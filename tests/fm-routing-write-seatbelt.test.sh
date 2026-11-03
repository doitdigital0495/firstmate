#!/usr/bin/env bash
# Portable public-hook regressions; no harness, credentials, or live stores.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-routing-write)
export LAB ROOT
mkdir -p "$LAB/primary/bin" "$LAB/primary/state" "$LAB/user"
printf '# fixture\n' > "$LAB/primary/AGENTS.md"
git -C "$LAB/primary" init -q
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, symlinkSync } from 'node:fs';
const root = process.env.ROOT, lab = process.env.LAB, home = `${lab}/primary`;
const env = { ...process.env, HOME: `${lab}/user`, FM_HOME: home, FM_ROOT_OVERRIDE: home, FM_STATE_OVERRIDE: `${home}/state` };
const hook = `${root}/bin/fm-routing-write-pretool-check.sh`;
let count = 0;
function check(tool, input, deny, scope = home, cwd = home) {
  const result = spawnSync('bash', [hook, '--claude'], { env: { ...env, FM_ROOT_OVERRIDE: scope }, input: JSON.stringify({tool_name: tool, tool_input: input, cwd}), encoding: 'utf8' });
  assert.equal(result.status, deny ? 2 : 0, `${tool} ${JSON.stringify(input)}: ${result.stderr}`);
  assert.equal(result.stdout, '');
  if (deny) {
    const message = JSON.parse(result.stderr);
    assert.equal(message.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(message.systemMessage, /Use .+ instead/);
  } else assert.equal(result.stderr, '');
  count++;
}
const paths = ['state/dispatch-receipt/r.json', 'state/dispatch-pick/p.json', 'state/.host-mirror.jsonl', `${env.HOME}/.lavish-axi/answers/a.json`];
for (const path of paths) {
  for (const tool of ['Write', 'Edit', 'write', 'edit', 'MultiEdit']) check(tool, { file_path: path, path }, true);
  for (const op of ['>', '>>', '>|', '2>', '&>', '<>']) check('Bash', {command: `printf fake ${op} '${path}'`}, true);
  check('Bash', {command: `cat '${path}'`}, false);
  check('Read', {file_path: path}, false);
  check('Bash', {command: `printf '%s' 'echo fake > ${path}'`}, false);
  check('Bash', {command: `# echo fake > ${path}\nprintf ok`}, false);
  check('Bash', {command: `(printf fake > '${path}')`}, true);
  check('Bash', {command: `bash -c "printf fake > '${path}'"`}, true);
}
check('Bash', {command: 'printf fake > "$FM_HOME/state/dispatch-receipt/a.json"'}, true);
check('Bash', {command: 'printf fake >> "$HOME/.lavish-axi/answer"'}, true);
check('Bash', {command: 'printf fake > ~/.lavish-axi/answer'}, true);
check('Bash', {command: 'cd state; printf fake > dispatch-pick/a.json'}, true);
check('Write', {path: './state/../state/dispatch-pick/a.json'}, true);
symlinkSync(`${home}/state/dispatch-pick`, `${home}/alias`);
check('Edit', {path: 'alias/a.json'}, true);
check('Write', {path: 'state/dispatch-pick-backup/a.json'}, false);
check('Write', {path: 'data/report.md'}, false);
check('Bash', {command: "printf safe > '$HOME/.lavish-axi/not-the-user-store'"}, false);
check('Bash', {command: "printf safe > '~/.lavish-axi/not-the-user-store'"}, false);
check('Bash', {command: "cat <<'EOF'\nhello > state/dispatch-pick/a.json\nEOF\n"}, false);
// No script-name exemption: even sanctioned commands cannot carry a direct redirect.
for (const command of ['bin/fm-dispatch-resolve.sh brief.md', 'bin/fm-spawn.sh task', 'bin/fm-control.sh pick code 1', 'bin/fm-host-mirror.sh hook claude', 'lavish-axi page.html']) {
  check('Bash', {command}, false);
  check('Bash', {command: `${command} > state/dispatch-receipt/fake.json`}, true);
}
// Internal script writes never traverse the agent hook: execute a private
// fixture writer after preflight, proving actual bytes land, not just allow text.
const writer = `${home}/bin/internal-writer.sh`;
writeFileSync(writer, '#!/usr/bin/env bash\nmkdir -p "$FM_HOME/state/dispatch-receipt"\nprintf sanctioned > "$FM_HOME/state/dispatch-receipt/internal.json"\n');
check('Bash', {command: `bash '${writer}'`}, false);
assert.equal(spawnSync('bash', [writer], {env}).status, 0);
assert.ok(existsSync(`${home}/state/dispatch-receipt/internal.json`));
// A linked-worker-shaped root stays inert, while a marked secondmate is guarded.
const worker = `${lab}/worker`;
mkdirSync(`${worker}/bin`, {recursive:true}); writeFileSync(`${worker}/AGENTS.md`, '# worker');
writeFileSync(`${worker}/.git`, `gitdir: ${home}/.git/worktrees/missing\n`);
check('Write', {path: paths[0]}, false, worker);
writeFileSync(`${worker}/.fm-secondmate-home`, 'fixture\n');
check('Write', {path: `${home}/${paths[0]}`}, true, worker);
console.log(`ok - routing write seatbelt: ${count} public hook checks; internal writer completed`);
JS
# Exercise the actual Pi adapter registration without a model or SDK runtime.
FM_ROOT_OVERRIDE="$LAB/primary" FM_HOME="$LAB/primary" FM_STATE_OVERRIDE="$LAB/primary/state" \
  NODE_NO_WARNINGS=1 node --input-type=module-typescript <<'TS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { default: register } = await import(pathToFileURL(`${process.env.ROOT}/.pi/extensions/fm-routing-write-seatbelt.ts`).href);
let handler;
register({ on: (name, callback) => { assert.equal(name, 'tool_call'); handler = callback; } });
const ctx = { cwd: `${process.env.LAB}/primary` };
for (const toolName of ['write', 'edit', 'bash']) {
  const input = toolName === 'bash' ? { command: 'printf bad > state/dispatch-pick/a.json' } : { path: 'state/dispatch-pick/a.json' };
  assert.equal(handler({toolName, input}, ctx).block, true);
}
assert.equal(handler({toolName:'write', input:{path:'ordinary.txt'}}, ctx), undefined);
assert.equal(handler({toolName:'read', input:{path:'state/dispatch-pick/a.json'}}, ctx), undefined);
console.log('ok - Pi tool_call adapter blocks write/edit/bash and preserves ordinary tools');
TS
pass 'portable routing write seatbelt denies direct writes and preserves internal writers'
