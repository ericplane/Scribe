import type { Diagnostic } from '@codemirror/lint';
import { actionsCompletions, templateCompletions } from './complete';
import { createEditor, type Editor } from './editor';
import { actionsHover, templateHover } from './hover';
import { checkActions, checkTemplate, fromWorker } from './lint';
import { describeType } from './schema';
import type { ApiEntry, Preset, Schema, WorkerDiagnostic } from './types';

const CODE_LIMIT = 12000;
const LOAD_TIMEOUT = 15000;
const RUN_TIMEOUT = 2000;
const CHECK_TIMEOUT = 4000;
const CHECK_DELAY = 350;

interface Shared { t: string; a: string; p: 'Clamp' | 'Reject' }

function encodeShare(state: Shared): string {
    const bytes = new TextEncoder().encode(JSON.stringify(state));
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function decodeShare(hash: string): Shared | null {
    const match = /^#v1=([A-Za-z0-9_-]+)$/.exec(hash);
    if (!match) return null;
    try {
        const binary = atob(match[1].replace(/-/g, '+').replace(/_/g, '/'));
        const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
        const parsed = JSON.parse(new TextDecoder().decode(bytes)) as Partial<Shared>;
        if (typeof parsed.t !== 'string' || typeof parsed.a !== 'string') return null;
        return { t: parsed.t.slice(0, CODE_LIMIT), a: parsed.a.slice(0, CODE_LIMIT), p: parsed.p === 'Reject' ? 'Reject' : 'Clamp' };
    } catch {
        return null;
    }
}

async function start(root: HTMLElement) {
    const assets = root.dataset.assets || '';
    const element = <T extends HTMLElement>(id: string): T => {
        const found = root.querySelector<T>(`#${id}`);
        if (!found) throw new Error(`Playground markup is missing #${id}`);
        return found;
    };
    const presetSelect = element<HTMLSelectElement>('pg-preset');
    const policySelect = element<HTMLSelectElement>('pg-policy');
    const description = element<HTMLElement>('pg-description');
    const expected = element<HTMLElement>('pg-expected');
    const status = element<HTMLElement>('pg-status');
    const runButton = element<HTMLButtonElement>('pg-run');
    const stopButton = element<HTMLButtonElement>('pg-stop');
    const resetButton = element<HTMLButtonElement>('pg-reset');
    const shareButton = element<HTMLButtonElement>('pg-share');
    const before = element<HTMLElement>('pg-before');
    const after = element<HTMLElement>('pg-after');
    const output = element<HTMLElement>('pg-output');
    const fields = element<HTMLElement>('pg-fields');
    const version = element<HTMLElement>('pg-version');
    const shortcut = element<HTMLElement>('pg-shortcut');
    shortcut.textContent = /Mac|iPhone|iPad/.test(navigator.platform) ? 'Cmd+Enter' : 'Ctrl+Enter';

    const say = (message: string) => { status.textContent = message; };

    let presets: Preset[] = [];
    let api: ApiEntry[] = [];
    try {
        const [presetResponse, metadataResponse, apiResponse] = await Promise.all([
            fetch(`${assets}presets.json`), fetch(`${assets}metadata.json`), fetch(`${assets}api.json`),
        ]);
        if (!presetResponse.ok || !metadataResponse.ok || !apiResponse.ok) throw new Error('Example assets are missing.');
        presets = await presetResponse.json();
        const metadata = await metadataResponse.json();
        api = await apiResponse.json();
        version.textContent = `Scribe ${metadata.scribeVersion}. ${metadata.runtime}. Runs in your browser.`;
    } catch {
        say('The examples could not load. Reload this page, or follow the Studio examples in the guides.');
        return;
    }

    let schema: Schema | null = null;
    let workerDiagnostics: WorkerDiagnostic[] = [];
    let runner: Worker | undefined;
    let checker: Worker | undefined;
    let runDeadline: ReturnType<typeof setTimeout> | undefined;
    let checkDeadline: ReturnType<typeof setTimeout> | undefined;
    let checkTimer: ReturnType<typeof setTimeout> | undefined;
    let lines: string[] = [];
    let template!: Editor;
    let actions!: Editor;

    const refreshDiagnostics = () => {
        const templateDiagnostics: Diagnostic[] = [
            ...fromWorker(template.view.state.doc, 'template', workerDiagnostics),
            ...checkTemplate(template.view.state.doc, schema, api),
        ];
        const actionDiagnostics: Diagnostic[] = [
            ...fromWorker(actions.view.state.doc, 'actions', workerDiagnostics),
            ...checkActions(actions.view.state.doc, schema, api),
        ];
        template.diagnose(templateDiagnostics);
        actions.diagnose(actionDiagnostics);
    };

    const renderFields = () => {
        fields.replaceChildren();
        if (!schema) {
            const empty = document.createElement('p');
            empty.className = 'pg-hint';
            empty.textContent = workerDiagnostics.some((entry) => entry.editor === 'template')
                ? 'Fix the template to see its fields.'
                : 'Compiling the template...';
            fields.append(empty);
            return;
        }
        const list = document.createElement('ul');
        list.className = 'pg-field-list';
        const add = (node: Schema, depth: number, label: string) => {
            const item = document.createElement('li');
            item.style.setProperty('--depth', String(depth));
            const name = document.createElement('code');
            name.textContent = label;
            const type = document.createElement('span');
            type.className = 'pg-field-type';
            type.textContent = describeType(node);
            item.append(name, type);
            const badges: string[] = [];
            if (node.persist === false) badges.push('session');
            if (node.visibility === 'ServerOnly') badges.push('server only');
            if (node.visibility === 'Shared') badges.push('shared');
            if (node.nullable) badges.push('optional');
            if (node.derived) badges.push('derived');
            for (const text of badges) {
                const badge = document.createElement('span');
                badge.className = 'pg-badge';
                badge.textContent = text;
                item.append(badge);
            }
            list.append(item);
            for (const child of node.children || []) add(child, depth + 1, child.name || '');
            if (node.element && (node.element.children?.length)) {
                add(node.element, depth + 1, node.container === 'Array' ? '[index]' : '[key]');
            }
        };
        for (const child of schema.children || []) add(child, 0, child.name || '');
        if (!list.children.length) {
            const empty = document.createElement('p');
            empty.className = 'pg-hint';
            empty.textContent = 'The template declares no fields yet.';
            fields.append(empty);
            return;
        }
        fields.append(list);
    };

    const stopChecker = () => {
        clearTimeout(checkDeadline);
        checker?.terminate();
        checker = undefined;
    };

    const check = () => {
        stopChecker();
        try {
            checker = new Worker(`${assets}worker.mjs`, { type: 'module' });
        } catch {
            return;
        }
        const current = checker;
        checkDeadline = setTimeout(() => {
            if (checker === current) stopChecker();
        }, CHECK_TIMEOUT);
        current.onmessage = ({ data }) => {
            if (checker !== current) return;
            stopChecker();
            if (data.type === 'checked') {
                schema = data.schema;
                workerDiagnostics = data.diagnostics;
            } else {
                schema = null;
                workerDiagnostics = [{ editor: 'template', line: null, message: String(data.error), severity: 'error' }];
            }
            refreshDiagnostics();
            renderFields();
        };
        current.onerror = () => { if (checker === current) stopChecker(); };
        current.postMessage({ type: 'check', template: template.get(), actions: actions.get() });
    };

    const queueCheck = () => {
        clearTimeout(checkTimer);
        checkTimer = setTimeout(check, CHECK_DELAY);
    };

    const onChange = () => {
        refreshDiagnostics();
        queueCheck();
    };

    const setBusy = (busy: boolean) => {
        runButton.disabled = busy;
        resetButton.disabled = busy;
        shareButton.disabled = busy;
        presetSelect.disabled = busy;
        stopButton.hidden = !busy;
    };

    const stop = (message?: string) => {
        clearTimeout(runDeadline);
        runner?.terminate();
        runner = undefined;
        setBusy(false);
        for (const panel of [before, after]) {
            if (panel.textContent === 'Running...') panel.textContent = 'The run stopped before a result was available.';
        }
        if (message) say(message);
    };

    const renderAfter = (beforeText: string, afterText: string) => {
        const previous = new Set(beforeText.split('\n'));
        const fragment = document.createDocumentFragment();
        afterText.split('\n').forEach((line, index, all) => {
            if (previous.has(line)) {
                fragment.append(line);
            } else {
                const changed = document.createElement('span');
                changed.className = 'pg-changed';
                changed.textContent = line;
                fragment.append(changed);
            }
            if (index < all.length - 1) fragment.append('\n');
        });
        after.replaceChildren(fragment);
    };

    const run = () => {
        stop();
        lines = [];
        output.textContent = '';
        before.textContent = 'Running...';
        after.textContent = 'Running...';
        say('Loading the local runtime...');
        setBusy(true);
        try {
            runner = new Worker(`${assets}worker.mjs`, { type: 'module' });
        } catch {
            output.textContent = 'This browser could not create the example worker. Try a browser with WebAssembly and module worker support.';
            stop('Runtime unavailable.');
            return;
        }
        runDeadline = setTimeout(() => stop('The runtime took too long to load. Try again.'), LOAD_TIMEOUT);
        runner.onmessage = ({ data }) => {
            if (data.type === 'ready') {
                clearTimeout(runDeadline);
                say('Running your example...');
                runDeadline = setTimeout(() => {
                    after.textContent = 'The run stopped before completion.';
                    stop('Stopped after two seconds. Check for a loop or an unusually large operation.');
                }, RUN_TIMEOUT);
            } else if (data.type === 'output') {
                lines.push(data.text);
                output.textContent = lines.join('\n');
            } else if (data.type === 'result') {
                before.textContent = data.before;
                renderAfter(data.before, data.after);
                if (!data.ok) lines.push(data.error);
                output.textContent = lines.join('\n') || '(No printed output.)';
                output.classList.toggle('pg-failed', !data.ok);
                stop(data.ok ? 'Finished. Compare the snapshots below.' : 'The actions stopped with an error. Read the output below.');
            } else if (data.type === 'failure') {
                before.textContent = 'No completed result.';
                after.textContent = 'No completed result.';
                output.textContent = data.error;
                output.classList.add('pg-failed');
                stop('The example could not run. Read the error below.');
            }
        };
        runner.onerror = () => {
            output.textContent = 'The browser could not start the local Luau runtime. Reload this page, or try a browser with WebAssembly and module worker support.';
            stop('Runtime unavailable.');
        };
        try {
            runner.postMessage({ type: 'run', template: template.get(), actions: actions.get(), policy: policySelect.value });
        } catch {
            output.textContent = 'The example could not be sent to the local worker. Reload the page and try again.';
            stop('Runtime unavailable.');
        }
    };

    const clearResults = () => {
        before.textContent = 'Run the example to see its starting data.';
        after.textContent = 'Each run starts fresh.';
        output.textContent = 'Your prints and errors appear here.';
        output.classList.remove('pg-failed');
    };

    const currentPreset = () => presets.find((entry) => entry.id === presetSelect.value) || presets[0];

    const applyPreset = (preset: Preset) => {
        stop();
        template.set(preset.template);
        actions.set(preset.actions);
        policySelect.value = preset.policy;
        description.textContent = preset.description;
        expected.textContent = `With the example as written: ${preset.expected}`;
        clearResults();
        say('Ready. Edit the example, or run it as written.');
        onChange();
    };

    const share = async () => {
        const url = new URL(location.href);
        url.hash = `v1=${encodeShare({ t: template.get(), a: actions.get(), p: policySelect.value === 'Reject' ? 'Reject' : 'Clamp' })}`;
        history.replaceState(null, '', url);
        try {
            await navigator.clipboard.writeText(url.href);
            say('Link copied. It carries this template, these actions and the bounds policy.');
        } catch {
            say('The link is in the address bar. Copy it from there.');
        }
    };

    for (const preset of presets) {
        const option = document.createElement('option');
        option.value = preset.id;
        option.textContent = preset.title;
        presetSelect.append(option);
    }

    const shared = decodeShare(location.hash);
    const requested = new URLSearchParams(location.search).get('example');
    const first = presets.find((entry) => entry.id === requested) ?? presets[0];
    presetSelect.value = first.id;
    template = createEditor({
        parent: element('pg-template'), doc: shared ? shared.t : first.template, label: 'Template', maxLength: CODE_LIMIT,
        placeholder: 'return {\n    Coins = Scribe.Int(0, { Min = 0 }),\n}', complete: templateCompletions(api), hover: templateHover(api), onChange, onRun: run,
    });
    actions = createEditor({
        parent: element('pg-actions'), doc: shared ? shared.a : first.actions, label: 'Actions', maxLength: CODE_LIMIT,
        placeholder: 'data.Coins.Increment(50)\nprint(data.Coins.Get())', complete: actionsCompletions(api, () => schema), hover: actionsHover(api, () => schema), onChange, onRun: run,
    });

    runButton.addEventListener('click', run);
    stopButton.addEventListener('click', () => stop('Stopped. Run again to start with fresh data.'));
    resetButton.addEventListener('click', () => applyPreset(currentPreset()));
    shareButton.addEventListener('click', () => { void share(); });
    presetSelect.addEventListener('change', () => applyPreset(currentPreset()));
    policySelect.addEventListener('change', () => { history.replaceState(null, '', location.pathname + location.search); });
    window.addEventListener('pagehide', () => { stop(); stopChecker(); });
    root.addEventListener('keydown', (event) => {
        if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key.toLowerCase() === 's') {
            event.preventDefault();
            if (!runButton.disabled) run();
        }
    });

    if (shared) {
        policySelect.value = shared.p;
        description.textContent = 'A shared example. Choose an example from the list to start from a guided one.';
        expected.textContent = '';
        clearResults();
        say('Loaded the example from the link.');
        setBusy(false);
        onChange();
    } else {
        applyPreset(first);
        setBusy(false);
    }
}

const root = document.querySelector<HTMLElement>('[data-playground]');
if (root) void start(root);
