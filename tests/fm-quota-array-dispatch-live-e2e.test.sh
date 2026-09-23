#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-array-dispatch skill.
#
# This drives the public Pi skill-loading interface against a fake quota-axi
# executable rather than parsing instruction source bytes or recreating the
# selector in test code. The fake serves default TOON from the schema-5 JSON
# fixture. The call log must start with that TOON; optional --json fallback
# calls are ignored, while TOON re-reads and warm-ups must match exactly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E pi python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

[ -f "$OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/quota.json"
CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
# Fake quota-axi: default TOON from the schema-5 JSON fixture; --json dumps it.
set -u
record() {
  printf '%s\n' "$1" >> "${QUOTA_AXI_CALLS:?}"
}
fixture() {
  if [ -n "${QUOTA_AXI_WARMED_FIXTURE:-}" ] && [ -e "${ZAI_WARM_FLAG:-/nonexistent}" ]; then
    printf '%s\n' "$QUOTA_AXI_WARMED_FIXTURE"
  else
    printf '%s\n' "${QUOTA_AXI_FIXTURE:?}"
  fi
}
emit_toon() {
  python3 - "$(fixture)" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
generated = data.get("generatedAt", "unknown")
quota = []
exhaustion = []
attention = []


def join_ids(ids):
    if not ids:
        return "unknown"
    return " + ".join(str(item) for item in ids)


for provider in data.get("providers") or []:
    name = provider.get("provider", "unknown")
    windows = {window.get("id"): window for window in (provider.get("windows") or [])}
    semantics = provider.get("quotaSemantics") or {}
    for scope in semantics.get("effectiveAvailability") or []:
        remaining = scope.get("effectivePercentRemaining")
        selection = scope.get("selection") or {}
        runway = scope.get("runway") or {}
        scope_name = scope.get("scope", "unknown")
        if remaining is None:
            attention.append(
                f"  {name},{scope_name},headroom_unknown,{join_ids(runway.get('unmeasurableWindowIds') or scope.get('boundedBy'))},none"
            )
            continue
        if selection.get("status") == "known" and "spendPriority" in selection:
            spend = selection["spendPriority"]
        else:
            spend = "unknown"
        runway_status = runway.get("status") or "unknown"
        confidence = runway.get("projectionConfidence") or "unknown"
        limited = join_ids(scope.get("limitingWindowIds"))
        binding = None
        for window_id in scope.get("limitingWindowIds") or []:
            binding = (windows.get(window_id) or {}).get("resetsAt")
            if binding:
                break
        resets_at = binding or "unknown"
        quota.append(
            f"  {name},{scope_name},{remaining},{spend},{runway_status},{confidence},{limited},{resets_at}"
        )
        if runway_status in ("projected_exhaustion", "exhausted_now"):
            seconds = runway.get("usableRunwaySeconds", "unknown")
            exhausted_at = runway.get("projectedExhaustedAt", "unknown")
            limiting = runway.get("limitingWindowId", "unknown")
            exhaustion.append(
                f"  {name},{scope_name},{seconds},{exhausted_at},{limiting}"
            )
        blocked = []
        if runway.get("unmeasurableWindowIds"):
            blocked.append(f"{join_ids(runway['unmeasurableWindowIds'])} blocks runway")
        if selection.get("unmeasurableWindowIds"):
            blocked.append(
                f"{join_ids(selection['unmeasurableWindowIds'])} blocks spendPriority"
            )
        if blocked:
            attention.append(
                f"  {name},{scope_name},unmeasurable,{' · '.join(blocked)},none"
            )

print('bin: fake-quota-axi')
print('description: Report local agent-provider quota windows for routing-aware agents')
print(f'generatedAt: "{generated}"')
print(
    f"quota[{len(quota)}]{{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}}:"
)
print("\n".join(quota) if quota else "")
print(
    f"exhaustion[{len(exhaustion)}]{{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}}:"
    if exhaustion
    else "exhaustion[0]:"
)
if exhaustion:
    print("\n".join(exhaustion))
print(
    f"attention[{len(attention)}]{{provider,scope,kind,detail,remedy}}:"
    if attention
    else "attention[0]:"
)
if attention:
    print("\n".join(attention))
print("help[1]:")
print("  Run `quota-axi --full` for windows, pace, reserve, and account evidence")
PY
}

case "$*" in
  ""|quota)
    record TOON
    emit_toon
    ;;
  --json)
    record JSON
    cat "$(fixture)"
    ;;
  *)
    printf 'unexpected quota-axi invocation: %s\n' "$*" >&2
    exit 64
    ;;
esac
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$FAKEBIN/zai-window-warm" <<'SH'
#!/usr/bin/env bash
printf 'WARM\n' >> "${QUOTA_AXI_CALLS:?}"
: > "${ZAI_WARM_FLAG:?}"
SH
chmod +x "$FAKEBIN/zai-window-warm"

WARMED_FIXTURE="$LAB/warmed-quota.json"
WARM_FLAG="$LAB/zai-warmed"
write_fixture() {
  cat > "$FIXTURE"
}

run_case() {
  local label=$1 expected=$2 expected_calls=$3 prompt=$4 out calls required
  shift 4
  : > "$CALLS"
  rm -f "$WARM_FLAG"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
      QUOTA_AXI_WARMED_FIXTURE="${WARM_TEST:-}" ZAI_WARM_FLAG="$WARM_FLAG" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "${calls%%$'\n'*}" = TOON ] || fail "$label: first quota-axi call was not default TOON: $calls"
  [ "$(grep -vx JSON "$CALLS")" = "$expected_calls" ] \
    || fail "$label: unexpected quota-axi call sequence: $calls"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || fail "$label: expected accounting line $required, got: $out"
  done
  printf '%s\n' "$out"
  printf 'ok - %s\n' "$label"
}

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 80,
          "resetsAt": "2030-01-07T07:12:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -10, "burnMultiple": 2 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 80,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -1.1111 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 241920,
              "projectedExhaustedAt": "2030-01-03T19:12:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -10, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 20,
          "resetsAt": "2030-01-03T19:12:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -20, "burnMultiple": 1.3333 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.8333 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 90720,
              "projectedExhaustedAt": "2030-01-02T01:12:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -20, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "higher spendPriority beats more headroom after the three gates" \
  "SELECTED=codex" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and follow it for the quota evidence. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Firstmate's Claude orchestration forecast is independently evidenced to reach reset with this task included. Return exact lines FACT=claude|headroom=<n>|spendPriority=<value>|runway_seconds=<n> and FACT=codex|headroom=<n>|spendPriority=<value>|runway_seconds=<n> filled from the quota evidence, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=80|spendPriority=-1.1111|runway_seconds=241920" \
  "FACT=codex|headroom=20|spendPriority=-0.8333|runway_seconds=90720"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 55,
          "resetsAt": "2030-01-08T00:00:00Z",
          "pace": { "status": "unknown", "reason": "missing_cycle" }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 55,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "unknown", "unmeasurableWindowIds": ["weekly"] },
            "runway": { "status": "unknown", "unmeasurableWindowIds": ["weekly"] },
            "pace": { "status": "unknown", "unknownWindowIds": ["weekly"] }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 45,
          "resetsAt": "2030-01-04T20:24:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -10, "burnMultiple": 1.2222 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 45,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.404 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 222676,
              "projectedExhaustedAt": "2030-01-03T13:51:16Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -10, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "unknown pool without warm-up drops only its candidate after one retry" \
  "DECISION=CODEX" \
  "TOON
TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and follow it for the quota evidence. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs prove Claude/Sonnet and Codex/GPT supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Return exact lines FACT=claude|status=<ranked|dropped>|warmup=<used|unavailable>|runway=<seconds|through_reset|unknown>|spendPriority=<value|unknown> and FACT=codex|status=<ranked|dropped>|headroom=<n>|spendPriority=<value|unknown>|runway_seconds=<n>|supports_horizon=<yes|no>, then an exact final line DECISION=<CLAUDE|CODEX|STOP>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|status=dropped|warmup=unavailable|runway=unknown|spendPriority=unknown" \
  "FACT=codex|status=ranked|headroom=45|spendPriority=-0.404|runway_seconds=222676|supports_horizon=yes"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "zai",
      "windows": [{"id":"five_hour", "resetsAt":"2030-01-01T05:00:00Z"}],
      "quotaSemantics": {"status":"known", "effectiveAvailability":[{
        "scope":"all_models", "status":"known", "effectivePercentRemaining":90,
        "limitingWindowIds":["five_hour"],
        "selection":{"status":"unknown", "unmeasurableWindowIds":["five_hour"]},
        "runway":{"status":"unknown", "unmeasurableWindowIds":["five_hour"]}
      }]}
    },
    {
      "provider": "codex",
      "quotaSemantics": {"status":"known", "effectiveAvailability":[{
        "scope":"all_models", "status":"known", "effectivePercentRemaining":50,
        "selection":{"status":"known", "spendPriority":-0.3},
        "runway":{"status":"through_reset"}
      }]}
    }
  ]
}
JSON
python3 - "$FIXTURE" "$WARMED_FIXTURE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
zai = data["providers"][0]["quotaSemantics"]["effectiveAvailability"][0]
zai["selection"] = {"status": "known", "spendPriority": 0.8}
zai["runway"] = {"status": "through_reset"}
with open(sys.argv[2], "w", encoding="utf-8") as target:
    json.dump(data, target)
PY
WARM_TEST="$WARMED_FIXTURE"
run_case \
  "on-demand Z.ai warm-up resolves an unknown pool before ranking" \
  "DECISION=ZAI" \
  "TOON
WARM
TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and follow it for the quota evidence. The authoritative catalogs prove Pi/zai/glm-5.3 and Codex/GPT supported in their provider families; credentials are usable and both meet the required reasoning class. Completion horizon is two hours with established confidence. Return exact lines FACT=zai|warmups=<n>|spendPriority=<value|unknown>|runway=<seconds|through_reset|unknown> and FACT=codex|spendPriority=<value|unknown>|runway=<seconds|through_reset|unknown> filled from the final quota evidence, then exact final line DECISION=<ZAI|CODEX|STOP>. Do not modify project files." \
  "FACT=zai|warmups=1|spendPriority=0.8|runway=through_reset" \
  "FACT=codex|spendPriority=-0.3|runway=through_reset"
unset WARM_TEST

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 5,
          "resetsAt": "2030-01-04T12:00:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -45, "burnMultiple": 1.9 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 5,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -1.8 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 15916,
              "projectedExhaustedAt": "2030-01-01T04:25:16Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -45, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 80,
          "resetsAt": "2030-01-06T22:48:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -5, "burnMultiple": 1.3333 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 80,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -0.3921 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 362880,
              "projectedExhaustedAt": "2030-01-05T04:48:00Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -5, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "required strongest reasoning class is not downgraded for quota" \
  "SELECTED=claude" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and follow it for the quota evidence. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile in the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class. Firstmate's Claude orchestration forecast is independently evidenced to reach reset with this task included. Return exact lines FACT=claude|reasoning=<meets|below>|headroom=<n>|spendPriority=<value>|runway_seconds=<n> and FACT=codex|reasoning=<meets|below>|headroom=<n>|spendPriority=<value>|runway_seconds=<n> filled from the quota evidence, then an exact final line SELECTED=<claude|codex|none>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|reasoning=meets|headroom=5|spendPriority=-1.8|runway_seconds=15916" \
  "FACT=codex|reasoning=below|headroom=80|spendPriority=-0.3921|runway_seconds=362880"

write_fixture <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "five_hour",
          "label": "5-hour",
          "kind": "five_hour",
          "percentRemaining": 20,
          "resetsAt": "2030-01-01T02:00:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -20, "burnMultiple": 1.3333 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 20,
            "boundedBy": ["five_hour"],
            "limitingWindowIds": ["five_hour"],
            "selection": { "status": "known", "spendPriority": -0.8333 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 2700,
              "projectedExhaustedAt": "2030-01-01T00:45:00Z",
              "limitingWindowId": "five_hour",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["five_hour"], "worstReservePercentPoints": -20, "worstReserveWindowId": "five_hour" }
          }
        ]
      }
    },
    {
      "provider": "codex",
      "state": { "status": "fresh", "stale": false },
      "windows": [
        {
          "id": "weekly",
          "label": "week",
          "kind": "weekly",
          "percentRemaining": 5,
          "resetsAt": "2030-01-04T12:00:00Z",
          "pace": { "status": "ahead", "reservePercentPoints": -45, "burnMultiple": 1.9 }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": 5,
            "boundedBy": ["weekly"],
            "limitingWindowIds": ["weekly"],
            "selection": { "status": "known", "spendPriority": -1.8 },
            "runway": {
              "status": "projected_exhaustion",
              "usableRunwaySeconds": 15916,
              "projectedExhaustedAt": "2030-01-01T04:25:16Z",
              "limitingWindowId": "weekly",
              "projectionConfidence": "established"
            },
            "pace": { "status": "ahead", "aheadWindowIds": ["weekly"], "worstReservePercentPoints": -45, "worstReserveWindowId": "weekly" }
          }
        ]
      }
    }
  ]
}
JSON
run_case \
  "unsplittable runway failure falls through to full-task candidate" \
  "SELECTED=codex" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and follow it for the quota evidence. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. The work is an atomic operation with no independently inspectable subtask. Firstmate's Claude orchestration forecast is independently evidenced to reach reset with this task included. Return exact lines FACT=claude|spendPriority=<value>|runway_seconds=<n>|supports_horizon=<yes|no> and FACT=codex|spendPriority=<value>|runway_seconds=<n>|supports_horizon=<yes|no> filled from the quota evidence, then an exact final line SELECTED=<claude|codex|none>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|spendPriority=-0.8333|runway_seconds=2700|supports_horizon=no" \
  "FACT=codex|spendPriority=-1.8|runway_seconds=15916|supports_horizon=yes"

run_case \
  "runway-limited top candidate gets a bounded slice with remainder requeued" \
  "DECISION=SPLIT_CLAUDE" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and follow it for the quota evidence. Both candidates have comparable required fit, catalog-supported models, usable credentials, and the same required reasoning class. The full-task horizon is two hours with established confidence. The work splits into a first deliverable that can be independently verified after 20 minutes of work, plus the remaining work. Firstmate's Claude orchestration forecast is independently evidenced to reach reset with a 20-minute Claude worker slice included, but not with the full two-hour task. Return exact lines FACT=claude|spendPriority=<value>|runway_seconds=<n>|slice_minutes=<n|none> and FACT=codex|spendPriority=<value>|runway_seconds=<n>|full_task=<yes|no>, then exact lines REQUEUED=<remaining-task|none> and DECISION=<CLAUDE|CODEX|SPLIT_CLAUDE|SPLIT_CODEX|STOP>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|spendPriority=-0.8333|runway_seconds=2700|slice_minutes=20" \
  "FACT=codex|spendPriority=-1.8|runway_seconds=15916|full_task=yes" \
  "REQUEUED=remaining-task"

python3 - "$FIXTURE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
data["providers"][0]["windows"][0]["resetsAt"] = "2030-01-01T06:00:00Z"
claude = data["providers"][0]["quotaSemantics"]["effectiveAvailability"][0]
claude["runway"]["usableRunwaySeconds"] = 15916
claude["runway"]["projectedExhaustedAt"] = "2030-01-01T04:25:16Z"
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(data, target)
PY
run_case \
  "Claude reserve can veto a full task despite generic runway" \
  "SELECTED=codex" \
  "TOON" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and follow it for the quota evidence. Both candidates have comparable required fit, catalog-supported models, usable credentials, the same required reasoning class, and a two-hour full-task completion horizon with established confidence. The work is an atomic operation with no independently inspectable subtask. Firstmate shares the Claude worker's credential store and, from observed usage and committed supervision work, forecasts that its own Claude orchestration will consume 3 hours of that store's runway before its reset. Return exact lines FACT=claude|task_horizon=<seconds>|runway_seconds=<n>|reserve=<sufficient|insufficient|not_applicable> and FACT=codex|runway_seconds=<n>|reserve=<sufficient|insufficient|not_applicable>, then exact final line SELECTED=<claude|codex|none>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|task_horizon=7200|runway_seconds=15916|reserve=insufficient" \
  "FACT=codex|runway_seconds=15916|reserve=not_applicable"

echo "# all quota-array-dispatch live behavior tests passed"
