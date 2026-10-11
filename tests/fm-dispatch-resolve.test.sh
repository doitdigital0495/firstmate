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

# --- clear writes the dispatch receipt the launch gate asks for ---------------
RECEIPT_DIR="$HOME_DIR/state/dispatch-receipt"
receipt_name=$(sed -n 's/^  receipt: \(dispatch-[^ ]*\) .*/\1/p' <<<"$out")
[ -n "$receipt_name" ] || fail "clear did not print the receipt it wrote: $out"
receipt="$RECEIPT_DIR/$receipt_name"
assert_present "$receipt" "clear writes its receipt under state/dispatch-receipt"
assert_equals '600' "$(stat -c %a "$receipt" 2>/dev/null || stat -f %Lp "$receipt")" "the receipt is private"
assert_equals 'resolve clear rule_4' "$(jq -r '"\(.source) \(.status) \(.row.id)"' "$receipt")" "the receipt names its source and matched row"
assert_equals '{"harness":"cursor","model":"cursor-grok-4.6-medium","effort":"","account":"","provider":"cursor"}' \
  "$(jq -c .profile "$receipt")" "the receipt carries the exact chosen profile"
assert_equals '64 64' "$(jq -r '"\(.brief.sha256 | length) \(.row.sha256 | length)"' "$receipt")" "the receipt binds the brief and the row by hash"
assert_equals '2' "$(jq '.candidates | length' "$receipt")" "the receipt accounts for every candidate of the row"
assert_equals 'true' "$(jq 'all(.candidates[]; (.catalog | length) > 0 and (.plan | length) > 0 and (.quotaIntakeRecord | length) > 0 and ((.spendPriority | type) == "number" or .spendPriority == "unknown") and (.eligible | type) == "boolean" and (.reason | type) == "string")' "$receipt")" \
  "each candidate carries catalog, plan, quota-intake record, spendPriority, eligibility, and reason"
run code out err gate --brief "$BRIEF" --task pager-fix --harness cursor --model cursor-grok-4.6-medium
expect_code 0 "$code" "the clear profile passes the gate with no extra step"
assert_contains "$out" "dispatch receipt gate: PASS - receipt $receipt_name (resolve, row rule_4)" "the gate names the receipt it admits"
run code out err gate --brief "$BRIEF" --task pager-fix --harness claude --model opus --effort high
expect_code 3 "$code" "a hand-picked profile beside a clear receipt is refused"
assert_contains "$out" "profile.harness is 'cursor' on the receipt but the launch passes 'claude'" "the refusal names the mismatching receipt field"
pass "clear: writes a private receipt binding the brief, the row, the profile, and every candidate, and the gate admits only that profile"

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
receipts_before=$(find "$RECEIPT_DIR" -name 'dispatch-*.json' | wc -l | tr -d ' ')
write_response "$RESPONSE" rule_4 0.41
OPENROUTER_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "ambiguous exits 0"
assert_contains "$out" '  status: ambiguous' "below the floor is ambiguous"
assert_contains "$out" '  reason: confidence 0.41 below floor 0.6' "ambiguous names the floor"
assert_contains "$out" '  receipt: none - only clear writes one' "a non-clear outcome says it wrote no receipt"
assert_equals "$receipts_before" "$(find "$RECEIPT_DIR" -name 'dispatch-*.json' | wc -l | tr -d ' ')" "a non-clear outcome writes no receipt"
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
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
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

# --- dispatch receipts: the guarded producers and the launch gate --------------
# Contract: bin/fm-dispatch-receipt-lib.sh. Everything here goes through the
# subcommands a home uses; the gate is called exactly as bin/fm-spawn.sh and
# bin/fm-control.sh relaunch call it.
RH="$TMP_ROOT/receipt-home"
RB="$RH/data/t1/brief.md"
mkdir -p "$RH/config" "$RH/state/quota-intake" "$RH/data/t1" "$RH/data/t2"
RTABLE='{"rules":[{"when":"hard design work","use":[{"harness":"claude","model":"opus","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol"}]},{"when":"routine work","approval":"captain","use":{"harness":"pi","model":"zai/glm-5","provider":"zai"}}],"default":[{"harness":"codex"}]}'
printf '%s\n' "$RTABLE" > "$RH/config/crew-dispatch.json"
printf '# Task\n## Captain'"'"'s intent\nRedesign the pager.\n' > "$RB"
printf '# Task\n## Captain'"'"'s intent\nAnother task entirely.\n' > "$RH/data/t2/brief.md"
printf '{}\n' > "$RH/state/quota-intake/quota-1-1-1.json"
ACCT="$TMP_ROOT/accounting.json"
WHY="$TMP_ROOT/rationale.txt"
WORDS="$TMP_ROOT/captain-words.txt"
printf 'spendPriority tie broken on the reasoning class the task needs\n' > "$WHY"
write_accounting() {  # <claude eligible> <codex intake record>
  jq -n --argjson claude "$1" --arg rec "$2" '[
    {harness: "claude", model: "opus", effort: "high", catalog: "claude model list names opus", plan: "max20",
     quotaIntakeRecord: "quota-1-1-1.json", spendPriority: 41.5, eligible: $claude, reason: "ok"},
    {harness: "codex", model: "gpt-5.6-sol", catalog: "codex catalog names gpt-5.6-sol", plan: "pro",
     quotaIntakeRecord: $rec, spendPriority: "unknown", eligible: false, reason: "weekly window at 0% remaining"}]' > "$ACCT"
}
rtool() {  # <exit-var> <out-var> [args...]: stdout and stderr together
  local __exit=$1 __out=$2 _out _code
  shift 2
  _out=$(FM_HOME="$RH" "$TOOL" "$@" 2>&1)
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}
rreceipts() { find "$RH/state/dispatch-receipt" -name 'dispatch-*.json' 2>/dev/null | wc -l | tr -d ' '; }
CHOOSE=(choose "$RB" --task t1 --row rule_1 --harness claude --model opus --effort high --accounting-file "$ACCT" --rationale-file "$WHY")

rtool code out rows
expect_code 0 "$code" "rows lists the table"
assert_contains "$out" 'row rule_1  sha256=' "rows names each row by id and hash"
assert_contains "$out" '  candidate: --harness claude --model opus --effort high' "rows lists each candidate as launch flags"
assert_contains "$out" 'row rule_2  sha256=' "rows lists every rule"
assert_contains "$out" 'approval=captain' "rows shows a declared approval"
assert_contains "$out" 'row default  sha256=' "rows lists the default row"

# With rows in the table and no receipt, a hand-picked profile is refused.
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high
expect_code 3 "$code" "no receipt refuses"
assert_contains "$out" 'dispatch receipt gate: refusing - no dispatch receipt binds the brief of t1' "the refusal names the missing receipt"
assert_contains "$out" 'the newest receipt in this home binds nothing, because there is none' "the refusal says the home holds no receipt"
assert_contains "$out" 'bin/fm-dispatch-resolve.sh choose <brief> --row <id>' "the refusal names the producing command"

# choose: bound to one row, its candidates, and the per-candidate accounting.
write_accounting true quota-1-1-1.json
rtool code out choose "$RB" --row rule_1 --harness claude --model sonnet --accounting-file "$ACCT" --rationale-file "$WHY"
expect_code 2 "$code" "a profile outside the row is refused"
assert_contains "$out" 'is not a candidate of row rule_1; a profile outside the matched row is refused' "choose names the row the profile is outside"
rtool code out choose "$RB" --row rule_9 --harness claude --model opus --effort high --accounting-file "$ACCT" --rationale-file "$WHY"
expect_code 2 "$code" "an unknown row is refused"
assert_contains "$out" "row 'rule_9' is not in" "choose names the unknown row"
rtool code out choose "$RB" --harness claude --model opus --effort high --accounting-file "$ACCT" --rationale-file "$WHY"
expect_code 2 "$code" "choose without a row is refused"
assert_contains "$out" 'choose requires --row' "choose demands the row id"
jq '.[0:1]' "$ACCT" > "$TMP_ROOT/accounting-short.json"
rtool code out choose "$RB" --row rule_1 --harness claude --model opus --effort high --accounting-file "$TMP_ROOT/accounting-short.json" --rationale-file "$WHY"
expect_code 2 "$code" "accounting that omits a candidate is refused"
assert_contains "$out" 'accounting omits a candidate of the row: codex:gpt-5.6-sol' "choose names the omitted candidate"
jq 'del(.[1].catalog)' "$ACCT" > "$TMP_ROOT/accounting-nocatalog.json"
rtool code out choose "$RB" --row rule_1 --harness claude --model opus --effort high --accounting-file "$TMP_ROOT/accounting-nocatalog.json" --rationale-file "$WHY"
expect_code 2 "$code" "accounting without catalog evidence is refused"
assert_contains "$out" 'every accounting entry needs catalog' "choose names the missing accounting field"
jq '.[1].spendPriority = "plenty"' "$ACCT" > "$TMP_ROOT/accounting-guess.json"
rtool code out choose "$RB" --row rule_1 --harness claude --model opus --effort high --accounting-file "$TMP_ROOT/accounting-guess.json" --rationale-file "$WHY"
expect_code 2 "$code" "a spendPriority that is neither a number nor unknown is refused"
assert_contains "$out" 'spendPriority: a number or the literal "unknown"' "choose names the spendPriority rule"
write_accounting true quota-9-9-9.json
rtool code out "${CHOOSE[@]}"
expect_code 2 "$code" "accounting from a quota-intake record the home does not hold is refused"
assert_contains "$out" 'quota-intake record(s) this home does not hold: quota-9-9-9.json' "choose names the absent intake record"
write_accounting false quota-1-1-1.json
rtool code out "${CHOOSE[@]}"
expect_code 2 "$code" "choosing a candidate the accounting excludes is refused"
assert_contains "$out" 'the chosen profile is marked not eligible in the accounting' "choose names the excluded pick"
write_accounting true quota-1-1-1.json
: > "$TMP_ROOT/empty.txt"
rtool code out choose "$RB" --task t1 --row rule_1 --harness claude --model opus --effort high --accounting-file "$ACCT" --rationale-file "$TMP_ROOT/empty.txt"
expect_code 2 "$code" "an empty rationale is refused"
assert_equals 0 "$(rreceipts)" "no refused choose leaves a receipt"
rtool code out "${CHOOSE[@]}"
expect_code 0 "$code" "a routed choice with complete accounting is recorded: $out"
assert_contains "$out" '  status: chosen' "choose reports its status"
assert_contains "$out" '  profile: --harness claude --model opus --effort high' "choose prints the profile line for fm-spawn"
assert_equals 1 "$(rreceipts)" "choose writes one receipt"
pass "choose: refuses a profile outside the row, an unknown row, incomplete or guessed accounting, an excluded pick, and an empty rationale"

# The gate admits exactly that profile, once.
rtool code out gate --brief "$RH/data/t2/brief.md" --task t2 --harness claude --model opus --effort high
expect_code 3 "$code" "a receipt for another brief refuses"
assert_contains "$out" 'no dispatch receipt binds the brief of t2' "another brief's receipt binds nothing here"
assert_contains "$out" "the newest receipt in this home binds $(cd "$RH/data/t1" && pwd -P)/brief.md" "the refusal names the brief that is bound"
rtool code out gate --brief "$RB" --task t9 --harness claude --model opus --effort high
expect_code 3 "$code" "a receipt issued for another task refuses"
assert_contains "$out" "was issued for task 't1', not t9" "the refusal names the task mismatch"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort max
expect_code 3 "$code" "a different effort than the receipt refuses"
assert_contains "$out" "profile.effort is 'high' on the receipt but the launch passes 'max'" "the refusal names the mismatching field"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high --account geris
expect_code 3 "$code" "a different account than the receipt refuses"
assert_contains "$out" "profile.account is 'default' on the receipt but the launch passes 'geris'" "the refusal names the account mismatch"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high
expect_code 0 "$code" "a preview passes and spends nothing"
assert_contains "$out" '(preview)' "a gate call without --consume is a preview"
# A relaunch progress note appended to the brief does not unbind its receipt.
cp "$RB" "$TMP_ROOT/brief-before-note.md"
printf '\n## Progress note (2026-01-01T00:00:00Z)\n\nThis task was relaunched.\n' >> "$RB"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high --consume
expect_code 0 "$code" "the launch consumes the receipt across an appended progress note: $out"
assert_contains "$out" 'receipt consumed' "the consuming gate says so"
cp "$TMP_ROOT/brief-before-note.md" "$RB"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high --consume
expect_code 3 "$code" "a consumed receipt refuses"
assert_contains "$out" 'was already consumed by a launch' "the refusal says the receipt was consumed"
pass "gate: one receipt admits one launch of its own brief, task, and profile, and nothing else"

# Stale: the window can only be shortened, never widened.
rtool code out "${CHOOSE[@]}"
stale=$(find "$RH/state/dispatch-receipt" -name 'dispatch-*.json' ! -name "$(basename "$(find "$RH/state/dispatch-receipt" -name '*.spent' | sed 's/\.spent$//')")")
jq '.issuedAtEpoch -= 1000' "$stale" > "$stale.tmp" && mv "$stale.tmp" "$stale"
FM_DISPATCH_RECEIPT_MAX_AGE=99999999 rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high
expect_code 3 "$code" "a receipt older than the fixed cap refuses whatever the environment asks for"
assert_contains "$out" 'is stale: issuedAt is' "the refusal says the receipt is stale"
assert_contains "$out" '(max 900s)' "the freshness window cannot be widened past its cap"
pass "gate: a stale receipt refuses and the freshness window cannot be widened"

# The table moved on: the receipt's row changed, or it never held the profile.
rtool code out "${CHOOSE[@]}"
jq '.rules[0].use += [{"harness":"grok"}]' "$RH/config/crew-dispatch.json" > "$TMP_ROOT/table.tmp" && cp "$TMP_ROOT/table.tmp" "$RH/config/crew-dispatch.json"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high
expect_code 3 "$code" "a receipt whose row has since changed refuses"
assert_contains "$out" "names row.id 'rule_1'" "the refusal names the row"
assert_contains "$out" 'that row has changed in config/crew-dispatch.json since' "the refusal says the row changed"
printf '%s\n' "$RTABLE" > "$RH/config/crew-dispatch.json"
# A receipt written by hand for a profile the row does not hold is refused: the
# gate re-derives membership from the current table.
forged="$RH/state/dispatch-receipt/dispatch-9999999999-000000000-1.json"
newest=$(find "$RH/state/dispatch-receipt" -name 'dispatch-*.json' | LC_ALL=C sort | tail -n 1)
jq --argjson now "$(date -u +%s)" '.receipt = "dispatch-9999999999-000000000-1.json" | .issuedAtEpoch = $now | .profile.model = "fable" | .profile.effort = "max"' "$newest" > "$forged"
rtool code out gate --brief "$RB" --task t1 --harness claude --model fable --effort max
expect_code 3 "$code" "a profile outside the matched row refuses even on a hand-written receipt"
assert_contains "$out" "is not a candidate of row.id 'rule_1' in the current config/crew-dispatch.json; a profile outside the matched row is refused" "the refusal names the row the profile is outside"
rm -f "$forged"
pass "gate: a receipt whose row changed, or whose profile the row does not hold, refuses"

# override: the captain's exact words, for one task, never silent.
rtool code out override "$RB" --task t1 --harness claude --model fable --effort max --words-file "$TMP_ROOT/empty.txt"
expect_code 2 "$code" "an override with empty words is refused"
assert_contains "$out" "the captain's words are empty; an override without the captain's exact words is refused" "override names the empty words"
printf '   \n\n' > "$WORDS"
rtool code out override "$RB" --task t1 --harness claude --model fable --effort max --words-file "$WORDS"
expect_code 2 "$code" "an override with whitespace-only words is refused"
printf 'use fable at max for this one\n' > "$WORDS"
rtool code out override "$RB" --harness claude --model fable --effort max --words-file "$WORDS"
expect_code 2 "$code" "an override with no task is refused"
assert_absent "$RH/data/dispatch-overrides.jsonl" "a refused override logs nothing"
rtool code out override "$RB" --task t1 --harness claude --model fable --effort max --words-file "$WORDS"
expect_code 0 "$code" "an override with the captain's words is recorded: $out"
assert_contains "$out" '  override: captain' "override marks the receipt override=captain"
assert_equals 'captain|use fable at max for this one|t1' "$(jq -r 'select(.override != null) | "\(.override.by)|\(.override.words)|\(.override.task)"' "$RH"/state/dispatch-receipt/dispatch-*.json | tail -n 1)" \
  "the override receipt carries the captain's exact words and the task id"
assert_equals 't1|use fable at max for this one|fable' "$(jq -r '"\(.task)|\(.words)|\(.profile.model)"' "$RH/data/dispatch-overrides.jsonl")" \
  "the override is appended to the durable log"
rtool code out overrides --recent
assert_contains "$out" 'task=t1  --harness claude --model fable --effort max  captain: "use fable at max for this one"' "the recent listing shows the override and its words"
rtool code out gate --brief "$RB" --task t2 --harness claude --model fable --effort max
expect_code 3 "$code" "an override for one task does not admit another"
rtool code out gate --brief "$RB" --task t1 --harness claude --model fable --effort max --raw --consume
expect_code 0 "$code" "the override admits its own off-table profile, raw command included: $out"
assert_contains "$out" 'override=captain' "the gate reports the override it admitted"
# An override receipt with no entry in the durable log is not an override.
rtool code out override "$RB" --task t1 --harness claude --model fable --effort max --words-file "$WORDS"
: > "$RH/data/dispatch-overrides.jsonl"
rtool code out gate --brief "$RB" --task t1 --harness claude --model fable --effort max
expect_code 3 "$code" "an override receipt missing from the log refuses"
assert_contains "$out" 'is marked override=captain but' "the refusal names the unlogged override"
pass "override: refuses empty words and a missing task, logs the captain's words durably, and admits only its own task"

# A raw launch command never rides a table receipt.
rtool code out "${CHOOSE[@]}"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high --raw
expect_code 3 "$code" "a raw launch command on a table receipt refuses"
assert_contains "$out" 'a raw launch command cannot be matched to a profile of the dispatch table; only a captain override admits it' "the refusal names the override as the only way"

# Keeping the recorded profile is no new routing decision; changing it is.
printf 'harness=claude\nmodel=opus\neffort=high\nkind=ship\n' > "$TMP_ROOT/recorded.meta"
rm -rf "$RH/state/dispatch-receipt"/dispatch-*
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high --recorded-meta "$TMP_ROOT/recorded.meta"
expect_code 0 "$code" "a relaunch that keeps the recorded profile needs no receipt: $out"
assert_contains "$out" 't1 keeps its recorded profile' "the gate says why no receipt was needed"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort max --recorded-meta "$TMP_ROOT/recorded.meta"
expect_code 3 "$code" "a relaunch onto a new effort needs a receipt"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high --account geris --recorded-meta "$TMP_ROOT/recorded.meta"
expect_code 3 "$code" "a relaunch onto a new account needs a receipt"
pass "gate: a raw command needs an override, and only a launch that keeps the recorded profile skips the receipt"

# A mismatch names the way to drop a carried-over value only where one exists.
rtool code out "${CHOOSE[@]}"
expect_code 0 "$code" "choose records a receipt for the mismatch checks: $out"
rtool code out gate --brief "$RB" --task t1 --harness claude --model sonnet --effort high
expect_code 3 "$code" "a launch whose model differs from the receipt refuses"
assert_contains "$out" "profile.model is 'opus' on the receipt but the launch passes 'sonnet'" "the refusal names the mismatching model"
assert_contains "$out" 'pass --model default to drop a carried-over value' "a model mismatch names the flag that drops a carried-over model"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort high --account geris
expect_code 3 "$code" "a launch whose account differs from the receipt refuses"
assert_contains "$out" "profile.account is 'default' on the receipt but the launch passes 'geris'" "the refusal names the mismatching account"
assert_not_contains "$out" '--account default' "an account mismatch must not suggest a flag value no launch accepts"
pass "gate: a mismatch suggests dropping a carried-over value for model and effort only"

# The parent-admission variable a remote second-mate host is handed admits
# nothing in an ordinary home: this launch still needs its own receipt.
rm -rf "$RH/state/dispatch-receipt"/dispatch-*
out=$(FM_HOME="$RH" FM_DISPATCH_PARENT_ADMITTED=t1 "$TOOL" gate --brief "$RB" --task t1 --harness claude --model opus --effort high 2>&1); code=$?
expect_code 3 "$code" "the parent-admission variable must not switch the gate off for an ordinary launch"
assert_contains "$out" 'no dispatch receipt binds the brief of t1' "the ordinary launch is still refused for its missing receipt"
pass "gate: the remote second-mate parent admission does not admit an ordinary launch"

# A home with no routing rows has nothing to route from, whether the table
# is absent or holds notes only; a malformed table refuses.
mv "$RH/config/crew-dispatch.json" "$TMP_ROOT/table.bak"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort max
expect_code 0 "$code" "a home with no table has nothing to route from: $out"
assert_contains "$out" 'PASS - this home has no routing rows' "the gate says there is no table to route from"
printf '{"model_notes":{"claude":"notes only"}}\n' > "$RH/config/crew-dispatch.json"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort max
expect_code 0 "$code" "a notes-only table has no routing rows: $out"
assert_contains "$out" 'PASS - this home has no routing rows' "the gate says a notes-only table has nothing to route from"
printf '{broken\n' > "$RH/config/crew-dispatch.json"
rtool code out gate --brief "$RB" --task t1 --harness claude --model opus --effort max
expect_code 3 "$code" "a malformed table refuses"
assert_contains "$out" 'is not a readable, well-formed rules file' "the refusal names the malformed table"
pass "gate: a home with no routing rows is not gated, and a malformed table refuses"

printf '# all fm-dispatch-resolve tests passed\n'
