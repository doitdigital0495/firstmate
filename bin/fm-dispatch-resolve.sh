#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with Jev through the private jevd socket.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>] [--task <id>] [--captain-pick]
#   fm-dispatch-resolve.sh pipeline --step <step> (no-mistakes step -> seat JSON)
#   fm-dispatch-resolve.sh pick <CODE>            (captain's answer -> receipt)
#   fm-dispatch-resolve.sh pick-card [<CODE>...]  (render the captain's card)
#   fm-dispatch-resolve.sh picks [--recent]       (pending and answered picks)
#   fm-dispatch-resolve.sh rows [--json]          (--json: criteria export)
#   fm-dispatch-resolve.sh audit [--days <n>] [--problems]
#   fm-dispatch-resolve.sh overrides [--recent]   (historical log)
#   fm-dispatch-resolve.sh gate ...     (called by fm-spawn.sh and fm-control.sh)
#   fm-dispatch-resolve.sh refund --token <token>   (called by fm-spawn.sh)
#   choose, degraded, degraded-recent, and override are retired (exit 2).
#
# Dispatch receipts: every launch in a home whose config/crew-dispatch.json has
#   routing rows is admitted only against a receipt this script wrote, and
#   bin/fm-dispatch-receipt-lib.sh's header owns the receipt format and the
#   gate's rules. A clear resolution writes a jev receipt; `pick` writes a
#   captain receipt from the captain's verified answer to a captain-pick
#   request (bin/fm-dispatch-pick-lib.sh owns that request, the card, and
#   the verification). No route is ever guessed and no profile is passed in.
#   The resolver never reads a key or .env; jevd owns key custody.
#   docs/configuration.md owns the socket protocol and failure policy.
#
# What it does: a dispatch_choices socket request with the project name and
#   brief's Task subsections (whole brief for legacy input) as
#   state and TWO batched Choice questions: rule matching (every rule's `when`
#   plus a neutral none option) and candidate/effort preference. Jev returns the matched rule, a probability per
#   option, and a confidence. Everything after that is jq: the confidence
#   floor, the rule's declared `approval` and `floor`, each profile's declared
#   `provider`, `quota_scope`, and `floor`, the quota rows from per-store quota-axi
#   --json snapshots, the optional preferred_provider family restriction, and the
#   spendPriority argmax over the eligible candidates. An eligible but wholly
#   unrankable preferred family escalates rather than authorizing another
#   family. The model never sees quota, catalogs, approvals, preferred_provider,
#   `why`, account labels, or credential paths.
#   Before any selection, a completeness gate makes a candidate readable only with
#   every applicable quota window - session, weekly, and model-scoped - known with
#   its remaining percent and reset time, or positively established absent for that
#   plan, so a measured weekly-only plan is complete while an unmeasured or
#   rate-limited provider is unreadable.
#   While any candidate is rankable, an unreadable one stays listed as skipped and
#   is never selected or treated as healthy; a skipped pool with a named warm-up
#   (zai-window-warm for Z.ai) still gets that warm-up and one re-read first.
#   With no rankable candidate the same warm-up and re-read run without any wait,
#   and anything still unknown starts on the first declared seat of the open tier
#   and strongest reasoning class, marked quota unknown (captain 2026-11-05: an
#   unknown quota never blocks a start).
#
# Shared-quota opt-out: an optional top-level "shared_quota": true in the
#   rules file declares this home draws every provider's usage from one single
#   shared budget, so per-provider quota rows do not describe what is left.
#   With it set, this tool makes no quota-axi call, applies no quota floor,
#   runway, or completeness gate, ranks nothing by spendPriority, and resolves
#   the matched rule's `use` profiles in declared order; preferred_provider still
#   narrows the pool and account registration still applies. Every candidate
#   line still prints, stating quota ranking is off by home declaration. The
#   declared value must be a boolean; anything else is a configuration error.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Fallback-only reserve tier: an optional per-profile boolean "fallback_only":
#   true holds that candidate out of selection while any non-fallback candidate
#   of the same provider family still has seat capacity: only the weekly (7d)
#   window decides, so a seat is at its limit when that window is at or above
#   100% used or a row it bounds reports runway exhausted_now, and a session
#   (5h) window alone never releases the reserve. Once every same-family
#   non-fallback seat is at its limit the reserve candidate is eligible, still
#   ranked below every non-fallback candidate, and its candidate line and the
#   receipt state the reserve decision and why. The declared value must be a
#   boolean; anything else is a configuration error.
#   docs/configuration.md "Crew dispatch profiles" owns the declared field.
#
# Seat tiers: an optional per-profile positive integer "seat_tier" declares a
#   strict order within a row, lower first, and an absent one sorts after every
#   declared tier. Only the lowest tier still holding a candidate that is not
#   ineligible and not at its weekly limit (the fallback_only test above) stays
#   in the choice; every later tier is held and never makes the choice
#   incomplete. An unreadable candidate holds no tier in dispatch, except in
#   pipeline mode below. Keep-strongest and spendPriority then decide inside that
#   tier.
#   An optional top-level "seat_tiers_by_delivery" maps a brief's "Delivery
#   contract: mode=" value to {account: tier} entries that replace "seat_tier"
#   for those accounts. With no tier declared, behavior is unchanged.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields.
#
# Pipeline mode: `pipeline --step <step>` picks the seat for one no-mistakes
#   step from the top-level "pipeline_rows" row naming that step, with no model
#   call, brief, receipt, or captain pick. Each profile declares its "pool" and
#   "seat_tier", so the seat tier hold above keeps every later pool out until the
#   earlier one has no seat with room. On top of the shared evaluation: an
#   optional profile "weekly_floor_percent" takes a seat out once its weekly room
#   left is at or below that percent, and inside the open tier a seat projected
#   to run out within 90 minutes loses to one that lasts to its reset. Quota
#   evidence waits at most 30 seconds in total; then a measured seat of the open
#   tier wins, else that tier's first seat with measured false, except that an
#   unreadable weekly floor takes its seat out. Unreadable quota never opens a
#   later pool.
#   stdout is one JSON object. status ok (exit 0) carries seat, harness, model,
#   effort, provider, pool, tier, reasoning_class, measured, reason, and
#   candidates. status exhausted (exit 3) carries one seats entry per seat, and
#   stderr carries one line per seat naming its reset. Exit 2 is a usage or
#   configuration error, including a step with no row.
#   docs/configuration.md "Pipeline seat rows" owns the declared fields.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, every string value of the built request is checked against it
#   before the socket request. Each non-blank, non-# line is a literal matched
#   case-insensitively, with surrounding whitespace trimmed and every run of
#   whitespace, on both sides, treated as one space. A match, or a list that
#   is not a readable regular file, prints one
#   "dispatch-resolve: off (...; nothing sent)" line on stderr naming at most
#   the list line number, never its value, prints nothing on stdout, and exits
#   0 with no network or quota call and no receipt (the launch gate refuses).
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | captain-pick
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     fallback: <runner-up rule taken when the picked rule missed its own floor>
#     reason: <why the status is not clear>
#     preferred_provider: <family and preference or fallback decision, when applied>
#     candidate: <harness>:<model> provider=.. windows=<id>:<pct>%@<reset>,.. [account=..] scope=.. remaining=..% spendPriority=.. runway=.. -> eligible | eligible, unranked: <reason> | eligible, reserve pick: <why the tier fired> | not eligible: <reason> | not eligible: quota unreadable, skipped: <reason> | incomplete: <reason>
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only)
#     pick: <CODE> ...; row <id> ...; option <n>: <profile> ... (captain-pick only)
#     receipt: <name> (one launch, valid <n>s) | none - ... | not written (...)
#   clear      -> pass the profile line to fm-spawn.sh exactly; the receipt it wrote
#                 admits that profile and no other. When every eligible candidate
#                 declares a numeric reasoning_class, only the highest declared
#                 class competes on spendPriority (single matched rule and default
#                 row alike); any missing class keeps plain spendPriority ranking
#   ambiguous  -> code unions qualifying rows and keeps strongest reasoning_class;
#                 a union with a missing class goes to the captain, never hand-picked
#   incomplete -> no candidate is rankable and quota window evidence is not fully
#                 known. Never waited on in worker mode: it resolves clear on the
#                 first declared seat with `quota unknown` on its line, and goes to
#                 the captain only when a rule requires approval or nothing is left
#                 to start on
#   captain-pick -> Jev is down or answered unusably after one retry (a missing
#                 socket first gets FM_JEVD_SOCKET_WAIT_SECONDS, default 15, to
#                 come back), or code cannot dispatch Jev's answer (captain
#                 approval, nothing rankable, or an invalid row). It writes a pick request offering
#                 every row and candidate with its evidence and launches nothing;
#                 the captain answers "route <CODE> <n>" and `pick <CODE>` turns
#                 the verified answer into a receipt. --captain-pick asks for
#                 the same request even when Jev's answer is dispatchable: the
#                 captain's per-task override, still decided only by his words.
#   Only clear and pick write receipts; every other outcome leaves launch refused.
#   Outcomes exit 0 for inspection; callers must require a printed receipt.
#   Failure to write a receipt or a pick request exits 3, as does `pick` when
#   it refuses or the captain answered wait.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, or missing jq), which is
#   actionable, never selected around.
#
# Environment:
#   FM_JEVD_SOCKET selects the private socket (default XDG state jev-gate/jevd.sock).
#   FM_QUOTA_READ_DEADLINE (45) is the deadline on all of a worker choice's reads.
#   FM_DISPATCH_QUOTA_WAIT_SECONDS can only shorten that, and pipeline's 30 seconds.
#   FM_DISPATCH_QUOTA_ATTEMPTS bounds quota gathers (default 1000, 1..1000).
#   FM_DISPATCH_QUOTA_BACKOFF_MS sets pipeline's initial backoff (1500, 250..30000 ms).
#
# Authority: Jev chooses the row; code applies deterministic quota and approval
#   gates without replacing fm-spawn.sh validation. It publishes one
#   inspectable answer plus every candidate's evidence, in code, and it is the
#   only writer of the receipts the launch gate checks.
set -u

# This process never reads a credential or .env; jevd owns key custody.
unset OPENROUTER_API_KEY TYPESAFE_API_KEY OPENROUTER_JEV_API_KEY
unset OPENROUTER_API_KEY_PRIVATE DIRECT_API_KEY_PRIVATE TS_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-dispatch-receipt-lib.sh
. "$SCRIPT_DIR/fm-dispatch-receipt-lib.sh"
# shellcheck source=bin/fm-dispatch-pick-lib.sh
. "$SCRIPT_DIR/fm-dispatch-pick-lib.sh"

# Inspection and launch admission never contact Jev.
case "${1:-}" in
  gate) shift; fm_dr_cmd_gate "$@"; exit $? ;;
  refund) shift; fm_dr_cmd_refund "$@"; exit $? ;;
  choose|degraded|override|degraded-recent) fm_dr_die "self-service and degraded receipts are retired; run the resolver with the brief (Jev, or the captain's pick when Jev cannot route)" ;;
  rows) shift; fm_dr_cmd_rows "$@"; exit $? ;;
  overrides) shift; fm_dr_cmd_overrides "$@"; exit $? ;;
  audit) shift; fm_dr_cmd_audit "$@"; exit $? ;;
  pick) shift; fm_dp_cmd_pick "$@"; exit $? ;;
  pick-card) shift; fm_dp_cmd_card "$@"; exit $? ;;
  picks) shift; fm_dp_cmd_picks "$@"; exit $? ;;
esac

CONFIDENCE_FLOOR=0.6
# Bounded gather for an incomplete choice: attempts and the doubling backoff base.
fm_dispatch_clamp_int() {  # <value> <default> <min> <max>
  local v=$1 d=$2 lo=$3 hi=$4
  case "$v" in '' | *[!0-9]*) v=$d ;; esac
  [ "$v" -ge "$lo" ] || v=$lo
  [ "$v" -le "$hi" ] || v=$hi
  printf '%s' "$v"
}
QUOTA_ATTEMPTS=$(fm_dispatch_clamp_int "${FM_DISPATCH_QUOTA_ATTEMPTS:-}" 1000 1 1000)
QUOTA_WAIT_SECONDS=$(fm_dispatch_clamp_int "${FM_DISPATCH_QUOTA_WAIT_SECONDS:-}" 900 1 900)
# Reads and warm-ups share this deadline so a wedged quota process cannot hang dispatch.
QUOTA_DEADLINE=0
fm_dispatch_bounded() {
  python3 "$SCRIPT_DIR/fm-dispatch-bounded.py" "$QUOTA_DEADLINE" "$@"
}
QUOTA_BACKOFF_MS=$(fm_dispatch_clamp_int "${FM_DISPATCH_QUOTA_BACKOFF_MS:-}" 1500 250 30000)
JEV_SOCKET_WAIT_SECONDS=$(fm_dispatch_clamp_int "${FM_JEVD_SOCKET_WAIT_SECONDS:-}" 15 0 60)
TS_MODEL=typesafe/jev-1.13
JEV_SOCKET=${FM_JEVD_SOCKET:-${XDG_STATE_HOME:-$HOME/.local/state}/jev-gate/jevd.sock}
JEV_FAILED_REASON=''
DEFAULT_WHEN="No listed rule applies to this task."

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

MODE=worker STEP=''
if [ "${1:-}" = pipeline ]; then MODE=pipeline; shift; fi
BRIEF='' PROJECT='' TASK_ID='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES='' FORCE_PICK=false
NEVER_SEND_PATH="$CONFIG/dispatch-never-send"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    --task) [ $# -ge 2 ] || die "--task needs a value"; TASK_ID=$2; shift 2 ;;
    --captain-pick) FORCE_PICK=true; shift ;;
    --step) [ $# -ge 2 ] || die "--step needs a value"; STEP=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- inputs --------------------------------------------------------------------
BRIEF_DELIVERY=''
if [ "$MODE" = pipeline ]; then
  [ -n "$STEP" ] || die "pipeline needs --step <step>"
  [ -z "$BRIEF$PROJECT$TASK_ID" ] && [ "$FORCE_PICK" = false ] || die "pipeline takes only --step"
  [ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || die "rules file absent: $RULES_PATH"
  # The whole pipeline decision, including its first quota reads, shares one bound.
  [ "$QUOTA_WAIT_SECONDS" -le 30 ] || QUOTA_WAIT_SECONDS=30
  QUOTA_DEADLINE=$(( $(date +%s) + QUOTA_WAIT_SECONDS ))
else
  [ -z "$STEP" ] || die "--step belongs to pipeline mode"
  [ -n "$BRIEF" ] || die "brief file required (see --help)"
  [ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
  BRIEF_DELIVERY=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  [ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
fi
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
FM_DR_TABLE_SHA=$(fm_dr_sha256 < "$RULES") || die "could not hash rules snapshot"
if [ "$MODE" = worker ]; then
  FM_DR_BRIEF_SHA=$(fm_dr_brief_hash "$BRIEF") || die "could not hash brief"
fi
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

pipeline_problems=$(fm_account_pipeline_problems "$RULES")
[ -z "$pipeline_problems" ] || die "malformed rules file: $RULES_PATH - $(printf '%s' "$pipeline_problems" | paste -sd ';' - | sed 's/;/; /g')"

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def seat_tier_ok($t): ($t | type) == "number" and $t >= 1 and ($t | floor) == $t;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or ($p | has("account") and ((.account | type) != "string" or (.account | test("^[a-z][a-z0-9-]*$") | not)))
    or ($p | has("reasoning_class") and ((.reasoning_class | type) != "number"))
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def family_of($p): $p.provider // ({"claude":"claude","codex":"codex","opencode":"codex"}[$p.harness] // null);
  def duplicate_profiles($items):
    ($items | map([.account // null, .harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("preferred_provider") and (provider_id(.preferred_provider) | not) then "preferred_provider must be a lowercase provider ID (for example codex)"
  elif has("shared_quota") and (.shared_quota | type) != "boolean" then "shared_quota must be true or false when present"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1)) then "min_confidence must be a number from 0 through 1 when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("never_providers") and ((.never_providers | type) != "array" or (.never_providers | length) == 0 or any(.never_providers[]; provider_id(.) | not))) then "never_providers must be a non-empty array of provider IDs when present"
  elif any((.rules // [])[]; . as $r | has("never_providers") and any(profiles($r.use)[]; (family_of(.) as $f | $f != null and ($r.never_providers | index($f)) != null))) then
    "a rule lists a profile of a provider its own never_providers bans: " + ([(.rules // []) | to_entries[] | .key as $i | .value as $r | select($r | has("never_providers")) | profiles($r.use)[] | select(family_of(.) as $f | $f != null and ($r.never_providers | index($f)) != null) | "rule \($i + 1) \(.harness):\(.model // "default")"] | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; type == "object" and has("quota_scope") and ((.quota_scope | type) != "string" or (.quota_scope | length) == 0)) then "each use profile quota_scope must be a non-empty string when present"
  elif any((.rules // [])[] | profiles(.use)[]; type == "object" and has("fallback_only") and ((.fallback_only | type) != "boolean")) then "each use profile fallback_only must be true or false when present"
  elif any((.rules // [])[] | profiles(.use)[]; type == "object" and has("seat_tier") and (seat_tier_ok(.seat_tier) | not)) then "each use profile seat_tier must be a positive integer when present"
  elif has("seat_tiers_by_delivery") and ((.seat_tiers_by_delivery | type) != "object" or any(.seat_tiers_by_delivery[]; type != "object" or any(.[]; seat_tier_ok(.) | not))) then "seat_tiers_by_delivery must map each delivery mode to account seat tiers that are positive integers"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif any((.pipeline_rows // [])[] | .use[]; profile_bad(.)) then "each pipeline_rows profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.pipeline_rows // [])[] | .use[]; (verified(.harness) | not)) then "each pipeline_rows profile must name a verified harness"
  elif any((.pipeline_rows // [])[] | .use[]; (effort_ok(.harness; .model; .effort) | not)) then "each pipeline_rows profile effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; type == "object" and has("quota_scope") and ((.quota_scope | type) != "string" or (.quota_scope | length) == 0)) then "each default profile quota_scope must be a non-empty string when present"
  elif has("default") and any(profiles(.default)[]; type == "object" and has("fallback_only") and ((.fallback_only | type) != "boolean")) then "each default profile fallback_only must be true or false when present"
  elif has("default") and any(profiles(.default)[]; type == "object" and has("seat_tier") and (seat_tier_ok(.seat_tier) | not)) then "each default profile seat_tier must be a positive integer when present"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"
# S1: with an account registry present every profile names a registered account
# that owns its harness store and serves its provider, so nothing falls onto the
# home pin store (the supervisor's own login) without saying so.
account_problems=$(fm_account_dispatch_problems "$CONFIG/accounts.json" "$RULES")
[ -z "$account_problems" ] || die "malformed rules file: $RULES_PATH - $(printf '%s' "$account_problems" | paste -sd ';' - | sed 's/;/; /g')"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)"),
  ((.pipeline_rows // [])[] | .use[] | select(has("provider") | not) | "pipeline_rows\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
  fi
done)
if [ -n "$missing_provider" ]; then
  missing_provider_detail=''
  while IFS=$'\t' read -r location harness; do
    missing_provider_detail="${missing_provider_detail:+$missing_provider_detail; }$location profiles whose harness lacks one authoritative provider family require provider: $harness"
  done <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $missing_provider_detail"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
PMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null) + [(.pipeline_rows // [])[] | .use[]])
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

emit_error() {
  local reason=$1
  [ "$MODE" = worker ] || die "$reason"
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

if [ "$MODE" = worker ] && [ "$RULE_COUNT" -eq 0 ] && ! jq -e 'has("default")' "$RULES" >/dev/null; then
  no_rules
fi
if [ "$MODE" = pipeline ] && ! jq -e --arg step "$STEP" 'any((.pipeline_rows // [])[]; .steps | index($step))' "$RULES" >/dev/null; then
  die "no pipeline_rows row names step $STEP"
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
SEND_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA" "$TASK_TEXT" "$SEND_TEXT"' EXIT

never_send_off() {
  echo "dispatch-resolve: off ($1; nothing sent)" >&2
  exit 0
}

# Checks every string the request carries, so no text reaches the network
# unchecked. grep's own stderr is discarded because it can echo the pattern.
never_send_check() {
  local list value n=0 rc
  [ -e "$NEVER_SEND_PATH" ] || [ -L "$NEVER_SEND_PATH" ] || return 0
  { [ -f "$NEVER_SEND_PATH" ] && [ -r "$NEVER_SEND_PATH" ]; } \
    || never_send_off "$NEVER_SEND_PATH is not a readable regular file"
  # Collapse whitespace runs on both sides so a value the brief wraps across
  # lines or spaces differently still matches
  jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$REQUEST" > "$SEND_TEXT" 2>/dev/null \
    || never_send_off "could not extract the request text to check"
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$NEVER_SEND_PATH" 2>/dev/null) \
    || never_send_off "could not read $NEVER_SEND_PATH"
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$SEND_TEXT" 2>/dev/null; rc=$?
    case "$rc" in
      0) never_send_off "brief text matches $NEVER_SEND_PATH line $n" ;;
      1) ;;
      *) never_send_off "could not check the request text against $NEVER_SEND_PATH line $n" ;;
    esac
  done <<<"$list"
}

# Send Jev only the task-specific sections bin/fm-brief.sh scaffolds, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# A brief with neither section goes whole. Ship delivery mode is deliberately
# not sent: live runs showed it pushing routine ship briefs to the top tier.
brief_kind() {
  if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$BRIEF"; then
    printf 'Brief kind: scout (report only)\n\n'
  fi
}
task_sections() {
  local heading
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$BRIEF" "$heading" || continue
    printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$BRIEF" "$heading")"
  done
}
LAT_MS=null
# Pipeline mode resolves a fixed row, so nothing below reaches the socket.
if [ "$MODE" = worker ]; then
  SECTIONS=$(task_sections)
  if [ -n "$SECTIONS" ]; then
    { brief_kind; printf '%s\n' "$SECTIONS"; } > "$TASK_TEXT" || die "could not read brief: $BRIEF"
  else
    cp "$BRIEF" "$TASK_TEXT" || die "could not read brief: $BRIEF"
  fi
  command -v python3 >/dev/null 2>&1 || emit_error "python3 not installed"
  REQUEST=$(jq -n --rawfile brief "$TASK_TEXT" --arg project "$PROJECT" --arg model "$TS_MODEL" \
    --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
    ($rules[0] | .rules //= []) as $cfg |
    ($cfg.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
    {
      model: $model,
      state: {task: {project: $project, brief: $brief}},
      questions: {
        rule: {
          type: "choice",
          instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
          criteria: ($criteria + {default: $none_criterion})
        },
        profile: {
          type: "choice",
          instructions: "Choose the best candidate and effort for this task from the rule you matched above. These are preferences only; code checks eligibility and quota independently.",
          criteria: (([$cfg.rules | to_entries[] | .key as $i | .value as $rule |
            (if ($rule.use | type) == "array" then $rule.use else [$rule.use] end) | to_entries[] |
            {key: "rule_\($i + 1)_\(.key + 1)", value: "\($rule.when) | \(.value.harness) \(.value.model // "default") effort=\(.value.effort // "default")"}] +
            [($cfg.default // [] | if type == "array" then . else [.] end) | to_entries[] |
             {key:"default_\(.key + 1)",value:"Default | \(.value.harness) \(.value.model // "default") effort=\(.value.effort // "default")"}]) | from_entries)
        }
      }
    }')
  never_send_check
  T0=$(fm_timing_now_ms)
  # A restarting jevd (its service manager owns the restart) gets a bounded
  # moment to bring the socket back before the first attempt; never started here.
  jev_wait_deadline=$(( $(date +%s) + JEV_SOCKET_WAIT_SECONDS ))
  while [ ! -S "$JEV_SOCKET" ] && [ "$(date +%s)" -lt "$jev_wait_deadline" ]; do
    sleep 0.5
  done
  jev_ok=0
  for jev_attempt in 1 2; do
    if ! printf '%s' "$REQUEST" | python3 "$SCRIPT_DIR/fm-jevd-dispatch.py" "$JEV_SOCKET" > "$RESP_FILE"; then
      continue
    fi
    if jq -e --slurpfile rules "$RULES" '
    (($rules[0].rules // [] | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
    (([$rules[0].rules // [] | to_entries[] | .key as $i | .value.use | (if type == "array" then . else [.] end) | to_entries[] | "rule_\($i + 1)_\(.key + 1)"] +
      [($rules[0].default // [] | if type == "array" then . else [.] end) | to_entries[] | "default_\(.key + 1)"]) | sort) as $profiles |
    (.answers.profile.choice | type) == "string" and
    (.answers.profile.choice as $preferred | ($profiles | index($preferred)) != null) and
    (.answers.profile.confidence | type) == "number" and
    .answers.profile.confidence >= 0 and .answers.profile.confidence <= 1 and
    (.answers.profile.probabilities | type) == "object" and
    ((.answers.profile.probabilities | keys | sort) == $profiles) and
    all(.answers.profile.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    ((.answers.profile.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    (.answers.rule.choice | type) == "string" and
    (.answers.rule.choice as $chosen | ($choices | index($chosen)) != null) and
    (.answers.rule.confidence | type) == "number" and
    .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
    (.answers.rule.probabilities | type) == "object" and
    ((.answers.rule.probabilities | keys | sort) == $choices) and
    all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number"))' \
  "$RESP_FILE" >/dev/null 2>&1; then
      jev_ok=1
      break
    fi
  done
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  if [ "$jev_ok" -ne 1 ]; then
    if [ -S "$JEV_SOCKET" ]; then
      JEV_FAILED_REASON="jevd error or invalid Choice after $jev_attempt attempts (one retry)"
    else
      JEV_FAILED_REASON="jevd socket $JEV_SOCKET absent after ${JEV_SOCKET_WAIT_SECONDS}s and $jev_attempt attempts (one retry)"
    fi
    # No row is assumed: the captain picks from every row (status captain-pick).
    jq -n '{model: null, requestId: null, answers: {rule: {choice: "default", confidence: 0, probabilities: {}}, profile: {choice: "", confidence: 0, probabilities: {}}}}' > "$RESP_FILE"
  fi
fi

# ---- plan evidence: declared plans in config/accounts.json ---------------------
PLAN_CONFIG='{}'
if fm_account_registry_valid "$CONFIG/accounts.json"; then
  PLAN_CONFIG=$(jq -c 'def plans: if type == "object" then . else {} end; {default: (.plans | plans), accounts: (.accounts | with_entries(.value = (.value.plans | plans)))}' "$CONFIG/accounts.json")
fi
# ---- quota evidence: one snapshot per authorized credential store -------------
# The whole read has one deadline, set here so a slow Jev answer cannot spend it.
if [ "$MODE" = worker ]; then
  [ "$QUOTA_WAIT_SECONDS" -le "$FM_QUOTA_READ_DEADLINE" ] || QUOTA_WAIT_SECONDS=$FM_QUOTA_READ_DEADLINE
  QUOTA_DEADLINE=$(( $(date +%s) + QUOTA_WAIT_SECONDS ))
fi
# Default quota reads must use the same captain-owned pins as launch and intake.
DEFAULT_CLAUDE_STORE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
DEFAULT_PI_STORE=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
for default_harness in claude pi; do
  default_selection=$(fm_worker_account_resolve "$default_harness" "$CONFIG") || die "invalid $default_harness worker account pin"
  [ -n "$default_selection" ] || continue
  default_store=${default_selection#*$'\t'}
  default_store=${default_store%%$'\t'*}
  case "$default_harness" in
    claude) DEFAULT_CLAUDE_STORE=${default_store:-$HOME/.claude} ;;
    pi) DEFAULT_PI_STORE=$default_store ;;
  esac
done
# Under the shared-quota opt-out no quota-axi call is made: a stub snapshot keeps
# the slurpfile contract, and registered accounts are recorded without one.
SQ=false
SHARED_QUOTA=$(jq -r '.shared_quota // false' "$RULES" 2>/dev/null) || SHARED_QUOTA=false
[ "$SHARED_QUOTA" != true ] || SQ=true
# Every pipeline profile names an account, so that mode never reads the home store.
if [ "$SQ" = true ] || [ "$MODE" = pipeline ]; then
  printf '{"providers":[]}\n' > "$QUOTA"
fi
# fm_dispatch_recent_read <cache-file> <fresh-file> <read-ok 0|1> <claude> <pi> <codex>: R11. Turns a
# fresh read into the snapshot to rank on: rows a rate limit or other transient
# failure left unmeasured reuse that store's last good reading while it is at
# most FM_QUOTA_RECENT_MAX_AGE (86400) seconds old, and a read that failed
# outright is answered from recent readings alone. rc 1 when nothing usable.
fm_dispatch_recent_read() {
  local cache=$1 fresh=$2 ok=$3 merged
  shift 3
  merged=$(mktemp) || return 1
  if [ "$ok" -eq 1 ]; then
    fm_quota_recent_save "$cache" "$fresh" "$@"
    if fm_quota_recent_merge "$cache" "$fresh" "$@" > "$merged" 2>/dev/null && fm_quota_json_valid < "$merged"; then
      mv -f "$merged" "$fresh"
    else
      rm -f "$merged"
    fi
    return 0
  fi
  if fm_quota_recent_merge "$cache" "" "$@" > "$merged" 2>/dev/null && fm_quota_json_valid < "$merged"; then
    mv -f "$merged" "$fresh"
    return 0
  fi
  rm -f "$merged"
  return 1
}
fm_dispatch_store_key() {  # <claude> <pi> <codex>: canonical store triple
  local one
  for one in "$@"; do
    if [ "$one" = "$FM_ACCOUNT_NO_STORE" ] || [ -z "$one" ]; then printf '%s\n' "${one:--}"
    else fm_account_canonical_store "$one"; fi
  done
}
# Validity decides whether a read counted, not its exit status: quota-axi exits 1
# with a full report when every provider failed, and that report names a bad login.
gather_home_quota() {  # refresh $QUOTA; a failed read keeps the previous snapshot
  local fresh ok=1 cache
  local -a canon=()
  fresh=$(mktemp) || { printf 'mktemp failed'; return 1; }
  cache=$(fm_quota_recent_file "$STATE")
  mapfile -t canon < <(fm_dispatch_store_key "$DEFAULT_CLAUDE_STORE" "$DEFAULT_PI_STORE" "${CODEX_HOME:-$HOME/.codex}")
  CLAUDE_CONFIG_DIR=$(fm_account_read_store claude "$DEFAULT_CLAUDE_STORE") PI_CODING_AGENT_DIR=$(fm_account_read_store pi "$DEFAULT_PI_STORE") fm_dispatch_bounded quota-axi --json > "$fresh" 2>/dev/null
  fm_quota_json_valid < "$fresh" || ok=0
  if ! fm_dispatch_recent_read "$cache" "$fresh" "$ok" "${canon[@]}"; then
    rm -f "$fresh"
    return 1
  fi
  mv "$fresh" "$QUOTA"
}
if [ "$SQ" = false ] && [ "$MODE" = worker ]; then
  # Nothing read and nothing cached is an unknown quota: an empty snapshot leaves
  # every home candidate unmeasured instead of stopping the choice.
  gather_home_quota || printf '{"providers":[]}\n' > "$QUOTA"
fi
gather_account_snapshot() {  # <account>: refresh ACCOUNT_QUOTAS[account] from its pinned store
  local account=$1 stores account_quota store_key
  [ -n "$account" ] || return 0
  stores=()
  mapfile -t stores < <(fm_account_stores "$CONFIG/accounts.json" "$account")
  [ "${#stores[@]}" -eq 3 ] || return 0
  store_key=$(fm_dispatch_store_key "${stores[@]}" | jq -Rsc .)
  account_quota=$(mktemp) || emit_error "mktemp failed"
  local read_ok=1 recent_cache
  local -a canon=()
  recent_cache=$(fm_quota_recent_file "$STATE")
  mapfile -t canon < <(fm_dispatch_store_key "${stores[0]}" "${stores[1]}" "${stores[2]}")
  CODEX_HOME=$(fm_account_read_store codex "${stores[2]}") PI_CODING_AGENT_DIR=$(fm_account_read_store pi "${stores[1]}") CLAUDE_CONFIG_DIR=$(fm_account_read_store claude "${stores[0]}") fm_dispatch_bounded quota-axi --json > "$account_quota" 2>/dev/null
  fm_quota_json_valid < "$account_quota" || read_ok=0
  if ! fm_dispatch_recent_read "$recent_cache" "$account_quota" "$read_ok" "${canon[@]}"; then
    ACCOUNT_QUOTAS=$(jq -c --arg a "$account" --arg key "$store_key" '. + {($a): {key: $key, failed: true}}' <<<"$ACCOUNT_QUOTAS")
  else
    ACCOUNT_QUOTAS=$(jq -c --arg a "$account" --arg key "$store_key" --slurpfile snapshot "$account_quota" '. + {($a): {key: $key, snapshot: $snapshot[0]}}' <<<"$ACCOUNT_QUOTAS")
  fi
  rm -f "$account_quota"
}
ACCOUNT_QUOTAS='{}'
while IFS= read -r account; do
  [ -n "$account" ] || continue
  stores=()
  mapfile -t stores < <(fm_account_stores "$CONFIG/accounts.json" "$account")
  [ "${#stores[@]}" -eq 3 ] || continue
  # Memoize identical store triples; no candidate gets another account's quota.
  store_key=$(fm_dispatch_store_key "${stores[@]}" | jq -Rsc .)
  previous=$(jq -r --arg key "$store_key" 'to_entries[] | select(.value.key == $key) | .key' <<<"$ACCOUNT_QUOTAS" | head -n 1)
  if [ -n "$previous" ]; then
    ACCOUNT_QUOTAS=$(jq -c --arg a "$account" --arg prev "$previous" '. + {($a): .[$prev]}' <<<"$ACCOUNT_QUOTAS")
    continue
  fi
  if [ "$SQ" = true ]; then
    ACCOUNT_QUOTAS=$(jq -c --arg a "$account" --arg key "$store_key" '. + {($a): {key: $key, shared: true}}' <<<"$ACCOUNT_QUOTAS")
    continue
  fi
  gather_account_snapshot "$account"
done < <(jq -r --arg mode "$MODE" --arg step "$STEP" '
  if $mode == "pipeline" then [(.pipeline_rows // [])[] | select(.steps | index($step)) | .use[] | .account] | unique[]
  else [((.rules // [])[] | .use | if type == "array" then .[] else . end), (.default // empty | if type == "array" then .[] else . end) | .account // empty] | unique[] end' "$RULES")
# Routing off or an unregistered seat is a configuration fact, never quota exhaustion.
if [ "$MODE" = pipeline ]; then
  unrouted=$(jq -r --argjson quotas "$ACCOUNT_QUOTAS" --arg step "$STEP" '[(.pipeline_rows // [])[] | select(.steps | index($step)) | .use[] | .account | select($quotas[.] == null)] | unique | join(", ")' "$RULES")
  [ -z "$unrouted" ] || die "pipeline seat not routable (cross-account routing off or account not registered): $unrouted"
fi

# ---- C5 round-robin slot: a fixed rotation over exactly tied candidates --------
TIE_RR_FILE=$STATE/dispatch-tie-round-robin
TIE_RR=$(cat "$TIE_RR_FILE" 2>/dev/null) || TIE_RR=0
case "$TIE_RR" in '' | *[!0-9]*) TIE_RR=0 ;; esac
[ "${#TIE_RR}" -le 9 ] || TIE_RR=0
# ---- resolution: declared gates + quota evidence + argmax, all in jq ----------
# Seat evaluation shared by worker and pipeline resolution: quota evidence,
# completeness, reserve and seat-tier holds, and the spend-priority argmax. It
# expects $cfg and $q bound, and the --argjson values both programs pass.
# shellcheck disable=SC2016  # a jq program, expanded by jq and not the shell
FM_DR_SEAT_JQ='
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def account_quota($c): (if $c.account then $account_quotas[$c.account].snapshot else $q end);
  def prov($p; $lane): quota_row(.; $p; $lane);
  def lane_of($c): quota_lane($c.harness; $c.model);
  def rows($p; $lane): (prov($p; $lane).quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def plan_label($v): if ($v | type) == "string" and ($v | length) > 0 and ($v | length) <= 80 and ($v | test("^[[:print:]]+$")) then $v else null end;
  def plan_for($c; $p):
    ((if $c.account then $account_quotas[$c.account].snapshot else $q end) // {providers: []}) as $snapshot |
    (plan_label(if $c.account then $plan_config.accounts[$c.account][$p] else $plan_config.default[$p] end)) as $declared |
    ($snapshot | quota_row(.; $p; lane_of($c)) | .plan | plan_label(.)) as $quota_plan |
    if $declared != null and $quota_plan != null then {plan: $declared, plan_source: "config; quota-axi: \($quota_plan)"}
    elif $declared != null then {plan: $declared, plan_source: "config"}
    elif $quota_plan != null then {plan: $quota_plan, plan_source: "quota-axi"}
    else {plan: "unknown", plan_source: "unavailable"} end;
  def measured($p; $lane):
    (prov($p; $lane)) as $provider |
    ($provider != null and (["known", "partial"] | index($provider.quotaSemantics.status)) != null);
  def applicable($p; $lane; $m; $qs):
    (bare($m)) as $bare |
    [rows($p; $lane)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare))) or
      ($qs != null and .scope == $qs)
    )];
  def floor_state($f; $p; $lane):
    if $f == null then "none"
    elif prov($p; $lane) == null or (measured($p; $lane) | not) then "unmeasured"
    else [rows($p; $lane)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 then "absent"
        elif any($matches[]; .status != "known") then "unmeasured"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def provider_windows($p; $lane): (prov($p; $lane).windows // []);
  def window_row($p; $lane; $id): ([provider_windows($p; $lane)[] | select(.id == $id)] | first) // null;
  def clean_reset($t): ($t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z"));
  # Fallback-only reserve seat test: only the weekly window decides whether a
  # non-fallback seat still has capacity, because the weekly allowance is the
  # real limit such a reserve protects; a session (5h) window alone never
  # makes a seat ineligible for the reserve test.
  def reserve_weekly_window($snap; $p; $lane):
    ([$snap | provider_windows($p; $lane)[] | select(.id == "seven_day" or .kind == "weekly")] | first) // null;
  def seat_at_limit($c):
    provider_of($c) as $p | lane_of($c) as $lane |
    if $p == null then false
    else account_quota($c) as $snap |
      reserve_weekly_window($snap; $p; $lane) as $w |
      if $w == null then false
      else (($w.percentRemaining // 100) <= 0) or
        any(($snap | rows($p; $lane))[];
            ((.boundedBy // []) | index($w.id)) != null and (.runway.status // "") == "exhausted_now")
      end
    end;
  def unmeasured_ids($p; $lane):
    ([rows($p; $lane)[] | (.selection.unmeasurableWindowIds // .runway.unmeasurableWindowIds // [])[]] | unique) as $ids |
    (if ($ids | length) == 0 then [provider_windows($p; $lane)[] | .id] | unique else $ids end);
  def applicable_window_ids($p; $lane; $m; $qs):
    # first-occurrence order keeps session and weekly windows ahead of model windows
    def dedupe: reduce .[] as $x ([]; if (. | index($x)) then . else . + [$x] end);
    (applicable($p; $lane; $m; $qs)) as $rows |
    ([ $rows[] | (.boundedBy // [])[] ] | dedupe) as $ids |
    (if ($ids | length) == 0
     then [provider_windows($p; $lane)[] | select((.kind // "") != "model") | .id] | dedupe
     else $ids end);
  # Captain 2026-11-02 (C3): a readable five-hour window counts; one that is
  # missing or unreadable is ignored on every account and never makes the
  # choice incomplete.
  # Run on the snapshot: the ids of five-hour windows (by id or kind).
  def five_hour_ids($p; $lane):
    (["five_hour"] + [provider_windows($p; $lane)[] | select((.kind // "") == "five_hour" or (.kind // "") == "session") | .id]) | unique;
  def only_five_hour_unknown($r; $five):
    (($r.selection.unmeasurableWindowIds // $r.runway.unmeasurableWindowIds // []) as $u |
     ($r.effectivePercentRemaining | type) == "number" and ($u | length) > 0 and all($u[]; . as $id | $five | index($id) != null));
  def credential_failed($p; $lane): ((prov($p; $lane).state.status // "") == "auth_required");
  def completeness($p; $lane; $c):
    (five_hour_ids($p; $lane)) as $five |
    (prov($p; $lane).state.error // null) as $state_error |
    (prov($p; $lane).state.retryAfter // null) as $retry_after |
    if prov($p; $lane) == null then {complete: false, missing: ["*"], reason:
      (if .schemaVersion == 6 and $lane != "" then "provider \($p) has no quota row for account \($lane)"
       else "provider \($p) absent from the quota snapshot" end)}
    elif (measured($p; $lane) | not) then
      {complete: false, missing: (unmeasured_ids($p; $lane)),
       reason: "provider \($p) unmeasured (\(prov($p; $lane).quotaSemantics.status)\(if (prov($p; $lane).state.status // "") == "rate_limited" then ", rate limited" else "" end))",
       state_error: $state_error, retry_after: $retry_after}
    else
      (applicable($p; $lane; ($c.model // ""); ($c.quota_scope // null))) as $rows |
      if ($rows | length) == 0 then {complete: false, missing: ["*"], reason: "no applicable quota row for provider \($p)", state_error: $state_error, retry_after: $retry_after}
      elif any($rows[]; .status != "known" and (only_five_hour_unknown(.; $five) | not)) then
        ([ $rows[] | select(.status != "known" and (only_five_hour_unknown(.; $five) | not)) | (.selection.unmeasurableWindowIds // .runway.unmeasurableWindowIds // [.scope])[] ] | unique) as $miss |
        {complete: false, missing: $miss, reason: "unmeasured windows: \($miss | join(", "))",
         state_error: $state_error, retry_after: $retry_after}
      else
        (applicable_window_ids($p; $lane; ($c.model // ""); ($c.quota_scope // null))) as $ids |
        if ($ids | length) == 0 then {complete: false, missing: ["*"], reason: "no window reset evidence for provider \($p)"}
        else
          (provider_windows($p; $lane)) as $pws |
          ([$ids[] | . as $id | ([$pws[] | select(.id == $id)] | first) as $w |
            if $w == null or ($w.percentRemaining | type) != "number" or ($w.resetsAt | type) != "string"
            then (if ($five | index($id)) != null then empty else {id: $id, missing: true} end)
            else {id: $id, pct: $w.percentRemaining, resetsAt: clean_reset($w.resetsAt)}
            end]) as $wev |
          ([$wev[] | select(.missing)] | map(.id)) as $miss |
          if ($miss | length) > 0 then {complete: false, missing: $miss, reason: "windows without known percent or reset: \($miss | join(", "))"}
          elif ($wev | length) == 0 then {complete: false, missing: $ids, reason: "no readable window besides an ignored five-hour window for provider \($p)"}
          else {complete: true, windows: $wev}
          end
        end
      end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p | (lane_of($c)) as $lane |
    if $c.account and $account_quotas[$c.account] == null then
      {profile: $c, provider: $p, eligible: false, reason: "cross-account routing disabled or account not registered"}
    elif $sq then
      {profile: $c, provider: $p, eligible: true, sq: true, reason: "ok"}
    elif $c.account and $account_quotas[$c.account].failed then
      {profile: $c, provider: $p, eligible: false, incomplete: true, windows_missing: ["*"], reason: "quota-axi --json failed for account \($c.account)"}
    elif $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif (account_quota($c) | credential_failed($p; $lane)) then
      {profile: $c, provider: $p, eligible: false, credential: true,
       reason: "credential unusable for provider \($p)\(if $c.account then " on account \($c.account)" else "" end) (\((account_quota($c) | prov($p; $lane).state.error) // "auth_required")): sign in again; not an unknown quota"}
    else account_quota($c) |
      (prov($p; $lane).reusedReading.ageSeconds // null) as $reading_age |
      (applicable($p; $lane; ($c.model // ""); ($c.quota_scope // null))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p; $lane)) as $profile_floor_state |
      (completeness($p; $lane; $c)) as $gate |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p; $lane)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif ($gate.complete | not) then
        {profile: $c, provider: $p, bounds: $bounds, eligible: false, incomplete: true,
         windows_missing: ($gate.missing // []),
         reason: ($gate.reason // "quota window evidence incomplete"),
         state_error: ($gate.state_error // null), retry_after: ($gate.retry_after // null)}
      elif $profile_floor_state == "unmeasured" then
        {profile: $c, provider: $p, bounds: $bounds, eligible: false, incomplete: true,
         windows_missing: [$c.floor.scope],
         reason: "profile floor \($c.floor.scope) is unmeasured",
         state_error: (prov($p; $lane).state.error // null), retry_after: (prov($p; $lane).state.retryAfter // null)}
      elif ($c.quota_scope != null and (any($rows[]; .scope == $c.quota_scope) | not)) then
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $c.quota_scope, eligible: true, unranked: true, reason: "declared quota_scope \($c.quota_scope) has no quota row for provider \($p): not rankable"}
      elif $profile_floor_state == "absent" then
        ([rows($p; $lane)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, windows: ($gate.windows // null), scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        # The binding window: the soonest reset among the windows bounding the
        # limiting row (every row tied for limiting), used only to break an
        # exact spendPriority tie (C5).
        ([$rows[] | select(.selection.spendPriority == $limiting.selection.spendPriority) | (.boundedBy // [])[]] | unique) as $binding_ids |
        ([($gate.windows // [])[] | select(. as $w | $binding_ids | index($w.id)) | .resetsAt]
          | if length == 0 then [($gate.windows // [])[] | .resetsAt] else . end | min) as $binding_reset |
        {profile: $c, provider: $p, bounds: $bounds, windows: $gate.windows, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, binding_reset: $binding_reset,
         reading_age: $reading_age, eligible: true, reason: "ok"}
      end
    end;
  # Fallback-only reserve tier over one candidate set (see the header).
  def reserve_tier: . as $cands | map(. as $cand |
    if (($cand.profile.fallback_only // false) | not) or $cand.provider == null then $cand
    else
      ([$cands[] | select((.profile.fallback_only // false) | not) | select(.provider == $cand.provider) | select((.banned // false) | not)]) as $kin_all |
      # A seat that cannot be read or signed in to has no known capacity to protect.
      ([$kin_all[] | select((.incomplete // false) or (.credential // false) | not)]) as $kin |
      if any($kin[]; seat_at_limit(.profile) | not) then
        # A held reserve is out of this choice, so its own quota, known or
        # not, never makes the choice incomplete.
        ($cand | del(.incomplete, .windows_missing, .unranked)) + {eligible: false, reserve: true,
          reason: ("fallback_only reserve held: non-fallback " + $cand.provider + " seats not at their limit (" +
            ([$kin[] | select(seat_at_limit(.profile) | not) |
              "\(.profile.harness):\(.profile.model // "default")" +
              (if .profile.account then "@\(.profile.account)" else "" end)] | join(", ")) + ")")}
      elif ($cand.sq // false) or (($cand.eligible // false) | not) or ($cand.unranked // false) then $cand + {reserve: true}
      else $cand + {reserve: true, reserve_active: true,
        reason: ("reserve pick: every non-fallback " + $cand.provider + " seat is at its limit (weekly window at or above 100% used or runway exhausted_now)" +
          (if ($kin_all | length) > ($kin | length) then " or unreadable" else "" end))}
      end
    end);
  # Seat tiers over one candidate set (see the header). An absent tier sorts last.
  def seat_rank($c): ((($cfg.seat_tiers_by_delivery // {})[$delivery] // {})[$c.account // ""] // $c.seat_tier // 1e9);
  def seat_label: "\(.profile.harness):\(.profile.model // "default")" + (if .profile.account then "@\(.profile.account)" else "" end);
  # $unreadable_holds: pipeline pools stay shut on unreadable quota; dispatch
  # never lets an unreadable seat hold a later tier.
  def seat_tier_hold($unreadable_holds):
    if all(.[]; seat_rank(.profile) == 1e9) then .
    else map(. + {at_limit: (((.banned // false) | not) and seat_at_limit(.profile))}) |
      ([.[] | select(.at_limit | not) | select(.eligible or ($unreadable_holds and (.incomplete // false)))]) as $live |
      ([$live[] | seat_rank(.profile)] | min) as $open |
      map(seat_rank(.profile) as $rank | if .at_limit then
          del(.incomplete, .windows_missing, .unranked) + {eligible: false, reason: "seat_tier \($rank): at its weekly limit"}
        elif $open != null and $rank > $open and (.eligible or (.incomplete // false)) then
          del(.incomplete, .windows_missing, .unranked) + {eligible: false, reason:
            ("seat_tier held: an earlier seat still has capacity (" + ([$live[] | select(seat_rank(.profile) == $open) | seat_label] | join(", ")) + ")")}
        else . end | del(.at_limit))
    end;
  # While a candidate is rankable, an unreadable one is listed but out of the choice.
  def skip_unreadable:
    if any(.[]; .eligible and ((.unranked // false) | not)) then
      map(if .incomplete then del(.incomplete) + {unreadable: true, reason: "quota unreadable, skipped: \(.reason)"} else . end)
    else . end;
  # Spend-priority argmax over a ranked candidate set. C5: an exact tie goes to
  # the sooner reset of the binding window, then to a fixed round-robin over a
  # stable order; both are logged.
  def reset_epoch($c): ($c.binding_reset // null) as $r | if ($r | type) == "string" then ($r | try fromdateiso8601 catch null) else null end;
  def rank_winner:
    . as $ranked |
    ($ranked | max_by(.spendPriority)) as $best |
    ([$ranked[] | select(.spendPriority == $best.spendPriority)]) as $ties |
    (if ($ties | length) < 2 then {winner: $best}
     else
       ([$ties[] | reset_epoch(.)] | map(select(. != null)) | min) as $soonest |
       (if $soonest == null then $ties else [$ties[] | select(reset_epoch(.) == $soonest)] end
         | sort_by([(.profile.account // ""), .profile.harness, (.profile.model // ""), (.profile.effort // "")])) as $ordered |
       ($rr % ($ordered | length)) as $slot |
       {winner: $ordered[$slot], round_robin: (($ordered | length) > 1),
        tie_break: ("\($ties | length) candidates tied at spendPriority \($best.spendPriority); " +
          (if $soonest == null then "no binding reset known" else "sooner binding reset \($soonest | todate) kept \($ordered | length)" end) +
          (if ($ordered | length) > 1 then "; round-robin slot \($slot + 1) of \($ordered | length)" else "" end) +
          " -> \($ordered[$slot].profile.harness):\($ordered[$slot].profile.model // "default")\(if $ordered[$slot].profile.account then " @" + $ordered[$slot].profile.account else "" end)")}
     end);
'
# Pipeline resolution for one step's fixed row (see the header): no model, no
# receipt, and every pool decision made by the shared seat logic above.
fm_dispatch_pipeline_json() {  # <quota attempts> <warm-ups run> [final]
  jq -cn --arg step "$STEP" --argjson pmap "$PMAP" --argjson account_quotas "$ACCOUNT_QUOTAS" --argjson plan_config "$PLAN_CONFIG" --argjson sq "$SQ" --argjson rr "$TIE_RR" \
    --argjson final "${3:-false}" --arg delivery '' --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" "$FM_QUOTA_ROW_JQ"'
  ($rules[0]) as $cfg | ($quota[0]) as $q |
'"$FM_DR_SEAT_JQ"'
  # The weekly floor reads the weekly window itself, because a row bounded by
  # both windows would also trip on a live five-hour window. Room left must stay
  # above the floor; a floor that cannot be read never fails open at the deadline.
  def weekly_window($e): reserve_weekly_window(account_quota($e.profile) // {providers: []}; $e.provider; lane_of($e.profile));
  def apply_weekly_floor:
    . as $e | $e.profile.weekly_floor_percent as $f |
    if $f == null or $sq or (($e.eligible or ($e.incomplete // false)) | not) then $e
    else (weekly_window($e).percentRemaining) as $pct |
      if ($pct | type) == "number" then
        if $pct <= $f then
          ($e | del(.incomplete, .windows_missing, .unranked)) + {eligible: false, floor_stop: true, reason: "weekly floor: \($pct)% left, stops at \($f)%"}
        else $e end
      elif $final then
        ($e | del(.incomplete, .windows_missing, .unranked)) + {eligible: false, reason: "weekly floor \($f)% is unverifiable: no weekly reading"}
      else
        $e + {eligible: false, incomplete: true, windows_missing: (($e.windows_missing // []) + ["weekly"] | unique), reason: "weekly floor \($f)% is unmeasured"}
      end
    end;
  # A live window that will not last: projected exhaustion inside the usable
  # runway limit. An idle five-hour window with no reset stays noise.
  def limiting_ids: [(.runway.limitingWindowId // empty), (.runway.limitingWindowIds // [])[], (.limitingWindowIds // [])[]];
  def short_runway($e):
    if $sq then false
    else $e.provider as $p | lane_of($e.profile) as $lane | account_quota($e.profile) |
      five_hour_ids($p; $lane) as $five | provider_windows($p; $lane) as $windows |
      any(applicable($p; $lane; ($e.profile.model // ""); ($e.profile.quota_scope // null))[];
        (.runway.status // "") == "projected_exhaustion"
        and ((.runway.usableRunwaySeconds | type) == "number" and .runway.usableRunwaySeconds < 5400)
        and (limiting_ids as $ids | (($ids | length) > 0 and all($ids[]; . as $id |
              ($five | index($id)) != null
              and (([$windows[] | select(.id == $id)] | first | .resetsAt? | type) != "string"))) | not))
    end;
  # When an out seat comes back: its emptied windows (the latest of them), else
  # its weekly window. Null when no reset is known.
  def seat_reset($e):
    (account_quota($e.profile) // {providers: []}) as $snap |
    ($snap | provider_windows($e.provider; lane_of($e.profile))) as $windows |
    ($snap | [rows($e.provider; lane_of($e.profile))[] | select((.runway.status // "") == "exhausted_now") | limiting_ids[]]) as $limiting |
    ([$windows[] | select((.resetsAt | type) == "string") | select(((.percentRemaining | type) == "number" and .percentRemaining <= 0) or (.id as $id | $limiting | index($id)) != null) | clean_reset(.resetsAt)] | max) as $emptied |
    (reserve_weekly_window($snap; $e.provider; lane_of($e.profile)).resetsAt) as $weekly |
    if (($e.floor_stop // false) | not) and $emptied != null then $emptied
    elif ($weekly | type) == "string" then clean_reset($weekly)
    else $emptied end;
  ([($cfg.pipeline_rows // [])[] | select(.steps | index($step))] | first) as $row |
  ($row.use | map(. as $c | evaluate($c) | apply_weekly_floor | . + {out_reason: .reason}) | seat_tier_hold(true)) as $cands |
  def seat_view: {seat: .profile.account, pool: .profile.pool, tier: .profile.seat_tier, eligible: (.eligible // false), reason: .reason,
    remaining: (.pct // null), spendPriority: (.spendPriority // null), runway: (.runway // null)};
  ([$cands[] | select(.incomplete)]) as $incomplete |
  ([$cands[] | select(.eligible or (.incomplete // false))]) as $open |
  if ($incomplete | length) > 0 and ($final | not) then
    {status: "incomplete", step: $step, reason: "quota window evidence incomplete", candidates: [$cands[] | seat_view],
     incomplete: [$incomplete[] | {account: .profile.account, provider: (.provider // null), missing: (.windows_missing // []), retry_after: (.retry_after // null)}]}
  elif ($open | length) == 0 then
    {status: "exhausted", step: $step, reason: "quota exhausted: no seat with room in any pool",
     seats: [$cands[] | {seat: .profile.account, pool: .profile.pool, reset: seat_reset(.), reason: .out_reason}]}
  else
    ([$open[] | select(.eligible and ((.unranked // false) | not))]) as $ready |
    ([$ready[] | select(short_runway(.) | not)]) as $lasting |
    (if ($lasting | length) > 0 then $lasting else $ready end) as $ranked |
    (if ($ready | length) == 0 then {winner: ($open | first), measured: false}
     elif $sq then {winner: ($ready | first), measured: true}
     else ($ranked | rank_winner) + {measured: true} end) as $tb |
    ($tb.winner) as $w |
    ($ready | length) as $n_ready |
    ([$ready[] | select(short_runway(.)) | .profile.account]) as $short |
    {status: "ok", step: $step, seat: $w.profile.account, harness: $w.profile.harness, model: ($w.profile.model // null), effort: ($w.profile.effort // null),
     provider: ($w.provider // null), pool: $w.profile.pool, tier: $w.profile.seat_tier, reasoning_class: $w.profile.reasoning_class, measured: $tb.measured,
     reason: ("pool \($w.profile.pool) tier \($w.profile.seat_tier): " +
       (if ($tb.measured | not) then "quota unreadable, first seat of the open tier"
        elif $sq then "quota ranking off, declared order"
        else "best spendPriority of \($ranked | length) seat(s)" end) +
       (if ($short | length) > 0 and ($lasting | length) > 0 then "; \($short | join(", ")) will not last to reset" else "" end) +
       (if ($n_ready > 0 and ($lasting | length) == 0) then "; no open seat lasts to reset" else "" end) +
       (if $w.profile.pool != ([$row.use[].pool] | min) then "; pool \([$row.use[].pool] | min) has no seat with room" else "" end)),
     candidates: [$cands[] | seat_view]}
    + (if $tb.tie_break then {tie_break: $tb.tie_break, tie_round_robin: ($tb.round_robin // false)} else {} end)
  end'
}
fm_dispatch_resolve_json() {  # <quota attempts> <warm-ups run>
  if [ "$MODE" = pipeline ]; then fm_dispatch_pipeline_json "$@"; return; fi
  jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" --argjson account_quotas "$ACCOUNT_QUOTAS" --argjson plan_config "$PLAN_CONFIG" --argjson quota_attempts "$1" --argjson warmups "$2" --argjson sq "$SQ" --argjson rr "$TIE_RR" \
    --argjson final "${3:-false}" --arg jev_failed "$JEV_FAILED_REASON" --argjson force_pick "$FORCE_PICK" --arg delivery "$BRIEF_DELIVERY" \
    --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" "$FM_QUOTA_ROW_JQ"'
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
'"$FM_DR_SEAT_JQ"'
  def rule_at($c):
    if ($c | test("^rule_[1-9][0-9]*$")) then
      ($c | ltrimstr("rule_") | tonumber) as $n |
      if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
    else null end;
  def declared_confidence($c): rule_at($c) as $x | $x != null and ($x | has("min_confidence"));
  def confidence_floor($c): if declared_confidence($c) then rule_at($c).min_confidence else ($floor | tonumber) end;
  # Captain-pick evidence: every row of the table, most probable first when Jev
  # answered, each candidate evaluated exactly as a clear resolution would be.
  def row_ids: [(($cfg.rules // []) | to_entries[] | "rule_\(.key + 1)"), (if $cfg | has("default") then "default" else empty end)];
  def row_use($id): if $id == "default" then profiles($cfg.default // null) else profiles(rule_at($id).use) end;
  def row_floor($id): (rule_at($id).floor // null) as $f | if $sq or $f == null then "none" else ($q | floor_state($f; $f.provider; "")) end;
  def pick_rows($probs):
    [row_ids | to_entries[] | .key as $order | .value as $id |
      (row_floor($id)) as $rf |
      ([row_use($id)[] | . as $c | (provider_of($c)) as $p |
        (if $rf == "below" then {profile: $c, provider: $p, eligible: false, reason: "row floor \(rule_at($id).floor.scope) below \(rule_at($id).floor.min_percent)%"}
         else evaluate($c) end) + plan_for($c; $p)] | reserve_tier | seat_tier_hold(false) | skip_unreadable) as $cs |
      ([$cs[] | select(.eligible and ((.unranked // false) | not) and ((.incomplete // false) | not)) | .profile.reasoning_class | select(type == "number")] | max // null) as $strongest |
      {id: $id, order: $order, when: (if $id == "default" then $none_criterion else rule_at($id).when end),
       approval: (rule_at($id).approval // null), row_floor: $rf,
       probability: (($probs // {})[$id] // null),
       candidates: [$cs[] | . + {strongest: ($strongest != null and .eligible and ((.unranked // false) | not) and .profile.reasoning_class == $strongest)}]}]
    | sort_by([-(.probability // -1), .order]);
  if $jev_failed != "" then
    {model: null, latency_ms: $lat, tokens: null, rule: null, rule_when: null, profile_preference: null,
     confidence: null, probabilities: {}, status: "captain-pick", jev_status: "down",
     reason: $jev_failed, pick: pick_rows({})}
  else
  ($a.choice) as $picked |
  (confidence_floor($picked)) as $picked_floor |
  # A declared floor is checked against the probability of that option whether
  # it is the pick or a runner-up, so a runner-up never needs weaker support
  # than it would as the pick. Only a rule that declares its own floor falls
  # through to a runner-up, so a file with no declared floors keeps the single
  # global floor on the answer confidence exactly.
  (if declared_confidence($picked) | not then
     (if $a.confidence >= $picked_floor then {below: false} else {below: true, global: true} end)
   elif $a.probabilities[$picked] >= $picked_floor then {below: false}
   else
     ([$a.probabilities | to_entries[] | select(.key != $picked and .value >= confidence_floor(.key))]
       | sort_by(-.value)) as $ok |
     if ($ok | length) == 0 then {below: true, why: "no other option clears its own floor"}
     elif ($ok | length) > 1 and $ok[1].value == $ok[0].value then {below: true, why: "runner-up tie"}
     else {below: true, to: $ok[0].key, p: $ok[0].value, to_floor: confidence_floor($ok[0].key)} end
   end) as $fb |
  (if $fb.to then $fb.to else $picked end) as $choice |
  (rule_at($choice)) as $rule |
  (if $sq or $rule == null then "none" else ($q | floor_state($rule.floor; $rule.floor.provider; "")) end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then []
   elif $rule == null then profiles($cfg.default // null)
   else profiles($rule.use)
   end) as $answer_use |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
   elif $rule_floor_state == "unmeasured" then {source: $choice, rule_floor_incomplete: true, use: profiles($rule.use), note: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unmeasured: gather first"}
   elif $rule_floor_state == "absent" then {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
   elif $rule_floor_state == "below"
     then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
   else {source: $choice, use: profiles($rule.use), note: "rule matched"} end) as $sel |
  ($fb.below and ($fb.to | not)) as $ambiguous |
  ([$a.probabilities | to_entries[] | select(.value >= 0.25) | .key]) as $union_ids |
  ([$union_ids[] | . as $id | if $id == "default" then profiles($cfg.default // null) else profiles(rule_at($id).use) end | .[]]) as $union |
  (if $ambiguous then $union else ($sel.use // $answer_use // []) end) as $raw_use |
  ($ambiguous and (any($union[]; (.reasoning_class | type) != "number") or ($union | length) == 0)) as $missing_class |
  # Anchor the class to the most probable row, not the hardest union member.
  # Equal row probabilities keep table order, with default after explicit rules.
  (row_ids | to_entries | map(select(.value as $id | $union_ids | index($id)))
    | sort_by([-$a.probabilities[.value], .key]) | first | .value) as $anchor_id |
  # With seat tiers the class comes from the first tier of that row, so a stronger
  # fallback seat cannot drop the default seat of the row out of the union.
  (if $anchor_id == null then [] else row_use($anchor_id) end
    | (map(seat_rank(.)) | min) as $first | map(select(seat_rank(.) == $first))) as $anchor_use |
  (if $ambiguous and ($missing_class | not) then ($anchor_use | map(.reasoning_class) | max) as $strongest | [$union[] | select(.reasoning_class == $strongest)] | unique else $raw_use end) as $decision_use |
  ($ambiguous and any($union_ids[]; rule_at(.).approval == "captain")) as $union_approval |
  ([$union_ids[] | . as $id | rule_at($id) | select(.floor != null) | .floor as $f |
    {id:$id, floor:$f, state:($q | floor_state($f; $f.provider; ""))}]) as $union_floors |
  ($decision_use | map(. as $c | (provider_of($c)) as $p |
    (if $ambiguous and any($union_floors[]; .state == "below" and (rule_at(.id).use | profiles(.) | index($c)) != null)
     then {profile:$c, provider:$p, eligible:false, reason:"ambiguous row floor below minimum"}
     else evaluate($c) end) + plan_for($c; $p))) as $evaluated |
  # S3: a provider a matched rule bans (never_providers) is never chosen, also
  # when an ambiguous union pulls in profiles of another rule of that provider.
  ((if $ambiguous then [$union_ids[] | rule_at(.) | select(. != null) | (.never_providers // [])[]]
    elif $rule != null then ($rule.never_providers // []) else [] end) | unique) as $banned |
  ([$evaluated[] | .provider as $pv | if ($pv != null and ($banned | index($pv)) != null)
      then del(.incomplete, .windows_missing, .unranked) + {eligible: false, banned: true, reason: "provider \(.provider) is banned for this work (never_providers)"}
      else . end]) as $unbanned |
  # Fallback-only reserve tier: a fallback candidate is eligible only once
  # every non-fallback candidate of the same provider family is at its limit
  # under the weekly-window seat test above; it then ranks below every
  # non-fallback candidate at selection.
  # An unmeasured rule floor gates the whole row, so its candidates stay as gathered.
  ($unbanned | reserve_tier | seat_tier_hold(false)
    | if ($sel.rule_floor_incomplete // false) or ($ambiguous and any($union_floors[]; .state == "unmeasured")) then . else skip_unreadable end) as $cands |
  ([$cands[] | select(.incomplete)]) as $incomplete |
  def when_of($c): (if rule_at($c) == null then $none_criterion else rule_at($c).when end | .[0:60]);
  ({
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $picked, profile_preference: $r.answers.profile.choice,
    rule_when: when_of($picked),
    confidence: $a.confidence, probabilities: $a.probabilities
  }
  + (if $fb.to then {fallback: "\($choice) (\(when_of($choice))) probability \($fb.p) clears its floor \($fb.to_floor); \($picked) probability \($a.probabilities[$picked]) is below its floor \($picked_floor)"} else {} end))
  as $ev |
  (if $missing_class then $ev + {status: "escalate", reason: "ambiguous union needs numeric reasoning_class on every candidate"}
  elif $union_approval then $ev + {status: "escalate", reason: "ambiguous union requires captain approval"}
  elif $ambiguous and any($union_floors[]; .state == "absent") then $ev + {status:"escalate",reason:"ambiguous union rule floor is unverifiable"}
  elif $ambiguous and any($union_floors[]; .state == "unmeasured") then
    $ev + {status:"incomplete",reason:"ambiguous union rule floor unmeasured",candidates:$cands,
      incomplete:[$union_floors[] | select(.state == "unmeasured") | {account:null,provider:.floor.provider,missing:[.floor.scope]}]}
  elif $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif ($incomplete | length) > 0 or ($sel.rule_floor_incomplete // false) then
    $ev + {
      status: "incomplete",
      reason: ("quota window evidence incomplete: " +
        (([$incomplete[] | "\(.profile.harness):\(.profile.model // "default") missing \((.windows_missing // []) | join(", "))"] +
          (if ($sel.rule_floor_incomplete // false)
           then ["rule floor \($rule.floor.provider)/\($rule.floor.scope) unmeasured"]
           else [] end)) | join("; "))),
      note: "\($quota_attempts) quota-axi attempt(s) and named warm-ups; no candidate is rankable",
      candidates: $cands,
      incomplete: (([$incomplete[] | {account: (.profile.account // null), provider: (.provider // null), missing: (.windows_missing // []), retry_after: (.retry_after // null)}]) +
        (if ($sel.rule_floor_incomplete // false)
         then [{account: null, provider: $rule.floor.provider, missing: [$rule.floor.scope], retry_after: (($q | prov($rule.floor.provider; "").state.retryAfter) // null)}]
         else [] end)),
      quota_attempts: $quota_attempts, warmups: $warmups
    }
  elif $sel.escalate and ($ambiguous | not) then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: $cands}
  elif ($decision_use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ([$cands[] | select(.provider == $cfg.preferred_provider)]) as $family |
    ([$family[] | select(.eligible)]) as $preferred_family |
    (if ($preferred_family | length) > 0 then $preferred_family else $cands end) as $pool |
    ($ev + (if $cfg.preferred_provider == null then {}
      else {preferred_provider: ($cfg.preferred_provider + ": " +
        (if ($family | length) == 0 then "not in matched profiles; preserve the selected rule"
         elif ($preferred_family | length) > 0 then "prefer eligible family candidates"
         else "fall back; every matched family candidate is ineligible" end))} end)) as $ev |
    ([$pool[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    # Reserve tier: a fallback_only candidate is picked only when no
    # non-fallback candidate is rankable, so it ranks below every other.
    ([$elig[] | select((.reserve // false) | not)]) as $elig_primary |
    (if ($elig_primary | length) > 0 then $elig_primary else $elig end) as $pickable |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($elig | length) == 0 then $ev + {status: "escalate",
      reason: ("no rankable eligible candidate" +
        (if ($preferred_family | length) > 0 then " in preferred provider \($cfg.preferred_provider); uncertainty does not authorize fallback" else "" end)),
      note: $sel.note, candidates: $cands}
    elif $sq then
      $ev + {status: "clear", note: ($sel.note + "; quota ranking off: home declares a single shared quota, declared order picks"), candidates: $cands, chosen: ($pickable | first), row: $sel.source}
    else
      # Keep-strongest classes: when every candidate in the pickable tier
      # declares a numeric reasoning_class, only the highest declared class
      # competes on spendPriority, so an unused weaker pool cannot outbid it
      # by quota alone.
      ($pickable | all((.profile.reasoning_class | type) == "number")) as $all_classed |
      (if $all_classed then ($pickable | map(.profile.reasoning_class) | max) else null end) as $strongest |
      (if $all_classed then [$pickable[] | select(.profile.reasoning_class == $strongest)] else $pickable end) as $ranked |
      ($ranked | rank_winner) as $tb |
      if false then empty
      else ($tb.winner) as $winner |
        (if $ambiguous then ([$union_ids[] | . as $id | (if $id == "default" then profiles($cfg.default) else profiles(rule_at($id).use) end) | select(index($winner.profile)) | $id] | first) else $sel.source end) as $winner_row |
        $ev + {status: "clear", note: ((if $ambiguous then "ambiguous union >= 0.25; strongest reasoning class of most probable row \($anchor_id)"
          elif ($ranked | length) < ($pickable | length) then "\($sel.note); strongest reasoning class \($strongest), \(($pickable | length) - ($ranked | length)) weaker eligible candidate(s) outranked"
          else $sel.note end)
               + (if ($winner.reserve_active // false) then "; \($winner.reason)" else "" end)
               + ([$cands[] | select(.unreadable) | seat_label] as $skipped | if ($skipped | length) > 0 then "; quota unreadable, skipped: \($skipped | join(", "))" else "" end)), candidates: $cands, chosen: $winner, row: $winner_row}
        + (if $tb.tie_break then {tie_break: $tb.tie_break, tie_round_robin: ($tb.round_robin // false)} else {} end)
        + (if ($unranked | length) > 0 then
             {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
           else {} end)
      end
    end
  end) as $out |
  # An unknown quota never blocks a start: the first declared seat of the open
  # tier starts marked quota unknown, and fm-quota-intake.sh logs that start.
  # Only a known stop or a rule that requires approval reaches the captain.
  (if $out.status == "incomplete" and $final and (($sel.escalate // null) == null) then
    ([$out.candidates[]? | select((.incomplete // false) or (.eligible // false))]) as $open |
    ([$open[] | select(.provider == $cfg.preferred_provider)]) as $family |
    (if ($family | length) > 0 then $family else $open end) as $pool |
    (if ($pool | length) > 0 and ($pool | all((.profile.reasoning_class | type) == "number"))
     then ($pool | map(.profile.reasoning_class) | max) as $top | [$pool[] | select(.profile.reasoning_class == $top)]
     else $pool end
     | sort_by((.reserve // false), seat_rank(.profile)) | first) as $seat |
    if $seat == null then $out
    else
      ($seat | del(.incomplete, .windows_missing) + {eligible: true, quota_unknown: true, reason: "quota unknown: \(.reason)"}) as $started |
      (if $ambiguous then ([$union_ids[] | . as $id | (if $id == "default" then profiles($cfg.default) else profiles(rule_at($id).use) end) | select(index($seat.profile)) | $id] | first) else $sel.source end) as $seat_row |
      ($out | del(.reason, .incomplete, .quota_attempts, .warmups)) + {
        status: "clear", quota_unknown: true, chosen: $started, row: $seat_row,
        note: "quota unknown on every candidate: starting on \($seat | seat_label), the first declared seat of its tier and strongest class, without waiting",
        candidates: [$out.candidates[] | if .profile == $seat.profile then $started else . end]}
    end
   else $out end) as $out |
  # Jev answered but code cannot dispatch it: the captain picks from the table.
  if $out.status == "escalate" or $out.status == "error" or ($out.status == "incomplete" and $final) then
    $out + {status: "captain-pick", jev_status: $out.status, pick: pick_rows($a.probabilities)}
  elif $force_pick and $out.status == "clear" then
    $out + {status: "captain-pick", jev_status: "captain-requested",
      reason: "the captain asked to choose this route; Jev and code would take \($out.chosen.profile.harness) \($out.chosen.profile.model // "default") from \($out.row)",
      pick: pick_rows($a.probabilities)} | del(.chosen)
  else $out end
  end'
}
RESULT=$(fm_dispatch_resolve_json 1 0) || emit_error "resolution failed"
quota_attempts=1
warmups_run=0
fm_dispatch_epoch_ms_of() {  # <iso8601>: epoch milliseconds, or nothing when unparsable
  local out
  out=$(date -d "$1" +%s%3N 2>/dev/null) || return 1
  case "$out" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}
fm_dispatch_warm_zai() {  # the named Z.ai warm-up, at most once per resolution
  warmups_run=1
  if command -v zai-window-warm >/dev/null 2>&1; then
    fm_dispatch_bounded zai-window-warm >/dev/null 2>&1 || true
  fi
}
# A worker choice never waits on quota, but a pool with a named warm-up still gets
# it and one re-read, so a cold window can join the choice.
if [ "$MODE" = worker ] && [ "$quota_attempts" -lt "$QUOTA_ATTEMPTS" ] && [ "$(date +%s)" -lt "$QUOTA_DEADLINE" ] \
  && jq -e '(.status == "clear" or .status == "incomplete") and any(.candidates[]?; ((.unreadable // false) or (.incomplete // false)) and .provider == "zai")' <<<"$RESULT" >/dev/null 2>&1; then
  fm_dispatch_warm_zai
  if jq -e 'any(.candidates[]?; ((.unreadable // false) or (.incomplete // false)) and .provider == "zai" and .profile.account == null)' <<<"$RESULT" >/dev/null 2>&1; then
    gather_home_quota >/dev/null || true
  fi
  while IFS= read -r account; do
    [ -n "$account" ] || continue
    gather_account_snapshot "$account"
  done < <(jq -r '.candidates[]? | select(((.unreadable // false) or (.incomplete // false)) and .provider == "zai") | .profile.account // empty' <<<"$RESULT" | sort -u)
  quota_attempts=$(( quota_attempts + 1 ))
  RESULT=$(fm_dispatch_resolve_json "$quota_attempts" "$warmups_run") || emit_error "resolution failed"
fi
# Pipeline's bounded gather loop: an incomplete resolution runs the named warm-up
# once, re-reads only the named stores with doubling backoff up to the deadline.
# Slow reads and warm-ups share that deadline, including their subprocesses.
while [ "$MODE" = pipeline ] && [ "$(jq -r '.status // ""' <<<"$RESULT" 2>/dev/null)" = "incomplete" ] && [ "$quota_attempts" -lt "$QUOTA_ATTEMPTS" ] && [ "$(date +%s)" -lt "$QUOTA_DEADLINE" ]; do
  if [ "$warmups_run" -eq 0 ] && jq -e 'any(.incomplete[]?; .provider == "zai")' <<<"$RESULT" >/dev/null 2>&1; then
    fm_dispatch_warm_zai
  fi
  budget_ms=$(( (QUOTA_DEADLINE - $(date +%s)) * 1000 ))
  [ "$budget_ms" -gt 0 ] || break
  now_ms=$(fm_timing_now_ms)
  all_late=1
  any_hint=0
  while IFS= read -r retry_after; do
    [ -n "$retry_after" ] || { all_late=0; continue; }
    any_hint=1
    retry_ms=$(fm_dispatch_epoch_ms_of "$retry_after") || { all_late=0; continue; }
    [ "$(( retry_ms - now_ms ))" -gt "$budget_ms" ] || all_late=0
  done < <(jq -r '.incomplete[]? | .retry_after // ""' <<<"$RESULT" | sort -u)
  # Even a later retry hint waits to the deadline, rather than exiting early.
  if [ "$any_hint" -eq 1 ] && [ "$all_late" -eq 1 ]; then
    sleep "$(( (budget_ms + 999) / 1000 ))"
    break
  fi
  sleep "$(awk -v base="$QUOTA_BACKOFF_MS" -v n="$quota_attempts" -v left="$budget_ms" 'BEGIN { if (n > 6) n = 6; delay = base * (2 ^ (n - 1)); if (delay > 30000) delay = 30000; if (delay > left) delay = left; if (delay < 0) delay = 0; printf "%.3f", delay / 1000 }')"
  [ "$(date +%s)" -lt "$QUOTA_DEADLINE" ] || break
  if jq -e 'any(.incomplete[]?; .account == null)' <<<"$RESULT" >/dev/null 2>&1; then
    gather_home_quota >/dev/null || true
  fi
  while IFS= read -r account; do
    [ -n "$account" ] || continue
    gather_account_snapshot "$account"
  done < <(jq -r '.incomplete[]? | .account // empty' <<<"$RESULT" | sort -u)
  quota_attempts=$(( quota_attempts + 1 ))
  RESULT=$(fm_dispatch_resolve_json "$quota_attempts" "$warmups_run") || emit_error "resolution failed"
done
# Evidence still incomplete: worker mode starts quota unknown and pipeline mode
# takes its first seat unmeasured, with every unmeasured candidate marked.
if [ "$(jq -r '.status // ""' <<<"$RESULT")" = incomplete ]; then
  RESULT=$(fm_dispatch_resolve_json "$quota_attempts" "$warmups_run" true) || emit_error "resolution failed"
fi

fm_dispatch_tie_rr_advance() {  # move the shared rotation on after a round-robin pick
  [ "$(jq -r '(.status == "clear" or .status == "ok") and (.tie_round_robin // false)' <<<"$RESULT")" = true ] || return 0
  mkdir -p "$STATE" 2>/dev/null || true
  if tie_rr_tmp=$(mktemp "$TIE_RR_FILE.XXXXXX" 2>/dev/null); then
    if ! { printf '%s\n' "$(( (TIE_RR + 1) % 1000000 ))" > "$tie_rr_tmp" && mv -f "$tie_rr_tmp" "$TIE_RR_FILE"; }; then
      rm -f "$tie_rr_tmp"
    fi
  fi
}
if [ "$MODE" = pipeline ]; then
  printf '%s\n' "$RESULT"
  case "$(jq -r '.status // ""' <<<"$RESULT")" in
    ok)
      fm_dispatch_tie_rr_advance
      exit 0
      ;;
    exhausted)
      jq -r 'def flat: tostring | gsub("[\t\r\n]"; " ");
        .seats[] | "dispatch-resolve: \(.seat | flat) (pool \(.pool | flat)) has no room, resets \((.reset // "unknown") | flat): \(.reason | flat)"' <<<"$RESULT" >&2
      exit 3
      ;;
    *) die "pipeline resolution failed" ;;
  esac
fi

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  def winstr($ws): [$ws[] | "\(.id | flat):\(.pct | flat)%@\(.resetsAt | flat)"] | join(",");
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(show(.rule)) (\(show(.rule_when)))   confidence: \(show(.confidence))",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  (if .profile_preference then "  candidate_preference: \(.profile_preference | flat) (quota gates and spendPriority take precedence)" else empty end),
  (if .fallback then "  fallback: \(.fallback | flat)" else empty end),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .preferred_provider then "  preferred_provider: \(.preferred_provider | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (if .tie_break then "  tie_break: \(.tie_break | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .profile.account then "  account=\(.profile.account | flat)" else "" end)
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .incomplete or .unreadable then "  windows_missing=\((.windows_missing // []) | map(flat) | join(","))"
          + (if .state_error or .retry_after
             then " (" + ([.state_error // empty] + (if .retry_after then [("retry after " + (.retry_after | flat))] else [] end) | join("; ")) + ")"
             else "" end)
        elif .windows then "  windows=\(winstr(.windows))" else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + (if .reading_age != null then "  reading_age=\(.reading_age | flat)s (recent reading reused)" else "" end)
      + "  -> " + (if .quota_unknown then "eligible, \(.reason | flat)" elif .incomplete then "incomplete: \(.reason | flat)" elif .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .sq then "eligible (quota ranking off: home declares a single shared quota)" elif .eligible and (.reserve_active // false) then "eligible, \(.reason | flat)" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)
      + "  plan=\(.plan | flat) (\(.plan_source | flat))"),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end)
      + (if .chosen.profile.account then " --account \(.chosen.profile.account | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
fm_dispatch_tie_rr_advance
# Missing classes let spare quota alone decide between models: say so on every run.
UNCLASSED=$(jq -r 'def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  [((.rules // [])[] | profiles(.use)[]), profiles(.default // null)[]] | "\([.[] | select((.reasoning_class | type) != "number")] | length) \(length)"' "$RULES")
if [ "${UNCLASSED%% *}" != 0 ]; then
  printf '  classes: %s of %s table candidates declare no reasoning_class, so spare quota alone ranks those rows; declare one on every candidate\n' "${UNCLASSED%% *}" "${UNCLASSED#* }"
fi
FM_DR_JEV=$(jq -c --argjson latency "$LAT_MS" 'if .requestId then {model, requestId, ruleChoice: .answers.rule.choice, ruleProbabilities: .answers.rule.probabilities, confidence: .answers.rule.confidence, candidatePreference: .answers.profile.choice, latencyMs: $latency, inputTokens: (.usage.input_tokens // null)} else null end' "$RESP_FILE")
case "$(jq -r '.status // ""' <<<"$RESULT")" in
  clear)
    # A clear answer is the routing decision, so it leaves the receipt the
    # launch gate will ask for. The per-launch intake is recorded here.
    fm_dr_record_intake || emit_error "quota intake failed; stop and report"
    if RECEIPT_NAME=$(fm_dr_write_clear "$BRIEF" "$TASK_ID" "$RESULT"); then
      printf '  source: jev\n'
      printf '  receipt: %s (one launch, valid %ss)\n' "$RECEIPT_NAME" "$(fm_dr_max_age)"
    else
      printf '  receipt: not written (%s); stop and report\n' "${FM_DR_ERR:-see diagnostic above}"
      exit 3
    fi
    ;;
  captain-pick)
    if PICK_CODE=$(fm_dp_write_request "$BRIEF" "$TASK_ID" "$PROJECT" "$RESULT"); then
      fm_dp_render_options "$PICK_CODE"
      printf '  receipt: none - nothing launches until the captain picks (pick %s); no route is guessed\n' "$PICK_CODE"
    else
      printf '  receipt: none - pick request not written (%s); stop and report\n' "$PICK_CODE"
      exit 3
    fi
    ;;
  *)
    printf '  receipt: none - stop and report\n'
    ;;
esac
exit 0
