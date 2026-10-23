--!strict
-- Type probe: each line marked expect-error must fail to type-check under both solvers.
local Sim = require("../../../src/sim")
local sert = require("../../../src")

local gen = sert.gen
local spec: sert.ModelSpec = {
	init = function() return 0 end,
	commands = {},
}
local codec: sert.CodecSpec<number, string> = {
	gen = gen.int(1, 9),
	encode = function(n: number): string return tostring(n) end,
	decode = function(s: string): number return tonumber(s) :: number end,
}

-- invalid option types
sert.describe("block", function() end, { separator = 1 }) -- expect-error
sert.test("test", function() end, { file = 1 }) -- expect-error
Sim.World.new({ mode = 1 }) -- expect-error

-- g draws values; combinators live on sert.gen only
sert.prop("gen names on g", function(g: sert.Gen)
	g:oneOf({ gen.int(1, 2) }) -- expect-error
	g:frequency({ { 1, gen.int(1, 2) } }) -- expect-error
	g:uniqueList(gen.int(1, 2)) -- expect-error
	g:map(gen.int(1, 2), tostring) -- expect-error
	g:filter(gen.int(1, 2), function() -- expect-error
		return true
	end)
	g:constant(1) -- expect-error
	g:sample(gen.int(1, 2)) -- expect-error
end)

-- renamed generators and assertions
gen.element({ 1 }) -- expect-error
gen.listOf(gen.int(1, 2)) -- expect-error
gen.uniqueListOf(gen.int(1, 2)) -- expect-error
gen.stringOf("ab") -- expect-error
gen.buffer() -- expect-error
local _same: { same: any } = sert -- expect-error
sert.expect(1).toStrictEqual(1) -- expect-error
sert.expect(1).never.toStrictEqual(2) -- expect-error
sert.expect(2).toBeEven() -- expect-error

-- internals and removed doubles API
sert.env.NONE() -- expect-error
sert.env._sharedG() -- expect-error
sert.doubles.Signal.new():listenerCount() -- expect-error
Sim.World.newSignal() -- expect-error

-- options before the function (or spec)
sert.test("test", { timeout = 1 }, function() end) -- expect-error
sert.rtest("rtest", { timeout = 1 }, function() end) -- expect-error
sert.focus("focus", { timeout = 1 }, function() end) -- expect-error
sert.skip("skip", { timeout = 1 }, function() end) -- expect-error
sert.each("each", { 1 }, { timeout = 1 }, function(_n: number) end) -- expect-error
sert.describe("describe", { separator = "/" }, function() end) -- expect-error
sert.describe.skip("describe", { separator = "/" }, function() end) -- expect-error
sert.prop("prop", { runs = 1 }, function(_g: sert.Gen) end) -- expect-error
sert.prop.run("prop", { runs = 1 }, function(_g: sert.Gen) end) -- expect-error
sert.check("check", function(_n: number) end, gen.int(1, 9)) -- expect-error
sert.model("model", { runs = 1 }, spec) -- expect-error
sert.laws.codec("codec", { runs = 1 }, codec) -- expect-error
Sim.prop("sim", { runs = 1 }, function(_world: Sim.World) end) -- expect-error
Sim.explore("sim", { maxRuns = 1 }, function(_world: Sim.World) end) -- expect-error
