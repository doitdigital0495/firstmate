# The fm-live-board-view.v1 projection; bin/fm-live-board.sh's header owns the
# public contract and the config/live-board-projects.json schema. Input is one
# fm-live-board.v1 snapshot; $map is the parsed project map or null.

def lb_text($max): type == "string" and length > 0 and length <= $max
  and test("[^[:space:]]") and (test("[\\x00-\\x1f\\x7f]") | not);

def lb_valid_map:
  type == "object" and .schema == "fm-live-board-projects.v1"
  and ((keys - ["schema","projects"]) | length == 0)
  and (.projects | type == "array" and length <= 64
    and all(.[]; type == "object" and ((keys - ["name","description","match"]) | length == 0)
      and (.name | lb_text(60))
      and ((has("description") | not) or (.description | lb_text(200)))
      and (.match | type == "array" and length > 0 and length <= 64
        and all(.[]; type == "object" and length > 0 and ((keys - ["id","repo"]) | length == 0)
          and ((has("id") | not) or (.id | type == "string" and test("^[A-Za-z0-9._*-]{1,128}$")))
          and ((has("repo") | not) or (.repo | type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))))))
    and (map(.name) | length == (unique | length)));

# Only `*` is a wildcard; every other id-pattern character is literal.
def lb_glob($pattern):
  test("^" + ($pattern | gsub("\\."; "\\.") | gsub("\\*"; ".*")) + "$");

# A metadata project may be a path; the board only ever names its last part.
def lb_repo: if type == "string" then (split("/") | map(select(length > 0)) | .[-1]) else null end;

# Captain-facing wording: drop links, paths, branches, run ids, key=value
# tokens and known task ids from operational text, keeping the plain words.
def lb_clean($ids):
  if type != "string" then null else
    gsub("(PR:?\\s+)?https?://[^\\s]*/pull(request)?s?/(?<n>[0-9]+)[^\\s]*"; "PR \(.n)")
    | gsub("https?://[^\\s]+"; "")
    | gsub("(?<![^\\s(\\[\"'])(?<p>[~./]*[A-Za-z0-9._@-]*/[A-Za-z0-9._@/-]*)";
        if (.p | test("^[~/.]|^(data|state|bin|docs|config|tests|fm|functions|reports-app|dbt|projects|home|scripts|src)/|\\.[A-Za-z]{1,5}$|/$"))
        then "" else .p end)
    | gsub("blocked-by:\\s*[A-Za-z0-9._-]+"; "")
    | gsub("\\b[a-z_]+=[^\\s]*"; "")
    | gsub("\\b(run|corr|session):?\\s*[0-9A-Za-z]{16,}\\b"; "")
    | gsub("\\b[0-9A-Z]{26}\\b"; "")
    | gsub("\\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,}\\b"; "")
    | gsub("(?<w>[A-Za-z0-9._]+(-[A-Za-z0-9._]+)+)"; if $ids[.w] then "" else .w end)
    | gsub("\\(\\s*[,;:]?\\s*\\)"; "")
    | gsub("\\(\\s*(report|see|in|from)\\s*\\)"; "")
    | gsub("\\s+(?<p>[,;:.)])"; .p)
    | gsub("\\s+"; " ")
    | gsub("^[\\s,;:·-]+|[\\s,;:·(-]+$"; "")
    | if length == 0 then null else . end
  end;
# A worker note is news only when it is mostly words; token soup is dropped.
def lb_words($ids; $max):
  lb_clean($ids)
  | if . == null then null else
      (if length > $max then .[:$max - 3] + "..." else . end)
      | ([splits("\\s+") | select(length > 0)]) as $tokens
      | if ([$tokens[] | select(test("^[(\"']?[A-Za-z][a-z]*[)\"',.;:!?]*$"))] | length) * 2 < ($tokens | length)
          or length < 15 then null else . end
    end;
def lb_note($ids): lb_words($ids; 160);
# A title that is only a task id reads as words instead.
def lb_title($ids):
  if type != "string" then null
  elif $ids[.] then (gsub("[-_.]+"; " ") | (.[:1] | ascii_upcase) + .[1:])
  else lb_clean($ids) end;

# EXPLANATIONS. Every row the page lists says what it is in plain words, so a
# short label never stands alone. The first source that yields words wins: the
# task's own note, the plain-language "about" its captain call was asked with,
# then its hold reason, each only when it is mostly words (`lb_words`); with
# none, the literal gap text, so a missing explanation is visible. `source`
# names which one it was.
def lb_no_explanation: "No explanation recorded yet";
def lb_explain($ids; $about; $context; $hold):
  [({text:($about | lb_words($ids; 240)),source:"note"}),
   ({text:($context | lb_words($ids; 240)),source:"call"}),
   ({text:($hold | lb_words($ids; 240)),source:"hold"})]
  | map(select(.text != null))[0] // {text:lb_no_explanation,source:"missing"};

# LANES. The one rule that puts every open task in exactly one lane, read top
# down; `why` names the reason and is the only thing the wording below keys on.
#   doing    it has a worker that neither waits on the captain nor is finished
#   next     not started and nothing in its way, so a worker starts it on its own
#   charted  will not start or move on its own; `why` says what it waits for
# $today is the collection date; a dated hold that is not the captain's lapses
# on that date, exactly as the backlog stops treating it as a hold. $crew is
# the task's `lb_worker_status`, or null when it has no worker.
def lb_deferred($today): .hold.until != null and .hold.until > $today;
def lb_lane($today; $crew):
  if $crew != null and ($crew | IN("you","finished") | not) then {lane:"doing",why:"worker"}
  elif .hold.kind == "captain" and .hold.reason != null then
    {lane:"charted",why:(if lb_deferred($today) then "deferred" else "your-answer" end)}
  elif (.hold.kind != null or .hold.reason != null) and (.hold.until == null or .hold.until > $today) then
    {lane:"charted",why:"on-hold"}
  elif ((.unresolved_blockers // []) | length) > 0 then {lane:"charted",why:"other-work"}
  elif .state == "queued" then {lane:"next",why:"ready"}
  elif .state == "blocked" or .state == "parked" then {lane:"charted",why:"stuck"}
  elif .state == "paused" then {lane:"charted",why:"paused"}
  elif .state == "finished-awaiting-processing" then {lane:"charted",why:"wrap-up"}
  elif .state == "program" then {lane:"charted",why:"program"}
  else {lane:"charted",why:"unclear"} end;

def lb_why_label($until):
  if . == "worker" then "With a worker"
  elif . == "ready" then "Starts automatically"
  elif . == "your-answer" then "Waits for your answer"
  elif . == "deferred" then "You put this off until \($until // "later")"
  elif . == "on-hold" then (if $until != null then "Waiting until \($until)" else "Set aside for now" end)
  elif . == "other-work" then "Waits for other work to finish first"
  elif . == "stuck" then "Stuck, needs help"
  elif . == "paused" then "Waiting on something outside the team"
  elif . == "wrap-up" then "Finished, cleanup pending"
  elif . == "program" then "Umbrella for other work"
  else "Started, but its current status cannot be read" end;

def lb_why_rank:
  {"stuck":0,"your-answer":1,"other-work":2,"on-hold":3,"deferred":4,"paused":5,
   "wrap-up":6,"unclear":7,"program":8}[.] // 9;

def lb_plural($n; $one; $many): "\($n) \(if $n == 1 then $one else $many end)";

# TIMELINE. The snapshot decides the outcome of each pull request's runs after merge and why;
# these words are the only thing the page says about it.
def lb_deploy_words:
  {"runs-succeeded":["passed","Runs after merge succeeded","Every run this change's merge started finished well."],
   "run-failed":["failed","Runs after merge failed","At least one run this change's merge started has failed."],
   "run-unfinished":["running","Runs after merge still running","A run this change's merge started has not finished yet."],
   "open":["open","Not merged yet","This change is still open; it has not been merged."],
   "waiting":["waiting","Runs after merge not started yet","Merged moments ago; its runs have not started yet."],
   "closed":["closed","Not merged","This change was closed without being merged."],
   "project":["no runs","No runs after merge for this project","Merged. This project starts no run after a merge, so there is nothing to check."],
   "change":["no runs","No run after merge for this change","Merged, but no run was started for it."],
   "superseded":["replaced","Replaced by a newer run","Merged. Its own run was cancelled because a newer run replaced it."],
   "unreadable":["unknown","Runs after merge could not be read","The runs could not be fetched, so the result is not known."],
   "too-old":["unknown","Runs after merge not available","This change is older than the run history the board reads."]}[.why]
  // ["unknown","Runs after merge could not be read","The result of the runs after merge is not known."];
def lb_run_words:
  {"succeeded":"succeeded","failed":"failed","running":"still running"}[.] // "unknown";
def lb_forge_name: {"github":"GitHub","ado":"Azure DevOps"}[.] // "the forge";
# Why a source's pull requests were not read, or null when they were. A
# local-only project has none to read.
def lb_unread_why:
  if .status == "failed" then "the read failed or took too long"
  elif .status != "none" or .reason == "local-only" then null
  elif .reason == "no-cli" then "the tool that reads \(.forge | lb_forge_name) is not installed on this machine"
  elif .reason == "unsupported-forge" then "its repository is kept somewhere the board cannot read"
  elif .reason == "no-clone" then "this home has no copy of its repository"
  else "the reason is not known" end;
# A project shows its newest pull requests, oldest first so time reads left to right.
def lb_timeline_shown: 15;

# ENVIRONMENTS. The snapshot says which environments each merged pull request
# has reached; these rules turn that into one strip per repository that has
# environments, and are the only words the page says about it.
#   last     the newest of the project's pull requests merged into that
#            environment's branch, with the outcome of the runs its merge started
#   waiting  the project's merged changes whose furthest environment is the
#            one before, newest first; a promotion is left out when the change
#            it carries is on the same list, so one change is counted once
#   direct   how many of the project's changes were merged into that
#            environment without being seen in the one before: a change redone
#            by hand arrives like this, so the waiting count may include it
# $pulls is the project's pull requests, newest first; $staged the sources
# with environments it has work in; $known whether it has any source at all.
def lb_stage_listed: 5;
def lb_stage_why:
  {"prs-unread":"its pull requests were not read","no-clone":"this home has no copy of its repository",
   "fetch-failed":"the history of its environment branches could not be fetched",
   "history-unreadable":"the history of its environment branches could not be read"}[.]
  // "the reason is not known";
def lb_environments($pulls; $staged; $known; $config):
  if $config != "ok" then {say:null,strips:[]}
  elif ($staged | length) == 0 then
    {say:(if $known then "No separate environments are set up for this project, so nothing waits to move from one to the next."
       else null end),strips:[]}
  else {say:null,strips:[$staged[] | . as $source | (.project | lb_repo) as $name | .environments.names as $names
    | if .status != "ok" then
        {repo:$name,status:"unknown",notes:[],
         say:"Not known, because the pull requests of \($name) could not be read: \(lb_unread_why // "they were not read").",
         stages:[$names[] | {name:.,kind:"unknown",label:"Not known",last:null,none:null,waiting:null}]}
      elif .environments.status != "ok" then
        {repo:$name,status:"unknown",notes:[],
         say:"Not known, because \(.environments.reason | lb_stage_why).",
         stages:[$names[] | {name:.,kind:"unknown",label:"Not known",last:null,none:null,waiting:null}]}
      else
        [$pulls[] | select(.repo == $source.project and .state == "merged" and .environment != null)] as $changes
        | [$changes[] | select(.environment.reached != null)
           | . + {top:([.environment.reached | to_entries[] | select(.value) | .key] | max // .environment.stage)}] as $placed
        | ([$changes[] | select(.environment.reached == null)] | length) as $lost
        | {repo:$name,status:"ok",say:null,
           notes:[
             "A change is seen in an environment when its merge, or a copy of it that git recorded, is in that environment's history. A change redone there by hand still shows as not yet seen.",
             (if $source.window_full then
                "Only the newest pull requests are read, so an older change that is still waiting may be missing here."
              else empty end),
             (if $lost > 0 then lb_plural($lost; "merged change"; "merged changes")
                + " could not be placed: the merge is not in the history that was read."
              else empty end)],
           stages:[range(0; $names | length) as $i
             | ([$changes[] | select(.environment.stage == $i)][0] // null) as $last
             | {name:$names[$i],
                kind:(if $last == null then "empty"
                  else $last.deploy.outcome | if IN("succeeded","failed","running","unknown") then .
                    elif . == "not-deployed" then "running" else "none" end end),
                label:(if $last == null then "No change yet" else ($last.deploy | lb_deploy_words)[1] end),
                last:(if $last == null then null else {title:$last.title,at:$last.at} end),
                none:(if $last == null then
                    "None of this project\u0027s changes was merged into \($names[$i]) in the pull requests that were read."
                  else null end),
                waiting:(if $i == 0 then null else
                  [$placed[] | select(.environment.stage < $i and .top == $i - 1)] as $all
                  | [$all[].number] as $numbers
                  | [$all[] | select(any(.environment.copy_of[]; . as $copied | $numbers | index($copied) != null) | not)] as $list
                  | ($list | length) as $count
                  | ([$placed[] | select(.environment.stage == $i and (.environment.reached[$i - 1] | not))] | length) as $direct
                  | {count:$count,
                     direct:(if $count > 0 and $direct > 0 then
                         lb_plural($direct; "change was"; "changes were") + " merged into \($names[$i]) with no recorded link to \($names[$i - 1]), so some of those listed may already be there."
                       else null end),
                     say:(if $count == 0 then "Nothing in \($names[$i - 1]) is waiting to go to \($names[$i])."
                       else lb_plural($count; "change is"; "changes are")
                         + " in \($names[$i - 1]) but not yet seen in \($names[$i])." end),
                     titles:[$list[:lb_stage_listed][] | {title,at}],
                     more:([$count - lb_stage_listed, 0] | max)} end)}]}
      end]}
  end;

# WORKERS. Every task that has a worker, in this home and in each registered
# home the snapshot read, gets one of seven plain statuses. `lb_worker_status`
# is the one rule, read top down; it only words the current state the snapshot
# already resolved and classifies nothing itself. `lb_lane` puts the task in
# Doing now on five of them and leaves `you` and `finished` in Charted next.
#   working     the worker is doing the work itself
#   validation  an automatic review of its work is running or stopped at a step
#   merge       its pull request's checks are running, or it is green and unmerged
#   you         its task holds an open question for the captain, or it asked for a decision
#   external    it paused itself on something outside the team
#   finished    it is done and not yet cleaned up
#   stuck       it is blocked, it failed, or its state cannot be read
# A working worker wins over a question on its task, as in the lanes.
def lb_worker_status:
  (.current_state // {}) as $now
  | ($now.detail // "") as $detail
  | if $now.state == "working" then
      (if $now.source != "run-step" then "working"
       elif $detail | startswith("ci running") then "merge" else "validation" end)
    elif .hold.kind == "captain" and .hold.reason != null
      and ($now.state | IN("parked","paused","blocked","done")) then "you"
    elif $now.state == "parked" then
      (if $now.source == "run-step" and ($detail | contains("ask-user: authority decision") | not)
       then "validation" else "you" end)
    elif $now.state == "paused" then "external"
    elif $now.state == "done" then
      (if $detail | test("checks green|^run passed: PR open") then "merge" else "finished" end)
    else "stuck" end;
# The status word a Doing now line shows.
def lb_worker_words:
  {"working":"Working","validation":"Waiting for validation","merge":"Waiting for a merge or CI",
   "external":"Paused on an outside wait","stuck":"Stuck or stopped"}[.];
# A worker that needs help leads its lane, then the ones nearest the work itself.
def lb_worker_rank:
  {"stuck":0,"working":1,"validation":2,"merge":3,"external":4}[.];
# One plain sentence on what that status means for this worker.
def lb_worker_say($status):
  (.current_state // {}) as $now
  | ($now.detail // "") as $detail
  | if $status == "working" then "A worker is doing this now."
    elif $status == "validation" then
      (if $now.state == "parked" then "The automatic review stopped at a step and waits for the worker to go through it."
       else "Its work is being reviewed and checked automatically." end)
    elif $status == "merge" then
      (if $now.state == "working" then "The checks on its pull request are running."
       else "Its pull request is ready and waits to be merged." end)
    elif $status == "external" then "It paused itself until something outside the team is ready."
    elif $now.state == "blocked" then "It reported that it cannot go on without help."
    elif $now.state == "failed" then "Its work failed."
    elif $detail | test("gone|no metadata") then "Its session is gone, so nothing is working on this."
    else "Its current state could not be read." end;
# The worker's own last words; a state read from anything but its own report
# has no words fit for the page.
def lb_worker_note($ids):
  (.last_meaningful_event.note
    // (if .current_state.source == "status-log" then .current_state.detail else null end))
  | lb_note($ids);
# The one sentence a Doing now line says: the worker's own last words while it
# works, or when it paused or got stuck and said so itself; else what its
# status means.
def lb_worker_doing($status; $ids):
  (if $status == "working" or (($status | IN("external","stuck")) and .current_state.source == "status-log")
   then lb_worker_note($ids) else null end)
  // lb_worker_say($status);
# The last report is when this status began only when the status was read from it.
def lb_worker_since:
  .last_meaningful_event as $event
  | ($event.emitted_at_epoch // $event.observed_at_epoch // null) as $at
  | {at:$at,
     at_is_since:($at != null and .current_state.source == "status-log"
       and {"working":"working","needs-decision":"parked","blocked":"blocked","paused":"paused",
            "done":"done","failed":"failed"}[$event.verb // ""] == .current_state.state)};
# Fleet-wide stages word only the resolved current state, never a guessed
# percentage or an old report. The per-project status rules stay unchanged.
def lb_worker_stage($status):
  if $status == "working" then "Doing the work"
  elif $status == "validation" then
    (if .current_state.state == "parked" then
       (if .current_state.detail | startswith("parked at review") then "Waiting on review"
        else "Waiting on validation" end)
     else "In validation" end)
  elif $status == "merge" then
    (if .current_state.state == "working" then "Checks running" else "Waiting for a merge" end)
  elif $status == "you" then "Waiting for a decision"
  elif $status == "external" then "Waiting outside the team"
  elif .current_state.state == "blocked" then "Needs help"
  elif .current_state.state == "failed" then "Work failed"
  else "Stopped or status unknown" end;
# Reuse Doing now's sentence, but keep operational jargon out of this section.
def lb_running_doing($status; $ids):
  if $status == "you" then "Waiting for an answer before work can continue."
  else lb_worker_doing($status; $ids) as $say
    | if $say | test("\\b(no-mistakes|pipeline|harness|run-step|status-log|worktree|daemon|tmux|herdr|codex|claude|opencode|pi|gate|axi|awaiting_approval|fix_review|checks-passed)\\b"; "i")
      then lb_worker_say($status) else $say end
  end;
def lb_home_name: gsub("[-_.]+"; " ") | (.[:1] | ascii_upcase) + .[1:];
def lb_home_unread_why:
  if .status == "remote" then "that home is on another machine"
  elif .status == "invalid" then "its registration could not be checked"
  else "the read failed or took too long" end;
# How old a second mate's last good read is, for work shown from it.
def lb_as_of($seconds):
  "as of " + (if $seconds < 60 then "less than a minute"
    elif $seconds < 5400 then lb_plural($seconds / 60 | round; "minute"; "minutes")
    elif $seconds < 172800 then lb_plural($seconds / 3600 | round; "hour"; "hours")
    else lb_plural($seconds / 86400 | round; "day"; "days") end) + " ago";
def lb_home_as_of($board):
  if .status == "stale" then lb_as_of(($board.collected_at_epoch // 0) - (.collected_at_epoch // 0)) else null end;

# Delivery posture is registered per repository, not per named project group
# or per task. Both sections consume the same snapshot, including idle projects.
def lb_delivery_row($home; $as_of):
  .registration as $r
  | {project:(.name | lb_repo // "Unassigned"),home:$home,home_as_of:$as_of,
     registration:(if $r == null then "Unregistered"
       elif $r.recognised == false then "Unrecognized setting; using defaults" else "Registered" end),
     mode:({"no-mistakes":"No-mistakes","direct-PR":"Direct PR","local-only":"Local only",
            "no-mistakes-prod-only":"No-mistakes for product work; Direct PR for internal work"}[$r.mode // "no-mistakes"] // "No-mistakes"),
     approval:(if $r.yolo == "on" then "Automatic merging when checks pass" else "Your approval required to merge" end),
     flags:[($r.flags // [])[] | select(. == "preview-on-push") | "Preview builds when changes are published"]};

def lb_view($map):
. as $board
| ($map | if . != null and lb_valid_map then . else null end) as $named
| ($board.registered_homes // []) as $homes
| ([$board.projects[].tasks[].id, $board.recently_finished[]?.id, ($homes[] | .workers[], .queued[]? | .id)]
   | map({key:.,value:true}) | from_entries) as $ids
| ([$board.projects[].tasks[] | {key:.id,value:.title}] | from_entries) as $titles
| (($board.collected_at // "") | .[:10]) as $today
| def group_of($id; $project):
    ($project | lb_repo) as $repo
    | (if $named == null then null
       else first($named.projects | to_entries[]
         | select(any(.value.match[];
             ((has("id") | not) or (.id as $pattern | $id | lb_glob($pattern))) and ((has("repo") | not) or .repo == $repo)))
         | .key) // null end) as $index
    | if $index != null then {key:"project:\($index)",index:$index}
      else {key:"repo:\($repo // "")",index:null,repo:$repo} end;
  [$board.projects[] | .questions[] | . as $q | group_of(.id; .project) + {question:$q}] as $asked
# A registered home's workers and queued work sit in their project's lanes
# beside this home's, each line naming its second mate, and the age of its last
# good read when this build could not read that home.
| ([$board.projects[] | .tasks[] | . as $t | group_of(.id; .project) + {task:$t,home:null,as_of:null}]
   + [$homes[] | (.label | lb_home_name) as $home | lb_home_as_of($board) as $as_of | (.workers[], .queued[]?) | . as $t
      | group_of(.id; .project) + {task:$t,home:$home,as_of:$as_of}]) as $placed
| [($board.recently_finished // [])[] | . as $f | group_of(.id; .project) + {finished:$f}] as $done
| [($board.pull_requests.repos // [])[] | . as $repo | ($repo.prs // [])[] | . as $pr
   | group_of($pr.task // ""; $repo.project) + {pr:($pr + {forge:$repo.forge,repo:$repo.project})}] as $merged
| [($board.pull_requests.repos // [])[] | select(.environments != null)] as $staged
| [($board.pull_requests.repos // [])[] | lb_unread_why as $why | select($why != null)
   | {repo:.project,say:"Pull requests for \(.project | lb_repo // "a project") could not be read: \($why)."}] as $unread
| ([$asked[], $placed[], $done[], $merged[] | {key,index,repo}]
   + if $named != null then [$named.projects | to_entries[] | {key:"project:\(.key)",index:.key,repo:null}]
     else [$board.projects[] | (.name | lb_repo) as $repo | {key:"repo:\($repo // "")",index:null,repo:$repo}] end
   | unique_by(.key)) as $keys
| [$keys[] as $g
   | [$asked[] | select(.key == $g.key) | .question] as $questions
   | [$done[] | select(.key == $g.key) | .finished] as $finished
   | [$placed[] | select(.key == $g.key) | .home as $home | .as_of as $as_of | .task as $t
      | (if $t.worker_present == true then $t | lb_worker_status else null end) as $crew
      | ($t | lb_lane($today; $crew)) as $l
      | lb_explain($ids; $t.about; $t.question_context.about; $t.hold.reason) as $what
      | {key:$t.key,id:$t.id,title:($t.title | lb_title($ids) // "Untitled work"),home:$home,home_as_of:$as_of,
         lane:$l.lane,why:$l.why,why_label:($l.why | lb_why_label($t.hold.until)),state:$t.state,
         explain:$what.text,explain_source:$what.source,
         note:(if $l.lane == "doing" then ($t | lb_worker_doing($crew; $ids))
           elif $l.why == "on-hold" then ($t.hold.reason | lb_note($ids))
           elif $l.why == "other-work" then
             ([($t.unresolved_blockers // [])[] | (if $home == null then $titles[.] else null end) // empty
               | lb_title($ids) // empty] | .[:2]
              | if length > 0 then "Waits for: " + join("; ") else null end)
           elif $l.why | IN("your-answer","deferred","ready","program") then null
           else (($t.last_meaningful_event.note // $t.current_state.detail) | lb_note($ids)) end),
         at:(if $t.worker_present then
             ($t.last_meaningful_event.emitted_at_epoch // $t.last_meaningful_event.observed_at_epoch // null)
           else null end),
         pr:$t.pr.url,priority:$t.priority,since:$t.since}
        + (if $l.lane == "doing" then
             {status:$crew,status_label:($crew | lb_worker_words),at_is_since:($t | lb_worker_since.at_is_since),
              report:($t | lb_worker_note($ids))}
           else {} end)
      | if .lane == "doing" then . else .report = .note end] as $rows
   | ([$rows[] | select(.report != null and .at != null)] | max_by(.at)) as $latest
   | {doing:([$rows[] | select(.lane == "doing")] | sort_by([(.status | lb_worker_rank),-(.at // 0),.title,.key])),
      next:([$rows[] | select(.lane == "next")] | sort_by([.priority // 5,.since // "9999",.id,.key])),
      charted:([$rows[] | select(.lane == "charted")] | sort_by([(.why | lb_why_rank),.since // "9999",.id,.key]))}
     | map_values(map(del(.priority,.since,.report))) as $lanes
   | ([$merged[] | select(.key == $g.key) | .pr] | sort_by([-(.at // 0),-.number,.url])) as $pulls
   # A repository that was not read may hold this project's pull requests when
   # it is this repository, a rule names it, or a rule matches by task id alone.
   | [$unread[] | select((.repo | lb_repo) as $repo
        | if $g.index == null then $g.repo == $repo
          else any($named.projects[$g.index].match[]; (has("repo") | not) or .repo == $repo) end)] as $gaps
   # The repositories this project has work in, by any of the ways work is placed.
   | ([$g.repo // empty]
      + (if $g.index != null then [$named.projects[$g.index].match[] | .repo // empty] else [] end)
      + [$placed[] | select(.key == $g.key) | .task.project | lb_repo // empty]
      + [$done[] | select(.key == $g.key) | .finished.project | lb_repo // empty]
      + [$merged[] | select(.key == $g.key) | .pr.repo | lb_repo // empty]
      | map(select(length > 0)) | unique) as $homes
   | ({questions:($questions|length),urgent:([$questions[] | select(.urgent)]|length),
      doing:($lanes.doing|length),next:($lanes.next|length),charted:($lanes.charted|length),
      stuck:([$lanes.charted[] | select(.why == "stuck")]|length),
      stopped:([$lanes.doing[] | select(.status == "stuck")]|length),finished:($finished|length)}
      | .stuck += .stopped) as $c
   | {key:$g.key,source:(if $g.index != null then "map" else "repo" end),
      name:(if $g.index != null then $named.projects[$g.index].name else ($g.repo // "Unsorted work") end),
      description:(if $g.index != null then ($named.projects[$g.index].description // null)
        elif $named != null then "Not yet sorted into a named project" else null end),
      explain:((if $g.index != null then $named.projects[$g.index].description else null end) // lb_no_explanation),
      order:$g.index,counts:$c,active:($c.questions + $c.doing + $c.next + $c.charted > 0),
      status:([
          if $c.questions > 0 then lb_plural($c.questions; "question waits"; "questions wait") + " for you"
            + if $c.urgent > 0 then " (\($c.urgent) urgent)" else "" end
          else empty end,
          if $c.doing > 0 then "\($c.doing) with a worker"
            + if $c.stopped > 0 then " (\($c.stopped) stuck or stopped)" else "" end
          else empty end,
          if $c.next > 0 then "\($c.next) starting automatically" else empty end,
          if $c.charted > 0 then "\($c.charted) not starting on \(if $c.charted == 1 then "its" else "their" end) own"
            + if $c.stuck > $c.stopped then " (\($c.stuck - $c.stopped) stuck)" else "" end
          else empty end]
        | if length == 0 then (if $c.finished > 0 then "Quiet, recent work finished" else "Nothing running" end)
          else join(", ") | (.[:1] | ascii_upcase) + .[1:] end),
      latest:(if $latest == null then null else {title:$latest.title,note:$latest.report,at:$latest.at} end),
      last_finished:($finished[0] // null | if . == null then null
        else {title:(.title | lb_title($ids) // "Untitled work"),finished} end),
      questions:[$questions[] | . as $q
        | ($q.context // null) as $ctx
        | {key:$q.key,id:$q.id,urgent:$q.urgent,priority:$q.priority,
           text:($ctx.question // ($q.title | lb_title($ids)) // "Question without a title"),
           topic:(if $ctx.question != null then ($q.title | lb_title($ids)) else null end),
           about:($ctx.about // null),purpose:($ctx.purpose // null),
           needs_explanation:($ctx.about == null or $ctx.purpose == null),
           why:($q.hold.reason | lb_clean($ids)),
           asked:($q.hold.set // $q.since),deferred_until:(if $q | lb_deferred($today) then $q.hold.until else null end),
           waiting_on_other_work:(($q.unresolved_blockers // []) | length > 0),
           mode:(if $q.answerable and $ctx != null and ($ctx.close | IN("done","release")) and $ctx.lifecycle != null then
               (if ($ctx.options | length) > 0 then "options" else "text" end)
             elif $q.context_status == "legacy" and ($q.integrity | length) == 0 then "free-text"
             else "read-only" end),
           readonly:(if $q.answerable then null
             elif ($q.integrity | length) > 0 then "ambiguous" else $q.context_status end),
           close:($ctx.close // null),lifecycle:($ctx.lifecycle // null),
           recommendation:($ctx.recommendation // null),
           options:[($ctx.options // [])[] | {value:.value,label:.label,detail:(.detail // null)}]}],
      timeline:{
        status:(if $board.pull_requests.status == "collected" then "ok"
          else ($board.pull_requests.status // "not-collected") end),
        total:($pulls|length),unread:$gaps,
        items:[$pulls[:lb_timeline_shown] | reverse[] | (.deploy | lb_deploy_words) as $words
          | {key:.url,number,url,forge:(.forge | lb_forge_name),state,draft,title,summary,at,
             state_label:(if .state == "merged" then "Merged" elif .state == "closed" then "Closed without merging"
               elif .draft then "Open, still a draft" else "Open" end),
             deploy:{outcome:.deploy.outcome,tag:$words[0],label:$words[1],detail:$words[2],
               runs:[.deploy.runs[] | {name,result,label:(.result | lb_run_words)}],more_runs:.deploy.more_runs}}]},
      environments:lb_environments($pulls;
        [$staged[] | select((.project | lb_repo) as $repo | $homes | index($repo) != null)];
        ($homes | length) > 0; $board.pull_requests.environment_config // "absent"),
      lanes:$lanes}]
| sort_by([(if .counts.urgent > 0 then 0 elif .counts.questions > 0 then 1
      elif .counts.stuck > 0 then 2 elif .counts.doing > 0 then 3 elif .active then 4 else 5 end),
    (if .order == null then 1 else 0 end),(.order // 0),(.name | ascii_downcase),.key]) as $groups
# Every unfinished worker, the ones that need someone first, then nearest the work.
| ([$placed[] | . as $p | .task as $t | select($t.worker_present)
   | ($t | lb_worker_status) as $status | select($status != "finished")
   | ($t | lb_worker_since) as $since
   | {key:$t.key,id:$t.id,title:($t.title | lb_title($ids) // "Untitled work"),
      project:([$groups[] | select(.key == $p.key) | .name][0]),
      home:$p.home,home_as_of:$p.as_of,status:$status,
      doing:($t | lb_running_doing($status; $ids)),stage:($t | lb_worker_stage($status)),
      at:$since.at,at_is_since:$since.at_is_since}]
   | sort_by([({"stuck":0,"you":1}[.status] // (.status | lb_worker_rank) + 2),
       (.project | ascii_downcase), .title, .key])) as $crew
# Pull requests merged in the 24 hours before collection, newest first, each
# under the project its timeline shows it in.
| ([$merged[] | .key as $key | .pr
    | select(.state == "merged" and (.at // 0) >= ($board.collected_at_epoch // 0) - 86400)
    | (.deploy | lb_deploy_words) as $words
    | {key:.url,project:([$groups[] | select(.key == $key) | .name][0]),title,url,
       forge:(.forge | lb_forge_name),at,tag:$words[0],label:$words[1]}]
   | unique_by(.key) | sort_by([-.at, .project, .key])) as $landed
| {schema:"fm-live-board-view.v1",
   grouping:(if $map == null then "repo" elif $named == null then "invalid-map" else "map" end),
   counts:{questions:([$groups[].counts.questions]|add // 0),urgent:([$groups[].counts.urgent]|add // 0),
     active_projects:([$groups[] | select(.active)]|length),
     doing:([$groups[].counts.doing]|add // 0),next:([$groups[].counts.next]|add // 0),
     charted:([$groups[].counts.charted]|add // 0),stuck:([$groups[].counts.stuck]|add // 0),
     finished:([$groups[].counts.finished]|add // 0),
     running:([$crew[] | select(.status | IN("working","validation","merge"))]|length),
     outside:([$crew[] | select(.status == "external")]|length),
     landed:($landed|length)},
   notes:[
     if $map != null and $named == null then
       "The project map is invalid, so work is grouped by repository until Firstmate fixes it." else empty end,
     ([$groups[].questions[] | select(.needs_explanation)] | length) as $bare
     | if $bare > 0 then lb_plural($bare; "question still needs"; "questions still need")
         + " a plain-language explanation from Firstmate." else empty end,
     (if $board.pull_requests.status == "unreadable" then
        "The pull request data could not be read, so the timelines are empty." else empty end),
     $unread[].say,
     (if $board.pull_requests.environment_config == "invalid" then
        "The environment list is invalid, so no project shows its environments until Firstmate fixes it." else empty end),
     ([$groups[] | .lanes[][] | select(.explain_source == "missing")] | length) as $unexplained
     | (if $unexplained > 0 then lb_plural($unexplained; "item has"; "items have")
         + " no explanation recorded yet; Firstmate adds one by giving the task a note." else empty end),
     ($board.omissions[]? | .kind as $k
       | if $k == "backlog-unavailable" then "The task list could not be read, so some work may be missing."
         elif $k == "registry-unavailable" then "The project registry could not be read."
         elif $k == "registered-homes-uncollected" then
           (if any($homes[]; .status != "collected") then empty
            else "Not every second mate\u0027s work could be read, so some project lanes may be missing lines." end)
         elif $k == "unstructured-open-work" then "\(.count) open task lines are not structured and are not shown."
         else "Coverage gap: \($k | gsub("-"; " "))" end),
     ($homes[] | select(.status != "collected")
       | if .status == "stale" then
           "The work of second mate \(.label | lb_home_name) is shown \(lb_home_as_of($board)), from its last good read: \(lb_home_unread_why) this time."
         else "The work of second mate \(.label | lb_home_name) is not shown: \(lb_home_unread_why)." end),
     ($board.warnings // [] | map(select(.kind != "question-needs-owner-review")) | group_by(.kind)[]
       | "\(length) board warning\(if length == 1 then "" else "s" end) for Firstmate: \(.[0].kind | gsub("-"; " "))")],
   workers:$crew,
   landed:$landed,
   delivery:([$board.projects[] | lb_delivery_row(null; null)]
     + [$homes[] | (.label | lb_home_name) as $home | lb_home_as_of($board) as $as_of
        | .projects[]? | lb_delivery_row($home; $as_of)]
     | group_by([.project,.home])
     | map((map(select(.registration == "Registered"))[0]
         // map(select(.registration != "Unregistered"))[0] // .[0]))
     | sort_by([(.project | ascii_downcase), .home // ""])),
   projects:$groups};
