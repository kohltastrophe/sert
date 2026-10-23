# The Luau API

This guide covers the public Luau API exported by `@sert`. See [README.md](../README.md) for installation and [cli.md](cli.md) for CLI commands and flags.

## Require paths

Only these require paths are public. Everything else under `.sert/sert/src` is internal.

| Path | Module |
| --- | --- |
| `@sert` | The test runner, assertions, and all submodules (`sert.env`, `sert.doubles`, `sert.sim`, `sert.rng`, `sert.bytes`, `sert.format`). |
| `@sert/doubles` | Standalone Roblox engine doubles (`Signal`, `Datatypes`, `Instance`, `DataStore`, `MemoryStore`, `HttpService`, `EncodingService`, `Generated`). See [env.md](env.md#doubles). |
| `@sert/sim` | The multi-peer simulator (`Sim.World`, `Sim.Scheduler`, `Sim.Runner`, `Sim.Spec`, `Sim.spec`, `Sim.checkSpec`, `Sim.vopr`, `Sim.prop`, `Sim.model`, `Sim.explore`). See [sim.md](sim.md). |
| `@sert/rng` | Seeded `xorshift32` random stream and FNV-1a hashing (`sert.rng`). |
| `@sert/bytes` | Buffer hex formatting and byte assertions (`sert.bytes`). |

In Roblox, require the package from `ReplicatedStorage` with `require(ReplicatedStorage.sert)`. See [roblox.md](roblox.md#requiring-sert-in-roblox).

## Assertions

Every assertion throws an error on failure and returns its first argument on success. Pass `why` to prefix the failure message.

```luau
local sert = require("@sert")

sert.test("assertions and frames", function()
	sert.eq(sert.contains("user-7", "user"), "user-7")
	sert.near(0.1 + 0.2, 0.3)
	sert.fails(function()
		error({ code = 404 })
	end, function(err)
		return err.code == 404
	end)

	local env = sert.env.new()
	local fired = false
	env.task.delay(0.05, function()
		fired = true
	end)
	sert.frames(function()
		return fired
	end, 10, "the delay fired")
end)

return {}
```

| Call | Checks |
| --- | --- |
| `sert(cond: T, why?: string) -> T` | `cond` is truthy (`not nil` and `not false`). |
| `sert.eq(v: T, expected: any, why?: string) -> T` | Deep equality. Compares plain tables by structure (cycle-safe), tables with metatables by identity or `__eq`, buffers by byte content, and `NaN` equal to `NaN`. Prints the path to the first difference on failure. |
| `sert.rawEq(v: T, expected: any, why?: string) -> T` | Like `eq`, but descends into tables with metatables and ignores `__eq`. Useful for codecs and datatype doubles. |
| `sert.neq(v: T, unexpected: any, why?: string) -> T` | Asserts that `not sert.equals(v, unexpected)`. |
| `sert.equals(a: any, b: any) -> boolean` | Returns `eq`'s deep comparison as a boolean without throwing. |
| `sert.near(v: T, expected: T, eps?: number, why?: string) -> T` | Checks that each component is within `eps` (default `1e-6`). Works on numbers, `Vector2`, `Vector3`, `Vector2int16`, `Vector3int16`, `Color3`, `UDim`, `UDim2`, `CFrame`, `Rect`, `NumberRange`, and native `vector` values. |
| `sert.contains(text: any, fragment: string, why?: string) -> string` | Checks that `tostring(text)` contains the plain substring `fragment` and returns the string. |
| `sert.matches(text: any, pattern: string, why?: string) -> string` | Checks that `tostring(text)` matches the Luau pattern `pattern` and returns the string. |
| `sert.fails(fn: () -> ...any, matcher?: string \| (any) -> boolean, why?: string) -> string` | Checks that `fn` throws an error. `matcher` can be a plain substring of the error message or a predicate function over the raw error value. Returns the formatted error string. |
| `sert.waitFor(predicate: () -> T, timeout?: number, why?: string, step?: (number?) -> any) -> T` | Polls until `predicate()` returns a truthy value (default `timeout` is `1` s). Uses `task.wait` in Roblox or steps the active `sert.env` in headless Luau. |
| `sert.frames(done: () -> any, frames?: number, why?: string, step?: () -> any) -> true` | Steps up to `frames` frames (default `60`) until `done()` returns truthy. Uses `task.wait` in Roblox or steps the active `sert.env` in headless Luau. |

## `expect`

`sert.expect(value, why?)` returns a table of matchers. Chain `.never` before any matcher to negate it.

| Matcher | Passes when |
| --- | --- |
| `toBe(x)` | `rawequal(value, x)` holds, or both values are `NaN`. Use `toEqual` for tables. |
| `toEqual(x)` | `sert.eq(value, x)` holds. |
| `toRawEqual(x)` | `sert.rawEq(value, x)` holds, ignoring metatables and `__eq`. |
| `toMatchObject(partial)` | Every key in `partial` matches recursively. Arrays match element by element. |
| `toHaveProperty(path, value?)` | `"a.b[2].c"` or `{ "a", "b", 2, "c" }` resolves on `value` and equals `value` when provided. |
| `toBeNil()`, `toBeTruthy()`, `toBeFalsy()` | `value` is `nil`, truthy (`not nil` and `not false`), or falsy (`nil` or `false`). |
| `toBeNaN()`, `toBeFinite()` | `value` is `NaN`, or a finite number (`not NaN` and `not ±math.huge`). |
| `toBeCloseTo(n, digits?)` | Number is within `10^-digits / 2` of `n` (default `2` digits, `±0.005`). |
| `toBeNear(x, eps?)` | `sert.near(value, x, eps)` holds (default `eps` is `1e-6`). |
| `toBeGreaterThan(n)`, `toBeGreaterThanOrEqual(n)`, `toBeLessThan(n)`, `toBeLessThanOrEqual(n)` | `value` and `n` are numbers satisfying `>`, `>=`, `<`, or `<=`. |
| `toBeA(typeName)` | `typeof`, `type`, or `Instance:IsA` matches `typeName`. |
| `toBeInstanceOf(class)` | Matches a class name (like `toBeA`) or a table on the metatable / `__index` chain. |
| `toContain(item)` | String contains the plain substring `item`, or table contains an element deep-equal to `item`. |
| `toMatch(pattern)` | `tostring(value)` matches the Luau pattern `pattern`. |
| `toHaveLength(n)` | String, table (`#value`), or `buffer` (`buffer.len(value)`) has length `n`. |
| `toThrow(matcher?)` | Callable throws an error. `matcher` works the same way as in `sert.fails`. |
| `toHaveBeenCalled()`, `toHaveBeenCalledTimes(n)` | Spy was called at least once, or exactly `n` times. |
| `toHaveBeenCalledWith(...)`, `toHaveBeenLastCalledWith(...)`, `toHaveBeenNthCalledWith(n, ...)` | Spy was called with deep-equal arguments on any call, the last call, or the 1-indexed `n`-th call. |
| `toHaveReturned()`, `toHaveReturnedWith(...)` | Spy call returned without throwing, and returned values deep-equal to `...` when given. |

Passing the wrong value type (such as `toHaveLength` on a number or spy matchers on a plain function) or calling a matcher with `:` instead of `.` always fails, even under `.never`.

### Custom matchers (`sert.extend`)

Call `sert.extend({ name = fn })` to add or override matchers on `sert.expect` (`never` is reserved). Each matcher takes `(actual, ...)` and returns a `MatcherResult`:

```luau
sert.extend({
	toBeEven = function(actual: any): sert.MatcherResult
		if type(actual) ~= "number" then
			return { pass = false, message = "expected a number", usage = true }
		end
		return {
			pass = actual % 2 == 0,
			message = function() return `expected {actual} to be even` end,
			negMessage = function() return `expected {actual} to be odd` end,
		}
	end,
})

-- Cast custom matcher calls to `any` under --!strict:
(sert.expect(4) :: any).toBeEven()
```

Set `usage = true` when the caller passed an invalid type so `.never` doesn't invert the error.

## Spies

```luau
local Store = {
	save = function(_k: string, _v: number)
		return true
	end,
}

sert.test("spies record calls", function()
	local save = sert.spy(Store, "save")
	save:mockReturnValueOnce(false)
	sert.eq(Store.save("a", 1), false)
	sert.eq(Store.save("b", 2), true)
	sert.expect(save).toHaveBeenCalledTimes(2)
	sert.expect(save).toHaveBeenLastCalledWith("b", 2)
end)
```

| Call | Description |
| --- | --- |
| `sert.fn(impl?) -> Spy` | Creates a callable spy that runs `impl` (or returns `nil` when omitted). |
| `sert.spy(target, key, impl?) -> Spy` | Replaces `target[key]` with a spy that delegates to `impl` or the original method. Restores `target[key]` automatically when the test finishes. |

Each `Spy` provides these fields and chainable methods:

| Member | Description |
| --- | --- |
| `spy.calls` | Array of argument packs `{ n = argCount, [1] = arg1, ... }`. |
| `spy.lastCall` | Last argument pack in `spy.calls`, or `nil` before the first call. |
| `spy.results` | Array of call outcomes `{ ok = boolean, n = count, ... }`. |
| `spy.callCount` | Number of calls since creation or the last `:reset()`. |
| `spy:mockImplementation(fn?) -> Spy` | Sets the default implementation (`nil` resets it to a no-op). |
| `spy:mockImplementationOnce(fn) -> Spy` | Queues a one-shot implementation for the next call (FIFO). |
| `spy:mockReturnValue(...) -> Spy` | Sets the default return values. |
| `spy:mockReturnValueOnce(...) -> Spy` | Queues one-shot return values for the next call (FIFO). |
| `spy:reset() -> Spy` | Clears `calls`, `lastCall`, `results`, `callCount`, and the one-shot queue. |
| `spy:restore()` | Restores `target[key]` on a `sert.spy` and resets the spy. |

## Registration

Every registration function takes options as its last argument: `(name, fn, opts?)`, or `(name, gens, fn, opts?)` for `check`.

```luau
sert.check("addition commutes", { sert.gen.int(-100, 100), sert.gen.int(-100, 100) }, function(a, b)
	sert.eq(a + b, b + a)
end)
```

| Call | Description |
| --- | --- |
| `sert.test(name, fn, opts?)` | Registers a test. `opts` supports `timeout` (max yield time in Roblox), `skip`, `focus`, and `file`. |
| `sert.rtest(name, fn, opts?)` | Registers a Roblox-only test. Skipped under the Luau CLI and Lute. |
| `sert.skip(name, fn?, opts?)` | Registers a skipped test that never runs. |
| `sert.todo(name)` | Registers a placeholder counted as `todo`. Passing a test body throws an error. |
| `sert.focus(name, fn, opts?)` | Focuses a test. When any test is focused, unfocused tests are skipped. |
| `sert.each(name, cases, fn(case, i), opts?)` | Registers one test per entry in `cases`, named `name · <case.name or i>` or `opts.format(name, case, i)`. |
| `sert.describe(prefix, fn, opts?)` | Groups tests under `prefix > name` (`opts.separator`, `opts.file`). Also supports `describe.skip` and `describe.focus`. |
| `sert.prop(name, fn(g), opts?)` | Registers a property test. See [Properties and generators](#properties-and-generators). |
| `sert.check(name, gens, fn(...), opts?)` | Registers a property test that draws arguments from one generator or a list of generators. |
| `sert.model(name, spec, opts?)` | Registers a stateful model test. See [Models](#models). |
| `sert.loaded(result) -> result` | Wraps `require` in custom entry scripts so Luau CLI load errors throw instead of returning an error string. |

`sert.prop`, `sert.check`, `sert.model`, `sert.laws.*`, and `sert.sim` helpers (`Sim.Spec` via `Sim.spec`, `Sim.checkSpec`, `Sim.vopr`, `Sim.prop`, `Sim.model`, `Sim.explore`) register a test when called at the top level of a spec, or run immediately when called inside a running test. If you wrap test registration in a helper function, pass `opts.file = debug.info(2, "s")` so test reports point to the caller's spec file. Under `--!strict`, annotate the `sert.prop` callback parameter as `function(g: sert.Gen)`.

## Hooks

| Call | Description |
| --- | --- |
| `sert.beforeAll(fn)`, `sert.afterAll(fn)` | Runs once before the first or after the last selected test in the current `describe` block or spec file. |
| `sert.beforeEach(fn)`, `sert.afterEach(fn)` | Runs before or after each selected test in the current `describe` block or spec file. |
| `sert.defer(fn)` | Queues `fn` to run when the current test finishes (LIFO, before `afterEach`), or after the file's `afterAll` when called in `beforeAll` or at file load time. |
| `sert.setup({ beforeAll?, afterAll?, beforeEach?, afterEach? })` | Configures global hooks that wrap every test in every file. Pass `{}` to clear them. |
| `sert.current() -> Current?` | Returns `{ name, file, last }` for the running test, or `nil` outside a test. |
| `sert.isolate(fn) -> (boolean, ...any)` | Runs `fn` against an isolated test registry and returns `pcall` results. |

Hooks run in this order around each test: global `beforeEach` → entry `beforeEach` → file `beforeEach` → `describe` `beforeEach` (outermost to innermost) → test → `sert.defer` (LIFO) → `describe` `afterEach` (innermost to outermost) → file `afterEach` → entry `afterEach` → global `afterEach`.

## Properties and generators

`sert.prop(name, fn, opts?)` runs `fn(g)` across `runs` generated cases. Every random draw is recorded on a tape so failures can shrink and replay deterministically. You can also call `sert.prop.run(name, fn, opts?, runOpts?) -> PropResult` to run a property without registering it.

### `PropOptions`

| Key | Default | Description |
| --- | --- | --- |
| `runs` | `200` | Number of sampled cases to run (`RunOptions.runs` overrides this). |
| `size` | `40` | Default max length (`g.size`) for generated lists, dicts, strings, and buffers. |
| `seed` | `0x5EED` | Base seed (`RunOptions.replay` runs a single case seed, and `RunOptions.seed` sets the fallback). |
| `regressions` | `nil` | List of case seeds from past failures to run before sampling new cases. |
| `exhaustive` | `nil` | Pass `{ size = N }` to enable bounded-exhaustive enumeration with `g.size = N`. |
| `shrinkBudget` | `{ tries = 500, seconds = 2 }` | Maximum attempts and time spent shrinking a failure. |
| `rtest`, `timeout`, `skip`, `focus`, `file` | | Standard test registration options (`rtest = true` skips the property outside Roblox). |

### The tape generator `g`

Each `g` instance exposes `g.size`, `g.seed`, and `g.exhaustive`:

| Method | Draws | Shrinks toward |
| --- | --- | --- |
| `g:int(lo, hi)` | Integer in `[lo, hi]`. | `0`, or the bound closest to `0`. |
| `g:float(lo?, hi?)` | Float in `[lo, hi)` (default `[0, 1)`). | `0.0`, or the bound closest to `0.0`. |
| `g:bool(p?)` | `true` with probability `p` (default `0.5`). | `false`. |
| `g:pick(list)` | One element from `list`. | `list[1]`. |
| `g:weighted({ { weight, value } })` | Value chosen by weight (zero-weight pairs are skipped). | First pair with a positive weight. |
| `g:optional(gen, absent?, present?)` | `gen(g)` or `nil`, weighted `absent` (`1`) to `present` (`1`). | `nil`. |
| `g:list(gen, min?, max?)` | Array of `min` (`0`) to `max` (`g.size`) values from `gen(g)`. | Shorter lists, then smaller elements. |
| `g:dict(keyGen, valueGen, min?, max?)` | Table of `min` to `max` key-value pairs. | Fewer entries, then smaller keys and values. |
| `g:tuple(gens)` or `g:tuple(a, b, ...)` | Array of values drawn from each generator in order. | Each element independently. |
| `g:record({ k = gen or constant })` | Table with a drawn value or constant for each key. | Each generated field independently. |
| `g:string(charset?, min?, max?)` | String of characters from `charset` (default `gen.CHARACTERS`). | Shorter strings, then the first character in `charset`. |
| `g:bytes(min?, max?)` | `buffer` of `min` (`0`) to `max` (`g.size`) bytes. | Shorter buffers, then `0x00` bytes. |
| `g:note(fmt, ...)` or `g:note(fn)` | Appends a line to the failure `trace:` output. | — |

### Combinators (`sert.gen`)

Each combinator in `sert.gen` returns a `Generator<T>` (`(g: sert.Gen) -> T`):

| Generator | Value (and shrink target) |
| --- | --- |
| `gen.int(lo, hi)`, `gen.bool()` | Same as `g:int` and `g:bool`. |
| `gen.constant(v)` | Always returns `v` without consuming tape draws. |
| `gen.float(lo, hi, opts?)` | Same as `g:float`. Pass `{ nan = true, inf = true, negZero = true }` to mix in IEEE-754 special values. |
| `gen.pick(list)` | Picks an element from `list` (shrinks toward `list[1]`). |
| `gen.oneOf(gens)` | Picks a generator from `gens` and draws from it (shrinks toward `gens[1]`). |
| `gen.frequency({ { weight, gen } })` | Picks a generator by weight (shrinks toward the first positive-weight entry). |
| `gen.optional(gen, absent?, present?)` | Same as `g:optional`. |
| `gen.list(gen, min?, max?)` | Array of `min` (`0`) to `max` (`g.size`) elements. |
| `gen.uniqueList(gen, min?, max?)` | Array of distinct elements (`NaN` is dropped). |
| `gen.set(gen, min?, max?)` | `{ [v] = true }` set with `min` to `max` keys (`NaN` is dropped). |
| `gen.dict(k, v, min?, max?)`, `gen.record(shape)`, `gen.tuple(...)` | Same as `g:dict`, `g:record`, and `g:tuple`. |
| `gen.string(charset?, min?, max?)`, `gen.bytes(min?, max?)` | Same as `g:string` and `g:bytes`. |
| `gen.utf8(min?, max?)` | Valid UTF-8 string of `min` to `max` codepoints across 1-byte to 4-byte scalar ranges. |
| `gen.shuffle(list)` | Shuffled copy of `list` (shrinks toward the original order). |
| `gen.subset(list, min?, max?)` | Ordered subsequence of `list`. |
| `gen.map(gen, fn)` | Transforms `gen(g)` with `fn(x)`. |
| `gen.bind(gen, fn)` | Draws `x = gen(g)`, then draws from `fn(x)`. |
| `gen.filter(gen, pred, maxTries?)` | Redraws until `pred(x)` returns true (default `maxTries` is `100`). |
| `gen.lazy(fn)` | Self-referential generator that calls `fn()` on first draw. |
| `gen.recursive(base, extend, maxDepth)` | Bounded-depth recursive generator that passes the smaller generator to `extend(subGen)`. |
| `gen.enum(EnumType)` | `EnumItem` from `EnumType` (shrinks toward the lowest `Value`). |
| `gen.any(depth?)` | Arbitrary non-`nil`, non-`NaN` Luau value up to nesting `depth`. |
| `gen.boundaryInt(lo?, hi?)` | Integer biased toward `0`, `±1`, `lo`, `hi`, `lo + 1`, `hi - 1`, `±2^31 - 1`, and `±2^53 - 1`. |
| `gen.boundaryFloat(lo?, hi?)` | IEEE-754 boundary float including `0.0`, `-0.0`, `NaN`, `±math.huge`, `±1e-9`, `lo`, and `hi`. |
| `gen.malformedString()` | Luau/Roblox adversarial string with NUL bytes, invalid UTF-8 sequences, control chars, format/pattern magic characters, numeric coercion traps, and RichText breakouts. |
| `gen.sparseTable(valGen?)` | Table with sparse integer indices, mixed array and string keys, and negative or float keys. |
| `gen.remotePayload(depth?)` | Untrusted client-to-server remote payload mixing primitives, `NaN`/`huge` vectors, sparse tables, and wrong-type records. |
| `gen.adversarial(depth?)` | Arbitrary untrusted Luau value including `remotePayload` values, functions, coroutines, userdata, and frozen tables. |
| `gen.vector2(x?, y?)`, `gen.vector3(x?, y?, z?)`, `gen.color3()`, `gen.udim(s?, o?)`, `gen.udim2(...)`, `gen.cframe(pos?)`, `gen.numberRange(lo?, hi?)`, `gen.rect(...)` | Roblox datatypes (native in Roblox, `@sert/doubles` in headless Luau). |
| `gen.sample(gen, seed?, size?)` | Draws a single value outside a property test (default `seed` `0x5EED`, `size` `40`). |

## Models

`sert.model(name, spec, opts?)` (or `sert.model(spec, opts?)`) generates random command sequences, runs each command against your system under test (`sut`) and a simpler model `state`, and shrinks failures by removing unneeded steps.

```luau
local spec: sert.ModelSpec = {
	init = function()
		return { n = 0 }
	end,
	commands = {
		add = {
			gen = function(g: sert.Gen)
				return g:int(1, 5)
			end,
			run = function(s, x)
				s.n += x
				return s.n
			end,
			post = function(state, x, res)
				sert.eq(res, state.n + x)
			end,
			next = function(state, x)
				state.n += x
			end,
		},
	},
}

sert.model("counter", spec, { length = 15 })
```

### `ModelSpec`

| Field | Type | Description |
| --- | --- | --- |
| `name` | `string?` | Test name when you call `sert.model(spec, opts?)` without a leading name string. |
| `init` | `() -> State` | Returns a fresh model `state` at the start of each case. |
| `setup` | `(() -> Sut)?` | Returns the real system (`sut`) for the case. Defaults to `state` when omitted. |
| `teardown` | `((sut: Sut, state: State) -> ())?` | Runs after each case, even if a step or invariant failed. |
| `invariant` | `((state: State, sut: Sut) -> ())?` | Checked right after `init`/`setup` and after every step. |
| `commands` | `{ ModelCommand } \| { [string]: ModelCommand }` | Array or name-keyed map of commands. |

### `ModelCommand`

| Field | Type | Description |
| --- | --- | --- |
| `name` | `string?` | Command name shown in failure traces. Taken from the table key when `commands` is a map. |
| `weight` | `number?` | Relative selection weight (default `1`). |
| `gen` | `((g: Gen, state: State) -> Arg)?` | Draws the command argument using the current `state`. |
| `pre` | `((state: State, arg: Arg) -> boolean)?` | Guard checked before running the step. Refused steps are skipped or redrawn. |
| `run` | `(sut: Sut, arg: Arg, state: State) -> Result` | Applies the command to `sut`. |
| `post` | `((state: State, arg: Arg, res: Result) -> ())?` | Asserts that `res` matches expectations against `state` before `next` updates it. |
| `next` | `((state: State, arg: Arg, res: Result) -> ())?` | Updates `state` for the completed command. |

`ModelOptions` accepts `length` (default `30`), `redraw` (retry refused steps), `maxRedraws`, and all `PropOptions`. Use `sert.model.replay(spec, steps) -> (state, sut)` to replay a `{ { "cmd", arg }, ... }` list from a failure trace in a unit test. `sert.model.property(spec, opts?) -> (g) -> ()` returns the underlying property function for `sert.prop.run`.

## Laws

`sert.laws` registers reusable contract test suites. Each function accepts `(name, spec, opts?)` or `(spec, opts?)`.

```luau
sert.laws.codec("json round-trip", {
	gen = sert.gen.record({
		id = sert.gen.int(1, 1000),
		tag = sert.gen.string(),
	}),
	encode = sert.format.json,
	decode = sert.format.jsonDecode,
})
```

| Law | Spec (`sert.<Name>Spec`) | Checks |
| --- | --- | --- |
| `codec` | `{ gen, encode, decode, eq? }` | `decode(encode(x))` equals `x`, `encode` is deterministic, and `encode(decode(encode(x)))` equals `encode(x)`. |
| `chunk` | `{ gen, chunk(x, budget), join, measure?, minSize?, maxSize?, eq? }` | Draws a budget in `[minSize, maxSize]` (`8..256`), checks that chunks are non-empty and fit within `measure`, and checks that `join(chunks)` equals `x`. |
| `order` | `{ gen, lt, eq? }` | Checks that `lt` is a strict weak order (irreflexive, asymmetric, transitive, and transitive incomparability matching `eq`). |
| `registry` | `{ entries, schema?, check?, aliases? }` | Checks that `entries` is non-empty, fields match `schema` (`"string"`, `"number?"`, or a predicate), `check` passes, and `aliases` resolves every entry's `aliases` list. |
| `remote` | `{ handler, checkState, post?, validGen?, invalidGen?, makePlayer?, argCount?, allowError? }` | Fuzzes a server remote handler with adversarial payloads (`gen.remotePayload()`), verifying it never throws unhandled errors, yields indefinitely, or corrupts mandatory `checkState`. |
| `algebra` | `{ gen, op, identity?, associative?, commutative?, idempotent?, inverse?, eq? }` | Checks algebraic laws (`associative`, `identity`, `commutative`, `idempotent`, `inverse`) across `gen`. |
| `differential` | `{ gen, sut, oracle, eq? }` | Verifies that `sut(x)` equals `oracle(x)` across inputs drawn from `gen`. |
| `ui` | `{ mount(env, parent, viewport), viewports?, tolerance?, noOverlap?, fitsViewport?, noTextOverflow?, check? }` | Mounts a UI tree in `sert.env` across Phone, Tablet, Desktop, and Console viewports and runs `Layout.audit`. |

## Running

`sert.run(opts?) -> Results` runs all registered tests, prints a report, and throws if any test failed (unless `raise = false`). Use `sert.parseCliArgs(...) -> RunOptions` in custom entry scripts to parse CLI flags.

### `RunOptions`

| Key | CLI flag | Meaning |
| --- | --- | --- |
| `filter` | positional, `--filter=TEXT` | Case-insensitive name substring, or `"@file=Button,Menu"`. |
| `filters`, `names`, `excludes`, `files` | | List of substrings, exact test names to include or exclude, or spec base names. |
| `shard` | | Cloud shard (`nil` uses `sert.shard()` when unfiltered, `true` always, `false` never, or a `Shard` table). |
| `list` | `--list` | Prints `[sert-list]` lines without running tests. |
| `raise`, `silent`, `markers` | `--silent`, `--markers` | `raise = false` returns instead of throwing. `silent` suppresses output. `markers` emits `[sert-test]` lines. |
| `timeout` | `--test-timeout=S` | Per-test yield timeout in seconds in Roblox (default `30`). |
| `requireTests`, `rtestOnly` | | Fails when `0` tests match, or skips plain `sert.test` registrations. |
| `failFast` | `-x`, `--fail-fast` | Stops after the first failure. |
| `seed`, `replay`, `seeds`, `runs` | `--seed=N\|random`, `--replay=N`, `--runs=N` | Base property seed (`0x5EED`), single case seed replay, per-test seed map, or run count override. |
| `exhaustive`, `budget` | `--exhaustive`, `--budget=S` | Runs only `exhaustive` properties within a per-property timeout in seconds (default `600`). |
| `command`, `mutant`, `mutants` | `--mutant=...`, `--mutants=...` | Replay command prefix and mutation testing flags. |

`Results` has the shape `{ passed, failed, skipped, todo, total, clock, failures, seeds, mutants? }`.

## Cloud shards and utilities

- **`sert.shard() -> Shard?`** returns `_G.__SERT_SHARD` (`{ name, index, count, runLimit, only?, except? }`) when running under `sert cloud`. `sert.shardSelects(name) -> boolean` checks whether a test name matches the active shard.
- **`sert.print(...)`, `sert.warn(...)`, `sert.quiet(fn, ...)`, `sert.capture(fn, ...) -> { string }`** route test output so specs can silence or capture logs.
- **`sert.isRoblox`** is `true` inside Roblox and `false` under the Luau CLI and Lute.
- **`sert.rng` (`@sert/rng`)** provides `rng.new(seed?) -> Rng` (`:next()`, `:int(lo, hi)`, `:float(lo?, hi?)`, `:chance(p)`, `:pick(list)`, `:shuffle(list)`, `:bytes(n, kind?)`, `:clone()`, `:fork(label?)`), `rng.xorshift32(s)`, and `rng.fnv1a32(text)`.

### `sert.format`

| Function | Description |
| --- | --- |
| `format.repr(v) -> string` | Formats Luau values, tables (cycle-safe, sorted keys), buffers, and Roblox datatypes or doubles as Luau syntax. |
| `format.diff(actual, expected, raw?) -> string?` | Returns the path and values of the first difference between `actual` and `expected`, or `nil` when equal. |
| `format.errorText(err) -> string` | Formats raw error values (strings, tables, instances) into diagnostic text. |
| `format.json(v, opts?) -> string` | Encodes `v` as JSON (`{ strict?: boolean, buffer?: (buffer) -> string, prefix?: string }`). `strict = true` enforces `HttpService` rules. |
| `format.jsonDecode(text, opts?) -> any` | Decodes a JSON string into Luau values. |
| `format.array(list) -> { any }` | Marks an empty table so `format.json` encodes it as `[]` instead of `{}`. |

### `sert.bytes` (`@sert/bytes`)

| Function | Description |
| --- | --- |
| `bytes.hex(b: buffer, offset?: number, count?: number) -> string` | Formats bytes from `b` as lowercase hex (`"deadbeef"`). |
| `bytes.fromHex(text: string) -> buffer` | Parses a hex string into a `buffer`, ignoring whitespace. |
| `bytes.equal(a: buffer, b: buffer) -> boolean` | Returns `true` when `a` and `b` have the same length and bytes. |
| `bytes.assertBytes(b: buffer, expected: buffer \| string, why?: string) -> buffer` | Asserts that `b` matches `expected` (a `buffer` or hex string), printing both in hex on failure, and returns `b`. |

## Types

`@sert` exports these types (`sert.Name`):

- **Runner and hooks:** `TestOptions`, `EachOptions<T>`, `DescribeOptions`, `RunOptions`, `Results`, `Setup`, `Current`, `Shard`.
- **Matchers and spies:** `Matchers`, `Matcher`, `MatcherResult`, `Spy`.
- **Properties, models, and laws:** `Gen`, `Generator<T>`, `PropOptions`, `PropResult`, `FloatOptions`, `ModelSpec`, `ModelCommand`, `ModelOptions`, `CodecSpec<T, E>`, `ChunkSpec<T, C>`, `OrderSpec<T>`, `RegistrySpec`.
- **Environment and utilities:** `Env`, `EnvOptions`, `EnvHost`, `EnvInput`, `EnvKick`, `Rng`, `JsonOptions`.
- **Simulation (`@sert/sim`):** `SimWorld`, `SimServer`, `SimClient`, `SimScheduler`, `SimModelSpec`, `SimModelCommand`, `SimSpec`, `SimSpecDef`, `SimActionSpec`, `SimTraceEntry`.
- **Roblox helpers (`sert.roblox`):** `RobloxConfig`, `RobloxSide`, `RobloxVerdict`, `RobloxContext`, `RobloxRequest`, `RobloxRunner`, `RobloxSettleOptions`, `RobloxFlickerOptions`, `RobloxFlickerResult`.
