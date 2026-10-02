#!/usr/bin/env bash
# Behavior tests for strict milestone emission, durations and review coverage.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
TMP_ROOT=$(fm_test_tmproot milestones)
unset FM_DATA_OVERRIDE
export FM_HOME="$TMP_ROOT/other-home"
TOOL="$ROOT/bin/fm-task-milestones.sh"
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
FILE="$TMP_ROOT/cycle.status"

stamp() { "$TOOL" stamp "$FILE" "$@" -- 'observed proof'; }
reject() {
  local before
  before=$(wc -c < "$FILE")
  if "$TOOL" stamp "$FILE" "$@" -- evidence 2>/dev/null; then fail 'accepted invalid milestone'; fi
  [ "$(wc -c < "$FILE")" = "$before" ] || fail 'invalid stamp wrote bytes'
}

: > "$FILE"
for bad in at=bad at=01 at=1000000000000; do reject brief "$bad"; done
reject brief at=10 at=11
reject brief at=10 typo=x
reject local-proof at=10
reject local-proof at=10 sha=short
reject gate-end at=10 sha="$SHA" run=gate rounds=01 result=passed
reject gate-end at=10 sha="$SHA" run=gate result=passed
reject data-ready at=10 sha="$SHA" snapshot='contains space'
reject dev-accepted at=10 sha="$SHA" snapshot=v1 result=waived
reject unknown at=10
reject merge at=10 sha="$SHA"
reject brief at=10 name=brief
if "$TOOL" stamp "$FILE" brief at=10 -- $'two\nlines' 2>/dev/null; then fail 'accepted multiline evidence'; fi
if "$TOOL" stamp "$FILE" brief at=10 -- '  ' 2>/dev/null; then fail 'accepted blank evidence'; fi
pass 'strict milestone schema refuses malformed epochs, duplicates, extra/missing fields and false acceptance without writing'

stamp brief at=100
stamp local-proof at=110 sha="$SHA"
stamp gate-start at=120 sha="$SHA" run=gate1
stamp gate-end at=130 sha="$SHA" run=gate1 rounds=2 result=failed
# Retried outcome replaces counts, not a second failed run.
stamp gate-end at=130 sha="$SHA" run=gate1 rounds=2 result=failed
stamp gate-start at=140 sha="$SHA" run=gate2
stamp gate-end at=150 sha="$OTHER" run=gate2 rounds=3 result=passed
"$TOOL" stamp "$FILE" pr-created at=151 sha="$OTHER" -- 'https://github.com/example/repo/pull/1'
"$TOOL" stamp "$FILE" merge at=160 sha="$OTHER" -- 'https://github.com/example/repo/pull/1'
stamp dev-deploy at=170 sha="$OTHER"
stamp data-ready at=180 sha="$OTHER" snapshot=v1
stamp first-live-proof at=190 sha="$OTHER" snapshot=v1 result=failed
# Acceptance after a failed/partial/waived first proof cannot yield a duration.
stamp dev-accepted at=195 sha="$OTHER" snapshot=v1 result=passed
out=$("$TOOL" durations "$FILE")
assert_contains "$out" $'cycle\tunknown\tunknown\t2\t5\t3\t1' 'failed live proof counted as DEV acceptance or wrong rounds'
stamp first-live-proof at=200 sha="$OTHER" snapshot=v1 result=passed
stamp dev-accepted at=210 sha="$OTHER" snapshot=v1 result=passed
"$TOOL" stamp "$FILE" uat-merge at=220 sha="$SHA" -- 'https://github.com/example/repo/pull/2'
stamp uat-deploy at=230 sha="$SHA"
stamp uat-data-ready at=240 sha="$SHA" snapshot=v1
stamp uat-live-proof at=250 sha="$SHA" snapshot=v1 result=passed
stamp uat-accepted at=260 sha="$SHA" snapshot=v1 result=passed
out=$("$TOOL" durations "$FILE")
assert_contains "$out" $'cycle\t110\t50\t2\t5\t3\t1' 'wrong actual phase durations/round counts'
pass 'readback distinguishes deploy/data/live/acceptance and deduplicates gate rounds and failures by run'

for proof in partial waived; do
  FILE="$TMP_ROOT/$proof.status"
  stamp brief at=100
  stamp dev-deploy at=110 sha="$SHA"
  stamp data-ready at=120 sha="$SHA" snapshot=v1
  stamp first-live-proof at=130 sha="$SHA" snapshot=v1 result="$proof"
  stamp dev-accepted at=140 sha="$SHA" snapshot=v1 result=passed
  assert_contains "$("$TOOL" durations "$FILE")" $'\tunknown\tunknown\t0\t0\t0\t0' 'non-passing proof counted as accepted'
done
FILE="$TMP_ROOT/mismatch.status"
stamp brief at=200
stamp dev-deploy at=210 sha="$SHA"
stamp data-ready at=220 sha="$OTHER" snapshot=v1
stamp first-live-proof at=230 sha="$SHA" snapshot=v1 result=passed
stamp dev-accepted at=240 sha="$SHA" snapshot=v1 result=passed
assert_contains "$("$TOOL" durations "$FILE")" $'\tunknown\tunknown' 'different deployed SHA snapshot counted as accepted'
stamp data-ready at=250 sha="$SHA" snapshot=v1
stamp first-live-proof at=260 sha="$SHA" snapshot=v2 result=passed
stamp dev-accepted at=270 sha="$SHA" snapshot=v2 result=passed
assert_contains "$("$TOOL" durations "$FILE")" $'\tunknown\tunknown' 'different data snapshot counted as accepted'
stamp gate-end at=280 sha="$SHA" run=unmatched rounds=1 result=failed
assert_contains "$("$TOOL" durations "$FILE")" $'\t0\tunknown\tunknown\tunknown' 'unmatched gate end claimed measured counts'
printf 'milestone [at=bad] [name=brief]: malformed\n' >> "$FILE"
assert_contains "$("$TOOL" durations "$FILE")" $'mismatch\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown' 'malformed stamp fell back to older timing'
assert_contains "$("$TOOL" durations "$TMP_ROOT/absent.status")" $'absent\tunknown\tunknown' 'missing milestone file invented timing'
FILE="$TMP_ROOT/reversed.status"
stamp brief at=1000
stamp dev-deploy at=100 sha="$SHA"
stamp data-ready at=110 sha="$SHA" snapshot=v1
stamp first-live-proof at=120 sha="$SHA" snapshot=v1 result=passed
stamp dev-accepted at=130 sha="$SHA" snapshot=v1 result=passed
assert_contains "$("$TOOL" durations "$FILE")" $'reversed\tunknown\tunknown' 'reversed brief-to-acceptance became a duration'
ln -s "$FILE" "$TMP_ROOT/linked.status"
if "$TOOL" stamp "$TMP_ROOT/linked.status" brief at=10 -- evidence 2>/dev/null; then fail 'writer followed status symlink'; fi
assert_contains "$("$TOOL" durations "$TMP_ROOT/linked.status")" $'linked\tunknown\tunknown' 'reader trusted a status symlink'
pass 'missing, malformed, reversed, partial, waived and mismatched phase evidence stays unknown'

FILE="$TMP_ROOT/state.status"
printf 'paused [at=100]: waiting for scheduled release\n' > "$FILE"
stamp brief at=110
[ "$(last_status_line "$FILE")" = 'paused [at=100]: waiting for scheduled release' ] || fail 'measurement hid paused state'
status_is_paused "$(status_current_line "$FILE" ship)" || fail 'measurement changed paused classification'
printf 'blocked [at=120] [key=decision]: need authority\n' >> "$FILE"
stamp local-proof at=130 sha="$SHA"
assert_contains "$(status_open_decisions "$FILE")" $'decision\tblocked\tneed authority' 'measurement closed decision'
status_is_captain_relevant "$(tail -1 "$FILE")" && fail 'measurement prose triggered terminal wake'
printf 'done [at=140]: delivered\n' >> "$FILE"
stamp dev-deploy at=150 sha="$SHA"
[ "$(last_status_line "$FILE")" = 'done [at=140]: delivered' ] || fail 'post-delivery measurement hid done state'
# Malformed milestone metadata remains measurement, never a terminal event.
printf 'milestone [at=bad] [name=unknown]: merged PR ready\n' >> "$FILE"
[ "$(last_status_line "$FILE")" = 'done [at=140]: delivered' ] || fail 'malformed measurement hid done'
status_is_captain_relevant "$(tail -1 "$FILE")" && fail 'malformed measurement triggered terminal wake'
pass 'milestone records never hide worker states, open decisions or terminal outcomes'

# The daemon's run record: head_sha is the run's current head and
# review_approved_head_sha the head its review step approved.
NM_HOME="$TMP_ROOT/nm"
mkdir -p "$NM_HOME"
python3 - "$NM_HOME/state.sqlite" "$SHA" "$OTHER" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE runs (id TEXT PRIMARY KEY, head_sha TEXT NOT NULL, review_approved_head_sha TEXT)")
db.executemany("INSERT INTO runs VALUES (?, ?, ?)", [
    ("covered", sys.argv[2], sys.argv[2]),
    ("moved", sys.argv[3], sys.argv[2]),
    ("unreviewed", sys.argv[2], None),
])
db.commit()
PY
coverage() { NM_HOME="$NM_HOME" "$TOOL" coverage "$@"; }
[ "$(coverage covered "$SHA")" = covered ] || fail 'reviewed current head not covered'
[ "$(coverage covered "$OTHER")" = stale ] || fail 'other head reported covered'
[ "$(coverage moved "$OTHER")" = stale ] || fail 'fix after review reported covered'
[ "$(coverage moved "$SHA")" = stale ] || fail 'superseded head reported covered'
[ "$(coverage unreviewed "$SHA")" = unverified ] || fail 'unreviewed run reported covered'
[ "$(coverage absent "$SHA")" = unverified ] || fail 'unknown run reported covered'
[ "$(NM_HOME="$TMP_ROOT/missing" "$TOOL" coverage covered "$SHA")" = unverified ] || fail 'missing run record reported covered'
if "$TOOL" coverage covered short 2>/dev/null; then fail 'accepted abbreviated sha'; fi
pass 'review coverage is covered only when the run record reviewed its exact current head'

mkdir -p "$TMP_ROOT/torn-home/state"
FILE="$TMP_ROOT/torn-home/state/never.status"
if "$TOOL" stamp "$FILE" dev-deploy sha="$SHA" -- deployed 2>/dev/null; then fail 'late stamp without a task record succeeded'; fi
[ ! -e "$FILE" ] || fail 'late stamp without a task record created an orphan status log'
FILE="$TMP_ROOT/torn-home/state/torn.status"
printf 'working [at=90]: building\n' > "$FILE"
stamp brief at=100
stamp gate-start at=110 sha="$SHA" run=gate1
stamp gate-end at=120 sha="$SHA" run=gate1 rounds=1 result=passed
"$TOOL" archive "$FILE"
"$TOOL" archive "$FILE"
rm -f "$FILE"
"$TOOL" archive "$FILE"
[ -f "$TMP_ROOT/torn-home/data/torn/milestones.status" ] || fail 'archive not beside the task state directory'
[ "$("$TOOL" records "$FILE" | wc -l | tr -d ' ')" = 3 ] || fail 'retried archive duplicated or lost milestones'
stamp dev-deploy at=200 sha="$SHA"
stamp data-ready at=210 sha="$SHA" snapshot=v1
stamp first-live-proof at=220 sha="$SHA" snapshot=v1 result=passed
stamp dev-accepted at=230 sha="$SHA" snapshot=v1 result=passed
stamp uat-deploy at=300 sha="$SHA"
stamp uat-data-ready at=310 sha="$SHA" snapshot=v1
stamp uat-live-proof at=320 sha="$SHA" snapshot=v1 result=passed
stamp uat-accepted at=330 sha="$SHA" snapshot=v1 result=passed
[ ! -e "$FILE" ] || fail 'late stamp recreated an orphan status log'
assert_contains "$("$TOOL" durations "$FILE")" $'torn\t130\t100\t1\t1\t0\t0' 'post-teardown phases lost the brief or gate history'
grep -q '^working' "$TMP_ROOT/torn-home/data/torn/milestones.status" && fail 'archive copied worker state lines'
pass 'teardown archive keeps milestones durable and late stamps append there without an orphan status log'

FILE="$TMP_ROOT/deadlines.status"
stamp brief at=50
stamp local-proof at=100 sha="$SHA"
[ -z "$("$TOOL" deadlines "$FILE" 999)" ] || fail 'dispatch deadline fired early'
assert_contains "$("$TOOL" deadlines "$FILE" 1000)" 'gate dispatch overdue: no gate-start 15 minutes after local proof at 100' '15-minute dispatch deadline missed'
[ "$("$TOOL" deadlines "$FILE" 1000)" = "$("$TOOL" deadlines "$FILE" 5000)" ] || fail 'deadline text changed with age and would re-wake'
stamp gate-start at=1010 sha="$SHA" run=gate1
[ -z "$("$TOOL" deadlines "$FILE" 1011)" ] || fail 'dispatched gate still overdue'
stamp gate-obsolete at=1100 sha="$SHA" run=gate1
[ -z "$("$TOOL" deadlines "$FILE" 2899)" ] || fail 'obsolete escalation deadline fired early'
assert_contains "$("$TOOL" deadlines "$FILE" 2900)" 'obsolete gate escalation due: run gate1 obsolete 30 minutes since 1100' '30-minute obsolete escalation deadline missed'
stamp gate-start at=2901 sha="$OTHER" run=gate2
[ -z "$("$TOOL" deadlines "$FILE" 5000)" ] || fail 'successor run did not clear obsolete deadline'
pass 'dispatch and obsolete-run targets are readable at exact 15/30-minute boundaries'

FILE="$TMP_ROOT/live-clock.status"
start=$(date +%s)
stamp brief
end=$(date +%s)
epoch=$(status_line_at_epoch "$(tail -1 "$FILE")")
[ "$epoch" -ge "$start" ] && [ "$epoch" -le "$end" ] || fail 'stamp did not use actual clock'
home="$TMP_ROOT/home"
mkdir -p "$home/data"
for kind in ship scout; do
  if [ "$kind" = ship ]; then
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" repo --mode no-mistakes >/dev/null
  else
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$kind" repo --scout >/dev/null
  fi
  "$TOOL" records "$home/state/$kind.status" | grep -q $'^brief\t[0-9]' || fail 'scaffold did not stamp actual brief'
done
if FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship repo --mode no-mistakes 2>/dev/null; then fail 'duplicate scaffold accepted'; fi
[ "$("$TOOL" records "$home/state/ship.status" | wc -l | tr -d ' ')" = 1 ] || fail 'failed duplicate scaffold wrote second brief time'
pass 'writers stamp actual clock and successful brief creation exactly once'
