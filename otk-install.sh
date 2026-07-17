#!/bin/bash

# =============================================================================
# macOS Onboarding System Deployment Script
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly TEMP_DIR="$(mktemp -d)"

# launchd and MDM agents run with a minimal PATH that excludes
# /usr/local/bin and /opt/homebrew/bin - exactly where jq, aria2c, and
# dialog live. Prepend them so daemon/agent contexts find the same tools
# interactive shells do.
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# Deployment paths
readonly TARGET_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
readonly CONFIG_DIR="/Library/Application Support/Microsoft/IntuneScripts"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =============================================================================
# DEPLOYMENT CONFIG - REPLACE BEFORE DEPLOYING
# These URLs are organization-specific, NOT generic defaults. Replace all
# three with your own hosting URLs before deploying. The toolkit fetches
# these at runtime during --install and from the LaunchDaemon's
# --daemon-check path.
# =============================================================================
readonly ONBOARDING_SCRIPTS_URL="https://YOUR-HOST/otk/onboardingtoolkit.zip" #onboardingtoolkit.zip
readonly ONBOARDING_APPS_URL="https://YOUR-HOST/otk/apps.json"                #apps.json
readonly ONBOARDING_APPS_ICONS_URL="https://YOUR-HOST/otk/icons.zip"          #icons.zip

# Config signing (strongly recommended). apps.json and onboardingtoolkit.zip
# are executed as root, so anyone who can write to the hosting above owns the
# fleet unless their authenticity is verified. Run `./otk-sign.sh --init` once
# (or `otk-sign.ps1 -Init` on Windows) - it generates the keypair AND writes
# the PEM public key between the quotes below automatically (re-apply anytime
# with `--install-key` / `-InstallKey`). From then on both artifacts must be
# uploaded together with the `<file>.sig` produced by the signing tool, and
# any download whose signature is missing or invalid aborts the run. Leave
# empty to disable verification (a warning is logged).
# Keep in sync with otk-intune-onboarding.sh.
readonly ONBOARDING_SIGNING_PUBKEY=""

# Optional: explicit signature URLs. Leave empty to derive them as <url>.sig
# next to each artifact - that works for plain static hosting (Azure Blob,
# S3, any web server) where you control the path. Set these when your file
# service assigns unpredictable per-file URLs (e.g. https://host/fileID1234,
# where the uploaded .sig gets its own unrelated ID) or when your URLs carry
# query strings (SAS tokens, presigned links), where appending ".sig" breaks
# the URL. Each accepts a ';'-separated mirror list like the artifact URLs.
# Keep in sync with otk-intune-onboarding.sh.
readonly ONBOARDING_SCRIPTS_SIG_URL=""
readonly ONBOARDING_APPS_SIG_URL=""

# PPPC profile gate - only relevant when THIS script is deployed via Intune.
# Intune can run scripts before device-targeted configuration profiles have
# landed, and onboarding's AppleScript steps (wallpaper, default-browser
# click) then hang on unprovisioned TCC. Set your PPPC profile's display-name
# substring and/or payload identifier(s) to make the initial onboarding run
# wait for the profile (match is OR across both). Leave BOTH empty (default)
# to skip the gate - correct for manual / non-Intune deployments.
# Keep in sync with otk-intune-onboarding.sh.
readonly PPPC_PROFILE_NAME_MATCH="OTK PPPC Onboarding"
readonly PPPC_PROFILE_IDENTIFIERS=(
  "com.apple.TCC.configuration-profile-policy.00000000-0000-4000-8000-000000000001"
)
PPPC_WAIT_TIMEOUT="${PPPC_WAIT_TIMEOUT:-600}"
PPPC_POLL_INTERVAL=15

# Version check settings
readonly VERSION_CHECK_INTERVAL_MINUTES=60
readonly VERSION_FILE="$CONFIG_DIR/state/apps.version"
readonly LAST_CHECK_FILE="$CONFIG_DIR/state/last_check"

# Download and retry settings
MAX_RETRY_ATTEMPTS=3
RETRY_BASE_DELAY=5
DOWNLOAD_TIMEOUT=600

# Flags
DEBUG=false
DRY_RUN_ONBOARDING=false
FORCE_DOWNLOAD=false
SKIP_DOWNLOAD=false
FORCE_ONBOARDING=false

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  case "$level" in
  INFO) echo -e "${GREEN}[$timestamp] [INFO]${NC} $message" ;;
  WARN) echo -e "${YELLOW}[$timestamp] [WARN]${NC} $message" ;;
  ERROR) echo -e "${RED}[$timestamp] [ERROR]${NC} $message" ;;
  DEBUG) echo -e "${BLUE}[$timestamp] [DEBUG]${NC} $message" ;;
  *) echo "[$timestamp] [$level] $message" ;;
  esac

  if [[ -d "$CONFIG_DIR/logs" ]]; then
    echo "[$timestamp] [$level] $message" >>"$CONFIG_DIR/logs/deployment.log"
  fi
}

log_info() { log "INFO" "$1"; }
log_warn() { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "$1"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    echo "Usage: sudo $SCRIPT_NAME [options]"
    exit 1
  fi
}

cleanup_temp() {
  log_debug "Cleaning up temporary files..."
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

create_directories() {
  log_info "Creating required directories..."

  local dirs=(
    "$CONFIG_DIR"
    "$CONFIG_DIR/onBoarding"
    "$CONFIG_DIR/state"
    "$CONFIG_DIR/logs"
    "$CONFIG_DIR/Swift Dialog"
  )

  for dir in "${dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      if mkdir -p "$dir"; then
        log_info "Created directory: $dir"
      else
        log_warn "Failed to create directory: $dir"
      fi
    else
      log_debug "Directory already exists: $dir"
    fi
  done
}

# =============================================================================
# DOWNLOAD MANAGER
# =============================================================================

download_file() {
  local urls="$1"
  local output_path="$2"
  local options="${3:-}"

  IFS=';' read -ra url_array <<<"$urls"
  local success=0

  for url in "${url_array[@]}"; do
    [[ -z "$url" ]] && continue
    log_info "Testing URL: $url"
    if test_url "$url"; then
      log_info "URL is reachable: $url"
      validate_url "$url" || continue

      log_info "Downloading: $url -> $output_path"
      case "$url" in
      *sharepoint.com* | *redirect=*)
        download_with_redirects "$url" "$output_path"
        ;;
      *)
        download_direct "$url" "$output_path" "$options"
        ;;
      esac

      if validate_download "$output_path"; then
        success=1
        break
      else
        log_warn "Download failed for $url, trying next..."
      fi
    else
      log_warn "URL not reachable: $url"
    fi
  done

  if [[ $success -eq 0 ]]; then
    log_error "All download attempts failed."
    return 1
  fi
}

download_with_redirects() {
  local url="$1"
  local output_path="$2"

  log_debug "Handling redirect URL: $url"

  local session_id="$$_$(date +%s)"
  local headers_file="$TEMP_DIR/headers_${session_id}.txt"
  local cookie_jar="$TEMP_DIR/cookies_${session_id}.txt"

  if ! curl -s -D "$headers_file" -c "$cookie_jar" "$url" -o /dev/null; then
    log_warn "Redirect probe failed for: $url"
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

  curl -L -b "$cookie_jar" \
    --connect-timeout 30 \
    --max-time "$DOWNLOAD_TIMEOUT" \
    --retry "$MAX_RETRY_ATTEMPTS" \
    --retry-delay "$RETRY_BASE_DELAY" \
    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
    -o "$output_path" \
    "$redirect_url"
  local rc=$?

  rm -f "$cookie_jar" "$headers_file"
  # Propagate curl's status (not rm's) and never leave a truncated partial
  # behind - validate_download only checks exists+non-empty.
  if [[ $rc -ne 0 ]]; then
    rm -f "$output_path"
  fi
  return $rc
}

download_direct() {
  local url="$1"
  local output_path="$2"
  local options="$3"

  if [[ "$options" == *"use-curl"* ]] || ! command -v aria2c >/dev/null; then
    log_debug "Using curl for download"
    curl -L \
      --connect-timeout 30 \
      --max-time "$DOWNLOAD_TIMEOUT" \
      --retry "$MAX_RETRY_ATTEMPTS" \
      --retry-delay "$RETRY_BASE_DELAY" \
      -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
      -o "$output_path" \
      "$url"
  else
    log_debug "Trying aria2c for download"
    aria2c -q -x16 -s16 \
      --dir="$(dirname "$output_path")" \
      --out="$(basename "$output_path")" \
      --connect-timeout=30 \
      --timeout="$DOWNLOAD_TIMEOUT" \
      --retry-wait="$RETRY_BASE_DELAY" \
      --max-tries="$MAX_RETRY_ATTEMPTS" \
      --header="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
      "$url"
    local rc=$?

    if (( rc != 0 )); then
      # aria2c may have left a partial file at $output_path. validate_download
      # only checks "file exists and non-empty", so a truncated partial would
      # pass and be silently corrupted downstream. Remove it before falling
      # back to curl.
      log_debug "aria2c failed (rc=$rc), removing partial download and falling back to curl"
      rm -f "$output_path"
      curl -L \
        --connect-timeout 30 \
        --max-time "$DOWNLOAD_TIMEOUT" \
        --retry "$MAX_RETRY_ATTEMPTS" \
        --retry-delay "$RETRY_BASE_DELAY" \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -o "$output_path" \
        "$url"
    fi
  fi
}

validate_download() {
  local file_path="$1"

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

test_url() {
  local url="$1"
  curl --head --silent --fail --connect-timeout 10 "$url" >/dev/null
  return $?
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
      delay=$((delay * 2))
    fi

    attempt=$((attempt + 1))
  done

  log_error "Operation failed after $max_attempts attempts"
  return 1
}

validate_url() {
  local url="$1"

  if [[ ! "$url" =~ ^https?:// ]]; then
    log_error "Invalid URL format: $url"
    return 1
  fi

  return 0
}

# =============================================================================
# VERSION MANAGEMENT FUNCTIONS
# =============================================================================

get_current_version() {
  local apps_json="$1"

  if [[ ! -f "$apps_json" ]]; then
    echo "0.0"
    return
  fi

  local version
  version=$("${JQ_BIN:-jq}" -r '.global_settings.version // "0.0"' "$apps_json" 2>/dev/null)

  if [[ "$version" == "null" ]] || [[ -z "$version" ]]; then
    version="0.0"
  fi

  echo "$version"
}

get_stored_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    cat "$VERSION_FILE"
  else
    echo "0.0"
  fi
}

store_version() {
  local version="$1"
  mkdir -p "$(dirname "$VERSION_FILE")"
  echo "$version" >"$VERSION_FILE"
  log_info "Stored version: $version"
}

# compare_versions <candidate> <baseline>
#
# Returns 0 iff <candidate> is STRICTLY NEWER than <baseline> (major.minor only).
# Returns 1 if <candidate> is equal-or-older.
#
# This is a 2-way comparison, not a 3-way one - callers cannot distinguish
# "equal" from "older". The only caller today is check_for_version_update,
# which treats "newer → re-download apps.json, anything else → no-op", so the
# semantics fit. Do not reuse this for ordering comparisons that need to
# differentiate equal from older without updating the contract.
compare_versions() {
  local version1="$1"
  local version2="$2"

  # cut -s: a version with no dot ("3") yields an EMPTY minor instead of
  # echoing the whole string back (without -s, "3" would get minor=3 and be
  # judged newer than "3.1").
  local v1_major=$(echo "$version1" | cut -d. -f1)
  local v1_minor=$(echo "$version1" | cut -sd. -f2)
  local v2_major=$(echo "$version2" | cut -d. -f1)
  local v2_minor=$(echo "$version2" | cut -sd. -f2)
  v1_minor="${v1_minor:-0}"
  v2_minor="${v2_minor:-0}"

  if [[ $v1_major -gt $v2_major ]]; then
    return 0
  elif [[ $v1_major -lt $v2_major ]]; then
    return 1
  fi

  if [[ $v1_minor -gt $v2_minor ]]; then
    return 0
  else
    return 1
  fi
}

check_for_version_update() {
  log_info "Checking for version updates..."

  local temp_apps_json="$TEMP_DIR/apps_check.json"

  # Signature-verified like every other apps.json fetch - a tampered file
  # never even gets its version parsed, and each check logs
  # "✓ Signature verified" to deployment.log so signing is visibly at work.
  if ! download_resource "apps.json (version check)" "$ONBOARDING_APPS_URL" "$temp_apps_json" "true" "true" "$ONBOARDING_APPS_SIG_URL"; then
    log_warn "Failed to download/verify apps.json for version check"
    return 1
  fi

  local remote_version=$(get_current_version "$temp_apps_json")
  local stored_version=$(get_stored_version)

  log_info "Remote version: $remote_version, Stored version: $stored_version"

  if compare_versions "$remote_version" "$stored_version"; then
    log_info "New version available: $remote_version > $stored_version"
    return 0
  else
    log_info "No update needed. Current version is up to date."
    return 1
  fi
}

update_last_check_timestamp() {
  mkdir -p "$(dirname "$LAST_CHECK_FILE")"
  date +%s >"$LAST_CHECK_FILE"
}

should_check_for_updates() {
  if [[ ! -f "$LAST_CHECK_FILE" ]]; then
    return 0
  fi

  local last_check=$(cat "$LAST_CHECK_FILE")
  local now=$(date +%s)
  local elapsed=$((now - last_check))
  local check_interval=$((VERSION_CHECK_INTERVAL_MINUTES * 60))

  if [[ $elapsed -ge $check_interval ]]; then
    return 0
  else
    log_debug "Last check was $elapsed seconds ago, skipping (interval: $check_interval)"
    return 1
  fi
}

# =============================================================================
# INSTALLATION FUNCTIONS
# =============================================================================

check_jq() {
  # Fast path: already present
  if command -v jq >/dev/null 2>&1; then
    JQ_BIN="$(command -v jq)"
    export JQ_BIN
    log_info "jq is already installed: $($JQ_BIN --version)"
    return 0
  fi
  # Detect architecture -> jq release asset name
  local arch platform latest_tag base asset url tmp_jq install_dir
  arch="$(uname -m)"
  case "$arch" in
  arm64) platform="macos-arm64" ;;
  x86_64) platform="macos-amd64" ;;
  *)
    log_error "Unsupported architecture: $arch"
    return 1
    ;;
  esac
  # Resolve latest tag without Homebrew or checksum
  latest_tag="$(
    curl -fsSL https://api.github.com/repos/jqlang/jq/releases/latest |
      grep -m1 '"tag_name"' |
      sed -E 's/.*"([^"]+)".*/\1/'
  )"
  if [[ -z "${latest_tag:-}" ]]; then
    # Fallback to a known stable tag (pin) to avoid API rate-limit issues
    latest_tag="jq-1.7.1"
    log_warn "GitHub API unavailable; falling back to ${latest_tag}"
  fi
  base="https://github.com/jqlang/jq/releases/download/${latest_tag}"
  asset="jq-${platform}"
  url="${base}/${asset}"
  tmp_jq="${TEMP_DIR}/jq"
  log_info "Downloading ${asset} (${latest_tag})..."
  if ! curl -fL --retry 3 --connect-timeout 30 --max-time 600 -o "${tmp_jq}" "${url}"; then
    log_error "Download failed: ${url}"
    return 1
  fi
  chmod +x "${tmp_jq}"
  # Choose install dir ensuring Intune/launchd contexts can find it
  install_dir="/usr/local/bin"
  if echo ":$PATH:" | grep -q ":/opt/homebrew/bin:"; then
    install_dir="/opt/homebrew/bin"
  fi
  mkdir -p "${install_dir}"
  mv "${tmp_jq}" "${install_dir}/jq"
  # Canonical symlink to /usr/local/bin (harmless if same)
  ln -sf "${install_dir}/jq" /usr/local/bin/jq
  log_info "jq installed at ${install_dir}/jq"
  JQ_BIN="${install_dir}/jq"
  export JQ_BIN
  "$JQ_BIN" --version
}

# verify_resource_signature <file> <urls> <resource_name> [sig_urls]
#
# Verifies <file> against a detached RSA/SHA-256 signature, using the
# ONBOARDING_SIGNING_PUBKEY pinned in the deployment config (keys and .sig
# files are produced by otk-sign.sh). The signature is fetched from
# [sig_urls] when given (explicit override for hosting with unpredictable
# URLs or query strings), otherwise derived as <url>.sig from each artifact
# mirror. Fail-closed: when a public key is configured, a missing or invalid
# signature is a hard error - these files are executed as root, so an
# unverifiable download must never be installed. With no key configured this
# is a no-op apart from a warning, so unsigned deployments keep working.
verify_resource_signature() {
  local file="$1"
  local urls="$2"
  local resource_name="$3"
  local sig_urls="${4:-}"

  if [[ -z "$ONBOARDING_SIGNING_PUBKEY" ]]; then
    log_warn "Signature verification DISABLED for $resource_name (ONBOARDING_SIGNING_PUBKEY is empty - see otk-sign.sh)"
    return 0
  fi

  local pubkey_file="$TEMP_DIR/otk-signing.pub"
  printf '%s\n' "$ONBOARDING_SIGNING_PUBKEY" >"$pubkey_file"

  # Candidate .sig locations: the explicit override when set, otherwise
  # <url>.sig next to each artifact mirror. First one that answers wins
  # (trust comes from the signature, not from which host served it).
  local candidates=() url_array=() url
  if [[ -n "$sig_urls" ]]; then
    IFS=';' read -ra url_array <<<"$sig_urls"
    for url in "${url_array[@]}"; do [[ -n "$url" ]] && candidates+=("$url"); done
  else
    IFS=';' read -ra url_array <<<"$urls"
    for url in "${url_array[@]}"; do [[ -n "$url" ]] && candidates+=("${url}.sig"); done
  fi

  local sig_file="$file.sig"
  rm -f "$sig_file"
  for url in "${candidates[@]}"; do
    if curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -o "$sig_file" "$url"; then
      break
    fi
    rm -f "$sig_file"
  done

  if [[ ! -s "$sig_file" ]]; then
    log_error "SIGNATURE MISSING for $resource_name: could not fetch the .sig from any candidate URL - refusing to use it."
    log_error "Sign and upload with otk-sign.sh (file and .sig side by side). If your hosting can't serve <url>.sig (opaque IDs or query-string URLs), set the *_SIG_URL override in the deployment config; or clear ONBOARDING_SIGNING_PUBKEY to disable verification."
    return 1
  fi

  if openssl dgst -sha256 -verify "$pubkey_file" -signature "$sig_file" "$file" >/dev/null 2>&1; then
    log_info "✓ Signature verified for $resource_name"
    return 0
  fi

  log_error "SIGNATURE INVALID for $resource_name - file does not match its .sig. Refusing to proceed."
  log_error "Causes: tampering, a stale .sig left after a config update, or a public/private key mismatch."
  return 1
}

download_resource() {
  local resource_name="$1"
  local url="$2"
  local output_path="$3"
  local required="${4:-true}"
  local signed="${5:-false}"
  local sig_url="${6:-}"

  log_info "Downloading $resource_name..."

  if retry_with_backoff 5 2 download_file "$url" "$output_path"; then
    log_info "✓ Downloaded $resource_name ($(du -h "$output_path" | cut -f1))"
    if [[ "$signed" == "true" ]]; then
      verify_resource_signature "$output_path" "$url" "$resource_name" "$sig_url" || return 1
    fi
    return 0
  else
    if [[ "$required" == "true" ]]; then
      log_error "Failed to download required resource: $resource_name"
      return 1
    else
      log_warn "Failed to download optional resource: $resource_name"
      return 0
    fi
  fi
}

download_onboarding_resources() {
  local download_all="${1:-true}"
  # Install root defaults to CONFIG_DIR (the IntuneScripts root) - the
  # onBoarding/ subfolder is derived from it in install_extracted_files.
  local custom_install_path="${2:-$CONFIG_DIR}"

  log_info "Downloading onboarding resources (download_all=$download_all)..."
  local scripts_zip="$TEMP_DIR/onboardingtoolkit.zip"
  local icons_zip="$TEMP_DIR/icons.zip"
  local apps_json="$TEMP_DIR/apps.json"
  local extract_dir="$TEMP_DIR/macOS-onboarding"

  local download_scripts=false
  local download_icons=false
  local download_config=false

  # Determine what needs to be downloaded
  if [[ "$download_all" == "true" ]] || [[ "$FORCE_DOWNLOAD" == "true" ]]; then
    download_scripts=true
    download_icons=true
    download_config=true
  else
    # Smart detection: download only if missing or outdated
    if [[ ! -f "$TARGET_DIR/onboardingProcess.sh" ]]; then
      download_scripts=true
    fi
    if [[ ! -d "$CONFIG_DIR/Swift Dialog/icons" ]] || [[ -z "$(ls -A "$CONFIG_DIR/Swift Dialog/icons" 2>/dev/null)" ]]; then
      download_icons=true
    fi
    if [[ ! -f "$TARGET_DIR/apps.json" ]] || check_for_version_update; then
      download_config=true
      # A version bump ships as a set: the new apps.json may reference icons
      # added to icons.zip and rely on newer toolkit scripts. Refresh all
      # three so daemon-updated machines converge on the full artifact set
      # (matching otk-intune-onboarding.sh's update path) - otherwise new
      # items render with the fallback icon and script fixes never roll out.
      download_scripts=true
      download_icons=true
    fi
  fi

  log_info "Download plan: scripts=$download_scripts, icons=$download_icons, config=$download_config"

  # Download only what's needed
  # scripts + config are executed as root → signature-verified (5th arg).
  # icons are inert images → downloaded unverified.
  if [[ "$download_scripts" == "true" ]]; then
    download_resource "onboardingtoolkit.zip" "$ONBOARDING_SCRIPTS_URL" "$scripts_zip" "true" "true" "$ONBOARDING_SCRIPTS_SIG_URL" || return 1
  fi

  if [[ "$download_icons" == "true" ]]; then
    download_resource "icons.zip" "$ONBOARDING_APPS_ICONS_URL" "$icons_zip" "false"
  fi

  if [[ "$download_config" == "true" ]]; then
    download_resource "apps.json" "$ONBOARDING_APPS_URL" "$apps_json" "true" "true" "$ONBOARDING_APPS_SIG_URL" || return 1
  fi

  # Extract only what was downloaded
  mkdir -p "$extract_dir"

  if [[ "$download_scripts" == "true" ]] && [[ -f "$scripts_zip" ]]; then
    log_info "Extracting onboardingtoolkit.zip..."
    if ! unzip -qq -o "$scripts_zip" -d "$extract_dir"; then
      log_error "Failed to extract onboardingtoolkit.zip"
      return 1
    fi
  fi

  if [[ "$download_icons" == "true" ]] && [[ -f "$icons_zip" ]]; then
    log_info "Extracting icons.zip..."
    mkdir -p "$extract_dir/icons"
    if ! unzip -qq -o "$icons_zip" -d "$extract_dir/icons"; then
      log_warn "Failed to extract icons.zip (non-critical)"
    fi
  fi

  if [[ "$download_config" == "true" ]] && [[ -f "$apps_json" ]]; then
    mv "$apps_json" "$extract_dir/apps.json"
  fi

  log_info "Extraction completed successfully"

  # Install files
  install_extracted_files "$extract_dir" "$custom_install_path"
}

install_extracted_files() {
  local extract_dir="$1"
  # The "Base" destination (e.g., /Library/.../IntuneScripts OR /tmp/xyz)
  local install_root="${2:-$CONFIG_DIR}"

  log_info "Installing extracted files to root: $install_root..."

  # Define sub-paths based on the root
  local dest_onboarding="$install_root/onBoarding"
  local dest_icons="$install_root/Swift Dialog"

  # Create structure
  mkdir -p "$dest_onboarding"
  mkdir -p "$dest_icons"

  # Map files to their correct sub-folders
  local install_items=(
    "onboardingProcess.sh|$dest_onboarding|1"
    "apps.json|$dest_onboarding|0"
    "functions|$dest_onboarding|0"
    "icons|$dest_icons|0" # Extract 'icons' folder into 'Swift Dialog'
    # Optional: ship otk-install.sh inside onboardingtoolkit.zip (with YOUR
    # URLs + public key configured) and the daemon copy refreshes itself on
    # every version bump - otherwise the installer/daemon code stays at its
    # install-day version until --install is re-run. Safe to replace while
    # the daemon is executing it: the running bash keeps its open fd to the
    # old inode; the new code takes effect on the next tick.
    "otk-install.sh|$dest_onboarding|1"
  )

  for item in "${install_items[@]}"; do
    IFS='|' read -r src dest_path is_exec <<<"$item"

    if [[ -e "$extract_dir/$src" ]]; then
      # Clean existing
      [[ -d "$dest_path/$src" || -f "$dest_path/$src" ]] && rm -rf "$dest_path/$src"

      # Copy
      cp -R "$extract_dir/$src" "$dest_path/"

      # Permissions
      [[ "$is_exec" == "1" ]] && chmod +x "$dest_path/$src"
      log_info "✓ Installed $src to $dest_path"
    else
      log_debug "$src not found in extraction"
    fi
  done

  chown -R root:wheel "$install_root"
  # Clamp write bits: unzip/cp preserve whatever permissions the admin's zip
  # carried (a zip built on a 777 filesystem would otherwise deploy
  # world-writable root-executed scripts, letting any local user edit them
  # between runs). Signature verification only covers the download - local
  # integrity depends on these files staying root-only writable.
  chmod -R go-w "$install_root"

  # Record the deployed config version as soon as apps.json lands so
  # --status and the version check report consistently.
  if [[ -f "$dest_onboarding/apps.json" ]]; then
    local ver
    ver="$(get_current_version "$dest_onboarding/apps.json")"
    store_version "$ver"
  fi
}

validate_installation() {
  log_info "Validating installation..."

  local validation_errors=()

  # Ensure JQ_BIN is set
  JQ_BIN="${JQ_BIN:-$(command -v jq || true)}"
  if [[ -z "$JQ_BIN" ]]; then
    validation_errors+=("jq not found on system PATH after install")
  fi

  local required_files=(
    "$TARGET_DIR/onboardingProcess.sh"
    "$TARGET_DIR/apps.json"
  )

  for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
      validation_errors+=("Missing required file: $file")
    fi
  done

  # Check executability
  if [[ -f "$TARGET_DIR/onboardingProcess.sh" ]] && [[ ! -x "$TARGET_DIR/onboardingProcess.sh" ]]; then
    validation_errors+=("Main script is not executable")
  fi

  # Validate JSON syntax (use absolute jq)
  if [[ -f "$TARGET_DIR/apps.json" && -n "$JQ_BIN" ]]; then
    if ! "$JQ_BIN" empty "$TARGET_DIR/apps.json" 2>/dev/null; then
      validation_errors+=("Invalid JSON syntax in apps.json")
    else
      local app_count=$("$JQ_BIN" '[.items[]? | if .type == "group" then .apps[] else . end] | length' "$TARGET_DIR/apps.json" 2>/dev/null || echo "0")
      log_info "Found $app_count applications in configuration"
    fi
  fi

  local required_commands=("jq" "curl" "unzip" "hdiutil")
  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      validation_errors+=("Missing required command: $cmd")
    fi
  done

  local required_dirs=(
    "$CONFIG_DIR/onBoarding"
    "$CONFIG_DIR/state"
    "$CONFIG_DIR/logs"
    "$CONFIG_DIR/Swift Dialog"
  )

  for dir in "${required_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      validation_errors+=("Missing required directory: $dir")
    fi
  done

  if [[ ${#validation_errors[@]} -gt 0 ]]; then
    log_error "Validation failed with the following errors:"
    for error in "${validation_errors[@]}"; do
      log_error "  - $error"
    done
    return 1
  else
    log_info "✓ Installation validation passed"
    return 0
  fi
}

create_launchd_service() {
  log_info "Creating LaunchDaemon for version checking and onboarding..."

  # The daemon invokes a persistent copy of this script - the location Intune
  # (or the admin) ran it from is temporary. Install ourselves first, or the
  # plist points at a file that never exists and the update path is inert.
  local daemon_script="$TARGET_DIR/otk-install.sh"
  mkdir -p "$TARGET_DIR"
  if ! cp "${BASH_SOURCE[0]}" "$daemon_script"; then
    log_error "Failed to install daemon copy of this script at $daemon_script"
    return 1
  fi
  chown root:wheel "$daemon_script"
  chmod 755 "$daemon_script"
  log_info "✓ Installed daemon copy: $daemon_script"

  local plist_path="/Library/LaunchDaemons/com.microsoft.intune.onboarding.plist"

  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.microsoft.intune.onboarding</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Library/Application Support/Microsoft/IntuneScripts/onBoarding/otk-install.sh</string>
        <string>--daemon-check</string>
    </array>
    <key>StartInterval</key>
    <integer>$((VERSION_CHECK_INTERVAL_MINUTES * 60))</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/Library/Application Support/Microsoft/IntuneScripts/logs/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/Library/Application Support/Microsoft/IntuneScripts/logs/daemon-error.log</string>
    <key>WorkingDirectory</key>
    <string>/Library/Application Support/Microsoft/IntuneScripts/onBoarding</string>
</dict>
</plist>
EOF

  # Permissions required by launchd
  chown root:wheel "$plist_path"
  chmod 0644 "$plist_path"
  log_info "✓ LaunchDaemon created at: $plist_path"
  log_info "  - Interval: ${VERSION_CHECK_INTERVAL_MINUTES} minutes"

  # (Re)load it now; safe to attempt unload first
  launchctl unload "$plist_path" 2>/dev/null || true
  if launchctl load "$plist_path" 2>/dev/null; then
    log_info "✓ LaunchDaemon loaded"
  else
    log_warn "! LaunchDaemon created but not loaded (this can be OK under some MDM flows)"
  fi

}

daemon_check() {
  log_info "Daemon version check started..."

  if [[ ! -f "$TARGET_DIR/onboardingProcess.sh" ]]; then
    log_error "Onboarding system not installed properly. Daemon cannot continue."
    return 1
  fi

  # Rate limiting: only check if enough time has passed
  if ! should_check_for_updates; then
    log_info "Skipping check - not enough time elapsed since last check"
    return 0
  fi

  update_last_check_timestamp

  if check_for_version_update; then
    log_info "Version update detected, downloading and installing..."

    # Download only what's needed (smart download)
    if download_onboarding_resources "false"; then
      log_info "Successfully updated to new version"

      log_info "Running onboarding process in silent mode..."
      # --force is required here: the orchestrator short-circuits unconditionally
      # if onBoarding/onboarding.flag (or the legacy /var/db/.onboardingdone) is
      # present. Without --force, every daemon-triggered re-run on an already-
      # onboarded machine is a silent no-op even when apps.json bumps version.
      # Per-item detection in the orchestrator still skips already-installed
      # apps, so --force only re-runs missing/changed items.
      if (cd "$TARGET_DIR" && "$TARGET_DIR/onboardingProcess.sh" --silent --force); then
        log_info "Silent onboarding completed successfully"
      else
        log_warn "Silent onboarding failed or had issues"
      fi
    else
      log_error "Failed to download updated resources"
      return 1
    fi
  else
    log_info "No version update needed"
  fi

  log_info "Daemon version check completed"
}

run_tests() {
  log_info "Running deployment tests..."

  # Ensure JQ_BIN is set
  JQ_BIN="${JQ_BIN:-$(command -v jq || true)}"

  log_info "Testing script syntax..."
  if bash -n "$TARGET_DIR/onboardingProcess.sh" 2>/dev/null; then
    log_info "✓ Main script syntax is valid"
  else
    log_error "✗ Main script syntax error"
    return 1
  fi

  # JSON validation
  if [[ -f "$TARGET_DIR/apps.json" && -n "$JQ_BIN" ]]; then
    log_info "Testing JSON configuration..."
    if "$JQ_BIN" empty "$TARGET_DIR/apps.json" 2>/dev/null; then
      log_info "✓ apps.json is valid JSON"
      # Check for required fields in each app
      # Reject missing .id too - a missing id produces an empty plist filename
      # ($STATE_DIR/.plist) and silently breaks SwiftDialog inspect mode for
      # that item.
      local invalid_apps=$("$JQ_BIN" -r '[.items[]? | if .type == "group" then .apps[] else . end][] | select(.name == null or .type == null or .id == null) | .name // .id // "unnamed"' "$TARGET_DIR/apps.json" 2>/dev/null)
      if [[ -n "$invalid_apps" ]]; then
        log_error "✗ Invalid app configurations found: $invalid_apps"
        return 1
      fi
      local app_count=$("$JQ_BIN" '[.items[]? | if .type == "group" then .apps[] else . end] | length' "$TARGET_DIR/apps.json" 2>/dev/null || echo "0")
      log_info "✓ Found $app_count valid applications in configuration"
    else
      log_error "✗ apps.json contains invalid JSON"
      return 1
    fi
  fi

  log_info "Testing file permissions..."
  if [[ -x "$TARGET_DIR/onboardingProcess.sh" ]]; then
    log_info "✓ Main script is executable"
  else
    log_error "✗ Main script is not executable"
    return 1
  fi

  log_info "Testing directory structure..."
  local required_dirs=(
    "$CONFIG_DIR/onBoarding"
    "$CONFIG_DIR/state"
    "$CONFIG_DIR/logs"
    "$CONFIG_DIR/Swift Dialog"
  )

  for dir in "${required_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      log_info "✓ Directory exists: $dir"
    else
      log_error "✗ Missing directory: $dir"
      return 1
    fi
  done

  if [[ -f "$VERSION_FILE" ]]; then
    local stored_version=$(get_stored_version)
    log_info "✓ Version file exists with version: $stored_version"
  else
    log_warn "! Version file not found (expected on fresh install)"
  fi

  log_info "✓ All tests passed successfully!"
}

show_status() {
  echo ""
  echo "=================================="
  echo "   Onboarding System Status"
  echo "=================================="
  echo ""

  # Ensure JQ_BIN is set
  JQ_BIN="${JQ_BIN:-$(command -v jq || true)}"

  if [[ -f "$TARGET_DIR/onboardingProcess.sh" ]]; then
    echo -e "${GREEN}✓${NC} Installation: Complete"

    local current_version=$(get_current_version "$TARGET_DIR/apps.json")
    local stored_version=$(get_stored_version)
    echo -e "  Current Version: $current_version"
    echo -e "  Stored Version: $stored_version"
  else
    echo -e "${RED}✗${NC} Installation: Missing"
  fi

  # Check configuration
  if [[ -f "$TARGET_DIR/apps.json" && -n "$JQ_BIN" ]]; then
    local app_count=$("$JQ_BIN" '[.items[]? | if .type == "group" then .apps[] else . end] | length' "$TARGET_DIR/apps.json" 2>/dev/null || echo "0")
    echo -e "${GREEN}✓${NC} Configuration: $app_count apps configured"
  else
    echo -e "${YELLOW}!${NC} Configuration: No apps.json found or jq unavailable"
  fi

  # Config signing
  if [[ -n "$ONBOARDING_SIGNING_PUBKEY" ]]; then
    local key_fp
    key_fp=$(printf '%s\n' "$ONBOARDING_SIGNING_PUBKEY" | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-16)
    echo -e "${GREEN}✓${NC} Config signing: Enabled (key fingerprint: ${key_fp:-unavailable})"
    echo -e "  Downloads of apps.json / onboardingtoolkit.zip require a valid .sig"
  else
    echo -e "${YELLOW}!${NC} Config signing: DISABLED - downloads are NOT verified (see otk-sign.sh)"
  fi

  if [[ -f "/Library/LaunchDaemons/com.microsoft.intune.onboarding.plist" ]]; then
    echo -e "${GREEN}✓${NC} LaunchDaemon: Configured"
    echo -e "  Check Interval: ${VERSION_CHECK_INTERVAL_MINUTES} minutes"

    if launchctl list | grep -q "com.microsoft.intune.onboarding"; then
      echo -e "  Status: Loaded and Running"
    else
      echo -e "  Status: Not loaded"
    fi
  else
    echo -e "${YELLOW}!${NC} LaunchDaemon: Not configured"
  fi

  if [[ -f "$CONFIG_DIR/onBoarding/onboarding.flag" ]]; then
    local flag_date=$(stat -f %Sm -t "%Y-%m-%d %H:%M:%S" "$CONFIG_DIR/onBoarding/onboarding.flag" 2>/dev/null || echo "unknown")
    echo -e "${BLUE}i${NC} Status: Onboarding completed on $flag_date"
  else
    echo -e "${YELLOW}!${NC} Status: Onboarding not yet run"
  fi

  if [[ -x "/usr/local/bin/dialog" ]]; then
    echo -e "${GREEN}✓${NC} SwiftDialog: Installed"
  else
    echo -e "${YELLOW}!${NC} SwiftDialog: Not installed"
  fi

  if [[ -d "$CONFIG_DIR/logs" ]]; then
    local log_count=$(find "$CONFIG_DIR/logs" -name "*.log" | wc -l | xargs)
    echo -e "${BLUE}i${NC} Logs: $log_count log files available"

    if [[ -f "$CONFIG_DIR/logs/daemon.log" ]]; then
      local last_check=$(tail -1 "$CONFIG_DIR/logs/daemon.log" 2>/dev/null | grep -o '\[.*\]' | head -1 || echo "unknown")
      echo -e "  Last Daemon Check: $last_check"
    fi
  fi

  echo ""

  if [[ -f "$LAST_CHECK_FILE" ]]; then
    local last_epoch
    last_epoch="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo "")"
    if [[ -n "$last_epoch" ]]; then
      local last_human
      last_human="$(date -r "$last_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_epoch")"
      echo -e "${BLUE}i${NC} Last Version Check: $last_human"
    fi
  fi

  echo "Version Management:"
  if command -v curl >/dev/null 2>&1; then
    echo -e "${BLUE}i${NC} Checking for updates..."
    if check_for_version_update >/dev/null 2>&1; then
      echo -e "${YELLOW}!${NC} Update Available: New version detected"
    else
      echo -e "${GREEN}✓${NC} Up to Date: No updates available"
    fi
  else
    echo -e "${YELLOW}!${NC} Cannot check for updates: curl not available"
  fi

  echo ""
}

show_help() {
  cat <<EOF
macOS Onboarding System Deployment Script

USAGE:
    sudo $SCRIPT_NAME [OPTIONS]
    
    Note: When no options are provided, the script defaults to --install
    (perfect for Intune deployment where arguments cannot be passed)

OPTIONS:
    -i, --install       Install the onboarding system and create daemon (DEFAULT)
    -u, --uninstall     Uninstall the onboarding system
    -t, --test          Run tests only
    -s, --status        Show system status
    -r, --run           Run onboarding process (smart download - only missing/updated files)
    -v, --validate      Validate installation
    --daemon-check      Check for version updates and run silent onboarding (internal)
    --create-launchd    Create LaunchDaemon service
    --remove-launchd    Remove LaunchDaemon service
    --force-update      Force download and install latest version (full download)
    --check-version     Check for available version updates
    --debug             Enable debug logging
    -h, --help          Show this help message

OPTIONS FOR --run:
    --dry-run, -n       Pass dry-run flag to onboarding process
    --force-download    Force re-download all resources
    --skip-download     Skip download, use existing files only
    --force, -f         Force the onboarding process to re-run even if the
                        machine is already onboarded (clears completion flags)

EXAMPLES:
    # Auto-install (Intune deployment - downloads everything)
    sudo $SCRIPT_NAME
    
    # Manual install
    sudo $SCRIPT_NAME --install
    
    # Run onboarding (smart - only downloads what's needed)
    sudo $SCRIPT_NAME --run
    
    # Run with dry-run mode
    sudo $SCRIPT_NAME --run --dry-run
    
    # Force full re-download and run
    sudo $SCRIPT_NAME --run --force-download
    
    # Run without downloading (use existing files)
    sudo $SCRIPT_NAME --run --skip-download

    # Force re-run on an already-onboarded machine
    sudo $SCRIPT_NAME --run --force

    # Force re-run using only existing files (no download)
    sudo $SCRIPT_NAME --run --force --skip-download

    # Force complete update
    sudo $SCRIPT_NAME --force-update
    
    # Check status
    sudo $SCRIPT_NAME --status
    
    # Debug mode
    sudo $SCRIPT_NAME --debug

INTUNE DEPLOYMENT:
    This script is designed to work seamlessly with Microsoft Intune.
    Simply deploy the script without any arguments - it will automatically
    run the installation process and set up the automated update daemon.

DESCRIPTION:
    This script downloads and installs the macOS onboarding system with automatic
    version checking and updates. The system includes:
    
    - onboardingProcess.sh (main installation script)
    - apps.json (application configuration with version tracking)
    - SwiftDialog configuration and icons
    - Automated daemon that checks for updates every ${VERSION_CHECK_INTERVAL_MINUTES} minutes

SMART DOWNLOAD BEHAVIOR:
    --run uses intelligent downloading:
    - Only downloads apps.json if version changed
    - Only downloads scripts if missing
    - Only downloads icons if missing
    
    This saves bandwidth and time for routine onboarding runs.
    
VERSION MANAGEMENT:
    The system tracks versions using the "global_settings.version" field in apps.json.
    When a newer version is detected, the daemon automatically downloads updates
    and runs the onboarding process in silent mode.
    
DAEMON BEHAVIOR:
    - Checks for updates every ${VERSION_CHECK_INTERVAL_MINUTES} minutes
    - Uses smart downloading (only changed files)
    - Runs onboarding in --silent mode for updates
    - Logs all activity to daemon.log

EOF
}

uninstall() {
  log_info "Uninstalling onboarding system..."

  local plist_path="/Library/LaunchDaemons/com.microsoft.intune.onboarding.plist"
  if [[ -f "$plist_path" ]]; then
    launchctl unload "$plist_path" 2>/dev/null || true
    rm -f "$plist_path"
    log_info "✓ Removed LaunchDaemon"
  fi

  if [[ -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
    log_info "✓ Removed installation directory"
  fi

  if [[ -t 0 ]]; then
    echo ""
    read -p "Remove configuration, logs, and version data? (y/N): " -n 1 -r
    echo ""
  else
    REPLY="N"
    log_info "Non-interactive mode: keeping configuration and logs"
  fi
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [[ -d "$CONFIG_DIR" ]]; then
      rm -rf "$CONFIG_DIR"
      log_info "✓ Removed configuration and data"
    fi
  else
    log_info "✓ Kept configuration, logs, and version data"
  fi

  log_info "Uninstallation completed"
}

# Mirrors otk-intune-onboarding.sh:wait_for_pppc - keep in sync.
# Blocks until the org's PPPC profile is present, or fails so the caller
# (Intune) can retry. No-op when neither a name match nor identifiers are
# configured. Returns 0 when detected or skipped, 1 on timeout.
wait_for_pppc() {
  local elapsed=0

  if [[ -z "$PPPC_PROFILE_NAME_MATCH" && ${#PPPC_PROFILE_IDENTIFIERS[@]} -eq 0 ]]; then
    # Intentionally quieter than otk-intune-onboarding.sh here: empty is this
    # script's DEFAULT (manual/daemon deployments), so a warning would be
    # noise on every run.
    log_debug "PPPC gate not configured - skipping profile wait."
    return 0
  fi

  if ! profiles status -type enrollment 2>/dev/null | grep -q "MDM enrollment: Yes"; then
    log_warn "MDM enrollment not yet reported - will keep polling for the PPPC profile anyway."
  fi

  log_info "Waiting up to ${PPPC_WAIT_TIMEOUT}s for PPPC profile ('${PPPC_PROFILE_NAME_MATCH}') to land..."

  while ((elapsed < PPPC_WAIT_TIMEOUT)); do
    local profiles_out
    profiles_out="$(profiles -P -v 2>/dev/null || true)"

    if [[ -n "$profiles_out" ]]; then
      # Name check only when a match string is set - grep with an empty
      # pattern matches every line, which would false-positive the gate.
      if [[ -n "$PPPC_PROFILE_NAME_MATCH" ]] && echo "$profiles_out" | grep -i -q "$PPPC_PROFILE_NAME_MATCH"; then
        log_info "✓ PPPC profile detected (display-name match: '${PPPC_PROFILE_NAME_MATCH}')"
        return 0
      fi
      local id
      for id in "${PPPC_PROFILE_IDENTIFIERS[@]}"; do
        if echo "$profiles_out" | grep -F -q "$id"; then
          log_info "✓ PPPC profile detected (identifier: $id)"
          return 0
        fi
      done
    fi

    sleep "$PPPC_POLL_INTERVAL"
    elapsed=$((elapsed + PPPC_POLL_INTERVAL))
    if ((elapsed % 60 == 0)); then
      log_info "Still waiting for PPPC profile... (${elapsed}s/${PPPC_WAIT_TIMEOUT}s)"
    fi
  done

  log_error "PPPC profile '${PPPC_PROFILE_NAME_MATCH}' not detected after ${PPPC_WAIT_TIMEOUT}s - aborting."
  log_error "Without it, AppleScript steps hang or fail. Intune will retry on its next cycle."
  return 1
}

run_onboarding() {
  log_info "Preparing onboarding process..."

  # PPPC gate: no-op unless configured (see DEPLOYMENT CONFIG). Skipped for
  # dry runs; the daemon's silent update path never calls run_onboarding, so
  # established machines are unaffected.
  if [[ "${DRY_RUN_ONBOARDING}" != "true" ]]; then
    wait_for_pppc || return 1
  fi

  local root_path="$CONFIG_DIR" # Default: /Library/.../IntuneScripts
  local script_path="$TARGET_DIR/onboardingProcess.sh"
  local is_temporary_run=false
  local run_args=()

  # 1. Check if installed
  if [[ -f "$script_path" ]]; then
    log_info "Status: Existing installation found."

    # Check for updates normally
    if [[ "${SKIP_DOWNLOAD}" == "false" ]]; then
      if check_for_version_update || [[ "$FORCE_DOWNLOAD" == "true" ]]; then
        log_info "Update required or forced."
        # Pass CONFIG_DIR to ensure it installs to system path
        download_onboarding_resources "false" "$CONFIG_DIR"
      fi
    fi
  else
    # 2. Not installed - Temporary Mode
    log_info "Status: No installation found. Initiating Temporary Run."
    is_temporary_run=true

    # Use the console user's own temp directory so SwiftDialog (running as
    # that user) can read the staged files without permission games.
    local current_user=$(stat -f "%Su" /dev/console)

    # Fail-safe: if detection fails, fall back to standard mktemp
    if [[ -z "$current_user" ]] || [[ "$current_user" == "root" ]]; then
      local base_temp="$(mktemp -d)"
    else
      local user_temp_dir=$(sudo -u "$current_user" getconf DARWIN_USER_TEMP_DIR | sed 's:/*$::')
      local base_temp=$(mktemp -d "${user_temp_dir}/otk-run.XXXXXX")
    fi

    # CRITICAL: Ensure 755 so SwiftDialog (running as user) can read inside
    chmod 755 "$base_temp"

    local temp_root="${base_temp}/IntuneScripts"
    root_path="$temp_root"
    script_path="$temp_root/onBoarding/onboardingProcess.sh"
    # --------------------------------------

    log_info "Setting up temporary environment at: $root_path"

    # Download and Install into the Temp Root
    if ! download_onboarding_resources "true" "$root_path"; then
      log_error "Failed to prepare temporary execution environment."
      rm -rf "$base_temp"
      exit 1
    fi
  fi

  # 3. Build Arguments
  if [[ "${DRY_RUN_ONBOARDING}" == "true" ]]; then
    run_args+=("--dry-run")
  fi

  # --force tells the orchestrator to delete both completion flags
  # (onBoarding/onboarding.flag and the legacy /var/db/.onboardingdone) and
  # re-run, instead of short-circuiting on an already-onboarded machine.
  if [[ "${FORCE_ONBOARDING}" == "true" ]]; then
    run_args+=("--force")
    log_info "Force onboarding enabled - completion flags will be cleared and the process re-run"
  fi

  # Pass the root directory to the inner script
  run_args+=("--root" "$root_path")

  # 4. Execute
  log_info "Executing: $script_path"

  if [[ -x "$script_path" ]]; then
    "$script_path" "${run_args[@]}"
    exit_code=$?
  else
    log_error "Executable not found at $script_path"
    exit_code=1
  fi

  # 5. Cleanup
  if [[ "$is_temporary_run" == "true" ]]; then
    log_info "Cleaning up temporary environment..."

    # Remove the specific base temp folder we created
    if [[ -n "$base_temp" && -d "$base_temp" ]]; then
      rm -rf "$base_temp"
      log_info "✓ Cleanup complete"
    fi
  fi

  return $exit_code
}

force_update() {
  log_info "Forcing update to latest version..."

  create_directories

  # Force full download
  export FORCE_DOWNLOAD=true

  # A forced update should also force the onboarding to re-run: clear the
  # completion flags so run_onboarding does not short-circuit on an
  # already-onboarded machine.
  export FORCE_ONBOARDING=true

  if download_onboarding_resources "true"; then
    log_info "Successfully updated to latest version"
    validate_installation

    if [[ -t 0 ]]; then
      echo ""
      read -p "Run onboarding process now? (y/N): " -n 1 -r
      echo ""
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        run_onboarding
      fi
    else
      log_info "Non-interactive mode - skipping the onboarding-run prompt (use --run to launch it)"
    fi
  else
    log_error "Failed to download latest resources"
    return 1
  fi
}

check_version_only() {
  log_info "Checking for version updates..."

  if [[ ! -f "$TARGET_DIR/apps.json" ]]; then
    log_warn "No current installation found"
    return 1
  fi

  local current_version=$(get_current_version "$TARGET_DIR/apps.json")
  local stored_version=$(get_stored_version)

  echo "Current installed version: $current_version"
  echo "Stored version: $stored_version"

  if check_for_version_update; then
    echo -e "${GREEN}Update available!${NC} A newer version is ready for download."
    echo "Run with --force-update to install the latest version."
    return 0
  else
    echo -e "${GREEN}Up to date!${NC} You have the latest version."
    return 1
  fi
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
  # Help must work without sudo, network access, or jq.
  case "${1:-}" in
  -h | --help)
    show_help
    return 0
    ;;
  esac

  check_root
  check_jq || {
    log_error "jq is required and could not be bootstrapped - aborting."
    exit 1
  }

  # Accept --debug in any position (the help text presents it as a general
  # option, so "--run --debug" must work as well as "--debug --run").
  local _arg
  local _rest=()
  for _arg in "$@"; do
    if [[ "$_arg" == "--debug" ]]; then
      export DEBUG=true
    else
      _rest+=("$_arg")
    fi
  done
  set -- "${_rest[@]}"

  # Default to install if no arguments
  if [[ $# -eq 0 ]]; then
    log_info "No arguments provided - defaulting to --install (Intune deployment mode)"
    set -- "--install"
  fi

  case "${1:-}" in
  -i | --install)
    log_info "Installing macOS Onboarding System with automated version checking..."
    create_directories

    if download_onboarding_resources "true"; then
      validate_installation
      update_last_check_timestamp
      create_launchd_service
      run_tests
      show_status
      log_info "✓ Installation completed successfully!"

      if [[ -t 0 ]]; then
        echo ""
        echo "The system will now automatically check for updates every ${VERSION_CHECK_INTERVAL_MINUTES} minutes."
        echo ""
        echo "Available commands:"
        echo "  Check status:       sudo $0 --status"
        echo "  Run manually:       sudo $0 --run"
        echo "  Run in dry-run:     sudo $0 --run --dry-run"
        echo "  Force update:       sudo $0 --force-update"
        echo "  Check for updates:  sudo $0 --check-version"

        echo ""
        read -p "Run initial onboarding now? (Y/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
          run_onboarding
        fi
      else
        log_info "Non-interactive mode detected - running initial onboarding automatically"
        run_onboarding
      fi
    else
      log_error "Failed to download onboarding resources"
      log_error "Installation failed - check URLs and network connectivity"
      exit 1
    fi
    ;;

  -u | --uninstall)
    uninstall
    ;;

  -t | --test)
    run_tests
    ;;

  -s | --status)
    show_status
    ;;

  -r | --run)
    shift
    # Parse arguments for run command
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --dry-run | -n)
        export DRY_RUN_ONBOARDING=true
        log_info "Dry-run mode will be passed to onboarding process"
        shift
        ;;
      --force-download)
        export FORCE_DOWNLOAD=true
        log_info "Force download enabled - will download all resources"
        shift
        ;;
      --force | -f)
        export FORCE_ONBOARDING=true
        log_info "Force re-run enabled - onboarding will run even if already completed"
        shift
        ;;
      --skip-download)
        export SKIP_DOWNLOAD=true
        log_info "Skip download enabled - will use existing files only"
        shift
        ;;
      *)
        log_warn "Unknown option for --run: $1"
        shift
        ;;
      esac
    done

    # Validate conflicting flags
    if [[ "${FORCE_DOWNLOAD}" == "true" ]] && [[ "${SKIP_DOWNLOAD}" == "true" ]]; then
      log_error "Cannot use --force-download and --skip-download together"
      exit 1
    fi

    run_onboarding
    ;;

  -v | --validate)
    validate_installation
    ;;

  --daemon-check)
    daemon_check
    ;;

  --create-launchd)
    create_launchd_service
    ;;

  --remove-launchd)
    local plist_path="/Library/LaunchDaemons/com.microsoft.intune.onboarding.plist"
    if [[ -f "$plist_path" ]]; then
      launchctl unload "$plist_path" 2>/dev/null || true
      rm -f "$plist_path"
      log_info "✓ LaunchDaemon removed"
    else
      log_info "LaunchDaemon not found"
    fi
    ;;

  --force-update)
    force_update
    ;;

  --check-version)
    check_version_only
    ;;

  -h | --help)
    show_help
    ;;

  *)
    log_error "Unknown option: $1"
    show_help
    exit 1
    ;;
  esac
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

trap cleanup_temp EXIT INT TERM
main "$@"