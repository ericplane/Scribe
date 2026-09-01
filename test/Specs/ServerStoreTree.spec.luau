--!nonstrict
-- The server-owned store at runtime.
--
-- One tree for the whole server, created with the bundle and destroyed with it. Nothing
-- in it persists, nothing about it is per player, and its writes reach every ready
-- client as ordinary Diff frames.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local template = { Coins = Scribe.Int(0, { Min = 0 }) }
	local store = {
		Wave = Scribe.Int(1, { Min = 0 }),
		BossHp = Scribe.Int(100, { Min = 0 }),
		Seed = Scribe.ServerOnly(0),
	}

	local function make(extra)
		local options = { ServerStore = store }
		for key, value in extra or {} do
			options[key] = value
		end
		return TestCtx.make({ Template = template, Options = options, AutoPump = true })
	end

	describe("the tree itself", function()
		itRunning("is writable with no players joined at all", function()
			local harness = make()
			harness.Data.ServerStore.Wave.Increment(1)
			local seen = harness.Data.ServerStore.Wave.Get()
			harness.Cleanup()
			expect(seen).to.equal(2)
		end)

		itRunning("seeds from the declared defaults", function()
			local harness = make()
			local seen = `{harness.Data.ServerStore.Wave.Get()},{harness.Data.ServerStore.BossHp.Get()}`
			harness.Cleanup()
			expect(seen).to.equal("1,100")
		end)

		itRunning("enforces declared bounds like any other tree", function()
			local harness = make({ BoundsPolicy = "Clamp" })
			harness.Data.ServerStore.BossHp.Decrement(500)
			local seen = harness.Data.ServerStore.BossHp.Get()
			harness.Cleanup()
			expect(seen).to.equal(0)
		end)

		itRunning("is ONE store, not one per player", function()
			local harness = make()
			harness.Join(60001)
			harness.Join(60002)
			harness.Data.ServerStore.Wave.Set(7)
			-- Two players, one value. A per-player store would give each their own.
			local seen = harness.Data.ServerStore.Wave.Get()
			harness.Cleanup()
			expect(seen).to.equal(7)
		end)
	end)

	describe("it is not persisted", function()
		itRunning("keeps store roots out of the profile payload", function()
			local harness = make()
			local _player, entry = harness.Join(60010)
			harness.Data.ServerStore.Wave.Set(9)
			local keys = {}
			for key in entry.LiveData do
				table.insert(keys, key)
			end
			table.sort(keys)
			harness.Cleanup()
			-- Coins and the reserved root; never Wave.
			expect(table.concat(keys, ",")).to.equal("Coins,_Scribe")
		end)

		itRunning("keeps store roots out of the per-player session store", function()
			local harness = make()
			local _player, entry = harness.Join(60011)
			local found = entry.SessionStore.Wave
			harness.Cleanup()
			expect(found).to.equal(nil)
		end)

		itRunning("does not mark a profile dirty when the store is written", function()
			local harness = make()
			local _player, entry = harness.Join(60012)
			harness.Data.Flush(entry.Player, { Force = true })
			local before = entry.SaveInfo.Dirty
			harness.Data.ServerStore.Wave.Increment(1)
			local after = entry.SaveInfo.Dirty
			harness.Cleanup()
			expect(`before={tostring(before)} after={tostring(after)}`).to.equal("before=false after=false")
		end)
	end)

	describe("it reaches every client", function()
		itRunning("puts store roots in the Init snapshot a joiner receives", function()
			local harness = make()
			harness.Data.ServerStore.Wave.Set(5)
			local player = harness.Join(60020)
			harness.Transport.LocalPlayer = player
			-- Client.new sends its own Hello, so it has to exist before the Init is answered.
			local clientData = Client.new(harness.Options, harness.Compiled)
			local seen = clientData.ServerStore.Wave.Get()
			harness.Cleanup()
			-- Riding the Init is what lets every recovery path repair the store mirror.
			expect(seen).to.equal(5)
		end)

		itRunning("delivers a later write as a Diff", function()
			local harness = make()
			local player = harness.Join(60021)
			harness.Transport.LocalPlayer = player
			-- Client.new sends its own Hello, so it has to exist before the Init is answered.
			local clientData = Client.new(harness.Options, harness.Compiled)
			harness.Data.ServerStore.BossHp.Set(42)
			harness.StepUntil(function()
				return clientData.ServerStore.BossHp.Get() == 42
			end)
			local seen = clientData.ServerStore.BossHp.Get()
			harness.Cleanup()
			expect(seen).to.equal(42)
		end)

		itRunning("fires a client listener on a store write", function()
			local harness = make()
			local player = harness.Join(60022)
			harness.Transport.LocalPlayer = player
			-- Client.new sends its own Hello, so it has to exist before the Init is answered.
			local clientData = Client.new(harness.Options, harness.Compiled)
			local seen = {}
			clientData.ServerStore.Wave.Changed(function(new)
				table.insert(seen, new)
			end)
			harness.Data.ServerStore.Wave.Set(3)
			harness.StepUntil(function()
				return #seen > 0
			end)
			local got = table.concat(seen, ",")
			harness.Cleanup()
			expect(got).to.equal("3")
		end)

		itRunning("NEVER sends a ServerOnly store root", function()
			local harness = make()
			local player = harness.Join(60023)
			harness.Transport.LocalPlayer = player
			-- Client.new sends its own Hello, so it has to exist before the Init is answered.
			local clientData = Client.new(harness.Options, harness.Compiled)
			harness.Data.ServerStore.Seed.Set(1234)
			harness.StepUntil(function()
				return false
			end, 4)
			local onServer = harness.Data.ServerStore.Seed.Get()
			local onClient = clientData.ServerStore.Seed.Get()
			harness.Cleanup()
			expect(`server={onServer} client={tostring(onClient)}`).to.equal("server=1234 client=nil")
		end)
	end)

	describe("transactions do not reach it", function()
		-- A rollback restores one player's tree. The store is not saved to any key and is
		-- not that tree, so a store write made inside a transaction would outlive an abort
		-- and leave the two halves disagreeing.
		itRunning("REFUSES a store write from inside a player transaction", function()
			local harness = make()
			local player, _entry, data = harness.Join(60030)
			data.Coins.Set(10)
			local ok, err = harness.Data.Transaction(player, function()
				data.Coins.Increment(5)
				harness.Data.ServerStore.Wave.Set(99)
			end)
			local coins = data.Coins.Get()
			local wave = harness.Data.ServerStore.Wave.Get()
			harness.Cleanup()
			-- Neither half landed: the store write was refused and the transaction that
			-- contained it rolled the player back.
			expect(`ok={tostring(ok)} refused={tostring(err ~= nil)} coins={coins} wave={wave}`).to.equal(
				"ok=false refused=true coins=10 wave=1"
			)
		end)

		itRunning("says it is the store, not that it is another player", function()
			local harness = make()
			local player = harness.Join(60031)
			local _ok, err = harness.Data.Transaction(player, function()
				harness.Data.ServerStore.Wave.Set(99)
			end)
			local text = tostring(err)
			harness.Cleanup()
			-- The cross-player sentence sends you to the durable outbox, which the store
			-- has no use for. Naming the store is the whole point of the second wording.
			expect(
				`store={tostring(string.find(text, "ServerStore", 1, true) ~= nil)}`
					.. ` foreign={tostring(string.find(text, "different player", 1, true) ~= nil)}`
			).to.equal("store=true foreign=false")
		end)

		itRunning("CONTROL: the same writes commit when the store is written outside", function()
			local harness = make()
			local player, _entry, data = harness.Join(60032)
			data.Coins.Set(10)
			harness.Data.ServerStore.Wave.Set(99)
			local ok = harness.Data.Transaction(player, function()
				data.Coins.Increment(5)
			end)
			local seen = `ok={tostring(ok)} coins={data.Coins.Get()} wave={harness.Data.ServerStore.Wave.Get()}`
			harness.Cleanup()
			expect(seen).to.equal("ok=true coins=15 wave=99")
		end)
	end)

	describe("lifecycle", function()
		itRunning("is absent when the bundle declares no ServerStore", function()
			local harness = TestCtx.make({ Template = template })
			local present = harness.Data.ServerStore
			harness.Cleanup()
			expect(present).to.equal(nil)
		end)

		itRunning("costs a storeless bundle not even a call per frame", function()
			-- The gate in flushFrame, not the empty-queue early return inside the drain.
			-- Counted on both sides, because a zero that is zero on BOTH is a spy that
			-- was never wired rather than a cost that was removed.
			local function drainCalls(harness): number
				local calls = 0
				local real = harness.Ctx.Replication.FlushStoreQueue
				harness.Ctx.Replication.FlushStoreQueue = function(...)
					calls += 1
					return real(...)
				end
				harness.Join(60040)
				for _ = 1, 5 do
					harness.Step()
				end
				return calls
			end

			local without = TestCtx.make({ Template = template })
			local none = drainCalls(without)
			without.Cleanup()

			local with = TestCtx.make({ Template = template, Options = { ServerStore = store } })
			local some = drainCalls(with)
			with.Cleanup()

			expect(`without={none} with={tostring(some > 0)}`).to.equal("without=0 with=true")
		end)

		itRunning("is destroyed by Data.Stop, so its listeners go with the bundle", function()
			local harness = make()
			local fired = 0
			harness.Data.ServerStore.Wave.Changed(function()
				fired += 1
			end)
			harness.Data.ServerStore.Wave.Set(2)
			local before = fired
			harness.Data.Stop()
			local ok = pcall(function()
				harness.Data.ServerStore.Wave.Set(3)
			end)
			harness.Cleanup()
			-- The tree is dead: a write raises rather than firing into a stopped bundle.
			expect(`before={before} afterStopRaised={tostring(not ok)}`).to.equal("before=1 afterStopRaised=true")
		end)
	end)
end
