extends Node

## Crowd solver.
##
## Two jobs, both done in one pass over a spatial hash:
##   1. Build the neighbour hash used by the agent-level force model.
##   2. Evaluate the pairwise Social Force Model once per pair and apply the
##      result to BOTH agents. Evaluating the pair centrally (instead of each
##      agent sampling its own capped neighbour list) removes order-dependent
##      truncation: if A interacts with B, B interacts with A in the same pass.
##
## Note on reciprocity: the anisotropic weight is per-agent, so A's and B's
## psychological forces differ in magnitude (as in Helbing's model; it is not
## momentum-conserving). Body contact and friction ARE equal and opposite.
##
## Model: Helbing & Molnar (1995), Helbing/Farkas/Vicsek (2000).
##   f_ij = [A exp((r_ij - d_ij)/B) * w_ij] n_ij
##        + [k g(r_ij - d_ij)] n_ij
##        + [kappa g(r_ij - d_ij) (dv_ji . t_ij)] t_ij
## with the anisotropic weight
##   w_ij = lambda + (1 - lambda) (1 + cos(phi_ij)) / 2
## where phi_ij is the angle between agent i's desired direction and the
## direction towards agent j. Contact (second and third terms) only acts when
## the bodies overlap (g > 0); a normal dashpot is added for numerical damping.
##
## Parameters and their provenance are documented in docs/SIMULATION_MODEL.md.

@export_group("Spatial Hash")
## Hash cell size. Must be at least as large as the interaction cutoff, or a
## pair two cells apart could be missed by the 3x3 sweep.
@export var cell_size: float = 1.5
## Force evaluation interval. Physics runs at 30 Hz, so 1/30 evaluates every
## tick. Raise it (lower rate) only for a documented performance trade.
@export var solve_interval: float = 1.0 / 30.0
## Radius used for the per-agent density measurement.
@export var density_radius: float = 1.4
## Maximum vertical separation for two agents to count as part of the same
## local crowd. One voxel is 1 m, so 0.9 m excludes agents on the floor above
## while still counting people on adjacent stair steps.
@export var density_vertical_tolerance: float = 0.9

@export_group("Social Force - Helbing 1995/2000")
## Strength of the psychological repulsion, newtons.
@export var repulsion_a: float = 2000.0
## Range of the psychological repulsion, metres.
@export var repulsion_b: float = 0.08
## Anisotropy factor lambda: 0 = full anisotropy, 1 = isotropic.
@export_range(0.0, 1.0, 0.01) var anisotropy: float = 0.35
## Pairs further apart than this are ignored. With B = 0.08 m the force is
## already negligible at 1.2 m, so this is a cost cutoff, not a behaviour knob.
@export var social_cutoff: float = 1.2
## Contact stiffness k, N/m.
@export var contact_stiffness: float = 120000.0
## Tangential contact friction kappa, kg/(m*s).
@export var contact_friction: float = 240000.0
## Normal dashpot ratio. 0 = undamped (oscillates), 0.2 = lightly damped.
@export var contact_damping_ratio: float = 0.2
## Hard clamp so a spawn overlap or a pathological pile cannot launch an agent.
@export var max_agent_acceleration: float = 120.0
## Two agents only interact when their body centres are this close vertically.
## Kept below one voxel so crowds on stacked floors do not push through slabs.
@export var vertical_tolerance: float = 0.9

## Instrumentation for the 600-agent budget.
var last_solve_usec: int = 0
var last_pair_count: int = 0
var last_agent_count: int = 0

# --- Contact-force distribution -------------------------------------------
## Per-agent contact force is a sum of normal contact forces (N). A single peak
## is not enough to judge crowd compression, so the solver keeps a run-wide
## histogram, threshold exposure, and a coarse time series.
const CONTACT_FORCE_BIN_WIDTH: float = 50.0
const CONTACT_FORCE_BIN_COUNT: int = 80
const CONTACT_FORCE_SERIES_INTERVAL: float = 0.5
const CONTACT_FORCE_SERIES_LIMIT: int = 1200
const CONTACT_FORCE_THRESHOLDS: Array[float] = [500.0, 1000.0, 2000.0, 3000.0]
var _contact_force_hist: PackedInt32Array = PackedInt32Array()
var _contact_force_samples: int = 0
var _contact_force_zero_samples: int = 0
var _contact_force_sum: float = 0.0
var _contact_force_peak: float = 0.0
var _contact_force_peak_time: float = 0.0
var _contact_force_agent_seconds: float = 0.0
var _contact_force_above: PackedFloat64Array = PackedFloat64Array()
var _contact_series: Array[Dictionary] = []
var _contact_series_accum: float = 0.0
var _contact_series_elapsed: float = 0.0
var _contact_series_peak: float = 0.0
var _contact_series_sum: float = 0.0
var _contact_series_samples: int = 0

var grid: Dictionary = {} # Vector2i cell -> Array[int] (indices into _agents)
var npc_count: int = 0

var _timer: float = 0.0

# Per-solve scratch arrays. Reused to avoid per-tick allocation.
var _agents: Array = []
var _pos: Array[Vector3] = []
var _radius: Array[float] = []
var _mass: Array[float] = []
var _desired: Array[Vector3] = []
var _vel: Array[Vector3] = []
var _accel: Array[Vector3] = []
var _contact_force: Array[float] = []
var _overlap: Array[int] = []
var _neighbours: Array[int] = []

const FORWARD_CELLS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(1, 1),
	Vector2i(-1, 1),
]


func _ready() -> void:
	process_physics_priority = -100
	reset_contact_force_stats()

	if social_cutoff > cell_size:
		push_warning(
			"CrowdManager: social_cutoff (%.2f) exceeds cell_size (%.2f); "
			% [social_cutoff, cell_size]
			+ "pairs two cells apart would be missed."
		)


func _physics_process(delta: float) -> void:
	_timer += delta

	if _timer < solve_interval:
		return

	# Use the accumulated step so the solver is frame-rate independent.
	var step: float = _timer
	_timer = 0.0
	_solve(step)


func _solve(step: float) -> void:
	var start_usec: int = Time.get_ticks_usec()
	var npcs: Array[Node] = get_tree().get_nodes_in_group("npc")

	_clear_scratch()

	for npc: Node in npcs:
		if npc == null or not is_instance_valid(npc):
			continue

		if not npc.has_method("get_body_radius"):
			continue

		_agents.append(npc)
		_pos.append(npc.global_position)
		_radius.append(float(npc.get_body_radius()))
		_mass.append(maxf(1.0, float(npc.get_body_mass())))

		var desired: Vector3 = npc.get_desired_direction()

		# Normalise once per agent instead of once per pair.
		if desired.length_squared() > 0.0001:
			desired = desired.normalized()
		else:
			desired = Vector3.ZERO

		_desired.append(desired)
		_vel.append(npc.get_flat_velocity())
		_accel.append(Vector3.ZERO)
		_contact_force.append(0.0)
		_overlap.append(0)
		_neighbours.append(0)

	npc_count = _agents.size()
	last_agent_count = npc_count

	_rebuild_grid()

	var pairs: int = 0
	var keys: Array = grid.keys()

	for cell: Vector2i in keys:
		var list: Array = grid[cell]

		for i in range(list.size()):
			for j in range(i + 1, list.size()):
				_evaluate_pair(list[i], list[j])
				pairs += 1

		for offset: Vector2i in FORWARD_CELLS:
			var other: Array = grid.get(cell + offset, [])

			for i: int in list:
				for j: int in other:
					_evaluate_pair(i, j)
					pairs += 1

	last_pair_count = pairs

	var density_area: float = PI * density_radius * density_radius

	for i in range(_agents.size()):
		var accel: Vector3 = _accel[i].limit_length(max_agent_acceleration)
		var density: float = float(_neighbours[i]) / density_area
		_agents[i].apply_social_forces(
			accel,
			_contact_force[i],
			_overlap[i],
			density
		)

	_record_contact_force_stats(step)
	last_solve_usec = Time.get_ticks_usec() - start_usec


func _record_contact_force_stats(step: float) -> void:
	var count: int = _agents.size()

	if count == 0:
		return

	if _contact_force_hist.is_empty():
		reset_contact_force_stats()

	var tick_peak: float = 0.0
	var tick_sum: float = 0.0
	var above_tick: PackedInt32Array = PackedInt32Array()
	above_tick.resize(CONTACT_FORCE_THRESHOLDS.size())

	for index: int in range(count):
		var force: float = _contact_force[index]
		tick_sum += force

		if force > tick_peak:
			tick_peak = force

		if force > _contact_force_peak:
			_contact_force_peak = force
			_contact_force_peak_time = _contact_series_elapsed + step

		if force <= 0.0:
			_contact_force_zero_samples += 1
		else:
			var bin: int = mini(int(force / CONTACT_FORCE_BIN_WIDTH), CONTACT_FORCE_BIN_COUNT - 1)
			_contact_force_hist[bin] += 1

		for t: int in range(CONTACT_FORCE_THRESHOLDS.size()):
			if force > CONTACT_FORCE_THRESHOLDS[t]:
				above_tick[t] += 1

	_contact_force_samples += count
	_contact_force_sum += tick_sum
	_contact_force_agent_seconds += float(count) * step

	for t: int in range(CONTACT_FORCE_THRESHOLDS.size()):
		_contact_force_above[t] += float(above_tick[t]) * step

	_contact_series_accum += step
	_contact_series_peak = maxf(_contact_series_peak, tick_peak)
	_contact_series_sum += tick_sum
	_contact_series_samples += count
	_contact_series_elapsed += step

	if _contact_series_accum < CONTACT_FORCE_SERIES_INTERVAL:
		return

	if _contact_series.size() < CONTACT_FORCE_SERIES_LIMIT:
		_contact_series.append({
			"t": _contact_series_elapsed,
			"peak": _contact_series_peak,
			"mean": (
				_contact_series_sum
				/ float(maxi(_contact_series_samples, 1))
			),
		})

	_contact_series_accum = 0.0
	_contact_series_peak = 0.0
	_contact_series_sum = 0.0
	_contact_series_samples = 0


func reset_contact_force_stats() -> void:
	_contact_force_hist.resize(CONTACT_FORCE_BIN_COUNT)
	_contact_force_hist.fill(0)
	_contact_force_samples = 0
	_contact_force_zero_samples = 0
	_contact_force_sum = 0.0
	_contact_force_peak = 0.0
	_contact_force_peak_time = 0.0
	_contact_force_agent_seconds = 0.0
	_contact_force_above.resize(CONTACT_FORCE_THRESHOLDS.size())
	_contact_force_above.fill(0.0)
	_contact_series.clear()
	_contact_series_accum = 0.0
	_contact_series_peak = 0.0
	_contact_series_sum = 0.0
	_contact_series_samples = 0
	_contact_series_elapsed = 0.0


func _contact_percentile(fraction: float, include_zero: bool = true) -> float:
	var zero_count: int = _contact_force_zero_samples if include_zero else 0
	var total: int = _contact_force_samples

	if not include_zero:
		total -= _contact_force_zero_samples

	if total <= 0:
		return 0.0

	var target: float = clampf(fraction, 0.0, 1.0) * float(total)

	if target <= float(zero_count):
		return 0.0

	target -= float(zero_count)
	var cumulative: int = 0

	for index: int in range(CONTACT_FORCE_BIN_COUNT):
		cumulative += _contact_force_hist[index]

		if cumulative >= int(ceil(target)):
			return minf(
				(float(index) + 0.5) * CONTACT_FORCE_BIN_WIDTH,
				float(CONTACT_FORCE_BIN_COUNT) * CONTACT_FORCE_BIN_WIDTH
			)

	return float(CONTACT_FORCE_BIN_COUNT) * CONTACT_FORCE_BIN_WIDTH


func get_contact_force_stats() -> Dictionary:
	var above := {}

	for index: int in range(CONTACT_FORCE_THRESHOLDS.size()):
		above[str(int(CONTACT_FORCE_THRESHOLDS[index]))] = _contact_force_above[index]

	return {
		"peak_force": _contact_force_peak,
		"peak_time": _contact_force_peak_time,
		"mean_force": _contact_force_sum / float(maxi(_contact_force_samples, 1)),
		"p50": _contact_percentile(0.50),
		"p90": _contact_percentile(0.90),
		"p95": _contact_percentile(0.95),
		"p99": _contact_percentile(0.99),
		"p50_loaded": _contact_percentile(0.50, false),
		"p90_loaded": _contact_percentile(0.90, false),
		"p95_loaded": _contact_percentile(0.95, false),
		"p99_loaded": _contact_percentile(0.99, false),
		"samples": _contact_force_samples,
		"zero_samples": _contact_force_zero_samples,
		"nonzero_samples": _contact_force_samples - _contact_force_zero_samples,
		"nonzero_fraction": (
			1.0 - float(_contact_force_zero_samples)
			/ float(maxi(_contact_force_samples, 1))
		),
		"agent_seconds": _contact_force_agent_seconds,
		"agent_seconds_above": above,
		"series": _contact_series.duplicate(true),
	}


func _clear_scratch() -> void:
	_agents.clear()
	_pos.clear()
	_radius.clear()
	_mass.clear()
	_desired.clear()
	_vel.clear()
	_accel.clear()
	_contact_force.clear()
	_overlap.clear()
	_neighbours.clear()
	grid.clear()


func _rebuild_grid() -> void:
	for i in range(_agents.size()):
		var cell: Vector2i = position_to_cell(_pos[i])

		if not grid.has(cell):
			grid[cell] = []

		grid[cell].append(i)


## One pairwise evaluation. Both agents are always updated together, even when
## their anisotropy weights differ (the Helbing weight is per-agent by design).
func _evaluate_pair(i: int, j: int) -> void:
	var delta: Vector3 = _pos[i] - _pos[j]
	var vertical: float = absf(delta.y)

	if vertical > vertical_tolerance:
		return

	delta.y = 0.0
	var distance_sq: float = delta.length_squared()
	var radius_sum: float = _radius[i] + _radius[j]
	# Include density_radius so the neighbour count is measured over the same
	# area the per-agent density uses, even though the force is negligible
	# beyond social_cutoff.
	var reach: float = maxf(
		maxf(social_cutoff, radius_sum),
		density_radius
	)

	if distance_sq > reach * reach:
		return

	var distance: float = sqrt(maxf(distance_sq, 1e-6))
	var normal: Vector3 = delta / distance

	# Density is measured on the same sweep; count the neighbour on both sides.
	if distance <= density_radius:
		_neighbours[i] += 1
		_neighbours[j] += 1

	# Beyond social_cutoff the psychological and contact terms are negligible
	# (with B = 0.08 m the repulsion has decayed by e^-5 or more), so the
	# remaining work is only the density count above.
	if distance > social_cutoff:
		return

	# --- psychological repulsion -------------------------------------------
	var expo: float = exp(
		clampf((radius_sum - distance) / maxf(repulsion_b, 1e-4), -20.0, 8.0)
	)
	var magnitude: float = minf(
		repulsion_a * expo,
		repulsion_a * 8.0
	)

	var ea: Vector3 = _desired[i]
	var eb: Vector3 = _desired[j]
	var cos_a: float = 0.0
	var cos_b: float = 0.0

	if ea.length_squared() > 0.0001:
		cos_a = clampf(-normal.dot(ea), -1.0, 1.0)
	if eb.length_squared() > 0.0001:
		cos_b = clampf(normal.dot(eb), -1.0, 1.0)

	var weight_a: float = anisotropy + (1.0 - anisotropy) * 0.5 * (1.0 + cos_a)
	var weight_b: float = anisotropy + (1.0 - anisotropy) * 0.5 * (1.0 + cos_b)

	var force_a: Vector3 = normal * (magnitude * weight_a)
	var force_b: Vector3 = -normal * (magnitude * weight_b)
	var contact_force_sum: float = 0.0

	# --- contact body force (only when overlapping) ------------------------
	var overlap: float = radius_sum - distance

	if overlap > 0.0:
		_overlap[i] += 1
		_overlap[j] += 1

		var normal_force: float = contact_stiffness * overlap
		var tangent: Vector3 = Vector3(-normal.z, 0.0, normal.x)
		var relative: Vector3 = _vel[j] - _vel[i]
		var tangential_speed: float = relative.dot(tangent)
		var friction: float = contact_friction * overlap * tangential_speed

		# Equal and opposite contact force preserves momentum.
		var contact: Vector3 = (
			normal * normal_force
			+ tangent * friction
		)

		# Normal dashpot. v_an is the relative velocity along the contact normal.
		var effective_mass: float = 2.0 * _mass[i] * _mass[j] / (_mass[i] + _mass[j])
		var damping: float = (
			2.0
			* contact_damping_ratio
			* sqrt(contact_stiffness * effective_mass)
		)
		var v_an: float = normal.dot(_vel[i] - _vel[j])
		contact += normal * (-damping * v_an)

		contact = contact.limit_length(contact_stiffness * 2.0)
		force_a += contact
		force_b -= contact
		contact_force_sum = normal_force

	_accel[i] += force_a / _mass[i]
	_accel[j] += force_b / _mass[j]
	_contact_force[i] += contact_force_sum
	_contact_force[j] += contact_force_sum


# ---------------------------------------------------------------------------
# PUBLIC QUERIES
# ---------------------------------------------------------------------------

## Nearest neighbours from the last solve. Applies the same horizontal radius
## and vertical band as the density query, so a caller never receives agents on
## another floor. When max_results is given the nearest are kept.
func get_nearby_npcs(
	position: Vector3,
	max_results: int = -1,
	query_radius: float = 2.0
) -> Array[CharacterBody3D]:
	var result: Array[CharacterBody3D] = []
	var span: int = maxi(1, int(ceil(query_radius / cell_size)))
	var center: Vector2i = position_to_cell(position)
	var radius_sq: float = query_radius * query_radius

	for x: int in range(-span, span + 1):
		for z: int in range(-span, span + 1):
			var list: Array = grid.get(center + Vector2i(x, z), [])

			for index: int in list:
				if index < 0 or index >= _agents.size():
					continue

				var npc: Variant = _agents[index]

				if npc == null or not is_instance_valid(npc):
					continue

				if not (npc is CharacterBody3D):
					continue

				var difference: Vector3 = npc.global_position - position

				if absf(difference.y) > density_vertical_tolerance:
					continue

				difference.y = 0.0

				if difference.length_squared() > radius_sq:
					continue

				result.append(npc)

	if max_results > 0 and result.size() > max_results:
		var origin: Vector3 = position
		result.sort_custom(
			func(a: CharacterBody3D, b: CharacterBody3D) -> bool:
				return (
					a.global_position.distance_squared_to(origin)
					< b.global_position.distance_squared_to(origin)
				)
		)
		result.resize(max_results)

	return result


## Count of agents within query_radius (not a capped neighbour count).
func get_density(position: Vector3, query_radius: float = 2.0) -> float:
	return float(get_density_count(position, query_radius))


func get_density_count(position: Vector3, query_radius: float = 2.0) -> int:
	var span: int = maxi(1, int(ceil(query_radius / cell_size)))
	var center: Vector2i = position_to_cell(position)
	var radius_sq: float = query_radius * query_radius
	var count: int = 0

	for x: int in range(-span, span + 1):
		for z: int in range(-span, span + 1):
			var list: Array = grid.get(center + Vector2i(x, z), [])

			for index: int in list:
				if index < 0 or index >= _agents.size():
					continue

				var npc: Variant = _agents[index]

				if npc == null or not is_instance_valid(npc):
					continue

				var difference: Vector3 = npc.global_position - position

				# Crowding is a same-floor property. Counting agents on the
				# floor above would make exit choice and crush damage wrong in
				# stacked buildings.
				if absf(difference.y) > density_vertical_tolerance:
					continue

				difference.y = 0.0

				if difference.length_squared() <= radius_sq:
					count += 1

	return count


## People per square metre inside query_radius.
func get_density_per_m2(position: Vector3, query_radius: float = 2.0) -> float:
	var area: float = PI * query_radius * query_radius
	return float(get_density_count(position, query_radius)) / area


func position_to_cell(position: Vector3) -> Vector2i:
	return Vector2i(
		floori(position.x / cell_size),
		floori(position.z / cell_size)
	)


func get_stats() -> Dictionary:
	return {
		"agents": last_agent_count,
		"pairs": last_pair_count,
		"solve_usec": last_solve_usec,
		"cells": grid.size(),
	}
