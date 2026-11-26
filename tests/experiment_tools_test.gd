extends Node

## Plan persistence + tidy export test.
##
## Run in a scene because it uses the autoloads:
##   godot --headless --path . res://tests/experiment_tools_test.tscn

const MEMBER_SCENE := preload("res://scenes/npcs/Member.tscn")
const EVAC_SCENE := preload("res://scenes/placeables/sim/sim_evac_point.tscn")
const AGENT_COUNT: int = 12

var _checks: int = 0
var _failures: int = 0
var _world: Node3D
var _grid: NavGridMap
var _bridge: OptimizerBridge
var _members: Array = []
var _demo_id: String = ""
var _plan_id: String = ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== experiment tools ===")

	await get_tree().process_frame
	_build_world()
	await get_tree().process_frame

	await _test_live_plan_round_trip()
	_test_recording_reconstruction()
	await _test_export()
	await _test_authored_route()
	await _test_fixture()
	_cleanup()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "ExperimentTools"
	add_child(_world)

	_grid = NavGridMap.new()
	_grid.name = "TestGrid"
	_grid.mesh_library = _make_library()
	_grid.cell_size = Vector3.ONE
	_grid.enable_greedy_meshing = false
	_grid.enable_flow_fields = false
	_grid.auto_generate_stairs = false
	_grid.wall_force_enabled = false
	_world.add_child(_grid)
	var cells: Array[Vector3i] = []

	for x: int in range(16):
		for z: int in range(10):
			cells.append(Vector3i(x, 0, z))

	_grid.place_blocks(cells, 0)
	_add_exit("A", Vector3(2.5, 1.0, 2.5), 2.0)
	_add_exit("B", Vector3(13.5, 1.0, 7.5), 1.0)

	for index: int in range(AGENT_COUNT):
		_add_member(Vector3(7.0 + float(index % 3), 0.75, 4.0 + float(index / 3)))

	_bridge = OptimizerBridge.new()
	_bridge.name = "OptimizerBridge"
	_world.add_child(_bridge)
	_bridge.set_algorithm(OptimizationRequest.ALGORITHM_GREEDY)
	_bridge.set_mode(OptimizationRequest.MODE_BALANCED)
	_bridge.set_auto_solve(false)
	_bridge.set_enabled(true)


func _test_live_plan_round_trip() -> void:
	_expect("bridge: solve completed", await _request_and_wait())

	if _bridge.last_result == null:
		return

	var plan := _bridge.capture_plan("test plan")
	_expect("plan: captured", plan != null)

	if plan == null:
		return

	_expect("plan: has assignments", plan.assignment_count() > 0, str(plan.assignment_count()))
	_expect("plan: has cohorts", plan.cohort_count() > 0, str(plan.cohort_count()))
	_expect("plan: has a layout signature", not plan.layout_signature.is_empty())
	_plan_id = PlanStore.save_plan(plan, "test_plan")
	_expect("plan: saved", not _plan_id.is_empty(), _plan_id)

	var loaded := PlanStore.load_plan(_plan_id)
	_expect("plan: reloaded", loaded != null)

	if loaded == null:
		return

	_expect(
		"plan: assignments survive JSON",
		loaded.assignment_count() == plan.assignment_count(),
		"%d vs %d" % [loaded.assignment_count(), plan.assignment_count()]
	)
	_expect(
		"plan: cohorts survive JSON",
		loaded.cohort_count() == plan.cohort_count()
	)
	_expect("plan: listed", _plan_id in _plan_ids(PlanStore.list_plans()))

	var result: Dictionary = _bridge.apply_plan(loaded)
	_expect("plan: apply accepted", bool(result.get("ok", false)), String(result.get("error", "")))
	_expect("plan: applied agents", int(result.get("applied", 0)) > 0)
	var overridden := 0

	for member: Node in _members:
		if bool(member.call("has_optimizer_assignment")):
			overridden += 1

	_expect("plan: agents hold the override", overridden > 0, str(overridden))


func _test_recording_reconstruction() -> void:
	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return

	var created: Dictionary = store.call("create_demo", "experiment fixture", {
		"seed": 424242,
		"scene": "res://tests/experiment_tools_test.tscn",
		"sample_interval": 0.25,
		"status": "recording",
		"started_at": Time.get_datetime_string_from_system(false, true),
	}, "_unsaved")
	_demo_id = String(created.get("id", ""))
	_expect("recording: demo folder created", not _demo_id.is_empty(), _demo_id)

	if _demo_id.is_empty():
		return

	var dir := String(created.get("dir", ""))
	var recording := dir.path_join("recording.jsonl")
	var file := FileAccess.open(recording, FileAccess.WRITE)

	if file == null:
		_expect("recording: file opened", false)
		return

	var exits: Array = [
		{"exit_id": "A", "name": "A", "location": [2.5, 1.0, 2.5], "service_rate": 2.0},
		{"exit_id": "B", "name": "B", "location": [13.5, 1.0, 7.5], "service_rate": 1.0},
	]
	var route_a: Array = [[7.0, 0.75, 4.0], [4.0, 0.75, 3.0], [2.5, 1.0, 2.5]]
	var route_b: Array = [[7.5, 0.75, 4.0], [10.0, 0.75, 6.0], [13.5, 1.0, 7.5]]
	file.store_line(JSON.stringify({
		"type": "run", "t": 0.0, "format": "ero-sim-recording", "version": 1,
		"run_id": _demo_id, "rng_seed": 424242, "scene": "res://tests/experiment_tools_test.tscn",
		"sample_interval": 0.25, "exits": exits,
		"metadata": {
			"simulation_version": "4.7.2-test",
			"physics_ticks_per_second": 60,
			"sampling_interval": 0.25,
			"optimizer": {
				"available": true,
				"configuration": {
					"algorithm": "greedy", "mode": "balanced",
					"cohort_size": 4.0, "max_cohorts": 60, "parameters": {},
				},
			},
			"hardware_fingerprint": {"fingerprint": "test-fingerprint", "engine_version": "4.7.2-test"},
			"experiment": "test_experiment",
			"experiment_scenario": "test_scenario",
		},
	}))
	file.store_line(JSON.stringify({
		"type": "optimizer", "t": 15.0, "name": "greedy", "duration_usec": 9000,
		"detail": {
			"algorithm": "greedy", "mode": "balanced", "cohort_count": 2,
			"agent_count": 2, "assignments": {"1": "A", "2": "B"},
			"cohorts": [
				{"cohort_id": 0, "members": [1], "count": 1, "position": [7.0, 0.75, 4.0], "exit_id": "A", "route": route_a},
				{"cohort_id": 1, "members": [2], "count": 1, "position": [7.5, 0.75, 4.0], "exit_id": "B", "route": route_b},
			],
			"estimated_cost": 12.5, "estimated_completion_time": 40.0,
			"terms": {"time": 40.0, "congestion": 0.5, "queue": 0.4},
			"convergence": [{"iteration": 0, "best_cost": 13.0}, {"iteration": 1, "best_cost": 12.5}],
			"computation_time_ms": 42.0, "evaluations": 200, "total_usec": 9000,
			"applied": 2, "skipped": 0, "rejected_reason": "",
			"solver": {"seed_cost": 13.0, "timed_out": false},
		},
	}))
	file.store_line(JSON.stringify({
		"type": "route", "t": 15.0, "agent": 1, "route_id": 1, "reason": "optimizer",
		"exit_id": "A", "target": [2.5, 1.0, 2.5], "path": route_a, "path_cells": [],
		"route_length": 8.0, "remaining_length": 8.0, "route_changes": 1, "route_switches": 0,
	}))
	file.store_line(JSON.stringify({
		"type": "route", "t": 15.0, "agent": 2, "route_id": 1, "reason": "optimizer",
		"exit_id": "B", "target": [13.5, 1.0, 7.5], "path": route_b, "path_cells": [],
		"route_length": 9.0, "remaining_length": 9.0, "route_changes": 1, "route_switches": 0,
	}))
	file.store_line(JSON.stringify({
		"type": "tick", "t": 20.0,
		"sim": {"elapsed": 20.0, "active": 0, "spawned": 2, "evacuated": 2},
		"agents": [],
		"exits": [
			["A", "A", true, true, 1, 0, 0, 0, 0, 0.0, 0.0, 2.0, 0.05, 0.5, 0, 0.5, 0, 0, 0, 0],
			["B", "B", true, true, 1, 0, 0, 0, 0, 0.0, 0.0, 1.0, 0.05, 0.5, 0, 0.5, 0, 0, 0, 0],
		],
	}))
	file.store_line(JSON.stringify({
		"type": "evacuation", "t": 30.0, "agent": 1, "exit_id": "A",
		"evacuation_time": 25.0, "time_since_run_start": 30.0, "wait_time": 1.0,
		"distance": 8.0, "stuck_time": 0.0, "stuck_strikes": 0, "peak_density": 1.2,
		"peak_contact_force": 100.0, "pre_movement_wait": 2.0, "route_changes": 1,
		"route_switches": 0, "density_seconds_above_1_5": 0.0,
		"density_seconds_above_2_0": 0.0, "density_seconds_above_2_5": 0.0,
	}))
	file.store_line(JSON.stringify({
		"type": "evacuation", "t": 35.0, "agent": 2, "exit_id": "B",
		"evacuation_time": 28.0, "time_since_run_start": 35.0, "wait_time": 0.5,
		"distance": 9.0, "stuck_time": 0.0, "stuck_strikes": 0, "peak_density": 1.0,
		"peak_contact_force": 80.0, "pre_movement_wait": 1.0, "route_changes": 1,
		"route_switches": 0, "density_seconds_above_1_5": 0.0,
		"density_seconds_above_2_0": 0.0, "density_seconds_above_2_5": 0.0,
	}))
	file.store_line(JSON.stringify({
		"type": "end", "t": 40.0, "reason": "quota_complete",
		"summary": {
			"run_id": _demo_id, "started_at": "2026-01-01T00:00:00", "duration": 40.0,
			"rng_seed": 424242, "agents_spawned": 2, "agents_evacuated": 2,
			"agents_died": 0, "agents_active": 0, "all_required_evacuated": true,
			"total_evacuation_time": 35.0, "average_evacuation_time": 26.5,
			"median_evacuation_time": 26.5, "p95_evacuation_time": 28.0,
			"max_evacuation_time": 28.0, "global_max_density": 1.2,
			"global_average_density": 1.0, "peak_contact_force": 100.0,
			"contact_force_p99": 95.0, "contact_agent_seconds_above_2kn": 0.0,
			"contact_agent_seconds_above_3kn": 0.0, "density_agent_seconds_above_1_5": 0.0,
			"density_agent_seconds_above_2_0": 0.0, "density_agent_seconds_above_2_5": 0.0,
			"peak_density_time": 20.0, "route_changes_total": 2, "route_switches_total": 0,
			"coverage": {"assigned_agents": 2, "assigned_fraction": 1.0},
			"optimizer": {
				"available": true, "algorithm": "greedy", "mode": "balanced",
				"solve_count": 1, "total_solver_usec": 42000, "mean_solver_usec": 42000.0,
				"max_solver_usec": 42000, "total_pipeline_usec": 9000,
				"rejected": 0, "timed_out": 0, "evaluations": 200,
				"configuration": {"algorithm": "greedy", "mode": "balanced", "parameters": {"time_budget_ms": 2000}},
			},
			"exits": [
				{"exit_id": "A", "name": "A", "accepted": 1, "share": 0.5, "assigned_at_end": 0, "admission_rate": 0.025, "utilization": 0.5, "average_wait": 0.0, "max_wait": 0.0, "peak_queue": 0, "receiving_occupancy": 0, "rejected": 0, "capacity_waits": 0, "capacity_rejections": 0, "queue_full_rejections": 0, "service_rate": 2.0, "available": true},
				{"exit_id": "B", "name": "B", "accepted": 1, "share": 0.5, "assigned_at_end": 0, "admission_rate": 0.025, "utilization": 0.5, "average_wait": 0.0, "max_wait": 0.0, "peak_queue": 0, "receiving_occupancy": 0, "rejected": 0, "capacity_waits": 0, "capacity_rejections": 0, "queue_full_rejections": 0, "service_rate": 1.0, "available": true},
			],
		},
	}))
	file.close()

	var path := dir.path_join("manifest.json")
	var manifest_file := FileAccess.open(path, FileAccess.WRITE)

	if manifest_file != null:
		manifest_file.store_string(JSON.stringify({
			"format": "ero-sim-recording", "version": 1, "metadata": {
				"simulation_version": "4.7.2-test", "sampling_interval": 0.25,
				"physics_ticks_per_second": 60,
				"optimizer": {"available": true, "configuration": {"algorithm": "greedy"}},
				"hardware_fingerprint": {"fingerprint": "test-fingerprint", "engine_version": "4.7.2-test"},
				"experiment": "test_experiment", "experiment_scenario": "test_scenario",
			},
		}, "\t"))
		manifest_file.close()

	var summary_file := FileAccess.open(dir.path_join("summary.json"), FileAccess.WRITE)

	if summary_file != null:
		summary_file.store_string(JSON.stringify({"run_id": _demo_id, "duration": 40.0}))
		summary_file.close()

	var plan := EvacuationPlan.from_recording(recording, _demo_id)
	_expect("recording: plan reconstructed", plan != null)

	if plan != null:
		_expect("recording: assignments rebuilt", plan.assignment_count() == 2, str(plan.assignment_count()))
		_expect("recording: routes rebuilt", plan.routes_with_polylines() == 2, str(plan.routes_with_polylines()))
		_expect("recording: algorithm read", plan.algorithm == "greedy", plan.algorithm)


func _test_export() -> void:
	_expect("export: demo available", not _demo_id.is_empty())

	if _demo_id.is_empty():
		return

	var result: Dictionary = ExperimentExporter.export_demo(_demo_id, "user://exports_test", "_unsaved")
	print("  export result: ", result)
	_expect("export: succeeded", bool(result.get("ok", false)), str(result.get("errors", result.get("error", ""))))
	_expect("export: one run row", int(result.get("runs", 0)) == 1)
	_expect("export: two agent rows", int(result.get("agents", 0)) == 2, str(result.get("agents", 0)))
	_expect("export: two exit rows", int(result.get("exits", 0)) == 2, str(result.get("exits", 0)))
	_expect("export: one solve row", int(result.get("solves", 0)) == 1, str(result.get("solves", 0)))
	_expect("export: convergence rows", int(result.get("convergence", 0)) == 2)
	_expect("export: route rows", int(result.get("routes", 0)) == 2, str(result.get("routes", 0)))

	var dir := String(result.get("output_dir", ""))
	var plan_dir := dir.path_join("plans")
	var plan_files: PackedStringArray = []

	if DirAccess.dir_exists_absolute(plan_dir):
		plan_files = DirAccess.open(plan_dir).get_files()

	_expect("export: reusable plan written", not plan_files.is_empty(), str(plan_files.size()))

	for file_name: String in ["runs.csv", "agents.csv", "exits.csv", "solves.csv", "convergence.csv", "routes.csv", "data_dictionary.md"]:
		_expect("export: %s exists" % file_name, FileAccess.file_exists(dir.path_join(file_name)))

	var runs := FileAccess.open(dir.path_join("runs.csv"), FileAccess.READ)

	if runs != null:
		var header := runs.get_line()
		_expect("export: runs header", header.contains("solver_total_usec"))
		var row := runs.get_line()
		_expect("export: runs row has condition", row.contains("greedy"))
		runs.close()

	await get_tree().process_frame


func _test_fixture() -> void:
	var result: Dictionary = ExperimentFixture.build_preset("s1")
	_expect("fixture: built", bool(result.get("ok", false)), str(result.get("error", "")))
	_expect("fixture: four exits", int(result.get("exits", 0)) == 4, str(result.get("exits", 0)))
	_expect("fixture: floor cells", int(result.get("cells", 0)) == 600, str(result.get("cells", 0)))
	await get_tree().process_frame

	var live := 0
	for node: Node in get_tree().get_nodes_in_group("EvacPoint"):
		if node.has_method("get_exit_status"):
			live += 1

	_expect("fixture: exits registered", live >= 4, str(live))
	ExperimentFixture.build_preset("clear")
	await get_tree().process_frame


func _test_authored_route() -> void:
	var cells: Array = _grid.get_used_block_cells()

	if cells.size() < 4:
		_expect("authored route: grid has cells", false)
		return

	var added: int = RoutePainter.paint_between(cells[0], cells[cells.size() - 1])
	_expect("authored route: painted cells", added > 0, str(added))
	var plan := RoutePainter.capture_authored_plan("test authored route")
	_expect("authored route: plan captured", plan != null and plan.authored_cell_count() > 0)

	if plan == null:
		return

	var plan_id := PlanStore.save_plan(plan, "test_authored_route")
	_expect("authored route: plan saved", not plan_id.is_empty())
	var result: Dictionary = _bridge.apply_plan(plan)
	_expect("authored route: plan applies corridor", bool(result.get("ok", false)), String(result.get("error", "")))
	_expect("authored route: cells applied", int(result.get("authored_cells", 0)) > 0)
	RoutePainter.clear_all()

	if not plan_id.is_empty():
		PlanStore.delete_plan(plan_id)

	await get_tree().process_frame


func _cleanup() -> void:
	if not _plan_id.is_empty():
		PlanStore.delete_plan(_plan_id)

	if not _demo_id.is_empty():
		var store := get_node_or_null("/root/DemoStore")

		if store != null:
			store.call("delete_demo", _demo_id)

	var export_dir := "user://exports_test"

	if DirAccess.dir_exists_absolute(export_dir):
		_remove_dir(export_dir)


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)

	if dir == null:
		return

	dir.list_dir_begin()
	var name := dir.get_next()

	while not name.is_empty():
		var child := path.path_join(name)

		if dir.current_is_dir():
			_remove_dir(child)
		else:
			DirAccess.remove_absolute(child)

		name = dir.get_next()

	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _plan_ids(plans: Array) -> Array:
	var result: Array = []

	for plan: Dictionary in plans:
		result.append(String(plan.get("id", "")))

	return result


func _add_exit(exit_id: String, position: Vector3, rate: float) -> void:
	var exit_instance: Node3D = EVAC_SCENE.instantiate()
	var area := exit_instance.get_node("Area3D") as Area3D
	area.set("exit_id", exit_id)
	area.set("exit_service_rate", rate)
	area.set("track_evacuation", true)
	area.set("retain_evacuated", false)
	exit_instance.position = position
	_world.add_child(exit_instance)


func _add_member(position: Vector3) -> void:
	var member: Node3D = MEMBER_SCENE.instantiate()
	member.name = "agent_%d" % _members.size()
	member.position = position
	member.set("pre_movement_enabled", false)
	member.set("realistic_sprites_mode", false)
	_world.add_child(member)
	_members.append(member)


func _make_library() -> MeshLibrary:
	var library := MeshLibrary.new()
	var box := BoxMesh.new()
	var shape := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.size = Vector3.ONE
	library.create_item(0)
	library.set_item_name(0, "TestCube")
	library.set_item_mesh(0, box)
	library.set_item_shapes(0, [shape, Transform3D.IDENTITY])
	return library


func _request_and_wait() -> bool:
	var target: int = _bridge.solve_count + 1
	_bridge.request_solve()

	for _frame: int in range(600):
		if _bridge.solve_count >= target:
			return true

		await get_tree().process_frame

	return false


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + label)
		return

	_failures += 1
	print("  FAIL  " + label + ("" if detail.is_empty() else "  [" + detail + "]"))
