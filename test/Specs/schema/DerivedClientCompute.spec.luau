--!nonstrict
-- Clients compute only visible derived fields whose inputs they receive.
-- Edit-mode mocks can compute from seeded ServerOnly inputs.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Client = require(ScribeRoot.Client)
local Template = require(ScribeRoot.Internal.Template)
local Log = require(ScribeRoot.Internal.Log)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local USER = 66101

-- Mixed fields need hidden inputs; Chain uses a transmitted result.
-- Badge is computed by its owner and transmitted to watchers.
local function makeTemplate()
	return {
		XP = Scribe.Int(2),
		Heat = Scribe.Int(1),
		Suspicion = Scribe.ServerOnly(Scribe.Int(5)),
		Mixed = Scribe.Derived(Scribe.Int(0), { "Suspicion", "Heat" }, function(s, h)
			return s + h
		end),
		MixedSoft = Scribe.Derived(Scribe.Int(0), { "Suspicion", "Heat" }, function(s, h)
			return (s or 100) + h
		end),
		Chain = Scribe.Derived(Scribe.Int(0), { "MixedSoft" }, function(m)
			return (m or 0) * 10
		end),
		Echo = Scribe.ServerOnly(Scribe.Derived(Scribe.Int(0), { "XP" }, function(x)
			return x * 2
		end)),
		Threat = Scribe.ServerOnly(Scribe.Derived(Scribe.Int(0), { "Suspicion", "XP" }, function(s, x)
			return s + x
		end)),
		Secret = Scribe.ServerOnly(Scribe.Session({
			Level = Scribe.Int(5),
			Out = Scribe.Derived(Scribe.Int(0), { "Secret.Level", "XP" }, function(l, x)
				return (l or 100) + x
			end),
		})),
		Badge = Scribe.Shared(Scribe.Derived(Scribe.String(""), { "Heat" }, function(h)
			return `b{tostring(h)}`
		end)),
	}
end

local function watchIssues()
	local counts = { DERIVED_ERROR = 0 }
	local connection = Log.OnIssue:Connect(function(entry)
		if counts[entry.Code] ~= nil then
			counts[entry.Code] += 1
		end
	end)
	return counts, function()
		connection:Disconnect()
	end
end

-- Change inputs before Init; default values would hide missing recomputes.
local function make(before: ((acc: any, harness: any) -> ())?, options: { [string]: any }?)
	local harness = TestCtx.make({ Template = makeTemplate(), Options = options, AutoPump = true })
	local player, _entry, acc = harness.Join(USER)
	if before then
		before(acc, harness)
	end
	harness.Transport.LocalPlayer = player
	local client = Client.new(harness.Options, harness.Compiled)
	harness.StepUntil(function()
		return client.IsReady()
	end)
	return harness, acc, client
end

local function step(harness)
	for _ = 1, 4 do
		harness.Step()
	end
end

describe("a running client", function()
	itRunning("keeps the server's value for a field reading a ServerOnly input, and what derives from it", function()
		local harness, acc, client = make(function(server)
			server.Heat.Set(2)
		end)
		local atInit = `{client.MixedSoft.Get()},{client.Chain.Get()},{client.Mixed.Get()}`
		acc.Heat.Set(3)
		step(harness)
		local afterWrite = `{client.MixedSoft.Get()},{client.Chain.Get()},{client.Mixed.Get()}`
		local server = `{acc.MixedSoft.Get()},{acc.Chain.Get()},{acc.Mixed.Get()}`
		harness.Cleanup()
		-- Check values too, so disabling server recomputes cannot pass.
		expect(`init={atInit} after={afterWrite} server={server}`).toBe("init=7,70,7 after=8,80,8 server=8,80,8")
	end)

	itRunning("never computes a ServerOnly derived field, and logs nothing for one it cannot compute", function()
		local issues, stopWatching = watchIssues()
		local harness, acc, client = make(function(server)
			server.XP.Set(3)
			server.Heat.Set(2)
		end)
		acc.XP.Set(4)
		acc.Heat.Set(3)
		step(harness)
		local seen = `echo={tostring(client.Echo.Get())} threat={tostring(client.Threat.Get())}`
			.. ` secret={tostring(client.Secret.Get())} mixed={client.Mixed.Get()}`
		local server = `{acc.Echo.Get()},{acc.Threat.Get()},{acc.Secret.Out.Get()},{acc.Mixed.Get()}`
		harness.Cleanup()
		stopWatching()
		expect(`{seen} errors={issues.DERIVED_ERROR} server={server}`).toBe(
			"echo=nil threat=nil secret=nil mixed=8 errors=0 server=8,9,9,8"
		)
	end)

	itRunning(
		"leaves a transmitted field alone on an optimistic write, and still moves one its owner can compute",
		function()
			local harness, acc, client = make(function(server)
				server.Heat.Set(2)
				server.Suspicion.Set(10)
			end)
			client.Heat.Set(50)
			local seen = `mixed={client.MixedSoft.Get()} badge={client.Badge.Get()}`
			local server = `{acc.MixedSoft.Get()},{acc.Badge.Get()}`
			harness.Cleanup()
			-- MixedSoft waits for the server; Badge can follow the optimistic Heat write.
			expect(`{seen} server={server}`).toBe("mixed=12 badge=b50 server=12,b2")
		end
	)

	itRunning("reports an impure field to the DevMode audit, and not a pure one off a transmitted value", function()
		local calls = 0
		local template = makeTemplate()
		template.Impure = Scribe.Derived(Scribe.Int(0), { "Heat" }, function(h)
			calls += 1
			return h + calls
		end)
		local mismatched = {}
		local remove = Log.AddSink(function(entry)
			if entry.Code == "DERIVED_MISMATCH" then
				mismatched[tostring(entry.Context and entry.Context.Field)] = true
			end
		end, { Level = "Warn" })
		local harness = TestCtx.make({ Template = template, Options = { DevMode = true }, AutoPump = true })
		local player, _entry, acc = harness.Join(USER)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		acc.Heat.Set(2)
		step(harness)
		acc.Heat.Set(3)
		step(harness)
		task.wait() -- sinks are spawned, not called inline
		remove()
		harness.Cleanup()
		local fields = {}
		for field in mismatched do
			table.insert(fields, field)
		end
		table.sort(fields)
		expect(table.concat(fields, ",")).toBe("Impure")
	end)
end)

describe("a running client with a ServerStore", function()
	itRunning("keeps the server's value for a store field reading a ServerOnly store input", function()
		local issues, stopWatching = watchIssues()
		local store = {
			SHeat = Scribe.Int(1),
			SHidden = Scribe.ServerOnly(Scribe.Int(5)),
			SMixed = Scribe.Derived(Scribe.Int(0), { "SHidden", "SHeat" }, function(s, h)
				return (s or 100) + h
			end),
			SStrict = Scribe.Derived(Scribe.Int(0), { "SHidden", "SHeat" }, function(s, h)
				return s + h
			end),
			SChain = Scribe.Derived(Scribe.Int(0), { "SMixed" }, function(m)
				return (m or 0) * 10
			end),
			SLocal = Scribe.Derived(Scribe.Int(0), { "SHeat" }, function(h)
				return h * 7
			end),
		}
		local harness, _acc, client = make(function(_acc, h)
			h.Data.ServerStore.SHeat.Set(3)
		end, { ServerStore = store })
		local atInit =
			`{client.ServerStore.SMixed.Get()},{client.ServerStore.SChain.Get()},{client.ServerStore.SLocal.Get()}`
		harness.Data.ServerStore.SHeat.Set(4)
		step(harness)
		local s = client.ServerStore
		local afterWrite = `{s.SMixed.Get()},{s.SStrict.Get()},{s.SChain.Get()},{s.SLocal.Get()}`
		harness.Cleanup()
		stopWatching()
		expect(`init={atInit} after={afterWrite} errors={issues.DERIVED_ERROR}`).toBe(
			"init=8,80,21 after=9,9,90,28 errors=0"
		)
	end)
end)

describe("what stays as it was", function()
	itRunning("leaves the shared compile and the server's own recomputes untouched", function()
		-- The harness shares one compile, so client filtering must not mutate it.
		local fresh = #Template.Compile(makeTemplate(), {}).DerivedNodes
		local harness, acc = make()
		acc.XP.Set(3)
		acc.Heat.Set(2)
		local server = `{acc.Threat.Get()},{acc.Mixed.Get()},{acc.Echo.Get()},{acc.Chain.Get()}`
		local shared = #harness.Compiled.DerivedNodes
		harness.Cleanup()
		-- `fresh` comes from a compile no client has seen.
		expect(`nodes={fresh}/{shared} server={server}`).toBe("nodes=7/7 server=8,7,6,70")
	end)

	it("computes every field in edit mode, where Data.Mock may seed a ServerOnly input", function()
		local options = {
			Template = makeTemplate(),
			ProfileStoreIndex = "DerivedClientCompute",
			ProfileKeyPrefix = "PLAYER_",
			IsRunning = false,
			Banner = false,
		}
		local compiled = Template.Compile(options.Template, {})
		local client = Client.new(options, compiled)
		client.Mock({ Heat = 2 })
		client.Mock({ Suspicion = 50 })
		expect(`{client.Mixed.Get()},{client.MixedSoft.Get()},{client.Chain.Get()}`).toBe("52,52,520")
	end)
end)
