// Run a built Bridge page's shipped inline script under a minimal DOM shim and
// print what it rendered, so page behavior is asserted through the real built
// file rather than by reading the template source.
//
// Usage: node bridge-render-harness.mjs <bridge.html> [now-epoch] [spec...]
// A spec `<ask-id>=<option-value>[:<note>]` (empty value for a note-only
// answer) fills that card's form and submits it with window.lavish present;
// `!nolavish` (first) runs the page without window.lavish.
// Prints one JSON document:
//   { fresh, stale, staleBanner, banners:[text], stats:[text],
//     sections:[{title, count, asks:[id]}], groups:[{title, asks:[id]}],
//     cards:{<ask>:{text, queued, status}}, text, queued:[{prompt, tag, text, data}],
//     sources:text }
import { readFileSync } from "node:fs";

const [file, nowArg, ...specs] = process.argv.slice(2);
const html = readFileSync(file, "utf8");
const payload = html.match(/<script id="bridge-data" type="application\/json">\n([\s\S]*?)\n<\/script>/)[1];
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
const code = scripts[scripts.length - 1][1];

class Ev {
  constructor(type, opts) { this.type = type; this.bubbles = !!(opts && opts.bubbles); }
  preventDefault() {}
}
class N {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.parentNode = null; this.attrs = {};
    this.className = ""; this.hidden = false; this._text = ""; this.listeners = {};
    this.value = ""; this.type = ""; this.name = ""; this.checked = false; this.placeholder = "";
  }
  appendChild(c) {
    if (c.parentNode) c.parentNode.removeChild(c);
    c.parentNode = this; this.children.push(c); return c;
  }
  removeChild(c) { this.children = this.children.filter((x) => x !== c); c.parentNode = null; return c; }
  get firstChild() { return this.children[0] || null; }
  set textContent(v) { this.children = []; this._text = String(v); }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(""); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  dispatchEvent(ev) {
    (this.listeners[ev.type] || []).forEach((f) => f(ev));
    if (ev.bubbles && this.parentNode) this.parentNode.dispatchEvent(ev);
    return true;
  }
  matches(sel) {
    return sel.split(",").some((one) => {
      one = one.trim();
      if (one.startsWith(".")) return this.className.split(/\s+/).includes(one.slice(1));
      const m = one.match(/^(\w+)\[type=(\w+)\]$/);
      if (m) return this.tagName === m[1] && this.type === m[2];
      return this.tagName === one;
    });
  }
  walk(fn) { this.children.forEach((c) => { fn(c); c.walk(fn); }); }
  querySelectorAll(sel) { const out = []; this.walk((n) => { if (n.matches(sel)) out.push(n); }); return out; }
}
const ids = {};
const document = {
  createElement: (t) => new N(t),
  createTextNode: (t) => { const n = new N("#text"); n._text = String(t); return n; },
  getElementById: (id) => ids[id] || null,
};
ids["bridge-data"] = new N("script"); ids["bridge-data"]._text = payload;
ids.root = new N("div");
ids.fresh = new N("span");

const queued = [];
const noLavish = specs[0] === "!nolavish";
const windowObj = {
  listeners: {},
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); },
};
if (!noLavish) {
  windowObj.lavish = { queuePrompt: (prompt, opts) => queued.push({ prompt, tag: opts.tag, text: opts.text, data: opts.data }) };
}
const now = Number(nowArg || Math.floor(Date.now() / 1000));
const RealDate = Date;
const FakeDate = class extends RealDate { static now() { return now * 1000; } };
new Function("window", "document", "Event", "setInterval", "setTimeout", "Date", code)(
  windowObj, document, Ev, () => 0, (f) => f(), FakeDate);

const root = ids.root;
const cardOf = (ask) => { let hit = null; root.walk((n) => { if (n.tagName === "article" && n.getAttribute("data-ask") === ask) hit = n; }); return hit; };
for (const spec of specs) {
  if (spec.startsWith("!")) continue;
  const at = spec.indexOf("=");
  const ask = spec.slice(0, at);
  let rest = spec.slice(at + 1), note = "";
  const colon = rest.indexOf(":");
  if (colon >= 0) { note = rest.slice(colon + 1); rest = rest.slice(0, colon); }
  const c = cardOf(ask);
  if (!c) { console.error("no card " + ask); process.exit(3); }
  const form = c.querySelectorAll("form")[0];
  form.querySelectorAll("input").forEach((i) => { if (i.type === "radio") i.checked = i.value === rest; if (i.name === "note") i.value = note; });
  form.querySelectorAll("textarea").forEach((t) => { t.value = note; });
  form.dispatchEvent(new Ev("submit"));
}

function visible(n) {
  if (n.hidden) return "";
  if (n.tagName === "#text") return n._text;
  return n._text + n.children.map(visible).join(n.tagName === "ul" || n.tagName === "div" ? " " : "");
}
const out = { fresh: ids.fresh.textContent, stale: /is-stale/.test(ids.fresh.className), staleBanner: "",
  banners: [], stats: [], sections: [], groups: [], cards: {}, queued, text: "", sources: "" };
let current = null;
root.children.forEach((n) => {
  if (n.tagName === "div" && /\bbanner\b/.test(n.className)) {
    if (!n.hidden) out.banners.push(visible(n));
    if (/\bbad\b/.test(n.className) && /last checked/.test(n.textContent)) out.staleBanner = n.hidden ? "" : n.textContent;
  } else if (n.className === "stats") {
    out.stats = n.children.map((s) => visible(s));
  } else if (n.tagName === "h2") {
    current = { title: n._text.trim(), count: n.children.map((c) => c.textContent).join(""), asks: [] };
    out.sections.push(current);
  } else if (n.tagName === "article") {
    current.asks.push(n.getAttribute("data-ask"));
  } else if (n.tagName === "details") {
    const g = { title: n.children[0].textContent, asks: [] };
    n.walk((x) => { if (x.tagName === "article") g.asks.push(x.getAttribute("data-ask")); });
    out.groups.push(g);
  } else if (n.className === "sources") {
    out.sources = visible(n);
  } else if (n.tagName === "p" && current) {
    current.empty = n.textContent;
  }
});
root.walk((n) => {
  if (n.tagName !== "article") return;
  const status = n.querySelectorAll("span").filter((s) => s.getAttribute("role") === "status").map((s) => s.textContent).join("");
  out.cards[n.getAttribute("data-ask")] = { text: visible(n), queued: /is-queued/.test(n.className), status };
});
out.text = ids.fresh.textContent + " " + visible(root);
process.stdout.write(JSON.stringify(out) + "\n");
