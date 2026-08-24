--!nonstrict
-- CHARACTERISATION: what the DERIVED_MISMATCH purity audit actually reports.
--
-- Under DevMode the server replicates a locally computable derived field so the client
-- can compare it against its own computation and report an impure compute function
-- (Node.luau, `Replicate = spec.Transmit or devMode`). The audit lives in Tree.ApplyOp
-- and compares the incoming op against `readValue` of the same path.
--
-- The compute function below is pure by construction: one arithmetic expression over
-- its single declared input, no os.time, no math.random, no upvalue.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Client = require(Root.Scribe.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	-- The reported case: Level = floor(Xp / 1000) + 1, capped at 100.
	local function levelForXp(xp: number): number
		return math.min(100, math.floor(xp / 1000) + 1)
	end

	local function makeHarness()
		return TestCtx.make({
			Template = {
				Xp = Scribe.Int(0, { Min = 0 }),
				Level = Scribe.Derived(Scribe.Int(1, { Min = 1, Max = 100 }), { "Xp" }, levelForXp),
			},
			-- The audit only runs when the server transmits a locally computable
			-- derived field, which is DevMode's doing.
			Options = { DevMode = true },
			AutoPump = true,
		})
	end

	--- Every DERIVED_MISMATCH raised while `body` runs.
	local function mismatchesDuring(body: () -> ()): { string }
		local seen = {}
		local unsubscribe = Scribe.AddLogSink(function(entry)
			if entry.Code == "DERIVED_MISMATCH" then
				table.insert(seen, tostring(entry.Message))
			end
		end)
		local ok, err = pcall(body)
		if unsubscribe then
			unsubscribe()
		end
		if not ok then
			error(err, 0)
		end
		return seen
	end

	describe("the derived purity audit, against a provably pure compute function", function()
		itRunning("says nothing when the derived value does not change", function()
			local harness = makeHarness()
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			local mismatches = mismatchesDuring(function()
				-- 0 -> 500 leaves Level at 1, so no derived op is produced at all.
				serverData.Xp.Set(500)
				harness.Ctx.Replication.FlushEntry(entry)
			end)

			expect(("level=%d mismatches=%d"):format(clientData.Level.Get(), #mismatches)).to.equal(
				"level=1 mismatches=0"
			)

			harness.Cleanup()
		end)

		itRunning("reports a mismatch on a pure function the moment the value DOES change", function()
			local harness = makeHarness()
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			local mismatches = mismatchesDuring(function()
				-- Crossing the 1000 boundary moves Level 1 -> 2, so the server sends it.
				serverData.Xp.Set(1000)
				harness.Ctx.Replication.FlushEntry(entry)
			end)

			-- Both realms end up agreeing, which is the point: nothing is impure.
			expect(("server=%d client=%d"):format(serverData.Level.Get(), clientData.Level.Get())).to.equal(
				"server=2 client=2"
			)

			-- What the audit reported about that agreement.
			expect(#mismatches).to.equal(0)

			harness.Cleanup()
		end)

		itRunning("reports the reverse mismatch when the value changes back", function()
			local harness = makeHarness()
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			serverData.Xp.Set(1000)
			harness.Ctx.Replication.FlushEntry(entry)

			local mismatches = mismatchesDuring(function()
				serverData.Xp.Set(999)
				harness.Ctx.Replication.FlushEntry(entry)
			end)

			expect(("server=%d client=%d"):format(serverData.Level.Get(), clientData.Level.Get())).to.equal(
				"server=1 client=1"
			)
			expect(#mismatches).to.equal(0)

			harness.Cleanup()
		end)
	end)

	describe("the same audit against a genuinely impure compute function", function()
		-- THE MUTATION. Without this the three specs above are satisfied by an audit
		-- that never fires at all, which would be a silent loss of the only check that
		-- catches an impure derived field. The counter makes the two realms disagree
		-- for the reason the audit exists to report: the result depends on something
		-- other than the declared inputs.
		itRunning("still reports it, so the fix did not simply silence the check", function()
			local calls = 0
			local harness = TestCtx.make({
				Template = {
					Xp = Scribe.Int(0, { Min = 0 }),
					Level = Scribe.Derived(Scribe.Int(1, { Min = 1, Max = 100 }), { "Xp" }, function(_xp: number)
						calls += 1
						return math.min(100, calls)
					end),
				},
				Options = { DevMode = true },
				AutoPump = true,
			})
			local player, entry, serverData = harness.Join()
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)

			local mismatches = mismatchesDuring(function()
				serverData.Xp.Set(1000)
				harness.Ctx.Replication.FlushEntry(entry)
			end)

			expect(#mismatches >= 1).to.equal(true)
			expect(string.find(mismatches[1] or "", "not pure", 1, true) ~= nil).to.equal(true)
			-- And the server's value is what the mirror keeps, as the log code documents.
			expect(type(clientData.Level.Get())).to.equal("number")

			harness.Cleanup()
		end)
	end)
end
