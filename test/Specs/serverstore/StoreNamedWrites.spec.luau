--!nonstrict
-- Reject writes to foreign roots, reserved data and derived fields, including Remove.
-- Root Update must reject before calling user code.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Client = require(ScribeRoot.Client)
local Node = require(ScribeRoot.Internal.Node)
local Template = require(ScribeRoot.Internal.Template)
local Log = require(ScribeRoot.Internal.Log)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local USER = 65101
local STORE_MESSAGE = "Data.ServerStore."
local PLAYER_MESSAGE = "per-player root"

local function shape(data: { [string]: any }?): string
	if data == nil then
		return "<none>"
	end
	local parts = {}
	for key, value in data do
		table.insert(parts, `{key}={if type(value) == "table" then "tbl" else tostring(value)}`)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function keys(set: { [string]: any }?): string
	if set == nil then
		return "nil"
	end
	local out = {}
	for key in set do
		table.insert(out, key)
	end
	table.sort(out)
	return `[{table.concat(out, ",")}]`
end

-- Match the refusal reason and caller location; unrelated errors must fail.
local function attempt(needles: { string }, fn: () -> ()): string
	local ok, err = pcall(fn)
	if ok then
		return "ok"
	end
	local text = tostring(err)
	for _, needle in needles do
		if not string.find(text, needle, 1, true) then
			return text
		end
	end
	if not string.find(text, "StoreNamedWrites", 1, true) then
		return `unblamed: {text}`
	end
	return "refused"
end

local function storeTemplate(calls: { string })
	return {
		Biome = Scribe.Int(1),
		BiomeName = Scribe.Derived(Scribe.String(""), { "Biome" }, function(biome)
			table.insert(calls, tostring(biome))
			return `biome{tostring(biome)}`
		end),
		World = { Level = Scribe.Int(3) },
	}
end

-- Seed a profile, join it, then deliver Init to its client.
local function make(seed: { [string]: any }?, extra: { [string]: any }?)
	local calls = {}
	local options: { [string]: any } = { ServerStore = storeTemplate(calls) }
	for key, value in extra or {} do
		options[key] = value
	end
	local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0) }, Options = options, AutoPump = true })
	if seed ~= nil then
		harness.Fake.Persisted[`Default/PLAYER_{USER}`] = seed
	end
	local player, entry, acc = harness.Join(USER)
	harness.Transport.LocalPlayer = player
	local client = Client.new(harness.Options, harness.Compiled)
	harness.StepUntil(function()
		return client.IsReady()
	end)
	table.clear(calls)
	return {
		Harness = harness,
		Player = player,
		Entry = entry,
		Acc = acc,
		Client = client,
		Calls = calls,
	}
end

local function settle(world)
	for _ = 1, 4 do
		world.Harness.Step()
	end
end

--- Everything a stray write could touch, after the frames have gone out.
local function observe(world): string
	settle(world)
	local client = world.Client
	return `live={shape(world.Entry.LiveData)} dirty={tostring(world.Entry.SaveInfo.Dirty)}`
		.. ` client={client.ServerStore.Biome.Get()},{tostring(client.ServerStore.BiomeName.Get())},{client.ServerStore.World.Level.Get()}`
		.. ` server={world.Harness.Data.ServerStore.Biome.Get()} calls=[{table.concat(world.Calls, " ")}]`
end

local PRISTINE = "live=Coins=0,_Scribe=tbl dirty=false client=1,biome1,3 server=1 calls=[]"

describe("which roots each view refuses", function()
	it("gives each view the roots the other one holds, and the full compile none", function()
		local compiled = Template.Compile({ Coins = Scribe.Int(0) }, { ServerStore = storeTemplate({}) })
		local storeless = Template.Compile({ Coins = Scribe.Int(0) }, {})
		expect(
			`full={keys(compiled.ForeignRoots)} player={keys(compiled.Views.Player.ForeignRoots)}`
				.. ` store={keys(compiled.Views.Store.ForeignRoots)} storeless={keys(
					storeless.Views.Player.ForeignRoots
				)}`
		).toBe("full=nil player=[Biome,BiomeName,World] store=[Coins,_Scribe,_ScribeSession] storeless=nil")
	end)
end)

describe("a player tree", function()
	itRunning("refuses to write under a store root's name, and nothing reaches the client", function()
		local world = make()
		local byChild = attempt({ "Data.ServerStore.Biome", "migration" }, function()
			world.Acc.Child("Biome").Set(9)
		end)
		local byIndex = attempt({ "Data.ServerStore.Biome" }, function()
			world.Acc.Biome.Increment(1)
		end)
		local seen = observe(world)
		world.Harness.Cleanup()
		expect(`child={byChild} index={byIndex} {seen}`).toBe(`child=refused index=refused {PRISTINE}`)
	end)

	itRunning("refuses every mutator, not a hand-picked few", function()
		local world = make()
		local names = {}
		for name in Node.MUTATOR_METHODS do
			table.insert(names, name)
		end
		table.sort(names)
		local notRefused = {}
		for _, name in names do
			local result = attempt({ STORE_MESSAGE }, function()
				local _ = world.Acc.Child("Biome")[name]
			end)
			if result ~= "refused" then
				table.insert(notRefused, `{name}:{result}`)
			end
		end
		local seen = observe(world)
		world.Harness.Cleanup()
		expect(`count={#names} notRefused=[{table.concat(notRefused, ";")}] {seen}`).toBe(
			`count=16 notRefused=[] {PRISTINE}`
		)
	end)

	itRunning("refuses a path below a store root, not only the root itself", function()
		local world = make()
		local refused = attempt({ "Data.ServerStore.World" }, function()
			world.Acc.Child("World").Child("Level").Set(7)
		end)
		local seen = observe(world)
		world.Harness.Cleanup()
		expect(`{refused} {seen}`).toBe(`refused {PRISTINE}`)
	end)

	itRunning("refuses Update before its function runs, so nothing is edited in place", function()
		local world = make({ Coins = 0, World = { Level = 5 } })
		local ran = false
		local refused = attempt({ "Data.ServerStore.World" }, function()
			world.Acc.Child("World").Update(function(current)
				ran = true
				current.Level = 7
				return current
			end)
		end)
		settle(world)
		local level = world.Entry.LiveData.World.Level
		local dirty = world.Entry.SaveInfo.Dirty
		world.Harness.Cleanup()
		expect(`{refused} ran={tostring(ran)} level={level} dirty={tostring(dirty)}`).toBe(
			"refused ran=false level=5 dirty=false"
		)
	end)

	itRunning("refuses to remove a stray copy an earlier version saved, by Set(nil) or by Remove", function()
		-- Stray keys remain readable for cleanup but cannot change the client store.
		local world = make({ Coins = 4, Biome = 5, BiomeName = "stray" })
		local read = `{world.Acc.Child("Biome").Get()},{world.Acc.Child("BiomeName").Get()}`
		local results = {
			attempt({ "Data.ServerStore.BiomeName", "migration" }, function()
				world.Acc.Child("BiomeName").Set(nil)
			end),
			attempt({ "Data.ServerStore.BiomeName" }, function()
				world.Acc.Remove("BiomeName")
			end),
			attempt({ "Data.ServerStore.Biome" }, function()
				world.Acc.Remove("Biome")
			end),
		}
		local seen = observe(world)
		world.Harness.Cleanup()
		expect(`read={read} {table.concat(results, ",")} {seen}`).toBe(
			"read=5,stray refused,refused,refused live=Biome=5,BiomeName=stray,Coins=4,_Scribe=tbl dirty=false"
				.. " client=1,biome1,3 server=1 calls=[]"
		)
	end)

	itRunning("refuses inside a transaction, which rolls the rest of it back", function()
		local world = make()
		local ok, why = world.Harness.Data.Transaction(world.Player, function()
			world.Acc.Coins.Increment(1)
			world.Acc.Child("Biome").Increment(1)
		end)
		local named = string.find(tostring(why), STORE_MESSAGE, 1, true) ~= nil
		settle(world)
		-- Rollback emits can mark Dirty; assert the values instead.
		local client = world.Client
		local seen = `coins={world.Acc.Coins.Get()} live={shape(world.Entry.LiveData)}`
			.. ` client={client.ServerStore.Biome.Get()},{client.ServerStore.BiomeName.Get()},{client.Coins.Get()}`
		world.Harness.Cleanup()
		expect(`ok={tostring(ok)} named={tostring(named)} {seen}`).toBe(
			"ok=false named=true coins=0 live=Coins=0,_Scribe=tbl client=1,biome1,0"
		)
	end)
end)

describe("the store tree", function()
	itRunning("refuses to write under a per-player root's name, which every client would apply", function()
		-- Use the internal tree accessor to test the store-side guard.
		local world = make()
		local storeAcc = world.Harness.Ctx.ServerStore.Accessor
		local results = {
			attempt({ PLAYER_MESSAGE, "Coins" }, function()
				storeAcc.Child("Coins").Set(4)
			end),
			-- The reserved-root refusal takes priority on either tree.
			attempt({ "reserved", "_ScribeSession" }, function()
				storeAcc.Child("_ScribeSession").Child("Probe").Set(1)
			end),
		}
		settle(world)
		local seen = `store={shape(world.Harness.Ctx.ServerStore.Data)} client={world.Client.Coins.Get()}`
		world.Harness.Cleanup()
		expect(`{table.concat(results, ",")} {seen}`).toBe(
			"refused,refused store=Biome=1,BiomeName=biome1,World=tbl client=0"
		)
	end)
end)

describe("Remove(key) meets the same refusals as the field's own mutators", function()
	itRunning("refuses the root accessor's Remove of the reserved ledger", function()
		local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0) }, AutoPump = true })
		local _player, entry, acc = harness.Join(USER)
		local before = shape(entry.LiveData._Scribe)
		local refused = attempt({ "reserved", "_Scribe" }, function()
			acc.Remove("_Scribe")
		end)
		local after = shape(entry.LiveData._Scribe)
		local dirty = entry.SaveInfo.Dirty
		harness.Cleanup()
		expect(
			`{refused} same={tostring(before == after)} kept={tostring(string.find(after, "Version=", 1, true) ~= nil)} dirty={tostring(
				dirty
			)}`
		).toBe("refused same=true kept=true dirty=false")
	end)

	itRunning("refuses a parent's Remove of a derived field, at the root or below it", function()
		local template = {
			Coins = Scribe.Int(3),
			Label = Scribe.Derived(Scribe.String(""), { "Coins" }, function(coins)
				return `c{tostring(coins)}`
			end),
			Stats = Scribe.Session({
				Twice = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(coins)
					return (coins or 0) * 2
				end),
			}),
		}
		local harness = TestCtx.make({ Template = template, AutoPump = true })
		local player, _entry, acc = harness.Join(USER)
		-- Off the default, so the client's Init recomputes both fields from it.
		acc.Coins.Set(4)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local results = {
			attempt({ "derived field", "Label" }, function()
				acc.Remove("Label")
			end),
			attempt({ "derived field", "Stats.Twice" }, function()
				acc.Stats.Remove("Twice")
			end),
		}
		for _ = 1, 4 do
			harness.Step()
		end
		local seen =
			`server={acc.Label.Get()},{acc.Stats.Twice.Get()} client={client.Label.Get()},{client.Stats.Twice.Get()}`
		harness.Cleanup()
		expect(`{table.concat(results, ",")} {seen}`).toBe("refused,refused server=c4,8 client=c4,8")
	end)
end)

describe("the root accessor's Update", function()
	itRunning("refuses before its function runs, which would edit the saved table directly", function()
		-- Root Update must refuse before its callback can mutate the live profile.
		local world = make({ Coins = 4, BiomeName = "stray" })
		local ran = 0
		local results = {
			attempt({ "Update" }, function()
				world.Acc.Update(function(data)
					ran += 1
					data.Biome = 9
					data.BiomeName = nil
					return data
				end)
			end),
			attempt({ "Update" }, function()
				world.Acc.Update(function(data)
					ran += 1
					data._Scribe.ProcessedPurchaseIds = nil
				end)
			end),
			-- The callable shorthand reaches Update too, and must blame its own caller.
			attempt({ "Update" }, function()
				world.Acc(function(data)
					ran += 1
					data.Biome = 9
				end)
			end),
		}
		local live = world.Entry.LiveData
		local seen = `ran={ran} live={shape(live)} ledger={tostring(live._Scribe.ProcessedPurchaseIds ~= nil)}`
		world.Harness.Cleanup()
		expect(`{table.concat(results, ",")} {seen}`).toBe(
			"refused,refused,refused ran=0 live=BiomeName=stray,Coins=4,_Scribe=tbl ledger=true"
		)
	end)
end)

describe("a stray key at load", function()
	itRunning("is named by the DevMode unknown-root warning", function()
		local warned = {}
		local remove = Log.AddSink(function(entry)
			if entry.Code == "UNKNOWN_ROOT_KEYS" then
				table.insert(warned, tostring(entry.Context and entry.Context.Keys))
			end
		end, { Level = "Warn" })
		local world = make({ Coins = 4, BiomeName = "stray", Nope = 1 }, { DevMode = true })
		task.wait() -- sinks are spawned, not called inline
		remove()
		world.Harness.Cleanup()
		expect(table.concat(warned, ";")).toBe("BiomeName, Nope")
	end)
end)

describe("what stays as it was", function()
	itRunning("still saves a write to an undeclared root that names nothing, and its Remove", function()
		-- Check the server only; undeclared roots are absent from Init.
		local world = make({ Coins = 4, Gone = 5 })
		local wrote = attempt({ "<none>" }, function()
			world.Acc.Child("Nope").Set(9)
		end)
		local removed = world.Acc.Remove("Gone")
		settle(world)
		local seen = `live={shape(world.Entry.LiveData)} dirty={tostring(world.Entry.SaveInfo.Dirty)}`
		world.Harness.Cleanup()
		expect(`{wrote} removed={tostring(removed)} {seen}`).toBe(
			"ok removed=5 live=Coins=4,Nope=9,_Scribe=tbl dirty=true"
		)
	end)

	itRunning("still reads a stray key and still lets a listener watch it", function()
		local world = make({ Coins = 4, Biome = 5, BiomeName = "stray", World = { Level = 5 } })
		local connection = world.Acc.Child("BiomeName").Changed(function() end)
		local reads = `{world.Acc.Child("Biome").Get()}/{world.Acc.Child("BiomeName").Get()}/{world.Acc
			.Child("World")
			.Child("Level")
			.Get()}`
		connection()
		local seen = observe(world)
		world.Harness.Cleanup()
		expect(`reads={reads} {seen}`).toBe(
			"reads=5/stray/5 live=Biome=5,BiomeName=stray,Coins=4,World=tbl,_Scribe=tbl dirty=false client=1,biome1,3 server=1 calls=[]"
		)
	end)

	itRunning("still writes the store through Data.ServerStore and the player's own fields", function()
		local world = make()
		world.Harness.Data.ServerStore.Biome.Set(4)
		world.Harness.Data.ServerStore.World.Level.Set(5)
		world.Acc.Coins.Set(2)
		local seen = observe(world)
		local clientCoins = world.Client.Coins.Get()
		world.Harness.Cleanup()
		expect(`{seen} clientCoins={clientCoins}`).toBe(
			"live=Coins=2,_Scribe=tbl dirty=true client=4,biome4,5 server=4 calls=[4 4] clientCoins=2"
		)
	end)

	itRunning("still removes a stray key through a migration, leaving the client's store alone", function()
		local world = make({ Coins = 4, BiomeName = "stray" }, {
			Migrations = {
				[2] = function(data)
					data.BiomeName = nil
				end,
			},
		})
		local seen = observe(world)
		world.Harness.Cleanup()
		expect(seen).toBe("live=Coins=4,_Scribe=tbl dirty=false client=1,biome1,3 server=1 calls=[]")
	end)

	itRunning("leaves a storeless bundle's undeclared roots alone, whatever they are named", function()
		local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0) }, AutoPump = true })
		local _player, entry, acc = harness.Join(USER)
		local result = attempt({ "<none>" }, function()
			acc.Child("Biome").Set(9)
		end)
		local live = shape(entry.LiveData)
		harness.Cleanup()
		expect(`{result} live={live}`).toBe("ok live=Biome=9,Coins=0,_Scribe=tbl")
	end)
end)
