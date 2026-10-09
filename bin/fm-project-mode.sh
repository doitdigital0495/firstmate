#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   An extra `preview-on-push` token after the mode is read by firstmate at
#   intake (AGENTS.md section 7) and ignored here.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# --list-json returns {present,projects:[{name,mode,yolo,recognised,annotation}],
# duplicates:[]}, enumerating names and raw registered posture only, never
# descriptions or remotes. Unknown modes retain the fail-safe fallback and
# recognised:false. Duplicate names retain the first posture and are disclosed.
# A missing registry is present:false, not an empty registered portfolio.
# Usage: fm-project-mode.sh [--raw] <project-name> | --list-json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
# Enumerate through the same posture parser used by mechanical callers.
registered_posture() {  # <name>
  awk -v n="$1" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    print mode, yolo; exit
  }
' "$REG"
}
known_mode() {
  case "$1" in no-mistakes|direct-PR|local-only|no-mistakes-prod-only) return 0 ;; esac
  return 1
}
usage() { printf '%s\n' 'usage: fm-project-mode.sh [--raw] <project-name> | --list-json'; }
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then usage; exit 0; fi
if [ "${1:-}" = --list-json ]; then
  [ "$#" = 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo 'fm-project-mode: jq not found' >&2; exit 1; }
  if [ ! -f "$REG" ]; then printf '{"present":false,"projects":[],"duplicates":[]}\n'; exit 0; fi
  names=$(awk '$1=="-" && $2!="" {print $2}' "$REG")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    posture=$(registered_posture "$name")
    mode=${posture%% *}; yolo=${posture##* }; recognised=true
    annotation=$mode
    if ! known_mode "$mode"; then mode=no-mistakes; yolo=off; recognised=false; fi
    jq -n --arg name "$name" --arg mode "$mode" --arg yolo "$yolo" \
      --arg annotation "$annotation" --argjson recognised "$recognised" \
      '{name:$name,mode:$mode,yolo:$yolo,recognised:$recognised,annotation:$annotation}'
  done <<EOF | jq -s '{present:true,projects:unique_by(.name),duplicates:[group_by(.name)[] | select(length>1) | .[0].name]}'
$names
EOF
  exit 0
fi
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

parsed=$(registered_posture "$NAME")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
if ! known_mode "$mode"; then
  echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off
fi
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
