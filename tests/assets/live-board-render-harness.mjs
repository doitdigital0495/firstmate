// Run a built live board's shipped inline script under a minimal DOM shim and
// print what it rendered, so page behavior is asserted through the real built
// file rather than by reading the template source.
//
// Usage: node live-board-render-harness.mjs <board.html> [now-epoch] [answer-spec...]
// An answer spec is `<question-id>=<option-value>[:<note>]` (empty value for a
// note-only answer); each is applied to that card's form and submitted.
// Prints one JSON document:
//   { freshness, banner, stats:{}, notes:[], empty, idle, foot,
//     projects:[{label, badges, questions:[{id,title,urgent,badges,answerable,
//       readonly,options:[{value,label,recommended}],mode}], tasks:[{id,state}]}],
//     submits:[{id,status}], queued:[{prompt,options}], tickers }
import { readFileSync } from "node:fs";

const [file, nowArg, ...answers] = process.argv.slice(2);
const html = readFileSync(file, "utf8");

class Node {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.className = "";
    this.children = [];
    this.attributes = {};
    this.listeners = {};
    this._text = "";
    this.innerHTML = "";
    this.hidden = false;
    this.parentNode = null;
    this.type = ""; this.name = ""; this.value = ""; this.checked = false;
    this.placeholder = ""; this.href = ""; this.target = ""; this.rel = "";
  }
  get firstChild() { return this.children[0] || null; }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  removeChild(n) { this.children = this.children.filter((c) => c !== n); n.parentNode = null; return n; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatch(type) { for (const fn of this.listeners[type] || []) fn({ preventDefault() {} }); }
  hasClass(c) { return this.className.split(/\s+/).includes(c); }
  find(pred, out = []) {
    for (const c of this.children) { if (pred(c)) out.push(c); c.find(pred, out); }
    return out;
  }
}

const ids = ["lb-root", "lb-home", "lb-fresh", "lb-banner", "lb-stats", "lb-notes", "lb-projects", "lb-foot"];
const byId = new Map(ids.map((id) => [id, new Node("div")]));
const data = new Node("script");
data.textContent = html.split('<script id="live-board-data" type="application/json">')[1].split("</script>")[0];
byId.set("live-board-data", data);
const code = html.split("<script>").pop().split("</script>")[0];

const queued = [];
const tickers = [];
const nowMs = (nowArg ? Number(nowArg) : Date.now() / 1000) * 1000;
const document = { getElementById: (id) => byId.get(id) || null, createElement: (t) => new Node(t) };
const window = { lavish: { queuePrompt: (prompt, options) => queued.push({ prompt, options }) } };
const FakeDate = { now: () => nowMs, parse: (s) => Date.parse(s) };
new Function("window", "document", "setInterval", "Date", code)(
  window, document, (fn, ms) => tickers.push(ms), FakeDate);

const text = (n) => n.textContent.replace(/\s+/g, " ").trim();
const badges = (n) => n.find((c) => c.hasClass("badge")).map(text);
const root = byId.get("lb-projects");

const submits = [];
for (const spec of answers) {
  const [id, rest] = spec.split(/=(.*)/s);
  const [value, note] = rest.split(/:(.*)/s);
  const card = root.find((c) => c.getAttribute("data-question") === id)[0];
  const form = card && card.find((c) => c.tagName === "FORM")[0];
  if (!form) { submits.push({ id, status: "no-form" }); continue; }
  for (const r of form.find((c) => c.type === "radio")) r.checked = r.value === value;
  const noteInput = form.find((c) => c.name === "note")[0];
  noteInput.value = note || "";
  form.dispatch("submit");
  submits.push({ id, status: text(form.find((c) => c.hasClass("q-status"))[0]), queuedClass: card.hasClass("is-queued") });
}

const fresh = byId.get("lb-fresh").find((c) => c.getAttribute("data-freshness") !== null)[0];
const stats = {};
for (const s of byId.get("lb-stats").children) stats[s.getAttribute("data-stat")] = Number(s.children[0].textContent);
const projects = root.children.filter((c) => c.getAttribute("data-project") !== null).map((p) => ({
  label: p.getAttribute("data-project"),
  badges: badges(p.children[0]),
  questions: p.find((c) => c.getAttribute("data-question") !== null).map((q) => {
    const form = q.find((c) => c.tagName === "FORM")[0];
    const ro = q.find((c) => c.getAttribute("data-readonly") !== null)[0];
    return {
      id: q.getAttribute("data-question"),
      title: text(q.find((c) => c.tagName === "H3")[0]),
      urgent: q.hasClass("q-urgent"),
      badges: badges(q.children[0]),
      answerable: Boolean(form),
      lavishQuestion: form ? form.getAttribute("data-lavish-question") : null,
      readonly: ro ? { status: ro.getAttribute("data-readonly"), text: text(ro) } : null,
      options: form ? form.find((c) => c.hasClass("q-opt")).map((o) => ({
        value: o.find((c) => c.type === "radio")[0].value,
        label: text(o.children[1]),
        recommended: o.find((c) => c.hasClass("rec")).length > 0,
      })) : [],
      mode: form ? text(form.find((c) => c.hasClass("q-mode"))[0]) : null,
    };
  }),
  tasks: p.find((c) => c.getAttribute("data-task") !== null).map((t) => ({
    id: t.getAttribute("data-task"),
    state: text(t.children[0].children[0]),
    links: t.find((c) => c.tagName === "A").map((a) => a.href),
  })),
}));
const idle = root.find((c) => c.getAttribute("data-idle") !== null)[0];

console.log(JSON.stringify({
  freshness: fresh ? fresh.getAttribute("data-freshness") : null,
  freshText: text(byId.get("lb-fresh")),
  banner: text(byId.get("lb-banner")),
  home: text(byId.get("lb-home")),
  stats,
  notes: byId.get("lb-notes").find((c) => c.tagName === "LI").map(text),
  empty: root.find((c) => c.getAttribute("data-empty") !== null).map(text)[0] || null,
  idle: idle ? { count: Number(idle.getAttribute("data-idle")), names: idle.find((c) => c.tagName === "LI").map(text) } : null,
  foot: text(byId.get("lb-foot")),
  projects,
  submits,
  queued: queued.map((q) => ({ prompt: q.prompt, tag: q.options.tag, data: q.options.data })),
  tickers,
}));
