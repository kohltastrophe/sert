--!strict
--[=[
	Pure-Luau Roblox engine doubles for standalone Luau execution.
]=]

local DataStore = require("@self/datastore")
local Datatypes = require("@self/datatypes")
local EncodingService = require("@self/encoding_service")
local Generated = require("@self/generated")
local InstanceDouble = require("@self/instance")
local MemoryStore = require("@self/memorystore")
local Signal = require("@self/signal")

return table.freeze({
	Signal = Signal,
	Datatypes = Datatypes,
	-- The Instance engine's public functions (env/ requires ./instance itself for the internals).
	-- cast: instance.luau's module table is `{ [string]: any }`
	Instance = table.freeze({
		new = InstanceDouble.new,
		createInstance = InstanceDouble.createInstance,
		isClass = InstanceDouble.isClass,
		setAbsolute = InstanceDouble.setAbsolute,
	}) :: {
		new: (className: string, parent: any?) -> any,
		createInstance: (env: any?, className: string, parent: any?, bypassAbstract: boolean?) -> any,
		isClass: (className: string, base: string) -> boolean,
		setAbsolute: (inst: any, size: any?, position: any?) -> (),
	},
	DataStore = DataStore,
	MemoryStore = MemoryStore,
	EncodingService = EncodingService,
	HttpService = EncodingService.HttpService,
	-- The Roblox class and enum tables from the pinned API dump (scripts/gen_api.py), with lookups.
	Generated = Generated,
})
