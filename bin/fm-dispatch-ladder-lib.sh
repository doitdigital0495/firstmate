#!/usr/bin/env bash
# fm-dispatch-ladder-lib.sh - the escalation-ladder jq definitions, sourced by
# bin/fm-dispatch-resolve.sh and bin/fm-dispatch-receipt-lib.sh so the resolver's
# choice and the receipt gate's membership check share one expansion.
#
# docs/configuration.md "Escalation ladder" owns the table fields these read
# (ladder_rungs, default_ladder, a rule's ladder, ladder_policy, capability).
# This file owns only the expansion:
#   dl_expand       one rung -> concrete profiles for a row: per provider family,
#                   the first rung profile the row, project and lens allow, spread
#                   over the accounts and seat tiers the row itself lists
#   dl_ladder_for   the ladder a row runs on: its own `ladder`, else default_ladder
#   dl_resolve      history -> {k, rung, use} or {escalate} for the resolver
#   dl_all          every profile any rung of a row's ladder could seat (the gate)
# Defs are jq source text in FM_DL_JQ; nothing here runs on its own.

# shellcheck disable=SC2016 # jq program text, not shell expansion
FM_DL_JQ='
  def dl_profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def dl_family($p): $p.provider // ({"claude":"claude","codex":"codex","opencode":"codex"}[$p.harness] // null);
  def dl_cap_key($p): "\(dl_family($p))/\(($p.model // "") | split("/") | last):\($p.effort // "")";
  def dl_ladder_for($cfg; $meta): (if ($meta | type) == "object" then $meta.ladder else null end) // $cfg.default_ladder // null;
  # Capability gate: a candidate stays only when it beats every failed profile on
  # the lens. Technical needs the index or Terminal-Bench higher by more than the
  # tie band; written needs GDPval higher. A candidate the capability map does not
  # list cannot be shown to beat anything, so it stays out; a failed profile the
  # map does not list sets no bar beyond the exact-profile exclusion.
  def dl_beats($cfg; $cand; $failed; $lens):
    ($cfg.capability // {}) as $cap | ($cfg.ladder_policy.tie_band_points // 2) as $tie |
    if ($failed | length) == 0 then true
    else ($cap[dl_cap_key($cand)]) as $c |
      if $c == null then false
      else all($failed[]; . as $f | ($cap[dl_cap_key($f)]) as $fc |
        if $fc == null then true
        elif $lens == "written" then $c.gdpval > $fc.gdpval
        else ($c.index > $fc.index + $tie) or ($c.terminal_bench > $fc.terminal_bench + $tie) end) end
    end;
  def dl_fable_gated($cfg; $p; $project):
    $project != null and $p.harness == "claude" and $p.model == "fable"
    and (($cfg.ladder_policy.fable_projects | type) == "array")
    and (($cfg.ladder_policy.fable_projects | index($project)) == null);
  def dl_allowed($cfg; $meta; $ladder; $p; $project):
    (dl_family($p)) as $f |
    (($ladder.families // null) == null or (($ladder.families | index($f)) != null))
    and ((($meta.never_providers // []) | index($f)) == null)
    and ((($meta.never_models // []) | index($p.model)) == null)
    and (dl_fable_gated($cfg; $p; $project) | not)
    and (($p.harness == "claude" and $p.model == "fable" and (["xhigh", "max", "ultra"] | index($p.effort)) != null) | not);
  # One rung for one row. $use is the row use list (its accounts, seat tiers and
  # floors are what each family inherits), $meta the rule object (bans), $failed
  # the failed profiles, $project null to skip the project gate, $all true to
  # keep every allowed preference instead of the first.
  def dl_expand($cfg; $use; $meta; $ladder; $rung_no; $failed; $project; $all):
    ((($cfg.ladder_rungs // []) | map(select(.rung == $rung_no)) | first) // null) as $rung |
    if $rung == null then [] else
    ($ladder.lens // "technical") as $lens |
    (dl_profiles($use)) as $tpl |
    ([$tpl[] | dl_family(.)] | unique) as $in_rule |
    ([$rung | keys_unsorted[] | select(. != "rung" and . != "name" and . != "claude_written" and ($in_rule | index(.)) != null)] | sort_by(. != "claude")) as $fams |
    ([$tpl[] | select(dl_family(.) == "claude") | (.seat_tier // 1)] | max // 0) as $claude_tier |
    ([$fams[] | select(. != "claude")]) as $others |
    [$fams[] | . as $f |
      ([$tpl[] | select(dl_family(.) == $f)]
        | reduce .[] as $t ([]; . as $acc | if any($acc[]; (.account // null) == ($t.account // null) and (.seat_tier // null) == ($t.seat_tier // null)) then $acc else $acc + [$t] end)) as $ts |
      ([$tpl[] | select(dl_family(.) == $f)]) as $fam_tpl |
      (if $f == "claude" and $lens == "written" and (($rung.claude_written | type) == "array") then $rung.claude_written else (($rung[$f] // []) | if type == "array" then . else [] end) end) as $prefs |
      ([$prefs[] | select(dl_allowed($cfg; $meta; $ladder; .; $project)
          and (dl_cap_key(.) as $k | all($failed[]; dl_cap_key(.) != $k))
          and dl_beats($cfg; .; $failed; $lens))]) as $ok |
      (if $all then $ok else $ok[:1] end)[] | . as $rp |
      (([$fam_tpl[] | select(.model == $rp.model) | .reasoning_class] | map(select(type == "number")) | max)
        // ([$fam_tpl[] | .reasoning_class] | map(select(type == "number")) | max) // null) as $class |
      $ts[] | . as $t | ($t | del(.model, .effort, .reasoning_class, .provider))
        + {harness: $rp.harness, model: $rp.model, effort: $rp.effort}
        + (if $rp.provider != null then {provider: $rp.provider} else {} end)
        + (if ($ladder.claude_first // false) and $f != "claude" then {seat_tier: ($claude_tier + 1 + ($others | index($f)))} else {} end)
        + (if $rp.reasoning_class != null then {reasoning_class: $rp.reasoning_class} elif $class != null then {reasoning_class: $class} else {} end)
    ] end;
  # k capability failures -> the rung the row runs: start+k, advanced past any
  # rung that leaves no allowed profile, never above the ceiling. Past the
  # ceiling the answer is {escalate} (ladder_policy.beyond_ceiling).
  def dl_resolve($cfg; $use; $meta; $ladder; $k; $failed; $project):
    ($ladder.start) as $start | ($ladder.ceiling) as $ceiling |
    if $start + $k > $ceiling then
      {escalate: "\($k) capability failure(s) take this task past its ladder ceiling (rung \($ceiling)); the captain decides the next route (ladder_policy.beyond_ceiling)"}
    else
      ([range($start + $k; $ceiling + 1) as $r
        | {rung: $r, use: dl_expand($cfg; $use; $meta; $ladder; $r; $failed; $project; false)}
        | select(.use | length > 0)] | first) as $hit |
      if $hit == null then
        {escalate: "no ladder profile from rung \($start + $k) through ceiling \($ceiling) beats the \($k) failed profile(s) on the \($ladder.lens // "technical") lens for this row; the captain decides the next route"}
      else $hit + {k: $k, name: ((($cfg.ladder_rungs // []) | map(select(.rung == $hit.rung)) | first | .name) // null)} end
    end;
  def dl_all($cfg; $use; $meta):
    (dl_ladder_for($cfg; $meta)) as $ladder |
    if $ladder == null then []
    else try ([range(($ladder.start) + 1; ($ladder.ceiling) + 1) as $r | dl_expand($cfg; $use; $meta; $ladder; $r; []; null; true)[]]) catch [] end;
'
