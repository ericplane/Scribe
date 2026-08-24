--!nonstrict
-- `StatusThresholds` is a PROCESS GLOBAL, and it did not say so.
--
-- The health machine is a library-level singleton, so `Health.Configure` writes
-- into one shared `thresholds` table. Two Scribe bundles in one process --
-- documented and supported -- therefore share one health machine, and the second
-- bundle to build silently retunes the first one's. Nothing warns; the winner is
-- decided by construction order.
--
-- That is not cosmetic. The Outage gate is what refuses Robux grants and gift
-- prompts during a DataStore failure, and it is derived from `FailCount`. A second
-- bundle loosening the thresholds disables the first bundle's refusal at exactly
-- the moment it is supposed to fire.
--
-- Scribe already faced this hazard one file over and answered it: `AUTO_SAVE_PERIOD`
-- is a ProfileStore global, and `Persistence` warns `SAVE_INTERVAL_CONFLICT` rather
-- than resolving it as a silent last-writer-wins. The value still wins -- there is
-- one machine and it can only hold one setting -- but the operator finds out.
return function()
	local Root = script.Parent.Parent.Parent
	local Health = require(Root.Scribe.Internal.Health)
	local Log = require(Root.Scribe.Internal.Log)

	--- Capture every log line emitted while `body` runs. Sinks are Sched.Spawn'd,
	--- so the caller has to let a frame pass before reading.
	local function capturing(body)
		local seen = {}
		local detach = Log.AddSink(function(entry)
			table.insert(seen, entry)
		end)
		body()
		task.wait()
		detach()
		return seen
	end

	local function codesIn(entries, code)
		local hits = 0
		for _, entry in entries do
			if entry.Code == code then
				hits += 1
			end
		end
		return hits
	end

	describe("Health.Configure across bundles", function()
		it("says nothing when nobody configures thresholds", function()
			-- THE CONTROL for silence: building bundles that leave StatusThresholds
			-- alone must stay quiet, or every ordinary two-bundle process gets a
			-- warning it cannot act on.
			local entries = capturing(function()
				Health.Configure(nil)
				Health.Configure(nil)
			end)
			expect(codesIn(entries, "HEALTH_THRESHOLDS_CONFLICT")).to.equal(0)
			Health.ResetThresholds()
		end)

		it("says nothing when the SAME thresholds are set twice", function()
			-- The other control, and the one that keeps the warning meaningful: two
			-- bundles configured identically are not in conflict. A warning here would
			-- be noise on the most common multi-bundle setup there is.
			local entries = capturing(function()
				Health.Configure({ FailWindow = 30, FailCount = 5, RecoverStreak = 2 })
				Health.Configure({ FailWindow = 30, FailCount = 5, RecoverStreak = 2 })
			end)
			expect(codesIn(entries, "HEALTH_THRESHOLDS_CONFLICT")).to.equal(0)
			Health.ResetThresholds()
		end)

		it("WARNS when a second caller asks for different thresholds", function()
			-- The defect. Today this resolves silently and the later value wins.
			local entries = capturing(function()
				Health.Configure({ FailWindow = 30, FailCount = 5 })
				Health.Configure({ FailWindow = 30, FailCount = 9 })
			end)
			expect(codesIn(entries, "HEALTH_THRESHOLDS_CONFLICT")).to.equal(1)
			Health.ResetThresholds()
		end)

		it("still lets the later value win, and rebuilds the derived Outage count", function()
			-- Warning, not refusing. There is ONE machine and it can hold one setting,
			-- so changing who wins would be a behaviour change rather than a
			-- diagnostic. Asserted through the machine rather than by reading the
			-- table, because the derived OutageFailCount is the thing that actually
			-- gates money and it has to follow the winner.
			Health.ResetThresholds()
			Health.Configure({ FailWindow = 30, FailCount = 9, RecoverStreak = 4 })
			Health.Configure({ FailWindow = 45, FailCount = 2, RecoverStreak = 7 })

			local thresholds = Health.Thresholds()
			expect(thresholds.FailWindow).to.equal(45)
			expect(thresholds.FailCount).to.equal(2)
			expect(thresholds.RecoverStreak).to.equal(7)
			-- The derived member has to be rebuilt from the WINNER, not left holding
			-- the loser's value: this is the number that decides Outage, and Outage is
			-- what refuses Robux.
			expect(thresholds.OutageFailCount).to.equal(math.max(2 * 2, 2 + 1))

			Health.ResetThresholds()
			local defaults = Health.Thresholds()
			expect(defaults.FailWindow).to.equal(60)
			expect(defaults.FailCount).to.equal(3)
			expect(defaults.RecoverStreak).to.equal(5)
			expect(defaults.OutageFailCount).to.equal(math.max(3 * 2, 3 + 1))
		end)

		it("warns once per conflicting field, not once per Configure call", function()
			-- A repeated identical conflict is the same conflict. Re-warning on every
			-- call would turn a real signal into log spam in a process that rebuilds
			-- bundles (a test suite, a simulation), which is exactly the process most
			-- likely to hit it.
			-- Every step after the first is a REAL conflict -- the value alternates, so
			-- each call genuinely disagrees with the one before it. Repeating the same
			-- value instead would prove nothing: those calls are not conflicts at all,
			-- and an implementation that warned on every conflict would still print
			-- once.
			local entries = capturing(function()
				Health.Configure({ FailCount = 5 })
				Health.Configure({ FailCount = 9 })
				Health.Configure({ FailCount = 5 })
				Health.Configure({ FailCount = 9 })
			end)
			expect(codesIn(entries, "HEALTH_THRESHOLDS_CONFLICT")).to.equal(1)
			Health.ResetThresholds()
		end)

		it("forgets the conflict record on Reset", function()
			-- Reset returns the singleton to its defaults for the next test/simulation,
			-- so it has to clear what has been configured too -- otherwise the first
			-- Configure after a Reset is compared against a bundle that no longer
			-- exists.
			Health.ResetThresholds()
			local entries = capturing(function()
				Health.Configure({ FailCount = 5 })
				Health.ResetThresholds()
				Health.Configure({ FailCount = 9 })
			end)
			expect(codesIn(entries, "HEALTH_THRESHOLDS_CONFLICT")).to.equal(0)
			Health.ResetThresholds()
		end)
	end)
end
