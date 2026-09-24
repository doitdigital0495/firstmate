#!/usr/bin/env bash
# Registry authority for cross-home worker accounts. Source from spawn and resolver.
# An absent or malformed registry never authorizes cross-account routing.
fm_account_registry_valid() {
  local file=$1
  [ -f "$file" ] && jq -e '
    def store_path: type == "string" and length > 2 and
      (startswith("/") or startswith("~/")) and (test("[[:cntrl:]]") | not);
    type == "object" and (.accounts | type == "object") and
    all(.accounts | to_entries[]; (.key | test("^[a-z][a-z0-9-]*$")) and
      (.value | type == "object") and
      all([.value.claude, .value.pi, .value.codex][]; store_path)) and
    ((.crossAccount // null) == null or
      ((.crossAccount | type) == "object" and (.crossAccount.enabled | type) == "boolean"))
  ' "$file" >/dev/null 2>&1
}

fm_account_enabled() {
  fm_account_registry_valid "$1" && jq -e '.crossAccount.enabled == true' "$1" >/dev/null 2>&1
}

# Emit three absolute store paths, in Claude/Pi/Codex order. No shell evaluation.
fm_account_stores() {
  local file=$1 account=$2 home=${HOME:?HOME must be set} values
  fm_account_enabled "$file" || return 1
  values=$(jq -r --arg a "$account" '
    .accounts[$a] // empty | [.claude, .pi, .codex] | .[]
  ' "$file") || return 1
  [ "$(printf '%s\n' "$values" | wc -l)" -eq 3 ] || return 1
  while IFS= read -r value; do
    # shellcheck disable=SC2088 # Literal registry prefix, not shell expansion.
    case "$value" in
      '~/'*) printf '%s/%s\n' "$home" "${value:2}" ;;
      /*) printf '%s\n' "$value" ;;
      *) return 1 ;;
    esac
  done <<< "$values"
}
