#!/usr/bin/env bash
# Behavior tests for the Bridge (bin/fm-bridge.sh): build, refresh, open,
# export, digest and route, the shipped page rendered through
# tests/assets/bridge-render-harness.mjs, the watcher's refresh tick, and the
# guarded answer path from a captured Lavish choice through
# bin/fm-procevent-lavish.sh into bin/fm-captain-hold.sh. Assertions are on
# published files, rendered output and task state, never on source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge.sh"
HARNESS="$ROOT/tests/assets/bridge-render-harness.mjs"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge)
WATCH_PID=
REG=zz9reg

cleanup() {
  [ -z "$WATCH_PID" ] || kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ENABLED='{"schema":"fm-bridge-config.v1","enabled":true,"refresh_seconds":60}'

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  chmod 700 "$home" "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" treehouse no-mistakes gh gh-axi tmux
  # A protocol-shaped Lavish stub: opening lists the page open, poll blocks.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.74\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/live",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_NO_OPEN=1 "$@"
}
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@" >/dev/null); }
render() {  # <home> [now-epoch] [spec...]
  local home=$1
  shift
  node "$HARNESS" "$home/data/bridge/bridge.html" "$@"
}
feed() { jq -c "$2" "$1/state/bridge/feed.json"; }
check() { printf '%s\n' "$1" | jq -e "$2" >/dev/null || fail "$3: $1"; }
worker() {  # <home> <id>
  fm_write_meta "$1/state/$2.meta" 'kind=ship' 'harness=claude' "window=firstmate:fm-$2"
}
ask_for() {  # <home> <jq-select> -> ask id of the first matching card
  jq -r "[.asks[] | select($2)][0].ask // empty" "$1/state/bridge/feed.json"
}
# A Lavish capture holding exactly the given queued choices, as the page queued them.
capture() {  # <result-file> <queued-json-array>
  printf '%s' "$2" | jq -r '"status: feedback\nprompts[\(length)]{id,prompt,selector,tag,text}:",
    (to_entries[] | "  \"\(.key + 1)\",\(("Answer\n\nContext data:\n" + (.value.data | tojson)) | @json),\"form\",choice,\(.value.text | @json)")' > "$1"
}

test_config_gate() {
  local home out bad
  home=$(make_home config)
  out=$(in_home "$home" "$BRIDGE" open 2>&1) && fail "open succeeded without a config"
  assert_contains "$out" "the Bridge is off" "a missing config did not say the Bridge is off"
  in_home "$home" "$BRIDGE" refresh || fail "refresh with no config failed"
  assert_absent "$home/data/bridge/bridge.html" "refresh built a page that was never enabled"
  for bad in '{"schema":"fm-bridge-config.v1","enabled":true,"refresh_seconds":5}' \
    '{"schema":"fm-bridge-config.v1","enabled":"yes"}' '{"schema":"fm-bridge-config.v1","enabled":true,"x":1}' 'not json'; do
    printf '%s\n' "$bad" > "$home/config/bridge.json"
    out=$(in_home "$home" "$BRIDGE" open 2>&1) && fail "open accepted an invalid config: $bad"
    assert_contains "$out" "config is invalid" "an invalid config was not named invalid: $bad"
  done
  in_home "$home" "$BRIDGE" refresh || fail "refresh with an invalid config failed its caller"
  assert_absent "$home/data/bridge/bridge.html" "refresh built a page from an invalid config"
  assert_grep "config is invalid" "$home/state/bridge/refresh.log" "refresh did not log the invalid config"
  printf '%s\n' "$ENABLED" > "$TMP_ROOT/linked.json"
  rm -f "$home/config/bridge.json"
  ln -s "$TMP_ROOT/linked.json" "$home/config/bridge.json"
  out=$(in_home "$home" "$BRIDGE" open 2>&1) && fail "open followed a symlinked config"
  assert_contains "$out" "not a regular file" "a symlinked config was not refused"
  pass "the Bridge stays off unless a regular, valid, enabled config opts in"
}

test_keyed_question_lifecycle() {
  local home now out ask
  home=$(make_home keyed)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  worker "$home" w1
  now=$(date +%s)
  printf 'working [at=%s]: started\n' "$((now - 600))" > "$home/state/w1.status"
  in_home "$home" "$BRIDGE" refresh
  check "$(feed "$home" '.counts')" '.firstmate == 0 and .you == 0' "an empty fleet showed questions"
  printf 'needs-decision [key=x] [at=%s]: Which port should the API use? | A: 8080 | B: 9090 | rec=B | blocks=the deploy\n' \
    "$((now - 7200))" >> "$home/state/w1.status"
  in_home "$home" "$BRIDGE" refresh
  in_home "$home" "$BRIDGE" refresh
  out=$(feed "$home" '[.asks[] | select(.source == "status-key")]')
  check "$out" 'length == 1 and .[0].who == "firstmate" and .[0].asked_epoch == '"$((now - 7200))"'
    and .[0].question == "Which port should the API use?" and (.[0].options | map(.value)) == ["A","B"]
    and .[0].recommendation == "B" and .[0].blocks_text == "the deploy"' \
    "a keyed question did not reach the feed with its age and parsed options"
  ask=$(ask_for "$home" '.source == "status-key"')
  out=$(render "$home" "$now")
  check "$out" '(.sections[] | select(.title == "Waiting on Firstmate") | .asks) == ["'"$ask"'"]
    and (.cards["'"$ask"'"].text | test("about 2 h|2 h old")) and (.banners | any(test("1 question from the crew")))' \
    "the page did not show the keyed question under Waiting on Firstmate with its age"
  out=$(render "$home" "$now" "$ask=B:after lunch")
  check "$out" '.queued[0].data == {schema:"fm-bridge-answer.v1", ask:"'"$ask"'", selection:"B", note:"after lunch"}
    and (.queued[0].prompt | test("fm-bridge.sh route '"$ask"'"))' \
    "a keyed answer did not queue the opaque routed answer"
  out=$(in_home "$home" "$BRIDGE" route "$ask") || fail "route refused a current question: $out"
  assert_contains "$out" "relay: bin/fm-send.sh w1 --resolve-key x" "route did not name the fm-send relay"
  capture "$TMP_ROOT/keyed.result" "$(render "$home" "$now" "$ask=B" | jq -c '.queued')"
  out=$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$TMP_ROOT/keyed.result" 2>/dev/null)
  [ -z "$out" ] || fail "a routed keyed answer was handed to the captain-hold intake as a hold answer: $out"
  printf 'resolved [key=x] [at=%s]: use 9090\n' "$now" >> "$home/state/w1.status"
  in_home "$home" "$BRIDGE" refresh
  check "$(feed "$home" '.asks')" 'length == 0' "a resolved line did not remove the keyed card"
  out=$(in_home "$home" "$BRIDGE" route "$ask" 2>&1); [ "$?" -eq 3 ] || fail "route did not refuse a closed question: $out"
  assert_contains "$out" "not-current" "route did not say the question is no longer open"
  printf 'needs-decision [key=y]: an unstamped question\n' > "$home/state/gone.status"
  in_home "$home" "$BRIDGE" refresh
  check "$(feed "$home" '.asks[0]')" '.asked_estimated == true and (.flags | index("worker-gone"))' \
    "an unstamped question from a task with no worker was not marked estimated and worker-gone"
  pass "a keyed question shows with its age after refresh, routes through fm-send, and leaves on resolved"
}

test_hold_answer_path() {
  local home now out ask sid lifecycle rows show
  home=$(make_home hold)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  tasks_in "$home" add ws-carrier "Which carrier?" --repo web-shop --kind captain --priority 1
  tasks_in "$home" add ws-legacy "Pick a logo" --repo web-shop --kind captain
  tasks_in "$home" add ws-ship "Ship the spring orders" --repo web-shop --kind ship --blocked-by ws-carrier
  cat > "$home/ctx.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"done",
 "about":"The web shop needs one company to deliver the spring orders to customers.",
 "purpose":"Your pick lets the team book the deliveries. Until you pick, spring orders cannot be sent out.",
 "question":"Who should ship the spring orders?",
 "options":[{"value":"dhl","label":"DHL","detail":"Next-day delivery, about 8 percent dearer."},
  {"value":"postnl","label":"PostNL","detail":"Two-day delivery at today's price, which is why it is recommended."}],
 "recommendation":"postnl"}
JSON
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ws-carrier --reason "Pick a carrier." --context-file "$home/ctx.json" >/dev/null \
    || fail "could not hold the carrier question"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ws-legacy --reason "Which logo, old or new?" >/dev/null \
    || fail "could not hold the legacy question"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  now=$(date +%s)
  ask=$(ask_for "$home" '.task == "ws-carrier"')
  out=$(feed "$home" '[.asks[] | select(.who == "you")]')
  check "$out" 'length == 2 and .[0].task == "ws-carrier" and .[0].answer == "hold-guarded"
    and .[0].blocks == ["Ship the spring orders"] and .[1].answer == "hold-free"' \
    "holds did not rank by what waits behind them, or lost their answer mode"
  out=$(in_home "$home" "$BRIDGE" open 2>&1) || fail "open failed: $out"
  assert_contains "$out" "session: live" "open did not prove the session live"
  sid=$(printf '%s\n' "$out" | sed -n 's/^bound: //p')
  [ -n "$sid" ] || fail "open did not bind the page source: $out"
  assert_contains "$out" "armed: $sid" "open did not arm the bound source"
  out=$(render "$home" "$now" "$ask=postnl")
  lifecycle=$(printf '%s' "$out" | jq -r '.queued[0].data.lifecycle')
  check "$out" '.queued[0].data.schema == "fm-bearings-answer.v1" and .queued[0].data.question == "ws-carrier"
    and .queued[0].data.selection == "postnl" and .queued[0].data.close == "done" and .cards["'"$ask"'"].queued' \
    "a held question did not queue the guarded captain-hold answer"
  capture "$TMP_ROOT/hold.result" "$(printf '%s' "$out" | jq -c '.queued')"
  rows=$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$TMP_ROOT/hold.result")
  [ "$(printf '%s\n' "$rows" | cut -f1,2,4,5)" = "$(printf 'ws-carrier\tpostnl\tdone\t%s' "$lifecycle")" ] \
    || fail "the adapter did not relay the guarded Bridge answer: $rows"
  out=$(printf '%s\n' "$rows" | in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source "fixture capture" 2>&1)
  assert_contains "$out" "closed: ws-carrier" "the Bridge answer did not close the held question"
  show=$(cd "$home" && tasks-axi show ws-carrier --full)
  assert_contains "$show" "state: done" "the answered question stayed open"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "rebuild failed"
  check "$(feed "$home" '[.asks[].task]')" 'index("ws-carrier") == null and index("ws-legacy") != null' \
    "an answered hold stayed on the Bridge"
  out=$(render "$home" "$now" "$(ask_for "$home" '.task == "ws-legacy"')=:Use the new logo")
  check "$out" '.queued[0].data == {schema:"fm-bearings-answer.v1", question:"ws-legacy", selection:"", note:"Use the new logo"}' \
    "a hold without context did not queue a free-text captain answer"
  pass "a held question is answerable, goes through the captain-hold intake, and leaves after answer"
}

secondmate_world() {  # <home> -> secondmate home path
  local home=$1 sm="$1-sm" now
  now=$(date +%s)
  mkdir -p "$sm/state/bridge"
  fm_write_meta "$home/state/$REG.meta" 'kind=secondmate' "home=$sm" "worktree=$sm"
  jq -n --argjson now "$now" --arg reg "$REG" '{schema:"fm-bridge-export.v1", generated_epoch:$now, complete:true, asks:[
    {route:{kind:"hold", task:"sm-pick", lifecycle:"2026-01-01T00:00:00Z#0"}, who:"you", source:"hold",
     asker:"Harbor colour", asked_epoch:($now - 90000), question:("Which colour for the harbor sign, says " + $reg + "?"),
     options:[{value:"red", label:"Red"}, {value:"blue", label:"Blue"}], recommendation:"blue", blocks:["Paint the sign"]},
    {route:{kind:"key", task:"sm-w", key:"k1", at:($now - 60)}, who:"firstmate", source:"status-key",
     asker:"Harbor worker", asked_epoch:($now - 60), question:"Should I paint on Sunday?"}]}' > "$sm/state/bridge/asks.json"
  {
    printf 'needs-decision [key=captain-hold-sm-pick] [at=%s]: relayed: harbor colour\n' "$((now - 80000))"
    printf 'needs-decision [key=captain-hold-gone] [at=%s]: relayed: an old call\n' "$((now - 80000))"
    printf 'needs-decision [key=fyi] [at=%s]: %s finished the report, should I archive it?\n' "$((now - 3000))" "$REG"
  } > "$home/state/$REG.status"
  printf '%s\n' "$sm"
}

test_secondmate_export_and_names() {
  local home sm now out marker
  home=$(make_home sm)
  sm=$(secondmate_world "$home")
  printf '{"schema":"fm-bridge-names.v1","names":{"%s":"Harbor"}}\n' "$REG" > "$home/config/bridge-names.json"
  marker="$TMP_ROOT/sm-marker"; : > "$marker"; sleep 1
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  now=$(date +%s)
  out=$(feed "$home" '.')
  check "$out" '.complete == true and .counts.you == 1 and .counts.secondmates == 1 and .counts.firstmate == 1
    and .counts.moot == 1 and .counts.relayed == 0
    and ([.asks[] | select(.who == "you")][0] | .home == "Harbor" and (.flags | index("relayed")) and .question == "Which colour for the harbor sign, says Harbor?")' \
    "a secondmate export did not merge under its name with its mirror folded in"
  out=$(render "$home" "$now")
  check "$out" '(.sections | map(.title)) == ["Needs you","Waiting on Firstmate","Waiting on Harbor"]
    and (.groups | map(.title) | any(test("Probably settled")))' \
    "the page did not place the exported cards under Needs you and Waiting on Harbor"
  printf '%s' "$out" | jq -r '.text' | grep -q "$REG" && fail "the rendered page showed a secondmate registry id"
  grep -q "$REG" "$home/data/bridge/bridge.html" && fail "the published page carries a secondmate registry id"
  grep -q "$REG" "$home/state/bridge/digest.txt" && fail "the digest carries a secondmate registry id"
  [ -z "$(find "$sm" -newer "$marker" -print 2>/dev/null)" ] || fail "the Bridge wrote into the secondmate's home"
  out=$(in_home "$home" "$BRIDGE" route "$(ask_for "$home" '.home == "Harbor" and .who == "you"')")
  assert_contains "$out" "home: $REG" "route did not name the secondmate to relay to"
  rm -f "$home/config/bridge-names.json"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build without names failed"
  out=$(render "$home" "$now")
  check "$out" '(.sections | map(.title) | index("Waiting on a secondmate")) != null' "an unnamed secondmate was not called a secondmate"
  printf '%s' "$out" | jq -r '.text' | grep -q "$REG" && fail "an unnamed secondmate's registry id was rendered"
  rm -f "$sm/state/bridge/asks.json"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build without an export failed"
  out=$(feed "$home" '.')
  check "$out" '.complete == false and .counts.relayed == 2 and .counts.you == 0
    and (.sources.items | any(.read == "absent"))' \
    "a secondmate with no export did not keep its relayed questions visible and the board incomplete"
  printf 'not json' > "$sm/state/bridge/asks.json"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build with an invalid export failed"
  check "$(feed "$home" '.sources.items')" 'any(.read == "failed")' "an invalid export was not reported as failed"
  pass "a secondmate export merges under its display name, folds its mirrors, and no registry id is rendered"
}

test_never_falsely_green() {
  local home now out
  home=$(make_home blind)
  worker "$home" w1
  printf 'working: fine\n' > "$home/state/w1.status"
  ln -s "$TMP_ROOT/nowhere" "$home/state/w2.status"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  now=$(date +%s)
  check "$(feed "$home" '.')" '.complete == false and (.sources.items | any(.label == "status logs" and .read == "failed" and (.detail | test("w2"))))' \
    "an unreadable status log did not make the feed incomplete"
  out=$(render "$home" "$now")
  check "$out" '(.stats[0] | test("at least 0")) and (.banners | any(test("Not everything could be read")))
    and ([.sections[] | select(.title == "Needs you")][0].empty | test("could not be read"))' \
    "a board with an unread source showed a plain zero"
  grep -q 'complete=no' "$home/state/bridge/digest.txt" || fail "the digest did not say the board is incomplete"
  rm -f "$home/state/w2.status"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "rebuild failed"
  out=$(render "$home" "$((now + 1000))")
  check "$out" '.stale and (.staleBanner | test("may have stopped"))' "an old page did not mark itself out of date"
  out=$(render "$home" "$now")
  check "$out" '(.stale | not) and .staleBanner == ""' "a fresh page marked itself out of date"
  pass "an unreadable source or a stopped builder never shows a green board"
}

test_redaction_and_escaping() {
  local home now token out
  home=$(make_home redact)
  worker "$home" w1
  now=$(date +%s)
  token="ghp_$(printf 'A1b2C3d4%.0s' 1 2 3 4)"
  {
    printf 'needs-decision [key=leak] [at=%s]: use token %s and https://example.com/cb?code=s3cr3tvalue now\n' "$now" "$token"
    printf 'needs-decision [key=xss] [at=%s]: </script><img src=x onerror=alert(1)> ok?\n' "$now"
    printf 'needs-decision [key=board] [at=%s]: review http://127.0.0.1:4387/session/d2bbe6103e9cc5aa please\n' "$now"
  } > "$home/state/w1.status"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  for f in "$home/data/bridge/bridge.html" "$home/state/bridge/digest.txt" "$home/state/bridge/asks.json"; do
    grep -q "$token" "$f" && fail "a planted token reached $(basename "$f")"
    grep -q 's3cr3tvalue' "$f" && fail "a URL query reached $(basename "$f")"
    grep -q 'd2bbe6103e9cc5aa' "$f" && fail "a Lavish session id reached $(basename "$f")"
  done
  grep -q '</script><img' "$home/data/bridge/bridge.html" && fail "markup in a question was not escaped in the page"
  out=$(render "$home" "$now")
  check "$out" '.text | test("</script><img src=x onerror=alert\\(1\\)> ok\\?") and test("https://example.com/cb ")' \
    "an escaped question did not render as literal text"
  pass "worker text is redacted before the page, export and digest, and markup renders as text"
}

test_digest_and_bounds() {
  local home now i out
  home=$(make_home digest)
  worker "$home" w1
  now=$(date +%s)
  : > "$home/state/w1.status"
  for i in $(seq 1 40); do
    printf 'needs-decision [key=k%s] [at=%s]: question number %s with some words to make the line long enough\n' "$i" "$((now - i))" "$i" >> "$home/state/w1.status"
  done
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  out=$(in_home "$home" "$BRIDGE" digest)
  [ "$(wc -c < "$home/state/bridge/digest.txt")" -le 2048 ] || fail "the digest is over 2048 bytes"
  printf '%s\n' "$out" | head -1 | grep -q '^bridge v1 checked=.* sources=3/3$' || fail "the digest header is wrong: $out"
  printf '%s\n' "$out" | grep -q '^asks you=0 firstmate=40 ' || fail "the digest did not count the questions: $out"
  printf '%s\n' "$out" | grep -q '^+[0-9]* more$' || fail "a long digest did not say how many more: $out"
  printf '%s\n' "$out" | tail -n 1 | grep -q '^bridge-end hash=[0-9a-f]\{12\}$' || fail "the digest has no end line: $out"
  printf '%s\n' "$out" | grep '^- ' | grep -qv ' data: ' && fail "a digest question line lacks its data: prefix"
  head -c 300 "$home/state/bridge/digest.txt" > "$home/state/bridge/digest.cut"
  mv "$home/state/bridge/digest.cut" "$home/state/bridge/digest.txt"
  in_home "$home" "$BRIDGE" digest | grep -q '^bridge-warning the digest is truncated' || fail "a truncated digest was not flagged"
  pass "the digest stays under 2048 bytes, ends with its hash line, and flags truncation"
}

test_incremental_reads() {
  local home now probe start end elapsed f i
  home=$(make_home big)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  worker "$home" w1
  now=$(date +%s)
  {
    for i in $(seq 1 1499); do printf 'working [at=%s]: step %s\n' "$now" "$i"; done
    printf 'needs-decision [key=big] [at=%s]: still open?\n' "$now"
    for i in $(seq 1 1500); do printf 'working [at=%s]: step %s\n' "$now" "$i"; done
  } > "$home/state/w1.status"
  probe="$TMP_ROOT/probe"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" in_home "$home" "$BRIDGE" refresh
  [ -s "$probe" ] || fail "the first refresh did not fold the status log"
  check "$(feed "$home" '[.asks[].question]')" '. == ["still open?"]' "the 3,000-line log lost its open question"
  for f in "$home"/state/.*open-decisions-cursor*; do
    [ -e "$f" ] && fail "the Bridge wrote a cursor beside the status logs: $f"
  done
  : > "$probe"
  start=$(date +%s%N)
  FM_OPEN_DECISIONS_READ_PROBE="$probe" in_home "$home" "$BRIDGE" refresh
  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))
  [ ! -s "$probe" ] || fail "a refresh with no new bytes read the status log: $(cat "$probe")"
  [ "$elapsed" -lt 1000 ] || fail "a refresh with no new bytes took ${elapsed} ms"
  : > "$probe"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" in_home "$home" "$BRIDGE" build >/dev/null || fail "forced build failed"
  [ ! -s "$probe" ] || fail "a full build with no new bytes re-read the status log: $(cat "$probe")"
  printf 'resolved [key=big]: done\n' >> "$home/state/w1.status"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" in_home "$home" "$BRIDGE" refresh
  [ "$(cut -f2 "$probe")" = "$(printf 'resolved [key=big]: done\n' | wc -c | tr -d ' ')" ] \
    || fail "a refresh after one new line did not read only that line: $(cat "$probe")"
  check "$(feed "$home" '.asks')" 'length == 0' "the appended resolution did not clear the card"
  pass "a refresh over 3,000 lines with no new bytes reads nothing, stays under 1 s, and keeps cursors out of state"
}

test_refresh_retention() {
  local home page
  home=$(make_home retain)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  in_home "$home" "$BRIDGE" refresh
  page="$home/data/bridge/bridge.html"
  assert_present "$page" "refresh did not build an enabled Bridge"
  cp "$page" "$TMP_ROOT/last-good.html"
  touch -t 202001010000 "$page" "$home/state/bridge/feed.json"
  chmod 500 "$home/data/bridge"
  in_home "$home" "$BRIDGE" refresh || fail "a failed refresh changed its exit status"
  chmod 700 "$home/data/bridge"
  cmp -s "$page" "$TMP_ROOT/last-good.html" || fail "a failed refresh replaced the last good page"
  jq -e '.result == "failed" and (.error | length > 0)' "$home/state/bridge/health.json" >/dev/null \
    || fail "a failed refresh was not recorded in health.json"
  in_home "$home" "$BRIDGE" digest | grep -q '^bridge-warning the last build failed' || fail "the digest did not warn about the failed build"
  in_home "$home" "$BRIDGE" refresh
  jq -e '.result == "ok"' "$home/state/bridge/health.json" >/dev/null || fail "a recovered refresh did not record ok"
  pass "refresh keeps the last good page on failure and records it in health and the digest"
}

test_watcher_tick() {
  local home i
  home=$(make_home watched)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
    "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
  WATCH_PID=$!
  i=0
  while [ ! -s "$home/data/bridge/bridge.html" ] && [ "$i" -lt 300 ]; do
    kill -0 "$WATCH_PID" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
  wait "$WATCH_PID" >/dev/null 2>&1 || true
  WATCH_PID=
  [ -s "$home/data/bridge/bridge.html" ] || fail "the watcher did not publish an enabled Bridge: $(cat "$TMP_ROOT/watch.err" 2>/dev/null)"
  check "$(render "$home")" '(.sections | map(.title)) == ["Needs you","Waiting on Firstmate"]' "the watcher-published page did not render"
  pass "a running watcher keeps an enabled Bridge published"
}

# A recorder standing in for every desktop channel: one line per alert.
alert_recorder() {  # <home> -> recorder path
  cat > "$1/alert-recorder" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "${0%/*}/alerts.log"
SH
  chmod +x "$1/alert-recorder"
  printf '%s\n' "$1/alert-recorder"
}
alert_count() { if [ -f "$1/alerts.log" ]; then wc -l < "$1/alerts.log" | tr -d ' '; else printf '0\n'; fi; }
build_at() {  # <home> <alert-now-epoch>
  in_home "$1" env FM_BRIDGE_ALERT_EXEC="$1/alert-recorder" FM_BRIDGE_ALERT_NOW="$2" "$BRIDGE" build >/dev/null \
    || fail "build failed at $2"
}

test_alerts_fire_once_per_step() {
  local home t0 set out
  home=$(make_home alerts)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  alert_recorder "$home" >/dev/null
  t0=$(( $(date +%s) - 120 ))
  set=$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$t0" +%Y-%m-%dT%H:%M:%SZ)
  tasks_in "$home" add ws-colour "Pick the banner colour" --repo web-shop --kind captain
  in_home "$home" env FM_CAPTAIN_HOLD_NOW="$set" "$ROOT/bin/fm-captain-hold.sh" hold ws-colour \
    --reason "Secret plan: blue or green banner?" >/dev/null || fail "could not hold the question"

  # No config: nothing fires and the page says it is the only signal.
  build_at "$home" "$((t0 + 60))"
  [ "$(alert_count "$home")" = 0 ] || fail "an alert fired with no config/bridge-alerts"
  check "$(render "$home")" '.banners | any(test("Desktop alerts are not set up"))' "the page did not say alerts are not set up"

  # An invalid config turns every channel off and says why.
  printf 'herdr\nsteps 0 4x\n' > "$home/config/bridge-alerts"
  build_at "$home" "$((t0 + 60))"
  [ "$(alert_count "$home")" = 0 ] || fail "an invalid alert config still fired"
  check "$(render "$home")" '.banners | any(test("settings could not be read.*4x"))' "an invalid alert config was not named"

  # A valid config: one alert on arrival, one per later step, never a repeat.
  printf '# desktop alerts\nherdr\nsteps 0 4h 24h\n' > "$home/config/bridge-alerts"
  build_at "$home" "$((t0 + 60))"
  [ "$(alert_count "$home")" = 1 ] || fail "arrival did not fire exactly one alert: $(cat "$home/alerts.log" 2>/dev/null)"
  build_at "$home" "$((t0 + 600))"
  [ "$(alert_count "$home")" = 1 ] || fail "a second build in the same step fired again"
  build_at "$home" "$((t0 + 4 * 3600 + 60))"
  [ "$(alert_count "$home")" = 2 ] || fail "the 4 h step did not fire exactly once"
  build_at "$home" "$((t0 + 5 * 3600))"
  [ "$(alert_count "$home")" = 2 ] || fail "the 4 h step fired twice"
  build_at "$home" "$((t0 + 24 * 3600 + 60))"
  [ "$(alert_count "$home")" = 3 ] || fail "the 24 h step did not fire exactly once"
  build_at "$home" "$((t0 + 48 * 3600))"
  [ "$(alert_count "$home")" = 3 ] || fail "an alert fired past the last step"
  out=$(cat "$home/alerts.log")
  assert_contains "$out" "herdr|1 question waits for you" "the alert did not go to the configured channel with a count"
  printf '%s' "$out" | grep -qiE 'secret|banner|colour' && fail "alert text carried question text: $out"
  check "$(render "$home")" '.banners | any(test("Desktop alerts are on \\(herdr\\).*arrives and again at 4 h and 24 h.*Last alert"))' \
    "the page did not show the alert channel, steps and last alert"

  # A question first seen past a step fires once, not once per step it skipped.
  tasks_in "$home" add ws-font "Pick the heading font" --repo web-shop --kind captain
  in_home "$home" env FM_CAPTAIN_HOLD_NOW="$set" "$ROOT/bin/fm-captain-hold.sh" hold ws-font --reason "Serif or sans?" >/dev/null \
    || fail "could not hold the second question"
  build_at "$home" "$((t0 + 48 * 3600 + 60))"
  [ "$(alert_count "$home")" = 4 ] || fail "a late-seen question did not fire exactly one alert"
  assert_contains "$(tail -n 1 "$home/alerts.log")" "2 questions wait for you, oldest 2 days" "the alert count or age is wrong"

  # `off` silences every channel.
  printf 'off\nherdr\n' > "$home/config/bridge-alerts"
  rm -f "$home/state/bridge/alerts.json"
  build_at "$home" "$((t0 + 60))"
  [ "$(alert_count "$home")" = 4 ] || fail "an off directive still fired"
  check "$(render "$home")" '.banners | any(test("switched off"))' "the page did not say alerts are switched off"
  pass "a desktop alert fires once per age step per question, carries no question text, and the page shows its state"
}

test_deadline_clock_on_the_card() {
  local home now set due_set out ask_soon ask_stop ask_out show
  home=$(make_home clock)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  now=$(date +%s)
  # Held 23 h 59 min ago with the earliest allowed default, 24 h after the hold:
  # a one-minute test clock.
  set=$(date -u -d "@$((now - 86340))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((now - 86340))" +%Y-%m-%dT%H:%M:%SZ)
  due_set=$(date -u -d "@$((now + 60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((now + 60))" +%Y-%m-%dT%H:%M:%SZ)
  for id in ws-soon ws-stop; do
    tasks_in "$home" add "$id" "Pick the button label" --repo web-shop --kind captain
    jq -n --arg at "$due_set" '{schema:"fm-captain-question.v1",close:"done",
      about:"The shop button needs a label.",purpose:"Your pick sets the label; until then the old one stays.",
      question:"Which button label?",
      options:[{value:"order",label:"Order now",detail:"Short and clear, which is why it is recommended."},
               {value:"buy",label:"Add to basket",detail:"Longer."}],
      recommendation:"order",scope:["copy"],default_eligible:"small-reversible",default_at:$at}' > "$home/ctx.json"
    in_home "$home" env FM_CAPTAIN_HOLD_NOW="$set" "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "Pick a label." \
      --context-file "$home/ctx.json" >/dev/null || fail "could not hold $id with an hour default"
  done
  tasks_in "$home" add ws-out "Tell customers about the sale" --repo web-shop --kind captain
  jq '.scope = ["outward-facing"] | del(.default_eligible, .default_at)' "$home/ctx.json" > "$home/ctx-out.json"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ws-out --reason "Mail customers?" --context-file "$home/ctx-out.json" >/dev/null \
    || fail "could not hold the outward-facing question"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  ask_soon=$(ask_for "$home" '.task == "ws-soon"')
  ask_stop=$(ask_for "$home" '.task == "ws-stop"')
  ask_out=$(ask_for "$home" '.task == "ws-out"')
  check "$(feed "$home" '[.asks[] | select(.task == "ws-soon") | .default][0]')" \
    '.state == "pending" and .due_epoch == '"$((now + 60))"' and .label == "Order now"' "the card did not carry the countdown"
  out=$(render "$home" "$now")
  check "$out" '(.cards["'"$ask_soon"'"].text | test("Goes ahead with the recommended answer \\(Order now\\) in 60 s, marked as not your words"))
    and (.cards["'"$ask_out"'"].text | test("Cannot go ahead without you: this is outward-facing"))' \
    "the page did not show the countdown or why a call cannot default"

  # Stop the clock: the page queues a request for Firstmate, route names the verb.
  out=$(render "$home" "$now" "@$ask_stop:stop-clock")
  check "$out" '.queued[0].data == {schema:"fm-bridge-stop-clock.v1", ask:"'"$ask_stop"'"}
    and (.cards["'"$ask_stop"'"].text | test("Stop queued"))' "stop the clock did not queue its request"
  capture "$TMP_ROOT/stop.result" "$(printf '%s' "$out" | jq -c '.queued')"
  [ -z "$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$TMP_ROOT/stop.result" 2>/dev/null)" ] \
    || fail "a stop request was handed to the captain-hold intake as an answer"
  out=$(in_home "$home" "$BRIDGE" route "$ask_stop") || fail "route refused a current hold"
  assert_contains "$out" "stop-clock: bin/fm-captain-hold.sh stop-clock ws-stop" "route did not name the stop-clock verb"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" stop-clock ws-stop --source "captain on the Bridge" >/dev/null \
    || fail "stop-clock refused a pending default"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  ask_stop=$(ask_for "$home" '.task == "ws-stop"')
  check "$(render "$home" "$now")" '.cards["'"$ask_stop"'"].text | test("You stopped the clock")' "a stopped clock was not shown"

  # One minute later only the running clock is due, and it applies as not the captain's words.
  out=$(in_home "$home" env FM_CAPTAIN_HOLD_NOW="$(date -u -d "@$((now + 120))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((now + 120))" +%Y-%m-%dT%H:%M:%SZ)" \
    "$ROOT/bin/fm-captain-hold.sh" defaults-due)
  [ "$(printf '%s\n' "$out" | cut -f1)" = ws-soon ] || fail "defaults-due did not list exactly the running clock: $out"
  in_home "$home" env FM_CAPTAIN_HOLD_NOW="$(date -u -d "@$((now + 120))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$((now + 120))" +%Y-%m-%dT%H:%M:%SZ)" \
    "$ROOT/bin/fm-captain-hold.sh" answer ws-soon --deadline-default >/dev/null || fail "the due default could not be applied"
  show=$(cd "$home" && tasks-axi show ws-soon --full)
  assert_contains "$show" "Deadline default (not the captain's words):" "the applied default is not labelled"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  check "$(feed "$home" '[.asks[].task]')" 'index("ws-soon") == null and index("ws-stop") != null and index("ws-out") != null' \
    "the applied default did not leave the board, or another call left with it"
  pass "a card counts down to its default, stops on request, and says why a call can never default"
}

test_nudge_and_parked_work() {
  local home now out old young
  home=$(make_home nudge)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  worker "$home" w1
  worker "$home" w2
  now=$(date +%s)
  printf 'blocked [key=db] [at=%s]: Which database host? | A: Old host | B: New host | rec=B\n' "$((now - 1200))" > "$home/state/w1.status"
  printf 'needs-decision [key=tone] [at=%s]: Formal or casual tone?\n' "$((now - 300))" > "$home/state/w2.status"
  tasks_in "$home" add ws-carrier "Which carrier?" --repo web-shop --kind captain
  tasks_in "$home" add ws-ship "Ship the spring orders" --repo web-shop --kind ship --blocked-by ws-carrier
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ws-carrier --reason "Pick a carrier." >/dev/null || fail "could not hold"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  old=$(ask_for "$home" '.route.key == "db"')
  young=$(ask_for "$home" '.route.key == "tone"')
  out=$(render "$home" "$now")
  check "$out" '(.cards["'"$old"'"].text | test("Waiting on Firstmate 20 min") and test("Nudge Firstmate"))
    and (.cards["'"$young"'"].text | test("Waiting on Firstmate|Nudge") | not)' \
    "a question past 15 minutes did not offer a nudge, or a young one did"
  check "$out" '.text | test("Parked until a question is answered \\(2\\)") and test("Ship the spring orders waits on you")
    and test("w1 waits on Firstmate for 20 min: Which database host\\?")' "the parked-work list is wrong"
  out=$(render "$home" "$now" "@$old:nudge")
  check "$out" '.queued == [.queued[0]] and .queued[0].data == {schema:"fm-bridge-nudge.v1", ask:"'"$old"'"}
    and (.queued[0].prompt | test("fm-bridge.sh route '"$old"'")) and (.cards["'"$old"'"].text | test("Nudge queued"))' \
    "a nudge did not queue one routed request"
  capture "$TMP_ROOT/nudge.result" "$(printf '%s' "$out" | jq -c '.queued')"
  [ -z "$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$TMP_ROOT/nudge.result" 2>/dev/null)" ] \
    || fail "a nudge was handed to the captain-hold intake as an answer"
  out=$(render "$home" "$now" "!nolavish" "@$old:nudge")
  check "$out" '.queued == [] and (.cards["'"$old"'"].text | test("only works when the board is open in Lavish"))' \
    "a nudge without Lavish did not explain itself"
  pass "a question waiting on Firstmate past 15 minutes offers a routed nudge, and parked work is listed"
}

# --- slice 2: the fleet ------------------------------------------------------

# A crew-state stand-in: answers from $FM_HOME/crew/<id> and logs each call.
crew_stub() {  # <home>
  cat > "$1/crew-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/crew-calls"
cat "$FM_HOME/crew/$1" 2>/dev/null || printf 'garbled reader output\n'
SH
  chmod +x "$1/crew-stub"
  mkdir -p "$1/crew"
}
crew_says() { printf 'state: %s · source: %s · %s\n' "$3" "$4" "$5" > "$1/crew/$2"; }
in_fleet() { local home=$1; shift; FM_BRIDGE_CREW_STATE_CMD="$home/crew-stub" in_home "$home" "$@"; }
row() { jq -c --arg t "$2" '[.fleet.homes[].rows[] | select(.title == $t)][0]' "$1/state/bridge/feed.json"; }
rendered_flags() {  # <home> <now> <title>
  render "$1" "$2" | jq -c --arg t "$3" '[.fleet.rows[] | select(.title == $t)][0].flags'
}

test_fleet_flags_and_crew_cache() {
  local home now r i calls
  home=$(make_home fleet)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  crew_stub "$home"
  now=$(date +%s)
  for i in w1 w2 w3 w4 w5; do worker "$home" "$i"; done
  crew_says "$home" w1 working pane 'harness busy (claude-hook)'
  printf 'working [at=%s]: reading the parser\n' "$((now - 4000))" > "$home/state/w1.status"
  crew_says "$home" w2 working pane 'busy'
  for i in 1 2 3; do printf 'failed [at=%s]: pipeline step %s failed: lint\n' "$((now - 300 + i))" "$i"; done > "$home/state/w2.status"
  crew_says "$home" w3 working pane 'busy'
  # 101 different lines in a day, the last one just now: noisy, not repeating or stale.
  for i in $(seq 1 101); do printf 'working [at=%s]: tick %s\n' "$((now - 70700 + i * 700))" "$(printf '%s' "$i" | tr 0-9 a-j)"; done > "$home/state/w3.status"
  crew_says "$home" w4 parked run-step 'waiting at the review gate'
  printf 'working [at=%s]: pipeline started\n' "$((now - 60))" > "$home/state/w4.status"
  printf 'done [at=%s]: PR https://github.com/acme/shop/pull/7\n' "$((now - 90000))" > "$home/state/w5.status"
  crew_says "$home" w5 'done' status-log 'PR https://github.com/acme/shop/pull/7'
  tasks_in "$home" add w5 "Ship the cart" --repo web-shop --kind ship
  : > "$home/crew-calls"
  in_fleet "$home" "$BRIDGE" refresh
  [ "$(sort "$home/crew-calls" | tr '\n' ' ')" = "w1 w2 w3 w4 w5 " ] || fail "the first refresh did not read every worker once: $(cat "$home/crew-calls")"
  r=$(row "$home" "w1")
  check "$r" '.state == "working" and .stale_at == '"$((now - 4000 + 1800))"' and .now_text == "reading the parser"' \
    "a quiet worker did not get its stale time from max(30 min, 3 x median gap), or showed the harness instead of its report"
  check "$(rendered_flags "$home" "$((now - 2201))" w1)" 'index("stale") == null' "a worker was stale before its threshold"
  check "$(rendered_flags "$home" "$((now - 2200))" w1)" 'index("stale") != null' "a worker that stopped appending was not stale at its threshold"
  grep -q '^fleet working=3 review=1 .* stale=1 repeating=1 noisy=1 parked_long=0 done_open=1 ' "$home/state/bridge/digest.txt" \
    || fail "the digest fleet line is wrong: $(grep '^fleet' "$home/state/bridge/digest.txt")"
  check "$(rendered_flags "$home" "$now" w2)" 'index("repeating") != null' "a status line repeated three times in an hour was not flagged repeating"
  check "$(rendered_flags "$home" "$now" w3)" 'index("noisy") != null and index("repeating") == null' "a log with over 100 lines a day was not flagged noisy (or was called repeating)"
  check "$(rendered_flags "$home" "$now" w4)" 'index("parked-long") == null' "a worker just parked was flagged parked long"
  check "$(rendered_flags "$home" "$((now + 3700))" w4)" 'index("parked-long") != null' "a worker parked over an hour was not flagged"
  check "$(rendered_flags "$home" "$now" "Ship the cart")" 'index("done-open") != null' "a worker done over a day with its task row open was not flagged"
  check "$(row "$home" "Ship the cart")" '.pr == "https://github.com/acme/shop/pull/7"' "a finished worker lost its PR link"
  # The current-state reader is cached: nothing changed, nothing re-read.
  : > "$home/crew-calls"
  in_fleet "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  [ ! -s "$home/crew-calls" ] || fail "an unchanged worker was re-read: $(cat "$home/crew-calls")"
  # A new line clears stale, and only that worker is re-read.
  sleep 1
  printf 'working [at=%s]: parser done, writing tests\n' "$(date +%s)" >> "$home/state/w1.status"
  in_fleet "$home" "$BRIDGE" refresh
  [ "$(cat "$home/crew-calls")" = w1 ] || fail "a changed worker was not the only one re-read: $(cat "$home/crew-calls")"
  check "$(rendered_flags "$home" "$(date +%s)" w1)" 'index("stale") == null' "a stale worker kept the flag after its next line"
  grep -q ' stale=0 ' "$home/state/bridge/digest.txt" || fail "the digest still counts the worker stale"
  # A reader that cannot decide is shown as unknown, with why.
  rm -f "$home/crew/w1"
  printf 'working [at=%s]: next\n' "$(date +%s)" >> "$home/state/w1.status"
  in_fleet "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  check "$(row "$home" w1)" '.state == "unknown" and (.flags | index("unknown")) and (.unknown_detail | length > 0)' \
    "an undecided state reader did not show as unknown with its reason"
  calls=$(render "$home" "$now" | jq -r '.fleet.text')
  assert_contains "$calls" "Why unknown" "the page did not say why a worker is unknown"
  pass "fleet flags fire at their thresholds, clear on the next line, and crew-state is re-read only on change"
}

test_fleet_usage_never_triggers_quota() {
  local home now f
  home=$(make_home quota)
  crew_stub "$home"
  now=$(date +%s)
  cat > "$home/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/quota-was-called"
exit 1
SH
  chmod +x "$home/fakebin/quota-axi"
  fm_write_meta "$home/state/w1.meta" 'kind=ship' 'harness=claude' 'seat=claude9' "claude_config_dir=$home/cfg9"
  crew_says "$home" w1 working pane busy
  printf 'working [at=%s]: busy\n' "$now" > "$home/state/w1.status"
  printf '{"accounts":{"claude9":{"provider":"claude","claude":"%s/cfg9"}}}\n' "$home" > "$home/config/accounts.json"
  mkdir -p "$home/state/quota-single-flight"
  jq -n --arg dir "$home/cfg9" --argjson at "$((now - 120))" '{("full|0|" + $dir): {at:$at, schemaVersion:5, rows:[
    {provider:"claude", plan:"max", account:{accountId:"acct-123456", email:"captain@example.com"},
     windows:[{id:"seven_day", kind:"weekly", percentUsed:41, resetsAt:"2026-11-10T09:00:00Z"}]}]}}' \
    > "$home/state/quota-single-flight/reads.json"
  in_fleet "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  assert_absent "$home/quota-was-called" "the Bridge triggered a quota read"
  check "$(feed "$home" '.fleet.usage')" 'length == 1 and .[0].seat == "claude9" and .[0].workers == 1
    and (.[0].windows | map(select(.kind == "weekly"))[0].used) == 41
    and (.[0].windows | map(select(.kind == "session"))[0].used) == null' \
    "the usage hint did not read the shared quota record per seat"
  assert_contains "$(render "$home" "$now" | jq -r '.fleet.text')" "5 hours not reported, week 41% used" \
    "the page did not show the reported window and name the missing one"
  for f in "$home/data/bridge/bridge.html" "$home/state/bridge/digest.txt" "$home/state/bridge/feed.json"; do
    grep -q 'captain@example.com\|acct-123456\|cfg9' "$f" && fail "an account field or config path reached $(basename "$f")"
  done
  pass "the usage hint reads shared quota records only, never starts a read, and carries no account details"
}

test_fleet_hierarchy() {
  local home sm sm2 sm3 sm4 now marker out
  home=$(make_home tree)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  crew_stub "$home"
  now=$(date +%s)
  sm="$home-sm"; sm2="$home-sm2"; sm3="$home-sm3"; sm4="$home-sm4"
  mkdir -p "$sm/state" "$sm2/state" "$sm3/state" "$sm4/state"
  fm_write_meta "$home/state/$REG.meta" 'kind=secondmate' "home=$sm" 'harness=claude'
  printf 'working [at=%s]: relaying for %s\n' "$now" "$REG" > "$home/state/$REG.status"
  fm_write_meta "$home/state/zz8far.meta" 'kind=secondmate' 'home=/elsewhere' 'remote_host=boat'
  fm_write_meta "$sm/state/paint.meta" 'kind=ship' 'harness=codex' 'seat=codex1'
  printf 'needs-decision [key=c] [at=%s]: which blue for %s? PR https://github.com/acme/%s/pull/9\n' "$now" "$REG" "$REG" > "$sm/state/paint.status"
  printf '{"valid":false}\n' > "$sm/state/home-summary.json"
  fm_write_meta "$sm/state/zz7mid.meta" 'kind=secondmate' "home=$sm2"
  fm_write_meta "$sm2/state/zz6low.meta" 'kind=secondmate' "home=$sm3"
  fm_write_meta "$sm2/state/zz5loop.meta" 'kind=secondmate' "home=$sm"
  fm_write_meta "$sm3/state/zz4deep.meta" 'kind=secondmate' "home=$sm4"
  fm_write_meta "$sm4/state/hidden.meta" 'kind=ship'
  printf '{"schema":"fm-bridge-names.v1","names":{"%s":"Harbor"}}\n' "$REG" > "$home/config/bridge-names.json"
  marker="$TMP_ROOT/tree-marker"; : > "$marker"; sleep 1
  : > "$home/crew-calls"
  in_fleet "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  out=$(feed "$home" '.fleet')
  check "$out" '(.homes | map(.home)) == ["Firstmate","a secondmate","Harbor","a secondmate","a secondmate","a secondmate","a secondmate"]
    and (.homes | map(.read)) == ["ok","remote","ok","ok","repeated","ok","too-deep"]
    and (.homes | map(.depth)) == [0,1,1,2,3,3,4]
    and ([.homes[] | select(.home == "Harbor")][0] | .inventory_inconsistent and (.rows | map(.title) | index("paint")))
    and .complete == false' \
    "the home tree is not three levels deep with a visited set, remote and too-deep homes named"
  [ ! -s "$home/crew-calls" ] || fail "a secondmate or another home's worker was sent to crew-state: $(cat "$home/crew-calls")"
  check "$(feed "$home" '[.fleet.homes[].rows[] | select(.title == "paint")][0]')" \
    '.state == "blocked" and .pr == null and (.pr_text | test("#9")) and (.now_text | test("Harbor"))' \
    "a secondmate worker's row did not come from its own report with its registry id replaced"
  out=$(render "$home" "$now")
  printf '%s' "$out" | jq -r '.text' | grep -q "$REG\|zz7mid\|zz6low\|zz4deep\|zz8far" && fail "the rendered fleet showed a secondmate registry id"
  grep -q "$REG\|zz7mid\|zz6low\|zz4deep\|zz8far" "$home/data/bridge/bridge.html" "$home/state/bridge/digest.txt" \
    && fail "the published page or digest carries a secondmate registry id"
  check "$out" '(.fleet.banners | any(test("could not be read")))' "a fleet with unread homes did not say so"
  [ -z "$(find "$sm" "$sm2" "$sm3" "$sm4" -newer "$marker" -print 2>/dev/null)" ] || fail "the Bridge wrote into a secondmate's home"
  sleep 1
  printf 'working [at=%s]: mixing paint\n' "$(date +%s)" >> "$sm/state/paint.status"
  in_fleet "$home" "$BRIDGE" refresh
  check "$(feed "$home" '[.fleet.homes[].rows[] | select(.title == "paint")][0]')" '.state == "working"' \
    "a new line in a secondmate worker's log did not trigger a refresh"
  pass "the fleet reads homes three levels deep, never writes into them, and renders no registry id"
}

test_fleet_failure_is_visible() {
  local home now
  home=$(make_home fleetfail)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  crew_stub "$home"
  worker "$home" w1
  crew_says "$home" w1 working pane busy
  printf 'working: hi\n' > "$home/state/w1.status"
  mkdir -p "$home/state/bridge"
  printf 'not a directory\n' > "$home/state/bridge/crew"
  in_fleet "$home" "$BRIDGE" build >/dev/null || fail "a failed fleet read failed the whole build"
  now=$(date +%s)
  check "$(feed "$home" '.fleet')" '.read == "failed"' "a failed fleet read was not published as failed"
  check "$(render "$home" "$now")" '.fleet.banners | any(test("could not be read"))' "the page did not say the fleet is unreadable"
  grep -q '^fleet unavailable data: ' "$home/state/bridge/digest.txt" || fail "the digest did not say the fleet is unavailable"
  rm -f "$home/state/bridge/crew"
  in_fleet "$home" "$BRIDGE" build >/dev/null || fail "rebuild failed"
  check "$(feed "$home" '.fleet')" '.read == "ok" and .counts.total == 1' "the fleet did not recover"
  pass "a fleet that cannot be read is shown as unreadable, never as an empty fleet"
}

test_guard_refreshes_without_watcher() {
  local home i
  home=$(make_home guarded)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  worker "$home" w1
  mkdir -p "$TMP_ROOT/guard-root"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$TMP_ROOT/guard-root" FM_HOME="$home" FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" >/dev/null 2>&1 || true
  i=0
  while [ ! -s "$home/data/bridge/bridge.html" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$home/data/bridge/bridge.html" ] || fail "a guarded command with the watcher down did not refresh the Bridge"
  i=0
  while [ -e "$home/state/bridge/.build.lock" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  pass "with the watcher down, guarded commands keep an enabled Bridge refreshed"
}

test_tasks_feed_and_page() {
  local home now out
  home=$(make_home tasks)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  tasks_in "$home" add pilot "Plan the pilot" --repo web-shop --body "Captain 2026-11-06: plan the pilot with one customer"
  tasks_in "$home" add pilot-mail "Mail the pilot customer" --repo web-shop --blocked-by pilot \
    --body "$(printf 'Picked from suggestion sg-0a1b2c3d, a follow-up of pilot.\nDraft the first mail. token=ghp_abcdefghijklmnopqrstuvwxyz123456')"
  tasks_in "$home" add later-one "A later idea" --body "Origin: scout-review"
  tasks_in "$home" hold later-one --reason "after launch" --until 2099-01-01
  tasks_in "$home" add busy "Being built" --repo web-shop
  worker "$home" busy
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  out=$(feed "$home" '.tasks')
  check "$out" '.read == "ok" and .counts.open == 4 and .counts.waiting == 1 and .counts.later == 1 and .counts.nosource == 1' \
    "the tasks feed did not count its lanes: $out"
  check "$out" '[.rows[] | select(.id == "pilot")][0] | .origin.kind == "captain" and .origin.label == "You asked for this on 2026-11-06"
    and .needed_by == [{id:"pilot-mail", title:"Mail the pilot customer"}] and .keep == null and .project == "web-shop"' \
    "a captain task lost its origin or its dependent"
  check "$out" '[.rows[] | select(.id == "pilot-mail")][0] | .origin.kind == "suggestion" and (.origin.label | contains("Plan the pilot"))
    and .needs == [{id:"pilot", title:"Plan the pilot", state:"open"}] and .lane == "waiting" and (.what | startswith("Draft the first mail"))' \
    "a picked follow-up lost its origin, its blocker or its explainer"
  check "$out" '[.rows[] | select(.id == "later-one")][0] | .origin.label == "Came from: scout-review" and .lane == "later"' \
    "an Origin: line or a dated hold was not read"
  check "$out" '[.rows[] | select(.id == "busy")][0] | .keep == "worker" and (.keep_text | contains("teardown"))' \
    "a task with a worker was offered for removal"
  grep -q ghp_abcdefghijklmnopqrstuvwxyz123456 "$home/data/bridge/bridge.html" && fail "a token in a task note reached the page"
  grep -q '^tasks open=4 ready=1 waiting=1 later=1 ' "$home/state/bridge/digest.txt" || fail "the digest has no tasks line: $(cat "$home/state/bridge/digest.txt")"
  now=$(date +%s)
  out=$(render "$home" "$now" @group=origin)
  check "$out" '.tasks.text | contains("Follow-ups of: Plan the pilot (1)") and contains("You asked for these (1)")' \
    "grouping by origin did not regroup the rows"
  out=$(render "$home" "$now" @open=pilot)
  check "$out" '[.tasks.rows[] | select(.id == "pilot")][0].text | contains("What it is: Captain 2026-11-06: plan the pilot")
    and contains("Where it came from: You asked for this on 2026-11-06") and contains("Needed by: Mail the pilot customer")' \
    "an opened task does not explain what it is, where it came from and what needs it"
  out=$(render "$home" "$now" @select-mode @pick=pilot @pick=later-one @remove-selected)
  check "$out" '.tasks.confirm | contains("Removed now (1): A later idea")
    and contains("Kept (1)") and contains("Plan the pilot - Another open task still needs it")' \
    "the confirmation did not list what goes and what stays with why"
  out=$(render "$home" "$now" @select-mode @select-group=web-shop @remove-selected)
  check "$out" '.tasks.confirm | contains("Removed now (2): Plan the pilot Mail the pilot customer") and (contains("Kept") | not)' \
    "a task and the task that needs it were not removable together"
  out=$(render "$home" "$now" @select-mode @select-shown @remove-selected @confirm-remove)
  check "$out" '.queued | length == 1 and .[0].tag == "choice" and .[0].data.schema == "fm-bridge-action.v1"
    and .[0].data.action == "remove" and (.[0].data.items | map(.id) | sort) == ["later-one","pilot","pilot-mail"]
    and all(.[0].data.items[]; .rev | test("^[0-9a-f]{16}$"))' "Select all shown did not queue one remove of every free row"
  check "$out" '[.tasks.rows[] | select(.pending) | .id] | sort == ["later-one","pilot","pilot-mail"]' "queued rows are not marked"
  out=$(render "$home" "$now" !nolavish @open=pilot @remove-one=pilot @confirm-remove)
  check "$out" '.queued == [] and (.tasks.confirm | contains("only works when this board is open in Lavish"))' \
    "a press outside Lavish claimed to queue"
  pass "the tasks feed explains each task with its origin and both-way links, groups it, and bulk-selects into one confirmed remove"
}

test_intake_applies_remove_and_restore() {
  local home now out sid batch result
  home=$(make_home intake)
  printf '%s\n' "$ENABLED" > "$home/config/bridge.json"
  tasks_in "$home" add a1 "First unwanted"
  tasks_in "$home" add a2 "Second unwanted"
  tasks_in "$home" add a3 "Needs the second" --blocked-by a2
  out=$(in_home "$home" "$BRIDGE" open 2>&1) || fail "open failed: $out"
  sid=$(printf '%s\n' "$out" | sed -n 's/^bound: //p')
  [ -n "$sid" ] || fail "open did not bind the page source: $out"
  now=$(date +%s)
  out=$(render "$home" "$now" @select-mode @pick=a1 @pick=a2 @remove-selected @confirm-remove)
  batch=$(printf '%s' "$out" | jq -r '.queued[0].data.batch')
  mkdir -p "$home/state/procevent-inbox"
  result="$home/state/procevent-inbox/$sid.1.result"
  capture "$result" "$(printf '%s' "$out" | jq -c '.queued')"
  capture "$TMP_ROOT/outside.result" "$(printf '%s' "$out" | jq -c '.queued')"
  out=$(in_home "$home" "$ROOT/bin/fm-bridge-intake.sh" "$TMP_ROOT/outside.result" 2>&1) && fail "a result outside the capture inbox was applied"
  cp "$result" "$home/state/procevent-inbox/lavish-0000000000000000.1.result"
  out=$(in_home "$home" "$ROOT/bin/fm-bridge-intake.sh" "$home/state/procevent-inbox/lavish-0000000000000000.1.result" 2>&1) \
    && fail "a result from another source was applied"
  assert_contains "$out" "not this home's Bridge" "a foreign source was not named"
  printf 'off\n' > "$home/config/bridge-actions"
  out=$(in_home "$home" "$ROOT/bin/fm-bridge-intake.sh" "$result" 2>&1) && fail "the kill switch did not stop the press"
  rm -f "$home/config/bridge-actions"
  out=$(in_home "$home" "$ROOT/bin/fm-bridge-intake.sh" "$result") || fail "the intake failed: $out"
  assert_contains "$out" "press remove batch=$batch items=1" "the receipt does not name the press"
  assert_contains "$out" "removed a1" "the intake did not remove the free task"
  (cd "$home" && tasks-axi list) | grep -q '^  a1,' && fail "a1 is still listed"
  jq -s -e --arg sid "$sid" 'any(.[]; .id == "a1" and (.by | contains($sid)) and (.by | contains("press")))' \
    "$home/data/forgotten-index.jsonl" >/dev/null || fail "the removal does not record the press it came from"
  out=$(in_home "$home" "$ROOT/bin/fm-bridge-intake.sh" "$result")
  assert_contains "$out" "already applied" "a repeated wake applied the press twice"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "rebuild failed"
  out=$(render "$home" "$now")
  check "$out" '.tasks.text | contains("Removed, restorable for 90 days (1)") and contains("Last results (1)") and contains("removed a1")' \
    "the page does not show the removed list and the receipt"
  out=$(render "$home" "$now" "@restore-one=a1")
  check "$out" '.queued[0].data | .action == "restore" and .items == [{id:"a1"}]' "Restore did not queue a restore of the row"
  capture "$home/state/procevent-inbox/$sid.2.result" "$(printf '%s' "$out" | jq -c '.queued')"
  out=$(in_home "$home" "$ROOT/bin/fm-bridge-intake.sh" "$home/state/procevent-inbox/$sid.2.result") || fail "the restore intake failed: $out"
  assert_contains "$out" "restored a1" "the intake did not restore the row"
  (cd "$home" && tasks-axi list) | grep -q '^  a1,' || fail "a1 did not come back"
  pass "the intake applies a Bridge press only from this home's bound capture, once, records the press, and restores"
}

fm_test_run test_config_gate test_keyed_question_lifecycle test_hold_answer_path \
  test_secondmate_export_and_names test_never_falsely_green test_redaction_and_escaping \
  test_digest_and_bounds test_incremental_reads test_refresh_retention test_watcher_tick \
  test_alerts_fire_once_per_step test_deadline_clock_on_the_card test_nudge_and_parked_work \
  test_fleet_flags_and_crew_cache test_fleet_usage_never_triggers_quota test_fleet_hierarchy \
  test_fleet_failure_is_visible test_guard_refreshes_without_watcher \
  test_tasks_feed_and_page test_intake_applies_remove_and_restore
