--!nonstrict
-- V1 and V2: the verdict key, against the modelled DataStore.
--
-- This is the only part of the exchange with a genuine point of no return, so it is the
-- only part where a wrong answer is unrecoverable. Everything after it is either
-- infallible (a settle, which writes only under the reserved root) or infinitely
-- retryable (a delivery, which parks). Everything before it is free to abandon.
--
-- The two properties that matter:
--
--   V1 THE TRANSFORM NEVER RETURNS NIL. Returning nil when the key is occupied reads
--      like the obvious way to say "someone else decided", and it is wrong: a nil
--      return ABORTS the write and hands the caller (nil, nil), which is
--      indistinguishable from a failure. The loser must read the winner's verdict
--      out of the RETURN VALUE.
--   V2 AN INDETERMINATE WRITE IS NOT A SPECIAL CASE. A write can land and then fail.
--      Nobody has settled at that point, because settling requires reading a verdict
--      back, so the next proposal either reads the committed answer or lands its own.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Universe = require(Root.Test.Sim.Universe)
	local Guard = require(Root.Test.Sim.Guard)
	-- Sim-backed: needs a modelled DataStore with injectable faults.
	local it = if require(Root.Test.Sim.Available).Ready then it else itSKIP
	local StubTransport = require(Root.Test.Helpers.StubTransport)
	local ExchangeVerdict = require(Root.Scribe.Internal.ExchangeVerdict)

	local TID = "tid_verdict_1"
	local A_ID, B_ID = 97001, 97002

	local PRODUCTION = {
		AUTO_SAVE_PERIOD = 300,
		SESSION_STEAL = 40,
		FIRST_LOAD_REPEAT = 5,
		LOAD_REPEAT_PERIOD = 10,
		ASSUME_DEAD = 630,
		START_SESSION_TIMEOUT = 120,
	}

	local universe

	afterEach(function()
		Guard.Reset()
		universe = nil
	end)

	local function setup()
		universe = Universe.new({
			Seed = 20260826,
			Servers = 1,
			Constants = PRODUCTION,
			Transport = StubTransport.new({ AutoPump = false }),
			LatencyProfile = "Nominal",
			NoBudget = true,
			StatusThresholds = { FailWindow = 60, FailCount = 1000, RecoverStreak = 1 },
			Template = { Coins = Scribe.Int(0, { Min = 0, Max = 1000 }) },
			Options = {},
		})
		Guard.Install(universe)
		local uni = universe
		return uni, uni.Disk:GetDataStore(ExchangeVerdict.STORE_NAME)
	end

	--- Run a yielding call on a scheduler thread and hand back its results.
	local function call(uni, fn)
		local packed
		uni.Sched:Spawn(function()
			packed = table.pack(pcall(fn))
		end)
		uni:Run(120)
		if packed == nil then
			return "NEVER RETURNED"
		end
		if not packed[1] then
			return `RAISED {tostring(packed[2])}`
		end
		return table.unpack(packed, 2, packed.n)
	end

	local function proposal(kind: string, digest: string?)
		return { V = kind, A = A_ID, B = B_ID, D = digest or "digest-1" }
	end

	describe("V1: the transform never returns nil", function()
		it("commits the first proposal and reports it", function()
			local uni, store = setup()
			local verdict, decided, err = call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Commit"))
			end)
			expect(`v={tostring(verdict and verdict.V)} decided={tostring(decided)} err={tostring(err)}`).to.equal(
				"v=Commit decided=true err=nil"
			)
		end)

		it("hands the LOSER the winner's verdict, not nil and not its own proposal", function()
			-- The property V1 exists for. A loser that got nil could not tell "someone
			-- else decided" from "the call failed", and a loser that got its OWN
			-- proposal back would settle the two profiles in opposite directions.
			local uni, store = setup()
			call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Commit"))
			end)

			local verdict, decided, err = call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Abort"))
			end)
			expect(`v={tostring(verdict and verdict.V)} decided={tostring(decided)} err={tostring(err)}`).to.equal(
				"v=Commit decided=false err=nil"
			)
		end)

		it("is stable under repeated proposals from both sides", function()
			-- Both participants propose, on every retry, forever. The answer must not
			-- move, or two profiles settle against different verdicts.
			local uni, store = setup()
			local answers = {}
			for index = 1, 6 do
				local kind = if index % 2 == 0 then "Abort" else "Commit"
				local verdict = call(uni, function()
					return ExchangeVerdict.Propose(store, TID, proposal(kind))
				end)
				table.insert(answers, tostring(verdict and verdict.V))
			end
			expect(table.concat(answers, ",")).to.equal("Commit,Commit,Commit,Commit,Commit,Commit")
		end)

		it("reads back the same verdict it committed", function()
			local uni, store = setup()
			call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Abort"))
			end)
			local verdict, err = call(uni, function()
				return ExchangeVerdict.Read(store, TID)
			end)
			expect(`v={tostring(verdict and verdict.V)} err={tostring(err)}`).to.equal("v=Abort err=nil")
		end)

		it("reads nil for an exchange nobody has decided, which is not an error", function()
			local uni, store = setup()
			local verdict, err = call(uni, function()
				return ExchangeVerdict.Read(store, "tid_never_proposed")
			end)
			expect(`v={tostring(verdict)} err={tostring(err)}`).to.equal("v=nil err=nil")
		end)
	end)

	describe("V2: an indeterminate write is not a special case", function()
		it("may lose the ANSWER while the write lands, and the next proposal finds it", function()
			-- The sim commits, then raises: the caller cannot tell whether it happened.
			-- Nobody has settled, because settling requires reading a verdict back, so
			-- the next proposal reads the committed answer and both sides agree.
			local uni, store = setup()
			uni.Disk.Faults:Arm({
				Kind = "Indeterminate",
				Op = "UpdateAsync",
				Store = ExchangeVerdict.STORE_NAME,
				Key = TID,
				Count = 1,
			})

			local verdict, _decided, err = call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Commit"))
			end)
			local lostTheAnswer = verdict == nil and err ~= nil

			local second = call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Abort"))
			end)
			expect(`lost={tostring(lostTheAnswer)} then={tostring(second and second.V)}`).to.equal(
				"lost=true then=Commit"
			)
		end)

		it("or may lose the write entirely, in which case the next proposal decides", function()
			-- The other branch of the same fault. Either way exactly one verdict ends
			-- up in force and both participants read it.
			local uni, store = setup()
			uni.Disk.Faults:Arm({
				Kind = "ServiceError",
				Op = "UpdateAsync",
				Store = ExchangeVerdict.STORE_NAME,
				Key = TID,
				Count = 1,
			})

			local verdict, _decided, err = call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Commit"))
			end)
			local refused = verdict == nil and err ~= nil

			local second = call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Abort"))
			end)
			local final = call(uni, function()
				return ExchangeVerdict.Read(store, TID)
			end)
			expect(
				`refused={tostring(refused)} then={tostring(second and second.V)} stored={tostring(final and final.V)}`
			).to.equal("refused=true then=Abort stored=Abort")
		end)

		it("does not let a later proposal overwrite a decided exchange", function()
			-- The mutation this case exists for. If a second proposal could overwrite,
			-- a participant that already settled against Commit would find the key
			-- saying Abort, and the two profiles would be settled in opposite directions
			-- with nothing to reconcile them.
			local uni, store = setup()
			call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Commit"))
			end)
			for _ = 1, 3 do
				call(uni, function()
					return ExchangeVerdict.Propose(store, TID, proposal("Abort"))
				end)
			end
			local final = call(uni, function()
				return ExchangeVerdict.Read(store, TID)
			end)
			expect(tostring(final and final.V)).to.equal("Commit")
		end)

		it("REFUSES to match a verdict against the wrong basket or the wrong pair", function()
			-- Corruption checks, not expected branches. Settling against the wrong
			-- basket would move value nobody agreed to move.
			local uni, store = setup()
			local verdict = call(uni, function()
				return ExchangeVerdict.Propose(store, TID, proposal("Commit"))
			end)

			local okSame = select(1, ExchangeVerdict.Matches(verdict, "digest-1", A_ID, B_ID))
			local okDigest, whyDigest = ExchangeVerdict.Matches(verdict, "digest-2", A_ID, B_ID)
			local okPair, whyPair = ExchangeVerdict.Matches(verdict, "digest-1", A_ID, 99999)

			expect(
				`same={tostring(okSame)} digest={tostring(okDigest)}/{tostring(whyDigest)} pair={tostring(okPair)}/{tostring(
					whyPair
				)}`
			).to.equal("same=true digest=false/digest mismatch pair=false/participant mismatch")
		end)

		it("REFUSES a malformed record rather than settling against it", function()
			local uni, store = setup()
			call(uni, function()
				return store:SetAsync(TID, { NotAVerdict = true })
			end)
			local verdict, err = call(uni, function()
				return ExchangeVerdict.Read(store, TID)
			end)
			expect(`v={tostring(verdict)} err={tostring(err)}`).to.equal(
				"v=nil err=verdict key holds a malformed record"
			)
		end)
	end)
end
