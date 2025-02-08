-- TODO: every 5s print which tests are still running to find hanging tests!!!

type Map = { [string]: any }
type Function = (...any) -> ...any

local FOCUS = table.freeze({ type = "FOCUS" })
local SKIP = table.freeze({ type = "SKIP" })
local TIME = table.freeze({ type = "TIME" })

local reservedKeys = {
	after = true,
	afterEach = true,
	beforeEach = true,
	_async = true,
	_focus = true,
	_skip = true,
}

local Sert = { FOCUS = FOCUS, SKIP = SKIP, TIME = TIME }

local function assertHook(hook: Function, label: string, name)
	if hook then
		local t = type(hook)
		assert(t == "function", `function expected for {name}.test.{label}, got {t}`)
	end
end

local function isPromise(object)
	return type(object) == "table" and type(object.andThen) == "function" and type(object.awaitStatus) == "function"
end

local function runTest(key: string, test: Function, tests: Map, tasks: Map, results: Map, async: boolean)
	if tests.beforeEach then
		tests.beforeEach()
	end

	local testStart = os.clock()
	local ok, result = pcall(test)
	if ok and isPromise(result) then
		local status, rejection = result:awaitStatus()
		if status == "Rejected" then
			ok, result = false, rejection
		end
	end
	results[key] = { _status = ok or result, [TIME] = os.clock() - testStart }

	if tests.afterEach then
		tests.afterEach()
	end

	tasks.num -= 1
	if tasks.num == 0 and async then
		coroutine.resume(tasks.main)
	end
end

local function runTestModule(module: ModuleScript, globals: Map?, globalAsync: boolean): Map
	local name = module.Name
	local moduleStart = os.clock()
	local ok, tests = pcall(require, module)

	assertHook(tests.beforeEach, "beforeEach", name)
	assertHook(tests.afterEach, "afterEach", name)
	assertHook(tests.after, "after", name)

	local results = {}

	if ok then
		local async = globalAsync and tests._async ~= false
		local tasks = { num = #tests, main = async and coroutine.running() }

		for key, test in tests do
			if reservedKeys[key] then
				continue
			end
			if tests._skip then
				results[key] = SKIP
				continue
			end
			assert(type(test) == "function", `{name} > {key}: function expected for test, got {type(test)}`)
			if globals then -- PERF: DISABLES LUAU OPTIMIZATIONS
				setfenv(test, globals)
			end
			local process = if async then task.spawn else pcall
			process(runTest, key, test, tests, tasks, results, async)
		end

		if tasks.num > 0 and async then
			coroutine.yield()
		end

		results[TIME] = os.clock() - moduleStart

		if tests._focus then
			results[FOCUS] = true
		end
	end

	if tests.after then
		tests.after()
	end

	return results
end

local run
local function runTask(object: Instance, results: Map, globals: Map, async: boolean, tasks: Map)
	run(object, results, globals, async)
	tasks.num -= 1
	if tasks.num == 0 and async then
		coroutine.resume(tasks.main)
	end
end

run = function(object: Instance, results: Map, globals: Map, async: boolean): Map
	local name = object.Name

	if object:IsA("ModuleScript") and name:find("%.test$") then
		results[name] = runTestModule(object, globals, async)
	else
		local children = object:GetChildren()
		local tasks = { num = #children, main = async and coroutine.running() }
		local childResults = {}

		for _, child in children do
			local process = if async then task.spawn else pcall
			process(runTask, child, childResults, globals, async, tasks)
		end

		if tasks.num > 0 and async then
			coroutine.yield()
		end

		if next(childResults) then
			results[name] = childResults
		end
	end

	return results
end

local function formatTime(duration: number): string
	return if duration < 1 then tostring(math.floor(duration * 1000)) .. " ms" else string.format("%.03f s", duration)
end

local function formatResults(results: Map, lines: { string }, depth: number, focus: boolean?): string
	local indent = string.rep(" ", depth * 2)

	local maxLength = 0
	for key in results do
		maxLength = math.max(maxLength, #tostring(key))
	end
	maxLength += 2

	for key, value in results do
		if typeof(value) == "table" and (not focus or value._focus) then
			if value == SKIP then
				table.insert(lines, `{indent}  🟡 {key}`)
				continue
			end

			local elapsed = value[TIME]
			local fTime = if elapsed then formatTime(elapsed) else ""
			if value._status then
				local ok = value._status == true
				local status = if ok then "✅" else "❌"
				local err = ok and "" or `\n{indent}    ⚠️ {value._status}`
				local spacer = string.rep(" ", maxLength - #tostring(key))
				table.insert(lines, `{indent}  {status} {key}{spacer}{fTime}{err}`)
			else
				table.insert(lines, `{indent}{key}  {fTime}\n{formatResults(value, {}, depth + 1)}`)
			end
		end
	end

	table.sort(lines)
	return table.concat(lines, "\n")
end

local function statusCount(results: Map): (number, number)
	local passed, failed, skipped = 0, 0, 0
	for _, value in results do
		if value == SKIP then
			skipped += 1
			continue
		end
		if typeof(value) == "table" then
			if value._status then
				if value._status == true then
					passed += 1
				else
					failed += 1
				end
			else
				local a, b, c = statusCount(value)
				passed += a
				failed += b
				skipped += c
			end
		end
	end
	return passed, failed, skipped
end

local function shouldFocus(results)
	for _, value in results do
		if typeof(value) == "table" then
			if value[FOCUS] or shouldFocus(value) then
				return true
			end
		end
	end
	return false
end

function Sert.run(object: Instance, globals: Map?, async: boolean?, silent: boolean?): Map
	if not silent then
		print("Running Tests...")
	end

	local results = run(object, {}, globals, if async == false then false else true)
	if silent then
		return results
	end

	print("Test Results:\n" .. formatResults(results, {}, 0, shouldFocus(results)))

	local passed, failed, skipped = statusCount(results)
	local status = ` | {passed} passed | {failed} failed | {skipped} skipped`

	if failed > 0 then
		warn("⚠️ Some tests failed! Check output for details." .. status)
	else
		print("✅ All tests passed!" .. status)
	end

	return results
end

return Sert
