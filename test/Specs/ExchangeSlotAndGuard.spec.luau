--!nonstrict
-- R1 and R3: the slot has no window, and the cross-tree guard stays green.
--
-- R1 exists because of a defect that duplicated an item. Two exchanges claimed the same
-- profile and the second wrote its record straight over the first with a plain
-- `container[key] = newValue`, so exchange one's escrow was replaced by exchange two's and
-- the value it was holding had nowhere to come back from. The fix is that both slots
-- are claimed back to back with NO YIELD between them, so there is no instant at which
-- a participant of an in-flight exchange advertises a free slot.
--
-- "No yield between them" is only worth anything if it is checked at the points where
-- the attempt DOES yield, which is the forced flushes. So the third player attempts
-- their exchange from inside the flush, which is the only moment they could get in.
--
-- R3 guards the guard. `OPEN_TXN_TREE` shipped because the naive shape of an exchange
-- MINTED currency: a transaction on one player wrapping a write to another committed
-- half a transfer. Nothing in this feature may reopen that, so the attempt is checked
-- for an open transaction at every yield, and the spec that pins the original defect is
-- checked for its assertions still being there.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Exchange = require(Root.Scribe.Internal.Exchange)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local TID = "tid_slot"
	local A_ID, B_ID, C_ID = 97301, 97302, 97303

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 10000 }),
				Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 4 }),
			},
		})
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

	--- Three loaded players, each holding one item.
	local function three(harness)
		local pa, ea = harness.Join(A_ID)
		local pb, eb = harness.Join(B_ID)
		local pc, ec = harness.Join(C_ID)
		harness.Data.Get(pa).Inventory["a_item"].Set({ Qty = 1 })
		harness.Data.Get(pb).Inventory["b_item"].Set({ Qty = 1 })
		harness.Data.Get(pc).Inventory["c_item"].Set({ Qty = 1 })
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
			C = {
				Ctx = ctxFor(harness, pc, ec),
				UserId = C_ID,
				Legs = { { Path = { "Inventory" }, Kind = "Key", Key = "c_item" } },
			},
			Harness = harness,
			PA = pa,
			PB = pb,
			PC = pc,
		}
	end

	describe("R1: no window between the claim and the stake", function()
		it("REFUSES a third player who tries to exchange with B from inside the flush", function()
			-- The flush is the ONLY yield in the attempt, so it is the only moment a
			-- third exchange could slip in. Both records already exist by then, and the
			-- second attempt's admission reads them.
			harnessed(function(harness)
				local p = three(harness)
				local intruder, intruderErr
				local attempts = 0

				local outcome = Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = verdictStore(),
					Flush = function()
						attempts += 1
						if attempts == 1 then
							-- C tries to take B's slot while A and B are mid-exchange.
							intruder, intruderErr = Exchange.Attempt({
								ExchangeId = "tid_intruder",
								VerdictStore = verdictStore(),
								Flush = function()
									return true
								end,
							}, p.C, p.B)
						end
						return true
					end,
				}, p.A, p.B)

				expect(
					`exchange={tostring(outcome)} intruder={tostring(intruder)} refused={tostring(
						intruderErr ~= nil
							and string.find(intruderErr, "already has an exchange in flight", 1, true) ~= nil
					)}`
				).to.equal("exchange=Committed intruder=nil refused=true")
			end)
		end)

		it("leaves the intruder's own profile untouched, so a refused attempt costs nothing", function()
			-- A refusal that half-staked the third player would be worse than the window
			-- it was closing.
			harnessed(function(harness)
				local p = three(harness)
				local dc = harness.Data.Get(p.PC)

				Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = verdictStore(),
					Flush = function()
						Exchange.Attempt({
							ExchangeId = "tid_intruder",
							VerdictStore = verdictStore(),
							Flush = function()
								return true
							end,
						}, p.C, p.B)
						return true
					end,
				}, p.A, p.B)

				expect(
					`item={tostring(dc.Inventory["c_item"].Get() ~= nil)} record={tostring(
						p.C.Ctx.Tree.Reserved.Exchange["tid_intruder"].Get()
					)}`
				).to.equal("item=true record=nil")
			end)
		end)

		it("REFUSES the intruder even before the first flush, because both claims land first", function()
			-- The claims are back to back with no yield, so the slot is taken from the
			-- moment the attempt starts doing anything at all. Driving the intruder from
			-- the FIRST flush already proves that, but this pins the reason: the record
			-- exists, not merely an in-flight set entry that a second server could not see.
			harnessed(function(harness)
				local p = three(harness)
				local sawRecord
				Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = verdictStore(),
					Flush = function()
						sawRecord = sawRecord
							or (
								p.B.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil
								and p.A.Ctx.Tree.Reserved.Exchange[TID].Get() ~= nil
							)
						return true
					end,
				}, p.A, p.B)
				expect(`bothClaimedBeforeAnyYield={tostring(sawRecord)}`).to.equal("bothClaimedBeforeAnyYield=true")
			end)
		end)
	end)

	describe("R1b: the guard covers the window after the records are gone", function()
		-- ROUND 4. R1 above checks the pre-verdict flush, where both records exist and
		-- the admission reads them. There is a SECOND yielding window, after the
		-- verdict: Settle REMOVES each record, and the two resolve flushes and two
		-- deliveries all yield afterwards. Throughout that window the durable check
		-- sees an empty container and admits freely, so the record cannot be the only
		-- guard. The in-flight set is the one that can cover it, and until this round
		-- nothing consulted it on admission and every clear treated it as a set of
		-- user ids rather than the userId-to-exchangeId map it is.

		it("REFUSES a third player who slips in AFTER the settle, when both records are gone", function()
			harnessed(function(harness)
				local p = three(harness)
				local intruder, intruderErr
				local recordsAtIntrusion
				local attempts = 0
				local inFlight = {}

				local outcome = Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = verdictStore(),
					InFlight = inFlight,
					Flush = function()
						attempts += 1
						-- Flushes 1 and 2 are the pre-verdict pair. Flush 3 is the
						-- first one inside Resolve, after both settles.
						if attempts == 3 then
							recordsAtIntrusion = tostring(p.B.Ctx.Tree.Reserved.Exchange[TID].Get())
							intruder, intruderErr = Exchange.Attempt({
								ExchangeId = "tid_late_intruder",
								VerdictStore = verdictStore(),
								InFlight = inFlight,
								Flush = function()
									return true
								end,
							}, p.C, p.B)
						end
						return true
					end,
				}, p.A, p.B)

				expect(
					`exchange={tostring(outcome)} recordGone={recordsAtIntrusion} intruder={tostring(intruder)} refused={tostring(
						intruderErr ~= nil
							and string.find(intruderErr, "already has an exchange in flight", 1, true) ~= nil
					)}`
				).to.equal("exchange=Committed recordGone=nil intruder=nil refused=true")
			end)
		end)

		it("does not strand both players when the forced flush RAISES instead of returning false", function()
			-- Once admission reads the in-flight set, a leaked registration stops being
			-- a sweep problem and becomes a permanent exchanging ban for both players. The
			-- two pre-verdict flushes were the one unguarded call in the attempt: a
			-- false from them is already handled as unresolved, but a RAISE travelled
			-- straight out of Attempt with both records staked, no verdict proposed and
			-- both registrations still held. Persistence.Flush is what the server passes
			-- here, so this is a real call into another subsystem, not a hypothetical.
			harnessed(function(harness)
				local p = three(harness)
				local inFlight = {}

				local pok, outcome, err = pcall(Exchange.Attempt, {
					ExchangeId = TID,
					VerdictStore = verdictStore(),
					InFlight = inFlight,
					Flush = function()
						error("the datastore said no", 0)
					end,
				}, p.A, p.B)

				expect(
					`raised={tostring(not pok)} outcome={tostring(outcome)} why={tostring(err)} a={tostring(
						inFlight[A_ID]
					)} b={tostring(inFlight[B_ID])} aItem={tostring(
						p.A.Ctx.Tree.Reserved.Exchange[TID].Get() == nil
					)}`
				).to.equal(
					"raised=false outcome=Aborted why=a stake could not be proved durable a=nil b=nil aItem=true"
				)
			end)
		end)

		it("clears only the registration it owns, because the set is a map and not a set", function()
			-- Every clear deleted by user id alone. A resolution finishing for one exchange
			-- therefore deleted whatever registration that player currently held, which
			-- after the window above can be a DIFFERENT, live exchange. The consequence is
			-- not lost value: it is that the sweep loses its only same-server guard for
			-- an exchange that is still running.
			harnessed(function(harness)
				local p = three(harness)
				local inFlight = { [A_ID] = TID, [B_ID] = "tid_someone_elses" }

				Exchange.Resolve({
					VerdictStore = verdictStore(),
					InFlight = inFlight,
					Flush = function()
						return true
					end,
				}, p.A, p.B, TID, "digest-r1b", "Abort", nil)

				expect(`own={tostring(inFlight[A_ID])} foreign={tostring(inFlight[B_ID])}`).to.equal(
					"own=nil foreign=tid_someone_elses"
				)
			end)
		end)

		it("releases them when NO verdict could be established, which is the common failure", function()
			-- The branch that gives up because the store could not answer. It leaves
			-- both records exactly as they are, on purpose, and until this round it left
			-- both registrations too. That is the reachable version of the ban: one
			-- store hiccup at the wrong instant and neither player can exchange again for
			-- the life of the server, with the sweep skipping them the whole time.
			--
			-- Releasing is safe because the records are still there: admission reads
			-- those too, so the player stays blocked from a NEW exchange while the sweep
			-- becomes able to finish the old one.
			harnessed(function(harness)
				local p = three(harness)
				local inFlight = { [A_ID] = TID, [B_ID] = TID }

				local outcome, err = Exchange.Resolve({
					VerdictStore = {
						UpdateAsync = function()
							return nil, "the store is having a day"
						end,
						GetAsync = function()
							return nil, "the store is having a day"
						end,
					},
					InFlight = inFlight,
					Flush = function()
						return true
					end,
				}, p.A, p.B, TID, "digest-r1b", "Abort", nil)

				expect(
					`outcome={tostring(outcome)} named={tostring(
						err ~= nil and string.find(err, "no verdict could be established", 1, true) ~= nil
					)} a={tostring(inFlight[A_ID])} b={tostring(inFlight[B_ID])}`
				).to.equal("outcome=nil named=true a=nil b=nil")
			end)
		end)

		it("still releases its own registrations when the verdict does not govern the exchange", function()
			-- The corruption branch refuses to settle and leaves both records for an
			-- operator, which is right. It also returned without releasing anything,
			-- and because the sweep skips any player named in the set, that left the
			-- liveness machinery switched off for both of them for the life of the
			-- server: the one exchange that needs a human to look at it is the one nothing
			-- would ever log about again.
			harnessed(function(harness)
				local p = three(harness)
				local store = verdictStore()
				store:UpdateAsync(TID, function()
					return { V = "Commit", A = A_ID, B = B_ID, D = "a-completely-different-digest" }
				end)
				local inFlight = { [A_ID] = TID, [B_ID] = TID }

				local outcome, err = Exchange.Resolve({
					VerdictStore = store,
					InFlight = inFlight,
					Flush = function()
						return true
					end,
				}, p.A, p.B, TID, "digest-r1b", "Abort", nil)

				expect(
					`outcome={tostring(outcome)} named={tostring(
						err ~= nil and string.find(err, "does not govern", 1, true) ~= nil
					)} a={tostring(inFlight[A_ID])} b={tostring(inFlight[B_ID])}`
				).to.equal("outcome=nil named=true a=nil b=nil")
			end)
		end)
	end)

	describe("R3: the cross-tree guard is never reopened", function()
		it("has no transaction open at any yield inside the attempt", function()
			-- Probed rather than inspected. If a transaction were open on any tree,
			-- opening one on a THIRD player would raise with the cross-player refusal,
			-- which is the exact guard that shipped because the naive shape minted
			-- currency. A clean open here proves OPEN_TXN_TREE was nil.
			harnessed(function(harness)
				local p = three(harness)
				local yields, clean = 0, 0

				Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = verdictStore(),
					Flush = function()
						yields += 1
						local ok = pcall(function()
							local wrote = harness.Data.Transaction(p.PC, function()
								harness.Data.Get(p.PC).Coins.Increment(1)
							end)
							return wrote
						end)
						if ok then
							clean += 1
						end
						return true
					end,
				}, p.A, p.B)

				expect(`yields={yields > 0} clean={clean == yields}`).to.equal("yields=true clean=true")
			end)
		end)

		it("leaves the cross-tree guard ALIVE, so the shape that minted currency still raises", function()
			-- The first draft of this case counted a variable nothing incremented and
			-- compared a function to itself. It passed on everything.
			--
			-- What actually matters: the feature must not have disabled the guard on its
			-- way past it. So the forbidden shape is attempted deliberately, and it has
			-- to still be refused, by the same message that shipped.
			harnessed(function(harness)
				local p = three(harness)
				local db = harness.Data.Get(p.PB)

				-- Data.Transaction RETURNS (false, err) for an ordinary body failure and only
				-- RAISES for a dead tree, nesting, a cross-player transaction, or a failed
				-- rollback. A cross-tree WRITE is the first kind, so the refusal arrives in
				-- the return value. The first draft of this case checked for a raise and
				-- reported raised=false: the guard was working and the assertion was not.
				local ok, err = harness.Data.Transaction(p.PA, function()
					db.Coins.Increment(500) -- the other player's tree
				end)

				expect(
					`refused={tostring(ok == false)} named={tostring(
						string.find(tostring(err), "belongs to a different player", 1, true) ~= nil
					)} bCoins={db.Coins.Get()}`
				).to.equal("refused=true named=true bCoins=0")
			end)
		end)

		it("conserves both profiles across a completed exchange, which is what the guard protects", function()
			-- The substance of the spec that pins the original defect, asserted directly
			-- rather than by reading that file's text. The first draft of this case tried
			-- to read the sibling spec's source; the sibling resolved to nil, so it
			-- returned early and asserted nothing on every run.
			harnessed(function(harness)
				local p = three(harness)
				local da, db = harness.Data.Get(p.PA), harness.Data.Get(p.PB)
				da.Coins.Set(100)
				db.Coins.Set(0)

				p.A.Legs = {
					{ Path = { "Inventory" }, Kind = "Key", Key = "a_item" },
					{ Path = { "Coins" }, Kind = "Qty", Amount = 50 },
				}

				local outcome = Exchange.Attempt({
					ExchangeId = TID,
					VerdictStore = verdictStore(),
					Flush = function()
						return true
					end,
				}, p.A, p.B)

				-- 100 in, 100 out, and each item on exactly one profile.
				local total = da.Coins.Get() + db.Coins.Get()
				local aHasB = da.Inventory["b_item"].Get() ~= nil
				local bHasA = db.Inventory["a_item"].Get() ~= nil
				local aStillHasA = da.Inventory["a_item"].Get() ~= nil
				expect(
					`{tostring(outcome)} total={total} moved={tostring(aHasB and bHasA)} duplicated={tostring(
						aStillHasA
					)}`
				).to.equal("Committed total=100 moved=true duplicated=false")
			end)
		end)
	end)
end
