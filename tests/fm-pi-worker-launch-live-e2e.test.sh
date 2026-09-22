#!/usr/bin/env bash
# Default-on, token-free guard for Pi's lean worker resource and profile flags.
#
# The portable spawn regression pins Firstmate's launch composition.
# This guard asks the installed Pi itself what provider, model, thinking level,
# tools, context files, skills, and final system prompt it resolved.
# An extension command reads Pi's resolved prompt inputs without starting an agent
# turn, so this spends no model tokens and needs no provider credential.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_WORKER_LAUNCH_LIVE pi node opr

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB=$(fm_test_tmproot fm-pi-worker-launch-live)
PROBE="$LAB/probe.ts"
FULL="$LAB/full.json"
LEAN="$LAB/lean.json"
ZAI="$LAB/zai.json"
PI_VERSION=$(pi --version)
PI_AGENT_DIR=${PI_CODING_AGENT_DIR:-${HOME:?}/.pi/agent}
HERDR_EXT="$PI_AGENT_DIR/extensions/herdr-agent-state.ts"
RTK_EXT="$PI_AGENT_DIR/extensions/rtk-compact.ts"

cat > "$PROBE" <<'TS'
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerProvider("fm-probe", {
    baseUrl: "http://127.0.0.1:9/v1",
    apiKey: "unused",
    api: "openai-completions",
    models: [{
      id: "probe",
      name: "Firstmate launch probe",
      reasoning: true,
      input: ["text"],
      contextWindow: 272000,
      maxTokens: 1024,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    }],
  });

  pi.registerCommand("fm-launch-probe", {
    description: "Record resolved launch inputs without a provider request",
    handler: async (_args, ctx) => {
      const options = ctx.getSystemPromptOptions();
      const prompt = ctx.getSystemPrompt();
      writeFileSync(process.env.FM_PI_PROBE_OUT!, JSON.stringify({
        provider: ctx.model?.provider,
        model: ctx.model?.id,
        thinking: ctx.thinkingLevel,
        tools: options.selectedTools,
        contexts: options.contextFiles?.length ?? 0,
        skills: options.skills?.length ?? 0,
        promptChars: prompt.length,
        hasContract: prompt.includes("Firstmate worker contract"),
      }));
    },
  });
}
TS

(
  cd "$ROOT" || exit 1
  FM_PI_PROBE_OUT="$FULL" pi --no-extensions -e "$PROBE" \
    --tools read,bash,edit,write --provider fm-probe --model probe --thinking medium \
    --no-session -p /fm-launch-probe >/dev/null
) || fail "Pi $PI_VERSION full-context probe failed"

(
  cd "$ROOT" || exit 1
  FM_PI_PROBE_OUT="$LEAN" PI_REASONING_LEVEL=xhigh pi \
    --no-context-files --no-skills --no-extensions \
    -e "$HERDR_EXT" -e "$RTK_EXT" -e "$PROBE" \
    --tools read,bash --provider openai-codex --model gpt-5.6-luna --thinking low \
    --append-system-prompt "$(< "$ROOT/.pi/fm-worker-contract.md")" \
    --no-session -p /fm-launch-probe >/dev/null
) || fail "Pi $PI_VERSION openai-codex lean probe failed"

(
  cd "$ROOT" || exit 1
  FM_PI_PROBE_OUT="$ZAI" PI_REASONING_LEVEL=xhigh opr -f "$ROOT/.env.op" -- pi \
    --no-context-files --no-skills --no-extensions \
    -e "$HERDR_EXT" -e "$RTK_EXT" -e "$PROBE" \
    --tools read,bash,edit,write --provider zai --model glm-5.3 --thinking high \
    --append-system-prompt "$(< "$ROOT/.pi/fm-worker-contract.md")" \
    --no-session -p /fm-launch-probe >/dev/null
) || fail "Pi $PI_VERSION zai lean probe failed"

node - "$FULL" "$LEAN" "$ZAI" <<'JS'
const fs = require("node:fs");
const [fullPath, leanPath, zaiPath] = process.argv.slice(2);
const full = JSON.parse(fs.readFileSync(fullPath, "utf8"));
const lean = JSON.parse(fs.readFileSync(leanPath, "utf8"));
const zai = JSON.parse(fs.readFileSync(zaiPath, "utf8"));
const fail = (message) => { console.error(`not ok - ${message}`); process.exit(1); };
if (lean.provider !== "openai-codex" || lean.model !== "gpt-5.6-luna" || lean.thinking !== "low")
  fail(`explicit Codex profile was not resolved: ${JSON.stringify(lean)}`);
if (zai.provider !== "zai" || zai.model !== "glm-5.3" || zai.thinking !== "high")
  fail(`explicit Z.ai profile was not resolved: ${JSON.stringify(zai)}`);
if (JSON.stringify(zai.tools) !== JSON.stringify(["read", "bash", "edit", "write"]))
  fail(`Z.ai ship tool allowlist drifted: ${JSON.stringify(zai.tools)}`);
if (JSON.stringify(lean.tools) !== JSON.stringify(["read", "bash"]))
  fail(`lean tool allowlist drifted: ${JSON.stringify(lean.tools)}`);
if (lean.contexts !== 0 || lean.skills !== 0)
  fail(`lean resources still include contexts=${lean.contexts} skills=${lean.skills}`);
if (!lean.hasContract)
  fail("lean system prompt omitted the worker contract");
if (full.contexts < 1 || full.skills < 1)
  fail(`control did not load repository resources: contexts=${full.contexts} skills=${full.skills}`);
const removed = 1 - lean.promptChars / full.promptChars;
if (removed < 0.95)
  fail(`lean prompt removed only ${(removed * 100).toFixed(1)}% (${full.promptChars} -> ${lean.promptChars} chars)`);
console.log(`ok - real Pi removed ${(removed * 100).toFixed(1)}% of startup prompt characters and honored explicit Codex/Z.ai profiles and tools`);
console.log(`# full_chars=${full.promptChars} lean_chars=${lean.promptChars} estimated_tokens=${Math.ceil(full.promptChars / 4)}->${Math.ceil(lean.promptChars / 4)} contexts=${full.contexts}->${lean.contexts} skills=${full.skills}->${lean.skills}`);
JS
