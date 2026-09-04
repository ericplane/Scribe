--!nonstrict
-- The client's answer for a product's state: the server's strings, computed from the
-- mirror and the local player's own policy read, so a button can grey with no round trip.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Client = require(Root.Scribe.Client)
	local Clock = require(Root.Scribe.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local LOOT_ID, PET_ID, BAG_ID, VIP_ID = 5001, 5002, 5003, 777

	local function settle(frames: number?)
		for _ = 1, frames or 6 do
			task.wait()
		end
	end

	--- One mode for every caller: true, false, "error", "hang". Set changes it for the
	--- next read; Release lets parked reads finish under the current mode.
	local function fakePolicy(initial)
		local mode = initial
		local parked = {}
		local calls = 0
		local function fake()
			calls += 1
			if mode == "error" then
				error("policy: unavailable")
			elseif mode == "hang" then
				table.insert(parked, coroutine.running())
				coroutine.yield()
			end
			return { ArePaidRandomItemsRestricted = mode == true }
		end
		return fake,
			{
				Calls = function()
					return calls
				end,
				Set = function(next)
					mode = next
				end,
				Release = function()
					local threads = parked
					parked = {}
					for _, thread in threads do
						task.spawn(thread)
					end
				end,
			}
	end

	local function makeLoopback(initial, autoPump: boolean?)
		local fake, control = fakePolicy(initial)
		local harness = TestCtx.make({
			AutoPump = autoPump ~= false,
			Options = {
				Products = {
					LootBox = { Id = LOOT_ID, PaidRandom = true },
					MysteryPet = { Id = PET_ID, PaidRandom = true, Grants = "Pet" },
					CoinBag = { Id = BAG_ID },
				},
				Passes = { VIPPass = { Id = VIP_ID } },
				GetPolicyInfoAsync = fake,
				UserOwnsGamePassAsync = function()
					return false
				end,
				Banner = false,
			},
		})
		local player, entry = harness.Join()
		harness.Transport.LocalPlayer = player
		Client.SetLocalPlayerProbe(function()
			return player
		end)
		local client = Client.new(harness.Options, harness.Compiled)
		return harness, player, entry, client, control
	end

	local function done(harness, client)
		client.Stop()
		harness.Cleanup()
	end

	local function logCount(code: string): number
		return #Scribe.GetRecentLogs({ Code = code, Limit = 100 })
	end

	it("answers restricted, purchasable and pending from the local policy", function()
		local harness, _, _, client, control = makeLoopback(true)
		client.GetProductState("LootBox")
		settle()
		local restricted = client.GetProductState("LootBox")
		done(harness, client)

		local harness2, _, _, client2 = makeLoopback(false)
		client2.GetProductState("LootBox")
		settle()
		local purchasable = client2.GetProductState("LootBox")
		local bag = client2.GetProductState("CoinBag")
		done(harness2, client2)

		local harness3, _, _, client3, control3 = makeLoopback("hang")
		client3.GetProductState("LootBox")
		settle()
		local pending = client3.GetProductState("LootBox")
		local bagWhileHanging = client3.GetProductState("CoinBag")
		control3.Set(false)
		control3.Release()
		settle()
		local landed = client3.GetProductState("LootBox")
		done(harness3, client3)
		control.Set(false)
		expect(`{restricted} {purchasable} {bag} {pending} {bagWhileHanging} {landed}`).to.equal(
			"paid-random-restricted purchasable purchasable policy-pending purchasable purchasable"
		)
	end)

	it("stays pending after the read fails, and logs POLICY_READ_FAIL once", function()
		local wait = Clock.Wait
		Clock.Install({
			Wait = function()
				return task.wait()
			end,
		})
		local harness, _, _, client, control = makeLoopback(false)
		settle()
		-- Only the client's read fails: the server's landed at join.
		control.Set("error")
		local before = logCount("POLICY_READ_FAIL")
		client.GetProductState("LootBox")
		settle(12)
		local state = client.GetProductState("LootBox")
		local logged = logCount("POLICY_READ_FAIL") - before
		Clock.Install({ Wait = wait })
		done(harness, client)
		expect(`state={state} logged={logged}`).to.equal("state=policy-pending logged=1")
	end)

	it("reports owned from the mirror for a held perk, and never for a consumable", function()
		local harness, player, entry, client = makeLoopback(false)
		settle()
		harness.Data.GrantPerk(player, "Pet")
		-- A perk sharing the consumable's name is not ownership of it.
		harness.Data.GrantPerk(player, "LootBox")
		harness.Ctx.Replication.FlushEntry(entry)
		settle()
		local pet = client.GetProductState("MysteryPet")
		local loot = client.GetProductState("LootBox")
		done(harness, client)
		expect(`pet={pet} loot={loot}`).to.equal("pet=owned loot=purchasable")
	end)

	it("ObserveProductState fires the current state, then the policy landing, then an ownership change", function()
		local harness, player, entry, client, control = makeLoopback("hang")
		local seen = {}
		local stop = client.ObserveProductState("MysteryPet", function(state)
			table.insert(seen, state)
		end)
		settle()
		control.Set(false)
		control.Release()
		settle()
		harness.Data.GrantPerk(player, "Pet")
		harness.Ctx.Replication.FlushEntry(entry)
		settle()
		stop()
		harness.Data.RevokePerk(player, "Pet")
		harness.Ctx.Replication.FlushEntry(entry)
		settle()
		done(harness, client)
		expect(table.concat(seen, ",")).to.equal("policy-pending,purchasable,owned")
	end)

	it("answers not-loaded before Init, and the observer follows the load", function()
		local harness, _, _, client = makeLoopback(false, false)
		local seen = {}
		local before = client.GetProductState("LootBox")
		local stop = client.ObserveProductState("LootBox", function(state)
			table.insert(seen, state)
		end)
		-- No AutoPump: the Hello and the Init each cross the stub only when pumped.
		harness.Transport:PumpToServer()
		settle()
		harness.Step()
		harness.Transport:PumpToClient()
		settle()
		local after = client.GetProductState("LootBox")
		stop()
		done(harness, client)
		expect(`before={before} after={after} seen={table.concat(seen, ",")}`).to.equal(
			"before=not-loaded after=purchasable seen=not-loaded,purchasable"
		)
	end)

	it("RAISES for a name that is not declared, naming the API", function()
		local harness, _, _, client = makeLoopback(false)
		local ok, err = pcall(client.GetProductState, "Nope")
		local okObserve, errObserve = pcall(client.ObserveProductState, "Nope", function() end)
		done(harness, client)
		expect(
			`ok={ok} named={string.find(tostring(err), 'Scribe.GetProductState: "Nope"', 1, true) ~= nil} `
				.. `observe={okObserve} named={string.find(tostring(errObserve), "Scribe.ObserveProductState", 1, true) ~= nil}`
		).to.equal("ok=false named=true observe=false named=true")
	end)

	it("never sits in front of the first snapshot: a joiner's hanging read does not hold their SharedInit", function()
		-- The load hooks end with the snapshot; a read awaited inline would hold it.
		local harness, _, _, client, control = makeLoopback("hang")
		settle()
		local other = harness.Join(4242)
		settle()
		local during = client.GetShared(other.UserId) ~= nil
		control.Set(false)
		control.Release()
		settle()
		local after = client.GetShared(other.UserId) ~= nil
		done(harness, client)
		expect(`during={during} after={after}`).to.equal("during=true after=true")
	end)

	it("PrefetchProductInfo warms the policy too", function()
		local harness, _, _, client, control = makeLoopback(false)
		settle()
		-- The server's own read landed at join; the prefetch adds exactly the client's.
		local before = control.Calls()
		client.PrefetchProductInfo()
		settle()
		local armed = control.Calls() - before
		local state = client.GetProductState("LootBox")
		done(harness, client)
		expect(`armed={armed} state={state}`).to.equal("armed=1 state=purchasable")
	end)
end
