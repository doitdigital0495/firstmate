#!/usr/bin/env bash
# tests/fm-remote-secondmate-dispatch-receipt.test.sh - the dispatch receipt
# gate (contract: bin/fm-dispatch-receipt-lib.sh) on the remote second-mate
# launch path.
#
# A remote second mate never reaches the local gate in bin/fm-spawn.sh:
# spawn_remote_secondmate hands the launch across the transport to the remote
# host's own fm-spawn, whose private state/parent-route has no receipt
# producer. The gate therefore runs in the PARENT home, against a receipt in
# the parent home, and the host-local launch is admitted on the strength of
# it. These assertions drive the real chain - parent fm-spawn -> fm-on -> the
# real remote entrypoint -> fm-remote-secondmate-control -> the remote host's
# fm-spawn - with routing rows in both homes' dispatch tables.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-dispatch-receipt)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" \
  "$REMOTE_ROOT" "$CLAIMS"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; chmod -R u+w "$TMP_ROOT" 2>/dev/null || true; rm -rf -- "$TMP_ROOT"' EXIT

# Routing rows in both homes: the parent's table is the one a remote second mate
# is routed from, and the remote host's own table having rows is what would make
# its host-local gate demand a receipt that host cannot produce.
TABLE='{"model_notes":{"claude":"personal max line","codex":"codex pool line"},"rules":[{"when":"second mate charters","use":[{"harness":"codex"}]}]}'

# The remote host's tracked code root is this branch, as a real git repository,
# exactly as tests/fm-spawn-compact-adviser-disable-remote.test.sh builds it.
fm_test_copy_repo "$REMOTE_ROOT"
cat > "$REMOTE_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
# The readiness gate is answered here rather than by the real doctor, which
# would inspect the RUNNER's own account.
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '%s\n' "$TABLE" > "$PARENT/config/crew-dispatch.json"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"
printf '%s\n' "$$" > "$PARENT/state/.lock"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route under test"

# The remote spawn runs the real quota intake gate against the route's own
# state, so each launch needs a fresh record there; the same step gives the
# remote home its routing rows.
seed_remote_home() {
  local fake="$TMP_ROOT/quota-fake"
  local account_home
  account_home=$(CDPATH='' env -u HOME bash -c 'cd -- ~ && pwd -P') \
    || fail "cannot resolve the fake remote account home"
  mkdir -p "$fake" "$REMOTE_HOME/config"
  printf '%s\n' "$TABLE" > "$REMOTE_HOME/config/crew-dispatch.json"
  cat > "$fake/quota-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in --version) echo "quota-axi 0.1.29"; exit 0 ;; esac
cat <<'EOF'
{"schemaVersion":5,"providers":[{"provider":"claude","label":"max","plan":"max","state":{"status":"fresh"},"windows":[{"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-09-29T15:19:59Z"},{"id":"seven_day","label":"7d","kind":"seven_day","percentUsed":7,"percentRemaining":93,"resetsAt":"2026-10-05T17:59:59Z"}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.4}}]}},{"provider":"codex","label":"prolite","plan":"prolite","state":{"status":"fresh"},"windows":[{"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":3,"percentRemaining":97,"resetsAt":"2026-09-29T19:00:00Z"},{"id":"weekly","label":"week","kind":"weekly","percentUsed":8,"resetsAt":"2026-10-04T05:00:39.000Z","windowSeconds":604800,"percentRemaining":92}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":92,"boundedBy":["five_hour","weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":1.1213}}]}}]}
EOF
SH
  chmod +x "$fake/quota-axi"
  env -i HOME="$account_home" PATH="$fake:$PATH" \
    FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_STATE_OVERRIDE="$REMOTE_HOME/state/parent-route" \
    FM_CONFIG_OVERRIDE="$REMOTE_HOME/config" \
    "$REMOTE_ROOT/bin/fm-quota-intake.sh" >/dev/null \
    || fail "seeding the remote route's quota intake record failed"
}

launch_remote() {
  seed_remote_home
  reset_remote_herdr_fixture "$HERDR_STATE"
  : > "$HERDR_LOG"
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1
}
count_files() {  # <dir> <name-pattern>
  find "$1" -name "$2" 2>/dev/null | wc -l | tr -d ' '
}
remote_pane_launches() { grep -c '^pane send-text ' "$HERDR_LOG" || true; }

PARENT_RECEIPTS="$PARENT/state/dispatch-receipt"
REMOTE_RECEIPTS="$REMOTE_HOME/state/parent-route/dispatch-receipt"
CHARTER="$PARENT/data/ios/brief.md"

# --- no receipt in the parent home: refused before the host is asked ---------
OUT=$(launch_remote); RC=$?
[ "$RC" -ne 0 ] || fail "a remote second mate launched with no dispatch receipt in the parent home"$'\n'"$OUT"
assert_contains "$OUT" 'dispatch receipt gate: refusing - no dispatch receipt binds the brief of ios' \
  "the refusal is the gate's own, naming the missing receipt"
assert_contains "$OUT" 'ios was not launched; the dispatch receipt gate refused it and nothing was created' \
  "the launch reports the gate refusal"
assert_absent "$PARENT/state/ios.meta" "a refused remote launch must record no task in the parent home"
assert_equals 0 "$(remote_pane_launches)" "a refused remote launch must never reach the remote pane"
pass "a remote second mate with no dispatch receipt in the parent home is refused before its host is asked to launch"

# --- a receipt in the parent home admits the launch and is consumed there ----
fm_test_dispatch_choose "$PARENT" ios "$CHARTER" rule_1 codex \
  || fail "could not record the routed choice in the parent home"
OUT=$(launch_remote); RC=$?
expect_code 0 "$RC" "a remote second mate routed from the parent's dispatch table should launch"$'\n'"$OUT"
assert_grep 'harness=codex' "$PARENT/state/ios.meta" "the parent should record the launched second mate"
[ "$(remote_pane_launches)" -ge 1 ] || fail "the admitted launch never reached the remote pane"
assert_equals 1 "$(count_files "$PARENT_RECEIPTS" '*.spent')" \
  "the launch must consume the parent home's receipt"
assert_equals 0 "$(count_files "$REMOTE_RECEIPTS" 'dispatch-*')" \
  "the remote host needs, and holds, no receipt of its own"
pass "a receipt in the parent home admits the remote second mate, is consumed there, and the host needs none"

# --- a respawn that keeps the recorded profile needs no new receipt ----------
OUT=$(launch_remote); RC=$?
expect_code 0 "$RC" "a respawn that keeps the recorded profile should need no new receipt"$'\n'"$OUT"
assert_equals 1 "$(count_files "$PARENT_RECEIPTS" '*.spent')" \
  "a respawn on the recorded profile must not consume anything"
pass "a remote second mate respawns on its recorded profile without a new receipt"

# --- a respawn onto another harness is a new routing decision ----------------
printf 'claude\n' > "$PARENT/config/secondmate-harness"
OUT=$(launch_remote); RC=$?
[ "$RC" -ne 0 ] || fail "a remote respawn onto a changed harness launched with no receipt"$'\n'"$OUT"
assert_contains "$OUT" 'dispatch receipt gate: refusing' \
  "a changed harness is refused by the gate"
assert_grep 'harness=codex' "$PARENT/state/ios.meta" "a refused respawn must leave the parent record as it was"
pass "a remote respawn onto a changed harness is refused until it has a receipt or a captain override"

echo "ALL TESTS PASSED"
