--!strict
-- Roblox Studio, Open Cloud, UI layout/flicker verification, remote fuzzing, and DataModel sweeping (`sert.roblox`).

local Flicker = require("@self/Flicker")
local Layout = require("@self/Layout")
local Runner = require("@self/Runner")
local conformance = require("@self/conformance")
local fuzz = require("@self/fuzz")
local sweep = require("@self/sweep")

export type Config = Runner.Config
export type Side = Runner.Side
export type Verdict = Runner.Verdict
export type Context = Runner.Context
export type Request = Runner.Request
export type Runner = typeof(Runner)

export type Rect = Layout.Rect
export type PresetName = Layout.PresetName
export type ViewportPreset = Layout.ViewportPreset
export type SettleOptions = Layout.SettleOptions
export type AuditOptions = Layout.AuditOptions
export type MatrixOptions = Layout.MatrixOptions

export type FlickerOptions = Flicker.Options
export type FlickerResult = Flicker.Result

export type RemoteFuzzSpec = fuzz.RemoteFuzzSpec
export type SweepOptions = sweep.SweepOptions
export type SweepSnapshot = sweep.Snapshot
export type ConformanceTarget = conformance.ConformanceTarget
export type ContainerKind = conformance.ContainerKind
export type ConformanceOptions = conformance.ConformanceOptions
export type ConformanceContext = conformance.ConformanceContext
export type ConformanceFn = conformance.ConformanceFn
export type ConformanceApi = conformance.ConformanceApi

return table.freeze({
	Runner = Runner,
	Layout = Layout,
	Flicker = Flicker,
	conformance = conformance.api,
	fuzzRemote = fuzz.fuzzRemote,
	sweep = sweep,
})
