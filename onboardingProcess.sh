#!/bin/bash

# =============================================================================
# macOS Onboarding System
# =============================================================================

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- DYNAMIC ROOT CONFIGURATION ---
# Default to system path
ONBOARDING_ROOT="/Library/Application Support/Microsoft/IntuneScripts"

# Pre-scan arguments to override root before setting constants
argv=("$@")
for ((i = 0; i < ${#argv[@]}; i++)); do
  if [[ "${argv[i]}" == "--root" ]]; then
    ONBOARDING_ROOT="${argv[i + 1]}"
    break
  fi
done

# Define paths relative to the dynamic root
readonly CONFIG_DIR="$ONBOARDING_ROOT"
readonly ONBOARDING_DIR="$CONFIG_DIR/onBoarding"
readonly STATE_DIR="$CONFIG_DIR/state"
readonly LOG_DIR="$CONFIG_DIR/logs"
# ----------------------------------

# --- ROOT CHECK ---
# Must run before any mkdir / mktemp / sudo because the parse-time blocks below
# touch /Library/Application Support/... and call `sudo -u <console_user> ...`.
# A non-root invocation that fell through to those would either fail confusingly
# (mkdir permission denied) or block on a sudo password prompt. The duplicate
# guard inside main() is left as defense-in-depth.
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)" >&2
  exit 1
fi
# ------------------

# --- CREATE DIRECTORIES IMMEDIATELY ---
# We must create these NOW because argument parsing (which happens before main)
# uses log_info, which requires the log directory to exist.
required_dirs=("$CONFIG_DIR" "$ONBOARDING_DIR" "$STATE_DIR" "$LOG_DIR")
for dir in "${required_dirs[@]}"; do
  [[ ! -d "$dir" ]] && mkdir -p "$dir"
done
# ----------------------------------------------------

#Create TEMP_DIR in the context of the logged-in user
current_user=$(stat -f "%Su" /dev/console)
user_temp_dir=$(sudo -u "$current_user" getconf DARWIN_USER_TEMP_DIR | sed 's:/*$::')
TEMP_DIR=$(mktemp -d "${user_temp_dir}/onboarding.XXXXXX")
mkdir -p "$TEMP_DIR"
chmod 755 "$TEMP_DIR"

#keep tally on the apps/configs
export installed_count=0
export skipped_count=0
export failed_count=0

# Configuration files
readonly APPS_JSON="$SCRIPT_DIR/apps.json"
readonly SWIFT_DIALOG_CONFIG="$CONFIG_DIR/Swift Dialog/swiftdialog.json"

# Default configuration (can be overridden by config file)
export SILENT_MODE=${SILENT_MODE:-false}
export DRY_RUN=${DRY_RUN:-false}
export DOWNLOAD_TIMEOUT=$(jq -r '.global_settings.default_dl_timeout // 300' "$APPS_JSON")
export MAX_RETRY_ATTEMPTS=$(jq -r '.global_settings.default_retries // 3' "$APPS_JSON")
export RETRY_BASE_DELAY=$(jq -r '.global_settings.default_retry_delay // 5' "$APPS_JSON")
export ENROLLMENT_WINDOW_HOURS=1
export CHECK_ENROLLMENT_TIME=false

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_MISSING_DEPS=2
readonly EXIT_CONFIG_ERROR=3
readonly EXIT_NETWORK_ERROR=4
readonly EXIT_INSTALL_ERROR=5

# Source all function files
source_functions() {
  local functions_dir="$SCRIPT_DIR/functions"

  if [[ ! -d "$functions_dir" ]]; then
    # Fallback: try looking in the root if functions aren't in onBoarding subdir
    # This handles cases where structure varies slightly in temp runs
    if [[ -d "$CONFIG_DIR/functions" ]]; then
      functions_dir="$CONFIG_DIR/functions"
    else
      echo "Functions directory not found: $functions_dir" >&2
      return 1
    fi
  fi

  local file_count=0
  for file in "$functions_dir"/*.sh; do
    [[ -f "$file" ]] || continue

    if source "$file"; then
      ((file_count++))
      [[ -n "${DEBUG:-}" ]] && echo "Sourced: $(basename "$file")"
    else
      echo "Failed to source: $(basename "$file")" >&2
      return 1
    fi
  done

  if [[ $file_count -eq 0 ]]; then
    echo "No function files found in $functions_dir" >&2
    return 1
  fi

  echo "Successfully sourced $file_count function files"
  return 0
}

# Use it in main
if ! source_functions; then
  exit $EXIT_CONFIG_ERROR
fi

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
  log_info "Starting macOS Onboarding System"

  # Backward compat: machines onboarded by the previous version wrote a flag at
  # /var/db/.onboardingdone. Migrate it to the new path and exit so we don't
  # re-onboard already-provisioned devices.
  if [[ -f "/var/db/.onboardingdone" && ! -f "$ONBOARDING_DIR/onboarding.flag" ]]; then
    log_info "Legacy completion flag found at /var/db/.onboardingdone - migrating to $ONBOARDING_DIR/onboarding.flag and exiting"
    mkdir -p "$ONBOARDING_DIR"
    touch "$ONBOARDING_DIR/onboarding.flag"
    exit $EXIT_SUCCESS
  fi

  # Idempotency gate: skip if onboarding already completed. Use --force to re-run.
  if [[ -f "$ONBOARDING_DIR/onboarding.flag" ]]; then
    log_info "Onboarding already completed (flag at $ONBOARDING_DIR/onboarding.flag). Use --force to re-run."
    exit $EXIT_SUCCESS
  fi

  # Check enrollment timing
  if ! check_enrollment_timing; then
    log_info "Enrollment timing check failed, exiting"
    exit $EXIT_SUCCESS
  fi

  # --- Process prerequisites from apps.json (no state/UI) ---
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Dry-run: skipping prerequisites phase"
  else
    if ! process_prerequisites; then
      log_warn "One or more prerequisites failed. Continuing..."
    fi
  fi

  [[ "${DRY_RUN}" == "true" ]] && log_info "Dry-run: UI and progress will reflect simulation only"

  # Wait for desktop to be ready
  wait_for_desktop

  # Create a pseudo app_config object for global kill_apps_pre
  global_kill_config=$(jq -c '{name: "Global Cleanup", kill_apps: .global_settings.kill_apps_pre}' "$APPS_JSON")

  if [[ $(echo "$global_kill_config" | jq '.kill_apps | length') -gt 0 ]]; then
    kill_applications "$global_kill_config"
  else
    log_info "No applications to kill in kill_apps_pre or setting is missing."
  fi

  #Clean up unused plists
  cleanup_stale_plists

  # Initialize state file structure
  if initialize_state_file_with_detection; then
    log_info "State File initialized successfully"
  fi

  # Initialize SwiftDialog
  # Skip dialog UI if in silent mode
  if [[ "$SILENT_MODE" != "true" ]]; then
    dialog_manager init

    # Wait for SwiftDialog to start
    log_info "Waiting for SwiftDialog to start..."

    if [[ -f "$STATE_DIR/dialog.pid" ]]; then
      local dialogpid=$(cat "$STATE_DIR/dialog.pid")
      local start_time=$(date +%s)

      log_info "Waiting for SwiftDialog (PID $dialogpid) to start..."
      while ! ps -p "$dialogpid" >/dev/null 2>&1; do
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge 60 ]]; then
          log_warn "SwiftDialog did not start within 60 seconds, continuing anyway"
          break
        fi
        sleep 2
      done

      if ps -p "$dialogpid" >/dev/null 2>&1; then
        log_info "SwiftDialog is running (PID $dialogpid)"
      fi
    else
      log_warn "SwiftDialog PID file not found at $STATE_DIR/dialog.pid - dialog_manager init may have failed; continuing without UI tracking"
    fi
  fi

  # Process all applications
  local install_result=0
  if ! process_applications; then
    install_result=1
    log_warn "Some applications failed to install"
  fi

  # Finalize dialog
  if [[ $install_result -eq 0 ]]; then
    sleep 1

    # Create a pseudo app_config object for global kill_apps_post
    global_kill_config=$(jq -c '{name: "Global Cleanup", kill_apps: .global_settings.kill_apps_post}' "$APPS_JSON")

    if [[ $(echo "$global_kill_config" | jq '.kill_apps | length') -gt 0 ]]; then
      kill_applications "$global_kill_config"
    else
      log_info "No applications to kill in kill_apps_post or setting is missing."
    fi

  else
    sleep 1
  fi

  # Finalize: force every per-item plist to its compliant state so SwiftDialog
  # inspect mode considers all items "complete" and fires autoEnableButton
  # (button text → autoEnableButtonText, button enabled). This is the
  # documented mechanism - https://swiftdialog.app/advanced/inspect-mode/ -
  # and intentionally collapses pass/fail into "done" at the per-item visual
  # level so the user can always dismiss the dialog.
  #
  # No textual summary is posted. Inspect mode is the completion UI: when the
  # run finishes the user sees the card layout with every processed item and an
  # enabled close button. (The "message:" summary was a pre-inspect-mode
  # leftover.) The command file is still created in swift-dialog.sh because
  # apps.json items use it for hide:/show: control during installs.
  log_info "Finalizing dialog (install_result=$install_result)"
  force_compliant_state_for_all_items

  # clear all notifications
  clear_all_notifications

  # Wait for SwiftDialog to exit and capture its exit code
  if [[ -f "$STATE_DIR/dialog.pid" ]]; then
    dialog_pid=$(cat "$STATE_DIR/dialog.pid")
    wait "$dialog_pid"
    dialogResults=$?
  else
    log_warn "Dialog PID not found, assuming user exited manually"
    dialogResults=1
  fi

  # On primary-button click (exit 0) AND a fully-successful run, perform the
  # configured post-completion action. Configurable via
  # swift_dialog_settings.primary_button_action:
  #   "reboot" (default) - restart the Mac via loginwindow.
  #   "close"            - just close the dialog and exit cleanly.
  # Reboot is intentionally gated on install_result == 0: on failure the
  # button text becomes "Continue" (above) and the click also returns 0, but
  # rebooting a half-onboarded machine is the wrong default - the user is
  # acknowledging the failed run shown in the dialog, not asking to restart.
  if [[ "$dialogResults" -eq 0 && "$install_result" -eq 0 && "${DRY_RUN:-false}" != "true" ]]; then
    [[ -f "$STATE_DIR/dialog.pid" ]] && rm -f "$STATE_DIR/dialog.pid"

    local button_action
    button_action=$(jq -r '.swift_dialog_settings.primary_button_action // "reboot"' "$APPS_JSON")
    case "$button_action" in
      close)
        log_info "Primary button: close action - dialog closed, no reboot."
        ;;
      reboot|*)
        if [[ "$button_action" != "reboot" ]]; then
          log_warn "Unknown primary_button_action '$button_action' - defaulting to reboot."
        fi
        log_info "User confirmed reboot, triggering system restart..."
        osascript -e 'tell application "loginwindow" to «event aevtrrst»'
        ;;
    esac
  fi


  #Clear Temp dir
  [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  log_info "Cleaned up temporary files"

  # Create completion flag only on full success
  if [[ $install_result -eq 0 ]]; then
    touch "$ONBOARDING_DIR/onboarding.flag"
  fi

  log_info "Onboarding completed (exit code: $install_result)"

  exit $install_result
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

# Trap signals
trap on_interrupt INT
trap cleanup_temp_files EXIT TERM

on_interrupt() {
  log_warn "Interrupt received (CTRL+C). Skipping cleanup to preserve logs..."

  # Kill SwiftDialog using PID file if available
  if [[ -f "$STATE_DIR/dialog.pid" ]]; then
    dialog_pid=$(cat "$STATE_DIR/dialog.pid")
    if ps -p "$dialog_pid" >/dev/null 2>&1; then
      kill "$dialog_pid"
      log_info "SwiftDialog process (PID $dialog_pid) terminated via PID file."
    else
      log_warn "PID from dialog.pid not running. Attempting fallback kill..."
    fi
  fi

  # Fallback: kill by process name if PID file failed
  if pgrep -f "Dialog.app/Contents/MacOS/Dialog" >/dev/null 2>&1; then
    pkill -f "Dialog.app/Contents/MacOS/Dialog"
    log_info "SwiftDialog process terminated via fallback match."
  fi

  # Remove PID file only after killing
  [[ -f "$STATE_DIR/dialog.pid" ]] && rm -f "$STATE_DIR/dialog.pid"

  exit 130
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit $EXIT_GENERAL_ERROR
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
  --root)
    # Handled in pre-scan, just shift past the value
    shift 2
    ;;
  --debug)
    export DEBUG=true
    # This log_info CALL is what was failing before!
    log_info "Debug mode enabled"
    shift
    ;;
  --force)
    rm -f "$ONBOARDING_DIR/onboarding.flag"
    rm -f "/var/db/.onboardingdone"
    log_info "Force mode: removed completion flag (new + legacy)"
    shift
    ;;
  --dry-run | -n)
    export DRY_RUN=true
    log_info "Dry-run mode enabled: URLs will be probed and detection commands executed; no downloads or installs will occur."
    shift
    ;;
  --silent | -s)
    export SILENT_MODE=true
    log_info "Silent mode enabled: No dialog will be shown"
    shift
    ;;
  --help | -h)
    cat <<EOF
macOS Onboarding System v0.1

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --debug                 Enable debug logging
    --force                 Force run even if already completed
    --dry-run, -n           Simulate run: probe URLs, execute detection, print commands only
                            No downloads, mounting, package installs, file writes, or system changes   
    --help                  Show this help message

DESCRIPTION:
    Automated installation system for macOS applications and configurations.
    Reads configuration from apps.json and installs applications using SwiftDialog for UI.

FILES:
    $APPS_JSON              - Application configuration
    $SWIFT_DIALOG_CONFIG    - SwiftDialog UI configuration

LOGS:
    $LOG_DIR/onboarding.log - Main log file

EOF
    exit 0
    ;;
  *)
    log_error "Unknown option: $1"
    exit $EXIT_GENERAL_ERROR
    ;;
  esac
done

# Start main function
main "$@"