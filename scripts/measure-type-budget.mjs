import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";

// Estimate the largest subtype check in each file by varying LuauSubtypingIterationLimit.
//
// usage: node scripts/measure-type-budget.mjs [--sourcemap=path] [--defs=path]
//            [--settings=path] [--lsp=path] <file> [<file> ...]
// Run it from the project root, after `rojo sourcemap`.
const options = { sourcemap: "sourcemap.json", defs: "globalTypes.d.luau", settings: ".vscode/settings.json", lsp: "luau-lsp" };
const files = [];
for (const arg of process.argv.slice(2)) {
    if (!arg.startsWith("--")) {
        files.push(arg);
        continue;
    }
    const split = arg.indexOf("=");
    assert(split > 2 && arg.slice(2, split) in options, `Expected --sourcemap, --defs, --settings or --lsp with =value, got ${arg}`);
    options[arg.slice(2, split)] = arg.slice(split + 1);
}
assert(files.length > 0, "Name at least one file to measure.");

function run(args) {
    const result = spawnSync(options.lsp, args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
    if (result.error) throw result.error;
    return `${result.stdout}${result.stderr}`;
}

const declared = /LuauSubtypingIterationLimit=(\d+)/.exec(run(["--show-flags"]));
assert(declared, "This luau-lsp does not list LuauSubtypingIterationLimit; is it too old?");
const budget = Number(declared[1]);

function fits(file, limit) {
    const output = run([
        "analyze", `--sourcemap=${options.sourcemap}`, `--defs=${options.defs}`, `--settings=${options.settings}`,
        `--flag:LuauSubtypingIterationLimit=${limit}`, file,
    ]);
    return !output.includes("too complex to typecheck");
}

const count = new Intl.NumberFormat("en-US");
for (const file of files) {
    let high = budget * 256;
    if (!fits(file, high)) {
        console.log(`${file}: still too complex at ${count.format(high)} steps, so another limit is in the way.`);
        process.exitCode = 1;
        continue;
    }
    let low = 0;
    // Probe the default limit to narrow the search.
    if (fits(file, budget)) high = budget;
    else low = budget;
    while (high - low > Math.max(1, Math.floor(high / 500))) {
        const middle = Math.floor((low + high) / 2);
        if (fits(file, middle)) high = middle;
        else low = middle;
    }
    const share = Math.round((high / budget) * 100);
    console.log(`${file}: about ${count.format(high)} of ${count.format(budget)} subtype steps (${share}% of the budget)`);
}
