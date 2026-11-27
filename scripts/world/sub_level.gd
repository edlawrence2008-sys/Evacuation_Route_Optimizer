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

## Live body count. Agents use this to skip the sub-level obstacle ray entirely
## on maps that do not have any moving structures.
static var live_count: int = 0

## local cell -> {"item": int, "orientation": int}
var cells: Dictionary = {}
var mesh_library: MeshLibrary = null
var block_size: Vector3 = Vector3.ONE
## World cell that maps to local (0, 0, 0). Only meaningful while the body is
## still at its spawn transform; edits and merging use local cells.
var origin_cell: Vector3i = Vector3i.ZERO
## Callable(grid.get_orientation_basis) so slabs/stairs keep their facing.
var orientation_provider: Callable = Callable()
var settled_for: float = 0.0
var last_edit_at: float = 0.0

var _visual: MeshInstance3D = null
var _collision_shapes: Array[CollisionShape3D] = []
var _mesh: ArrayMesh = null


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
	linear_damp = 0.05
	angular_damp = 0.1


func _enter_tree() -> void:
	live_count += 1


func _exit_tree() -> void:
	live_count = maxi(0, live_count - 1)


func set_cells(data: Dictionary) -> void:
	cells.clear()

	for cell: Vector3i in data:
		var entry: Dictionary = data[cell]
		var item: int = int(entry.get("item", -1))
		if item < 0:
			continue
		cells[cell] = {
			"item": item,
			"orientation": int(entry.get("orientation", 0)),
		}

	_rebuild()


## JSON-safe snapshot of the body, its cells and its motion state. Cell keys are
## stored as flat rows because JSON cannot key a dictionary by Vector3i.
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

	set_cells(data)

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
	_rebuild()
	return true


func remove_cell(cell: Vector3i) -> bool:
	if not cells.erase(cell):
		return false

	last_edit_at = _now()

	if cells.is_empty():
		move_placeables_to(get_parent())
		queue_free()
		return true

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

	last_edit_at = _now()
	_rebuild()
	return additions.size()


## World cells this sub-level would occupy when docked, or {} when it is not
## axis-aligned / not close enough to the grid / would overlap existing blocks.
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
	var missing: Array[Vector3i] = []

	for cell: Vector3i in cells:
		var item: int = int((cells[cell] as Dictionary).get("item", -1))
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

	if groups.is_empty() and missing.is_empty():
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
