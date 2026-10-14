--!nonstrict
-- Record replacement and rollback must not emit temporary derived values.

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

local USER = 72201

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

local LABELS = { "Twice", "Inner", "Chain", "Shown", "Deep" }

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
	)},{tostring(stats.Sub.Deep.Get())}`
end

describe("a transaction replacing a record that holds derived fields", function()
	itRunning("fires nothing inside the body and only real changes at the commit, on both realms", function()
		local harness, player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		local inside
		local ok = harness.Data.Transaction(player, function()
			acc.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
			inside = server()
		end)
		local commit = server()
		step(harness)
		local seen = `ok={tostring(ok)} inside {inside} | commit {commit} = {values(acc)}`
			.. ` | client {mirror()} = {values(client)}`
		harness.Cleanup()
		expect(seen).toBe(
			"ok=true inside Twice[] Inner[] Chain[] Shown[] Deep[]"
				.. " | commit Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] = 10,109,1090,11,25"
				.. " | client Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[] = 10,109,1090,11,25"
		)
	end)

	itRunning("fires nothing on either realm when it rolls back", function()
		local harness, player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		local inside
		local ok = harness.Data.Transaction(player, function()
			acc.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
			acc.Coins.Set(6)
			inside = server()
			error("abort")
		end)
		local rollback = server()
		step(harness)
		local seen = `ok={tostring(ok)} inside {inside} | rollback {rollback} = {values(acc)},{acc.Stats.Kept.Get()}`
			.. ` | client {mirror()} = {values(client)},{tostring(client.Stats.Kept.Get())}`
		harness.Cleanup()
		expect(seen).toBe(
			"ok=false inside Twice[] Inner[] Chain[] Shown[] Deep[]"
				.. " | rollback Twice[] Inner[] Chain[] Shown[] Deep[] = 10,107,1070,11,25,7"
				.. " | client Twice[] Inner[] Chain[] Shown[] Deep[] = 10,107,1070,11,25,7"
		)
	end)

	itRunning("restores a field the server sends to its value before the transaction, not the body's", function()
		local harness, player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		local read
		local ok = harness.Data.Transaction(player, function()
			acc.Secret.Set(6)
			-- Rollback must not carry the body's settled value of 13 into the restored record.
			read = acc.Stats.Shown.Get()
			acc.Stats.Set({ Kept = 9, Sub = { Leaf = 1 } })
			error("abort")
		end)
		local rollback = server()
		step(harness)
		local seen = `ok={tostring(ok)} read={read} | rollback {rollback} = {values(acc)}`
			.. ` | client {mirror()} = {values(client)}`
		harness.Cleanup()
		expect(seen).toBe(
			"ok=false read=13"
				.. " | rollback Twice[] Inner[] Chain[] Shown[11>13 13>11] Deep[] = 10,107,1070,11,25"
				.. " | client Twice[] Inner[] Chain[] Shown[] Deep[] = 10,107,1070,11,25"
		)
	end)

	itRunning("fills the fields a record lacked before the transaction from the one its restore replaces", function()
		local harness, player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		local read, ok
		harness.Data.Batch(player, function()
			acc.Stats.Set(nil)
			-- The batch defers recompute, so the snapshot has no derived fields.
			acc.Stats.Kept.Set(9)
			ok = harness.Data.Transaction(player, function()
				acc.Stats.Set({ Kept = 11 })
				read = acc.Stats.Twice.Get()
				error("abort")
			end)
		end)
		local after = server()
		step(harness)
		local seen = `ok={tostring(ok)} read={read} | server {after} = {values(acc)},{acc.Stats.Kept.Get()}`
			.. ` | client {mirror()} = {values(client)},{tostring(client.Stats.Kept.Get())}`
		harness.Cleanup()
		-- The server sees each settle; the client sees only the batch outcome. Sub stays absent.
		expect(seen).toBe(
			"ok=false read=10"
				.. " | server Twice[10>nil nil>10] Inner[107>nil nil>111 111>109] Chain[1070>nil nil>1110 1110>1090]"
				.. " Shown[11>nil nil>11] Deep[25>nil] = 10,109,1090,11,nil,9"
				.. " | client Twice[] Inner[107>109] Chain[1070>1090] Shown[] Deep[25>nil] = 10,109,1090,11,nil,9"
		)
	end)

	itRunning("keeps the fields through a Clear the body reads after, and rolls the Clear back quietly", function()
		local harness, player, acc, client = make()
		local server, mirror = watch(acc), watch(client)
		local read
		local ok = harness.Data.Transaction(player, function()
			acc.Stats.Clear()
			-- A read settles inside the body, so this is where a dropped field came back.
			read = `{tostring(acc.Stats.Twice.Get())},{tostring(acc.Stats.Shown.Get())}`
			error("abort")
		end)
		local rollback = server()
		step(harness)
		local seen = `ok={tostring(ok)} read={read} | rollback {rollback} = {values(acc)},{acc.Stats.Kept.Get()}`
			.. ` | client {mirror()} = {values(client)},{tostring(client.Stats.Kept.Get())}`
		harness.Cleanup()
		expect(seen).toBe(
			"ok=false read=10,11"
				.. " | rollback Twice[] Inner[107>100 100>107] Chain[1070>1000 1000>1070] Shown[] Deep[25>nil nil>25]"
				.. " = 10,107,1070,11,25,7"
				.. " | client Twice[] Inner[] Chain[] Shown[] Deep[] = 10,107,1070,11,25,7"
		)
	end)
end)
