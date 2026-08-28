--!nonstrict
-- T4: which exchangeable paths are refused at startup, by name.
--
-- The point of refusing at registration rather than at exchange time is that a
-- misconfigured game fails to BOOT instead of discovering the problem when two
-- players are mid-exchange and value is already in escrow. Every refusal here is a shape
-- that cannot be made safe by any amount of care at leg time.
--
-- No harness and no sim: this compiles a template and asks the walk about it, so it
-- runs identically under Lune and Studio and costs nothing.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Template = require(Root.Scribe.Internal.Template)
	local ExchangeLeg = require(Root.Scribe.Internal.ExchangeLeg)

	--- Compile a template and run the refusal walk over one leg spec.
	---
	--- Returns "ADMITTED" or the refusal message, so a case asserts WHY it was refused
	--- rather than only that something went wrong.
	local function walk(template, spec): string
		local compiled = Template.Compile(template, {})
		local ok, err = pcall(ExchangeLeg.Refuse, compiled, { probe = spec })
		if ok then
			return "ADMITTED"
		end
		return tostring(err)
	end

	local function refusedFor(result: string, reason: string): string
		if string.find(result, reason, 1, true) ~= nil then
			return `refused: {reason}`
		end
		return result
	end

	local BASE = {
		Coins = Scribe.Int(0, { Min = 0, Max = 1000000 }),
		Inventory = Scribe.DictOf({ Qty = Scribe.Int(1, { Min = 1, Max = 99 }) }, { MaxKeys = 8 }),
	}

	local function withField(name, field)
		local template = table.clone(BASE)
		template[name] = field
		return template
	end

	it("ADMITS a well-formed quantity leg and a well-formed key leg, which is the control", function()
		-- Without this, every refusal below is equally well explained by a walk that
		-- refuses everything.
		expect(walk(BASE, { Path = { "Coins" }, Kind = "Qty" })).to.equal("ADMITTED")
		expect(walk(BASE, { Path = { "Inventory" }, Kind = "Key" })).to.equal("ADMITTED")
	end)

	it("REFUSES a non-persisted root, which is the one that silently duplicates and destroys", function()
		-- Session state is rebuilt from declared defaults on every load, while the
		-- escrow under _Scribe is persisted. So a session debit is undone by the payer's
		-- next join while the escrow survives (a duplicate), and a session credit is
		-- wiped by the recipient's next join (a destruction). Neither reports anything.
		local template = withField("Energy", Scribe.ServerOnly(Scribe.Session(Scribe.Int(0, { Min = 0, Max = 100 }))))
		expect(refusedFor(walk(template, { Path = { "Energy" }, Kind = "Qty" }), "non-persisted root")).to.equal(
			"refused: non-persisted root"
		)
	end)

	it("REFUSES a quantity path with no declared Min, because it has no floor", function()
		-- Scribe.Int(0) compiles Min = nil and validateWrite then skips its whole bounds
		-- clause, so a debit past zero stores a negative that every per-leg assertion
		-- accepts and that a conservation sum cannot see.
		local template = withField("Floating", Scribe.Int(0))
		expect(refusedFor(walk(template, { Path = { "Floating" }, Kind = "Qty" }), "declares no Min")).to.equal(
			"refused: declares no Min"
		)
	end)

	it("REFUSES a Scribe.Big quantity leg, per D6", function()
		local template = withField("Shards", Scribe.Big(0, { Min = 0 }))
		expect(refusedFor(walk(template, { Path = { "Shards" }, Kind = "Qty" }), "absorbs a small leg")).to.equal(
			"refused: absorbs a small leg"
		)
	end)

	it("REFUSES the reserved root, by prefix so the session root is caught too", function()
		expect(refusedFor(walk(BASE, { Path = { "_Scribe", "Perks" }, Kind = "Key" }), "reserved")).to.equal(
			"refused: reserved"
		)
		expect(refusedFor(walk(BASE, { Path = { "_ScribeSession" }, Kind = "Key" }), "reserved")).to.equal(
			"refused: reserved"
		)
	end)

	it("REFUSES a misspelled path instead of silently resolving it to a parent", function()
		-- Template.Resolve returns the deepest static ANCESTOR rather than nil, so a
		-- walk built on it accepts every typo and exchanges the wrong field.
		expect(refusedFor(walk(BASE, { Path = { "Inventry" }, Kind = "Key" }), "is not a declared field")).to.equal(
			"refused: is not a declared field"
		)
	end)

	it("REFUSES a quantity leg on a container and a key leg on a plain field", function()
		expect(refusedFor(walk(BASE, { Path = { "Inventory" }, Kind = "Qty" }), "quantity leg on a container")).to.equal(
			"refused: quantity leg on a container"
		)
		expect(refusedFor(walk(BASE, { Path = { "Coins" }, Kind = "Key" }), "not a container")).to.equal(
			"refused: not a container"
		)
	end)

	it("REFUSES a Scribe.Timed field, whose bookkeeping is keyed by path and would not follow it", function()
		-- The subtree rule the design asked for is mostly UNREACHABLE, and saying so is
		-- worth more than a case that pretends otherwise: Scribe already refuses
		-- Scribe.Timed inside an element shape at COMPILE time, with that exact
		-- reasoning, so a Timed field cannot exist inside any exchangeable container. What
		-- remains reachable is a top-level Timed field named directly as a leg, which
		-- is what this pins. The subtree walk stays as defence in depth.
		local template = withField("Boost", Scribe.Timed(Scribe.Int(0, { Min = 0, Max = 100 })))
		expect(refusedFor(walk(template, { Path = { "Boost" }, Kind = "Qty" }), "Scribe.Timed")).to.equal(
			"refused: Scribe.Timed"
		)
	end)

	it(
		"cannot even declare a Timed field inside a exchanged element, which is why the subtree rule is quiet",
		function()
			-- The control for the case above. If this ever starts compiling, the subtree
			-- walk stops being defence in depth and becomes load-bearing.
			local ok = pcall(Template.Compile, {
				Crates = Scribe.DictOf({ Boost = Scribe.Timed(Scribe.Int(0)) }, { MaxKeys = 2 }),
			}, {})
			expect(ok).to.equal(false)
		end
	)

	it("REFUSES an Evict container in the subtree, which destroys a third item silently", function()
		local template = withField(
			"Loadouts",
			Scribe.DictOf({
				Slots = Scribe.ArrayOf(Scribe.String("x"), { MaxItems = 2, Evict = "Front" }),
			}, { MaxKeys = 4 })
		)
		expect(refusedFor(walk(template, { Path = { "Loadouts" }, Kind = "Key" }), "Evict container")).to.equal(
			"refused: Evict container"
		)
	end)

	it("REFUSES a Scribe.Flags field, whose membership is not a movable quantity", function()
		local template = withField("Unlocks", Scribe.Flags({ "A", "B", "C" }))
		expect(refusedFor(walk(template, { Path = { "Unlocks" }, Kind = "Qty" }), "Scribe.Flags")).to.equal(
			"refused: Scribe.Flags"
		)
	end)

	it("REFUSES a derived field, which is computed and never written", function()
		local template = withField(
			"Level",
			Scribe.Derived(Scribe.Int(1), { "Coins" }, function(coins)
				return 1 + math.floor(coins / 100)
			end)
		)
		expect(refusedFor(walk(template, { Path = { "Level" }, Kind = "Qty" }), "Scribe.Derived")).to.equal(
			"refused: Scribe.Derived"
		)
	end)

	it("REFUSES a spec that declares no Path or an unknown Kind", function()
		expect(refusedFor(walk(BASE, { Kind = "Qty" }), "must declare a Path")).to.equal("refused: must declare a Path")
		expect(refusedFor(walk(BASE, { Path = { "Coins" }, Kind = "Wobble" }), 'Kind "Key", "Qty" or "Stack"')).to.equal(
			'refused: Kind "Key", "Qty" or "Stack"'
		)
	end)
end
