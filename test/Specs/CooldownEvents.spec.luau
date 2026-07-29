--!nonstrict
-- OnCooldownEnded: the only expiry notification a cooldown gets. A cooldown holds
-- no value, so clearing it fires no Changed the way a lapsed Scribe.Timed field does.
return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local Template = require(Root.Scribe.Internal.Template)

	local COOLDOWN_PREFIX = Template.COOLDOWN_PREFIX

	-- Wind a live cooldown's stored expiry into the past so the next sweep lapses
	-- it. OnCooldown floors to 1 second, so this avoids a real wait.
	local function expire(entry: any, key: string)
		entry.LiveData[Template.RESERVED_ROOT].Timed[COOLDOWN_PREFIX .. key] = os.time() - 1
	end

	it("fires (player, key) once a cooldown lapses", function()
		local harness = TestCtx.make()
		local player, entry = harness.Join()

		local fired = {}
		harness.Data.OnCooldownEnded:Connect(function(p, key)
			table.insert(fired, { Player = p, Key = key })
		end)

		harness.Data.OnCooldown(player, "DailyReward", 3600)
		expect(harness.Data.PeekCooldown(player, "DailyReward")).to.equal(true)

		-- Still running: the sweep must not fire.
		harness.Ctx.Timed.Sweep(entry)
		expect(#fired).to.equal(0)

		expire(entry, "DailyReward")
		harness.Ctx.Timed.Sweep(entry)

		expect(#fired).to.equal(1)
		expect(fired[1].Player).to.equal(player)
		expect(fired[1].Key).to.equal("DailyReward")
		-- The key is genuinely cleared, not just announced.
		expect(harness.Data.PeekCooldown(player, "DailyReward")).to.equal(false)

		-- Exactly once: a second sweep has nothing left to lapse.
		harness.Ctx.Timed.Sweep(entry)
		expect(#fired).to.equal(1)

		harness.Cleanup()
	end)

	it("reports the bare key, and one signal covers every cooldown", function()
		local harness = TestCtx.make()
		local player, entry = harness.Join()

		local keys = {}
		harness.Data.OnCooldownEnded:Connect(function(_, key)
			table.insert(keys, key)
		end)

		harness.Data.OnCooldown(player, "Alpha", 3600)
		harness.Data.OnCooldown(player, "Beta", 3600)
		expire(entry, "Alpha")
		expire(entry, "Beta")
		harness.Ctx.Timed.Sweep(entry)

		table.sort(keys)
		expect(#keys).to.equal(2)
		-- Bare keys, with the internal "@cd|" prefix stripped.
		expect(keys[1]).to.equal("Alpha")
		expect(keys[2]).to.equal("Beta")

		harness.Cleanup()
	end)

	it("does not fire for cooldowns that lapsed while the player was offline", function()
		local harness = TestCtx.make()
		local player, entry = harness.Join()

		local fired = 0
		harness.Data.OnCooldownEnded:Connect(function()
			fired += 1
		end)

		harness.Data.OnCooldown(player, "DailyReward", 3600)
		expire(entry, "DailyReward")

		-- The load sweep clears lapsed cooldowns but stays silent: they ended while
		-- the player was away, and a joining game reads PeekCooldown for its state.
		harness.Ctx.Timed.OnLoad(entry)
		expect(fired).to.equal(0)
		expect(harness.Data.PeekCooldown(player, "DailyReward")).to.equal(false)

		harness.Cleanup()
	end)

	it("does not fire for a lapsed Scribe.Timed field, which signals via Changed", function()
		local harness = TestCtx.make()
		local _player, entry, data = harness.Join()

		local cooldowns = 0
		harness.Data.OnCooldownEnded:Connect(function()
			cooldowns += 1
		end)

		local changed = 0
		data.Booster.Changed(function()
			changed += 1
		end)

		data.Booster.SetTimed(true, 3600)
		entry.LiveData[Template.RESERVED_ROOT].Timed.Booster = os.time() - 1
		harness.Ctx.Timed.Sweep(entry)

		expect(cooldowns).to.equal(0)
		expect(changed >= 1).to.equal(true)
		expect(data.Booster.Get()).to.equal(false)

		harness.Cleanup()
	end)
end
