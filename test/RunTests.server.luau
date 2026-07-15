--!nonstrict
-- Studio entry point for the Scribe test suite. Build and open the test
-- place, then press Run (F8) — TestEZ output appears in the Output window:
--
--   rojo build test.project.json -o ScribeTest.rbxlx
--
-- The same specs also run headless via `lune run lune/run-tests`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local root = ReplicatedStorage:WaitForChild("ScribeDev")
local TestEZ = require(root.DevPackages.TestEZ)

local results = TestEZ.TestBootstrap:run({ root.Test.Specs }, TestEZ.Reporters.TextReporter)

if results.failureCount > 0 then
	warn(`Scribe test suite: {results.failureCount} failure(s)`)
else
	print(`Scribe test suite: all {results.successCount} tests passed`)
end
