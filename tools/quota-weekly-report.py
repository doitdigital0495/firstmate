#!/usr/bin/env python3
"""Weekly Claude Code usage report for a firstmate host. Read-only, stdlib only.

Built from the scan and leak-metric scripts of the 2026-11-12 quota usage
analysis (claude_scan.py, common.py, a3.py), folded into one self-contained tool
so a weekly run refreshes the same numbers with no agent involved.

What it reads: every `projects/**/*.jsonl` transcript under each Claude config
store (default: ~/.claude, ~/.claude-2, ~/.claude-3 and any other ~/.claude*
directory that has a `projects` folder) that was modified inside the two report
windows. It keeps ONLY usage fields, model, effort, cwd, git branch and boolean
command-shape flags. It never keeps, prints or writes message text.

What it prints (Markdown, to stdout or --out): for this window and the one before
it, estimated spend per seat, per model and per role, then the leak metrics the
analysis tracks: poll-loop and sleep-then-check turns, tiny turns at large
context (the secondmate wake overhead), multi-task sessions, compactions, and
the sleep-then-check flags the worker guard logged (state/<id>.wait-flags,
written by bin/fm-wait-pretool-check.sh).

Prices are an estimate: $/MTok input, 5m cache write, 1h cache write, cache read,
output. A model with no row is counted as unpriced, never guessed. Edit RATES
when prices change.

Usage:
  python3 -I tools/quota-weekly-report.py [--end ISO] [--days 7] [--home DIR]
                                         [--store DIR ...] [--jobs N] [--out FILE]

Scheduling (this repo never schedules it; the operator does). A weekly cron entry
on the host that owns the Claude stores, Mondays 06:00, writing a dated report
under the firstmate home's data directory:

  0 6 * * 1  python3 -I /path/to/firstmate/tools/quota-weekly-report.py --out "$HOME/.firstmate/data/quota-weekly/$(date +\\%F).md" >/dev/null 2>&1

Create the output directory once (`mkdir -p ~/.firstmate/data/quota-weekly`).
The run takes about 25 seconds for 12 GB of transcripts on 16 processes.
Read the report by opening the newest file; compare "this window" with "prior".
"""
import argparse
import collections
import glob
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from multiprocessing import Pool

# $/MTok: input, 5m write, 1h write, cache read, output. Estimates; fable-5-2 is
# priced on the fable-5-1 row. Haiku has a second tier above 100K prompt tokens.
RATES = {
    'opus-5-5': (4, 5, 8, .2, 20),
    'sonnet-5-5': (2, 2.5, 4, .1, 10),
    'fable-5-2': (10, 12.5, 20, .25, 50),
    'fable-5-1': (10, 12.5, 20, .25, 50),
}
HAIKU = ((.1, .125, .2, .01, .5), (.5, .625, 1, .05, 2.5))

# Command-shape flags. A "poll" is any waiting loop shape; a "sleep-check" is the
# costly subset: a bare `sleep N` outside a loop, whose result is read next turn.
POLL = re.compile(r'(^|[;&|\s(])sleep\s+\d|\buntil\b[^\n]*;\s*do\b|\bwhile\b[^\n]*;\s*do\b|--watch\b|no-mistakes (axi )?status|lavish-axi poll|--wait\b')
LOOP = re.compile(r'\b(until|while|for)\b[^\n]*;\s*do\b')
BARE_SLEEP = re.compile(r'(^|[;&|(\n])\s*sleep\s+(\d+)')
HEREDOC = re.compile(r"<<-?\s*'?\"?(\w+)'?\"?.*?\n.*?\n\1\b", re.S)
LAVISH = re.compile(r'fm-procevent-lavish\.sh|lavish-axi|fm-lavish-open\.sh')
TINY_OUT, TINY_CTX = 150, 100_000


def default_stores():
    out, seen = [], set()
    for d in sorted(glob.glob(os.path.expanduser('~/.claude*'))):
        real = os.path.realpath(d)
        if real not in seen and os.path.isdir(os.path.join(real, 'projects')):
            seen.add(real)
            out.append(d)
    return out


def sleep_check(cmd, min_secs=20):
    """True for a `sleep N` (N >= min_secs) outside any loop."""
    if LOOP.search(cmd):
        return False
    return any(int(m.group(2)) >= min_secs for m in BARE_SLEEP.finditer(cmd))


def scan(args):
    path, store, lo, end = args
    sub = '/subagents/' in path
    rows, compacts = {}, 0
    try:
        fh = open(path, errors='replace')
    except OSError:
        return rows, 0
    with fh:
        for line in fh:
            if '"compact_boundary"' in line:
                compacts += 1
            if '"assistant"' not in line or '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get('type') != 'assistant':
                continue
            m = d.get('message') or {}
            u = m.get('usage')
            model = m.get('model') or ''
            if not u or not model.startswith('claude'):
                continue
            try:
                ts = datetime.fromisoformat(d['timestamp'].replace('Z', '+00:00')).timestamp()
            except (KeyError, ValueError, AttributeError):
                continue
            if not lo <= ts < end:
                continue
            bash = ''
            for c in m.get('content') or []:
                if isinstance(c, dict) and c.get('type') == 'tool_use' and c.get('name') == 'Bash':
                    bash += ' ' + HEREDOC.sub('', (c.get('input') or {}).get('command', '') or '')
            cc = u.get('cache_creation') or {}
            w1 = cc.get('ephemeral_1h_input_tokens', 0) or 0
            w5 = max((u.get('cache_creation_input_tokens', 0) or 0) - w1, 0)
            key = '%s|%s' % (m.get('id'), d.get('requestId'))
            row = dict(
                ts=ts, store=store, sid=d.get('sessionId') or path, sub=sub,
                model=re.sub(r'^claude-|-\d{8}$', '', model), cwd=d.get('cwd') or '',
                branch=d.get('gitBranch') or '', i=u.get('input_tokens', 0) or 0, w1=w1, w5=w5,
                r=u.get('cache_read_input_tokens', 0) or 0, o=u.get('output_tokens', 0) or 0,
                poll=bool(bash and POLL.search(bash)), sleepcheck=sleep_check(bash),
                lav=bool(LAVISH.search(bash)))
            if key in rows:  # a later content block of the same response: merge flags only
                for f in ('poll', 'sleepcheck', 'lav'):
                    rows[key][f] |= row[f]
            else:
                rows[key] = row
    return rows, compacts


def transcripts(stores, lo):
    for store in stores:
        for dp, _, fns in os.walk(os.path.join(store, 'projects')):
            for fn in fns:
                p = os.path.join(dp, fn)
                try:
                    if fn.endswith('.jsonl') and os.path.getmtime(p) >= lo:
                        yield p, os.path.basename(store.rstrip('/')) or store
                except OSError:
                    continue


def price(r):
    p = r['i'] + r['w1'] + r['w5'] + r['r']
    rt = HAIKU[p > 100_000] if r['model'] == 'haiku-5-5' else RATES.get(r['model'])
    r['prompt'] = p
    if not rt:
        r['usd'], r['priced'] = 0.0, False
        return
    r['priced'] = True
    r['usd'] = (r['i'] * rt[0] + r['w5'] * rt[1] + r['w1'] * rt[2] + r['r'] * rt[3] + r['o'] * rt[4]) / 1e6


_secondmate_cache = {}


def is_secondmate_cwd(cwd):
    if cwd not in _secondmate_cache:
        _secondmate_cache[cwd] = bool(cwd) and os.path.exists(os.path.join(cwd, '.fm-secondmate-home'))
    return _secondmate_cache[cwd]


def classify(rows, home):
    lav = collections.Counter(r['sid'] for r in rows if r['lav'])
    home = os.path.realpath(home) if home else ''
    for r in rows:
        cwd = r['cwd'].rstrip('/')
        if '/.no-mistakes/' in cwd + '/':
            role = 'pipeline'
        elif r['sub']:
            role = 'subagent'
        elif is_secondmate_cwd(cwd):
            role = 'secondmate'
        elif home and os.path.realpath(cwd) == home:
            role = 'firstmate'
        elif r['branch'].startswith('fm/') or '/.treehouse/' in cwd:
            role = 'board host' if lav[r['sid']] >= 3 else 'worker'
        else:
            role = 'other'
        r['role'] = role


def usd_by(rows, keyf):
    a = collections.defaultdict(lambda: [0.0, 0, set()])
    for r in rows:
        v = a[keyf(r)]
        v[0] += r['usd']
        v[1] += 1
        v[2].add(r['sid'])
    return sorted(((k, v[0], v[1], len(v[2])) for k, v in a.items()), key=lambda x: -x[1])


def metrics(rows, compacts_by_sid):
    m = {}
    m['usd'] = sum(r['usd'] for r in rows)
    m['turns'] = len(rows)
    m['unpriced'] = sum(1 for r in rows if not r['priced'])
    for name, pred in (('worker poll loops', lambda r: r['role'] == 'worker' and r['poll']),
                       ('board host poll loops', lambda r: r['role'] == 'board host' and r['poll']),
                       ('sleep-then-check turns', lambda r: r['sleepcheck'] and r['role'] != 'secondmate'),
                       ('secondmate tiny turns', lambda r: r['role'] == 'secondmate' and r['o'] < TINY_OUT and r['prompt'] > TINY_CTX)):
        sel = [r for r in rows if pred(r)]
        m[name] = (len(sel), sum(r['usd'] for r in sel))
    branches = collections.defaultdict(set)
    for r in rows:
        if r['role'] in ('worker', 'board host') and r['branch'].startswith('fm/'):
            branches[r['sid']].add(r['branch'])
    multi = {sid for sid, b in branches.items() if len(b) >= 2}
    m['multi-task sessions'] = (len(multi), sum(r['usd'] for r in rows if r['sid'] in multi))
    m['compactions'] = sum(compacts_by_sid.get(sid, 0) for sid in {r['sid'] for r in rows})
    return m


def wait_flags(home, lo, end):
    """Sleep-then-check flags the worker guard logged: state/<id>.wait-flags lines '<epoch> <mode>'."""
    n, tasks = 0, 0
    for f in glob.glob(os.path.join(home, 'state', '*.wait-flags')) if home else []:
        hit = 0
        try:
            for line in open(f, errors='replace'):
                t = line.split(' ', 1)[0]
                if t.isdigit() and lo <= int(t) < end:
                    hit += 1
        except OSError:
            continue
        n += hit
        tasks += 1 if hit else 0
    return n, tasks


def render(end, days, stores, cur, prev, cm, pm, flags, pflags, scanned):
    f = lambda x: '$%.2f' % x
    out = ['# Weekly Claude usage report', '',
           'Window: %s to %s UTC (%d days); prior window: the %d days before.' % (
               (end - timedelta(days=days)).strftime('%Y-%m-%d %H:%M'), end.strftime('%Y-%m-%d %H:%M'), days, days),
           'Stores: %s. Transcripts read: %d. Costs are estimates from list prices.' % (', '.join(stores) or 'none', scanned), '']
    out += ['## Totals', '', '| | this window | prior |', '|---|---|---|',
            '| estimated spend | %s | %s |' % (f(cm['usd']), f(pm['usd'])),
            '| assistant turns | %d | %d |' % (cm['turns'], pm['turns']),
            '| unpriced turns (model has no rate) | %d | %d |' % (cm['unpriced'], pm['unpriced']), '']
    for title, keyf in (('By seat', lambda r: r['store']), ('By model', lambda r: r['model']), ('By role', lambda r: r['role'])):
        out += ['## ' + title, '', '| key | this window | turns | sessions |', '|---|---|---|---|']
        for k, usd, turns, sess in usd_by(cur, keyf)[:15]:
            out.append('| %s | %s | %d | %d |' % (k, f(usd), turns, sess))
        out.append('')
    out += ['## Leak metrics', '', '| metric | this window | cost | prior | cost |', '|---|---|---|---|---|']
    for name in ('worker poll loops', 'board host poll loops', 'sleep-then-check turns', 'secondmate tiny turns', 'multi-task sessions'):
        out.append('| %s | %d | %s | %d | %s |' % (name, cm[name][0], f(cm[name][1]), pm[name][0], f(pm[name][1])))
    out += ['| compactions | %d | | %d | |' % (cm['compactions'], pm['compactions']),
            '| guard sleep-then-check flags (tasks) | %d (%d) | | %d (%d) | |' % (flags[0], flags[1], pflags[0], pflags[1]), '']
    out += ['Poll loops are regex-detected, so a heuristic. Tiny turns are under %d output tokens at more than %dK context.' % (TINY_OUT, TINY_CTX // 1000),
            'A multi-task session carried two or more `fm/` branches; the fix is one task per worker.', '']
    return '\n'.join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    ap.add_argument('--end', help='window end, ISO 8601 (default: now, UTC)')
    ap.add_argument('--days', type=int, default=7)
    ap.add_argument('--home', default=os.environ.get('FM_HOME') or os.path.expanduser('~/.firstmate'))
    ap.add_argument('--store', action='append', help='Claude config dir (repeatable; default ~/.claude*)')
    ap.add_argument('--jobs', type=int, default=min(16, os.cpu_count() or 1))
    ap.add_argument('--out', help='write the report here instead of stdout')
    a = ap.parse_args(argv)
    end_dt = datetime.fromisoformat(a.end).astimezone(timezone.utc) if a.end else datetime.now(timezone.utc)
    if end_dt.tzinfo is None:
        end_dt = end_dt.replace(tzinfo=timezone.utc)
    end = end_dt.timestamp()
    split, lo = end - a.days * 86400, end - 2 * a.days * 86400
    stores = a.store or default_stores()
    work = sorted(transcripts(stores, lo), key=lambda x: -os.path.getsize(x[0]))
    jobs = [(p, s, lo, end) for p, s in work]
    seen, comp = {}, {}
    if a.jobs > 1 and len(jobs) > 1:
        with Pool(a.jobs) as pool:
            results = list(pool.imap_unordered(scan, jobs, chunksize=4))
    else:
        results = [scan(j) for j in jobs]
    for rows, c in results:
        for k, r in rows.items():
            if k in seen:
                for fl in ('poll', 'sleepcheck', 'lav'):
                    seen[k][fl] |= r[fl]
            else:
                seen[k] = r
        if rows and c:
            comp[next(iter(rows.values()))['sid']] = comp.get(next(iter(rows.values()))['sid'], 0) + c
    rows = list(seen.values())
    for r in rows:
        price(r)
    classify(rows, a.home)
    cur = [r for r in rows if r['ts'] >= split]
    prev = [r for r in rows if r['ts'] < split]
    report = render(end_dt, a.days, stores, cur, prev, metrics(cur, comp), metrics(prev, comp),
                    wait_flags(a.home, split, end), wait_flags(a.home, lo, split), len(work))
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, 'w') as fh:
            fh.write(report + '\n')
    else:
        print(report)
    return 0


if __name__ == '__main__':
    sys.exit(main())
