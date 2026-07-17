#!/bin/bash
# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

clear_all_notifications() {

  osascript -l JavaScript << 'JXA'
"use strict";

function run() {
  const CurrentApplication = (() => {
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;
    return app;
  })();
  const SystemEvents = Application("System Events");
  const NotificationCenter = SystemEvents.processes.byName("NotificationCenter");
  const macOSSequoiaOrGreater = parseFloat(CurrentApplication.systemInfo().systemVersion) >= 15.0;

  const notificationGroups = () => {
    const windows = NotificationCenter.windows;
    if (windows.length === 0) {
      return [];
    }

    return macOSSequoiaOrGreater
      ? windows.at(0).groups.at(0).groups.at(0).scrollAreas.at(0).groups().at(0).uiElements()
          .concat(windows.at(0).groups.at(0).groups.at(0).scrollAreas.at(0).groups())
      : windows.at(0).groups.at(0).scrollAreas.at(0).uiElements.at(0).groups();
  };

  const findCloseAction = group => {
    const [clearAll, close] = group.actions().reduce(
      (matches, action) => {
        switch (action.description()) {
          case "Clear All":
            return [action, matches[1]];
          case "Close":
            return [matches[0], action];
          default:
            return matches;
        }
      },
      [null, null]
    );
    return clearAll ?? close;
  };

  const actions = notificationGroups().map(findCloseAction);
  for (const action of actions) {
    action?.perform();
  }
}
JXA

}

wait_for_process() {
  local process_name="$1"
  local timeout="${2:-300}"
  local terminate="${3:-false}"

  log_info "Waiting for process '$process_name' to complete (timeout: ${timeout}s)"

  local start_time=$(date +%s)

  while pgrep -x "$process_name" > /dev/null 2>&1; do
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))

    if [[ $elapsed -ge $timeout ]]; then
      if [[ "$terminate" == "true" ]]; then
        log_warn "Terminating process '$process_name' after timeout"
        pkill -f "$process_name" || true
        sleep 2
        pkill -9 -f "$process_name" || true
        return 2
      else
        log_error "Process '$process_name' did not complete within ${timeout}s"
        return 1
      fi
    fi
    log_debug "Waiting for '$process_name' to complete... (${elapsed}s elapsed)"
    sleep 5
  done

  log_info "Process '$process_name' completed successfully"
  return 0
}

wait_for_desktop() {
  log_info "Waiting for desktop environment to be ready..."

  local start_time
  start_time=$(date +%s)
  local timeout=300 # 5 minutes

  while :; do
    local current_user
    current_user=$( /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" \
      | /usr/bin/awk '/Name :/ { print $3 }' )

    if [[ -n "$current_user" \
       && "$current_user" != "root" \
       && "$current_user" != "loginwindow" \
       && "$current_user" != "_mbsetupuser" ]] \
       && pgrep -xq "Dock" \
       && pgrep -xq "Finder"; then
      log_info "Desktop environment is ready (console user: $current_user)"
      return 0
    fi

    local elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed >= timeout )); then
      log_error "Desktop not ready after ${timeout}s (last console user: '${current_user:-<none>}')"
      return 1
    fi

    local delay=$(( RANDOM % 10 + 5 )) # Random delay 5-15 seconds
    log_debug "Desktop not ready (user='${current_user:-<none>}'), waiting ${delay}s... (${elapsed}s elapsed)"
    sleep "$delay"
  done
}

get_current_user() {
  local user
  user=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" \
    | /usr/bin/awk '/Name :/ && ! /loginwindow/ && ! /root/ && ! /_mbsetupuser/ { print $3 }' \
    | /usr/bin/awk -F '@' '{print $1}')

  if [[ -z "$user" ]]; then
    # Fallback: last logged-in non-system user (ac -p is unavailable on modern macOS)
    # Skip macOS `last` synthetic entries: reboot, wtmp, shutdown, and any
    # row starting with `~` (older systems used `~` for the boot marker).
    user=$(last -1 | awk 'NR==1 && $1 !~ /^(reboot|wtmp|shutdown)$/ && $1 !~ /^~/ {print $1}')
  fi

  echo "$user"
}

kill_application() {
  local app_name="$1"

  if pgrep -x "$app_name" > /dev/null 2>&1; then
    log_info "Terminating application: $app_name"

    # Try graceful termination first
    pkill -TERM "$app_name" || true
    sleep 3

    # Force kill if still running
    if pgrep -x "$app_name" > /dev/null 2>&1; then
      log_warn "Force killing application: $app_name"
      pkill -KILL "$app_name" || true
    fi

    log_info "Application terminated: $app_name"
  else
    log_debug "Application not running: $app_name"
  fi
}

retry_with_backoff() {
  local max_attempts="$1"
  local base_delay="$2"
  local operation="$3"
  shift 3

  local attempt=1
  local delay="$base_delay"

  while [[ $attempt -le $max_attempts ]]; do
    log_debug "Attempting operation (attempt $attempt/$max_attempts): $operation"

    if "$operation" "$@"; then
      log_info "Operation succeeded on attempt $attempt"
      return 0
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      log_warn "Operation failed (attempt $attempt), retrying in ${delay}s..."
      sleep "$delay"
      delay=$((delay * 2)) # Exponential backoff
    fi

    attempt=$((attempt + 1))
  done

  log_error "Operation failed after $max_attempts attempts"
  return 1
}

check_enrollment_timing() {
  if [[ "$CHECK_ENROLLMENT_TIME" != "true" ]]; then
    log_info "Enrollment time check disabled"
    return 0
  fi

  log_info "Checking enrollment timing..."

  # Note: the new-flag idempotency gate now lives unconditionally at the top of
  # main() in onboardingProcess.sh; we no longer re-check it here.

  # Get MDM profile installation time
  local profile_output=$(profiles -P -v 2> /dev/null | grep -A 10 "Management Profile" || true)
  if [[ -z "$profile_output" ]]; then
    log_warn "No MDM profile found, proceeding with onboarding"
    return 0
  fi

  local install_date=$(echo "$profile_output" | grep -oE 'installationDate:.*' | cut -d' ' -f2-)
  if [[ -z "$install_date" ]]; then
    log_warn "Could not determine MDM installation date, proceeding with onboarding"
    return 0
  fi

  local install_date_seconds=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$install_date" "+%s" 2> /dev/null || echo "0")
  local current_time_seconds=$(date "+%s")
  local time_difference_hours=$(((current_time_seconds - install_date_seconds) / 3600))

  log_info "MDM enrolled $time_difference_hours hours ago (limit: $ENROLLMENT_WINDOW_HOURS hours)"

  if [[ $time_difference_hours -gt $ENROLLMENT_WINDOW_HOURS ]]; then
    log_info "Device enrolled more than $ENROLLMENT_WINDOW_HOURS hours ago, creating flag and exiting"
    touch "$ONBOARDING_DIR/onboarding.flag"
    return 1
  fi

  log_info "Device enrolled within window, proceeding with onboarding"
  return 0
}

generate_random_string() {
  local length="$1"
  LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c "$length"
  echo
}