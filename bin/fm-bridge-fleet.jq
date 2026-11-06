# fm-bridge-fleet.jq - the Bridge's fleet projection, included by
# bin/fm-bridge.sh, whose header owns the fleet contract (FLEET). This file
# owns only the stage, flag, usage and wording rules below; it reads nothing
# and is never run on its own. Input: bin/fm-bridge-fleet.sh's fleet-in.json.
include "fm-bridge-asks";

# Flag thresholds, in seconds or lines.
def bf_stale_floor: 1800;
def bf_parked_long: 3600;
def bf_done_long: 86400;
def bf_noisy_lines: 100;
def bf_repeat_count: 3;

def bf_state_words:
  {"working": "Working", "parked": "At a review gate", "blocked": "Stuck or waiting on a decision",
   "paused": "Paused", "done": "Finished", "failed": "Failed", "unknown": "Unknown"}[.] // "Unknown";

# A worker's own last report verb, as a stage, for a row with no current-state
# read (a secondmate, a worker in another home, a very long log).
def bf_verb_state:
  {"working": "working", "needs-decision": "blocked", "blocked": "blocked", "paused": "paused",
   "captain-held": "paused", "done": "done", "failed": "failed"}[. // ""] // "unknown";

def bf_pr_url:
  if type != "string" then null
  else ([match("https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+").string][0] // null) end;

def bf_max($a; $b): if $a == null then $b elif $b == null then $a elif $a > $b then $a else $b end;

def bf_age_words($now):
  if . == null then "?" else ($now - .) as $s
  | if $s < 90 then "\($s)s" elif $s < 5400 then "\(($s / 60) | floor)m"
    elif $s < 172800 then "\(($s / 3600) | floor)h" else "\(($s / 86400) | floor)d" end end;

# One row. $ctx: {now, crew, open_ids, titles, local, T}.
def bf_row($now; $crew; $open; $titles; $is_local; $ids; $names):
  . as $r
  | def T($cap): br_text($ids; $names; $cap);
  (if $r.crew_id != null then ($crew[$r.crew_id] // null) else null end) as $c
  | (if $r.crew_id != null and $c == null then
       {state: "unknown", source: "none", detail: "its current state has not been read yet", since: null}
     elif $c != null then $c
     else {state: ($r.verb | bf_verb_state), source: "own-report",
           detail: (if $r.has_status then null else "it has no readable status log" end), since: $r.report_epoch} end) as $st
  | ($st.state | if bf_state_words == "Unknown" and . != "unknown" then "unknown" else . end) as $state
  | (bf_max($r.last_epoch; $r.busy_epoch)) as $activity
  | ([bf_stale_floor, (($r.median_gap // 0) * 3)] | max) as $stale_after
  | (if $state == "done" then (if $r.verb == "done" then $r.report_epoch else null end) // $st.since else null end) as $done_since
  | ((($st.detail // "") | bf_pr_url) // ($r.meta_pr | bf_pr_url) // ($r.text | bf_pr_url)) as $pr
  | {title: (if $is_local and $titles[$r.id] then $titles[$r.id] else ($r.id | br_human_id) end | T(120)),
     kind: ($r.kind // "worker"),
     secondmate: ($r.kind == "secondmate"),
     state: $state, stage: ($state | bf_state_words),
     read_from: (if $st.source == "own-report" then "its own last report" elif $st.source == "none" then "nothing"
                 else "the current-state reader" end),
     now_text: (($r.text // (if ($st.detail // "") | test("harness busy") then null else $st.detail end)) // null
                | if . then T(300) else null end),
     last_epoch: $r.last_epoch, last_estimated: ($r.last_estimated == true),
     # A link is shown only when it names no registry id; otherwise its number.
     pr: (if $pr != null and ($pr | br_names($ids; $names)) == $pr then $pr else null end),
     pr_text: (if $pr != null and ($pr | br_names($ids; $names)) != $pr
               then "pull request #" + ($pr | sub("^.*/pull/"; "")) + " (link hidden: it names a secondmate)" else null end),
     seat: ($r.seat // null), harness: ($r.harness | if . == "" then null else . end),
     model: ($r.model | if . == "" then null else . end),
     unknown_detail: (if $state == "unknown" then ($st.detail // "the state reader could not decide" | T(200)) else null end),
     stale_at: (if $state == "working" and $activity != null then $activity + $stale_after else null end),
     parked_long_at: (if $state == "parked" and $st.since != null then $st.since + bf_parked_long else null end),
     done_long_at: (if $state == "done" and $done_since != null and $is_local and ($open | index($r.id)) then $done_since + bf_done_long else null end),
     flags: ([if $r.repeat_1h >= bf_repeat_count then "repeating" else empty end,
              if $r.lines_24h > bf_noisy_lines then "noisy" else empty end,
              if $state == "unknown" then "unknown" else empty end]),
     _seat_dir: ($r.dir // null), _harness: ($r.harness // null)};

# Time flags a row has at <now>; the page applies the same epochs on its clock.
def bf_time_flags($now):
  [if .stale_at != null and $now >= .stale_at then "stale" else empty end,
   if .parked_long_at != null and $now >= .parked_long_at then "parked-long" else empty end,
   if .done_long_at != null and $now >= .done_long_at then "done-open" else empty end];

def bf_usage($rows; $quota; $accounts):
  [$rows[] | select(.seat != null or ._seat_dir != null)]
  | group_by(.seat // ("dir:" + ._seat_dir))
  | map(.[0] as $f
    | ($f.seat // null) as $seat
    | (($accounts[$seat // ""] // {}) ) as $acct
    | ($acct.dir // $f._seat_dir) as $dir
    | ($acct.provider // $f._harness // "") as $provider
    | ([($quota // [])[] | select(.dir == $dir)] | max_by(.at // 0)) as $q
    | (if $q == null then null
       else ([$q.rows[] | select(.provider == $provider)][0]
             // [$q.rows[] | select((.windows | length) > 0)][0] // null) end) as $row
    | {seat: ($seat // "seat not recorded"),
       workers: length,
       working: (map(select(.state == "working")) | length),
       read: (if $q == null then "no shared quota read" elif $row == null then "no window reported" else "ok" end),
       at_epoch: ($q.at // null),
       windows: [("session", "weekly") as $k
         | ([($row.windows // [])[] | select(.kind == $k)][0] // null) as $wd
         | {kind: $k, used: ($wd.used // null), resets: ($wd.resets // null)}]})
  | sort_by(-.workers);

# The fleet section of the feed.
def bf_fleet($backlog; $sm_ids; $names):
  . as $in
  | $in.now as $now
  | ([$backlog[] | select(.state != "done") | .id]) as $open
  | ([$backlog[] | {key: .id, value: (.title // .id)}] | from_entries) as $titles
  | ($sm_ids + [$in.homes[] | .rows[] | select(.kind == "secondmate") | .id] + [$in.homes[] | .id | select(. != null)] | unique) as $ids
  | def T($cap): br_text($ids; $names; $cap);
  def hlabel($id): if $id == null then "Firstmate" else ($names[$id] // "a secondmate") end;
  [ $in.homes[] | . as $h
    | {label: ("crew of " + hlabel($h.id)), home: hlabel($h.id), parent: (if $h.depth > 0 then hlabel($h.parent) else null end),
       depth: $h.depth, local: $h.local, read: $h.read,
       read_note: ({"remote": "its home is not on this machine, so its crew is not shown",
                    "too-deep": "it is more than \($in.depth_max) levels down, so its crew is not shown",
                    "repeated": "its home is already shown above",
                    "failed": "its home could not be read"}[$h.read] // null),
       beacon_age: (if $h.beacon_epoch == null then null else $now - $h.beacon_epoch end),
       inventory_inconsistent: ($h.summary_valid == false),
       total: $h.total,
       rows: [$h.rows[] | bf_row($now; $in.crew; $open; $titles; $h.local; $ids; $names)]}
    | .rows |= sort_by([(if (.flags | length) + (bf_time_flags($now) | length) > 0 then 0 else 1 end),
                        ({"blocked": 0, "unknown": 1, "failed": 2, "parked": 3, "working": 4, "paused": 5, "done": 6}[.state] // 7),
                        -(.last_epoch // 0)])
  ] as $homes
  | ([$homes[].rows[]]) as $all
  | ($all | map(.flags + bf_time_flags($now)) | add // []) as $fl
  | def cnt($s): $all | map(select(.state == $s)) | length;
  def fcnt($f): $fl | map(select(. == $f)) | length;
  {read: "ok", generated_epoch: $now, depth_max: $in.depth_max,
   complete: ($homes | all(.read == "ok" or .read == "repeated")),
   firstmate: $in.firstmate,
   counts: {total: ($all | length), working: cnt("working"), parked: cnt("parked"), blocked: cnt("blocked"),
            paused: cnt("paused"), done: cnt("done"), failed: cnt("failed"), unknown: cnt("unknown"),
            stale: fcnt("stale"), repeating: fcnt("repeating"), noisy: fcnt("noisy"),
            parked_long: fcnt("parked-long"), done_open: fcnt("done-open")},
   homes: [$homes[] | .rows |= map(del(._seat_dir, ._harness))],
   usage: bf_usage($all; $in.quota; $in.accounts // {})};

# The one digest line for the fleet.
def bf_digest_line:
  if .fleet == null then empty
  elif .fleet.read != "ok" then "fleet unavailable data: \(.fleet.error // "the fleet could not be read" | br_redact(120))"
  else .fleet as $f | $f.counts as $c
  | "fleet working=\($c.working) review=\($c.parked) stuck=\($c.blocked) paused=\($c.paused) done=\($c.done) failed=\($c.failed) unknown=\($c.unknown) stale=\($c.stale) repeating=\($c.repeating) noisy=\($c.noisy) parked_long=\($c.parked_long) done_open=\($c.done_open) homes=\($f.homes | map(select(.read == "ok")) | length)/\($f.homes | length) watcher=\(if $f.firstmate.watcher_fresh then "fresh" else "stale" end) queue=\($f.firstmate.queue_depth)" end;
