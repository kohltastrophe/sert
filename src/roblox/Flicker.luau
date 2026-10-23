--!strict
-- Frame-by-frame GUI rect stability recorder (`sert.roblox.Flicker`). Samples at `RunService.PreAnimation` (right after
-- the engine lays out `PreRender` changes) and fails if any visible frame deviates from the settled rect beyond
-- declared entrance motion.

local Datatypes = require("../doubles/datatypes")
local Layout = require("./Layout")
local geometry = Layout.geometry

local RunService: RunService? = if (game :: any) ~= nil then game:GetService("RunService") else nil
local Vector2Lib: typeof(Vector2) = if (Vector2 :: any) ~= nil then Vector2 else Datatypes.Vector2 :: any

local Flicker = {}
local advanceFrame: (() -> ())? = nil

--- Overrides the frame stepper used by `recorder.result()` (`nil` restores the default `PreAnimation` wait).
function Flicker.drive(frame: (() -> ())?) advanceFrame = frame end

export type Sample = { frame: number, shown: boolean, x: number, y: number, width: number, height: number }
export type Result = {
	label: string?,
	samples: { Sample },
	first: Sample?,
	settled: Sample?,
	steady: boolean?,
	ok: boolean,
	problem: string?,
	motion: number,
}
export type Options = {
	motion: number?,
	tolerance: number?,
	stable: number?,
	timeout: number?,
	shown: ((GuiObject) -> boolean)?,
	positionOnly: boolean?,
	maxStep: number?,
	fromSettledSize: boolean?,
	busy: (() -> boolean)?,
	label: string?,
	runService: RunService?,
}
export type Recorder = { result: () -> Result, stop: () -> (), samples: { Sample } }

--- Returns `true` when `object` is inside an enabled `LayerCollector` in the DataModel and all its `GuiObject` ancestors are visible.
function Flicker.visible(object: GuiObject): boolean return geometry.visible(object, { requireDataModel = true }) end

local function rectText(sample: Sample): string
	return string.format(
		"%s(%.1f, %.1f %.1f×%.1f)",
		if sample.shown then "" else "hidden ",
		sample.x,
		sample.y,
		sample.width,
		sample.height
	)
end

--- Judges `result.samples` against `options`, setting `result.ok` and `result.problem`, and returns `result`.
function Flicker.judge(result: Result, options: Options?): Result
	local opts: Options = options or {}
	local tolerance = opts.tolerance or 1
	local motion, maxStep = opts.motion or result.motion or 0, opts.maxStep
	local shown: { Sample }, blinkFrame: number? = {}, nil
	for _, sample in result.samples do
		if sample.shown then
			table.insert(shown, sample)
		elseif #shown > 0 and blinkFrame == nil then
			blinkFrame = sample.frame
		end
	end
	if opts.fromSettledSize and #shown > 0 then
		local last, from = shown[#shown], #shown
		for index, sample in shown do
			if
				math.abs(sample.width - last.width) <= tolerance
				and math.abs(sample.height - last.height) <= tolerance
			then
				from = index
				break
			end
		end
		shown = table.move(shown, from, #shown, 1, {} :: { Sample })
	end
	result.first, result.settled = shown[1], shown[#shown]
	result.ok, result.problem = true, nil
	if #shown == 0 then
		result.ok, result.problem = false, "never visible"
		return result
	elseif blinkFrame ~= nil then
		result.ok, result.problem = false, string.format("blinks hidden at frame %d", blinkFrame)
		return result
	end
	local settled = shown[#shown]
	if result.steady == false then
		result.ok, result.problem = false, "never held still: " .. rectText(settled) .. " last"
		return result
	end
	local direction: Vector2?, previous: number? = nil, nil
	for index, sample in shown do
		local offset = Vector2Lib.new(sample.x - settled.x, sample.y - settled.y)
		local distance = offset.Magnitude
		local function fail(why: string): Result
			result.ok = false
			result.problem =
				`visible frame {index} (frame {sample.frame}) {why}: {rectText(sample)}, settles at {rectText(settled)}`
			return result
		end
		if
			not opts.positionOnly
			and (
				math.abs(sample.width - settled.width) > tolerance
				or math.abs(sample.height - settled.height) > tolerance
			)
		then
			return fail("has another size")
		end
		if distance > tolerance then
			if index == 1 and maxStep == nil and distance > motion + tolerance then
				return fail(string.format("is %.0f px from its place (declared motion %d px)", distance, motion))
			elseif direction == nil then
				direction = offset.Unit
			elseif distance > 2 * tolerance and offset.Unit:Dot(direction) < 0.9 then
				return fail("moves off its motion's line")
			end
			if index > 1 and (previous == nil or previous <= tolerance) then
				return fail("jumps after it was in place")
			end
		end
		local before = shown[index - 1]
		if maxStep ~= nil and before ~= nil then
			local step = Vector2Lib.new(sample.x - before.x, sample.y - before.y).Magnitude
			if step > maxStep + tolerance then
				return fail(string.format("jumps %.0f px in one frame (at most %d px)", step, maxStep))
			end
		end
		if previous ~= nil and distance > previous + tolerance then
			return fail(string.format("moves away (%.0f px after %.0f px)", distance, previous))
		end
		previous = distance
	end
	return result
end

--- Starts recording `target()` on every `PreAnimation` frame until settled (or `timeout` elapses).
function Flicker.record(target: () -> GuiObject?, options: Options?): Recorder
	local opts: Options = options or {}
	local runService = opts.runService or RunService
	if runService == nil then error("Flicker.record: no RunService outside Roblox; pass options.runService", 2) end
	local tolerance, stable = opts.tolerance or 1, opts.stable or 3
	local waitFrame = geometry.stepper("PreAnimation", runService)
	local frameCap = math.ceil((opts.timeout or 2) * 60)
	local samples: { Sample }, connections: { RBXScriptConnection } = {}, {}
	local frame, still, finished, done, seen = 0, 0, false, false, false

	local function stop()
		if not done then
			done = true
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end

	local preRenderConn = runService.PreRender:Connect(function()
		if finished or done then return end
		frame += 1
	end)
	table.insert(connections, preRenderConn)
	local preAnimConn = runService.PreAnimation:Connect(function()
		if finished or done or frame == 0 then return end
		local ok, found: any = pcall(target)
		local object: GuiObject? = if ok
				and Datatypes.typeof(found) == "Instance"
				and found:IsA("GuiObject")
			then found
			else nil
		local sample: Sample
		if object == nil or object.Parent == nil then
			sample = { frame = frame, shown = false, x = 0, y = 0, width = 0, height = 0 }
		else
			local gui = object :: GuiObject
			local rect = geometry.rect(gui, true)
			sample = {
				frame = frame,
				shown = Flicker.visible(gui) and (opts.shown == nil or (opts.shown :: (GuiObject) -> boolean)(gui)),
				x = rect.x,
				y = rect.y,
				width = rect.width,
				height = rect.height,
			}
		end
		table.insert(samples, sample)
		if sample.shown then
			local last = samples[#samples - 1]
			still = if seen
					and last
					and last.shown
					and geometry.sameRect(sample, last, tolerance, opts.positionOnly)
				then still + 1
				else 0
			seen = true
		elseif seen then
			still = 0
		end
		if (seen and still >= stable and not (opts.busy ~= nil and opts.busy())) or frame > frameCap then
			finished = true
			stop()
		end
	end)
	table.insert(connections, preAnimConn)

	local function result(): Result
		while not finished and not done do
			local advance = advanceFrame
			if advance ~= nil then
				advance()
			else
				waitFrame()
			end
		end
		stop()
		return Flicker.judge({
			label = opts.label,
			samples = samples,
			steady = seen and still >= stable,
			ok = true,
			motion = opts.motion or 0,
		}, {
			motion = opts.motion,
			tolerance = tolerance,
			positionOnly = opts.positionOnly,
			maxStep = opts.maxStep,
			fromSettledSize = opts.fromSettledSize,
		})
	end
	return { result = result, stop = stop, samples = samples }
end

--- Formats `result` as a frame-by-frame diagnostic string.
function Flicker.describe(result: Result): string
	local lines, hidden, started = {}, 0, false
	for _, sample in result.samples do
		if not started and not sample.shown then
			hidden += 1
		else
			started = true
			table.insert(lines, string.format("  f%d %s", sample.frame, rectText(sample)))
		end
		if #lines >= 24 then
			table.insert(lines, "  …")
			break
		end
	end
	return string.format(
		"%s: %s (%d hidden frames first)\n%s",
		result.label or "interface",
		if result.ok then "steady" else result.problem or "flickers",
		hidden,
		table.concat(lines, "\n")
	)
end

--- Raises with `Flicker.describe(result)` when `not result.ok`.
function Flicker.expect(result: Result, label: string?)
	if label then result.label = label end
	if not result.ok then error("flicker · " .. Flicker.describe(result), 2) end
end

--- Records `target` across `open()` until settled and returns the judged `Result`.
function Flicker.around(target: () -> GuiObject?, open: () -> (), options: Options?): Result
	local recorder = Flicker.record(target, options)
	local ok, err = pcall(open :: any)
	if not ok then
		recorder.stop()
		error(err, 0)
	end
	return recorder.result()
end

return table.freeze(Flicker)
