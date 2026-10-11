#!/usr/bin/env bash
# Step 1: mint the lab home and a crew home, seed the reported situation.
set -eu
. "$(dirname "$0")/driver-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
MATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
"$ROOT/bin/fm-lab-home.sh" create "$MATE" >/dev/null
TMUXDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf 'LAB=%s\nMATE=%s\nTMUXDIR=%s\n' "$LAB" "$MATE" "$TMUXDIR" > "$EV/lab-paths"

for home in "$LAB" "$MATE"; do
  chmod 700 "$home" "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
done

# The main home: the Charted next items the captain saw as bare labels.
cat > "$LAB/data/backlog.md" <<'BACKLOG'
## In flight

## Queued
- [ ] chat-dev-4 - Chatbot DEV-4 (repo: chatbot) (kind: ship) (since 2026-10-01)
- [ ] chat-dev-5 - Chatbot DEV-5 (repo: chatbot) (kind: ship) (since 2026-10-02)
    Lets the assistant carry out an action only after the user confirms it.
- [ ] chat-dev-6 - Chatbot DEV-6 (repo: chatbot) (kind: ship) (since 2026-10-03) (hold: waiting for the pilot users to be named)
- [ ] chat-tests - Assistant test cases (repo: chatbot) (kind: ship) (since 2026-10-04)
    Runs 20 test conversations that impersonate real users, to fine tune the assistant.

## Done
BACKLOG
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$LAB/config/live-board.json"
printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"Chatbot","description":"The AI assistant that answers staff questions.","match":[{"repo":"chatbot"}]}]}' \
  > "$LAB/config/live-board-projects.json"

# The crew home: eleven workers busy right now, as when the captain asked.
printf '# Seeded Firstmate home\n' > "$MATE/AGENTS.md"
printf 'chat-crew\n' > "$MATE/.fm-secondmate-home"
{
  printf '## In flight\n'
  printf -- '- [ ] chat-tests - Assistant test cases (repo: chatbot) (kind: ship) (since 2026-10-04)\n'
  printf '    Runs 20 test conversations that impersonate real users, to fine tune the assistant.\n'
  for n in 2 3 4 5 6 7 8 9 10 11; do
    printf -- '- [ ] crew-job-%s - Crew job %s (repo: chatbot) (kind: ship) (since 2026-10-05)\n' "$n" "$n"
    printf '    Crew work item %s, explained in one plain sentence.\n' "$n"
  done
  printf '\n## Queued\n\n## Done\n'
} > "$MATE/data/backlog.md"
worker "$MATE" chat-tests
for n in 2 3 4 5 6 7 8 9 10 11; do worker "$MATE" "crew-job-$n"; done
fm "$MATE" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$MATE/state/home-summary.json"
printf 'crew summary: %s working children\n' "$(jq '[.active_children[]] | length' "$MATE/state/home-summary.json")"
printf 'lab: %s\ncrew: %s\n' "$LAB" "$MATE"
