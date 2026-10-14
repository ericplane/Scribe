--!nonstrict
-- Raw ledger damage must trip the wipe guard, even below 1 KB.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
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

local function trips(): number
	return #Scribe.GetRecentLogs({ Code = "WIPE_GUARD_TRIPPED", Limit = 500 })
end

local function lastTripReason(): string
	local logs = Scribe.GetRecentLogs({ Code = "WIPE_GUARD_TRIPPED", Limit = 1 })
	return if logs[1] then tostring(logs[1].Message) else "<none>"
end

local function make(policy: string?, extra: { [string]: any }?)
	local options = { Perks = { "VIP" }, WipeGuardPolicy = policy }
	for key, value in extra or {} do
		options[key] = value
	end
	harness = TestCtx.make({
		Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		Options = options,
	})
	return harness
end

-- Joins, grants the perk and saves, so the key holds a full ledger.
local function savedWithPerk(userId: number)
	local player, entry, data = harness.Join(userId)
	harness.Data.GrantPerk(player, "VIP")
	data.Coins.Set(3)
	expect(harness.Data.Flush(player)).toBe(true)
	expect(harness.Fake.Persisted[keyOf(entry)]._Scribe.Perks.VIP).toBe(true)
	return player, entry, data
end

local function storedLedger(entry): string
	local reserved = harness.Fake.Persisted[keyOf(entry)]._Scribe
	if type(reserved) ~= "table" then
		return "none"
	end
	return `VIP={reserved.Perks and reserved.Perks.VIP} Version={reserved.Version} `
		.. `receipts={type(reserved.ProcessedPurchaseIds)}`
end

describe("under Block, a gutted ledger is held back", function()
	it("holds the save when the ledger was emptied in place", function()
		make("Block")
		local player, entry, data = savedWithPerk(88601)
		local before = trips()
		table.clear(entry.LiveData._Scribe)
		data.Coins.Set(4)
		local flushed = harness.Data.Flush(player)
		expect(`flush={flushed} trips={trips() - before} blocked={entry.Blocked} {storedLedger(entry)}`).toBe(
			"flush=false trips=1 blocked=true VIP=true Version=1 receipts=table"
		)
		expect(lastTripReason()).toContain("ProcessedPurchaseIds")
	end)

	it("holds the save when the ledger was replaced by a partial one", function()
		-- Recreate one ledger path after losing the rest.
		make("Block")
		local player, entry, data = savedWithPerk(88602)
		local before = trips()
		entry.LiveData._Scribe = { Perks = { VIP = true } }
		data.Coins.Set(4)
		local flushed = harness.Data.Flush(player)
		expect(`flush={flushed} trips={trips() - before} {storedLedger(entry)}`).toBe(
			"flush=false trips=1 VIP=true Version=1 receipts=table"
		)
	end)

	it("holds the save when a part of the ledger was replaced by another type", function()
		-- Presence alone misses a ledger part replaced with false.
		make("Block")
		local player, entry, data = savedWithPerk(88608)
		local before = trips()
		entry.LiveData._Scribe.Perks = false
		data.Coins.Set(4)
		local flushed = harness.Data.Flush(player)
		expect(`flush={flushed} trips={trips() - before} {storedLedger(entry)}`).toBe(
			"flush=false trips=1 VIP=true Version=1 receipts=table"
		)
		expect(lastTripReason()).toContain("Perks")
	end)

	it("holds the save when the ledger is no longer a table", function()
		make("Block")
		local player, entry, data = savedWithPerk(88607)
		local before = trips()
		entry.LiveData._Scribe = true
		data.Coins.Set(4)
		local flushed = harness.Data.Flush(player)
		expect(`flush={flushed} trips={trips() - before} {storedLedger(entry)}`).toBe(
			"flush=false trips=1 VIP=true Version=1 receipts=table"
		)
	end)

	it("holds the save when the schema version went backwards", function()
		make("Block", {
			Migrations = {
				[2] = function(data)
					return data
				end,
			},
		})
		local player, entry, data = savedWithPerk(88603)
		expect(harness.Fake.Persisted[keyOf(entry)]._Scribe.Version).toBe(2)
		local before = trips()
		entry.LiveData._Scribe.Version = 1
		data.Coins.Set(4)
		local flushed = harness.Data.Flush(player)
		expect(`flush={flushed} trips={trips() - before} {storedLedger(entry)}`).toBe(
			"flush=false trips=1 VIP=true Version=2 receipts=table"
		)
		expect(lastTripReason()).toContain("Version")
	end)

	it("checks against the loaded ledger before the session's first save", function()
		make("Block")
		local player, entry = savedWithPerk(88604)
		harness.Leave(player)
		local rejoined, again, data = harness.Join(88604)
		local before = trips()
		table.clear(again.LiveData._Scribe)
		data.Coins.Set(5)
		local flushed = harness.Data.Flush(rejoined)
		expect(`flush={flushed} trips={trips() - before} {storedLedger(entry)}`).toBe(
			"flush=false trips=1 VIP=true Version=1 receipts=table"
		)
	end)
end)

describe("under Warn, a gutted ledger is reported", function()
	it("trips and lets the save through, as for any other wipe", function()
		make(nil)
		local player, entry, data = savedWithPerk(88605)
		local before = trips()
		table.clear(entry.LiveData._Scribe)
		data.Coins.Set(4)
		local flushed = harness.Data.Flush(player)
		-- A successful save becomes the new baseline.
		data.Coins.Set(5)
		local again = harness.Data.Flush(player)
		expect(`flush={flushed},{again} trips={trips() - before} {storedLedger(entry)}`).toBe(
			"flush=true,true trips=1 VIP=nil Version=nil receipts=nil"
		)
	end)
end)

-- Loading repairs malformed ledger parts; that repair is not data loss.
local function seedMalformedTimed(fake, userId: number)
	fake.Persisted[`Default/PLAYER_{userId}`] = {
		Coins = 5,
		_Scribe = {
			Version = 1,
			GiftAims = {},
			GiftCredits = {},
			PendingGifts = {},
			Perks = {},
			ProcessedPurchaseIds = {},
			ReceiptReservations = {},
			PurchaseLogs = { InGame = {}, Robux = {} },
			Exchange = {},
			ExchangeInbox = {},
			Timed = false,
			Boards = {},
		},
	}
end

describe("Scribe's own repair of a malformed ledger part is not a wipe", function()
	it("saves the session under Block", function()
		make("Block")
		seedMalformedTimed(harness.Fake, 88611)
		local before = trips()
		local player, entry, data = harness.Join(88611)
		local repaired = type(entry.LiveData._Scribe.Timed)
		data.Coins.Set(6)
		local first = harness.Data.Flush(player)
		data.Coins.Set(7)
		local second = harness.Data.Flush(player)
		local stored = harness.Fake.Persisted["Default/PLAYER_88611"]
		expect(`repaired={repaired} flush={first},{second} trips={trips() - before} storedCoins={stored.Coins}`).toBe(
			"repaired=table flush=true,true trips=0 storedCoins=7"
		)
	end)

	it("saves the next session under Block too", function()
		make("Block")
		seedMalformedTimed(harness.Fake, 88612)
		local player, _entry, data = harness.Join(88612)
		data.Coins.Set(6)
		harness.Data.Flush(player)
		harness.Leave(player)
		local again, _again, data2 = harness.Join(88612)
		data2.Coins.Set(9)
		local flushed = harness.Data.Flush(again)
		local stored = harness.Fake.Persisted["Default/PLAYER_88612"]
		expect(`flush={flushed} storedCoins={stored.Coins}`).toBe("flush=true storedCoins=9")
	end)

	it("reports nothing under Warn", function()
		make(nil)
		seedMalformedTimed(harness.Fake, 88613)
		local before = trips()
		local player, _entry, data = harness.Join(88613)
		data.Coins.Set(6)
		local flushed = harness.Data.Flush(player)
		expect(`flush={flushed} trips={trips() - before}`).toBe("flush=true trips=0")
	end)

	it("saves the session after a gutted part was forced through", function()
		-- Data.Flush(player, { Force = true }) is the documented way out of a block.
		make("Block")
		local player, entry, data = harness.Join(88614)
		data.Coins.Set(3)
		harness.Data.Flush(player)
		entry.LiveData._Scribe.Perks = false
		data.Coins.Set(4)
		local held = harness.Data.Flush(player)
		local forced = harness.Data.Flush(player, { Force = true })
		harness.Leave(player)
		local again, _again, data2 = harness.Join(88614)
		data2.Coins.Set(50)
		local f1 = harness.Data.Flush(again)
		data2.Coins.Set(51)
		local f2 = harness.Data.Flush(again)
		local stored = harness.Fake.Persisted["Default/PLAYER_88614"]
		expect(`held={held} forced={forced} next={f1},{f2} storedCoins={stored.Coins}`).toBe(
			"held=false forced=true next=true,true storedCoins=51"
		)
	end)
end)

describe("a part the last save already held malformed", function()
	it("is not reported again by the next save", function()
		-- Warn allowed the malformed value to save, so it is now the baseline.
		make(nil)
		local player, entry, data = savedWithPerk(88615)
		local before = trips()
		entry.LiveData._Scribe.Perks = false
		data.Coins.Set(4)
		local first = harness.Data.Flush(player)
		data.Coins.Set(5)
		local second = harness.Data.Flush(player)
		expect(`flush={first},{second} trips={trips() - before}`).toBe("flush=true,true trips=1")
	end)
end)

describe("ordinary ledger traffic does not trip it", function()
	it("lets perks come and go and the save through", function()
		make("Block")
		local player, entry, data = savedWithPerk(88606)
		local before = trips()
		harness.Data.RevokePerk(player, "VIP")
		data.Coins.Set(6)
		local first = harness.Data.Flush(player)
		harness.Data.GrantPerk(player, "VIP")
		local second = harness.Data.Flush(player)
		harness.Data.RevokePerk(player, "VIP")
		local third = harness.Data.Flush(player)
		expect(`flushes={first},{second},{third} trips={trips() - before} {storedLedger(entry)}`).toBe(
			"flushes=true,true,true trips=0 VIP=nil Version=1 receipts=table"
		)
	end)
end)
