#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned typesafe.ai response.
# A fake quota-axi serves the selected schema-5 fixture. No case touches the
# network, and the absent-key case proves the tool makes no call
# at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_RULES="$TMP_ROOT/rules.json"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

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
if [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] || [ -n "${TYPESAFE_API_KEY+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
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
if [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ] || [ -n "${TYPESAFE_API_KEY+x}" ]; then
  printf 'quota-axi:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'quota-axi:clean\n' >> "${CHILD_ENV_LOG:?}"
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

RESPONSE="$TMP_ROOT/response.json"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" QUOTA_AXI_CALLS="$LOG/quota-axi.calls" QUOTA_AXI_FIXTURE="$QUOTA" CHILD_ENV_LOG="$LOG/child-env" ZAI_WARM_LOG="$LOG/zai-warm.calls"
# Retry tests keep the bounded gather fast; production defaults live in the tool.
export FM_DISPATCH_QUOTA_BACKOFF_MS="${FM_DISPATCH_QUOTA_BACKOFF_MS:-20}"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME; OPENROUTER_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
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

KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

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
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
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

printf '# all fm-dispatch-resolve tests passed\n'
