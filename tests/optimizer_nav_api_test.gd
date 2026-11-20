extends SceneTree

## Integration test for the read-only navigation API added for the optimizer:
## NavGridMap.build_cost_field_to(), get_path_cells() and get_nav_point_count().
##
## Builds a real NavGridMap in an empty headless scene so the test exercises the
## same weights, connectivity rules and step lengths the agents use. Run with:
##
##   godot --headless --path . --script res://tests/optimizer_nav_api_test.gd

const EPSILON: float = 0.01

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	# Deferred so the SceneTree root is live when the grid is added; otherwise
	# Node3D.to_global() reports "not inside tree" in --script mode.
	_run_tests.call_deferred()


func _run_tests() -> void:
	print("=== optimizer nav api ===")

	var grid: NavGridMap = _make_grid()

	_test_room_field(grid)
	_test_path_cells(grid)
	_test_weighted_distance(grid)
	_test_cell_limit(grid)
	_test_disconnected_island(grid)
	_test_unreachable(grid)

	grid.free()
	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _test_room_field(grid: NavGridMap) -> void:
	var field: Dictionary = grid.build_cost_field_to(Vector3(9.5, 1.0, 2.5))

	_expect("field: 50 room cells", field.size() == 50, str(field.size()))
	_expect(
		"field: target costs zero",
		_is_close(float(field.get(Vector3i(9, 0, 2), -1.0)), 0.0, 0.0001),
		str(field.get(Vector3i(9, 0, 2), -1.0))
	)
	_expect(
		"field: far corner is positive",
		float(field.get(Vector3i(0, 0, 0), -1.0)) > 0.0,
		str(field.get(Vector3i(0, 0, 0), -1.0))
	)
	_expect(
		"field: all costs finite and non-negative",
		_all_non_negative(field),
		""
	)


func _test_path_cells(grid: NavGridMap) -> void:
	var path: Array = grid.get_path_cells(
		Vector3(0.5, 1.0, 0.5), Vector3(9.5, 1.0, 2.5)
	)

	_expect("path: at least 10 cells", path.size() >= 10, str(path.size()))
	_expect(
		"path: starts at the origin cell",
		not path.is_empty() and Vector3i(path[0]) == Vector3i(0, 0, 0),
		"" if path.is_empty() else str(path[0])
	)
	_expect(
		"path: ends at the target cell",
		not path.is_empty() and Vector3i(path[path.size() - 1]) == Vector3i(9, 0, 2),
		"" if path.is_empty() else str(path[path.size() - 1])
	)
	_expect("path: consecutive cells are neighbours", _cells_are_contiguous(path))


func _test_weighted_distance(grid: NavGridMap) -> void:
	# Interior cells have no wall or gap penalty, so the weighted field distance
	# must equal the A* distance and the straight-line distance.
	var field: Dictionary = grid.build_cost_field_to(Vector3(6.5, 1.0, 2.5))
	var field_distance: float = float(field.get(Vector3i(4, 0, 2), -1.0))
	var astar_distance: float = grid.estimate_path_distance(
		Vector3(4.5, 1.0, 2.5), Vector3(6.5, 1.0, 2.5)
	)

	_expect(
		"distance: field matches straight line (2 m)",
		_is_close(field_distance, 2.0, EPSILON),
		str(field_distance)
	)
	_expect(
		"distance: field matches A*",
		_is_close(field_distance, astar_distance, EPSILON),
		"%f vs %f" % [field_distance, astar_distance]
	)


func _test_cell_limit(grid: NavGridMap) -> void:
	var field: Dictionary = grid.build_cost_field_to(Vector3(9.5, 1.0, 2.5), 5)

	_expect("limit: at most five cells", field.size() <= 5, str(field.size()))
	_expect("limit: target still present", field.has(Vector3i(9, 0, 2)))


func _test_disconnected_island(grid: NavGridMap) -> void:
	var field: Dictionary = grid.build_cost_field_to(Vector3(12.5, 1.0, 0.5))
	var path: Array = grid.get_path_cells(
		Vector3(0.5, 1.0, 0.5), Vector3(12.5, 1.0, 0.5)
	)

	_expect("island: only four cells", field.size() == 4, str(field.size()))
	_expect(
		"island: room cell is absent",
		not field.has(Vector3i(0, 0, 0))
	)
	_expect("island: no path from the room", path.is_empty(), str(path.size()))


func _test_unreachable(grid: NavGridMap) -> void:
	var field: Dictionary = grid.build_cost_field_to(Vector3(100.0, 1.0, 100.0))
	var path: Array = grid.get_path_cells(
		Vector3(0.5, 1.0, 0.5), Vector3(100.0, 1.0, 100.0)
	)

	_expect("unreachable: empty field", field.is_empty(), str(field.size()))
	_expect("unreachable: empty path", path.is_empty(), str(path.size()))
	_expect("nav points: 54 registered", grid.get_nav_point_count() == 54,
		str(grid.get_nav_point_count()))


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

func _make_grid() -> NavGridMap:
	var grid := NavGridMap.new()
	grid.name = "OptimizerTestGrid"
	grid.mesh_library = _make_library()
	grid.cell_size = Vector3.ONE
	grid.enable_greedy_meshing = false
	grid.enable_flow_fields = false
	grid.auto_generate_stairs = false
	grid.wall_force_enabled = false

	root.add_child(grid)

	var room: Array[Vector3i] = []

	for x: int in range(10):
		for z: int in range(5):
			room.append(Vector3i(x, 0, z))

	grid.place_blocks(room, 0)

	var island: Array[Vector3i] = [
		Vector3i(12, 0, 0),
		Vector3i(13, 0, 0),
		Vector3i(12, 0, 1),
		Vector3i(13, 0, 1),
	]

	grid.place_blocks(island, 0)
	return grid


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
# Assertions
# ---------------------------------------------------------------------------

func _expect(name: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + name)
		return

	_failures += 1
	print("  FAIL  " + name + ("" if detail.is_empty() else "  [" + detail + "]"))


func _is_close(a: float, b: float, tolerance: float) -> bool:
	return absf(a - b) <= tolerance


func _all_non_negative(field: Dictionary) -> bool:
	for key: Vector3i in field.keys():
		var value: float = float(field[key])

		if not is_finite(value) or value < 0.0:
			return false

	return true


func _cells_are_contiguous(path: Array) -> bool:
	const OFFSETS: Array[Vector3i] = [
		Vector3i.RIGHT,
		Vector3i.LEFT,
		Vector3i.FORWARD,
		Vector3i.BACK,
		Vector3i(1, 0, 1),
		Vector3i(1, 0, -1),
		Vector3i(-1, 0, 1),
		Vector3i(-1, 0, -1),
		Vector3i(1, 1, 0),
		Vector3i(-1, 1, 0),
		Vector3i(0, 1, 1),
		Vector3i(0, -1, 1),
		Vector3i(0, 1, -1),
		Vector3i(0, -1, -1),
		Vector3i(1, -1, 0),
		Vector3i(-1, -1, 0),
	]

	for index: int in range(path.size() - 1):
		var delta: Vector3i = Vector3i(path[index + 1]) - Vector3i(path[index])

		if not OFFSETS.has(delta):
			return false

	return true
