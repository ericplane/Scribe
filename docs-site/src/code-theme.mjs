// Code block themes that match the site's own syntax palette (hero and playground).
import { ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';

const KEYWORDS = ['keyword', 'storage', 'storage.type', 'keyword.control', 'keyword.operator.logical', 'keyword.operator.new', 'constant.language', 'variable.language'];
const FUNCTIONS = ['entity.name.function', 'support.function', 'variable.function', 'entity.name.type', 'support.type', 'support.class', 'entity.name.class', 'entity.name.section', 'support.type.property-name.toml', 'keyword.key.toml'];
const STRINGS = ['string', 'punctuation.definition.string', 'constant.other.symbol'];
const NUMBERS = ['constant.numeric', 'constant.character', 'constant.other'];
const PLAIN = ['variable', 'variable.other', 'variable.parameter', 'entity.name.tag', 'support.variable', 'entity.other.attribute-name', 'meta.object-literal.key', 'support.type.property-name', 'meta.brace', 'source'];
const OPERATORS = ['keyword.operator', 'punctuation'];

function theme(type, palette) {
    return new ExpressiveCodeTheme({
        name: `scribe-${type}`,
        type,
        colors: {
            'editor.background': palette.background,
            'editor.foreground': palette.text,
            'editorLineNumber.foreground': palette.muted,
            'editorLineNumber.activeForeground': palette.text,
            'editor.selectionBackground': palette.selection,
        },
        tokenColors: [
            { scope: ['comment', 'punctuation.definition.comment'], settings: { foreground: palette.comment, fontStyle: 'italic' } },
            { scope: KEYWORDS, settings: { foreground: palette.keyword } },
            { scope: OPERATORS, settings: { foreground: palette.operator } },
            { scope: STRINGS, settings: { foreground: palette.string } },
            { scope: NUMBERS, settings: { foreground: palette.number } },
            { scope: FUNCTIONS, settings: { foreground: palette.builtin } },
            { scope: PLAIN, settings: { foreground: palette.text } },
            { scope: ['markup.heading', 'markup.bold'], settings: { fontStyle: 'bold' } },
            { scope: ['markup.italic'], settings: { fontStyle: 'italic' } },
        ],
    });
}

export const dark = theme('dark', {
    background: '#0d151f', text: '#e2eaf4', muted: '#506176', comment: '#8d9cae', selection: '#34d39938',
    keyword: '#bdadf1', builtin: '#b4d7ff', string: '#9be4c4', number: '#edc88b', operator: '#bdc9d8',
});

export const light = theme('light', {
    background: '#f7fafc', text: '#293d53', muted: '#92a4b8', comment: '#61768b', selection: '#34d39942',
    keyword: '#7951b4', builtin: '#1f60a6', string: '#067550', number: '#956219', operator: '#40566d',
});

// Frames use the site's tokens, so they follow the theme switch like everything else.
export const styleOverrides = {
    borderRadius: '0.65rem',
    borderWidth: '1px',
    borderColor: 'var(--scribe-border)',
    codeBackground: 'var(--scribe-code)',
    codePaddingBlock: '0.95rem',
    codePaddingInline: '1.1rem',
    frames: {
        shadowColor: 'transparent',
        frameBoxShadowCssValue: 'none',
        editorTabBarBackground: 'var(--scribe-surface)',
        editorTabBarBorderBottomColor: 'var(--scribe-border-soft)',
        editorActiveTabBackground: 'var(--scribe-code)',
        editorActiveTabForeground: 'var(--scribe-ink)',
        editorActiveTabIndicatorTopColor: 'var(--sl-color-accent)',
        editorActiveTabIndicatorBottomColor: 'transparent',
        editorTabBorderRadius: '0.5rem',
        terminalTitlebarBackground: 'var(--scribe-surface)',
        terminalTitlebarBorderBottomColor: 'var(--scribe-border-soft)',
        terminalTitlebarForeground: 'var(--scribe-muted)',
        terminalBackground: 'var(--scribe-code)',
    },
};
