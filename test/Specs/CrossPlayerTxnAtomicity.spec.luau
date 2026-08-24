--!nonstrict
-- WHAT CHANGED IN THIS FILE, AND WHY
--
-- This file used to CHARACTERISE a bug. `Data.Transaction`'s nesting guard reads
-- `if self._txn then error("transactions do not nest") end`, and `self` is ONE
-- PLAYER'S TREE, so it fired for `Transaction(A) > Transaction(A)` and was silent
-- for `Transaction(A) > Transaction(B)` -- the shape a trade is actually written
-- in. The old cases pinned what that produced:
--
--   * outer throws after the inner committed  -> A=100 B=50: 50 coins MINTED
--   * inner rolls back, outer commits         -> total 50 from 100: 50 DESTROYED,
--     and the outer call returned `true` while it happened
--   * no nesting needed at all: a bare write to B's tree inside A's transaction
--     survived A's rollback
--
-- All four are now REFUSED at the source, so those assertions could not survive:
-- an expectation of `A=100 B=50` is an expectation that the mint still happens.
-- Every one of them has been rewritten to pin the REFUSAL and the conservation
-- that follows from it. Nothing was deleted to make a failure go away -- each old
-- case has a successor here running the same body and asserting the new outcome.
--
-- KEPT EXACTLY AS THEY WERE, because they are what makes the rest legible:
--   * "gives each player their own Tree" -- every claim below is a claim about two
--     DIFFERENT trees; if a refactor unified them, this file would silently turn
--     into same-player nesting and keep passing while testing the opposite thing.
--   * same-player nesting is still refused, still as a return value and not a
--     throw, and still with the ORIGINAL "do not nest" wording. The two refusals
--     are different sentences on purpose and the specs hold them apart.
--   * a single-player transaction still commits, and still rolls back.
--   * the happy path is still green -- it is just written the way the library now
--     supports: two separate transactions, not one nested inside the other.
--   * the whole `Data.OnMessage` describe block, unchanged. It measures when a
--     cross-server message is ACKNOWLEDGED, which nothing here touches, and it
--     matters more now than it did: the outbox it describes is the escape route
--     the refusal points developers at.
--
-- THE RULE BEING PINNED: while a transaction is open, a write to a DIFFERENT
-- player's tree is refused. Not a new rule -- Scribe already refuses a YIELD
-- inside a transaction, for the reason Monetization gives on the Grant path
-- ("The Grant yielded, so it cannot be made atomic: a rollback across a ..."). A
-- cross-tree write cannot be rolled back either, because it is a different
-- DataStore key. This is that rule applied consistently.
return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Node = require(Root.Scribe.Internal.Node)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local AMOUNT = 50

	-- The two refusals say different things and must not be confused for each
	-- other: a spec that matched on "Scribe:" alone would pass if the cross-player
	-- guard were replaced by the nesting guard, which refuses the right call for
	-- the wrong reason and would take the same-player control down with it.
	local NEST_TEXT = "do not nest"
	local SPAN_TEXT = "do not span players"
	local FOREIGN_TEXT = "belongs to a different player"

	local harness, Data
	local pa, pb, dA, dB, entryA, entryB

	-- A = 100, B = 0. Both sides carry the same declarator, and both bounds are
	-- present so a clamp would be a visible number rather than a silent no-op.
	local function setup()
		harness = TestCtx.make({
			Template = { Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }) },
		})
		Data = harness.Data
		pa, entryA, dA = harness.Join(1001)
		pb, entryB, dB = harness.Join(1002)
		dA.Coins.Set(100)
		dB.Coins.Set(0)
	end

	local function coins()
		return dA.Coins.Get(), dB.Coins.Get()
	end

	--- Run `fn` and return the error text, or nil if it did not throw.
	local function throwsAbout(fn): string?
		local ok, err = pcall(fn)
		if ok then
			return nil
		end
		return tostring(err)
	end

	local function has(text: string?, needle: string): boolean
		return text ~= nil and string.find(text, needle, 1, true) ~= nil
	end

	beforeEach(setup)

	afterEach(function()
		if harness then
			harness.Cleanup()
		end
		harness, Data = nil, nil
		pa, pb, dA, dB, entryA, entryB = nil, nil, nil, nil, nil, nil
	end)

	-- Everything below is a claim about two DIFFERENT trees. If a refactor ever
	-- unified them, every case in this file would silently become same-tree nesting
	-- and would keep passing while testing the opposite thing.
	it("gives each player their own Tree", function()
		expect(entryA.Tree).to.be.ok()
		expect(entryB.Tree).to.be.ok()
		expect(entryA.Tree).never.to.equal(entryB.Tree)
	end)

	describe("the shapes that still work", function()
		-- THE LIVENESS GATE. Without it a clamp or a wrong accessor path no-ops both
		-- legs and every conservation assertion below passes vacuously: 100/0 in,
		-- 100/0 out, "nothing was lost". This is the same transfer the old happy-path
		-- case ran, written the way the library now supports -- two transactions,
		-- side by side, neither inside the other -- and it must stay green, because
		-- a guard that took the working shape down with the broken one would be a
		-- worse bug than the one it fixed.
		it("moves value between two players as two separate transactions", function()
			local okA = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
			end)
			local okB = Data.Transaction(pb, function()
				dB.Coins.Increment(AMOUNT)
			end)
			local a, b = coins()
			expect(("okA=%s okB=%s A=%d B=%d TOTAL=%d"):format(tostring(okA), tostring(okB), a, b, a + b)).to.equal(
				"okA=true okB=true A=50 B=50 TOTAL=100"
			)
		end)

		it("still commits, and still rolls back, a single-player transaction", function()
			-- THE MECHANISM CONTROL. Every refusal below is asserted alongside "and
			-- nothing moved", which is indistinguishable from "transactions stopped
			-- working entirely" unless a transaction is shown doing both of its jobs.
			local committed = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
			end)
			local afterCommit = dA.Coins.Get()

			local rolledBack, err = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				error("single-player validation failed")
			end)
			local afterRollback = dA.Coins.Get()

			expect(
				("commit=%s A=%d rollback=%s A=%d reason=%s"):format(
					tostring(committed),
					afterCommit,
					tostring(rolledBack),
					afterRollback,
					tostring(has(err, "single-player validation failed"))
				)
			).to.equal("commit=true A=50 rollback=false A=50 reason=true")
		end)

		it("still refuses same-player nesting, and reports it as a return value not a throw", function()
			-- The shape of this assertion is the point. The nest error is raised INSIDE
			-- the outer body, which runs under the outer RunTransaction's own xpcall, so
			-- it never escapes to the caller. A spec written
			-- `expect(pcall(...)).to.equal(false)` fails for the wrong reason; one written
			-- `.to.equal(true)` passes while asserting nothing at all. The only thing that
			-- distinguishes "refused" from "silently allowed" here is the error TEXT.
			--
			-- It must also be refused as NESTING and not as a cross-player span: the
			-- same-player call is the one case the new guard must not claim, or the
			-- older, narrower error disappears from the library.
			local pcallOk, first, err = pcall(function()
				return Data.Transaction(pa, function()
					dA.Coins.Increment(-AMOUNT)
					Data.Transaction(pa, function()
						dA.Coins.Increment(AMOUNT)
					end)
				end)
			end)
			local a = dA.Coins.Get()
			expect(
				("threw=%s outerOk=%s nested=%s span=%s A=%d"):format(
					tostring(not pcallOk),
					tostring(first),
					tostring(has(tostring(err), NEST_TEXT)),
					tostring(has(tostring(err), SPAN_TEXT)),
					a
				)
			).to.equal("threw=false outerOk=false nested=true span=false A=100")
		end)

		it("reads another player's tree freely from inside a transaction", function()
			-- Reads were never the problem and must not become collateral: a trade's
			-- validation leg reads the other side before it writes anything, and a
			-- guard that refused that would make the supported two-transaction shape
			-- unwritable. `.Get()` is not a mutator, so it never enters the guard.
			local sawA, sawB, listened = nil, nil, false
			local ok = Data.Transaction(pa, function()
				sawA = dA.Coins.Get()
				sawB = dB.Coins.Get()
				local disconnect = dB.Coins.Changed(function() end)
				listened = type(disconnect) == "function"
				disconnect()
				dA.Coins.Increment(-AMOUNT)
			end)
			local a, b = coins()
			expect(
				("ok=%s sawA=%s sawB=%s listened=%s A=%d B=%d"):format(
					tostring(ok),
					tostring(sawA),
					tostring(sawB),
					tostring(listened),
					a,
					b
				)
			).to.equal("ok=true sawA=100 sawB=0 listened=true A=50 B=0")
		end)
	end)

	describe("a transaction refuses to reach another player's tree", function()
		it("refuses a nested transaction on a different player", function()
			-- WAS: "commits the inner player's credit through the outer player's
			-- rollback" -- the MINT. Same body, including the outer throw that used to
			-- strand the credit. The inner call never opens now, so the throw is
			-- unreachable and the outer rolls back with nothing to strand.
			local innerOk, err = nil, nil
			local outerOk
			outerOk, err = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				innerOk = Data.Transaction(pb, function()
					dB.Coins.Increment(AMOUNT)
				end)
				error("outer validation failed")
			end)
			local a, b = coins()
			expect(
				("outerOk=%s innerRan=%s span=%s A=%d B=%d TOTAL=%d"):format(
					tostring(outerOk),
					tostring(innerOk ~= nil),
					tostring(has(err, SPAN_TEXT)),
					a,
					b,
					a + b
				)
			).to.equal("outerOk=false innerRan=false span=true A=100 B=0 TOTAL=100")
		end)

		it("refuses a nested transaction that would have rolled back under a committing outer", function()
			-- WAS: "returns true from the outer call while the inner player's half was
			-- rolled back" -- the DESTROY, and the API lying about it. The outer used
			-- to answer `true` because its own tree committed, which is all `true` has
			-- ever meant. Now the refusal is raised inside the outer body, so the outer
			-- fails too and the caller is told with the same value it always read.
			local innerOk, err = nil, nil
			local outerOk
			outerOk, err = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				innerOk = Data.Transaction(pb, function()
					dB.Coins.Increment(AMOUNT)
					error("inner fails")
				end)
			end)
			local a, b = coins()
			expect(
				("outerOk=%s innerRan=%s span=%s A=%d B=%d TOTAL=%d"):format(
					tostring(outerOk),
					tostring(innerOk ~= nil),
					tostring(has(err, SPAN_TEXT)),
					a,
					b,
					a + b
				)
			).to.equal("outerOk=false innerRan=false span=true A=100 B=0 TOTAL=100")
		end)

		it("refuses a nested transaction before its body can yield", function()
			-- WAS: "converts an inner yield into value destruction". The same
			-- destruction, reached without anyone writing `error` -- someone puts a
			-- Flush, a DataStore read or a task.wait in the credit leg. Refused at the
			-- call, so the body never runs and never yields; the failure now arrives
			-- as a refusal instead of as a silent 50-coin hole.
			local innerOk, err = nil, nil
			local outerOk
			outerOk, err = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				innerOk = Data.Transaction(pb, function()
					dB.Coins.Increment(AMOUNT)
					task.wait()
				end)
			end)
			local a, b = coins()
			expect(
				("outerOk=%s innerRan=%s span=%s yield=%s A=%d B=%d TOTAL=%d"):format(
					tostring(outerOk),
					tostring(innerOk ~= nil),
					tostring(has(err, SPAN_TEXT)),
					tostring(has(err, "must not yield")),
					a,
					b,
					a + b
				)
			).to.equal("outerOk=false innerRan=false span=true yield=false A=100 B=0 TOTAL=100")
		end)

		it("refuses a bare write to another player, with no nested transaction anywhere", function()
			-- WAS: "keeps a bare cross-player write made inside a transaction". This is
			-- the shape a developer actually reaches -- no second `Transaction` is typed
			-- anywhere -- and the one the nesting guard could never have caught however
			-- it was scoped, because there is no second transaction to notice. It is
			-- caught on the accessor instead.
			local err
			local outerOk
			outerOk, err = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				dB.Coins.Increment(AMOUNT)
				error("outer validation failed")
			end)
			local a, b = coins()
			expect(
				("outerOk=%s foreign=%s A=%d B=%d TOTAL=%d"):format(
					tostring(outerOk),
					tostring(has(err, FOREIGN_TEXT)),
					a,
					b,
					a + b
				)
			).to.equal("outerOk=false foreign=true A=100 B=0 TOTAL=100")
		end)

		it("refuses EVERY mutator, so a mutator added later is covered without editing this spec", function()
			-- Iterate the canonical table rather than hand-listing, exactly as the
			-- reserved-root guard's spec does: the guard and this assertion then cannot
			-- drift apart. `checked > 0` is load-bearing -- emptying MUTATOR_METHODS
			-- would otherwise make a vacuous loop look like a clean pass.
			--
			-- Every method is INDEXED here before the transaction opens as well as
			-- inside it, and that ordering is the whole point of the second half of
			-- this case: see the next one.
			local checked, missed = 0, {}
			local ok = Data.Transaction(pa, function()
				for name in Node.MUTATOR_METHODS do
					checked += 1
					local err = throwsAbout(function()
						return dB.Coins[name]
					end)
					if not has(err, FOREIGN_TEXT) then
						table.insert(missed, name)
					end
				end
			end)
			table.sort(missed)
			local a, b = coins()
			expect(
				("ok=%s any=%s missed=%s A=%d B=%d"):format(
					tostring(ok),
					tostring(checked > 0),
					table.concat(missed, ","),
					a,
					b
				)
			).to.equal("ok=true any=true missed= A=100 B=0")
		end)

		it("refuses a mutator whose method was already built and cached before the transaction", function()
			-- THE CACHE HOLE, and the reason the guard does not simply sit in front of
			-- the accessor's ordinary method cache. Every non-mutator method is
			-- `rawset` onto the accessor on first index, so the SECOND read is answered
			-- straight off the table and never reaches __index again. The reserved-root
			-- and derived refusals survive that, because they are fixed properties of
			-- the accessor -- a refused method is never built, so it is never cached.
			-- This refusal is not fixed: the very same handle is writable outside a
			-- transaction and must be refused inside one. Warm the cache first, the way
			-- ordinary game code does within seconds of starting, then check.
			dB.Coins.Increment(5)
			dB.Coins.Set(0)
			expect(dB.Coins.Get()).to.equal(0)

			local err
			local ok = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				err = throwsAbout(function()
					dB.Coins.Increment(AMOUNT)
				end)
			end)
			local a, b = coins()
			expect(
				("ok=%s foreign=%s A=%d B=%d TOTAL=%d"):format(
					tostring(ok),
					tostring(has(err, FOREIGN_TEXT)),
					a,
					b,
					a + b
				)
			).to.equal("ok=true foreign=true A=50 B=0 TOTAL=50")
		end)

		it("names the path, and names the way out", function()
			-- A refusal that does not say what to do instead just moves the developer's
			-- problem. The shape being refused -- one player handing value to another --
			-- is a real thing games need; it simply cannot be a transaction, because a
			-- rollback cannot cross a DataStore key. The error has to carry both halves.
			local err
			Data.Transaction(pa, function()
				err = throwsAbout(function()
					dB.Coins.Set(1)
				end)
			end)
			expect(err).to.be.ok()
			local parts = {
				["the path the developer wrote"] = has(err, "Coins"),
				["that it is another player"] = has(err, FOREIGN_TEXT),
				["the reason a rollback cannot reach it"] = has(err, "DataStore key"),
				["the escape route"] = has(err, "Data.SendMessage"),
				["where the escape route is written up"] = has(err, "Transactions guide"),
			}
			local absent = {}
			for label, present in parts do
				if not present then
					table.insert(absent, label)
				end
			end
			table.sort(absent)
			expect(table.concat(absent, ",")).to.equal("")
		end)
	end)

	describe("the refusal reaches the RAW timed writer, which never touches an accessor", function()
		-- Data.OnCooldown and Data.ClearCooldown do not go through the accessor tree.
		-- Server/Timed says so in as many words -- "This deliberately bypasses the
		-- accessor tree" -- because the store is a FLAT dict keyed by full pathKey and
		-- a nested Scribe.Timed field's pathKey embeds \31, which the accessor's
		-- dictionary-key guard rejects. Both of the accessor's guards live in
		-- accessorIndex, so this writer walked past both of them while being
		-- PUBLICLY reachable on any player.
		--
		-- Why that is not survivable: a raw timed write is rolled back by
		-- Tree:RecordRawWrite, and that journal is PER TREE. On the tree that owns the
		-- transaction it restores the pre-write expiry; on any other tree `_txn` is nil
		-- and it is a no-op, so the write outlives the rollback. A cooldown consumed
		-- for a trade that never happened -- or, in the dangerous direction, a purchase
		-- idempotency claim CLEARED on someone else's profile, which is exactly what
		-- lets a retry apply the same purchase twice.
		local KEY = "DailyChest"

		local function timedStoreOf(entry): { [string]: any }
			local reserved = entry.LiveData["_Scribe"]
			return (if type(reserved) == "table" and type(reserved.Timed) == "table" then reserved.Timed else {}) :: any
		end

		local function timedKeys(entry): string
			local keys = {}
			for key in timedStoreOf(entry) do
				table.insert(keys, key)
			end
			table.sort(keys)
			return table.concat(keys, ",")
		end

		it("refuses Data.OnCooldown on another player, and A's own debit rolls back with it", function()
			local ok, err = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				Data.OnCooldown(pb, KEY, 3600)
			end)
			local a, b = coins()
			expect(
				("ok=%s foreign=%s named=%s onCd=%s storeB=[%s] A=%d B=%d TOTAL=%d"):format(
					tostring(ok),
					tostring(has(err, FOREIGN_TEXT)),
					tostring(has(err, KEY)),
					tostring((Data.PeekCooldown(pb, KEY))),
					timedKeys(entryB),
					a,
					b,
					a + b
				)
			).to.equal("ok=false foreign=true named=true onCd=false storeB=[] A=100 B=0 TOTAL=100")
		end)

		it("refuses Data.ClearCooldown on another player, so a live claim survives", function()
			-- The dangerous direction. Armed OUTSIDE, cleared from inside A's
			-- transaction: without the guard the clear lands on B's profile and is not
			-- rolled back with A, so the window it protects is simply gone.
			Data.OnCooldown(pb, KEY, 3600)
			expect((Data.PeekCooldown(pb, KEY))).to.equal(true)
			local armed = timedKeys(entryB)

			local ok, err = Data.Transaction(pa, function()
				Data.ClearCooldown(pb, KEY)
			end)
			expect(
				("ok=%s foreign=%s stillOn=%s store=%s"):format(
					tostring(ok),
					tostring(has(err, FOREIGN_TEXT)),
					tostring((Data.PeekCooldown(pb, KEY))),
					tostring(timedKeys(entryB) == armed)
				)
			).to.equal("ok=false foreign=true stillOn=true store=true")
		end)

		it("refuses with the accessor guard's OWN sentence, not a second one that can drift", function()
			-- One rule, one implementation, one message. If the raw writer grew its own
			-- copy of the wording, a reword of either would leave the other behind and
			-- a developer would meet two different explanations of the same refusal.
			local _, accessorErr = Data.Transaction(pa, function()
				dB.Coins.Increment(1)
			end)
			local _, timedErr = Data.Transaction(pa, function()
				Data.OnCooldown(pb, KEY, 3600)
			end)

			local TAIL = "belongs to a different player than the one whose transaction is open, so it "
				.. "cannot be written from inside that transaction: "
			-- Both arrive wrapped in a traceback, so take the message line only:
			-- comparing the stacks would compare where the error was raised, which is
			-- the one thing that SHOULD differ between the two writers.
			local NEWLINE = string.char(10)
			local function tailOf(text: string?): string?
				if text == nil then
					return nil
				end
				local at = string.find(text, TAIL, 1, true)
				if at == nil then
					return nil
				end
				local stop = string.find(text, NEWLINE, at, true)
				return if stop then string.sub(text, at, stop - 1) else string.sub(text, at)
			end

			expect(tailOf(accessorErr)).to.be.ok()
			expect(tailOf(timedErr)).to.equal(tailOf(accessorErr))
			-- ...and each still names the thing that was refused, which is the half
			-- that legitimately differs: a dotted accessor path, or the raw store key.
			expect(has(accessorErr, '"Coins"')).to.equal(true)
			expect(has(timedErr, `"_Scribe.Timed.`)).to.equal(true)
			-- The escape route survives in both, because it is the same sentence.
			expect(has(timedErr, "durable outbox")).to.equal(true)
		end)

		it("CONTROL: your OWN cooldown inside your OWN transaction still arms, and commits", function()
			-- THE LIVENESS GATE for this block. Without it every refusal above is
			-- indistinguishable from "cooldowns stopped working inside transactions".
			local inside: boolean? = nil
			local ok = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				inside = (Data.OnCooldown(pa, KEY, 3600))
			end)
			expect(
				("ok=%s armedInside=%s onCd=%s A=%d"):format(
					tostring(ok),
					tostring(inside),
					tostring((Data.PeekCooldown(pa, KEY))),
					dA.Coins.Get()
				)
			).to.equal("ok=true armedInside=false onCd=true A=50")
		end)

		it("CONTROL: and it still rolls back IN LOCKSTEP when that transaction aborts", function()
			-- RecordRawWrite is what makes this work, and the refusal above sits
			-- directly in front of it: a guard placed a line later, or one that also
			-- fired on the owning tree, would take this with it. Both directions --
			-- a cooldown ARMED inside an aborted transaction must not survive, and one
			-- CLEARED inside it must come back.
			Data.OnCooldown(pa, "AlreadyArmed", 3600)
			expect((Data.PeekCooldown(pa, "AlreadyArmed"))).to.equal(true)

			local ok = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				Data.OnCooldown(pa, KEY, 3600)
				Data.ClearCooldown(pa, "AlreadyArmed")
				error("boom")
			end)
			expect(
				("ok=%s armedSurvived=%s clearedSurvived=%s A=%d"):format(
					tostring(ok),
					tostring((Data.PeekCooldown(pa, KEY))),
					tostring(not (Data.PeekCooldown(pa, "AlreadyArmed"))),
					dA.Coins.Get()
				)
			).to.equal("ok=false armedSurvived=false clearedSurvived=false A=100")
		end)

		it("CONTROL: READING another player's cooldown inside a transaction is still allowed", function()
			-- The rule is about writes. PeekCooldown never arms, and the whole point of
			-- a cross-player read is that a trade has to check the other side.
			Data.OnCooldown(pb, KEY, 3600)
			local seen: boolean? = nil
			local ok = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				seen = (Data.PeekCooldown(pb, KEY))
			end)
			expect(("ok=%s seen=%s"):format(tostring(ok), tostring(seen))).to.equal("ok=true seen=true")
		end)

		it("CONTROL: the refusal lifts with the transaction, on BOTH players", function()
			Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
			end)
			local errA = throwsAbout(function()
				Data.OnCooldown(pa, "AfterA", 3600)
			end)
			local errB = throwsAbout(function()
				Data.OnCooldown(pb, "AfterB", 3600)
			end)
			expect(
				("afterA=%s afterB=%s onA=%s onB=%s"):format(
					tostring(errA == nil),
					tostring(errB == nil),
					tostring((Data.PeekCooldown(pa, "AfterA"))),
					tostring((Data.PeekCooldown(pb, "AfterB")))
				)
			).to.equal("afterA=true afterB=true onA=true onB=true")
		end)
	end)

	describe("the refusal lasts exactly as long as the transaction", function()
		-- A guard that fails to lift is a worse outage than the bug: every
		-- cross-player write in the game would be dead from the first transaction
		-- onwards. Each of the three ways a transaction can end gets its own case,
		-- because they leave through three different paths in RunTransaction.
		local function writeBothAfter(): string
			local errA = throwsAbout(function()
				dA.Coins.Increment(1)
			end)
			local errB = throwsAbout(function()
				dB.Coins.Increment(1)
			end)
			return ("afterA=%s afterB=%s"):format(tostring(errA == nil), tostring(errB == nil))
		end

		it("lifts after a transaction commits", function()
			Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
			end)
			expect(writeBothAfter()).to.equal("afterA=true afterB=true")
		end)

		it("lifts after a transaction throws and rolls back", function()
			Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				error("boom")
			end)
			expect(writeBothAfter()).to.equal("afterA=true afterB=true")
		end)

		it("lifts after a transaction is refused for yielding", function()
			-- The yield path closes `fn`'s coroutine rather than returning through it,
			-- so it is the one exit that could plausibly skip a cleanup step.
			local ok, err = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				task.wait()
			end)
			expect(("ok=%s yield=%s %s"):format(tostring(ok), tostring(has(err, "must not yield")), writeBothAfter())).to.equal(
				"ok=false yield=true afterA=true afterB=true"
			)
		end)

		it("refuses a listener's cross-player write during the body and allows it during the drain", function()
			-- ONE listener, TWO fires, opposite answers -- and both are right.
			--
			-- The first fire is the debit itself, dispatched IMMEDIATELY while the
			-- transaction is open, so the listener is running inside it and its write to
			-- B is refused like any other: it could not be rolled back either, and a
			-- listener is exactly where an unnoticed cross-tree write hides.
			--
			-- The second is the rollback restore. Those fires are QUEUED and drained
			-- after the tree is whole again, and Node's own comment calls a write made
			-- during that drain "an ORDINARY post-rollback write: it lands, emits, and
			-- is not rolled back". So the guard must already be lifted by then, or that
			-- documented behaviour turns into a throw inside the fire queue.
			--
			-- The sequence is the assertion. Collapsing it to "did it write at some
			-- point" would read `true` whether the refusal happened or not.
			local outcomes = {}
			local disconnect = dA.Coins.Changed(function()
				local e = throwsAbout(function()
					dB.Coins.Increment(1)
				end)
				table.insert(outcomes, if e == nil then "wrote" elseif has(e, FOREIGN_TEXT) then "refused" else "other")
			end)

			local ok = Data.Transaction(pa, function()
				dA.Coins.Increment(-AMOUNT)
				error("boom")
			end)
			disconnect()

			local a, b = coins()
			expect(("ok=%s fires=%s A=%d B=%d"):format(tostring(ok), table.concat(outcomes, ","), a, b)).to.equal(
				"ok=false fires=refused,wrote A=100 B=1"
			)
		end)
	end)

	-- The other half of a trade recipe, and now the half the refusal points at: if
	-- the two players are not both here, the credit leg has to ride
	-- `Data.SendMessage` / `Data.OnMessage`, and that hop acknowledges the message
	-- on a schedule of its own.
	--
	-- UNCHANGED by the cross-player transaction fix -- nothing in this block opens a
	-- transaction. It DID change with F5, which is what it was written to catch.
	--
	-- WHAT IT USED TO RECORD. Persistence registered ONE handler and it read:
	--     ctx.Signals.OnMessage:Fire(entry.Player, message.Data)
	--     processed()
	-- with nothing between those two lines. `Signal.Fire` resumes each connection on
	-- a cached runner thread via `task.spawn`, so it runs the handler synchronously
	-- RIGHT UP TO the handler's first yield and then returns -- and it returns just
	-- the same when nothing is connected, and lets a raised error go to the
	-- scheduler. So every handler that yielded before its write had `processed()` run
	-- against it while the write did not exist yet; a handler with no connections had
	-- a message acked that nothing observed; and a handler that threw had one acked
	-- that nothing survived. The three lines measured then were
	--     stage=started queued=0 A=100
	--     queued=0 A=100
	--     reached=true queued=0 A=100
	--
	-- WHAT IT RECORDS NOW. The handler acknowledges only once a listener has RETURNED
	-- without raising (Signal.FireTracked). processed() flags the update, and
	-- ProfileStore removes it inside the same UpdateAsync that writes profile.Data, so
	-- the message and the data it produced retire together or not at all. An
	-- unacknowledged message is redelivered, which is a contract the docstrings and
	-- the lifecycle guide now state outright: Data.OnMessage is at-least-once.
	--
	-- WHAT THIS MEASURES AND WHAT IT DOES NOT: the observable below is the fake
	-- store's mailbox, and the fake DELETES a consumed message outright
	-- (FakeProfileStore.luau:339-347) and re-offers an unconsumed one on EVERY save,
	-- where real ProfileStore marks the update locked, sweeps it on a later save, and
	-- re-offers an unacked one once per SESSION (received_global_updates). So these
	-- cases pin the ORDERING -- the ack does not run ahead of the handler -- and they
	-- do NOT size either the durable loss window or the redelivery cadence. Those
	-- need the sim and are not measured here.
	describe("Data.OnMessage acknowledges only what a handler observed", function()
		local function mailboxLen(userId: number): number
			local key = `Default/{harness.Ctx.Persistence.KeyFor(userId)}`
			local mailbox = harness.Fake.Mailboxes[key]
			return if mailbox then #mailbox else 0
		end

		it("keeps the message while a yielding handler is parked with nothing written", function()
			local parked, stage = nil, "none"
			Data.OnMessage:Connect(function(_player, msg)
				stage = "started"
				parked = coroutine.running()
				coroutine.yield()
				dA.Coins.Increment(msg.Amount)
				stage = "wrote"
			end)

			expect(Data.SendMessage(1001, { Amount = AMOUNT })).to.equal(true)
			expect(mailboxLen(1001)).to.equal(1)

			-- Delivery happens inside a save, not on send.
			Data.Flush(pa)
			task.wait()

			expect(("stage=%s queued=%d A=%d"):format(stage, mailboxLen(1001), dA.Coins.Get())).to.equal(
				"stage=started queued=1 A=100"
			)

			-- The handler is still alive and still going to write -- and the message is
			-- still on the key, so the value it owes cannot go missing with it. This read
			-- queued=0 before F5: the acknowledgement was spent and only this server's
			-- RAM was holding the pair together.
			task.spawn(parked)
			task.wait()
			expect(("stage=%s A=%d"):format(stage, dA.Coins.Get())).to.equal("stage=wrote A=150")
		end)

		it("has already written by the same point when the handler does not yield", function()
			-- THE CONTROL. Without it, "queued=0 and nothing written" is equally well
			-- explained by the harness draining the mailbox before running anything.
			local stage = "none"
			Data.OnMessage:Connect(function(_player, msg)
				dA.Coins.Increment(msg.Amount)
				stage = "wrote"
			end)

			expect(Data.SendMessage(1001, { Amount = AMOUNT })).to.equal(true)
			Data.Flush(pa)
			task.wait()

			expect(("stage=%s queued=%d A=%d"):format(stage, mailboxLen(1001), dA.Coins.Get())).to.equal(
				"stage=wrote queued=0 A=150"
			)
		end)

		it("keeps a message with no listener connected at all", function()
			-- The cheapest of the three: no yield, no crash, no timing. The handler used
			-- to call `processed()` for any `ScribeMessage`-tagged payload whether or not
			-- `Fire` had anything to fire at, so a game that sent before it connected --
			-- or that dropped its connection on a code path -- consumed the message
			-- anyway. Now nothing observed it, so nothing is retired and it comes back.
			-- MESSAGE_NO_LISTENER records it; that is asserted in
			-- MessageAckDurability.spec, which owns the log side of this arm.
			expect(Data.SendMessage(1001, { Amount = AMOUNT })).to.equal(true)
			expect(mailboxLen(1001)).to.equal(1)

			Data.Flush(pa)
			task.wait()

			expect(("queued=%d A=%d"):format(mailboxLen(1001), dA.Coins.Get())).to.equal("queued=1 A=100")
		end)

		it("keeps a message whose handler threw before writing anything", function()
			-- The third destruction mode, and the one that was nearly left unmeasured
			-- on a reason that does not apply. An earlier draft of this file recorded
			-- the throwing variant as untestable because `Signal.Fire` task.spawns
			-- onto the free runner thread and the SIM harness routes that to
			-- Scheduler.Resume, which re-raises and kills the run. True of the sim --
			-- and irrelevant here, because this whole describe block runs on TestCtx,
			-- where the error surfaces and the suite continues, exactly as Roblox does.
			--
			-- `processed()` used to sit outside any pcall of the handler, so it ran
			-- whether the handler returned, yielded, or blew up. FireTracked pcalls each
			-- listener and reports the failure, so the ack is withheld and the error
			-- surfaces as MESSAGE_HANDLER_ERROR instead of reaching the scheduler.
			local reached = false
			Data.OnMessage:Connect(function()
				reached = true
				error("handler blew up before writing the credit")
			end)

			expect(Data.SendMessage(1001, { Amount = AMOUNT })).to.equal(true)
			expect(mailboxLen(1001)).to.equal(1)

			Data.Flush(pa)
			task.wait()

			expect(("reached=%s queued=%d A=%d"):format(tostring(reached), mailboxLen(1001), dA.Coins.Get())).to.equal(
				"reached=true queued=1 A=100"
			)
		end)
	end)
end
