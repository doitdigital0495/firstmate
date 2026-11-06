# fmx-respond: promised final replies procedure

Reference of the `fmx-respond` skill, loaded on demand from its `SKILL.md` table; the always-resident rules stay in that `SKILL.md`.

**When you promise a final (including every Relay request whose work is routed to a second mate):**

1. Create the typed obligation with `bin/fm-tasks-axi.sh public-followup add` and bind the work with its `bind-work`, keeping the public-safe summary and the opaque thread binding in the obligation and the full request context where the poll already put it.
   When the public ask plainly implies follow-on work ("look into X and fix it"), register the promised-final against the outcome and deliver any interim report as a separate `--purpose milestone` obligation on the same thread.
   An ask that genuinely terminates at a report stays `report-ready`; do not invent a ship commitment for work the captain has not authorized.
2. Register it with `bin/fm-public-followup.sh register <obligation-id> --relation <relation-id> --work-home <main|secondmate:<id>> --work-id <task-id> --generation <n>`.
   This is what makes the commitment reconcilable without you.
3. Put `bin/fm-public-followup.sh brief <obligation-id>` output straight into the worker's brief.
   It prints the exact reporting command for that binding, pre-fills any deliverable value the binding determines, and gives the accepted format for every remaining placeholder.
   When the work is routed to a second mate rather than spawned here, the routed item's own note MUST carry that same `brief` output so it survives the routing and reaches whoever ends up doing the work.
   A header-only routed item loses the emit command.
   Never ask a worker to find the thread or post the reply: only this home holds the relay consent and the thread binding.

**When work reports back, or on a `public-followup ...` check wake, or when the session-start digest lists a public commitment or an open public loop:**

1. Run `bin/fm-public-followup.sh consume`.
   It reconciles every typed terminal result from disk and prints `ready <obligation-id> <request-id> <platform>` for each commitment that became deliverable.
   A refusal prints `rejected <event-id>: <reason>` and quarantines that event; read the reason rather than re-emitting blindly.
   The same refusal later arrives as a `public-followup rejected <event-id> ...` wake, so the promise is not left owed silently: have the bound work re-emit with the value the reason names, using the corrected `brief` command.
   That wake is at-least-once: a failed cleanup can raise the same refusal again, carrying the same event id and reason.
   When the event id is one you already took up, acknowledge the wake and do not re-brief the work; re-acting is safe but redundant, because the corrected result resolves to the event id that was already accepted.
2. For each ready commitment, run `bin/fm-public-followup.sh deliver <obligation-id>`.
   With no `--text-file` it reuses the accepted terminal outcome exactly, which is the preferred path for a landed result.
   Only pass `--text-file` when the outcome genuinely needs composing, and hold it to the same public-safety bar as every other reply here.
   Delivery clears the bound task's legacy Relay link at the validated receipt boundary and stamps the registration `state=delivered`; it does **not** close the public loop.
   If it reports a cleanup failure, use its reconciliation message and do not post a legacy final.
3. Read the outcome and stop guessing at anything it refuses:
   - "still waiting on its bound work" means the work has not reported a typed terminal result yet - do not post.
   - "recorded as retryable" means nothing was posted; retry on a later wake.
   - "held" means the thread's platform or budget is unresolvable right now; retry once it is recoverable.
   - "mid-delivery" means a previous post started and its outcome was never recorded.
     Do NOT deliver again.
     Establish whether that post landed, then either record its receipt with `record-posted <id> --attempt <n> --chunks <exact-count>` or escalate.
     Posting again would put a second reply in a public thread.
   - "the relay no longer accepts a follow-up" is a captain decision, not a retry.
4. After a successful deliver (or when the digest lists an `open-loop` line), decide the disposition in that same turn:
   - Follow-on work authorized from the same public thread: `bin/fm-public-followup.sh rechain <new-id> --from <delivered-id> --work-home <main|secondmate:<id>> --work-id <task-id> --expected <pr-merged|report-ready|local-main>`, then put the printed `brief` into that follow-on's instructions (and into the routed item's own note when the work is routed).
     If rechain reports an interrupted bind or source-retirement failure, resume the same destination with the same command; the retained source claim forbids choosing another destination.
   - The public loop is finished: `bin/fm-public-followup.sh retire <id> --reason "<why the loop is done>"`.
   Delivering a final is not closure.
   Silence after delivery is an open loop, not a kept promise for later work.

The cleanup, kept-commitment, and closed-loop rules that close this procedure stay in `SKILL.md` under "Promised final replies".
