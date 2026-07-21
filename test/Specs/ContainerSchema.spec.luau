--!nonstrict
-- Compile-time coverage for the Scribe.ArrayOf / Scribe.DictOf container
-- declarators: the shape of the compiled node, the element subtree hanging off
-- AnyChild, HasDatatype bubbling, schema-hash sensitivity to element metadata,
-- and every compile rejection.
return function()
	local Root = script.Parent.Parent.Parent
	local ScribeRoot = Root.Scribe
	local Scribe = require(ScribeRoot) :: any
	local Template = require(ScribeRoot.Internal.Template)

	local function compile(template)
		return Template.Compile(template, {})
	end

	local function field(compiled, name)
		return compiled.Root.Children[name]
	end

	describe("compiled shape", function()
		it("compiles an ArrayOf into a Container node with an element schema", function()
			local compiled = compile({
				Furniture = Scribe.ArrayOf({
					Cf = Scribe.CFrame(CFrame.new()),
					ItemId = Scribe.String("", { MaxLength = 64 }),
				}, { MaxItems = 200 }),
			})
			local node = field(compiled, "Furniture")
			expect(node.Container).to.equal("Array")
			expect(node.Kind).to.equal("table")
			expect(node.MaxItems).to.equal(200)
			-- Children stays nil: the field set lives on the element, not the container.
			expect(node.Children).to.equal(nil)
			expect(next(node.Default)).to.equal(nil)

			local element = node.AnyChild
			expect(element).to.be.ok()
			expect(element.IsElement).to.equal(true)
			expect(element.Closed).to.equal(true)
			expect(element.Parent).to.equal(node)
			expect(element.Children.Cf.ValueType).to.equal("datatype")
			expect(element.Children.Cf.Datatype).to.equal("CFrame")
			expect(element.Children.ItemId.MaxLength).to.equal(64)
		end)

		it("compiles a DictOf with a leaf element shape", function()
			local compiled = compile({
				Resources = Scribe.DictOf(Scribe.Int(0, { Min = 0 }), { MaxKeys = 50, MaxKeyLength = 32 }),
			})
			local node = field(compiled, "Resources")
			expect(node.Container).to.equal("Dict")
			expect(node.MaxKeys).to.equal(50)
			expect(node.MaxKeyLength).to.equal(32)

			local element = node.AnyChild
			expect(element.IsElement).to.equal(true)
			expect(element.Kind).to.equal("leaf")
			expect(element.ValueType).to.equal("int")
			expect(element.Min).to.equal(0)
			expect(element.Default).to.equal(0)
			-- A leaf element has no field set, so Closed does not apply; ChildSchema
			-- already returns nil for a leaf.
			expect(element.Closed).to.equal(nil)
		end)

		it("routes every dynamic key through the element schema", function()
			local compiled = compile({ Bag = Scribe.ArrayOf(Scribe.Int(0)) })
			local node = field(compiled, "Bag")
			expect(Template.ChildSchema(node, 1)).to.equal(node.AnyChild)
			expect(Template.ChildSchema(node, 7)).to.equal(node.AnyChild)
			expect(Template.ChildSchema(node, "anything")).to.equal(node.AnyChild)
		end)

		it("resolves nil for an undeclared field of a closed element record", function()
			local compiled = compile({ Pets = Scribe.DictOf({ Level = Scribe.Int(1) }) })
			local element = field(compiled, "Pets").AnyChild
			expect(Template.ChildSchema(element, "Level")).to.equal(element.Children.Level)
			expect(Template.ChildSchema(element, "Colour")).to.equal(nil)
			-- and the miss must not have been cached onto the shared element node
			expect(element.AnyChild).to.equal(nil)
		end)

		it("gives element nodes no field id, so they consume no id budget", function()
			local plain = compile({ Bag = {} })
			local withElement = compile({
				Bag = Scribe.ArrayOf({ A = Scribe.Int(0), B = Scribe.Int(0), C = Scribe.Int(0) }),
			})
			expect(withElement.NodeCount).to.equal(plain.NodeCount)

			local element = field(withElement, "Bag").AnyChild
			expect(element.Id).to.equal(nil)
			expect(element.Children.A.Id).to.equal(nil)
		end)

		it("keeps element fields out of DynamicNodes", function()
			local compiled = compile({
				Made = Scribe.Dynamic(os.time),
				Bag = Scribe.ArrayOf({ N = Scribe.Int(0) }),
			})
			expect(#compiled.DynamicNodes).to.equal(1)
			expect(compiled.DynamicNodes[1].Name).to.equal("Made")
		end)
	end)

	describe("HasDatatype bubbling", function()
		it("bubbles an element datatype to the container and the root", function()
			local compiled = compile({ Furniture = Scribe.ArrayOf({ Cf = Scribe.CFrame(CFrame.new()) }) })
			expect(field(compiled, "Furniture").HasDatatype).to.equal(true)
			expect(compiled.Root.HasDatatype).to.equal(true)
		end)

		it("bubbles a datatype-typed leaf element", function()
			local compiled = compile({ Spots = Scribe.ArrayOf(Scribe.Vector3(Vector3.zero)) })
			expect(field(compiled, "Spots").HasDatatype).to.equal(true)
		end)

		it("leaves HasDatatype false when no element field is a datatype", function()
			local compiled = compile({ Bag = Scribe.ArrayOf({ N = Scribe.Int(0) }) })
			expect(field(compiled, "Bag").HasDatatype).to.equal(false)
			expect(compiled.Root.HasDatatype).to.equal(false)
		end)
	end)

	describe("nesting", function()
		it("compiles three levels of containers", function()
			local compiled = compile({
				Plots = Scribe.ArrayOf({
					Name = Scribe.String("", { MaxLength = 32 }),
					Rooms = Scribe.ArrayOf({
						Origin = Scribe.CFrame(CFrame.new()),
						Furniture = Scribe.DictOf({
							Cf = Scribe.CFrame(CFrame.new()),
							ItemId = Scribe.String("", { MaxLength = 64 }),
						}, { MaxKeys = 200 }),
					}, { MaxItems = 16 }),
				}, { MaxItems = 4 }),
			})

			local plots = field(compiled, "Plots")
			local plot = plots.AnyChild
			local rooms = plot.Children.Rooms
			local room = rooms.AnyChild
			local furniture = room.Children.Furniture
			local item = furniture.AnyChild

			expect(plots.Container).to.equal("Array")
			expect(rooms.Container).to.equal("Array")
			expect(rooms.MaxItems).to.equal(16)
			expect(furniture.Container).to.equal("Dict")
			expect(furniture.MaxKeys).to.equal(200)
			expect(item.Children.Cf.Datatype).to.equal("CFrame")

			-- the synthetic "[]" segment keeps element paths visibly non-addressable
			expect(table.concat(item.Path, ".")).to.equal("Plots.[].Rooms.[].Furniture.[]")
			-- and the datatype flag reaches all the way up
			expect(rooms.HasDatatype).to.equal(true)
			expect(plots.HasDatatype).to.equal(true)
			expect(compiled.Root.HasDatatype).to.equal(true)
		end)

		it("inherits container visibility into the element subtree", function()
			local compiled = compile({
				Secret = Scribe.ServerOnly(Scribe.ArrayOf({ N = Scribe.Int(0) })),
			})
			local node = field(compiled, "Secret")
			expect(node.Visibility).to.equal("ServerOnly")
			expect(node.AnyChild.Visibility).to.equal("ServerOnly")
			expect(node.AnyChild.Children.N.Visibility).to.equal("ServerOnly")
		end)

		it("allows ServerOnly on an element field", function()
			local compiled = compile({
				Rows = Scribe.ArrayOf({ Public = Scribe.Int(0), Hidden = Scribe.ServerOnly(Scribe.Int(0)) }),
			})
			local element = field(compiled, "Rows").AnyChild
			expect(element.Children.Public.Visibility).to.equal("Replicated")
			expect(element.Children.Hidden.Visibility).to.equal("ServerOnly")
		end)
	end)

	describe("schema hash", function()
		local function hashOf(template)
			return compile(template).Hash
		end

		it("distinguishes ArrayOf from DictOf over the same element", function()
			expect(hashOf({ X = Scribe.ArrayOf(Scribe.Int(0)) })).never.to.equal(
				hashOf({ X = Scribe.DictOf(Scribe.Int(0)) })
			)
		end)

		it("folds element bounds, which drive wire int width", function()
			expect(hashOf({ X = Scribe.ArrayOf(Scribe.Int(0, { Min = 0, Max = 200 })) })).never.to.equal(
				hashOf({ X = Scribe.ArrayOf(Scribe.Int(0, { Min = 0, Max = 70000 })) })
			)
		end)

		it("folds element enum members, which drive enum indexing", function()
			expect(hashOf({ X = Scribe.ArrayOf(Scribe.Enum("A", { "A", "B" })) })).never.to.equal(
				hashOf({ X = Scribe.ArrayOf(Scribe.Enum("A", { "A", "B", "C" })) })
			)
		end)

		it("folds element field names", function()
			expect(hashOf({ X = Scribe.ArrayOf({ A = Scribe.Int(0) }) })).never.to.equal(
				hashOf({ X = Scribe.ArrayOf({ B = Scribe.Int(0) }) })
			)
		end)

		it("folds container caps", function()
			expect(hashOf({ X = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 10 }) })).never.to.equal(
				hashOf({ X = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 11 }) })
			)
		end)

		it("folds a nested element subtree", function()
			expect(hashOf({ X = Scribe.ArrayOf({ Y = Scribe.ArrayOf(Scribe.Int(0)) }) })).never.to.equal(
				hashOf({ X = Scribe.ArrayOf({ Y = Scribe.ArrayOf(Scribe.String("")) }) })
			)
		end)

		it("is stable across compiles of an equivalent template", function()
			local function make()
				return {
					Plots = Scribe.ArrayOf({
						Name = Scribe.String(""),
						Tags = Scribe.DictOf(Scribe.Int(0)),
					}),
				}
			end
			expect(hashOf(make())).to.equal(hashOf(make()))
		end)
	end)

	describe("compile rejections", function()
		local function rejects(template, fragment)
			local ok, err = pcall(compile, template)
			expect(ok).to.equal(false)
			if not string.find(tostring(err), fragment, 1, true) then
				error(`expected error containing "{fragment}", got: {err}`, 0)
			end
		end

		it("rejects Scribe.Timed inside an element shape", function()
			rejects({ X = Scribe.ArrayOf({ Boost = Scribe.Timed(1) }) }, "Scribe.Timed is not supported inside")
		end)

		it("rejects Scribe.Dynamic inside an element shape", function()
			rejects({ X = Scribe.DictOf({ At = Scribe.Dynamic(os.time) }) }, "Scribe.Dynamic is not supported inside")
		end)

		it("rejects Scribe.Shared inside an element shape", function()
			rejects({ X = Scribe.ArrayOf({ N = Scribe.Shared(0) }) }, "Scribe.Shared is not supported inside")
		end)

		it("rejects Scribe.Session inside an element shape", function()
			rejects({ X = Scribe.ArrayOf({ N = Scribe.Session(0) }) }, "Scribe.Session is not supported inside")
		end)

		it("rejects a forbidden declarator nested deeper in the shape", function()
			rejects(
				{ X = Scribe.ArrayOf({ Inner = { Deep = Scribe.Timed(1) } }) },
				"Scribe.Timed is not supported inside"
			)
		end)

		it("rejects a forbidden declarator inside a nested container's shape", function()
			rejects(
				{ X = Scribe.ArrayOf({ Y = Scribe.ArrayOf({ At = Scribe.Dynamic(os.time) }) }) },
				"Scribe.Dynamic is not supported inside"
			)
		end)

		it("rejects an element shape with no fields", function()
			rejects({ X = Scribe.ArrayOf({}) }, "declares no fields")
		end)

		it("rejects a non-integer cap", function()
			rejects({ X = Scribe.ArrayOf(Scribe.Int(0), { MaxItems = 2.5 }) }, "MaxItems must be a positive integer")
		end)

		it("rejects a zero cap", function()
			rejects({ X = Scribe.DictOf(Scribe.Int(0), { MaxKeys = 0 }) }, "MaxKeys must be a positive integer")
		end)

		it("points a declarator-in-a-plain-array at ArrayOf", function()
			-- The shape that motivated these declarators: a datatype inside an array
			-- literal. The error has to name the fix, not just state the rule.
			local ok, err = pcall(compile, {
				placedFurniture = {
					{ cf = Scribe.CFrame(CFrame.new()), furnitureId = Scribe.String("") },
				},
			})
			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "Scribe.ArrayOf", 1, true) ~= nil).to.equal(true)
			expect(string.find(tostring(err), "Scribe.DictOf", 1, true) ~= nil).to.equal(true)
		end)

		it("rejects Scribe.Optional around a container", function()
			rejects({ X = Scribe.Optional(Scribe.ArrayOf(Scribe.Int(0))) }, "Scribe.Optional cannot wrap")
		end)

		it("compiles Scribe.Optional to a nullable field with no default", function()
			local compiled = compile({ X = Scribe.Optional(Scribe.String("", { MaxLength = 8 })) })
			local node = field(compiled, "X")
			expect(node.Nullable).to.equal(true)
			expect(node.ValueType).to.equal("string")
			expect(node.MaxLength).to.equal(8)
			expect(node.Default).to.equal(nil)
			-- and it is absent from the seeded defaults rather than present as ""
			expect(Template.BuildDefaults(compiled, "Persistent").X).to.equal(nil)
		end)

		it("rejects wrapping a container in Scribe.Timed", function()
			rejects({ X = Scribe.Timed(Scribe.ArrayOf(Scribe.Int(0))) }, "Scribe.Timed cannot wrap")
		end)
	end)
end
