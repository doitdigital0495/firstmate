#!/usr/bin/env bash
# Drive bin/fm-spawn.sh to compose a real Pi task-worker launch, then execute that
# exact launch text with the real installed Pi, swapping only (a) the fake pi path
# for the real pi binary and (b) the brief positional for a token-free probe command.
# A hostile inherited PI_PROVIDER/PI_MODEL/PI_REASONING_LEVEL proves env -u works.
set -u
cd "$FM_WT"
. tests/fixtures.sh
source <(sed -n '17,121p' tests/fm-spawn-dispatch-profile.test.sh)
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-launch-replay)
name=$1; shift
id="$name-z1"
rec=$(make_spawn_case "$name" pi "$id")
read_case_record "$rec"
FM_TEST_PI_CODING_AGENT_DIR="$HOME/.pi/agent" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$@" >/dev/null 2>&1 \
  || { echo "spawn refused"; exit 1; }
echo "meta: $(grep -E '^(harness|model|effort|kind)=' "$HOME_DIR/state/$id.meta" | tr '\n' ' ')"
launch=$(cat "$LAUNCH_LOG")
echo "composed launch (secret check: ZAI_API_KEY value present in text? $(case "$launch" in *"${ZAI_SENTINEL:-__none__}"*) echo YES;; *) echo no;; esac))"
printf '%s\n' "$launch"
cat > "$TMP_ROOT/probe.ts" <<'TS'
import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.registerCommand("fm-launch-probe", {
    description: "probe",
    handler: async (_a, ctx) => {
      const o = ctx.getSystemPromptOptions(); const p = ctx.getSystemPrompt();
      writeFileSync(process.env.FM_PI_PROBE_OUT!, JSON.stringify({
        provider: ctx.model?.provider, model: ctx.model?.id, thinking: ctx.thinkingLevel,
        tools: o.selectedTools, contexts: o.contextFiles?.length ?? 0, skills: o.skills?.length ?? 0,
        promptChars: p.length, hasContract: p.includes("Firstmate worker contract"),
        zaiKeyPresent: !!process.env.ZAI_API_KEY }));
    },
  });
}
TS
realpi=$(PATH=${PATH#"$FAKEBIN_DIR:"} command -v pi)
launch=${launch//"'$FAKEBIN_DIR/pi'"/"'$realpi'"}
launch=${launch% \"\$(*}
launch="$launch -e '$TMP_ROOT/probe.ts' --no-session -p /fm-launch-probe </dev/null >/dev/null 2>$TMP_ROOT/err"
out="$TMP_ROOT/probe.json"
( cd "$WT_DIR" && PATH="$(printf %s "$PATH" | tr ':' '\n' | grep -v fakebin | paste -sd:)" \
  PI_PROVIDER=anthropic PI_MODEL=bogus PI_REASONING_LEVEL=xhigh FM_PI_PROBE_OUT="$out" bash -c "$launch" )
echo "real pi exit=$?"
cat "$TMP_ROOT/err" 2>/dev/null | head -5
echo "probe: $(cat "$out" 2>/dev/null || echo MISSING)"
