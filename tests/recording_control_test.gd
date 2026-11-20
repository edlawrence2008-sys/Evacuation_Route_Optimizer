extends Node

## Recording-control acceptance:
##   - a continuation demo copies the source prefix up to the load tick,
##   - live recording continues after it and finalizes with the combined summary,
##   - a completed quota with no live member auto-finalizes,
##   - manual start/stop works without Start.
##
##   godot --headless --path . res://tests/recording_control_test.tscn

const SLUG: String = "__recording_control_test__"

var _checks: int = 0
var _failures: int = 0
var _original_slug: String = ""
var _original_recording: bool = false
var _original_seed: int = 0
var _original_quota: int = 0
var _original_spawned: int = 0
var _original_evacuated: int = 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== recording control ===")

	var save_manager := get_node_or_null("/root/SaveManager")
	var store := get_node_or_null("/root/DemoStore")

	if save_manager == null or store == null:
		_fail("SaveManager/DemoStore unavailable")
		_finish()
		return

	_original_slug = String(save_manager.active_slug)
	_original_recording = SimRecorder.recording_enabled
	_original_seed = GlobalData.rng_seed
	_original_quota = GlobalData.global_spawn_quota
	_original_spawned = GlobalData.npcs_spawned
	_original_evacuated = GlobalData.npcs_evacuated

	SimRecorder.set_recording_enabled(false)
	save_manager.active_slug = SLUG
	_test_runtime_exports()

	var source: Dictionary = store.call("create_demo", "Recording Source", {
		"seed": 777,
		"scene": "res://tests/recording_control_test.tscn",
		"sample_interval": 0.25,
		"status": "complete",
		"started_at": "2026-11-20_00-00-00",
	}, SLUG)
	var source_id := String(source.get("id", ""))
	_expect("source demo created", not source_id.is_empty())

	if not source_id.is_empty():
		_write_source(store, source_id)

		SimRecorder.prepare_continuation(source_id, 30.0)
		SimRecorder.resume_continuation()
		_expect("continuation recording starts", SimRecorder.is_recording())

		var new_id := SimRecorder.get_demo_id()
		_expect("continuation demo created", not new_id.is_empty())

		SimRecorder.stop_manual_recording()
		_expect("continuation stops", not SimRecorder.is_recording())

		if not new_id.is_empty():
			_assert_continuation(store, source_id, new_id)

		# Every quota is met and no member is alive. _sample gives the recorder
		# at least one tick, then the completion check must close it.
		GlobalData.global_spawn_quota = 0
		GlobalData.npcs_spawned = 1
		GlobalData.npcs_evacuated = 1
		_expect("manual recording starts", SimRecorder.start_manual_recording())
		SimRecorder.call("_sample", GlobalData.sim_now())
		SimRecorder.call("_maybe_auto_finalize")
		_expect("quota completion auto-finalizes", not SimRecorder.is_recording())

		if not SimRecorder.get_demo_id().is_empty():
			store.call("delete_demo", SimRecorder.get_demo_id(), SLUG)

		store.call("delete_demo", new_id, SLUG)
		store.call("delete_demo", source_id, SLUG)

	_cleanup_save_folder()
	save_manager.active_slug = _original_slug
	SimRecorder.set_recording_enabled(_original_recording)
	GlobalData.rng_seed = _original_seed
	GlobalData.global_spawn_quota = _original_quota
	GlobalData.npcs_spawned = _original_spawned
	GlobalData.npcs_evacuated = _original_evacuated
	_finish()


func _test_runtime_exports() -> void:
	var runtime := get_node_or_null("/root/RuntimeExports")

	if runtime == null:
		_fail("RuntimeExports autoload missing")
		return

	var cap: int = GlobalData.global_unit_cap
	var quota: int = GlobalData.global_spawn_quota
	var seed_value: int = GlobalData.rng_seed
	var evac: bool = GlobalData.evacuation_mode
	var agents: Dictionary = GlobalData.agent_overrides.duplicate(true)

	GlobalData.global_unit_cap = 321
	GlobalData.global_spawn_quota = 77
	GlobalData.rng_seed = 4242
	GlobalData.evacuation_mode = false
	GlobalData.set_agent_overrides({
		"movement_speed": 1.55,
		"desired_speed_max": 2.05,
		"sprite_offset": Vector3(0.1, 0.2, 0.3),
	})

	var block: Dictionary = runtime.call("collect_live")
	var global_block: Dictionary = block.get("global", {})
	var agent_block: Dictionary = block.get("agents", {})
	_expect("runtime exports capture cap", int(global_block.get("global_unit_cap", 0)) == 321)
	_expect("runtime exports capture quota", int(global_block.get("global_spawn_quota", 0)) == 77)
	_expect("runtime exports capture seed", int(global_block.get("rng_seed", 0)) == 4242)
	_expect("runtime exports capture evacuation mode", not bool(global_block.get("evacuation_mode", true)))
	_expect(
		"runtime exports capture agent overrides",
		_is_close(float(agent_block.get("movement_speed", 0.0)), 1.55, 0.001)
	)
	_expect(
		"runtime exports encode vector3",
		agent_block.get("sprite_offset") is Dictionary
	)

	var save_manager := get_node_or_null("/root/SaveManager")

	if save_manager != null:
		var manifest: Dictionary = save_manager.call("_build_manifest", "Test", {})
		var saved_exports: Dictionary = manifest.get("runtime_exports", {})
		var saved_global: Dictionary = saved_exports.get("global", {})
		_expect(
			"save manifest carries runtime exports",
			int(saved_global.get("global_unit_cap", 0)) == 321,
			str(saved_global.get("global_unit_cap", 0))
		)

		var evac_scene: PackedScene = load(
			"res://scenes/placeables/sim/sim_evac_point.tscn"
		)
		var exit_node: Node3D = evac_scene.instantiate()
		add_child(exit_node)
		var area := exit_node.get_node("Area3D")
		area.set("exit_id", "TEST_EXIT")
		area.set("exit_service_rate", 3.25)
		area.set("receiving_area_offset", Vector3(0.1, 0.2, 0.3))
		var entries: Array = save_manager.call("_collect_placeables")
		var found_child_props := false

		for entry: Dictionary in entries:
			if not String(entry.get("scene", "")).ends_with(
				"sim_evac_point.tscn"
			):
				continue

			for group: Dictionary in entry.get("node_props", []):
				if String(group.get("path", "")) != "Area3D":
					continue

				var child_props: Dictionary = group.get("props", {})
				found_child_props = true
				_expect(
					"placeable child export exit id",
					String(child_props.get("exit_id", "")) == "TEST_EXIT",
					String(child_props.get("exit_id", ""))
				)
				_expect(
					"placeable child export service rate",
					_is_close(
						float(child_props.get("exit_service_rate", 0.0)),
						3.25,
						0.001
					)
				)
				_expect(
					"placeable child vector export encoded",
					child_props.get("receiving_area_offset") is Dictionary
				)
				var decoded = RuntimeExports.decode_value(
					child_props.get("receiving_area_offset")
				)
				_expect(
					"placeable child vector export decodes",
					decoded is Vector3 and _is_close(decoded.y, 0.2, 0.001)
				)

		_expect("placeable child props collected", found_child_props)
		exit_node.free()

	GlobalData.global_unit_cap = 1
	GlobalData.global_spawn_quota = -1
	GlobalData.rng_seed = 1
	GlobalData.evacuation_mode = true
	GlobalData.set_agent_overrides({})
	runtime.call("apply_live", block)
	_expect("runtime exports restore cap", GlobalData.global_unit_cap == 321, str(GlobalData.global_unit_cap))
	_expect("runtime exports restore quota", GlobalData.global_spawn_quota == 77, str(GlobalData.global_spawn_quota))
	_expect("runtime exports restore seed", GlobalData.rng_seed == 4242, str(GlobalData.rng_seed))
	_expect("runtime exports restore evacuation mode", not GlobalData.evacuation_mode)
	_expect(
		"runtime exports restore agent overrides",
		_is_close(
			float(GlobalData.agent_overrides.get("movement_speed", 0.0)),
			1.55,
			0.001
		)
	)
	_expect(
		"runtime exports revive vector3",
		GlobalData.agent_overrides.get("sprite_offset") is Vector3
	)

	GlobalData.global_unit_cap = cap
	GlobalData.global_spawn_quota = quota
	GlobalData.rng_seed = seed_value
	GlobalData.evacuation_mode = evac
	GlobalData.set_agent_overrides(agents)


func _write_source(store: Node, demo_id: String) -> void:
	var path := String(store.call("recording_path", demo_id, SLUG))
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		_fail("cannot write source recording")
		return

	var run := {
		"type": "run", "t": 10.0, "format": "ero-sim-recording", "version": 1,
		"run_id": demo_id, "demo_id": demo_id, "save_slug": SLUG,
		"started_at": "2026-11-20_00-00-00", "rng_seed": 777,
		"scene": "res://tests/recording_control_test.tscn",
		"sample_interval": 0.25,
		"exits": [],
		"metadata": {"optimizer": {"available": false}},
	}
	var spawn := {
		"type": "agent_spawn", "t": 10.0, "agent": 1, "agent_id": 1,
		"name": "A", "position": [0.0, 0.0, 0.0], "desired_speed": 1.2,
		"pre_movement_delay": 0.0,
	}
	var tick := {
		"type": "tick", "t": 20.0,
		"sim": {
			"time": 20.0, "elapsed": 10.0, "active": 1, "spawned": 1,
			"evacuated": 0, "density_mean": 1.0, "density_max": 2.0,
			"speed_mean": 1.1, "peak_contact_force": 10.0,
			"contact_pairs_total": 1, "agent_contact_samples_total": 1,
			"contact_solves": 1,
		},
		"agents": [[1, "seeking_exit", 4, 0.0, 0.0, 0.0]],
		"exits": [],
	}
	var evacuation := {
		"type": "evacuation", "t": 25.0, "agent": 1, "exit_id": "A",
		"exit_name": "A", "evacuation_time": 15.0, "wait_time": 0.0,
		"distance": 12.0, "stuck_time": 0.0, "stuck_strikes": 0,
		"peak_density": 2.0, "peak_contact_force": 10.0,
		"pre_movement_wait": 0.0, "route_changes": 0, "route_switches": 0,
	}
	var end := {"type": "end", "t": 30.0, "reason": "complete", "summary": {}}

	for record: Dictionary in [run, spawn, tick, evacuation, end]:
		file.store_line(JSON.stringify(record))

	file.close()


func _assert_continuation(store: Node, source_id: String, new_id: String) -> void:
	var path := String(store.call("recording_path", new_id, SLUG))
	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		_fail("continuation recording missing")
		return

	var run: Dictionary = {}
	var ticks := 0
	var evacuations := 0
	var ends := 0

	while not file.eof_reached():
		var line := file.get_line()

		if line.strip_edges().is_empty():
			continue

		var parsed: Variant = JSON.parse_string(line)

		if not parsed is Dictionary:
			continue

		var record: Dictionary = parsed

		match String(record.get("type", "")):
			"run":
				run = record
			"tick":
				ticks += 1
			"evacuation":
				evacuations += 1
			"end":
				ends += 1

	file.close()

	_expect("continuation has source run", not run.is_empty())
	_expect(
		"continuation run points at source",
		String(run.get("resumed_from", "")) == source_id,
		String(run.get("resumed_from", ""))
	)
	_expect(
		"continuation run has new id",
		String(run.get("demo_id", "")) == new_id,
		String(run.get("demo_id", ""))
	)
	_expect("continuation copied one tick", ticks == 1, str(ticks))
	_expect("continuation copied evacuation", evacuations == 1, str(evacuations))
	_expect("continuation drops source end", ends == 1, str(ends))

	var meta: Dictionary = store.call("get_demo", new_id, SLUG)
	var summary: Dictionary = meta.get("summary", {})
	_expect(
		"continuation summary includes earlier evacuation",
		int(summary.get("agents_evacuated", 0)) == 1,
		str(summary.get("agents_evacuated", 0))
	)


func _cleanup_save_folder() -> void:
	var saves := "user://saves"
	var folder := saves.path_join(SLUG)
	_remove_dir(folder)


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)

	if dir == null:
		return

	dir.list_dir_begin()
	var name := dir.get_next()

	while not name.is_empty():
		if name != "." and name != "..":
			var child := path.path_join(name)

			if dir.current_is_dir():
				_remove_dir(child)
			else:
				DirAccess.remove_absolute(child)

		name = dir.get_next()

	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _finish() -> void:
	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(name: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + name)
		return

	_failures += 1
	print("  FAIL  " + name + ("" if detail.is_empty() else "  [" + detail + "]"))


func _is_close(value: float, expected: float, tolerance: float) -> bool:
	return absf(value - expected) <= tolerance


func _fail(name: String) -> void:
	_expect(name, false)
