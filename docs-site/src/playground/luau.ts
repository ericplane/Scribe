import { HighlightStyle, StreamLanguage, syntaxHighlighting } from '@codemirror/language';
import { lua } from '@codemirror/legacy-modes/mode/lua';
import { tags } from '@lezer/highlight';

const LUAU_KEYWORDS = new Set(['continue', 'type', 'export']);

const luauParser = {
    ...lua,
    name: 'luau',
    token(stream: Parameters<typeof lua.token>[0], state: Parameters<typeof lua.token>[1]) {
        const style = lua.token(stream, state);
        if (style === 'variable' && LUAU_KEYWORDS.has(stream.current())) return 'keyword';
        return style;
    },
};

export const luau = StreamLanguage.define(luauParser);

const palette = HighlightStyle.define([
    { tag: tags.keyword, color: 'var(--pg-keyword)' },
    { tag: tags.standard(tags.variableName), color: 'var(--pg-builtin)' },
    { tag: tags.string, color: 'var(--pg-string)' },
    { tag: tags.number, color: 'var(--pg-number)' },
    { tag: tags.comment, color: 'var(--pg-comment)', fontStyle: 'italic' },
    { tag: tags.variableName, color: 'var(--pg-text)' },
]);

export const luauHighlighting = syntaxHighlighting(palette);
