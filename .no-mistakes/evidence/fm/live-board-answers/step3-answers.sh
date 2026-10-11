#!/usr/bin/env bash
# Step 3: make the crew home a readable Firstmate home, then answer the
# captain's questions on the board and try to break the rule.
set -u
. "$(dirname "$0")/driver-lib.sh"
LIVE="$ROOT/bin/fm-live-board.sh"
ANSWER="$ROOT/bin/fm-live-board-answer.sh"
PROC="$ROOT/bin/fm-procevent.sh"
handled() { [ -e "$LAB/state/procevent-inbox/$SID.$1.handled" ] && echo yes || echo no; }

echo "## crew home readable: eleven workers are live under the Chat crew"
mkdir -p "$MATE/bin"
fm "$LAB" "$LIVE" build
render | jq -c '{doing:.stats.doing, status:.projects[0].status, notes,
  doing_cards:[.projects[].lanes.doing.cards[] | {title,worker,note,what:.what.text}],
  next:[.projects[].lanes.next.cards[].title]}'

echo "## answer the 20-test-cases question (stdin), with a source"
printf 'The 20 test conversations are the task "Assistant test cases". A worker in the Chat crew is running them right now; none has been reported back yet.\n\nSee its card under Chatbot, Doing now. <b>not bold</b> <script>document.title="pwned"</script>\n' \
  | fm "$LAB" "$ANSWER" record "$SID" 1 --source "the Chat crew summary and the task list"
echo "exit=$?"

echo "## handled is accepted only once its question is answered"
fm "$LAB" "$PROC" handled "$SID" 1; echo "exit=$? handled-file=$(handled 1)"
fm "$LAB" "$PROC" handled "$SID" 2; echo "exit=$? handled-file=$(handled 2)"

echo "## answer Dev 4 to 6 from a file, and the Doing now question"
printf 'DEV-4, DEV-5 and DEV-6 are the next three Chatbot steps. DEV-5 lets the assistant act only after the user confirms. DEV-6 waits for the pilot users to be named. DEV-4 has no explanation recorded yet.\n' > "$LAB/answer.txt"
fm "$LAB" "$ANSWER" record "$SID" 2 --file "$LAB/answer.txt" --source "the task list"; echo "exit=$?"
printf 'Work was being done: eleven workers were live under the Chat crew. The board only counted this home. It now lists them under Doing now.\n' \
  | fm "$LAB" "$ANSWER" record "$SID" 3; echo "exit=$?"
fm "$LAB" "$PROC" handled "$SID" 2; echo "exit=$? handled-file=$(handled 2)"
fm "$LAB" "$PROC" handled "$SID" 3; echo "exit=$? handled-file=$(handled 3)"

echo "## adversarial: empty answer, oversized answer, control characters, blank waiver"
printf '   \n' | fm "$LAB" "$ANSWER" record "$SID" 4; echo "exit=$?"
head -c 6001 /dev/zero | tr '\0' a | fm "$LAB" "$ANSWER" record "$SID" 4; echo "exit=$?"
printf 'bad \033[31m text\n' | fm "$LAB" "$ANSWER" record "$SID" 4; echo "exit=$?"
fm "$LAB" "$PROC" handled "$SID" 4 --no-answer-needed "   "; echo "exit=$? handled-file=$(handled 4)"
printf 'x\n' | fm "$LAB" "$ANSWER" record "../../etc" 4; echo "exit=$?"

echo "## adversarial: unreadable answers record"
cp "$LAB/data/live-board/answers.json" "$LAB/answers.good"
printf 'not json\n' > "$LAB/data/live-board/answers.json"
printf 'yes\n' | fm "$LAB" "$ANSWER" record "$SID" 4; echo "exit=$? record-now=$(cat "$LAB/data/live-board/answers.json")"
fm "$LAB" "$PROC" handled "$SID" 4; echo "exit=$? handled-file=$(handled 4)"
fm "$LAB" "$LIVE" build
cp "$LAB/data/live-board/board.html" "$EV/board-target-record-unreadable.html"
render | jq -c '.asked | {banner,items:[.items[] | [.status,.question[0:40]]]}'
cp "$LAB/answers.good" "$LAB/data/live-board/answers.json"

echo "## the fourth comment is an instruction: handled with a reason, not listed as a question"
fm "$LAB" "$PROC" handled "$SID" 4 --no-answer-needed "an instruction, carried out by this change, not a question"; echo "exit=$? handled-file=$(handled 4)"

echo "## another board's typed question is not held to this rule"
printf 'session:\n  file: /tmp/other.html\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "",A question on some other board?,"",message,Freeform message\n' \
  > "$LAB/state/procevent-inbox/lavish-00000000000000aa.1.result"
printf 'lavish\n' > "$LAB/state/procevent-inbox/lavish-00000000000000aa.1.adapter"
fm "$LAB" "$PROC" handled lavish-00000000000000aa 1; echo "exit=$?"

echo "## final board, answers stay after their results are handled"
fm "$LAB" "$LIVE" build
cp "$LAB/data/live-board/board.html" "$EV/board-target-answered.html"
render | jq -c '.asked | {title,banner,items:[.items[] | {status,question:.question[0:60],answer,source,badges}]}'
fm "$LAB" "$ANSWER" list | jq -c '{status,items:[.items[] | {key,status}]}'

echo "## adversarial: a crew summary too old to trust is not shown as work being done"
cp "$MATE/state/home-summary.json" "$LAB/summary.good"
jq '.generated_epoch -= 30000' "$LAB/summary.good" > "$MATE/state/home-summary.json"
fm "$LAB" "$LIVE" build
render | jq -c '{doing:.stats.doing, notes:[.notes[] | select(test("crew"))]}'
cp "$LAB/summary.good" "$MATE/state/home-summary.json"
fm "$LAB" "$LIVE" build >/dev/null
render | jq -c '{doing_after_restore:.stats.doing}'
