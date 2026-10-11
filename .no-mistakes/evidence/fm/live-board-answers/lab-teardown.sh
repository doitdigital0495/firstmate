#!/usr/bin/env bash
# Stop the lab board's listener, end its Lavish session and remove the lab.
# Usage: lab-teardown.sh <worktree> <lab>
set -u
ROOT=$1
LAB=$2
case "$LAB" in /tmp/fm-lab.*) ;; *) echo "refusing: not a lab home: $LAB" >&2; exit 1 ;; esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$HERE/lab-run.sh" "$LAB" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
[ ! -f "$LAB/data/live-board/board.html" ] || lavish-axi end "$LAB/data/live-board/board.html" >/dev/null 2>&1 || true
rm -rf "$LAB" "$LAB.mate"
echo "removed: $LAB"
