// Same primary scope, policy and refusal as Claude's PreToolUse transport.
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export default function (pi: ExtensionAPI): void {
  pi.on("tool_call", (event, ctx) => {
    if (!["write", "edit", "bash"].includes(event.toolName)) return;
    const result = spawnSync("bash", [resolve(root, "bin/fm-routing-write-pretool-check.sh")], {
      input: JSON.stringify({ tool_name: event.toolName, tool_input: event.input, cwd: ctx.cwd }),
      encoding: "utf8", timeout: 5000,
    });
    if (result.status === 0) return;
    let reason = result.stderr.trim();
    try { reason = JSON.parse(reason).systemMessage || reason; } catch { /* Runtime failure also blocks. */ }
    return { block: true, reason: reason || "[routing-write-seatbelt] Guard unavailable; refusing unchecked write." };
  });
}
