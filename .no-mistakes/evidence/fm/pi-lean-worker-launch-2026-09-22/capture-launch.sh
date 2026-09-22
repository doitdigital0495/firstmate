#!/usr/bin/env bash
# Capture the literal launch text bin/fm-spawn.sh composes for a Pi task worker.
# usage: capture-launch.sh <case-name> <spawn args...>
set -u
cd "$FM_WT"
. tests/fixtures.sh
source <(sed -n '17,121p' tests/fm-spawn-dispatch-profile.test.sh)
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-launch-capture)
name=$1; shift
id="$name-z1"
rec=$(make_spawn_case "$name" pi "$id")
read_case_record "$rec"
out=$(FM_TEST_PI_CODING_AGENT_DIR="$HOME/.pi/agent" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$@" 2>&1)
st=$?
echo "spawn_exit=$st" >&2
[ $st -eq 0 ] || { echo "$out" >&2; exit $st; }
echo "FAKEBIN=$FAKEBIN_DIR" >&2
echo "META:" >&2; grep -E '^(harness|model|effort)=' "$HOME_DIR/state/$id.meta" >&2
cat "$LAUNCH_LOG"
