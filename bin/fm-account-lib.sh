#!/usr/bin/env bash
# Registry authority for cross-home worker accounts. Source from spawn and resolver.
# An absent or malformed registry never authorizes cross-account routing.
#
# An account names the stores it owns: claude, pi and codex are each optional,
# but at least one must be present, so a Claude-only seat registers without
# borrowing another account's Pi or Codex store. A store that is present must
# still be a valid path; a present-but-malformed store invalidates the registry.
# An optional `provider` names the one quota provider family the account spends
# (claude, codex, zai, ...). It is what tells two seats that share one store
# apart (a Codex seat and a Z.ai seat both on ~/.pi/agent), and the intake and
# the resolver read only that provider's rows for the account.
# An optional `claudeTokenEnv` names a `.env.op` reference file for the account's
# Claude launches (fm_account_claude_token_env below); a present value must be a
# valid path like a store.
fm_account_registry_valid() {
  local file=$1
  [ -f "$file" ] && jq -e '
    def store_path: type == "string" and length > 2 and
      (startswith("/") or startswith("~/")) and (test("[[:cntrl:]]") | not);
    type == "object" and (.accounts | type == "object") and
    all(.accounts | to_entries[]; (.key | test("^[a-z][a-z0-9-]*$")) and
      (.value | type == "object") and
      ((.value.provider // null) == null or
        ((.value.provider | type) == "string" and (.value.provider | test("^[a-z0-9]+(-[a-z0-9]+)*$")))) and
      ((.value.claudeTokenEnv // null) == null or (.value.claudeTokenEnv | store_path)) and
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
  local file=$1 account=$2 kind=$3
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

# fm_account_canonical_store <path>: ~/ expanded, trailing slashes trimmed, and
# symlinks resolved, so a symlinked alias and its target name one store. A path
# that does not exist yet is resolved as far as it exists (realpath -m).
fm_account_canonical_store() {
  local value
  value=$(fm_account_expand_store "$1")
  [ -n "$value" ] || return 0
  realpath -m -- "$value" 2>/dev/null || printf '%s\n' "$value"
}

# fm_account_provider <file> <account>: the account's declared provider, or nothing.
fm_account_provider() {
  fm_account_registry_valid "$1" || return 0
  jq -r --arg a "$2" '.accounts[$a].provider // empty | strings' "$1" 2>/dev/null || true
}

# fm_account_seat_for_store <file> <claude|pi|codex> <store> [<provider>]: the
# registry account id that owns <store> for that kind, or nothing. Stores are
# compared after symlink resolution. Several accounts sharing one store (the Pi
# agent directory is shared between a Codex and a Z.ai seat) name no seat,
# unless <provider> is given and exactly one of them declares that provider.
# Needs a valid registry; the routing switch may be off.
fm_account_seat_for_store() {
  local file=$1 kind=$2 provider=${4:-} store matches count account candidate
  fm_account_registry_valid "$file" || return 0
  store=$(fm_account_canonical_store "$3")
  [ -n "$store" ] || return 0
  matches=
  while IFS=$'\t' read -r account candidate; do
    [ -n "$account" ] || continue
    [ "$(fm_account_canonical_store "$candidate")" = "$store" ] || continue
    matches="${matches}${account}"$'\n'
  done < <(jq -r --arg k "$kind" '.accounts | to_entries[] | select((.value[$k] // null) != null) | "\(.key)\t\(.value[$k])"' "$file" 2>/dev/null)
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -gt 1 ] && [ -n "$provider" ]; then
    matches=$(printf '%s' "$matches" | while IFS= read -r account; do
      [ -n "$account" ] || continue
      [ "$(fm_account_provider "$file" "$account")" != "$provider" ] || printf '%s\n' "$account"
    done)
    count=$(printf '%s' "$matches" | grep -c . || true)
  fi
  [ "$count" -eq 1 ] && printf '%s\n' "$(printf '%s' "$matches" | grep . )"
  return 0
}

# fm_account_registry_problems <file>: one line per problem a valid-shaped
# registry still has, so bootstrap can fail loudly instead of routing quietly
# around them. Prints nothing for an absent file or a clean registry.
#   - a declared provider whose store the account does not own (claude needs a
#     claude store; codex needs a codex or pi store; any other provider needs pi)
#   - two accounts declaring the same provider on the same canonical store, which
#     would read and bill one login twice under two names
#   - a claudeTokenEnv on an account that owns no claude store
fm_account_registry_problems() {
  local file=$1 account provider kind store key seen=''
  [ -e "$file" ] || return 0
  if ! fm_account_registry_valid "$file"; then
    printf 'malformed registry (see docs/configuration.md "Cross-account worker routing")\n'
    return 0
  fi
  jq -r '.accounts | to_entries[] | select(.value.claudeTokenEnv != null and .value.claude == null) |
    "account \(.key) sets claudeTokenEnv but owns no claude store"' "$file"
  while IFS=$'\t' read -r account provider; do
    [ -n "$account" ] || continue
    [ -n "$provider" ] || continue
    case "$provider" in
      claude) jq -e --arg a "$account" '.accounts[$a].claude != null' "$file" >/dev/null 2>&1 ||
        printf 'account %s declares provider claude but owns no claude store\n' "$account" ;;
      codex) jq -e --arg a "$account" '.accounts[$a].codex != null or .accounts[$a].pi != null' "$file" >/dev/null 2>&1 ||
        printf 'account %s declares provider codex but owns no codex or pi store\n' "$account" ;;
      *) jq -e --arg a "$account" '.accounts[$a].pi != null' "$file" >/dev/null 2>&1 ||
        printf 'account %s declares provider %s but owns no pi store\n' "$account" "$provider" ;;
    esac
    for kind in claude pi codex; do
      store=$(jq -r --arg a "$account" --arg k "$kind" '.accounts[$a][$k] // empty' "$file")
      [ -n "$store" ] || continue
      key="$provider|$kind|$(fm_account_canonical_store "$store")"
      case "$seen" in
        *$'\n'"$key="*)
          printf 'accounts %s and %s both declare provider %s on %s store %s\n' \
            "$(printf '%s' "$seen" | grep -F "$key=" | head -1 | sed 's/.*=//')" "$account" "$provider" "$kind" "${key##*|}" ;;
      esac
      seen="$seen"$'\n'"$key=$account"
    done
  done < <(jq -r '.accounts | to_entries[] | "\(.key)\t\(.value.provider // "")"' "$file")
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

# ---- long-lived Claude token (claudeTokenEnv) ----------------------------------
# An account may name in `claudeTokenEnv` a `.env.op` file whose
# CLAUDE_CODE_OAUTH_TOKEN 1Password reference (a `claude setup-token` token)
# `opr -f <file> --` injects into that seat's Claude task-worker launches, so the
# seat keeps working after its stored /login ends. Claude ranks that token above
# the stored login, so a configured seat always runs on it. Only the file path is
# configuration: the file holds references only, and nothing here reads a
# reference or value into launch text, records, or output.

# fm_account_claude_token_env <file> <account>: the account's claudeTokenEnv
# with ~/ expanded, or nothing. Needs a valid registry; the routing switch may be off.
fm_account_claude_token_env() {
  local value
  [ -n "$2" ] || return 0
  fm_account_registry_valid "$1" || return 0
  value=$(jq -r --arg a "$2" '.accounts[$a].claudeTokenEnv // empty | strings' "$1" 2>/dev/null) || return 0
  [ -z "$value" ] || fm_account_expand_store "$value"
}

# fm_account_claude_token_check <account> <token-env>: one error and rc 1 when a
# launch cannot carry the token - opr or script missing (script keeps Claude's
# interactive terminal behind opr's output pipe), or the file unreadable or
# declaring no CLAUDE_CODE_OAUTH_TOKEN. Only the variable name is matched.
fm_account_claude_token_check() {
  local account=$1 envfile=$2 why=
  if ! command -v opr >/dev/null 2>&1; then
    why='opr is not on PATH'
  elif ! command -v script >/dev/null 2>&1; then
    why='script is not on PATH'
  elif [ ! -f "$envfile" ] || [ ! -r "$envfile" ]; then
    why="$envfile is not a readable file"
  elif ! grep -Eq '^[[:space:]]*(export[[:space:]]+)?CLAUDE_CODE_OAUTH_TOKEN=' "$envfile" 2>/dev/null; then
    why="$envfile declares no CLAUDE_CODE_OAUTH_TOKEN"
  fi
  [ -n "$why" ] || return 0
  echo "error: account '$account' runs Claude on its claudeTokenEnv token (config/accounts.json), but $why; nothing was launched" >&2
  return 1
}

# ---- six-account dispatch guard (S1) -------------------------------------------
# fm_account_dispatch_problems <accounts-file> <crew-dispatch-file>: one line per
# dispatch profile that would route silently. With a valid registry present,
# every rule and default profile must name a registered account; a profile
# without one would fall onto the home pin store (the supervisor's own login).
# A named account must own the store its harness launches from, and an account
# that declares a provider must match the profile's provider family. Prints
# nothing when no registry exists, so homes without accounts are unchanged.
fm_account_dispatch_problems() {
  local accounts=$1 rules=$2
  [ -f "$rules" ] || return 0
  fm_account_registry_valid "$accounts" || return 0
  jq -r --slurpfile reg "$accounts" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def store_kind($h): {"claude":"claude","pi":"pi","pi-signed":"pi","codex":"codex"}[$h] // null;
    def family($p): $p.provider // ({"claude":"claude","codex":"codex","opencode":"codex"}[$p.harness] // null);
    def plabel($p): "\($p.harness):\($p.model // "default")/\($p.effort // "default")";
    ($reg[0].accounts) as $acc |
    ([(.rules // []) | to_entries[] | .key as $i | profiles(.value.use)[] | {where: "rule \($i + 1)", p: .}]
      + [profiles(.default // null)[] | {where: "default", p: .}]
      + [(.pipeline_rows | if type == "array" then . else [] end) | to_entries[] | .key as $i | (.value | objects | .use | arrays)[] | {where: "pipeline row \($i + 1)", p: .}])[] |
    .where as $w | .p as $p |
    if ($p | type) != "object" then empty
    elif ($p.account // null) == null then "\($w) profile \(plabel($p)) names no account; with config/accounts.json present every profile must name one"
    elif $acc[$p.account] == null then "\($w) profile \(plabel($p)) names unregistered account \($p.account)"
    elif store_kind($p.harness) != null and $acc[$p.account][store_kind($p.harness)] == null then
      "\($w) profile \(plabel($p)) runs on \($p.harness) but account \($p.account) owns no \(store_kind($p.harness)) store"
    elif ($acc[$p.account].provider // null) != null and family($p) != null and family($p) != $acc[$p.account].provider then
      "\($w) profile \(plabel($p)) spends provider \(family($p)) but account \($p.account) declares provider \($acc[$p.account].provider)"
    else empty end
  ' "$rules" 2>/dev/null || printf 'crew dispatch file is not JSON\n'
}

# fm_account_pipeline_problems <crew-dispatch-file>: one line per problem in the
# optional top-level pipeline_rows, shared by the resolver and bootstrap.
# docs/configuration.md "Pipeline seat rows" owns the fields. Prints nothing for a
# file that is not a JSON object, whose own diagnostic belongs to its caller.
fm_account_pipeline_problems() {
  local rules=$1
  [ -f "$rules" ] || return 0
  jq -r '
    def family($p): $p.provider // ({"claude":"claude","codex":"codex","opencode":"codex"}[$p.harness] // null);
    def tier_ok($t): ($t | type) == "number" and $t >= 1 and ($t | floor) == $t;
    def row_problems($w):
      if type != "object" then "\($w) must be an object"
      elif (.steps | type) != "array" or (.steps | length) == 0 or any(.steps[]; type != "string" or length == 0) then "\($w) needs steps, a non-empty array of step names"
      elif (.never_providers | type) != "array" or (.never_providers | length) == 0 or any(.never_providers[]; type != "string") then "\($w) needs never_providers, a non-empty array of provider IDs"
      elif (.use | type) != "array" or (.use | length) == 0 or any(.use[]; type != "object") then "\($w) needs use, a non-empty array of profile objects"
      else . as $row |
        (.use[] | . as $p | "\($p.harness // "?"):\($p.model // "default")" as $l |
          if ($p.account | type) != "string" then "\($w) profile \($l) must name an account"
          elif ($p.pool != 1 and $p.pool != 2) then "\($w) profile \($l) pool must be 1 or 2"
          elif (tier_ok($p.seat_tier) | not) then "\($w) profile \($l) seat_tier must be a positive integer"
          elif ($p.reasoning_class | type) != "number" then "\($w) profile \($l) reasoning_class must be a number"
          elif $p | has("fallback_only") then "\($w) profile \($l) must not set fallback_only: the seat tier orders the pools"
          elif ($p | has("weekly_floor_percent")) and (($p.weekly_floor_percent | type) != "number" or $p.weekly_floor_percent < 0 or $p.weekly_floor_percent > 100) then "\($w) profile \($l) weekly_floor_percent must be a number from 0 through 100"
          elif (family($p) as $f | $f != null and ($row.never_providers | index($f)) != null) then "\($w) profile \($l) spends provider \(family($p)), which never_providers bans"
          else empty end),
        (if all(.use[]; (.seat_tier | type) == "number" and (.pool == 1 or .pool == 2)) then
           (if any(.use[]; .pool == 1) | not then "\($w) needs a pool 1 profile" else empty end),
           ([.use[] | select(.pool == 1) | .seat_tier] | max) as $last_one |
           ([.use[] | select(.pool == 2) | .seat_tier] | min) as $first_two |
           (if $first_two != null and $last_one != null and $first_two <= $last_one then "\($w) pool 2 seat_tier values must all follow pool 1" else empty end)
         else empty end),
        # Classes may step down between tiers (a class 4 row may close with a
        # class 3 GLM tier), but a tier must share one class so no fallback
        # inside it lowers the step.
        (.use | group_by(.seat_tier)[] | select((map(.reasoning_class) | unique | length) > 1)
          | "\($w) profiles of seat_tier \(.[0].seat_tier) must share one reasoning_class, so no fallback lowers the step"),
        (if (.use | map(.account) | length) != (.use | map(.account) | unique | length) then "\($w) must not list an account twice" else empty end)
      end;
    if type != "object" or (has("pipeline_rows") | not) then empty
    elif (.pipeline_rows | type) != "array" or (.pipeline_rows | length) == 0 then "pipeline_rows must be a non-empty array"
    else
      (.pipeline_rows | to_entries[] | .key as $i | .value | row_problems("pipeline row \($i + 1)")),
      ([.pipeline_rows[] | objects | .steps | arrays | .[]] | group_by(.) | map(select(length > 1) | .[0]) | .[] | "pipeline step \(.) is named by more than one row")
    end
  ' "$rules" 2>/dev/null || true
}

# fm_account_coverage_gaps <accounts-file> <crew-dispatch-file>: S7 audit. For
# every rule and the default, each distinct harness/model/effort rung of a
# provider must list every registered account that declares that provider, so
# one seat at its limit never strands a rung. Prints one line per gap, and one
# note per provider served by a single account (a single point of failure).
fm_account_coverage_gaps() {
  local accounts=$1 rules=$2
  [ -f "$rules" ] || return 0
  fm_account_registry_valid "$accounts" || return 0
  jq -r --slurpfile reg "$accounts" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    def family($p): $p.provider // ({"claude":"claude","codex":"codex","opencode":"codex"}[$p.harness] // null);
    ($reg[0].accounts | to_entries | map(select(.value.provider != null)) | group_by(.value.provider)
      | map({key: .[0].value.provider, value: map(.key)}) | from_entries) as $byp |
    ([(.rules // []) | to_entries[] | {where: "rule \(.key + 1)", use: profiles(.value.use)}]
      + [{where: "default", use: profiles(.default // null)}]) as $rows |
    ([$rows[] | .where as $w | .use | group_by([.harness, (.model // ""), (.effort // ""), (family(.) // "")])[]
      | (family(.[0])) as $f | select($f != null and $byp[$f] != null)
      | ([.[].account] | map(select(. != null))) as $have
      | ($byp[$f] - $have) as $missing | select(($missing | length) > 0)
      | "gap: \($w) \(.[0].harness):\(.[0].model // "default")/\(.[0].effort // "default") lacks \($f) account(s) \($missing | join(", "))"]
    + [$byp | to_entries[] | select((.value | length) == 1) | "single point: provider \(.key) has one account (\(.value[0]))"]) | .[]
  ' "$rules" 2>/dev/null || true
}
