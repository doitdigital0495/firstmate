#!/usr/bin/env bash
# fm-send firstmate-imposed holds (--hold / --release-hold) behavior.
#
# A steer where firstmate itself imposes a hold - telling a worker or
# secondmate to hold, or start nothing - used to be plain steering text with
# no record and no clock, so it could stall a target indefinitely with
# nothing to wake firstmate. These tests drive the real fm-send executable
# over stubbed transports and assert the record through the real consumer
# fold (bin/fm-classify-lib.sh's status_open_imposed_hold) and the real
# watcher tick (bin/fm-watch.sh), never through source text:
#   1. --hold delivers the instruction exactly as typed AND records the hold
#      with the expiry clock set at imposition; the notice names the renew and
#      release commands.
#   2. --hold=<seconds> sets that hold's clock; the record never re-wakes the
#      home that wrote it, and a later line on the same task still does.
#   3. The watcher wakes exactly once on what fm-send wrote, with the renew
#      and release commands in the reason.
#   4. --release-hold closes the hold (matching id, or none needed); a wrong
#      id and a release with nothing open refuse BEFORE anything is sent.
#   5. Flag misuse (empty message, --key, --resolve-key, explicit backend
#      target, malformed seconds) refuses before anything is sent.
#   6. A release still cleans up after a worker finishes, without allowing
#      --hold to bypass the finished-worker reuse guard. A remote secondmate's
#      hold is the same local record, with only the message crossing transport.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-hold)

# The same stubs fm-send-resolve-key uses: tmux logs literal typed text and
# reports an empty composer, fake-ssh records the remote invocation.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows)
    printf '%s\n' fm-t1 fm-t2 fm-t3 fm-t4 fm-t5 fm-t6 fm-t7 fm-t8 fm-t9 fm-mate elsewhere
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes a fresh home dir with empty state/ and config/
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# send_err <err-file> <fakebin> <home> <send-log> <fm-send args...>
send_err() {
  local err=$1 fb=$2 home=$3 log=$4; shift 4
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>"$err"
}

run_send() {  # <fakebin> <home> <send-log> <fm-send args...>
  local fb=$1 home=$2 log=$3; shift 3
  send_err /dev/null "$fb" "$home" "$log" "$@"
}

# fold_open <home> <task> -> the id/at/until row of the open imposed hold
fold_open() {
  FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/fm-classify-lib.sh"
    status_open_imposed_hold "$2/$3.status"
  ' _ "$ROOT" "$1/state" "$2"
}

test_hold_delivers_and_records() {
  local dir fb log home err rc row span
  dir="$TMP_ROOT/impose"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home impose)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'working [at=100]: started\n' > "$home/state/t1.status"

  send_err "$err" "$fb" "$home" "$log" t1 --hold "hold until 2030-01-02T03:04Z pending vendor confirmation"; rc=$?
  expect_code 0 "$rc" "a hold send should succeed"
  grep -qF "hold until 2030-01-02T03:04Z pending vendor confirmation" "$home/state/t1.inbox/001.msg" \
    || fail "the hold instruction did not reach the worker's durable inbox record"
  grep -qF 'notice: firstmate hold imposed on t1' "$err" \
    || fail "the impose notice is missing from stderr: $(cat "$err")"
  grep -qF -- '--hold "<reason>"' "$err" \
    || fail "the notice does not name the renew command: $(cat "$err")"
  row=$(fold_open "$home" t1) || fail "no imposed hold reads back open: $(cat "$home/state/t1.status")"
  span=$(( $(printf '%s' "$row" | cut -f3) - $(printf '%s' "$row" | cut -f2) ))
  [ "$span" -eq 1800 ] \
    || fail "default expiry is not the thirty-minute clock (span ${span}s): $row"
  pass "--hold delivers the instruction and records an expiring hold"
}

test_custom_clock_and_self_announced() {
  local dir fb log home rc row span
  dir="$TMP_ROOT/clock"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home clock)
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship"
  printf 'working [at=100]: started\n' > "$home/state/t2.status"

  run_send "$fb" "$home" "$log" t2 --hold=5 "brief hold"; rc=$?
  expect_code 0 "$rc" "a custom-clock hold send should succeed"
  row=$(fold_open "$home" t2) || fail "custom-clock hold did not record"
  span=$(( $(printf '%s' "$row" | cut -f3) - $(printf '%s' "$row" | cut -f2) ))
  [ "$span" -eq 5 ] || fail "custom clock not honored (span ${span}s): $row"

  # The record is firstmate's own bookkeeping: it must not re-wake the home
  # that wrote it, while a later worker line on the same task still must.
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t2.status" \
    || fail "could not prime the announced baseline"
  run_send "$fb" "$home" "$log" t2 --release-hold "resume" >/dev/null; rc=$?
  expect_code 0 "$rc" "the release send should succeed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t2.status" \
    || fail "firstmate's own release was left to re-wake this same home"
  printf 'working [at=200]: resumed\n' >> "$home/state/t2.status"
  if FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/t2.status"; then
    fail "a later worker line after the release was swallowed"
  fi
  pass "--hold=<seconds> sets the clock and the records stay self-announced"
}

test_watcher_wakes_on_what_send_wrote() {
  local dir fb log home rc row until_epoch queue
  dir="$TMP_ROOT/wake"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home wake)
  fm_write_meta "$home/state/t3.meta" "window=sess:fm-t3" "kind=ship"
  printf 'working [at=100]: started\n' > "$home/state/t3.status"

  run_send "$fb" "$home" "$log" t3 --hold=5 "short hold"; rc=$?
  expect_code 0 "$rc" "the hold send should succeed"
  row=$(fold_open "$home" t3) || fail "hold did not record"
  until_epoch=$(printf '%s' "$row" | cut -f3)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1/bin/fm-watch.sh"; imposed_hold_expiry_tick "$2" >/dev/null 2>&1' \
    _ "$ROOT" $((until_epoch + 600)) || fail "the watcher tick failed"
  queue="$home/state/.wake-queue"
  [ -f "$queue" ] && [ "$(wc -l < "$queue" | tr -d ' ')" = 1 ] \
    || fail "the tick did not queue exactly one wake: $(cat "$queue" 2>/dev/null)"
  grep -qF 'imposed hold expired: t3' "$queue" \
    || fail "the wake does not name the task: $(cat "$queue")"
  grep -qF -- 'fm-send t3 --hold' "$queue" \
    || fail "the wake does not carry the renew command: $(cat "$queue")"
  grep -qF -- 'fm-send t3 --release-hold' "$queue" \
    || fail "the wake does not carry the release command: $(cat "$queue")"
  pass "the real watcher tick wakes once on the hold the real send wrote"
}

test_release_closes_and_wrong_id_refuses() {
  local dir fb log home err rc row id
  dir="$TMP_ROOT/release"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home release)
  fm_write_meta "$home/state/t4.meta" "window=sess:fm-t4" "kind=ship"
  printf 'working [at=100]: started\n' > "$home/state/t4.status"

  run_send "$fb" "$home" "$log" t4 --hold "hold for review"; rc=$?
  expect_code 0 "$rc" "the hold send should succeed"
  row=$(fold_open "$home" t4) || fail "hold did not record"
  id=$(printf '%s' "$row" | cut -f1)

  # A wrong id refuses BEFORE anything is sent.
  local inbox_before
  inbox_before=$(find "$home/state/t4.inbox" -maxdepth 1 -type f -name '*.msg' | wc -l | tr -d ' ')
  send_err "$err" "$fb" "$home" "$log" t4 --release-hold=0000000000000000 "note"; rc=$?
  [ "$rc" -ne 0 ] || fail "a wrong-id release should refuse"
  assert_contains "$(cat "$err")" "does not match the open hold" \
    "the wrong-id refusal should be explicit"
  [ "$(find "$home/state/t4.inbox" -maxdepth 1 -type f -name '*.msg' | wc -l | tr -d ' ')" = "$inbox_before" ] \
    || fail "a refused release still delivered a message"

  # The matching release closes the fold.
  run_send "$fb" "$home" "$log" t4 --release-hold="$id" "vendor confirmed, resume"; rc=$?
  expect_code 0 "$rc" "the matching release should succeed"
  if fold_open "$home" t4 >/dev/null 2>&1; then
    fail "the matching release did not close the hold: $(cat "$home/state/t4.status")"
  fi
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/t4.status" \
    | grep -qF "resolved [key=imposed-hold-$id]: imposed-hold-$id: released by firstmate: vendor confirmed, resume" \
    || fail "the release record is malformed: $(cat "$home/state/t4.status")"

  # Releasing again, with nothing open, refuses before sending.
  send_err "$err" "$fb" "$home" "$log" t4 --release-hold "again"; rc=$?
  [ "$rc" -ne 0 ] || fail "a release with nothing open should refuse"
  assert_contains "$(cat "$err")" "no firstmate-imposed hold is open" \
    "the nothing-open refusal should be explicit"
  pass "--release-hold closes only the named open hold and refuses otherwise"
}

test_flag_misuse_refuses() {
  local dir fb log home err rc
  dir="$TMP_ROOT/misuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home misuse)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'working [at=100]: started\n' > "$home/state/t5.status"

  # Empty message.
  send_err "$err" "$fb" "$home" "$log" t5 --hold >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty hold message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" "the empty-message refusal should be explicit"

  # --hold and --release-hold cannot combine.
  send_err "$err" "$fb" "$home" "$log" t5 --hold --release-hold "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "--hold and --release-hold together should refuse"

  # --key is for key bytes, not holds.
  send_err "$err" "$fb" "$home" "$log" t5 --hold --key Enter "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "--hold with --key should refuse"
  assert_contains "$(cat "$err")" "cannot accompany --key" "the --key refusal should be explicit"

  # --resolve-key answers decisions; a hold is separate.
  send_err "$err" "$fb" "$home" "$log" t5 --hold --resolve-key somekey "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "--hold with --resolve-key should refuse"
  assert_contains "$(cat "$err")" "separate messages" "the --resolve-key refusal should be explicit"

  # An explicit backend target has no supervision ledger in this home.
  send_err "$err" "$fb" "$home" "$log" sess:elsewhere --hold "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit backend target should refuse --hold"
  assert_contains "$(cat "$err")" "no supervision ledger" "the explicit-target refusal should be explicit"

  # Malformed or non-positive seconds.
  send_err "$err" "$fb" "$home" "$log" t5 --hold=0 "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a zero hold should refuse"
  send_err "$err" "$fb" "$home" "$log" t5 --hold=nope "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a non-numeric hold should refuse"
  send_err "$err" "$fb" "$home" "$log" t5 --hold= "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty duration should refuse"
  send_err "$err" "$fb" "$home" "$log" t5 --release-hold= "text" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty release id should refuse"
  send_err "$err" "$fb" "$home" "$log" t5 --hold "   " >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a blank reason should refuse"

  [ ! -s "$log" ] || fail "a refused misuse still typed text: $(cat "$log")"
  if fold_open "$home" t5 >/dev/null 2>&1; then
    fail "a refused misuse still recorded a hold: $(cat "$home/state/t5.status")"
  fi
  pass "hold flag misuse refuses before anything is sent"
}

test_release_still_works_after_worker_finishes() {
  local dir fb log home rc row
  dir="$TMP_ROOT/finished"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home finished)
  fm_write_meta "$home/state/t6.meta" "window=sess:fm-t6" "kind=ship"
  printf 'working [at=800]: wrapping up\n' > "$home/state/t6.status"
  run_send "$fb" "$home" "$log" t6 --hold "hold the wrap-up"; rc=$?
  expect_code 0 "$rc" "imposing a hold should succeed"
  row=$(fold_open "$home" t6) || fail "hold did not record"
  printf 'done [at=900]: shipped the feature\n' >> "$home/state/t6.status"
  run_send "$fb" "$home" "$log" t6 --hold "start nothing new"; rc=$?
  [ "$rc" -ne 0 ] || fail "--hold bypassed the finished-worker reuse guard"
  [ "$(fold_open "$home" t6)" = "$row" ] || fail "refused hold changed the ledger"
  run_send "$fb" "$home" "$log" t6 --release-hold "released"; rc=$?
  expect_code 0 "$rc" "releasing a finished worker's hold should succeed"
  if fold_open "$home" t6 >/dev/null 2>&1; then
    fail "the finished worker's hold did not close"
  fi
  pass "release works after completion without bypassing finished-worker reuse"
}

test_remote_secondmate_hold_is_the_same_local_record() {
  local dir fb log home ssh_log rc row
  dir="$TMP_ROOT/remote"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; ssh_log="$dir/ssh.log"; : > "$ssh_log"
  local err="$dir/send.err"
  home=$(setup_home remote)
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=fm-remote:w1:p1" \
    "endpoint_task_id=rsm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$home/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF

  # The remote transport resolves its entrypoint through the real root; only
  # the home (and its ledger) is the fixture.
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --hold "start nothing until told" 2>"$err"; rc=$?
  expect_code 0 "$rc" "a remote secondmate hold send should succeed"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" \
    "the hold instruction should cross the remote transport"
  row=$(fold_open "$home" rsm) || fail "the remote hold did not record in the local ledger"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=1 \
    "$SEND" rsm --hold "failed renewal" 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "failed delivery should not report success"
  [ "$(fold_open "$home" rsm)" = "$row" ] || fail "failed delivery changed the hold ledger"
  pass "a remote secondmate's hold records locally only after delivery"
}

fm_test_run \
  test_hold_delivers_and_records \
  test_custom_clock_and_self_announced \
  test_watcher_wakes_on_what_send_wrote \
  test_release_closes_and_wrong_id_refuses \
  test_flag_misuse_refuses \
  test_release_still_works_after_worker_finishes \
  test_remote_secondmate_hold_is_the_same_local_record
