--!nonstrict
-- Replies wait for repair snapshots within half the RequestTimeout.
-- Coroutine status records when each request resumes.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Scribe = require(Root.Scribe)
local Client = require(Root.Scribe.Client)
local Clock = require(Root.Scribe.Internal.Clock)
local Metrics = require(Root.Scribe.Internal.Metrics)
local Wire = require(Root.Scribe.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local FRAME_NAMES = {}
for name, id in Wire.Frames do
	FRAME_NAMES[id] = name
end

local harness: any = nil
local client: any = nil
local now = 1000

afterEach(function()
	Clock.Reset()
	if client then
		client.Stop()
		client = nil
	end
	if harness then
		harness.Cleanup()
		harness = nil
	end
end)

-- Advance cooldowns without waiting.
local function useClock()
	now = 1000
	Clock.Install({
		Monotonic = function()
			return now
		end,
	})
end

local function setup(userId: number, cfg: { [string]: any }?)
	local c = cfg or {}
	local options = { RequestTimeout = 30, CommandRateLimit = 1000 }
	for key, value in c.Options or {} do
		options[key] = value
	end
	harness = TestCtx.make({ AutoPump = true, Template = c.Template or { Coins = Scribe.Int(0) }, Options = options })
	local player, entry, data = harness.Join(userId)
	harness.Transport.LocalPlayer = player
	client = Client.new(harness.Options, harness.Compiled)
	harness.StepUntil(function()
		return client.IsReady()
	end)
	return player, entry, data
end

local function buy(data)
	harness.Data.Command("Buy", function()
		data.Coins.Set(data.Coins.Get() + 50)
		return true
	end)
end

-- Capture the data visible when Request resumes.
local function request(method: string, args: { any }, after: (() -> any)?)
	local call: { [string]: any } = { Done = false }
	call.Thread = coroutine.create(function()
		call.Results = table.pack(client[method](table.unpack(args)))
		-- Catch timeouts that resume after the test ends.
		pcall(function()
			call.Coins = client.Coins.Get()
			if after then
				call.Seen = after()
			end
		end)
		call.Done = true
	end)
	local ok, err = coroutine.resume(call.Thread)
	assert(ok, err)
	return call
end

local function status(call): string
	return coroutine.status(call.Thread)
end

local function framesAfter(player, mark: number): string
	local names = {}
	for i, frame in harness.FramesFor(player) do
		if i > mark then
			table.insert(names, FRAME_NAMES[frame.Type] or tostring(frame.Type))
		end
	end
	return table.concat(names, ",")
end

local function replyCorrelationsAfter(player, mark: number): string
	local out = {}
	for i, frame in harness.FramesFor(player) do
		if i > mark and frame.Type == Wire.Frames.CommandReply then
			table.insert(out, tostring(frame.Correlation))
		end
	end
	return table.concat(out, ",")
end

-- Fail the next refuse[kind] sends to this player.
local function refuser(player)
	local real = harness.Transport.SendToClient
	local refuse: { [number]: number } = {}
	harness.Transport.SendToClient = function(self, target, bytes)
		local kind = buffer.readu8(bytes, 0)
		if target == player and (refuse[kind] or 0) > 0 then
			refuse[kind] -= 1
			error("transport adapter: refused", 0)
		end
		return real(self, target, bytes)
	end
	return refuse
end

local function metric(name: string): number
	return Metrics.Get()[name] or 0
end

-- Run due timers manually. Join timers stay real because setup runs first.
local function recordDelays(): () -> ()
	local delays = {}
	Clock.Install({
		Delay = function(seconds: number, fn, ...)
			table.insert(delays, { At = now + seconds, Fn = fn, Args = table.pack(...), Fired = false })
			return coroutine.create(function() end)
		end,
	})
	return function()
		for _, delay in delays do
			if not delay.Fired and delay.At <= now then
				delay.Fired = true
				delay.Fn(table.unpack(delay.Args, 1, delay.Args.n))
			end
		end
	end
end

-- The returned release resumes the handler.
local function slowCommand(spec: { [string]: any }?, after: (() -> ())?): () -> ()
	local threads = {}
	local function handler()
		table.insert(threads, coroutine.running())
		coroutine.yield()
		if after then
			after()
		end
		return true
	end
	if spec then
		harness.Data.Command("Slow", spec, handler)
	else
		harness.Data.Command("Slow", handler)
	end
	return function()
		for _, thread in threads do
			task.spawn(thread)
		end
		table.clear(threads)
	end
end

local function commandFrame(correlation: number, name: string, key: string?): buffer
	local w = Wire.NewWriter(32)
	Wire.U8(w, Wire.Frames.Command)
	Wire.U32(w, correlation)
	Wire.Str(w, name)
	Wire.U8(w, 0)
	Wire.Str(w, key or "")
	return Wire.Finish(w)
end

local function inject(player, correlation: number, name: string, key: string?)
	harness.Transport:InjectToServer(player, commandFrame(correlation, name, key))
end

-- Use a separate thread so the handler can yield.
local function injectSpawned(player, correlation: number, name: string, key: string?)
	task.spawn(inject, player, correlation, name, key)
end

describe("a reply while its client waits for a repair snapshot", function()
	it("follows the snapshot, which carries the handler's writes", function()
		useClock()
		local player, entry, data = setup(88820)
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local mark = #harness.FramesFor(player)
		local call = request("Request", { "Buy" })
		local before = `{status(call)} [{framesAfter(player, mark)}]`
		harness.Step()
		expect(`{before} -> {status(call)} ok={call.Results[1]} coins={call.Coins} [{framesAfter(player, mark)}]`).toBe(
			"suspended [] -> dead ok=true coins=50 [Init,Status,CommandReply]"
		)
	end)

	it("follows the snapshot for a handler that threw, whose earlier writes stand", function()
		useClock()
		local _player, entry, data = setup(88840)
		harness.Data.Command("Boom", function()
			data.Coins.Set(7)
			error("boom")
		end)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local call = request("Request", { "Boom" })
		local before = status(call)
		harness.Step()
		expect(`{before} -> {status(call)} {call.Results[1]} {call.Results[2]} coins={call.Coins}`).toBe(
			"suspended -> dead false error coins=7"
		)
	end)

	it("waits out the cooldown after a second failure, and no longer", function()
		useClock()
		local player, entry, data = setup(88821)
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now += 1
		harness.Ctx.Replication.RequestResync(entry, "second")
		local mark = #harness.FramesFor(player)
		local call = request("Request", { "Buy" })
		local done = {}
		for _, advance in { 0, 1, 1, 1, 1, 1 } do
			now += advance
			harness.Step()
			table.insert(done, tostring(call.Done))
		end
		local inits = select(2, string.gsub(framesAfter(player, mark), "Init", ""))
		expect(`{table.concat(done, " ")} coins={call.Coins} lastResync={entry.LastResyncAt} inits={inits}`).toBe(
			"false false false false true true coins=50 lastResync=1005 inits=1"
		)
	end)

	it("is not held when the snapshot is not due within half the RequestTimeout", function()
		useClock()
		local _player, entry, data = setup(88822, { Options = { RequestTimeout = 4 } })
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now += 1
		harness.Ctx.Replication.RequestResync(entry, "second")
		local heldBefore = metric("CommandRepliesHeld")
		-- Due at 1005; the handler starts at 1001 and may wait until 1003.
		local call = request("Request", { "Buy" })
		local atOnce = `{status(call)} coins={call.Coins} held={metric("CommandRepliesHeld") - heldBefore}`
		now += 4
		harness.Step()
		expect(`{atOnce} later={client.Coins.Get()}`).toBe("dead coins=0 held=0 later=50")
	end)

	it("goes at once when the snapshot is refused, and nothing is held until one lands", function()
		useClock()
		local player, entry, data = setup(88823)
		buy(data)
		local refuse = refuser(player)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local first = request("Request", { "Buy" })
		local firstBefore = status(first)
		refuse[Wire.Frames.Init] = math.huge
		harness.Step()
		local afterRefused =
			`first={firstBefore}->{status(first)} ok={first.Results[1]} coins={first.Coins} failed={entry.ResyncFailed}`
		local second = request("Request", { "Buy" })
		local secondNow = `second={status(second)} coins={second.Coins}`
		refuse[Wire.Frames.Init] = 0
		now += 5
		harness.Step()
		local healed = `healed failed={entry.ResyncFailed} client={client.Coins.Get()}`
		harness.Ctx.Replication.RequestResync(entry, "again")
		local third = request("Request", { "Buy" })
		local thirdBefore = status(third)
		now += 5
		harness.Step()
		expect(`{afterRefused} | {secondNow} | {healed} | third={thirdBefore}->{status(third)} coins={third.Coins}`).toBe(
			"first=suspended->dead ok=true coins=0 failed=true | second=dead coins=0 | healed failed=false client=100 | third=suspended->dead coins=150"
		)
	end)

	it("is answered fresh when the repair's Status was refused, and nothing is held after", function()
		useClock()
		local player, entry, data = setup(88824)
		buy(data)
		local refuse = refuser(player)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local heldBefore = metric("CommandRepliesHeld")
		local first = request("Request", { "Buy" })
		refuse[Wire.Frames.Status] = 1
		harness.Step()
		local flags = `HR={entry.HandshakeReady} RP={entry.ResyncPending}`
		local second = request("Request", { "Buy" })
		expect(
			`first={status(first)} coins={first.Coins} {flags} | second={status(second)} coins={second.Coins} held={metric(
				"CommandRepliesHeld"
			) - heldBefore}`
		).toBe("first=dead coins=50 HR=true RP=true | second=dead coins=100 held=1")
	end)

	it("is held when the handler's own Diff is lost after such a repair", function()
		-- A second loss must close the queue even while repair is pending.
		useClock()
		local player, entry, data = setup(88825)
		buy(data)
		local refuse = refuser(player)
		harness.Ctx.Replication.RequestResync(entry, "test")
		refuse[Wire.Frames.Status] = 1
		harness.Step()
		refuse[Wire.Frames.Diff] = 1
		local call = request("Request", { "Buy" })
		local before = status(call)
		now += 5
		harness.Step()
		expect(`{before} -> {status(call)} coins={call.Coins}`).toBe("suspended -> dead coins=50")
	end)

	it("is released fresh when the attempt throws after the Init landed", function()
		useClock()
		local _player, entry, data = setup(88826)
		buy(data)
		local leaderboards = harness.Ctx.Leaderboards
		local realReady = leaderboards.OnClientReady
		local throws = 1
		leaderboards.OnClientReady = function(...)
			if throws > 0 then
				throws -= 1
				error("boards failed", 0)
			end
			return realReady(...)
		end
		local failedBefore = metric("InitSendFailed")
		harness.Ctx.Replication.RequestResync(entry, "test")
		local call = request("Request", { "Buy" })
		harness.Step()
		leaderboards.OnClientReady = realReady
		expect(`{status(call)} coins={call.Coins} initSendFailed={metric("InitSendFailed") - failedBefore}`).toBe(
			"dead coins=50 initSendFailed=1"
		)
	end)

	it("is released by a Hello's snapshot too, even one that throws after the Init landed", function()
		useClock()
		local player, entry, data = setup(88827)
		buy(data)
		local leaderboards = harness.Ctx.Leaderboards
		local realReady = leaderboards.OnClientReady
		local throws = 1
		leaderboards.OnClientReady = function(...)
			if throws > 0 then
				throws -= 1
				error("boards failed", 0)
			end
			return realReady(...)
		end
		harness.Ctx.Replication.RequestResync(entry, "test")
		local call = request("Request", { "Buy" })
		local before = status(call)
		local failedBefore = metric("InitSendFailed")
		-- The Hello attempt releases the reply before the next repair.
		harness.SendHello(player)
		leaderboards.OnClientReady = realReady
		expect(
			`{before} -> {status(call)} coins={call.Coins} pending={entry.ResyncPending} throwsLeft={throws} initSendFailed={metric(
				"InitSendFailed"
			) - failedBefore}`
		).toBe("suspended -> dead coins=50 pending=true throwsLeft=0 initSendFailed=1")
	end)

	it("follows the other players' SharedInits, which the Init emptied", function()
		useClock()
		local template = { Coins = Scribe.Int(0), Pub = Scribe.Shared({ Title = Scribe.String("") }) }
		local player, entry, data = setup(88828, { Template = template })
		buy(data)
		local other, _otherEntry, otherData = harness.Join(88829)
		otherData.Pub.Title.Set("bee")
		harness.Step()
		local seenBefore = (client.GetShared(other.UserId) or {}).Pub
		harness.Ctx.Replication.RequestResync(entry, "test")
		local mark = #harness.FramesFor(player)
		local call = request("Request", { "Buy" }, function()
			local shared = client.GetShared(other.UserId)
			return if shared then shared.Pub.Title else "none"
		end)
		harness.Step()
		expect(`before={seenBefore and seenBefore.Title} {status(call)} seen={call.Seen} [{framesAfter(player, mark)}]`).toBe(
			"before=bee dead seen=bee [Init,Status,SharedInit,CommandReply]"
		)
	end)

	it("never holds a refusal, which describes no change", function()
		useClock()
		local _player, entry, data = setup(88830)
		buy(data)
		harness.Data.Command("Typed", { Args = { "number" } }, function()
			return true
		end)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local heldBefore = metric("CommandRepliesHeld")
		local seen = {}
		for _, args in { { "Nope" }, { "Typed", "x" }, { "Typed", 1, 2 } } do
			local call = request("Request", args)
			table.insert(seen, `{status(call)} {call.Results[2]} {call.Results[3] == Scribe.RequestFailed}`)
		end
		local keyed = request("RequestOnce", { "Buy", "k" })
		table.insert(seen, `{status(keyed)} {keyed.Results[2]}`)
		expect(`{table.concat(seen, " | ")} | held={metric("CommandRepliesHeld") - heldBefore}`).toBe(
			"dead unknown-command true | dead bad-args true | dead bad-args true | dead bad-idempotency-key | held=0"
		)
	end)

	it("never holds a rate-limited refusal", function()
		useClock()
		local _player, entry, data = setup(88846, { Options = { CommandRateLimit = 1 } })
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local handled = request("Request", { "Buy" })
		local limited = request("Request", { "Buy" })
		expect(`{status(handled)} | {status(limited)} {limited.Results[2]}`).toBe("suspended | dead rate-limited")
	end)

	it("never holds the refusal of one duplicate too many, or of one key too many", function()
		useClock()
		local player, entry = setup(88847)
		local release = slowCommand({ Idempotent = true })
		local mark = #harness.FramesFor(player)
		-- One call and its 32 parked duplicates, then a 34th.
		for correlation = 1, 33 do
			injectSpawned(player, correlation, "Slow", "k")
		end
		-- 63 more keys in flight, for 64, then a 65th.
		for correlation = 101, 163 do
			injectSpawned(player, correlation, "Slow", `k{correlation}`)
		end
		harness.Ctx.Replication.RequestResync(entry, "test")
		inject(player, 34, "Slow", "k")
		inject(player, 164, "Slow", "k164")
		local refused = replyCorrelationsAfter(player, mark)
		release()
		expect(`refused=[{refused}]`).toBe("refused=[34,164]")
	end)

	it("holds an idempotent replay too, since the snapshot carries the cached writes", function()
		useClock()
		local _player, entry, data = setup(88831)
		local runs = 0
		harness.Data.Command("Grant", { Idempotent = true }, function()
			runs += 1
			data.Coins.Set(data.Coins.Get() + 50)
			return true
		end)
		local first = request("RequestOnce", { "Grant", "k" })
		-- The replay deadline falls before the next repair in 4s.
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now += 1
		harness.Ctx.Replication.RequestResync(entry, "second")
		local dedupedBefore = metric("CommandsDeduped")
		local replay = request("RequestOnce", { "Grant", "k" })
		local before = status(replay)
		now += 4
		harness.Step()
		expect(
			`first={status(first)} replay={before}->{status(replay)} ok={replay.Results[1]} coins={replay.Coins} runs={runs} deduped={metric(
				"CommandsDeduped"
			) - dedupedBefore}`
		).toBe("first=dead replay=suspended->dead ok=true coins=50 runs=1 deduped=1")
	end)

	it("holds a reply whose repair is due exactly at its deadline", function()
		useClock()
		local _player, entry, data = setup(88844, { Options = { RequestTimeout = 4 } })
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now = 1003
		-- Due at 1005; the handler starts at 1003 and may wait until 1005.
		harness.Ctx.Replication.RequestResync(entry, "second")
		local call = request("Request", { "Buy" })
		local before = status(call)
		now = 1005
		harness.Step()
		expect(`{before} -> {status(call)} coins={call.Coins}`).toBe("suspended -> dead coins=50")
	end)

	it("measures the wait from the handler's start, not its reply", function()
		useClock()
		local player, entry = setup(88843, { Options = { RequestTimeout = 4 } })
		local release = slowCommand()
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now = 1002
		local mark = #harness.FramesFor(player)
		injectSpawned(player, 1, "Slow")
		harness.Ctx.Replication.RequestResync(entry, "second")
		-- Started at 1002, so it may wait until 1004, and the repair is due at 1005.
		now = 1003.5
		release()
		expect(`replies=[{replyCorrelationsAfter(player, mark)}] held={entry.HeldReplies}`).toBe("replies=[1] held=nil")
	end)

	it("gives parked duplicates the first call's deadline", function()
		useClock()
		local player, entry = setup(88848, { Options = { RequestTimeout = 4 } })
		local release = slowCommand({ Idempotent = true })
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now = 1002
		local mark = #harness.FramesFor(player)
		injectSpawned(player, 1, "Slow", "k")
		now = 1003.5
		inject(player, 2, "Slow", "k")
		inject(player, 3, "Slow", "k")
		harness.Ctx.Replication.RequestResync(entry, "second")
		release()
		expect(`replies=[{replyCorrelationsAfter(player, mark)}] held={entry.HeldReplies}`).toBe(
			"replies=[1,2,3] held=nil"
		)
	end)

	it("holds the duplicates parked on an in-flight call behind it", function()
		useClock()
		local player, entry, data = setup(88832)
		local release
		harness.Data.Command("Slow", { Idempotent = true }, function()
			local handlerThread = coroutine.running()
			release = function()
				task.spawn(handlerThread)
			end
			coroutine.yield()
			data.Coins.Set(data.Coins.Get() + 50)
			return true
		end)
		-- The duplicates expire before the next repair in 4s.
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now += 1
		local mark = #harness.FramesFor(player)
		task.spawn(function()
			harness.Transport:InjectToServer(player, commandFrame(1, "Slow", "k"))
		end)
		harness.Transport:InjectToServer(player, commandFrame(2, "Slow", "k"))
		harness.Transport:InjectToServer(player, commandFrame(3, "Slow", "k"))
		harness.Ctx.Replication.RequestResync(entry, "second")
		release()
		local before = replyCorrelationsAfter(player, mark)
		now += 4
		harness.Step()
		expect(`before=[{before}] after=[{replyCorrelationsAfter(player, mark)}] [{framesAfter(player, mark)}]`).toBe(
			"before=[] after=[1,2,3] [Init,Status,CommandReply,CommandReply,CommandReply]"
		)
	end)
end)

describe("a held reply whose snapshot will not come", function()
	it("is answered when the session ends, on the data the client last had", function()
		useClock()
		local _player, entry, data = setup(88833, { Options = { KickOnSessionEnd = false } })
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local call = request("Request", { "Buy" })
		local before = status(call)
		entry.Profile:EndSession()
		expect(`{before} -> {status(call)} ok={call.Results and call.Results[1]} coins={call.Coins}`).toBe(
			"suspended -> dead ok=true coins=0"
		)
	end)

	it("is dropped when the player has left", function()
		useClock()
		local player, entry, data = setup(88834)
		buy(data)
		recordDelays()
		harness.Ctx.Replication.RequestResync(entry, "test")
		local mark = #harness.FramesFor(player)
		local heldBefore = metric("CommandRepliesHeld")
		local call = request("Request", { "Buy" })
		local held = metric("CommandRepliesHeld") - heldBefore
		harness.Leave(player)
		expect(`{status(call)} held={held} replies=[{replyCorrelationsAfter(player, mark)}] left={entry.HeldReplies}`).toBe(
			"suspended held=1 replies=[] left=nil"
		)
	end)

	it("is not held at all for a handler that outlived its session", function()
		useClock()
		local player, entry, data = setup(88835, { Options = { KickOnSessionEnd = false } })
		local release
		harness.Data.Command("Slow", function()
			local handlerThread = coroutine.running()
			release = function()
				task.spawn(handlerThread)
			end
			coroutine.yield()
			return true
		end)
		local _ = data
		local mark = #harness.FramesFor(player)
		task.spawn(function()
			harness.Transport:InjectToServer(player, commandFrame(1, "Slow"))
		end)
		harness.Ctx.Replication.RequestResync(entry, "test")
		entry.Profile:EndSession()
		local heldBefore = metric("CommandRepliesHeld")
		release()
		expect(`replies=[{replyCorrelationsAfter(player, mark)}] held={metric("CommandRepliesHeld") - heldBefore}`).toBe(
			"replies=[1] held=0"
		)
	end)

	it("is answered by Data.Stop, and none is held after it", function()
		useClock()
		local player, entry, data = setup(88836)
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local call = request("Request", { "Buy" })
		local before = status(call)
		harness.Data.Stop()
		local stopped = `{before} -> {status(call)} ok={call.Results and call.Results[1]} held={entry.HeldReplies}`
		-- Stop leaves no flush loop to release held replies.
		harness.Ctx.Replication.RequestResync(entry, "after stop")
		local mark = #harness.FramesFor(player)
		local reader = Wire.NewReader(commandFrame(7, "Buy"))
		Wire.RU8(reader)
		harness.Ctx.Commands.HandleFrame(entry, reader)
		expect(`{stopped} | after=[{replyCorrelationsAfter(player, mark)}]`).toBe(
			"suspended -> dead ok=true held=nil | after=[7]"
		)
	end)

	it("is answered at its deadline, and not before", function()
		useClock()
		local _player, entry, data = setup(88837, { Options = { RequestTimeout = 4 } })
		buy(data)
		recordDelays()
		harness.Ctx.Replication.RequestResync(entry, "test")
		local first = request("Request", { "Buy" })
		local second = request("Request", { "Buy" })
		-- Repair moved beyond the replies' 2s deadline.
		entry.LastResyncAt = now
		local expiredBefore = metric("CommandReplyHoldsExpired")
		now = 1001.5
		harness.Step()
		local early = `{status(first)} expired={metric("CommandReplyHoldsExpired") - expiredBefore}`
		now = 1002
		harness.Step()
		expect(
			`{early} -> {status(first)} {status(second)} ok={first.Results and first.Results[1]} coins={first.Coins} expired={metric(
				"CommandReplyHoldsExpired"
			) - expiredBefore}`
		).toBe("suspended expired=0 -> dead dead ok=true coins=0 expired=2")
	end)

	it("wakes the flush loop at the deadline for a client the loop had dropped", function()
		useClock()
		local _player, entry, data = setup(88841, { Options = { RequestTimeout = 4 } })
		buy(data)
		local fire = recordDelays()
		harness.Ctx.Replication.RequestResync(entry, "test")
		local call = request("Request", { "Buy" })
		entry.LastResyncAt = now
		-- Simulate teardown removing the entry from the dirty set.
		entry.TornDown = true
		harness.Step()
		entry.TornDown = false
		now = 1002
		harness.Step()
		local unwoken = status(call)
		fire()
		harness.Step()
		expect(`{unwoken} -> {status(call)} coins={call.Coins}`).toBe("suspended -> dead coins=0")
	end)

	it("lets a repair due in the deadline's own frame go first", function()
		-- At the default timeout, the reply deadline and repair fall in the same frame.
		-- The timer may run before the flush.
		useClock()
		local player, entry, data = setup(88842, { Options = { RequestTimeout = 10 } })
		buy(data)
		local fire = recordDelays()
		local refuse = refuser(player)
		harness.Ctx.Replication.RequestResync(entry, "first")
		harness.Step()
		now = 1000.25
		refuse[Wire.Frames.Diff] = 1
		local mark = #harness.FramesFor(player)
		local call = request("Request", { "Buy" })
		local before = status(call)
		local expiredBefore = metric("CommandReplyHoldsExpired")
		now = 1005.5
		fire()
		harness.Step()
		expect(
			`{before} -> {status(call)} coins={call.Coins} expired={metric("CommandReplyHoldsExpired") - expiredBefore} [{framesAfter(
				player,
				mark
			)}]`
		).toBe("suspended -> dead coins=50 expired=0 [Init,Status,CommandReply]")
	end)

	it("moves the deadline up when an earlier one joins the held replies", function()
		useClock()
		local player, entry, data = setup(88845, { Options = { RequestTimeout = 4 } })
		buy(data)
		local release = slowCommand()
		local mark = #harness.FramesFor(player)
		-- Starts at 1000, so it may wait until 1002.
		injectSpawned(player, 1, "Slow")
		harness.Ctx.Replication.RequestResync(entry, "test")
		now = 1001
		-- Starts at 1001 and is held first, until 1003.
		inject(player, 2, "Buy")
		release()
		-- The repair is now 5 s out, so only the deadline releases them.
		entry.LastResyncAt = now
		now = 1002
		harness.Step()
		expect(`replies=[{replyCorrelationsAfter(player, mark)}]`).toBe("replies=[2,1]")
	end)

	it("goes at once past MAX_HELD_REPLIES", function()
		useClock()
		local player, entry, data = setup(88838)
		buy(data)
		harness.Ctx.Replication.RequestResync(entry, "test")
		local mark = #harness.FramesFor(player)
		for correlation = 1, 65 do
			harness.Transport:InjectToServer(player, commandFrame(correlation, "Buy"))
		end
		local before = replyCorrelationsAfter(player, mark)
		harness.Step()
		local after = string.split(replyCorrelationsAfter(player, mark), ",")
		local inOrder = true
		for i = 2, 65 do
			inOrder = inOrder and after[i] == tostring(i - 1)
		end
		expect(`before=[{before}] count={#after} first={after[1]} heldInOrder={inOrder}`).toBe(
			"before=[65] count=65 first=65 heldInOrder=true"
		)
	end)
end)
