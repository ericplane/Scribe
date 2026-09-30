--!nonstrict
-- Studio entry point. Build test.project.json, open the place, press Run (F8),
-- then execute this from the server command bar:
-- require(game:GetService("ReplicatedStorage").ScribeDev.Test.RunTests)()
-- Jest needs the command bar's source-loading permissions.

return function(options)
	print("[Scribe tests] Preparing Jest Roblox...")
	local RunService = game:GetService("RunService")
	assert(
		RunService:IsRunning() and RunService:IsServer(),
		"Start Run (F8), then invoke Scribe tests from Studio's server command bar"
	)
	local root = game:GetService("ReplicatedStorage"):WaitForChild("ScribeDev")
	local probe = Instance.new("ModuleScript")
	local canLoadModule = pcall((debug :: any).loadmodule, probe)
	probe:Destroy()
	if not canLoadModule then
		local canReadSource = pcall(function()
			return root.Test["jest.config"].Source
		end)
		assert(canReadSource, "Jest requires script source access: invoke RunTests from Studio's server command bar")
		local canCompile, chunk = pcall(loadstring, "return true")
		assert(
			canCompile and type(chunk) == "function",
			"Jest requires loadstring: rebuild the isolated test place with ServerScriptService.LoadStringEnabled enabled"
		)
	end

	local Jest = require(root.DevPackages.Jest)
	local argv = table.clone(options or {})
	argv.ci = true
	argv.runInBand = true
	argv.passWithNoTests = false
	argv.config = "jest.config"
	print("[Scribe tests] Running engine-compatible specs; simulation-only specs will be skipped.")
	local results = Jest.runCLI(root.Test, argv, { root.Test.Specs }):expect().results
	if argv.testNamePattern and results.numPassedTests + results.numFailedTests == 0 then
		error("No tests matched testNamePattern", 0)
	end
	if not results.success or results.numTotalTests == 0 then
		error(`Scribe test suite failed: {results.numFailedTests} failed, {results.numTotalTests} discovered`, 0)
	end
	print(`[Scribe tests] PASS: {results.numPassedTests} passed, {results.numPendingTests} skipped`)
	return results
end
