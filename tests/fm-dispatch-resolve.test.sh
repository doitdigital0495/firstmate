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
# An optional JSON map keyed by CLAUDE_CONFIG_DIR lets a test give separate
# accounts separate snapshots; every other read uses $QUOTA_FIXTURE.
if [ -n "${QUOTA_FIXTURE_MAP:-}" ]; then
  mapped=$(printf '%s' "$QUOTA_FIXTURE_MAP" | jq -r --arg k "${CLAUDE_CONFIG_DIR:-}" '.[$k] // empty' 2>/dev/null) || mapped=''
  if [ -n "$mapped" ] && [ -r "$mapped" ]; then
    cat "$mapped"
    exit 0
  fi
fi
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH" QUOTA_FIXTURE="$QUOTA" QUOTA_CALL_LOG="$TMP_ROOT/quota-calls" QUOTA_STORE_LOG="$TMP_ROOT/quota-stores"
# The intake is real even though other suites default to a gate bypass.
unset FM_QUOTA_INTAKE_TEST_BYPASS
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_JEVD_SOCKET="$SOCKET"
export FM_DISPATCH_QUOTA_ATTEMPTS=2 FM_DISPATCH_QUOTA_BACKOFF_MS=250 FM_DISPATCH_QUOTA_WAIT_SECONDS=1 FM_JEVD_SOCKET_WAIT_SECONDS=0
# Captain words come only from these two records; the tests own both.
export FM_LAVISH_STATE="$TMP_ROOT/lavish-state.json" FM_JEVD_AUDIT_JOURNAL=0 FM_JEVD_AUDIT_LOG="$TMP_ROOT/jevd.log"
MIRROR="$HOME_DIR/state/.host-mirror.jsonl"
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
assert_contains "$out" 'status: captain-pick' 'a union with a missing class goes to the captain'
jq '.rules[1].approval="captain"' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'requires captain approval' 'approval union stops'
cp "$TMP_ROOT/rules-backup" "$RULES"
pass 'ambiguous unions keep strongest class; unknown class and approval stop'
write_response rule_2 0.95 '{"rule_1":0.03,"rule_2":0.95,"default":0.02}'
jq '.rules[1].approval="captain"' "$TMP_ROOT/rules-backup" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'captain approval stops for the captain to pick'
assert_contains "$out" 'row rule_2 p=0.95 approval=captain' 'the approval row leads the pick, Jev probability shown'
cp "$TMP_ROOT/rules-backup" "$RULES"
# Unknown quota waits within the configured, shorten-only deadline, never guesses.
cp "$QUOTA" "$TMP_ROOT/quota-backup"
jq '.providers[0].quotaSemantics = {status:"unknown", effectiveAvailability:[]}' "$TMP_ROOT/quota-backup" > "$QUOTA"
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' "unknown quota after the deadline goes to the captain: $out"
assert_contains "$out" 'jev: incomplete' 'the pick names the incomplete evidence'
assert_contains "$out" '-> incomplete: provider claude unmeasured' 'unmeasured candidates stay listed, marked'
hang_started=$SECONDS
QUOTA_HANG_READ=1 QUOTA_CALL_LOG="$TMP_ROOT/hang-calls" run "$BRIEF" --task pager
assert_contains "$out" 'jev: incomplete' 'slow retry remains incomplete'
[ "$((SECONDS - hang_started))" -lt 12 ] || fail 'slow quota retry escaped the shortened incomplete deadline'
cp "$TMP_ROOT/quota-backup" "$QUOTA"
pass 'escalate and incomplete go to a captain pick without a receipt, including slow reads'
# Exercise quota ranking and fail-closed policies via the socket interface.
cp "$RULES" "$TMP_ROOT/original-rules"
cp "$QUOTA" "$TMP_ROOT/original-quota"
jq '.rules[0].use=[.rules[0].use,.rules[1].use] | .rules[0].use[0].floor={scope:"all_models",min_percent:90}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'profile floor excludes below-minimum preferred candidate'
# An equal-class tie still needs a preference for one of the tied candidates, not default.
jq 'del(.rules[0].use[0].floor) | .rules[0].use[0].reasoning_class = .rules[0].use[1].reasoning_class' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
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
assert_contains "$out" 'jev: incomplete' 'missing reset evidence blocks ranking'
cp "$TMP_ROOT/original-quota" "$QUOTA"
cp "$TMP_ROOT/original-rules" "$RULES"
jq '.rules[1].floor={scope:"all_models",provider:"claude",min_percent:10}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"default":0.25}'
run "$BRIEF" --task pager
assert_contains "$out" 'ambiguous union >= 0.25' 'measured ambiguous rule floor can route'
jq '.rules[1].floor.min_percent=99' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'strongest class below rule floor stops rather than downgrading'
assert_contains "$out" 'not eligible: row floor all_models below 99%' 'the floor reason is on the card'
cp "$TMP_ROOT/original-rules" "$RULES"
jq '.rules[0].min_confidence=0.9 | .rules[1].min_confidence=0.4' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.5,"rule_2":0.49,"default":0.01}'
run "$BRIEF" --task pager
assert_contains "$out" 'fallback: rule_2' 'declared confidence runner-up remains deterministic'
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'runner-up row selected'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'quota floors, ties, model bounds, missing resets and declared confidence fallback'
# Keep-strongest classes rank a single matched rule before the spendPriority
# argmax, so an unused weaker pool cannot outbid the strongest declared class.
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"model:opus",status:"known",effectivePercentRemaining:70,boundedBy:["seven_day"],runway:{status:"through_reset"},selection:{spendPriority:0.5}}]' "$TMP_ROOT/original-quota" > "$QUOTA"
jq '.rules[0].use = [.rules[1].use, .rules[0].use]' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'strongest class beats weaker candidate with higher spendPriority'
assert_contains "$out" 'strongest reasoning class 2' 'class narrowing is disclosed'
# Equal declared classes still compete on spendPriority alone.
jq '.rules[0].use[0].reasoning_class = .rules[0].use[1].reasoning_class' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'equal class falls back to spendPriority'
assert_not_contains "$out" 'outranked' 'no class narrowing at equal class'
# A single missing class keeps plain spendPriority ranking, no silent guessing.
jq 'del(.rules[0].use[0].reasoning_class)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'missing class keeps spendPriority ranking'
# The class filter applies after eligibility, so an ineligible strongest
# candidate never blocks a weaker eligible one.
jq '.rules[0].use = [.rules[1].use, .rules[0].use] | .rules[0].use[0].floor = {scope:"all_models",min_percent:90}' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' 'ineligible strongest does not block weaker eligible'
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'eligible weaker class proceeds'
# The default row gets the same keep-strongest ranking.
jq '{default:[.rules[1].use,.rules[0].use]}' "$TMP_ROOT/original-rules" > "$RULES"
write_response default 1 '{"default":1}' default_1
run "$BRIEF" --task pager
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'default row keeps strongest class too'
assert_contains "$out" 'no rule matched; strongest reasoning class 2' 'default-row narrowing is disclosed'
cp "$TMP_ROOT/original-quota" "$QUOTA"
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'single-rule and default rows keep the strongest declared reasoning class'
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
# Upstream's additive table declarations ride the same socket route:
# preferred_provider narrows the pool, quota_scope binds a named row, and the
# shared-quota opt-out resolves declared order without quota snapshots.
for value in '"Codex"' 42 '""'; do
  jq --argjson value "$value" '.preferred_provider = $value' "$TMP_ROOT/original-rules" > "$RULES"
  run "$BRIEF" --task pager
  expect_code 2 "$code" "invalid preferred_provider $value is a configuration error"
  assert_contains "$out" 'preferred_provider must be a lowercase provider ID' 'preference error is actionable'
done
jq '.preferred_provider = "claude" | .rules[0].use = [.rules[0].use, .rules[1].use]' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_contains "$out" 'preferred_provider: claude: prefer eligible family candidates' "matched family is preferred: $out"
jq '.preferred_provider = "codex"' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'preferred_provider: codex: not in matched profiles; preserve the selected rule' 'absent family keeps the rule'
pass 'preferred_provider is validated, applied and explained'
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"tier_a",status:"known",effectivePercentRemaining:40,boundedBy:["seven_day"],runway:{status:"through_reset"},selection:{spendPriority:0.1}}]' "$TMP_ROOT/original-quota" > "$QUOTA"
jq '.rules[0].use.quota_scope = "tier_a"' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
run "$BRIEF" --task pager
assert_contains "$out" 'scope=tier_a  remaining=40%' "a declared quota_scope binds its row: $out"
cp "$TMP_ROOT/original-rules" "$RULES"
run "$BRIEF" --task pager
assert_not_contains "$out" 'scope=tier_a' 'without quota_scope the tier row stays unbound'
jq '.rules[0].use.quota_scope = "tier_b"' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'declared quota_scope tier_b has no quota row for provider claude: not rankable' 'a missing declared row is disclosed uncertainty'
jq '.rules[0].use.quota_scope = ""' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
expect_code 2 "$code" 'an empty quota_scope is a configuration error'
cp "$TMP_ROOT/original-quota" "$QUOTA"
pass 'quota_scope binds, discloses, and validates a named quota row'
jq '.shared_quota = "yes"' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
expect_code 2 "$code" 'a non-boolean shared_quota is a configuration error'
jq '.shared_quota = true | .rules[0].use = [.rules[1].use, .rules[0].use] | .rules[0].floor = {scope:"all_models",provider:"claude",min_percent:99}' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
json_reads_before=$(grep -c '^--json$' "$QUOTA_CALL_LOG" 2>/dev/null || true)
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "shared quota resolves: $out"
assert_contains "$out" 'eligible (quota ranking off: home declares a single shared quota)' 'every candidate states the opt-out'
assert_equals opus "$(jq -r .profile.model "$(latest)")" 'declared order picks, and the unmet rule floor is bypassed'
assert_equals "$json_reads_before" "$(grep -c '^--json$' "$QUOTA_CALL_LOG" 2>/dev/null || true)" 'shared quota takes no quota-axi --json snapshot'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'shared_quota resolves declared order with no quota snapshot, and rejects non-booleans'
# Fallback-only reserve tier: a geris-style Claude reserve seat is picked only
# when every non-fallback Claude seat is at its weekly limit, never over a
# healthy same-family seat or another family's candidate.
mkdir -p "$TMP_ROOT/claude2-seat" "$TMP_ROOT/geris-seat"
jq -n --arg c2 "$TMP_ROOT/claude2-seat" --arg g "$TMP_ROOT/geris-seat" \
  '{crossAccount:{enabled:true},accounts:{claude2:{claude:$c2},geris:{claude:$g}}}' > "$HOME_DIR/config/accounts.json"
seat_quota() {  # <weekly-remaining> <spend-priority> <runway> <session-remaining>
  jq -cn --argjson r7 "$1" --argjson sp "$2" --arg runway "$3" --argjson r5 "$4" \
    '{schemaVersion:5,generatedAt:"2030-01-01T00:00:00Z",providers:[{provider:"claude",plan:"Team",state:{status:"fresh"},windows:[{id:"five_hour",kind:"session",percentRemaining:$r5,resetsAt:"2030-01-02T00:00:00Z"},{id:"seven_day",kind:"weekly",percentRemaining:$r7,resetsAt:"2030-01-04T00:00:00Z"}],quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:([$r5,$r7]|min),boundedBy:["five_hour","seven_day"],runway:{status:$runway},selection:{spendPriority:$sp}}]}}]}'
}
seat_quota 80 1 through_reset 90 > "$TMP_ROOT/claude2-quota.json"
seat_quota 70 5 through_reset 90 > "$TMP_ROOT/geris-quota.json"
QUOTA_FIXTURE_MAP=$(jq -cn --arg c2 "$TMP_ROOT/claude2-seat" --arg g "$TMP_ROOT/geris-seat" \
  --arg cf "$TMP_ROOT/claude2-quota.json" --arg gf "$TMP_ROOT/geris-quota.json" '{($c2):$cf,($g):$gf}')
export QUOTA_FIXTURE_MAP
reserve_rules() {  # rule_1 pool: sonnet on the claude2 seat plus haiku on the geris seat
  jq '.rules[0].use = [{"harness":"claude","model":"sonnet","account":"claude2","reasoning_class":1},{"harness":"claude","model":"haiku","account":"geris","reasoning_class":1}]' \
    "$TMP_ROOT/original-rules" > "$RULES"
}
reserve_rules
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' rule_1_2
run "$BRIEF" --task pager
assert_not_contains "$out" 'fallback_only' 'an unset fallback_only changes nothing'
receipt=$(latest)
assert_equals haiku "$(jq -r .profile.model "$receipt")" 'unset flag keeps the spendPriority argmax'
assert_equals geris "$(jq -r .profile.account "$receipt")" 'unset flag keeps the declared account'
jq '.rules[0].use[1].fallback_only = true' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' "a held reserve still clears: $out"
assert_contains "$out" 'not eligible: fallback_only reserve held: non-fallback claude seats not at their limit (claude:sonnet@claude2)' 'held line states the reserve and why'
assert_equals sonnet "$(jq -r .profile.model "$(latest)")" 'a healthy non-fallback seat beats the reserve despite its higher spendPriority'
request=$(tail -1 "$LOG")
assert_not_contains "$request" 'fallback_only' 'Jev never sees the reserve flag'
seat_quota 0 1 exhausted_now 0 > "$TMP_ROOT/claude2-quota.json"
run "$BRIEF" --task pager
assert_contains "$out" 'eligible, reserve pick: every non-fallback claude seat is at its limit' 'picked line states the reserve and why'
receipt=$(latest)
assert_equals haiku "$(jq -r .profile.model "$receipt")" 'a fully used weekly window releases the reserve'
assert_equals geris "$(jq -r .profile.account "$receipt")" 'the reserve launches on its declared account'
assert_contains "$(jq -r .rationale "$receipt")" 'reserve pick' 'the receipt rationale states the reserve pick'
seat_quota 5 1 exhausted_now 90 > "$TMP_ROOT/claude2-quota.json"
run "$BRIEF" --task pager
assert_equals haiku "$(jq -r .profile.model "$(latest)")" 'an exhausted_now runway releases the reserve'
seat_quota 80 1 through_reset 0 > "$TMP_ROOT/claude2-quota.json"
run "$BRIEF" --task pager
assert_contains "$out" 'status: escalate' 'an exhausted session window alone never releases the reserve'
assert_contains "$out" 'fallback_only reserve held' 'the held reserve is disclosed while escalating'
# Another family's candidate still outranks an activated reserve.
jq '.providers += [{provider:"codex",plan:"Plus",state:{status:"fresh"},windows:[{id:"five_hour",kind:"session",percentRemaining:85,resetsAt:"2030-01-02T00:00:00Z"}],quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:85,boundedBy:["five_hour"],runway:{status:"through_reset"},selection:{spendPriority:1}}]}}]' \
  "$TMP_ROOT/original-quota" > "$QUOTA"
seat_quota 0 1 exhausted_now 0 > "$TMP_ROOT/claude2-quota.json"
jq '.rules[0].use += [{"harness":"pi","model":"openai-codex/gpt-6-luna","provider":"codex","reasoning_class":1}]' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' rule_1_1
run "$BRIEF" --task pager
assert_equals pi "$(jq -r .profile.harness "$(latest)")" 'another family candidate still outranks the reserve'
assert_contains "$out" 'eligible, reserve pick: every non-fallback claude seat is at its limit' 'the activated reserve stays disclosed when not chosen'
jq '.shared_quota = true | .rules[0].use = [{"harness":"claude","account":"geris","fallback_only":true,"reasoning_class":1}]' "$TMP_ROOT/original-rules" > "$RULES"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}' rule_1_1
run "$BRIEF" --task pager
assert_contains "$out" 'status: clear' 'a lone reserve under the shared-quota opt-out still resolves'
assert_not_contains "$out" '; ok' 'a reserve pick never leaks a placeholder reason'
assert_equals geris "$(jq -r .profile.account "$(latest)")" 'the shared-quota reserve launches on its declared account'
jq '.rules[0].use = [{"harness":"claude","model":"sonnet","account":"claude2","reasoning_class":1},{"harness":"claude","model":"haiku","account":"geris","fallback_only":"yes","reasoning_class":1}]' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
expect_code 2 "$code" 'a non-boolean fallback_only is a configuration error'
assert_contains "$out" 'fallback_only must be true or false when present' 'the fallback_only error is actionable'
rm "$HOME_DIR/config/accounts.json"
unset QUOTA_FIXTURE_MAP
cp "$TMP_ROOT/original-rules" "$RULES"
cp "$TMP_ROOT/original-quota" "$QUOTA"
pass 'fallback_only holds a claude reserve until every non-fallback claude seat is at its limit'
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
# Unusable permissions and invalid replies never become a guessed route:
# nothing is receipted and the captain picks from every row.
pick_code() { sed -n 's/^  pick: \([A-HJ-NP-Z2-9]\{4\}\) .*/\1/p' <<<"$out"; }
captain_mirror() {  # <text> [tag]
  jq -cn --arg text "$1" --arg tag "${2:-captain}" --argjson epoch "$(date +%s)" --argjson seq "$((++MIRROR_SEQ))" \
    '{seq:$seq,epoch:$epoch,key:"main-1",id:"p\($seq)",tag:$tag,text:$text}' >> "$MIRROR"
}
captain_lavish() {  # <text> [role] [epoch]
  local at
  at=$(date -u -d "@${3:-$(date +%s)}" +%Y-%m-%dT%H:%M:%S.123Z)
  [ -f "$FM_LAVISH_STATE" ] || printf '{"sessions":{"s1":{"chat":[]}}}\n' > "$FM_LAVISH_STATE"
  jq --arg text "$1" --arg role "${2:-user}" --arg at "$at" '.sessions.s1.chat += [{at:$at,role:$role,text:$text}]' "$FM_LAVISH_STATE" > "$FM_LAVISH_STATE.next"
  mv "$FM_LAVISH_STATE.next" "$FM_LAVISH_STATE"
}
MIRROR_SEQ=0
printf '{}\n' > "$RESPONSE"
requests_before=$(wc -l < "$LOG")
before=$(latest)
run "$BRIEF" --project pager --task pager
assert_contains "$out" 'status: captain-pick' "two invalid answers go to the captain: $out"
assert_contains "$out" 'receipt: none - nothing launches until the captain picks' 'no receipt, no guessed route'
assert_not_contains "$out" 'source: degraded' 'nothing is degraded'
assert_equals "$before" "$(latest)" 'invalid answers write no receipt'
assert_equals 2 "$(( $(wc -l < "$LOG") - requests_before ))" 'invalid answers get exactly two attempts'
chmod 666 "$SOCKET"
requests_before=$(wc -l < "$LOG")
run "$BRIEF" --task pager
assert_contains "$out" 'status: captain-pick' 'unsafe socket mode goes to the captain'
assert_equals "$requests_before" "$(wc -l < "$LOG")" 'unsafe socket never receives task text'
chmod 600 "$SOCKET"
run degraded-recent
expect_code 2 "$code" 'the degraded listing is retired'
pass 'invalid replies and unsafe socket modes fail closed into a captain pick'
# A restarting jevd gets a bounded wait for its socket before any attempt.
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true; SERVER=''
rm -f "$SOCKET"
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
( sleep 1; exec python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" ) &
SERVER=$!
FM_JEVD_SOCKET_WAIT_SECONDS=8 run "$BRIEF" --task pager
assert_contains "$out" 'source: jev' "a socket that returns within the wait routes through Jev: $out"
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true; SERVER=''
rm -f "$SOCKET"
pass 'a restarting jevd gets a bounded socket wait'
# Jev down: every row is offered, with evidence, and nothing launches.
before=$(latest)
run "$BRIEF" --project pager --task pager
assert_contains "$out" 'status: captain-pick' "Jev down goes to the captain: $out"
assert_contains "$out" 'jev: down - jevd socket' 'the reason names the absent socket'
assert_equals "$before" "$(latest)" 'Jev down writes no receipt'
code_a=$(pick_code)
req="$HOME_DIR/state/dispatch-pick/$code_a.json"
assert_present "$req" 'pick request written'
assert_equals 600 "$(stat -c %a "$req")" 'pick request private'
assert_equals 3 "$(jq '.options | length' "$req")" 'every row and candidate offered'
assert_equals 'rule_1 rule_2 default' "$(jq -r '[.options[].row.id] | join(" ")' "$req")" 'table order without Jev'
assert_equals null "$(jq -c .jev "$req")" 'no Jev answer recorded when Jev is down'
assert_contains "$out" 'option 2: --harness claude --model opus  class=2' 'options carry class'
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'nothing launches before the captain picks'
pass 'Jev down offers every row with evidence and writes no receipt'
# The pick needs the captain's own words, newer than the request.
run pick "$code_a"
expect_code 3 "$code" 'no words, no receipt'
assert_contains "$out" "no captain words answer route $code_a" 'missing answer named'
captain_lavish "route $code_a 2" user "$(( $(jq -r .issuedAtEpoch "$req") - 30 ))"
captain_lavish "route $code_a 2" agent
captain_mirror "route $code_a 2" main
run pick "$code_a"
expect_code 3 "$code" 'older captain text and firstmate text never count'
captain_mirror "please route ${code_a,,} 2"
before=$(latest)
run pick "$code_a"
expect_code 0 "$code" "captain chat answer admits the option: $out"
assert_contains "$out" 'source: captain' 'captain source shown'
assert_contains "$out" 'profile: --harness claude --model opus' 'the picked profile is printed'
receipt=$(latest)
[ "$receipt" != "$before" ] || fail 'pick wrote no receipt'
assert_equals captain "$(jq -r .source "$receipt")" 'receipt source'
assert_equals "$code_a 2 mirror false" "$(jq -r '"\(.captainPick.code) \(.captainPick.option) \(.captainPick.channel) \(.captainPick.override)"' "$receipt")" 'pick binding recorded'
assert_equals rule_2 "$(jq -r .row.id "$receipt")" 'row recorded'
run gate --brief "$BRIEF" --task pager --harness claude --model sonnet
expect_code 3 "$code" 'a different profile than the captain picked is refused'
cp "$receipt" "$TMP_ROOT/captain-receipt"
jq '.captainPick.option = 1' "$TMP_ROOT/captain-receipt" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'a receipt that no longer matches its answered option is refused'
cp "$TMP_ROOT/captain-receipt" "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model opus --consume
expect_code 0 "$code" "captain receipt admits its launch: $out"
assert_contains "$out" "captain pick $code_a option 2" 'gate names the pick'
run pick "$code_a"
expect_code 3 "$code" 'a pick is answered once'
assert_contains "$out" 'already answered' 'second answer refused'
pass 'captain words in chat become a receipt bound to the pick and its option'
# An option that is not eligible needs the word override, and says so.
jq '.rules[1].use.floor={scope:"all_models",min_percent:90}' "$TMP_ROOT/original-rules" > "$RULES"
run "$BRIEF" --task pager
code_b=$(pick_code)
assert_contains "$out" 'option 2: --harness claude --model opus' 'ineligible option still offered'
assert_contains "$out" 'not eligible: profile floor all_models below 90%' 'ineligibility reason shown'
captain_lavish "route $code_b 2"
run pick "$code_b"
expect_code 3 "$code" 'not eligible without override is refused'
assert_contains "$out" "route $code_b 2 override" 'the refusal names the override words'
captain_lavish "Ok then: route $code_b 2 override"
run pick "$code_b"
expect_code 0 "$code" "override answer on the card admits the option: $out"
assert_equals "lavish true" "$(jq -r '"\(.captainPick.channel) \(.captainPick.override)"' "$(latest)")" 'override recorded'
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 0 "$code" 'override receipt admits its launch'
cp "$TMP_ROOT/original-rules" "$RULES"
pass 'not-eligible options need the captain override words and record them'
# The captain can ask to choose even when Jev routes cleanly.
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.03,"default":0.02}'
python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" &
SERVER=$!
for ((i=0;i<100;i++)); do [ ! -S "$SOCKET" ] || break; sleep 0.02; done
before=$(latest)
run "$BRIEF" --task pager --captain-pick
assert_contains "$out" 'status: captain-pick' "captain-requested pick: $out"
assert_contains "$out" 'jev: captain-requested - the captain asked to choose this route; Jev and code would take claude sonnet from rule_1' 'the routed answer is shown beside the pick'
assert_equals "$before" "$(latest)" 'a captain-requested pick writes no Jev receipt'
assert_equals 'rule_1 rule_2 default' "$(jq -r '[.options[].row.id] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end) | join(" ")' "$HOME_DIR/state/dispatch-pick/$(pick_code).json")" 'rows in Jev probability order'
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true; SERVER=''
rm -f "$SOCKET"
pass 'the captain can ask to choose a route Jev would have taken'
# Ambiguous answers, reused evidence, changed briefs, and wait.
run "$BRIEF" --task pager
code_c=$(pick_code)
captain_mirror "route $code_c 1, or maybe route $code_c 3"
run pick "$code_c"
expect_code 3 "$code" 'two answers in one entry are refused'
assert_contains "$out" 'more than one answer' 'ambiguity named'
captain_mirror "route $code_c 1"
rm -rf "$HOME_DIR/state/dispatch-pick/used.keep"; cp -r "$HOME_DIR/state/dispatch-pick/used" "$HOME_DIR/state/dispatch-pick/used.keep"
printf '%s' "mirror:main-1:$MIRROR_SEQ" | sha256sum | awk '{print $1}' | xargs -I{} touch "$HOME_DIR/state/dispatch-pick/used/{}"
run pick "$code_c"
expect_code 3 "$code" 'evidence that admitted another pick is refused'
assert_contains "$out" 'already admitted another pick' 'single use named'
printf '\nAnother deliverable\n' >> "$BRIEF"
run pick "$code_c"
expect_code 3 "$code" 'a brief changed since the card is refused'
assert_contains "$out" 'changed since pick' 'brief change named'
run "$BRIEF" --task pager
code_d=$(pick_code)
captain_mirror "route $code_d wait"
before=$(latest)
run pick "$code_d"
expect_code 3 "$code" 'wait issues nothing'
assert_contains "$out" 'status: wait' 'wait recorded'
assert_equals "$before" "$(latest)" 'wait wrote no receipt'
pass 'ambiguous, reused, stale-brief and wait answers issue nothing'
# The card is self-contained and dark; picks lists pending and answered.
run "$BRIEF" --task pager
code_e=$(pick_code)
run pick-card
expect_code 0 "$code" "card renders: $out"
card="$HOME_DIR/data/dispatch-pick/route-pick.html"
assert_present "$card" 'card written'
assert_contains "$(<"$card")" "data-prompt=\"route $code_e 1\"" 'each option queues its exact words'
assert_contains "$(<"$card")" 'color-scheme:dark' 'card is dark'
assert_not_contains "$(<"$card")" 'http' 'card makes no external request'
assert_not_contains "$(<"$card")" "route $code_a" 'answered picks are not on the card'
run picks --recent
assert_contains "$out" "route pick $code_e PENDING" 'pending pick listed'
assert_contains "$out" "route pick $code_a task=pager answered" 'answered pick listed'
assert_contains "$out" 'wait for Jev' 'wait answer listed'
pass 'the card offers exact answers; pending and answered picks are listed'
# Legacy degraded receipts are refused at the gate.
cp "$TMP_ROOT/captain-receipt" "$receipt"
rm -f "$receipt.spent"
jq '.source = "degraded" | .degraded = {reason: "legacy"}' "$TMP_ROOT/captain-receipt" > "$receipt"
run gate --brief "$BRIEF" --task pager --harness claude --model opus
expect_code 3 "$code" 'a legacy degraded receipt is refused'
rm -f "$receipt"
# The audit matches Jev receipts to jevd's own log and captain receipts to their words.
rm -f "$FM_JEVD_AUDIT_LOG"
run audit --problems
assert_contains "$out" 'unverifiable: no jevd log readable' 'no log is reported as unverifiable, not as clean'
printf 'jevd: listening (mode 0600)\n' > "$FM_JEVD_AUDIT_LOG"
run audit --problems
assert_contains "$out" 'NOT IN JEVD LOG' 'a Jev receipt jevd never logged is flagged'
for f in "$HOME_DIR/state/dispatch-receipt"/dispatch-*.json; do
  jq -r 'select(.source == "jev") | "jevd: dispatch \(.jev.requestId): rule=\(.jev.ruleChoice) profile=x in=1"' "$f" >> "$FM_JEVD_AUDIT_LOG"
done
run audit --problems
assert_equals '' "$out" "every logged Jev receipt and every captain receipt audits clean: $out"
jev_receipt=$(grep -l '"source":"jev"' "$HOME_DIR/state/dispatch-receipt"/dispatch-*.json | tail -1)
jq '.jev.requestId = "forged-1"' "$jev_receipt" > "$jev_receipt.next"; mv "$jev_receipt.next" "$jev_receipt"
captain_receipt=$(grep -l '"source":"captain"' "$HOME_DIR/state/dispatch-receipt"/dispatch-*.json | head -1)
jq '.captainPick.wordsSha256 = ("0" * 64)' "$captain_receipt" > "$captain_receipt.next"; mv "$captain_receipt.next" "$captain_receipt"
run audit
assert_contains "$out" 'request id forged-1 has no jevd dispatch line' 'forged request id flagged'
assert_contains "$out" 'CAPTAIN WORDS: captain words differ' 'forged captain words flagged'
assert_contains "$out" '2 finding(s)' 'finding count'
pass 'audit reconciles Jev receipts with jevd log and captain receipts with their words'
# The criteria export carries every row's text, gates and classes.
run rows --json
expect_code 0 "$code" 'criteria export runs'
assert_equals 'rule_1 rule_2 default' "$(jq -r '[.rows[].id] | join(" ")' <<<"$out")" 'every row exported'
assert_equals '1 2 1' "$(jq -r '[.rows[].candidates[].reasoning_class] | join(" ")' <<<"$out")" 'classes exported'
assert_equals 0 "$(jq -r .unclassed <<<"$out")" 'no unclassed candidates'
assert_equals 64 "$(jq -r '.table.sha256 | length' <<<"$out")" 'table hash exported'
pass 'rows --json exports the routing criteria'
echo '# all fm-dispatch-resolve tests passed'
