// Firstmate's always-visible Codex credential-store indicator for the Pi footer.
//
// Verified against Pi 0.84.4, which renders every extension status registered through
// ctx.ui.setStatus() on its own footer line, sorted by key and joined with a space,
// directly beneath the token/cost/context stats. That line is on screen for as long as
// the built-in footer is, which is also for as long as the captain's quota display is,
// so the indicator needs no widget of its own. A widget would be the wrong surface
// anyway: Pi orders widgets by extension load order, which is unsorted directory order,
// so a second belowEditor widget could land above or below the quota block from one run
// to the next and would compete with it for Pi's ten-line widget budget.
//
// This file never reads a credential. Two non-secret Pi APIs answer the whole question:
// getAgentDir() resolves the agent directory this process actually authenticates from
// (PI_CODING_AGENT_DIR, otherwise ~/.pi/agent), and modelRegistry.getProviderAuthStatus
// reports whether a credential for the provider is configured and which surface it came
// from. No access token, refresh token, stored credential, account id, or email address
// is read, derived, or displayed. A store is named only when Pi reports the credential
// as the stored one; every other case renders an explicit unverified state rather than
// implying an account.
//
// docs/pi-account-indicator.md owns the captain-facing behavior and its limits.
import { homedir } from "node:os";
import { relative, resolve, sep } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// Pi's provider id for the ChatGPT/Codex subscription family.
const PROVIDER = "openai-codex";
// Sorted with the other extension statuses on Pi's footer status line.
const STATUS_KEY = "firstmate-codex-account";

// A store label is a path fragment and nothing else. Pi's own footer sanitizer only
// collapses whitespace, so an escape sequence reaching this text would repaint the
// captain's screen, and a mangled label could read as a different store than the one
// in use. Anything that is not plainly path-shaped is therefore reported as unknown
// rather than cleaned up into something that looks like an answer.
const SAFE_LABEL = /^[A-Za-z0-9._\-/]{1,64}$/;
// The AuthStatus.source values Pi 0.84.4 reports. Only "stored" means the credential
// came from the agent directory this indicator names.
const KNOWN_SOURCES = new Set([
  "stored",
  "runtime",
  "environment",
  "fallback",
  "models_json_key",
  "models_json_command",
]);

/**
 * The credential store this Pi process authenticates from, as the captain reads it:
 * `.pi` and `.pi-geris` rather than two long paths that differ late. The trailing
 * `agent` segment is dropped because it is identical for every home and carries none
 * of the distinction. A directory outside the home keeps its absolute path.
 */
function codexStoreLabel(agentDir: string, home: string): string {
  const suffix = `${sep}agent`;
  // Normalized first so a trailing separator cannot leave the `agent` segment in
  // the label and make one store read as two.
  const normalized = resolve(agentDir);
  const store = normalized.endsWith(suffix) ? normalized.slice(0, -suffix.length) : normalized;
  const fromHome = relative(home, store);
  const label = fromHome && !fromHome.startsWith("..") ? fromHome : store;
  return SAFE_LABEL.test(label) ? label : "unknown";
}

/**
 * What the footer says, from the resolved store and Pi's own non-secret auth status.
 * `configured` alone is not enough to name a store: an environment or runtime
 * credential authenticates some other account entirely, and naming the store then
 * would be exactly the false claim this indicator exists to prevent.
 */
function codexAccountStatus(
  agentDir: string,
  home: string,
  auth: { configured: boolean; source?: string } | undefined,
): string {
  if (!auth?.configured) return "codex@unverified(no-login)";
  if (auth.source !== "stored") {
    const source = auth.source && KNOWN_SOURCES.has(auth.source) ? auth.source : "other";
    return `codex@unverified(${source})`;
  }
  return `codex@${codexStoreLabel(agentDir, home)}`;
}

export default function (pi: ExtensionAPI) {
  const publish = (ctx: ExtensionContext): void => {
    if (!ctx.hasUI) return;
    let auth: { configured: boolean; source?: string } | undefined;
    try {
      auth = ctx.modelRegistry.getProviderAuthStatus(PROVIDER);
    } catch {
      // An unavailable auth status is missing evidence, never a signed-in account.
      auth = undefined;
    }
    ctx.ui.setStatus(STATUS_KEY, codexAccountStatus(getAgentDir(), homedir(), auth));
  };

  // Pi exposes no login or logout event, so the status is refreshed on the events that
  // bracket every way the credential can change under a running session: a new or
  // reloaded session, a model or provider switch, and the start of each turn.
  pi.on("session_start", (_event, ctx) => publish(ctx));
  pi.on("model_select", (_event, ctx) => publish(ctx));
  pi.on("turn_start", (_event, ctx) => publish(ctx));
}
