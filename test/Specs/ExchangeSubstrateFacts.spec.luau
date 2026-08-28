--!nonstrict
-- STEP 0 of the ClaimExchange build: pin the four source facts the design rests on.
--
-- These were INFERENCE in every design round, and inference is what killed rounds one
-- through five. Each is load-bearing in a different place, and if any one of them is
-- false the DESIGN changes rather than the implementation, which is why they are
-- characterised before a line of protocol code exists.
--
--   (i)   A dynamic key of an untyped reserved container can be Set and Removed inside
--         a transaction with no Closed-record refusal. `_Scribe.Exchange` will be exactly
--         such a container, and SETTLE INFALLIBILITY is the whole redesign: after the
--         verdict, a settle must not be refusable by anything data-dependent.
--   (ii)  A container `Get()` on an ordinary game path hands back the LIVE table, while
--         a reserved-root read hands back a detached copy. The first is why the lien
--         was abandoned; the second is the entire ghost-unreachability argument.
--   (iii) A cross-tree READ inside an open transaction is permitted, while a write is
--         refused. Admission reads the counterparty, so if reads were refused too the
--         protocol could not be written as specified.
--   (iv)  A wipe-guard Block does not revert the in-memory tree. Escrow lives in the
--         tree across a flush, and a Block that rolled the tree back would silently
--         restore staked value while the counterparty's copy stayed durable.
--   (v)   An item carrying a Scribe datatype cannot be escrowed in the form a read
--         hands back, but CAN be escrowed in its packed form. This decides STEP 2's
--         open question: refuse datatype-bearing exchangeable paths outright, or carry
--         the packed form. The answer changes what applyLeg is allowed to move.
--
-- Deliberately NOT a Sim spec. None of the four needs a second server or a modelled
-- disk, and running them on both hosts is worth more than the fixture would buy.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Template = require(Root.Scribe.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Datatypes = require(Root.Scribe.Internal.Datatypes)

	local RESERVED = Template.RESERVED_ROOT

	local function harnessed(fn, options)
		local harness = TestCtx.make({
			Template = {
				Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
				Inventory = Scribe.DictOf({
					Qty = Scribe.Int(1, { Min = 1, Max = 999 }),
					-- Padding, so a collapse clears the wipe guard's 1024-byte floor.
					Note = Scribe.String("x", { MaxLength = 200 }),
				}, { MaxKeys = 50 }),
				-- Fact (v): one declared datatype field, which is what makes an
				-- element's stored form packed.
				Marker = Scribe.Vector3(Vector3.new(0, 0, 0)),
			},
			Options = options,
		})
		local ok, err = pcall(fn, harness)
		harness.Cleanup()
		if not ok then
			error(err, 0)
		end
	end

	describe("(i) an untyped reserved container takes and drops a dynamic key inside a transaction", function()
		-- PendingGifts stands in for _Scribe.Exchange: same shape, already shipped, and the
		-- precedent the design says to follow. If a dynamic key of it were refused, the
		-- infallible-settle claim would be false and the redesign would have no floor.
		it("Sets and Removes a dynamic key through Tree.Reserved, inside a transaction", function()
			harnessed(function(harness)
				local player, entry = harness.Join(70101)
				local reserved = entry.Tree.Reserved

				local setOk, setErr = harness.Data.Transaction(player, function()
					reserved.PendingGifts["exchange-tid-1"].Set({ Role = "A", Amount = 500 })
				end)
				expect(`set ok={tostring(setOk)} err={tostring(setErr)}`).to.equal("set ok=true err=nil")
				expect(reserved.PendingGifts["exchange-tid-1"].Get().Amount).to.equal(500)

				local delOk, delErr = harness.Data.Transaction(player, function()
					reserved.PendingGifts["exchange-tid-1"].Set(nil)
				end)
				expect(`del ok={tostring(delOk)} err={tostring(delErr)}`).to.equal("del ok=true err=nil")
				expect(reserved.PendingGifts["exchange-tid-1"].Get()).to.equal(nil)
			end)
		end)

		it("refuses the same write from game code, so the container is library-owned", function()
			-- The other half of the fact. A settle is infallible BECAUSE only the library
			-- can reach these paths; if game code could write them the ghost argument and
			-- the record's integrity both go.
			harnessed(function(harness)
				local player = harness.Join(70102)
				local data = harness.Data.Get(player)
				expect(function()
					(data :: any)[RESERVED].PendingGifts["exchange-tid-1"].Set({ Role = "A" })
				end).to.throw()
			end)
		end)
	end)

	describe("(ii) a game container Get() is live; a reserved read is detached", function()
		it("hands back the LIVE table for an ordinary game container", function()
			-- This is why the lien is dead. A caller can mutate the container it was
			-- handed and no write funnel ever runs, so no predicate sited in those
			-- funnels can protect a staked item. Pinned so nobody re-proposes the lien.
			harnessed(function(harness)
				local player = harness.Join(70201)
				local data = harness.Data.Get(player)
				data.Inventory["sword"].Set({ Qty = 1 })

				local live = data.Inventory.Get()
				live.sword = nil -- no accessor, no funnel, no op

				expect(data.Inventory.Get().sword).to.equal(nil)
			end)
		end)

		it("hands back a DETACHED copy for a reserved-root read, so a ghost cannot be reached", function()
			harnessed(function(harness)
				local player, entry = harness.Join(70202)
				entry.Tree.Reserved.PendingGifts["ghost"].Set({ Amount = 500 })

				local data = harness.Data.Get(player)
				-- Get(), not an index. Indexing the reserved root hands back an ACCESSOR,
				-- which is a table too, so a type check on it passes without ever
				-- touching a stored value and the test proves nothing.
				local copy = (data :: any)[RESERVED].PendingGifts.Get()
				expect(type(copy)).to.equal("table")
				expect(copy.ghost.Amount).to.equal(500)
				copy.ghost.Amount = 999
				copy.ghost = nil

				local stored = entry.Tree.Reserved.PendingGifts["ghost"].Get()
				expect(`present={tostring(stored ~= nil)} amount={tostring(stored and stored.Amount)}`).to.equal(
					"present=true amount=500"
				)
			end)
		end)
	end)

	describe("(iii) a cross-tree READ inside an open transaction is permitted", function()
		it("reads the counterparty while a transaction is open, and refuses to write them", function()
			-- Admission reads both players. If the open-transaction guard refused reads
			-- as well as writes, the protocol could not be written as specified.
			harnessed(function(harness)
				local pa = harness.Join(70301)
				local pb = harness.Join(70302)
				local dA, dB = harness.Data.Get(pa), harness.Data.Get(pb)
				dB.Coins.Set(250)

				local readBack, wroteOk
				local ok = harness.Data.Transaction(pa, function()
					dA.Coins.Set(10)
					readBack = dB.Coins.Get() -- READ: must be allowed
					wroteOk = pcall(function()
						dB.Coins.Set(999) -- WRITE: must be refused
					end)
				end)

				expect(`txn={tostring(ok)} read={tostring(readBack)} wrote={tostring(wroteOk)}`).to.equal(
					"txn=true read=250 wrote=false"
				)
				-- The refused write left nothing behind.
				expect(dB.Coins.Get()).to.equal(250)
			end)
		end)
	end)

	describe("(iv) a wipe-guard Block does not revert the in-memory tree", function()
		it("keeps the live value after a blocked save, so escrow survives the flush", function()
			-- Escrow sits in the tree across a flush. A Block that rolled the tree back
			-- would restore staked value while the counterparty's copy stayed durable,
			-- which is a mint with no crash anywhere.
			harnessed(function(harness)
				local player, entry = harness.Join(70401)
				local data = harness.Data.Get(player)

				-- Measured: this seeds 8482 bytes and collapses to 209, which clears the
				-- guard's 1024-byte floor and its 60% ratio. Twenty bare items did not,
				-- and the test passed green while never tripping the guard once.
				local pad = string.rep("y", 180)
				for i = 1, 40 do
					data.Inventory[`it{i}`].Set({ Qty = 1, Note = pad })
				end
				data.Coins.Set(5000)
				expect(harness.Data.Flush(player, { Timeout = 30 })).to.equal(true)

				harness.Data.Transaction(player, function()
					for i = 1, 40 do
						data.Inventory[`it{i}`].Set(nil)
					end
					data.Coins.Set(1)
				end)

				local flushed = harness.Data.Flush(player, { Timeout = 30 })
				-- The Block must actually have happened, or the rest is vacuous.
				expect(`flush={tostring(flushed)} blocked={tostring(entry.Blocked)}`).to.equal(
					"flush=false blocked=true"
				)
				-- Whatever the guard decided about the BYTES, the live tree still holds
				-- what was written. A Block that rolled the tree back would restore
				-- staked value here while the counterparty's copy stayed durable.
				expect(`coins={tostring(data.Coins.Get())} items={tostring(next(data.Inventory.Get()) ~= nil)}`).to.equal(
					"coins=1 items=false"
				)
			end, { WipeGuardPolicy = "Block" })
		end)
	end)

	describe("(v) a datatype escrows in its packed form, never in the form a read hands back", function()
		it("REFUSES the unpacked value a read returns, which is the obvious implementation", function()
			-- The trap STEP 2 has to avoid. A read UNPACKS, so the value in hand is real
			-- userdata; the escrow container is untyped, and the generic gate refuses
			-- userdata outright (Node.luau:1073-1076). An applyLeg written the obvious
			-- way raises on every exchange of an item carrying a datatype, at stake time,
			-- forever, with no diagnosis pointing at the cause.
			harnessed(function(harness)
				local player, entry = harness.Join(70501)
				local data = harness.Data.Get(player)
				data.Marker.Set(Vector3.new(1, 2, 3))

				local unpacked = data.Marker.Get()
				expect(typeof(unpacked)).to.equal("Vector3")

				local ok, err = pcall(function()
					entry.Tree.Reserved.PendingGifts["exchange-dt"].Set({ Value = unpacked })
				end)
				expect(`ok={tostring(ok)} named={tostring(string.find(tostring(err), "Vector3") ~= nil)}`).to.equal(
					"ok=false named=true"
				)
			end)
		end)

		it("ACCEPTS the packed form and hands it back into a declared datatype field intact", function()
			-- The half that decides the design. A packed datatype is a buffer; the
			-- untyped path stores one by cloning it (Node.luau:1201-1204) and a declared
			-- datatype field accepts one back the same way (Node.luau:1067-1071). So the
			-- round trip exists and datatype-bearing items need not be refused at
			-- registration.
			harnessed(function(harness)
				local player, entry = harness.Join(70502)
				local data = harness.Data.Get(player)
				local original = Vector3.new(1, 2, 3)
				data.Marker.Set(original)

				local packed = Datatypes.Pack("Vector3", original)
				expect(type(packed)).to.equal("buffer")

				-- Into the untyped reserved container, inside a transaction, the way an
				-- escrow writes it.
				local setOk = harness.Data.Transaction(player, function()
					entry.Tree.Reserved.PendingGifts["exchange-dt"].Set({ Value = packed })
				end)
				expect(setOk).to.equal(true)

				-- And back onto the declared field, the way a delivery writes it.
				local stored = entry.Tree.Reserved.PendingGifts["exchange-dt"].Get()
				data.Marker.Set(Vector3.new(9, 9, 9))
				local backOk = harness.Data.Transaction(player, function()
					data.Marker.Set(stored.Value)
				end)

				-- Compared COMPONENTWISE, not by tostring. Under the headless shim a
				-- datatype is a table, so tostring prints an address and two equal
				-- values never match; the comparison would fail on a working round
				-- trip and pass on nothing.
				local back = data.Marker.Get()
				expect(`ok={tostring(backOk)} type={typeof(back)} xyz={back.X},{back.Y},{back.Z}`).to.equal(
					"ok=true type=Vector3 xyz=1,2,3"
				)
			end)
		end)
	end)
end
