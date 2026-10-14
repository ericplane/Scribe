--!nonstrict
-- A failed recompute drops carried values; transmitted fields use the server value.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Client = require(ScribeRoot.Client)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local function step(harness)
	for _ = 1, 4 do
		harness.Step()
	end
end

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

describe("a carried derived value whose recompute throws", function()
	itRunning("is not left behind by a rollback when the field was absent before it", function()
		local harness = TestCtx.make({
			Template = {
				Stats = Scribe.Session({
					Name = Scribe.String("x"),
					Len = Scribe.Derived(Scribe.Int(0), { "Stats.Name" }, function(name)
						assert(name ~= "bad", "bad name")
						return #name
					end),
				}),
			},
		})
		local player, entry, acc = harness.Join(69101)
		-- Re-created with a name the compute refuses, so Len is absent going in.
		acc.Stats.Set(nil)
		acc.Stats.Set({ Name = "bad" })
		local before = shape(entry.SessionStore.Stats)
		local read
		local ok = harness.Data.Transaction(player, function()
			acc.Stats.Name.Set("okay")
			read = acc.Stats.Len.Get()
			acc.Stats.Set({ Name = "zz" })
			error("abort")
		end)
		local after = shape(entry.SessionStore.Stats)
		harness.Cleanup()
		expect(`before={before} ok={tostring(ok)} read={read} after={after}`).toBe(
			"before=Name=bad ok=false read=4 after=Name=bad"
		)
	end)

	itRunning("is not filled into a client's Init for a field the server holds absent", function()
		local harness = TestCtx.make({
			Template = {
				Hidden = Scribe.ServerOnly(Scribe.Int(4)),
				Stats = Scribe.Session({
					Kept = Scribe.Int(7),
					-- Server-computed; rejects 99.
					Shown = Scribe.Derived(Scribe.Int(0), { "Hidden" }, function(hidden)
						assert(hidden ~= 99, "refused")
						return hidden * 2 + 1
					end),
				}),
			},
			AutoPump = true,
		})
		local player, entry, acc = harness.Join(69102)
		acc.Hidden.Set(99)
		acc.Stats.Set(nil)
		acc.Stats.Set({ Kept = 1 })
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local seen =
			`server={shape(entry.SessionStore.Stats)} client={tostring(client.Stats.Shown.Get())},{client.Stats.Kept.Get()}`
		harness.Cleanup()
		-- The template default (4 * 2 + 1 = 9) is a value the server never held.
		expect(seen).toBe("server=Kept=1 client=nil,1")
	end)

	itRunning("keeps its previous value when a later input write throws, as any derived field does", function()
		-- After a successful recompute, later failures keep the last value as usual.
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(3),
				Stats = Scribe.Session({
					Kept = Scribe.Int(7),
					Twice = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(coins)
						assert(coins ~= 13, "unlucky")
						return coins * 2
					end),
				}),
			},
		})
		local _player, entry, acc = harness.Join(69105)
		acc.Coins.Set(5)
		acc.Stats.Set({ Kept = 9 })
		local afterRecord = shape(entry.SessionStore.Stats)
		acc.Coins.Set(13)
		local afterThrow = shape(entry.SessionStore.Stats)
		harness.Cleanup()
		expect(`record={afterRecord} throw={afterThrow}`).toBe("record=Kept=9,Twice=10 throw=Kept=9,Twice=10")
	end)

	itRunning("is dropped on the server as on a watcher's Shared copy after a Clear", function()
		local harness = TestCtx.make({
			Template = {
				Pub = Scribe.Shared(Scribe.Session({
					Level = Scribe.Int(1),
					-- Computed by watchers; Clear removes the required Level input.
					Badge = Scribe.Derived(Scribe.String(""), { "Pub.Level" }, function(level)
						return "L" .. level
					end),
				})),
			},
			AutoPump = true,
		})
		local watcher = harness.Join(69103)
		local owner, _entry, acc = harness.Join(69104)
		harness.Transport.LocalPlayer = watcher
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		harness.SendHello(owner)
		acc.Pub.Level.Set(2)
		harness.StepUntil(function()
			local shared = client.GetShared(owner.UserId)
			return shared ~= nil and shared.Pub ~= nil and shared.Pub.Badge == "L2"
		end)
		acc.Pub.Clear()
		step(harness)
		local shared = client.GetShared(owner.UserId)
		local watcherBadge = if shared and shared.Pub then tostring(shared.Pub.Badge) else "<no record>"
		local seen = `server={tostring(acc.Pub.Badge.Get())} watcher={watcherBadge}`
		harness.Cleanup()
		expect(seen).toBe("server=nil watcher=nil")
	end)
end)
