import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dockerfile = readFileSync(join(root, 'deploy/Dockerfile'), 'utf8');
const current = dockerfile.match(/^ARG OK_VERSION=(.+)$/m)[1];
const baseImage = dockerfile.match(/^ARG NODE_IMAGE=(.+)$/m)[1];
const scanner = readFileSync(join(root, 'scripts/tenant/scan.sh'), 'utf8').match(/^default_image=(.+)$/m)[1];
const next = '99.0.0';
const identity = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.com', GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.com' };
function git(cwd, ...args) {
  const output = spawnSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], { cwd, env: identity, encoding: 'utf8' });
  assert.equal(output.status, 0, output.stderr);
  return output.stdout.trim();
}
function fixture(context, scenario = '') {
  const tmp = mkdtempSync(join(tmpdir(), 'ok-update-test-'));
  context.after(() => rmSync(tmp, { recursive: true, force: true }));
  const repo = join(tmp, 'repo'), bin = join(tmp, 'bin'), work = join(tmp, 'work');
  mkdirSync(join(repo, 'scripts/tenant'), { recursive: true });
  mkdirSync(bin);
  for (const name of ['update.sh', 'update.mjs', 'update-ci.mjs', 'update-docker.mjs', 'build.sh', 'scan.sh', 'smoke.sh', 'pins.sh', 'install-hooks.sh', 'public-check.sh', 'public-check.development', 'public-check.rules', 'public-check.allow']) cpSync(join(root, 'scripts/tenant', name), join(repo, 'scripts/tenant', name));
  for (const name of ['deploy', 'EXPLAINER.md', '.gitleaks.toml']) cpSync(join(root, name), join(repo, name), { recursive: true });
  mkdirSync(join(repo, 'packages/cli'), { recursive: true });
  mkdirSync(join(repo, 'packages/server/src/mcp/tools'), { recursive: true });
  writeFileSync(join(repo, 'packages/cli/package.json'), JSON.stringify({ version: current }));
  writeFileSync(join(repo, 'package.json'), JSON.stringify({ packageManager: JSON.parse(readFileSync(join(root, 'package.json'))).packageManager }, null, 2) + '\n');
  writeFileSync(join(repo, 'pnpm-workspace.yaml'), 'packages: []\n');
  writeFileSync(join(repo, 'packages/server/src/mcp/tools/read.ts'), "server.registerTool('read', {});\n");
  writeFileSync(join(repo, 'shared'), 'base\n');
  git(repo, 'init', '-q', '-b', 'main'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', `main reset: post-stable v${current}`);
  const base = git(repo, 'rev-parse', 'HEAD');
  git(repo, 'switch', '-c', 'local-dev');
  writeFileSync(join(repo, 'fork-file'), 'fork\n');
  if (scenario === 'conflict') writeFileSync(join(repo, 'shared'), 'fork edit\n');
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'fork');
  const fork = git(repo, 'rev-parse', 'HEAD');
  git(repo, 'switch', 'main');
  writeFileSync(join(repo, 'packages/cli/package.json'), JSON.stringify({ version: next }));
  writeFileSync(join(repo, 'package.json'), JSON.stringify({ packageManager: 'pnpm@99.0.0' }, null, 2) + '\n');
  writeFileSync(join(repo, 'pnpm-workspace.yaml'), 'packages: [packages/*]\n');
  mkdirSync(join(repo, 'patches')); writeFileSync(join(repo, 'patches/new.patch'), 'new\n');
  mkdirSync(join(repo, '.github/workflows'), { recursive: true }); writeFileSync(join(repo, '.github/workflows/new.yml'), 'name: new\n');
  mkdirSync(join(repo, '.husky')); writeFileSync(join(repo, '.husky/pre-commit'), 'exit 0\n');
  writeFileSync(join(repo, 'packages/server/src/mcp/tools/write.ts'), "server.registerTool('write', {});\n");
  if (scenario === 'conflict') writeFileSync(join(repo, 'shared'), 'upstream edit\n');
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', `main reset: post-stable v${next}`);
  const release = git(repo, 'rev-parse', 'HEAD');
  writeFileSync(join(repo, 'unreleased'), 'not part of the release\n');
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'unreleased change');
  const bare = join(tmp, 'upstream.git');
  git(tmp, 'clone', '--bare', '--no-local', repo, bare);
  git(repo, 'remote', 'add', 'upstream', bare);
  git(repo, 'remote', 'set-url', '--push', 'upstream', 'DISABLED');
  git(repo, 'switch', 'local-dev');
  const config = { current, next, baseImage, scanner, scenario, latest: current };
  writeFileSync(join(bin, 'config.json'), JSON.stringify(config));
  const fake = `#!${process.execPath}
import {readFileSync,writeFileSync,appendFileSync,mkdirSync,rmSync,readdirSync} from 'node:fs';
import {dirname,join,basename} from 'node:path';
import {spawnSync} from 'node:child_process';
const dir=dirname(process.argv[1]);
const config=JSON.parse(readFileSync(join(dir,'config.json')));
const args=process.argv.slice(2), kind=basename(process.argv[1]);
const transport=Object.fromEntries(['DOCKER_HOST','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy'].map(name=>[name,process.env[name]]));
appendFileSync(join(dir,'calls.jsonl'),JSON.stringify({kind,args,cwd:process.cwd(),home:process.env.HOME,token:process.env.GITEA_TOKEN,marker:process.env.OK_REGISTRY_TOKEN,transport})+'\\n');
if(kind==='npm') { console.log(JSON.stringify(args[2]==='versions'?[config.latest,config.next+'-beta.1']: 'sha512-'+Buffer.alloc(64,1).toString('base64'))); }
else if(kind==='digest') {console.log(args[0]===config.baseImage.split('@')[0]?config.baseImage.split('@')[1]:config.scanner.split('@')[1]);}
else if(kind==='releases') {console.log(JSON.stringify([{tag_name:'v'+config.next,body:'### Fixes\\n\\n- A normal fix.\\n\\n### Breaking Changes\\n\\n- Replace the old setting.\\n\\n### Improvements\\n\\n- A new option.'}]));}
else if(kind==='ss') { console.log('State Recv-Q Send-Q Local Address:Port Peer Address:Port\\nLISTEN 0 4096 127.0.0.1:18127 0.0.0.0:*'+(config.scenario==='port'?'\\nLISTEN 0 4096 [::]:18080 [::]:*':'')); }
else if(kind==='docker') {
 if(args[0]==='build') {process.exit(config.scenario==='build'?7:0);}
 if(config.scenario==='cleanup' && args[0]==='image' && args[1]==='rm') {console.error('Docker daemon is unavailable');process.exit(1);}
 if(args[0]==='run' && args.includes('--version') && args.includes('ok')) {console.log(config.next+'\\nCopyright (C) Example');}
 else if(args[0]==='run' && (args.includes('dir')||args.includes('--staged')||args.includes('--history')||args.includes('--log-opts'))) {
  const content=args.find(arg=>arg.includes('/image-content/')&&arg.endsWith(':/work:ro'))?.slice(0,-9);
  const finding=content&&readdirSync(content).some(layer=>readFileSync(join(content,layer,'file'),'utf8')==='finding');
  if(config.scenario==='finding' && !args.includes('--tmpfs') && !args.includes('--staged') || finding) {console.log('RuleID: new-rule\\nFile: new-fixture\\nStartLine: 1\\nINF leaks found: 1');process.exit(1);}
  if(content&&config.scenario==='base-scan-error'&&content.endsWith('/base')) {console.log('ERR failed scan');process.exit(2);}
  console.log('INF no leaks found');
 }
 else if(args[0]==='inspect') {if(args.includes('--format')) console.log('running');else process.exit(1);}
 else if(args[0]==='port') console.log('127.0.0.1:18080');
 else if(args[0]==='image' && args[1]==='inspect') {
  const layers=['a','b','c','d'].map(value=>'sha256:'+value.repeat(64));
  if(args.at(-1).endsWith(':base')) console.log(JSON.stringify(layers.slice(0,2)));
  else console.log(JSON.stringify(config.scenario==='wrong-base'?layers.toReversed():layers));
 }
 else if(args[0]==='image' && args[1]==='save') {
  const out=args[args.indexOf('--output')+1], temp=out+'.content'; mkdirSync(temp);
  const layers=[];
  for(let index=0;index<4;index++) {
   const layer=join(temp,'layer');mkdirSync(layer);
   writeFileSync(join(layer,'file'),config.scenario==='image-base'&&index===1||config.scenario==='image-added'&&index===3?'finding':'clean');
   const archive='layer-'+index+'.tar';layers.push(archive);
   const packed=spawnSync('tar',['-cf',join(temp,archive),'-C',layer,'.']);if(packed.status)process.exit(packed.status);
   rmSync(layer,{recursive:true});
  }
  writeFileSync(join(temp,'manifest.json'),JSON.stringify([{Layers:layers}]));
  const saved=spawnSync('tar',['-cf',out,'-C',temp,'.']);rmSync(temp,{recursive:true});process.exit(saved.status);
 }
}
`;
  for (const name of ['npm', 'digest', 'docker', 'ss', 'releases']) { writeFileSync(join(bin, name), fake); chmodSync(join(bin, name), 0o755); }
  const transport = Object.fromEntries(['DOCKER_HOST', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'].map((name) => [name, name === 'DOCKER_HOST' ? 'unix:///fixture/docker.sock' : name.toLowerCase().includes('no_proxy') ? 'localhost,127.0.0.1' : 'http://127.0.0.1:9']));
  const environment = { ...process.env, ...transport, GITEA_TOKEN: 'test-not-a-credential', OK_REGISTRY_TOKEN: 'test-not-a-credential', OK_UPDATE_NPM_COMMAND: join(bin, 'npm'), OK_UPDATE_DIGEST_COMMAND: join(bin, 'digest'), OK_UPDATE_DOCKER_COMMAND: join(bin, 'docker'), OK_UPDATE_SS_COMMAND: join(bin, 'ss'), OK_UPDATE_RELEASES_COMMAND: join(bin, 'releases'), SMOKE_PORT: '18080' };
  function call(action, args = []) {
    const output = spawnSync('sh', [join(repo, 'scripts/tenant/update.sh'), action, ...args], { env: environment, encoding: 'utf8', timeout: 60000 });
    assert.equal(output.error, undefined);
    assert.equal(output.stdout.trim().split('\n').length, 1, output.stdout + output.stderr);
    const result = JSON.parse(output.stdout);
    assert.equal(result.exit_code, output.status);
    assert.equal(git(repo, 'rev-parse', 'local-dev'), fork);
    assert.equal(git(repo, 'status', '--porcelain'), '');
    assert.equal(git(repo, 'config', '--get', 'remote.upstream.pushurl'), 'DISABLED');
    const calls = existsSync(join(bin, 'calls.jsonl')) ? readFileSync(join(bin, 'calls.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
    for (const call of calls) {
      assert.equal(call.token, undefined); assert.equal(call.marker, undefined);
      assert.deepEqual(call.transport, transport);
      assert.equal(call.args.includes('compose'), false); assert.equal(call.args.includes('push'), false);
      if (call.kind === 'docker' && ['run', 'create'].includes(call.args[0])) {
        assert.ok(call.args.includes('--rm'));
        assert.match(call.args[call.args.indexOf('--name') + 1], /^ok-update-/);
      }
    }
    if (action !== 'detect' && result.steps.length) {
      for (const record of result.steps) { assert.ok(existsSync(record.log_path)); assert.ok(Number.isInteger(record.exit_code) || record.status === 'skipped'); }
      const directory = dirname(result.steps[0].log_path);
      assert.equal(existsSync(join(directory, 'repo')), false);
      for (const name of ['layers', 'image-content', 'image.tar', 'base-image']) assert.equal(existsSync(join(directory, name)), false);
      assert.ok(existsSync(join(directory, 'result.json')));
    }
    return { result, code: output.status, calls };
  }
  return { call, config, bin, work, release, base, repo, environment };
}
function tracker(context, pulls) {
  const requests = [];
  const instance = createServer((request, response) => {
    let body = '';
    request.on('data', (chunk) => { body += chunk; });
    request.on('end', () => {
      requests.push({ method: request.method, url: request.url, authorization: request.headers.authorization, body: body && JSON.parse(body) });
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify(request.method === 'POST' ? { number: 7 } : pulls));
    });
  });
  context.after(() => instance.close());
  return new Promise((done) => { instance.listen(0, '127.0.0.1', () => done({ requests, url: `http://127.0.0.1:${instance.address().port}/api/v1` })); });
}
function glue(f, args, env) {
  return new Promise((done) => {
    const held = spawn(process.execPath, [join(f.repo, 'scripts/tenant/update-ci.mjs'), ...args], { env: { ...f.environment, ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
    let text = '';
    held.stdout.on('data', (chunk) => { text += chunk; });
    held.stderr.on('data', (chunk) => { text += chunk; });
    held.on('close', (code) => done({ code, text }));
  });
}

test('detect: no update, newest stable, changed base digest, and registry error', (context) => {
  const f = fixture(context);
  assert.equal(f.call('detect').code, 0);
  f.config.latest = next; writeFileSync(join(f.bin, 'config.json'), JSON.stringify(f.config));
  const updated = f.call('detect');
  assert.equal(updated.code, 10); assert.equal(updated.result.new_version, next);
  f.config.latest = current; f.config.baseImage = baseImage.split('@')[0] + '@sha256:' + 'a'.repeat(64);
  writeFileSync(join(f.bin, 'config.json'), JSON.stringify(f.config));
  assert.equal(f.call('detect').code, 10);
  f.config.baseImage = baseImage; f.config.scanner = scanner.split('@')[0] + '@sha256:' + 'b'.repeat(64);
  writeFileSync(join(f.bin, 'config.json'), JSON.stringify(f.config));
  assert.equal(f.call('detect').code, 10);
  writeFileSync(join(f.bin, 'npm'), '#!/bin/sh\nexit 9\n');
  assert.equal(f.call('detect').code, 2);
});
test('qualify: passing run selects the post-stable commit, not the latest main', (context) => {
  const f = fixture(context);
  const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work]);
  assert.equal(code, 0, JSON.stringify(result)); assert.equal(result.upstream_commit, f.release);
  assert.equal(result.branch, `sync/v${next}`);
  assert.ok(result.steps.every((record) => record.status === 'passed'));
  assert.equal(result.bundle, undefined);
});
test('qualify: a bundle carries the tested branch only after a passing run', (context) => {
  const f = fixture(context);
  const bundle = join(dirname(f.work), 'sync.bundle');
  const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work, '--bundle', bundle]);
  assert.equal(code, 0, JSON.stringify(result)); assert.equal(result.bundle, bundle);
  const heads = spawnSync('git', ['bundle', 'list-heads', bundle], { cwd: dirname(f.work), encoding: 'utf8' });
  assert.equal(heads.status, 0, heads.stderr);
  assert.match(heads.stdout, new RegExp(`^[a-f0-9]{40} refs/heads/sync/v${next.replaceAll('.', '\\.')}\n$`));
  assert.equal(f.call('qualify', ['--version', next, '--workdir', f.work, '--bundle', bundle]).code, 1);
  const failing = fixture(context, 'build');
  const refused = join(dirname(failing.work), 'sync.bundle');
  const failed = failing.call('qualify', ['--version', next, '--workdir', failing.work, '--bundle', refused]);
  assert.equal(failed.code, 1); assert.equal(existsSync(refused), false);
  assert.equal(failed.result.steps.find((record) => record.name === 'bundle').status, 'skipped');
});
test('qualify: findings in added image layers fail, but base findings are notes', (context) => {
  const added = fixture(context, 'image-added');
  const failed = added.call('qualify', ['--version', next, '--workdir', added.work]);
  const addedScan = failed.result.steps.find((step) => step.name === 'scan-image');
  assert.equal(failed.code, 1); assert.equal(addedScan.exit_code, 1);
  assert.ok(addedScan.findings.includes('RuleID: new-rule'));
  assert.match(readFileSync(addedScan.log_path, 'utf8'), /^RuleID: new-rule$/m);
  const base = fixture(context, 'image-base');
  const passed = base.call('qualify', ['--version', next, '--workdir', base.work]);
  const baseScan = passed.result.steps.find((step) => step.name === 'scan-image');
  assert.equal(passed.code, 0, JSON.stringify(passed.result)); assert.equal(baseScan.exit_code, 0);
  assert.equal(baseScan.findings, undefined);
  assert.match(readFileSync(baseScan.log_path, 'utf8'), /^note: RuleID: new-rule$/m);
  const inspected = passed.calls.filter((call) => call.kind === 'docker' && call.args[0] === 'image' && call.args[1] === 'inspect');
  assert.equal(inspected.length, 2);
  const baseline = inspected[0].args.at(-1);
  assert.ok(baseline.endsWith(':base'));
  assert.ok(passed.calls.some((call) => call.kind === 'docker' && call.args.join(' ') === `image rm ${baseline}`));
});
test('qualify: a mismatched image baseline or base scanner error fails closed', (context) => {
  for (const scenario of ['wrong-base', 'base-scan-error']) {
    const f = fixture(context, scenario);
    const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work]);
    assert.equal(code, 1);
    assert.equal(result.steps.find((step) => step.name === 'scan-image').exit_code, 2);
    assert.equal(result.steps.find((step) => step.name === 'cleanup').exit_code, 0);
  }
});
test('qualify: merge conflict stops dependent steps without resolving it', (context) => {
  const f = fixture(context, 'conflict');
  const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work]);
  assert.equal(code, 1); assert.equal(result.steps.find((step) => step.name === 'merge').exit_code, 1);
  assert.equal(result.steps.find((step) => step.name === 'build').status, 'skipped');
  assert.equal(result.steps.find((step) => step.name === 'port-check').status, 'passed');
});
test('qualify: failed build records its code and skips image tests', (context) => {
  const f = fixture(context, 'build');
  const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work]);
  assert.equal(code, 1); assert.equal(result.steps.find((step) => step.name === 'build').exit_code, 7);
  assert.equal(result.steps.find((step) => step.name === 'smoke').status, 'skipped');
});
test('qualify: a new finding fails and is listed; independent build still runs', (context) => {
  const f = fixture(context, 'finding');
  const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work]);
  assert.equal(code, 1);
  const scan = result.steps.find((step) => step.name === 'scan-tree');
  assert.equal(scan.exit_code, 1); assert.ok(scan.findings.includes('RuleID: new-rule'));
  assert.equal(result.steps.find((step) => step.name === 'build').exit_code, 0);
  assert.equal(result.steps.find((step) => step.name === 'scan-image').exit_code, 1);
});
test('qualify: occupied test port prevents smoke, but image version still runs', (context) => {
  const f = fixture(context, 'port');
  const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work]);
  assert.equal(code, 1); assert.equal(result.steps.find((step) => step.name === 'port-check').status, 'failed');
  assert.equal(result.steps.find((step) => step.name === 'smoke').status, 'skipped');
  assert.equal(result.steps.find((step) => step.name === 'image-version').exit_code, 0);
});
test('notes: breaking sections come first and every kit input drift is listed', (context) => {
  const f = fixture(context);
  const { result, code } = f.call('notes', ['--from', current, '--to', next, '--workdir', f.work]);
  assert.equal(code, 0, JSON.stringify(result)); assert.equal(result.breaking, true);
  assert.ok(result.text.indexOf('Replace the old setting') < result.text.indexOf('A normal fix'));
  assert.equal(result.drift.packageManager.changed, true);
  assert.deepEqual(result.drift.workspace, ['pnpm-workspace.yaml']);
  assert.deepEqual(result.drift.patches, ['patches/new.patch']);
  assert.deepEqual(result.drift.new_workflows, ['.github/workflows/new.yml']);
  assert.equal(result.drift.new_husky, true); assert.equal(result.drift.mcp_tools.changed, true);
  assert.deepEqual(result.drift.mcp_tools.to, ['read', 'write']);
  writeFileSync(join(f.bin, 'releases'), `#!/bin/sh\nprintf '%s\\n' '[{"tag_name":"v${next}","body":"- A non-breaking improvement. No breaking changes."}]'\n`);
  const compatible = f.call('notes', ['--from', current, '--to', next, '--workdir', f.work]);
  assert.equal(compatible.code, 0); assert.equal(compatible.result.breaking, false);
});
test('notes: Minor Changes and Major Changes sections count as breaking and come first', (context) => {
  const f = fixture(context);
  for (const section of ['Minor Changes', 'Major Changes']) {
    const body = `### Patch Changes\n\n- A normal fix.\n\n### ${section}\n\n- Replace the old setting.\n\n### Improvements\n\n- A new option.`;
    writeFileSync(join(f.bin, 'releases'), `#!${process.execPath}\nconsole.log(${JSON.stringify(JSON.stringify([{ tag_name: `v${next}`, body }]))});\n`);
    const { result, code } = f.call('notes', ['--from', current, '--to', next, '--workdir', f.work]);
    assert.equal(code, 0); assert.equal(result.breaking, true);
    assert.match(result.breaking_changes[0].text, new RegExp(section));
    assert.ok(result.breaking_changes.some((entry) => entry.text.includes('Replace the old setting')));
    assert.ok(result.text.indexOf(section) < result.text.indexOf('A normal fix'));
    assert.ok(result.text.indexOf('Replace the old setting') < result.text.indexOf('A new option'));
  }
});
test('missing Node prints one JSON error object with exit 2', (context) => {
  const empty = mkdtempSync(join(tmpdir(), 'ok-update-path-'));
  context.after(() => rmSync(empty, { recursive: true, force: true }));
  const output = spawnSync('/bin/sh', [join(root, 'scripts/tenant/update.sh'), 'detect'], { env: { PATH: empty }, encoding: 'utf8' });
  assert.equal(output.status, 2); assert.equal(output.stderr, '');
  assert.equal(output.stdout.trim().split('\n').length, 1);
  assert.deepEqual(JSON.parse(output.stdout), { error: 'missing command: node', exit_code: 2, ok: false });
});
test('symlink workdir ancestors are rejected before directories are created', (context) => {
  const f = fixture(context);
  const outside = join(f.bin, 'outside'), alias = join(f.bin, 'alias');
  mkdirSync(outside);
  symlinkSync(outside, alias);
  const rejected = f.call('qualify', ['--version', next, '--workdir', join(alias, 'nested')]);
  assert.equal(rejected.code, 1);
  assert.match(rejected.result.error, /symlink/);
  assert.equal(existsSync(join(outside, 'nested')), false);
});
test('cleanup failure fails the run and does not claim success', (context) => {
  const f = fixture(context, 'cleanup');
  const { result, code } = f.call('qualify', ['--version', next, '--workdir', f.work]);
  assert.equal(code, 1);
  assert.equal(result.steps.find((step) => step.name === 'cleanup').status, 'failed');
});
test('invalid qualification and missing release fail without a build', (context) => {
  const f = fixture(context);
  assert.equal(f.call('qualify', ['--version', '../invalid', '--workdir', f.work]).code, 1);
  const missing = f.call('qualify', ['--version', '98.0.0', '--workdir', f.work]);
  assert.equal(missing.code, 1);
  assert.equal(missing.result.steps.find((step) => step.name === 'select-release').status, 'failed');
  assert.equal(missing.result.steps.find((step) => step.name === 'build').status, 'skipped');
});
test('workflow glue: detect selects a new version once, and the pull request carries the tested branch', async (context) => {
  const f = fixture(context);
  const tmp = dirname(f.work), branch = `sync/v${next}`, token = 'test-not-a-credential-2';
  const open = [{ number: 3, head: { ref: branch }, base: { ref: 'local-dev' } }];
  const none = await tracker(context, []), taken = await tracker(context, open);
  const settings = (api, remote) => ({ OK_API_URL: api.url, OK_REPOSITORY: 'team/kit', OK_TOKEN: token, OK_SERVER_URL: `file://${join(tmp, remote)}`, GITHUB_OUTPUT: join(tmp, 'output') });
  const outputs = () => { const text = readFileSync(join(tmp, 'output'), 'utf8'); rmSync(join(tmp, 'output')); return text; };
  assert.equal((await glue(f, ['detect'], settings(none, 'a'))).code, 0);
  assert.equal(outputs(), `qualify=false\nversion=\ncurrent=${current}\n`);
  assert.equal(none.requests.length, 0);
  f.config.latest = next; writeFileSync(join(f.bin, 'config.json'), JSON.stringify(f.config));
  assert.equal((await glue(f, ['detect'], settings(none, 'a'))).code, 0);
  assert.equal(outputs(), `qualify=true\nversion=${next}\ncurrent=${current}\n`);
  assert.equal(none.requests[0].authorization, `token ${token}`);
  const skipped = await glue(f, ['detect'], settings(taken, 'a'));
  assert.equal(skipped.code, 0); assert.equal(outputs(), `qualify=false\nversion=${next}\ncurrent=${current}\n`);
  writeFileSync(join(f.bin, 'npm'), '#!/bin/sh\nexit 9\n');
  assert.equal((await glue(f, ['detect'], settings(none, 'a'))).code, 2);
  for (const name of ['a', 'b', 'c']) git(tmp, 'init', '-q', '--bare', join(name, 'team/kit.git'));
  const passing = fixture(context);
  const bundle = join(dirname(passing.work), 'sync.bundle');
  const qualified = passing.call('qualify', ['--version', next, '--workdir', passing.work, '--bundle', bundle]).result;
  const notes = passing.call('notes', ['--from', current, '--to', next, '--workdir', passing.work]).result;
  const result = join(tmp, 'qualify.json'), notesFile = join(tmp, 'notes.json'), failed = join(tmp, 'failed.json');
  writeFileSync(result, JSON.stringify(qualified)); writeFileSync(notesFile, JSON.stringify(notes));
  writeFileSync(failed, JSON.stringify({ ...qualified, ok: false }));
  const heads = (name) => git(join(tmp, name, 'team/kit.git'), 'for-each-ref', '--format=%(objectname) %(refname)');
  none.requests.length = 0;
  const refused = await glue(passing, ['pull-request', '--result', failed, '--notes', notesFile, '--bundle', bundle], settings(none, 'a'));
  assert.equal(refused.code, 2); assert.equal(heads('a'), ''); assert.equal(none.requests.length, 0);
  const existing = await glue(passing, ['pull-request', '--result', result, '--notes', notesFile, '--bundle', bundle], settings(taken, 'b'));
  assert.equal(existing.code, 0, existing.text); assert.equal(heads('b'), '');
  assert.equal(taken.requests.some((request) => request.method === 'POST'), false);
  const opened = await glue(passing, ['pull-request', '--result', result, '--notes', notesFile, '--bundle', bundle], settings(none, 'c'));
  assert.equal(opened.code, 0, opened.text); assert.equal(opened.text.includes(token), false);
  const tip = spawnSync('git', ['bundle', 'list-heads', bundle], { cwd: tmp, encoding: 'utf8' }).stdout.split(' ')[0];
  assert.equal(heads('c'), `${tip} refs/heads/${branch}`);
  const posts = none.requests.filter((request) => request.method === 'POST');
  assert.equal(posts.length, 1); assert.equal(posts[0].url, '/api/v1/repos/team/kit/pulls');
  assert.equal(posts[0].body.base, 'local-dev'); assert.equal(posts[0].body.head, branch);
  assert.equal(posts[0].body.title, `[BREAKING] Upstream sync v${next}`);
  assert.match(posts[0].body.body, /^\*\*BREAKING CHANGE/); assert.match(posts[0].body.body, /Replace the old setting/);
});
