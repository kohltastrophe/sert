--!strict
-- Property-driven boundary and adversarial payload fuzzer for Roblox remote handlers (`sert.roblox.fuzzRemote`).

local Datatypes = require("../engine/datatypes")
local Env = require("../env")
local assert = require("../core/assert")
local format = require("../core/format")
local prop = require("../prop")
local registry = require("../core/registry")
local util = require("../core/util")

export type RemoteFuzzSpec = {
	name: string?,
	handler: (player: any, ...any) -> ...any,
	makePlayer: (() -> any)?,
	checkState: ((player: any) -> ())?,
	validGen: any?,
	maxArgs: number?,
	allowError: boolean?,
	allowYield: boolean?,
	runs: number?,
	seed: number?,
	replay: number?,
	target: registry.Target?,
}

local ADVERSARIAL_NUMBERS: { number } = {
	0 / 0,
	math.huge,
	-math.huge,
	-0.0,
	0.0,
	1,
	-1,
	2147483647,
	-2147483648,
	9007199254740991,
	-9007199254740991,
	9007199254740992,
	1e-308,
	-1e-308,
	1.7976931348623157e308,
}

local ADVERSARIAL_STRINGS: { string } = {
	"",
	"\0",
	"\0\0admin\0",
	"\xFF\xFE\xFD",
	"\xC3\x28",
	"%s%s%d%q%%",
	"../ServerStorage/Secret",
	"NaN",
	"inf",
	"true",
	"null",
	string.rep("A", 4096),
}

local function makeDefaultPlayer(): any
	return {
		ClassName = "Player",
		UserId = 1001,
		Name = "FuzzPlayer",
		DisplayName = "FuzzPlayer",
		AccountAge = 0,
		IsA = function(_self: any, cls: string): boolean return cls == "Player" or cls == "Instance" end,
	}
end

local function makeSpoofedInstance(kind: number): any
	if kind == 1 then
		-- Plain table spoofing Instance fields/methods to defeat naive `arg.ClassName == "Part"` or `arg:IsA(...)` checks!
		return {
			ClassName = "Part",
			Name = "SpoofedPart",
			UserId = 1,
			Parent = workspace,
			IsA = function(): boolean return true end,
			FindFirstChild = function(): any return nil end,
		}
	elseif kind == 2 then
		local realGame: any = if typeof(game) == "Instance" then game else nil
		if realGame ~= nil then return Instance.new("Folder") end
		local scratch = Env.new()
		local f = scratch.Instance.new("Folder")
		return f
	else
		-- Table with throwing `__index` metatable (simulating hostile/unexpected table structure).
		return setmetatable({ ClassName = "Player" }, {
			__tostring = function(): string return "Player" end,
		})
	end
end

local function drawAdversarialValue(g: any, depth: number): any
	if depth >= 4 then
		local leafKind = g:int(1, 5)
		if leafKind == 1 then return nil end
		if leafKind == 2 then return g:bool() end
		if leafKind == 3 then return g:pick(ADVERSARIAL_NUMBERS) end
		if leafKind == 4 then return g:pick(ADVERSARIAL_STRINGS) end
		return buffer.create(0)
	end

	local category = g:int(1, 11)
	if category == 1 then
		return nil
	elseif category == 2 then
		return g:bool()
	elseif category == 3 then
		return g:pick(ADVERSARIAL_NUMBERS)
	elseif category == 4 then
		return g:pick(ADVERSARIAL_STRINGS)
	elseif category == 5 then
		-- Boundary and oversized buffers.
		local len = g:pick({ 0, 1, 1024, 16384 })
		local b = buffer.create(len)
		if len > 0 then buffer.fill(b, 0, g:int(0, 255), len) end
		return b
	elseif category == 6 then
		-- Deep nested chain table.
		local chainDepth = g:pick({ 8, 24, 68 })
		local root: { [any]: any } = {}
		local cur = root
		for i = 1, chainDepth do
			local child: { [any]: any } = { level = i }
			cur.next = child
			cur[1] = child
			cur = child
		end
		return root
	elseif category == 7 then
		-- Cyclic self-referential table.
		local cyc: { [any]: any } = { id = g:pick(ADVERSARIAL_NUMBERS) }
		cyc.self = cyc
		cyc[1] = cyc
		return cyc
	elseif category == 8 then
		-- Sparse array with `nil` holes + mixed string/NaN/negative keys.
		local mixed: { [any]: any } = {
			[1] = drawAdversarialValue(g, depth + 1),
			[5] = drawAdversarialValue(g, depth + 1),
			[10000] = "sparse_tail",
			[-1] = "neg_index",
			amount = g:pick(ADVERSARIAL_NUMBERS),
			count = g:pick(ADVERSARIAL_NUMBERS),
			id = g:pick(ADVERSARIAL_STRINGS),
		}
		return mixed
	elseif category == 9 then
		-- Spoofed or unparented wrong-class Instance.
		return makeSpoofedInstance(g:int(1, 3))
	elseif category == 10 then
		-- Non-finite / extreme Roblox datatypes (`Vector3`, `CFrame`, `UDim2`, `Color3`).
		local dtKind = g:int(1, 4)
		local V3 = if typeof(Vector3) == "table" then Vector3 else Datatypes.Vector3
		local CF = if typeof(CFrame) == "table" then CFrame else Datatypes.CFrame
		local UD2 = if typeof(UDim2) == "table" then UDim2 else Datatypes.UDim2
		local C3 = if typeof(Color3) == "table" then Color3 else Datatypes.Color3
		if dtKind == 1 then
			return V3.new(g:pick(ADVERSARIAL_NUMBERS), g:pick(ADVERSARIAL_NUMBERS), g:pick(ADVERSARIAL_NUMBERS))
		elseif dtKind == 2 then
			return CF.new(g:pick(ADVERSARIAL_NUMBERS), 0, 0)
		elseif dtKind == 3 then
			return UD2.new(g:pick(ADVERSARIAL_NUMBERS), 0, g:pick(ADVERSARIAL_NUMBERS), 0)
		else
			return C3.new(g:pick(ADVERSARIAL_NUMBERS), -5, 999)
		end
	else
		-- Adversarial dictionary mimicking common remote payload keys (`action`, `itemId`, `quantity`, `price`, `target`).
		local dict: { [string]: any } = {}
		local keys = { "action", "type", "id", "itemId", "quantity", "amount", "price", "position", "target" }
		local count = g:int(0, 5)
		for _ = 1, count do
			local k = g:pick(keys)
			dict[k] = drawAdversarialValue(g, depth + 1)
		end
		return dict
	end
end

local function invokeHandler(
	spec: RemoteFuzzSpec,
	player: any,
	args: { [number]: any, n: number },
	expectValid: boolean
)
	local co = coroutine.create(spec.handler)
	local ok, resOrErr = coroutine.resume(co, player, table.unpack(args, 1, args.n))
	local status = coroutine.status(co)

	if status == "suspended" and not spec.allowYield then
		coroutine.close(co)
		local formattedArgs: { string } = {}
		for i = 1, args.n do
			table.insert(formattedArgs, format.repr(args[i], 3))
		end
		assert.fail(`fuzzRemote: handler yielded on payload ({table.concat(formattedArgs, ", ")})`)
	end

	if not ok then
		if expectValid or not spec.allowError then
			local formattedArgs: { string } = {}
			for i = 1, args.n do
				table.insert(formattedArgs, format.repr(args[i], 3))
			end
			assert.fail(
				`fuzzRemote: handler threw on {if expectValid then "valid" else "adversarial"} payload `
					.. `({table.concat(formattedArgs, ", ")}): {format.errorText(resOrErr)}`
			)
		end
	end

	if spec.checkState ~= nil then spec.checkState(player) end
end

local function executeFuzzTrial(spec: RemoteFuzzSpec, g: any)
	local player = if spec.makePlayer ~= nil then spec.makePlayer() else makeDefaultPlayer()
	local maxArgs = spec.maxArgs or 5

	if spec.validGen ~= nil and g:bool(0.25) then
		local validVal = g:draw(spec.validGen)
		if g:bool(0.5) and type(validVal) == "table" and util.doubleTag(validVal) == nil then
			-- Mutate one field of a valid payload into an adversarial value to fuzz near-miss payloads!
			local corrupted = util.copy(validVal)
			local keys = util.sortedKeys(corrupted)
			if #keys > 0 then
				local victimKey = g:pick(keys)
				corrupted[victimKey] = drawAdversarialValue(g, 1)
			else
				corrupted[1] = drawAdversarialValue(g, 1)
			end
			invokeHandler(spec, player, { [1] = corrupted, n = 1 }, false)
		else
			invokeHandler(spec, player, { [1] = validVal, n = 1 }, true)
		end
		return
	end

	-- Adversarial arity: 0 args, `nil` interior holes, or 1..maxArgs mixed adversarial values.
	local arityMode = g:int(1, 4)
	if arityMode == 1 then
		invokeHandler(spec, player, { n = 0 }, false)
	elseif arityMode == 2 then
		local holeCount = g:int(2, math.max(2, maxArgs))
		local packed: { [number]: any, n: number } = { n = holeCount }
		packed[holeCount] = drawAdversarialValue(g, 0)
		invokeHandler(spec, player, packed, false)
	else
		local n = g:int(1, maxArgs)
		local packed: { [number]: any, n: number } = { n = n }
		for i = 1, n do
			packed[i] = drawAdversarialValue(g, 0)
		end
		invokeHandler(spec, player, packed, false)
	end
end

local function normalizeSpec(
	first: string | ((player: any, ...any) -> ...any) | RemoteFuzzSpec,
	second: (((player: any, ...any) -> ...any) | RemoteFuzzSpec)?,
	third: RemoteFuzzSpec?
): (string?, RemoteFuzzSpec)
	if type(first) == "string" then
		if type(second) == "function" then
			local base: RemoteFuzzSpec = if type(third) == "table" then table.clone(third) else {} :: any
			base.name = first
			base.handler = second
			return first, base
		elseif type(second) == "table" then
			local base = table.clone(second)
			base.name = first
			return first, base
		end
		error("fuzzRemote: expected handler function or RemoteFuzzSpec table as second argument", util.outside())
	elseif type(first) == "function" then
		local base: RemoteFuzzSpec = if type(second) == "table"
			then table.clone(second :: RemoteFuzzSpec)
			else {} :: any
		base.handler = first
		return base.name, base
	elseif type(first) == "table" then
		local base = table.clone(first)
		return base.name, base
	end
	error("fuzzRemote: expected (name, handler, opts?) or (handler, opts?) or (spec)", util.outside())
end

local fuzz = {}

--- Fuzzes a remote handler against adversarial boundary payloads (`NaN`, `±inf`, `-0.0`, deep/cyclic tables,
--- spoofed `Instance`s, oversized buffers, `nil` holes, wrong arity, and type confusion).
--- Registers a property test when called at top-level/describe with a `name`, or executes inline inside a running test.
function fuzz.fuzzRemote(
	first: string | ((player: any, ...any) -> ...any) | RemoteFuzzSpec,
	second: (((player: any, ...any) -> ...any) | RemoteFuzzSpec)?,
	third: RemoteFuzzSpec?
)
	local name, spec = normalizeSpec(first, second, third)
	if type(spec.handler) ~= "function" then error("fuzzRemote: 'handler' must be a function", util.outside()) end

	local propOpts: any = {
		runs = spec.runs or 100,
		seed = spec.seed,
	}

	if name ~= nil and not registry.inline() then
		local registrar: any = if spec.target == "server"
			then prop.server
			elseif spec.target == "roblox" then prop.roblox
			elseif spec.target == "client" then prop.client
			else prop
		registrar(name, function(g: any) executeFuzzTrial(spec, g) end, propOpts)
		return
	end

	local runOpts: any = if registry.currentOptions() ~= nil then table.clone(registry.currentOptions() :: any) else {}
	if spec.replay ~= nil then runOpts.replay = spec.replay end
	local label = name or "fuzzRemote"
	local res = prop.run(label, function(g: any) executeFuzzTrial(spec, g) end, propOpts, runOpts, true, label)

	if not res.ok then error((res :: any).report or res.message or "fuzzRemote failed", util.outside()) end
end

return fuzz
