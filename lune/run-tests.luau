--!nonstrict
-- Unmodified Jest Roblox, with Scribe's explicit Roblox host for Lune.
-- Run wally install, then lune run lune/run-tests.
local process = require("@lune/process")
local makeHost = require("./test-host")
local writeReport = require("./test-report")

local started = os.clock()
local report = { success = false, suites = {}, numTotalTests = 0, numFailedTests = 0, numPassedTests = 0 }
local host
local ok, err = xpcall(function()
	assert(#process.args == 0, "Use SCRIBE_SPECS for file selection or SCRIBE_TEST_NAME for a Jest name pattern")
	local timeout = if process.env.SCRIBE_TEST_TIMEOUT then tonumber(process.env.SCRIBE_TEST_TIMEOUT) else 10
	assert(
		timeout and timeout > 0 and timeout < math.huge,
		"SCRIBE_TEST_TIMEOUT must be a positive finite number of seconds"
	)
	local updateSnapshots = process.env.SCRIBE_UPDATE_SNAPSHOTS == "1"
	assert(
		not updateSnapshots or not process.env.CI or process.env.CI == "false" or process.env.CI == "0",
		"Snapshot updates are forbidden in CI"
	)
	host = makeHost()
	local root = host.root
	local selected = root.Test.Specs
	local control = process.env.SCRIBE_TEST_CONTROLS
	if control then
		assert(string.match(control, "^[%w_-]+$"), "Invalid runner control name")
		selected = root.Test.RunnerControls and root.Test.RunnerControls:FindFirstChild(control)
		assert(selected, "Unknown runner control: " .. control)
	end
	local paths = {}
	local function collect(folder, prefix)
		for _, child in folder:GetChildren() do
			local path = prefix .. child.Name
			if child:IsA("ModuleScript") and string.sub(child.Name, -5) == ".spec" then
				table.insert(paths, path)
			end
			collect(child, path .. "/")
		end
	end
	collect(selected, "")
	table.sort(paths)
	local filter = process.env.SCRIBE_SPECS
	local kept = {}
	for _, path in paths do
		local include = filter == nil or filter == ""
		for fragment in string.gmatch(filter or "", "[^,]+") do
			if string.find(path, fragment, 1, true) then
				include = true
			end
		end
		if include then
			table.insert(kept, path)
		end
	end
	assert(#kept > 0, "No tests selected: check SCRIBE_SPECS")
	report.selectedSpecFiles = kept
	report.discoveredSpecFiles = #paths
	local config = host.globals.require(root.Test["jest.config"])
	-- Jest Roblox's discovery walks rootDir; its roots option is not a boundary.
	config.rootDir = selected
	config.roots = { selected }
	if filter and filter ~= "" then
		config.testMatch = {}
		for _, path in kept do
			table.insert(config.testMatch, "**/" .. path)
		end
	end
	local Jest = host.globals.require(root.DevPackages.Jest)
	host.start()
	local outcome = Jest.runCLI(root.Test, {
		config = "jest.config",
		ci = true,
		runInBand = true,
		verbose = process.env.SCRIBE_TEST_VERBOSE == "1",
		testTimeout = timeout * 1000,
		testNamePattern = process.env.SCRIBE_TEST_NAME,
		passWithNoTests = false,
		updateSnapshot = updateSnapshots,
	}, { selected }):expect()
	local results = outcome.results
	for _, field in
		{
			"numPassedTests",
			"numFailedTests",
			"numTotalTests",
			"numTotalTestSuites",
			"numPassedTestSuites",
			"numFailedTestSuites",
			"numRuntimeErrorTestSuites",
			"numPendingTests",
			"numPendingTestSuites",
			"numTodoTests",
		}
	do
		report[field] = results[field]
	end
	for _, suite in results.testResults do
		local entry = { path = tostring(suite.testFilePath), failureMessage = suite.failureMessage, tests = {} }
		if suite.testExecError then
			entry.runtimeError = suite.testExecError.stack
				or suite.testExecError.message
				or tostring(suite.testExecError)
		end
		for _, test in suite.testResults do
			table.insert(entry.tests, {
				name = test.fullName,
				status = test.status,
				duration = test.duration,
				failureMessages = test.failureMessages,
			})
		end
		table.insert(report.suites, entry)
	end
	assert(
		results.numTotalTestSuites == #kept,
		string.format(
			"Discovery mismatch: selected %d spec files but Jest reported %d",
			#kept,
			results.numTotalTestSuites
		)
	)
	assert(results.numTotalTests > 0 or results.numRuntimeErrorTestSuites > 0, "No tests ran")
	if process.env.SCRIBE_TEST_NAME then
		assert(results.numPassedTests + results.numFailedTests > 0, "No tests matched SCRIBE_TEST_NAME")
	end
	report.success = results.success
end, function(message)
	return debug.traceback(tostring(message), 2)
end)

if host then
	host.stop()
end
if not ok then
	report.infrastructureError = err
	report.success = false
	print(err)
end
report.durationSeconds = os.clock() - started
report.fragmentAll = process.env.SCRIBE_FRAGMENT_ALL == "1"
writeReport(process.env.SCRIBE_TEST_REPORT_DIR or "test-results", report)
print(
	string.format(
		"Scribe Jest %s: %d passed, %d failed, %d skipped; %d failed suites in %.2fs",
		if report.success then "PASS" else "FAIL",
		report.numPassedTests,
		report.numFailedTests,
		report.numPendingTests or 0,
		report.numFailedTestSuites or 0,
		report.durationSeconds
	)
)
process.exit(if report.success then 0 else 1)
