extends Node

## Manifest-driven batch experiment runner.
##
## This is the in-game equivalent of the headless harness the research backlog
## asks for. It drives the loaded scenario/current save, sets the seed and
## condition, records each run, and writes the tidy export tables. It is a data
## tool: it never moves the camera or changes display settings.
##
## Start it from the console:
##   experiment_start res://experiments/assignment_comparison_v1.json
##   experiment_dry_run res://experiments/assignment_comparison_v1.json
##   experiment_status
##   experiment_abort
##
## It supports `resume` (skip cells in completed.json), `only` (a cell substring
## filter), `repeat`, and a dry run that validates the scenario without running.
##
## Manifest (all relative paths are resolved against res:// then user://):
## {
##   "experiment": "assignment_comparison_v1",
##   "scenarios": [
##     {"id": "S1_symmetric", "save_slug": "", "expected_exits": 4,
##      "expected_exit_ids": ["..."], "expected_service_rates": {"id": 1.2},
##      "layout_signature": "", "load_save": false, "population": 300,
##      "agent_cap": 700, "quota": 300, "horizon_s": 300}
##   ],
##   "conditions": ["baseline", "nearest", "equal_split", "greedy",
##                  "greedy_congestion", "local_search", "aco", "pso",
##                  "network_flow", "time_expanded"],
##   "seeds": [1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010],
##   "repeat": 1,
##   "objective": "balanced",
##   "cohort_size": 4.0,
##   "max_cohorts": 60,
##   "time_budget_ms": 2000,
##   "horizon_s": 300,
##   "sampling_interval": 0.25,
##   "prepopulate": true,
##   "population_count": 300,
##   "resume": true,
##   "only": "",
##   "output_root": "user://experiments"
## }

signal status_changed(text: String)
signal cell_finished(cell_id: String, result: Dictionary)
signal experiment_finished(result: Dictionary)

var running: bool = false
var aborted: bool = false
var current_cell: String = ""
var current_index: int = 0
var total_cells: int = 0
var status_text: String = "idle"
var last_result: Dictionary = {}

var _manifest: Dictionary = {}
var _manifest_path: String = ""
var _completed: Dictionary = {}
var _completed_path: String = ""
var _output_root: String = "user://experiments"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func start_from_file(path: String, options: Dictionary = {}) -> Dictionary:
	if running:
		return {"ok": false, "error": "an experiment is already running"}

	var manifest_path := _resolve_path(path)

	if manifest_path.is_empty():
		return {"ok": false, "error": "manifest not found: %s" % path}

	var manifest := _read_json(manifest_path)

	if manifest.is_empty():
		return {"ok": false, "error": "manifest is empty or invalid JSON"}

	for key: Variant in options:
		manifest[key] = options[key]

	var validation := _validate_manifest(manifest)

	if not bool(validation.get("ok", false)):
		return validation

	_manifest = manifest
	_manifest_path = manifest_path
	_output_root = String(manifest.get("output_root", "user://experiments"))
	_completed_path = _experiment_dir().path_join("completed.json")
	_completed = _read_json(_completed_path) if bool(manifest.get("resume", true)) else {}
	aborted = false
	running = true
	last_result = {}
	current_index = 0
	total_cells = int(validation.get("cells", 0))
	_publish("starting %s (%d cells)" % [String(manifest.get("experiment", "experiment")), total_cells])
	await _run_experiment()
	return {"ok": true, "experiment": String(manifest.get("experiment", "")), "cells": total_cells}


func dry_run(path: String, options: Dictionary = {}) -> Dictionary:
	var manifest_path := _resolve_path(path)

	if manifest_path.is_empty():
		return {"ok": false, "error": "manifest not found: %s" % path}

	var manifest := _read_json(manifest_path)

	if manifest.is_empty():
		return {"ok": false, "error": "manifest is empty or invalid JSON"}

	for key: Variant in options:
		manifest[key] = options[key]

	var validation := _validate_manifest(manifest)

	if bool(validation.get("ok", false)):
		validation["cells_list"] = _cell_ids(manifest, String(manifest.get("only", "")))
		validation["output_root"] = String(manifest.get("output_root", "user://experiments"))
		validation["output_display"] = ProjectSettings.globalize_path(
			String(validation["output_root"])
		)

	return validation


func abort() -> void:
	if not running:
		return

	aborted = true
	_publish("abort requested; finishing the current cell")


func status() -> Dictionary:
	return {
		"running": running,
		"aborted": aborted,
		"cell": current_cell,
		"index": current_index,
		"total": total_cells,
		"status": status_text,
		"experiment": String(_manifest.get("experiment", "")),
		"last": last_result.duplicate(true),
	}


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

func _validate_manifest(manifest: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var experiment := String(manifest.get("experiment", ""))

	if experiment.is_empty():
		errors.append("manifest needs an experiment name")

	var scenarios_value: Variant = manifest.get("scenarios", [])
	var scenarios: Array = scenarios_value if scenarios_value is Array else []

	if scenarios.is_empty():
		errors.append("manifest needs at least one scenario")

	var conditions_value: Variant = manifest.get("conditions", [])
	var conditions: Array = conditions_value if conditions_value is Array else []

	if conditions.is_empty():
		errors.append("manifest needs at least one condition")

	for condition_value: Variant in conditions:
		var condition := String(condition_value)

		if condition != "baseline" and not OptimizationRequest.ALGORITHMS.has(condition):
			errors.append("unknown condition: %s" % condition)

	var seeds_value: Variant = manifest.get("seeds", [])
	var seeds: Array = seeds_value if seeds_value is Array else []

	if seeds.is_empty():
		errors.append("manifest needs at least one seed")

	var objective := String(manifest.get("objective", "balanced"))

	if not OptimizationRequest.MODES.has(objective):
		errors.append("unknown objective: %s" % objective)

	var cells := _cell_ids(manifest, String(manifest.get("only", "")))

	if cells.is_empty():
		errors.append("no cells match the only filter")

	# Validate the currently loaded scenario against the first declaration that
	# names it. Switching saves is optional, so this is a warning list; the
	# runner still refuses to start a cell whose declared exits do not match.
	var scenario_errors: Array[String] = []
	var scenario_warnings: Array[String] = []
	var has_fixture := false

	for scenario_value: Variant in scenarios:
		var scenario := _scenario_dictionary(scenario_value)
		var uses_fixture := scenario.has("fixture") or scenario.has("fixture_preset")

		if uses_fixture:
			has_fixture = true
			continue

		var check := _validate_loaded_scenario(scenario)

		if not bool(check.get("ok", false)) and String(check.get("error", "")).begins_with("mismatch"):
			scenario_errors.append(String(check.get("error", "")))

	if has_fixture:
		scenario_warnings.append("fixture scenario(s) are built when the runner starts; dry-run does not build them")

	return {
		"ok": errors.is_empty() and scenario_errors.is_empty(),
		"errors": errors + scenario_errors,
		"warnings": scenario_warnings,
		"experiment": experiment,
		"cells": cells.size(),
		"scenarios": scenarios.size(),
		"conditions": conditions.size(),
		"seeds": seeds.size(),
		"repeat": maxi(1, int(manifest.get("repeat", 1))),
	}


func _scenario_dictionary(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)

	return {"id": String(value)}


func _cell_ids(manifest: Dictionary, only: String) -> Array[String]:
	var cells: Array[String] = []
	var scenarios: Array = manifest.get("scenarios", [])
	var conditions: Array = manifest.get("conditions", [])
	var seeds: Array = manifest.get("seeds", [])
	var repeat := maxi(1, int(manifest.get("repeat", 1)))

	for scenario_value: Variant in scenarios:
		var scenario := _scenario_dictionary(scenario_value)
		var scenario_id := String(scenario.get("id", "scenario"))

		for condition_value: Variant in conditions:
			var condition := String(condition_value)

			for seed_value: Variant in seeds:
				var seed_id := int(seed_value)

				for rep: int in range(1, repeat + 1):
					var cell := "%s|%s|%d|%d" % [scenario_id, condition, seed_id, rep]

					if only.is_empty() or cell.contains(only):
						cells.append(cell)

	return cells


func _validate_loaded_scenario(scenario: Dictionary) -> Dictionary:
	var save_slug := String(scenario.get("save_slug", ""))

	if not save_slug.is_empty():
		var demo_store := get_node_or_null("/root/DemoStore")
		var active := String(demo_store.call("active_save_slug")) if demo_store != null else ""

		if active != save_slug:
			return {
				"ok": false,
				"error": "mismatch: loaded save is '%s', scenario wants '%s'" % [active, save_slug],
			}

	var exits := _live_exits()

	if scenario.has("expected_exits") and exits.size() != int(scenario.get("expected_exits", 0)):
		return {
			"ok": false,
			"error": "mismatch: %d exits loaded, scenario declares %d" % [
				exits.size(), int(scenario.get("expected_exits", 0))
			],
		}

	var expected_ids: Variant = scenario.get("expected_exit_ids", [])

	if expected_ids is Array and not (expected_ids as Array).is_empty():
		var live_ids: Array[String] = []

		for exit_id: Variant in exits.keys():
			live_ids.append(String(exit_id))

		live_ids.sort()

		var wanted: Array[String] = []

		for value: Variant in expected_ids:
			wanted.append(String(value))

		wanted.sort()

		if live_ids != wanted:
			return {
				"ok": false,
				"error": "mismatch: exit ids %s vs expected %s" % [live_ids, wanted],
			}

	var expected_rates: Variant = scenario.get("expected_service_rates", {})

	if expected_rates is Dictionary and not (expected_rates as Dictionary).is_empty():
		for exit_id: Variant in (expected_rates as Dictionary).keys():
			var want := float((expected_rates as Dictionary)[exit_id])
			var have := float(exits.get(String(exit_id), {}).get("service_rate", -1.0))

			if absf(want - have) > 0.001:
				return {
					"ok": false,
					"error": "mismatch: exit %s rate %.3f, expected %.3f" % [
						String(exit_id), have, want
					],
				}

	var signature := String(scenario.get("layout_signature", ""))

	if not signature.is_empty():
		var current := String(EvacuationPlan.capture_layout_signature().get("signature", ""))

		if signature != current:
			return {"ok": false, "error": "mismatch: layout signature differs from the fixture"}

	return {"ok": true}


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

func _run_experiment() -> void:
	var started_at := Time.get_datetime_string_from_system(true, true)
	var cells := _cell_ids(_manifest, String(_manifest.get("only", "")))
	var completed_ids: Array[String] = []
	var failures: Array[String] = []
	var export_ids: Array[String] = []
	var scenarios: Array = _manifest.get("scenarios", [])
	var repeat := maxi(1, int(_manifest.get("repeat", 1)))
	var require_complete := bool(_manifest.get("require_complete", false))

	DirAccess.make_dir_recursive_absolute(_experiment_dir())

	for index: int in range(cells.size()):
		if aborted:
			break

		current_index = index + 1
		var cell_id := cells[index]
		current_cell = cell_id

		if bool(_manifest.get("resume", true)) and _completed.has(cell_id):
			completed_ids.append(cell_id)
			_publish("skip completed %d/%d: %s" % [current_index, cells.size(), cell_id])
			continue

		_publish("cell %d/%d: %s" % [current_index, cells.size(), cell_id])
		var parts := cell_id.split("|")
		var scenario_id := String(parts[0])
		var condition := String(parts[1])
		var seed_id := int(parts[2])
		var rep := int(parts[3])
		var scenario := _find_scenario(scenarios, scenario_id)

		if scenario.is_empty():
			failures.append("%s: scenario not found" % cell_id)
			continue

		var scenario_check := await _ensure_scenario(scenario)

		if not bool(scenario_check.get("ok", false)):
			failures.append("%s: %s" % [cell_id, String(scenario_check.get("error", ""))])
			_publish("FAILED %s: %s" % [cell_id, String(scenario_check.get("error", ""))])

			if bool(_manifest.get("abort_on_failure", true)):
				break

			continue

		var result := await _run_cell(cell_id, scenario, condition, seed_id, rep)

		if not bool(result.get("ok", false)):
			failures.append("%s: %s" % [cell_id, String(result.get("error", ""))])
			_publish("FAILED %s: %s" % [cell_id, String(result.get("error", ""))])

			if bool(_manifest.get("abort_on_failure", true)):
				break

			continue

		completed_ids.append(cell_id)
		_completed[cell_id] = result.duplicate(true)
		_write_json(_completed_path, _completed)
		last_result = result.duplicate(true)
		cell_finished.emit(cell_id, result)

		var demo_id := String(result.get("demo_id", ""))

		if not demo_id.is_empty():
			export_ids.append(demo_id)

		if require_complete and not bool(result.get("complete", false)):
			failures.append("%s: run did not complete within the horizon" % cell_id)
			_publish("FAILED %s: incomplete run" % cell_id)

			if bool(_manifest.get("abort_on_failure", true)):
				break

		await get_tree().process_frame

	running = false
	current_cell = ""

	var combined := {"ok": true}

	if not export_ids.is_empty():
		combined = ExperimentExporter.export_demos(
			export_ids,
			String(_manifest.get("experiment", "experiment")),
			_output_root,
			"",
			true
		)

	var summary := {
		"ok": failures.is_empty(),
		"experiment": String(_manifest.get("experiment", "")),
		"started_at": started_at,
		"finished_at": Time.get_datetime_string_from_system(true, true),
		"cells_total": cells.size(),
		"cells_completed": completed_ids.size(),
		"cells_failed": failures.size(),
		"failures": failures,
		"completed": completed_ids,
		"export": combined,
		"output_display": String(combined.get("output_display", "")),
		"resume_file": _completed_path,
		"aborted": aborted,
	}
	_write_json(_experiment_dir().path_join("summary.json"), summary)
	_publish(
		"finished: %d/%d cells, %d failures%s" % [
			completed_ids.size(),
			cells.size(),
			failures.size(),
			" (aborted)" if aborted else "",
		]
	)
	experiment_finished.emit(summary)
	last_result = summary


func _ensure_scenario(scenario: Dictionary) -> Dictionary:
	var save_slug := String(scenario.get("save_slug", ""))
	var demo_store := get_node_or_null("/root/DemoStore")
	var active := String(demo_store.call("active_save_slug")) if demo_store != null else ""

	if not save_slug.is_empty() and (active != save_slug or bool(scenario.get("force_load", false))):
		if not bool(scenario.get("load_save", false)):
			return {
				"ok": false,
				"error": "loaded save '%s' is not scenario '%s' (set load_save=true to switch)" % [
					active, save_slug
				],
			}

		var save_manager := get_node_or_null("/root/SaveManager")

		if save_manager == null:
			return {"ok": false, "error": "SaveManager autoload is unavailable"}

		save_manager.call("load_save", save_slug)
		# The scene change recreates the HUD, bridge and populator.
		await _wait_for_scene()

	var fixture_value: Variant = scenario.get("fixture", {})

	if scenario.has("fixture_preset"):
		var preset_result: Dictionary = ExperimentFixture.build_preset(
			String(scenario.get("fixture_preset", ""))
		)

		if not bool(preset_result.get("ok", false)):
			return preset_result

		await get_tree().process_frame
		await get_tree().process_frame
	elif fixture_value is Dictionary and not (fixture_value as Dictionary).is_empty():
		var fixture_result: Dictionary = ExperimentFixture.build(fixture_value)

		if not bool(fixture_result.get("ok", false)):
			return fixture_result

		await get_tree().process_frame
		await get_tree().process_frame

	var check := _validate_loaded_scenario(scenario)

	if not bool(check.get("ok", false)):
		return check

	return {"ok": true, "scenario": scenario, "bridge": _bridge(), "populator": _populator()}


func _wait_for_scene() -> void:
	for _i: int in range(600):
		await get_tree().process_frame

		if get_tree().current_scene != null and _bridge() != null and _populator() != null:
			await get_tree().create_timer(0.2).timeout
			return


func _run_cell(
	cell_id: String,
	scenario: Dictionary,
	condition: String,
	seed_value: int,
	repeat_index: int
) -> Dictionary:
	var bridge: Node = _bridge()
	var populator: Node = _populator()

	if bridge == null:
		return {"ok": false, "error": "no optimizer bridge in the current scene"}

	if populator == null:
		return {"ok": false, "error": "no RandomPopulator in the current scene"}

	var horizon := float(scenario.get("horizon_s", _manifest.get("horizon_s", 300.0)))
	var sampling_interval := float(_manifest.get("sampling_interval", 0.25))
	var population := int(scenario.get("population", _manifest.get("population_count", 0)))
	var prepopulate := bool(scenario.get("prepopulate", _manifest.get("prepopulate", population > 0)))
	var agent_cap := int(scenario.get("agent_cap", _manifest.get("agent_cap", 700)))
	var quota := int(scenario.get("quota", _manifest.get("quota", population if prepopulate else -1)))
	var condition_algorithm := "" if condition == "baseline" else condition

	# Configure the condition before Start so the run header records it.
	bridge.call("set_enabled", condition != "baseline")

	if condition != "baseline":
		bridge.call("set_algorithm", condition)
		bridge.call("set_mode", String(_manifest.get("objective", "balanced")))
		bridge.call("set_cohort_size", float(_manifest.get("cohort_size", 4.0)))
		bridge.call("set_max_cohorts", int(_manifest.get("max_cohorts", 60)))
		bridge.call("set_auto_solve", true)
		bridge.call("set_re_solve_enabled", bool(_manifest.get("re_solve", true)))
		bridge.call("set_re_solve_interval", float(_manifest.get("re_solve_interval", 15.0)))
		bridge.call("set_first_solve_delay", float(scenario.get("first_solve_delay", _manifest.get("first_solve_delay", 1.0))))
		bridge.call("set_solve_on_spawn_complete", bool(scenario.get("solve_on_spawn_complete", _manifest.get("solve_on_spawn_complete", false))))
		bridge.call("set_hysteresis_enabled", bool(_manifest.get("hysteresis_enabled", true)))
		bridge.call("set_hysteresis_ratio", float(_manifest.get("hysteresis_ratio", 0.10)))
		bridge.call("set_parameters", {
			"time_budget_ms": float(_manifest.get("time_budget_ms", 250.0)),
			"max_combinations": int(_manifest.get("max_combinations", 250000)),
			"aco_ants": int(_manifest.get("aco_ants", 16)),
			"aco_iterations": int(_manifest.get("aco_iterations", 40)),
			"pso_swarm": int(_manifest.get("pso_swarm", 24)),
			"pso_iterations": int(_manifest.get("pso_iterations", 60)),
		})
	else:
		bridge.call("set_enabled", false)

	GlobalData.global_unit_cap = maxi(1, agent_cap)
	GlobalData.global_spawn_quota = quota
	GlobalData.rng_seed = seed_value
	GlobalData.reset_determinism(seed_value)
	GlobalData.set_evacuation_mode(true)

	# Reset the previous population and counters. Stop a leftover recording so
	# the new cell starts with its own demo.
	if SimRecorder.is_recording():
		SimRecorder.stop_manual_recording()

	GlobalData.reset_spawning()
	await get_tree().process_frame
	await get_tree().process_frame
	GlobalData.kill_all_npcs()
	await get_tree().process_frame

	if prepopulate:
		populator.set("member_count", population)
		populator.set("start_evacuating", true)
		populator.set("only_pathfindable_blocks", bool(_manifest.get("pathfind_only", false)))
		populator.set("freeze_until_start", true)
		var populated: Dictionary = populator.call("populate")

		if int(populated.get("spawned", 0)) < population:
			return {
				"ok": false,
				"error": "populate spawned %d/%d: %s" % [
					int(populated.get("spawned", 0)),
					population,
					String(populated.get("reason", "")),
				],
			}

	SimRecorder.sampling_interval = sampling_interval
	SimRecorder.set_recording_enabled(true)
	SimRecorder.set_experiment_context({
		"experiment": String(_manifest.get("experiment", "")),
		"experiment_scenario": String(scenario.get("id", "")),
		"horizon_s": horizon,
		"repeat_index": repeat_index,
		"cell_id": cell_id,
	})

	var start_sim := GlobalData.sim_now()
	GlobalData.start_spawning()
	await get_tree().process_frame

	var complete := false
	var timed_out := false
	var last_status_log := start_sim

	while not aborted:
		await get_tree().create_timer(0.5).timeout

		var elapsed := GlobalData.sim_now() - start_sim
		var alive: int = get_tree().get_nodes_in_group("npc").size()
		var quota_met := quota > 0 and GlobalData.npcs_spawned >= quota

		if quota_met and alive == 0:
			complete = true
			break

		if elapsed >= horizon:
			timed_out = true
			break

		if GlobalData.sim_now() - last_status_log >= 30.0:
			last_status_log = GlobalData.sim_now()
			_publish("  %s: %.0f/%.0f s, %d alive" % [cell_id, elapsed, horizon, alive])

	GlobalData.stop_spawning()
	await get_tree().process_frame
	await get_tree().process_frame

	var demo_id := SimRecorder.get_demo_id()
	var summary := SimRecorder.get_last_summary()
	var cell_dir := _experiment_dir().path_join("cells").path_join(_slugify(cell_id))
	var export := ExperimentExporter.export_demo(demo_id, cell_dir) if not demo_id.is_empty() else {}
	var export_error := String(export.get("error", ""))

	if not export.is_empty() and not bool(export.get("ok", false)) and not export_error.is_empty():
		return {"ok": false, "error": "export failed: %s" % export_error}

	return {
		"ok": true,
		"cell_id": cell_id,
		"scenario": String(scenario.get("id", "")),
		"condition": condition,
		"algorithm": condition_algorithm,
		"seed": seed_value,
		"repeat_index": repeat_index,
		"demo_id": demo_id,
		"complete": complete,
		"timed_out": timed_out,
		"duration_s": float(summary.get("duration", 0.0)),
		"agents_spawned": int(summary.get("agents_spawned", 0)),
		"agents_evacuated": int(summary.get("agents_evacuated", 0)),
		"total_evacuation_time_s": float(summary.get("total_evacuation_time", 0.0)),
		"export_dir": String(export.get("output_dir", "")),
		"export_display": String(export.get("output_display", "")),
	}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _bridge() -> Node:
	if get_tree() == null:
		return null

	return get_tree().get_first_node_in_group("optimizer_bridge")


func _populator() -> Node:
	if get_tree() == null:
		return null

	return get_tree().get_first_node_in_group("random_populator")


func _find_scenario(scenarios: Array, scenario_id: String) -> Dictionary:
	for scenario_value: Variant in scenarios:
		var scenario := _scenario_dictionary(scenario_value)

		if String(scenario.get("id", "")) == scenario_id:
			return scenario

	return {}


func _live_exits() -> Dictionary:
	var result: Dictionary = {}
	var tree := get_tree()

	if tree == null:
		return result

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node) or not node.has_method("get_exit_status"):
			continue

		var exit_status: Dictionary = node.call("get_exit_status")
		result[String(exit_status.get("exit_id", ""))] = exit_status

	return result


func _experiment_dir() -> String:
	return _output_root.path_join(_slugify(String(_manifest.get("experiment", "experiment"))))


func _resolve_path(path: String) -> String:
	if path.is_empty():
		return ""

	if FileAccess.file_exists(path):
		return path

	for prefix: String in ["res://", "user://"]:
		if FileAccess.file_exists(prefix + path):
			return prefix + path

	return ""


func _read_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _write_json(path: String, value: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return

	file.store_string(JSON.stringify(value, "\t", false))
	file.close()


func _slugify(value: String) -> String:
	var cleaned := value.strip_edges().to_lower()
	var result := ""

	for character: String in cleaned:
		if character in "abcdefghijklmnopqrstuvwxyz0123456789_-":
			result += character
		elif character in [" ", "|", "."]:
			result += "_"

	return result if not result.is_empty() else "experiment"


func _publish(text: String) -> void:
	status_text = text
	print("[ExperimentRunner] ", text)
	status_changed.emit(text)
