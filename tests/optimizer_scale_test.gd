extends Node

## Phase-2 scale acceptance: 600 real agents, 4 real exits, one bridge solve and
## application. This does not run a full evacuation; it proves the snapshot,
## analytic solve and assignment path hold at the project's 600-agent target.
##
##   godot --headless --path . res://tests/optimizer_scale_test.tscn

const MEMBER_SCENE := preload("res://scenes/npcs/Member.tscn")
const EVAC_SCENE := preload("res://scenes/placeables/sim/sim_evac_point.tscn")

const AGENT_COUNT: int = 600
const COLUMNS: int = 30
const ROWS: int = 20
const FLOOR_WIDTH: int = 40
const FLOOR_DEPTH: int = 20

var _checks: int = 0
var _failures: int = 0
var _world: Node3D
var _grid: NavGridMap
var _bridge: OptimizerBridge


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== optimizer scale ===")

	await get_tree().process_frame
	_build_world()
	await get_tree().process_frame

	_bridge = OptimizerBridge.new()
	_bridge.name = "OptimizerBridge"
	_world.add_child(_bridge)
	_bridge.set_algorithm(OptimizationRequest.ALGORITHM_GREEDY)
	_bridge.set_mode(OptimizationRequest.MODE_BALANCED)
	_bridge.set_cohort_size(4.0)
	_bridge.set_max_cohorts(60)
	_bridge.set_auto_solve(false)
	_bridge.set_enabled(true)
	await get_tree().process_frame

	var started: int = Time.get_ticks_usec()
	_bridge.request_solve()

	for _frame: int in range(1200):
		if _bridge.solve_count > 0:
			break

		await get_tree().process_frame

	var elapsed_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	var result: OptimizationResult = _bridge.last_result

	_expect("scale: solve completed", _bridge.solve_count > 0)
	_expect("scale: result exists", result != null)

	if result != null:
		_expect("scale: feasible", result.feasible, result.get_violation_summary())
		_expect(
			"scale: all agents considered",
			result.agent_exit_assignments.size() >= AGENT_COUNT - 5,
			str(result.agent_exit_assignments.size())
		)
		_expect(
			"scale: cohorts bounded",
			result.cohorts.size() <= 60,
			str(result.cohorts.size())
		)
		_expect(
			"scale: applied + skipped covers assignments",
			_bridge.last_applied + _bridge.last_skipped
			== result.agent_exit_assignments.size(),
			"%d + %d != %d" % [
				_bridge.last_applied,
				_bridge.last_skipped,
				result.agent_exit_assignments.size(),
			]
		)
		_expect("scale: some agents applied", _bridge.last_applied > 0)

		print(
			"scale: agents=%d cohorts=%d applied=%d skipped=%d solve=%.0f ms wall=%.0f ms cost=%.1f"
			% [
				result.agent_exit_assignments.size(),
				result.cohorts.size(),
				_bridge.last_applied,
				_bridge.last_skipped,
				result.computation_time_ms,
				elapsed_ms,
				result.estimated_cost,
			]
		)

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "OptimizerScale"
	add_child(_world)

	_grid = NavGridMap.new()
	_grid.name = "ScaleGrid"
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

	_add_exit("A", Vector3(2.5, 1.0, 2.5))
	_add_exit("B", Vector3(2.5, 1.0, 17.5))
	_add_exit("C", Vector3(37.5, 1.0, 2.5))
	_add_exit("D", Vector3(37.5, 1.0, 17.5))

	GlobalData.evacuation_mode = true

	for index: int in range(AGENT_COUNT):
		var column: int = index % COLUMNS
		var row: int = index / COLUMNS
		var position := Vector3(
			8.0 + float(column) * 0.75,
			0.75,
			4.0 + float(row) * 0.6
		)
		var member: Node3D = MEMBER_SCENE.instantiate()
		member.position = position
		member.set("pre_movement_enabled", false)
		member.set("realistic_sprites_mode", false)
		_world.add_child(member)


func _add_exit(exit_id: String, position: Vector3) -> void:
	var exit_instance: Node3D = EVAC_SCENE.instantiate()
	var area := exit_instance.get_node("Area3D") as Area3D
	area.set("exit_id", exit_id)
	area.set("exit_service_rate", 2.0)
	area.set("track_evacuation", true)
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
