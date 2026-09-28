. /home/daan/.no-mistakes/evidence/01M3KNMV0A57WVYHMG6DN2SX7J/adversarial-funcs.sh
adv_default_store() {
  local c="$TMP_ROOT/adv-c" out
  local home=$c/home proj=$c/project wt=$c/wt log=$c/launch.log fakebin
  fakebin=$(make_spawn_fakebin "$c/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-adv-c
  fm_test_spawn_brief "$home" advdefault
  out=$(FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$home" "$wt" "$fakebin" advdefault "$proj" claude --mode no-mistakes --yolo off)
  echo "spawn exit=$? ; output tail:"; printf '%s\n' "$out" | tail -2
  echo "home pin: $(FM_HOME=$home HOME=$home/user-home CLAUDE_CONFIG_DIR= "$ROOT/bin/fm-home-identity.sh" show 2>&1 | tr '\n' ' ')"
  echo "launch: $(tr '\n' ' ' < "$log" | cut -c1-160)"
  echo "default store (\$HOME/.claude.json) trusted paths:"; trusted_paths "$home/user-home/.claude.json"
  echo "expected wt: $wt"
}
echo "== C: default-pinned home, no --account, no ambient store"; adv_default_store
