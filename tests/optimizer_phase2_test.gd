extends Node

## Phase-2 integration test. Builds a real NavGridMap, two EvacPoints and real
## Member instances, then drives the OptimizerBridge end to end:
## snapshot -> solve -> validate -> apply -> agent override.
##
## Run with:
##   godot --headless --path . --script res://tests/optimizer_phase2_test.gd
##
## Autoloads (GlobalData, CrowdManager, EvacuationManager, SimRecorder) are
## present in --script mode, so the agents use their production lifecycle.

const MEMBER_SCENE := preload("res://scenes/npcs/Member.tscn")
const EVAC_SCENE := preload("res://scenes/placeables/sim/sim_evac_point.tscn")

const AGENT_COUNT: int = 24
const FLOOR_WIDTH: int = 20
const FLOOR_DEPTH: int = 10

var _checks: int = 0
var _failures: int = 0

var _world: Node3D
var _grid: NavGridMap
var _bridge: OptimizerBridge
var _exits: Array = []
var _members: Array = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== optimizer phase 2 ===")

	await get_tree().process_frame
	_build_world()
	await get_tree().process_frame

	_test_recorder_configuration()
	await _test_bridge_apply()
	await _test_spawn_adoption()
	await _test_unavailable_exit()
	await _test_pre_movement_assignment()
	await _test_environment_version()
	await _test_recorded_run()
	await _test_inventory_panel()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------------------
# Scenario
# ---------------------------------------------------------------------------

func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "OptimizerPhase2"
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

	var floor_cells: Array[Vector3i] = []

	for x: int in range(FLOOR_WIDTH):
		for z: int in range(FLOOR_DEPTH):
			floor_cells.append(Vector3i(x, 0, z))

	_grid.place_blocks(floor_cells, 0)

	_add_exit("A", Vector3(2.5, 1.0, 2.5), 2.0)
	_add_exit("B", Vector3(17.5, 1.0, 7.5), 1.0)

	GlobalData.evacuation_mode = true

	for index: int in range(AGENT_COUNT):
		var position := Vector3(
			8.0 + float(index % 4) * 0.7,
			0.75,
			4.0 + float(index / 4) * 0.7
		)
		_add_member(position, false, "agent")


func _add_exit(exit_id: String, position: Vector3, rate: float) -> void:
	var exit_instance: Node3D = EVAC_SCENE.instantiate()
	var area := exit_instance.get_node("Area3D") as Area3D
	area.set("exit_id", exit_id)
	area.set("exit_service_rate", rate)
	area.set("track_evacuation", true)
	area.set("retain_evacuated", false)
	exit_instance.position = position
	_world.add_child(exit_instance)
	_exits.append(area)


func _add_member(position: Vector3, pre_movement: bool, label: String) -> Node3D:
	var member: Node3D = MEMBER_SCENE.instantiate()
	member.name = "%s_%d" % [label, _members.size()]
	member.position = position
	member.set("pre_movement_enabled", pre_movement)
	member.set("pre_movement_mean", 30.0)
	member.set("realistic_sprites_mode", false)
	_world.add_child(member)
	_members.append(member)
	return member


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


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func _test_recorder_configuration() -> void:
	SimRecorder.set_optimizer_configuration({
		"available": true,
		"algorithm": "greedy",
		"mode": "balanced",
		"weights": {"time": 1.0, "congestion": 0.4, "queue": 0.3},
		"parameters": {},
		"cohort_size": 4.0,
		"max_cohorts": 60,
	})
	var stored: Dictionary = SimRecorder.get_optimizer_configuration()

	_expect("recorder: configuration stored", bool(stored.get("available", false)))
	_expect(
		"recorder: algorithm kept",
		String(stored.get("algorithm", "")) == "greedy",
		str(stored.get("algorithm", ""))
	)


func _test_bridge_apply() -> void:
	_bridge = OptimizerBridge.new()
	_bridge.name = "OptimizerBridge"
	_world.add_child(_bridge)
	_bridge.set_algorithm(OptimizationRequest.ALGORITHM_GREEDY)
	_bridge.set_mode(OptimizationRequest.MODE_BALANCED)
	_bridge.set_cohort_size(3.0)
	_bridge.set_auto_solve(false)
	_bridge.set_enabled(true)
	await get_tree().process_frame

	_expect("bridge: GlobalData mode set", GlobalData.optimizer_enabled)

	var solved: bool = await _request_and_wait()
	_expect("bridge: first solve completed", solved, str(_bridge.solve_count))

	var result: OptimizationResult = _bridge.last_result
	_expect("bridge: result exists", result != null)

	if result == null:
		return

	_expect("bridge: feasible", result.feasible, result.get_violation_summary())
	_expect(
		"bridge: assigned most agents",
		result.agent_exit_assignments.size() >= AGENT_COUNT - 2,
		str(result.agent_exit_assignments.size())
	)
	_expect("bridge: applied some", _bridge.last_applied > 0, str(_bridge.last_applied))
	_expect(
		"bridge: applied + skipped covers the assignment",
		_bridge.last_applied + _bridge.last_skipped
		== result.agent_exit_assignments.size(),
		"%d + %d != %d" % [
			_bridge.last_applied,
			_bridge.last_skipped,
			result.agent_exit_assignments.size(),
		]
	)
	_expect(
		"bridge: cohorts are bounded",
		result.cohorts.size() <= 60,
		str(result.cohorts.size())
	)

	# Paths are queued; wait long enough for the override routes to resolve.
	for _frame: int in range(30):
		await get_tree().process_frame

	var overridden: int = 0
	var routed: int = 0

	for member_value: Variant in _members:
		var member := member_value as Node3D

		if not is_instance_valid(member) or not member.has_method("has_optimizer_assignment"):
			continue

		if not bool(member.call("has_optimizer_assignment")):
			continue

		overridden += 1
		var exit_id: String = String(member.call("get_optimizer_exit_id"))

		if exit_id != "A" and exit_id != "B":
			continue

		var destination: String = String(member.get("destination_exit_id"))

		if destination == exit_id and String(member.get("last_route_reason")) == "optimizer":
			routed += 1

	_expect("bridge: agents hold an override", overridden > 0, str(overridden))
	_expect("bridge: override routes are labelled", routed > 0, str(routed))


func _test_spawn_adoption() -> void:
	if _bridge == null or _bridge.last_result == null:
		return

	var member := _add_member(Vector3(8.5, 0.75, 5.5), false, "late")
	GlobalData.register_npc_spawned(member)

	for _frame: int in range(10):
		await get_tree().process_frame

	_expect(
		"spawn adoption: late agent assigned from the last result",
		bool(member.call("has_optimizer_assignment")),
		String(member.call("get_optimizer_exit_id"))
	)
	_expect(
		"spawn adoption: exit is one of the active exits",
		String(member.call("get_optimizer_exit_id")) in ["A", "B"],
		String(member.call("get_optimizer_exit_id"))
	)


func _test_unavailable_exit() -> void:
	if _exits.size() < 2 or _bridge == null:
		return

	var area := _exits[1] as Node
	area.call("set_operational", false)
	await get_tree().process_frame

	var first: OptimizationResult = _bridge.last_result
	var solved: bool = await _request_and_wait()
	_expect("unavailable: second solve completed", solved, str(_bridge.solve_count))

	var result: OptimizationResult = _bridge.last_result
	_expect("unavailable: new result", result != null and result != first)

	if result == null:
		return

	_expect("unavailable: feasible with exit A", result.feasible, result.get_violation_summary())
	_expect(
		"unavailable: exit B never assigned",
		not result.exit_counts.has("B"),
		str(result.exit_counts)
	)
	_expect(
		"unavailable: exit A receives agents",
		int(result.exit_counts.get("A", 0)) > 0,
		str(result.exit_counts)
	)


func _test_pre_movement_assignment() -> void:
	if _exits.is_empty():
		return

	var target := (_exits[0] as Node3D).global_position
	var member := _add_member(Vector3(5.5, 0.75, 2.5), true, "pre")
	await get_tree().process_frame

	var accepted: bool = bool(
		member.call("set_optimizer_assignment", "A", target)
	)
	await get_tree().process_frame

	var state: Dictionary = member.call("get_measurement_state")

	_expect("pre-movement: assignment accepted", accepted)
	_expect("pre-movement: override stored", bool(member.call("has_optimizer_assignment")))
	_expect(
		"pre-movement: still waiting",
		String(state.get("status", "")) == "pre_movement",
		str(state.get("status", ""))
	)
	_expect("pre-movement: no target yet", not bool(member.get("has_evacuation_target")))

	member.set("wait_timer", 0.0)
	member.call("choose_next_action")
	await get_tree().process_frame

	_expect(
		"pre-movement: target applied after delay",
		bool(member.get("has_evacuation_target"))
	)
	_expect(
		"pre-movement: keeps the assigned exit",
		String(member.call("get_optimizer_exit_id")) == "A"
	)


func _test_environment_version() -> void:
	if _grid == null:
		return

	var before: int = GlobalData.environment_version
	_grid.place_block(Vector3i(1, 1, 8), 0)
	await get_tree().process_frame

	_expect(
		"environment: block edit bumps the version",
		GlobalData.environment_version > before,
		"%d -> %d" % [before, GlobalData.environment_version]
	)


## Acceptance run: start a recorded run with the optimizer enabled, wait for the
## auto-solve and at least one admission, stop, then inspect the demo files.
func _test_recorded_run() -> void:
	if _bridge == null:
		return

	_bridge.set_auto_solve(true)
	var solves_before: int = _bridge.solve_count

	GlobalData.start_spawning()
	await get_tree().process_frame

	_expect("recording: started", SimRecorder.is_recording())

	var deadline: float = GlobalData.sim_now() + 15.0
	var solved: bool = false
	var evacuated: bool = false

	while GlobalData.sim_now() < deadline:
		if _bridge.solve_count > solves_before:
			solved = true

		if GlobalData.npcs_evacuated > 0:
			evacuated = true

		if solved and evacuated:
			break

		await get_tree().process_frame

	_expect("recording: auto-solve ran", solved, str(_bridge.solve_count))
	_expect(
		"recording: at least one admission",
		evacuated,
		str(GlobalData.npcs_evacuated)
	)

	GlobalData.stop_spawning()
	await get_tree().process_frame

	var summary: Dictionary = SimRecorder.get_last_summary()
	var optimizer: Dictionary = summary.get("optimizer", {})
	var run_dir: String = SimRecorder.get_run_dir()

	_expect(
		"recording: summary optimizer available",
		bool(optimizer.get("available", false)),
		str(optimizer)
	)
	_expect(
		"recording: optimizer executions recorded",
		int(optimizer.get("executions", 0)) >= 1,
		str(optimizer.get("executions", 0))
	)
	_expect(
		"recording: optimizer time recorded",
		int(optimizer.get("execution_usec", 0)) > 0,
		str(optimizer.get("execution_usec", 0))
	)
	_expect(
		"recording: measured admissions in summary",
		int(summary.get("agents_evacuated", 0)) > 0,
		str(summary.get("agents_evacuated", 0))
	)

	if run_dir.is_empty():
		_expect("recording: run directory exists", false, "empty")
		return

	var manifest: Dictionary = _read_json(run_dir.path_join("manifest.json"))
	var manifest_metadata: Dictionary = manifest.get("metadata", {})
	var manifest_optimizer: Dictionary = manifest_metadata.get("optimizer", {})
	var manifest_config: Dictionary = manifest_optimizer.get("configuration", {})
	var capabilities: Dictionary = manifest.get("capabilities", {})

	_expect(
		"manifest: optimizer available",
		bool(manifest_optimizer.get("available", false)),
		str(manifest_optimizer)
	)
	_expect(
		"manifest: optimizer algorithm",
		String(manifest_config.get("algorithm", "")) == OptimizationRequest.ALGORITHM_GREEDY,
		str(manifest_config.get("algorithm", ""))
	)
	_expect(
		"manifest: optimizer capability",
		bool(capabilities.get("optimizer", false)),
		str(capabilities.get("optimizer", false))
	)

	var scan: Dictionary = _scan_recording(run_dir.path_join("recording.jsonl"))

	_expect(
		"recording: optimizer event present",
		int(scan.get("optimizer", 0)) > 0,
		str(scan.get("optimizer", 0))
	)
	_expect(
		"recording: optimizer routes labelled",
		int(scan.get("optimizer_routes", 0)) > 0,
		str(scan.get("optimizer_routes", 0))
	)
	_expect(
		"recording: estimate stored separately",
		float(scan.get("last_estimate", 0.0)) > 0.0,
		str(scan.get("last_estimate", 0.0))
	)

	DemoStore.delete_demo(run_dir.get_file())


## Loads the authored inventory and verifies that the runtime optimizer UI is
## built and wired. The panel is normally created by the HUD in the game scene.
func _test_inventory_panel() -> void:
	var scene: PackedScene = load("res://scenes/inventory/Inventory.tscn")

	_expect("ui: inventory scene loads", scene != null)

	if scene == null:
		return

	var inventory: Control = scene.instantiate()
	add_child(inventory)
	await get_tree().process_frame

	var panel: Variant = inventory.get_node_or_null("SimulationPanel")
	_expect("ui: simulation panel found", panel != null)

	if panel == null:
		inventory.queue_free()
		return

	var optimizer_panel: Variant = inventory.get_node_or_null("OptimizerPanel")
	_expect("ui: optimizer side panel found", optimizer_panel != null)

	if optimizer_panel == null:
		inventory.queue_free()
		return

	_expect(
		"ui: bridge owned by the side panel",
		optimizer_panel.get("bridge") != null
	)
	_expect("ui: title row present", panel.has_node("TitleRow"))
	_expect("ui: optimizer button present", panel.has_node("TitleRow/OptimizerButton"))
	_expect("ui: method control", optimizer_panel.get("_algorithm") != null)
	_expect("ui: objective control", optimizer_panel.get("_mode") != null)
	_expect("ui: status label", optimizer_panel.get("_status") != null)
	var description_label: Label = optimizer_panel.get("_algorithm_description")
	_expect(
		"ui: method descriptions present",
		not description_label.text.is_empty(),
		description_label.text
	)
	_expect(
		"ui: ACO is selectable",
		OptimizerPanel.ALGORITHMS.has(OptimizationRequest.ALGORITHM_ACO)
	)

	for algorithm: String in OptimizationRequest.ALGORITHMS:
		_expect(
			"ui: method %s is selectable" % algorithm,
			OptimizerPanel.ALGORITHMS.has(algorithm)
		)
		_expect(
			"ui: method %s has a description" % algorithm,
			OptimizerPanel.ALGORITHM_DESCRIPTIONS.has(algorithm)
			and not String(
				OptimizerPanel.ALGORITHM_DESCRIPTIONS[algorithm]
			).is_empty()
		)

	panel.call("_on_optimizer_button_pressed")
	await get_tree().process_frame
	_expect(
		"ui: side panel opens",
		bool(optimizer_panel.get("visible"))
	)
	optimizer_panel.call("close_panel")
	await get_tree().process_frame
	_expect(
		"ui: side panel closes",
		not bool(optimizer_panel.get("visible"))
	)

	inventory.queue_free()
	await get_tree().process_frame


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return {}

	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _scan_recording(path: String) -> Dictionary:
	var result: Dictionary = {
		"optimizer": 0,
		"optimizer_routes": 0,
		"last_estimate": 0.0,
	}

	if not FileAccess.file_exists(path):
		return result

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return result

	while not file.eof_reached():
		var line: String = file.get_line()

		if line.strip_edges().is_empty():
			continue

		var parsed: Variant = JSON.parse_string(line)

		if not parsed is Dictionary:
			continue

		var record: Dictionary = parsed
		var record_type: String = String(record.get("type", ""))

		if record_type == "optimizer":
			result["optimizer"] = int(result["optimizer"]) + 1
			var detail: Dictionary = record.get("detail", {})
			result["last_estimate"] = float(
				detail.get("estimated_completion_time", 0.0)
			)
		elif (
			record_type == "route"
			and String(record.get("reason", "")) == "optimizer"
		):
			result["optimizer_routes"] = int(result["optimizer_routes"]) + 1

	file.close()
	return result


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
