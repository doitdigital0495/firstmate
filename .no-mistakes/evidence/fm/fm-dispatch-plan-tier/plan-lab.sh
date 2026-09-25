#!/usr/bin/env bash
# Lab: drive bin/fm-dispatch-resolve.sh with REAL quota-axi against the REAL
# personal and geris credential stores; only the Jev HTTPS answer is canned
# (no OPENROUTER_API_KEY reachable on this host).
set -u
WT=$1 SCEN=$2
LAB=$(mktemp -d); trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/home/config" "$LAB/bin"
cat > "$LAB/bin/curl" <<'SH'
#!/usr/bin/env bash
out=''; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; *) shift;; esac; done
cat >/dev/null; cp "$LAB_RESPONSE" "$out"; printf 200
SH
chmod +x "$LAB/bin/curl"
cat > "$LAB/home/config/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"A simple bug fix with a stated root cause.","use":[
 {"harness":"claude","model":"sonnet","effort":"high","account":"personal"},
 {"harness":"claude","model":"sonnet","effort":"high","account":"geris"},
 {"harness":"pi","model":"openai-codex/gpt-5.6-sol","provider":"codex","account":"personal"}]}],
 "default":[{"harness":"claude","model":"opus"}]}
JSON
case $SCEN in
  declared) PLANS_P='"plans":{"claude":"Max 20x","codex":"ChatGPT Pro"},' PLANS_G='"plans":{"claude":"Max 5x"},' ;;
  undeclared) PLANS_P='' PLANS_G='' ;;
  malformed) PLANS_P='"plans":{"claude":"","z.ai":"Pro","codex":"ChatGPT Pro"},' PLANS_G='"plans":"Max 5x",' ;;
esac
cat > "$LAB/home/config/accounts.json" <<JSON
{"crossAccount":{"enabled":true},"accounts":{
 "personal":{$PLANS_P"claude":"/home/daan/.claude","pi":"/home/daan/.pi/agent","codex":"/home/daan/.codex"},
 "geris":{$PLANS_G"claude":"/home/daan/.claude-geris","pi":"/home/daan/.pi-geris/agent","codex":"/home/daan/.codex-geris"}}}
JSON
printf '# Task\nFix the off-by-one in the pager: root cause is the <= on line 40.\n' > "$LAB/brief.md"
jq -n '{model:"jev-1.13.0",answers:{rule:{type:"choice",choice:"rule_1",confidence:0.95,probabilities:{rule_1:0.95,default:0.05}},
 profile:{type:"choice",choice:"rule_1_1",confidence:0.9,probabilities:{rule_1_1:0.34,rule_1_2:0.33,rule_1_3:0.33}}},usage:{input_tokens:1,output_tokens:1}}' > "$LAB/resp.json"
echo "== accounts.json ($SCEN)"; jq -c . "$LAB/home/config/accounts.json"
echo "== fm-dispatch-resolve.sh output"
PATH="$LAB/bin:$PATH" LAB_RESPONSE="$LAB/resp.json" OPENROUTER_API_KEY=lab-dummy FM_HOME="$LAB/home" \
  "$WT/bin/fm-dispatch-resolve.sh" "$LAB/brief.md"; echo "exit=$?"
