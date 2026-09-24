import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const output = path.join(root, "dist", "npm");
export const sourceOutput = path.join(root, "dist", "npm-sources");
export const addonNames = ["react", "vide", "fusion", "telemetry", "leaderstats"];

export function addonSourcePath(name) {
    assert(addonNames.includes(name), `Unknown addon: ${name}`);
    if (name === "telemetry") return "addons/telemetry/ScribeTelemetry";
    if (name === "leaderstats") return "addons/leaderstats/ScribeLeaderstats.luau";
    return `addons/ui/Scribe${name[0].toUpperCase() + name.slice(1)}.luau`;
}

function writeSourceMap(destination, mapping, sourcePath, packagePath) {
    const files = Object.fromEntries(Object.entries(mapping.files)
        .filter(([file]) => file === sourcePath || file.startsWith(sourcePath + "/"))
        .map(([file, entry]) => [file, { ...entry, packagePath: packagePath(file) }]));
    assert(Object.keys(files).length > 0, `No source mappings for ${sourcePath}`);
    fs.writeFileSync(path.join(destination, "Scribe-source-map.json"), JSON.stringify({ ...mapping, files }) + "\n");
}

// Never follow a staging-directory link or delete outside this repository.
export function cleanGenerated(relative) {
    const target = path.resolve(root, relative);
    assert(target.startsWith(root + path.sep) && target !== root);
    let current = root;
    for (const part of path.relative(root, target).split(path.sep)) {
        current = path.join(current, part);
        if (fs.existsSync(current)) assert(!fs.lstatSync(current).isSymbolicLink(), `Refusing linked output: ${current}`);
    }
    fs.rmSync(target, { recursive: true, force: true });
    fs.mkdirSync(target, { recursive: true });
    return target;
}

export function build() {
    const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
    const wallyVersion = fs.readFileSync(path.join(root, "wally.toml"), "utf8").match(/^version\s*=\s*"([^"]+)"/m)?.[1];
    const runtimeVersion = fs.readFileSync(path.join(root, "src/Internal/Version.luau"), "utf8").match(/"([0-9][^"]*)"/)?.[1];
    const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"));
    assert.equal(pkg.version, wallyVersion, "package.json and wally.toml versions must match");
    assert.equal(pkg.version, runtimeVersion, "package.json and runtime versions must match");
    assert.equal(pkg.version, lock.version, "package-lock.json version must match package.json");
    assert.equal(pkg.version, lock.packages[""].version, "Locked root package version must match package.json");
    execFileSync(process.env.SCRIBE_PYTHON || "python", ["bundle/stage.py", "--version", pkg.version, "--target", "npm"], { cwd: root, stdio: "inherit" });
    const mapping = JSON.parse(fs.readFileSync(path.join(sourceOutput, "Scribe-source-map.json"), "utf8"));
    assert.equal(mapping.version, pkg.version, "Staged sources must match the package version");
    cleanGenerated("dist/npm");
    fs.cpSync(path.join(sourceOutput, "src"), path.join(output, "src"), { recursive: true });
    for (const name of ["licenses", "LICENSE", "NOTICE", "README.md"])
        fs.cpSync(path.join(root, name), path.join(output, name), { recursive: true });
    writeSourceMap(output, mapping, "src", file => file);
    fs.mkdirSync(path.join(output, "types"));
    for (const name of fs.readdirSync(path.join(root, "types")))
        if (name.endsWith(".d.ts")) fs.copyFileSync(path.join(root, "types", name), path.join(output, "types", name));
    cleanGenerated("dist/npm-addons");
    for (const name of addonNames) {
        const dest = path.join(root, "dist/npm-addons", name);
        fs.mkdirSync(dest, { recursive: true });
        const sourcePath = addonSourcePath(name);
        if (name === "telemetry") {
            fs.cpSync(path.join(sourceOutput, sourcePath), dest, { recursive: true });
            writeSourceMap(dest, mapping, sourcePath, file => file.slice(sourcePath.length + 1));
        } else {
            fs.copyFileSync(path.join(sourceOutput, sourcePath), path.join(dest, "init.luau"));
            writeSourceMap(dest, mapping, sourcePath, () => "init.luau");
        }
        const declaration = fs.readFileSync(path.join(root, `types/addons/${name}.d.ts`), "utf8");
        fs.writeFileSync(path.join(dest, "index.d.ts"), declaration);
        for (const file of ["LICENSE", "NOTICE"]) fs.copyFileSync(path.join(root, file), path.join(dest, file));
        const peers = { "@rbxts/scribe": `^${pkg.version}` };
        if (name === "react") peers["@rbxts/react"] = "^17.0.0 || ^17.3.7-ts.2";
        if (name === "vide") peers["@rbxts/vide"] = "^0.6.1";
        // Fusion 0.3 may be supplied by another compatible package.
        if (name === "fusion") peers["@rbxts/fusion"] = "^0.2.0";
        const manifest = {
            name: `@rbxts/scribe-${name}`, version: pkg.version, description: `Optional ${name} addon for Scribe`,
            main: "init.luau", types: "index.d.ts", license: pkg.license, repository: pkg.repository,
            homepage: pkg.homepage, author: pkg.author, peerDependencies: peers,
            ...(name === "fusion" ? { peerDependenciesMeta: { "@rbxts/fusion": { optional: true } } } : {}),
            publishConfig: { access: "public" },
        };
        fs.writeFileSync(path.join(dest, "package.json"), JSON.stringify(manifest, null, 2) + "\n");
        fs.writeFileSync(path.join(dest, "README.md"), `# ${manifest.name}\n\nOptional Scribe addon. Install only if you use it.\n\nSee [the roblox-ts guide](${pkg.homepage}roblox-ts/) for usage.\n`);
    }
    const { scripts, devDependencies, private: _private, peerDependencies, peerDependenciesMeta, ...published } = pkg;
    published.main = "src/init.luau";
    published.types = "types/index.d.ts";
    published.files = ["src", "types", "licenses", "NOTICE", "Scribe-source-map.json"];
    fs.writeFileSync(path.join(output, "package.json"), JSON.stringify(published, null, 2) + "\n");
    console.log(`Assembled ${pkg.name}@${pkg.version} and ${addonNames.length} optional addon packages from staged Luau sources with source maps and full declarations.`);
    return output;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) build();
