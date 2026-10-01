// Drive headless Chrome over CDP: load a built board, screenshot it collapsed,
// click the first open-work row's summary, screenshot expanded, and dump facts.
// Usage: node cdp-shoot.mjs <port> <file.html> <out-prefix>
import { writeFileSync } from "node:fs";
const [port, file, out] = process.argv.slice(2);
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/new?file://${file}`, { method: "PUT" })).json();
const ws = new WebSocket(tabs.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let id = 0; const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true })).result.result.value;
const shot = async (name) => {
  const h = await ev("Math.ceil(document.documentElement.scrollHeight)");
  await send("Emulation.setDeviceMetricsOverride", { width: 1100, height: h, deviceScaleFactor: 1, mobile: false });
  const r = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  writeFileSync(`${out}-${name}.png`, Buffer.from(r.result.data, "base64"));
};
await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 1100, height: 900, deviceScaleFactor: 1, mobile: false });
await new Promise((r) => setTimeout(r, 1500));
const facts = (label) => ev(`(() => {
  const vis = (el) => el && !el.hidden && el.offsetParent !== null;
  const rows = [...document.querySelectorAll('.bb-row')].filter(vis);
  return {
    label: ${JSON.stringify(label)},
    sectionOrder: [...document.querySelectorAll('[id$="-section"]')].filter(vis).map(s => s.id),
    rows: rows.map(r => ({ tag: r.tagName, open: r.open ?? null, tone: (r.className.match(/bb-work--(\\w+)/)||[])[1] || '',
      title: r.querySelector('.bb-row__title')?.textContent, sub: r.querySelector('.bb-row__sub')?.textContent || '',
      badge: [...r.querySelectorAll('summary .fm-badge, :scope > .fm-badge')].map(b => b.textContent).join('|'),
      borderColor: getComputedStyle(r).borderLeftColor,
      detailVisible: vis(r.querySelector('.bb-work__detail')), detail: r.querySelector('.bb-work__detail')?.innerText || '' })),
    projects: [...document.querySelectorAll('.bb-project__name')].filter(vis).map(n => n.textContent),
    idleMsgVisible: vis(document.getElementById('bb-idle')),
    completed: (() => { const d = document.querySelector('#bb-landed-section details'); return d ? { open: d.open, summary: d.querySelector('summary')?.textContent } : null; })(),
    bodyBg: getComputedStyle(document.body).backgroundColor,
    colorScheme: document.querySelector('meta[name=color-scheme]')?.content,
    errors: document.body.innerText.includes('could not') ? document.body.innerText.slice(0, 200) : '',
  }; })()`);
const before = await facts("collapsed");
await shot("collapsed");
await ev(`document.querySelector('#bb-underway .bb-row summary')?.click(); document.querySelector('#bb-charted .bb-row summary')?.click(); true`);
await new Promise((r) => setTimeout(r, 300));
const after = await facts("expanded-first-underway-and-charted");
await shot("expanded");
writeFileSync(`${out}-facts.json`, JSON.stringify({ before, after }, null, 2));
console.log(JSON.stringify({ before, after }, null, 1));
ws.close();
