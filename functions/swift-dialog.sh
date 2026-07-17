#!/bin/bash

# =============================================================================
# SWIFT DIALOG MANAGEMENT - v3.1 with Inspect Mode Support
# =============================================================================

dialog_manager() {
  local action="$1"
  shift

  # Check if SwiftDialog is available
  if [[ ! -x "/usr/local/bin/dialog" ]]; then
    log_warn "SwiftDialog not available, skipping UI update"
    return 0
  fi

  case "$action" in
  init)
    initialize_dialog "$@"
    ;;
  error)
    show_error_dialog "$@"
    ;;
  *)
    log_warn "Unknown dialog action: $action"
    ;;
  esac
}

create_dynamic_dialog_config() {
  log_info "Creating SwiftDialog v3 configuration with Inspect Mode from apps.json..."

  local swift_dialog_dir="$CONFIG_DIR/Swift Dialog"
  mkdir -p "$swift_dialog_dir"

  if [[ ! -f "$APPS_JSON" ]]; then
    log_error "apps.json not found at $APPS_JSON"
    return 1
  fi

  local settings=$(jq -r '.swift_dialog_settings // {}' "$APPS_JSON")
  local icon_base_path="$CONFIG_DIR/Swift Dialog/icons/"

  # Extract icon and bannerimage from settings
  local icon_val=$(echo "$settings" | jq -r '.icon // "sf=desktopcomputer.and.macbook"')
  local bannerimage_val=$(echo "$settings" | jq -r '.bannerimage // .banner // empty')

  # Resolve paths
  local icon_path="$icon_base_path$icon_val"
  local bannerimage_path="$icon_base_path$bannerimage_val"

  # Title + message (DRY_RUN aware)
  local title=$(echo "$settings" | jq -r '.title // "Mac Setup"')
  local message
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    title="${title} (DRY RUN)"
    message="Simulation only – no changes will be made to your system."
  else
    message=$(echo "$settings" | jq -r '.message // "Setting up your Mac with essential applications and configurations. This may take several minutes."')
  fi

  # Get preset value from settings
  local preset=$(echo "$settings" | jq -r '.preset // "preset1"')

  # Build cachePaths array for Inspect Mode
  local cache_paths_json=$(
    jq -n \
      --arg temp "$TEMP_DIR" \
      '[$temp]'
  )

  # Build inspectItems array from apps.json. Inspect mode wants a flat array
  # - see https://swiftdialog.app/advanced/inspect-mode/ "Items Configuration":
  # only id/displayName/guiIndex/paths (required) and icon/plistKey/expectedValue/
  # evaluation (optional). There is NO documented section/group syntax across
  # presets 1-9, so groups are represented as a single "rollup" row that
  # watches the group's plist for state=completed (written by update_group_state
  # once every child app finishes installing). The group's children are not
  # emitted as separate dialog rows - install progress for each child still
  # runs through the orchestrator, but the user sees one "System Settings" row
  # that flips green when the whole group is done.
  local inspect_items_json=$(jq -r \
    --arg statefile "$STATE_DIR" \
    '
    [ .items[] |
      if .type == "group" then
        { id, name, icon, _expected: "completed" }
      else
        { id, name, icon, _expected: "installed" }
      end
    ]
    | [ range(0; length) as $i |
        .[$i] | {
          id: .id,
          displayName: .name,
          guiIndex: $i,
          paths: [($statefile + "/" + .id + ".plist")],
          plistKey: "state",
          expectedValue: ._expected,
          evaluation: "equals",
          icon: (.icon // "sf=apple.logo")
        }
      ]
    ' "$APPS_JSON")

  # logMonitor path matches LOG_DIR/onboarding.log written by log_status_event.
  # Uses the "shell" preset which parses lines matching "^\[STATUS\]\s*(.+)$".
  # autoMatch routes status text to the correct item row by finding the app's
  # displayName in the captured text (e.g. "Downloading Google Chrome" → googlechrome).
  # Success (green check) comes from the plist FSEvent - logMonitor only drives
  # the progress spinner and status text while an install is in-flight.
  local log_monitor_json
  log_monitor_json=$(jq -n \
    --arg logPath "$LOG_DIR/onboarding.log" \
    '{
      path: $logPath,
      preset: "shell",
      startFromEnd: true,
      autoMatch: true
    }')

  # Build base JSON config with Inspect Mode support
  local config_json=$(jq -n \
    --arg title "$title" \
    --arg message "$message" \
    --arg icon "$icon_path" \
    --arg iconBasePath "$icon_base_path" \
    --arg bannerimage "$bannerimage_path" \
    --arg preset "$preset" \
    --argjson settings "$settings" \
    --argjson inspectItems "$inspect_items_json" \
    --argjson cachePaths "$cache_paths_json" \
    --argjson logMonitor "$log_monitor_json" \
    '{
      title: $title,
      message: $message,
      appearance: ($settings.appearance // "dark"),
      blurscreen: ($settings.blurscreen // false),
      moveable: ($settings.moveable // true),
      ontop: ($settings.ontop // true),
      fullscreen: ($settings.fullscreen // false),
      iconBasePath: $iconBasePath,
      icon: $icon,
      banner: $bannerimage,
      width: ($settings.width // 1024),
      height: ($settings.height // 650),

      scanInterval: 2,
      items: $inspectItems,
      cachePaths: $cachePaths,
      # We download with aria2c, which writes <name>.aria2 partial-control
      # files. SwiftDialog 3.1 cachePaths download-detection only watches
      # download/pkg/dmg by default (inspect-config.schema.json cacheExtensions,
      # swiftDialog issue 617), so an in-flight aria2c download is invisible to
      # inspect mode unless we add aria2 here. Override via
      # swift_dialog_settings.cacheExtensions. (NOTE: avoid apostrophes in this
      # comment - it lives inside a single-quoted jq program.)
      cacheExtensions: ($settings.cacheExtensions // ["download", "pkg", "dmg", "aria2"]),

      preset: $preset,
      logMonitor: $logMonitor,

      quitkey: "X",
      button1text: ($settings.button1text // "Please Wait..."),
      button1disabled: true,
      autoEnableButtonText: ($settings.autoEnableButtonText //
        (if ($settings.primary_button_action // "reboot") == "close" then "Close" else "Reboot" end)),
      autoEnableButton: true,

    } +
    # Optional inspect-mode visual keys, passed through verbatim if present in
    # swift_dialog_settings. Names must match the spec exactly (case-sensitive)
    # - https://swiftdialog.app/advanced/inspect-mode/ "Visual Customization Keys".
    ($settings | {
      bannerTitle, bannerHeight,
      highlightColor, backgroundColor, backgroundImage, backgroundOpacity,
      textOverlayColor, gradientColors,
      button2text, button2visible,
      colorThresholds
    } | with_entries(select(.value != null)))
  ')

  echo "$config_json" >"$SWIFT_DIALOG_CONFIG"

  if [[ $? -eq 0 ]]; then
    log_info "SwiftDialog Inspect Mode configuration created successfully"
    log_debug "Configuration created with $(echo "$inspect_items_json" | jq 'length') items"
    return 0
  else
    log_error "Failed to create SwiftDialog configuration"
    return 1
  fi
}

initialize_dialog() {
  log_info "Initializing SwiftDialog interface with Inspect Mode..."

  # Create dynamic dialog configuration
  if ! create_dynamic_dialog_config; then
    log_error "Failed to create dialog configuration"
    return 1
  fi

  # Verify configuration file exists and is valid JSON
  if [[ ! -f "$SWIFT_DIALOG_CONFIG" ]] || ! jq empty "$SWIFT_DIALOG_CONFIG" 2>/dev/null; then
    log_error "Invalid dialog configuration file at $SWIFT_DIALOG_CONFIG"
    return 1
  fi

  export DIALOG_INSPECT_CONFIG="$SWIFT_DIALOG_CONFIG"

  # Get current logged-in user
  local current_user
  current_user=$(get_current_user)

  if [[ -z "$current_user" ]]; then
    log_error "Could not determine current user"
    return 1
  fi

  local current_user_id
  current_user_id=$(id -u "$current_user")

  if [[ -z "$current_user_id" ]]; then
    log_error "Could not determine user ID for $current_user"
    return 1
  fi

  log_info "Starting SwiftDialog as user: $current_user (UID: $current_user_id)"

  # Re-check the dialog binary; the prerequisite phase should have installed it,
  # but a missing/broken binary here means we can't proceed with UI.
  if [[ ! -x /usr/local/bin/dialog ]]; then
    log_error "/usr/local/bin/dialog missing or not executable; cannot start SwiftDialog"
    return 1
  fi

  # Command file: any process can write `key: value` lines and SwiftDialog
  # applies them live. apps.json items use it for hide:/show: control while an
  # install runs (see the hide:/show: post_install_commands). The button is
  # auto-enabled by inspect mode itself once every item reaches its compliant
  # state (autoEnableButton), so the orchestrator no longer drives it here.
  # Path is intentionally in /var/tmp (no spaces) - SwiftDialog's commandfile
  # poller errors on paths containing spaces (e.g. "Application Support").
  # The actual path is published to STATE_DIR/dialog.cmd.path so the
  # orchestrator and apps.json commands can find it without hardcoding.
  local dialog_cmd_file="/var/tmp/otk_dialog.cmd"
  : >"$dialog_cmd_file"
  chmod 666 "$dialog_cmd_file"
  echo "$dialog_cmd_file" >"$STATE_DIR/dialog.cmd.path"

  # Capability probe: --inspect-mode requires SwiftDialog build >= 4955.
  # If the installed binary is older, fall back to launching without the flag
  # so we at least get a degraded UI instead of a hard failure.
  # Note: `dialog --version` formatting varies across builds - older releases
  # use a dash before the build number ("3.0.0-4952"), newer ones use a dot
  # ("3.0.1.4955"). Extract the *last* numeric run so both work.
  local dialog_build
  dialog_build="$(/usr/local/bin/dialog --version 2>/dev/null | grep -oE '[0-9]+' | tail -1)"
  local has_inspect=true
  if [[ -z "$dialog_build" || "$dialog_build" -lt 4955 ]]; then
    log_warn "SwiftDialog build '${dialog_build:-unknown}' does not support --inspect-mode (needs >= 4955); launching without inspect mode"
    has_inspect=false
  fi

  # Publish the inspect config to SwiftDialog's standard discovery location.
  # SwiftDialog >= 3.1 resolves the inspect config in this priority order
  # (dialog/Command Line/ProcessCLOptions.swift):
  #   1. $DIALOG_INSPECT_CONFIG env var
  #   2. /var/tmp/dialog-inspect-config.json  (standard location)
  #   3. --inspect-config <path>   <-- "may cause hang with certain SwiftUI
  #                                     versions" per SwiftDialog's own source
  # We previously used (3), which in 3.1 hangs on launch so the window never
  # appears. (1) is unreliable through `launchctl asuser` + `sudo -u` (env is
  # stripped) and (2)/(3) with our real path are fragile because it contains
  # spaces ("Application Support"/"Swift Dialog"). Copying to the standard
  # /var/tmp path (no spaces, world-readable) and launching with NO
  # --inspect-config lets dialog self-discover via priority 2 - robust across
  # the sudo chain and immune to the --inspect-config hang.
  local std_inspect_config="/var/tmp/dialog-inspect-config.json"
  if cp -f "$SWIFT_DIALOG_CONFIG" "$std_inspect_config" 2>/dev/null; then
    chmod 644 "$std_inspect_config"
  else
    log_warn "Could not stage inspect config to $std_inspect_config; falling back to --inspect-config (may hang on SwiftDialog 3.1)"
  fi

  # Launch dialog as the logged-in user.
  if [[ "$has_inspect" == "true" ]]; then
    if [[ -f "$std_inspect_config" ]]; then
      launchctl asuser "$current_user_id" sudo -u "$current_user" \
        /usr/local/bin/dialog --inspect-mode --commandfile "$dialog_cmd_file" &
    else
      launchctl asuser "$current_user_id" sudo -u "$current_user" \
        /usr/local/bin/dialog --inspect-mode --inspect-config "$SWIFT_DIALOG_CONFIG" --commandfile "$dialog_cmd_file" &
    fi
  else
    launchctl asuser "$current_user_id" sudo -u "$current_user" \
      /usr/local/bin/dialog --commandfile "$dialog_cmd_file" &
  fi

  # Store PID for cleanup
  local dialog_pid=$!
  echo "$dialog_pid" >"$STATE_DIR/dialog.pid"

  log_debug "SwiftDialog PID: $dialog_pid"

  # Wait for dialog to initialize
  sleep 2

  # Verify dialog is running
  if ! kill -0 "$dialog_pid" 2>/dev/null; then
    log_error "SwiftDialog failed to start"
    return 1
  fi

  if [[ "$has_inspect" == "true" ]]; then
    log_info "SwiftDialog v3 initialized with Inspect Mode (config: $SWIFT_DIALOG_CONFIG)"
  else
    log_info "SwiftDialog v3 initialized (degraded - no Inspect Mode)"
  fi
  return 0
}

show_error_dialog() {
  local error_message="$1"

  /usr/local/bin/dialog \
    --title "Installation Error" \
    --message "$error_message" \
    --icon "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns" \
    --button1text "OK" 2>/dev/null || true
}
