class_name OptimizerBridge
extends Node

const OPTIMIZER_OVERLAY := preload(
	"res://scripts/optimization/optimizer_overlay.gd"
)

## Simulation-side adapter for the optimization layer.
##
## Responsibilities:
##   - capture a read-only `SimulationSnapshot` from the live scene,
##   - call the pure `OptimizerManager`,
##   - validate the result against the current world,
##   - apply accepted assignments through `Member.set_optimizer_assignment()`,
##   - record the estimate and the application outcome.
##
## It never changes crowd physics, navigation or exit admission. With the
## optimizer disabled it does nothing, so the baseline run is unchanged.
##
## The solve is synchronous and can take hundreds of milliseconds at 600
## agents / 40 cohorts (docs/OPTIMIZER.md §8.4). `request_solve()` defers it to
## an idle frame, but it still blocks that frame; it does not run inside a
## physics tick.

signal state_changed(text: String)
signal result_ready(result: OptimizationResult, applied: int, skipped: int)

## Agents closer than this to the exit they are already heading for are not
## reassigned in a later solve. Avoids late reroutes at the doorway.
const COMMIT_RADIUS: float = 4.0
const AUTO_SOLVE_DELAY: float = 1.0
## A late spawn is adopted by the nearest cohort of the last result only when it
## appears within this radius. Farther spawns are queued for the next solve.
const ADOPT_RADIUS: float = 8.0
## Never solve twice inside this window, even when a trigger fires.
const RESOLVE_MIN_GAP: float = 2.0
## A spawn wave this large (or a quiet period after any spawn) triggers a solve.
const SPAWN_BATCH_TRIGGER: int = 8
const SPAWN_DEBOUNCE: float = 1.5
## Growing queue pressure this large above the last solve's baseline triggers a
## solve between periodic intervals.
const QUEUE_TRIGGER_DELTA: int = 4
const LIVE_POLL_INTERVAL: float = 0.5
## Saved-plan application waits this long after Start so spawners/importers have
## created the agents the plan refers to. A plan can also be applied manually.
const PLAN_APPLY_DELAY: float = 0.5

var enabled: bool = false
var auto_solve: bool = true
## Re-solve while a run is active so assignments follow queues and late arrivals.
var re_solve_enabled: bool = true
## Periodic interval in seconds. Ignored when `re_solve_enabled` is false.
var re_solve_interval: float = 15.0
## Wait this long after Start before the first solve. Previously fixed at 1 s,
## which planned before pre-movement delays had expired.
var first_solve_delay: float = AUTO_SOLVE_DELAY
## When true, the first solve waits until the configured spawn quota is met
## instead of using `first_solve_delay`. Useful for 600-agent spawner fixtures.
var solve_on_spawn_complete: bool = false
## Do not replace an existing exit assignment unless the new plan improves the
## estimated cost by at least this fraction. Prevents cohort oscillation between
## near-tied exits across periodic solves.
var hysteresis_enabled: bool = true
var hysteresis_ratio: float = 0.10
## Draw cohort -> exit lines, agent exit colours and exit load labels.
var overlay_enabled: bool = false
var algorithm: String = OptimizationRequest.ALGORITHM_GREEDY
var mode: String = OptimizationRequest.MODE_BALANCED
var cohort_size: float = 4.0
var max_cohorts: int = 60
var weights: Dictionary = {}
var parameters: Dictionary = {
	"max_combinations": 250000,
	"time_budget_ms": 250.0,
	"local_search_passes": 4,
	"aco_ants": 16,
	"aco_iterations": 40,
	"pso_swarm": 24,
	"pso_iterations": 60,
}

var last_result: OptimizationResult
var last_applied: int = 0
var last_skipped: int = 0
var last_unchanged: int = 0
var last_changed: int = 0
var last_held: int = 0
var last_commitment_skipped: int = 0
var last_rejection: String = ""
var solve_count: int = 0
var adopted_spawns: int = 0
var plan_active: bool = false
var last_plan_name: String = ""

var _startup_plan: EvacuationPlan = null
var _active_plan: EvacuationPlan = null
var _plan_pending: bool = false
var _plan_apply_at: float = 0.0
var _last_applied_cost: float = INF
var _last_applied_environment: int = -1
var _spawn_complete_solved: bool = false

var _solving: bool = false
var _auto_pending: bool = false
var _auto_at: float = 0.0
var _serial_to_node: Dictionary = {}
var _connected_grid: NavGridMap
var _next_resolve_at: float = 0.0
var _last_solved_at: float = -INF
var _last_solved_environment: int = -1
var _last_exit_signature: String = ""
var _pending_spawns: int = 0
var _spawn_solve_at: float = 0.0
var _queue_baseline: int = 0
var _queue_total_cached: int = 0
var _exit_signature_cached: String = ""
var _poll_at: float = 0.0
var _overlay: Node3D = null
## A structural collapse schedules a solve at the next allowed moment instead of
## waiting for the periodic interval.
var _disruption_pending: bool = false
var _disruption_at: float = 0.0
var _disruption_count: int = 0
var _disruption_cells: int = 0


func _ready() -> void:
	process_priority = 40
	add_to_group("optimizer_bridge")
	GlobalData.spawning_started.connect(_on_run_started)
	GlobalData.spawning_reset.connect(_on_run_reset)
	GlobalData.agent_spawned.connect(_on_agent_spawned)
	_apply_runtime_defaults()
	_sync_recorder_configuration()
	_publish_state("off")


func _apply_runtime_defaults() -> void:
	var defaults: Dictionary = RuntimeExports.get_default_section("optimizer")

	if defaults.is_empty():
		return

	if defaults.has("algorithm"):
		algorithm = String(defaults["algorithm"])
	if defaults.has("mode"):
		mode = String(defaults["mode"])
	if defaults.has("cohort_size"):
		cohort_size = clampf(float(defaults["cohort_size"]), 1.0, 40.0)
	if defaults.has("max_cohorts"):
		max_cohorts = clampi(int(defaults["max_cohorts"]), 1, 400)
	if defaults.has("auto_solve"):
		auto_solve = bool(defaults["auto_solve"])
	if defaults.has("first_solve_delay"):
		first_solve_delay = clampf(float(defaults["first_solve_delay"]), 0.0, 120.0)
	if defaults.has("solve_on_spawn_complete"):
		solve_on_spawn_complete = bool(defaults["solve_on_spawn_complete"])
	if defaults.has("hysteresis_enabled"):
		hysteresis_enabled = bool(defaults["hysteresis_enabled"])
	if defaults.has("hysteresis_ratio"):
		hysteresis_ratio = clampf(float(defaults["hysteresis_ratio"]), 0.0, 0.9)
	if defaults.has("re_solve_enabled"):
		re_solve_enabled = bool(defaults["re_solve_enabled"])
	if defaults.has("re_solve_interval"):
		re_solve_interval = clampf(
			float(defaults["re_solve_interval"]), 5.0, 120.0
		)
	if defaults.has("overlay_enabled"):
		overlay_enabled = bool(defaults["overlay_enabled"])
	if defaults.get("weights") is Dictionary:
		weights = (defaults["weights"] as Dictionary).duplicate(true)
	if defaults.get("parameters") is Dictionary:
		parameters = (defaults["parameters"] as Dictionary).duplicate(true)
	if defaults.has("enabled"):
		enabled = bool(defaults["enabled"])
		GlobalData.set_optimizer_enabled(enabled)


func _exit_tree() -> void:
	_disconnect_grid()

	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()

	_overlay = null


func _process(_delta: float) -> void:
	if not enabled or _solving:
		return

	var now: float = GlobalData.sim_now()

	if _plan_pending:
		if now >= _plan_apply_at:
			_plan_pending = false

			if _startup_plan != null:
				apply_plan(_startup_plan)

	if _auto_pending:
		if now >= _auto_at:
			_auto_pending = false
			request_solve()
		return

	if not auto_solve:
		return

	_poll_live_state(now)

	if (
		solve_on_spawn_complete
		and not _spawn_complete_solved
		and _pending_spawns == 0
		and _spawners_complete()
	):
		_spawn_complete_solved = true
		request_solve()
		return

	if _should_re_solve(now):
		request_solve()


## Reads exit availability and queue pressure at a low rate. Scanning the
## EvacPoint group every frame would be wasted work during a run.
func _poll_live_state(now: float) -> void:
	if now < _poll_at:
		return

	_poll_at = now + LIVE_POLL_INTERVAL
	_exit_signature_cached = _exit_signature()
	_queue_total_cached = _queue_total()


## True when a finite spawn quota has been reached. Unlimited runs never report
## complete, so the delay policy stays in charge.
func _spawners_complete() -> bool:
	var total: int = GlobalData.get_total_max_spawns()

	if total <= 0:
		return false

	return GlobalData.npcs_spawned >= total


func _should_re_solve(now: float) -> bool:
	if _last_solved_at > -INF and now - _last_solved_at < RESOLVE_MIN_GAP:
		return false

	if _disruption_pending and now >= _disruption_at:
		return true

	if _pending_spawns >= SPAWN_BATCH_TRIGGER:
		return true

	# A spawn burst, or a quiet gap after any spawn, brings unassigned agents
	# into a new solve. The previous 8 m rule left far spawners uncovered.
	if _pending_spawns > 0 and now >= _spawn_solve_at:
		return true

	if GlobalData.environment_version != _last_solved_environment:
		return true

	if _exit_signature_cached != _last_exit_signature:
		return true

	if _queue_total_cached - _queue_baseline >= QUEUE_TRIGGER_DELTA:
		return true

	return re_solve_enabled and now >= _next_resolve_at


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

func set_enabled(value: bool) -> void:
	enabled = value
	GlobalData.set_optimizer_enabled(value)

	if not value:
		_auto_pending = false
		_pending_spawns = 0
		_publish_state("off")

		if _overlay != null and is_instance_valid(_overlay):
			_overlay.call("set_enabled", false)
	else:
		_next_resolve_at = GlobalData.sim_now() + re_solve_interval
		_publish_state("enabled: Start or Run once")

	_sync_recorder_configuration()


func set_algorithm(value: String) -> void:
	if not OptimizationRequest.ALGORITHMS.has(value):
		return

	algorithm = value
	_sync_recorder_configuration()


func set_mode(value: String) -> void:
	if not OptimizationRequest.MODES.has(value):
		return

	mode = value
	weights = {}
	_sync_recorder_configuration()


func set_cohort_size(value: float) -> void:
	cohort_size = clampf(value, 1.0, 40.0)
	_sync_recorder_configuration()


func set_max_cohorts(value: int) -> void:
	max_cohorts = clampi(value, 1, 400)
	_sync_recorder_configuration()


func set_auto_solve(value: bool) -> void:
	auto_solve = value

	if not value:
		_auto_pending = false

	_sync_recorder_configuration()


func set_first_solve_delay(value: float) -> void:
	first_solve_delay = clampf(value, 0.0, 120.0)
	_sync_recorder_configuration()


func set_solve_on_spawn_complete(value: bool) -> void:
	solve_on_spawn_complete = value
	_sync_recorder_configuration()


func set_hysteresis_enabled(value: bool) -> void:
	hysteresis_enabled = value
	_sync_recorder_configuration()


func set_hysteresis_ratio(value: float) -> void:
	hysteresis_ratio = clampf(value, 0.0, 0.9)
	_sync_recorder_configuration()


## Batch runner/console entry point: merge method parameters without replacing
## keys the caller does not mention.
func set_parameters(values: Dictionary) -> void:
	for key: Variant in values.keys():
		parameters[String(key)] = values[key]

	_sync_recorder_configuration()


# ---------------------------------------------------------------------------
# Saved plans
# ---------------------------------------------------------------------------

## Capture the current assignment and the actual route each agent is following.
## Prefer the last optimizer result; if the user has not solved yet, capture the
## agents' current exits (a plan of the local-choice baseline).
func capture_plan(plan_name: String = "") -> EvacuationPlan:
	var tree := get_tree()

	if tree == null:
		return null

	var layout: Dictionary = EvacuationPlan.capture_layout_signature()
	var plan := EvacuationPlan.new()
	plan.name = plan_name if not plan_name.is_empty() else "Plan %s" % Time.get_time_string_from_system()
	plan.created_at = Time.get_datetime_string_from_system(true, true)
	plan.source = "live"
	plan.scene = String(tree.current_scene.scene_file_path) if tree.current_scene != null else ""
	var demo_store := get_node_or_null("/root/DemoStore")
	plan.save_slug = String(demo_store.call("active_save_slug")) if demo_store != null else ""
	plan.rng_seed = GlobalData.rng_seed
	plan.layout_signature = String(layout.get("signature", ""))
	plan.environment_version = GlobalData.environment_version
	plan.exits = layout.get("exits", [])

	if last_result != null:
		plan.algorithm = last_result.algorithm
		plan.mode = last_result.mode
		plan.weights = last_result.detail.get("weights", weights).duplicate(true)
		plan.estimated_cost = last_result.estimated_cost
		plan.estimated_completion_time = last_result.estimated_completion_time
		plan.estimated_average_time = last_result.estimated_average_time
		plan.cohorts = last_result.cohorts.duplicate(true)

		for cohort_value: Variant in plan.cohorts:
			if not cohort_value is Dictionary:
				continue

			var cohort: Dictionary = cohort_value
			cohort["position"] = EvacuationPlan._point_to_array(cohort.get("position", []))
			var members: Array = cohort.get("members", [])
			cohort["route"] = _route_for_serial(int(members[0]) if not members.is_empty() else -1)

		for serial_value: Variant in last_result.agent_exit_assignments.keys():
			var serial := int(serial_value)
			var exit_id := String(last_result.agent_exit_assignments[serial_value])
			var target: Vector3 = last_result.agent_targets.get(serial, _exit_position(exit_id))
			plan.assignments.append(_assignment_row(serial, exit_id, target, _route_for_serial(serial)))
	else:
		var seen: Dictionary = {}

		for node: Node in tree.get_nodes_in_group("npc"):
			if node == null or not is_instance_valid(node) or node.has_meta("evacuated"):
				continue

			if not node.has_method("get_measurement_state"):
				continue

			var state: Dictionary = node.call("get_measurement_state")
			var status := String(state.get("status", ""))
			var exit_id := String(state.get("exit_id", ""))

			if exit_id.is_empty() or status in ["dead", "evacuated"]:
				continue

			var serial := int(state.get("serial", -1))
			seen[serial] = true
			plan.assignments.append(_assignment_row(
				serial,
				exit_id,
				state.get("destination", _exit_position(exit_id)),
				_route_for_serial(serial)
			))

		plan.algorithm = "local_choice"
		plan.mode = "baseline"

		if plan.assignments.is_empty():
			return null

		plan.cohorts = _cohorts_from_assignments(plan.assignments)

	for assignment_value: Variant in plan.assignments:
		if assignment_value is Dictionary:
			var assignment: Dictionary = assignment_value
			assignment["target"] = EvacuationPlan._point_to_array(assignment.get("target", []))

	if plan.assignments.is_empty():
		return null

	plan.notes = "Captured from the live crowd. Routes are the paths active at capture time."
	return plan


## Apply a saved plan now. Returns {ok, applied, skipped, missing, error}.
## A plan made on a different layout is refused unless `force` is true.
func apply_plan(plan: EvacuationPlan, force: bool = false) -> Dictionary:
	if plan == null:
		return {"ok": false, "error": "no plan loaded"}

	var tree := get_tree()

	if tree == null:
		return {"ok": false, "error": "no scene"}

	var current_signature := String(
		EvacuationPlan.capture_layout_signature().get("signature", "")
	)
	var signature_ok := plan.layout_signature.is_empty() or plan.layout_signature == current_signature

	if not signature_ok and not force:
		return {
			"ok": false,
			"error": "plan was captured on a different layout or exit set",
			"layout_mismatch": true,
		}

	var live_exits := _live_exit_ids()
	var live_positions: Dictionary = _live_exit_positions()
	var nodes: Dictionary = {}
	var used_serials: Dictionary = {}
	var authored_cells := 0

	if not plan.authored_route_cells.is_empty():
		authored_cells = RoutePainter.set_cells(plan.authored_route_cells)

	for node: Node in tree.get_nodes_in_group("npc"):
		if node == null or not is_instance_valid(node):
			continue

		if node.has_method("get_measurement_state"):
			var state: Dictionary = node.call("get_measurement_state")
			nodes[int(state.get("serial", -1))] = node

	var applied := 0
	var skipped := 0
	var missing := 0

	for assignment_value: Variant in plan.assignments:
		if not assignment_value is Dictionary:
			continue

		var assignment: Dictionary = assignment_value
		var serial := int(assignment.get("serial", -1))
		var exit_id := String(assignment.get("exit_id", ""))

		if exit_id.is_empty() or not live_exits.has(exit_id):
			skipped += 1
			continue

		var target: Vector3 = live_positions.get(exit_id, Vector3.ZERO)

		if target == Vector3.ZERO:
			skipped += 1
			continue

		var node: Node = nodes.get(serial)

		if node == null and assignment.has("spawn_position"):
			node = _nearest_agent_to(
				EvacuationPlan._point_array(assignment.get("spawn_position", [])),
				3.0,
				used_serials
			)

		if node == null or not is_instance_valid(node):
			missing += 1
			continue

		var state: Dictionary = node.call("get_measurement_state")
		var status := String(state.get("status", ""))

		if status in ["arrived", "queued", "evacuated", "dead"] or bool(state.get("evacuated", false)):
			skipped += 1
			continue

		var route_points: Array = EvacuationPlan._point_array_list(assignment.get("route", []))
		var accepted := false

		if route_points.size() >= 2 and node.has_method("request_evacuation_route"):
			accepted = bool(node.call(
				"request_evacuation_route",
				exit_id,
				target,
				route_points,
				"plan"
			))
		elif node.has_method("set_optimizer_assignment"):
			accepted = bool(node.call("set_optimizer_assignment", exit_id, target))

		if accepted:
			applied += 1
			used_serials[int(state.get("serial", -1))] = true
		else:
			skipped += 1

	plan_active = applied > 0 or authored_cells > 0
	_active_plan = plan if not plan.assignments.is_empty() else null
	last_plan_name = plan.name

	if not plan.assignments.is_empty():
		GlobalData.set_optimizer_enabled(true)
	_publish_state("plan applied: %d agents, %d painted cells | %s" % [applied, authored_cells, plan.name])

	var recorder := get_node_or_null("/root/SimRecorder")

	if recorder != null and recorder.has_method("record_plan_application"):
		recorder.call("record_plan_application", plan.name, 0, {
			"algorithm": plan.algorithm,
			"mode": plan.mode,
			"estimated_cost": plan.estimated_cost,
			"estimated_completion_time": plan.estimated_completion_time,
			"agent_count": applied,
			"cohort_count": plan.cohorts.size(),
			"applied": applied,
			"skipped": skipped,
			"missing": missing,
			"authored_cells": authored_cells,
			"environment_version": GlobalData.environment_version,
			"layout_signature": plan.layout_signature,
		})

	return {
		"ok": applied > 0 or authored_cells > 0,
		"applied": applied,
		"authored_cells": authored_cells,
		"skipped": skipped,
		"missing": missing,
		"error": "" if (applied > 0 or authored_cells > 0) else "no live agent matched the plan",
	}


func set_startup_plan(plan: EvacuationPlan) -> void:
	_startup_plan = plan
	_active_plan = plan if plan != null and not plan.assignments.is_empty() else null


func get_startup_plan() -> EvacuationPlan:
	return _startup_plan


func clear_startup_plan() -> void:
	_startup_plan = null
	_plan_pending = false


func _nearest_agent_to(position: Array, radius: float, used: Dictionary) -> Node:
	if position.size() < 3:
		return null

	var target := Vector3(float(position[0]), float(position[1]), float(position[2]))
	var tree := get_tree()

	if tree == null:
		return null

	var best: Node = null
	var best_distance := radius * radius

	for node: Node in tree.get_nodes_in_group("npc"):
		if node == null or not is_instance_valid(node) or not node is Node3D:
			continue

		if node.has_method("get_measurement_state"):
			var serial := int(node.call("get_measurement_state").get("serial", -1))

			if used.has(serial):
				continue

			var distance := (node as Node3D).global_position.distance_squared_to(target)

			if distance < best_distance:
				best_distance = distance
				best = node

	return best


func _live_exit_positions() -> Dictionary:
	var result: Dictionary = {}
	var tree := get_tree()

	if tree == null:
		return result

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node) or not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")
		result[String(status.get("exit_id", ""))] = (node as Node3D).global_position

	return result


func _route_for_serial(serial: int) -> Array:
	var node: Variant = _serial_to_node.get(serial)

	if node == null or not is_instance_valid(node):
		var tree := get_tree()

		if tree != null:
			for candidate: Node in tree.get_nodes_in_group("npc"):
				if candidate != null and is_instance_valid(candidate) and int(candidate.get("agent_serial")) == serial:
					node = candidate
					break

	if node == null or not is_instance_valid(node) or not node.has_method("get_route_snapshot"):
		return []

	var snapshot: Dictionary = node.call("get_route_snapshot")
	return EvacuationPlan._point_array_list(snapshot.get("path", []))


func _assignment_row(
	serial: int,
	exit_id: String,
	target: Vector3,
	route_points: Array
) -> Dictionary:
	var node: Variant = _serial_to_node.get(serial)
	var spawn_position: Array = []

	if node == null or not is_instance_valid(node):
		var tree := get_tree()

		if tree != null:
			for candidate: Node in tree.get_nodes_in_group("npc"):
				if candidate != null and is_instance_valid(candidate) and int(candidate.get("agent_serial")) == serial:
					node = candidate
					break

	if node != null and is_instance_valid(node) and node is Node3D:
		if node.has_method("get_measurement_state"):
			var state: Dictionary = node.call("get_measurement_state")
			spawn_position = EvacuationPlan._point_to_array(
				state.get("spawn_position", (node as Node3D).global_position)
			)
		else:
			spawn_position = EvacuationPlan._point_to_array((node as Node3D).global_position)

	return {
		"serial": serial,
		"exit_id": exit_id,
		"target": EvacuationPlan._point_to_array(target),
		"spawn_position": spawn_position,
		"route": route_points,
		"route_source": "live" if route_points.size() >= 2 else "straight",
		"reason": "optimizer" if last_result != null else "local_choice",
	}


func _cohorts_from_assignments(assignments: Array) -> Array:
	var groups: Dictionary = {}

	for assignment_value: Variant in assignments:
		if not assignment_value is Dictionary:
			continue

		var assignment: Dictionary = assignment_value
		var exit_id := String(assignment.get("exit_id", ""))
		var position := EvacuationPlan._point_array(assignment.get("spawn_position", []))
		var key := exit_id

		if position.size() >= 3:
			key = "%s:%d:%d" % [
				exit_id,
				int(floor(float(position[0]) / 4.0)),
				int(floor(float(position[2]) / 4.0)),
			]

		if not groups.has(key):
			groups[key] = {
				"cohort_id": groups.size(),
				"position": position,
				"exit_id": exit_id,
				"count": 0,
				"members": [],
				"route": assignment.get("route", []),
			}

		var group: Dictionary = groups[key]
		group["count"] = int(group["count"]) + 1
		(group["members"] as Array).append(int(assignment.get("serial", -1)))

	var result: Array = []

	for key: Variant in groups.keys():
		result.append(groups[key])

	return result


func set_re_solve_enabled(value: bool) -> void:
	re_solve_enabled = value

	if value and enabled:
		_next_resolve_at = GlobalData.sim_now() + re_solve_interval

	_sync_recorder_configuration()


func set_re_solve_interval(value: float) -> void:
	re_solve_interval = clampf(value, 5.0, 120.0)
	_next_resolve_at = GlobalData.sim_now() + re_solve_interval
	_sync_recorder_configuration()


func set_overlay_enabled(value: bool) -> void:
	overlay_enabled = value
	_ensure_overlay()

	if _overlay == null:
		return

	_overlay.call("set_result", last_result if overlay_enabled else null)
	_overlay.call("set_enabled", overlay_enabled)


func request_solve() -> void:
	if not enabled:
		_publish_state("disabled")
		return

	if _solving:
		return

	_disruption_pending = false
	_solving = true
	_publish_state("queued")
	call_deferred("_run_solve")


func get_status_line() -> String:
	if not enabled:
		return "Optimizer off (local exit choice)"

	return "%s | %s | cohort %.1f m | %s" % [
		algorithm,
		mode,
		cohort_size,
		last_rejection if not last_rejection.is_empty() else "ready",
	]


# ---------------------------------------------------------------------------
# Solve lifecycle
# ---------------------------------------------------------------------------

func _on_run_started() -> void:
	if not enabled:
		return

	GlobalData.set_optimizer_enabled(true)
	_clear_live_assignments()
	last_result = null
	last_applied = 0
	last_skipped = 0
	last_rejection = ""
	adopted_spawns = 0
	plan_active = false
	last_plan_name = ""
	last_held = 0
	last_commitment_skipped = 0
	_last_applied_cost = INF
	_last_applied_environment = -1
	_spawn_complete_solved = false
	_plan_pending = false
	GlobalData.optimizer_last_estimate = 0.0
	GlobalData.optimizer_last_algorithm = ""
	GlobalData.optimizer_last_mode = ""
	_serial_to_node.clear()
	_next_resolve_at = 0.0
	_last_solved_at = -INF
	_last_solved_environment = GlobalData.environment_version
	_last_exit_signature = ""
	_queue_baseline = 0
	_queue_total_cached = 0
	_exit_signature_cached = ""
	_pending_spawns = 0
	_spawn_solve_at = 0.0
	_poll_at = 0.0

	if _startup_plan != null:
		_plan_pending = true
		_plan_apply_at = GlobalData.sim_now() + PLAN_APPLY_DELAY
		_publish_state("plan armed: %s" % _startup_plan.name)

	if auto_solve:
		if solve_on_spawn_complete:
			_publish_state("waiting for spawn quota before the first solve")
		else:
			_auto_pending = true
			_auto_at = GlobalData.sim_now() + maxf(0.0, first_solve_delay)
			_publish_state("auto-solve in %.1f s" % maxf(0.0, first_solve_delay))


func _on_run_reset() -> void:
	_auto_pending = false
	_clear_live_assignments()
	_serial_to_node.clear()
	last_result = null
	last_applied = 0
	last_skipped = 0
	last_unchanged = 0
	last_changed = 0
	last_held = 0
	last_commitment_skipped = 0
	last_rejection = ""
	adopted_spawns = 0
	plan_active = false
	last_plan_name = ""
	_plan_pending = false
	_last_applied_cost = INF
	_last_applied_environment = -1
	_spawn_complete_solved = false
	_last_solved_at = -INF
	_next_resolve_at = 0.0
	_last_exit_signature = ""
	_queue_baseline = 0
	_pending_spawns = 0
	_spawn_solve_at = 0.0
	_poll_at = 0.0

	if _overlay != null and is_instance_valid(_overlay):
		_overlay.call("set_result", null)

	_publish_state("enabled" if enabled else "off")


## New agents that appear after a solve are adopted by the nearest cohort of the
## last feasible result when they appear close to it. Farther spawns are queued
## for the next periodic/triggered solve, so a distant spawner is still covered.
func _on_agent_spawned(agent: Node) -> void:
	if not enabled:
		return

	if _active_plan != null:
		call_deferred("_adopt_plan_spawn", agent)
		return

	if (
		last_result != null
		and last_result.source_environment_version
		== GlobalData.environment_version
	):
		call_deferred("_adopt_spawned_agent", agent)
	elif auto_solve:
		_queue_spawn_for_solve()


func _queue_spawn_for_solve() -> void:
	if not auto_solve:
		return

	_pending_spawns += 1
	_spawn_solve_at = GlobalData.sim_now() + SPAWN_DEBOUNCE


func _adopt_plan_spawn(agent: Node) -> void:
	if not enabled or _active_plan == null:
		return

	if agent == null or not is_instance_valid(agent) or not agent.is_inside_tree():
		return

	if not agent.is_in_group("npc") or agent.has_meta("evacuated"):
		return

	if not bool(agent.get("is_evacuee")):
		return

	var state: Dictionary = agent.call("get_measurement_state")
	var status := String(state.get("status", ""))

	if status in ["arrived", "queued", "evacuated", "dead"]:
		return

	var serial := int(state.get("serial", -1))
	var assignment: Dictionary = {}

	for candidate: Variant in _active_plan.assignments:
		if candidate is Dictionary and int((candidate as Dictionary).get("serial", -1)) == serial:
			assignment = candidate
			break

	if assignment.is_empty():
		var position: Vector3 = agent.global_position
		var best_distance := INF

		for candidate: Variant in _active_plan.assignments:
			if not candidate is Dictionary or not (candidate as Dictionary).has("spawn_position"):
				continue

			var point := EvacuationPlan._point_array((candidate as Dictionary).get("spawn_position", []))

			if point.size() < 3:
				continue

			var distance := position.distance_squared_to(
				Vector3(float(point[0]), float(point[1]), float(point[2]))
			)

			if distance < best_distance and distance <= 36.0:
				best_distance = distance
				assignment = candidate

	if assignment.is_empty():
		if auto_solve:
			_queue_spawn_for_solve()

		return

	var exit_id := String(assignment.get("exit_id", ""))
	var target := _exit_position(exit_id)

	if exit_id.is_empty() or target == Vector3.ZERO or not _live_exit_ids().has(exit_id):
		return

	var route: Array = EvacuationPlan._point_array_list(assignment.get("route", []))

	if route.size() >= 2 and agent.has_method("request_evacuation_route"):
		if bool(agent.call("request_evacuation_route", exit_id, target, route, "plan")):
			adopted_spawns += 1
			return

	if agent.call("set_optimizer_assignment", exit_id, target):
		adopted_spawns += 1


func _adopt_spawned_agent(agent: Node) -> void:
	if not enabled:
		return

	if agent == null or not is_instance_valid(agent) or not agent.is_inside_tree():
		return

	if not agent.is_in_group("npc") or agent.has_meta("evacuated"):
		return

	if not bool(agent.get("is_evacuee")):
		return

	var state: Dictionary = agent.call("get_measurement_state")
	var status: String = String(state.get("status", ""))

	if status in ["arrived", "queued", "evacuated", "dead"]:
		return

	if last_result != null:
		var position: Vector3 = agent.global_position
		var nearest: Dictionary = {}
		var nearest_sq: float = INF

		for cohort: Dictionary in last_result.cohorts:
			var distance_sq: float = position.distance_squared_to(
				cohort.get("position", Vector3.ZERO)
			)

			if distance_sq < nearest_sq:
				nearest_sq = distance_sq
				nearest = cohort

		if (
			not nearest.is_empty()
			and nearest_sq <= ADOPT_RADIUS * ADOPT_RADIUS
		):
			var exit_id: String = String(nearest.get("exit_id", ""))

			if not exit_id.is_empty() and _live_exit_ids().has(exit_id):
				var target: Vector3 = _exit_position(exit_id)

				if (
					target != Vector3.ZERO
					and agent.call("set_optimizer_assignment", exit_id, target)
				):
					adopted_spawns += 1
					return

	_queue_spawn_for_solve()


func _exit_position(exit_id: String) -> Vector3:
	var tree: SceneTree = get_tree()

	if tree == null:
		return Vector3.ZERO

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node):
			continue

		if not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")

		if String(status.get("exit_id", "")) == exit_id:
			return (node as Node3D).global_position

	return Vector3.ZERO


func _run_solve() -> void:
	if not enabled:
		_solving = false
		return

	var started_usec: int = Time.get_ticks_usec()
	_publish_state("capturing snapshot")

	# Let the panel draw the state before the synchronous capture/solve work.
	await get_tree().process_frame

	if not is_inside_tree() or not enabled:
		_solving = false
		return

	var snapshot: SimulationSnapshot = _capture_snapshot()

	if snapshot == null:
		_solving = false
		last_rejection = ""
		_mark_solve_finished()
		_publish_state("nothing to optimize (no agents or exits)")
		return

	_publish_state("solving %d agents / %d exits" % [
		snapshot.agents.size(),
		snapshot.get_available_exits().size(),
	])
	await get_tree().process_frame

	if not is_inside_tree() or not enabled:
		_solving = false
		return

	var request := OptimizationRequest.new()
	request.snapshot = snapshot
	request.algorithm = algorithm
	request.mode = mode
	request.weights = weights.duplicate(true)
	request.parameters = parameters.duplicate(true)
	request.cohort_size = cohort_size
	request.max_cohorts = max_cohorts

	if (
		request.algorithm
		in [
			OptimizationRequest.ALGORITHM_ACO,
			OptimizationRequest.ALGORITHM_PSO,
		]
		and not request.parameters.has("seed")
	):
		request.parameters["seed"] = hash([
			GlobalData.rng_seed,
			snapshot.environment_version,
		])

	var result: OptimizationResult = OptimizerManager.solve(snapshot, request)
	last_result = result
	_attach_cohort_routes(result)
	GlobalData.optimizer_last_estimate = result.estimated_completion_time
	GlobalData.optimizer_last_algorithm = result.algorithm
	GlobalData.optimizer_last_mode = result.mode

	var rejection: String = _validate(result, snapshot)
	var applied: int = 0
	var skipped: int = 0
	var unchanged: int = 0
	var held: int = 0
	var commitment_skipped: int = 0

	if rejection.is_empty():
		var outcome: Dictionary = _apply(result)
		applied = int(outcome.get("applied", 0))
		skipped = int(outcome.get("skipped", 0))
		unchanged = int(outcome.get("unchanged", 0))
		held = int(outcome.get("held", 0))
		commitment_skipped = int(outcome.get("commitment_skipped", 0))
		last_rejection = ""
	else:
		last_rejection = rejection
		skipped = result.agent_exit_assignments.size()

	last_applied = applied
	last_changed = applied
	last_skipped = skipped
	last_unchanged = unchanged
	last_held = held
	last_commitment_skipped = commitment_skipped
	result.detail["apply"] = {
		"changed": applied,
		"unchanged": unchanged,
		"skipped": skipped,
		"held": held,
		"commitment_skipped": commitment_skipped,
		"hysteresis_enabled": hysteresis_enabled,
		"hysteresis_ratio": hysteresis_ratio,
	}

	_record(result, applied, skipped, rejection, Time.get_ticks_usec() - started_usec)
	_solving = false
	solve_count += 1
	_mark_solve_finished()
	_refresh_overlay()

	if not rejection.is_empty():
		_publish_state("rejected: " + rejection)
	elif applied == 0:
		_publish_state(
			"solved; %d unchanged, %d skipped" % [unchanged, skipped]
		)
	else:
		_publish_state(
			"changed %d | unchanged %d | skipped %d | %d cohorts | T=%.1f s | %.0f ms"
			% [
				applied,
				unchanged,
				skipped,
				result.cohorts.size(),
				result.estimated_completion_time,
				result.computation_time_ms,
			]
		)

	result_ready.emit(result, applied, skipped)


## Records the state a fresh re-solve is measured against. Called even when the
## snapshot was empty so a periodic retry does not storm every frame.
func _mark_solve_finished() -> void:
	var now: float = GlobalData.sim_now()
	_last_solved_at = now
	_last_solved_environment = GlobalData.environment_version
	_last_exit_signature = _exit_signature()
	_exit_signature_cached = _last_exit_signature
	_queue_baseline = _queue_total()
	_queue_total_cached = _queue_baseline
	_next_resolve_at = now + re_solve_interval
	_pending_spawns = 0
	_spawn_solve_at = 0.0
	_auto_pending = false
	_poll_at = 0.0


func _exit_signature() -> String:
	var ids: Array = _live_exit_ids().keys()
	ids.sort()

	var parts: Array[String] = []

	for id: Variant in ids:
		parts.append(String(id))

	return ",".join(parts)


func _clear_live_assignments() -> void:
	var tree: SceneTree = get_tree()

	if tree == null:
		return

	for node: Node in tree.get_nodes_in_group("npc"):
		if node.has_method("clear_optimizer_assignment"):
			node.call("clear_optimizer_assignment")


func _queue_total() -> int:
	var total: int = 0
	var tree: SceneTree = get_tree()

	if tree == null:
		return total

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if not is_instance_valid(node) or not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")
		total += int(status.get("current_queue", 0))

	return total


func _ensure_overlay() -> void:
	if not overlay_enabled:
		return

	if _overlay != null and is_instance_valid(_overlay):
		return

	var tree: SceneTree = get_tree()

	if tree == null:
		return

	var host: Node = tree.current_scene

	if host == null:
		host = tree.root

	if host == null:
		return

	var overlay: Node3D = OPTIMIZER_OVERLAY.new()
	overlay.name = "OptimizerOverlay"
	host.add_child(overlay)
	overlay.call("setup", self)
	_overlay = overlay


func _refresh_overlay() -> void:
	if not overlay_enabled:
		return

	_ensure_overlay()

	if _overlay == null or not is_instance_valid(_overlay):
		return

	_overlay.call("set_result", last_result)
	_overlay.call("set_enabled", true)


# ---------------------------------------------------------------------------
# Snapshot capture
# ---------------------------------------------------------------------------

func _capture_snapshot() -> SimulationSnapshot:
	var tree: SceneTree = get_tree()

	if tree == null:
		return null

	var grid: NavGridMap = _ensure_grid(tree)

	if grid == null:
		return null

	var exits: Array = _capture_exits(tree, grid)

	if exits.is_empty():
		return null

	var agents: Array = _capture_agents(tree, grid)

	if agents.is_empty():
		return null

	var cost_fields: Dictionary = {}

	for exit_data: Dictionary in exits:
		if not bool(exit_data.get("available", false)):
			continue

		cost_fields[String(exit_data.get("exit_id", ""))] = grid.build_cost_field_to(
			exit_data.get("position", Vector3.ZERO)
		)

	var snapshot := SimulationSnapshot.new()
	snapshot.sim_time = GlobalData.sim_now()
	snapshot.rng_seed = GlobalData.rng_seed
	snapshot.environment_version = GlobalData.environment_version
	snapshot.agent_cap = GlobalData.global_unit_cap
	snapshot.agents = agents
	snapshot.exits = exits
	snapshot.congestion_heat = grid.get_congestion_heat_map()
	snapshot.nav = {
		"cell_size": grid.cell_size,
		"cost_fields": cost_fields,
	}
	return snapshot


func _capture_exits(tree: SceneTree, grid: NavGridMap) -> Array:
	var exits: Array = []
	var seen: Dictionary = {}

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		var exit_node := node as Node3D

		if exit_node == null or not is_instance_valid(exit_node):
			continue

		# Each exit registers its root and its Area3D. The Area3D owns the
		# script and the admission policy, so only it can produce a status.
		if not exit_node.has_method("get_exit_status"):
			continue

		var status: Dictionary = exit_node.call("get_exit_status")
		var exit_id: String = String(status.get("exit_id", ""))

		if exit_id.is_empty() or seen.has(exit_id):
			continue

		seen[exit_id] = true
		var position: Vector3 = exit_node.global_position

		exits.append({
			"exit_id": exit_id,
			"name": String(status.get("name", exit_id)),
			"position": position,
			"cell": grid.resolve_nav_cell(position),
			"available": bool(status.get("available", false)),
			"service_rate": float(status.get("service_rate", 0.0)),
			"max_queue_length": int(status.get("max_queue_length", 0)),
			"receiving_capacity": int(status.get("receiving_capacity", 0)),
			"retain_evacuated": bool(status.get("retain", false)),
			"queue_length": int(status.get("current_queue", 0)),
			"receiving_occupancy": int(status.get("receiving_occupancy", 0)),
			"accepted": int(status.get("accepted", 0)),
			"average_wait": float(status.get("average_wait", 0.0)),
		})

	return exits


func _capture_agents(tree: SceneTree, grid: NavGridMap) -> Array:
	var agents: Array = []
	_serial_to_node.clear()

	for node: Node in tree.get_nodes_in_group("npc"):
		var member := node as Node3D

		if member == null or not is_instance_valid(member):
			continue

		if not member.has_method("get_measurement_state"):
			continue

		if member.has_meta("evacuated"):
			continue

		if not bool(member.get("is_evacuee")):
			continue

		var state: Dictionary = member.call("get_measurement_state")
		var status: String = String(state.get("status", ""))

		# These are already in the admission pipeline or out of the run.
		if status in ["arrived", "queued", "evacuated", "dead"]:
			continue

		var serial: int = int(state.get("serial", -1))

		if serial < 0:
			continue

		var position: Vector3 = state.get("position", Vector3.ZERO)
		var member_node: Node3D = member
		_serial_to_node[serial] = member_node

		agents.append({
			"serial": serial,
			"position": position,
			"cell": grid.resolve_nav_cell(position),
			"desired_speed": float(state.get("desired_speed", 1.34)),
			"state": status,
			"has_target": bool(member_node.get("has_evacuation_target")),
			"exit_id": String(state.get("exit_id", "")),
			"path_remaining": float(state.get("route_length", 0.0)),
		})

	return agents


# ---------------------------------------------------------------------------
# Validation and application
# ---------------------------------------------------------------------------

func _validate(result: OptimizationResult, snapshot: SimulationSnapshot) -> String:
	if result == null:
		return "no_result"

	if not result.feasible:
		return result.get_violation_summary() if not result.violations.is_empty() else "infeasible"

	if result.source_environment_version != GlobalData.environment_version:
		return "stale environment (was %d, now %d)" % [
			result.source_environment_version,
			GlobalData.environment_version,
		]

	if snapshot.get_available_exits().is_empty():
		return "no available exits"

	var live_exits: Dictionary = _live_exit_ids()

	for exit_id_value: Variant in result.exit_counts.keys():
		var exit_id: String = String(exit_id_value)

		if not live_exits.has(exit_id):
			return "exit unavailable: %s" % exit_id

	return ""


func _apply(result: OptimizationResult) -> Dictionary:
	var applied: int = 0
	var skipped: int = 0
	var unchanged: int = 0
	var held: int = 0
	var commitment_skipped: int = 0
	var live_exits: Dictionary = _live_exit_ids()
	var same_environment: bool = (
		_last_applied_environment == GlobalData.environment_version
	)
	var improvement_ok: bool = (
		not is_finite(_last_applied_cost)
		or not is_finite(result.estimated_cost)
		or result.estimated_cost <= _last_applied_cost * (1.0 - hysteresis_ratio)
	)
	var allow_changes: bool = (
		not hysteresis_enabled
		or not same_environment
		or _last_applied_cost == INF
		or improvement_ok
	)

	for serial_value: Variant in result.agent_exit_assignments.keys():
		var serial: int = int(serial_value)
		var member: Variant = _serial_to_node.get(serial)

		if member == null or not is_instance_valid(member):
			skipped += 1
			continue

		var node := member as Node3D

		if not node.is_inside_tree():
			skipped += 1
			continue

		if node.has_meta("evacuated"):
			skipped += 1
			continue

		var status: Dictionary = node.call("get_measurement_state")
		var status_text: String = String(status.get("status", ""))

		if status_text in ["arrived", "queued", "evacuated", "dead"]:
			skipped += 1
			continue

		if bool(status.get("evacuated", false)):
			skipped += 1
			continue

		# Do not pull an agent away from a doorway it is about to reach.
		if bool(node.get("has_evacuation_target")):
			var current_target: Vector3 = status.get("destination", Vector3.ZERO)

			if (
				current_target != Vector3.ZERO
				and node.global_position.distance_to(current_target) <= COMMIT_RADIUS
			):
				skipped += 1
				commitment_skipped += 1
				continue

		var exit_id: String = String(result.agent_exit_assignments[serial])
		var target: Vector3 = result.agent_targets.get(serial, Vector3.ZERO)
		var previous_exit: String = ""

		if (
			node.has_method("has_optimizer_assignment")
			and bool(node.call("has_optimizer_assignment"))
		):
			previous_exit = String(node.call("get_optimizer_exit_id"))

		# A periodic solve usually reproduces most of the previous assignment.
		# Leaving those agents untouched avoids re-pathing the whole crowd every
		# interval and makes the "changed" count meaningful.
		if previous_exit == exit_id:
			unchanged += 1
			continue

		# Hysteresis: keep a valid existing assignment unless the new plan is
		# materially better, or the old exit is no longer available. This is the
		# guard the design document promised; it is recorded in the event.
		if (
			not allow_changes
			and not previous_exit.is_empty()
			and live_exits.has(previous_exit)
		):
			held += 1
			continue

		if node.call("set_optimizer_assignment", exit_id, target):
			applied += 1
		else:
			skipped += 1

	if applied > 0 or not same_environment:
		_last_applied_cost = result.estimated_cost
		_last_applied_environment = GlobalData.environment_version

	return {
		"applied": applied,
		"skipped": skipped,
		"unchanged": unchanged,
		"held": held,
		"commitment_skipped": commitment_skipped,
	}


func _attach_cohort_routes(result: OptimizationResult) -> void:
	if result == null:
		return

	for cohort_value: Variant in result.cohorts:
		if not cohort_value is Dictionary:
			continue

		var cohort: Dictionary = cohort_value
		var members: Array = cohort.get("members", [])
		var route: Array = []

		for serial_value: Variant in members:
			route = _route_for_serial(int(serial_value))

			if route.size() >= 2:
				break

		cohort["route"] = route


func _live_exit_ids() -> Dictionary:
	var result: Dictionary = {}
	var tree: SceneTree = get_tree()

	if tree == null:
		return result

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node):
			continue

		if not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")

		if bool(status.get("available", false)):
			result[String(status.get("exit_id", ""))] = true

	return result


# ---------------------------------------------------------------------------
# Recording and grid signals
# ---------------------------------------------------------------------------

func _record(
	result: OptimizationResult,
	applied: int,
	skipped: int,
	rejection: String,
	total_usec: int
) -> void:
	var detail: Dictionary = result.to_dictionary()
	detail["applied"] = applied
	detail["skipped"] = skipped
	detail["rejected_reason"] = rejection
	detail["enabled"] = enabled
	detail["total_usec"] = total_usec
	detail["adopted_spawns"] = adopted_spawns

	var recorder := get_node_or_null("/root/SimRecorder")

	if recorder != null and recorder.has_method("record_optimizer_execution"):
		recorder.record_optimizer_execution(
			result.algorithm,
			maxi(0, total_usec),
			detail
		)

	_sync_recorder_configuration()


func _sync_recorder_configuration() -> void:
	var recorder := get_node_or_null("/root/SimRecorder")

	if recorder == null or not recorder.has_method("set_optimizer_configuration"):
		return

	var effective_weights: Dictionary = OptimizationRequest.default_weights(mode)

	for key: Variant in weights.keys():
		effective_weights[String(key)] = float(weights[key])

	recorder.set_optimizer_configuration({
		"available": enabled,
		"algorithm": algorithm,
		"mode": mode,
		"weights": effective_weights,
		"parameters": parameters.duplicate(true),
		"cohort_size": cohort_size,
		"max_cohorts": max_cohorts,
		"auto_solve": auto_solve,
		"first_solve_delay": first_solve_delay,
		"solve_on_spawn_complete": solve_on_spawn_complete,
		"hysteresis_enabled": hysteresis_enabled,
		"hysteresis_ratio": hysteresis_ratio,
		"re_solve_enabled": re_solve_enabled,
		"re_solve_interval": re_solve_interval,
		"overlay_enabled": overlay_enabled,
		"environment_version": GlobalData.environment_version,
	})


func _ensure_grid(tree: SceneTree) -> NavGridMap:
	if _connected_grid != null and is_instance_valid(_connected_grid):
		return _connected_grid

	if tree == null:
		return null

	var grid := tree.get_first_node_in_group("grid_map") as NavGridMap

	if grid == null:
		return null

	_connected_grid = grid

	if not grid.block_placed.is_connected(_on_block_placed):
		grid.block_placed.connect(_on_block_placed)

	if not grid.block_removed.is_connected(_on_block_removed):
		grid.block_removed.connect(_on_block_removed)

	if not grid.structure_collapsed.is_connected(_on_structure_collapsed):
		grid.structure_collapsed.connect(_on_structure_collapsed)

	return grid


func _disconnect_grid() -> void:
	if _connected_grid == null or not is_instance_valid(_connected_grid):
		_connected_grid = null
		return

	if _connected_grid.block_placed.is_connected(_on_block_placed):
		_connected_grid.block_placed.disconnect(_on_block_placed)

	if _connected_grid.block_removed.is_connected(_on_block_removed):
		_connected_grid.block_removed.disconnect(_on_block_removed)

	if _connected_grid.structure_collapsed.is_connected(_on_structure_collapsed):
		_connected_grid.structure_collapsed.disconnect(_on_structure_collapsed)

	_connected_grid = null


func _on_block_placed(_cell: Vector3i, _item: int) -> void:
	GlobalData.bump_environment_version()


func _on_block_removed(_cell: Vector3i) -> void:
	GlobalData.bump_environment_version()


## A collapse is a route disruption, not a normal single-block edit: schedule a
## solve as soon as the minimum gap allows instead of waiting for the periodic
## interval. `_on_block_removed` already bumps the environment version per cell;
## this adds the event-level intent and the shorter reaction.
func _on_structure_collapsed(cells: Array[Vector3i], _style: int) -> void:
	_disruption_pending = true
	_disruption_at = GlobalData.sim_now() + RESOLVE_MIN_GAP
	_disruption_count += 1
	_disruption_cells = cells.size()


func disruption_stats() -> Dictionary:
	return {
		"count": _disruption_count,
		"last_cells": _disruption_cells,
		"pending": _disruption_pending,
	}


func _publish_state(text: String) -> void:
	state_changed.emit(text)
