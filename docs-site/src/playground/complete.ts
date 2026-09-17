import type { Completion, CompletionContext, CompletionResult } from '@codemirror/autocomplete';
import type { ApiEntry, Schema } from './types';
import { apiEntry, describeType, methodNames, methodsFor, parsePath, resolvePath } from './schema';

const KEYWORDS = ['local', 'function', 'if', 'then', 'else', 'elseif', 'end', 'for', 'in', 'do', 'while', 'repeat',
    'until', 'return', 'break', 'continue', 'and', 'or', 'not', 'true', 'false', 'nil'];
export const GLOBALS: Record<string, string> = {
    print: 'print(...)', pcall: 'pcall(fn, ...)', xpcall: 'xpcall(fn, handler, ...)', assert: 'assert(value, message?)',
    error: 'error(message, level?)', tostring: 'tostring(value)', tonumber: 'tonumber(value)', type: 'type(value)',
    typeof: 'typeof(value)', ipairs: 'ipairs(t)', pairs: 'pairs(t)', next: 'next(t, key?)', select: 'select(n, ...)',
    table: 'table library', string: 'string library', math: 'math library', os: 'os library', utf8: 'utf8 library',
};
const LIBRARIES: Record<string, string[]> = {
    table: ['insert', 'remove', 'concat', 'find', 'sort', 'unpack', 'pack', 'create', 'clear', 'clone', 'freeze', 'isfrozen'],
    math: ['floor', 'ceil', 'round', 'abs', 'max', 'min', 'clamp', 'sqrt', 'pow', 'random', 'fmod', 'huge', 'pi'],
    string: ['format', 'sub', 'len', 'upper', 'lower', 'rep', 'find', 'match', 'gmatch', 'gsub', 'split', 'byte', 'char'],
    os: ['time', 'clock', 'date'],
};
const OPTIONS: Record<string, string[]> = {
    Int: ['Min', 'Max'], Number: ['Min', 'Max', 'Precision'], Big: ['Min', 'Max'], String: ['MaxLength'],
    ArrayOf: ['MaxItems', 'Evict'], SetOf: ['MaxItems'], DictOf: ['MaxKeys', 'MaxKeyLength'], MapOf: ['MaxKeys', 'MaxKeyLength'],
};

function strip(signature: string, prefix: string): string {
    return signature.startsWith(prefix) ? signature.slice(prefix.length) : signature;
}

function methodCompletion(api: ApiEntry[], cls: ApiEntry['class'], name: string, boost = 0): Completion {
    const entry = apiEntry(api, cls, name);
    const separator = entry?.kind === 'method' ? ':' : '.';
    return {
        label: name,
        type: 'method',
        detail: entry ? strip(entry.signature, `${cls}${separator}${name}`) : '()',
        info: entry?.summary || undefined,
        apply: `${name}(`,
        boost,
    };
}

function keywordCompletions(): Completion[] {
    return [
        ...KEYWORDS.map((word): Completion => ({ label: word, type: 'keyword', boost: -1 })),
        ...Object.entries(GLOBALS).map(([word, detail]): Completion => ({ label: word, type: 'function', detail, boost: -1 })),
    ];
}

function libraryCompletions(context: CompletionContext): CompletionResult | null {
    const match = context.matchBefore(/\b(table|math|string|os)\.(\w*)$/);
    if (!match) return null;
    const [, library, word] = /\b(table|math|string|os)\.(\w*)$/.exec(match.text) || [];
    return {
        from: match.to - (word?.length ?? 0),
        options: (LIBRARIES[library ?? ''] || []).map((name): Completion => ({ label: name, type: 'function' })),
        validFor: /^\w*$/,
    };
}

function wordCompletions(context: CompletionContext, extra: Completion[]): CompletionResult | null {
    const word = context.matchBefore(/[A-Za-z_]\w*$/);
    if (!word || (word.from === word.to && !context.explicit)) return null;
    return { from: word.from, options: [...extra, ...keywordCompletions()], validFor: /^\w*$/ };
}

export function templateCompletions(api: ApiEntry[]): (context: CompletionContext) => CompletionResult | null {
    const declarators = api.filter((entry) => entry.class === 'Scribe' && !['Short', 'SetShortSuffixes'].includes(entry.name));
    return (context) => {
        const declarator = context.matchBefore(/\bScribe\.(\w*)$/);
        if (declarator) {
            const typed = /\.(\w*)$/.exec(declarator.text)?.[1] ?? '';
            return {
                from: declarator.to - typed.length,
                options: declarators.map((entry): Completion => ({
                    label: entry.name,
                    type: entry.tags.includes('Visibility') ? 'keyword' : 'function',
                    detail: strip(entry.signature, `Scribe.${entry.name}`),
                    info: entry.summary || undefined,
                    apply: `${entry.name}(`,
                })),
                validFor: /^\w*$/,
            };
        }
        // Inside `Scribe.Int(0, { M` the open table is the declarator's options.
        const before = context.state.sliceDoc(Math.max(0, context.pos - 400), context.pos);
        const open = before.lastIndexOf('{');
        if (open >= 0 && !before.slice(open).includes('}')) {
            const owner = /Scribe\.(\w+)\([^{}]*,\s*$/.exec(before.slice(0, open));
            const options = owner ? OPTIONS[owner[1]] : undefined;
            if (options) {
                const word = context.matchBefore(/[A-Za-z_]\w*$/);
                if (word || context.explicit) {
                    return {
                        from: word ? word.from : context.pos,
                        options: options.map((name): Completion => ({ label: name, type: 'property', apply: `${name} = ` })),
                        validFor: /^\w*$/,
                    };
                }
            }
        }
        return libraryCompletions(context)
            ?? wordCompletions(context, [{ label: 'Scribe', type: 'namespace', detail: 'field declarators', boost: 2 }]);
    };
}

export function actionsCompletions(api: ApiEntry[], schema: () => Schema | null): (context: CompletionContext) => CompletionResult | null {
    const methods = methodNames(api);
    const helpers = api.filter((entry) => entry.class === 'Scribe' && ['Short', 'SetShortSuffixes'].includes(entry.name));
    return (context) => {
        const path = context.matchBefore(/\bdata((?:\.[A-Za-z_]\w*|\[[^\]\n]*\])*)\.(\w*)$/);
        if (path) {
            const [, chain = '', typed = ''] = /\bdata((?:\.[A-Za-z_]\w*|\[[^\]\n]*\])*)\.(\w*)$/.exec(path.text) || [];
            const root = schema();
            if (!root) return null;
            const resolved = resolvePath(root, parsePath(chain), methods);
            if (!resolved.node || resolved.method || resolved.unknown) return null;
            const node = resolved.node;
            const fields = (node.children || []).map((child): Completion => ({
                label: child.name || '', type: 'property', detail: describeType(child), boost: 3,
            }));
            const options = [...fields, ...methodsFor(node).map((name) => methodCompletion(api, 'Value', name))];
            if (node.type === 'big') {
                for (const entry of api.filter((item) => item.class === 'BigValue')) options.push(methodCompletion(api, 'BigValue', entry.name, -2));
            }
            return { from: path.to - typed.length, options, validFor: /^\w*$/ };
        }
        const helper = context.matchBefore(/\bScribe\.(\w*)$/);
        if (helper) {
            const typed = /\.(\w*)$/.exec(helper.text)?.[1] ?? '';
            return {
                from: helper.to - typed.length,
                options: helpers.map((entry): Completion => ({
                    label: entry.name, type: 'function', detail: strip(entry.signature, `Scribe.${entry.name}`), info: entry.summary || undefined, apply: `${entry.name}(`,
                })),
                validFor: /^\w*$/,
            };
        }
        return libraryCompletions(context) ?? wordCompletions(context, [
            { label: 'data', type: 'variable', detail: 'your fields', boost: 3 },
            { label: 'Scribe', type: 'namespace', detail: 'Short and other helpers', boost: 1 },
        ]);
    };
}
