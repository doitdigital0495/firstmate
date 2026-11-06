# fm-bridge-tasks.jq - the Bridge's task projection, included by
# bin/fm-bridge.sh, whose header owns the contract (TASKS). This file owns only
# the wording and grouping rules below; it reads nothing and is never run on its
# own. The facts come from `fm-forget.sh feed`, which also owns every keep
# reason and its words; nothing here decides whether a task may be removed.
include "fm-bridge-asks";

def bt_links:
  (. // "") | split(",") | map(select(length > 0) | capture("^(?<t>[a-z]+):(?<v>.+)$")) | map({(.t): .v}) | add // {};

# tasks-axi appends a row's link to its markdown title; the page shows it apart.
def bt_title($links):
  (. // "") as $t
  | reduce ([$links.pr, $links.report] | map(select(. != null))[]) as $l ($t;
      if endswith(" " + $l) then .[0:(length - ($l | length) - 1)] else . end);

def bt_human: gsub("[-_.]+"; " ") | (.[0:1] | ascii_upcase) + .[1:];

# Where a row came from, from structure only (lbc-tasks F4): the line
# `Picked from suggestion <sg>, a follow-up of <task>.` that fm-suggestions.sh
# pick writes, a first line `Captain [<date>]: ...`, an `Origin:` or
# `Captain hold origin:` line, or a secondmate row; anything else is not recorded.
def bt_origin($titles; $kind):
  ((. // "") | split("\n")) as $lines
  | ([$lines[] | capture("^Picked from suggestion (?<sg>sg-[0-9a-f]+), a follow-up of (?<o>[A-Za-z0-9._-]+)") | .o |= rtrimstr(".")] | first) as $pick
  | ([$lines[] | capture("^(Captain hold )?[Oo]rigin: *(?<o>.+)$")] | first) as $orig
  | ([($lines[0] // "") | capture("^Captain( (?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}))?:")] | first) as $cap
  | if $kind == "secondmate" then {kind: "secondmate", label: "A secondmate home", group: "Secondmate homes"}
    elif $pick != null then ($titles[$pick.o] // ($pick.o | bt_human)) as $o
      | {kind: "suggestion", label: "A suggested follow-up you picked, from: \($o)", group: "Follow-ups of: \($o)"}
    elif $cap != null then
      {kind: "captain", label: ("You asked for this" + (if $cap.d then " on " + $cap.d else "" end)), group: "You asked for these"}
    elif $orig != null then ($titles[$orig.o] // $orig.o) as $o
      | {kind: "origin", label: "Came from: \($o)", group: "From: \($o)"}
    else {kind: "none", label: "Not recorded", group: "Where it came from is not recorded"} end;

# The explainer: the row's own note without its provenance lines, else its hold
# reason, else the literal gap text, so a missing explanation is visible.
def bt_what($hold):
  ((. // "") | split("\n")
    | map(select(test("^(Picked from suggestion |(Captain hold )?[Oo]rigin:)") | not)) | join("\n")) as $note
  | if ($note | test("[A-Za-z]")) then {text: $note, source: "note"}
    elif ($hold // "") != "" then {text: $hold, source: "hold"}
    else {text: "No explanation recorded yet", source: "missing"} end;

def bt_lane($today; $open_blockers):
  if .state == "in_flight" then {lane: "started", why: "Being worked on"}
  elif .keep == "worker" then {lane: "started", why: "A worker is attached"}
  elif .hold_kind == "captain" then {lane: "you", why: "Waits for your answer"}
  elif (.hold_until // "") != "" and .hold_until > $today then {lane: "later", why: "Put off until \(.hold_until)"}
  elif (.hold_reason // "") != "" and ((.hold_until // "") == "" or .hold_until > $today) then {lane: "held", why: "Set aside for now"}
  elif ($open_blockers | length) > 0 then {lane: "waiting", why: "Waits for other work to finish first"}
  else {lane: "ready", why: "Starts on its own when a worker is free"} end;

def bt_age($today_epoch):
  if (. // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  then ((($today_epoch - ((. + "T00:00:00Z") | fromdateiso8601)) / 86400) | floor | if . < 0 then 0 else . end)
  else null end;

# Input: {forget: fm-forget-feed.v1 or null, receipts, now, today, sm_ids, names}.
def br_tasks:
  . as $in
  | ($in.sm_ids // []) as $ids | ($in.names // {}) as $names
  | def T($cap): br_text($ids; $names; $cap);
  if ($in.forget | type) != "object" or $in.forget.schema != "fm-forget-feed.v1" then
    {schema: "fm-bridge-tasks.v1", read: "failed", rows: [], removed: [], receipts: [], counts: {}, keep_days: null}
  else
  ($in.forget.rows // []) as $all
  | ($in.forget.reasons // {}) as $reasons
  | ($all | map({key: .id, value: .}) | from_entries) as $by
  | ($all | map({key: .id, value: ((.links | bt_links) as $l | .title | bt_title($l))}) | from_entries) as $titles
  | [ $all[] | select(.state != "done") ] as $open
  | [ $open[] | . as $r
      | ($r.links | bt_links) as $links
      | [ $r.blockers[] | . as $b | {id: $b, title: (($titles[$b] // ($b | bt_human)) | T(160)),
          state: (if $by[$b] == null then "gone" elif $by[$b].state == "done" then "done" else "open" end)} ] as $needs
      | ($r | bt_lane($in.today; [$needs[] | select(.state == "open")])) as $lane
      | ($r.body | bt_origin($titles; $r.kind // "")) as $origin
      | ($r.body | bt_what($r.hold_reason)) as $what
      | {kind: "task", id: $r.id, id_text: ($r.id | T(160)), rev: $r.rev, state: $r.state,
         title: ($titles[$r.id] | if . == "" then ($r.id | bt_human) else . end | T(200)),
         project: (($r.repo // "") | if . == "" then "No project" else T(60) end),
         lane: $lane.lane, why: $lane.why,
         hold_reason: ($r.hold_reason // null | if . then T(300) else null end),
         origin: {kind: $origin.kind, label: ($origin.label | T(200)), group: ($origin.group | T(200))},
         what: ($what.text | T(900)), what_source: $what.source,
         needs: $needs,
         needed_by: [ $open[] | select(.blockers | index($r.id)) | {id, title: (($titles[.id] // .id) | T(160))} ],
         created: ($r.created // null), age_days: ($r.created | bt_age($in.now)),
         priority: ($r.priority // null | if . == null then null else (tonumber? // null) end),
         pr: ($links.pr // null | if . then T(200) else null end),
         report: ($links.report // null | if . then T(200) else null end),
         keep: ($r.keep // null),
         keep_text: (if $r.keep then (($reasons[$r.keep] // "Kept.") | T(200)) else null end)} ] as $rows
  | [ ($in.forget.suggestions // [])[] | select(type == "object" and (.id | type) == "string")
      | . as $s
      | {kind: "suggestion", id: $s.id, id_text: $s.id, rev: null, state: "suggested",
         title: (($s.title // $s.id) | T(200)),
         project: (($s.repo // "") | if . == "" then "No project" else T(60) end),
         lane: "suggested", why: "Suggested, not on the list yet",
         hold_reason: null,
         origin: (($titles[$s.origin // ""] // (($s.origin // "") | bt_human)) as $o
           | {kind: "suggestion", label: ("A worker suggested this, from: \($o)" | T(200)), group: ("Follow-ups of: \($o)" | T(200))}),
         what: ([($s.title // ""), (if ($s.file_line // "") != "" then "Where: \($s.file_line)" else empty end),
                 (if ($s.risk // "") != "" then "Risk if ignored: \($s.risk)" else empty end)] | join("\n") | T(900)),
         what_source: "suggestion",
         needs: [], needed_by: [], created: null, age_days: ($s.age_days // null),
         priority: null, pr: null, report: null, keep: null, keep_text: null} ] as $sugg
  | ($rows + $sugg) as $list
  | {schema: "fm-bridge-tasks.v1", read: (if $in.forget.suggestions == null then "partial" else "ok" end),
     keep_days: $in.forget.keep_days,
     needed_text: (($reasons.needed // "Another open task still needs it; select that task too.") | T(200)),
     rows: ($list | sort_by([({"you":0,"ready":1,"waiting":2,"held":3,"later":4,"started":5,"suggested":6}[.lane] // 7),
                             (.priority // 5), -(.age_days // 0), .id])),
     removed: [ ($in.forget.removed // [])[] | {id, kind, batch, removed_epoch, expires_epoch,
                 title: ((.title // .id) | T(200)), what: ((.body // "") | T(300))} ],
     receipts: [ ($in.receipts.receipts // [])[] | {at, lines: [.lines[] | T(300)]} ],
     counts: {
       open: ($rows | length),
       ready: ($rows | map(select(.lane == "ready")) | length),
       waiting: ($rows | map(select(.lane == "waiting")) | length),
       later: ($rows | map(select(.lane == "later")) | length),
       held: ($rows | map(select(.lane == "held")) | length),
       you: ($rows | map(select(.lane == "you")) | length),
       started: ($rows | map(select(.lane == "started")) | length),
       suggested: ($sugg | length),
       nosource: ($rows | map(select(.origin.kind == "none")) | length),
       removable: ($list | map(select(.keep == null)) | length),
       removed: (($in.forget.removed // []) | length)}}
  end;

# One digest line for agents, appended after the question lines.
def br_tasks_digest_lines:
  if .tasks == null then []
  elif .tasks.read == "failed" then ["tasks unread"]
  else .tasks.counts as $c
    | ["tasks open=\($c.open) ready=\($c.ready) waiting=\($c.waiting) later=\($c.later) held=\($c.held) you=\($c.you) started=\($c.started) suggested=\($c.suggested) nosource=\($c.nosource) removed=\($c.removed)"]
  end;
