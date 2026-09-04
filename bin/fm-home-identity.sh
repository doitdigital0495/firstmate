#!/usr/bin/env bash
# fm-home-identity.sh - the durable pin binding one firstmate home to the
# terminal session and Claude account it was started from.
#
# Usage:
#   fm-home-identity.sh ensure       pin this home from the environment, or verify it
#   fm-home-identity.sh check        verify only; an unpinned home refuses
#   fm-home-identity.sh store        print this home's pinned Claude credential store
#   fm-home-identity.sh show         print the pin, or "absent"
#   fm-home-identity.sh seed <home> <session> <store>
#                                    write a child home's pin from its parent's identity
#   fm-home-identity.sh verify <home> <session> <store>
#                                    seed's refusal without its write
#   fm-home-identity.sh --help
#
# WHY THIS EXISTS. The operator runs one firstmate home per terminal session,
# and that session is what selects the Claude account every worker in it bills:
# the shell derives CLAUDE_CONFIG_DIR from the session name. Nothing durable
# recorded which session a home belonged to, so a home opened from a different
# session silently adopted that session's account, and every relaunch, recovery,
# and message it drove went to the other subscription. Two homes that must never
# mix were one ambient environment variable apart.
#
# This script is that missing binding. A home records its ORIGINATING identity
# once, and from then on every fleet mutation is checked against it. A home is
# never migrated, never re-pinned, and never merged with another; a session that
# does not match is refused, and the operator opens that home from its own
# session instead.
#
# THE IDENTITY is two facts read from the environment, both structural and
# neither a credential value:
#
#   herdr_session      $HERDR_SESSION, or the literal "default" when unset. The
#                      terminal session the home belongs to.
#   claude_config_dir  $CLAUDE_CONFIG_DIR canonicalized, or the literal
#                      "default" when unset. The Claude account it bills.
#
# Both must match. The account alone is not enough (two sessions can share a
# store), and the session alone is not enough (a session's store can be
# reconfigured); a home is refused when either has moved.
#
# NO FALLBACK. A missing pin refuses every verb but `ensure`, which is the one
# that establishes it. A malformed or unreadable pin refuses everything,
# including `ensure`: a home whose recorded identity cannot be read is never
# re-pinned from the environment, because that is exactly how a home would be
# silently migrated onto the wrong account. Repairing it is a deliberate
# operator act, and nothing here guesses which account was right.
#
# WHAT IT NEVER DOES. It does not move, merge, clean up, or delete a home; it
# does not change which account anything uses; and it does not read, print, or
# copy a credential value. It only records, compares, and refuses.
#
# EXIT CODES
#   0  pinned now, or the environment matches the pin
#   2  usage error
#   3  refused: mismatch, absent pin, or unreadable pin
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PIN="$DATA/home-identity"
SCHEMA=fm-home-identity-v1

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-home-identity: %s\n' "$1" >&2
  exit 2
}

die_refuse() {
  printf 'fm-home-identity: %s\n' "$1" >&2
  exit 3
}

canonical_store() {  # <path>
  local path=$1 real
  path=${path%/}
  [ -n "$path" ] || path=/
  if real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

ENV_SESSION=
ENV_STORE=

read_environment_identity() {
  ENV_SESSION=${HERDR_SESSION:-}
  [ -n "$ENV_SESSION" ] || ENV_SESSION=default
  case "$ENV_SESSION" in
    *[!A-Za-z0-9._-]*) die_refuse "HERDR_SESSION '$ENV_SESSION' is not a usable session name" ;;
  esac
  ENV_STORE=${CLAUDE_CONFIG_DIR:-}
  if [ -z "$ENV_STORE" ]; then
    ENV_STORE=default
  else
    case "$ENV_STORE" in
      /*) ENV_STORE=$(canonical_store "$ENV_STORE") ;;
      *) die_refuse "CLAUDE_CONFIG_DIR '$ENV_STORE' is not an absolute path, so this session's Claude account cannot be identified" ;;
    esac
  fi
}

PIN_SESSION=
PIN_STORE=

# 0 pinned and readable, 1 absent. A present-but-unreadable pin refuses here
# rather than returning "absent", so a corrupt pin can never be silently
# replaced by whatever session happens to be running.
read_pin() {
  local line version session store extra
  PIN_SESSION=; PIN_STORE=
  [ -e "$PIN" ] || return 1
  [ -f "$PIN" ] && [ ! -L "$PIN" ] \
    || die_refuse "$PIN is not a plain file; this home's recorded identity cannot be read and will not be replaced"
  version=; session=; store=; extra=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$SCHEMA") version=$line ;;
      herdr_session=*) session=${line#herdr_session=} ;;
      claude_config_dir=*) store=${line#claude_config_dir=} ;;
      ''|'#'*) ;;
      *) extra=1 ;;
    esac
  done < "$PIN" || die_refuse "$PIN could not be read; this home's recorded identity will not be replaced"
  [ "$version" = "$SCHEMA" ] && [ -n "$session" ] && [ -n "$store" ] && [ "$extra" -eq 0 ] \
    || die_refuse "$PIN does not hold a readable home identity; repair it deliberately rather than letting this session re-pin the home"
  PIN_SESSION=$session
  PIN_STORE=$store
  return 0
}

write_pin() {  # <path> <session> <store>
  local path=$1 session=$2 store=$3 dir tmp
  dir=${path%/*}
  [ "$dir" != "$path" ] || dir=.
  [ -d "$dir" ] && [ ! -L "$dir" ] || die_refuse "$dir is not a directory, so a home identity cannot be recorded there"
  tmp=$(umask 077; mktemp "$dir/.fm-home-identity.XXXXXX") \
    || die_refuse "a home identity record could not be staged in $dir"
  if ! printf '%s\nherdr_session=%s\nclaude_config_dir=%s\n' "$SCHEMA" "$session" "$store" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    die_refuse "the home identity record $path could not be written"
  fi
}

refuse_mismatch() {
  printf 'fm-home-identity: refused: this firstmate home belongs to session %s on Claude store %s, but the current session is %s on %s.\n' \
    "$PIN_SESSION" "$PIN_STORE" "$ENV_SESSION" "$ENV_STORE" >&2
  printf '                  Homes are never migrated or merged across sessions. Open this home from its own session, or use the home that belongs to this one.\n' >&2
  exit 3
}

action_ensure() {
  [ -d "$FM_HOME" ] \
    || die_refuse "'$FM_HOME' is not an existing directory, so it is not a firstmate home and no identity is recorded for it"
  read_environment_identity
  if read_pin; then
    { [ "$PIN_SESSION" = "$ENV_SESSION" ] && [ "$PIN_STORE" = "$ENV_STORE" ]; } || refuse_mismatch
    printf 'identity: session=%s store=%s (already pinned)\n' "$PIN_SESSION" "$PIN_STORE"
    return 0
  fi
  [ -d "$DATA" ] || (umask 077; mkdir -p "$DATA") \
    || die_refuse "the home's record directory $DATA could not be created"
  write_pin "$PIN" "$ENV_SESSION" "$ENV_STORE"
  printf 'identity: session=%s store=%s (pinned now)\n' "$ENV_SESSION" "$ENV_STORE"
}

action_check() {
  read_environment_identity
  read_pin || die_refuse "this firstmate home has no recorded identity yet; run 'fm-home-identity.sh ensure' from the session it belongs to before driving any fleet work from it"
  { [ "$PIN_SESSION" = "$ENV_SESSION" ] && [ "$PIN_STORE" = "$ENV_STORE" ]; } || refuse_mismatch
  printf 'identity: session=%s store=%s\n' "$PIN_SESSION" "$PIN_STORE"
}

action_store() {
  read_pin || die_refuse "this firstmate home has no recorded identity yet, so the Claude account its workers must use is unknown; pin it with 'fm-home-identity.sh ensure' from the session it belongs to"
  printf '%s\n' "$PIN_STORE"
}

action_show() {
  if read_pin; then
    printf '%s\nherdr_session=%s\nclaude_config_dir=%s\n' "$SCHEMA" "$PIN_SESSION" "$PIN_STORE"
  else
    printf 'absent\n'
  fi
}

SEED_TARGET=
# The argument and conflict half of seeding, with no write of any kind: a caller
# that must refuse before it is allowed to create anything runs this first.
# 0 = a matching pin is already recorded, 1 = no pin recorded yet, exit 3 =
# refused because the child is pinned to another identity.
seed_compare() {  # <home> <session> <store>
  local home=$1 session=$2 store=$3
  [ -d "$home" ] || die_usage "seed target '$home' is not a directory"
  case "$session" in
    ''|*[!A-Za-z0-9._-]*) die_usage "seed session '$session' is not a usable session name" ;;
  esac
  case "$store" in
    default|/*) ;;
    *) die_usage "seed store '$store' must be an absolute path or the literal default" ;;
  esac
  SEED_TARGET="$home/data/home-identity"
  [ -e "$SEED_TARGET" ] || return 1
  PIN=$SEED_TARGET
  read_pin || die_refuse "$SEED_TARGET exists but holds no readable identity"
  { [ "$PIN_SESSION" = "$session" ] && [ "$PIN_STORE" = "$store" ]; } || {
    printf 'fm-home-identity: refused: %s is already pinned to session %s on %s and will not be re-pinned to %s on %s\n' \
      "$SEED_TARGET" "$PIN_SESSION" "$PIN_STORE" "$session" "$store" >&2
    exit 3
  }
  return 0
}

# A child home is pinned from its PARENT's identity, not from the environment
# the provisioning command happens to run in, so a second mate and its own
# workers stay on the account the firstmate that created them belongs to.
action_seed() {  # <home> <session> <store>
  local home=$1 session=$2 store=$3
  if seed_compare "$home" "$session" "$store"; then
    printf 'identity: session=%s store=%s (already pinned)\n' "$session" "$store"
    return 0
  fi
  [ -d "$home/data" ] || (umask 077; mkdir -p "$home/data") \
    || die_refuse "the child home's record directory could not be created"
  write_pin "$SEED_TARGET" "$session" "$store"
  printf 'identity: session=%s store=%s (pinned now)\n' "$session" "$store"
}

action_verify() {  # <home> <session> <store>
  local home=$1 session=$2 store=$3
  if seed_compare "$home" "$session" "$store"; then
    printf 'identity: session=%s store=%s (already pinned)\n' "$session" "$store"
  else
    printf 'identity: session=%s store=%s (unpinned, seeding will record it)\n' "$session" "$store"
  fi
}

VERB=${1:-}
case "$VERB" in
  -h|--help) usage; exit 0 ;;
  '') die_usage "a verb is required" ;;
esac
shift

case "$VERB" in
  ensure) [ "$#" -eq 0 ] || die_usage "ensure takes no arguments"; action_ensure ;;
  check) [ "$#" -eq 0 ] || die_usage "check takes no arguments"; action_check ;;
  store) [ "$#" -eq 0 ] || die_usage "store takes no arguments"; action_store ;;
  show) [ "$#" -eq 0 ] || die_usage "show takes no arguments"; action_show ;;
  seed) [ "$#" -eq 3 ] || die_usage "seed takes <home> <session> <store>"; action_seed "$@" ;;
  verify) [ "$#" -eq 3 ] || die_usage "verify takes <home> <session> <store>"; action_verify "$@" ;;
  *) die_usage "unknown verb: $VERB" ;;
esac
