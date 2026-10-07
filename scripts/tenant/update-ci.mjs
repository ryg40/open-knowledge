import { spawnSync } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const kit = dirname(fileURLToPath(import.meta.url));
const source = resolve(kit, '../..');
const base = 'local-dev';
const action = process.argv[2];

function setting(name) {
  const value = process.env[name];
  if (!value) throw new Error(`missing environment variable: ${name}`);
  return value;
}
function branchOf(release) {
  if (!/^\d+\.\d+\.\d+$/.test(release || '')) throw new Error('expected a stable X.Y.Z version');
  return `sync/v${release}`;
}
function output(values) {
  const text = Object.entries(values).map(([key, value]) => `${key}=${value}\n`).join('');
  process.stdout.write(text);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, text);
}
async function api(method, path, body) {
  const response = await fetch(`${setting('OK_API_URL').replace(/\/+$/, '')}/repos/${setting('OK_REPOSITORY')}${path}`, {
    method, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000),
    headers: { accept: 'application/json', 'content-type': 'application/json', authorization: `token ${setting('OK_TOKEN')}` },
  });
  if (!response.ok) throw new Error(`request failed: ${method} ${path.split('?')[0]} HTTP ${response.status}`);
  return response.json();
}
async function openPullRequest(branch) {
  for (let page = 1; page <= 100; page++) {
    const entries = await api('GET', `/pulls?state=open&limit=50&per_page=50&page=${page}`);
    if (!Array.isArray(entries)) throw new Error('pull request list must be an array');
    const found = entries.find((entry) => entry.head?.ref === branch && entry.base?.ref === base);
    if (found) return found;
    if (entries.length < 50) return undefined;
  }
  throw new Error('pull request pagination limit reached');
}
function git(args, env = process.env) {
  const result = spawnSync('git', args, { cwd: source, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`command failed: git ${args[0]} (exit ${result.status ?? 2})\n${result.stderr || result.error?.message || ''}`);
  return result.stdout.trim();
}
async function detect() {
  const run = spawnSync('sh', [join(kit, 'update.sh'), 'detect'], { cwd: source, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
  process.stdout.write(run.stdout || '');
  if (![0, 10].includes(run.status)) throw new Error(`detect failed with exit ${run.status ?? 2}`);
  const result = JSON.parse(run.stdout);
  const pin = result.pins.find((record) => record.name === 'OK_VERSION');
  for (const record of result.pins) if (record.behind && record.name !== 'OK_VERSION') process.stdout.write(`::warning::the pin ${record.name} is behind: ${record.latest}\n`);
  if (!pin?.behind) {
    output({ qualify: 'false', version: '', current: pin?.current ?? '' });
    return;
  }
  const branch = branchOf(pin.latest);
  const existing = await openPullRequest(branch);
  if (existing) process.stdout.write(`::notice::an open pull request for ${branch} exists: number ${existing.number}\n`);
  output({ qualify: existing ? 'false' : 'true', version: pin.latest, current: pin.current });
}
function option(name) {
  const index = process.argv.indexOf(name, 3);
  if (index < 0 || process.argv[index + 1] === undefined) throw new Error(`missing option: ${name}`);
  return process.argv[index + 1];
}
async function pullRequest() {
  const qualified = JSON.parse(readFileSync(option('--result'), 'utf8'));
  const notes = JSON.parse(readFileSync(option('--notes'), 'utf8'));
  const bundle = resolve(option('--bundle'));
  const branch = branchOf(qualified.version);
  if (qualified.action !== 'qualify' || qualified.ok !== true || qualified.branch !== branch) throw new Error('the qualification did not pass');
  if (notes.action !== 'notes' || notes.ok !== true || notes.to !== qualified.version || typeof notes.breaking !== 'boolean') throw new Error('the notes do not belong to the qualified version');
  const existing = await openPullRequest(branch);
  if (existing) {
    process.stdout.write(`an open pull request for ${branch} exists: number ${existing.number}\n`);
    return;
  }
  git(['bundle', 'verify', bundle]);
  git(['fetch', '--no-tags', bundle, `+refs/heads/${branch}:refs/remotes/update/${branch}`]);
  const tip = git(['rev-parse', '--verify', `refs/remotes/update/${branch}^{commit}`]);
  git(['merge-base', '--is-ancestor', qualified.local_dev, tip]);
  git(['merge-base', '--is-ancestor', qualified.upstream_commit, tip]);
  const url = `${setting('OK_SERVER_URL').replace(/\/+$/, '')}/${setting('OK_REPOSITORY')}.git`;
  const credential = Buffer.from(`x-access-token:${setting('OK_TOKEN')}`).toString('base64');
  git(['push', '--force', url, `${tip}:refs/heads/${branch}`], { ...process.env, GIT_TERMINAL_PROMPT: '0',
    GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: `http.${url}.extraheader`, GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${credential}` });
  const drift = JSON.stringify(notes.drift ?? {}, null, 2);
  const text = String(notes.text ?? '');
  const body = [
    notes.breaking ? '**BREAKING CHANGE: read the first sections before the merge.**' : 'No breaking change is marked in the release notes.',
    `Upstream version ${notes.from} to ${notes.to}. Upstream commit \`${qualified.upstream_commit}\`. The qualification passed on \`${base}\` at \`${qualified.local_dev}\`.`,
    '## Release notes', text.length > 50000 ? `${text.slice(0, 50000)}\n\n(The notes are cut at 50000 characters.)` : text,
    '## Changed kit inputs', `\`\`\`json\n${drift}\n\`\`\``,
  ].join('\n\n');
  const created = await api('POST', '/pulls', { base, head: branch, title: `${notes.breaking ? '[BREAKING] ' : ''}Upstream sync v${qualified.version}`, body });
  process.stdout.write(`pull request number ${created.number} is open for ${branch}\n`);
}

try {
  if (action === 'detect' && process.argv.length === 3) await detect();
  else if (action === 'pull-request' && process.argv.length === 9) await pullRequest();
  else throw new Error('usage: update-ci.mjs detect | pull-request --result FILE --notes FILE --bundle FILE');
} catch (error) {
  process.stderr.write(`update-ci: ${error.message}\n`);
  process.exitCode = 2;
}
