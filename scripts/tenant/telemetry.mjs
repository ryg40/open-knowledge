import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const baselinePath = 'scripts/tenant/telemetry.baseline';
const schemaPath = 'packages/core/src/config/schema.ts';
const guardPath = 'deploy/no-telemetry.mjs';
const ignorePath = 'deploy/Dockerfile.dockerignore';
const kitSettings = ['VITE_OTEL_ENABLED'];
const scopes = ['packages/server/src', 'packages/cli/src', 'packages/core/src', 'packages/app/src'];
const excluded = ['*.test.ts', '*.test.tsx', '*.test-helper.ts', '*/__tests__/*', '*/__fixtures__/*', '*/fixtures/*', '*/test/*'].map((pattern) => `:(exclude)${pattern}`);
const access = "env\\??(\\.|\\[['\"`])";
const variable = `${access}[A-Z0-9_]*(TELEMETRY|OTEL|OTLP|TRACK|SINK|ANALYTICS|DIAG|REPORT|CAPTURE|METRIC|SENTRY|POSTHOG|USAGE|BEACON|FEEDBACK|CRASH)[A-Z0-9_]*`;
const anyVariable = `${access}[A-Z][A-Z0-9_]+`;
const localeVariable = /^(LANG|LC_[A-Z]+)$/;
const unpacked = '\\}[[:space:]]*=[[:space:]]*(process|import\\.meta)\\.env';
const scheme = '(https?|wss?)://';
const address = `${scheme}([A-Za-z0-9.-]+\\.[a-z]{2,}|[0-9]{1,3}(\\.[0-9]{1,3}){3})`;
const loopback = /^(127(\.[0-9]{1,3}){3}|0\.0\.0\.0)$/;
const builtAddress = `${scheme}\\$\\{`;
const moduleUse = `(from|import|require)[[:space:]]*\\(?[[:space:]]*['"][@a-z][^'"]*['"]`;
const moduleName = /opentelemetry|otel|otlp|telemetry|sentry|posthog|segment|analytics|amplitude|mixpanel|datadog|bugsnag|rollbar|newrelic|honeycomb|plausible|logrocket|fullstory|statsig|rudder|matomo|gtag|beacon|tracking/i;
const kitKinds = ['switch', 'force', 'unset'];
const sourceKinds = ['default', 'read', 'env', 'unpack', 'host', 'built', 'module', 'setting'];
const kitScopes = ['deploy', 'scripts/tenant', '.gitea/workflows', '.github/workflows'];
const settingScopes = ['.', ...scopes, 'scripts/tenant', '.changeset', '*.md', '*.mdx', '*.test.ts', '*.test.tsx', '*/tests/*'].map((path, index) => (index ? `:(exclude)${path}` : path));
const envFiles = '**/.env*';
const kitExempt = /^(deploy\/docs\/|scripts\/tenant\/telemetry\.)/;

function schemaDefaults(text) {
  const stack = [];
  const found = [];
  const record = (literal) => found.push({ path: stack.map((entry) => entry.name).join('.'), literal });
  const lines = text.split('\n');
  for (let index = 0; index < lines.length; index++) {
    const opened = lines[index].match(/^(\s+)([A-Za-z0-9_]+): z\b(.*)$/);
    if (opened) {
      while (stack.length && stack.at(-1).depth >= opened[1].length) stack.pop();
      stack.push({ depth: opened[1].length, name: opened[2] });
      const inline = opened[3].match(/\.default\((.*)\),?$/);
      if (inline) { record(inline[1]); stack.pop(); }
      continue;
    }
    const closed = lines[index].match(/^(\s+)\.default\((.*)$/);
    if (!closed) continue;
    const depth = closed[1].length - 2;
    while (stack.length && stack.at(-1).depth > depth) stack.pop();
    if (stack.at(-1)?.depth !== depth) continue;
    let literal = closed[2];
    while (!/\),?$/.test(literal) && index + 1 < lines.length) literal += ` ${lines[++index].trim()}`;
    record(literal.replace(/\),?$/, ''));
    stack.pop();
  }
  if (!found.some(({ path }) => path.startsWith('telemetry.'))) throw new Error(`no telemetry key found in ${schemaPath}`);
  const compact = (literal) => literal.replace(/\s+/g, ' ').replace(/, \}/g, ' }');
  const repeatsChildren = ({ path, literal }) => {
    const children = found.filter((entry) => entry.path.startsWith(`${path}.`) && !entry.path.slice(path.length + 1).includes('.'));
    return children.length > 0 && compact(literal) === compact(`{ ${children.map((entry) => `${entry.path.slice(path.length + 1)}: ${entry.literal}`).join(', ')} }`);
  };
  return found.filter((entry) => !repeatsChildren(entry)).map(({ path, literal }) => `default\t${path}\t${literal}`);
}

export function sourceFacts(cwd, ref) {
  const git = (args, statuses = [0]) => {
    const output = spawnSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
    if (output.error || !statuses.includes(output.status)) throw new Error(`command failed: git ${args[0]} (exit ${output.status ?? 2})\n${output.stderr || output.error?.message || ''}`);
    return output.stdout;
  };
  const grep = (flags, pattern, paths = [...scopes, ...excluded]) => git(['grep', '-I', ...flags, ...(ref ? [] : ['--untracked']), '-E', '-e', pattern, ...(ref ? [ref] : []), '--', ...paths], [0, 1]).split('\n').filter(Boolean);
  const schema = ref ? git(['show', `${ref}:${schemaPath}`]) : readFileSync(join(cwd, schemaPath), 'utf8');
  const plain = (path) => (ref && path.startsWith(`${ref}:`) ? path.slice(ref.length + 1) : path);
  const counted = (values) => [...values.reduce((counts, value) => counts.set(value, (counts.get(value) ?? 0) + 1), new Map())];
  const reads = grep(['-z', '--full-name'], variable).map((line) => {
    const [path, text] = line.split('\0');
    return `read\t${plain(path)}\t${text.trim().replace(/\s+/g, ' ').replace(new RegExp(scheme, 'g'), '')}`;
  });
  const names = grep(['-h', '-o'], anyVariable).map((match) => match.match(/[A-Z][A-Z0-9_]+$/)[0]).filter((name) => !localeVariable.test(name)).map((name) => `env\t${name}`);
  const unpacks = grep(['-z', '--full-name'], unpacked).map((line) => {
    const [path, text] = line.split('\0');
    return `unpack\t${plain(path)}\t${text.trim().replace(/\s+/g, ' ')}`;
  });
  const hosts = counted(grep(['-h', '-o', '-i'], address).map((match) => match.replace(new RegExp(`^${scheme}`, 'i'), '').toLowerCase()).filter((host) => !loopback.test(host))).map(([host, count]) => `host\t${host}\t${count}`);
  const built = grep(['-i', '-c', '--full-name'], builtAddress).map((line) => `built\t${plain(line.slice(0, line.lastIndexOf(':')))}\t${line.slice(line.lastIndexOf(':') + 1)}`);
  const modules = grep(['-h', '-o'], moduleUse).map((match) => match.match(/['"]([^'"]+)['"]$/)[1]).filter((name) => !name.startsWith('@/') && moduleName.test(name)).map((name) => `module\t${name}`);
  const settings = kitSettings.flatMap((name) => grep(['-z', '--full-name'], name, settingScopes)).map((line) => {
    const [path, text] = line.split('\0');
    return `setting\t${plain(path)}\t${text.trim().replace(/\s+/g, ' ')}`;
  });
  return [...new Set([...schemaDefaults(schema), ...reads, ...names, ...unpacks, ...hosts, ...built, ...modules, ...settings])].sort();
}

function readBaseline(root) {
  const lines = readFileSync(join(root, baselinePath), 'utf8').split('\n').filter(Boolean);
  for (const line of lines) {
    const fields = line.split('\t');
    if (![...kitKinds, ...sourceKinds].includes(fields[0]) || fields.length < 2 || fields.some((field) => !field)) throw new Error(`invalid baseline line: ${line}`);
  }
  if (new Set(lines).size !== lines.length) throw new Error('the baseline repeats a line');
  return { kit: lines.filter((line) => kitKinds.includes(line.split('\t')[0])), source: lines.filter((line) => sourceKinds.includes(line.split('\t')[0])) };
}

function kitFiles(root) {
  return kitScopes
    .filter((scope) => existsSync(join(root, scope)))
    .flatMap((scope) => readdirSync(join(root, scope), { recursive: true, withFileTypes: true }).filter((entry) => entry.isFile()).map((entry) => relative(root, join(entry.parentPath, entry.name))))
    .filter((path) => !kitExempt.test(path))
    .sort();
}

function kitProblems(root, kit) {
  const text = (path) => readFileSync(join(root, path), 'utf8');
  const literal = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const problems = [];
  const expect = (found, message) => { if (!found) problems.push(message); };
  if (kitKinds.some((kind) => !kit.some((line) => line.startsWith(`${kind}\t`)))) throw new Error('the baseline names no switch, no forced key or no build setting');
  for (const line of kit) {
    const [kind, name, value] = line.split('\t');
    if (kind === 'unset') {
      for (const path of kitFiles(root)) expect(!text(path).includes(name), `${path} names the build setting ${name}`);
      expect(text(ignorePath).split('\n').includes(envFiles), `${ignorePath} does not hold the line ${envFiles}`);
      continue;
    }
    if (kind === 'force') {
      expect(text(guardPath).includes(`'${name}'`), `${guardPath} does not force ${name}`);
      continue;
    }
    if (value === undefined) throw new Error(`invalid baseline line: ${line}`);
    expect(new RegExp(`^ {6}${literal(name)}: "${literal(value)}"$`, 'm').test(text('deploy/compose.yaml')), `deploy/compose.yaml does not set ${name} to ${value}`);
    expect(new RegExp(`^ {4}${literal(name)}=${literal(value)}( \\\\)?$`, 'm').test(text('deploy/Dockerfile')), `deploy/Dockerfile does not set ${name} to ${value}`);
    expect(new RegExp(`^ {2}--env ${literal(name)}=${literal(value)} \\\\$`, 'm').test(text('scripts/tenant/smoke.sh')), `scripts/tenant/smoke.sh does not set ${name} to ${value}`);
    expect(text(guardPath).includes(`${name}: '${value}'`), `${guardPath} does not check ${name} for ${value}`);
  }
  return problems;
}

function main() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const [action = 'check', ...rest] = process.argv.slice(2);
  if (action === 'list' && (rest.length === 0 || (rest.length === 2 && rest[0] === '--ref'))) {
    process.stdout.write(`${sourceFacts(root, rest[1]).join('\n')}\n`);
    return 0;
  }
  if (!['check', 'update'].includes(action) || rest.length) {
    process.stderr.write('usage: telemetry.sh [check | update | list [--ref <revision>]]\n');
    return 2;
  }
  const baseline = readBaseline(root);
  const present = sourceFacts(root);
  if (action === 'update') {
    writeFileSync(join(root, baselinePath), `${[...baseline.kit, ...present].join('\n')}\n`);
    process.stdout.write(`telemetry: ${baselinePath} holds ${present.length} source facts\n`);
    return 0;
  }
  const problems = kitProblems(root, baseline.kit);
  const added = present.filter((line) => !baseline.source.includes(line));
  const removed = baseline.source.filter((line) => !present.includes(line));
  for (const problem of problems) process.stderr.write(`telemetry: ${problem}\n`);
  for (const line of added) process.stderr.write(`telemetry: in the source, not in the baseline: ${line}\n`);
  for (const line of removed) process.stderr.write(`telemetry: in the baseline, not in the source: ${line}\n`);
  if (problems.length || added.length || removed.length) return 1;
  process.stdout.write(`telemetry: ok (${baseline.kit.length} kit settings, ${present.length} source facts)\n`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (error) {
    process.stderr.write(`telemetry: ${error.message}\n`);
    process.exitCode = 2;
  }
}
