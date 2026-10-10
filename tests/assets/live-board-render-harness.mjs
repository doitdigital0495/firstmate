// Run a built live board's shipped inline script under a minimal DOM shim and
// print what it rendered, so page behavior is asserted through the real built
// file rather than by reading the template source.
//
// Usage: node live-board-render-harness.mjs <board.html> [now-epoch] [answer-spec...]
// An answer spec is `<question-id>=<option-value>[:<note>]` (empty value for a
// note-only answer); each is applied to that card's form and submitted.
// Three more specs drive the rest of the answer flow, in argument order:
//   `!send`               press the page's send control at the top
//   `!change=<id>`        press that answered card's Change answer or Answer again control
//   `!restore=<id>=<kept>` put <kept> back in that card's hidden answer field and
//                         deliver a parent message, as Lavish does after a reload
// Prints one JSON document:
//   { freshness, banner, stats:{}, notes:[], empty, idle:{count,names,lines}, foot,
//     projects:[{label, key, badges, description, status, progress, latest, text,
//       questions:[{id,mode,title,topic,why,urgent,badges,answerable,lavishQuestion,
//         readonly,options:[{value,label,detail,recommended}],noteField,modeText,
//         submit,answer,answered,kept,change,status}],
//       lanes:{doing|next|charted:{count,say,none,more,
//         cards:[{id,why,reason,title,note,links,folded}]}}}],
//     submits:[{id,status}], queued:[{prompt,tag,data}], sends, tray:{count,text,send}, tickers }
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

const ids = ["lb-root", "lb-home", "lb-fresh", "lb-banner", "lb-stats", "lb-notes", "lb-projects", "lb-tray", "lb-foot"];
const byId = new Map(ids.map((id) => [id, new Node("div")]));
const data = new Node("script");
data.textContent = html.split('<script id="live-board-data" type="application/json">')[1].split("</script>")[0];
byId.set("live-board-data", data);
const code = html.split("<script>").pop().split("</script>")[0];

const queued = [];
const tickers = [];
const nowMs = (nowArg ? Number(nowArg) : Date.now() / 1000) * 1000;
const document = { getElementById: (id) => byId.get(id) || null, createElement: (t) => new Node(t) };
let sends = 0;
const messageListeners = [];
const window = {
  lavish: { queuePrompt: (prompt, options) => queued.push({ prompt, options }), sendQueuedPrompts: () => { sends += 1; } },
  addEventListener: (type, fn) => { if (type === "message") messageListeners.push(fn); },
};
const FakeDate = { now: () => nowMs, parse: (s) => Date.parse(s) };
new Function("window", "document", "setInterval", "setTimeout", "Date", code)(
  window, document, (fn, ms) => tickers.push(ms), (fn) => fn(), FakeDate);

const text = (n) => n.textContent.replace(/\s+/g, " ").trim();
const badges = (n) => n.find((c) => c.hasClass("badge")).map(text);
// The words of one named card part, or of the given tag inside it.
const say = (q, part, tag) => {
  const box = q.find((c) => c.getAttribute("data-part") === part)[0];
  const node = box && tag ? box.find((c) => c.tagName === tag)[0] : box;
  return node ? text(node) : null;
};
const root = byId.get("lb-projects");

const submits = [];
const cardOf = (id) => root.find((c) => c.getAttribute("data-question") === id)[0];
for (const spec of answers) {
  if (spec === "!send") {
    const send = byId.get("lb-tray").find((c) => c.getAttribute("data-send") !== null)[0];
    if (send) send.dispatch("click");
    submits.push({ id: spec, status: send ? "sent" : "no-send-control" });
    continue;
  }
  if (spec.startsWith("!change=")) {
    const target = cardOf(spec.slice(8));
    const change = target && target.find((c) => c.getAttribute("data-change") !== null)[0];
    if (change) change.dispatch("click");
    submits.push({ id: spec, status: change ? "changed" : "no-change-control" });
    continue;
  }
  if (spec.startsWith("!restore=")) {
    const [target, value] = spec.slice(9).split(/=(.*)/s);
    const field = cardOf(target) && cardOf(target).find((c) => c.name === "queued")[0];
    if (field) { field.value = value; for (const fn of messageListeners) fn({}); }
    submits.push({ id: spec, status: field ? "restored" : "no-answer-field" });
    continue;
  }
  const [id, rest] = spec.split(/=(.*)/s);
  const [value, note] = rest.split(/:(.*)/s);
  const card = cardOf(id);
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
const projects = root.children.filter((c) => c.getAttribute("data-project") !== null).map((p) => {
  const head = p.children[0];
  const one = (cls) => { const n = head.find((c) => c.hasClass(cls))[0]; return n ? text(n) : null; };
  return {
    label: p.getAttribute("data-project"),
    key: p.getAttribute("data-project-key"),
    badges: badges(head.children[0]),
    description: one("proj-desc"),
    status: one("proj-status"),
    progress: one("prog-text"),
    latest: one("proj-latest"),
    questions: p.find((c) => c.getAttribute("data-question") !== null).map((q) => {
      const form = q.find((c) => c.tagName === "FORM")[0];
      const ro = q.find((c) => c.getAttribute("data-readonly") !== null)[0];
      const topic = q.find((c) => c.hasClass("q-topic"))[0];
      const why = q.find((c) => c.hasClass("q-why"))[0];
      const note = form ? form.find((c) => c.name === "note")[0] : null;
      return {
        id: q.getAttribute("data-question"),
        mode: q.getAttribute("data-mode"),
        title: text(q.find((c) => c.tagName === "H3")[0]),
        topic: topic ? text(topic) : null,
        why: why ? text(why) : null,
        parts: q.find((c) => c.getAttribute("data-part") !== null).map((c) => c.getAttribute("data-part")),
        project: say(q, "project", "B"),
        about: say(q, "about", "P"),
        purpose: say(q, "purpose", "P"),
        needsExplanation: say(q, "needs-explanation"),
        urgent: q.hasClass("q-urgent"),
        badges: badges(q.children[0]),
        answerable: Boolean(form),
        lavishQuestion: form ? form.getAttribute("data-lavish-question") : null,
        readonly: ro ? { status: ro.getAttribute("data-readonly"), text: text(ro) } : null,
        options: form ? form.find((c) => c.hasClass("q-opt")).map((o) => ({
          value: o.find((c) => c.type === "radio")[0].value,
          label: text(o.find((c) => c.hasClass("q-opt-label"))[0]),
          detail: (o.find((c) => c.hasClass("q-opt-detail"))[0] || null) && text(o.find((c) => c.hasClass("q-opt-detail"))[0]),
          recommended: o.find((c) => c.hasClass("rec")).length > 0,
        })) : [],
        noteField: note ? note.tagName.toLowerCase() : null,
        modeText: form ? text(form.find((c) => c.hasClass("q-mode"))[0]) : null,
        submit: form ? text(form.find((c) => c.tagName === "BUTTON" && c.type === "submit")[0]) : null,
        answer: q.getAttribute("data-answer"),
        answered: form && !form.find((c) => c.hasClass("q-answered"))[0].hidden
          ? text(form.find((c) => c.hasClass("q-answered-main"))[0]) : null,
        kept: form ? form.find((c) => c.name === "queued")[0].value : null,
        change: q.getAttribute("data-answer") === "queued" || q.getAttribute("data-answer") === "sent"
          ? text(form.find((c) => c.getAttribute("data-change") !== null)[0]) : null,
        status: form ? text(form.find((c) => c.hasClass("q-status"))[0]) : null,
      };
    }),
    lanes: Object.fromEntries(p.find((c) => c.getAttribute("data-lane-box") !== null).map((lane) => {
      const more = lane.find((c) => c.getAttribute("data-lane-more") !== null)[0];
      const folded = new Set(more ? more.find((c) => c.getAttribute("data-task") !== null) : []);
      const none = lane.find((c) => c.hasClass("lane-none"))[0];
      return [lane.getAttribute("data-lane-box"), {
        count: Number(text(lane.find((c) => c.hasClass("lane-count"))[0])),
        say: text(lane.find((c) => c.hasClass("lane-say"))[0]),
        none: none ? text(none) : null,
        more: more ? Number(more.getAttribute("data-lane-more")) : 0,
        cards: lane.find((c) => c.getAttribute("data-task") !== null).map((w) => ({
          id: w.getAttribute("data-task"),
          lane: w.getAttribute("data-lane"),
          why: w.getAttribute("data-why"),
          reason: badges(w)[0] || null,
          title: text(w.find((c) => c.hasClass("w-title"))[0]),
          note: (w.find((c) => c.hasClass("w-note"))[0] || null) && text(w.find((c) => c.hasClass("w-note"))[0]),
          links: w.find((c) => c.tagName === "A").map((a) => ({ href: a.href, text: text(a) })),
          folded: folded.has(w),
        })),
      }];
    })),
    text: text(p),
  };
});
const idle = root.find((c) => c.getAttribute("data-idle") !== null)[0];

console.log(JSON.stringify({
  freshness: fresh ? fresh.getAttribute("data-freshness") : null,
  freshText: text(byId.get("lb-fresh")),
  banner: text(byId.get("lb-banner")),
  home: text(byId.get("lb-home")),
  stats,
  notes: byId.get("lb-notes").find((c) => c.tagName === "LI").map(text),
  empty: root.find((c) => c.getAttribute("data-empty") !== null).map(text)[0] || null,
  idle: idle ? { count: Number(idle.getAttribute("data-idle")),
    names: idle.find((c) => c.getAttribute("data-quiet-project") !== null).map((c) => c.getAttribute("data-quiet-project")),
    lines: idle.find((c) => c.tagName === "LI").map(text) } : null,
  foot: text(byId.get("lb-foot")),
  projects,
  submits,
  queued: queued.map((q) => ({ prompt: q.prompt, tag: q.options.tag, data: q.options.data })),
  sends,
  tray: ((bar) => bar ? { count: Number(bar.getAttribute("data-tray")),
    text: text(bar.children[0]),
    send: (bar.find((c) => c.getAttribute("data-send") !== null)[0] || null) && text(bar.find((c) => c.getAttribute("data-send") !== null)[0]) } : null)(
    byId.get("lb-tray").children[0]),
  tickers,
}));
