#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned provider response.
# A fake quota-axi serves the selected schema-5 fixture. A fake security and a
# fake uname stand in for the macOS Keychain, so no case reads the real one.
# No case touches the network, and the absent-key case proves the tool makes
# no call at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
NO_SECURITY_BIN="$TMP_ROOT/no-security-bin"
NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_RULES="$TMP_ROOT/rules.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN" "$NO_SECURITY_BIN" "$NO_JQ_BIN"
for command_name in bash chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
  ln -s "$(command -v "$command_name")" "$NO_SECURITY_BIN/$command_name"
done
# The minimal PATHs that simulate one missing command: no security, or no jq.
# Both keep the fake macOS uname, and the no-jq one keeps the fake security.
for command_name in bash chmod cp dirname mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_JQ_BIN/$command_name"
done
ln -s "$FAKEBIN/uname" "$NO_SECURITY_BIN/uname"
ln -s "$FAKEBIN/uname" "$NO_JQ_BIN/uname"
ln -s "$FAKEBIN/security" "$NO_JQ_BIN/security"

cat > "$BRIEF" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh, expected behavior is one page per call.
MD

cat > "$BASE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "New feature work on the app.",
      "floor": { "scope": "model:fable", "min_percent": 20, "provider": "claude" },
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" },
      "why": "SECRET-WHY-TEXT feature work wants the strongest model"
    },
    {
      "when": "The task generates images.",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol", "floor": { "scope": "all_models", "min_percent": 50 } }
      ]
    },
    {
      "when": "Genuinely very difficult design or planning work.",
      "approval": "captain",
      "use": { "harness": "claude", "model": "fable", "effort": "xhigh" }
    },
    {
      "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "claude", "model": "sonnet", "effort": "high" },
        { "harness": "cursor", "model": "cursor-grok-4.6-medium" }
      ]
    }
  ],
  "default": [
    { "harness": "claude", "model": "opus" },
    { "harness": "cursor", "model": "cursor-grok-4.6-high" }
  ]
}
JSON
cp "$BASE_RULES" "$RULES"

write_quota() {  # <path> <cursor spendPriority> [<claude all_models spendPriority>]
  local path=$1 cursor=$2 claude=${3:--0.4627}
  cat > "$path" <<JSON
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 93, "resetsAt": "2030-01-01T04:00:00Z" },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": 79, "resetsAt": "2030-01-04T00:00:00Z" },
        { "id": "model:fable", "kind": "model", "percentRemaining": 15, "resetsAt": "2030-01-04T00:00:00Z" } ],
      "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 79, "boundedBy": ["five_hour", "seven_day"], "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": $claude } },
      { "scope": "model:fable", "status": "known", "effectivePercentRemaining": 15, "boundedBy": ["five_hour", "seven_day", "model:fable"], "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.79 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" },
      "windows": [ { "id": "weekly", "kind": "weekly", "percentRemaining": 31, "resetsAt": "2030-01-06T00:00:00Z" } ],
      "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 31, "boundedBy": ["weekly"], "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.1649 } } ] } },
    { "provider": "cursor", "state": { "status": "fresh" },
      "windows": [ { "id": "weekly", "kind": "weekly", "percentRemaining": 91, "resetsAt": "2030-01-03T00:00:00Z" } ],
      "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 91, "boundedBy": ["weekly"], "runway": { "status": "through_reset" }, "selection": { "spendPriority": $cursor } } ] } },
    { "provider": "agy", "state": { "status": "fresh" },
      "windows": [ { "id": "weekly", "kind": "weekly", "percentRemaining": 64, "resetsAt": "2030-01-02T00:00:00Z" } ],
      "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "boundedBy": ["weekly"], "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.4 } } ] } },
    { "provider": "google", "state": { "status": "fresh" },
      "windows": [ { "id": "weekly", "kind": "weekly", "percentRemaining": 72, "resetsAt": "2030-01-02T00:00:00Z" } ],
      "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 72, "boundedBy": ["weekly"], "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.3 } } ] } },
    { "provider": "kimi", "state": { "status": "unknown" }, "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } }
  ]
}
JSON
}
write_quota "$QUOTA" 0.7597

add_profile_response() { # <response file>; fixtures use one valid profile Choice.
  local response=$1 tmp
  tmp=$(mktemp)
  jq --slurpfile rules "$RULES" '
    ([$rules[0].rules | to_entries[] | .key as $i | .value.use |
      (if type == "array" then . else [.] end) | to_entries[] | "rule_\($i + 1)_\(.key + 1)"]) as $ids |
    .answers.profile = {type: "choice", choice: $ids[0], confidence: 0.95,
      probabilities: ($ids | map({key: ., value: (if . == $ids[0] then 1 else 0 end)}) | from_entries)}
  ' "$response" > "$tmp" && mv "$tmp" "$response"
}
write_response() {  # <path> <choice> <confidence>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": 0.01, "rule_2": 0.01, "rule_3": 0.01, "rule_4": 0.96, "default": 0.01 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
  add_profile_response "$1"
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] ||
  [ -n "${DIRECT_API_KEY_PRIVATE+x}" ] || [ -n "${TS_KEY+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
# With a canary file named, also look for the canary's VALUE in this process's
# environment and in the directories the test lists, where the tool's own
# files live while the request is in flight.
if [ -n "${FAKE_CANARY_FILE:-}" ]; then
  canary=$(cat "$FAKE_CANARY_FILE")
  env | grep -qF -- "$canary" && printf 'curl:canary-in-env\n' >> "${CHILD_ENV_LOG:?}"
  for dir in ${FAKE_CANARY_DIRS:-}; do
    grep -rqF -- "$canary" "$dir" 2>/dev/null && printf 'curl:canary-in-file\n' >> "${CHILD_ENV_LOG:?}"
  done
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ -n "${FAKE_CURL_MUTATE_SOURCE:-}" ]; then
  cp "$FAKE_CURL_MUTATE_SOURCE" "${FAKE_CURL_MUTATE_TARGET:?}"
fi
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] ||
  [ -n "${DIRECT_API_KEY_PRIVATE+x}" ] || [ -n "${TS_KEY+x}" ]; then
  printf 'quota-axi:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'quota-axi:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
if [ -n "${FAKE_CANARY_FILE:-}" ] && env | grep -qF -- "$(cat "$FAKE_CANARY_FILE")"; then
  printf 'quota-axi:canary-in-env\n' >> "${CHILD_ENV_LOG:?}"
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
[ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
[ "${1:-}" = --json ] || exit 2
call_index=$(grep -c . "${QUOTA_AXI_CALLS:?}" || true)
if [ -n "${GERIS_QUOTA_FIXTURE:-}" ] && [ "${CODEX_HOME:-}" = "$HOME/.codex-geris" ]; then
  printf 'geris pinned\n' >> "${QUOTA_AXI_CALLS:?}"
  # pinned-call count separates the first probe from its retries
  pinned_index=$(grep -c 'geris pinned' "${QUOTA_AXI_CALLS:?}" || true)
  if [ -n "${GERIS_QUOTA_RETRY_FIXTURE:-}" ] && [ "$pinned_index" -ge 2 ]; then
    cat "$GERIS_QUOTA_RETRY_FIXTURE"
  elif [ "${FAKE_GERIS_QUOTA_FAIL:-0}" = 1 ]; then
    exit 1
  else
    cat "$GERIS_QUOTA_FIXTURE"
  fi
elif [ -n "${QUOTA_AXI_RETRY_FIXTURE:-}" ] && [ "$call_index" -ge 2 ]; then
  cat "$QUOTA_AXI_RETRY_FIXTURE"
else
  cat "${QUOTA_AXI_FIXTURE:?}"
fi
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$FAKEBIN/zai-window-warm" <<'SH'
#!/usr/bin/env bash
printf 'warm\n' >> "${ZAI_WARM_LOG:?}"
SH
chmod +x "$FAKEBIN/zai-window-warm"

cat > "$FAKEBIN/security" <<'SH'
#!/usr/bin/env bash
# Fake security: the Keychain stand-in. It answers only an exact
# `find-generic-password -s <service> [-a <account>] -w` query, from the item
# file FAKE_SECURITY_STORE/<service>, and records argv and whether a key
# variable reached its environment. FAKE_SECURITY_EXIT fails the query after
# printing the item to stdout and stderr as a decoy, and FAKE_SECURITY_HANG
# names a file to receive its pid before it stops answering.
set -u
printf '%s\n' "$*" >> "${FAKE_SECURITY_LOG:?}"
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] ||
  [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'security:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'security:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
[ "${1:-}" = find-generic-password ] || exit 2
shift
service='' wants_password=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) [ $# -ge 2 ] || exit 2; service=$2; shift 2 ;;
    -a) { [ $# -ge 2 ] && [ -n "$2" ]; } || exit 2; shift 2 ;;
    -w) wants_password=1; shift ;;
    *) exit 2 ;;
  esac
done
[ -n "$service" ] && [ "$wants_password" = 1 ] || exit 2
if [ -n "${FAKE_SECURITY_HANG:-}" ]; then
  printf '%s\n' "$$" > "$FAKE_SECURITY_HANG"
  exec sleep 60
fi
item="${FAKE_SECURITY_STORE:?}/$service"
if [ -n "${FAKE_SECURITY_EXIT:-}" ]; then
  if [ -r "$item" ]; then
    cat "$item"
    printf 'security: could not use the item holding %s\n' "$(cat "$item")" >&2
  fi
  exit "$FAKE_SECURITY_EXIT"
fi
[ -r "$item" ] || exit 44
cat "$item"
SH
chmod +x "$FAKEBIN/security"

cat > "$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
# Fake uname: the host is macOS unless FAKE_UNAME names another system.
printf '%s\n' "${FAKE_UNAME:-Darwin}"
SH
chmod +x "$FAKEBIN/uname"

RESPONSE="$TMP_ROOT/response.json"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env" ZAI_WARM_LOG="$LOG/zai-warm.calls" FAKE_SECURITY_LOG="$LOG/security.argv"
# Retry tests keep the bounded gather fast; production defaults live in the tool.
export FM_DISPATCH_QUOTA_BACKOFF_MS="${FM_DISPATCH_QUOTA_BACKOFF_MS:-20}"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME; OPENROUTER_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code route=${FM_DISPATCH_ROUTE:-}
  shift 3
  # Upstream cases use the direct key; explicitly select the fork's direct
  # fallback rather than silently changing production default-route authority.
  if [ -n "${TYPESAFE_API_KEY:-}" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then route=direct; fi
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_DISPATCH_ROUTE="$route" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

run_without_curl() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$NO_CURL_BIN" FM_HOME="$HOME_DIR" OPENROUTER_API_KEY="$KEY" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

# run_on_path <path> <exit-var> <out-var> <err-var> [args...]: the tool on a
# caller-built PATH, for the cases that simulate a missing command.
run_on_path() {
  local __path=$1 __exit=$2 __out=$3 __err=$4 _out _code
  shift 4
  _out=$(PATH="$__path" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

# --- preferred family: public resolution across accounts of one family -----
test_preferred_provider() (
  local scenario=$1 expected="--harness 'pi' --model 'openai-codex/gpt-6-astra'"
  local decision='codex: prefer eligible family candidates' status=clear
  local rules_filter='.' quota_filter='.' override_dir=''
  jq '.preferred_provider = "codex" | .rules[3].use = [
    {harness:"claude",model:"opus"},
    {harness:"pi",model:"openai-codex/gpt-6-astra",provider:"codex"},
    {harness:"pi",model:"openai-codex-work/gpt-6-astra",provider:"codex"}]' "$BASE_RULES" > "$TMP_ROOT/preferred-rules.json"
  jq '.schemaVersion = 6 | .providers |= map(.accountKey = "default") |
    (.providers[] | select(.provider == "claude").quotaSemantics.effectiveAvailability[0]) |=
      (.effectivePercentRemaining = 26 | .selection.spendPriority = 0.8) |
    (.providers[] | select(.provider == "codex")) |=
      (.accountKey = "openai-codex" | .quotaSemantics.effectiveAvailability[0] |=
        (.effectivePercentRemaining = 82 | .runway.status = "through_reset" | .selection.spendPriority = 0.2)) |
    .providers += [(.providers[] | select(.provider == "codex") | .accountKey = "openai-codex-work" |
      .quotaSemantics.effectiveAvailability[0].selection.spendPriority = 0.1)]' "$QUOTA" > "$TMP_ROOT/preferred-quota.json"
  case "$scenario" in
    astra-82-claude-26) ;;
    work-account)
      quota_filter='(.providers[] | select(.accountKey == "openai-codex-work").quotaSemantics.effectiveAvailability[0].selection.spendPriority) = 0.3'
      expected="--harness 'pi' --model 'openai-codex-work/gpt-6-astra'" ;;
    exhausted)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[0].runway.status) = "exhausted_now"'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: fall back; every matched family candidate is ineligible' ;;
    # The fork's completeness gate answers before any family preference: an
    # unmeasured preferred candidate makes the whole choice incomplete.
    unknown)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics) = {status:"unknown",effectiveAvailability:[]}'
      status=incomplete; expected=''; decision='' ;;
    unknown-one-known-one)
      quota_filter='(.providers[] | select(.accountKey == "openai-codex").quotaSemantics) = {status:"unknown",effectiveAvailability:[]}'
      status=incomplete; expected=''; decision='' ;;
    claude-only)
      rules_filter='.rules[3].use = [.rules[3].use[0]]'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: not in matched profiles; preserve the selected rule' ;;
    config-override)
      override_dir="$TMP_ROOT/preferred-override"; mkdir -p "$override_dir"
      jq '.preferred_provider = "claude"' "$TMP_ROOT/preferred-rules.json" > "$override_dir/crew-dispatch.json"
      expected="--harness 'claude' --model 'opus'"
      decision='claude: prefer eligible family candidates' ;;
    prose-why)
      rules_filter='.rules[3].why = "Always choose Claude instead of OpenAI."' ;;
    absent)
      rules_filter='del(.preferred_provider)'
      expected="--harness 'claude' --model 'opus'"; decision='' ;;
    approval)
      rules_filter='.rules[3].approval = "captain"'
      status=escalate; expected=''; decision='' ;;
    tie)
      quota_filter='(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[0].selection.spendPriority) = 0.2'
      status=escalate; expected='' ;;
    floor)
      rules_filter='(.rules[3].use[] | select(.provider == "codex").floor) = {scope:"all_models",min_percent:90}'
      expected="--harness 'claude' --model 'opus'"
      decision='codex: fall back; every matched family candidate is ineligible' ;;
  esac
  jq "$rules_filter" "$TMP_ROOT/preferred-rules.json" > "$RULES"
  write_response "$RESPONSE" rule_4 0.9
  jq "$quota_filter" "$TMP_ROOT/preferred-quota.json" > "$TMP_ROOT/preferred-case-quota.json"
  reset_log
  TYPESAFE_API_KEY=$KEY FM_CONFIG_OVERRIDE="${override_dir:-$HOME_DIR/config}" \
    QUOTA_AXI_FIXTURE="$TMP_ROOT/preferred-case-quota.json" \
    run code out err "$BRIEF"
  expect_code 0 "$code" "$scenario resolves"
  assert_contains "$out" "  status: $status" "$scenario status"
  if [ -n "$expected" ]; then
    assert_contains "$out" "  profile: $expected" "$scenario choice"
  else
    assert_not_contains "$out" '  profile:' "$scenario cannot authorize a profile"
  fi
  if [ -n "$decision" ]; then
    assert_contains "$out" "  preferred_provider: $decision" "$scenario explains the family decision"
  else
    assert_not_contains "$out" '  preferred_provider:' "$scenario does not apply preference"
  fi
  if [ "$scenario" = prose-why ]; then
    assert_not_contains "$(cat "$LOG/body")" 'Always choose Claude' 'rule why never reaches the rule matcher'
  fi
  pass "preferred provider: $scenario"
)
test_invalid_preferred_provider() (
  local value=$1
  jq --argjson value "$value" '.preferred_provider = $value' "$BASE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "invalid preferred_provider $value is refused"
  assert_contains "$err" 'preferred_provider must be a lowercase provider ID (for example codex)' 'actionable preference error'
  assert_absent "$LOG/argv" 'invalid preference never reaches the rule matcher'
  assert_absent "$LOG/quota-axi.calls" 'invalid preference never reads quota'
  pass "invalid preferred_provider: $value"
)
preferred_failures=0
for value in null false 42 '[]' '{}' '""' '"Codex"' '"codex\\n"' '" codex"'; do
  test_invalid_preferred_provider "$value" || preferred_failures=$((preferred_failures + 1))
done
for scenario in astra-82-claude-26 work-account exhausted unknown unknown-one-known-one claude-only config-override prose-why absent approval tie floor; do
  test_preferred_provider "$scenario" || preferred_failures=$((preferred_failures + 1))
done
[ "$preferred_failures" -eq 0 ] || fail "$preferred_failures preferred-provider cases failed"
cp "$BASE_RULES" "$RULES"
reset_log

# --- absent key: off, silent on stdout, no network, no quota read -----------
# The worker shell may export a key; this outcome must hold without one.
reset_log
write_response "$RESPONSE" rule_4 0.9
( unset OPENROUTER_API_KEY OPENROUTER_API_KEY_PRIVATE
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$BRIEF" --project pager
) > "$TMP_ROOT/sub-out" 2> "$TMP_ROOT/sub-err"
code=$?
out=$(cat "$TMP_ROOT/sub-out")
err=$(cat "$TMP_ROOT/sub-err")
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (OPENROUTER_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent key never reads quota-axi"
pass "absent key is off: one stderr line, exit 0, no network call"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' 'FMX_PAIRING_TOKEN=abc' "export OPENROUTER_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
( unset OPENROUTER_API_KEY OPENROUTER_API_KEY_PRIVATE
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$BRIEF" --project pager
) > "$TMP_ROOT/sub-out" 2> "$TMP_ROOT/sub-err"
code=$?
out=$(cat "$TMP_ROOT/sub-out")
err=$(cat "$TMP_ROOT/sub-err")
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on the fd header"
reset_log
OPENROUTER_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
OVERRIDE_CONFIG="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE_CONFIG"
cp "$BASE_RULES" "$OVERRIDE_CONFIG/crew-dispatch.json"
reset_log
OPENROUTER_API_KEY=$KEY FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "FM_CONFIG_OVERRIDE selects the canonical rules directory"
pass "OPENROUTER_API_KEY= in .env activates the tool; environment and config overrides work"

# --- clear: request shape, secret handling, argmax --------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'dispatch-resolve:' "TOON block header"
assert_contains "$out" '  status: clear' "clear status"
assert_contains "$out" '  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9' "rule and confidence line"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "argmax picks the highest spendPriority"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  windows=five_hour:93%@2030-01-01T04:00:00Z,seven_day:79%@2030-01-04T00:00:00Z  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "every candidate is accounted for with its window evidence"
assert_not_contains "$out" 'unranked' "a clear result ranks from complete evidence only"
assert_not_contains "$out" '--effort' "cursor profile without effort emits no --effort"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://openrouter.ai/api/v1/systemone' "the request uses the OpenRouter System One endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "curl receives the bearer header on fd 3"
assert_equals $'curl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the API key is absent from every child environment"
body=$(cat "$LOG/body")
assert_equals 'typesafe/jev-1.13' "$(jq -r .model <<<"$body")" "default model is typesafe/jev-1.13"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one in the pager' "the whole brief rides in the state"
assert_equals '["profile","rule"]' "$(jq -c '.questions | keys' <<<"$body")" "rule and candidate/effort Choices share one call"
assert_equals '["default","rule_1","rule_2","rule_3","rule_4"]' "$(jq -c '.questions.rule.criteria | keys' <<<"$body")" "one option per rule plus default"
assert_equals 'No listed rule applies to this task.' "$(jq -r '.questions.rule.criteria.default' <<<"$body")" "the fixed generic none criterion is the default option"
assert_equals 'A simple bug fix with a stated root cause.' "$(jq -r '.questions.rule.criteria.rule_4' <<<"$body")" "rule when text is the option verbatim"
assert_not_contains "$body" 'SECRET-WHY-TEXT' "why text never leaves the machine"
assert_not_contains "$body" 'spendPriority' "quota never leaves the machine"
assert_contains "$body" 'cursor-grok' "candidate and effort options reach the model without credential paths"
assert_not_contains "$body" '.codex-geris' "credential paths never reach the model"
pass "clear: one rule Choice request, key on the fd header only, spendPriority argmax over every candidate"

# --- credential source declaration: where a key lives, never the key -----------
# $CONFIG/dispatch-credential-sources.json names a source per provider. It is
# read only when neither the environment nor .env supplied a key. The fake
# Keychain holds one item file per service name.
SECRET='kc-typesafe-4d7a1e90-never-on-argv'
KC_OR_SECRET='kc-openrouter-8b21f6c3-never-on-argv'
EFFECTIVE_SECRET='kc-effective-c07e5a12-never-on-argv'
STORE="$TMP_ROOT/keychain"
CRED="$HOME_DIR/config/dispatch-credential-sources.json"
mkdir -p "$STORE"
printf '%s\n' "$SECRET" > "$STORE/typesafe-svc"
printf '%s\n' "$KC_OR_SECRET" > "$STORE/openrouter-svc"
printf '%s\n' "$EFFECTIVE_SECRET" > "$STORE/effective-svc"
: > "$STORE/empty-svc"
export FAKE_SECURITY_STORE="$STORE"
# The typesafe entry belongs to the fork's direct route, so these cases select
# it; the provider-isolation cases below also cover the default OpenRouter route.
export FM_DISPATCH_ROUTE=direct

# declare_source <file> <provider> <service> [<account>]: add or replace one
# provider's macos-keychain entry, keeping the other providers' entries.
declare_source() {
  local file=$1 provider=$2 service=$3 account=${4:-}
  [ -f "$file" ] || printf '{}\n' > "$file"
  jq --arg p "$provider" --arg s "$service" --arg a "$account" \
    '.[$p] = ({source: "macos-keychain", service: $s} + (if $a == "" then {} else {account: $a} end))' \
    "$file" > "$file.next" && mv "$file.next" "$file"
}

# mapping: the declared service and optional account become the lookup
reset_log
write_response "$RESPONSE" rule_4 0.9
declare_source "$CRED" typesafe typesafe-svc mike
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a declared source resolves"
assert_contains "$out" '  status: clear' "a declared source turns the tool on"
assert_equals 'find-generic-password -s typesafe-svc -a mike -w' "$(cat "$LOG/security.argv")" "the declared service and account are the whole Keychain lookup"
assert_equals "Authorization: Bearer $SECRET" "$(cat "$LOG/header")" "the declared key reaches curl on the fd header"
rm -f "$CRED"
declare_source "$CRED" typesafe typesafe-svc
reset_log
run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "a declaration without an account resolves"
assert_equals 'find-generic-password -s typesafe-svc -w' "$(cat "$LOG/security.argv")" "an omitted account is omitted from the lookup"
pass "mapping: a declared macos-keychain service and optional account become the lookup, and the key rides the fd header"

# precedence: environment, then .env, then the declared source
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "the environment key wins over a declared source"
assert_absent "$LOG/security.argv" "the environment key wins before the declared source is read"
printf '%s\n' 'TYPESAFE_API_KEY=dotenv-wins' > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer dotenv-wins' "$(cat "$LOG/header")" ".env key wins over a declared source"
assert_absent "$LOG/security.argv" ".env key wins before the declared source is read"
rm -f "$HOME_DIR/.env" "$CRED"
printf '%s\n' '{"typesafe":' > "$CRED"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a key from the environment never consults an invalid declaration"
assert_contains "$out" '  status: clear' "an unread declaration cannot break a configured resolver"
assert_absent "$LOG/security.argv" "an invalid declaration is not read when the environment has the key"
rm -f "$CRED"
pass "precedence: environment, then .env, then the declared source, which is read only when needed"

# provider isolation: each route reads only its own provider's entry, and an entry never selects a route
rm -f "$CRED"
declare_source "$CRED" typesafe typesafe-svc
reset_log
FM_DISPATCH_ROUTE='' run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a typesafe declaration leaves the default OpenRouter route off"
assert_equals '' "$out" "the default route never uses a typesafe declaration"
assert_contains "$err" 'dispatch-resolve: off (OPENROUTER_API_KEY absent from the environment and' "the default route without its own declaration is off"
assert_absent "$LOG/security.argv" "a typesafe declaration is never read for the default route"
assert_absent "$LOG/argv" "the default route without a key never calls curl"
rm -f "$CRED"
declare_source "$CRED" openrouter openrouter-svc
reset_log
run code out err "$BRIEF" --project pager
assert_equals '' "$out" "an OpenRouter declaration neither selects a route nor feeds the direct route"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "the direct route without its own declaration is off"
assert_absent "$LOG/security.argv" "an OpenRouter declaration is never read for the direct route"
declare_source "$CRED" typesafe typesafe-svc
reset_log
FM_DISPATCH_ROUTE='' run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "the default route resolves from its own declared source"
assert_equals 'find-generic-password -s openrouter-svc -w' "$(cat "$LOG/security.argv")" "the default route reads only the openrouter service"
assert_equals "Authorization: Bearer $KC_OR_SECRET" "$(cat "$LOG/header")" "OpenRouter's declared key reaches curl, not typesafe's"
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/v1/systemone' "OpenRouter's declared key goes to OpenRouter's System One endpoint"
reset_log
run code out err "$BRIEF" --project pager
assert_equals 'find-generic-password -s typesafe-svc -w' "$(cat "$LOG/security.argv")" "the direct route reads only the typesafe service"
assert_equals "Authorization: Bearer $SECRET" "$(cat "$LOG/header")" "typesafe's declared key reaches curl, not OpenRouter's"
assert_contains "$(cat "$LOG/argv")" 'https://api.typesafe.ai/v1/systemone' "typesafe's declared key goes to the typesafe.ai endpoint"
rm -f "$CRED"
pass "provider isolation: each route reads only its own provider's declared service, and a declaration never selects a route"

# effective-home isolation: the effective config directory's declaration, and no other
declare_source "$CRED" typesafe typesafe-svc
OTHER_HOME="$TMP_ROOT/other-home"
mkdir -p "$OTHER_HOME/config"
cp "$BASE_RULES" "$OTHER_HOME/config/crew-dispatch.json"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$OTHER_HOME
reset_log
run code out err "$BRIEF" --project pager
HOME_DIR=$PRIMARY_HOME
assert_equals '' "$out" "a declaration in another home is not consulted"
assert_contains "$err" "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $OTHER_HOME/.env)" "a home with no declaration is off"
assert_absent "$LOG/security.argv" "another home's declaration is never read"
EFFECTIVE_CONFIG="$TMP_ROOT/effective-config"
mkdir -p "$EFFECTIVE_CONFIG"
cp "$BASE_RULES" "$EFFECTIVE_CONFIG/crew-dispatch.json"
declare_source "$EFFECTIVE_CONFIG/dispatch-credential-sources.json" typesafe effective-svc
reset_log
FM_CONFIG_OVERRIDE=$EFFECTIVE_CONFIG run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "an overridden config directory supplies its own declaration"
assert_equals 'find-generic-password -s effective-svc -w' "$(cat "$LOG/security.argv")" "only the effective directory's declaration is read"
assert_equals "Authorization: Bearer $EFFECTIVE_SECRET" "$(cat "$LOG/header")" "the effective directory's key is the one sent"
rm -f "$EFFECTIVE_CONFIG/dispatch-credential-sources.json"
reset_log
FM_CONFIG_OVERRIDE=$EFFECTIVE_CONFIG run code out err "$BRIEF" --project pager
assert_equals '' "$out" "the home's own config declaration is ignored when another directory is effective"
assert_absent "$LOG/security.argv" "a declaration outside the effective directory is never read"
rm -f "$CRED"
pass "effective-home isolation: only the effective config directory's declaration is consulted"

# failure distinctions: off, a configuration error, and an unavailable source are three different things
printf '{}\n' > "$CRED"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "a declaration with no entries is off"
assert_equals '' "$out" "off prints nothing on stdout"
assert_contains "$err" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' "off says so on stderr"
assert_absent "$LOG/security.argv" "an empty declaration never reaches the Keychain"
assert_absent "$LOG/argv" "off never calls curl"

for bad in \
  '{"typesafe":|not JSON' \
  '|must hold exactly one JSON object' \
  '[]|top-level value must be an object keyed by provider' \
  '{"typsafe":{"source":"macos-keychain","service":"s"}}|unknown provider typsafe (expected typesafe or openrouter)' \
  '{"typesafe":"kc-planted-value"}|typesafe must be an object with a source' \
  '{"typesafe":{"service":"s"}}|typesafe needs a source' \
  '{"typesafe":{"source":"kc-planted-value","service":"s"}}|typesafe source must be one of macos-keychain' \
  '{"typesafe":{"source":"macos-keychain"}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":""}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":7}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":"a\nb"}}|typesafe service must be a non-empty string without control characters' \
  '{"typesafe":{"source":"macos-keychain","service":"s","account":""}}|typesafe account must be a non-empty string without control characters when present' \
  '{"typesafe":{"source":"macos-keychain","service":"s","key":"kc-planted-value"}}|typesafe has unknown field key (allowed: source, service, account); credential values do not belong in this file' \
  '{"openrouter":{"source":"macos-keychain","service":"s","token":"kc-planted-value"}}|openrouter has unknown field token (allowed: source, service, account); credential values do not belong in this file'; do
  printf '%s\n' "${bad%%|*}" > "$CRED"
  reset_log
  run code out err "$BRIEF" --project pager
  expect_code 2 "$code" "an invalid declaration exits 2: ${bad#*|}"
  assert_contains "$err" "malformed credential source declaration: $CRED - ${bad#*|}" "the problem is named: ${bad#*|}"
  assert_not_contains "$err" 'kc-planted-value' "an invalid declaration never echoes a declared value"
  assert_equals '' "$out" "an invalid declaration prints nothing on stdout: ${bad#*|}"
  assert_equals '1' "$(grep -c . <<<"$err")" "an invalid declaration is one diagnostic line: ${bad#*|}"
  assert_absent "$LOG/security.argv" "an invalid declaration never reaches the Keychain: ${bad#*|}"
  assert_absent "$LOG/argv" "an invalid declaration never reaches the network: ${bad#*|}"
done
rm -f "$CRED"
ln -s "$TMP_ROOT/missing-declaration.json" "$CRED"
reset_log
run code out err "$BRIEF" --project pager
expect_code 2 "$code" "a broken declaration symlink exits 2"
assert_contains "$err" "credential source declaration not readable: $CRED" "an unreadable declaration is named"
rm -f "$CRED"
declare_source "$CRED" typesafe typesafe-svc
reset_log
run_on_path "$NO_JQ_BIN" code out err "$BRIEF" --project pager
expect_code 2 "$code" "a declaration cannot be read without jq"
assert_contains "$err" 'error: jq required' "missing jq is named"
assert_absent "$LOG/security.argv" "missing jq never reaches the Keychain"

# expect_unavailable <label> <reason>: a declared source that cannot supply the key
expect_unavailable() {
  local label=$1 reason=$2
  expect_code 0 "$code" "$label exits 0"
  assert_contains "$out" '  status: error' "$label is a structured error outcome"
  assert_contains "$out" "  reason: $reason" "$label names the source and why on stdout"
  assert_contains "$err" "dispatch-resolve: error ($reason)" "$label reports the same reason on stderr"
  assert_not_contains "$err" 'dispatch-resolve: off' "$label is not mistaken for an unconfigured resolver"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  assert_not_contains "$out$err" "$SECRET" "$label never prints a stored key"
}
UNAVAILABLE='credential source macos-keychain declared for typesafe is unavailable; nothing sent'
UNSUPPORTED='credential source macos-keychain declared for typesafe is not supported on this host; nothing sent'
declare_source "$CRED" typesafe absent-svc mike
reset_log
run code out err "$BRIEF" --project pager
expect_unavailable "a declared item that is not in the Keychain" "$UNAVAILABLE"
assert_equals 'find-generic-password -s absent-svc -a mike -w' "$(cat "$LOG/security.argv")" "the missing item was looked up once, by its declared identity"
declare_source "$CRED" typesafe empty-svc
reset_log
run code out err "$BRIEF" --project pager
expect_unavailable "a declared item with an empty secret" "$UNAVAILABLE"
declare_source "$CRED" typesafe typesafe-svc
reset_log
FAKE_SECURITY_EXIT=36 run code out err "$BRIEF" --project pager
expect_unavailable "a Keychain that refuses with the item in its output" "$UNAVAILABLE"
assert_not_contains "$out$err" 'could not use the item' "the tool's own output is never relayed"
reset_log
FAKE_UNAME=Linux run code out err "$BRIEF" --project pager
expect_unavailable "a declared macOS source on another system" "$UNSUPPORTED"
assert_absent "$LOG/security.argv" "an unsupported host never runs the credential tool"
reset_log
run_on_path "$NO_SECURITY_BIN" code out err "$BRIEF" --project pager
expect_unavailable "a declared source whose tool is missing" "$UNSUPPORTED"
reset_log
started=$SECONDS
FAKE_SECURITY_HANG="$LOG/hang.pid" run code out err "$BRIEF" --project pager
elapsed=$((SECONDS - started))
expect_unavailable "a declared source that never answers" 'credential source macos-keychain declared for typesafe did not answer in time; nothing sent'
[ "$elapsed" -lt 30 ] || fail "an unanswered Keychain read held the resolver for ${elapsed}s"
[ -s "$LOG/hang.pid" ] || fail "the fake security that never answers was not started"
hang_pid=$(cat "$LOG/hang.pid")
for _ in $(seq 1 50); do
  kill -0 "$hang_pid" 2>/dev/null || break
  sleep 0.1
done
! kill -0 "$hang_pid" 2>/dev/null || fail "the unanswered Keychain read was left running"
rm -f "$CRED"
declare_source "$CRED" openrouter absent-svc
reset_log
FM_DISPATCH_ROUTE='' run code out err "$BRIEF" --project pager
expect_unavailable "OpenRouter's declared item that is not in the Keychain" 'credential source macos-keychain declared for openrouter is unavailable; nothing sent'
rm -f "$CRED"
pass "failure distinctions: off, a configuration error, and an unavailable source each read differently and send nothing"

# secret containment: the key lives in one private variable and reaches curl on fd 3 only
declare_source "$CRED" typesafe typesafe-svc mike
SCAN_TMP="$TMP_ROOT/scan-tmp"
mkdir -p "$SCAN_TMP"
printf '%s' "$SECRET" > "$TMP_ROOT/canary"
reset_log
TMPDIR=$SCAN_TMP FAKE_CANARY_FILE="$TMP_ROOT/canary" FAKE_CANARY_DIRS="$SCAN_TMP $HOME_DIR" \
  run code out err "$BRIEF" --project pager
assert_contains "$out" '  status: clear' "the containment run resolves"
assert_equals "Authorization: Bearer $SECRET" "$(cat "$LOG/header")" "the key arrives only as the bearer header on the descriptor"
assert_not_contains "$out" "$SECRET" "the key never reaches stdout"
assert_not_contains "$err" "$SECRET" "the key never reaches stderr"
assert_not_contains "$(cat "$LOG/argv")" "$SECRET" "the key never appears on curl argv"
assert_not_contains "$(cat "$LOG/security.argv")" "$SECRET" "the key never appears on security argv"
assert_not_contains "$(cat "$LOG/body")" "$SECRET" "the key never rides in the request body"
assert_equals $'security:clean\ncurl:clean\nquota-axi:clean' "$(cat "$LOG/child-env")" "the key is in no child environment, and in no file the tool holds while the request is in flight"
! grep -rqF -- "$SECRET" "$HOME_DIR" || fail "the key was written under the home"
! grep -rqF -- "$SECRET" "$SCAN_TMP" || fail "the key was left in the temporary directory"
rm -f "$CRED"
pass "secret containment: the declared key is on no argv, in no output, environment, or file, and only on the fd header"

# capability probe: a supported/unsupported answer that reads no declaration and runs no credential tool
printf '%s\n' '{"typesafe":' > "$CRED"
reset_log
run code out err --supports-credential-source macos-keychain
expect_code 0 "$code" "macos-keychain is supported on a macOS host with security"
assert_equals 'supported' "$out" "the probe answers supported"
assert_equals '' "$err" "the probe prints nothing on stderr, and an invalid declaration does not matter to it"
assert_absent "$LOG/security.argv" "the probe never runs security, so it retrieves no credential"
assert_absent "$LOG/argv" "the probe never calls curl"
FAKE_UNAME=Linux run code out err --supports-credential-source macos-keychain
expect_code 1 "$code" "macos-keychain is unsupported on another system"
assert_equals 'unsupported' "$out" "the probe answers unsupported"
run_on_path "$NO_SECURITY_BIN" code out err --supports-credential-source macos-keychain
expect_code 1 "$code" "macos-keychain is unsupported without security"
assert_equals 'unsupported' "$out" "the probe answers unsupported without the tool"
run code out err --supports-credential-source vault
expect_code 1 "$code" "an unknown source is unsupported"
assert_equals 'unsupported' "$out" "the probe answers unsupported for an unknown source"
run_on_path "$NO_JQ_BIN" code out err --supports-credential-source macos-keychain
expect_code 0 "$code" "the probe needs no jq"
run code out err --supports-credential-source
expect_code 2 "$code" "the probe without a source is a usage error"
assert_contains "$err" '--supports-credential-source needs a value' "the usage error is named"
run code out err --help
assert_contains "$out" '--supports-credential-source <source>' "--help documents the probe"
assert_contains "$out" 'dispatch-credential-sources.json' "--help names the declaration file"
assert_absent "$LOG/security.argv" "no probe or help request ran security"
rm -f "$CRED"
unset FM_DISPATCH_ROUTE
pass "capability probe: supported or unsupported, with no declaration read and no credential tool run"

# --- never-send list: a match or a bad list withholds the request -------------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
PRIVATE_BRIEF="$TMP_ROOT/private-brief.md"
cat > "$PRIVATE_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the pager for the Acme-Ledger account 4417-2290.

## Firstmate spec
- Keep the change small.
MD
expect_withheld() {  # <label> <stderr fragment> [<value that must not print>...]
  local label=$1 fragment=$2
  shift 2
  expect_code 0 "$code" "$label exits 0"
  assert_equals '' "$out" "$label prints nothing on stdout, so firstmate uses its existing intake"
  assert_contains "$err" "dispatch-resolve: off ($fragment" "$label names why on stderr"
  assert_contains "$err" 'nothing sent)' "$label says nothing was sent"
  assert_equals '1' "$(grep -c . <<<"$err")" "$label prints one diagnostic line"
  assert_absent "$LOG/argv" "$label never calls curl"
  assert_absent "$LOG/quota-axi.calls" "$label never reads quota"
  local value
  for value in "$@"; do
    assert_not_contains "$err" "$value" "$label never prints the listed value"
  done
}

printf '%s\n' '# private values' '' '   ' 'Unlisted-Value' > "$NEVER_SEND"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "a list with no match leaves resolution unchanged"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "a list with no match sends the task text"

printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a case-insensitive literal match" "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger'

WRAPPED_BRIEF="$TMP_ROOT/wrapped-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for Example Client\nLtd before\tthe\xc2\xa0release.\n' > "$WRAPPED_BRIEF"
printf '%s\n' 'example  client ltd' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief wraps across lines" "brief text matches $NEVER_SEND line 1" 'example' 'Example'

printf '%s\n' 'before the release' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$WRAPPED_BRIEF" --project pager
expect_withheld "a literal the brief spaces with a tab and a no-break space" "brief text matches $NEVER_SEND line 1" 'release'

printf '%s\n' 'orion-private' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project orion-private
expect_withheld "a project-name match" "brief text matches $NEVER_SEND line 1" 'orion-private'

printf '%s\n' 'stated root cause' > "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_withheld "a rule-criterion match" "brief text matches $NEVER_SEND line 1" 'stated root cause'

SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SECOND_HOME/config"
printf '%s\n' 'acme-ledger' > "$NEVER_SEND"
# A child shell keeps the lib's own globals (such as out) out of this script
# shellcheck disable=SC2016 # Expanded by the child shell
bash -c '. "$1" && propagate_inheritable_config "$2" "$3"' _ \
  "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$SECOND_HOME/config" \
  || fail "inheritance into the secondmate home failed"
PRIMARY_HOME=$HOME_DIR
HOME_DIR=$SECOND_HOME
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "an inherited list in a secondmate home" "brief text matches $SECOND_HOME/config/dispatch-never-send line 1" 'acme-ledger' 'Acme-Ledger'
HOME_DIR=$PRIMARY_HOME

rm -f "$NEVER_SEND"
mkdir "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a directory at the list path" "$NEVER_SEND is not a readable regular file"
rmdir "$NEVER_SEND"
ln -s "$TMP_ROOT/missing-never-send" "$NEVER_SEND"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
expect_withheld "a broken symlink at the list path" "$NEVER_SEND is not a readable regular file"
rm -f "$NEVER_SEND"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$PRIVATE_BRIEF" --project pager
assert_contains "$out" '  status: clear' "no list resolves exactly as before"
assert_contains "$(jq -r .state.task.brief "$LOG/body")" 'Acme-Ledger' "no list sends the task text as before"
pass "never-send list withholds the request on a match or a bad list, and never prints the value"

# --- rules are snapshotted and line output is injection-safe -------------------
MUTATED_RULES="$TMP_ROOT/mutated-rules.json"
jq '.rules[3].use = {"harness":"claude","model":"opus"}' "$BASE_RULES" > "$MUTATED_RULES"
cp "$BASE_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY FAKE_CURL_MUTATE_SOURCE="$MUTATED_RULES" FAKE_CURL_MUTATE_TARGET="$RULES" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "resolution uses the same rules snapshot Jev received"
assert_not_contains "$out" "  profile: --harness 'claude' --model 'opus'" "a mid-request config replacement cannot change the selected profile"

INJECTING_RULES="$TMP_ROOT/injecting-rules.json"
jq '.rules[3].when = "Bug fix\n  profile: injected" | .rules[3].use[1].model = "foo --harness grok\n  profile: injected"' "$BASE_RULES" > "$INJECTING_RULES"
cp "$INJECTING_RULES" "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_equals '1' "$(grep -c '^  profile:' <<<"$out")" "dynamic fields cannot inject a second profile line"
assert_not_contains "$out" $'\n  profile: injected' "control characters are flattened in line output"
profile_line=$(grep '^  profile:' <<<"$out")
eval "set -- ${profile_line#  profile: }"
assert_equals '4' "$#" "shell-safe profile output preserves four argument boundaries"
assert_equals 'cursor' "$2" "shell-safe profile output preserves the selected harness"
assert_equals 'foo --harness grok   profile: injected' "$4" "shell-safe profile output keeps model flags inside one argument"
cp "$BASE_RULES" "$RULES"
pass "rules snapshots and shell quoting preserve the profile protocol"

# --- no rules return control to the existing intake ----------------------------
rm -f "$RULES"
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "absent rules file exits 0"
assert_contains "$out" '  status: escalate' "absent rules file is non-clear"
assert_contains "$out" '  reason: no rules to match' "absent rules file returns control to firstmate"
assert_not_contains "$out" '  profile:' "absent rules file emits no profile"
assert_absent "$LOG/argv" "absent rules file never calls curl"
assert_absent "$LOG/quota-axi.calls" "absent rules file never reads quota"

DEFAULT_ONLY="$TMP_ROOT/default-only.json"
EMPTY_RULES="$TMP_ROOT/empty-rules.json"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$DEFAULT_ONLY"
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}' > "$EMPTY_RULES"
for direct_rules in "$DEFAULT_ONLY" "$EMPTY_RULES"; do
  cp "$direct_rules" "$RULES"
  reset_log
  OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 0 "$code" "no-rule resolution exits 0: $direct_rules"
  assert_contains "$out" '  status: escalate' "no-rule resolution is non-clear: $direct_rules"
  assert_contains "$out" '  reason: no rules to match' "no-rule resolution returns control to firstmate: $direct_rules"
  assert_not_contains "$out" '  profile:' "no-rule resolution emits no profile: $direct_rules"
  assert_absent "$LOG/argv" "no-rule resolution never calls curl: $direct_rules"
  assert_absent "$LOG/quota-axi.calls" "no-rule resolution never reads quota: $direct_rules"
done

AGY_RULE="$TMP_ROOT/agy-rule.json"
printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$AGY_RULE"
cp "$AGY_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
add_profile_response "$RESPONSE"
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy  windows=weekly:64%@2030-01-02T00:00:00Z  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible' "agy uses its resolver-only authoritative quota provider"
assert_contains "$out" "  profile: --harness 'agy'" "provider-less agy rule resolves"

write_agy_tiers() {  # <path> <gemini row JSON or ""> <claude_gpt row JSON or "">
  jq -n --argjson g "${2:-null}" --argjson c "${3:-null}" '{
    generatedAt: "2030-01-01T00:00:00Z",
    schemaVersion: 5,
    providers: [{ provider: "agy", state: { status: "fresh" },
      windows: [{ id: "weekly", kind: "weekly", percentRemaining: 64, resetsAt: "2030-01-02T00:00:00Z" }],
      quotaSemantics: { status: "known", effectiveAvailability: ([$g, $c] | map(select(. != null) | .boundedBy = ["weekly"])) } }]
  }' > "$1"
}
AGY_GEMINI='{"scope":"gemini","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.5}}'
AGY_CLAUDE_GPT_OK='{"scope":"claude_gpt","status":"known","effectivePercentRemaining":55,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.2}}'
AGY_CLAUDE_GPT_ZERO_PCT='{"scope":"claude_gpt","status":"known","effectivePercentRemaining":0,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.2}}'
AGY_CLAUDE_GPT_ZERO='{"scope":"claude_gpt","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"},"selection":{"spendPriority":-1}}'
QUOTA_SCOPE_RULE='{"rules":[{"when":"Agy work.","use":{"harness":"agy","quota_scope":"claude_gpt"}}]}'
cp "$QUOTA" "$QUOTA.base"

printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$RULES"
write_agy_tiers "$QUOTA" "$AGY_GEMINI" "$AGY_CLAUDE_GPT_ZERO"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy  windows_missing=*  -> incomplete: no applicable quota row for provider agy: gather first, wait and re-run' "without quota_scope an agy tier row stays unbound, even when exhausted, and the completeness gate asks to gather"

printf '%s\n' "$QUOTA_SCOPE_RULE" > "$RULES"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'scope=claude_gpt  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at claude_gpt' "a declared exhausted tier row blocks the candidate"

write_agy_tiers "$QUOTA" "$AGY_GEMINI" "$AGY_CLAUDE_GPT_ZERO_PCT"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'scope=claude_gpt  remaining=0%' "a declared 0% tier row is read with a non-exhausted runway"
assert_contains "$out" '-> not eligible' "a declared 0% tier row blocks the candidate without an exhausted runway"
assert_not_contains "$out" '  profile:' "a declared 0% tier row emits no profile"

write_agy_tiers "$QUOTA" "$AGY_GEMINI" "$AGY_CLAUDE_GPT_OK"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: agy:-  provider=agy  windows=weekly:64%@2030-01-02T00:00:00Z  scope=claude_gpt  remaining=55%  spendPriority=0.2  runway=through_reset  -> eligible' "a declared healthy tier row ranks the candidate on that row alone"
assert_contains "$out" "  profile: --harness 'agy'" "the healthy declared tier resolves"

write_agy_tiers "$QUOTA" "$AGY_GEMINI" ""
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
# The fork's completeness gate treats a declared tier with no row as unknown
# evidence to gather, never as a block and never as a rankable pick.
assert_contains "$out" '  status: incomplete' "a declared tier row missing from the snapshot asks to gather first"
assert_not_contains "$out" 'not eligible' "a missing declared tier row never blocks the candidate"
assert_not_contains "$out" '  profile:' "a missing declared tier row authorizes no profile"
write_agy_tiers "$QUOTA" '{"scope":"all_models","status":"known","effectivePercentRemaining":70,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.3}}' ""
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '-> eligible, unranked: declared quota_scope claude_gpt has no quota row for provider agy: not rankable: disclosed uncertainty' "a declared tier row absent beside a measured provider-wide row is eligible with disclosed uncertainty"

cp "$QUOTA.base" "$QUOTA"
cp "$BASE_RULES" "$RULES"
pass "quota_scope binds an agy candidate to its declared tier row"

GEMINI_RULE="$TMP_ROOT/gemini-rule.json"
printf '%s\n' '{"rules":[{"when":"Gemini work.","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google"}}]}' > "$GEMINI_RULE"
cp "$GEMINI_RULE" "$RULES"
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: gemini:gemini-3.8-flash-high  provider=google  windows=weekly:72%@2030-01-02T00:00:00Z  scope=all_models  remaining=72%  spendPriority=0.3  runway=through_reset  -> eligible' "Gemini resolves through its explicit provider"
assert_contains "$out" "  profile: --harness 'gemini' --model 'gemini-3.8-flash-high'" "Gemini is a typed verified dispatch harness"

cp "$ROOT/docs/examples/crew-dispatch.json" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"default","confidence":0.9,"probabilities":{"rule_1":0.02,"rule_2":0.02,"rule_3":0.02,"default":0.94}}},"usage":{"input_tokens":812,"output_tokens":60}}
JSON
add_profile_response "$RESPONSE"
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "the documented example passes opted-in resolution"
assert_contains "$out" 'candidate: pi:anthropic/claude-sonnet-5  provider=claude  windows=five_hour:93%@2030-01-01T04:00:00Z,seven_day:79%@2030-01-04T00:00:00Z' "the documented Pi default uses its declared Claude provider with window evidence"
assert_not_contains "$err" 'malformed rules file' "the documented example reaches resolution"
cp "$BASE_RULES" "$RULES"
pass "no-rule fallback, Agy, Gemini, and documented configurations resolve"

# --- ambiguous: fixed confidence floor -----------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.41
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "ambiguous exits 0"
assert_contains "$out" '  status: ambiguous' "below the floor is ambiguous"
assert_contains "$out" '  reason: confidence 0.41 below floor 0.6' "ambiguous names the floor"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  windows=five_hour:93%@2030-01-01T04:00:00Z,seven_day:79%@2030-01-04T00:00:00Z  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' "ambiguous preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "ambiguous emits no profile line"
pass "ambiguous: confidence below the fixed floor hands the decision back"

# --- per-rule confidence floor ------------------------------------------------
write_floor_response() {  # <path> <choice> <confidence> <rule_1> <rule_2> <rule_3> <rule_4> <default>
  cat > "$1" <<JSON
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "$2", "confidence": $3,
    "probabilities": { "rule_1": $4, "rule_2": $5, "rule_3": $6, "rule_4": $7, "default": $8 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
  add_profile_response "$1"
}
FLOOR_RULES="$TMP_ROOT/floor-rules.json"
jq '.rules[1].min_confidence = 0.9 | .rules[3].min_confidence = 0.1' "$BASE_RULES" > "$FLOOR_RULES"
cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.18 0.02
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a top rule below its own floor falls to a runner-up that clears its floor"
assert_contains "$out" '  rule: rule_2 (The task generates images.)   confidence: 0.76' "the model's own pick stays visible"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.18 clears its floor 0.1; rule_2 probability 0.76 is below its floor 0.9' "the fallback names both floors"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the runner-up rule's profiles are resolved"
assert_not_contains "$(cat "$LOG/body")" 'min_confidence' "the model never sees confidence floors"

reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.02 0.76 0.02 0.08 0.12
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "no runner-up clearing its own floor is ambiguous"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; no other option clears its own floor' "the undeclared default keeps the global floor as a runner-up"
assert_not_contains "$out" '  fallback:' "no fallback is reported when none is taken"
assert_not_contains "$out" '  profile:' "ambiguous per-rule floor emits no profile"

jq '.rules[0].min_confidence = 0.1' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.76 0.12 0.76 0.0 0.12 0.0
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "equally probable runner-ups never break by option order"
assert_contains "$out" '  reason: rule_2 probability 0.76 below its floor 0.9; runner-up tie' "a runner-up tie is named"

cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.45 0.01 0.01 0.01 0.45 0.52
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "a declared floor below the global floor lets the picked rule resolve"

# A declared floor needs the same support from a rule as the pick or as a runner-up
jq '.rules[3].min_confidence = 0.3' "$FLOOR_RULES" > "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_4 0.25 0.25 0.05 0.05 0.35 0.30
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a picked rule clears its declared floor on its own probability, not the answer confidence"
assert_not_contains "$out" '  fallback:' "a picked rule that clears its own floor takes no fallback"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the picked rule resolves at probability 0.35 over floor 0.3"

reset_log
# jq 1.7+ preserves 0.30's spelling; use the canonical 0.3 lexeme for the
# exact prose assertion on both jq 1.6 and newer versions, without changing support.
write_floor_response "$RESPONSE" rule_2 0.95 0.05 0.55 0.05 0.3 0.05
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a high answer confidence does not lift a picked rule over its own floor"
assert_contains "$out" '  fallback: rule_4 (A simple bug fix with a stated root cause.) probability 0.3 clears its floor 0.3; rule_2 probability 0.55 is below its floor 0.9' "the runner-up clears the same floor it would need as the pick"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.05 0.55 0.05 0.25 0.10
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "a runner-up below its own floor is not taken"
assert_contains "$out" '  reason: rule_2 probability 0.55 below its floor 0.9; no other option clears its own floor' "the missed runner-up floor is named"
cp "$BASE_RULES" "$RULES"

reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.01 0.55 0.01 0.42 0.01
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: ambiguous' "without declared floors a low pick stays ambiguous"
assert_contains "$out" '  reason: confidence 0.55 below floor 0.6' "without declared floors the global floor reason is unchanged"
assert_not_contains "$out" '  fallback:' "without declared floors no runner-up is taken"
pass "per-rule confidence floors fall to the most probable runner-up that clears its own floor"

# Low answer confidence does not authorize candidates from the original rule
# once a declared floor has selected a different, supported runner-up.
cp "$FLOOR_RULES" "$RULES"
reset_log
write_floor_response "$RESPONSE" rule_2 0.55 0.05 0.55 0.03 0.35 0.02
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' 'a supported low-confidence runner-up resolves under its own floor'
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" 'only the runner-up rule may supply the selected profile'
assert_not_contains "$out" 'candidate: pi:openai-codex' 'the original rule candidates must not leak into fallback ranking'
cp "$BASE_RULES" "$RULES"
pass 'declared-floor fallback uses the runner-up candidate pool even below the global confidence floor'

# --- the model sees only the task-specific brief sections ----------------------
SCAFFOLD_BRIEF="$TMP_ROOT/scaffold-brief.md"
cat > "$SCAFFOLD_BRIEF" <<'MD'
# Task
## Captain's intent
Add a flag to the pager.

## Firstmate spec
Touch pager.sh only.
```sh
# Not a heading inside a fence
## Setup
```
### Out of scope
Anything else.

# Setup
BOILERPLATE-SETUP never push to the default branch.

## Captain intent authorized for --intent
BOILERPLATE-DUPLICATE
MD
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$SCAFFOLD_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "the captain's intent section is sent"
assert_contains "$sent" $'## Firstmate spec\nTouch pager.sh only.' "the Firstmate spec section is sent"
assert_contains "$sent" $'# Not a heading inside a fence\n## Setup\n```\n### Out of scope\nAnything else.' "fenced lines and subheadings stay inside the section"
assert_not_contains "$sent" 'BOILERPLATE' "scaffold boilerplate after the task sections is not sent"
assert_not_contains "$sent" '# Task' "the enclosing Task heading is not sent"
assert_not_contains "$sent" 'Brief kind:' "a brief without a scout contract line gets no kind line"

SPEC_ONLY_BRIEF="$TMP_ROOT/spec-only-brief.md"
printf '%s\n' '# Task' '## Firstmate spec' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals $'## Firstmate spec\nSpec text.' "$(jq -r .state.task.brief "$LOG/body")" "one recognized section is enough"

printf '%s\n' '# Task' '## Firstmate spec   ' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a heading with trailing blanks is not a section, matching spawn validation"

printf '%s\n' 'Preamble.' '## Firstmate spec' 'Spec text.' > "$SPEC_ONLY_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a section outside the Task heading is not a task section"

KIND_BRIEF="$TMP_ROOT/kind-brief.md"
{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' '# Definition of done' 'Delivery contract: mode=no-mistakes' 'Delivery contract: mode=direct-PR'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "a ship brief still sends its task sections"
assert_not_contains "$sent" 'Brief kind:' "a ship brief gets no kind line"
assert_not_contains "$sent" 'mode=' "a ship brief's delivery mode is not sent"

{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$KIND_BRIEF"
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$KIND_BRIEF"
sent=$(jq -r .state.task.brief "$LOG/body")
assert_contains "$sent" $'Brief kind: scout (report only)\n\n## Captain\'s intent' "a scout brief's contract line names its kind"
assert_not_contains "$sent" 'This is a SCOUT task' "the scout contract line itself is not sent"

reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
assert_equals "$(cat "$BRIEF")" "$(jq -r .state.task.brief "$LOG/body")" "a brief with neither heading is sent whole"
pass "only the brief's task sections and scout tag reach the model, with a whole-brief fallback"

# --- escalate: captain approval ------------------------------------------------
reset_log
write_response "$RESPONSE" rule_3 0.95
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "escalate exits 0"
assert_contains "$out" '  status: escalate' "approval-gated rule escalates"
assert_contains "$out" "  reason: rule requires the captain's explicit approval before dispatch" "escalate names the approval gate"
assert_contains "$out" 'candidate: claude:fable  provider=claude  windows=five_hour:93%@2030-01-01T04:00:00Z,seven_day:79%@2030-01-04T00:00:00Z,model:fable:15%@2030-01-04T00:00:00Z  scope=model:fable  remaining=15%  spendPriority=-0.79  runway=projected_exhaustion  bounds=all_models:79%/projected_exhaustion,model:fable:15%/projected_exhaustion  -> eligible' "approval escalation preserves matched candidate evidence"
assert_not_contains "$out" '  profile:' "escalate emits no profile line"
pass "escalate: a rule declared approval: captain never yields a profile"

# --- rule floor fails: fall through to default -------------------------------
reset_log
write_response "$RESPONSE" rule_1 0.97
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "rule floor fall-through still resolves"
assert_contains "$out" '  note: rule rule_1 floor model:fable below 20%: fall through to default' "rule floor fall-through is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "fall-through resolves among the default profiles"
assert_not_contains "$out" 'candidate: claude:fable' "the floored rule's own profile is not a candidate"

MISSING_RULE_FLOOR="$TMP_ROOT/missing-rule-floor.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) |= map(select(.scope != "model:fable"))' "$QUOTA" > "$MISSING_RULE_FLOOR"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$MISSING_RULE_FLOOR" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "an unverifiable rule floor escalates"
assert_contains "$out" '  reason: rule rule_1 floor claude/model:fable is unverifiable' "the unverifiable rule floor names its provider and scope"
assert_not_contains "$out" '  profile:' "an unverifiable rule floor never authorizes default routing"
pass "rule floor: known shortfall falls through while unavailable evidence escalates"

# --- declared provider and profile floor --------------------------------------
reset_log
write_response "$RESPONSE" rule_2 0.99
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a weekly-only plan resolves clear: the measured window set is the plan's own evidence"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  windows=weekly:31%@2030-01-06T00:00:00Z  scope=all_models  remaining=31%' "declared provider routes a Pi profile to the codex row with its window evidence"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  windows=weekly:31%@2030-01-06T00:00:00Z  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  -> not eligible: profile floor all_models below 50%' "profile floor makes a candidate ineligible with its reason"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "the remaining eligible candidate wins"

FLOOR_BOUNDS="$TMP_ROOT/floor-bounds.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.9}}
]' "$QUOTA" > "$FLOOR_BOUNDS"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_BOUNDS" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  windows=weekly:31%@2030-01-06T00:00:00Z  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:10%/projected_exhaustion  -> not eligible: profile floor all_models below 50%' "a failed profile floor reports its named row while retaining all bounds"

FLOOR_WITH_UNKNOWN="$TMP_ROOT/floor-with-unknown.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:gpt-5.6-sol","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$FLOOR_WITH_UNKNOWN"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_WITH_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> not eligible: profile floor all_models below 50%' "a known profile-floor shortfall wins over unrelated unknown model evidence"
assert_contains "$out" '  status: incomplete' "an unknown model window still blocks the choice"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  windows_missing=model:gpt-5.6-sol  bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> incomplete: unmeasured windows: model:gpt-5.6-sol: gather first, wait and re-run' "the candidate bounded by the unknown window is incomplete, not dropped"
assert_not_contains "$out" '  profile:' "unknown window evidence never authorizes a selection"

BAD_HOME_RETRY="$TMP_ROOT/bad-home-retry.json"
printf 'not json\n' > "$BAD_HOME_RETRY"
reset_log
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$FLOOR_WITH_UNKNOWN" QUOTA_AXI_RETRY_FIXTURE="$BAD_HOME_RETRY" run code out err "$BRIEF"
assert_contains "$out" '  status: incomplete' "a failed home re-read keeps the incomplete block instead of an error"
assert_contains "$out" 'windows_missing=model:gpt-5.6-sol' "the kept snapshot still names the missing window"

UNMEASURED_PROFILE_FLOOR="$TMP_ROOT/unmeasured-profile-floor.json"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:other","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$UNMEASURED_PROFILE_FLOOR"
jq '.rules[1].use[1].floor.scope = "model:other"' "$BASE_RULES" > "$RULES"
reset_log
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNMEASURED_PROFILE_FLOOR" run code out err "$BRIEF"
assert_contains "$out" '  status: incomplete' "an unmeasured profile floor blocks the choice"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  windows_missing=model:other' "the unmeasured floor scope is named as missing"
assert_not_contains "$out" '  profile:' "an unmeasured profile floor never authorizes a selection"
cp "$BASE_RULES" "$RULES"

MISSING_PROFILE_FLOOR_RULES="$TMP_ROOT/missing-profile-floor-rules.json"
jq '.rules[1].use[1].floor.scope = "model:missing"' "$BASE_RULES" > "$MISSING_PROFILE_FLOOR_RULES"
cp "$MISSING_PROFILE_FLOOR_RULES" "$RULES"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  windows=weekly:31%@2030-01-06T00:00:00Z  scope=model:missing  remaining=-%  spendPriority=-  runway=-  -> eligible, unranked: profile floor model:missing is unverifiable: not rankable: disclosed uncertainty' "a missing profile floor remains eligible but unranked"
assert_not_contains "$out" 'profile floor model:missing below' "missing profile evidence is not described as a shortfall"
assert_contains "$out" '  note: 1 eligible candidate(s) unranked (codex)' "the unranked candidate is disclosed on the clear result"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "another candidate may clear without misrepresenting missing floor evidence"
cp "$BASE_RULES" "$RULES"
pass "declared provider and profile floor evidence are applied in code"

# --- malformed ranking evidence is never ordered -------------------------------
reset_log
NONNUMERIC="$TMP_ROOT/nonnumeric-spend-priority.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models") | .selection.spendPriority) = "high"' "$QUOTA" > "$NONNUMERIC"
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONNUMERIC" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  windows=weekly:91%@2030-01-03T00:00:00Z  scope=all_models  remaining=91%  spendPriority=-  runway=through_reset  -> eligible, unranked: spendPriority missing or non-numeric at all_models: not rankable: disclosed uncertainty' "a nonnumeric spendPriority remains eligible but unranked"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "numeric evidence wins without mixed-type ordering"
pass "nonnumeric spendPriority evidence is never ranked"

# --- partial providers retain their known row evidence --------------------------
reset_log
PARTIAL="$TMP_ROOT/partial.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.status) = "partial"' "$QUOTA" > "$PARTIAL"
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  windows=weekly:91%@2030-01-03T00:00:00Z  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "a known row from a partial provider remains rankable"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "partial provider evidence can win the argmax"

PARTIAL_UNKNOWN="$TMP_ROOT/partial-unknown.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
])' "$QUOTA" > "$PARTIAL_UNKNOWN"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_UNKNOWN" run code out err "$BRIEF"
assert_contains "$out" '  status: incomplete' "an unknown exact-model window makes the choice incomplete"
assert_contains "$out" '  reason: quota window evidence incomplete: cursor:cursor-grok-4.6-medium missing model:cursor-grok-4.6-medium' "the reason names the candidate and its missing window"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  windows_missing=model:cursor-grok-4.6-medium  bounds=all_models:91%/through_reset,model:cursor-grok-4.6-medium:-%/unknown  -> incomplete: unmeasured windows: model:cursor-grok-4.6-medium: gather first, wait and re-run' "an unknown exact-model row is disclosed, never selected around"
assert_not_contains "$out" '  profile:' "unknown model windows never authorize a selection"

PARTIAL_EXHAUSTED="$TMP_ROOT/partial-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
] | .effectiveAvailability[] |= if .scope == "all_models" then .effectivePercentRemaining = 0 | .runway.status = "exhausted_now" else . end)' "$QUOTA" > "$PARTIAL_EXHAUSTED"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$PARTIAL_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  bounds=all_models:0%/exhausted_now,model:cursor-grok-4.6-medium:-%/unknown  -> not eligible: runway exhausted_now at all_models' "known exhaustion vetoes a candidate despite unknown exact-model evidence"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "a concretely vetoed candidate needs no window evidence to clear the rest"

UNKNOWN_EXHAUSTED="$TMP_ROOT/unknown-exhausted.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) = {
  "status":"unknown","effectiveAvailability":[
    {"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}
  ]
}' "$QUOTA" > "$UNKNOWN_EXHAUSTED"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNKNOWN_EXHAUSTED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=-%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "unknown provider semantics cannot mask concrete exhaustion"

NO_APPLICABLE="$TMP_ROOT/no-applicable.json"
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability) = [
  {"scope":"model:other","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}
]' "$QUOTA" > "$NO_APPLICABLE"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NO_APPLICABLE" run code out err "$BRIEF"
assert_contains "$out" '  status: incomplete' "a candidate without an applicable row blocks the choice"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  windows_missing=*  -> incomplete: no applicable quota row for provider cursor: gather first, wait and re-run' "a candidate without an applicable row is incomplete, not unranked"
assert_not_contains "$out" '  profile:' "no-applicable-row evidence never authorizes a selection"
pass "partial, missing, and unknown quota evidence is disclosed and never selected around"

# --- completeness gate: gather first, never select around unknown quota ------
reset_log
UNMEASURED="$TMP_ROOT/unmeasured.json"
jq '(.providers[] | select(.provider == "claude")) |= (
  .state = { "status": "stale", "error": "Claude quota endpoint rate limited", "retryAfter": "2020-01-01T00:00:10Z" } |
  .windows = [ { "id": "five_hour", "kind": "session" }, { "id": "seven_day", "kind": "weekly" } ] |
  .quotaSemantics = { "status": "unknown", "effectiveAvailability": [
    { "scope": "all_models", "status": "unknown", "boundedBy": ["five_hour", "seven_day"], "selection": { "unmeasurableWindowIds": ["five_hour", "seven_day"] } } ] }
)' "$QUOTA" > "$UNMEASURED"
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNMEASURED" FM_DISPATCH_QUOTA_ATTEMPTS=1 run code out err "$BRIEF"
expect_code 0 "$code" "an unmeasured provider exits 0"
assert_contains "$out" '  status: incomplete' "an unmeasured provider makes the choice incomplete"
assert_contains "$out" '  reason: quota window evidence incomplete: claude:sonnet missing five_hour, seven_day' "the status names the candidate and its missing windows"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  windows_missing=five_hour,seven_day (Claude quota endpoint rate limited; retry after 2020-01-01T00:00:10Z)  -> incomplete: provider claude unmeasured (unknown): gather first, wait and re-run' "the unmeasured candidate discloses its missing windows and retry time"
assert_contains "$out" 'candidate: cursor:cursor-grok-4.6-medium  provider=cursor  windows=weekly:91%@2030-01-03T00:00:00Z  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible' "a measured candidate keeps complete evidence"
assert_contains "$out" 'never pick by hand or drop a candidate' "the incomplete note forbids hand-picking"
assert_not_contains "$out" '  profile:' "an incomplete choice never emits a profile"
assert_equals '1' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "FM_DISPATCH_QUOTA_ATTEMPTS=1 honors a single gather"
reset_log
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNMEASURED" QUOTA_AXI_RETRY_FIXTURE="$QUOTA" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "a recovered measurement clears the choice on the retry"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  windows=five_hour:93%@2030-01-01T04:00:00Z,seven_day:79%@2030-01-04T00:00:00Z' "the recovered attempt lists the measured windows"
assert_equals '2' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "the incomplete home store is re-read once and the loop stops"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "the argmax runs only after the gate passes"
reset_log
LATE_RETRY="$TMP_ROOT/unmeasured-late.json"
jq '(.providers[] | select(.provider == "claude") | .state.retryAfter) = "2031-01-01T00:00:00Z"' "$UNMEASURED" > "$LATE_RETRY"
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$LATE_RETRY" run code out err "$BRIEF"
assert_contains "$out" '  status: incomplete' "a retry time beyond the bounded wait stays incomplete"
assert_contains "$out" 'retry after 2031-01-01T00:00:00Z' "the block names the published retry time"
assert_equals '1' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "a late retry time stops the gather loop before sleeping"
reset_log
write_response "$RESPONSE" rule_4 0.41
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$UNMEASURED" FM_DISPATCH_QUOTA_ATTEMPTS=1 run code out err "$BRIEF"
assert_contains "$out" '  status: incomplete' "hand-picking on ambiguous also requires complete window evidence"
assert_not_contains "$out" '  status: ambiguous' "a low confidence never downgrades the completeness gate"
assert_not_contains "$out" '  profile:' "no profile without complete evidence"
pass "completeness gate: unmeasured windows are gathered first and otherwise non-dispatchable"

# --- bounded retry drives the named Z.ai warm-up exactly once -----------------
ZAI_RULE="$TMP_ROOT/zai-rule.json"
printf '%s\n' '{"rules":[{"when":"Zai work.","use":{"harness":"pi","model":"zai/glm-5.3","provider":"zai"}}]}' > "$ZAI_RULE"
cp "$ZAI_RULE" "$RULES"
cat > "$RESPONSE" <<'JSON'
{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.99,"probabilities":{"rule_1":0.99,"default":0.01}},"profile":{"type":"choice","choice":"rule_1_1","confidence":0.99,"probabilities":{"rule_1_1":1.0}}},"usage":{"input_tokens":100,"output_tokens":60}}
JSON
add_profile_response "$RESPONSE"
ZAI_UNMEASURED="$TMP_ROOT/zai-unmeasured.json"
jq '.providers += [ { "provider": "zai", "state": { "status": "stale", "error": "Z.ai quota endpoint unavailable" },
  "windows": [ { "id": "five_hour", "kind": "session" } ],
  "quotaSemantics": { "status": "unknown", "effectiveAvailability": [
    { "scope": "all_models", "status": "unknown", "boundedBy": ["five_hour"], "selection": { "unmeasurableWindowIds": ["five_hour"] } } ] } } ]' "$QUOTA" > "$ZAI_UNMEASURED"
reset_log
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$ZAI_UNMEASURED" run code out err "$BRIEF"
assert_contains "$out" '  status: incomplete' "an unmeasurable Z.ai window stays incomplete"
assert_contains "$out" 'candidate: pi:zai/glm-5.3  provider=zai  windows_missing=five_hour (Z.ai quota endpoint unavailable)  -> incomplete: provider zai unmeasured (unknown): gather first, wait and re-run' "the Z.ai candidate names its missing window and state error"
assert_equals '3' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "default attempts bound the gather loop"
assert_equals '1' "$(grep -c . "$LOG/zai-warm.calls")" "the named warm-up runs exactly once across retries"
cp "$BASE_RULES" "$RULES"
pass "bounded retry drives the named Z.ai warm-up exactly once"

# --- provider-wide rows remain bounds beside exact model rows ------------------
reset_log
BOUNDED="$TMP_ROOT/bounded.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:sonnet","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.9}}
]' "$QUOTA" > "$BOUNDED"
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$BOUNDED" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  windows=five_hour:93%@2030-01-01T04:00:00Z,seven_day:79%@2030-01-04T00:00:00Z  scope=all_models  remaining=79%  spendPriority=-0.4627' "the limiting provider-wide row drives ranking"
assert_contains "$out" 'bounds=all_models:79%/projected_exhaustion,model:sonnet:99%/through_reset' "all applicable quota bounds are disclosed"

EXHAUSTED_WIDE="$TMP_ROOT/exhausted-wide.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$BOUNDED" > "$EXHAUSTED_WIDE"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$EXHAUSTED_WIDE" run code out err "$BRIEF"
assert_contains "$out" 'candidate: claude:sonnet  provider=claude  windows=five_hour:93%@2030-01-01T04:00:00Z,seven_day:79%@2030-01-04T00:00:00Z  scope=all_models  remaining=0%' "the exhausted account-wide bound is the candidate evidence"
assert_contains "$out" '-> not eligible: runway exhausted_now at all_models' "a healthy exact row cannot bypass an exhausted account-wide bound"
pass "provider-wide and exact quota rows combine into one limiting candidate"

# --- default choice ------------------------------------------------------------
reset_log
write_response "$RESPONSE" default 0.88
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  rule: default (No listed rule applies to this task.)' "default names the fixed neutral none option"
assert_contains "$out" '  note: no rule matched' "default is explained"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" "default resolves by argmax"
pass "default: no rule matched resolves among the default profiles"

# --- genuine tie escalates ---------------------------------------------------------
reset_log
TIE="$TMP_ROOT/tie.json"
write_quota "$TIE" 0.5 0.5
write_response "$RESPONSE" default 0.88
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "tie escalates"
assert_contains "$out" '  reason: genuine spendPriority tie' "tie is named"
pass "tie: equal spendPriority never breaks by array order"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.profile.choice = "rule_4_1" | .answers.profile.probabilities |= with_entries(.value = (if .key == "rule_4_1" then 1 else 0 end))' "$RESPONSE" > "$TMP_ROOT/preferred-tie.json"
mv "$TMP_ROOT/preferred-tie.json" "$RESPONSE"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TIE" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "Jev candidate and effort preference resolves an otherwise genuine quota tie"
pass "stage-3 candidate/effort preference operates only inside the top eligible quota tier"

# --- nothing rankable escalates -------------------------------------------------
reset_log
NONE="$TMP_ROOT/none.json"
jq '.providers |= map(if .provider == "cursor" or .provider == "claude" then .quotaSemantics.effectiveAvailability |= map(.runway.status = "exhausted_now") else . end)' "$QUOTA" > "$NONE"
OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$NONE" run code out err "$BRIEF"
assert_contains "$out" '  status: escalate' "no rankable candidate escalates"
assert_contains "$out" '  reason: no rankable eligible candidate' "no-candidate reason"
assert_contains "$out" '-> not eligible: runway exhausted_now' "exhausted candidates keep their reason"
pass "no rankable candidate: the tool escalates instead of guessing"

# --- schema 6: rows keyed by provider + accountKey bind per account ----------------
# quota-axi emits schema 6 once a provider expands to several accounts; every
# row then carries accountKey and one provider id may appear on several rows.
# Native Codex and Pi lanes bind to their own account rows, with no row
# chosen by position or summed across accounts.
LANE_RULES="$TMP_ROOT/lane-rules.json"
SCHEMA6="$TMP_ROOT/schema6.json"
SCHEMA5_PAIR="$TMP_ROOT/schema5-pair.json"
cat > "$LANE_RULES" <<'JSON'
{
  "rules": [
    {
      "when": "Codex work.",
      "use": [
        { "harness": "pi", "model": "openai-codex-work/gpt-5.6-terra", "provider": "codex" },
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
        { "harness": "codex", "model": "gpt-5.6-sol" }
      ]
    }
  ]
}
JSON
cat > "$SCHEMA6" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 6,
  "providers": [
    { "provider": "claude", "accountKey": "default", "quotaSemantics": { "status": "unknown", "effectiveAvailability": [] } },
    { "provider": "codex", "accountKey": "openai-codex", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": { "status": "exhausted_now" }, "selection": { "spendPriority": -1.4788 } } ] } },
    { "provider": "codex", "accountKey": "openai-codex-work", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 11, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -5.6819 } } ] } },
    { "provider": "cursor", "accountKey": "default", "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 24, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": 0.3917 } } ] } }
  ]
}
JSON
cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.9,
    "probabilities": { "rule_1": 0.97, "default": 0.03 } } },
  "usage": { "input_tokens": 812, "output_tokens": 60 } }
JSON
cp "$LANE_RULES" "$RULES"
add_profile_response "$RESPONSE"
# Account matching does not replace the fork's reset-evidence completeness gate.
# Successful schema-6 fixtures must carry measured windows as real snapshots do.
jq '.providers |= map(if .quotaSemantics.status == "known" then
  .windows = [{id:"weekly", kind:"weekly", percentRemaining:.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining, resetsAt:"2030-01-04T00:00:00Z"}] |
  .quotaSemantics.effectiveAvailability |= map(.boundedBy = ["weekly"])
  else . end)' "$SCHEMA6" > "$TMP_ROOT/schema6-windows.json"
mv "$TMP_ROOT/schema6-windows.json" "$SCHEMA6"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
expect_code 0 "$code" "schema 6 snapshot exits 0"
assert_contains "$out" '  status: incomplete' "a missing native account blocks the whole choice, without borrowing a Pi row"
assert_contains "$out" 'candidate: pi:openai-codex-work/gpt-5.6-terra  provider=codex  windows=weekly:11%@2030-01-04T00:00:00Z  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a Pi lane binds to its own account row"
assert_contains "$out" 'candidate: pi:openai-codex/gpt-5.6-sol  provider=codex  windows=weekly:0%@2030-01-04T00:00:00Z  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at all_models' "the sibling lane reads its own exhausted row"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  windows_missing=*  -> incomplete: provider codex has no quota row for account codex-home: gather first, wait and re-run' "native Codex never infers an account from a Pi lane"
assert_not_contains "$out" '  profile:' "a missing account never authorizes routing around it"
assert_equals '3' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "missing schema-6 evidence is retried within the bounded gather loop"

SCHEMA6_NATIVE="$TMP_ROOT/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now") |
    .windows[].percentRemaining = 0
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" | .plan = "native-plan" |
      .windows[].percentRemaining = 80 |
      .quotaSemantics.effectiveAvailability |= map(
        .effectivePercentRemaining = 80 | .runway.status = "through_reset" | .selection.spendPriority = 0.8))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_NATIVE" run code out err "$BRIEF"
expect_code 0 "$code" "native Codex schema 6 snapshot exits 0"
assert_contains "$out" '  status: clear' "native Codex headroom resolves despite exhausted Pi and default rows"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  windows=weekly:80%@2030-01-04T00:00:00Z  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible  plan=native-plan (quota-axi)' "native Codex reads codex-home"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex headroom is chosen"

jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-reversed.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-reversed.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex selection ignores row order"

jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-default.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "native Codex falls back to the default row when codex-home is absent"
pass "native Codex binds to codex-home before default, independently of Pi accounts and row order"

jq '.schemaVersion = 5 | .providers |= map(select(.accountKey != "openai-codex")) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "schema 5 keeps joining by provider alone, with Jev preference inside its tied top tier"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" "the profile preference resolves the genuine schema-5 tie"
assert_contains "$out" 'candidate: codex:gpt-5.6-sol  provider=codex  windows=weekly:11%@2030-01-04T00:00:00Z  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible' "a schema 5 row never needs accountKey"

SCHEMA6_PI_NATIVE="$TMP_ROOT/schema6-pi-native.json"
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default"))' "$SCHEMA6_NATIVE" > "$SCHEMA6_PI_NATIVE"
for harness in pi pi-signed; do
  jq --arg harness "$harness" '.rules[0].use |= map(if .harness == "codex" then
    {harness: $harness, model: "codex-native/gpt-6-astra", provider: "codex", effort: "ultra"}
    else . end)' "$LANE_RULES" > "$RULES"
  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6_PI_NATIVE" run code out err "$BRIEF"
  expect_code 0 "$code" "$harness native adapter schema 6 exits 0"
  assert_contains "$out" '  status: clear' "$harness native adapter resolves with codex-home and no default row"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  windows=weekly:80%@2030-01-04T00:00:00Z  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset  -> eligible" "$harness native adapter reads codex-home"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter is chosen over exhausted Pi accounts"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-default.json" run code out err "$BRIEF"
  assert_contains "$out" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter falls back to default"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA6" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  windows_missing=*  -> incomplete: provider codex has no quota row for account codex-home: gather first, wait and re-run" "$harness native adapter never borrows a Pi account"

  reset_log
  TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$SCHEMA5_PAIR" run code out err "$BRIEF"
  assert_contains "$out" "candidate: $harness:codex-native/gpt-6-astra  provider=codex  windows=weekly:11%@2030-01-04T00:00:00Z  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion  -> eligible" "$harness native adapter still joins schema 5 by provider alone"
done
cp "$LANE_RULES" "$RULES"
pass "Pi native adapters bind to codex-home with existing fallbacks and schema 5 compatibility"

jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$TMP_ROOT/schema6-keyless.json"
reset_log
TYPESAFE_API_KEY=$KEY QUOTA_AXI_FIXTURE="$TMP_ROOT/schema6-keyless.json" run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a schema 6 row without accountKey is an error outcome"
assert_contains "$out" '  reason: quota-axi --json returned an invalid snapshot' "keyless schema 6 row is named as an invalid snapshot"
cp "$BASE_RULES" "$RULES"
pass "schema 6: each candidate binds to its account row; schema 5 is unchanged"

# --- quota-axi is read exactly once --------------------------------------------
reset_log
write_response "$RESPONSE" rule_4 0.9
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi path exits 0"
assert_equals '--json' "$(cat "$LOG/quota-axi.calls")" "quota-axi --json is called exactly once"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "quota-axi snapshot drives the argmax"
reset_log
OPENROUTER_API_KEY=$KEY FAKE_QUOTA_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "quota-axi failure exits 0"
assert_contains "$out" '  status: error' "quota-axi failure is an error outcome"
assert_contains "$out" '  reason: quota-axi --json failed' "quota-axi failure is named"
pass "quota evidence comes from one quota-axi --json read, and its failure is an error outcome"

# --- account stores are joined once per registry seat and disabled fail closed ---
GERIS_QUOTA="$TMP_ROOT/geris-quota.json"
write_quota "$GERIS_QUOTA" 0.1 0.95
export GERIS_QUOTA_FIXTURE="$GERIS_QUOTA"
jq '.rules[3].use += [{"harness":"claude","model":"sonnet","effort":"high","account":"geris"}]' "$BASE_RULES" > "$RULES"
cat > "$HOME_DIR/config/accounts.json" <<'JSON'
{"crossAccount":{"enabled":true},"accounts":{"geris":{"claude":"~/.claude-geris","pi":"~/.pi-geris/agent","codex":"~/.codex-geris"}}}
JSON
write_response "$RESPONSE" rule_4 0.9
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high' --account 'geris'" "Geris quota ranks from its pinned store"
assert_contains "$out" 'candidate: claude:sonnet  account=geris  provider=claude' "account is inspectable"
assert_equals '2' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "one snapshot for each seat"
assert_contains "$(cat "$LOG/quota-axi.calls")" 'geris pinned' "secondary quota call pinned all three stores"
reset_log
OPENROUTER_API_KEY=$KEY FAKE_GERIS_QUOTA_FAIL=1 run code out err "$BRIEF"
assert_not_contains "$out" '  status: error' "a failed Geris probe does not fail the resolution"
assert_contains "$out" '  status: incomplete' "a failed Geris probe makes the choice incomplete, never a home-only selection"
assert_contains "$out" 'candidate: claude:sonnet  account=geris  provider=claude  windows_missing=*  -> incomplete: quota-axi --json failed for account geris: gather first, wait and re-run' "the failed seat names its missing evidence"
assert_not_contains "$out" '  profile:' "the home seat cannot be selected around the failed seat"
assert_equals '4' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "the failed store is retried within the attempts bound"
reset_log
OPENROUTER_API_KEY=$KEY FAKE_GERIS_QUOTA_FAIL=1 GERIS_QUOTA_RETRY_FIXTURE="$GERIS_QUOTA" run code out err "$BRIEF"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high' --account 'geris'" "the retried Geris store recovers and wins the argmax"
assert_equals '3' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "only the incomplete store is re-read"
assert_equals '2' "$(grep -c 'geris pinned' "$LOG/quota-axi.calls")" "the home snapshot is not re-read while complete"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-routing.sh" off >/dev/null
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'account=geris  provider=claude  -> not eligible: cross-account routing disabled' "off excludes Geris"
assert_equals '1' "$(grep -c '^--json$' "$LOG/quota-axi.calls")" "off never probes Geris store"
rm -f "$HOME_DIR/config/accounts.json"
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'not eligible: cross-account routing disabled' "missing registry fails closed"
printf '%s\n' '{invalid' > "$HOME_DIR/config/accounts.json"
reset_log
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'not eligible: cross-account routing disabled' "malformed registry fails closed"
cp "$BASE_RULES" "$RULES"
rm -f "$HOME_DIR/config/accounts.json"
unset GERIS_QUOTA_FIXTURE
pass "account-aware union ranking, kill switch, and fail-closed missing/malformed registry"

# --- plan evidence follows the candidate's provider and pinned account --------
cp "$BASE_RULES" "$RULES"
cat > "$HOME_DIR/config/accounts.json" <<'JSON'
{"crossAccount":{"enabled":true},"plans":{"claude":"Pro","cursor":"Business"},"accounts":{"geris":{"claude":"~/.claude-geris","pi":"~/.pi-geris/agent","codex":"~/.codex-geris","plans":{"claude":"Max 20x"}}}}
JSON
jq '.rules[3].use += [{"harness":"claude","model":"sonnet","account":"geris"}, {"harness":"pi","model":"openai-codex/gpt-5.6-sol","provider":"codex"}]' "$BASE_RULES" > "$RULES"
write_response "$RESPONSE" rule_4 0.9
reset_log
HOME="$HOME_DIR" OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'plan=Pro (config)' "default Claude plan comes from its declaration"
assert_contains "$out" 'plan=Max 20x (config)' "named account plan comes from its own declaration, not the default"
assert_contains "$out" 'plan=Business (config)' "another provider gets its own declaration"
assert_contains "$out" 'plan=unknown (unavailable)' "Pi Codex does not inherit Claude plan"
assert_contains "$out" 'compare candidate plan tiers before accepting percent-based capacity' "differing ranked plans prompt tier-aware assessment"
QUOTA_PLAN="$TMP_ROOT/quota-plan.json"
jq '(.providers[] | select(.provider == "claude")).plan = "max" | (.providers[] | select(.provider == "codex")).plan = "prolite"' "$QUOTA" > "$QUOTA_PLAN"
reset_log
HOME="$HOME_DIR" OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$QUOTA_PLAN" run code out err "$BRIEF"
assert_contains "$out" 'plan=Pro (config; quota-axi: max)' "declared plan wins over the coarse quota-axi label, shown beside it"
assert_contains "$out" 'plan=Max 20x (config; quota-axi: max)' "named declaration wins over its account snapshot label"
assert_contains "$out" 'plan=prolite (quota-axi)' "undeclared provider uses the quota-axi label"
cat > "$HOME_DIR/config/accounts.json" <<'JSON'
{"crossAccount":{"enabled":true},"plans":{"claude":"","cursor":"Business","z.ai":"Pro"},"accounts":{"geris":{"claude":"~/.claude-geris","pi":"~/.pi-geris/agent","codex":"~/.codex-geris","plans":"Max 20x"}}}
JSON
reset_log
HOME="$HOME_DIR" OPENROUTER_API_KEY=$KEY QUOTA_AXI_FIXTURE="$QUOTA_PLAN" run code out err "$BRIEF"
geris_line=$(printf '%s\n' "$out" | grep 'account=geris')
assert_contains "$geris_line" '-> eligible  plan=max (quota-axi)' "a malformed plan entry never blocks named-account routing and falls back per entry"
assert_contains "$out" 'plan=Business (config)' "valid declarations survive a sibling invalid entry"
cat > "$HOME_DIR/config/accounts.json" <<'JSON'
{"crossAccount":{"enabled":true},"accounts":{"geris":{"claude":"~/.claude-geris","pi":"~/.pi-geris/agent","codex":"~/.codex-geris"}}}
JSON
reset_log
HOME="$HOME_DIR" OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" 'status: clear' "undeclared plans still resolve"
assert_not_contains "$out" 'compare candidate plan tiers' "identical ranked plans add no tier note"
cp "$BASE_RULES" "$RULES"
rm -f "$HOME_DIR/config/accounts.json"
pass "each candidate discloses account/provider plan, declared-over-quota-axi precedence, and uncertainty"

# --- API and response failures are error outcomes, exit 0 ----------------------
reset_log
run_without_curl code out err "$BRIEF"
expect_code 0 "$code" "missing curl exits 0"
assert_contains "$out" '  status: error' "missing curl is a structured error outcome"
assert_contains "$out" '  reason: curl not installed' "missing curl is named in the TOON block"
assert_contains "$err" 'dispatch-resolve: error (curl not installed)' "missing curl is also reported on stderr"
reset_log
OPENROUTER_API_KEY=$KEY FAKE_CURL_HTTP=429 run code out err "$BRIEF"
expect_code 0 "$code" "http 429 exits 0"
assert_contains "$out" '  status: error' "http 429 is an error outcome"
assert_contains "$out" '  reason: http 429 after' "http status is reported"
assert_contains "$err" 'dispatch-resolve: error (http 429' "error also goes to stderr"
reset_log
OPENROUTER_API_KEY=$KEY FAKE_CURL_FAIL=1 run code out err "$BRIEF"
expect_code 0 "$code" "curl failure exits 0"
assert_contains "$out" '  reason: http 000 after' "transport failure reads as http 000"
reset_log
printf '%s\n' '{"model":"jev","answers":{}}' > "$RESPONSE"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  reason: response is not a rule Choice answer' "a malformed answer is an error outcome"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.usage = "bad"' "$RESPONSE" > "$TMP_ROOT/malformed-usage.json"
mv "$TMP_ROOT/malformed-usage.json" "$RESPONSE"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "malformed usage is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "malformed usage cannot break text rendering silently"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq 'del(.answers.rule.probabilities.default)' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "missing probability choice is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must name every offered choice"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities.rule_4 = "high"' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "nonnumeric probability is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must be numeric and bounded"
reset_log
write_response "$RESPONSE" rule_4 0.9
jq '.answers.rule.probabilities[] = 0' "$RESPONSE" > "$TMP_ROOT/malformed-probabilities.json"
mv "$TMP_ROOT/malformed-probabilities.json" "$RESPONSE"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "a zero-mass probability distribution is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "probabilities must sum to approximately one"
reset_log
write_response "$RESPONSE" rule_4 2
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "out-of-range confidence is an error outcome"
assert_contains "$out" '  reason: response is not a rule Choice answer' "out-of-range confidence is a malformed answer"
reset_log
write_response "$RESPONSE" rule_9 0.9
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "an unknown rule id is an error outcome"
assert_contains "$out" '  reason: rule rule_9 is not in the rules file' "unknown rule id is named"
write_response "$RESPONSE" rule_0 0.9
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
assert_contains "$out" '  status: error' "rule zero is an error outcome"
assert_contains "$out" '  reason: rule rule_0 is not in the rules file' "rule zero cannot alias the final rule"
reset_log
OPENROUTER_API_KEY=$KEY FAKE_CURL_HTTP=500 run code out err "$BRIEF"
assert_contains "$out" '  status: error' "http 500 is a TOON error outcome"
pass "API, transport, and response failures are error outcomes with exit 0"

# --- configuration errors exit 2 and select nothing ----------------------------------
reset_log
OPENROUTER_API_KEY=$KEY run code out err
expect_code 2 "$code" "missing brief exits 2"
assert_contains "$err" 'brief file required' "missing brief is named"
rm -f "$RULES"
ln -s "$TMP_ROOT/missing-rules-target.json" "$RULES"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "broken canonical rules symlink exits 2"
assert_contains "$err" "rules file not readable: $RULES" "broken rules symlink is actionable"
rm -f "$RULES"
printf '%s\n' '{"rules":[' > "$RULES"
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "non-JSON rules exits 2"
assert_contains "$err" 'not JSON' "non-JSON rules is named"
for bad in \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"shared_quota":"yes","rules":[{"when":"x","use":{"harness":"claude"}}]}|shared_quota must be true or false when present' \
  '{"shared_quota":1,"rules":[{"when":"x","use":{"harness":"claude"}}]}|shared_quota must be true or false when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"agy","quota_scope":""}}]}|each use profile quota_scope must be a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"agy","quota_scope":7}}]}|each use profile quota_scope must be a non-empty string when present' \
  '{"rules":[{"when":"x","use":["codex"]}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":["codex"]}|each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"agy"}}],"default":{"harness":"agy","quota_scope":["gemini"]}}|each default profile quota_scope must be a non-empty string when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":""}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":" claude"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"claude\n"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex","floor":{"scope":"all_models","min_percent":20,"provider":"claude"}}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}|each rule use must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":[{"harness":"claude","model":"opus"},{"harness":"claude","model":"opus"}]}|default must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5"}}]}|use profiles whose harness lacks one authoritative provider family require provider: opencode' \
  '{"rules":[{"when":"x","use":{"harness":"rovo"}}]}|use profiles whose harness lacks one authoritative provider family require provider: rovo' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"pi","model":"anthropic/claude-sonnet-5"}}|default profiles whose harness lacks one authoritative provider family require provider: pi'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
  expect_code 2 "$code" "malformed rules exit 2: ${bad#*|}"
  assert_contains "$err" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named: ${bad#*|}"
done
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"opencode"},{"harness":"rovo"},{"harness":"codex"}]}],"default":[{"harness":"pi"},{"harness":"claude"}]}' > "$RULES"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 2 "$code" "multiple provider-less profiles exit 2"
assert_contains "$err" "malformed rules file: $RULES - use profiles whose harness lacks one authoritative provider family require provider: opencode; use profiles whose harness lacks one authoritative provider family require provider: rovo; default profiles whose harness lacks one authoritative provider family require provider: pi" "all provider-less profiles are reported together across use and default"
[ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" -eq 1 ] || fail "provider errors must use one diagnostic"
assert_absent "$LOG/argv" "configuration errors never reach the network"
cp "$BASE_RULES" "$RULES"
for removed in --json --rules --quota; do
  OPENROUTER_API_KEY=$KEY run code out err "$BRIEF" "$removed"
  expect_code 2 "$code" "removed option is rejected: $removed"
  assert_contains "$err" "unknown flag $removed" "removed option has no public path: $removed"
done
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF" --bogus
expect_code 2 "$code" "unknown flag exits 2"
run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "configuration errors exit 2 before any network call"

# --- direct route remains a one-switch fallback with a separately scoped key ---
cp "$BASE_RULES" "$RULES"
reset_log
FM_DISPATCH_ROUTE=direct run code out err "$BRIEF"
assert_contains "$err" 'TYPESAFE_API_KEY absent' "direct route remains off without its separate key"
assert_absent "$LOG/argv" "direct route without a key never calls the network"
write_response "$RESPONSE" rule_4 0.9
reset_log
FM_DISPATCH_ROUTE=direct TYPESAFE_API_KEY="$KEY" run code out err "$BRIEF"
assert_contains "$out" '  status: clear' "direct route still resolves typed choices"
assert_contains "$(cat "$LOG/argv")" 'https://api.typesafe.ai/v1/systemone' "direct route uses native System One"
assert_equals 'jev-latest' "$(jq -r .model "$LOG/body")" "direct route uses native Jev id"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "direct key is used without new credentials"
assert_not_contains "$(cat "$LOG/child-env")" 'secret-present' "direct key is not exported to children"
pass "direct route fallback changes base, model, and key without touching the default route"

# --- startup canary: one batched-system-one request only when explicitly enabled ---
CANARY="$ROOT/bin/fm-dispatch-canary.sh"
printf '%s\n' '{"answers":{"probe":{"choice":"ready","confidence":0.99}}}' > "$RESPONSE"
reset_log
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" OPENROUTER_API_KEY="$KEY" "$CANARY" > "$TMP_ROOT/canary.out"
assert_absent "$LOG/argv" "canary stays off by default"
reset_log
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_DISPATCH_CANARY=1 OPENROUTER_API_KEY="$KEY" "$CANARY" > "$TMP_ROOT/canary.out"
assert_equals 'DISPATCH_CANARY: ok' "$(cat "$TMP_ROOT/canary.out")" "canary accepts a typed Choice"
assert_contains "$(cat "$LOG/argv")" 'https://openrouter.ai/api/v1/systemone' "canary uses OpenRouter System One"
assert_equals '1' "$(grep -c '^https://' "$LOG/argv")" "exactly one canary network request"
assert_equals 'typesafe/jev-1.13' "$(jq -r '.model' "$LOG/body")" "canary uses pinned Jev"
assert_not_contains "$(cat "$LOG/child-env")" 'secret-present' "key is not exported into the curl environment"
pass "opt-in startup canary makes one typed Choice request without exporting a credential"
reset_log
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_DISPATCH_CANARY=1 FM_DISPATCH_ROUTE=direct OPENROUTER_API_KEY="$KEY" "$CANARY" > "$TMP_ROOT/canary.out" 2> "$TMP_ROOT/canary.err"
assert_contains "$(cat "$TMP_ROOT/canary.err")" 'TYPESAFE_API_KEY absent' "direct canary is off without the direct key"
assert_absent "$LOG/argv" "direct canary never probes OpenRouter"
reset_log
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_DISPATCH_CANARY=1 FM_DISPATCH_ROUTE=direct TYPESAFE_API_KEY="$KEY" "$CANARY" > "$TMP_ROOT/canary.out"
assert_equals 'DISPATCH_CANARY: ok' "$(cat "$TMP_ROOT/canary.out")" "direct canary accepts a typed Choice"
assert_contains "$(cat "$LOG/argv")" 'https://api.typesafe.ai/v1/systemone' "direct canary probes the resolver's direct base"
assert_equals 'jev-latest' "$(jq -r '.model' "$LOG/body")" "direct canary uses the resolver's direct model"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "direct canary uses the direct key"
pass "startup canary follows the resolver's route selection"

# --- shared-quota opt-out: no quota call, declared-order pick ----------------
cp "$BASE_RULES" "$RULES"
jq '.shared_quota = true' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota clear exits 0"
assert_contains "$out" '  status: clear' "shared-quota clear status"
assert_contains "$out" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" "shared-quota picks the first declared profile, not the argmax winner"
assert_not_contains "$out" 'spendPriority=' "shared-quota prints no quota evidence"
assert_not_contains "$out" '  remaining=' "shared-quota prints no remaining percentages"
assert_not_contains "$out" '  runway=' "shared-quota prints no runway gates"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "every candidate line states quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota never reads quota-axi"
[ "$(printf '%s\n' "$out" | grep -c 'quota ranking off')" -ge 3 ] || fail "shared-quota states the opt-out on every candidate line"
pass "shared-quota opt-out: no quota snapshot, deterministic declared-order pick, opt-out stated on every candidate"

# --- shared-quota: an unmet rule-level floor is bypassed too -----------------
# rule_1 declares floor model:fable >= 20% but the fixture has 15% there, so the
# quota-ranked path would fall through to default; the opt-out keeps the rule.
jq '.shared_quota = true' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_1 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota unmet rule floor exits 0"
assert_contains "$out" '  status: clear' "shared-quota unmet rule floor status"
assert_contains "$out" '  note: rule matched' "shared-quota skips the unmet rule floor instead of falling through to default"
assert_not_contains "$out" 'fall through to default' "shared-quota unmet rule floor never falls through to default"
assert_contains "$out" "  profile: --harness 'claude' --model 'fable' --effort 'xhigh'" "shared-quota unmet rule floor picks the rule's own declared profile"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "unmet rule floor candidate states quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota unmet rule floor never reads quota-axi"
pass "shared-quota bypasses an unmet rule-level floor: the rule's own profile wins with no quota call"

# --- shared-quota: an unmet profile-level floor is bypassed too ---------------
# The codex profile declares floor all_models >= 50% but the fixture has 31%, so
# the quota-ranked path marks it not eligible; the opt-out resolves the declared
# order anyway. The use array is reversed so the floored profile is first.
jq '.shared_quota = true | .rules[1].use |= reverse' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_2 0.99
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota unmet profile floor exits 0"
assert_contains "$out" '  status: clear' "shared-quota unmet profile floor status"
assert_contains "$out" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" "shared-quota unmet profile floor picks the floored profile first in declared order"
assert_not_contains "$out" 'not eligible' "shared-quota unmet profile floor marks no candidate ineligible"
assert_contains "$out" 'quota ranking off: home declares a single shared quota' "unmet profile floor candidates state quota ranking is off"
assert_absent "$LOG/quota-axi.calls" "shared-quota unmet profile floor never reads quota-axi"
pass "shared-quota bypasses an unmet profile-level floor: the first declared profile wins with no quota call"

# --- shared-quota: preferred_provider still narrows the pool ------------------
# The matched rule declares claude first, then two codex-family profiles; the
# home prefers codex, so the first declared codex profile wins.
jq '.shared_quota = true | .preferred_provider = "codex" | .rules[3].use = [
  {harness:"claude",model:"sonnet",effort:"high"},
  {harness:"pi",model:"openai-codex/gpt-5.6-sol",provider:"codex"},
  {harness:"codex",model:"gpt-5.6-sol"}]' "$BASE_RULES" > "$RULES"
reset_log
write_response "$RESPONSE" rule_4 0.9
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared-quota preferred_provider exits 0"
assert_contains "$out" '  status: clear' "shared-quota preferred_provider status"
assert_contains "$out" '  preferred_provider: codex: prefer eligible family candidates' "shared-quota still applies the family preference"
assert_contains "$out" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" "shared-quota preferred_provider picks the first declared preferred-family profile"
assert_absent "$LOG/quota-axi.calls" "shared-quota preferred_provider never reads quota-axi"
[ "$(printf '%s\n' "$out" | grep -c '^  candidate: ')" -eq 3 ] || fail "shared-quota preferred_provider lists every candidate"
[ "$(printf '%s\n' "$out" | grep '^  candidate: ' | grep -c 'quota ranking off: home declares a single shared quota')" -eq 3 ] ||
  fail "shared-quota preferred_provider states the opt-out on every candidate line"
pass "shared-quota keeps preferred_provider narrowing: the preferred family wins in declared order with no quota call"

# --- shared_quota false: byte-for-byte the quota-ranked path ------------------
jq '.shared_quota = false' "$BASE_RULES" > "$RULES"
# restore the shared response fixture against these rules
write_response "$RESPONSE" rule_4 0.9
reset_log
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "shared_quota false exits 0"
assert_contains "$out" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" "shared_quota false keeps the spendPriority argmax"
assert_not_contains "$out" 'quota ranking off' "shared_quota false prints no opt-out wording"
[ -f "$LOG/quota-axi.calls" ] || fail "shared_quota false still reads quota-axi"
assert_contains "$out" 'spendPriority=' "shared_quota false prints quota evidence"
pass "shared_quota false keeps the unchanged quota-ranked behavior"
cp "$BASE_RULES" "$RULES"

printf '# all fm-dispatch-resolve tests passed\n'
