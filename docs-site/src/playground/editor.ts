import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap, type CompletionSource } from '@codemirror/autocomplete';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { bracketMatching, indentOnInput, indentUnit } from '@codemirror/language';
import { lintKeymap, setDiagnostics, type Diagnostic } from '@codemirror/lint';
import { highlightSelectionMatches, searchKeymap } from '@codemirror/search';
import { EditorState, Prec, type Extension } from '@codemirror/state';
import { EditorView, drawSelection, highlightActiveLine, highlightActiveLineGutter, keymap, lineNumbers, placeholder as placeholderOf } from '@codemirror/view';
import { luau, luauHighlighting } from './luau';

export interface EditorOptions {
    parent: HTMLElement;
    doc: string;
    label: string;
    placeholder?: string;
    maxLength: number;
    complete: CompletionSource;
    hover: Extension;
    onChange: () => void;
    onRun: () => void;
}

export interface Editor {
    view: EditorView;
    get: () => string;
    set: (doc: string) => void;
    diagnose: (diagnostics: Diagnostic[]) => void;
}

export function createEditor(options: EditorOptions): Editor {
    const view = new EditorView({
        parent: options.parent,
        state: EditorState.create({
            doc: options.doc,
            extensions: [
                lineNumbers(),
                highlightActiveLineGutter(),
                highlightActiveLine(),
                history(),
                drawSelection(),
                indentOnInput(),
                indentUnit.of('    '),
                EditorState.tabSize.of(4),
                bracketMatching(),
                closeBrackets(),
                highlightSelectionMatches(),
                autocompletion({ override: [options.complete], activateOnTyping: true, icons: false }),
                options.hover,
                luau,
                luauHighlighting,
                placeholderOf(options.placeholder ?? ''),
                EditorView.contentAttributes.of({ 'aria-label': options.label, spellcheck: 'false', autocapitalize: 'off' }),
                EditorState.changeFilter.of((transaction) => transaction.newDoc.length <= options.maxLength),
                // Ctrl+S has nothing to save here; run instead of opening the browser's save dialog.
                Prec.highest(keymap.of([{ key: 'Mod-Enter', run: () => { options.onRun(); return true; } }, { key: 'Mod-s', run: () => { options.onRun(); return true; } }])),
                keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...completionKeymap, ...lintKeymap, indentWithTab]),
                EditorView.updateListener.of((update) => { if (update.docChanged) options.onChange(); }),
            ],
        }),
    });
    return {
        view,
        get: () => view.state.doc.toString(),
        set: (doc) => view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: doc } }),
        diagnose: (diagnostics) => view.dispatch(setDiagnostics(view.state, diagnostics)),
    };
}
