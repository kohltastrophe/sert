--!strict
-- Snapshot testing (`core/snapshot`): inline source-updated snapshots (`inlineSnapshot`) and `.snap` file snapshots (`snapshot`).

local format = require("./format")
local registry = require("./registry")
local util = require("./util")

local snapshot = {}

local function cleanSourcePath(source: string): string
	local clean = string.gsub(string.gsub(source, "^[@=]", ""), "\\", "/")
	clean = string.gsub(clean, "^%./", "")
	return util.stripStagePrefix(clean)
end

local function callerLocation(): (string, number)
	for level = 2, 64 do
		local source, line = debug.info(level, "sl")
		if source == nil then break end
		if not util.internal(source) then return cleanSourcePath(source), line or 0 end
	end
	local fallbackSource, fallbackLine = debug.info(util.outside(), "sl")
	return if type(fallbackSource) == "string" then cleanSourcePath(fallbackSource) else "?", fallbackLine or 0
end

local function renderSnapshotValue(actual: any): string
	if type(actual) == "string" then
		local normalized = string.gsub(actual, "\r\n", "\n")
		return normalized
	end
	return format.snapshot(actual)
end

local function normalizeNewlines(text: string): string
	local normalized = string.gsub(text, "\r\n", "\n")
	return normalized
end

local function splitLines(text: string): { string }
	local lines: { string } = {}
	local start = 1
	local len = #text
	while true do
		local nl = string.find(text, "\n", start, true)
		if nl == nil then
			table.insert(lines, string.sub(text, start, len))
			break
		end
		table.insert(lines, string.sub(text, start, nl - 1))
		start = nl + 1
	end
	return lines
end

local MAX_DIFF_OPS = 24

local function formatLineDiff(expectedText: string, actualText: string): string
	local exp = splitLines(expectedText)
	local act = splitLines(actualText)
	local out: { string } = {}
	local emitted = 0
	local extra = 0

	local function push(line: string)
		if emitted < MAX_DIFF_OPS then
			emitted += 1
			table.insert(out, line)
		else
			extra += 1
		end
	end

	local i, j = 1, 1
	local LOOKAHEAD = 8
	while i <= #exp or j <= #act do
		if i <= #exp and j <= #act and exp[i] == act[j] then
			push(`  {exp[i]}`)
			i += 1
			j += 1
		elseif i > #exp then
			push(`+ {act[j]}`)
			j += 1
		elseif j > #act then
			push(`- {exp[i]}`)
			i += 1
		else
			local foundAct: number? = nil
			for k = 1, LOOKAHEAD do
				if j + k <= #act and exp[i] == act[j + k] then
					foundAct = j + k
					break
				end
			end
			local foundExp: number? = nil
			if foundAct == nil then
				for k = 1, LOOKAHEAD do
					if i + k <= #exp and act[j] == exp[i + k] then
						foundExp = i + k
						break
					end
				end
			end
			if foundAct ~= nil then
				while j < foundAct :: number do
					push(`+ {act[j]}`)
					j += 1
				end
			elseif foundExp ~= nil then
				while i < foundExp :: number do
					push(`- {exp[i]}`)
					i += 1
				end
			else
				push(`- {exp[i]}`)
				push(`+ {act[j]}`)
				i += 1
				j += 1
			end
		end
	end
	if extra > 0 then table.insert(out, `… and {extra} more lines`) end
	return table.concat(out, "\n")
end

local function emitSnapshotMarker(payload: { [string]: any })
	registry.output.marker(`[sert-x:snapshot] {format.json(payload)}`)
end

local function lookupSnapshotBucket(
	store: { [string]: { [string]: string } }?,
	rawFile: string,
	normFile: string
): { [string]: string }?
	if type(store) ~= "table" then return nil end
	local unstageRaw = util.stripStagePrefix(rawFile)
	local unstageNorm = util.stripStagePrefix(normFile)
	for _, keyCandidate in { rawFile, unstageRaw, normFile, unstageNorm } do
		local hit = store[keyCandidate]
		if type(hit) == "table" then return hit end
	end
	local stem = string.match(unstageNorm, "([^/]+)$")
	if stem ~= nil and type(store[stem]) == "table" then return store[stem] end
	for candidate, bucket in next, store do
		if type(candidate) == "string" and type(bucket) == "table" then
			local candNorm = util.stripStagePrefix(registry.normalizeSpecFile(candidate))
			if
				candNorm == unstageNorm
				or candNorm == normFile
				or (
					candNorm ~= ""
					and (
						string.sub(unstageNorm, -(#candNorm + 1)) == "/" .. candNorm
						or string.sub(normFile, -(#candNorm + 1)) == "/" .. candNorm
					)
				)
			then
				return bucket
			end
		end
	end
	return nil
end

--- Asserts that `actual` matches an inline `expected` snapshot string, or records/updates it under `--update-snapshots` (`-u`).
function snapshot.inlineSnapshot<T>(actual: T, expected: string?, msg: string?): T
	registry.recordAssertion("snapshot")
	if expected ~= nil and type(expected) ~= "string" then
		error(`sert.inlineSnapshot: expected snapshot string or nil, got {util.typeof(expected)}`, util.outside())
	end

	local file, line = callerLocation()
	local ordinal = registry.nextInlineSnapshotOrdinal(file, line)
	local rendered = renderSnapshotValue(actual)
	local expectedNorm = if expected ~= nil then normalizeNewlines(expected) else nil
	local opts = registry.currentOptions()

	if opts ~= nil and opts.updateSnapshots == true then
		if opts.ci == true then error("cannot update snapshots when CI mode is active", util.outside()) end
		if expectedNorm == nil or expectedNorm ~= rendered then
			emitSnapshotMarker({
				kind = "inline",
				file = file,
				line = line,
				ordinal = ordinal,
				actual = rendered,
				previous = expectedNorm,
			})
		end
		return actual
	end

	local prefix = if msg ~= nil then `{msg}: ` else ""
	if expectedNorm == nil then
		error(
			`{prefix}missing inline snapshot; run with -u / --update-snapshots to record:\n{rendered}`,
			util.outside()
		)
	elseif expectedNorm ~= rendered then
		error(
			`{prefix}inline snapshot mismatch:\n{formatLineDiff(expectedNorm, rendered)}\n(run with -u / --update-snapshots to update)`,
			util.outside()
		)
	end
	return actual
end

--- Asserts that `actual` matches a stored file snapshot under `"{testName} :: {name or ordinal}"`, or updates it under `-u`.
function snapshot.snapshot<T>(actual: T, name: string?, msg: string?): T
	registry.recordAssertion("snapshot")
	if name ~= nil and type(name) ~= "string" then
		error(`sert.snapshot: expected snapshot name string or nil, got {util.typeof(name)}`, util.outside())
	end

	local callerFile = callerLocation()
	local current = registry.currentRun()
	local testName = if current ~= nil then current.name else "?"
	local normFile = if current ~= nil and current.file ~= "?"
		then current.file
		else registry.normalizeSpecFile(callerFile)
	local emitFile = if callerFile ~= "?" then callerFile else normFile
	local ordOrName = if name ~= nil and name ~= "" then name else tostring(registry.nextFileSnapshotOrdinal())
	local key = `{testName} :: {ordOrName}`
	local rendered = renderSnapshotValue(actual)

	local opts = registry.currentOptions()
	local bucket: { [string]: string }? =
		lookupSnapshotBucket(if opts ~= nil then opts.snapshots else nil, emitFile, normFile)
	if bucket == nil then
		local shared = rawget(registry.mutant._sharedG, "__SERT_SNAPSHOTS")
		bucket = lookupSnapshotBucket(shared, emitFile, normFile)
	end
	local prevRaw: any = if type(bucket) == "table" then (bucket :: { [string]: string })[key] else nil
	local prev = if type(prevRaw) == "string" then normalizeNewlines(prevRaw) else nil

	if opts ~= nil and opts.updateSnapshots == true then
		if opts.ci == true then error("cannot update snapshots when CI mode is active", util.outside()) end
		if prev == nil or prev ~= rendered then
			emitSnapshotMarker({
				kind = "file",
				file = emitFile,
				key = key,
				actual = rendered,
				previous = prev,
			})
		end
		return actual
	end

	local prefix = if msg ~= nil then `{msg}: ` else ""
	if prev == nil then
		error(
			`{prefix}missing snapshot {format.repr(key)}; run with -u / --update-snapshots to record:\n{rendered}`,
			util.outside()
		)
	elseif prev ~= rendered then
		error(
			`{prefix}snapshot mismatch for {format.repr(key)}:\n{formatLineDiff(prev, rendered)}\n(run with -u / --update-snapshots to update)`,
			util.outside()
		)
	end
	return actual
end

return table.freeze(snapshot)
