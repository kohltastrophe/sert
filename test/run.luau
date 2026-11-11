--!strict
--[[
Runs `sert`'s own headless suite directly via `luau test/run.luau [-a ...]` or `lute run test/run.luau [...]`.
]]

local sert = require("../src")

local dynRequire: (string) -> any = require :: any

local SPECS: { string } = {
	"Sert.spec",
	"Assert.spec",
	"Format.spec",
	"Runner.spec",
	"Gen.spec",
	"Model.spec",
	"Laws.spec",
	"Engine.spec",
	"Env.spec",
	"Sim.spec",
	"Roblox.spec",
	"layout_headless.spec",
}

local function isZeroReturnRequireError(err: any): boolean
	if type(err) ~= "string" then return false end
	return string.find(err, "must return a single value", 1, true) ~= nil
		or string.find(err, "did not return exactly one value", 1, true) ~= nil
end

local function isMissingModuleError(err: any): boolean
	if type(err) ~= "string" then return false end
	return string.find(err, "error requiring module", 1, true) ~= nil
		or string.find(err, "could not resolve", 1, true) ~= nil
		or string.find(err, "cannot find", 1, true) ~= nil
		or string.find(err, "No such file", 1, true) ~= nil
end

local function loadSpec(specName: string)
	local okStaged, stagedErr = pcall(dynRequire, `../.sert/stage/specs/test/{specName}`)
	if okStaged or isZeroReturnRequireError(stagedErr) then return end
	if not isMissingModuleError(stagedErr) then error(stagedErr, 0) end

	local okLocal, localErr = pcall(dynRequire, `./{specName}`)
	if okLocal or isZeroReturnRequireError(localErr) then return end
	if not isMissingModuleError(localErr) then error(localErr, 0) end
end

local function matchesFileFilter(specName: string, options: sert.RunOptions): boolean
	local filters: { string } = {}
	if options.file ~= nil then table.insert(filters, options.file) end
	if options.files ~= nil then
		for _, entry in options.files do
			table.insert(filters, entry)
		end
	end
	if #filters == 0 then return true end
	for _, needle in filters do
		if string.find(specName, needle, 1, true) ~= nil or string.find(needle, specName, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local options = sert.parseCliArgs(...)
if options.command == nil then options.command = "luau test/run.luau -a" end

for _, specName in SPECS do
	if matchesFileFilter(specName, options) then loadSpec(specName) end
end

return sert.run(options)
