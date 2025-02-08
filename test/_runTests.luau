local results = require("../src").run({
	async = require "./async.test",
	focus = require "./focus.test",
	globals = require "./globals.test",
	hooks = require "./hooks.test",
	invalid = require "./invalid.test",
	promise = require "./promise.test",
	silent = require "./silent.test",
	skip = require "./skip.test",
	statusCount = require "./statusCount.test",
})

if results.FAILED > 0 then
	error("Tests failed", 0)
end

return results
