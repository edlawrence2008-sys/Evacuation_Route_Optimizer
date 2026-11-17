extends Node

## Records the current evacuation run and turns it into the numbers shown in
## the results panel: per-NPC times, exit usage, throughput and congestion.

signal metrics_changed

var _records: Dictionary = {} # npc instance id -> record
var _arrivals: Array[float] = []
var _exits: Dictionary = {} # exit key -> aggregate
var _failed_paths: int = 0
var _deaths: int = 0
var _peak_density: float = 0.0
var _total_distance: float = 0.0
var _total_stuck_time: float = 0.0
var _total_stuck_strikes: int = 0
var _run_started_ms: int = 0
var _last_activity_ms: int = 0
var _total_pre_movement: float = 0.0
var _peak_contact_force: float = 0.0
var _evacuations: Array[Dictionary] = []

## Retained evacuated agents. These are deliberately kept outside the `npc`
## and `Members` groups and outside the active crowd/navigation systems.
var _retained: Array[Dictionary] = []
var _retained_container: Node3D = null
var _retained_expiring: int = 0
var _retention_accum: float = 0.0
var _peak_receiving_occupancy: int = 0
var _receiving_occupancy_by_point: Dictionary = {} # instance id -> occupancy
var _receiving_occupancy_total: int = 0

## Retained agents only need to be scanned for expiry a few times per second;
## with a positive hold time the list can be large, and per-frame scanning of
## every retained node is wasted work.
const RETENTION_SCAN_INTERVAL: float = 0.25


func _ready() -> void:
	GlobalData.spawning_reset.connect(reset_run)
	GlobalData.spawning_started.connect(begin_run)


func _process(delta: float) -> void:
	if _retained_expiring <= 0:
		return

	_retention_accum += delta

	if _retention_accum < RETENTION_SCAN_INTERVAL:
		return

	_retention_accum = 0.0
	var now: float = GlobalData.sim_now()

	for index: int in range(_retained.size() - 1, -1, -1):
		var entry: Dictionary = _retained[index]
		var node: Variant = entry.get("node")
		var expires_at: float = float(entry.get("expires_at", 0.0))

		if node == null or not is_instance_valid(node):
			if expires_at > 0.0:
				_retained_expiring = maxi(0, _retained_expiring - 1)
			_retained.remove_at(index)
			continue

		if expires_at <= 0.0 or now < expires_at:
			continue

		var point: Variant = entry.get("point")
		var slot: int = int(entry.get("slot", -1))
		_retained.remove_at(index)
		_retained_expiring = maxi(0, _retained_expiring - 1)

		if is_instance_valid(node):
			node.queue_free()

		if (
			point != null
			and is_instance_valid(point)
			and point.has_method("release_receiving_slot")
		):
			point.release_receiving_slot(slot)


func begin_run() -> void:
	_reset_contact_stats()

	if _run_started_ms == 0:
		_run_started_ms = _now_ms()

	_last_activity_ms = _now_ms()


func _reset_contact_stats() -> void:
	var crowd := get_node_or_null("/root/CrowdManager")

	if crowd != null and crowd.has_method("reset_contact_force_stats"):
		crowd.reset_contact_force_stats()


func reset_run() -> void:
	_records.clear()
	_arrivals.clear()
	_exits.clear()
	_evacuations.clear()
	clear_retained_agents(false)
	_peak_receiving_occupancy = 0
	_receiving_occupancy_by_point.clear()
	_receiving_occupancy_total = 0
	_failed_paths = 0
	_deaths = 0
	_peak_density = 0.0
	_total_distance = 0.0
	_total_stuck_time = 0.0
	_total_stuck_strikes = 0
	_total_pre_movement = 0.0
	_peak_contact_force = 0.0
	_run_started_ms = 0
	_last_activity_ms = 0
	_reset_contact_stats()
	metrics_changed.emit()


## Called by the spawner (and by Member itself, so direct spawns are counted).
func register_npc(npc: Node) -> void:
	if npc == null or not is_instance_valid(npc):
		return

	var id: int = npc.get_instance_id()
	if _records.has(id):
		return

	var now: int = _now_ms()
	if _run_started_ms == 0:
		_run_started_ms = now

	_records[id] = {
		"name": String(npc.name),
		"spawn_ms": now,
		"target": Vector3.ZERO,
		"arrived_ms": -1,
		"dead": false,
		"evacuated": false,
	}
	_last_activity_ms = now


func notify_evacuation_target_chosen(target: Vector3, npc: Node) -> void:
	var record := _record_for(npc)
	if record.is_empty():
		return

	record["target"] = target


func notify_npc_arrived(target: Vector3, npc: Node) -> void:
	var record := _record_for(npc)
	if record.is_empty():
		return

	record["target"] = target
	record["arrived_ms"] = _now_ms()


func notify_evacuation_failed(_target: Vector3) -> void:
	_failed_paths += 1
	_last_activity_ms = _now_ms()
	metrics_changed.emit()


func notify_npc_died(npc: Node) -> void:
	_deaths += 1

	var record := _record_for(npc)
	if not record.is_empty():
		record["dead"] = true

	_records.erase(npc.get_instance_id())
	_last_activity_ms = _now_ms()
	metrics_changed.emit()


## Called by EvacPoint after an agent has passed the exit. `info` carries the
## per-exit policy and queue metadata supplied by the point. Returns
## `{"retained": true}` when the agent was kept in the receiving area.
func register_evacuation(
	npc: Node,
	exit_node: Node3D,
	info: Dictionary = {}
) -> Dictionary:
	if npc == null or not is_instance_valid(npc):
		return {"retained": false}

	if npc.has_meta("evacuated"):
		return {"retained": false}

	var id: int = npc.get_instance_id()
	var now: int = _now_ms()
	var record: Dictionary = _records.get(id, {})
	var spawn_ms: int = int(record.get("spawn_ms", now))

	if _run_started_ms == 0:
		_run_started_ms = spawn_ms

	var snapshot: Dictionary = {}
	if npc.has_method("get_evacuation_snapshot"):
		snapshot = npc.get_evacuation_snapshot()

	var duration: float = maxf(0.0, float(now - spawn_ms) / 1000.0)
	var exit_key: String = String(info.get("exit_id", ""))
	if exit_key.is_empty():
		exit_key = _exit_key(exit_node)

	var exit_name: String = String(info.get("exit_name", ""))
	if exit_name.is_empty():
		exit_name = _exit_label(exit_node)

	var wait_time: float = maxf(0.0, float(info.get("wait_time", 0.0)))
	var track: bool = bool(info.get("track", true))

	if track:
		if snapshot.has("peak_density"):
			_peak_density = maxf(_peak_density, float(snapshot["peak_density"]))
		if snapshot.has("distance"):
			_total_distance += float(snapshot["distance"])
		if snapshot.has("stuck_time"):
			_total_stuck_time += float(snapshot["stuck_time"])
		if snapshot.has("stuck_strikes"):
			_total_stuck_strikes += int(snapshot["stuck_strikes"])
		if snapshot.has("pre_movement_wait"):
			_total_pre_movement += float(snapshot["pre_movement_wait"])
		if snapshot.has("peak_contact_force"):
			_peak_contact_force = maxf(
				_peak_contact_force,
				float(snapshot["peak_contact_force"])
			)

		var exit: Dictionary = _exits.get(exit_key, {})

		if exit.is_empty():
			exit = {
				"exit_id": exit_key,
				"name": exit_name,
				"arrivals": 0,
				"total_time": 0.0,
				"min_time": duration,
				"max_time": duration,
				"first_ms": now,
				"last_ms": now,
				"total_wait": 0.0,
				"max_wait": 0.0,
			}
			_exits[exit_key] = exit

		exit["arrivals"] = int(exit["arrivals"]) + 1
		exit["total_time"] = float(exit["total_time"]) + duration
		exit["min_time"] = minf(float(exit["min_time"]), duration)
		exit["max_time"] = maxf(float(exit["max_time"]), duration)
		exit["last_ms"] = now
		exit["total_wait"] = float(exit["total_wait"]) + wait_time
		exit["max_wait"] = maxf(float(exit["max_wait"]), wait_time)

		_arrivals.append(duration)
		_evacuations.append({
			"agent_id": id,
			"agent_serial": int(snapshot.get("agent_serial", -1)),
			"exit_id": exit_key,
			"exit_name": exit_name,
			"spawn_ms": spawn_ms,
			"evacuated_ms": now,
			"evacuation_time": duration,
			"wait_time": wait_time,
			"desired_speed": float(snapshot.get("desired_speed", 0.0)),
		})

	_records.erase(id)
	_last_activity_ms = now

	# The aggregate counter always advances: it is the run completion signal,
	# independent of optional per-agent/per-exit tracking.
	GlobalData.register_evacuation()

	var retain: bool = bool(info.get("retain", false))
	var retained: bool = false

	if npc.has_method("mark_evacuated"):
		npc.mark_evacuated()

	if retain and _retain_agent(npc, exit_node, info):
		retained = true
	elif is_instance_valid(npc):
		npc.queue_free()

	metrics_changed.emit()
	return {"retained": retained}


## Stores a successfully evacuated agent outside the active simulation. The
## node is deactivated by Member.mark_evacuated() before this is called.
func _retain_agent(npc: Node, exit_node: Node3D, info: Dictionary) -> bool:
	if exit_node == null or not is_instance_valid(exit_node):
		return false

	var container: Node3D = _get_retained_container()

	if container == null or container == npc:
		return false

	var slot: int = int(info.get("receiving_slot", -1))
	var target: Vector3 = exit_node.global_position

	if exit_node.has_method("get_receiving_slot_global_position"):
		target = exit_node.get_receiving_slot_global_position(slot)

	npc.reparent(container, true)

	if npc is Node3D:
		(npc as Node3D).global_position = target
		(npc as Node3D).visible = bool(info.get("visible", true))

	var hold_time: float = maxf(0.0, float(info.get("retain_seconds", 0.0)))
	var expires_at: float = (
		GlobalData.sim_now() + hold_time if hold_time > 0.0 else 0.0
	)

	if expires_at > 0.0:
		_retained_expiring += 1

	_retained.append({
		"node": npc,
		"point": exit_node,
		"slot": slot,
		"expires_at": expires_at,
	})

	return true


func _get_retained_container() -> Node3D:
	if (
		_retained_container != null
		and is_instance_valid(_retained_container)
		and _retained_container.is_inside_tree()
	):
		return _retained_container

	var tree: SceneTree = get_tree()

	if tree == null:
		return null

	var parent: Node = tree.current_scene

	if parent == null:
		parent = tree.root

	if parent == null:
		return null

	_retained_container = Node3D.new()
	_retained_container.name = "EvacuatedAgents"
	parent.add_child(_retained_container)

	return _retained_container


## Removes every retained evacuated agent. Used by run reset, by the global
## kill-all path, and when the scene changes. Returns the number of nodes
## removed. Releasing slots may let queued active agents advance, so the loop
## pops until the list is genuinely empty.
func clear_retained_agents(release_slots: bool = true) -> int:
	var removed: int = 0

	while not _retained.is_empty():
		var entry: Dictionary = _retained.pop_back()
		removed += 1
		var node: Variant = entry.get("node")

		if node != null and is_instance_valid(node):
			node.queue_free()

		if not release_slots:
			continue

		var point: Variant = entry.get("point")

		if (
			point != null
			and is_instance_valid(point)
			and point.has_method("release_receiving_slot")
		):
			point.release_receiving_slot(int(entry.get("slot", -1)))

	_retained_expiring = 0
	_retention_accum = 0.0
	_receiving_occupancy_by_point.clear()
	_receiving_occupancy_total = 0
	return removed


## Called when an exit is deleted. Retained agents cannot outlive the point that
## owns their receiving slots, so drop them without releasing slots (the point
## is going away) and remove its occupancy entry.
func release_retained_for_point(point: Node) -> int:
	if point == null or not is_instance_valid(point):
		return 0

	var removed: int = 0

	for index: int in range(_retained.size() - 1, -1, -1):
		var entry: Dictionary = _retained[index]

		if entry.get("point") != point:
			continue

		_retained.remove_at(index)
		removed += 1

		if float(entry.get("expires_at", 0.0)) > 0.0:
			_retained_expiring = maxi(0, _retained_expiring - 1)

		var node: Variant = entry.get("node")

		if node != null and is_instance_valid(node):
			node.queue_free()

	_receiving_occupancy_by_point.erase(point.get_instance_id())
	_receiving_occupancy_total = 0

	for value: Variant in _receiving_occupancy_by_point.values():
		_receiving_occupancy_total += int(value)

	return removed


## Called by EvacPoint whenever its receiving-area occupancy changes. Updates a
## running total in O(1) so a burst of admissions does not rescan every exit on
## each event, and keeps the peak across every exit.
func notify_receiving_occupancy_changed(point: Node) -> void:
	if point == null or not is_instance_valid(point):
		return

	var current: int = 0

	if point.has_method("get_receiving_occupancy"):
		current = int(point.get_receiving_occupancy())
	elif point.has_method("get_exit_status"):
		current = int(point.get_exit_status().get("receiving_occupancy", 0))

	var id: int = point.get_instance_id()
	var previous: int = int(_receiving_occupancy_by_point.get(id, 0))
	_receiving_occupancy_total = maxi(
		0,
		_receiving_occupancy_total + current - previous
	)
	_receiving_occupancy_by_point[id] = current
	_peak_receiving_occupancy = maxi(
		_peak_receiving_occupancy,
		_receiving_occupancy_total
	)


## Per-agent evacuation records for optimizer/replay tooling. The array is
## copied so callers cannot mutate the live run.
func get_evacuation_records() -> Array[Dictionary]:
	return _evacuations.duplicate(true)


## Removes retained entries whose nodes were freed by a scene change or an
## external kill. Forever-retained agents (hold time 0) are never scanned by
## the expiry pass, so this keeps the reported count honest without a
## per-frame pass over the whole list.
func _prune_invalid_retained() -> void:
	for index: int in range(_retained.size() - 1, -1, -1):
		var entry: Dictionary = _retained[index]
		var node: Variant = entry.get("node")

		if node != null and is_instance_valid(node):
			continue

		if float(entry.get("expires_at", 0.0)) > 0.0:
			_retained_expiring = maxi(0, _retained_expiring - 1)

		_retained.remove_at(index)


## A complete snapshot for the results panel.
func get_summary() -> Dictionary:
	_prune_invalid_retained()
	var now: int = _now_ms()
	var running: bool = GlobalData.is_spawning_enabled
	var spawned: int = GlobalData.npcs_spawned
	var evacuated: int = GlobalData.npcs_evacuated

	var end_ms: int = now
	if not running and _last_activity_ms > 0:
		end_ms = maxi(_last_activity_ms, _run_started_ms)

	var elapsed: float = 0.0
	if _run_started_ms > 0:
		elapsed = maxf(0.0, float(end_ms - _run_started_ms) / 1000.0)

	var alive: int = 0
	if get_tree() != null:
		alive = get_tree().get_nodes_in_group("npc").size()

	var timing := _timing_stats()
	var exits: Array = []
	var statuses: Dictionary = _collect_exit_statuses()
	var seen_exits: Dictionary = {}

	for exit_key: String in _exits:
		seen_exits[exit_key] = true
		exits.append(_build_exit_summary(
			_exits[exit_key],
			statuses.get(exit_key, {}),
			elapsed,
			evacuated
		))

	# Include configured points that have not admitted anyone yet so a finite
	# receiving area can show its capacity/occupancy before the first arrival.
	for exit_key: String in statuses:
		if seen_exits.has(exit_key):
			continue

		exits.append(_build_exit_summary(
			{"exit_id": exit_key, "name": String(statuses[exit_key].get("name", "Exit"))},
			statuses[exit_key],
			elapsed,
			evacuated
		))

	exits.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["arrivals"]) > int(b["arrivals"])
	)

	var receiving_occupancy: int = 0
	var receiving_capacity: int = 0
	var receiving_queue: int = 0
	var capacity_waits: int = 0
	var capacity_rejections: int = 0
	var queue_full_rejections: int = 0
	var capped_exits: int = 0
	var unlimited_exits: int = 0

	for status: Dictionary in statuses.values():
		receiving_occupancy += int(status.get("receiving_occupancy", 0))
		receiving_queue += int(status.get("current_queue", 0))
		capacity_waits += int(status.get("capacity_waits", 0))
		capacity_rejections += int(status.get("capacity_rejections", 0))
		queue_full_rejections += int(status.get("queue_full_rejections", 0))

		var capacity: int = int(status.get("receiving_capacity", 0))

		if capacity > 0:
			receiving_capacity += capacity
			capped_exits += 1
		else:
			unlimited_exits += 1

	# "Unlimited" is only true when every configured exit is uncapped. Mixed
	# layouts report both the finite total and the fact that some exits are open.
	var unlimited_receiving: bool = (
		statuses.is_empty() or unlimited_exits == statuses.size()
	)

	# Recompute the running total from live exits so a freed point cannot leave
	# a stale occupancy behind in the incremental tracker.
	_receiving_occupancy_total = receiving_occupancy
	_peak_receiving_occupancy = maxi(
		_peak_receiving_occupancy,
		receiving_occupancy
	)

	var total_quota: int = GlobalData.get_total_max_spawns()
	var complete: bool = (
		spawned > 0
		and total_quota >= 0
		and spawned >= total_quota
		and alive == 0
	)

	var contact_stats: Dictionary = {}
	var crowd := get_node_or_null("/root/CrowdManager")

	if crowd != null and crowd.has_method("get_contact_force_stats"):
		contact_stats = crowd.get_contact_force_stats()

	return {
		"running": running,
		"complete": complete,
		"elapsed": elapsed,
		"spawned": spawned,
		"evacuated": evacuated,
		"alive": alive,
		"total_quota": total_quota,
		"active_records": _records.size(),
		"failed_paths": _failed_paths,
		"deaths": _deaths,
		"peak_density": _peak_density,
		"total_distance": _total_distance,
		"average_distance": _total_distance / float(maxi(evacuated, 1)),
		"total_stuck_time": _total_stuck_time,
		"total_stuck_strikes": _total_stuck_strikes,
		"average_pre_movement": _total_pre_movement / float(maxi(evacuated, 1)),
		"peak_contact_force": _peak_contact_force,
		"contact_force_stats": contact_stats,
		"average_time": timing["average"],
		"median_time": timing["median"],
		"p95_time": timing["p95"],
		"min_time": timing["min"],
		"max_time": timing["max"],
		"receiving_occupancy": receiving_occupancy,
		"peak_receiving_occupancy": _peak_receiving_occupancy,
		"receiving_capacity": receiving_capacity,
		"receiving_unlimited": unlimited_receiving,
		"receiving_capped_exits": capped_exits,
		"receiving_unlimited_exits": unlimited_exits,
		"receiving_queue": receiving_queue,
		"capacity_waits": capacity_waits,
		"capacity_rejections": capacity_rejections,
		"queue_full_rejections": queue_full_rejections,
		"retained_agents": _retained.size(),
		"evacuations_recorded": _evacuations.size(),
		"exits": exits,
	}


func _build_exit_summary(
	exit: Dictionary,
	status: Dictionary,
	elapsed: float,
	evacuated_total: int
) -> Dictionary:
	var arrivals: int = int(exit.get("arrivals", 0))
	var total_time: float = float(exit.get("total_time", 0.0))
	var total_wait: float = float(exit.get("total_wait", 0.0))
	var configured: bool = not status.is_empty()

	return {
		"exit_id": String(exit.get("exit_id", status.get("exit_id", ""))),
		"name": String(exit.get("name", status.get("name", "Exit"))),
		"arrivals": arrivals,
		"average_time": total_time / float(maxi(arrivals, 1)),
		"min_time": float(exit.get("min_time", 0.0)),
		"max_time": float(exit.get("max_time", 0.0)),
		"throughput_per_minute": (
			float(arrivals) / maxf(elapsed, 0.001) * 60.0
		),
		"throughput_per_second": float(arrivals) / maxf(elapsed, 0.001),
		"share": float(arrivals) / float(maxi(evacuated_total, 1)),
		"average_wait": float(status.get(
			"average_wait",
			total_wait / float(maxi(arrivals, 1))
		)),
		"max_wait": float(status.get("max_wait", exit.get("max_wait", 0.0))),
		"service_rate": float(status.get("service_rate", 0.0)),
		"receiving_capacity": int(status.get("receiving_capacity", 0)),
		"receiving_occupancy": int(status.get("receiving_occupancy", 0)),
		"peak_occupancy": int(status.get("peak_occupancy", 0)),
		"current_queue": int(status.get("current_queue", 0)),
		"max_queue": int(status.get("max_queue", 0)),
		"capacity_waits": int(status.get("capacity_waits", 0)),
		"capacity_rejections": int(status.get("capacity_rejections", 0)),
		"queue_full_rejections": int(status.get("queue_full_rejections", 0)),
		"retained": bool(status.get("retain", false)),
		"configured": configured,
	}


func _collect_exit_statuses() -> Dictionary:
	var result: Dictionary = {}
	var tree: SceneTree = get_tree()

	if tree == null:
		return result

	var seen: Dictionary = {}

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node):
			continue

		if not node.has_method("get_exit_status"):
			continue

		var id: int = node.get_instance_id()
		if seen.has(id):
			continue
		seen[id] = true

		var status: Dictionary = node.get_exit_status()
		var key: String = String(status.get("exit_id", node.get_path()))
		result[key] = status

	return result


func _record_for(npc: Node) -> Dictionary:
	if npc == null or not is_instance_valid(npc):
		return {}

	var id: int = npc.get_instance_id()
	if not _records.has(id):
		register_npc(npc)

	return _records.get(id, {})


func _timing_stats() -> Dictionary:
	var sorted: Array[float] = _arrivals.duplicate()
	sorted.sort()

	var count: int = sorted.size()
	if count == 0:
		return {
			"average": 0.0,
			"median": 0.0,
			"p95": 0.0,
			"min": 0.0,
			"max": 0.0,
		}

	var total: float = 0.0
	for value: float in sorted:
		total += value

	var middle: int = int(count / 2.0)
	var median: float = sorted[middle]
	if count % 2 == 0:
		median = (sorted[middle - 1] + sorted[middle]) * 0.5

	var p95_index: int = clampi(
		int(ceilf(float(count) * 0.95)) - 1,
		0,
		count - 1
	)

	return {
		"average": total / float(count),
		"median": median,
		"p95": sorted[p95_index],
		"min": sorted[0],
		"max": sorted[count - 1],
	}


func _exit_key(exit_node: Node3D) -> String:
	if exit_node == null or not is_instance_valid(exit_node):
		return "unknown"
	return String(exit_node.get_path())


func _exit_label(exit_node: Node3D) -> String:
	if exit_node == null or not is_instance_valid(exit_node):
		return "Unknown exit"

	var label: String = String(exit_node.name)
	if label == "Area3D" and exit_node.get_parent() != null:
		label = String(exit_node.get_parent().name)
	return label


func _now_ms() -> int:
	# Physics-clock milliseconds. Wall time keeps running through pauses and
	# frame hitches, which used to inflate measured evacuation times.
	return int(round(GlobalData.sim_now() * 1000.0))
