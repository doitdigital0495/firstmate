#!/usr/bin/env bash
# Builds a throwaway lab: a primary home plus one registered second mate home
# ("geris-ai-assistant") shaped like the captain's report: 27 workers
# (10 working, 17 paused on an outside wait) and 22 queued items.
# The only stand-in is `no-mistakes` on the lab PATH: it never answers for the
# workers whose worktree holds a .nm-hang marker (the slow reads of a busy
# fleet) and answers at once for the rest.
# usage: lab-fixture.sh <repo-root> <lab-dir> <hang: mixed|all>
set -euo pipefail
ROOT=$1 LAB=$2 HANG=$3

make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  chmod 700 "$home" "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  local tool
  for tool in tmux treehouse gh gh-axi lavish-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$tool"
    chmod +x "$home/fakebin/$tool"
  done
  cat > "$home/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
[ ! -e "$top/.nm-hang" ] || exec sleep 120
exit 0
SH
  chmod +x "$home/fakebin/no-mistakes"
}
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@" >/dev/null); }
worker() {  # <home> <id> <busy|idle> <project>
  local home=$1 id=$2 now=$3 project=$4 gen event=stop wt
  wt="$home/projects/wt-$id"
  mkdir -p "$wt"
  printf '%s\n' 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" "worktree=$wt" "project=$project" \
    > "$home/state/$id.meta"
  git -C "$wt" init -q -b "fm/$id"
  git -C "$wt" -c user.email=fixture@example.invalid -c user.name=fixture commit -q --allow-empty -m init
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"
}

home="$LAB/primary" mate="$LAB/geris"
make_home "$home"
make_home "$mate"
mkdir -p "$mate/bin"
printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
printf 'geris-ai-assistant\n' > "$mate/.fm-secondmate-home"
printf -- '- shop [no-mistakes] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
printf -- '- reports [no-mistakes] - fixture (added 2026-01-01)\n- transport [no-mistakes] - fixture (added 2026-01-01)\n- portal [no-mistakes] - fixture (added 2026-01-01)\n' \
  > "$mate/data/projects.md"
printf -- '- geris-ai-assistant - fixture (home: %s; scope: fixture; projects: reports, transport, portal; added 2026-07-11)\n' \
  "$mate" > "$home/data/secondmates.md"
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$home/config/live-board.json"

tasks_in "$home" add own-checkout "Build the new checkout" --repo shop --kind ship --start
worker "$home" own-checkout busy shop

repos=(reports transport portal)
for i in $(seq 1 27); do
  id=$(printf 'g-w%02d' "$i") repo=${repos[$((i % 3))]}
  tasks_in "$mate" add "$id" "Geris worker task $i" --repo "$repo" --kind ship --start
  if [ "$i" -le 10 ]; then
    worker "$mate" "$id" busy "$repo"
  else
    worker "$mate" "$id" idle "$repo"
    printf 'paused [at=%s]: waiting for the vendor to answer\n' "$(date +%s)" > "$mate/state/$id.status"
  fi
  if [ "$HANG" = all ] || [ $((i % 4)) -eq 1 ]; then : > "$mate/projects/wt-$id/.nm-hang"; fi
done
for i in $(seq 1 22); do
  tasks_in "$mate" add "$(printf 'g-q%02d' "$i")" "Geris queued item $i" --repo "${repos[$((i % 3))]}" --kind ship
done
echo "lab ready: $LAB (hang=$HANG, hung workers: $(find "$mate/projects" -name .nm-hang | wc -l))"
