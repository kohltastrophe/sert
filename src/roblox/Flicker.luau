--!strict
-- Frame-by-frame UI geometry stability recorder (`sert.roblox.Flicker`). Detects single-frame mount jumps,
-- visibility blinks, and post-mount jitter across both Roblox Studio and headless `sert.env`.

local Layout = require("./Layout")
local registry = require("../core/registry")
local util = require("../core/util")

local geometry = Layout.geometry

local Flicker = {}

export type Sample = {
	frame: number,
	visible: boolean,
	rect: Layout.Rect?,
}

export type Options = {
	maxFrames: number?,
	stableFrames: number?,
	tolerance: number?,
	anchor: boolean?,
	positionOnly: boolean?,
	fromSettledSize: boolean?,
	label: string?,
	step: (() -> ())?,
	runService: any?,
}

export type Result = {
	label: string?,
	frames: number,
	tolerance: number,
	positionOnly: boolean?,
	fromSettledSize: boolean?,
	samples: { Sample },
	ok: boolean?,
	problem: ("never-visible" | "never-settled" | "blinked" | "jumped" | "jittered")?,
	first: Sample?,
	settled: Sample?,
}

local function sameSize(a: Layout.Rect, b: Layout.Rect, eps: number): boolean
	return math.abs(a.w - b.w) <= eps and math.abs(a.h - b.h) <= eps
end

local function sameRect(a: Layout.Rect, b: Layout.Rect, eps: number, positionOnly: boolean?): boolean
	local posMatch = math.abs(a.x - b.x) <= eps and math.abs(a.y - b.y) <= eps
	return if positionOnly then posMatch else posMatch and sameSize(a, b, eps)
end

local function detectBlink(samples: { Sample }, startFrame: number): Sample?
	local state = 0
	for _, s in samples do
		if s.frame >= startFrame then
			if state == 0 and s.visible then
				state = 1
			elseif state == 1 and not s.visible then
				state = 2
			elseif state == 2 and s.visible then
				return s
			end
		end
	end
	return nil
end

--- Evaluates `result.samples` and returns a new `Result` table with `.ok`, `.problem`, `.first`, and `.settled` populated.
--- Never mutates `result` in place.
function Flicker.judge(result: Result, options: Options?): Result
	local opts: Options = options or {}
	local eps = opts.tolerance or result.tolerance or 1
	local posOnly = if opts.positionOnly ~= nil then opts.positionOnly else (result.positionOnly == true)
	local fromSize = if opts.fromSettledSize ~= nil then opts.fromSettledSize else (result.fromSettledSize == true)

	local out: Result = table.clone(result)
	out.tolerance = eps
	out.positionOnly = posOnly
	out.fromSettledSize = fromSize

	local shown: { Sample } = {}
	for _, s in result.samples do
		if s.visible and s.rect ~= nil then table.insert(shown, s) end
	end

	if #shown == 0 then
		out.ok = false
		out.problem = "never-visible"
		out.first = nil
		out.settled = nil
		return out
	end

	if fromSize then
		local finalRect = shown[#shown].rect :: Layout.Rect
		local settleStart = #shown
		while settleStart > 1 and sameSize(shown[settleStart - 1].rect :: Layout.Rect, finalRect, eps) do
			settleStart -= 1
		end
		shown = table.move(shown, settleStart, #shown, 1, {})
	end

	local first = shown[1]
	local settled = shown[#shown]
	out.first = first
	out.settled = settled

	local blinkSample = detectBlink(result.samples, first.frame)
	if blinkSample ~= nil then
		out.ok = false
		out.problem = "blinked"
		return out
	end

	local steady = true
	for i = 2, #shown do
		if not sameRect(shown[i].rect :: Layout.Rect, settled.rect :: Layout.Rect, eps, posOnly) then
			steady = false
			break
		end
	end

	local matchedFirst = sameRect(first.rect :: Layout.Rect, settled.rect :: Layout.Rect, eps, posOnly)
	if matchedFirst and steady then
		out.ok = true
		out.problem = nil
	elseif not matchedFirst then
		out.ok = false
		out.problem = "jumped"
	else
		out.ok = false
		out.problem = "jittered"
	end
	return out
end

local function stepOnce(opts: Options)
	if opts.step ~= nil then
		opts.step()
		return
	end
	if opts.runService ~= nil then
		Layout.stepFrame(opts.runService)
		return
	end
	local activeEnv: any = registry.activeEnv()
	if activeEnv ~= nil and type(activeEnv.step) == "function" then
		(activeEnv.step :: (any) -> ())(activeEnv)
		return
	end
	Layout.stepFrame(nil)
end

--- Mounts via `mount()` (or observes an already-mounted `GuiObject` / `{ target, cleanup }`) across frames until its
--- screen rect stabilizes, then returns a judged `Result` without mutating caller options.
function Flicker.record(target: (() -> any) | GuiObject | { [string]: any }, options: Options?): Result
	local opts: Options = options or {}
	local maxFrames = opts.maxFrames or 60
	local needStable = opts.stableFrames or 4
	local eps = opts.tolerance or 1
	local anchor = opts.anchor == true
	local posOnly = opts.positionOnly == true
	local fromSize = opts.fromSettledSize == true

	local mounted: any = if type(target) == "function" then (target :: () -> any)() else target
	local maybeSubject: GuiObject?
	local cleanup: (() -> ())? = nil
	if type(mounted) == "table" and util.typeof(mounted) ~= "Instance" and mounted.target ~= nil then
		maybeSubject = mounted.target :: GuiObject?
		cleanup = mounted.cleanup
	else
		maybeSubject = mounted :: GuiObject?
	end

	if maybeSubject == nil or util.typeof(maybeSubject) ~= "Instance" or not maybeSubject:IsA("GuiObject") then
		if cleanup ~= nil then pcall(cleanup :: () -> ...any) end
		error(
			"Flicker.record: target must be or return a GuiObject (or { target = GuiObject, cleanup? })",
			util.outside()
		)
	end
	local subject: GuiObject = maybeSubject

	local samples: { Sample } = {}
	local function capture(frameIndex: number): Sample
		local vis = geometry.visible(subject)
		local sample: Sample = {
			frame = frameIndex,
			visible = vis,
			rect = if vis then geometry.rect(subject, anchor) else nil,
		}
		table.insert(samples, sample)
		return sample
	end

	local settled = false
	local okRun, runErr = pcall(function()
		local prev = capture(0)
		local still = 0
		for f = 1, maxFrames do
			stepOnce(opts)
			local cur = capture(f)
			if cur.visible and prev.visible and cur.rect ~= nil and prev.rect ~= nil then
				local stableRect = sameRect(cur.rect, prev.rect, eps, posOnly)
				local stableSize = if fromSize then sameSize(cur.rect, prev.rect, eps) else true
				if stableRect and stableSize then
					still += 1
					if still >= needStable then
						settled = true
						break
					end
				else
					still = 0
				end
			else
				still = 0
			end
			prev = cur
		end
	end)

	if cleanup ~= nil then pcall(cleanup) end
	if not okRun then error(runErr, 0) end

	local raw: Result = {
		label = opts.label or subject.Name,
		frames = #samples - 1,
		tolerance = eps,
		positionOnly = posOnly,
		fromSettledSize = fromSize,
		samples = samples,
	}

	if not settled then
		local anyVisible = false
		for _, s in samples do
			if s.visible then
				anyVisible = true
				break
			end
		end
		local failed = table.clone(raw)
		failed.ok = false
		failed.problem = if anyVisible then "never-settled" else "never-visible"
		return failed
	end

	return Flicker.judge(raw, opts)
end

local function fmtRect(r: Layout.Rect?): string
	if r == nil then return "(hidden)" end
	return string.format("(%.1f, %.1f  %.1fx%.1f)", r.x, r.y, r.w, r.h)
end

--- Formats a human-readable diagnostic timeline for `result` without mutating `result`.
function Flicker.describe(result: Result, overrideLabel: string?): string
	local judged = if result.ok == nil then Flicker.judge(result) else result
	local who = overrideLabel or judged.label or "element"
	if judged.ok then return `{who}: steady at {fmtRect(if judged.settled then judged.settled.rect else nil)}` end

	local header: string
	if judged.problem == "never-visible" then
		header = `{who} never became visible across {judged.frames} frames`
	elseif judged.problem == "never-settled" then
		header = `{who} kept moving past {judged.frames} frames`
	elseif judged.problem == "blinked" then
		header = `{who} blinked (visible -> hidden -> visible)`
	elseif judged.problem == "jumped" then
		local f = judged.first :: Sample
		local s = judged.settled :: Sample
		header =
			`{who} jumped after first paint: frame {f.frame} {fmtRect(f.rect)} -> frame {s.frame} {fmtRect(s.rect)}`
	else
		header = `{who} jittered before settling at {fmtRect(if judged.settled then judged.settled.rect else nil)}`
	end

	local lines = { header }
	local prev: Sample? = nil
	for _, s in judged.samples do
		local changed = prev == nil
			or s.visible ~= prev.visible
			or (s.rect ~= nil and prev.rect ~= nil and not sameRect(s.rect, prev.rect, 0.05, judged.positionOnly))
		if changed then table.insert(lines, string.format("  f%-3d %s", s.frame, fmtRect(s.rect))) end
		prev = s
	end
	return table.concat(lines, "\n")
end

--- Asserts that `result` has zero flicker, raising a caller-framed diagnostic without mutating `result`.
function Flicker.expect(result: Result, label: string?): Result
	local judged: Result = if result.ok == nil then Flicker.judge(result) else table.clone(result :: any) :: Result
	if label ~= nil then judged.label = label end
	if not judged.ok then error(Flicker.describe(judged, label), util.outside()) end
	return judged
end

--- Convenience helper recording `target` and asserting zero flicker in one call.
function Flicker.steady(target: (() -> any) | GuiObject | { [string]: any }, options: Options?): Result
	return Flicker.expect(Flicker.record(target, options))
end

return Flicker
