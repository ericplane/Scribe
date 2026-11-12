--!nonstrict
-- Handshake timeouts and durations are measured from profile readiness.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local Root = script.Parent.Parent.Parent.Parent
local Clock = require(Root.Scribe.Internal.Clock)
local Metrics = require(Root.Scribe.Internal.Metrics)
local Log = require(Root.Scribe.Internal.Log)
local Wire = require(Root.Scribe.Internal.Wire)
local TestCtx = require(Root.Test.Helpers.TestCtx)
local FakePlayer = require(Root.Test.Helpers.FakePlayer)

local TIMEOUT = "CLIENT_HANDSHAKE_TIMEOUT"
local UNDELIVERED = "INIT_UNDELIVERED"

local harness
local parked = {}

afterEach(function()
	for _, thread in parked do
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
	table.clear(parked)
	if harness then
		harness.Cleanup()
		harness = nil
	end
	Clock.Reset()
	Metrics.Reset()
	Log.SetRingLevel(nil)
end)

local function clock()
	local now = 1000
	local delayed = {}
	Clock.Install({
		Now = function()
			return 1000000 + now
		end,
		Monotonic = function()
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
	return {
		Advance = function(seconds)
			now += seconds
			while true do
				local due
				for index, item in delayed do
					if item.At <= now then
						due = index
						break
					end
				end
				if due == nil then
					break
				end
				local item = table.remove(delayed, due)
				local ok, err = coroutine.resume(item.Thread)
				assert(ok, err)
			end
		end,
	}
end

-- DevMode defaults to RunService:IsStudio().
local function make(devMode)
	harness = TestCtx.make({
		Template = { Coins = 0 },
		Options = { DevMode = devMode, LogRingLevel = "Debug" },
	})
	Metrics.Reset()
	return harness
end

local function park()
	local thread = coroutine.running()
	table.insert(parked, thread)
	coroutine.yield()
end

local function resume()
	local thread = table.remove(parked, 1)
	assert(thread ~= nil, "expected a parked load")
	task.spawn(thread)
end

local function reports(code, player)
	local out = {}
	for _, entry in Log.GetRecent({ Code = code }) do
		if entry.Context and entry.Context.Player == player then
			table.insert(out, entry)
		end
	end
	return out
end

local function levels(code, player)
	local out = {}
	for _, entry in reports(code, player) do
		table.insert(out, entry.Level)
	end
	return table.concat(out, ",")
end

it("waits on a live server, and warns only when no client has ever asked", function()
	local time = clock()
	local h = make(false)
	local player = h.Join(981001)
	time.Advance(10)
	expect(levels(TIMEOUT, player)).toBe("")
	time.Advance(49)
	expect(levels(TIMEOUT, player)).toBe("")
	time.Advance(1)
	expect(levels(TIMEOUT, player)).toBe("Warn")
	expect(reports(TIMEOUT, player)[1].Context.Waited).toBe(60)
	expect(Metrics.Get().HandshakeTimeouts).toBe(1)
	time.Advance(120)
	expect(levels(TIMEOUT, player)).toBe("Warn")
	expect(Metrics.Get().HandshakeTimeouts).toBe(1)
end)

it("reports a silent client at Debug once another client of the server has asked", function()
	local time = clock()
	local h = make(false)
	local quick = h.Join(981011)
	h.SendHello(quick)
	local slow = h.Join(981012)
	-- Run the ten-second check late.
	time.Advance(60)
	expect(levels(TIMEOUT, slow)).toBe("Debug")
	expect(reports(TIMEOUT, slow)[1].Context.Waited).toBe(60)
	expect(levels(TIMEOUT, quick)).toBe("")
	expect(levels(UNDELIVERED, quick)).toBe("")
	expect(Metrics.Get().HandshakeTimeouts).toBe(1)
end)

it("says nothing about a client that asks late, and records how long it took", function()
	local time = clock()
	local h = make(false)
	local player, entry = h.Join(981021)
	time.Advance(25)
	h.SendHello(player)
	expect(entry.HandshakeReady).toBe(true)
	time.Advance(60)
	expect(levels(TIMEOUT, player)).toBe("")
	expect(levels(UNDELIVERED, player)).toBe("")
	expect(Metrics.Get().HandshakeTimeouts).toBe(nil)
	local duration = Metrics.Get().HandshakeDuration
	expect(`{duration.Count}/{duration.Max}`).toBe("1/25")
end)

it("samples the wait once per session, not once per snapshot", function()
	local time = clock()
	local h = make(false)
	local player = h.Join(981031)
	time.Advance(3)
	h.SendHello(player)
	time.Advance(6)
	h.SendHello(player)
	local metrics = Metrics.Get()
	expect(metrics.Handshakes).toBe(2)
	expect(`{metrics.HandshakeDuration.Count}/{metrics.HandshakeDuration.Max}`).toBe("1/3")
end)

it("measures from Ready, so a client that asked during the load did not wait", function()
	local time = clock()
	local h = make(false)
	local start = h.Ctx.Persistence.Store.StartSessionAsync
	h.Ctx.Persistence.Store.StartSessionAsync = function(store, key, params)
		park()
		return start(store, key, params)
	end
	local player = FakePlayer.new(981041)
	h.Ctx.Persistence.OnPlayerAdded(player)
	time.Advance(7)
	h.SendHello(player)
	resume()
	expect((h.Data.GetState(player))).toBe("Ready")
	expect(h.Ctx.Persistence.EntryFor(player).HandshakeReady).toBe(true)
	local duration = Metrics.Get().HandshakeDuration
	expect(`{duration.Count}/{duration.Max}`).toBe("1/0")
	time.Advance(60)
	expect(levels(TIMEOUT, player)).toBe("")
	h.Leave(player)
end)

it("keeps the ten-second warning in DevMode", function()
	local time = clock()
	local h = make(true)
	local player = h.Join(981051)
	time.Advance(9)
	expect(levels(TIMEOUT, player)).toBe("")
	time.Advance(1)
	expect(levels(TIMEOUT, player)).toBe("Warn")
	expect(reports(TIMEOUT, player)[1].Context.Waited).toBe(10)
	time.Advance(60)
	expect(levels(TIMEOUT, player)).toBe("Warn")
	expect(Metrics.Get().HandshakeTimeouts).toBe(1)
end)

it("says nothing about a client that left before the deadline", function()
	local time = clock()
	local h = make(false)
	local player = h.Join(981061)
	time.Advance(30)
	h.Leave(player)
	time.Advance(60)
	expect(levels(TIMEOUT, player)).toBe("")
	expect(Metrics.Get().HandshakeTimeouts).toBe(nil)
end)

it("leaves a refused client to its mismatch warning", function()
	local time = clock()
	local h = make(false)
	local player = h.Join(981101)
	local w = Wire.NewWriter(8)
	Wire.U8(w, Wire.Frames.Hello)
	Wire.U32(w, (h.Compiled.Hash + 1) % 4294967296)
	Wire.U8(w, Wire.PROTOCOL_VERSION)
	h.Transport:InjectToServer(player, Wire.Finish(w))
	time.Advance(60)
	expect(levels("SCHEMA_MISMATCH", player)).toBe("Warn")
	expect(levels(TIMEOUT, player)).toBe("")
	expect(Metrics.Get().HandshakeTimeouts).toBe(nil)
end)

it("says nothing on behalf of a stopped bundle", function()
	local time = clock()
	local h = make(false)
	local player, entry = h.Join(981071)
	h.Data.Stop()
	expect(entry.TornDown).toBe(false)
	time.Advance(60)
	expect(levels(TIMEOUT, player)).toBe("")
	expect(Metrics.Get().HandshakeTimeouts).toBe(nil)
end)

it("still reports an undeliverable snapshot at ten seconds on a live server", function()
	local time = clock()
	local h = make(false)
	local player, entry = h.Join(981081)
	h.Transport.SendToClient = function()
		error("transport: refused", 0)
	end
	time.Advance(2)
	h.SendHello(player)
	expect(`{entry.HelloReceived}/{entry.HandshakeReady}`).toBe("true/false")
	time.Advance(8)
	expect(levels(UNDELIVERED, player)).toBe("Warn")
	expect(levels(TIMEOUT, player)).toBe("")
	time.Advance(60)
	expect(levels(UNDELIVERED, player)).toBe("Warn")
	expect(levels(TIMEOUT, player)).toBe("")
	expect(Metrics.Get().HandshakeTimeouts).toBe(nil)
	expect(Metrics.Get().HandshakeDuration).toBe(nil)
end)

it("reports an undeliverable snapshot for a client that asked after the first check", function()
	local time = clock()
	local h = make(false)
	local player = h.Join(981091)
	h.Transport.SendToClient = function()
		error("transport: refused", 0)
	end
	time.Advance(10)
	expect(levels(UNDELIVERED, player)).toBe("")
	time.Advance(20)
	h.SendHello(player)
	time.Advance(30)
	expect(levels(UNDELIVERED, player)).toBe("Warn")
	expect(levels(TIMEOUT, player)).toBe("")
	expect(Metrics.Get().HandshakeTimeouts).toBe(nil)
end)
