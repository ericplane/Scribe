--!nonstrict
-- Big purchases use Big arithmetic; number-currency refusals stay unchanged.

local JestGlobals = require(game:GetService("ReplicatedStorage").ScribeDev.DevPackages.JestGlobals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local RunService = game:GetService("RunService")
local Root = script.Parent.Parent.Parent.Parent
local ScribeRoot = Root.Scribe
local Scribe = require(ScribeRoot) :: any
local Client = require(ScribeRoot.Client)
local TestCtx = require(Root.Test.Helpers.TestCtx)

local itRunning = if RunService:IsRunning() then it else it.skip

local function makeTemplate()
	return {
		Essence = Scribe.Big(0, { Min = 0 }),
		-- A floor that is itself past 2^53, written as a string.
		Floored = Scribe.Big("1e20", { Min = "1e20" }),
		Debt = Scribe.Big(0, { Min = -100 }),
		Loose = Scribe.Big(0), -- no Min: Purchase floors at 0, as for a number
		Price = Scribe.Big(10),
		Wallet = Scribe.DictOf(Scribe.Big(500, { Min = 100 })),
		Vaults = Scribe.DictOf({ Gold = Scribe.Big("2e300", { Min = 0 }), Label = Scribe.String("") }),
		MaybeBig = Scribe.Optional(Scribe.Big(5)),
		-- A non-zero floor far under the balance's 15th digit.
		Floor100 = Scribe.Big(0, { Min = 100 }),
		Coins = Scribe.Int(100, { Min = 0 }),
		Nick = Scribe.String("x"),
		Boxes = Scribe.Int(0, { Min = 0 }),
		-- Number-currency controls.
		Score = Scribe.Number(50, { Min = 0 }),
		Purse = Scribe.DictOf(Scribe.Int(40, { Min = 0 })),
		MaybeNum = Scribe.Optional(Scribe.Int(3)),
	}
end

-- Record economy events as text.
local function make(options: { [string]: any }?)
	local events = {}
	local merged = {
		Economy = {
			LogEconomyEvent = function(_player, flow, currency, amount, balance, txn, itemSku)
				table.insert(
					events,
					`{flow.Name}/{currency}/{tostring(amount)}/{tostring(balance)}/{tostring(txn)}/{tostring(itemSku)}`
				)
			end,
		},
	}
	for key, value in options or {} do
		merged[key] = value
	end
	local harness = TestCtx.make({ Template = makeTemplate(), Options = merged, AutoPump = true })
	return harness, events
end

-- Render the exact stored pair, or nil.
local function big(value): string
	if value == nil then
		return "nil"
	end
	return `{tostring(value.M)}e{tostring(value.E)}`
end

local function buy(harness, player, path: string, amount: any, extra: { [string]: any }?)
	local spec = {
		Cost = { Path = path, Amount = amount },
		Category = "Shop",
		ItemId = "Lantern",
		Grant = function(data)
			data.Boxes.Increment(1)
		end,
	}
	for key, value in extra or {} do
		spec[key] = value
	end
	local ok, reason = harness.Data.Purchase(player, spec)
	-- A Grant's own error comes back with the transaction's traceback under it.
	local firstLine = string.match(tostring(reason), "^[^\n]*")
	return `{tostring(ok)}:{firstLine}`
end

describe("Data.Purchase with a Scribe.Big currency", function()
	itRunning("debits a big balance past the double range, through the accessor, on both realms", function()
		local harness, events = make()
		local player, entry, acc = harness.Join(96001)
		acc.Essence.Set("1.5e400")
		local heard = {}
		acc.Essence.Changed(function(new)
			table.insert(heard, big(new))
		end)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.StepUntil(function()
			return client.IsReady()
		end)
		local before = big(client.Essence.Get())

		local result = buy(harness, player, "Essence", "5e399")
		harness.Step()
		harness.Step()
		local raw = entry.LiveData.Essence
		local observed = `result={result} server={big(acc.Essence.Get())} stored={raw[1]},{raw[2]} `
			.. `client={before}->{big(client.Essence.Get())} heard={table.concat(heard, ",")} `
			.. `boxes={acc.Boxes.Get()} events={#events}`
		harness.Cleanup()
		expect(observed).toBe(
			"result=true:nil server=1e400 stored=1,400 client=1.5e400->1e400 heard=1e400 boxes=1 events=1"
		)
	end)

	it("refuses an insufficient big balance and changes nothing", function()
		local harness, events = make()
		local player, entry, acc = harness.Join(96002)
		acc.Essence.Set("1e400")

		local over = buy(harness, player, "Essence", "2e400")
		local justOver = buy(harness, player, "Essence", "1.00000000000001e400")
		local raw = entry.LiveData.Essence
		local observed = `over={over} justOver={justOver} stored={raw[1]},{raw[2]} boxes={acc.Boxes.Get()} `
			.. `logs={#harness.Data.GetPurchases(player)} events={#events}`
		harness.Cleanup()
		expect(observed).toBe(
			"over=false:insufficient funds justOver=false:insufficient funds stored=1,400 boxes=0 logs=0 events=0"
		)
	end)

	it("spends down to the floor and no further, wherever the floor is", function()
		local harness = make()
		local player, _entry, acc = harness.Join(96003)
		local seen = {}
		local function note(label: string, result: string, field: string)
			table.insert(seen, `{label}={result}@{big(acc[field].Get())}`)
		end

		-- Min = 0: the whole balance is spendable, then nothing is.
		acc.Essence.Set(250)
		note("exact", buy(harness, player, "Essence", 250), "Essence")
		note("empty", buy(harness, player, "Essence", "1e-300"), "Essence")
		-- A debit below the 15th digit rounds back to the floor but must still refuse.
		note("onFloor", buy(harness, player, "Floored", 1), "Floored")
		acc.Floored.Set("1.000000000001e20")
		note("aboveFloor", buy(harness, player, "Floored", "1e8"), "Floored")
		-- A negative Min allows debt down to it, as it does for a number.
		note("debt", buy(harness, player, "Debt", 100), "Debt")
		note("pastDebt", buy(harness, player, "Debt", 1), "Debt")
		-- No Min: floored at 0, as a number currency without one is.
		note("noMin", buy(harness, player, "Loose", 1), "Loose")
		-- Away from the floor a big still trades precision for range: 1e20 - 1 is 1e20.
		acc.Essence.Set("1e20")
		note("absorbed", buy(harness, player, "Essence", 1), "Essence")

		local observed = `{table.concat(seen, " ")} boxes={acc.Boxes.Get()}`
		harness.Cleanup()
		expect(observed).toBe(
			"exact=true:nil@0e0 empty=false:insufficient funds@0e0 "
				.. "onFloor=false:insufficient funds@1e20 aboveFloor=true:nil@1e20 "
				.. "debt=true:nil@-1e2 pastDebt=false:insufficient funds@-1e2 "
				.. "noMin=false:insufficient funds@0e0 absorbed=true:nil@1e20 boxes=4"
		)
	end)

	it("validates the amount for a big currency and keeps every number answer", function()
		local harness = make()
		local player, _entry, acc = harness.Join(96004)
		acc.Essence.Set(1000)
		local seen = {}
		local function try(label: string, path: string, amount: any)
			table.insert(seen, `{label}={buy(harness, player, path, amount)}`)
		end

		try("zero", "Essence", 0)
		try("negative", "Essence", -5)
		try("nan", "Essence", 0 / 0)
		try("inf", "Essence", math.huge)
		try("zeroText", "Essence", "0")
		try("negativeText", "Essence", "-1e400")
		try("word", "Essence", "abc")
		try("empty", "Essence", "")
		-- 257 bytes: one past the numeric-string limit, refused rather than truncated.
		try("long", "Essence", string.rep("0", 255) .. "10")
		try("table", "Essence", {})
		try("bool", "Essence", true)
		try("missing", "Essence", nil)
		-- Number currencies and unresolved paths answer exactly as before.
		try("intText", "Coins", "10")
		try("intPair", "Coins", { 1, 1 })
		try("typoText", "NoSuchField", "10")
		try("typoNumber", "NoSuchField", 10)
		try("textField", "Nick", "10")
		try("fraction", "Coins", 1.5)
		-- inf % 1 is NaN, so an int currency has always called inf an invalid amount.
		try("intInf", "Coins", math.huge)
		-- A Scribe.Optional big that is absent answers as an absent optional number does.
		try("absent", "MaybeBig", 1)

		local observed = `{table.concat(seen, " ")} essence={big(acc.Essence.Get())} coins={acc.Coins.Get()} `
			.. `boxes={acc.Boxes.Get()}`
		harness.Cleanup()
		expect(observed).toBe(
			"zero=false:invalid Cost amount negative=false:invalid Cost amount nan=false:invalid Cost amount "
				.. "inf=false:invalid Cost amount zeroText=false:invalid Cost amount "
				.. "negativeText=false:invalid Cost amount word=false:invalid Cost amount "
				.. "empty=false:invalid Cost amount long=false:invalid Cost amount "
				.. "table=false:invalid Cost amount bool=false:invalid Cost spec missing=false:invalid Cost spec "
				.. "intText=false:invalid Cost spec intPair=false:invalid Cost spec "
				.. "typoText=false:invalid Cost spec typoNumber=false:invalid cost path "
				.. "textField=false:invalid Cost spec fraction=false:invalid Cost amount "
				.. "intInf=false:invalid Cost amount absent=false:invalid cost path "
				.. "essence=1e3 coins=100 boxes=0"
		)
	end)

	it("accepts every amount form the field's own Decrement accepts", function()
		local harness = make()
		local player, _entry, acc = harness.Join(96005)
		acc.Essence.Set(1000)
		local seen = {}
		local function try(label: string, amount: any)
			local result = buy(harness, player, "Essence", amount)
			table.insert(seen, `{label}={result}@{big(acc.Essence.Get())}`)
		end

		try("number", 10)
		try("text", "10")
		try("spaced", " 1e1 ")
		try("bigValue", acc.Price.Get())
		try("storedPair", { 1, 1 })
		try("fields", { M = 1, E = 1 })
		-- 256 bytes: exactly the numeric-string limit, accepted.
		try("limit", string.rep("0", 254) .. "10")

		local observed = `{table.concat(seen, " ")} boxes={acc.Boxes.Get()}`
		harness.Cleanup()
		expect(observed).toBe(
			"number=true:nil@9.9e2 text=true:nil@9.8e2 spaced=true:nil@9.7e2 bigValue=true:nil@9.6e2 "
				.. "storedPair=true:nil@9.5e2 fields=true:nil@9.4e2 limit=true:nil@9.3e2 boxes=7"
		)
	end)

	it("rolls a big debit back with a throwing Grant, and the claim with it", function()
		local harness, events = make()
		local player, entry, acc = harness.Join(96006)
		acc.Essence.Set("1e400")

		local thrown = buy(harness, player, "Essence", "4e399", {
			IdempotencyKey = "order-1",
			Grant = function(data)
				data.Boxes.Increment(1)
				error("shelf is empty", 0)
			end,
		})
		local rawAfterThrow = entry.LiveData.Essence
		local afterThrow = `{rawAfterThrow[1]},{rawAfterThrow[2]}`
		local boxesAfterThrow = acc.Boxes.Get()
		-- The claim rolled back with the debit, so the same key can still buy once.
		local retried = buy(harness, player, "Essence", "4e399", { IdempotencyKey = "order-1" })
		local repeated = buy(harness, player, "Essence", "4e399", { IdempotencyKey = "order-1" })

		local observed = `thrown={thrown} afterThrow={afterThrow} boxesAfterThrow={boxesAfterThrow} `
			.. `retried={retried} repeated={repeated} essence={big(acc.Essence.Get())} boxes={acc.Boxes.Get()} `
			.. `logs={#harness.Data.GetPurchases(player)} events={#events}`
		harness.Cleanup()
		expect(observed).toBe(
			"thrown=false:shelf is empty afterThrow=1,400 boxesAfterThrow=0 retried=true:nil "
				.. "repeated=true:nil essence=6e399 boxes=1 logs=1 events=1"
		)
	end)

	it("keeps the PaidRandom guard in front of a big currency", function()
		local harness = make({
			GetPolicyInfoAsync = function()
				return { ArePaidRandomItemsRestricted = true }
			end,
		})
		local player, _entry, acc = harness.Join(96007)
		acc.Essence.Set(1000)
		local result
		for _ = 1, 20 do
			result = buy(harness, player, "Essence", 10, { PaidRandom = true })
			if result ~= `false:{Scribe.PurchaseReason.PolicyPending}` then
				break
			end
			task.wait()
		end
		local observed = `result={result} essence={big(acc.Essence.Get())} boxes={acc.Boxes.Get()}`
		harness.Cleanup()
		expect(observed).toBe("result=false:paid random items are not available for this account essence=1e3 boxes=0")
	end)

	it("spends a big DictOf element from its declared default and stops at the element's Min", function()
		local harness = make()
		local player, entry, acc = harness.Join(96008)
		local seen = {}
		local function try(label: string, path: string, amount: any)
			table.insert(seen, `{label}={buy(harness, player, path, amount)}`)
		end

		-- Never written: the balance is the element default, 500, over a Min of 100.
		local untouched = big(acc.Wallet.Gold.Get())
		try("fromDefault", "Wallet.Gold", 300)
		try("toMin", "Wallet.Gold", 100)
		try("pastMin", "Wallet.Gold", 1)
		-- A big field inside a record element: default 2e300.
		try("record", "Vaults.Main.Gold", "5e299")

		local gold = entry.LiveData.Wallet.Gold
		local observed = `untouched={untouched} {table.concat(seen, " ")} gold={big(acc.Wallet.Gold.Get())} `
			.. `stored={gold[1]},{gold[2]} vault={big(acc.Vaults.Main.Gold.Get())} boxes={acc.Boxes.Get()}`
		harness.Cleanup()
		expect(observed).toBe(
			"untouched=nil fromDefault=true:nil toMin=true:nil pastMin=false:insufficient funds "
				.. "record=true:nil gold=1e2 stored=1,2 vault=1.5e300 boxes=3"
		)
	end)

	it("logs a big amount in its stored form and reports doubles to analytics", function()
		local harness, events = make()
		local player, _entry, acc = harness.Join(96009)
		acc.Essence.Set(1000)

		local small = buy(harness, player, "Essence", "250")
		local huge = buy(harness, player, "Vaults.Main.Gold", "1.25e300")
		acc.Essence.Set("1e400")
		local past = buy(harness, player, "Essence", "5e399")
		local number = buy(harness, player, "Coins", 30)

		local logs = {}
		for _, record in harness.Data.GetPurchases(player, { Kind = "InGame" }) do
			local amount = record.Amount
			local text = if type(amount) == "table"
				then `pair({amount[1]},{amount[2]})`
				else `{type(amount)}({tostring(amount)})`
			table.insert(logs, `{record.Currency}:{text}`)
		end
		-- Newest first, and these four can share a timestamp, so sort the text instead.
		table.sort(logs)

		local observed = `results={small},{huge},{past},{number} logs={table.concat(logs, ";")} `
			.. `events={table.concat(events, ";")}`
		harness.Cleanup()
		expect(observed).toBe(
			"results=true:nil,true:nil,true:nil,true:nil "
				.. "logs=Coins:number(30);Essence:pair(2.5,2);Essence:pair(5,399);Gold:pair(1.25,300) "
				.. "events=Sink/Essence/250/750/Lantern/Lantern;Sink/Gold/1.25e+300/7.5e+299/Lantern/Lantern;"
				.. "Sink/Essence/inf/inf/Lantern/Lantern;Sink/Coins/30/70/Lantern/Lantern"
		)
	end)
end)

describe("Data.Purchase with a Scribe.Big currency, at its edges", function()
	it("returns its answer when the Grant removes the big field it was paid from", function()
		-- The economy event reads the balance after the commit; it must not raise on nil.
		local harness = make()
		local player, _entry, acc = harness.Join(96101)
		acc.Wallet.Child("Gold").Set(1000)
		acc.MaybeBig.Set(500)
		local function guarded(path: string, grant)
			local ok, result = pcall(buy, harness, player, path, 100, { Grant = grant })
			return if ok then result else `raised:{string.match(tostring(result), "[^\n]*$")}`
		end
		local seen = {
			guarded("Wallet.Gold", function(data)
				data.Boxes.Increment(1)
				data.Wallet.Remove("Gold")
			end),
			guarded("MaybeBig", function(data)
				data.Boxes.Increment(1)
				data.MaybeBig.Set(nil)
			end),
		}
		local logged = #harness.Data.GetPurchases(player, { Kind = "InGame" })
		local boxes = acc.Boxes.Get()
		harness.Cleanup()
		expect(`{table.concat(seen, ",")} boxes={boxes} logged={logged}`).toBe("true:nil,true:nil boxes=2 logged=2")
	end)

	it("refuses a purchase that would round below a non-zero Min, rather than clamp to it", function()
		local harness = make()
		local player, _entry, acc = harness.Join(96102)
		local anomalies = 0
		harness.Data.OnAnomaly:Connect(function()
			anomalies += 1
		end)
		acc.Floor100.Set("1e18")
		-- Headroom rounds from 1e18 - 100 to 1e18; spending 1e18 must still refuse.
		local seen = {
			buy(harness, player, "Floor100", "1e18"),
			buy(harness, player, "Floor100", acc.Floor100.Get()),
		}
		local observed =
			`{table.concat(seen, ",")} balance={big(acc.Floor100.Get())} boxes={acc.Boxes.Get()} anomalies={anomalies}`
		harness.Cleanup()
		expect(observed).toBe("false:insufficient funds,false:insufficient funds balance=1e18 boxes=0 anomalies=0")
	end)

	it("answers a refusal, not a raise, for an amount that cannot be read", function()
		-- An accessor passed without .Get() raises when indexed for its mantissa.
		local harness = make()
		local player, _entry, acc = harness.Join(96103)
		acc.Essence.Set(1000)
		local ok, result = pcall(buy, harness, player, "Essence", acc.Price)
		local seen = if ok then result else `raised:{tostring(result)}`
		local balance = big(acc.Essence.Get())
		harness.Cleanup()
		expect(`{seen} balance={balance}`).toBe("false:invalid Cost amount balance=1e3")
	end)
end)

describe("Data.Purchase with a number currency", function()
	-- Number-currency results must match the previous implementation.
	it("answers every number-currency purchase exactly as before", function()
		local harness, events = make()
		local player, _entry, acc = harness.Join(96010)
		local seen = {}
		local function try(label: string, path: string, amount: any)
			table.insert(seen, `{label}={buy(harness, player, path, amount)}`)
		end

		try("spend", "Coins", 10)
		try("text", "Coins", "10")
		try("pair", "Coins", { 1, 1 })
		try("bool", "Coins", true)
		try("missing", "Coins", nil)
		try("zero", "Coins", 0)
		try("negative", "Coins", -1)
		try("nan", "Coins", 0 / 0)
		try("intInf", "Coins", math.huge)
		try("fraction", "Coins", 1.5)
		try("over", "Coins", 1000)
		try("typo", "NoSuchField", 10)
		try("typoText", "NoSuchField", "10")
		-- A typo of a closed record field makes the accessor walk itself throw.
		try("closedTypo", "Vaults.Main.Glod", 10)
		try("closedTypoText", "Vaults.Main.Glod", "10")
		try("textField", "Nick", 10)
		try("textFieldText", "Nick", "10")
		try("numberInf", "Score", math.huge)
		try("numberHalf", "Score", 0.5)
		try("element", "Purse.Copper", 15)
		try("absent", "MaybeNum", 1)
		local notTable = harness.Data.Purchase(player, { Cost = 5, ItemId = "x" })
		local notPath = harness.Data.Purchase(player, { Cost = { Path = 5, Amount = 5 }, ItemId = "x" })

		local logs = {}
		for _, record in harness.Data.GetPurchases(player, { Kind = "InGame" }) do
			table.insert(logs, `{record.Currency}:{type(record.Amount)}({tostring(record.Amount)})`)
		end
		table.sort(logs)
		local observed = `{table.concat(seen, " ")} notTable={tostring(notTable)} notPath={tostring(notPath)} `
			.. `coins={acc.Coins.Get()} score={acc.Score.Get()} copper={acc.Purse.Copper.Get()} `
			.. `boxes={acc.Boxes.Get()} logs={table.concat(logs, ";")} events={table.concat(events, ";")}`
		harness.Cleanup()
		expect(observed).toBe(
			"spend=true:nil text=false:invalid Cost spec pair=false:invalid Cost spec bool=false:invalid Cost spec "
				.. "missing=false:invalid Cost spec zero=false:invalid Cost amount negative=false:invalid Cost amount "
				.. "nan=false:invalid Cost amount intInf=false:invalid Cost amount fraction=false:invalid Cost amount "
				.. "over=false:insufficient funds typo=false:invalid cost path typoText=false:invalid Cost spec "
				.. "closedTypo=false:invalid cost path closedTypoText=false:invalid Cost spec "
				.. "textField=false:cost path is not a spendable number textFieldText=false:invalid Cost spec "
				.. "numberInf=false:insufficient funds numberHalf=true:nil element=true:nil "
				.. "absent=false:invalid cost path notTable=false notPath=false "
				.. "coins=90 score=49.5 copper=25 boxes=3 "
				.. "logs=Coins:number(10);Copper:number(15);Score:number(0.5) "
				.. "events=Sink/Coins/10/90/Lantern/Lantern;Sink/Score/0.5/49.5/Lantern/Lantern;"
				.. "Sink/Copper/15/25/Lantern/Lantern"
		)
	end)
end)
