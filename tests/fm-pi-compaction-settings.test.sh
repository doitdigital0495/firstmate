#!/usr/bin/env bash
# Contract for the tracked project-local Pi auto-compaction settings.
# Owner of the behavior: docs/configuration.md "Pi auto-compaction".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTINGS="$ROOT/.pi/settings.json"

# Context window of the active Firstmate Pi model (openai-codex/gpt-5.6-sol).
# Pi compacts when contextTokens > contextWindow - reserveTokens, so this
# constant is what makes the reserve mean 175,000 rather than some other point.
MODEL_CONTEXT_WINDOW=272000
EXPECTED_THRESHOLD=175000

test_compaction_threshold() {
  local enabled reserve keep threshold

  enabled=$(jq -r '.compaction.enabled' "$SETTINGS") \
    || fail "$SETTINGS is not valid JSON"
  reserve=$(jq -r '.compaction.reserveTokens' "$SETTINGS")
  keep=$(jq -r '.compaction.keepRecentTokens' "$SETTINGS")

  [ "$enabled" = "true" ] || fail "compaction.enabled is '$enabled', expected true"
  [ "$keep" = "20000" ] || fail "compaction.keepRecentTokens is '$keep', expected Pi's default 20000"

  threshold=$((MODEL_CONTEXT_WINDOW - reserve))
  [ "$threshold" -eq "$EXPECTED_THRESHOLD" ] \
    || fail "effective trigger is $MODEL_CONTEXT_WINDOW - $reserve = $threshold, expected $EXPECTED_THRESHOLD"

  pass "compaction enabled, keeps 20000 recent tokens, triggers at $threshold for a $MODEL_CONTEXT_WINDOW context window"
}

test_no_extension_configuration() {
  local keys

  keys=$(jq -r 'keys[]' "$SETTINGS")
  [ "$keys" = "compaction" ] \
    || fail "$SETTINGS must carry only the compaction key, found: $(printf '%s' "$keys" | tr '\n' ' ')"

  pass "settings file carries compaction only; extensions stay directory-loaded"
}

test_compaction_threshold
test_no_extension_configuration
