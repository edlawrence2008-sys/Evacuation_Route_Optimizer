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
## A newly spawned/loaded body gets one ground-backed stability check after it
## has been at rest this long.
const STABILITY_SETTLE: float = 0.6

var grid: NavGridMap = null
var host: Node3D = null
var auto_dock: bool = false
var sublevels: Array = []

var _check_accum: float = 0.0


## Emitted after the Static Bodifier turns a sub-level into world cells.
signal staticified(cell_count: int)


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
	node.ctm_grid = grid
	_apply_grid_rules(node)
	node.shed_callback = Callable(
		self,
		"_shed_sublevel_cells"
	).bind(node)
	host.add_child(node)
	node.global_position = grid.to_global(grid.map_to_local(origin))
	node.set_cells(local_cells, false)
	sublevels.append(node)
	return node


func _apply_grid_rules(node: SubLevel) -> void:
	if grid == null or node == null:
		return
	if "sublevel_stability_enabled" in grid:
		node.stability_enabled = bool(grid.sublevel_stability_enabled)
	if "sublevel_contact_damage_enabled" in grid:
		node.contact_damage_enabled = bool(
			grid.sublevel_contact_damage_enabled
		)
	if "sublevel_contact_damage_scale" in grid:
		node.contact_damage_scale = float(
			grid.sublevel_contact_damage_scale
		)
	if "sublevel_collision_destruction_enabled" in grid:
		node.collision_destruction_enabled = bool(
			grid.sublevel_collision_destruction_enabled
		)
	if "sublevel_collision_destruction_radius" in grid:
		node.collision_destruction_radius = float(
			grid.sublevel_collision_destruction_radius
		)
	if "sublevel_fire_enabled" in grid:
		node.fire_enabled = bool(grid.sublevel_fire_enabled)
		if not node.fire_enabled and node.is_burning():
			node.extinguish_all()


## Pushes the current grid rules onto live bodies after a settings change.
func apply_grid_rules() -> void:
	_prune()
	for node: Variant in sublevels.duplicate():
		if not is_instance_valid(node):
			continue
		_apply_grid_rules(node)
		if node.stability_enabled:
			node.apply_stability_now()


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
		node.ctm_grid = grid
		_apply_grid_rules(node)
		node.shed_callback = Callable(
			self,
			"_shed_sublevel_cells"
		).bind(node)
		host.add_child(node)

		if not node.restore_state(state):
			node.queue_free()
			continue

		sublevels.append(node)

	return sublevels.size()


## Stability shed: turn removed local cells into a new free rigid sub-level.
func _shed_sublevel_cells(
	removed_cells: Array,
	removed_data: Dictionary,
	source: SubLevel
) -> void:
	if (
		grid == null
		or host == null
		or source == null
		or not is_instance_valid(source)
		or removed_data.is_empty()
	):
		return

	var node := SUB_LEVEL.new()
	node.name = "SubLevel"
	node.configure(
		grid.mesh_library,
		grid.cell_size,
		Vector3i.ZERO,
		Callable(grid, "get_orientation_basis")
	)
	node.ctm_grid = grid
	_apply_grid_rules(node)
	# Shed pieces are already the unstable fragment; let them exist as free
	# bodies instead of immediately shedding again.
	node.stability_enabled = false
	host.add_child(node)
	node.global_transform = source.global_transform
	node.set_cells(removed_data, false)
	node.linear_velocity = source.linear_velocity
	node.angular_velocity = source.angular_velocity
	node.sleeping = false

	# Move placeables on the removed cells with their fragment.
	for child in source.get_children():
		if not child is Node3D or not child.is_in_group("placeables"):
			continue
		var local := source.local_cell_at_world(
			(child as Node3D).global_position
		)
		if removed_data.has(local):
			(child as Node3D).reparent(node, true)

	sublevels.append(node)


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

	for node: Variant in sublevels.duplicate():
		if not is_instance_valid(node):
			continue
		if node.is_settled():
			node.settled_for += step
			if (
				node.stability_enabled
				and not node.freeze
				and not node.stability_checked
				and node.settled_for >= STABILITY_SETTLE
			):
				node.stability_checked = true
				node.apply_stability_now()
		else:
			node.settled_for = 0.0
			node.stability_checked = false

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
		if (
			not is_instance_valid(first)
			or first.settled_for < WELD_SETTLE
			or first.nav_baked
		):
			continue

		for other_index in range(index + 1, sublevels.size()):
			var second: Variant = sublevels[other_index]
			if (
				not is_instance_valid(second)
				or second.settled_for < WELD_SETTLE
				or second.nav_baked
			):
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
			guest.detach_ash()
			guest.queue_free()
			return true

	return false


func _dock_one() -> bool:
	for node: Variant in sublevels.duplicate():
		if (
			not is_instance_valid(node)
			or node.settled_for < DOCK_SETTLE
			or node.nav_baked
		):
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
	node.detach_ash()

	sublevels.erase(node)
	node.queue_free()
	return true


## Static Bodifier: convert a moving body into normal world blocks at its
## current transform. The placed cells enter the chunk/nav/route/save systems,
## so agents and the optimizer treat the result as map geometry.
func staticify(node: SubLevel) -> int:
	if grid == null or not is_instance_valid(grid):
		return 0
	if node == null or not is_instance_valid(node) or node.cells.is_empty():
		return 0

	unbake_nav(node)

	var placement: Dictionary = node.world_cell_placement(grid)
	if placement.is_empty():
		return 0

	var groups: Dictionary = {}
	for target_value: Variant in placement:
		var target: Vector3i = target_value
		var entry: Dictionary = placement[target]
		var item: int = int(entry.get("item", -1))
		if item < 0:
			continue
		var orientation: int = int(entry.get("orientation", 0))
		var key := "%d:%d" % [item, orientation]
		if not groups.has(key):
			groups[key] = {
				"item": item,
				"orientation": orientation,
				"cells": [],
			}
		groups[key]["cells"].append(target)

	var placed := 0
	for key: Variant in groups:
		var group: Dictionary = groups[key]
		var cells: Array[Vector3i] = []
		cells.assign(group["cells"])
		placed += grid.place_blocks(
			cells,
			int(group["item"]),
			int(group["orientation"])
		)

	if placed == 0:
		return 0

	var scene_root := get_tree().current_scene if is_inside_tree() else null
	node.move_placeables_to(scene_root if scene_root != null else host)
	node.detach_ash()
	sublevels.erase(node)
	node.queue_free()
	staticified.emit(placed)
	return placed


## Dupe gun: create a new editable sub-level with the same cells and attached
## placeables, translated by `world_offset`. The copy starts at rest.
func duplicate_sublevel(node: SubLevel, world_offset: Vector3) -> SubLevel:
	if grid == null or host == null:
		return null
	if node == null or not is_instance_valid(node) or node.cells.is_empty():
		return null

	var copy := SUB_LEVEL.new()
	copy.name = "SubLevel"
	copy.configure(
		grid.mesh_library,
		grid.cell_size,
		node.origin_cell,
		Callable(grid, "get_orientation_basis")
	)
	copy.ctm_grid = grid
	_apply_grid_rules(copy)
	copy.shed_callback = Callable(
		self,
		"_shed_sublevel_cells"
	).bind(copy)
	host.add_child(copy)
	copy.global_transform = Transform3D(
		node.global_transform.basis,
		node.global_transform.origin + world_offset
	)
	copy.set_cells(node.cells.duplicate(true), false)
	copy.linear_velocity = Vector3.ZERO
	copy.angular_velocity = Vector3.ZERO
	copy.freeze = node.freeze
	copy.gravity_scale = node.gravity_scale if node.freeze else 1.0
	copy.sleeping = false

	for child in node.get_children():
		if not child is Node3D or not child.is_in_group("placeables"):
			continue
		var duplicate := child.duplicate()
		if duplicate is Node3D:
			copy.add_child(duplicate)
			(duplicate as Node3D).transform = (child as Node3D).transform

	sublevels.append(copy)
	return copy


## Nav Bodifier: freeze the body in place and register invisible nav-marker
## world cells along its walkable top surfaces. The body keeps its diagonal
## visual/collision; the markers make the existing grid A*, routes and optimizer
## treat the surface as walkable.
func bake_nav(node: SubLevel) -> int:
	if grid == null or not is_instance_valid(grid):
		return 0
	if node == null or not is_instance_valid(node) or node.cells.is_empty():
		return 0

	unbake_nav(node)
	var placement: Dictionary = node.nav_bake_placement(grid)
	if placement.is_empty():
		return 0

	var groups: Dictionary = {}
	for target_value: Variant in placement:
		var target: Vector3i = target_value
		var entry: Dictionary = placement[target]
		var item: int = int(entry.get("item", -1))
		if item < 0:
			continue
		var key := "%d:%d" % [item, 0]
		if not groups.has(key):
			groups[key] = {"item": item, "cells": []}
		groups[key]["cells"].append(target)

	var placed := 0
	for key: Variant in groups:
		var group: Dictionary = groups[key]
		var cells: Array[Vector3i] = []
		cells.assign(group["cells"])
		placed += grid.place_blocks(cells, int(group["item"]), 0)

	if placed == 0:
		return 0

	node.nav_marker_cells.clear()
	for target_value: Variant in placement:
		node.nav_marker_cells.append(target_value as Vector3i)
	node.nav_baked = true
	node.set_meta("nav_baked", true)
	node.freeze = true
	node.linear_velocity = Vector3.ZERO
	node.angular_velocity = Vector3.ZERO
	node.gravity_scale = 0.0
	node.sleeping = false
	return placed


func unbake_nav(node: SubLevel) -> int:
	if node == null or not is_instance_valid(node) or grid == null:
		return 0
	var remove: Array[Vector3i] = []
	for cell: Vector3i in node.nav_marker_cells:
		if grid.is_nav_marker_cell(cell):
			remove.append(cell)
	var removed := 0
	if not remove.is_empty():
		removed = grid.remove_blocks(remove)
	node.nav_marker_cells.clear()
	node.nav_baked = false
	if node.has_meta("nav_baked"):
		node.remove_meta("nav_baked")
	if node.freeze:
		node.freeze = false
	node.gravity_scale = 1.0
	node.sleeping = false
	return removed


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
