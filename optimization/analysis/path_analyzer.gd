class_name PathAnalyzer
extends RefCounted

## Turns a cohort and an exit into a predicted route using the per-exit cost
## fields in the snapshot. The cost field is built by the simulation from the
## same wall/gap/surface weights A* uses, so the optimizer's distance agrees
## with the path agents will walk.
##
## Route cells are reconstructed by descending the cost field. No A* query is
## issued per cohort: the bridge bakes one field per exit, and every cohort
## reads it. Falls back to "unreachable" when the cohort's cell is missing from
## the field.

## Same 16 moves as NavGridMap.NEIGHBOR_OFFSETS: 4 straight, 4 flat diagonals,
## 8 one-block stair steps.
const NEIGHBOUR_OFFSETS: Array[Vector3i] = [
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

const STRAIGHT_OFFSETS: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.FORWARD,
	Vector3i.BACK,
]

const DEFAULT_SPEED: float = 1.34
const MIN_SPEED: float = 0.2
const MAX_PATH_STEPS: int = 4096

var _snapshot: SimulationSnapshot
var _exit_ids: Array[String] = []
var _fields: Dictionary = {}
var _routes: Dictionary = {}
var _widths: Dictionary = {}
var _cell_size: Vector3 = Vector3.ONE


func setup(snapshot: SimulationSnapshot, _cohorts: Array = []) -> void:
	_snapshot = snapshot
	_exit_ids.clear()
	_fields.clear()
	_routes.clear()
	_widths.clear()

	if snapshot == null:
		return

	_cell_size = snapshot.get_cell_size()

	for exit_data: Dictionary in snapshot.get_available_exits():
		var exit_id: String = String(exit_data.get("exit_id", ""))

		if exit_id.is_empty():
			continue

		_exit_ids.append(exit_id)
		_fields[exit_id] = snapshot.get_cost_field(exit_id)


func get_exit_ids() -> Array[String]:
	return _exit_ids.duplicate()


func has_exit(exit_id: String) -> bool:
	return _fields.has(exit_id)


func get_route(cohort: Dictionary, exit_id: String) -> Dictionary:
	var cohort_id: int = int(cohort.get("cohort_id", -1))
	var key: String = "%d|%s" % [cohort_id, exit_id]
	var cached: Variant = _routes.get(key)

	if cached != null:
		return cached

	var field: Dictionary = _fields.get(exit_id, {})
	var start: Vector3i = cohort.get("cell", Vector3i.ZERO)
	var result: Dictionary = {
		"reachable": false,
		"distance": -1.0,
		"time": -1.0,
		"cells": [],
	}

	if not field.is_empty() and field.has(start):
		var distance: float = float(field[start])
		var speed: float = maxf(float(cohort.get("speed", DEFAULT_SPEED)), MIN_SPEED)

		result["reachable"] = true
		result["distance"] = distance
		result["time"] = distance / speed
		result["cells"] = _reconstruct(field, start)

	_routes[key] = result
	return result


## Downhill orthogonal directions at a cell. One means a corridor/bottleneck,
## two to four means an open approach. Used as a coarse lane width by the
## congestion estimator; it is a heuristic, not door geometry.
func get_cell_lane_width(exit_id: String, cell: Vector3i) -> int:
	var per_exit: Variant = _widths.get(exit_id)

	if per_exit == null:
		per_exit = {}
		_widths[exit_id] = per_exit

	if (per_exit as Dictionary).has(cell):
		return int(per_exit[cell])

	var field: Dictionary = _fields.get(exit_id, {})
	var width: int = 1

	if field.has(cell):
		var current: float = float(field[cell])
		var downhill: int = 0

		for offset: Vector3i in STRAIGHT_OFFSETS:
			var neighbour: Vector3i = cell + offset

			if field.has(neighbour) and float(field[neighbour]) < current - 0.0001:
				downhill += 1

		width = clampi(downhill, 1, 3)

	(per_exit as Dictionary)[cell] = width
	return width


static func _reconstruct(field: Dictionary, start: Vector3i) -> Array:
	var path: Array = []
	var current: Vector3i = start
	var current_cost: float = float(field[start])
	var guard: int = 0
	path.append(current)

	while current_cost > 0.001 and guard < MAX_PATH_STEPS:
		guard += 1

		var best_cell: Vector3i = current
		var best_cost: float = current_cost

		for offset: Vector3i in NEIGHBOUR_OFFSETS:
			var neighbour: Vector3i = current + offset

			if not field.has(neighbour):
				continue

			# Flat diagonals follow the nav graph's corner rule: both
			# orthogonal side cells must be in the field. Stair steps are
			# already validated by the field itself.
			if offset.y == 0 and offset.x != 0 and offset.z != 0:
				var side_a: Vector3i = current + Vector3i(offset.x, 0, 0)
				var side_b: Vector3i = current + Vector3i(0, 0, offset.z)

				if not field.has(side_a) or not field.has(side_b):
					continue

			var cost: float = float(field[neighbour])

			if cost >= best_cost - 0.0001:
				continue

			best_cell = neighbour
			best_cost = cost

		if best_cell == current:
			break

		current = best_cell
		current_cost = best_cost
		path.append(current)

	return path
