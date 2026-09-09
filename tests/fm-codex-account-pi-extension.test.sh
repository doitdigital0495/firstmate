#!/usr/bin/env bash
# Focused checks for the Pi footer's Codex credential-store indicator.
#
# The fixture loads the real .pi/extensions/fm-codex-account.ts against the installed
# Pi package, so PI_CODING_AGENT_DIR is resolved by Pi's own getAgentDir() rather than
# by a reimplementation of it here. Only the auth status and the UI are faked, and the
# fake refuses every credential-bearing Pi API so a future change that reaches for a
# token fails this suite instead of shipping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-account-pi-extension)
EXT="$ROOT/.pi/extensions/fm-codex-account.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

# Never a real credential: both values below are invented for this suite and must not
# reach the rendered status text.
SYNTHETIC_STATUS_LABEL='synthetic-label-sk-TESTONLY-0000'
SYNTHETIC_STORE_TOKEN='synthetic-store-sk-TESTONLY-1111'

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "skip: node or npm not found for the Pi Codex account indicator test"
  exit 0
fi
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi

PI_VERSION=$(node -p "require('$PI_PACKAGE_DIR/package.json').version" 2>/dev/null || printf '')
[ -n "$PI_VERSION" ] || fail "could not determine the installed Pi version"

FIXTURE="$TMP_ROOT/fixture"
FAKE_HOME="$TMP_ROOT/home"
mkdir -p \
  "$FIXTURE/.pi/extensions" \
  "$FIXTURE/node_modules/@earendil-works" \
  "$FAKE_HOME/.pi/agent" \
  "$FAKE_HOME/.pi-geris/agent" \
  "$TMP_ROOT/elsewhere/agent"
cp "$EXT" "$FIXTURE/.pi/extensions/fm-codex-account.ts"
ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$FIXTURE/node_modules/typebox"
printf '%s\n' '{"type":"module"}' >"$FIXTURE/package.json"

# A credential file the indicator must never open. It is unreadable so that any read
# attempt raises instead of passing silently; root bypasses file modes, so the mode is
# only asserted to matter when the suite is not running as root.
printf '{"openai-codex":{"type":"oauth","access":"%s"}}\n' "$SYNTHETIC_STORE_TOKEN" \
  >"$FAKE_HOME/.pi/agent/auth.json"
if [ "$(id -u)" != "0" ]; then
  chmod 000 "$FAKE_HOME/.pi/agent/auth.json"
fi

cat >"$TMP_ROOT/drive.mjs" <<'JS'
import { pathToFileURL } from "node:url";

// One entry per publish: the auth status the fake registry answers with, in order.
// "throw" makes getProviderAuthStatus raise, "undefined" makes it answer nothing.
const script = JSON.parse(process.env.CASE_AUTH);
const events = process.env.CASE_EVENTS.split(",");
const hasUI = process.env.CASE_HAS_UI !== "0";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  events: { emit() {}, on() {} },
  registerCommand() {},
  registerTool() {},
};

const statuses = [];
let call = 0;
const forbidden = [];
const modelRegistry = {
  getProviderAuthStatus(provider) {
    if (provider !== "openai-codex") throw new Error(`unexpected provider ${provider}`);
    const entry = script[Math.min(call, script.length - 1)];
    call += 1;
    if (entry === "throw") throw new Error("auth status unavailable");
    return entry === "undefined" ? undefined : entry;
  },
  // Every Pi API that can hand back credential material. Reaching one is a failure,
  // not a fallback, so it is recorded and raised rather than answered.
  getProviderAuth() {
    forbidden.push("getProviderAuth");
    throw new Error("credential API must not be called");
  },
  getApiKeyForProvider() {
    forbidden.push("getApiKeyForProvider");
    throw new Error("credential API must not be called");
  },
};

const ctx = {
  hasUI,
  modelRegistry,
  ui: {
    setStatus(key, text) {
      statuses.push({ key, text });
    },
  },
};

const extension = await import(
  `${pathToFileURL(process.env.CASE_EXT).href}?case=${Date.now()}-${Math.random()}`
);
extension.default(pi);

for (const event of events) {
  const handler = handlers.get(event);
  if (!handler) throw new Error(`extension registered no handler for ${event}`);
  await handler({}, ctx);
}

process.stdout.write(
  JSON.stringify({ statuses, forbidden, registered: [...handlers.keys()].sort() }) + "\n",
);
JS

# drive <agent-dir> <auth-script-json> [events] [hasUI]
drive() {
  local agent_dir=$1 auth=$2 events=${3:-session_start} has_ui=${4:-1}
  HOME="$FAKE_HOME" \
  PI_CODING_AGENT_DIR="$agent_dir" \
  CASE_EXT="$FIXTURE/.pi/extensions/fm-codex-account.ts" \
  CASE_AUTH="$auth" \
  CASE_EVENTS="$events" \
  CASE_HAS_UI="$has_ui" \
    node "$TMP_ROOT/drive.mjs" 2>"$TMP_ROOT/drive.err"
}

status_text() {
  node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write((d.statuses[Number(process.argv[1])]||{}).text??"")' "$2" <<<"$1"
}

json_field() {
  node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(JSON.stringify(d[process.argv[1]]))' "$2" <<<"$1"
}

STORED='[{"configured":true,"source":"stored"}]'

test_store_identity() {
  local personal geris out

  out=$(drive "$FAKE_HOME/.pi/agent" "$STORED") || fail "personal store case did not run: $(cat "$TMP_ROOT/drive.err")"
  personal=$(status_text "$out" 0)
  [ "$personal" = "codex@.pi" ] || fail "personal Pi store rendered '$personal', expected codex@.pi"

  out=$(drive "$FAKE_HOME/.pi-geris/agent" "$STORED") || fail "geris store case did not run: $(cat "$TMP_ROOT/drive.err")"
  geris=$(status_text "$out" 0)
  [ "$geris" = "codex@.pi-geris" ] || fail "geris Pi store rendered '$geris', expected codex@.pi-geris"

  # Asserted explicitly so the two cases above can never quietly collapse onto one
  # label, which is the exact failure this indicator exists to prevent.
  [ "$personal" != "$geris" ] || fail "personal and geris Pi stores rendered the same label '$personal'"

  # A trailing separator names the same store, not a second one.
  out=$(drive "$FAKE_HOME/.pi-geris/agent/" "$STORED") || fail "trailing-separator case did not run"
  [ "$(status_text "$out" 0)" = "$geris" ] \
    || fail "a trailing separator rendered '$(status_text "$out" 0)' rather than '$geris'"

  pass "the personal and geris Pi credential stores render as distinct labels"
}

test_unverified_states() {
  local out text

  out=$(drive "$FAKE_HOME/.pi/agent" '[{"configured":false}]') || fail "no-login case did not run"
  text=$(status_text "$out" 0)
  [ "$text" = "codex@unverified(no-login)" ] || fail "a store with no login rendered '$text'"

  out=$(drive "$FAKE_HOME/.pi/agent" '[{"configured":true,"source":"environment"}]') || fail "environment case did not run"
  text=$(status_text "$out" 0)
  [ "$text" = "codex@unverified(environment)" ] || fail "an environment credential rendered '$text'"

  out=$(drive "$FAKE_HOME/.pi/agent" '[{"configured":true,"source":"brand-new-source"}]') || fail "unknown-source case did not run"
  text=$(status_text "$out" 0)
  [ "$text" = "codex@unverified(other)" ] || fail "an unrecognized credential source rendered '$text'"

  out=$(drive "$FAKE_HOME/.pi/agent" '["throw"]') || fail "auth-error case did not run"
  text=$(status_text "$out" 0)
  [ "$text" = "codex@unverified(no-login)" ] || fail "an unavailable auth status rendered '$text'"

  out=$(drive "$FAKE_HOME/.pi/agent" '["undefined"]') || fail "absent-status case did not run"
  text=$(status_text "$out" 0)
  [ "$text" = "codex@unverified(no-login)" ] || fail "an absent auth status rendered '$text'"

  pass "a missing, foreign-sourced, unrecognized, or unavailable credential renders an explicit unverified state"
}

test_unnameable_store() {
  local out text
  # A store whose path cannot be stated safely is reported as unknown rather than
  # cleaned into something that reads like a real store.
  out=$(drive "$FAKE_HOME/$(printf 'weird\033[31m dir')/agent" "$STORED") || fail "hostile-path case did not run"
  text=$(status_text "$out" 0)
  [ "$text" = "codex@unknown" ] || fail "a path-unsafe store rendered '$text', expected codex@unknown"

  out=$(drive "$TMP_ROOT/elsewhere/agent" "$STORED") || fail "outside-home case did not run"
  text=$(status_text "$out" 0)
  case "$text" in
    codex@/*|codex@unknown) : ;;
    *) fail "a store outside the home rendered '$text', which reads as a home-relative store" ;;
  esac
  [ "$text" != "codex@.pi" ] || fail "a store outside the home was mistaken for the personal store"

  pass "a store that cannot be named safely never borrows another store's label"
}

test_refresh_and_no_ui() {
  local out first second registered

  out=$(drive "$FAKE_HOME/.pi/agent" '[{"configured":false},{"configured":true,"source":"stored"}]' "session_start,turn_start") \
    || fail "refresh case did not run"
  first=$(status_text "$out" 0)
  second=$(status_text "$out" 1)
  [ "$first" = "codex@unverified(no-login)" ] || fail "the first publish rendered '$first'"
  [ "$second" = "codex@.pi" ] || fail "a login that appeared mid-session rendered '$second'"

  registered=$(json_field "$out" registered)
  [ "$registered" = '["model_select","session_start","turn_start"]' ] \
    || fail "the indicator registered $registered rather than every refresh event"

  out=$(drive "$FAKE_HOME/.pi/agent" "$STORED" session_start 0) || fail "headless case did not run"
  [ "$(json_field "$out" statuses)" = "[]" ] || fail "a session with no UI still published a footer status"

  pass "the indicator refreshes on every credential-changing event and stays silent without a UI"
}

test_never_exposes_a_secret() {
  local out text forbidden
  out=$(drive "$FAKE_HOME/.pi/agent" \
    "[{\"configured\":true,\"source\":\"stored\",\"label\":\"$SYNTHETIC_STATUS_LABEL\",\"accountId\":\"$SYNTHETIC_STATUS_LABEL\"}]") \
    || fail "secret-safety case did not run: $(cat "$TMP_ROOT/drive.err")"
  text=$(status_text "$out" 0)

  [ "$text" = "codex@.pi" ] || fail "the secret-safety case rendered '$text'"
  case "$text" in
    *"$SYNTHETIC_STATUS_LABEL"*) fail "the rendered status carried a value from the auth status payload" ;;
    *"$SYNTHETIC_STORE_TOKEN"*) fail "the rendered status carried a value from the credential store" ;;
    *@*@*) fail "the rendered status carried more than the one label separator" ;;
  esac

  forbidden=$(json_field "$out" forbidden)
  [ "$forbidden" = "[]" ] || fail "the indicator called credential-bearing Pi APIs: $forbidden"

  # The credential file in the resolved store is unreadable, so a correct run proves
  # the indicator never opened it.
  [ -z "$(cat "$TMP_ROOT/drive.err")" ] || fail "the indicator wrote diagnostics: $(cat "$TMP_ROOT/drive.err")"

  pass "no credential, account id, or auth-status payload value reaches the footer"
}

test_store_identity
test_unverified_states
test_unnameable_store
test_refresh_and_no_ui
test_never_exposes_a_secret

printf 'ok - Codex account indicator verified against Pi %s\n' "$PI_VERSION"
