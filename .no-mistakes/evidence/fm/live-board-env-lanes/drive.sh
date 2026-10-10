#!/usr/bin/env bash
# Evidence driver for the live-board environment strips: an isolated firstmate
# home whose `fm-live-board.sh build` runs the real collector, snapshot, view
# and page. Git is real (a local upstream with one branch per environment,
# fetched by the collector); only the Azure DevOps CLI is a stub that lists the
# pull requests and runs, because no forge with DEV/UAT/PROD branches is
# available to this run.
#
#   drive.sh setup <scratch>     build the home, the upstream and the forge stub
#   drive.sh build <scratch>     force a pull request re-read and build the board
#   drive.sh promote <scratch>   carry the halfway change from UAT into PROD
set -eu
ROOT=${FM_WORKTREE:?set FM_WORKTREE to the worktree}
cmd=$1 S=$2
H="$S/home" FORGE="$S/forge" UP="$S/forge/upstream/stages"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

g() { git -C "$UP" "$@" >/dev/null 2>&1 || { echo "fixture git $* failed" >&2; exit 1; }; }
change() { printf '%s\n' "$2" >> "$UP/$1"; g add "$1"; g commit -qm "$2"; }
land() { g checkout -q "$1"; g merge -q --no-ff -m "Merge $2 into $1" "$2"; git -C "$UP" rev-parse HEAD; }
ado_pr() {  # <id> <status> <source> <target> <closed|null> <sha|null> <title> <description>
  jq -cn --argjson id "$1" --arg status "$2" --arg source "$3" --arg target "$4" --arg closed "$5" \
    --arg sha "$6" --arg title "$7" --arg body "$8" '{id:$id,title:$title,description:$body,
      status:$status,draft:false,source:"refs/heads/\($source)",target:"refs/heads/\($target)",
      created:"2026-10-01T08:00:00.123456+00:00",closed:(if $closed == "null" then null else $closed end),
      merge_commit:(if $sha == "null" then null else $sha end)}'
}
ado_run() {  # <id> <name> <result> <sha> <repo>
  jq -cn --argjson id "$1" --arg name "$2" --arg result "$3" --arg sha "$4" --arg repo "$5" \
    '{id:$id,name:$name,status:"completed",result:$result,reason:"individualCI",sha:$sha,repo:$repo,queued:"2026-10-02T00:00:00.1+00:00"}'
}
in_home() {
  PATH="$H/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
    FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" FM_TEST_FORGE="$FORGE" FM_TEST_CALLS="$S/calls.log" "$@"
}

case "$cmd" in
setup)
  mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin" "$FORGE" "$UP"
  chmod 700 "$H" "$H/data" "$H/state" "$H/config"
  cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
  : > "$S/calls.log"
  for tool in tmux treehouse no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$tool"; chmod +x "$H/fakebin/$tool"
  done
  cat > "$H/fakebin/az" <<'SH'
#!/usr/bin/env bash
printf 'az %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$FM_TEST_CALLS"
repo= branch= project=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repo=$2; shift ;;
    --project) project=$2; shift ;;
    --branch) branch=${2##*/}; shift ;;
  esac
  shift
done
if [ -n "$repo" ]; then file="$FM_TEST_FORGE/az-prs-$repo.json"; else file="$FM_TEST_FORGE/az-runs-$project-$branch.json"; fi
[ -f "$file" ] || exit 1
cat "$file"
SH
  # The real git; a fetch of the fixture forge's address is served from the
  # local upstream of the same name (a missing one fails as an unreachable forge).
  cat > "$H/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*)
    printf 'git %s\n' "\$*" >> "\$FM_TEST_CALLS"
    export GIT_CONFIG_VALUE_0="\$FM_TEST_FORGE/upstream/\${GIT_CONFIG_VALUE_0##*/}"
    ;;
esac
exec "$(command -v git)" "\$@"
SH
  chmod +x "$H/fakebin/az" "$H/fakebin/git"

  # Upstream history: one branch per environment.
  g init -q; g checkout -q -b main
  change base.txt 'Base'
  g branch release/uat; g branch release/prod
  change everywhere.txt 'Everywhere'; M54=$(git -C "$UP" rev-parse HEAD)
  M55=$(land release/uat main); M56=$(land release/prod release/uat)
  g checkout -q -b fm/st-devonly main; change devonly.txt 'Dev only'; M51=$(land main fm/st-devonly)
  g checkout -q -b fm/st-picked main; change picked.txt 'Picked one'; change picked.txt 'Picked two'
  M52=$(land main fm/st-picked)
  g checkout -q -b cherry/uat-52 release/uat; g cherry-pick -x fm/st-picked~1 fm/st-picked
  M53=$(land release/uat cherry/uat-52)
  g checkout -q -b cherry/prod-53 release/prod; g cherry-pick -x -m 1 "$M53"
  M58=$(land release/prod cherry/prod-53)
  g checkout -q -b fm/st-halfway main; change halfway.txt 'Halfway'; M59=$(land main fm/st-halfway)
  g checkout -q -b cherry/uat-59 release/uat; g cherry-pick -x fm/st-halfway
  M60=$(land release/uat cherry/uat-59)
  g checkout -q -b fm/st-redone main; change redone.txt 'Redone'; M61=$(land main fm/st-redone)
  g checkout -q -b fm/st-redone-uat release/uat; change redone.txt 'Redone'; M62=$(land release/uat fm/st-redone-uat)
  printf '%s\n' "$M60" > "$S/m60"

  d='Stock managers see the weekly total on the first page.'
  {
    ado_pr 51 completed fm/st-devonly main '2026-10-03T10:00:00.5+00:00' "$M51" 'Dev only change' "$d"
    ado_pr 52 completed fm/st-picked main '2026-10-03T10:10:00.5+00:00' "$M52" 'Picked change' "$d"
    ado_pr 53 completed cherry/uat-52 release/uat '2026-10-03T10:20:00.5+00:00' "$M53" 'Promote the picked change to UAT' "$d"
    ado_pr 54 completed fm/st-everywhere main '2026-10-03T09:00:00.5+00:00' "$M54" 'Everywhere change' "$d"
    ado_pr 55 completed promote/uat release/uat '2026-10-03T09:10:00.5+00:00' "$M55" 'Promote to UAT' "$d"
    ado_pr 56 completed promote/prod release/prod '2026-10-03T09:20:00.5+00:00' "$M56" 'Promote to PROD' "$d"
    ado_pr 58 completed cherry/prod-53 release/prod '2026-10-03T10:30:00.5+00:00' "$M58" 'Promote the picked change to PROD' "$d"
    ado_pr 59 completed fm/st-halfway main '2026-10-03T10:40:00.5+00:00' "$M59" 'Halfway change' "$d"
    ado_pr 60 completed cherry/uat-59 release/uat '2026-10-03T10:50:00.5+00:00' "$M60" 'Promote the halfway change to UAT' "$d"
    ado_pr 61 completed fm/st-redone main '2026-10-03T11:00:00.5+00:00' "$M61" 'Redone change' "$d"
    ado_pr 62 completed fm/st-redone-uat release/uat '2026-10-03T11:10:00.5+00:00' "$M62" 'Redo on UAT' "$d"
    ado_pr 63 active fm/st-open main null null 'Open one' "$d"
  } | jq -cs . > "$FORGE/az-prs-stages.json"
  ado_run 301 stages-deploy succeeded "$M61" stages | jq -cs . > "$FORGE/az-runs-Stages-main.json"
  ado_run 302 stages-deploy failed "$M62" stages | jq -cs . > "$FORGE/az-runs-Stages-uat.json"
  ado_run 303 stages-deploy succeeded "$M58" stages | jq -cs . > "$FORGE/az-runs-Stages-prod.json"
  # ledger: listed environments, pull requests readable, branch history unreachable.
  ado_pr 31 completed fm/ledger-fix main '2026-10-03T10:00:00.5+00:00' "$M51" 'Ledger fix' "$d" | jq -cs . > "$FORGE/az-prs-ledger.json"
  echo '[]' > "$FORGE/az-runs-Ledger-main.json"
  # site: one environment only, not in the list.
  ado_pr 41 completed fm/site-banner main '2026-10-03T10:00:00.5+00:00' "$M51" 'New banner' "$d" | jq -cs . > "$FORGE/az-prs-site.json"
  echo '[]' > "$FORGE/az-runs-Site-main.json"

  for p in stages:Stages ledger:Ledger site:Site; do
    name=${p%%:*}
    git init -q "$H/projects/$name"
    git -C "$H/projects/$name" remote add origin "https://someone:not-a-real-token@dev.azure.com/acme-org/${p##*:}/_git/$name"
    printf -- '- %s [direct-PR] - fixture (added 2026-01-01)\n' "$name" >> "$H/data/projects.md"
    (cd "$H" && tasks-axi add "$name-task" "Open work in $name" --repo "$name" --kind ship >/dev/null)
  done
  printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$H/config/live-board.json"
  echo "home: $H"
  ;;
build)
  rm -f "$H/state/.live-board-prs-attempt"
  in_home "$ROOT/bin/fm-live-board.sh" build
  ;;
promote)
  g checkout -q -b cherry/prod-60 release/prod
  g cherry-pick -x -m 1 "$(cat "$S/m60")"
  M66=$(land release/prod cherry/prod-60)
  jq -c --arg sha "$M66" '. + [{id:66,title:"Promote the halfway change to PROD",description:"Carries the halfway change into production.",
    status:"completed",draft:false,source:"refs/heads/cherry/prod-60",target:"refs/heads/release/prod",
    created:"2026-10-04T08:00:00.123456+00:00",closed:"2026-10-04T09:00:00.5+00:00",merge_commit:$sha}]' \
    "$FORGE/az-prs-stages.json" > "$FORGE/az-prs-stages.tmp" && mv "$FORGE/az-prs-stages.tmp" "$FORGE/az-prs-stages.json"
  echo "promoted: $M66"
  ;;
esac
