# API Reference (`api.md`)

Require `@sert` at the top of any spec or helper module:

```luau
--!strict
local sert = require("@sert")
```

`@sert` is the single public module alias (`"sert": "./.sert/sert/src"` in `.luaurc`, or `ReplicatedStorage.sert` in custom Roblox scripts). Spec files omit any trailing `return` statement—`sert` stages `.spec.luau` files directly while preserving line numbers `1..N` for stack traces and LCOV coverage.

Calling `sert(value, msg?)` directly invokes `sert.ok(value, msg?)`. `sert.isRoblox` is `true` inside Roblox Studio and Open Cloud, and `false` in standalone Luau, Lute, and Lune.

---

## Registration and targets

```luau
sert.test(name: string, fn: (ctx: sert.TestContext) -> (), opts?: sert.TestOptions)
sert.describe(name: string, fn: () -> (), opts?: sert.DescribeOptions)
sert.prop(name: string, fn: (g: sert.GenContext) -> (), opts?: sert.PropOptions)
sert.model(name: string, spec: sert.ModelSpec<State, Sut>, opts?: sert.ModelOptions)
```

Every test receives a `TestContext` (`{ name: string, file: string, target: sert.Target, defer: (self, () -> ()) -> () }`).

### Target namespaces

`sert` tags every test with a `Target` (`"portable" | "roblox" | "server" | "client"`). `sert.test`, `sert.describe`, `sert.prop`, `sert.model`, and `sert.sim.vopr` all expose matching target sub-namespaces:

| Namespace | Target | Runs under |
| --- | --- | --- |
| `sert.test(name, fn)` | `"portable"` | `sert run` (and `sert studio` / `sert cloud` when `allTargets = true`) |
| `sert.test.roblox(name, fn)` | `"roblox"` | `sert studio` and `sert cloud` (server DataModel) |
| `sert.test.server(name, fn)` | `"server"` | `sert studio` and `sert cloud` (server DataModel) |
| `sert.test.client(name, fn)` | `"client"` | `sert studio` in `play` mode (`LocalPlayer` client DataModel) |

When a `"roblox"`, `"server"`, or `"client"` test is loaded under standalone `sert run`, `sert` counts it as skipped for the current target rather than failing.

### Modifiers and parameterized tables

Every registration entry (`sert.test`, `sert.describe`, `sert.prop`, and their `.roblox`, `.server`, `.client` namespaces) supports `.skip` and `.focus`. `sert.test` and `sert.describe` (including target namespaces) also provide `.each` and `.eachTuple`:

| Modifier | Behavior |
| --- | --- |
| `.skip(name, fn?)` | Registers the test or suite as skipped (`fn` may be omitted on `test.skip`). |
| `.focus(name, fn)` | Runs only focused tests locally; fails the run when `CI=true` or `--ci` is set unless `--allow-focused` is passed. |
| `.each(cases)(fmt, fn)` | Passes each element `case: T` as a single first argument `fn(case, ctx)`—table cases like `{ 1, 2 }` stay intact instead of being unpacked. |
| `.eachTuple(rows)(fmt, fn)` | Unpacks each row `{ a, b, ... }` into positional arguments `fn(a, b, ..., ctx)`. |

`fmt` accepts either a `string.format` template (`"parses %s"`), positional `$1` / `$2` placeholders, or `(case, index) -> string`:

```luau
--!strict
local sert = require("@sert")

sert.test.each({ { x = 1, y = 2 }, { x = -3, y = 3 } })("cancels vector %s", function(v)
	sert.eq(v.x + (-v.x), 0)
end)

sert.test.eachTuple({
	{ "200", 200 },
	{ "404", 404 },
})("tonumber(%s) == %d", function(raw: string, expected: number)
	sert.eq(tonumber(raw), expected)
end)
```

### Lifecycle hooks and `.config.luau`

```luau
sert.beforeAll(fn: () -> ())
sert.afterAll(fn: () -> ())
sert.beforeEach(fn: () -> ())
sert.afterEach(fn: () -> ())
sert.defer(fn: () -> ())
sert.setup(hooks: { beforeAll?: () -> (), afterAll?: () -> (), beforeEach?: () -> (), afterEach?: () -> () })
```

- Hooks attach to the enclosing `describe` block (or to the current spec file when called at file top level).
- `beforeAll` and `beforeEach` run outer-to-inner; `afterEach`, `afterAll`, and `defer` callbacks run in LIFO order (inner-to-outer, last-registered first).
- If `beforeAll` or `beforeEach` throws, `sert` skips the matching teardown hook so uninitialized state isn't cleaned up, and if both a test body and a teardown hook throw, `sert` reports both failures together.
- Place `.config.luau` (or `init.config.luau`) in `test/` or any subdirectory to register shared hooks across every spec file under that directory, loaded outermost-first.

---

## Procedural assertions

All assertions report the caller's stack frame and (unless noted) return their first argument so you can inline them in expressions (`local user = sert.ok(findUser(id))`).

| Assertion | Description |
| --- | --- |
| `sert.ok(val, msg?)` / `sert(val, msg?)` | Asserts `val` is truthy (`val ~= nil and val ~= false`) and returns `val`. |
| `sert.eq(actual, expected, msg?)` | Deep structural equality with cycle handling, `NaN == NaN`, hex diffs on `buffer`, and nested `Matcher` support. |
| `sert.ne(actual, unexpected, msg?)` | Asserts `not sert.equals(actual, unexpected)`. |
| `sert.equals(a, b) -> boolean` | Boolean predicate using the same deep comparison and matcher rules as `sert.eq`. |
| `sert.lt(a, b, msg?)` / `sert.le(a, b, msg?)` | Asserts `a < b` or `a <= b`. |
| `sert.gt(a, b, msg?)` / `sert.ge(a, b, msg?)` | Asserts `a > b` or `a >= b`. |
| `sert.near(actual, expected, eps?, msg?)` | Component-wise tolerance check (default `eps = 1e-6`) across `number`, `vector`, `Vector2`, `Vector3`, `Vector2int16`, `Vector3int16`, `UDim`, `UDim2`, `Color3`, `CFrame`, `Rect`, and `NumberRange`. |
| `sert.matches(str, pattern, msg?)` | Asserts `string.find(str, pattern) ~= nil` using Luau string patterns. |
| `sert.contains(haystack, needle, msg?)` | Checks substring membership on `string`, or deep/matcher membership across table values. |
| `sert.throws(fn, matcher?, msg?) -> string` | Asserts `fn()` raises an error; optionally checks the error against a Luau pattern string, `Matcher`, or `(err: any) -> boolean`, and returns the formatted error text. |
| `sert.doesNotThrow(fn, msg?) -> ...` | Asserts `fn()` completes without throwing and returns all values returned by `fn()`. |
| `sert.fail(msg?) -> never` | Unconditionally fails the current test. |
| `sert.waitFor(pred, timeout?, interval?, msg?)` | Polls `pred()` until it returns a non-`nil`, non-`false` value (default `timeout = 1` second), advancing the active `sert.env` in headless Luau or `task.wait` in Roblox. |

---

## Asymmetric matchers

Matchers compose at the root or arbitrarily deep inside `sert.eq`, `sert.ne`, `sert.equals`, `sert.contains`, and `sert.calledWith`:

| Matcher | Matches when |
| --- | --- |
| `sert.any()` | Value is any non-`nil` value. |
| `sert.any(kind: string)` | `typeof(v) == kind`, `type(v) == kind`, or `v` is an `Instance` where `v:IsA(kind)` is `true`. |
| `sert.any(pred: (any) -> boolean)` | `pred(v)` returns `true`. |
| `sert.subset(partial: { [any]: any })` | Every key in `partial` matches the corresponding table entry or `Instance` property on `v`; extra keys on `v` are ignored. |
| `sert.within(expected, eps?)` | Numeric or Roblox datatype components lie within `eps` (default `1e-6`). |
| `sert.matching(pattern: string)` | `type(v) == "string"` and `string.find(v, pattern) ~= nil`. |
| `sert.exact(expected)` | Bit-exact comparison: distinguishes `-0.0` from `+0.0`, treats `NaN == NaN`, and walks tables with `rawget` bypassing `__eq` and `__index`. |

```luau
--!strict
local sert = require("@sert")

sert.test("composes matchers inside nested payloads", function()
	local packet = {
		id = 91,
		tag = "spawn:boss",
		origin = Vector3.new(10, 0.0000002, -4),
		meta = { retries = 0, region = "us-east" },
	}
	sert.eq(packet, {
		id = sert.any("number"),
		tag = sert.matching("^spawn:"),
		origin = sert.within(Vector3.new(10, 0, -4), 1e-5),
		meta = sert.subset({ region = "us-east" }),
	})
end)
```

---

## Spies

Create a standalone spy with `sert.spy(fn?)` or wrap an existing table method in place with `sert.spy(tbl, key, impl?)`.

```luau
--!strict
local sert = require("@sert")

sert.test("tracks calls and restores patched methods automatically", function()
	local mailer = {
		send = function(_to: string, _subject: string): boolean
			return true
		end,
	}

	local sendSpy = sert.spy(mailer, "send"):returnsOnce(false)
	sert.eq(mailer.send("a@example.com", "First"), false)
	sert.eq(mailer.send("b@example.com", "Second"), true)

	sert.calledTimes(sendSpy, 2)
	sert.calledWith(sendSpy, "b@example.com", sert.matching("^Sec"))
end)
```

Table spies read and write via `rawget` / `rawset`, so tables guarded by strict `__newindex` metatables still restore cleanly. Patched methods restore in LIFO order at the end of the enclosing test, or in `afterAll` when created inside `beforeAll`.

### `Spy` members and assertions

| Member / Assertion | Description |
| --- | --- |
| `spy.called: boolean` | `true` once invoked at least once. |
| `spy.callCount: number` | Total invocations since creation or `:reset()`. |
| `spy.calls: { SpyCall }` | Recorded argument packs (`call.n` preserves trailing `nil` varargs). Also callable as `spy:calls(fn)` to replace the delegate implementation. |
| `spy.results` | Recorded `{ ok: boolean, n: number, [number]: any }` return or error packs. |
| `spy.lastArgs: SpyCall?` | Arguments from the most recent call. |
| `spy:returns(...)` / `spy:returnsOnce(...)` | Configures default or FIFO one-shot return values. |
| `spy:throws(err?)` / `spy:throwsOnce(err?)` | Configures default or FIFO one-shot raised errors. |
| `spy:reset()` | Clears recorded calls, results, and queued one-shot behaviors. |
| `spy:restore()` | Restores `tbl[key]` early (also runs automatically at scope exit). |
| `sert.called(spy, msg?)` | Asserts `spy.callCount >= 1`. |
| `sert.calledTimes(spy, n, msg?)` | Asserts `spy.callCount == n`. |
| `sert.calledWith(spy, ...expected)` | Asserts at least one recorded call matched `...expected` (supports `Matcher` arguments and exact vararg arity). |

---

## Property testing (`sert.prop` and `sert.gen`)

`sert.prop(name, fn, opts?)` runs `fn(g)` across `runs` trials (default `100`), scaling generator complexity from `0` up to `size` (default `100`). Every draw from `g` records onto a byte tape; when a trial fails, `sert` shrinks the tape directly—eliminating unused draws and binary-searching values toward zero—without requiring custom per-type shrink functions.

```luau
--!strict
local sert = require("@sert")

sert.prop("sorted list stays non-decreasing", function(g)
	local xs = g:draw(sert.gen.list(sert.gen.boundaryInt(-10_000, 10_000)))
	g:assume(#xs >= 2)
	table.sort(xs)
	g:note("min=%d max=%d", xs[1], xs[#xs])
	for i = 2, #xs do
		sert.le(xs[i - 1], xs[i])
	end
end, {
	runs = 200,
	regressions = { 3622492770 },
})
```

### `GenContext` (`g`) methods

| Method | Description |
| --- | --- |
| `g:draw(gen)` | Draws a shrinkable value from any `sert.Generator<T>`. |
| `g:assume(cond, why?)` | Discards the current trial if `cond` is falsy (fails if >90% of trials are discarded). |
| `g:note(fmtOrFn, ...)` | Attaches formatted diagnostic notes printed only on the final shrunk counterexample. |
| `g:int(lo, hi)` / `g:float(lo?, hi?)` / `g:bool(p?)` | Direct numeric and boolean draws (`float` defaults to `[0, 1]`). |
| `g:pick(items)` / `g:weighted(pairs)` | Picks uniformly from `{ T }` or by `{ { weight, Generator<T> } }`. |
| `g:list(gen, min?, max?)` / `g:dict(kGen, vGen, min?, max?)` | Draws shrinkable arrays and dictionaries. |
| `g:optional(gen)` / `g:tuple(...)` / `g:record(shape)` | Draws `T?`, fixed tuples, or shaped record tables. |
| `g:string(charset?, min?, max?)` / `g:bytes(min?, max?)` | Draws strings (`"ascii"`, `"alnum"`, `"alpha"`, `"digit"`, `"hex"`, `"printable"`, `"utf8"`, or custom characters) and `buffer`s. |

`PropOptions` accepts `runs`, `size`, `seed`, `regressions: { number }`, `exhaustive: { size: number }`, `shrinkBudget: { tries?: number, seconds?: number }`, and `timeout`. Use `sert.prop.run(fn, opts?)` to execute a property inline and get back a `PropResult`.

### Built-in generators (`sert.gen`)

`sert.gen` includes generators across scalars, collections, combinators, adversarial payloads, and Roblox datatypes:

| Category | Generators |
| --- | --- |
| Primitives and boundaries | `int(lo, hi)`, `boundaryInt(lo?, hi?)` (biases toward `0`, `±1`, `±2^k`, and bounds while shrinking toward `0`), `float(lo, hi, opts?)` (`opts = { nan?, inf?, negZero?, subnormal? }`), `boundaryFloat(lo?, hi?)` (injects `-0.0`, subnormals, `±math.huge`, and `NaN`, encoded `0.0`-first so finite failures never shrink into `NaN`), `bool()`, `constant(val)` |
| Strings and binary | `string(optsOrMax?)`, `utf8(maxCodepoints?)`, `malformedString(maxBytes?)`, `bytes(min?, max?)` |
| Collections | `list(elem, min?, max?)`, `uniqueList(elem, min?, max?, keyFn?)`, `set(elem, min?, max?)`, `dict(k, v, min?, max?)`, `record(shape)`, `tuple(...)`, `subset(items)`, `shuffle(items)`, `sparseTable(valGen?)` |
| Combinators | `pick(items)`, `oneOf(gens)`, `frequency(weightedPairs)`, `optional(gen)`, `map(gen, fn)`, `filter(gen, pred, maxTries?)`, `bind(gen, fn)`, `lazy(thunk)`, `recursive(base, extend, maxDepth?)`, `custom(drawFn)`, `sample(gen, seed?, size?)` |
| Adversarial & dynamic values | `any(depth?)`, `remotePayload(depth?)` (validates untrusted `RemoteEvent` handlers), `adversarial(depth?)` |
| Roblox datatypes | `vector2(lo?, hi?)`, `vector3(lo?, hi?)`, `color3()`, `udim()`, `udim2()`, `cframe(posBound?)`, `numberRange(lo?, hi?)`, `rect(bound?)`, `enum(Enum.SomeEnum)` |

---

## Universal laws (`sert.laws`)

Register standard algebraic and round-trip properties in a single call (each registers a `describe` block with individual law properties):

| Helper | Verifies |
| --- | --- |
| `sert.laws.codec(name, { gen, encode, decode, eq?, encodedEq?, deterministic? }, opts?)` | `decode(encode(x)) == x`, plus `encode(x) == encode(x)` when `deterministic ~= false`. |
| `sert.laws.order(name, { gen, lt, eq? }, opts?)` | Irreflexivity, asymmetry, transitivity, and trichotomy of `lt(a, b)`. |
| `sert.laws.algebra(name, { gen, op, identity?, hasIdentity?, associative?, commutative?, idempotent?, inverse?, eq? }, opts?)` | Requested algebraic laws (`hasIdentity = true` allows `identity = nil`). |
| `sert.laws.differential(name, { gen, sut, oracle, eq? }, opts?)` | `sut(x)` matches a reference `oracle(x)` (including matching throws vs returns). |

---

## Stateful model testing (`sert.model`)

`sert.model` generates random sequences of state-machine commands against a system under test (`Sut`), compares results against a pure reference `State`, checks invariants after every step, and shrinks failing traces down to the shortest sequence.

```luau
--!strict
local sert = require("@sert")

sert.model("bounded counter", {
	init = function() return 0 end,
	setup = function()
		local value = 0
		return {
			add = function(d: number) value = math.clamp(value + d, 0, 10); return value end,
			reset = function() value = 0 end,
			get = function() return value end,
		}
	end,
	commands = {
		add = {
			gen = function(_state, g) return g:int(-5, 8) end,
			run = function(sut, d) return sut.add(d) end,
			next = function(state, d) return math.clamp(state + d, 0, 10) end,
			post = function(state, _sut, _d, res) sert.eq(res, state) end,
		},
		reset = {
			pre = function(state) return state > 0 end,
			run = function(sut) sut.reset() end,
			next = function() return 0 end,
		},
	},
	invariants = {
		inBounds = function(state, sut)
			sert.eq(sut.get(), state)
			sert.ge(state, 0)
			sert.le(state, 10)
		end,
	},
})
```

- `sert.model(name, spec, opts?)` registers a test (with `.roblox`, `.server`, `.client`, `.skip`, `.focus`).
- `sert.model.check(spec, opts?)` runs immediately; `sert.model.replay(spec, trace, world?)` deterministically replays `{ { "add", 5 }, { "reset" } }` traces in unit regressions.
- Rejected `pre(state, arg)` draws automatically redraw (`redraw = true` by default, up to `maxRedraws = 16`) instead of wasting sequence steps.

---

## Bytes, output capture, and programmatic runner

| Function | Description |
| --- | --- |
| `sert.bytes.hex(bufOrStr)` | Encodes a `buffer` or binary `string` as lowercase hex (`"deadbeef"`). |
| `sert.bytes.fromHex(hex)` | Decodes hex (ignoring whitespace and `_` separators) into a `buffer`. |
| `sert.print(...)` / `sert.warn(...)` | Writes through `sert`'s active output sink. |
| `sert.quiet(fn, ...)` | Runs `fn(...)` while discarding `sert.print` / `sert.warn` output. |
| `sert.capture(fn, ...) -> { string }` | Captures `sert.print` / `sert.warn` lines emitted during `fn(...)` and returns them (`(lines, ...ret)`). |
| `sert.run(opts?: sert.RunOptions) -> sert.Results` | Executes registered specs and returns `{ passed, failed, skipped, duration, failures }`. |
| `sert.parseCliArgs(...: string) -> sert.RunOptions` | Parses standalone Luau `-a` runner flags into `RunOptions`. |
