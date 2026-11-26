# Migrating to `sert` (`migration.md`)

This guide maps test patterns from Jest-Lua, TestEZ, and frktest to `sert`. Because `sert` keeps one procedural assertion vocabulary (`sert.eq`, `sert.ok`, `sert.throws`) and one headless environment (`sert.env`), it does not ship a runtime `expect()` compatibility shim.

Specs in `sert` omit any trailing `return` statement—`sert` stages `.spec.luau` files directly while preserving exact line numbers for stack traces and LCOV coverage.

---

## Side-by-side cheat sheet

| Concept | Jest-Lua | TestEZ | frktest | `sert` |
| --- | --- | --- | --- | --- |
| Suite block | `describe(name, fn)` | `describe(name, fn)` | `test.suite(name, fn)` | `sert.describe(name, fn)` |
| Test case | `test(name, fn)` / `it(name, fn)` | `it(name, fn)` | `test.case(name, fn)` | `sert.test(name, fn)` |
| Skip / Focus | `test.skip` / `test.only` | `itSKIP` / `itFOCUS` / `FIXME` | `test.skip` | `sert.test.skip` / `sert.test.focus` |
| Table-driven cases | `test.each(rows)(fmt, fn)` | manual loop | manual loop | `sert.test.each(cases)` / `sert.test.eachTuple(rows)` |
| Hooks | `beforeAll` / `beforeEach` / `afterEach` / `afterAll` | `beforeAll` / `beforeEach` / `afterEach` / `afterAll` | `before_each` / `after_each` | `sert.beforeAll` / `beforeEach` / `afterEach` / `afterAll` / `ctx:defer` |
| Truthy | `expect(x).toBeTruthy()` | `expect(x).to.be.ok()` | `check.truthy(x)` | `sert.ok(x)` |
| Strict / Deep equality | `expect(a).toBe(b)` / `toEqual(b)` | `expect(a).to.equal(b)` | `check.equal(a, b)` / `check.table.equal(a, b)` | `sert.eq(a, b)` (or `sert.exact(b)` for raw `rawget`/`-0.0`) |
| Inequality | `expect(a).never.toEqual(b)` | `expect(a).never.to.equal(b)` | `check.not_equal(a, b)` | `sert.ne(a, b)` |
| Partial table match | `expect(a).toMatchObject(sub)` | — | — | `sert.eq(a, sert.subset(sub))` |
| Approximate number | `expect(a).toBeCloseTo(b, digits)` | `expect(a).to.be.near(b, eps)` | `check.close_to(a, b, eps)` | `sert.near(a, b, eps)` |
| Regex / Pattern | `expect(s).toMatch(pat)` | — | — | `sert.matches(s, pat)` / `sert.matching(pat)` |
| Membership | `expect(arr).toContainEqual(v)` | — | — | `sert.contains(arr, v)` |
| Expected error | `expect(fn).toThrow(pat?)` | `expect(fn).to.throw(pat?)` | `check.should_error(fn)` | `sert.throws(fn, pat?)` |
| Spies / Mocks | `jest.fn()` / `jest.spyOn(t, k)` | — | — | `sert.spy(fn?)` / `sert.spy(t, k, impl?)` |
| Calls / Args | `toHaveBeenCalledTimes(n)` / `toHaveBeenCalledWith(...)` | — | — | `sert.calledTimes(s, n)` / `sert.calledWith(s, ...)` |
| Snapshots | `toMatchSnapshot()` / `toMatchInlineSnapshot()` | — | — | `sert.snapshot(v)` / `sert.inlineSnapshot(v, ...)` |
| Fake timers | `jest.useFakeTimers()` / `advanceTimersByTime(ms)` | — | — | `env = sert.env.new()` / `env:advance(seconds)` |

---

## Migrating from Jest-Lua

Jest-Lua specs typically run inside Roblox Studio or Open Cloud, build matcher chains (`expect(x).toEqual(...)`), and use `jest.fn` and `jest.useFakeTimers()`.

**Before (Jest-Lua):**

```luau
local JestGlobals = require(Packages.Dev.JestGlobals)
local describe, it, expect, jest = JestGlobals.describe, JestGlobals.it, JestGlobals.expect, JestGlobals.jest

describe("Wallet", function()
	jest.useFakeTimers()

	it("credits pending payouts after cooldown", function()
		local notify = jest.fn()
		local wallet = Wallet.new(notify)
		wallet:queuePayout(50)
		jest.advanceTimersByTime(2000)

		expect(wallet:balance()).toBe(50)
		expect(notify).toHaveBeenCalledTimes(1)
		expect(notify).toHaveBeenCalledWith(expect.objectContaining({ amount = 50 }))
	end)
end)
```

**After (`sert`):**

```luau
--!strict
local sert = require("@sert")

sert.describe("Wallet", function()
	sert.test("credits pending payouts after cooldown", function(ctx)
		local env = sert.env.new()
		ctx:defer(function() env:destroy() end)

		local notify = sert.spy()
		local wallet = env:run(function()
			local w = Wallet.new(notify)
			w:queuePayout(50)
			return w
		end)

		env:advance(2)
		sert.eq(wallet:balance(), 50)
		sert.calledTimes(notify, 1)
		sert.calledWith(notify, sert.subset({ amount = 50 }))
	end)
end)
```

Key differences when converting Jest-Lua suites:

- **Seconds, not milliseconds:** `env:advance(2)` advances 2 seconds across virtual `task.delay` and `RunService` frames rather than `2000` ms.
- **Spies restore on scope exit:** `sert.spy(tbl, "method")` wraps via `rawget`/`rawset` and automatically restores `tbl.method` after each test (`spy:restore()` restores early without erasing `spy.calls`).
- **Two-argument `.eachTuple` vs single-argument `.each`:** Use `sert.test.eachTuple(rows)` when each row table unpacks into multiple handler parameters, and `sert.test.each(cases)` when each element is passed whole as one argument.

---

## Migrating from TestEZ

TestEZ specs return `function() describe(...) end` and use `expect(...).to.*` chains.

**Before (TestEZ):**

```luau
return function()
	describe("RateLimiter", function()
		it("blocks calls above the burst limit", function()
			local limiter = RateLimiter.new(2)
			expect(limiter:allow("u1")).to.equal(true)
			expect(limiter:allow("u1")).to.equal(true)
			expect(limiter:allow("u1")).to.equal(false)
		end)

		it("throws on non-positive limits", function()
			expect(function()
				RateLimiter.new(0)
			end).to.throw("positive")
		end)
	end)
end
```

**After (`sert`):**

```luau
--!strict
local sert = require("@sert")

sert.describe("RateLimiter", function()
	sert.test("blocks calls above the burst limit", function()
		local limiter = RateLimiter.new(2)
		sert.eq(limiter:allow("u1"), true)
		sert.eq(limiter:allow("u1"), true)
		sert.eq(limiter:allow("u1"), false)
	end)

	sert.test("throws on non-positive limits", function()
		sert.throws(function()
			RateLimiter.new(0)
		end, "positive")
	end)
end)
```

Key differences when converting TestEZ suites:

- **Remove the outer `return function()` wrapper:** Top-level calls to `sert.describe` and `sert.test` register specs directly when `sert` loads the file.
- **Shared setup lives in `.config.luau`:** Put suite-wide `beforeEach`/`afterEach` hooks in `test/.config.luau` rather than duplicating setup across TestEZ spec files.
- **Engine specs keep their target tags:** Tests that require real Studio physics, `Humanoid`, or GPU layout move from generic `it(...)` to `sert.test.roblox(...)`, `sert.test.server(...)`, or `sert.test.client(...)`; everything else runs in milliseconds under headless `sert run`.

---

## Migrating from frktest

frktest registers tests via `test.case` / `test.suite` inside a Lune script and executes checks through `@frktest/assert`.

**Before (frktest):**

```luau
local test = require("@pkg/frktest").test
local check = require("@pkg/frktest").assert

test.suite("Encoder", function()
	test.case("roundtrips packets", function()
		local raw = { id = 7, ok = true }
		check.table.equal(Encoder.decode(Encoder.encode(raw)), raw)
	end)
end)
```

**After (`sert`):**

```luau
--!strict
local sert = require("@sert")

sert.describe("Encoder", function()
	sert.test("roundtrips packets", function()
		local raw = { id = 7, ok = true }
		sert.eq(Encoder.decode(Encoder.encode(raw)), raw)
	end)

	sert.laws.codec("packet codec satisfies round-trip law", {
		gen = sert.gen.record({ id = sert.gen.int(1, 1000), ok = sert.gen.bool() }),
		encode = Encoder.encode,
		decode = Encoder.decode,
	})
end)
```

If you run under Lune today, pass `--runner lune` to `sert run` during migration or configure `[test].runner = "lune"` in `sert.toml`. Moving pure Luau suites onto the default `luau` runner unlocks `--coverage`, `sert mutate`, and `luau --codegen` bytecode compilation.

---

## Incremental migration checklist

1. Keep existing tests runnable while adding new `.spec.luau` files under a separate directory (for example `specs/` or `test/unit/`) pointed to by `[test].specs` in `sert.toml`.
2. Add `[test].stage = "default.project.json"` so existing Rojo modules mount via `require("@game/...")` inside `sert.env` with zero source edits and zero `setfenv`.
3. Convert leaf modules first, verify both new and old Luau type solvers via `sert lint`, and split Studio-only integration checks into `.roblox`, `.server`, or `.client` targets.
