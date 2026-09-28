#!/usr/bin/env bash
# capture.sh <repo-root> <outfile> [--mcp-config <file>]: emit fm-spawn's real Claude scout launch text via the repo's fake-backend harness.
set -u
ROOT_ARG=$1 OUT=$2; shift 2
. "$ROOT_ARG/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-mcp-capture)
CASE_DIR="$TMP_ROOT/c"; HOME_DIR="$CASE_DIR/home"; PROJ_DIR="$CASE_DIR/project"; WT_DIR="$CASE_DIR/wt"
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" claude)
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ_DIR" "$WT_DIR" wt-c
fm_test_spawn_brief "$HOME_DIR" cap-1
: > "$CASE_DIR/launch.log"
FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" cap-1 "$PROJ_DIR" --scout --model opus --effort low "$@"
echo "spawn exit=$?"
cp "$CASE_DIR/launch.log" "$OUT"
rm -rf "$OUT.home"; cp -r "$HOME_DIR" "$OUT.home"
