import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  ftruncateSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { join, sep } from 'node:path';
import { isDeepStrictEqual } from 'node:util';

const { isAlias, isCollection, isMap, isPair, isScalar, parseDocument, visit } = createRequire('/opt/open-knowledge/package.json')('yaml');

const project = '/data/.ok';
const local = join(project, 'local');
const user = join(homedir(), '.ok');
const switches = {
  DO_NOT_TRACK: '1',
  DISABLE_TELEMETRY: '1',
  OK_DISABLE_LOCAL_SINK: '1',
  OTEL_SDK_DISABLED: 'true',
};
const layers = [
  {
    root: project,
    file: join(project, 'config.yml'),
    keys: ['telemetry.localSink.enabled', 'lossCapture.enabled'],
    required: true,
  },
  {
    root: project,
    file: join(local, 'config.yml'),
    keys: ['telemetry.localSink.enabled', 'lossCapture.enabled'],
    required: false,
  },
  {
    root: user,
    file: join(user, 'global.yml'),
    keys: ['telemetry.skillInstallReports.enabled'],
    required: true,
    make: true,
  },
];
const recordDirectories = [
  ...['telemetry', 'logs', 'loss-capture'].map((name) => join(local, name)),
  join(user, 'logs', 'projects'),
];
const recordFiles = [
  { directory: local, name: /^tolerance-telemetry.*\.jsonl$/ },
  { directory: user, name: /^skill-install-events.*\.jsonl$/ },
];

const problems = [];

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function plain(value) {
  if (Array.isArray(value)) return value.map(plain);
  if (isRecord(value)) return Object.fromEntries(Object.entries(value).map(([name, entry]) => [name, plain(entry)]));
  return value;
}

function parse(text) {
  const document = parseDocument(text);
  if (document.errors.length > 0) {
    throw new Error(`the YAML parser reports an error: ${document.errors[0].message.split('\n')[0]}`);
  }
  let content;
  try {
    content = plain(document.toJS());
  } catch (error) {
    throw new Error(`the YAML parser reports an error: ${error.message}`);
  }
  if (content !== null && content !== undefined && !isRecord(content)) throw new Error('the top level is not a mapping');
  return { text, document, content: content ?? {} };
}

function valueOf(content, key) {
  let value = content;
  for (const part of key.split('.')) {
    if (!isRecord(value) || !Object.hasOwn(value, part)) return undefined;
    value = value[part];
  }
  return value;
}

function wrong(layer, content, key) {
  const value = valueOf(content, key);
  return layer.required ? value !== false : value !== undefined && value !== false;
}

function forced(content, key) {
  const result = plain(content);
  const path = key.split('.');
  let holder = result;
  for (const part of path.slice(0, -1)) {
    if (!Object.hasOwn(holder, part) || !isRecord(holder[part])) holder[part] = {};
    holder = holder[part];
  }
  holder[path.at(-1)] = false;
  return result;
}

function lineEnd(text) {
  return text.includes('\r\n') ? '\r\n' : '\n';
}

function block(path, end, indent) {
  return path.map((part, depth) => `${'  '.repeat(depth)}${part}:${depth === path.length - 1 ? ' false' : ''}`).join(`${end}${indent}`);
}

function appended({ text, content }, key) {
  const path = key.split('.');
  if (Object.hasOwn(content, path[0])) return null;
  const end = lineEnd(text);
  const open = text === '' || text.endsWith('\n') ? '' : end;
  return `${text}${open}${block(path, end, '')}${end}`;
}

function replaced({ text, document }, key) {
  const node = document.getIn(key.split('.'), true);
  if (!isScalar(node) || !node.range) return null;
  return `${text.slice(0, node.range[0])}false${text.slice(node.range[1])}`;
}

function inserted({ text, document }, key) {
  const path = key.split('.');
  for (let depth = path.length - 1; depth > 0; depth--) {
    const map = document.getIn(path.slice(0, depth), true);
    if (map === undefined) continue;
    const first = isMap(map) && !map.flow ? map.items[0]?.key?.range?.[0] : undefined;
    if (first === undefined) return null;
    const indent = text.slice(text.lastIndexOf('\n', first - 1) + 1, first);
    if (!/^ *$/.test(indent)) return null;
    const end = lineEnd(text);
    return `${text.slice(0, first)}${block(path.slice(depth), end, indent)}${end}${indent}${text.slice(first)}`;
  }
  return null;
}

function fresh(document, value, old) {
  const node = document.createNode(value);
  if (old?.commentBefore) node.commentBefore = old.commentBefore;
  if (old?.comment) node.comment = old.comment;
  return node;
}

function rewritten({ text, content }, key) {
  const document = parseDocument(text);
  if (isScalar(document.contents) && document.contents.value === null) document.contents = fresh(document, {}, document.contents);
  const path = key.split('.');
  for (let depth = 1; depth < path.length; depth++) {
    const parent = path.slice(0, depth);
    const old = document.getIn(parent, true);
    if (isMap(old)) continue;
    const copy = valueOf(content, parent.join('.'));
    document.setIn(parent, fresh(document, isRecord(copy) ? copy : {}, old));
  }
  const chain = path.map((_, depth) => document.getIn(path.slice(0, depth + 1), true)).filter(Boolean);
  visit(document, {
    Alias(_, alias) {
      const source = alias.resolve(document);
      return chain.includes(source) ? document.createNode(plain(source.toJS(document))) : undefined;
    },
  });
  document.setIn(path, fresh(document, false, document.getIn(path, true)));
  let text2 = document.toString({ lineWidth: 0 });
  if (text.startsWith('﻿')) text2 = `﻿${text2}`;
  if (text.includes('\r\n') && !/(^|[^\r])\n/.test(text)) text2 = text2.replace(/\r?\n/g, '\r\n');
  return text2;
}

const methods = [
  { name: 'lines added at the end', edit: appended },
  { name: 'value replaced', edit: replaced },
  { name: 'lines added in the mapping', edit: inserted },
  { name: 'file written again by the parser', edit: rewritten },
];

function numberTexts(document) {
  const texts = new Map();
  const walk = (node, path) => {
    const item = isAlias(node) ? node.resolve(document) : node;
    if (isScalar(item) && typeof item.value !== 'number') return;
    if (isScalar(item)) texts.set(path, item.source);
    if (!isCollection(item)) return;
    item.items.forEach((entry, index) => {
      if (!isPair(entry)) return walk(entry, `${path}/${index}`);
      const name = `${path}/${isScalar(entry.key) ? JSON.stringify(String(entry.key.value)) : index}`;
      walk(entry.key, `${name}?`);
      walk(entry.value, name);
    });
  };
  walk(document.contents, '');
  return texts;
}

function settle(source, key) {
  const wanted = forced(source.content, key);
  const texts = numberTexts(source.document);
  for (const method of methods) {
    try {
      const text = method.edit(source, key);
      const result = text === null ? null : parse(text);
      if (result === null || !isDeepStrictEqual(result.content, wanted)) continue;
      if ([...numberTexts(result.document)].every(([path, number]) => texts.get(path) === number)) return { result, method: method.name };
    } catch {
      continue;
    }
  }
  return null;
}

function target(layer, write) {
  if (write && layer.make && !lstatSync(layer.root, { throwIfNoEntry: false })) mkdirSync(layer.root);
  const root = lstatSync(layer.root, { throwIfNoEntry: false });
  if (root && !root.isDirectory()) throw new Error(`${layer.root} is a symbolic link or not a directory`);
  if (!root || !lstatSync(layer.file, { throwIfNoEntry: false })) return null;
  let path;
  try {
    path = realpathSync(layer.file);
  } catch (error) {
    throw new Error(`the symbolic link leads to no file (${error.code})`);
  }
  if (!path.startsWith(`${realpathSync(layer.root)}${sep}`)) throw new Error('a symbolic link leads out of the .ok directory');
  if (!/\.ya?ml$/.test(path)) throw new Error('the name of the link target does not end in .yml or .yaml');
  const found = lstatSync(path);
  if (!found.isFile()) throw new Error('the path is not a regular file');
  if (found.nlink > 1) throw new Error('the file has more than one hard link');
  return path;
}

function quiet(action) {
  try {
    action();
  } catch {
    return;
  }
}

function spare(path) {
  return `${path}.no-telemetry.tmp`;
}

function replace(path, bytes, mode) {
  const handle = openSync(spare(path), 'wx', mode);
  try {
    try {
      writeFileSync(handle, bytes);
      fsyncSync(handle);
    } finally {
      closeSync(handle);
    }
    chmodSync(spare(path), mode);
    renameSync(spare(path), path);
  } finally {
    rmSync(spare(path), { force: true });
  }
}

function append(path, length, bytes) {
  let handle;
  try {
    handle = openSync(path, constants.O_WRONLY | constants.O_APPEND | constants.O_NOFOLLOW);
  } catch {
    return false;
  }
  try {
    writeFileSync(handle, bytes);
    fsyncSync(handle);
  } catch (error) {
    try {
      ftruncateSync(handle, length);
    } catch {
      error.changed = true;
    }
    throw error;
  } finally {
    quiet(() => closeSync(handle));
  }
  return true;
}

function store(path, before, text, added) {
  if (before !== null && added !== null && append(path, before.length, Buffer.from(added))) return;
  const bytes = added === null ? Buffer.from(text) : Buffer.concat([before ?? Buffer.alloc(0), Buffer.from(added)]);
  replace(path, bytes, before === null ? 0o644 : lstatSync(path).mode & 0o777);
}

function restore(path, before) {
  if (before === null) rmSync(path, { force: true });
  else replace(path, before, lstatSync(path).mode & 0o777);
}

function holds(path, content) {
  try {
    return isDeepStrictEqual(parse(readFileSync(path, 'utf8')).content, content);
  } catch {
    return false;
  }
}

function applyLayer(layer) {
  const found = target(layer, true);
  if (found === null && !layer.required) return;
  const path = found ?? layer.file;
  quiet(() => lstatSync(spare(path), { throwIfNoEntry: false })?.isFile() && rmSync(spare(path)));
  const before = found === null ? null : readFileSync(path);
  const start = parse(before === null ? '' : before.toString('utf8'));
  let source = start;
  const done = [];
  for (const key of layer.keys.filter((name) => wrong(layer, start.content, name))) {
    const step = settle(source, key);
    if (step === null) {
      problems.push(`${layer.file}: ${key} is not set: no edit keeps the data and the number text of the other keys`);
      continue;
    }
    source = step.result;
    done.push(`${key} (${step.method})`);
  }
  if (done.length === 0) return;
  store(path, before, source.text, source.text.startsWith(start.text) ? source.text.slice(start.text.length) : null);
  if (!holds(path, source.content)) {
    const error = new Error('the file did not hold the result after the write');
    try {
      restore(path, before);
    } catch {
      error.changed = true;
    }
    throw error;
  }
  console.log(`no-telemetry: set to false in ${layer.file}: ${done.join(', ')}`);
}

function apply() {
  for (const layer of layers) {
    try {
      applyLayer(layer);
    } catch (error) {
      const state = error.changed ? 'CHANGED, and the bytes before are not back' : 'not changed';
      problems.push(`${layer.file}: ${state}: ${error.message}`);
    }
  }
}

function filesUnder(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter((entry) => !entry.isDirectory())
    .map((entry) => join(entry.parentPath, entry.name));
}

function check() {
  let environment = {};
  try {
    environment = Object.fromEntries(
      readFileSync('/proc/1/environ', 'utf8')
        .split('\0')
        .filter(Boolean)
        .map((entry) => [entry.split('=', 1)[0], entry.slice(entry.indexOf('=') + 1)]),
    );
  } catch (error) {
    problems.push(`the environment of the server process cannot be read: ${error.message}`);
  }
  for (const [name, value] of Object.entries(switches)) {
    if (environment[name] !== value) {
      problems.push(`${name} is ${environment[name] || 'absent or empty'} in the environment, not ${value}`);
    }
  }
  for (const layer of layers) {
    try {
      const path = target(layer, false);
      if (path === null && !layer.required) continue;
      const { content } = parse(path === null ? '' : readFileSync(path, 'utf8'));
      for (const key of layer.keys) {
        if (wrong(layer, content, key)) problems.push(`${layer.file}: ${key} is not false`);
      }
    } catch (error) {
      problems.push(`${layer.file}: ${error.message}`);
    }
  }
  const records = recordDirectories.flatMap(filesUnder);
  for (const { directory, name } of recordFiles) {
    if (!existsSync(directory)) continue;
    records.push(
      ...readdirSync(directory)
        .filter((entry) => name.test(entry))
        .map((entry) => join(directory, entry)),
    );
  }
  for (const file of records) problems.push(`recorded file: ${file}`);
}

const mode = process.argv[2];
if (process.argv.length > 3 || (mode !== undefined && mode !== '--check')) {
  console.error('usage: no-telemetry.mjs [--check]');
  process.exit(2);
}
if (mode === '--check') check();
else apply();
for (const problem of problems) console.error(`no-telemetry: ${problem}`);
if (problems.length > 0) process.exit(1);
if (mode === '--check') console.log('no-telemetry: ok');
