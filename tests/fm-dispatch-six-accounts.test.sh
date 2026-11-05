#!/usr/bin/env bash
# Six-account routing guards (rr-synthesis plan, fork PRs A and B):
#   S1  every profile names a registered account once config/accounts.json exists
#   C2  a fallback_only reserve waits until every other seat of its provider is at limit,
#       and its own unknown quota never stalls the choice while it is held
#   S9  with cross-account routing off nothing falls onto the supervisor login
#   S3  a rule's never_providers bans a provider, also inside an ambiguous union
#   C3  an unreadable five-hour window is ignored, never incomplete
#   R11 a rate-limited read reuses that store's last good reading under 30 min
#   S4  a credential failure is named as such, never as unknown quota
#   T   seat_tier strict order, per-delivery tiers, and their reserve and class rules
#   U   an unreadable candidate is skipped while another is readable; none readable stays incomplete
#   P   pipeline mode: fixed row per step, pools, weekly floor, live five-hour window
#   A   provider-aware, symlink-canonical seat lookup and the one-shot migration
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-six-accounts)
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
ACCOUNTS="$HOME_DIR/config/accounts.json"
STORES="$TMP_ROOT/stores"
QDIR="$TMP_ROOT/quota"
SERVER=''
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
mkdir -p "$STORES"/claude1 "$STORES"/claude2 "$STORES"/claude3 "$STORES"/codex1 "$STORES"/pi "$QDIR"
printf '# Task\n## Captain%s intent\nFix the pager.\n## Firstmate spec\nOne page per call.\n' "'" > "$BRIEF"

# The fake quota-axi answers per store: the Claude store's name, else the Codex
# store's, else "pi" for the shared Pi agent directory.
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
key=default
case "${CLAUDE_CONFIG_DIR:-}" in /nonexistent/*|'') ;; *) key=$(basename "$CLAUDE_CONFIG_DIR") ;; esac
if [ "$key" = default ]; then
  case "${CODEX_HOME:-}" in /nonexistent/*|'') ;; *) key=$(basename "$CODEX_HOME") ;; esac
fi
if [ "$key" = default ]; then
  case "${PI_CODING_AGENT_DIR:-}" in /nonexistent/*|'') ;; *) key=pi ;; esac
fi
[ -f "$QUOTA_DIR/$key.json" ] || key=empty
cat "$QUOTA_DIR/$key.json"
SH
chmod +x "$FAKEBIN/quota-axi"
printf '{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[]}\n' > "$QDIR/empty.json"

# snap <provider> <pct-remaining> <spendPriority> [runway] [weekly-reset]
snap() {
  local runway=${4:-through_reset} reset=${5:-2030-01-04T00:00:00Z}
  jq -n --arg p "$1" --argjson pct "$2" --argjson sp "$3" --arg runway "$runway" --arg reset "$reset" '
    {schemaVersion:5, generatedAt:"2030-01-01T00:00:00Z", providers:[{provider:$p, plan:"plan", state:{status:"fresh"},
      windows:[{id:"five_hour",kind:"session",percentRemaining:90,resetsAt:"2030-01-02T00:00:00Z"},
               {id:"seven_day",kind:"weekly",percentRemaining:$pct,resetsAt:$reset}],
      quotaSemantics:{status:"known", effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:$pct,
        boundedBy:["five_hour","seven_day"],runway:{status:$runway},selection:{spendPriority:$sp}}]}}]}'
}
set_quota() { snap "$2" "$3" "$4" "${5:-through_reset}" "${6:-2030-01-04T00:00:00Z}" > "$QDIR/$1.json"; }
reset_quota() {
  set_quota claude1 claude 70 1
  set_quota claude2 claude 60 2
  set_quota claude3 claude 95 9
  set_quota codex1 codex 50 1
  set_quota pi zai 90 5
  rm -rf "$HOME_DIR/state/quota-last-good"
}
reset_quota

cat > "$ACCOUNTS" <<JSON
{"crossAccount":{"enabled":true},"accounts":{
 "claude1":{"provider":"claude","claude":"$STORES/claude1","plans":{"claude":"Max 20x"}},
 "claude2":{"provider":"claude","claude":"$STORES/claude2","plans":{"claude":"Ultra"}},
 "claude3":{"provider":"claude","claude":"$STORES/claude3","plans":{"claude":"Team premium"}},
 "codex1":{"provider":"codex","codex":"$STORES/codex1","pi":"$STORES/pi","plans":{"codex":"Pro 5x"}},
 "glm":{"provider":"zai","pi":"$STORES/pi","plans":{"zai":"Pro 6x"}}}}
JSON
cat > "$RULES" <<'JSON'
{"model_notes":{"claude":"claude line","codex":"codex line","zai":"glm line"},
 "rules":[
  {"when":"Writing and reporting","use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","reasoning_class":2},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","reasoning_class":2},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude3","fallback_only":true,"reasoning_class":2},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","reasoning_class":2}]},
  {"when":"Front-end design","never_providers":["zai"],"use":[
    {"harness":"claude","model":"opus","effort":"high","account":"claude1","reasoning_class":2},
    {"harness":"claude","model":"opus","effort":"high","account":"claude2","reasoning_class":2}]},
  {"when":"Read-only investigation","use":[
    {"harness":"claude","model":"haiku","effort":"low","account":"claude1","reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude2","reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude3","fallback_only":true,"reasoning_class":1}]}],
 "default":[
  {"harness":"claude","model":"opus","effort":"medium","account":"claude1","reasoning_class":2},
  {"harness":"claude","model":"opus","effort":"medium","account":"claude2","reasoning_class":2}]}
JSON
cp "$RULES" "$TMP_ROOT/rules-original"

export PATH="$FAKEBIN:$PATH" QUOTA_DIR="$QDIR"
unset FM_QUOTA_INTAKE_TEST_BYPASS
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_JEVD_SOCKET="$SOCKET"
export FM_DISPATCH_QUOTA_ATTEMPTS=1 FM_DISPATCH_QUOTA_BACKOFF_MS=250 FM_DISPATCH_QUOTA_WAIT_SECONDS=1
# The supervisor's own login is the home pin store, as on a real home.
export CLAUDE_CONFIG_DIR="$STORES/claude3" PI_CODING_AGENT_DIR="$STORES/pi" CODEX_HOME="$STORES/codex1"
write_response() {
  jq -n --slurpfile rules "$RULES" --arg choice "$1" --argjson confidence "$2" --argjson probabilities "$3" '
    def profiles: if type == "array" then . else [.] end;
    (([$rules[0].rules // [] | to_entries[] | .key as $r | .value.use | profiles | to_entries[] | "rule_\($r + 1)_\(.key + 1)"] +
      [($rules[0].default // [] | profiles) | to_entries[] | "default_\(.key + 1)"])) as $ids |
    {model:"typesafe/jev-1.13",answers:{rule:{choice:$choice,confidence:$confidence,probabilities:$probabilities},
      profile:{choice:$ids[0],confidence:1,probabilities:($ids | map({key:.,value:(if . == $ids[0] then 1 else 0 end)}) | from_entries)}},usage:{input_tokens:10,output_tokens:4}}' > "$RESPONSE"
}
run() { code=0; out=$("$TOOL" "$@" 2>&1) || code=$?; }
latest() { find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' | sort | tail -1; }
chosen() { printf '%s\n' "$out" | sed -n 's/^  profile: //p'; }
python3 "$ROOT/tests/jevd-dispatch-stub.py" "$SOCKET" "$RESPONSE" "$LOG" &
SERVER=$!
for ((i=0;i<100;i++)); do [ ! -S "$SOCKET" ] || break; sleep 0.02; done
[ -S "$SOCKET" ] || fail 'stub did not start'

# ---- S1 -----------------------------------------------------------------------
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
jq 'del(.rules[2].use[0].account)' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" "a profile without an account is a configuration error: $out"
assert_contains "$out" 'rule 3 profile claude:haiku/low names no account' 'the missing account is named'
jq '.rules[2].use[0].account = "nobody"' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
assert_contains "$out" 'names unregistered account nobody' 'an unregistered account is named'
jq '.rules[0].use[3].account = "codex1"' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
assert_contains "$out" 'spends provider zai but account codex1 declares provider codex' 'a provider mismatch is named'
jq '.rules[2].use[0].account = "glm"' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
assert_contains "$out" 'runs on claude but account glm owns no claude store' 'a store the seat lacks is named'
# The libraries run in a child shell, so their locals never shadow this file's.
acct() { bash -c '. "$0"; "$@"' "$ROOT/bin/fm-account-lib.sh" "$@"; }
qlib() { bash -c '. "$0"; "$@"' "$ROOT/bin/fm-quota-axi-lib.sh" "$@"; }
assert_contains "$(acct fm_account_dispatch_problems "$ACCOUNTS" "$RULES")" 'owns no claude store' 'bootstrap shares the same check'
assert_equals '' "$(acct fm_account_dispatch_problems "$ACCOUNTS" "$TMP_ROOT/rules-original")" 'the six-account table is clean'
assert_equals '' "$(acct fm_account_dispatch_problems "$TMP_ROOT/absent.json" "$RULES")" 'a home without a registry is unchanged'
cp "$TMP_ROOT/rules-original" "$RULES"
pass 'S1: every profile names a registered account that owns its store and serves its provider'

# ---- C2 / S9 --------------------------------------------------------------------
reset_quota
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "investigation routes: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the higher spendPriority worker seat wins'
assert_contains "$out" 'not eligible: fallback_only reserve held: non-fallback claude seats not at their limit (claude:haiku@claude1, claude:haiku@claude2)' 'claude3 is held while the worker seats have room'
set_quota claude1 claude 70 1 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" 'one worker seat at limit is not enough'
assert_contains "$out" 'fallback_only reserve held: non-fallback claude seats not at their limit (claude:haiku@claude2)' 'only the seat with room is named'
set_quota claude2 claude 0 2
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude3'" "claude3 is picked when both worker seats are at limit: $out"
assert_contains "$out" 'reserve pick: every non-fallback claude seat is at its limit' 'the reserve pick is visible'
"$ROOT/bin/fm-account-routing.sh" off >/dev/null
run "$BRIEF" --task six
assert_contains "$out" 'status: captain-pick' 'routing off goes to the captain with a reason, no guessed route'
assert_contains "$out" 'cross-account routing disabled or account not registered' 'the reason is named'
assert_not_contains "$(chosen)" 'claude3' 'routing off never concentrates work on claude3'
"$ROOT/bin/fm-account-routing.sh" on >/dev/null
reset_quota
reset_quota
jq '.providers[0] |= (.state = {status:"rate_limited", error:"Claude quota endpoint rate limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude3.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude3.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a held reserve with unknown quota does not stall the choice: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the worker seats still decide'
reset_quota
pass 'C2 and S9: the claude3 reserve opens only when claude1 and claude2 are both at limit, never with routing off, and never stalls while held'

# ---- T: seat tiers ---------------------------------------------------------------
# The worker order: claude1, claude2, claude3 reserve, then other families. A
# stronger or better-funded candidate of a later tier never wins while an
# earlier seat has capacity.
cat > "$RULES" <<'JSON'
{"model_notes":{"claude":"claude line","codex":"codex line","zai":"glm line"},
 "seat_tiers_by_delivery":{"no-mistakes":{"claude2":1,"claude1":2,"claude3":3}},
 "rules":[
  {"when":"Multi-file implementation","use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","seat_tier":2,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude3","seat_tier":3,"fallback_only":true,"reasoning_class":4},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6.1-sol","effort":"xhigh","account":"codex1","seat_tier":4,"reasoning_class":5},
    {"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","seat_tier":4,"reasoning_class":3}]},
  {"when":"Orchestration","use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude3","seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","seat_tier":2,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","seat_tier":3,"reasoning_class":3}]},
  {"when":"Read-only investigation","use":[
    {"harness":"claude","model":"haiku","effort":"low","account":"claude1","seat_tier":1,"reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude2","seat_tier":2,"reasoning_class":1},
    {"harness":"claude","model":"haiku","effort":"low","account":"claude3","seat_tier":3,"fallback_only":true,"reasoning_class":1},
    {"harness":"pi","provider":"codex","model":"openai-codex/gpt-6-luna","effort":"xhigh","account":"codex1","seat_tier":4,"reasoning_class":5}]}]}
JSON
reset_quota
worker='{"rule_1":0.95,"rule_2":0.02,"rule_3":0.02,"default":0.01}'
write_response rule_1 0.95 "$worker"
run "$BRIEF" --task six
assert_contains "$(chosen)" "--model 'opus'" "keep-strongest decides inside the open tier: $out"
assert_contains "$(chosen)" "--account 'claude1'" 'the first tier wins although claude2 has the higher spendPriority'
assert_contains "$out" 'not eligible: seat_tier held: an earlier seat still has capacity (claude:sonnet@claude1, claude:opus@claude1)' 'a held candidate names the open tier'
assert_not_contains "$(tail -1 "$LOG")" 'seat_tier' 'Jev never sees a seat tier'
set_quota claude3 claude 95 9
jq '.providers[0] |= (.state = {status:"rate_limited", error:"limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a held later tier with unknown quota does not stall the choice: $out"
assert_contains "$(chosen)" "--account 'claude1'" 'the open tier still decides'
# ---- U: an unreadable seat never blocks a readable one ---------------------------
unreadable() { jq '.providers[0] |= (.state = {status:"rate_limited", error:"limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/$1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/$1.json"; }
reset_quota
unreadable claude1
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "an unreadable first seat does not stop the dispatch: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the next readable seat is chosen'
assert_contains "$out" 'not eligible: quota unreadable, skipped: provider claude unmeasured' 'the unreadable seat is marked on its line'
assert_contains "$out" 'windows_missing=' 'the skipped seat still names what is missing'
assert_contains "$out" 'seat_tier held: an earlier seat still has capacity (claude:opus@claude2)' 'only a readable seat holds the later tiers'
assert_contains "$(jq -r .rationale "$(latest)")" 'quota unreadable, skipped: claude:sonnet@claude1, claude:opus@claude1' 'the receipt names the skipped seats'
# Inside one tier the readable seat wins although the unreadable one comes first.
cp "$RULES" "$TMP_ROOT/tier-rules"
jq '(.rules[0].use[] | select(.account == "claude2")).seat_tier = 1' "$TMP_ROOT/tier-rules" > "$RULES"
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "a readable seat of the same tier is chosen: $out"
cp "$TMP_ROOT/tier-rules" "$RULES"
# An unreadable seat is no capacity for a reserve to protect.
set_quota claude2 claude 0 2 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude3'" "the reserve opens past an unreadable and a full seat: $out"
assert_contains "$out" 'seat is at its limit (weekly window at or above 100% used or runway exhausted_now) or unreadable' 'the reserve says why it opened'
# So is an expired login.
reset_quota
jq '.providers[0] |= (.state = {status:"auth_required", error:"claude_credential_unavailable"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude1.json"
set_quota claude2 claude 0 2 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude3'" "the reserve opens past an expired login and a full seat: $out"
# A later unreadable tier stays held, and nothing readable stays incomplete.
reset_quota
unreadable claude1
unreadable claude3
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "the open tier decides: $out"
assert_contains "$out" 'fallback_only reserve held' 'a later unreadable reserve stays held'
reset_quota
for seat in claude1 claude2 claude3 codex1 pi; do unreadable "$seat"; done
run "$BRIEF" --task six
assert_contains "$out" 'status: captain-pick' "nothing readable still goes to the captain: $out"
assert_contains "$out" 'jev: incomplete' 'the pick names the incomplete evidence'
assert_contains "$out" '-> incomplete: provider claude unmeasured' 'every seat stays listed as unmeasured'
assert_contains "$out" 'receipt: none' 'nothing launches'
assert_not_contains "$out" 'seat_tier held' 'no unreadable tier hides a later one from the gather'
# A skipped pool with a named warm-up still gets it once, and can join the choice.
cat > "$FAKEBIN/zai-window-warm" <<SH
#!/usr/bin/env bash
printf 'warm\n' >> "$TMP_ROOT/warm-calls"
cp "$TMP_ROOT/pi-warm.json" "$QDIR/pi.json"
SH
chmod +x "$FAKEBIN/zai-window-warm"
cp "$RULES" "$TMP_ROOT/tier-rules"
cp "$TMP_ROOT/rules-original" "$RULES"
write_response rule_1 0.95 "$worker"
reset_quota
cp "$QDIR/pi.json" "$TMP_ROOT/pi-warm.json"
unreadable pi
FM_DISPATCH_QUOTA_ATTEMPTS=1 run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "the attempt bound stops the warm-up, not the dispatch: $out"
[ ! -e "$TMP_ROOT/warm-calls" ] || fail 'the warm-up ran past the attempt bound'
FM_DISPATCH_QUOTA_ATTEMPTS=3 run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'glm'" "the warmed pool joins this choice: $out"
assert_equals 1 "$(wc -l < "$TMP_ROOT/warm-calls" | tr -d ' ')" 'the warm-up runs exactly once'
rm -f "$FAKEBIN/zai-window-warm"
reset_quota
unreadable pi
FM_DISPATCH_QUOTA_ATTEMPTS=3 run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "an absent warm-up never stalls the choice: $out"
cp "$TMP_ROOT/tier-rules" "$RULES"
write_response rule_1 0.95 "$worker"
pass 'U: an unreadable candidate is skipped while another is readable; none readable stays incomplete'
reset_quota
set_quota claude1 claude 0 1 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" "claude2 is the first fallback: $out"
set_quota claude2 claude 0 2 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude3'" "claude3 comes before another family, unlike a tierless reserve: $out"
assert_contains "$out" 'reserve pick: every non-fallback claude seat is at its limit' 'the reserve decision stays visible'
set_quota claude3 claude 0 9 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--harness 'pi'" "another family is the last fallback: $out"
assert_contains "$(chosen)" "--model 'openai-codex/gpt-6.1-sol'" 'keep-strongest and spendPriority still decide inside a shared tier'
reset_quota
# Delivery tiers change the order for a no-mistakes ship and nothing else.
{ cat "$BRIEF"; printf '\n# Definition of done\nDelivery contract: mode=no-mistakes\n'; } > "$TMP_ROOT/nm-brief.md"
{ cat "$BRIEF"; printf '\n# Definition of done\nDelivery contract: mode=direct-PR\n'; } > "$TMP_ROOT/pr-brief.md"
run "$TMP_ROOT/nm-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude2'" "a no-mistakes ship defaults to claude2: $out"
assert_not_contains "$(tail -1 "$LOG")" 'no-mistakes' 'Jev never sees the delivery mode'
run "$TMP_ROOT/pr-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude1'" 'a direct-PR ship keeps the worker order'
set_quota claude2 claude 0 2 exhausted_now
run "$TMP_ROOT/nm-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude1'" "a no-mistakes ship falls back to claude1: $out"
set_quota claude1 claude 0 1 exhausted_now
run "$TMP_ROOT/nm-brief.md" --task six
assert_contains "$(chosen)" "--account 'claude3'" "and then to the claude3 reserve: $out"
reset_quota
# The orchestration row defaults to the supervisor seat, then the worker seats.
write_response rule_2 0.95 '{"rule_1":0.02,"rule_2":0.95,"rule_3":0.02,"default":0.01}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude3'" "orchestration defaults to claude3: $out"
set_quota claude3 claude 0 9 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude1'" 'orchestration falls back to claude1'
set_quota claude1 claude 0 1 exhausted_now
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude2'" 'and then to claude2'
reset_quota
# A stronger later tier does not outbid the default seat, also in an ambiguous union.
write_response rule_3 0.95 '{"rule_1":0.02,"rule_2":0.02,"rule_3":0.95,"default":0.01}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude1'" "a class-5 fallback does not outbid the class-1 default seat: $out"
jq '.default = [.rules[2].use[]]' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_3 0.4 '{"rule_1":0.3,"rule_2":0.05,"rule_3":0.4,"default":0.25}'
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "an ambiguous union clears: $out"
assert_contains "$(chosen)" "--model 'haiku'" 'the union takes its class from the anchor row first tier'
assert_contains "$(chosen)" "--account 'claude1'" 'and keeps the seat order'
# Under the shared-quota opt-out the declared tiers still order the row.
jq '.shared_quota = true | del(.default)' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
jq '.rules[0].use |= reverse' "$RULES" > "$TMP_ROOT/rules-next"; mv "$TMP_ROOT/rules-next" "$RULES"
write_response rule_1 0.95 "$worker"
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'claude1'" "shared quota honors the tier over declared order: $out"
# Malformed declarations are configuration errors.
jq '.rules[0].use[0].seat_tier = 0' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a non-positive seat_tier is a configuration error'
assert_contains "$out" 'seat_tier must be a positive integer' 'the seat_tier error is actionable'
jq '.default[0].seat_tier = 1.5' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a fractional default seat_tier is a configuration error'
jq '.seat_tiers_by_delivery = {"no-mistakes":{"claude2":"first"}}' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a malformed delivery tier is a configuration error'
assert_contains "$out" 'seat_tiers_by_delivery must map' 'the delivery tier error is actionable'
cp "$TMP_ROOT/rules-original" "$RULES"
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
pass 'T: seat tiers hold later candidates, follow per-delivery tiers, and keep the reserve and class rules'

# ---- S3 -------------------------------------------------------------------------
write_response rule_1 0.95 '{"rule_1":0.95,"rule_2":0.02,"rule_3":0.01,"default":0.02}'
run "$BRIEF" --task six
assert_contains "$(chosen)" "--account 'glm'" "glm wins writing on spendPriority where it is allowed: $out"
write_response rule_1 0.4 '{"rule_1":0.4,"rule_2":0.35,"rule_3":0,"default":0.25}'
run "$BRIEF" --task six
assert_contains "$out" 'ambiguous union >= 0.25' "an ambiguous design-adjacent task unions: $out"
assert_contains "$out" 'provider zai is banned for this work (never_providers)' 'glm is banned in the union'
assert_not_contains "$(chosen)" 'glm' 'glm never runs design-adjacent work'
jq '.rules[1].use += [{"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","reasoning_class":2}]' "$TMP_ROOT/rules-original" > "$RULES"
run "$BRIEF" --task six
expect_code 2 "$code" 'a banned provider listed on its own rule is a configuration error'
assert_contains "$out" 'a rule lists a profile of a provider its own never_providers bans: rule 2 pi:zai/glm-5.3' 'the offending profile is named'
cp "$TMP_ROOT/rules-original" "$RULES"
pass 'S3: never_providers bans a provider in code, including inside an ambiguous union'

# ---- C3 / R11 / S4 --------------------------------------------------------------
write_response rule_3 0.95 '{"rule_1":0.01,"rule_2":0.02,"rule_3":0.95,"default":0.02}'
reset_quota
jq '.providers[0].windows[0] |= del(.resetsAt, .percentRemaining)' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "an unreadable five-hour window does not make the choice incomplete: $out"
assert_contains "$(chosen)" "--account 'claude2'" 'the seat with the unreadable five-hour window still ranks'
reset_quota
run "$BRIEF" --task six
jq '.providers[0] |= (.state = {status:"rate_limited", error:"Claude quota endpoint rate limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a rate-limited read with a recent reading keeps the decision going: $out"
assert_contains "$out" 'reading_age=' 'the reused reading states its age'
assert_contains "$(chosen)" "--account 'claude2'" 'the recent reading still ranks claude2'
for cache in "$HOME_DIR"/state/quota-last-good/resolve*.json; do
  jq '.rows |= map_values(.at -= 4000)' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
done
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a reading older than 30 minutes only takes that seat out: $out"
assert_contains "$(chosen)" "--account 'claude1'" 'the readable seat takes the choice'
assert_contains "$out" 'not eligible: quota unreadable, skipped: provider claude unmeasured' 'the expired reading is marked on its line'
reset_quota
jq '.providers[0] |= (.state = {status:"auth_required", error:"claude_credential_unavailable"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$QDIR/claude2.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/claude2.json"
run "$BRIEF" --task six
assert_contains "$out" 'status: clear' "a credential failure does not stall the other seats: $out"
assert_contains "$out" 'credential unusable for provider claude on account claude2' 'the credential failure is named as such'
assert_contains "$(chosen)" "--account 'claude1'" 'the remaining worker seat runs the work'
reset_quota
pass 'C3, R11 and S4: unreadable five-hour windows are ignored, recent readings reused under 30 minutes, credential failures named'

# ---- P: pipeline seat rows -------------------------------------------------------
# The fixed row per no-mistakes step: pool 1 is claude1 and claude2, pool 2 is
# claude3 above its weekly floor and then the Codex seats. A healthy glm seat with
# the most room stays out, because no row may list a banned provider.
mkdir -p "$STORES/codex2"
cp "$ACCOUNTS" "$TMP_ROOT/accounts-original"
jq --arg store "$STORES" '.accounts.codex2 = {provider:"codex",codex:"\($store)/codex2",pi:"\($store)/pi",plans:{codex:"Business"}}' "$TMP_ROOT/accounts-original" > "$ACCOUNTS"
cat > "$RULES" <<'JSON'
{"rules":[{"when":"Any work","use":[
   {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","reasoning_class":3}]}],
 "pipeline_rows":[
  {"steps":["review","test","ci","rebase","fixes"],"never_providers":["zai"],"use":[
    {"harness":"claude","model":"opus","effort":"medium","account":"claude1","pool":1,"seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude2","pool":1,"seat_tier":1,"reasoning_class":4},
    {"harness":"claude","model":"opus","effort":"medium","account":"claude3","pool":2,"seat_tier":2,"reasoning_class":4,"weekly_floor_percent":20},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"medium","account":"codex1","pool":2,"seat_tier":3,"reasoning_class":4},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"medium","account":"codex2","pool":2,"seat_tier":3,"reasoning_class":4}]},
  {"steps":["document","pr"],"never_providers":["zai"],"use":[
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude1","pool":1,"seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude2","pool":1,"seat_tier":1,"reasoning_class":3},
    {"harness":"claude","model":"sonnet","effort":"high","account":"claude3","pool":2,"seat_tier":2,"reasoning_class":3,"weekly_floor_percent":20},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"low","account":"codex1","pool":2,"seat_tier":3,"reasoning_class":3},
    {"harness":"codex","model":"gpt-6.1-sol","effort":"low","account":"codex2","pool":2,"seat_tier":3,"reasoning_class":3}]}]}
JSON
cp "$RULES" "$TMP_ROOT/rules-pipeline"
pipeline_quota() {
  reset_quota
  set_quota claude1 claude 70 1.3
  set_quota claude2 claude 60 1.2
  set_quota claude3 claude 80 0.2
  set_quota codex1 codex 90 0.8
  set_quota codex2 codex 90 0.7
}
# tweak <key> <jq filter over the provider's single row and windows>
tweak() { jq ".providers[0] |= ($2)" "$QDIR/$1.json" > "$QDIR/next" && mv "$QDIR/next" "$QDIR/$1.json"; }
# A live five-hour window: projected out of room in <seconds>, row bound by five_hour.
short_seat() { tweak "$1" ".quotaSemantics.effectiveAvailability[0].runway = {status:\"projected_exhaustion\",usableRunwaySeconds:$2,limitingWindowId:\"five_hour\"}"; }
# The five-hour window is empty, the weekly window still has room.
five_hour_out() { tweak "$1" ".windows[0].percentRemaining = 0 | .windows[0].resetsAt = \"$2\" | .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 0 | .quotaSemantics.effectiveAvailability[0].runway = {status:\"exhausted_now\",limitingWindowId:\"five_hour\"}"; }
rate_limited() { tweak "$1" '.state = {status:"rate_limited", error:"quota endpoint rate limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]}'; }
# One attempt means no retry wait; the bound must still outlast five reads on a slow host.
pipe() { code=0; pout=$(FM_DISPATCH_QUOTA_WAIT_SECONDS=30 "$TOOL" pipeline --step "$1" 2>"$TMP_ROOT/pipe-err") || code=$?; perr=$(cat "$TMP_ROOT/pipe-err"); }
pfield() { jq -r "$1" <<<"$pout"; }
receipts() { find "$HOME_DIR/state/dispatch-receipt" -name 'dispatch-*.json' 2>/dev/null | wc -l | tr -d ' '; }

pipeline_quota
before_requests=$(wc -l < "$LOG"); before_receipts=$(receipts)
pipe review
expect_code 0 "$code" "a pipeline step resolves: $pout $perr"
assert_equals 'ok claude1 claude opus medium 1' "$(pfield '"\(.status) \(.seat) \(.harness) \(.model) \(.effort) \(.pool)"')" 'pool 1 best spendPriority wins with its row profile'
assert_contains "$(pfield .reason)" 'pool 1 tier 1' 'the reason names the pool'
assert_equals '5' "$(pfield '.candidates | length')" 'every seat of the row is reported'
assert_equals "$before_requests" "$(wc -l < "$LOG")" 'pipeline mode makes no model call'
assert_equals "$before_receipts" "$(receipts)" 'pipeline mode writes no receipt'
pipe document
assert_equals 'claude1 sonnet high 3' "$(pfield '"\(.seat) \(.model) \(.effort) \(.reasoning_class)"')" 'each step takes its own row'
write_response rule_1 0.95 '{"rule_1":0.95,"default":0.05}'
run "$BRIEF" --task six-p
assert_not_contains "$(tail -1 "$LOG")" 'gpt-6.1-sol' 'worker requests never show the pipeline rows to Jev'
assert_contains "$out" "--account 'claude1'" 'worker resolution ignores the pipeline rows'
pass 'P: a step resolves from its fixed row with no model call and no receipt'

# Tie-break: the shared rule, soonest reset and then the round-robin.
pipeline_quota
set_quota claude1 claude 70 1.3 through_reset 2030-01-05T00:00:00Z
set_quota claude2 claude 70 1.3 through_reset 2030-01-03T00:00:00Z
tweak claude1 '.quotaSemantics.effectiveAvailability[0].boundedBy = ["seven_day"]'
tweak claude2 '.quotaSemantics.effectiveAvailability[0].boundedBy = ["seven_day"]'
pipe review
assert_equals claude2 "$(pfield .seat)" 'an exact tie goes to the sooner binding reset'
assert_contains "$(pfield .tie_break)" 'sooner binding reset' 'the tie-break is logged'
set_quota claude1 claude 70 1.3
set_quota claude2 claude 70 1.3
pipe review; first_tied=$(pfield .seat)
pipe review; second_tied=$(pfield .seat)
assert_not_contains "$first_tied" "$second_tied" 'a full tie rotates between the seats'
pass 'P: ties use the shared reset and round-robin rule'

# Five-hour window: counts for the pipeline, never opens pool 2 while a seat has room.
pipeline_quota
set_quota claude2 claude 60 5
pipe review
assert_equals claude2 "$(pfield .seat)" 'divergence check: claude2 outranks claude1 on spendPriority'
short_seat claude2 3808
pipe review
assert_equals claude1 "$(pfield .seat)" 'a seat that will not last to reset loses to one that does'
assert_contains "$(pfield .reason)" 'claude2 will not last to reset' 'the reason names the seat that lost'
pipeline_quota
set_quota claude2 claude 60 5
short_seat claude2 5400
pipe review
assert_equals claude2 "$(pfield .seat)" 'a runway of 90 minutes is not short'
pipeline_quota
set_quota claude2 claude 60 5
short_seat claude2 3808
tweak claude2 'del(.windows[0].resetsAt)'
pipe review
assert_equals claude2 "$(pfield .seat)" 'an idle five-hour window with no reset stays noise'
pipeline_quota
short_seat claude1 600
short_seat claude2 700
pipe review
assert_equals '1 claude1' "$(pfield '"\(.pool) \(.seat)"')" 'short runways alone keep pool 1, ranked as usual'
assert_contains "$(pfield .reason)" 'no open seat lasts to reset' 'that is stated'
pass 'P: a live five-hour window decides inside a tier and does not open pool 2'

# Pool 2 opens only when pool 1 has no room, and claude3 comes first inside it.
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
pipe review
assert_equals '1 claude2' "$(pfield '"\(.pool) \(.seat)"')" 'one pool 1 seat with room keeps pool 1'
five_hour_out claude2 2030-01-01T06:00:00Z
pipe review
assert_equals '2 claude3 opus medium' "$(pfield '"\(.pool) \(.seat) \(.model) \(.effort)"')" 'claude3 above its floor beats Codex despite a lower spendPriority'
assert_contains "$(pfield .reason)" 'pool 1 has no seat with room' 'opening pool 2 is stated'
pass 'P: pool 2 opens on an empty pool 1, even on five-hour limits, claude3 first'

# The claude3 weekly floor: weekly room decides, and a low five-hour row does not trip it.
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
set_quota claude3 claude 21 0.2
pipe review
assert_equals claude3 "$(pfield .seat)" 'above the floor claude3 still runs'
set_quota claude3 claude 20 0.2
pipe review
assert_equals '2 codex1 codex gpt-6.1-sol medium' "$(pfield '"\(.pool) \(.seat) \(.harness) \(.model) \(.effort)"')" 'at the floor claude3 stops and Codex runs at the class effort'
assert_contains "$(pfield '.candidates[] | select(.seat == "claude3") | .reason')" 'weekly floor: 20% left, stops at 20%' 'the floor stop is named'
set_quota claude3 claude 80 0.2
tweak claude3 '.windows[0].percentRemaining = 15 | .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 15'
pipe review
assert_equals claude3 "$(pfield .seat)" 'a low five-hour row never trips the weekly floor'
set_quota claude3 claude 20 0.2
pipe document
assert_equals 'codex1 low 3' "$(pfield '"\(.seat) \(.effort) \(.reasoning_class)"')" 'Codex takes the step class of its row'
pass 'P: claude3 stops at its weekly floor, on the weekly window only'

# Both pools empty: one line per seat with its reset, no downgrade, no GLM.
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
set_quota claude3 claude 10 0.2 through_reset 2030-01-07T00:00:00Z
set_quota codex1 codex 0 0.8 through_reset 2030-01-08T00:00:00Z
set_quota codex2 codex 0 0.7 through_reset 2030-01-09T00:00:00Z
pipe review
expect_code 3 "$code" "both pools empty exits 3: $pout"
assert_equals 'exhausted' "$(pfield .status)" 'the outcome is exhausted'
assert_equals 'null' "$(pfield '.seat // null')" 'no seat is named as chosen'
assert_contains "$(pfield .reason)" 'quota exhausted' 'the outcome uses the recognised limit text'
assert_equals '5' "$(printf '%s\n' "$perr" | wc -l | tr -d ' ')" "one line per seat: $perr"
assert_contains "$perr" 'claude1 (pool 1) has no room, resets 2030-01-01T05:00:00Z' 'a five-hour seat names its five-hour reset'
assert_contains "$perr" 'claude2 (pool 1) has no room, resets 2030-01-01T06:00:00Z' 'each seat names its own reset'
assert_contains "$perr" 'claude3 (pool 2) has no room, resets 2030-01-07T00:00:00Z: weekly floor: 10% left' 'a floored seat names its weekly reset'
assert_contains "$perr" 'codex1 (pool 2) has no room, resets 2030-01-08T00:00:00Z' 'a Codex seat names its reset'
assert_contains "$perr" 'codex2 (pool 2) has no room, resets 2030-01-09T00:00:00Z' 'every Codex seat is listed'
assert_not_contains "$pout$perr" 'glm' 'no GLM seat is offered'
pass 'P: both pools empty fail with one line per seat and its reset, and no GLM'

# Unreadable quota waits within its bound and never opens the next pool.
pipeline_quota
rate_limited claude2
pipe review
assert_equals 'claude1 true' "$(pfield '"\(.seat) \(.measured)"')" 'a measured seat of the open tier wins over an unreadable one'
pipeline_quota
rate_limited claude1
rate_limited claude2
pipe review
expect_code 0 "$code" "both unreadable still resolve: $perr"
assert_equals '1 claude1 false' "$(pfield '"\(.pool) \(.seat) \(.measured)"')" 'both unreadable: the first seat of the tier, marked unmeasured, pool 2 stays shut'
assert_contains "$(pfield .reason)" 'quota unreadable' 'the reason says so'
pipeline_quota
five_hour_out claude1 2030-01-01T05:00:00Z
five_hour_out claude2 2030-01-01T06:00:00Z
rate_limited claude3
pipe review
assert_equals 'codex1' "$(pfield .seat)" 'an unreadable weekly floor never lets claude3 fail open'
assert_contains "$(pfield '.candidates[] | select(.seat == "claude3") | .reason')" 'weekly floor 20% is unverifiable' 'that is named'
pipeline_quota
cat > "$FAKEBIN/quota-axi-hung" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
chmod +x "$FAKEBIN/quota-axi-hung"
cp "$FAKEBIN/quota-axi" "$FAKEBIN/quota-axi-real"
cp "$FAKEBIN/quota-axi-hung" "$FAKEBIN/quota-axi"
started=$(date +%s)
code=0; pout=$(FM_DISPATCH_QUOTA_WAIT_SECONDS=900 FM_DISPATCH_QUOTA_ATTEMPTS=1000 "$TOOL" pipeline --step review 2>/dev/null) || code=$?
elapsed=$(( $(date +%s) - started ))
cp "$FAKEBIN/quota-axi-real" "$FAKEBIN/quota-axi"
expect_code 0 "$code" 'a hung quota read still resolves'
[ "$elapsed" -le 40 ] || fail "the quota wait is bounded to 30 seconds, took $elapsed"
assert_equals '1 claude1 false' "$(pfield '"\(.pool) \(.seat) \(.measured)"')" 'a hung read gives the first seat of pool 1 within the bound'
pass 'P: unreadable quota is bounded to 30 seconds and never opens the next pool'

# Shared-quota homes keep the declared order.
pipeline_quota
jq '.shared_quota = true' "$TMP_ROOT/rules-pipeline" > "$RULES"
pipe review
assert_equals 'claude1 true' "$(pfield '"\(.seat) \(.measured)"')" 'a shared-quota home takes the declared order'
cp "$TMP_ROOT/rules-pipeline" "$RULES"
pass 'P: a shared-quota home takes the declared order'

# Usage and configuration errors exit 2 and name the fault.
pipe nosuchstep
expect_code 2 "$code" 'a step with no row is a configuration error'
assert_contains "$perr" 'no pipeline_rows row names step nosuchstep' 'the step is named'
run pipeline
expect_code 2 "$code" 'pipeline needs a step'
run pipeline --step review "$BRIEF"
expect_code 2 "$code" 'pipeline takes no brief'
run "$BRIEF" --step review
expect_code 2 "$code" '--step belongs to pipeline mode'
bad_rows() {  # <jq edit> <expected text> <what>
  jq "$1" "$TMP_ROOT/rules-pipeline" > "$RULES"
  pipe review
  expect_code 2 "$code" "$3 is a configuration error: $pout"
  assert_contains "$perr" "$2" "$3 is named"
  cp "$TMP_ROOT/rules-pipeline" "$RULES"
}
bad_rows '.pipeline_rows[0].use += [{"harness":"pi","provider":"zai","model":"zai/glm-5.3","effort":"high","account":"glm","pool":2,"seat_tier":4,"reasoning_class":4}]' 'spends provider zai, which never_providers bans' 'a GLM seat in a row'
bad_rows 'del(.pipeline_rows[0].never_providers)' 'needs never_providers' 'a row without never_providers'
bad_rows '.pipeline_rows[0].use[3].reasoning_class = 3' 'share one reasoning_class' 'a fallback that lowers the class'
bad_rows '.pipeline_rows[0].use[2].seat_tier = 1' 'pool 2 seat_tier values must all follow pool 1' 'a pool 2 seat inside the pool 1 tier'
bad_rows '.pipeline_rows[0].use[2].fallback_only = true' 'must not set fallback_only' 'fallback_only in a row'
bad_rows '.pipeline_rows[0].use[2].weekly_floor_percent = "20"' 'weekly_floor_percent must be a number' 'a malformed floor'
bad_rows '.pipeline_rows[1].steps = ["review"]' 'pipeline step review is named by more than one row' 'a step in two rows'
bad_rows '.pipeline_rows[0].use[0].account = "nobody"' 'names unregistered account nobody' 'an unregistered seat'
bad_rows 'del(.pipeline_rows[0].use[0].account)' 'must name an account' 'a seat without an account'
bad_rows '.pipeline_rows[0].use[0].effort = "ultra"' 'effort must be supported' 'an unsupported effort'
assert_contains "$(acct fm_account_pipeline_problems "$TMP_ROOT/rules-pipeline")$(jq '.pipeline_rows = {}' "$TMP_ROOT/rules-pipeline" > "$RULES"; acct fm_account_pipeline_problems "$RULES")" 'pipeline_rows must be a non-empty array' 'a malformed rows value is named'
cp "$TMP_ROOT/rules-pipeline" "$RULES"
"$ROOT/bin/fm-account-routing.sh" off >/dev/null
pipe review
expect_code 2 "$code" 'routing off is not quota exhaustion'
assert_contains "$perr" 'pipeline seat not routable' 'routing off is named'
"$ROOT/bin/fm-account-routing.sh" on >/dev/null
cp "$TMP_ROOT/accounts-original" "$ACCOUNTS"
cp "$TMP_ROOT/rules-original" "$RULES"
pipeline_quota
reset_quota
pass 'P: malformed rows, unknown steps and unroutable seats are configuration errors'

# ---- A: seat lookup and migration ------------------------------------------------
ln -s "$STORES/claude3" "$STORES/claude3-alias"
assert_equals claude3 "$(acct fm_account_seat_for_store "$ACCOUNTS" claude "$STORES/claude3-alias")" 'a symlinked alias names its target seat'
assert_equals '' "$(acct fm_account_seat_for_store "$ACCOUNTS" pi "$STORES/pi")" 'a shared Pi store names no seat without a provider'
assert_equals glm "$(acct fm_account_seat_for_store "$ACCOUNTS" pi "$STORES/pi" zai)" 'the zai provider names the glm seat'
assert_equals codex1 "$(acct fm_account_seat_for_store "$ACCOUNTS" pi "$STORES/pi" codex)" 'the codex provider names the codex1 seat'
assert_equals '' "$(acct fm_account_registry_problems "$ACCOUNTS")" 'the six-account registry has no problems'
jq '.accounts.dup = {"provider":"zai","pi":"'"$STORES"'/pi/"}' "$ACCOUNTS" > "$TMP_ROOT/dup.json"
assert_contains "$(acct fm_account_registry_problems "$TMP_ROOT/dup.json")" 'both declare provider zai on pi store' 'two seats on one login are reported'
out=$("$ROOT/bin/fm-account-routing.sh" audit 2>&1); code=$?
expect_code 1 "$code" "the audit fails on a coverage gap: $out"
assert_contains "$out" 'gap: rule 2 claude:opus/high lacks claude account(s) claude3' 'a rung missing a provider account is named'
assert_contains "$out" 'single point: provider zai has one account (glm)' 'a single-account provider is noted'
assert_not_contains "$out" 'gap: rule 1' 'a fully covered rule is not reported'
RC="$TMP_ROOT/recent.json"
snap claude 40 3 > "$TMP_ROOT/good.json"
qlib fm_quota_recent_save "$RC" "$TMP_ROOT/good.json" "$STORES/claude3" "$STORES/pi" "$STORES/codex1"
jq '.providers[0] |= (.state = {status:"rate_limited"} | .windows = [] | .quotaSemantics = {status:"unknown", effectiveAvailability:[]})' "$TMP_ROOT/good.json" > "$TMP_ROOT/limited.json"
assert_equals 3 "$(qlib fm_quota_recent_merge "$RC" "$TMP_ROOT/limited.json" "$STORES/claude3" - - | jq '.providers[0].quotaSemantics.effectiveAvailability[0].selection.spendPriority')" \
  'a Claude row read through the home default answers for the claude3 seat on the same login'
assert_equals null "$(qlib fm_quota_recent_merge "$RC" "$TMP_ROOT/limited.json" "$STORES/claude2" - - | jq '.providers[0].reusedReading')" \
  'another login never borrows that reading'
pass 'A: provider-aware, symlink-canonical seat lookup and registry problems'
pass 'S7: the coverage audit names rungs missing an account and single-account providers'

MIG="$ROOT/bin/fm-account-migrate.sh"
has_line() { grep -qxF -- "$1" "$2" || fail "$3 (no line '$1' in $(basename "$2"): $(tr '\n' ' ' < "$2"))"; }
OLD="$TMP_ROOT/old-stores"
mkdir -p "$OLD/claude-old" "$OLD/codex-old" "$OLD/pi-old/agent"
STATE_DIR="$HOME_DIR/state"
printf 'harness=claude\nmodel=opus\naccount=legacy\nseat=legacy\nclaude_config_dir=%s\n' "$OLD/claude-old" > "$STATE_DIR/m-claude.meta"
printf 'harness=pi\nmodel=openai-codex/gpt-6.1-sol\naccount=legacy\npi_agent_dir=%s\ncodex_home=%s\n' "$OLD/pi-old/agent" "$OLD/codex-old" > "$STATE_DIR/m-codex.meta"
printf 'harness=pi\nmodel=zai/glm-5.3\npi_agent_dir=%s\n' "$STORES/pi" > "$STATE_DIR/m-zai.meta"
printf 'harness=claude\nmodel=sonnet\nclaude_config_dir=%s\n' "$STORES/claude3" > "$STATE_DIR/m-unnamed.meta"
printf '%s\n' "$OLD/pi-old/agent" 'openai-codex' > "$HOME_DIR/config/pi-account"
chmod 600 "$STATE_DIR"/m-*.meta
args=(--id legacy:claude=claude3 --id legacy:codex=codex1 --id -:claude=claude1 --id -:zai=glm
      --path "$OLD/codex-old=$STORES/codex1" --path "$OLD/pi-old/agent=$STORES/pi")
before=$(cat "$STATE_DIR/m-claude.meta")
out=$("$MIG" "${args[@]}" 2>&1); code=$?
expect_code 0 "$code" "dry run: $out"
assert_contains "$out" 'dry run, 5 file(s) would change' 'the dry run counts the changes'
assert_equals "$before" "$(cat "$STATE_DIR/m-claude.meta")" 'the dry run writes nothing'
env CODEX_HOME="$OLD/codex-old" sleep 30 &
live=$!
out=$("$MIG" "${args[@]}" --apply 2>&1); code=$?
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
expect_code 2 "$code" 'apply refuses while a worker runs on an old store'
assert_contains "$out" 'a live worker still runs on an old store' 'the live worker is named'
assert_equals "$before" "$(cat "$STATE_DIR/m-claude.meta")" 'the refusal writes nothing'
out=$("$MIG" "${args[@]}" --apply 2>&1); code=$?
expect_code 0 "$code" "apply after the drain: $out"
assert_contains "$out" 'applied 5 file change(s)' 'the apply reports its count'
has_line 'account=claude3' "$STATE_DIR/m-claude.meta" 'the old Claude id becomes claude3'
has_line 'seat=claude3' "$STATE_DIR/m-claude.meta" 'the seat follows'
has_line "claude_config_dir=$STORES/claude3" "$STATE_DIR/m-claude.meta" 'the store follows the new seat'
has_line 'account=codex1' "$STATE_DIR/m-codex.meta" 'the same old id splits by provider'
has_line "pi_agent_dir=$STORES/pi" "$STATE_DIR/m-codex.meta" 'the launch store is the new seat store'
has_line "codex_home=$STORES/codex1" "$STATE_DIR/m-codex.meta" 'other store keys follow the path map'
has_line 'account=glm' "$STATE_DIR/m-zai.meta" 'an unnamed zai record binds to glm'
has_line 'account=claude1' "$STATE_DIR/m-unnamed.meta" 'an unnamed Claude record binds to claude1'
has_line "claude_config_dir=$STORES/claude1" "$STATE_DIR/m-unnamed.meta" 'and relaunches on claude1'
assert_equals "$STORES/pi" "$(sed -n 1p "$HOME_DIR/config/pi-account")" 'the pin file path is rewritten'
assert_equals openai-codex "$(sed -n 2p "$HOME_DIR/config/pi-account")" 'the pin provider line is kept'
assert_equals 600 "$(stat -c %a "$STATE_DIR/m-claude.meta")" 'record modes are kept'
backup=$(find "$STATE_DIR/account-migrate" -mindepth 1 -maxdepth 1 -type d | head -1)
has_line 'account=legacy' "$backup/state/m-claude.meta" 'the original record is backed up'
out=$("$MIG" "${args[@]}" --apply 2>&1); code=$?
assert_contains "$out" 'nothing to change' 're-running is a no-op'
pass 'A: the one-shot migration splits an old id by provider, follows paths, backs up, refuses live workers, and is idempotent'

echo '# all fm-dispatch-six-accounts tests passed'
