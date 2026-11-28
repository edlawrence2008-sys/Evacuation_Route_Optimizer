class_name SubLevel
extends RigidBody3D

## A moving, editable block structure (the project's take on Sable sub-levels).
##
## Cells live in a local integer grid and move with the body. A sub-level can be
## built on, broken, and welded to another sub-level; it collides with the world
## and with other sub-levels through convex compound boxes. Custom Jolt
## narrowphase is not exposed to GDScript, so voxel-to-voxel contacts are the
## engine's own compound contacts; the greedy box merge keeps the shape count
## low (the practical stand-in for Teardown's contact filtering).
##
## Collision layer 5 (16) is in the player's mask (19). Agents use it through a
## kinematic ground probe and a chest-height obstacle probe, so they can stand
## on a body and cannot walk through a taller one; the nav graph they follow is
## still the world grid.

const SUBLEVEL_LAYER: int = 16
const MAX_COLLISION_SHAPES: int = 128
const STRUCTURAL_STABILITY = preload("res://scripts/world/structural_stability.gd")
const BLOCK_MATERIALS = preload("res://scripts/block_materials.gd")
const ASH_SETTLER = preload("res://scripts/world/ash_settler.gd")
const FIRE_TEXTURE: Texture2D = preload("res://textures/specialblocks/fire.png")
const SMOKE_TEXTURE: Texture2D = preload("res://textures/particles/smoke_small.png")
const ASH_TEXTURE: Texture2D = preload("res://textures/autoblocks/ash.png")
const FIRE_FRAME_SIZE: int = 16
const MIN_FLAMMABILITY: float = 0.04
const SUSTAINED_FLAMMABILITY: float = 0.15
const SURFACE_FUEL: float = 1.4
const SPREAD_CHANCE_SCALE: float = 0.65
const MAX_BURNING_CELLS: int = 64
const MAX_ASH_INSTANCES: int = 256
const ASH_PANEL_NAME: String = "Auto_Panel_Bottom_ash"
const ASH_SCAN_LIMIT: int = 32
const SMOKE_SAMPLES_PER_TICK: int = 8
const SMOKE_ANIM_INTERVAL: float = 0.1
const COLLISION_DESTRUCTION_INTERVAL: float = 0.2
const COLLISION_DESTRUCTION_MAX_CELLS: int = 48
const COLLISION_DESTRUCTION_SCAN_LIMIT: int = 4096
const COLLISION_CONTACT_SAMPLE_LIMIT: int = 96
const COLLISION_DESTRUCTION_MIN_SPEED: float = 3.0
const SELF_FRACTURE_SPEED: float = 5.0
const SELF_FRACTURE_RADIUS_SCALE: float = 0.55
const CTM_ATLAS_GRID: int = 16
const FACE_NORMALS: Array[Vector3i] = [
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
]
const NEIGHBOURS_6: Array[Vector3i] = [
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]
const SIDE_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

## Live body count. Agents use this to skip the sub-level obstacle ray entirely
## on maps that do not have any moving structures.
static var live_count: int = 0

## local cell -> {"item": int, "orientation": int}
var cells: Dictionary = {}
var mesh_library: MeshLibrary = null
var block_size: Vector3 = Vector3.ONE
## Grid used only for the shared CTM material/base helpers.
var ctm_grid: NavGridMap = null
## World cell that maps to local (0, 0, 0). Only meaningful while the body is
## still at its spawn transform; edits and merging use local cells.
var origin_cell: Vector3i = Vector3i.ZERO
## Callable(grid.get_orientation_basis) so slabs/stairs keep their facing.
var orientation_provider: Callable = Callable()
var settled_for: float = 0.0
var last_edit_at: float = 0.0
## Nav Bodifier state: frozen diagonal map piece plus the world nav markers it
## owns. Markers are invisible world cells; the body itself stays a diagonal
## static collider.
var nav_baked: bool = false
var nav_marker_cells: Array[Vector3i] = []

## Copied from the owning grid/PerformanceSettings on spawn/restore.
var stability_enabled: bool = false
var contact_damage_enabled: bool = false
var contact_damage_scale: float = 0.05
var contact_damage_min_speed: float = 1.5
var collision_destruction_enabled: bool = false
var collision_destruction_radius: float = 1.5
var fire_enabled: bool = true

var _destruction_accum: float = 0.0
## Highest speed seen since the last destruction step. Impact resolution can
## zero the current velocity before the step timer fires, so use the peak.
var _recent_speed_max: float = 0.0
## Manager callback: (removed_cells, removed_cell_data). Stability uses it to
## shed unsupported pieces as their own rigid sub-levels.
var shed_callback: Callable = Callable()
## True once the manager has run the settle-time ground check for this rest.
var stability_checked: bool = false

var _visual: MeshInstance3D = null
var _collision_shapes: Array[CollisionShape3D] = []
var _mesh: ArrayMesh = null

## Contact damage cadence and per-target cooldown.
var _contact_accum: float = 0.0
var _contact_last_msec: Dictionary = {}

## Burning local cells -> remaining fuel in seconds.
var _burning_cells: Dictionary = {}
var _fire_accum: float = 0.0
var _fire_visual: MultiMeshInstance3D = null
var _fire_multimesh: MultiMesh = null
var _fire_material: StandardMaterial3D = null
var _fire_anim_accum: float = 0.0
var _smoke_anim_accum: float = 0.0
var _fire_light: OmniLight3D = null
var _smoke_visual: MultiMeshInstance3D = null
var _smoke_multimesh: MultiMesh = null
var _smoke_count: int = 0
var _ash_visual: MultiMeshInstance3D = null
var _ash_multimesh: MultiMesh = null
var _ash_points: Array[Transform3D] = []
## item id -> flammability; avoids re-parsing material names every spread roll.
var _flammability_cache: Dictionary = {}
## item id -> anchored; avoids re-parsing names during collision-destruction scans.
var _anchored_cache: Dictionary = {}
static var _fire_frame_textures: Array[ImageTexture] = []
var _burn_fuel: float = 6.0
var _fire_damage_radius: float = 2.0
var _fire_damage_per_tick: float = 6.0
var _ash_item: int = -2


func configure(
	library: MeshLibrary,
	size: Vector3,
	origin: Vector3i,
	basis_provider: Callable
) -> void:
	mesh_library = library
	block_size = size
	origin_cell = origin
	orientation_provider = basis_provider
	collision_layer = SUBLEVEL_LAYER
	collision_mask = 1 | SUBLEVEL_LAYER
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	linear_damp = 0.05
	angular_damp = 0.1


func _enter_tree() -> void:
	live_count += 1
	add_to_group("sublevels")


func _exit_tree() -> void:
	live_count = maxi(0, live_count - 1)
	remove_from_group("sublevels")


func set_cells(data: Dictionary, apply_stability: bool = true) -> void:
	cells.clear()
	stability_checked = false

	for cell: Vector3i in data:
		var entry: Dictionary = data[cell]
		var item: int = int(entry.get("item", -1))
		if item < 0:
			continue
		cells[cell] = {
			"item": item,
			"orientation": int(entry.get("orientation", 0)),
		}

	ASH_SETTLER.settle_cells_columns(cells, mesh_library)

	if stability_enabled and apply_stability:
		_apply_local_stability()

	if cells.is_empty():
		move_placeables_to(get_parent())
		queue_free()
		return

	_rebuild()


## JSON-safe snapshot of the body, its cells and its motion state. Cell keys are
## stored as flat rows because JSON cannot key a dictionary by Vector3i.
func _serialize_nav_marker_cells() -> Array:
	var rows: Array = []
	for cell: Vector3i in nav_marker_cells:
		rows.append([cell.x, cell.y, cell.z])
	return rows


func serialize_state() -> Dictionary:
	var entries: Array = []

	for cell: Vector3i in cells:
		var entry: Dictionary = cells[cell]
		entries.append([
			cell.x,
			cell.y,
			cell.z,
			int(entry.get("item", -1)),
			int(entry.get("orientation", 0)),
		])

	var xform := global_transform
	return {
		"xform": [
			xform.basis.x.x, xform.basis.x.y, xform.basis.x.z,
			xform.basis.y.x, xform.basis.y.y, xform.basis.y.z,
			xform.basis.z.x, xform.basis.z.y, xform.basis.z.z,
			xform.origin.x, xform.origin.y, xform.origin.z,
		],
		"cells": entries,
		"linear_velocity": [
			linear_velocity.x, linear_velocity.y, linear_velocity.z
		],
		"angular_velocity": [
			angular_velocity.x, angular_velocity.y, angular_velocity.z
		],
		"gravity_scale": gravity_scale,
		"freeze": freeze,
		"lock_x": axis_lock_angular_x,
		"lock_y": axis_lock_angular_y,
		"lock_z": axis_lock_angular_z,
		"nav_baked": nav_baked,
		"nav_marker_cells": _serialize_nav_marker_cells(),
	}


## Restores a snapshot produced by `serialize_state()`. The node must already be
## under its host so `global_transform` is meaningful.
func restore_state(state: Dictionary) -> bool:
	var xform_values: Variant = state.get("xform", [])
	if xform_values is Array and (xform_values as Array).size() == 12:
		var values: Array = xform_values
		global_transform = Transform3D(
			Vector3(
				float(values[0]), float(values[1]), float(values[2])
			),
			Vector3(
				float(values[3]), float(values[4]), float(values[5])
			),
			Vector3(
				float(values[6]), float(values[7]), float(values[8])
			),
			Vector3(
				float(values[9]), float(values[10]), float(values[11])
			)
		)

	var data: Dictionary = {}
	var raw_cells: Variant = state.get("cells", [])
	if raw_cells is Array:
		for row_value: Variant in raw_cells:
			if not row_value is Array:
				continue
			var row: Array = row_value
			if row.size() < 5:
				continue
			var cell := Vector3i(
				int(row[0]), int(row[1]), int(row[2])
			)
			data[cell] = {
				"item": int(row[3]),
				"orientation": int(row[4]),
			}

	if data.is_empty():
		return false

	set_cells(data, false)

	nav_baked = bool(state.get("nav_baked", false))
	nav_marker_cells.clear()
	var marker_rows: Variant = state.get("nav_marker_cells", [])
	if marker_rows is Array:
		for row_value: Variant in marker_rows:
			if not row_value is Array:
				continue
			var row: Array = row_value
			if row.size() < 3:
				continue
			nav_marker_cells.append(
				Vector3i(int(row[0]), int(row[1]), int(row[2]))
			)

	var lv: Variant = state.get("linear_velocity", [])
	if lv is Array and (lv as Array).size() == 3:
		var values: Array = lv
		linear_velocity = Vector3(
			float(values[0]), float(values[1]), float(values[2])
		)

	var av: Variant = state.get("angular_velocity", [])
	if av is Array and (av as Array).size() == 3:
		var values: Array = av
		angular_velocity = Vector3(
			float(values[0]), float(values[1]), float(values[2])
		)

	gravity_scale = float(state.get("gravity_scale", 1.0))
	axis_lock_angular_x = bool(state.get("lock_x", false))
	axis_lock_angular_y = bool(state.get("lock_y", false))
	axis_lock_angular_z = bool(state.get("lock_z", false))
	freeze = bool(state.get("freeze", false))
	sleeping = false
	return true


## Moves every directly attached placeable to another node while preserving its
## world transform. Used before welding/docking/freeing a body so furniture
## follows the surviving body or stays in the world.
func move_placeables_to(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return

	for child in get_children():
		if not child is Node3D:
			continue
		if not child.is_in_group("placeables"):
			continue
		(child as Node3D).reparent(target, true)


func add_cell(cell: Vector3i, item: int, orientation: int = 0) -> bool:
	if cells.has(cell) or item < 0:
		return false

	cells[cell] = {"item": item, "orientation": orientation}
	last_edit_at = _now()

	if stability_enabled:
		_apply_local_stability()

	_rebuild()
	return true


func remove_cell(cell: Vector3i) -> bool:
	if not cells.erase(cell):
		return false

	last_edit_at = _now()

	if cells.is_empty():
		move_placeables_to(get_parent())
		detach_ash()
		queue_free()
		return true

	if stability_enabled:
		_apply_local_stability()

	_rebuild()
	return true


func cell_center_local(cell: Vector3i) -> Vector3:
	return Vector3(cell) * block_size


func cell_center_world(cell: Vector3i) -> Vector3:
	return to_global(cell_center_local(cell))


func local_cell_at_world(world_position: Vector3) -> Vector3i:
	var local: Vector3 = to_local(world_position) / block_size
	return Vector3i(roundi(local.x), roundi(local.y), roundi(local.z))


## Nearest occupied cell to a world point. A ray that lands exactly on a cell
## boundary rounds to the empty neighbour, so click/ghost resolution uses this
## instead of trusting `local_cell_at_world()` alone.
func nearest_cell_to_world(world_position: Vector3) -> Vector3i:
	if cells.is_empty():
		return Vector3i(2147483647, 2147483647, 2147483647)

	var local: Vector3 = to_local(world_position) / block_size
	var rounded := Vector3i(
		roundi(local.x),
		roundi(local.y),
		roundi(local.z)
	)
	if cells.has(rounded):
		return rounded

	var best: Vector3i = cells.keys()[0]
	var best_distance: float = INF

	for cell: Vector3i in cells:
		var distance: float = (Vector3(cell) - local).length_squared()
		if distance < best_distance:
			best_distance = distance
			best = cell

	return best


## Duck-typed surface used by StructuralStability, matching NavGridMap.
func get_block_item(cell: Vector3i) -> int:
	var entry: Variant = cells.get(cell, null)
	if not entry is Dictionary:
		return -1
	return int((entry as Dictionary).get("item", -1))


func get_block_orientation(cell: Vector3i) -> int:
	var entry: Variant = cells.get(cell, null)
	if not entry is Dictionary:
		return 0
	return int((entry as Dictionary).get("orientation", 0))


func has_block(cell: Vector3i) -> bool:
	return cells.has(cell)


func _physics_process(delta: float) -> void:
	if contact_damage_enabled:
		_update_contact_damage(delta)
	if collision_destruction_enabled:
		_update_collision_destruction(delta)
	if not _burning_cells.is_empty():
		_animate_fire_visual(delta)
		_update_fire(delta)


## Contact pairs are not reliable for every moving/compound body, so block
## damage is a motion-aware proximity carve. The impact point is derived from
## the world cells overlapping the body, then only cells inside a sphere around
## that point are removed. This leaves rounded craters instead of the old
## AABB-shaped holes, and high-speed impacts also fracture the moving body.
func _update_collision_destruction(delta: float) -> void:
	_recent_speed_max = maxf(_recent_speed_max, linear_velocity.length())
	_destruction_accum += delta
	if _destruction_accum < COLLISION_DESTRUCTION_INTERVAL:
		return

	var speed := _recent_speed_max
	_recent_speed_max = 0.0
	_destruction_accum = 0.0
	if speed < COLLISION_DESTRUCTION_MIN_SPEED:
		return

	var my_aabb := world_aabb().grow(0.2)
	var radius := collision_destruction_radius * clampf(
		0.85 + speed / 40.0,
		0.85,
		1.4
	)
	var contact: Variant = _world_contact_point(my_aabb)

	if contact != null:
		_carve_world_at(contact, radius)
		if speed >= SELF_FRACTURE_SPEED:
			_fracture_self_near(contact, radius * SELF_FRACTURE_RADIUS_SCALE)

	for node in get_tree().get_nodes_in_group("sublevels"):
		if node == self or not node is SubLevel or not is_instance_valid(node):
			continue
		var other := node as SubLevel
		var other_aabb := other.world_aabb()
		if not my_aabb.intersects(other_aabb):
			continue
		var point := my_aabb.intersection(other_aabb).get_center()
		other.carve_at_world(point, radius)
		if speed >= SELF_FRACTURE_SPEED:
			_fracture_self_near(point, radius * SELF_FRACTURE_RADIUS_SCALE)


## Carve the moving body at its cell nearest the impact. Using the nearest cell
## (rather than the world contact point) guarantees the fracture reaches the
## body even when the contact is half a block below/outside it.
func _fracture_self_near(world_point: Vector3, radius: float) -> void:
	if cells.size() <= 1:
		return
	var cell := nearest_cell_to_world(world_point)
	if not cells.has(cell):
		return
	carve_at_world(cell_center_world(cell), radius)


## Centroid of the world blocks overlapping the body. Used as the impact point
## for a spherical crater; returns null when no world block is overlapped.
func _world_contact_point(my_aabb: AABB) -> Variant:
	var tree := get_tree()
	if tree == null:
		return null
	var grid := tree.get_first_node_in_group("grid_map") as NavGridMap
	if grid == null or grid.mesh_library == null:
		return null

	var minimum: Vector3i = grid.world_to_cell(my_aabb.position) - Vector3i.ONE
	var maximum: Vector3i = grid.world_to_cell(my_aabb.end) + Vector3i.ONE
	var step: Vector3 = grid.cell_size
	var sum := Vector3.ZERO
	var count := 0
	var scanned := 0

	for x in range(minimum.x, maximum.x + 1):
		if scanned > COLLISION_DESTRUCTION_SCAN_LIMIT:
			break
		for y in range(minimum.y, maximum.y + 1):
			if scanned > COLLISION_DESTRUCTION_SCAN_LIMIT:
				break
			for z in range(minimum.z, maximum.z + 1):
				scanned += 1
				if scanned > COLLISION_DESTRUCTION_SCAN_LIMIT:
					break
				var cell := Vector3i(x, y, z)
				var item: int = grid.get_block_item(cell)
				if item < 0:
					continue
				var center: Vector3 = grid.to_global(grid.map_to_local(cell))
				var box := AABB(center - step * 0.5, step)
				if not box.intersects(my_aabb):
					continue
				sum += center
				count += 1
				if count >= COLLISION_CONTACT_SAMPLE_LIMIT:
					break
			if count >= COLLISION_CONTACT_SAMPLE_LIMIT:
				break
		if count >= COLLISION_CONTACT_SAMPLE_LIMIT:
			break

	if count == 0:
		return null
	return sum / float(count)


## Runs the normal structural-support rules on the body's local grid. Only
## cells that actually rest on the world or on another body are used as
## foundation anchors; the rest of the body must reach them through the normal
## material span. A body that is entirely airborne therefore has no anchored
## base and its unsupported cells are shed.
func _apply_local_stability() -> Array[Vector3i]:
	if not stability_enabled or cells.is_empty():
		return []

	var anchors := _ground_anchor_cells()
	if anchors.is_empty() and not is_inside_tree():
		# Called before the body reaches the tree (tests/tools): keep the old
		# lowest-layer fallback because no world raycast can run yet.
		var min_y: int = 2147483647
		for cell: Vector3i in cells:
			min_y = mini(min_y, cell.y)
		for cell: Vector3i in cells:
			if cell.y == min_y:
				anchors.append(cell)

	var solver = STRUCTURAL_STABILITY.new(self)
	var keys: Array[Vector3i] = []
	keys.assign(cells.keys())
	var field: Dictionary = solver.field_for_cells(keys, anchors)
	var removed: Array[Vector3i] = []

	for cell: Vector3i in keys:
		if int(field.get(cell, -1)) <= 0:
			removed.append(cell)

	if removed.is_empty():
		return removed

	var removed_data: Dictionary = {}
	for cell: Vector3i in removed:
		removed_data[cell] = (cells[cell] as Dictionary).duplicate()

	for cell: Vector3i in removed:
		cells.erase(cell)
		_burning_cells.erase(cell)

	if shed_callback.is_valid():
		shed_callback.call(removed, removed_data)
	else:
		_remove_placeables_at(removed)

	return removed


## True foundation anchors: the lowest cell of each local column that has a
## downward ray hit on the world (layer 1) or another sub-level (layer 16)
## within a small gap. This anchors only the cells actually touching a surface.
func _ground_anchor_cells() -> Array[Vector3i]:
	var anchors: Array[Vector3i] = []
	if not is_inside_tree():
		return anchors

	var lowest: Dictionary = {}
	for cell: Vector3i in cells:
		var column := Vector2i(cell.x, cell.z)
		var existing: Variant = lowest.get(column, null)
		if existing == null:
			lowest[column] = cell
			continue
		var existing_cell: Vector3i = existing
		if cell.y < existing_cell.y:
			lowest[column] = cell

	if lowest.is_empty():
		return anchors

	var space := get_world_3d().direct_space_state
	if space == null:
		return anchors

	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = 1 | SUBLEVEL_LAYER
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var half_height := block_size.y * 0.5
	for column_value: Variant in lowest:
		var cell: Vector3i = lowest[column_value]
		var bottom := to_global(
			cell_center_local(cell) - Vector3.UP * half_height
		)
		# Start just inside our own block (self is excluded) and look through
		# the bottom face into the surface below.
		query.from = bottom + Vector3.UP * 0.1
		query.to = bottom - Vector3.UP * (half_height * 0.7 + 0.3)
		if space.intersect_ray(query).is_empty():
			continue
		anchors.append(cell)

	return anchors


## Public entry point used when the stability rule is switched on for bodies
## that already exist.
func apply_stability_now() -> Array[Vector3i]:
	var removed := _apply_local_stability()
	if not removed.is_empty():
		if cells.is_empty():
			move_placeables_to(get_parent())
			queue_free()
			return removed
		_rebuild()
		_refresh_fire_visual()
	return removed


func _remove_placeables_at(removed_cells: Array[Vector3i]) -> void:
	if removed_cells.is_empty():
		return

	var wanted: Dictionary = {}
	for cell: Vector3i in removed_cells:
		wanted[cell] = true

	for child in get_children():
		if not child is Node3D or not child.is_in_group("placeables"):
			continue
		var cell := local_cell_at_world((child as Node3D).global_position)
		if wanted.has(cell):
			child.queue_free()


# --- Contact damage --------------------------------------------------------

## Moving bodies damage nearby agents/player. Kinematic agents do not generate
## engine contacts with the sub-level layer, so this intentionally uses a short
## proximity sweep; it is off by default.
func _update_contact_damage(delta: float) -> void:
	_contact_accum += delta
	if _contact_accum < 0.2:
		return

	_contact_accum = 0.0
	var speed: float = (
		linear_velocity.length()
		+ angular_velocity.length() * block_size.length() * 0.5
	)
	if speed < contact_damage_min_speed:
		return

	var bounds: AABB = world_aabb().grow(0.8)
	var damage: float = clampf(
		(speed - contact_damage_min_speed)
		* maxf(mass, 1.0)
		* contact_damage_scale,
		0.0,
		200.0
	)
	if damage <= 0.0:
		return

	var now := Time.get_ticks_msec()
	_damage_group("npc", bounds, damage, now)
	_damage_group("Player", bounds, damage, now)


func _damage_group(
	group_name: String,
	bounds: AABB,
	damage: float,
	now: int
) -> void:
	for node in get_tree().get_nodes_in_group(group_name):
		if not node is Node3D:
			continue
		if not bounds.has_point((node as Node3D).global_position + Vector3.UP * 0.5):
			continue
		var id := node.get_instance_id()
		if now - int(_contact_last_msec.get(id, -100000)) < 500:
			continue
		_contact_last_msec[id] = now
		_damage_node(node as Node, damage)


func _damage_node(node: Node, damage: float) -> void:
	var current := node
	while current != null:
		if current.has_method("take_damage"):
			current.call("take_damage", damage)
			return
		var health := current.get_node_or_null("HealthComponent")
		if health != null and health.has_method("take_damage"):
			health.call("take_damage", damage)
			return
		current = current.get_parent()


# --- Collision destruction -------------------------------------------------

func _carve_world_at(world_position: Vector3, radius: float) -> int:
	var tree := get_tree()
	if tree == null:
		return 0
	var grid := tree.get_first_node_in_group("grid_map") as NavGridMap
	if grid == null or grid.mesh_library == null:
		return 0

	var center: Vector3i = grid.world_to_cell(world_position)
	var step := maxf(
		minf(grid.cell_size.x, minf(grid.cell_size.y, grid.cell_size.z)),
		0.01
	)
	var reach := mini(int(ceil(radius / step)), 6)
	var cells: Array[Vector3i] = []

	for x in range(-reach, reach + 1):
		for y in range(-reach, reach + 1):
			for z in range(-reach, reach + 1):
				var cell := center + Vector3i(x, y, z)
				var item: int = grid.get_block_item(cell)
				if item < 0:
					continue
				var item_name := String(grid.mesh_library.get_item_name(item))
				var anchored: bool
				if _anchored_cache.has(item):
					anchored = bool(_anchored_cache[item])
				else:
					anchored = BLOCK_MATERIALS.is_anchored(item_name)
					_anchored_cache[item] = anchored
				if anchored:
					continue
				if (
					grid.to_global(grid.map_to_local(cell))
					.distance_to(world_position) > radius
				):
					continue
				cells.append(cell)
				if cells.size() >= COLLISION_DESTRUCTION_MAX_CELLS:
					break
			if cells.size() >= COLLISION_DESTRUCTION_MAX_CELLS:
				break
		if cells.size() >= COLLISION_DESTRUCTION_MAX_CELLS:
			break

	if cells.is_empty():
		return 0
	return grid.remove_blocks(cells)


## Carve a crater out of this body's local cells. Public for collision
## destruction and tests.
func carve_at_world(world_position: Vector3, radius: float) -> int:
	if cells.is_empty():
		return 0

	var center := local_cell_at_world(world_position)
	var step := maxf(
		minf(block_size.x, minf(block_size.y, block_size.z)),
		0.01
	)
	var reach := mini(int(ceil(radius / step)), 6)
	var removed: Array[Vector3i] = []

	for x in range(-reach, reach + 1):
		for y in range(-reach, reach + 1):
			for z in range(-reach, reach + 1):
				var cell := center + Vector3i(x, y, z)
				if not cells.has(cell):
					continue
				if cell_center_world(cell).distance_to(world_position) > radius:
					continue
				removed.append(cell)
				if removed.size() >= COLLISION_DESTRUCTION_MAX_CELLS:
					break
			if removed.size() >= COLLISION_DESTRUCTION_MAX_CELLS:
				break
		if removed.size() >= COLLISION_DESTRUCTION_MAX_CELLS:
			break

	if removed.is_empty():
		return 0

	_remove_placeables_at(removed)
	for cell: Vector3i in removed:
		cells.erase(cell)
		_burning_cells.erase(cell)

	if cells.is_empty():
		move_placeables_to(get_parent())
		detach_ash()
		queue_free()
		return removed.size()

	if stability_enabled:
		_apply_local_stability()

	_rebuild()
	_refresh_fire_visual()
	return removed.size()


# --- Fire ------------------------------------------------------------------

func ignite_at_world(world_position: Vector3) -> bool:
	if not fire_enabled:
		return false
	return ignite_cell(nearest_cell_to_world(world_position))


func ignite_cell(cell: Vector3i) -> bool:
	if not fire_enabled or not cells.has(cell):
		return false
	if _burning_cells.has(cell):
		return true
	if _burning_cells.size() >= MAX_BURNING_CELLS:
		return false
	var flammability := _cell_flammability(cell)
	_burning_cells[cell] = (
		_burn_fuel if flammability >= SUSTAINED_FLAMMABILITY else SURFACE_FUEL
	)
	_refresh_fire_visual()
	return true


func extinguish_all() -> void:
	_burning_cells.clear()
	_refresh_fire_visual()


func extinguish_at_world(world_position: Vector3, radius: float) -> int:
	var removed := 0
	var radius_sq := radius * radius

	for cell_value: Variant in _burning_cells.keys():
		var cell: Vector3i = cell_value
		if cell_center_world(cell).distance_squared_to(world_position) > radius_sq:
			continue
		_burning_cells.erase(cell)
		removed += 1

	if removed > 0:
		_refresh_fire_visual()
	return removed


func is_burning() -> bool:
	return not _burning_cells.is_empty()


## Fire ticks twice a second: damages nearby health targets, spreads to
## connected cells, consumes cells, and rebuilds the body once per tick.
func _update_fire(delta: float) -> void:
	_fire_accum += delta
	if _fire_accum < 0.5:
		return

	var step := _fire_accum
	_fire_accum = 0.0
	var burning: Array = _burning_cells.keys()
	var damage_centers: Array = []
	var consumed: Array[Vector3i] = []
	var expired: Array[Vector3i] = []

	for cell_value: Variant in burning:
		var cell: Vector3i = cell_value
		_burning_cells[cell] = float(_burning_cells[cell]) - step
		damage_centers.append(cell_center_world(cell))

		if _burning_cells.size() < MAX_BURNING_CELLS:
			_try_spread(cell)

		if float(_burning_cells[cell]) <= 0.0:
			if _cell_flammability(cell) >= SUSTAINED_FLAMMABILITY:
				consumed.append(cell)
			else:
				expired.append(cell)

	if not damage_centers.is_empty():
		Explosion.damage_area_clustered(
			self,
			damage_centers,
			_fire_damage_radius,
			_fire_damage_per_tick
		)

	for cell: Vector3i in expired:
		_burning_cells.erase(cell)

	_inject_smoke(burning)

	if consumed.is_empty():
		_refresh_fire_visual()
		return

	_consume_cells(consumed)


## Sustained cells are consumed and become ash panels at the bottom of their
## local column. Surface fires on concrete/stone never reach here.
func _consume_cells(removed: Array[Vector3i]) -> void:
	if removed.is_empty():
		return

	_remove_placeables_at(removed)
	for cell: Vector3i in removed:
		_burning_cells.erase(cell)
		cells.erase(cell)

	_place_ash_panels(removed)

	if cells.is_empty():
		move_placeables_to(get_parent())
		detach_ash()
		queue_free()
		return

	if stability_enabled:
		_apply_local_stability()

	if cells.is_empty():
		move_placeables_to(get_parent())
		detach_ash()
		queue_free()
		return

	_rebuild()
	_refresh_fire_visual()


func _place_ash_panels(removed: Array[Vector3i]) -> void:
	var ash_item := _ash_panel_item()
	if ash_item < 0:
		return

	var min_y: int = 2147483647
	for cell: Vector3i in cells:
		min_y = mini(min_y, cell.y)
	for cell: Vector3i in removed:
		min_y = mini(min_y, cell.y)
	if min_y == 2147483647:
		return

	var landing: Dictionary = {}
	for cell: Vector3i in removed:
		var probe := cell
		for _index in ASH_SCAN_LIMIT:
			var below := probe + Vector3i.DOWN
			if cells.has(below):
				if not cells.has(probe):
					landing[probe] = true
				break
			if probe.y <= min_y:
				if not cells.has(probe):
					landing[probe] = true
				break
			probe = below

	var columns: Dictionary = {}
	for key: Variant in landing:
		var ash_cell: Vector3i = key
		cells[ash_cell] = {"item": ash_item, "orientation": 0}
		var column := Vector2i(ash_cell.x, ash_cell.z)
		if columns.has(column):
			var existing: Vector3i = columns[column]
			if ash_cell.y < existing.y:
				columns[column] = ash_cell
		else:
			columns[column] = ash_cell

	for key: Variant in columns:
		var bottom: Vector3i = columns[key]
		ASH_SETTLER.compact_cells_column(cells, mesh_library, bottom)


func _ash_panel_item() -> int:
	if _ash_item != -2:
		return _ash_item
	_ash_item = -1
	if mesh_library == null:
		return _ash_item
	for id: int in mesh_library.get_item_list():
		if String(mesh_library.get_item_name(id)) == ASH_PANEL_NAME:
			_ash_item = id
			return _ash_item
	for id: int in mesh_library.get_item_list():
		var lower := String(mesh_library.get_item_name(id)).to_lower()
		if "panel" in lower and "ash" in lower:
			_ash_item = id
			return _ash_item
	return _ash_item


## Feed the shared HazardWorld smoke CA used by the smoke tool.
func _inject_smoke(cells: Array) -> void:
	if cells.is_empty() or not is_inside_tree():
		return
	var hazard := get_tree().get_first_node_in_group("hazard_world")
	if hazard == null or not hazard.has_method("add_smoke"):
		return
	var stride := maxi(
		1,
		int(ceil(float(cells.size()) / float(SMOKE_SAMPLES_PER_TICK)))
	)
	var index := 0
	for cell_value: Variant in cells:
		if index % stride == 0:
			var cell: Vector3i = cell_value
			hazard.call(
				"add_smoke",
				cell_center_world(cell) + Vector3.UP * 0.8,
				0.32,
				1.3
			)
		index += 1


func _try_spread(cell: Vector3i) -> void:
	if _cell_flammability(cell) < SUSTAINED_FLAMMABILITY:
		return
	for offset: Vector3i in NEIGHBOURS_6:
		var neighbour: Vector3i = cell + offset
		if not cells.has(neighbour) or _burning_cells.has(neighbour):
			continue
		var flammability := _cell_flammability(neighbour)
		if flammability <= MIN_FLAMMABILITY:
			continue
		var chance := clampf(flammability * SPREAD_CHANCE_SCALE, 0.0, 0.85)
		if randf() < chance:
			_burning_cells[neighbour] = _burn_fuel
			if _burning_cells.size() >= MAX_BURNING_CELLS:
				return


func _cell_flammability(cell: Vector3i) -> float:
	if mesh_library == null or not cells.has(cell):
		return 0.0
	var item: int = int((cells[cell] as Dictionary).get("item", -1))
	if item < 0:
		return 0.0
	if _flammability_cache.has(item):
		return float(_flammability_cache[item])
	var value := BLOCK_MATERIALS.flammability_for_item(
		String(mesh_library.get_item_name(item))
	)
	_flammability_cache[item] = value
	return value


static func _build_fire_frames() -> Array[ImageTexture]:
	if not _fire_frame_textures.is_empty():
		return _fire_frame_textures
	var image := FIRE_TEXTURE.get_image()
	var frames := maxi(1, image.get_height() / FIRE_FRAME_SIZE)
	for index in frames:
		var region := image.get_region(Rect2i(
			0,
			index * FIRE_FRAME_SIZE,
			FIRE_FRAME_SIZE,
			FIRE_FRAME_SIZE
		))
		_fire_frame_textures.append(ImageTexture.create_from_image(region))
	return _fire_frame_textures


func _animate_fire_visual(delta: float) -> void:
	_fire_anim_accum += delta
	if _fire_anim_accum >= 0.08:
		_fire_anim_accum = 0.0
		if _fire_material != null:
			var frames := _build_fire_frames()
			if not frames.is_empty():
				var frame := int(Time.get_ticks_msec() / 80) % frames.size()
				_fire_material.albedo_texture = frames[frame]


func _animate_smoke() -> void:
	var count := mini(_burning_cells.size(), MAX_BURNING_CELLS)
	if count <= 0:
		if _smoke_count > 0:
			_smoke_multimesh.instance_count = 0
			_smoke_count = 0
		return
	if _smoke_count != count:
		_smoke_multimesh.instance_count = count
		_smoke_count = count

	var t := Time.get_ticks_msec() * 0.001
	var index := 0
	for cell_value: Variant in _burning_cells:
		var cell: Vector3i = cell_value
		var phase := fposmod(
			t * 0.42 + float(cell.x * 37 + cell.y * 61 + cell.z * 19) * 0.01,
			1.0
		)
		var size := 0.55 + phase * 1.15
		var alpha := sin(phase * PI) * 0.42
		_smoke_multimesh.set_instance_transform(
			index,
			Transform3D(
				Basis.from_scale(Vector3(size, size, size)),
				cell_center_local(cell)
				+ Vector3.UP * (block_size.y * 0.5 + phase * 1.7)
			)
		)
		_smoke_multimesh.set_instance_color(
			index,
			Color(0.82, 0.80, 0.77, alpha)
		)
		index += 1
		if index >= count:
			return


func _refresh_fire_visual() -> void:
	if _burning_cells.is_empty():
		if is_instance_valid(_fire_visual):
			_fire_visual.visible = false
		if is_instance_valid(_smoke_visual):
			_smoke_visual.visible = false
		if _smoke_multimesh != null and _smoke_count > 0:
			_smoke_multimesh.instance_count = 0
			_smoke_count = 0
		if is_instance_valid(_fire_light):
			_fire_light.visible = false
		return

	_ensure_fire_visual()
	var transforms: Array[Transform3D] = []
	var t := Time.get_ticks_msec() * 0.01
	var first_cell := Vector3i.ZERO
	var has_first := false
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	var camera_pos := Vector3.ZERO
	var has_camera := false
	var viewport := get_viewport()
	if viewport != null:
		var camera := viewport.get_camera_3d()
		if camera != null:
			camera_pos = to_local(camera.global_position)
			has_camera = true

	for cell_value: Variant in _burning_cells:
		var cell: Vector3i = cell_value
		var local := cell_center_local(cell)
		minimum = minimum.min(local)
		maximum = maximum.max(local)
		if not has_first:
			first_cell = cell
			has_first = true
		var flame_position: Variant = _flame_local_position(
			cell,
			camera_pos,
			has_camera
		)
		if flame_position == null:
			continue
		var scale := 1.0 + sin(t + float(cell.x + cell.z)) * 0.08
		transforms.append(Transform3D(
			Basis.from_scale(Vector3(scale, scale, scale)),
			flame_position
		))

	_fire_multimesh.instance_count = transforms.size()
	for index in transforms.size():
		_fire_multimesh.set_instance_transform(index, transforms[index])

	if is_instance_valid(_smoke_visual):
		_smoke_visual.visible = true
		_smoke_visual.custom_aabb = AABB(
			minimum + Vector3.UP * 0.2,
			(maximum - minimum) + Vector3(8.0, 8.0, 8.0)
		)

	_fire_visual.visible = not transforms.is_empty()
	if is_instance_valid(_fire_light):
		_fire_light.visible = not transforms.is_empty()
		_fire_light.global_position = (
			cell_center_world(first_cell)
			+ Vector3.UP * (block_size.y * 0.5 + 0.4)
		)


## Pick an exposed face for the flame in body-local space: top when exposed
## upward, otherwise the side face that most directly faces the camera. Fully
## enclosed cells draw nothing.
func _flame_local_position(
	cell: Vector3i,
	camera_pos: Vector3,
	has_camera: bool
) -> Variant:
	if not cells.has(cell):
		return null
	var center := cell_center_local(cell)
	if not cells.has(cell + Vector3i(0, 1, 0)):
		return center + Vector3.UP * (block_size.y * 0.5 + 0.15)

	var best_dir := Vector3i.ZERO
	var best_score := -2.0
	for dir: Vector3i in SIDE_DIRS:
		if cells.has(cell + dir):
			continue
		var face := center + Vector3(dir) * block_size * 0.5
		var score := 0.0
		if has_camera:
			score = Vector3(dir).dot((camera_pos - face).normalized())
		if score > best_score:
			best_score = score
			best_dir = dir

	if best_dir == Vector3i.ZERO:
		return null
	return (
		center
		+ Vector3(best_dir) * block_size * 0.5
		+ Vector3(best_dir) * 0.15
	)


func _ensure_fire_visual() -> void:
	if _fire_visual != null and is_instance_valid(_fire_visual):
		return

	_fire_visual = MultiMeshInstance3D.new()
	_fire_visual.name = "SubLevelFire"
	_fire_visual.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	_fire_multimesh = MultiMesh.new()
	_fire_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(0.7, 0.7)
	_fire_multimesh.mesh = quad
	_fire_visual.multimesh = _fire_multimesh
	var frames := _build_fire_frames()
	_fire_material = StandardMaterial3D.new()
	_fire_material.albedo_texture = (
		frames[0] if not frames.is_empty() else FIRE_TEXTURE
	)
	_fire_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_fire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fire_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fire_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fire_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_fire_material.no_depth_test = false
	_fire_material.render_priority = 1
	_fire_visual.material_override = _fire_material
	add_child(_fire_visual)

	_fire_light = OmniLight3D.new()
	_fire_light.light_color = Color(1.0, 0.42, 0.08, 1.0)
	_fire_light.light_energy = 1.5
	_fire_light.omni_range = 4.5
	_fire_light.shadow_enabled = false
	add_child(_fire_light)


## Burned cells leave an ash patch on the surface they sat on. The patch is
## attached to the body, so it moves with a falling sub-level.
func _add_ash(removed: Array[Vector3i]) -> void:
	if removed.is_empty() or mesh_library == null:
		return
	_ensure_ash_visual()

	for cell: Vector3i in removed:
		var basis := (
			Basis(Vector3.RIGHT, -PI * 0.5)
			* Basis.from_scale(
				Vector3(block_size.x, block_size.z, 1.0)
			)
		)
		var position := (
			cell_center_local(cell)
			- Vector3.UP * (block_size.y * 0.5)
			+ Vector3.UP * 0.02
		)
		_ash_points.append(Transform3D(basis, position))
		while _ash_points.size() > MAX_ASH_INSTANCES:
			_ash_points.remove_at(0)

	_rebuild_ash()


func _ensure_ash_visual() -> void:
	if _ash_visual != null and is_instance_valid(_ash_visual):
		return
	_ash_visual = MultiMeshInstance3D.new()
	_ash_visual.name = "SubLevelFireAsh"
	_ash_visual.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	_ash_multimesh = MultiMesh.new()
	_ash_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_ash_multimesh.mesh = quad
	_ash_visual.multimesh = _ash_multimesh
	var ash_material := StandardMaterial3D.new()
	ash_material.albedo_texture = ASH_TEXTURE
	ash_material.albedo_color = Color(0.62, 0.60, 0.58, 1.0)
	ash_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	ash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	ash_material.roughness = 1.0
	_ash_visual.material_override = ash_material
	add_child(_ash_visual)


## Keep burned-out ash in the world when the body itself is freed (all cells
## consumed) or docked. The patches keep their world-space transforms.
func detach_ash() -> void:
	if (
		_ash_visual == null
		or not is_instance_valid(_ash_visual)
		or _ash_points.is_empty()
	):
		return
	var target := get_parent()
	if target == null:
		return
	var saved_transform := global_transform
	_ash_visual.reparent(target)
	_ash_visual.global_transform = saved_transform
	_ash_visual = null
	_ash_multimesh = null
	_ash_points.clear()


func _rebuild_ash() -> void:
	if _ash_multimesh == null:
		return
	_ash_multimesh.instance_count = _ash_points.size()
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	for index in _ash_points.size():
		var transform := _ash_points[index]
		_ash_multimesh.set_instance_transform(index, transform)
		minimum = minimum.min(transform.origin)
		maximum = maximum.max(transform.origin)
	if _ash_points.is_empty():
		_ash_visual.visible = false
		return
	_ash_visual.visible = true
	_ash_visual.custom_aabb = AABB(
		minimum - Vector3.ONE * 2.0,
		(maximum - minimum) + Vector3.ONE * 4.0
	)


func world_aabb() -> AABB:
	if cells.is_empty():
		return AABB(global_position, Vector3.ZERO)

	var minimum := Vector3.INF
	var maximum := -Vector3.INF

	for cell: Vector3i in cells:
		var point: Vector3 = cell_center_world(cell)
		minimum = minimum.min(point)
		maximum = maximum.max(point)

	return AABB(minimum, maximum - minimum).grow(block_size.length())


func is_settled() -> bool:
	return (
		linear_velocity.length_squared() < 0.02
		and angular_velocity.length_squared() < 0.04
	)


## Basis columns must line up with the world axes. Moving/rotated sub-levels
## stay physical but cannot be grid-merged until they settle axis-aligned.
func is_axis_aligned(tolerance: float = 0.01) -> bool:
	var basis := global_transform.basis

	for axis: Vector3 in [basis.x, basis.y, basis.z]:
		var largest: float = maxf(
			absf(axis.x),
			maxf(absf(axis.y), absf(axis.z))
		)
		if largest < 1.0 - tolerance:
			return false

	return true


## Welds `other` into this body. Returns the number of cells added; 0 when the
## two grids are not aligned closely enough to merge safely.
func merge_guest(other: SubLevel) -> int:
	if other == null or not is_instance_valid(other):
		return 0
	if not is_axis_aligned() or not other.is_axis_aligned():
		return 0

	var additions: Dictionary = {}

	for cell: Vector3i in other.cells:
		var world: Vector3 = other.cell_center_world(cell)
		var local: Vector3 = to_local(world) / block_size
		var snapped := Vector3(
			roundf(local.x),
			roundf(local.y),
			roundf(local.z)
		)

		if (local - snapped).length() > 0.25:
			# The grids do not line up; merging would shift blocks.
			return 0

		var host_cell := Vector3i(snapped)
		if cells.has(host_cell):
			continue

		var entry: Dictionary = other.cells[cell]
		additions[host_cell] = entry.duplicate()

	if additions.is_empty():
		return 0

	for cell: Vector3i in additions:
		cells[cell] = additions[cell]

	# Furniture on the welded body follows the host instead of being freed with
	# the guest.
	other.move_placeables_to(self)

	if stability_enabled:
		_apply_local_stability()

	last_edit_at = _now()
	_rebuild()
	return additions.size()


## World cells this sub-level would occupy when docked, or {} when it is not
## axis-aligned / not close enough to the grid / would overlap existing blocks.
## Builds the invisible nav-marker placement for this body's walkable top cells.
## A full marker reports its nav point at the cell top; the slab marker reports
## the cell centre. The closer one approximates the diagonal surface.
func nav_bake_placement(grid: NavGridMap) -> Dictionary:
	var result: Dictionary = {}
	if grid == null or not is_instance_valid(grid) or cells.is_empty():
		return result

	var full_item: int = grid.nav_marker_item(false)
	var low_item: int = grid.nav_marker_item(true)
	if full_item < 0 and low_item < 0:
		return result

	var cell_size: Vector3 = grid.cell_size
	var half_y: float = block_size.y * 0.5
	var low_offset: float = 0.0 if grid.cell_center_y else cell_size.y * 0.5
	var full_offset: float = cell_size.y * 0.5

	for cell: Vector3i in cells:
		if cells.has(cell + Vector3i.UP):
			continue
		var top_world: Vector3 = to_global(
			cell_center_local(cell) + Vector3.UP * half_y
		)
		var target: Vector3i = grid.world_to_cell(top_world)
		if target.y < grid.min_block_y or target.y > grid.max_block_y:
			continue
		if grid.has_block(target) and not grid.is_nav_marker_cell(target):
			continue

		var center: Vector3 = grid.to_global(grid.map_to_local(target))
		var full_y: float = center.y + full_offset
		var low_y: float = center.y + low_offset
		var full_delta: float = absf(full_y - top_world.y)
		var low_delta: float = absf(low_y - top_world.y)
		var use_low: bool = low_item >= 0 and low_delta < full_delta
		var item: int = low_item if use_low else full_item
		if item < 0:
			item = full_item
		var delta: float = low_delta if use_low else full_delta

		if result.has(target):
			var existing: Dictionary = result[target]
			if float(existing.get("delta", INF)) <= delta:
				continue
		result[target] = {
			"item": item,
			"orientation": 0,
			"delta": delta,
		}
	return result


## Best-effort conversion of every local cell to a world grid cell at the
## body's current transform. Unlike `dock_cells`, this does not require the body
## to be axis-aligned or settled: it snaps each cell centre to the nearest world
## cell, skips occupied cells, and remaps directional orientations to the
## nearest world orientation. Used by the Static Bodifier.
func world_cell_placement(grid: NavGridMap) -> Dictionary:
	var result: Dictionary = {}
	if grid == null or not is_instance_valid(grid) or cells.is_empty():
		return result

	var body_basis := global_transform.basis
	var rotated := not body_basis.is_equal_approx(Basis.IDENTITY)
	var min_y: int = grid.min_block_y
	var max_y: int = grid.max_block_y

	for cell: Vector3i in cells:
		var world := cell_center_world(cell)
		var target: Vector3i = grid.world_to_cell(world)
		if target.y < min_y or target.y > max_y:
			continue
		if grid.has_block(target) or result.has(target):
			continue

		var entry: Dictionary = cells[cell]
		var item: int = int(entry.get("item", -1))
		if item < 0:
			continue

		var orientation: int = int(entry.get("orientation", 0))
		if rotated and orientation != 0:
			orientation = _nearest_world_orientation(
				grid,
				orientation,
				body_basis
			)
		result[target] = {
			"item": item,
			"orientation": orientation,
		}

	return result


func _nearest_world_orientation(
	grid: NavGridMap,
	orientation: int,
	body_basis: Basis
) -> int:
	var local_basis: Basis
	if orientation_provider.is_valid():
		var value: Variant = orientation_provider.call(orientation)
		if value is Basis:
			local_basis = value
		else:
			return 0
	else:
		local_basis = grid.get_orientation_basis(orientation)

	var world_basis := (body_basis * local_basis).orthonormalized()
	var best := 0
	var best_score := -INF
	for index in 24:
		var candidate: Basis = grid.get_orientation_basis(index)
		var score := (
			candidate.x.dot(world_basis.x)
			+ candidate.y.dot(world_basis.y)
			+ candidate.z.dot(world_basis.z)
		)
		if score > best_score:
			best_score = score
			best = index
	return best


func dock_cells(grid: NavGridMap) -> Dictionary:
	if grid == null or cells.is_empty() or not is_axis_aligned():
		return {}

	var result: Dictionary = {}
	var tolerance: float = block_size.length() * 0.2

	for cell: Vector3i in cells:
		var world: Vector3 = cell_center_world(cell)
		var target: Vector3i = grid.world_to_cell(world)
		var center: Vector3 = grid.to_global(grid.map_to_local(target))

		if center.distance_to(world) > tolerance:
			return {}
		if grid.has_block(target) or result.has(target):
			return {}

		result[target] = (cells[cell] as Dictionary).duplicate()

	return result


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _rebuild() -> void:
	_clear_visuals()

	_mesh = _build_mesh()
	if _mesh == null:
		return

	_visual = MeshInstance3D.new()
	_visual.name = "SubLevelVisual"
	_visual.mesh = _mesh
	_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_visual)

	_build_collision(_mesh)

	mass = clampf(float(cells.size()) * 0.15, 1.0, 500.0)
	sleeping = false


func _clear_visuals() -> void:
	if is_instance_valid(_visual):
		_visual.free()
	_visual = null

	for shape: Variant in _collision_shapes:
		if is_instance_valid(shape):
			shape.free()
	_collision_shapes.clear()


func _basis_for(orientation: int) -> Basis:
	if orientation_provider.is_valid():
		var value: Variant = orientation_provider.call(orientation)
		if value is Basis:
			return value
	return Basis.IDENTITY


## One surface per (item, source surface) so the moving mesh keeps the real
## block materials and stair/slab geometry.
func _build_mesh() -> ArrayMesh:
	if mesh_library == null or cells.is_empty():
		return null

	var groups: Dictionary = {}
	var ctm_groups: Dictionary = {}
	var missing: Array[Vector3i] = []

	for cell: Vector3i in cells:
		var item: int = int((cells[cell] as Dictionary).get("item", -1))

		# Full connected-texture blocks need the same per-face CTM atlas path
		# as the world mesher; the item mesh's authored UVs cannot connect.
		if (
			item >= 0
			and ctm_grid != null
			and ctm_grid.is_ctm_item(item)
			and _is_full_block_item(item)
		):
			var ctm_material: Material = ctm_grid.get_ctm_material(item)
			var ctm_key := str(ctm_material.get_instance_id())
			if not ctm_groups.has(ctm_key):
				ctm_groups[ctm_key] = {
					"item": item,
					"material": ctm_material,
					"cells": [],
				}
			ctm_groups[ctm_key]["cells"].append(cell)
			continue

		var source: Mesh = null
		if item >= 0:
			source = mesh_library.get_item_mesh(item)

		if source == null or source.get_surface_count() == 0:
			missing.append(cell)
			continue

		for surface in source.get_surface_count():
			var key := "%d:%d" % [item, surface]
			if not groups.has(key):
				groups[key] = {
					"item": item,
					"surface": surface,
					"cells": [],
				}
			groups[key]["cells"].append(cell)

	if groups.is_empty() and ctm_groups.is_empty() and missing.is_empty():
		return null

	var result := ArrayMesh.new()
	var fallback := StandardMaterial3D.new()
	fallback.albedo_color = Color(0.5, 0.46, 0.42)
	fallback.roughness = 1.0

	for key: Variant in groups:
		var group: Dictionary = groups[key]
		var item: int = int(group["item"])
		var surface: int = int(group["surface"])
		var source: Mesh = mesh_library.get_item_mesh(item)
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)

		for cell: Vector3i in group["cells"]:
			var orientation: int = int(
				(cells[cell] as Dictionary).get("orientation", 0)
			)
			builder.append_from(
				source,
				surface,
				Transform3D(
					_basis_for(orientation),
					cell_center_local(cell)
				)
			)

		builder.commit(result)
		var material: Material = source.surface_get_material(surface)
		result.surface_set_material(
			result.get_surface_count() - 1,
			material if material != null else fallback
		)

	for key: Variant in ctm_groups:
		var ctm_group: Dictionary = ctm_groups[key]
		var item: int = int(ctm_group["item"])
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)
		var face_count := 0

		for cell: Vector3i in ctm_group["cells"]:
			face_count += _append_ctm_block(builder, cell, item)

		if face_count <= 0:
			continue

		builder.commit(result)
		var material: Material = ctm_group["material"]
		result.surface_set_material(
			result.get_surface_count() - 1,
			material if material != null else fallback
		)

	if not missing.is_empty():
		var box := BoxMesh.new()
		box.size = block_size * 0.92
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)

		for cell: Vector3i in missing:
			builder.append_from(
				box,
				0,
				Transform3D(Basis.IDENTITY, cell_center_local(cell))
			)

		builder.commit(result)
		result.surface_set_material(result.get_surface_count() - 1, fallback)

	return result


func _is_full_block_item(item: int) -> bool:
	if item < 0 or mesh_library == null:
		return false
	var lower := String(mesh_library.get_item_name(item)).to_lower()
	return not (
		"slab" in lower
		or "stair" in lower
		or "panel" in lower
	)


## Per-face CTM quad emission, matching ChunkMesher's atlas/mask convention.
func _append_ctm_block(
	builder: SurfaceTool,
	cell: Vector3i,
	item: int
) -> int:
	var base := String(ctm_grid.get_ctm_base(item))
	if base.is_empty():
		return 0

	var cell_min: Vector3 = cell_center_local(cell) - block_size * 0.5
	var emitted := 0

	for direction_id in 6:
		var neighbor: Vector3i = cell + FACE_NORMALS[direction_id]
		if _ctm_face_hidden(neighbor):
			continue

		var axis: int = direction_id >> 1
		var face_sign: int = 1 if (direction_id & 1) == 1 else -1
		var dirs: Array = _ctm_face_dirs(axis, face_sign)
		var mask: int = _ctm_mask_for_base(
			cell,
			base,
			dirs[0],
			dirs[1]
		)
		_append_ctm_quad(
			builder,
			axis,
			face_sign,
			dirs[0],
			dirs[1],
			cell_min,
			mask
		)
		emitted += 1

	return emitted


func _ctm_face_hidden(neighbor: Vector3i) -> bool:
	if not cells.has(neighbor):
		return false
	var item: int = int((cells[neighbor] as Dictionary).get("item", -1))
	return _is_full_block_item(item)


func _ctm_face_dirs(axis: int, face_sign: int) -> Array:
	var u_dir: Vector3i
	var v_dir: Vector3i
	match axis:
		0:
			u_dir = Vector3i(0, 0, -face_sign)
			v_dir = Vector3i(0, -1, 0)
		1:
			u_dir = Vector3i(1, 0, 0)
			v_dir = Vector3i(0, 0, face_sign)
		_:
			u_dir = Vector3i(face_sign, 0, 0)
			v_dir = Vector3i(0, -1, 0)
	return [u_dir, v_dir]


func _ctm_mask_for_base(
	cell: Vector3i,
	base: String,
	u_dir: Vector3i,
	v_dir: Vector3i
) -> int:
	if base.is_empty():
		return 0

	var mask := 0
	var checks: Array = [
		[1, -v_dir],
		[2, u_dir],
		[4, v_dir],
		[8, -u_dir],
		[16, u_dir - v_dir],
		[32, u_dir + v_dir],
		[64, -u_dir + v_dir],
		[128, -u_dir - v_dir],
	]
	for check: Array in checks:
		var neighbor: Vector3i = cell + check[1]
		if not cells.has(neighbor):
			continue
		var item: int = int((cells[neighbor] as Dictionary).get("item", -1))
		if item >= 0 and ctm_grid.get_ctm_base(item) == base:
			mask |= int(check[0])
	return mask


func _append_ctm_quad(
	builder: SurfaceTool,
	axis: int,
	face_sign: int,
	u_dir: Vector3i,
	v_dir: Vector3i,
	cell_min: Vector3,
	mask: int
) -> void:
	var u_axis: int = (axis + 1) % 3
	var v_axis: int = (axis + 2) % 3
	var size := block_size

	var p00: Vector3 = cell_min
	p00[axis] += size[axis] if face_sign > 0 else 0.0
	var p10: Vector3 = p00
	p10[u_axis] += size[u_axis]
	var p11: Vector3 = p10
	p11[v_axis] += size[v_axis]
	var p01: Vector3 = p00
	p01[v_axis] += size[v_axis]

	var normal := Vector3.ZERO
	normal[axis] = float(face_sign)

	var tile := Vector2(
		float(mask % CTM_ATLAS_GRID),
		float(floori(float(mask) / float(CTM_ATLAS_GRID)))
	)
	var u_vec := Vector3(u_dir)
	var v_vec := Vector3(v_dir)
	var u_extent: float = absf(u_vec.dot(size))
	var v_extent: float = absf(v_vec.dot(size))
	var u_base: float = minf(0.0, u_vec.dot(size))
	var v_base: float = minf(0.0, v_vec.dot(size))

	var corners: Array[Vector3] = [p00, p10, p11, p01]
	var winding: Array = (
		[0, 2, 1, 0, 3, 2]
		if face_sign > 0
		else [0, 1, 2, 0, 2, 3]
	)

	for corner_index: int in winding:
		var corner: Vector3 = corners[corner_index]
		var local: Vector3 = corner - cell_min
		var uv := Vector2(
			(local.dot(u_vec) - u_base) / u_extent,
			(local.dot(v_vec) - v_base) / v_extent
		)
		builder.set_normal(normal)
		builder.set_uv((tile + uv) / float(CTM_ATLAS_GRID))
		builder.add_vertex(corner)


## Greedy 3D box merge over the cells. This keeps a solid wall or floor at a
## handful of convex shapes instead of one per cell.
func _build_collision(mesh: ArrayMesh) -> void:
	var used: Dictionary = {}
	var boxes: Array[AABB] = []

	var sorted_cells: Array[Vector3i] = []
	sorted_cells.assign(cells.keys())
	sorted_cells.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			if a.y != b.y:
				return a.y < b.y
			if a.z != b.z:
				return a.z < b.z
			return a.x < b.x
	)

	for cell: Vector3i in sorted_cells:
		if used.has(cell):
			continue

		var span_x: int = 0
		while (
			cells.has(cell + Vector3i(span_x + 1, 0, 0))
			and not used.has(cell + Vector3i(span_x + 1, 0, 0))
		):
			span_x += 1

		var span_z: int = 0
		while _slab_free(cell, span_x, 0, span_z + 1, used):
			span_z += 1

		var span_y: int = 0
		while _slab_free(cell, span_x, span_y + 1, span_z, used):
			span_y += 1

		for y in span_y + 1:
			for z in span_z + 1:
				for x in span_x + 1:
					used[cell + Vector3i(x, y, z)] = true

		boxes.append(AABB(
			cell_center_local(cell)
			+ Vector3(span_x, span_y, span_z) * 0.5 * block_size,
			Vector3(span_x + 1, span_y + 1, span_z + 1) * block_size
		))

		if boxes.size() > MAX_COLLISION_SHAPES:
			break

	if boxes.size() > MAX_COLLISION_SHAPES or boxes.is_empty():
		# Too fragmented for individual boxes; one convex hull still collides.
		var hull := mesh.create_convex_shape(true, false)
		if hull != null:
			var shape := CollisionShape3D.new()
			shape.shape = hull
			add_child(shape)
			_collision_shapes.append(shape)
		return

	for box: AABB in boxes:
		var box_shape := BoxShape3D.new()
		box_shape.size = box.size
		var shape := CollisionShape3D.new()
		shape.shape = box_shape
		shape.position = box.position
		# CollisionShape3D must be a direct child of the physics body.
		add_child(shape)
		_collision_shapes.append(shape)


func _slab_free(
	start: Vector3i,
	span_x: int,
	offset_y: int,
	offset_z: int,
	used: Dictionary
) -> bool:
	for z in offset_z + 1:
		for x in span_x + 1:
			var cell := start + Vector3i(x, offset_y, z)
			if not cells.has(cell) or used.has(cell):
				return false
	return true
