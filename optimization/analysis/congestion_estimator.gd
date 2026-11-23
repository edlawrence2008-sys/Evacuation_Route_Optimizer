class_name CongestionEstimator
extends RefCounted

## Predicts whether a proposed assignment overloads the corridors it uses.
##
## The model is a deterministic demand-to-capacity heuristic, not a density
## measurement and not a queueing theorem. Two corrections matter for ranking:
##
## 1. **Peak platoon flow, not route-average flow.** A cohort is a compact
##    spatial bucket; it crosses a cell over the time its own length takes to
##    pass, not over the whole route. `count / travel_time` underestimates the
##    rate on long routes by a large factor, which made the congestion term
##    nearly irrelevant. The crossing time is therefore
##    `(platoon_length + cell_length) / speed`, floored by the route travel time.
## 2. **Agent-seconds.** A delay of one second is suffered by every member of
##    the cohort, so the term is multiplied by the cohort count. The objective
##    then normalises it per agent, making it comparable to the makespan.
##
## Capacity is `q_max * lane_width_m` persons/second, where the lane width is a
## coarse count of open downhill neighbours times the nav cell size. It is a
## heuristic corridor capacity, not a measured door width.

const DEFAULT_Q_MAX: float = 1.3       # persons / (m * s), dense walking crowd
const DEFAULT_AGENT_SPACING: float = 0.6  # m front-to-back in a compact platoon
const MIN_TRAVEL_TIME: float = 0.5     # s; avoids dividing by zero at an exit
const MIN_ROUTE_DISTANCE: float = 0.5  # m; cohorts already at the exit add no load
const MAX_LANE_WIDTH_CELLS: int = 3


## Cell loads for a complete assignment, plus the route per cohort.
## Returns {loads: {Vector3i: persons/s}, routes: [{cohort_index, exit_id, route,
## travel_time, speed, count}]}. The caller can reuse `loads` to price a
## candidate route incrementally (greedy congestion and the flow priors).
func build_loads(
	assignments: Array,
	cohorts: Array,
	exit_ids: Array,
	analyzer: PathAnalyzer,
	q_max: float,
	cell_size: Vector3,
	agent_spacing: float = DEFAULT_AGENT_SPACING
) -> Dictionary:
	var loads: Dictionary = {}
	var routes: Array = []
	var effective_q_max: float = maxf(q_max, 0.1)
	var spacing: float = maxf(agent_spacing, 0.1)
	var cell_length: float = maxf(cell_size.x, 0.1)

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
		var distance: float = maxf(float(route.get("distance", 0.0)), cell_length)
		var speed: float = maxf(distance / travel_time, 0.2)
		var count: int = maxi(int(cohort.get("count", 0)), 1)
		var cells: Array = route.get("cells", [])

		for cell: Vector3i in cells:
			var width: int = analyzer.get_cell_lane_width(exit_id, cell)
			var platoon_depth: float = platoon_depth_for(count, width, spacing)
			var crossing_time: float = (platoon_depth + cell_length) / speed
			var rate: float = float(count) / maxf(travel_time, maxf(crossing_time, MIN_TRAVEL_TIME))
			loads[cell] = float(loads.get(cell, 0.0)) + rate

		routes.append({
			"cohort_index": index,
			"exit_id": exit_id,
			"route": route,
			"travel_time": travel_time,
			"speed": speed,
			"count": count,
			"effective_q_max": effective_q_max,
		})

	return {"loads": loads, "routes": routes}


## Delay of one cohort on one route given the current cell loads.
## Returns {delay (agent-seconds), max_ratio, overloaded_cells}.
func estimate_route_delay(
	cohort: Dictionary,
	exit_id: String,
	route: Dictionary,
	loads: Dictionary,
	analyzer: PathAnalyzer,
	q_max: float,
	cell_size: Vector3,
	heat: Dictionary = {},
	agent_spacing: float = DEFAULT_AGENT_SPACING,
	add_own_flow: bool = false
) -> Dictionary:
	if not bool(route.get("reachable", false)):
		return {"delay": 0.0, "max_ratio": 0.0, "overloaded_cells": 0}

	if float(route.get("distance", 0.0)) < MIN_ROUTE_DISTANCE:
		return {"delay": 0.0, "max_ratio": 0.0, "overloaded_cells": 0}

	var count: int = maxi(int(cohort.get("count", 0)), 1)
	var cells: Array = route.get("cells", [])
	var effective_q_max: float = maxf(q_max, 0.1)
	var spacing: float = maxf(agent_spacing, 0.1)
	var cell_length: float = maxf(cell_size.x, 0.1)
	var travel_time: float = maxf(float(route.get("time", 0.0)), MIN_TRAVEL_TIME)
	var distance: float = maxf(float(route.get("distance", 0.0)), cell_length)
	var speed: float = maxf(distance / travel_time, 0.2)
	var dt: float = cell_length / speed
	var delay: float = 0.0
	var max_ratio: float = 0.0
	var overloaded: int = 0

	for cell: Vector3i in cells:
		var width: int = analyzer.get_cell_lane_width(exit_id, cell)
		var platoon_depth: float = platoon_depth_for(count, width, spacing)
		var crossing_time: float = (platoon_depth + cell_length) / speed
		var rate: float = float(count) / maxf(travel_time, maxf(crossing_time, MIN_TRAVEL_TIME))
		var capacity: float = effective_q_max * float(width) * cell_length
		var existing: float = float(loads.get(cell, 0.0))
		var own: float = rate if add_own_flow else 0.0
		var load_ratio: float = (existing + own) / maxf(capacity, 0.0001)
		var heat_ratio: float = clampf(float(heat.get(cell, 0.0)), 0.0, 1.0)
		var ratio: float = load_ratio + heat_ratio * 0.5

		if ratio > max_ratio:
			max_ratio = ratio

		if ratio > 1.0:
			overloaded += 1

		# `add_own_flow` is false for a full evaluation (build_loads already
		# counted this route's rate) and true when pricing a candidate route
		# against loads built from the cohorts already assigned.
		delay += dt * (ratio - 1.0) * float(count)

	return {
		"delay": maxf(delay, 0.0),
		"max_ratio": max_ratio,
		"overloaded_cells": overloaded,
	}


## Full evaluation of an assignment.
func evaluate(
	assignments: Array,
	cohorts: Array,
	exit_ids: Array,
	analyzer: PathAnalyzer,
	q_max: float = DEFAULT_Q_MAX,
	cell_size: Vector3 = Vector3.ONE,
	heat: Dictionary = {},
	agent_spacing: float = DEFAULT_AGENT_SPACING
) -> Dictionary:
	var built: Dictionary = build_loads(
		assignments,
		cohorts,
		exit_ids,
		analyzer,
		q_max,
		cell_size,
		agent_spacing
	)
	var loads: Dictionary = built.get("loads", {})
	var routes: Array = built.get("routes", [])
	var delay: float = 0.0
	var max_ratio: float = 0.0
	var overloaded: Dictionary = {}
	var per_route: Array = []

	for entry: Dictionary in routes:
		var index: int = int(entry.get("cohort_index", -1))
		var cohort: Dictionary = cohorts[index] if index >= 0 and index < cohorts.size() else {}
		var route: Dictionary = entry.get("route", {})
		var estimate: Dictionary = estimate_route_delay(
			cohort,
			String(entry.get("exit_id", "")),
			route,
			loads,
			analyzer,
			q_max,
			cell_size,
			heat,
			agent_spacing
		)
		delay += float(estimate.get("delay", 0.0))
		max_ratio = maxf(max_ratio, float(estimate.get("max_ratio", 0.0)))

		if int(estimate.get("overloaded_cells", 0)) > 0:
			overloaded[index] = true

		per_route.append({
			"cohort_index": index,
			"exit_id": String(entry.get("exit_id", "")),
			"delay": float(estimate.get("delay", 0.0)),
			"max_ratio": float(estimate.get("max_ratio", 0.0)),
		})

	return {
		"delay": delay,
		"max_ratio": max_ratio,
		"overloaded_cells": overloaded.size(),
		"loaded_cells": loads.size(),
		"loads": loads,
		"per_route": per_route,
	}


## Deterministic platoon depth. A narrow cell forces the group into a single
## file; a wide one lets it spread laterally, so a square-root depth is closer
## to the occupied length than `count * spacing`.
static func platoon_depth_for(count: int, lane_width_cells: int, spacing: float) -> float:
	var width_class: int = clampi(lane_width_cells, 1, MAX_LANE_WIDTH_CELLS)

	if width_class <= 2:
		return float(maxi(count - 1, 1)) * spacing

	var side: float = sqrt(float(maxi(count, 1)))
	return maxf(side - 1.0, 1.0) * spacing
