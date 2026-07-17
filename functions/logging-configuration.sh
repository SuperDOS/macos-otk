#!/bin/bash

# =============================================================================
# LOGGING & ERROR HANDLING
# =============================================================================

log_level() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local caller="${FUNCNAME[2]:-main}"

    # Construct log output
    local log_entry="[$timestamp] [$level] [$caller] $message"

    # Print to console
    echo "$log_entry"

    # Write to file only if LOG_DIR is defined. Suppress and ignore failures so
    # a user-context child shell (which cannot write to the root-owned log) does
    # not trip `set -e` in the caller's payload.
    if [[ -n "${LOG_DIR:-}" ]] && [[ -d "$LOG_DIR" ]]; then
        echo "$log_entry" >>"$LOG_DIR/onboarding.log" 2>/dev/null || true
    fi

    # Also log to system log
    logger -t "OnboardingSystem" "[$level] $message"
}

log_info() { log_level "INFO" "$1"; }
log_warn() { log_level "WARN" "$1"; }
log_error() { log_level "ERROR" "$1"; }
log_debug() {
    # Must always return 0. Otherwise, when DEBUG is not "true" the conditional
    # falls through and the function inherits the [[ ]] exit code of 1 - under
    # `set -euo pipefail` in execute_commands' child payload, that aborts any
    # custom command that calls log_debug (e.g. rename_device's "Current name:"
    # line) at the first such call, with no further log output to point at it.
    [[ "${DEBUG:-false}" == "true" ]] && log_level "DEBUG" "$1"
    return 0
}

# Write a SwiftDialog-compatible status event to the log file.
# Uses the "shell" preset format: [STATUS] <text>
# SwiftDialog's logMonitor (preset: "shell") watches LOG_DIR/onboarding.log and
# parses lines matching "^\[STATUS\]\s*(.+)$". autoMatch routes by finding the
# app's displayName in the captured text - e.g. "Downloading Google Chrome"
# routes to the googlechrome row automatically.
#
# Usage: log_status_event <item_id> <keyword> <app_display_name>
#   keyword: Downloading | Installing | Configuring | Installed | Error | Skipped
#
# NOTE: "Installed" intentionally writes nothing to the log. The green check mark
# comes from SwiftDialog's FSEvent on the plist write (state=installed). Emitting
# a logMonitor status for completion would race with the FSEvent and risk a brief
# conflict. The plist is the single source of truth for success.
log_status_event() {
    local item_id="${1:-}"
    local keyword="${2:-}"
    local app_name="${3:-}"

    # Requires LOG_DIR to be set and the log file's parent directory to exist
    [[ -z "${LOG_DIR:-}" ]] && return 0

    local action_text
    case "$keyword" in
        Waiting)      action_text="Waiting for $app_name" ;;
        Downloading)  action_text="Downloading $app_name" ;;
        Installing)   action_text="Installing $app_name" ;;
        Configuring)  action_text="Configuring $app_name" ;;
        Installed)
            # Let the plist FSEvent handle the success icon - no logMonitor line needed
            return 0
            ;;
        Error)        action_text="Failed: $app_name" ;;
        Skipped)      action_text="Skipped: $app_name" ;;
        *)            action_text="$keyword $app_name" ;;
    esac

    # Write [STATUS] line - SwiftDialog shell preset picks this up via logMonitor
    echo "[STATUS] ${action_text}" >> "$LOG_DIR/onboarding.log" 2>/dev/null || true
    log_debug "log_status_event: [STATUS] ${action_text} (item: $item_id)"
}

handle_error() {
    local exit_code="$1"
    local error_message="$2"
    local cleanup_function="${3:-cleanup_temp_files}"

    log_error "$error_message"
    dialog_manager error "$error_message"

    # Prevent cleanup if needed
    SKIP_CLEANUP=true

    if [[ -n "$cleanup_function" ]] && declare -f "$cleanup_function" >/dev/null; then
        "$cleanup_function"
    fi

    exit "$exit_code"
}

cleanup_temp_files() {
    # SKIP_CLEANUP is only set (to true) by handle_error. Default to false so
    # the normal-run cleanup path is unambiguous instead of relying on an empty
    # string ≠ "false" coincidence.
    if [[ "${SKIP_CLEANUP:-false}" == "false" ]]; then
        log_info "Cleaning up temporary files..."
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    else
        log_info "Skipping cleanup of temporary files (flag set to true)"
    fi
}