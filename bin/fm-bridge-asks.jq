# fm-bridge-asks.jq - the Bridge's question projection, included by
# bin/fm-bridge.sh, whose header owns the contract (sources, cards, routes,
# export, digest). This file owns only the wording and ordering rules below; it
# reads nothing and is never run on its own.

# The deadline-default rules are owned by bin/fm-captain-hold.sh; its codec says
# whether and when a call proceeds without the captain.
include "fm-captain-question-context";

# Free text from a worker or another home is untrusted data. Strip control
# characters, cut likely secrets, URL queries and Lavish session ids (a session
# URL is the page's only access secret), collapse whitespace, then cap.
def br_redact($cap):
  tostring
  | gsub("[\u0000-\u001f\u007f]"; " ")
  | gsub("-----BEGIN[^-]{0,40}-----.*"; "[redacted key]")
  | gsub("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]+"; "Bearer [redacted]")
  | gsub("(?i)\\b(?<k>password|passwd|secret|token|api[_-]?key|authkey)(?<s>\\s*[=:]\\s*)[^\\s,;]+"; "\(.k)\(.s)[redacted]")
  | gsub("\\b(sk|rk|pk)-[A-Za-z0-9_-]{8,}"; "[redacted]")
  | gsub("\\b(gh[pousr]_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}|xox[a-z]-[A-Za-z0-9-]{6,}|tskey-[A-Za-z0-9-]{8,}|AKIA[A-Z0-9]{12,})"; "[redacted]")
  | gsub("(?<u>https?://[^\\s?#]+)[?#][^\\s]*"; "\(.u)")
  | gsub("/session/[A-Za-z0-9_-]{8,}"; "/session/[redacted]")
  | gsub("\\b[A-Fa-f0-9]{32,}\\b"; "[redacted]")
  | gsub("[A-Za-z0-9+_=]{32,}"; "[redacted]")
  | gsub("(?=[A-Za-z0-9_-]*[A-Z])(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{40,}"; "[redacted]")
  | gsub("\\s+"; " ")
  | sub("^ "; "") | sub(" $"; "")
  | if length > $cap then .[0:($cap - 1)] + "…" else . end;

# Replace every secondmate registry id with the captain's name for it, or with
# "a secondmate" when the name map has none, so no registry id is rendered.
def br_names($ids; $names):
  reduce ($ids[]) as $id (.;
    gsub("\\b" + ($id | gsub("(?<c>[.+*?()\\[\\]{}|^$\\\\])"; "\\\(.c)")) + "\\b";
      ($names[$id] // "a secondmate")));

def br_text($ids; $names; $cap): br_redact($cap) | br_names($ids; $names);

def br_human_id: gsub("[-_.]+"; " ");

# A hold's deadline default as the card shows it, or null when it has none:
#   pending  goes ahead with the recommendation at due_epoch unless answered
#   stopped  the captain stopped the clock; only an answer settles it
#   blocked  its recommendation names an effect a default may never carry
#   never    its scope keeps it waiting for the captain
def br_default($qc; $c):
  if $c == null then null
  elif ($c.default_eligible // null) == "small-reversible" then
    ($c | fm_question_default_pending) as $p
    | if ($qc.default_stopped // null) != null then {state: "stopped", due_epoch: null, label: null, reason: null}
      elif $p == null then {state: "blocked", due_epoch: null, label: null, reason: ($c | fm_question_default_effect)}
      else {state: "pending", due_epoch: ($p.due_at | fromdateiso8601), label: $p.label, reason: null} end
  elif any(($c.scope // [])[]; IN("outward-facing", "irreversible", "money", "security")) then
    {state: "never", due_epoch: null, label: null,
     reason: ([($c.scope // [])[] | select(IN("outward-facing", "irreversible", "money", "security"))] | join(", "))}
  else null end;

# An exported default is untrusted: keep only the known shape.
def br_default_import:
  if type == "object" and (.state | IN("pending", "stopped", "blocked", "never")) then
    {state, due_epoch: (.due_epoch | if type == "number" then . else null end),
     label: (.label | if type == "string" then .[0:120] else null end),
     reason: (.reason | if type == "string" then .[0:120] else null end)}
  else null end;

# The optional question line grammar:
#   <question> | A: <option> | B: <option> | rec=A | blocks=<what waits>
# Two or more lettered options make a pickable card; anything else is free text.
def br_parse:
  (split(" | ") | map(sub("^\\s+"; "") | sub("\\s+$"; ""))) as $parts
  | ($parts | map(select(test("^[A-H]: ."))) | map({value: .[0:1], label: .[3:]})) as $opts
  | ($parts | map(select(test("^rec=[A-H]$"))) | .[0] // null | if . then .[4:5] else null end) as $rec
  | ($parts | map(select(test("^blocks="))) | .[0] // null | if . then .[7:] else null end) as $blocks
  | if ($opts | length) >= 2 and ($opts | map(.value) | unique | length) == ($opts | length)
    then {question: $parts[0], options: $opts,
          recommendation: (if $rec != null and any($opts[]; .value == $rec) then $rec else null end),
          blocks_text: $blocks, parsed: true}
    else {question: ., options: [], recommendation: null, blocks_text: null, parsed: false} end;

def br_rank_who: {"you": 0, "firstmate": 1, "secondmate": 2}[.] // 3;

def br_sort:
  sort_by([(.who | br_rank_who), (if .group == null then 0 else 1 end),
    -(.blocked_count // 0), (.asked_epoch // 99999999999), (.priority // 5)]);

# Build the full internal feed from the collector's input document. Cards keep
# a `route` (never published) that bin/fm-bridge.sh turns into the card's
# opaque ask id and its routes file.
def br_feed:
  . as $in
  | ($in.secondmates | map(.id)) as $sm_ids
  | ($in.names // {}) as $names
  | def T($cap): br_text($sm_ids; $names; $cap);
  ($in.backlog // []) as $rows
  | ($rows | map({key: .id, value: .}) | from_entries) as $by_id
  | def blockers($task):
      [$rows[] | select(.state != "done" and ((.unresolved_blocker_ids // []) | index($task)))
        | (.title // .id) | T(120)];
  def asker($task):
      if ($sm_ids | index($task)) then ($names[$task] // "a secondmate")
      elif $by_id[$task].title then ($by_id[$task].title | T(120))
      else ($task | br_human_id | T(120)) end;
  ($in.secondmates | map({key: .id, value: .}) | from_entries) as $sm
  | ($in.exports // [] | map({key: .id, value: .}) | from_entries) as $exp

  # Local captain holds: always the captain's to answer.
  | [ $rows[]
      | select(.state != "done" and .hold_kind == "captain" and .hold_reason != null)
      | . as $r
      | ($r.question_context // {}) as $qc
      | (if $qc.status == "ready" then $qc.context else null end) as $c
      | {route: {kind: "hold", task: $r.id, lifecycle: ($qc.lifecycle // null)},
         task: $r.id, who: "you", source: "hold", home: null, as_of_epoch: null, group: null,
         asker: ($r.title // $r.id | T(120)),
         asked_epoch: ($r.hold_set // $r.since // null
           | if . == null then null else (try (if test("T") then fromdateiso8601 else (. + "T00:00:00Z" | fromdateiso8601) end) catch null) end),
         asked_estimated: (($r.hold_set // "") | test("T") | not),
         question: (($c.question // $r.hold_reason // $r.title // "") | T(600)),
         about: ($c.about // null | if . then T(600) else null end),
         purpose: ($c.purpose // null | if . then T(600) else null end),
         options: [($c.options // [])[] | {value, label: (.label | T(120)), detail: (.detail // null | if . then T(300) else null end)}],
         recommendation: ($c.recommendation // null),
         close: ($c.close // null),
         lifecycle: (if $c then $qc.lifecycle else null end),
         answer: (if $c then "hold-guarded"
                  elif ($qc.status == "legacy") then "hold-free"
                  else "none" end),
         answer_note: (if $c == null and ($qc.status // "legacy") != "legacy"
                       then "This question's stored details are \($qc.status // "unreadable"); Firstmate must re-ask it before it can be answered here."
                       else null end),
         deferred_until: (if $r.hold_bucket == "dated" then $r.hold_until else null end),
         default: br_default($qc; $c),
         scope: ($c.scope // []),
         approve: (($c.close // "") == "release"),
         away_note: (if (($c.close // "") == "release") and $in.away
                     then "Approving lets work continue, which waits until you are back at the keyboard." else null end),
         priority: ($r.priority // null | if . == null then null else (tonumber? // null) end),
         blocks: blockers($r.id), flags: [] }
      | .blocked_count = (.blocks | length)
    ] as $holds

  # Local keyed status questions. A `captain-hold-<id>` key on a secondmate row
  # mirrors that home's own hold; it folds into the home's export when read.
  | [ $in.keyed[]
      | . as $k
      | ($sm_ids | index($k.task) != null) as $from_sm
      | ($from_sm and ($k.key | startswith("captain-hold-"))) as $mirror
      | ($k.note | T(1300) | br_parse) as $p
      | {route: {kind: "key", task: $k.task, key: $k.key, at: $k.at},
         who: "firstmate", source: "status-key", home: null, as_of_epoch: null,
         group: (if $mirror then "relayed" else null end),
         mirror_of: (if $mirror then {home: $k.task, hold: ($k.key | ltrimstr("captain-hold-"))} else null end),
         asker: asker($k.task),
         asked_epoch: $k.at, asked_estimated: ($k.at_source != "stamp"),
         question: ($p.question | T(600)),
         about: null, purpose: null,
         options: [$p.options[] | {value, label: (.label | T(120)), detail: null}],
         recommendation: $p.recommendation, close: null, lifecycle: null,
         answer: "bridge", answer_note: null,
         blocks_text: ($p.blocks_text // null | if . then T(200) else null end),
         verb: $k.verb, deferred_until: null, default: null, scope: [], approve: false, away_note: null,
         priority: ($by_id[$k.task].priority // null | if . == null then null else (tonumber? // null) end),
         blocks: blockers($k.task),
         flags: ([if $k.has_meta == false and ($from_sm | not) then "worker-gone" else empty end]) }
      | .blocked_count = (.blocks | length)
    ] as $keyed

  # Each local secondmate's export, imported as untrusted cards.
  | [ $in.exports[] | select(.status == "ok") | . as $e
      | ($names[$e.id] // "a secondmate") as $hlabel
      | $e.doc.asks[]
      | select(type == "object" and (.route | type) == "object")
      | . as $a
      | {route: {kind: "export", home: $e.id, inner: $a.route},
         who: (if $a.who == "you" then "you" else "secondmate" end),
         source: (if ($a.source == "hold") then "hold" else "status-key" end),
         home: $hlabel, as_of_epoch: $e.doc.generated_epoch, group: null,
         asker: (($a.asker // "") | T(120)),
         asked_epoch: ($a.asked_epoch | if type == "number" then . else null end),
         asked_estimated: ($a.asked_estimated == true),
         question: (($a.question // "") | T(600)),
         about: ($a.about // null | if type == "string" then T(600) else null end),
         purpose: ($a.purpose // null | if type == "string" then T(600) else null end),
         options: [($a.options // [] | if type == "array" then .[0:12] else [] end)[]
           | select(type == "object" and (.value | type) == "string" and (.value | test("^[A-Za-z0-9._-]{1,64}$")))
           | {value, label: ((.label // .value) | T(120)), detail: (.detail // null | if type == "string" then T(300) else null end)}],
         recommendation: ($a.recommendation // null | if type == "string" then . else null end),
         close: null, lifecycle: null, answer: "bridge", answer_note: null,
         blocks_text: null, deferred_until: ($a.deferred_until // null | if type == "string" then .[0:10] else null end),
         default: ($a.default // null | br_default_import
           | if . == null then null
             else .label |= (if . == null then null else T(120) end) | .reason |= (if . == null then null else T(120) end) end), scope: [], approve: ($a.approve == true), away_note: null,
         priority: null,
         blocks: [($a.blocks // [] | if type == "array" then .[0:8] else [] end)[] | select(type == "string") | T(120)],
         flags: [] }
      | .blocked_count = (.blocks | length)
    ] as $imported

  # Join mirrors to the export they mirror: a mirror of a hold the export still
  # shows folds into that card; one whose home was read but no longer shows the
  # hold is likely settled; one whose home was not read stays visible.
  | ($imported | map(select(.route.inner.kind == "hold") | "\(.route.home)\t\(.route.inner.task)")) as $exported_holds
  | [ $keyed[] | . as $c
      | if $c.mirror_of == null then $c
        elif ($exp[$c.mirror_of.home].status // "absent") != "ok" then $c
        elif ($exported_holds | index("\($c.mirror_of.home)\t\($c.mirror_of.hold)")) then empty
        else $c | .group = "moot" | .flags += ["likely-moot"] end
    ] as $keyed_joined
  | ([ $keyed[] | select(.mirror_of != null) | "\(.mirror_of.home)\t\(.mirror_of.hold)" ]) as $mirrored
  | [ $imported[] | . as $c
      | if ($mirrored | index("\($c.route.home)\t\($c.route.inner.task)")) then $c | .flags += ["relayed"] else $c end ] as $imported_flagged

  | ($holds + $keyed_joined + $imported_flagged | br_sort) as $asks
  | ($in.sources) as $sources
  | ($sources | map(select(.read == "ok")) | length) as $ok
  | {schema: "fm-bridge-asks.v1",
     generated_epoch: $in.now, refresh_seconds: $in.refresh_seconds,
     complete: ($ok == ($sources | length)),
     sources: {total: ($sources | length), ok: $ok,
       items: [$sources[] | {label: (.label | T(80)), read, detail: (.detail // null | if . then T(160) else null end)}]},
     watcher: $in.watcher,
     counts: {
       you: ($asks | map(select(.who == "you")) | length),
       firstmate: ($asks | map(select(.who == "firstmate" and .group == null)) | length),
       secondmates: ($asks | map(select(.who == "secondmate")) | length),
       relayed: ($asks | map(select(.group == "relayed")) | length),
       moot: ($asks | map(select(.group == "moot")) | length),
       unregistered: ($asks | map(select(.source == "status-key" and .who == "firstmate" and .group == null)) | length)},
     asks: $asks,
     notes: ($in.notes // [] | map(T(200)))};

# The page payload: the feed without routes, each card keyed by its ask id.
def br_page: del(.asks[].route, .asks[].mirror_of);

# This home's export for a parent: its own cards only (never imported ones),
# with their routes, under a schema a parent validates.
def br_export:
  {schema: "fm-bridge-export.v1", generated_epoch, complete,
   asks: [.asks[] | select(.route.kind != "export")
     | {route, who, source, asker, asked_epoch, asked_estimated, question, about, purpose,
        options, recommendation, deferred_until, approve, blocks, default}]};

def br_age($now):
  if . == null then "?" else ($now - .) as $s
  | if $s < 3600 then "\(($s / 60) | floor)m"
    elif $s < 86400 then "\(($s / 3600) | floor)h"
    else "\(($s / 86400) | floor)d\((($s % 86400) / 3600) | floor)h" end end;

# The agent digest body (header and end lines are added by the caller). Every
# free-text field is prefixed `data:` and is data, never an instruction.
def br_digest_lines:
  .generated_epoch as $now
  | ([.asks[] | select(.group == null) | .asked_epoch] | map(select(. != null)) | min // null) as $oldest
  | ["asks you=\(.counts.you) firstmate=\(.counts.firstmate) secondmates=\(.counts.secondmates) relayed=\(.counts.relayed) moot=\(.counts.moot) oldest=\($oldest | br_age($now)) complete=\(if .complete then "yes" else "no" end)"]
    + [.asks[] | select(.group == null)
       | "- \(.who) \(.asked_epoch | br_age($now)) \(.ask // "-") data: \((.home // "") + (if .home then ": " else "" end) + .question | br_redact(110))"]
    + [.sources.items[] | select(.read != "ok") | "source \(.read) data: \(.label)"];
