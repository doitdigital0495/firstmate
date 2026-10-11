#!/usr/bin/env bash
# Runs the real `bin/fm-live-board.sh build` of <repo-root> against the lab's
# primary home, times it, and prints what the shipped page shows for the second
# mate, read from the rendered page.
# usage: lab-build.sh <repo-root> <lab-dir> <label> <out-dir> [VAR=value...]
set -uo pipefail
ROOT=$1 LAB=$2 LABEL=$3 OUT=$4
shift 4
home="$LAB/primary"
start=$(date +%s.%N)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_PROJECTS_OVERRIDE \
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_NO_OPEN=1 "$@" \
  "$ROOT/bin/fm-live-board.sh" build
rc=$?
end=$(date +%s.%N)
printf '[%s] code=%s build exit=%s seconds=%.1f overrides=%s\n' "$LABEL" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || basename "$ROOT")" "$rc" "$(echo "$end - $start" | bc)" "${*:-none}"
board="$home/data/live-board/board.html"
[ -f "$board" ] || { echo "[$LABEL] no board file"; exit 0; }
cp "$board" "$OUT/board-$LABEL.html"
node "$ROOT/tests/assets/live-board-render-harness.mjs" "$board" | jq -r --arg l "$LABEL" '
  [.projects[].lanes | to_entries[] | .key as $lane | .value.cards[] | select(.home != null) | . + {lane:$lane}] as $cards
  | "[\($l)] second mate lines on page: doing=\([$cards[] | select(.lane == "doing")] | length) next=\([$cards[] | select(.lane == "next")] | length) charted=\([$cards[] | select(.lane == "charted")] | length)",
    "[\($l)] doing statuses: \([$cards[] | select(.lane == "doing") | .statusLabel] | group_by(.) | map("\(length)x \(.[0])") | join(", "))",
    "[\($l)] age marks: \([$cards[] | .asOf] | unique | tojson)",
    (.notes[] | select(test("second mate")) | "[\($l)] note: \(.)")'
