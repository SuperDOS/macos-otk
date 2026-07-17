#!/bin/bash

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

#helper function to extract command name from a full command
extract_command_name() {
  local full_command="$1"

  # Trim leading/trailing whitespace
  full_command="${full_command#"${full_command%%[![:space:]]*}"}"
  full_command="${full_command%"${full_command##*[![:space:]]}"}"

  # If command starts with $(), extract the first word inside
  if [[ "$full_command" == \$\(* ]]; then
    # Remove leading '$(' and trailing ')'
    local inner_command="${full_command:2}"
    [[ "${inner_command: -1}" == ")" ]] && inner_command="${inner_command::-1}"

    # Extract first word from the inner command
    echo "$inner_command" | awk '{print $1}'
  else
    echo "$full_command" | awk '{print $1}'
  fi
}

initialize_state_file_with_detection() {
  log_info "Detecting current installation states..."

  mkdir -p "$STATE_DIR"
  chmod 755 "$STATE_DIR"

  local items_json=$(jq -c '.items[]' "$APPS_JSON")

  #
  # 1. SCAN ALL APPS FIRST
  #
  while IFS= read -r item; do
    local item_type=$(echo "$item" | jq -r '.type')

    if [[ "$item_type" == "group" ]]; then
      local apps=$(echo "$item" | jq -c '.apps[]')
      while IFS= read -r app_config; do
        local app_id=$(echo "$app_config" | jq -r '.id')

        if is_application_installed "$app_config"; then
          update_installation_state "$app_id" "installed"
        else
          update_installation_state "$app_id" "not_installed"
        fi
      done <<<"$apps"

    else
      local item_id=$(echo "$item" | jq -r '.id')

      if is_application_installed "$item"; then
        update_installation_state "$item_id" "installed"
      else
        update_installation_state "$item_id" "not_installed"
      fi
    fi
  done <<<"$items_json"

  #
  # 2. AFTER ALL APPS → EVALUATE GROUP COMPLETION
  #
  while IFS= read -r item; do
    local item_type=$(echo "$item" | jq -r '.type')

    if [[ "$item_type" == "group" ]]; then
      local group_id=$(echo "$item" | jq -r '.id')

      if check_group_completion "$item"; then
        update_group_state "$group_id" "completed" "$item"
      else
        update_group_state "$group_id" "partial" "$item"
      fi
    fi
  done <<<"$items_json"

  log_info "Per-app and per-group state files updated based on system detection."
}

update_installation_state() {
  local item_id="$1"
  local state="$2"
  local plist="$STATE_DIR/${item_id}.plist"

  # Always write the plist - even for "not_installed". SwiftDialog Inspect Mode
  # tracks each item's `paths[]` for existence (FSEvents) and reads `plistKey`
  # for compliance. If the file is missing the row will not render at all,
  # leaving the dialog with logo + button and an empty list. Writing
  # state=not_installed gives SwiftDialog something to watch and a
  # known-non-compliant value to display until install completes and we
  # rewrite the file with state=installed.
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>state</key>
    <string>${state}</string>
</dict>
</plist>
EOF

  chmod 644 "$plist"
  log_debug "Updated state file: ${item_id}.plist → $state"
}

get_installation_state() {
  local item_id="$1"
  local plist="$STATE_DIR/${item_id}.plist"

  INSTALLATION_STATE="not_installed"

  # Load app info from JSON
  local app_data
  app_data=$(jq -r --arg id "$item_id" '
    (
      (.items[]? | if .type == "group" then .apps[] else . end),
      (.prerequisites[]?)
    ) 
    | select(.id == $id)
  ' "$APPS_JSON")

  if [[ -z "$app_data" ]]; then
    log_error "No app found with id: $item_id"
    return 1
  fi

  local app_name
  app_name=$(echo "$app_data" | jq -r '.name')

  #
  # 1. DETECTION COMMANDS
  #
  local detection_commands
  detection_commands=$(echo "$app_data" | jq -r '
    .detection_commands |
    if type == "array" then .[] else . end // empty
  ')
  local detect_all
  detect_all=$(echo "$app_data" | jq -r '.detect_all // false')

  if [[ -n "$detection_commands" ]]; then
    local all_passed=true
    local one_passed=false
    local command_found=false

    while IFS= read -r command; do
      [[ -z "$command" ]] && continue
      command_found=true

      local prefix="${command%%:*}"
      local actual_command="${command#*:}"
      local run_as_user=false
      [[ "$prefix" == "user" ]] && run_as_user=true

      execute_detection_command "$actual_command" "$run_as_user" "$item_id"
      local exit_code=$?

      log_debug "Detection: \"$actual_command\" (Exit: $exit_code)"

      if [[ $exit_code -eq 0 ]]; then
        one_passed=true
      else
        all_passed=false
      fi
    done <<<"$detection_commands"

    if [[ "$command_found" == "true" ]]; then
      if { [[ "$detect_all" == "true" ]] && [[ "$all_passed" == "true" ]]; } ||
        { [[ "$detect_all" == "false" ]] && [[ "$one_passed" == "true" ]]; }; then

        INSTALLATION_STATE="installed"
        log_info "$app_name (ID: $item_id) detected as installed."

        update_installation_state "$item_id" "installed"
        return 0
      else
        INSTALLATION_STATE="not_installed"
        log_debug "$app_name (ID: $item_id) detection commands indicate not installed."

        update_installation_state "$item_id" "not_installed"
        return 1
      fi
    fi
  fi

  #
  # 2. CHECK /Applications
  #
  local alt_app_name
  alt_app_name=$(echo "$app_data" | jq -r '.alt_app_name // empty')

  local clean_app_name="${app_name//[$'\t\r\n']/}"
  local app_path=""

  if [[ -n "$alt_app_name" ]]; then
    app_path=$(find /Applications -maxdepth 1 -iname "$alt_app_name" -type d 2>/dev/null | head -n 1)
  else
    app_path=$(find /Applications -maxdepth 1 -iname "${clean_app_name}.app" -type d 2>/dev/null | head -n 1)
  fi

  if [[ -n "$app_path" ]]; then
    INSTALLATION_STATE="installed"
    log_debug "$app_name (ID: $item_id) found in /Applications."

    update_installation_state "$item_id" "installed"
    return 0
  fi

  #
  # 3. NOT FOUND ANYWHERE
  #
  INSTALLATION_STATE="not_installed"
  log_debug "$app_name (ID: $item_id) not found."

  update_installation_state "$item_id" "not_installed"
  return 1
}

update_group_state() {
  local group_id="$1"
  local state="$2"
  local plist="$STATE_DIR/${group_id}.plist"
  local group_name=$(echo "$3" | jq -r '.name')

  # Always write the plist, even for non-"completed" states (e.g. "partial").
  # Inspect mode tracks the file via FSEvents and reads `plistKey` for compliance;
  # if the file is missing, the group's row never renders. We watch for
  # state=completed in the inspect-mode item config and let SwiftDialog flip the
  # row to green when the group's last child finishes.
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>state</key>
    <string>${state}</string>
</dict>
</plist>
EOF

  chmod 644 "$plist"
  log_debug "Updated group state for $group_name (ID: $group_id): $state"
}

check_group_completion() {
  local group_config="$1"

  # Get all app IDs in the group
  local app_ids=$(echo "$group_config" | jq -r '.apps[].id')

  local all_installed=true
  while IFS= read -r app_id; do
    [[ -z "$app_id" ]] && continue

    # Check if plist exists AND contains state=installed
    local plist="$STATE_DIR/${app_id}.plist"
    if [[ ! -f "$plist" ]]; then
      all_installed=false
      break
    fi

    local state
    state=$(defaults read "$plist" state 2>/dev/null || echo "not_installed")

    if [[ "$state" != "installed" ]]; then
      all_installed=false
      break
    fi

  done <<<"$app_ids"

  $all_installed && return 0 || return 1
}

execute_detection_command() {
  local command="$1"
  local run_as_user="$2"
  local item_id="$3" # Changed from app_name

  local command_name
  command_name=$(extract_command_name "$command")
  local command_type
  command_type=$(type -t "$command_name")

  if [[ -z "$command_type" ]]; then
    log_error "Command '$command_name' is not found in the current shell (ID: $item_id)"
    return 1
  fi

  log_info "Running detection command for ID $item_id: $command"
  log_info "Detected command type: $command_type"

  local current_user
  current_user=$(get_current_user)

  local output
  local exit_code

  if [[ "$command_type" == "file" || "$command_type" == "builtin" ]]; then
    if [[ "$run_as_user" == "true" ]]; then
      # `-H` is required so HOME is the target user's home; without it sudo
      # preserves root's HOME and any `~` in the detection command (e.g.
      # ~/Library/Preferences/...) expands to /var/root/Library/... → file
      # not found → detection silently reports "not installed" forever.
      output=$(sudo -H -u "$current_user" bash -c "set -e; $command" 2>&1)
      exit_code=$?
    else
      output=$(bash -c "set -e; $command" 2>&1 <<<"")
      exit_code=$?
    fi
  elif [[ "$command_type" == "function" ]]; then
    # Mirror execute_commands (unified_installer.sh): source the full
    # functions/ directory in the child shell so every helper the command's
    # body references (log_info, log_debug, generate_random_string, ...) is
    # defined. The previous approach serialized only the target function via
    # `declare -f "$command_name"`, so any nested helper call produced
    # "command not found" noise - and, when it was the function's last
    # statement, a bogus exit 127 that flipped the detection result.
    # log_level already tolerates the user-context child (file writes to the
    # root-owned log are suppressed; console output is captured below).
    local temp_script
    temp_script=$(mktemp "/tmp/${command_name}_XXXX.sh")
    {
      echo "#!/bin/bash"
      if [[ -d "$SCRIPT_DIR/functions" ]]; then
        echo "for __otk_fn in \"$SCRIPT_DIR/functions/\"*.sh; do source \"\$__otk_fn\"; done"
      else
        # Fallback (no functions dir next to the orchestrator): at least ship
        # the target function itself, as before.
        declare -f "$command_name"
      fi
      [[ -n "${LOG_DIR:-}" ]] && echo "export LOG_DIR=\"$LOG_DIR\""
      [[ -n "${DEBUG:-}" ]] && echo "export DEBUG=\"$DEBUG\""
      [[ -n "${STATE_DIR:-}" ]] && echo "export STATE_DIR=\"$STATE_DIR\""
      [[ -n "${CONFIG_DIR:-}" ]] && echo "export CONFIG_DIR=\"$CONFIG_DIR\""
      echo "export TEMP_DIR=\"${TEMP_DIR:-/tmp}\""
      echo
      echo "$command"
    } >"$temp_script"
    chmod +x "$temp_script"

    if [[ "$run_as_user" == "true" ]]; then
      chown "$current_user" "$temp_script"
      output=$(sudo -H -u "$current_user" bash "$temp_script" 2>&1)
      exit_code=$?
    else
      output=$(bash "$temp_script" 2>&1)
      exit_code=$?
    fi
    rm -f "$temp_script"
  else
    log_error "Unsupported command type: $command_type (ID: $item_id)"
    return 1
  fi

  echo "$output"
  return $exit_code
}

# Force every item's plist to its expected-compliant value so SwiftDialog
# inspect mode sees the whole config as "complete" and fires autoEnableButton.
# Called at end-of-run from the orchestrator's finalize block. Intentionally
# does not differentiate success vs failure at the per-item visual level - the
# completion UI is the inspect-mode card layout itself (all items shown as
# processed, with an enabled close button); no textual summary is posted.
# Items get state=installed; groups get state=completed (matching the
# expectedValue values configured in functions/swift-dialog.sh:82-104).
force_compliant_state_for_all_items() {
  log_info "Forcing all item plists to compliant state for SwiftDialog auto-enable..."

  local items_json
  items_json=$(jq -c '.items[]' "$APPS_JSON")

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    local item_type
    item_type=$(echo "$item" | jq -r '.type')

    if [[ "$item_type" == "group" ]]; then
      local group_id
      group_id=$(echo "$item" | jq -r '.id')
      update_group_state "$group_id" "completed" "$item"

      # Also flip every child app's plist to installed so the group's row and
      # any per-app rows agree.
      local app_ids
      app_ids=$(echo "$item" | jq -r '.apps[].id')
      while IFS= read -r app_id; do
        [[ -z "$app_id" ]] && continue
        update_installation_state "$app_id" "installed"
      done <<<"$app_ids"
    else
      local item_id
      item_id=$(echo "$item" | jq -r '.id')
      update_installation_state "$item_id" "installed"
    fi
  done <<<"$items_json"

  log_info "All item plists forced to compliant state."
}

cleanup_stale_plists() {
  log_info "Cleaning up stale plist files in $STATE_DIR..."

  mkdir -p "$STATE_DIR"

  #
  # 1. Build valid ID list from apps.json
  #
  local valid_ids
  valid_ids=$(jq -r '
      .items[] |
      if .type == "group" then
        .id, (.apps[].id)
      else
        .id
      end
    ' "$APPS_JSON" | sort -u)

  #
  # 2. Iterate over all *.plist in state folder
  #
  for plist in "$STATE_DIR"/*.plist; do
    [[ ! -f "$plist" ]] && continue

    local filename
    filename=$(basename "$plist")
    local id="${filename%.plist}"

    # Check if this id is in valid list
    if ! grep -Fxq "$id" <<<"$valid_ids"; then
      log_warn "Removing stale plist: $filename (no longer present in apps.json)"
      rm -f "$plist"
      continue
    fi

    # Optional extra check: corrupted plist with no state key
    if ! defaults read "$plist" state &>/dev/null; then
      log_warn "Removing invalid/corrupted plist: $filename (no 'state' key)"
      rm -f "$plist"
    fi
  done

  log_info "Cleanup complete."
}