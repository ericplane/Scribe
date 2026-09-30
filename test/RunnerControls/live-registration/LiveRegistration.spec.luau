--!nonstrict
-- Collect the real opted-in specs through Jest, but never run cloud operations.
-- The verifier selects only the sentinel below; all 18 live tests stay pending.
local Root = game:GetService("ReplicatedStorage").ScribeDev
local JestGlobals = require(Root.DevPackages.JestGlobals)
local it, expect, jest = JestGlobals.it, JestGlobals.expect, JestGlobals.jest
local settings = jest.requireActual(Root.Test.Helpers.ConformanceStore)
local storeRequests = 0
local backendOperations = 0

local function forbiddenBackendOperation()
	backendOperations += 1
	error("SCRIBE_CONTROL_LIVE_BACKEND_BODY_RAN", 0)
end

jest.mock(Root.Test.Helpers.ConformanceStore, function()
	return {
		IsReal = function()
			return true
		end,
		get = function()
			storeRequests += 1
			return { New = forbiddenBackendOperation }
		end,
		LIVE_TIMEOUT_MS = settings.LIVE_TIMEOUT_MS,
		CLEANUP_TIMEOUT_MS = settings.CLEANUP_TIMEOUT_MS,
		STORE = settings.STORE,
		PREFIX = settings.PREFIX,
		AwaitBudget = forbiddenBackendOperation,
		AwaitKeyWindow = forbiddenBackendOperation,
	}
end)

local function collectSpec(module)
	local ok, failure = pcall(require, module)
	if not ok then
		-- The test-entry loader permits no return value; normal require does not.
		-- Accept only this exact post-execution error for this target module.
		-- Unsupported Jest APIs and every other collection failure still fail here.
		local expected =
			`[Module Error]: {module.Name} did not return a valid result\n\tModuleScripts must return exactly one value`
		if string.sub(tostring(failure), -#expected) ~= expected then
			error(failure, 0)
		end
	end
end

collectSpec(Root.Test.Specs.exchange["ExchangeRealBackend.spec"])
collectSpec(Root.Test.Specs.persistence["RealBackend.spec"])

it("SCRIBE_CONTROL_LIVE_REGISTRATION", function()
	expect(storeRequests).toBe(2)
	expect(backendOperations).toBe(0)
	expect(settings.LIVE_TIMEOUT_MS).toBe(600000)
	expect(settings.CLEANUP_TIMEOUT_MS).toBe(60000)
	print("SCRIBE_CONTROL_LIVE_REGISTRATION_WITHOUT_CLOUD_OPERATIONS")
end)
