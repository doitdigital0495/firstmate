#!/usr/bin/env bash
# Firstmate-imposed hold grammar: recognition, writers, and the position-
# independent fold that reads them back.
#
# A steer where firstmate itself tells a worker or secondmate to hold, or to
# start nothing, is recorded as a keyed paused line under the reserved
# imposed-hold- key namespace, so it survives the target's later lines and no
# other writer - worker, answered: note, or --resolve-key - can close
# firstmate's hold. These tests pin the reader/writer halves
# (bin/fm-classify-lib.sh) with no endpoint or harness process:
#   1. Only a pause carrying the imposer tag and a well-formed imposed-hold-
#      <id> key reads as an imposed hold; worker pauses, captain-held
#      transfers, and prose look-alikes do not.
#   2. The builders round-trip through the readers, keep the until tail and
#      the key structure under any cap, and cap only the prose.
#   3. The fold returns the newest open hold as id/at/until, closes only on a
#      matching-key resolved line, treats a missing until as empty (fail-safe
#      lapsed for the watcher), and lets a renewal supersede.
#   4. The reserved namespace is honored where it must be: an imposed line
#      never lists as an open decision and never reads as closable by an
#      unrelated answered: note.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-imposed-hold)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
STATE=$FM_STATE_OVERRIDE

ID=aaaabbbbccccdddd
ID2=1111222233334444
UNTIL=2030-01-02T03:04Z

imposed_line() {  # [reason] -> full builder output with the canonical shape
  status_hold_imposed_line "$ID" "$UNTIL" "${1:-hold for the vendor answer}"
}

test_recognition() {
  [ "$(status_hold_imposed_id "$(imposed_line)")" = "$ID" ] \
    || fail "canonical imposed line did not read back its id"
  status_is_hold_imposed "$(imposed_line)" \
    || fail "canonical imposed line did not pass the predicate"
  # A worker's own paused: declaration and a captain-held transfer are not
  # firstmate holds, and neither is prose that merely mentions the key.
  if status_hold_imposed_id 'paused: waiting on the vendor'; then
    fail "worker pause read as an imposed hold"
  fi
  if status_hold_imposed_id 'captain-held [key=imposed-hold-'"$ID"']: transferred'; then
    fail "captain-held line read as an imposed hold"
  fi
  if status_hold_imposed_id 'paused [hold=firstmate]: prose mentions imposed-hold-'"$ID"' only'; then
    fail "prose mention read as an imposed hold key"
  fi
  if status_hold_imposed_id 'working [hold=firstmate] [key=imposed-hold-'"$ID"']: not paused'; then
    fail "non-pause verb with tag and key read as an imposed hold"
  fi
  pass "recognition requires the pause verb, imposer tag, and imposed-hold- key"
}

test_builders_round_trip_and_cap() {
  local line
  line=$(imposed_line)
  [ "$(status_paused_until "$line")" = "$(fm_utc_iso_to_epoch "$UNTIL")" ] \
    || fail "builder's until did not round-trip through the pause reader"
  # Cap only the prose: every structural byte, including the until tail,
  # survives a cap tighter than the fixed bytes alone.
  line=$(status_hold_imposed_line "$ID" "$UNTIL" "a reason longer than any budget here" 90)
  case "$line" in
    *"until $UNTIL") ;;
    *) fail "cap ate the until tail: $line" ;;
  esac
  [ "$(status_hold_imposed_id "$line")" = "$ID" ] \
    || fail "capped line no longer reads back its id"
  case "$line" in
    *budget*) fail "cap left prose in a line too tight for it: $line" ;;
  esac
  line=$(status_hold_release_line "$ID" "resume normal work")
  [ "$(status_line_verb "$line")" = "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}" ] \
    || fail "release line verb is not resolved"
  [ "$(_fm_decision_key "$line" || true)" = "imposed-hold-$ID" ] \
    || fail "release line lost its key"
  case "$line" in
    *"released by firstmate: resume normal work") ;;
    *) fail "release line note malformed: $line" ;;
  esac
  pass "builders round-trip and the cap touches only the prose"
}

test_fold_newest_close_supersede() {
  local f="$STATE/fold.status" row
  : > "$f"
  if status_open_imposed_hold "$f"; then
    fail "empty fold reported an open hold"
  fi
  printf 'working [at=100]: started\n' > "$f"
  if status_open_imposed_hold "$f"; then
    fail "no imposed line yet, fold reported an open hold"
  fi
  : > "$f"
  printf 'paused [hold=firstmate] [at=1000] [key=imposed-hold-%s]: imposed-hold-%s: hold until %s\n' "$ID" "$ID" "$UNTIL" >> "$f"
  printf 'working [at=1100]: target kept busy on other work\n' >> "$f"
  printf 'blocked [at=1150] [key=other]: unrelated key\n' >> "$f"
  row=$(status_open_imposed_hold "$f") || fail "fold lost an open hold behind later lines"
  [ "$(printf '%s' "$row" | cut -f1)" = "$ID" ] || fail "fold returned the wrong id: $row"
  [ "$(printf '%s' "$row" | cut -f2)" = 1000 ] || fail "fold lost the stamped at-epoch: $row"
  [ "$(printf '%s' "$row" | cut -f3)" = "$(fm_utc_iso_to_epoch "$UNTIL")" ] \
    || fail "fold lost the until epoch: $row"
  # A foreign resolved key and an answered: note close nothing.
  printf 'resolved [at=1200] [key=other]: answered: proceed\n' >> "$f"
  printf 'resolved [at=1250]: answered: release the hold please\n' >> "$f"
  status_open_imposed_hold "$f" >/dev/null || fail "foreign resolved lines closed firstmate's hold"
  # The matching-key release closes it.
  printf '%s\n' "$(status_hold_release_line "$ID" "released")" >> "$f"
  if status_open_imposed_hold "$f"; then
    fail "matching-key release did not close the hold"
  fi
  # A renewal supersedes: newest open wins, and the old id's late release
  # cannot resurrect or steal the new one.
  printf 'paused [hold=firstmate] [at=2000] [key=imposed-hold-%s]: imposed-hold-%s: renewed until %s\n' "$ID2" "$ID2" "$UNTIL" >> "$f"
  printf '%s\n' "$(status_hold_release_line "$ID" "stale release")" >> "$f"
  row=$(status_open_imposed_hold "$f") || fail "stale release erased the renewed hold"
  [ "$(printf '%s' "$row" | cut -f1)" = "$ID2" ] || fail "fold did not keep the newest hold: $row"
  pass "fold: newest open wins, only its own key closes it, renewal supersedes"
}

test_missing_until_is_fail_safe_lapsed() {
  local f="$STATE/no-until.status" row
  printf 'paused [hold=firstmate] [key=imposed-hold-%s]: imposed-hold-%s: hold, no time stated\n' "$ID" "$ID" > "$f"
  row=$(status_open_imposed_hold "$f") || fail "unparseable until broke the fold open"
  [ -z "$(printf '%s' "$row" | cut -f3)" ] \
    || fail "missing until did not surface as empty: $row"
  pass "a hold with no readable until surfaces empty, never far-future"
}

test_reserved_namespace_protection() {
  local f="$STATE/reserved.status"
  printf 'paused [hold=firstmate] [at=1000] [key=imposed-hold-%s]: imposed-hold-%s: hold until %s\n' "$ID" "$ID" "$UNTIL" > "$f"
  printf 'needs-decision [at=1100] [key=real-key]: a real decision\n' >> "$f"
  local open
  open=$(status_open_decisions "$f")
  printf '%s' "$open" | grep -F "imposed-hold-$ID" >/dev/null \
    && fail "imposed hold listed as an open decision"
  printf '%s' "$open" | grep -F 'real-key' >/dev/null \
    || fail "fold dropped the real decision: $open"
  pass "imposed-hold- keys stay out of the decision fold"
}

fm_test_run \
  test_recognition \
  test_builders_round_trip_and_cap \
  test_fold_newest_close_supersede \
  test_missing_until_is_fail_safe_lapsed \
  test_reserved_namespace_protection
