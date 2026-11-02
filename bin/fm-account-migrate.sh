#!/usr/bin/env bash
# fm-account-migrate.sh - one-shot rewrite of account ids and store paths in
# task records and worker pin files, for an account registry rename.
#
# Usage:
#   fm-account-migrate.sh [--apply] [--assume-drained]
#       --id <old>:<provider>=<new> [--id ...]
#       [--path <old-store>=<new-store> ...]
#
#   --id     maps the account a task record names (account=, else seat=) to a new
#            registry id, per provider family, so one old id that spent two
#            providers can split: --id old:claude=claude3 --id old:codex=codex2.
#            <old> may be "-" for a record that names no account, which binds it
#            to the provider's new account (--id -:claude=claude1).
#            A mapped record gets account=<new> and seat=<new>, and the store key
#            its harness launches from (claude_config_dir, pi_agent_dir or
#            codex_home) is set to <new>'s store in config/accounts.json, so a
#            relaunch lands on the new seat. Every <new> must be registered there.
#   --path   rewrites a store path, or any path under it, wherever a task record
#            store key or a worker pin file (config/claude-account,
#            config/pi-account, their suspended copies, and
#            config/secondmate-accounts/<id>/*-account) still names it.
#   --apply  writes the changes. Without it nothing is written and the planned
#            change list is printed (a dry run).
#   --assume-drained  skip the live-worker check (only for hosts without /proc).
#
# Safety: --apply refuses while any process of this user still runs with
# CLAUDE_CONFIG_DIR, PI_CODING_AGENT_DIR or CODEX_HOME at or under an old
# --path store, because renaming a store under a running harness breaks it.
# Before writing, every file it changes is copied under
# state/account-migrate/pre-<UTC stamp>/ with its path relative to the home;
# copying those files back restores the previous state. Re-running after a
# successful apply changes nothing.
#
# Provider family of a record: harness claude -> claude, codex -> codex;
# pi and pi-signed by model prefix (zai/* -> zai, openai-codex/* and
# codex-native/* -> codex). A record whose family cannot be established is
# reported and left alone.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

APPLY=0 DRAINED=0
declare -A ID_MAP=()
PATH_OLD=() PATH_NEW=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --assume-drained) DRAINED=1; shift ;;
    --id)
      [ $# -ge 2 ] || die "--id needs <old>:<provider>=<new>"
      [[ $2 =~ ^(-|[a-z][a-z0-9-]*):([a-z0-9]+(-[a-z0-9]+)*)=([a-z][a-z0-9-]*)$ ]] ||
        die "--id must look like <old>:<provider>=<new>, got: $2"
      ID_MAP["${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"]=${BASH_REMATCH[4]}
      shift 2 ;;
    --path)
      [ $# -ge 2 ] || die "--path needs <old-store>=<new-store>"
      case "$2" in /*=/*) ;; *) die "--path needs two absolute paths: <old>=<new>" ;; esac
      PATH_OLD+=("$(fm_account_expand_store "${2%%=*}")")
      PATH_NEW+=("$(fm_account_expand_store "${2#*=}")")
      shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ "${#ID_MAP[@]}" -gt 0 ] || [ "${#PATH_OLD[@]}" -gt 0 ] || usage
command -v jq >/dev/null 2>&1 || die "jq required"

REGISTRY=$CONFIG/accounts.json
if [ "${#ID_MAP[@]}" -gt 0 ]; then
  fm_account_registry_valid "$REGISTRY" || die "config/accounts.json is missing or malformed; install the new registry first"
  for key in "${!ID_MAP[@]}"; do
    jq -e --arg a "${ID_MAP[$key]}" '.accounts[$a] != null' "$REGISTRY" >/dev/null ||
      die "--id target ${ID_MAP[$key]} is not registered in config/accounts.json"
  done
fi

# map_path <path>: the path after the --path rewrites (first match wins).
map_path() {
  local value=$1 i old
  for i in "${!PATH_OLD[@]}"; do
    old=${PATH_OLD[$i]}
    if [ "$value" = "$old" ]; then printf '%s\n' "${PATH_NEW[$i]}"; return 0; fi
    case "$value" in "$old"/*) printf '%s\n' "${PATH_NEW[$i]}${value#"$old"}"; return 0 ;; esac
  done
  printf '%s\n' "$value"
}

record_provider() {  # <harness> <model>
  case "$1" in
    claude) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    pi|pi-signed)
      case "$2" in
        zai/*) printf 'zai\n' ;;
        openai-codex/*|codex-native/*) printf 'codex\n' ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

store_key_for() {  # <harness>: record key and registry store kind
  case "$1" in
    claude) printf 'claude_config_dir claude\n' ;;
    pi|pi-signed) printf 'pi_agent_dir pi\n' ;;
    codex) printf 'codex_home codex\n' ;;
    *) return 1 ;;
  esac
}

# get <file> <key>: last value of key= in a record.
get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# ---- live-worker check ------------------------------------------------------------
live_on_old_store() {
  local env_file pid line value i old
  [ "${#PATH_OLD[@]}" -gt 0 ] || return 1
  for env_file in /proc/[0-9]*/environ; do
    [ -r "$env_file" ] || continue
    pid=${env_file#/proc/}; pid=${pid%/environ}
    [ "$pid" != "$$" ] || continue
    while IFS= read -r -d '' line; do
      case "$line" in CLAUDE_CONFIG_DIR=*|PI_CODING_AGENT_DIR=*|CODEX_HOME=*) ;; *) continue ;; esac
      value=$(fm_account_expand_store "${line#*=}")
      for i in "${!PATH_OLD[@]}"; do
        old=${PATH_OLD[$i]}
        case "$value" in "$old"|"$old"/*)
          printf 'pid %s runs with %s\n' "$pid" "$line"
          return 0 ;;
        esac
      done
    done < "$env_file" 2>/dev/null || true
  done
  return 1
}

# ---- plan --------------------------------------------------------------------------
PLAN=$(mktemp -d)
trap 'rm -rf "$PLAN"' EXIT
changes=0 skipped=0

plan_file() {  # <source> <new-content-file>: queue when content differs
  local src=$1 new=$2 rel
  if cmp -s "$src" "$new"; then return 0; fi
  rel=${src#"$FM_HOME"/}
  mkdir -p "$PLAN/new/$(dirname "$rel")"
  cp "$new" "$PLAN/new/$rel"
  printf '%s\n' "$rel" >> "$PLAN/files"
  changes=$((changes + 1))
  diff -u --label "a/$rel" --label "b/$rel" "$src" "$new" | sed -n '3,$p' | grep '^[-+]' | sed 's/^/  /' || true
}

for record in "$STATE"/*.meta; do
  [ -f "$record" ] || continue
  newfile=$(mktemp)
  harness=$(get "$record" harness)
  model=$(get "$record" model)
  account=$(get "$record" account)
  [ -n "$account" ] || account=$(get "$record" seat)
  new_account=
  set_key='' set_value=''
  if [ "${#ID_MAP[@]}" -gt 0 ] && [ -n "$harness" ]; then
    if provider=$(record_provider "$harness" "$model"); then
      new_account=${ID_MAP["${account:--}:$provider"]:-}
      if [ -n "$new_account" ] && read -r set_key kind < <(store_key_for "$harness"); then
        set_value=$(fm_account_stores "$REGISTRY" "$new_account" 2>/dev/null | sed -n "$(case $kind in claude) echo 1;; pi) echo 2;; codex) echo 3;; esac)p") || set_value=
        if [ -z "$set_value" ] || [ "$set_value" = "$FM_ACCOUNT_NO_STORE" ]; then
          printf 'skip %s: account %s owns no %s store (or cross-account routing is off)\n' "${record#"$FM_HOME"/}" "$new_account" "$kind" >&2
          skipped=$((skipped + 1)); new_account=; set_key=
        fi
      fi
    elif [ -n "$account" ]; then
      printf 'skip %s: provider family of harness %s model %s is unknown\n' "${record#"$FM_HOME"/}" "$harness" "${model:-default}" >&2
      skipped=$((skipped + 1))
    fi
  fi
  saw_account=0 saw_seat=0 saw_store=0
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*} value=${line#*=}
    case "$key" in
      account|seat)
        if [ -n "$new_account" ]; then
          [ "$key" = account ] && saw_account=1 || saw_seat=1
          line="$key=$new_account"
        fi ;;
      claude_config_dir|pi_agent_dir|codex_home)
        if [ -n "$set_key" ] && [ "$key" = "$set_key" ]; then
          saw_store=1; line="$key=$set_value"
        elif [ -n "$value" ]; then
          line="$key=$(map_path "$value")"
        fi ;;
    esac
    printf '%s\n' "$line"
  done < "$record" > "$newfile"
  if [ -n "$new_account" ]; then
    [ "$saw_account" -eq 1 ] || printf 'account=%s\n' "$new_account" >> "$newfile"
    [ "$saw_seat" -eq 1 ] || printf 'seat=%s\n' "$new_account" >> "$newfile"
    [ -z "$set_key" ] || [ "$saw_store" -eq 1 ] || printf '%s=%s\n' "$set_key" "$set_value" >> "$newfile"
  fi
  chmod --reference="$record" "$newfile" 2>/dev/null || true
  plan_file "$record" "$newfile"
  rm -f "$newfile"
done

pin_files() {
  local f
  for f in "$CONFIG"/claude-account "$CONFIG"/pi-account "$CONFIG"/codex-account \
           "$CONFIG"/claude-account.* "$CONFIG"/pi-account.* "$CONFIG"/codex-account.* \
           "$CONFIG"/secondmate-accounts/*/*-account; do
    [ -f "$f" ] && [ ! -L "$f" ] && printf '%s\n' "$f"
  done | sort -u
}
if [ "${#PATH_OLD[@]}" -gt 0 ]; then
  while IFS= read -r pin; do
    newfile=$(mktemp)
    first=1
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$first" -eq 1 ] && [ "${line#/}" != "$line" ]; then line=$(map_path "$line"); fi
      first=0
      printf '%s\n' "$line"
    done < "$pin" > "$newfile"
    # Keep a file that had no final newline without one.
    if [ -n "$(tail -c 1 "$pin")" ]; then printf '%s' "$(cat "$newfile")" > "$newfile.trim" && mv "$newfile.trim" "$newfile"; fi
    chmod --reference="$pin" "$newfile" 2>/dev/null || true
    plan_file "$pin" "$newfile"
    rm -f "$newfile"
  done < <(pin_files)
fi

if [ "$APPLY" -eq 0 ]; then
  printf 'account-migrate: dry run, %s file(s) would change, %s record(s) skipped; re-run with --apply\n' "$changes" "$skipped"
  exit 0
fi
if [ "$DRAINED" -eq 0 ]; then
  [ -d /proc/self ] || die "cannot check for live workers without /proc; drain first and pass --assume-drained"
  if live=$(live_on_old_store); then
    die "a live worker still runs on an old store ($live); drain it or stop it, then re-run"
  fi
fi
if [ "$changes" -eq 0 ]; then
  printf 'account-migrate: nothing to change\n'
  exit 0
fi
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup=$STATE/account-migrate/pre-$stamp
mkdir -p "$backup"
chmod 700 "$STATE/account-migrate" "$backup"
while IFS= read -r rel; do
  mkdir -p "$backup/$(dirname "$rel")"
  cp -p "$FM_HOME/$rel" "$backup/$rel"
done < "$PLAN/files"
while IFS= read -r rel; do
  tmp=$(mktemp "$FM_HOME/$rel.migrate.XXXXXX")
  cat "$PLAN/new/$rel" > "$tmp"
  chmod --reference="$FM_HOME/$rel" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$FM_HOME/$rel"
done < "$PLAN/files"
printf 'account-migrate: applied %s file change(s), %s record(s) skipped; backup %s\n' "$changes" "$skipped" "${backup#"$FM_HOME"/}"
