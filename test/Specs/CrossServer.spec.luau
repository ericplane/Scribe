--!nonstrict
-- Two SERVERS, one DataStore.
--
-- Every other spec builds its harness with a private FakeProfileStore, so the
-- suite structurally could not express the single most important failure mode a
-- persistence library has: two servers contending for one profile key. These
-- specs share one fake between two harnesses, which makes Persisted,
-- ActiveProfiles (the session lock) and Mailboxes (cross-server messages) common
-- to both -- so session locking, handoff, stealing and durable messaging are
-- exercised against the real Scribe code paths rather than reasoned about in
-- comments.

return function()
	local Root = script.Parent.Parent.Parent
	local TestCtx = require(Root.Test.Helpers.TestCtx)
	local FakeProfileStore = require(Root.Test.Helpers.FakeProfileStore)

	-- Two harnesses over one disk. Cleanup order matters: the second server is
	-- torn down first so the first still owns whatever lock it started with.
	local function twoServers(options: { [string]: any }?)
		local fake = FakeProfileStore.new()
		local a = TestCtx.make({ Fake = fake, Options = options })
		local b = TestCtx.make({ Fake = fake, Options = options })
		return fake, a, b, function()
			b.Cleanup()
			a.Cleanup()
		end
	end

	describe("session locking across servers", function()
		it("refuses a second server the profile while the first holds it", function()
			local fake, a, b, cleanup = twoServers()

			local _, _, dataA = a.Join(9001)
			expect(dataA).to.be.ok()
			expect(fake.IsLocked("PLAYER_9001")).to.equal(true)

			-- Default LoadFailurePolicy is "Kick", so the contended load fails
			-- rather than hanging: the point is that it does NOT hand out a second
			-- live tree over the same key.
			local _, entryB, dataB = b.TryJoin(9001)
			expect(dataB).to.equal(nil)
			expect(entryB).to.equal(nil)

			cleanup()
		end)

		it("hands the profile over once the first server releases it", function()
			local fake, a, b, cleanup = twoServers()

			local playerA, _, dataA = a.Join(9002)
			dataA.Coins.Set(777)
			a.Leave(playerA) -- EndSession: final save, lock released
			expect(fake.IsLocked("PLAYER_9002")).to.equal(false)

			local _, _, dataB = b.Join(9002)
			expect(dataB).to.be.ok()
			expect(dataB.Coins.Get()).to.equal(777)

			cleanup()
		end)
	end)

	describe("session stealing", function()
		it("ends the incumbent session and does NOT persist its unsaved writes", function()
			local fake, a, b, cleanup = twoServers()

			local playerA, entryA, dataA = a.Join(9003)
			-- Save a known baseline, then write past it WITHOUT saving.
			dataA.Coins.Set(100)
			a.Data.Flush(playerA)
			dataA.Coins.Set(555)

			-- Another server force-loads the key. ProfileStore drops the superseded
			-- session and fires OnSessionEnd with no final save -- writing there
			-- would clobber the new owner.
			expect(fake.StealSession("PLAYER_9003")).to.equal(true)

			expect(entryA.State).to.equal("SessionEnded")
			expect(fake.IsLocked("PLAYER_9003")).to.equal(false)

			-- The unsaved 555 must not have reached the disk; the saved 100 must.
			local _, _, dataB = b.Join(9003)
			expect(dataB.Coins.Get()).to.equal(100)

			cleanup()
		end)

		it("marks the teardown as a steal, not a local session end", function()
			local fake, a, _, cleanup = twoServers()

			local _, entryA = a.Join(9004)
			-- Scribe distinguishes "we ended this" from "someone took it" via
			-- LocalSessionEnd; only the remote case is a steal.
			expect(entryA.LocalSessionEnd).never.to.equal(true)
			fake.StealSession("PLAYER_9004")
			expect(entryA.SessionStolen).to.equal(true)

			cleanup()
		end)

		it("frees the key for the stealing server to load", function()
			local fake, a, b, cleanup = twoServers()

			a.Join(9005)
			local _, _, blocked = b.TryJoin(9005)
			expect(blocked).to.equal(nil) -- locked

			fake.StealSession("PLAYER_9005")

			local _, _, dataB = b.Join(9005)
			expect(dataB).to.be.ok()

			cleanup()
		end)
	end)

	describe("durable cross-server messaging", function()
		it("delivers a message sent from one server to a session live on the other", function()
			local _, a, b, cleanup = twoServers()

			local playerB = b.Join(9006)
			local received = {}
			b.Data.OnMessage:Connect(function(player, message)
				table.insert(received, { UserId = player.UserId, Message = message })
			end)

			expect(a.Data.SendMessage(9006, { Kind = "Hello", N = 42 })).to.equal(true)

			-- MessageAsync only COMMITS; ProfileStore delivers inside a later save,
			-- which is exactly why this needs a shared mailbox to test at all.
			b.Data.Flush(playerB)

			expect(#received).to.equal(1)
			expect(received[1].UserId).to.equal(9006)
			expect(received[1].Message.Kind).to.equal("Hello")
			expect(received[1].Message.N).to.equal(42)

			cleanup()
		end)

		it("queues a message for an offline recipient and delivers it on their next load", function()
			local _, a, b, cleanup = twoServers()

			-- Nobody is online for 9007 anywhere.
			expect(a.Data.SendMessage(9007, { Kind = "Offline" })).to.equal(true)

			local received = {}
			b.Data.OnMessage:Connect(function(_, message)
				table.insert(received, message)
			end)

			local playerB = b.Join(9007)
			b.Data.Flush(playerB)

			expect(#received).to.equal(1)
			expect(received[1].Kind).to.equal("Offline")

			cleanup()
		end)
	end)
end
