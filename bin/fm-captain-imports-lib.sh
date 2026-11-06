# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_CAPTAIN_IMPORTS_ERROR and FM_CAPTAIN_IMPORTS_REASON are results callers read after sourcing.
# fm-captain-imports-lib.sh - the home-local Claude import of captain memory.
#
# Usage: . bin/fm-captain-imports-lib.sh
#
# A primary home's captain-private curated memory - data/captain.md,
# data/captain-shared.md, and data/learnings.md - is loaded into a Claude
# primary session as instructions, through @-imports in the gitignored
# home-local instruction file CLAUDE.local.md at the home root. Claude Code
# loads that file beside the tracked CLAUDE.md and re-loads it after every
# compaction, so a context re-emit (bin/fm-session-start.sh --reemit) does not
# have to reprint the three files. The tracked CLAUDE.md stays the shared
# @AGENTS.md pointer: these files are captain-private and gitignored, so the
# import must live in the home, never in tracked material.
#
# This library is the one owner of the file's name, its canonical content, its
# creation rule, and the "imports are live" test:
#   fm_captain_imports_materialize <home>
#     Creates <home>/CLAUDE.local.md with the canonical content when it is
#     absent. Primary homes only: a secondmate home (.fm-secondmate-home marker)
#     is left untouched and returns 0. An existing file that already carries all
#     three import lines is kept as the captain left it. Any other existing path
#     is never overwritten: it returns 1 with the reason in
#     FM_CAPTAIN_IMPORTS_ERROR.
#   fm_captain_imports_active <home> <harness>
#     Returns 0 only when the three files are really imported into this session:
#     the harness is claude, <home>/CLAUDE.local.md is a regular file carrying
#     all three import lines, and the Claude project directory (when the harness
#     names one) is the home itself. Otherwise returns 1 with the reason in
#     FM_CAPTAIN_IMPORTS_REASON.
#
# Why the project directory must be the home: Claude Code loads an @-import
# without approval only when the imported path lies inside the session's
# project directory. An import outside it is an "external import", which is
# skipped until the captain approves external imports for that project. A
# session started in the home itself therefore loads the three files with no
# prompt, while a session started below the home (a project clone under
# projects/) may load CLAUDE.local.md through the upward walk but skips its
# imports, which keeps captain-private memory out of project sessions.
# Imports nest at most five levels deep; this file uses one.
# docs/verification/runtime-backends.md records the checked Claude version.

FM_CAPTAIN_IMPORTS_FILE=CLAUDE.local.md
FM_CAPTAIN_IMPORTS_ERROR=
FM_CAPTAIN_IMPORTS_REASON=

fm_captain_imports_content() {
  printf '%s\n' \
    '<!-- Maintained by bin/fm-bootstrap.sh (bin/fm-captain-imports-lib.sh) for this primary home. -->' \
    '<!-- Gitignored and captain-private: it loads curated captain memory into every Claude turn. -->' \
    '@data/captain.md' \
    '@data/captain-shared.md' \
    '@data/learnings.md'
}

# 0 when <file> carries every import line on a line of its own.
fm_captain_imports_lines_present() {  # <file>
  local file=$1 line
  [ -f "$file" ] && [ -r "$file" ] || return 1
  for line in '@data/captain.md' '@data/captain-shared.md' '@data/learnings.md'; do
    grep -Fqx -- "$line" "$file" 2>/dev/null || return 1
  done
}

fm_captain_imports_materialize() {  # <home>
  local home=$1 target tmp
  FM_CAPTAIN_IMPORTS_ERROR=
  if [ -e "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ]; then
    return 0
  fi
  target="$home/$FM_CAPTAIN_IMPORTS_FILE"
  if [ -L "$target" ]; then
    FM_CAPTAIN_IMPORTS_ERROR="$FM_CAPTAIN_IMPORTS_FILE is a symlink; replace it with a regular file carrying the three @data/ import lines"
    return 1
  fi
  if [ -e "$target" ]; then
    if [ -f "$target" ] && fm_captain_imports_lines_present "$target"; then
      return 0
    fi
    FM_CAPTAIN_IMPORTS_ERROR="$FM_CAPTAIN_IMPORTS_FILE exists without the @data/captain.md, @data/captain-shared.md, and @data/learnings.md import lines; add them or remove the file so bootstrap recreates it"
    return 1
  fi
  [ -d "$home" ] || { FM_CAPTAIN_IMPORTS_ERROR="home $home is not a directory"; return 1; }
  tmp=$(mktemp "$home/.$FM_CAPTAIN_IMPORTS_FILE.XXXXXX" 2>/dev/null) || {
    FM_CAPTAIN_IMPORTS_ERROR="could not create a temporary file in $home"
    return 1
  }
  if fm_captain_imports_content > "$tmp" 2>/dev/null && chmod 0644 "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$target" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  FM_CAPTAIN_IMPORTS_ERROR="could not write $target"
  return 1
}

fm_captain_imports_active() {  # <home> <harness>
  local home=$1 harness=$2 home_phys project_phys
  FM_CAPTAIN_IMPORTS_REASON=
  if [ "$harness" != claude ]; then
    FM_CAPTAIN_IMPORTS_REASON="primary harness $harness does not load $FM_CAPTAIN_IMPORTS_FILE imports"
    return 1
  fi
  if [ -L "$home/$FM_CAPTAIN_IMPORTS_FILE" ] || ! fm_captain_imports_lines_present "$home/$FM_CAPTAIN_IMPORTS_FILE"; then
    FM_CAPTAIN_IMPORTS_REASON="$home/$FM_CAPTAIN_IMPORTS_FILE is absent or lacks the three import lines"
    return 1
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    home_phys=$(cd -P "$home" 2>/dev/null && pwd -P) || home_phys=
    project_phys=$(cd -P "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P) || project_phys=
    if [ -z "$home_phys" ] || [ "$home_phys" != "$project_phys" ]; then
      FM_CAPTAIN_IMPORTS_REASON="the Claude project directory $CLAUDE_PROJECT_DIR is not this home, so its imports are external and skipped"
      return 1
    fi
  fi
  return 0
}
