#!/bin/bash

# =============================================================================
# OTK config signing helper
# =============================================================================
# Admin-side companion to otk-install.sh / otk-intune-onboarding.sh.
#
# Workflow:
#   1. ./otk-sign.sh --init
#        Generates an RSA-4096 keypair in ./signing/ (one time) and writes
#        the public key into the ONBOARDING_SIGNING_PUBKEY variable of both
#        installer scripts automatically (no manual copy/paste).
#   2. ./otk-sign.sh [file ...]
#        Signs each file, writing <file>.sig next to it. With no arguments it
#        signs apps.json and onboardingtoolkit.zip if present in the current
#        directory. Upload each file together with its .sig to your hosting.
#   3. ./otk-sign.sh --verify <file>
#        Local sanity check: verifies <file> against <file>.sig with the
#        public key, exactly like the installers will on-device.
#   4. ./otk-sign.sh --install-key
#        Re-writes the public key into the installer scripts on demand (e.g.
#        after pulling fresh copies of them, or when rotating keys).
#
# Uses `openssl dgst -sha256` (RSA), which works with both OpenSSL and the
# LibreSSL shipped on macOS. KEEP ./signing/otk-signing.key OUT OF THE REPO
# AND OFF THE HOSTING - anyone holding it can push root-executed config to
# your entire fleet.
# =============================================================================

set -euo pipefail

KEY_DIR="${OTK_KEY_DIR:-$(dirname "$0")/signing}"
PRIVATE_KEY="$KEY_DIR/otk-signing.key"
PUBLIC_KEY="$KEY_DIR/otk-signing.pub"

# Installer scripts that pin the public key, looked up next to this script.
INSTALLER_SCRIPTS=(
  "$(dirname "$0")/otk-install.sh"
  "$(dirname "$0")/otk-intune-onboarding.sh"
)

err() { echo "ERROR: $*" >&2; exit 1; }

# Rewrite the ONBOARDING_SIGNING_PUBKEY="..." assignment in one installer
# script with the current public key. Handles both the empty placeholder and
# an already-populated multi-line value (key rotation), and is idempotent.
inject_pubkey() {
  local target="$1"
  if ! grep -q '^readonly ONBOARDING_SIGNING_PUBKEY="' "$target"; then
    echo "WARN: no ONBOARDING_SIGNING_PUBKEY line in $target - skipped." >&2
    return 1
  fi

  local tmp="${target}.tmp.$$"
  awk -v pubfile="$PUBLIC_KEY" '
    BEGIN {
      n = 0
      while ((getline line < pubfile) > 0) pem[n++] = line
      close(pubfile)
    }
    skipping { if (index($0, "\"")) skipping = 0; next }
    /^readonly ONBOARDING_SIGNING_PUBKEY="/ {
      rest = substr($0, length("readonly ONBOARDING_SIGNING_PUBKEY=\"") + 1)
      if (index(rest, "\"") == 0) skipping = 1
      printf "readonly ONBOARDING_SIGNING_PUBKEY=\""
      for (i = 0; i < n; i++) printf "%s%s", pem[i], (i == n - 1 ? "\"\n" : "\n")
      next
    }
    { print }
  ' "$target" >"$tmp" || { rm -f "$tmp"; return 1; }

  # cat-over instead of mv preserves the target's permissions/ownership
  cat "$tmp" >"$target"
  rm -f "$tmp"

  if ! bash -n "$target" 2>/dev/null; then
    err "$target no longer parses after key injection - restore it from version control!"
  fi
  echo "Public key installed in: $target"
}

install_key() {
  [[ -f "$PUBLIC_KEY" ]] || err "No public key at $PUBLIC_KEY - run: $0 --init first"
  local found=false rc=0 target
  for target in "${INSTALLER_SCRIPTS[@]}"; do
    [[ -f "$target" ]] || continue
    found=true
    inject_pubkey "$target" || rc=1
  done
  if [[ "$found" == "false" ]]; then
    echo "No installer scripts found next to $0 - paste this manually into"
    echo "ONBOARDING_SIGNING_PUBKEY in both installer scripts:"
    echo ""
    cat "$PUBLIC_KEY"
  fi
  return $rc
}

init_keys() {
  if [[ -f "$PRIVATE_KEY" ]]; then
    echo "Keypair already exists at $KEY_DIR - refusing to overwrite."
    echo "Delete the directory manually if you really want to rotate keys"
    echo "(remember: rotating means updating the public key in both installer"
    echo "scripts and re-signing every hosted artifact)."
  else
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"
    echo "Generating RSA-4096 keypair in $KEY_DIR ..."
    openssl genrsa -out "$PRIVATE_KEY" 4096 2>/dev/null
    chmod 600 "$PRIVATE_KEY"
    openssl rsa -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" 2>/dev/null
    echo "Done."
  fi

  echo ""
  install_key || true
  cat <<EOF

Sign your artifacts before every upload:

  ./otk-sign.sh apps.json onboardingtoolkit.zip

IMPORTANT: never commit or upload $PRIVATE_KEY. Back it up somewhere safe
(password manager / offline). Losing it means generating a new pair and
updating the installers; leaking it means an attacker can sign malicious
config for your whole fleet.
EOF
}

sign_file() {
  local file="$1"
  [[ -f "$file" ]] || err "File not found: $file"
  openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$file.sig" "$file"
  echo "Signed: $file -> $file.sig"
}

verify_file() {
  local file="$1"
  [[ -f "$file" ]] || err "File not found: $file"
  [[ -f "$file.sig" ]] || err "Signature not found: $file.sig"
  if openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$file.sig" "$file" >/dev/null 2>&1; then
    echo "OK: $file matches $file.sig"
  else
    err "VERIFICATION FAILED for $file - do not upload this pair."
  fi
}

case "${1:-}" in
  --init)
    init_keys
    ;;
  --verify)
    [[ -f "$PUBLIC_KEY" ]] || err "No public key at $PUBLIC_KEY - run: $0 --init"
    shift
    [[ $# -ge 1 ]] || err "Usage: $0 --verify <file> [file ...]"
    for f in "$@"; do verify_file "$f"; done
    ;;
  --install-key)
    install_key
    ;;
  --help | -h)
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    [[ -f "$PRIVATE_KEY" ]] || err "No private key at $PRIVATE_KEY - run: $0 --init first"
    if [[ $# -ge 1 ]]; then
      files=("$@")
    else
      files=()
      for f in apps.json onboardingtoolkit.zip; do
        [[ -f "$f" ]] && files+=("$f")
      done
      [[ ${#files[@]} -ge 1 ]] || err "Nothing to sign: no apps.json or onboardingtoolkit.zip here. Pass files explicitly."
    fi
    for f in "${files[@]}"; do sign_file "$f"; done
    echo ""
    echo "Upload each file TOGETHER WITH its .sig to your hosting (same folder)."
    ;;
esac
