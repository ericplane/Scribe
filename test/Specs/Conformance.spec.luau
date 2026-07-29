--!nonstrict
-- The ProfileStore CONTRACT that Scribe relies on, asserted against whichever
-- implementation ConformanceStore hands us. Under Lune that is FakeProfileStore
-- (so this runs in CI on every change); in Studio with _G.ScribeConformanceReal
-- set it is the real library against real DataStores.
--
-- Every assertion here encodes something Scribe's source actually depends on, and
-- most of them exist because the fake once got it wrong and hid a real bug. Keep
-- them narrow and behavioural: this is a fidelity check, not a feature test.
return function()
	local Root = script.Parent.Parent.Parent
	local ConformanceStore = require(Root.Test.Helpers.ConformanceStore)

	local nextId = 0
	local function freshKey(): string
		nextId += 1
		-- os.time keeps runs against a real DataStore from colliding with each other.
		return `{ConformanceStore.PREFIX}{os.time()}_{nextId}`
	end

	local function newStore()
		local module = ConformanceStore.get()
		return module.New(ConformanceStore.STORE, { Coins = 0 })
	end

	describe("ProfileStore contract", function()
		it("a brand-new profile reports SessionLoadCount 1 on its first live session", function()
			local store = newStore()
			local key = freshKey()
			local profile = store:StartSessionAsync(key, {
				Cancel = function()
					return false
				end,
			})
			expect(profile).to.be.ok()
			-- Scribe compares this against 1 to decide "brand new" (Persistence isNew).
			expect(profile.SessionLoadCount).to.equal(1)
			profile:EndSession()
		end)

		it("a view reports the RAW stored count, one BELOW a live session", function()
			local store = newStore()
			local key = freshKey()

			local first = store:StartSessionAsync(key, {
				Cancel = function()
					return false
				end,
			})
			first.Data.Coins = 7
			first:EndSession()

			-- GetAsync passes EditProfile = nil, so the session-start increment never
			-- runs. Scribe must normalise this or a Mode = "NoSave" dry run of a
			-- once-loaded profile is judged brand new and SKIPS EVERY MIGRATION.
			local view = store:GetAsync(key)
			expect(view).to.be.ok()
			expect(view.SessionLoadCount).to.equal(1)

			local second = store:StartSessionAsync(key, {
				Cancel = function()
					return false
				end,
			})
			expect(second.SessionLoadCount).to.equal(2)
			second:EndSession()
		end)

		it("UserIds is empty until a save completes, then persists", function()
			local store = newStore()
			local key = freshKey()

			local profile = store:StartSessionAsync(key, {
				Cancel = function()
					return false
				end,
			})
			-- Scribe uses a non-empty UserIds to prove a prior save happened, which is
			-- what distinguishes a returning all-default player from a crashed first
			-- session. If this ever becomes non-empty before a save, that breaks.
			expect(#profile.UserIds).to.equal(0)
			profile:AddUserId(1234)
			profile:EndSession()

			local view = store:GetAsync(key)
			expect(view).to.be.ok()
			expect(#view.UserIds > 0).to.equal(true)
		end)

		it("MessageAsync does not deliver inline; delivery happens on a later save", function()
			local store = newStore()
			local key = freshKey()

			local profile = store:StartSessionAsync(key, {
				Cancel = function()
					return false
				end,
			})
			local delivered = 0
			profile:MessageHandler(function(_message, processed)
				delivered += 1
				processed()
			end)

			store:MessageAsync(key, { Hello = true })
			-- Committed to the profile's updates, NOT handed to the handler yet. Scribe's
			-- AwaitSave generation gate exists because real delivery lands inside a save.
			expect(delivered).to.equal(0)

			-- Wait for delivery rather than assuming it is synchronous. The fake
			-- persists inline, but a real Save() schedules an async UpdateAsync with a
			-- network round-trip, so a single task.wait() only ever passed against the
			-- fake. The assertion is "eventually delivered on a save", so poll for it.
			profile:Save()
			local deadline = os.clock() + 10
			while delivered == 0 and os.clock() < deadline do
				task.wait(0.1)
			end
			expect(delivered >= 1).to.equal(true)

			profile:EndSession()
		end)

		it("the session is already inactive when OnSessionEnd fires", function()
			local store = newStore()
			local key = freshKey()

			local profile = store:StartSessionAsync(key, {
				Cancel = function()
					return false
				end,
			})
			local activeDuringEnd: boolean? = nil
			profile.OnSessionEnd:Connect(function()
				activeDuringEnd = profile:IsActive()
			end)

			profile:EndSession()
			task.wait()
			-- Real ProfileStore drops the session BEFORE firing OnSessionEnd, so Scribe's
			-- teardown runs against an already-inactive profile.
			expect(activeDuringEnd).to.equal(false)
		end)

		it("redelivers an UNACKED message on a later save, but not an acked one", function()
			local store = newStore()
			local key = freshKey()

			local profile = store:StartSessionAsync(key, {
				Cancel = function()
					return false
				end,
			})

			-- Real ProfileStore's processed() only sets a lock flag; the physical
			-- sweep happens on a LATER save, so delivery is at-least-once. Scribe's
			-- receipt dedupe (ProcessedPurchaseIds) exists precisely because of this,
			-- so if the harness ever makes delivery exactly-once, the code that
			-- protects against a duplicate grant stops being exercised.
			local ackedSeen, unackedSeen = 0, 0
			profile:MessageHandler(function(message, processed)
				if message.Ack then
					ackedSeen += 1
					processed()
				else
					unackedSeen += 1
					-- deliberately NOT acked
				end
			end)

			-- Capture the baseline BEFORE saving: the fake delivers synchronously
			-- inside Save(), so reading it after would never observe a change.
			local function saveAndSettle()
				local before = ackedSeen + unackedSeen
				profile:Save()
				local deadline = os.clock() + 10
				while ackedSeen + unackedSeen == before and os.clock() < deadline do
					task.wait(0.1)
				end
				task.wait(0.2)
			end

			store:MessageAsync(key, { Ack = true })
			saveAndSettle()
			expect(ackedSeen >= 1).to.equal(true)
			local ackedAfterFirst = ackedSeen

			store:MessageAsync(key, { Ack = false })
			saveAndSettle()
			expect(unackedSeen >= 1).to.equal(true)

			-- A further save must not re-deliver the ACKED one...
			profile:Save()
			task.wait(0.5)
			expect(ackedSeen).to.equal(ackedAfterFirst)
			-- ...while the unacked one is still outstanding, so it may arrive again.
			expect(unackedSeen >= 1).to.equal(true)

			profile:EndSession()
		end)
	end)
end
