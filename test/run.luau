--!nonstrict
--[[
	sert's own suite, headless: `luau test/run.luau [-a filter --flags]` or `lute run test/run.luau [filter --flags]`.

		filter            plain substring of test names (one)
		--seed=N|random   base seed of every property
		--replay=N        run one case of the matching properties by the per-run seed a failure printed
		--runs=N          cases per property, over each property's own count
		--exhaustive      run only the bounded-exhaustive properties
		--budget=N        seconds an exhaustive property may take (default 600)
		--test-timeout=N  Roblox: seconds a yielding test may take (default 30)
		--markers         print a `[sert-test] {json}` line per test
		--list            print the selected tests and run nothing
]]

local sert = require("../src")

sert.loaded(require("./Sert.spec"))
sert.loaded(require("./Assert.spec"))
sert.loaded(require("./Runner.spec"))
sert.loaded(require("./Gen.spec"))
sert.loaded(require("./Model.spec"))
sert.loaded(require("./Format.spec"))
sert.loaded(require("./Laws.spec"))
sert.loaded(require("./Env.spec"))
sert.loaded(require("./Sim.spec"))
sert.loaded(require("./Doubles.spec"))
sert.loaded(require("./Roblox.spec"))
sert.loaded(require("./layout_headless.spec"))

local options: any = sert.parseCliArgs(...)
options.command = "luau test/run.luau -a"

return sert.run(options)
