--!strict
--[=[
	Prototype-backed virtual `Instance` engine for `sert.env` and `sert.sim`.
	All instances share `InstanceMeta` (`__type = "Instance"`) and class-level method tables,
	lazily allocating `_children`, `_attributes`, `_tags`, `_propSignals`, `_attrSignals`, and `_signals`.
	Defaults to strict schema validation (`strict = true`).
]=]

local Util = require("../core/util")
local Datatypes = require("./datatypes")
local Generated = require("./generated")
local Serialize = require("./serialize")
local Signal = require("./signal")

-- The `Instance:QueryDescendants` selector grammar, for the Instance double.
type SelectorAccess = {
	isA: (inst: any, className: string) -> boolean,
	name: (inst: any) -> string,
	hasTag: (inst: any, tag: string) -> boolean,
	attribute: (inst: any, name: string) -> any,
	property: (inst: any, name: string) -> any,
	parent: (inst: any) -> any,
	children: (inst: any) -> { any },
}

type SelectorCheck = (inst: any, scope: any) -> boolean
type SelectorCompound = { SelectorCheck }
-- `combinators[i]` relates `compounds[i]` to the compound before it; `combinators[1]` relates it to the scope.
type SelectorComplex = { compounds: { SelectorCompound }, combinators: { string } }
type SelectorList = { SelectorComplex }

local Selector = {}

local function parseSelector(source: string, access: SelectorAccess): SelectorList
	local pos = 1
	local len = #source

	local function fail(): never error(`QueryDescendants: invalid selector "{source}"`, 0) end

	local function peek(): string return string.sub(source, pos, pos) end

	local function skipSpace(): boolean
		local s, e = string.find(source, "^%s+", pos)
		if s ~= nil then
			pos = (e :: number) + 1
			return true
		end
		return false
	end

	local function ident(): string?
		local s, e = string.find(source, "^[%a_][%w_%-]*", pos)
		if s == nil then return nil end
		pos = (e :: number) + 1
		return string.sub(source, s, e :: number)
	end

	local function value(): string
		local quote = peek()
		if quote == '"' or quote == "'" then
			local close = string.find(source, quote, pos + 1, true)
			if close == nil then fail() end
			local text = string.sub(source, pos + 1, (close :: number) - 1)
			pos = (close :: number) + 1
			return text
		end
		local s, e = string.find(source, "^[%w_%-%.]+", pos)
		if s == nil then fail() end
		pos = (e :: number) + 1
		return string.sub(source, s :: number, e :: number)
	end

	local function equals(actual: any, expected: string): boolean
		local kind = type(actual)
		if kind == "boolean" then
			return tostring(actual) == expected
		elseif kind == "number" then
			return tonumber(expected) == actual
		elseif kind == "string" then
			return actual == expected
		elseif actual == nil then
			return false
		end
		-- An EnumItem matches by its Name (`[FillDirection = Horizontal]`).
		local ok, name = pcall(function(): any return actual.Name end)
		return (ok and name == expected) or tostring(actual) == expected
	end

	local parseList: () -> SelectorList

	local function compound(): SelectorCompound?
		local checks: SelectorCompound = {}
		if peek() == "*" then
			pos += 1
			table.insert(checks, function(): boolean return true end)
		else
			local className = ident()
			if className ~= nil then
				table.insert(checks, function(inst: any): boolean return access.isA(inst, className) end)
			end
		end
		while pos <= len do
			local c = peek()
			if c == "." or c == "#" then
				pos += 1
				local word = ident() or fail()
				table.insert(
					checks,
					if c == "."
						then function(inst: any): boolean return access.hasTag(inst, word) end
						else function(inst: any): boolean return access.name(inst) == word end
				)
			elseif c == "[" then
				pos += 1
				skipSpace()
				local isAttribute = peek() == "$"
				if isAttribute then
					pos += 1
				end
				local key = ident() or fail()
				skipSpace()
				local expected: string? = nil
				if peek() == "=" then
					pos += 1
					skipSpace()
					expected = value()
					skipSpace()
				end
				if peek() ~= "]" then fail() end
				pos += 1
				local read: (any, string) -> any = if isAttribute then access.attribute else access.property
				table.insert(checks, function(inst: any): boolean
					local actual = read(inst, key)
					if expected == nil then return actual ~= nil end
					return equals(actual, expected)
				end)
			elseif c == ":" then
				pos += 1
				local pseudo = ident()
				if (pseudo ~= "not" and pseudo ~= "has") or peek() ~= "(" then fail() end
				pos += 1
				local inner = parseList()
				skipSpace()
				if peek() ~= ")" then fail() end
				pos += 1
				if pseudo == "not" then
					table.insert(
						checks,
						function(inst: any, scope: any): boolean
							return not Selector.matchList(inst, inner, scope, access)
						end
					)
				else
					table.insert(checks, function(inst: any): boolean return Selector.any(inst, inner, access) end)
				end
			else
				break
			end
		end
		return if #checks > 0 then checks else nil
	end

	local function combinator(): string?
		if string.sub(source, pos, pos + 1) == ">>" then
			pos += 2
			return ">>"
		elseif peek() == ">" then
			pos += 1
			return ">"
		end
		return nil
	end

	local function complex(): SelectorComplex
		local result: SelectorComplex = { compounds = {}, combinators = {} }
		skipSpace()
		local pending = combinator() or ">>"
		while true do
			skipSpace()
			local part = compound() or fail()
			table.insert(result.compounds, part)
			table.insert(result.combinators, pending)
			local spaced = skipSpace()
			local explicit = combinator()
			if explicit ~= nil then
				pending = explicit
			elseif spaced and pos <= len and peek() ~= "," and peek() ~= ")" then
				pending = ">>"
			else
				break
			end
		end
		return result
	end

	function parseList(): SelectorList
		local list: SelectorList = {}
		repeat
			table.insert(list, complex())
			skipSpace()
			local more = peek() == ","
			if more then
				pos += 1
			end
		until not more
		return list
	end

	local list = parseList()
	skipSpace()
	if pos <= len then fail() end
	return list
end

local function compoundMatches(inst: any, part: SelectorCompound, scope: any): boolean
	for _, check in part do
		if not check(inst, scope) then return false end
	end
	return true
end

local function matchFrom(
	inst: any,
	complex: SelectorComplex,
	index: number,
	scope: any,
	access: SelectorAccess
): boolean
	if not compoundMatches(inst, complex.compounds[index], scope) then return false end
	local link = complex.combinators[index]
	local parent = access.parent(inst)
	if index == 1 then
		if link == ">" then return parent == scope end
		while parent ~= nil do
			if parent == scope then return true end
			parent = access.parent(parent)
		end
		return false
	end
	if link == ">" then
		return parent ~= nil and parent ~= scope and matchFrom(parent, complex, index - 1, scope, access)
	end
	while parent ~= nil and parent ~= scope do
		if matchFrom(parent, complex, index - 1, scope, access) then return true end
		parent = access.parent(parent)
	end
	return false
end

function Selector.matchList(inst: any, list: SelectorList, scope: any, access: SelectorAccess): boolean
	for _, complex in list do
		if matchFrom(inst, complex, #complex.compounds, scope, access) then return true end
	end
	return false
end

local function walkSelector(node: any, access: SelectorAccess, visit: (any) -> boolean): boolean
	for _, child in access.children(node) do
		if visit(child) or walkSelector(child, access, visit) then return true end
	end
	return false
end

function Selector.any(scope: any, list: SelectorList, access: SelectorAccess): boolean
	return walkSelector(
		scope,
		access,
		function(desc: any): boolean return Selector.matchList(desc, list, scope, access) end
	)
end

function Selector.parse(source: string, access: SelectorAccess): SelectorList
	if type(source) ~= "string" then error(`QueryDescendants: invalid selector "{tostring(source)}"`, 0) end
	return parseSelector(source, access)
end

function Selector.query(scope: any, source: string, access: SelectorAccess): { any }
	local list = Selector.parse(source, access)
	local out = {}
	walkSelector(scope, access, function(desc: any): boolean
		if Selector.matchList(desc, list, scope, access) then table.insert(out, desc) end
		return false
	end)
	return out
end

local Color3 = Datatypes.Color3
local BrickColor = Datatypes.BrickColor
local UDim2 = Datatypes.UDim2
local Vector2 = Datatypes.Vector2
local Vector3 = Datatypes.Vector3
local CFrame = Datatypes.CFrame
local Rect = Datatypes.Rect
local Font = Datatypes.Font
local Enum = Datatypes.Enum
local customTypeof = Datatypes.typeof
local rawget: (any, any) -> any = rawget

local InstanceDouble: { [string]: any } = {}
local nextStandaloneId = 0

local function isStrictEnv(env: any): boolean return if env ~= nil then env.strict ~= false else true end

type LayoutState = {
	dirty: { [any]: boolean },
	dirtyOrder: { any },
	hasDirty: boolean,
	flushing: boolean,
	anyGeomSig: boolean,
}

local standaloneLayoutState: LayoutState = {
	dirty = {},
	dirtyOrder = {},
	hasDirty = false,
	flushing = false,
	anyGeomSig = false,
}

local function getLayoutState(env: any): LayoutState
	if env == nil then return standaloneLayoutState end
	local state: LayoutState? = rawget(env, "_layoutState")
	if state == nil then
		state = {
			dirty = {},
			dirtyOrder = {},
			hasDirty = false,
			flushing = false,
			anyGeomSig = false,
		}
		rawset(env, "_layoutState", state)
	end
	return state :: LayoutState
end

-- GUI geometry (defined with setParent below): the properties that move a GuiObject, and the re-layout pass.
local LAYOUT_KEYS: { [string]: boolean }
local LAYOUT_MODIFIER_CLASSES: { [string]: boolean }
local GEOMETRY_PROPS: { [string]: boolean }
local relayout: (inst: any) -> ()
local flushLayouts: (env: any?) -> ()
local markGeomSig: (inst: any) -> ()
local parentDependsOnChildren: (parent: any) -> boolean

local NONE = table.freeze({})

local Ray = Datatypes.Ray

-- Class hierarchy for Instance:IsA(className) ------------------------------------------------------------------------

-- The hierarchy comes from the generated API dump; these are the classes sert models that the dump lacks.
local SUPERCLASS_OVERRIDES: { [string]: string } = {
	CylinderPart = "BasePart",
}

local function superclassOf(name: string): string? return SUPERCLASS_OVERRIDES[name] or Generated.superclass(name) end

-- Read-only view for `env`: `SUPERCLASS[className]` is the direct superclass.
local SUPERCLASS: { [string]: string } = setmetatable({}, {
	__index = function(_: any, name: any): string? return if type(name) == "string" then superclassOf(name) else nil end,
	__newindex = function() error("InstanceDouble.SUPERCLASS is read-only (it comes from the generated API dump)", 2) end,
}) :: any

-- className -> { [superclass]: true } along superclassOf (overrides included); classes unknown to the dump get
-- whatever chain superclassOf gives them (usually none).
local ANCESTORS: { [string]: { [string]: boolean } } = {}

local function isClass(actual: string, target: string): boolean
	if actual == target or target == "Instance" or target == "Object" then return true end
	local set = ANCESTORS[actual]
	if set == nil then
		set = {}
		local cur: string? = superclassOf(actual)
		while cur ~= nil do
			set[cur] = true
			cur = superclassOf(cur)
		end
		ANCESTORS[actual] = set
	end
	return set[target] == true
end

InstanceDouble.SUPERCLASS = SUPERCLASS
InstanceDouble.isClass = isClass

-- Strict schema definitions (used when env.strict == true and for property metadata) ---------------------------------

export type MemberSpec = {
	kind: "property" | "event" | "method",
	default: any,
	-- The `typeof` a strict assignment must have; nil accepts any value (dump types sert has no double for).
	type: string?,
	enum: string?,
	-- The dump's integer type: strict assignments truncate an `int` and round an `int64`, as the engine does.
	integer: string?,
	readOnly: boolean?,
	fn: ((...any) -> ...any)?,
	-- From the API dump with no sert behaviour behind it (a method like this has no `fn`).
	generated: boolean?,
}

export type ClassSchema = {
	name: string,
	creatable: boolean,
	members: { [string]: MemberSpec },
	is: { [string]: boolean },
	-- Initial property values, inherited ones included: hand-written defaults over the dump's.
	defaults: { [string]: any },
	-- The `defaults` keys that came from the dump -> the class declaring them, so an env with injected datatypes
	-- can rebuild those values with its own constructors.
	dumpDefaults: { [string]: string },
}

-- Hand-written class behaviour (props with sert's defaults, events, methods), registered by `defClass` below. A
-- class's schema is built on first use from the generated API dump with these layered on top, so every class in the
-- dump is known (members, read-only flags, events) and the hand-written ones keep their behaviour.
local HAND_SPECS: { [string]: { [string]: any } } = {}

-- Classes sert lets `Instance.new` create although the dump marks them NotCreatable (Roblox makes them through
-- AssetService/TextChatService; tests build them directly).
local SERT_CREATABLE: { [string]: boolean } = {
	EditableImage = true,
	EditableMesh = true,
	TextSource = true,
}

local PRIMITIVE_TYPES: { [string]: string } = {
	bool = "boolean",
	int = "number",
	int64 = "number",
	float = "number",
	double = "number",
	string = "string",
}

local STRING_DATATYPES: { [string]: boolean } = { ContentId = true, ProtectedString = true, BinaryString = true }

local function generatedProperty(info: Generated.Property): MemberSpec
	local category, typeName = info.category, info.typeName
	local kind: string? = nil
	local enumName: string? = nil
	if category == "Primitive" then
		kind = PRIMITIVE_TYPES[typeName]
	elseif category == "Enum" then
		kind, enumName = "EnumItem", typeName
	elseif category == "Class" then
		kind = "Instance"
	elseif STRING_DATATYPES[typeName] then
		kind = "string"
	elseif category == "DataType" and Datatypes[typeName] ~= nil then
		kind = typeName
	end
	local default: any = nil
	if info.default ~= nil then
		local ok, value = pcall(Generated.defaultValue, info.owner, info.name, Datatypes)
		if ok then default = value end
	end
	return {
		kind = "property",
		default = default,
		type = kind,
		enum = enumName,
		integer = if category == "Primitive" and (typeName == "int" or typeName == "int64") then typeName else nil,
		readOnly = info.readOnly,
		generated = true,
	}
end

local CLASSES: { [string]: ClassSchema } = {}

local function buildSchema(name: string): ClassSchema?
	local spec = HAND_SPECS[name]
	local inDump = Generated.exists(name)
	if spec == nil and not inDump then return nil end
	local members: { [string]: MemberSpec } = {}
	local is: { [string]: boolean } = { [name] = true, Instance = true, Object = true }
	local defaults: { [string]: any } = {}
	local dumpDefaults: { [string]: string } = {}
	local super = superclassOf(name)
	local parent = if super ~= nil then CLASSES[super] else nil
	if parent ~= nil then
		for k, m in parent.members do
			members[k] = m
		end
		for k, v in parent.defaults do
			defaults[k] = v
		end
		for k, owner in parent.dumpDefaults do
			dumpDefaults[k] = owner
		end
	end
	local cur = super
	while cur ~= nil do
		is[cur] = true
		cur = superclassOf(cur)
	end
	if inDump then
		local own = (Generated.class(name) :: Generated.Class).own
		for k, info in own.properties do
			local member = generatedProperty(info)
			members[k] = member
			defaults[k] = member.default
			if member.default ~= nil then dumpDefaults[k] = name end
		end
		for k in own.events do
			members[k] = { kind = "event", default = nil, generated = true }
		end
		for k in own.functions do
			members[k] = { kind = "method", default = nil, generated = true }
		end
		for k in own.callbacks do
			members[k] = { kind = "property", default = nil, generated = true }
		end
	end
	if spec ~= nil then
		local ro: { [string]: boolean } = { ClassName = true }
		for _, key in spec.readOnly or {} do
			ro[key] = true
		end
		local props = spec.props or {}
		props.ClassName = name
		for key, default in props do
			local dumped = members[key]
			local kind = if default == NONE
				then (if dumped ~= nil then dumped.type else "Instance")
				else customTypeof(default)
			members[key] = {
				kind = "property",
				default = default,
				type = kind,
				enum = if kind == "EnumItem" then tostring(default.EnumType) else nil,
				integer = if dumped ~= nil and kind == "number" then dumped.integer else nil,
				readOnly = ro[key] == true,
			}
			defaults[key] = if default == NONE then nil else default
			dumpDefaults[key] = nil
		end
		for _, evName in spec.events or {} do
			members[evName] = { kind = "event", default = nil }
		end
		local specMethods: { [string]: (...any) -> ...any } = spec.methods or {}
		for key, fn in specMethods do
			members[key] = { kind = "method", default = nil, fn = fn }
		end
	end
	local creatable = if inDump
		then SERT_CREATABLE[name] == true or (Generated.creatable(name) and not Generated.isService(name))
		else spec ~= nil and not spec.abstract
	local schema: ClassSchema = {
		name = name,
		creatable = creatable,
		members = members,
		is = is,
		defaults = defaults,
		dumpDefaults = dumpDefaults,
	}
	rawset(CLASSES, name, schema)
	return schema
end

setmetatable(CLASSES, {
	__index = function(_: any, name: any): ClassSchema?
		return if type(name) == "string" then buildSchema(name) else nil
	end,
})

local function defineClass(name: string, spec: { [string]: any })
	-- A schema built before every spec is registered would miss the later ones.
	assert(next(CLASSES) == nil, "defineClass after a class schema was built")
	HAND_SPECS[name] = spec
end

local ATTRIBUTE_TYPES: { [string]: boolean } = {}
for _, k in
	string.split(
		"boolean number string UDim UDim2 Color3 BrickColor Vector2 Vector3 CFrame Rect NumberRange ColorSequence NumberSequence EnumItem Font Instance",
		" "
	)
do
	ATTRIBUTE_TYPES[k] = true
end

-- Shared Instance & Class Methods ------------------------------------------------------------------------------------

local InstanceMeta: { [string]: any } = { __type = "Instance" }

local function makeEnvSignal(env: any): any
	local fn: ((any) -> any)? = if env ~= nil then env.signal else nil
	return if fn ~= nil then fn(env) else Signal.new()
end

local function getSignal(inst: any, name: string): any
	if name == "Changed" and rawget(inst, "_isGui") == true then markGeomSig(inst) end
	local sigs = rawget(inst, "_signals")
	if sigs == nil then
		sigs = {}
		rawset(inst, "_signals", sigs)
	end
	local sig = sigs[name]
	if sig == nil then
		local propSig = inst._props[name]
		if propSig ~= nil and propSig ~= NONE then
			sigs[name] = propSig
			return propSig
		end
		sig = makeEnvSignal(rawget(inst, "_env"))
		sigs[name] = sig
	end
	return sig
end

local function fireIfConnected(sigs: { [string]: any }?, key: string, ...: any)
	if sigs ~= nil then
		local sig = sigs[key]
		if sig ~= nil then sig:Fire(...) end
	end
end

local function firePropChanged(inst: any, key: string, value: any)
	local pSigs = rawget(inst, "_propSignals")
	if pSigs ~= nil and pSigs[key] ~= nil then pSigs[key]:Fire() end
	local sigs = rawget(inst, "_signals")
	if sigs ~= nil and sigs.Changed ~= nil then
		-- ValueBase overrides Changed: it fires the new Value, and only when Value changes.
		if isClass(inst._props.ClassName, "ValueBase") then
			if key == "Value" then sigs.Changed:Fire(if value == NONE then nil else value) end
		else
			sigs.Changed:Fire(key)
		end
	end
end

local function walkDescendants(node: any, out: { any })
	local children = rawget(node, "_children")
	if children ~= nil then
		for _, child in children do
			table.insert(out, child)
			walkDescendants(child, out)
		end
	end
end

local function collectSubtree(root: any, out: { any }): { any }
	table.insert(out, root)
	walkDescendants(root, out)
	return out
end

-- Whether any node in root's subtree has `key` in its signal map (fireIfConnected would fire for it).
local function subtreeHasSignal(root: any, key: string): boolean
	local sigs = rawget(root, "_signals")
	if sigs ~= nil and sigs[key] ~= nil then return true end
	local children = rawget(root, "_children")
	if children ~= nil then
		for _, child in children do
			if subtreeHasSignal(child, key) then return true end
		end
	end
	return false
end

local function findAncestor(self: any, match: (any, any) -> boolean, target: any): any
	local cur = rawget(self, "_parent")
	while cur ~= nil do
		if match(cur, target) then return cur end
		cur = rawget(cur, "_parent")
	end
	return nil
end

--- Whether `inst` is `env.game` or a descendant of it (Roblox's "in the DataModel").
local function isInDataModel(env: any, inst: any): boolean
	local game = if env ~= nil then env.game else nil
	return game ~= nil and (rawequal(inst, game) or findAncestor(inst, rawequal, game) ~= nil)
end
InstanceDouble.isInDataModel = isInDataModel

local function isLockedService(inst: any, env: any): boolean
	if rawget(inst, "_isService") == true then return true end
	local cls = inst._props.ClassName
	if cls == "DataModel" then return true end
	if env ~= nil and env.game == inst then return true end
	if Generated.isService(cls) and env ~= nil and rawget(inst, "_parent") == env.game then return true end
	return false
end

local function parentNameOf(node: any): string
	return if node ~= nil and type(node) == "table" and node._props ~= nil then tostring(node._props.Name) else "NULL"
end

local function setParent(inst: any, newParent: any?, allowDestroyedDetach: boolean?)
	local env = rawget(inst, "_env")
	if isLockedService(inst, env) then
		local cur = parentNameOf(rawget(inst, "_parent"))
		local target = parentNameOf(newParent)
		error(`The Parent property of {inst._props.Name} is locked, current parent: {cur}, new parent {target}`, 3)
	end
	if not allowDestroyedDetach and (rawget(inst, "_destroyed") == true or rawget(inst, "_destroying") == true) then
		local target = parentNameOf(newParent)
		error(`The Parent property of {inst._props.Name} is locked, current parent: NULL, new parent {target}`, 3)
	end
	if newParent ~= nil and (type(newParent) ~= "table" or rawget(newParent, "_isInstance") ~= true) then
		error(`invalid argument #3 (Instance expected, got {customTypeof(newParent)})`, 3)
	end
	if newParent == inst or (newParent ~= nil and newParent:IsDescendantOf(inst)) then
		error(
			`Attempt to set parent of {inst:GetFullName()} to {newParent:GetFullName()} would result in circular reference`,
			3
		)
	end
	local oldParent = rawget(inst, "_parent")
	if oldParent == newParent then return end
	local myGen = (rawget(inst, "_reparentGen") or 0) + 1
	rawset(inst, "_reparentGen", myGen)
	local wasInDataModel = if env ~= nil then isInDataModel(env, inst) else false
	local subtree: { any }? = nil
	if oldParent ~= nil then
		local anc = oldParent
		while anc ~= nil do
			if not rawget(anc, "_destroying") then
				local ancSigs = rawget(anc, "_signals")
				if ancSigs ~= nil and ancSigs.DescendantRemoving ~= nil then
					subtree = subtree or collectSubtree(inst, {})
					for _, node in subtree :: { any } do
						fireIfConnected(ancSigs, "DescendantRemoving", node)
					end
				end
			end
			anc = rawget(anc, "_parent")
		end
		if
			rawget(inst, "_reparentGen") ~= myGen
			or rawget(inst, "_destroyed") == true
			or (not allowDestroyedDetach and rawget(inst, "_destroying") == true)
		then
			return
		end
		local oldChildren = rawget(oldParent, "_children")
		if oldChildren ~= nil then
			local idx = table.find(oldChildren, inst)
			if idx ~= nil then table.remove(oldChildren, idx) end
		end
	end
	rawset(inst, "_parent", newParent)
	if newParent ~= nil then
		local newChildren = rawget(newParent, "_children")
		if newChildren == nil then
			newChildren = {}
			rawset(newParent, "_children", newChildren)
		end
		table.insert(newChildren, inst)
		if rawget(inst, "_hasGui") == true then
			local anc = newParent
			while anc ~= nil and rawget(anc, "_hasGui") ~= true do
				rawset(anc, "_hasGui", true)
				anc = rawget(anc, "_parent")
			end
		end
		if rawget(inst, "_subtreeGeomSig") == true then
			local anc = newParent
			while anc ~= nil and rawget(anc, "_subtreeGeomSig") ~= true do
				rawset(anc, "_subtreeGeomSig", true)
				anc = rawget(anc, "_parent")
			end
		end
	end
	local nowInDataModel = if env ~= nil then isInDataModel(env, inst) else false
	if oldParent ~= nil then
		if not rawget(oldParent, "_destroying") then
			fireIfConnected(rawget(oldParent, "_signals"), "ChildRemoved", inst)
		end
		local anc = oldParent
		while anc ~= nil do
			if not rawget(anc, "_destroying") then
				local ancSigs = rawget(anc, "_signals")
				if ancSigs ~= nil and ancSigs.DescendantRemoved ~= nil then
					subtree = subtree or collectSubtree(inst, {})
					for _, node in subtree :: { any } do
						fireIfConnected(ancSigs, "DescendantRemoved", node)
					end
				end
			end
			anc = rawget(anc, "_parent")
		end
	end
	if newParent ~= nil and rawget(inst, "_reparentGen") == myGen then
		fireIfConnected(rawget(newParent, "_signals"), "ChildAdded", inst)
		local anc = newParent
		while anc ~= nil do
			local ancSigs = rawget(anc, "_signals")
			if ancSigs ~= nil and ancSigs.DescendantAdded ~= nil then
				subtree = subtree or collectSubtree(inst, {})
				for _, node in subtree :: { any } do
					ancSigs.DescendantAdded:Fire(node)
				end
			end
			anc = rawget(anc, "_parent")
		end
	end
	if rawget(inst, "_reparentGen") ~= myGen then return end
	-- Snapshot the subtree only when some node listens: handlers may reparent nodes mid-loop.
	if subtreeHasSignal(inst, "AncestryChanged") then
		for _, node in collectSubtree(inst, {}) do
			fireIfConnected(rawget(node, "_signals"), "AncestryChanged", inst, newParent)
		end
	end
	if rawget(inst, "_reparentGen") ~= myGen then return end
	firePropChanged(inst, "Parent", newParent)
	if rawget(inst, "_reparentGen") ~= myGen then return end
	if wasInDataModel ~= nowInDataModel and env ~= nil then
		local sigMap = if nowInDataModel then env._tagAddedSignals else env._tagRemovedSignals
		for _, node in collectSubtree(inst, {}) do
			local tags = rawget(node, "_tags")
			if tags ~= nil then
				local tagOrder = rawget(node, "_tagOrder")
				for tag in tags do
					if nowInDataModel then
						local list = env._tags[tag]
						if list == nil then
							list = {}
							env._tags[tag] = list
						end
						if table.find(list, node) == nil then
							local myOrd = if tagOrder ~= nil then tagOrder[tag] or math.huge else math.huge
							local pos = #list + 1
							for i, other in list do
								local otherOrdMap = rawget(other, "_tagOrder")
								local otherOrd = if otherOrdMap ~= nil then otherOrdMap[tag] or math.huge else math.huge
								if myOrd < otherOrd then
									pos = i
									break
								end
							end
							table.insert(list, pos, node)
						end
					else
						local list = env._tags[tag]
						local idx = if list ~= nil then table.find(list, node) else nil
						if idx ~= nil then table.remove(list, idx) end
					end
					if sigMap[tag] ~= nil then sigMap[tag]:Fire(node) end
				end
			end
		end
	end
	if rawget(inst, "_reparentGen") ~= myGen then return end
	if rawget(inst, "_hasGui") == true then
		if oldParent ~= nil and not rawget(oldParent, "_destroying") then
			if LAYOUT_MODIFIER_CLASSES[inst._props.ClassName] or parentDependsOnChildren(oldParent) then
				relayout(oldParent)
			end
		end
		if not rawget(inst, "_destroying") then relayout(inst) end
	end
	if env ~= nil then
		local onReparent: ((any, any) -> ())? = env._onReparent
		if onReparent ~= nil then onReparent(inst, newParent) end
	end
end

-- GUI geometry ---------------------------------------------------------------------------------------------------
-- Deterministic headless UI layout engine for GuiBase2d, GuiObject, UIListLayout, UIGridLayout, UIPadding,
-- UIScale, UISizeConstraint, UIAspectRatioConstraint, AutomaticSize, ScrollingFrame, and TextBounds/TextFits.

LAYOUT_KEYS = {
	Size = true,
	Position = true,
	AnchorPoint = true,
	SizeConstraint = true,
	AutomaticSize = true,
	LayoutOrder = true,
	Visible = true,
	Name = true,
	Text = true,
	TextSize = true,
	TextScaled = true,
	TextWrapped = true,
	RichText = true,
	CanvasSize = true,
	CanvasPosition = true,
	AutomaticCanvasSize = true,
	ScrollBarThickness = true,
	ScrollingDirection = true,
	FillDirection = true,
	HorizontalAlignment = true,
	VerticalAlignment = true,
	SortOrder = true,
	Padding = true,
	Wraps = true,
	CellSize = true,
	CellPadding = true,
	FillDirectionMaxCells = true,
	StartCorner = true,
	PaddingTop = true,
	PaddingBottom = true,
	PaddingLeft = true,
	PaddingRight = true,
	Scale = true,
	MinSize = true,
	MaxSize = true,
	AspectRatio = true,
	AspectType = true,
	DominantAxis = true,
	FlexMode = true,
	GrowRatio = true,
	ShrinkRatio = true,
	ItemLineAlignment = true,
	HorizontalFlex = true,
	VerticalFlex = true,
}

local TEXT_CLASSES: { [string]: boolean } = {
	TextLabel = true,
	TextButton = true,
	TextBox = true,
}

LAYOUT_MODIFIER_CLASSES = {
	UIListLayout = true,
	UIGridLayout = true,
	UIPadding = true,
	UIScale = true,
	UISizeConstraint = true,
	UIAspectRatioConstraint = true,
	UIFlexItem = true,
}

GEOMETRY_PROPS = {
	AbsoluteSize = true,
	AbsolutePosition = true,
	AbsoluteContentSize = true,
	AbsoluteCellSize = true,
	AbsoluteCellCount = true,
	AbsoluteCanvasSize = true,
	AbsoluteWindowSize = true,
	ContentText = true,
	TextBounds = true,
	TextFits = true,
}

local function enumName(val: any, default: string): string
	if val == nil then return default end
	local k = type(val)
	if k == "string" then return val end
	if (k == "table" or k == "userdata") and val.Name ~= nil then return tostring(val.Name) end
	return default
end

local function containerOf(inst: any): any
	local cur = rawget(inst, "_parent")
	while cur ~= nil do
		if isClass(cur._props.ClassName, "GuiBase2d") then return cur end
		cur = rawget(cur, "_parent")
	end
	return nil
end

local function vectorOf(inst: any): any
	local env = rawget(inst, "_env")
	local dt = if env ~= nil and env.datatypes ~= nil then env.datatypes else Datatypes
	return dt.Vector2
end

local function setGeometry(inst: any, key: string, value: any)
	local props = inst._props
	if props[key] ~= value then
		props[key] = value
		firePropChanged(inst, key, value)
	end
end

local function axis(dim: any, field: string): (number, number)
	local part = if dim ~= nil then dim[field] else nil
	if part == nil then return 0, 0 end
	return part.Scale or 0, part.Offset or 0
end

local function udimValue(u: any, basis: number): number
	if u == nil then return 0 end
	return (u.Scale or 0) * basis + (u.Offset or 0)
end

local function paddingOf(container: any, cw: number, ch: number): (number, number, number, number)
	local children = rawget(container, "_children")
	if children == nil then return 0, 0, 0, 0 end
	for _, child in children do
		if child._props.ClassName == "UIPadding" then
			local p = child._props
			local left = udimValue(p.PaddingLeft, cw)
			local right = udimValue(p.PaddingRight, cw)
			local top = udimValue(p.PaddingTop, ch)
			local bottom = udimValue(p.PaddingBottom, ch)
			return left, right, top, bottom
		end
	end
	return 0, 0, 0, 0
end

local function applyObjectConstraints(
	inst: any,
	w: number,
	h: number,
	parentW: number?,
	parentH: number?
): (number, number)
	local children = rawget(inst, "_children")
	if children == nil then return w, h end
	local scaleFactor = 1
	local sizeConstraint: any = nil
	local aspectConstraint: any = nil
	for _, child in children do
		local cls = child._props.ClassName
		if cls == "UIScale" then
			local s = child._props.Scale
			if type(s) == "number" then
				scaleFactor *= s
			end
		elseif cls == "UISizeConstraint" and sizeConstraint == nil then
			sizeConstraint = child._props
		elseif cls == "UIAspectRatioConstraint" and aspectConstraint == nil then
			aspectConstraint = child._props
		end
	end
	if sizeConstraint ~= nil then
		local minS = sizeConstraint.MinSize
		local maxS = sizeConstraint.MaxSize
		local minX = if minS ~= nil then minS.X else 0
		local minY = if minS ~= nil then minS.Y else 0
		local maxX = if maxS ~= nil then maxS.X else math.huge
		local maxY = if maxS ~= nil then maxS.Y else math.huge
		w = math.clamp(w, minX, maxX)
		h = math.clamp(h, minY, maxY)
	end
	if aspectConstraint ~= nil then
		local ratio = aspectConstraint.AspectRatio
		if type(ratio) == "number" and ratio > 0 then
			local aspectType = enumName(aspectConstraint.AspectType, "FitWithinMaxSize")
			local dom = enumName(aspectConstraint.DominantAxis, "Width")
			if aspectType == "ScaleWithParentSize" then
				if dom == "Height" then
					w = h * ratio
				else
					h = w / ratio
				end
				if
					parentW ~= nil
					and parentH ~= nil
					and parentW > 0
					and parentH > 0
					and (w > parentW or h > parentH)
				then
					local s = math.min(parentW / w, parentH / h)
					w *= s
					h *= s
				end
			else
				if w > 0 and h > 0 then
					if w / ratio <= h then
						h = w / ratio
					else
						w = h * ratio
					end
				elseif dom == "Height" then
					w = h * ratio
				else
					h = w / ratio
				end
			end
		end
	end
	w *= scaleFactor
	h *= scaleFactor
	return w, h
end

local function measureTextWithFontSize(
	visibleText: string,
	fontSize: number,
	wrap: boolean,
	availW: number
): (number, number)
	if #visibleText == 0 then return 0, 0 end
	local charW = fontSize * 0.55
	local lineH = math.ceil(fontSize * 1.2)
	local paragraphs = string.split(visibleText, "\n")
	local totalLines = 0
	local maxLineW = 0
	for _, para in paragraphs do
		if not wrap or availW <= 0 or #para * charW <= availW + 1e-6 then
			totalLines += 1
			local w = #para * charW
			if w > maxLineW then maxLineW = w end
		else
			local words = string.split(para, " ")
			local curLen = 0
			local maxCharsPerLine = math.max(1, math.floor(availW / math.max(charW, 0.1)))
			for _, word in words do
				local wLen = #word
				if wLen * charW > availW + 1e-6 then
					if curLen > 0 then
						totalLines += 1
						local lw = curLen * charW
						if lw > maxLineW then maxLineW = lw end
						curLen = 0
					end
					local rem = wLen
					while rem > maxCharsPerLine do
						totalLines += 1
						local lw = maxCharsPerLine * charW
						if lw > maxLineW then maxLineW = lw end
						rem -= maxCharsPerLine
					end
					curLen = rem
				elseif curLen == 0 then
					curLen = wLen
				elseif (curLen + 1 + wLen) * charW <= availW + 1e-6 then
					curLen += 1 + wLen
				else
					totalLines += 1
					local lw = curLen * charW
					if lw > maxLineW then maxLineW = lw end
					curLen = wLen
				end
			end
			if curLen > 0 or #words == 0 then
				totalLines += 1
				local lw = curLen * charW
				if lw > maxLineW then maxLineW = lw end
			end
		end
	end
	return math.ceil(maxLineW - 1e-9), totalLines * lineH
end

local function updateTypography(inst: any, absSize: any)
	local props = inst._props
	if not TEXT_CLASSES[props.ClassName] then return end
	local V2 = vectorOf(inst)
	local rawText = tostring(props.Text or "")
	local stripped = string.gsub(rawText, "<[^>]+>", "")
	setGeometry(inst, "ContentText", stripped)
	local visibleText = if props.RichText == true then stripped else rawText
	if #visibleText == 0 then
		setGeometry(inst, "TextBounds", V2.new(0, 0))
		setGeometry(inst, "TextFits", true)
		return
	end
	local textSize = if type(props.TextSize) == "number" and props.TextSize > 0 then props.TextSize else 14
	local textWrapped = props.TextWrapped == true
	local textScaled = props.TextScaled == true
	local availW = if absSize ~= nil then absSize.X else 0
	local availH = if absSize ~= nil then absSize.Y else 0
	local width, height: number
	if textScaled and availW > 0 and availH > 0 then
		local lo, hi = 1, 100
		local bestW, bestH = measureTextWithFontSize(visibleText, 1, true, availW)
		while lo <= hi do
			local mid = (lo + hi) // 2
			local mw, mh = measureTextWithFontSize(visibleText, mid, true, availW)
			if mw <= availW + 0.5 and mh <= availH + 0.5 then
				bestW, bestH = mw, mh
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		width = math.min(bestW, math.floor(availW))
		height = math.min(bestH, math.floor(availH))
	else
		width, height = measureTextWithFontSize(visibleText, textSize, textWrapped, availW)
	end
	local fits = width <= availW + 0.5 and height <= availH + 0.5
	setGeometry(inst, "TextBounds", V2.new(width, height))
	setGeometry(inst, "TextFits", fits)
end

local function computeChildSize(inst: any, cw: number, ch: number): any
	local props = inst._props
	local pin = rawget(inst, "_absPin")
	if pin ~= nil and pin.size ~= nil then return pin.size end
	local V2 = vectorOf(inst)
	local sxS, sxO = axis(props.Size, "X")
	local syS, syO = axis(props.Size, "Y")
	local sc = enumName(props.SizeConstraint, "RelativeXY")
	local baseX = if sc == "RelativeYY" then ch else cw
	local baseY = if sc == "RelativeXX" then cw else ch
	local w = baseX * sxS + sxO
	local h = baseY * syS + syO
	w, h = applyObjectConstraints(inst, w, h, cw, ch)
	return V2.new(w, h)
end

local function flexRatiosOf(inst: any, parentFlexMode: string): (number, number, string)
	local children = rawget(inst, "_children")
	if children ~= nil then
		for _, child in children do
			if child._props.ClassName == "UIFlexItem" then
				local fp = child._props
				local mode = enumName(fp.FlexMode, "None")
				local align = enumName(fp.ItemLineAlignment, "Automatic")
				if mode == "Grow" then
					return 1, 0, align
				elseif mode == "Shrink" then
					return 0, 1, align
				elseif mode == "Fill" then
					return 1, 1, align
				elseif mode == "Custom" then
					return math.max(0, tonumber(fp.GrowRatio) or 0), math.max(0, tonumber(fp.ShrinkRatio) or 0), align
				else
					return 0, 0, align
				end
			end
		end
	end
	if parentFlexMode == "Fill" then return 1, 1, "Automatic" end
	return 0, 0, "Automatic"
end

local function containerScrollOffset(container: any): (number, number)
	if container ~= nil and isClass(container._props.ClassName, "ScrollingFrame") then
		local cPos = container._props.CanvasPosition
		if cPos ~= nil then return cPos.X or 0, cPos.Y or 0 end
	end
	return 0, 0
end

local function computeChildPosition(inst: any, size: any, cx: number, cy: number, cw: number, ch: number): any
	local props = inst._props
	local pin = rawget(inst, "_absPin")
	if pin ~= nil and pin.position ~= nil then return pin.position end
	local V2 = vectorOf(inst)
	local pxS, pxO = axis(props.Position, "X")
	local pyS, pyO = axis(props.Position, "Y")
	local anchor = props.AnchorPoint
	local ax, ay = if anchor ~= nil then anchor.X else 0, if anchor ~= nil then anchor.Y else 0
	return V2.new(cx + cw * pxS + pxO - ax * size.X, cy + ch * pyS + pyO - ay * size.Y)
end

type SortEntry = { child: any, idx: number, order: number, name: string }

local function sortGuiChildren(children: { any }, sortOrder: any): { any }
	local byName = enumName(sortOrder, "LayoutOrder") == "Name"
	local indexed: { SortEntry } = {}
	for i, child in children do
		local rawOrder = child._props.LayoutOrder
		local orderNum: number = if type(rawOrder) == "number" then rawOrder else 0
		table.insert(indexed, { child = child, idx = i, order = orderNum, name = tostring(child._props.Name) })
	end
	table.sort(indexed, function(a: SortEntry, b: SortEntry): boolean
		if byName then
			if a.name ~= b.name then return a.name < b.name end
			return a.idx < b.idx
		else
			if a.order ~= b.order then return a.order < b.order end
			return a.idx < b.idx
		end
	end)
	local out: { any } = {}
	for _, entry in indexed do
		table.insert(out, entry.child)
	end
	return out
end

local layoutSubtree: (node: any, positionedByParentLayout: boolean?) -> ()

function layoutSubtree(node: any, positionedByParentLayout: boolean?)
	if rawget(node, "_hasGui") ~= true then return end
	local props = node._props
	local className = props.ClassName
	local V2 = vectorOf(node)
	local isGuiBase = isClass(className, "GuiBase2d")
	local isGuiObj = isClass(className, "GuiObject")

	if isGuiBase then
		local pin = rawget(node, "_absPin")
		if isClass(className, "LayerCollector") then
			if pin ~= nil and pin.size ~= nil then
				setGeometry(node, "AbsoluteSize", pin.size)
			else
				local env = rawget(node, "_env")
				local parent = rawget(node, "_parent")
				if
					parent ~= nil
					and isClass(parent._props.ClassName, "BasePlayerGui")
					and parent._props.AbsoluteSize ~= nil
				then
					setGeometry(node, "AbsoluteSize", parent._props.AbsoluteSize)
				elseif env ~= nil and rawget(env, "_viewport") ~= nil then
					setGeometry(node, "AbsoluteSize", rawget(env, "_viewport"))
				end
			end
			if pin ~= nil and pin.position ~= nil then setGeometry(node, "AbsolutePosition", pin.position) end
		elseif isGuiObj and not positionedByParentLayout then
			local container = containerOf(node)
			local cs = if container ~= nil then container._props.AbsoluteSize else nil
			local cp = if container ~= nil then container._props.AbsolutePosition else nil
			local cw, ch = if cs ~= nil then cs.X else 0, if cs ~= nil then cs.Y else 0
			local cx, cy = if cp ~= nil then cp.X else 0, if cp ~= nil then cp.Y else 0
			if container ~= nil then
				local pL, pR, pT, pB = paddingOf(container, cw, ch)
				local sX, sY = containerScrollOffset(container)
				cx += pL - sX
				cy += pT - sY
				cw = math.max(0, cw - pL - pR)
				ch = math.max(0, ch - pT - pB)
			end
			local size = computeChildSize(node, cw, ch)
			local pos = computeChildPosition(node, size, cx, cy, cw, ch)
			setGeometry(node, "AbsoluteSize", size)
			setGeometry(node, "AbsolutePosition", pos)
		end
	end

	if TEXT_CLASSES[className] then updateTypography(node, props.AbsoluteSize) end

	local children = rawget(node, "_children")
	local listLayout: any = nil
	local gridLayout: any = nil
	if children ~= nil then
		for _, child in children do
			local cCls = child._props.ClassName
			if cCls == "UIListLayout" and listLayout == nil then
				listLayout = child
			elseif cCls == "UIGridLayout" and gridLayout == nil then
				gridLayout = child
			end
		end
	end

	local absSize = props.AbsoluteSize or V2.new(0, 0)
	local absPos = props.AbsolutePosition or V2.new(0, 0)
	local padLeft, padRight, padTop, padBottom = 0, 0, 0, 0
	if isGuiBase then
		padLeft, padRight, padTop, padBottom = paddingOf(node, absSize.X, absSize.Y)
	end
	local scrollOffX, scrollOffY = containerScrollOffset(node)
	local contentX = absPos.X + padLeft - scrollOffX
	local contentY = absPos.Y + padTop - scrollOffY
	local contentW = math.max(0, absSize.X - padLeft - padRight)
	local contentH = math.max(0, absSize.Y - padTop - padBottom)

	if isGuiBase and listLayout ~= nil and children ~= nil then
		local visibleGuiChildren: { any } = {}
		local otherChildren: { any } = {}
		for _, child in children do
			if isClass(child._props.ClassName, "GuiObject") then
				if child._props.Visible ~= false then
					table.insert(visibleGuiChildren, child)
				else
					table.insert(otherChildren, child)
				end
			elseif child._props.ClassName ~= "UIListLayout" and child._props.ClassName ~= "UIGridLayout" then
				table.insert(otherChildren, child)
			end
		end
		local ordered = sortGuiChildren(visibleGuiChildren, listLayout._props.SortOrder)
		for _, child in ordered do
			local cSize = computeChildSize(child, contentW, contentH)
			setGeometry(child, "AbsoluteSize", cSize)
			if enumName(child._props.AutomaticSize, "None") ~= "None" then layoutSubtree(child, true) end
		end
		local lProps = listLayout._props
		local isHoriz = enumName(lProps.FillDirection, "Vertical") == "Horizontal"
		local hAlign = enumName(lProps.HorizontalAlignment, "Left")
		local vAlign = enumName(lProps.VerticalAlignment, "Top")
		local mainFlex = enumName(if isHoriz then lProps.HorizontalFlex else lProps.VerticalFlex, "None")
		local wraps = lProps.Wraps == true
		local mainAvail = if isHoriz then contentW else contentH
		local gap = udimValue(lProps.Padding, mainAvail)

		type Line = { items: { any }, mainSpan: number, crossSpan: number }
		local lines: { Line } = {}
		local curLine: Line = { items = {}, mainSpan = 0, crossSpan = 0 }
		for _, child in ordered do
			local cs = child._props.AbsoluteSize
			local cMain = if isHoriz then cs.X else cs.Y
			local cCross = if isHoriz then cs.Y else cs.X
			if wraps and #curLine.items > 0 and mainAvail > 0 and curLine.mainSpan + gap + cMain > mainAvail + 0.5 then
				table.insert(lines, curLine)
				curLine = { items = {}, mainSpan = 0, crossSpan = 0 }
			end
			if #curLine.items > 0 then
				curLine.mainSpan += gap
			end
			table.insert(curLine.items, child)
			curLine.mainSpan += cMain
			if cCross > curLine.crossSpan then curLine.crossSpan = cCross end
		end
		if #curLine.items > 0 then table.insert(lines, curLine) end

		-- Distribute positive free space or negative overflow across UIFlexItem children per line.
		for _, line in lines do
			local delta = mainAvail - line.mainSpan
			if math.abs(delta) > 1e-6 and mainAvail > 0 then
				local totalWeight = 0
				local weights: { number } = {}
				for idx, child in line.items do
					local pin = rawget(child, "_absPin")
					if pin ~= nil and pin.size ~= nil then
						weights[idx] = 0
					else
						local grow, shrink = flexRatiosOf(child, mainFlex)
						local w = if delta > 0 then grow else shrink
						weights[idx] = w
						totalWeight += w
					end
				end
				if totalWeight > 0 then
					line.mainSpan = math.max(0, (#line.items - 1) * gap)
					line.crossSpan = 0
					for idx, child in line.items do
						local w = weights[idx]
						local cs = child._props.AbsoluteSize
						local newW, newH = cs.X, cs.Y
						if w > 0 then
							local adj = delta * (w / totalWeight)
							if isHoriz then
								newW = math.max(0, newW + adj)
							else
								newH = math.max(0, newH + adj)
							end
							newW, newH = applyObjectConstraints(child, newW, newH, contentW, contentH)
							setGeometry(child, "AbsoluteSize", V2.new(newW, newH))
							if TEXT_CLASSES[child._props.ClassName] then updateTypography(child, V2.new(newW, newH)) end
						end
						line.mainSpan += if isHoriz then newW else newH
						local cCross = if isHoriz then newH else newW
						if cCross > line.crossSpan then line.crossSpan = cCross end
					end
				end
			end
		end

		local totalMain = 0
		local totalCross = 0
		for i, line in lines do
			if line.mainSpan > totalMain then totalMain = line.mainSpan end
			if i > 1 then
				totalCross += gap
			end
			totalCross += line.crossSpan
		end
		local totalW = if isHoriz then totalMain else totalCross
		local totalH = if isHoriz then totalCross else totalMain
		setGeometry(listLayout, "AbsoluteContentSize", V2.new(totalW, totalH))

		local crossCursor = if isHoriz
			then (if vAlign == "Center"
				then contentY + (contentH - totalCross) * 0.5
				elseif vAlign == "Bottom" then contentY + (contentH - totalCross)
				else contentY)
			else (if hAlign == "Center"
				then contentX + (contentW - totalCross) * 0.5
				elseif hAlign == "Right" then contentX + (contentW - totalCross)
				else contentX)

		for _, line in lines do
			local mainCursor = if isHoriz
				then (if hAlign == "Center"
					then contentX + (contentW - line.mainSpan) * 0.5
					elseif hAlign == "Right" then contentX + (contentW - line.mainSpan)
					else contentX)
				else (if vAlign == "Center"
					then contentY + (contentH - line.mainSpan) * 0.5
					elseif vAlign == "Bottom" then contentY + (contentH - line.mainSpan)
					else contentY)
			local lineCrossBox = if #lines == 1 then (if isHoriz then contentH else contentW) else line.crossSpan
			local lineCrossOrigin = if #lines == 1 then (if isHoriz then contentY else contentX) else crossCursor

			for _, child in line.items do
				local cs = child._props.AbsoluteSize
				local pin = rawget(child, "_absPin")
				if pin == nil or pin.position == nil then
					local cx, cy: number
					if isHoriz then
						cx = mainCursor
						cy = if vAlign == "Center"
							then lineCrossOrigin + (lineCrossBox - cs.Y) * 0.5
							elseif vAlign == "Bottom" then lineCrossOrigin + (lineCrossBox - cs.Y)
							else lineCrossOrigin
					else
						cy = mainCursor
						cx = if hAlign == "Center"
							then lineCrossOrigin + (lineCrossBox - cs.X) * 0.5
							elseif hAlign == "Right" then lineCrossOrigin + (lineCrossBox - cs.X)
							else lineCrossOrigin
					end
					setGeometry(child, "AbsolutePosition", V2.new(cx, cy))
				end
				layoutSubtree(child, true)
				mainCursor += (if isHoriz then cs.X else cs.Y) + gap
			end
			crossCursor += line.crossSpan + gap
		end

		for _, child in otherChildren do
			layoutSubtree(child, false)
		end
	elseif isGuiBase and gridLayout ~= nil and children ~= nil then
		local visibleGuiChildren: { any } = {}
		local otherChildren: { any } = {}
		for _, child in children do
			if isClass(child._props.ClassName, "GuiObject") then
				if child._props.Visible ~= false then
					table.insert(visibleGuiChildren, child)
				else
					table.insert(otherChildren, child)
				end
			elseif child._props.ClassName ~= "UIListLayout" and child._props.ClassName ~= "UIGridLayout" then
				table.insert(otherChildren, child)
			end
		end
		local gProps = gridLayout._props
		local ordered = sortGuiChildren(visibleGuiChildren, gProps.SortOrder)
		local csX_S, csX_O = axis(gProps.CellSize, "X")
		local csY_S, csY_O = axis(gProps.CellSize, "Y")
		local cellW = contentW * csX_S + csX_O
		local cellH = contentH * csY_S + csY_O
		local cpX_S, cpX_O = axis(gProps.CellPadding, "X")
		local cpY_S, cpY_O = axis(gProps.CellPadding, "Y")
		local padX = contentW * cpX_S + cpX_O
		local padY = contentH * cpY_S + cpY_O
		local isVert = enumName(gProps.FillDirection, "Horizontal") == "Vertical"
		local maxCells = gProps.FillDirectionMaxCells or 0
		local cols: number
		local rows: number
		local n = #ordered
		if not isVert then
			cols = math.max(1, math.floor((contentW + padX) / math.max(1, cellW + padX)))
			if maxCells > 0 then cols = math.min(cols, maxCells) end
			rows = if n > 0 then math.ceil(n / cols) else 0
		else
			rows = math.max(1, math.floor((contentH + padY) / math.max(1, cellH + padY)))
			if maxCells > 0 then rows = math.min(rows, maxCells) end
			cols = if n > 0 then math.ceil(n / rows) else 0
		end
		local usedCols = if n == 0 then 0 elseif not isVert then math.min(n, cols) else cols
		local usedRows = if n == 0 then 0 elseif not isVert then rows else math.min(n, rows)
		local totalW = if n > 0 then usedCols * cellW + math.max(0, usedCols - 1) * padX else 0
		local totalH = if n > 0 then usedRows * cellH + math.max(0, usedRows - 1) * padY else 0
		setGeometry(gridLayout, "AbsoluteContentSize", V2.new(totalW, totalH))
		setGeometry(gridLayout, "AbsoluteCellSize", V2.new(cellW, cellH))
		setGeometry(gridLayout, "AbsoluteCellCount", V2.new(usedCols, usedRows))

		local hAlign = enumName(gProps.HorizontalAlignment, "Left")
		local vAlign = enumName(gProps.VerticalAlignment, "Top")
		local startCorner = enumName(gProps.StartCorner, "TopLeft")
		local flipX = startCorner == "TopRight" or startCorner == "BottomRight"
		local flipY = startCorner == "BottomLeft" or startCorner == "BottomRight"
		local startX = if hAlign == "Center"
			then contentX + (contentW - totalW) * 0.5
			elseif hAlign == "Right" then contentX + (contentW - totalW)
			else contentX
		local startY = if vAlign == "Center"
			then contentY + (contentH - totalH) * 0.5
			elseif vAlign == "Bottom" then contentY + (contentH - totalH)
			else contentY

		for i, child in ordered do
			local col0 = if not isVert then (i - 1) % cols else (i - 1) // rows
			local row0 = if not isVert then (i - 1) // cols else (i - 1) % rows
			local col = if flipX and usedCols > 0 then (usedCols - 1) - col0 else col0
			local row = if flipY and usedRows > 0 then (usedRows - 1) - row0 else row0
			local pin = rawget(child, "_absPin")
			if pin == nil or pin.size == nil then
				local cw, ch = applyObjectConstraints(child, cellW, cellH, cellW, cellH)
				setGeometry(child, "AbsoluteSize", V2.new(cw, ch))
			end
			if pin == nil or pin.position == nil then
				local cx = startX + col * (cellW + padX)
				local cy = startY + row * (cellH + padY)
				setGeometry(child, "AbsolutePosition", V2.new(cx, cy))
			end
			layoutSubtree(child, true)
		end

		for _, child in otherChildren do
			layoutSubtree(child, false)
		end
	elseif children ~= nil then
		for _, child in children do
			layoutSubtree(child, false)
		end
	end

	-- AutomaticSize expansion on GuiObject
	if isGuiObj then
		local pin = rawget(node, "_absPin")
		local autoMode = enumName(props.AutomaticSize, "None")
		local autoX = autoMode == "X" or autoMode == "XY"
		local autoY = autoMode == "Y" or autoMode == "XY"
		if (autoX or autoY) and (pin == nil or pin.size == nil) then
			local reqW, reqH = 0, 0
			if TEXT_CLASSES[className] then
				local rawText = tostring(props.Text or "")
				local visibleText = if props.RichText == true then string.gsub(rawText, "<[^>]+>", "") else rawText
				local textSize = if type(props.TextSize) == "number" and props.TextSize > 0 then props.TextSize else 14
				local wrapForMeasure = props.TextWrapped == true and not autoX
				local tw, th = measureTextWithFontSize(visibleText, textSize, wrapForMeasure, contentW)
				reqW = math.max(reqW, tw)
				reqH = math.max(reqH, th)
			end
			if listLayout ~= nil then
				local acs = listLayout._props.AbsoluteContentSize
				if acs ~= nil then
					reqW = math.max(reqW, acs.X)
					reqH = math.max(reqH, acs.Y)
				end
			elseif gridLayout ~= nil then
				local acs = gridLayout._props.AbsoluteContentSize
				if acs ~= nil then
					reqW = math.max(reqW, acs.X)
					reqH = math.max(reqH, acs.Y)
				end
			elseif children ~= nil then
				for _, child in children do
					if isClass(child._props.ClassName, "GuiObject") and child._props.Visible ~= false then
						local cp = child._props.AbsolutePosition
						local cs = child._props.AbsoluteSize
						if cp ~= nil and cs ~= nil then
							reqW = math.max(reqW, (cp.X - contentX) + cs.X)
							reqH = math.max(reqH, (cp.Y - contentY) + cs.Y)
						end
					end
				end
			end
			local curSize = props.AbsoluteSize or V2.new(0, 0)
			local newW = if autoX then math.max(curSize.X, reqW + padLeft + padRight) else curSize.X
			local newH = if autoY then math.max(curSize.Y, reqH + padTop + padBottom) else curSize.Y
			newW, newH = applyObjectConstraints(node, newW, newH)
			if newW ~= curSize.X or newH ~= curSize.Y then
				local newSize = V2.new(newW, newH)
				setGeometry(node, "AbsoluteSize", newSize)
				if not positionedByParentLayout and (pin == nil or pin.position == nil) then
					local container = containerOf(node)
					local cs = if container ~= nil then container._props.AbsoluteSize else nil
					local cp = if container ~= nil then container._props.AbsolutePosition else nil
					local cw, ch = if cs ~= nil then cs.X else 0, if cs ~= nil then cs.Y else 0
					local cx, cy = if cp ~= nil then cp.X else 0, if cp ~= nil then cp.Y else 0
					if container ~= nil then
						local pL, pR, pT, pB = paddingOf(container, cw, ch)
						local sX, sY = containerScrollOffset(container)
						cx += pL - sX
						cy += pT - sY
						cw = math.max(0, cw - pL - pR)
						ch = math.max(0, ch - pT - pB)
					end
					setGeometry(node, "AbsolutePosition", computeChildPosition(node, newSize, cx, cy, cw, ch))
				end
				if TEXT_CLASSES[className] then updateTypography(node, newSize) end
			end
		end
	end

	-- ScrollingFrame AbsoluteCanvasSize and AbsoluteWindowSize
	if isClass(className, "ScrollingFrame") then
		local curSize = props.AbsoluteSize or V2.new(0, 0)
		setGeometry(node, "AbsoluteWindowSize", curSize)
		local csX_S, csX_O = axis(props.CanvasSize, "X")
		local csY_S, csY_O = axis(props.CanvasSize, "Y")
		local canvasW = curSize.X * csX_S + csX_O
		local canvasH = curSize.Y * csY_S + csY_O
		local acMode = enumName(props.AutomaticCanvasSize, "None")
		local acX = acMode == "X" or acMode == "XY"
		local acY = acMode == "Y" or acMode == "XY"
		if acX or acY then
			local reqW, reqH = 0, 0
			if listLayout ~= nil then
				local acs = listLayout._props.AbsoluteContentSize
				if acs ~= nil then
					reqW = math.max(reqW, acs.X)
					reqH = math.max(reqH, acs.Y)
				end
			elseif gridLayout ~= nil then
				local acs = gridLayout._props.AbsoluteContentSize
				if acs ~= nil then
					reqW = math.max(reqW, acs.X)
					reqH = math.max(reqH, acs.Y)
				end
			elseif children ~= nil then
				for _, child in children do
					if isClass(child._props.ClassName, "GuiObject") and child._props.Visible ~= false then
						local cp = child._props.AbsolutePosition
						local cs = child._props.AbsoluteSize
						if cp ~= nil and cs ~= nil then
							reqW = math.max(reqW, (cp.X - contentX) + cs.X)
							reqH = math.max(reqH, (cp.Y - contentY) + cs.Y)
						end
					end
				end
			end
			if acX then canvasW = math.max(canvasW, reqW + padLeft + padRight) end
			if acY then canvasH = math.max(canvasH, reqH + padTop + padBottom) end
		end
		setGeometry(node, "AbsoluteCanvasSize", V2.new(canvasW, canvasH))
	end
end

function parentDependsOnChildren(parent: any): boolean
	local pClass = parent._props.ClassName
	if not isClass(pClass, "GuiBase2d") then return false end
	if isClass(pClass, "ScrollingFrame") or enumName(parent._props.AutomaticSize, "None") ~= "None" then return true end
	local pChildren = rawget(parent, "_children")
	if pChildren ~= nil then
		for _, ch in pChildren do
			local cName = ch._props.ClassName
			if cName == "UIListLayout" or cName == "UIGridLayout" then return true end
		end
	end
	return false
end

-- Finds the highest GuiBase2d ancestor whose layout could be affected by `inst` changing.
local function findLayoutRoot(inst: any): any
	local root = inst
	if LAYOUT_MODIFIER_CLASSES[root._props.ClassName] then
		local p = rawget(root, "_parent")
		if p ~= nil then root = p end
	end
	local startRoot = root
	local cur = root
	while cur ~= nil do
		if cur ~= startRoot then
			local curClass = cur._props.ClassName
			if isClass(curClass, "GuiBase2d") and enumName(cur._props.AutomaticSize, "None") == "None" then break end
		end
		local parent = rawget(cur, "_parent")
		if parent == nil then break end
		if isClass(parent._props.ClassName, "GuiBase2d") then
			if parentDependsOnChildren(parent) then
				root = parent
				cur = parent
			else
				break
			end
		else
			cur = parent
		end
	end
	return root
end

function flushLayouts(env: any?)
	local state = getLayoutState(env)
	if not state.hasDirty or state.flushing then return end
	state.flushing = true
	while state.hasDirty do
		state.hasDirty = false
		local order = state.dirtyOrder
		state.dirty = {}
		state.dirtyOrder = {}
		local roots: { [any]: boolean } = {}
		local rootOrder: { any } = {}
		for _, inst in order do
			if rawget(inst, "_destroyed") ~= true and rawget(inst, "_destroying") ~= true then
				local r = findLayoutRoot(inst)
				if not roots[r] then
					roots[r] = true
					table.insert(rootOrder, r)
				end
			end
		end
		for _, root in rootOrder do
			local hasAncestor = false
			local anc = rawget(root, "_parent")
			while anc ~= nil do
				if roots[anc] then
					hasAncestor = true
					break
				end
				anc = rawget(anc, "_parent")
			end
			if not hasAncestor then layoutSubtree(root, false) end
		end
	end
	state.flushing = false
end

function markGeomSig(inst: any)
	local env = rawget(inst, "_env")
	local state = getLayoutState(env)
	if state.hasDirty then flushLayouts(env) end
	state.anyGeomSig = true
	rawset(inst, "_hasGeomSig", true)
	local cur = inst
	while cur ~= nil and rawget(cur, "_subtreeGeomSig") ~= true do
		rawset(cur, "_subtreeGeomSig", true)
		cur = rawget(cur, "_parent")
	end
end

function relayout(inst: any)
	if rawget(inst, "_hasGui") ~= true or rawget(inst, "_destroyed") == true then return end
	local env = rawget(inst, "_env")
	local state = getLayoutState(env)
	if not state.dirty[inst] then
		state.dirty[inst] = true
		table.insert(state.dirtyOrder, inst)
	end
	state.hasDirty = true
	if state.anyGeomSig and rawget(findLayoutRoot(inst), "_subtreeGeomSig") == true then flushLayouts(env) end
end

InstanceDouble.flushLayouts = flushLayouts
InstanceDouble.relayout = function(inst: any)
	relayout(inst)
	flushLayouts(rawget(inst, "_env"))
end

--[=[
	Pins a GuiBase2d's AbsoluteSize and/or AbsolutePosition (a nil argument leaves that one computed; both nil unpins
	both) and re-lays out its descendants against the new values. Fires the property-changed signals of what moved.
]=]
function InstanceDouble.setAbsolute(inst: any, size: any?, position: any?)
	if
		type(inst) ~= "table"
		or rawget(inst, "_isInstance") ~= true
		or not isClass(inst._props.ClassName, "GuiBase2d")
	then
		error("setAbsolute: expected a GuiBase2d Instance", 2)
	end
	if size == nil and position == nil then
		rawset(inst, "_absPin", nil)
	else
		local pin = rawget(inst, "_absPin") or {}
		pin.size = size or pin.size
		pin.position = position or pin.position
		rawset(inst, "_absPin", pin)
	end
	relayout(inst)
end

-- How the selector engine reads an Instance double.
local EMPTY_LIST: { any } = table.freeze({} :: { any })
local selectorAccess: SelectorAccess = {
	isA = function(inst: any, className: string): boolean return inst:IsA(className) :: boolean end,
	name = function(inst: any): string return inst._props.Name end,
	hasTag = function(inst: any, tag: string): boolean
		local tags = rawget(inst, "_tags")
		return tags ~= nil and tags[tag] == true
	end,
	attribute = function(inst: any, name: string): any
		local attributes = rawget(inst, "_attributes")
		return if attributes ~= nil then attributes[name] else nil
	end,
	property = function(inst: any, name: string): any
		local env = rawget(inst, "_env")
		if GEOMETRY_PROPS[name] and getLayoutState(env).hasDirty then flushLayouts(env) end
		local value = inst._props[name]
		return if value == NONE then nil else value
	end,
	parent = function(inst: any): any return rawget(inst, "_parent") end,
	children = function(inst: any): { any } return rawget(inst, "_children") or EMPTY_LIST end,
}

local BaseMethods: { [string]: (self: any, ...any) -> ...any } = {}

function BaseMethods.IsA(self: any, targetClass: string): boolean
	local schema = CLASSES[self._props.ClassName]
	if schema ~= nil then return schema.is[targetClass] == true end
	return isClass(self._props.ClassName, targetClass)
end

function BaseMethods.GetFullName(self: any): string
	local env = rawget(self, "_env")
	local stopAt = if env ~= nil then env.game else nil
	local parts = { tostring(self._props.Name) }
	local cur = rawget(self, "_parent")
	while cur ~= nil and cur ~= stopAt do
		table.insert(parts, tostring(cur._props.Name))
		cur = rawget(cur, "_parent")
	end
	local n = #parts
	for i = 1, n // 2 do
		parts[i], parts[n - i + 1] = parts[n - i + 1], parts[i]
	end
	return table.concat(parts, ".")
end

function BaseMethods.GetChildren(self: any): { any }
	local children = rawget(self, "_children")
	return if children ~= nil then table.clone(children) else {}
end

function BaseMethods.GetDescendants(self: any): { any }
	local out = {}
	walkDescendants(self, out)
	return out
end

local function findChild(self: any, match: (any, string) -> boolean, target: string, recursive: boolean?): any
	local children = rawget(self, "_children")
	if children == nil then return nil end
	for _, child in children do
		if match(child, target) then return child end
	end
	if recursive then
		for _, child in children do
			local found = findChild(child, match, target, true)
			if found ~= nil then return found end
		end
	end
	return nil
end

local function matchName(inst: any, name: string): boolean return inst._props.Name == name end
local function matchClass(inst: any, cls: string): boolean return inst._props.ClassName == cls end

function BaseMethods.FindFirstChild(self: any, name: string, recursive: boolean?): any
	return findChild(self, matchName, name, recursive)
end

function BaseMethods.FindFirstChildOfClass(self: any, targetClass: string, recursive: boolean?): any
	return findChild(self, matchClass, targetClass, recursive)
end

function BaseMethods.FindFirstChildWhichIsA(self: any, targetClass: string, recursive: boolean?): any
	return findChild(self, BaseMethods.IsA, targetClass, recursive)
end

function BaseMethods.FindFirstAncestor(self: any, name: string): any return findAncestor(self, matchName, name) end

function BaseMethods.FindFirstAncestorOfClass(self: any, targetClass: string): any
	return findAncestor(self, matchClass, targetClass)
end

function BaseMethods.FindFirstAncestorWhichIsA(self: any, targetClass: string): any
	return findAncestor(self, BaseMethods.IsA, targetClass)
end

function BaseMethods.WaitForChild(self: any, name: string, timeOut: number?): any
	local found = BaseMethods.FindFirstChild(self, name)
	if found ~= nil then return found end
	local env = rawget(self, "_env")
	if env ~= nil then
		local resolveMounted: ((any, string) -> any)? = env._resolveMountedServerChild
		if resolveMounted ~= nil then
			found = resolveMounted(self, name)
			if found ~= nil then return found end
		end
	end
	if env == nil then
		if not coroutine.isyieldable() then return nil end
		local arrived = Signal.new()
		local conn = self.ChildAdded:Connect(function(child: any)
			if child._props.Name == name then arrived:Fire(child) end
		end)
		local result = arrived:Wait()
		conn:Disconnect()
		return result
	end
	local makeImmediate: ((any) -> any)? = env._immediateSignal
	local arrived = if makeImmediate ~= nil then makeImmediate(env) else env:signal()
	local conn = self.ChildAdded:Connect(function(child: any)
		if child._props.Name == name then arrived:Fire(child) end
	end)
	local timer: thread? = nil
	local warnTimer: thread? = nil
	if timeOut ~= nil then
		timer = env.task.delay(timeOut, function()
			timer = nil
			arrived:Fire(nil)
		end)
	else
		warnTimer = env.task.delay(5, function()
			warnTimer = nil
			if BaseMethods.FindFirstChild(self, name) == nil then
				local warnFn: ((...any) -> ())? = (if env.globals ~= nil then env.globals.warn else nil) or env._warn
				if warnFn ~= nil then
					warnFn(`Infinite yield possible on '{self:GetFullName()}:WaitForChild("{name}")'`)
				end
			end
		end)
	end
	local failure: string? = nil
	while true do
		local ok, result = pcall(arrived.Wait, arrived)
		if ok then
			found = result
			break
		end
		failure = tostring(result)
		local canContinue = timer ~= nil or (env._canStep ~= nil and env._canStep())
		if not canContinue or string.find(failure :: string, "did not fire within", 1, true) == nil then break end
		failure = nil
	end
	conn:Disconnect()
	if timer ~= nil then env.task.cancel(timer) end
	if warnTimer ~= nil then env.task.cancel(warnTimer) end
	if failure ~= nil then
		local reason = string.match(failure, "Signal:Wait%(%): (.*)$")
		if reason == nil then
			error(failure, 0)
		elseif string.find(reason, "nothing scheduled", 1, true) ~= nil then
			reason = "nothing scheduled can add it (pass a timeout, or add the child before waiting)"
		else
			reason = (string.gsub(reason, "^the signal did not fire", "it did not arrive"))
		end
		error(`WaitForChild("{name}") on {self:GetFullName()}: {reason}`, 2)
	end
	return found
end

function BaseMethods.IsDescendantOf(self: any, ancestor: any): boolean
	return findAncestor(self, rawequal, ancestor) ~= nil
end

function BaseMethods.IsAncestorOf(self: any, descendant: any): boolean
	return type(descendant) == "table"
		and rawget(descendant, "_isInstance") == true
		and BaseMethods.IsDescendantOf(descendant, self)
end

function BaseMethods.QueryDescendants(self: any, selector: string): { any }
	return Selector.query(self, selector, selectorAccess)
end

function BaseMethods.ClearAllChildren(self: any)
	local children = rawget(self, "_children")
	if children ~= nil then
		for _, child in table.clone(children) :: { any } do
			if rawget(child, "_parent") == self then child:Destroy() end
		end
	end
end

local function disconnectAllNodeSignals(node: any)
	local sigs = rawget(node, "_signals")
	if sigs ~= nil then
		for _, sig in sigs do
			if Signal.is(sig) then sig:DisconnectAll() end
		end
	end
	for _, propVal in node._props do
		if Signal.is(propVal) then propVal:DisconnectAll() end
	end
	for _, field in { "_propSignals", "_attrSignals" } do
		local map = rawget(node, field)
		if map ~= nil then
			for _, sig in map do
				sig:DisconnectAll()
			end
		end
	end
end

local function destroyNode(self: any, parentDestroying: boolean?)
	local env = rawget(self, "_env")
	if isLockedService(self, env) then
		local cur = parentNameOf(rawget(self, "_parent"))
		error(`The Parent property of {self._props.Name} is locked, current parent: {cur}, new parent NULL`, 3)
	end
	if rawget(self, "_destroyed") == true or rawget(self, "_destroying") == true then return end
	rawset(self, "_destroying", true)
	local sigs = rawget(self, "_signals")
	if sigs ~= nil and sigs.Destroying ~= nil then sigs.Destroying:Fire() end
	local oldParent = rawget(self, "_parent")
	if oldParent ~= nil then
		if not parentDestroying then
			setParent(self, nil, true)
		else
			-- Tear down inner child links directly without spurious per-descendant Changed("Parent") or ChildRemoved cascades.
			rawset(self, "_reparentGen", (rawget(self, "_reparentGen") or 0) + 1)
			local oldChildren = rawget(oldParent, "_children")
			if oldChildren ~= nil then
				local idx = table.find(oldChildren, self)
				if idx ~= nil then table.remove(oldChildren, idx) end
			end
			rawset(self, "_parent", nil)
		end
	end
	-- Destroyed instances retain HasTag/GetTags locally, while leaving CollectionService's DataModel tag lists.
	local tags = rawget(self, "_tags")
	if tags ~= nil and env ~= nil then
		for tag in tags do
			local list = env._tags[tag]
			local idx = if list ~= nil then table.find(list, self) else nil
			if idx ~= nil then table.remove(list, idx) end
		end
	end
	local children = rawget(self, "_children")
	if children ~= nil then
		for _, child in table.clone(children) :: { any } do
			if rawget(child, "_parent") == self then destroyNode(child, true) end
		end
	end
	if env ~= nil and env._focusedBox == self then env._focusedBox = nil end
	rawset(self, "_destroyed", true)
	rawset(self, "_destroying", nil)
	self._props.OnServerInvoke = nil
	self._props.OnClientInvoke = nil
	for _, field in { "_boundServerChannels", "_boundClientChannels" } do
		local bound = rawget(self, field)
		if bound ~= nil then
			for _, conn in bound do
				conn:Disconnect()
			end
			table.clear(bound)
		end
	end
	local boundRpcName = rawget(self, "_boundRpcName")
	local boundRpcCb = rawget(self, "_boundRpcCb")
	if boundRpcName ~= nil and boundRpcCb ~= nil and env ~= nil then
		local net = env.peerBridge
		if net == nil then
			local srv = env.server or (if env.client then env.client.server else nil)
			net = if srv ~= nil then srv._net else nil
		end
		if net ~= nil and net.rpc ~= nil then
			local rpc = net:rpc(boundRpcName, env.client)
			if rpc ~= nil then
				if env.client == nil and rpc.OnServerInvoke == boundRpcCb then
					rpc.OnServerInvoke = nil
				elseif env.client ~= nil and rpc.OnClientInvoke == boundRpcCb then
					rpc.OnClientInvoke = nil
				end
			end
		end
		rawset(self, "_boundRpcName", nil)
		rawset(self, "_boundRpcCb", nil)
	end
	local deferSignalFn: (((...any) -> (), ...any) -> ())? = if env ~= nil then env._deferSignal else nil
	if deferSignalFn ~= nil then
		-- Disconnect non-destroy signals immediately while deferring final disconnection until queued Destroy events drain.
		sigs = rawget(self, "_signals")
		if sigs ~= nil then
			for key, sig in sigs do
				if
					key ~= "Destroying"
					and key ~= "AncestryChanged"
					and (parentDestroying or key ~= "Changed")
					and Signal.is(sig)
				then
					sig:DisconnectAll()
				end
			end
		end
		for _, propVal in self._props do
			if Signal.is(propVal) then propVal:DisconnectAll() end
		end
		local propMap = rawget(self, "_propSignals")
		if propMap ~= nil then
			for propKey, sig in propMap do
				if parentDestroying or propKey ~= "Parent" then sig:DisconnectAll() end
			end
		end
		local attrMap = rawget(self, "_attrSignals")
		if attrMap ~= nil then
			for _, sig in attrMap do
				sig:DisconnectAll()
			end
		end
		deferSignalFn(disconnectAllNodeSignals, self)
	else
		disconnectAllNodeSignals(self)
	end
	if env ~= nil then
		local onDestroy: ((any) -> ())? = env._onDestroy
		if onDestroy ~= nil then onDestroy(self) end
	end
end

function BaseMethods.Destroy(self: any) destroyNode(self, false) end

local function copyAttributeOrPropValue(val: any): any
	return Util.copy(val, {
		map = function(v: any): (boolean, any)
			local kind = customTypeof(v)
			if kind ~= "table" and type(v) ~= "buffer" then return true, v end
			return false, nil
		end,
	})
end

-- A copy of `self` alone: its properties (Instance references left at their defaults), attributes and tags.
local function copyNode(self: any): any
	local props = self._props
	local copy = InstanceDouble.createInstance(rawget(self, "_env"), props.ClassName, nil, true)
	for k, v in props do
		if k ~= "ClassName" and k ~= "Parent" and v ~= NONE then
			local kind = customTypeof(v)
			if kind ~= "RBXScriptSignal" and kind ~= "Instance" then
				if kind == "table" or type(v) == "buffer" then
					copy._props[k] = copyAttributeOrPropValue(v)
				else
					copy._props[k] = v
				end
			end
		end
	end
	local attrs = rawget(self, "_attributes")
	if attrs ~= nil then
		local clonedAttrs: { [string]: any } = {}
		for attr, val in attrs do
			clonedAttrs[attr] = copyAttributeOrPropValue(val)
		end
		rawset(copy, "_attributes", clonedAttrs)
	end
	local tags = rawget(self, "_tags")
	if tags ~= nil then
		local tagOrder = rawget(self, "_tagOrder")
		local orderedTags: { string } = {}
		for tag in tags do
			table.insert(orderedTags, tag)
		end
		table.sort(orderedTags, function(a: string, b: string): boolean
			local oa = if tagOrder ~= nil then tagOrder[a] or math.huge else math.huge
			local ob = if tagOrder ~= nil then tagOrder[b] or math.huge else math.huge
			if oa ~= ob then return oa < ob end
			return a < b
		end)
		for _, tag in orderedTags do
			BaseMethods.AddTag(copy, tag)
		end
	end
	rawset(copy, "_factory", rawget(self, "_factory"))
	rawset(copy, "_loader", rawget(self, "_loader"))
	return copy
end

local function cloneSubtree(self: any, clonedMap: { [any]: any }): any
	if self._props.Archivable == false then return nil end
	local copy = copyNode(self)
	clonedMap[self] = copy
	local children = rawget(self, "_children")
	if children ~= nil then
		for _, child in children do
			local childCopy = cloneSubtree(child, clonedMap)
			if childCopy ~= nil then childCopy.Parent = copy end
		end
	end
	return copy
end

function BaseMethods.Clone(self: any): any
	local env = rawget(self, "_env")
	if rawget(self, "_hasGui") == true and getLayoutState(env).hasDirty then flushLayouts(env) end
	local clonedMap: { [any]: any } = {}
	local rootCopy = cloneSubtree(self, clonedMap)
	if rootCopy == nil then return nil end
	for srcInst, copyInst in clonedMap do
		for k, v in srcInst._props do
			if k ~= "ClassName" and k ~= "Parent" and customTypeof(v) == "Instance" then
				copyInst._props[k] = clonedMap[v] or v
			end
		end
		local copyAttrs = rawget(copyInst, "_attributes")
		if copyAttrs ~= nil then
			for attr, val in copyAttrs do
				if customTypeof(val) == "Instance" then copyAttrs[attr] = clonedMap[val] or val end
			end
		end
	end
	if isClass(rootCopy._props.ClassName, "GuiBase2d") then relayout(rootCopy) end
	return rootCopy
end

--- `Instance.fromExisting(existing)`: a copy of `existing` without its descendants, whatever its Archivable.
function InstanceDouble.fromExisting(existing: any): any
	local env = rawget(existing, "_env")
	if rawget(existing, "_hasGui") == true and getLayoutState(env).hasDirty then flushLayouts(env) end
	local copy = copyNode(existing)
	for k, v in existing._props do
		if k ~= "ClassName" and k ~= "Parent" and customTypeof(v) == "Instance" then copy._props[k] = v end
	end
	if isClass(copy._props.ClassName, "GuiBase2d") then relayout(copy) end
	return copy
end

function BaseMethods.GetPropertyChangedSignal(self: any, prop: string): any
	local env = rawget(self, "_env")
	if isStrictEnv(env) then
		local schema = CLASSES[self._props.ClassName]
		local member = if schema ~= nil then schema.members[prop] else nil
		if member == nil or member.kind ~= "property" then error(`{prop} is not a valid property name.`, 2) end
	end
	if GEOMETRY_PROPS[prop] and rawget(self, "_isGui") == true then markGeomSig(self) end
	local pSigs = rawget(self, "_propSignals")
	if pSigs == nil then
		pSigs = {}
		rawset(self, "_propSignals", pSigs)
	end
	local sig = pSigs[prop]
	if sig == nil then
		sig = makeEnvSignal(env)
		pSigs[prop] = sig
	end
	return sig
end

function BaseMethods.GetAttribute(self: any, attr: string): any
	local attrs = rawget(self, "_attributes")
	return if attrs ~= nil then attrs[attr] else nil
end

function BaseMethods.SetAttribute(self: any, attr: string, value: any)
	if
		type(attr) ~= "string"
		or not string.match(attr, "^[%w_%.%-/]+$")
		or #attr > 100
		or string.sub(attr, 1, 3) == "RBX"
	then
		error(`Attribute name "{tostring(attr)}" is invalid`, 2)
	end
	local kind = customTypeof(value)
	if value ~= nil and not ATTRIBUTE_TYPES[kind] then error(`{kind} is not a supported attribute type`, 2) end
	local attrs = rawget(self, "_attributes")
	if attrs == nil then
		if value == nil then return end
		attrs = {}
		rawset(self, "_attributes", attrs)
	end
	local old = attrs[attr]
	if old ~= value then
		attrs[attr] = value
		local env = rawget(self, "_env")
		local aSigs = rawget(self, "_attrSignals")
		if aSigs ~= nil and aSigs[attr] ~= nil then aSigs[attr]:Fire() end
		fireIfConnected(rawget(self, "_signals"), "AttributeChanged", attr)
		if env ~= nil then
			local onAttrSet: ((any, string, any) -> ())? = env._onAttrSet
			if onAttrSet ~= nil then onAttrSet(self, attr, value) end
		end
	end
end

function BaseMethods.GetAttributes(self: any): { [string]: any }
	local attrs = rawget(self, "_attributes")
	return if attrs ~= nil then table.clone(attrs) else {}
end

function BaseMethods.GetAttributeChangedSignal(self: any, attr: string): any
	local aSigs = rawget(self, "_attrSignals")
	if aSigs == nil then
		aSigs = {}
		rawset(self, "_attrSignals", aSigs)
	end
	local sig = aSigs[attr]
	if sig == nil then
		sig = makeEnvSignal(rawget(self, "_env"))
		aSigs[attr] = sig
	end
	return sig
end

function BaseMethods.AddTag(self: any, tag: string)
	local tags = rawget(self, "_tags")
	if tags == nil then
		tags = {}
		rawset(self, "_tags", tags)
	end
	if not tags[tag] then
		tags[tag] = true
		local env = rawget(self, "_env")
		local tagOrder = rawget(self, "_tagOrder")
		if tagOrder == nil then
			tagOrder = {}
			rawset(self, "_tagOrder", tagOrder)
		end
		local seq = (if env ~= nil then (env._tagSeq or 0) else 0) + 1
		if env ~= nil then env._tagSeq = seq end
		tagOrder[tag] = seq
		if env ~= nil then
			if not rawget(self, "_destroyed") and isInDataModel(env, self) then
				env._tags[tag] = env._tags[tag] or {}
				table.insert(env._tags[tag], self)
				if env._tagAddedSignals[tag] ~= nil then env._tagAddedSignals[tag]:Fire(self) end
			end
			if env.onTagChange ~= nil then env.onTagChange(self, tag, true) end
		end
		local hooks = rawget(self, "_tagHooks")
		if hooks ~= nil then
			for _, fn in hooks do
				fn(tag, true)
			end
		end
	end
end

--- CollectionService:GetTagged for `env`: the instances tagged `tag` that are in the DataModel, in tagging order.
--- Tagged instances outside `env.game` (unparented or in a detached tree) are left out, as in Roblox.
function InstanceDouble.getTagged(env: any, tag: string): { any }
	local out = {}
	local list = env._tags[tag]
	if list ~= nil then
		local write = 1
		for read = 1, #list do
			local inst = list[read]
			local tags = rawget(inst, "_tags")
			if not rawget(inst, "_destroyed") and tags ~= nil and tags[tag] and isInDataModel(env, inst) then
				if write ~= read then list[write] = inst end
				write += 1
				table.insert(out, inst)
			end
		end
		for idx = write, #list do
			list[idx] = nil
		end
	end
	return out
end

function BaseMethods.RemoveTag(self: any, tag: string)
	local tags = rawget(self, "_tags")
	if tags ~= nil and tags[tag] then
		tags[tag] = nil
		local tagOrder = rawget(self, "_tagOrder")
		if tagOrder ~= nil then tagOrder[tag] = nil end
		local env = rawget(self, "_env")
		if env ~= nil then
			local list = env._tags[tag]
			if list ~= nil then
				local idx = table.find(list, self)
				if idx ~= nil then table.remove(list, idx) end
			end
			if env._tagRemovedSignals[tag] ~= nil and isInDataModel(env, self) then
				env._tagRemovedSignals[tag]:Fire(self)
			end
			if env.onTagChange ~= nil then env.onTagChange(self, tag, false) end
		end
		local hooks = rawget(self, "_tagHooks")
		if hooks ~= nil then
			for _, fn in hooks do
				fn(tag, false)
			end
		end
	end
end

function BaseMethods.HasTag(self: any, tag: string): boolean
	local tags = rawget(self, "_tags")
	return tags ~= nil and tags[tag] == true
end

function BaseMethods.GetTags(self: any): { string }
	local tags = rawget(self, "_tags")
	if tags == nil then return {} end
	local out = {}
	for tag in tags do
		table.insert(out, tag)
	end
	table.sort(out)
	return out
end

-- Shared Class-Specific Methods --------------------------------------------------------------------------------------

local function setCoupledProp(self: any, key: string, value: any)
	local prev = self._props[key]
	if prev == NONE then prev = nil end
	if prev ~= value then
		self._props[key] = value
		firePropChanged(self, key, value)
		local env = rawget(self, "_env")
		local onPropChange: ((any, any, any) -> ())? = if env ~= nil then env._onPropChange else nil
		if onPropChange ~= nil then onPropChange(self, key, value) end
	end
end

local ModelMethods = {
	GetPivot = function(self: any): any
		local pp: any = self._props.PrimaryPart
		if pp ~= nil and pp ~= NONE then return pp.CFrame end
		return self._props.WorldPivot or CFrame.identity
	end,
	PivotTo = function(self: any, cf: any)
		local oldPivot = self:GetPivot()
		setCoupledProp(self, "WorldPivot", cf)
		local pp: any = self._props.PrimaryPart
		if pp == NONE then pp = nil end
		local movedPp = false
		if customTypeof(oldPivot) == "CFrame" and customTypeof(cf) == "CFrame" then
			for _, desc in BaseMethods.GetDescendants(self) do
				if BaseMethods.IsA(desc, "BasePart") and customTypeof(desc.CFrame) == "CFrame" then
					if desc == pp then
						movedPp = true
						desc.CFrame = cf
					else
						desc.CFrame = cf:ToWorldSpace(oldPivot:ToObjectSpace(desc.CFrame))
					end
				end
			end
		end
		if pp ~= nil and not movedPp then pp.CFrame = cf end
	end,
	GetBoundingBox = function(_self: any): (any, any) return CFrame.identity, Vector3.new(4, 5, 2) end,
	GetExtentsSize = function(_self: any): any return Vector3.new(4, 5, 2) end,
	MoveTo = function(self: any, pos: any) self:PivotTo(self:GetPivot().Rotation + pos) end,
	ScaleTo = function(self: any, scale: number) self._props._scale = scale end,
	GetScale = function(self: any): number return self._props._scale or 1 end,
}

local BasePartMethods = {
	GetPivot = function(self: any): any return self._props.CFrame end,
	PivotTo = function(self: any, cf: any) self.CFrame = cf end,
	GetMass = function(self: any): number
		local s = self._props.Size
		return s.X * s.Y * s.Z
	end,
	ApplyImpulse = function(self: any, impulse: any)
		local cur = self._props.AssemblyLinearVelocity or Vector3.zero
		setCoupledProp(self, "AssemblyLinearVelocity", cur + impulse)
		self._props._lastImpulse = impulse
	end,
	SetNetworkOwner = function(_self: any, _player: any?) end,
	GetNetworkOwner = function(_self: any): any return nil end,
}

-- After a Humanoid's Health changes: fire HealthChanged, and on the first drop to 0 enter the Dead state (firing
-- StateChanged) and fire Died once. Health later rising above 0 does not revive it, as in Roblox.
local function humanoidHealthChanged(self: any, health: any)
	local sigs = rawget(self, "_signals")
	fireIfConnected(sigs, "HealthChanged", health)
	if type(health) == "number" and health <= 0 and rawget(self, "_died") ~= true then
		rawset(self, "_died", true)
		local props = self._props
		local oldState = props._state or Enum.HumanoidStateType.Running
		local dead = Enum.HumanoidStateType.Dead
		props._state = dead
		if oldState ~= dead then fireIfConnected(sigs, "StateChanged", oldState, dead) end
		fireIfConnected(sigs, "Died")
	end
end

local HumanoidMethods = {
	TakeDamage = function(self: any, amount: number) self.Health = math.max(0, (self._props.Health or 100) - amount) end,
	MoveTo = function(self: any, location: any, part: any?)
		setCoupledProp(self, "WalkToPoint", location)
		setCoupledProp(self, "WalkToPart", part)
		getSignal(self, "MoveToFinished"):Fire(true)
	end,
	ChangeState = function(self: any, state: any)
		local oldState = self._props._state or Enum.HumanoidStateType.Running
		self._props._state = state
		local sigs = rawget(self, "_signals")
		if oldState ~= state then fireIfConnected(sigs, "StateChanged", oldState, state) end
		if state == Enum.HumanoidStateType.Dead and rawget(self, "_died") ~= true then
			rawset(self, "_died", true)
			fireIfConnected(sigs, "Died")
		end
	end,
	GetState = function(self: any): any return self._props._state or Enum.HumanoidStateType.Running end,
	ApplyDescription = function(self: any, desc: any)
		self._props._appliedDescription = desc
		self._props._description = desc
	end,
	ApplyDescriptionReset = function(self: any, desc: any)
		self._props._appliedDescription = desc
		self._props._description = desc
	end,
	GetAppliedDescription = function(self: any): any
		local desc = self._props._appliedDescription or self._props._description
		if desc == nil then
			desc = InstanceDouble.createInstance(rawget(self, "_env"), "HumanoidDescription", nil, true)
			self._props._appliedDescription = desc
		end
		return desc
	end,
	GetAccessories = function(self: any): { any }
		local out = {}
		local seen: { [any]: boolean } = {}
		local parent = rawget(self, "_parent")
		if parent ~= nil then
			for _, child in parent:GetChildren() do
				if child._props.ClassName == "Accessory" and not seen[child] then
					seen[child] = true
					table.insert(out, child)
				end
			end
		end
		for _, child in self:GetChildren() do
			if child._props.ClassName == "Accessory" and not seen[child] then
				seen[child] = true
				table.insert(out, child)
			end
		end
		return out
	end,
	AddAccessory = function(self: any, acc: any) acc.Parent = rawget(self, "_parent") or self end,
	RemoveAccessories = function(self: any)
		for _, acc in self:GetAccessories() do
			acc.Parent = nil
		end
	end,
}

local HumanoidDescriptionMethods = {
	GetAccessories = function(self: any, _includeRigid: boolean?): { any } return self._props._accessories or {} end,
	SetAccessories = function(self: any, list: { any }, _includeRigid: boolean?) self._props._accessories = list end,
}

local TextBoxMethods = {
	IsFocused = function(self: any): boolean
		local env = rawget(self, "_env")
		if env ~= nil then return env._focusedBox == self end
		return self._props._focused == true
	end,
	CaptureFocus = function(self: any)
		local env = rawget(self, "_env")
		if env ~= nil then
			if env._focusedBox == self then return end
			local prev = env._focusedBox
			env._focusedBox = self
			if prev ~= nil then
				prev._props._focused = false
				getSignal(prev, "FocusLost"):Fire(false)
			end
		end
		self._props._focused = true
		getSignal(self, "Focused"):Fire()
	end,
	ReleaseFocus = function(self: any, submitted: boolean?)
		local env = rawget(self, "_env")
		if env ~= nil then
			if env._focusedBox == self then
				env._focusedBox = nil
			elseif isStrictEnv(env) then
				return
			end
		end
		self._props._focused = false
		getSignal(self, "FocusLost"):Fire(submitted == true)
	end,
}

local SoundMethods = {
	Play = function(self: any) setCoupledProp(self, "Playing", true) end,
	Stop = function(self: any)
		setCoupledProp(self, "Playing", false)
		getSignal(self, "Stopped"):Fire(self._props.SoundId)
	end,
	Pause = function(self: any) setCoupledProp(self, "Playing", false) end,
	Resume = function(self: any) setCoupledProp(self, "Playing", true) end,
}

local function cameraProject(self: any, v: any): (any, boolean)
	local cf = self._props.CFrame or CFrame.identity
	local vp = if rawget(self, "_viewportSet")
		then (self._props.ViewportSize or Vector2.new(1280, 720))
		else Vector2.new(1280, 720)
	local rel = cf:PointToObjectSpace(v)
	local depth = -rel.Z
	local sx = vp.X * 0.5 + rel.X
	local sy = vp.Y * 0.5 - rel.Y
	local onScreen = depth > 0 and sx >= 0 and sx <= vp.X and sy >= 0 and sy <= vp.Y
	return Vector3.new(sx, sy, depth), onScreen
end

local function cameraPointToRay(self: any, x: number, y: number, depth: number?): any
	local cf = self._props.CFrame or CFrame.identity
	local d = depth or 0
	local origin = cf.Position + Vector3.new(x, y, d)
	return Ray.new(origin, cf.LookVector)
end

local CameraMethods = {
	WorldToViewportPoint = cameraProject,
	WorldToScreenPoint = cameraProject,
	ViewportPointToRay = cameraPointToRay,
	ScreenPointToRay = cameraPointToRay,
}

local HapticEffectMethods = {
	SetWaveformKeys = function(self: any, keys: { any }) self._props._waveformKeys = keys end,
	Play = function(self: any) setCoupledProp(self, "Playing", true) end,
	Stop = function(self: any) setCoupledProp(self, "Playing", false) end,
}

local BasePlayerGuiMethods = {
	GetGuiObjectsAtPosition = function(self: any, x: number, y: number): { any }
		local env = rawget(self, "_env")
		local selfProps: { [string]: any } = rawget(self, "_props") :: any
		if getLayoutState(env).hasDirty then flushLayouts(env) end
		if BaseMethods.IsA(self, "LayerCollector") and selfProps.Enabled == false then return {} end
		if BaseMethods.IsA(self, "GuiObject") then
			if not selfProps.Visible then return {} end
			if selfProps.ClipsDescendants == true or BaseMethods.IsA(self, "ScrollingFrame") then
				local sPos, sSize = selfProps.AbsolutePosition, selfProps.AbsoluteSize
				if x < sPos.X or x > sPos.X + sSize.X or y < sPos.Y or y > sPos.Y + sSize.Y then return {} end
			end
		end
		local out = {}
		for _, desc in BaseMethods.GetDescendants(self) do
			if desc:IsA("GuiObject") and desc.Visible then
				local visible = true
				local cur = rawget(desc, "_parent")
				while cur ~= nil and cur ~= self do
					if
						(cur:IsA("GuiObject") and not cur.Visible) or (cur:IsA("LayerCollector") and not cur.Enabled)
					then
						visible = false
						break
					end
					if cur:IsA("GuiObject") and (cur.ClipsDescendants == true or cur:IsA("ScrollingFrame")) then
						local cPos = cur.AbsolutePosition
						local cSize = cur.AbsoluteSize
						if x < cPos.X or x > cPos.X + cSize.X or y < cPos.Y or y > cPos.Y + cSize.Y then
							visible = false
							break
						end
					end
					cur = rawget(cur, "_parent")
				end
				if visible then
					local pos = desc.AbsolutePosition
					local size = desc.AbsoluteSize
					if x >= pos.X and x <= pos.X + size.X and y >= pos.Y and y <= pos.Y + size.Y then
						table.insert(out, desc)
					end
				end
			end
		end
		return out
	end,
}

local function stepUIPageLayout(self: any, delta: number)
	local parent = rawget(self, "_parent")
	if parent == nil then return end
	local pages = {}
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then table.insert(pages, child) end
	end
	local cur = table.find(pages, self._props.CurrentPage) or 1
	if pages[cur + delta] ~= nil then self:JumpTo(pages[cur + delta]) end
end

local UIPageLayoutMethods = {
	JumpTo = function(self: any, page: any)
		local prev = self._props.CurrentPage
		if prev ~= page then
			if prev ~= nil and prev ~= NONE then getSignal(self, "PageLeave"):Fire(prev) end
			if page ~= nil and page ~= NONE then
				getSignal(self, "PageEnter"):Fire(page)
				getSignal(self, "Stopped"):Fire(page)
			end
			setCoupledProp(self, "CurrentPage", page)
		end
	end,
	JumpToIndex = function(self: any, index: number)
		local parent = rawget(self, "_parent")
		if parent == nil then return end
		local idx = 0
		for _, child in parent:GetChildren() do
			if child:IsA("GuiObject") then
				if idx == index then
					self:JumpTo(child)
					return
				end
				idx += 1
			end
		end
	end,
	Next = function(self: any) stepUIPageLayout(self, 1) end,
	Previous = function(self: any) stepUIPageLayout(self, -1) end,
}

local TextChannelMethods = {
	AddUserAsync = function(self: any, userId: number): (any, boolean)
		local env = rawget(self, "_env")
		local name = tostring(userId)
		local existing = self:FindFirstChild(name)
		if existing ~= nil then return existing, true end
		local source = InstanceDouble.createInstance(env, "TextSource", self, true)
		source.Name = name
		source._props.UserId = userId
		source.CanSend = true
		return source, true
	end,
	SetDirectChatRequester = function(self: any, player: any) setCoupledProp(self, "DirectChatRequester", player) end,
	GetDirectChatRequester = function(self: any): any
		local val = self._props.DirectChatRequester
		return if val == NONE then nil else val
	end,
	SendAsync = function(self: any, text: string, metadata: string?): any
		local env = rawget(self, "_env")
		local senderId = if env ~= nil and env.LocalPlayer ~= nil then env.LocalPlayer.UserId else 1
		local source = self:FindFirstChild(tostring(senderId))
		if source == nil then
			source = InstanceDouble.createInstance(env, "TextSource", nil, true)
			source._props.UserId = senderId
			source.CanSend = true
		end
		local msg = {
			Text = tostring(text or ""),
			PrefixText = "",
			Metadata = tostring(metadata or ""),
			Status = Enum.TextChatMessageStatus.Success,
			TextChannel = self,
			TextSource = source,
			MessageId = "msg-1",
			Translation = "",
		}
		local shouldDeliver: any = self._props.ShouldDeliverCallback
		if type(shouldDeliver) == "function" then
			if (shouldDeliver :: (any, any) -> any)(msg, source) == false then return msg end
		end
		local function applyIncomingHook(cb: any)
			if type(cb) == "function" then
				local props: any = (cb :: (any) -> any)(msg)
				if type(props) == "table" then
					if props.Text ~= nil and props.Text ~= "" then msg.Text = tostring(props.Text) end
					if props.PrefixText ~= nil and props.PrefixText ~= "" then
						msg.PrefixText = tostring(props.PrefixText)
					end
				end
			end
		end
		applyIncomingHook(self._props.OnIncomingMessage)
		if env ~= nil then
			local services: { [string]: any }? = rawget(env, "_services")
			local ctx: { getService: ((string) -> any)? }? = rawget(env, "_ctx")
			local tcs = if services ~= nil and services.TextChatService ~= nil
				then services.TextChatService
				elseif ctx ~= nil and ctx.getService ~= nil then ctx.getService("TextChatService")
				else nil
			if tcs ~= nil then
				applyIncomingHook(tcs._props.OnIncomingMessage)
				getSignal(tcs, "SendingMessage"):Fire(msg)
				getSignal(tcs, "MessageReceived"):Fire(msg)
			end
		end
		getSignal(self, "MessageReceived"):Fire(msg)
		return msg
	end,
	DisplaySystemMessage = function(self: any, systemMessage: string, metadata: string?): any
		local msg = {
			Text = tostring(systemMessage or ""),
			PrefixText = "",
			Metadata = tostring(metadata or ""),
			Status = Enum.TextChatMessageStatus.Success,
			TextChannel = self,
			TextSource = nil,
			MessageId = "sys-1",
			Translation = "",
		}
		getSignal(self, "MessageReceived"):Fire(msg)
		return msg
	end,
}

local BindableEventMethods = {
	Fire = function(self: any, ...: any) self.Event:Fire(...) end,
}

local BindableFunctionMethods = {
	Invoke = function(self: any, ...: any): ...any
		local onInvoke: ((...any) -> ...any)? = self._props.OnInvoke
		if onInvoke ~= nil then return onInvoke(...) end
		return nil
	end,
}

-- Dynamic RemoteEvent / UnreliableRemoteEvent / RemoteFunction methods (never freeze channel name before .Name is set!)
local function getNetFor(inst: any): (any?, any?)
	local env = rawget(inst, "_env")
	if env == nil then return nil, nil end
	if env.peerBridge ~= nil then return env.peerBridge, env.client end
	local srv = env.server or (if env.client then env.client.server else nil)
	if srv == nil then return nil, nil end
	if srv._net == nil and env.world ~= nil then srv._net = env.world:remotes(srv) end
	return srv._net, env.client
end

local function ensureRemoteBound(inst: any)
	local className = inst._props.ClassName
	if className ~= "RemoteEvent" and className ~= "UnreliableRemoteEvent" and className ~= "RemoteFunction" then
		return
	end
	local name = inst._props.Name
	local net, client = getNetFor(inst)
	if net == nil then return end
	if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
		local unreliable = className == "UnreliableRemoteEvent"
		local ch = net:channel(name, unreliable, client)
		if ch == nil then return end
		local sigs = rawget(inst, "_signals")
		if sigs ~= nil then
			local function bindChannelSignal(eventName: string, mapField: string)
				local sig = sigs[eventName]
				local chSig = ch[eventName]
				if sig == nil or chSig == nil then return end
				local boundMap = rawget(inst, mapField)
				if boundMap == nil then
					boundMap = {}
					rawset(inst, mapField, boundMap)
				else
					for boundName, conn in boundMap do
						if boundName ~= name then
							conn:Disconnect()
							boundMap[boundName] = nil
						end
					end
				end
				if not boundMap[name] then
					boundMap[name] = chSig:Connect(function(...: any)
						if inst._props.Name == name and not rawget(inst, "_destroyed") then sig:Fire(...) end
					end)
				end
			end
			if client == nil then
				bindChannelSignal("OnServerEvent", "_boundServerChannels")
			else
				bindChannelSignal("OnClientEvent", "_boundClientChannels")
			end
		end
	elseif className == "RemoteFunction" then
		local prevName = rawget(inst, "_boundRpcName")
		local prevCb = rawget(inst, "_boundRpcCb")
		if prevName ~= nil and prevName ~= name and prevCb ~= nil then
			local prevRpc = net:rpc(prevName, client)
			if prevRpc ~= nil then
				if client == nil and prevRpc.OnServerInvoke == prevCb then
					prevRpc.OnServerInvoke = nil
				elseif client ~= nil and prevRpc.OnClientInvoke == prevCb then
					prevRpc.OnClientInvoke = nil
				end
			end
		end
		local rawCb = if client == nil then inst._props.OnServerInvoke else inst._props.OnClientInvoke
		if rawCb ~= nil or prevCb ~= nil then
			local rpc = net:rpc(name, client)
			if rpc ~= nil then
				local wrapped: ((...any) -> ...any)? = nil
				if rawCb ~= nil and not rawget(inst, "_destroyed") then
					wrapped = function(...: any): ...any
						if rawget(inst, "_destroyed") or inst._props.Name ~= name then return nil end
						local cb: ((...any) -> ...any)? = if client == nil
							then inst._props.OnServerInvoke
							else inst._props.OnClientInvoke
						if cb == nil then return nil end
						return cb(...)
					end
				end
				rawset(inst, "_boundRpcName", name)
				rawset(inst, "_boundRpcCb", wrapped)
				if client == nil then
					rpc.OnServerInvoke = wrapped
				else
					rpc.OnClientInvoke = wrapped
				end
			end
		end
	end
end

InstanceDouble.ensureRemoteBound = ensureRemoteBound

local function remoteChannel(self: any): (any, any)
	local net, client = getNetFor(self)
	if net ~= nil then
		return net:channel(self._props.Name, self._props.ClassName == "UnreliableRemoteEvent", client), client
	end
	return nil, nil
end

local function fireClientChannel(self: any, method: string, stripFirstOnFallback: boolean, ...: any)
	local ch: any = remoteChannel(self)
	local fn = if ch ~= nil then ch[method] else nil
	if fn ~= nil then
		fn(ch, ...)
		return
	end
	local env = rawget(self, "_env")
	local handler: ((any, string, ...any) -> ...any)? = if env ~= nil then env.remoteHandler else nil
	if stripFirstOnFallback then
		local player = select(1, ...)
		local packed, packedN = Serialize.remoteTuple({ allowInstances = true }, select(2, ...))
		if handler ~= nil then
			handler(self, method, player, table.unpack(packed, 1, packedN))
		else
			getSignal(self, "OnClientEvent"):Fire(table.unpack(packed, 1, packedN))
		end
	else
		local packed, packedN = Serialize.remoteTuple({ allowInstances = true }, ...)
		if handler ~= nil then
			handler(self, method, table.unpack(packed, 1, packedN))
		else
			getSignal(self, "OnClientEvent"):Fire(table.unpack(packed, 1, packedN))
		end
	end
end

local RemoteEventMethods = {
	FireServer = function(self: any, ...: any)
		local ch: any = remoteChannel(self)
		if ch ~= nil and ch.FireServer then
			(ch.FireServer :: any)(ch, ...)
		else
			local env = rawget(self, "_env")
			local packed, packedN = Serialize.remoteTuple({ allowInstances = true }, ...)
			local handler: ((any, string, ...any) -> ...any)? = if env ~= nil then env.remoteHandler else nil
			if handler ~= nil then
				handler(self, "FireServer", table.unpack(packed, 1, packedN))
			else
				getSignal(self, "OnServerEvent"):Fire(
					if env then env.LocalPlayer else nil,
					table.unpack(packed, 1, packedN)
				)
			end
		end
	end,
	FireClient = function(self: any, player: any, ...: any) fireClientChannel(self, "FireClient", true, player, ...) end,
	FireAllClients = function(self: any, ...: any) fireClientChannel(self, "FireAllClients", false, ...) end,
}

local function invokeRemote(self: any, method: string, prop: string, withPlayer: boolean, ...: any): ...any
	if rawget(self, "_destroyed") then return nil end
	local net, client = getNetFor(self)
	if net ~= nil and net.rpc ~= nil then
		local rpc: any = (net.rpc :: any)(net, self._props.Name, client)
		if rpc ~= nil and rpc[method] ~= nil then return (rpc[method] :: any)(rpc, ...) end
	end
	local env = rawget(self, "_env")
	local handler: ((any, string, ...any) -> ...any)? = if env ~= nil then env.remoteHandler else nil
	if handler ~= nil then
		if withPlayer then
			local req, reqN = Serialize.remoteTuple({ allowInstances = true }, ...)
			local res, resN =
				Serialize.remoteTuple({ allowInstances = true }, handler(self, method, table.unpack(req, 1, reqN)))
			return table.unpack(res, 1, resN)
		else
			local player = select(1, ...)
			local req, reqN = Serialize.remoteTuple({ allowInstances = true }, select(2, ...))
			local res, resN = Serialize.remoteTuple(
				{ allowInstances = true },
				handler(self, method, player, table.unpack(req, 1, reqN))
			)
			return table.unpack(res, 1, resN)
		end
	end
	local cb: ((...any) -> ...any)? = self._props[prop]
	if cb == nil then return nil end
	if withPlayer then
		local req, reqN = Serialize.remoteTuple({ allowInstances = true }, ...)
		local res, resN = Serialize.remoteTuple(
			{ allowInstances = true },
			cb(if env then env.LocalPlayer else nil, table.unpack(req, 1, reqN))
		)
		return table.unpack(res, 1, resN)
	end
	local req, reqN = Serialize.remoteTuple({ allowInstances = true }, select(2, ...))
	local res, resN = Serialize.remoteTuple({ allowInstances = true }, cb(table.unpack(req, 1, reqN)))
	return table.unpack(res, 1, resN)
end

local RemoteFunctionMethods = {
	InvokeServer = function(self: any, ...: any): ...any
		return invokeRemote(self, "InvokeServer", "OnServerInvoke", true, ...)
	end,
	InvokeClient = function(self: any, player: any, ...: any): ...any
		return invokeRemote(self, "InvokeClient", "OnClientInvoke", false, player, ...)
	end,
}

local APPEARANCE_CLASSES: { [string]: boolean } = {}
for _, k in string.split("Accessory Shirt Pants ShirtGraphic BodyColors CharacterMesh Decal", " ") do
	APPEARANCE_CLASSES[k] = true
end

local PlayerMethods = {
	GetRankInGroup = function(self: any, groupId: number): number
		local env = rawget(self, "_env")
		if env ~= nil and env.groups ~= nil then
			local g = env.groups[groupId]
			if g ~= nil and g.ranks ~= nil and g.ranks[self.UserId] ~= nil then return g.ranks[self.UserId] end
		end
		return 0
	end,
	GetRoleInGroup = function(self: any, groupId: number): string
		local rank = self:GetRankInGroup(groupId)
		if rank <= 0 then return "Guest" end
		-- The role `env:setGroupRank` recorded, else a name made from the rank.
		local env = rawget(self, "_env")
		local g = if env ~= nil and env.groups ~= nil then env.groups[groupId] else nil
		local role = if g ~= nil and g.roles ~= nil then g.roles[self.UserId] else nil
		return if role ~= nil then role else `Rank{rank}`
	end,
	IsInGroup = function(self: any, groupId: number): boolean return self:GetRankInGroup(groupId) > 0 end,
	IsFriendsWith = function(self: any, otherUserId: number): boolean
		local env = rawget(self, "_env")
		if env ~= nil and env.friends ~= nil then
			local f = env.friends[self.UserId]
			return f ~= nil and f[otherUserId] == true
		end
		return false
	end,
	LoadCharacter = function(self: any)
		local env = rawget(self, "_env")
		local char = InstanceDouble.createInstance(env, "Model")
		char.Name = self.Name
		local hum = InstanceDouble.createInstance(env, "Humanoid", char)
		hum.DisplayName = self.DisplayName
		local root = InstanceDouble.createInstance(env, "Part", char)
		root.Name = "HumanoidRootPart"
		local head = InstanceDouble.createInstance(env, "Part", char)
		head.Name = "Head"
		char.PrimaryPart = root
		if env ~= nil and env.workspace ~= nil then char.Parent = env.workspace end
		self.Character = char
		self.CharacterAdded:Fire(char)
	end,
	ClearCharacterAppearance = function(self: any)
		local char = self.Character
		if char ~= nil and char ~= NONE then
			for _, child in char:GetChildren() do
				if APPEARANCE_CLASSES[child._props.ClassName] then child:Destroy() end
			end
		end
	end,
	Kick = function(self: any, message: string?)
		local customKick: ((any, string?) -> ())? = rawget(self, "_kickFn")
		if customKick ~= nil then
			customKick(self, message)
			return
		end
		local env = rawget(self, "_env")
		if env ~= nil and env.kicks ~= nil and rawget(self, "_parent") ~= nil then
			table.insert(env.kicks, { player = self, userId = self.UserId, message = message or "", at = env.now })
			env:removePlayer(self)
		end
	end,
}
PlayerMethods.LoadCharacterWithHumanoidDescription = PlayerMethods.LoadCharacter

-- Register all classes in CLASSES ------------------------------------------------------------------------------------

defineClass("Instance", {
	abstract = true,
	props = { Name = "Instance", Parent = NONE, ClassName = "Instance", Archivable = true },
	readOnly = { "ClassName" },
	methods = BaseMethods,
})

local function defClass(name: string, spec: { [string]: any })
	spec.props = spec.props or {}
	spec.props.Name = spec.props.Name or name
	defineClass(name, spec)
end

defClass("DataModel", {
	abstract = true,
	props = {
		PlaceId = 1,
		GameId = 1,
		CreatorId = 1,
		CreatorType = Enum.CreatorType.User,
		JobId = "00000000-0000-4000-8000-000000000001",
		PrivateServerId = "",
		PrivateServerOwnerId = 0,
	},
})
defClass("Model", { props = { PrimaryPart = NONE, WorldPivot = CFrame.identity }, methods = ModelMethods })
defClass("Workspace", {
	abstract = true,
	props = {
		CurrentCamera = NONE,
		Gravity = 196.2,
		FallenPartsDestroyHeight = -500,
		GlobalWind = Vector3.zero,
		Terrain = NONE,
	},
})
defClass("BasePart", {
	abstract = true,
	props = {
		Size = Vector3.new(4, 1, 2),
		Position = Vector3.zero,
		Orientation = Vector3.zero,
		Rotation = Vector3.zero,
		CFrame = CFrame.identity,
		Color = Color3.fromRGB(163, 162, 165),
		BrickColor = BrickColor.new("Medium stone grey"),
		Material = Enum.Material.Plastic,
		Transparency = 0,
		Reflectance = 0,
		Anchored = false,
		CanCollide = true,
		CanQuery = true,
		CanTouch = true,
		CastShadow = true,
		Locked = false,
		Massless = false,
		AssemblyLinearVelocity = Vector3.zero,
		AssemblyAngularVelocity = Vector3.zero,
		Shape = Enum.PartType.Block,
		CollisionGroup = "Default",
		PivotOffset = CFrame.identity,
		MaterialVariant = "",
		EnableFluidForces = true,
		FrontSurface = Enum.SurfaceType.Smooth,
		BackSurface = Enum.SurfaceType.Smooth,
		LeftSurface = Enum.SurfaceType.Smooth,
		RightSurface = Enum.SurfaceType.Smooth,
		TopSurface = Enum.SurfaceType.Smooth,
		BottomSurface = Enum.SurfaceType.Smooth,
	},
	methods = BasePartMethods,
})
defClass("CylinderPart", {})
defClass("MeshPart", { props = { MeshId = "", TextureID = "" } })
defClass("Terrain", {
	abstract = true,
	props = {
		WaterColor = Color3.fromRGB(12, 84, 92),
		WaterReflectance = 1,
		WaterTransparency = 0.3,
		WaterWaveSize = 0.15,
		WaterWaveSpeed = 10,
	},
})
defClass("Camera", {
	props = { CFrame = CFrame.identity, Focus = CFrame.identity, ViewportSize = Vector2.new(1920, 1080) },
	readOnly = { "ViewportSize" },
	methods = CameraMethods,
})
defClass("Attachment", { props = { Position = Vector3.zero } })
defClass("JointInstance", { abstract = true, props = { C0 = CFrame.identity, C1 = CFrame.identity, Enabled = true } })
defClass(
	"Light",
	{ abstract = true, props = { Brightness = 1, Color = Color3.new(1, 1, 1), Enabled = true, Shadows = false } }
)
defClass("PointLight", { props = { Range = 8 } })
defClass("SpotLight", { props = { Angle = 90, Face = Enum.NormalId.Front, Range = 16 } })
defClass("SurfaceLight", { props = { Angle = 90, Face = Enum.NormalId.Front, Range = 16 } })
defClass("GuiBase3d", { abstract = true, props = { Transparency = 0, Visible = true } })
defClass("Humanoid", {
	props = { JumpHeight = 7.2, HipHeight = 2, RigType = Enum.HumanoidRigType.R15 },
	methods = HumanoidMethods,
})
defClass("Accoutrement", { abstract = true, props = { AttachmentPoint = CFrame.identity } })
defClass("Clothing", { abstract = true, props = { Color3 = Color3.new(1, 1, 1) } })
defClass("EditableImage", { props = { Size = Vector2.new(512, 512) }, readOnly = { "Size" } })
defClass("TweenBase", {
	abstract = true,
	props = { PlaybackState = Enum.PlaybackState.Begin },
	readOnly = { "PlaybackState" },
})
defClass("Tween", {
	abstract = true,
	props = { Instance = NONE, TweenInfo = Datatypes.TweenInfo.new() },
	readOnly = { "Instance", "TweenInfo" },
})
defClass("HumanoidDescription", {
	props = {
		HeadColor = Color3.new(1, 1, 1),
		LeftArmColor = Color3.new(1, 1, 1),
		LeftLegColor = Color3.new(1, 1, 1),
		RightArmColor = Color3.new(1, 1, 1),
		RightLegColor = Color3.new(1, 1, 1),
		TorsoColor = Color3.new(1, 1, 1),
	},
	methods = HumanoidDescriptionMethods,
})
defClass("GuiBase2d", {
	abstract = true,
	props = {
		AbsolutePosition = Vector2.zero,
		AbsoluteSize = Vector2.zero,
		AbsoluteRotation = 0,
		AutoLocalize = true,
	},
	readOnly = { "AbsolutePosition", "AbsoluteSize", "AbsoluteRotation" },
})
defClass("GuiObject", {
	abstract = true,
	props = {
		Active = false,
		AnchorPoint = Vector2.zero,
		AutomaticSize = Enum.AutomaticSize.None,
		BackgroundColor3 = Color3.fromRGB(163, 162, 165),
		BackgroundTransparency = 0,
		BorderColor3 = Color3.fromRGB(27, 42, 53),
		BorderMode = Enum.BorderMode.Outline,
		BorderSizePixel = 1,
		ClipsDescendants = false,
		Draggable = false,
		InputSink = Enum.InputSink.None,
		Interactable = true,
		LayoutOrder = 0,
		Position = UDim2.new(),
		Rotation = 0,
		Selectable = false,
		SelectionImageObject = NONE,
		SelectionOrder = 0,
		Size = UDim2.fromOffset(100, 100),
		SizeConstraint = Enum.SizeConstraint.RelativeXY,
		Visible = true,
		ZIndex = 1,
	},
})
defClass("ViewportFrame", {
	props = { Ambient = Color3.fromRGB(200, 200, 200), LightColor = Color3.fromRGB(140, 140, 140) },
})
defClass("ScrollingFrame", {
	props = {
		Active = true,
		ClipsDescendants = true,
		CanvasSize = Datatypes.UDim2.fromScale(0, 2),
		CanvasPosition = Vector2.zero,
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		AbsoluteCanvasSize = Vector2.zero,
		AbsoluteWindowSize = Vector2.new(100, 100),
		ScrollBarThickness = 12,
		ScrollingDirection = Enum.ScrollingDirection.XY,
		ScrollingEnabled = true,
	},
	readOnly = { "AbsoluteCanvasSize", "AbsoluteWindowSize" },
})
defClass("GuiButton", {
	abstract = true,
	props = {
		Active = true,
		AutoButtonColor = true,
		InputSink = Enum.InputSink.Activate,
		Modal = false,
		Selectable = true,
		Selected = false,
	},
})

local function textBounds(contentText: string, textSize: number, dt: any?): any
	local vec2 = if dt ~= nil and dt.Vector2 ~= nil then dt.Vector2 else Vector2
	local w, h = measureTextWithFontSize(contentText, textSize, false, 200)
	return vec2.new(w, h)
end

local function makeTextProps(extra: { [string]: any }, defaultText: string): { [string]: any }
	extra.Font = Enum.Font.Legacy
	extra.FontFace = Font.new("rbxasset://fonts/families/LegacyArial.json")
	extra.TextColor3 = Color3.fromRGB(27, 42, 53)
	extra.TextSize = 14
	extra.TextScaled = false
	extra.TextWrapped = false
	extra.RichText = false
	extra.TextBounds = textBounds(defaultText, 14)
	extra.TextFits = true
	extra.Size = UDim2.fromOffset(200, 50)
	return extra
end

defClass("TextLabel", { props = makeTextProps({}, "Label"), readOnly = { "TextBounds", "TextFits", "ContentText" } })
defClass("TextButton", { props = makeTextProps({}, "Button"), readOnly = { "TextBounds", "TextFits", "ContentText" } })
defClass("TextBox", {
	props = makeTextProps(
		{ Active = true, PlaceholderColor3 = Color3.fromRGB(178, 178, 178), Selectable = true },
		"TextBox"
	),
	readOnly = { "TextBounds", "TextFits", "ContentText" },
	methods = TextBoxMethods,
})
defClass("LayerCollector", {
	abstract = true,
	props = { Enabled = true, ResetOnSpawn = true, ZIndexBehavior = Enum.ZIndexBehavior.Global },
})
defClass("SurfaceGuiBase", {
	abstract = true,
	props = { Active = true, Adornee = NONE, Face = Enum.NormalId.Front },
})
defClass("BasePlayerGui", { abstract = true, methods = BasePlayerGuiMethods })
defClass("BindableEvent", { methods = BindableEventMethods })
defClass("BindableFunction", { props = { OnInvoke = NONE }, methods = BindableFunctionMethods })
defClass("RemoteEvent", { methods = RemoteEventMethods })
defClass("UnreliableRemoteEvent", { methods = RemoteEventMethods })
defClass(
	"RemoteFunction",
	{ props = { OnServerInvoke = NONE, OnClientInvoke = NONE }, methods = RemoteFunctionMethods }
)
defClass("BrickColorValue", { props = { Value = BrickColor.new("Medium stone grey") } })
defClass("UIFlexItem", {
	props = {
		FlexMode = Enum.UIFlexMode.None,
		GrowRatio = 1,
		ShrinkRatio = 1,
		ItemLineAlignment = Enum.ItemLineAlignment.Automatic,
	},
})
defClass("UIGridStyleLayout", {
	abstract = true,
	props = {
		AbsoluteContentSize = Vector2.zero,
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		SortOrder = Enum.SortOrder.Name,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	},
	readOnly = { "AbsoluteContentSize" },
})
defClass("UIListLayout", {
	props = {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		HorizontalFlex = Enum.UIFlexAlignment.None,
		VerticalFlex = Enum.UIFlexAlignment.None,
		ItemLineAlignment = Enum.ItemLineAlignment.Automatic,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = Datatypes.UDim.new(0, 0),
		Wraps = false,
		AbsoluteContentSize = Vector2.zero,
	},
	readOnly = { "AbsoluteContentSize" },
})
defClass("UIGridLayout", {
	props = {
		CellSize = UDim2.fromOffset(100, 100),
		CellPadding = UDim2.fromOffset(0, 0),
		FillDirection = Enum.FillDirection.Horizontal,
		FillDirectionMaxCells = 0,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		StartCorner = Enum.StartCorner.TopLeft,
		AbsoluteContentSize = Vector2.zero,
		AbsoluteCellSize = Vector2.new(100, 100),
		AbsoluteCellCount = Vector2.zero,
	},
	readOnly = { "AbsoluteContentSize", "AbsoluteCellSize", "AbsoluteCellCount" },
})
defClass("UIPadding", {
	props = {
		PaddingTop = Datatypes.UDim.new(0, 0),
		PaddingBottom = Datatypes.UDim.new(0, 0),
		PaddingLeft = Datatypes.UDim.new(0, 0),
		PaddingRight = Datatypes.UDim.new(0, 0),
	},
})
defClass("UIScale", { props = { Scale = 1 } })
defClass("UISizeConstraint", {
	props = {
		MinSize = Vector2.zero,
		MaxSize = Vector2.new(math.huge, math.huge),
	},
})
defClass("UIAspectRatioConstraint", {
	props = {
		AspectRatio = 1,
		AspectType = Enum.AspectType.FitWithinMaxSize,
		DominantAxis = Enum.DominantAxis.Width,
	},
})
defClass("ProximityPrompt", {
	props = {
		ActionText = "Interact",
		ObjectText = "",
		MaxActivationDistance = 10,
		HoldDuration = 0,
		Enabled = true,
		KeyboardKeyCode = Enum.KeyCode.E,
		GamepadKeyCode = Enum.KeyCode.ButtonX,
		RequiresLineOfSight = true,
		Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton,
		Style = Enum.ProximityPromptStyle.Default,
	},
	events = { "Triggered", "PromptButtonHoldBegan", "PromptButtonHoldEnded", "PromptShown", "PromptHidden" },
})
defClass("ProximityPromptService", {
	abstract = true,
	props = { Enabled = true, MaxPromptsVisible = 16 },
	events = { "PromptTriggered", "PromptButtonHoldBegan", "PromptButtonHoldEnded", "PromptShown", "PromptHidden" },
})
defClass("UIPageLayout", {
	props = { CurrentPage = NONE },
	readOnly = { "CurrentPage" },
	methods = UIPageLayoutMethods,
})
defClass("HapticEffect", {
	props = { Type = Enum.HapticEffectType.Custom, Looped = false, Playing = false },
	readOnly = { "Playing" },
	methods = HapticEffectMethods,
})
defClass("TextSource", { props = { UserId = 0, CanSend = true }, readOnly = { "UserId" } })
defClass("TextChatMessageProperties", { props = { Text = "", PrefixText = "", Metadata = "" } })
defClass("TextChannel", {
	props = { ShouldDeliverCallback = NONE, OnIncomingMessage = NONE, DirectChatRequester = NONE },
	readOnly = { "DirectChatRequester" },
	methods = TextChannelMethods,
})
defClass("Sound", {
	props = { Pitch = 1, Playing = false, IsLoaded = true, TimeLength = 1 },
	readOnly = { "IsLoaded", "TimeLength" },
	methods = SoundMethods,
})
defClass("FaceInstance", { abstract = true, props = { Face = Enum.NormalId.Front } })
defClass("BaseScript", { abstract = true, props = { Enabled = true, Disabled = false } })
defClass("Player", {
	abstract = true,
	props = {
		UserId = 1,
		DisplayName = "Player",
		AccountAge = 365,
		MembershipType = Enum.MembershipType.None,
		LocaleId = "en-us",
		Neutral = true,
		Team = NONE,
		TeamColor = BrickColor.new("White"),
		Character = NONE,
		Backpack = NONE,
		PlayerGui = NONE,
		StarterGear = NONE,
	},
	methods = PlayerMethods,
})
defClass("Players", {
	abstract = true,
	props = { MaxPlayers = 50, RespawnTime = 5, CharacterAutoLoads = true, LocalPlayer = NONE },
})
defClass("GuiService", {
	abstract = true,
	props = {
		MenuIsOpen = false,
		PreferredTextSize = Enum.PreferredTextSize.Medium,
		PreferredTransparency = 1,
		ReducedMotionEnabled = false,
		SelectedObject = NONE,
		ViewportDisplaySize = Enum.DisplaySize.Medium,
		TopbarInset = Rect.new(0, 0, 1280, 36),
		AutoSelectGuiEnabled = true,
		GuiNavigationEnabled = true,
		TouchControlsEnabled = true,
	},
})
defClass("UserInputService", {
	abstract = true,
	props = {
		GamepadEnabled = false,
		KeyboardEnabled = true,
		MouseEnabled = true,
		TouchEnabled = false,
		PreferredInput = Enum.PreferredInput.KeyboardAndMouse,
		VREnabled = false,
	},
})
defClass("VRService", { abstract = true, props = { VREnabled = false } })
defClass("Lighting", {
	abstract = true,
	props = {
		Ambient = Color3.fromRGB(127, 127, 127),
		OutdoorAmbient = Color3.fromRGB(127, 127, 127),
		Brightness = 2,
		ClockTime = 14,
		TimeOfDay = "14:00:00",
		FogEnd = 100000,
		FogStart = 0,
		FogColor = Color3.fromRGB(192, 192, 192),
		GlobalShadows = true,
	},
})

local DataStoreOptionsMethods = {
	SetMetadata = function(self: any, metadata: { [string]: any }?)
		self._props._metadata = if type(metadata) == "table" then table.clone(metadata) else {}
	end,
	GetMetadata = function(self: any): { [string]: any }
		local meta = self._props._metadata
		return if type(meta) == "table" then table.clone(meta) else {}
	end,
}

local TeleportOptionsMethods = {
	SetTeleportData = function(self: any, teleportData: any)
		self._props._teleportData = copyAttributeOrPropValue(teleportData)
	end,
	GetTeleportData = function(self: any): any return copyAttributeOrPropValue(self._props._teleportData) end,
}

defClass("DataStoreOptions", {
	props = { AllScopes = false, ExperimentalFeatures = NONE },
	methods = {
		SetExperimentalFeatures = function(self: any, features: { [string]: any }?)
			self._props.ExperimentalFeatures = if type(features) == "table" then table.clone(features) else {}
		end,
	},
})
defClass("DataStoreSetOptions", { methods = DataStoreOptionsMethods })
defClass("DataStoreIncrementOptions", { methods = DataStoreOptionsMethods })
defClass("DataStoreGetOptions", { props = { UseCache = true } })
defClass("TeleportOptions", {
	props = { ReservedServerAccessCode = "", ServerInstanceId = "", ShouldReserveServer = false },
	methods = TeleportOptionsMethods,
})

InstanceDouble.CLASSES = CLASSES

-- Property coercion & strict validation ------------------------------------------------------------------------------

local function coerceMember(member: MemberSpec, value: any, dt: any?): any
	local expected = member.type
	if expected == nil then return value end
	local typeofFn = if dt ~= nil and dt.typeof ~= nil then dt.typeof else customTypeof
	local enumLib = if dt ~= nil and dt.Enum ~= nil then dt.Enum else Enum
	local kind = typeofFn(value)
	if kind == expected then
		if member.integer == "int" then
			return if value < 0 then math.ceil(value) else math.floor(value)
		elseif member.integer == "int64" then
			return math.round(value)
		elseif member.enum == nil or tostring(value.EnumType) == member.enum then
			return value
		end
	elseif value == nil and expected == "Instance" then
		return nil
	elseif member.enum ~= nil and kind == "string" then
		return (enumLib :: any)[member.enum][value]
	elseif expected == "string" and kind == "number" then
		return tostring(value)
	end
	error(`invalid argument #3 ({member.enum or expected} expected, got {kind})`, 3)
end

-- Lenient mode only, for classes the API dump does not know (custom class names): these names read as signals.
-- Classes in the dump get exactly their events, from the schema.
local LAZY_SIGNAL_NAMES: { [string]: boolean } = {}
for _, k in
	string.split(
		"Changed ChildAdded ChildRemoved DescendantAdded DescendantRemoving DescendantRemoved Destroying AncestryChanged AttributeChanged Activated Deactivated Equipped Unequipped MouseButton1Click MouseButton1Down MouseButton1Up MouseButton2Click MouseButton2Down MouseButton2Up MouseEnter MouseLeave MouseMoved MouseWheelForward MouseWheelBackward SelectionGained SelectionLost InputBegan InputChanged InputEnded Focused FocusLost TouchTap Died Running Jumping FreeFalling Seated HealthChanged StateChanged Touched TouchEnded Triggered PromptButtonHoldBegan PromptButtonHoldEnded PromptTriggered PromptShown PromptHidden Event OnServerEvent OnClientEvent CharacterAdded CharacterRemoving CharacterAppearanceLoaded Chatted Idled Ended Stopped Loaded Paused Resumed PageEnter PageLeave SendingMessage MessageReceived BubbleDisplayed MoveToFinished Completed PlayerAdded PlayerRemoving",
		" "
	)
do
	LAZY_SIGNAL_NAMES[k] = true
end

function InstanceMeta.__tostring(self: any): string return tostring(self._props.Name) end

function InstanceMeta.__index(self: any, key: any): any
	if key == "Parent" then return rawget(self, "_parent") end
	local env = rawget(self, "_env")
	if GEOMETRY_PROPS[key] and getLayoutState(env).hasDirty then flushLayouts(env) end
	local overrides = rawget(self, "_overrides")
	if overrides ~= nil and overrides[key] ~= nil then return overrides[key] end
	local customMethods = rawget(self, "_methods")
	if customMethods ~= nil and customMethods[key] ~= nil then return customMethods[key] end
	local className = self._props.ClassName
	local schema = CLASSES[className]
	local member = if schema ~= nil then schema.members[key] else nil
	local isStrict = isStrictEnv(env)

	if member ~= nil then
		if member.kind == "method" then
			if member.fn ~= nil then return member.fn end
		elseif member.kind == "event" then
			local sig = getSignal(self, key)
			if key == "OnServerEvent" or key == "OnClientEvent" then ensureRemoteBound(self) end
			return sig
		elseif member.kind == "property" then
			local val = self._props[key]
			return if val == NONE then nil else val
		end
	end

	local baseFn = BaseMethods[key]
	if baseFn ~= nil then return baseFn end

	local double = rawget(self, "_double")
	local doubleFields = rawget(self, "_doubleFields")
	if double ~= nil and doubleFields ~= nil and doubleFields[key] then return double[key] end

	local propVal = self._props[key]
	if propVal ~= nil then return if propVal == NONE then nil else propVal end

	if type(key) == "string" then
		local children = rawget(self, "_children")
		if children ~= nil then
			for _, child in children do
				if child._props.Name == key then return child end
			end
		end
		-- On DataModel (`game`), support lazy service lookup via `game.<ServiceName>`
		local hasService: ((any, string) -> boolean)? = if env ~= nil then env._hasService else nil
		if className == "DataModel" and hasService ~= nil and hasService(env, key) then return self:GetService(key) end
	end

	if not isStrict and schema == nil and type(key) == "string" and LAZY_SIGNAL_NAMES[key] then
		local sig = getSignal(self, key)
		if key == "OnServerEvent" or key == "OnClientEvent" then ensureRemoteBound(self) end
		return sig
	end

	if member ~= nil and member.kind == "method" then
		local methodName = tostring(key)
		return function()
			error(`{className}:{methodName} is a Roblox method sert's Instance double does not implement`, 2)
		end
	end
	if isStrict then error(`{tostring(key)} is not a valid member of {className} "{self:GetFullName()}"`, 2) end

	return nil
end

local function syncCoupledProps(
	className: string,
	props: { [string]: any },
	key: any,
	value: any,
	dt: any?
): (string?, any, string?, any)
	local typeofFn = if dt ~= nil and dt.typeof ~= nil then dt.typeof else customTypeof
	local cfLib = if dt ~= nil and dt.CFrame ~= nil then dt.CFrame else CFrame
	local coupledKey1: string?, coupledVal1: any = nil, nil
	local coupledKey2: string?, coupledVal2: any = nil, nil
	if className == "Humanoid" and key == "MaxHealth" and type(value) == "number" then
		local health = props.Health
		if type(health) == "number" and health > math.max(value, 0) then
			props.Health = math.max(value, 0)
			coupledKey1, coupledVal1 = "Health", props.Health
		end
	elseif key == "CFrame" and isClass(className, "BasePart") and typeofFn(value) == "CFrame" then
		if props.Position ~= value.Position then
			props.Position = value.Position
			coupledKey1, coupledVal1 = "Position", value.Position
		end
	elseif key == "Position" and isClass(className, "BasePart") and typeofFn(value) == "Vector3" then
		local prevCf = props.CFrame
		local nextCf = if prevCf ~= nil and typeofFn(prevCf) == "CFrame"
			then prevCf.Rotation + value
			else cfLib.new(value)
		if props.CFrame ~= nextCf then
			props.CFrame = nextCf
			coupledKey1, coupledVal1 = "CFrame", nextCf
		end
	end
	return coupledKey1, coupledVal1, coupledKey2, coupledVal2
end

function InstanceMeta.__newindex(self: any, key: any, value: any)
	if key == "Parent" then
		setParent(self, value)
		return
	end
	if
		key == "_factory"
		or key == "_loader"
		or key == "_onPropSet"
		or key == "_mountPath"
		or key == "_env"
		or key == "_methods"
		or key == "_kickFn"
		or key == "_isService"
	then
		rawset(self, key, value)
		return
	end
	local double = rawget(self, "_double")
	local doubleFields = rawget(self, "_doubleFields")
	if double ~= nil and doubleFields ~= nil and doubleFields[key] then
		double[key] = value
		return
	end

	local props = self._props
	local className = props.ClassName
	local schema = CLASSES[className]
	local member = if schema ~= nil then schema.members[key] else nil
	local env = rawget(self, "_env")
	local dt = if env ~= nil then env.datatypes else nil
	local isStrict = isStrictEnv(env)

	if isStrict then
		if member == nil then
			error(`{tostring(key)} is not a valid member of {className} "{self:GetFullName()}"`, 2)
		elseif member.kind ~= "property" or (member.readOnly and not rawget(self, "_replicating")) then
			error(`Unable to assign property {key}. Property is read only`, 2)
		end
		value = coerceMember(member, value, dt)
	elseif member ~= nil and member.readOnly and key == "ClassName" then
		error(`Unable to assign property {key}. Property is read only`, 2)
	elseif
		(member ~= nil and member.kind == "method")
		or BaseMethods[key] ~= nil
		or (rawget(self, "_methods") ~= nil and self._methods[key] ~= nil)
	then
		-- Lenient mode: assigning a method stubs it on this instance alone (nil restores the double's own). Roblox
		-- rejects the assignment, as strict mode does above.
		local overrides = rawget(self, "_overrides")
		if overrides == nil then
			overrides = {}
			rawset(self, "_overrides", overrides)
		end
		overrides[key] = value
		return
	end

	if (key == "AbsoluteSize" or key == "AbsolutePosition") and isClass(className, "GuiBase2d") then
		-- Lenient mode: assigning the geometry pins it, as `InstanceDouble.setAbsolute` does.
		if key == "AbsoluteSize" then
			InstanceDouble.setAbsolute(self, value, nil)
		else
			InstanceDouble.setAbsolute(self, nil, value)
		end
		return
	end

	local isHumanoid = className == "Humanoid"
	if isHumanoid and key == "Health" and type(value) == "number" then
		value = math.clamp(value, 0, math.max(props.MaxHealth or 100, 0))
	end

	local old = props[key]
	if old == NONE then old = nil end
	props[key] = value

	local coupledKey1, coupledVal1, coupledKey2, coupledVal2 = syncCoupledProps(className, props, key, value, dt)

	if key == "Name" or key == "OnServerInvoke" or key == "OnClientInvoke" then ensureRemoteBound(self) end

	local onPropSet: ((string, any) -> ())? = rawget(self, "_onPropSet")
	if onPropSet ~= nil then onPropSet(key, value) end
	rawset(self, "_replicating", nil)
	if old ~= value then
		if LAYOUT_KEYS[key] and (isClass(className, "GuiBase2d") or LAYOUT_MODIFIER_CLASSES[className]) then
			relayout(self)
		end
		firePropChanged(self, key, value)
		if coupledKey1 ~= nil then firePropChanged(self, coupledKey1, coupledVal1) end
		if coupledKey2 ~= nil then firePropChanged(self, coupledKey2, coupledVal2) end
		if isHumanoid and (key == "Health" or coupledKey1 == "Health") then
			humanoidHealthChanged(self, props.Health)
		end
		local onPropChange: ((any, any, any) -> ())? = if env ~= nil then env._onPropChange else nil
		if onPropChange ~= nil then onPropChange(self, key, value) end
	end
end

-- Instance creation & Player upgrade ---------------------------------------------------------------------------------

-- Datatypes module -> className -> defaults rebuilt with that module's constructors (injected `env.datatypes`).
local defaultsByDatatypes: { [any]: { [string]: { [string]: any } } } = setmetatable({}, { __mode = "k" }) :: any

-- `value` (a sert datatype) rebuilt with `dt`'s constructors; unknown kinds, and any rebuild that fails, stay as given.
local function rebuildValue(value: any, dt: any): any
	if type(value) ~= "table" and type(value) ~= "userdata" then return value end
	local kind = customTypeof(value)
	local ok, rebuilt = pcall(function(): any
		if kind == "EnumItem" then
			return dt.Enum[tostring(value.EnumType)][value.Name]
		elseif kind == "UDim" then
			return dt.UDim.new(value.Scale, value.Offset)
		elseif kind == "UDim2" then
			return dt.UDim2.new(value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
		elseif kind == "Vector2" then
			return dt.Vector2.new(value.X, value.Y)
		elseif kind == "Vector3" then
			return dt.Vector3.new(value.X, value.Y, value.Z)
		elseif kind == "Color3" then
			return dt.Color3.new(value.R, value.G, value.B)
		elseif kind == "ColorSequence" then
			local points: { any } = {}
			for _, point in value.Keypoints do
				local keypoint: any = dt.ColorSequenceKeypoint.new(point.Time, rebuildValue(point.Value, dt))
				table.insert(points, keypoint)
			end
			return dt.ColorSequence.new(points)
		elseif kind == "NumberSequence" then
			local points: { any } = {}
			for _, point in value.Keypoints do
				local keypoint: any = dt.NumberSequenceKeypoint.new(point.Time, point.Value, point.Envelope)
				table.insert(points, keypoint)
			end
			return dt.NumberSequence.new(points)
		elseif kind == "Font" then
			return dt.Font.new(value.Family, rebuildValue(value.Weight, dt), rebuildValue(value.Style, dt))
		elseif kind == "CFrame" then
			return dt.CFrame.new(value:GetComponents())
		elseif kind == "BrickColor" then
			return dt.BrickColor.new(value.Number)
		elseif kind == "Rect" then
			return dt.Rect.new(value.Min.X, value.Min.Y, value.Max.X, value.Max.Y)
		elseif kind == "NumberRange" then
			return dt.NumberRange.new(value.Min, value.Max)
		elseif kind == "TweenInfo" then
			return dt.TweenInfo.new(
				value.Time,
				rebuildValue(value.EasingStyle, dt),
				rebuildValue(value.EasingDirection, dt),
				value.RepeatCount,
				value.Reverses,
				value.DelayTime
			)
		end
		return nil
	end)
	return if ok and rebuilt ~= nil then rebuilt else value
end

local function schemaDefaults(schema: ClassSchema, dt: any): { [string]: any }
	if dt == Datatypes or rawget(dt, "_isDefault") then return schema.defaults end
	local byClass = defaultsByDatatypes[dt]
	if byClass == nil then
		byClass = {}
		defaultsByDatatypes[dt] = byClass
	end
	local found = byClass[schema.name]
	if found == nil then
		found = table.clone(schema.defaults)
		for key, value in found do
			if schema.dumpDefaults[key] == nil then found[key] = rebuildValue(value, dt) end
		end
		for key, owner in schema.dumpDefaults do
			local ok, value = pcall(Generated.defaultValue, owner, key, dt)
			if ok and value ~= nil then found[key] = value end
		end
		byClass[schema.name] = found
	end
	return found
end

-- `dt` is the env's datatypes module (sert's Datatypes when nil). Dump defaults and the lenient-mode layout
-- defaults use its constructors; hand-written defaults are rebuilt with them (`rebuildValue`).
local function buildDefaultProps(className: string, isStrict: boolean, dt: any?, env: any?): { [string]: any }
	local types: any = dt or Datatypes
	local schema = CLASSES[className]
	local props: { [string]: any } = if schema ~= nil then table.clone(schemaDefaults(schema, types)) else {}
	props.Name = className
	props.ClassName = className
	if props.Archivable == nil then props.Archivable = true end
	local V2, E = types.Vector2, types.Enum
	if isClass(className, "BasePlayerGui") or className == "CoreGui" then
		props.AbsoluteSize = if env ~= nil and env.viewport ~= nil then env.viewport else V2.new(1920, 1080)
	elseif isClass(className, "LayerCollector") and env ~= nil and env._viewport ~= nil then
		props.AbsoluteSize = env._viewport
	elseif className == "Camera" then
		props.ViewportSize = if env ~= nil and env.viewport ~= nil then env.viewport else V2.new(1920, 1080)
	end
	if not isStrict then
		-- Lenient mode sizes GUIs and orders layouts, which the dump leaves unset.
		if isClass(className, "LayerCollector") then
			props.ZIndexBehavior = E.ZIndexBehavior.Sibling
			props.AbsoluteSize = if env ~= nil and env._viewport ~= nil then env._viewport else V2.new(1280, 720)
		elseif className == "UIListLayout" or className == "UIGridLayout" or className == "UIPageLayout" then
			props.SortOrder = E.SortOrder.LayoutOrder
		end
	end
	return props
end

local function allocInstanceId(env: any?): number
	if env ~= nil then
		local nextId = (rawget(env, "_nextInstId") or 0) + 1
		rawset(env, "_nextInstId", nextId)
		return nextId
	end
	nextStandaloneId += 1
	return nextStandaloneId
end

function InstanceDouble.createInstance(env: any?, className: string, parent: any?, bypassAbstract: boolean?): any
	local isStrict = isStrictEnv(env)
	if not bypassAbstract then
		-- Strict mode creates only creatable classes; lenient mode also allows class names the dump doesn't know.
		local schema = CLASSES[className]
		if if schema == nil then isStrict else not schema.creatable then
			error(`Unable to create an Instance of type "{className}"`, 2)
		end
	end
	local isGui = isClass(className, "GuiBase2d") or LAYOUT_MODIFIER_CLASSES[className] == true
	local inst: any = setmetatable({
		_id = allocInstanceId(env),
		_isInstance = true,
		_isGui = if isGui then true else nil,
		_hasGui = if isGui then true else nil,
		_env = env,
		_props = buildDefaultProps(className, isStrict, if env ~= nil then env.datatypes else nil, env),
		_parent = nil,
	}, InstanceMeta)
	if isGui then relayout(inst) end

	if parent ~= nil then setParent(inst, parent) end
	return inst
end

function InstanceDouble.upgradePlayer(env: any, player: any): any
	if player == nil then return nil end
	if getmetatable(player) == InstanceMeta then
		if rawget(player, "_env") == nil then rawset(player, "_env", env) end
		if rawget(player, "_id") == nil then rawset(player, "_id", allocInstanceId(env)) end
		return player
	end
	local uid = player.UserId or 1
	local name = player.Name or `Player{uid}`
	local displayName = player.DisplayName or name
	local accountAge = player.AccountAge or 365
	local existingKick = rawget(player, "Kick")

	for k in table.clone(player) do
		rawset(player, k, nil)
	end

	local props = buildDefaultProps("Player", isStrictEnv(env), if env ~= nil then env.datatypes else nil, env)
	props.UserId = uid
	props.Name = name
	props.DisplayName = displayName
	props.AccountAge = accountAge

	rawset(player, "_id", allocInstanceId(env))
	rawset(player, "_isInstance", true)
	rawset(player, "_env", env)
	rawset(player, "_props", props)
	rawset(player, "_parent", nil)
	if type(existingKick) == "function" then rawset(player, "_kickFn", existingKick) end
	setmetatable(player, InstanceMeta)

	local backpack = InstanceDouble.createInstance(env, "Backpack", player, true)
	backpack.Name = "Backpack"
	props.Backpack = backpack

	local playerGui = InstanceDouble.createInstance(env, "PlayerGui", player, true)
	playerGui.Name = "PlayerGui"
	props.PlayerGui = playerGui

	local starterGear = InstanceDouble.createInstance(env, "StarterGear", player, true)
	starterGear.Name = "StarterGear"
	props.StarterGear = starterGear

	return player
end

function InstanceDouble.new(className: string, parent: any?): any
	return InstanceDouble.createInstance(nil, className, parent, false)
end

return table.freeze(InstanceDouble)
