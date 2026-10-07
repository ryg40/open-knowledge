import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const script = join(root, 'scripts/tenant/workflows.mjs');
const files = ['.gitea/workflows/checks.yml', '.gitea/workflows/upstream-update.yml', '.github/workflows/portable-release.yml', '.github/workflows/public-checks.yml'];
function check(directory, env = {}) {
  return spawnSync(process.execPath, [script, 'check'], { encoding: 'utf8', env: { ...process.env, OK_WORKFLOWS_ROOT: directory, ...env } });
}
function copy(context) {
  const tmp = mkdtempSync(join(tmpdir(), 'ok-workflows-test-'));
  context.after(() => rmSync(tmp, { recursive: true, force: true }));
  for (const name of ['.gitea', '.github/workflows', 'scripts/tenant']) cpSync(join(root, name), join(tmp, name), { recursive: true });
  return tmp;
}
function refused(context, file, from, to, message) {
  const tmp = copy(context);
  const text = readFileSync(join(tmp, file), 'utf8');
  assert.ok(text.includes(from), `fixture text is absent: ${from}`);
  writeFileSync(join(tmp, file), text.replace(from, to));
  const output = check(tmp);
  assert.equal(output.status, 1, output.stdout + output.stderr);
  assert.match(output.stderr, message);
}

test('the fork workflow files pass, with and without the full parser', () => {
  const full = check(root);
  assert.equal(full.status, 0, full.stdout + full.stderr);
  assert.match(full.stdout, /^workflows: ok$/m);
  const empty = mkdtempSync(join(tmpdir(), 'ok-workflows-path-'));
  try {
    const structural = check(root, { PATH: empty });
    assert.equal(structural.status, 0, structural.stdout + structural.stderr);
    assert.match(structural.stdout, /structural check only/);
  } finally { rmSync(empty, { recursive: true, force: true }); }
});
test('invalid YAML and unknown files fail', (context) => {
  refused(context, files[0], 'name: Checks', 'name: [Checks', /unsupported plain scalar/);
  refused(context, files[0], '    name: Shell check', '   name: Shell check', /line \d+/);
  refused(context, files[3], 'permissions:\n  contents: read', 'permissions:\n  contents: read\n  contents: read', /duplicate key/);
  const tmp = copy(context);
  writeFileSync(join(tmp, '.gitea/workflows/extra.yml'), 'name: extra\n');
  assert.match(check(tmp).stderr, /extra\.yml: file is not in the fork workflow list/);
  rmSync(join(tmp, '.gitea/workflows/extra.yml'));
  rmSync(join(tmp, files[1]));
  assert.match(check(tmp).stderr, /missing fork workflow file/);
});
test('a run line names only known commands', (context) => {
  refused(context, files[3], 'run: scripts/tenant/scan.sh', 'run: scripts/tenant/absent.sh', /unknown repository command: scripts\/tenant\/absent\.sh/);
  refused(context, files[3], 'run: scripts/tenant/scan.sh', 'run: curl example.com', /unknown command: curl/);
  refused(context, files[3], 'run: scripts/tenant/scan.sh', 'run: echo "$(wget example.com)"', /unknown command: wget/);
  refused(context, files[3], 'run: scripts/tenant/scan.sh', 'run: node -e 1', /interpreter without a repository script/);
  refused(context, files[3], 'run: scripts/tenant/scan.sh', 'run: scripts/tenant/scan.sh ${{ github.ref }}', /workflow expression/);
  const tmp = copy(context);
  chmodSync(join(tmp, 'scripts/tenant/scan.sh'), 0o644);
  assert.match(check(tmp).stderr, /repository command is not executable: scripts\/tenant\/scan\.sh/);
});
test('no workflow promotes, tags or pushes, and each action has a commit pin', (context) => {
  refused(context, files[0], 'run: scripts/tenant/pins.sh', 'run: scripts/tenant/promote.sh --push', /must not promote/);
  refused(context, files[0], 'run: scripts/tenant/pins.sh', 'run: git push origin portable', /must not push/);
  refused(context, files[0], 'run: scripts/tenant/pins.sh', 'run: git tag portable-v9.9.9', /must not tag/);
  refused(context, files[0], '@34e114876b0b11c390a56381ad16ebd13914f8d5', '@v4', /not pinned by commit/);
});
test('secrets and the public workflow stay within their limits', (context) => {
  refused(context, files[0], 'vars.GITLEAKS_IMAGE', 'secrets.OTHER_TOKEN', /secret is not documented for this file: OTHER_TOKEN/);
  refused(context, files[3], 'runs-on: ubuntu-latest', 'runs-on: self-hosted', /hosted runner/);
  refused(context, files[3], 'permissions:\n  contents: read', 'permissions:\n  contents: write', /contents: read only/);
  refused(context, files[3], 'run: scripts/tenant/scan.sh', 'env:\n          TOKEN: ${{ github.token }}\n        run: scripts/tenant/scan.sh', /no token/);
});
test('the documented loop disables each upstream workflow and no fork workflow', (context) => {
  const tmp = mkdtempSync(join(tmpdir(), 'ok-workflows-gh-'));
  context.after(() => rmSync(tmp, { recursive: true, force: true }));
  mkdirSync(join(tmp, 'bin'));
  writeFileSync(join(tmp, 'bin/gh'), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${join(tmp, 'calls')}'\n`, { mode: 0o755 });
  const documented = readFileSync(join(root, 'deploy/docs/ci.md'), 'utf8').split('\n').filter((line) => line.includes('workflows.sh upstream |'));
  assert.equal(documented.length, 1);
  const output = spawnSync('sh', ['-c', documented[0].trim()], { cwd: root, encoding: 'utf8', env: { ...process.env, PATH: `${join(tmp, 'bin')}:${process.env.PATH}` } });
  assert.equal(output.status, 0, output.stderr);
  const calls = readFileSync(join(tmp, 'calls'), 'utf8').trim().split('\n');
  const upstream = spawnSync('git', ['ls-files', '.github/workflows'], { cwd: root, encoding: 'utf8' }).stdout.trim().split('\n').filter((file) => !files.includes(file));
  assert.ok(upstream.length > 0);
  assert.deepEqual(calls.sort(), upstream.map((file) => `workflow disable ${file.split('/').at(-1)}`).sort());
});
