class_name StructuralStability
extends RefCounted

## Deterministic support field for the voxel world.
##
## Model (matches the design in docs/STRUCTURAL_INTEGRITY.md):
##   - Bedrock and other anchored materials are roots with infinite reach.
##   - Support propagates straight up with no loss, so a pillar keeps the
##     reach of its anchor at every height.
##   - Each lateral step costs 1. A concrete face at 8 supports 7 next to it.
##   - A cell's value is min(incoming, material reach). Wood next to concrete 8
##     still caps at 4.
##   - 0 means unsupported. It does not support anything above it either.
##
## Evaluation is windowed: an edit can only change cells within
## `max_reach` lateral steps, and a cell at that distance can only receive from
## a column at most another `max_reach` farther out. The window is therefore
## `2 * max_reach` columns wide, which keeps an edit bounded even in a huge
## world. Cells outside the window are not needed: with values capped at
## `max_reach`, a cell more than `2 * max_reach` away can contribute at most 0.
##
## The grid is accessed through duck typing (no NavGridMap type reference) to
## avoid a script cycle with gridmap.gd.

const MATERIALS = preload("res://scripts/block_materials.gd")

const STABILITY_ANCHORED: int = MATERIALS.STABILITY_ANCHORED
const STABILITY_UNSUPPORTED: int = MATERIALS.STABILITY_UNSUPPORTED
const MAX_WINDOW_CELLS: int = 60000

const DIRS_6: Array[Vector3i] = [
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

const DIRS_LATERAL: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

var _grid: Node
var _reach_cache: Dictionary = {}
var _anchor_cache: Dictionary = {}
var _max_reach: int = 0


func _init(grid: Node) -> void:
	_grid = grid


## Drops cached item lookups. Editor tools call this after rebuilding blocks.
func invalidate_items() -> void:
	_reach_cache.clear()
	_anchor_cache.clear()
	_max_reach = 0


func max_reach() -> int:
	if _max_reach <= 0:
		_max_reach = maxi(1, MATERIALS.max_stability_reach())
	return _max_reach


## Lateral distance at which an edit can still change support.
func decision_radius() -> int:
	return max_reach()


## How far the evaluation window reaches. See the class comment for the proof.
func window_radius() -> int:
	return max_reach() * 2


func reach_of(item: int) -> int:
	var cached: Variant = _reach_cache.get(item, null)
	if cached != null:
		return int(cached)

	var value: int = MATERIALS.FALLBACK_STABILITY_REACH
	var library: MeshLibrary = _grid.mesh_library
	if library != null and library.get_item_list().has(item):
		value = MATERIALS.stability_reach_for_item(
			String(library.get_item_name(item))
		)
	_reach_cache[item] = value
	return value


func is_anchor(item: int) -> bool:
	var cached: Variant = _anchor_cache.get(item, null)
	if cached != null:
		return bool(cached)

	var value := false
	var library: MeshLibrary = _grid.mesh_library
	if library != null and library.get_item_list().has(item):
		value = MATERIALS.is_anchored(String(library.get_item_name(item)))
	_anchor_cache[item] = value
	return value


## Evaluates the support window around `center`. `center` may be solid (a
## query or a fresh placement) or air (a cell that was just removed).
##
## Returns:
##   values      {Vector3i: int}  support for every cell in the window
##   cells       Array[Vector3i]  the window's solid cells
##   unsupported Array[Vector3i]  zero-valued cells within decision radius
##   aborted     bool             true when the window exceeded its cell cap
func evaluate_around(center: Vector3i) -> Dictionary:
	var radius: int = window_radius()
	var collected: Dictionary = _collect_window(center, radius)
	var cells: Array[Vector3i] = collected["cells"]

	if bool(collected["aborted"]):
		return {
			"values": {},
			"cells": cells,
			"unsupported": [],
			"aborted": true,
		}

	var values: Dictionary = _relax(cells, collected["items"])
	var decision: int = decision_radius()
	var center_column := Vector2i(center.x, center.z)
	var unsupported: Array[Vector3i] = []

	# Only report zeros within one decision radius of the center. Values near
	# the window edge can be underestimated because their support lies outside
	# the evaluated window. The caller selects centers so every edited cell is
	# within this radius of one center, which is what covers a long batch.
	for cell: Vector3i in cells:
		if int(values[cell]) > STABILITY_UNSUPPORTED:
			continue
		if _column_distance(cell, center_column) <= decision:
			unsupported.append(cell)

	return {
		"values": values,
		"cells": cells,
		"unsupported": unsupported,
		"aborted": false,
	}


## Support value of one solid cell, or -1 when the cell is empty/air.
func stability_at(cell: Vector3i) -> int:
	if not _grid.has_block(cell):
		return -1
	var result: Dictionary = evaluate_around(cell)
	return int(result["values"].get(cell, -1))


## Support field for an explicit set of cells. Used by the debug overlay: the
## caller passes the cells it wants to draw plus enough margin that the draw
## area is not on the set's boundary. Cells outside the set are treated as air.
func field_for_cells(
	cells: Array[Vector3i],
	extra_anchors: Array[Vector3i] = []
) -> Dictionary:
	var solid: Array[Vector3i] = []
	var items: Dictionary = {}
	var anchors: Dictionary = {}

	for cell: Vector3i in extra_anchors:
		anchors[cell] = true

	for cell: Vector3i in cells:
		var item: int = int(_grid.get_block_item(cell))
		if item < 0:
			continue
		solid.append(cell)
		items[cell] = item

	return _relax(solid, items, anchors)


func _column_distance(cell: Vector3i, column: Vector2i) -> int:
	return absi(cell.x - column.x) + absi(cell.z - column.y)


## Connected solid cells around `center` within `radius` columns, all heights.
## Returns the cells and their item ids so the relaxation does not have to ask
## the section store again for every edge.
func _collect_window(center: Vector3i, radius: int) -> Dictionary:
	var cells: Array[Vector3i] = []
	var seen: Dictionary = {}
	var items: Dictionary = {}
	var stack: Array[Vector3i] = []
	var center_column := Vector2i(center.x, center.z)

	var center_item: int = int(_grid.get_block_item(center))
	if center_item >= 0:
		items[center] = center_item
		stack.append(center)

	for offset: Vector3i in DIRS_6:
		var neighbour: Vector3i = center + offset
		if items.has(neighbour):
			continue
		var item: int = int(_grid.get_block_item(neighbour))
		if item >= 0:
			items[neighbour] = item
			stack.append(neighbour)

	while not stack.is_empty():
		var cell: Vector3i = stack.pop_back()
		if seen.has(cell):
			continue
		if _column_distance(cell, center_column) > radius:
			continue

		seen[cell] = true
		cells.append(cell)

		if cells.size() >= MAX_WINDOW_CELLS:
			return {"cells": cells, "items": items, "aborted": true}

		for offset: Vector3i in DIRS_6:
			var neighbour: Vector3i = cell + offset
			if seen.has(neighbour) or items.has(neighbour):
				continue
			var item: int = int(_grid.get_block_item(neighbour))
			if item >= 0:
				items[neighbour] = item
				stack.append(neighbour)

	return {"cells": cells, "items": items, "aborted": false}


## Highest-first relaxation over the supplied cell set.
##
## Two values are tracked per cell:
##   raw[cell]    support arriving from an anchor or a lateral neighbour
##   value[cell]  raw capped by the cell's own material reach (what is shown)
##
## Vertical edges carry `raw` unchanged: a grass block on bedrock displays 1
## because it can only span one block sideways, but it still passes the column's
## full support to the concrete built on top. Capping vertically as well would
## make every structure on natural ground start at 1.
##
## Lateral edges spend one point from the neighbour's *capped* value, which is
## what makes wood beside concrete 8 become 4 and then 3.
func _relax(
	cells: Array[Vector3i],
	items: Dictionary,
	extra_anchors: Dictionary = {}
) -> Dictionary:
	var raw: Dictionary = {}
	var caps: Dictionary = {}

	for cell: Vector3i in cells:
		raw[cell] = STABILITY_UNSUPPORTED
		caps[cell] = reach_of(int(items.get(cell, -1)))

	var buckets: Array = []
	buckets.resize(STABILITY_ANCHORED + 1)
	for index in buckets.size():
		buckets[index] = []

	for cell: Vector3i in cells:
		if extra_anchors.has(cell) or is_anchor(int(items.get(cell, -1))):
			raw[cell] = STABILITY_ANCHORED
			buckets[STABILITY_ANCHORED].append(cell)

	var index: int = STABILITY_ANCHORED

	while index >= 1:
		var bucket: Array = buckets[index]

		if bucket.is_empty():
			index -= 1
			continue

		var cell: Vector3i = bucket.pop_back()
		if int(raw[cell]) != index:
			continue

		var capped: int = mini(index, int(caps[cell]))

		# Vertical: no loss and no cap by the intermediate block. A pillar keeps
		# the column's support all the way up regardless of its material.
		var up: Vector3i = cell + Vector3i(0, 1, 0)
		if raw.has(up) and index > int(raw[up]):
			raw[up] = index
			buckets[index].append(up)

		# Lateral: one step costs one point and uses this block's capped reach.
		if capped <= 1:
			continue

		for offset: Vector3i in DIRS_LATERAL:
			var neighbour: Vector3i = cell + offset
			if not raw.has(neighbour):
				continue
			var candidate: int = capped - 1
			if candidate <= 0:
				continue
			if candidate > int(raw[neighbour]):
				raw[neighbour] = candidate
				buckets[candidate].append(neighbour)

	var values: Dictionary = {}
	for cell: Vector3i in cells:
		values[cell] = mini(int(raw[cell]), int(caps[cell]))

	return values
