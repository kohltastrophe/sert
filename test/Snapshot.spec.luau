--!strict
local format = require("../src/core/format")
local registry = require("../src/core/registry")
local sert = require("../src")

local function withIsolatedState(fn: () -> ())
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, err = pcall(function() registry.withState(sub, fn) end)
	registry.isolateDepth -= 1
	if not ok then error(err, 0) end
end

sert.describe("sert.inlineSnapshot", function()
	sert.test("matches strings, CRLF normalization, and deterministic formatted tables", function()
		local value = sert.inlineSnapshot("hello\r\nworld", "hello\nworld")
		sert.eq(value, "hello\r\nworld")

		local structured = { b = 2, a = 1 }
		local ret = sert.inlineSnapshot(structured, "{\n  a = 1,\n  b = 2,\n}")
		sert.eq(ret, structured, "returns same table reference")

		local tracker = registry.activeTestAssertions()
		sert.ok(tracker ~= nil)
		sert.eq((tracker :: registry.AssertionTracker).kinds["snapshot"], 2)
	end)

	sert.test("fails clearly when missing or mismatched and rejects invalid expected argument", function()
		local missingErr = sert.throws(function() sert.inlineSnapshot({ x = 1 }, nil, "first record") end)
		sert.contains(missingErr, "first record")
		sert.contains(
			missingErr,
			"missing inline snapshot; run with -u / --update-snapshots to record:\n{\n  x = 1,\n}"
		)

		local diffErr = sert.throws(function() sert.inlineSnapshot("a\nb\nc", "a\nx\nc", "ui dump") end)
		sert.contains(diffErr, "ui dump: inline snapshot mismatch:")
		sert.contains(diffErr, "- x")
		sert.contains(diffErr, "+ b")
		sert.contains(diffErr, "-u / --update-snapshots")

		sert.throws(function() sert.inlineSnapshot("ok", 123 :: any) end, "expected snapshot string or nil")
	end)

	sert.test("emits [sert-x:snapshot] markers under -u bypassing quiet and tracks per-line ordinals", function()
		local captured = sert.capture(function()
			withIsolatedState(function()
				sert.test("inline updates", function()
					local quietOut = sert.quiet(function()
						for i = 1, 2 do
							sert.inlineSnapshot({ idx = i }, nil)
						end
						sert.inlineSnapshot("same", "same")
						return "ok"
					end)
					sert.eq(quietOut, "ok")
				end)
				local res = sert.run({ updateSnapshots = true, quiet = true, raise = false })
				sert.eq(res.passed, 1)
				sert.eq(res.failed, 0)
			end)
		end)

		local events: { { [string]: any } } = {}
		for _, line in captured do
			local payload = string.match(line, "^%[sert%-x:snapshot%] (.+)$")
			if payload ~= nil then table.insert(events, format.jsonDecode(payload)) end
		end
		sert.eq(#events, 2)
		sert.eq(events[1].kind, "inline")
		sert.contains(events[1].file, "Snapshot.spec")
		sert.eq(events[1].ordinal, 1)
		sert.eq(events[1].actual, "{\n  idx = 1,\n}")
		sert.eq(events[2].ordinal, 2)
		sert.eq(events[2].actual, "{\n  idx = 2,\n}")
		sert.eq(events[1].line, events[2].line)
	end)

	sert.test("rejects snapshot updates when CI mode is active", function()
		withIsolatedState(function()
			sert.test("ci guard", function() sert.inlineSnapshot("x", nil) end)
			local res = sert.run({ updateSnapshots = true, ci = true, quiet = true, raise = false })
			sert.eq(res.failed, 1)
			sert.contains(res.failures[1], "cannot update snapshots when CI mode is active")
		end)
		local outerTracker = registry.activeTestAssertions()
		sert.ok(outerTracker ~= nil and outerTracker.count >= 2)
	end)
end)

sert.describe("sert.snapshot", function()
	sert.test("resolves named and ordinal keys from RunOptions.snapshots and __SERT_SNAPSHOTS", function()
		withIsolatedState(function()
			sert.test("file snap", function()
				sert.snapshot({ hp = 100 }, "hero")
				sert.snapshot("ordinal-value")
			end)
			local res = sert.run({
				quiet = true,
				raise = false,
				snapshots = {
					["test/Snapshot"] = {
						["file snap :: hero"] = "{\n  hp = 100,\n}",
						["file snap :: 1"] = "ordinal-value",
					},
				},
			})
			sert.eq(res.passed, 1)
			sert.eq(res.failed, 0)
		end)

		local prevShared = rawget(registry.mutant._sharedG, "__SERT_SNAPSHOTS")
		rawset(registry.mutant._sharedG, "__SERT_SNAPSHOTS", {
			["Snapshot"] = {
				["shared snap :: card"] = "{\n  ok = true,\n}",
			},
		})
		local ok, err = pcall(function()
			withIsolatedState(function()
				sert.test(
					"shared snap",
					function() sert.snapshot({ ok = true }, "card") end,
					{ file = "test/Snapshot" }
				)
				local res = sert.run({ quiet = true, raise = false })
				sert.eq(res.passed, 1)
				sert.eq(res.failed, 0)
			end)
		end)
		rawset(registry.mutant._sharedG, "__SERT_SNAPSHOTS", prevShared)
		if not ok then error(err, 0) end
	end)

	sert.test("fails on missing or mismatched file snapshot and emits update marker under -u", function()
		withIsolatedState(function()
			sert.test("missing snap", function() sert.snapshot("v1", "key1") end)
			local missingRes = sert.run({ quiet = true, raise = false })
			sert.eq(missingRes.failed, 1)
			sert.contains(missingRes.failures[1], 'missing snapshot "missing snap :: key1"')

			local mismatchRes = sert.run({
				quiet = true,
				raise = false,
				snapshots = {
					["test/Snapshot"] = {
						["missing snap :: key1"] = "old",
					},
				},
			})
			sert.eq(mismatchRes.failed, 1)
			sert.contains(mismatchRes.failures[1], "snapshot mismatch")
			sert.contains(mismatchRes.failures[1], "- old")
			sert.contains(mismatchRes.failures[1], "+ v1")
		end)

		local captured = sert.capture(function()
			withIsolatedState(function()
				sert.test("update file snap", function() sert.snapshot("new-body", "btn") end)
				local res = sert.run({
					updateSnapshots = true,
					quiet = true,
					raise = false,
					snapshots = {
						["test/Snapshot"] = {
							["update file snap :: btn"] = "old-body",
						},
					},
				})
				sert.eq(res.passed, 1)
				sert.eq(res.failed, 0)
			end)
		end)
		local markerLine: string? = nil
		for _, line in captured do
			local payload = string.match(line, "^%[sert%-x:snapshot%] (.+)$")
			if payload ~= nil then markerLine = payload end
		end
		sert.ok(markerLine ~= nil)
		local decoded = format.jsonDecode(markerLine :: string)
		sert.eq(decoded.kind, "file")
		sert.eq(decoded.key, "update file snap :: btn")
		sert.eq(decoded.previous, "old-body")
		sert.eq(decoded.actual, "new-body")

		local insertErr = sert.throws(function() sert.inlineSnapshot("a\nextra\nb\nc", "a\nb") end)
		sert.contains(insertErr, "+ extra")
		sert.contains(insertErr, "+ c")

		local deleteErr = sert.throws(function() sert.inlineSnapshot("a\nb", "a\nold\nb\ntail") end)
		sert.contains(deleteErr, "- old")
		sert.contains(deleteErr, "- tail")

		withIsolatedState(function()
			sert.test("ci file snap", function() sert.snapshot("x", "k") end)
			local ciRes = sert.run({ updateSnapshots = true, ci = true, quiet = true, raise = false })
			sert.eq(ciRes.failed, 1)
			sert.contains(ciRes.failures[1], "cannot update snapshots when CI mode is active")
		end)

		sert.throws(function() sert.snapshot("x", 42 :: any) end, "expected snapshot name string or nil")
	end)
end)
