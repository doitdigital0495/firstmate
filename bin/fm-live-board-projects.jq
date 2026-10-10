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

def lb_state_label:
  if . == "working" then "In progress"
  elif . == "blocked" or . == "parked" then "Stuck"
  elif . == "paused" then "Paused"
  elif . == "finished-awaiting-processing" then "Finished, being wrapped up"
  elif . == "held" then "On hold"
  elif . == "program" then "Program"
  else "In flight" end;

def lb_plural($n; $one; $many): "\($n) \(if $n == 1 then $one else $many end)";

def lb_view($map):
. as $board
| ($map | if . != null and lb_valid_map then . else null end) as $named
| ([$board.projects[].tasks[].id, $board.recently_finished[]?.id]
   | map({key:.,value:true}) | from_entries) as $ids
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
| ([$asked[].question.key] | map({key:.,value:true}) | from_entries) as $asked_keys
| [$board.projects[] | .tasks[] | select($asked_keys[.key] | not) | . as $t | group_of(.id; .project) + {task:$t}] as $placed
| [($board.recently_finished // [])[] | . as $f | group_of(.id; .project) + {finished:$f}] as $done
| ([$asked[], $placed[], $done[] | {key,index,repo}]
   + if $named != null then [$named.projects | to_entries[] | {key:"project:\(.key)",index:.key,repo:null}]
     else [$board.projects[] | (.name | lb_repo) as $repo | {key:"repo:\($repo // "")",index:null,repo:$repo}] end
   | unique_by(.key)) as $keys
| [$keys[] as $g
   | [$asked[] | select(.key == $g.key) | .question] as $questions
   | [$placed[] | select(.key == $g.key) | .task] as $tasks
   | [$tasks[] | select(.worker_present or .backlog_state == "in_flight")] as $working_rows
   | [$tasks[] | select((.worker_present or .backlog_state == "in_flight") | not)] as $waiting
   | [$done[] | select(.key == $g.key) | .finished] as $finished
   | [$working_rows[] | . as $t
      | {key:$t.key,id:$t.id,title:($t.title | lb_title($ids) // "Untitled work"),state:$t.state,
         state_label:($t.state | lb_state_label),
         note:(($t.last_meaningful_event.note // $t.current_state.detail) | lb_note($ids)),
         at:($t.last_meaningful_event.emitted_at_epoch // $t.last_meaningful_event.observed_at_epoch // null),
         pr:$t.pr.url}] as $workers
   | {questions:($questions|length),urgent:([$questions[] | select(.urgent)]|length),
      workers:($workers|length),working:([$workers[] | select(.state == "working")]|length),
      stuck:([$workers[] | select(.state | IN("blocked","parked"))]|length),
      wrapping_up:([$workers[] | select(.state == "finished-awaiting-processing")]|length),
      finished:($finished|length),waiting:($waiting|length)} as $c
   | ([$workers[] | select(.note != null and .at != null)] | max_by(.at)) as $latest
   | {key:$g.key,source:(if $g.index != null then "map" else "repo" end),
      name:(if $g.index != null then $named.projects[$g.index].name else ($g.repo // "Unsorted work") end),
      description:(if $g.index != null then ($named.projects[$g.index].description // null)
        elif $named != null then "Not yet sorted into a named project" else null end),
      order:$g.index,counts:$c,active:($c.questions > 0 or $c.workers > 0),
      status:([
          if $c.questions > 0 then lb_plural($c.questions; "question waits"; "questions wait") + " for you"
            + if $c.urgent > 0 then " (\($c.urgent) urgent)" else "" end
          else empty end,
          if $c.stuck > 0 then "\($c.stuck) stuck" else empty end,
          if $c.working > 0 then "\($c.working) busy" else empty end,
          if $c.wrapping_up > 0 then "\($c.wrapping_up) finished and being wrapped up" else empty end,
          ([$workers[] | select(.state == "paused")] | length) as $paused
          | if $paused > 0 then "\($paused) paused" else empty end,
          ($c.workers - $c.stuck - $c.working - $c.wrapping_up - ([$workers[] | select(.state == "paused")] | length)) as $other
          | if $other > 0 then "\($other) in flight" else empty end]
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
           asked:($q.hold.set // $q.since),deferred_until:(if $q.hold.until != null and $q.hold.bucket != "live" then $q.hold.until else null end),
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
      workers:$workers}]
| sort_by([(if .counts.urgent > 0 then 0 elif .counts.questions > 0 then 1
      elif .counts.stuck > 0 then 2 elif .active then 3 else 4 end),
    (if .order == null then 1 else 0 end),(.order // 0),(.name | ascii_downcase),.key]) as $groups
| {schema:"fm-live-board-view.v1",
   grouping:(if $map == null then "repo" elif $named == null then "invalid-map" else "map" end),
   counts:{questions:([$groups[].counts.questions]|add // 0),urgent:([$groups[].counts.urgent]|add // 0),
     active_projects:([$groups[] | select(.active)]|length),
     working:([$groups[].counts.working]|add // 0),stuck:([$groups[].counts.stuck]|add // 0),
     finished:([$groups[].counts.finished]|add // 0)},
   notes:[
     if $map != null and $named == null then
       "The project map is invalid, so work is grouped by repository until Firstmate fixes it." else empty end,
     ([$groups[].questions[] | select(.needs_explanation)] | length) as $bare
     | if $bare > 0 then lb_plural($bare; "question still needs"; "questions still need")
         + " a plain-language explanation from Firstmate." else empty end,
     ($board.omissions[]? | .kind as $k
       | if $k == "backlog-unavailable" then "The task list could not be read, so some work may be missing."
         elif $k == "registry-unavailable" then "The project registry could not be read."
         elif $k == "registered-homes-uncollected" then "Work run from other Firstmate homes is not on this board."
         elif $k == "unstructured-open-work" then "\(.count) open task lines are not structured and are not shown."
         else "Coverage gap: \($k | gsub("-"; " "))" end),
     ($board.warnings // [] | map(select(.kind != "question-needs-owner-review")) | group_by(.kind)[]
       | "\(length) board warning\(if length == 1 then "" else "s" end) for Firstmate: \(.[0].kind | gsub("-"; " "))")],
   projects:$groups};
