--!strict
-- The runner's request (roblox/session, internal): the keys it forwards to sert.run, its default replay command, and
-- the keys it reports as unknown.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local sert = require(ReplicatedStorage.sert) :: any
local Runner = require(ReplicatedStorage.sert.roblox.Runner)
local session = Runner._session

sert.test("request forwards replay, exhaustive, budget and command", function()
	local request = session.request({
		mode = "play",
		replay = 3714881375,
		exhaustive = true,
		budget = 30,
		command = "python3 tools/sert.py studio --mode play",
	})
	sert.expect(request.replay).toBe(3714881375)
	sert.eq(request.exhaustive, true)
	sert.eq(request.budget, 30)
	sert.eq(request.command, "python3 tools/sert.py studio --mode play")
	sert.eq(#request.unknown, 0)
end)

sert.test("request ignores malformed property keys", function()
	local request = session.request({ mode = "run", replay = 1.5, exhaustive = "yes", budget = -1, command = "" })
	sert.eq(request.replay, nil)
	sert.eq(request.exhaustive, false)
	sert.eq(request.budget, nil)
	sert.eq(request.command, "python3 tools/sert.py studio --mode run")
end)

sert.test("request lists the keys it does not read", function()
	local request = session.request({ mode = "edit", seed = 1, target = "x", capture = true })
	sert.eq(request.unknown, { "capture", "target" })
	sert.eq(request.args.target, "x")
end)

sert.test("every key the runner reads is known", function()
	local given: { [string]: any } = {}
	for _, key in Runner.KEYS do
		given[key] = true
	end
	sert.eq(#session.request(given).unknown, 0)
end)

return {}
