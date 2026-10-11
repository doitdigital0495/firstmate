#!/usr/bin/env bash
# Live validation fixture: a disposable Firstmate home whose live board is served
# by the real lavish-axi. Usage: lab-setup.sh <worktree> -> prints LAB path.
set -eu
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$(cd -P -- "$LAB" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/data" "$LAB/state" "$LAB/config" "$LAB/projects"
chmod 700 "$LAB" "$LAB/data" "$LAB/state" "$LAB/config"
# A registered home may not sit inside the home that registers it.
MATE="$LAB.mate"
mkdir -p "$MATE/data" "$MATE/state" "$MATE/config" "$MATE/projects" "$MATE/bin"
cp "$ROOT/.tasks.toml" "$LAB/.tasks.toml"
cp "$ROOT/.tasks.toml" "$MATE/.tasks.toml"

cat > "$LAB/data/backlog.md" <<'BACKLOG'
## In flight

## Queued
- [ ] ws-dev-4 - Chatbot DEV-4 (repo: geris-chatbot) (kind: ship) (since 2026-01-02)
    Lets a customer build a safe custom dashboard by asking the assistant in plain words.
- [ ] ws-dev-5 - Chatbot DEV-5 (repo: geris-chatbot) (kind: ship) (since 2026-01-03) (hold: waiting for the supplier to confirm the price list)
- [ ] ws-dev-6 - Chatbot DEV-6 (repo: geris-chatbot) (kind: ship) (since 2026-01-04)
- [ ] ws-token - Rotate keys (repo: geris-chatbot) (kind: ship) (since 2026-01-05)
    data/ws-token/report.md

## Done
BACKLOG
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$LAB/config/live-board.json"
printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"Geris AI assistant","description":"The chatbot Geris customers ask about their transport data.","match":[{"repo":"geris-chatbot"}]}]}' \
  > "$LAB/config/live-board-projects.json"

# A registered second mate home with two workers busy right now and one idle.
printf '# Firstmate fixture\n' > "$MATE/AGENTS.md"
printf 'ai-crew\n' > "$MATE/.fm-secondmate-home"
cat > "$MATE/data/backlog.md" <<'BACKLOG'
## In flight
- [ ] crew-tests - Run the 20 impersonated test cases (repo: geris-chatbot) (kind: ship) (since 2026-01-06)
    Plays twenty real user questions against the assistant to fine tune its answers.
- [ ] crew-search - Speed up search (repo: geris-chatbot) (kind: ship) (since 2026-01-07)
    Makes the assistant find a shipment in under a second.
- [ ] crew-idle - Tidy the footer (repo: geris-chatbot) (kind: ship) (since 2026-01-08)

## Queued

## Done
BACKLOG
worker() {  # <home> <id> <busy|idle>
  local home=$1 id=$2 now=$3 gen event=stop
  mkdir -p "$home/projects/wt-$id"
  printf '%s\n' 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" \
    "worktree=$home/projects/wt-$id" 'project=geris-chatbot' > "$home/state/$id.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"
}
worker "$MATE" crew-tests busy
worker "$MATE" crew-search busy
worker "$MATE" crew-idle idle
printf 'working [at=%s]: 12 of the 20 test cases have run\n' "$(date +%s)" > "$MATE/state/crew-tests.status"
printf 'done [at=%s]: footer tidied\n' "$(date +%s)" > "$MATE/state/crew-idle.status"
printf -- '- ai-crew - fixture crew (home: %s; scope: fixture work; projects: geris-chatbot; added 2026-01-01)\n' "$MATE" \
  > "$LAB/data/secondmates.md"
printf '%s\n' "$LAB"
