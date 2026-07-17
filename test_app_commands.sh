#!/bin/bash
# test_app_commands.sh
#
# Walk an apps.json and print (or execute) its detection / pre-install /
# post-install commands, with the same conventions the orchestrator uses:
#   - prerequisites[] and items[] (groups nested) are both covered
#   - command fields may be a string or an array (both accepted at runtime)
#   - only a literal root:/user: prefix selects context; anything else is a
#     bare command (default root) - a colon inside it is not a prefix
#   - custom_variables are substituted generically ($KEY -> value; array
#     values join with spaces), mirroring the runtime's substitution
#
# Usage: ./test_app_commands.sh [JSON_FILE] [MODE] [DRY_RUN]
#   JSON_FILE  default: apps.example.json
#   MODE       all | detection | pre | post   (default: all)
#   DRY_RUN    true | false                   (default: true - print only)
#
# Execution mode (DRY_RUN=false) sources functions/ when present next to
# this script, so custom commands (rename_device, configure_dock, ...) are
# callable - but note $INSTALLER_PATH only exists during a real install run.

JSON_FILE="${1:-apps.example.json}"
MODE="${2:-all}" # all | detection | pre | post
DRY_RUN="${3:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$JSON_FILE" ]]; then
  echo "❌ Error: JSON file not found: $JSON_FILE"
  exit 1
fi

if ! jq empty "$JSON_FILE" 2>/dev/null; then
  echo "❌ Error: $JSON_FILE is not valid JSON"
  exit 1
fi

echo "=== Testing commands from: $JSON_FILE ==="
echo "Mode: $MODE | Dry-run: $DRY_RUN"
echo

# substitute_vars <command> <item_json>
# Replace $KEY for every key in the item's custom_variables. Array values
# join with spaces. Pure-bash replacement - no sed delimiter pitfalls.
substitute_vars() {
  local cmd="$1"
  local item_json="$2"
  local key value

  while IFS=$'\t' read -r key value; do
    [[ -z "$key" ]] && continue
    cmd="${cmd//\$$key/$value}"
  done < <(echo "$item_json" | jq -r '
    .custom_variables // {} | to_entries[] |
    [.key, (if (.value | type) == "array" then (.value | join(" ")) else (.value | tostring) end)] |
    @tsv')

  echo "$cmd"
}

# run_command <role> <command>
run_command() {
  local role="$1" actual="$2"

  # Make the functions/ vocabulary available like the orchestrator's child
  # payloads do (best effort - macOS-only helpers may still no-op elsewhere).
  local payload=""
  if [[ -d "$SCRIPT_DIR/functions" ]]; then
    payload="for __otk_fn in \"$SCRIPT_DIR/functions/\"*.sh; do source \"\$__otk_fn\" 2>/dev/null; done; "
  fi
  payload+="$actual"

  if [[ "$role" == "user" ]]; then
    local current_user
    current_user=$(stat -f "%Su" /dev/console 2>/dev/null || echo "$USER")
    sudo -u "$current_user" bash -c "$payload" >/dev/null 2>&1
  else
    bash -c "$payload" >/dev/null 2>&1
  fi
}

# test_commands <item_json> <field> <indent>
test_commands() {
  local item_json="$1" field="$2" indent="$3"

  # Accept both array and string forms, exactly like the runtime.
  local cmds
  cmds=$(echo "$item_json" | jq -r --arg key "$field" '
    .[$key] // empty |
    if type == "array" then .[] else . end' 2>/dev/null)
  [[ -z "$cmds" ]] && return 0

  echo "${indent}Testing $field:"
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue

    # Only a literal root:/user: prefix is a context marker.
    local role="root" raw="$cmd"
    if [[ "$cmd" == root:* || "$cmd" == user:* ]]; then
      role="${cmd%%:*}"
      raw="${cmd#*:}"
    fi

    local actual
    actual=$(substitute_vars "$raw" "$item_json")

    echo "${indent}  [$role] $actual"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "${indent}    🧪 Dry-run: Skipped execution"
    elif run_command "$role" "$actual"; then
      echo "${indent}    ✅ OK"
    else
      echo "${indent}    ❌ Failed"
    fi
  done <<<"$cmds"
}

# test_item <item_json> <indent>
test_item() {
  local item_json="$1" indent="$2"

  case "$MODE" in
  all)
    test_commands "$item_json" "detection_commands" "$indent"
    test_commands "$item_json" "pre_install_commands" "$indent"
    test_commands "$item_json" "post_install_commands" "$indent"
    ;;
  detection) test_commands "$item_json" "detection_commands" "$indent" ;;
  pre) test_commands "$item_json" "pre_install_commands" "$indent" ;;
  post) test_commands "$item_json" "post_install_commands" "$indent" ;;
  *)
    echo "❌ Unknown mode: $MODE (use all|detection|pre|post)"
    exit 1
    ;;
  esac
}

# --- Prerequisites ---
while IFS= read -r item; do
  [[ -z "$item" ]] && continue
  name=$(echo "$item" | jq -r '.name')
  type=$(echo "$item" | jq -r '.type // "installation"')
  echo "---- [prerequisite/$type] $name ----"
  test_item "$item" "  "
  echo
done < <(jq -c '.prerequisites[]?' "$JSON_FILE")

# --- Items (groups nested) ---
while IFS= read -r item; do
  [[ -z "$item" ]] && continue
  name=$(echo "$item" | jq -r '.name')
  type=$(echo "$item" | jq -r '.type // "installation"')
  echo "---- [$type] $name ----"

  if [[ "$type" == "group" ]]; then
    while IFS= read -r subapp; do
      [[ -z "$subapp" ]] && continue
      subname=$(echo "$subapp" | jq -r '.name')
      subtype=$(echo "$subapp" | jq -r '.type // "installation"')
      echo "  ↳ [$subtype] $subname"
      test_item "$subapp" "    "
    done < <(echo "$item" | jq -c '.apps[]?')
  else
    test_item "$item" "  "
  fi
  echo
done < <(jq -c '.items[]?' "$JSON_FILE")
