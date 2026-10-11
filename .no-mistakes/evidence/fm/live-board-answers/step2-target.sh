#!/usr/bin/env bash
# Step 2: build the same lab with the change, then replay the captain's real
# captured board feedback (read-only copies of the operator home's Lavish
# results 10, 11, 13 and 14) into the lab inbox under the lab board's source id.
set -u
. "$(dirname "$0")/driver-lib.sh"
LIVE="$ROOT/bin/fm-live-board.sh"
REAL=/home/daan/.firstmate/state/procevent-inbox/lavish-b951cc844d1ffeb6

echo "## build with the change"
fm "$LAB" "$LIVE" build
cp "$LAB/data/live-board/board.html" "$EV/board-target-before-questions.html"
render | jq -c '{doing:.stats.doing, notes, asked:.asked,
  doing_cards:[.projects[].lanes.doing.cards[] | {title,worker,note,what:.what.text}] | .[0:3],
  other:[.projects[].lanes | (.next, .charted) | .cards[] | {title,lane,what:.what.text,source:.what.source}]}'

echo "## the captain's real captured questions arrive"
SID=$(fm "$LAB" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$LAB/data/live-board/board.html")
echo "SID=$SID" >> "$EV/lab-paths"
(umask 077; mkdir -p "$LAB/state/procevent-inbox")
seq=0
for n in 10 11 13 14; do
  seq=$((seq + 1))
  cp "$REAL.$n.result" "$LAB/state/procevent-inbox/$SID.$seq.result"
  printf 'lavish\n' > "$LAB/state/procevent-inbox/$SID.$seq.adapter"
done
fm "$LAB" "$LIVE" build
cp "$LAB/data/live-board/board.html" "$EV/board-target-questions-open.html"
render | jq -c '.asked | {hidden,title,items:[.items[] | {key,status,question,badges,on:(.on // "" | .[0:60])}]}'

echo "## marking a question's result handled without an answer"
for s in 1 2 3 4; do
  fm "$LAB" "$ROOT/bin/fm-procevent.sh" handled "$SID" "$s"; echo "exit=$? handled-file=$([ -e "$LAB/state/procevent-inbox/$SID.$s.handled" ] && echo yes || echo no)"
done
