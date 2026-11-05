#!/usr/bin/env bash
# fm-ship-overlap-lib.sh - advisory warning that a ship being dispatched names
# the same project files as a queued or in-flight ship, so firstmate can queue
# one behind the other instead of letting them race the review gate.
#
# A ship records no list of touched paths, so this reads what firstmate already
# holds: the `# Task` section of data/<id>/brief.md and, for a queued ship, its
# backlog notes. A word counts as a named file only when it resolves to a file
# the project tracks, either as a full path or as a trailing part of one
# (`gateway.py` finds `src/gateway.py`), which keeps prose and home paths out.
# Lines opening with `Prior art`, `Out of scope`, `Tests`, `Verification`, or
# `Validation` are skipped, because they name files a task reads, runs, or leaves
# alone. A file a brief does not name, and a file that does not exist yet, cannot
# be flagged.
#
# In-flight means a ship task record in any local home for the same project
# identity (fm_treehouse_project_lock_path), including one whose PR is in review.
# Queued means a queued backlog ship whose repo is the project directory's name.
#
# The warning never blocks a spawn: any read that fails only narrows what it
# can see. bin/fm-spawn.sh owns where the check runs.
#
# Requires bin/fm-wake-lib.sh, bin/fm-backend.sh (fm_meta_get),
# bin/fm-brief-heading-lib.sh, and bin/fm-backlog-transition-lib.sh to be sourced
# first. No side effects on source.

# Print the tracked paths the text on stdin names, sorted and unique.
fm_ship_overlap_paths() {  # <tracked-paths-file>
  sed 's/\\n/ /g' |
    awk 'tolower($0) !~ /^[ \t*-]*(prior art|out of scope|tests?|verification|validation)[ :]/' |
    tr -c 'A-Za-z0-9_./-' '\n' |
    awk -v tracked="$1" '
      BEGIN {
        while ((getline path < tracked) > 0) {
          exact[path] = 1
          tail = path
          while ((slash = index(tail, "/")) > 0) {
            tail = substr(tail, slash + 1)
            tails[tail] = tails[tail] path "\n"
          }
        }
      }
      {
        word = $0
        sub(/^\.\//, "", word)
        sub(/[.-]+$/, "", word)
        if (word !~ /[.\/]/) next
        if (word in exact) print word
        else if (word in tails) printf "%s", tails[word]
      }
    ' |
    LC_ALL=C sort -u
}

fm_ship_overlap_task_text() {  # <brief>
  [ ! -f "$1" ] || fm_brief_heading_body "$1" '# Task' 2>/dev/null
}

# Print one warning when the text on stdin shares named files with this ship.
fm_ship_overlap_report() {  # <id> <own-paths-file> <tracked-paths-file> <other-label>
  local shared count
  shared=$(fm_ship_overlap_paths "$3" | grep -Fxf "$2") || return 0
  count=$(printf '%s\n' "$shared" | wc -l | tr -d ' ')
  shared=$(printf '%s\n' "$shared" | head -n 5 | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
  [ "$count" -le 5 ] || shared="$shared and $((count - 5)) more"
  printf 'warning: ship overlap: %s names the same files as %s: %s; this launch continues, so queue one behind the other if they would race the review gate\n' \
    "$1" "$4" "$shared"
}

# A subshell, so no temp file, trap, or backlog global reaches the caller.
fm_ship_overlap_warn() (  # <id> <project-dir> <brief> <state-dir> <data-dir> <config-dir>
  id=$1 project=$2 brief=$3 first=$4 data=$5 config=$6
  tmp=$(mktemp -d) || exit 0
  trap 'rm -rf "$tmp"' EXIT
  git -C "$project" ls-files > "$tmp/tracked" 2>/dev/null || exit 0
  fm_ship_overlap_task_text "$brief" | fm_ship_overlap_paths "$tmp/tracked" > "$tmp/own"
  [ -s "$tmp/own" ] || exit 0

  own_lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null) || own_lock=
  fm_local_firstmate_state_dirs "$first" 2>/dev/null || FM_LOCAL_FIRSTMATE_STATES=("$first")
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    other_data=$(dirname "$state")/data
    [ "$state" != "$first" ] || other_data=$data
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || continue
      [ "$meta" != "$first/$id.meta" ] || continue
      [ "$(fm_meta_get "$meta" kind)" = ship ] || continue
      other_project=$(fm_meta_get "$meta" project)
      [ -n "$other_project" ] || continue
      if [ "$other_project" != "$project" ]; then
        other_lock=$(fm_treehouse_project_lock_path "$other_project" 2>/dev/null) || continue
        [ -n "$own_lock" ] && [ "$other_lock" = "$own_lock" ] || continue
      fi
      other=$(basename "$meta" .meta)
      label="in-flight ship $other"
      [ "$state" = "$first" ] || label="$label in $(dirname "$state")"
      pr=$(fm_meta_get "$meta" pr)
      [ -z "$pr" ] || label="$label ($pr)"
      fm_ship_overlap_task_text "$other_data/$other/brief.md" |
        fm_ship_overlap_report "$id" "$tmp/own" "$tmp/tracked" "$label"
    done
  done

  fm_backlog_transition_applies "$config" "$data" ship >/dev/null 2>&1 || exit 0
  FM_TASKS_AXI_TIMEOUT=10 fm_backlog_row_list "$data" --state queued --repo "$(basename "$project")" --kind ship --fields body 2>/dev/null |
    awk '/^  [^,]+,queued,ship,/' > "$tmp/queued"
  while IFS= read -r row || [ -n "$row" ]; do
    other=${row#  }
    other=${other%%,*}
    [ "$other" != "$id" ] || continue
    {
      printf '%s\n' "$row"
      fm_ship_overlap_task_text "$data/$other/brief.md"
    } | fm_ship_overlap_report "$id" "$tmp/own" "$tmp/tracked" "queued ship $other"
  done < "$tmp/queued"
)
