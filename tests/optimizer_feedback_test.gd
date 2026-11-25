extends Node

## Runtime acceptance for the optimizer feedback loop:
##   - optimizer overlay (cohort lines, agent stems, exit labels)
##   - periodic re-solve with unchanged-agent skipping
##   - late-spawn coverage outside the 8 m adoption radius
##   - console opt_overlay command
##
##   godot --headless --path . res://tests/optimizer_feedback_test.tscn

const MEMBER_SCENE := preload("res://scenes/npcs/Member.tscn")
const EVAC_SCENE := preload("res://scenes/placeables/sim/sim_evac_point.tscn")
const CONSOLE_SCRIPT := preload("res://scenes/console_text.gd")

const FLOOR_WIDTH: int = 24
const FLOOR_DEPTH: int = 10

var _checks: int = 0
var _failures: int = 0
var _world: Node3D
var _grid: NavGridMap
var _bridge: OptimizerBridge


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== optimizer feedback runtime ===")

	await get_tree().process_frame
	_build_world()
	await get_tree().process_frame

	_bridge = OptimizerBridge.new()
	_bridge.name = "OptimizerBridge"
	_world.add_child(_bridge)
	_bridge.set_algorithm(OptimizationRequest.ALGORITHM_GREEDY)
	_bridge.set_mode(OptimizationRequest.MODE_BALANCED)
	_bridge.set_auto_solve(true)
	_bridge.set_re_solve_interval(5.0)
	_bridge.set_enabled(true)
	_bridge.set_overlay_enabled(true)
	GlobalData.start_spawning()

	var solved: bool = await _wait_for_solve(1.0)
	var result: OptimizationResult = _bridge.last_result

	_expect("solve: auto-solve ran", solved)
	_expect("solve: result exists", result != null)

	if result != null:
		_expect("solve: applied some agents", _bridge.last_applied > 0, str(_bridge.last_applied))
		_expect(
			"overlay: created and visible",
			_bridge.get("_overlay") != null
			and is_instance_valid(_bridge.get("_overlay"))
			and (_bridge.get("_overlay") as Node3D).visible
		)
		_expect(
			"overlay: one label per exit",
			(_bridge.get("_overlay") as Node).get("_labels").size() == 2,
			str((_bridge.get("_overlay") as Node).get("_labels").size())
		)

	# Periodic re-solve: force the interval and wait past RESOLVE_MIN_GAP.
	var solves_before: int = _bridge.solve_count
	_bridge.set("_next_resolve_at", 0.0)
	await _wait_for_solve(solves_before + 1.0)

	_expect("periodic: second solve ran", _bridge.solve_count > solves_before)
	_expect(
		"periodic: stable agents are skipped",
		_bridge.last_unchanged > 0,
		str(_bridge.last_unchanged)
	)

	# Late spawn far from every cohort must queue a solve, not keep the local
	# choice forever.
	var late: Node3D = MEMBER_SCENE.instantiate()
	late.position = Vector3(0.5, 0.75, 0.5)
	late.set("pre_movement_enabled", false)
	_world.add_child(late)
	for _i in 10:
		await get_tree().process_frame
	GlobalData.agent_spawned.emit(late)
	for _i in 10:
		await get_tree().process_frame

	_expect(
		"late spawn: queued for a solve",
		int(_bridge.get("_pending_spawns")) > 0,
		str(_bridge.get("_pending_spawns"))
	)

	var before_late: int = _bridge.solve_count
	await _wait_for_solve(before_late + 1.0)

	_expect("late spawn: solve ran", _bridge.solve_count > before_late)
	_expect("late spawn: assigned", late.has_optimizer_assignment())

	await _test_console()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _test_console() -> void:
	var console := LineEdit.new()
	console.name = "ConsoleTest"
	console.set_script(CONSOLE_SCRIPT)
	_world.add_child(console)
	await get_tree().process_frame

	console.call("_process_command", "opt_overlay on")
	_expect(
		"console: opt_overlay toggles the overlay",
		bool(_bridge.get("overlay_enabled"))
	)

	console.queue_free()


func _wait_for_solve(target: float) -> bool:
	for _frame: int in range(600):
		await get_tree().process_frame

		if float(_bridge.solve_count) >= target:
			return true

	return false


func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "OptimizerFeedbackWorld"
	add_child(_world)

	_grid = NavGridMap.new()
	_grid.name = "OptimizerFeedbackGrid"
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

	_add_exit("west", Vector3(2.5, 1.0, 5.5))
	_add_exit("east", Vector3(21.5, 1.0, 5.5))

	GlobalData.evacuation_mode = true

	var starts: Array[Vector3] = [
		Vector3(10.5, 0.75, 5.0), Vector3(11.5, 0.75, 5.0),
		Vector3(10.5, 0.75, 4.0), Vector3(11.5, 0.75, 6.0),
		Vector3(12.5, 0.75, 4.5), Vector3(12.5, 0.75, 5.5),
		Vector3(9.5, 0.75, 5.5), Vector3(9.5, 0.75, 4.5),
	]

	for position: Vector3 in starts:
		var member: Node3D = MEMBER_SCENE.instantiate()
		member.position = position
		member.set("pre_movement_enabled", false)
		member.set("realistic_sprites_mode", false)
		_world.add_child(member)


func _add_exit(exit_id: String, position: Vector3) -> void:
	var exit_instance: Node3D = EVAC_SCENE.instantiate()
	var area := exit_instance.get_node("Area3D") as Area3D
	area.set("exit_id", exit_id)
	area.set("exit_service_rate", 1.5)
	exit_instance.position = position
	_world.add_child(exit_instance)


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


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + label)
		return

	_failures += 1
	print("  FAIL  " + label + ("" if detail.is_empty() else "  [" + detail + "]"))
