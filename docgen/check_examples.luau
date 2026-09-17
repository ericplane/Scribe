--!nonstrict
-- Run from the repository root: lune run docgen/check_examples
-- Reads executable examples directly from Markdown. Reuses the existing Roblox
-- shim, real Scribe modules, fake store, and loopback transport; no live services.
-- This validates documented behavior, not production DataStore availability or
-- Luau's static type checker. Public Scribe construction is adapted to TestCtx so
-- the tests can inject a fake store and control player joins.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local task = require("@lune/task")

local runner = fs.readFile("lune/run-tests.luau")
local boundary = "local specsFolder = root._children.Test._children.Specs"
local start = string.find(runner, boundary, 1, true)
assert(start, "The headless runner bootstrap changed; update docgen/check_examples.luau")
assert(not string.find(runner, boundary, start + 1, true), "Ambiguous headless bootstrap boundary")
local bootstrap = string.sub(runner, 1, start - 1)
	.. [[
return {
    Require = shimRequire,
    Root = root,
    Globals = baseGlobals,
    -- TestCtx's FakePlayer is deliberately a plain table. The docs use the
    -- public Data[player] shorthand, so classify these as shim Instances while
    -- preserving the fake player's existing lifecycle methods and identity.
    MarkPlayer = function(player) player[INSTANCE_MARKER] = true end,
}
]]
local host = luau.load(bootstrap, { debugName = "docs-example-bootstrap", injectGlobals = true })()
local Scribe = host.Require(host.Root.Scribe)
local TestCtx = host.Require(host.Root.Test.Helpers.TestCtx)
local Client = host.Require(host.Root.Scribe.Client)
local harnesses = {}
local passed = 0

local function blocks(name)
	local text = fs.readFile("docgen/guides/" .. name .. ".md")
	text = string.gsub(text, "\r\n", "\n")
	local out = {}
	for code in string.gmatch(text, "```lua\n(.-)\n```") do
		table.insert(out, code)
	end
	return out
end

local function execute(code, env, label)
	return luau.load(code, { debugName = label, environment = env, injectGlobals = false })()
end

local function setup(moduleCode, label)
	local env = table.clone(host.Globals)
	local output = {}
	env.print = function(...)
		table.insert(output, { ... })
	end
	env.warn = function(...)
		local parts = {}
		local args = table.pack(...)
		for index = 1, args.n do
			table.insert(parts, tostring(args[index]))
		end
		error("Unexpected warning in " .. label .. ": " .. table.concat(parts, " "))
	end

	local harness, bundle
	local adapter = setmetatable({}, {
		__index = Scribe,
		__call = function(_, options)
			assert(options.Mode == "Mock", label .. " should use Mock mode")
			harness = TestCtx.make({ Template = options.Template, Options = options, AutoPump = true })
			table.insert(harnesses, harness)
			bundle = { Server = harness.Data }
			return bundle
		end,
	})
	local players = { PlayerAdded = {} }
	local onPlayerAdded
	function players.PlayerAdded:Connect(fn)
		onPlayerAdded = fn
		return {
			Disconnect = function()
				onPlayerAdded = nil
			end,
		}
	end
	local joined = {}
	function players:GetPlayers()
		return joined
	end
	local storage = { Packages = { Scribe = adapter }, Shared = {} }
	env.game = {
		GetService = function(_, name)
			if name == "Players" then
				return players
			end
			if name == "ReplicatedStorage" then
				return storage
			end
			error("Unexpected tutorial service: " .. name)
		end,
	}
	env.require = function(value)
		assert(value == adapter or value == bundle, "Unexpected tutorial require")
		return value
	end

	local result = execute(moduleCode, env, label .. ":module")
	assert(result == bundle and harness, "The shared module must return Scribe(options)")
	storage.Shared.GameData = bundle
	storage.Shared.EmberfallData = bundle
	local player, entry, data = harness.Join(773001)
	host.MarkPlayer(player)
	table.insert(joined, player)
	harness.Transport.LocalPlayer = player
	bundle.Client = Client.new(harness.Options, harness.Compiled)

	return {
		Env = env,
		Harness = harness,
		Bundle = bundle,
		Data = data,
		Entry = entry,
		Output = output,
		JoinLater = function()
			assert(onPlayerAdded, "Server example did not connect PlayerAdded")
			local latePlayer, _, lateData = harness.Join(773002)
			host.MarkPlayer(latePlayer)
			onPlayerAdded(latePlayer)
			return lateData
		end,
	}
end

local function hasOutput(rows, label, value)
	for _, row in rows do
		if row[1] == label and row[2] == value then
			return true
		end
	end
	return false
end

local ok, err = xpcall(function()
	local intro = blocks("intro")
	assert(#intro == 3, "Getting Started executable blocks changed; update their checks")
	local first = setup(intro[1], "Getting Started")
	execute(intro[3], first.Env, "Getting Started:client")
	assert(hasOutput(first.Output, "Client coins:", 0), "Observe must print the initial balance")
	execute(intro[2], first.Env, "Getting Started:server")
	task.wait()
	first.Harness.Ctx.Replication.FlushEntry(first.Entry)
	assert(first.Data.Coins.Get() == 50, "Tutorial should grant 50 coins")
	assert(first.Data.Settings.Music.Get() == true, "Tutorial music should default to true")
	assert(hasOutput(first.Output, "Server coins:", 50), "Server output differs from the guide")
	assert(hasOutput(first.Output, "Client coins:", 50), "Client did not observe replicated coins")
	assert(first.JoinLater().Coins.Get() == 50, "Players joining after startup must receive the grant")
	passed += 1
	print("PASS: Getting Started module, server, client, and documented output")

	local commands = blocks("commands")
	assert(#commands >= 2, "The first command must include server and client code blocks")
	execute(commands[1], first.Env, "Commands:server registration")
	execute(commands[2], first.Env, "Commands:successful false result")
	first.Harness.Ctx.Replication.FlushEntry(first.Entry)
	assert(first.Data.Settings.Music.Get() == false, "The documented command must change the server setting")
	assert(first.Bundle.Client.Settings.Music.Get() == false, "The setting must replicate to the client")
	assert(hasOutput(first.Output, "Music enabled:", false), "A successful false reply must reach the success branch")

	-- Run the SAME client snippet against a real refusal. The mirror is already
	-- loaded, but a server entry that is no longer Ready must reject the command.
	first.Data.Settings.Music.Set(true)
	first.Harness.Ctx.Replication.FlushEntry(first.Entry)
	local warningRows = {}
	local refusalEnv = table.clone(first.Env)
	refusalEnv.warn = function(...)
		table.insert(warningRows, { ... })
	end
	local outputCount = #first.Output
	local previousState = first.Entry.State
	first.Entry.State = "Loading"
	local refusalOk, refusalError = pcall(execute, commands[2], refusalEnv, "Commands:request refusal")
	first.Entry.State = previousState
	assert(refusalOk, refusalError)
	assert(
		hasOutput(warningRows, "Music request could not be confirmed:", "not-ready"),
		"The documented RequestFailed branch must report the server refusal"
	)
	assert(#first.Output == outputCount, "A refused request must not print a successful setting change")
	assert(first.Data.Settings.Music.Get() == true, "A refused request must not run its handler")
	passed += 1
	print("PASS: Commands server/client examples, successful false reply, and real request refusal")

	local emberfall = blocks("emberfall")
	assert(#emberfall == 3, "Emberfall executable blocks changed; update their checks")
	local rpg = setup(emberfall[1], "Emberfall")
	local actionsEnv = table.clone(rpg.Env)
	actionsEnv.data = rpg.Data
	execute(emberfall[2], actionsEnv, "Emberfall:server actions")
	rpg.Harness.Ctx.Replication.FlushEntry(rpg.Entry)
	local clientEnv = table.clone(rpg.Env)
	clientEnv.Data = rpg.Bundle.Client
	execute(emberfall[3], clientEnv, "Emberfall:client observer")
	assert(rpg.Data.Coins.Get() == 50, "Emberfall coins should be 50")
	assert(rpg.Data.Level.Get() == 2, "Emberfall XP should derive level 2")
	assert(rpg.Data.Inventory.Emberblade.Qty.Get() == 1, "Emberblade should be created")
	assert(rpg.Data.Inventory.Emberblade.Rarity.Get() == "Common", "Item rarity should use its default")
	assert(rpg.Data.Settings.Has("Music"), "Music flag should be enabled")
	assert(hasOutput(rpg.Output, "Level:", 2), "Client should observe the computed level")
	passed += 1
	print("PASS: Emberfall template, derived level, inventory defaults, flags, and client observer")
end, debug.traceback)

for _, harness in harnesses do
	harness.Cleanup()
end
if not ok then
	warn(err)
	process.exit(1)
end
print(tostring(passed) .. " documentation examples passed")
process.exit(0)
