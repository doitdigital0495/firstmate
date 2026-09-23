#!/usr/bin/env bash
# Drives bin/fm-pr-poll.sh's Azure DevOps branch end to end with real git
# (bare "origin" whose path mimics the ADO clone URL) and a logging fake az,
# because the intent forbids contacting the real Geris workspace.
set -u
POLL=${1:?poll path}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
URL=https://dev.azure.com/Org-1/Insights-Requests/_git/fabric_monorepo/pullrequest/801
ORIGIN="$T/remote/dev.azure.com/Org-1/Insights-Requests/_git/fabric_monorepo"
mkdir -p "$T/bin" "$T/state" "$(dirname "$ORIGIN")"
cat > "$T/bin/az" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AZ_LOG:?}"
case "$*" in
  *'repos pr show'*)
    [ "$AZ_PR" = fail ] && exit 1
    printf '%s\n' "$AZ_PR" | tr '|' '\n' ;;
  *'pipelines runs list'*)
    [ "${AZ_RUNS:-}" = fail ] && exit 1
    printf '%b' "${AZ_RUNS:-}" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$T/bin/az"
export AZ_LOG="$T/az.log" PATH="$T/bin:$PATH"
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
# Publish by fetching into the bare origin: the host's global pre-receive hook
# refuses pushes from inside a no-mistakes step.
g init -q --bare "$ORIGIN"
g init -q "$T/seed"
publish() { git -C "$ORIGIN" fetch -q --force "$T/seed" 'refs/heads/*:refs/heads/*'; }
( cd "$T/seed" && printf 'a\n' > f && g add f && g commit -qm base >/dev/null 2>&1
  g checkout -qb fm-test && printf 'src\n' > f && g commit -qam src >/dev/null 2>&1
  g checkout -q main && printf 'other\n' > g2 && g add g2 && g commit -qm clean-tgt >/dev/null 2>&1 )
publish
g clone -q "$ORIGIN" "$T/wt" 2>/dev/null
printf 'worktree=%s\n' "$T/wt" > "$T/state/task-a.meta"
run() {
  printf '\n### %s\n' "$1"
  out=$(bash "$POLL" --validated ado "$URL" dev.azure.com Org-1/Insights-Requests/_git/fabric_monorepo 801 "$T/state" task-a)
  printf 'poll stdout: %s\n' "${out:-<empty>}"
}
ACTIVE='active|queued|refs/heads/main|refs/heads/fm-test|None|None'
export AZ_PR=$ACTIVE
run "open PR, forge mergeStatus=queued, branches merge cleanly (git probe)"
( cd "$T/seed" && printf 'conflicting\n' > f && g commit -qam tgt-conflict >/dev/null 2>&1 ); publish
run "open PR, forge mergeStatus=queued (lagging), target now conflicts (git probe)"
AZ_PR='active|conflicts|refs/heads/main|refs/heads/fm-test|None|None' run "open PR, forge itself reports conflicts"
AZ_PR=fail run "adversarial: az lookup fails during conflict -> must stay silent (no false clear)"
( cd "$T/seed" && g checkout -q fm-test && g merge -q -X theirs main >/dev/null 2>&1 && g checkout -q main ); publish
run "worker rebased/merged target into source (forge still queued) -> git probe confirms clear"
printf 'worktree=relative/path\n' > "$T/state/task-a.meta"
run "adversarial: doctored meta (relative worktree) -> probe refused, no claim"
printf 'worktree=%s\n' "$T/wt" > "$T/state/task-a.meta"
( cd "$T/wt" && git remote set-url origin "$T/remote/evil/repo" )
run "adversarial: worktree origin is a different repo -> probe refused, no claim"
( cd "$T/wt" && git remote set-url origin "$ORIGIN" )
MC=0123456789abcdef0123456789abcdef01234567
OLD=2020-01-01T00:00:00.296140+00:00
export AZ_PR="completed|None|refs/heads/main|refs/heads/fm-test|$MC|$OLD"
AZ_RUNS='fabric-deploy\tcompleted\tsucceeded\t8513\nreports-deploy\tcompleted\tfailed\t8519\ndbt-dev-build\tcompleted\tcanceled\t8521\n' \
  run "merged PR, runs on merge commit: one success, one failure, one cancel"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000000+00:00)
AZ_PR="completed|None|refs/heads/main|refs/heads/fm-test|$MC|$NOW" AZ_RUNS='' \
  run "merged just now, no runs yet -> wait silently inside grace window"
AZ_PR="completed|None|refs/heads/main|refs/heads/fm-test|$MC|$NOW" AZ_RUNS='fabric-deploy\tinProgress\tNone\t8513\n' \
  run "merged just now, run still in progress -> wait silently"
AZ_RUNS='prod-deploy\tnotStarted\tNone\t8530\n' run "adversarial: run stuck pending past 7200s cap -> merge still reported"
AZ_RUNS=fail run "adversarial: runs unreadable past cap -> merge still reported"
AZ_RUNS='' run "merged long ago, no runs ever -> terminal line"
AZ_PR='abandoned|None|refs/heads/main|refs/heads/fm-test|None|None' run "abandoned PR -> silent"
printf '\n### every az invocation made (must be read-only show/list only)\n'
cat "$AZ_LOG"
printf '\n### refs written into task worktree by probe\n'
git -C "$T/wt" for-each-ref --format='%(refname)' refs/remotes
