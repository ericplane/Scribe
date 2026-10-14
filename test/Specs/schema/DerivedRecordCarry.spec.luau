--!nonstrict
-- Record replacement preserves derived values until recompute.

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
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local USER = 68201

-- Cover root inputs, sibling inputs, chains and a server-computed field.
local function makeTemplate()
	return {
		Coins = Scribe.Int(3),
		Secret = Scribe.ServerOnly(Scribe.Int(4)),
		Stats = Scribe.Session({
			Twice = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
				return (c or 0) * 2
			end),
			Kept = Scribe.Int(7),
			Inner = Scribe.Derived(Scribe.Int(0), { "Stats.Kept" }, function(k)
				return (k or 0) + 100
			end),
			Chain = Scribe.Derived(Scribe.Int(0), { "Stats.Inner" }, function(i)
				return (i or 0) * 10
			end),
			Shown = Scribe.Derived(Scribe.Int(0), { "Secret" }, function(s)
				return (s or 0) * 2 + 1
			end),
			Sub = {
				Deep = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
					return (c or 0) * 5
				end),
				Leaf = Scribe.Int(1),
			},
		}),
		Total = Scribe.Derived(Scribe.Int(0), { "Stats.Twice" }, function(t)
			return (t or 0) * 100
		end),
	}
end

-- Seed Coins and Secret before Init to give each derived field a known value.
local function make()
	local harness = TestCtx.make({ Template = makeTemplate(), AutoPump = true })
	local player, _entry, acc = harness.Join(USER)
	acc.Coins.Set(5)
	acc.Secret.Set(5)
	harness.Transport.LocalPlayer = player
	local client = Client.new(harness.Options, harness.Compiled)
	harness.StepUntil(function()
		return client.IsReady()
	end)
	return harness, player, acc, client
end

local function step(harness)
	for _ = 1, 4 do
		harness.Step()
	end
end

local LABELS = { "Twice", "Inner", "Chain", "Shown", "Deep", "Total" }

-- Capture Changed events in field order, then clear the log.
local function watch(data): () -> string
	local logs = {}
	local function on(label: string, accessor)
		logs[label] = {}
		accessor.Changed(function(new, old)
			table.insert(logs[label], `{tostring(old)}>{tostring(new)}`)
		end)
	end
	on("Twice", data.Stats.Twice)
	on("Inner", data.Stats.Inner)
	on("Chain", data.Stats.Chain)
	on("Shown", data.Stats.Shown)
	on("Deep", data.Stats.Sub.Deep)
	on("Total", data.Total)
	return function(): string
		local parts = {}
		for _, label in LABELS do
			table.insert(parts, `{label}[{table.concat(logs[label], " ")}]`)
			table.clear(logs[label])
		end
		return table.concat(parts, " ")
	end
end

local function values(data): string
	local stats = data.Stats
	return `{tostring(stats.Twice.Get())},{tostring(stats.Inner.Get())},{tostring(stats.Chain.Get())},{tostring(
		stats.Shown.Get()
	)},{tostring(stats.Sub.Deep.Get())},{tostring(data.Total.Get())}`
end

describe("a derived field inside a record while the record is replaced", function()
	itRunning("fires only real changes on the server and the owner's client for Set, Update and Clear", function()
		local harness, _player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		local seen = {}
		local function record(label: string)
			step(harness)
			table.insert(seen, `{label}: server {server()} = {values(acc)} | client {mirror()} = {values(client)}`)
		end
		acc.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
		record("set")
		acc.Stats.Update(function()
			return { Kept = 11, Sub = { Leaf = 3 } }
		end)
		record("update")
		-- Clear removes Sub, so Deep goes with it: that one is a real removal.
		acc.Stats.Clear()
		record("clear")
		harness.Cleanup()
		expect(table.concat(seen, "\n")).toBe(table.concat({
			"set: server Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] Total[] = 10,109,1090,11,25,1000"
				.. " | client Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] Total[] = 10,109,1090,11,25,1000",
			"update: server Twice[] Inner[109>111] Chain[1090>1110] Shown[] Deep[] Total[] = 10,111,1110,11,25,1000"
				.. " | client Twice[] Inner[109>111] Chain[1090>1110] Shown[] Deep[] Total[] = 10,111,1110,11,25,1000",
			"clear: server Twice[] Inner[111>100] Chain[1110>1000] Shown[] Deep[25>nil] Total[] = 10,100,1000,11,nil,1000"
				.. " | client Twice[] Inner[111>100] Chain[1110>1000] Shown[] Deep[25>nil] Total[] = 10,100,1000,11,nil,1000",
		}, "\n"))
	end)

	itRunning("never passes through a value a record Set supplies for one", function()
		local harness, _player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		acc.Stats.Set({ Kept = 9, Twice = 500, Inner = 1, Shown = 2, Sub = { Leaf = 1, Deep = 999 } })
		step(harness)
		local seen = `server {server()} = {values(acc)} | client {mirror()} = {values(client)}`
		harness.Cleanup()
		expect(seen).toBe(
			"server Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] Total[] = 10,109,1090,11,25,1000"
				.. " | client Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] Total[] = 10,109,1090,11,25,1000"
		)
	end)

	itRunning("drops a field whose sub-record the write removed, and recomputes a re-created record", function()
		local harness, player, acc, client = make()
		local entry = harness.Ctx.Persistence.EntryFor(player)
		local server, mirror = watch(acc), watch(client)
		local seen = {}
		local function record(label: string)
			step(harness)
			-- Raw: Get() on a missing record answers a shell, so it cannot tell.
			local raw = entry.SessionStore.Stats
			local sub = if raw == nil then "none" elseif raw.Sub == nil then "nil" else "tbl"
			table.insert(seen, `{label}: sub={sub} server {server()} | client {mirror()}`)
		end
		-- No Sub in the value: Deep has nowhere to be carried to, and is not brought back.
		acc.Stats.Set({ Kept = 9 })
		record("nosub")
		-- Set(Get()) names every field already, so it was quiet before and stays quiet.
		acc.Stats.Set(acc.Stats.Get())
		record("setget")
		acc.Stats.Set(nil)
		record("removed")
		-- Nothing to carry from a record that is not there: these are creations.
		acc.Stats.Set({ Kept = 8, Sub = { Leaf = 1 } })
		record("recreated")
		harness.Cleanup()
		expect(table.concat(seen, "\n")).toBe(table.concat({
			"nosub: sub=nil server Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[25>nil] Total[]"
				.. " | client Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[25>nil] Total[]",
			"setget: sub=nil server Twice[] Inner[] Chain[] Shown[] Deep[] Total[]"
				.. " | client Twice[] Inner[] Chain[] Shown[] Deep[] Total[]",
			"removed: sub=none server Twice[10>nil] Inner[109>nil] Chain[1090>nil] Shown[11>nil] Deep[] Total[1000>0]"
				.. " | client Twice[10>nil] Inner[109>nil] Chain[1090>nil] Shown[11>nil] Deep[] Total[1000>0]",
			"recreated: sub=tbl server Twice[nil>10] Inner[nil>108] Chain[nil>1080] Shown[nil>11] Deep[nil>25] Total[0>1000]"
				.. " | client Twice[nil>10] Inner[nil>108] Chain[nil>1080] Shown[nil>11] Deep[nil>25] Total[0>1000]",
		}, "\n"))
	end)

	itRunning("keeps a field the client cannot compute through an optimistic record write", function()
		local harness, _player, _acc, client = make()
		local mirror = watch(client)
		local seen = {}
		client.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
		table.insert(seen, `set: {mirror()} = {values(client)}`)
		client.Stats.Clear()
		table.insert(seen, `clear: {mirror()} = {values(client)}`)
		harness.Cleanup()
		expect(table.concat(seen, "\n")).toBe(table.concat({
			"set: Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] Total[] = 10,109,1090,11,25,1000",
			"clear: Twice[] Inner[109>100] Chain[1090>1000] Shown[] Deep[25>nil] Total[] = 10,100,1000,11,nil,1000",
		}, "\n"))
	end)

	itRunning("fires each field once for a Data.Batch replacing the record and an input", function()
		local harness, player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		local inside
		harness.Data.Batch(player, function()
			acc.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
			acc.Coins.Set(6)
			inside = server()
		end)
		local after = server()
		step(harness)
		local seen = `inside {inside} | after {after} = {values(acc)} | client {mirror()} = {values(client)}`
		harness.Cleanup()
		expect(seen).toBe(
			"inside Twice[] Inner[] Chain[] Shown[] Deep[] Total[]"
				.. " | after Twice[10>12] Inner[107>109] Chain[1070>1090] Shown[] Deep[25>30] Total[1000>1200]"
				.. " = 12,109,1090,11,30,1200"
				.. " | client Twice[10>12] Inner[107>109] Chain[1070>1090] Shown[] Deep[25>30] Total[1000>1200]"
				.. " = 12,109,1090,11,30,1200"
		)
	end)

	it("fires only real changes for a record write in edit mode, before and after Data.Mock", function()
		local options = {
			Template = makeTemplate(),
			ProfileStoreIndex = "DerivedRecordCarry",
			ProfileKeyPrefix = "PLAYER_",
			IsRunning = false,
			Banner = false,
		}
		local client = Client.new(options, Template.Compile(options.Template, {}))
		-- Edit mode computes Shown itself, so it needs the ServerOnly input seeded too.
		client.Mock({ Coins = 5, Secret = 5 })
		local mirror = watch(client)
		local seen = {}
		client.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
		table.insert(seen, `set: {mirror()} = {values(client)}`)
		-- Mock writes the whole record; its supplied derived value must be ignored.
		client.Mock({ Stats = { Twice = 999, Kept = 8 } })
		table.insert(seen, `mock: {mirror()} = {values(client)}`)
		client.Stats.Clear()
		table.insert(seen, `clear: {mirror()} = {values(client)}`)
		expect(table.concat(seen, "\n")).toBe(table.concat({
			"set: Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] Total[] = 10,109,1090,11,25,1000",
			"mock: Twice[] Inner[109>108] Chain[1090>1080] Shown[] Deep[] Total[] = 10,108,1080,11,25,1000",
			"clear: Twice[] Inner[108>100] Chain[1080>1000] Shown[] Deep[25>nil] Total[] = 10,100,1000,11,nil,1000",
		}, "\n"))
	end)
end)

--- A below index as text: each record's key, then the fields under it, sorted.
local function index(below): string
	if below == nil then
		return "none"
	end
	local parts = {}
	for key, nodes in below do
		local names = {}
		for _, node in nodes do
			table.insert(names, table.concat(node.Path, "."))
		end
		table.sort(names)
		table.insert(parts, `{(string.gsub(key, "\31", "."))}>{table.concat(names, ",")}`)
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

describe("a derived field inside a ServerStore record while the record is replaced", function()
	itRunning("fires nothing on the server or a client for Set, a forged Set and Clear", function()
		local store = {
			Wave = Scribe.Int(2),
			Board = {
				Label = Scribe.Derived(Scribe.String(""), { "Wave" }, function(w)
					return `w{tostring(w)}`
				end),
				Size = Scribe.Int(5),
			},
		}
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0),
				Stats = Scribe.Session({
					Twice = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						return (c or 0) * 2
					end),
				}),
			},
			Options = { ServerStore = store },
			AutoPump = true,
		})
		-- Each tree carries only its own side's fields; the client's one tree holds both.
		local compiled = harness.Compiled
		local indexes = `full={index(compiled.DerivedBelow)} player={index(compiled.Views.Player.DerivedBelow)}`
			.. ` store={index(compiled.Views.Store.DerivedBelow)}`
			.. ` client={index(Template.ClientView(compiled).DerivedBelow)}`
		local player = harness.Join(USER)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local s, c = harness.Data.ServerStore, client.ServerStore
		local logs = { server = {}, client = {} }
		s.Board.Label.Changed(function(new, old)
			table.insert(logs.server, `{tostring(old)}>{tostring(new)}`)
		end)
		c.Board.Label.Changed(function(new, old)
			table.insert(logs.client, `{tostring(old)}>{tostring(new)}`)
		end)
		local seen = {}
		local function record(label: string)
			step(harness)
			table.insert(
				seen,
				`{label}: server[{table.concat(logs.server, " ")}]={tostring(s.Board.Label.Get())},{tostring(
					s.Board.Size.Get()
				)} client[{table.concat(logs.client, " ")}]={tostring(c.Board.Label.Get())},{tostring(
					c.Board.Size.Get()
				)}`
			)
			table.clear(logs.server)
			table.clear(logs.client)
		end
		s.Board.Set({ Size = 8 })
		record("set")
		s.Board.Set({ Size = 9, Label = "forged" })
		record("forged")
		s.Board.Clear()
		record("clear")
		s.Wave.Set(3)
		record("input")
		harness.Cleanup()
		expect(indexes .. "\n" .. table.concat(seen, "\n")).toBe(table.concat({
			"full=Board>Board.Label;Stats>Stats.Twice player=Stats>Stats.Twice store=Board>Board.Label"
				.. " client=Board>Board.Label;Stats>Stats.Twice",
			"set: server[]=w2,8 client[]=w2,8",
			"forged: server[]=w2,9 client[]=w2,9",
			"clear: server[]=w2,nil client[]=w2,nil",
			"input: server[w2>w3]=w3,nil client[w2>w3]=w3,nil",
		}, "\n"))
	end)
end)
