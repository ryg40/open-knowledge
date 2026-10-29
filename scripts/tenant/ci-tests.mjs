import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const version = '99.0.0';
const identity = {
  ...process.env,
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_AUTHOR_NAME: 'Fixture',
  GIT_AUTHOR_EMAIL: 'fixture@example.com',
  GIT_COMMITTER_NAME: 'Fixture',
  GIT_COMMITTER_EMAIL: 'fixture@example.com',
};

function git(cwd, ...args) {
  const result = spawnSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], { cwd, env: identity, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function fixture(context, { manifest = '0.0.0-unknown', reset = false, offMain = false, tag = true } = {}) {
  const tmp = mkdtempSync(join(tmpdir(), 'ok-ci-release-test-'));
  context.after(() => rmSync(tmp, { recursive: true, force: true }));
  const upstream = join(tmp, 'upstream');
  const checkout = join(tmp, 'checkout');
  mkdirSync(join(upstream, 'packages/cli'), { recursive: true });
  git(upstream, 'init', '-q', '-b', 'main');
  writeFileSync(join(upstream, 'packages/cli/package.json'), JSON.stringify({ version: manifest }, null, 2));
  git(upstream, 'add', '.');
  git(upstream, 'commit', '-qm', 'Base');
  if (offMain) git(upstream, 'switch', '-c', 'release');
  writeFileSync(join(upstream, 'release'), 'stable\n');
  git(upstream, 'add', '.');
  git(upstream, 'commit', '-qm', reset ? `main reset: post-stable v${version}` : 'Published source');
  const release = git(upstream, 'rev-parse', 'HEAD');
  if (tag) git(upstream, 'tag', '-a', `v${version}`, '-m', 'Stable release');
  if (offMain) git(upstream, 'switch', 'main');
  writeFileSync(join(upstream, 'later'), 'unreleased\n');
  git(upstream, 'add', '.');
  git(upstream, 'commit', '-qm', 'Later work');
  git(tmp, 'clone', '--no-tags', upstream, checkout);
  git(checkout, 'config', `url.${upstream}.insteadOf`, 'https://github.com/inkeep/open-knowledge.git');
  mkdirSync(join(checkout, 'scripts/tenant'), { recursive: true });
  mkdirSync(join(checkout, 'deploy'), { recursive: true });
  cpSync(join(root, 'scripts/tenant/ci.sh'), join(checkout, 'scripts/tenant/ci.sh'));
  writeFileSync(join(checkout, 'deploy/Dockerfile'), `ARG OK_VERSION=${version}\n`);
  return {
    checkout,
    release,
    call: () => spawnSync('sh', ['scripts/tenant/ci.sh', 'upstream-ref'], { cwd: checkout, env: identity, encoding: 'utf8', timeout: 15000 }),
  };
}

for (const manifest of ['0.0.0-unknown', version]) {
  test(`upstream-ref verifies tagged ${manifest} source and is repeatable`, (context) => {
    const f = fixture(context, { manifest });
    for (let index = 0; index < 2; index++) {
      const result = f.call();
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.equal(git(f.checkout, 'rev-parse', `refs/tags/${version}^{commit}`), f.release);
    }
  });
}

test('upstream-ref keeps the matching post-stable release rule', (context) => {
  const f = fixture(context, { manifest: version, reset: true });
  const result = f.call();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /release commit/);
});

for (const options of [{ offMain: true }, { manifest: '98.0.0' }, { tag: false }]) {
  test(`upstream-ref refuses ${JSON.stringify(options)}`, (context) => {
    const f = fixture(context, options);
    const result = f.call();
    assert.equal(result.status, 2, result.stdout + result.stderr);
    assert.equal(git(f.checkout, 'tag', '--list', version), '');
  });
}

test('upstream-ref never replaces a different local release marker', (context) => {
  const f = fixture(context);
  const wrong = git(f.checkout, 'rev-parse', 'HEAD');
  git(f.checkout, 'tag', version, wrong);
  const result = f.call();
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.equal(git(f.checkout, 'rev-parse', `refs/tags/${version}^{commit}`), wrong);
});
