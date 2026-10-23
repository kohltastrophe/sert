--!nonstrict
--!nolint DeprecatedApi
-- Engine doubles: generated API dump metadata, datatypes, Instance, DataStore, EncodingService, HttpService, and Signal.

local sert = require("../src")
local Datatypes = require("../src/doubles/datatypes")
local G = require("../src/doubles/generated") :: any
local InstanceDouble = require("../src/doubles/instance")
local DataStore = require("../src/doubles/datastore")
local Encoding = require("../src/doubles/encoding_service")
local Http = Encoding.HttpService
local Signal = require("../src/doubles/signal")

local test = sert.test
local expect = sert
local D = sert.doubles.Datatypes
local typeof = D.typeof
local Vector3 = D.Vector3
local CFrame = D.CFrame
local Enum = D.Enum

test("generated · hierarchy, members, read-only/deprecated/hidden, services/creatable, enums, defaults", function()
	sert.eq(G.superclass("Part"), "FormFactorPart")
	sert.eq(G.superclass("FormFactorPart"), "BasePart")
	sert.eq(G.superclass("BasePart"), "PVInstance")
	sert.eq(G.superclass("PVInstance"), "Instance")
	for _, base in { "Part", "FormFactorPart", "BasePart", "PVInstance", "Instance" } do
		expect(G.isA("Part", base))
	end
	expect(not G.isA("Part", "GuiObject") and not G.isA("Instance", "Part") and not G.isA("NoSuchClass", "Instance"))
	sert.eq(G.superclass("NoSuchClass"), nil)
	expect(G.isA("TextButton", "GuiButton") and G.isA("ScreenGui", "LayerCollector"))
	expect(G.exists("Workspace") and not G.exists("NoSuchClass"))

	local size = G.property("Frame", "Size")
	sert.eq({ size.owner, size.category, size.typeName }, { "GuiObject", "DataType", "UDim2" })
	sert.eq(G.property("Frame", "BackgroundColor3").typeName, "Color3")
	local style = G.property("Frame", "Style")
	sert.eq({ style.owner, style.category, style.typeName }, { "Frame", "Enum", "FrameStyle" })
	local parent = G.property("Frame", "Parent")
	sert.eq({ parent.category, parent.typeName }, { "Class", "Instance" })
	expect(G.event("Frame", "MouseEnter") ~= nil and G.event("Frame", "ChildAdded") ~= nil)
	local findFirst = G.method("Frame", "FindFirstChild")
	sert.eq({ findFirst.owner, findFirst.params[1].name, findFirst.returns }, { "Instance", "name", { "@Instance" } })
	expect(findFirst.params[2].optional and G.method("Players", "GetUserIdFromNameAsync").yields)
	expect(G.property("Frame", "NoSuchProperty") == nil and G.members("Frame").properties.Name ~= nil)
	expect(G.members("Frame") == G.members("Frame"))

	expect(G.property("Instance", "ClassName").readOnly and not G.property("Instance", "Name").readOnly)
	expect(G.property("Frame", "AbsoluteSize").readOnly and G.property("Part", "BrickColor").deprecated == false)
	expect(G.method("Instance", "children").deprecated and G.property("Instance", "archivable") == nil)

	expect(G.isService("Workspace") and G.isService("Players") and not G.isService("Part"))
	expect(G.creatable("Part") and G.creatable("Frame") and not G.creatable("Workspace"))
	expect(not G.creatable("BasePart") and G.isAbstract("BasePart") and not G.isAbstract("Workspace"))
	expect(not G.creatable("NoSuchClass") and G.tags("Workspace").NotCreatable and #G.classNames() > 500)

	sert.eq(G.enumItem("KeyCode", "A"), { Name = "A", Value = 97 })
	sert.eq(G.enumItem("KeyCode", "Unknown").Name, "None")
	sert.eq(G.enum("UserInputState")[1], { Name = "Begin", Value = 0 })
	expect(#G.enum("KeyCode") > 100)
	for _, item in G.enum("KeyCode") do
		expect(item.Name ~= "Unknown")
	end
	expect(G.enum("NoSuchEnum") == nil and G.enumItem("KeyCode", "Nope") == nil)
	expect(table.find(G.enumNames(), "Material") ~= nil)

	sert.eq(G.defaultValue("Frame", "Style", Datatypes).Name, "Custom")
	expect(G.defaultValue("UIListLayout", "Padding", Datatypes) == Datatypes.UDim.new(0, 0))
	sert.eq(G.defaultValue("UIGradient", "Scale", Datatypes), 1)
	sert.eq(#G.defaultValue("UIGradient", "Color", Datatypes).Keypoints, 2)
	sert.eq(G.defaultValue("UIGradient", "Transparency", Datatypes).Keypoints[2].Time, 1)
	sert.eq(G.defaultValue("UIGradient", "Enabled", Datatypes), true)
	sert.eq(G.defaultValue("Frame", "Size", Datatypes), nil)
end)

test(
	"datatypes · Ray, RaycastParams/OverlapParams, RaycastResult, PhysicalProperties, CatalogSearchParams, Region3, int16, Axes, Faces, PathWaypoint",
	function()
		local ray = D.Ray.new(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0))
		sert.eq({ typeof(ray), ray.Origin, ray.Unit.Direction }, { "Ray", Vector3.zero, Vector3.new(1, 0, 0) })
		sert.eq(ray:ClosestPoint(Vector3.new(4, 3, 0)), Vector3.new(4, 0, 0))
		sert.eq(ray:ClosestPoint(Vector3.new(-4, 3, 0)), Vector3.zero)
		sert.near(ray:Distance(Vector3.new(4, 3, 0)), 3)
		sert.eq(ray, D.Ray.new(Vector3.zero, Vector3.new(10, 0, 0)))
		sert.eq(tostring(ray), "{0, 0, 0}, {10, 0, 0}")
		sert.fails(function() (ray :: any).Origin = Vector3.one end)

		local rp = D.RaycastParams.new()
		sert.eq({
			typeof(rp),
			rp.FilterType,
			rp.IgnoreWater,
			rp.CollisionGroup,
			rp.RespectCanCollide,
			rp.BruteForceAllSlow,
			#rp.FilterDescendantsInstances,
		}, {
			"RaycastParams",
			Enum.RaycastFilterType.Exclude,
			false,
			"Default",
			false,
			false,
			0,
		})
		rp.FilterType, rp.IgnoreWater = Enum.RaycastFilterType.Include, true
		sert.eq(rp.FilterType, Enum.RaycastFilterType.Include)

		local e = sert.env.new()
		local a, b = e.Instance.new("Part"), e.Instance.new("Part")
		rp:AddToFilter(a)
		rp:AddToFilter({ b })
		sert.eq(rp.FilterDescendantsInstances, { a, b })
		sert.fails(function() rp.FilterTpye = Enum.RaycastFilterType.Include end, "not a valid member of RaycastParams")

		local op = D.OverlapParams.new({ MaxParts = 5 })
		sert.eq({ typeof(op), op.MaxParts, op.FilterType }, { "OverlapParams", 5, Enum.RaycastFilterType.Exclude })
		op:AddToFilter(a)
		sert.eq(op.FilterDescendantsInstances, { a })
		sert.fails(function() D.OverlapParams.new({ Nope = 1 }) end, "Nope is not a valid member of OverlapParams")
		sert(rp ~= D.RaycastParams.new())

		local part = e.Instance.new("Part")
		local hit = D.newRaycastResult(part, Vector3.new(1, 2, 3), Vector3.yAxis, 4, Enum.Material.Plastic)
		sert.eq({ typeof(hit), hit.Instance, hit.Position, hit.Normal, hit.Distance, hit.Material }, {
			"RaycastResult",
			part,
			Vector3.new(1, 2, 3),
			Vector3.yAxis,
			4,
			Enum.Material.Plastic,
		})
		sert.eq(hit, D.newRaycastResult(part, Vector3.new(1, 2, 3), Vector3.yAxis, 4, Enum.Material.Plastic))
		sert.fails(function() (hit :: any).Distance = 1 end)

		local plastic = D.PhysicalProperties.new(Enum.Material.Plastic)
		sert.eq(typeof(plastic), "PhysicalProperties")
		sert.near(plastic.Density, 0.7)
		sert.near(plastic.Friction, 0.3)
		sert.near(plastic.Elasticity, 0.5)
		sert.eq(plastic.FrictionWeight, 1)
		sert.near(D.PhysicalProperties.new(Enum.Material.Metal).Density, 7.85)
		local custom = D.PhysicalProperties.new(2, 0.5, 0.25, 3, 4)
		sert.eq({ custom.Density, custom.FrictionWeight, custom.ElasticityWeight }, { 2, 3, 4 })
		sert.eq(custom, D.PhysicalProperties.new(2, 0.5, 0.25, 3, 4))
		sert.neq(custom, D.PhysicalProperties.new(2, 0.5, 0.25))
		sert.eq(tostring(D.PhysicalProperties.new(1, 0.5, 0.25)), "1, 0.5, 0.25, 1, 1")
		sert.fails(function() D.PhysicalProperties.new("Plastic") end, "expects a Material")

		local csp = D.CatalogSearchParams.new()
		sert.eq({ typeof(csp), csp.Limit, csp.SortType, csp.SortAggregation, csp.CreatorType }, {
			"CatalogSearchParams",
			30,
			Enum.CatalogSortType.Relevance,
			Enum.CatalogSortAggregation.AllTime,
			Enum.CreatorTypeFilter.All,
		})
		csp.SearchKeyword = "hat"
		sert.eq(csp.SearchKeyword, "hat")
		sert.fails(function() csp.Keyword = "hat" end, "not a valid member of CatalogSearchParams")

		local r = D.Region3.new(Vector3.new(0, 0, 0), Vector3.new(4, 2, 6))
		sert.eq({ typeof(r), r.Size, r.CFrame }, { "Region3", Vector3.new(4, 2, 6), CFrame.new(2, 1, 3) })
		local rg = D.Region3.new(Vector3.new(1, -1, 3), Vector3.new(5, 2, 7)):ExpandToGrid(4)
		sert.eq({ rg.Size, rg.CFrame.Position }, { Vector3.new(8, 8, 8), Vector3.new(4, 0, 4) })
		sert.eq(r, D.Region3.new(Vector3.zero, Vector3.new(4, 2, 6)))
		sert.fails(function() (r :: any).Size = Vector3.one end)

		local v3i = D.Vector3int16.new(1.9, -2.9, 3)
		sert.eq({ typeof(v3i), v3i }, { "Vector3int16", D.Vector3int16.new(1, -2, 3) })
		sert.eq(v3i + D.Vector3int16.new(1, 1, 1), D.Vector3int16.new(2, -1, 4))
		sert.eq(v3i - D.Vector3int16.new(1, 1, 1), D.Vector3int16.new(0, -3, 2))
		sert.eq(v3i * 2, D.Vector3int16.new(2, -4, 6))
		sert.eq(v3i * D.Vector3int16.new(2, 2, 2), D.Vector3int16.new(2, -4, 6))
		sert.eq(D.Vector3int16.new(7, 7, 7) / 2, D.Vector3int16.new(3, 3, 3))
		sert.eq(-v3i, D.Vector3int16.new(-1, 2, -3))
		sert.eq(D.Vector3int16.new(32767, 0, 0) + D.Vector3int16.new(1, 0, 0), D.Vector3int16.new(-32768, 0, 0))
		sert.eq(D.Vector3int16.new(40000).X, -25536)
		sert.eq(tostring(v3i), "1, -2, 3")

		local v2i = D.Vector2int16.new(3, 4)
		sert.eq({ typeof(v2i), v2i + D.Vector2int16.new(1, 1), v2i * 2, -v2i, D.Vector2int16.new(-32769, 0).X }, {
			"Vector2int16",
			D.Vector2int16.new(4, 5),
			D.Vector2int16.new(6, 8),
			D.Vector2int16.new(-3, -4),
			32767,
		})
		sert.fails(function() (v2i :: any).X = 1 end)

		local axes = D.Axes.new(Enum.Axis.X, Enum.NormalId.Top)
		sert.eq({ typeof(axes), tostring(axes), axes }, { "Axes", "X, Y", D.Axes.new(Enum.NormalId.Left, Enum.Axis.Y) })
		sert(
			axes.X
				and axes.Y
				and not axes.Z
				and axes.Right
				and axes.Left
				and axes.Top
				and axes.Bottom
				and not axes.Front
				and not axes.Back
		)

		local faces = D.Faces.new(Enum.NormalId.Top, Enum.NormalId.Front)
		sert.eq(
			{ typeof(faces), tostring(faces), faces },
			{ "Faces", "Top, Front", D.Faces.new(Enum.NormalId.Front, Enum.NormalId.Top) }
		)
		sert(faces.Top and faces.Front and not faces.Bottom and not faces.Right)
		sert.neq(faces, D.Faces.new(Enum.NormalId.Top))
		sert.fails(function() D.Faces.new(Enum.Axis.X) end, "expects Enum.NormalId")

		local wp = D.PathWaypoint.new(Vector3.new(1, 2, 3), Enum.PathWaypointAction.Jump, "ledge")
		sert.eq(
			{ typeof(wp), wp.Position, wp.Action, wp.Label },
			{ "PathWaypoint", Vector3.new(1, 2, 3), Enum.PathWaypointAction.Jump, "ledge" }
		)
		local plain = D.PathWaypoint.new(Vector3.one)
		sert.eq({ plain.Action, plain.Label }, { Enum.PathWaypointAction.Walk, "" })
		sert.eq(wp, D.PathWaypoint.new(Vector3.new(1, 2, 3), Enum.PathWaypointAction.Jump, "ledge"))
	end
)

test(
	"datatypes · strict vs lenient Enum, Vector3 interning, sert.near, Color3, BrickColor, UDim, Vector2/3, CFrame, sequences, DateTime, Random",
	function()
		local Strict = D.makeEnum(true)
		sert.eq({
			D.makeEnum(false),
			D.makeEnum(nil),
			Strict,
			Strict.KeyCode.Return,
			typeof(Strict.KeyCode),
			tostring(Strict.KeyCode),
		}, {
			D.Enum,
			D.Enum,
			D.StrictEnum,
			Enum.KeyCode.Return,
			"Enum",
			"KeyCode",
		})
		sert(Strict.KeyCode == Enum.KeyCode and Enum.KeyCode.Return.EnumType == Strict.KeyCode)
		sert.eq(Strict.KeyCode:FromName("Return"), Enum.KeyCode.Return)
		sert.eq(#Strict.RaycastFilterType:GetEnumItems(), 2)
		sert.fails(function() local _ = Strict.KeyCode.Typo end, "Typo is not a valid member of Enum KeyCode")
		sert.fails(function() local _ = Strict.NotAnEnumType end, "NotAnEnumType is not a valid member of Enums")
		sert.fails(function() Strict.KeyCode.Return = 1 end)

		local minted = Enum.SertSpecLenient.Whatever
		sert.eq({ typeof(minted), Enum.SertSpecLenient:GetEnumItems() }, { "EnumItem", { minted } })
		sert.fails(function() local _ = Strict.SertSpecLenient end, "SertSpecLenient is not a valid member of Enums")
		local keyCount = #Enum.KeyCode:GetEnumItems()
		local typo = Enum.KeyCode.SertSpecTypo
		sert.eq(
			{ typeof(typo), #Enum.KeyCode:GetEnumItems(), #Strict.KeyCode:GetEnumItems() },
			{ "EnumItem", keyCount, keyCount }
		)
		sert.fails(
			function() local _ = Strict.KeyCode.SertSpecTypo end,
			"SertSpecTypo is not a valid member of Enum KeyCode"
		)
		sert.eq({
			Strict.KeyCode:FromName("SertSpecTypo"),
			Strict.KeyCode.FromValue(typo.Value),
			Enum.KeyCode:FromName("SertSpecTypo"),
		}, { nil, nil, typo })
		for _, et in Strict:GetEnums() do
			sert.eq(typeof(et), "Enum")
		end

		local t = { [Vector3.new(1, 2, 3)] = "hit" }
		sert.eq({
			t[Vector3.new(1, 2, 3)],
			t[Vector3.new(1, 2, 3) + Vector3.zero],
			t[Vector3.new(0.5, 1, 1) * 2 + Vector3.new(0, 0, 1)],
			t[Vector3.new(1, 2, 4)],
		}, {
			"hit",
			"hit",
			"hit",
			nil,
		})
		sert(rawequal(Vector3.new(0.1, 0.2, 0.3), Vector3.new(0.1, 0.2, 0.3)))
		sert.eq({ Vector3.new(0.1, 0, 0).X, Vector3.new(0.1 + 1e-12, 0, 0).X }, { 0.1, 0.1 + 1e-12 })
		local nan = Vector3.new(0 / 0, 0, 0)
		sert(nan.X ~= nan.X)

		sert.near(Vector3.new(1, 2, 3), Vector3.new(1 + 1e-7, 2, 3))
		sert.near(
			CFrame.new(1, 2, 3) * CFrame.Angles(0, math.pi, 0),
			CFrame.new(1, 2, 3) * CFrame.Angles(0, -math.pi, 0)
		)
		sert.near(D.Vector2.new(1, 1), D.Vector2.new(1, 1 + 1e-7))
		sert.near(D.Color3.new(0.5, 0.5, 0.5), D.Color3.fromRGB(128, 128, 128), 0.01)
		sert.near(D.UDim2.new(0.5, 1, 0.5, 1), D.UDim2.new(0.5, 1, 0.5, 1))
		sert.near(D.Rect.new(0, 0, 1, 1), D.Rect.new(0, 0, 1, 1 + 1e-7))
		sert.near(D.NumberRange.new(1, 2), D.NumberRange.new(1, 2 + 1e-7))
		sert.near(D.Vector3int16.new(1, 2, 3), D.Vector3int16.new(1, 2, 3))
		sert.near(D.Vector2int16.new(1, 2), D.Vector2int16.new(1, 2))
		sert.fails(function() sert.near(Vector3.new(1, 2, 3), Vector3.new(1, 2, 3.1)) end)

		sert.eq({
			Enum.KeyCode.A.Value,
			Enum.KeyCode.Space.Value,
			Enum.Material.Plastic.Value,
			Enum.HumanoidStateType.Dead.Value,
			Enum.SortOrder.LayoutOrder.Value,
		}, {
			97,
			32,
			256,
			15,
			2,
		})
		sert.eq({
			Enum.KeyCode:FromValue(97),
			Strict.AccessModifierType.Deny.Value,
			Enum.Font.Montserrat,
			Strict.Font.Montserrat,
			Enum.Font:FromName("Montserrat"),
		}, {
			Enum.KeyCode.A,
			1,
			Enum.Font.Gotham,
			Enum.Font.Gotham,
			Enum.Font.Gotham,
		})
		sert.fails(
			function() local _ = Strict.Material.NotAMaterial end,
			"NotAMaterial is not a valid member of Enum Material"
		)
		sert.fails(function() local _ = Strict.SertNoSuchEnum end, "SertNoSuchEnum is not a valid member of Enums")

		local e = sert.env.new()
		local g = e.globals
		sert.eq({ g.type(g.Color3.new(1, 0, 0)), g.type(e.game), g.type(123) }, { "userdata", "userdata", "number" })

		for sector = 0, 5 do
			local col = g.Color3.fromHSV((sector + 0.25) / 6, 0.8, 0.9)
			local h, s, v = col:ToHSV()
			sert.near(g.Color3.fromHSV(h, s, v).R, col.R, 1e-3)
		end
		for _, rgb in { { 0.8, 0.2, 0.4 }, { 0.2, 0.9, 0.3 }, { 0.2, 0.3, 0.9 } } do
			local col = g.Color3.new(rgb[1], rgb[2], rgb[3])
			local h, s, v = col:ToHSV()
			local rt = g.Color3.fromHSV(h, s, v)
			sert.near(rt, col, 1e-4)
		end
		sert.eq(g.Color3.fromHex("#f80"), g.Color3.fromRGB(255, 136, 0))
		sert.fails(function() g.Color3.fromHex("zzzz") end, "invalid hex")
		sert.eq(g.Color3.new(0, 0, 0):Lerp(g.Color3.new(1, 1, 1), 0.5), g.Color3.new(0.5, 0.5, 0.5))
		sert.eq(tostring(g.Color3.new(1, 0, 0)), "1, 0, 0")

		sert.eq(g.BrickColor.new(21), g.BrickColor.Red())
		sert.eq(g.BrickColor.new(999999).ClassName, nil)
		sert.eq(g.BrickColor.new(1, 0, 0), g.BrickColor.new("Really red"))
		sert.eq(g.BrickColor.new("nonexistent brick").Name, "Medium stone grey")
		sert.eq(g.BrickColor.new(nil).Name, "Medium stone grey")
		local pal3 = g.BrickColor.palette(3)
		sert.eq({ g.typeof(pal3), pal3.Name, pal3.Number }, { "BrickColor", "Brick yellow", 5 })
		local randBc = g.BrickColor.random()
		sert(g.typeof(randBc) == "BrickColor" and #randBc.Name > 0 and randBc.Number > 0)
		sert.eq({
			g.BrickColor.White().Name,
			g.BrickColor.Black().Name,
			g.BrickColor.Green().Name,
			g.BrickColor.Blue().Name,
			g.BrickColor.Yellow().Name,
			tostring(g.BrickColor.White()),
		}, {
			"White",
			"Black",
			"Dark green",
			"Bright blue",
			"Bright yellow",
			"White",
		})

		local ud1, ud2 = g.UDim.new(0.5, 10), g.UDim.new(0.2, -4.2)
		sert.eq({ ud1 - ud2, tostring(ud1) }, { g.UDim.new(0.3, 14), "0.5, 10" })
		local u2a, u2b = g.UDim2.new(ud1, ud2), g.UDim2.fromOffset(20, 40)
		sert.eq({ (u2a - u2b).X.Offset, g.UDim2.fromOffset(0, 0):Lerp(u2b, 0.5) }, { -10, g.UDim2.fromOffset(10, 20) })
		sert.contains(tostring(u2b), "{0, 20}")

		local zeroUnit2 = g.Vector2.zero.Unit
		sert(zeroUnit2.X ~= zeroUnit2.X and zeroUnit2.Y ~= zeroUnit2.Y)
		local v2a, v2b = g.Vector2.new(-3.2, 4.8), g.Vector2.new(2, -1)
		sert.eq(v2a:Lerp(v2b, 0.5), g.Vector2.new(-0.6, 1.9))
		sert.near(v2a:Dot(v2b), -11.2)
		sert.near(v2a:Cross(v2b), -6.4)
		sert.eq({ v2a:Abs(), v2a:Ceil(), v2a:Floor(), v2a:Sign(), v2a:Max(v2b), v2a:Min(v2b) }, {
			g.Vector2.new(3.2, 4.8),
			g.Vector2.new(-3, 5),
			g.Vector2.new(-4, 4),
			g.Vector2.new(-1, 1),
			g.Vector2.new(2, 4.8),
			g.Vector2.new(-3.2, -1),
		})
		sert.eq({
			v2b + g.Vector2.one,
			v2b - g.Vector2.one,
			2 * v2b,
			v2b * 2,
			v2b * v2b,
			4 / g.Vector2.new(2, 4),
			v2b / 2,
			v2b / g.Vector2.new(2, -1),
			-v2b,
			tostring(v2b),
		}, {
			g.Vector2.new(3, 0),
			g.Vector2.new(1, -2),
			g.Vector2.new(4, -2),
			g.Vector2.new(4, -2),
			g.Vector2.new(4, 1),
			g.Vector2.new(2, 1),
			g.Vector2.new(1, -0.5),
			g.Vector2.one,
			g.Vector2.new(-2, 1),
			"2, -1",
		})

		local zeroUnit3 = g.Vector3.zero.Unit
		sert(zeroUnit3.X ~= zeroUnit3.X and zeroUnit3.Z ~= zeroUnit3.Z)
		local v3a, v3b = g.Vector3.new(-1.5, 2.5, -3.5), g.Vector3.new(2, -1, 4)
		sert.eq({
			g.Vector3.zero:Lerp(v3b, 0.5),
			v3a:Dot(v3b),
			v3a:Abs(),
			v3a:Ceil(),
			v3a:Floor(),
			v3a:Sign(),
			v3b:FuzzyEq(g.Vector3.new(2.000001, -1, 4), 1e-4),
			v3a:Max(v3b),
			v3a:Min(v3b),
		}, {
			g.Vector3.new(1, -0.5, 2),
			-19.5,
			g.Vector3.new(1.5, 2.5, 3.5),
			g.Vector3.new(-1, 3, -3),
			g.Vector3.new(-2, 2, -4),
			g.Vector3.new(-1, 1, -1),
			true,
			g.Vector3.new(2, 2.5, 4),
			g.Vector3.new(-1.5, -1, -3.5),
		})
		for _, nid in
			{
				{ "Right", 1, 0, 0 },
				{ "Top", 0, 1, 0 },
				{ "Back", 0, 0, 1 },
				{ "Left", -1, 0, 0 },
				{ "Bottom", 0, -1, 0 },
				{ "Front", 0, 0, -1 },
				{ "Unknown", 0, 0, 0 },
			}
		do
			sert.eq(g.Vector3.FromNormalId(nid[1]), g.Vector3.new(nid[2], nid[3], nid[4]))
		end
		for _, ax in { { "X", 1, 0, 0 }, { "Y", 0, 1, 0 }, { "Z", 0, 0, 1 }, { "Unknown", 0, 0, 0 } } do
			sert.eq(g.Vector3.FromAxis(ax[1]), g.Vector3.new(ax[2], ax[3], ax[4]))
		end
		sert.eq({
			v3b + g.Vector3.one,
			v3b - g.Vector3.one,
			2 * v3b,
			v3b * 2,
			v3b * v3b,
			8 / g.Vector3.new(2, 4, 8),
			v3b / 2,
			v3b / v3b,
			-v3b,
			tostring(v3b),
		}, {
			g.Vector3.new(3, 0, 5),
			g.Vector3.new(1, -2, 3),
			g.Vector3.new(4, -2, 8),
			g.Vector3.new(4, -2, 8),
			g.Vector3.new(4, 1, 16),
			g.Vector3.new(4, 2, 1),
			g.Vector3.new(1, -0.5, 2),
			g.Vector3.one,
			g.Vector3.new(-2, 1, -4),
			"2, -1, 4",
		})

		local cf1 = g.CFrame.new(g.Vector3.new(1, 2, 3))
		local cf2 = g.CFrame.new(g.Vector3.zero, g.Vector3.new(0, 0, -1))
		local cfLookSame = g.CFrame.lookAt(g.Vector3.zero, g.Vector3.zero)
		local cf7, cf7Zero = g.CFrame.new(1, 2, 3, 0, 0, 0, 1), g.CFrame.new(1, 2, 3, 0, 0, 0, 0)
		local cf12 = g.CFrame.new(1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		local cfAxis = g.CFrame.fromAxisAngle(g.Vector3.yAxis, math.pi / 4)
		sert.eq({ cf1.Position, cf2.LookVector, cfLookSame.LookVector, cf7, cf7Zero }, {
			g.Vector3.new(1, 2, 3),
			g.Vector3.new(0, 0, -1),
			g.Vector3.new(0, 0, -1),
			cf12,
			cf12,
		})
		sert.eq(cfAxis:PointToObjectSpace(cfAxis:PointToWorldSpace(g.Vector3.new(1, 0, 0))), g.Vector3.new(1, 0, 0))
		sert.eq(cfAxis:VectorToObjectSpace(cfAxis:VectorToWorldSpace(g.Vector3.new(1, 0, 0))), g.Vector3.new(1, 0, 0))
		sert.eq(
			{ cf1:ToObjectSpace(cf1:ToWorldSpace(cfAxis)), g.CFrame.identity:Lerp(cf1, 0.5).Position },
			{ cfAxis, g.Vector3.new(0.5, 1, 1.5) }
		)
		local rx, ry, rz = cfAxis:ToEulerAnglesXYZ()
		local ox, oy, oz = cfAxis:ToOrientation()
		sert.near(g.CFrame.fromEulerAnglesXYZ(rx, ry, rz), cfAxis, 1e-4)
		sert.near(g.CFrame.fromOrientation(ox, oy, oz), cfAxis, 1e-4)
		local axisOut, thetaOut = cfAxis:ToAxisAngle()
		sert.near(axisOut, g.Vector3.yAxis, 1e-4)
		sert.near(thetaOut, math.pi / 4, 1e-4)
		local cf180 = g.CFrame.Angles(0, math.pi, 0)
		local lerp49 = g.CFrame.identity:Lerp(cf180, 0.49)
		local lerp51 = g.CFrame.identity:Lerp(cf180, 0.51)
		sert((lerp49.LookVector - lerp51.LookVector).Magnitude < 0.1)
		sert.eq(
			{ cf1 * g.Vector3.new(1, 1, 1), (cf1 - g.Vector3.new(1, 2, 3)).Position },
			{ g.Vector3.new(2, 3, 4), g.Vector3.zero }
		)
		sert.contains(tostring(cf12), "1, 2, 3")

		local r1, r2 = g.Rect.new(g.Vector2.new(1, 2), g.Vector2.new(5, 8)), g.Rect.new(1, 2, 5, 8)
		sert.eq({ r1, tostring(r1) }, { r2, "1, 2, 5, 8" })
		sert.eq({ g.NumberRange.new(5), tostring(g.NumberRange.new(5, 10)) }, { g.NumberRange.new(5, 5), "5 10" })
		sert.fails(function() g.NumberRange.new(10, 5) end, "NumberRange: invalid range")
		local cs1 = g.ColorSequence.new(g.Color3.new(0, 0, 0), g.Color3.new(1, 1, 1))
		sert.eq({ cs1, tostring(cs1) }, { g.ColorSequence.new(cs1.Keypoints), "0 0 0 0 0 1 1 1 1 0" })
		local ns1 = g.NumberSequence.new(0, 1)
		sert.eq({ ns1, tostring(ns1) }, { g.NumberSequence.new(ns1.Keypoints), "0 0 0 1 1 0" })
		local fck = g.FloatCurveKey.new(0.5, 1.25)
		sert.eq(fck, g.FloatCurveKey.new(0.5, 1.25))
		sert.contains(tostring(fck), "0.5 1.25")
		local f1, f2 = g.Font.fromName("Gotham", g.Enum.FontWeight.Bold, g.Enum.FontStyle.Italic), g.Font.fromId(12345)
		sert.eq({ f1.Bold, f1 }, { true, g.Font.fromName("Gotham", g.Enum.FontWeight.Bold, g.Enum.FontStyle.Italic) })
		sert.contains(tostring(f1), "Gotham")
		sert.contains(tostring(f2), "12345")
		local ti = g.TweenInfo.new(0.5, g.Enum.EasingStyle.Linear, g.Enum.EasingDirection.In, 2, true, 0.1)
		sert.eq(ti, g.TweenInfo.new(0.5, g.Enum.EasingStyle.Linear, g.Enum.EasingDirection.In, 2, true, 0.1))
		sert.contains(tostring(ti), "0.5, Linear, In")

		local dt1, dt2, dtNow =
			g.DateTime.fromUnixTimestamp(1700000000),
			g.DateTime.fromUnixTimestampMillis(1700000000500),
			g.DateTime.now()
		sert.eq({
			dt2:ToUniversalTime().Millisecond,
			dt1:FormatUniversalTime("YYYY-MM-DD HH:mm:ss", "en-us"),
			dt1,
			tostring(dt1),
			g.typeof(dtNow),
		}, {
			500,
			"2023-11-14 22:13:20",
			g.DateTime.fromUnixTimestamp(1700000000),
			"1700000000000",
			"DateTime",
		})
		sert(dtNow.UnixTimestamp > 0)
		sert.eq(D.DateTime.fromLocalTime(2023, 11, 14, 12, 0, 0, 250).UnixTimestampMillis % 1000, 250)

		local rng = g.Random.new(42)
		local rngClone = rng:Clone()
		sert.eq({ rng:NextNumber(10, 20), rng:NextInteger(5, 5) }, { rngClone:NextNumber(10, 20), 5 })
		sert.near(rng:NextUnitVector().Magnitude, 1, 1e-5)
		local arr, arr2 = { 1, 2, 3, 4 }, { 1, 2, 3, 4 }
		g.Random.new(42):Shuffle(arr)
		g.Random.new(42):Shuffle(arr2)
		sert.eq(arr, arr2)
		table.sort(arr)
		sert.eq(arr, { 1, 2, 3, 4 })

		sert(#g.Enum:GetEnums() > 10 and #g.Enum.KeyCode:GetEnumItems() > 10)
		sert.eq({
			g.Enum.KeyCode.FromName("Space"),
			g.Enum.KeyCode.FromValue(g.Enum.KeyCode.Space.Value),
			tostring(g.Enum),
			tostring(g.Enum.KeyCode),
		}, {
			g.Enum.KeyCode.Space,
			g.Enum.KeyCode.Space,
			"Enums",
			"KeyCode",
		})
	end
)

test(
	"instance · ValueBase, GetTagged, Humanoid, Destroying, API dump, defaults, classes, Clone, QueryDescendants",
	function()
		local e = sert.env.new()
		local g = e.globals
		for _, case in
			{
				{ "IntValue", 5 },
				{ "StringValue", "hi" },
				{ "BoolValue", true },
				{ "NumberValue", 1.5 },
				{ "Vector3Value", g.Vector3.new(1, 2, 3) },
				{ "CFrameValue", g.CFrame.new(1, 2, 3) },
				{ "Color3Value", g.Color3.new(1, 0, 0) },
				{ "BrickColorValue", g.BrickColor.new("Bright red") },
				{ "RayValue", D.Ray.new(g.Vector3.one, g.Vector3.xAxis) },
				{ "ObjectValue", e.Instance.new("Folder") },
			}
		do
			local inst = e.Instance.new(case[1])
			sert(inst:IsA("ValueBase"))
			local seen = {}
			inst.Changed:Connect(function(arg) table.insert(seen, arg) end)
			inst.Name = "Renamed"
			inst.Value = case[2]
			sert.eq(seen, { case[2] })
		end
		local ov = e.Instance.new("ObjectValue")
		ov.Value = e.Instance.new("Folder")
		local got = "unset"
		ov.Changed:Connect(function(arg) got = arg end)
		ov.Value = nil
		sert.eq(got, nil)

		local part = e.Instance.new("Part")
		local seenProps = {}
		part.Changed:Connect(function(prop) table.insert(seenProps, prop) end)
		part.Name = "Floor"
		sert(table.find(seenProps, "Name") ~= nil)

		local ws = e.game:GetService("Workspace")
		local inside, orphan, detachedRoot = e.Instance.new("Part", ws), e.Instance.new("Part"), e.Instance.new("Model")
		local detached = e.Instance.new("Part", detachedRoot)
		for _, inst in { inside, orphan, detached } do
			inst:AddTag("Lava")
		end
		sert.eq(InstanceDouble.getTagged(e, "Lava"), { inside })
		sert(InstanceDouble.isInDataModel(e, inside) and InstanceDouble.isInDataModel(e, e.game))
		sert(not InstanceDouble.isInDataModel(e, orphan) and not InstanceDouble.isInDataModel(e, detached))
		detachedRoot.Parent = ws
		sert.eq(InstanceDouble.getTagged(e, "Lava"), { inside, detached })
		inside.Parent = nil
		sert.eq(InstanceDouble.getTagged(e, "Lava"), { detached })
		sert.eq(InstanceDouble.getTagged(e, "Nothing"), {})

		local hum = e.Instance.new("Humanoid")
		local died, healths, states = 0, {}, {}
		hum.Died:Connect(function()
			died += 1
		end)
		hum.HealthChanged:Connect(function(h) table.insert(healths, h) end)
		hum.StateChanged:Connect(function(old, new) table.insert(states, { old, new }) end)
		hum.Health = 250
		sert.eq(hum.Health, 100)
		hum:TakeDamage(30)
		sert.eq(hum.Health, 70)
		hum.MaxHealth = 50
		sert.eq(hum.Health, 50)
		hum:TakeDamage(500)
		sert.eq({ hum.Health, died, hum:GetState(), states }, {
			0,
			1,
			g.Enum.HumanoidStateType.Dead,
			{ { g.Enum.HumanoidStateType.Running, g.Enum.HumanoidStateType.Dead } },
		})
		hum.Health = -10
		hum.Health = 20
		hum.Health = 0
		sert.eq({ died, hum:GetState(), healths }, { 1, g.Enum.HumanoidStateType.Dead, { 70, 50, 0, 20, 0 } })

		local folder = e.Instance.new("Folder")
		local fired = 0
		local conn = folder.Destroying:Connect(function()
			fired += 1
		end)
		folder:Destroy()
		sert.eq({ fired, conn.Connected }, { 1, false })

		local se = sert.env.new({ strict = true })
		sert(se.Instance.new("LocalScript"):IsA("Script") and se.Instance.new("LocalScript"):IsA("BaseScript"))
		sert(se.Instance.new("Decal"):IsA("FaceInstance") and not se.Instance.new("Decal"):IsA("BasePart"))
		sert.eq(InstanceDouble.SUPERCLASS.UnionOperation, "PartOperation")
		sert(InstanceDouble.isClass("CylinderPart", "BasePart"))
		local weld = se.Instance.new("Weld")
		local pa, pb = se.Instance.new("Part"), se.Instance.new("Part")
		weld.Part0, weld.Part1, weld.C0 = pa, pb, se.globals.CFrame.new(1, 2, 3)
		sert.eq(
			{ weld.Part0, weld.Part1, weld.C0, weld:IsA("JointInstance") },
			{ pa, pb, se.globals.CFrame.new(1, 2, 3), true }
		)
		se.Instance.new("Animator").AnimationPlayed:Connect(function()
			fired += 1
		end)
		sert.fails(function() weld.C0 = 5 end, "CFrame expected, got number")
		sert.fails(function() weld.NotAProperty = 1 end, "NotAProperty is not a valid member of Weld")
		sert.fails(function() local _ = weld.NotAProperty end, "NotAProperty is not a valid member of Weld")
		sert.fails(function() weld.ClassName = "Part" end, "Property is read only")
		sert.fails(function() se.Instance.new("Workspace") end, 'Unable to create an Instance of type "Workspace"')
		sert.fails(function() InstanceDouble.new("Workspace") end, 'Unable to create an Instance of type "Workspace"')
		sert.fails(
			function() se.Instance.new("SertNoSuchClass") end,
			'Unable to create an Instance of type "SertNoSuchClass"'
		)
		sert.eq(InstanceDouble.new("SertNoSuchClass").ClassName, "SertNoSuchClass")

		local fire = e.Instance.new("Fire")
		sert.eq(
			{ fire.Enabled, fire.Heat, e.Instance.new("Sparkles").SparkleColor },
			{ true, 9, g.Color3.new(0.564706, 0.0980392, 1) }
		)
		local made = 0
		local custom = sert.env.new({
			datatypes = {
				Color3 = {
					new = function(r, gr, b)
						made += 1
						return { custom = true, R = r, G = gr, B = b }
					end,
				},
			},
		})
		sert(custom.Instance.new("Fire").Color.custom == true and made > 0)
		local input = e.createInstance("InputObject", nil, true)
		sert(input:IsA("InputObject") and input.KeyCode == g.Enum.KeyCode.None)
		local player = e:addPlayer(5, "P5")
		e:setGroupRank(5, 42, 200, "Admin")
		e:setGroupRank(5, 43, 10)
		sert.eq(
			{ player:GetRoleInGroup(42), player:GetRoleInGroup(43), player:GetRoleInGroup(44) },
			{ "Admin", "Rank10", "Guest" }
		)

		local root = e.Instance.new("Folder", e.workspace)
		root.Name = "RootFolder"
		local subModel = e.Instance.new("Model", root)
		subModel.Name = "SubModel"
		local mainPart = e.Instance.new("Part", subModel)
		mainPart.Name = "MainPart"
		subModel.PrimaryPart = mainPart
		sert.eq({
			root:FindFirstChildOfClass("Model"),
			root:FindFirstChildOfClass("Part", true),
			root:FindFirstChildWhichIsA("BasePart", true),
			mainPart:FindFirstAncestor("RootFolder"),
			mainPart:FindFirstAncestorOfClass("Folder"),
			mainPart:FindFirstAncestorWhichIsA("Instance"),
			root:IsAncestorOf(mainPart),
		}, { subModel, mainPart, mainPart, root, root, subModel, true })

		subModel:PivotTo(g.CFrame.new(5, 6, 7))
		sert.eq({ subModel:GetPivot(), mainPart:GetPivot() }, { g.CFrame.new(5, 6, 7), g.CFrame.new(5, 6, 7) })
		subModel:MoveTo(g.Vector3.new(1, 2, 3))
		subModel:ScaleTo(2)
		sert.eq(subModel:GetScale(), 2)
		local _, ext = subModel:GetBoundingBox()
		sert.eq(ext, subModel:GetExtentsSize())
		mainPart:PivotTo(g.CFrame.new(2, 3, 4))
		sert(mainPart:GetMass() > 0)
		mainPart.AssemblyLinearVelocity = g.Vector3.new(1, 0, 0)
		mainPart:ApplyImpulse(g.Vector3.new(2, 3, 4))
		sert.eq(
			{ mainPart.AssemblyLinearVelocity, mainPart._props._lastImpulse },
			{ g.Vector3.new(3, 3, 4), g.Vector3.new(2, 3, 4) }
		)
		mainPart:SetNetworkOwner(nil)
		sert.eq(mainPart:GetNetworkOwner(), nil)

		local hum2 = e.Instance.new("Humanoid", subModel)
		hum2:TakeDamage(25)
		sert.eq(hum2.Health, 75)
		local moveReached = nil
		hum2.MoveToFinished:Connect(function(r2) moveReached = r2 end)
		hum2:MoveTo(g.Vector3.new(10, 0, 20), mainPart)
		sert.eq({ hum2.WalkToPoint, hum2.WalkToPart, moveReached }, { g.Vector3.new(10, 0, 20), mainPart, true })
		hum2:ChangeState(g.Enum.HumanoidStateType.Jumping)
		sert.eq(hum2:GetState(), g.Enum.HumanoidStateType.Jumping)
		local hdesc = hum2:GetAppliedDescription()
		hdesc:SetAccessories({ { AssetId = 1 } })
		sert.eq(#hdesc:GetAccessories(), 1)
		local customDesc, resetDesc = e.Instance.new("HumanoidDescription"), e.Instance.new("HumanoidDescription")
		hum2:ApplyDescription(customDesc)
		sert.eq(hum2:GetAppliedDescription(), customDesc)
		hum2:ApplyDescriptionReset(resetDesc)
		sert.eq(hum2:GetAppliedDescription(), resetDesc)
		local acc = e.Instance.new("Accessory")
		hum2:AddAccessory(acc)
		sert.eq({ acc.Parent, hum2:GetAccessories() }, { subModel, { acc } })
		hum2:RemoveAccessories()
		sert.eq({ hum2:GetAccessories(), acc.Parent }, { {}, nil })

		local sgui = e.Instance.new("ScreenGui", e.game)
		local scroll = e.Instance.new("ScrollingFrame", sgui)
		for _, cls in
			{
				"UIListLayout",
				"UIGridLayout",
				"UIPadding",
				"UIScale",
				"UIAspectRatioConstraint",
				"UISizeConstraint",
				"UITextSizeConstraint",
			}
		do
			sert(e.Instance.new(cls, scroll):IsA("UIComponent"))
		end
		local pageContainer = e.Instance.new("Frame", sgui)
		local pageLayout = e.Instance.new("UIPageLayout", pageContainer)
		local p1, p2 = e.Instance.new("Frame", pageContainer), e.Instance.new("Frame", pageContainer)
		pageLayout:JumpToIndex(0)
		sert.eq(pageLayout.CurrentPage, p1)
		pageLayout:Next()
		sert.eq(pageLayout.CurrentPage, p2)
		pageLayout:Previous()
		sert.eq(pageLayout.CurrentPage, p1)

		local tb1, tb2 = e.Instance.new("TextBox", sgui), e.Instance.new("TextBox", sgui)
		tb1:CaptureFocus()
		sert.eq(tb1:IsFocused(), true)
		tb2:CaptureFocus()
		sert.eq({ tb1:IsFocused(), tb2:IsFocused() }, { false, true })
		tb2:ReleaseFocus(true)
		sert.eq(tb2:IsFocused(), false)

		local snd = e.Instance.new("Sound", root)
		snd:Play()
		sert.eq(snd.Playing, true)
		snd:Pause()
		sert.eq(snd.Playing, false)
		snd:Resume()
		sert.eq(snd.Playing, true)
		snd:Stop()
		sert.eq(snd.Playing, false)

		local hap = e.Instance.new("HapticEffect", root)
		hap:SetWaveformKeys({ g.FloatCurveKey.new(0, 1) })
		hap:Play()
		sert.eq(hap.Playing, true)
		hap:Stop()
		sert.eq(hap.Playing, false)

		local cam = e.workspace.CurrentCamera
		cam.CFrame = g.CFrame.identity
		local vpPt, onScreen = cam:WorldToViewportPoint(g.Vector3.new(10, 20, -5))
		sert.eq({ onScreen, vpPt }, { true, g.Vector3.new(650, 340, 5) })
		local scrPt, scrOn = cam:WorldToScreenPoint(g.Vector3.new(-10, 5, 4))
		sert.eq({ scrOn, scrPt }, { false, g.Vector3.new(630, 355, -4) })
		local vpRay = cam:ViewportPointToRay(100, 200, 5)
		sert.eq(
			{ g.typeof(vpRay), vpRay.Origin, vpRay.Direction },
			{ "Ray", g.Vector3.new(100, 200, 5), g.Vector3.new(0, 0, -1) }
		)
		local scrRay = cam:ScreenPointToRay(50, 60)
		sert.eq(
			{ g.typeof(scrRay), scrRay.Origin, scrRay.Direction },
			{ "Ray", g.Vector3.new(50, 60, 0), g.Vector3.new(0, 0, -1) }
		)

		local be = e.Instance.new("BindableEvent")
		local beVal = nil
		be.Event:Connect(function(v) beVal = v end)
		be:Fire("hello")
		sert.eq(beVal, "hello")
		local bf = e.Instance.new("BindableFunction")
		bf.OnInvoke = function(a, b) return a + b end
		sert.eq(bf:Invoke(3, 4), 7)

		mainPart:AddTag("TaggedPart")
		sert.eq(
			{ mainPart:GetTags(), root:QueryDescendants("BasePart#MainPart.TaggedPart") },
			{ { "TaggedPart" }, { mainPart } }
		)
		local clonedRoot = root:Clone()
		sert.eq(clonedRoot.SubModel.PrimaryPart, clonedRoot.SubModel.MainPart)
		clonedRoot:ClearAllChildren()
		sert.eq(#clonedRoot:GetChildren(), 0)

		subModel.Archivable = false
		subModel:SetAttribute("Kind", "sub")
		local copied = g.Instance.fromExisting(subModel)
		sert.eq(
			{ #copied:GetChildren(), copied.Name, copied.PrimaryPart, copied:GetAttribute("Kind"), subModel:Clone() },
			{
				0,
				"SubModel",
				subModel.PrimaryPart,
				"sub",
				nil,
			}
		)

		local dFolder = e.Instance.new("Folder", e.workspace)
		local destroyCalls, reparentFailed = 0, false
		dFolder.Destroying:Connect(function()
			destroyCalls += 1
			dFolder:Destroy()
			reparentFailed = not pcall(function() dFolder.Parent = e.workspace end)
		end)
		dFolder:Destroy()
		sert.eq({ destroyCalls, reparentFailed }, { 1, true })

		local cModel = e.Instance.new("Model")
		local cChild, external = e.Instance.new("Part", cModel), e.Instance.new("Part")
		cChild.Name = "ChildPart"
		cModel:SetAttribute("InternalRef", cChild)
		cModel:SetAttribute("ExternalRef", external)
		local clonedModel = cModel:Clone()
		local clonedChild = clonedModel:FindFirstChild("ChildPart")
		sert(clonedChild ~= nil and clonedChild ~= cChild)
		sert.eq(
			{ clonedModel:GetAttribute("InternalRef"), clonedModel:GetAttribute("ExternalRef") },
			{ clonedChild, external }
		)

		local qRoot = e.Instance.new("Folder")
		local qModel = e.Instance.new("Model", qRoot)
		qModel.Name = "Rig"
		local sword = e.Instance.new("Part", qModel)
		sword.Name = "Sword"
		sword:AddTag("SwordPart")
		local holder = e.Instance.new("Folder", qModel)
		local mesh = e.Instance.new("MeshPart", holder)
		mesh.Name = "Blade"
		mesh:AddTag("SwordPart")
		mesh:SetAttribute("OnFire", true)
		mesh:SetAttribute("Variety", "Fuji")
		local apple = e.Instance.new("Part", qRoot)
		apple.Name = "Apple-1"
		apple:AddTag("Apple")
		apple.Anchored = true

		local function names(selector: string): { string }
			local out = {}
			for _, inst in qRoot:QueryDescendants(selector) do
				table.insert(out, inst.Name)
			end
			return out
		end
		for _, qCase in
			{
				{ "BasePart", { "Sword", "Blade", "Apple-1" } },
				{ "Model > .SwordPart", { "Sword" } },
				{ "Model >> .SwordPart", { "Sword", "Blade" } },
				{ "Model .SwordPart", { "Sword", "Blade" } },
				{ "> Part.Apple", { "Apple-1" } },
				{ "> .SwordPart", {} },
				{ "#Apple-1, #Sword", { "Sword", "Apple-1" } },
				{ "[$OnFire]", { "Blade" } },
				{ "[$OnFire = true][$Variety = 'Fuji']", { "Blade" } },
				{ '[$Variety = "Gala"]', {} },
				{ "[Anchored = true]", { "Apple-1" } },
				{ "[Name=Blade]", { "Blade" } },
				{ ":not(BasePart)", { "Rig", "Folder" } },
				{ "BasePart:not(.Apple, [$OnFire])", { "Sword" } },
				{ ":not(Model > .SwordPart)", { "Rig", "Folder", "Blade", "Apple-1" } },
				{ ":has(MeshPart)", { "Rig", "Folder" } },
				{ "Model:has(> .SwordPart)", { "Rig" } },
				{ "Folder:has(> :not(MeshPart))", {} },
				{ "*", { "Rig", "Sword", "Folder", "Blade", "Apple-1" } },
			}
		do
			sert.eq(names(qCase[1]), qCase[2])
		end
		sert.eq(
			{ qModel:QueryDescendants("Folder > MeshPart"), holder:QueryDescendants("Model MeshPart") },
			{ { mesh }, {} }
		)
		for _, bad in { "", "Model >", "[x", ":first-child", "Part)", ".", "[$a = ]" } do
			sert.fails(function() qRoot:QueryDescendants(bad) end, "QueryDescendants: invalid selector")
		end

		-- strict readOnly from API dump + HAND_SPECS, relayout before Changed, coupled method prop signals, Clone/fromExisting relayout, Destroy lazy signals
		local sSound = se.Instance.new("Sound")
		sert.fails(function() sSound.IsLoaded = false end, "Property is read only")
		sert.fails(function() sSound.TimeLength = 5 end, "Property is read only")
		local sPage = se.Instance.new("UIPageLayout")
		sert.fails(function() sPage.CurrentPage = nil end, "Property is read only")

		local layoutScreen = e.Instance.new("ScreenGui")
		local layoutFrame = e.Instance.new("Frame", layoutScreen)
		local observedAbsSize = nil
		layoutFrame:GetPropertyChangedSignal("Size"):Connect(function() observedAbsSize = layoutFrame.AbsoluteSize end)
		layoutFrame.Size = g.UDim2.fromOffset(250, 120)
		sert.eq(observedAbsSize, g.Vector2.new(250, 120))
		layoutFrame.Position = g.UDim2.fromScale(0.5, 0.5)
		local clonedGui = layoutFrame:Clone()
		local existingGui = g.Instance.fromExisting(layoutFrame)
		sert.eq({ clonedGui.AbsolutePosition, existingGui.AbsolutePosition }, { g.Vector2.zero, g.Vector2.zero })

		local methodProps = {}
		snd:GetPropertyChangedSignal("Playing"):Connect(function() table.insert(methodProps, snd.Playing) end)
		snd:Play()
		snd:Stop()
		sert.eq(methodProps, { true, false })

		local parentWithoutSigs = e.Instance.new("Folder")
		local childWithDestroy = e.Instance.new("Folder", parentWithoutSigs)
		local lateConn = nil
		childWithDestroy.Destroying:Connect(function()
			lateConn = parentWithoutSigs.Changed:Connect(function() end)
		end)
		parentWithoutSigs:Destroy()
		sert.eq(lateConn.Connected, false)

		-- setParent ordering, re-entrancy, strict descendant AncestryChanged, Destroy child suppression, and DataModel tag signals
		local folderA = se.Instance.new("Folder", se.workspace)
		local folderB = se.Instance.new("Folder", se.workspace)
		local mover = se.Instance.new("Model", folderA)
		local leaf = se.Instance.new("Part", mover)
		local orderLog = {}
		folderA.DescendantRemoving:Connect(function(d)
			if d == mover then table.insert(orderLog, `removing:{d.Parent == folderA}`) end
		end)
		folderA.ChildRemoved:Connect(
			function(c)
				table.insert(
					orderLog,
					`childRemoved:{c.Parent == folderB and table.find(folderB:GetChildren(), c) ~= nil}`
				)
			end
		)
		folderB.ChildAdded:Connect(function(c) table.insert(orderLog, `childAdded:{c.Parent == folderB}`) end)
		local leafAncestry = {}
		leaf.AncestryChanged:Connect(function(child, parent) table.insert(leafAncestry, { child, parent }) end)
		mover.Parent = folderB
		sert.eq(orderLog, { "removing:true", "childRemoved:true", "childAdded:true" })
		sert.eq(leafAncestry, { { mover, folderB } })

		local reentA = se.Instance.new("Folder", se.workspace)
		local reentB = se.Instance.new("Folder", se.workspace)
		local reentC = se.Instance.new("Folder", se.workspace)
		local reentNode = se.Instance.new("Part", reentA)
		local reentParents = {}
		reentA.ChildRemoved:Once(function() reentNode.Parent = reentC end)
		reentNode.AncestryChanged:Connect(function(_, newP) table.insert(reentParents, newP) end)
		reentNode.Parent = reentB
		sert.eq({ reentNode.Parent, reentParents }, { reentC, { reentC } })

		local dModel = se.Instance.new("Model", se.workspace)
		local dChild = se.Instance.new("Part", dModel)
		local selfChildRemoved = 0
		dModel.ChildRemoved:Connect(function()
			selfChildRemoved += 1
		end)
		dModel:Destroy()
		sert.eq({ selfChildRemoved, dChild.Parent }, { 0, nil })

		local cs = se.game:GetService("CollectionService")
		local addedTags, removedTags = {}, {}
		cs:GetInstanceAddedSignal("Quest"):Connect(function(inst) table.insert(addedTags, inst) end)
		cs:GetInstanceRemovedSignal("Quest")
			:Connect(function(inst) table.insert(removedTags, { inst, #cs:GetTagged("Quest") }) end)
		local detachedTree = se.Instance.new("Folder")
		local taggedChild = se.Instance.new("Part", detachedTree)
		taggedChild:AddTag("Quest")
		sert.eq(addedTags, {})
		detachedTree.Parent = se.workspace
		sert.eq(addedTags, { taggedChild })
		detachedTree:Destroy()
		sert.eq(removedTags, { { taggedChild, 0 } })
	end
)

test("doubles · DataStore, OrderedDataStore, EncodingService, HttpService, and Signal", function()
	local b = buffer.fromstring("bufdata")
	local bCopy = DataStore.copy(b)
	sert(bCopy ~= b and buffer.tostring(bCopy) == "bufdata")
	local mtObj = setmetatable({ a = 1 }, {})
	sert.eq(DataStore.copy(mtObj), mtObj)
	local cyc: any = {}
	cyc.self = cyc
	local cycCopy = DataStore.copy(cyc)
	sert(cycCopy ~= cyc and cycCopy.self == cycCopy)
	local deep: any = {}
	local cur = deep
	for _ = 1, 70 do
		cur.next = {}
		cur = cur.next
	end
	sert.fails(function() DataStore.copy(deep) end, "exceeds 64 levels")

	local advanceCount = 0
	local pages = DataStore.makePages({ 10, 20, 30 }, 2, function()
		advanceCount += 1
	end)
	sert.eq({ pages.IsFinished, pages:GetCurrentPage() }, { false, { 10, 20 } })
	pages:AdvanceToNextPageAsync()
	sert.eq({ advanceCount, pages.IsFinished, pages:GetCurrentPage() }, { 1, true, { 30 } })
	sert.fails(function() pages:AdvanceToNextPageAsync() end, "No more pages")

	local mock = DataStore.new()
	sert.eq({ mock:GetGlobalDataStore().name, mock:GetRequestBudgetForRequestType("GetAsync") }, { "_global", 1000000 })
	local std = mock:GetDataStore("Std", "s1")
	std:SetAsync("k1", "strVal", { 1 }, { GetMetadata = function() return { source = "opts" } end })
	local v1, info1 = std:GetVersionAsync("k1", "1")
	sert.eq({ v1, info1:GetMetadata() }, { "strVal", { source = "opts" } })
	local mV, mInfo = std:GetVersionAsync("k1", "999")
	sert.eq({ mV, mInfo }, { nil, nil })
	sert.fails(function() std:IncrementAsync("k1", 5) end, "current value is not a number")

	local incVal, incInfo = std:IncrementAsync(
		"numKey",
		5,
		{ 10 },
		{ GetMetadata = function() return { inc = true } end }
	)
	sert.eq({ incVal, incInfo:GetMetadata() }, { 5, { inc = true } })
	local incVal2, incInfo2 = std:IncrementAsync("numKey", nil, { 101 }, { metadata = { step = 2 } })
	sert.eq({ incVal2, incInfo2:GetMetadata() }, { 6, { step = 2 } })
	std:SetAsync("kPlain", "plainVal", { 7 }, { metadata = { tag = "plainMeta" } })
	local vPlain, infoPlain = std:GetAsync("kPlain")
	sert.eq({ vPlain, infoPlain:GetUserIds(), infoPlain:GetMetadata() }, { "plainVal", { 7 }, { tag = "plainMeta" } })

	local updVal, updInfo = std:UpdateAsync("k1", function(old, info)
		sert.eq({ old, info.Version }, { "strVal", "1" })
		return "updatedStr", { 42 }, { updated = true }
	end)
	sert.eq(
		{ updVal, updInfo.Version, updInfo:GetUserIds(), updInfo:GetMetadata() },
		{ "updatedStr", "2", { 42 }, { updated = true } }
	)
	local abortVal, abortInfo = std:UpdateAsync("numKey", function() return nil end)
	sert.eq({ abortVal, abortInfo, (std:GetAsync("numKey")) }, { nil, nil, 6 })
	sert.eq(std:SetAsync("tempKey", "x"), "1")
	sert.fails(function() std:SetAsync("tempKey", nil) end, "Argument 2 missing or nil")
	std:RemoveAsync("tempKey")
	sert.eq((std:GetAsync("tempKey")), nil)
	local remVal, remInfo = std:RemoveAsync("numKey")
	sert.eq({ remVal, remInfo.Version, remInfo:GetUserIds(), remInfo:GetMetadata() }, { 6, "2", { 101 }, { step = 2 } })
	local remNil1, remNil2 = std:RemoveAsync("numKey")
	sert.eq({ remNil1, remNil2, #std:ListVersionsAsync("k1", "Descending"):GetCurrentPage() }, { nil, nil, 2 })
	local postDelVer = std:SetAsync("numKey", 99)
	std:RemoveVersionAsync("numKey", postDelVer)
	sert.eq((std:GetAsync("numKey")), nil)

	local ods = mock:GetOrderedDataStore("Board")
	sert.fails(function() ods:SetAsync("p1", 1.5) end, "value must be an integer")
	sert.fails(function() ods:SetAsync("p1", "notanumber") end, "value must be an integer")
	sert.eq(ods:SetAsync("b", 100), nil)
	ods:SetAsync("a", 100)
	ods:SetAsync("c", 50)
	sert.eq(
		{ ods:GetAsync("b"), ods:IncrementAsync("d", 15), ods:IncrementAsync("d", 5), ods:RemoveAsync("d") },
		{ 100, 15, 20, 20 }
	)
	sert.eq(
		ods:GetSortedAsync(true, 10, 50, 100):GetCurrentPage(),
		{ { key = "c", value = 50 }, { key = "a", value = 100 }, { key = "b", value = 100 } }
	)
	sert.eq(ods:UpdateAsync("c", function(old) return old + 10 end), 60)
	sert.eq(ods:UpdateAsync("c", function() return nil end), nil)
	sert.eq(ods:RemoveAsync("c"), 60)
	ods:RemoveAsync("b")
	sert.eq(ods:GetAsync("b"), nil)

	local b3, b2, b1 = buffer.fromstring("abc"), buffer.fromstring("ab"), buffer.fromstring("a")
	local e3, e2, e1 = Encoding.base64Encode(b3), Encoding.base64Encode(b2), Encoding.base64Encode(b1)
	sert.eq({ e1, e2, e3 }, { "YQ==", "YWI=", "YWJj" })
	sert.eq({
		buffer.tostring(Encoding.base64Decode(e3) :: buffer),
		buffer.tostring(Encoding.base64Decode(e2) :: buffer),
		buffer.tostring(Encoding.base64Decode(e1) :: buffer),
		Encoding.base64Decode("abc"),
		Encoding.base64Decode("=abc"),
		Encoding.base64Decode("ab=c"),
		Encoding.base64Decode("ab$="),
	}, { "abc", "ab", "a", nil, nil, nil, nil })

	local service = Encoding.new()
	local rawParts = {}
	for i = 1, 140 do
		table.insert(rawParts, string.char((i * 7) % 251))
	end
	table.insert(rawParts, string.rep("Z", 50))
	local rawStr = table.concat(rawParts)
	local rawBuf = buffer.fromstring(rawStr)
	local c1 = service:CompressBuffer(rawBuf, "Zstd")
	local c2 = service:CompressBuffer(rawBuf, "Enum.CompressionAlgorithm.Zstd", -7)
	local c3 = service:CompressBuffer(rawBuf, "Zstd", 22)
	sert.eq({ service.levels, service.calls.CompressBuffer, buffer.tostring(c1), buffer.tostring(c2) }, {
		{ 1, -7, 22 },
		3,
		buffer.tostring(c2),
		buffer.tostring(c3),
	})
	for _, lv in { 1.5, -8, 23 } do
		sert.fails(function() service:CompressBuffer(rawBuf, "Zstd", lv) end, "zstd level must be an integer")
	end
	sert.fails(function() service:CompressBuffer(rawBuf, "Lz4") end, "unsupported algorithm")
	local badMagic, hugeSize = buffer.create(8), buffer.create(8)
	buffer.writeu32(badMagic, 0, 0x12345678)
	buffer.copy(hugeSize, 0, c1, 0, 4)
	buffer.writeu32(hugeSize, 4, 2000000000)
	sert.eq({
		service:GetDecompressedBufferSize(c1, "Zstd"),
		service:GetDecompressedBufferSize(buffer.create(4), "Zstd"),
		service:GetDecompressedBufferSize(badMagic, "Zstd"),
		service:GetDecompressedBufferSize(hugeSize, "Zstd"),
		buffer.tostring(service:DecompressBuffer(c1, "Zstd")),
	}, { #rawStr, nil, nil, nil, rawStr })
	sert.fails(function() service:DecompressBuffer(badMagic, "Zstd") end, "not a compressed buffer")

	local corruptLit, corruptRep, mismatch = buffer.create(9), buffer.create(9), buffer.create(8)
	buffer.copy(corruptLit, 0, c1, 0, 4)
	buffer.writeu32(corruptLit, 4, 10)
	buffer.writeu8(corruptLit, 8, 20)
	buffer.copy(corruptRep, 0, c1, 0, 4)
	buffer.writeu32(corruptRep, 4, 10)
	buffer.writeu8(corruptRep, 8, 130)
	buffer.copy(mismatch, 0, c1, 0, 4)
	buffer.writeu32(mismatch, 4, 5)
	sert.fails(function() service:DecompressBuffer(corruptLit, "Zstd") end, "corrupt literal run")
	sert.fails(function() service:DecompressBuffer(corruptRep, "Zstd") end, "corrupt repeat run")
	sert.fails(function() service:DecompressBuffer(mismatch, "Zstd") end, "decompressed size differs")

	sert.eq(buffer.tostring(service:Base64Decode(service:Base64Encode(b3))), "abc")
	sert.fails(function() service:Base64Decode(buffer.fromstring("!!!")) end, "invalid Base64")
	local hBlake3 = service:ComputeBufferHash(b3, "Blake3")
	local hSha256 = service:ComputeBufferHash(b3, "Enum.HashAlgorithm.Sha256")
	sert.eq({
		buffer.len(hBlake3),
		buffer.len(hSha256),
		buffer.len(service:ComputeBufferHash(b3, "Enum.HashAlgorithm.Blake2b")),
		buffer.len(service:ComputeBufferHash(b3, "Sha1")),
		buffer.len(service:ComputeBufferHash(b3, "Md5")),
	}, { 32, 32, 32, 20, 16 })
	sert(buffer.tostring(hBlake3) ~= buffer.tostring(hSha256))
	local expectedHex = (
		string.gsub(buffer.tostring(hBlake3), ".", function(c) return string.format("%02x", string.byte(c)) end)
	)
	sert.eq(service:ComputeStringHash("abc", "Blake3"), expectedHex)
	sert.fails(function() service:ComputeBufferHash(b3, "Crc32") end, "unsupported hash algorithm")
	sert.fails(function() service:ComputeStringHash("abc", "Crc32") end, "unsupported hash algorithm")

	local h = Http.new({ prefix = 0x12345678 })
	sert.eq({ h:GenerateGUID(false), h:GenerateGUID(true) }, {
		"12345678-4E5F-4061-5678-000000000001",
		"{12345678-4E5F-4061-5678-000000000002}",
	})
	local encoded = h:JSONEncode({
		b = true,
		f = false,
		fl = 1.5,
		ctrl = 'a"b\\c\bd\fe\nf\rg\th\x01',
		buf = buffer.fromstring("hi"),
		arr = { [1] = "x", [3] = "z" },
	})
	sert.contains(encoded, '["x",null,"z"]')
	local decoded = h:JSONDecode(encoded)
	sert.eq({ decoded.b, decoded.f, decoded.fl, decoded.ctrl, buffer.tostring(decoded.buf), decoded.arr }, {
		true,
		false,
		1.5,
		'a"b\\c\bd\fe\nf\rg\th\x01',
		"hi",
		{ "x", "z" },
	})
	sert.eq({ h:JSONDecode("{}"), h:JSONDecode("[]"), h:JSONEncode(nil) }, { {}, {}, "null" })
	local deepJson: any = {}
	local curJ = deepJson
	for _ = 1, 105 do
		curJ.next = {}
		curJ = curJ.next
	end
	for _, encBad in
		{
			{ 0 / 0, "non-finite" },
			{ math.huge, "non-finite" },
			{ deepJson, "nesting too deep" },
			{ { [1] = "a", key = "b" }, "mixed or non-string keys" },
			{ function() end, "can't convert a function" },
		}
	do
		sert.fails(function() h:JSONEncode(encBad[1]) end, encBad[2])
	end
	for _, decBad in
		{
			{ '"unterminated', "unterminated string" },
			{ '"\\uZZZZ"', "invalid \\u escape" },
			{ "truX", "invalid JSON" },
			{ "@", "invalid JSON" },
			{ "123 extra", "trailing characters" },
			{ '{"t":"buffer","base64":"!!!"}', "invalid buffer Base64" },
		}
	do
		sert.fails(function() h:JSONDecode(decBad[1]) end, decBad[2])
	end

	local emptyCount, dispatched, resumed, errors = 0, 0, 0, {}
	local sig = Signal.new({
		dispatch = function(fn, ...)
			dispatched += 1
			fn(...)
		end,
		resume = function(co, ...)
			resumed += 1
			coroutine.resume(co, ...)
		end,
	}, function()
		emptyCount += 1
	end)
	sert.eq(
		{ Signal.is(sig), Signal.is({}), tostring(sig), sig:connected() },
		{ true, false, "RBXScriptSignal", false }
	)
	local c1Count, c2Count = 0, 0
	local sc1 = sig:Connect(function()
		c1Count += 1
	end)
	local sc2 = sig:ConnectParallel(function()
		c2Count += 1
	end)
	sert.eq({
		Signal.isConnection(sc1),
		Signal.isConnection({}),
		tostring(sc1),
		sig:connections(),
		sig:connected(),
		sc1.Connected,
	}, {
		true,
		false,
		"RBXScriptConnection",
		2,
		true,
		true,
	})
	sc1:Disconnect()
	sc1:Disconnect()
	sert.eq({ sc1.Connected, rawget(sc1 :: any, "_signal"), emptyCount }, { false, nil, 0 })
	sig:Fire("after")
	sc2:Disconnect()
	sert.eq({ c1Count, c2Count, sc2.Connected, emptyCount }, { 0, 1, false, 1 })

	local onceVal = nil
	sig:Once(function(v) onceVal = v end)
	sig:Fire(42)
	sert.eq({ onceVal, dispatched, emptyCount }, { 42, 2, 2 })
	local stepCount = 0
	sert.eq(
		sig:Wait(function()
			stepCount += 1
			if stepCount == 2 then sig:Fire("fromYieldFn") end
		end),
		"fromYieldFn"
	)

	local waitedVal = nil
	local co = coroutine.create(function()
		waitedVal = sig:Wait()
		return waitedVal
	end)
	coroutine.resume(co)
	sert.eq(coroutine.status(co), "suspended")
	sig:Fire("coResumed")
	sert.eq({ resumed, waitedVal, coroutine.status(co) }, { 1, "coResumed", "dead" })

	local deadCo = coroutine.create(function() sig:Wait() end)
	coroutine.resume(deadCo)
	local deadConn = (sig :: any)._listeners[1]
	coroutine.close(deadCo)
	sert.eq({ sig:connections(), deadConn.Connected, rawget(deadConn, "_signal") }, { 0, false, nil })

	local sc3 = sig:Connect(function() end)
	sig:DisconnectAll()
	sert.eq({ sc3.Connected, rawget(sc3 :: any, "_signal"), emptyCount }, { false, nil, 5 })

	local w = sert.sim.World.new()
	local s1 = w:server()
	local wSig = Signal.fromWorld(w, s1)
	local gotDepth0, gotDepth1, gotInsideSpawn = nil, nil, "unset"
	w.scheduler:spawn(s1, function() gotDepth0 = wSig:Wait() end)
	wSig:Fire("atDepth0")
	sert.eq(gotDepth0, "atDepth0")
	w.scheduler:spawn(s1, function() gotDepth1 = wSig:Wait() end)
	w.scheduler:spawn(s1, function()
		wSig:Fire("atDepth1")
		gotInsideSpawn = tostring(gotDepth1)
	end)
	sert.eq({ gotInsideSpawn, gotDepth1 }, { "nil", "atDepth1" })

	local hostSig = Signal.new({ onError = function(err) table.insert(errors, tostring(err)) end })
	local errCo = coroutine.create(function()
		hostSig:Wait()
		error("waiter boom")
	end)
	coroutine.resume(errCo)
	hostSig:Fire()
	sert.eq(#errors, 1)
	sert.contains(errors[1], "waiter boom")

	local sig2 = Signal.new()
	local seen = {}
	local lConn = sig2:connect(function(v) table.insert(seen, v) end)
	local lPar = sig2:connectParallel(function(v) table.insert(seen, -v) end)
	sig2:Fire(1)
	lConn:disconnect()
	sig2:Fire(2)
	lPar:Disconnect()
	sert.eq({ lConn.Connected, seen, Signal.new().wait }, { false, { 1, -1, -2 }, Signal.new().Wait })
	local beats = 0
	local envE = sert.env.new()
	envE.game:GetService("RunService").Heartbeat:connect(function()
		beats += 1
	end)
	envE:step()
	sert.eq(beats, 1)

	-- Budget.charge multi-unit same-type tally & MemoryStoreSortedMap exclusive sortKey bounds without key
	local bClock = 0
	local bgt = DataStore.budget(function() return bClock end, 1)
	sert.eq(bgt:charge({ "GetAsync", "GetAsync" }), "GetAsync")
	sert.eq(bgt:remaining("GetAsync"), 1)
	sert.eq(bgt:charge({ "GetAsync" }), nil)
	sert.eq(bgt:remaining("GetAsync"), 0)

	local ms = sert.doubles.MemoryStore.new()
	local sm = ms:GetSortedMap("RangeBounds")
	sm:SetAsync("a", 1, 60, 10)
	sm:SetAsync("b", 2, 60, 20)
	sm:SetAsync("c", 3, 60, 30)
	local exclusive = sm:GetRangeAsync(Enum.SortDirection.Ascending, 10, { sortKey = 10 }, { sortKey = 30 })
	sert.eq(#exclusive, 1)
	sert.eq(exclusive[1].key, "b")

	-- DateTime.fromLocalTime -> ToLocalTime / FormatLocalTime round-trip
	local dtLocal = Datatypes.DateTime.fromLocalTime(2025, 6, 15, 14, 30, 45, 125)
	sert.eq(dtLocal:ToLocalTime(), {
		Year = 2025,
		Month = 6,
		Day = 15,
		Hour = 14,
		Minute = 30,
		Second = 45,
		Millisecond = 125,
	})
	sert.eq(dtLocal:FormatLocalTime(), "2025-06-15 14:30:45")

	-- OrderedDataStore:GetSortedAsync pageSize & minValue/maxValue validation
	local dsVal = DataStore.new()
	local odsVal = dsVal:GetOrderedDataStore("SortedVal")
	sert.fails(function() odsVal:GetSortedAsync(true, 0) end, "pageSize must be an integer in 1..100")
	sert.fails(function() odsVal:GetSortedAsync(true, 101) end, "pageSize must be an integer in 1..100")
	sert.fails(function() odsVal:GetSortedAsync(true, 2.5) end, "pageSize must be an integer in 1..100")
	sert.fails(function() odsVal:GetSortedAsync(true, 10, 50, 10) end, "minValue cannot be greater than maxValue")

	-- MemoryStore:evict with key ~= nil and expired queue entries
	local msEvict = sert.doubles.MemoryStore.new()
	local eqQueue = msEvict:GetQueue("ExpiredQ")
	eqQueue:AddAsync("soonExpired", 5)
	msEvict:step(10)
	sert.eq(msEvict:evict("ExpiredQ"), nil)
	eqQueue:AddAsync("liveItem", 60)
	sert.eq(msEvict:evict(nil, "missingKey"), nil)
	sert.eq(eqQueue:GetSizeAsync(false), 1)
end)

return nil
