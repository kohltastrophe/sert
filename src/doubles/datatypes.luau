--!strict
-- Headless Roblox datatype and Enum doubles for standalone Luau (`sert.env`).

local Rng = require("../rng")
local Generated = require("./generated")

local Datatypes: any = {}
local nativeType, nativeTypeof = type, typeof

local function doubleTag(value: any): string?
	if nativeType(value) == "table" then
		local mt = getmetatable(value)
		if nativeType(mt) == "table" and nativeType(rawget(mt, "__type")) == "string" then
			return rawget(mt, "__type") :: string
		elseif rawget(value, "_isInstance") == true then
			return "Instance"
		end
	end
	return nil
end

local function customTypeof(value: any): string return doubleTag(value) or nativeTypeof(value) end

local function customType(value: any): string return if doubleTag(value) ~= nil then "userdata" else nativeType(value) end

Datatypes.typeof = customTypeof
Datatypes.type = customType
Datatypes.doubleTag = doubleTag

local DATATYPE_GLOBALS = table.freeze({
	"Random",
	"Ray",
	"Color3",
	"BrickColor",
	"UDim",
	"UDim2",
	"Vector2",
	"Vector3",
	"Vector2int16",
	"Vector3int16",
	"CFrame",
	"Rect",
	"Region3",
	"Axes",
	"Faces",
	"NumberRange",
	"ColorSequence",
	"ColorSequenceKeypoint",
	"NumberSequence",
	"NumberSequenceKeypoint",
	"Font",
	"TweenInfo",
	"FloatCurveKey",
	"Enum",
	"CatalogSearchParams",
	"RaycastParams",
	"OverlapParams",
	"PhysicalProperties",
	"PathWaypoint",
})
Datatypes.DATATYPE_GLOBALS = DATATYPE_GLOBALS

local customUtf8 = table.freeze(setmetatable({
	graphemes = function(str: string, i: number?, j: number?)
		local pos, endByte = i or 1, j or #str
		return function(): (number?, number?)
			if pos > endByte or pos > #str then return nil, nil end
			local first, b = pos, string.byte(str, pos)
			local charLen = if b < 0x80 then 1 elseif b < 0xE0 then 2 elseif b < 0xF0 then 3 else 4
			local last = math.min(pos + charLen - 1, #str)
			pos = last + 1
			return first, last
		end
	end,
	nfcnormalize = function(s: string): string return s end,
	nfdnormalize = function(s: string): string return s end,
}, { __index = utf8 }))
Datatypes.utf8 = customUtf8

local function near(a: number, b: number, eps: number?): boolean return a == b or math.abs(a - b) <= (eps or 1e-6) end

local function clamp01(n: number): number return math.clamp(n, 0, 1) end

-- Color3 -------------------------------------------------------------------------------------------------------------

local Color3 = {}
local Color3Meta = { __index = Color3, __type = "Color3" }

function Color3.new(r: number?, g: number?, b: number?): any
	return table.freeze(setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3Meta))
end

function Color3.fromRGB(r: number?, g: number?, b: number?): any
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end

function Color3.fromHSV(h: number?, s: number?, v: number?): any
	local hh, ss, vv = ((h or 0) % 1) * 6, clamp01(s or 0), clamp01(v or 0)
	local c = vv * ss
	local x, m = c * (1 - math.abs((hh % 2) - 1)), vv - c
	local r, g, b = 0, 0, 0
	if hh < 1 then
		r, g, b = c, x, 0
	elseif hh < 2 then
		r, g, b = x, c, 0
	elseif hh < 3 then
		r, g, b = 0, c, x
	elseif hh < 4 then
		r, g, b = 0, x, c
	elseif hh < 5 then
		r, g, b = x, 0, c
	else
		r, g, b = c, 0, x
	end
	return Color3.new(r + m, g + m, b + m)
end

function Color3.fromHex(hex: string): any
	local clean = if type(hex) == "string" then string.match(hex, "^#?(%x+)$") else nil
	if clean ~= nil then
		if #clean == 3 then
			local r, g, b = string.sub(clean, 1, 1), string.sub(clean, 2, 2), string.sub(clean, 3, 3)
			clean = r .. r .. g .. g .. b .. b
		end
		if #clean == 6 then
			return Color3.fromRGB(
				tonumber(string.sub(clean, 1, 2), 16),
				tonumber(string.sub(clean, 3, 4), 16),
				tonumber(string.sub(clean, 5, 6), 16)
			)
		end
	end
	error(`Color3.fromHex: invalid hex "{hex}"`, 0)
end

function Color3.ToHSV(self: any): (number, number, number)
	local r, g, b = self.R, self.G, self.B
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local d, h = max - min, 0
	if max ~= min then
		if max == r then
			h = (g - b) / d + (if g < b then 6 else 0)
		elseif max == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h /= 6
	end
	return h, if max == 0 then 0 else d / max, max
end
Color3.toHSV = Color3.ToHSV

function Color3.ToHex(self: any): string
	return string.format(
		"%02x%02x%02x",
		math.round(clamp01(self.R) * 255),
		math.round(clamp01(self.G) * 255),
		math.round(clamp01(self.B) * 255)
	)
end

function Color3.Lerp(self: any, goal: any, alpha: number): any
	return Color3.new(
		self.R + (goal.R - self.R) * alpha,
		self.G + (goal.G - self.G) * alpha,
		self.B + (goal.B - self.B) * alpha
	)
end

function Color3Meta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "Color3"
		and customTypeof(b) == "Color3"
		and near(a.R, b.R)
		and near(a.G, b.G)
		and near(a.B, b.B)
end

function Color3Meta.__tostring(self: any): string return `{self.R}, {self.G}, {self.B}` end

Datatypes.Color3 = table.freeze(Color3)

-- BrickColor ---------------------------------------------------------------------------------------------------------

local BRICK_PALETTE: { { name: string, number: number, r: number, g: number, b: number } } = {
	{ name = "White", number = 1, r = 242, g = 243, b = 243 },
	{ name = "Grey", number = 2, r = 161, g = 165, b = 162 },
	{ name = "Light yellow", number = 3, r = 249, g = 233, b = 153 },
	{ name = "Brick yellow", number = 5, r = 215, g = 197, b = 154 },
	{ name = "Bright red", number = 21, r = 196, g = 40, b = 28 },
	{ name = "Bright blue", number = 23, r = 13, g = 105, b = 172 },
	{ name = "Bright yellow", number = 24, r = 245, g = 205, b = 48 },
	{ name = "Black", number = 26, r = 27, g = 42, b = 53 },
	{ name = "Dark green", number = 28, r = 40, g = 127, b = 71 },
	{ name = "Bright green", number = 37, r = 75, g = 151, b = 75 },
	{ name = "Bright orange", number = 106, r = 218, g = 133, b = 65 },
	{ name = "Medium stone grey", number = 194, r = 163, g = 162, b = 165 },
	{ name = "Institutional white", number = 1001, r = 248, g = 248, b = 248 },
	{ name = "Really black", number = 1003, r = 17, g = 17, b = 17 },
	{ name = "Really red", number = 1004, r = 255, g = 0, b = 0 },
	{ name = "Lime green", number = 1020, r = 0, g = 255, b = 0 },
	{ name = "Really blue", number = 1010, r = 0, g = 0, b = 255 },
	{ name = "New Yeller", number = 1009, r = 255, g = 255, b = 0 },
}

local BrickColor: any = {}
local BrickColorMeta = { __index = BrickColor, __type = "BrickColor" }

local function makeBrick(entry: { name: string, number: number, r: number, g: number, b: number }): any
	local c = Color3.fromRGB(entry.r, entry.g, entry.b)
	return table.freeze(
		setmetatable({ Name = entry.name, Number = entry.number, Color = c, r = c.R, g = c.G, b = c.B }, BrickColorMeta)
	)
end

function BrickColor.new(a: any, b: number?, c: number?): any
	if type(a) == "string" then
		local lower = string.lower(a)
		for _, entry in BRICK_PALETTE do
			if string.lower(entry.name) == lower then return makeBrick(entry) end
		end
		return makeBrick(BRICK_PALETTE[12])
	elseif type(a) == "number" and b == nil then
		for _, entry in BRICK_PALETTE do
			if entry.number == a then return makeBrick(entry) end
		end
		return BrickColor.palette(a)
	elseif type(a) == "number" and b ~= nil and c ~= nil then
		return BrickColor.new(Color3.new(a, b, c))
	elseif customTypeof(a) == "Color3" then
		local best, bestDist = BRICK_PALETTE[1], math.huge
		for _, entry in BRICK_PALETTE do
			local dr, dg, db = a.R - entry.r / 255, a.G - entry.g / 255, a.B - entry.b / 255
			local dist = dr * dr + dg * dg + db * db
			if dist < bestDist then
				bestDist, best = dist, entry
			end
		end
		return makeBrick(best)
	end
	return makeBrick(BRICK_PALETTE[12])
end

function BrickColor.palette(index: number): any
	return makeBrick(BRICK_PALETTE[(math.abs(math.floor(index)) % #BRICK_PALETTE) + 1])
end

local brickRngState = 1
function BrickColor.random(): any
	brickRngState = Rng.xorshift32(brickRngState)
	return makeBrick(BRICK_PALETTE[(brickRngState % #BRICK_PALETTE) + 1])
end

for method, brickName in
	{
		White = "White",
		Black = "Black",
		Red = "Bright red",
		Green = "Dark green",
		Blue = "Bright blue",
		Yellow = "Bright yellow",
	} :: { [string]: string }
do
	BrickColor[method] = function(): any return BrickColor.new(brickName) end
end

function BrickColorMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "BrickColor" and customTypeof(b) == "BrickColor" and a.Number == b.Number
end

function BrickColorMeta.__tostring(self: any): string return self.Name end

Datatypes.BrickColor = table.freeze(BrickColor)

-- UDim & UDim2 -------------------------------------------------------------------------------------------------------

local UDim = {}
local UDimMeta = { __index = UDim, __type = "UDim" }

function UDim.new(scale: number?, offset: number?): any
	local off = offset or 0
	return table.freeze(
		setmetatable({ Scale = scale or 0, Offset = if off >= 0 then math.floor(off) else math.ceil(off) }, UDimMeta)
	)
end

function UDimMeta.__add(a: any, b: any): any return UDim.new(a.Scale + b.Scale, a.Offset + b.Offset) end

function UDimMeta.__sub(a: any, b: any): any return UDim.new(a.Scale - b.Scale, a.Offset - b.Offset) end

function UDimMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "UDim" and customTypeof(b) == "UDim" and near(a.Scale, b.Scale) and a.Offset == b.Offset
end

function UDimMeta.__tostring(self: any): string return `{self.Scale}, {self.Offset}` end

Datatypes.UDim = table.freeze(UDim)

local UDim2 = {}
local UDim2Meta = { __index = UDim2, __type = "UDim2" }

function UDim2.new(a: any?, b: any?, c: number?, d: number?): any
	local x: any, y: any
	if customTypeof(a) == "UDim" and customTypeof(b) == "UDim" then
		x, y = a, b
	else
		x, y = UDim.new(a or 0, b or 0), UDim.new(c or 0, d or 0)
	end
	return table.freeze(setmetatable({ X = x, Y = y, Width = x, Height = y }, UDim2Meta))
end

-- selene: allow(roblox_manual_fromscale_or_fromoffset)
function UDim2.fromScale(xs: number?, ys: number?): any return UDim2.new(xs or 0, 0, ys or 0, 0) end

-- selene: allow(roblox_manual_fromscale_or_fromoffset)
function UDim2.fromOffset(xo: number?, yo: number?): any return UDim2.new(0, xo or 0, 0, yo or 0) end

function UDim2.Lerp(self: any, goal: any, alpha: number): any
	return UDim2.new(
		self.X.Scale + (goal.X.Scale - self.X.Scale) * alpha,
		self.X.Offset + (goal.X.Offset - self.X.Offset) * alpha,
		self.Y.Scale + (goal.Y.Scale - self.Y.Scale) * alpha,
		self.Y.Offset + (goal.Y.Offset - self.Y.Offset) * alpha
	)
end

function UDim2Meta.__add(a: any, b: any): any return UDim2.new(a.X + b.X, a.Y + b.Y) end

function UDim2Meta.__sub(a: any, b: any): any return UDim2.new(a.X - b.X, a.Y - b.Y) end

function UDim2Meta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "UDim2" and customTypeof(b) == "UDim2" and a.X == b.X and a.Y == b.Y
end

function UDim2Meta.__tostring(self: any): string
	return `\{{self.X.Scale}, {self.X.Offset}\}, \{{self.Y.Scale}, {self.Y.Offset}\}`
end

Datatypes.UDim2 = table.freeze(UDim2)

-- Vector2 & Vector3 --------------------------------------------------------------------------------------------------

local Vector2: any = {}
local Vector2Meta: any = { __type = "Vector2" }

function Vector2.new(x: number?, y: number?): any
	local vx, vy = x or 0, y or 0
	return table.freeze(setmetatable({ X = vx, Y = vy, x = vx, y = vy }, Vector2Meta))
end

function Vector2Meta.__index(self: any, key: string): any
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y)
	elseif key == "Unit" then
		local mag = math.sqrt(self.X * self.X + self.Y * self.Y)
		return Vector2.new(self.X / mag, self.Y / mag)
	end
	return Vector2[key]
end

function Vector2.Lerp(self: any, goal: any, alpha: number): any
	return Vector2.new(self.X + (goal.X - self.X) * alpha, self.Y + (goal.Y - self.Y) * alpha)
end

function Vector2.Dot(self: any, other: any): number return self.X * other.X + self.Y * other.Y end

function Vector2.Cross(self: any, other: any): number return self.X * other.Y - self.Y * other.X end

for name, fn in
	{ Abs = math.abs, Ceil = math.ceil, Floor = math.floor, Sign = math.sign } :: { [string]: (number) -> number }
do
	Vector2[name] = function(self: any): any return Vector2.new(fn(self.X), fn(self.Y)) end
end

for name, fn in { Max = math.max, Min = math.min } :: { [string]: (number, number) -> number } do
	Vector2[name] = function(self: any, ...: any): any
		local x, y = self.X, self.Y
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			x, y = fn(x, v.X), fn(y, v.Y)
		end
		return Vector2.new(x, y)
	end
end

local function vec2BinOp(a: any, b: any, op: (number, number) -> number): any
	return if type(a) == "number"
		then Vector2.new(op(a, b.X), op(a, b.Y))
		elseif type(b) == "number" then Vector2.new(op(a.X, b), op(a.Y, b))
		else Vector2.new(op(a.X, b.X), op(a.Y, b.Y))
end

local function mulNum(x: number, y: number): number return x * y end
local function divNum(x: number, y: number): number return x / y end

function Vector2Meta.__add(a: any, b: any): any return Vector2.new(a.X + b.X, a.Y + b.Y) end
function Vector2Meta.__sub(a: any, b: any): any return Vector2.new(a.X - b.X, a.Y - b.Y) end
function Vector2Meta.__mul(a: any, b: any): any return vec2BinOp(a, b, mulNum) end
function Vector2Meta.__div(a: any, b: any): any return vec2BinOp(a, b, divNum) end
function Vector2Meta.__unm(a: any): any return Vector2.new(-a.X, -a.Y) end
function Vector2Meta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "Vector2" and customTypeof(b) == "Vector2" and near(a.X, b.X) and near(a.Y, b.Y)
end
function Vector2Meta.__tostring(self: any): string return `{self.X}, {self.Y}` end

Vector2.zero = Vector2.new(0, 0)
Vector2.one = Vector2.new(1, 1)
Vector2.xAxis = Vector2.new(1, 0)
Vector2.yAxis = Vector2.new(0, 1)
Datatypes.Vector2 = table.freeze(Vector2)

local Vector3: any = {}
local Vector3Meta: any = { __type = "Vector3" }
local vectorCreate: ((number, number, number) -> any)? = if (vector :: any) ~= nil then (vector :: any).create else nil
local vector3Cache: { [any]: any } = setmetatable({}, { __mode = "v" }) :: any

function Vector3.new(x: number?, y: number?, z: number?): any
	local vx, vy, vz = x or 0, y or 0, z or 0
	local key = nil
	if vectorCreate ~= nil and vx == vx and vy == vy and vz == vz then
		key = vectorCreate(vx, vy, vz)
		local hit = vector3Cache[key]
		if hit ~= nil and rawequal(hit.X, vx) and rawequal(hit.Y, vy) and rawequal(hit.Z, vz) then return hit end
	end
	local made = table.freeze(setmetatable({ X = vx, Y = vy, Z = vz, x = vx, y = vy, z = vz }, Vector3Meta))
	if key ~= nil and vector3Cache[key] == nil then vector3Cache[key] = made end
	return made
end

function Vector3Meta.__index(self: any, key: string): any
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local mag = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		return Vector3.new(self.X / mag, self.Y / mag, self.Z / mag)
	end
	return Vector3[key]
end

function Vector3.Lerp(self: any, goal: any, alpha: number): any
	return Vector3.new(
		self.X + (goal.X - self.X) * alpha,
		self.Y + (goal.Y - self.Y) * alpha,
		self.Z + (goal.Z - self.Z) * alpha
	)
end

function Vector3.Dot(self: any, other: any): number return self.X * other.X + self.Y * other.Y + self.Z * other.Z end

function Vector3.Cross(self: any, other: any): any
	return Vector3.new(
		self.Y * other.Z - self.Z * other.Y,
		self.Z * other.X - self.X * other.Z,
		self.X * other.Y - self.Y * other.X
	)
end

for name, fn in
	{ Abs = math.abs, Ceil = math.ceil, Floor = math.floor, Sign = math.sign } :: { [string]: (number) -> number }
do
	Vector3[name] = function(self: any): any return Vector3.new(fn(self.X), fn(self.Y), fn(self.Z)) end
end

function Vector3.FuzzyEq(self: any, other: any, epsilon: number?): boolean
	local eps = epsilon or 1e-5
	return near(self.X, other.X, eps) and near(self.Y, other.Y, eps) and near(self.Z, other.Z, eps)
end

for name, fn in { Max = math.max, Min = math.min } :: { [string]: (number, number) -> number } do
	Vector3[name] = function(self: any, ...: any): any
		local x, y, z = self.X, self.Y, self.Z
		for i = 1, select("#", ...) do
			local v = select(i, ...)
			x, y, z = fn(x, v.X), fn(y, v.Y), fn(z, v.Z)
		end
		return Vector3.new(x, y, z)
	end
end

local NORMAL_VECTORS: { [any]: { number } } = {
	Right = { 1, 0, 0 },
	[0] = { 1, 0, 0 },
	Top = { 0, 1, 0 },
	[1] = { 0, 1, 0 },
	Back = { 0, 0, 1 },
	[2] = { 0, 0, 1 },
	Left = { -1, 0, 0 },
	[3] = { -1, 0, 0 },
	Bottom = { 0, -1, 0 },
	[4] = { 0, -1, 0 },
	Front = { 0, 0, -1 },
	[5] = { 0, 0, -1 },
}

function Vector3.FromNormalId(normal: any): any
	local key = if type(normal) == "table" and normal.Name then normal.Name else normal
	local v = NORMAL_VECTORS[key] or NORMAL_VECTORS[tostring(normal)]
	return if v ~= nil then Vector3.new(v[1], v[2], v[3]) else Vector3.zero
end

function Vector3.FromAxis(axis: any): any
	local name = if type(axis) == "table" and axis.Name then axis.Name else tostring(axis)
	if name == "X" or axis == 0 then
		return Vector3.xAxis
	elseif name == "Y" or axis == 1 then
		return Vector3.yAxis
	elseif name == "Z" or axis == 2 then
		return Vector3.zAxis
	end
	return Vector3.zero
end

local function vec3BinOp(a: any, b: any, op: (number, number) -> number): any
	return if type(a) == "number"
		then Vector3.new(op(a, b.X), op(a, b.Y), op(a, b.Z))
		elseif type(b) == "number" then Vector3.new(op(a.X, b), op(a.Y, b), op(a.Z, b))
		else Vector3.new(op(a.X, b.X), op(a.Y, b.Y), op(a.Z, b.Z))
end

function Vector3Meta.__add(a: any, b: any): any return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
function Vector3Meta.__sub(a: any, b: any): any return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function Vector3Meta.__mul(a: any, b: any): any return vec3BinOp(a, b, mulNum) end
function Vector3Meta.__div(a: any, b: any): any return vec3BinOp(a, b, divNum) end
function Vector3Meta.__unm(a: any): any return Vector3.new(-a.X, -a.Y, -a.Z) end
function Vector3Meta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "Vector3"
		and customTypeof(b) == "Vector3"
		and near(a.X, b.X)
		and near(a.Y, b.Y)
		and near(a.Z, b.Z)
end
function Vector3Meta.__tostring(self: any): string return `{self.X}, {self.Y}, {self.Z}` end

Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.zAxis = Vector3.new(0, 0, 1)
Datatypes.Vector3 = table.freeze(Vector3)

-- CFrame -------------------------------------------------------------------------------------------------------------

local CFrame: any = {}
local CFrameMeta: any = { __type = "CFrame" }

local function buildCFrame(
	x: number,
	y: number,
	z: number,
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
): any
	local pos, right, up, look =
		Vector3.new(x, y, z), Vector3.new(r00, r10, r20), Vector3.new(r01, r11, r21), Vector3.new(-r02, -r12, -r22)
	return table.freeze(setmetatable({
		X = x,
		Y = y,
		Z = z,
		Position = pos,
		p = pos,
		RightVector = right,
		UpVector = up,
		LookVector = look,
		XVector = right,
		YVector = up,
		ZVector = Vector3.new(r02, r12, r22),
		_m = { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 },
	}, CFrameMeta))
end

function CFrameMeta.__index(self: any, key: string): any
	if key == "Rotation" then
		local m = self._m
		return buildCFrame(0, 0, 0, m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12])
	end
	return CFrame[key]
end

function CFrame.new(...: any): any
	local count = select("#", ...)
	if count == 0 then
		return buildCFrame(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif count == 1 then
		local v = select(1, ...)
		return buildCFrame(v.X, v.Y, v.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif count == 2 then
		return CFrame.lookAt(select(1, ...), select(2, ...))
	elseif count == 3 then
		local x, y, z = ...
		return buildCFrame(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif count == 7 then
		local x, y, z, qx, qy, qz, qw = ...
		local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
		if n == 0 then return buildCFrame(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
		qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
		return buildCFrame(
			x,
			y,
			z,
			1 - 2 * (qy * qy + qz * qz),
			2 * (qx * qy - qz * qw),
			2 * (qx * qz + qy * qw),
			2 * (qx * qy + qz * qw),
			1 - 2 * (qx * qx + qz * qz),
			2 * (qy * qz - qx * qw),
			2 * (qx * qz - qy * qw),
			2 * (qy * qz + qx * qw),
			1 - 2 * (qx * qx + qy * qy)
		)
	elseif count >= 12 then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = ...
		return buildCFrame(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	end
	return buildCFrame(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
end

function CFrame.fromMatrix(pos: any, vx: any, vy: any, vz: any?): any
	local z = vz or vx:Cross(vy).Unit
	return buildCFrame(pos.X, pos.Y, pos.Z, vx.X, vy.X, z.X, vx.Y, vy.Y, z.Y, vx.Z, vy.Z, z.Z)
end

function CFrame.lookAt(at: any, lookAt: any, up: any?): any
	local upVec = up or Vector3.yAxis
	local toward = lookAt - at
	local forward = if toward.Magnitude == 0 then -Vector3.zAxis else toward.Unit
	local across = forward:Cross(upVec)
	local right = if across.Magnitude == 0 then Vector3.xAxis else across.Unit
	return CFrame.fromMatrix(at, right, right:Cross(forward).Unit, -forward)
end

function CFrame.fromEulerAnglesXYZ(rx: number?, ry: number?, rz: number?): any
	local cx, sx = math.cos(rx or 0), math.sin(rx or 0)
	local cy, sy = math.cos(ry or 0), math.sin(ry or 0)
	local cz, sz = math.cos(rz or 0), math.sin(rz or 0)
	return buildCFrame(
		0,
		0,
		0,
		cy * cz,
		-cy * sz,
		sy,
		sx * sy * cz + cx * sz,
		-sx * sy * sz + cx * cz,
		-sx * cy,
		-cx * sy * cz + sx * sz,
		cx * sy * sz + sx * cz,
		cx * cy
	)
end
CFrame.Angles = CFrame.fromEulerAnglesXYZ

function CFrame.fromEulerAnglesYXZ(ry: number?, rx: number?, rz: number?): any
	local cy, sy = math.cos(ry or 0), math.sin(ry or 0)
	local cx, sx = math.cos(rx or 0), math.sin(rx or 0)
	local cz, sz = math.cos(rz or 0), math.sin(rz or 0)
	return buildCFrame(
		0,
		0,
		0,
		cy * cz + sy * sx * sz,
		sy * sx * cz - cy * sz,
		sy * cx,
		cx * sz,
		cx * cz,
		-sx,
		cy * sx * sz - sy * cz,
		sy * sz + cy * sx * cz,
		cy * cx
	)
end

function CFrame.fromOrientation(rx: number?, ry: number?, rz: number?): any return CFrame.fromEulerAnglesYXZ(ry, rx, rz) end

function CFrame.fromAxisAngle(v: any, r: number): any
	if v.Magnitude < 1e-6 or r == 0 then return CFrame.identity end
	local u, c, s = v.Unit, math.cos(r), math.sin(r)
	local t = 1 - c
	return buildCFrame(
		0,
		0,
		0,
		t * u.X * u.X + c,
		t * u.X * u.Y - s * u.Z,
		t * u.X * u.Z + s * u.Y,
		t * u.X * u.Y + s * u.Z,
		t * u.Y * u.Y + c,
		t * u.Y * u.Z - s * u.X,
		t * u.X * u.Z - s * u.Y,
		t * u.Y * u.Z + s * u.X,
		t * u.Z * u.Z + c
	)
end

function CFrame.GetComponents(self: any): (
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number,
	number
)
	local m = self._m
	return m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12]
end
CFrame.components = CFrame.GetComponents

function CFrame.Inverse(self: any): any
	local m = self._m
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 =
		m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12]
	return buildCFrame(
		-(r00 * x + r10 * y + r20 * z),
		-(r01 * x + r11 * y + r21 * z),
		-(r02 * x + r12 * y + r22 * z),
		r00,
		r10,
		r20,
		r01,
		r11,
		r21,
		r02,
		r12,
		r22
	)
end

function CFrame.PointToWorldSpace(self: any, v: any): any return self.Position + self:VectorToWorldSpace(v) end

function CFrame.PointToObjectSpace(self: any, v: any): any return self:Inverse():PointToWorldSpace(v) end

function CFrame.VectorToWorldSpace(self: any, v: any): any
	local m = self._m
	return Vector3.new(
		m[4] * v.X + m[5] * v.Y + m[6] * v.Z,
		m[7] * v.X + m[8] * v.Y + m[9] * v.Z,
		m[10] * v.X + m[11] * v.Y + m[12] * v.Z
	)
end

function CFrame.VectorToObjectSpace(self: any, v: any): any return self:Inverse():VectorToWorldSpace(v) end

function CFrame.ToWorldSpace(self: any, cf: any): any return self * cf end

function CFrame.ToObjectSpace(self: any, cf: any): any return self:Inverse() * cf end

function CFrame.ToAxisAngle(self: any): (any, number)
	local m = self._m
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12]
	local trace = r00 + r11 + r22
	local qx, qy, qz, qw: number
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		qw, qx, qy, qz = 0.25 * s, (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		qw, qx, qy, qz = (r21 - r12) / s, 0.25 * s, (r01 + r10) / s, (r02 + r20) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		qw, qx, qy, qz = (r02 - r20) / s, (r01 + r10) / s, 0.25 * s, (r12 + r21) / s
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		qw, qx, qy, qz = (r10 - r01) / s, (r02 + r20) / s, (r12 + r21) / s, 0.25 * s
	end
	if qw < 0 then
		qx, qy, qz, qw = -qx, -qy, -qz, -qw
	end
	local sinHalf = math.sqrt(qx * qx + qy * qy + qz * qz)
	if sinHalf < 1e-7 then return Vector3.yAxis, 0 end
	return Vector3.new(qx / sinHalf, qy / sinHalf, qz / sinHalf), 2 * math.atan2(sinHalf, qw)
end

function CFrame.Lerp(self: any, goal: any, alpha: number): any
	if alpha == 0 then
		return self
	elseif alpha == 1 then
		return goal
	end
	local pos = self.Position:Lerp(goal.Position, alpha)
	local axis, theta = (self:Inverse() * goal):ToAxisAngle()
	if theta < 1e-7 then return self.Rotation + pos end
	return (self.Rotation * CFrame.fromAxisAngle(axis, theta * alpha)) + pos
end

function CFrame.ToEulerAnglesXYZ(self: any): (number, number, number)
	local m = self._m
	local sy = math.clamp(m[6], -1, 1)
	local ry = math.asin(sy)
	if math.abs(sy) < 0.99999 then return math.atan2(-m[9], m[12]), ry, math.atan2(-m[5], m[4]) end
	return math.atan2(m[8], m[7]), ry, 0
end

function CFrame.ToEulerAnglesYXZ(self: any): (number, number, number)
	local m = self._m
	local sx = math.clamp(-m[9], -1, 1)
	local rx = math.asin(sx)
	if math.abs(sx) < 0.99999 then return math.atan2(m[6], m[12]), rx, math.atan2(m[7], m[8]) end
	return math.atan2(-m[10], m[4]), rx, 0
end

function CFrame.ToOrientation(self: any): (number, number, number)
	local ry, rx, rz = self:ToEulerAnglesYXZ()
	return rx, ry, rz
end

function CFrame.FuzzyEq(self: any, other: any, epsilon: number?): boolean
	if customTypeof(other) ~= "CFrame" then return false end
	local eps = epsilon or 1e-5
	for i = 1, 12 do
		if math.abs(self._m[i] - other._m[i]) > eps then return false end
	end
	return true
end

function CFrameMeta.__mul(a: any, b: any): any
	if customTypeof(b) == "Vector3" then return a:PointToWorldSpace(b) end
	local am, bm = a._m, b._m
	local ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22 =
		am[1], am[2], am[3], am[4], am[5], am[6], am[7], am[8], am[9], am[10], am[11], am[12]
	local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 =
		bm[1], bm[2], bm[3], bm[4], bm[5], bm[6], bm[7], bm[8], bm[9], bm[10], bm[11], bm[12]
	return buildCFrame(
		ax + a00 * bx + a01 * by + a02 * bz,
		ay + a10 * bx + a11 * by + a12 * bz,
		az + a20 * bx + a21 * by + a22 * bz,
		a00 * b00 + a01 * b10 + a02 * b20,
		a00 * b01 + a01 * b11 + a02 * b21,
		a00 * b02 + a01 * b12 + a02 * b22,
		a10 * b00 + a11 * b10 + a12 * b20,
		a10 * b01 + a11 * b11 + a12 * b21,
		a10 * b02 + a11 * b12 + a12 * b22,
		a20 * b00 + a21 * b10 + a22 * b20,
		a20 * b01 + a21 * b11 + a22 * b21,
		a20 * b02 + a21 * b12 + a22 * b22
	)
end

function CFrameMeta.__add(a: any, b: any): any
	local m = a._m
	return buildCFrame(m[1] + b.X, m[2] + b.Y, m[3] + b.Z, m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12])
end

function CFrameMeta.__sub(a: any, b: any): any
	local m = a._m
	return buildCFrame(m[1] - b.X, m[2] - b.Y, m[3] - b.Z, m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12])
end

function CFrameMeta.__eq(a: any, b: any): boolean
	if customTypeof(a) ~= "CFrame" or customTypeof(b) ~= "CFrame" then return false end
	for i = 1, 12 do
		if math.abs(a._m[i] - b._m[i]) > 1e-5 then return false end
	end
	return true
end

function CFrameMeta.__tostring(self: any): string
	local parts = table.create(12)
	for i = 1, 12 do
		parts[i] = tostring(self._m[i])
	end
	return table.concat(parts, ", ")
end

CFrame.identity = CFrame.new()
Datatypes.CFrame = table.freeze(CFrame)

-- Rect, NumberRange, Sequences, Font, TweenInfo ----------------------------------------------------------------------

local Rect = {}
local RectMeta = { __index = Rect, __type = "Rect" }

function Rect.new(a: any?, b: any?, c: number?, d: number?): any
	local minV: any, maxV: any
	if customTypeof(a) == "Vector2" and customTypeof(b) == "Vector2" then
		minV, maxV = a, b
	else
		minV, maxV = Vector2.new(a or 0, b or 0), Vector2.new(c or 0, d or 0)
	end
	return table.freeze(
		setmetatable({ Min = minV, Max = maxV, Width = maxV.X - minV.X, Height = maxV.Y - minV.Y }, RectMeta)
	)
end

function RectMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "Rect" and customTypeof(b) == "Rect" and a.Min == b.Min and a.Max == b.Max
end

function RectMeta.__tostring(self: any): string return `{self.Min.X}, {self.Min.Y}, {self.Max.X}, {self.Max.Y}` end

Datatypes.Rect = table.freeze(Rect)

local NumberRange = {}
local NumberRangeMeta = { __index = NumberRange, __type = "NumberRange" }

function NumberRange.new(min: number, max: number?): any
	local hi = if max == nil then min else max
	if hi < min then error("NumberRange: invalid range", 2) end
	return table.freeze(setmetatable({ Min = min, Max = hi }, NumberRangeMeta))
end

function NumberRangeMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "NumberRange"
		and customTypeof(b) == "NumberRange"
		and near(a.Min, b.Min)
		and near(a.Max, b.Max)
end

function NumberRangeMeta.__tostring(self: any): string return `{self.Min} {self.Max}` end

Datatypes.NumberRange = table.freeze(NumberRange)

local ColorSequenceKeypoint = {}
local ColorSequenceKeypointMeta = { __index = ColorSequenceKeypoint, __type = "ColorSequenceKeypoint" }

function ColorSequenceKeypoint.new(time: number, value: any): any
	return table.freeze(setmetatable({ Time = time, Value = value }, ColorSequenceKeypointMeta))
end

function ColorSequenceKeypointMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "ColorSequenceKeypoint"
		and customTypeof(b) == "ColorSequenceKeypoint"
		and near(a.Time, b.Time)
		and a.Value == b.Value
end

function ColorSequenceKeypointMeta.__tostring(self: any): string
	return `{self.Time} {self.Value.R} {self.Value.G} {self.Value.B} 0`
end

Datatypes.ColorSequenceKeypoint = table.freeze(ColorSequenceKeypoint)

local NumberSequenceKeypoint = {}
local NumberSequenceKeypointMeta = { __index = NumberSequenceKeypoint, __type = "NumberSequenceKeypoint" }

function NumberSequenceKeypoint.new(time: number, value: number, envelope: number?): any
	return table.freeze(
		setmetatable({ Time = time, Value = value, Envelope = envelope or 0 }, NumberSequenceKeypointMeta)
	)
end

function NumberSequenceKeypointMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "NumberSequenceKeypoint"
		and customTypeof(b) == "NumberSequenceKeypoint"
		and near(a.Time, b.Time)
		and near(a.Value, b.Value)
		and near(a.Envelope, b.Envelope)
end

function NumberSequenceKeypointMeta.__tostring(self: any): string return `{self.Time} {self.Value} {self.Envelope}` end

Datatypes.NumberSequenceKeypoint = table.freeze(NumberSequenceKeypoint)

local function sequence(typeName: string, makeKeypoint: (time: number, value: any) -> any, singleType: string)
	local seq = {}
	local seqMeta = { __index = seq, __type = typeName }
	function seq.new(a: any, b: any?): any
		local keypoints = if type(a) == "table" and customTypeof(a) ~= singleType
			then table.clone(a)
			else { makeKeypoint(0, a), makeKeypoint(1, if b ~= nil then b else a) }
		return table.freeze(setmetatable({ Keypoints = table.freeze(keypoints) }, seqMeta))
	end
	function seqMeta.__eq(a: any, b: any): boolean
		if customTypeof(a) ~= typeName or customTypeof(b) ~= typeName or #a.Keypoints ~= #b.Keypoints then
			return false
		end
		for i = 1, #a.Keypoints do
			if a.Keypoints[i] ~= b.Keypoints[i] then return false end
		end
		return true
	end
	function seqMeta.__tostring(self: any): string
		local parts = table.create(#self.Keypoints)
		for i, kp in self.Keypoints do
			parts[i] = tostring(kp)
		end
		return table.concat(parts, " ")
	end
	return table.freeze(seq)
end

Datatypes.ColorSequence = sequence("ColorSequence", ColorSequenceKeypoint.new, "Color3")
Datatypes.NumberSequence = sequence("NumberSequence", NumberSequenceKeypoint.new, "number")

-- Enum ---------------------------------------------------------------------------------------------------------------

local EnumItemMeta = {
	__type = "EnumItem",
	__tostring = function(self: any): string return `Enum.{self._typeName}.{self.Name}` end,
	__index = {
		IsA = function(self: any, name: string): boolean return name == "EnumItem" or name == self._typeName end,
	},
}

local enumTypes: { [string]: any } = {}
local canonicalEnumType: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local mintedItems: { [any]: boolean } = {}

local function enumTypeEq(a: any, b: any): boolean return rawequal(canonicalEnumType[a] or a, canonicalEnumType[b] or b) end

local function getOrCreateEnumType(typeName: string): any
	local found = enumTypes[typeName]
	if found ~= nil then return found end
	local itemsByName: { [string]: any }, itemsByValue: { [number]: any }, list: { any } = {}, {}, {}
	local nextVal = 0
	local enumType: any = {}

	local function makeItem(itemName: string, value: number?): any
		if itemsByName[itemName] ~= nil then return itemsByName[itemName] end
		local val = if value ~= nil then value else nextVal
		nextVal = math.max(nextVal, val + 1)
		local item = table.freeze(
			setmetatable({ Name = itemName, Value = val, EnumType = enumType, _typeName = typeName }, EnumItemMeta)
		)
		itemsByName[itemName] = item
		itemsByValue[val] = itemsByValue[val] or item
		table.insert(list, item)
		return item
	end

	local generated = Generated.enum(typeName)
	if generated ~= nil then
		for _, entry in generated do
			makeItem(entry.Name, entry.Value)
		end
	end

	local function lookup(name: any): any
		local item = itemsByName[name]
		if item == nil and generated ~= nil and type(name) == "string" then
			local alias = Generated.enumItem(typeName, name)
			if alias ~= nil then item = itemsByName[alias.Name] end
		end
		return item
	end

	local function getEnumItems(): { any }
		if generated == nil then return table.clone(list) end
		local items = {}
		for _, item in list do
			if not mintedItems[item] then table.insert(items, item) end
		end
		return items
	end

	local function fromName(a: any, b: any?): any return lookup(if type(a) == "table" then b else a) end
	local function fromValue(a: any, b: any?): any return itemsByValue[if type(a) == "table" then b else a] end

	setmetatable(enumType, {
		__type = "Enum",
		__eq = enumTypeEq,
		__tostring = function(): string return typeName end,
		__index = function(_: any, key: string): any
			if key == "GetEnumItems" then
				return getEnumItems
			elseif key == "FromName" then
				return fromName
			elseif key == "FromValue" then
				return fromValue
			end
			local item = lookup(key)
			if item == nil then
				item = makeItem(key)
				if generated ~= nil then mintedItems[item] = true end
			end
			return item
		end,
	})

	enumTypes[typeName] = enumType
	return enumType
end

local function getEnums(): { any }
	local out = Generated.enumNames()
	local seen: { [string]: boolean } = {}
	for _, name in out do
		seen[name] = true
	end
	for name in enumTypes do
		if not seen[name] then table.insert(out, name) end
	end
	local types = {}
	for _, name in out do
		table.insert(types, getOrCreateEnumType(name))
	end
	return types
end

local EnumRoot: any = setmetatable({}, {
	__type = "Enums",
	__tostring = function(): string return "Enums" end,
	__index = function(_: any, key: string): any
		return if key == "GetEnums" then getEnums else getOrCreateEnumType(key)
	end,
})
Datatypes.Enum = EnumRoot

local strictEnumTypes: { [string]: any } = {}

local function strictEnumType(typeName: string, canonical: any): any
	local found = strictEnumTypes[typeName]
	if found ~= nil then return found end
	local proxy = {}
	canonicalEnumType[proxy] = canonical
	setmetatable(proxy, {
		__type = "Enum",
		__eq = enumTypeEq,
		__tostring = function(): string return typeName end,
		__index = function(_: any, key: string): any
			if key == "GetEnumItems" then
				return canonical.GetEnumItems
			elseif key == "FromName" or key == "FromValue" then
				local find = canonical[key]
				return function(...: any): any
					local item = find(...)
					return if mintedItems[item] then nil else item
				end
			end
			local item = if type(key) == "string" then canonical.FromName(key) else nil
			if item == nil or mintedItems[item] then
				error(`{tostring(key)} is not a valid member of Enum {typeName}`, 2)
			end
			return item
		end,
		__newindex = function(_: any, key: any) error(`{tostring(key)} cannot be assigned to`, 2) end,
	})
	strictEnumTypes[typeName] = proxy
	return proxy
end

local StrictEnumRoot: any = setmetatable({}, {
	__type = "Enums",
	__tostring = function(): string return "Enums" end,
	__index = function(_: any, key: string): any
		if key == "GetEnums" then
			return function(): { any }
				local out = {}
				for _, typeName in Generated.enumNames() do
					table.insert(out, strictEnumType(typeName, getOrCreateEnumType(typeName)))
				end
				return out
			end
		end
		if type(key) ~= "string" or Generated.enum(key) == nil then
			error(`{tostring(key)} is not a valid member of Enums`, 2)
		end
		return strictEnumType(key, getOrCreateEnumType(key))
	end,
	__newindex = function(_: any, key: any) error(`{tostring(key)} cannot be assigned to`, 2) end,
})

Datatypes.StrictEnum = StrictEnumRoot
function Datatypes.makeEnum(strict: boolean?): any return if strict then StrictEnumRoot else EnumRoot end

local FloatCurveKey = {}
local FloatCurveKeyMeta = { __index = FloatCurveKey, __type = "FloatCurveKey" }

function FloatCurveKey.new(time: number, value: number, interpolation: any?): any
	return table.freeze(setmetatable({
		Time = time,
		Value = value,
		Interpolation = interpolation or EnumRoot.KeyInterpolationMode.Cubic,
		LeftTangent = 0,
		RightTangent = 0,
	}, FloatCurveKeyMeta))
end

function FloatCurveKeyMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "FloatCurveKey"
		and customTypeof(b) == "FloatCurveKey"
		and near(a.Time, b.Time)
		and near(a.Value, b.Value)
		and a.Interpolation == b.Interpolation
end

function FloatCurveKeyMeta.__tostring(self: any): string return `{self.Time} {self.Value} {self.Interpolation.Name}` end

Datatypes.FloatCurveKey = table.freeze(FloatCurveKey)

-- Font & TweenInfo ---------------------------------------------------------------------------------------------------

local Font = {}
local FontMeta = { __index = Font, __type = "Font" }

function Font.new(family: string, weight: any?, style: any?): any
	local w, s = weight or EnumRoot.FontWeight.Regular, style or EnumRoot.FontStyle.Normal
	return table.freeze(setmetatable({
		Family = family,
		Weight = w,
		Style = s,
		Bold = (if type(w) == "table" and type(w.Value) == "number" then w.Value >= 600 else false),
	}, FontMeta))
end

function Font.fromEnum(fontEnum: any): any
	local name = if type(fontEnum) == "table" and fontEnum.Name then fontEnum.Name else tostring(fontEnum)
	return Font.new(`rbxasset://fonts/families/{if name == "Legacy" then "LegacyArial" else name}.json`)
end

function Font.fromName(name: string, weight: any?, style: any?): any
	return Font.new(`rbxasset://fonts/families/{name}.json`, weight, style)
end

function Font.fromId(id: number, weight: any?, style: any?): any return Font.new(`rbxassetid://{id}`, weight, style) end

function FontMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "Font"
		and customTypeof(b) == "Font"
		and a.Family == b.Family
		and a.Weight == b.Weight
		and a.Style == b.Style
end

function FontMeta.__tostring(self: any): string return `{self.Family}, {self.Weight.Name}, {self.Style.Name}` end

Datatypes.Font = table.freeze(Font)

local TweenInfo = {}
local TweenInfoMeta = { __index = TweenInfo, __type = "TweenInfo" }

function TweenInfo.new(
	time: number?,
	easingStyle: any?,
	easingDirection: any?,
	repeatCount: number?,
	reverses: boolean?,
	delayTime: number?
): any
	return table.freeze(setmetatable({
		Time = time or 1,
		EasingStyle = easingStyle or EnumRoot.EasingStyle.Quad,
		EasingDirection = easingDirection or EnumRoot.EasingDirection.Out,
		RepeatCount = repeatCount or 0,
		Reverses = reverses == true,
		DelayTime = delayTime or 0,
	}, TweenInfoMeta))
end

function TweenInfoMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "TweenInfo"
		and customTypeof(b) == "TweenInfo"
		and near(a.Time, b.Time)
		and a.EasingStyle == b.EasingStyle
		and a.EasingDirection == b.EasingDirection
		and a.RepeatCount == b.RepeatCount
		and a.Reverses == b.Reverses
		and near(a.DelayTime, b.DelayTime)
end

function TweenInfoMeta.__tostring(self: any): string
	return `{self.Time}, {self.EasingStyle.Name}, {self.EasingDirection.Name}, {self.RepeatCount}, {self.Reverses}, {self.DelayTime}`
end

Datatypes.TweenInfo = table.freeze(TweenInfo)

-- DateTime & Random --------------------------------------------------------------------------------------------------

local DateTime = {}
local DateTimeMeta = { __index = DateTime, __type = "DateTime" }

local function fromMillis(ms: number, clockFn: (() -> number)?): any
	local millis = math.floor(ms)
	return table.freeze(
		setmetatable(
			{ UnixTimestamp = math.floor(millis / 1000), UnixTimestampMillis = millis, _clock = clockFn },
			DateTimeMeta
		)
	)
end

function DateTime.fromUnixTimestamp(ts: number): any return fromMillis(ts * 1000) end

function DateTime.fromUnixTimestampMillis(ms: number): any return fromMillis(ms) end

function DateTime.now(): any return fromMillis(os.time() * 1000) end

-- Civil date (year, month, day) to days since 1970-01-01 UTC (Howard Hinnant's algorithm).
local function daysFromCivil(year: number, month: number, day: number): number
	local y = if month <= 2 then year - 1 else year
	local era = math.floor((if y >= 0 then y else y - 399) / 400)
	local yoe = y - era * 400
	local m = if month > 2 then month - 3 else month + 9
	local doy = math.floor((153 * m + 2) / 5) + day - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

function DateTime.fromUniversalTime(
	year: number?,
	month: number?,
	day: number?,
	hour: number?,
	minute: number?,
	second: number?,
	millisecond: number?
): any
	local days = daysFromCivil(year or 1970, month or 1, day or 1)
	local secs = days * 86400 + (hour or 0) * 3600 + (minute or 0) * 60 + (second or 0)
	return fromMillis(secs * 1000 + (millisecond or 0))
end

function DateTime.fromLocalTime(
	year: number?,
	month: number?,
	day: number?,
	hour: number?,
	minute: number?,
	second: number?,
	millisecond: number?
): any
	local target = daysFromCivil(year or 1970, month or 1, day or 1) * 86400
		+ (hour or 0) * 3600
		+ (minute or 0) * 60
		+ (second or 0)
	local lt: any = (os.date :: any)("*t", target)
	local offset = (daysFromCivil(lt.year, lt.month, lt.day) * 86400 + lt.hour * 3600 + lt.min * 60 + lt.sec) - target
	local ts = target - offset
	local lt2: any = (os.date :: any)("*t", ts)
	local offset2 = (daysFromCivil(lt2.year, lt2.month, lt2.day) * 86400 + lt2.hour * 3600 + lt2.min * 60 + lt2.sec)
		- ts
	return fromMillis((target - offset2) * 1000 + (millisecond or 0))
end

function DateTime.fromIsoDate(iso: string): any
	local y, m, d, h, min, s, frac = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)%.?(%d*)")
	assert(y and m and d and h and min and s, `DateTime.fromIsoDate: invalid ISO date "{iso}"`)
	local ms = if frac ~= nil and #frac > 0 then math.floor((tonumber(string.sub(frac .. "000", 1, 3)) or 0)) else 0
	return DateTime.fromUniversalTime(
		tonumber(y),
		tonumber(m),
		tonumber(d),
		tonumber(h),
		tonumber(min),
		tonumber(s),
		ms
	)
end

function DateTime.ToIsoDate(self: any): string return (os.date :: any)("!%Y-%m-%dT%H:%M:%SZ", self.UnixTimestamp) end

function DateTime.ToUniversalTime(self: any): { [string]: number }
	local t: any = (os.date :: any)("!*t", self.UnixTimestamp)
	return {
		Year = t.year,
		Month = t.month,
		Day = t.day,
		Hour = t.hour,
		Minute = t.min,
		Second = t.sec,
		Millisecond = self.UnixTimestampMillis % 1000,
	}
end

function DateTime.ToLocalTime(self: any): { [string]: number }
	local t: any = (os.date :: any)("*t", self.UnixTimestamp)
	return {
		Year = t.year,
		Month = t.month,
		Day = t.day,
		Hour = t.hour,
		Minute = t.min,
		Second = t.sec,
		Millisecond = self.UnixTimestampMillis % 1000,
	}
end

function DateTime.FormatUniversalTime(self: any, _format: string?, _locale: string?): string
	return (os.date :: any)("!%Y-%m-%d %H:%M:%S", self.UnixTimestamp)
end

function DateTime.FormatLocalTime(self: any, _format: string?, _locale: string?): string
	return (os.date :: any)("%Y-%m-%d %H:%M:%S", self.UnixTimestamp)
end

function DateTimeMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "DateTime"
		and customTypeof(b) == "DateTime"
		and a.UnixTimestampMillis == b.UnixTimestampMillis
end

function DateTimeMeta.__tostring(self: any): string return tostring(self.UnixTimestampMillis) end

Datatypes.DateTime = table.freeze(DateTime)

function Datatypes.makeDateTime(unixClock: () -> number): any
	return table.freeze(setmetatable({
		now = function(): any return fromMillis(unixClock() * 1000) end,
	}, { __index = DateTime }))
end

local RandomLib = {}
local RandomMeta = {
	__index = RandomLib,
	__type = "Random",
	__tostring = function() return "Random" end,
}

function RandomLib.new(seed: number?): any
	local state = bit32.bxor(math.floor(seed or 1), 0x9E3779B9)
	return setmetatable({ _state = if state == 0 then 0x6D2B79F5 else state }, RandomMeta)
end

local function stepRng(self: any): number
	local x = Rng.xorshift32(self._state)
	self._state = x
	return x
end

function RandomLib.NextNumber(self: any, min: number?, max: number?): number
	local u = stepRng(self) / 4294967296
	return if min ~= nil and max ~= nil then min + u * (max - min) else u
end

function RandomLib.NextInteger(self: any, min: number, max: number): number
	return if max <= min then min else min + (stepRng(self) % ((max - min) + 1))
end

function RandomLib.NextUnitVector(self: any): any
	local theta, z = self:NextNumber(0, math.pi * 2), self:NextNumber(-1, 1)
	local r = math.sqrt(math.max(0, 1 - z * z))
	return Vector3.new(r * math.cos(theta), r * math.sin(theta), z)
end

function RandomLib.Shuffle(self: any, tbl: { any })
	for i = #tbl, 2, -1 do
		local j = self:NextInteger(1, i)
		tbl[i], tbl[j] = tbl[j], tbl[i]
	end
end

function RandomLib.Clone(self: any): any return setmetatable({ _state = self._state }, RandomMeta) end

Datatypes.Random = table.freeze(RandomLib)

-- Shared helpers & spatial datatypes ---------------------------------------------------------------------------------

local function enumItemName(value: any): string? return if customTypeof(value) == "EnumItem" then value.Name else nil end

local function readOnlyError(typeName: string): (any, any, any) -> ()
	return function(_: any, key: any) error(`{tostring(key)} cannot be assigned to on {typeName}`, 2) end
end

local Ray: any = {}
local RayMeta: any = { __type = "Ray" }

function Ray.new(origin: any?, direction: any?): any
	return table.freeze(
		setmetatable({ Origin = origin or Vector3.zero, Direction = direction or Vector3.zero }, RayMeta)
	)
end

function Ray.ClosestPoint(self: any, point: any): any
	local dir = self.Direction
	local lenSq = dir:Dot(dir)
	return if lenSq == 0 then self.Origin else self.Origin + dir * math.max(0, (point - self.Origin):Dot(dir) / lenSq)
end

function Ray.Distance(self: any, point: any): number return (point - self:ClosestPoint(point)).Magnitude end

function RayMeta.__index(self: any, key: string): any
	return if key == "Unit" then Ray.new(self.Origin, self.Direction.Unit) else Ray[key]
end
function RayMeta.__eq(a: any, b: any): boolean
	return customTypeof(a) == "Ray" and customTypeof(b) == "Ray" and a.Origin == b.Origin and a.Direction == b.Direction
end
function RayMeta.__tostring(self: any): string return `\{{self.Origin}\}, \{{self.Direction}\}` end

Datatypes.Ray = table.freeze(Ray)

local function filterParams(typeName: string, defaults: () -> { [string]: any })
	local methods: any = {}
	local meta: any = {
		__type = typeName,
		__index = methods,
		__newindex = function(_: any, key: any) error(`{tostring(key)} is not a valid member of {typeName}`, 2) end,
		__tostring = function(self: any): string
			return `{typeName}\{FilterType = {self.FilterType}, #FilterDescendantsInstances = {#self.FilterDescendantsInstances}\}`
		end,
	}
	function methods.AddToFilter(self: any, instances: any)
		local list = table.clone(self.FilterDescendantsInstances)
		if customTypeof(instances) == "Instance" then
			table.insert(list, instances)
		else
			for _, inst in instances do
				table.insert(list, inst)
			end
		end
		rawset(self, "FilterDescendantsInstances", list)
	end
	return table.freeze({
		new = function(init: { [string]: any }?): any
			local self: any = setmetatable(defaults(), meta)
			if init ~= nil then
				for key, value in init do
					if rawget(self, key) == nil then error(`{tostring(key)} is not a valid member of {typeName}`, 2) end
					rawset(self, key, value)
				end
			end
			return self
		end,
	})
end

Datatypes.RaycastParams = filterParams(
	"RaycastParams",
	function()
		return {
			FilterDescendantsInstances = {},
			FilterType = EnumRoot.RaycastFilterType.Exclude,
			IgnoreWater = false,
			CollisionGroup = "Default",
			RespectCanCollide = false,
			BruteForceAllSlow = false,
		}
	end
)

Datatypes.OverlapParams = filterParams(
	"OverlapParams",
	function()
		return {
			FilterDescendantsInstances = {},
			FilterType = EnumRoot.RaycastFilterType.Exclude,
			MaxParts = 0,
			CollisionGroup = "Default",
			RespectCanCollide = false,
			BruteForceAllSlow = false,
		}
	end
)

local RaycastResultMeta: any = {
	__type = "RaycastResult",
	__tostring = function(self: any): string
		local name = if self.Instance ~= nil then tostring(self.Instance) else "nil"
		return `RaycastResult\{{name} @ {self.Position}; {self.Normal}; {self.Material}\}`
	end,
	__eq = function(a: any, b: any): boolean
		return customTypeof(a) == "RaycastResult"
			and customTypeof(b) == "RaycastResult"
			and rawequal(a.Instance, b.Instance)
			and a.Position == b.Position
			and a.Normal == b.Normal
			and a.Distance == b.Distance
			and a.Material == b.Material
	end,
}

function Datatypes.newRaycastResult(
	instance: any,
	position: any,
	normal: any,
	distance: number?,
	material: any?
): any
	return table.freeze(setmetatable({
		Instance = instance,
		Position = position,
		Normal = normal,
		Distance = distance or 0,
		Material = material or EnumRoot.Material.Plastic,
	}, RaycastResultMeta))
end

local MATERIAL_PHYSICS: { [string]: { number } } = {
	Plastic = { 0.7, 0.3, 0.5 },
	SmoothPlastic = { 0.7, 0.2, 0.5 },
	Neon = { 0.7, 0.3, 0.2 },
	Wood = { 0.35, 0.48, 0.2 },
	WoodPlanks = { 0.35, 0.48, 0.2 },
	Marble = { 2.563, 0.2, 0.17 },
	Basalt = { 2.691, 0.7, 0.15 },
	Slate = { 2.691, 0.4, 0.2 },
	CrackedLava = { 2.691, 0.65, 0.15 },
	Concrete = { 2.403, 0.7, 0.2 },
	Limestone = { 2.691, 0.5, 0.15 },
	Granite = { 2.691, 0.4, 0.2 },
	Pavement = { 2.691, 0.5, 0.17 },
	Brick = { 1.92, 0.8, 0.15 },
	Pebble = { 2.403, 0.4, 0.17 },
	Cobblestone = { 2.691, 0.5, 0.17 },
	Rock = { 2.691, 0.5, 0.17 },
	Sandstone = { 2.691, 0.5, 0.15 },
	CorrodedMetal = { 7.85, 0.7, 0.2 },
	DiamondPlate = { 7.85, 0.35, 0.25 },
	Foil = { 2.7, 0.4, 0.25 },
	Metal = { 7.85, 0.4, 0.25 },
	Grass = { 0.9, 0.4, 0.1 },
	LeafyGrass = { 0.9, 0.4, 0.1 },
	Sand = { 1.6, 0.5, 0.05 },
	Fabric = { 0.7, 0.35, 0.05 },
	Snow = { 0.9, 0.3, 0.03 },
	Mud = { 0.9, 0.3, 0.07 },
	Ground = { 0.9, 0.45, 0.1 },
	Asphalt = { 2.36, 0.8, 0.2 },
	Salt = { 2.16, 0.5, 0.05 },
	Ice = { 0.919, 0.02, 0.15 },
	Glacier = { 0.919, 0.05, 0.15 },
	Glass = { 2.4, 0.25, 0.2 },
	ForceField = { 2.4, 0.25, 0.2 },
	Air = { 0.01, 0.01, 0.01 },
	Water = { 1, 0.3, 0.01 },
}

local PhysicalProperties: any = {}
local PhysicalPropertiesMeta: any = {
	__type = "PhysicalProperties",
	__index = PhysicalProperties,
	__eq = function(a: any, b: any): boolean
		return customTypeof(a) == "PhysicalProperties"
			and customTypeof(b) == "PhysicalProperties"
			and a.Density == b.Density
			and a.Friction == b.Friction
			and a.Elasticity == b.Elasticity
			and a.FrictionWeight == b.FrictionWeight
			and a.ElasticityWeight == b.ElasticityWeight
	end,
	__tostring = function(self: any): string
		return `{self.Density}, {self.Friction}, {self.Elasticity}, {self.FrictionWeight}, {self.ElasticityWeight}`
	end,
}

function PhysicalProperties.new(
	density: any,
	friction: number?,
	elasticity: number?,
	frictionWeight: number?,
	elasticityWeight: number?
): any
	local d, f, e, fw, ew
	local materialName = enumItemName(density)
	if materialName ~= nil then
		local row = MATERIAL_PHYSICS[materialName] or MATERIAL_PHYSICS.Plastic
		d, f, e, fw, ew = row[1], row[2], row[3], 1, 1
	else
		if type(density) ~= "number" or type(friction) ~= "number" or type(elasticity) ~= "number" then
			error("PhysicalProperties.new expects a Material or (density, friction, elasticity)", 2)
		end
		d, f, e, fw, ew = density, friction, elasticity, frictionWeight or 1, elasticityWeight or 1
	end
	return table.freeze(setmetatable({
		Density = math.max(d, 0.01),
		Friction = math.clamp(f, 0, 2),
		Elasticity = math.clamp(e, 0, 1),
		FrictionWeight = math.clamp(fw, 0, 100),
		ElasticityWeight = math.clamp(ew, 0, 100),
	}, PhysicalPropertiesMeta))
end

Datatypes.PhysicalProperties = table.freeze(PhysicalProperties)

local CatalogSearchParamsMeta: any = {
	__type = "CatalogSearchParams",
	__newindex = function(_: any, key: any) error(`{tostring(key)} is not a valid member of CatalogSearchParams`, 2) end,
	__tostring = function(self: any): string
		return `CatalogSearchParams\{SearchKeyword = "{self.SearchKeyword}", Limit = {self.Limit}\}`
	end,
}

Datatypes.CatalogSearchParams = table.freeze({
	new = function(): any
		return setmetatable({
			SearchKeyword = "",
			MinPrice = 0,
			MaxPrice = 2147483647,
			SortType = EnumRoot.CatalogSortType.Relevance,
			SortAggregation = EnumRoot.CatalogSortAggregation.AllTime,
			CategoryFilter = EnumRoot.CatalogCategoryFilter.None,
			SalesTypeFilter = EnumRoot.SalesTypeFilter.All,
			BundleTypes = {},
			AssetTypes = {},
			IncludeOffSale = false,
			CreatorName = "",
			CreatorType = EnumRoot.CreatorTypeFilter.All,
			CreatorId = 0,
			Limit = 30,
		}, CatalogSearchParamsMeta)
	end,
})

local Region3: any = {}
local Region3Meta: any = {
	__type = "Region3",
	__index = Region3,
	__newindex = readOnlyError("Region3"),
	__eq = function(a: any, b: any): boolean
		return customTypeof(a) == "Region3" and customTypeof(b) == "Region3" and a._min == b._min and a._max == b._max
	end,
	__tostring = function(self: any): string return `{self.CFrame}; {self.Size}` end,
}

local function makeRegion3(minV: any, maxV: any): any
	local lo, hi = minV:Min(maxV), minV:Max(maxV)
	return table.freeze(
		setmetatable({ CFrame = CFrame.new((lo + hi) / 2), Size = hi - lo, _min = lo, _max = hi }, Region3Meta)
	)
end

function Region3.new(minV: any?, maxV: any?): any return makeRegion3(minV or Vector3.zero, maxV or Vector3.zero) end

function Region3.ExpandToGrid(self: any, resolution: number): any
	local lo, hi = self._min, self._max
	local function snap(v: any, fn: (number) -> number): any
		return Vector3.new(
			fn(v.X / resolution) * resolution,
			fn(v.Y / resolution) * resolution,
			fn(v.Z / resolution) * resolution
		)
	end
	return makeRegion3(snap(lo, math.floor), snap(hi, math.ceil))
end

Datatypes.Region3 = table.freeze(Region3)

-- Vector2int16 / Vector3int16 / Axes / Faces / PathWaypoint ----------------------------------------------------------

local function toInt16(n: number?): number
	local v = n or 0
	if v ~= v then return 0 end
	v = if v < 0 then math.ceil(v) else math.floor(v)
	return ((v + 32768) % 65536) - 32768
end

local function int16Operand(v: any, i: number): number
	return if type(v) == "number" then v elseif i == 1 then v.X elseif i == 2 then v.Y else v.Z
end

local Vector2int16: any = {}
local function vec2int16BinOp(a: any, b: any, op: (number, number) -> number): any
	return Vector2int16.new(op(int16Operand(a, 1), int16Operand(b, 1)), op(int16Operand(a, 2), int16Operand(b, 2)))
end

local Vector2int16Meta: any = {
	__type = "Vector2int16",
	__index = Vector2int16,
	__add = function(a: any, b: any): any return Vector2int16.new(a.X + b.X, a.Y + b.Y) end,
	__sub = function(a: any, b: any): any return Vector2int16.new(a.X - b.X, a.Y - b.Y) end,
	__mul = function(a: any, b: any): any return vec2int16BinOp(a, b, mulNum) end,
	__div = function(a: any, b: any): any return vec2int16BinOp(a, b, divNum) end,
	__unm = function(a: any): any return Vector2int16.new(-a.X, -a.Y) end,
	__eq = function(a: any, b: any): boolean
		return customTypeof(a) == "Vector2int16" and customTypeof(b) == "Vector2int16" and a.X == b.X and a.Y == b.Y
	end,
	__tostring = function(self: any): string return `{self.X}, {self.Y}` end,
}

function Vector2int16.new(x: number?, y: number?): any
	return table.freeze(setmetatable({ X = toInt16(x), Y = toInt16(y) }, Vector2int16Meta))
end
Datatypes.Vector2int16 = table.freeze(Vector2int16)

local Vector3int16: any = {}
local function vec3int16BinOp(a: any, b: any, op: (number, number) -> number): any
	return Vector3int16.new(
		op(int16Operand(a, 1), int16Operand(b, 1)),
		op(int16Operand(a, 2), int16Operand(b, 2)),
		op(int16Operand(a, 3), int16Operand(b, 3))
	)
end

local Vector3int16Meta: any = {
	__type = "Vector3int16",
	__index = Vector3int16,
	__add = function(a: any, b: any): any return Vector3int16.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
	__sub = function(a: any, b: any): any return Vector3int16.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
	__mul = function(a: any, b: any): any return vec3int16BinOp(a, b, mulNum) end,
	__div = function(a: any, b: any): any return vec3int16BinOp(a, b, divNum) end,
	__unm = function(a: any): any return Vector3int16.new(-a.X, -a.Y, -a.Z) end,
	__eq = function(a: any, b: any): boolean
		return customTypeof(a) == "Vector3int16"
			and customTypeof(b) == "Vector3int16"
			and a.X == b.X
			and a.Y == b.Y
			and a.Z == b.Z
	end,
	__tostring = function(self: any): string return `{self.X}, {self.Y}, {self.Z}` end,
}

function Vector3int16.new(x: number?, y: number?, z: number?): any
	return table.freeze(setmetatable({ X = toInt16(x), Y = toInt16(y), Z = toInt16(z) }, Vector3int16Meta))
end
Datatypes.Vector3int16 = table.freeze(Vector3int16)

local NORMAL_AXIS: { [string]: string } = { Right = "X", Left = "X", Top = "Y", Bottom = "Y", Back = "Z", Front = "Z" }
local FACE_ORDER = { "Right", "Top", "Back", "Left", "Bottom", "Front" }

local AxesMeta: any = {
	__type = "Axes",
	__newindex = readOnlyError("Axes"),
	__eq = function(a: any, b: any): boolean
		return customTypeof(a) == "Axes" and customTypeof(b) == "Axes" and a.X == b.X and a.Y == b.Y and a.Z == b.Z
	end,
	__tostring = function(self: any): string
		local parts = {}
		for _, axis in { "X", "Y", "Z" } do
			if self[axis] then table.insert(parts, axis) end
		end
		return table.concat(parts, ", ")
	end,
}

Datatypes.Axes = table.freeze({
	new = function(...: any): any
		local set = { X = false, Y = false, Z = false }
		for i = 1, select("#", ...) do
			local item = select(i, ...)
			local name = enumItemName(item)
			if name ~= nil and item.EnumType == EnumRoot.Axis then
				set[name] = true
			elseif name ~= nil and NORMAL_AXIS[name] ~= nil and item.EnumType == EnumRoot.NormalId then
				set[NORMAL_AXIS[name]] = true
			else
				error(`Axes.new expects Enum.Axis or Enum.NormalId items, got {tostring(item)}`, 2)
			end
		end
		local fields: { [string]: boolean } = { X = set.X, Y = set.Y, Z = set.Z }
		for face, axis in NORMAL_AXIS do
			fields[face] = set[axis]
		end
		return table.freeze(setmetatable(fields, AxesMeta))
	end,
})

local FacesMeta: any = {
	__type = "Faces",
	__newindex = readOnlyError("Faces"),
	__eq = function(a: any, b: any): boolean
		if customTypeof(a) ~= "Faces" or customTypeof(b) ~= "Faces" then return false end
		for _, face in FACE_ORDER do
			if a[face] ~= b[face] then return false end
		end
		return true
	end,
	__tostring = function(self: any): string
		local parts = {}
		for _, face in FACE_ORDER do
			if self[face] then table.insert(parts, face) end
		end
		return table.concat(parts, ", ")
	end,
}

Datatypes.Faces = table.freeze({
	new = function(...: any): any
		local fields: { [string]: boolean } =
			{ Right = false, Top = false, Back = false, Left = false, Bottom = false, Front = false }
		for i = 1, select("#", ...) do
			local item = select(i, ...)
			local name = enumItemName(item)
			if name == nil or NORMAL_AXIS[name] == nil or item.EnumType ~= EnumRoot.NormalId then
				error(`Faces.new expects Enum.NormalId items, got {tostring(item)}`, 2)
			end
			fields[name] = true
		end
		return table.freeze(setmetatable(fields, FacesMeta))
	end,
})

local PathWaypointMeta: any = {
	__type = "PathWaypoint",
	__newindex = readOnlyError("PathWaypoint"),
	__eq = function(a: any, b: any): boolean
		return customTypeof(a) == "PathWaypoint"
			and customTypeof(b) == "PathWaypoint"
			and a.Position == b.Position
			and a.Action == b.Action
			and a.Label == b.Label
	end,
	__tostring = function(self: any): string return `\{{self.Position}\}, {self.Action}, {self.Label}` end,
}

Datatypes.PathWaypoint = table.freeze({
	new = function(position: any?, action: any?, label: string?): any
		return table.freeze(setmetatable({
			Position = position or Vector3.zero,
			Action = action or EnumRoot.PathWaypointAction.Walk,
			Label = label or "",
		}, PathWaypointMeta))
	end,
})

local installedEnvs: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local IS_ROBLOX = (game :: any) ~= nil

local function populateEnv(env: { [string]: any }, includeType: boolean)
	if table.isfrozen(env) then return end
	for _, name in DATATYPE_GLOBALS do
		if rawget(env, name) == nil then rawset(env, name, Datatypes[name]) end
	end
	if rawget(env, "DateTime") == nil then rawset(env, "DateTime", Datatypes.DateTime) end
	rawset(env, "typeof", customTypeof)
	if includeType then rawset(env, "type", customType) end
	local curUtf8 = rawget(env, "utf8")
	if nativeType(curUtf8) ~= "table" or curUtf8.graphemes == nil then rawset(env, "utf8", customUtf8) end
end

function Datatypes.installGlobals(target: { [string]: any }?): { [string]: any }
	local env: any = target or (if getfenv ~= nil then (getfenv :: any)(0) else nil)
	if nativeType(env) ~= "table" or table.isfrozen(env) then return env end
	if target == nil and installedEnvs[env] then return env end
	populateEnv(env, target ~= nil)
	if target == nil then installedEnvs[env] = true end
	return env
end

function Datatypes.installCallerGlobals(fn: any?)
	if IS_ROBLOX or getfenv == nil then return end
	if nativeType(fn) == "function" then
		local src = debug.info(fn :: (...any) -> ...any, "s")
		if src ~= nil and src ~= "[C]" then
			local fenv = (getfenv :: any)(fn)
			if nativeType(fenv) == "table" and not installedEnvs[fenv] then
				populateEnv(fenv, false)
				installedEnvs[fenv] = true
			end
		end
	end
	for level = 2, 6 do
		local src, f = debug.info(level, "sf")
		if src == nil then break end
		if src ~= "[C]" and f ~= nil then
			local cenv = (getfenv :: any)(f)
			if nativeType(cenv) == "table" and not installedEnvs[cenv] then
				populateEnv(cenv, false)
				installedEnvs[cenv] = true
			end
		end
	end
end

return table.freeze(Datatypes) :: any
