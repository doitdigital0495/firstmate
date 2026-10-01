// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [answer]
// Prints rendered stats, task rows (including disclosures and status tones),
// section visibility, queued answer context, empty/more labels and errors.
// The optional answer mode submits the first card with its first radio and note.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((v) => v !== c).join(" "); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, on) => { if (on) this.classList.add(c); else this.classList.remove(c); },
    };
  }
  get textContent() {
    return this._text + this.children.map((c) => c.textContent).join("");
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(event, handler) { this.listeners[event] = handler; }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const queued = [];
globalThis.window = { lavish: { queuePrompt: (prompt, context) => queued.push({ prompt, data: context.data }) } };
globalThis.FormData = class {
  constructor(form) { this.form = form; }
  get(name) {
    const walk = (n) => n.children.flatMap((c) => [c, ...walk(c)]);
    return walk(this.form).find((n) => n.name === name && (n.type !== "radio" || n.checked))?.value ?? null;
  }
};
globalThis.setTimeout = (callback) => callback();
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const summary = row.children.find((c) => c.tagName === "summary");
      const content = summary || row;
      const main = content.children.find((c) => c.className.includes("bb-row__main"));
      return {
        disclosure: row.tagName === "details" && summary?.tagName === "summary",
        cue: summary?.children.find((c) => c.className.includes("bb-work__cue"))?.textContent ?? "",
        detail: row.children.find((c) => c.className.includes("bb-work__detail"))?.textContent ?? "",
        tone: row.className.match(/bb-work--(\w+)/)?.[1] ?? "",
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(content),
        pickable: content.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const requests = (byId.get("bb-requests")?.children || []).map((row) => ({
  title: row.children[0]?.textContent,
  status: row.children[1]?.children[0]?.textContent,
  detail: row.children[1]?.children[1]?.textContent,
  href: row.children[1]?.children.find((c) => c.tagName === "a")?.href ?? "",
}));
const cards = (byId.get("bb-call")?.children || [])
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => ({
    hidden: card.hidden,
    title: card.querySelectorAll(".bb-decision__title")[0]?.textContent,
    contexts: card.querySelectorAll(".bb-ctx__row").map((n) => n.textContent),
    options: card.querySelectorAll(".bb-opt").map((n) => n.textContent),
  }));
const coverage = (byId.get("bb-coverage")?.children || []).map((n) => n.textContent);
const projects = (byId.get("bb-projects")?.children || []).map((card) => ({
  name: card.querySelectorAll(".bb-project__name")[0]?.textContent,
  delivery: card.querySelectorAll(".bb-project__delivery")[0]?.textContent,
  text: card.textContent,
  people: card.querySelectorAll(".bb-person").map((person) => ({
    name: person.querySelectorAll(".bb-person__name")[0]?.textContent,
    role: person.querySelectorAll(".bb-person__role")[0]?.textContent,
    questions: person.querySelectorAll(".bb-question").map((q) => q.textContent),
    text: person.textContent,
  })),
}));
const sections = Object.fromEntries(["current", "call", "charted", "landed"].map((name) =>
  [name, { hidden: byId.get("bb-" + name + "-section")?.hidden ?? false }]));
const idle = !(byId.get("bb-idle")?.hidden ?? true);
if (process.argv[3] === "answer") {
  const walk = (n) => n.children.flatMap((c) => [c, ...walk(c)]);
  const nodes = walk(byId.get("bb-call"));
  const form = nodes.find((n) => n.tagName === "form");
  const radio = nodes.find((n) => n.type === "radio");
  const note = nodes.find((n) => n.name === "note");
  radio.checked = true;
  if (note) note.value = "a note";
  form.listeners.submit({ preventDefault() {} });
}
process.stdout.write(
  JSON.stringify({ stats, underway, charted, sections, idle, queued, empty, more, requests, cards, projects, coverage, error: errorText }) + "\n");
