class_name CongestionEstimator
extends RefCounted

## Predicts whether a proposed assignment overloads the corridors it uses.
##
## For every cell crossed by a chosen route, demand is the sum of the arrival
## rates of the cohorts using it (agents per second). Capacity is a specific
## flow multiplied by a coarse lane width derived from the cost field. The
## result is a delay in seconds, not a density measurement:
##
##   delay = sum over cohorts, cells of  dt * max(0, demand / capacity - 1)
##
## This is a deterministic demand-to-capacity heuristic. It ranks candidate
## assignments; the simulator measures what actually happens.

const DEFAULT_Q_MAX: float = 1.3       # persons / (m * s), dense walking crowd
const MIN_TRAVEL_TIME: float = 0.5     # s; avoids dividing by zero at an exit
const MIN_ROUTE_DISTANCE: float = 0.5  # m; cohorts already at the exit add no load


func evaluate(
	assignments: Array,
	cohorts: Array,
	exit_ids: Array,
	analyzer: PathAnalyzer,
	q_max: float = DEFAULT_Q_MAX,
	cell_size: Vector3 = Vector3.ONE
) -> Dictionary:
	var loads: Dictionary = {}
	var used: Array = []
	var effective_q_max: float = maxf(q_max, 0.1)
	var step_length: float = maxf(cell_size.x, 0.1)

	for index: int in range(cohorts.size()):
		var exit_index: int = int(assignments[index]) if index < assignments.size() else -1

		if exit_index < 0 or exit_index >= exit_ids.size():
			continue

		var cohort: Dictionary = cohorts[index]
		var exit_id: String = exit_ids[exit_index]
		var route: Dictionary = analyzer.get_route(cohort, exit_id)

		if not bool(route.get("reachable", false)):
			continue

		if float(route.get("distance", 0.0)) < MIN_ROUTE_DISTANCE:
			continue

		var travel_time: float = maxf(float(route.get("time", 0.0)), MIN_TRAVEL_TIME)
		var agent_rate: float = float(cohort.get("count", 0)) / travel_time
		var cells: Array = route.get("cells", [])

		for cell: Vector3i in cells:
			loads[cell] = float(loads.get(cell, 0.0)) + agent_rate

		used.append({
			"cohort_index": index,
			"exit_id": exit_id,
			"route": route,
			"travel_time": travel_time,
		})

	var delay: float = 0.0
	var max_ratio: float = 0.0
	var overloaded: Dictionary = {}

	for entry: Dictionary in used:
		var route: Dictionary = entry["route"]
		var cells: Array = route.get("cells", [])
		var distance: float = float(route.get("distance", 0.0))
		var travel_time: float = float(entry["travel_time"])
		var speed: float = maxf(distance / maxf(travel_time, 0.0001), 0.2)
		var dt: float = step_length / speed

		for cell: Vector3i in cells:
			var width: int = analyzer.get_cell_lane_width(entry["exit_id"], cell)
			var capacity: float = effective_q_max * float(width)
			var ratio: float = float(loads.get(cell, 0.0)) / maxf(capacity, 0.0001)

			if ratio > max_ratio:
				max_ratio = ratio

			if ratio > 1.0:
				delay += dt * (ratio - 1.0)
				overloaded[cell] = true

	return {
		"delay": delay,
		"max_ratio": max_ratio,
		"overloaded_cells": overloaded.size(),
		"loaded_cells": loads.size(),
	}
