---
name: operational-home-layout
description: Load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths.
user-invocable: false
metadata:
  internal: true
---

# Operational home layout

## Reference files

Files under `references/` are resources of this skill, not additional catalogued skills.

| Read | When |
| --- | --- |
| `references/config.md` | locating or interpreting anything under `config/` |
| `references/state.md` | locating or interpreting anything under `state/` |

```
AGENTS.md            this file (CLAUDE.md is a real @AGENTS.md pointer to it)
CLAUDE.local.md      primary home only; LOCAL, gitignored Claude @-imports of data/captain.md, data/captain-shared.md, and data/learnings.md, created by locked bootstrap when absent (bin/fm-captain-imports-lib.sh)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (section 10)
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
.claude/mods/        Claude Code mods (function-hooks plugins), committed; Calm's plugin starts disabled (defaultEnabled false) until a captain enables fm@skills-dir (docs/calm.md)
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
.env                 optional Relay pairing token (presence-gates section 14), mail-plane credentials (schema: docs/configuration.md "Mail plane"), and typed dispatch resolution key OPENROUTER_API_KEY (or TYPESAFE_API_KEY on the explicit direct fallback) (presence-gates bin/fm-dispatch-resolve.sh; docs/configuration.md "Typed dispatch resolution"); LOCAL, gitignored
config/              per-home configuration; every entry is in references/config.md
data/                personal fleet records; LOCAL, gitignored as a whole
  suggestions.jsonl suggestions-not-picked.jsonl  suggested tasks kept off the board and their never-deleted archive; written only by bin/fm-suggestions.sh
  backlog.md         task queue, dependencies, history
  home-identity      durable terminal-session and Claude-account binding, written once and never migrated; bin/fm-home-identity.sh owns its comparison and refusals
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture and optional ship-branch prefix; firstmate-private, parsed by fm-project-mode.sh (section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (section 6)
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
  <id>/milestones.status  task milestone lines archived at teardown and appended by later authorized stamps; survives teardown; bin/fm-task-milestones.sh owns it
  <id>/status.log <id>/status.<N>.log <id>/children/<child>/...  optional teardown archives; see docs/architecture.md "Task status archives"
  pipeline-spend.jsonl  optional per-task no-mistakes pipeline spend, written only when config/pipeline-spend is present; bin/fm-pipeline-spend.sh owns the schema
  dispatch-overrides.jsonl  historical captain overrides of the dispatch table; bin/fm-dispatch-receipt-lib.sh owns the schema and phase-1 restrictions, and the session-start digest lists recent history
projects/            cloned repos; gitignored; read-only except under hard rule 1's concrete captain-approved project operation exception
state/               runtime state; every entry is in references/state.md
.no-mistakes/        local validation state and evidence; gitignored
```
