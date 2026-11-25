class_name LegacyWaterSettings
extends Node

## LEGACY ARCHIVE - the water tuning that used to live in
## `PerformanceSettings`, kept out of the core project with the rest of the
## old water system.
##
## This script is NOT autoloaded. To use it again, add it as an autoload named
## `LegacyWaterSettings` (or instance it in the scene) and call
## `apply_to(water)`. The archived water menu still uses the old action names,
## so a re-enabled menu needs its own action dispatch.

const FLOW_STEPS: Array[float] = [0.067, 0.1, 0.15, 0.22, 0.3]
const EQUALIZE_STEPS: Array[float] = [0.25, 0.5, 0.75, 1.0, 1.5]
const UPDATE_BUDGETS: Array[int] = [96, 192, 384, 512, 768, 1024]
const MESH_RATES: Array[float] = [0.033, 0.05, 0.08, 0.12, 0.2]
const WAVE_STEPS: Array[float] = [0.0625, 0.125, 0.25, 0.5]
const WAVE_SAMPLES: Array[int] = [4096, 8192, 12288, 32768]

var effects: bool = true
var flow_interval: float = 0.15
var equalize_interval: float = 0.5
var update_budget: int = 384
var mesh_interval: float = 0.08
var waves: bool = true
var wave_step: float = 0.125
var wave_samples: int = 12288
var wake_style: int = 1
var splashes: bool = true
var surface_particles: bool = true


func apply_preset(quality: int) -> void:
	match clampi(quality, 0, 2):
		0:
			flow_interval = 0.3
			equalize_interval = 1.0
			update_budget = 96
			mesh_interval = 0.12
			waves = true
			wave_step = 0.25
			wave_samples = 4096
			wake_style = 0
			splashes = false
			surface_particles = false
		1:
			flow_interval = 0.15
			equalize_interval = 0.5
			update_budget = 384
			mesh_interval = 0.08
			waves = true
			wave_step = 0.125
			wave_samples = 12288
			wake_style = 1
			splashes = true
			surface_particles = true
		_:
			flow_interval = 0.1
			equalize_interval = 0.4
			update_budget = 768
			mesh_interval = 0.05
			waves = true
			wave_step = 0.0625
			wave_samples = 32768
			wake_style = 1
			splashes = true
			surface_particles = true


## Copies the archived tuning into a LegacyWaterSystem instance.
func apply_to(water) -> void:
	if water == null:
		return

	var waves_changed: bool = (
		not is_equal_approx(water.wave_step, wave_step)
		or water.wave_max_samples != wave_samples
		or water.wake_style != wake_style
	)
	water.flow_interval = flow_interval
	water.global_equalize_interval = equalize_interval
	water.max_updates_per_tick = update_budget
	water.mesh_rebuild_interval = mesh_interval
	water.wave_step = wave_step
	water.wave_max_samples = wave_samples
	water.wake_style = wake_style
	water.waves_enabled = effects and waves
	water.splashes_enabled = effects and splashes
	water.surface_particles_enabled = effects and surface_particles
	if waves_changed and water.has_method("refresh_wave_settings"):
		water.refresh_wave_settings()


func cycle_flow() -> void:
	flow_interval = _next_float(FLOW_STEPS, flow_interval)


func cycle_equalize() -> void:
	equalize_interval = _next_float(EQUALIZE_STEPS, equalize_interval)


func cycle_budget() -> void:
	update_budget = _next_int(UPDATE_BUDGETS, update_budget)


func cycle_mesh() -> void:
	mesh_interval = _next_float(MESH_RATES, mesh_interval)


func cycle_wave_detail() -> void:
	wave_step = _next_float(WAVE_STEPS, wave_step)


func cycle_wave_cap() -> void:
	wave_samples = _next_int(WAVE_SAMPLES, wave_samples)


func cycle_wake_style() -> void:
	wake_style = (wake_style + 1) % 2


func _next_float(values: Array[float], current: float) -> float:
	for index in values.size():
		if is_equal_approx(values[index], current):
			return values[(index + 1) % values.size()]
	return values[0]


func _next_int(values: Array[int], current: int) -> int:
	var index := values.find(current)
	return values[0] if index == -1 else values[(index + 1) % values.size()]
