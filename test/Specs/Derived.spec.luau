--!nonstrict
-- Scribe.Derived: compile-time resolution and refusals, recompute timing and
-- coalescing, transactions, replication (who computes vs who receives), offline
-- reads, and edit mode.
return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local Template = require(ScribeRoot.Internal.Template)
	local Wire = require(ScribeRoot.Internal.Wire)
	local Log = require(ScribeRoot.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local RANKS = { "Recruit", "Officer", "Sergeant", "Paramedic" }

	local function rankFor(team: string, policeXp: number, emsXp: number): string
		if team == "Police" then
			return if policeXp >= 100 then "Sergeant" else "Officer"
		elseif team == "EMS" then
			return if emsXp >= 100 then "Paramedic" else "Officer"
		end
		return "Recruit"
	end

	-- The worked example from the design note: two XP pools, a team that selects
	-- between them, a ServerOnly input, and a derived field reading a derived field.
	local function makeTemplate()
		return {
			Team = Scribe.Shared(Scribe.Enum("Civilian", { "Civilian", "Police", "EMS" })),
			Stats = {
				PoliceXP = Scribe.Int(0, { Min = 0 }),
				EMSXP = Scribe.Int(0, { Min = 0 }),
			},
			Suspicion = Scribe.ServerOnly(Scribe.Int(0, { Min = 0, Max = 100 })),

			-- Replicated over Replicated/Shared inputs: computed on both realms.
			Rank = Scribe.Derived(Scribe.Enum("Recruit", RANKS), { "Team", "Stats.PoliceXP", "Stats.EMSXP" }, rankFor),
			-- Derived from a derived.
			RankIcon = Scribe.Derived(Scribe.String("", { MaxLength = 8 }), { "Rank" }, function(rank: string): string
				return `icon:{string.sub(rank, 1, 3)}`
			end),
			-- Shared over a Shared input: every client computes it.
			Title = Scribe.Shared(Scribe.Derived(Scribe.String("", { MaxLength = 24 }), { "Team" }, function(team)
				return `The {team}`
			end)),
			-- Replicated over a ServerOnly input: the server must send this one.
			Watchlisted = Scribe.Derived(false, { "Suspicion" }, function(suspicion: number): boolean
				return suspicion >= 80
			end),
			-- Never leaves the server.
			Threat = Scribe.ServerOnly(Scribe.Derived(Scribe.Int(0), { "Suspicion", "Stats.PoliceXP" }, function(s, xp)
				return s + xp
			end)),
		}
	end

	local function makeHarness(extra)
		local config = { Template = makeTemplate() }
		for key, value in extra or {} do
			config[key] = value
		end
		-- Pin production mode. DevMode defaults to RunService:IsStudio()
		-- (src/Server/init.luau), and a derived field is deliberately REPLICATED
		-- under DevMode so the client can compare it against its own computation and
		-- report an impure function (Node.luau, `Replicate = spec.Transmit or
		-- devMode`). These specs assert the production rule -- that a locally
		-- computable derived field sends nothing -- so without this they pass
		-- headless (where IsStudio is false) and fail under real TestEZ in Studio.
		-- Set here rather than per-test so every assertion about what crosses the
		-- wire means the same thing in both runners. A caller may still override it.
		local options = config.Options or {}
		if options.DevMode == nil then
			options.DevMode = false
		end
		config.Options = options
		return TestCtx.make(config)
	end

	local function compileFails(template: any): (boolean, string)
		local ok, err = pcall(Template.Compile, template, {})
		return ok, tostring(err)
	end

	local function nodeFor(compiled: any, name: string): any
		return compiled.Root.Children[name]
	end

	describe("compile", function()
		it("resolves nested input paths and records the graph", function()
			local compiled = Template.Compile(makeTemplate(), {})
			local rank = nodeFor(compiled, "Rank")
			expect(rank.Derived).never.to.equal(nil)
			expect(#rank.Derived.Inputs).to.equal(3)
			expect(table.concat(rank.Derived.InputPaths[2], ".")).to.equal("Stats.PoliceXP")
			-- A derived field never persists, wherever it sits.
			expect(rank.Persist).to.equal(false)
			-- Topological: RankIcon reads Rank, so it settles after it.
			local rankIndex, iconIndex
			for i, node in compiled.DerivedNodes do
				if node.Name == "Rank" then
					rankIndex = i
				elseif node.Name == "RankIcon" then
					iconIndex = i
				end
			end
			expect(rankIndex < iconIndex).to.equal(true)
		end)

		it("seeds each default by running the compute function against the inputs' defaults", function()
			local compiled = Template.Compile(makeTemplate(), {})
			expect(nodeFor(compiled, "Rank").Default).to.equal("Recruit")
			expect(nodeFor(compiled, "RankIcon").Default).to.equal("icon:Rec")
			expect(nodeFor(compiled, "Title").Default).to.equal("The Civilian")
			expect(nodeFor(compiled, "Watchlisted").Default).to.equal(false)
		end)

		it("decides who computes from the visibility of the inputs", function()
			local compiled = Template.Compile(makeTemplate(), {})
			-- Replicated output, Replicated + Shared inputs: the owner can see them all.
			expect(nodeFor(compiled, "Rank").Derived.Transmit).to.equal(false)
			expect(nodeFor(compiled, "RankIcon").Derived.Transmit).to.equal(false)
			-- Shared output over a Shared input: so can everyone else.
			expect(nodeFor(compiled, "Title").Derived.Transmit).to.equal(false)
			-- ServerOnly input, replicated output: only the server can compute it.
			expect(nodeFor(compiled, "Watchlisted").Derived.Transmit).to.equal(true)
			-- ServerOnly output is never sent at all.
			expect(nodeFor(compiled, "Threat").Derived.Transmit).to.equal(false)
		end)

		it("widening the audience past the inputs starts transmitting", function()
			-- Same field as Rank, but Shared: other clients see Team and not PoliceXP.
			local compiled = Template.Compile({
				Team = Scribe.Shared(Scribe.Enum("Civilian", { "Civilian", "Police" })),
				PoliceXP = Scribe.Int(0, { Min = 0 }),
				Rank = Scribe.Shared(Scribe.Derived(Scribe.String(""), { "Team", "PoliceXP" }, function(t, xp)
					return `{t}:{xp}`
				end)),
			}, {})
			expect(nodeFor(compiled, "Rank").Derived.Transmit).to.equal(true)
		end)

		it("folds the derived signature into the schema hash", function()
			local base = Template.Compile({
				A = Scribe.Int(0),
				B = Scribe.Int(0),
				D = Scribe.Derived(Scribe.Int(0), { "A" }, function(a)
					return a
				end),
			}, {})
			-- Same shape, different dependency: a locally computing client would read
			-- a different field, so this must not hash the same.
			local moved = Template.Compile({
				A = Scribe.Int(0),
				B = Scribe.Int(0),
				D = Scribe.Derived(Scribe.Int(0), { "B" }, function(b)
					return b
				end),
			}, {})
			expect(base.Hash).never.to.equal(moved.Hash)
		end)

		it("refuses an input that is not a declared field", function()
			local ok, err = compileFails({
				Coins = Scribe.Int(0),
				D = Scribe.Derived(Scribe.Int(0), { "Nope" }, function()
					return 0
				end),
			})
			expect(ok).to.equal(false)
			expect(string.find(err, "does not resolve to a declared field", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses an input inside a container, whose entries have no static path", function()
			local ok, err = compileFails({
				Bag = Scribe.ArrayOf(Scribe.Int(0)),
				D = Scribe.Derived(Scribe.Int(0), { "Bag.1" }, function()
					return 0
				end),
			})
			expect(ok).to.equal(false)
			expect(string.find(err, "does not resolve to a declared field", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses an input whose read shape is mutable or time-dependent", function()
			local okRecord, recordErr = compileFails({
				Stats = { Kills = 0 },
				D = Scribe.Derived(Scribe.Int(0), { "Stats" }, function()
					return 0
				end),
			})
			expect(okRecord).to.equal(false)
			expect(string.find(recordErr, "is a record", 1, true) ~= nil).to.equal(true)

			local okFlags, flagsErr = compileFails({
				Perks = Scribe.Flags({ "A", "B" }),
				D = Scribe.Derived(Scribe.Int(0), { "Perks" }, function()
					return 0
				end),
			})
			expect(okFlags).to.equal(false)
			expect(string.find(flagsErr, "Scribe.Flags", 1, true) ~= nil).to.equal(true)

			local okTimed, timedErr = compileFails({
				Booster = Scribe.Timed(false),
				D = Scribe.Derived(Scribe.Int(0), { "Booster" }, function()
					return 0
				end),
			})
			expect(okTimed).to.equal(false)
			expect(string.find(timedErr, "wall clock", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses a library-owned input", function()
			local ok, err = compileFails({
				D = Scribe.Derived(Scribe.Int(0), { "_Scribe.Perks" }, function()
					return 0
				end),
			})
			expect(ok).to.equal(false)
			expect(string.find(err, "library-owned root", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses a derived field under a persisted root", function()
			local ok, err = compileFails({
				Coins = Scribe.Int(0),
				Stats = {
					Rank = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						return c
					end),
				},
			})
			expect(ok).to.equal(false)
			expect(string.find(err, "must be a root field or live inside a Scribe.Session root", 1, true) ~= nil).to.equal(
				true
			)
		end)

		it("allows a derived field inside a Session root", function()
			local compiled = Template.Compile({
				Coins = Scribe.Int(0, { Min = 0 }),
				Runtime = Scribe.Session({
					Doubled = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						return c * 2
					end),
				}),
			}, {})
			expect(#compiled.DerivedNodes).to.equal(1)
			expect(compiled.DerivedNodes[1].Persist).to.equal(false)
		end)

		it("refuses redundant or contradictory wrappers", function()
			local okSession, sessionErr = compileFails({
				Coins = Scribe.Int(0),
				D = Scribe.Session(Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
					return c
				end)),
			})
			expect(okSession).to.equal(false)
			expect(string.find(sessionErr, "redundant", 1, true) ~= nil).to.equal(true)

			local okTimed, timedErr = compileFails({
				Coins = Scribe.Int(0),
				D = Scribe.Timed(Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
					return c
				end)),
			})
			expect(okTimed).to.equal(false)
			expect(string.find(timedErr, "no expiry", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses a derived field inside an element shape", function()
			local ok, err = compileFails({
				Coins = Scribe.Int(0),
				Squad = Scribe.ArrayOf({
					Name = Scribe.String(""),
					Rank = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						return c
					end),
				}),
			})
			expect(ok).to.equal(false)
			expect(string.find(err, "element shape", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses a container output and a self-reference", function()
			local okContainer, containerErr = compileFails({
				Coins = Scribe.Int(0),
				D = Scribe.Derived(Scribe.ArrayOf(Scribe.Int(0)), { "Coins" }, function()
					return {}
				end),
			})
			expect(okContainer).to.equal(false)
			expect(string.find(containerErr, "one scalar value", 1, true) ~= nil).to.equal(true)

			local okSelf, selfErr = compileFails({
				D = Scribe.Derived(Scribe.Int(0), { "D" }, function(d)
					return d
				end),
			})
			expect(okSelf).to.equal(false)
			expect(string.find(selfErr, "reads itself", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses a cycle between derived fields", function()
			local ok, err = compileFails({
				A = Scribe.Derived(Scribe.Int(0), { "B" }, function(b)
					return b
				end),
				B = Scribe.Derived(Scribe.Int(0), { "A" }, function(a)
					return a
				end),
			})
			expect(ok).to.equal(false)
			expect(string.find(err, "cycle", 1, true) ~= nil).to.equal(true)
		end)

		it("refuses a compute function that throws or returns the wrong type", function()
			local okThrow, throwErr = compileFails({
				Coins = Scribe.Int(0),
				D = Scribe.Derived(Scribe.Int(0), { "Coins" }, function()
					error("boom")
				end),
			})
			expect(okThrow).to.equal(false)
			expect(string.find(throwErr, "threw while evaluating its default", 1, true) ~= nil).to.equal(true)

			local okType, typeErr = compileFails({
				Coins = Scribe.Int(0),
				D = Scribe.Derived(Scribe.String(""), { "Coins" }, function(c)
					return c -- a number, for a string field
				end),
			})
			expect(okType).to.equal(false)
			expect(string.find(typeErr, "returned a number", 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe("recompute", function()
		it("recomputes on a write, through the whole chain", function()
			local harness = makeHarness()
			local _player, _entry, data = harness.Join()

			expect(data.Rank.Get()).to.equal("Recruit")
			data.Team.Set("Police")
			expect(data.Rank.Get()).to.equal("Officer")
			expect(data.RankIcon.Get()).to.equal("icon:Off")

			data.Stats.PoliceXP.Set(150)
			expect(data.Rank.Get()).to.equal("Sergeant")
			expect(data.RankIcon.Get()).to.equal("icon:Ser")

			-- The other team's pool does not move a Police rank.
			data.Stats.EMSXP.Set(500)
			expect(data.Rank.Get()).to.equal("Sergeant")

			harness.Cleanup()
		end)

		it("cannot be written", function()
			local harness = makeHarness()
			local _player, _entry, data = harness.Join()

			local ok, err = pcall(function()
				data.Rank.Set("Sergeant")
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "is a derived field and cannot be written", 1, true) ~= nil).to.equal(
				true
			)
			-- The message names the inputs, so the fix is obvious from the error.
			expect(string.find(tostring(err), "Stats.PoliceXP", 1, true) ~= nil).to.equal(true)

			expect(pcall(function()
				data.Watchlisted.Toggle()
			end)).to.equal(false)
			expect(pcall(function()
				data.Threat.Increment(1)
			end)).to.equal(false)

			harness.Cleanup()
		end)

		it("fires once per batch, not once per input write", function()
			local harness = makeHarness()
			local _player, _entry, data = harness.Join()

			local fires = 0
			data.Rank.Changed(function()
				fires += 1
			end)

			harness.Data.Batch(_player, function()
				data.Team.Set("Police")
				data.Stats.PoliceXP.Set(10)
				data.Stats.PoliceXP.Set(50)
				data.Stats.PoliceXP.Set(150)
			end)

			expect(fires).to.equal(1)
			expect(data.Rank.Get()).to.equal("Sergeant")

			harness.Cleanup()
		end)

		it("is never stale inside a batch", function()
			local harness = makeHarness()
			local player, _entry, data = harness.Join()

			local seen
			harness.Data.Batch(player, function()
				data.Team.Set("Police")
				data.Stats.PoliceXP.Set(150)
				seen = data.Rank.Get() -- mid-batch read settles first
			end)
			expect(seen).to.equal("Sergeant")

			harness.Cleanup()
		end)

		it("emits nothing when the recomputed value is unchanged", function()
			local harness = makeHarness()
			local player, entry, data = harness.Join()
			harness.SendHello(player)
			table.clear(harness.Transport.SentToClientLog)

			-- Both values map to the same rank, so the second write recomputes to the
			-- value already stored: no Changed, and nothing queued for the wire.
			data.Team.Set("Police")
			data.Stats.PoliceXP.Set(150)
			harness.Ctx.Replication.FlushEntry(entry)
			table.clear(harness.Transport.SentToClientLog)

			local fires = 0
			data.Rank.Changed(function()
				fires += 1
			end)
			data.Stats.PoliceXP.Set(200) -- still "Sergeant"
			harness.Ctx.Replication.FlushEntry(entry)

			expect(fires).to.equal(0)
			for _, frame in harness.FramesFor(player, Wire.Frames.Diff) do
				for _, op in frame.Ops do
					expect(op.Path[1]).never.to.equal("Rank")
				end
			end

			harness.Cleanup()
		end)

		it("recomputes when a Clear wipes a static record holding an input", function()
			-- Clear is the one mutation that reaches a declared input without going
			-- through applySet: it accepts a static record and table.clears it, taking
			-- the declared children with it. The compute function has to tolerate the
			-- nil that leaves behind, which is the honest shape of a cleared record.
			local harness = TestCtx.make({
				Template = {
					Stats = { PoliceXP = Scribe.Int(0, { Min = 0 }) },
					Label = Scribe.Derived(
						Scribe.String("", { MaxLength = 16 }),
						{ "Stats.PoliceXP" },
						function(xp: number?): string
							return `xp:{tostring(xp)}`
						end
					),
				},
			})
			local _player, _entry, data = harness.Join()

			data.Stats.PoliceXP.Set(150)
			expect(data.Label.Get()).to.equal("xp:150")

			data.Stats.Clear()
			expect(data.Label.Get()).to.equal("xp:nil")

			harness.Cleanup()
		end)

		it("keeps the previous value when the compute function throws, without failing the write", function()
			local blowUp = false
			local harness = TestCtx.make({
				Template = {
					Coins = Scribe.Int(0, { Min = 0 }),
					Label = Scribe.Derived(Scribe.String(""), { "Coins" }, function(coins: number): string
						if blowUp then
							error("nope")
						end
						return `c{coins}`
					end),
				},
			})
			local _player, _entry, data = harness.Join()

			data.Coins.Set(1)
			expect(data.Label.Get()).to.equal("c1")

			blowUp = true
			local ok = pcall(function()
				data.Coins.Set(2)
			end)
			expect(ok).to.equal(true) -- the input write still succeeds
			expect(data.Coins.Get()).to.equal(2)
			expect(data.Label.Get()).to.equal("c1") -- last good value
			expect(#Log.GetRecent({ Code = "DERIVED_ERROR" }) > 0).to.equal(true)

			harness.Cleanup()
		end)
	end)

	describe("transactions", function()
		it("commits the recompute with the writes that caused it", function()
			local harness = makeHarness()
			local player, _entry, data = harness.Join()

			local ok = harness.Data.Transaction(player, function()
				data.Team.Set("Police")
				data.Stats.PoliceXP.Set(150)
			end)
			expect(ok).to.equal(true)
			expect(data.Rank.Get()).to.equal("Sergeant")

			harness.Cleanup()
		end)

		it("leaves the derived value consistent with rolled-back inputs", function()
			local harness = makeHarness()
			local player, _entry, data = harness.Join()

			data.Team.Set("Police")
			expect(data.Rank.Get()).to.equal("Officer")

			local ok = harness.Data.Transaction(player, function()
				data.Stats.PoliceXP.Set(150)
				error("abort")
			end)
			expect(ok).to.equal(false)
			expect(data.Stats.PoliceXP.Get()).to.equal(0)
			-- Not "Sergeant": the recompute rolled back with its input.
			expect(data.Rank.Get()).to.equal("Officer")

			harness.Cleanup()
		end)
	end)

	describe("replication", function()
		itRunning("computes locally on the client and sends nothing", function()
			local harness = makeHarness({ AutoPump = true })
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			-- The Init snapshot carried Team and Stats, not Rank.
			expect(clientData.Rank.Get()).to.equal("Recruit")

			table.clear(harness.Transport.SentToClientLog)
			serverData.Team.Set("Police")
			serverData.Stats.PoliceXP.Set(150)
			harness.Ctx.Replication.FlushEntry(entry)

			-- Both realms agree...
			expect(serverData.Rank.Get()).to.equal("Sergeant")
			expect(clientData.Rank.Get()).to.equal("Sergeant")
			expect(clientData.RankIcon.Get()).to.equal("icon:Ser")
			-- ...and no op for either derived field crossed the wire.
			for _, frame in harness.FramesFor(player) do
				for _, op in frame.Ops or {} do
					expect(op.Path[1]).never.to.equal("Rank")
					expect(op.Path[1]).never.to.equal("RankIcon")
				end
			end

			harness.Cleanup()
		end)

		itRunning("sends a derived field the client cannot compute", function()
			local harness = makeHarness({ AutoPump = true })
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			expect(clientData.Watchlisted.Get()).to.equal(false)
			serverData.Suspicion.Set(90)
			harness.Ctx.Replication.FlushEntry(entry)

			-- The input is ServerOnly, so only the value itself crosses.
			expect(clientData.Watchlisted.Get()).to.equal(true)
			local sawSuspicion = false
			for _, frame in harness.FramesFor(player) do
				for _, op in frame.Ops or {} do
					if op.Path[1] == "Suspicion" then
						sawSuspicion = true
					end
					-- ServerOnly derived stays home.
					expect(op.Path[1]).never.to.equal("Threat")
				end
			end
			expect(sawSuspicion).to.equal(false)

			harness.Cleanup()
		end)

		itRunning("reaches another player's Shared mirror", function()
			local harness = makeHarness({ AutoPump = true })
			local watcher = harness.Join(1)
			local _subject, subjectEntry, subjectData = harness.Join(2)
			harness.Transport.LocalPlayer = watcher
			local clientData = Client.new(harness.Options, harness.Compiled)

			subjectData.Team.Set("EMS")
			harness.Ctx.Replication.FlushEntry(subjectEntry)

			local shared = clientData.GetShared(2)
			expect(shared).never.to.equal(nil)
			expect(shared.Team).to.equal("EMS")
			-- Computed by the watching client from the Shared input it received.
			expect(shared.Title).to.equal("The EMS")

			harness.Cleanup()
		end)
	end)

	describe("leaderboards", function()
		it("ranks a derived stat", function()
			-- A board reads its Stat through the accessor tree, which is the only view
			-- that sees a derived field: LiveData is the persisted store alone.
			local harness = TestCtx.make({
				Template = {
					Wins = Scribe.Int(0, { Min = 0 }),
					Losses = Scribe.Int(0, { Min = 0 }),
					Score = Scribe.Derived(Scribe.Int(0), { "Wins", "Losses" }, function(w: number, l: number): number
						return w * 3 - l
					end),
				},
				Options = { Leaderboards = { TopScore = { Stat = "Score", Limit = 10 } } },
			})
			local player, _entry, data = harness.Join()

			data.Wins.Set(10)
			data.Losses.Set(4)
			expect(data.Score.Get()).to.equal(26)

			-- The leave flush reads the same way, so the board sees the computed value
			-- rather than the nil a raw profile read would give.
			harness.Leave(player)
			harness.Ctx.Leaderboards.FlushAllBlocking(1)
			harness.Ctx.Leaderboards.RefreshNow()
			local board = harness.Data.GetLeaderboard("TopScore")
			expect(#board >= 1).to.equal(true)
			expect(board[1].Score).to.equal(26)

			harness.Cleanup()
		end)
	end)

	describe("offline", function()
		it("derives over stored data for an online and an offline profile", function()
			local harness = makeHarness()
			local player, _entry, data = harness.Join()
			data.Team.Set("Police")
			data.Stats.PoliceXP.Set(150)

			-- Online: GetOffline clones LiveData, which is the persisted store only.
			local online = harness.Data.GetOffline(player.UserId)
			expect(online.Stats.PoliceXP).to.equal(150)
			expect(online.Rank).to.equal("Sergeant")
			expect(online.RankIcon).to.equal("icon:Ser")

			-- Offline: the same fill over a raw store read.
			harness.Leave(player)
			local offline = harness.Data.GetOffline(player.UserId)
			expect(offline).never.to.equal(nil)
			expect(offline.Rank).to.equal("Sergeant")

			harness.Cleanup()
		end)

		it("omits a field whose input is not stored", function()
			local harness = TestCtx.make({
				Template = {
					Coins = Scribe.Int(0, { Min = 0 }),
					Mood = Scribe.Session(Scribe.String("calm", { MaxLength = 8 })),
					FromStored = Scribe.Derived(Scribe.Int(0), { "Coins" }, function(c)
						return c * 2
					end),
					FromSession = Scribe.Derived(Scribe.String(""), { "Mood" }, function(m)
						return `mood:{m}`
					end),
				},
			})
			local player, _entry, data = harness.Join()
			data.Coins.Set(21)

			local snapshot = harness.Data.GetOffline(player.UserId)
			expect(snapshot.FromStored).to.equal(42)
			-- Mood is Session: it does not exist in a stored profile, so filling this
			-- in would mean deriving from data that is not there.
			expect(snapshot.FromSession).to.equal(nil)

			harness.Cleanup()
		end)
	end)

	describe("edit mode", function()
		it("recomputes from Data.Mock seeds and refuses a Mock of the field itself", function()
			local options = {
				Template = makeTemplate(),
				ProfileStoreIndex = "DerivedSpec",
				ProfileKeyPrefix = "PLAYER_",
				IsRunning = false,
				Banner = false,
			}
			local compiled = Template.Compile(options.Template, {})
			local clientData = Client.new(options, compiled)

			expect(clientData.Rank.Get()).to.equal("Recruit")
			clientData.Mock({ Team = "Police", Stats = { PoliceXP = 150, EMSXP = 0 } })
			expect(clientData.Rank.Get()).to.equal("Sergeant")
			expect(clientData.RankIcon.Get()).to.equal("icon:Ser")

			-- Seeding the computed field itself is a write, and writes are refused.
			expect(pcall(function()
				clientData.Mock({ Rank = "Paramedic" })
			end)).to.equal(false)
		end)
	end)
	itRunning("settles a mark laid down BEHIND the sweep cursor, which takes a second pass", function()
		-- Why MAX_SETTLE_PASSES is 4 and not 1, pinned.
		--
		-- runSettle sweeps `Compiled.DerivedNodes` in topological order rather than
		-- sweeping the dirty set, and its comment says that is what makes a CHAIN of
		-- any depth settle in one pass -- a dependent always sits after its inputs, so
		-- a mark laid down by a recompute is still ahead of the cursor. True, and it
		-- is exactly why a chain cannot pin the loop: one pass is enough for one.
		--
		-- The case that needs a second pass is a mark laid down BEHIND the cursor, and
		-- a LISTENER is what lays one. `Late` reads `Early`, so the compiler orders
		-- Early first; a listener on Late writes `B`, which is an input of Early. By
		-- then the cursor is past Early, so the mark survives to the next pass.
		--
		-- It converges rather than feeding back forever: the listener writes the same
		-- constant every time, so the second recompute of Late short-circuits at
		-- leafEquals and lays no third mark. With MAX_SETTLE_PASSES = 1, Early keeps
		-- the value it computed while B was still 0 and DERIVED_FEEDBACK fires on a
		-- program that was going to settle.
		local harness = TestCtx.make({
			AutoPump = false,
			Template = {
				A = Scribe.Int(0, { Min = 0 }),
				B = Scribe.Int(0, { Min = 0 }),
				Early = Scribe.Derived(Scribe.Int(0), { "A", "B" }, function(a: number, b: number): number
					return a * 10 + b
				end),
				Late = Scribe.Derived(Scribe.Int(0), { "Early" }, function(early: number): number
					return early + 1000
				end),
			},
		})
		local _player, _entry, data = harness.Join()
		data.Late.Changed(function()
			data.B.Set(1)
		end)

		data.A.Set(5)
		-- Early = 5*10 + 1 requires the SECOND pass to have run; at one pass it is 50.
		expect(`Early={data.Early.Get()} Late={data.Late.Get()}`).to.equal("Early=51 Late=1051")
		harness.Cleanup()
	end)
end
