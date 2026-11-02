#!/usr/bin/env bash
# Behavior tests for per-file inheritance of config/brief-addenda/<repo>.md.
#
# The set is declared once in bin/fm-config-inherit-lib.sh
# (FM_INHERITABLE_CONFIG_SETS). These tests drive the public propagation entry
# point, the reread helpers, the remote receiver and the remote sender.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-brief-addenda-inherit)

fm_git_identity fmtest fmtest@example.invalid

new_pair() {
  local name=$1 base="$TMP_ROOT/$1"
  mkdir -p "$base/primary/config" "$base/second/config"
  printf '%s\n' "$base"
}

report_status() {  # <report> <item>
  awk -F '\t' -v item="$2" '$1 == item { print $2; exit }' "$1"
}

test_declared_set_and_member_rules() {
  case " $FM_INHERITABLE_CONFIG_SETS " in
    *" brief-addenda "*) ;;
    *) fail "brief-addenda must be a declared inherited set" ;;
  esac
  fm_config_inherit_set_member_valid brief-addenda/acme.md || fail "plain addendum should be a member"
  fm_config_inherit_set_member_valid brief-addenda/a.b_c-1.md || fail "dots, underscores and dashes are valid"
  ! fm_config_inherit_set_member_valid brief-addenda/.fm-inherit-acme.md.lock || fail "hidden names are not members"
  ! fm_config_inherit_set_member_valid brief-addenda/.md || fail ".md is not a member"
  ! fm_config_inherit_set_member_valid brief-addenda/acme.txt || fail "non-md names are not members"
  ! fm_config_inherit_set_member_valid brief-addenda/a\ b.md || fail "names with spaces are not members"
  ! fm_config_inherit_set_member_valid brief-addenda/sub/acme.md || fail "nested paths are not members"
  ! fm_config_inherit_set_member_valid other/acme.md || fail "undeclared sets are not members"
  fm_config_inherit_path_allowed config/brief-addenda/acme.md || fail "receiver should allow a member"
  ! fm_config_inherit_path_allowed config/brief-addenda/.hidden.md || fail "receiver must refuse hidden names"
  ! fm_config_inherit_path_allowed config/other/acme.md || fail "receiver must refuse undeclared sets"
  pass "brief-addenda is a declared set with strict member rules"
}

test_propagate_copy_update_and_membership() {
  local base primary second report err
  base=$(new_pair membership)
  primary="$base/primary/config"
  second="$base/second/config"
  report="$base/report"
  err="$base/err"
  mkdir -p "$primary/brief-addenda" "$second/brief-addenda"
  printf 'acme v1\n' > "$primary/brief-addenda/acme.md"
  printf 'beta v1\n' > "$primary/brief-addenda/beta.md"
  printf 'ignored\n' > "$primary/brief-addenda/notes.txt"
  printf 'ignored\n' > "$primary/brief-addenda/.hidden.md"
  printf 'hand copied\n' > "$second/brief-addenda/stale.md"
  printf 'keep\n' > "$second/brief-addenda/notes.txt"

  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary" "$second" 2>"$err" \
    || fail "first propagation failed: $(cat "$err")"
  [ ! -s "$err" ] || fail "clean propagation wrote stderr: $(cat "$err")"
  [ "$(cat "$second/brief-addenda/acme.md")" = 'acme v1' ] || fail "acme.md not inherited"
  [ "$(cat "$second/brief-addenda/beta.md")" = 'beta v1' ] || fail "beta.md not inherited"
  [ ! -e "$second/brief-addenda/stale.md" ] || fail "destination-only member should be mirrored as absence"
  [ ! -e "$second/brief-addenda/.hidden.md" ] || fail "hidden primary name must not be inherited"
  [ ! -e "$second/brief-addenda/ignored" ] || fail "unexpected file"
  [ "$(cat "$second/brief-addenda/notes.txt")" = keep ] || fail "non-member destination file must be left alone"
  [ "$(report_status "$report" brief-addenda/acme.md)" = pushed ] || fail "acme.md should report pushed"
  [ "$(report_status "$report" brief-addenda/stale.md)" = pushed ] || fail "stale.md removal should report pushed"

  : > "$report"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary" "$second" 2>"$err" || fail "idempotent run failed"
  [ "$(report_status "$report" brief-addenda/acme.md)" = unchanged ] || fail "second run should leave acme.md unchanged"
  [ -z "$(fm_config_reread_changed_items "$report")" ] || fail "no reread is owed when nothing changed"

  : > "$report"
  printf 'acme v2\n' > "$primary/brief-addenda/acme.md"
  rm -f "$primary/brief-addenda/beta.md"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary" "$second" 2>"$err" || fail "update run failed"
  [ "$(cat "$second/brief-addenda/acme.md")" = 'acme v2' ] || fail "edited addendum did not converge"
  [ ! -e "$second/brief-addenda/beta.md" ] || fail "primary deletion did not converge"
  [ "$(fm_config_reread_changed_items "$report")" = "$(printf 'brief-addenda/acme.md\nbrief-addenda/beta.md')" ] \
    || fail "reread should list changed and removed members, got: $(fm_config_reread_changed_items "$report")"
  pass "propagation copies, updates, and mirrors membership; hidden and non-md names stay out"
}

test_absent_primary_set_mirrors_absence() {
  local base primary second
  base=$(new_pair absent-set)
  primary="$base/primary/config"
  second="$base/second/config"
  mkdir -p "$second/brief-addenda"
  printf 'x\n' > "$second/brief-addenda/acme.md"
  propagate_inheritable_config "$primary" "$second" 2>/dev/null || fail "absent primary set should propagate cleanly"
  [ ! -e "$second/brief-addenda/acme.md" ] || fail "absent primary set should clear destination members"
  pass "an absent primary set directory converges to no destination members"
}

test_unprovable_primary_set_preserves_destination() {
  local base primary second report err
  base=$(new_pair unprovable)
  primary="$base/primary/config"
  second="$base/second/config"
  report="$base/report"
  err="$base/err"
  printf 'not a directory\n' > "$primary/brief-addenda"
  mkdir -p "$second/brief-addenda"
  printf 'keep\n' > "$second/brief-addenda/acme.md"
  if FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary" "$second" 2>"$err"; then
    fail "an unusable primary set should report a propagation error"
  fi
  [ "$(cat "$second/brief-addenda/acme.md")" = keep ] || fail "destination must be preserved when the primary set is unusable"
  [ "$(report_status "$report" brief-addenda)" = error ] || fail "set error should be reported"
  pass "an unusable primary set preserves the destination and reports an error"
}

test_symlinked_member_errors_without_removal() {
  local base primary second report err
  base=$(new_pair dangling)
  primary="$base/primary/config"
  second="$base/second/config"
  report="$base/report"
  err="$base/err"
  mkdir -p "$primary/brief-addenda" "$second/brief-addenda"
  ln -s "$base/missing-target" "$primary/brief-addenda/acme.md"
  printf 'keep\n' > "$second/brief-addenda/acme.md"
  if FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary" "$second" 2>"$err"; then
    fail "a dangling primary member should report an error"
  fi
  [ "$(cat "$second/brief-addenda/acme.md")" = keep ] || fail "a dangling primary member must not remove the destination copy"
  pass "a dangling primary member errors and preserves the destination copy"
}

test_reread_instruction_includes_member_bytes() {
  local base primary second report out
  base=$(new_pair reread)
  primary="$base/primary/config"
  second="$base/second/config"
  report="$base/report"
  mkdir -p "$primary/brief-addenda" "$base/second/state"
  printf 'acme standing rule\n' > "$primary/brief-addenda/acme.md"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_inheritable_config "$primary" "$second" 2>/dev/null || fail "propagate failed"
  fm_config_write_reread_instruction "$base/second" "$report" "$base/second/state/instr" || fail "no instruction written"
  out=$(cat "$base/second/state/instr")
  assert_contains "$out" "-----BEGIN config/brief-addenda/acme.md-----" "instruction should delimit the member"
  assert_contains "$out" "acme standing rule" "instruction should carry the exact member bytes"
  pass "reread instruction carries inherited addendum bytes"
}

remote_run() {  # <home> <args...>
  local home=$1
  shift
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" "$@" 2>&1
}

test_remote_receiver_set_commands() {
  local home out payload empty_hash bytes hash
  home="$TMP_ROOT/receiver/home"
  payload="$TMP_ROOT/receiver/payload"
  mkdir -p "$home/config" "$home/data" "$TMP_ROOT/receiver"
  printf 'remote addendum\n' > "$payload"
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload")
  : > "$TMP_ROOT/receiver/empty"
  empty_hash=$(fm_inherit_sha256 "$TMP_ROOT/receiver/empty")

  out=$(remote_run "$home" put config/brief-addenda/acme.md "$bytes" "$hash" 1 < "$payload") || fail "put failed: $out"
  assert_contains "$out" "pushed: config/brief-addenda/acme.md" "put should publish the member"
  cmp -s "$payload" "$home/config/brief-addenda/acme.md" || fail "member bytes differ"
  out=$(remote_run "$home" members config/brief-addenda 0 "$empty_hash" 1 < /dev/null) || fail "members failed: $out"
  [ "$out" = brief-addenda/acme.md ] || fail "members should list only the valid member, got: $out"
  out=$(remote_run "$home" absent config/brief-addenda/acme.md 0 "$empty_hash" 2 < /dev/null) || fail "absent failed: $out"
  assert_contains "$out" "removed: config/brief-addenda/acme.md" "absent should remove the member"
  [ ! -e "$home/config/brief-addenda/acme.md" ] || fail "member not removed"

  out=$(remote_run "$home" put config/brief-addenda/.hidden.md "$bytes" "$hash" 1 < "$payload") && fail "hidden member must be refused"
  assert_contains "$out" "not inherited material" "hidden refusal should name the allowlist"
  out=$(remote_run "$home" put config/other/acme.md "$bytes" "$hash" 1 < "$payload") && fail "undeclared set must be refused"
  out=$(remote_run "$home" members config/backend 0 "$empty_hash" 1 < /dev/null) && fail "members of a non-set must be refused"
  pass "remote receiver puts, lists and removes set members and refuses everything else"
}

test_remote_sender_mirrors_membership() {
  local base root remote_home primary_config out rc
  base="$TMP_ROOT/sender"
  root="$base/root"
  remote_home="$base/remote-home"
  primary_config="$base/home/config"
  mkdir -p "$root" "$remote_home/config/brief-addenda" "$remote_home/data" "$primary_config/brief-addenda" "$base/home/data"
  cp -R "$ROOT/bin" "$root/bin"
  # The shim stands in for SSH: it runs the real receiver against the remote home.
  cat > "$root/bin/fm-on.sh" <<'SHIM'
#!/usr/bin/env bash
set -eu
stdin_mode=closed
if [ "${1:-}" = --stdin ]; then stdin_mode=caller; shift; fi
shift
cmd=$1
shift
if [ "$stdin_mode" = caller ]; then
  FM_HOME="$FM_TEST_REMOTE_HOME" "$(dirname "${BASH_SOURCE[0]}")/$cmd" "$@"
else
  FM_HOME="$FM_TEST_REMOTE_HOME" "$(dirname "${BASH_SOURCE[0]}")/$cmd" "$@" < /dev/null
fi
SHIM
  chmod +x "$root/bin/fm-on.sh"
  printf -- '- rm1 - remote fixture (host: fakehost; root: /r; home: /h; scope: test; projects: none; added 2026-01-01)\n' > "$base/home/data/secondmates.md"
  printf 'acme v1\n' > "$primary_config/brief-addenda/acme.md"
  printf 'old\n' > "$remote_home/config/brief-addenda/stale.md"
  printf 'divergent\n' > "$remote_home/config/brief-addenda/acme.md"

  out=$(PATH="$BASE_PATH" FM_HOME="$base/home" FM_ROOT_OVERRIDE="$root" FM_TEST_REMOTE_HOME="$remote_home" \
    "$root/bin/fm-remote-inherit-push.sh" rm1 1 2>&1) || fail "remote sender failed: $out"
  [ "$(cat "$remote_home/config/brief-addenda/acme.md")" = 'acme v1' ] || fail "remote member did not converge"
  [ ! -e "$remote_home/config/brief-addenda/stale.md" ] || fail "remote-only member should be removed"
  assert_contains "$out" "removed: config/brief-addenda/stale.md" "sender should report the removal"

  rm -f "$primary_config/brief-addenda/acme.md"
  out=$(PATH="$BASE_PATH" FM_HOME="$base/home" FM_ROOT_OVERRIDE="$root" FM_TEST_REMOTE_HOME="$remote_home" \
    "$root/bin/fm-remote-inherit-push.sh" rm1 2 2>&1) || { rc=$?; fail "second sender run failed ($rc): $out"; }
  [ ! -e "$remote_home/config/brief-addenda/acme.md" ] || fail "primary deletion should reach the remote home"
  pass "remote sender converges set membership, including removals"
}

test_declared_set_and_member_rules
test_propagate_copy_update_and_membership
test_absent_primary_set_mirrors_absence
test_unprovable_primary_set_preserves_destination
test_symlinked_member_errors_without_removal
test_reread_instruction_includes_member_bytes
test_remote_receiver_set_commands
test_remote_sender_mirrors_membership

echo "# all fm-brief-addenda-inheritance tests passed"
