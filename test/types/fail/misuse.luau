--!strict
-- Negative type probe (`sert lint --only types`): every line marked `expect-error` must fail under both `new` and `old` Luau solvers.
local sert = require("../../../src")

local gen = sert.gen
local spec: sert.ModelSpec<{ n: number }, { n: number }> = {
	init = function() return { n = 0 } end,
	commands = {
		inc = {
			run = function(sut: { n: number }) return sut.n end,
		},
	},
}
local codec: sert.CodecSpec<number, string> = {
	gen = gen.int(1, 9),
	encode = function(n: number): string return tostring(n) end,
	decode = function(s: string): number return tonumber(s) :: number end,
}

-- Invalid option field types
sert.describe("block", function() end, { separator = 1 }) -- expect-error
sert.test("test", function() end, { file = 1 }) -- expect-error
sert.prop("prop", function(_g: sert.GenContext) end, { runs = "ten" }) -- expect-error
sert.sim.new({ mode = 123 }) -- expect-error
sert.env.new({ strict = "yes" }) -- expect-error

-- Wrong argument types on procedural assertions, spies, and bytes
sert.matches(123, "^a") -- expect-error
sert.matches("abc", 123) -- expect-error
sert.calledTimes(sert.spy(), "two") -- expect-error
sert.bytes.fromHex(123) -- expect-error
sert.bytes.hex(123) -- expect-error

-- Options passed before callback or spec
sert.test("test", { timeout = 1 }, function() end) -- expect-error
sert.describe("describe", { separator = "/" }, function() end) -- expect-error
sert.prop("prop", { runs = 1 }, function(_g: sert.GenContext) end) -- expect-error
sert.prop.run("prop", { runs = 1 }, function(_g: sert.GenContext) end) -- expect-error
sert.model("model", { runs = 1 }, spec) -- expect-error
sert.laws.codec("codec", { runs = 1 }, codec) -- expect-error

-- Generator combinators live on `sert.gen`, not on `GenContext`
sert.prop("combinators not on g", function(g: sert.GenContext)
	g:oneOf({ gen.int(1, 2) }) -- expect-error
	g:frequency({ { 1, gen.int(1, 2) } }) -- expect-error
	g:uniqueList(gen.int(1, 2)) -- expect-error
	g:map(gen.int(1, 2), tostring) -- expect-error
	g:constant(1) -- expect-error
	g:sample(gen.int(1, 2)) -- expect-error
end)

-- Removed 0.1.0-draft APIs must fail static typechecking
sert.expect(1) -- expect-error
sert.extend({}) -- expect-error
sert.check("c", gen.int(1, 2), function() end) -- expect-error
sert.doubles.Signal.new() -- expect-error
sert.fn() -- expect-error
sert.todo("later") -- expect-error
sert.neq(1, 2) -- expect-error
sert.rawEq(1, 1) -- expect-error
sert.fails(function() end) -- expect-error
sert.rtest("r", function() end) -- expect-error
sert.ptest("p", function() end) -- expect-error
sert.ctest("c", function() end) -- expect-error
sert.bytes.assertBytes(buffer.create(0), "") -- expect-error
sert.env.current() -- expect-error
sert.env.configure({}) -- expect-error
sert.env.install({}) -- expect-error
sert.laws.chunk("ch", {}) -- expect-error
sert.laws.registry("reg", {}) -- expect-error
sert.sim.Runner.run({}) -- expect-error
sert.sim.configure({}) -- expect-error
gen.element({ 1 }) -- expect-error
gen.listOf(gen.int(1, 2)) -- expect-error
gen.buffer() -- expect-error
