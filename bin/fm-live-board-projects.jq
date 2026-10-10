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
def lb_note($ids):
  lb_clean($ids)
  | if . == null then null else
      (if length > 160 then .[:157] + "..." else . end)
      | ([splits("\\s+") | select(length > 0)]) as $tokens
      | if ([$tokens[] | select(test("^[(\"']?[A-Za-z][a-z]*[)\"',.;:!?]*$"))] | length) * 2 < ($tokens | length)
          or length < 15 then null else . end
    end;
# A title that is only a task id reads as words instead.
def lb_title($ids):
  if type != "string" then null
  elif $ids[.] then (gsub("[-_.]+"; " ") | (.[:1] | ascii_upcase) + .[1:])
  else lb_clean($ids) end;

# LANES. The one rule that puts every open task in exactly one lane, read top
# down; `why` names the reason and is the only thing the wording below keys on.
#   doing    a worker is working on it right now
#   next     not started and nothing in its way, so a worker starts it on its own
#   charted  will not start or move on its own; `why` says what it waits for
# $today is the collection date; a dated hold that is not the captain's lapses
# on that date, exactly as the backlog stops treating it as a hold.
def lb_deferred($today): .hold.until != null and .hold.until > $today;
def lb_lane($today):
  if .worker_present == true and .state == "working" then {lane:"doing",why:"working"}
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
  if . == "working" then "Being done now"
  elif . == "ready" then "Starts on its own"
  elif . == "your-answer" then "Waits for your answer"
  elif . == "deferred" then "You put this off until \($until // "later")"
  elif . == "on-hold" then (if $until != null then "Waiting until \($until)" else "Set aside for now" end)
  elif . == "other-work" then "Waits for other work to finish first"
  elif . == "stuck" then "Stuck, needs help"
  elif . == "paused" then "Waiting on something outside the team"
  elif . == "wrap-up" then "Finished, waiting to be wrapped up"
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

def lb_view($map):
. as $board
| ($map | if . != null and lb_valid_map then . else null end) as $named
| ([$board.projects[].tasks[].id, $board.recently_finished[]?.id]
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
| [$board.projects[] | .tasks[] | . as $t | group_of(.id; .project) + {task:$t}] as $placed
| [($board.recently_finished // [])[] | . as $f | group_of(.id; .project) + {finished:$f}] as $done
| [($board.pull_requests.repos // [])[] | . as $repo | ($repo.prs // [])[] | . as $pr
   | group_of($pr.task // ""; $repo.project) + {pr:($pr + {forge:$repo.forge})}] as $merged
| [($board.pull_requests.repos // [])[] | lb_unread_why as $why | select($why != null)
   | {repo:.project,say:"Pull requests for \(.project | lb_repo // "a project") could not be read: \($why)."}] as $unread
| ([$asked[], $placed[], $done[], $merged[] | {key,index,repo}]
   + if $named != null then [$named.projects | to_entries[] | {key:"project:\(.key)",index:.key,repo:null}]
     else [$board.projects[] | (.name | lb_repo) as $repo | {key:"repo:\($repo // "")",index:null,repo:$repo}] end
   | unique_by(.key)) as $keys
| [$keys[] as $g
   | [$asked[] | select(.key == $g.key) | .question] as $questions
   | [$done[] | select(.key == $g.key) | .finished] as $finished
   | [$placed[] | select(.key == $g.key) | .task | . as $t | lb_lane($today) as $l
      | {key:$t.key,id:$t.id,title:($t.title | lb_title($ids) // "Untitled work"),
         lane:$l.lane,why:$l.why,why_label:($l.why | lb_why_label($t.hold.until)),state:$t.state,
         note:(if $l.why == "on-hold" then ($t.hold.reason | lb_note($ids))
           elif $l.why == "other-work" then
             ([($t.unresolved_blockers // [])[] | $titles[.] // empty | lb_title($ids) // empty] | .[:2]
              | if length > 0 then "Waits for: " + join("; ") else null end)
           elif $l.why | IN("your-answer","deferred","ready","program") then null
           else (($t.last_meaningful_event.note // $t.current_state.detail) | lb_note($ids)) end),
         at:(if $t.worker_present then
             ($t.last_meaningful_event.emitted_at_epoch // $t.last_meaningful_event.observed_at_epoch // null)
           else null end),
         pr:$t.pr.url,priority:$t.priority,since:$t.since}] as $rows
   | {doing:([$rows[] | select(.lane == "doing")] | sort_by([-(.at // 0),.title,.key])),
      next:([$rows[] | select(.lane == "next")] | sort_by([.priority // 5,.since // "9999",.id,.key])),
      charted:([$rows[] | select(.lane == "charted")] | sort_by([(.why | lb_why_rank),.since // "9999",.id,.key]))}
     | map_values(map(del(.priority,.since))) as $lanes
   | ([$merged[] | select(.key == $g.key) | .pr] | sort_by([-(.at // 0),-.number,.url])) as $pulls
   # A repository that was not read may hold this project's pull requests when
   # it is this repository, a rule names it, or a rule matches by task id alone.
   | [$unread[] | select((.repo | lb_repo) as $repo
        | if $g.index == null then $g.repo == $repo
          else any($named.projects[$g.index].match[]; (has("repo") | not) or .repo == $repo) end)] as $gaps
   | {questions:($questions|length),urgent:([$questions[] | select(.urgent)]|length),
      doing:($lanes.doing|length),next:($lanes.next|length),charted:($lanes.charted|length),
      stuck:([$lanes.charted[] | select(.why == "stuck")]|length),finished:($finished|length)} as $c
   | ([$rows[] | select(.note != null and .at != null)] | max_by(.at)) as $latest
   | {key:$g.key,source:(if $g.index != null then "map" else "repo" end),
      name:(if $g.index != null then $named.projects[$g.index].name else ($g.repo // "Unsorted work") end),
      description:(if $g.index != null then ($named.projects[$g.index].description // null)
        elif $named != null then "Not yet sorted into a named project" else null end),
      order:$g.index,counts:$c,active:($c.questions + $c.doing + $c.next + $c.charted > 0),
      status:([
          if $c.questions > 0 then lb_plural($c.questions; "question waits"; "questions wait") + " for you"
            + if $c.urgent > 0 then " (\($c.urgent) urgent)" else "" end
          else empty end,
          if $c.doing > 0 then "\($c.doing) being done now" else empty end,
          if $c.next > 0 then "\($c.next) starting next" else empty end,
          if $c.charted > 0 then "\($c.charted) not starting on \(if $c.charted == 1 then "its" else "their" end) own"
            + if $c.stuck > 0 then " (\($c.stuck) stuck)" else "" end
          else empty end]
        | if length == 0 then (if $c.finished > 0 then "Quiet, recent work finished" else "Nothing running" end)
          else join(", ") | (.[:1] | ascii_upcase) + .[1:] end),
      latest:(if $latest == null then null else {title:$latest.title,note:$latest.note,at:$latest.at} end),
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
      lanes:$lanes}]
| sort_by([(if .counts.urgent > 0 then 0 elif .counts.questions > 0 then 1
      elif .counts.stuck > 0 then 2 elif .counts.doing > 0 then 3 elif .active then 4 else 5 end),
    (if .order == null then 1 else 0 end),(.order // 0),(.name | ascii_downcase),.key]) as $groups
| {schema:"fm-live-board-view.v1",
   grouping:(if $map == null then "repo" elif $named == null then "invalid-map" else "map" end),
   counts:{questions:([$groups[].counts.questions]|add // 0),urgent:([$groups[].counts.urgent]|add // 0),
     active_projects:([$groups[] | select(.active)]|length),
     doing:([$groups[].counts.doing]|add // 0),next:([$groups[].counts.next]|add // 0),
     charted:([$groups[].counts.charted]|add // 0),stuck:([$groups[].counts.stuck]|add // 0),
     finished:([$groups[].counts.finished]|add // 0)},
   notes:[
     if $map != null and $named == null then
       "The project map is invalid, so work is grouped by repository until Firstmate fixes it." else empty end,
     ([$groups[].questions[] | select(.needs_explanation)] | length) as $bare
     | if $bare > 0 then lb_plural($bare; "question still needs"; "questions still need")
         + " a plain-language explanation from Firstmate." else empty end,
     (if $board.pull_requests.status == "unreadable" then
        "The pull request data could not be read, so the timelines are empty." else empty end),
     $unread[].say,
     ($board.omissions[]? | .kind as $k
       | if $k == "backlog-unavailable" then "The task list could not be read, so some work may be missing."
         elif $k == "registry-unavailable" then "The project registry could not be read."
         elif $k == "registered-homes-uncollected" then "Work run from other Firstmate homes is not on this board."
         elif $k == "unstructured-open-work" then "\(.count) open task lines are not structured and are not shown."
         else "Coverage gap: \($k | gsub("-"; " "))" end),
     ($board.warnings // [] | map(select(.kind != "question-needs-owner-review")) | group_by(.kind)[]
       | "\(length) board warning\(if length == 1 then "" else "s" end) for Firstmate: \(.[0].kind | gsub("-"; " "))")],
   projects:$groups};
