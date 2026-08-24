--!nonstrict
-- The ProfileStore CONTRACT that Scribe relies on, asserted against BOTH
-- implementations on every CI run: FakeProfileStore, which CI drives everywhere
-- else, and the vendored fork at src/Internal/Store, which is what ships.
--
-- Running both is the entire point and it did not used to happen. The arm switch
-- was `ConformanceStore.UseReal`, a Studio-only flag defaulting to false, so every
-- CI run compared the fake against the fake -- proving only that FakeProfileStore
-- is consistent with itself, which is the one thing that cannot drift. See
-- ConformanceStore.arms for why flipping the default was not possible and what
-- replaced it.
--
-- Every assertion here encodes something Scribe's source actually depends on, and
-- most of them exist because the fake once got it wrong and hid a real bug. Keep
-- them narrow and behavioural: this is a fidelity check, not a feature test.
--
-- TWO RULES FOR ANYTHING ADDED HERE. Every test body runs inside `contract`, and
-- every wait goes through `ctx.Wait` / `ctx.Until`. A raw `task.wait` or an
-- `os.clock` deadline is harness time; against the fork arm it parks a thread the
-- simulation is not driving, and the test then fails on the runner's timeout
-- rather than on an assertion -- which proves nothing.
return function()
	local Root = script.Parent.Parent.Parent
	local ConformanceStore = require(Root.Test.Helpers.ConformanceStore)

	local nextId = 0
	local function freshKey(): string
		nextId += 1
		-- os.time keeps runs against a real DataStore from colliding with each other.
		return `{ConformanceStore.PREFIX}{os.time()}_{nextId}`
	end

	for _, arm in ConformanceStore.arms() do
		--- One test, run against one arm.
		---
		--- `Finish` runs whether the body passed or failed, because the fork arm
		--- installs a modelled DataStore over the shared harness service and leaving
		--- that installed would make every later spec in the run read from a dead
		--- universe. The failure is re-raised afterwards with level 0, so the message
		--- the runner prints is still the assertion's own.
		describe(`ProfileStore contract ({arm.Name})`, function()
			-- An arm that cannot be built on this host reports SKIP rather than failing
			-- twenty times over. Only the fork arm is ever unavailable, and only under
			-- Studio, where there is no way to fork-load the real store; ConformanceStore
			-- decides it, because that is where the dependency is.
			--
			-- BOTH OF THESE MUST STAY INSIDE THIS CALLBACK. TestEZ binds `it` and `itSKIP`
			-- to the node whose environment they were read from: addChild closes over
			-- `currentNode` (TestPlan.lua:26) and TestNode:expand setfenv's this callback
			-- into a fresh environment carrying the describe's own pair. Hoisting either
			-- line above the describe silently registers every test on the CONFORMANCE
			-- root instead, where the two arms share a name and the second one raises
			-- "Duplicate it block found" during planning. The headless shim does not
			-- reproduce that, so it only shows up in Studio.
			local itArm = if arm.Ready then it else itSKIP

			local function contract(name: string, body: (any) -> ())
				itArm(name, function()
					local ctx = arm.New()
					local ok, err = pcall(function()
						ctx.Run(function()
							body(ctx)
						end)
					end)
					ctx.Finish()
					if not ok then
						error(err, 0)
					end
				end)
			end

			contract("a brand-new profile reports SessionLoadCount 1 on its first live session", function(ctx)
				local store = ctx.Store
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

			contract("a view reports the RAW stored count, one BELOW a live session", function(ctx)
				local store = ctx.Store
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
				-- ...and the named accessor is what makes that difference stop being the
				-- caller's problem. A view and a live join of the same profile must agree
				-- once normalized, or a Mode = "NoSave" dry run judges the profile brand new
				-- and skips every migration it exists to exercise.
				expect(second:SessionsStarted()).to.equal(2)
				expect(view:SessionsStarted()).to.equal(2)
				second:EndSession()
			end)

			describe("the offline compare-and-set", function()
				--- A key with stored data and no live session, plus the fingerprint a
				--- caller would have read from it.
				local function offlineKey(ctx, store)
					local key = freshKey()
					local first = store:StartSessionAsync(key, {
						Cancel = function()
							return false
						end,
					})
					first.Data.Coins = 100
					first:EndSession()
					ctx.Wait(0.1)
					local view = store:GetAsync(key)
					return key,
						view,
						{
							SessionLoadCount = view.SessionLoadCount,
							LastUpdate = view.LastUpdate,
							WriteIndex = view.WriteIndex,
						}
				end

				contract("writes when the fingerprint still matches, and refuses when it does not", function(ctx)
					local store = ctx.Store
					local key, _view, expected = offlineKey(ctx, store)

					expect(store:UpdateOfflineAsync(key, expected, { Coins = 555 })).to.equal("Written")
					expect(store:GetAsync(key).Data.Coins).to.equal(555)
					-- The SAME fingerprint a second time is now stale.
					expect(store:UpdateOfflineAsync(key, expected, { Coins = 999 })).to.equal("Changed")
					expect(store:GetAsync(key).Data.Coins).to.equal(555)
				end)

				contract("refuses the second of two writers off one snapshot", function(ctx)
					-- The money property, and the one a LastUpdate-only fingerprint could
					-- not keep: os.time() has one-second granularity, so two commits inside
					-- the same second were indistinguishable from no commit at all.
					local store = ctx.Store
					local key, _view, expected = offlineKey(ctx, store)

					local first = store:UpdateOfflineAsync(key, expected, { Coins = 111 })
					local second = store:UpdateOfflineAsync(key, expected, { Coins = 222 })
					expect(`first={first} second={second} coins={store:GetAsync(key).Data.Coins}`).to.equal(
						"first=Written second=Changed coins=111"
					)
				end)

				contract("sees a view SetAsync, which stamps no LastUpdate at all", function(ctx)
					local store = ctx.Store
					local key, view, expected = offlineKey(ctx, store)

					view.Data.Coins = 777
					view:SetAsync()
					ctx.Wait(0.1)

					expect(store:UpdateOfflineAsync(key, expected, { Coins = 999 })).to.equal("Changed")
					expect(store:GetAsync(key).Data.Coins).to.equal(777)
				end)

				contract(
					"refuses while a session is live, and reports Missing for a key that is not there",
					function(ctx)
						local store = ctx.Store
						local key, _view, expected = offlineKey(ctx, store)

						local live = store:StartSessionAsync(key, {
							Cancel = function()
								return false
							end,
						})
						expect(store:UpdateOfflineAsync(key, expected, { Coins = 1 })).to.equal("SessionActive")
						live:EndSession()
						ctx.Wait(0.1)

						expect(
							store:UpdateOfflineAsync(
								freshKey(),
								{ SessionLoadCount = 0, LastUpdate = 0, WriteIndex = 0 },
								{
									Coins = 1,
								}
							)
						).to.equal("Missing")
					end
				)

				contract("takes a session lock that is older than the staleness allowance, and only then", function(ctx)
					-- The A9 rule. Opt-in via the fourth argument, evaluated inside the
					-- transform against the key's own LastUpdate -- the same test
					-- StartSessionAsync uses to steal a session it believes is dead.
					local store = ctx.Store
					local key, _view, expected = offlineKey(ctx, store)

					local live = store:StartSessionAsync(key, {
						Cancel = function()
							return false
						end,
					})
					-- A huge allowance means "nothing is ever stale": still refused.
					expect(store:UpdateOfflineAsync(key, expected, { Coins = 1 }, { StaleSessionAfter = 1e9 })).to.equal(
						"SessionActive"
					)
					-- The comparison is `elapsed <= allowance` means LIVE, matching
					-- StartSessionAsync's `elapsed > ASSUME_DEAD` means dead -- so a zero
					-- allowance still refuses at zero elapsed, and the clock has to actually
					-- cross the boundary. One real second is enough at os.time()'s
					-- resolution, and waiting is the only way to make this branch true
					-- against a real DataStore in the Studio arm.
					ctx.Wait(1.1)
					-- ...and the outcome is Changed, not Written, which is the point: the
					-- staleness allowance opens the LOCK, it does not bypass the
					-- compare-and-set. The session's own start moved the fingerprint.
					expect(store:UpdateOfflineAsync(key, expected, { Coins = 1 }, { StaleSessionAfter = 0 })).to.equal(
						"Changed"
					)
					live:EndSession()
				end)
			end)

			contract("a session whose key is REMOVED under it ends, and no save brings the key back", function(ctx)
				-- The GDPR-adjacent property. RemoveAsync bypasses the session lock, so an
				-- erase can land while a session is live -- and what happens next decides
				-- whether the erase holds.
				--
				-- In the fork it used to hold in the worst possible way: the removed key
				-- reaches the save transform with no MetaData, indexing it threw INSIDE
				-- UpdateAsync's own pcall, and the save neither wrote nor released. Every
				-- autosave repeated that, so the session stayed ACTIVE indefinitely,
				-- silently discarding every write. Measured at 200 virtual seconds with a
				-- 30 s autosave period.
				--
				-- Both halves are asserted because both can regress independently: the
				-- session must END (or the holder wedges) and the key must STAY ABSENT (or
				-- an erased user is recreated, and Data.GetOffline answers as though the
				-- erase never happened -- measured, when the abort was left out).
				local store = ctx.Store
				local key = freshKey()
				local profile = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				profile.Data.Coins = 42
				profile:Save()
				ctx.Wait(0.2)
				expect(store:GetAsync(key)).to.be.ok()

				-- The THIRD refusal path, and the only one of the three that is a SAVE.
				--
				-- SaveProfileAsync declines here too (AbortWrite, ProfileStore.luau:1017):
				-- committing would recreate the key as a GlobalUpdates-only stub and answer
				-- Data.GetOffline as though the erase had not happened. Like the other two
				-- declines it returns nil out of the transform, and until Tier B that was
				-- indistinguishable from a failed call -- so an ERASE degraded service health,
				-- and enough of them would flip the store to critical state.
				--
				-- Asserted here rather than inferred from the other two. They share one branch
				-- in UpdateAsync today, so pinning either pins the code; what this pins is that
				-- THIS path still routes through it, which a future save-specific reporting
				-- path would silently change.
				local errors = 0
				local errorWatch = ctx.Module.OnError:Connect(function()
					errors += 1
				end)
				store:RemoveAsync(key)
				ctx.Wait(0.2)
				profile:Save()
				ctx.Wait(0.5)

				errorWatch:Disconnect()
				expect(`active={profile:IsActive()} key={store:GetAsync(key) ~= nil} errors={errors}`).to.equal(
					"active=false key=false errors=0"
				)
			end)

			contract("refuses a message past the queue cap rather than dropping the oldest", function(ctx)
				-- The cap exists in the real store (1,000 undelivered messages per key) and
				-- used to be enforced by `table.remove(update_list, 1)` -- dropping the
				-- OLDEST entry and returning true. Scribe's gift delivery treats that true
				-- as durable and clears the buyer's escrow, so a purchased gift could be
				-- destroyed with nothing recording it.
				--
				-- FakeProfileStore's mailbox was UNBOUNDED, which is why no CI spec could
				-- express the bug or catch a broken fix. This holds both to the bound, and
				-- to the two halves that matter: the refusal is REPORTED, and the messages
				-- already queued are the ones that survive.
				local store, module = ctx.Store, ctx.Module
				local key = freshKey()
				module.SetConstant("MAX_MESSAGE_QUEUE", 3)

				local results = {}
				for i = 1, 5 do
					local ok, reason = store:MessageAsync(key, { Seq = i })
					table.insert(results, if ok then "y" else `n:{tostring(reason)}`)
				end
				module.SetConstant("MAX_MESSAGE_QUEUE", 1000)

				expect(table.concat(results, ",")).to.equal("y,y,y,n:QueueFull,n:QueueFull")

				-- The survivors are the FIRST three, not the last three.
				local seen = {}
				local profile = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				profile:MessageHandler(function(message, processed)
					table.insert(seen, tostring(message.Seq))
					processed()
				end)
				ctx.Wait(0.3)
				profile:Save()
				ctx.Wait(0.3)
				table.sort(seen)
				expect(table.concat(seen, ",")).to.equal("1,2,3")
				profile:EndSession()
			end)

			contract("MessageAsync: a first-attempt QueueFull is PROVABLY CLEAN, a write is not", function(ctx)
				-- THE THIRD RETURN, and Scribe spends real money on it. `deliverGift`
				-- hands a paid gift credit back only where the store says nothing can
				-- have been written; every other answer keeps the credit spent. So the
				-- fake and the fork have to agree on this value, and the fake is what
				-- every gift spec in the suite actually runs against.
				--
				-- Two rows, because both directions cost. A full inbox refused on the
				-- FIRST attempt wrote nothing -- the transform ran, saw the cap, set
				-- AbortWrite -- and must be clean, or the ordinary full-inbox refund
				-- silently starts eating credits. A send that SUCCEEDED must never
				-- claim it, which is what keeps "absent means not clean" safe.
				--
				-- What is NOT here: a QueueFull that follows a committed attempt inside
				-- ONE call, which is the ambiguous shape and the one that double-granted.
				-- The fake cannot produce it -- one call of it is one attempt and cannot
				-- loop -- so it is pinned against the fork alone, in StoreAccessors.spec,
				-- with the sim's Indeterminate fault supplying the lost reply.
				local store, module = ctx.Store, ctx.Module
				local key = freshKey()
				module.SetConstant("MAX_MESSAGE_QUEUE", 1)

				local wroteOk, wroteReason, wroteClean = store:MessageAsync(key, { Seq = 1 })
				local refusedOk, refusedReason, refusedClean = store:MessageAsync(key, { Seq = 2 })
				module.SetConstant("MAX_MESSAGE_QUEUE", 1000)

				expect(`{tostring(wroteOk)}/{tostring(wroteReason)}`).to.equal("true/nil")
				expect(wroteClean == true).to.equal(false)
				expect(`{tostring(refusedOk)}/{tostring(refusedReason)}/{tostring(refusedClean)}`).to.equal(
					"false/QueueFull/true"
				)
			end)

			contract("OnSettled fires once per save call, with the outcome, on success and on failure", function(ctx)
				-- The contract Scribe's in-flight save counter is built on. Persistence
				-- connects OnSettled and decrements `entry.SavesInFlight` there, with a comment
				-- saying why OnAfterSave cannot do it: OnAfterSave fires only on success, so a
				-- failing save would leak a count forever.
				--
				-- That counter is not bookkeeping. `SavesInFlight == 0` is one of the three
				-- terms in the durability predicate `Data.Flush` answers from, and
				-- Monetization requires it before acknowledging a duplicate receipt as
				-- GRANTED. A store that stops firing this leaves the count pinned above zero,
				-- so Flush never reports durable and every duplicate receipt takes the
				-- AwaitSave path -- silently, because nothing else reads the counter.
				--
				-- Deleting the fork's fire was a surviving mutation: CI drives the fake, which
				-- fires it, so the fork's copy had nothing holding it.
				local store = ctx.Store
				local key = freshKey()
				local profile = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				profile:AddUserId(1234)
				profile.Data.Coins = 5

				local settles, outcomes = 0, {}
				local connection = profile.OnSettled:Connect(function(_saveContext, settled)
					settles += 1
					table.insert(outcomes, tostring(settled))
				end)
				profile:Save()
				ctx.Until(function()
					return settles > 0
				end, 10)
				connection:Disconnect()
				profile:EndSession()

				expect(`settles={settles} outcome={outcomes[1]}`).to.equal("settles=1 outcome=Saved")
			end)

			contract("a template buffer is COPIED into a profile, never aliased", function(ctx)
				-- Scribe's persistent template contains buffers: Template.luau lists `buffer`
				-- among the types that persist, a datatype field packs to one, and a
				-- Scribe.Big stores one. So "how does the store copy a buffer" is a live
				-- question about real profile data, not a hypothetical.
				--
				-- Two copies have to be real copies. The template -> Data copy, or every
				-- profile in the server shares one buffer and a write through any of them is
				-- a write through all of them AND through the template itself, which then
				-- seeds every future profile with the last player's bytes. And the
				-- Data -> LastSavedData copy, which is what Scribe's wipe guard diffs against
				-- live data -- aliased, it diffs live against live and can never trip.
				--
				-- Its own store, because the buffer only needs to exist for this test and a
				-- shared template would put one in front of every other assertion in the file.
				local template = buffer.fromstring("scribe-conformance-blob")
				local store = ctx.Module.New("ScribeConformanceBuffers", { Blob = template })
				local key = freshKey()

				local profile = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				profile:AddUserId(1234)
				local fromTemplate = rawequal(profile.Data.Blob, template)
				local fromLastSaved = rawequal(profile.LastSavedData.Blob, profile.Data.Blob)

				-- The RECONCILE path as well as the mint path. They are different functions
				-- with the same bug, and a returning profile written before the field
				-- existed reaches its buffer through this one -- which is the commoner case
				-- in a live game, because the mint path only runs once per player ever.
				profile.Data.Blob = nil
				profile:Reconcile()
				local fromReconcile = rawequal(profile.Data.Blob, template)
				profile:EndSession()

				expect(`templateAlias={fromTemplate} lastSavedAlias={fromLastSaved} reconcileAlias={fromReconcile}`).to.equal(
					"templateAlias=false lastSavedAlias=false reconcileAlias=false"
				)
			end)

			contract("BeginClose stops new sessions; AwaitClose releases what is still held", function(ctx)
				-- The shutdown handshake Scribe's whole drain is built on, held to one
				-- contract on both implementations.
				--
				-- Persistence.Shutdown guards each call with `type(...) == "function"`, so for
				-- as long as FakeProfileStore did not have them the handshake was two guarded
				-- calls to nothing on every CI run: deleting either call from Shutdown left
				-- 1347/0/7. The fake has them now, which is what makes this test possible on
				-- the fake arm -- and running it on both arms is what stops the fake's version
				-- drifting into something the fork does not do.
				--
				-- Two properties, because they fail independently. BeginClose stops new work
				-- starting, or the drain waits for sessions it just admitted; AwaitClose ends
				-- what is still held AND leaves its last write on disk, which is the whole
				-- reason a shutdown drain exists.
				local store, module = ctx.Store, ctx.Module
				local key = freshKey()
				local profile = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				profile:AddUserId(1234)
				profile.Data.Coins = 61
				-- Saved BEFORE closing, so the key genuinely has data to read. Without this
				-- the view assertion below passes for the wrong reason -- a key that has
				-- never been written answers nil whether or not anything is gating it, and
				-- both GetAsync mutations survived the first draft of this test because of
				-- exactly that.
				profile:SaveAwait()
				local viewOpen = store:GetAsync(key)

				module.BeginClose()
				local refused = store:StartSessionAsync(freshKey(), {
					Cancel = function()
						return false
					end,
				})
				-- Views are refused while closing as well as sessions. Asserted rather than
				-- assumed: it is the one point of this contract the fake got wrong when it
				-- was first taught these methods, and only the fork arm said so.
				local viewClosed = store:GetAsync(key)

				module.AwaitClose()
				local activeAfter = profile:IsActive()
				local saved = profile.LastSavedData

				expect(
					`readable={viewOpen and viewOpen.Data and viewOpen.Data.Coins} refused={refused == nil} `
						.. `viewClosed={viewClosed == nil} active={activeAfter} coins={saved and saved.Coins}`
				).to.equal("readable=61 refused=true viewClosed=true active=false coins=61")
			end)

			contract("a refused write is not reported as a DataStore error", function(ctx)
				-- Both refusals below are Scribe patches to the store, and both work the same
				-- way: the transform returns nil so that a refusal writes nothing at all. A nil
				-- return is also what a FAILED call produces, and telling those two apart is
				-- the whole of this test.
				--
				-- It matters because the store's OnError is not a log line. Scribe connects it
				-- at Persistence.luau, reports it as PROFILE_STORE_ERROR, counts it as
				-- DataStoreErrors and feeds it into Health -- and an Outage refuses Robux
				-- grants for every player on the server. The MESSAGE_QUEUE_FULL guide entry
				-- promises in as many words that a full inbox is "deliberately not routed to
				-- service health"; this is where that promise is checked against the code.
				local store, module = ctx.Store, ctx.Module
				local errors = 0
				local connection = module.OnError:Connect(function()
					errors += 1
				end)

				local key = freshKey()
				module.SetConstant("MAX_MESSAGE_QUEUE", 2)
				store:MessageAsync(key, { Seq = 1 })
				store:MessageAsync(key, { Seq = 2 })
				local refused = store:MessageAsync(key, { Seq = 3 })
				module.SetConstant("MAX_MESSAGE_QUEUE", 1000)

				-- The offline-CAS setup, inlined: `offlineKey` lives in the nested describe
				-- below and this test spans both refusal paths.
				local casKey = freshKey()
				local seed = store:StartSessionAsync(casKey, {
					Cancel = function()
						return false
					end,
				})
				seed.Data.Coins = 100
				seed:EndSession()
				ctx.Wait(0.1)
				local seeded = store:GetAsync(casKey)
				local expected = {
					SessionLoadCount = seeded.SessionLoadCount,
					LastUpdate = seeded.LastUpdate,
					WriteIndex = seeded.WriteIndex,
				}
				local written = store:UpdateOfflineAsync(casKey, expected, { Coins = 1 })
				-- The same fingerprint twice: the second is stale and must be refused.
				local stale = store:UpdateOfflineAsync(casKey, expected, { Coins = 2 })

				connection:Disconnect()
				expect(`refused={tostring(refused)} written={written} stale={stale} errors={errors}`).to.equal(
					"refused=false written=Written stale=Changed errors=0"
				)
			end)

			contract("UserIds is empty until a save completes, then persists", function(ctx)
				local store = ctx.Store
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
				-- The named accessor answers the same question, and is what Scribe actually
				-- calls. Both are asserted so a fake that got one right and the other wrong
				-- fails here rather than in a migration months later.
				expect(profile:HasCompletedSave()).to.equal(false)
				profile:AddUserId(1234)
				profile:EndSession()

				local view = store:GetAsync(key)
				expect(view).to.be.ok()
				expect(#view.UserIds > 0).to.equal(true)
				expect(view:HasCompletedSave()).to.equal(true)
			end)

			contract("the save transform reads Data AFTER OnSave, so a handler can swap it", function(ctx)
				-- The ordering Scribe's wipe guard is built on: it substitutes the last
				-- known-good snapshot for live data that looks like a wipe, from inside
				-- OnSave, and the save then writes the substitute. SetSaveSource names that
				-- contract; this is where the implementation is held to it.
				local store = ctx.Store
				local key = freshKey()

				local profile = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				profile:AddUserId(1234)
				profile.Data.Coins = 111
				local connection = profile.OnSave:Connect(function()
					profile:SetSaveSource({ Coins = 222 })
				end)
				profile:Save()
				-- Poll rather than assume: the fake persists inline, a real save is a
				-- network round trip. Same shape as the message test below.
				local stored = nil
				ctx.Until(function()
					local view = store:GetAsync(key)
					stored = view and view.Data and view.Data.Coins
					return stored == 222
				end, 10)
				connection:Disconnect()
				profile:EndSession()

				expect(stored).to.equal(222)
			end)

			contract("the per-save context names the table the write actually serialized", function(ctx)
				-- The other half of the swap contract above, and the half Scribe's
				-- durability answer rests on. The swap is per-PROFILE: the transform reads
				-- the pointer when IT runs, so a swap made by a LATER save changes what an
				-- EARLIER save writes, including one whose OnSave has already fired. A
				-- caller that decided "was my payload substituted?" at snapshot time is
				-- therefore describing a table that need not be the one that reached the
				-- key -- and Scribe answers AwaitSave, and through it a Robux receipt,
				-- off exactly that decision.
				--
				-- So the store reports the IDENTITY of what it serialized on the per-call
				-- context, at write time. Identity, not a verdict: the store knows nothing
				-- about wipe guards, and the caller compares against whatever it holds
				-- live. Asserted on both arms because the fake is what CI drives and the
				-- fork is what ships.
				local store = ctx.Store

				-- No swap: the context must name the profile's own live table.
				local plainKey = freshKey()
				local plain = store:StartSessionAsync(plainKey, {
					Cancel = function()
						return false
					end,
				})
				plain:AddUserId(1234)
				plain.Data.Coins = 5
				local plainOutcome, plainContext = plain:SaveAwait()
				expect(plainOutcome).to.equal("Saved")
				expect(type(plainContext)).to.equal("table")
				expect(plainContext.SavedSource).to.equal(plain.Data)
				plain:EndSession()

				-- Swapped: the context must name the SUBSTITUTE, by identity -- not a
				-- table that merely deep-equals it, and not the pre-swap pointer.
				local swapKey = freshKey()
				local swapped = store:StartSessionAsync(swapKey, {
					Cancel = function()
						return false
					end,
				})
				swapped:AddUserId(1234)
				swapped.Data.Coins = 111
				local before = swapped.Data
				local substitute = { Coins = 222 }
				local connection = swapped.OnSave:Connect(function()
					swapped:SetSaveSource(substitute)
				end)
				local swapOutcome, swapContext = swapped:SaveAwait()
				connection:Disconnect()
				expect(swapOutcome).to.equal("Saved")
				expect(swapContext.SavedSource).to.equal(substitute)
				expect(swapContext.SavedSource == before).to.equal(false)
				swapped:EndSession()
			end)

			contract("LastSavedData is the stored data, and is released when the owner opts out", function(ctx)
				-- Scribe reads this to baseline the wipe guard, then tells the store to stop
				-- keeping it. Both halves are contract: the handler must see the real data,
				-- and afterwards the field must be empty rather than stale or aliased to
				-- live data -- a reader that diffed live against live would never trip.
				local store = ctx.Store
				local key = freshKey()

				local profile = store:StartSessionAsync(key, {
					Cancel = function()
						return false
					end,
				})
				profile:AddUserId(1234)
				profile.Data.Coins = 41
				profile:SetRetainLastSaved(false)

				local handlerSaw = nil
				local connection = profile.OnAfterSave:Connect(function(lastSaved)
					handlerSaw = lastSaved and lastSaved.Coins
				end)
				profile:Save()
				ctx.Until(function()
					return handlerSaw ~= nil
				end, 10)
				connection:Disconnect()

				expect(handlerSaw).to.equal(41)
				expect(next(profile.LastSavedData)).to.equal(nil)
				expect(profile.LastSavedData ~= profile.Data).to.equal(true)
				profile:EndSession()
			end)

			contract("MessageAsync does not deliver inline; delivery happens on a later save", function(ctx)
				local store = ctx.Store
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
				-- network round-trip, so a single ctx.Wait() only ever passed against the
				-- fake. The assertion is "eventually delivered on a save", so poll for it.
				profile:Save()
				ctx.Until(function()
					return delivered > 0
				end, 10)
				expect(delivered >= 1).to.equal(true)

				profile:EndSession()
			end)

			contract("the session is already inactive when OnSessionEnd fires", function(ctx)
				local store = ctx.Store
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
				ctx.Wait()
				-- Real ProfileStore drops the session BEFORE firing OnSessionEnd, so Scribe's
				-- teardown runs against an already-inactive profile.
				expect(activeDuringEnd).to.equal(false)
			end)

			contract("redelivers an UNACKED message on a later save, but not an acked one", function(ctx)
				local store = ctx.Store
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
					ctx.Until(function()
						return ackedSeen + unackedSeen ~= before
					end, 10)
					ctx.Wait(0.2)
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
				ctx.Wait(0.5)
				expect(ackedSeen).to.equal(ackedAfterFirst)
				-- ...while the unacked one is still outstanding, so it may arrive again.
				expect(unackedSeen >= 1).to.equal(true)

				profile:EndSession()
			end)
		end)
	end
end
