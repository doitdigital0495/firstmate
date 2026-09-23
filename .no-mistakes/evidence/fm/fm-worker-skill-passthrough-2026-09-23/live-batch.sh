#!/usr/bin/env bash
# Batch dispatch: two id=project pairs with one --skill; both launches must carry it.
set -u
WT=$1; . "$WT/tests/fixtures.sh"; ROOT=$WT
c=$(mktemp -d); fb=$(fm_test_make_spawn_fakebin "$c/fake" pi)
fm_test_spawn_home "$c/home" pi
fm_git_worktree "$c/project" "$c/wt" wt-batch
fm_test_spawn_brief "$c/home" b-one-s1; fm_test_spawn_brief "$c/home" b-two-s2
mkdir -p "$c/sk/seo"; printf '# s\n' > "$c/sk/seo/SKILL.md"; : > "$c/launch.log"
FM_FAKE_LAUNCH_LOG="$c/launch.log" fm_test_run_spawn "$c/home" "$c/wt" "$fb" \
  "b-one-s1=$c/project" "b-two-s2=$c/project" --mode direct-PR --yolo off --skill "$c/sk/seo" | sed "s#$c#<C>#g"
echo "exit=${PIPESTATUS[0]}"
echo "launches carrying --skill: $(grep -c -- "--no-skills --skill '$c/sk/seo' --no-extensions" "$c/launch.log")"
sed "s#$c#<C>#g" "$c/launch.log" | grep -o -- "--no-skills.*--no-extensions"
rm -rf "$c"
