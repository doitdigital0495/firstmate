# Live board Workers section - what was driven

Fixture: a throwaway firstmate home and one registered second mate home, built by `drive-fixture.sh`.
The page was built by the real `bin/fm-live-board.sh build` and opened in headless Chrome through `chrome-devtools-axi`.
Every result below was read from the page in the browser after real clicks.

## Page 1: `board.html` from `fm-live-board.sh build`

Resolved states the collector reported for the main home:

```
c-doing     working  pane        harness busy (claude-hook)
w-ask       parked   status-log  which courier should we use for the launch
w-doing     working  pane        harness busy (claude-hook)
w-finished  done     status-log  product page tidied and checked on a phone
w-lost      unknown  none        no current-state source available
w-merge     working  pane        harness busy (claude-hook)
w-paused    paused   status-log  waiting for the supplier to publish their release
w-stuck     blocked  status-log  the payment sandbox keeps refusing our test card
w-val       working  pane        harness busy (claude-hook)
```

Workers section on load, 1280 px (`01-workers-all-desktop.png`):

```
Workers 11
The workers of second mate Lost desk are not shown: its registration could not be checked.
All 11 | 5 working | 1 waiting on you | 1 paused on an outside wait | 2 finished and idle | 2 stuck or stopped
Webshop 6:    Stuck or stopped x2, Finished and idle, Waiting on you, Paused on an outside wait, Working
Help desk (Second mate: Ai desk) 2:  Finished and idle (with pull request link), Working (Investigation)
Claims portal 3:  Working x3
```

Press "2 stuck or stopped" (`02-filter-stuck-desktop.png`):

```
pressed: 2 stuck or stopped
summary: 2 stuck or stopped, by project
groups:  Webshop 2
rows:    Fix the payment error; Speed up search
```

Press it again: pressed is "All 11" and all 11 rows show.

Press "2 finished and idle":

```
summary: 2 finished and idle, by project
groups:  Webshop 1; Help desk Second mate: Ai desk 1
rows:    Tidy the product page; Wrap up the desk report (pull request)
```

Press "All 11", then press four rows (`03-rows-open-desktop.png`):

```
Speed up search                 -> Its current state could not be read.
Tidy the product page           -> It is done and can be cleaned up. Last report: product page tidied and checked on a phone
Set up the courier integration  -> It asked for a decision before it can go on. Last report: which courier should we use for the launch
Wait for the supplier release   -> It paused itself until something outside the team is ready. Last report: waiting for the supplier to publish their release
```

Phone width 390 px, fresh load (`04-phone-folded.png`): six counts show, the list is folded, no row shows, no sideways scroll.
Press "1 waiting on you" (`05-phone-filter-you.png`): the list opens on the one row "Set up the courier integration".

No task id, state-source label, home path or worktree name appears in the section text.

## Page 2: `board-run-states.html` (`06-all-seven-statuses-desktop.png`)

"Waiting for validation" and "Waiting for a merge or CI" are read from a real no-mistakes run, which a throwaway home cannot hold.
`drive-run-states.sh` took the board input the real collector produced, set the resolved state of two workers to `working / run-step / validating (running)` and `done / run-step / checks green: PR ready for review (still monitoring for merge/close)`, and ran the real snapshot, view and template.
The state resolver itself (`bin/fm-crew-state.sh`) is not part of this change and was not driven for these two workers.

```
All 11 | 3 working | 1 waiting for validation | 1 waiting for a merge or CI | 1 waiting on you |
1 paused on an outside wait | 2 finished and idle | 2 stuck or stopped
Add the claim form              -> Waiting for validation: Its work is being reviewed and checked automatically.
Export claims to a spreadsheet  -> Waiting for a merge or CI: Its pull request is ready and waits to be merged.
```
