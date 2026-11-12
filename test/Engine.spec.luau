--!strict
-- Headless Roblox datatypes and engine services exposed through `sert.env.new()`.

local sert = require("../src")

local describe = sert.describe
local test = sert.test

describe("Engine datatypes via sert.env.new()", function()
	test("enforces exact == on datatypes while supporting sert.near, sert.within, and FuzzyEq", function()
		local e = sert.env.new()
		local g = e.globals
		local Vector2, Vector3, CFrame = g.Vector2, g.Vector3, g.CFrame
		local Color3, UDim, UDim2 = g.Color3, g.UDim, g.UDim2
		local Rect, NumberRange = g.Rect, g.NumberRange

		local v2a = Vector2.new(1, 2)
		local v2b = Vector2.new(1 + 1e-7, 2)
		sert.eq(v2a, Vector2.new(1, 2))
		sert.ne(v2a, v2b)
		sert.ok(v2a ~= v2b)
		sert.near(v2a, v2b, 1e-6)
		sert.ok(v2a:FuzzyEq(v2b, 1e-6))

		local v3a = Vector3.new(1, 2, 3)
		local v3b = Vector3.new(1, 2 + 1e-7, 3)
		sert.eq(v3a, Vector3.new(1, 2, 3))
		sert.ne(v3a, v3b)
		sert.ok(v3a ~= v3b)
		sert.near(v3a, v3b, 1e-6)
		sert.ok(v3a:FuzzyEq(v3b, 1e-6))

		local keyed: { [any]: string } = { [v3a] = "exact" }
		sert.eq(keyed[Vector3.new(1, 2, 3)], "exact")
		sert.eq(keyed[v3b], nil)

		local cfa = CFrame.new(1, 2, 3)
		local cfb = CFrame.new(1, 2, 3 + 1e-7)
		sert.eq(cfa, CFrame.new(1, 2, 3))
		sert.ne(cfa, cfb)
		sert.ok(cfa ~= cfb)
		sert.near(cfa, cfb, 1e-6)
		sert.ok(cfa:FuzzyEq(cfb, 1e-6))

		local ca = Color3.new(0.25, 0.5, 0.75)
		local cb = Color3.new(0.25 + 1e-7, 0.5, 0.75)
		sert.eq(ca, Color3.new(0.25, 0.5, 0.75))
		sert.ne(ca, cb)
		sert.near(ca, cb, 1e-6)

		local uda = UDim.new(0.5, 10)
		local udb = UDim.new(0.5 + 1e-7, 10)
		sert.eq(uda, UDim.new(0.5, 10))
		sert.ne(uda, udb)
		sert.eq({ pad = udb }, { pad = sert.within(uda, 1e-6) })

		local ud2a = UDim2.new(0.5, 10, 0.25, 20)
		local ud2b = UDim2.new(0.5 + 1e-7, 10, 0.25, 20)
		sert.eq(ud2a, UDim2.new(0.5, 10, 0.25, 20))
		sert.ne(ud2a, ud2b)
		sert.near(ud2a, ud2b, 1e-6)

		local ra = Rect.new(0, 0, 10, 20)
		local rb = Rect.new(0, 0, 10 + 1e-7, 20)
		sert.ne(ra, rb)
		sert.near(ra, rb, 1e-6)

		local nra = NumberRange.new(1, 5)
		local nrb = NumberRange.new(1, 5 + 1e-7)
		sert.ne(nra, nrb)
		sert.near(nra, nrb, 1e-6)

		sert.eq({
			v2 = v2b,
			v3 = v3b,
			cf = cfb,
			color = cb,
			ud2 = ud2b,
		}, {
			v2 = sert.within(v2a, 1e-6),
			v3 = sert.within(v3a, 1e-6),
			cf = sert.within(cfa, 1e-6),
			color = sert.within(ca, 1e-6),
			ud2 = sert.within(ud2a, 1e-6),
		})
	end)

	test(
		"computes exact CFrame YXZ orientation, gimbal-lock Euler roundtrips, lookAt/lookAlong, and basis ops",
		function()
			local e = sert.env.new()
			local CFrame, Vector3 = e.globals.CFrame, e.globals.Vector3

			-- Exact matrix identity for fromEulerAnglesYXZ / fromOrientation: R_y(ry) * R_x(rx) * R_z(rz) -> r02 = sy * cx
			for _, angles in { { 0.4, 0.7, 1.1 }, { -0.8, 1.3, -0.5 }, { 1.2, -0.9, 2.1 } } do
				local rx, ry, rz = angles[1], angles[2], angles[3]
				local yxz = CFrame.fromEulerAnglesYXZ(rx, ry, rz)
				local orient = CFrame.fromOrientation(rx, ry, rz)
				local composed = CFrame.Angles(0, ry, 0) * CFrame.Angles(rx, 0, 0) * CFrame.Angles(0, 0, rz)
				sert.near(yxz, orient, 1e-9)
				sert.near(yxz, composed, 1e-6)
				local _, _, _, _, _, r02 = yxz:GetComponents()
				sert.near(r02, math.sin(ry) * math.cos(rx), 1e-9)
			end

			-- Gimbal-lock roundtrips at ±pi/2 for both XYZ and YXZ orders
			for _, sign in { 1, -1 } do
				local halfPi = sign * (math.pi / 2)
				local targetXYZ = CFrame.fromEulerAnglesXYZ(0.35, halfPi, -0.6)
				local ex, ey, ez = targetXYZ:ToEulerAnglesXYZ()
				sert.near(CFrame.fromEulerAnglesXYZ(ex, ey, ez), targetXYZ, 1e-5)

				local targetYXZ = CFrame.fromEulerAnglesYXZ(halfPi, 0.45, -0.7)
				local ox, oy, oz = targetYXZ:ToEulerAnglesYXZ()
				sert.near(CFrame.fromEulerAnglesYXZ(ox, oy, oz), targetYXZ, 1e-5)
			end

			-- Parallel-up lookAt produces finite orthonormal matrices with zero NaNs
			for _, target in { Vector3.yAxis, Vector3.new(0, -5, 0), Vector3.xAxis, -Vector3.xAxis } do
				local up = if math.abs(target.X) > 0 then Vector3.xAxis else Vector3.yAxis
				local cf = CFrame.lookAt(Vector3.zero, target, up)
				local comps = { cf:GetComponents() }
				for _, comp in comps do
					sert.ok(comp == comp and math.abs(comp) < math.huge)
				end
				sert.near(cf.XVector.Magnitude, 1, 1e-6)
				sert.near(cf.YVector.Magnitude, 1, 1e-6)
				sert.near(cf.ZVector.Magnitude, 1, 1e-6)
				sert.near(cf.XVector:Dot(cf.YVector), 0, 1e-6)
				sert.near(cf.XVector:Cross(cf.YVector), cf.ZVector, 1e-6)
				sert.near(cf.LookVector, target.Unit, 1e-6)
			end

			-- lookAlong with normal, collinear-up, and zero direction
			local along = CFrame.lookAlong(Vector3.new(1, 2, 3), Vector3.new(0, 1, 0), Vector3.yAxis)
			sert.eq(along.Position, Vector3.new(1, 2, 3))
			sert.near(along.LookVector, Vector3.yAxis, 1e-6)
			sert.near(along.XVector:Cross(along.YVector), along.ZVector, 1e-6)
			local zeroAlong = CFrame.lookAlong(Vector3.zero, Vector3.zero)
			sert.near(zeroAlong.LookVector, -Vector3.zAxis, 1e-6)

			-- fromRotationBetweenVectors: general, parallel, antiparallel, zero
			local rotXY = CFrame.fromRotationBetweenVectors(Vector3.xAxis, Vector3.yAxis)
			sert.near(rotXY:VectorToWorldSpace(Vector3.xAxis), Vector3.yAxis, 1e-6)
			sert.eq(CFrame.fromRotationBetweenVectors(Vector3.xAxis, Vector3.xAxis * 3), CFrame.identity)
			sert.eq(CFrame.fromRotationBetweenVectors(Vector3.zero, Vector3.yAxis), CFrame.identity)

			for _, axis in { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, Vector3.new(1, 2, 3).Unit } do
				local anti = CFrame.fromRotationBetweenVectors(axis, -axis)
				sert.near(anti:VectorToWorldSpace(axis), -axis, 1e-6)
				sert.near(anti.XVector:Cross(anti.YVector), anti.ZVector, 1e-6)
			end

			-- Orthonormalize & XVector/YVector/ZVector & variadic space transforms
			local skewed = CFrame.fromMatrix(
				Vector3.new(4, 5, 6),
				Vector3.new(2, 0.1, 0),
				Vector3.new(0.2, 3, 0),
				Vector3.new(0, 0, 4)
			)
			local ortho = skewed:Orthonormalize()
			sert.eq(ortho.Position, Vector3.new(4, 5, 6))
			sert.near(ortho.XVector.Magnitude, 1, 1e-6)
			sert.near(ortho.YVector.Magnitude, 1, 1e-6)
			sert.near(ortho.ZVector.Magnitude, 1, 1e-6)
			sert.near(ortho.XVector:Dot(ortho.YVector), 0, 1e-6)
			sert.eq(ortho.XVector, ortho.RightVector)
			sert.eq(ortho.YVector, ortho.UpVector)
			sert.eq(ortho.ZVector, -ortho.LookVector)

			local frame = CFrame.new(10, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
			local p1, p2 = frame:PointToWorldSpace(Vector3.new(0, 0, -2), Vector3.new(1, 3, 0))
			local o1, o2 = frame:PointToObjectSpace(p1, p2)
			sert.near(o1, Vector3.new(0, 0, -2), 1e-6)
			sert.near(o2, Vector3.new(1, 3, 0), 1e-6)

			local w1, w2 = frame:VectorToWorldSpace(Vector3.xAxis, Vector3.zAxis)
			local b1, b2 = frame:VectorToObjectSpace(w1, w2)
			sert.near(b1, Vector3.xAxis, 1e-6)
			sert.near(b2, Vector3.zAxis, 1e-6)
		end
	)

	test("supports Vector2/Vector3 floor division, Angle, scalar-div rejection, and unary -UDim/-UDim2", function()
		local e = sert.env.new()
		local Vector2, Vector3 = e.globals.Vector2, e.globals.Vector3
		local UDim, UDim2 = e.globals.UDim, e.globals.UDim2

		sert.eq(Vector2.new(7, -7) // 2, Vector2.new(3, -4))
		sert.eq(Vector2.new(9, -5) // Vector2.new(4, 2), Vector2.new(2, -3))
		sert.eq(Vector3.new(7, -7, 15) // 4, Vector3.new(1, -2, 3))
		sert.eq(Vector3.new(9, -5, 11) // Vector3.new(4, 2, 3), Vector3.new(2, -3, 3))

		sert.near(Vector3.xAxis:Angle(Vector3.yAxis), math.pi / 2, 1e-6)
		sert.near(Vector3.xAxis:Angle(Vector3.yAxis, Vector3.zAxis), math.pi / 2, 1e-6)
		sert.near(Vector3.yAxis:Angle(Vector3.xAxis, Vector3.zAxis), -math.pi / 2, 1e-6)

		sert.throws(function() local _ = (1 :: any) / Vector3.one end)
		sert.throws(function() local _ = (1 :: any) / Vector2.one end)

		sert.eq(-UDim.new(0.25, -12), UDim.new(-0.25, 12))
		sert.eq(-UDim2.new(0.5, -10, -0.25, 8), UDim2.new(-0.5, 10, 0.25, -8))
	end)

	test("validates Sequences, Params, DateTime tokens, BrickColor, Random, Enum, Font, and utf8.graphemes", function()
		local e = sert.env.new()
		local g = e.globals
		local Color3 = g.Color3
		local ColorSequence, ColorSequenceKeypoint = g.ColorSequence, g.ColorSequenceKeypoint
		local NumberSequence, NumberSequenceKeypoint = g.NumberSequence, g.NumberSequenceKeypoint

		-- Sequence validation: < 2 keypoints, unsorted times, first ~= 0, last ~= 1
		sert.throws(function() return ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)) }) end)
		sert.throws(
			function()
				return ColorSequence.new({
					ColorSequenceKeypoint.new(0.2, Color3.new(1, 0, 0)),
					ColorSequenceKeypoint.new(1, Color3.new(0, 1, 0)),
				})
			end
		)
		sert.throws(
			function()
				return ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)),
					ColorSequenceKeypoint.new(0.8, Color3.new(0, 1, 0)),
				})
			end
		)
		sert.throws(
			function()
				return ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)),
					ColorSequenceKeypoint.new(0.7, Color3.new(0, 1, 0)),
					ColorSequenceKeypoint.new(0.3, Color3.new(0, 0, 1)),
					ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
				})
			end
		)

		sert.throws(function() return NumberSequence.new({ NumberSequenceKeypoint.new(0, 1) }) end)
		sert.throws(
			function()
				return NumberSequence.new({
					NumberSequenceKeypoint.new(0.1, 0),
					NumberSequenceKeypoint.new(1, 1),
				})
			end
		)
		sert.throws(
			function()
				return NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(0.9, 1),
				})
			end
		)
		sert.throws(
			function()
				return NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(0.6, 0.5),
					NumberSequenceKeypoint.new(0.4, 0.5),
					NumberSequenceKeypoint.new(1, 1),
				})
			end
		)

		local cs = ColorSequence.new(Color3.new(0, 0, 0), Color3.new(1, 1, 1))
		local ns = NumberSequence.new(0.5)
		sert.eq({ #cs.Keypoints, #ns.Keypoints, ns.Keypoints[1].Value }, { 2, 2, 0.5 })

		-- BrickColor, PhysicalProperties, Rect, Region3, NumberRange, Ray
		local bc = g.BrickColor.new("Bright blue")
		sert.eq({ g.typeof(bc), bc.Name }, { "BrickColor", "Bright blue" })
		local pp = g.PhysicalProperties.new(g.Enum.Material.Plastic)
		sert.near(pp.Density, 0.7, 1e-3)
		local rect = g.Rect.new(10, 20, 50, 80)
		sert.eq({ rect.Width, rect.Height }, { 40, 60 })
		local reg = g.Region3.new(g.Vector3.zero, g.Vector3.new(4, 2, 6)):ExpandToGrid(4)
		sert.eq(reg.Size, g.Vector3.new(4, 4, 8))
		local nr = g.NumberRange.new(3)
		sert.eq({ nr.Min, nr.Max }, { 3, 3 })
		local ray = g.Ray.new(g.Vector3.zero, g.Vector3.new(10, 0, 0))
		sert.eq(ray:ClosestPoint(g.Vector3.new(4, 3, 0)), g.Vector3.new(4, 0, 0))
		sert.near(ray:Distance(g.Vector3.new(4, 3, 0)), 3, 1e-6)

		-- RaycastParams & OverlapParams nullable FilterDescendantsInstances = nil
		local p = e.Instance.new("Part")
		local rp = g.RaycastParams.new()
		rp:AddToFilter(p)
		sert.eq(#rp.FilterDescendantsInstances, 1)
		rp.FilterDescendantsInstances = nil :: any
		sert.eq(rp.FilterDescendantsInstances, {})

		local op = g.OverlapParams.new()
		op:AddToFilter(p)
		sert.eq(#op.FilterDescendantsInstances, 1)
		op.FilterDescendantsInstances = nil :: any
		sert.eq(op.FilterDescendantsInstances, {})

		local csp = g.CatalogSearchParams.new()
		csp.SearchKeyword = "sword"
		sert.eq(csp.SearchKeyword, "sword")

		local wp = g.PathWaypoint.new(g.Vector3.new(1, 2, 3), g.Enum.PathWaypointAction.Jump, "gap")
		sert.eq({ wp.Position, wp.Action, wp.Label }, { g.Vector3.new(1, 2, 3), g.Enum.PathWaypointAction.Jump, "gap" })

		local font = g.Font.fromEnum(g.Enum.Font.GothamBold)
		sert.eq(g.typeof(font), "Font")
		local ti = g.TweenInfo.new(0.5, g.Enum.EasingStyle.Quad, g.Enum.EasingDirection.Out, 2, true, 0.1)
		sert.eq(ti.Time, 0.5)
		sert.eq(ti.RepeatCount, 2)
		sert.eq(ti.Reverses, true)

		-- DateTime FormatUniversalTime tokens: YYYY, YY, MM, DD, HH, hh, mm, ss, SSS, A, a
		local dtPm = g.DateTime.fromUniversalTime(2026, 3, 7, 15, 4, 9, 42)
		sert.eq(
			dtPm:FormatUniversalTime("YYYY-YY-MM-DD HH:hh:mm:ss.SSS A a", "en-us"),
			"2026-26-03-07 15:03:04:09.042 PM pm"
		)
		local dtAm = g.DateTime.fromUniversalTime(2026, 12, 31, 0, 59, 58, 7)
		sert.eq(
			dtAm:FormatUniversalTime("YYYY-YY-MM-DD HH:hh:mm:ss.SSS A a", "en-us"),
			"2026-26-12-31 00:12:59:58.007 AM am"
		)

		-- Random determinism, strict Enum, and utf8.graphemes
		local r1, r2 = g.Random.new(12345), g.Random.new(12345)
		sert.eq(r1:NextInteger(1, 1000), r2:NextInteger(1, 1000))
		sert.eq(r1:NextNumber(), r2:NextNumber())
		sert.near(r1:NextUnitVector().Magnitude, 1, 1e-6)
		sert.throws(function() local _ = e.Enum.KeyCode.NoSuchKey end)

		local clusters: { string } = {}
		local sample = "Aé🚀"
		for sIdx, eIdx in g.utf8.graphemes(sample) do
			table.insert(clusters, string.sub(sample, sIdx, eIdx))
		end
		sert.eq(clusters, { "A", "é", "🚀" })
	end)
end)

describe("Engine services via sert.env.new()", function()
	test(
		"DataStoreService enforces JSON tree cloning, quotas, non-yielding UpdateAsync, and OrderedDataStore",
		function()
			local e = sert.env.new()
			local dss = e:getService("DataStoreService")
			local store = dss:GetDataStore("Profiles")

			-- Shared sub-table returns two independent tree copies without DAG aliasing
			local shared = { coins = 50, items = { "sword" } }
			store:SetAsync("p1", { a = shared, b = shared })
			shared.coins = 999
			local got, info = store:GetAsync("p1")
			sert.eq(got, {
				a = { coins = 50, items = { "sword" } },
				b = { coins = 50, items = { "sword" } },
			})
			sert.ok(got.a ~= got.b)
			sert.ok(got.a.items ~= got.b.items)
			got.a.coins = 0
			sert.eq(got.b.coins, 50)
			sert.eq(e.typeof(info), "DataStoreKeyInfo")

			-- Rejects cyclic tables, NaN/Inf, > 4MB values, and > 50-char keys
			local cyc: { [string]: any } = {}
			cyc.self = cyc
			sert.throws(function() store:SetAsync("cyc", cyc) end)
			sert.throws(function() store:SetAsync("nan", { x = 0 / 0 }) end)
			sert.throws(function() store:SetAsync("inf", { x = math.huge }) end)
			sert.throws(function() store:SetAsync("ninf", { x = -math.huge }) end)
			sert.throws(function() store:SetAsync("big", string.rep("x", 4 * 1024 * 1024 + 16)) end)
			sert.throws(function() store:SetAsync(string.rep("k", 51), 1) end)

			-- UpdateAsync, IncrementAsync, RemoveAsync, ListKeysAsync
			local setOpts = e.Instance.new("DataStoreSetOptions")
			setOpts:SetMetadata({ schema = 2 })
			local incVal, incInfo = store:IncrementAsync("counter", 5, { 101 }, setOpts)
			sert.eq(incVal, 5)
			sert.eq(incInfo:GetUserIds(), { 101 })
			sert.eq(incInfo:GetMetadata(), { schema = 2 })

			local updVal, updInfo = store:UpdateAsync("counter", function(old: any, keyInfo: any)
				sert.eq(old, 5)
				sert.eq(keyInfo:GetMetadata(), { schema = 2 })
				return old + 10, { 101, 202 }, { schema = 3 }
			end)
			sert.eq(updVal, 15)
			sert.eq(updInfo:GetUserIds(), { 101, 202 })
			sert.eq(updInfo:GetMetadata(), { schema = 3 })

			sert.throws(function()
				store:UpdateAsync("counter", function()
					coroutine.yield()
					return 0
				end)
			end, "cannot yield")

			store:SetAsync("user:1", { ok = true })
			store:SetAsync("user:2", { ok = true })
			local pages = store:ListKeysAsync("user:", 1)
			local seenKeys: { string } = {}
			while true do
				for _, item in pages:GetCurrentPage() do
					table.insert(seenKeys, item.KeyName)
				end
				if pages.IsFinished then break end
				pages:AdvanceToNextPageAsync()
			end
			sert.eq(seenKeys, { "user:1", "user:2" })

			local removed = store:RemoveAsync("counter")
			sert.eq(removed, 15)
			local afterRemove = store:GetAsync("counter")
			sert.eq(afterRemove, nil)

			-- OrderedDataStore: integer-only, ascending/descending, minValue/maxValue, DataStoreKeyInfo
			local ods = dss:GetOrderedDataStore("Leaderboard")
			sert.throws(function() ods:SetAsync("u1", 12.5) end, "integer")
			ods:SetAsync("u1", 100, { 1 }, setOpts)
			ods:SetAsync("u2", 300)
			ods:SetAsync("u3", 200)
			local oVal, oInfo = ods:GetAsync("u1")
			sert.eq(oVal, 100)
			sert.eq(e.typeof(oInfo), "DataStoreKeyInfo")
			sert.eq(oInfo:GetUserIds(), { 1 })
			sert.eq(oInfo:GetMetadata(), { schema = 2 })

			local descPages = ods:GetSortedAsync(false, 10, 150, 350)
			sert.eq(descPages:GetCurrentPage(), {
				{ key = "u2", value = 300 },
				{ key = "u3", value = 200 },
			})
			local ascPages = ods:GetSortedAsync(true, 10, 100, 250)
			sert.eq(ascPages:GetCurrentPage(), {
				{ key = "u1", value = 100 },
				{ key = "u3", value = 200 },
			})
		end
	)

	test("MemoryStoreService separates HashMap, SortedMap, and Queue semantics", function()
		local e = sert.env.new()
		local mss = e:getService("MemoryStoreService")

		local hash = mss:GetHashMap("Sessions")
		local sorted = mss:GetSortedMap("Sessions")
		sert.eq((hash :: any).GetRangeAsync, nil)
		sert.eq((sorted :: any).ListItemsAsync, nil)

		-- HashMap SetAsync overwrite flag + ListItemsAsync
		sert.eq(hash:SetAsync("b", { token = 2 }, 60), false)
		sert.eq(hash:SetAsync("a", { token = 1 }, 60), false)
		sert.eq(hash:SetAsync("a", { token = 3 }, 60), true)
		local hPages = hash:ListItemsAsync(10)
		sert.eq(hPages:GetCurrentPage(), {
			{ key = "a", value = { token = 3 } },
			{ key = "b", value = { token = 2 } },
		})
		-- HashMap and SortedMap with same name do not collide
		local sInitial = sorted:GetAsync("a")
		sert.eq(sInitial, nil)

		-- SortedMap ordering by sortKey then key
		sorted:SetAsync("charlie", "c", 60, 10)
		sorted:SetAsync("alpha", "a", 60, 10)
		sorted:SetAsync("bravo", "b", 60, 5)
		sorted:SetAsync("delta", "d", 60, 20)

		local sVal, sKey = sorted:GetAsync("alpha")
		sert.eq(sVal, "a")
		sert.eq(sKey, 10)

		local asc = sorted:GetRangeAsync(e.Enum.SortDirection.Ascending, 10)
		sert.eq(asc, {
			{ key = "bravo", value = "b", sortKey = 5 },
			{ key = "alpha", value = "a", sortKey = 10 },
			{ key = "charlie", value = "c", sortKey = 10 },
			{ key = "delta", value = "d", sortKey = 20 },
		})
		local bounded = sorted:GetRangeAsync(e.Enum.SortDirection.Descending, 10, { sortKey = 5 }, { sortKey = 20 })
		sert.eq(bounded, {
			{ key = "charlie", value = "c", sortKey = 10 },
			{ key = "alpha", value = "a", sortKey = 10 },
		})

		-- Queue priority, invisibility timeout, redelivery, and RemoveAsync
		local queue = mss:GetQueue("Matchmaking", 5)
		queue:AddAsync({ match = "low" }, 60, 1)
		queue:AddAsync({ match = "high" }, 60, 10)
		local items1, id1 = queue:ReadAsync(1, false, 0)
		sert.eq(items1, { { match = "high" } })
		sert.ok(type(id1) == "string")

		-- Second immediate read skips invisible high-priority item and reads low-priority item
		local items2, id2 = queue:ReadAsync(1, false, 0)
		sert.eq(items2, { { match = "low" } })
		queue:RemoveAsync(id2)

		-- Advance past 5s invisibility timeout without acking id1 -> high-priority item redelivers
		e:advance(6)
		local redelivered, id3 = queue:ReadAsync(2, false, 0)
		sert.eq(redelivered, { { match = "high" } })
		queue:RemoveAsync(id3)
		local emptyAfter = queue:ReadAsync(1, false, 0)
		sert.eq(emptyAfter, {})
	end)

	test("EncodingService, HttpService, Marketplace, Teleport, Collection, Tween, Input, and Players", function()
		local e = sert.env.new({ isClient = true })
		local enc = e:getService("EncodingService")
		local Enum = e.Enum

		-- Base64, hashes, and Zstd compression
		local rawBuf = buffer.fromstring("sert-engine-" .. string.rep("Z", 64))
		local b64 = enc:Base64Encode(rawBuf)
		sert.eq(buffer.tostring(enc:Base64Decode(b64)), buffer.tostring(rawBuf))
		sert.throws(function() enc:Base64Decode(buffer.fromstring("not-valid-b64!")) end)

		sert.eq(buffer.len(enc:ComputeBufferHash(rawBuf, Enum.HashAlgorithm.Sha256)), 32)
		sert.eq(buffer.len(enc:ComputeBufferHash(rawBuf, Enum.HashAlgorithm.Blake2b)), 32)
		sert.eq(buffer.len(enc:ComputeBufferHash(rawBuf, Enum.HashAlgorithm.Blake3)), 32)
		sert.eq(buffer.len(enc:ComputeBufferHash(rawBuf, Enum.HashAlgorithm.Md5)), 16)
		sert.eq(buffer.len(enc:ComputeBufferHash(rawBuf, Enum.HashAlgorithm.Sha1)), 20)
		sert.eq(#enc:ComputeStringHash("hello", Enum.HashAlgorithm.Sha256), 64)

		local compressed = enc:CompressBuffer(rawBuf, Enum.CompressionAlgorithm.Zstd, 3)
		sert.eq(enc:GetDecompressedBufferSize(compressed, Enum.CompressionAlgorithm.Zstd), buffer.len(rawBuf))
		sert.eq(
			buffer.tostring(enc:DecompressBuffer(compressed, Enum.CompressionAlgorithm.Zstd)),
			buffer.tostring(rawBuf)
		)
		sert.throws(function() enc:CompressBuffer(rawBuf, "Deflate") end)

		-- HttpService JSON, GUID, custom RequestAsync handler
		local http = e:getService("HttpService")
		local guid = http:GenerateGUID(false)
		sert.eq(#guid, 36)
		local encoded = http:JSONEncode({ ok = true, nums = { 1, 2, 3 } })
		sert.eq(http:JSONDecode(encoded), { ok = true, nums = { 1, 2, 3 } })
		e:onHttp(
			function(req)
				return {
					Success = true,
					StatusCode = 200,
					StatusMessage = "OK",
					Headers = { ["x-echo"] = req.Method },
					Body = http:JSONEncode({ url = req.Url }),
				}
			end
		)
		local resp = http:RequestAsync({ Url = "https://example.test/ping", Method = "POST", Body = "{}" })
		sert.eq(resp.Headers["x-echo"], "POST")
		sert.eq(http:JSONDecode(http:GetAsync("https://example.test/ping")), { url = "https://example.test/ping" })

		-- MarketplaceService & TeleportService
		local mkt = e:getService("MarketplaceService")
		e:setProductInfo(500, { Name = "GemPack", PriceInRobux = 250 })
		sert.eq(mkt:GetProductInfo(500).Name, "GemPack")
		e:setGamePass(42, 99, true)
		sert.eq(mkt:UserOwnsGamePassAsync(42, 99), true)
		local grantedCoins = 0
		mkt.ProcessReceipt = function(receipt: any)
			grantedCoins += receipt.CurrencySpent :: number
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		local plr = e:addPlayer(42, "Buyer")
		mkt:PromptProductPurchase(plr, 500)
		sert.eq(grantedCoins, 250)

		local tp = e:getService("TeleportService")
		local code, serverId = tp:ReserveServer(9001)
		sert.ok(#code > 0 and #serverId > 0)
		local tpOpts = e.Instance.new("TeleportOptions")
		tpOpts.ReservedServerAccessCode = code
		tpOpts:SetTeleportData({ lobby = "alpha" })
		local tpRes = tp:TeleportAsync(9001, { plr }, tpOpts)
		sert.eq(tpRes.ReservedServerAccessCode, code)
		sert.eq(#e.teleports, 1)
		sert.eq(e.teleports[1].teleportData, { lobby = "alpha" })

		-- CollectionService tags & signals
		local cs = e:getService("CollectionService")
		local addedTag: { any } = {}
		local removedTag: { any } = {}
		cs:GetInstanceAddedSignal("Hazard"):Connect(function(inst) table.insert(addedTag, inst) end)
		cs:GetInstanceRemovedSignal("Hazard"):Connect(function(inst) table.insert(removedTag, inst) end)
		local trap = e.Instance.new("Part", e.workspace)
		cs:AddTag(trap, "Hazard")
		e:flush()
		sert.eq(cs:GetTagged("Hazard"), { trap })
		sert.eq(addedTag, { trap })
		cs:RemoveTag(trap, "Hazard")
		e:flush()
		sert.eq(removedTag, { trap })

		-- TweenService (including UDim & Vector3 lerp)
		local ts = e:getService("TweenService")
		local pad = e.Instance.new("UIPadding")
		local completed = false
		local tween = ts:Create(pad, e.TweenInfo.new(0.2, Enum.EasingStyle.Linear), {
			PaddingTop = e.UDim.new(0.5, 20),
		})
		tween.Completed:Connect(function() completed = true end)
		tween:Play()
		e:advance(0.25)
		sert.eq(completed, true)
		sert.near(pad.PaddingTop.Scale, 0.5, 1e-4)
		sert.near(pad.PaddingTop.Offset, 20, 1e-4)

		-- UserInputService & Players
		local uis = e:getService("UserInputService")
		e:input():press(Enum.KeyCode.Space)
		sert.eq(uis:IsKeyDown(Enum.KeyCode.Space), true)
		e:input():release(Enum.KeyCode.Space)
		sert.eq(uis:IsKeyDown(Enum.KeyCode.Space), false)

		local players = e:getService("Players")
		sert.eq(players:GetPlayerByUserId(42), plr)
		players:BanAsync({ UserIds = { 42 }, Duration = 60, DisplayReason = "Test", PrivateReason = "Spec" })
		local banPages = players:GetBanHistoryAsync(42)
		sert.eq(#banPages:GetCurrentPage(), 1)
	end)
end)

describe("Engine extended datatypes, persistence versions, and boundary serialization", function()
	test(
		"covers Color3 HSV/Hex sectors, BrickColor constructors, CFrame spaces/quaternions, Axes/Faces, loose Enums, and DateTime tokens",
		function()
			local e = sert.env.new()
			local g = e.globals
			local Color3, BrickColor, CFrame, Vector3 = g.Color3, g.BrickColor, g.CFrame, g.Vector3
			local Axes, Faces, DateTime, Enum = g.Axes, g.Faces, g.DateTime, g.Enum

			-- Color3 HSV across all 6 hue sectors + ToHSV + Hex
			for sector = 0, 5 do
				local h = (sector + 0.25) / 6
				local c = Color3.fromHSV(h, 0.8, 0.9)
				local rh, rs, rv = c:ToHSV()
				sert.near(rh, h, 1e-3)
				sert.near(rs, 0.8, 1e-3)
				sert.near(rv, 0.9, 1e-3)
			end
			sert.eq(Color3.fromHex("#f0a"):ToHex(), "ff00aa")
			sert.eq(Color3.fromHex("12ab34"):ToHex(), "12ab34")
			sert.throws(function() local _ = Color3.fromHex("not-hex") end, "invalid hex")
			sert.near(Color3.new(0, 0, 0):Lerp(Color3.new(1, 0.5, 0.25), 0.5), Color3.new(0.5, 0.25, 0.125), 1e-5)

			-- BrickColor constructors & palette
			sert.eq(BrickColor.new("Bright red").Name, "Bright red")
			sert.eq(BrickColor.new("nonexistent brick name").Number, BrickColor.palette(11).Number)
			sert.eq(BrickColor.new(21).Name, "Bright red")
			sert.ok(BrickColor.new(99999).Name ~= "")
			sert.ok(BrickColor.new(1, 0, 0).Name ~= "")
			sert.ok(BrickColor.new(Color3.new(0, 1, 0)).Name ~= "")
			sert.ok(BrickColor.random().Name ~= "")

			-- CFrame multi-arg constructors, ToWorldSpace/ToObjectSpace packs, and all 4 ToAxisAngle quaternion branches
			local cf0 = CFrame.new()
			local cf1 = CFrame.new(Vector3.new(3, 4, 5))
			local cf2 = CFrame.new(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
			local cf3 = CFrame.new(1, 2, 3)
			local cf7 = CFrame.new(1, 2, 3, 0, 0, 0, 0) -- zero-norm quaternion fallback
			local cf7b = CFrame.new(1, 2, 3, 0, math.sin(0.4), 0, math.cos(0.4))
			local cf12 = CFrame.new(1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1)
			local cfMat = CFrame.fromMatrix(Vector3.new(1, 2, 3), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0))
			local cfAlong = CFrame.lookAlong(Vector3.new(0, 0, 0), Vector3.new(0, 0, 0))
			sert.eq(cf0.Position, Vector3.new(0, 0, 0))
			sert.eq(cf1.Position, Vector3.new(3, 4, 5))
			sert.near(cf2.LookVector, Vector3.new(0, 0, -1), 1e-5)
			sert.eq(cf3, cf7)
			sert.eq(cf12, cfMat)
			sert.near(cfAlong.LookVector, Vector3.new(0, 0, -1), 1e-5)

			local wA, wB = cf7b:ToWorldSpace(CFrame.new(1, 0, 0), CFrame.new(0, 2, 0))
			local oA, oB = cf7b:ToObjectSpace(wA, wB)
			sert.near(oA, CFrame.new(1, 0, 0), 1e-5)
			sert.near(oB, CFrame.new(0, 2, 0), 1e-5)
			sert.eq(select("#", cf7b:ToWorldSpace()), 0)
			sert.eq(select("#", cf7b:ToObjectSpace()), 0)
			sert.near(
				cf7b:VectorToObjectSpace(cf7b:VectorToWorldSpace(Vector3.new(1, 2, 3))),
				Vector3.new(1, 2, 3),
				1e-5
			)
			sert.near(cf7b:PointToObjectSpace(cf7b:PointToWorldSpace(Vector3.new(1, 2, 3))), Vector3.new(1, 2, 3), 1e-5)

			-- Exercise trace > 0 and all three 180-degree diagonal branches of ToAxisAngle
			local rots: { any } = {
				CFrame.fromAxisAngle(Vector3.new(0, 1, 0), 0.5),
				CFrame.fromAxisAngle(Vector3.new(1, 0, 0), math.pi),
				CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.pi),
				CFrame.fromAxisAngle(Vector3.new(0, 0, 1), math.pi),
			}
			for _, rot in rots do
				local axis, angle = rot:ToAxisAngle()
				sert.near(axis.Magnitude, 1, 1e-5)
				sert.gt(angle, 0)
			end

			-- Axes, Faces, DateTime tokens, and loose Enum mode
			local axes = Axes.new(Enum.Axis.X, Enum.NormalId.Top)
			sert.eq(axes, Axes.new(Enum.Axis.X, Enum.Axis.Y))
			sert.eq(tostring(axes), "X, Y")
			sert.throws(function() local _ = Axes.new("bad") end, "Axes.new")

			local faces = Faces.new(Enum.NormalId.Front, Enum.NormalId.Right)
			sert.eq(faces, Faces.new(Enum.NormalId.Right, Enum.NormalId.Front))
			sert.ne(faces, Faces.new(Enum.NormalId.Front))
			sert.ok(string.find(tostring(faces), "Right", 1, true) ~= nil)
			sert.throws(function() local _ = Faces.new("bad") end, "Faces.new")

			local dt = DateTime.fromUniversalTime(2026, 7, 4, 15, 8, 9, 45)
			local formatted = dt:FormatUniversalTime(
				"YYYY YY MMMM MMM MM M DDDD DDD DD D dddd ddd dd d HH H hh h mm m ss s SSS A a",
				"en-us"
			)
			sert.matches(formatted, "^2026 26 July Jul 07 7 ")
			sert.ok(#dt:ToIsoDate() > 10)
			sert.eq(DateTime.fromIsoDate("2026-07-04T15:08:09Z").UnixTimestamp, dt.UnixTimestamp)

			local loose = sert.env.new({ strict = false })
			local customEnum: any = (loose.Enum :: any).CustomMode
			local alpha = customEnum.Alpha
			sert.eq(alpha.Name, "Alpha")
			sert.eq(customEnum:FromName("Alpha"), alpha)
			sert.eq(customEnum:FromValue(alpha.Value), alpha)
			sert.eq(#customEnum:GetEnumItems(), 1)
		end
	)

	test("covers DataStore versions/budgets, MemoryStore HashMap/Queue/faults, and boundary serialize", function()
		local DataStore = require("../src/engine/datastore")
		local MemoryStore = require("../src/engine/memorystore")
		local serialize = require("../src/engine/serialize")
		local Datatypes = require("../src/engine/datatypes")

		-- DataStore versions, ListDataStoresAsync, GetGlobalDataStore, and budgets
		local now = 1000
		local dsMock = DataStore.new({
			clock = function() return now end,
			budget = 50,
		})
		local globalStore = dsMock:GetGlobalDataStore()
		globalStore:SetAsync("g", 1)
		sert.eq((globalStore:GetAsync("g")), 1)

		local store = dsMock:GetDataStore("Players")
		local v1 = store:SetAsync("u1", { coins = 10 }, { 101 })
		now += 5
		local v2 = store:SetAsync("u1", { coins = 25 }, { 101 })
		local v1Val = store:GetVersionAsync("u1", v1)
		sert.eq(v1Val, { coins = 10 })

		local verPagesAsc = store:ListVersionsAsync("u1", "Ascending", nil, nil, 1)
		sert.eq(#verPagesAsc:GetCurrentPage(), 1)
		verPagesAsc:AdvanceToNextPageAsync()
		sert.eq(#verPagesAsc:GetCurrentPage(), 1)
		local verPagesDesc = store:ListVersionsAsync("u1", "Descending")
		sert.eq(#verPagesDesc:GetCurrentPage(), 2)

		store:RemoveVersionAsync("u1", v2)
		sert.eq((store:GetAsync("u1")), { coins = 10 })

		local storesPages = dsMock:ListDataStoresAsync("Play", 10)
		sert.eq(#storesPages:GetCurrentPage(), 1)
		sert.gt(dsMock:GetRequestBudgetForRequestType(Datatypes.Enum.DataStoreRequestType.GetAsync), 0)

		-- MemoryStore standalone clock, HashMap UpdateAsync/RemoveAsync/ListItemsAsync, stored(), and fail()
		local ms = MemoryStore.new()
		local hm = ms:GetHashMap("Sessions")
		hm:SetAsync("k1", "hello", 30)
		hm:SetAsync("k2", buffer.fromstring("bin"), 30)
		sert.eq(ms:stored().values, 2)
		sert.gt(ms:stored().bytes, 5)

		-- Conflict retry + nil abort on HashMap:UpdateAsync
		ms.conflict = function(mapObj: any, key: string)
			mapObj.data[key] = { value = "concurrent", expiry = ms.now + 30 }
		end
		local updated = hm:UpdateAsync("k1", function(cur) return `{tostring(cur)}!` end, 30)
		sert.eq(updated, "concurrent!")
		sert.eq(hm:UpdateAsync("k1", function() return nil end, 30), nil)

		local hmPages = hm:ListItemsAsync(1)
		sert.eq(#hmPages:GetCurrentPage(), 1)
		hmPages:AdvanceToNextPageAsync()
		sert.eq(#hmPages:GetCurrentPage(), 1)
		sert.throws(function() hm:ListItemsAsync(0) end, "1..200")
		hm:RemoveAsync("k1")
		sert.eq(hm:GetAsync("k1"), nil)

		local q = ms:GetQueue("Tasks", 5)
		q:AddAsync("job1", 60, 1)
		ms:step(10)
		ms:fail("SetAsync", "injected failure", false)
		sert.throws(function() hm:SetAsync("k3", 1, 10) end, "injected failure")

		-- Boundary serialize: params cloning, remoteTuple, buffers, control-char JSON sizing, and error guards
		local rp = Datatypes.RaycastParams.new()
		rp.IgnoreWater = true
		local op = Datatypes.OverlapParams.new()
		op.MaxParts = 7
		local cp = Datatypes.CatalogSearchParams.new()
		cp.SearchKeyword = "sword"
		sert.eq(serialize.remote(rp).IgnoreWater, true)
		sert.eq(serialize.remote(op).MaxParts, 7)
		sert.eq(serialize.remote(cp).SearchKeyword, "sword")

		local buf = buffer.fromstring("abc")
		local clonedBuf = serialize.remote(buf)
		sert.eq(buffer.tostring(clonedBuf), "abc")
		local tup, tupN = serialize.remoteTuple(nil, 1, nil, "x", nil)
		sert.eq(tupN, 4)
		sert.eq(tup[1], 1)
		sert.eq(tup[3], "x")

		local cyc: { [string]: any } = {}
		cyc.self = cyc
		sert.throws(function() serialize.remote(cyc) end, "cyclic")
		sert.throws(function()
			serialize.remote(function() end)
		end, "Cannot pass function")

		local dsCloned, dsBytes = serialize.datastore({
			ctrl = 'a"b\\c\nd\001e',
			raw = buffer.fromstring("xyz"),
			flag = false,
		})
		sert.eq(dsCloned.ctrl, 'a"b\\c\nd\001e')
		sert.eq(buffer.tostring(dsCloned.raw), "xyz")
		sert.gt(dsBytes, 15)
		sert.throws(function() serialize.datastore("too-big-payload", { maxBytes = 4 }) end)
	end)

	test(
		"covers RotationOrder Euler roundtrips, Vector2/3 min/max/axis/int16, installGlobals, and MemoryStore evict/queue wait",
		function()
			local Datatypes = require("../src/engine/datatypes")
			local MemoryStore = require("../src/engine/memorystore")
			local e = sert.env.new()
			local g = e.globals
			local Vector2, Vector3, CFrame = g.Vector2, g.Vector3, g.CFrame
			local Vector2int16, Vector3int16, Enum = g.Vector2int16, g.Vector3int16, g.Enum

			-- Vector2/Vector3 min, max, scalar left/right mul, FromNormalId, FromAxis
			sert.eq(Vector2.min(Vector2.new(3, 1), Vector2.new(2, 4)), Vector2.new(2, 1))
			sert.eq(Vector2.max(Vector2.new(3, 1), Vector2.new(2, 4)), Vector2.new(3, 4))
			sert.eq(2 * Vector2.new(3, 4), Vector2.new(6, 8))
			sert.eq(Vector2.new(3, 4) * 2, Vector2.new(6, 8))
			sert.eq(Vector2.new(3, 4) * Vector2.new(2, 5), Vector2.new(6, 20))

			sert.eq(Vector3.FromNormalId(Enum.NormalId.Front), Vector3.new(0, 0, -1))
			sert.eq(Vector3.FromNormalId(Enum.NormalId.Right), Vector3.new(1, 0, 0))
			sert.eq(Vector3.FromAxis(Enum.Axis.X), Vector3.new(1, 0, 0))
			sert.eq(Vector3.FromAxis(Enum.Axis.Y), Vector3.new(0, 1, 0))
			sert.eq(Vector3.FromAxis(Enum.Axis.Z), Vector3.new(0, 0, 1))
			sert.eq(2 * Vector3.new(1, 2, 3), Vector3.new(2, 4, 6))
			sert.eq(Vector3.new(1, 2, 3) * 2, Vector3.new(2, 4, 6))
			sert.eq(Vector3.new(1, 2, 3) * Vector3.new(2, 3, 4), Vector3.new(2, 6, 12))

			-- Vector2int16 and Vector3int16 arithmetic
			local i2 = Vector2int16.new(10, -7)
			sert.eq(i2 + Vector2int16.new(2, 3), Vector2int16.new(12, -4))
			sert.eq(i2 - Vector2int16.new(2, 3), Vector2int16.new(8, -10))
			sert.eq(i2 * 2, Vector2int16.new(20, -14))
			sert.eq(i2 / 2, Vector2int16.new(5, -3))
			sert.eq(i2 // 3, Vector2int16.new(3, -3))
			sert.eq(-i2, Vector2int16.new(-10, 7))
			sert.eq(tostring(i2), "10, -7")
			local i3 = Vector3int16.new(9, -4, 6)
			sert.eq(i3 + Vector3int16.new(1, 4, -2), Vector3int16.new(10, 0, 4))
			sert.eq(i3 - Vector3int16.new(1, 2, 3), Vector3int16.new(8, -6, 3))
			sert.eq(i3 * 2, Vector3int16.new(18, -8, 12))
			sert.eq(i3 / 3, Vector3int16.new(3, -1, 2))
			sert.eq(-i3, Vector3int16.new(-9, 4, -6))

			-- CFrame.fromEulerAngles + ToEulerAngles across all 6 RotationOrders
			local orders: { any } = { "XYZ", "YXZ", "XZY", "YZX", "ZXY", "ZYX", Enum.RotationOrder.ZXY }
			for _, ord in orders do
				local cf = CFrame.fromEulerAngles(0.2, -0.3, 0.4, ord)
				local rx, ry, rz = cf:ToEulerAngles(ord)
				local rebuilt = CFrame.fromEulerAngles(rx, ry, rz, ord)
				sert.near(rebuilt, cf, 1e-4)
			end

			-- Datatypes.installGlobals into an isolated target dictionary
			local target: { [string]: any } = {}
			Datatypes.installGlobals(target)
			sert.ok(target.Vector3 ~= nil and target.CFrame ~= nil and target.Enum ~= nil)

			-- MemoryStore evict modes + Queue invisibility wait re-delivery
			local ms = MemoryStore.new()
			local hm = ms:GetHashMap("EvictHash")
			local sm = ms:GetSortedMap("EvictSorted")
			local q = ms:GetQueue("EvictQueue", 2)
			hm:SetAsync("a", 1, 60)
			hm:SetAsync("b", 2, 60)
			sm:SetAsync("s1", "val", 60, 10)
			q:AddAsync("item1", 60, 1)
			q:AddAsync("item2", 60, 2)

			-- Read item2 (higher priority) so it becomes invisible for 2s, then ReadAsync with waitTimeout = 5 wakes when visible
			local read1, rid1 = q:ReadAsync(2, false, 0)
			sert.eq(#read1, 2)
			local readAfterInvis, rid2 = q:ReadAsync(1, false, 5)
			sert.eq(#readAfterInvis, 1)
			sert.ge(q:GetSizeAsync(false), 1)
			sert.ge(q:GetSizeAsync(true), 0)
			q:RemoveAsync(rid2)
			q:RemoveAsync(rid1) -- expired receipt RemoveAsync is a safe no-op

			sert.eq(ms:evict("EvictHash", "a"), "EvictHash/a")
			sert.eq(ms:evict("EvictQueue"), "queue:EvictQueue")
			sert.ok(ms:evict(nil, "b") ~= nil)
			sert.ok(ms:evict() ~= nil)
		end
	)
end)
