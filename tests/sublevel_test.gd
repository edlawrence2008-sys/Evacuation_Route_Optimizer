extends SceneTree

## Moving sub-levels: creation, editable cells, welding, world docking and
## collision against the world's trimesh floors.
##
##   godot --headless --path . --script res://tests/sublevel_test.gd

const GRID = preload("res://scripts/gridmap.gd")
const MANAGER = preload("res://scripts/world/sub_level_manager.gd")
const ANCHOR := 0
const CONCRETE := 1

var _checks: int = 0
var _failures: int = 0
var _grid: NavGridMap
var _manager: Node
var _host: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== sub-levels ===")
	await _test_spawn_and_edit()
	await _test_weld()
	await _test_dock()
	await _test_collision()
	await _test_serialize_restore()
	await _test_placeable_ownership()
	await _test_edge_hit_resolution()
	_test_agent_layer()
	_finish()


func _test_spawn_and_edit() -> void:
	_begin()

	var sublevel = _manager.spawn(
		[Vector3i(0, 4, 0), Vector3i(1, 4, 0)],
		{Vector3i(0, 4, 0): CONCRETE, Vector3i(1, 4, 0): CONCRETE},
		{Vector3i(0, 4, 0): 0, Vector3i(1, 4, 0): 0}
	)

	_expect("spawn returns a sub-level", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	_expect("spawn keeps both cells", sublevel.cells.size() == 2)
	_expect("sub-level has a mesh", _mesh_of(sublevel) != null)
	_expect(
		"sub-level has collision shapes",
		_collision_count(sublevel) > 0
	)
	_expect(
		"sub-level is on the player-visible layer",
		sublevel.collision_layer == 16 and sublevel.collision_mask == 17
	)

	_expect("add cell", sublevel.add_cell(Vector3i(2, 0, 0), CONCRETE))
	_expect("add cell grows the grid", sublevel.cells.size() == 3)
	_expect("remove cell", sublevel.remove_cell(Vector3i(2, 0, 0)))
	_expect("remove cell shrinks the grid", sublevel.cells.size() == 2)

	_free_all()


func _test_weld() -> void:
	_begin()

	var first = _manager.spawn(
		[Vector3i(0, 4, 0), Vector3i(1, 4, 0)],
		{Vector3i(0, 4, 0): CONCRETE, Vector3i(1, 4, 0): CONCRETE},
		{Vector3i(0, 4, 0): 0, Vector3i(1, 4, 0): 0}
	)
	var second = _manager.spawn(
		[Vector3i(2, 4, 0)],
		{Vector3i(2, 4, 0): CONCRETE},
		{Vector3i(2, 4, 0): 0}
	)

	_expect("weld: both sub-levels exist", first != null and second != null)
	if first == null or second == null:
		_free_all()
		return

	var added: int = first.merge_guest(second)
	_expect("weld: one cell added", added == 1, str(added))
	_expect("weld: host now holds three cells", first.cells.size() == 3)
	_expect("weld: host is still one editable body", _collision_count(first) > 0)

	_free_all()


func _test_dock() -> void:
	_begin()

	# World anchor directly under the sub-level cell.
	_place(Vector3i(0, 0, 0), ANCHOR)

	var sublevel = _manager.spawn(
		[Vector3i(0, 1, 0)],
		{Vector3i(0, 1, 0): CONCRETE},
		{Vector3i(0, 1, 0): 0}
	)
	_expect("dock: sub-level spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	_expect("dock: dock_now returns true", _manager.dock_now(sublevel))
	_expect(
		"dock: cell becomes a world block",
		_grid.get_block_item(Vector3i(0, 1, 0)) == CONCRETE
	)
	_expect("dock: manager drops the body", _manager.active_count() == 0)

	_free_all()


func _test_collision() -> void:
	_begin()

	# Trimesh floor, matching the world's chunk collision.
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 1
	var floor_shape := CollisionShape3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(20.0, 1.0, 20.0)
	floor_shape.shape = floor_mesh.create_trimesh_shape()
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	root.add_child(floor_body)

	var sublevel = _manager.spawn(
		[Vector3i(0, 6, 0)],
		{Vector3i(0, 6, 0): CONCRETE},
		{Vector3i(0, 6, 0): 0}
	)
	_expect("collision: sub-level spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 4000:
		await process_frame
		if sublevel.global_position.y < -5.0:
			break

	_expect(
		"collision: sub-level rests on the trimesh world",
		sublevel.global_position.y > 0.2,
		"y=%.3f" % sublevel.global_position.y
	)

	floor_body.free()
	_free_all()


func _test_serialize_restore() -> void:
	_begin()

	var sublevel = _manager.spawn(
		[
			Vector3i(0, 4, 0),
			Vector3i(1, 4, 0),
			Vector3i(1, 5, 0),
		],
		{
			Vector3i(0, 4, 0): CONCRETE,
			Vector3i(1, 4, 0): CONCRETE,
			Vector3i(1, 5, 0): CONCRETE,
		},
		{
			Vector3i(0, 4, 0): 0,
			Vector3i(1, 4, 0): 2,
			Vector3i(1, 5, 0): 3,
		}
	)
	_expect("save: sub-level spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	sublevel.global_position = Vector3(4.0, 5.0, 6.0)
	sublevel.freeze = true
	var saved: Array = _manager.serialize_all()
	_expect("save: one body serialized", saved.size() == 1, str(saved.size()))

	_manager.clear_all()
	await process_frame
	await process_frame

	var restored_count: int = _manager.restore_all(saved)
	_expect("save: one body restored", restored_count == 1, str(restored_count))
	if _manager.sublevels.is_empty():
		_free_all()
		return

	var restored = _manager.sublevels[0]
	_expect("save: cells survive", restored.cells.size() == 3)
	_expect(
		"save: transform survives",
		restored.global_position.distance_to(Vector3(4.0, 5.0, 6.0)) < 0.01,
		str(restored.global_position)
	)
	_expect("save: freeze survives", restored.freeze)
	var has_oriented_cell := false
	for cell: Vector3i in restored.cells:
		if int(restored.cells[cell]["orientation"]) == 2:
			has_oriented_cell = true
			break
	_expect("save: orientation survives", has_oriented_cell)
	_expect("save: mesh rebuilt", _mesh_of(restored) != null)
	_expect("save: collision rebuilt", _collision_count(restored) > 0)

	_free_all()


func _test_placeable_ownership() -> void:
	_begin()

	var first = _manager.spawn(
		[Vector3i(0, 4, 0), Vector3i(1, 4, 0)],
		{Vector3i(0, 4, 0): CONCRETE, Vector3i(1, 4, 0): CONCRETE},
		{Vector3i(0, 4, 0): 0, Vector3i(1, 4, 0): 0}
	)
	var second = _manager.spawn(
		[Vector3i(2, 4, 0)],
		{Vector3i(2, 4, 0): CONCRETE},
		{Vector3i(2, 4, 0): 0}
	)
	_expect("ownership: bodies spawned", first != null and second != null)
	if first == null or second == null:
		_free_all()
		return

	var guest_placeable := _make_placeable(second)
	first.merge_guest(second)
	_expect(
		"ownership: welded furniture follows the host",
		guest_placeable.get_parent() == first
	)

	# Docking must leave furniture in the world instead of freeing it with the
	# temporary body.
	_place(Vector3i(0, 0, 0), ANCHOR)
	var docked = _manager.spawn(
		[Vector3i(0, 1, 0)],
		{Vector3i(0, 1, 0): CONCRETE},
		{Vector3i(0, 1, 0): 0}
	)
	_expect("ownership: dock body spawned", docked != null)
	if docked != null:
		var dock_placeable := _make_placeable(docked)
		_manager.dock_now(docked)
		_expect(
			"ownership: docked furniture survives in the world",
			is_instance_valid(dock_placeable)
			and dock_placeable.get_parent() == _host
		)

	_free_all()


func _test_edge_hit_resolution() -> void:
	_begin()

	var sublevel = _manager.spawn(
		[Vector3i(0, 4, 0)],
		{Vector3i(0, 4, 0): CONCRETE},
		{Vector3i(0, 4, 0): 0}
	)
	_expect("edge hit: sub-level spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	# Exactly on the top/right/back corner, plain rounding would choose the
	# empty neighbour (1, 1, 1). The nearest-cell lookup must stay on the body.
	var edge: Vector3 = sublevel.global_position + Vector3(0.5, 0.5, 0.5)
	var nearest: Vector3i = sublevel.nearest_cell_to_world(edge)
	_expect(
		"edge hit resolves to an occupied cell",
		sublevel.cells.has(nearest),
		str(nearest)
	)

	_free_all()


func _test_agent_layer() -> void:
	var member_script = load("res://scripts/NPCstuff/Member.gd")
	if member_script == null:
		_expect("agent script loads", false)
		return
	var constants: Dictionary = member_script.get_script_constant_map()
	_expect(
		"agents target the sub-level collision layer",
		int(constants.get("SUBLEVEL_LAYER", 0)) == 16
	)


func _make_placeable(parent: Node) -> Node3D:
	var node := Node3D.new()
	node.name = "TestPlaceable"
	node.add_to_group("placeables")
	parent.add_child(node)
	return node


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

func _begin() -> void:
	_free_all()

	_grid = GRID.new()
	_grid.name = "SubLevelTestGrid"
	_grid.sync_settings_on_ready = false
	_grid.mesh_library = _library()
	_grid.cell_size = Vector3.ONE
	_grid.enable_greedy_meshing = false
	_grid.enable_flow_fields = false
	_grid.auto_generate_stairs = false
	_grid.wall_force_enabled = false
	root.add_child(_grid)

	_host = Node3D.new()
	_host.name = "SubLevelHost"
	root.add_child(_host)

	_manager = MANAGER.new()
	_manager.name = "SubLevelManager"
	root.add_child(_manager)
	_manager.setup(_grid, _host)


func _place(cell: Vector3i, item: int) -> void:
	_grid.place_block(cell, item, 0)


func _mesh_of(sublevel) -> Mesh:
	for child in sublevel.get_children():
		if child is MeshInstance3D:
			return child.mesh
	return null


func _collision_count(sublevel) -> int:
	var count := 0
	for child in sublevel.get_children():
		if child is CollisionShape3D:
			count += 1
	return count


func _library() -> MeshLibrary:
	var library := MeshLibrary.new()
	var box := BoxMesh.new()
	var shape := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.size = Vector3.ONE

	var names := {ANCHOR: "Auto_bedrock", CONCRETE: "Auto_concrete_test"}
	for item: int in names:
		library.create_item(item)
		library.set_item_name(item, String(names[item]))
		library.set_item_mesh(item, box)
		library.set_item_shapes(item, [shape, Transform3D.IDENTITY])

	return library


func _free_all() -> void:
	if _manager != null and is_instance_valid(_manager):
		_manager.clear_all()
		_manager.queue_free()
		_manager = null

	if _grid != null and is_instance_valid(_grid):
		_grid.free()
		_grid = null

	if _host != null and is_instance_valid(_host):
		_host.queue_free()
		_host = null


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("FAIL: %s" % label)
	else:
		print("FAIL: %s (%s)" % [label, detail])


func _finish() -> void:
	print("checks=%d failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== PASS ===")
	quit(1 if _failures > 0 else 0)
