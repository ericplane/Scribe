--!nonstrict
-- The modelled disk's own contract, with ProfileStore deliberately NOT in the
-- loop.
--
-- Kept separate because the disk is the layer everything else inherits: the real
-- vendored library runs on top of it, so a divergence here is a divergence every
-- later result silently carries. Testing it through ProfileStore would mean a
-- failure in either could look like a failure in both, and the interesting
-- properties -- what the transform is handed, how many times, and whether the
-- value it returned is the value that got stored -- are far easier to state when
-- the transform is one this file wrote.

return function()
	local Root = script.Parent.Parent.Parent
	local Disk = require(Root.Test.Sim.Disk)
	local Scheduler = require(Root.Test.Sim.Scheduler)
	local Rng = require(Root.Test.Sim.Rng)

	local function newDisk(seed: number?, overrides)
		local sched = Scheduler.new(seed or 1)
		local config = {
			Sched = sched,
			Rng = Rng.Stream(seed or 1, "disk.latency"),
			VersionRng = Rng.Stream(seed or 1, "disk.versionid"),
			LatencyProfile = "Instant",
			-- Budgets off by default here: these specs are about storage semantics,
			-- and a throttle firing mid-scenario would make an unrelated failure look
			-- like a disk bug. The budget specs below opt back in.
			NoBudget = true,
			FaultRng = Rng.Stream(seed or 1, "disk.fault"),
		}
		for key, value in overrides or {} do
			config[key] = value
		end
		return Disk.new(config), sched
	end

	--- Run `fn` as a simulated request and return what it produced.
	local function request(sched, fn)
		local result = { n = 0 }
		local failure = nil
		sched:Spawn(function()
			local packed = table.pack(pcall(fn))
			if packed[1] then
				result = table.pack(table.unpack(packed, 2, packed.n))
			else
				failure = packed[2]
			end
		end)
		sched:Run()
		return result, failure
	end

	describe("UpdateAsync", function()
		it("writes, and returns the value with a non-nil KeyInfo", function()
			-- ProfileStore discards an otherwise-good result unless BOTH values
			-- come back, so the second one is load-bearing rather than decorative.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			local result = request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 10 }
				end)
			end)

			expect(result[1]).never.to.equal(nil)
			expect(result[1].Coins).to.equal(10)
			expect(result[2]).never.to.equal(nil)
			expect(type(result[2].Version)).to.equal("string")
		end)

		it("aborts the write when the transform returns nil", function()
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			local result = request(sched, function()
				return store:UpdateAsync("k", function()
					return nil
				end)
			end)

			expect(result[1]).to.equal(nil)
			expect(disk.Keyspace:Version("S", "k")).to.equal(0)
		end)

		it("re-invokes the transform against fresh data after a conflict", function()
			-- The core of optimistic concurrency. A commit that lands during the
			-- write window must lose, re-read, and re-run -- not silently overwrite.
			local disk, sched = newDisk(4171, { LatencyProfile = "Fixed" })
			local store = disk:GetDataStore("S")

			request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 1 }
				end)
			end)

			local seenByTransform = {}
			local interloperDone = false

			sched:Spawn(function()
				store:UpdateAsync("k", function(current)
					table.insert(seenByTransform, current.Coins)
					-- On the first pass this races the write below; on the retry it
					-- must see that write's result.
					return { Coins = current.Coins + 100 }
				end)
			end)
			sched:Spawn(function()
				-- Lands inside the first update's read/write window.
				store:UpdateAsync("k", function(current)
					return { Coins = current.Coins + 5 }
				end)
				interloperDone = true
			end)
			sched:Run()

			expect(interloperDone).to.equal(true)
			expect(disk.Stats.Conflicts > 0).to.equal(true)
			expect(#seenByTransform > 1).to.equal(true)
			-- The retry saw the interloper's committed value, not the stale one.
			expect(seenByTransform[#seenByTransform]).to.equal(6)
			expect(disk.Keyspace:Read("S", "k").Value.Coins).to.equal(106)
		end)

		it("refuses a transform that yields (DC-STRICT)", function()
			-- Roblox forbids yielding in a transform. Detected with a coroutine
			-- rather than a flag: a flag only trips when the transform yields
			-- through the disk's own wait, and one yielding on anything else would
			-- slip past while holding ProfileStore's per-key queue across the yield.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			local _, failure = request(sched, function()
				return store:UpdateAsync("k", function()
					coroutine.yield()
					return { Coins = 1 }
				end)
			end)

			expect(failure).never.to.equal(nil)
			expect(string.find(tostring(failure), "yielded", 1, true) ~= nil).to.equal(true)
			expect(Disk.Errors.Classify(tostring(failure)).Class).to.equal("Sim")
		end)
	end)

	describe("deep-copy invariants", function()
		it("DC-IN: hands the transform a fresh copy, on every invocation", function()
			-- ProfileStore mutates what it is handed and returns the same table. If
			-- the transform were given the live stored table, a mutation would take
			-- effect before the commit -- and on a retry it would see its own
			-- previous partial work.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			request(sched, function()
				return store:UpdateAsync("k", function()
					return { Nested = { Coins = 1 } }
				end)
			end)

			local stored = disk.Keyspace:Read("S", "k").Value
			request(sched, function()
				return store:UpdateAsync("k", function(current)
					expect(current).never.to.equal(stored)
					expect(current.Nested).never.to.equal(stored.Nested)
					current.Nested.Coins = 999 -- scribbling on the input...
					return { Nested = { Coins = 2 } }
				end)
			end)

			-- ...must not have reached the stored value.
			expect(disk.Keyspace:Read("S", "k").Value.Nested.Coins).to.equal(2)
		end)

		it("DC-OUT: stores a copy, not the table the transform returned", function()
			-- ProfileStore assigns latest_data.Data = profile.Data by LIVE
			-- reference. Storing that reference would let later mutations of
			-- Profile.Data retroactively rewrite data that was already persisted --
			-- a write appearing atomic when it was not.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			local returned = { Nested = { Coins = 1 } }
			request(sched, function()
				return store:UpdateAsync("k", function()
					return returned
				end)
			end)

			returned.Nested.Coins = 12345 -- mutate AFTER the write committed

			expect(disk.Keyspace:Read("S", "k").Value.Nested.Coins).to.equal(1)
		end)

		it("DC-RET: returns a copy distinct from stored and from input", function()
			-- ProfileStore publishes the return as Profile.LastSavedData, and
			-- Scribe restores Data from it when a save is blocked. Handing back the
			-- stored table would alias saved state to live state, so a later edit
			-- would rewrite the record of what was last saved.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			local result = request(sched, function()
				return store:UpdateAsync("k", function()
					return { Nested = { Coins = 1 } }
				end)
			end)

			local stored = disk.Keyspace:Read("S", "k").Value
			expect(result[1]).never.to.equal(stored)
			expect(result[1].Nested).never.to.equal(stored.Nested)

			result[1].Nested.Coins = 999
			expect(stored.Nested.Coins).to.equal(1)
		end)
	end)

	describe("GetAsync", function()
		it("returns BOTH nil for a key that was never written", function()
			-- ProfileStore decides a profile is new by testing the KeyInfo, not the
			-- value. A helpfully non-nil keyInfo here would make every first load
			-- look like a returning player -- and skip migrations accordingly.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			local result = request(sched, function()
				return store:GetAsync("missing")
			end)

			expect(result[1]).to.equal(nil)
			expect(result[2]).to.equal(nil)
		end)

		it("returns a copy, so a reader cannot edit the disk", function()
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")
			request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 7 }
				end)
			end)

			local result = request(sched, function()
				return store:GetAsync("k")
			end)
			result[1].Coins = 999

			expect(disk.Keyspace:Read("S", "k").Value.Coins).to.equal(7)
		end)
	end)

	describe("limits", function()
		it("rejects an oversized value permanently, leaving the key untouched", function()
			local disk, sched = newDisk(1, { ValueBytes = 2048 })
			local store = disk:GetDataStore("S")

			request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 1 }
				end)
			end)

			local big = {}
			for i = 1, 500 do
				big[`field_{i}`] = string.rep("x", 32)
			end

			local _, failure = request(sched, function()
				return store:UpdateAsync("k", function()
					return big
				end)
			end)

			expect(failure).never.to.equal(nil)
			local descriptor = Disk.Errors.Classify(tostring(failure))
			expect(descriptor.Code).to.equal(105)
			expect(descriptor.Class).to.equal("Permanent")
			expect(descriptor.Retryable).to.equal(false)
			-- The rejected write left the previous value exactly as it was.
			expect(disk.Keyspace:Read("S", "k").Value.Coins).to.equal(1)
		end)

		it("rejects an empty or overlong key before spending any time", function()
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")
			local before = sched.Now

			local _, empty = request(sched, function()
				return store:GetAsync("")
			end)
			local _, long = request(sched, function()
				return store:GetAsync(string.rep("k", 51))
			end)

			expect(Disk.Errors.Classify(tostring(empty)).Code).to.equal(101)
			expect(Disk.Errors.Classify(tostring(long)).Code).to.equal(102)
			-- Validation is client-side and free: no latency was paid.
			expect(sched.Now).to.equal(before)

			-- Every entry point, not just the read one. Found by mutation: this
			-- spec originally checked GetAsync alone, so dropping the check from
			-- UpdateAsync -- the path that actually matters -- changed nothing.
			local _, badUpdate = request(sched, function()
				return store:UpdateAsync("", function()
					return { Coins = 1 }
				end)
			end)
			expect(Disk.Errors.Classify(tostring(badUpdate)).Code).to.equal(101)
			expect(sched.Now).to.equal(before)
		end)

		it("does not let a delayed write resurrect an erased key", function()
			-- The dangerous shape is a writer whose CAS token is ZERO -- the value a
			-- never-written key reports. A remove that reset the version line back to
			-- zero would hand that stale writer a matching token again, and its
			-- commit would silently bring the key back after the erase.
			--
			-- The timing is explicit, because the reset is only observable when the
			-- erase completes BEFORE the stale writer re-checks. Let the write land
			-- first and both behaviours conflict identically, which is how an earlier
			-- version of this spec passed against a reset line.
			local disk, sched = newDisk(3, { LatencyProfile = "Fixed" })
			local store = disk:GetDataStore("S")

			local attempts = 0
			sched:Spawn(function()
				-- Reads a key that has never been written: token 0. Checks at t=0.10.
				store:UpdateAsync("ghost", function(current)
					attempts += 1
					return { Coins = (current and current.Coins or 0) + 1, Attempt = attempts }
				end)
			end)
			sched:Spawn(function()
				sched:Wait(0.005)
				store:SetAsync("ghost", { Coins = 500 }) -- commits t=0.055
			end)
			sched:Spawn(function()
				sched:Wait(0.01)
				store:RemoveAsync("ghost") -- erases t=0.06, before the check
			end)
			sched:Run()

			-- Forced to re-run: the erase moved the line past the writer's token.
			-- Had the line reset to zero, the token would have matched and the first
			-- attempt would have committed unchallenged.
			expect(attempts).to.equal(2)
			expect(disk.Keyspace:Read("S", "ghost").Value.Attempt).to.equal(2)
		end)
		it("makes a concurrent erase beat a stale in-flight write", function()
			-- A remove keeps counting the version line rather than resetting it, so
			-- a writer holding a token from before the erase still loses its CAS.
			-- Reset to zero, that stale write would match and silently bring deleted
			-- data back -- and "the erase came back" is a bug worth being able to
			-- find, not one to make unrepresentable.
			local disk, sched = newDisk(9, { LatencyProfile = "Fixed" })
			local store = disk:GetDataStore("S")

			request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 50 }
				end)
			end)

			local attempts = 0
			sched:Spawn(function()
				store:UpdateAsync("k", function(current)
					attempts += 1
					return { Coins = (current and current.Coins or 0) + 1 }
				end)
			end)
			sched:Spawn(function()
				-- Staggered so the erase lands INSIDE the writer's write window,
				-- deliberately rather than by luck. Fired at the same instant, the
				-- two orderings are a coin flip on the seed, and only one of them is
				-- the scenario under test -- a spec that depends on winning that flip
				-- tests the seed, not the disk.
				sched:Wait(0.02)
				store:RemoveAsync("k")
			end)
			sched:Run()

			-- The writer was forced to re-run rather than committing against a
			-- version the erase had already moved past.
			expect(attempts > 1).to.equal(true)
			expect(disk.Stats.Conflicts > 0).to.equal(true)
		end)

		it("measures size two ways that disagree", function()
			-- Not a curiosity. Scribe guesses "this save failed because the profile
			-- is too big" by comparing its OWN cheap approximation against a warn
			-- threshold, because the DataStore error tells it nothing. A model
			-- where both measures agreed would never exercise that guess.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 1, Name = "player", Items = { 1, 2, 3 } }
				end)
			end)

			local divergence = disk.Stats.SizeDivergence
			expect(divergence).never.to.equal(nil)
			expect(divergence.Serialized > 0).to.equal(true)
			expect(divergence.Approx > 0).to.equal(true)
			expect(divergence.Serialized).never.to.equal(divergence.Approx)
		end)
	end)

	describe("versions", function()
		it("keeps one recoverable backup per UTC hour, not per write", function()
			-- What makes "not every write is recoverable" true. Successive writes
			-- inside one hour overwrite the same backup permanently, which is the
			-- premise Scribe's version-restore path is written against.
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")

			for i = 1, 4 do
				request(sched, function()
					return store:UpdateAsync("k", function()
						return { Coins = i }
					end)
				end)
			end

			expect(#disk.Keyspace:Versions("S", "k")).to.equal(1)
			expect(disk.Keyspace:Versions("S", "k")[1].Value.Coins).to.equal(4)
		end)

		it("rejects a version id it never minted, in words ProfileStore matches", function()
			local disk, sched = newDisk()
			local store = disk:GetDataStore("S")
			request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 1 }
				end)
			end)

			local _, failure = request(sched, function()
				return store:GetVersionAsync("k", "not-a-real-version")
			end)

			expect(failure).never.to.equal(nil)
			expect(string.find(tostring(failure), "not valid", 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe("budget", function()
		local Budget = require(Root.Test.Sim.Disk.Budget)

		it("accrues experience writes at HALF the per-server per-player rate", function()
			-- The most important property in the budget model. Per server, writes
			-- accrue at 60 + n*40 per minute; across the experience, at 300 + CCU*20.
			-- The more players there are, the more certainly the experience pool runs
			-- dry first, and a model with only per-server budgets would report
			-- headroom that does not exist.
			--
			-- Asserted on the SLOPES rather than on one comparison. Found by
			-- mutation: an inequality between two chosen points still held with the
			-- experience multiplier doubled to match the per-server one, so the very
			-- property the spec is named for went untested.
			local experienceSlope = Budget.EXPERIENCE_LIMITS.Write(2000) - Budget.EXPERIENCE_LIMITS.Write(1000)
			local serverSlope = Budget.SERVER_LIMITS.StandardWrite(2000) - Budget.SERVER_LIMITS.StandardWrite(1000)
			expect(experienceSlope * 2).to.equal(serverSlope)
		end)

		it("charges the experience tier even when the server tier is flush", function()
			-- Behavioural proof that the second tier exists. Player count is set high
			-- so the per-server pool is enormous (60 + 100*40 = 4060/min) while CCU
			-- is zero so the experience pool is the documented floor of 300 -- the
			-- only thing that can throttle here is the tier the previous spec only
			-- checked arithmetically.
			local disk, sched = newDisk(1, {
				NoBudget = false,
				PlayerCount = function()
					return 100
				end,
				CCU = function()
					return 0
				end,
			})
			local store = disk:GetDataStore("S")

			for i = 1, 320 do
				sched:Spawn(function()
					store:UpdateAsync(`k{i}`, function()
						return { Coins = i }
					end)
				end)
			end
			sched:Run()

			-- Well under the per-server ceiling, so any stall at all came from the
			-- experience pool.
			expect(disk.Budget.Stats.Stalls > 0).to.equal(true)
			expect(disk.Budget.Stats.Dropped).to.equal(0)
		end)

		it("refunds the server tier when the experience tier refuses", function()
			-- Spending both tiers has to be all-or-nothing. A request that cannot pay
			-- the experience pool must not quietly consume a server token on its way
			-- out: it will be queued and retried, and charging on every failed
			-- attempt would drain the server pool at the rate of RETRIES rather than
			-- of admissions -- inventing a per-server shortage that does not exist.
			local sched = Scheduler.new(1)
			local budget = Budget.new({
				Sched = sched,
				-- Server pool enormous, experience pool at its floor of 300.
				PlayerCount = function()
					return 100
				end,
				CCU = function()
					return 0
				end,
			})

			-- Drain the experience Write pool.
			for _ = 1, 300 do
				expect(budget:TryTake("job", "StandardWrite")).to.equal(true)
			end

			local serverTokens = budget._servers.job.Tokens.StandardWrite
			-- This one must fail on the experience tier...
			expect(budget:TryTake("job", "StandardWrite")).to.equal(false)
			-- ...without having spent a server token.
			expect(budget._servers.job.Tokens.StandardWrite).to.equal(serverTokens)
		end)

		it("queues rather than failing when the budget is spent", function()
			-- Exhaustion is LATENCY, not an error. Collapsing the two would overstate
			-- failure rates and understate tails, which are the two numbers a
			-- capacity study exists to produce.
			local disk, sched = newDisk(1, { NoBudget = false })
			local store = disk:GetDataStore("S")

			-- Above the 60/min pool so requests genuinely have to wait, but the
			-- overflow stays under the 30-deep queue so none are dropped. Forty fit
			-- outright and proved nothing.
			local completed, failed = 0, 0
			for i = 1, 80 do
				sched:Spawn(function()
					local ok = pcall(function()
						store:UpdateAsync(`k{i}`, function()
							return { Coins = i }
						end)
					end)
					if ok then
						completed += 1
					else
						failed += 1
					end
				end)
			end
			sched:Run()

			expect(failed).to.equal(0)
			expect(completed).to.equal(80)
			expect(disk.Budget.Stats.Stalls > 0).to.equal(true)
		end)

		it("drops with a throttle code only when the QUEUE overflows", function()
			local disk, sched = newDisk(2, { NoBudget = false })
			local store = disk:GetDataStore("S")

			local dropped = {}
			for i = 1, 200 do
				sched:Spawn(function()
					local ok, err = pcall(function()
						store:UpdateAsync(`k{i}`, function()
							return { Coins = i }
						end)
					end)
					if not ok then
						table.insert(dropped, tostring(err))
					end
				end)
			end
			sched:Run()

			expect(#dropped > 0).to.equal(true)
			local descriptor = Disk.Errors.Classify(dropped[1])
			-- 303 specifically: the drop code is chosen by operation.
			expect(descriptor.Code).to.equal(303)
			expect(descriptor.Class).to.equal("Transient")
			expect(descriptor.Retryable).to.equal(true)
			expect(disk.Budget.Stats.Dropped > 0).to.equal(true)
		end)
	end)

	describe("faults", function()
		it("commits an Indeterminate write and THEN fails", function()
			-- The outcome no Roblox mock models, and the reason this layer exists.
			-- ProfileStore treats every error as "did not happen" and retries an
			-- ending-session save, so a committed-then-failed write is a
			-- double-apply path rather than a lost one.
			local disk, sched = newDisk(1)
			local store = disk:GetDataStore("S")
			disk:Arm({ Kind = "Indeterminate", Op = "UpdateAsync", Count = 1 })

			local _, failure = request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 42 }
				end)
			end)

			expect(failure).never.to.equal(nil)
			-- The caller saw a failure...
			expect(Disk.Errors.Classify(tostring(failure)).Class).to.equal("Indeterminate")
			-- ...and the write is on disk anyway.
			expect(disk.Keyspace:Read("S", "k").Value.Coins).to.equal(42)
			expect(disk.Faults.Stats.IndeterminateCommits).to.equal(1)
		end)

		it("fails a ServiceError without writing anything", function()
			local disk, sched = newDisk(1)
			local store = disk:GetDataStore("S")
			disk:Arm({ Kind = "ServiceError", Op = "UpdateAsync", Count = 1 })

			local _, failure = request(sched, function()
				return store:UpdateAsync("k", function()
					return { Coins = 42 }
				end)
			end)

			expect(Disk.Errors.Classify(tostring(failure)).Class).to.equal("Transient")
			expect(disk.Keyspace:Read("S", "k")).to.equal(nil)
		end)

		it("retires an armed fault after its count, and Heal clears the rest", function()
			local disk, sched = newDisk(1)
			local store = disk:GetDataStore("S")
			disk:Arm({ Kind = "ServiceError", Op = "UpdateAsync", Count = 2 })

			local outcomes = {}
			for i = 1, 4 do
				local _, failure = request(sched, function()
					return store:UpdateAsync(`k{i}`, function()
						return { Coins = i }
					end)
				end)
				table.insert(outcomes, failure == nil)
			end

			expect(outcomes[1]).to.equal(false)
			expect(outcomes[2]).to.equal(false)
			expect(outcomes[3]).to.equal(true) -- armed count exhausted
			expect(outcomes[4]).to.equal(true)

			disk:Arm({ Kind = "ServiceError", Op = "UpdateAsync", Count = 5 })
			disk:Heal()
			local _, afterHeal = request(sched, function()
				return store:UpdateAsync("healed", function()
					return { Coins = 1 }
				end)
			end)
			expect(afterHeal).to.equal(nil)
		end)

		it("draws nothing from the fault stream when no rate is set", function()
			-- A run with rates and a run without are different configurations. If an
			-- unconfigured run still drew, adding a rate later would shift every
			-- subsequent draw and silently change what a seed means.
			local disk = newDisk(1)
			expect(disk.Faults:AnyRateSet()).to.equal(false)
			for _ = 1, 50 do
				expect(disk.Faults:Next("UpdateAsync", "S", "k")).to.equal(nil)
			end

			-- Returning nil is not the property; leaving the STREAM UNTOUCHED is.
			-- After fifty fault-free decisions the next draw must still be the first
			-- draw of a fresh stream, or those decisions consumed randomness and
			-- adding a fault rate later would silently renumber every subsequent one.
			local fresh = Rng.Stream(1, "disk.fault")
			expect(disk.Faults._rng:NextNumber()).to.equal(fresh:NextNumber())

			disk:SetFaultRate({ ServiceError = 1 })
			expect(disk.Faults:AnyRateSet()).to.equal(true)
			expect(disk.Faults:Next("UpdateAsync", "S", "k")).to.equal("ServiceError")
		end)

		it("makes a Lost request visible as a deadlock, not a clean finish", function()
			-- A request that never returns leaves a thread parked forever. Without
			-- the kernel's liveness check the run would simply end and report
			-- success -- for a storage simulation the worst possible failure mode,
			-- since "the save never completed" IS the bug.
			local disk, sched = newDisk(1)
			local store = disk:GetDataStore("S")
			disk:Arm({ Kind = "Lost", Op = "UpdateAsync", Count = 1 })

			sched:Spawn(function()
				store:UpdateAsync("k", function()
					return { Coins = 1 }
				end)
			end)
			sched:Run()

			expect(sched:Settled()).to.equal(false)
			expect(sched.Deadlocked).to.equal(true)
			expect(disk.Faults.Stats.Lost).to.equal(1)
		end)
	end)

	describe("per-key throughput", function()
		it("delays a hot key rather than failing it", function()
			-- Replaces the folklore 6-second per-key write cooldown, which Roblox
			-- removed in 2023. The real backpressure is a rolling byte window, and it
			-- costs the writer time rather than an error.
			local disk, sched = newDisk(1)
			disk.Throughput.WriteLimit = 8 * 1024 -- tiny, so a test reaches it
			local store = disk:GetDataStore("S")

			local before = sched.Now
			for i = 1, 12 do
				request(sched, function()
					return store:UpdateAsync("hot", function()
						return { Coins = i }
					end)
				end)
			end

			expect(disk.Throughput.Stats.Throttles > 0).to.equal(true)
			-- Waited, did not fail: every write landed and the last one is current.
			expect(disk.Keyspace:Read("S", "hot").Value.Coins).to.equal(12)
			expect(sched.Now > before).to.equal(true)
		end)

		it("charges per KiB, so many small writes cost far more than their bytes", function()
			-- Roblox bills rounded up to the KiB, so a chatty autosave of a small
			-- profile is much more expensive than its size suggests -- which is
			-- exactly the shape of Scribe's traffic.
			local disk = newDisk(1)
			for _ = 1, 10 do
				disk.Throughput:Charge("S:k", "Write", 12) -- 12 bytes each
			end
			expect(disk.Throughput:Used("S:k", "Write")).to.equal(10 * 1024)
		end)
	end)
end
