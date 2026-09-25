#!/usr/bin/env bash
# Extract only public subscription labels from vendor profile files.
# No credential, token, or raw profile content is emitted.
fm_plan_store_fields() {  # <claude store> <codex store>: JSON provider -> plan label
  local claude=$1 codex=$2 result='{}' value
  if [ -r "$claude/.claude.json" ]; then
    value=$(jq -er '(.oauthAccount.subscriptionType // .account.subscriptionType // .subscriptionType) | select(type == "string" and length > 0 and length <= 80 and (test("^[[:print:]]+$")))' "$claude/.claude.json" 2>/dev/null) || value=''
    [ -z "$value" ] || result=$(jq -cn --arg v "$value" '{claude: $v}')
  fi
  if [ -r "$codex/auth.json" ]; then
    # Top-level metadata only: never decode or emit the id_token or API key.
    value=$(jq -er '(.plan // .account.plan) | select(type == "string" and length > 0 and length <= 80 and (test("^[[:print:]]+$")))' "$codex/auth.json" 2>/dev/null) || value=''
    [ -z "$value" ] || result=$(jq -cn --argjson prev "$result" --arg v "$value" '$prev + {codex: $v}')
  fi
  printf '%s\n' "$result"
}
