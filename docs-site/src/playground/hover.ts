import type { Extension } from '@codemirror/state';
import { hoverTooltip, type EditorView, type Tooltip } from '@codemirror/view';
import { GLOBALS } from './complete';
import { apiEntry, describeType, methodNames, parsePath, resolvePath } from './schema';
import type { ApiEntry, Schema } from './types';

const PATH = /\bdata((?:\.[A-Za-z_]\w*|\[[^\]\n]*\])*)/g;

function badgesFor(node: Schema): string[] {
    const badges: string[] = [];
    if (node.persist === false) badges.push('session');
    if (node.visibility === 'ServerOnly') badges.push('server only');
    if (node.visibility === 'Shared') badges.push('shared');
    if (node.nullable) badges.push('optional');
    if (node.derived) badges.push('derived');
    return badges;
}

function tip(from: number, to: number, title: string, body?: string, badges: string[] = []): Tooltip {
    return {
        pos: from,
        end: to,
        above: true,
        create() {
            const dom = document.createElement('div');
            dom.className = 'pg-hover';
            const heading = document.createElement('code');
            heading.className = 'pg-hover-title';
            heading.textContent = title;
            dom.append(heading);
            if (body) {
                const text = document.createElement('p');
                text.className = 'pg-hover-body';
                text.textContent = body;
                dom.append(text);
            }
            for (const label of badges) {
                const badge = document.createElement('span');
                badge.className = 'pg-badge';
                badge.textContent = label;
                dom.append(badge);
            }
            return { dom };
        },
    };
}

function entryTip(from: number, to: number, entry: ApiEntry | undefined): Tooltip | null {
    return entry ? tip(from, to, entry.signature, entry.summary || undefined) : null;
}

function wordUnder(view: EditorView, pos: number): { from: number; to: number; name: string } | null {
    const word = view.state.wordAt(pos);
    if (!word) return null;
    return { from: word.from, to: word.to, name: view.state.sliceDoc(word.from, word.to) };
}

function precededByScribe(view: EditorView, from: number): boolean {
    return view.state.sliceDoc(Math.max(0, from - 7), from) === 'Scribe.';
}

export function templateHover(api: ApiEntry[]): Extension {
    return hoverTooltip((view, pos) => {
        const word = wordUnder(view, pos);
        if (!word) return null;
        if (precededByScribe(view, word.from)) return entryTip(word.from, word.to, apiEntry(api, 'Scribe', word.name));
        if (word.name === 'Scribe') return tip(word.from, word.to, 'Scribe', 'The declarators a template is built from. Type a dot to list them.');
        if (word.name in GLOBALS) return tip(word.from, word.to, GLOBALS[word.name]);
        return null;
    }, { hoverTime: 250 });
}

export function actionsHover(api: ApiEntry[], schema: () => Schema | null): Extension {
    const methods = methodNames(api);
    return hoverTooltip((view, pos) => {
        const word = wordUnder(view, pos);
        if (!word) return null;
        const line = view.state.doc.lineAt(pos);
        PATH.lastIndex = 0;
        let match: RegExpExecArray | null;
        while ((match = PATH.exec(line.text))) {
            const start = line.from + match.index;
            if (word.from < start || word.to > start + match[0].length) continue;
            const root = schema();
            if (!root) return null;
            if (word.from === start) {
                const names = (root.children || []).map((child) => child.name).join(', ');
                return tip(word.from, word.to, 'data', names ? `Your fields: ${names}.` : 'The template declares no fields yet.');
            }
            const segments = parsePath(match[1]);
            const chainStart = start + 4;
            const index = segments.findIndex((segment) => chainStart + segment.from <= word.from && chainStart + segment.to >= word.to);
            if (index < 0) return null;
            const resolved = resolvePath(root, segments.slice(0, index + 1), methods);
            if (resolved.method) {
                const entry = apiEntry(api, 'Value', resolved.method.name) ?? apiEntry(api, 'BigValue', resolved.method.name);
                return entryTip(word.from, word.to, entry);
            }
            if (resolved.unknown) return tip(word.from, word.to, word.name, 'Not a declared field. See the Fields panel for what the template declares.');
            if (resolved.node && resolved.stoppedAt === index + 1) {
                const path = `data${match[1].slice(0, segments[index].to)}`;
                return tip(word.from, word.to, path, describeType(resolved.node), badgesFor(resolved.node));
            }
            return null;
        }
        if (precededByScribe(view, word.from)) return entryTip(word.from, word.to, apiEntry(api, 'Scribe', word.name));
        if (word.name in GLOBALS) return tip(word.from, word.to, GLOBALS[word.name]);
        return null;
    }, { hoverTime: 250 });
}
