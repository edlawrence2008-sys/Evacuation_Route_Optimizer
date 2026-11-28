extends SceneTree

## Moving sub-levels: creation, editable cells, welding, world docking and
## collision against the world's trimesh floors.
##
##   godot --headless --path . --script res://tests/sublevel_test.gd

const GRID = preload("res://scripts/gridmap.gd")
const MANAGER = preload("res://scripts/world/sub_level_manager.gd")
const FIRE_TEXTURE: Texture2D = preload("res://textures/specialblocks/fire.png")
const ASH_SETTLER = preload("res://scripts/world/ash_settler.gd")
const ANCHOR := 0
const CONCRETE := 1
const PLANK := 2
const ASH_PANEL := 3
const ASH_BLOCK := 4
const ASH_SLAB := 5
const NAV_MARKER := 6
const NAV_MARKER_LOW := 7

var _checks: int = 0
var _failures: int = 0
var _grid: NavGridMap
var _manager: Node
var _host: Node3D
var _stability_floor: StaticBody3D = null


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
	await _test_stability_and_fire()
	await _test_contact_damage()
	await _test_collision_destruction()
	await _test_staticify()
	await _test_dupe()
	await _test_nav_bake()
	await _test_world_fire()
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

	sublevel.set_cells({
		Vector3i(0, 0, 0): {"item": CONCRETE, "orientation": 0},
		Vector3i(0, 5, 0): {"item": ASH_PANEL, "orientation": 0},
	}, false)
	_expect(
		"sub-level ash settles onto the surface below",
		int((sublevel.cells.get(Vector3i(0, 1, 0), {}) as Dictionary).get(
			"item",
			-1
		)) == ASH_PANEL
		and not sublevel.cells.has(Vector3i(0, 5, 0))
	)

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


func _test_stability_and_fire() -> void:
	_begin()
	_grid.sublevel_stability_enabled = true

	var sublevel = _manager.spawn(
		[
			Vector3i(0, 0, 0),
			Vector3i(1, 0, 0),
			Vector3i(2, 0, 0),
			Vector3i(3, 0, 0),
			Vector3i(4, 1, 0),
		],
		{
			Vector3i(0, 0, 0): CONCRETE,
			Vector3i(1, 0, 0): PLANK,
			Vector3i(2, 0, 0): CONCRETE,
			Vector3i(3, 0, 0): CONCRETE,
			Vector3i(4, 1, 0): CONCRETE,
		},
		{}
	)
	_expect("sublevel stability: body spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	_expect("sublevel stability: setting copied", sublevel.stability_enabled)
	# Manager spawn defers stability until the body settles. Give it a real
	# floor and run the settle-time ground check here.
	_add_stability_floor(sublevel.cell_center_world(Vector3i(0, 0, 0)))
	await process_frame
	await process_frame
	sublevel.apply_stability_now()
	_expect(
		"sublevel stability: unsupported overhang removed",
		not sublevel.cells.has(Vector3i(2, 1, 0))
	)
	_expect(
		"sublevel stability: anchored foundation kept",
		sublevel.cells.has(Vector3i(0, 0, 0))
	)
	_expect(
		"sublevel stability: unsupported piece sheds a new body",
		_manager.sublevels.size() >= 2,
		str(_manager.sublevels.size())
	)

	sublevel.fire_enabled = true
	var plank_cell := Vector3i.ZERO
	var concrete_cell := Vector3i.ZERO
	for cell_value: Variant in sublevel.cells:
		var cell: Vector3i = cell_value
		var item: int = int((sublevel.cells[cell] as Dictionary).get("item", -1))
		if item == PLANK:
			plank_cell = cell
		elif item == CONCRETE:
			concrete_cell = cell
	var ignited: bool = sublevel.ignite_cell(plank_cell)
	_expect("sublevel fire: flammable cell ignites", ignited)
	_expect("sublevel fire: body reports burning", sublevel.is_burning())
	_expect(
		"sublevel fire: concrete surface fire ignites",
		sublevel.ignite_cell(concrete_cell)
	)
	_expect(
		"sublevel fire: visual exists",
		is_instance_valid(sublevel.get("_fire_visual"))
	)

	# Force both fuels to expire: the plank becomes an ash panel, the concrete
	# surface fire goes out and leaves its block intact.
	sublevel._fire_accum = 0.0
	sublevel._burning_cells[plank_cell] = 0.01
	sublevel._burning_cells[concrete_cell] = 0.01
	sublevel.call("_update_fire", 0.5)
	_expect(
		"sublevel fire: concrete self-extinguishes",
		not sublevel._burning_cells.has(concrete_cell)
		and sublevel.cells.has(concrete_cell)
	)
	_expect(
		"sublevel fire: consumed plank becomes an ash panel",
		sublevel.cells.has(plank_cell)
		and int((sublevel.cells[plank_cell] as Dictionary).get("item", -1))
		== ASH_PANEL
	)

	var panel_bottom := Vector3i(10, 0, 10)
	sublevel.cells[panel_bottom] = {"item": ASH_PANEL, "orientation": 0}
	sublevel.cells[panel_bottom + Vector3i.UP] = {
		"item": ASH_PANEL, "orientation": 0
	}
	ASH_SETTLER.compact_cells_column(
		sublevel.cells,
		sublevel.mesh_library,
		panel_bottom
	)
	_expect(
		"ash stacking: two panels merge into normal ash",
		int((sublevel.cells[panel_bottom] as Dictionary).get("item", -1))
		== ASH_BLOCK
		and not sublevel.cells.has(panel_bottom + Vector3i.UP)
	)

	var slab_bottom := Vector3i(12, 0, 10)
	sublevel.cells[slab_bottom] = {"item": ASH_SLAB, "orientation": 0}
	sublevel.cells[slab_bottom + Vector3i.UP] = {
		"item": ASH_SLAB, "orientation": 0
	}
	ASH_SETTLER.compact_cells_column(
		sublevel.cells,
		sublevel.mesh_library,
		slab_bottom
	)
	_expect(
		"ash stacking: two slabs merge into normal ash",
		int((sublevel.cells[slab_bottom] as Dictionary).get("item", -1))
		== ASH_BLOCK
		and not sublevel.cells.has(slab_bottom + Vector3i.UP)
	)

	_free_all()


func _test_contact_damage() -> void:
	_begin()
	_grid.sublevel_contact_damage_enabled = true
	_grid.sublevel_contact_damage_scale = 0.5

	var sublevel = _manager.spawn(
		[Vector3i(0, 4, 0)],
		{Vector3i(0, 4, 0): CONCRETE},
		{Vector3i(0, 4, 0): 0}
	)
	_expect("contact damage: body spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	_expect(
		"contact damage: setting copied",
		sublevel.contact_damage_enabled
	)

	sublevel.gravity_scale = 0.0
	sublevel.contact_damage_min_speed = 0.0
	sublevel.linear_velocity = Vector3(1.0, 0.0, 0.0)

	var target := Node3D.new()
	target.name = "ContactTarget"
	target.add_to_group("npc")
	_host.add_child(target)
	target.global_position = sublevel.global_position + Vector3.UP * 0.5
	var health := HealthComponent.new()
	health.name = "HealthComponent"
	health.max_health = 100.0
	target.add_child(health)
	await process_frame

	await create_timer(0.55).timeout
	_expect(
		"contact damage: nearby health target is damaged",
		health.current_health < 100.0,
		str(health.current_health)
	)

	target.queue_free()
	_free_all()


func _test_collision_destruction() -> void:
	_begin()
	_grid.sublevel_collision_destruction_enabled = true

	for x in 3:
		for y in 3:
			for z in 3:
				_place(Vector3i(x, 4 + y, z), CONCRETE)

	var sublevel = _manager.spawn(
		[
			Vector3i(0, 10, 0),
			Vector3i(1, 10, 0),
			Vector3i(2, 10, 0),
		],
		{
			Vector3i(0, 10, 0): CONCRETE,
			Vector3i(1, 10, 0): CONCRETE,
			Vector3i(2, 10, 0): CONCRETE,
		},
		{}
	)
	_expect("collision destruction: body spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	_expect(
		"collision destruction: setting copied",
		sublevel.collision_destruction_enabled
	)

	var world_point: Vector3 = _grid.to_global(
		_grid.map_to_local(Vector3i(1, 5, 1))
	)
	var world_removed: int = sublevel.call(
		"_carve_world_at",
		world_point,
		1.2
	)
	_expect(
		"collision destruction: world blocks removed",
		world_removed > 0 and not _grid.has_block(Vector3i(1, 5, 1)),
		str(world_removed)
	)

	# The moving body path is separate from the direct carve helper: drop the
	# body into the block field and run one destruction step. The result should
	# be a rounded crater, not the entire AABB volume.
	sublevel.global_position = _grid.to_global(
		_grid.map_to_local(Vector3i(1, 6, 1))
	)
	sublevel.linear_velocity = Vector3(0.0, -10.0, 0.0)
	sublevel.call("_update_collision_destruction", 0.25)
	var destroyed := 0
	for x in 3:
		for y in 3:
			for z in 3:
				if not _grid.has_block(Vector3i(x, 4 + y, z)):
					destroyed += 1
	_expect(
		"collision destruction: moving body carves a crater",
		destroyed > 0 and destroyed < 27,
		str(destroyed)
	)

	var before: int = sublevel.cells.size()
	var local_point: Vector3 = sublevel.cell_center_world(
		Vector3i(0, 0, 0)
	)
	var self_removed: int = sublevel.carve_at_world(local_point, 1.1)
	_expect(
		"collision destruction: sub-level cells carved",
		self_removed > 0 and sublevel.cells.size() < before,
		"%d -> %d" % [before, sublevel.cells.size()]
	)

	_free_all()


func _test_staticify() -> void:
	_begin()

	var sublevel = _manager.spawn(
		[Vector3i(2, 4, 0), Vector3i(3, 4, 0)],
		{
			Vector3i(2, 4, 0): CONCRETE,
			Vector3i(3, 4, 0): CONCRETE,
		},
		{}
	)
	_expect("static bodifier: body spawned", sublevel != null)
	if sublevel == null:
		_free_all()
		return

	var placed: int = _manager.staticify(sublevel)
	_expect("static bodifier: cells placed", placed == 2, str(placed))
	_expect(
		"static bodifier: first world cell exists",
		_grid.has_block(Vector3i(2, 4, 0))
	)
	_expect(
		"static bodifier: second world cell exists",
		_grid.has_block(Vector3i(3, 4, 0))
	)
	_expect(
		"static bodifier: rigid body removed from manager",
		not _manager.sublevels.has(sublevel)
	)
	_expect(
		"static bodifier: body not serialized as a sub-level",
		_manager.serialize_all().is_empty()
	)
	await process_frame
	_expect(
		"static bodifier: rigid body freed",
		not is_instance_valid(sublevel)
	)

	_free_all()


func _test_dupe() -> void:
	_begin()
	var source = _manager.spawn(
		[Vector3i(2, 4, 0), Vector3i(3, 4, 0)],
		{
			Vector3i(2, 4, 0): CONCRETE,
			Vector3i(3, 4, 0): CONCRETE,
		},
		{}
	)
	_expect("dupe gun: source spawned", source != null)
	if source == null:
		_free_all()
		return

	var copy = _manager.duplicate_sublevel(source, Vector3(5, 0, 0))
	_expect("dupe gun: copy created", copy != null and is_instance_valid(copy))
	if copy == null:
		_free_all()
		return
	_expect(
		"dupe gun: copy has the same cells",
		copy.cells.size() == source.cells.size()
	)
	_expect(
		"dupe gun: copy is offset",
		copy.global_position.distance_to(source.global_position + Vector3(5, 0, 0))
		< 0.01
	)
	_expect(
		"dupe gun: manager holds both bodies",
		_manager.sublevels.size() == 2
	)

	var furniture := _make_placeable(source)
	furniture.position = Vector3(0.25, 1.0, 0.0)
	var with_furniture = _manager.duplicate_sublevel(source, Vector3(2, 0, 0))
	var copied_furniture := 0
	if with_furniture != null:
		for child in with_furniture.get_children():
			if child.is_in_group("placeables"):
				copied_furniture += 1
	_expect(
		"dupe gun: placeables are copied",
		copied_furniture == 1,
		str(copied_furniture)
	)

	_free_all()


func _test_nav_bake() -> void:
	_begin()
	var body = _manager.spawn(
		[Vector3i(2, 4, 0), Vector3i(3, 4, 0)],
		{
			Vector3i(2, 4, 0): CONCRETE,
			Vector3i(3, 4, 0): CONCRETE,
		},
		{}
	)
	_expect("nav bodifier: body spawned", body != null)
	if body == null:
		_free_all()
		return

	var nav_before: int = _grid.get_nav_point_count()
	var baked: int = _manager.bake_nav(body)
	_expect("nav bodifier: markers baked", baked > 0, str(baked))
	_expect("nav bodifier: body marked baked", body.nav_baked)
	_expect("nav bodifier: body frozen", body.freeze)
	_expect(
		"nav bodifier: marker cells recorded",
		not body.nav_marker_cells.is_empty()
	)
	var marker_cell: Vector3i = body.nav_marker_cells[0]
	_expect(
		"nav bodifier: world nav marker exists",
		_grid.is_nav_marker_cell(marker_cell)
	)
	_expect(
		"nav bodifier: nav point count grew",
		_grid.get_nav_point_count() > nav_before
	)
	_expect(
		"nav bodifier: save state marks the body baked",
		bool(body.serialize_state().get("nav_baked", false))
	)
	_expect(
		"nav bodifier: body is not welded/docked while baked",
		_manager._dock_one() == false
	)

	var removed: int = _manager.unbake_nav(body)
	_expect("nav bodifier: markers removed", removed > 0, str(removed))
	_expect("nav bodifier: body unbaked", not body.nav_baked)
	_expect("nav bodifier: body unfrozen", not body.freeze)
	_expect(
		"nav bodifier: marker block cleared",
		not _grid.is_nav_marker_cell(marker_cell)
	)

	_free_all()


func _test_world_fire() -> void:
	_begin()
	_place(Vector3i(0, 3, 0), CONCRETE)
	_place(Vector3i(0, 4, 0), PLANK)
	_place(Vector3i(1, 4, 0), CONCRETE)

	var world_fire = _grid.get_node_or_null("WorldFire")
	_expect("world fire: manager exists", world_fire != null)
	if world_fire == null:
		_free_all()
		return

	var cell := Vector3i(0, 4, 0)
	var concrete_cell := Vector3i(1, 4, 0)
	_expect("world fire: flammable block ignites", world_fire.ignite_cell(cell))
	_expect("world fire: reports burning", world_fire.is_burning())
	_expect(
		"world fire: concrete surface fire ignites",
		world_fire.ignite_cell(concrete_cell)
	)
	_expect(
		"world fire: visual exists",
		is_instance_valid(world_fire.get("_visual"))
	)
	_expect(
		"world fire: frame count follows texture height",
		WorldFire.fire_frame_count()
		== maxi(1, FIRE_TEXTURE.get_height() / 16),
		str(WorldFire.fire_frame_count())
	)

	# Expire both: the plank is consumed into an ash panel, the concrete fire
	# goes out without damaging its block.
	world_fire._accum = 0.0
	world_fire.burning_cells[cell] = 0.01
	world_fire.burning_cells[concrete_cell] = 0.01
	world_fire.call("_physics_process", 0.5)
	_expect(
		"world fire: concrete self-extinguishes",
		not world_fire.burning_cells.has(concrete_cell)
		and _grid.has_block(concrete_cell)
	)
	_expect(
		"world fire: consumed block leaves an ash panel",
		_grid.get_block_item(cell) == ASH_PANEL,
		str(_grid.get_block_item(cell))
	)
	_grid.place_block(cell + Vector3i.UP, ASH_PANEL, 0)
	ASH_SETTLER.compact_world_column(_grid, cell)
	_expect(
		"world ash stacking: two panels merge into normal ash",
		_grid.get_block_item(cell) == ASH_BLOCK
		and not _grid.has_block(cell + Vector3i.UP)
	)

	_place(Vector3i(20, 4, 20), CONCRETE)
	_grid.place_block(Vector3i(20, 8, 20), ASH_PANEL, 0)
	_expect(
		"world ash settling: floating panel falls to the floor",
		_grid.get_block_item(Vector3i(20, 5, 20)) == ASH_PANEL
		and not _grid.has_block(Vector3i(20, 8, 20))
	)

	var world_point: Vector3 = _grid.to_global(_grid.map_to_local(concrete_cell))
	_expect("world fire: concrete surface fire re-ignites", world_fire.ignite_cell(concrete_cell))
	var extinguished: int = world_fire.extinguish_at_world(world_point, 2.0)
	_expect("world fire: extinguishes", extinguished > 0)
	_expect("world fire: cleared", not world_fire.is_burning())

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

	var names := {
		ANCHOR: "Auto_bedrock",
		CONCRETE: "Auto_concrete_test",
		PLANK: "Auto_planks_test",
		ASH_PANEL: "Auto_Panel_Bottom_ash",
		ASH_BLOCK: "Auto_ash",
		ASH_SLAB: "Auto_Slab_Top_ash",
		NAV_MARKER: "NavMarker",
		NAV_MARKER_LOW: "NavMarker_Slab",
	}
	for item: int in names:
		library.create_item(item)
		library.set_item_name(item, String(names[item]))
		library.set_item_mesh(item, box)
		library.set_item_shapes(item, [shape, Transform3D.IDENTITY])

	return library


func _add_stability_floor(lowest_center: Vector3) -> void:
	if _stability_floor != null and is_instance_valid(_stability_floor):
		_stability_floor.queue_free()
	var body := StaticBody3D.new()
	body.name = "StabilityTestFloor"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	body.global_position = lowest_center + Vector3.DOWN * 1.0
	_stability_floor = body


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

	if _stability_floor != null and is_instance_valid(_stability_floor):
		_stability_floor.queue_free()
		_stability_floor = null


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
