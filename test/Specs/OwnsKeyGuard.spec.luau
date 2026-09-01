--!nonstrict
-- Owns(player, nil) and its siblings.
--
-- CHARACTERISED FROM A REAL CRASH on 2.1.1: `Monetization:229: table index is nil`,
-- raised from inside Scribe with a stack that named neither the caller nor the argument.
-- A nil key fell through `knownOwnsKeys[key]` (indexing with nil is legal and answers
-- nil) and landed on `warnedOwnsKeys[key] = true`, which is not.
--
-- The half that never showed up in a stack is worse. That line sits behind `ctx.DevMode`,
-- which is Studio-only, so a live server ran straight past it and answered FALSE: an
-- ownership gate quietly denying a player who had paid, with nothing logged anywhere.
-- Both halves are pinned below, the second one with DevMode explicitly off.

return function()
	local RunService = game:GetService("RunService")
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Client = require(ScribeRoot.Client)
	local Template = require(ScribeRoot.Internal.Template)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local itRunning = if RunService:IsRunning() then it else itSKIP

	local template = { Coins = Scribe.Int(0, { Min = 0 }) }
	local PASSES = { VIP = { Id = 111 } }

	--- The error text, or "no error" when the call returned instead of raising.
	local function raised(fn, ...): string
		local ok, err = pcall(fn, ...)
		return if ok then "no error" else tostring(err)
	end

	local function says(text: string, needle: string): boolean
		return string.find(text, needle, 1, true) ~= nil
	end

	describe("a key that is not a string", function()
		it("names the API and the argument instead of raising from inside Scribe", function()
			local harness = TestCtx.make({ Template = template, Options = { Passes = PASSES } })
			local player = harness.Join(71001)
			local text = raised(harness.Data.Owns, player, nil)
			harness.Cleanup()
			-- The old text was "table index is nil", which said nothing about the call.
			expect(
				`named={says(text, "Scribe: Owns:")} typed={says(text, "must be a string")} `
					.. `old={says(text, "table index is nil")}`
			).to.equal("named=true typed=true old=false")
		end)

		it("says which of the three APIs was called", function()
			local harness = TestCtx.make({ Template = template, Options = { Passes = PASSES } })
			local player = harness.Join(71002)
			local owns = raised(harness.Data.Owns, player, nil)
			local async = raised(harness.Data.OwnsAsync, player, nil)
			local observe = raised(harness.Data.ObserveOwned, player, nil, function() end)
			harness.Cleanup()
			expect(
				`owns={says(owns, "Scribe: Owns:")} async={says(async, "Scribe: OwnsAsync:")} `
					.. `observe={says(observe, "Scribe: ObserveOwned:")}`
			).to.equal("owns=true async=true observe=true")
		end)

		it("reports the type it got, so passing the pass Id names itself", function()
			local harness = TestCtx.make({ Template = template, Options = { Passes = PASSES } })
			local player = harness.Join(71003)
			-- Owns takes the NAME you registered, not the gamepass id. Before the guard this
			-- answered false forever and looked like a player who had not bought it.
			local text = raised(harness.Data.Owns, player, 111)
			harness.Cleanup()
			expect(`typed={says(text, "got number")} named={says(text, "Scribe: Owns:")}`).to.equal(
				"typed=true named=true"
			)
		end)

		it("RAISES WITH DEVMODE OFF, which is the live server that used to answer false", function()
			local harness = TestCtx.make({
				Template = template,
				Options = { Passes = PASSES, DevMode = false },
			})
			local player = harness.Join(71004)
			local text = raised(harness.Data.Owns, player, nil)
			harness.Cleanup()
			-- The whole point: production never reached the crashing line and silently
			-- denied instead. A guard that only fired in Studio would leave that intact.
			expect(`named={says(text, "Scribe: Owns:")} old={says(text, "table index is nil")}`).to.equal(
				"named=true old=false"
			)
		end)

		it("CONTROL: a real key still answers, so the guard did not swallow the API", function()
			local harness = TestCtx.make({ Template = template, Options = { Passes = PASSES } })
			local player = harness.Join(71005)
			local unowned = harness.Data.Owns(player, "VIP")
			local unknown = harness.Data.Owns(player, "NotAThing")
			harness.Cleanup()
			expect(`vip={tostring(unowned)} unknown={tostring(unknown)}`).to.equal("vip=false unknown=false")
		end)
	end)

	describe("the client mirror", function()
		itRunning("raises there too, where a nil key used to read as simply not owned", function()
			local harness = TestCtx.make({ Template = template, Options = { Passes = PASSES }, AutoPump = true })
			local player = harness.Join(71010)
			harness.Transport.LocalPlayer = player
			local clientData = Client.new(harness.Options, harness.Compiled)
			-- Before waitForLoaded, so it answers the caller rather than yielding first.
			local text = raised(clientData.Owns, nil)
			harness.Cleanup()
			expect(`named={says(text, "Scribe: Owns:")} typed={says(text, "must be a string")}`).to.equal(
				"named=true typed=true"
			)
		end)
	end)

	describe("what OwnsCache holds", function()
		it("stores ONLY owned keys, so absence is the not-owned answer", function()
			-- Deliberate, not an omission: writing false for every declared pass would put
			-- a key per pass per player on the wire to say nothing. Every reader tests
			-- `== true`, so absence and false are the same answer.
			local harness = TestCtx.make({ Template = template, Options = { Passes = PASSES } })
			local _player, entry = harness.Join(71020)
			local cache = entry.SessionStore[Template.SESSION_ROOT].OwnsCache
			local keys = {}
			for name, value in cache do
				table.insert(keys, `{name}={tostring(value)}`)
			end
			table.sort(keys)
			local owns = harness.Data.Owns(entry.Player, "VIP")
			harness.Cleanup()
			-- No VIP=false entry, and Owns still answers false for it.
			expect(`cache=[{table.concat(keys, ",")}] owns={tostring(owns)}`).to.equal("cache=[] owns=false")
		end)
	end)
end
