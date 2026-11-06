# stow: over-budget offload

Reference of the `stow` skill, loaded on demand from its `SKILL.md` table; the always-resident rules stay in that `SKILL.md`.

## Over-budget offload to JIT-loaded owners

Decay handles staleness over time; offload handles scope: knowledge that is current and durable but relevant only in a nameable context, and therefore wrong to pay for in every session of every fleet member.
For the offload sweep's evaluation only, each entry has exactly three outcomes decided in this fixed order:

1. Archive, the time outcome, always evaluated first: staleness is judged before scope, and offload never moves a stale fact anywhere.
2. Offload, the scope outcome, asked only of current durable entries: is this needed in nearly every session, or only in a nameable context?
3. Keep, the default outcome for this sweep: current, durable, and either fleet-wide-relevant or safety-relevant even in sessions that never name the topic.

The offload sweep runs whenever the pass is still over budget after decay archiving and consolidation, so routine passes do not move entries speculatively.
It is an immediate reduction step for eligible non-pinned conditional material that can be added to an already-existing allowed owner, not a deferred proposal that leaves the pass over budget.
Every test must hold for a candidate:

- Editable source: this home owns the memory file and may relocate the entry; a read-only shared entry is routed to its primary owner instead.
- Durable: not `perishable`, not stale, and expected to remain true for months.
- Eligible by authority: only a non-pinned, dated `aging` entry that is not pending offload or pending capture may be autonomously relocated to an already-existing allowed owner, while a `pinned` entry may be proposed only for explicit, per-item captain-approved relocation and can never be archived or autonomously offloaded for budget relief.
- Conditional: a one-line nameable trigger exists, and a session that never touches that trigger runs no risk from omitting the fact.
- Fat enough to matter: roughly 50 estimated tokens or more, handled largest-first, because consolidation handles smaller entries.
- A destination below fits the entry's privacy and visibility.
- Not already preserved by a stronger owner, which the consolidation counterweight already handles as ordinary curation rather than offload.

### Destinations

The destinations hard rule stays in `SKILL.md` under "Rules that hold without a reference loaded"; every destination below is bound by it.

- A user-owned local skill: a directory under `.agents/skills/<freeform-name>/` whose path is appended to the active home clone's repository-local exclude file, never to a `.gitignore`.
  Resolve `home_root` to `$FM_HOME` when it is set and otherwise to the Firstmate code root, and anchor every destination index check, exclude-path lookup, and ignore verification to that root with `git -C "$home_root"`.
  Before approval and again before migration, validate that the chosen freeform destination under `home_root` is absent from that home's git index and collides with no existing file or directory, and reject the destination if either check fails.
  The name is freeform with no user-vs-firstmate naming convention, the skill stays per-home and untracked, and the harness still lists and JIT-loads it because skill discovery scans the filesystem and ignores git status (verified in `docs/verification/stow-memory.md`).
  Its precise, condition-stated description line is its entire trigger; it gets no `AGENTS.md` declaration because `AGENTS.md` is shared tracked material.
  Because this destination is local and untracked, it is also the JIT home for private conditional knowledge that no committed surface may hold.
- An already-existing user-owned local on-demand note with an established trigger, after confirming it is untracked, private, and able to hold the quoted entry.
  The pass may add the entry to that existing owner but never creates a new note, skill, or trigger for this purpose.
- A project-level skill in the project's own repository, for situation-conditional knowledge within one project, through a normal ship task and the project's registered delivery mode.
  A project's committed `AGENTS.md` is never an offload destination: crewmates correct it but only humans extend it (AGENTS.md section 6).

Forbidden destinations: any firstmate-repo-tracked skill per the hard rule; firstmate's own `AGENTS.md`, which is always-loaded for every fleet session; `docs/` alone, which is never agent-loaded on demand, though a skill body may point into docs for depth; and any committed surface for private content.
A local skill exists only in this home, so offloading an entry out of `data/captain-shared.md` removes it from every inheriting home's always-injected memory: the proposal must say so, and the default for shared entries is keep.

### Flow: reduce, approve, migrate, remove

1. Reduce non-pinned material now.
   For each eligible non-pinned candidate, record its first line, source file, estimated tokens, one-line trigger, live destination, privacy and visibility verdict, and actual budget relief in the completion receipt.
   Autonomously relocate it only by adding it to an already-existing allowed JIT note, or by routing it through a project's established delivery path to an already-existing allowed project-level destination, then confirming that destination holds the quoted entry before removing the memory entry.
   A destination that needs creation, uncompleted project delivery, or any other future work is not live and cannot count as relief, so continue with the next archival or eviction rung instead of leaving an over-budget proposal pending.
2. Propose pinned relocation only.
   For a pinned candidate, append a `proposed-offload` section with the same fields to the completion receipt, create or refresh one durable backlog item with `bin/fm-tasks-axi.sh add`, `bin/fm-tasks-axi.sh show <id> --full`, and `bin/fm-tasks-axi.sh update <id> --body-file <path>` as appropriate, then hold it through `bin/fm-captain-hold.sh hold`.
   Preserve each candidate's approval state in that item, and require explicit plain-chat approval for that named item before any migration.
   If the captain never answers, nothing migrates and the held item persists, but it is never treated as budget relief.
3. Migrate an approved pinned candidate outside this pass.
   Resolve `home_root` to `$FM_HOME` when it is set and otherwise to the Firstmate code root, then re-validate the approved local-skill destination under that root for both index absence with `git -C "$home_root"` and filesystem collision absence.
   Before creating the destination or writing any private content, resolve the exclude file with `git -C "$home_root" rev-parse --git-path info/exclude`, append the destination directory path to it, and verify the future `SKILL.md` path is ignored with `git -C "$home_root" check-ignore`.
   Only after that verification succeeds, create the destination and write the `SKILL.md` with its precise description trigger, then confirm the skill appears in a fresh session's skill index.
   If any migration step fails, remove the destination content and the exclude rule written by this attempt, leaving neither partial private content nor a partial rule behind.
   An approved project destination ships as a normal task through that project's registered delivery mode.
   The migration's source of truth is the entry as quoted in the proposal.
4. Remove only once live.
   The memory entry leaves its always-injected file only after the destination is live: the local skill exists with its verified line in the active home's resolved repository-local exclude file, or the project change has landed.
   Until then the entry stays, so knowledge is never in limbo between owners.
   Leave no pointer behind by default, and at most one line only when the destination's discoverability is genuinely doubtful.
