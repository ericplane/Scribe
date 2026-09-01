--!nonstrict
-- Per-player Marketplace prices on the client.
--
-- A live server's GetProductInfoAsync has no player in context and answers the base
-- catalog price; a Studio server answers the personalized one. That divergence is why
-- this is client-side, and why two assertions here outrank the rest: the price handed
-- back is the discounted one, and a failed read stays nil.
--
-- Batching is the other property. The engine only coalesces calls in flight together,
-- so the queue must defer, or a twelve-button shop costs twelve requests.

return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local Clock = require(ScribeRoot.Internal.Clock)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local template = { Coins = Scribe.Int(0, { Min = 0 }) }

	local PASS_ID = 111
	local PRODUCT_ID = 222

	--- Let the defer, the spawned read and any observer push run.
	local function settle(frames: number?)
		for _ = 1, frames or 5 do
			task.wait()
		end
	end

	--- A Marketplace stand-in. `prices` is keyed by asset id; a missing id raises, which
	--- is also how the failure paths are driven. Returns the fake and its call log.
	local function fakeMarketplace(prices: { [number]: number? })
		local calls: { { Asset: number, Type: any } } = {}
		local function fake(assetId: number, infoType: any)
			table.insert(calls, { Asset = assetId, Type = infoType })
			local price = prices[assetId]
			if price == nil then
				error(`fake: asset {assetId} unavailable`)
			end
			return { Name = "Item", PriceInRobux = price, UserBasePriceInRobux = 100 }
		end
		return fake, calls
	end

	--- A LocalPlayer whose HasRobloxSubscription can be flipped. Only `Once` is offered,
	--- so a watch widened to `Connect` fails here.
	local function installLocalPlayer()
		local armed: { () -> () } = {}
		local player = {
			Name = "Local",
			UserId = 78001,
			HasRobloxSubscription = false,
			GetPropertyChangedSignal = function(_self, property: string)
				assert(property == "HasRobloxSubscription", `watched the wrong property: {property}`)
				return {
					Once = function(_signal, fn: () -> ())
						table.insert(armed, fn)
						return { Disconnect = function() end }
					end,
				}
			end,
		}
		Client.SetLocalPlayerProbe(function()
			return player
		end)

		local function flip()
			player.HasRobloxSubscription = not player.HasRobloxSubscription
			-- Once: a handler is spent by the fire that runs it.
			local pending = armed
			armed = {}
			for _, fn in pending do
				task.spawn(fn)
			end
		end
		return flip, function()
			Client.SetLocalPlayerProbe(nil)
		end
	end

	--- A client wired to `fake`, with one pass and one product declared.
	local function makeClient(fake: any)
		local harness = TestCtx.make({
			Template = template,
			Options = {
				Passes = { VIP = { Id = PASS_ID } },
				Products = { Coins100 = { Id = PRODUCT_ID } },
				GetProductInfoAsync = fake,
				Banner = false,
			},
		})
		return harness, Client.new(harness.Options, harness.Compiled)
	end

	describe("resolution", function()
		it("reads a PASS as GamePass and a PRODUCT as Product", function()
			local fake, calls = fakeMarketplace({ [PASS_ID] = 80, [PRODUCT_ID] = 40 })
			local harness, client = makeClient(fake)
			client.GetProductInfo("VIP")
			client.GetProductInfo("Coins100")
			settle()

			local seen: { [number]: any } = {}
			for _, call in calls do
				seen[call.Asset] = call.Type
			end
			harness.Cleanup()
			local pass = seen[PASS_ID] == Enum.InfoType.GamePass
			local product = seen[PRODUCT_ID] == Enum.InfoType.Product
			expect(`pass={pass} product={product}`).to.equal("pass=true product=true")
		end)

		it("hands back the DISCOUNTED price, never the base price", function()
			-- 100 is the catalog number a server-side cache would have held.
			local fake = fakeMarketplace({ [PASS_ID] = 80 })
			local harness, client = makeClient(fake)
			client.GetPrice("VIP")
			settle()
			local price = client.GetPrice("VIP")
			local base = client.GetProductInfo("VIP").UserBasePriceInRobux
			harness.Cleanup()
			expect(`price={price} base={base}`).to.equal("price=80 base=100")
		end)

		it("resolves without waiting for the profile to load", function()
			-- No Join anywhere in this spec: nothing here may sit behind waitForLoaded.
			local fake = fakeMarketplace({ [PASS_ID] = 55 })
			local harness, client = makeClient(fake)
			expect(client.IsReady()).to.equal(false)
			client.GetPrice("VIP")
			settle()
			local price = client.GetPrice("VIP")
			harness.Cleanup()
			expect(price).to.equal(55)
		end)
	end)

	describe("batching", function()
		it("DEFERS, so reads asked for in one frame leave as one burst", function()
			-- Issuing on the spot would be N separate requests, which trips the limit.
			local fake, calls = fakeMarketplace({ [PASS_ID] = 80, [PRODUCT_ID] = 40 })
			local harness, client = makeClient(fake)
			client.GetProductInfo("VIP")
			client.GetProductInfo("Coins100")
			client.GetPrice("VIP")
			local duringFrame = #calls
			settle()
			local afterFrame = #calls
			harness.Cleanup()
			expect(`during={duringFrame} after={afterFrame}`).to.equal("during=0 after=2")
		end)

		it("reads each asset ONCE however many times it is asked for", function()
			local fake, calls = fakeMarketplace({ [PASS_ID] = 80 })
			local harness, client = makeClient(fake)
			client.GetPrice("VIP")
			settle()
			for _ = 1, 5 do
				client.GetPrice("VIP")
			end
			settle()
			harness.Cleanup()
			expect(#calls).to.equal(1)
		end)
	end)

	describe("prefetch", function()
		it("warms EVERY declared pass and product as one burst", function()
			local fake, calls = fakeMarketplace({ [PASS_ID] = 80, [PRODUCT_ID] = 40 })
			local harness, client = makeClient(fake)
			client.PrefetchProductInfo()
			local duringFrame = #calls
			settle()
			local pass, product = client.GetPrice("VIP"), client.GetPrice("Coins100")
			harness.Cleanup()
			expect(`during={duringFrame} calls={#calls} pass={pass} product={product}`).to.equal(
				"during=0 calls=2 pass=80 product=40"
			)
		end)

		it("takes a subset, and warms only that", function()
			local fake, calls = fakeMarketplace({ [PASS_ID] = 80, [PRODUCT_ID] = 40 })
			local harness, client = makeClient(fake)
			client.PrefetchProductInfo({ "VIP" })
			settle()
			harness.Cleanup()
			expect(`calls={#calls} asset={calls[1].Asset}`).to.equal(`calls=1 asset={PASS_ID}`)
		end)

		it("RAISES on a typo in the list without warming anything", function()
			-- Validated in full before the first enqueue: a half-warmed cache after a
			-- raise is the state nobody thinks to look for.
			local fake, calls = fakeMarketplace({ [PASS_ID] = 80, [PRODUCT_ID] = 40 })
			local harness, client = makeClient(fake)
			local ok = pcall(client.PrefetchProductInfo, { "VIP", "Typo" })
			settle()
			harness.Cleanup()
			expect(`ok={ok} calls={#calls}`).to.equal("ok=false calls=0")
		end)
	end)

	describe("failure", function()
		it("leaves the price NIL rather than falling back to the base price", function()
			local waitImpl = Clock.Wait
			Clock.Install({
				Wait = function()
					return task.wait()
				end,
			})
			local fake, calls = fakeMarketplace({})
			local harness, client = makeClient(fake)
			client.GetPrice("VIP")
			settle(12)
			local price = client.GetPrice("VIP")
			local attempts = #calls
			Clock.Install({ Wait = waitImpl })
			harness.Cleanup()
			expect(`price={tostring(price)} attempts={attempts}`).to.equal("price=nil attempts=4")
		end)
	end)

	describe("observers", function()
		it("fires IMMEDIATELY, then again when the read lands", function()
			-- Lets a button render "..." on the first frame instead of staying blank.
			local fake = fakeMarketplace({ [PASS_ID] = 80 })
			local harness, client = makeClient(fake)
			local seen: { string } = {}
			client.ObserveProductInfo("VIP", function(info)
				table.insert(seen, if info == nil then "nil" else tostring(info.PriceInRobux))
			end)
			settle()
			harness.Cleanup()
			expect(table.concat(seen, ",")).to.equal("nil,80")
		end)

		it("stops delivering once disconnected", function()
			local fake = fakeMarketplace({ [PASS_ID] = 80 })
			local harness, client = makeClient(fake)
			local seen: { string } = {}
			local disconnect = client.ObserveProductInfo("VIP", function(info)
				table.insert(seen, if info == nil then "nil" else tostring(info.PriceInRobux))
			end)
			disconnect()
			settle()
			harness.Cleanup()
			expect(table.concat(seen, ",")).to.equal("nil")
		end)
	end)

	describe("invalidation", function()
		it("re-reads when the local player's HasRobloxSubscription flips", function()
			-- Plus is 10% for two months then 20%, so the player's price moves while the
			-- catalog price does not.
			local flip, restore = installLocalPlayer()
			local prices: { [number]: number? } = { [PASS_ID] = 100 }
			local fake = fakeMarketplace(prices)
			local harness, client = makeClient(fake)
			local seen: { string } = {}
			client.ObserveProductInfo("VIP", function(info)
				table.insert(seen, if info == nil then "nil" else tostring(info.PriceInRobux))
			end)
			settle()
			prices[PASS_ID] = 80
			flip()
			settle()
			restore()
			harness.Cleanup()
			expect(table.concat(seen, ",")).to.equal("nil,100,80")
		end)

		it("is ONE-SHOT, so a second flip needs RefreshProductInfo", function()
			-- Pinning Once on purpose: widening it to Connect should be a decision
			-- somebody makes, not something that drifts in.
			local flip, restore = installLocalPlayer()
			local prices: { [number]: number? } = { [PASS_ID] = 100 }
			local fake = fakeMarketplace(prices)
			local harness, client = makeClient(fake)
			client.GetPrice("VIP")
			settle()
			prices[PASS_ID] = 80
			flip()
			settle()
			local first = client.GetPrice("VIP")
			prices[PASS_ID] = 60
			flip()
			settle()
			local second = client.GetPrice("VIP")
			client.RefreshProductInfo("VIP")
			settle()
			local refreshed = client.GetPrice("VIP")
			restore()
			harness.Cleanup()
			expect(`first={first} second={second} refreshed={refreshed}`).to.equal("first=80 second=80 refreshed=60")
		end)

		it("RETRIES arming when the first read beat LocalPlayer into existence", function()
			-- Treating a failed connect as armed would freeze the price for the rest of
			-- the session, and only for players whose first read landed early.
			Client.SetLocalPlayerProbe(function()
				return nil
			end)

			local prices: { [number]: number? } = { [PASS_ID] = 100 }
			local fake = fakeMarketplace(prices)
			local harness, client = makeClient(fake)
			client.GetPrice("VIP")
			settle()

			local flip, restore = installLocalPlayer()
			client.GetPrice("VIP")
			settle()
			prices[PASS_ID] = 80
			flip()
			settle()
			local after = client.GetPrice("VIP")
			restore()
			harness.Cleanup()
			expect(after).to.equal(80)
		end)

		it("RefreshProductInfo re-reads the one name it is given", function()
			local prices: { [number]: number? } = { [PASS_ID] = 100, [PRODUCT_ID] = 40 }
			local fake, calls = fakeMarketplace(prices)
			local harness, client = makeClient(fake)
			client.GetPrice("VIP")
			client.GetPrice("Coins100")
			settle()
			prices[PASS_ID] = 70
			client.RefreshProductInfo("VIP")
			settle()
			local pass, product = client.GetPrice("VIP"), client.GetPrice("Coins100")
			harness.Cleanup()
			expect(`pass={pass} product={product} calls={#calls}`).to.equal("pass=70 product=40 calls=3")
		end)
	end)

	describe("the yielding form", function()
		it("returns the info once it lands", function()
			local fake = fakeMarketplace({ [PASS_ID] = 80 })
			local harness, client = makeClient(fake)
			local info = client.GetProductInfoAsync("VIP", 5)
			harness.Cleanup()
			expect(if info == nil then "nil" else info.PriceInRobux).to.equal(80)
		end)

		it("returns nil on timeout, and the late arrival still settles cleanly", function()
			-- Resuming a thread the timeout already woke raises, inside the spawned read
			-- where nothing catches it. The proof it did not: the read still settles a
			-- second waiter, which is also the wait; a frame count is 15ms a frame on
			-- Windows and far less on Linux.
			local fake = function(assetId: number)
				task.wait(0.2)
				return { Name = "Item", PriceInRobux = 80, UserBasePriceInRobux = 100, Asset = assetId }
			end
			local harness, client = makeClient(fake)
			local timedOut = client.GetProductInfoAsync("VIP", 0)
			local afterwards = client.GetPriceAsync("VIP", 5)
			harness.Cleanup()
			expect(`timedOut={tostring(timedOut)} afterwards={tostring(afterwards)}`).to.equal(
				"timedOut=nil afterwards=80"
			)
		end)

		it("GetPriceAsync yields to the number, and honours its timeout", function()
			-- The timeout has to reach GetProductInfoAsync: without it the shorthand always
			-- waits the full default, which is the opposite of what a caller asked for.
			local fake = fakeMarketplace({ [PASS_ID] = 80 })
			local harness, client = makeClient(fake)
			local price = client.GetPriceAsync("VIP", 5)

			local slow = function()
				task.wait(0.2)
				return { Name = "Item", PriceInRobux = 80, UserBasePriceInRobux = 100 }
			end
			local slowHarness, slowClient = makeClient(slow)
			local started = os.clock()
			local timedOut = slowClient.GetPriceAsync("VIP", 0)
			local waited = os.clock() - started
			local late = slowClient.GetPriceAsync("VIP", 5)

			harness.Cleanup()
			slowHarness.Cleanup()
			expect(`price={price} timedOut={tostring(timedOut)} quick={waited < 0.15} late={tostring(late)}`).to.equal(
				"price=80 timedOut=nil quick=true late=80"
			)
		end)

		it("NEVER resumes a caller that timed out and then parked on something else", function()
			-- Coroutine status cannot tell those two apart: a timed-out caller waiting on
			-- anything at all still reads "suspended". Settling on that alone wakes it out
			-- of an unrelated wait, holding a price it stopped asking for.
			local fake = function()
				task.wait(0.2)
				return { Name = "Item", PriceInRobux = 80, UserBasePriceInRobux = 100 }
			end
			local harness, client = makeClient(fake)
			local reached: { string } = {}
			local worker = coroutine.create(function()
				table.insert(reached, `timeout={tostring(client.GetProductInfoAsync("VIP", 0))}`)
				-- Parked for good. Only a spurious resume moves this thread on.
				coroutine.yield()
				table.insert(reached, "WOKEN BY THE LATE READ")
			end)
			coroutine.resume(worker)
			-- Joins the read in flight, so the assertion runs once it has landed.
			local late = client.GetPriceAsync("VIP", 5)
			harness.Cleanup()
			expect(`{table.concat(reached, ",")} late={tostring(late)}`).to.equal("timeout=nil late=80")
		end)
	end)

	describe("refusals and cost", function()
		it("RAISES on a name that is not a declared pass or product, naming it", function()
			local fake = fakeMarketplace({ [PASS_ID] = 80 })
			local harness, client = makeClient(fake)
			local ok, err = pcall(client.GetPrice, "Nonexistent")
			harness.Cleanup()
			expect(`ok={ok} named={string.find(tostring(err), "Nonexistent", 1, true) ~= nil}`).to.equal(
				"ok=false named=true"
			)
		end)

		it("costs NOTHING in a client that never asks for a price", function()
			-- A client that eagerly warmed at construction would read 2 here.
			local fake, calls = fakeMarketplace({ [PASS_ID] = 80, [PRODUCT_ID] = 40 })
			local harness, client = makeClient(fake)
			local status = client.GetServiceStatus()
			settle()
			harness.Cleanup()
			expect(`calls={#calls} alive={status ~= nil}`).to.equal("calls=0 alive=true")
		end)
	end)
end
