import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { build, root, output, sourceOutput, addonNames, addonSourcePath, cleanGenerated } from "./build-npm.mjs";

build();
execFileSync(process.env.SCRIBE_LUNE || "lune", ["run", "bundle/verify", "--staging", "dist/npm-sources", "--sources-only"], { cwd: root, stdio: "inherit" });
const stagedMap = JSON.parse(fs.readFileSync(path.join(sourceOutput, "Scribe-source-map.json"), "utf8"));
const npmCLI = process.env.SCRIBE_NPM_CLI || process.env.npm_execpath;
assert(npmCLI && /npm-cli\.js$/.test(npmCLI), "Run with npm run test:roblox-ts (or set SCRIBE_NPM_CLI to npm-cli.js).");
function packAndInstall(directory, name) {
    const report = JSON.parse(execFileSync(process.execPath, [npmCLI, "pack", "--json", "--cache", path.join(root, ".cache/npm-cache"), "--pack-destination", path.join(root, "dist")], { cwd: directory, encoding: "utf8" }));
    // npm 12 keys reports by package name; earlier versions return an array.
    const packed = (Array.isArray(report) ? report : Object.values(report))[0];
    assert(packed?.filename, "npm pack must report its archive filename");
    const installed = cleanGenerated(`node_modules/@rbxts/${name}`);
    execFileSync("tar", ["-xzf", path.join(root, "dist", packed.filename), "-C", installed, "--strip-components=1"], { cwd: root, stdio: "inherit" });
    return { packed, installed };
}

function verifyInstalledSources(installed, sourcePath, packagePath) {
    const expected = Object.entries(stagedMap.files)
        .filter(([file]) => file === sourcePath || file.startsWith(sourcePath + "/"));
    assert(expected.length > 0, `No staged modules for ${sourcePath}`);
    const mapping = JSON.parse(fs.readFileSync(path.join(installed, "Scribe-source-map.json"), "utf8"));
    const { files, ...metadata } = mapping;
    const { files: _stagedFiles, ...stagedMetadata } = stagedMap;
    assert.deepEqual(metadata, stagedMetadata, `Source map metadata drift: ${sourcePath}`);
    assert.deepEqual(Object.keys(files).sort(), expected.map(([file]) => file).sort(), `Source map scope drift: ${sourcePath}`);
    const installedModules = fs.readdirSync(installed, { recursive: true })
        .filter(file => file.endsWith(".luau"))
        .map(file => file.split(path.sep).join("/"));
    assert.deepEqual(installedModules.sort(), expected.map(([file]) => packagePath(file)).sort(), `Installed module set drift: ${sourcePath}`);
    for (const [file, entry] of expected) {
        const packedPath = packagePath(file);
        assert.deepEqual(files[file], { ...entry, packagePath: packedPath }, `Source map entry drift: ${file}`);
        assert.deepEqual(fs.readFileSync(path.join(sourceOutput, file)), fs.readFileSync(path.join(installed, packedPath)), `Staged source drift: ${file}`);
    }
}

const { packed, installed } = packAndInstall(output, "scribe");
assert(packed.files.some(file => file.path === "types/index.d.ts"));
assert(packed.files.some(file => file.path === "src/Internal/Store/ProfileStore.luau"));
assert(packed.files.some(file => file.path === "Scribe-source-map.json"));
assert(!packed.files.some(file => /^(test|scripts|node_modules|research)\//.test(file.path)), "Only distributable files belong in npm");
assert(!packed.files.some(file => file.path.includes("addons")), "Core installation must contain no addons");
assert(!JSON.parse(fs.readFileSync(path.join(installed, "package.json"), "utf8")).peerDependencies, "Core installation must not pull UI frameworks");
verifyInstalledSources(installed, "src", file => file);
for (const file of fs.readdirSync(path.join(root, "types")).filter(file => file.endsWith(".d.ts")))
    assert.deepEqual(fs.readFileSync(path.join(root, "types", file)), fs.readFileSync(path.join(installed, "types", file)), `Declaration drift: ${file}`);
for (const name of addonNames) {
    const addon = packAndInstall(path.join(root, "dist/npm-addons", name), `scribe-${name}`);
    const sourcePath = addonSourcePath(name);
    if (name === "telemetry") {
        verifyInstalledSources(addon.installed, sourcePath, file => file.slice(sourcePath.length + 1));
    } else {
        verifyInstalledSources(addon.installed, sourcePath, () => "init.luau");
    }
    assert.deepEqual(fs.readFileSync(path.join(root, `types/addons/${name}.d.ts`)), fs.readFileSync(path.join(addon.installed, "index.d.ts")), `${name} declaration drift`);
}
execFileSync(process.execPath, [path.join(root, "node_modules/roblox-ts/out/CLI/cli.js"), "-p", "tsconfig.rbxts.json", "--type", "game", "--rojo", "test/roblox-ts/default.project.json", "--includePath", "test/roblox-ts/include", "--luau"], { cwd: root, stdio: "inherit" });
const emitted = fs.readFileSync(path.join(root, "test/roblox-ts/out/runtime.luau"), "utf8");
const leaderstatsEmitted = fs.readFileSync(path.join(root, "test/roblox-ts/out/leaderstats.luau"), "utf8");
const leaderstatsRuntime = fs.readFileSync(path.join(root, "test/roblox-ts/out/leaderstats-runtime.luau"), "utf8");
assert(!leaderstatsRuntime.includes("TS."), "Leaderstats integration fixture must execute without a separate compiler helper loader");
assert(leaderstatsEmitted.includes("ScribeLeaderstats.Start(bundle.Server,"), "Leaderstats.Start must compile as a dot call");
assert(leaderstatsEmitted.includes("handle:Stop()"), "Leaderstats handle methods must receive self");
assert(leaderstatsEmitted.includes('"scribe-leaderstats"'), "Leaderstats must resolve its separate addon package");
assert(emitted.includes("data.Coins.Increment(3)"), "Accessor must compile as a dot call");
assert(emitted.includes('bundle.Client.PromptPurchase("Gold")'), "Client PromptPurchase must compile as a dot call");
assert(emitted.includes("second.Client.Boost.Active()"), "Client Active must compile as a dot call");
assert(emitted.includes("data.Coins(10)"), "Callable accessors must not receive an implicit self");
assert(emitted.includes("data.Bag[1].Quantity.Get()"), "Accessor numeric indices must not shift");
assert(emitted.includes("data.Bag.Get()[1].Quantity"), "Snapshot array indices must shift");
assert(/big:Multiply\(2\)/.test(emitted), "Big methods must receive self");
assert(!emitted.includes("TS."), "Runtime integration fixture must execute without a separate compiler helper loader");
// The Lune harness loads .luau modules under test/. Keep generated files temporary.
const helper = path.join(root, "test/Helpers/RobloxTsCompiled.luau");
const leaderstatsHelper = path.join(root, "test/Helpers/RobloxTsLeaderstats.luau");
const spec = path.join(root, "test/Specs/api/RobloxTsCompiled.spec.luau");
assert([helper, leaderstatsHelper, spec].every(file => !fs.existsSync(file)), "Refusing to overwrite existing integration fixtures");
try {
    fs.writeFileSync(helper, emitted);
    fs.writeFileSync(leaderstatsHelper, leaderstatsRuntime);
    fs.writeFileSync(spec, `return function()
 local root = script.Parent.Parent.Parent.Parent
 local run = require(root.Test.Helpers.RobloxTsCompiled)
 local runLeaderstats = require(root.Test.Helpers.RobloxTsLeaderstats)
 local makeDependencies = require(root.Test.Helpers.RobloxTsLeaderstatsDependencies)
 local make = require(root.Test.Helpers.TestCtx).make
 local Scribe = require(root.Scribe)
 local Leaderstats = require(root.Addons.Leaderstats.ScribeLeaderstats)
 describe("roblox-ts compiled consumer", function()
  it("preserves the public runtime contracts", function() run(Scribe, make) end)
  it("supports leaderstats updates and cleanup", function() runLeaderstats(Scribe, Leaderstats, make, makeDependencies) end)
 end)
end
`);
    execFileSync(process.env.SCRIBE_LUNE || "lune", ["run", "lune/run-tests"], { cwd: root, stdio: "inherit", env: { ...process.env, SCRIBE_SPECS: "api/RobloxTsCompiled" } });
} finally {
    fs.rmSync(helper, { force: true });
    fs.rmSync(leaderstatsHelper, { force: true });
    fs.rmSync(spec, { force: true });
}
console.log(`Packed ${packed.filename} and five optional addons, verified staged source bytes, executable parity, source maps and declarations, compiled installed-package imports, and executed both compiled consumers.`);
