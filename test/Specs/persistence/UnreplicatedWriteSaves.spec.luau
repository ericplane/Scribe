--!nonstrict
-- Unreplicated writes still dirty saved data.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Client = require(Root.Scribe.Client)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local harness: any = nil

afterEach(function()
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

local function keyOf(entry): string
	return `Default/{entry.Key}`
end

local function saveCount(entry): number
	return harness.Fake.SaveCounts[keyOf(entry)] or 0
end

-- Joins and saves once, so the key holds Coins = 5 and the profile is clean.
local function savedAt5(userId: number, options: { [string]: any }?)
	harness = TestCtx.make(options)
	local player, entry, data = harness.Join(userId)
	data.Coins.Set(5)
	expect(harness.Data.Flush(player)).toBe(true)
	expect(harness.Fake.Persisted[keyOf(entry)].Coins).toBe(5)
	return player, entry, data
end

describe("a write with replicate = false", function()
	it("marks the profile dirty, so Flush saves an unreplicated Increment", function()
		local player, entry, data = savedAt5(88401)
		local saves = saveCount(entry)
		expect(data.Coins.Increment(60, false)).toBe(65)
		local dirty = entry.SaveInfo.Dirty
		local flushed = harness.Data.Flush(player)
		expect(
			`flush={flushed} dirty={dirty} saves={saveCount(entry) - saves} stored={harness.Fake.Persisted[keyOf(entry)].Coins}`
		).toBe("flush=true dirty=true saves=1 stored=65")
	end)

	it("marks the profile dirty for an unreplicated Set", function()
		local player, entry, data = savedAt5(88402)
		local saves = saveCount(entry)
		data.Coins.Set(77, false)
		local dirty = entry.SaveInfo.Dirty
		local flushed = harness.Data.Flush(player)
		expect(
			`flush={flushed} dirty={dirty} saves={saveCount(entry) - saves} stored={harness.Fake.Persisted[keyOf(entry)].Coins}`
		).toBe("flush=true dirty=true saves=1 stored=77")
	end)

	it("marks it dirty when the transaction that made it commits", function()
		local player, entry, data = savedAt5(88403)
		local ok = harness.Data.Transaction(player, function()
			data.Coins.Set(77, false)
		end)
		local dirty = entry.SaveInfo.Dirty
		harness.Data.Flush(player)
		expect(`ok={ok} dirty={dirty} stored={harness.Fake.Persisted[keyOf(entry)].Coins}`).toBe(
			"ok=true dirty=true stored=77"
		)
	end)

	it("stays off the wire", function()
		local player, entry, data = savedAt5(88404, { AutoPump = true })
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		data.Coins.Set(77, false)
		harness.Data.Flush(player)
		for _ = 1, 4 do
			harness.Step()
		end
		expect(`client={client.Coins.Get()} stored={harness.Fake.Persisted[keyOf(entry)].Coins}`).toBe(
			"client=5 stored=77"
		)
	end)

	it("stays off the wire when the transaction that made it commits", function()
		local player, entry, data = savedAt5(88406, { AutoPump = true })
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		harness.Data.Transaction(player, function()
			data.Coins.Set(77, false)
		end)
		harness.Data.Flush(player)
		for _ = 1, 4 do
			harness.Step()
		end
		expect(`client={client.Coins.Get()} stored={harness.Fake.Persisted[keyOf(entry)].Coins}`).toBe(
			"client=5 stored=77"
		)
	end)

	it("does not cost a save when the field is not saved at all", function()
		-- Session writes must not dirty saved data, with or without replication.
		local player, entry, data = savedAt5(88405)
		local saves = saveCount(entry)
		data.Runtime.InCombat.Set(true, false)
		local dirty = entry.SaveInfo.Dirty
		harness.Data.Flush(player)
		expect(`dirty={dirty} saves={saveCount(entry) - saves}`).toBe("dirty=false saves=0")
	end)
end)
