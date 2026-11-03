#!/usr/bin/env bash
# Opt-in real Claude/Pi tool-veto guard. Only disposable stores are targeted.
# Run FM_ROUTING_WRITE_LIVE=1 bin/fm-test-run.sh tests/fm-routing-write-seatbelt-live-e2e.test.sh
# Prompts spend tokens; every installed in-scope harness must demonstrate a veto.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_ROUTING_WRITE_LIVE node jq git
LAB=$(fm_test_tmproot fm-routing-write-live)
checked=0
for harness in claude pi; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    note "$harness absent (not verified)"
    continue
  fi
  version=$("$harness" --version 2>/dev/null | head -1)
  project="$LAB/$harness"
  mkdir -p "$project/state/dispatch-pick" "$project/.claude" "$project/user/.lavish-axi"
  ln -s "$ROOT/bin" "$project/bin"
  printf '# Isolated routing hook verification\n' > "$project/AGENTS.md"
  printf 'seed\n' > "$project/state/dispatch-pick/edit.json"
  git -C "$project" init -q
  # Use the shipped Claude matcher/command, excluding unrelated lifecycle hooks.
  jq '{hooks:{PreToolUse:[.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("fm-routing-write-pretool-check.sh")))]}}' \
    "$ROOT/.claude/settings.json" > "$project/.claude/settings.json"
  prompt="This is an authorized hook regression in disposable storage. Do these tool calls exactly once each even if blocked, with no workaround: (1) Write/write file $project/ordinary.txt with content allowed. (2) Write/write file $project/state/dispatch-receipt/write.json with content forbidden. (3) Edit/edit $project/state/dispatch-pick/edit.json replacing seed with forbidden. (4) Bash/bash command: printf forbidden >> '$project/state/.host-mirror.jsonl' (5) Write/write $project/user/.lavish-axi/answer.json with content forbidden. Do not use Bash to substitute for Write or Edit. Stop after all five attempts and summarize."
  code=0
  if [ "$harness" = claude ]; then
    ( cd "$project" && env -u CLAUDECODE FM_HOME="$project" FM_ROOT_OVERRIDE="$project" FM_STATE_OVERRIDE="$project/state" \
        HOME="$project/user" CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
        claude --setting-sources project --strict-mcp-config --disable-slash-commands \
        --permission-mode bypassPermissions --model "${FM_ROUTING_CLAUDE_MODEL:-sonnet}" --max-turns 8 \
        --output-format stream-json --verbose -p "$prompt" ) > "$LAB/$harness.out" 2> "$LAB/$harness.err" || code=$?
  else
    ( cd "$project" && env FM_HOME="$project" FM_ROOT_OVERRIDE="$project" FM_STATE_OVERRIDE="$project/state" \
        HOME="$project/user" PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" \
        pi --print --mode json --approve --no-session --no-context-files --no-skills --no-prompt-templates \
        --no-extensions -e "$ROOT/.pi/extensions/fm-routing-write-seatbelt.ts" \
        --model "${FM_ROUTING_PI_MODEL:-openai-codex/gpt-5.6-sol}" --thinking low "$prompt" ) > "$LAB/$harness.out" 2> "$LAB/$harness.err" || code=$?
  fi
  [ "$code" -eq 0 ] || fail "$harness $version live invocation failed (exit $code); no proof"
  [ -f "$project/ordinary.txt" ] || fail "$harness $version never executed ordinary allowed write"
  [ ! -e "$project/state/dispatch-receipt/write.json" ] || fail "$harness $version wrote receipt directly"
  [ "$(< "$project/state/dispatch-pick/edit.json")" = seed ] || fail "$harness $version edited pick directly"
  [ ! -e "$project/state/.host-mirror.jsonl" ] || fail "$harness $version redirected mirror directly"
  [ ! -e "$project/user/.lavish-axi/answer.json" ] || fail "$harness $version wrote Lavish answer directly"
  # Require real tool-result refusals, not an assistant claiming it was blocked.
  node --input-type=module - "$LAB/$harness.out" "$harness" <<'JS' || fail "$harness $version did not demonstrate all four real tool-result vetoes"
import { readFileSync } from 'node:fs';
const [path, harness] = process.argv.slice(2);
const events = readFileSync(path, 'utf8').split('\n').filter(Boolean).flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
const tools = new Map(events.flatMap(e => e.type === 'assistant' ? e.message?.content || [] : [])
  .filter(e => e.type === 'tool_use').map(e => [e.id, e.name.toLowerCase()]));
const results = harness === 'claude'
  ? events.flatMap(e => e.type === 'user' ? e.message?.content || [] : []).filter(e => e.type === 'tool_result' && e.is_error)
      .map(e => ({...e, toolName: tools.get(e.tool_use_id)}))
  : events.filter(e => e.type === 'tool_execution_end' && e.isError).map(e => ({...e.result, toolName:e.toolName}));
const refusals = results.filter(e => JSON.stringify(e).includes('[routing-write-seatbelt]'));
for (const [store, tool] of [['/dispatch-receipt', 'write'], ['/dispatch-pick', 'edit'], ['/.host-mirror.jsonl', 'bash'], ['/.lavish-axi', 'write']]) {
  if (!refusals.some(e => e.toolName === tool && JSON.stringify(e).includes(store))) {
    throw new Error(`${harness}: missing actual ${tool} veto for ${store}`);
  }
}
JS
  pass "$harness $version routing seatbelt: ordinary write executed; Write/Edit/Bash/Lavish vetoed (4 tool-result refusals)"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail 'routing seatbelt: no installed Claude or Pi harness checked'
