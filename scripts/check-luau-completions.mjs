import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const options = Object.fromEntries(process.argv.slice(2).map(arg => {
    assert(arg.startsWith("--") && arg.includes("="), `Expected --option=value, got ${arg}`);
    const split = arg.indexOf("=");
    return [arg.slice(2, split), arg.slice(split + 1)];
}));
const fixture = path.join(root, "test/TypeCheckNamedParameters.luau");
const source = readFileSync(fixture, "utf8");
const uri = pathToFileURL(fixture).href;
const config = {
    platform: { type: "roblox" },
    sourcemap: { enabled: true, autogenerate: false, sourcemapFile: options.sourcemap ?? "sourcemap.json" },
    diagnostics: { workspace: false },
    completion: { autocompleteEnd: true },
};
const server = spawn(options.lsp ?? "luau-lsp", [
    "lsp", "--stdio", "--flag:LuauSolverV2=true",
    `--definitions=${path.resolve(root, options.defs ?? "globalTypes.d.luau")}`,
    "--settings=.vscode/settings.json",
], { cwd: root, stdio: ["pipe", "pipe", "pipe"] });
let stderr = "";
server.stderr.on("data", data => { stderr = (stderr + data).slice(-8000); });
let buffer = Buffer.alloc(0);
let sequence = 0;
const pending = new Map();
const send = message => {
    const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", ...message }));
    server.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    server.stdin.write(body);
};
function request(method, params) {
    return new Promise((resolve, reject) => {
        const id = ++sequence;
        const timeout = setTimeout(() => {
            pending.delete(id);
            reject(new Error(`${method} timed out.\n${stderr}`));
        }, 60000);
        pending.set(id, { resolve, reject, timeout });
        send({ id, method, params });
    });
}
function rejectPending(error) {
    for (const entry of pending.values()) {
        clearTimeout(entry.timeout);
        entry.reject(error);
    }
    pending.clear();
}
server.on("error", rejectPending);
server.on("exit", code => rejectPending(new Error(`luau-lsp exited (${code}).\n${stderr}`)));
server.stdout.on("data", data => {
    buffer = Buffer.concat([buffer, data]);
    for (;;) {
        const headerEnd = buffer.indexOf("\r\n\r\n");
        if (headerEnd < 0) return;
        const match = /Content-Length:\s*(\d+)/i.exec(buffer.subarray(0, headerEnd).toString());
        if (!match) {
            rejectPending(new Error("LSP response omitted Content-Length"));
            return;
        }
        const end = headerEnd + 4 + Number(match[1]);
        if (buffer.length < end) return;
        const message = JSON.parse(buffer.subarray(headerEnd + 4, end).toString());
        buffer = buffer.subarray(end);
        if (message.method && message.id !== undefined) {
            send({ id: message.id, result: message.method === "workspace/configuration"
                ? message.params.items.map(() => config) : null });
        } else if (message.id !== undefined && pending.has(message.id)) {
            const entry = pending.get(message.id);
            pending.delete(message.id);
            clearTimeout(entry.timeout);
            if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
            else entry.resolve(message.result);
        }
    }
});

const cases = {
    "grant-changed": "(newValue: number, oldValue: number) -> ()",
    "server-changed": "(newValue: number, oldValue: number) -> ()",
    "client-observe": "(value: number) -> ()",
    "update": "(value: number) -> number",
    "child-changed": "(key: number, newValue: string?, oldValue: string?) -> ()",
    "insert-event": "(value: string, index: number) -> ()",
    "remove-event": "(value: string, index: number) -> ()",
    "key-added": "(key: number, value: string) -> ()",
    "key-removed": "(key: number, value: string) -> ()",
    "nested-changed": "(newValue: string, oldValue: string) -> ()",
    "array-child-changed": "(newValue: string, oldValue: string) -> ()",
    "store-changed": "(newValue: number, oldValue: number) -> ()",
    "set": "(value: number, replicate: boolean?)",
    "increment": "(delta: number, tagsOrReplicate: any)",
    "insert": "(value: string, index: number?, replicate: boolean?)",
};
const probes = source.split(/\r?\n/).flatMap((line, index, lines) => {
    const marker = /-- named: ([\w-]+)/.exec(line);
    return marker ? [{ id: marker[1], line: index + 1, character: lines[index + 1].indexOf("(") + 1 }] : [];
});
try {
    assert.deepEqual(probes.map(probe => probe.id).sort(), Object.keys(cases).sort(), "LSP fixture markers drifted");
    await request("initialize", {
        processId: process.pid,
        rootUri: pathToFileURL(root).href,
        capabilities: { workspace: { configuration: true }, textDocument: { completion: { completionItem: { snippetSupport: true } } } },
    });
    send({ method: "initialized", params: {} });
    send({ method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "luau", version: 1, text: source } } });
    for (const probe of probes) {
        const result = await request("textDocument/signatureHelp", {
            textDocument: { uri }, position: { line: probe.line, character: probe.character },
        });
        const labels = result?.signatures?.map(signature => signature.label) ?? [];
        assert.equal(labels.length, 1, `${probe.id}: expected one signature, received ${JSON.stringify(labels)}`);
        assert(labels[0].includes(cases[probe.id]), `${probe.id}: expected ${cases[probe.id]}, received ${JSON.stringify(labels)}`);
    }
    let version = 1;
    const callbacks = probes.filter(probe => cases[probe.id].includes(" -> "));
    for (const probe of callbacks) {
        const lines = source.split(/\r?\n/);
        const indent = /^\s*/.exec(lines[probe.line])[0];
        const end = lines.findIndex((line, index) => index > probe.line && line === `${indent}end)`);
        assert(end > probe.line, `${probe.id}: missing callback end`);
        lines.splice(probe.line, end - probe.line + 1, `${lines[probe.line].slice(0, probe.character)}fun)`);
        send({ method: "textDocument/didChange", params: {
            textDocument: { uri, version: ++version }, contentChanges: [{ text: lines.join("\n") }],
        } });
        const result = await request("textDocument/completion", {
            textDocument: { uri }, position: { line: probe.line, character: probe.character + 3 },
        });
        const items = Array.isArray(result) ? result : result?.items ?? [];
        const completion = items.find(item => item.label === "function (anonymous autofilled)");
        assert(completion, `${probe.id}: anonymous callback completion missing`);
        const [parameters, returns] = cases[probe.id].split(" -> ");
        const expected = `function${parameters}${returns === "()" ? "" : `: ${returns}`}`;
        const actual = (completion.textEdit?.newText ?? completion.insertText ?? "")
            .replace(/\$\{\d+:([^}]+)\}/g, "$1").split("\n")[0];
        assert.equal(actual, expected, `${probe.id}: callback completion lost names or exact field types`);
    }
    console.log(`${probes.length} Luau signatures and ${callbacks.length} callback completions retain named parameters and exact field types.`);
} catch (error) {
    console.error(error.message);
    if (stderr) console.error(stderr);
    process.exitCode = 1;
} finally {
    server.kill();
}
