#!/usr/bin/env bash
# Public resolver and receipt gate regressions with a real private stub socket.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
mkdir -p "$TMP_ROOT"
HOME_DIR="$TMP_ROOT/home"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
TOOL="$ROOT/bin/fm-dispatch-resolve.sh"
SOCKET="$TMP_ROOT/jev.sock"
RESPONSE="$TMP_ROOT/response.json"
LOG="$TMP_ROOT/requests.jsonl"
BRIEF="$HOME_DIR/data/brief.md"
RULES="$HOME_DIR/config/crew-dispatch.json"
QUOTA="$TMP_ROOT/quota.json"
SERVER=''
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
printf '# Task\n## Captain%s intent\nFix the pager.\n## Firstmate spec\nOne page per call.\n' "'" > "$BRIEF"
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Small fix", "use":{"harness":"claude","model":"sonnet","reasoning_class":1}},{"when":"Hard design", "use":{"harness":"claude","model":"opus","reasoning_class":2}}],"default":{"harness":"claude","model":"sonnet","reasoning_class":1}}
JSON
cat > "$QUOTA" <<'JSON'
{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","plan":"Max","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":90,"resetsAt":"2030-01-02T00:00:00Z"},{"id":"seven_day","kind":"weekly","percentRemaining":80,"resetsAt":"2030-01-04T00:00:00Z"}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["five_hour","seven_day"],"runway":{"status":"through_reset"},"selection":{"spendPriority":1}}]}}]}
JSON
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QUOTA_CALL_LOG"
printf 'claude=%s pi=%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "${PI_CODING_AGENT_DIR:-unset}" >> "$QUOTA_STORE_LOG"
if [ "${1:-}" = --json ] && [ -n "${QUOTA_HANG_READ:-}" ] && [ "$(grep -c '^--json$' "$QUOTA_CALL_LOG")" -ge 2 ]; then
  sleep 20
fi
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH" QUOTA_FIXTURE="$QUOTA" QUOTA_CALL_LOG="$TMP_ROOT/quota-calls" QUOTA_STORE_LOG="$TMP_ROOT/quota-stores"
# The intake is real even though other suites default to a gate bypass.
unset FM_QUOTA_INTAKE_TEST_BYPASS
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_JEVD_SOCKET="$SOCKET"
export FM_DISPATCH_QUOTA_ATTEMPTS=2 FM_DISPATCH_QUOTA_BACKOFF_MS=250 FM_DISPATCH_QUOTA_WAIT_SECONDS=1
write_response() {
  jq -n --slurpfile rules "$RULES" --arg choice "$1" --argjson confidence "$2" --argjson probabilities "$3" --arg preferred "${4:-rule_1_1}" '
    def profiles: if type == "array" then . else [.] end;
    (([$rules[0].rules // [] | to_entries[] | .key as $r | .value.use | profiles | to_entries[] | "rule_\($r + 1)_\(.key + 1)"] +
      [($rules[0].default // [] | profiles) | to_entries[] | "default_\(.key + 1)"])) as $ids |
    {model:"typesafe/jev-1.13",answers:{rule:{choice:$choice,confidence:$confidence,probabilities:$probabilities},
      profile:{choice:$preferred,confidence:1,probabilities:($ids | map({key:.,value:(if . == $preferred then 1 else 0 end)}) | from_entries)}},usage:{input_tokens:10,output_tokens:4}}' > "$RESPONSE"
}
run() { code=0; out=$("$TOOL" "$@" 2>&1) || code=$?; }
latest() { find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' | sort | tail -1; }
start_stub() {
  python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" &
  SERVER=$!
  for ((i=0;i<100;i++)); do [ ! -S "$SOCKET" ] || return 0; sleep 0.02; done
  fail 'stub did not start'
}
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'hand-picked launch refused'
assert_contains "$out" 'no dispatch receipt binds' 'missing receipt named'
for command in choose degraded override; do
  run "$command" "$BRIEF" --harness claude
  expect_code 2 "$code" "$command cannot mint a self-service receipt"
done
pass 'hand-picking and self-service receipt producers refused'
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
start_stub
run "$BRIEF" --project pager --task pager
expect_code 0 "$code" "Jev resolution succeeds: $out"
assert_contains "$out" 'source: jev' 'source visibly Jev'
receipt=$(latest)
assert_equals jev "$(jq -r .source "$receipt")" 'receipt source'
assert_equals stub-dispatch-1 "$(jq -r .jev.requestId "$receipt")" 'request id retained'
intake=$(jq -r .quotaIntakeRecord "$receipt")
assert_present "$HOME_DIR/state/quota-intake/$intake" 'receipt names real quota intake'
assert_equals 600 "$(stat -c %a "$receipt")" 'receipt private'
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'hand-picked model differs from routed receipt'
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet --consume
expect_code 0 "$code" "routed launch admitted: $out"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet --consume
expect_code 3 "$code" 'spent receipt refused'
assert_contains "$out" 'already consumed' 'spent named'
pass 'Jev receipt binds profile, quota intake, request id, one launch'
request=$(head -1 "$LOG")
assert_not_contains "$request" 'reasoning_class' 'Jev does not get eligibility metadata'
assert_not_contains "$request" 'spendPriority' 'Jev does not get quota'
assert_contains "$request" 'dispatch_choices' 'typed socket protocol'
# Stale, changed-table, changed-brief, and disabled legacy sources all refuse.
run "$BRIEF" --task pager
receipt=$(latest)
cp "$receipt" "$TMP_ROOT/receipt-backup"
jq '.issuedAtEpoch -= 901' "$TMP_ROOT/receipt-backup" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'stale receipt refused'
cp "$TMP_ROOT/receipt-backup" "$receipt"
jq '.source="override"' "$TMP_ROOT/receipt-backup" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'legacy override receipt refused'
cp "$TMP_ROOT/receipt-backup" "$receipt"
printf '\nChanged deliverable\n' >> "$BRIEF"
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'changed brief refused'
pass 'stale, spent, changed brief and legacy override receipts refused'
# Low confidence unions the qualifying rows, retaining only the strongest class.
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"default":0.25}'
run "$BRIEF" --task pager
assert_contains "$out" 'ambiguous union >= 0.25' "ambiguous union routed: $out"
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'stronger class wins over Jev preference'
cp "$RULES" "$TMP_ROOT/rules-backup"
jq 'del(.default.reasoning_class)' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'ambiguous union needs numeric reasoning_class' 'missing class stops'
jq '.rules[1].approval="captain"' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'requires captain approval' 'approval union stops'
cp "$TMP_ROOT/rules-backup" "$RULES"
pass 'ambiguous unions keep strongest class; unknown class and approval stop'
write_response rule_2 0.95 '{"rule_1":0.03,"rule_2":0.95,"default":0.02}'
jq '.rules[1].approval="captain"' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: escalate' 'captain approval stops'
cp "$TMP_ROOT/rules-backup" "$RULES"
# Unknown quota waits within the configured, shorten-only deadline, never guesses.
cp "$QUOTA" "$TMP_ROOT/quota-backup"
jq '.providers[0].quotaSemantics = {status:"unknown", effectiveAvailability:[]}' "$TMP_ROOT/quota-backup" > "$QUOTA"
run "$BRIEF" --task pager
assert_contains "$out" 'status: incomplete' "unknown quota stays incomplete: $out"
hang_started=$SECONDS
QUOTA_HANG_READ=1 QUOTA_CALL_LOG="$TMP_ROOT/hang-calls" run "$BRIEF" --task pager
assert_contains "$out" 'status: incomplete' 'slow retry remains incomplete'
[ "$((SECONDS - hang_started))" -lt 12 ] || fail 'slow quota retry escaped the shortened incomplete deadline'
cp "$TMP_ROOT/quota-backup" "$QUOTA"
pass 'escalate asks captain; incomplete retries and stops without receipt, including slow reads'
# Exercise quota ranking and fail-closed policies via the socket interface.
cp "$RULES" "$TMP_ROOT/original-rules"
cp "$QUOTA" "$TMP_ROOT/original-quota"
jq '.rules[0].use=[.rules[0].use,.rules[1].use] | .rules[0].use[0].floor={scope:"all_models",min_percent:90}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'profile floor excludes below-minimum preferred candidate'
# A genuine tie needs a preference for one of the tied candidates, not default.
jq 'del(.rules[0].use[0].floor)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' default_1
run "$BRIEF" --task pager
assert_contains "$out" 'genuine spendPriority tie' 'unrelated preference cannot break tie'
# A model-specific bound must constrain its candidate, not its neighbor.
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"model:sonnet",status:"known",effectivePercentRemaining:50,boundedBy:["seven_day"],runway:{status:"through_reset"},selection:{spendPriority:-1}}]' "$TMP_ROOT/original-quota" > "$QUOTA"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'limiting model-specific spendPriority beats Jev preference'
# All unknown candidates remain in the choice, rather than dropping to a known one.
jq 'del(.providers[0].windows[1].resetsAt)' "$TMP_ROOT/original-quota" > "$QUOTA"
run "$BRIEF" --task pager
assert_contains "$out" 'status: incomplete' 'missing reset evidence blocks ranking'
cp "$TMP_ROOT/original-quota" "$QUOTA"
cp "$TMP_ROOT/original-rules" "$RULES"
jq '.rules[1].floor={scope:"all_models",provider:"claude",min_percent:10}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"default":0.25}'
run "$BRIEF" --task pager
assert_contains "$out" 'ambiguous union >= 0.25' 'measured ambiguous rule floor can route'
jq '.rules[1].floor.min_percent=99' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: escalate' 'strongest class below rule floor stops rather than downgrading'
cp "$TMP_ROOT/original-rules" "$RULES"
jq '.rules[0].min_confidence=0.9 | .rules[1].min_confidence=0.4' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.5,"rule_2":0.49,"default":0.01}'
run "$BRIEF" --task pager
assert_contains "$out" 'fallback: rule_2' 'declared confidence runner-up remains deterministic'
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'runner-up row selected'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'quota floors, ties, model bounds, missing resets and declared confidence fallback'
mkdir -p "$TMP_ROOT/claude-seat" "$TMP_ROOT/pi-seat"
printf '%s\n' "$TMP_ROOT/claude-seat" > "$HOME_DIR/config/claude-account"
printf '%s\nopenai-codex\n' "$TMP_ROOT/pi-seat" > "$HOME_DIR/config/pi-account"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' 'captain-owned pins can route'
assert_contains "$(<"$QUOTA_STORE_LOG")" "claude=$TMP_ROOT/claude-seat pi=$TMP_ROOT/pi-seat" 'ranking and intake read the launch pins'
rm "$HOME_DIR/config/claude-account" "$HOME_DIR/config/pi-account"
# Invalid candidate ranks stop before sending text, rather than guessing.
jq '.rules[0].use.reasoning_class="weak"' "$TMP_ROOT/original-rules" > "$RULES"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
expect_code 2 "$code" 'nonnumeric reasoning rank is a configuration error'
assert_equals "$requests_before" "$(wc -l < "$LOG")" 'invalid table is never sent'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'quota reads honor captain-owned pins; invalid ranks fail before transport'
# Default-only tables still receive a valid Jev Choice, without degrading.
jq '{default:.default}' "$TMP_ROOT/original-rules" > "$RULES"
write_response default 1 '{"default":1}' default_1
run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' "default-only table can route: $out"
cp "$TMP_ROOT/original-rules" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
# The first bad answer gets one retry, and a second valid answer is Jev-sourced.
jq '{_stubResponses:[{},.]}' "$RESPONSE" > "$TMP_ROOT/response-next"; mv "$TMP_ROOT/response-next" "$RESPONSE"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' 'one retry can recover'
assert_equals 2 "$(( $(wc -l < "$LOG") - requests_before ))" 'exactly one retry after invalid Choice'
# Mutating the brief in-flight must not authorize its new words.
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
jq --arg path "$BRIEF" --arg text "$(<"$BRIEF") new deliverable" '. + {_stubMutate:{path:$path,text:$text}}' "$RESPONSE" > "$TMP_ROOT/response-next"; mv "$TMP_ROOT/response-next" "$RESPONSE"
run "$BRIEF" --task pager
expect_code 3 "$code" 'brief changed while Jev answered is refused'
assert_contains "$out" 'brief changed during resolution' 'brief race names binding mismatch'
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
jq --arg path "$RULES" --arg text "$(jq '.rules[0].when="Changed fit"' "$RULES")" '. + {_stubMutate:{path:$path,text:$text}}' "$RESPONSE" > "$TMP_ROOT/response-next"; mv "$TMP_ROOT/response-next" "$RESPONSE"
run "$BRIEF" --task pager
expect_code 3 "$code" 'table changed while Jev answered is refused'
assert_contains "$out" 'table changed during resolution' 'table race names binding mismatch'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'default-only tables, one-retry recovery and in-flight input binding'
# Unusable permissions and invalid replies cannot be treated as Jev routes.
printf '{}\n' > "$RESPONSE"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
assert_contains "$out" 'source: degraded' 'two invalid answers degrade'
assert_equals 2 "$(( $(wc -l < "$LOG") - requests_before ))" 'invalid answers get exactly two attempts'
chmod 666 "$SOCKET"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
assert_contains "$out" 'source: degraded' 'unsafe socket mode degrades without sending task text'
assert_equals "$requests_before" "$(wc -l < "$LOG")" 'unsafe socket never receives task text'
chmod 600 "$SOCKET"
run degraded-recent
assert_contains "$out" 'source=degraded' 'degraded receipt is visible to session startup'
# New fixture day for the isolated daily-cap proof.
rm -f "$HOME_DIR/state/dispatch-receipt"/degraded-*.count
pass 'invalid replies and unsafe socket modes fail closed, with visible degraded records'
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true; SERVER=''
rm -f "$SOCKET"
for ((i=1;i<=3;i++)); do
  run "$BRIEF" --task pager
  assert_contains "$out" 'source: degraded' "down Jev produces degraded receipt $i: $out"
  assert_equals degraded "$(jq -r .source "$(latest)")" 'flag retained'
  assert_contains "$(jq -r .degraded.reason "$(latest)")" 'one retry' 'reason retained'
done
before=$(latest)
run "$BRIEF" --task pager
assert_contains "$out" 'degraded daily cap 3 reached' 'fourth degraded stops and reports'
assert_equals "$before" "$(latest)" 'cap produced no receipt'
pass 'Jev down retries once then flagged degraded default route, capped at 3 UTC/day'
echo '# all fm-dispatch-resolve tests passed'
