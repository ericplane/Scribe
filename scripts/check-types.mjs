import ts from "typescript";
import path from "node:path";
import { root } from "./build-npm.mjs";
const configPath = path.join(root, "tsconfig.types.json");
const config = ts.readConfigFile(configPath, ts.sys.readFile);
const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, root);
const program = ts.createProgram(parsed.fileNames, parsed.options);
// Check our declarations with skipLibCheck=false. Roblox's generated upstream
// declarations have independent compiler-version defects; they are not Scribe's
// declarations and are checked by their own maintainers. Never filter fixtures
// or declarations from this repository.
const allDiagnostics = [...(config.error ? [config.error] : []), ...parsed.errors, ...ts.getPreEmitDiagnostics(program)];
const diagnostics = allDiagnostics.filter(d => !d.file || !path.resolve(d.file.fileName).split(path.sep).includes("node_modules"));
if (diagnostics.length) {
    console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
        getCanonicalFileName: name => name, getCurrentDirectory: () => root, getNewLine: () => "\n",
    }));
    process.exit(1);
}
console.log(`TypeScript declarations and ${parsed.fileNames.length} fixture files passed (including expected errors).`);
if (allDiagnostics.length !== diagnostics.length) console.log(`Excluded ${allDiagnostics.length - diagnostics.length} diagnostics in upstream node_modules declarations; all Scribe declarations were checked.`);
