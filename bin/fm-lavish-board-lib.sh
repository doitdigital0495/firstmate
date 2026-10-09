#!/usr/bin/env bash
# fm-lavish-board-lib.sh - serve a captain-facing Lavish board and arm its answers.
#
# Sourced, never executed. Shared by bin/fm-bearings-board.sh and
# bin/fm-live-board.sh so both boards establish, prove, bind and arm their
# Lavish session through one sequence. The caller must define `fail <message>`
# (print and exit nonzero); every refusal below goes through it.
#
#   fm_lavish_board_serve <board.html>
#       Establish the Lavish session on the board and PROVE it is live BEFORE
#       binding and arming its answer source, so a registered poll can never
#       race a session that does not exist or attach to one that has ended.
#       Binding to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#       precedes arm, so the board can never produce an answer that has nowhere
#       to go (captain-hold-lifecycle's ordering rule, enforced here rather than
#       left to agent memory). Prints lavish-axi's session output followed by:
#         session: live | reopened
#         served: <path>
#         bound: <source-id>
#         armed: <source-id>            (first registration)
#         already-armed: <source-id>    (registration already present)
#         listening: live               (only when a replacement was needed)
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. Serving requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. A session the captain ended is reopened once - the
# caller asked for this board, which is exactly the attention `--reopen` exists
# for. After a reopen it retires the pre-reopen source generation through the
# guarded adapter path, arms a fresh registration, and accepts only the
# replacement listener as live. A registered board with no live owner also gets
# a replacement before serving returns, because `already-armed` is not the same
# fact as `listening`. Verified against lavish-axi 0.1.61.

FM_LAVISH_BOARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_lavish_board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

fm_lavish_board_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
fm_lavish_board_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

# Sets FM_LAVISH_BOARD_REOPENED=1 when the session had to be reopened.
fm_lavish_board_establish() {  # <board>
  local board=$1 real out status version
  FM_LAVISH_BOARD_REOPENED=0
  real=$(fm_lavish_board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if fm_lavish_board_listed_open "$real"; then
    printf 'session: live\n'
    return 0
  fi
  out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if fm_lavish_board_listed_open "$real"; then
    FM_LAVISH_BOARD_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(fm_lavish_board_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
fm_lavish_board_source_owner() {  # <source-id>
  "$FM_LAVISH_BOARD_LIB_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
fm_lavish_board_await_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(fm_lavish_board_source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

fm_lavish_board_serve() {  # <board>
  local board=$1 sid owner version pre_reopen_owner
  local adapter="$FM_LAVISH_BOARD_LIB_DIR/fm-procevent-lavish.sh"
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$adapter" source-id "$board") || fail "cannot derive the board source id"
  pre_reopen_owner=$(fm_lavish_board_source_owner "$sid")
  fm_lavish_board_establish "$board"
  if [ "$FM_LAVISH_BOARD_REOPENED" = 1 ]; then
    "$adapter" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! fm_lavish_board_listed_open "$(fm_lavish_board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$FM_LAVISH_BOARD_LIB_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(fm_lavish_board_source_owner "$sid")
  if [ "$FM_LAVISH_BOARD_REOPENED" = 1 ]; then
    "$adapter" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(fm_lavish_board_source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$adapter" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(fm_lavish_board_source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$FM_LAVISH_BOARD_LIB_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(fm_lavish_board_await_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}
