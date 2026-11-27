class_name SubLevelManager
extends Node

## Owns the moving sub-level bodies and decides when they connect:
##   - two settled, touching sub-levels weld into one body;
##   - when `auto_dock_sublevels` is on, a settled sub-level that is axis-aligned
##     and touching the world becomes normal world blocks again.
##
## Welding and docking are grid merges, so they need both grids to line up; a
## rotated body keeps colliding physically but is left alone until it settles.

const SUB_LEVEL = preload("res://scripts/world/sub_level.gd")

const CHECK_INTERVAL: float = 0.25
const WELD_SETTLE: float = 0.5
const DOCK_SETTLE: float = 1.5

var grid: NavGridMap = null
var host: Node3D = null
var auto_dock: bool = false
var sublevels: Array = []

var _check_accum: float = 0.0


func setup(grid_ref: NavGridMap, host_node: Node3D) -> void:
	grid = grid_ref
	host = host_node


func spawn(
	world_cells: Array,
	items: Dictionary,
	orientations: Dictionary
) -> SubLevel:
	if grid == null or host == null or world_cells.is_empty():
		return null

	var sum := Vector3i.ZERO
	for cell_value: Variant in world_cells:
		sum += Vector3i(cell_value)

	var count: int = world_cells.size()
	var origin := Vector3i(
		roundi(float(sum.x) / float(count)),
		roundi(float(sum.y) / float(count)),
		roundi(float(sum.z) / float(count))
	)

	var local_cells: Dictionary = {}
	for cell_value: Variant in world_cells:
		var cell := Vector3i(cell_value)
		var item: int = int(items.get(cell, -1))
		if item < 0:
			continue
		local_cells[cell - origin] = {
			"item": item,
			"orientation": int(orientations.get(cell, 0)),
		}

	if local_cells.is_empty():
		return null

	var node := SUB_LEVEL.new()
	node.name = "SubLevel"
	node.configure(
		grid.mesh_library,
		grid.cell_size,
		origin,
		Callable(grid, "get_orientation_basis")
	)
	host.add_child(node)
	node.global_position = grid.to_global(grid.map_to_local(origin))
	node.set_cells(local_cells)
	sublevels.append(node)
	return node


## Snapshots every live body. The array order is stable within a save so
## attached placeables can refer back to their host by index.
func serialize_all() -> Array:
	_prune()
	var result: Array = []

	for node: Variant in sublevels:
		if is_instance_valid(node):
			result.append(node.serialize_state())

	return result


## Replaces the live bodies with a serialized array. Returns how many were
## restored; malformed entries are skipped.
func restore_all(entries: Array) -> int:
	clear_all()

	if grid == null or not is_instance_valid(grid) or host == null:
		return 0

	for value: Variant in entries:
		if not value is Dictionary:
			continue

		var state: Dictionary = value
		var node := SUB_LEVEL.new()
		node.name = "SubLevel"
		node.configure(
			grid.mesh_library,
			grid.cell_size,
			Vector3i.ZERO,
			Callable(grid, "get_orientation_basis")
		)
		host.add_child(node)

		if not node.restore_state(state):
			node.queue_free()
			continue

		sublevels.append(node)

	return sublevels.size()


func active_count() -> int:
	_prune()
	return sublevels.size()


func clear_all() -> void:
	for node: Variant in sublevels:
		if is_instance_valid(node):
			node.queue_free()
	sublevels.clear()


func _process(delta: float) -> void:
	if grid == null or not is_instance_valid(grid):
		return

	_check_accum += delta
	if _check_accum < CHECK_INTERVAL:
		return

	var step: float = _check_accum
	_check_accum = 0.0

	if "auto_dock_sublevels" in grid:
		auto_dock = bool(grid.auto_dock_sublevels)

	_prune()

	for node: Variant in sublevels:
		if not is_instance_valid(node):
			continue
		if node.is_settled():
			node.settled_for += step
		else:
			node.settled_for = 0.0

	# One connection decision per tick keeps the loop simple and spread out.
	if _weld_one():
		return

	if auto_dock:
		_dock_one()


func _prune() -> void:
	for index in range(sublevels.size() - 1, -1, -1):
		var node: Variant = sublevels[index]
		if not is_instance_valid(node) or node.cells.is_empty():
			sublevels.remove_at(index)


func _weld_one() -> bool:
	for index in sublevels.size():
		var first: Variant = sublevels[index]
		if not is_instance_valid(first) or first.settled_for < WELD_SETTLE:
			continue

		for other_index in range(index + 1, sublevels.size()):
			var second: Variant = sublevels[other_index]
			if not is_instance_valid(second) or second.settled_for < WELD_SETTLE:
				continue

			if not first.world_aabb().intersects(second.world_aabb()):
				continue

			var host_body: SubLevel = first
			var guest: SubLevel = second
			if second.cells.size() > first.cells.size():
				host_body = second
				guest = first

			var added: int = host_body.merge_guest(guest)
			if added <= 0:
				continue

			sublevels.erase(guest)
			guest.queue_free()
			return true

	return false


func _dock_one() -> bool:
	for node: Variant in sublevels.duplicate():
		if not is_instance_valid(node) or node.settled_for < DOCK_SETTLE:
			continue
		if dock_now(node):
			return true
	return false


## Docks one sub-level immediately. Public for tests and, later, a console
## command. Returns false when the grid does not line up or the cells would
## overlap the world.
func dock_now(node: SubLevel) -> bool:
	if node == null or not is_instance_valid(node) or grid == null:
		return false

	var placement: Dictionary = node.dock_cells(grid)
	if placement.is_empty():
		return false
	if not _touches_world(placement):
		return false

	var groups: Dictionary = {}

	for target: Vector3i in placement:
		var entry: Dictionary = placement[target]
		var item: int = int(entry.get("item", -1))
		var orientation: int = int(entry.get("orientation", 0))
		var key := "%d:%d" % [item, orientation]
		if not groups.has(key):
			groups[key] = {
				"item": item,
				"orientation": orientation,
				"cells": [],
			}
		groups[key]["cells"].append(target)

	for key: Variant in groups:
		var entry: Dictionary = groups[key]
		var cells: Array[Vector3i] = []
		cells.assign(entry["cells"])
		grid.place_blocks(cells, int(entry["item"]), int(entry["orientation"]))

	# Docking turns the body into world cells; furniture stays where it was
	# instead of being freed with the body.
	var scene_root := get_tree().current_scene if is_inside_tree() else null
	node.move_placeables_to(scene_root if scene_root != null else host)

	sublevels.erase(node)
	node.queue_free()
	return true


func _touches_world(placement: Dictionary) -> bool:
	for cell: Vector3i in placement:
		for offset: Vector3i in [
			Vector3i(1, 0, 0),
			Vector3i(-1, 0, 0),
			Vector3i(0, 1, 0),
			Vector3i(0, -1, 0),
			Vector3i(0, 0, 1),
			Vector3i(0, 0, -1),
		]:
			if grid.has_block(cell + offset) and not placement.has(cell + offset):
				return true
	return false
