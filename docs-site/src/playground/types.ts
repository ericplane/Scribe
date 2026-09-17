export interface Schema {
    name?: string;
    type: 'number' | 'int' | 'boolean' | 'string' | 'enum' | 'flags' | 'big' | 'buffer' | 'datatype' | 'table' | 'any';
    container?: 'Array' | 'Dict';
    unique?: boolean;
    keyType?: string;
    nullable?: boolean;
    timed?: boolean;
    derived?: boolean;
    persist?: boolean;
    visibility?: 'Replicated' | 'ServerOnly' | 'Shared';
    min?: number;
    max?: number;
    maxLength?: number;
    maxItems?: number;
    maxKeys?: number;
    members?: string[];
    default?: unknown;
    children?: Schema[];
    element?: Schema;
}

export interface ApiEntry {
    class: 'Scribe' | 'Value' | 'BigValue';
    name: string;
    kind: 'function' | 'method' | 'prop';
    tags: string[];
    signature: string;
    summary: string;
}

export interface Preset {
    id: string;
    title: string;
    description: string;
    policy: 'Clamp' | 'Reject';
    template: string;
    actions: string;
    expected: string;
}

export interface WorkerDiagnostic {
    editor: 'template' | 'actions';
    line: number | null;
    message: string;
    severity: 'error' | 'warning';
}

export type EditorName = 'template' | 'actions';
