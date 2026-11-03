#!/usr/bin/env node
// Routing write seatbelt policy, shared by Claude and Pi transports.
// Usage: fm-routing-write-policy.mjs <primary-root> <state-dir> <user-home>
// Reads one PreToolUse JSON payload on stdin. Allow: silent exit 0.
// Deny: exit 2 with Claude-shaped JSON on stderr. Never runs submitted code.
// Only agent Write/Edit targets and Bash output redirects are classified.
// Script arguments are not writes: sanctioned writers keep owning their stores.
// This is an agent-mistake seatbelt, not a sandbox against arbitrary programs,
// dynamic shell computation, or an agent modifying/disabling its own hooks.
import { readFileSync, readlinkSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

const [home, state, userHome] = process.argv.slice(2);
function physical(path, depth = 0) {
  if (depth > 64) throw new Error("symlink cycle");
  try { return realpathSync(path); }
  catch {
    const parent = dirname(path);
    try { return physical(resolve(parent, readlinkSync(path)), depth + 1); }
    catch (error) { if (error.message === "symlink cycle") throw error; }
    return parent === path ? path : join(physical(parent, depth + 1), basename(path));
  }
}
const stores = [
  [join(state, "dispatch-receipt"), "bin/fm-dispatch-resolve.sh or bin/fm-spawn.sh"],
  [join(state, "dispatch-pick"), "bin/fm-control.sh pick"],
  [join(state, ".host-mirror.jsonl"), "bin/fm-host-mirror.sh hook"],
  [join(userHome, ".lavish-axi"), "lavish-axi (or bin/fm-lavish-open.sh for pages)"],
].map(([path, command]) => ({ path: physical(resolve(path)), command }));
const vars = { HOME: userHome, FM_HOME: home, FM_ROOT_OVERRIDE: home, FM_STATE_OVERRIDE: state };
function pathValue(value, cwd, { expandVars = true, expandTilde = true, toolPath = false } = {}) {
  if (toolPath) value = value.replace(/^@/, "");
  if (expandTilde) value = value.replace(/^~(?=\/|$)/, userHome);
  if (expandVars) value = value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g,
    (original, braced, bare) => vars[braced || bare] ?? original);
  return physical(isAbsolute(value) ? resolve(value) : resolve(cwd, value));
}
function protectedStore(value, cwd, options) {
  const target = pathValue(value, cwd, options);
  return stores.find(({ path }) => target === path || target.startsWith(`${path}/`));
}
function redirects(command, cwd, depth = 0) {
  if (depth > 16) return undefined;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return undefined;
  for (const tokens of splitProgram(lexed.tokens).nodes) {
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (token.type === "group") {
        const hit = redirects(token.content, cwd, depth + 1);
        if (hit) return hit;
      }
      for (const sub of token.subs || []) {
        const hit = redirects(sub.content, cwd, depth + 1);
        if (hit) return hit;
      }
      if (token.type === "redir" && !token.inlineTarget && [">", ">>", ">|", ">&", "<>"].includes(token.value)) {
        const target = tokens[i + 1];
        if (target?.type === "word") {
          const hit = protectedStore(target.value, cwd, { expandVars: !target.literal, expandTilde: !target.quoted });
          if (hit) return hit;
        }
      }
    }
    const position = commandPosition(tokens);
    const args = position.words.slice(position.index + 1);
    const name = position.command?.value.split("/").at(-1);
    if (["bash", "sh", "zsh", "dash"].includes(name)) {
      const index = args.findIndex((arg) => /^-[^-]*c/.test(arg.value));
      if (index >= 0 && args[index + 1]) {
        const hit = redirects(args[index + 1].value, cwd, depth + 1);
        if (hit) return hit;
      }
    }
    if (name === "cd") {
      const target = args.filter((arg) => !arg.value.startsWith("-"));
      if (target.length === 1) cwd = pathValue(target[0].value, cwd, { expandVars: !target[0].literal, expandTilde: !target[0].quoted });
    }
  }
  return undefined;
}
try {
  const payload = JSON.parse(readFileSync(0, "utf8"));
  const tool = (payload.tool_name || "").toLowerCase();
  const input = payload.tool_input || {};
  const cwd = payload.cwd || home;
  let hit;
  if (["write", "edit", "multiedit"].includes(tool)) {
    const path = input.file_path ?? input.path;
    if (typeof path === "string") hit = protectedStore(path, cwd, { expandVars: false, toolPath: true });
  } else if (tool === "bash" && typeof input.command === "string") {
    hit = redirects(input.command, cwd);
  }
  if (hit) {
    const reason = `[routing-write-seatbelt] Direct agent writes to ${hit.path} are blocked. Use ${hit.command} instead; its internal writes remain allowed.`;
    process.stderr.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason }, systemMessage: reason })}\n`);
    process.exitCode = 2;
  }
} catch {
  process.stderr.write("[routing-write-seatbelt] Invalid hook payload; refusing an unchecked tool call.\n");
  process.exitCode = 2;
}
