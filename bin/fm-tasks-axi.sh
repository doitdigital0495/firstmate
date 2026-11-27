#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
#
# Two commands are this wrapper's own rather than tasks-axi's (the lean-memory
# row lapse; docs/configuration.md "Backlog backend" owns the operator view):
#   lapse-due   list Queued rows that may lapse, one `<id> TAB <since> TAB <repo>`
#               line each, read-only in every mode.
#   lapse       close each of those rows with plain
#               `tasks-axi done <id> --note 'lapsed unstarted'` at the default
#               keep value, so Done is trimmed only as any ordinary close trims
#               it and no other row is touched. The done-archive note is the
#               lapse record; a lapsed row that matters is re-filed.
# Both print a final `lapse mode=<shadow|on> due=<n> closed=<n>` line, plus one
# `queued-over-limit queued=<n> limit=30` line when the home would still hold
# more than 30 Queued rows after the closes (the shadow run counts the rows it
# would have closed); the later weekly sweep owns acting on that line.
# A row is due only when ALL of these hold: Queued, kind other than
# secondmate or captain, unheld, no open blocked-by, `since` 14 or more days ago,
# no link to an item of an ON goal (bin/fm-goal.sh launch-links, any verdict but
# `off`), and never started: no state/<id>.meta, no state/<id>.status, no
# data/<id>/ and no local or remote branch or worktree ending in the id inside
# projects/<repo>. History that cannot be read (no repo, no clone, a git or goal
# read failure, an unusable id or date) means the row is NOT due, because
# tasks-axi keeps no first-start field. `lapse` closes rows only when
# config/record-sweep holds `on` (a regular file, not a symlink); an absent or
# any other value is shadow and `lapse` then only lists, like `lapse-due`.
# `lapse` exits 1 when a goal-link or backlog read fails or a close fails.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LAPSE_QUEUED_LIMIT=30
LAPSE_AGE_DAYS=14
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
lapse_mode() {  # on only for a regular, non-symlink config/record-sweep reading `on`
  local m=''
  if [ -f "$CONFIG/record-sweep" ] && [ ! -L "$CONFIG/record-sweep" ]; then
    read -r m < "$CONFIG/record-sweep" || true
  fi
  [ "$m" = on ] && printf on || printf shadow
}

# Succeeds only when the local records prove <id> never started in <repo>.
lapse_never_started() {  # <id> <repo>
  local id=$1 repo=$2 clone path ref
  fm_task_id_creation_valid "$id" || return 1
  case "$repo" in ''|-|*/*|.*|-*) return 1 ;; esac
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || return 1
  [ ! -e "$STATE/$id.status" ] && [ ! -L "$STATE/$id.status" ] || return 1
  [ ! -e "$DATA/$id" ] && [ ! -L "$DATA/$id" ] || return 1
  clone="$PROJECTS/$repo"
  [ -d "$clone" ] || return 1
  ref=$(git -C "$clone" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null) || return 1
  case "$ref" in *"$id"$'\n'*|*"$id") return 1 ;; esac
  path=$(git -C "$clone" worktree list --porcelain 2>/dev/null | grep -E '^(worktree|branch) ') || return 1
  case "$path" in *"$id"$'\n'*|*"$id") return 1 ;; esac
  return 0
}

# Prints the due rows as `<id> TAB <since> TAB <repo>` lines, then
# `queued <n>` for the Queued total; returns 1 when a read fails.
lapse_candidates() {
  local rows links cutoff id kind repo created held blocked rest total=0
  rows=$(tasks-axi list --state queued --fields created,held,blocked 2>/dev/null) || return 1
  links=$("$SCRIPT_DIR/fm-goal.sh" launch-links 2>/dev/null) || return 1
  cutoff=$(date -u -d "@$(( $(date +%s) - LAPSE_AGE_DAYS * 86400 ))" +%F 2>/dev/null \
    || date -u -r "$(( $(date +%s) - LAPSE_AGE_DAYS * 86400 ))" +%F 2>/dev/null) || return 1
  case "$cutoff" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  while IFS= read -r rest; do
    case "$rest" in "  "[!\ ]*,queued,*) ;; *) continue ;; esac
    total=$((total + 1))
    rest=${rest#  }
    id=${rest%%,*}
    # Fixed trailing fields (created,held,blocked) come off the right because a
    # title may itself hold commas; kind and repo precede the title.
    blocked=${rest##*,}; rest=${rest%,*}
    held=${rest##*,}; rest=${rest%,*}
    created=${rest##*,}; rest=${rest%,*}
    kind=${rest#*,queued,}; kind=${kind%%,*}
    repo=${rest#*,queued,*,}; repo=${repo%%,*}
    [ "$held" = no ] && [ "$blocked" = no ] || continue
    case "$kind" in secondmate|captain) continue ;; esac
    case "$created" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
    [[ ! "$created" > "$cutoff" ]] || continue
    if awk -F'\t' -v id="$id" '$1 == id && $2 != "off" { found = 1 } END { exit !found }' <<< "$links"; then
      continue
    fi
    lapse_never_started "$id" "$repo" || continue
    printf '%s\t%s\t%s\n' "$id" "$created" "$repo"
  done <<< "$rows"
  printf 'queued %s\n' "$total"
}

lapse_command() {  # lapse-due | lapse
  local cmd=$1 mode out line total=0 due=0 closed=0 rc=0 id
  mode=$(lapse_mode)
  out=$(lapse_candidates) || { printf 'fm-tasks-axi: cannot read the backlog or goal links; nothing lapses\n' >&2; return 1; }
  while IFS= read -r line; do
    case "$line" in
      'queued '*) total=${line#queued }; continue ;;
      '') continue ;;
    esac
    id=${line%%$'\t'*}
    due=$((due + 1))
    if [ "$cmd" = lapse ] && [ "$mode" = on ]; then
      if tasks-axi 'done' "$id" --note 'lapsed unstarted' >/dev/null 2>&1; then
        closed=$((closed + 1))
        printf 'lapsed\t%s\n' "$line"
      else
        rc=1
        printf 'failed\t%s\n' "$line"
      fi
    elif [ "$cmd" = lapse ]; then
      printf 'would-lapse\t%s\n' "$line"
    else
      printf '%s\n' "$line"
    fi
  done <<< "$out"
  printf 'lapse mode=%s due=%s closed=%s\n' "$mode" "$due" "$closed"
  # Shadow counts the rows it would have closed, so the wake-worthy line reads
  # the same before and after the switch is turned on.
  if [ "$mode" = on ] && [ "$cmd" = lapse ]; then total=$((total - closed)); else total=$((total - due)); fi
  [ "$total" -le "$LAPSE_QUEUED_LIMIT" ] || printf 'queued-over-limit queued=%s limit=%s\n' "$total" "$LAPSE_QUEUED_LIMIT"
  return "$rc"
}
case "${1:-}" in
  lapse-due|lapse)
    [ "$#" -eq 1 ] || fail "${1} takes no arguments"
    lapse_command "$1"
    exit $?
    ;;
esac
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
