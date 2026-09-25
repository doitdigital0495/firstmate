#!/usr/bin/env bash
# Live drive of bin/fm-dispatch-resolve.sh: REAL quota-axi (wrapped only to count calls),
# stubbed Jev endpoint (curl) because no OpenRouter key is reachable in this run.
set -u
WT=/home/daan/.no-mistakes/worktrees/cf62ac6bfd91/01M3BW3V8YNQQ67NZG7PFS186G
T=$(mktemp -d /tmp/nm-dr-live.XXXX); H=$T/home; B=$T/bin; mkdir -p "$H/config" "$B"
REAL_QA=$(command -v quota-axi)
cat > "$B/quota-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/qa.calls"
exec "$REAL_QA" "\$@"
EOF
cat > "$B/curl" <<'EOF'
#!/usr/bin/env bash
out=''; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; *) shift;; esac; done
cat >/dev/null; cp "$JEV_RESPONSE" "$out"; printf 200
EOF
chmod +x "$B"/*
printf '# Task\nFix the off-by-one in pager.sh line 40.\n' > "$T/brief.md"
drive() { # <name> <rules-json>
  local name=$1; printf '%s\n' "$2" > "$H/config/crew-dispatch.json"
  jq -n --slurpfile r "$H/config/crew-dispatch.json" '
    ([$r[0].rules | to_entries[] | .key as $i | .value.use | (if type=="array" then . else [.] end) | to_entries[] | "rule_\($i+1)_\(.key+1)"]) as $ids |
    {model:"jev-stub", answers:{rule:{type:"choice",choice:"rule_1",confidence:0.95,probabilities:{rule_1:0.95,default:0.05}},
     profile:{type:"choice",choice:$ids[0],confidence:0.9,probabilities:($ids|map({key:.,value:(1/($ids|length))})|from_entries)}},
     usage:{input_tokens:1,output_tokens:1}}' > "$T/resp.json"
  : > "$T/qa.calls"
  echo "===== $name"; echo "rules: $2"
  local s=$(date +%s)
  PATH="$B:$PATH" FM_HOME="$H" OPENROUTER_API_KEY=stub-not-a-secret JEV_RESPONSE="$T/resp.json" \
    FM_DISPATCH_QUOTA_ATTEMPTS=2 FM_DISPATCH_QUOTA_BACKOFF_MS=250 "$WT/bin/fm-dispatch-resolve.sh" "$T/brief.md" --project pager
  echo "exit=$?  real quota-axi calls=$(wc -l < "$T/qa.calls")  elapsed=$(( $(date +%s)-s ))s"
}
drive "A complete-candidates-clear" '{"rules":[{"when":"A bug fix.","use":[{"harness":"claude","model":"sonnet","effort":"high"},{"harness":"codex","model":"gpt-5.6-sol"}]}]}'
drive "E rule-floor-model-scope-known (fable 95%)" '{"rules":[{"when":"A bug fix.","floor":{"scope":"model:fable","min_percent":20,"provider":"claude"},"use":{"harness":"claude","model":"fable","effort":"xhigh"}}]}'
rm -rf "$T"
