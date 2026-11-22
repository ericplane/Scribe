--!nonstrict
-- A free trial grants temporary pass access without recording a purchase.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe) :: any
local Clock = require(Root.Scribe.Internal.Clock)
local Log = require(Root.Scribe.Internal.Log)
local Metrics = require(Root.Scribe.Internal.Metrics)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local PASS, PASS_ID = "VIP", 777
local GIFT_ID = 501
local START = 1800000000
local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

local NONE = { Owned = false, Active = false }
local BOUGHT = { Owned = true, Active = true }
local function trial(endTime)
	return { Owned = false, Active = true, EndTime = endTime }
end

local harness
local now = START
local delayed = {}

afterEach(function()
	if harness then
		harness.Cleanup()
		harness = nil
	end
	Clock.Reset()
	Log.SetRingLevel(nil)
	now = START
	table.clear(delayed)
end)

--- Advance the test clock and run due callbacks in deadline order.
local function advance(seconds: number)
	now += seconds
	while true do
		local due
		for index, item in delayed do
			if item.At <= now and (due == nil or item.At < delayed[due].At) then
				due = index
			end
		end
		if due == nil then
			return
		end
		local item = table.remove(delayed, due)
		local ok, err = coroutine.resume(item.Thread)
		assert(ok, err)
	end
end

--- For[userId] overrides the default ownership response.
local function roblox()
	local state = { Answer = NONE, For = {}, Fails = false, Asked = 0 }
	state.Seam = function(player, _passId)
		state.Asked += 1
		if state.Fails then
			error("HTTP 500 (Internal Server Error)", 0)
		end
		return state.For[player.UserId] or state.Answer
	end
	return state
end

local function make(state, options)
	Clock.Install({
		Now = function()
			return now
		end,
		Delay = function(seconds, callback, ...)
			local args = table.pack(...)
			local thread = coroutine.create(function()
				callback(table.unpack(args, 1, args.n))
			end)
			table.insert(delayed, { At = now + seconds, Thread = thread })
			return thread
		end,
	})
	local merged = {
		Passes = { [PASS] = { Id = PASS_ID } },
		GetPassOwnershipAsync = state.Seam,
		LogRingLevel = "Info",
	}
	for key, value in options or {} do
		merged[key] = value
	end
	harness = TestCtx.make({ Template = { Coins = Scribe.Int(0, { Min = 0 }) }, Options = merged })
	return harness
end

local function changes(h)
	local events = {}
	h.Data.OnOwnershipChanged:Connect(function(_player, key, owned, isTrial)
		table.insert(events, `{key}:{owned}/{isTrial}`)
	end)
	return events
end

local function finish(h, player)
	h.Ctx.Monetization.OnPassPurchaseFinished(player, PASS_ID, true)
end

local function onTrial(state, length: number?, options)
	local h = make(state, options)
	local player = h.Join(9401)
	local events = changes(h)
	state.Answer = trial(if length then now + length else nil)
	finish(h, player)
	return h, player, events
end

local function logged(code: string): number
	return #Scribe.GetRecentLogs({ Code = code, Limit = 100 })
end

local function endsAt(h, player): string
	local found = h.Data.GetTrial(player, PASS)
	return if found then tostring(found.EndsAt) else "none"
end

local function counted(name: string): number
	return Metrics.Get()[name] or 0
end

describe("a trial that starts", function()
	it("gives the pass and leaves it purchasable, without a purchase on record", function()
		local state = roblox()
		local started = logged("PASS_TRIAL_STARTED")
		local h, player, events = onTrial(state, 3600)
		local live = `owns={h.Data.Owns(player, PASS)} ends={endsAt(h, player) == tostring(START + 3600)} `
			.. `state={h.Data.GetProductState(player, PASS)} history={#h.Data.GetPurchases(player)} `
			.. `events={table.concat(events, ",")} started={logged("PASS_TRIAL_STARTED") - started}`
		h.Leave(player)
		local saved = h.Fake.Persisted["Default/PLAYER_9401"]
		expect(
			`{live} | perks={next(saved._Scribe.Perks)} robux={#saved._Scribe.PurchaseLogs.Robux} `
				.. `session={saved._ScribeSession}`
		).toBe(
			"owns=true ends=true state=purchasable history=0 events=VIP:true/true started=1 | "
				.. "perks=nil robux=0 session=nil"
		)
	end)

	it("still prompts the purchase", function()
		local prompted = 0
		local h, player = onTrial(roblox(), 3600, {
			PromptGamePassPurchase = function()
				prompted += 1
			end,
		})
		local ok, why = h.Data.PromptPurchase(player, PASS)
		expect(`ok={ok} why={why} prompted={prompted}`).toBe("ok=true why=nil prompted=1")
	end)

	it("reports the trial to an observer, then the purchase made during it", function()
		local state = roblox()
		local h = make(state)
		local player = h.Join(9402)
		local seen = {}
		h.Data.ObserveOwned(player, PASS, function(owned, isTrial)
			table.insert(seen, `{owned}/{isTrial}`)
		end)
		state.Answer = trial(now + 3600)
		finish(h, player)
		state.Answer = BOUGHT
		finish(h, player)
		expect(table.concat(seen, ",")).toBe("false/false,true/true,true/false")
	end)

	it("is the baseline for a player who joins during it", function()
		local state = roblox()
		state.Answer = trial(now + 200)
		local h = make(state)
		local events = changes(h)
		local player = h.Join(9403)
		local joined = `owns={h.Data.Owns(player, PASS)} ends={endsAt(h, player) == tostring(START + 200)} `
			.. `events={#events}`
		state.Answer = NONE
		advance(201)
		expect(`{joined} | owns={h.Data.Owns(player, PASS)} events={table.concat(events, ",")}`).toBe(
			"owns=true ends=true events=0 | owns=false events=VIP:false/false"
		)
	end)
end)

describe("buying the pass during its trial", function()
	it("records the purchase once and reports it as owned", function()
		local state = roblox()
		local h, player, events = onTrial(state, 3600)
		state.Answer = BOUGHT
		finish(h, player)
		local history = h.Data.GetPurchases(player, { Kind = "Robux" })
		expect(
			`owns={h.Data.Owns(player, PASS)} trial={endsAt(h, player)} state={h.Data.GetProductState(player, PASS)} `
				.. `history={#history}:{history[1] and history[1].From.Type} events={table.concat(events, ",")}`
		).toBe("owns=true trial=none state=owned history=1:GamePass events=VIP:true/true,VIP:true/false")
	end)

	it("is noticed within five minutes when it was bought outside the game", function()
		local state = roblox()
		local h, player, events = onTrial(state, 3600)
		state.Answer = BOUGHT
		local asked = state.Asked
		advance(299)
		local before = `asked={state.Asked - asked} trial={endsAt(h, player) ~= "none"}`
		advance(1)
		expect(`{before} | asked={state.Asked - asked} trial={endsAt(h, player)} events={events[#events]}`).toBe(
			"asked=0 trial=true | asked=1 trial=none events=VIP:true/false"
		)
	end)

	it("keeps the pass when an older answer says the trial was all there was", function()
		local state = roblox()
		local h, player = onTrial(state, 200)
		state.Answer = BOUGHT
		finish(h, player)
		state.Answer = NONE
		advance(201)
		expect(`owns={h.Data.Owns(player, PASS)} async={h.Data.OwnsAsync(player, PASS)}`).toBe("owns=true async=true")
	end)
end)

describe("a trial that ends", function()
	it("takes the pass away when it is due, and not before", function()
		local state = roblox()
		local ended = logged("PASS_TRIAL_ENDED")
		local starts, ends = counted("PassTrialsStarted"), counted("PassTrialsEnded")
		local h, player, events = onTrial(state, 200)
		state.Answer = NONE
		local asked = state.Asked
		advance(200)
		local before = `owns={h.Data.Owns(player, PASS)} asked={state.Asked - asked}`
		advance(1)
		expect(
			`{before} | owns={h.Data.Owns(player, PASS)} asked={state.Asked - asked} trial={endsAt(h, player)} `
				.. `events={table.concat(events, ",")} ended={logged("PASS_TRIAL_ENDED") - ended} `
				.. `counted={counted("PassTrialsStarted") - starts}/{counted("PassTrialsEnded") - ends}`
		).toBe(
			"owns=true asked=0 | owns=false asked=1 trial=none events=VIP:true/true,VIP:false/false ended=1 "
				.. "counted=1/1"
		)
	end)

	it("stays while Roblox still reports it, and is asked about again a minute later", function()
		local state = roblox()
		local h, player, events = onTrial(state, 200)
		local asked = state.Asked
		advance(201)
		local held = `owns={h.Data.Owns(player, PASS)} asked={state.Asked - asked}`
		advance(59)
		local waiting = state.Asked - asked
		state.Answer = NONE
		advance(1)
		expect(`{held} waiting={waiting} | owns={h.Data.Owns(player, PASS)} events={#events}`).toBe(
			"owns=true asked=1 waiting=1 | owns=false events=2"
		)
	end)

	it("stays through a failed check, which is asked again", function()
		local state = roblox()
		local failures = counted("OwnershipCheckFailures")
		local h, player = onTrial(state, 200)
		state.Fails = true
		advance(201)
		local held = `owns={h.Data.Owns(player, PASS)} failed={counted("OwnershipCheckFailures") - failures}`
		state.Fails, state.Answer = false, NONE
		advance(60)
		expect(`{held} | owns={h.Data.Owns(player, PASS)}`).toBe("owns=true failed=1 | owns=false")
	end)

	it("is asked about every minute when Roblox names no end", function()
		local state = roblox()
		local h, player = onTrial(state, nil)
		local asked = state.Asked
		advance(59)
		local before = `ends={endsAt(h, player)} asked={state.Asked - asked}`
		advance(1)
		expect(`{before} | asked={state.Asked - asked} owns={h.Data.Owns(player, PASS)}`).toBe(
			"ends=nil asked=0 | asked=1 owns=true"
		)
	end)

	it("stops being watched once the player has left", function()
		local state = roblox()
		local h, player = onTrial(state, 200)
		h.Leave(player)
		local asked = state.Asked
		advance(201)
		expect(state.Asked - asked).toBe(0)
	end)

	it("stops being watched once the bundle has stopped", function()
		local state = roblox()
		local h = onTrial(state, 200)
		h.Data.Stop()
		local asked = state.Asked
		advance(201)
		expect(state.Asked - asked).toBe(0)
	end)
end)

describe("asking about a pass on trial", function()
	it("OwnsAsync asks Roblox again for a trial, and not for a pass that was bought", function()
		local state = roblox()
		local h, player = onTrial(state, 3600)
		local asked = state.Asked
		local during = `owns={h.Data.OwnsAsync(player, PASS)} asked={state.Asked - asked}`
		state.Answer = BOUGHT
		local bought = `owns={h.Data.OwnsAsync(player, PASS)} asked={state.Asked - asked}`
		state.Answer = NONE
		expect(`{during} | {bought} | owns={h.Data.OwnsAsync(player, PASS)} asked={state.Asked - asked}`).toBe(
			"owns=true asked=1 | owns=true asked=2 | owns=true asked=2"
		)
	end)

	it("OwnsAsync reports a trial that has ended without waiting for the watch", function()
		local state = roblox()
		local h, player, events = onTrial(state, 3600)
		state.Answer = NONE
		expect(`async={h.Data.OwnsAsync(player, PASS)} owns={h.Data.Owns(player, PASS)} events={events[#events]}`).toBe(
			"async=false owns=false events=VIP:false/false"
		)
	end)

	it("follows an end that moved, and keeps one watch however often it is asked", function()
		local state = roblox()
		local h, player = onTrial(state, 200)
		local pending, ends = #delayed, counted("PassTrialsEnded")
		for _ = 1, 3 do
			h.Data.OwnsAsync(player, PASS)
		end
		local repeated = #delayed - pending
		state.Answer = trial(now + 100)
		h.Data.OwnsAsync(player, PASS)
		local movedTo = endsAt(h, player) == tostring(START + 100)
		state.Answer = NONE
		local asked = state.Asked
		advance(100)
		local early = state.Asked - asked
		advance(1)
		local moved = state.Asked - asked
		advance(100)
		expect(
			`repeated={repeated} movedTo={movedTo} early={early} moved={moved} stale={state.Asked - asked} `
				.. `ended={counted("PassTrialsEnded") - ends}`
		).toBe("repeated=0 movedTo=true early=0 moved=1 stale=1 ended=1")
	end)

	it("asks once, at the new time, when the end moves later", function()
		local state = roblox()
		local h, player = onTrial(state, 100)
		state.Answer = trial(now + 200)
		h.Data.OwnsAsync(player, PASS)
		local asked = state.Asked
		advance(101)
		local atOldEnd = state.Asked - asked
		advance(100)
		expect(`old={atOldEnd} new={state.Asked - asked} owns={h.Data.Owns(player, PASS)}`).toBe(
			"old=0 new=1 owns=true"
		)
	end)

	it("a perk under the same name is ownership, whatever the trial says", function()
		local state = roblox()
		local h, player, events = onTrial(state, 200)
		h.Data.GrantPerk(player, PASS)
		local granted = `trial={endsAt(h, player)} state={h.Data.GetProductState(player, PASS)}`
		state.Answer = NONE
		advance(201)
		expect(`{granted} | owns={h.Data.Owns(player, PASS)} events={table.concat(events, ",")}`).toBe(
			"trial=none state=owned | owns=true events=VIP:true/true,VIP:true/false"
		)
	end)
end)

describe("GetTrial", function()
	it("is nil for a pass the player does not have, and names itself for a key that is not a string", function()
		local h = make(roblox())
		local player = h.Join(9413)
		local ok, err = pcall(h.Data.GetTrial, player, PASS_ID)
		expect(
			`none={h.Data.GetTrial(player, PASS)} raised={not ok} `
				.. `named={string.find(tostring(err), "Scribe: GetTrial: key must be a string", 1, true) ~= nil}`
		).toBe("none=nil raised=true named=true")
	end)
end)

describe("answers that arrive out of order", function()
	it("an older not-owned answer does not end a trial a newer one confirmed", function()
		local waiting = {}
		local answer = NONE
		local h = make({
			Seam = function()
				local captured = answer
				table.insert(waiting, coroutine.running())
				coroutine.yield()
				return captured
			end,
		})
		local player = h.Join(9404)
		answer = trial(now + 3600)
		task.spawn(finish, h, player)
		task.spawn(table.remove(waiting, 2))
		local confirmed = h.Data.Owns(player, PASS)
		task.spawn(table.remove(waiting, 1))
		expect(`confirmed={confirmed} owns={h.Data.Owns(player, PASS)} trial={endsAt(h, player) ~= "none"}`).toBe(
			"confirmed=true owns=true trial=true"
		)
	end)
end)

describe("a perk product named after the pass", function()
	local BUYER, RECIPIENT = 9411, 9412

	local function shop(state)
		local prompted = {}
		local h = make(state, {
			Products = { VIPGift = { Id = GIFT_ID, Grants = PASS } },
			PromptProductPurchase = function(player, productId)
				table.insert(prompted, `{player.UserId}:{productId}`)
			end,
		})
		return h, prompted
	end

	it("bought during the trial grants the perk rather than a gift credit", function()
		local state = roblox()
		local h = shop(state)
		local buyer, entry = h.Join(BUYER)
		local events = changes(h)
		state.Answer = trial(now + 3600)
		finish(h, buyer)
		local decision = h.Data.HandleReceipt({
			PlayerId = BUYER,
			ProductId = GIFT_ID,
			PurchaseId = "paid-during-trial",
			CurrencySpent = 99,
			ProductPurchaseChannel = Enum.ProductPurchaseChannel.InExperience,
		})
		local reserved = entry.LiveData._Scribe
		expect(
			`granted={decision == GRANTED} perk={reserved.Perks[PASS]} credits={next(reserved.GiftCredits)} `
				.. `trial={endsAt(h, buyer)} events={table.concat(events, ",")}`
		).toBe("granted=true perk=true credits=nil trial=none events=VIP:true/true,VIP:true/false")
	end)

	it("can be gifted to a player who only has the trial", function()
		local state = roblox()
		local h, prompted = shop(state)
		local buyer = h.Join(BUYER)
		h.Join(RECIPIENT)
		state.For[RECIPIENT] = trial(now + 3600)
		finish(h, h.Ctx.Persistence.EntryForUserId(RECIPIENT).Player)
		local ok, why = h.Data.PromptGift(buyer, "VIPGift", RECIPIENT)
		expect(`ok={ok} why={why} prompted={table.concat(prompted, ",")}`).toBe(
			`ok=true why=nil prompted={BUYER}:{GIFT_ID}`
		)
	end)

	it("is refused for a recipient who bought the pass after joining", function()
		local state = roblox()
		local h, prompted = shop(state)
		local buyer = h.Join(BUYER)
		h.Join(RECIPIENT)
		state.For[RECIPIENT] = BOUGHT
		local ok, why = h.Data.PromptGift(buyer, "VIPGift", RECIPIENT)
		expect(`ok={ok} why={why} prompted={#prompted}`).toBe("ok=false why=recipient already owns this prompted=0")
	end)
end)

describe("reading the trial's end", function()
	local shapes = {
		{ Name = "seconds", Value = START + 3600 },
		{ Name = "milliseconds", Value = (START + 3600) * 1000 },
		{ Name = "an ISO 8601 string", Value = DateTime.fromUnixTimestamp(START + 3600):ToIsoDate() },
		{ Name = "a DateTime", Value = DateTime.fromUnixTimestamp(START + 3600) },
	}
	for _, shape in shapes do
		it(`accepts {shape.Name}`, function()
			local state = roblox()
			local h = make(state)
			local player = h.Join(9405)
			state.Answer = trial(shape.Value)
			finish(h, player)
			expect(endsAt(h, player)).toBe(tostring(START + 3600))
		end)
	end

	it("reports a trial with no usable end as a trial without one", function()
		local state = roblox()
		local h = make(state)
		local player = h.Join(9406)
		state.Answer = trial("soon")
		finish(h, player)
		expect(`owns={h.Data.Owns(player, PASS)} ends={endsAt(h, player)}`).toBe("owns=true ends=nil")
	end)
end)

describe("an engine whose ownership read does not answer", function()
	local function legacy(answer)
		local warned = logged("PASS_TRIAL_READ_FAIL")
		local h = make({ Seam = answer }, {
			UserOwnsGamePassAsync = function()
				return true
			end,
		})
		local player = h.Join(9407)
		h.Join(9408)
		return `owns={h.Data.Owns(player, PASS)} trial={endsAt(h, player)} `
			.. `warned={logged("PASS_TRIAL_READ_FAIL") - warned}`
	end

	it("reads ownership the old way when the call raises, and says so once", function()
		expect(legacy(function()
			error("GetPassOwnershipAsync is not enabled", 0)
		end)).toBe("owns=true trial=none warned=1")
	end)

	it("reads ownership the old way when the answer carries no ownership", function()
		expect(legacy(function()
			return {}
		end)).toBe("owns=true trial=none warned=1")
	end)

	it("does not fall back once the call has answered on this server", function()
		local state = roblox()
		local h = make(state, {
			UserOwnsGamePassAsync = function()
				return true
			end,
		})
		local player = h.Join(9409)
		state.Fails = true
		expect(`async={h.Data.OwnsAsync(player, PASS)} owns={h.Data.Owns(player, PASS)}`).toBe("async=false owns=false")
	end)

	it("does not record a purchase the failed read could not confirm", function()
		local state = roblox()
		local h = make(state, {
			UserOwnsGamePassAsync = function()
				return true
			end,
		})
		local player = h.Join(9410)
		state.Fails = true
		finish(h, player)
		expect(`owns={h.Data.Owns(player, PASS)} history={#h.Data.GetPurchases(player)}`).toBe("owns=false history=0")
	end)
end)
