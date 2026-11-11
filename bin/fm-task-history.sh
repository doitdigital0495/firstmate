#!/usr/bin/env bash
# Append-only per-task routing history, independent of harness and backend.
# Usage: fm-task-history.sh append TASK EVENT [--reason CLASS] [--attempt ID]
#          [--event-id ID] [--profile JSON] [--meta-file PATH]
#        fm-task-history.sh read TASK
#        fm-task-history.sh summary TASK
# EVENT: relaunch | stall-escalation | launch-profile.
# CLASS: capability | infra | usage-limit | captain | unknown (default).
# Storage: FM_STATE_OVERRIDE, else ${FM_HOME:-repo}/state/<task>.history.jsonl.
# v1 records contain version, id, at (epoch), event, reason, attempt, receipt,
# and profile (only harness/model/effort/account/provider strings).
# Metadata defaults to <task>.meta; only those profile axes, busy_gen,
# control_relaunch_tx and dispatch_receipt are read. No notes or credentials.
# Attempt defaults to busy_gen, control_relaunch_tx, then "unknown"; callers
# with a receipt/attempt identity may pass --attempt explicitly.
# --event-id makes retries idempotent; reusing it for different data refuses.
# Without it a new UUID is assigned, so separate stalls remain separate events.
# stdout is JSON: append {appended,event}, read an array, summary an object with
# capability_failures (distinct known attempts whose relaunch reason is
# capability), failed_profiles (those attempts' profiles), last_outcomes (last
# three relaunch events), and stall_escalations. Stalls alone never prove a
# capability failure. Missing history is empty; malformed history fails closed.
# Writes and reads share a bounded advisory lock; writes fsync before success.
# Exit: 0 success, 2 usage/invalid data, 1 storage/lock failure.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export FM_HISTORY_STATE="${FM_STATE_OVERRIDE:-${FM_HOME:-${SCRIPT_DIR%/bin}}/state}"
exec python3 - "$@" <<'PY'
import argparse
import fcntl
import json
import os
import re
import stat
import sys
import time
import uuid

EVENTS = ('relaunch', 'stall-escalation', 'launch-profile')
REASONS = ('capability', 'infra', 'usage-limit', 'captain', 'unknown')
AXES = ('harness', 'model', 'effort', 'account', 'provider')
p = argparse.ArgumentParser(description='Append-only per-task routing history (JSON output).')
sub = p.add_subparsers(dest='command', required=True)
for command in ('append', 'read', 'summary'):
    q = sub.add_parser(command)
    q.add_argument('task')
    if command == 'append':
        q.add_argument('event', choices=EVENTS)
        q.add_argument('--reason', choices=REASONS, default='unknown')
        q.add_argument('--attempt')
        q.add_argument('--event-id')
        q.add_argument('--profile', type=json.loads)
        q.add_argument('--meta-file')
a = p.parse_args()
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', a.task) or '..' in a.task:
    p.error('invalid task id')
state = os.environ['FM_HISTORY_STATE']
path = os.path.join(state, a.task + '.history.jsonl')


def profile_valid(value):
    return (isinstance(value, dict) and set(value) <= set(AXES)
            and all(isinstance(v, str) for v in value.values()))


def valid(row):
    return (isinstance(row, dict) and row.get('version') == 1
            and row.get('event') in EVENTS and row.get('reason') in REASONS
            and type(row.get('at')) is int and row['at'] >= 0
            and all(isinstance(row.get(k), str) and row[k]
                    for k in ('id', 'attempt'))
            and isinstance(row.get('receipt'), str)
            and profile_valid(row.get('profile')))


def output(value):
    print(json.dumps(value, separators=(',', ':'), sort_keys=True))


try:
    if a.command != 'append' and not os.path.lexists(path):
        rows = []
    else:
        if a.command == 'append':
            os.makedirs(state, exist_ok=True)
        # O_NOFOLLOW refuses symlinks, including dangling ones. O_NONBLOCK
        # prevents a hostile FIFO from hanging before the regular-file check.
        flags = os.O_NOFOLLOW | os.O_NONBLOCK
        flags |= os.O_RDWR | os.O_CREAT | os.O_APPEND if a.command == 'append' else os.O_RDONLY
        fd = os.open(path, flags, 0o600)
        with os.fdopen(fd, 'a+' if a.command == 'append' else 'r') as ledger:
            if not stat.S_ISREG(os.fstat(ledger.fileno()).st_mode):
                raise ValueError('history is not a regular file')
            deadline = time.monotonic() + 5
            while True:
                try:
                    fcntl.flock(ledger, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise OSError('history lock timeout')
                    time.sleep(0.05)
            ledger.seek(0)
            rows = []
            for line in ledger:
                row = json.loads(line)
                if not line.endswith('\n') or not valid(row):
                    raise ValueError('invalid or incomplete history record')
                rows.append(row)
            if a.command == 'append':
                meta = {}
                meta_path = a.meta_file or os.path.join(state, a.task + '.meta')
                try:
                    with open(meta_path) as source:
                        for line in source:
                            key, sep, value = line.rstrip('\n').partition('=')
                            if sep and key in (*AXES, 'busy_gen', 'control_relaunch_tx', 'dispatch_receipt'):
                                meta[key] = value
                except FileNotFoundError:
                    pass
                profile = a.profile if a.profile is not None else {k: meta[k] for k in AXES if k in meta}
                if not profile_valid(profile):
                    raise ValueError('profile must contain only string routing axes')
                row = dict(version=1, id=a.event_id or str(uuid.uuid4()), at=int(time.time()),
                           event=a.event, reason=a.reason,
                           attempt=a.attempt or meta.get('busy_gen') or meta.get('control_relaunch_tx') or 'unknown',
                           receipt=meta.get('dispatch_receipt', ''), profile=profile)
                if not valid(row):
                    raise ValueError('invalid event')
                prior = next((r for r in rows if r['id'] == row['id']), None)
                if prior and any(prior[k] != row[k] for k in row if k != 'at'):
                    raise ValueError('event id already has different data')
                if not prior:
                    ledger.write(json.dumps(row, separators=(',', ':'), sort_keys=True) + '\n')
                    ledger.flush()
                    os.fsync(ledger.fileno())
                output(dict(appended=prior is None, event=prior or row))
    if a.command == 'read':
        output(rows)
    elif a.command == 'summary':
        failures = {}
        for r in rows:
            if r['event'] == 'relaunch' and r['reason'] == 'capability' and r['attempt'] != 'unknown':
                failures[r['attempt']] = r
        profiles = []
        for r in failures.values():
            if r['profile'] and r['profile'] not in profiles:
                profiles.append(r['profile'])
        output(dict(version=1, capability_failures=len(failures), failed_profiles=profiles,
                    last_outcomes=[r for r in rows if r['event'] == 'relaunch'][-3:],
                    stall_escalations=sum(r['event'] == 'stall-escalation' for r in rows)))
except (ValueError, TypeError) as exc:
    print('task-history: ' + str(exc), file=sys.stderr)
    sys.exit(2)
except OSError as exc:
    print('task-history: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
