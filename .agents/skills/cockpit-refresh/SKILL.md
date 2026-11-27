---
name: cockpit-refresh
description: >-
  Load before refreshing, changing, or verifying a cockpit page (Miko or Geris), before wiring or editing a page's refresh button, or when the captain says a page is stale, wrong, or missing one of his questions or to-dos.
user-invocable: false
metadata:
  internal: true
---

# cockpit-refresh

This skill owns the rules and the step order of a cockpit refresh.
`tools/cockpit/cockpit-sync.py --help` owns the commands, flags, environment variables, truth-JSON shape, and page contract.
`tools/cockpit/README.md` owns the tool inventory and each host tool's paths.

## The button contract

Every refresh of every cockpit page, whether from the captain's "Ververs alles" button, a timer, or by hand, runs this package.
Never rebuild or hand-edit a page around it, and never answer a refresh click with only a partial pass.
The order is fixed:

1. Sync: run `tools/cockpit/cockpit-sync.sh` with the page's own scope and `--page <live page>`.
2. Stop if it fails: the live page now carries the failure banner, and nothing else is published.
   Tell the captain the refresh failed and why.
3. Build the page to a scratch file from the truth JSON of step 1.
   Item statuses come from `goals[]`, never from the raw goal marks.
   Leave the captain cards to the shared renderer, never to host markup or memory.
4. Run the shared drive pass with that same truth file, not a second goal export; it builds the fixed first section and the goal views.
5. Verify the scratch page with `cockpit-sync.sh --verify-page`, which rejects stale goal views and violations of the fixed first-section contract.
6. Publish only when step 5 reports no problem.
   Otherwise keep the old page and mark it with `--banner-only`.
7. Route the findings: report every `MISMATCH` line to the owner of the record.

A page host may add its own sources and layout between steps 3 and 4, but may not drop, reorder, or soften a step.

## What a refresh must get right

- Every item of every goal on the page is re-checked each time: pull request state from the forge, the live task state, and the goal mark.
- A status taken from a message is shown only after it is checked against the forge, the worker, or the deployment.
- Every goal item, including dropped items, appears consistently in its goal list, WBS box and keyed Kanban card, and counts in both rings.
- Any popup about an item shows the same verified status.
- "Live for customers" means deployed: the version production actually serves, not only merged on main.
- Every active worker is on the board.
- A coloured status never carries text saying it is not happening now, and nothing shows as running while something before it is still open.
- Section 1 comes before all other page content and contains only the captain's open Vraag and Taak cards, in `must`, `can`, `later` order.
- Do not copy a card elsewhere, omit a later item, or keep one after it is answered.
- Work that belongs to no cockpit appears only on the page whose scope also names `main`, labelled "Overige projecten" inside the applicable priority bucket.
- Supply all fields at record creation; `bin/fm-captain-hold.sh --help` and `bin/fm-goal.sh --help` own the input formats.
- Two refreshes in a row make zero differences when the world did not change.

## Miko page working rules

- Until the captain says Miko goes live for customers, security repairs run alongside and block nothing.
- The hourly firstmate timer and the captain's refresh button run the same pass.

## Mismatches

A mismatch is a finding, not a page failure.
An `unrouted-decision-key` line is an open worker or secondmate question that is not on the captain's list: firstmate holds it through `captain-hold-lifecycle` when it is his, or answers and resolves it.
The page shows the verified status; the goal record stays the record owner's to mark through `bin/fm-goal.sh` (see `drive-goal`).
A `stale-decision-key` line means a status log still holds a key whose question is already answered: its writer appends the `resolved` line.
Use `cockpit-sync.sh --captain-waiting` to follow up on missing cockpit entries; route a real question not covered by a goal step through `captain-hold-lifecycle`, never by typing it into the page.
An `incomplete-captain-card` finding leaves the existing card visible with an explicit `ONTBREEKT` marker; the record owner adds the missing information rather than making it up in the page.

## Improving the package

When a refresh missed something or showed something stale:

1. Reproduce it as a case in `tests/cockpit-tools.test.sh` on the synthetic goal home and page, and see it fail.
2. Add the check in `tools/cockpit/cockpit-sync.py`: a flag in `verify_item` for item truth, a source or rule in `captain_list` for the decisions section, or a rule in `verify_page` for the built page.
3. Update the script's `--help` when a field, flag, or page rule changes, and this skill only when a rule or the step order changes.
4. Run `bin/fm-lint.sh` and the cockpit test, then ship it as an ordinary firstmate change.

Fix the package, never one page by hand, so the same miss cannot return on the other cockpit.
