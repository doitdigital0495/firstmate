#!/usr/bin/env bash
# Registry authority for cross-home worker accounts. Source from spawn and resolver.
# An absent or malformed registry never authorizes cross-account routing.
#
# An account names the stores it owns: claude, pi and codex are each optional,
# but at least one must be present, so a Claude-only seat registers without
# borrowing another account's Pi or Codex store. A store that is present must
# still be a valid path; a present-but-malformed store invalidates the registry.
fm_account_registry_valid() {
  local file=$1
  [ -f "$file" ] && jq -e '
    def store_path: type == "string" and length > 2 and
      (startswith("/") or startswith("~/")) and (test("[[:cntrl:]]") | not);
    type == "object" and (.accounts | type == "object") and
    all(.accounts | to_entries[]; (.key | test("^[a-z][a-z0-9-]*$")) and
      (.value | type == "object") and
      ([.value.claude, .value.pi, .value.codex] | map(select(. != null))) as $present |
      ($present | length) > 0 and all($present[]; store_path)) and
    ((.crossAccount // null) == null or
      ((.crossAccount | type) == "object" and (.crossAccount.enabled | type) == "boolean"))
  ' "$file" >/dev/null 2>&1
}

fm_account_enabled() {
  fm_account_registry_valid "$1" && jq -e '.crossAccount.enabled == true' "$1" >/dev/null 2>&1
}

# The line fm_account_stores prints for a store the account does not own. A
# literal marker rather than an empty line, so it survives command substitution
# and can never be mistaken for "use the ambient store". Callers that need that
# store refuse (fm_account_require_store); callers that only read a snapshot
# point the missing store at an empty location instead of the personal one.
FM_ACCOUNT_NO_STORE=-

# Emit three lines, in Claude/Pi/Codex order: an absolute store path, or
# $FM_ACCOUNT_NO_STORE for a store the account does not own. No shell evaluation.
fm_account_stores() {
  local file=$1 account=$2 home=${HOME:?HOME must be set} values value out=()
  fm_account_enabled "$file" || return 1
  values=$(jq -r --arg a "$account" '
    .accounts[$a] // empty | [.claude, .pi, .codex] | map(. // "-") | .[]
  ' "$file") || return 1
  [ "$(printf '%s\n' "$values" | wc -l)" -eq 3 ] || return 1
  while IFS= read -r value; do
    # shellcheck disable=SC2088 # Literal registry prefix, not shell expansion.
    case "$value" in
      -) out+=("$FM_ACCOUNT_NO_STORE") ;;
      '~/'*) out+=("$home/${value:2}") ;;
      /*) out+=("$value") ;;
      *) return 1 ;;
    esac
  done <<< "$values"
  printf '%s\n' "${out[@]}"
}

# fm_account_has_store <stores-text> <claude|pi|codex>: whether the account owns it.
fm_account_has_store() {
  local idx
  case "$2" in claude) idx=1 ;; pi) idx=2 ;; codex) idx=3 ;; *) return 1 ;; esac
  [ "$(printf '%s\n' "$1" | sed -n "${idx}p")" != "$FM_ACCOUNT_NO_STORE" ] &&
    [ -n "$(printf '%s\n' "$1" | sed -n "${idx}p")" ]
}

# fm_account_require_store <file> <account> <claude|pi|codex>: a registered seat
# that does not own the store the launch needs is refused by name; an account the
# registry does not know is not this function's to judge and passes through.
fm_account_require_store() {
  local file=$1 account=$2 kind=$3 stores
  fm_account_registry_valid "$file" || return 0
  jq -e --arg a "$account" '.accounts[$a] != null' "$file" >/dev/null 2>&1 || return 0
  if jq -e --arg a "$account" --arg k "$kind" '.accounts[$a][$k] != null' "$file" >/dev/null 2>&1; then
    return 0
  fi
  echo "error: account '$account' has no $kind store in config/accounts.json; it cannot launch a $kind worker and no other account's store is borrowed" >&2
  return 1
}

# fm_account_read_store <claude|pi|codex> <store>: the path a READ-ONLY consumer
# (a quota snapshot) should pin for a store. A store the account does not own
# maps to a location that never exists, so the snapshot reports that provider as
# signed out instead of reading the personal home's login.
fm_account_read_store() {
  if [ "$2" = "$FM_ACCOUNT_NO_STORE" ] || [ -z "$2" ]; then
    printf '/nonexistent/fm-account-no-%s-store\n' "$1"
  else
    printf '%s\n' "$2"
  fi
}

# ---- worker seat label ---------------------------------------------------------
# A worker window shows which subscription it runs on: the seat id, its plan and
# the login email. Everything here is non-secret by construction: seat ids and
# plan names come from config/accounts.json, and the email is the single
# oauthAccount.emailAddress field of a Claude store's .claude.json (the same
# source and validation agentic-setup's seat-info uses). No credential file is
# opened, and no process environment is read.

# fm_account_expand_store <path>: ~/ expanded, trailing slashes trimmed.
fm_account_expand_store() {
  local value=$1 home=${HOME:?HOME must be set}
  # shellcheck disable=SC2088 # Literal registry prefix, not shell expansion.
  case "$value" in '~/'*) value="$home/${value:2}" ;; esac
  while [ "${#value}" -gt 1 ] && [ "${value%/}" != "$value" ]; do value=${value%/}; done
  printf '%s\n' "$value"
}

# fm_account_seat_for_store <file> <claude|pi|codex> <store>: the registry
# account id that owns <store> for that kind, or nothing. Several accounts
# sharing one store (the Pi agent directory is shared between seats) is
# ambiguous and names no seat. Needs a valid registry; the routing switch may be off.
fm_account_seat_for_store() {
  local file=$1 kind=$2 store matches count
  fm_account_registry_valid "$file" || return 0
  store=$(fm_account_expand_store "$3")
  [ -n "$store" ] || return 0
  matches=$(jq -r --arg k "$kind" --arg home "${HOME:?}" --arg s "$store" '
    def norm: if startswith("~/") then $home + .[1:] else . end
              | sub("/+$"; "");
    .accounts | to_entries[] | select((.value[$k] // null) != null and ((.value[$k] | norm) == $s)) | .key
  ' "$file" 2>/dev/null) || return 0
  count=$(printf '%s' "$matches" | grep -c . || true)
  [ "$count" -eq 1 ] && printf '%s\n' "$matches"
  return 0
}

# fm_account_label_text <text> <max>: printable label text only.
fm_account_label_text() {
  printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9 ._@%+/-' | cut -c1-"$2"
}

# fm_account_claude_email <claude-store>: the store's login email, or nothing.
fm_account_claude_email() {
  local store=$1 email
  case "$store" in ''|default) store="${HOME:?}/.claude" ;; esac
  [ -f "$store/.claude.json" ] || return 0
  email=$(jq -r '.oauthAccount.emailAddress // empty | strings' "$store/.claude.json" 2>/dev/null) || return 0
  email=$(printf '%s' "$email" | LC_ALL=C tr -d '[:cntrl:]')
  if printf '%s' "$email" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+$'; then
    printf '%s\n' "$email" | cut -c1-120
  fi
  return 0
}

# fm_account_seat_label <file> <seat> <plan-provider> [<claude-store>]
# Prints "seat · plan · email", or "seat · plan" when no email is known, or just
# the seat when no plan is declared. Prints nothing without a seat.
fm_account_seat_label() {
  local file=$1 seat=$2 provider=$3 store=${4:-} plan email label
  [ -n "$seat" ] || return 0
  plan=
  if fm_account_registry_valid "$file"; then
    plan=$(jq -r --arg a "$seat" --arg p "$provider" '(.accounts[$a].plans // {})[$p] // empty | strings' "$file" 2>/dev/null) || plan=
  fi
  email=
  [ -z "$store" ] || email=$(fm_account_claude_email "$store")
  label=$(fm_account_label_text "$seat" 40)
  [ -z "$plan" ] || label="$label · $(fm_account_label_text "$plan" 80)"
  [ -z "$email" ] || label="$label · $(fm_account_label_text "$email" 120)"
  printf '%s\n' "$label"
}
