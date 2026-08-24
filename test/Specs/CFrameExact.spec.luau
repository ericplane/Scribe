--!nonstrict
-- OPT-IN FULL-PRECISION CFrame: `Scribe.CFrame(default, { Precision = "exact" })`.
--
-- THE ONLY QUESTION THAT MATTERS HERE IS WHETHER THE PRECISION IS REAL, and that
-- is the reason for the shape of this file. Counting bytes proves a new branch got
-- taken; it says nothing about whether the branch preserves anything the old one
-- lost. So the centrepiece (R2) measures BOTH paths against the same original with
-- one tolerance, chosen so the default path FAILS it and the exact path PASSES --
-- a test that would go red if `Precision = "exact"` silently fell through to the
-- quaternion, which is exactly the decoration this is written to avoid.
--
-- MODELLING NOTE, and it is load-bearing. Roblox stores CFrame components as f32.
-- The headless harness stores them as f64, so a CFrame built here from arbitrary
-- doubles is NOT a CFrame Roblox could hand you, and packing it into f32 would lose
-- something real Roblox never had. Every rotation below is therefore rounded
-- through f32 first (see `roblovian`), which is the state a real CFrame is already
-- in. Skip that step and the exact path looks lossy for a reason that is the
-- harness's, not the codec's.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot)
	local Template = require(ScribeRoot.Internal.Template)
	local Marker = require(ScribeRoot.Internal.Marker)
	local TestCtx = require(Root.Test.Helpers.TestCtx)

	local Datatypes = Scribe.Datatypes

	-- Restated rather than imported, for the reason WireDense.spec gives: a test
	-- that read the codec's own constants could not catch the codec redefining
	-- them. These ARE the persisted format.
	local TAG_FULL = 254
	local TAG_QUAT = 255
	local LEN_AXIS, LEN_QUAT, LEN_FULL = 13, 29, 49

	-- The tolerance the two paths are separated by. Between the quaternion path's
	-- error (~1e-7, an f32 mantissa's worth, propagated through a re-derivation)
	-- and the exact path's (0). Not a round number picked to pass: R2 asserts the
	-- measured quaternion error EXCEEDS it, so a codec that quietly got better
	-- would fail this file rather than sail through it.
	local TOL = 1e-9

	local scratch = buffer.create(4)
	local function asF32(n: number): number
		buffer.writef32(scratch, 0, n)
		return buffer.readf32(scratch, 0)
	end

	--- A CFrame in the state real Roblox would have handed you: every one of the
	--- twelve components exactly representable in f32.
	local function roblovian(cf: CFrame): CFrame
		local c = { cf:GetComponents() }
		for i = 1, 12 do
			c[i] = asF32(c[i])
		end
		return CFrame.new(table.unpack(c))
	end

	--- The largest absolute difference across all twelve components. This is the
	--- measurement the whole file turns on, so it deliberately compares POSITION
	--- and ROTATION together: a path that preserved one and lost the other would
	--- still be lossy.
	local function maxDelta(a: CFrame, b: CFrame): number
		local ca, cb = { a:GetComponents() }, { b:GetComponents() }
		local worst = 0
		for i = 1, 12 do
			worst = math.max(worst, math.abs(ca[i] - cb[i]))
		end
		return worst
	end

	local function roundTrip(cf: CFrame, precision: string?): (CFrame, number, number)
		local packed = Datatypes.Pack("CFrame", cf, precision)
		local back = Datatypes.Unpack("CFrame", packed)
		return back, maxDelta(cf, back), buffer.len(packed)
	end

	--- Assert with the measured number in the failure text. `expect(x < TOL)` tells
	--- you a boolean was false; this tells you what the error actually was, which is
	--- the only thing worth knowing when a precision test goes red.
	local function assertDelta(label: string, actual: number, cmp: string, bound: number)
		local ok = if cmp == "<=" then actual <= bound else actual > bound
		if not ok then
			error(`{label}: measured max component delta {actual}, expected {cmp} {bound}`, 2)
		end
	end

	--- Assert that declaring `field` is refused, AND refused for the stated reason.
	--- Same argument WireFloat.spec makes: a bare `.to.throw()` passes just as
	--- happily when the guard is deleted and the next line crashes instead.
	local function refuses(field: any, needle: string)
		local ok, err = pcall(function()
			TestCtx.make({ Template = { N = field } }).Cleanup()
		end)
		if ok then
			error(`expected a refusal naming "{needle}", but the template compiled`, 2)
		end
		if not string.find(tostring(err), needle, 1, true) then
			error(`expected a refusal naming "{needle}", got: {tostring(err)}`, 2)
		end
	end

	-- An arbitrary rotation: not axis-aligned, not a nice angle, no zero components
	-- to let a broken path coast. Built from a normalized quaternion so it is a
	-- genuine rotation matrix, then dropped to f32 so it is a genuine ROBLOX one.
	local TILTED = roblovian(CFrame.new(12.5, -3.25, 400.125, 0.3, 0.5, 0.2, 0.78))

	----------------------------------------------------------------------------
	-- R1. THE BYTES -- and above all, the bytes that must NOT have moved.
	----------------------------------------------------------------------------

	describe("the layout", function()
		it("leaves both default paths exactly where they were", function()
			-- The whole feature is additive or it is a data-loss bug. An undeclared
			-- CFrame must pack the bytes it packed yesterday, to the byte.
			expect(buffer.len(Datatypes.Pack("CFrame", CFrame.new(5, 10, 15)))).to.equal(LEN_AXIS)
			expect(buffer.len(Datatypes.Pack("CFrame", TILTED))).to.equal(LEN_QUAT)
			-- And passing the argument as nil is the same as not passing it: the
			-- signature grew, the behaviour did not.
			expect(buffer.len(Datatypes.Pack("CFrame", TILTED, nil))).to.equal(LEN_QUAT)
			expect(buffer.tostring(Datatypes.Pack("CFrame", TILTED, nil))).to.equal(
				buffer.tostring(Datatypes.Pack("CFrame", TILTED))
			)
		end)

		it("packs a declared-exact CFrame into 49 bytes, tagged 254", function()
			local packed = Datatypes.Pack("CFrame", TILTED, "exact")
			expect(buffer.len(packed)).to.equal(LEN_FULL)
			expect(buffer.readu8(packed, 0)).to.equal(TAG_FULL)
		end)

		it("cannot collide with anything already persisted, by tag AND by length", function()
			-- The additivity argument, asserted rather than asserted-in-prose. No
			-- default pack over a corpus spanning both old paths produces the new
			-- tag or the new length, so no buffer written before this existed can be
			-- mistaken for one written after it.
			local corpus = {
				CFrame.new(),
				CFrame.new(1, 2, 3),
				CFrame.new(-4096, 0.5, 4096),
				TILTED,
				roblovian(CFrame.new(0, 0, 0, 0.7071068, 0, 0, 0.7071068)),
				roblovian(CFrame.fromMatrix(Vector3.new(1, 1, 1), Vector3.new(0, 0, 1), Vector3.new(0, 1, 0))),
			}
			for _, cf in corpus do
				local packed = Datatypes.Pack("CFrame", cf)
				local length, tag = buffer.len(packed), buffer.readu8(packed, 0)
				expect(length == LEN_AXIS or length == LEN_QUAT).to.equal(true)
				expect(length).never.to.equal(LEN_FULL)
				expect(tag).never.to.equal(TAG_FULL)
			end
		end)
	end)

	----------------------------------------------------------------------------
	-- R2. THE PRECISION IS REAL. This is the test the feature exists for.
	----------------------------------------------------------------------------

	describe("the precision it actually buys", function()
		it("keeps every component the quaternion path loses", function()
			local _, quatDelta, quatBytes = roundTrip(TILTED, nil)
			local _, exactDelta, exactBytes = roundTrip(TILTED, "exact")

			-- The default really did take the lossy path (not the 13-byte one, which
			-- would make the comparison below meaningless).
			expect(quatBytes).to.equal(LEN_QUAT)
			expect(exactBytes).to.equal(LEN_FULL)

			-- ONE TOLERANCE, BOTH PATHS. The default fails it; the exact one passes.
			assertDelta("quaternion path", quatDelta, ">", TOL)
			assertDelta("exact path", exactDelta, "<=", 0)

			-- Stated the other way round, so a future change that made BOTH paths
			-- exact (or both lossy) cannot leave this file green.
			expect(exactDelta < quatDelta).to.equal(true)
		end)

		it("is bit-exact, not merely tighter -- the components come back identical", function()
			-- `<= 0` above is the strongest tolerance there is, but a reader can miss
			-- that. Say it as identity, component by component, so the guarantee in
			-- the docs is the guarantee in the test.
			local back = Datatypes.Unpack("CFrame", Datatypes.Pack("CFrame", TILTED, "exact"))
			local a, b = { TILTED:GetComponents() }, { back:GetComponents() }
			for i = 1, 12 do
				expect(b[i]).to.equal(a[i])
			end
		end)

		it("re-encodes to the same bytes, so an exact field is byte-canonical", function()
			-- The property Node.canonicalDatatype leans on: pack -> unpack -> pack is
			-- a fixed point on this path. It is NOT one on the quaternion path, which
			-- is why the codec header says packing is not byte-canonical in general.
			local once = Datatypes.Pack("CFrame", TILTED, "exact")
			local twice = Datatypes.Pack("CFrame", Datatypes.Unpack("CFrame", once), "exact")
			expect(buffer.tostring(twice)).to.equal(buffer.tostring(once))
		end)

		it("survives a rotation with no friendly components at all", function()
			-- A guard that passes on one lucky constant is not a guard. Sweep a set of
			-- unrelated rotations and require the same separation on every one.
			--
			-- The `expect(quatBytes).to.equal(LEN_QUAT)` line below is not ceremony:
			-- the first draft of this list contained { 0.5, -0.5, 0.5, 0.5 }, which is
			-- a 120-degree turn about (1,-1,1) and therefore PERMUTES THE AXES -- an
			-- axis-aligned rotation wearing an arbitrary-looking quaternion. It took
			-- the 13-byte path, and without that assertion this test would have been
			-- silently comparing the exact path against the wrong default.
			local quats = {
				{ 0.1, 0.2, 0.3, 0.927 },
				{ -0.44, 0.61, -0.13, 0.65 },
				{ 0.21, 0.34, -0.55, 0.73 },
				{ 0.03, 0.99, -0.02, 0.13 },
			}
			-- WHY THE SEPARATION IS ASSERTED OVER THE SET AND NOT PER ROTATION. Whether
			-- any GIVEN rotation survives the quaternion path is an f32 accident, not a
			-- property of the codec. On real Roblox both the input matrix and the rebuilt
			-- one are f32, so the re-derivation perturbs each component by 0-3 ULPs and 0
			-- is a common outcome: measured in Studio, 3,848 of 20,000 random rotations
			-- (19.2%) round-trip EXACTLY, this list's fourth entry among them. Headless,
			-- FakeCFrame keeps components in f64, so the rebuilt matrix essentially never
			-- equals the f32-rounded original and `quatDelta > 0` held by construction --
			-- which is how a per-rotation `> TOL` survived review. It was asserting the
			-- harness's float width, and it fails in Studio on a rotation the codec
			-- handled perfectly.
			--
			-- Do not repair this by hunting for four rotations that are lossy on both
			-- hosts: that constant is a landmine for the next change to Roblox's CFrame
			-- maths. What the file is FOR -- catching `Precision = "exact"` silently
			-- falling through to the quaternion -- needs only that the exact path is never
			-- worse and that the two paths are still measurably different SOMEWHERE.
			local lossy = 0
			for _, q in quats do
				local cf = roblovian(CFrame.new(7.75, -0.5, 1024.25, q[1], q[2], q[3], q[4]))
				local _, quatDelta, quatBytes = roundTrip(cf, nil)
				local _, exactDelta = roundTrip(cf, "exact")
				expect(quatBytes).to.equal(LEN_QUAT)
				assertDelta(`exact path {q[1]},{q[2]},{q[3]},{q[4]}`, exactDelta, "<=", 0)
				-- Per rotation: the exact path is never the worse of the two.
				assertDelta(`exact vs quaternion {q[1]},{q[2]},{q[3]},{q[4]}`, exactDelta, "<=", quatDelta)
				if quatDelta > TOL then
					lossy += 1
				end
			end
			-- Over the set: the two paths are still distinguishable. A codec that made
			-- the default lossless, or routed exact into it, drops this to zero.
			expect(`lossy={lossy > 0}`).to.equal("lossy=true")
		end)
	end)

	----------------------------------------------------------------------------
	-- R3. AXIS-ALIGNED ROTATIONS, DECLARED AND UNDECLARED. The pinned behaviour.
	----------------------------------------------------------------------------

	describe("axis-aligned rotations", function()
		it("still takes the 13-byte path when precision is not declared", function()
			local packed = Datatypes.Pack("CFrame", CFrame.new(5, 10, 15))
			expect(buffer.len(packed)).to.equal(LEN_AXIS)
			expect(buffer.readu8(packed, 0)).never.to.equal(TAG_FULL)
			expect(buffer.readu8(packed, 0)).never.to.equal(TAG_QUAT)
		end)

		it("PINNED: a declared-exact field is 49 bytes even when it is square", function()
			-- THE BEHAVIOUR, CHOSEN AND FIXED HERE. Declaring exact does NOT fall back
			-- to the cheap 13-byte form for a square rotation, even though a square
			-- rotation would survive it. Two reasons, and the second is the real one:
			--   * a flat 49 is a cost a developer can budget; a width that moves with
			--     the runtime rotation is not, and 13-vs-49 is indistinguishable from
			--     an undeclared field to anything reading raw buffers.
			--   * the cheap path is exactly the path that SNAPS (next test).
			local square = Datatypes.Pack("CFrame", CFrame.new(5, 10, 15), "exact")
			expect(buffer.len(square)).to.equal(LEN_FULL)
			expect(buffer.readu8(square, 0)).to.equal(TAG_FULL)
			-- Identity rotation too, the most square case there is.
			expect(buffer.len(Datatypes.Pack("CFrame", CFrame.new(), "exact"))).to.equal(LEN_FULL)
		end)

		it("and that is WHY: the 13-byte path snaps a nearly-square rotation flat", function()
			-- AXIS_EPSILON is 1e-4, so an axis 3e-5 off unit is accepted as unit and
			-- then rebuilt as unit. The tilt does not degrade -- it VANISHES. This is
			-- a loss ~300x larger than the quaternion path's, hiding on the path that
			-- looks cheapest, and it is the sharpest reason an exact field must never
			-- be routed there.
			local tilt = asF32(3e-5)
			-- GetComponents order is x y z / r00 r01 r02 / r10 r11 r12 / r20 r21 r22,
			-- so this is Right = (1, tilt, 0), Up = (-tilt, 1, 0), Back = (0, 0, 1):
			-- a rotation a hair off square about Z.
			local nearlySquare = CFrame.new(table.unpack({ 0, 0, 0, 1, -tilt, 0, tilt, 1, 0, 0, 0, 1 }))

			local _, snappedDelta, snappedBytes = roundTrip(nearlySquare, nil)
			expect(snappedBytes).to.equal(LEN_AXIS)
			-- The tilt is gone entirely, not merely rounded.
			assertDelta("13-byte path", snappedDelta, ">", TOL)
			expect(snappedDelta).to.equal(tilt)

			local _, exactDelta, exactBytes = roundTrip(nearlySquare, "exact")
			expect(exactBytes).to.equal(LEN_FULL)
			assertDelta("exact path on a nearly-square rotation", exactDelta, "<=", 0)
		end)
	end)

	----------------------------------------------------------------------------
	-- R4. OLD BUFFERS DECODE FOREVER. Built by hand, not by the encoder.
	----------------------------------------------------------------------------

	describe("buffers written before this existed", function()
		it("decodes a hand-built 13-byte axis-aligned buffer", function()
			-- Hand-built ON PURPOSE. Round-tripping through today's encoder would only
			-- prove the encoder agrees with itself; these are the bytes on disk.
			local b = buffer.create(LEN_AXIS)
			buffer.writeu8(b, 0, 2) -- rightCode 0 (+X), upCode 2 (+Y): identity rotation
			buffer.writef32(b, 1, 5)
			buffer.writef32(b, 5, 10)
			buffer.writef32(b, 9, 15)

			local cf = Datatypes.Unpack("CFrame", b)
			local c = { cf:GetComponents() }
			expect(c[1]).to.equal(5)
			expect(c[2]).to.equal(10)
			expect(c[3]).to.equal(15)
			-- Identity rotation, reconstructed from the code.
			local identity = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
			for i = 1, 9 do
				expect(c[3 + i]).to.equal(identity[i])
			end
		end)

		it("decodes a hand-built 29-byte quaternion buffer", function()
			local b = buffer.create(LEN_QUAT)
			buffer.writeu8(b, 0, TAG_QUAT)
			buffer.writef32(b, 1, 1)
			buffer.writef32(b, 5, 2)
			buffer.writef32(b, 9, 3)
			buffer.writef32(b, 13, 0.3826834) -- 45 degrees about X
			buffer.writef32(b, 17, 0)
			buffer.writef32(b, 21, 0)
			buffer.writef32(b, 25, 0.9238795)

			local cf = Datatypes.Unpack("CFrame", b)
			local c = { cf:GetComponents() }
			expect(c[1]).to.equal(1)
			expect(c[2]).to.equal(2)
			expect(c[3]).to.equal(3)
			-- A 45-degree X rotation: the Y axis tips to (0, cos45, sin45).
			expect(math.abs(c[8] - 0.7071068) < 1e-6).to.equal(true)
			expect(math.abs(c[11] - 0.7071068) < 1e-6).to.equal(true)
		end)

		it("still refuses the tags that were malformed before, and 36..253 with them", function()
			-- The new tag came out of the unassigned range, so the range has to stay
			-- refused around it or a corrupt byte would start decoding as a CFrame.
			for _, tag in { 36, 100, 253 } do
				local b = buffer.create(LEN_AXIS)
				buffer.writeu8(b, 0, tag)
				expect(function()
					Datatypes.Unpack("CFrame", b)
				end).to.throw()
			end
		end)

		it("refuses a TRUNCATED 254 buffer rather than reading past its end", function()
			-- A hostile or half-written buffer carrying the new tag must fail as a
			-- clean malformed-CFrame error, the same way a truncated 255 does.
			local short = buffer.create(LEN_AXIS)
			buffer.writeu8(short, 0, TAG_FULL)
			local ok, err = pcall(Datatypes.Unpack, "CFrame", short)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "malformed packed CFrame", 1, true) ~= nil).to.equal(true)
		end)
	end)

	----------------------------------------------------------------------------
	-- R5. NaN AND INF ARE STILL REFUSED, on the new path too.
	----------------------------------------------------------------------------

	describe("non-finite components", function()
		local NAN = 0 / 0

		local function refusesComponent(label: string, cf: CFrame, precision: string?)
			local ok, err = pcall(Datatypes.Pack, "CFrame", cf, precision)
			if ok then
				error(`{label}: expected a non-finite refusal, but it packed`, 2)
			end
			if not string.find(tostring(err), Datatypes.NONFINITE, 1, true) then
				error(`{label}: expected the NONFINITE marker, got: {tostring(err)}`, 2)
			end
		end

		it("refuses a NaN or infinite POSITION on both paths", function()
			refusesComponent("default / NaN", CFrame.new(NAN, 0, 0), nil)
			refusesComponent("exact / NaN", CFrame.new(NAN, 0, 0), "exact")
			refusesComponent("default / inf", CFrame.new(0, math.huge, 0), nil)
			refusesComponent("exact / inf", CFrame.new(0, math.huge, 0), "exact")
			refusesComponent("exact / -inf", CFrame.new(0, 0, -math.huge), "exact")
		end)

		it("refuses a NaN ROTATION component, which only the exact path can even see", function()
			-- A NaN in the rotation defeats unitAxisCode (every comparison against NaN
			-- is false), so the default path routes it to the quaternion and the NaN
			-- propagates into it. The exact path writes the component directly. Both
			-- must refuse.
			local nanRotation = CFrame.new(0, 0, 0, NAN, 0, 0, 0, 1, 0, 0, 0, 1)
			refusesComponent("default / NaN rotation", nanRotation, nil)
			refusesComponent("exact / NaN rotation", nanRotation, "exact")

			local infRotation = CFrame.new(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, math.huge)
			refusesComponent("exact / inf rotation", infRotation, "exact")
		end)

		it("reports a non-finite exact field as a clean validation error, not a raw throw", function()
			-- The NONFINITE prefix is what validateWrite converts into a path-tagged
			-- error; the new path uses the same wf32 writer, so it inherits that.
			local harness = TestCtx.make({
				Template = (function()
					local template = TestCtx.defaultTemplate()
					template.Aim = Scribe.CFrame(CFrame.new(), { Precision = "exact" })
					return template
				end)(),
			})
			local _, _, data = harness.Join(7710)
			local ok, err = pcall(function()
				data.Aim.Set(CFrame.new(0 / 0, 0, 0))
			end)
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "NaN/inf component", 1, true) ~= nil).to.equal(true)
			harness.Cleanup()
		end)
	end)

	----------------------------------------------------------------------------
	-- R6. THE DECLARATION -- refused at STARTUP, never at the first write.
	----------------------------------------------------------------------------

	describe("declaring it", function()
		it("accepts the one value it has, and still accepts no value at all", function()
			expect(function()
				TestCtx.make({ Template = { N = Scribe.CFrame(CFrame.new(), { Precision = "exact" }) } }).Cleanup()
			end).never.to.throw()
			expect(function()
				TestCtx.make({ Template = { N = Scribe.CFrame(CFrame.new()) } }).Cleanup()
			end).never.to.throw()
		end)

		it("refuses a Precision the CFrame codec does not offer", function()
			-- "f32" is a real Precision -- on Scribe.Number. Borrowing it here would
			-- otherwise sit in the meta table doing nothing.
			refuses(Scribe.CFrame(CFrame.new(), { Precision = "f32" } :: any), "Precision must be")
			refuses(Scribe.CFrame(CFrame.new(), { Precision = "full" } :: any), "Precision must be")
			refuses(Scribe.CFrame(CFrame.new(), { Precision = 0.5 } :: any), "Precision must be")
			refuses(Scribe.CFrame(CFrame.new(), { Precision = true } :: any), "Precision must be")
		end)

		it("refuses Precision on a datatype that has no such option", function()
			-- Only Scribe.CFrame exposes a meta argument, so this marker has to be
			-- hand-built -- but the compiler guard is what a future declarator would
			-- land on, and an unguarded one would pack the default form in silence.
			local vectorWithPrecision =
				Marker.make("Datatype", Vector3.new(1, 2, 3), { Datatype = "Vector3", Precision = "exact" })
			refuses(vectorWithPrecision, "has no Precision option")
		end)

		it("refuses an unknown option on the declarator itself", function()
			expect(function()
				Scribe.CFrame(CFrame.new(), { Exact = true } :: any)
			end).to.throw()
		end)

		it("still refuses Precision on the declarators that never took one", function()
			-- The control for loosening the old guard: opening it for datatypes must
			-- not have opened it for everything.
			local why = "Precision is a Scribe.Number option"
			refuses(Scribe.Int(0, { Min = 0, Max = 9, Precision = 1 } :: any), why)
			refuses(Scribe.String("", { Precision = 1 } :: any), why)
			refuses(Scribe.Big(0, { Precision = 1 } :: any), why)
		end)

		it("refuses a bad Precision from the PUBLIC Datatypes.Pack too", function()
			-- Scribe.Datatypes is public API and migrations call it directly, with no
			-- compiler in front of them. A typo there must not quietly hand back the
			-- default form.
			expect(function()
				Datatypes.Pack("CFrame", CFrame.new(), "f32")
			end).to.throw()
			expect(function()
				Datatypes.Pack("Vector3", Vector3.new(1, 2, 3), "exact")
			end).to.throw()
			-- And the accepted-value set is published, because the compiler reads it.
			expect(Datatypes.PrecisionValues("CFrame")[1]).to.equal("exact")
			expect(Datatypes.PrecisionValues("Vector3")).to.equal(nil)
		end)

		it("folds into the schema hash, so a drift cannot pass the Hello handshake", function()
			local function hashOf(field)
				return Template.Compile({ N = field }, {}).Hash
			end
			expect(hashOf(Scribe.CFrame(CFrame.new(), { Precision = "exact" }))).never.to.equal(
				hashOf(Scribe.CFrame(CFrame.new()))
			)
		end)
	end)

	----------------------------------------------------------------------------
	-- R7. END TO END, through a real profile.
	----------------------------------------------------------------------------

	describe("through a declared field", function()
		local function makeHarness()
			local template = TestCtx.defaultTemplate()
			template.Aim = Scribe.CFrame(CFrame.new(), { Precision = "exact" })
			template.Placed = Scribe.CFrame(CFrame.new())
			return TestCtx.make({ Template = template })
		end

		it("stores 49 bytes and reads back the exact rotation, across a save and reload", function()
			local harness = makeHarness()
			local player, entry, data = harness.Join(7700)

			-- BEFORE any write. The template compiler packs the DEFAULT too, and it
			-- has to pack it at the declared precision: a default stored at 13 bytes
			-- under a field whose every write stores 49 would mean a brand-new
			-- profile decoded differently from a used one.
			expect(buffer.len(entry.LiveData.Aim)).to.equal(LEN_FULL)
			expect(buffer.readu8(entry.LiveData.Aim, 0)).to.equal(TAG_FULL)
			expect(buffer.len(entry.LiveData.Placed)).to.equal(LEN_AXIS)

			data.Aim.Set(TILTED)
			data.Placed.Set(TILTED)

			-- The stored form: the declared field is wide, its undeclared neighbour
			-- is not. Same value, same template, different declaration.
			expect(buffer.len(entry.LiveData.Aim)).to.equal(LEN_FULL)
			expect(buffer.len(entry.LiveData.Placed)).to.equal(LEN_QUAT)

			assertDelta("exact field, live", maxDelta(TILTED, data.Aim.Get()), "<=", 0)
			assertDelta("default field, live", maxDelta(TILTED, data.Placed.Get()), ">", TOL)

			-- And it survives the round trip through the datastore, which is the
			-- reason the format had to be additive in the first place.
			harness.Data.Flush(player)
			harness.Leave(player)
			local _, _, reloaded = harness.Join(7700)
			assertDelta("exact field, reloaded", maxDelta(TILTED, reloaded.Aim.Get()), "<=", 0)

			harness.Cleanup()
		end)

		it("keeps Has() working on an exact CFrame inside a container", function()
			-- Node.canonicalDatatype repacks both sides to compare them. If it repacked
			-- the needle at the DEFAULT precision, the stored 49-byte entry and the
			-- 29-byte needle would land on different representatives and Has would say
			-- false about a value Get() had just handed out.
			local template = TestCtx.defaultTemplate()
			template.Shots = Scribe.ArrayOf(Scribe.CFrame(CFrame.new(), { Precision = "exact" }))
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join(7720)

			data.Shots.Insert(TILTED)
			expect(data.Shots.Has(TILTED)).to.equal(true)
			expect(data.Shots.Has(data.Shots.Get()[1])).to.equal(true)
			expect(data.Shots.Has(CFrame.new(99, 99, 99))).to.equal(false)

			harness.Cleanup()
		end)

		it("does not conflate two rotations the DEFAULT form cannot tell apart", function()
			-- FOUND BY MUTATION TESTING, and the only mutant of twenty-four that the
			-- first draft of this file let through. canonicalDatatype repacks both
			-- sides of a comparison to land them on one representative; drop the
			-- precision from that repack and both sides collapse onto the DEFAULT
			-- form -- symmetrically, so Has() still answers true for a value that is
			-- present, and every test above stayed green. What it loses is the
			-- ability to answer FALSE: two values that differ only in the bits the
			-- exact form exists to preserve become the same buffer, and Has reports a
			-- match that is not there.
			--
			-- The pair below makes that guaranteed rather than probable. A rotation
			-- 3e-5 off square and a perfectly square one pack to the *same 13 bytes*
			-- by default, because AXIS_EPSILON snaps the tilt away -- asserted, not
			-- assumed, on the next line.
			local tilt = asF32(3e-5)
			local nearlySquare = CFrame.new(table.unpack({ 0, 0, 0, 1, -tilt, 0, tilt, 1, 0, 0, 0, 1 }))
			local square = CFrame.new(0, 0, 0)
			expect(buffer.tostring(Datatypes.Pack("CFrame", nearlySquare))).to.equal(
				buffer.tostring(Datatypes.Pack("CFrame", square))
			)

			local template = TestCtx.defaultTemplate()
			template.Shots = Scribe.ArrayOf(Scribe.CFrame(CFrame.new(), { Precision = "exact" }))
			local harness = TestCtx.make({ Template = template })
			local _, _, data = harness.Join(7730)

			data.Shots.Insert(nearlySquare)
			-- Present: found. Absent-but-indistinguishable-by-default: NOT found.
			expect(data.Shots.Has(nearlySquare)).to.equal(true)
			expect(data.Shots.Has(square)).to.equal(false)

			harness.Cleanup()
		end)
	end)
end
