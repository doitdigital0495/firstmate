# stow: memory tiers

Reference of the `stow` skill, loaded on demand from its `SKILL.md` table; the always-resident rules stay in that `SKILL.md`.

## Memory tiers and entry markers

Markers are compact trailing HTML comments, deliberately cheap because marker bytes are counted content:

- `<!--a:YYYY-MM-DD-->` - an `aging` entry; the embedded date is its last-reinforced date.
- `<!--p:YYYY-MM-DD-->` - a `perishable` entry; the embedded date is its last-reinforced date.
- `<!--a:YYYY-MM-DD/N-->` - only in a home that has opted in to the pass horizon below: either dated marker may carry `/N`, the number of passes that evaluated the entry without reinforcing it.
  An absent `/N` means zero, so an entry the fleet keeps exercising costs no counter bytes at all, and a home that has not opted in never writes one.
- `<!--P-->` - an explicitly `pinned` entry in a file whose default tier is not `pinned`.
- `<!--g-->` - migration-only: an unconfirmed legacy entry that has consumed its one grace cycle, carrying no date because grace is not reinforcement.
- `<!--t:NAME-->` - pending capture: a tier-owned entry that the declared memory tier `NAME` does not yet hold because no session that wrote or curated it could reach that tier; it follows any tier marker the entry already carries.
  Stow never prunes, ages out, evicts, offloads, consolidates away, or moves to the cold archive an entry carrying it, whatever its tier clock says.
  A later pass that can reach `NAME` captures the entry there under the tier's declared rule, then removes the marker, after which the entry is curated like any other.
  When the declaration no longer names `NAME` because the home renamed or retired that tier, the next pass retargets the marker to the declared tier that now owns the entry's knowledge class, or removes it when no declared tier owns that class, so no entry stays pinned by a tier that no longer exists.

```markdown
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
- While state/.afk exists, the away-daemon owns triage (until the afk-wake fix lands; tracked: afk-pi-wake-bypass-r1). <!--p:2026-07-20-->
- Never restart the shared no-mistakes daemon while runs are active. <!--P-->
- Codex writes its trust prompt to stderr, not stdout. <!--a:2026-07-28/6-->
```

The tier names say what the pass does with an entry:

- `pinned` - no clock is ever read for it: exempt from decay and from budget eviction, changed only through inspect-then-update when the captain or reality changes it, except that an explicit per-item captain approval may offload it under the flow below.
- `aging` - it must re-prove itself: an entry whose age is greater than or equal to 30 days since its last-reinforced date is stale, and a stale entry is re-validated (date refreshed) or archived, never kept by inertia alone.
- `perishable` - it is stored expecting disposal: an entry whose age is greater than or equal to 7 days since its last-reinforced date is stale, and its prose must name a checkable expiry condition, such as a backlog id, a version floor, or a dated expectation.
  An admitted durable entry that cannot name a checkable expiry condition is not `perishable` and must be stored as `aging`.
  Omission is reserved for non-durable material or facts already owned elsewhere.

Marking rules:

- Tier defaults are file-scoped: entries in `data/captain.md` and `data/captain-shared.md` default to `pinned` because preferences and authority boundaries do not age, and entries in `data/learnings.md` default to `aging` because operational facts must re-prove themselves.
- An entry matching its file's `pinned` default carries no marker at all; every `aging` and `perishable` entry always carries its dated marker, whose letter names the tier, so a clock-carrying entry is never ambiguous with unmarked legacy material.
- Marker and header-pointer bytes count toward the startup-memory budget: the pass's own bookkeeping is costed content, never free, which is why the spellings above are as short as they are.
- Each memory file's header carries at most a one-line pointer naming this skill as the scheme owner, such as `<!-- memory tiers: see the stow skill -->`.
  This skill text is the single owner of tier semantics, marker spellings, and clocks, and no memory file header may restate them.
  The one exception is the `config/stow-pass-horizon` presence flag below, which turns a single extra horizon on for this home and changes nothing else on this page.
- Inspect each editable file's header pointer on every pass and add or correct it; for a read-only `data/captain-shared.md`, leave the file byte-identical and route a missing or outdated pointer to the primary owner.
  The required receipt action for that file is `routed`, not `unchanged`; name the ownership exception and do not declare the session reset-safe.
- A pre-existing missing or hand-dropped marker is never grounds for destructive treatment: it means the file's default tier; an unmarked entry in a default-pinned file is simply pinned, while an unmarked entry in a file whose default tier carries a clock follows the migration rule below.

Decay advances only when a pass runs, so a home stowed less often than a clock experiences that clock at its stow interval.

### Optional pass horizon (config/stow-pass-horizon)

The wall-clock horizons above are this skill's default contract, and a home gets exactly them unless it asks for more.
A home may opt in to a second, per-pass horizon by creating the local, gitignored `config/stow-pass-horizon` presence flag.
While that file is absent nothing else in this section applies: no counter is written, no counter already in a file is read, and every entry decays on its date alone.

Opt in where admission and decay are not commensurable.
A pass admits the findings that pass produced, so growth is a per-pass quantity, while a wall-clock horizon alone is a per-day one.
In a home that stows daily those two rates diverge by the stow cadence, an entry the fleet keeps exercising never sits unreinforced for 30 wall-clock days, and the date horizon is evaluated vacuously every pass while the file only grows.
A home stowed monthly already exceeds its date horizon on a single pass and gains nothing from the flag.

While the flag is present:

- An `aging` entry is stale at whichever horizon it reaches first: 10 passes that evaluated it without reinforcing it, or 30 days since its last-reinforced date.
- A `perishable` entry is stale at whichever it reaches first: 3 unreinforced passes, or 7 days.
- Reinforcement refreshes the date and clears the counter, and nothing else clears it, so the evidence hard rule in step 4 stays the only way an entry renews its lease.
- An existing dated marker with no `/N` reads as counter zero, so a home that opts in migrates nothing.
- Removing the flag returns the home to the default contract on its next pass: any `/N` already written is then neither read nor advanced, and is left in place rather than rewritten.
