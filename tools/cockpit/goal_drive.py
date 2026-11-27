#!/usr/bin/env python3
"""Render the fixed first section (captain cards) and shared goal views from cockpit truth,
or preview drive controls from goal export. Existing keyed host forms keep their routing."""

import argparse
from collections import Counter, defaultdict
import datetime
import hashlib
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


TRUTH_SCHEMA = 'fm-cockpit-truth.v1'
GOAL_BIN = Path(__file__).resolve().parents[2] / 'bin' / 'fm-goal.sh'
GENERATED = re.compile(r'<!-- fm-goal-drive -->.*?<!-- /fm-goal-drive -->', re.S)
STATUSES = {
    'done': ('Klaar', '#63d6ad'),
    'running': ('Bezig', '#66b5ff'),
    'startable': ('Kan starten', '#ffc35c'),
    'waiting': ('Wacht', '#a3afc2'),
    'open-captain': ('Aan jou', '#d8a8ff'),
    'dropped': ('Vervallen', '#858892'),
}
ATTRIBUTE = re.compile(r' data-fm-goal-drive="(?:on|off)"(?=>)|'
                       r' data-fm-goal-status="(?:' + '|'.join(STATUSES) + r')"(?=>)')
STYLE = '''<style>
[data-fm-goal-drive="off"], .fm-goal-kpi-off { filter: grayscale(1); }
#fm-goal-kpis, #fm-budget-lines { list-style:none; margin:4px 0 8px; padding:0; }
#fm-goal-kpis > li, #fm-budget-lines > li { display:flex; flex-wrap:wrap; align-items:baseline; gap:4px 8px; margin:0 0 4px;
    border:1px solid #465369; border-radius:6px; padding:3px 6px; background:#141821;
    color:#f2f4f8; font-size:.875rem; }
.fm-goal-kpi-title { flex:1 1 8rem; min-inline-size:0; color:inherit;
    white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.fm-goal-kpi-metrics { flex:none; max-inline-size:75%; display:flex; flex-wrap:wrap;
    gap:2px 4px; font-size:.75rem; }
.fm-goal-kpi-metrics > span { white-space:nowrap; color:var(--fm-goal-color); }
.fm-budget-home { flex:0 1 auto; font-weight:700; }
.fm-budget-metrics { flex:1 1 auto; min-inline-size:0; display:flex; flex-wrap:wrap; gap:2px 8px; font-size:.75rem; color:#d4dbe7; }
.fm-budget-metrics > span { white-space:nowrap; }
.fm-budget-metrics > [data-fm-budget="closes"] { white-space:normal; overflow-wrap:anywhere; }
.fm-budget-over { color:#ffc35c; font-weight:700; }
.fm-goal-readiness, .fm-goal-pace { color:#d4dbe7; font-size:.75rem; }
.fm-goal-readiness { flex:none; max-inline-size:100%; }
.fm-goal-pace > span { white-space:nowrap; }
.fm-goal-pace-warning { color:#ffc35c; font-weight:bold; }
p.fm-goal-pace { display:table; background:#141821; border-radius:4px; margin:4px 0; padding:2px 4px; }
@media (max-width:640px) {
    #fm-budget-lines .fm-budget-home { flex:0 1 100%; }
    #fm-goal-kpis .fm-goal-kpi-title { flex:0 1 100%; }
    #fm-goal-kpis .fm-goal-kpi-metrics { max-inline-size:100%; }
    #fm-goal-kpis .fm-goal-readiness, #fm-goal-kpis .fm-goal-pace { flex:0 1 100%; }
}
.fm-goal-drive { display:flex; flex-wrap:wrap; align-items:center; gap:4px 8px; margin:2px 0 4px; }
.fm-goal-drive button { font:inherit; color:inherit; background:#202633; border:1px solid #546074;
                        border-radius:6px; padding:4px 8px; cursor:pointer; }
.fm-goal-drive-state { color:#7fe0a5; font-weight:bold; }
.fm-goal-drive .st { background:none; border:0; padding:0; }
.fm-goal-drive .st:empty { display:none; }
.fm-goal-items { color-scheme:dark; color:#f2f4f8; background:#141821; border:1px solid #465369;
                 border-radius:8px; padding:12px; margin:6px 0 10px; }
.fm-goal-items-body { display:flex; align-items:center; flex-wrap:wrap; gap:12px 16px; }
.fm-goal-ring { flex:none; border-radius:50%; inline-size:6rem; block-size:6rem;
                background:#3b4659; background-image:var(--fm-goal-ring, none);
                display:grid; place-items:center; }
.fm-goal-ring > span { border-radius:50%; inline-size:4.65rem; block-size:4.65rem;
                       background:#141821; display:grid; place-content:center; text-align:center;
                       font-size:.75rem; line-height:1.2; }
.fm-goal-ring strong { font-size:1.2rem; }
.fm-goal-items ul { flex:1 1 8rem; min-inline-size:0; max-inline-size:14rem;
                    list-style:none; padding:0; margin:0; font-size:.875rem; }
.fm-goal-items li { display:grid; grid-template-columns:.65rem minmax(0,1fr) auto;
                    align-items:center; gap:.55rem; margin:0; overflow-wrap:anywhere; }
.fm-goal-items li::before { content:""; inline-size:.65rem; block-size:.65rem;
                            border-radius:50%; background:var(--fm-goal-color); }
span.fm-goal-item-status[data-fm-goal-status] { display:inline-block; color:#f2f4f8; background:#141821;
    border:1px solid var(--fm-goal-color); border-inline-start-width:4px; border-radius:4px;
    padding:0 4px; font-size:.75rem; font-weight:700; }
text.fm-goal-item-status[data-fm-goal-status] { fill:var(--fm-goal-color); font-weight:700; }
.fm-goal-steps { margin-block-start:4px; }
.fm-goal-steps > summary { cursor:pointer; }
.fm-goal-steps > .fm-goal-items { padding:8px; margin:4px 0; }
.fm-goal-steps .fm-goal-ring { inline-size:4rem; block-size:4rem; }
.fm-goal-steps .fm-goal-ring > span { inline-size:3.1rem; block-size:3.1rem; }
.fm-goal-steps .fm-goal-ring strong { font-size:.95rem; }
.fm-goal-steps > ul { margin:4px 0 0; padding-inline-start:1.25rem; overflow-wrap:anywhere; }
.fm-goal-box { border:1px solid #465369; border-radius:6px; padding:4px 8px; margin:4px 0; }
''' + '\n'.join(f'[data-fm-goal-status="{state}"] {{ --fm-goal-color:{color}; }}'
                for state, (_, color) in STATUSES.items()) + '</style>'


def goals_from(home):
    result = subprocess.run(
        ['bash', str(GOAL_BIN), 'export'], check=True, text=True, stdout=subprocess.PIPE,
        env={**os.environ, 'FM_HOME': str(home), 'FM_STATE_OVERRIDE': str(home / 'state'),
             'FM_DATA_OVERRIDE': str(home / 'data')},
    )
    snapshot = json.loads(result.stdout)
    if snapshot['schema'] != 'fm-goal-export.v1':
        raise ValueError('unsupported goal export schema')
    return snapshot['goals']


def generated(fragment):
    return '<!-- fm-goal-drive -->' + fragment + '<!-- /fm-goal-drive -->'


def item_status(item):
    # The export already applies dependencies, pause and orphaned-running checks.
    if item['startable']:
        return 'startable'
    state = item['state']
    if state == 'open' and item['class'] == 'captain':
        return 'open-captain'
    if state in ('open', 'blocked'):
        return 'waiting'
    if state not in STATUSES:
        raise ValueError(f'unsupported goal item state: {state}')
    return state


def items_kpi(statuses, element_id='doel-item-kpi'):
    total = len(statuses)
    counts = dict.fromkeys(STATUSES, 0)
    for state in statuses:
        counts[state] += 1
    legend, stops = [], []
    seen = 0
    for state, (label, color) in STATUSES.items():
        count = counts[state]
        legend.append(f'<li data-fm-goal-status="{state}"><span>{label}</span> <b>{count}</b></li>')
        if count:
            stops.append(f'{color} {seen / total:.8%} {(seen + count) / total:.8%}')
            seen += count
    ring = f' style="--fm-goal-ring:conic-gradient({", ".join(stops)})"' if stops else ''
    return (f'<div class="fm-goal-items" id="{element_id}">'
            '<div class="fm-goal-items-body">'
            f'<div class="fm-goal-ring"{ring}><span><strong>{total}</strong> taken</span></div>'
            f'<ul role="list" aria-label="Status van doeltaken">{"".join(legend)}</ul></div></div>')


def drive_kpi(goals):
    return ('<p class="small mute" id="doel-drive-kpi">'
            f'{sum(bool(g["driven"]) for g in goals)} van {len(goals)} doelen actief gedreven</p>')


def pace_marker(goal, *, card=False):
    pace = goal.get('pace')
    if not goal['driven'] or pace is None:
        return ''
    tag = 'p' if card else 'span'
    ident = f' id="fm-goal-pace-{html.escape(goal["id"])}"' if card else ''
    warning = ' class="fm-goal-pace-warning"' if pace['idle'] and pace['idle_minutes'] > 10 else ''
    return (f'<{tag}{ident} class="fm-goal-pace">Tempo: <span>{pace["running"]} actief</span> · '
            f'<span{warning}>{pace["idle"]} stil ({pace["idle_minutes"]}m)</span> · '
            f'<span>{pace["waiting"]} wacht</span></{tag}>')


def readiness_marker(goal):
    readiness = goal.get('drive_ready', {})
    if readiness.get('total') == 0:
        label = 'Geen crewtaken'
    elif 'ready' not in readiness:
        label = 'Instructies: niet gecontroleerd'
    else:
        label = f'Instructies klaar: {readiness["ready"]}/{readiness["total"]}'
        if readiness['unknown']:
            label += f' · {readiness["unknown"]} niet gecontroleerd'
    return f'<span class="fm-goal-readiness">{label}</span>'


def goal_kpis(goals):
    if not goals:
        return ''
    rows = []
    for goal in goals:
        items = goal['items']
        counts = Counter(i['status'] for i in items)
        metrics = []
        for state in ('done', 'startable', 'running', 'waiting', 'open-captain'):
            count = f'{counts[state]}/{len(items)}' if state == 'done' else counts[state]
            metrics.append(f'<span data-fm-goal-status="{state}">{count} {STATUSES[state][0]}</span>')
        gid, title = html.escape(goal['id']), html.escape(goal['title'])
        off = '' if goal['driven'] else ' class="fm-goal-kpi-off"'
        rows.append(f'<li{off}><a class="fm-goal-kpi-title" href="#doel-{gid}" title="{title}">{title}</a>'
                    f'<span class="fm-goal-kpi-metrics">{"".join(metrics)}</span>'
                    f'{readiness_marker(goal)}{pace_marker(goal)}</li>')
    return f'<ul id="fm-goal-kpis" role="list" aria-label="Status per doel">{"".join(rows)}</ul>'


def data_size(size):
    if size is None:
        return '?'
    for unit in ('B', 'KB', 'MB', 'GB'):
        if size < 1024 or unit == 'GB':
            return f'{size} B' if unit == 'B' else f'{size:.1f} {unit}'
        size /= 1024


def calls_text(calls):
    text = f'{calls["count"]}/{calls["limit"]}'
    if calls['count']:
        text += f' · oldest {"?" if calls["oldest_days"] is None else calls["oldest_days"]}d'
    return text


def budget_metric(kind, label, text, over=False):
    cls = ' class="fm-budget-over"' if over else ''
    return f'<span data-fm-budget="{kind}"{cls}>{label} {text}{" over" if over else ""}</span>'


def budget_strip(lines):
    """One compact line per home from the truth's budget_lines; every number is the owning script's."""
    if not lines:
        return ''
    rows = []
    for line in lines:
        queued, calls, memory, sweep = line['queued'], line['calls'], line['memory'], line['sweep']
        metrics = [
            budget_metric('queued', 'queued rows', '?' if queued is None else f'{queued["count"]}/{queued["limit"]}',
                          queued is not None and queued['count'] > queued['limit']),
            budget_metric('calls', 'open captain calls', '?' if calls is None else calls_text(calls),
                          calls is not None and calls['count'] > calls['limit']),
            budget_metric('memory', 'startup memory', '?' if memory is None else f'{memory["tokens"]:,}/{memory["budget"]:,}',
                          memory is not None and memory['tokens'] > memory['budget']),
            budget_metric('data', 'data', data_size(line['data_bytes'])),
        ]
        if sweep is None:
            metrics.append('<span data-fm-budget="sweep">no sweep yet</span>')
        else:
            when = datetime.datetime.fromtimestamp(sweep['at'], datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
            metrics.append(f'<span data-fm-budget="sweep">last sweep {when}</span>')
            counts = ' · '.join(f'{key} {"?" if value is None else value}' for key, value in sweep['counts'].items())
            failed = f' · failed {html.escape(", ".join(sweep["failed"]))}' if sweep['failed'] else ''
            metrics.append(f'<span data-fm-budget="closes">{"closed" if sweep["mode"] == "on" else "would close"}: {counts}{failed}</span>')
        rows.append(f'<li data-fm-budget-home="{html.escape(line["home"], quote=True)}">'
                    f'<span class="fm-budget-home">{html.escape(line["home"])}</span>'
                    f'<span class="fm-budget-metrics">{"".join(metrics)}</span></li>')
    return f'<ul id="fm-budget-lines" role="list" aria-label="Budget per home">{"".join(rows)}</ul>'


def drive_switch(goal):
    goal_id, on = goal['id'], goal['driven']
    label = html.escape('Firstmate stuurt: ' + goal['title'], quote=True)
    answer = html.escape(f'{"pause" if on else "resume"} {goal_id}', quote=True)
    key = 'goal.drive.' + hashlib.sha256(goal_id.encode('ascii')).hexdigest()
    return f'''<form class="fm-goal-drive small" data-lavish-question="{key}" onsubmit="return mikoSend(event,'{key}')">
<span class="fm-goal-drive-state">{'wordt gedreven' if on else 'uit'}</span>
<input type="hidden" name="a" value="{answer}">
<button type="submit" role="switch" aria-checked="{'true' if on else 'false'}" aria-label="{label}">{'Zet uit' if on else 'Zet aan'}</button>
<span class="st mute small" role="status"></span></form>'''


def base_page(page):
    return ATTRIBUTE.sub('', GENERATED.sub('', page))


def render_preview(page, goals, allow=None):
    base = base_page(page)
    parsed = GoalPage(base)
    heading = heading_end(base, parsed)
    if allow:
        goals = [g for g in goals if g['id'] in allow]
    statuses = {key: item_status(item) for key, item in item_keys(goals).items()}
    patches = [(heading, generated(STYLE + drive_kpi(goals) + items_kpi(list(statuses.values()))))]
    for node in parsed.nodes:
        if node.key in statuses and is_slot(node):
            patches.extend(slot_patches(node, statuses[node.key]))
    for g in goals:
        cards = goal_cards(parsed, g)
        if len(cards) != 1:
            raise ValueError(f'expected one cockpit card #doel-{g["id"]}')
        end = cards[0].end
        patches.append((end - 1, f' data-fm-goal-drive="{"on" if g["driven"] else "off"}"'))
        patches.append((end, generated(drive_switch(g))))
    return apply_patches(base, patches)


def apply_patches(base, patches):
    for offset, fragment in sorted(patches, key=lambda patch: patch[0], reverse=True):
        base = base[:offset] + fragment + base[offset:]
    return base


VOID = set('area base br col embed hr img input link meta param source track wbr'.split())


class Node:
    def __init__(self, tag, attrs, parent, start, end):
        self.tag, self.attrs, self.parent, self.start, self.end = tag, dict(attrs), parent, start, end
        self.parts, self.close = [], None
        self.classes = set((self.attrs.get('class') or '').split())
        self.id = self.attrs.get('id')
        self.key = self.attrs.get('data-fm-goal-item')
        # Closed details are still rendered and reachable; hidden content is not.
        self.visible = (not parent or parent.visible) and 'hidden' not in self.attrs and tag not in {
            'template', 'script', 'style', 'title', 'desc', 'noscript'}

    def ancestor(self, matches):
        node = self.parent
        while node and not matches(node):
            node = node.parent
        return node

    def text(self):
        return ''.join(p if isinstance(p, str) else p.text() for p in self.parts) if self.visible else ''

    def signature(self):
        # Compare generated views as parsed markup, not against HTML serialization details.
        return (self.tag, self.attrs, [p.signature() if isinstance(p, Node) else p.strip()
                                       for p in self.parts if isinstance(p, Node) or p.strip()])


class GoalPage(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.offsets = [0] + [m.end() for m in re.finditer('\n', page)]
        self.stack, self.nodes, self.by_id, self.root_parts = [], [], defaultdict(list), []
        self.feed(page)
        self.close()

    def absolute_offset(self):
        line, col = self.getpos()
        return self.offsets[line - 1] + col

    def start(self, tag, attrs, push):
        parent = self.stack[-1] if self.stack else None
        start = self.absolute_offset()
        node = Node(tag, attrs, parent, start, start + len(self.get_starttag_text()))
        self.nodes.append(node)
        if node.id:
            self.by_id[node.id].append(node)
        (parent.parts if parent else self.root_parts).append(node)
        if push:
            self.stack.append(node)

    def handle_starttag(self, tag, attrs):
        self.start(tag, attrs, tag not in VOID)

    def handle_startendtag(self, tag, attrs):
        self.start(tag, attrs, False)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i].tag == tag:
                self.stack[i].close = self.absolute_offset()
                del self.stack[i:]
                break

    def handle_data(self, data):
        (self.stack[-1].parts if self.stack else self.root_parts).append(data)


def truth_path(home, scope):
    projects = sorted({name.rstrip('/').rsplit('/', 1)[-1].casefold() for name in scope if name})
    suffix = '.'.join(projects)
    if suffix and not re.fullmatch(r'[a-z0-9_.-]+', suffix):
        raise ValueError('use --out for a scope with non-slug characters')
    return Path(home) / 'state' / ('cockpit-truth' + ('.' + suffix if suffix else '') + '.json')


DECISION_SECTIONS = ('captain-door', 'beslissingen')
OTHER_PROJECTS = 'overige-projecten'
CAPTAIN_BUCKETS = ('must', 'can', 'later')
PAGE_CONTROL = re.compile(r'^(?:goal\.drive\.|ververs|refresh)', re.I)
CAPTAIN_STYLE = '''<style>
.fm-captain { box-sizing:border-box; width:100%; max-width:48rem; margin:0 auto 1rem; padding:clamp(.75rem,3vw,1.5rem);
  background:#0f131a; color:#f1f4fa; color-scheme:dark; font:1rem/1.5 system-ui,sans-serif; overflow-wrap:anywhere; }
.fm-captain :is(h1,h2,h3,p,ol,ul) { margin:0; }
.fm-captain > h2 { font-size:clamp(1.4rem,5vw,2rem); margin-bottom:.75rem; }
.fm-captain > [data-captain-priority] { margin-top:.9rem; }
.fm-captain :is(summary,h3) { font-weight:700; cursor:inherit; }
.fm-captain summary { cursor:pointer; padding:.45rem 0; }
.fm-captain article { --badge:#b5a1ff; display:grid; gap:.65rem; min-width:0; margin:.55rem 0;
  padding:clamp(.85rem,3vw,1.15rem); border:1px solid #3a4658; border-inline-start:4px solid var(--badge);
  border-radius:.75rem; background:#1a2330; color:#f1f4fa; text-align:start; }
.fm-captain article[data-captain-type=taak] { --badge:#77dfbe; }
.fm-captain article h3 { font-size:1.15rem; color:#f1f4fa; }
.fm-captain [data-captain-field=type] { width:fit-content; padding:.1rem .55rem; border-radius:1rem;
  border:1px solid var(--badge); color:var(--badge); font-size:.82rem; font-weight:700; }
.fm-captain [data-captain-field=id] { color:#bcc8d8; font-size:.82rem; }
.fm-captain .fm-captain-group { color:#bcc8d8; font-size:.85rem; }
.fm-captain a { color:#9dd5ff; text-decoration:underline; }
.fm-captain :is(ul,ol) { padding-inline-start:1.35rem; }
.fm-captain li + li { margin-top:.45rem; }
.fm-captain .fm-captain-missing { color:#ffc391; }
.fm-captain button,.fm-captain textarea { max-width:100%; }
</style>'''


def captain_entries(truth):
    return [(bucket, row) for bucket in CAPTAIN_BUCKETS for row in truth.get('section1', {}).get(bucket, [])]


def missing_marker(name):
    return f'<span class="fm-captain-missing">ONTBREEKT: {html.escape(name)}</span>'


def captain_step(text):
    chunks = re.split(r'(https?://[^\s<>]+)', text)
    for i in range(1, len(chunks), 2):
        url = chunks[i].rstrip('.,;!?)')
        link = html.escape(url)
        chunks[i] = f'<a href="{link}">{link}</a>' + html.escape(chunks[i][len(url):])
    return ''.join(part if i % 2 else html.escape(part) for i, part in enumerate(chunks))


def captain_card(row, forms=''):
    key = html.escape(row['key'], quote=True)
    kind = row['type']
    missing = set(row['missing'])
    context = ' '.join(filter(None, (html.escape(row['about']), missing_marker('Waarvoor') if 'Waarvoor' in missing else '')))
    goal = ', '.join(f'<a href="#doel-{html.escape(gid, quote=True)}">{html.escape(title)}</a>'
                     for gid, title in row['goal_links'].items()) or 'Geen doel'
    body = (f'<p data-captain-field="type">{"Taak" if kind == "taak" else "Vraag"}</p>'
            f'<h3 data-captain-field="title">{html.escape(row["title"]) or missing_marker("Titel")}</h3>'
            f'<p data-captain-field="context"><b>Waarvoor</b> {context}</p>'
            f'<p data-captain-field="goal"><b>Doel</b> {goal}</p>'
            f'<p data-captain-field="id"><b>ID</b> <code>{key}</code></p>')
    if kind == 'taak':
        items = ''.join(f'<li>{captain_step(text)}</li>' for texts in row['steps'].values() for text in texts)
        notices = ' '.join(missing_marker(f) for f in ('Stappen', 'URL of klikpad') if f in missing)
        body += f'<div data-captain-field="steps"><b>Stappen</b>{"<ol>" + items + "</ol>" if items else ""}{notices}</div>'
        body += ('<p data-captain-field="result"><b>Verwacht resultaat</b> '
                 + (html.escape(row['expected']) or missing_marker('Verwacht resultaat')) + '</p>')
    else:
        if row['question'] and row['question'] != row['title']:
            body += f'<p data-captain-field="question">{html.escape(row["question"])}</p>'
        items = ''
        for option in row['options']:
            rec = '<strong data-captain-field="recommendation">Aanbevolen</strong> ' if option['value'] == row['recommendation'] else ''
            items += (f'<li><b>{html.escape(option["label"])}</b> {rec}'
                      f'{html.escape(option["detail"]) or missing_marker("Gevolg per optie")}</li>')
        notices = (missing_marker('Opties') if 'Opties' in missing else '')
        if 'Aanbeveling' in missing:
            notices += f'<p data-captain-field="recommendation">{missing_marker("Aanbeveling")}</p>'
        body += f'<div data-captain-field="options"><b>Opties</b>{"<ul>" + items + "</ul>" if items else ""}{notices}</div>'
    if row.get('group') == 'other_projects':
        body += '<p class="fm-captain-group">Overige projecten</p>'
    if forms:
        body += f'<div data-captain-controls>{forms}</div>'
    return f'<article data-cockpit-captain="{key}" data-captain-type="{kind}">{body}</article>'


def captain_section(truth, section_id, forms):
    cards = defaultdict(list)
    for bucket, row in captain_entries(truth):
        cards[bucket].append(captain_card(row, forms.get(row['key'], '')))
    body = '<h2>1. Vragen en taken voor jou</h2>'
    for bucket, label in zip(CAPTAIN_BUCKETS, ('Moet', 'Kan', 'Later')):
        rows = ''.join(cards[bucket])
        if bucket == 'must':
            body += f'<div data-captain-priority="must"><h3>{label} ({len(cards[bucket])})</h3>{rows}</div>'
        else:
            opened = ' open' if bucket == 'can' else ''
            body += f'<details data-captain-priority="{bucket}"{opened}><summary>{label} ({len(cards[bucket])})</summary>{rows}</details>'
    if not any(cards.values()):
        body += '<p>Geen open vragen of taken.</p>'
    return f'<section id="{html.escape(section_id)}" class="fm-captain">{CAPTAIN_STYLE}{body}</section>'


def captain_goal_refs(truth):
    full = {goal['id'] for goal in truth['goals']}
    return {gid: title for _, row in captain_entries(truth) for gid, title in row['goal_links'].items() if gid not in full}


def render_captain_steps(page, truth):
    parsed = GoalPage(page)
    sections = [n for n in parsed.nodes if n.id in (*DECISION_SECTIONS, OTHER_PROJECTS)
                and n.close is not None]
    section_set = set(sections)
    sections = [n for n in sections if not n.ancestor(section_set.__contains__)]
    section_id = next((n.id for n in sections if n.id in DECISION_SECTIONS), DECISION_SECTIONS[0])
    owners = {key: row['key'] for _, row in captain_entries(truth) for key in [row['key'], *row['aliases']]}
    forms, controls = defaultdict(list), []
    for node in parsed.nodes:
        if node.tag != 'form' or not node.visible or node.close is None or not node.ancestor(section_set.__contains__):
            continue
        key = node.attrs.get('data-lavish-question') or ''
        fragment = page[node.start:page.index('>', node.close) + 1]
        if key in owners:
            forms[owners[key]].append(fragment)
        elif PAGE_CONTROL.search(key):
            controls.append(fragment)
    old_refs = [n for n in parsed.by_id['fm-captain-goal-refs'] if n.close is not None]
    for node in sorted(sections + old_refs, key=lambda n: n.start, reverse=True):
        page = page[:node.start] + page[page.index('>', node.close) + 1:]
    parsed = GoalPage(page)
    body = next((n for n in parsed.nodes if n.tag == 'body'), None)
    root = next((n for n in parsed.nodes if n.tag == 'html'), None)
    at = body.end if body else next((page.index('>', n.close) + 1 for n in parsed.nodes
                                    if n.tag == 'head' and n.close is not None), root.end if root else 0)
    refs = captain_goal_refs(truth)
    if refs:
        cards = ''.join(f'<article id="doel-{html.escape(gid)}"><h3>{html.escape(title)}</h3></article>'
                        for gid, title in refs.items())
        container = body or root
        ref_at = container.close if container and container.close is not None else len(page)
        page = page[:ref_at] + generated('<section id="fm-captain-goal-refs"><h2>Doelen van overige projecten</h2>'
                                         + cards + '</section>') + page[ref_at:]
    inline_forms = {key: ''.join(values) for key, values in forms.items()}
    return page[:at] + captain_section(truth, section_id, inline_forms) + ''.join(controls) + page[at:]


def heading_end(page, parsed):
    headings = [n for n in parsed.by_id['doelen'] if n.tag == 'h2' and n.visible and n.close is not None]
    if len(headings) != 1:
        raise ValueError('expected one visible cockpit goal heading <h2 id="doelen">')
    return page.index('>', headings[0].close) + 1


def goal_cards(parsed, goal):
    return [n for n in parsed.by_id['doel-' + goal['id']] if n.tag in ('article', 'div', 'section')]


def is_slot(node):
    return (node.tag in ('span', 'text') and node.close is not None
            and 'fm-goal-item-status' in node.classes)


def slot_patches(node, state):
    return [(node.end - 1, f' data-fm-goal-status="{state}"'), (node.end, generated(STATUSES[state][0]))]


WBS_IDS = {'wbs-blok', 'wbs'}


def wbs_box(node):
    return (node.tag == 'g' and 'data-id' in node.attrs) or 'fm-goal-box' in node.classes


def kanban_card(node):
    return 'kb-card' in node.classes


def slot_view(node):
    if not is_slot(node) or not node.visible:
        return None, None
    box = node.ancestor(wbs_box)
    if box and box.ancestor(lambda n: n.id in WBS_IDS):
        return 'WBS box', box
    card = node.ancestor(kanban_card)
    if card and card.ancestor(lambda n: n.id == 'kanban'):
        return 'Kanban card', card
    if node.parent and node.parent.tag == 'li':
        goal = node.ancestor(lambda n: 'data-fm-goal-drive' in n.attrs)
        if goal and goal.id == 'doel-' + (node.key or '').partition('/')[0]:
            return 'goal item', node.parent
    return None, None


def item_keys(goals):
    return {f"{g['id']}/{i['id']}": i for g in goals for i in g['items']}


def label_slot(key, state):
    return (f'<span class="fm-goal-item-status" data-fm-goal-item="{html.escape(key, quote=True)}"'
            f' data-fm-goal-status="{state}">{STATUSES[state][0]}</span>')


def ring_id(goal):
    return 'doel-ring-' + goal['id']


def steps_id(goal):
    return 'fm-goal-steps-' + goal['id']


def goal_item_title(item):
    override = item.get('goal_item_title')
    return (override.strip() if isinstance(override, str) else '') or item['title'].partition(' - ')[0].strip()


def goal_steps(goal, ring):
    gid, items = goal['id'], goal['items']
    rows = ''.join(f'<li>{html.escape(goal_item_title(i))} {label_slot(gid + "/" + i["id"], i["status"])}</li>'
                   for i in items)
    return (f'<details class="fm-goal-steps" id="{steps_id(goal)}">'
            f'<summary class="small mute">Alle stappen ({len(items)})</summary>'
            f'{ring}<ul>{rows}</ul></details>')


def render_truth(page, goals, budget_lines=None):
    base = base_page(page)
    parsed = GoalPage(base)
    if not parsed.by_id['doelen'] and not goals:
        return base
    heading_at = heading_end(base, parsed)
    items = item_keys(goals)
    patches, covered, wbs_keys = [], defaultdict(set), {}
    for node in parsed.nodes:
        if not node.key or not is_slot(node):
            continue
        view, box = slot_view(node)
        if view == 'WBS box' and box.attrs.get('data-id'):
            wbs_keys[box.attrs['data-id']] = node.key
        if node.key in items:
            state = items[node.key]['status']
            patches.extend(slot_patches(node, state))
            covered[view].add(node.key)
    # Rich cards can inherit identity from their linked SVG box, never from title or release stage.
    keyed_cards = {node.ancestor(kanban_card) for node in parsed.nodes if node.key}
    for card in parsed.nodes:
        key = wbs_keys.get(card.attrs.get('data-wbs'))
        if (key in items and kanban_card(card) and card not in keyed_cards and card.visible
                and card.ancestor(lambda n: n.id == 'kanban')):
            patches.append((card.end, generated(label_slot(key, items[key]['status']))))
            covered['Kanban card'].add(key)

    overview = STYLE + goal_kpis(goals) + budget_strip(budget_lines) + drive_kpi(goals) + items_kpi([i['status'] for i in items.values()])
    for goal in goals:
        gid = goal['id']
        controls = drive_switch(goal) + pace_marker(goal, card=True)
        steps = goal_steps(goal, items_kpi([i['status'] for i in goal['items']], ring_id(goal)))
        drive = 'on' if goal['driven'] else 'off'
        cards = goal_cards(parsed, goal)
        if cards:
            card = cards[0]
            if card.close is None:
                raise ValueError(f'expected a closed cockpit card #doel-{gid}')
            # The switch stays first, even if the host card is empty and both offsets coincide.
            patches.extend([(card.close, generated(steps)), (card.end - 1, f' data-fm-goal-drive="{drive}"'),
                            (card.end, generated(controls))])
        else:
            done_when = html.escape(goal.get('done_when', ''))
            completion = f'<p class="small mute">{done_when}</p>' if done_when else ''
            overview += (f'<article id="doel-{gid}" data-fm-goal-drive="{drive}">'
                         f'<h3>{html.escape(goal["title"])}</h3>{completion}{controls}{steps}</article>')

    for view, ids, css, heading in [('WBS box', ('wbs-blok', 'wbs'), 'fm-goal-box', 'WBS'),
                                    ('Kanban card', ('kanban',), 'kb-card fm-goal-box', 'Kanban')]:
        missing = {key: i for key, i in items.items() if key not in covered[view]}
        if not missing:
            continue
        groups = defaultdict(list)
        for key, item in missing.items():
            group = item['status'] if view == 'Kanban card' else key.split('/', 1)[0]
            groups[group].append(f'<div class="{css}">{html.escape(item["title"])} '
                                 f'{label_slot(key, item["status"])}</div>')
        titles = {g['id']: g['title'] for g in goals}
        titles = {k: v[0] for k, v in STATUSES.items()} if view == 'Kanban card' else titles
        content = '<h3>Geverifieerde doeltaken</h3>' + ''.join(
            f'<h4>{html.escape(titles[group])}</h4>{"".join(cards)}' for group, cards in groups.items())
        sections = [n for ident in ids for n in parsed.by_id[ident] if n.visible and n.close is not None]
        if sections:
            patches.append((sections[0].close, generated(content)))
        else:
            overview += f'<section id="{ids[0]}"><h2>{heading}</h2>{content}</section>'
    patches.append((heading_at, generated(overview)))
    return apply_patches(base, patches)


def verify_goal_views(page, goals, budget_lines=None):
    parsed = GoalPage(page)
    items = item_keys(goals)
    problems, covered = [], Counter()
    expected_cards = {f'doel-{g["id"]}' for g in goals}
    expected_rings = {ring_id(g) for g in goals}
    expected_steps = {steps_id(g) for g in goals}
    expected_pace = {f'fm-goal-pace-{g["id"]}' for g in goals if g['driven'] and g.get('pace') is not None}
    for node in parsed.nodes:
        if 'data-fm-goal-drive' in node.attrs and node.id not in expected_cards:
            problems.append(f'out-of-scope goal card: {node.id}')
        if node.id and node.id.startswith('doel-ring-') and node.id not in expected_rings:
            problems.append(f'out-of-scope goal ring: {node.id}')
        if node.id and node.id.startswith('fm-goal-steps-') and node.id not in expected_steps:
            problems.append(f'out-of-scope goal steps: {node.id}')
        if node.id and node.id.startswith('fm-goal-pace-') and node.id not in expected_pace:
            problems.append(f'unexpected pace marker: {node.id}')

    def settled(signature):
        # Pace is a clock sample: its marker must be there, its numbers are newer in every truth.
        tag, attrs, parts = signature
        if 'fm-goal-pace' in (attrs.get('class') or '').split():
            return tag, {'class': 'fm-goal-pace'} | ({'id': attrs['id']} if 'id' in attrs else {}), []
        return tag, attrs, [part if isinstance(part, str) else settled(part) for part in parts]

    def check_markup(expected, parent=None):
        model = GoalPage(expected).nodes[0]
        found = parsed.by_id[model.id]
        if (len(found) != 1 or not found[0].visible or settled(found[0].signature()) != settled(model.signature())
                or (parent and not found[0].ancestor(lambda n: n is parent))):
            problems.append(f'missing or stale goal rendering: {model.id}')

    # A truth without budget_lines predates the strip: nothing is asked of its page.
    if budget_lines:
        if goals or parsed.by_id['doelen']:
            check_markup(budget_strip(budget_lines))
    elif budget_lines is not None and parsed.by_id['fm-budget-lines']:
        problems.append('out-of-scope budget lines')
    if goals:
        check_markup(goal_kpis(goals))
    elif parsed.by_id['fm-goal-kpis']:
        problems.append('out-of-scope goal KPI lines')
    if goals or parsed.by_id['doelen'] or parsed.by_id['doel-item-kpi']:
        check_markup(drive_kpi(goals))
        check_markup(items_kpi([i['status'] for i in items.values()]))
    for goal in goals:
        card_id = f'doel-{goal["id"]}'
        cards = goal_cards(parsed, goal)
        drive = 'on' if goal['driven'] else 'off'
        if (len(parsed.by_id[card_id]) != 1 or len(cards) != 1 or not cards[0].visible
                or cards[0].attrs.get('data-fm-goal-drive') != drive):
            problems.append(f'missing or stale goal card: {card_id}')
        else:
            card = cards[0]
            pace = pace_marker(goal, card=True)
            if pace:
                check_markup(pace, card)
            ring = items_kpi([i['status'] for i in goal['items']], ring_id(goal))
            check_markup(ring, card)
            check_markup(goal_steps(goal, ring), card)
            switch = GoalPage(drive_switch(goal)).nodes[0].signature()
            switches = [n.signature() for n in parsed.nodes if 'fm-goal-drive' in n.classes
                        and n.visible and n.ancestor(lambda parent: parent is card)]
            if switches != [switch]:
                problems.append(f'missing or stale goal switch: {card_id}')

    box_keys = defaultdict(set)
    for node in parsed.nodes:
        if node.key is None:
            continue
        if node.key not in items:
            problems.append(f'out-of-scope or unknown goal item: {node.key}')
            continue
        view, box = slot_view(node)
        stated = node.attrs.get('data-fm-goal-status')
        expected = items[node.key]['status']
        if stated != expected or node.text().strip() != STATUSES[expected][0]:
            problems.append(f'stale status of {node.key}: expected {STATUSES[expected][0]} ({expected})')
        if view:
            covered[view, node.key] += 1
            box_keys[box].add(node.key)
    wbs_keys = defaultdict(set)
    for box, keys in box_keys.items():
        if wbs_box(box) and box.attrs.get('data-id'):
            wbs_keys[box.attrs['data-id']].update(keys)
        if len(keys) != 1:
            problems.append(f'goal rendering has multiple item keys: {", ".join(sorted(keys))}')
    for node in parsed.nodes:
        linked = wbs_keys.get(node.attrs.get('data-wbs'))
        if linked and kanban_card(node) and node.visible and (len(linked) != 1 or box_keys.get(node) != linked):
            problems.append(f'Kanban card does not match WBS box {node.attrs["data-wbs"]}')
    for key in items:
        for view in ('goal item', 'WBS box', 'Kanban card'):
            if not covered[view, key]:
                problems.append(f'missing {view}: {key}')
        if covered['goal item', key] > 1:
            problems.append(f'goal item listed more than once: {key}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--goal-home', type=Path, help='goal-record home for a standalone preview (not read with --truth)')
    parser.add_argument('--goal-id', action='append',
                        help='limit preview to this ID; with --truth only asserts its goals are allowed (repeatable)')
    parser.add_argument('--page', type=Path, required=True, help='already generated cockpit HTML; updated atomically')
    parser.add_argument('--output', type=Path, help='write a preview instead of changing --page')
    parser.add_argument('--truth', type=Path, help='scoped cockpit-sync.py truth JSON; generates section 1 and the goal views')
    args = parser.parse_args()
    if not (args.truth or args.goal_home):
        parser.error('--truth or --goal-home is required')
    target = args.output or args.page
    try:
        page = args.page.read_text(encoding='utf-8')
        if args.truth:
            truth = json.loads(args.truth.read_text(encoding='utf-8'))
            if truth['schema'] != TRUTH_SCHEMA:
                raise ValueError('unsupported cockpit truth schema')
            if args.goal_id and {g['id'] for g in truth['goals']} - set(args.goal_id):
                raise ValueError('truth contains goals outside --goal-id; select goals in cockpit-sync.py')
            updated = render_captain_steps(render_truth(page, truth['goals'], truth.get('budget_lines')), truth)
        else:
            updated = render_preview(page, goals_from(args.goal_home), args.goal_id)
        if target == args.page and updated == page:
            return
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=target.parent, delete=False) as f:
            pending = Path(f.name)
            try:
                f.write(updated)
                f.flush()
                pending.chmod(stat.S_IMODE(args.page.stat().st_mode))
                pending.replace(target)
            finally:
                pending.unlink(missing_ok=True)
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'goal-drive: {exc}\n')


if __name__ == '__main__':
    main()
