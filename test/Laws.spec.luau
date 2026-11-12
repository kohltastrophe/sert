--!strict
local registry = require("../src/core/registry")
local sert = require("../src")

local gen = sert.gen
local laws = sert.laws

local function runIsolated(register: () -> (), opts: sert.RunOptions?): sert.Results
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, res = pcall(function(): sert.Results
		return registry.withState(sub, function(): sert.Results
			register()
			local merged: sert.RunOptions = if opts ~= nil then table.clone(opts) else {}
			if merged.quiet == nil and merged.silent == nil then merged.quiet = true end
			if merged.raise == nil then merged.raise = false end
			return sert.run(merged)
		end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(res, 0) end
	return res
end

-- Deterministic hex codec
laws.codec("hex buffer codec", {
	gen = gen.bytes(0, 24),
	encode = function(b: buffer): string return sert.bytes.hex(b) end,
	decode = function(h: string): buffer return sert.bytes.fromHex(h) end,
}, { runs = 40 })

-- Codec with custom `eq` and `encodedEq` (quantized float + unordered bag representation)
laws.codec("quantized float codec with eq and encodedEq", {
	gen = gen.float(-100, 100),
	encode = function(x: number): { scaled: number, saltOrder: { string } }
		local q = math.round(x * 100)
		return { scaled = q, saltOrder = { "a", "b" } }
	end,
	decode = function(enc: { scaled: number, saltOrder: { string } }): number return enc.scaled / 100 end,
	eq = function(a: number, b: number): boolean return math.abs(a - b) <= 0.01 end,
	encodedEq = function(
		a: { scaled: number, saltOrder: { string } },
		b: { scaled: number, saltOrder: { string } }
	): boolean
		return a.scaled == b.scaled
	end,
}, { runs = 40 })

-- Randomized / salted codec (`deterministic = false`)
local nonceCounter = 0
laws.codec("salted non-deterministic xor codec", {
	gen = gen.bytes(0, 16),
	deterministic = false,
	encode = function(plain: buffer): buffer
		nonceCounter = (nonceCounter + 1) % 251 + 1
		local mask = nonceCounter
		local n = buffer.len(plain)
		local out = buffer.create(n + 1)
		buffer.writeu8(out, 0, mask)
		for i = 0, n - 1 do
			buffer.writeu8(out, i + 1, bit32.bxor(buffer.readu8(plain, i), mask))
		end
		return out
	end,
	decode = function(cipher: buffer): buffer
		local mask = buffer.readu8(cipher, 0)
		local n = buffer.len(cipher) - 1
		local out = buffer.create(n)
		for i = 0, n - 1 do
			buffer.writeu8(out, i, bit32.bxor(buffer.readu8(cipher, i + 1), mask))
		end
		return out
	end,
}, { runs = 40 })

-- Strict weak ordering laws (numbers and case-insensitive strings with custom equivalence)
laws.order("integer strict order", {
	gen = gen.int(-50, 50),
	lt = function(a: number, b: number): boolean return a < b end,
	eq = function(a: number, b: number): boolean return a == b end,
}, { runs = 50 })

laws.order("case-insensitive string strict weak order", {
	gen = gen.string("aAbBcC12", 0, 6),
	lt = function(a: string, b: string): boolean return string.lower(a) < string.lower(b) end,
	eq = function(a: string, b: string): boolean return string.lower(a) == string.lower(b) end,
}, { runs = 50 })

-- Algebraic laws: Abelian group (`+`, `0`, `-x`)
laws.algebra("integer addition abelian group", {
	gen = gen.int(-1000, 1000),
	op = function(a: number, b: number): number return a + b end,
	identity = 0,
	associative = true,
	commutative = true,
	inverse = function(a: number): number return -a end,
}, { runs = 40 })

-- Algebraic laws: Semigroup without identity (`hasIdentity = false`)
laws.algebra("non-empty string semigroup", {
	gen = gen.string("xyz", 1, 5),
	op = function(a: string, b: string): string return a .. b end,
	hasIdentity = false,
	associative = true,
	commutative = false,
}, { runs = 40 })

-- Algebraic laws: Nullable monoid (`identity = nil`, `hasIdentity = true`)
local nullableMaxSpec: sert.AlgebraSpec<number?> = {
	gen = gen.optional(gen.int(-20, 20)),
	op = function(a: number?, b: number?): number?
		if a == nil then return b end
		if b == nil then return a end
		return math.max(a, b)
	end,
	identity = nil,
	hasIdentity = true,
	associative = true,
	commutative = true,
	idempotent = true,
}
laws.algebra("nullable max monoid", nullableMaxSpec, { runs = 40 })

-- Distributivity check via `sert.prop` alongside `laws.algebra`
sert.prop("multiplication distributes over addition", function(g: sert.Gen)
	local a, b, c = g:int(-100, 100), g:int(-100, 100), g:int(-100, 100)
	sert.eq(a * (b + c), a * b + a * c)
	sert.eq((a + b) * c, a * c + b * c)
end, { runs = 40 })

-- Differential laws: pure function equivalence (binary search lower-bound vs linear scan)
laws.differential("sorted lower-bound binary search vs linear oracle", {
	gen = gen.record({
		items = gen.list(gen.int(-10, 10), 0, 16),
		target = gen.int(-12, 12),
	}),
	sut = function(input: { items: { number }, target: number }): number
		local arr = table.clone(input.items)
		table.sort(arr)
		local lo, hi = 1, #arr + 1
		while lo < hi do
			local mid = lo + (hi - lo) // 2
			if arr[mid] < input.target then
				lo = mid + 1
			else
				hi = mid
			end
		end
		return lo
	end,
	oracle = function(input: { items: { number }, target: number }): number
		local arr = table.clone(input.items)
		table.sort(arr)
		for i, v in arr do
			if v >= input.target then return i end
		end
		return #arr + 1
	end,
}, { runs = 50 })

-- Differential laws: stateful command sequence equivalence (ring-buffer deque vs array oracle)
type DequeOp = { op: string, val: number }
local dequeOpGen: sert.Generator<{ DequeOp }> = gen.list(
	gen.record({
		op = gen.pick({ "pushBack", "pushFront", "popBack", "popFront" }),
		val = gen.int(1, 50),
	}) :: any,
	0,
	20
)

laws.differential("ring deque command sequence vs array oracle", {
	gen = dequeOpGen,
	sut = function(ops: { DequeOp }): { any }
		local store: { [number]: number } = {}
		local head, tail = 0, -1
		local outputs: { any } = {}
		for _, cmd in ops do
			if cmd.op == "pushBack" then
				tail += 1
				store[tail] = cmd.val
			elseif cmd.op == "pushFront" then
				head -= 1
				store[head] = cmd.val
			elseif cmd.op == "popBack" then
				if head <= tail then
					table.insert(outputs, store[tail])
					store[tail] = nil
					tail -= 1
				else
					table.insert(outputs, false)
				end
			elseif cmd.op == "popFront" then
				if head <= tail then
					table.insert(outputs, store[head])
					store[head] = nil
					head += 1
				else
					table.insert(outputs, false)
				end
			end
		end
		local remaining: { number } = {}
		for idx = head, tail do
			table.insert(remaining, store[idx])
		end
		return { out = outputs, rem = remaining }
	end,
	oracle = function(ops: { DequeOp }): { any }
		local arr: { number } = {}
		local outputs: { any } = {}
		for _, cmd in ops do
			if cmd.op == "pushBack" then
				table.insert(arr, cmd.val)
			elseif cmd.op == "pushFront" then
				table.insert(arr, 1, cmd.val)
			elseif cmd.op == "popBack" then
				table.insert(outputs, if #arr > 0 then table.remove(arr) :: any else false)
			elseif cmd.op == "popFront" then
				table.insert(outputs, if #arr > 0 then table.remove(arr, 1) :: any else false)
			end
		end
		return { out = outputs, rem = arr }
	end,
}, { runs = 50 })

sert.describe("sert.laws violation detection", function()
	sert.test("detects broken codec, broken order, broken algebra, and divergent differential specs", function()
		local brokenCodec = runIsolated(function()
			laws.codec("lossy codec", {
				gen = gen.int(0, 20),
				encode = function(x: number): number return x // 2 end,
				decode = function(y: number): number return y * 2 end,
			}, { runs = 30, seed = 5 })
		end)
		sert.eq(brokenCodec.failed, 1)
		sert.contains(brokenCodec.failures[1], "codec round-trip")

		local nondetMarkedDet = runIsolated(function()
			local salt = 0
			laws.codec("unmarked salted codec", {
				gen = gen.int(1, 10),
				encode = function(x: number): { number }
					salt += 1
					return { x, salt }
				end,
				decode = function(pair: { number }): number return pair[1] end,
			}, { runs = 10, seed = 5 })
		end)
		sert.eq(nondetMarkedDet.failed, 1)
		sert.contains(nondetMarkedDet.failures[1], "codec determinism")

		local brokenOrder = runIsolated(function()
			laws.order("non-irreflexive order", {
				gen = gen.int(1, 5),
				lt = function(a: number, b: number): boolean return a <= b end,
			}, { runs = 10, seed = 5 })
		end)
		sert.eq(brokenOrder.failed, 1)
		sert.contains(brokenOrder.failures[1], "irreflexivity")

		local cyclicOrder = runIsolated(function()
			-- Rock (0) < Paper (1) < Scissors (2) < Rock (0) violates transitivity!
			laws.order("cyclic rps order", {
				gen = gen.int(0, 2),
				lt = function(a: number, b: number): boolean return (b - a) % 3 == 1 end,
			}, { runs = 40, seed = 9 })
		end)
		sert.eq(cyclicOrder.failed, 1)
		sert.contains(cyclicOrder.failures[1], "transitivity")

		local brokenAlgebra = runIsolated(function()
			laws.algebra("subtraction is not associative or commutative", {
				gen = gen.int(-20, 20),
				op = function(a: number, b: number): number return a - b end,
				identity = 0,
				associative = true,
				commutative = true,
			}, { runs = 30, seed = 7 })
		end)
		sert.ge(brokenAlgebra.failed, 2)

		local brokenDiff = runIsolated(function()
			laws.differential("off-by-one sut", {
				gen = gen.int(0, 50),
				sut = function(x: number): number return if x >= 10 then x + 1 else x end,
				oracle = function(x: number): number return x end,
			}, { runs = 40, seed = 12 })
		end)
		sert.eq(brokenDiff.failed, 1)
		sert.contains(brokenDiff.failures[1], "differential law")
	end)
end)
