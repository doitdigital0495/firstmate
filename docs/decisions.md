# Decision log

Captain-level routing and operating decisions whose reasoning the current-behavior docs do not carry.
Each entry links the page that owns its resulting contract.

## 2026-11-05 - up to 30 workers, and unlanded work is finished rather than parked

**Decision.** A home runs up to 30 ordinary workers in parallel, down from 50.
The primary firstmate and persistent secondmates do not count toward that cap, and there is no automatic pause at any usage percentage.
[`configuration.md`](configuration.md#lane-capacity-configlane-capacity) owns the cap's file format.
Work that cleanup refuses as uncommitted or unmerged is finished and merged by firstmate rather than sent to the captain, and never forced; [`ship-landing`](../.agents/skills/ship-landing/SKILL.md) owns the procedure.

## 2026-11-04 - no-mistakes steps choose their seat from two pools

**Decision.** A no-mistakes step takes its seat from a fixed resolver row, with no model call per step.
Pool 1 is claude1 or claude2.
Pool 2 is claude3 and every Codex account, used only when pool 1 has no seat with room.
A live five-hour window counts for the pipeline only, claude3 stops at 20 percent weekly room left, and Codex seats run at the step's reasoning class.
When both pools are empty the step fails and names every seat's reset, with no downgrade and no GLM.
[`configuration.md`](configuration.md#pipeline-seat-rows) owns the resulting contract.

**Why a fixed row.** The step name already fixes the row, and a model call per step would add cost and turn a Jev outage into a captain pick that a pipeline cannot answer.

**Why claude3 comes before Codex inside pool 2.** After a mid-run switch to Codex, a no-mistakes run never returns to the Claude adapter, so a run that goes to Codex can no longer reach claude3.
Ranking pool 2 by spendPriority alone would normally pick Codex first, because claude3's priority runs far lower, so claude3 sits in an earlier `seat_tier` while it is above its floor.
This keeps the two kinds of seat in one pool, and the order stays a row declaration rather than code.

**Why the floor reads the weekly window.** A quota row can be bounded by both windows, so a floor on that row would stop claude3 on a low five-hour window while its week still has room.

**Why an unreadable floor takes the seat out.** Other unreadable seats fall back to the first seat of their tier so a brief quota outage does not stop the pipeline, but the floor is a limit the captain set, so missing evidence does not override it.
