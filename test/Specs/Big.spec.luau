--!nonstrict
-- Scribe.Big: mantissa/exponent numbers for values past 2^53, where a Luau double
-- stops being exact, and past 1.8e308, where it stops existing.
--
-- Range is traded for precision on purpose: ~15 significant digits at any
-- magnitude, so 1e20 + 1 == 1e20. Stored as the two-element { mantissa, exponent }
-- array and read back as an object with arithmetic on it, the same split datatype
-- fields use.

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
			AutoPump = true,
			Template = { Coins = Scribe.Big(0, { Min = 0 }) },
		})
	end

	it("accepts a number, a numeric string, and another big value", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97401)

		data.Coins.Set(1500)
		expect(tostring(data.Coins.Get())).to.equal("1500")
		-- Past the double range entirely: tonumber("1e400") is inf, so this only
		-- works because the exponent is split off by hand.
		data.Coins.Set("1e400")
		expect(tostring(data.Coins.Get())).to.equal("1e400")
		local carried = data.Coins.Get()
		data.Coins.Set(0)
		data.Coins.Set(carried)
		expect(tostring(data.Coins.Get())).to.equal("1e400")

		harness.Cleanup()
	end)

	it("refuses a value it cannot represent", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97402)

		expect(function()
			data.Coins.Set("not a number")
		end).to.throw()
		expect(function()
			data.Coins.Set(0 / 0)
		end).to.throw()
		expect(function()
			data.Coins.Set({})
		end).to.throw()

		harness.Cleanup()
	end)

	it("adds, subtracts, multiplies, and divides past the double range", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97403)

		data.Coins.Set("1.5e100")
		data.Coins.Increment("1e99")
		expect(tostring(data.Coins.Get())).to.equal("1.6e100")
		data.Coins.Multiply(2)
		expect(tostring(data.Coins.Get())).to.equal("3.2e100")
		data.Coins.Divide(4)
		expect(tostring(data.Coins.Get())).to.equal("8e99")
		data.Coins.Decrement("1e99")
		expect(tostring(data.Coins.Get())).to.equal("7e99")

		-- Well past where a double exists at all.
		data.Coins.Set("1e400")
		data.Coins.Multiply("1e400")
		expect(tostring(data.Coins.Get())).to.equal("1e800")

		harness.Cleanup()
	end)

	it("gives Decrement the right sign, on a value a double would lose", function()
		-- Decrement used to negate its delta before handing it over, which for a big
		-- field would negate twice, and which for a numeric string coerces through a
		-- double: -"1e400" is -inf, not -1e400.
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97404)

		data.Coins.Set("5e400")
		data.Coins.Decrement("1e400")
		expect(tostring(data.Coins.Get())).to.equal("4e400")

		-- And a plain numeric delta still subtracts rather than adding.
		data.Coins.Set(1000)
		data.Coins.Decrement(250)
		expect(tostring(data.Coins.Get())).to.equal("750")

		harness.Cleanup()
	end)

	it("clamps to declared bounds", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97405)

		data.Coins.Set(100)
		data.Coins.Decrement(250)
		expect(tostring(data.Coins.Get())).to.equal("0")

		local capped = TestCtx.make({ Template = { C = Scribe.Big(0, { Max = "1e50" }) } })
		local _p, _e, d = capped.Join(97406)
		d.C.Set("1e100")
		expect(tostring(d.C.Get())).to.equal("1e50")
		capped.Cleanup()

		harness.Cleanup()
	end)

	it("errors on a divide by zero rather than storing an infinity", function()
		local harness = makeHarness()
		local _player, entry, data = harness.Join(97407)
		data.Coins.Set(100)

		expect(function()
			data.Coins.Divide(0)
		end).to.throw()
		-- Nothing partially applied, and no inf in the store, which would not survive
		-- the DataStore JSON round trip.
		expect(tostring(data.Coins.Get())).to.equal("100")
		expect(entry.LiveData.Coins[1]).to.equal(1)

		harness.Cleanup()
	end)

	it("stores the canonical mantissa/exponent pair and reloads it", function()
		local harness = makeHarness()
		local player, entry, data = harness.Join(97408)
		data.Coins.Set("9.87e250")

		-- Normalized: 1 <= |m| < 10, so one stored form per value.
		expect(entry.LiveData.Coins[2]).to.equal(250)
		expect(entry.LiveData.Coins[1] >= 1 and entry.LiveData.Coins[1] < 10).to.equal(true)

		-- Exactly, not just in the window. 10^n is inexact for most n, so scaling in
		-- more than one step compounds two roundings and drifts a clean power of ten
		-- off by an ulp: 1e60 came back as { 9.999999999999998, 59 }, a second stored
		-- form for a value that must have exactly one.
		for _, exponent in { 20, 40, 60, 100, 250, 308 } do
			data.Coins.Set(`1e{exponent}`)
			expect(entry.LiveData.Coins[1]).to.equal(1)
			expect(entry.LiveData.Coins[2]).to.equal(exponent)
		end
		data.Coins.Set("9.87e250")

		harness.Leave(player)
		local saved = harness.Fake.Persisted["Default/PLAYER_97408"]
		local reloaded = makeHarness()
		reloaded.Fake.Persisted["Default/PLAYER_97408"] = saved
		local _p2, _e2, d2 = reloaded.Join(97408)
		expect(tostring(d2.Coins.Get())).to.equal("9.87e250")
		reloaded.Cleanup()

		harness.Cleanup()
	end)

	it("exposes comparison, display, and a lossy number conversion", function()
		local harness = makeHarness()
		local _player, _entry, data = harness.Join(97409)

		data.Coins.Set("1.5e9")
		expect(data.Coins.Get():Short()).to.equal("1.50B")
		expect(data.Coins.Get():ToNumber()).to.equal(1.5e9)

		data.Coins.Set("1e400")
		-- Past the double range a plain number can only saturate.
		expect(data.Coins.Get():ToNumber()).to.equal(math.huge)

		local big = data.Coins.Get()
		data.Coins.Set("1e399")
		local smaller = data.Coins.Get()
		expect(smaller < big).to.equal(true)
		expect(big <= big).to.equal(true)

		harness.Cleanup()
	end)

	it("reads back as a big on every path, not just Get", function()
		-- Get was the only read taught about the stored pair, so Clone, Default, a
		-- container read and a listener all handed back the raw { m, e } array. One
		-- of those (Clone) even type-checks as a big and then crashes on :Short().
		local harness = TestCtx.make({
			Template = {
				Wallet = { Coins = Scribe.Big(0, { Min = 0 }) },
				Top = Scribe.Big(0),
			},
		})
		local _player, _entry, data = harness.Join(97411)
		data.Wallet.Coins.Set("1e40")
		data.Top.Set("2e40")

		expect(data.Wallet.Coins.Get():Short()).to.equal("10.00DDc")
		expect(data.Wallet.Coins.Clone():Short()).to.equal("10.00DDc")
		expect(tostring(data.Wallet.Coins.Default())).to.equal("0")
		-- Through the parent container, through the root, and through a root Clone.
		expect(tostring(data.Wallet.Get().Coins)).to.equal("1e40")
		expect(tostring(data.Get().Wallet.Coins)).to.equal("1e40")
		expect(tostring(data.Clone().Top)).to.equal("2e40")

		local seen
		data.Wallet.Changed(function(new)
			seen = new.Coins
		end)
		data.Wallet.Coins.Set("3e40")
		expect(tostring(seen)).to.equal("3e40")

		harness.Cleanup()
	end)

	it("reaches the same stored form by arithmetic as by literal", function()
		-- Scaling by a power of ten is exact for almost no power, so 100 - 30 landed
		-- on 6.9999999999999991 where the literal 70 is 7. Two stored forms for one
		-- value, agreeing to sixteen digits, and everything built on the canonical
		-- form compares the mantissa exactly: ==, the container entry search,
		-- toShort's whole-number test, and the leaderboard packing all split on it.
		local harness = makeHarness()
		local _player, entry, data = harness.Join(97417)
		for _, pair in { { 100, 30 }, { 12, 5 }, { 1000, 1 }, { 500, 125 }, { 7, 3 } } do
			data.Coins.Set(pair[1])
			data.Coins.Decrement(pair[2])
			local reached = { entry.LiveData.Coins[1], entry.LiveData.Coins[2] }
			data.Coins.Set(pair[1] - pair[2])
			expect(reached[1]).to.equal(entry.LiveData.Coins[1])
			expect(reached[2]).to.equal(entry.LiveData.Coins[2])
		end

		-- The display path is the one an idle game actually shows.
		data.Coins.Set(100)
		data.Coins.Decrement(30)
		expect(data.Coins.Get():Short()).to.equal("70")
		expect(tostring(data.Coins.Get())).to.equal("70")

		harness.Cleanup()
	end)

	it("returns a big from every write path, and seeds the declared default", function()
		-- Set/Update and the arithmetic methods each unpack their own return, and
		-- nothing asserted on those: all three lines were deletable with a green
		-- suite. The seeded default is the same story, and it is what a read before
		-- any write hands back.
		local Big = require(ScribeRoot.Internal.Big)
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Big("1e40"), Zero = Scribe.Big(0) },
		})
		local _player, entry, data = harness.Join(97419)

		-- Seeded straight from the declarator, before any write touches it.
		expect(Big.isBig(data.Coins.Get())).to.equal(true)
		expect(tostring(data.Coins.Get())).to.equal("1e40")
		expect(tostring(data.Zero.Get())).to.equal("0")
		-- Stored as the canonical pair, not the raw declarator argument.
		expect(entry.LiveData.Coins[1]).to.equal(1)
		expect(entry.LiveData.Coins[2]).to.equal(40)

		expect(Big.isBig(data.Coins.Set("2e40"))).to.equal(true)
		expect(Big.isBig(data.Coins.Update(function(v)
			return v
		end))).to.equal(true)
		expect(Big.isBig(data.Coins.Increment(1))).to.equal(true)
		expect(Big.isBig(data.Coins.Decrement(1))).to.equal(true)
		expect(Big.isBig(data.Coins.Multiply(2))).to.equal(true)
		expect(Big.isBig(data.Coins.Divide(2))).to.equal(true)

		harness.Cleanup()
	end)

	it("refuses arithmetic on an absent Scribe.Optional big", function()
		-- Every other Optional leaf errors on Increment against an absent value.
		-- The big path quietly materialized one from 0 instead.
		local harness = TestCtx.make({ Template = { Coins = Scribe.Optional(Scribe.Big(0)) } })
		local _player, _entry, data = harness.Join(97420)
		expect(data.Coins.Get()).to.equal(nil)
		for _, call in
			{
				function()
					data.Coins.Increment(5)
				end,
				function()
					data.Coins.Decrement(5)
				end,
				function()
					data.Coins.Multiply(2)
				end,
				function()
					data.Coins.Divide(2)
				end,
			}
		do
			expect(call).to.throw()
		end
		-- Once it has a value, all of them work again.
		data.Coins.Set(10)
		expect(tostring(data.Coins.Increment(5))).to.equal("15")

		harness.Cleanup()
	end)

	it("refuses container mutation, which would rewrite the stored pair", function()
		-- A big is a LEAF whose stored form happens to be a table, and every container
		-- mutation gated on the stored VALUE being a table rather than on the schema.
		-- So Insert rewrote the { mantissa, exponent } pair (a 1e100 balance became
		-- 50), Clear left a non-Optional field reading nil, and both persisted and
		-- survived a rejoin with nothing to roll back to.
		local harness = makeHarness()
		local _player, entry, data = harness.Join(97421)
		data.Coins.Set("1e100")

		for _, call in
			{
				function()
					data.Coins.Insert(5, 1)
				end,
				function()
					data.Coins.Remove(1)
				end,
				function()
					data.Coins.Clear()
				end,
				function()
					return data.Coins[1].Set(9)
				end,
			}
		do
			expect(call).to.throw()
		end

		-- Untouched, in memory and on disk.
		expect(tostring(data.Coins.Get())).to.equal("1e100")
		expect(entry.LiveData.Coins[1]).to.equal(1)
		expect(entry.LiveData.Coins[2]).to.equal(100)
		-- And the arithmetic surface still works.
		expect(tostring(data.Coins.Multiply(2))).to.equal("2e100")

		harness.Cleanup()
	end)

	it("keeps the exponent finite, so a save can never carry an infinity", function()
		-- normalize guarded the mantissa but not the exponent. Exponents ADD on a
		-- multiply, so a long enough chain overflowed to inf, which a real DataStore
		-- refuses: every save for the session failed and ProfileStore's end-of-session
		-- retry loop never released the profile. A hand-built { m, inf } pair got in
		-- the same way.
		local Util = require(ScribeRoot.Internal.Util)
		local harness = TestCtx.make({ Template = { C = Scribe.Big(0) } })
		local _player, entry, data = harness.Join(97422)

		expect(function()
			data.C.Set({ 1, math.huge })
		end).to.throw()
		expect(function()
			data.C.Set({ 1, 0 / 0 })
		end).to.throw()

		data.C.Set(1e308)
		for _ = 1, 1200 do
			data.C.Multiply(data.C.Get())
		end
		local exponent = entry.LiveData.C[2]
		expect(exponent == exponent).to.equal(true) -- not NaN
		expect(exponent ~= math.huge).to.equal(true)
		-- And the profile is still something a DataStore would accept.
		expect(Util.findUnpersistable(entry.LiveData)).to.equal(nil)

		harness.Cleanup()
	end)

	it("finds a big by value inside an array", function()
		-- Entries reach the caller unpacked, so identity never holds and a stored
		-- pair never equals the object Get just returned. Without a big case in the
		-- structural compare, Has/Find/RemoveValue silently no-op forever.
		local harness = TestCtx.make({ Template = { Hist = Scribe.ArrayOf(Scribe.Big(0)) } })
		local _player, _entry, data = harness.Join(97412)
		data.Hist.Insert("1e60")
		data.Hist.Insert("5e10")

		local needle = data.Hist[1].Get()
		expect(data.Hist.Has(needle)).to.equal(true)
		expect(data.Hist.Find(needle)).to.equal(1)

		-- A LITERAL needle for a value that was reached by arithmetic. This is the
		-- half that breaks when normalize leaves two stored forms for one value.
		local wallet = TestCtx.make({
			Template = { Coins = Scribe.Big(0), Hist = Scribe.ArrayOf(Scribe.Big(0)) },
		})
		local _p2, _e2, d2 = wallet.Join(97418)
		d2.Coins.Set(100)
		d2.Coins.Decrement(30)
		d2.Hist.Insert(d2.Coins.Get())
		expect(d2.Hist.Has(70)).to.equal(true)
		expect(d2.Hist.Find(70)).to.equal(1)
		local gone, at = d2.Hist.RemoveValue(70)
		expect(tostring(gone)).to.equal("70")
		expect(at).to.equal(1)
		expect(d2.Hist.Count()).to.equal(0)
		wallet.Cleanup()
		local removed, index = data.Hist.RemoveValue(needle)
		expect(tostring(removed)).to.equal("1e60")
		expect(index).to.equal(1)
		expect(data.Hist.Count()).to.equal(1)

		harness.Cleanup()
	end)

	it("emits an economy event for a tagged Increment and Decrement", function()
		-- The big branch returned before the economy block, so the tags table was
		-- swallowed: no LogEconomyEvent, no metric, no warning, for exactly the
		-- currency type Scribe.Big exists to serve.
		local events = {}
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Big(0, { Min = 0 }), Gems = Scribe.Int(0, { Min = 0 }) },
			Options = {
				Economy = {
					LogEconomyEvent = function(_player, flow, currency, amount, balance, txn)
						table.insert(
							events,
							{ Flow = flow.Name, Currency = currency, Amount = amount, Balance = balance, Txn = txn }
						)
					end,
				},
			},
		})
		local _player, _entry, data = harness.Join(97413)

		-- Amounts round-trip through Big arithmetic, which carries ~15 significant
		-- digits, so compare with a relative tolerance rather than exactly.
		local function near(a: number, b: number)
			return math.abs(a - b) <= math.abs(b) * 1e-12
		end

		data.Gems.Increment(5, { Source = "Quest" }) -- control: a plain number already worked
		data.Coins.Increment(1000, { Source = "Quest" })
		data.Coins.Decrement(400, { Source = "Shop" })
		expect(#events).to.equal(3)
		expect(events[2].Currency).to.equal("Coins")
		expect(events[2].Flow).to.equal("Source")
		expect(near(events[2].Amount, 1000)).to.equal(true)
		expect(events[2].Txn).to.equal("Quest")
		expect(events[3].Flow).to.equal("Sink")
		expect(near(events[3].Amount, 400)).to.equal(true)
		expect(near(events[3].Balance, 600)).to.equal(true)

		-- A clamp reports the EFFECTIVE change, and a no-op reports nothing at all,
		-- matching the plain number path.
		data.Coins.Decrement(1e9, { Source = "Shop" })
		expect(#events).to.equal(4)
		expect(near(events[4].Amount, 600)).to.equal(true)
		data.Coins.Decrement(5, { Source = "Shop" })
		expect(#events).to.equal(4)

		harness.Cleanup()
	end)

	it("drops a rolled-back big economy event, like a plain number", function()
		local events = {}
		local harness = TestCtx.make({
			Template = { Coins = Scribe.Big(0, { Min = 0 }) },
			Options = {
				Economy = {
					LogEconomyEvent = function(_player, _flow, _currency, amount)
						table.insert(events, amount)
					end,
				},
			},
		})
		local player, _entry, data = harness.Join(97414)

		local ok = harness.Data.Transaction(player, function()
			data.Coins.Increment(50, { Source = "Quest" })
			error("abort")
		end)
		expect(ok).to.equal(false)
		expect(#events).to.equal(0)
		expect(tostring(data.Coins.Get())).to.equal("0")

		harness.Data.Transaction(player, function()
			data.Coins.Increment(50, { Source = "Quest" })
		end)
		expect(#events).to.equal(1)

		harness.Cleanup()
	end)

	it("orders string bounds numerically, not lexically", function()
		-- A bound past 1.8e308 can only be spelled as a numeric string, and a raw `>`
		-- either throws on a mixed pair or compares two strings by their text, which
		-- both rejects a valid pair and lets an inverted one through.
		expect(function()
			TestCtx.make({ Template = { C = Scribe.Big(0, { Min = 0, Max = "1e400" }) } }).Cleanup()
		end).never.to.throw()
		expect(function()
			TestCtx.make({ Template = { C = Scribe.Big(0, { Min = "2", Max = "1e50" }) } }).Cleanup()
		end).never.to.throw()
		-- "1e50" < "2" lexically, so this inverted pair used to compile clean.
		expect(function()
			TestCtx.make({ Template = { C = Scribe.Big(0, { Min = "1e50", Max = "2" }) } }).Cleanup()
		end).to.throw()
		expect(function()
			TestCtx.make({ Template = { C = Scribe.Big(0, { Min = 100, Max = 1 }) } }).Cleanup()
		end).to.throw()

		local harness = TestCtx.make({ Template = { C = Scribe.Big(0, { Min = 0, Max = "1e400" }) } })
		local _player, _entry, data = harness.Join(97415)
		data.C.Set("1e500")
		expect(tostring(data.C.Get())).to.equal("1e400")
		expect(data.C.Max()).to.equal("1e400")
		harness.Cleanup()
	end)

	it("keeps a subnormal input finite rather than storing an infinity", function()
		-- 10^-324 underflows to exactly 0, so scaling in one step divided by zero and
		-- manufactured the very inf the guard above it rejects. That reaches the save
		-- payload, where a real DataStore fails the WHOLE profile write.
		local harness = makeHarness()
		local _player, entry, data = harness.Join(97416)
		for _, value in { 5e-324, 9.88131291682493e-324, 1e-300, 1e300 } do
			data.Coins.Set(value)
			local m = entry.LiveData.Coins[1]
			expect(m == m and m ~= math.huge and m ~= -math.huge).to.equal(true)
			expect(math.abs(m) >= 1 and math.abs(m) < 10).to.equal(true)
		end

		harness.Cleanup()
	end)

	itRunning("replicates the pair to the client", function()
		local harness = makeHarness()
		local player, entry, data = harness.Join(97410)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		task.wait()

		data.Coins.Set("9.87e250")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()

		-- The exponent travels as a zigzag varint and the mantissa as an f64, so a
		-- width mistake in either shows up as a different magnitude here.
		expect(tostring(client.Coins.Get())).to.equal("9.87e250")

		data.Coins.Set("1e-40")
		harness.Ctx.Replication.FlushEntry(entry)
		task.wait()
		expect(client.Coins.Get().E).to.equal(-40)

		harness.Cleanup()
	end)
end
