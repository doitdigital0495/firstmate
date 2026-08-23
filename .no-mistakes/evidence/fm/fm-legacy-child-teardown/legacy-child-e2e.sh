#!/usr/bin/env bash
# Manual end-to-end reproduction: forced teardown of a secondmate home whose own
# home holds ONE legacy child task record (no endpoint_task_id). Builds the
# fixture with the repo's own test helpers, then runs bin/fm-teardown.sh exactly
# as an operator would and prints what the operator sees.
set -u
ROOT=${ROOT:?set ROOT to the repo root}
# shellcheck disable=SC1091
. "$ROOT/tests/secondmate-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-legacy-child-evidence)
export FM_BACKEND=tmux

make_case() {  # <name> [extra meta lines...]
  local name=$1 dir home subhome childproj childwt fakebin
  shift
  dir="$TMP_ROOT/$name"; home="$dir/home"; subhome="$dir/subhome"
  childproj="$subhome/projects/alpha"; childwt="$dir/child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  fm_git_worktree "$childproj" "$childwt" "legacy-child-$name" >/dev/null 2>&1
  : > "$childwt/sentinel"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_secondmate_meta "$home/state/domain.meta" "$subhome"
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/child.meta" \
    "window=lab:7" "worktree=$childwt" "project=$childproj" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7" "$@"
  fakebin=$(make_fake_tmux "$dir/fake")
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
printf 'zellij %s\n' "$*" >> "${FM_FAKE_ZELLIJ_CALLS:?}"
for arg in "$@"; do
  case "$arg" in
    list-tabs) cat "${FM_FAKE_ZELLIJ_TABS:?}"; exit 0 ;;
    list-sessions) printf 'lab\n'; exit 0 ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/zellij"
  : > "$dir/zellij.calls"
  printf '[{"tab_id":3,"name":"fm-child"}]\n' > "$dir/tabs.json"
  printf '%s\n' "$dir"
}

run_teardown() {  # <dir>
  local dir=$1
  PATH="$dir/fake/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_FAKE_TMUX_LOG="$dir/fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake/pane.txt" \
    FM_FAKE_ZELLIJ_CALLS="$dir/zellij.calls" FM_FAKE_ZELLIJ_TABS="$dir/tabs.json" \
    "$ROOT/bin/fm-teardown.sh" domain --force 2>&1
}

report() {  # <label> <dir> <rc>
  local label=$1 dir=$2 rc=$3
  printf '  exit status: %s\n' "$rc"
  printf '  secondmate home %s still present: %s\n' "$dir/subhome" \
    "$([ -e "$dir/subhome" ] && echo yes || echo no)"
  printf '  child record still present: %s\n' \
    "$([ -e "$dir/subhome/state/child.meta" ] && echo yes || echo no)"
  printf '  child worktree unlanded work still present: %s\n' \
    "$([ -e "$dir/child-worktree/sentinel" ] && echo yes || echo no)"
  printf '  endpoint_task_id written into the child record: %s\n' \
    "$(grep -h '^endpoint_task_id=' "$dir/subhome/state/child.meta" 2>/dev/null || echo '(record gone or unbound)')"
  printf '  live endpoint reads: %s\n' "$(wc -l < "$dir/zellij.calls" | tr -d ' ')"
}

section() { printf '\n================ %s ================\n' "$1"; }

section "CASE 1  legacy child (no endpoint_task_id), live tab proves label fm-child"
d=$(make_case provable); set +e; out=$(run_teardown "$d"); rc=$?; set -e
printf '$ bin/fm-teardown.sh domain --force\n%s\n' "$out"
report provable "$d" "$rc"

section "CASE 2  same legacy child, live tab carries SOMEONE ELSE's label"
d=$(make_case unprovable); printf '[{"tab_id":3,"name":"fm-other"}]\n' > "$d/tabs.json"
set +e; out=$(run_teardown "$d"); rc=$?; set -e
printf '$ bin/fm-teardown.sh domain --force\n%s\n' "$out"
report unprovable "$d" "$rc"

section "CASE 3  current-format child (endpoint_task_id=child) - offline path"
d=$(make_case current endpoint_task_id=child)
set +e; out=$(run_teardown "$d"); rc=$?; set -e
printf '$ bin/fm-teardown.sh domain --force\n%s\n' "$out"
report current "$d" "$rc"

section "CASE 4  legacy child whose OWN metadata lock is held by another process"
d=$(make_case metalock)
lock="$d/subhome/state/.meta-child.lock"
( . "$ROOT/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$lock" || exit 1; sleep 45 ) &
holder=$!
i=0; while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
set +e; out=$(run_teardown "$d"); rc=$?; set -e
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
printf '$ bin/fm-teardown.sh domain --force   # child meta lock held elsewhere\n%s\n' "$out"
report metalock "$d" "$rc"
