import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const args = process.argv.slice(2).map((arg) =>
  arg.replace(/^(container:)?(ok-smoke-[a-f0-9]{8}(?:-version|-probe)?)$/, `$1${process.env.OK_UPDATE_PREFIX}-$2`),
);
const command = args[0];
const allowed = ['build', 'run', 'create', 'start', 'inspect', 'port', 'rm', 'image'];
if (!allowed.includes(command) || (command === 'image' && !['inspect', 'save', 'rm'].includes(args[1]))) {
  process.stderr.write('update: Docker operation refused\n');
  process.exit(2);
}
if (command === 'run' || command === 'create') {
  if (!args.includes('--rm')) args.splice(1, 0, '--rm');
  if (!args.includes('--name')) args.splice(1, 0, '--name', `${process.env.OK_UPDATE_PREFIX}-${randomBytes(6).toString('hex')}`);
  const name = args[args.indexOf('--name') + 1];
  if (!name.startsWith(`${process.env.OK_UPDATE_PREFIX}-`)) process.exit(2);
  appendFileSync(process.env.OK_UPDATE_CONTAINER_LEDGER, `${name}\n`);
}
if (command === 'rm' && args.slice(1).some((arg) => !arg.startsWith('-') && !arg.startsWith(`${process.env.OK_UPDATE_PREFIX}-`))) {
  process.stderr.write('update: container removal refused\n');
  process.exit(2);
}
if (command === 'image' && args[1] === 'rm' && ![process.env.OK_UPDATE_IMAGE, `${process.env.OK_UPDATE_PREFIX}:base`].includes(args.at(-1))) process.exit(2);
const child = spawn(process.env.OK_UPDATE_DOCKER_EXECUTABLE, args, { stdio: 'inherit' });
let running = true;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => { if (running) child.kill(signal); });
}
child.on('error', () => { running = false; process.exitCode = 2; });
child.on('exit', (code) => { running = false; process.exitCode = code ?? 1; });
