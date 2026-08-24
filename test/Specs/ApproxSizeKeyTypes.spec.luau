--!nonstrict
-- CHARACTERISATION ONLY. Pins the KEY dispatch of Util.approxSize, which is
-- partial where the VALUE dispatch is total.
--
-- The value dispatch ends in `return 4` -- charge `null` and keep walking -- for
-- userdata, functions, and anything else it does not recognise. The key dispatch
-- does not:
--
--     local keyBytes = if type(k) == "string"
--         then jsonStringBytes(k :: string)
--         else jsonNumberBytes(k :: number) + 2
--
-- `k :: number` is an ASSERTION the type checker accepts and the runtime does not
-- make good on, and jsonNumberBytes immediately does `v % 1`. Anything that is
-- neither a string nor a number RAISES there.
--
-- Util.findUnpersistable, walking the same trees, gets this right: its key check
-- is `if kt ~= "string" and kt ~= "number"` and it REPORTS rather than asserting.
-- The two functions disagree about how total a key dispatch has to be, and only
-- one of them is right.
--
-- WHY IT IS INVISIBLE. approxSize runs inside a ProfileStore signal handler
-- (Persistence:926 in onProfileSaving, :1024 in onProfileSaved), and Signal
-- handlers run on their own thread -- so the raise prints a traceback and is
-- swallowed. Nothing fails. What is lost is the estimate itself, and with it the
-- PROFILE_SIZE warning that exists to fire BEFORE the ~4 MB DataStore ceiling
-- starts failing every save. A diagnostic that disables itself without saying so
-- is worse than one that over-estimates, so the consequence is pinned below and
-- not only the return value.
--
-- WHAT THESE SPECS DO NOT PIN: what a non-string, non-number key should COST. It
-- cannot be JSON-encoded, so there is no true stored size and any figure is
-- arbitrary. Pinning one here would pin the fix's arithmetic rather than its
-- behaviour. Every assertion below is therefore "a finite estimate came back, and
-- the rest of the tree is still in it" -- true of any total dispatch, whatever it
-- charges.

return function()
	local Root = script.Parent.Parent.Parent
	local Scribe = require(Root.Scribe)
	local Util = require(Root.Scribe.Internal.Util)
	local Log = require(Root.Scribe.Internal.Log)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	-- A named verdict rather than a bare call, so a raise lands as an `equal`
	-- mismatch carrying the error text instead of escaping the test as a raise
	-- with no case name attached to it.
	local function estimate(label: string, value: any): string
		local ok, result = pcall(Util.approxSize, value)
		if not ok then
			return `{label}: raised <{tostring(result)}>`
		end
		if type(result) ~= "number" then
			return `{label}: returned a {typeof(result)}`
		end
		if result ~= result or result == math.huge or result == -math.huge then
			return `{label}: non-finite ({tostring(result)})`
		end
		return `{label}: finite`
	end

	local function sizeOrNil(value: any): number?
		local ok, result = pcall(Util.approxSize, value)
		if ok and type(result) == "number" and result == result and result < math.huge then
			return result
		end
		return nil
	end

	-- The estimate for `value` must still contain everything `baseline` costs:
	-- an odd key may be charged whatever the fix decides, but it must not cost the
	-- walk the siblings it was standing next to.
	local function stillCounts(label: string, value: any, baseline: any): string
		local got = sizeOrNil(value)
		local want = Util.approxSize(baseline)
		if got == nil then
			return `{label}: no estimate at all (want >= {want})`
		end
		if got < want then
			return `{label}: lost {want - got} bytes of the rest of the tree ({got} < {want})`
		end
		return `{label}: ok`
	end

	describe("a key that is neither a string nor a number", function()
		it("still produces an estimate for a TABLE key", function()
			-- Built directly rather than through the runner's FakeDateTime, for two
			-- reasons: the shim is not reachable as a module from a spec, and a spec
			-- that reached for it would only run headless. This IS that shape --
			-- lune/run-tests.luau:269 `dt()` writes `fields[DT_MARKER] = typeName`,
			-- where DT_MARKER is one unique empty table shared by every fake
			-- datatype -- so the assertion means the same thing in Studio, where
			-- DateTime is userdata and this shape is simply a table keyed by a table.
			local marker = {}
			local fakeDateTime = { UnixTimestampMillis = 1700000000000, [marker] = "DateTime" }
			expect(estimate("tableKey", fakeDateTime)).to.equal("tableKey: finite")
			expect(estimate("tableKeyNested", { Wrap = { Stamp = fakeDateTime } })).to.equal("tableKeyNested: finite")
		end)

		it("still produces an estimate for a BOOLEAN key", function()
			-- The case real game code reaches. A raw bag written at OnPlayerInit, in
			-- a migration, or in an offline draft is untyped: `bag[flag] = n` with a
			-- boolean flag is a plain mistake, not a shim artefact, and unlike the
			-- table key above it is reachable on real Roblox where the datatypes are
			-- userdata.
			expect(estimate("trueKey", { [true] = 1 })).to.equal("trueKey: finite")
			expect(estimate("falseKey", { [false] = 1 })).to.equal("falseKey: finite")
			expect(estimate("bothBoolKeys", { [true] = 1, [false] = 2 })).to.equal("bothBoolKeys: finite")
		end)

		it("still produces an estimate for the other key types a table accepts", function()
			-- Which types are worth covering is decided by what Lua will actually
			-- accept as a key AND what can reach a profile table:
			--
			--   * function -- a callback parked in a bag and used as an identity key.
			--     Same class exactly: neither string nor number, so the same cast.
			--   * buffer -- its own `type()`, and Scribe hands buffers to developers
			--     as the packed datatype representation, so one being used as a key
			--     is a mis-write of a value Scribe itself produced.
			--   * a Roblox datatype -- userdata in Studio, a plain table under the
			--     headless shim. Included precisely because it is the one case that
			--     exercises a DIFFERENT runtime type in each realm while being the
			--     same developer mistake in both.
			--
			-- Deliberately absent: nil (not a legal key) and NaN (`t[0/0] = 1` raises
			-- at construction, so no profile can carry one).
			expect(estimate("functionKey", { [function() end] = 1 })).to.equal("functionKey: finite")
			expect(estimate("bufferKey", { [buffer.create(4)] = 1 })).to.equal("bufferKey: finite")
			expect(estimate("datatypeKey", { [Vector3.new(1, 2, 3)] = "spawn" })).to.equal("datatypeKey: finite")
		end)

		it("keeps measuring the rest of the tree around it", function()
			-- The point of making the dispatch total is not the odd key's own cost --
			-- which is arbitrary -- but that the walk CONTINUES, so the estimate stays
			-- useful for everything else in the profile. A fix that returned early, or
			-- charged the whole table as one opaque constant, passes the cases above
			-- and fails these.
			expect(stillCounts("beside", { Coins = 1250, [true] = 1 }, { Coins = 1250 })).to.equal("beside: ok")
			local big = string.rep("x", 4096)
			expect(stillCounts("aboveIt", { Blob = big, Bag = { [true] = 1 } }, { Blob = big })).to.equal("aboveIt: ok")
			expect(stillCounts("belowIt", { Bag = { [true] = { Blob = big } } }, { Blob = big })).to.equal("belowIt: ok")
		end)

		it("leaves findUnpersistable as the thing that says it cannot be saved", function()
			-- The division of labour the fix must preserve: approxSize measures and
			-- keeps going, findUnpersistable reports. If a future change made
			-- approxSize the reporter, or made findUnpersistable tolerant, this pins
			-- which one owns the verdict.
			local found = Util.findUnpersistable({ Bag = { [true] = 1 } })
			expect(found).to.be.ok()
			expect(found.Kind).to.equal("Unserializable")
			expect(string.find(tostring(found.Detail), "unsupported key type", 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe("the consequence: the profile is still measured, so the size warning still fires", function()
		-- SIZE_WARN_BYTES is 3.5 MiB (Persistence.luau:134). These build a profile
		-- genuinely past it rather than reaching into the threshold, because the
		-- behaviour worth pinning is the real latch and not a rigged one.
		local OVERSIZE = 3.6 * 1024 * 1024

		-- Kept out of the replicated tree on purpose: a multi-megabyte string in a
		-- replicated field would be pushed through Wire on the join snapshot. It is
		-- the SAVE path that measures the profile, and ServerOnly data is on it.
		local function makeHarness(withOddKey: boolean)
			return TestCtx.make({
				Template = {
					Secret = Scribe.ServerOnly({ Blob = "" }),
					Bag = {},
				},
				Options = {
					LogLevel = "Fatal",
					OnPlayerInit = function(_player, raw)
						raw.Secret.Blob = string.rep("x", OVERSIZE)
						if withOddKey then
							-- The raw boundary is exactly where an untyped write like
							-- this lands, and nothing between here and the save path
							-- removes it: findUnpersistable REPORTS the key, it does
							-- not strip it.
							raw.Bag = { [true] = 1 }
						end
					end,
				},
			})
		end

		local function warnCount(): number
			return #Log.GetRecent({ Code = "PROFILE_SIZE" })
		end

		it("estimates a profile carrying a boolean key at all", function()
			local harness = makeHarness(true)
			local _player, entry = harness.Join(98501)
			harness.Data.Flush(_player)

			-- Persistence:928 (from the :926 measurement) and :1026 (from :1024).
			-- Both are downstream of an approxSize call on the live profile, and both
			-- are simply skipped when that call raises inside the signal handler.
			expect(`LiveSize={typeof(entry.LiveSize)}`).to.equal("LiveSize=number")
			expect(`LastSavedSize={typeof(entry.LastSavedSize)}`).to.equal("LastSavedSize=number")

			harness.Cleanup()
		end)

		it("fires PROFILE_SIZE for an oversize profile carrying a boolean key", function()
			local before = warnCount()
			local harness = makeHarness(true)
			local player = harness.Join(98502)
			harness.Data.Flush(player)

			expect(`warnings={warnCount() - before}`).to.equal("warnings=1")

			harness.Cleanup()
		end)

		it("latches that warning to once per crossing, not once per save", function()
			local before = warnCount()
			local harness = makeHarness(true)
			local player, entry = harness.Join(98503)
			harness.Data.Flush(player)
			harness.Data.Flush(player)
			harness.Data.Flush(player)

			expect(`warnings={warnCount() - before}`).to.equal("warnings=1")
			expect(`SizeWarned={tostring(entry.SizeWarned)}`).to.equal("SizeWarned=true")

			harness.Cleanup()
		end)

		it("fires it for the same oversize profile WITHOUT the odd key", function()
			-- The control. Green today and after: it proves the three rows above are
			-- red because of the key and not because the oversize rigging never
			-- reached the latch in the first place.
			local before = warnCount()
			local harness = makeHarness(false)
			local player, entry = harness.Join(98504)
			harness.Data.Flush(player)

			expect(`warnings={warnCount() - before}`).to.equal("warnings=1")
			expect(`LiveSize={typeof(entry.LiveSize)}`).to.equal("LiveSize=number")

			harness.Cleanup()
		end)
	end)

	describe("the shapes that already worked, unchanged", function()
		-- Green before the fix and green after. A total key dispatch is easy to
		-- write in a way that also frees array indices, or charges a numeric map key
		-- as an array position; these are the rows that catch that.
		it("charges string keys and array positions exactly as before", function()
			-- [1,2,3]: three values, two commas, two brackets. No key bytes.
			expect(Util.approxSize({ 1, 2, 3 })).to.equal(7)
			-- {"123":"a"} -- a numeric key OUTSIDE the array part is quoted.
			expect(Util.approxSize({ [123] = "a" })).to.equal(11)
			expect(Util.approxSize({ "a" })).to.equal(5)
			expect(Util.approxSize({ Coins = 1250 })).to.equal(2 + 7 + 1 + 4)
		end)

		it("charges nested tables and buffers exactly as before", function()
			local HttpService = game:GetService("HttpService")
			local nested = { a = { b = { c = { 1, 2 } } } }
			expect(Util.approxSize(nested)).to.equal(#HttpService:JSONEncode(nested))
			local buf = buffer.create(10)
			expect(Util.approxSize({ Packed = buf })).to.equal(2 + 8 + 1 + (#Util.base64FromBuffer(buf) + 2))
		end)

		it("still caps the walk at 64 levels", function()
			-- Two chains that differ only BELOW the cap must price identically, and
			-- both must terminate. This is the guard that keeps a cyclic or absurdly
			-- deep tree from killing the save path that walks it unprotected.
			local function chain(depth: number)
				local root = {}
				local node = root
				for _ = 1, depth do
					node.N = {}
					node = node.N
				end
				node.Leaf = 1
				return root
			end
			local a, b = sizeOrNil(chain(200)), sizeOrNil(chain(400))
			expect(`deep200={tostring(a)}`).to.equal(`deep200={tostring(b)}`)
			expect(a ~= nil).to.equal(true)
		end)
	end)
end
