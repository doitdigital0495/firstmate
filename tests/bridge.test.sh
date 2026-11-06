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
  } > "$home/state/w1.status"
  in_home "$home" "$BRIDGE" build >/dev/null || fail "build failed"
  for f in "$home/data/bridge/bridge.html" "$home/state/bridge/digest.txt" "$home/state/bridge/asks.json"; do
    grep -q "$token" "$f" && fail "a planted token reached $(basename "$f")"
    grep -q 's3cr3tvalue' "$f" && fail "a URL query reached $(basename "$f")"
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
  printf '%s\n' "$out" | head -1 | grep -q '^bridge v1 checked=.* sources=2/2$' || fail "the digest header is wrong: $out"
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

fm_test_run test_config_gate test_keyed_question_lifecycle test_hold_answer_path \
  test_secondmate_export_and_names test_never_falsely_green test_redaction_and_escaping \
  test_digest_and_bounds test_incremental_reads test_refresh_retention test_watcher_tick
