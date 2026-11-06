# fmx-respond: procedure

Reference of the `fmx-respond` skill, loaded on demand from its `SKILL.md` table; the always-resident rules stay in that `SKILL.md`.

## Procedure

This is a drain over the inbox, not a single reply.
The watcher coalesces same-key `check:` wakes, so one `x-mention` wake can stand in for several pending mentions.
Treat `state/x-inbox/` as the source of truth and process **every** file you find there, not just the `request_id` named in the wake.

1. **Gather live fleet state once.** Compose answers from what this instance genuinely knows right now:
   - `data/backlog.md` "## In flight" - the work currently moving.
   - `state/*.status` - the latest status event of each in-flight job, for fresh phase detail.
   - `data/projects.md` - the active projects, for naming what you work on in plain terms.
   Translate every internal item into an outcome. Example: a backlog line `fix-login-k3 - repair OAuth redirect (repo: yourapp)` becomes "patching a sign-in redirect bug on one of the apps" - no id, no repo name unless it is already public.
2. **Drain every pending mention.** For each `state/x-inbox/*.json` file:
   a. **Read the whole object, not a fixed list of fields.**
      Inspect every key the payload actually carries - at the top level, inside `in_reply_to`, and inside each `in_reply_to_chain` entry - because the relay gains fields over time and anything you never look at is invisible to you.
      `request_id`, `text`, `in_reply_to`, and `in_reply_to_chain` are what you always work from; never assume they are all that is there.
      `in_reply_to` is `{author_handle, text}` when this mention is a reply within an ongoing conversation, or `null` for a fresh, standalone mention.
      `in_reply_to_chain` is the optional surrounding-conversation transcript; [the Relay configuration reference](../../../../docs/configuration.md#relay-env) owns its exact wire shape and compatibility semantics.
      Read every entry in its documented oldest-first order, including `history` entries and unavailable gaps, but treat the chain as optional context because it is often absent today: use it when present and proceed normally without it.
      Ignore `tweet_id` entirely - you never name a platform message id; the relay binds the reply for you.
      **Then look at whatever is attached before you answer.**
      A mention can carry image and file URLs on the mention itself and on any `in_reply_to_chain` entry, in fields such as `images` and `attachments`, either as bare URL strings or as objects with a `url`.
      The mention's own media is often empty while the `thread_starter` entry carries the screenshots - the ordinary shape of a Discord support thread - so scan the entire payload rather than the top level alone.
      Fetch each media URL with your own tools into a local file and then actually open it: read an image file as an image so you see the screenshot itself, and read a text-like file inline.
      "Fetching inbound attachments" above governs which hosts you may fetch from and how to treat what comes back.
      Never answer from a URL alone when you could have looked at the file, and never guess at what a screenshot shows.
      If a fetch fails, or the host is not on that list, tell the captain rather than quietly dropping the attachment.
   b. **Classify the mention into one of three cases** (see "A request to act on: acknowledge first, act, then follow up on completion"):
      - **Actionable instruction / request** ("add this to the backlog", "look into X", "fix Y", "ship Z") - go to step 2c and do the work first.
      - **Question** - nothing to do; skip step 2c and answer from live fleet state in step 2d.
      - **Pure acknowledgment** ("thanks", "👍", "nice", "got it", a reaction, or a follow-up that just closes the loop with nothing to add) - **skip**: post nothing, but **dismiss it at the relay** (step 2e-skip), then remove the inbox file (the cleanup of step 2f), and move on **without** calling `bin/fm-x-reply.sh`. A deliberate non-answer is the correct outcome here, not a failure.
      When in doubt between an instruction and a question, do the smallest safe lifecycle step the request implies; when in doubt between a question and bare politeness, lean toward skipping - a needless reply is noise on a public bot.
   c. **Act on an actionable request through the normal lifecycle.** Treat it exactly as a captain prompt typed in session: run ordinary intake (resolve the project), then file the backlog item, dispatch a crewmate, start a scout, or ship through the gate - whatever the request calls for.
      **Destructive, irreversible, or security-sensitive work is the exception** (Relay is a public, relayed channel and does not carry full in-session trust): do not execute it from the mention. Flag it to the captain through the normal trusted channel first - the same carve-out as `yolo` (AGENTS.md §1, §7) - act only on the captain's word, and in step 2d say only that it has been flagged for the captain.
      **If the request spawned a real, longer-running task in THIS home** (you ran `bin/fm-spawn.sh` here), link that task to this mention so milestone and completion follow-ups can be posted: `bin/fm-x-link.sh <task-id> <request_id>`.
      **Link here, in step 2c, before the step 2f inbox cleanup** - `bin/fm-x-link.sh` can copy both the mention's reply platform and explicit budget from the still-present inbox payload without a relay lookup.
      If that local context is incomplete it uses the durable resolution contract in `docs/configuration.md` and warns loudly, while the follow-up path refuses to post unless both values can be resolved authoritatively.
      **If intake routes the work to a second mate instead**, do not reach for the link: register the typed promised-final commitment bound to `secondmate:<id>` and brief the routed worker with its reporting command (step 3 of "acknowledge first, act, then follow up on completion", with the commands in "Promised final replies").
      Then step 2d's reply is an **acknowledgement** ("on it, captain"), and genuine milestone updates plus the final outcome come later as follow-ups (see "Completion follow-up" below), with the terminal one posted using `--final` when no typed promised-final commitment exists.
      If the work completed in this turn (a backlog item filed, a question answered), there is no task to link and step 2d reports the outcome directly.
   d. **Compose the reply.** For a **question**, answer `.text` from the fleet state gathered in step 1. For an **actionable request that completed now**, report the outcome of step 2c (what was done, or - for escalated work - that it has been flagged for the captain). For an **actionable request that spawned a linked task**, acknowledge that you have the order and are on it - milestone updates and the final outcome follow later as completion follow-ups, so do not promise a result you do not yet have. Either way keep it short, in firstmate's voice, and public-safe.
      Conversation continuity: resolve referents like "this", "it", "that", "and then?" against **all** the conversation context the payload carries - `in_reply_to.text` (what `in_reply_to.author_handle` said just before, when present) plus the full `in_reply_to_chain` transcript, whose oldest-first order puts what was said most recently just before the mention at the end.
      A standalone mention (`in_reply_to` null) can still carry a chain - a thread starter or recent nearby messages - and its referents usually point there, so read the chain before concluding a mention has no context; only a mention with neither answers on its own.
      When chain entries disagree, weigh the entries nearest the mention most heavily, and skip `unavailable: true` gaps.
      If nothing is in flight and the mention just asks what you are up to, say so honestly and in-voice (e.g. "Calm seas just now - nothing underway, standing by for the captain's next orders.").
   e. **Submit it without ever inlining the reply into a shell command.**
      Public mention text can influence your prose, so a double-quoted shell argument is unsafe (command substitution, variable expansion, quote breakage).
      Write the composed reply to a temporary file with your own file-writing tool - never via shell interpolation - then pass it by path:

      ```sh
      bin/fm-x-reply.sh <request_id> --text-file <path-to-reply-file>
      ```

      (`bin/fm-x-reply.sh <request_id> -`, reading the reply on stdin, is equally fine.) It echoes the `request_id` and exits 0 on success; non-zero on a failed live post or failed dry-run record.
      When the reply carries one real visual artifact, add `--image <path>`: the helper reads one local PNG, JPEG, GIF, WebP, BMP, or TIFF, detects the media type, base64-encodes it, and sends it in the relay's optional `image` object without ever inlining image bytes into the shell command.
      If the reply auto-splits into a thread, the image rides the first/opener message only.
   e-skip. **For a skip, dismiss it at the relay instead of replying.** A pure acknowledgment gets no reply, but clearing only the local inbox file is not enough: the relay keeps re-offering that request on every poll until it times out to a polite "offline" auto-reply. So before clearing the file, tell the relay to drop the request:

      ```sh
      bin/fm-x-dismiss.sh <request_id>
      ```

      It posts nothing, stops the re-offer, and prevents the offline auto-reply; it echoes the `request_id` and exits 0 on success (it honors `FMX_DRY_RUN` like `bin/fm-x-reply.sh`, recording the would-be dismiss to `state/x-outbox/` instead of posting). Do **not** call `bin/fm-x-reply.sh` for a skip.
   f. **On success (a posted reply, or a relay dismiss for a skip), remove that inbox file:** `rm -f state/x-inbox/<request_id>.json` (and your temporary reply file).
      This is the local idempotency guard - a cleared file is never answered twice.
      For an acknowledged actionable request that spawned a task, this cleanup comes **after** the step 2c link, never before, so the link can copy the reply platform and budget directly from the inbox payload.
   g. **On failure** (a non-zero exit from `bin/fm-x-reply.sh` or `bin/fm-x-dismiss.sh`), leave that inbox file in place, move on to the next, and do not retry blindly.
      If you had already acted on this mention in step 2c before the post failed, do **not** redo that work on a later drain - check whether it is already done (e.g. the backlog item exists, the crewmate is already running) and only retry the reply.
      If a reply or dismiss fails twice, surface it to the captain as a blocker with the stderr detail; for live post failures include the relay's HTTP status when available.
      The relay posts its own offline reply if no live answer lands in time, so a single miss is not a crisis.

## Dry-run / preview mode

When `FMX_DRY_RUN` is set (truthy, in the environment or `.env`), `bin/fm-x-reply.sh` does **not** post and `bin/fm-x-dismiss.sh` does **not** call the relay.
The reply client records the full would-be reply payload to `state/x-outbox/<request_id>.json` (`{request_id, text}` for one message, or `{request_id, text, texts}` for a thread), prints a `DRY RUN` summary to stderr, and still echoes the `request_id` and exits 0.
The dismiss client records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary to stderr, and still echoes the `request_id` and exits 0.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
When an image was attached, the dry-run record keeps only compact `{media_type, bytes, source_path}` metadata instead of the base64 bytes, so a preview never writes a multi-MB blob.
Dry-run needs `jq` to build the JSON payload, but it needs neither `FMX_PAIRING_TOKEN` nor the relay because it runs before token and network checks.
Your procedure does not change: compose as usual and call `bin/fm-x-reply.sh ... --text-file <path>`, or call `bin/fm-x-dismiss.sh <request_id>` for a skip.
Because the call still succeeds, the loop completes normally (clear the inbox file as in step 2f); the only difference is nothing reaches the relay.
This is the mode for end-to-end testing the poll -> compose -> would-post loop without a public post.
Inspect `state/x-outbox/` to see exactly what would have been posted.
The completion follow-up honors `FMX_DRY_RUN` the same way (it flows through `bin/fm-x-reply.sh --followup`): the would-be follow-up is recorded to `state/x-outbox/`, and the local counter and link mutate exactly as a live post would.
A non-final dry-run follow-up increments `x_followups` and keeps the link while under the cap; `--final`, the cap, or an expired window clears it, so the whole acknowledge -> act -> follow-up loop is testable without a public post.
