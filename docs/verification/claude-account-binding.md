# Claude account binding and release shaping verification

Audience: maintainer verification.

This record supports two current guarantees and is what must be re-established when their inputs change:

- One firstmate home is bound to one terminal session and one Claude account, and every fleet mutation from another session is refused (`bin/fm-home-identity.sh`, `docs/configuration.md` "Home session and account pin").
- Firstmate's own Claude launches onto a shaped credential store are paced at a limit-reset edge, and that store's committed parked demand is measurable (`bin/fm-claude-admission.sh`, `docs/configuration.md` "Claude release shaping").

It records empirical facts only.
Credential paths are shown with the home directory replaced by `<home>`, and no credential value appears here or in any output the tooling produces.

## Claude Code transcript shape the census depends on

Verified 2026-09-02 against Claude Code transcripts under `<home>/.claude-<account>/projects/*/*.jsonl`.

The committed-demand census reads three record shapes and nothing else.
A vendor change to any of them is what invalidates this record.

| Record | Fields read | Meaning |
| --- | --- | --- |
| `type=system`, `subtype=informational`, `level=notice` | `content`, `timestamp`, `sessionId` | The park and resume notices below |
| `type=assistant` | `message.model`, `message.id`, `message.usage` | A real turn; `model` `<synthetic>` is local and not billed |
| `type=continued-in` | position only | The session was forked onward, so its park is not live |

Exact `content` prefixes observed, and how each is classified:

```
Usage limit reached · continuing automatically at 8:20pm · esc or type to cancel      -> park
Usage limit reached again after you continued · continuing automatically ...          -> park
Usage limit reset · continuing automatically                                          -> resume
```

The classifier anchors on the `Usage limit reached` prefix together with the `continuing automatically` marker for a park, and on the `Usage limit reset` prefix for a resume.
Agent-written status prose in the same transcripts also contains the words "session limit"; that prose is deliberately not matched, because only a `type=system` notice record is read.

Billable input per turn is `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` from `message.usage`.
Turns are deduplicated by `message.id`, because a resumed transcript replays prior assistant messages and a naive count doubles them.

A session counts as live committed demand only when its park is the last decisive record in the file, no resume, real turn, or `continued-in` follows it, and the park is no older than `FM_CLAUDE_DEMAND_MAX_AGE`.

## Executable coverage

| Guarantee | Test |
| --- | --- |
| A reset-edge herd is staggered one release per interval, highest priority first | `tests/fm-claude-admission.test.sh` |
| A second release inside one slot is withheld and stays durable across processes | `tests/fm-claude-admission.test.sh` |
| Parked demand paces only the store the home lists | `tests/fm-claude-admission.test.sh` |
| An unshaped store's spawn is byte-for-byte unchanged | `tests/fm-claude-admission.test.sh` |
| Malformed or unreadable evidence refuses without losing work | `tests/fm-claude-admission.test.sh` |
| A home refuses the other session in both directions, and survives a restart | `tests/fm-home-identity.test.sh` |
| A spawn from a foreign session is refused and creates nothing | `tests/fm-home-identity.test.sh` |
| A worker records and launches on its home's account | `tests/fm-home-identity.test.sh` |
| A relaunch keeps the task's own recorded account, in both directions | `tests/fm-control-relaunch.test.sh` |
| A relaunch that is not released yet refuses before the agent is stopped | `tests/fm-control-relaunch.test.sh` |

Run them with `bin/fm-test-run.sh tests/fm-claude-admission.test.sh tests/fm-home-identity.test.sh tests/fm-control-relaunch.test.sh`.

## Live Herdr end-to-end

The portable tests above use a fake terminal, so the release decision is additionally exercised against a real Herdr session and a real `fm-spawn.sh`.
That run uses an isolated named lab session through `bin/fm-herdr-lab.sh` and a throwaway credential store, never the captain's `default` session and never a real quota reset or account exhaustion.

Refresh it with the procedure below and update the dated result.

```
HERDR_LAB_HELPER=<repo>/bin/fm-herdr-lab.sh
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name claude-admission)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
# one shaped store with a synthetic parked session, then two spawns:
# the first is released and creates a tab, worktree, and task record;
# the second is withheld and creates none of them.
```

Not yet recorded on this host.
As of 2026-09-02 the lab helper refuses to provision here, because its fleet-state tripwire requires exactly one RUNNING `default` Herdr session and this host runs none: `herdr 0.8.0` reports `default` present but `running: false`, alongside two running named sessions.
That refusal is the tripwire working as designed and is never bypassed, so the live run is pending an operator starting the default session; the portable coverage above stands in the meantime and exercises the same decision against a fake terminal.
