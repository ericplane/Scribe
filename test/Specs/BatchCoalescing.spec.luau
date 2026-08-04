--!nonstrict
-- Server.Batch promises "a single replication flush and one Changed pass". The
-- flush half always worked; the Changed half did not, so four writes to four
-- fields of one container fired that container's listener four times, on the
-- server AND on the client, which unpacked the single batched frame back into one
-- fire per op.
--
-- The split that makes coalescing truthful: a container's Changed carries STATE
-- (old is the same reference as new, so a batch can lose nothing) and coalesces to
-- one fire. OnChildChanged carries a TRANSITION and therefore never coalesces, the
-- same rule leaf Changed, OnInsert, OnRemove, OnKeyAdded and OnKeyRemoved follow.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local function makeHarness()
		return TestCtx.make({
			Template = { State = { A = 0, B = 0, C = 0, D = 0 } },
		})
	end

	it("collapses a batch's ancestor fires into one", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(95001)

		local fires = 0
		-- Capture the ARGUMENTS, not just the count. Asserting only on a counter left
		-- the payload untested: firing (nil, nil) kept the whole suite green.
		local seenNew, seenOld, sameRef
		data.State.Changed(function(new, old)
			fires += 1
			seenNew, seenOld = new, old
			sameRef = rawequal(new, old)
		end)
		local leafFires = 0
		data.State.A.Changed(function()
			leafFires += 1
		end)

		harness.Data.Batch(_player, function()
			data.State.A.Set(1)
			data.State.B.Set(2)
			data.State.C.Set(3)
			data.State.D.Set(4)
			data.State.A.Set(5)
		end)

		expect(fires).to.equal(1)
		-- Leaves report EVERY write, including the repeat, because each is a real
		-- transition with its own old and new value.
		expect(leafFires).to.equal(2)
		-- The one fire carries the batch's END state, not an intermediate one, and
		-- old is the same reference as new because a container is never snapshotted.
		expect(data.State.D.Get()).to.equal(4)
		expect(type(seenNew)).to.equal("table")
		expect(seenNew.A).to.equal(5)
		expect(seenNew.D).to.equal(4)
		expect(sameRef).to.equal(true)
		expect(seenOld.A).to.equal(5)

		harness.Cleanup()
	end)

	it("reports every child transition through OnChildChanged, uncoalesced", function()
		local harness = makeHarness()
		local player, _entry, data = harness.Join(95002)

		local seen, changedFires = {}, 0
		data.State.OnChildChanged(function(key, value)
			table.insert(seen, `{key}={value}`)
		end)
		data.State.Changed(function()
			changedFires += 1
		end)

		harness.Data.Batch(player, function()
			data.State.A.Set(1)
			data.State.B.Set(2)
			data.State.A.Set(5)
		end)

		-- Three writes, three transitions, INCLUDING the repeat on A: a transition
		-- event that deduplicated would be lying about what happened.
		expect(#seen).to.equal(3)
		expect(table.concat(seen, " ")).to.equal("A=1 B=2 A=5")
		-- And still exactly one state fire for the whole batch.
		expect(changedFires).to.equal(1)

		harness.Cleanup()
	end)

	it("reports a DictOf key whose value changed, which no other event covers", function()
		-- OnKeyAdded and OnKeyRemoved fire on a key appearing or disappearing, never
		-- on one changing, and a leaf listener needs a key name a dictionary user
		-- does not have up front. This is the only signal.
		local harness = TestCtx.make({ Template = { Inv = Scribe.DictOf(Scribe.Int(0)) } })
		local player, _entry, data = harness.Join(95003)
		data.Inv.Sword.Set(1)
		data.Inv.Shield.Set(1)
		data.Inv.Potion.Set(1)

		local added, removed = 0, 0
		data.Inv.OnKeyAdded(function()
			added += 1
		end)
		data.Inv.OnKeyRemoved(function()
			removed += 1
		end)
		local seen, fires = {}, 0
		data.Inv.OnChildChanged(function(key, value)
			table.insert(seen, `{key}={value}`)
		end)
		data.Inv.Changed(function()
			fires += 1
		end)

		harness.Data.Batch(player, function()
			data.Inv.Sword.Set(50)
			data.Inv.Shield.Set(60)
			data.Inv.Potion.Set(70)
		end)

		expect(added).to.equal(0)
		expect(removed).to.equal(0)
		table.sort(seen)
		expect(table.concat(seen, " ")).to.equal("Potion=70 Shield=60 Sword=50")
		expect(fires).to.equal(1)

		harness.Cleanup()
	end)

	it("carries a real old value for a leaf child, and old == new for a container child", function()
		-- OnChildChanged is the transition half, so it has to report both sides. It
		-- can only do that honestly where a prior value exists: the deepest
		-- ancestor's child is the leaf that actually changed. Every shallower
		-- ancestor's child is a container mutated in place, so old and new are one
		-- reference, exactly as that container's own Changed reports.
		local harness = TestCtx.make({ Template = { State = { Inner = { A = 0 } } } })
		local _player, _entry, data = harness.Join(95011)
		data.State.Inner.A.Set(7)

		local leafNew, leafOld, sameRef
		data.State.Inner.OnChildChanged(function(_key, new, prev)
			leafNew, leafOld = new, prev
		end)
		data.State.OnChildChanged(function(_key, new, prev)
			sameRef = new == prev
		end)

		data.State.Inner.A.Set(9)
		expect(leafNew).to.equal(9)
		expect(leafOld).to.equal(7)
		expect(sameRef).to.equal(true)

		harness.Cleanup()
	end)

	it("reports a nil old on a key being added and a nil new on one removed", function()
		local harness = TestCtx.make({ Template = { Inv = Scribe.DictOf(Scribe.Int(0)) } })
		local _player, _entry, data = harness.Join(95012)

		local events = {}
		data.Inv.OnChildChanged(function(key, new, prev)
			table.insert(events, `{key}:{tostring(prev)}->{tostring(new)}`)
		end)

		data.Inv.Sword.Set(5) -- appears
		data.Inv.Sword.Set(8) -- changes
		data.Inv.Sword.Set(nil) -- removed

		expect(table.concat(events, " ")).to.equal("Sword:nil->5 Sword:5->8 Sword:8->nil")

		harness.Cleanup()
	end)

	it("gives every ancestor its OWN immediate child, not the leaf that changed", function()
		local harness = TestCtx.make({ Template = { State = { Inner = { A = 0 } } } })
		local player, _entry, data = harness.Join(95004)

		local innerSaw, stateSaw, rootSaw
		data.State.Inner.OnChildChanged(function(key)
			innerSaw = key
		end)
		data.State.OnChildChanged(function(key)
			stateSaw = key
		end)
		data.OnChildChanged(function(key)
			rootSaw = key
		end)

		harness.Data.Batch(player, function()
			data.State.Inner.A.Set(1)
		end)

		expect(innerSaw).to.equal("A")
		expect(stateSaw).to.equal("Inner")
		expect(rootSaw).to.equal("State")

		harness.Cleanup()
	end)

	it("refuses a container Changed listener still written for the removed key argument", function()
		-- Coalescing would hand this listener nil forever, so `if key == "A"` would
		-- quietly stop matching in a shipped game. Refuse it at connect instead.
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(95005)

		expect(function()
			data.State.Changed(function(_new, _old, _key) end)
		end).to.throw()
		-- The root is a container too.
		expect(function()
			data.Changed(function(_new, _old, _key) end)
		end).to.throw()
		-- Two parameters is the supported shape, and fewer is always fine.
		expect(function()
			data.State.Changed(function(_new, _old) end)
		end).never.to.throw()
		expect(function()
			data.State.Changed(function() end)
		end).never.to.throw()
		-- A LEAF listener is untouched: its signature did not change.
		expect(function()
			data.State.A.Changed(function(_new, _old) end)
		end).never.to.throw()

		harness.Cleanup()
	end)

	it("delivers a container's child transitions before its coalesced state fire", function()
		-- The accumulate-then-drain shape depends on this ordering: a listener that
		-- collects keys from OnChildChanged and acts on them in Changed only works
		-- if every transition has landed by then.
		local harness = makeHarness()
		local player, _entry, data = harness.Join(95009)

		local order = {}
		data.State.OnChildChanged(function(key)
			table.insert(order, `child:{key}`)
		end)
		data.State.Changed(function()
			table.insert(order, "state")
		end)

		harness.Data.Batch(player, function()
			data.State.A.Set(1)
			data.State.B.Set(2)
		end)

		expect(table.concat(order, " ")).to.equal("child:A child:B state")

		-- Batched, the ordering is structural: Changed is deferred to the flush, so
		-- it cannot arrive early. Unbatched is where the order is actually decided,
		-- and it has to match, or the same listener behaves differently depending on
		-- whether the caller happened to use Batch.
		table.clear(order)
		data.State.A.Set(9)
		expect(table.concat(order, " ")).to.equal("child:A state")

		harness.Cleanup()
	end)

	it("keeps Observe a pure state callback, with no key arguments", function()
		-- Observe answers "what is the state", including an immediate call on
		-- connect, where there is no transition to describe. Handing it a key would
		-- make it nil on that first call, so the natural `for _, k in keys do` would
		-- silently render nothing at startup. Changed and OnChildChanged are where
		-- transitions live.
		local harness = makeHarness()
		local player, _entry, data = harness.Join(95010)

		local calls, extraArgs = 0, -1
		data.State.Observe(function(_value, ...)
			calls += 1
			extraArgs = select("#", ...)
		end)
		expect(calls).to.equal(1) -- fired immediately on connect
		expect(extraArgs).to.equal(0)

		harness.Data.Batch(player, function()
			data.State.A.Set(1)
			data.State.B.Set(2)
		end)

		-- One call for the whole batch, still with nothing but the value.
		expect(calls).to.equal(2)
		expect(extraArgs).to.equal(0)

		harness.Cleanup()
	end)

	it("coalesces a nested batch into the outermost one", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(95003)

		local fires = 0
		data.State.Changed(function()
			fires += 1
		end)

		harness.Data.Batch(_player, function()
			data.State.A.Set(1)
			harness.Data.Batch(_player, function()
				data.State.B.Set(2)
			end)
			data.State.C.Set(3)
		end)

		-- The inner batch must not flush early: depth returns to 1, not 0.
		expect(fires).to.equal(1)

		harness.Cleanup()
	end)

	it("fires coalesced ancestors deepest first, as an unbatched write does", function()
		local harness = TestCtx.make({ Template = { State = { Inner = { A = 0, B = 0 } } } })
		local _player, _entry, data = harness.Join(95004)

		local order = {}
		data.Changed(function()
			table.insert(order, "root")
		end)
		data.State.Changed(function()
			table.insert(order, "State")
		end)
		data.State.Inner.Changed(function()
			table.insert(order, "Inner")
		end)

		harness.Data.Batch(_player, function()
			data.State.Inner.A.Set(1)
			data.State.Inner.B.Set(2)
		end)

		expect(#order).to.equal(3)
		expect(order[1]).to.equal("Inner")
		expect(order[2]).to.equal("State")
		expect(order[3]).to.equal("root")

		harness.Cleanup()
	end)

	it("still fires per write outside a batch", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(95005)

		local fires = 0
		data.State.Changed(function()
			fires += 1
		end)

		data.State.A.Set(1)
		data.State.B.Set(2)

		expect(fires).to.equal(2)

		harness.Cleanup()
	end)

	it("coalesces a committed transaction and discards a rolled-back one", function()
		local harness = makeHarness()
		local player, _entry, data = harness.Join(95006)

		local fires = 0
		data.State.Changed(function()
			fires += 1
		end)

		local ok = harness.Data.Transaction(player, function()
			data.State.A.Set(1)
			data.State.B.Set(2)
		end)
		expect(ok).to.equal(true)
		expect(fires).to.equal(1)

		-- A rollback must not deliver the fires its writes queued: those writes did
		-- not happen. The restores fire their own Changed with the pre-transaction
		-- values, which is existing documented behavior.
		--
		-- The listener has to be registered BEFORE the transaction, or it cannot
		-- observe the rollback's fires at all and the assertion below is vacuous.
		fires = 0
		local sawRolledBackValue = false
		data.State.Changed(function(new)
			if new.C == 99 then
				sawRolledBackValue = true
			end
		end)

		local rolledBack = harness.Data.Transaction(player, function()
			data.State.C.Set(99)
			error("boom")
		end)
		expect(rolledBack).to.equal(false)
		expect(data.State.C.Get()).to.equal(0)
		-- Flushing rather than discarding would read the store while C is still 99,
		-- since the deferred fires run before the restores do.
		expect(sawRolledBackValue).to.equal(false)

		harness.Cleanup()
	end)

	it("keeps the enclosing batch's fires when a nested transaction rolls back", function()
		-- The deferred queue is tree-wide but the discard was not: a rollback cleared
		-- the whole queue, taking the OUTER batch's fires with it. The batch's writes
		-- still landed and still replicated, so the client mirror fired a container
		-- Changed the server never did.
		local harness = TestCtx.make({
			Template = { State = { A = 0, B = 0 }, Other = { C = 0 } },
		})
		local player, _entry, data = harness.Join(95010)

		local stateFires, otherFires = 0, 0
		data.State.Changed(function()
			stateFires += 1
		end)
		data.Other.Changed(function()
			otherFires += 1
		end)

		harness.Data.Batch(player, function()
			data.State.A.Set(1)
			data.State.B.Set(2)
			harness.Data.Transaction(player, function()
				data.Other.C.Set(9)
				error("boom")
			end)
		end)

		-- The batch's own writes happened and are reported exactly once.
		expect(data.State.A.Get()).to.equal(1)
		expect(data.State.B.Get()).to.equal(2)
		expect(stateFires).to.equal(1)
		-- The rolled-back subtree is back to its old value. Its restore fires its own
		-- Changed, which is existing documented behavior.
		expect(data.Other.C.Get()).to.equal(0)
		expect(otherFires).to.equal(1)

		harness.Cleanup()
	end)

	it("does not leak the batch depth when a yield kills a nested batch", function()
		-- A transaction runs its function on its own coroutine and closes it on a
		-- yield. Luau does not unwind a closed coroutine, so a Data.Batch opened
		-- inside never runs its matching decrement. Decrementing only our own left
		-- the tree permanently above zero, and the deferred queue only ever flushes
		-- AT zero, so every container Changed and Observe on that player went
		-- silently dead for the rest of the session while leaf writes kept working.
		local harness = TestCtx.make({
			Template = { State = { A = 0, B = 0 }, Arr = Scribe.ArrayOf(Scribe.Int(0)) },
		})
		local player, entry, data = harness.Join(95013)

		local stateFires, observeFires, leafFires, arrFires = 0, 0, 0, 0
		data.State.Changed(function()
			stateFires += 1
		end)
		data.State.Observe(function()
			observeFires += 1
		end)
		data.State.A.Changed(function()
			leafFires += 1
		end)
		data.Arr.Changed(function()
			arrFires += 1
		end)
		observeFires = 0 -- Observe fires once on connect

		local ok = harness.Data.Transaction(player, function()
			harness.Data.Batch(player, function()
				data.State.A.Set(1)
				task.wait()
				data.State.B.Set(2)
			end)
		end)
		expect(ok).to.equal(false) -- the yield was refused, which is the trigger
		expect(entry.Tree._batchDepth).to.equal(0)

		-- The rollback's own restores fire, so measure from here.
		stateFires, observeFires, leafFires, arrFires = 0, 0, 0, 0

		-- Everything below is dead on a leaked depth.
		data.State.A.Set(50)
		expect(leafFires > 0).to.equal(true) -- the control: leaf writes never broke
		expect(stateFires).to.equal(1)
		expect(observeFires).to.equal(1)

		harness.Data.Batch(player, function()
			data.State.B.Set(9)
		end)
		expect(stateFires).to.equal(2)

		data.Arr.Insert(1)
		data.Arr.Insert(2)
		expect(arrFires).to.equal(2)

		harness.Cleanup()
	end)

	it("restores the enclosing batch's depth when a nested transaction yields", function()
		local harness = makeHarness()
		local player, entry, data = harness.Join(95014)
		local fires = 0
		data.State.Changed(function()
			fires += 1
		end)

		harness.Data.Batch(player, function()
			data.State.A.Set(1)
			harness.Data.Transaction(player, function()
				harness.Data.Batch(player, function()
					task.wait()
				end)
			end)
			data.State.B.Set(2)
		end)

		expect(entry.Tree._batchDepth).to.equal(0)
		-- The enclosing batch still delivers exactly one coalesced fire.
		expect(fires).to.equal(1)

		harness.Cleanup()
	end)

	it("coalesces Insert, Remove and Clear inside a batch", function()
		-- These mutate the container's OWN path rather than a child's, so they never
		-- reached the ancestor defer queue and fired once per call while every other
		-- container in the same batch fired once. Their (value, value) shape is the
		-- same state fire fireAncestors already defers, and the per-entry transitions
		-- ride OnInsert/OnRemove, so nothing is lost by collapsing them.
		local harness = TestCtx.make({
			Template = { Arr = Scribe.ArrayOf(Scribe.Int(0)), Inv = Scribe.DictOf(Scribe.Int(0)) },
		})
		local player, _entry, data = harness.Join(95011)

		local arrFires, invFires, inserts = 0, 0, 0
		data.Arr.Changed(function()
			arrFires += 1
		end)
		data.Arr.OnInsert(function()
			inserts += 1
		end)
		data.Inv.Changed(function()
			invFires += 1
		end)

		harness.Data.Batch(player, function()
			data.Arr.Insert(1)
			data.Arr.Insert(2)
			data.Arr.Insert(3)
			data.Inv.Wood.Set(1) -- control: a child-path write already coalesced
			data.Inv.Stone.Set(2)
		end)
		expect(arrFires).to.equal(1)
		expect(invFires).to.equal(1)
		-- The one fire carries the batch's END state, and the transitions are intact.
		expect(data.Arr.Count()).to.equal(3)
		expect(inserts).to.equal(3)

		-- Mixed Remove and Clear collapse the same way.
		arrFires = 0
		harness.Data.Batch(player, function()
			data.Arr.Remove()
			data.Arr.Insert(4)
			data.Arr.Clear()
		end)
		expect(arrFires).to.equal(1)
		expect(data.Arr.Count()).to.equal(0)

		-- Outside a batch each one still fires per write.
		arrFires = 0
		data.Arr.Insert(5)
		data.Arr.Insert(6)
		expect(arrFires).to.equal(2)

		harness.Cleanup()
	end)

	it("guards a container listener under an untyped subtree too", function()
		-- Template.ChildSchema synthesizes an `any` pseudo-node for an undeclared key
		-- rather than returning nil, so the connect-time check classified everything
		-- below an untyped `{}` as a leaf. Those listeners connected fine and were
		-- handed key = nil forever, which is the silent break the guard exists to
		-- stop, on the shapes least likely to be caught by types.
		local harness = TestCtx.make({
			Template = { Inv = {}, Quests = {} :: { any }, State = { A = 0 } },
		})
		local _player, _entry, data = harness.Join(95012)
		data.Inv.Bag.A.Set(1)
		data.Quests.Insert({ Step = 1 })

		expect(function()
			data.Inv.Bag.Changed(function(_new, _old, _key) end)
		end).to.throw()
		expect(function()
			data.Quests[1].Changed(function(_new, _old, _key) end)
		end).to.throw()
		-- A leaf under the same untyped subtree keeps the two-parameter shape.
		expect(function()
			data.Inv.Bag.A.Changed(function(_new, _old) end)
		end).never.to.throw()

		harness.Cleanup()
	end)

	itRunning("delivers one client fire for a batched frame, not one per op", function()
		local harness = TestCtx.make({
			AutoPump = true,
			Template = { State = { A = 0, B = 0, C = 0, D = 0 } },
		})
		local player, entry, data = harness.Join(95007)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()

		local fires, observes = 0, 0
		client.State.Changed(function()
			fires += 1
		end)
		client.State.Observe(function()
			observes += 1
		end)
		observes = 0 -- Observe calls back once on connect

		harness.Data.Batch(player, function()
			data.State.A.Set(1)
			data.State.B.Set(2)
			data.State.C.Set(3)
			data.State.D.Set(4)
		end)
		task.wait()

		-- The server coalesced these into one frame; the client must not unpack
		-- that frame back into four fires.
		expect(fires).to.equal(1)
		expect(observes).to.equal(1)
		-- Every value still landed.
		expect(client.State.A.Get()).to.equal(1)
		expect(client.State.D.Get()).to.equal(4)

		-- A single write still delivers exactly one fire.
		fires = 0
		data.State.A.Set(50)
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()
		expect(fires).to.equal(1)

		harness.Cleanup()
	end)
end
