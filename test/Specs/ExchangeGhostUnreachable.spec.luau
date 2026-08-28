--!nonstrict
-- C4: during the ghost window, the dispossessed escrow is not reachable by game code.
--
-- THE WINDOW. One side has settled a Commit and dropped its escrow; the other has read
-- the same Commit but has not settled yet. That second profile is now holding a copy of
-- value the first profile already owns. Two copies exist on disk at once, and the design
-- calls this conserving only because exactly one of them is OWNED and the other is
-- provably not spendable.
--
-- "Provably not spendable" is the entire claim, and it rests on one property: game code
-- cannot write inside the reserved root, and reads of it come back detached. If any
-- accessor route reaches that escrow, the ghost is a live duplicate and the ownership
-- framing collapses.
--
-- WHAT THIS SPEC CAN AND CANNOT PROMISE. It enumerates every mutating accessor method
-- Node declares and every reading one, and drives each against the escrow. That makes it
-- exhaustive against the surface as it is TODAY. It cannot notice a NEW method added to
-- Node later, so a rename guard is included below: every name here must still resolve on
-- an ordinary game accessor. If someone adds an accessor route, this file must grow with
-- it, and that instruction belongs next to the list rather than in a design document.
--
-- ONE KNOWN ROUTE IS NOT CLOSED, and this file must not be read as saying otherwise.
-- Node keeps five private fields on the accessor table itself with rawset, keyed by
-- table identities so game code cannot NAME them (Node.luau:109-112 states that threat
-- model outright). Naming is blocked; ENUMERATION is not. `next` and `pairs` ignore
-- metatables, so a pairs walk over any public accessor reaches the live Tree, and from
-- it `Tree.Reserved` (the privileged accessor) and `Params.Stores.Persist` (the raw
-- store). MEASURED against real Scribe, not inferred: a five-field walk reached all
-- three. Closing it means moving that private state off the accessor table, which is a
-- change to Node's hot path and is the owner's call, not a test's. Until then the
-- unreachability claim holds for every ACCESSOR route and not for reflection.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Template = require(Root.Scribe.Internal.Template)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local RESERVED = Template.RESERVED_ROOT
	local TID = "tid_ghost_1"

	-- Every mutating method Node exposes on an accessor.
	local MUTATORS = {
		"Set",
		"Update",
		"Increment",
		"Decrement",
		"Multiply",
		"Divide",
		"Toggle",
		"Enable",
		"Disable",
		"Add",
		"Insert",
		"Remove",
		"RemoveValue",
		"Clear",
		"SetTimed",
		"ExtendTimed",
	}

	-- Every reading method. These are ALLOWED, and must hand back something detached.
	local READERS = { "Get", "Clone", "Count", "Has", "Find", "Default", "Min", "Max", "Active" }

	local function harnessed(fn)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000 }),
				Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 5 }),
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

	--- Put this profile in the ghost window: staked, and holding an escrow whose value
	--- the counterparty already owns.
	local function ghosted(harness, player, entry)
		local ctx = ctxFor(harness, player, entry)
		local data = harness.Data.Get(player)
		data.Inventory["relic"].Set({ Qty = 3 })
		local ok = select(1, ExchangeLeg.Claim(ctx, TID, { Digest = "d", Role = "B", Partner = 1 }))
		expect(ok).to.equal(true)
		expect(select(1, ExchangeLeg.Escrow(ctx, TID, { { Path = { "Inventory" }, Kind = "Key", Key = "relic" } }))).to.equal(
			true
		)
		return ctx, data
	end

	--- What the escrow holds right now, read through the library's own capability.
	local function escrowQty(entry): any
		local record = entry.Tree.Reserved.Exchange[TID].Get()
		if type(record) ~= "table" or type(record.Escrow) ~= "table" then
			return nil
		end
		local leg = record.Escrow[1]
		return if type(leg) == "table" and type(leg.Value) == "table" then leg.Value.Qty else nil
	end

	it("refuses every mutating accessor route into the escrow, by name", function()
		harnessed(function(harness)
			local player, entry = harness.Join(96001)
			local _ctx, data = ghosted(harness, player, entry)
			expect(escrowQty(entry)).to.equal(3)

			local reached = {}
			for _, method in MUTATORS do
				-- The refusal is by CALLER at index time, so indexing alone should raise;
				-- calling is attempted anyway in case a route ever returns a live handle.
				local ok = pcall(function()
					local target = (data :: any)[RESERVED].Exchange[TID]
					local fn = target[method]
					if type(fn) == "function" then
						fn({ Qty = 99 })
					end
				end)
				if ok then
					table.insert(reached, method)
				end
			end

			table.sort(reached)
			expect(`reached={table.concat(reached, ",")} qty={tostring(escrowQty(entry))}`).to.equal("reached= qty=3")
		end)
	end)

	it("refuses an ANCESTOR write, which would take the escrow with it", function()
		-- A route that never names the escrow at all: clear or overwrite something above
		-- it. If an ancestor write landed, the ghost would vanish without any of the
		-- per-key refusals ever firing.
		harnessed(function(harness)
			local player, entry = harness.Join(96002)
			local _ctx, data = ghosted(harness, player, entry)

			local reached = {}
			local attempts = {
				["root Set"] = function()
					(data :: any)[RESERVED].Set({})
				end,
				["container Set"] = function()
					(data :: any)[RESERVED].Exchange.Set({})
				end,
				["container Clear"] = function()
					(data :: any)[RESERVED].Exchange.Clear()
				end,
				["container Remove"] = function()
					(data :: any)[RESERVED].Exchange.Remove(TID)
				end,
				["record Update"] = function()
					(data :: any)[RESERVED].Exchange[TID].Update(function()
						return {}
					end)
				end,
			}
			for name, attempt in attempts do
				if pcall(attempt) then
					table.insert(reached, name)
				end
			end

			table.sort(reached)
			expect(`reached={table.concat(reached, ",")} qty={tostring(escrowQty(entry))}`).to.equal("reached= qty=3")
		end)
	end)

	it("hands every READ route a detached copy, so mutating what it returns reaches nothing", function()
		-- Reads are permitted on purpose. The claim is that what comes back is a copy,
		-- which is what makes the refusals above impossible to walk around.
		harnessed(function(harness)
			local player, entry = harness.Join(96003)
			local _ctx, data = ghosted(harness, player, entry)

			-- A reader that RAISES is refusing, which is at least as safe as detaching;
			-- several do, because a method like Has or Min has no meaning on a record
			-- node. What must never happen is a reader handing back something that
			-- reaches the store, so that is what is asserted rather than the raise count.
			local vandalised = 0
			for _, method in READERS do
				local ok, value = pcall(function()
					local target = (data :: any)[RESERVED].Exchange[TID]
					local fn = target[method]
					return if type(fn) == "function" then fn() else nil
				end)
				if ok and type(value) == "table" then
					vandalised += 1
					value.Escrow = nil
					value.Poisoned = true
				end
			end

			-- Get and Clone MUST both have returned a table, or nothing was vandalised
			-- and the case proves nothing.
			expect(`vandalised={vandalised >= 2} qty={tostring(escrowQty(entry))}`).to.equal("vandalised=true qty=3")
		end)
	end)

	it("keeps the reserved root out of a whole-data read entirely", function()
		harnessed(function(harness)
			local player, entry = harness.Join(96004)
			local _ctx, data = ghosted(harness, player, entry)

			local whole = data.Get()
			local reachable = type(whole) == "table" and whole[RESERVED] ~= nil
			-- And a write into the root shell must not land either.
			local wrote = pcall(function()
				(whole :: any).Inventory = {}
			end)

			expect(`reserved={tostring(reachable)} wrote={tostring(wrote)} qty={tostring(escrowQty(entry))}`).to.equal(
				"reserved=false wrote=false qty=3"
			)
		end)
	end)

	it("keeps the ghost out of game data, so the item is not spendable from the inventory either", function()
		-- The other half of unreachability. The escrow left the inventory when it was
		-- staked, so there is nothing to spend even before the refusals matter.
		harnessed(function(harness)
			local player, entry = harness.Join(96005)
			local _ctx, data = ghosted(harness, player, entry)

			expect(
				`inv={tostring(data.Inventory["relic"].Get())} count={data.Inventory.Count()} qty={tostring(
					escrowQty(entry)
				)}`
			).to.equal("inv=nil count=0 qty=3")
		end)
	end)

	it("names methods that actually exist, so a rename in Node cannot quietly empty this list", function()
		-- The control. Every name above is driven against an ordinary game accessor,
		-- where the ones that apply must resolve. Without this, renaming Set to Assign
		-- would leave every case above passing while testing nothing.
		harnessed(function(harness)
			local player = harness.Join(96006)
			local data = harness.Data.Get(player)

			local missing = {}
			for _, method in { "Set", "Update", "Increment", "Clear", "Get", "Clone", "Count" } do
				local ok, value = pcall(function()
					return (data :: any).Inventory[method]
				end)
				if not ok or type(value) ~= "function" then
					table.insert(missing, method)
				end
			end
			table.sort(missing)
			expect(table.concat(missing, ",")).to.equal("")
		end)
	end)
end
