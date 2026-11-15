--!strict
-- Exact 3D oriented spatial queries (`Raycast`, `Blockcast`, `Spherecast`, `Shapecast`, `GetPartBoundsInBox`,
-- `GetPartBoundsInRadius`, `GetPartsInPart`) with CollisionGroup and BruteForceAllSlow filtering.

local Spatial = {}

local EPS = 1e-6
local PARALLEL_EPS = 1e-12

local function isWithin(inst: any, list: { any }): boolean
	for _, root in list do
		if inst == root or inst:IsDescendantOf(root) then return true end
	end
	return false
end

local function partShapeKind(part: any): string
	local shape = part._props.Shape
	if shape ~= nil then
		local sName = shape.Name
		if sName == "Ball" then return "Ball" end
		if sName == "Cylinder" then return "Cylinder" end
	end
	return "Box"
end

local function groupOf(value: any): string
	if type(value) == "string" and value ~= "" then return value end
	return "Default"
end

--- Returns candidate BaseParts inside `workspaceInst` matching `params` (filter, CanQuery/BruteForceAllSlow,
--- RespectCanCollide, CollisionGroup), excluding `terrainInst` and optional `excludePart`.
function Spatial.candidates(workspaceInst: any, terrainInst: any, ctx: any, params: any?, excludePart: any?): { any }
	local filterList: { any } = if params ~= nil then params.FilterDescendantsInstances or {} else {}
	local Enum = ctx.Enum
	local include = params ~= nil and params.FilterType == Enum.RaycastFilterType.Include
	local respectCollide = params ~= nil and params.RespectCanCollide == true
	local bruteForce = params ~= nil and params.BruteForceAllSlow == true
	local queryGroup = groupOf(if params ~= nil then params.CollisionGroup else nil)
	local phys = ctx.services.PhysicsService or ctx.getService("PhysicsService")
	local checkGroups = phys ~= nil

	local out: { any } = {}
	for _, inst in workspaceInst:GetDescendants() do
		if inst == terrainInst or inst == excludePart or not inst:IsA("BasePart") then continue end
		if not bruteForce and inst.CanQuery == false then continue end
		if respectCollide and inst.CanCollide == false then continue end
		if checkGroups then
			local partGroup = groupOf(inst.CollisionGroup)
			if not phys:CollisionGroupsAreCollidable(queryGroup, partGroup) then continue end
		end
		local listed = #filterList > 0 and isWithin(inst, filterList)
		if if include then listed else not listed then table.insert(out, inst) end
	end
	return out
end

--- Limits an overlap result array according to `params.MaxParts`.
function Spatial.limit(list: { any }, params: any?): { any }
	local maxParts = if params ~= nil then params.MaxParts or 0 else 0
	return if maxParts > 0 and #list > maxParts then table.move(list, 1, maxParts, 1, {}) else list
end

local function rayVsBox(cf: any, size: any, origin: any, direction: any, Vector3: any): (number?, any?, any?)
	local lo = cf:PointToObjectSpace(origin)
	local ld = cf:VectorToObjectSpace(direction)
	local half = { math.max(size.X * 0.5, 0), math.max(size.Y * 0.5, 0), math.max(size.Z * 0.5, 0) }
	local o = { lo.X, lo.Y, lo.Z }
	local d = { ld.X, ld.Y, ld.Z }

	local tEnter = -math.huge
	local tExit = math.huge
	local hitAxis, hitSign = 0, 0
	for i = 1, 3 do
		local h, oi, di = half[i], o[i], d[i]
		if math.abs(di) < PARALLEL_EPS then
			if oi < -h - 1e-9 or oi > h + 1e-9 then return nil, nil, nil end
		else
			local invD = 1 / di
			local t1, t2 = (-h - oi) * invD, (h - oi) * invD
			local s = -1
			if t1 > t2 then
				t1, t2, s = t2, t1, 1
			end
			if t1 > tEnter then
				tEnter, hitAxis, hitSign = t1, i, s
			end
			tExit = math.min(tExit, t2)
			if tEnter > tExit then return nil, nil, nil end
		end
	end

	-- Rays originating strictly inside the shape do not hit its interior shell (matching Roblox).
	if hitAxis == 0 or tExit < 0 or tEnter > 1 or tEnter < -EPS then return nil, nil, nil end
	local t = math.max(0, tEnter)
	local localPos = lo + ld * t
	local n = { 0, 0, 0 }
	n[hitAxis] = hitSign
	local localNormal = Vector3.new(n[1], n[2], n[3])
	return t, cf:PointToWorldSpace(localPos), cf:VectorToWorldSpace(localNormal).Unit
end

local function rayVsBall(cf: any, size: any, origin: any, direction: any): (number?, any?, any?)
	local r = math.min(size.X, size.Y, size.Z) * 0.5
	if r <= 0 then return nil, nil, nil end
	local p = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(direction)
	local a = d:Dot(d)
	if a < PARALLEL_EPS then return nil, nil, nil end
	local b = p:Dot(d)
	local c = p:Dot(p) - r * r
	-- Origin strictly inside sphere -> no hit.
	if c < -EPS * math.max(r, 1) then return nil, nil, nil end
	if c <= EPS and b >= 0 then return nil, nil, nil end
	local disc = b * b - a * c
	if disc < 0 then return nil, nil, nil end
	local t = (-b - math.sqrt(disc)) / a
	if t < -EPS or t > 1 then return nil, nil, nil end
	t = math.max(0, t)
	local localPos = p + d * t
	local mag = localPos.Magnitude
	local localNormal = if mag > PARALLEL_EPS then localPos / mag else -d.Unit
	return t, cf:PointToWorldSpace(localPos), cf:VectorToWorldSpace(localNormal).Unit
end

local function rayVsCylinder(cf: any, size: any, origin: any, direction: any, Vector3: any): (number?, any?, any?)
	local hx = math.max(size.X * 0.5, 0)
	local r = math.min(size.Y, size.Z) * 0.5
	if r <= 0 then return nil, nil, nil end
	local p = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(direction)
	local px, py, pz = p.X, p.Y, p.Z
	local dx, dy, dz = d.X, d.Y, d.Z

	-- Roblox PartType.Cylinder is aligned along local X axis; skip origins strictly inside.
	if math.abs(px) < hx - EPS and (py * py + pz * pz) < (r * r - EPS * math.max(r, 1)) then return nil, nil, nil end

	local bestT: number? = nil
	local bestNormal: any = nil

	if math.abs(dx) > PARALLEL_EPS then
		for _, sx in { -1, 1 } do
			if dx * sx < 0 then
				local tx = (sx * hx - px) / dx
				if tx >= -EPS and tx <= 1 then
					local cy, cz = py + tx * dy, pz + tx * dz
					if cy * cy + cz * cz <= r * r + 1e-7 then
						local clampedT = math.max(0, tx)
						if bestT == nil or clampedT < bestT then
							bestT = clampedT
							bestNormal = Vector3.new(sx, 0, 0)
						end
					end
				end
			end
		end
	end

	local a = dy * dy + dz * dz
	if a > PARALLEL_EPS then
		local b = py * dy + pz * dz
		local c = py * py + pz * pz - r * r
		local disc = b * b - a * c
		if disc >= 0 then
			local tSide = (-b - math.sqrt(disc)) / a
			if tSide >= -EPS and tSide <= 1 then
				local hxPos = px + tSide * dx
				if math.abs(hxPos) <= hx + 1e-7 then
					local clampedT = math.max(0, tSide)
					if bestT == nil or clampedT < bestT then
						local hyPos, hzPos = py + clampedT * dy, pz + clampedT * dz
						local radialMag = math.sqrt(hyPos * hyPos + hzPos * hzPos)
						if radialMag > PARALLEL_EPS then
							bestT = clampedT
							bestNormal = Vector3.new(0, hyPos / radialMag, hzPos / radialMag)
						end
					end
				end
			end
		end
	end

	if bestT == nil or bestNormal == nil then return nil, nil, nil end
	local localPos = p + d * bestT
	return bestT, cf:PointToWorldSpace(localPos), cf:VectorToWorldSpace(bestNormal).Unit
end

--- Exact oriented 3D `Workspace:Raycast` supporting Block/OBB, Ball, and X-aligned Cylinder parts.
function Spatial.raycast(workspaceInst: any, terrainInst: any, origin: any, direction: any, params: any?, ctx: any): any
	if origin == nil or direction == nil then return nil end
	local dt = ctx.dt
	local Vector3 = dt.Vector3
	local dirLen = direction.Magnitude
	if dirLen <= PARALLEL_EPS then return nil end

	local bestT, bestPart, bestPos, bestNorm = math.huge, nil :: any, nil :: any, nil :: any
	for _, part in Spatial.candidates(workspaceInst, terrainInst, ctx, params, nil) do
		local kind = partShapeKind(part)
		local t, pos, norm: any
		if kind == "Ball" then
			t, pos, norm = rayVsBall(part.CFrame, part.Size, origin, direction)
		elseif kind == "Cylinder" then
			t, pos, norm = rayVsCylinder(part.CFrame, part.Size, origin, direction, Vector3)
		else
			t, pos, norm = rayVsBox(part.CFrame, part.Size, origin, direction, Vector3)
		end
		if t ~= nil and t < bestT then
			bestT, bestPart, bestPos, bestNorm = t, part, pos, norm
		end
	end
	if bestPart == nil then return nil end
	return dt.newRaycastResult(
		bestPart,
		bestPos,
		bestNorm,
		dirLen * bestT,
		bestPart.Material or ctx.Enum.Material.Plastic
	)
end

local function obbAxes(cf: any): { any } return { cf.RightVector, cf.UpVector, cf.ZVector } end

local function obbProjRadius(axes: { any }, half: { number }, axis: any): number
	return half[1] * math.abs(axes[1]:Dot(axis))
		+ half[2] * math.abs(axes[2]:Dot(axis))
		+ half[3] * math.abs(axes[3]:Dot(axis))
end

--- Exact 15-axis Separating Axis Theorem (SAT) overlap test between two oriented boxes.
local function overlapBoxBox(cfA: any, sizeA: any, cfB: any, sizeB: any): boolean
	local axA, axB = obbAxes(cfA), obbAxes(cfB)
	local hA = { math.max(sizeA.X * 0.5, 0), math.max(sizeA.Y * 0.5, 0), math.max(sizeA.Z * 0.5, 0) }
	local hB = { math.max(sizeB.X * 0.5, 0), math.max(sizeB.Y * 0.5, 0), math.max(sizeB.Z * 0.5, 0) }
	local delta = cfB.Position - cfA.Position

	for i = 1, 3 do
		local L = axA[i]
		if math.abs(delta:Dot(L)) > hA[i] + obbProjRadius(axB, hB, L) + 1e-9 then return false end
	end
	for j = 1, 3 do
		local L = axB[j]
		if math.abs(delta:Dot(L)) > obbProjRadius(axA, hA, L) + hB[j] + 1e-9 then return false end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			local cross = axA[i]:Cross(axB[j])
			local mag = cross.Magnitude
			if mag > 1e-6 then
				local L = cross / mag
				if math.abs(delta:Dot(L)) > obbProjRadius(axA, hA, L) + obbProjRadius(axB, hB, L) + 1e-9 then
					return false
				end
			end
		end
	end
	return true
end

local function closestPointOnBoxLocal(lp: any, size: any, Vector3: any): any
	local hx, hy, hz = math.max(size.X * 0.5, 0), math.max(size.Y * 0.5, 0), math.max(size.Z * 0.5, 0)
	return Vector3.new(math.clamp(lp.X, -hx, hx), math.clamp(lp.Y, -hy, hy), math.clamp(lp.Z, -hz, hz))
end

local function overlapSphereBox(center: any, radius: number, boxCf: any, boxSize: any, Vector3: any): boolean
	local lp = boxCf:PointToObjectSpace(center)
	local closest = closestPointOnBoxLocal(lp, boxSize, Vector3)
	local diff = lp - closest
	return diff:Dot(diff) <= radius * radius + 1e-9
end

local function overlapSphereCylinder(center: any, radius: number, cylCf: any, cylSize: any, Vector3: any): boolean
	local hx = math.max(cylSize.X * 0.5, 0)
	local cylR = math.max(math.min(cylSize.Y, cylSize.Z) * 0.5, 0)
	local lp = cylCf:PointToObjectSpace(center)
	local cx = math.clamp(lp.X, -hx, hx)
	local yzDistSq = lp.Y * lp.Y + lp.Z * lp.Z
	local cy, cz = lp.Y, lp.Z
	if yzDistSq > cylR * cylR and yzDistSq > PARALLEL_EPS then
		local scale = cylR / math.sqrt(yzDistSq)
		cy, cz = lp.Y * scale, lp.Z * scale
	end
	local diff = lp - Vector3.new(cx, cy, cz)
	return diff:Dot(diff) <= radius * radius + 1e-9
end

local function supportPoint(kind: string, cf: any, size: any, dir: any, Vector3: any): any
	local mag = dir.Magnitude
	if kind == "Ball" then
		local r = math.max(math.min(size.X, size.Y, size.Z) * 0.5, 0)
		return if mag > PARALLEL_EPS then cf.Position + (dir / mag) * r else cf.Position
	elseif kind == "Cylinder" then
		local ld = cf:VectorToObjectSpace(dir)
		local hx = math.max(size.X * 0.5, 0)
		local r = math.max(math.min(size.Y, size.Z) * 0.5, 0)
		local sx = if ld.X >= 0 then hx else -hx
		local yzLen = math.sqrt(ld.Y * ld.Y + ld.Z * ld.Z)
		local sy, sz = 0, 0
		if yzLen > PARALLEL_EPS then
			local scale = r / yzLen
			sy, sz = ld.Y * scale, ld.Z * scale
		end
		return cf:PointToWorldSpace(Vector3.new(sx, sy, sz))
	end
	local ld = cf:VectorToObjectSpace(dir)
	local hx, hy, hz = math.max(size.X * 0.5, 0), math.max(size.Y * 0.5, 0), math.max(size.Z * 0.5, 0)
	return cf:PointToWorldSpace(
		Vector3.new(if ld.X >= 0 then hx else -hx, if ld.Y >= 0 then hy else -hy, if ld.Z >= 0 then hz else -hz)
	)
end

type SupportVertex = { w: any, a: any, b: any }

local function supportVertex(
	kA: string,
	cfA: any,
	szA: any,
	kB: string,
	cfB: any,
	szB: any,
	dir: any,
	Vector3: any
): SupportVertex
	local pA = supportPoint(kA, cfA, szA, dir, Vector3)
	local pB = supportPoint(kB, cfB, szB, -dir, Vector3)
	return { w = pA - pB, a = pA, b = pB }
end

local function closestOnSegment(s: { SupportVertex }): (any, any, any, { SupportVertex })
	local A, B = s[1], s[2]
	local ab = B.w - A.w
	local denom = ab:Dot(ab)
	if denom <= PARALLEL_EPS then return A.w, A.a, A.b, { A } end
	local t = math.clamp(-A.w:Dot(ab) / denom, 0, 1)
	if t <= 0 then return A.w, A.a, A.b, { A } end
	if t >= 1 then return B.w, B.a, B.b, { B } end
	local w = A.w + ab * t
	local a = A.a + (B.a - A.a) * t
	local b = A.b + (B.b - A.b) * t
	return w, a, b, { A, B }
end

-- Exact Voronoi-region closest point to the origin on a triangle ABC (Ericson, Real-Time Collision Detection).
local function closestOnTriangle(s: { SupportVertex }): (any, any, any, { SupportVertex })
	local A, B, C = s[1], s[2], s[3]
	local ab, ac = B.w - A.w, C.w - A.w
	local ap = -A.w
	local d1, d2 = ab:Dot(ap), ac:Dot(ap)
	if d1 <= 0 and d2 <= 0 then return A.w, A.a, A.b, { A } end

	local bp = -B.w
	local d3, d4 = ab:Dot(bp), ac:Dot(bp)
	if d3 >= 0 and d4 <= d3 then return B.w, B.a, B.b, { B } end

	local vc = d1 * d4 - d3 * d2
	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return A.w + ab * v, A.a + (B.a - A.a) * v, A.b + (B.b - A.b) * v, { A, B }
	end

	local cp = -C.w
	local d5, d6 = ab:Dot(cp), ac:Dot(cp)
	if d6 >= 0 and d5 <= d6 then return C.w, C.a, C.b, { C } end

	local vb = d5 * d2 - d1 * d6
	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return A.w + ac * w, A.a + (C.a - A.a) * w, A.b + (C.b - A.b) * w, { A, C }
	end

	local va = d3 * d6 - d5 * d4
	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return B.w + (C.w - B.w) * w, B.a + (C.a - B.a) * w, B.b + (C.b - B.b) * w, { B, C }
	end

	local denom = 1 / (va + vb + vc)
	local v, w = vb * denom, vc * denom
	local u = 1 - v - w
	return A.w * u + B.w * v + C.w * w, A.a * u + B.a * v + C.a * w, A.b * u + B.b * v + C.b * w, { A, B, C }
end

local function pointOutsidePlane(a: any, b: any, c: any, dRef: any): boolean
	local n = (b - a):Cross(c - a)
	local signOrigin = -a:Dot(n)
	local signRef = (dRef - a):Dot(n)
	return signOrigin * signRef < 0
end

local function closestOnSimplex(s: { SupportVertex }): (boolean, any, any, any, { SupportVertex })
	local n = #s
	if n == 1 then
		return s[1].w:Dot(s[1].w) <= EPS * EPS, s[1].w, s[1].a, s[1].b, s
	elseif n == 2 then
		local w, a, b, kept = closestOnSegment(s)
		return w:Dot(w) <= EPS * EPS, w, a, b, kept
	elseif n == 3 then
		local w, a, b, kept = closestOnTriangle(s)
		return w:Dot(w) <= EPS * EPS, w, a, b, kept
	end
	local A, B, C, D = s[1], s[2], s[3], s[4]
	local bestDistSq = math.huge
	local bestW: any = A.w
	local bestA: any = A.a
	local bestB: any = A.b
	local bestKept: { SupportVertex } = { A }
	local outsideAny = false
	local faces = {
		{ { A, B, C }, D.w },
		{ { A, C, D }, B.w },
		{ { A, D, B }, C.w },
		{ { B, D, C }, A.w },
	}
	for _, face in faces do
		local tri, opp = face[1], face[2]
		if pointOutsidePlane(tri[1].w, tri[2].w, tri[3].w, opp) then
			outsideAny = true
			local fw, fa, fb, fKept = closestOnTriangle(tri)
			local dSq = fw:Dot(fw)
			if dSq < bestDistSq then
				bestDistSq, bestW, bestA, bestB, bestKept = dSq, fw, fa, fb, fKept
			end
		end
	end
	if not outsideAny then return true, A.w * 0, A.a, A.b, s end
	return bestDistSq <= EPS * EPS, bestW, bestA, bestB, bestKept
end

local function gjkClosest(
	kA: string,
	cfA: any,
	szA: any,
	kB: string,
	cfB: any,
	szB: any,
	Vector3: any
): (boolean, number, any, any, any)
	local initDir = cfA.Position - cfB.Position
	if initDir.Magnitude <= PARALLEL_EPS then initDir = Vector3.xAxis end
	local v0 = supportVertex(kA, cfA, szA, kB, cfB, szB, initDir, Vector3)
	local simplex: { SupportVertex } = { v0 }
	local bestV, bestA, bestB = v0.w, v0.a, v0.b

	for _ = 1, 32 do
		local distSq = bestV:Dot(bestV)
		if distSq <= 1e-12 then return true, 0, bestA, bestB, Vector3.zero end
		local searchDir = -bestV
		local nextV = supportVertex(kA, cfA, szA, kB, cfB, szB, searchDir, Vector3)
		local gap = bestV:Dot(bestV) - bestV:Dot(nextV.w)
		if gap <= 1e-7 * math.max(1, distSq) then
			local dist = math.sqrt(distSq)
			return false, dist, bestA, bestB, bestV / dist
		end
		local duplicate = false
		for _, sv in simplex do
			local d = sv.w - nextV.w
			if d:Dot(d) <= 1e-11 then
				duplicate = true
				break
			end
		end
		if duplicate then
			local dist = math.sqrt(distSq)
			return false, dist, bestA, bestB, bestV / dist
		end
		table.insert(simplex, nextV)
		local hit, w, a, b, kept = closestOnSimplex(simplex)
		if hit then return true, 0, a, b, Vector3.zero end
		simplex, bestV, bestA, bestB = kept, w, a, b
	end
	local finalDist = bestV.Magnitude
	if finalDist <= EPS then return true, 0, bestA, bestB, Vector3.zero end
	return false, finalDist, bestA, bestB, bestV / finalDist
end

local function overlapShapes(kA: string, cfA: any, szA: any, kB: string, cfB: any, szB: any, Vector3: any): boolean
	if kA == "Box" and kB == "Box" then return overlapBoxBox(cfA, szA, cfB, szB) end
	if kA == "Ball" then
		local r = math.max(math.min(szA.X, szA.Y, szA.Z) * 0.5, 0)
		if kB == "Ball" then
			local rB = math.max(math.min(szB.X, szB.Y, szB.Z) * 0.5, 0)
			local d = cfA.Position - cfB.Position
			return d:Dot(d) <= (r + rB) * (r + rB) + 1e-9
		elseif kB == "Cylinder" then
			return overlapSphereCylinder(cfA.Position, r, cfB, szB, Vector3)
		else
			return overlapSphereBox(cfA.Position, r, cfB, szB, Vector3)
		end
	elseif kB == "Ball" then
		local r = math.max(math.min(szB.X, szB.Y, szB.Z) * 0.5, 0)
		if kA == "Cylinder" then
			return overlapSphereCylinder(cfB.Position, r, cfA, szA, Vector3)
		else
			return overlapSphereBox(cfB.Position, r, cfA, szA, Vector3)
		end
	end
	-- Bounding OBB early-reject before GJK for cylinder-vs-box / cylinder-vs-cylinder.
	if not overlapBoxBox(cfA, szA, cfB, szB) then return false end
	local hit = gjkClosest(kA, cfA, szA, kB, cfB, szB, Vector3)
	return hit
end

--- Exact OBB/Ball/Cylinder overlap query inside an oriented box region.
function Spatial.getPartBoundsInBox(
	workspaceInst: any,
	terrainInst: any,
	cframe: any?,
	size: any?,
	params: any?,
	ctx: any
): { any }
	if cframe == nil or size == nil then return {} end
	local Vector3 = ctx.dt.Vector3
	local out = {}
	for _, part in Spatial.candidates(workspaceInst, terrainInst, ctx, params, nil) do
		local kind = partShapeKind(part)
		if overlapShapes("Box", cframe, size, kind, part.CFrame, part.Size, Vector3) then table.insert(out, part) end
	end
	return Spatial.limit(out, params)
end

--- Exact closest-point sphere overlap query supporting Block/OBB, Ball, and Cylinder parts.
function Spatial.getPartBoundsInRadius(
	workspaceInst: any,
	terrainInst: any,
	position: any?,
	radius: number?,
	params: any?,
	ctx: any
): { any }
	if position == nil or radius == nil or radius < 0 then return {} end
	local Vector3 = ctx.dt.Vector3
	local out = {}
	for _, part in Spatial.candidates(workspaceInst, terrainInst, ctx, params, nil) do
		local kind = partShapeKind(part)
		local hits: boolean
		if kind == "Ball" then
			local rB = math.max(math.min(part.Size.X, part.Size.Y, part.Size.Z) * 0.5, 0)
			local d = part.CFrame.Position - position
			hits = d:Dot(d) <= (radius + rB) * (radius + rB) + 1e-9
		elseif kind == "Cylinder" then
			hits = overlapSphereCylinder(position, radius, part.CFrame, part.Size, Vector3)
		else
			hits = overlapSphereBox(position, radius, part.CFrame, part.Size, Vector3)
		end
		if hits then table.insert(out, part) end
	end
	return Spatial.limit(out, params)
end

--- Exact shape overlap query using `part`'s oriented CFrame, Size, and PartType.
function Spatial.getPartsInPart(workspaceInst: any, terrainInst: any, part: any?, params: any?, ctx: any): { any }
	if part == nil then return {} end
	local Vector3 = ctx.dt.Vector3
	local kindA, cfA, szA = partShapeKind(part), part.CFrame, part.Size
	local out = {}
	for _, other in Spatial.candidates(workspaceInst, terrainInst, ctx, params, part) do
		if overlapShapes(kindA, cfA, szA, partShapeKind(other), other.CFrame, other.Size, Vector3) then
			table.insert(out, other)
		end
	end
	return Spatial.limit(out, params)
end

-- Exact Voronoi rounded-OBB raycast: sphere `(origin, radius)` sweeping `direction` against stationary OBB `(cf, size)`.
local function spherecastVsBox(
	origin: any,
	radius: number,
	direction: any,
	boxCf: any,
	boxSize: any,
	Vector3: any
): (number?, any?, any?)
	if overlapSphereBox(origin, radius - EPS, boxCf, boxSize, Vector3) then return nil, nil, nil end
	local o = boxCf:PointToObjectSpace(origin)
	local d = boxCf:VectorToObjectSpace(direction)
	local hx = math.max(boxSize.X * 0.5, 0)
	local hy = math.max(boxSize.Y * 0.5, 0)
	local hz = math.max(boxSize.Z * 0.5, 0)

	local bestT: number? = nil
	local bestContact: any = nil
	local bestNormal: any = nil

	local function record(t: number, contact: any, normal: any)
		if t < -EPS or t > 1 then return end
		local tc = math.max(0, t)
		if bestT == nil or tc < bestT then
			bestT, bestContact, bestNormal = tc, contact, normal
		end
	end

	-- 1) 6 Voronoi face slabs
	local axes = {
		{ o.X, d.X, hx, o.Y, d.Y, hy, o.Z, d.Z, hz, 1 },
		{ o.Y, d.Y, hy, o.X, d.X, hx, o.Z, d.Z, hz, 2 },
		{ o.Z, d.Z, hz, o.X, d.X, hx, o.Y, d.Y, hy, 3 },
	}
	for _, spec in axes do
		local ou, du, hu, ov, dv, hv, ow, dw, hw, idx = table.unpack(spec)
		for _, s in { -1, 1 } do
			if du * s < -PARALLEL_EPS then
				local t = (s * (hu + radius) - ou) / du
				if t >= -EPS and t <= 1 then
					local vHit, wHit = ov + t * dv, ow + t * dw
					if math.abs(vHit) <= hv + 1e-7 and math.abs(wHit) <= hw + 1e-7 then
						local vc, wc = math.clamp(vHit, -hv, hv), math.clamp(wHit, -hw, hw)
						if idx == 1 then
							record(t, Vector3.new(s * hx, vc, wc), Vector3.new(s, 0, 0))
						elseif idx == 2 then
							record(t, Vector3.new(vc, s * hy, wc), Vector3.new(0, s, 0))
						else
							record(t, Vector3.new(vc, wc, s * hz), Vector3.new(0, 0, s))
						end
					end
				end
			end
		end
	end

	-- 2) 12 Voronoi edge cylinders
	if radius > 0 then
		for _, spec in axes do
			local ou, du, hu, ov, dv, hv, ow, dw, hw, idx = table.unpack(spec)
			local a = dv * dv + dw * dw
			if a > PARALLEL_EPS then
				for _, sv in { -1, 1 } do
					for _, sw in { -1, 1 } do
						local ev, ew = sv * hv, sw * hw
						local pv, pw = ov - ev, ow - ew
						local b = pv * dv + pw * dw
						local c = pv * pv + pw * pw - radius * radius
						local disc = b * b - a * c
						if disc >= 0 then
							local t = (-b - math.sqrt(disc)) / a
							if t >= -EPS and t <= 1 then
								local uHit = ou + t * du
								if math.abs(uHit) <= hu + 1e-7 then
									local nv, nw = pv + t * dv, pw + t * dw
									if nv * dv + nw * dw < 0 then
										local nMag = math.sqrt(nv * nv + nw * nw)
										if nMag > PARALLEL_EPS then
											nv, nw = nv / nMag, nw / nMag
											local uc = math.clamp(uHit, -hu, hu)
											if idx == 1 then
												record(t, Vector3.new(uc, ev, ew), Vector3.new(0, nv, nw))
											elseif idx == 2 then
												record(t, Vector3.new(ev, uc, ew), Vector3.new(nv, 0, nw))
											else
												record(t, Vector3.new(ev, ew, uc), Vector3.new(nv, nw, 0))
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end

		-- 3) 8 Voronoi corner spheres
		local dSq = d:Dot(d)
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local corner = Vector3.new(sx * hx, sy * hy, sz * hz)
					local p = o - corner
					local b = p:Dot(d)
					local c = p:Dot(p) - radius * radius
					local disc = b * b - dSq * c
					if disc >= 0 then
						local t = (-b - math.sqrt(disc)) / dSq
						if t >= -EPS and t <= 1 then
							local nVec = p + d * t
							if nVec:Dot(d) < 0 then
								local nMag = nVec.Magnitude
								if nMag > PARALLEL_EPS then record(t, corner, nVec / nMag) end
							end
						end
					end
				end
			end
		end
	end

	if bestT == nil or bestContact == nil or bestNormal == nil then return nil, nil, nil end
	return bestT, boxCf:PointToWorldSpace(bestContact), boxCf:VectorToWorldSpace(bestNormal).Unit
end

local function clipPolygonAgainstPlane(poly: { any }, axis: any, offset: number, sign: number): { any }
	if #poly == 0 then return poly end
	local out: { any } = {}
	local prev = poly[#poly]
	local prevDist = (prev:Dot(axis) - offset) * sign
	for _, cur in poly do
		local curDist = (cur:Dot(axis) - offset) * sign
		local curIn = curDist <= 1e-5
		local prevIn = prevDist <= 1e-5
		if curIn ~= prevIn then
			local alpha = prevDist / (prevDist - curDist)
			table.insert(out, prev + (cur - prev) * alpha)
		end
		if curIn then table.insert(out, cur) end
		prev, prevDist = cur, curDist
	end
	return out
end

local function obbSupportVertices(cf: any, size: any, dir: any, Vector3: any): { any }
	local ld = cf:VectorToObjectSpace(dir)
	local hx, hy, hz = math.max(size.X * 0.5, 0), math.max(size.Y * 0.5, 0), math.max(size.Z * 0.5, 0)
	local bestProj = -math.huge
	local pts: { any } = {}
	local rawPts: { any } = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local lp = Vector3.new(sx * hx, sy * hy, sz * hz)
				local proj = lp:Dot(ld)
				table.insert(rawPts, { lp = lp, proj = proj })
				if proj > bestProj then bestProj = proj end
			end
		end
	end
	local tol = 1e-3 * math.max(1, size.Magnitude)
	for _, entry in rawPts do
		if entry.proj >= bestProj - tol then table.insert(pts, (cf:PointToWorldSpace(entry.lp))) end
	end
	-- Order quad vertices CCW around `dir` when a full face (4 corners) is active so clipping works cleanly.
	if #pts == 4 then
		local c = (pts[1] + pts[2] + pts[3] + pts[4]) * 0.25
		local ref = (pts[1] - c)
		local tangent = dir:Cross(ref)
		table.sort(pts, function(p1: any, p2: any): boolean
			local d1, d2 = p1 - c, p2 - c
			return math.atan2(d1:Dot(tangent), d1:Dot(ref)) < math.atan2(d2:Dot(tangent), d2:Dot(ref))
		end)
	end
	return pts
end

-- Exact Swept 15-axis SAT TOI for OBB `A` moving along `direction` against stationary OBB `B`.
local function blockcastVsBox(
	cfA: any,
	sizeA: any,
	direction: any,
	cfB: any,
	sizeB: any,
	Vector3: any
): (number?, any?, any?)
	local axA, axB = obbAxes(cfA), obbAxes(cfB)
	local hA = { math.max(sizeA.X * 0.5, 0), math.max(sizeA.Y * 0.5, 0), math.max(sizeA.Z * 0.5, 0) }
	local hB = { math.max(sizeB.X * 0.5, 0), math.max(sizeB.Y * 0.5, 0), math.max(sizeB.Z * 0.5, 0) }
	local delta0 = cfA.Position - cfB.Position

	local tEnter = -math.huge
	local tExit = math.huge
	local hitNormal: any = nil

	local function testAxis(L: any, rTotal: number): boolean
		local c0 = delta0:Dot(L)
		local vL = direction:Dot(L)
		if math.abs(vL) < PARALLEL_EPS then
			if math.abs(c0) > rTotal + 1e-9 then return false end
			return true
		end
		local t1 = (-rTotal - c0) / vL
		local t2 = (rTotal - c0) / vL
		local n = if vL > 0 then -L else L
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		if t1 > tEnter then
			tEnter, hitNormal = t1, n
		end
		tExit = math.min(tExit, t2)
		return tEnter <= tExit + 1e-9
	end

	for i = 1, 3 do
		local L = axA[i]
		if not testAxis(L, hA[i] + obbProjRadius(axB, hB, L)) then return nil, nil, nil end
	end
	for j = 1, 3 do
		local L = axB[j]
		if not testAxis(L, obbProjRadius(axA, hA, L) + hB[j]) then return nil, nil, nil end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			local cross = axA[i]:Cross(axB[j])
			local mag = cross.Magnitude
			if mag > 1e-6 then
				local L = cross / mag
				if not testAxis(L, obbProjRadius(axA, hA, L) + obbProjRadius(axB, hB, L)) then return nil, nil, nil end
			end
		end
	end

	-- Ignore initially intersecting boxes (`tEnter < -EPS`), misses (`tEnter > 1`), or behind origin (`tExit < 0`).
	if hitNormal == nil or tEnter < -EPS or tEnter > 1 or tExit < 0 then return nil, nil, nil end
	local t = math.max(0, tEnter)
	local hitCfA = cfA + direction * t
	local supA = obbSupportVertices(hitCfA, sizeA, -hitNormal, Vector3)

	-- Clip A's support feature against B's 6 half-spaces to isolate the true contact patch centroid.
	local clipped = supA
	if #clipped == 2 then
		local p0, p1 = clipped[1], clipped[2]
		local bLocal0 = cfB:PointToObjectSpace(p0)
		local bLocal1 = cfB:PointToObjectSpace(p1)
		local seg = bLocal1 - bLocal0
		local sLo, sHi = 0, 1
		local halfB = { hB[1] + 1e-4, hB[2] + 1e-4, hB[3] + 1e-4 }
		local coords0 = { bLocal0.X, bLocal0.Y, bLocal0.Z }
		local segCoords = { seg.X, seg.Y, seg.Z }
		for i = 1, 3 do
			if math.abs(segCoords[i]) > PARALLEL_EPS then
				local s1 = (-halfB[i] - coords0[i]) / segCoords[i]
				local s2 = (halfB[i] - coords0[i]) / segCoords[i]
				if s1 > s2 then
					s1, s2 = s2, s1
				end
				sLo, sHi = math.max(sLo, s1), math.min(sHi, s2)
			end
		end
		if sLo <= sHi then
			local contact = (p0 + seg * ((sLo + sHi) * 0.5))
			local clampedLocal = closestPointOnBoxLocal(cfB:PointToObjectSpace(contact), sizeB, Vector3)
			return t, cfB:PointToWorldSpace(clampedLocal), hitNormal.Unit
		end
	elseif #clipped >= 3 then
		local centerB = cfB.Position
		for j = 1, 3 do
			local axis = axB[j]
			clipped = clipPolygonAgainstPlane(clipped, axis, centerB:Dot(axis) + hB[j], 1)
			clipped = clipPolygonAgainstPlane(clipped, axis, centerB:Dot(axis) - hB[j], -1)
		end
	end

	local contactPoint: any
	if #clipped > 0 then
		local sum = Vector3.zero
		for _, p in clipped do
			sum += p
		end
		contactPoint = sum / #clipped
	else
		local sumA = Vector3.zero
		for _, p in supA do
			sumA += p
		end
		local meanA = sumA / math.max(#supA, 1)
		contactPoint = cfB:PointToWorldSpace(closestPointOnBoxLocal(cfB:PointToObjectSpace(meanA), sizeB, Vector3))
	end
	return t, contactPoint, hitNormal.Unit
end

-- Continuous Collision Detection via GJK + Conservative Advancement for Cylinder shapes.
local function conservativeAdvanceCast(
	kA: string,
	cfA: any,
	szA: any,
	direction: any,
	kB: string,
	cfB: any,
	szB: any,
	Vector3: any
): (number?, any?, any?)
	local hit0, d0, pA0, pB0, n0 = gjkClosest(kA, cfA, szA, kB, cfB, szB, Vector3)
	if hit0 then return nil, nil, nil end

	local t = 0
	local dist, pA, pB, n = d0, pA0, pB0, n0
	for _ = 1, 64 do
		if dist <= 1e-4 then return t, pB, n end
		local closing = -direction:Dot(n)
		if closing <= 1e-9 then return nil, nil, nil end
		local dtStep = dist / closing
		t += dtStep
		if t > 1 + 1e-6 then return nil, nil, nil end
		t = math.min(t, 1)
		local movedCf = cfA + direction * t
		local over, nextD, nextA, nextB, nextN = gjkClosest(kA, movedCf, szA, kB, cfB, szB, Vector3)
		if over then return t, pB, n end
		dist, pA, pB, n = nextD, nextA, nextB, nextN
		if dist <= 1e-4 then return t, (pA + pB) * 0.5, n end
	end
	if dist <= 1e-3 then return t, pB, n end
	return nil, nil, nil
end

--- Sweeps an oriented box along `direction`, returning the closest `RaycastResult` or `nil`.
function Spatial.blockcast(
	workspaceInst: any,
	terrainInst: any,
	cframe: any,
	size: any,
	direction: any,
	params: any?,
	ctx: any,
	excludePart: any?
): any
	if cframe == nil or size == nil or direction == nil then return nil end
	local dt = ctx.dt
	local Vector3 = dt.Vector3
	local dirLen = direction.Magnitude
	if dirLen <= PARALLEL_EPS then return nil end

	local bestT, bestPart, bestPos, bestNorm = math.huge, nil :: any, nil :: any, nil :: any
	for _, part in Spatial.candidates(workspaceInst, terrainInst, ctx, params, excludePart) do
		local kind = partShapeKind(part)
		local t, pos, norm: any
		if kind == "Box" then
			t, pos, norm = blockcastVsBox(cframe, size, direction, part.CFrame, part.Size, Vector3)
		elseif kind == "Ball" then
			local rB = math.min(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
			local ballCenter = part.CFrame.Position
			local st, _, sn = spherecastVsBox(ballCenter, rB, -direction, cframe, size, Vector3)
			if st ~= nil and sn ~= nil then
				t, pos, norm = st, ballCenter - sn * rB, -sn
			end
		else
			t, pos, norm =
				conservativeAdvanceCast("Box", cframe, size, direction, kind, part.CFrame, part.Size, Vector3)
		end
		if t ~= nil and t < bestT then
			bestT, bestPart, bestPos, bestNorm = t, part, pos, norm
		end
	end
	if bestPart == nil then return nil end
	return dt.newRaycastResult(
		bestPart,
		bestPos,
		bestNorm,
		dirLen * bestT,
		bestPart.Material or ctx.Enum.Material.Plastic
	)
end

--- Sweeps a sphere at `position` with `radius` along `direction`, returning the closest `RaycastResult` or `nil`.
function Spatial.spherecast(
	workspaceInst: any,
	terrainInst: any,
	position: any,
	radius: number,
	direction: any,
	params: any?,
	ctx: any,
	excludePart: any?
): any
	if position == nil or radius == nil or direction == nil or radius < 0 then return nil end
	local dt = ctx.dt
	local Vector3 = dt.Vector3
	local dirLen = direction.Magnitude
	if dirLen <= PARALLEL_EPS then return nil end

	local sphereCf = dt.CFrame.new(position)
	local sphereSz = Vector3.new(radius * 2, radius * 2, radius * 2)
	local bestT, bestPart, bestPos, bestNorm = math.huge, nil :: any, nil :: any, nil :: any

	for _, part in Spatial.candidates(workspaceInst, terrainInst, ctx, params, excludePart) do
		local kind = partShapeKind(part)
		local t, pos, norm: any
		if kind == "Box" then
			t, pos, norm = spherecastVsBox(position, radius, direction, part.CFrame, part.Size, Vector3)
		elseif kind == "Ball" then
			local rB = math.min(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
			local hitT, _, hitN = rayVsBall(
				part.CFrame,
				Vector3.new(2 * (radius + rB), 2 * (radius + rB), 2 * (radius + rB)),
				position,
				direction
			)
			if hitT ~= nil and hitN ~= nil then
				t, pos, norm = hitT, part.CFrame.Position + hitN * rB, hitN
			end
		else
			t, pos, norm =
				conservativeAdvanceCast("Ball", sphereCf, sphereSz, direction, kind, part.CFrame, part.Size, Vector3)
		end
		if t ~= nil and t < bestT then
			bestT, bestPart, bestPos, bestNorm = t, part, pos, norm
		end
	end
	if bestPart == nil then return nil end
	return dt.newRaycastResult(
		bestPart,
		bestPos,
		bestNorm,
		dirLen * bestT,
		bestPart.Material or ctx.Enum.Material.Plastic
	)
end

--- Sweeps a BasePart's geometry along `direction` (with optional `cframeOverride` and `sizeOverride`).
function Spatial.shapecast(
	workspaceInst: any,
	terrainInst: any,
	part: any,
	direction: any,
	params: any?,
	cframeOverride: any?,
	sizeOverride: any?,
	ctx: any
): any
	if part == nil or direction == nil then return nil end
	local cf = cframeOverride or part.CFrame
	local sz = sizeOverride or part.Size
	local kind = partShapeKind(part)
	if kind == "Ball" then
		local r = math.min(sz.X, sz.Y, sz.Z) * 0.5
		return Spatial.spherecast(workspaceInst, terrainInst, cf.Position, r, direction, params, ctx, part)
	elseif kind == "Box" then
		return Spatial.blockcast(workspaceInst, terrainInst, cf, sz, direction, params, ctx, part)
	end
	local dt = ctx.dt
	local Vector3 = dt.Vector3
	local dirLen = direction.Magnitude
	if dirLen <= PARALLEL_EPS then return nil end

	local bestT, bestPart, bestPos, bestNorm = math.huge, nil :: any, nil :: any, nil :: any
	for _, other in Spatial.candidates(workspaceInst, terrainInst, ctx, params, part) do
		local t, pos, norm = conservativeAdvanceCast(
			"Cylinder",
			cf,
			sz,
			direction,
			partShapeKind(other),
			other.CFrame,
			other.Size,
			Vector3
		)
		if t ~= nil and t < bestT then
			bestT, bestPart, bestPos, bestNorm = t, other, pos, norm
		end
	end
	if bestPart == nil then return nil end
	return dt.newRaycastResult(
		bestPart,
		bestPos,
		bestNorm,
		dirLen * bestT,
		bestPart.Material or ctx.Enum.Material.Plastic
	)
end

return Spatial
