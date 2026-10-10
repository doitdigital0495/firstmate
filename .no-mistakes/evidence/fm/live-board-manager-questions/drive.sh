#!/usr/bin/env bash
# Live drive of the captain-question plain-language change against a throwaway
# FM_HOME. Usage: drive.sh <worktree-root> <home-dir>
set -u
ROOT=$1
HOME_DIR=$2
HOLD="$ROOT/bin/fm-captain-hold.sh"
LIVE="$ROOT/bin/fm-live-board.sh"

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/fakebin" "$HOME_DIR/ctx"
chmod 700 "$HOME_DIR" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
for tool in tmux treehouse no-mistakes gh gh-axi lavish-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/fakebin/$tool"
  chmod +x "$HOME_DIR/fakebin/$tool"
done
printf -- '- geris-reports [no-mistakes] - fixture (added 2026-01-01)\n- data [direct-PR] - fixture (added 2026-01-01)\n' \
  > "$HOME_DIR/data/projects.md"
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$HOME_DIR/config/live-board.json"
printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"Margin overview","description":"The monthly margin report for the business.","match":[{"id":"margin-*"}]},{"name":"Data platform","match":[{"repo":"data"}]}]}' \
  > "$HOME_DIR/config/live-board-projects.json"

in_home() {
  PATH="$HOME_DIR/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" LAVISH_AXI_NO_OPEN=1 "$@"
}
tasks() { (cd "$HOME_DIR" && tasks-axi "$@" >/dev/null); }
say() { printf '\n=== %s\n' "$*"; }
# Run a hold, print its exit status and output, and whether the backlog changed.
hold() {  # <label> <args...>
  local label=$1 rc out
  shift
  cp "$HOME_DIR/data/backlog.md" "$HOME_DIR/before"
  out=$(in_home "$HOLD" hold "$@" 2>&1)
  rc=$?
  printf -- '--- %s\n$ fm-captain-hold.sh hold %s\nexit=%s\n%s\n' "$label" "$*" "$rc" "$out"
  if cmp -s "$HOME_DIR/before" "$HOME_DIR/data/backlog.md"; then echo "backlog: unchanged"; else echo "backlog: changed"; fi
}
ctx() { printf '%s\n' "$2" > "$HOME_DIR/ctx/$1.json"; }
build() { in_home "$LIVE" build; }
view() { sed -n '/<script id="live-board-data" type="application\/json">/,/<\/script>/p' "$HOME_DIR/data/live-board/board.html" | sed '1d;$d' | jq "$@"; }

tasks add margin-grant "Margin overview: group grant and Power BI reconciliation" --repo geris-reports --kind captain --priority 1
tasks add margin-legacy "Margin overview: refresh time" --repo geris-reports --kind captain
tasks add data-old "Move the nightly window?" --repo data --kind captain
tasks add data-work "Nightly export" --repo data --kind ship

say "S1 explained hold is accepted"
ctx good '{"schema":"fm-captain-question.v1","close":"done",
 "about":"The new margin overview is built, but the finance team cannot open it yet and its totals have not been compared with the old Power BI report.",
 "purpose":"Your answer decides who may see the report and whether the team checks the numbers first. Until you answer, nobody outside the build team can use it.",
 "question":"Should the finance group get access now, or only after the totals match the old report?",
 "options":[{"value":"grant-now","label":"Give access now","detail":"Finance can open the report today, but a wrong total may be seen before it is checked."},
  {"value":"check-first","label":"Check the numbers first","detail":"Finance waits about two days while the totals are compared, which is recommended because a wrong margin figure is hard to take back."}],
 "recommendation":"check-first"}'
hold "explained context" margin-grant --reason "Decide access and reconciliation order." --context-file "$HOME_DIR/ctx/good.json"

say "S3 adversarial: contexts a manager cannot place are refused before any change"
ctx none '{"schema":"fm-captain-question.v1","close":"done","question":"Grant the group?"}'
ctx nopurpose '{"schema":"fm-captain-question.v1","close":"done","about":"The margin overview is built and waits for a decision."}'
ctx noabout '{"schema":"fm-captain-question.v1","close":"done","purpose":"Your answer lets finance open the report."}'
ctx link '{"schema":"fm-captain-question.v1","close":"done","about":"The margin overview is built and waits for a decision.","purpose":"Your answer lets the team finish https://example.invalid/pull/7 this week."}'
ctx tick '{"schema":"fm-captain-question.v1","close":"done","about":"The `margin` overview is built and waits for a decision.","purpose":"Your answer lets finance open the report."}'
ctx guid '{"schema":"fm-captain-question.v1","close":"done","about":"Report 123e4567-e89b-12d3-a456-426614174000 is built and waits for a decision.","purpose":"Your answer lets finance open the report."}'
ctx nodetail '{"schema":"fm-captain-question.v1","close":"done","about":"The margin overview is built and waits for a decision.","purpose":"Your answer lets finance open the report.","options":[{"value":"go","label":"Go","detail":"Finance can open it today."},{"value":"wait","label":"Wait"}]}'
for bad in none nopurpose noabout link tick guid nodetail; do
  hold "refused: $bad" margin-legacy --reason "choose" --context-file "$HOME_DIR/ctx/$bad.json"
done

say "S4 plain words with slashes are accepted (decided in review round 1)"
tasks add data-rhythm "Reporting rhythm" --repo data --kind captain
ctx slashes '{"schema":"fm-captain-question.v1","close":"done","about":"The team can report monthly/quarterly/yearly to the business from now on.","purpose":"Your pick sets how often the business gets the figures. Until then nothing is sent."}'
hold "slashes" data-rhythm --reason "choose" --context-file "$HOME_DIR/ctx/slashes.json"

say "S5 reason-only hold (no context file) is still accepted, and a pre-rule stored call stays valid"
hold "reason only" margin-legacy --reason "Pick a refresh time."
FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z in_home "$HOLD" hold data-old --reason "Load overlaps." >/dev/null
stored='{"close":"done","lifecycle":"2026-07-14T12:00:00Z#0","options":[{"detail":"The load keeps running at night.","label":"Keep","value":"keep"},{"label":"Move","value":"move"}],"question":"Move the nightly window?","recommendation":"keep","schema":"fm-captain-question.v1","subject":null}'
printf 'Captain hold set: 2026-07-14T12:00:00Z\nCaptain question context: %s\n' "$stored" > "$HOME_DIR/old.body"
tasks update data-old --body-file "$HOME_DIR/old.body"

say "Board build 1"
build
view '{notes: .view.notes, cards: [.view.projects[] | .name as $p | .questions[] | {project:$p, id, text, topic, about, purpose, needs_explanation, why, options:[.options[]? | {label:.label, detail}], recommendation}]}'
cp "$HOME_DIR/data/live-board/board.html" "$HOME_DIR/board-before-backfill.html"

say "S2 persistence: the explanation lives in the task record and survives a rebuild and an identical re-hold"
(cd "$HOME_DIR" && tasks-axi show margin-grant --full 2>&1) || true
hold "identical re-hold" margin-grant --reason "Decide access and reconciliation order." --context-file "$HOME_DIR/ctx/good.json"
rm -f "$HOME_DIR/data/live-board/board.html"
build
view '[.view.projects[].questions[] | select(.id == "margin-grant") | {about, purpose, needs_explanation}]'

say "S6 backfill: a flagged call gains its explanation in the same lifecycle; a backfill that also changes the call is refused"
echo "lifecycle before: $(in_home "$HOLD" open data-old --identity)"
explained=$(printf '%s' "$stored" | jq -c 'del(.lifecycle) | .options[1].detail = "The load runs in the morning, so figures arrive later in the day."
  | .about = "The nightly data load overlaps with the backup, which sometimes slows both down."
  | .purpose = "Your answer decides when the figures are refreshed. Until then the overlap stays."')
printf '%s' "$explained" | jq -c '.recommendation = "move"' > "$HOME_DIR/ctx/changed.json"
printf '%s\n' "$explained" > "$HOME_DIR/ctx/explained.json"
hold "backfill that changes the recommendation" data-old --reason "Load overlaps." --context-file "$HOME_DIR/ctx/changed.json"
hold "backfill that only explains" data-old --reason "Load overlaps." --context-file "$HOME_DIR/ctx/explained.json"
echo "lifecycle after: $(in_home "$HOLD" open data-old --identity)"

say "Board build 2"
build
view '{notes: .view.notes, cards: [.view.projects[] | .name as $p | .questions[] | {project:$p, id, about, purpose, needs_explanation}]}'
