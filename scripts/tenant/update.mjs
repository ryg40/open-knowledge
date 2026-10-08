import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const kit = dirname(fileURLToPath(import.meta.url));
const source = resolve(kit, '../..');
const action = process.argv[2];
const options = {};
let result = { action, steps: [] };
let runDirectory;
let scratch;
let env;
let docker;
let prefix;
let image;
let ledger;
let imageAttempted = false;
let baseImage;
let baseImageAttempted = false;
let child;
let interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    interrupted = true;
    if (child) child.kill(signal);
  });
}

function executable(name) {
  if (name.includes('/')) return realpathSync(name);
  for (const directory of process.env.PATH.split(':')) {
    const path = join(directory, name);
    if (existsSync(path)) return realpathSync(path);
  }
  throw new Error(`missing command: ${name}`);
}
function command(key, fallback) {
  return executable(process.env[key] || fallback);
}
function sterile(directory) {
  for (const name of ['home', 'tmp', 'docker', 'npm-cache', 'bin']) mkdirSync(join(directory, name));
  for (const name of ['npm-user', 'npm-global']) writeFileSync(join(directory, name), '');
  const transport = Object.fromEntries(['DOCKER_HOST', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'].filter((name) => process.env[name] !== undefined).map((name) => [name, process.env[name]]));
  return {
    ...transport,
    PATH: process.env.PATH,
    HOME: join(directory, 'home'), TMPDIR: join(directory, 'tmp'),
    XDG_CONFIG_HOME: join(directory, 'home'),
    DOCKER_CONFIG: join(directory, 'docker'),
    npm_config_userconfig: join(directory, 'npm-user'),
    npm_config_globalconfig: join(directory, 'npm-global'),
    npm_config_cache: join(directory, 'npm-cache'),
    npm_config_registry: 'https://registry.npmjs.org',
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_COUNT: '2', GIT_CONFIG_KEY_0: 'credential.helper', GIT_CONFIG_VALUE_0: '',
    GIT_CONFIG_KEY_1: 'core.askPass', GIT_CONFIG_VALUE_1: '',
    GIT_TERMINAL_PROMPT: '0', GIT_ASKPASS: '/bin/false', GIT_PAGER: 'cat', LC_ALL: 'C',
    GIT_AUTHOR_NAME: 'OpenKnowledge Release', GIT_AUTHOR_EMAIL: 'noreply@example.com',
    GIT_COMMITTER_NAME: 'OpenKnowledge Release', GIT_COMMITTER_EMAIL: 'noreply@example.com',
    DO_NOT_TRACK: '1', CI: 'true', DOCKER_BUILDKIT: '1', BUILDKIT_PROGRESS: 'plain',
  };
}
function run(program, args, cwd = scratch || source) {
  if (interrupted) throw new Error('run interrupted');
  const output = spawnSync(program, args, { cwd, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (output.error || output.status !== 0) throw new Error(`command failed: ${program} ${args.join(' ')} (exit ${output.status ?? 2})\n${output.stderr || output.error?.message || ''}`);
  return output.stdout.trim();
}
function git(...args) { return run('git', args); }
function version(value) {
  if (!/^\d+\.\d+\.\d+$/.test(value || '')) throw new Error('expected a stable X.Y.Z version');
  return value;
}
function compare(a, b) {
  const left = a.split('.').map(Number), right = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return left[i] > right[i] ? 1 : -1;
  return 0;
}
function pins() {
  const dockerfile = readFileSync(join(source, 'deploy/Dockerfile'), 'utf8');
  const pin = (name) => {
    const matches = [...dockerfile.matchAll(new RegExp(`^ARG ${name}=(.+)$`, 'gm'))];
    if (matches.length !== 1) throw new Error(`invalid pin source: ${name}`);
    return matches[0][1];
  };
  const scanner = readFileSync(join(source, 'scripts/tenant/scan.sh'), 'utf8').match(/^default_image=(.+)$/m)?.[1];
  if (!scanner) throw new Error('missing scanner image');
  return { OK_VERSION: version(pin('OK_VERSION')), NODE_IMAGE: pin('NODE_IMAGE'), scanner };
}
function npmValue(spec, field) {
  return JSON.parse(run(command('OK_UPDATE_NPM_COMMAND', 'npm'), ['view', spec, field, '--json'], runDirectory));
}
function latest() {
  const versions = npmValue('@inkeep/open-knowledge', 'versions');
  if (!Array.isArray(versions)) throw new Error('registry versions must be an array');
  const stable = versions.filter((entry) => /^\d+\.\d+\.\d+$/.test(entry)).sort(compare);
  if (!stable.length) throw new Error('registry has no stable release');
  return stable.at(-1);
}
function digest(reference) {
  const tag = reference.split('@')[0];
  const override = process.env.OK_UPDATE_DIGEST_COMMAND;
  const value = override ? run(executable(override), [tag], runDirectory)
    : run(docker, ['buildx', 'imagetools', 'inspect', '--format', '{{.Manifest.Digest}}', tag], runDirectory);
  if (!/^sha256:[a-f0-9]{64}$/.test(value)) throw new Error('registry returned an invalid image digest');
  return `${tag}@${value}`;
}
async function step(name, operation, dependency = true) {
  const log = join(runDirectory, `${String(result.steps.length + 1).padStart(2, '0')}-${name}.log`);
  const record = { name, exit_code: 0, log_path: log, duration_ms: 0, status: 'passed' };
  const started = Date.now();
  writeFileSync(log, '');
  const execute = (program, args, cwd = scratch || runDirectory, outputLog = log) => new Promise((done) => {
    if (interrupted && name !== 'cleanup') { done(130); return; }
    const fd = openSync(outputLog, 'a');
    child = spawn(program, args, { cwd, env, stdio: ['ignore', fd, fd] });
    const held = child;
    held.on('exit', () => { if (child === held) child = undefined; });
    held.on('error', (error) => { writeFileSync(outputLog, `${error.message}\n`, { flag: 'a' }); });
    held.on('close', (code) => { closeSync(fd); if (child === held) child = undefined; done(code ?? 2); });
  });
  if (!dependency) {
    record.exit_code = null;
    record.status = 'skipped';
    writeFileSync(log, 'not run: a required earlier step failed\n');
  } else {
    try {
      record.exit_code = await operation(execute, log);
      if (record.exit_code !== 0) record.status = 'failed';
    } catch (error) {
      record.exit_code = 2;
      record.status = 'failed';
      writeFileSync(log, `${error.message}\n`, { flag: 'a' });
    }
  }
  if (name.startsWith('scan-') && record.status === 'failed') {
    record.findings = readFileSync(log, 'utf8').split('\n').filter((line) => !line.startsWith('note:') && /^(RuleID:|File:|Line:|StartLine:|Commit:|.*leaks found:)/.test(line)).map((line) => line.trim());
  }
  record.duration_ms = Date.now() - started;
  result.steps.push(record);
  return record.status === 'passed';
}
function prepareWorkdir() {
  if (!options.workdir) throw new Error('--workdir is required');
  const target = resolve(options.workdir);
  let ancestor = target;
  while (!existsSync(ancestor)) ancestor = dirname(ancestor);
  if (realpathSync(ancestor) !== ancestor || target === source || source.startsWith(`${target}/`)) throw new Error('workdir must not be a symlink or an ancestor of the checkout');
  mkdirSync(target, { recursive: true });
  const canonical = realpathSync(target);
  runDirectory = mkdtempSync(join(canonical, 'ok-update-'));
  env = sterile(runDirectory);
}
async function clone() {
  return step('clone', async (execute) => {
    const code = await execute('git', ['clone', '--no-local', '--no-hardlinks', '--no-tags', '--no-checkout', source, join(runDirectory, 'repo')]);
    if (code) return code;
    scratch = join(runDirectory, 'repo');
    git('remote', 'remove', 'origin');
    const url = run('git', ['config', '--get', 'remote.upstream.url'], source);
    if (url !== 'https://github.com/inkeep/open-knowledge.git' && !(isAbsolute(url) && existsSync(url))) throw new Error('upstream must be the public HTTPS repository or a local test repository');
    git('remote', 'add', 'upstream', url);
    git('config', 'remote.upstream.pushurl', 'DISABLED');
    git('config', 'remote.upstream.tagOpt', '--no-tags');
    git('config', 'ok.hostRules', 'none');
    git('checkout', '-B', result.branch || 'update-notes', result.local_dev);
    return 0;
  });
}
function releaseCommit(release) {
  version(release);
  const lines = git('log', '--first-parent', '--format=%H%x09%s', 'refs/remotes/upstream/main').split('\n');
  const candidates = lines.filter((line) => new RegExp(`^main reset: post-stable v${release.replaceAll('.', '\\.')}($|[ (])`).test(line.split('\t').slice(1).join('\t')));
  if (candidates.length !== 1) throw new Error(`expected one post-stable commit for ${release}, found ${candidates.length}`);
  const sha = candidates[0].split('\t')[0];
  const manifest = JSON.parse(git('show', `${sha}:packages/cli/package.json`));
  if (manifest.version !== release) throw new Error('post-stable package version does not match');
  return sha;
}
async function fetchUpstream(dependency) {
  return step('fetch-upstream', (execute) => execute('git', ['fetch', '--no-tags', 'upstream', '+refs/heads/main:refs/remotes/upstream/main']), dependency);
}
function setupDocker() {
  docker = command('OK_UPDATE_DOCKER_COMMAND', process.env.OK_CONTAINER_CLI || 'docker');
  prefix = `ok-update-${randomBytes(8).toString('hex')}`;
  image = `${prefix}:${options.version || 'test'}`;
  ledger = join(runDirectory, 'containers');
  writeFileSync(ledger, '');
  const wrapper = join(runDirectory, 'bin/docker');
  writeFileSync(wrapper, `#!/bin/sh\nexec '${process.execPath.replaceAll("'", "'\\''")}' '${join(kit, 'update-docker.mjs').replaceAll("'", "'\\''")}' "$@"\n`, { mode: 0o755 });
  env = { ...env, PATH: `${join(runDirectory, 'bin')}:${env.PATH}`,
    OK_UPDATE_DOCKER_EXECUTABLE: docker, OK_UPDATE_PREFIX: prefix,
    OK_UPDATE_IMAGE: image, OK_UPDATE_CONTAINER_LEDGER: ledger };
}
async function qualify() {
  version(options.version);
  prepareWorkdir();
  result = { action, version: options.version, branch: `sync/v${options.version}`, local_dev: run('git', ['rev-parse', '--verify', 'refs/heads/local-dev^{commit}'], source), steps: [] };
  setupDocker();
  const cloned = await clone();
  const fetched = await fetchUpstream(cloned);
  let upstream;
  const selected = await step('select-release', async (_, log) => {
    upstream = releaseCommit(options.version);
    result.upstream_commit = upstream;
    git('branch', '-f', 'main', upstream);
    writeFileSync(log, `${upstream}\n`);
    return 0;
  }, fetched);
  const merged = await step('merge', (execute) => execute('git', ['-c', 'core.hooksPath=/dev/null', 'merge', '--no-ff', '--no-edit', '-m', `Trial upstream sync ${options.version}`, upstream]), selected);
  const installed = await step('install-hooks', (execute) => execute('sh', ['scripts/tenant/install-hooks.sh']), merged);
  await step('hooks-check', (execute) => execute('sh', ['scripts/tenant/install-hooks.sh', '--check']), installed);
  const pinned = await step('pins', async (_, log) => {
    const integrity = npmValue(`@inkeep/open-knowledge@${options.version}`, 'dist.integrity');
    if (typeof integrity !== 'string' || !/^sha512-[A-Za-z0-9+/]{86}==$/.test(integrity)) throw new Error('invalid registry sha512');
    const file = join(scratch, 'deploy/Dockerfile');
    const original = readFileSync(file, 'utf8');
    for (const key of ['OK_VERSION', 'OK_NPM_INTEGRITY']) if ([...original.matchAll(new RegExp(`^ARG ${key}=.+$`, 'gm'))].length !== 1) throw new Error(`invalid pin source: ${key}`);
    writeFileSync(file, original.replace(/^ARG OK_VERSION=.+$/m, `ARG OK_VERSION=${options.version}`).replace(/^ARG OK_NPM_INTEGRITY=.+$/m, `ARG OK_NPM_INTEGRITY=${integrity}`));
    const facts = join(scratch, 'EXPLAINER.md');
    const manager = JSON.parse(readFileSync(join(scratch, 'package.json'), 'utf8')).packageManager;
    if (!/^pnpm@\d+\.\d+\.\d+$/.test(manager)) throw new Error('invalid packageManager');
    writeFileSync(facts, readFileSync(facts, 'utf8').replace(/^(\| Upstream version \| )`[^`]+`/m, `$1\`${options.version}\``).replace(/^(\| Tarball sha512 \| )`[^`]+`/m, `$1\`${integrity}\``).replace(/^(\| pnpm version \| )`[^`]+`/m, `$1\`${manager.slice(5)}\``));
    git('add', '--', 'deploy/Dockerfile', 'EXPLAINER.md');
    git('-c', 'core.hooksPath=/dev/null', 'commit', '--allow-empty', '-m', `Trial pins ${options.version}`);
    writeFileSync(log, 'trial version and tarball integrity set\n');
    return 0;
  }, merged);
  await step('pins-check', (execute) => execute('sh', ['scripts/tenant/pins.sh']), pinned);
  await step('scan-tree', (execute) => execute('sh', ['scripts/tenant/scan.sh']), pinned);
  await step('scan-range', (execute) => execute('sh', ['scripts/tenant/scan.sh', '--history', `${result.local_dev}..HEAD`]), pinned);
  await step('public-check', (execute) => execute('sh', ['scripts/tenant/public-check.sh']), pinned);
  const portFree = await step('port-check', async (_, log) => {
    const port = process.env.SMOKE_PORT || '18080';
    if (!/^\d{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65535) throw new Error('invalid SMOKE_PORT');
    const listeners = run(command('OK_UPDATE_SS_COMMAND', 'ss'), ['-ltn']);
    writeFileSync(log, listeners + '\n');
    if (listeners.split('\n').some((line) => line.trim().split(/\s+/)[3]?.endsWith(`:${Number(port)}`))) throw new Error('test port is in use');
    env.SMOKE_PORT = String(Number(port));
    result.test_port = Number(port);
    return 0;
  }, cloned);
  const built = await step('build', (execute) => {
    imageAttempted = true;
    return execute('sh', ['scripts/tenant/build.sh', '-v', options.version, '-t', image]);
  }, pinned);
  await step('smoke', (execute) => execute('sh', ['scripts/tenant/smoke.sh', image]), built && portFree);
  await step('image-version', async (execute, log) => {
    const code = await execute('docker', ['run', '--rm', '--network', 'none', '--entrypoint', 'ok', image, '--version']);
    if (code) return code;
    return readFileSync(log, 'utf8').split(/\r?\n/, 1)[0].trim() === options.version ? 0 : 1;
  }, built);
  await step('scan-image', async (execute, log) => {
    const dockerfile = readFileSync(join(scratch, 'deploy/Dockerfile'), 'utf8');
    const pins = [...dockerfile.matchAll(/^ARG NODE_IMAGE=(.+)$/gm)];
    if (pins.length !== 1 || !/^[A-Za-z0-9./:_-]+@sha256:[a-f0-9]{64}$/.test(pins[0][1])) throw new Error('invalid NODE_IMAGE baseline');
    const baseline = join(runDirectory, 'base-image');
    mkdirSync(baseline);
    writeFileSync(join(baseline, 'Dockerfile'), `FROM ${pins[0][1]}\n`);
    baseImage = `${prefix}:base`;
    baseImageAttempted = true;
    let code = await execute('docker', ['build', '--file', join(baseline, 'Dockerfile'), '--tag', baseImage, baseline]);
    if (code) return code;
    const rootfs = (reference) => {
      const layers = JSON.parse(run('docker', ['image', 'inspect', '--format', '{{json .RootFS.Layers}}', reference]));
      if (!Array.isArray(layers) || !layers.length || layers.some((layer) => !/^sha256:[a-f0-9]{64}$/.test(layer))) throw new Error('invalid image rootfs layers');
      return layers;
    };
    const baseLayers = rootfs(baseImage), imageLayers = rootfs(image);
    if (imageLayers.length <= baseLayers.length || baseLayers.some((layer, index) => imageLayers[index] !== layer)) throw new Error('image layers do not extend pinned NODE_IMAGE');
    const archive = join(runDirectory, 'image.tar');
    code = await execute('docker', ['image', 'save', '--output', archive, image]);
    if (code) return code;
    const layers = join(runDirectory, 'layers');
    mkdirSync(layers);
    code = await execute('tar', ['-xf', archive, '-C', layers]);
    if (code) return code;
    const manifest = JSON.parse(readFileSync(join(layers, 'manifest.json'), 'utf8'));
    if (!Array.isArray(manifest) || manifest.length !== 1 || !Array.isArray(manifest[0].Layers) || manifest[0].Layers.length !== imageLayers.length) throw new Error('invalid saved image manifest');
    const contents = join(runDirectory, 'image-content');
    const baseContents = join(contents, 'base'), addedContents = join(contents, 'added');
    mkdirSync(baseContents, { recursive: true });
    mkdirSync(addedContents);
    for (const [index, path] of manifest[0].Layers.entries()) {
      if (typeof path !== 'string' || isAbsolute(path) || path.split('/').includes('..')) throw new Error('invalid image layer path');
      const directory = join(index < baseLayers.length ? baseContents : addedContents, String(index));
      mkdirSync(directory);
      code = await execute('tar', ['--no-same-owner', '--no-same-permissions', '-xf', join(layers, path), '-C', directory]);
      if (code) return code;
    }
    const scanner = readFileSync(join(scratch, 'scripts/tenant/scan.sh'), 'utf8').match(/^default_image=(.+)$/m)?.[1];
    if (!scanner) throw new Error('missing scanner image');
    const scan = async (directory, outputLog) => {
      const code = await execute('docker', ['run', '--rm', '--network', 'none', '--volume', `${directory}:/work:ro`, '--volume', `${join(scratch, '.gitleaks.toml')}:/config/gitleaks.toml:ro`, scanner, 'dir', '--no-banner', '--no-color', '--redact', '--verbose', '--config', '/config/gitleaks.toml', '/work'], scratch, outputLog);
      const output = readFileSync(outputLog, 'utf8');
      if (!/(no leaks found|leaks found: [0-9]+)/.test(output) || /(^|\s)ERR(\s|$)/m.test(output) || ![0, 1].includes(code)) return 2;
      if (/leaks found: [1-9][0-9]*/.test(output)) return 1;
      return code;
    };
    const baseLog = join(runDirectory, 'base-layers.log'), addedLog = join(runDirectory, 'added-layers.log');
    writeFileSync(baseLog, ''); writeFileSync(addedLog, '');
    const baseCode = await scan(baseContents, baseLog);
    writeFileSync(log, `note: pinned NODE_IMAGE layers are informational\n${readFileSync(baseLog, 'utf8').split('\n').filter(Boolean).map((line) => `note: ${line}`).join('\n')}\n`, { flag: 'a' });
    const addedCode = await scan(addedContents, addedLog);
    writeFileSync(log, readFileSync(addedLog, 'utf8'), { flag: 'a' });
    return baseCode === 2 ? 2 : addedCode;
  }, built);
  if (options.bundle) {
    await step('bundle', async (execute) => {
      const target = resolve(options.bundle);
      if (existsSync(target)) throw new Error('bundle path exists');
      const code = await execute('git', ['bundle', 'create', target, `refs/heads/${result.branch}`, `^${result.local_dev}`]);
      if (code === 0) result.bundle = target;
      return code;
    }, result.steps.every((record) => record.status === 'passed'));
  }
  result.image = image;
}
async function detect() {
  runDirectory = mkdtempSync(join(tmpdir(), 'ok-update-detect-'));
  env = sterile(runDirectory);
  docker = command('OK_UPDATE_DOCKER_COMMAND', process.env.OK_CONTAINER_CLI || 'docker');
  const current = pins();
  const newest = latest();
  const records = [
    { name: 'OK_VERSION', current: current.OK_VERSION, latest: newest, behind: compare(newest, current.OK_VERSION) > 0 },
    ...['NODE_IMAGE', 'scanner'].map((name) => {
      const value = digest(current[name]);
      return { name, current: current[name], latest: value, behind: value !== current[name] };
    }),
  ];
  result = { action, new_version: newest, pins: records, behind: records.some((record) => record.behind) };
}
async function releaseNotes() {
  if (process.env.OK_UPDATE_RELEASES_COMMAND) return JSON.parse(run(executable(process.env.OK_UPDATE_RELEASES_COMMAND), [options.from, options.to], runDirectory));
  const releases = [];
  for (let page = 1; page <= 100; page++) {
    const response = await fetch(`https://api.github.com/repos/inkeep/open-knowledge/releases?per_page=100&page=${page}`, { headers: { accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw new Error(`release notes request failed: HTTP ${response.status}`);
    const entries = await response.json();
    if (!Array.isArray(entries)) throw new Error('release notes must be an array');
    releases.push(...entries);
    if (entries.length < 100 || entries.some((entry) => /^v?\d+\.\d+\.\d+$/.test(entry.tag_name) && compare(entry.tag_name.replace(/^v/, ''), options.from) <= 0)) return releases;
  }
  throw new Error('release notes pagination limit reached');
}
function paths(ref, path) { return git('ls-tree', '-r', '--name-only', ref, '--', path).split('\n').filter(Boolean); }
function tools(ref) {
  const names = [];
  for (const file of paths(ref, 'packages/server/src/mcp').filter((file) => file.endsWith('.ts') && !/\.(test|test-helper|uncached\.test)\.ts$/.test(file))) {
    const text = git('show', `${ref}:${file}`);
    names.push(...[...text.matchAll(/\.registerTool\(\s*['"]([^'"]+)['"]/g)].map((match) => match[1]));
  }
  if (!names.length) throw new Error('MCP tool names cannot be read statically');
  return [...new Set(names)].sort();
}
async function notes() {
  version(options.from); version(options.to);
  if (compare(options.from, options.to) >= 0) throw new Error('--to must be newer than --from');
  prepareWorkdir();
  result = { action, from: options.from, to: options.to, local_dev: run('git', ['rev-parse', '--verify', 'refs/heads/local-dev^{commit}'], source), steps: [] };
  const cloned = await clone();
  const fetched = await fetchUpstream(cloned);
  if (!fetched) throw new Error('cannot fetch upstream for notes');
  const from = releaseCommit(options.from), to = releaseCommit(options.to);
  const entries = (await releaseNotes()).filter((entry) => !entry.draft && !entry.prerelease && /^v?\d+\.\d+\.\d+$/.test(entry.tag_name)).map((entry) => ({ version: entry.tag_name.replace(/^v/, ''), text: entry.body || '' })).filter((entry) => compare(entry.version, options.from) > 0 && compare(entry.version, options.to) <= 0).sort((a, b) => compare(b.version, a.version));
  if (!entries.some((entry) => entry.version === options.to)) throw new Error('target release notes are missing');
  const breaking = [], remaining = [];
  for (const entry of entries) {
    let breakingDepth = 0;
    for (const text of entry.text.split(/\n(?=[-*] |#{1,6} )|\n\n+/).filter((block) => block.trim())) {
      const heading = text.match(/^(#{1,6}) /);
      const notice = text.replace(/\b(?:no|without) breaking changes?\b|\bnon[- ]breaking\b/gi, '');
      const explicit = /\bbreaking\b|\bbackward.incompatible\b|\bmajor changes\b/i.test(notice);
      if (heading && heading[1].length <= breakingDepth) breakingDepth = 0;
      if (heading && explicit) breakingDepth = heading[1].length;
      (explicit || breakingDepth ? breaking : remaining).push({ version: entry.version, text });
    }
  }
  const changed = (path) => git('diff', '--name-only', from, to, '--', path).split('\n').filter(Boolean);
  const oldManager = JSON.parse(git('show', `${from}:package.json`)).packageManager;
  const newManager = JSON.parse(git('show', `${to}:package.json`)).packageManager;
  const oldWorkflows = paths(from, '.github/workflows');
  const oldTools = tools(from), newTools = tools(to);
  result = { ...result, from_commit: from, to_commit: to, breaking: breaking.length > 0, breaking_changes: breaking, releases: entries,
    text: [...breaking, ...remaining].map((entry) => `## ${entry.version}\n${entry.text}`).join('\n\n'),
    drift: { packageManager: { from: oldManager, to: newManager, changed: oldManager !== newManager },
      workspace: changed('pnpm-workspace.yaml'), patches: changed('patches'),
      new_workflows: paths(to, '.github/workflows').filter((file) => !oldWorkflows.includes(file)),
      new_husky: paths(from, '.husky').length === 0 && paths(to, '.husky').length > 0,
      mcp_tools: { from: oldTools, to: newTools, changed: JSON.stringify(oldTools) !== JSON.stringify(newTools) } } };
}
async function cleanup() {
  if (action === 'detect') { if (runDirectory) rmSync(runDirectory, { recursive: true, force: true }); return; }
  if (!runDirectory) return;
  await step('cleanup', async (execute, log) => {
    let failed = 0;
    const remove = async (args) => {
      const start = readFileSync(log, 'utf8').length;
      const code = await execute(docker, args, runDirectory);
      if (code === 0) return true;
      return /No such (container|image|object)/i.test(readFileSync(log, 'utf8').slice(start));
    };
    if (ledger) {
      const names = [...new Set(readFileSync(ledger, 'utf8').split('\n').filter(Boolean))];
      for (const name of names) {
        if (!name.startsWith(`${prefix}-`)) { failed = 1; continue; }
        if (!await remove(['rm', '--force', '--volumes', name])) failed = 1;
      }
    }
    if (imageAttempted && !await remove(['image', 'rm', image])) failed = 1;
    if (baseImageAttempted && !await remove(['image', 'rm', baseImage])) failed = 1;
    for (const name of ['repo', 'layers', 'image-content', 'image.tar', 'base-image', 'tmp', 'home', 'docker', 'npm-cache', 'bin', 'npm-user', 'npm-global', 'containers']) rmSync(join(runDirectory, name), { recursive: true, force: true });
    return failed;
  });
}
let exitCode = 0;
const started = Date.now();
try {
  for (let i = 3; i < process.argv.length; i += 2) {
    const key = process.argv[i];
    if (!['--version', '--workdir', '--bundle', '--from', '--to'].includes(key) || process.argv[i + 1] === undefined || options[key.slice(2)] !== undefined) throw new Error('invalid command options');
    options[key.slice(2)] = process.argv[i + 1];
  }
  const allowed = { detect: [], qualify: ['version', 'workdir', 'bundle'], notes: ['from', 'to', 'workdir'] }[action];
  if (!allowed || Object.keys(options).some((key) => !allowed.includes(key))) throw new Error('usage: update.sh detect | qualify --version X.Y.Z --workdir DIR [--bundle FILE] | notes --from X.Y.Z --to X.Y.Z --workdir DIR');
  if (action === 'detect') await detect();
  if (action === 'qualify') await qualify();
  if (action === 'notes') await notes();
} catch (error) {
  result.error = error.message;
  exitCode = action === 'qualify' ? 1 : 2;
} finally {
  try { await cleanup(); } catch (error) { result.cleanup_error = error.message; exitCode = action === 'qualify' ? 1 : 2; }
}
if (result.steps?.some((record) => record.status !== 'passed')) exitCode = action === 'qualify' ? 1 : 2;
if (action === 'detect' && !exitCode && result.behind) exitCode = 10;
result.duration_ms = Date.now() - started;
result.exit_code = exitCode;
result.ok = exitCode === 0;
if (runDirectory && action !== 'detect' && existsSync(runDirectory)) writeFileSync(join(runDirectory, 'result.json'), `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(result)}\n`);
process.exitCode = exitCode;
