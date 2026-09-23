#!/usr/bin/env bash
# Live E2E: real bin/fm-spawn.sh builds the Pi worker launch (fake tmux captures
# the typed command), then the REAL pi binary is run with that launch's exact
# lean flags + --skill words, in rpc mode, and asked for its loaded commands.
# Also diffs the no-skill launch against the base commit's fm-spawn.sh.
set -u
WT=$1 BASE=$2
EV=$(cd "$(dirname "$0")" && pwd)
. "$WT/tests/fixtures.sh"

capture_launch() { # <root> <name> <id> [spawn args...] -> prints launch text
  local root=$1 name=$2 id=$3; shift 3
  local c="$SCRATCH/$name"
  mkdir -p "$c"
  local fb; fb=$(fm_test_make_spawn_fakebin "$c/fake" pi)
  fm_test_spawn_home "$c/home" pi
  fm_git_worktree "$c/project" "$c/wt" "wt-$name"
  fm_test_spawn_brief "$c/home" "$id"
  : > "$c/launch.log"
  ROOT=$root FM_FAKE_LAUNCH_LOG="$c/launch.log" \
    fm_test_run_spawn "$c/home" "$c/wt" "$fb" "$id" "$c/project" --mode direct-PR --yolo off "$@" > "$c/out.txt"
  echo "exit=$?" >> "$c/out.txt"
  sed -e "s#$c#<CASE>#g" -e "s#$root#<ROOT>#g" "$c/launch.log"
}

SCRATCH=$(mktemp -d)
SK="$SCRATCH/skills"
mkdir -p "$SK/seo audit" "$SK/empty-dir"
printf -- '---\nname: seo-audit\ndescription: SEO audit skill (dir with space in path)\n---\n# seo\n' > "$SK/seo audit/SKILL.md"
printf -- "---\nname: schema-markup\ndescription: Schema md skill with quote and ampersand\n---\n# s\n" > "$SK/it's & __WORKTREE__.md"

echo "== 1. default launch byte-identity vs base $BASE"
capture_launch "$BASE" base-default s-base-1 > "$EV/launch-default-base.txt"
capture_launch "$WT" new-default s-base-1 > "$EV/launch-default-new.txt"
if cmp -s "$EV/launch-default-base.txt" "$EV/launch-default-new.txt"; then echo "IDENTICAL"; else echo "DIFFERENT"; diff "$EV/launch-default-base.txt" "$EV/launch-default-new.txt"; fi
cat "$EV/launch-default-new.txt"; echo

echo "== 2. --skill launch built by real fm-spawn"
c="$SCRATCH/skills-case"
L=$(cd "$SCRATCH" && capture_launch "$WT" skills-case s-skill-2 --skill "skills/seo audit" --skill "$SK/it's & __WORKTREE__.md")
cat "$SCRATCH/skills-case/out.txt" | tail -1
raw=$(cat "$c/launch.log")
echo "$L" > "$EV/launch-with-skills.txt"
echo "$L"
# Words between --no-skills and --no-extensions are the fm-spawn-emitted skill words.
words=${raw#*--no-skills}; words=${words%% --no-extensions*}
echo "skill words: $words"

echo "== 3. REAL pi consumes those exact words"
eval "set -- $words"
printf 'argv: '; printf '[%s] ' "$@"; echo
cd "$SCRATCH/skills-case/wt"
echo '{"type":"get_commands"}' | timeout 60 pi --no-context-files --no-skills "$@" --no-extensions --mode rpc --no-session --offline 2>&1 \
  | sed "s#$SCRATCH#<SCRATCH>#g" | tee "$EV/pi-rpc-get-commands.json"
echo
echo "== 4. REAL pi baseline (lean flags, no --skill)"
echo '{"type":"get_commands"}' | timeout 60 pi --no-context-files --no-skills --no-extensions --mode rpc --no-session --offline 2>&1 \
  | tee "$EV/pi-rpc-get-commands-noskill.json"
echo
rm -rf "$SCRATCH"
