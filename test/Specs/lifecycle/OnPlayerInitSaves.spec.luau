--!nonstrict
-- Saves during OnPlayerInit preserve in-flight counts and the wipe-guard baseline.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)

local USER = 88792
local harnesses: { any } = {}
local players: { any } = {}

afterEach(function()
	for i = #harnesses, 1, -1 do
		local harness = harnesses[i]
		for _, player in players do
			if harness.Ctx.Persistence.EntryFor(player) then
				harness.Leave(player)
			end
		end
		harness.Cleanup()
	end
	table.clear(harnesses)
	table.clear(players)
end)

local function trips(): number
	return #Scribe.GetRecentLogs({ Code = "WIPE_GUARD_TRIPPED", Limit = 500 })
end

-- A first session leaves a profile with a top-level `Legacy` key on disk.
local function seeded(fake)
	local first = TestCtx.make({ Template = { Coins = Scribe.Int(0, { Min = 0 }) }, Fake = fake })
	local player, entry = first.Join(USER)
	entry.LiveData.Legacy = "old"
	expect(first.Data.Flush(player)).toBe(true)
	first.Leave(player)
	first.Cleanup()
end

local function wipeAfterLoad(midHookSave: boolean, policy: string): string
	local fake = FakeProfileStore.new()
	seeded(fake)
	local resumeHook: thread? = nil
	local harness = TestCtx.make({
		Template = { Coins = Scribe.Int(0, { Min = 0 }) },
		Fake = fake,
		Options = {
			WipeGuardPolicy = policy,
			OnPlayerInit = function()
				resumeHook = coroutine.running()
				coroutine.yield()
			end,
		},
	})
	table.insert(harnesses, harness)
	local player = FakePlayer.new(USER)
	table.insert(players, player)
	task.spawn(harness.Ctx.Persistence.OnPlayerAdded, player)
	local profile = fake.ActiveProfiles[`Default/PLAYER_{USER}`]
	if midHookSave then
		profile:Save() -- an autosave that lands while the hook is parked
	end
	task.spawn(resumeHook :: thread)
	local entry = harness.Ctx.Persistence.EntryFor(player)
	local before = trips()
	-- Damage both a game key and the ledger.
	entry.LiveData.Legacy = nil
	entry.LiveData._Scribe.ProcessedPurchaseIds = nil
	local flushed = harness.Data.Flush(player)
	local stored = fake.Persisted[`Default/PLAYER_{USER}`]
	return `trips={trips() - before} flushed={flushed} legacy={stored.Legacy} receipts={type(
		stored._Scribe.ProcessedPurchaseIds
	)}`
end

describe("a save while OnPlayerInit yields", function()
	it("a save during the hook leaves the first post-hook save unguarded", function()
		local out = {}
		for _, policy in { "Block", "Warn" } do
			local without = wipeAfterLoad(false, policy)
			local with = wipeAfterLoad(true, policy)
			table.insert(out, `{policy} same={with == without}`)
		end
		expect(table.concat(out, " ")).toBe("Block same=true Warn same=true")
	end)

	it("a mid-hook save settling after Ready hides a later save's failure", function()
		local fake = FakeProfileStore.new()
		local resumeHook: thread? = nil
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0 }) },
			Fake = fake,
			Options = {
				OnPlayerInit = function()
					resumeHook = coroutine.running()
					coroutine.yield()
				end,
			},
		})
		table.insert(harnesses, harness)
		local player = FakePlayer.new(USER)
		table.insert(players, player)
		task.spawn(harness.Ctx.Persistence.OnPlayerAdded, player)
		expect(resumeHook ~= nil).toBe(true)

		local profile = fake.ActiveProfiles[`Default/PLAYER_{USER}`]
		local parked: { thread } = {}
		fake.MidSave = function()
			table.insert(parked, coroutine.running())
			coroutine.yield()
		end

		-- Save A: an autosave that starts while the hook is parked.
		task.spawn(function()
			profile:Save()
		end)
		expect(#parked).toBe(1)

		-- The hook returns; the session goes Ready.
		task.spawn(resumeHook :: thread)
		local entry = harness.Ctx.Persistence.EntryFor(player)
		local data = harness.Data.Get(player)
		expect(entry.State).toBe("Ready")

		data.Coins.Set(5)
		-- Save B: a Flush that starts after Ready, carrying the write.
		local flushB = nil
		task.spawn(function()
			flushB = harness.Data.Flush(player)
		end)
		expect(#parked).toBe(2)
		local inFlightWithB = entry.SavesInFlight

		-- A settles first.
		fake.MidSave = nil
		task.spawn(parked[1])
		local inFlightAfterA = entry.SavesInFlight
		local flushWhileBInFlight = harness.Data.Flush(player)

		-- B fails.
		fake.FailSaves = true
		task.spawn(parked[2])
		fake.FailSaves = false
		local info = harness.Data.GetSaveInfo(player)
		local flushAfterFail = harness.Data.Flush(player)

		local observed = `inFlightWithB={inFlightWithB} inFlightAfterA={inFlightAfterA} `
			.. `flushWhileBInFlight={flushWhileBInFlight} flushB={flushB} lastResult={info.LastResult} `
			.. `dirty={info.Dirty} flushAfterFail={flushAfterFail} saves={fake.SaveCounts[`Default/PLAYER_{USER}`]}`
		-- Settling A must leave B in flight. A new Flush saves again; B's failure stays recorded.
		expect(observed).toBe(
			"inFlightWithB=1 inFlightAfterA=1 flushWhileBInFlight=true flushB=false lastResult=Fail "
				.. "dirty=true flushAfterFail=true saves=3"
		)
	end)

	it("leaves an ordinary save after load counted and settled", function()
		-- Normal saves must stop using the early-load bookkeeping.
		local harness = TestCtx.make({ Template = { Coins = Scribe.Int(0, { Min = 0 }) } })
		table.insert(harnesses, harness)
		local player, entry, data = harness.Join(88793)
		table.insert(players, player)
		data.Coins.Set(3)
		local flushed = harness.Data.Flush(player)
		local saves = harness.Fake.SaveCounts["Default/PLAYER_88793"] or 0
		local again = harness.Data.Flush(player)
		local after = harness.Fake.SaveCounts["Default/PLAYER_88793"] or 0
		expect(`flush={flushed},{again} inFlight={entry.SavesInFlight} extraSaves={after - saves}`).toBe(
			"flush=true,true inFlight=0 extraSaves=0"
		)
	end)
end)
