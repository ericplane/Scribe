// Watch the authoring sources, not the generated Markdown. Astro watches the
// resulting files and handles browser updates itself.
import { spawn } from 'node:child_process';
import { watch } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { dev } from 'astro';

const project = fileURLToPath(new URL('../', import.meta.url));
const python = process.env.PYTHON || 'python';
const watchers = [];
let stopping = false;
let generating = false;
let queued = false;
let timer;
let generator;
let astro;

async function generate() {
  if (stopping) return 1;
  if (generating) { queued = true; return; }
  generating = true;
  const code = await new Promise((resolve) => {
    generator = spawn(python, ['../docgen/gen.py'], { cwd: project, stdio: 'inherit' });
    generator.once('error', (error) => { console.error(error.message); resolve(1); });
    generator.once('exit', (code) => resolve(code ?? 1));
  });
  generating = false;
  generator = undefined;
  if (queued && !stopping) { queued = false; return generate(); }
  return code;
}

function schedule() {
  if (stopping) return;
  clearTimeout(timer);
  timer = setTimeout(() => {
    void generate().then((code) => {
      if (code && !stopping) console.error('[docs] Generation failed. Fix the source and save again to retry.');
    }).catch(fail);
  }, 200);
}

function stop() {
  if (stopping) return;
  stopping = true;
  clearTimeout(timer);
  watchers.forEach((watcher) => watcher.close());
  generator?.kill();
  if (astro) void astro.stop().catch(fail);
}

function fail(error) {
  console.error(error.message);
  process.exitCode = 1;
  stop();
}

process.once('SIGINT', stop);
process.once('SIGTERM', stop);

async function start() {
  const { values } = parseArgs({ options: { port: { type: 'string' } } });
  const port = values.port === undefined ? undefined : Number(values.port);
  if (port !== undefined && (!Number.isInteger(port) || port < 1 || port > 65535)) {
    throw new Error('--port must be an integer between 1 and 65535.');
  }
  const code = await generate();
  if (stopping) return;
  if (code) { process.exitCode = code; return; }

  for (const path of ['docgen', 'src']) {
    const watcher = watch(new URL(`../../${path}/`, import.meta.url), { recursive: true }, (_event, filename) => {
      if (filename && /(?:__pycache__|\.pyc$)/.test(filename)) return;
      schedule();
    });
    watcher.on('error', fail);
    watchers.push(watcher);
  }
  // Watch the parent directory: editors that save by replacing wally.toml would
  // leave a direct file watcher attached to the old inode on macOS/Linux.
  const versionWatcher = watch(new URL('../../', import.meta.url), (_event, filename) => {
    if (!filename || filename === 'wally.toml') schedule();
  });
  versionWatcher.on('error', fail);
  watchers.push(versionWatcher);

  // Use the API so Astro stays in this process for every caller. The CLI can
  // otherwise start a daemon and exit, separating the server from our watchers.
  astro = await dev({
    root: project,
    server: { host: '127.0.0.1', ...(port === undefined ? {} : { port }) },
  });
  // A signal may arrive while Astro is still starting up.
  if (stopping) await astro.stop();
}

await start().catch(fail);
