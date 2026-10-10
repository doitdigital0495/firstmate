#!/usr/bin/env bash
# Drives bin/fm-fleet-snapshot.sh (base vs target) against an isolated home with a large backlog.
# usage: drive.sh <worktree> <base-script-name>
set -u
WT=$1
BASE_NAME=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-snap-drive.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOME

# Keep the run off the live tmux server and the real no-mistakes daemon.
FAKEBIN=$WORK/fakebin
mkdir -p "$FAKEBIN"
for tool in tmux no-mistakes herdr; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done
export PATH="$FAKEBIN:$PATH"

make_home() {  # <name> <count> <detail-lines>
  local home=$WORK/$1 count=$2 detail=$3 i d
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  {
    printf '## In flight\n\n## Queued\n'
    for i in $(seq 1 "$count"); do
      printf -- '- [ ] task-%04d - Queued task %d: tighten the retry path of the ingest worker so a dropped lease is retried once (repo: alpha) (kind: ship) (since 2026-10-01)\n' "$i" "$i"
      for d in $(seq 1 "$detail"); do
        printf '  Detail %d for task %d: the captain asked for the full acceptance criteria to stay with the backlog entry, including the reproduction steps and the expected observable result.\n' "$d" "$i"
      done
    done
    printf '\n## Done\n'
  } > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

run() {  # <label> <home> <script> [args...]
  local label=$1 home=$2 script=$3 rc bytes
  shift 3
  FM_HOME="$home" "$script" "$@" > "$WORK/out" 2> "$WORK/err"
  rc=$?
  bytes=$(wc -c < "$WORK/out")
  printf '%-52s exit=%s stdout_bytes=%s\n' "$label" "$rc" "$bytes"
  [ ! -s "$WORK/err" ] || sed 's/^/    stderr: /' "$WORK/err" | cut -c1-240
  return "$rc"
}

leftovers() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-fleet-snapshot.*' 2>/dev/null | wc -l; }

BASE=$WT/bin/$BASE_NAME
TARGET=$WT/bin/fm-fleet-snapshot.sh

echo "== jq: $(jq --version), ARG_MAX=$(getconf ARG_MAX), single argv cap=131072 bytes"
echo
echo "== S1: realistic backlog, 200 queued tasks with detail lines"
H200=$(make_home h200 200 4)
echo "backlog.md bytes: $(wc -c < "$H200/data/backlog.md")"
echo "-- base 8793116"
run 'base   --contribution-input' "$H200" "$BASE" --contribution-input
echo "-- target cfcab60"
before=$(leftovers)
run 'target --contribution-input' "$H200" "$TARGET" --contribution-input
cp "$WORK/out" "$WORK/h200.json"
echo "   payload: $(jq -c '{backlog_records:(.backlog.records|length), tasks:(.tasks|length), first:.backlog.records[0].id, last:.backlog.records[-1].id}' "$WORK/h200.json")"
echo "   temp dirs left behind by target run: $(( $(leftovers) - before ))"

echo
echo "== S2: small backlog, base and target must emit identical JSON"
H5=$(make_home h5 5 1)
FM_HOME="$H5" FM_SNAPSHOT_NOW=2026-10-11T00:00:00Z "$BASE" --contribution-input > "$WORK/small-base.json" 2>"$WORK/err"; echo "base exit=$?"
FM_HOME="$H5" FM_SNAPSHOT_NOW=2026-10-11T00:00:00Z "$TARGET" --contribution-input > "$WORK/small-target.json" 2>"$WORK/err"; echo "target exit=$?"
cmp -s "$WORK/small-base.json" "$WORK/small-target.json" && echo "byte-identical: yes" || echo "byte-identical: no (object key order differs)"
jq -S . "$WORK/small-base.json" > "$WORK/small-base.sorted.json"
jq -S . "$WORK/small-target.json" > "$WORK/small-target.sorted.json"
if cmp -s "$WORK/small-base.sorted.json" "$WORK/small-target.sorted.json"; then echo "same JSON value after key sort (jq -S): yes ($(wc -c < "$WORK/small-target.sorted.json") bytes)"; else echo "same JSON value after key sort (jq -S): NO"; diff "$WORK/small-base.sorted.json" "$WORK/small-target.sorted.json" | cut -c1-300; fi
echo "top-level key order base:   $(jq -c 'keys_unsorted' "$WORK/small-base.json")"
echo "top-level key order target: $(jq -c 'keys_unsorted' "$WORK/small-target.json")"

echo
echo "== S3: every snapshot mode and the views built from it, 200-task home, target"
run 'target (default fleet JSON)' "$H200" "$TARGET"
echo "   payload: $(jq -c '{backlog_records:(.backlog.records|length)}' "$WORK/out" 2>&1 | cut -c1-200)"
run 'target --live-board-input' "$H200" "$TARGET" --live-board-input
run 'target --secondmate-home-summary' "$H200" "$TARGET" --secondmate-home-summary
run 'fm-fleet-view.sh' "$H200" "$WT/bin/fm-fleet-view.sh"
echo "   view lines: $(wc -l < "$WORK/out"), mentions task-0200: $(grep -c 'task-0200' "$WORK/out")"
run 'fm-contributions.sh poll (consumer of the fixed mode)' "$H200" "$WT/bin/fm-contributions.sh" poll
echo "-- same consumer wired to the base snapshot (temp copy of bin/ with the base script swapped in)"
cp -r "$WT/bin" "$WORK/basebin"
cp "$BASE" "$WORK/basebin/fm-fleet-snapshot.sh"
rm -f "$WORK/basebin/$BASE_NAME"
H200B=$(make_home h200b 200 4)
run 'base   fm-contributions.sh poll' "$H200B" "$WORK/basebin/fm-contributions.sh" poll

echo
echo "== S4: adversarial"
H2000=$(make_home h2000 2000 6)
echo "backlog.md bytes (2000 tasks): $(wc -c < "$H2000/data/backlog.md")"
run 'target --contribution-input, 2000 tasks' "$H2000" "$TARGET" --contribution-input
echo "   payload: $(jq -c '{backlog_records:(.backlog.records|length), tasks:(.tasks|length)}' "$WORK/out" 2>&1 | cut -c1-200)"
HQ=$WORK/hquote
mkdir -p "$HQ/state" "$HQ/data" "$HQ/projects" "$HQ/config"
{
  printf '## In flight\n\n## Queued\n'
  for i in $(seq 1 300); do
    printf -- '- [ ] odd-%04d - Title with "quotes", $(subshell), `ticks`, backslash \\ and unicode e-acute \303\251 %%s number %d padded to make the record long enough to matter for the size (repo: alpha) (kind: ship)\n' "$i" "$i"
  done
  printf '\n## Done\n'
} > "$HQ/data/backlog.md"
run 'target --contribution-input, shell-hostile titles' "$HQ" "$TARGET" --contribution-input
echo "   payload: $(jq -c '{backlog_records:(.backlog.records|length), sample:.backlog.records[0].title}' "$WORK/out" 2>&1 | cut -c1-260)"
echo "-- unwritable TMPDIR must fail loudly, not emit a partial document"
RO=$WORK/ro; mkdir -p "$RO"; chmod 555 "$RO"
TMPDIR="$RO" run 'target --contribution-input, TMPDIR read-only' "$H200" "$TARGET" --contribution-input
chmod 755 "$RO"
echo "-- no temp dirs leaked across the whole run: $(leftovers) present now vs $before at start"
