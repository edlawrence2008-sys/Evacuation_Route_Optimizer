class_name OptimizerBridge
extends Node

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
## appears within this radius. Farther spawns keep the local exit choice.
const ADOPT_RADIUS: float = 8.0

var enabled: bool = false
var auto_solve: bool = true
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
}

var last_result: OptimizationResult
var last_applied: int = 0
var last_skipped: int = 0
var last_rejection: String = ""
var solve_count: int = 0
var adopted_spawns: int = 0

var _solving: bool = false
var _auto_pending: bool = false
var _auto_at: float = 0.0
var _serial_to_node: Dictionary = {}
var _connected_grid: NavGridMap


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
	if defaults.get("weights") is Dictionary:
		weights = (defaults["weights"] as Dictionary).duplicate(true)
	if defaults.get("parameters") is Dictionary:
		parameters = (defaults["parameters"] as Dictionary).duplicate(true)
	if defaults.has("enabled"):
		enabled = bool(defaults["enabled"])
		GlobalData.set_optimizer_enabled(enabled)


func _exit_tree() -> void:
	_disconnect_grid()


func _process(_delta: float) -> void:
	if not enabled or _solving or not _auto_pending:
		return

	if GlobalData.sim_now() >= _auto_at:
		_auto_pending = false
		request_solve()


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

func set_enabled(value: bool) -> void:
	enabled = value
	GlobalData.set_optimizer_enabled(value)

	if not value:
		_auto_pending = false
		_publish_state("off")
	else:
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
	_sync_recorder_configuration()


func request_solve() -> void:
	if not enabled:
		_publish_state("disabled")
		return

	if _solving:
		return

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
	last_result = null
	last_applied = 0
	last_skipped = 0
	last_rejection = ""
	adopted_spawns = 0
	GlobalData.optimizer_last_estimate = 0.0
	GlobalData.optimizer_last_algorithm = ""
	GlobalData.optimizer_last_mode = ""
	_serial_to_node.clear()

	if auto_solve:
		_auto_pending = true
		_auto_at = GlobalData.sim_now() + AUTO_SOLVE_DELAY
		_publish_state("auto-solve in %.1f s" % AUTO_SOLVE_DELAY)


func _on_run_reset() -> void:
	_auto_pending = false
	_serial_to_node.clear()
	last_result = null
	last_applied = 0
	last_skipped = 0
	last_rejection = ""
	adopted_spawns = 0
	_publish_state("enabled" if enabled else "off")


## New agents that appear after a solve are adopted by the nearest cohort of the
## last feasible result. A spawner that is still emitting is therefore covered
## without another full solve; spawns farther than ADOPT_RADIUS keep the local
## logit choice.
func _on_agent_spawned(agent: Node) -> void:
	if not enabled or last_result == null:
		return

	if last_result.source_environment_version != GlobalData.environment_version:
		return

	call_deferred("_adopt_spawned_agent", agent)


func _adopt_spawned_agent(agent: Node) -> void:
	if not enabled or last_result == null:
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

	if nearest.is_empty() or nearest_sq > ADOPT_RADIUS * ADOPT_RADIUS:
		return

	var exit_id: String = String(nearest.get("exit_id", ""))

	if exit_id.is_empty() or not _live_exit_ids().has(exit_id):
		return

	var target: Vector3 = _exit_position(exit_id)

	if target == Vector3.ZERO:
		return

	if agent.call("set_optimizer_assignment", exit_id, target):
		adopted_spawns += 1


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
		request.algorithm == OptimizationRequest.ALGORITHM_ACO
		and not request.parameters.has("seed")
	):
		request.parameters["seed"] = hash([
			GlobalData.rng_seed,
			snapshot.environment_version,
		])

	var result: OptimizationResult = OptimizerManager.solve(snapshot, request)
	last_result = result
	GlobalData.optimizer_last_estimate = result.estimated_completion_time
	GlobalData.optimizer_last_algorithm = result.algorithm
	GlobalData.optimizer_last_mode = result.mode

	var rejection: String = _validate(result, snapshot)
	var applied: int = 0
	var skipped: int = 0

	if rejection.is_empty():
		var outcome: Dictionary = _apply(result)
		applied = int(outcome.get("applied", 0))
		skipped = int(outcome.get("skipped", 0))
		last_rejection = ""
	else:
		last_rejection = rejection
		skipped = result.agent_exit_assignments.size()

	last_applied = applied
	last_skipped = skipped

	_record(result, applied, skipped, rejection, Time.get_ticks_usec() - started_usec)
	_solving = false
	solve_count += 1

	if not rejection.is_empty():
		_publish_state("rejected: " + rejection)
	elif applied == 0:
		_publish_state("solved; no agents needed changing")
	else:
		_publish_state(
			"applied %d / %d | %d cohorts | T≈%.1f s | %.0f ms"
			% [
				applied,
				applied + skipped,
				result.cohorts.size(),
				result.estimated_completion_time,
				result.computation_time_ms,
			]
		)

	result_ready.emit(result, applied, skipped)


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
			var target: Vector3 = status.get("destination", Vector3.ZERO)

			if (
				target != Vector3.ZERO
				and node.global_position.distance_to(target) <= COMMIT_RADIUS
			):
				skipped += 1
				continue

		var exit_id: String = String(result.agent_exit_assignments[serial])
		var target: Vector3 = result.agent_targets.get(serial, Vector3.ZERO)

		if node.call("set_optimizer_assignment", exit_id, target):
			applied += 1
		else:
			skipped += 1

	return {"applied": applied, "skipped": skipped}


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

	return grid


func _disconnect_grid() -> void:
	if _connected_grid == null or not is_instance_valid(_connected_grid):
		_connected_grid = null
		return

	if _connected_grid.block_placed.is_connected(_on_block_placed):
		_connected_grid.block_placed.disconnect(_on_block_placed)

	if _connected_grid.block_removed.is_connected(_on_block_removed):
		_connected_grid.block_removed.disconnect(_on_block_removed)

	_connected_grid = null


func _on_block_placed(_cell: Vector3i, _item: int) -> void:
	GlobalData.bump_environment_version()


func _on_block_removed(_cell: Vector3i) -> void:
	GlobalData.bump_environment_version()


func _publish_state(text: String) -> void:
	state_changed.emit(text)
