# Live run of the pull request timeline (test round 2, commit 1793e2c)

Everything below ran against the real scripts in a disposable lab home (`bin/fm-lab-home.sh create`), with the machine's own `gh` and `az` logins, read-only.
The board was served from the lab's `data/live-board` over local HTTP and driven in headless Chrome with real pointer and keyboard input.
Azure DevOps sources were read live too; their pull request titles and summaries are private work data and are left out of this file and of every screenshot.

## 1. The collector reads real forges (`bin/fm-live-board-prs.sh --json`, 10 seconds)

| project | forge | status | reason | pull requests |
| --- | --- | --- | --- | --- |
| firstmate (doitdigital0495/firstmate) | github | ok | - | 50 |
| cli (cli/cli, heavy CI) | github | ok | - | 15 |
| uv (astral-sh/uv, heavy CI) | github | ok | - | 15 |
| zed (zed-industries/zed, heavy CI) | github | ok | - | 15 |
| ripgrep (BurntSushi/ripgrep) | github | ok | - | 50 |
| three Azure DevOps repositories | ado | ok | - | 2, 27 and 200 |
| ghost (repository does not exist) | github | failed | fetch-failed | 0 |
| elsewhere (gitlab.com remote) | none | none | unsupported-forge | 0 |
| missing (no clone) | none | none | no-clone | 0 |
| offline (local-only) | none | none | local-only | 0 |

Round 1 failed here: cli, uv and zed came back `failed` because GitHub rejects the 50-pull-request query.
They now come back `ok` with the 15 newest, the number the timeline shows.

## 2. The outcome on the board matches the forge's own answer

cli/cli pull request 14620, read independently with `gh api repos/cli/cli/actions/runs?head_sha=<merge commit>`:

```
Triage Scheduled Tasks  schedule       success
Triage Scheduled Tasks  issue_comment  success
Lint                    push           failure
Code Scanning           push           success
Unit and Integration Tests  push       success
```

The board says: "Runs after merge failed - Lint - failed / Code Scanning - succeeded / Unit and Integration Tests - succeeded" (timer runs left out, as documented).

firstmate pull request 52: GitHub says `CI push success`, the board says "Runs after merge succeeded - CI - succeeded".
firstmate pull request 58: GitHub lists no run on the merge commit, the board says "No run after merge for this change".

Azure DevOps pull request 1337, read independently with `az pipelines runs list` filtered on its merge commit: `infra-deploy failed`, `reports-deploy`, `functions-deploy` and `docs-deploy succeeded`.
The board says: "Runs after merge failed - infra-deploy - failed / docs-deploy - succeeded / functions-deploy - succeeded / reports-deploy - succeeded / Open this pull request on Azure DevOps".

## 3. Pointing, pressing and the keyboard

```
hover pull request 48      -> detail shows, nothing pinned, no link
  Runs after merge succeeded / Merged - 2 Oct / Stamp task milestones, gate promptly and report review coverage /
  <plain summary> / Runs after merge: Every run this change's merge started finished well. / CI - succeeded /
  Press it to keep this open and get its link.
click pull request 60      -> pinned=https://github.com/doitdigital0495/firstmate/pull/60, pressed=1,
  "Not merged yet / Open - 10 Oct / ... / Open this pull request on GitHub / Close"
hover 48 while 60 pinned   -> shows 48 while pointed at, returns to pinned 60 afterwards
click cli 14620            -> second project pins its own; the first project's pin stays
click pinned 60 again      -> unpinned
Close button               -> unpinned
Tab to a pull request      -> its detail shows on focus
Enter                      -> pinned with link; Enter again -> unpinned
```

Browser console: no errors.

## 4. Sources that could not be read are named, never called empty

```
elsewhere: Pull requests for elsewhere could not be read: its repository is kept somewhere the board cannot read.
ghost:     Pull requests for ghost could not be read: the read failed or took too long.
missing:   Pull requests for missing could not be read: this home has no copy of its repository.
offline (local-only, has no forge): No pull requests were found for this project.
```

With every `gh` hidden from PATH, all six GitHub projects read:
"Pull requests for <name> could not be read: the tool that reads GitHub is not installed on this machine."
"No pull requests were found" appeared only for the local-only project.

## 5. The watcher's entry point (`bin/fm-live-board.sh refresh`)

```
refresh on a fresh board                 -> board untouched
refresh on a 5-minute-old board          -> board rebuilt, pull request cache untouched (read is paced at 600 s)
refresh with an 11-minute-old read stamp -> GitHub read again, timelines recovered from the no-tool state
refresh log                              -> empty
```

## 6. Where the pull request data lives

```
state/.live-board-prs.json  mode 600
data/live-board/            board.html only
GET /prs.json beside the served board -> 404
raw description fields in the page payload -> 0
```
