#!/usr/bin/env bash
# Behavior tests for the live project board: bin/fm-live-board.sh build,
# refresh and open, the shipped page rendered through
# tests/assets/live-board-render-harness.mjs, the watcher's refresh tick, and
# the guarded answer path from a captured Lavish choice through
# bin/fm-procevent-lavish.sh into bin/fm-captain-hold.sh. Assertions are on
# published files, rendered output and task state, never on source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/bin/fm-live-board.sh"
HARNESS="$ROOT/tests/assets/live-board-render-harness.mjs"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-board)
WATCH_PID=

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

ENABLED='{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}'

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  chmod 700 "$home" "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  # A protocol-shaped Lavish stub: opening lists the board open, poll blocks.
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
render() {  # <home> [now-epoch] [answer-spec...]
  local home=$1
  shift
  node "$HARNESS" "$home/data/live-board/board.html" "$@"
}
check() { printf '%s\n' "$1" | jq -e "$2" >/dev/null || fail "$3: $1"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# --- Config gate ---------------------------------------------------------------
home=$(make_home config)
out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open succeeded without a config"
assert_contains "$out" "live board is off" "a missing config did not say the board is off"
in_home "$home" "$LIVE" refresh || fail "refresh with no config failed"
assert_absent "$home/data/live-board/board.html" "refresh built a board that was never enabled"
for bad in '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":5}' \
  '{"schema":"fm-live-board-config.v1","enabled":"yes"}' \
  '{"schema":"fm-live-board-config.v1","enabled":true,"extra":1}' \
  '{"schema":"future.v2","enabled":true}' 'not json'; do
  printf '%s\n' "$bad" > "$home/config/live-board.json"
  out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open accepted an invalid config: $bad"
  assert_contains "$out" "config is invalid" "an invalid config was not named invalid: $bad"
done
in_home "$home" "$LIVE" refresh || fail "refresh with an invalid config failed its caller"
assert_absent "$home/data/live-board/board.html" "refresh built a board from an invalid config"
assert_grep "config is invalid" "$home/state/.live-board-refresh.log" \
  "refresh did not log the invalid config"
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":false}' > "$home/config/live-board.json"
out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open accepted a disabled board"
assert_contains "$out" "enabled to false" "a disabled board did not say so"
printf '%s\n' "$ENABLED" > "$TMP_ROOT/linked.json"
rm -f "$home/config/live-board.json"
ln -s "$TMP_ROOT/linked.json" "$home/config/live-board.json"
out=$(in_home "$home" "$LIVE" open 2>&1) && fail "open followed a symlinked config"
assert_contains "$out" "not a regular file" "a symlinked config was not refused"
pass "the board stays off unless a regular, valid, enabled config opts in"

# --- Empty fleet ---------------------------------------------------------------
home=$(make_home empty)
printf -- '- quiet [local-only] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
in_home "$home" "$LIVE" build | grep -q '^board: ' || fail "build did not report the board path"
[ "$(in_home "$home" "$LIVE" path)" = "$home/data/live-board/board.html" ] \
  || fail "path does not name the published board"
out=$(render "$home")
check "$out" '.empty != null and (.empty | test("No open work"))
  and (.projects | length == 0) and .idle.count == 1 and .idle.names == ["quiet"]
  and .stats.open_tasks == 0 and .stats.questions == 0 and .freshness == "live"' \
  "an empty fleet did not render the explicit empty state"
pass "an empty fleet renders No open work with idle registered projects folded away"

# --- Large fleet ---------------------------------------------------------------
home=$(make_home large)
printf -- '- big [local-only] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
long=$(printf '%*s' 70000 '' | tr ' ' x)
tasks_in "$home" add big-a "$long" --repo big --kind ship
tasks_in "$home" add big-b "$long" --repo big --kind ship
out=$(in_home "$home" "$LIVE" build 2>&1) || fail "a board past the env-string limit did not build: $out"
[ "$(wc -c < "$home/data/live-board/board.html")" -gt 140000 ] \
  || fail "the large-fleet fixture did not produce a payload past the env-string limit"
check "$(render "$home")" '.stats.open_tasks == 2 and (.projects[0].tasks | map(.id) | sort) == ["big-a","big-b"]' \
  "a large board lost its open work"
pass "a board whose payload exceeds one environment string still builds and renders"

# --- Projects, questions and tasks ---------------------------------------------
home=$(make_home fleet)
printf -- '- web-shop [no-mistakes] - fixture (added 2026-01-01)\n- data [direct-PR] - fixture (added 2026-01-01)\n' \
  > "$home/data/projects.md"
tasks_in "$home" add redesign "Redesign checkout" --repo web-shop --kind ship
tasks_in "$home" add retry "Retry payments" --repo web-shop --kind ship
tasks_in "$home" add export "Nightly export" --repo data --kind ship
tasks_in "$home" add carrier "Which carrier?" --repo web-shop --kind captain --priority 1
tasks_in "$home" add window "Move the window?" --repo data --kind captain
tasks_in "$home" add legacy 'Logo </script><b>x</b>' --repo web-shop --kind captain
tasks_in "$home" add note-only "Name the release" --repo data --kind captain
printf '%s\n' '{"schema":"fm-captain-question.v1","close":"done","options":[{"value":"dhl","label":"DHL"},{"value":"postnl","label":"PostNL"}],"recommendation":"postnl"}' > "$home/ctx-done.json"
printf '%s\n' '{"schema":"fm-captain-question.v1","close":"release","options":[{"value":"keep","label":"Keep"},{"value":"move","label":"Move"}]}' > "$home/ctx-release.json"
printf '%s\n' '{"schema":"fm-captain-question.v1","close":"done"}' > "$home/ctx-note.json"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold carrier --reason "Pick a carrier." --context-file "$home/ctx-done.json" >/dev/null \
  || fail "could not hold the carrier question"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold window --reason "Load overlaps." --context-file "$home/ctx-release.json" >/dev/null \
  || fail "could not hold the window question"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold legacy --reason "Old hold." >/dev/null \
  || fail "could not hold the legacy question"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold note-only --reason "Free answer." --context-file "$home/ctx-note.json" >/dev/null \
  || fail "could not hold the note-only question"
fm_write_meta "$home/state/redesign.meta" 'kind=ship' 'harness=claude' 'project=web-shop' \
  'pr=https://github.com/example/web-shop/pull/42'
printf '%s\n' "$ENABLED" > "$home/config/live-board.json"
in_home "$home" "$LIVE" build >/dev/null || fail "the fleet board did not build"
now=$(date +%s)
out=$(render "$home" "$now")
check "$out" '.stats.questions == 4 and .stats.urgent_questions == 1
  and (.projects | map(.label)) == ["web-shop","data"]
  and .projects[0].questions[0].id == "carrier" and .projects[0].questions[0].urgent
  and (.projects[0].questions | map(.id)) == ["carrier","legacy"]
  and (.projects[1].questions | map(.id) | sort) == ["note-only","window"]' \
  "projects or their questions were not ordered by the snapshot"
check "$out" '(.projects[0].questions[0] | .answerable and .mode == "Answering closes this question."
    and .options == [{value:"dhl",label:"DHL",recommended:false},{value:"postnl",label:"PostNL",recommended:true}]
    and (.lavishQuestion | startswith("live-board:carrier#")))
  and (.projects[1].questions[] | select(.id == "window") | .answerable
    and .mode == "Answering releases the hold so the work continues.")
  and (.projects[1].questions[] | select(.id == "note-only") | .answerable and .options == [])
  and (.projects[0].questions[1] | (.answerable | not) and .readonly.status == "legacy"
    and .title == "Logo </script><b>x</b>")' \
  "owner context did not drive answer controls, or a legacy call became answerable"
check "$out" '(.projects[0].tasks | map(.id) | sort) == ["redesign","retry"]
  and (.projects[0].tasks[] | select(.id == "redesign") | .links) == ["https://github.com/example/web-shop/pull/42"]
  and (.projects[1].tasks | map(.id)) == ["export"]' \
  "open work rows duplicated question cards or lost the recorded PR link"
pass "projects lead with their ordered questions, owner context drives controls, and open work follows"

# --- Queued answers carry the owner's guard ------------------------------------
out=$(render "$home" "$now" 'carrier=postnl:cheaper' 'window=' 'note-only=:Call it Tidewater' 'legacy=x')
check "$out" '(.queued | length == 2)
  and .queued[0].tag == "choice"
  and (.queued[0].data | .schema == "fm-bearings-answer.v1" and .question == "carrier"
    and .selection == "postnl" and .note == "cheaper" and .close == "done"
    and (.lifecycle | test("^[0-9T:Z-]+#0$")))
  and (.queued[1].data | .question == "note-only" and .selection == "" and .note == "Call it Tidewater")
  and (.submits[] | select(.id == "window") | .queuedClass == false)
  and (.submits[] | select(.id == "legacy") | .status == "no-form")' \
  "a queued answer lost its close mode or lifecycle, or an empty answer queued"
pass "Queue answer emits one choice with the owner close mode and lifecycle"

# --- Local freshness ----------------------------------------------------------
check "$(render "$home" "$((now + 400))")" '.freshness == "stale" and .banner == ""' \
  "an old board did not mark itself stale"
check "$(render "$home" "$((now + 4000))")" '.freshness == "unavailable" and (.banner | test("rebuilt"))' \
  "a board whose refresh stopped did not say it is out of date"
pass "the page ages its own data from live to stale to out of date"

# --- Refresh timing and failure retention --------------------------------------
board="$home/data/live-board/board.html"
before=$(mtime "$board")
in_home "$home" "$LIVE" refresh
[ "$(mtime "$board")" = "$before" ] || fail "refresh rebuilt a board that was not yet due"
touch -t 202001010000 "$board"
in_home "$home" "$LIVE" refresh
[ "$(( $(date +%s) - $(mtime "$board") ))" -lt 60 ] || fail "refresh did not rebuild a due board"
cp "$board" "$TMP_ROOT/last-good.html"
touch -t 202001010000 "$board"
chmod 500 "$home/data/live-board"
in_home "$home" "$LIVE" refresh || fail "a failed refresh changed its exit status"
chmod 700 "$home/data/live-board"
cmp -s "$board" "$TMP_ROOT/last-good.html" || fail "a failed refresh replaced the last good board"
assert_grep "cannot stage" "$home/state/.live-board-refresh.log" "a failed refresh was not logged"
pass "refresh rebuilds only when due and keeps the last good board on failure"

# --- Open: serve, bind before arm ----------------------------------------------
out=$(in_home "$home" "$LIVE" open 2>&1) || fail "open failed: $out"
assert_contains "$out" "session: live" "open did not prove the session live"
sid=$(printf '%s\n' "$out" | sed -n 's/^bound: //p')
[ -n "$sid" ] || fail "open did not bind the board source: $out"
assert_contains "$out" "armed: $sid" "open did not arm the bound source"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" binding "$sid" >/dev/null \
  || fail "the armed source has no keyed-answer binding"
pass "open serves the board, binds its answers, then arms the source"

# --- Guarded answers through the Lavish adapter --------------------------------
lifecycle=$(render "$home" "$now" 'carrier=postnl' | jq -r '.queued[0].data.lifecycle')
window_lifecycle=$(render "$home" "$now" 'window=move' | jq -r '.queued[0].data.lifecycle')
row() {  # <n> <question> <selection> <extra-context-members>
  printf '  "%s","Answer\\n\\nContext data:\\n{\\"schema\\": \\"fm-bearings-answer.v1\\", \\"question\\": \\"%s\\", \\"selection\\": \\"%s\\", \\"note\\": \\"\\"%s}","form",choice,"%s -> %s"\n' \
    "$1" "$2" "$3" "$4" "$2" "$3"
}
result="$TMP_ROOT/captured.result"
{
  printf 'status: feedback\nprompts[4]{id,prompt,selector,tag,text}:\n'
  row 1 carrier postnl ", \\\"close\\\": \\\"done\\\", \\\"lifecycle\\\": \\\"$lifecycle\\\""
  row 2 window move ', \"close\": \"release\", \"lifecycle\": \"2020-01-01T00:00:00Z#0\"'
  row 3 forged yes ', \"close\": \"done\", \"lifecycle\": \"bad\\tlife#0\"'
  row 4 nomode yes ', \"lifecycle\": \"2020-01-01T00:00:00Z#0\"'
} > "$result"
rows=$(in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" answers "$result")
[ "$(printf '%s\n' "$rows" | cut -f1,2,4,5)" = "$(printf 'carrier\tpostnl\tdone\t%s\nwindow\tmove\trelease\t2020-01-01T00:00:00Z#0' "$lifecycle")" ] \
  || fail "the adapter did not relay exactly the well-formed guarded rows: $rows"
out=$(printf '%s\n' "$rows" | in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source "fixture capture" 2>&1)
assert_contains "$out" "closed: carrier" "a current guarded answer did not close its question"
assert_contains "$out" "skipped: window (stale captain question lifecycle)" \
  "an answer for an earlier hold was not refused by the lifecycle guard"
show=$(cd "$home" && tasks-axi show carrier --full)
assert_contains "$show" "state: done" "the answered question stayed open"
assert_contains "$show" "Captain answer lifecycle: $lifecycle" "the answer did not record its guarded lifecycle"
show=$(cd "$home" && tasks-axi show window --full)
assert_contains "$show" "held: yes" "a refused stale answer released the newer hold"
[ "$window_lifecycle" != "2020-01-01T00:00:00Z#0" ] || fail "the fixture lifecycle collided with the stale guard"
touch -t 202001010000 "$board"
in_home "$home" "$LIVE" refresh
check "$(render "$home")" '[.projects[].questions[].id] | index("carrier") == null' \
  "the next refresh still showed an answered question"
pass "guarded answers close the current question, refuse stale ones, and clear on refresh"

# --- The watcher drives refresh -----------------------------------------------
home=$(make_home watched)
printf '%s\n' "$ENABLED" > "$home/config/live-board.json"
PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  "$WATCH" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
while [ ! -s "$home/data/live-board/board.html" ] && [ "$i" -lt 300 ]; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
kill -KILL "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" >/dev/null 2>&1 || true
WATCH_PID=
[ -s "$home/data/live-board/board.html" ] \
  || fail "the watcher did not publish an enabled board: $(cat "$TMP_ROOT/watch.err" 2>/dev/null)"
check "$(render "$home")" '.empty != null' "the watcher-published board did not render"
pass "a running watcher keeps an enabled board published"
