#!/bin/bash

# =============================================================================
# Custom Commands
# =============================================================================

# Install Rosetta 2 if needed (builtin for prerequisites)

install_rosetta2() {
  log_info "Checking Rosetta 2 requirements..."

  # Check macOS version
  local os_version=$(sw_vers -productVersion)
  local major_version=$(echo "$os_version" | cut -d. -f1)

  if [[ $major_version -lt 11 ]]; then
    log_info "macOS version $os_version does not require Rosetta 2"
    return 0
  fi

  # Check processor type
  local processor=$(sysctl -n machdep.cpu.brand_string | grep -o "Intel" || true)
  if [[ -n "$processor" ]]; then
    log_info "Intel processor detected, Rosetta 2 not required"
    return 0
  fi

  # Check if Rosetta 2 is already installed
  if pgrep oahd >/dev/null 2>&1; then
    log_info "Rosetta 2 is already installed and running"
    return 0
  fi

  # Install Rosetta 2
  log_info "Installing Rosetta 2..."
  wait_for_process "softwareupdate" 300

  if softwareupdate --install-rosetta --agree-to-license; then
    log_info "Rosetta 2 installed successfully"
  else
    log_error "Failed to install Rosetta 2"
    return 1
  fi
}

# RENAME DEVICE FUNCTIONS
rename_device() {
  local CorporatePrefix="CO"
  local PersonalPrefix="BYO"
  local NameTemplate="{prefix}-{serialnum}-{country}-{modelcode}"
  local ABMOnly="false"
  local EnforceBYOD="false"
  local TestOnly="false"

  # Logging setup
  local appname="RenameDevice"
  log_info "$appname started"

  # Parse arguments
  while [[ "$#" -gt 0 ]]; do
    case $1 in
    --corporateprefix)
      CorporatePrefix="$2"
      shift
      ;;
    --personalprefix)
      PersonalPrefix="$2"
      shift
      ;;
    --nametemplate)
      NameTemplate="$2"
      shift
      ;;
    --testonly)
      TestOnly="$2"
      shift
      ;;
    --help)
      cat <<EOF
Usage:
  rename_device [--corporateprefix PREFIX] [--personalprefix PREFIX] [--nametemplate TEMPLATE] [--testonly true|false] [--help]

Description:
  Renames a macOS device based on a customizable name template.
  Supports dynamic values like serial number, model code, country, and random strings.

Options:
  --corporateprefix PREFIX   Prefix for corporate-owned devices (default: "CO")
  --personalprefix PREFIX    Prefix for BYOD devices (default: "BYO")
  --nametemplate TEMPLATE    Template for the new device name. Supports:
                               {prefix}       → Corporate or personal prefix
                               {serialnum}    → Device serial number
                               {country}      → Country code from public IP
                               {modelcode}    → Short code from Mac model
                               {random[N]}    → Random alphanumeric string of N characters
  --testonly true|false      Run in test mode without renaming (default: false)
  --help                     Show this help message and exit

Examples:
  rename_device --nametemplate "{prefix}-{random[4]}-{modelcode}"
  rename_device --testonly true --nametemplate "{prefix}-{serialnum}-{modelcode}"

Dry Run Logic:
  Use --testonly true to check if renaming is needed.
  If the current name matches the generated name, the script returns 0.
  If a rename is needed, it returns 1.

  Example:
    if rename_device --nametemplate 'mac-{serialnum}' --testonly true; then
        echo "No rename needed."
    else
        rename_device --nametemplate 'mac-{serialnum}'
    fi
EOF
      return 0
      ;;
    *)
      log_error "Unknown parameter: $1"
      return 1
      ;;
    esac
    shift
  done

  # Get serial number
  get_serial_number() {
    system_profiler SPHardwareDataType | awk '/Serial/ {print $4}' | cut -d ':' -f2- | xargs
  }

  # Get country code
  get_country_code() {
    local ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || curl -s -m 60 ifconfig.me)
    curl -s -m 60 "https://ipapi.co/$ip/country" 2>/dev/null
  }

  # Get model code
  get_model_code() {
    local model=$(system_profiler SPHardwareDataType | awk -F': ' '/Model Name/ {print $2}' | xargs)
    case "$model" in
    MacBook\ Air*) echo "MBA" ;;
    MacBook\ Pro*) echo "MBP" ;;
    MacBook*) echo "MB" ;;
    iMac*) echo "IMAC" ;;
    Mac\ Pro*) echo "PRO" ;;
    Mac\ mini*) echo "MINI" ;;
    Mac\ Studio*) echo "MS" ;;
    Apple\ Virtual\ Machine*) echo "VM" ;;
    *) echo "MAC" ;;
    esac
  }

  # Determine owner prefix
  resolve_owner_prefix() {
    if profiles status -type enrollment | grep -q "MDM enrollment: Yes"; then
      echo "$CorporatePrefix"
    elif [[ "$ABMOnly" == "false" ]]; then
      if [[ "$EnforceBYOD" == "true" ]]; then
        echo "$PersonalPrefix"
      else
        log_warn "Manual enrollment detected. Skipping rename."
        return 1
      fi
    else
      log_warn "Not ABM enrolled. Skipping rename."
      return 1
    fi
  }

  # Build new name
  build_device_name() {
    local prefix="$1"
    local serialnum=$(get_serial_number)
    local country=$(get_country_code)
    local modelcode=$(get_model_code)

    local name="$NameTemplate"
    name="${name//\{prefix\}/$prefix}"
    name="${name//\{serialnum\}/$serialnum}"
    name="${name//\{country\}/$country}"
    name="${name//\{modelcode\}/$modelcode}"

    while [[ "$name" =~ \{random\[([0-9]+)\]\} ]]; do
      local len="${BASH_REMATCH[1]}"
      local rand=$(generate_random_string "$len")
      name="${name/\{random\[$len\]\}/$rand}"
    done

    echo "$name"
  }

  # Main logic
  local prefix
  prefix=$(resolve_owner_prefix) || return 0

  local new_name
  new_name=$(build_device_name "$prefix")
  local current_name
  current_name=$(scutil --get ComputerName)

  log_info "Generated name: $new_name"
  log_debug "Current name: $current_name"

  if [[ "$current_name" == "$new_name" ]]; then
    log_info "Name already set. No change needed."
    return 0
  fi

  if [[ "$TestOnly" == "true" ]]; then
    log_info "Dry run: Would rename device to '$new_name'"
    return 1 # Signal that rename is needed
  fi

  # Apply new name
  local nameTypes=(ComputerName HostName LocalHostName)
  for nameType in "${nameTypes[@]}"; do
    if scutil --set "$nameType" "$new_name"; then
      log_info "$nameType set to $new_name"
    else
      log_error "Failed to set $nameType"
    fi
  done

  return 0
}
# END OF RENAME DEVICE FUNCTIONS

# Set the system default web browser. Chromium-only (Edge / Chrome / Brave /
# Vivaldi / Opera / Arc) - relies on the `--make-default-browser` launch flag
# which is a Chromium feature. Sequoia rejects direct utiluti LaunchServices
# writes for these UTIs (errFSpermErr / -54), so we drive it entirely through
# Chromium's own flag: `open -a <Browser> --args --make-default-browser`
# triggers the CoreServicesUIAgent prompt, and on confirmation Chromium writes
# all four LaunchServices handlers atomically - exactly what the detection
# command verifies. We auto-click the "Use <Short>" button via AppleScript.
#
# Other foreground apps are hidden first so AutoUpdate / Teams welcome
# dialogs don't end up above CoreServicesUIAgent.
#
# Must run in user context (`user:` prefix in apps.json) so the handler
# writes land in the console user's LaunchServices preferences.
#
# Requires Accessibility permission for whatever process invokes osascript
# (deployed via PPPC profile). Without it the click silently no-ops and the
# user will see the prompt the next time the browser launches.
#
# Button matching: Apple's prompt button is `Use "<Short>"` where <Short> is
# the brand without a vendor prefix (e.g. `Use "Edge"`, `Use "Chrome"`). The
# default match strips a leading "Microsoft " / "Google " / "Brave " from
# app_name; pass an explicit third arg to override.
#
# The bundle id is intentionally NOT taken - Chromium's `--make-default-browser`
# handles the LaunchServices write itself; we only need the .app name (for
# `open -a`) and the button label macOS shows in the confirmation dialog.
#
# Usage:
#   set_browser_default <app_name> [button_match]
# Examples:
#   set_browser_default "Microsoft Edge"
#   set_browser_default "Google Chrome"
#   set_browser_default "Brave Browser"
set_browser_default() {
  local app_name="$1"
  local button_match="${2:-}"

  if [[ -z "$app_name" ]]; then
    echo "set_browser_default: app_name is required (e.g. \"Microsoft Edge\")" >&2
    return 2
  fi

  if [[ -z "$button_match" ]]; then
    # Strip a leading vendor word so "Microsoft Edge" → "Edge", "Google Chrome"
    # → "Chrome", matching Apple's `Use "<Short>"` button text.
    button_match="${app_name#Microsoft }"
    button_match="${button_match#Google }"
    button_match="${button_match#Brave }"
  fi

  osascript -e 'tell application "System Events" to set visible of (every process whose background only is false and visible is true) to false' 2>/dev/null || true

  open -a "$app_name" --args --make-default-browser
  sleep 2

  osascript <<END_OF_SCRIPT 2>/dev/null || true
tell application "System Events"
  try
    tell application process "CoreServicesUIAgent"
      set frontmost to true
      repeat 30 times
        try
          set wins to every window
          repeat with w in wins
            try
              set btns to buttons of w
              repeat with b in btns
                if (name of b) contains "${button_match}" then
                  click b
                  exit repeat
                end if
              end repeat
            end try
          end repeat
        end try
        delay 0.5
      end repeat
    end tell
  end try
end tell
END_OF_SCRIPT
}

# Set the system default mail / calendar / vcard handler to the given bundle
# ID. Writes the five LaunchServices handlers macOS consults for mail-related
# UTIs and URL schemes via utiluti (a prereq). Must run in user context
# (`user:` prefix in apps.json) so it lands in the console user's
# LaunchServices preferences, not root's.
#
# Usage:
#   set_default_mail_client com.microsoft.outlook
#   set_default_mail_client com.apple.mail
set_default_mail_client() {
  local bundle_id="$1"
  if [[ -z "$bundle_id" ]]; then
    echo "set_default_mail_client: bundle id is required" >&2
    return 2
  fi
  /usr/local/bin/utiluti type set com.apple.default-app.mail-client "$bundle_id"
  /usr/local/bin/utiluti type set com.apple.ical.ics                "$bundle_id"
  /usr/local/bin/utiluti type set public.vcard                      "$bundle_id"
  /usr/local/bin/utiluti url  set mailto                            "$bundle_id"
  /usr/local/bin/utiluti url  set ical                              "$bundle_id"
}

# Set the system locale and force 24-hour clock everywhere (loginwindow,
# current user session, future user accounts). Writes the CFPreferences keys
# at two scopes:
#   - /Library/Preferences/.GlobalPreferences - system-wide default, also
#     read by loginwindow when no user is logged in
#   - the console user's globalDomain - overrides system-wide when that user
#     is logged in (per-user CFPrefs always shadow system)
# Then kicks cfprefsd so the change takes effect without a logout/login.
#
# Why this is needed: a plain `defaults write /Library/Preferences/
# .GlobalPreferences AppleLocale en_GB` only fixes language/region. The
# 12h-vs-24h clock is independently controlled by AppleICUForce24HourTime,
# and a stale per-user .GlobalPreferences will keep showing 12h until you
# explicitly write to the user's domain too.
#
# Run as root (the system-domain write needs root; the user-domain write is
# performed via `sudo -u $console_user`).
#
# Usage:
#   set_default_locale en_GB
#   set_default_locale sv_SE
set_default_locale() {
  local locale="$1"
  if [[ -z "$locale" ]]; then
    echo "set_default_locale: locale is required (e.g. en_GB)" >&2
    return 2
  fi

  # System-wide
  defaults write /Library/Preferences/.GlobalPreferences AppleLocale            "$locale"
  defaults write /Library/Preferences/.GlobalPreferences AppleICUForce24HourTime -bool true

  # Console user (if logged in) - per-user CFPreferences always override
  # system-wide, so without this the user's session keeps the old setting.
  local console_user
  console_user=$(get_current_user 2>/dev/null)
  if [[ -n "$console_user" && "$console_user" != "root" && "$console_user" != "loginwindow" ]]; then
    sudo -H -u "$console_user" defaults write -g AppleLocale            "$locale"
    sudo -H -u "$console_user" defaults write -g AppleICUForce24HourTime -bool true
  fi

  # Flush prefs cache so changes are visible to running processes (menubar
  # clock, system settings) without requiring logout.
  killall cfprefsd 2>/dev/null || true
}


# Reconfigure the macOS Dock for the current (or specified) console user.
configure_dock() {
  # --------------- Help text ---------------
  _configure_dock_help() {
    cat <<'EOF'
NAME
    configure_dock - reconfigure the macOS Dock for the console user.

SYNOPSIS
    configure_dock [OPTIONS] [ITEM ...]
    configure_dock --help

DESCRIPTION
    Applies a clean (or appended) Dock configuration by writing to:
      - com.apple.dock persistent-apps
      - com.apple.dock persistent-others
    Then restarts the Dock (unless --no-restart is given).

ITEM GRAMMAR
    You can mix any of the following ITEM forms:

    1) Applications (absolute path)
         /Applications/Safari.app
         /System/Applications/Notes.app

    2) Spacers
         spacer           (normal spacer)
         small-spacer     (compact spacer)
         flex-spacer      (flexible spacer)

    3) Folders / Stacks
        Token-based (colon-delimited):
           dir-<PathOrName>:<arrangement>[:<displayAs>[:<showAs>]]
           Example: dir-Downloads:created:stack:fan

       PathOrName may be:
         - Absolute (e.g., /Applications, /Users/alex/Projects)
         - Special names: Downloads | Applications | Documents | Desktop
         - Relative to home (e.g., Projects)

TOKENS
    Arrangement (arr / arrangement)
      name | added | modified | created | kind
      (maps to 1..5 respectively)

    Display As (display / displayAs)
      stack | folder
      (stack=0, folder=1)

    Show As (show / showAs)
      auto | fan | grid | list
      (auto=0, fan=1, grid=2, list=3)

OPTIONS
    -h, --help        Show this help and exit.
    -a, --append      Do NOT clear existing Dock items first.
    --no-restart      Do not restart Dock after writing preferences.
    -n, --dry-run     Print actions without making changes.
    --user <name>     Override detected console user.

EXIT CODES
    0  Success
    1  Failure (Dock not running, user detection failure, invalid folder, etc.)

EXAMPLES:
    configure_dock "dir-Downloads:created:stack:fan" \
                   "dir-Applications:name:folder:grid"

    # Mixed with apps and spacers:
    configure_dock "/System/Applications/Launchpad.app" \
                   "/Applications/Microsoft Edge.app" \
                   spacer \
                   "dir-Documents:modified:folder:grid"

NOTES
    - The order of items matters; they are added in the order given.
    - When run as root, commands are executed via 'launchctl asuser' and 'sudo -u'.
EOF
  }

  # --------------- Option parsing ---------------
  local __append=0
  local __no_restart=0
  local __dry_run=0
  local __user_override=""
  local items=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      _configure_dock_help
      return 0
      ;;
    -a | --append)
      __append=1
      shift
      ;;
    --no-restart)
      __no_restart=1
      shift
      ;;
    -n | --dry-run)
      __dry_run=1
      shift
      ;;
    --user)
      if [[ -z "$2" ]]; then
        echo "--user requires a username"
        return 1
      fi
      __user_override="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        items+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Use --help to see available options."
      return 1
      ;;
    *)
      items+=("$1")
      shift
      ;;
    esac
  done

  local dock_items=("${items[@]}")

  if [[ ${#dock_items[@]} -eq 0 ]]; then
    echo "No dock items provided. Skipping Dock configuration."
    return 0
  fi

  echo "Configuring Dock with ${#dock_items[@]} item(s)"

  # --------------- Wait for Dock to be running ---------------
  local dock_wait_count=0
  until pgrep -x "Dock" &>/dev/null; do
    sleep 2
    dock_wait_count=$((dock_wait_count + 1))
    if [[ $dock_wait_count -gt 30 ]]; then
      echo "Dock process not found after ~60 seconds"
      return 1
    fi
  done

  # --------------- Resolve user context ---------------
  local current_user
  if [[ -n "$__user_override" ]]; then
    current_user="$__user_override"
  elif [[ -n "$USER" ]]; then
    current_user="$USER"
  else
    current_user=$(scutil <<<"show State:/Users/ConsoleUser" | awk '/Name :/ && !/loginwindow/ { print $3 }')
  fi

  if [[ "$current_user" == "loginwindow" || -z "$current_user" ]]; then
    echo "No user logged in or user detection failed"
    return 1
  fi

  local uid
  uid=$(id -u "$current_user" 2>/dev/null)
  if [[ -z "$uid" ]]; then
    echo "Could not get UID for user: $current_user"
    return 1
  fi

  local user_home
  user_home=$(eval echo "~$current_user")
  if [[ ! -d "$user_home" ]]; then
    echo "User home directory not found: $user_home"
    return 1
  fi

  # --------------- Mapping helpers ---------------
  _lower() { tr '[:upper:]' '[:lower:]' <<<"$*"; }

  _map_arrangement() {
    local v=$(_lower "$1")
    case "$v" in
    1 | name) echo 1 ;;
    2 | added | "date added" | "date_added" | dateadded) echo 2 ;;
    3 | modified | "date modified" | "date_modified" | datemodified) echo 3 ;;
    4 | created | "date created" | "date_created" | datecreated) echo 4 ;;
    5 | kind | type) echo 5 ;;
    *) echo "" ;;
    esac
  }

  _map_displayas() {
    local v=$(_lower "$1")
    case "$v" in
    0 | stack) echo 0 ;;
    1 | folder) echo 1 ;;
    *) echo "" ;;
    esac
  }

  _map_showas() {
    local v=$(_lower "$1")
    case "$v" in
    0 | auto | automatic) echo 0 ;;
    1 | fan) echo 1 ;;
    2 | grid) echo 2 ;;
    3 | list) echo 3 ;;
    *) echo "" ;;
    esac
  }

  # Parse a dir-* item into path, arrangement, displayas, showas
  # Supports token-based only:
  #   dir-<PathOrName>:<arrangement>[:<displayAs>[:<showAs>]]
  # Examples:
  #   dir-Downloads:created:stack:fan
  #   dir-/absolute/path:name:folder:grid
  _parse_dir_item() {
    local raw="$1"
    local rest="${raw#dir-}"

    # Split "<path>" from tokens after the first colon
    local path_name token_str
    if [[ "$rest" == *:* ]]; then
      path_name="${rest%%:*}"
      token_str="${rest#"$path_name"}"
      token_str="${token_str#:}"
    else
      path_name="$rest"
      token_str=""
    fi

    local arrangement="" displayas="" showas=""

    # Consume tokens in order: arrangement -> displayas -> showas
    if [[ -n "$token_str" ]]; then
      local IFS=':'
      read -r -a tokens <<<"$token_str"
      local tok m
      for tok in "${tokens[@]}"; do
        # Trim whitespace (defensive)
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        [[ -z "$tok" ]] && continue

        if [[ -z "$arrangement" ]]; then
          m="$(_map_arrangement "$tok")"
          if [[ -n "$m" ]]; then
            arrangement="$m"
            continue
          fi
        fi
        if [[ -z "$displayas" ]]; then
          m="$(_map_displayas "$tok")"
          if [[ -n "$m" ]]; then
            displayas="$m"
            continue
          fi
        fi
        if [[ -z "$showas" ]]; then
          m="$(_map_showas "$tok")"
          if [[ -n "$m" ]]; then
            showas="$m"
            continue
          fi
        fi

        # Unknown token (ignored but logged)
        echo "WARN: Unknown dir token '$tok' in '$raw' - ignored" >&2
      done
    fi

    # Defaults when omitted
    arrangement="${arrangement:-1}" # name
    displayas="${displayas:-0}"     # stack
    showas="${showas:-2}"           # grid

    #echo "$path_name" "$arrangement" "$displayas" "$showas"
    printf "%s\t%s\t%s\t%s\n" "$path_name" "$arrangement" "$displayas" "$showas"
  }

  # --------------- Helpers ---------------
  run_as_user() {
    if [[ $__dry_run -eq 1 ]]; then
      echo "[dry-run] $*"
      return 0
    fi
    if [[ "$EUID" -eq 0 ]]; then
      launchctl asuser "$uid" sudo -u "$current_user" "$@"
    else
      "$@"
    fi
  }

  add_spacer() {
    local spacer_type="$1"
    case "$spacer_type" in
    "small-spacer") spacer_type="small-spacer-tile" ;;
    "flex-spacer") spacer_type="flex-spacer-tile" ;;
    *) spacer_type="spacer-tile" ;;
    esac
    echo "Adding Dock spacer: $spacer_type"
    run_as_user defaults write com.apple.dock persistent-apps -array-add \
      "<dict><key>tile-type</key><string>$spacer_type</string></dict>"
  }

  add_folder() {
    local path="$1"
    local label="$2"
    local arrangement="${3:-1}" # Name
    local displayas="${4:-0}"   # Stack
    local showas="${5:-2}"      # Grid

    if [[ ! -d "$path" ]]; then
      echo "Folder does not exist, skipping: $path"
      return 1
    fi

    echo "Adding folder: $label ($path) [arrangement=$arrangement, displayas=$displayas, showas=$showas]"
    run_as_user defaults write com.apple.dock persistent-others -array-add \
      "<dict>
         <key>tile-data</key>
         <dict>
           <key>file-data</key>
           <dict>
             <key>_CFURLString</key><string>file://$path</string>
             <key>_CFURLStringType</key><integer>15</integer>
           </dict>
           <key>file-label</key><string>$label</string>
           <key>arrangement</key><integer>$arrangement</integer>
           <key>displayas</key><integer>$displayas</integer>
           <key>showas</key><integer>$showas</integer>
         </dict>
         <key>tile-type</key><string>directory-tile</string>
       </dict>"
  }

  add_app() {
    local app_path="$1"
    if [[ ! -e "$app_path" ]]; then
      echo "Application does not exist, skipping: $app_path"
      return 1
    fi

    echo "Adding app: $app_path"
    run_as_user defaults write com.apple.dock persistent-apps -array-add \
      "<dict>
         <key>tile-data</key>
         <dict>
           <key>file-data</key>
           <dict>
             <key>_CFURLString</key><string>file://$app_path</string>
             <key>_CFURLStringType</key><integer>15</integer>
           </dict>
         </dict>
       </dict>"
  }

  # --------------- Clear (unless --append) ---------------
  if [[ $__append -eq 0 ]]; then
    echo "Clearing existing Dock configuration"
    run_as_user defaults delete com.apple.dock persistent-apps 2>/dev/null || true
    run_as_user defaults delete com.apple.dock persistent-others 2>/dev/null || true
  else
    echo "Appending to existing Dock configuration (no clear)"
  fi

  # --------------- Apply items (resilient) ---------------
  echo "Adding items to Dock"
  local item
  local successes=0
  local failures=0

  for item in "${dock_items[@]}"; do
    if [[ "$item" == /* ]]; then
      # Absolute path -> app
      if ! add_app "$item"; then
        echo "WARN: Failed to add app (or not found): $item - continuing"
        failures=$((failures + 1))
        continue
      fi
      successes=$((successes + 1))

    elif [[ "$item" == "spacer"* ]] || [[ "$item" == *"-spacer" ]]; then
      # Spacer tiles
      if ! add_spacer "$item"; then
        echo "WARN: Failed to add spacer: $item - continuing"
        failures=$((failures + 1))
        continue
      fi
      successes=$((successes + 1))

    elif [[ "$item" == dir-* ]]; then
      # Parse dir item with tokens or legacy numeric
      #read -r path_name arrangement displayas showas < <(_parse_dir_item "$item")
      IFS=$'\t' read -r path_name arrangement displayas showas < <(_parse_dir_item "$item")

      local path
      if [[ "$path_name" == /* ]]; then
        path="$path_name"
      else
        case "$path_name" in
        "Downloads") path="$user_home/Downloads" ;;
        "Applications") path="/Applications" ;;
        "Documents") path="$user_home/Documents" ;;
        "Desktop") path="$user_home/Desktop" ;;
        *) path="$user_home/$path_name" ;;
        esac
      fi

      local label
      label=$(basename "$path")

      if ! add_folder "$path" "$label" "$arrangement" "$displayas" "$showas"; then
        echo "WARN: Failed to add folder/stack: $item (resolved: $path) - continuing"
        failures=$((failures + 1))
        continue
      fi
      successes=$((successes + 1))

    else
      echo "WARN: Unknown dock item format: $item - continuing"
      failures=$((failures + 1))
      continue
    fi
  done

  echo "Summary: $successes item(s) added, $failures failed."

  # If everything failed, signal an error so callers can detect it
  if [[ $successes -eq 0 ]]; then
    echo "ERROR: No items were successfully added to the Dock."
    return 1
  fi

  # --------------- Restart Dock (unless suppressed or dry-run) ---------------
  if [[ $__dry_run -eq 1 ]]; then
    echo "[dry-run] Skipping Dock restart"
  elif [[ $__no_restart -eq 1 ]]; then
    echo "Skipping Dock restart (--no-restart)"
  else
    echo "Restarting Dock to apply changes"
    killall -KILL Dock 2>/dev/null || true
    sleep 2
  fi

  return 0
}

# Show a parametrized SwiftDialog popup for user-action prompts (e.g. OS
# consent flows). Always launched with --timer so an unattended run cannot
# strand the orchestrator past Intune's ~1h script timeout. Treats both
# button-click (exit 0) and timer expiry (exit 4) as success - the consent
# step is best-effort and the caller marks it done either way.
#
# Usage:
#   show_action_dialog --title TITLE --message MSG \
#                      [--button DONE] [--icon PATH] \
#                      [--timer SEC] [--width N] [--height N] \
#                      [--position POS] [--messagefont SPEC]
show_action_dialog() {
  local title="" message="" button="Done"
  local icon="${CONFIG_DIR:-/Library/Application Support/Microsoft/IntuneScripts}/Swift Dialog/icons/settings.png"
  local timer=600 width=540 height=420 position="bottomright" messagefont="size=14"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)        title="$2"; shift 2 ;;
      --message)      message="$2"; shift 2 ;;
      --button)       button="$2"; shift 2 ;;
      --icon)         icon="$2"; shift 2 ;;
      --timer)        timer="$2"; shift 2 ;;
      --width)        width="$2"; shift 2 ;;
      --height)       height="$2"; shift 2 ;;
      --position)     position="$2"; shift 2 ;;
      --messagefont)  messagefont="$2"; shift 2 ;;
      *) echo "show_action_dialog: unknown option: $1" >&2; return 2 ;;
    esac
  done

  if [[ -z "$title" || -z "$message" ]]; then
    echo "show_action_dialog: --title and --message are required" >&2
    return 2
  fi

  /usr/local/bin/dialog \
    --title "$title" \
    --message "$message" \
    --button1text "$button" \
    --moveable --ontop \
    --width "$width" --height "$height" \
    --position "$position" \
    --icon "$icon" \
    --messagefont "$messagefont" \
    --timer "$timer"
  local rc=$?
  case "$rc" in
    0|4) return 0 ;;
    *)   return "$rc" ;;
  esac
}

# Add or remove a Login Items entry for an application bundle. Idempotent on
# add (re-running does not produce duplicates). Run via `user:` so the entry
# lands in the console user's login items, not root's.
#
# Usage:
#   set_login_item /Applications/OneDrive.app                  # add, visible
#   set_login_item /Applications/OneDrive.app --hidden true    # add, hidden
#   set_login_item --remove /Applications/OneDrive.app         # remove
set_login_item() {
  local action="add" path="" hidden="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove) action="remove"; shift ;;
      --hidden) hidden="$2"; shift 2 ;;
      *)
        if [[ -z "$path" ]]; then
          path="$1"
        else
          echo "set_login_item: unexpected argument: $1" >&2
          return 2
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$path" ]]; then
    echo "set_login_item: app path is required" >&2
    return 2
  fi

  case "$action" in
    add)
      /usr/bin/osascript <<EOF
tell application "System Events"
  if not ((path of every login item) contains "$path") then
    make login item at end with properties {path:"$path", hidden:$hidden}
  end if
end tell
EOF
      ;;
    remove)
      /usr/bin/osascript <<EOF
tell application "System Events"
  delete (every login item whose path is "$path")
end tell
EOF
      ;;
  esac
}