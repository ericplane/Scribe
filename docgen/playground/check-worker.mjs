import { parentPort, workerData } from 'node:worker_threads';
import { LuauState } from '../theme/assets/playground/runtime/luau-web.mjs';

const { source, templateCode, actionCode, policy, mode } = workerData;
// Node workers otherwise miss the upstream browser-worker refusal assertion.
// This additionally exercises the worker guard; rendered-browser checks still
// verify the real web host branch and the UI deadline.
globalThis.WorkerGlobalScope = class WorkerGlobalScope {};
const output = [];
let state;
try {
  state = await LuauState.createAsync({ print: (...parts) => output.push(parts.map(String).join('\t')) });
  const [run, describe] = await state.loadstring(source, 'Scribe runtime', true)();
  const [template] = await state.loadstring(`return function(Scribe, print, warn)\n${templateCode}\nend`, 'Template', true)();
  if (mode === 'describe') {
    const [ok, result] = await describe(template);
    parentPort.postMessage({ described: { ok, result }, output });
  } else {
    const [actions] = await state.loadstring(`return function(data, Scribe, print, warn)\n${actionCode}\nend`, 'Actions', true)();
    parentPort.postMessage({ ready: true });
    const result = await run(template, actions, policy);
    parentPort.postMessage({ result, output });
  }
} catch (error) {
  parentPort.postMessage({ error: String(error) });
} finally {
  state?.destroy();
}
