import type { ApiEntry, Schema } from './types';

const CORE = ['Get', 'Set', 'Update', 'Clone', 'Default', 'Observe', 'Changed'];
const READ_ONLY = ['Get', 'Clone', 'Default', 'Observe', 'Changed'];
export const MUTATORS = new Set(['Set', 'Update', 'Increment', 'Decrement', 'Multiply', 'Divide', 'Toggle', 'Enable',
    'Disable', 'Insert', 'Remove', 'RemoveValue', 'Add', 'Clear']);

/** Accessor methods that make sense on a field of this shape. */
export function methodsFor(node: Schema): string[] {
    if (node.derived) return READ_ONLY;
    if (node.container === 'Array' && node.unique) return [...CORE, 'Add', 'Remove', 'Has', 'Find', 'Count', 'Clear', 'OnChildChanged'];
    if (node.container === 'Array') return [...CORE, 'Insert', 'Remove', 'RemoveValue', 'Find', 'Has', 'Count', 'Clear', 'OnInsert', 'OnRemove', 'OnChildChanged'];
    if (node.container === 'Dict') return [...CORE, 'Count', 'Clear', 'Has', 'Find', 'Remove', 'OnKeyAdded', 'OnKeyRemoved', 'OnChildChanged'];
    switch (node.type) {
        case 'int':
        case 'number': return [...CORE, 'Increment', 'Decrement', 'Min', 'Max'];
        case 'big': return [...CORE, 'Increment', 'Decrement', 'Multiply', 'Divide', 'Min', 'Max'];
        case 'boolean': return [...CORE, 'Toggle', 'Enable', 'Disable'];
        case 'flags': return [...CORE, 'Enable', 'Disable'];
        case 'table':
        case 'any': return [...CORE, 'OnChildChanged'];
        default: return CORE;
    }
}

/** True for a record or dynamic table that accepts undeclared keys. */
export function isOpen(node: Schema): boolean {
    return node.type === 'any' || (node.type === 'table' && !node.container && !(node.children && node.children.length));
}

export type Segment = { kind: 'name'; name: string; from: number; to: number } | { kind: 'index'; text: string; from: number; to: number };

/** Segments of `.Inventory[1].Id`, with offsets relative to the path text. */
export function parsePath(path: string): Segment[] {
    const segments: Segment[] = [];
    const pattern = /\.([A-Za-z_]\w*)|\[([^\]\n]*)\]/g;
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(path))) {
        if (match[1] !== undefined) segments.push({ kind: 'name', name: match[1], from: match.index + 1, to: match.index + match[0].length });
        else segments.push({ kind: 'index', text: match[2], from: match.index, to: match.index + match[0].length });
    }
    return segments;
}

export interface Resolution {
    /** The field the path reaches, or null when it walks into an untyped table. */
    node: Schema | null;
    /** A method name that ended the walk, with the segment that named it. */
    method?: { name: string; segment: Segment };
    /** The first segment that names nothing declared. */
    unknown?: { segment: Segment; parent: Schema };
    /** Segments after the method, which the walk does not interpret. */
    stoppedAt: number;
}

export function resolvePath(root: Schema, segments: Segment[], methodNames: Set<string>): Resolution {
    let node: Schema | null = root;
    for (let index = 0; index < segments.length; index++) {
        const segment = segments[index];
        if (node === null) return { node: null, stoppedAt: index };
        if (segment.kind === 'name') {
            const child = node.children?.find((entry) => entry.name === segment.name);
            if (child) { node = child; continue; }
            if (methodNames.has(segment.name)) return { node, method: { name: segment.name, segment }, stoppedAt: index + 1 };
            if (node.container === 'Dict' && node.element) { node = node.element; continue; }
            if (isOpen(node)) return { node: null, stoppedAt: index };
            return { node, unknown: { segment, parent: node }, stoppedAt: index };
        }
        if (node.container && node.element) { node = node.element; continue; }
        const literal = /^\s*["']([A-Za-z_]\w*)["']\s*$/.exec(segment.text);
        const child = literal ? node.children?.find((entry) => entry.name === literal[1]) : undefined;
        if (child) { node = child; continue; }
        return { node: null, stoppedAt: index };
    }
    return { node, stoppedAt: segments.length };
}

export function describeType(node: Schema): string {
    const bounds = (): string => {
        const parts: string[] = [];
        if (node.min !== undefined && node.max !== undefined) parts.push(`${node.min} to ${node.max}`);
        else if (node.min !== undefined) parts.push(`at least ${node.min}`);
        else if (node.max !== undefined) parts.push(`at most ${node.max}`);
        return parts.length ? ` (${parts.join(', ')})` : '';
    };
    if (node.container === 'Array' && node.unique) return `Set of ${node.element ? describeType(node.element) : 'values'}${node.maxItems ? `, up to ${node.maxItems}` : ''}`;
    if (node.container === 'Array') return `Array of ${node.element ? describeType(node.element) : 'values'}${node.maxItems ? `, up to ${node.maxItems}` : ''}`;
    if (node.container === 'Dict') return `${node.keyType === 'integer' ? 'Map with integer keys' : 'Dictionary'} of ${node.element ? describeType(node.element) : 'values'}${node.maxKeys ? `, up to ${node.maxKeys} keys` : ''}`;
    switch (node.type) {
        case 'int': return `Int${bounds()}`;
        case 'number': return `Number${bounds()}`;
        case 'big': return 'Big number';
        case 'string': return `String${node.maxLength ? ` (up to ${node.maxLength} bytes)` : ''}`;
        case 'boolean': return 'Boolean';
        case 'enum': return `Enum: ${(node.members || []).join(' | ')}`;
        case 'flags': return `Flags: ${(node.members || []).join(', ')}`;
        case 'table': return node.children && node.children.length ? `Record { ${node.children.map((child) => child.name).join(', ')} }` : 'Table';
        case 'any': return 'Table';
        default: return node.type;
    }
}

export function methodNames(api: ApiEntry[]): Set<string> {
    return new Set(api.filter((entry) => entry.class === 'Value').map((entry) => entry.name));
}

export function apiEntry(api: ApiEntry[], cls: ApiEntry['class'], name: string): ApiEntry | undefined {
    return api.find((entry) => entry.class === cls && entry.name === name);
}
