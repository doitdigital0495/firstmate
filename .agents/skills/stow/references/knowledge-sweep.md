# stow: knowledge sweep

Reference of the `stow` skill, loaded on demand from its `SKILL.md` table; the always-resident rules stay in that `SKILL.md`.

## Knowledge sweep and routing

1. **Sweep the session for uncaptured durable knowledge.**
   Look for operational learnings, captain preferences expressed in passing, project-intrinsic facts, standing decisions, and undone next steps.
   Include what workers reported from harnesses that cannot reach a declared tier, because this session is their only capture path.
2. **Route each finding using AGENTS.md's knowledge-routing table.**
   AGENTS.md section 6 is the source of truth for destinations.
   Do not re-derive or duplicate that mapping here.
   Match each finding against the home's declared memory tiers first and capture a tier-owned finding to that tier, falling back to the local files only for classes no declared tier owns.
   When the owning tier is unreachable from this session, write the finding to the startup-loaded local memory file its class would otherwise use, or keep it where it already lives, carrying the pending-capture marker for that tier; it is still an exception for the receipt, never a reason to treat the local copy as sufficient.
3. **Write within the existing boundaries.**
   - Captain preferences and fleet-local operational facts belong in the destination selected by AGENTS.md after the required whole-file curation pass.
     Create `data/learnings.md` only for a genuinely new local learning with no stronger owner.
   - In a primary home, curate shared captain preferences only under the existing primary-authoritative shared-preference contract.
     In a secondmate home, route a newly discovered shared preference to the main firstmate through marked status or a document pointer instead of editing the inherited file.
   - Project-intrinsic knowledge never goes into a project's `AGENTS.md` through this fleet: a crewmate edits those files only to correct factually wrong information (AGENTS.md section 6), so no ship task carries an addition.
     Keep the candidate in `data/learnings.md` or surface it in the completion receipt so the captain can extend the file by hand.
   - Knowledge general to every Firstmate user belongs in this repo's shared tracked material through the normal branch, no-mistakes, PR, and captain-merge path, which exists only under this home's firstmate-repository publication authority (`AGENTS.md` section 1's role boundary).
     A user/operator home instead keeps the lesson in `data/learnings.md` and may leave a sanitized local draft for the captain to carry upstream.
   - For task-scoped notes, inspect the item with `bin/fm-tasks-axi.sh show <id> --full`, classify the change as new, duplicate, superseding, or obsolete, then use a considered replacement body through `bin/fm-tasks-axi.sh update <id> --body-file <path>`.
     Use `--archive-body` when recoverability matters.
     Never append.
   - File each undone next step as a queued backlog item with a genuine `blocked-by` dependency when applicable.
4. **Use inspect-then-update.**
   For every retained fact, ask which current statement it supersedes, whether it can be a one-sentence rewrite, and whether a stale entry should be refreshed, archived, or routed to an existing stronger owner.
   The only graduation moves are promotion to tracked shared material through a PR, folding a learning into the captain-preference destination selected by AGENTS.md, archiving a stale entry to `data/memory-archive.md`, autonomous offload of an eligible non-pinned conditional entry to an already-existing allowed owner through the reduce flow above, captain-approved offload of a pinned durable conditional entry to a JIT-loaded owner executed through the migration step above, or deletion of an entry that is a duplicate or already preserved through a stronger existing owner.
   A stale unique fact is never deleted, only archived.
   Do not invent another graduation path.

## Open-record persistence

The sweep above preserves knowledge; this one preserves the state of work.
A reset destroys whatever exists only in this session, and that includes what you have learned about work already under way, not just facts worth remembering.
So before the reset, make sure the important open work you are holding in context is durably recorded: file what was never filed, and correct what you now know is stale.

Judge for yourself what is important and which record each thing belongs to, and write it through the owner that already governs that record.
One bound holds: this covers the open work you are actually holding in context, not the records at large.
It is not a reconciliation of durable records against repository or forge reality, cannot become one on input this volatile, and must never be reported as one.
Where the right correction is a judgment you cannot make, leave the record alone and raise the question instead of guessing.
