--!nonstrict
-- Owner countdowns use event-driven session metadata.

return function()
	local Root = script.Parent.Parent.Parent.Parent
	local Scribe = require(Root.Scribe) :: any
	local Client = require(Root.Scribe.Client)
	local Clock = require(Root.Scribe.Internal.Clock)
	local Template = require(Root.Scribe.Internal.Template)
	local Wire = require(Root.Scribe.Internal.Wire)
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local harnesses = {}
	local now

	beforeEach(function()
		now = 1800000000
		Clock.Install({
			Now = function()
				return now
			end,
		})
	end)

	afterEach(function()
		for _, harness in harnesses do
			harness.Cleanup()
		end
		table.clear(harnesses)
		Clock.Reset()
	end)

	local function make(config)
		local cfg = config or {}
		cfg.AutoPump = false
		cfg.Template = {
			Boost = Scribe.Timed(false),
			Charges = Scribe.Timed(5),
			Nested = { Enabled = Scribe.Timed(true) },
			Methods = { Get = Scribe.Timed(0), Changed = Scribe.Timed(false) },
			Private = Scribe.ServerOnly({ Boost = Scribe.Timed(false) }),
			Runtime = Scribe.Session({ Boost = Scribe.Timed(false) }),
			Public = Scribe.Shared({ Boost = Scribe.Timed(false) }),
		}
		local harness = TestCtx.make(cfg)
		table.insert(harnesses, harness)
		return harness
	end

	local function connect(harness, player)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		harness.Transport:PumpToServer()
		harness.Transport:PumpToClient()
		return client
	end

	local function flush(harness)
		harness.Step()
		harness.Transport:PumpToClient()
	end

	local function fieldId(harness, path)
		local schema = Template.Resolve(harness.Compiled, path)
		return tostring(schema.Id)
	end

	local function mirror(entry)
		return entry.SessionStore[Template.SESSION_ROOT].Timed
	end

	it("includes active timers in the owner's first snapshot", function()
		local harness = make()
		local player, entry, data = harness.Join()
		data.Boost.SetTimed(true, 60)
		data.Nested.Enabled.SetTimed(false, 40)
		local client = connect(harness, player)
		local active, remaining = client.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(60)
		expect(client.Nested.Enabled.Get()).to.equal(false)
		local nestedActive, nestedRemaining = client.Nested.Enabled.Active()
		expect(nestedActive).to.equal(true)
		expect(nestedRemaining).to.equal(40)
		expect(mirror(entry)[fieldId(harness, { "Nested", "Enabled" })]).to.equal(now + 40)
	end)

	it("replicates a false value and a value already equal to its default", function()
		local harness = make()
		local player, _, data = harness.Join()
		local client = connect(harness, player)
		data.Boost.SetTimed(false, 60)
		data.Charges.SetTimed(5, 90)
		flush(harness)
		expect(client.Boost.Get()).to.equal(false)
		expect((client.Boost.Active())).to.equal(true)
		expect(client.Charges.Get()).to.equal(5)
		local active, remaining = client.Charges.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(90)
	end)

	it("publishes extensions without changing the field's value", function()
		local harness = make()
		local player, _, data = harness.Join()
		local client = connect(harness, player)
		data.Boost.SetTimed(true, 60)
		flush(harness)
		now += 10
		data.Boost.ExtendTimed(30)
		flush(harness)
		local active, remaining = client.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(80)
		expect(client.Boost.Get()).to.equal(true)
	end)

	it("lets value listeners read the deadline from the same diff", function()
		local harness = make()
		local player, _, data = harness.Join()
		local client = connect(harness, player)
		local observedActive, observedRemaining
		client.Boost.Changed(function()
			observedActive, observedRemaining = client.Boost.Active()
		end)
		data.Boost.SetTimed(true, 60)
		flush(harness)
		expect(observedActive).to.equal(true)
		expect(observedRemaining).to.equal(60)
	end)

	it("batches deadline and value updates into one final container notification", function()
		local harness = make()
		local player, _, data = harness.Join()
		local client = connect(harness, player)
		local changed, observed, nested = {}, {}, {}
		local function capture(value)
			local firstActive, firstRemaining = client.Methods.Child("Get").Active()
			local secondActive, secondRemaining = client.Methods.Child("Changed").Active()
			return { value.Get, value.Changed, firstActive, firstRemaining, secondActive, secondRemaining }
		end
		client.Raw.Changed(function(value)
			table.insert(changed, capture(value.Methods))
		end)
		client.Raw.Observe(function(value)
			table.insert(observed, capture(value.Methods))
		end)
		client.Methods.Changed(function(value)
			table.insert(nested, capture(value))
		end)
		table.clear(observed) -- Ignore Observe's initial callback.
		data.Methods.Child("Get").SetTimed(20, 60)
		data.Methods.Child("Changed").SetTimed(true, 90)
		flush(harness)
		for _, notifications in { changed, observed, nested } do
			expect(#notifications).to.equal(1)
			local state = notifications[1]
			expect(state[1]).to.equal(20)
			expect(state[2]).to.equal(true)
			expect(state[3]).to.equal(true)
			expect(state[4]).to.equal(60)
			expect(state[5]).to.equal(true)
			expect(state[6]).to.equal(90)
		end
	end)

	it("lets observers read the deadline while the first snapshot is applied", function()
		local harness = make()
		local player, _, data = harness.Join()
		data.Boost.SetTimed(true, 60)
		harness.Transport.LocalPlayer = player
		local client = Client.new(harness.Options, harness.Compiled)
		expect((client.Boost.Active())).to.equal(false)
		local active, remaining
		client.Boost.Observe(function(value)
			if value then
				active, remaining = client.Boost.Active()
			end
		end)
		harness.Transport:PumpToServer()
		harness.Transport:PumpToClient()
		expect(active).to.equal(true)
		expect(remaining).to.equal(60)
	end)

	it("uses synchronized server time when the local wall clock disagrees", function()
		local harness = make()
		local player, _, data = harness.Join()
		data.Boost.SetTimed(true, 60)
		local client = connect(harness, player)
		Clock.Install({
			Now = function()
				return now + 10000
			end,
			ServerNow = function()
				return now + 0.25
			end,
		})
		local active, remaining = client.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(59.75)
	end)

	it("keeps expiry authority on the server despite local value edits", function()
		local harness = make()
		local player, _, data = harness.Join()
		local client = connect(harness, player)
		client.Boost.Set(true)
		expect((client.Boost.Active())).to.equal(false)
		expect(pcall(client.Boost.SetTimed, true, 60)).to.equal(false)
		expect(pcall(client.Boost.ExtendTimed, 60)).to.equal(false)
		data.Boost.SetTimed(true, 60)
		flush(harness)
		client.Boost.Set(false)
		expect((client.Boost.Active())).to.equal(true)
		local readActive = client.Boost.Active
		client.Stop()
		expect(pcall(readActive)).to.equal(false)
	end)

	it("counts down locally and expires without waiting for a server sweep", function()
		local harness = make()
		local player, _, data = harness.Join()
		local client = connect(harness, player)
		data.Boost.SetTimed(true, 60)
		flush(harness)
		local before = #harness.FramesFor(player, Wire.Frames.Diff)
		now += 59
		local active, remaining = client.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(1)
		now += 1
		local expired, absent = client.Boost.Active()
		expect(expired).to.equal(false)
		expect(absent).to.equal(nil)
		expect(#harness.FramesFor(player, Wire.Frames.Diff)).to.equal(before)
	end)

	it("clears metadata when the sweep restores the template default", function()
		local harness = make()
		local player, entry, data = harness.Join()
		local client = connect(harness, player)
		data.Charges.SetTimed(20, 60)
		flush(harness)
		now += 60
		harness.Ctx.Timed.Sweep(entry)
		flush(harness)
		expect(client.Charges.Get()).to.equal(5)
		expect((client.Charges.Active())).to.equal(false)
		expect(mirror(entry)[fieldId(harness, { "Charges" })]).to.equal(nil)
	end)

	it("sweeps timed fields named after accessor methods", function()
		local harness = make()
		local player, entry, data = harness.Join()
		local client = connect(harness, player)
		data.Methods.Child("Get").SetTimed(20, 60)
		data.Methods.Child("Changed").SetTimed(true, 60)
		flush(harness)
		expect((client.Methods.Child("Get").Active())).to.equal(true)
		now += 60
		harness.Ctx.Timed.Sweep(entry)
		flush(harness)
		expect(client.Methods.Child("Get").Get()).to.equal(0)
		expect(client.Methods.Child("Changed").Get()).to.equal(false)
		expect((client.Methods.Child("Changed").Active())).to.equal(false)
	end)

	it("rolls back deadline changes and commits successful transactions", function()
		local harness = make()
		local player, entry, data = harness.Join()
		local client = connect(harness, player)
		data.Boost.SetTimed(true, 60)
		flush(harness)
		local ok = harness.Data.Transaction(player, function()
			data.Boost.ExtendTimed(90)
			data.Charges.SetTimed(10, 120)
			error("abort")
		end)
		flush(harness)
		expect(ok).to.equal(false)
		expect(mirror(entry)[fieldId(harness, { "Boost" })]).to.equal(now + 60)
		expect(mirror(entry)[fieldId(harness, { "Charges" })]).to.equal(nil)
		local active, remaining = client.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(60)
		expect((client.Charges.Active())).to.equal(false)
		local committed = harness.Data.Transaction(player, function()
			data.Boost.ExtendTimed(30)
		end)
		flush(harness)
		expect(committed).to.equal(true)
		local _, extended = client.Boost.Active()
		expect(extended).to.equal(90)
	end)

	it("suppresses deadline diffs with replicate false", function()
		local harness = make()
		local player, entry, data = harness.Join()
		local client = connect(harness, player)
		data.Boost.SetTimed(true, 60, false)
		data.Boost.ExtendTimed(30, false)
		flush(harness)
		expect(client.Boost.Get()).to.equal(false)
		expect((client.Boost.Active())).to.equal(false)
		expect(mirror(entry)[fieldId(harness, { "Boost" })]).to.equal(now + 90)
		harness.Ctx.Replication.RequestResync(entry, "test")
		flush(harness)
		expect(client.Boost.Get()).to.equal(true)
		local active, remaining = client.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(90)
	end)

	it("keeps ServerOnly timers, cooldowns, and receipt claims private", function()
		local harness = make()
		local player, entry, data = harness.Join()
		data.Boost.SetTimed(true, 60)
		data.Private.Boost.SetTimed(true, 120)
		harness.Data.OnCooldown(player, "Reward", 180)
		harness.Ctx.Timed.Claim(entry, "@receipt:test", 240)
		local client = connect(harness, player)
		local metadata = client.Raw.Child(Template.SESSION_ROOT).Child("Timed").Get()
		local count = 0
		for key in metadata do
			count += 1
			expect(key).to.equal(fieldId(harness, { "Boost" }))
		end
		expect(count).to.equal(1)
		expect(mirror(entry)[fieldId(harness, { "Private", "Boost" })]).to.equal(nil)
		expect(client.Raw.Child(Template.RESERVED_ROOT).Child("Timed").Get()).to.equal(nil)
	end)

	it("includes visible Session and Shared timers in the owner's mirror", function()
		local harness = make()
		local player, _, data = harness.Join()
		data.Runtime.Boost.SetTimed(true, 60)
		data.Public.Boost.SetTimed(true, 90)
		local client = connect(harness, player)
		expect((client.Runtime.Boost.Active())).to.equal(true)
		expect((client.Public.Boost.Active())).to.equal(true)
	end)

	it("rebuilds metadata from saved timers after a rejoin", function()
		local harness = make()
		local player, entry, data = harness.Join(77301)
		data.Boost.SetTimed(true, 60)
		data.Private.Boost.SetTimed(true, 120)
		entry.Profile:Save()
		local saved = harness.Fake.Persisted["Default/PLAYER_77301"]
		expect(saved[Template.SESSION_ROOT]).to.equal(nil)
		expect(saved[Template.RESERVED_ROOT].Timed.Boost).to.equal(now + 60)
		harness.Leave(player)
		now += 10
		local returning, nextEntry = harness.Join(77301)
		local client = connect(harness, returning)
		local active, remaining = client.Boost.Active()
		expect(active).to.equal(true)
		expect(remaining).to.equal(50)
		expect(mirror(nextEntry)[fieldId(harness, { "Private", "Boost" })]).to.equal(nil)
	end)

	it("reads the live deadline while a save holds its separate copy", function()
		local harness = make()
		local player, entry, data = harness.Join()
		local client = connect(harness, player)
		data.Boost.SetTimed(true, 60)
		local held = harness.Ctx.Timed.BeforeSave(entry)
		data.Boost.ExtendTimed(30)
		flush(harness)
		local _, remaining = client.Boost.Active()
		expect(remaining).to.equal(90)
		expect(entry.TimedLive.Boost).to.equal(now + 90)
		expect(entry.LiveData[Template.RESERVED_ROOT].Timed.Boost).to.equal(now + 60)
		harness.Ctx.Timed.AfterSave(entry, held)
		expect(entry.LiveData[Template.RESERVED_ROOT].Timed.Boost).to.equal(now + 90)
	end)

	it("clears a field's public deadline through ClearField", function()
		local harness = make()
		local player, entry, data = harness.Join()
		local client = connect(harness, player)
		data.Boost.SetTimed(true, 60)
		flush(harness)
		harness.Ctx.Timed.ClearField(entry, "Boost")
		flush(harness)
		expect(data.Boost.Get()).to.equal(true)
		expect((client.Boost.Active())).to.equal(false)
	end)

	it("ignores corrupt saved deadlines and refuses NaN durations before writes", function()
		local harness = make()
		local player, entry, data = harness.Join()
		local store = entry.LiveData[Template.RESERVED_ROOT].Timed
		store.Boost = math.huge
		store.Charges = 0 / 0
		store["Nested" .. string.char(31) .. "Enabled"] = "invalid"
		harness.Ctx.Timed.OnLoad(entry)
		expect(next(mirror(entry))).to.equal(nil)
		local client = connect(harness, player)
		expect((client.Boost.Active())).to.equal(false)
		local setOk = pcall(data.Boost.SetTimed, true, 0 / 0)
		local extendOk = pcall(data.Boost.ExtendTimed, 0 / 0)
		expect(setOk).to.equal(false)
		expect(extendOk).to.equal(false)
		expect(data.Boost.Get()).to.equal(false)
	end)
end
