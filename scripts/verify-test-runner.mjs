// Keep deliberately failing runner controls separate from Scribe's normal specs.
// Every subprocess has a deadline, including non-yielding Luau code.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { stripVTControlCharacters } from "node:util";

const root = fileURLToPath(new URL("../", import.meta.url));
const resultsDir = path.join(root, "test-results", "runner-verification");
const lune = process.env.SCRIBE_LUNE || process.env.LUNE_BIN || "lune";
mkdirSync(resultsDir, { recursive: true });
const summaryPath = path.join(resultsDir, "verification.json");
rmSync(summaryPath, { force: true });

const scenarios = [
    { name: "features", specs: "framework/JestFeatures", code: 0, passed: 8, failed: 0, suites: 1 },
    { name: "assertion", code: 1, passed: 0, failed: 1, suites: 1, text: [/SCRIBE_CONTROL_EXPECTED/, /SCRIBE_CONTROL_RECEIVED/] },
    { name: "binary-diff", code: 1, passed: 0, failed: 1, suites: 1, text: [/SCRIBE_CONTROL_BINARY_POSITIVE_CASES_PASSED/, /(?:offset|byte)\s*[:=]?\s*1/i, /0x80|128/, /0x81|129/] },
    { name: "load-error", code: 1, passed: 0, failed: 0, suites: 1, runtimeErrors: 1, text: [/SCRIBE_CONTROL_LOAD_ERROR/] },
    { name: "timeout", code: 1, passed: 0, failed: 1, suites: 1, text: [/Exceeded timeout/] },
    { name: "cleanup", code: 1, passed: 1, failed: 1, suites: 1, text: [/SCRIBE_CONTROL_SETUP_ERROR/, /SCRIBE_CONTROL_CLEANUP_RAN:2/, /SCRIBE_CONTROL_AFTER_ALL:2/] },
    { name: "cleanup-order", code: 0, passed: 1, failed: 0, suites: 1, text: [/SCRIBE_CONTROL_USER_CLEANUP_RETAINED_MOCKS_AND_TIMERS/] },
    { name: "timeout-scope", code: 1, passed: 1, failed: 1, suites: 1, text: [/Exceeded timeout/, /SCRIBE_CONTROL_SCOPE_RESOURCES_ACQUIRED/, /SCRIBE_CONTROL_SCOPE_TIMEOUT_CLEANUP_PROVEN/] },
    { name: "before-all-timeout-scope", code: 1, passed: 1, failed: 2, suites: 1, text: [/Exceeded timeout/, /SCRIBE_CONTROL_SHARED_CAPTURE_RELEASED/, /SCRIBE_CONTROL_SHARED_CAPTURE_ONCE_PROVEN/] },
    { name: "scope-cleanup-errors", code: 1, passed: 0, failed: 1, suites: 1, text: [/SCRIBE_CONTROL_SCOPE_ORIGINAL_BODY_ERROR/, /SCRIBE_CONTROL_SCOPE_CLEANUP_TWO/, /SCRIBE_CONTROL_SCOPE_CLEANUP_THREE/, /SCRIBE_CONTROL_SCOPE_RETRY_AND_IDEMPOTENCE_PROVEN/] },
    { name: "constructor-cleanup-timeout", code: 1, passed: 0, failed: 1, suites: 1, text: [/Exceeded timeout/, /SCRIBE_CONTROL_CONSTRUCTOR_TIMEOUT_RESOURCES_ACQUIRED/, /SCRIBE_CONTROL_CONSTRUCTOR_RESTORED_BEFORE_DRAIN_TIMEOUT/, /SCRIBE_CONTROL_CONSTRUCTOR_TIMEOUT_RETRY_RELEASED_ONCE/] },
    { name: "slow-scoped-success", timeout: "0.1", code: 0, passed: 1, failed: 0, suites: 1, text: [/SCRIBE_CONTROL_SLOW_SCOPED_SUCCESS_RELEASED/] },
    { name: "live-registration", testName: "^SCRIBE_CONTROL_LIVE_REGISTRATION$", code: 0, passed: 1, failed: 0, pending: 18, suites: 1, text: [/SCRIBE_CONTROL_LIVE_REGISTRATION_WITHOUT_CLOUD_OPERATIONS/], absent: /SCRIBE_CONTROL_LIVE_BACKEND_BODY_RAN/ },
    { name: "test-cleanup", code: 1, passed: 0, failed: 1, suites: 1, text: [/SCRIBE_CONTROL_BODY_ERROR/, /SCRIBE_CONTROL_CLEANUP_ERROR/] },
    { name: "after-all", code: 1, passed: 1, failed: 0, suites: 1, runtimeErrors: 1, text: [/SCRIBE_CONTROL_AFTER_ALL_ERROR/] },
    { name: "body-after-all", code: 1, passed: 0, failed: 1, suites: 1, runtimeErrors: 1, text: [/SCRIBE_CONTROL_TEST_BODY_ERROR/, /SCRIBE_CONTROL_SUITE_CLEANUP_ERROR/] },
    { name: "promise-rejection", code: 1, passed: 0, failed: 1, suites: 1, text: [/SCRIBE_CONTROL_ASYNC_REJECTION/] },
    { name: "assertion-count", code: 1, passed: 0, failed: 1, suites: 1, text: [/Expected one assertion|Expected 1 assertion/i] },
    { name: "empty", specs: "__NO_SUCH_SCRIBE_SPEC__", code: 1, text: [/No tests (found|selected|ran)|No spec|no.*match/i] },
    { name: "empty-name", specs: "framework/JestFeatures", testName: "__NO_SUCH_SCRIBE_TEST__", code: 1, text: [/No tests matched SCRIBE_TEST_NAME/] },
    { name: "focus", code: 1, text: [/Focused tests are forbidden/] },
    { name: "focus-alias", code: 1, text: [/Focused tests are forbidden/] },
    { name: "focus-concurrent", code: 1, text: [/Focused tests are forbidden/], absent: /SCRIBE_CONTROL_FOCUSED_BODY_RAN/ },
    { name: "focus-failing", code: 1, text: [/Focused tests are forbidden/], absent: /SCRIBE_CONTROL_FOCUSED_BODY_RAN/ },
    { name: "snapshot-missing", code: 1, passed: 0, failed: 1, suites: 1, text: [/New snapshot was not written/] },
    { name: "snapshot-mismatch", code: 1, passed: 0, failed: 1, suites: 1, text: [/SCRIBE_CONTROL_SNAPSHOT_EXPECTED/, /SCRIBE_CONTROL_SNAPSHOT_RECEIVED/] },
    { name: "snapshot-ci-update", specs: "framework/JestFeatures", ciUpdate: true, code: 1, text: [/snapshot.*CI|CI.*snapshot/i] },
    { name: "malformed-timeout", specs: "framework/JestFeatures", timeout: "not-a-number", code: 1, text: [/SCRIBE_TEST_TIMEOUT/] },
    { name: "hang", deadlineMs: 3_000, externalTimeout: true, text: [/SCRIBE_CONTROL_HANG_ENTERED/] },
];

function terminateTree(child) {
    if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
    if (process.platform === "win32") {
        // Kill descendants too: a Rokit launcher may have started a separate Lune process.
        spawnSync("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"], {
            windowsHide: true, stdio: "ignore", timeout: 5_000,
        });
        child.kill("SIGKILL");
    } else {
        try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); }
    }
}

function execute(scenario, reportDir) {
    const env = { ...process.env };
    for (const name of ["SCRIBE_SPECS", "SCRIBE_TEST_NAME", "SCRIBE_TEST_CONTROLS", "SCRIBE_TEST_TIMEOUT", "SCRIBE_TEST_REPORT_DIR", "SCRIBE_UPDATE_SNAPSHOTS"]) delete env[name];
    env.SCRIBE_TEST_REPORT_DIR = reportDir;
    env.SCRIBE_TEST_TIMEOUT = scenario.timeout || "10";
    if (scenario.testName) env.SCRIBE_TEST_NAME = scenario.testName;
    if (scenario.ciUpdate) {
        env.CI = "true";
        env.SCRIBE_UPDATE_SNAPSHOTS = "1";
    }
    if (scenario.specs) env.SCRIBE_SPECS = scenario.specs;
    else env.SCRIBE_TEST_CONTROLS = scenario.name;

    return new Promise((resolve) => {
        const started = performance.now();
        const child = spawn(lune, ["run", "lune/run-tests"], {
            cwd: root, env, windowsHide: true, detached: process.platform !== "win32",
            stdio: ["ignore", "pipe", "pipe"],
        });
        let output = "";
        let error;
        let timedOut = false;
        let overflow = false;
        const collect = (data) => {
            if (overflow) return;
            output += data.toString("utf8");
            if (output.length > 8 * 1024 * 1024) {
                overflow = true;
                terminateTree(child);
            }
        };
        child.stdout.on("data", collect);
        child.stderr.on("data", collect);
        child.on("error", (err) => { error = err; });
        const timer = setTimeout(() => {
            timedOut = true;
            terminateTree(child);
        }, scenario.deadlineMs || 30_000);
        child.on("close", (status, signal) => {
            clearTimeout(timer);
            resolve({ status, signal, output, error, timedOut, overflow, durationSeconds: (performance.now() - started) / 1000 });
        });
    });
}

const summary = [];
for (const scenario of scenarios) {
    const reportDir = path.join(resultsDir, scenario.name);
    mkdirSync(reportDir, { recursive: true });
    const reportPath = path.join(reportDir, "results.json");
    const junitPath = path.join(reportDir, "junit.xml");
    rmSync(reportPath, { force: true });
    rmSync(junitPath, { force: true });
    const execution = await execute(scenario, reportDir);
    const output = stripVTControlCharacters(execution.output);
    writeFileSync(path.join(reportDir, "runner.log"), output);
    try {
        assert.ifError(execution.error);
        assert.equal(execution.overflow, false, "runner exceeded its output budget");
        for (const text of scenario.text || []) assert.match(output, text, `missing expected diagnostic: ${text}`);
        if (scenario.absent) assert.doesNotMatch(output, scenario.absent, "a forbidden test body executed");
        if (scenario.externalTimeout) {
            assert.equal(execution.timedOut, true, "non-yielding fixture did not reach the external deadline");
            assert.notEqual(execution.status, 0, "a terminated run must never be successful");
            if (existsSync(reportPath)) assert.equal(JSON.parse(readFileSync(reportPath, "utf8")).success, false);
        } else {
            assert.equal(execution.timedOut, false, "runner exceeded its process deadline");
            assert.equal(execution.signal, null, "runner was terminated unexpectedly");
            assert.equal(execution.status, scenario.code, "unexpected process status");
            const report = JSON.parse(readFileSync(reportPath, "utf8"));
            assert.equal(report.success, scenario.code === 0);
            assert.equal(typeof report.durationSeconds, "number");
            const junit = readFileSync(junitPath, "utf8");
            assert.match(junit, /<testsuites\b/);
            assert.match(junit, /<\/testsuites>/);
            if (scenario.passed !== undefined) {
                assert.equal(report.infrastructureError, undefined, "runner failed before returning results");
                assert.equal(report.numPassedTests, scenario.passed);
                assert.equal(report.numFailedTests, scenario.failed);
                assert.equal(report.numTotalTests, scenario.passed + scenario.failed + (scenario.pending || 0));
                assert.equal(report.numTotalTestSuites, scenario.suites);
                assert.equal(report.numPendingTests, scenario.pending || 0);
                assert.equal(report.numRuntimeErrorTestSuites, scenario.runtimeErrors || 0);
                assert.equal(report.suites.length, scenario.suites);
            }
            if (scenario.name === "test-cleanup") {
                const failures = report.suites[0].tests[0].failureMessages.join("\n");
                assert.match(failures, /SCRIBE_CONTROL_BODY_ERROR/);
                assert.match(failures, /SCRIBE_CONTROL_CLEANUP_ERROR/);
                assert.match(junit, /SCRIBE_CONTROL_BODY_ERROR/);
                assert.match(junit, /SCRIBE_CONTROL_CLEANUP_ERROR/);
                assert.match(junit, /&lt;body&gt; &amp; failure/);
                assert.doesNotMatch(junit, /<body>|<cleanup>/);
            }
            if (scenario.name === "scope-cleanup-errors") {
                const failures = report.suites[0].tests[0].failureMessages.join("\n");
                for (const diagnostic of [/SCRIBE_CONTROL_SCOPE_ORIGINAL_BODY_ERROR/, /SCRIBE_CONTROL_SCOPE_CLEANUP_TWO/, /SCRIBE_CONTROL_SCOPE_CLEANUP_THREE/]) {
                    assert.match(failures, diagnostic);
                    assert.match(junit, diagnostic);
                }
            }
            if (scenario.name === "constructor-cleanup-timeout") {
                const failures = report.suites[0].tests[0].failureMessages;
                assert.equal(failures.length, 1, "constructor cleanup produced an unexpected extra failure");
                assert.match(failures[0], /Exceeded timeout.*hook/s);
                assert.match(junit, /Exceeded timeout/);
                assert.equal((junit.match(/<failure\b/g) || []).length, 1);
                assert.doesNotMatch(junit, /<error\b/);
                for (const marker of ["RESOURCES_ACQUIRED", "RESTORED_BEFORE_DRAIN_TIMEOUT", "TIMEOUT_RETRY_RELEASED_ONCE"]) {
                    const prefix = marker === "RESOURCES_ACQUIRED" ? "SCRIBE_CONTROL_CONSTRUCTOR_TIMEOUT_" : "SCRIBE_CONTROL_CONSTRUCTOR_";
                    assert.equal(output.split(prefix + marker).length - 1, 1, `constructor proof marker repeated or missing: ${marker}`);
                }
            }
            if (scenario.name === "before-all-timeout-scope") {
                assert.equal(output.match(/SCRIBE_CONTROL_SHARED_CAPTURE_STARTED/g)?.length, 1,
                    "shared setup ran more than once after its timeout");
                const failed = report.suites[0].tests.filter((test) => test.status === "failed");
                assert.equal(failed.length, 2);
                for (const test of failed) assert.match(test.failureMessages.join("\n"), /Exceeded timeout/);
                assert.match(junit, /Exceeded timeout/);
            }
            if (scenario.name === "live-registration") {
                const tests = report.suites[0].tests;
                assert.equal(tests.filter((test) => test.status === "pending").length, 18);
                assert.equal(tests.filter((test) => test.name.startsWith("every supported shape moves, through real yields ")).length, 9);
                assert.equal(tests.filter((test) => test.name.startsWith("real backend ")).length, 4);
                assert.equal(tests.find((test) => test.status === "passed").name, "SCRIBE_CONTROL_LIVE_REGISTRATION");
                assert.equal((junit.match(/<skipped\b/g) || []).length, 18);
            }
            if (scenario.name === "binary-diff") {
                const failure = report.suites[0].tests[0].failureMessages.join("\n");
                assert.match(failure, /^[\x00-\x7F]*$/, "binary data leaked into the assertion diagnostic");
                for (const diagnostic of [/(?:offset|byte)\s*[:=]?\s*1/i, /0x80|128/, /0x81|129/]) {
                    assert.match(failure, diagnostic);
                    assert.match(junit, diagnostic);
                }
            }
            if (scenario.name === "after-all") {
                assert.equal(report.numFailedTestSuites, 1);
                assert.match(report.suites[0].failureMessage, /SCRIBE_CONTROL_AFTER_ALL_ERROR/);
                assert.match(junit, /SCRIBE_CONTROL_AFTER_ALL_ERROR/);
                assert.match(junit, /<(error|failure)\b/);
                assert.match(junit, /&lt;cleanup&gt; &amp; failure/);
            }
            if (scenario.name === "body-after-all") {
                assert.equal(report.numFailedTestSuites, 1);
                const suite = report.suites[0];
                assert.match(suite.tests[0].failureMessages.join("\n"), /SCRIBE_CONTROL_TEST_BODY_ERROR/);
                assert.match(suite.failureMessage, /SCRIBE_CONTROL_SUITE_CLEANUP_ERROR/);
                assert.match(junit, /SCRIBE_CONTROL_TEST_BODY_ERROR/);
                assert.match(junit, /SCRIBE_CONTROL_SUITE_CLEANUP_ERROR/);
                assert.match(junit, /<failure\b/);
                assert.match(junit, /&lt;body&gt; &amp; failure/);
                assert.match(junit, /&lt;cleanup&gt; &amp; failure/);
            }
            if (scenario.name === "snapshot-missing") {
                assert.equal(existsSync(path.join(root, "test/RunnerControls/snapshot-missing/__snapshots__/MissingSnapshot.spec.snap.lua")), false,
                    "ordinary test execution wrote a snapshot");
            }
        }
        summary.push({ scenario: scenario.name, verified: true, exitCode: execution.status, externallyTerminated: execution.timedOut, durationSeconds: execution.durationSeconds });
        console.log(`PASS ${scenario.name}: ${execution.timedOut ? "external deadline enforced" : `expected exit ${scenario.code}`}, ${execution.durationSeconds.toFixed(2)}s`);
    } catch (error) {
        console.error(output.slice(-12_000));
        throw new Error(`Jest runner control '${scenario.name}' did not behave as expected; see ${reportDir}`, {
            cause: new Error(error.message),
        });
    }
}
writeFileSync(summaryPath, JSON.stringify(summary, null, 2) + "\n");
console.log(`Verified ${summary.length} Jest runner scenarios; reports are in ${resultsDir}.`);
