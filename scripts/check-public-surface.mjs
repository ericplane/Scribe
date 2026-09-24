import fs from "node:fs";
import assert from "node:assert/strict";
import ts from "typescript";

// Keep declaration coverage reviewable when the shared Luau API changes.
const source = fs.readFileSync("src/init.luau", "utf8");
const expected = new Set([...source.matchAll(/^(?:function )?Scribe\.(\w+)(?:[<(]|\s*=)/gm)].map(m => m[1]));
const declarations = ts.createSourceFile("index.d.ts", fs.readFileSync("types/index.d.ts", "utf8"), ts.ScriptTarget.Latest, true);
const actual = new Set();
function visit(node) {
    if (ts.isInterfaceDeclaration(node) && node.name.text === "ScribeModule") {
        for (const member of node.members) if (member.name && ts.isIdentifier(member.name)) actual.add(member.name.text);
    }
    ts.forEachChild(node, visit);
}
visit(declarations);
assert.deepEqual([...actual].sort(), [...expected].sort(), "Scribe runtime exports and TypeScript declarations must match");

const common = fs.readFileSync("types/common.d.ts", "utf8");
const luauTypes = fs.readFileSync("src/Types.luau", "utf8");
const logCodes = luauTypes.match(/export type LogCode =([\s\S]*?)(?=\nexport |\nlocal )/)[1];
const tsCodes = common.match(/export type LogCode =([\s\S]*?);/)[1];
const strings = text => [...text.matchAll(/"([^"]+)"/g)].map(m => m[1]).sort();
assert.deepEqual(strings(tsCodes), strings(logCodes), "Diagnostic code declarations drifted from Luau");

const api = ts.createSourceFile("api.d.ts", fs.readFileSync("types/api.d.ts", "utf8"), ts.ScriptTarget.Latest, true);
let apiMethods = 0;
for (const side of ["Server", "Client"]) {
    const runtime = fs.readFileSync(`src/${side}/init.luau`, "utf8");
    const methods = new Set([...runtime.matchAll(/^\s*function Data\.(\w+)\(/gm)].map(match => match[1]));
    const declaration = api.statements.find(statement => ts.isInterfaceDeclaration(statement) && statement.name.text === `${side}API`);
    assert(declaration, `Missing ${side}API interface`);
    const names = new Set(declaration.members.flatMap(member => member.name && ts.isIdentifier(member.name) ? [member.name.text] : []));
    for (const method of methods) assert(names.has(method), `${side}.${method} is missing from the TypeScript API`);
    apiMethods += methods.size;
}
console.log(`Public declaration coverage passed: ${actual.size} module exports, ${apiMethods} server/client methods, and ${strings(tsCodes).length} diagnostic codes.`);
