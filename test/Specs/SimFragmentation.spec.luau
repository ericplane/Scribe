--!nonstrict
-- Fragmentation on virtual time: the two properties that only a simulation can
-- express, because both are about SECONDS passing while a snapshot is in flight.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: every node below needs a simulated universe, which only the headless
	-- runner can build. Under Studio they report SKIP instead of each failing with the
	-- same missing capability -- see test/Sim/Available for why it cannot be provided.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local Wire = require(Root.Scribe.Internal.Wire)
	local FakePlayer = require(Root.Test.Helpers.FakePlayer)

	local CONSTANTS = {
		AUTO_SAVE_PERIOD = 30,
		SESSION_STEAL = 10,
		FIRST_LOAD_REPEAT = 2,
		LOAD_REPEAT_PERIOD = 3,
		ASSUME_DEAD = 60,
		START_SESSION_TIMEOUT = 60,
	}

	local universe

	local function newUniverse(overrides)
		local config = {
			Seed = 909090,
			Servers = 1,
			Constants = CONSTANTS,
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0 }), Bag = {} },
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		universe = Universe.new(config)
		Guard.Install(universe)
		return universe
	end

	afterEach(function()
		if universe then
			universe:Quiesce()
			universe = nil
		end
		Guard.Reset()
	end)

	local function fill(data, n)
		for i = 1, n do
			data.Bag[`entry_{i}_paddingpadding`].Set(i)
		end
	end

	-- Counted off the RAW log, not Link:AddressedTo -- that one reassembles, which
	-- is right for every assertion about ops and wrong for one about framing.
	local function frameStats(server, player)
		local frags = 0
		for _, frame in server.Link.SentToClientLog do
			if
				(frame.Player == nil or frame.Player == player)
				and buffer.readu8(frame.Bytes, 0) == Wire.Frames.Fragment
			then
				frags += 1
			end
		end
		return frags, server.Link.RefusedOversize
	end

	it("loads a profile the link refuses to carry whole", function()
		-- Without fragmentation this is the shipped cliff: one oversize Init, one
		-- refusal, a client that never loads and re-Hellos forever.
		local uni = newUniverse({ MaxFrameBytes = 4096, Options = { MaxOutboundBytes = 4096 } })
		local server = uni:Server(1)
		local player = FakePlayer.new(90001)
		server:Join(90001, player)
		uni:Run(30)
		local data = server.Bundle.Data.Get(player)
		fill(data, 900)
		data.Coins.Set(4242)

		local client = server:AttachClient(player)
		expect(server:SettleClients()).to.equal(true)

		local frags, refused = frameStats(server, player)
		expect(`ready={client.IsReady()} coins={client.Coins.Get()} refused={refused}`).to.equal(
			"ready=true coins=4242 refused=0"
		)
		expect(frags > 5).to.equal(true)
		expect(#server.Bundle.FrameErrors).to.equal(0)
	end)

	it("does not restart a snapshot that is still arriving", function()
		-- A link that drains one frame per pump: the fragmented Init takes tens of
		-- virtual seconds, spanning many rounds of the client's Hello backoff. If the
		-- client asks again while fragments are still landing, the server throws the
		-- snapshot away and encodes the whole profile afresh -- and a snapshot slower
		-- to drain than the retry delay then restarts forever and never completes.
		local uni = newUniverse({
			MaxFrameBytes = 4096,
			MaxFramesPerPump = 1,
			Options = { MaxOutboundBytes = 4096 },
		})
		local server = uni:Server(1)
		local player = FakePlayer.new(90002)
		server:Join(90002, player)
		uni:Run(30)
		local data = server.Bundle.Data.Get(player)
		fill(data, 6000)
		data.Coins.Set(77)

		local client = server:AttachClient(player)
		local readyAt = nil
		for second = 1, 600 do
			uni:Run(1)
			if client.IsReady() then
				readyAt = second
				break
			end
		end

		local inits = 0
		for _, frame in server.Link.SentToClientLog do
			local b = frame.Bytes
			if buffer.readu8(b, 0) == Wire.Frames.Fragment and buffer.readu16(b, 7) == 0 then
				inits += 1
			end
		end
		-- The bound is the point. Each restart is a fresh snapshot of the whole
		-- profile, so a client that keeps asking mid-flight shows up as many
		-- fragment-zero frames rather than as a failure to load.
		-- Measured both ways: with the guard, 1 snapshot and 58 frames to this client.
		-- Without it, 8 Hellos, 7 snapshots and 394 frames -- the same profile pushed
		-- almost seven times over because each Hello threw away the one in flight.
		expect(`ready={client.IsReady()} coins={client.Coins.Get()}`).to.equal("ready=true coins=77")
		expect(`restarts<=2 -> {inits <= 2} (saw {inits})`).to.equal(`restarts<=2 -> true (saw {inits})`)
		expect(readyAt).never.to.equal(nil)
		expect(#server.Bundle.FrameErrors).to.equal(0)
	end)
end
