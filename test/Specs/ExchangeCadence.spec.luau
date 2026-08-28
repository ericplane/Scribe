--!nonstrict
-- R2: the sweep must not abort an exchange that is still happening.
--
-- The sweep exists for sessions that never end. A load resolves what it finds, but a
-- player who stays on for six hours after their counterparty vanished would otherwise
-- wait six hours, so something has to look periodically.
--
-- The failure this guards against is the liveness machinery eating its own healthy
-- exchanges. A live attempt writes its records and then YIELDS through two forced flushes.
-- A sweep that resolved them mid-attempt would propose Abort against an exchange about to
-- commit, and the effective attempt bound would silently become the sweep interval
-- rather than the attempt's own deadline.
--
-- TWO INDEPENDENT PROTECTIONS, AND BOTH ARE NEEDED:
--
--   the in-flight set  knows about attempts THIS server is running. Exact, and blind to
--                      every other server.
--   the age floor      is the only thing that can protect an attempt running on ANOTHER
--                      server, which this one can only see as a record on a key.
--
-- Neither covers the other's case, which is why removing either one has a spec below.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Exchange = require(Root.Scribe.Internal.Exchange)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local Log = require(Root.Scribe.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_cadence"
	local A_ID, B_ID = 95501, 95502

	local TEMPLATE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
	}

	local function harnessed(fn)
		local harness = TestCtx.make({ Template = TEMPLATE })
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	local function ctxFor(harness, player, entry)
		return { Tree = entry.Tree, Entry = entry, Compiled = harness.Compiled, UserId = player.UserId }
	end

	local function verdictStore()
		local keys = {}
		return {
			UpdateAsync = function(_self, key, transform)
				local value = transform(keys[key])
				if value == nil then
					return nil, nil
				end
				keys[key] = value
				return value, nil
			end,
			GetAsync = function(_self, key)
				return keys[key], nil
			end,
		}
	end

	local function pair(harness)
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		harness.Data.Get(pa).Inventory["a_item"].Set({ Qty = 1 })
		harness.Data.Get(pb).Inventory["b_item"].Set({ Qty = 1 })
		return {
			A = {
				Ctx = ctxFor(harness, pa, ea),
				UserId = A_ID,
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "a_item" } },
			},
			B = {
				Ctx = ctxFor(harness, pb, eb),
				UserId = B_ID,
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "b_item" } },
			},
			PA = pa,
			PB = pb,
			EA = ea,
			EB = eb,
		}
	end

	it("does NOT abort a live attempt on this server, because the in-flight set covers it", function()
		-- The sweep runs at the worst possible moment: inside the attempt's own flush
		-- yield, with both records already written. The exchange must still commit.
		harnessed(function(harness)
			local p = pair(harness)
			local swept, sweptDuring = 0, 0

			local outcome = Exchange.Attempt({
				ExchangeId = TID,
				VerdictStore = verdictStore(),
				InFlight = harness.Ctx.Exchanges.InFlight,
				Flush = function()
					swept += 1
					sweptDuring += harness.Ctx.Exchanges.Sweep()
					return true
				end,
			}, p.A, p.B)

			expect(
				`{tostring(outcome)} sweeps={swept > 0} resolvedBySweep={sweptDuring} aGot={tostring(
					harness.Data.Get(p.PA).Inventory["b_item"].Get() ~= nil
				)}`
			).to.equal("Committed sweeps=true resolvedBySweep=0 aGot=true")
		end)
	end)

	it("does NOT touch a young record it did not start, which is the cross-server case", function()
		-- Another server is mid-attempt. This one sees only a record on a key, with no
		-- in-flight entry to consult, so the age floor is the only thing standing
		-- between the sweep and somebody else's live exchange.
		harnessed(function(harness)
			local p = pair(harness)
			ExchangeLeg.Claim(p.A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
			ExchangeLeg.Escrow(p.A.Ctx, TID, p.A.Legs)

			-- Deliberately NOT registered in the in-flight set: this server did not start it.
			expect(`inFlight={tostring(harness.Ctx.Exchanges.InFlight[A_ID])}`).to.equal("inFlight=nil")

			local resolved = harness.Ctx.Exchanges.Sweep()
			local record = p.A.Ctx.Tree.Reserved.Exchange[TID].Get()
			expect(`resolved={resolved} recordKept={tostring(record ~= nil)} phase={tostring(record and record.Phase)}`).to.equal(
				"resolved=0 recordKept=true phase=Staked"
			)
		end)
	end)

	it("DOES resolve a record old enough to be abandoned, or the sweep is decoration", function()
		-- The control. Without it, every case above passes on a sweep that never
		-- resolves anything at all.
		harnessed(function(harness)
			local p = pair(harness)
			ExchangeLeg.Claim(p.A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
			ExchangeLeg.Escrow(p.A.Ctx, TID, p.A.Legs)

			-- Age it past the floor, the way a real abandoned record ages.
			p.A.Ctx.Tree.Reserved.Exchange[TID].StakedAt.Set(0)

			local resolved = harness.Ctx.Exchanges.Sweep()
			expect(
				`resolved={resolved} record={tostring(p.A.Ctx.Tree.Reserved.Exchange[TID].Get())} itemBack={tostring(
					harness.Data.Get(p.PA).Inventory["a_item"].Get() ~= nil
				)}`
			).to.equal("resolved=1 record=nil itemBack=true")
		end)
	end)

	it("does NOT count an exchange it failed to resolve, and says so", function()
		-- ROUND 4. The sweep called ResolveOne through a bare pcall and counted every
		-- call that did not RAISE. ResolveOne does not raise when it cannot resolve: it
		-- returns nil with a reason, which is the ordinary shape of a stranded exchange,
		-- so an exchange whose verdict key cannot be reached was swept every thirty seconds
		-- for ever, reported as resolved every time, and produced not one log line.
		--
		-- That is precisely the state the operator verbs exist for, and the only thing
		-- that could ever tell anyone to reach for them is a log. The load path already
		-- distinguished all three outcomes; the sweep is the copy that drifted.
		harnessed(function(harness)
			local p = pair(harness)
			ExchangeLeg.Claim(p.A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
			ExchangeLeg.Escrow(p.A.Ctx, TID, p.A.Legs)
			p.A.Ctx.Tree.Reserved.Exchange[TID].StakedAt.Set(0)

			-- A store that cannot decide: UpdateAsync answers nothing, so no verdict is
			-- ever established and the record must stay exactly where it is.
			harness.Ctx.Exchanges.VerdictStore = function()
				return {
					UpdateAsync = function()
						return nil, "the key is unreachable"
					end,
					GetAsync = function()
						return nil, "the key is unreachable"
					end,
				}
			end

			local before = #Log.GetRecent({ Code = "EXCHANGE_UNRESOLVED" })
			local resolved = harness.Ctx.Exchanges.Sweep()
			local logged = #Log.GetRecent({ Code = "EXCHANGE_UNRESOLVED" }) - before

			expect(
				`resolved={resolved} logged={logged > 0} record={tostring(
					p.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil
				)}`
			).to.equal("resolved=0 logged=true record=true")
		end)
	end)

	it("announces a parked delivery ONCE, not on every tick for ever", function()
		-- EXCHANGE_PARKED was declared and documented and emitted nowhere, so a player owed
		-- an item their inventory will not accept was owed it in silence, and the one
		-- verb that fixes that is the one nothing told anybody to reach for.
		--
		-- Once is the whole design. The sweep revisits a parked entry every thirty
		-- seconds and the load revisits it on every join, and an alarm repeating twice a
		-- minute about a condition sitting durably on a key is what buries the next one.
		harnessed(function(harness)
			local p = pair(harness)
			-- The destination is occupied and stays that way, which is the park this
			-- exists for.
			harness.Data.Get(p.PA).Inventory["prize"].Set({ Qty = 1 })
			p.A.Ctx.Tree.Reserved.ExchangeInbox[TID].Set({
				Id = TID,
				Verdict = "Commit",
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "prize", Value = { Qty = 5 } } },
			})

			local before = #Log.GetRecent({ Code = "EXCHANGE_PARKED" })
			harness.Ctx.Exchanges.Sweep()
			local afterFirst = #Log.GetRecent({ Code = "EXCHANGE_PARKED" }) - before
			harness.Ctx.Exchanges.Sweep()
			harness.Ctx.Exchanges.Sweep()
			local afterThree = #Log.GetRecent({ Code = "EXCHANGE_PARKED" }) - before

			expect(
				`first={afterFirst} afterThree={afterThree} stillParked={tostring(
					p.A.Ctx.Tree.Reserved.ExchangeInbox[TID].Get() ~= nil
				)}`
			).to.equal("first=1 afterThree=1 stillParked=true")
		end)
	end)

	it("finishes the sweep when a profile JOINS while it is running", function()
		-- ROUND 4. The loop iterated ctx.Persistence.Entries directly across a yielding
		-- store call. Removing a key during a traversal is legal in Luau and a departure
		-- is therefore harmless, which is worth stating because it is the case that
		-- first suggests itself and it does not reproduce. ADDING one is not legal: a
		-- player who joins mid-sweep makes the next step raise "invalid key to next",
		-- and because the cadence thread runs the sweep under a pcall the whole cycle is
		-- abandoned in silence, skipping every profile after the join.
		--
		-- Provoked from inside the store call, which is where the real sweep yields.
		harnessed(function(harness)
			local p = pair(harness)
			-- The two records must name each OTHER. Given Partner = 1 on both, the second
			-- side fails Matches and never resolves, and the miscount this round fixed
			-- was reporting that as a resolution.
			ExchangeLeg.Claim(p.A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
			ExchangeLeg.Claim(p.B.Ctx, TID, { Digest = "d", Role = "B", Partner = A_ID })
			for _, side in { p.A, p.B } do
				ExchangeLeg.Escrow(side.Ctx, TID, side.Legs)
				side.Ctx.Tree.Reserved.Exchange[TID].StakedAt.Set(0)
			end

			local inner = verdictStore()
			local joined = false
			harness.Ctx.Exchanges.VerdictStore = function()
				return {
					UpdateAsync = function(selfRef, key, transform)
						if not joined then
							joined = true
							harness.Join(95503)
						end
						return inner.UpdateAsync(selfRef, key, transform)
					end,
					GetAsync = function(selfRef, key)
						return inner.GetAsync(selfRef, key)
					end,
				}
			end

			local ok, resolved = pcall(harness.Ctx.Exchanges.Sweep)
			expect(`ok={tostring(ok)} resolved={tostring(resolved)}`).to.equal("ok=true resolved=2")
		end)
	end)

	it("skips a profile that is not Ready, so a loading session is never swept", function()
		harnessed(function(harness)
			local p = pair(harness)
			ExchangeLeg.Claim(p.A.Ctx, TID, { Digest = "d", Role = "A", Partner = B_ID })
			ExchangeLeg.Escrow(p.A.Ctx, TID, p.A.Legs)
			p.A.Ctx.Tree.Reserved.Exchange[TID].StakedAt.Set(0)

			p.EA.State = "Loading"
			local resolved = harness.Ctx.Exchanges.Sweep()
			p.EA.State = "Ready"

			expect(`resolved={resolved} kept={tostring(p.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil)}`).to.equal(
				"resolved=0 kept=true"
			)
		end)
	end)
end
