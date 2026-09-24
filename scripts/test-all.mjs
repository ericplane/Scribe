import { execFileSync } from "node:child_process";
import { root } from "./build-npm.mjs";
for (const script of ["check-public-surface", "check-types", "check-roblox-ts"])
    execFileSync(process.execPath, [`scripts/${script}.mjs`], { cwd: root, stdio: "inherit", env: process.env });
