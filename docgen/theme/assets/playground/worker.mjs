// Fresh worker per run or check: user Luau has no DOM, fetch, filesystem, or JS eval binding.
import { LuauState } from './runtime/luau-web.mjs';

const CODE_LIMIT = 12000;
const OUTPUT_LIMIT = 12000;
let consumed = 0;
let truncated = false;

function output(...parts) {
  if (truncated) return;
  const text = parts.map((part) => String(part).slice(0, 2000)).join('\t');
  const remaining = OUTPUT_LIMIT - consumed;
  if (text.length > remaining) {
    postMessage({ type: 'output', text: text.slice(0, remaining) + '\n[Output limit reached]' });
    truncated = true;
    return;
  }
  consumed += text.length + 1;
  postMessage({ type: 'output', text });
}

function validate(data) {
  if (typeof data.template !== 'string' || typeof data.actions !== 'string'
    || data.template.length > CODE_LIMIT || data.actions.length > CODE_LIMIT) {
    throw new Error('The example is too large.');
  }
}

async function loadRuntime(state) {
  const response = await fetch(new URL('./runtime.luau', import.meta.url));
  if (!response.ok) throw new Error('The Scribe runtime could not be loaded.');
  const source = await response.text();
  return state.loadstring(source, 'Scribe runtime', true)();
}

// Compile errors arrive as `[string "Template"]:4: message`; line 1 is the wrapper.
async function compile(state, chunk, source, wrapper, diagnostics) {
  try {
    const [fn] = await state.loadstring(`return function(${wrapper})\n${source}\nend`, chunk, true)();
    return fn;
  } catch (error) {
    const match = /^\[string "[^"]*"\]:(\d+):\s*(.*)$/s.exec(String(error?.message || error));
    diagnostics.push({
      editor: chunk.toLowerCase(),
      line: match ? Math.max(1, Number(match[1]) - 1) : null,
      message: match ? match[2] : String(error?.message || error),
      severity: 'error',
    });
    return null;
  }
}

async function check(data) {
  let state;
  try {
    validate(data);
    state = await LuauState.createAsync({ print: () => {}, warn: () => {} });
    const [, describe] = await loadRuntime(state);
    const diagnostics = [];
    const template = await compile(state, 'Template', data.template, 'Scribe, print, warn', diagnostics);
    await compile(state, 'Actions', data.actions, 'data, Scribe, print, warn', diagnostics);
    let schema = null;
    if (template) {
      const [ok, result] = await describe(template);
      if (ok) schema = JSON.parse(result);
      else diagnostics.push({ editor: 'template', line: null, message: String(result), severity: 'error' });
    }
    postMessage({ type: 'checked', diagnostics, schema });
  } catch (error) {
    postMessage({ type: 'failure', error: String(error?.message || error).slice(0, 4000) });
  } finally {
    state?.destroy();
  }
}

async function run(data) {
  let state;
  try {
    validate(data);
    if (!['Clamp', 'Reject'].includes(data.policy)) throw new Error('The bounds policy is invalid.');
    state = await LuauState.createAsync({ print: output, warn: output });
    const [runExample] = await loadRuntime(state);
    // Start the execution deadline after loading/initializing the local runtime.
    postMessage({ type: 'ready' });
    const [template] = await state.loadstring(`return function(Scribe, print, warn)\n${data.template}\nend`, 'Template', true)();
    const [actions] = await state.loadstring(`return function(data, Scribe, print, warn)\n${data.actions}\nend`, 'Actions', true)();
    const [ok, before, after, error] = await runExample(template, actions, data.policy);
    postMessage({ type: 'result', ok, before, after, error: String(error).slice(0, 4000) });
  } catch (error) {
    postMessage({ type: 'failure', error: String(error?.message || error).slice(0, 4000) });
  } finally {
    state?.destroy();
  }
}

self.onmessage = ({ data }) => (data.type === 'check' ? check(data) : run(data));
