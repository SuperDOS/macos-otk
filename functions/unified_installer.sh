#!/bin/bash

# =============================================================================
# DOWNLOAD MANAGER with Progress Tracking
# =============================================================================

is_application_installed() {
  local app_config="$1"
  local item_id
  item_id=$(get_item_id "$app_config")
  get_installation_state "$item_id" # This now updates plist internally
  [[ "$INSTALLATION_STATE" == "installed" ]]
}

# Get item ID from app config for progress updates
get_item_id() {
  local app_config="$1"
  echo "$app_config" | jq -r '.id // (.name | ascii_downcase | gsub("[^a-z0-9]+"; ""))'
}

# Probe one or more URLs (semicolon-separated). Returns 0 only if all pass.
probe_urls() {
  local urls="$1"
  IFS=';' read -ra url_array <<<"$urls"
  local failures=0
  for url in "${url_array[@]}"; do
    [[ -z "$url" ]] && continue
    log_info "Probing URL (HEAD): $url"
    if ! validate_url "$url"; then
      log_error "Invalid URL format: $url"
      failures=$((failures + 1))
      continue
    fi
    if test_url "$url"; then
      log_info "URL reachable: $url"
    else
      log_warn "URL NOT reachable: $url"
      failures=$((failures + 1))
    fi
  done
  [[ $failures -eq 0 ]]
}

download_file() {
  local urls="$1"
  local output_path="$2"
  local options="${3:-}"
  local item_id="${4:-}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    probe_urls "$urls"
    return $?
  fi

  IFS=';' read -ra url_array <<<"$urls"

  for url in "${url_array[@]}"; do
    [[ -z "$url" ]] && continue

    if ! test_url "$url"; then
      log_warn "URL not reachable: $url" >&2
      continue
    fi

    if ! validate_url "$url"; then
      log_error "Invalid URL format: $url" >&2
      continue
    fi

    log_info "Downloading: $url -> $output_path" >&2

    # Attempt download
    local download_success=false
    case "$url" in
    *sharepoint.com* | *redirect=*)
      if download_with_redirects "$url" "$output_path" "$item_id"; then
        download_success=true
      fi
      ;;
    *)
      if download_direct "$url" "$output_path" "$options" "$item_id"; then
        download_success=true
      fi
      ;;
    esac

    # Validate the download
    if [[ "$download_success" == "true" ]] && validate_download "$output_path"; then
      log_info "Successfully downloaded from: $url" >&2
      return 0
    else
      log_warn "Download failed for $url, trying next..." >&2
      # Clean up failed download
      [[ -f "$output_path" ]] && rm -f "$output_path"
    fi
  done

  log_error "All download attempts failed." >&2
  return 1
}

download_with_redirects() {
  local url="$1"
  local output_path="$2"

  log_debug "Handling redirect URL: $url"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry-run: would follow redirects and download to $output_path"
    return 0
  fi

  # Create unique temporary files to avoid conflicts
  local session_id="$$_$(date +%s%N)"
  local headers_file="$TEMP_DIR/headers_${session_id}.txt"
  local cookie_jar="$TEMP_DIR/cookies_${session_id}.txt"

  # Follow redirects and capture cookies
  if ! curl -s -D "$headers_file" -c "$cookie_jar" "$url" -o /dev/null; then
    log_error "Failed to follow redirects for: $url"
    rm -f "$cookie_jar" "$headers_file"
    return 1
  fi

  local redirect_url=$(grep -i '^Location:' "$headers_file" | awk '{print $2}' | tr -d '\r' | tail -1)
  local base_domain=$(echo "$url" | awk -F/ '{print $1 "//" $3}')

  if [[ -n "$redirect_url" ]]; then
    if [[ "$redirect_url" == /* ]]; then
      redirect_url="$base_domain$redirect_url"
    fi
    log_debug "Resolved redirect URL: $redirect_url"
  else
    redirect_url="$url"
    log_debug "No redirect detected, using original URL"
  fi

  # Download the actual file
  local success=false
  if curl -L -b "$cookie_jar" \
    --connect-timeout 30 \
    --max-time "${DOWNLOAD_TIMEOUT:-300}" \
    --retry "${MAX_RETRY_ATTEMPTS:-3}" \
    --retry-delay "${RETRY_BASE_DELAY:-5}" \
    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
    -o "$output_path" \
    "$redirect_url"; then
    success=true
  fi

  # Cleanup
  rm -f "$cookie_jar" "$headers_file"

  [[ "$success" == "true" ]]
}

download_direct() {
  local url="$1"
  local output_path="$2"
  local options="$3"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry-run: would download $url -> $output_path"
    return 0
  fi

  local download_success=false

  if [[ "$options" == *"use-curl"* ]] || ! command -v aria2c >/dev/null; then
    log_debug "Using curl for download"
    if curl -L --connect-timeout 30 --max-time "${DOWNLOAD_TIMEOUT:-300}" \
      --retry "${MAX_RETRY_ATTEMPTS:-3}" --retry-delay "${RETRY_BASE_DELAY:-5}" \
      -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
      -o "$output_path" "$url"; then
      download_success=true
    fi
  else
    log_debug "Trying aria2c for download"
    if aria2c -q -x16 -s16 \
      --dir="$(dirname "$output_path")" \
      --out="$(basename "$output_path")" \
      --connect-timeout=30 \
      --timeout="${DOWNLOAD_TIMEOUT:-300}" \
      --retry-wait="${RETRY_BASE_DELAY:-5}" \
      --max-tries="${MAX_RETRY_ATTEMPTS:-3}" \
      --header="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
      "$url"; then
      download_success=true
    else
      log_debug "aria2c failed, falling back to curl"
      if curl -L --connect-timeout 30 --max-time "${DOWNLOAD_TIMEOUT:-300}" \
        --retry "${MAX_RETRY_ATTEMPTS:-3}" --retry-delay "${RETRY_BASE_DELAY:-5}" \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -o "$output_path" "$url"; then
        download_success=true
      fi
    fi
  fi

  [[ "$download_success" == "true" ]]
}

validate_download() {
  local file_path="$1"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry-run: skipping file validation for $file_path"
    return 0
  fi

  if [[ ! -f "$file_path" ]]; then
    log_error "Download failed: file not found at $file_path"
    return 1
  fi

  if [[ ! -s "$file_path" ]]; then
    log_error "Download failed: file is empty at $file_path"
    return 1
  fi

  log_info "Download validation successful: $file_path ($(du -h "$file_path" | cut -f1))"
  return 0
}

validate_url() {
  local url="$1"

  if [[ ! "$url" =~ ^https?:// ]]; then
    log_error "Invalid URL format: $url"
    return 1
  fi

  return 0
}

test_url() {
  local url="$1"
  curl --head --silent --fail --connect-timeout 10 "$url" >/dev/null
  return $?
}

# =============================================================================
# UNIFIED INSTALLATION ENGINE with Inspect Mode Integration
# =============================================================================

process_app() {
  local app_config="$1"
  local app_name=$(echo "$app_config" | jq -r '.name')
  local app_type=$(echo "$app_config" | jq -r '.type // "unknown"')
  local item_id=$(get_item_id "$app_config")

  log_info "Processing app: $app_name ($app_type) [ID: $item_id]"

  if is_application_installed "$app_config"; then
    local status_msg="Already installed"
    [[ "$app_type" == "config" ]] && status_msg="Already configured"

    ((skipped_count++))
    return
  fi

  kill_applications "$app_config"

  if install_application "$app_config"; then
    local success_msg="Installed"
    [[ "$app_type" == "config" ]] && success_msg="Configured"
    # No log_status_event ... "Installed" by design - the plist FSEvent drives
    # the green check. See functions/logging-configuration.sh:71-74.
    ((installed_count++))
  else
    default_retries=$(jq -r '.global_settings.default_retries // 2' "$APPS_JSON")
    local retries=$(echo "$app_config" | jq -r --argjson def "$default_retries" '.retries // $def')

    if [[ $retries -gt 0 ]]; then
      log_info "Retrying $app_name (max retries: $retries)"
      # Hold off on [STATUS] Failed: until retries are exhausted - the SwiftDialog
      # shell logMonitor preset latches "Failed:" as a terminal row state, so
      # emitting it before a successful retry leaves the row stuck red.
      log_status_event "$item_id" "Installing" "$app_name"
      if retry_application_installation "$app_config" "$retries"; then
        ((installed_count++))
        return
      fi
    fi

    log_status_event "$item_id" "Error" "$app_name"
    ((failed_count++))
  fi
}

process_group() {
  local group_config="$1"
  local group_name=$(echo "$group_config" | jq -r '.name')
  local group_id=$(get_item_id "$group_config")
  local group_subtitle=$(echo "$group_config" | jq -r '.subtitle // "Processing group..."')
  local apps=$(echo "$group_config" | jq -c '.apps[]')

  log_info "Processing group: $group_name [ID: $group_id]"

  # Count total apps in group
  local total_apps=$(echo "$group_config" | jq '.apps | length')
  local current_app=0

  local group_success=0
  local group_failed=0

  while IFS= read -r app_config; do
    local app_name=$(echo "$app_config" | jq -r '.name')
    local app_id=$(get_item_id "$app_config")

    local app_type=$(echo "$app_config" | jq -r '.type // "installation"')

    if is_application_installed "$app_config"; then
      log_info "$app_name (ID: $app_id) already configured/installed"

      ((group_success++))
      ((skipped_count++))
      ((current_app++))

      continue
    fi

    # Prefix group_name so autoMatch routes the [STATUS] line to the
    # collapsed group row (no row exists for the individual sub-step).
    log_status_event "$app_id" "Installing" "$group_name: $app_name"
    kill_applications "$app_config"

    if install_application "$app_config"; then
      log_info "$app_name (ID: $app_id) processed successfully"
      # No log_status_event ... "Installed" by design - the green check is
      # driven by SwiftDialog's FSEvent on the plist write below. Emitting a
      # status line on completion would race the FSEvent. See the "Installed"
      # branch in functions/logging-configuration.sh:71-74.
      update_installation_state "$app_id" "installed"
      ((group_success++))
      ((installed_count++))
    else
      log_error "$app_name (ID: $app_id) failed"
      log_status_event "$app_id" "Error" "$group_name: $app_name"
      ((group_failed++))
      ((failed_count++))
    fi

    ((current_app++))

  done <<<"$apps"

  # Update group state based on completion
  if check_group_completion "$group_config"; then
    update_group_state "$group_id" "completed" "$group_config"
    log_info "Group $group_name (ID: $group_id) completed successfully"
  else
    update_group_state "$group_id" "partial" "$group_config"
    log_warn "Group $group_name (ID: $group_id) completed partially"
  fi
}

retry_application_installation() {
  local app_config="$1"
  local max_retries="$2"
  local app_name=$(echo "$app_config" | jq -r '.name')
  local item_id=$(get_item_id "$app_config")

  local attempt=1
  while [[ $attempt -le $max_retries ]]; do
    log_info "Retry attempt $attempt/$max_retries for $app_name"

    if install_application "$app_config"; then
      log_info "Retry successful for $app_name on attempt $attempt"
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ $attempt -le $max_retries ]]; then
      sleep $((attempt * 2))
    fi
  done

  log_error "All retry attempts failed for $app_name"

  return 1
}

# Unified installer function - handles all package types automatically
install_application() {
  local app_config="$1"
  local app_name=$(echo "$app_config" | jq -r '.name')
  local app_type=$(echo "$app_config" | jq -r '.type')
  local download_url=$(echo "$app_config" | jq -r '.download_url // empty')
  local item_id=$(get_item_id "$app_config")

  log_info "Installing application: $app_name (type: $app_type)"

  # ---------------------------
  # PRE-INSTALL
  # ---------------------------
  execute_commands "$app_config" "pre_install_commands" || {
    log_error "Pre-install commands failed for $app_name"
    update_installation_state "$item_id" "not_installed"
    return 1
  }

  # ---------------------------
  # DRY RUN
  # ---------------------------
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "DRY RUN: Simulating install for $app_name"

    if [[ -n "$download_url" && "$download_url" != "empty" ]]; then
      probe_urls "$download_url" || log_warn "URL unreachable for $app_name (dry run)"
    fi

    execute_commands "$app_config" "commands" || true
    execute_commands "$app_config" "post_install_commands" || true

    return 0
  fi

  # ---------------------------
  # DOWNLOAD (if applicable)
  # ---------------------------
  local package_file=""
  if [[ -n "$download_url" && "$download_url" != "empty" ]]; then
    log_status_event "$item_id" "Downloading" "$app_name"
    log_debug "Downloading package for $app_name"
    package_file=$(download_item "$app_config" 2>/dev/null)
    local download_exit=$?

    if [[ $download_exit -ne 0 || -z "$package_file" || ! -f "$package_file" ]]; then
      log_error "Download failed for $app_name"
      update_installation_state "$item_id" "not_installed"
      return 1
    fi
    log_info "Download complete: $package_file"
  fi

  # ---------------------------
  # INSTALL
  # ---------------------------
  if [[ "$app_type" == "installation" ]]; then
    log_status_event "$item_id" "Installing" "$app_name"

    if [[ -n "$package_file" ]]; then
      if ! install_package_file "$app_config" "$package_file"; then
        log_error "Package installation failed for $app_name"
        update_installation_state "$item_id" "not_installed"
        return 1
      fi
    else
      log_warn "Installation type app has no installer package: $app_name"
    fi

  else
    log_status_event "$item_id" "Installing" "$app_name"
    [[ -n "$package_file" ]] &&
      log_info "Downloaded asset file for $app_name (no installation step)"
  fi

  # ---------------------------
  # POST-INSTALL COMMANDS
  # ---------------------------
  execute_commands "$app_config" "post_install_commands" || {
    log_error "Post-install commands failed for $app_name"
    update_installation_state "$item_id" "not_installed"
    return 1
  }

  # ---------------------------
  # SUCCESS → WRITE INSTALLED
  # ---------------------------
  log_info "Successfully installed: $app_name"

  log_status_event "$item_id" "Installed" "$app_name"
  update_installation_state "$item_id" "installed"

  # Do NOT re-run get_installation_state here. The install pipeline (download
  # → install → post_install) all returned success, so the plist is the
  # authoritative record. Re-running detection at this point loses the race
  # for installs whose detection signal is asynchronous (e.g. Papercut's
  # `lpstat -v | grep papercut` - the Hive installer registers the print
  # queue in the background, so an immediate lpstat returns 1 and the helper
  # would overwrite the plist back to `not_installed`, stranding the
  # SwiftDialog row at "Installing $app_name". The next run's pre-install
  # detection re-evaluates from scratch, so idempotency is unaffected.

  return 0
}

sanitize_app_name() {
  local raw_name="$1"
  echo "$raw_name" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9._-]+/_/g'
}

# Download package and return path
download_item() {
  local app_config="$1"
  local app_name=$(echo "$app_config" | jq -r '.name')
  local download_url=$(echo "$app_config" | jq -r '.download_url')
  local download_path=$(echo "$app_config" | jq -r '.download_path // empty')
  local item_id=$(get_item_id "$app_config")

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry-run: would download package for: $app_name" >&2
    if probe_urls "$download_url" >&2; then
      echo "$TEMP_DIR/dry_run_${app_name// /_}.pkg"
      return 0
    else
      log_warn "One or more URLs are not reachable for $app_name" >&2
      return 1
    fi
  fi

  log_info "Downloading package for: $app_name" >&2

  # Decide download_path
  if [[ -n "$download_path" && "$download_path" != "empty" ]]; then
    if [[ "$download_path" == /* ]]; then
      : # absolute, leave as is
    else
      download_path="$TEMP_DIR/$download_path"
    fi
  else
    download_path="$TEMP_DIR/${item_id}.download"
  fi

  log_debug "Final download path: $download_path" >&2

  # Perform download with progress tracking
  if download_file "$download_url" "$download_path" "" "$item_id" >/dev/null 2>&1; then
    log_info "Package downloaded to: $download_path" >&2
    echo "$download_path"
    return 0
  else
    log_error "Failed to download package for: $app_name" >&2
    return 1
  fi
}

detect_package_type() {
  local file_path="$1"

  # Check if file exists
  if [[ ! -f "$file_path" ]]; then
    echo "UNKNOWN"
    return 1
  fi

  local filename=$(basename "$file_path")
  local dirname=$(dirname "$file_path")
  local lowername=$(echo "$filename" | tr '[:upper:]' '[:lower:]')

  local detected_type="UNKNOWN"

  # Step 1: Extension check (fast path)
  case "$lowername" in
  *.pkg) detected_type="PKG" ;;
  *.mpkg) detected_type="MPKG" ;;
  *.dmg) detected_type="DMG" ;;
  *.zip) detected_type="ZIP" ;;
  *.tar.gz | *.tgz) detected_type="TARGZ" ;;
  *.tar.bz2 | *.bz2) detected_type="BZ2" ;;
  *.tar.xz | *.txz) detected_type="XZ" ;;
  *.tar) detected_type="TAR" ;;
  *.7z) detected_type="7Z" ;;
  *.rar) detected_type="RAR" ;;
  esac

  # Step 2: Content-based detection if unknown
  if [[ "$detected_type" == "UNKNOWN" ]]; then
    local file_size=$(stat -f%z "$file_path" 2>/dev/null || echo "0")
    local header=$(xxd -l 16 -p "$file_path" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    case "$header" in
    504b0304*) detected_type="ZIP" ;; # ZIP
    1f8b08*) detected_type="TARGZ" ;; # GZIP
    425a68*) detected_type="BZ2" ;;   # BZIP2
    377abcaf*) detected_type="7Z" ;;  # 7z
    52617221*) detected_type="RAR" ;; # Rar! (v4 and v5)
    78617221*) detected_type="PKG" ;; # XAR/PKG
    esac

    # XZ vs DMG
    if [[ "$header" =~ ^fd377a58 ]]; then
      if command -v hdiutil >/dev/null 2>&1 && hdiutil imageinfo "$file_path" >/dev/null 2>&1; then
        detected_type="DMG"
      else
        local file_output=$(file -b "$file_path" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [[ "$file_output" =~ (apple.*disk|disk.*image|udif|ndif) ]]; then
          detected_type="DMG"
        else
          detected_type="XZ"
        fi
      fi
    fi

    # DMG trailer check (koly)
    if [[ $file_size -gt 512 && "$detected_type" == "UNKNOWN" ]]; then
      if tail -c 512 "$file_path" 2>/dev/null | xxd -p | grep -q "6b6f6c79"; then
        detected_type="DMG"
      fi
    fi

    # MIME fallback
    if [[ "$detected_type" == "UNKNOWN" ]]; then
      local mimetype=$(file --mime-type -b "$file_path" 2>/dev/null)
      case "$mimetype" in
      "application/x-apple-diskimage") detected_type="DMG" ;;
      "application/x-xar") detected_type="PKG" ;;
      "application/zip") detected_type="ZIP" ;;
      "application/x-bzip2") detected_type="BZ2" ;;
      "application/gzip" | "application/x-gzip") detected_type="TARGZ" ;;
      "application/x-xz") detected_type="XZ" ;;
      "application/x-7z-compressed") detected_type="7Z" ;;
      "application/x-rar" | "application/vnd.rar" | "application/x-rar-compressed") detected_type="RAR" ;;
      esac
    fi
  fi

  # --- New Step: Rename file if detected type has known extension ---
  local new_ext=""
  case "$detected_type" in
  PKG) new_ext="pkg" ;;
  MPKG) new_ext="mpkg" ;;
  DMG) new_ext="dmg" ;;
  ZIP) new_ext="zip" ;;
  TARGZ) new_ext="tar.gz" ;;
  BZ2) new_ext="tar.bz2" ;;
  XZ) new_ext="tar.xz" ;;
  TAR) new_ext="tar" ;;
  7Z) new_ext="7z" ;;
  RAR) new_ext="rar" ;;
  esac

  local new_path="$file_path"
  if [[ -n "$new_ext" ]]; then
    if [[ "$lowername" != *.$new_ext ]]; then
      new_path="$dirname/${filename%.*}.$new_ext"
      log_info "Renaming detected package: $file_path → $new_path" >&2
      mv -f "$file_path" "$new_path"

    fi
  fi

  # Print two values: type and final path
  echo "$detected_type|$new_path"
}

install_package_file() {
  local app_config="$1"
  local package_file="$2"
  local app_name=$(echo "$app_config" | jq -r '.name')

  log_info "Installing package file: $package_file"

  # Detect type and possibly rename
  local detection_result
  detection_result=$(detect_package_type "$package_file" | tail -n1)
  local package_type=$(echo "$detection_result" | cut -d'|' -f1)
  local final_package_file=$(echo "$detection_result" | cut -d'|' -f2)

  log_info "Detected package type: $package_type"
  if [[ "$final_package_file" != "$package_file" ]]; then
    log_info "Using renamed package file: $final_package_file"
  fi

  # archive_password only applies to the archive handler (zip/7z/rar). If it
  # is set on an item whose payload turns out to be a PKG or DMG, ignore it
  # loudly instead of failing - a copy-pasted item shouldn't break.
  local pw_set
  pw_set=$(echo "$app_config" | jq -r '.archive_password // empty')

  case "$package_type" in
  "PKG" | "MPKG")
    [[ -n "$pw_set" ]] && log_warn "archive_password is set but the payload is a PKG - ignoring it."
    install_pkg_file "$final_package_file" || return 1
    ;;
  "DMG")
    [[ -n "$pw_set" ]] && log_warn "archive_password is set but the payload is a DMG - ignoring it (encrypted DMGs are not supported)."
    install_dmg_file "$app_config" "$final_package_file" || return 1
    ;;
  "ZIP" | "BZ2" | "TAR" | "TARGZ" | "XZ" | "7Z" | "RAR")
    install_archive_file "$app_config" "$final_package_file" || return 1
    ;;
  "UNKNOWN")
    log_warn "Non-installable file detected ($final_package_file). Skipping installation step."
    return 2 # distinct non-installable exit
    ;;
  *)
    log_warn "Unsupported or asset file type: $package_type (skipping execution)"
    return 2 # distinct non-installable exit
    ;;
  esac
}

# Install PKG file
install_pkg_file() {
  local package_file="$1"

  log_info "Installing PKG: $package_file"
  wait_for_process "installer" 300

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry-run: would run 'installer -pkg \"$package_file\" -target /'"
    return 0
  fi

  if installer -pkg "$package_file" -target /; then
    log_info "PKG installation successful"
    return 0
  else
    log_error "PKG installation failed"
    return 1
  fi
}

# Install DMG file
install_dmg_file() {
  local app_config="$1"
  local package_file="$2"
  local app_name=$(echo "$app_config" | jq -r '.name')
  local destination=$(echo "$app_config" | jq -r '.install_path // "/Applications"')
  local app_path=$(echo "$app_config" | jq -r '.app_path // empty')

  log_info "Installing DMG: $package_file"

  local mount_point="$TEMP_DIR/mount_${app_name// /_}"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry-run: would mount $package_file at $mount_point, copy/install content, then detach"
    return 0
  fi

  # Mount the DMG
  if ! hdiutil attach -quiet -nobrowse -mountpoint "$mount_point" "$package_file"; then
    log_error "Failed to mount DMG: $package_file"
    return 1
  fi

  # Find installable content
  local success=false

  # First, try to find and install PKG files
  local pkg_files=($(find "$mount_point" \( -name "*.pkg" -o -name "*.mpkg" \) -type f))
  if [[ ${#pkg_files[@]} -gt 0 ]]; then
    log_info "Found PKG files in DMG, installing..."
    for pkg_file in "${pkg_files[@]}"; do
      if install_pkg_file "$pkg_file"; then
        success=true
      fi
    done
  fi

  # If no PKG files or PKG installation failed, try to find app bundles
  if [[ "$success" == "false" ]]; then
    local source_app
    if [[ -n "$app_path" && "$app_path" != "empty" ]]; then
      source_app="$mount_point/$app_path"
    else
      source_app=$(find "$mount_point" -name "*.app" -type d | head -1)
    fi

    if [[ -d "$source_app" ]]; then
      local app_bundle_name=$(basename "$source_app")
      local target_path="$destination/$app_bundle_name"

      log_info "Installing app bundle: $app_bundle_name"

      # Remove existing installation
      [[ -d "$target_path" ]] && rm -rf "$target_path"

      # Copy the app
      if cp -R "$source_app" "$destination/"; then
        chown -R root:wheel "$target_path"
        success=true
        log_info "App bundle installation successful"
      else
        log_error "Failed to copy app bundle"
      fi
    fi
  fi

  # Unmount
  hdiutil detach -quiet "$mount_point" || true

  if [[ "$success" == "true" ]]; then
    return 0
  else
    log_error "No installable content found in DMG"
    return 1
  fi
}

# Install archive files (zip, tar, bz2, tar.gz, xz, 7z, etc.)
install_archive_file() {
  local app_config="$1"
  local package_file="$2"
  local app_name=$(echo "$app_config" | jq -r '.name')
  local destination=$(echo "$app_config" | jq -r '.install_path // "/Applications"')
  local installer_name=$(echo "$app_config" | jq -r '.installer_name // empty')
  # Optional password for protected archives (zip/7z/rar). Note: apps.json is
  # world-readable on the device, so treat this as fleet-visible - fine for
  # AV-evasion wrappers, not for real secrets.
  local archive_password=$(echo "$app_config" | jq -r '.archive_password // empty')

  log_info "Installing archive: $package_file"

  # Debug information
  log_debug "Archive file exists: $(test -f "$package_file" && echo "yes" || echo "no")"
  if [[ -f "$package_file" ]]; then
    log_debug "Archive file size: $(ls -lh "$package_file" | awk '{print $5}')"
    log_debug "Archive file type: $(file "$package_file")"
  fi

  local extract_dir="$TEMP_DIR/extract_${app_name// /_}"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "Dry-run: would extract $package_file into $extract_dir and search for installers/app bundles"
    return 0
  fi

  # Remove existing extract directory and create fresh one
  [[ -d "$extract_dir" ]] && rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  # Extract based on file type with verbose error handling
  local extraction_success=false
  local filename=$(basename "$package_file")

  log_debug "Attempting to extract $filename"

  # tar-family formats have no password concept - ignore a mistakenly set
  # archive_password loudly rather than failing.
  case "$filename" in
  *.tar.gz | *.tgz | *.tar.bz2 | *.bz2 | *.tar.xz | *.txz | *.tar)
    [[ -n "$archive_password" ]] && log_warn "archive_password is set but tar-family archives have no password support - ignoring it."
    ;;
  esac

  case "$filename" in
  *.zip)
    if [[ -n "$archive_password" ]]; then
      # Password-protected zip: prefer 7zz/7z, which decrypt AES-encrypted
      # zips (the common modern scheme); the stock unzip -P only handles the
      # legacy ZipCrypto format and is the last resort.
      if command -v 7zz >/dev/null 2>&1; then
        log_debug "Extracting password-protected ZIP with 7zz"
        if 7zz x -y -p"$archive_password" "$package_file" -o"$extract_dir" >/dev/null 2>&1; then
          extraction_success=true
        else
          log_error "Password-protected ZIP extraction (7zz) failed - wrong password or corrupt archive"
        fi
      elif command -v 7z >/dev/null 2>&1; then
        log_debug "Extracting password-protected ZIP with 7z"
        if 7z x -y -p"$archive_password" "$package_file" -o"$extract_dir" >/dev/null 2>&1; then
          extraction_success=true
        else
          log_error "Password-protected ZIP extraction (7z) failed - wrong password or corrupt archive"
        fi
      else
        log_debug "Extracting password-protected ZIP with unzip -P (ZipCrypto only)"
        if unzip -qq -o -P "$archive_password" "$package_file" -d "$extract_dir" 2>&1; then
          extraction_success=true
        else
          log_error "Password-protected ZIP extraction failed. If the archive is AES-encrypted, the stock unzip cannot decrypt it - install 7-Zip/Keka as a prerequisite."
        fi
      fi
    elif unzip -qq -o "$package_file" -d "$extract_dir" 2>&1; then
      extraction_success=true
      log_debug "ZIP extraction successful"
    else
      local exit_code=$?
      log_error "ZIP extraction failed with exit code: $exit_code"
      # Try with verbose output for debugging
      log_debug "Attempting verbose ZIP extraction for diagnosis..."
      unzip -l "$package_file" 2>&1 | head -20 | while IFS= read -r line; do
        log_debug "ZIP contents: $line"
      done
    fi
    ;;
  *.tar.gz | *.tgz)
    log_debug "Extracting TAR.GZ file"
    if tar -zxf "$package_file" -C "$extract_dir" 2>&1; then
      extraction_success=true
    else
      log_error "TAR.GZ extraction failed with exit code: $?"
    fi
    ;;
  *.tar.bz2 | *.bz2)
    log_debug "Extracting TAR.BZ2 file"
    if tar -jxf "$package_file" -C "$extract_dir" 2>&1; then
      extraction_success=true
    else
      log_error "TAR.BZ2 extraction failed with exit code: $?"
    fi
    ;;
  *.tar.xz | *.txz)
    log_debug "Extracting TAR.XZ file"
    if tar -Jxf "$package_file" -C "$extract_dir" 2>&1; then
      extraction_success=true
    else
      log_error "TAR.XZ extraction failed with exit code: $?"
    fi
    ;;
  *.tar)
    log_debug "Extracting TAR file"
    if tar -xf "$package_file" -C "$extract_dir" 2>&1; then
      extraction_success=true
    else
      log_error "TAR extraction failed with exit code: $?"
    fi
    ;;
  *.7z)
    # Preference order: 7zz (official 7-Zip macOS build) → 7z (p7zip) →
    # bsdtar. macOS ships no 7z tool natively, but its bundled tar is
    # libarchive-based and reads standard 7z archives, so most configs work
    # with zero extra binaries; the dedicated tools cover exotic codecs.
    local sevenz_pw=()
    [[ -n "$archive_password" ]] && sevenz_pw=(-p"$archive_password")
    if command -v 7zz >/dev/null 2>&1; then
      log_debug "Extracting 7Z file with 7zz"
      if 7zz x -y "${sevenz_pw[@]}" "$package_file" -o"$extract_dir" >/dev/null 2>&1; then
        extraction_success=true
      else
        log_error "7Z extraction (7zz) failed with exit code: $?"
      fi
    elif command -v 7z >/dev/null 2>&1; then
      log_debug "Extracting 7Z file with 7z"
      if 7z x -y "${sevenz_pw[@]}" "$package_file" -o"$extract_dir" >/dev/null 2>&1; then
        extraction_success=true
      else
        log_error "7Z extraction (7z) failed with exit code: $?"
      fi
    elif [[ -n "$archive_password" ]]; then
      # bsdtar cannot decrypt 7z - a password requires a real 7z tool.
      log_error "7Z archive has archive_password set but no 7zz/7z is installed - bsdtar cannot decrypt. Install 7-Zip/Keka as a prerequisite."
      return 1
    else
      log_debug "No 7zz/7z binary - trying bsdtar (libarchive) for 7Z file"
      if tar -xf "$package_file" -C "$extract_dir" 2>&1; then
        extraction_success=true
      else
        log_error "7Z extraction failed: no 7zz/7z installed and bsdtar could not read the archive. Add 7-Zip as a prerequisite item if your config ships .7z payloads."
        return 1
      fi
    fi
    ;;
  *.rar)
    # Preference order: unrar (e.g. Keka's embedded one exposed via a
    # /usr/local/bin wrapper - see README) → bsdtar. macOS has no native rar
    # tool, but bsdtar (libarchive) reads RAR v4 and most RAR v5; a real
    # unrar additionally handles encrypted and exotic variants.
    if command -v unrar >/dev/null 2>&1; then
      # -p<pw> supplies the archive_password; -p- (no password) prevents an
      # unexpectedly-encrypted rar from hanging on a headless prompt.
      local unrar_pw=("-p-")
      [[ -n "$archive_password" ]] && unrar_pw=(-p"$archive_password")
      log_debug "Extracting RAR file with unrar"
      if unrar x -y "${unrar_pw[@]}" "$package_file" "$extract_dir/" >/dev/null 2>&1; then
        extraction_success=true
      else
        log_error "RAR extraction (unrar) failed with exit code: $? - wrong password or corrupt archive"
      fi
    elif [[ -n "$archive_password" ]]; then
      # bsdtar cannot decrypt rar - a password requires a real unrar tool.
      log_error "RAR archive has archive_password set but no unrar is installed - bsdtar cannot decrypt. Install Keka/unrar as a prerequisite."
      return 1
    else
      log_debug "Extracting RAR file with bsdtar (libarchive)"
      if tar -xf "$package_file" -C "$extract_dir" 2>&1; then
        extraction_success=true
      else
        log_error "RAR extraction failed: bsdtar could not read the archive (encrypted or unsupported RAR variant). Install Keka/unrar as a prerequisite, or re-package the payload as zip/dmg."
        return 1
      fi
    fi
    ;;
  *)
    log_error "Unsupported archive format: $filename"
    return 1
    ;;
  esac

  if [[ "$extraction_success" == "false" ]]; then
    log_error "Failed to extract archive: $package_file"
    return 1
  fi

  # Debug: List extracted contents
  log_debug "Extracted contents:"
  find "$extract_dir" -type f -name "*" | head -10 | while IFS= read -r file; do
    log_debug "  Found: $file"
  done

  # Find and install content in priority order
  local success=false

  # 1. Look for specific installer if specified
  if [[ "$success" == "false" && -n "$installer_name" && "$installer_name" != "empty" ]]; then
    log_debug "Looking for specific installer: $installer_name"
    local installer_path=$(find "$extract_dir" -name "$installer_name" -type f | head -1)
    if [[ -n "$installer_path" ]]; then
      log_info "Found specific installer: $installer_path"
      chmod +x "$installer_path"
      export INSTALLER_PATH="$installer_path"
      success=true
      log_debug "Exported INSTALLER_PATH=$installer_path"
    else
      log_warn "Specified installer '$installer_name' not found in archive"
      # List what we did find
      log_debug "Available files in archive:"
      find "$extract_dir" -type f -executable | head -10 | while IFS= read -r file; do
        log_debug "  Executable: $(basename "$file")"
      done
    fi
  fi

  # 2. Look for PKG files first (highest priority)
  local pkg_files=($(find "$extract_dir" \( -name "*.pkg" -o -name "*.mpkg" \) -type f))
  if [[ ${#pkg_files[@]} -gt 0 ]]; then
    log_info "Found PKG files in archive, installing..."
    for pkg_file in "${pkg_files[@]}"; do
      log_debug "Installing PKG: $pkg_file"
      if install_pkg_file "$pkg_file"; then
        success=true
      fi
    done
  fi

  # 3. Look for DMG files
  if [[ "$success" == "false" ]]; then
    local dmg_files=($(find "$extract_dir" -name "*.dmg" -type f))
    for dmg_file in "${dmg_files[@]}"; do
      log_debug "Installing DMG: $dmg_file"
      if install_dmg_file "$app_config" "$dmg_file"; then
        success=true
        break
      fi
    done
  fi

  # 4. Look for app bundles
  if [[ "$success" == "false" ]]; then
    local app_bundle=$(find "$extract_dir" -name "*.app" -type d | head -1)
    if [[ -d "$app_bundle" ]]; then
      local app_bundle_name=$(basename "$app_bundle")
      local target_path="$destination/$app_bundle_name"

      log_info "Installing app bundle: $app_bundle_name"

      # Remove existing installation
      [[ -d "$target_path" ]] && rm -rf "$target_path"

      # Copy the app
      if cp -R "$app_bundle" "$destination/"; then
        chown -R root:wheel "$target_path"
        success=true
        log_info "App bundle installation successful"
      else
        log_error "Failed to copy app bundle"
      fi
    fi
  fi

  # 5. Look for executable scripts/installers (fallback)
  if [[ "$success" == "false" ]]; then
    local script_files=($(find "$extract_dir" -type f \( -name "*.sh" -o -name "*.zsh" -o -name "install*" -o -name "setup*" \) | head -5))
    if [[ ${#script_files[@]} -gt 0 ]]; then
      log_info "Found executable scripts in archive, making them available for commands..."
      for script_file in "${script_files[@]}"; do
        chmod +x "$script_file"
        log_info "Made executable: $script_file"
      done
      success=true
    fi
  fi

  # Export installer path for use in commands
  if [[ -n "$installer_name" && "$installer_name" != "empty" ]]; then
    local installer_path=$(find "$extract_dir" -name "$installer_name" -type f | head -1)
    if [[ -n "$installer_path" ]]; then
      export INSTALLER_PATH="$installer_path"
      log_info "Exported INSTALLER_PATH=$installer_path"
    fi
  fi

  if [[ "$success" == "true" ]]; then
    log_info "Archive extraction and preparation successful"
    return 0
  else
    log_error "No recognizable installable content found in archive"
    return 1
  fi
}

# Execute commands with proper context
execute_commands() {
  local app_config="$1"
  local command_type="$2" # pre_install_commands, commands, post_install_commands
  local app_name
  app_name=$(echo "$app_config" | jq -r '.name')

  # Pull commands (one per line). Accept both array and string forms so
  # a single-line directive like `"post_install_commands": "install_rosetta2"`
  # is treated the same as `["install_rosetta2"]`. Without this branch, the
  # `[]?` operator silently extracts zero commands from a string and the
  # whole post_install phase no-ops with rc=0 - exactly how the rosetta2
  # prereq used to ship without ever calling install_rosetta2 (see commit
  # history). state-managment.sh:detection_commands has the same accommodation.
  local commands_json
  commands_json=$(echo "$app_config" | jq -r "
    .${command_type} |
    if type == \"array\" then .[]
    elif type == \"string\" then .
    else empty end
  " 2>/dev/null)

  [[ -z "$commands_json" ]] && return 0

  log_info "Executing ${command_type} for $app_name"

  while IFS= read -r command_line; do
    [[ -z "$command_line" ]] && continue

    # prefix:command   (default root)
    local prefix="root" command="$command_line"
    if [[ "$command_line" == *":"* ]]; then
      prefix="${command_line%%:*}"
      command="${command_line#*:}"
    fi

    # Variable substitution
    command=$(substitute_variables "$app_config" "$command")

    # Idempotent quoting for $INSTALLER_PATH. Strip any pre-existing quotes
    # around the variable first, then wrap exactly once. Handles both bare
    # `$INSTALLER_PATH` and pre-quoted `"$INSTALLER_PATH"` in apps.json without
    # producing the broken `""$INSTALLER_PATH""` form (which word-splits because
    # the inner expansion is unquoted from bash's perspective).
    if [[ "$command" == *"\$INSTALLER_PATH"* ]]; then
      command="${command//\"\$INSTALLER_PATH\"/\$INSTALLER_PATH}"
      command="${command//\$INSTALLER_PATH/\"\$INSTALLER_PATH\"}"
    fi

    log_info "Executing as $prefix: $command"

    # Dry-run: just print
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      log_info "DRY-RUN: would execute as $prefix: $command"
      continue
    fi

    # Build the child shell payload. Source the full functions/ directory so
    # every helper defined in the orchestrator (custom-commands, logging,
    # utilities, etc.) is available - both for `root:` and `user:` commands.
    # The previous implementation re-injected a hand-listed whitelist of
    # functions, which silently broke any custom command whose body referenced
    # a helper that wasn't on the list (e.g. `rename_device` calls log_debug,
    # which under `set -euo pipefail` produced exit 127 / command not found).
    local payload=""
    if [[ -d "$SCRIPT_DIR/functions" ]]; then
      payload+="for __otk_fn in \"$SCRIPT_DIR/functions/\"*.sh; do source \"\$__otk_fn\"; done"$'\n'
    fi

    # Export any env vars the command might need. LOG_DIR + DEBUG are exported
    # so log_info/log_debug inside the child shell append to the same
    # onboarding.log the orchestrator writes - without these, subshell log
    # output goes only to stdout, and a custom command that fails leaves no
    # trace in the log file (see rename_device's silent exit-1 in earlier runs).
    payload+="export TEMP_DIR=${TEMP_DIR:-/tmp}"$'\n'
    [[ -n "${STATE_DIR:-}" ]] && payload+="export STATE_DIR=\"$STATE_DIR\""$'\n'
    [[ -n "${CONFIG_DIR:-}" ]] && payload+="export CONFIG_DIR=\"$CONFIG_DIR\""$'\n'
    [[ -n "${LOG_DIR:-}" ]] && payload+="export LOG_DIR=\"$LOG_DIR\""$'\n'
    [[ -n "${DEBUG:-}" ]] && payload+="export DEBUG=\"$DEBUG\""$'\n'
    [[ -n "${INSTALLER_PATH:-}" ]] && payload+="export INSTALLER_PATH=\"$INSTALLER_PATH\""$'\n'
    [[ -n "${installer_path:-}" ]] && payload+="export installer_path=\"$installer_path\""$'\n'
    # Only pipefail. `set -e` + `set -u` were too strict for ad-hoc commands
    # in apps.json and helper functions in custom-commands.sh - any helper that
    # legitimately returns non-zero (log_debug when DEBUG=false, `grep` with no
    # match, conditional `[[ ]]` chains) would abort the whole payload. The
    # orchestrator captures the command's actual exit code via `|| rc=$?` below
    # and reports it, so the strict-mode safety net wasn't adding signal - it
    # was masking real failures behind silent exits.
    payload+="set -o pipefail"$'\n'
    payload+="$command"$'\n'

    # Execute
    local rc=0
    if [[ "$prefix" == "user" ]]; then
      local current_user
      current_user=$(get_current_user)
      sudo -u "$current_user" -H bash -lc "$payload" || rc=$?
    else
      bash -lc "$payload" || rc=$?
    fi

    if ((rc != 0)); then
      log_error "Command failed with exit code $rc: $command"
      return $rc
    fi
  done <<<"$commands_json"

  return 0
}

# Substitute variables in commands
substitute_variables() {
  local app_config="$1"
  local command="$2"

  # Replace common variables
  command="${command//\$TEMP_DIR/$TEMP_DIR}"
  # Safe home-directory lookup via dscl. The prior `eval echo ~$user` form
  # would expand shell metacharacters if a username ever contained any -
  # rare but not impossible. dscl returns "NFSHomeDirectory: /Users/foo" so
  # awk picks the second field.
  command="${command//\$HOME/$(dscl . -read /Users/"$(get_current_user)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')}"

  # Replace custom variables
  local custom_vars
  custom_vars=$(echo "$app_config" | jq -r '.custom_variables // {}' 2>/dev/null)

  if [[ "$custom_vars" != "{}" && "$custom_vars" != "null" ]]; then
    local var_keys
    var_keys=$(echo "$custom_vars" | jq -r 'keys[]')
    while IFS= read -r key; do
      local value
      local type
      type=$(echo "$custom_vars" | jq -r --arg k "$key" '.[$k] | type')

      if [[ "$type" == "array" ]]; then
        # Quote each array item properly for bash
        value=$(echo "$custom_vars" | jq -r --arg k "$key" '.[$k][]' | sed "s/'/'\\\\''/g" | awk '{printf "'\''%s'\'' ", $0}')
        value="${value% }" # Remove trailing space
      else
        value=$(echo "$custom_vars" | jq -r --arg k "$key" '.[$k]')
      fi

      if [[ "$value" != "null" ]]; then
        command="${command//\$$key/$value}"
      fi
    done <<<"$var_keys"
  fi

  echo "$command"
}

# Kill applications before installation
kill_applications() {
  local app_config="$1"
  local app_name=$(echo "$app_config" | jq -r '.name')

  local kill_apps_json=$(echo "$app_config" | jq -r '.kill_apps[]? // empty' 2>/dev/null)

  if [[ -n "$kill_apps_json" ]]; then
    log_info "Killing conflicting apps for $app_name"
    while IFS= read -r app_to_kill; do
      [[ -n "$app_to_kill" ]] && kill_application "$app_to_kill"
    done <<<"$kill_apps_json"
  fi
}

process_applications() {
  log_info "Processing applications from $APPS_JSON"

  local items_json=$(jq -c '.items[]' "$APPS_JSON")
  local total_items=$(echo "$items_json" | wc -l | xargs)
  local current_item=0

  # Pre-flight: emit a "Waiting for X" status for every top-level row that
  # isn't already complete. autoMatch routes each line to its dialog row by
  # displayName, so users see the queue. As the loop reaches each item, the
  # existing Downloading/Installing/Configuring events overwrite this status.
  # The state plists were just written by initialize_state_file_with_detection,
  # so reading them is the cheap source of truth (no need to re-run detection).
  while IFS= read -r item; do
    local pf_type=$(echo "$item" | jq -r '.type')
    local pf_id=$(echo "$item" | jq -r '.id')
    local pf_name=$(echo "$item" | jq -r '.name')
    local pf_state
    pf_state=$(defaults read "$STATE_DIR/${pf_id}.plist" state 2>/dev/null || echo "")

    if [[ "$pf_type" == "group" && "$pf_state" == "completed" ]]; then
      continue
    fi
    if [[ "$pf_type" != "group" && "$pf_state" == "installed" ]]; then
      continue
    fi

    log_status_event "$pf_id" "Waiting" "$pf_name"
  done <<<"$items_json"

  while IFS= read -r item; do
    current_item=$((current_item + 1))

    local item_type=$(echo "$item" | jq -r '.type')
    local item_id=$(echo "$item" | jq -r '.id')
    local item_name=$(echo "$item" | jq -r '.name')

    if [[ "$item_type" == "group" ]]; then
      process_group "$item"
    else
      process_app "$item"
    fi
  done <<<"$items_json"

  log_info "Completed processing all items (Installed: $installed_count, Skipped: $skipped_count, Failed: $failed_count)"
  return $((failed_count > 0 ? 1 : 0))
}

process_prerequisites() {
  log_info "Processing prerequisites (no UI/state) from $APPS_JSON"
  local prereqs_json=$(jq -c '.prerequisites[]?' "$APPS_JSON") || prereqs_json=""

  if [[ -z "$prereqs_json" ]]; then
    log_info "No prerequisites defined. Skipping."
    return 0
  fi

  local PRE_REQ_MODE=true
  local failures=0

  while IFS= read -r app_config; do
    [[ -z "$app_config" ]] && continue
    local app_name=$(echo "$app_config" | jq -r '.name')

    if is_application_installed "$app_config"; then
      log_info "[prereq] $app_name already present. Skipping."
      continue
    fi

    log_info "[prereq] Installing: $app_name"
    if ! install_application "$app_config"; then
      log_error "[prereq] Failed: $app_name"
      failures=$((failures + 1))
    else
      log_info "[prereq] Success: $app_name"
    fi
  done <<<"$prereqs_json"

  if ((failures > 0)); then
    log_warn "Prerequisites phase completed with $failures failure(s)."
    return 1
  fi
  log_info "Prerequisites phase completed successfully."
  return 0
}
