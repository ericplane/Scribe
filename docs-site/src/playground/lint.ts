import type { Diagnostic } from '@codemirror/lint';
import type { Text } from '@codemirror/state';
import type { ApiEntry, EditorName, Schema, WorkerDiagnostic } from './types';
import { MUTATORS, describeType, methodNames, methodsFor, parsePath, resolvePath } from './schema';

// A missing `end` is reported past the last line; anchor it to text so it shows.
function lineRange(doc: Text, line: number | null): { from: number; to: number } {
    let number = Math.min(Math.max(line ?? 1, 1), doc.lines);
    while (number > 1 && doc.line(number).text.trim() === '') number--;
    const target = doc.line(number);
    return { from: target.from, to: target.to };
}

/** Worker errors, anchored to their line or to the field a template error names. */
export function fromWorker(doc: Text, editor: EditorName, list: WorkerDiagnostic[]): Diagnostic[] {
    return list.filter((entry) => entry.editor === editor).map((entry) => {
        let range = lineRange(doc, entry.line);
        if (entry.line === null) {
            const field = /at "([^"]+)"/.exec(entry.message)?.[1]?.split('.').pop();
            const text = doc.toString();
            const at = field ? text.search(new RegExp(`\\b${field}\\s*=`)) : -1;
            if (at >= 0) range = { from: at, to: at + field!.length };
        }
        return { ...range, severity: entry.severity, message: entry.message, source: 'Scribe' };
    });
}

function literalKind(argument: string): 'string' | 'number' | 'boolean' | 'nil' | null {
    const trimmed = argument.trim();
    if (/^(["']).*\1$/s.test(trimmed)) return 'string';
    if (/^-?\d+(\.\d+)?$/.test(trimmed)) return 'number';
    if (trimmed === 'true' || trimmed === 'false') return 'boolean';
    if (trimmed === 'nil') return 'nil';
    return null;
}

function inCommentOrString(line: string, column: number): boolean {
    const before = line.slice(0, column);
    if (before.includes('--')) return true;
    return (before.match(/"/g) || []).length % 2 === 1 || (before.match(/'/g) || []).length % 2 === 1;
}

export function checkActions(doc: Text, schema: Schema | null, api: ApiEntry[]): Diagnostic[] {
    if (!schema) return [];
    const methods = methodNames(api);
    const diagnostics: Diagnostic[] = [];
    const text = doc.toString();
    const pattern = /\bdata((?:\.[A-Za-z_]\w*|\[[^\]\n]*\])+)/g;
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(text))) {
        const line = doc.lineAt(match.index);
        if (inCommentOrString(line.text, match.index - line.from)) continue;
        const chain = match[1];
        const start = match.index + 4;
        const resolved = resolvePath(schema, parsePath(chain), methods);
        if (resolved.unknown) {
            const { segment, parent } = resolved.unknown;
            const declared = (parent.children || []).map((child) => child.name).join(', ');
            diagnostics.push({
                from: start + segment.from, to: start + segment.to, severity: 'error', source: 'Scribe',
                message: `"${segment.kind === 'name' ? segment.name : segment.text}" is not a declared field${parent.name ? ` of ${parent.name}` : ''}.${declared ? ` Declared: ${declared}.` : ''}`,
            });
            continue;
        }
        if (!resolved.node || !resolved.method) continue;
        const node = resolved.node;
        const { name, segment } = resolved.method;
        const range = { from: start + segment.from, to: start + segment.to };
        if (node.derived && MUTATORS.has(name)) {
            diagnostics.push({ ...range, severity: 'error', source: 'Scribe', message: `${node.name} is a derived field, so it is computed and cannot be written with ${name}.` });
            continue;
        }
        const allowed = methodsFor(node);
        if (!allowed.includes(name)) {
            diagnostics.push({ ...range, severity: 'warning', source: 'Scribe', message: `${name} is not a method of ${node.name || 'this field'} (${describeType(node)}). Available: ${allowed.join(', ')}.` });
            continue;
        }
        const call = /^\s*\(([^()\n]*)\)/.exec(text.slice(match.index + match[0].length));
        if (!call) continue;
        const argument = call[1].split(',')[0] ?? '';
        const kind = literalKind(argument);
        if (!kind) continue;
        const argumentRange = { from: match.index + match[0].length + call[0].indexOf(call[1]), to: match.index + match[0].length + call[0].indexOf(call[1]) + argument.length };
        const expects = (what: string) => diagnostics.push({ ...argumentRange, severity: 'error', source: 'Scribe', message: `${node.name} is ${describeType(node)}, so ${name} expects ${what}.` });
        if (['Set', 'Increment', 'Decrement'].includes(name) && (node.type === 'int' || node.type === 'number') && kind !== 'number') expects('a number');
        else if (name === 'Set' && node.type === 'string' && kind !== 'string' && !(kind === 'nil' && node.nullable)) expects('a string');
        else if (name === 'Set' && node.type === 'boolean' && kind !== 'boolean') expects('true or false');
        else if (name === 'Set' && node.type === 'enum' && kind === 'string') {
            const value = argument.trim().slice(1, -1);
            if (node.members && !node.members.includes(value)) {
                diagnostics.push({ ...argumentRange, severity: 'error', source: 'Scribe', message: `"${value}" is not a member of ${node.name}. Members: ${node.members.join(', ')}.` });
            }
        } else if (name === 'Set' && node.type === 'big' && kind !== 'number' && kind !== 'string') expects('a number or a numeric string');
    }
    return diagnostics;
}

export function checkTemplate(doc: Text, schema: Schema | null, api: ApiEntry[]): Diagnostic[] {
    if (!schema) return [];
    const methods = methodNames(api);
    const diagnostics: Diagnostic[] = [];
    const text = doc.toString();
    const seen = new Set<number>();
    const walk = (node: Schema, parentLabel: string) => {
        for (const child of node.children || []) {
            if (child.name && methods.has(child.name)) {
                const pattern = new RegExp(`\\b${child.name}\\s*=`, 'g');
                let match: RegExpExecArray | null;
                while ((match = pattern.exec(text))) {
                    if (seen.has(match.index)) continue;
                    seen.add(match.index);
                    diagnostics.push({
                        from: match.index, to: match.index + child.name.length, severity: 'warning', source: 'Scribe',
                        message: `${child.name} is also an accessor method, so ${parentLabel}.${child.name} would call the method instead of reaching this field. Choose another name.`,
                    });
                    break;
                }
            }
            if (child.children) walk(child, `${parentLabel}.${child.name}`);
            if (child.element) walk(child.element, `${parentLabel}.${child.name}[key]`);
        }
    };
    walk(schema, 'data');
    return diagnostics;
}
