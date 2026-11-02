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


func _ready() -> void:
	GlobalData.spawning_reset.connect(reset_run)
	GlobalData.spawning_started.connect(begin_run)


func begin_run() -> void:
	if _run_started_ms == 0:
		_run_started_ms = _now_ms()

	_last_activity_ms = _now_ms()


func reset_run() -> void:
	_records.clear()
	_arrivals.clear()
	_exits.clear()
	_failed_paths = 0
	_deaths = 0
	_peak_density = 0.0
	_total_distance = 0.0
	_total_stuck_time = 0.0
	_total_stuck_strikes = 0
	_run_started_ms = 0
	_last_activity_ms = 0
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


## Called from EvacPoint before the body is freed.
func register_evacuation(npc: Node, exit_node: Node3D) -> void:
	if npc == null or not is_instance_valid(npc):
		return

	var id: int = npc.get_instance_id()
	var now: int = _now_ms()
	var record: Dictionary = _records.get(id, {})
	var spawn_ms: int = int(record.get("spawn_ms", now))

	if _run_started_ms == 0:
		_run_started_ms = spawn_ms

	var snapshot: Dictionary = {}
	if npc.has_method("get_evacuation_snapshot"):
		snapshot = npc.get_evacuation_snapshot()

	if snapshot.has("peak_density"):
		_peak_density = maxf(_peak_density, float(snapshot["peak_density"]))
	if snapshot.has("distance"):
		_total_distance += float(snapshot["distance"])
	if snapshot.has("stuck_time"):
		_total_stuck_time += float(snapshot["stuck_time"])
	if snapshot.has("stuck_strikes"):
		_total_stuck_strikes += int(snapshot["stuck_strikes"])

	var duration: float = maxf(0.0, float(now - spawn_ms) / 1000.0)
	var exit_key: String = _exit_key(exit_node)
	var exit: Dictionary = _exits.get(exit_key, {})

	if exit.is_empty():
		exit = {
			"name": _exit_label(exit_node),
			"arrivals": 0,
			"total_time": 0.0,
			"min_time": duration,
			"max_time": duration,
			"first_ms": now,
			"last_ms": now,
		}
		_exits[exit_key] = exit

	exit["arrivals"] = int(exit["arrivals"]) + 1
	exit["total_time"] = float(exit["total_time"]) + duration
	exit["min_time"] = minf(float(exit["min_time"]), duration)
	exit["max_time"] = maxf(float(exit["max_time"]), duration)
	exit["last_ms"] = now

	_arrivals.append(duration)
	_records.erase(id)
	_last_activity_ms = now
	metrics_changed.emit()


## A complete snapshot for the results panel.
func get_summary() -> Dictionary:
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

	for exit_key: String in _exits:
		var exit: Dictionary = _exits[exit_key]
		var arrivals: int = int(exit["arrivals"])
		var average: float = (
			float(exit["total_time"]) / float(maxi(arrivals, 1))
		)

		exits.append({
			"name": String(exit["name"]),
			"arrivals": arrivals,
			"average_time": average,
			"min_time": float(exit["min_time"]),
			"max_time": float(exit["max_time"]),
			"throughput_per_minute": (
				float(arrivals) / maxf(elapsed, 0.001) * 60.0
			),
			"share": float(arrivals) / float(maxi(evacuated, 1)),
		})

	exits.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["arrivals"]) > int(b["arrivals"])
	)

	var total_quota: int = GlobalData.get_total_max_spawns()
	var complete: bool = (
		spawned > 0
		and total_quota >= 0
		and spawned >= total_quota
		and alive == 0
	)

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
		"average_time": timing["average"],
		"median_time": timing["median"],
		"p95_time": timing["p95"],
		"min_time": timing["min"],
		"max_time": timing["max"],
		"exits": exits,
	}


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
	return Time.get_ticks_msec()
