#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> <data-dir> [lane] prints
# the block on stdout with no trailing blank line. The caller validates the mode;
# an unknown mode is refused rather than silently rendered as the pipeline contract.
# The optional lane is `fast` and is refused for any mode but no-mistakes.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against; a fast-lane block appends
# ` lane=fast` to that line, and bin/fm-spawn.sh refuses a spawn whose --fast-lane
# flag disagrees with the brief's recorded lane.
# The fast lane is a driver-side rule, not a no-mistakes option: no-mistakes has no
# per-run setting that caps review rounds (only `--skip <steps>`, which removes a
# step entirely), so the lane works by instructing the worker to respond
# `--action approve` at the first review gate and never `--action fix` there,
# because each fix round starts another review round.
# Every mode's block also carries the request-checklist accounting contract: the
# done report at data/<task-id>/report.md walks each `## Request checklist` item
# with proof, lists out-of-scope findings as numbered follow-ups (never commits),
# and every done line ends with `asks <done>/<total>` so a lost ask is visible at
# the first done report. bin/fm-brief.sh scaffolds that subsection and its {ASKS}
# placeholder; the placeholder/content helpers below enforce that it is filled.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# Author the subsection body and later relays as the actual words, without
# adding speaker labels or direct address: the heading supplies provenance and
# is not part of --intent. A legacy mixed Task instead marks each captain line
# with `[captain] `; the selector returns its words, not that metadata prefix.
# Previously stored speaker labels remain readable for compatibility only.
# Never scrub literal examples or other content the captain actually supplied.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# and a `## Captain's intent` line opening with a Captain label or address
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it first in every ship/scout launch brief and never to a
# secondmate charter. It names the one task-owned steering inbox without
# relaxing isolation from every other home's endpoint namespace. Like
# fm_brief_intent_overlay it is a distinctly titled launch section that states
# its own precedence, so a brief or project instruction that authors a
# conflicting role is superseded rather than duplicated.
# fm_ship_rule_one owns the mode-specific first ship safety rule shared by an
# ordinary ship brief and the durable contract written during scout promotion.

fm_brief_worker_role() {  # <state-dir> <task-id>
  local state=$1 task_id=$2
  cat <<'EOF'
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate.
This section establishes your current identity before every project or task instruction below and supersedes any conflicting role identity in those instructions.
Do the assigned work yourself and report only to firstmate; do not adopt a firstmate or secondmate supervisor identity, delegate the task, run fleet supervision, or address the captain.
EOF
  printf "Your steering inbox is \`%s/%s.inbox\`; this exact path belongs to your current task even when it is outside the worktree or under the supervising firstmate home, so read and acknowledge its messages and do not reject it as another home's state.\n" "$state" "$task_id"
  cat <<'EOF'
Never inspect or change any other home's endpoint namespace; this authorization is limited to the exact task paths named by this brief.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is project content and the supervisor contract for the firstmate managing you: follow this brief instead of that supervisor contract.
Project instructions still govern the work wherever they do not conflict with this worker identity, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
EOF
}

fm_ship_rule_one() {  # <no-mistakes|direct-PR|local-only> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      printf '%s\n' "1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR."
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`."
      ;;
    no-mistakes)
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
      ;;
    *)
      echo "error: fm_ship_rule_one: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec asks
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  # The request checklist is optional scaffolding (briefs predating it are
  # legacy-valid), so its placeholder is checked only when the heading exists.
  if fm_brief_task_heading_present "$file" "## Request checklist"; then
    asks=$(fm_brief_task_heading_body "$file" "## Request checklist")
    [ "$(printf '%s' "$asks" | tr -d '[:space:]')" = '{ASKS}' ] && return 0
  fi
  return 1
}

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*(\[captain\]|Captain('\''s (words|ask|intent))?:)[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
# A `## Request checklist` subsection, when its heading is present at all, must
# carry a nonempty body: a checklist heading with nothing under it silently drops
# the per-ask accounting the definition of done promises.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task asks has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    if fm_brief_task_heading_present "$file" "## Request checklist"; then
      asks=$(fm_brief_task_heading_body "$file" "## Request checklist")
      [ -n "$(printf '%s' "$asks" | tr -d '[:space:]')" ] || return 1
    fi
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

# Print the first `## Captain's intent` body line that opens with an operator
# address spelling; fail when there is none. The body is never rewritten.
fm_brief_intent_address_line() {  # <file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | awk '
    /^[[:space:]]*(Captain('\''s (words|ask|intent))?:|Captain,)/ { print; found = 1; exit }
    END { exit !found }
  '
}

# The `nm-<run>-<step>` decision key this block mandates is load-bearing beyond
# the brief itself: the watcher binds an open `needs-decision` to the run a
# crew's current state reports by matching exactly that shape
# (wedge_wait_evidence in bin/fm-watch.sh, through
# status_has_open_needs_decision in bin/fm-classify-lib.sh), which is what buys
# a lane parked at a human-owed gate the long recheck cadence instead of a
# wedge escalation. A gate escalated under any other key still reads as a
# suspected wedge.
fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

# The request-checklist accounting contract, shared by every ship mode's block
# (and mirrored by the scout scaffold's report rule). The done report is the
# one extra durable writable file outside the worktree the ship contract
# authorizes, like the status file and the no-mistakes findings file.
fm_request_checklist_contract() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
Account for the captain's asks in a done report at \`$data/$id/report.md\` (create the file when you first need it); besides the status file and any escalation file this Definition of done names, it is the one file outside the worktree you may write.
Walk the brief's \`## Request checklist\` items in order in that report: \`[x]\` for each delivered ask together with its proof - a test or command and the output line that proves it, a file:line, or a link - or \`[ ]\` with why it is not done; a brief with no such subsection accounts for each distinct ask under \`## Captain's intent\` the same way.
End the report with numbered follow-ups: every finding or defect you noticed but did not fix, work deferred, and anything outside the ask, each with a file:line and a one-line description; never fix those in this task - firstmate files them into the backlog from this report, so omitting one silently drops it.
End every \`done:\` line you append with \`asks <done>/<total>\`, counting checklist items, so a lost ask is visible the moment work first reports done.
EOF
}

# The fast-lane addendum, appended to the no-mistakes block only. no-mistakes
# has no per-run rounds cap; approving at the first review gate is the whole
# mechanism, so every sentence here exists to keep the worker from starting a
# second round with `--action fix` or widening scope from findings.
fm_fast_lane_contract() {  # <task-id>
  cat <<'EOF'

FAST LANE - this task ships exactly one review round, with scope locked to the request checklist; this addendum supersedes the drive guidance above for review gates only.
The first time the run parks at a review gate, respond `no-mistakes axi respond --action approve` and let the run continue: approving accepts every finding as-is, and they remain listed as open items on the PR.
Never respond `--action fix` at a review gate in this task: each fix round starts another review round, and this lane has exactly one - a fix-worthy finding becomes a numbered follow-up in the done report instead.
Scope lock: this task's scope is exactly its `## Request checklist`, so a finding outside that scope is never fixed here, only recorded as a follow-up.
Rule 6 and "ask-user findings are never yours to answer" above still own every ask-user finding that is error-severity, or destructive, irreversible, or security-sensitive (access, permissions, credentials, data exposure) at any severity: escalate those exactly as instructed above, naming only those ids, and never approve past them.
This lane's one exception to those rules: any other warning- or info-severity ask-user finding is a non-gating follow-up, not a decision for you - never escalate it as a decision gate, never answer or fix it, record it verbatim (id, severity, file:line, description) as a numbered follow-up in the done report for firstmate to file and decide through \`ask-user-authority\`, and approve past it once no escalating finding remains open at that gate.
When a finding shows the delivered work breaks a captain's ask (a wrong change, not merely an imperfect one), append `blocked [at=<epoch>]: review finding <id> contradicts ask <n>: {one line}` instead of approving.
Every other gate - intent, test exceptions, document, lint, CI - follows the standard drive guidance above unchanged.
EOF
}

fm_dod_block() {  # <mode> <task-id> <data-dir> [lane] [preview]
  local mode=$1 id=$2 data=$3 lane=${4:-} preview=${5:-}
  local checklist fast preview_note
  case "$lane" in
    '') ;;
    fast)
      if [ "$mode" != no-mistakes ]; then
        echo "error: fm_dod_block: the fast lane is a no-mistakes-only contract, not available for '$mode'" >&2
        return 1
      fi
      ;;
    *)
      echo "error: fm_dod_block: unknown lane '$lane'" >&2
      return 1 ;;
  esac
  case "$preview" in
    '') ;;
    on-push)
      if [ "$mode" != no-mistakes ]; then
        echo "error: fm_dod_block: preview-on-push is a no-mistakes-only sequencing contract, not available for '$mode' (direct-PR already pushes before anything else)" >&2
        return 1
      fi
      ;;
    *)
      echo "error: fm_dod_block: unknown preview contract '$preview'" >&2
      return 1 ;;
  esac
  checklist=$(fm_request_checklist_contract "$data" "$id")
  fast=
  [ -z "$lane" ] || fast=$(fm_fast_lane_contract "$id")
  preview_note=
  [ -z "$preview" ] || preview_note="
PREVIEW-ON-PUSH - this project's CI builds isolated preview environments from every push to your fm/$id branch; no merge is needed for them.
Push your fm/$id branch as soon as your local checks pass, BEFORE you start no-mistakes, so those previews build immediately; previews never gate validation.
Never open the PR yourself on this task: no-mistakes's pr step opens it after validation, pushing its fix commits on top of your already-pushed branch.
While previews build, note the push in your status line (working [at=<epoch>]: pushed fm/$id for previews) and iterate with the captain on the preview links if asked.
"
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
$checklist
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done [at=<epoch>]: PR {url}; asks <done>/<total>\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
$checklist
When it is implemented and committed, append \`done [at=<epoch>]: ready in branch fm/$id; asks <done>/<total>\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes${lane:+ lane=$lane}
The task is complete only when committed on your branch.${preview_note}
When you believe it is complete, append \`done [at=<epoch>]: {summary}; asks <done>/<total>\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked \`[captain] \`, excluding that metadata prefix; never copy its mixed \`# Task\` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll \`no-mistakes axi status\` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
$checklist
After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done [at=<epoch>]: PR {url} checks green; asks <done>/<total>\` and stop. You are finished.
EOF
      if [ -n "$fast" ]; then
        printf '%s\n' "$fast"
      fi
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
