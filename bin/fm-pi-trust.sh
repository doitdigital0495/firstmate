#!/usr/bin/env bash
# Pre-register Pi's project trust for the isolated task worktree a ship/scout
# spawn is about to launch a pi or pi-signed crewmate into, so the worker
# reaches its brief instead of parking on Pi's "Trust project folder?" dialog.
#
# Usage: fm-pi-trust.sh <worktree> <project> <agent-dir>
#   <worktree>   the isolated task worktree this spawn launches into
#   <project>    the primary checkout that worktree belongs to
#   <agent-dir>  the Pi agent dir the launch uses (PI_CODING_AGENT_DIR, or
#                ~/.pi/agent when that is unset); an empty value means the default
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. Pi (0.86.1) gates any cwd that carries project resources -
# .pi/settings.json, .pi/extensions and friends, or an .agents/skills directory
# in the cwd or an ancestor - behind an interactive trust dialog, and every
# task worktree is a fresh path. Pi keeps its decisions in <agent-dir>/trust.json
# (dist/core/trust-manager.js): a JSON object whose keys are realpath-resolved
# directories and whose values are true, false, or null, looked up from the
# cwd upward with the nearest true/false entry winning. Pi writes the file with
# sorted keys under a proper-lockfile lock directory at trust.json.lock, and
# this script takes that same lock so it never interleaves with a live Pi.
# The exact worktree key is set to true, which also replaces a stale false left
# on a reused pool path; every other entry is preserved.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-agy-trust.sh:
# <worktree> must be a LINKED git worktree - its own git dir, sharing
# <project>'s common dir - whose top level is exactly the resolved argument. A
# primary checkout, a worktree of an unrelated repo, a subdirectory of a
# worktree, a plain directory, and a home directory are each refused with a
# non-zero exit, never a warning and never a silent skip. The store must be a
# regular file this uid owns, and the replacement is atomic.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

[ "$#" -eq 3 ] || { echo "usage: fm-pi-trust.sh <worktree> <project> <agent-dir>" >&2; exit 2; }
WT_ARG=$1
PROJ_ARG=$2
AGENT_ARG=$3

refuse() { echo "error: refusing to pre-register pi trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

WT_REAL=$(real_dir "$WT_ARG") || true
[ -n "$WT_REAL" ] || refuse "worktree '$WT_ARG' is not an accessible directory"
PROJ_REAL=$(real_dir "$PROJ_ARG") || true
[ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"

[ -n "${HOME:-}" ] || refuse "HOME is not set, so pi's agent dir cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
[ "$WT_REAL" != "$HOME_REAL" ] || refuse "'$WT_REAL' is the home directory, not a task worktree"

WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$WT_TOP" ] || refuse "'$WT_REAL' is not inside a git repository"
WT_TOP_REAL=$(real_dir "$WT_TOP") || true
[ "$WT_TOP_REAL" = "$WT_REAL" ] || refuse "'$WT_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"

WT_GIT_DIR=$(git -C "$WT_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has no resolvable git directory"
WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
[ -n "$WT_GIT_DIR" ] || refuse "'$WT_REAL' has an unresolvable git directory"
WT_COMMON=$(common_dir_of "$WT_REAL") || true
[ -n "$WT_COMMON" ] || refuse "'$WT_REAL' has no resolvable git common directory"
[ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$WT_REAL' is a primary checkout, not an isolated worktree"

PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
[ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
[ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$WT_REAL' is not a worktree of project '$PROJ_REAL'"

command -v node >/dev/null 2>&1 || refuse "node is required to record project trust and was not found on PATH"

# Pi expands a leading ~ in PI_CODING_AGENT_DIR itself, so the same spelling is
# honoured here.
# shellcheck disable=SC2088 # Literal tilde prefix, not shell expansion.
case "$AGENT_ARG" in
  '') AGENT_DIR="$HOME_REAL/.pi/agent" ;;
  '~') AGENT_DIR=$HOME_REAL ;;
  '~/'*) AGENT_DIR="$HOME_REAL/${AGENT_ARG:2}" ;;
  /*) AGENT_DIR=$AGENT_ARG ;;
  *) refuse "agent dir '$AGENT_ARG' is not an absolute path" ;;
esac
mkdir -p "$AGENT_DIR" 2>/dev/null || true
AGENT_REAL=$(real_dir "$AGENT_DIR") || true
[ -n "$AGENT_REAL" ] || refuse "pi agent dir '$AGENT_DIR' does not exist and could not be created"
STORE="$AGENT_REAL/trust.json"
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Pi's lock is proper-lockfile's: an atomic mkdir of <store>.lock, refreshed
# while held and treated as stale once its mtime is 10 seconds old. Taking it
# the same way keeps a concurrent Pi dialog answer from being lost, and the
# rename keeps a reader from ever seeing a half-written store.
if ! node - "$STORE" "$WT_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, key] = process.argv.slice(2);
const lock = `${store}.lock`;
const STALE_MS = 10000;
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const acquire = () => {
  for (let i = 0; i < 150; i += 1) {
    try {
      fs.mkdirSync(lock);
      return;
    } catch (err) {
      if (err.code !== "EEXIST") throw err;
      try {
        if (Date.now() - fs.statSync(lock).mtimeMs > STALE_MS) {
          fs.rmdirSync(lock);
          continue;
        }
      } catch (statErr) {
        if (statErr.code !== "ENOENT") throw statErr;
        continue;
      }
      sleep(20);
    }
  }
  throw new Error(`${lock} stayed held; another pi is writing its trust store`);
};
const readStore = () => {
  let raw;
  try {
    raw = fs.readFileSync(store, "utf8").replace(/^﻿/, "");
  } catch (err) {
    if (err.code === "ENOENT") return {};
    throw err;
  }
  if (raw.trim() === "") return {};
  const root = JSON.parse(raw);
  if (root === null || typeof root !== "object" || Array.isArray(root)) {
    throw new Error(`${store} is not a JSON object`);
  }
  for (const [k, v] of Object.entries(root)) {
    if (v !== true && v !== false && v !== null) {
      throw new Error(`${store} value for ${JSON.stringify(k)} is not true, false, or null`);
    }
  }
  return root;
};
try {
  acquire();
  try {
    const root = readStore();
    if (root[key] !== true) {
      root[key] = true;
      const sorted = {};
      for (const k of Object.keys(root).sort()) sorted[k] = root[k];
      const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
      const tmp = path.join(path.dirname(store), `.trust.json.fm-trust.${unique}`);
      fs.writeFileSync(tmp, `${JSON.stringify(sorted, null, 2)}\n`, { mode: 0o600, flag: "wx" });
      try {
        fs.renameSync(tmp, store);
      } catch (err) {
        fs.rmSync(tmp, { force: true });
        throw err;
      }
    }
    if (readStore()[key] !== true) throw new Error(`${store} did not retain trust for ${key}`);
  } finally {
    fs.rmdirSync(lock);
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
NODE
then
  refuse "could not record trust for '$WT_REAL' in '$STORE'"
fi

echo "trusted: $WT_REAL in $STORE"
