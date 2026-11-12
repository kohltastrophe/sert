--!strict
-- Zero-boilerplate Studio and Open Cloud test runner (`sert.roblox.Runner`). Isolates `registry` state per side,
-- matches specs by relative DataModel path, clones `ModuleScript`s on warm re-runs, aggregates `N` client reports,
-- and sweeps newly created DataModel instances after each test.

local IS_ROBLOX = typeof(game) == "Instance"

local format = require("../core/format")
local registry = require("../core/registry")
local runner = require("../core/runner")
local sweep = require("./sweep")
local util = require("../core/util")

local Runner = {}

export type Context = {
	sert: any,
	config: Config,
	side: string,
	isServer: boolean,
	isClient: boolean,
	isEdit: boolean,
	[string]: any,
}

export type Side = {
	specs: Instance | { Instance } | () -> Instance | { Instance }?,
	context: ((base: Context) -> { [string]: any }?)?,
	setup: ((ctx: Context) -> (() -> ())?)?,
	beforeEach: ((ctx: Context) -> ())?,
	afterEach: ((ctx: Context) -> ())?,
	timeout: number?,
}

export type Request = {
	runId: string?,
	mode: string?,
	filter: string?,
	filters: { string }?,
	names: { string }?,
	grep: string?,
	exclude: string?,
	excludes: { string }?,
	file: string?,
	files: { string }?,
	side: string?,
	sides: { string }?,
	ci: boolean?,
	allowFocused: boolean?,
	allTargets: boolean?,
	seed: number?,
	seeds: { [string]: number }?,
	replay: (number | string)?,
	runs: number?,
	exhaustive: boolean?,
	budget: number?,
	testTimeout: number?,
	timeout: number?,
	deadline: number?,
	repeatCount: number?,
	["repeat"]: number?,
	slowest: number?,
	failFast: boolean?,
	compact: boolean?,
	quiet: boolean?,
	list: boolean?,
	sweep: boolean?,
	clients: number?,
	command: string?,
	args: { string }?,
}

export type Config = {
	name: string?,
	sert: (ModuleScript | () -> any)?,
	sides: { [string]: Side }?,
	specs: (Instance | { Instance } | () -> Instance | { Instance }?)?,
	order: { string }?,
	clients: number?,
	sweep: boolean?,
	allTargets: boolean?,
	excludeSweep: { Instance }?,
	requestName: string?,
	resultName: string?,
	clientTimeout: number?,
	command: string?,
	game: any?,
	env: any?,
}

export type FailureEntry = {
	side: string,
	name: string,
	file: string?,
	message: string,
}

export type Counts = {
	passed: number,
	failed: number,
	skipped: number,
	todo: number,
	total: number,
}

export type Verdict = {
	runId: string,
	name: string?,
	mode: string?,
	passed: boolean,
	failed: number,
	durationMs: number,
	counts: Counts,
	sides: { [string]: any },
	failures: { FailureEntry },
	loadErrors: { { side: string, spec: string, error: string } },
	seed: number?,
	seeds: { [string]: number }?,
	listed: boolean?,
	reason: string?,
}

local ARGS_ATTRIBUTE = "sert_Args"
local DEFAULT_REQUEST_NAME = "sert.Request"
local DEFAULT_RESULT_NAME = "sert.Result"
local DEFAULT_CLIENT_TIMEOUT = 60

local defaultSert: any = nil

-- Tracks ModuleScripts already required once in this VM so warm re-runs `Clone()` them to bypass Luau's require cache.
local requiredOnce: { [ModuleScript]: boolean } =
	setmetatable({} :: { [ModuleScript]: boolean }, { __mode = "k" }) :: any

local SKIP_AUTO_CONTAINERS: { [string]: boolean } = {
	sert = true,
	Packages = true,
	DevPackages = true,
	ServerPackages = true,
}

local guidSeq = 0

local function resolveEnvAndGame(config: Config?): (any, any)
	local envObj: any = if config ~= nil and config.env ~= nil then config.env else registry.activeEnv()
	local dm: any = if config ~= nil and config.game ~= nil
		then config.game
		elseif IS_ROBLOX then game
		elseif envObj ~= nil then envObj.game
		else nil
	return envObj, dm
end

local function getService(dm: any, name: string): any
	if dm == nil then return nil end
	local ok, svc = pcall(dm.GetService, dm, name)
	return if ok then svc else nil
end

local function newInstance(envObj: any, className: string): any
	if envObj ~= nil and envObj.Instance ~= nil then return envObj.Instance.new(className) end
	return Instance.new(className :: any)
end

local function taskLib(envObj: any): any
	if envObj ~= nil and envObj.task ~= nil then return envObj.task end
	return task
end

local function clockNow(envObj: any): number
	if envObj ~= nil then
		local clockFn = envObj.clock
		if type(clockFn) == "function" then return (clockFn :: (any) -> number)(envObj) end
	end
	return os.clock()
end

local function nowMs(envObj: any): number return math.round(clockNow(envObj) * 1000) end

local function jsonEncode(dm: any, value: any): string
	local hs = getService(dm, "HttpService")
	if hs ~= nil then return hs:JSONEncode(value) end
	return format.json(value)
end

local function jsonDecode(dm: any, raw: string): (boolean, any)
	local hs = getService(dm, "HttpService")
	if hs ~= nil then return pcall(hs.JSONDecode, hs, raw) end
	return pcall(function() return format.jsonDecode(raw) end)
end

local function nextGuid(dm: any): string
	local hs = getService(dm, "HttpService")
	if hs ~= nil then return hs:GenerateGUID(false) end
	guidSeq += 1
	return string.format("00000000-0000-4000-8000-%012x", guidSeq)
end

local function isInstanceLike(v: any): boolean return util.typeof(v) == "Instance" end

local function requireModule(envObj: any, mod: any): any
	if envObj ~= nil then
		local reqFn = envObj.require
		if type(reqFn) == "function" then return (reqFn :: (any, any) -> any)(envObj, mod) end
	end
	return (require :: any)(mod)
end

local function emitMarker(kind: string, payload: string) registry.output.print(`[sert-{kind}] {payload}`) end

local function emitJsonMarker(dm: any, kind: string, value: any) emitMarker(kind, jsonEncode(dm, value)) end

--- Sets the default `sert` root table returned on `ctx.sert` when `config.sert` is omitted.
function Runner.setDefaultSert(sertMod: any) defaultSert = sertMod end

--- Emits a custom `[sert-x:<tag>] <text>` diagnostic marker.
function Runner.marker(tag: string, text: string) emitMarker(`x:{tag}`, text) end

--- Emits a `[sert-phase] <where> <name> <ms>` timing marker.
function Runner.phase(where: string, name: string) emitMarker("phase", `{where} {name} {nowMs(nil)}`) end

--- Reads Studio test session arguments from `workspace:GetAttribute("sert_Args")` or `StudioTestService:GetTestArgs()`.
function Runner.args(waitSeconds: number?, config: Config?): Request?
	local envObj, dm = resolveEnvAndGame(config)
	if dm == nil then return nil end
	local limit = waitSeconds or 5
	local waited = 0
	local ws = getService(dm, "Workspace")
	local sts = getService(dm, "StudioTestService")
	local tLib = taskLib(envObj)
	while true do
		local preset = if ws ~= nil then ws:GetAttribute(ARGS_ATTRIBUTE) else nil
		if type(preset) == "string" and preset ~= "" then
			local okDec, given = jsonDecode(dm, preset)
			if okDec and type(given) == "table" then return given :: Request end
		end
		if sts ~= nil then
			local okArgs, val = pcall((sts :: any).GetTestArgs, sts)
			if okArgs and type(val) == "table" then return val :: Request end
		end
		if waited >= limit or tLib == nil or tLib.wait == nil then return nil end
		local dt: any = (tLib.wait :: (number) -> number)(0.05)
		waited += if type(dt) == "number" then dt else 0.05
	end
end

local function resolveSertModule(config: Config, envObj: any, dm: any): any
	if type(config.sert) == "function" then return (config.sert :: () -> any)() end
	if isInstanceLike(config.sert) and (config.sert :: any):IsA("ModuleScript") then
		return requireModule(envObj, config.sert)
	end
	if defaultSert ~= nil then return defaultSert end
	local rs = getService(dm, "ReplicatedStorage")
	local rsSert: any = if rs ~= nil then rs:FindFirstChild("sert") else nil
	if rsSert ~= nil and rsSert:IsA("ModuleScript") then return requireModule(envObj, rsSert) end
	if IS_ROBLOX then
		local robloxDir = script.Parent
		local sertInit = if robloxDir ~= nil then robloxDir.Parent else nil
		if sertInit ~= nil and sertInit:IsA("ModuleScript") then return requireModule(envObj, sertInit) end
	end
	return nil
end

-- Computes a stable relative DataModel path (`specs/server/Inventory.spec`) so identically named specs in different
-- directories never collide under `--file`.
local function relativeSpecPath(mod: ModuleScript, rootAnchor: Instance?, dm: any): string
	local parts: { string } = {}
	local cur: Instance? = mod
	while cur ~= nil and cur ~= dm do
		table.insert(parts, 1, cur.Name)
		if rootAnchor ~= nil and cur == rootAnchor then break end
		cur = cur.Parent
	end
	-- Strip leading service/wrapper container (`ReplicatedStorage/Tests/specs/...` -> `specs/...`) when present.
	if rootAnchor == nil then
		if
			#parts >= 3
			and (parts[1] == "ReplicatedStorage" or parts[1] == "ServerScriptService" or parts[1] == "ServerStorage")
		then
			if parts[2] == "Tests" or parts[2] == "Test" then return table.concat(parts, "/", 3) end
			return table.concat(parts, "/", 2)
		end
	end
	return table.concat(parts, "/")
end

local function matchesFileFilter(relPath: string, fileFilter: string): boolean
	if fileFilter == "" then return true end
	local normRel = string.lower(registry.normalizeSpecFile(relPath))
	local normFilter = string.lower(registry.normalizeSpecFile(fileFilter))
	if normRel == normFilter or string.lower(relPath) == string.lower(fileFilter) then return true end
	-- Match trailing subpath (`server/Inventory` or `Inventory` matching `specs/server/Inventory`).
	if #normRel > #normFilter and string.sub(normRel, -(#normFilter + 1)) == "/" .. normFilter then return true end
	return false
end

local function matchesRequestFiles(relPath: string, request: Request): boolean
	if request.file ~= nil and request.file ~= "" then
		if not matchesFileFilter(relPath, request.file) then return false end
	end
	if request.files ~= nil and #request.files > 0 then
		for _, wanted in request.files do
			if matchesFileFilter(relPath, wanted) then return true end
		end
		return false
	end
	return true
end

local function sideEnabled(sideName: string, request: Request): boolean
	if request.side ~= nil and request.side ~= "" and request.side ~= "all" and request.side ~= sideName then
		return false
	end
	if request.sides ~= nil and #request.sides > 0 then
		return table.find(request.sides, sideName) ~= nil or table.find(request.sides, "all") ~= nil
	end
	return true
end

local function isSpecModule(inst: Instance): boolean
	if not inst:IsA("ModuleScript") then return false end
	local name = inst.Name
	return string.sub(name, -5) == ".spec" or string.sub(name, -5) == "_spec" or string.sub(name, -5) == ".test"
end

type SpecEntry = { mod: ModuleScript, path: string }

local function collectSpecsUnder(
	container: Instance,
	anchor: Instance?,
	dm: any,
	out: { SpecEntry },
	seen: { [ModuleScript]: boolean }
)
	if SKIP_AUTO_CONTAINERS[container.Name] then return end
	if isSpecModule(container) then
		local m = container :: ModuleScript
		if not seen[m] then
			seen[m] = true
			table.insert(out, { mod = m, path = relativeSpecPath(m, anchor, dm) })
		end
	end
	for _, child in container:GetChildren() do
		if not SKIP_AUTO_CONTAINERS[child.Name] then collectSpecsUnder(child, anchor, dm, out, seen) end
	end
end

local function discoverSpecs(sideDef: Side?, config: Config, isClient: boolean, dm: any): { SpecEntry }
	local out: { SpecEntry } = {}
	local seen: { [ModuleScript]: boolean } = {}

	local explicitSource: any = if sideDef ~= nil and sideDef.specs ~= nil then sideDef.specs else config.specs
	if type(explicitSource) == "function" then explicitSource = (explicitSource :: () -> any)() end

	if explicitSource ~= nil then
		if isInstanceLike(explicitSource) then
			collectSpecsUnder(explicitSource, explicitSource, dm, out, seen)
		elseif type(explicitSource) == "table" then
			for _, item in explicitSource do
				if isInstanceLike(item) then collectSpecsUnder(item, item, dm, out, seen) end
			end
		end
		table.sort(out, function(a: SpecEntry, b: SpecEntry): boolean return a.path < b.path end)
		return out
	end

	-- Zero-boilerplate auto-discovery across DataModel services accessible to this side.
	local rs = getService(dm, "ReplicatedStorage")
	if rs ~= nil then collectSpecsUnder(rs, nil, dm, out, seen) end
	if not isClient then
		local sss = getService(dm, "ServerScriptService")
		if sss ~= nil then collectSpecsUnder(sss, nil, dm, out, seen) end
		local ss = getService(dm, "ServerStorage")
		if ss ~= nil then collectSpecsUnder(ss, nil, dm, out, seen) end
	else
		local playersSvc = getService(dm, "Players")
		local lp: Player? = if playersSvc ~= nil then playersSvc.LocalPlayer else nil
		if lp ~= nil then
			local ps = lp:FindFirstChildOfClass("PlayerScripts")
			if ps ~= nil then collectSpecsUnder(ps, nil, dm, out, seen) end
		end
		local sp = getService(dm, "StarterPlayer")
		if sp ~= nil then collectSpecsUnder(sp, nil, dm, out, seen) end
	end

	table.sort(out, function(a: SpecEntry, b: SpecEntry): boolean return a.path < b.path end)
	return out
end

local function requireSpecFresh(envObj: any, mod: ModuleScript): (boolean, any)
	if not requiredOnce[mod] then
		requiredOnce[mod] = true
		return pcall(requireModule, envObj, mod)
	end
	local clone = mod:Clone()
	clone.Parent = mod.Parent
	local ok, result = pcall(requireModule, envObj, clone)
	clone:Destroy()
	return ok, result
end

local function buildRunOptions(
	request: Request,
	config: Config,
	targets: { registry.Target },
	markers: boolean
): registry.RunOptions
	local base: registry.RunOptions = if request.args ~= nil and #request.args > 0
		then runner.parseCliArgs(request.args)
		else {}

	if request.filter ~= nil and request.filter ~= "" then base.filter = request.filter end
	if request.filters ~= nil then base.filters = request.filters end
	if request.names ~= nil then base.names = request.names end
	if request.grep ~= nil then base.grep = request.grep end
	if request.exclude ~= nil then base.exclude = request.exclude end
	if request.excludes ~= nil then base.excludes = request.excludes end
	if request.file ~= nil and request.file ~= "" then base.file = registry.normalizeSpecFile(request.file) end
	if request.files ~= nil then
		local normFiles: { string } = {}
		for _, f in request.files do
			table.insert(normFiles, registry.normalizeSpecFile(f))
		end
		base.files = normFiles
	end
	if request.ci ~= nil then base.ci = request.ci end
	if request.allowFocused ~= nil then base.allowFocused = request.allowFocused end
	if request.seed ~= nil then base.seed = request.seed end
	if request.seeds ~= nil then base.seeds = request.seeds end
	if request.replay ~= nil then base.replay = request.replay end
	if request.runs ~= nil then base.runs = request.runs end
	if request.exhaustive ~= nil then base.exhaustive = request.exhaustive end
	if request.budget ~= nil then base.budget = request.budget end
	if request.testTimeout ~= nil then
		base.testTimeout = request.testTimeout
	elseif request.timeout ~= nil then
		base.testTimeout = request.timeout
	end
	if request.repeatCount ~= nil then
		base.repeatCount = request.repeatCount
	elseif request["repeat"] ~= nil then
		base.repeatCount = request["repeat"]
	end
	if request.slowest ~= nil then base.slowest = request.slowest end
	if request.failFast ~= nil then base.failFast = request.failFast end
	if request.compact ~= nil then base.compact = request.compact end
	if request.quiet ~= nil then base.quiet = request.quiet end
	if request.list ~= nil then base.list = request.list end
	if request.command ~= nil then
		base.command = request.command
	elseif config.command ~= nil and base.command == nil then
		base.command = config.command
	end

	base.targets = targets
	base.markers = markers
	base.raise = false
	return base
end

local function targetsForSide(isClient: boolean, allTargets: boolean): { registry.Target }
	if isClient then return if allTargets then { "client", "portable" } else { "client" } end
	return if allTargets then { "roblox", "server", "portable" } else { "roblox", "server" }
end

type SideOutcome = {
	side: string,
	passed: number,
	failed: number,
	skipped: number,
	todo: number,
	total: number,
	durationMs: number,
	failures: { FailureEntry },
	loadErrors: { { side: string, spec: string, error: string } },
	seed: number?,
	seeds: { [string]: number }?,
}

local function executeSide(
	sideName: string,
	sideDef: Side?,
	config: Config,
	request: Request,
	isClient: boolean,
	isEdit: boolean,
	emitLiveMarkers: boolean
): SideOutcome
	local envObj, dm = resolveEnvAndGame(config)
	local startAt = nowMs(envObj)
	local allTargets = if request.allTargets ~= nil then request.allTargets else (config.allTargets == true)
	local targets = targetsForSide(isClient, allTargets)
	local doSweep = if request.sweep ~= nil then request.sweep else (config.sweep ~= false)
	local specs = discoverSpecs(sideDef, config, isClient, dm)

	local sertMod = resolveSertModule(config, envObj, dm)
	local ctx: Context = {
		sert = sertMod,
		config = config,
		side = sideName,
		isServer = not isClient and not isEdit,
		isClient = isClient,
		isEdit = isEdit,
	}
	if sideDef ~= nil and sideDef.context ~= nil then
		local extra = sideDef.context(ctx)
		if type(extra) == "table" then
			for k, v in extra do
				ctx[k] = v
			end
		end
	end

	local sideState = registry.newState()
	sideState.side = sideName

	local loadErrors: { { side: string, spec: string, error: string } } = {}
	local teardownSetup: (() -> ())? = nil
	local runRes: any = nil

	registry.withState(sideState, function()
		if sideDef ~= nil and sideDef.setup ~= nil then
			local okSetup, cleanupOrErr = pcall(sideDef.setup, ctx)
			if not okSetup then
				table.insert(loadErrors, {
					side = sideName,
					spec = `<{sideName}.setup>`,
					error = format.errorText(cleanupOrErr),
				})
				return
			end
			if type(cleanupOrErr) == "function" then teardownSetup = cleanupOrErr end
		end

		if sideDef ~= nil and sideDef.beforeEach ~= nil then
			local fn = sideDef.beforeEach
			registry.api.beforeEach(function() fn(ctx) end)
		end
		if sideDef ~= nil and sideDef.afterEach ~= nil then
			local fn = sideDef.afterEach
			registry.api.afterEach(function() fn(ctx) end)
		end

		-- Automatic DataModel sweep around every test unless `sweep == false`.
		local activeSnap: sweep.Snapshot? = nil
		local prevPostHook = registry.getPostTestHook()
		local prevActiveEnv = registry.activeEnv()
		if envObj ~= nil then registry.setActiveEnv(envObj) end
		if doSweep and not request.list then
			table.insert(
				sideState.globalHooks.before,
				1,
				function() activeSnap = sweep.snapshot({ gameRoot = dm, exclude = config.excludeSweep }) end
			)
			registry.setPostTestHook(function(testCtx)
				local snap = activeSnap
				activeSnap = nil
				if snap ~= nil then sweep.restore(snap) end
				if prevPostHook ~= nil then prevPostHook(testCtx) end
			end)
		end

		for _, entry in specs do
			if matchesRequestFiles(entry.path, request) then
				local loadStart = nowMs(envObj)
				sideState.file = entry.path
				local okReq, exported = requireSpecFresh(envObj, entry.mod)
				sideState.file = nil

				if not okReq then
					table.insert(loadErrors, {
						side = sideName,
						spec = entry.path,
						error = format.errorText(exported),
					})
				elseif type(exported) == "function" then
					sideState.file = entry.path
					local okFn, fnErr = pcall(exported, ctx)
					sideState.file = nil
					if not okFn then
						table.insert(loadErrors, {
							side = sideName,
							spec = entry.path,
							error = format.errorText(fnErr),
						})
					end
				end

				if emitLiveMarkers then
					emitMarker(
						"file",
						`{sideName}|{registry.normalizeSpecFile(entry.path)}|{nowMs(envObj) - loadStart}`
					)
				end
			end
		end

		if #sideState.tests > 0 then
			local runOpts = buildRunOptions(request, config, targets, emitLiveMarkers)
			if sideDef ~= nil and sideDef.timeout ~= nil and runOpts.testTimeout == nil then
				runOpts.testTimeout = sideDef.timeout
			end
			local okRun, resOrErr = pcall(runner.run, runOpts)
			if okRun then
				runRes = resOrErr
			else
				table.insert(loadErrors, {
					side = sideName,
					spec = `<{sideName}.runner>`,
					error = format.errorText(resOrErr),
				})
			end
		end
		if doSweep and not request.list then registry.setPostTestHook(prevPostHook) end
		if envObj ~= nil then registry.setActiveEnv(prevActiveEnv) end

		if teardownSetup ~= nil then
			local okTd, tdErr = pcall(teardownSetup :: () -> ...any)
			if not okTd then
				table.insert(loadErrors, {
					side = sideName,
					spec = `<{sideName}.teardown>`,
					error = format.errorText(tdErr),
				})
			end
		end
	end)

	local failures: { FailureEntry } = {}
	for _, le in loadErrors do
		table.insert(failures, {
			side = sideName,
			name = le.spec,
			file = le.spec,
			message = le.error,
		})
	end
	if runRes ~= nil and type(runRes.failures) == "table" then
		for _, f in runRes.failures do
			if type(f) == "string" then
				local parsedName, parsedMsg = string.match(f, "^(.-): (.*)$")
				table.insert(failures, {
					side = sideName,
					name = parsedName or f,
					message = parsedMsg or f,
				})
			elseif type(f) == "table" then
				table.insert(failures, {
					side = sideName,
					name = tostring(f.name or "?"),
					file = f.file,
					message = tostring(f.error or f.err or f.message or "failed"),
				})
			end
		end
	end

	local passed = if runRes ~= nil then (runRes.passed or 0) else 0
	local failed = (if runRes ~= nil then (runRes.failed or 0) else 0) + #loadErrors
	local skipped = if runRes ~= nil then (runRes.skipped or 0) else 0
	local todo = if runRes ~= nil then (runRes.todo or 0) else 0
	local total = passed + failed + skipped + todo

	return {
		side = sideName,
		passed = passed,
		failed = failed,
		skipped = skipped,
		todo = todo,
		total = total,
		durationMs = nowMs(envObj) - startAt,
		failures = failures,
		loadErrors = loadErrors,
		seed = if runRes ~= nil then runRes.seed else nil,
		seeds = if runRes ~= nil then runRes.seeds else nil,
	}
end

local function decodeRequestValue(dm: any, raw: string): Request?
	if raw == "" then return nil end
	local ok, decoded = jsonDecode(dm, raw)
	if ok and type(decoded) == "table" then return decoded :: Request end
	return nil
end

local function ensureComms(config: Config, envObj: any, dm: any): (StringValue, RemoteEvent)
	local rs = getService(dm, "ReplicatedStorage")
	if rs == nil then error("Runner: ReplicatedStorage is unavailable in active DataModel", 0) end
	local reqName = config.requestName or DEFAULT_REQUEST_NAME
	local resName = config.resultName or DEFAULT_RESULT_NAME

	local reqVal = rs:FindFirstChild(reqName) :: StringValue?
	if reqVal == nil then
		local created = newInstance(envObj, "StringValue")
		created.Name = reqName
		created.Value = ""
		created.Parent = rs
		reqVal = created
	end

	local resRemote = rs:FindFirstChild(resName) :: RemoteEvent?
	if resRemote == nil then
		local created = newInstance(envObj, "RemoteEvent")
		created.Name = resName
		created.Parent = rs
		resRemote = created
	end

	return reqVal :: StringValue, resRemote :: RemoteEvent
end

local function expectedClientCount(request: Request, config: Config, dm: any): number
	if not sideEnabled("client", request) then return 0 end
	if request.clients ~= nil then return math.max(0, request.clients) end
	if config.clients ~= nil then return math.max(0, config.clients) end
	-- Studio `Run` mode (`IsRunMode() == true`) has no client VM.
	local rs = getService(dm, "RunService")
	local okRunMode, isRunMode = pcall(function() return if rs ~= nil then rs:IsRunMode() else false end)
	if okRunMode and isRunMode then return 0 end
	if config.sides ~= nil and config.sides.client == nil then return 0 end
	return 1
end

local function mergeOutcomes(
	runId: string,
	config: Config,
	request: Request,
	outcomes: { SideOutcome },
	startAt: number
): Verdict
	local counts: Counts = { passed = 0, failed = 0, skipped = 0, todo = 0, total = 0 }
	local sides: { [string]: any } = {}
	local failures: { FailureEntry } = {}
	local loadErrors: { { side: string, spec: string, error: string } } = {}
	local seeds: { [string]: number } = {}
	local primarySeed: number? = request.seed

	for _, o in outcomes do
		counts.passed += o.passed
		counts.failed += o.failed
		counts.skipped += o.skipped
		counts.todo += o.todo
		counts.total += o.total

		local existingSide = sides[o.side]
		if existingSide == nil then
			sides[o.side] = {
				passed = o.passed,
				failed = o.failed,
				skipped = o.skipped,
				todo = o.todo,
				total = o.total,
				durationMs = o.durationMs,
			}
		else
			existingSide.passed += o.passed
			existingSide.failed += o.failed
			existingSide.skipped += o.skipped
			existingSide.todo += o.todo
			existingSide.total += o.total
			existingSide.durationMs = math.max(existingSide.durationMs, o.durationMs)
		end

		for _, f in o.failures do
			table.insert(failures, f)
		end
		for _, le in o.loadErrors do
			table.insert(loadErrors, le)
		end
		if primarySeed == nil and o.seed ~= nil then primarySeed = o.seed end
		if o.seeds ~= nil then
			for k, v in o.seeds do
				seeds[k] = v
			end
		end
	end

	local listed = request.list == true
	local passed = if listed then counts.failed == 0 else (counts.failed == 0 and counts.passed > 0)
	local reason: string? = nil
	if listed then
		reason = `listed {counts.total}`
	elseif counts.failed == 0 and counts.passed == 0 then
		reason = "no test ran: nothing matched the selection"
	end

	return {
		runId = runId,
		name = config.name or "sert",
		mode = request.mode,
		passed = passed,
		failed = counts.failed,
		durationMs = nowMs((resolveEnvAndGame(config))) - startAt,
		counts = counts,
		sides = sides,
		failures = failures,
		loadErrors = loadErrors,
		seed = primarySeed,
		seeds = if next(seeds) ~= nil then seeds else nil,
		listed = if listed then true else nil,
		reason = reason,
	}
end

local function emitFinalVerdict(dm: any, verdict: Verdict)
	emitJsonMarker(dm, "result", verdict)
	emitJsonMarker(dm, "verdict", verdict)
	emitMarker("run:end", verdict.runId)
end

-- Waits briefly on real Play Solo client boot until `CoreGui` finishes mounting the topbar (`GuiService:GetGuiInset()`)
-- so frame-0 client UI specs never observe a false-positive 58px `IgnoreGuiInset` shift on frame 1.
local clientBootSettled = false

local function settleClientBoot(dm: any)
	if clientBootSettled or not IS_ROBLOX then return end
	clientBootSettled = true
	local rs = getService(dm, "RunService")
	local gs = getService(dm, "GuiService")
	if rs == nil or rs.RenderStepped == nil or gs == nil then return end
	local prevY = -1
	local stable = 0
	for _ = 1, 15 do
		(rs.RenderStepped :: any):Wait()
		local okInset, topLeft = pcall(gs.GetGuiInset, gs)
		local curY = if okInset and topLeft ~= nil then topLeft.Y else 0
		if curY == prevY and (curY > 0 or stable >= 3) then
			stable += 1
			if stable >= 2 then break end
		elseif curY == prevY then
			stable += 1
		else
			prevY = curY
			stable = 0
		end
	end
end

--- Runs a single coordinated server + N-client test pass and returns the aggregated `Verdict`.
function Runner.runOnce(config: Config?, request: Request?): Verdict
	local cfg: Config = config or {}
	local envObj, dm = resolveEnvAndGame(cfg)
	local req: Request = if request ~= nil then table.clone(request) else {}
	local runId = req.runId or nextGuid(dm)
	req.runId = runId

	local startAt = nowMs(envObj)
	emitMarker("run:start", runId)

	local outcomes: { SideOutcome } = {}
	local numClients = expectedClientCount(req, cfg, dm)
	local reqVal, resRemote = ensureComms(cfg, envObj, dm)

	local clientReports: { SideOutcome } = {}
	local seenPlayers: { [any]: boolean } = {}
	local receivedClients = 0
	local clientConn: RBXScriptConnection? = nil

	if numClients > 0 then
		clientConn = resRemote.OnServerEvent:Connect(function(player: Player, payload: any)
			if type(payload) ~= "table" or payload.runId ~= runId then return end
			local pAny: any = player
			local pKey: any = if pAny ~= nil then pAny else receivedClients + 1
			if seenPlayers[pKey] then return end
			seenPlayers[pKey] = true
			receivedClients += 1

			local outcome: SideOutcome = payload.outcome
			if type(outcome) == "table" then
				local pName = if pAny ~= nil then tostring(pAny.Name) else tostring(receivedClients)
				local clientLabel = if numClients > 1 then `client:{pName}` else "client"
				outcome.side = clientLabel
				if type(payload.markerLines) == "table" then
					for _, rawLine in payload.markerLines do
						if type(rawLine) == "string" then
							local testJson = string.match(rawLine, "^%[sert%-test%] (.+)$")
							if testJson ~= nil then
								local okDec, parsed = jsonDecode(dm, testJson)
								if okDec and type(parsed) == "table" then
									parsed.side = clientLabel
									emitJsonMarker(dm, "test", parsed)
								end
							elseif not (req.list and receivedClients > 1) then
								registry.output.print(rawLine)
							end
						end
					end
				end
				table.insert(clientReports, outcome)
			end
		end)

		local clientReq: Request = table.clone(req)
		clientReq.runId = runId
		reqVal.Value = jsonEncode(dm, clientReq)
	end

	-- Run server side unless restricted to client-only.
	if sideEnabled("server", req) then
		local serverSideDef = if cfg.sides ~= nil then cfg.sides.server else nil
		local serverOutcome = executeSide("server", serverSideDef, cfg, req, false, false, true)
		table.insert(outcomes, serverOutcome)
	end

	-- Wait for all `expectedClients` distinct client reports.
	if numClients > 0 then
		local tLib = taskLib(envObj)
		local timeoutSec = req.deadline or cfg.clientTimeout or DEFAULT_CLIENT_TIMEOUT
		local deadline = clockNow(envObj) + timeoutSec
		while receivedClients < numClients and clockNow(envObj) < deadline do
			if tLib ~= nil and tLib.wait ~= nil then
				(tLib.wait :: (number) -> any)(0.02)
			else
				break
			end
		end
		if clientConn ~= nil then clientConn:Disconnect() end

		for _, co in clientReports do
			table.insert(outcomes, co)
		end

		if receivedClients < numClients then
			local missing = numClients - receivedClients
			local msg = `Timed out after {timeoutSec}s waiting for {missing} of {numClients} client report(s)`
			table.insert(outcomes, {
				side = "client",
				passed = 0,
				failed = 1,
				skipped = 0,
				todo = 0,
				total = 1,
				durationMs = nowMs(envObj) - startAt,
				failures = { { side = "client", name = "<client-handoff>", message = msg } },
				loadErrors = { { side = "client", spec = "<client-handoff>", error = msg } },
				seed = nil,
				seeds = nil,
			})
		end
	end

	local verdict = mergeOutcomes(runId, cfg, req, outcomes, startAt)
	emitFinalVerdict(dm, verdict)
	return verdict
end

--- Starts the server test coordinator (`Runner.server(config?)`). Runs a `StudioTestService` session when test args are
--- present and listens for warm re-run requests on `sert.Request`.
function Runner.server(config: Config?): { stop: () -> (), runOnce: (req: Request?) -> Verdict }
	local cfg: Config = config or {}
	local envObj, dm = resolveEnvAndGame(cfg)
	local tLib = taskLib(envObj)
	local reqVal = ensureComms(cfg, envObj, dm)
	local lastRunId: string? = nil

	local function handleValue(raw: string)
		local req = decodeRequestValue(dm, raw)
		if req == nil then return end
		if req.runId ~= nil and req.runId == lastRunId then return end
		local runId = req.runId or nextGuid(dm)
		lastRunId = runId
		req.runId = runId
		Runner.runOnce(cfg, req)
	end

	local conn = reqVal.Changed:Connect(handleValue)
	if reqVal.Value ~= "" then
		tLib.spawn(handleValue, reqVal.Value)
	else
		tLib.spawn(function()
			local studioReq = Runner.args(5, cfg)
			if studioReq == nil then return end
			local rid = studioReq.runId or nextGuid(dm)
			if rid == lastRunId then return end
			lastRunId = rid
			local r = table.clone(studioReq)
			r.runId = rid
			local verdict = Runner.runOnce(cfg, r)
			local sts = getService(dm, "StudioTestService")
			if sts ~= nil then pcall((sts :: any).EndTest, sts, verdict) end
		end)
	end

	return {
		stop = function() conn:Disconnect() end,
		runOnce = function(req: Request?): Verdict
			local r: Request = if req ~= nil then table.clone(req) else {}
			local rid = r.runId or nextGuid(dm)
			lastRunId = rid
			r.runId = rid
			return Runner.runOnce(cfg, r)
		end,
	}
end

--- Starts the client test listener (`Runner.client(config?)`), executing `{"client"}` target specs for each `runId`
--- broadcast on `sert.Request` and reporting back via `sert.Result`.
function Runner.client(config: Config?): { stop: () -> () }
	local cfg: Config = config or {}
	local envObj, dm = resolveEnvAndGame(cfg)
	local tLib = taskLib(envObj)
	local rs = getService(dm, "ReplicatedStorage")
	if rs == nil then error("Runner.client: ReplicatedStorage is unavailable in active DataModel", 0) end
	local reqName = cfg.requestName or DEFAULT_REQUEST_NAME
	local resName = cfg.resultName or DEFAULT_RESULT_NAME

	local reqVal = rs:WaitForChild(reqName, 30) :: StringValue?
	local resRemote = rs:WaitForChild(resName, 30) :: RemoteEvent?
	if reqVal == nil or resRemote == nil then
		error(`Runner.client: timed out waiting for ReplicatedStorage.{reqName} / {resName}`, 0)
	end

	local lastRunId: string? = nil
	local clientSideDef = if cfg.sides ~= nil then cfg.sides.client else nil

	local function onRequestRaw(raw: string)
		local req = decodeRequestValue(dm, raw)
		if req == nil or req.runId == nil or req.runId == lastRunId then return end
		if not sideEnabled("client", req) then return end
		lastRunId = req.runId

		settleClientBoot(dm)

		-- Capture `[sert-...]` marker lines emitted on this client so the server replays them deterministically.
		local markerLines: { string } = {}
		local outcome: SideOutcome
		local lines = registry.output.capture(
			function() outcome = executeSide("client", clientSideDef, cfg, req, true, false, true) end
		)
		for _, line in lines do
			if string.match(line, "^%[sert%-") ~= nil then table.insert(markerLines, line) end
		end

		(resRemote :: RemoteEvent):FireServer({
			runId = req.runId,
			outcome = outcome,
			markerLines = markerLines,
		})
	end

	local conn = (reqVal :: StringValue).Changed:Connect(onRequestRaw)
	if (reqVal :: StringValue).Value ~= "" then tLib.spawn(onRequestRaw, (reqVal :: StringValue).Value) end

	return {
		stop = function() conn:Disconnect() end,
	}
end

--- Executes specs in Studio Edit mode (`Runner.edit(config?, requestOrArgs?)`) with fresh `ModuleScript:Clone()` reloads.
function Runner.edit(config: Config?, requestOrArgs: (Request | { string })?): Verdict
	local cfg: Config = config or {}
	local envObj, dm = resolveEnvAndGame(cfg)
	local req: Request
	if
		type(requestOrArgs) == "table"
		and (#(requestOrArgs :: { any }) > 0 or next(requestOrArgs :: { [any]: any }) == nil)
	then
		local isArray = true
		for k in next, requestOrArgs :: { [any]: any } do
			if type(k) ~= "number" then
				isArray = false
				break
			end
		end
		if isArray then
			req = ({ args = requestOrArgs :: { string } } :: any) :: Request
		else
			req = table.clone((requestOrArgs :: any) :: Request)
		end
	else
		local studioReq = Runner.args(0, cfg)
		req = if studioReq ~= nil then table.clone(studioReq) else {} :: Request
	end
	if req.mode == nil then req.mode = "edit" end

	local runId = req.runId or nextGuid(dm)
	req.runId = runId
	local startAt = nowMs(envObj)
	emitMarker("run:start", runId)

	local outcomes: { SideOutcome } = {}
	if cfg.sides ~= nil then
		local order: { string } = cfg.order or { "server", "client" }
		for _, sName in order do
			local sDef = cfg.sides[sName]
			if sDef ~= nil and sideEnabled(sName, req) then
				table.insert(outcomes, executeSide(sName, sDef, cfg, req, sName == "client", true, true))
			end
		end
	else
		local editReq: Request = table.clone(req)
		if editReq.allTargets == nil then editReq.allTargets = true end
		table.insert(outcomes, executeSide("edit", nil, cfg, editReq, false, true, true))
	end

	local verdict = mergeOutcomes(runId, cfg, req, outcomes, startAt)
	emitFinalVerdict(dm, verdict)
	return verdict
end

--- Executes specs in Roblox Open Cloud Luau Execution (`Runner.cloud(config?, request?)`) and returns the `Verdict`.
function Runner.cloud(config: Config?, request: Request?): Verdict
	local cfg: Config = config or {}
	local req: Request = if request ~= nil then table.clone(request) else {}
	req.clients = 0
	if req.mode == nil then req.mode = "cloud" end
	return Runner.runOnce(cfg, req)
end

return Runner
