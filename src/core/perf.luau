--!strict
--!nolint DeprecatedApi
-- Allocation assertions (`allocs`, `maxAllocs`, `noAllocs`) and benchmark registration (`bench`).

local registry = require("./registry")
local util = require("./util")

export type BenchContext = registry.BenchContext
export type BenchOptions = registry.BenchOptions

local perf = {}

local DEFAULT_WARMUP = 4
local DEFAULT_SAMPLES = 32
local NO_ALLOC_TOLERANCE_KB = 0.01

local function readMemoryKb(): number
	local cg: any = collectgarbage
	if type(cg) == "function" then
		local ok, kb = pcall(cg, "count")
		if ok and type(kb) == "number" then return kb end
	end
	return gcinfo()
end

local function collectMemory()
	local cg: any = collectgarbage
	if type(cg) == "function" then pcall(cg, "collect") end
end

--- Measures average heap growth per call to `fn` in KB (`>= 0`).
function perf.allocs(fn: () -> (), warmup: number?, samples: number?): number
	if type(fn) ~= "function" then error(`sert.allocs: expected a function, got {util.typeof(fn)}`, util.outside()) end
	local warmupCount = if warmup ~= nil then warmup else DEFAULT_WARMUP
	if type(warmupCount) ~= "number" or warmupCount < 0 or warmupCount ~= math.floor(warmupCount) then
		error(`sert.allocs: expected non-negative integer warmup, got {tostring(warmup)}`, util.outside())
	end
	local sampleCount = if samples ~= nil then samples else DEFAULT_SAMPLES
	if type(sampleCount) ~= "number" or sampleCount < 1 or sampleCount ~= math.floor(sampleCount) then
		error(`sert.allocs: expected positive integer samples, got {tostring(samples)}`, util.outside())
	end

	for _ = 1, warmupCount do
		fn()
	end
	collectMemory()
	local before = readMemoryKb()
	for _ = 1, sampleCount do
		fn()
	end
	local after = readMemoryKb()
	return math.max(0, (after - before) / sampleCount)
end

--- Asserts that average heap allocation per call to `fn` does not exceed `maxKb` (KB/call), returning the measured KB.
function perf.maxAllocs(maxKb: number, fn: () -> (), msg: string?): number
	registry.recordAssertion("allocs")
	if type(maxKb) ~= "number" or maxKb < 0 or maxKb ~= maxKb then
		error(`sert.maxAllocs: expected non-negative maxKb number, got {tostring(maxKb)}`, util.outside())
	end
	if type(fn) ~= "function" then
		error(`sert.maxAllocs: expected a function, got {util.typeof(fn)}`, util.outside())
	end
	local kb = perf.allocs(fn)
	if kb > maxKb then
		error(
			`{msg or "allocation budget exceeded"}: expected <= {string.format("%.4g", maxKb)} KB/call, got {string.format(
				"%.4g",
				kb
			)} KB/call`,
			util.outside()
		)
	end
	return kb
end

--- Asserts that calling `fn` performs zero heap allocations (within `<= 0.01` KB/call measurement noise).
function perf.noAllocs(fn: () -> (), msg: string?)
	registry.recordAssertion("allocs")
	if type(fn) ~= "function" then
		error(`sert.noAllocs: expected a function, got {util.typeof(fn)}`, util.outside())
	end
	local kb = perf.allocs(fn)
	if kb > NO_ALLOC_TOLERANCE_KB then
		error(
			`{msg or "unexpected allocation"}: expected <= {NO_ALLOC_TOLERANCE_KB} KB/call, got {string.format(
				"%.4g",
				kb
			)} KB/call`,
			util.outside()
		)
	end
end

--- Registers a named benchmark that executes when `RunOptions.bench == true` (or `--bench`).
function perf.bench(name: string, fn: (b: BenchContext) -> (), opts: BenchOptions?)
	registry.registerBench(name, fn, opts)
end

return table.freeze(perf)
