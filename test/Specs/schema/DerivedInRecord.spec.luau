--!nonstrict
-- Replacing a record also recomputes its derived fields.

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

local USER = 68101

-- Twice and Deep read root inputs; Inner reads a sibling; Shown needs the server.
local function makeTemplate(calls: { [string]: number }?)
	local function count(name: string)
		if calls then
			calls[name] = (calls[name] or 0) + 1
		end
	end
	return {
		Coins = Scribe.Int(3),
		Secret = Scribe.ServerOnly(Scribe.Int(4)),
		Stats = Scribe.Session({
			Twice = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
				count("Twice")
				return (c or 0) * 2
			end),
			Kept = Scribe.Int(7),
			Inner = Scribe.Derived(Scribe.Int(0), { "Stats.Kept" }, function(k)
				return (k or 0) + 100
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

-- Apply server setup before the client receives Init.
local function make(before: ((acc: any) -> ())?, calls: { [string]: number }?)
	local harness = TestCtx.make({ Template = makeTemplate(calls), AutoPump = true })
	local player, _entry, acc = harness.Join(USER)
	if before then
		before(acc)
	end
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

local function fields(data): string
	local stats = data.Stats
	return `{tostring(stats.Twice.Get())},{tostring(stats.Inner.Get())},{tostring(stats.Sub.Deep.Get())},{tostring(
		data.Total.Get()
	)}`
end

describe("a derived field inside a Session record", function()
	itRunning("is right on the client after the Init and after a resync, with every input at its default", function()
		-- Non-default inputs would hide a missing record recompute.
		local harness, player, acc, client = make()
		local atInit = fields(client)
		harness.SendHello(player)
		step(harness)
		local afterResync = fields(client)
		local server = fields(acc)
		harness.Cleanup()
		expect(`init={atInit} resync={afterResync} server={server}`).toBe(
			"init=6,107,15,600 resync=6,107,15,600 server=6,107,15,600"
		)
	end)

	itRunning("is recomputed on both realms when its record is replaced by Set, Update or Clear", function()
		local harness, _player, acc, client = make(function(server)
			server.Coins.Set(5)
		end)
		local seen = {}
		local function record(label: string)
			step(harness)
			table.insert(seen, `{label}={fields(acc)}/{fields(client)}`)
		end
		acc.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
		record("set")
		acc.Stats.Update(function()
			return { Kept = 11, Sub = { Leaf = 3 } }
		end)
		record("update")
		-- Clear removes Sub; its derived field must not recreate it.
		acc.Stats.Clear()
		record("clear")
		harness.Cleanup()
		expect(table.concat(seen, " ")).toBe(
			"set=10,109,25,1000/10,109,25,1000 update=10,111,25,1000/10,111,25,1000 clear=10,100,nil,1000/10,100,nil,1000"
		)
	end)

	itRunning("keeps the computed value when a record Set supplies one", function()
		local harness, _player, acc, client = make(function(server)
			server.Coins.Set(5)
		end)
		acc.Stats.Set({ Kept = 9, Twice = 500 })
		step(harness)
		local seen = `server={acc.Stats.Twice.Get()} client={tostring(client.Stats.Twice.Get())}`
		harness.Cleanup()
		expect(seen).toBe("server=10 client=10")
	end)

	itRunning("is recomputed when only the intermediate record is written", function()
		local harness, _player, acc, client = make(function(server)
			server.Coins.Set(5)
		end)
		acc.Stats.Sub.Set({ Leaf = 2 })
		step(harness)
		local seen = `server={acc.Stats.Sub.Deep.Get()},{acc.Stats.Sub.Leaf.Get()} client={tostring(
			client.Stats.Sub.Deep.Get()
		)}`
		harness.Cleanup()
		expect(seen).toBe("server=25,2 client=25")
	end)

	itRunning("re-sends a transmitted field after its record is replaced", function()
		local harness, _player, acc, client = make(function(server)
			server.Secret.Set(5)
		end)
		local atInit = client.Stats.Shown.Get()
		acc.Stats.Set({ Kept = 9 })
		step(harness)
		local seen = `init={atInit} server={acc.Stats.Shown.Get()} client={tostring(client.Stats.Shown.Get())}`
		harness.Cleanup()
		expect(seen).toBe("init=11 server=11 client=11")
	end)

	itRunning("recomputes each field once per realm for one record write", function()
		local calls = {}
		local harness, _player, acc = make(function(server)
			server.Coins.Set(5)
		end, calls)
		table.clear(calls)
		acc.Stats.Set({ Kept = 9 })
		step(harness)
		local twice = calls.Twice or 0
		harness.Cleanup()
		-- One on the server, one on the owner's client.
		expect(`twice={twice}`).toBe("twice=2")
	end)

	itRunning("is not brought back as a partial record after the record itself is removed", function()
		local harness, player, acc, client = make()
		local entry = harness.Ctx.Persistence.EntryFor(player)
		local function seen(): string
			step(harness)
			-- Raw: Get() on a missing record answers a shell, so it cannot tell.
			local raw = entry.SessionStore.Stats
			return `raw={if raw == nil then "nil" else "tbl"} twice={tostring(acc.Stats.Twice.Get())}/{tostring(
				client.Stats.Twice.Get()
			)}`
		end
		acc.Stats.Set(nil)
		local afterRemove = seen()
		acc.Coins.Set(40)
		local afterInput = seen()
		harness.Cleanup()
		expect(`removed {afterRemove} input {afterInput}`).toBe(
			"removed raw=nil twice=nil/nil input raw=nil twice=nil/nil"
		)
	end)

	itRunning("is recomputed when a child write re-creates its removed record in the same frame", function()
		-- Recreating a record must recompute its fields, even inside a batch.
		local harness, _player, acc, client = make(function(server)
			server.Coins.Set(5)
		end)
		acc.Stats.Set(nil)
		acc.Stats.Kept.Set(9)
		acc.Stats.Sub.Clear()
		acc.Stats.Sub.Leaf.Set(2)
		step(harness)
		local seen = `server={tostring(acc.Stats.Twice.Get())},{tostring(acc.Stats.Sub.Deep.Get())}`
			.. ` client={tostring(client.Stats.Twice.Get())},{tostring(client.Stats.Sub.Deep.Get())}`
		harness.Cleanup()
		expect(seen).toBe("server=10,25 client=10,25")
	end)

	it("recomputes in edit mode when Data.Mock seeds the record", function()
		local options = {
			Template = makeTemplate(),
			ProfileStoreIndex = "DerivedInRecord",
			ProfileKeyPrefix = "PLAYER_",
			IsRunning = false,
			Banner = false,
		}
		local client = Client.new(options, Template.Compile(options.Template, {}))
		client.Mock({ Coins = 5 })
		client.Mock({ Stats = { Twice = 999, Kept = 8 } })
		expect(fields(client)).toBe("10,108,25,1000")
	end)
end)

describe("a derived field inside a ServerStore record", function()
	itRunning("is right on the client at Init and recomputed when the record is replaced", function()
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
			Template = { Coins = Scribe.Int(0) },
			Options = { ServerStore = store },
			AutoPump = true,
		})
		local player = harness.Join(USER)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local s, c = harness.Data.ServerStore, client.ServerStore
		local seen = { `init={s.Board.Label.Get()}/{tostring(c.Board.Label.Get())}` }
		s.Board.Set({ Size = 8 })
		step(harness)
		table.insert(seen, `set={tostring(s.Board.Label.Get())}/{tostring(c.Board.Label.Get())}`)
		s.Board.Set({ Size = 9, Label = "forged" })
		step(harness)
		table.insert(seen, `forged={tostring(s.Board.Label.Get())}/{tostring(c.Board.Label.Get())}`)
		s.Board.Set(nil)
		s.Board.Size.Set(8)
		step(harness)
		table.insert(seen, `recreated={tostring(s.Board.Label.Get())}/{tostring(c.Board.Label.Get())}`)
		harness.Cleanup()
		expect(table.concat(seen, " ")).toBe("init=w2/w2 set=w2/w2 forged=w2/w2 recreated=w2/w2")
	end)
end)
