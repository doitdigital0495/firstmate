#!/usr/bin/env bash
# Drives the real live-board scripts of the run worktree against a throwaway
# FM_HOME. Only Lavish itself is a stub (so no session is opened on the
# machine's shared Lavish server); every bin/ script is the real one.
# Usage: drive-live-board.sh <worktree> <home-dir> <phase>
set -u
ROOT=$1 BASE=$2 PHASE=$3
home="$BASE/home" mate="$BASE/mate"
LIVE="$ROOT/bin/fm-live-board.sh"
ANSWER="$ROOT/bin/fm-live-board-answer.sh"
PROC="$ROOT/bin/fm-procevent.sh"
board="$home/data/live-board/board.html"
inbox="$home/state/procevent-inbox"

in_home() {
  local h=$1; shift
  PATH="$h/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" \
    FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
    FM_CONFIG_OVERRIDE="$h/config" FM_PROCEVENT_CLAIM_ROOT="$h/procevent-claims" \
    LAVISH_AXI_NO_OPEN=1 "$@"
}
run() { printf '\n$ %s\n' "$*"; shift 0; "$@"; printf '[exit %s]\n' "$?"; }
mk() {
  local h=$1 t
  mkdir -p "$h/data" "$h/state" "$h/config" "$h/projects" "$h/fakebin"
  chmod 700 "$h" "$h/data" "$h/state" "$h/config"
  cp "$ROOT/.tasks.toml" "$h/.tasks.toml"
  for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$h/fakebin/$t"; chmod +x "$h/fakebin/$t"; done
  cat > "$h/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '%s\n' "$(cat "$FM_HOME/lavish-version" 2>/dev/null || echo 0.1.74)" ;;
  reply) cat "$4" >> "$FM_HOME/lavish-reply.body"; printf '\n-----\n' >> "$FM_HOME/lavish-reply.body" ;;
  '') printf 'sessions[0]{file,status,url,pending_prompts}:\n' ;;
  poll) exit 75 ;;
  *) printf 'session:\n  status: opened\n' ;;
esac
exit 0
SH
  chmod +x "$h/fakebin/lavish-axi"
}
worker() {  # <home> <id> <meta...>
  local h=$1 id=$2 gen; shift 2
  mkdir -p "$h/projects/wt-$id"
  printf '%s\n' 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" "worktree=$h/projects/wt-$id" "$@" > "$h/state/$id.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$h/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$h/state" "$id" busy --gen "$gen" --source claude-hook --event user-prompt-submit
}
capture() {  # <source-id> <sequence> <row...>
  local source=$1 seq=$2; shift 2
  (umask 077; mkdir -p "$inbox")
  { printf 'session:\n  file: %s\n  status: feedback\nprompts[%s]{uid,prompt,selector,tag,text}:\n' "$board" "$#"
    printf '  %s\n' "$@"; } > "$inbox/$source.$seq.result"
  printf 'lavish\n' > "$inbox/$source.$seq.adapter"
}
sid() { in_home "$home" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$board"; }

case "$PHASE" in
setup)
  mk "$home"; mk "$mate"
  cat > "$home/data/backlog.md" <<'BACKLOG'
## In flight
- [ ] geris-testcases - Run the 20 impersonated test cases (repo: geris-assistant) (kind: ship) (since 2026-10-09)
    Plays 20 scripted user conversations against the Geris AI assistant to find where its answers need tuning.

## Queued
- [ ] chatbot-dev-4 - Chatbot DEV-4 (repo: geris-assistant) (kind: ship) (since 2026-10-02)
- [ ] chatbot-dev-5 - Chatbot DEV-5 (repo: geris-assistant) (kind: ship) (since 2026-10-03)
    Lets the chatbot run an action only after the user confirms it.
- [ ] chatbot-dev-6 - Chatbot DEV-6 (repo: geris-assistant) (kind: ship) (since 2026-10-04) (hold: waiting for the supplier to confirm the price list)
- [ ] chatbot-secret - Rotate keys (repo: geris-assistant) (kind: ship) (since 2026-10-05)
    data/chatbot-secret/report.md

## Done
BACKLOG
  printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$home/config/live-board.json"
  printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"Geris AI assistant","description":"The chatbot Geris staff ask about orders and stock.","match":[{"repo":"geris-assistant"}]}]}' > "$home/config/live-board-projects.json"
  worker "$home" geris-testcases 'project=geris-assistant'
  printf 'working [at=%s]: 12 of the 20 test conversations are played\n' "$(date +%s)" > "$home/state/geris-testcases.status"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"; mkdir -p "$mate/bin"
  printf 'geris-crew\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'BACKLOG'
## In flight
- [ ] crew-search - Speed up search (repo: geris-assistant) (kind: ship) (since 2026-10-06)
    Makes the assistant's product search answer in under a second.

## Queued
- [ ] crew-later - Translate the assistant (repo: geris-assistant) (kind: ship) (since 2026-10-08)
    Lets the assistant answer in German and French.

## Done
BACKLOG
  worker "$mate" crew-search 'project=geris-assistant'
  printf 'working [at=%s]: the search index is rebuilt and being measured\n' "$(date +%s)" > "$mate/state/crew-search.status"
  printf -- '- geris-crew - fixture crew (home: %s; scope: fixture work; projects: geris-assistant; added 2026-10-01)\n' "$mate" > "$home/data/secondmates.md"
  run in_home "$home" "$LIVE" build
  ;;
ask)
  s=$(sid)
  capture "$s" 1 \
    '"",What is the status of the 20 test cases you should do do fine tune the geris ai assistant impersonating users?,"",message,Freeform message' \
    '"1",What is Dev 4 to dev 6???,"div > section:nth-of-type(3)",section,"Charted next 4 Chatbot DEV-4 Waits for other work to finish first"' \
    '"2",Why is nothing being done now?? answer in this lavish,"div > section:nth-of-type(1)",section,"Doing now 0 A worker is on this right now. Nothing is being worked on right now."'
  touch -t 202001010000 "$board"
  run in_home "$home" "$LIVE" refresh
  echo "--- adversarial: mark the result handled with nothing answered"
  run in_home "$home" "$PROC" handled "$s" 1
  ls "$inbox" | sed 's/^/inbox: /'
  ;;
answer)
  s=$(sid)
  echo "--- adversarial: answer with no --item on a three-question result"
  printf 'x\n' | run in_home "$home" "$ANSWER" record "$s" 1
  printf '12 of the 20 conversations are played; 3 answers needed tuning <script>alert(1)</script>.\n' \
    | run in_home "$home" "$ANSWER" record "$s" 1 --item 1 --source "state/geris-testcases.status"
  echo "--- adversarial: handled with one of three answered"
  run in_home "$home" "$PROC" handled "$s" 1
  printf 'DEV-4 is safe custom dashboards.\n\nDEV-5 is confirmed actions.\n\nDEV-6 is the price list import.\n' \
    | run in_home "$home" "$ANSWER" record "$s" 1 --item 2 --source "data/backlog.md"
  echo "--- adversarial: blank no-answer-needed reason"
  run in_home "$home" "$PROC" handled "$s" 1 --no-answer-needed "  "
  echo 0.1.80 > "$home/lavish-version"
  printf 'Two workers are on it right now: one here and one in the geris crew.\n' \
    | run in_home "$home" "$ANSWER" record "$s" 1 --item 3 --source "live worker records"
  echo "--- body posted to the board conversation (Lavish with reply):"; cat "$home/lavish-reply.body"
  run in_home "$home" "$PROC" handled "$s" 1
  ls "$inbox" | sed 's/^/inbox: /'
  touch -t 202001010000 "$board"
  run in_home "$home" "$LIVE" refresh
  run in_home "$home" "$ANSWER" list
  ;;
broken)
  s=$(sid)
  cp "$home/data/live-board/answers.json" "$BASE/answers.good"
  printf 'not json\n' > "$home/data/live-board/answers.json"
  capture "$s" 2 '"",Still there?,"",message,Freeform message'
  printf 'yes\n' | run in_home "$home" "$ANSWER" record "$s" 2
  run in_home "$home" "$PROC" handled "$s" 2
  printf 'answers.json after refused write: '; cat "$home/data/live-board/answers.json"
  touch -t 202001010000 "$board"
  run in_home "$home" "$LIVE" refresh
  ;;
esac
