// Executes the shipped runtime directly. No server, network, or package install.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Worker } from 'node:worker_threads';

const assets = new URL('../../docs-site/public/assets/playground/', import.meta.url);
const source = await readFile(new URL('runtime.luau', assets), 'utf8');
const metadata = JSON.parse(await readFile(new URL('metadata.json', assets), 'utf8'));
const api = JSON.parse(await readFile(new URL('api.json', assets), 'utf8'));
const presets = JSON.parse(await readFile(new URL('../theme/assets/playground/presets.json', import.meta.url), 'utf8'));
assert.equal(metadata.sourceSha256, createHash('sha256').update(source).digest('hex'));

let passed = 0;
async function example(templateCode, actionCode, policy = 'Clamp', executionMs = 5000, mode = 'run') {
  return new Promise((resolve, reject) => {
    // Match the browser's fresh-worker isolation, including a fresh Wasm module.
    const worker = new Worker(new URL('./check-worker.mjs', import.meta.url), {
      workerData: { source, templateCode, actionCode, policy, mode },
    });
    let deadline = setTimeout(() => { worker.terminate(); reject(new Error('Playground check load timed out')); }, 5000);
    worker.on('message', (message) => {
      if (message.ready) {
        clearTimeout(deadline);
        deadline = setTimeout(() => { worker.terminate(); reject(new Error('Playground execution timed out')); }, executionMs);
        return;
      }
      clearTimeout(deadline);
      worker.terminate();
      if (message.error) reject(new Error(message.error));
      else resolve(message);
    });
    worker.once('error', (error) => { clearTimeout(deadline); reject(error); });
  });
}
const describe = (templateCode) => example(templateCode, '', 'Clamp', 5000, 'describe').then((m) => m.described);

const EXPECTED = {
  clamp: { ok: true, output: ['Starting coins:\t20', 'After Set(175):\t100', 'After Set(5.8):\t6', 'After Increment(10):\t16'], after: [/\["Coins"\] = 16/] },
  reject: { ok: true, output: ['Write accepted:\tfalse', 'Scribe: invalid write to "Coins": out of bounds [0, 100]', 'Coins are still:\t20'], after: [/\["Coins"\] = 20/] },
  type: { ok: false, error: /invalid write/, output: [], after: [/\["Coins"\] = 20/] },
  inventory: { ok: true, output: ['Items:\t3', 'First item:\tshield', 'Potion count clamped to:\t99', 'Has a bow?\ttrue'], after: [/\["Id"\] = "potion"/, /\["Amount"\] = 99/], absent: [/sword/] },
  set: { ok: true, output: ['Added:\ttrue', 'Added again:\tfalse', 'Unlocked:\t2', 'Has DeepMines?\ttrue', 'Removed:\ttrue', 'Unlocked now:\t1'], after: [/\["Unlocked"\] = \{ \[1\] = "DeepMines" \}/] },
  derived: { ok: true, output: ['Level is now\t1', 'Level is now\t3', 'Direct write accepted:\tfalse'], after: [/\["Level"\] = 3/, /\["Xp"\] = 250/] },
  choices: { ok: true, output: ['Team:\tBlue', 'Green accepted:\tfalse', 'Enabled perks:\tLucky'], after: [/\["Team"\] = "Blue"/, /\["Perks"\] = \{ \[1\] = "Lucky" \}/] },
  pets: { ok: true, output: ['Pets before:\t0', 'Nickname before:\tnil', 'Nickname after:\tEm', 'Pets after:\t2'], after: [/\["Nickname"\] = "Em"/, /\["Species"\] = "Wolf"/] },
  friends: { ok: true, output: ['Friends:\t2', 'Friend 42:\tAva', 'Fractional key accepted:\tfalse'], after: [/\[42\] = \{ \["Name"\] = "Ava" \}/, /\[7\] = \{ \["Name"\] = "Kai" \}/] },
  big: { ok: true, output: ['Bank:\t1.5e21', 'Bank, short:\t1.50Sx', 'Coins, short:\t1.5K'], after: [/\["E"\] = 21/, /\["M"\] = 1\.5/] },
  visibility: { ok: true, output: ['Title:\tChampion', 'In combat:\ttrue'], after: [/\["Secret"\] = "server-only note"/, /\["InCombat"\] = true/, /\["Title"\] = "Champion"/] },
  listen: { ok: true, output: ['Coins changed from\t10\tto\t30', 'Music on?\tfalse'], after: [/\["Coins"\] = 31/, /\["Music"\] = false/] },
};

for (const preset of presets) {
  const expected = EXPECTED[preset.id];
  if (!expected) throw new Error(`Add assertions for preset ${preset.id}`);
  const { result, output } = await example(preset.template, preset.actions, preset.policy);
  const [ok, before, after, error] = result;
  assert.equal(ok, expected.ok, `${preset.id}: ${error}`);
  if (expected.error) assert.match(error, expected.error, preset.id);
  assert.deepEqual(output, expected.output, preset.id);
  assert.ok(before.length > 0, preset.id);
  const flat = after.replace(/\s+/g, ' ');
  for (const pattern of expected.after) assert.match(flat, pattern, `${preset.id}: ${flat}`);
  for (const pattern of expected.absent || []) assert.doesNotMatch(flat, pattern, `${preset.id}: ${flat}`);
  passed++;
}
const ids = new Set(presets.map((preset) => preset.id));
for (const id of Object.keys(EXPECTED)) assert.ok(ids.has(id), `Preset ${id} has assertions but no example`);

const template = presets[0].template;
for (const action of [
  'data.Coins.Set(-50); assert(data.Coins.Get() == 0)',
  'local ok, message = pcall(function() error("expected") end); assert(not ok); assert(string.find(message, "expected"))',
  'local ok, message = xpcall(function() error("expected") end, function(e) return "handled" end); assert(not ok); assert(message == "handled")',
  'assert(game == nil); assert(workspace == nil); assert(require == nil); assert(fetch == nil); assert(loadstring == nil)',
  'assert(globalThis == nil); assert(window == nil); assert(document == nil); assert(Function == nil); assert(process == nil)',
  'local ok = pcall(function() return print.constructor("return globalThis")() end); assert(not ok, "JavaScript constructor must be unavailable")',
  'assert(Scribe.Short(1500) == "1.50K"); assert(Scribe.Int ~= nil, "declarators stay reachable for Scribe.Short users")',
  'local ok, message = pcall(function() return Scribe.Timed(false) end); assert(not ok); assert(string.find(message, "unavailable"), message)',
]) {
  const { result } = await example(template, action);
  assert.equal(result[0], true, result[3]);
  passed++;
}

const { result: nested, output: printed } = await example('return {Settings = {Music = true}}', 'data.Settings.Music.Set(false); print(nil, 0.1 + 0.2, {})');
assert.equal(nested[0], true, nested[3]);
assert.match(nested[2], /\["Music"\] = false/);
assert.equal(printed.length, 1);
assert.match(printed[0], /^nil\t0\.30000000000000004\ttable: /, 'print formats values the way Luau does');
passed++;

const { result: capped } = await example('return {Rows = {}}', 'local rows = {}; for index = 1, 50 do rows[index] = string.rep("x", 400) end; data.Rows.Set(rows)');
assert.equal(capped[0], true, capped[3]);
assert.ok(capped[1].length + capped[2].length <= 12000);
assert.match(capped[2], /Snapshot display limit reached/);
passed++;

const { result: breadth } = await example('return {Rows = {}}', 'local rows = {}; for i = 1, 30 do rows[i] = {}; for j = 1, 30 do rows[i][j] = j end end; data.Rows.Set(rows)');
assert.equal(breadth[0], true, breadth[3]);
assert.ok(breadth[1].length + breadth[2].length <= 12000);
assert.match(breadth[2], /Snapshot display limit reached/);
passed++;

await assert.rejects(example(template, 'while true do end', 'Clamp', 100), /Playground execution timed out/);
passed++;

// describe() feeds the editor's completions and field panel.
const inventory = await describe(presets.find((preset) => preset.id === 'inventory').template);
assert.equal(inventory.ok, true, inventory.result);
const schema = JSON.parse(inventory.result);
const field = schema.children.find((child) => child.name === 'Inventory');
assert.equal(field.container, 'Array');
assert.equal(field.maxItems, 3);
assert.deepEqual(field.element.children.map((child) => child.name), ['Amount', 'Id']);
assert.deepEqual(field.element.children.map((child) => [child.type, child.min, child.max]), [['int', 1, 99], ['string', undefined, undefined]]);
assert.ok(!schema.children.some((child) => child.name.startsWith('_Scribe')), 'the reserved roots stay out of the field panel');
passed++;

const visibility = await describe(presets.find((preset) => preset.id === 'visibility').template);
const roots = Object.fromEntries(JSON.parse(visibility.result).children.map((child) => [child.name, child]));
assert.equal(roots.Session.persist, false);
assert.equal(roots.Secret.visibility, 'ServerOnly');
assert.equal(roots.Title.visibility, 'Shared');
passed++;

const broken = await describe('return { Coins = Scribe.Int("x") }');
assert.equal(broken.ok, false);
assert.match(broken.result, /Scribe\.Int default must be an integer/);
passed++;

for (const name of ['Int', 'ArrayOf', 'Derived', 'Short']) {
  assert.ok(api.some((entry) => entry.class === 'Scribe' && entry.name === name && entry.signature.startsWith(`Scribe.${name}`)), `api.json lists Scribe.${name}`);
}
for (const name of ['Get', 'Set', 'Insert', 'Observe']) {
  assert.ok(api.some((entry) => entry.class === 'Value' && entry.name === name && entry.summary.length > 0), `api.json documents Value.${name}`);
}
passed++;

console.log(`Playground: ${passed} checks passed using ${metadata.runtime}; Scribe ${metadata.scribeVersion}.`);
console.log(`Generated source: ${fileURLToPath(new URL('runtime.luau', assets))}`);
