import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

const root = resolve(process.env.OK_WORKFLOWS_ROOT || join(dirname(fileURLToPath(import.meta.url)), '../..'));
const fork = ['.gitea/workflows/checks.yml', '.gitea/workflows/upstream-update.yml', '.github/workflows/portable-release.yml', '.github/workflows/public-checks.yml'];
const secrets = {
  '.gitea/workflows/checks.yml': [],
  '.gitea/workflows/upstream-update.yml': ['OK_UPDATE_TOKEN'],
  '.github/workflows/portable-release.yml': ['OK_REGISTRY_USER', 'OK_REGISTRY_TOKEN'],
  '.github/workflows/public-checks.yml': [],
};
const standard = ['[', 'awk', 'cat', 'docker', 'echo', 'exit', 'git', 'grep', 'mkdir', 'node', 'printf', 'rm', 'sed', 'set', 'sh', 'tail', 'tee', 'test'];
const keywords = ['!', '{', '}', 'do', 'done', 'elif', 'else', 'fi', 'if', 'then', 'while'];
const interpreters = ['node', 'sh'];

function parse(text) {
  const lines = text.split('\n');
  if (lines.at(-1) === '') lines.pop();
  let at = 0;
  const fail = (message, line = at) => { throw new Error(`line ${line + 1}: ${message}`); };
  const indent = (line) => line.length - line.trimStart().length;
  const skip = () => {
    while (at < lines.length && lines[at].trim() === '') at++;
    if (at < lines.length && (lines[at].includes('\t') || lines[at].trimStart().startsWith('#') || lines[at] === '---')) fail('unsupported YAML: tab, comment or document marker');
    return at < lines.length;
  };
  const scalar = (value) => {
    if (value.startsWith("'")) {
      if (value.length < 2 || !value.endsWith("'") || /(^|[^'])'([^']|$)/.test(value.slice(1, -1))) fail('unsupported single-quoted scalar');
      return value.slice(1, -1).replaceAll("''", "'");
    }
    if (value.startsWith('"')) {
      if (value.length < 2 || !value.endsWith('"') || /["\\]/.test(value.slice(1, -1))) fail('unsupported double-quoted scalar');
      return value.slice(1, -1);
    }
    if (/^[[{&*!|>%@`]/.test(value) || /: | #|:$/.test(value)) fail('unsupported plain scalar');
    return value;
  };
  const literal = (parent, chomp) => {
    const collected = [];
    let width;
    while (at < lines.length && (lines[at].trim() === '' || indent(lines[at]) > parent)) {
      if (lines[at].includes('\t')) fail('unsupported YAML: tab');
      if (width === undefined && lines[at].trim() !== '') width = indent(lines[at]);
      if (lines[at].trim() !== '' && indent(lines[at]) < width) fail('block scalar loses its indentation');
      collected.push(lines[at].trim() === '' ? '' : lines[at].slice(width));
      at++;
    }
    while (collected.length && collected.at(-1) === '') collected.pop();
    if (!collected.length) fail('empty block scalar');
    return collected.join('\n') + (chomp === '-' ? '' : '\n');
  };
  const block = (width) => (lines[at].slice(width) === '-' || lines[at].slice(width).startsWith('- ') ? sequence(width) : mapping(width));
  function mapping(width) {
    const value = {};
    while (skip() && indent(lines[at]) === width && !lines[at].slice(width).startsWith('- ')) {
      const match = lines[at].slice(width).match(/^([A-Za-z0-9_.-]+):(?: +(.*?))? *$/);
      if (!match) fail('expected a key');
      const [, key, rest] = match;
      if (Object.hasOwn(value, key)) fail(`duplicate key ${key}`);
      at++;
      if (rest === '|' || rest === '|-') value[key] = literal(width, rest.slice(1));
      else if (rest !== undefined && rest !== '') value[key] = scalar(rest);
      else if (skip() && (indent(lines[at]) > width || (indent(lines[at]) === width && lines[at].slice(width).startsWith('- ')))) value[key] = block(indent(lines[at]));
      else value[key] = '';
    }
    if (at < lines.length && indent(lines[at]) > width) fail('unexpected indentation');
    return value;
  }
  function sequence(width) {
    const value = [];
    while (skip() && indent(lines[at]) === width && (lines[at].slice(width) === '-' || lines[at].slice(width).startsWith('- '))) {
      const rest = lines[at].slice(width + 2);
      if (/^[A-Za-z0-9_.-]+:( |$)/.test(rest)) {
        lines[at] = `${' '.repeat(width + 2)}${rest}`;
        value.push(mapping(width + 2));
      } else {
        if (rest.trim() === '') fail('unsupported empty sequence entry');
        value.push(scalar(rest.trim()));
        at++;
      }
    }
    if (at < lines.length && indent(lines[at]) > width) fail('unexpected indentation');
    return value;
  }
  if (!skip()) fail('empty document');
  if (indent(lines[at]) !== 0) fail('unexpected indentation');
  const document = block(0);
  if (skip()) fail('unexpected content');
  return document;
}

function closing(text, start) {
  const stack = ['('];
  for (let at = start; at < text.length; at++) {
    const char = text[at];
    if (char === '\\') at++;
    else if (stack.at(-1) === '"') {
      if (char === '"') stack.pop();
      else if (char === '$' && text[at + 1] === '(') { stack.push('('); at++; }
    } else if (char === "'") {
      at = text.indexOf("'", at + 1);
      if (at < 0) break;
    } else if (char === '"') stack.push('"');
    else if (char === '(') stack.push('(');
    else if (char === ')') {
      stack.pop();
      if (!stack.length) return at;
    }
  }
  throw new Error('unbalanced command substitution');
}
function commands(script) {
  const found = [];
  const scan = (text) => {
    let words = [], word = '', quoted = false, quote = '';
    const endWord = () => { if (word || quoted) words.push(word); word = ''; quoted = false; };
    const endCommand = () => { endWord(); if (words.length) found.push(words); words = []; };
    for (let at = 0; at < text.length; at++) {
      const char = text[at];
      if (quote === "'") { if (char === "'") quote = ''; else word += char; }
      else if (char === '\\') { if (text[at + 1] !== '\n') word += text[at + 1] ?? ''; at++; }
      else if (char === '$' && text[at + 1] === '(') {
        const end = closing(text, at + 2);
        scan(text.slice(at + 2, end));
        word += '$()';
        at = end;
      } else if (char === '`') throw new Error('unsupported backquote substitution');
      else if (quote === '"') { if (char === '"') quote = ''; else word += char; }
      else if (char === "'" || char === '"') { quote = char; quoted = true; }
      else if (char === '&' && text[at - 1] === '>') word += char;
      else if ('\n;|&'.includes(char)) endCommand();
      else if (char === ' ') endWord();
      else if (char === '(' || char === ')') throw new Error('unsupported subshell or pattern');
      else word += char;
    }
    if (quote) throw new Error('unbalanced quote');
    endCommand();
  };
  scan(script);
  return found.map((words) => {
    let start = 0;
    while (start < words.length && (keywords.includes(words[start]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[start]))) start++;
    return words.slice(start);
  }).filter((words) => words.length && !/^[0-9]*[<>]/.test(words[0]));
}
function tracked(path) {
  return /^[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.-]+)+$/.test(path) && !path.split('/').includes('..') && existsSync(join(root, path)) && statSync(join(root, path)).isFile();
}
function checkRun(script, problems) {
  if (script.includes('${{')) problems.push('a run script holds a workflow expression; pass the value through env');
  for (const words of commands(script)) {
    const [name, ...args] = words;
    const text = words.join(' ');
    if (name.includes('/')) {
      if (!tracked(name)) problems.push(`unknown repository command: ${name}`);
      else if (!(statSync(join(root, name)).mode & 0o111)) problems.push(`repository command is not executable: ${name}`);
    } else if (!standard.includes(name)) problems.push(`unknown command: ${name}`);
    if (interpreters.includes(name) && !args.some((arg) => tracked(arg))) problems.push(`interpreter without a repository script: ${text}`);
    for (const arg of args) if (/^(scripts|deploy)\//.test(arg) && !existsSync(join(root, arg))) problems.push(`unknown repository path: ${arg}`);
    if (words.some((value) => /promote\.sh|setup-remotes\.sh/.test(value))) problems.push(`a workflow must not promote: ${text}`);
    if (name === 'git' && args.includes('push')) problems.push(`a workflow must not push: ${text}`);
    if (name === 'git' && args[0] === 'tag' && !args.includes('--list')) problems.push(`a workflow must not tag: ${text}`);
  }
}
function checkFile(file, text) {
  const problems = [];
  const document = parse(text);
  for (const key of ['name', 'on', 'permissions', 'jobs']) if (!Object.hasOwn(document, key)) problems.push(`missing top-level key: ${key}`);
  if (typeof document.jobs !== 'object' || Array.isArray(document.jobs) || !Object.keys(document.jobs).length) throw new Error('jobs must be a mapping');
  const named = [...text.matchAll(/\bsecrets\.([A-Za-z0-9_]+)/g)].map((match) => match[1]);
  for (const name of named) if (!secrets[file].includes(name)) problems.push(`secret is not documented for this file: ${name}`);
  if (/\bsecrets\s*\[|\bsecrets\s*:\s*inherit|toJSON\(\s*secrets/i.test(text)) problems.push('indirect secret access');
  let steps = 0;
  for (const [id, job] of Object.entries(document.jobs)) {
    if (!job['runs-on'] || !job['timeout-minutes']) problems.push(`job ${id}: runs-on and timeout-minutes are required`);
    if (!Array.isArray(job.steps) || !job.steps.length) { problems.push(`job ${id}: steps are required`); continue; }
    for (const step of job.steps) {
      steps++;
      if ((typeof step.run === 'string') === (typeof step.uses === 'string')) problems.push(`job ${id}: a step needs exactly one of run and uses`);
      if (typeof step.uses === 'string' && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[a-f0-9]{40}$/.test(step.uses)) problems.push(`job ${id}: action is not pinned by commit: ${step.uses}`);
      if (typeof step.run === 'string') {
        try { checkRun(step.run, problems); } catch (error) { problems.push(`job ${id}: ${error.message}`); }
      }
    }
  }
  if (file === '.github/workflows/public-checks.yml') {
    if (!isDeepStrictEqual(document.permissions, { contents: 'read' })) problems.push('public checks need contents: read only');
    for (const [id, job] of Object.entries(document.jobs)) {
      if (job['runs-on'] !== 'ubuntu-latest') problems.push(`job ${id}: public checks need the hosted runner ubuntu-latest`);
      if (job.permissions !== undefined && !isDeepStrictEqual(job.permissions, { contents: 'read' })) problems.push(`job ${id}: public checks need contents: read only`);
    }
    if (/github\.token|GITHUB_TOKEN|\bvars\./.test(text)) problems.push('public checks must need no token and no variable');
  }
  return { document, problems, steps };
}
function fullParse(files) {
  const probe = spawnSync('python3', ['-I', '-c', 'import yaml'], { encoding: 'utf8' });
  if (probe.error || probe.status !== 0) return undefined;
  const program = 'import json, sys, yaml\ndef load(path):\n  try:\n    return {"document": yaml.load(open(path, encoding="utf-8"), Loader=yaml.BaseLoader)}\n  except yaml.YAMLError:\n    return {}\nprint(json.dumps([load(path) for path in sys.argv[1:]]))';
  const output = spawnSync('python3', ['-I', '-c', program, ...files.map((file) => join(root, file))], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (output.error || output.status !== 0) throw new Error(`full YAML parse failed\n${output.stderr || output.error?.message || ''}`);
  return JSON.parse(output.stdout);
}
function upstreamFiles() {
  return readdirSync(join(root, '.github/workflows')).filter((name) => !fork.includes(`.github/workflows/${name}`)).sort();
}
function check() {
  let failed = false;
  const report = (file, message) => { failed = true; process.stderr.write(`workflows: ${file}: ${message}\n`); };
  const documents = [];
  for (const file of fork) {
    if (!existsSync(join(root, file))) { report(file, 'missing fork workflow file'); documents.push(undefined); continue; }
    try {
      const { document, problems, steps } = checkFile(file, readFileSync(join(root, file), 'utf8'));
      documents.push(document);
      for (const problem of problems) report(file, problem);
      process.stdout.write(`workflows: ${file}: ${Object.keys(document.jobs).length} jobs, ${steps} steps\n`);
    } catch (error) {
      documents.push(undefined);
      report(file, error.message);
    }
  }
  if (existsSync(join(root, '.gitea/workflows'))) for (const name of readdirSync(join(root, '.gitea/workflows'))) if (!fork.includes(`.gitea/workflows/${name}`)) report(`.gitea/workflows/${name}`, 'file is not in the fork workflow list');
  const present = fork.filter((file) => existsSync(join(root, file)));
  const full = fullParse(present);
  if (full) {
    present.forEach((file, index) => {
      const structural = documents[fork.indexOf(file)];
      if (!Object.hasOwn(full[index], 'document')) report(file, 'the full YAML parse failed');
      else if (structural && !isDeepStrictEqual(JSON.parse(JSON.stringify(structural)), full[index].document)) report(file, 'the structural parse differs from the full YAML parse');
    });
  }
  process.stdout.write(`workflows: YAML mode: ${full ? 'structural check and full parse with PyYAML' : 'structural check only, PyYAML is not present'}\n`);
  process.stdout.write(`workflows: ${upstreamFiles().length} upstream files under .github/workflows are not checked\n`);
  if (failed) process.exitCode = 1;
  else process.stdout.write('workflows: ok\n');
}

try {
  if (process.argv.length !== 3) throw new Error('usage: workflows.sh check | upstream');
  if (process.argv[2] === 'check') check();
  else if (process.argv[2] === 'upstream') process.stdout.write(upstreamFiles().map((name) => `${name}\n`).join(''));
  else throw new Error('usage: workflows.sh check | upstream');
} catch (error) {
  process.stderr.write(`workflows: ${error.message}\n`);
  process.exitCode = 2;
}
