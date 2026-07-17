#!/bin/bash

# =============================================================================
# macOS Onboarding Toolkit - Intune One-Shot Installer
#
# Slim variant of otk-install.sh for the Intune onboarding scenario:
#   * Runs once when Intune deploys the script (no arguments needed).
#   * Does NOT install a LaunchDaemon - Intune owns the lifecycle.
#   * On already-onboarded machines (completion flag present), acts as a
#     version-aware updater instead of a no-op: probes the hosted apps.json
#     (signature-verified) and, only if global_settings.version is strictly
#     newer than the installed one, re-downloads everything and re-runs the
#     orchestrator with --force --silent (no UI, no reboot; detection skips
#     items that are already compliant). Set an Intune script frequency
#     (e.g. weekly) to have the fleet converge on every config bump.
#     Set ENABLE_FLEET_UPDATES="false" (or run with --run-once) for the
#     classic one-shot behavior: onboarded machines are never touched again.
#
# For the daemon-enabled deployment path (non-Intune, periodic version checks),
# use otk-install.sh.
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly TEMP_DIR="$(mktemp -d)"

# MDM agents run with a minimal PATH that can exclude /usr/local/bin and
# /opt/homebrew/bin - exactly where jq and aria2c live. Prepend them so the
# agent context finds the same tools interactive shells do.
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# Deployment paths (must match otk-install.sh / onboardingProcess.sh)
readonly TARGET_DIR="/Library/Application Support/Microsoft/IntuneScripts/onBoarding"
readonly CONFIG_DIR="/Library/Application Support/Microsoft/IntuneScripts"
readonly VERSION_FILE="$CONFIG_DIR/state/apps.version"

# Completion flags
readonly LEGACY_FLAG="/var/db/.onboardingdone"
readonly NEW_FLAG="$TARGET_DIR/onboarding.flag"
# Breadcrumb proving this machine completed onboarding at least once. Unlike
# the completion flag, nothing ever deletes it (the orchestrator's --force
# removes the flag before an update run) - it's what routes an interrupted
# silent update into silent recovery instead of a full UI onboarding.
readonly ONBOARDED_ONCE="$CONFIG_DIR/state/onboarded.once"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# =============================================================================
# DEPLOYMENT CONFIG - REPLACE BEFORE DEPLOYING
# These URLs are organization-specific, NOT generic defaults. Replace all
# three with your own hosting URLs before deploying. Keep in sync with
# otk-install.sh.
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
# Keep in sync with otk-install.sh.
readonly ONBOARDING_SIGNING_PUBKEY=""

# Optional: explicit signature URLs. Leave empty to derive them as <url>.sig
# next to each artifact - that works for plain static hosting (Azure Blob,
# S3, any web server) where you control the path. Set these when your file
# service assigns unpredictable per-file URLs (e.g. https://host/fileID1234,
# where the uploaded .sig gets its own unrelated ID) or when your URLs carry
# query strings (SAS tokens, presigned links), where appending ".sig" breaks
# the URL. Each accepts a ';'-separated mirror list like the artifact URLs.
# Keep in sync with otk-install.sh.
readonly ONBOARDING_SCRIPTS_SIG_URL=""
readonly ONBOARDING_APPS_SIG_URL=""

# Fleet update behavior on already-onboarded machines (completion flag
# present):
#   "true"  (default) - version-aware updater: probe the hosted apps.json
#           version and apply a silent --force update only when it is
#           strictly newer than the installed one.
#   "false" - classic one-shot: exit immediately, never touch an onboarded
#           machine again; config updates then reach NEW machines only.
# Intune deploys this script without arguments, so flip it here (or set the
# env var); --run-once forces "false" for a manual invocation.
ENABLE_FLEET_UPDATES="${ENABLE_FLEET_UPDATES:-true}"

# Download/retry settings
MAX_RETRY_ATTEMPTS=3
RETRY_BASE_DELAY=5
DOWNLOAD_TIMEOUT=600
DEBUG=false

# PPPC profile gate - Intune sometimes runs onboarding scripts before all
# device-targeted configuration profiles have landed, so the orchestrator's
# AppleScript steps (wallpaper, CoreServicesUIAgent click for default
# browser, etc.) hit unprovisioned TCC and either hang on invisible consent
# dialogs or silently fail. We block until the org's PPPC profile is
# present, then proceed; on timeout we exit non-zero so Intune retries on
# its next deployment cycle (by which point the profile should have landed).
#
# Match is OR across:
#   * display-name substring (resilient to UUID rotation in Intune)
#   * any explicit payload identifier listed
#
# DEPLOYMENT CONFIG: both values below are organization-specific - replace
# the name match with your own PPPC profile's display name and the payload
# identifier with your profile's, or empty the identifier list to match on
# name only. Empty BOTH (name match "" and identifier list ()) to skip the
# gate entirely if your org doesn't deploy a PPPC profile.
readonly PPPC_PROFILE_NAME_MATCH="OTK PPPC Onboarding"
readonly PPPC_PROFILE_IDENTIFIERS=(
  "com.apple.TCC.configuration-profile-policy.00000000-0000-4000-8000-000000000001"
)
PPPC_WAIT_TIMEOUT="${PPPC_WAIT_TIMEOUT:-600}"
PPPC_POLL_INTERVAL=15

# =============================================================================
# LOGGING
# =============================================================================

log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  case "$level" in
  INFO)  echo -e "${GREEN}[$timestamp] [INFO]${NC} $message" ;;
  WARN)  echo -e "${YELLOW}[$timestamp] [WARN]${NC} $message" ;;
  ERROR) echo -e "${RED}[$timestamp] [ERROR]${NC} $message" ;;
  DEBUG) echo -e "${BLUE}[$timestamp] [DEBUG]${NC} $message" ;;
  *)     echo "[$timestamp] [$level] $message" ;;
  esac

  if [[ -d "$CONFIG_DIR/logs" ]]; then
    echo "[$timestamp] [$level] $message" >>"$CONFIG_DIR/logs/deployment.log"
  fi
}

log_info()  { log "INFO"  "$1"; }
log_warn()  { log "WARN"  "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "$1"; }

# =============================================================================
# UTILITIES
# =============================================================================

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    echo "Usage: sudo $SCRIPT_NAME"
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
      mkdir -p "$dir" && log_info "Created directory: $dir" || log_warn "Failed to create: $dir"
    fi
  done
}

# =============================================================================
# DOWNLOAD HELPERS (mirrors the same-named functions in otk-install.sh -
# keep in sync)
# =============================================================================

validate_url() {
  local url="$1"
  [[ "$url" =~ ^https?:// ]] || { log_error "Invalid URL format: $url"; return 1; }
  return 0
}

test_url() {
  curl --head --silent --fail --connect-timeout 10 "$1" >/dev/null
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

  local redirect_url
  redirect_url=$(grep -i '^Location:' "$headers_file" | awk '{print $2}' | tr -d '\r' | tail -1)
  local base_domain
  base_domain=$(echo "$url" | awk -F/ '{print $1 "//" $3}')

  if [[ -n "$redirect_url" ]]; then
    [[ "$redirect_url" == /* ]] && redirect_url="$base_domain$redirect_url"
    log_debug "Resolved redirect URL: $redirect_url"
  else
    redirect_url="$url"
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
  local url="$1" output_path="$2" options="$3"
  if [[ "$options" == *"use-curl"* ]] || ! command -v aria2c >/dev/null; then
    curl -L \
      --connect-timeout 30 \
      --max-time "$DOWNLOAD_TIMEOUT" \
      --retry "$MAX_RETRY_ATTEMPTS" \
      --retry-delay "$RETRY_BASE_DELAY" \
      -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
      -o "$output_path" \
      "$url"
  else
    if ! aria2c -q -x16 -s16 \
      --dir="$(dirname "$output_path")" \
      --out="$(basename "$output_path")" \
      --connect-timeout=30 \
      --timeout="$DOWNLOAD_TIMEOUT" \
      --retry-wait="$RETRY_BASE_DELAY" \
      --max-tries="$MAX_RETRY_ATTEMPTS" \
      --header="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
      "$url"; then
      # Remove any partial file aria2c left behind. validate_download only checks
      # "exists and non-empty", so a truncated partial would silently pass.
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

download_file() {
  local urls="$1" output_path="$2" options="${3:-}"
  IFS=';' read -ra url_array <<<"$urls"
  for url in "${url_array[@]}"; do
    [[ -z "$url" ]] && continue
    log_info "Testing URL: $url"
    if test_url "$url"; then
      validate_url "$url" || continue
      log_info "Downloading: $url -> $output_path"
      case "$url" in
        *sharepoint.com* | *redirect=*) download_with_redirects "$url" "$output_path" ;;
        *)                              download_direct "$url" "$output_path" "$options" ;;
      esac
      validate_download "$output_path" && return 0
      log_warn "Download failed for $url, trying next..."
    else
      log_warn "URL not reachable: $url"
    fi
  done
  log_error "All download attempts failed."
  return 1
}

retry_with_backoff() {
  local max_attempts="$1" base_delay="$2" operation="$3"
  shift 3
  local attempt=1 delay="$base_delay"
  while [[ $attempt -le $max_attempts ]]; do
    "$operation" "$@" && { log_info "Operation succeeded on attempt $attempt"; return 0; }
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

# verify_resource_signature <file> <urls> <resource_name> [sig_urls]
#
# Mirrors otk-install.sh: verifies <file> against a detached RSA/SHA-256
# signature using the pinned ONBOARDING_SIGNING_PUBKEY (keys and .sig files
# come from otk-sign.sh). The signature is fetched from [sig_urls] when given
# (explicit override for hosting with unpredictable URLs or query strings),
# otherwise derived as <url>.sig from each artifact mirror. Fail-closed when
# a key is configured; a warning-only no-op when it's empty.
verify_resource_signature() {
  local file="$1" urls="$2" resource_name="$3" sig_urls="${4:-}"

  if [[ -z "$ONBOARDING_SIGNING_PUBKEY" ]]; then
    log_warn "Signature verification DISABLED for $resource_name (ONBOARDING_SIGNING_PUBKEY is empty - see otk-sign.sh)"
    return 0
  fi

  local pubkey_file="$TEMP_DIR/otk-signing.pub"
  printf '%s\n' "$ONBOARDING_SIGNING_PUBKEY" >"$pubkey_file"

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
  local resource_name="$1" url="$2" output_path="$3" required="${4:-true}" signed="${5:-false}" sig_url="${6:-}"
  log_info "Downloading $resource_name..."
  if retry_with_backoff 5 2 download_file "$url" "$output_path"; then
    log_info "✓ Downloaded $resource_name ($(du -h "$output_path" | cut -f1))"
    if [[ "$signed" == "true" ]]; then
      verify_resource_signature "$output_path" "$url" "$resource_name" "$sig_url" || return 1
    fi
    return 0
  fi
  if [[ "$required" == "true" ]]; then
    log_error "Failed to download required resource: $resource_name"
    return 1
  fi
  log_warn "Failed to download optional resource: $resource_name"
  return 0
}

# =============================================================================
# JQ BOOTSTRAP (mirrors check_jq in otk-install.sh - keep in sync)
# =============================================================================

check_jq() {
  if command -v jq >/dev/null 2>&1; then
    JQ_BIN="$(command -v jq)"
    export JQ_BIN
    log_info "jq is already installed: $($JQ_BIN --version)"
    return 0
  fi

  local arch platform
  arch="$(uname -m)"
  case "$arch" in
    arm64)  platform="macos-arm64" ;;
    x86_64) platform="macos-amd64" ;;
    *)      log_error "Unsupported architecture: $arch"; return 1 ;;
  esac

  local latest_tag
  latest_tag="$(curl -fsSL https://api.github.com/repos/jqlang/jq/releases/latest |
    grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"
  [[ -z "$latest_tag" ]] && { latest_tag="jq-1.7.1"; log_warn "GitHub API unavailable; falling back to ${latest_tag}"; }

  local url="https://github.com/jqlang/jq/releases/download/${latest_tag}/jq-${platform}"
  local tmp_jq="${TEMP_DIR}/jq"
  log_info "Downloading jq-${platform} (${latest_tag})..."
  if ! curl -fL --retry 3 --connect-timeout 30 --max-time 600 -o "${tmp_jq}" "${url}"; then
    log_error "jq download failed: ${url}"
    return 1
  fi
  chmod +x "${tmp_jq}"

  local install_dir="/usr/local/bin"
  if echo ":$PATH:" | grep -q ":/opt/homebrew/bin:"; then
    install_dir="/opt/homebrew/bin"
  fi
  mkdir -p "${install_dir}"
  mv "${tmp_jq}" "${install_dir}/jq"
  ln -sf "${install_dir}/jq" /usr/local/bin/jq
  JQ_BIN="${install_dir}/jq"
  export JQ_BIN
  log_info "jq installed at ${install_dir}/jq"
}

# =============================================================================
# RESOURCE DOWNLOAD + INSTALL
# =============================================================================

download_resources() {
  log_info "Downloading onboarding resources..."
  local scripts_zip="$TEMP_DIR/onboardingtoolkit.zip"
  local icons_zip="$TEMP_DIR/icons.zip"
  local apps_json="$TEMP_DIR/apps.json"
  local extract_dir="$TEMP_DIR/macOS-onboarding"

  # scripts + config are executed as root → signature-verified (5th arg).
  # icons are inert images → downloaded unverified.
  download_resource "onboardingtoolkit.zip" "$ONBOARDING_SCRIPTS_URL" "$scripts_zip" "true" "true" "$ONBOARDING_SCRIPTS_SIG_URL" || return 1
  download_resource "icons.zip"             "$ONBOARDING_APPS_ICONS_URL" "$icons_zip"   "false"
  download_resource "apps.json"             "$ONBOARDING_APPS_URL" "$apps_json"         "true" "true" "$ONBOARDING_APPS_SIG_URL" || return 1

  mkdir -p "$extract_dir"

  log_info "Extracting onboardingtoolkit.zip..."
  if ! unzip -qq -o "$scripts_zip" -d "$extract_dir"; then
    log_error "Failed to extract onboardingtoolkit.zip"
    return 1
  fi

  if [[ -f "$icons_zip" ]]; then
    log_info "Extracting icons.zip..."
    mkdir -p "$extract_dir/icons"
    unzip -qq -o "$icons_zip" -d "$extract_dir/icons" || log_warn "Failed to extract icons.zip (non-critical)"
  fi

  [[ -f "$apps_json" ]] && mv "$apps_json" "$extract_dir/apps.json"

  install_extracted_files "$extract_dir"
}

install_extracted_files() {
  local extract_dir="$1"
  local install_root="$CONFIG_DIR"
  log_info "Installing extracted files to root: $install_root..."

  local dest_onboarding="$install_root/onBoarding"
  local dest_icons="$install_root/Swift Dialog"
  mkdir -p "$dest_onboarding" "$dest_icons"

  local install_items=(
    "onboardingProcess.sh|$dest_onboarding|1"
    "apps.json|$dest_onboarding|0"
    "functions|$dest_onboarding|0"
    "icons|$dest_icons|0"
    # Optional zip member (see otk-install.sh) - installed for zip-layout
    # parity so the same onboardingtoolkit.zip works with either installer.
    # Only meaningful on daemon-managed machines; inert here otherwise.
    "otk-install.sh|$dest_onboarding|1"
  )

  for item in "${install_items[@]}"; do
    IFS='|' read -r src dest_path is_exec <<<"$item"
    if [[ -e "$extract_dir/$src" ]]; then
      [[ -d "$dest_path/$src" || -f "$dest_path/$src" ]] && rm -rf "$dest_path/$src"
      cp -R "$extract_dir/$src" "$dest_path/"
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

  # Record version so otk-install.sh --status / future migrations report consistently.
  if [[ -f "$dest_onboarding/apps.json" ]] && command -v jq >/dev/null 2>&1; then
    local ver
    ver="$(jq -r '.global_settings.version // "0.0"' "$dest_onboarding/apps.json" 2>/dev/null)"
    [[ "$ver" == "null" || -z "$ver" ]] && ver="0.0"
    mkdir -p "$(dirname "$VERSION_FILE")"
    echo "$ver" >"$VERSION_FILE"
    log_info "Stored version: $ver"
  fi
}

validate_installation() {
  log_info "Validating installation..."
  local errors=()

  local required_files=(
    "$TARGET_DIR/onboardingProcess.sh"
    "$TARGET_DIR/apps.json"
  )
  for f in "${required_files[@]}"; do
    [[ -f "$f" ]] || errors+=("Missing required file: $f")
  done

  [[ -f "$TARGET_DIR/onboardingProcess.sh" && ! -x "$TARGET_DIR/onboardingProcess.sh" ]] && \
    errors+=("Main script is not executable")

  if [[ -f "$TARGET_DIR/apps.json" ]] && command -v jq >/dev/null 2>&1; then
    jq empty "$TARGET_DIR/apps.json" 2>/dev/null || errors+=("Invalid JSON syntax in apps.json")
  fi

  for cmd in jq curl unzip hdiutil; do
    command -v "$cmd" >/dev/null 2>&1 || errors+=("Missing required command: $cmd")
  done

  for d in "$CONFIG_DIR/onBoarding" "$CONFIG_DIR/state" "$CONFIG_DIR/logs" "$CONFIG_DIR/Swift Dialog"; do
    [[ -d "$d" ]] || errors+=("Missing required directory: $d")
  done

  if [[ ${#errors[@]} -gt 0 ]]; then
    log_error "Validation failed:"
    for e in "${errors[@]}"; do log_error "  - $e"; done
    return 1
  fi
  log_info "✓ Installation validation passed"
}

# =============================================================================
# COMPLETION-FLAG GATES
# =============================================================================

# Check whether onboarding has already been completed (legacy or new flag).
# Migrates the legacy flag to the new path so --status reports correctly on
# devices onboarded by the previous toolkit version.
already_onboarded() {
  if [[ -f "$LEGACY_FLAG" ]]; then
    log_info "Legacy completion flag found at $LEGACY_FLAG - onboarding already done. Migrating to $NEW_FLAG."
    mkdir -p "$(dirname "$NEW_FLAG")"
    [[ ! -f "$NEW_FLAG" ]] && touch "$NEW_FLAG"
    return 0
  fi
  if [[ -f "$NEW_FLAG" ]]; then
    log_info "Onboarding already completed (new flag present at $NEW_FLAG)."
    return 0
  fi
  return 1
}

# =============================================================================
# UPDATE MODE (already-onboarded machines)
# =============================================================================

# Mirrors otk-install.sh:compare_versions - keep in sync.
# Returns 0 iff <candidate> is STRICTLY NEWER than <baseline> (major.minor
# only); "equal" and "older" are both return 1. A same-version content edit
# will NOT roll out - always bump global_settings.version.
compare_versions() {
  local version1="$1" version2="$2"
  local v1_major=$(echo "$version1" | cut -d. -f1)
  # cut -s: a version with no dot ("3") yields an EMPTY minor instead of
  # echoing the whole string back (without -s, "3" would get minor=3 and be
  # judged newer than "3.1").
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
  [[ $v1_minor -gt $v2_minor ]]
}

get_stored_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    cat "$VERSION_FILE"
  else
    # No stored version (e.g. legacy-flag machine onboarded by the previous
    # toolkit) → any hosted version counts as newer and triggers an update.
    echo "0.0"
  fi
}

# Probe the hosted apps.json (signature-verified - an unsigned/tampered file
# never even gets its version parsed) and compare against the installed
# version. Returns 0 = update needed, 1 = up to date or probe failed.
update_available() {
  local probe="$TEMP_DIR/apps_probe.json"

  if ! download_resource "apps.json (version probe)" "$ONBOARDING_APPS_URL" "$probe" "true" "true" "$ONBOARDING_APPS_SIG_URL"; then
    log_warn "Version probe failed - skipping update check this cycle. Intune will retry on its next run."
    return 1
  fi

  local remote stored
  remote="$(jq -r '.global_settings.version // "0.0"' "$probe" 2>/dev/null)"
  [[ -z "$remote" || "$remote" == "null" ]] && remote="0.0"
  stored="$(get_stored_version)"
  log_info "Config version - hosted: $remote, installed: $stored"

  compare_versions "$remote" "$stored"
}

# Re-download everything (signature-verified), reinstall, and re-run the
# orchestrator headlessly. --force clears the completion flag so the run
# happens at all; --silent means no UI and no reboot. Per-item detection
# still runs, so only new/changed items actually install.
#
# No PPPC gate here: that gate exists for the enrollment race on brand-new
# machines - on an established machine the profile landed long ago.
run_update() {
  log_info "Newer config available - applying silent update."

  mkdir -p "$(dirname "$ONBOARDED_ONCE")"
  touch "$ONBOARDED_ONCE"

  create_directories
  if ! download_resources; then
    log_error "Failed to download updated resources - aborting update."
    return 1
  fi
  if ! validate_installation; then
    log_error "Validation of updated installation failed - aborting update."
    return 1
  fi
  run_onboarding --force --silent
}

# =============================================================================
# PPPC PROFILE GATE
# =============================================================================

# Block until the org's PPPC profile is present, or fail fast so Intune can
# retry. See the readonly constants near the top of this script for the
# match criteria. Returns 0 once the profile is detected, 1 on timeout.
wait_for_pppc() {
  local elapsed=0

  # Gate unconfigured → skip. Orgs without a PPPC profile (or that provision
  # TCC another way) leave both constants empty; blocking here would make
  # onboarding permanently unreachable for them (timeout → exit 1 → Intune
  # retry loop, forever).
  if [[ -z "$PPPC_PROFILE_NAME_MATCH" && ${#PPPC_PROFILE_IDENTIFIERS[@]} -eq 0 ]]; then
    log_warn "PPPC gate not configured (no name match / identifiers) - skipping the profile wait."
    log_warn "AppleScript-driven steps (wallpaper, default-browser click) may hang or fail if TCC is not provisioned."
    return 0
  fi

  if ! profiles status -type enrollment 2>/dev/null | grep -q "MDM enrollment: Yes"; then
    log_warn "MDM enrollment not yet reported - will keep polling for the PPPC profile anyway."
  fi

  log_info "Waiting up to ${PPPC_WAIT_TIMEOUT}s for PPPC profile ('${PPPC_PROFILE_NAME_MATCH}') to land..."

  while (( elapsed < PPPC_WAIT_TIMEOUT )); do
    local profiles_out
    profiles_out="$(profiles -P -v 2>/dev/null || true)"

    if [[ -n "$profiles_out" ]]; then
      # Name check only when a match string is set - grep with an empty
      # pattern matches every line, which would false-positive the gate.
      if [[ -n "$PPPC_PROFILE_NAME_MATCH" ]] && echo "$profiles_out" | grep -i -q "$PPPC_PROFILE_NAME_MATCH"; then
        log_info "✓ PPPC profile detected (display-name match: '${PPPC_PROFILE_NAME_MATCH}')"
        return 0
      fi
      for id in "${PPPC_PROFILE_IDENTIFIERS[@]}"; do
        if echo "$profiles_out" | grep -F -q "$id"; then
          log_info "✓ PPPC profile detected (identifier: $id)"
          return 0
        fi
      done
    fi

    sleep "$PPPC_POLL_INTERVAL"
    elapsed=$((elapsed + PPPC_POLL_INTERVAL))
    if (( elapsed % 60 == 0 )); then
      log_info "Still waiting for PPPC profile... (${elapsed}s/${PPPC_WAIT_TIMEOUT}s)"
    fi
  done

  log_error "PPPC profile '${PPPC_PROFILE_NAME_MATCH}' not detected after ${PPPC_WAIT_TIMEOUT}s - aborting."
  log_error "Without it, AppleScript steps (wallpaper, default-browser auto-click) hang or fail."
  log_error "Intune will retry on its next deployment cycle, by which point the profile should have landed."
  return 1
}

# =============================================================================
# RUN ONBOARDING
# =============================================================================

run_onboarding() {
  local target_script="$TARGET_DIR/onboardingProcess.sh"
  if [[ ! -x "$target_script" ]]; then
    log_error "Onboarding script not executable at $target_script"
    return 1
  fi

  # First runs launch with the SwiftDialog UI (no args). Under Intune the
  # script runs as root with no TTY, but the orchestrator bridges into the
  # console user's session via launchctl asuser (see
  # functions/swift-dialog.sh:initialize_dialog). Update/recovery paths pass
  # --force --silent instead.
  local args=("$@")

  log_info "Launching onboarding: bash $target_script ${args[*]}"
  bash "$target_script" "${args[@]}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  trap cleanup_temp EXIT INT TERM

  check_root

  # Gate 1: already onboarded → version-aware silent update instead of a
  # plain no-op (unless fleet updates are disabled - then classic one-shot).
  # Nothing happens unless the hosted config version is strictly newer than
  # what this machine has.
  if already_onboarded; then
    if [[ "$ENABLE_FLEET_UPDATES" != "true" ]]; then
      log_info "Fleet updates disabled (ENABLE_FLEET_UPDATES=$ENABLE_FLEET_UPDATES) - nothing to do."
      exit 0
    fi
    check_jq || { log_error "jq bootstrap failed"; exit 1; }
    if update_available; then
      run_update
      local rc=$?
      log_info "Silent update exited with code $rc"
      exit $rc
    fi
    log_info "Config up to date - nothing to do."
    exit 0
  fi

  # Interrupted update recovery: the completion flag is gone (the
  # orchestrator's --force removed it) but this machine has onboarded
  # before - resume silently rather than re-showing the full onboarding UI.
  if [[ -f "$ONBOARDED_ONCE" ]]; then
    log_warn "Completion flag missing but onboarded-once marker present - resuming interrupted update silently."
    create_directories
    check_jq || { log_error "jq bootstrap failed"; exit 1; }
    if ! validate_installation; then
      log_warn "Installed toolkit failed validation - re-downloading before recovery run."
      if ! download_resources; then
        log_error "Failed to re-download resources - aborting recovery."
        exit 1
      fi
    fi
    run_onboarding --force --silent
    local rc=$?
    log_info "Silent recovery run exited with code $rc"
    exit $rc
  fi

  # Gate 2: require the org's PPPC profile before doing anything that costs
  # real work. Without it, the orchestrator's AppleScript steps will hang or
  # fail at runtime; better to exit non-zero and let Intune retry.
  if ! wait_for_pppc; then
    exit 1
  fi

  create_directories
  check_jq || { log_error "jq bootstrap failed"; exit 1; }

  if ! download_resources; then
    log_error "Failed to download onboarding resources - aborting."
    exit 1
  fi

  if ! validate_installation; then
    log_error "Installation validation failed - aborting before onboarding run."
    exit 1
  fi

  log_info "✓ Installation complete - starting onboarding."
  run_onboarding
  local rc=$?
  log_info "Onboarding exited with code $rc"
  exit $rc
}

# Intune deploys with no args by default; flags are for manual invocations.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) DEBUG=true; shift ;;
    --run-once) ENABLE_FLEET_UPDATES=false; shift ;;
    -h|--help)
      cat <<EOF
$SCRIPT_NAME - macOS Onboarding Toolkit, Intune one-shot installer.

Usage: sudo $SCRIPT_NAME [--debug] [--run-once]

Behavior:
  * Fresh machine: downloads the toolkit, installs it under $CONFIG_DIR,
    and runs onboarding once with the SwiftDialog UI. No LaunchDaemon.
  * Already onboarded (completion flag present):
    probes the hosted apps.json version and, only if it is strictly newer
    than the installed one, re-downloads and re-runs the orchestrator with
    --force --silent (no UI, no reboot). Otherwise exits without changes.
    Assign this script with an Intune run frequency to roll out config
    updates to the existing fleet.
  * --run-once (or ENABLE_FLEET_UPDATES="false" in the script/env):
    classic one-shot behavior - exit immediately when a completion flag
    is present; onboarded machines are never touched again.
EOF
      exit 0 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

main
