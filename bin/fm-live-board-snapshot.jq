# The fm-live-board.v1 projection; its executable wrapper owns the public contract.
def valid_input:
  .schema == "fm-live-board-input.v1"
  and (.fm_home | type == "string")
  and (.generated | type == "string") and (.generated_epoch | type == "number")
  and (.collection_duration_seconds | type == "number")
  and (.registry.present | type == "boolean")
  and (.registry.projects | type == "array") and (.registry.duplicates | type == "array")
  and (.backlog.present | type == "boolean") and (.backlog.records | type == "array")
  and (.tasks | type == "array") and (.main_inventory | type == "object")
  and (.coverage.local.complete | type == "boolean")
  and (.coverage.registered_homes.complete | type == "boolean")
  and all(.backlog.records[]; (.state | IN("in_flight","queued","done"))
    and (.structured | type == "boolean")
    and (if .structured then (.id | type == "string" and length > 0)
      and (.order | type == "number") else true end))
  and all(.tasks[]; (.id | type == "string" and length > 0)
    and (.current_state | type == "object") and (.hints.open_decisions | type == "array"));
def priority:
  if type == "string" and test("^[0-4]$") then tonumber
  elif type == "number" and . >= 0 and . <= 4 and floor == . then . else null end;
def date_key:
  if type != "string" then null
  elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then try (. + "T00:00:00Z" | fromdateiso8601) catch null
  else try fromdateiso8601 catch null end;
def pr_url:
  if type == "string" and test("^https://[A-Za-z0-9.-]+(?::[0-9]+)?/[^[:space:]<>\"?#]+/pull/[0-9]+$")
  then . else null end;
def nonempty: if type == "string" and length > 0 then . else null end;
def counts($tasks; $questions):
  {open_tasks:($tasks|length),questions:($questions|length),
   urgent_questions:([$questions[] | select(.urgent)]|length),
   working:([$tasks[] | select(.state == "working")]|length),
   blocked:([$tasks[] | select(.state == "blocked" or .state == "parked")]|length),
   queued:([$tasks[] | select(.state == "queued")]|length),
   unknown:([$tasks[] | select(.state == "unknown")]|length)};
def task_band:
  if .state == "blocked" or .state == "parked" then 0
  elif .state == "working" then 1 elif .state == "finished-awaiting-processing" then 2
  elif .state == "paused" then 3 elif .state == "queued" then 4 else 5 end;
if valid_input then . else error("unsupported or malformed fm-live-board-input.v1") end
| . as $input
| [.backlog.records[] | select(.structured and .state != "done")] as $open
| [.backlog.records[] | select(.structured)] as $backlog
| [.tasks[] as $worker
   | select(any($backlog[]; .id == $worker.id) | not)
   | {id:$worker.id,order:null,state:null,structured:true}] as $meta_only
| ($open + $meta_only | map(. as $row
    | ([$input.tasks[] | select(.id == $row.id)][0] // null) as $worker
    | ($row.repo | nonempty) as $repo
    | ($worker.project | nonempty) as $meta_project
    | ($repo // $meta_project) as $project
    | ($row.state == "queued" and $worker == null) as $queued
    | ($row.kind // $worker.kind // "unknown") as $kind
    | (if $queued then "queued"
       elif $worker != null then
         if $worker.current_state.state == "done" then "finished-awaiting-processing"
         else ($worker.current_state.state // "unknown") end
       elif $row.current_role == "held" then "held"
       elif $row.current_role == "program" then "program" else "unknown" end) as $state
    | {key:([$home_key,$row.id,($row.order // "meta" | tostring)] | tojson),
       id:$row.id,home_key:$home_key,project:$project,title:($row.title // $row.id),kind:$kind,
       backlog_state:$row.state,role:($row.current_role // "worker"),state:$state,
       current_state:(if $worker == null then null else
         $worker.current_state | {state,source,detail:((.detail // "")[:240]),observed_at,freshness} end),
       owner:(if $worker == null then null else {harness:$worker.harness,kind:$worker.kind} end),
       worker_present:($worker != null),since:$row.since,priority:($row.priority | priority),
       blockers:($row.blocked_by_ids // []),unresolved_blockers:($row.unresolved_blocker_ids // []),
       hold:{kind:$row.hold_kind,reason:$row.hold_reason,bucket:$row.hold_bucket,
         until:$row.hold_until,set:$row.hold_set,age_days:$row.hold_age_days},
       pr:{url:(($worker.pr.url // $row.pr_url) | pr_url),
         source:(if $worker.pr.url != null then $worker.pr.source
           elif $row.pr_url != null then "backlog" else "absent" end)},
       last_meaningful_event:(if $worker.last_meaningful_event == null then null else
         $worker.last_meaningful_event | {type,verb,name,note,emitted_at_epoch,observed_at_epoch,age_seconds} end),
       integrity:[
         if $repo != null and $meta_project != null and $repo != $meta_project then
           {kind:"project-conflict",backlog_project:$repo,metadata_project:$meta_project} else empty end,
         if $row.requires_child_metadata == true and $worker == null then
           {kind:"missing-worker-metadata"} else empty end,
         if $row.state == null then {kind:"metadata-without-backlog"} else empty end,
         if ([$backlog[] | select(.id == $row.id)] | length) > 1 then
           {kind:"duplicate-backlog-id"} else empty end],
       unregistered_decisions:(if $row.hold_kind == "captain" and $row.hold_reason != null then []
         else ($worker.hints.open_decisions // [] | map({key,verb,summary:((.summary // "")[:240])})) end)})) as $tasks
| [$tasks[] | select(.hold.kind == "captain" and .hold.reason != null)
   | {key:.key,id:.id,home_key:.home_key,project:.project,title:.title,
      priority:.priority,urgent:(.priority == 0 or .priority == 1),
      since:.since,hold:.hold,blockers:.blockers,unresolved_blockers:.unresolved_blockers,
      answerable:false,integrity:.integrity}] as $questions
| ([$input.registry.projects[].name] + [$tasks[].project] | unique) as $projects
| [$projects[] as $name
   | ([$tasks[] | select(.project == $name)]
      | sort_by([task_band,(.since | date_key) // 1e30,.id,.key])) as $rows
   | ([$questions[] | select(.project == $name)]
      | sort_by([(if .urgent then 0 else 1 end),
          ((.hold.set // .since) | date_key) // 1e30,.priority // 5,.id,.key])) as $calls
   | {key:([$home_key,$name] | tojson),name:$name,label:($name // "Unassigned"),
      registration:([$input.registry.projects[] | select(.name == $name) | {name,mode,yolo,recognised,annotation}][0] // null),
      counts:counts($rows;$calls),tasks:$rows,questions:$calls}]
| sort_by([(if .counts.urgent_questions > 0 then 0 elif .counts.questions > 0 then 1
    elif any(.tasks[]; .worker_present or .backlog_state == "in_flight") then 2
    elif .counts.open_tasks > 0 then 3 else 4 end),.label,.key]) as $groups
| {schema:"fm-live-board.v1",collected_at:$input.generated,collected_at_epoch:$input.generated_epoch,
   collection_duration_seconds:$input.collection_duration_seconds,
   home:{key:$home_key,label:($input.fm_home | split("/") | map(select(length>0)) | .[-1])},
   coverage:($input.coverage + {local:($input.coverage.local +
     {structured_open:($open|length),metadata_only:($meta_only|length),shown:($tasks|length),truncated:false,
      trustworthy:($input.backlog.present and $input.main_inventory.valid and
        ([$backlog | group_by(.id)[] | select(length>1)]|length == 0))})}),
   omissions:[
     if $input.backlog.present | not then {kind:"backlog-unavailable"} else empty end,
     if $input.registry.present | not then {kind:"registry-unavailable"} else empty end,
     if $input.coverage.registered_homes.complete | not then
       {kind:"registered-homes-uncollected",reason:$input.coverage.registered_homes.reason} else empty end,
     ([$input.backlog.records[] | select(.structured == false and .state != "done")]|length) as $unstructured
     | if $unstructured > 0 then {kind:"unstructured-open-work",count:$unstructured} else empty end],
   warnings:[
     ($tasks[] as $task | $task.integrity[] | . + {task_key:$task.key,id:$task.id}),
     ($tasks[] as $task | $task.unregistered_decisions[] |
       {kind:"owner-must-register-call",task_key:$task.key,id:$task.id,decision:.}),
     ($input.registry.duplicates[] | {kind:"duplicate-project-registration",name:.}),
     ($input.registry.projects[] | select(.recognised == false) |
       {kind:"unrecognised-project-posture",name:.name,annotation:.annotation})],
   counts:counts($tasks;$questions),projects:$groups}
