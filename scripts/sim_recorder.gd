extends Node

## Simulation demo recorder.
##
## Writes every run to `user://runs/<timestamp>_seed<seed>/`:
##   recording.jsonl  one JSON object per line (run, tick, route, evacuation,
##                    environment/disruption, exit_state, end)
##   manifest.json    format/schema/capabilities for readers
##   summary.json     final run aggregates
##
## This is the measurement layer for the future demo player and layout
## comparer. Those consumers are intentionally not implemented yet; the file
## format is documented in docs/SIM_MEASUREMENTS.md.
##
## Sampling is time-based on GlobalData.sim_now(), so pauses and frame hitches
## do not stretch or skip measured simulation time.

const FORMAT: String = "ero-sim-recording"
const VERSION: int = 1

## Agent tick row order. Keep in sync with `_sample()`.
const AGENT_FIELDS: Array[String] = [
	"serial", "status", "state",
	"x", "y", "z",
	"vx", "vy", "vz",
	"speed", "ax", "ay", "az",
	"dest_x", "dest_y", "dest_z",
	"exit_id", "route_id", "route_index", "route_points",
	"route_length", "remaining_length", "distance",
	"contact_force", "density",
	"route_changes", "route_switches", "stuck_strikes",
	"evacuated_at",
]

## Exit tick row order. Keep in sync with `_sample()`.
const EXIT_FIELDS: Array[String] = [
	"exit_id", "name", "operational", "available",
	"accepted", "current_queue", "max_queue",
	"receiving_occupancy", "peak_occupancy",
	"average_wait", "max_wait", "service_rate",
	"admission_rate", "utilization", "assigned",
	"share", "rejected", "capacity_waits",
	"capacity_rejections", "queue_full_rejections",
]

@export var recording_enabled: bool = true
@export var sampling_interval: float = 0.25
@export var flush_interval: float = 1.0
@export var record_paths: bool = true
@export var max_path_points: int = 256
@export var record_nav_graph: bool = true
@export var nav_graph_edge_limit: int = 20000
@export var record_initial_layout: bool = true
@export var layout_cell_limit: int = 50000
@export var output_root: String = "user://runs"
## Agents whose current route passes this close to an edit are "affected".
@export var disruption_route_radius: float = 3.0
@export var disruption_vertical_tolerance: float = 2.0
## How long after a disruption a route change is attributed to it.
@export var disruption_window: float = 15.0

var _recording: bool = false
var _file: FileAccess = null
var _run_dir: String = ""
var _run_id: String = ""
var _demo_id: String = ""
var _demo_save_slug: String = ""
var _run_exit_catalog: Array = []
var _experiment_metadata: Dictionary = {}
var _started_sim: float = 0.0
var _started_unix: String = ""
var _last_sample_sim: float = -1.0
var _sample_count: int = 0
var _flush_accum: float = 0.0

var _grid: NavGridMap = null
var _agents: Dictionary = {} # instance id -> Member
var _spawn_serials: Dictionary = {} # serial -> true
var _evacuated_serials: Dictionary = {} # serial -> true
var _dead_serials: Dictionary = {} # serial -> true
var _last_routes: Dictionary = {} # serial -> {route_id, exit_id, target, path}
var _known_exit_ids: Dictionary = {}
var _exit_signal_ids: Dictionary = {}
var _exit_accepted_at_start: Dictionary = {} # exit_id -> accepted
var _last_exit_statuses: Dictionary = {}
var _last_exit_rows: Array = []
var _last_sim_stats: Dictionary = {}

var _evac_times: Array[float] = []
var _evacuation_distance_total: float = 0.0
var _last_evac_sim: float = -1.0
var _route_changes_total: int = 0
var _route_switches_total: int = 0
var _destination_changes_total: int = 0
var _max_route_changes: int = 0
var _max_route_switches: int = 0

var _density_integral: float = 0.0
var _density_time: float = 0.0
var _density_peak: float = 0.0
var _speed_integral: float = 0.0
var _speed_time: float = 0.0

var _pending_environment: Array[Dictionary] = []
var _environment_seq: int = 0
var _disruption_seq: int = 0
var _disruptions: Array[Dictionary] = []
var _active_disruption: Dictionary = {}
var _pre_disruption: Dictionary = {} # serial -> {route_id, exit_id, target}
var _affected: Dictionary = {} # serial -> true
var _rerouted: Dictionary = {} # serial -> true (all disruptions)
var _rerouted_current: Dictionary = {} # serial -> true (latest disruption)

var _last_nav_cells: int = 0
var _nav_total_at_start: int = 0
var _path_total_at_start: int = 0
var _nav_count_at_start: int = 0
var _path_count_at_start: int = 0
var _summary_peak_contact_force: float = 0.0
var _summary_contact_pairs: int = 0
var _summary_contact_samples: int = 0
var _summary_contact_solves: int = 0
var _summary: Dictionary = {}
## Events declared by a scenario before/at run start. No automatic scheduler
## exists; this is metadata for reproducible experiments.
var _scheduled_events: Array[Dictionary] = []

## Optimizer configuration for this run. Written into the manifest/run header so
## a demo records which objective produced it. Empty until a bridge (or a test)
## registers a configuration; the default describes the local logit baseline.
var _optimizer_configuration: Dictionary = {
	"available": false,
	"algorithm": "",
	"mode": "",
	"weights": {},
	"parameters": {},
	"cohort_size": 0.0,
	"max_cohorts": 0,
}
var _optimizer_last_usec: int = 0
var _optimizer_executions: int = 0


func _ready() -> void:
	process_priority = 50
	GlobalData.spawning_started.connect(_on_run_started)
	GlobalData.spawning_stopped.connect(_on_run_stopped)
	GlobalData.spawning_reset.connect(_on_run_reset)
	GlobalData.agent_spawned.connect(_on_agent_spawned)
	GlobalData.environment_changed.connect(_on_environment_changed)

	var manager := get_node_or_null("/root/EvacuationManager")

	if manager != null:
		if manager.has_signal("evacuation_recorded"):
			manager.evacuation_recorded.connect(_on_evacuation_recorded)
		if manager.has_signal("npc_died"):
			manager.npc_died.connect(_on_npc_died)

	var crowd := get_node_or_null("/root/CrowdManager")

	if crowd != null and crowd.has_signal("contact_threshold_crossed"):
		crowd.contact_threshold_crossed.connect(_on_contact_threshold_crossed)


func _process(delta: float) -> void:
	if not _recording:
		return

	if not _pending_environment.is_empty():
		_flush_environment()

	_flush_accum += delta

	if _flush_accum >= flush_interval and _file != null:
		_flush_accum = 0.0
		_file.flush()

	# Once every spawned agent has left the active crowd, stop sampling until
	# the run is reset or new agents appear. Otherwise an idle ended run writes
	# an unbounded number of empty ticks.
	if (
		_spawn_serials.size() > 0
		and int(_last_sim_stats.get("active", -1)) == 0
		and get_tree() != null
		and get_tree().get_nodes_in_group("npc").is_empty()
	):
		return

	var now: float = GlobalData.sim_now()

	if _last_sample_sim < 0.0 or now - _last_sample_sim >= sampling_interval:
		_sample(now)


func _exit_tree() -> void:
	_finalize("exit")


# ---------------------------------------------------------------------------
# PUBLIC API (recorder now; player/comparer later)
# ---------------------------------------------------------------------------

func is_recording() -> bool:
	return _recording


func get_run_dir() -> String:
	return _run_dir


func get_last_summary() -> Dictionary:
	return _summary.duplicate(true)


func set_recording_enabled(value: bool) -> void:
	recording_enabled = value

	if not value and _recording:
		_finalize("disabled")
	elif value and not _recording and GlobalData.is_spawning_enabled:
		# Re-enabling mid-run starts a fresh file from this point.
		_begin_run()


## Declare a planned environmental event for the next/current run. This is
## recorded as experiment metadata; it does not execute the event.
func schedule_environment_event(
	at_sim_time: float,
	kind: String,
	location: Vector3,
	detail: Dictionary = {}
) -> void:
	_scheduled_events.append({
		"at": at_sim_time,
		"kind": kind,
		"location": location,
		"detail": detail.duplicate(true),
	})


## Register the optimizer configuration for the next/current run. The bridge
## calls this whenever the algorithm, mode, weights or enable flag changes, so
## the manifest can describe the run even before the first solve.
func set_optimizer_configuration(configuration: Dictionary) -> void:
	_optimizer_configuration = configuration.duplicate(true)

	if not _optimizer_configuration.has("available"):
		_optimizer_configuration["available"] = false


func get_optimizer_configuration() -> Dictionary:
	return _optimizer_configuration.duplicate(true)


## Record an optimizer execution step. The detail dictionary is the optimizer's
## estimate and the application outcome; measured outcomes stay in the run
## summary, never in this event.
func record_optimizer_execution(
	name: String,
	duration_usec: int,
	detail: Dictionary = {}
) -> void:
	if not _recording:
		return

	_optimizer_last_usec = maxi(0, duration_usec)
	_optimizer_executions += 1

	_write({
		"type": "optimizer",
		"t": GlobalData.sim_now(),
		"name": name,
		"duration_usec": duration_usec,
		"detail": detail,
	})


# ---------------------------------------------------------------------------
# RUN LIFECYCLE
# ---------------------------------------------------------------------------

func _on_run_started() -> void:
	if not recording_enabled:
		return

	if _recording:
		_finalize("restart")

	_begin_run()


func _on_run_stopped() -> void:
	_finalize("stopped")


func _on_run_reset() -> void:
	_finalize("reset")


func _begin_run() -> void:
	_reset_run_state()
	_started_sim = GlobalData.sim_now()
	_started_unix = Time.get_datetime_string_from_system(false, true)
	var default_name: String = "Run %s" % _safe_stamp(_started_unix)
	var demo_store := get_node_or_null("/root/DemoStore")

	if demo_store != null:
		_demo_save_slug = String(demo_store.active_save_slug())
		var created: Dictionary = demo_store.create_demo(default_name, {
			"seed": GlobalData.rng_seed,
			"scene": _scene_path(),
			"sample_interval": sampling_interval,
			"status": "recording",
			"started_at": _started_unix,
		}, _demo_save_slug)

		if created.is_empty():
			push_warning("SimRecorder: DemoStore could not create a demo folder")
			return

		_demo_id = String(created.get("id", ""))
		_run_dir = String(created.get("dir", ""))
	else:
		_demo_save_slug = ""
		_demo_id = ""
		_run_id = "%s_seed%d" % [_safe_stamp(_started_unix), GlobalData.rng_seed]
		_run_dir = output_root.path_join(_run_id)

	_run_id = _demo_id if not _demo_id.is_empty() else _run_id
	DirAccess.make_dir_recursive_absolute(_run_dir)
	_file = FileAccess.open(_run_dir.path_join("recording.jsonl"), FileAccess.WRITE)

	if _file == null:
		push_warning("SimRecorder: cannot open %s" % _run_dir)
		return

	_recording = true
	_last_sample_sim = -1.0
	_cache_grid()

	if _grid != null:
		_nav_total_at_start = _grid.nav_refresh_total_usec
		_path_total_at_start = _grid.path_request_total_usec
		_nav_count_at_start = _grid.nav_refresh_count
		_path_count_at_start = _grid.path_request_count

	var exits: Array = _collect_exits()
	var exit_catalog: Array = []

	for entry: Dictionary in exits:
		exit_catalog.append(_exit_catalog_entry(entry["status"]))
		var start_exit_id: String = String(entry["status"].get("exit_id", ""))
		_known_exit_ids[start_exit_id] = true
		_exit_accepted_at_start[start_exit_id] = int(entry["status"].get("accepted", 0))
		_connect_exit_signal(entry["node"])

	var metadata: Dictionary = _collect_experiment_metadata(exit_catalog)
	_run_exit_catalog = exit_catalog.duplicate(true)
	_experiment_metadata = metadata.duplicate(true)
	_write_manifest(exit_catalog, metadata)

	if demo_store != null and not _demo_id.is_empty():
		# Make the demo self-describing while it is still recording, not only
		# when it finalises. Otherwise a comparer opened on an in-progress demo
		# sees an empty experiment block and every B value reads as null.
		demo_store.update_demo(_demo_id, {
			"experiment": _json_ready(_experiment_metadata),
			"exit_configuration": _run_exit_catalog.duplicate(true),
		}, _demo_save_slug)

	var run_record: Dictionary = {
		"type": "run",
		"t": _started_sim,
		"format": FORMAT,
		"version": VERSION,
		"run_id": _run_id,
		"demo_id": _demo_id,
		"save_slug": _demo_save_slug,
		"started_at": _started_unix,
		"rng_seed": GlobalData.rng_seed,
		"scene": _scene_path(),
		"sample_interval": sampling_interval,
		"fields": {"agent": AGENT_FIELDS, "exit": EXIT_FIELDS},
		"capabilities": _capabilities(),
		"exits": exit_catalog,
		"nav": _connectivity(),
		"metadata": metadata,
	}
	_write(run_record)

	if record_nav_graph:
		_write_nav_graph()

	if record_initial_layout:
		_write_layout()

	_register_existing_agents()


func _finalize(reason: String) -> void:
	if not _recording:
		return

	var summary: Dictionary = _build_summary(reason)
	_write({"type": "end", "t": GlobalData.sim_now(), "reason": reason, "summary": summary})

	if _file != null:
		_file.flush()
		_file.close()

	_file = null
	_recording = false
	_summary = summary
	_write_summary_file(summary)
	_update_demo_metadata(summary)
	_clear_run_state()


func _update_demo_metadata(summary: Dictionary) -> void:
	if _demo_id.is_empty():
		return

	var demo_store := get_node_or_null("/root/DemoStore")

	if demo_store == null or not demo_store.has_method("update_demo"):
		return

	var status: String = "complete" if bool(summary.get("all_required_evacuated", false)) else "partial"

	if int(summary.get("agents_evacuated", 0)) == 0:
		status = "stopped"

	demo_store.update_demo(_demo_id, {
		"status": status,
		"duration": float(summary.get("duration", 0.0)),
		"agents": int(summary.get("agents_spawned", 0)),
		"seed": int(summary.get("rng_seed", 0)),
		"scene": String(summary.get("scene", "")),
		"sample_interval": sampling_interval,
		"summary": {
			"agents_evacuated": int(summary.get("agents_evacuated", 0)),
			"agents_active": int(summary.get("agents_active", 0)),
			"total_evacuation_time": float(summary.get("total_evacuation_time", 0.0)),
			"average_evacuation_time": float(summary.get("average_evacuation_time", 0.0)),
			"max_evacuation_time": float(summary.get("max_evacuation_time", 0.0)),
			"global_max_density": float(summary.get("global_max_density", 0.0)),
			"peak_contact_force": float(summary.get("peak_contact_force", 0.0)),
			"route_switches_total": int(summary.get("route_switches_total", 0)),
			"disruptions": int(summary.get("disruptions", []).size()),
		},
		"files": {
			"recording": _run_dir.path_join("recording.jsonl"),
			"manifest": _run_dir.path_join("manifest.json"),
			"summary": _run_dir.path_join("summary.json"),
		},
		"exit_configuration": _run_exit_catalog.duplicate(true),
		"experiment": _json_ready(_experiment_metadata),
	}, _demo_save_slug)


func _reset_run_state() -> void:
	_agents.clear()
	_spawn_serials.clear()
	_evacuated_serials.clear()
	_dead_serials.clear()
	_last_routes.clear()
	_known_exit_ids.clear()
	_exit_accepted_at_start.clear()
	_last_exit_statuses.clear()
	_last_exit_rows.clear()
	_last_sim_stats.clear()
	_evac_times.clear()
	_evacuation_distance_total = 0.0
	_last_evac_sim = -1.0
	_route_changes_total = 0
	_route_switches_total = 0
	_destination_changes_total = 0
	_max_route_changes = 0
	_max_route_switches = 0
	_density_integral = 0.0
	_density_time = 0.0
	_density_peak = 0.0
	_speed_integral = 0.0
	_speed_time = 0.0
	_summary_peak_contact_force = 0.0
	_summary_contact_pairs = 0
	_summary_contact_samples = 0
	_summary_contact_solves = 0
	_pending_environment.clear()
	_environment_seq = 0
	_disruption_seq = 0
	_disruptions.clear()
	_active_disruption.clear()
	_pre_disruption.clear()
	_affected.clear()
	_rerouted.clear()
	_rerouted_current.clear()
	_last_nav_cells = 0
	_sample_count = 0
	_flush_accum = 0.0
	_optimizer_last_usec = 0
	_optimizer_executions = 0


func _clear_run_state() -> void:
	_agents.clear()
	_last_routes.clear()
	_pending_environment.clear()
	_disruptions.clear()
	_active_disruption.clear()
	_pre_disruption.clear()
	_affected.clear()
	_rerouted.clear()
	_rerouted_current.clear()


# ---------------------------------------------------------------------------
# AGENT REGISTRATION AND EVENTS
# ---------------------------------------------------------------------------

func _on_agent_spawned(npc: Node) -> void:
	if _recording:
		_register_agent(npc, false)


func _register_existing_agents() -> void:
	var tree: SceneTree = get_tree()

	if tree == null:
		return

	for npc: Node in tree.get_nodes_in_group("npc"):
		_register_agent(npc, true)


func _register_agent(npc: Node, existing: bool) -> void:
	if npc == null or not is_instance_valid(npc):
		return

	var id: int = npc.get_instance_id()

	if _agents.has(id):
		return

	_agents[id] = npc

	if npc.has_signal("route_changed") and not npc.route_changed.is_connected(_on_agent_route_changed):
		npc.route_changed.connect(_on_agent_route_changed)

	if npc.has_signal("destination_changed") and not npc.destination_changed.is_connected(_on_agent_destination_changed):
		npc.destination_changed.connect(_on_agent_destination_changed)

	var serial: int = int(npc.get("agent_serial"))
	_spawn_serials[serial] = true

	var record: Dictionary = {
		"type": "agent_spawn",
		"t": GlobalData.sim_now(),
		"existing_at_start": existing,
		"agent": serial,
		"agent_id": id,
		"name": String(npc.name),
		"position": npc.global_position,
		"desired_speed": float(npc.get("desired_speed")),
		"pre_movement_delay": float(npc.call("get_pre_movement_delay")),
	}
	_write(record)

	if npc.has_method("get_route_snapshot"):
		var route: Dictionary = npc.call("get_route_snapshot")

		if not route.is_empty():
			_write_route(route)


func _on_agent_route_changed(info: Dictionary) -> void:
	if not _recording:
		return

	_write_route(info)


func _on_agent_destination_changed(info: Dictionary) -> void:
	if not _recording:
		return

	_destination_changes_total += 1
	_write({
		"type": "destination",
		"t": float(info.get("at", GlobalData.sim_now())),
		"agent": int(info.get("agent_serial", -1)),
		"previous_target": info.get("previous_target", Vector3.ZERO),
		"previous_exit_id": String(info.get("previous_exit_id", "")),
		"target": info.get("target", Vector3.ZERO),
		"exit_id": String(info.get("exit_id", "")),
		"exit_name": String(info.get("exit_name", "")),
	})


func _write_route(info: Dictionary) -> void:
	var serial: int = int(info.get("agent_serial", -1))
	var previous: Dictionary = _last_routes.get(serial, {}).duplicate()
	var pre: Dictionary = _pre_disruption.get(serial, {})

	if not pre.is_empty():
		previous["route_id"] = int(pre.get("route_id", 0))
		previous["exit_id"] = String(pre.get("exit_id", ""))
		previous["target"] = pre.get("target", Vector3.ZERO)
	var t: float = float(info.get("at", GlobalData.sim_now()))
	var path: PackedVector3Array = info.get("path", PackedVector3Array())
	var record: Dictionary = {
		"type": "route",
		"t": t,
		"agent": serial,
		"route_id": int(info.get("route_id", 0)),
		"previous_route_id": int(info.get("previous_route_id", 0)),
		"reason": String(info.get("reason", "")),
		"mode": String(info.get("mode", "path")),
		"success": bool(info.get("success", true)),
		"evacuating": bool(info.get("evacuating", true)),
		"target": info.get("target", Vector3.ZERO),
		"exit_id": String(info.get("exit_id", "")),
		"exit_name": String(info.get("exit_name", "")),
		"path_points": int(info.get("path_points", 0)),
		"route_length": float(info.get("route_length", 0.0)),
		"remaining_length": float(info.get("remaining_length", 0.0)),
		"path_usec": int(info.get("path_usec", 0)),
		"switched": bool(info.get("switched", false)),
		"route_changes": int(info.get("route_changes", 0)),
		"route_switches": int(info.get("route_switches", 0)),
	}

	if record_paths:
		record["path"] = _path_array(path)
		record["path_cells"] = info.get("path_cells", [])

	var disruption: Dictionary = _active_disruption_for(t)

	if not disruption.is_empty() and _affected.has(serial) and not _rerouted_current.has(serial):
		record["type"] = "route_change"
		record["disruption_id"] = String(disruption.get("id", ""))
		record["before"] = {
			"route_id": int(previous.get("route_id", 0)),
			"exit_id": String(previous.get("exit_id", "")),
			"target": previous.get("target", Vector3.ZERO),
		}
		record["after"] = {
			"route_id": record["route_id"],
			"exit_id": record["exit_id"],
			"target": record["target"],
		}

		if record_paths and previous.has("path"):
			var before_path: Variant = previous.get("path", [])
			record["before_path"] = (
				before_path
				if before_path is Array
				else _path_array(before_path)
			)

		_rerouted_current[serial] = true
		_rerouted[serial] = true
		disruption["rerouted"] = int(disruption.get("rerouted", 0)) + 1
		disruption["route_reassignment_t"] = t

	_write(record)

	_last_routes[serial] = {
		"route_id": record["route_id"],
		"exit_id": record["exit_id"],
		"target": record["target"],
		"path": record.get("path", []),
	}

	if String(record["reason"]) != "snapshot":
		_route_changes_total += 1

	if bool(record["switched"]):
		_route_switches_total += 1

	_max_route_changes = maxi(_max_route_changes, int(record["route_changes"]))
	_max_route_switches = maxi(_max_route_switches, int(record["route_switches"]))


func _on_evacuation_recorded(record: Dictionary) -> void:
	if not _recording:
		return

	var t: float = GlobalData.sim_now()
	var serial: int = int(record.get("agent_serial", -1))
	var evacuation_time: float = float(record.get("evacuation_time", 0.0))
	var event: Dictionary = {
		"type": "evacuation",
		"t": t,
		"agent": serial,
		"agent_id": int(record.get("agent_id", 0)),
		"exit_id": String(record.get("exit_id", "")),
		"exit_name": String(record.get("exit_name", "")),
		"evacuation_time": evacuation_time,
		"time_since_run_start": t - _started_sim,
		"wait_time": float(record.get("wait_time", 0.0)),
		"distance": float(record.get("distance", 0.0)),
		"stuck_time": float(record.get("stuck_time", 0.0)),
		"stuck_strikes": int(record.get("stuck_strikes", 0)),
		"peak_density": float(record.get("peak_density", 0.0)),
		"pre_movement_wait": float(record.get("pre_movement_wait", 0.0)),
	}
	_write(event)

	_evac_times.append(evacuation_time)
	_evacuation_distance_total += float(record.get("distance", 0.0))
	_last_evac_sim = maxf(_last_evac_sim, t)
	_evacuated_serials[serial] = true
	_last_routes.erase(serial)
	_agents.erase(int(record.get("agent_id", 0)))


func _on_npc_died(npc: Node) -> void:
	if not _recording or npc == null or not is_instance_valid(npc):
		return

	var serial: int = int(npc.get("agent_serial"))
	_dead_serials[serial] = true
	_agents.erase(npc.get_instance_id())
	_last_routes.erase(serial)
	_write({
		"type": "agent_death",
		"t": GlobalData.sim_now(),
		"agent": serial,
		"position": npc.global_position,
	})


# ---------------------------------------------------------------------------
# SAMPLING
# ---------------------------------------------------------------------------

func _sample(now: float) -> void:
	var dt: float = 0.0

	if _last_sample_sim >= 0.0:
		dt = maxf(0.0, now - _last_sample_sim)

	_last_sample_sim = now
	var tree: SceneTree = get_tree()

	if tree == null:
		return

	var rows: Array = []
	var assigned: Dictionary = {}
	var density_sum: float = 0.0
	var speed_sum: float = 0.0
	var max_density: float = 0.0
	var active: int = 0

	for npc: Node in tree.get_nodes_in_group("npc"):
		if npc == null or not is_instance_valid(npc):
			continue

		if not npc.has_method("get_measurement_state"):
			continue

		var state: Dictionary = npc.call("get_measurement_state")
		var position: Vector3 = state.get("position", Vector3.ZERO)
		var velocity: Vector3 = state.get("velocity", Vector3.ZERO)
		var acceleration: Vector3 = state.get("acceleration", Vector3.ZERO)
		var destination: Vector3 = state.get("destination", Vector3.ZERO)
		var exit_id: String = String(state.get("exit_id", ""))
		var density: float = float(state.get("density", 0.0))
		var speed: float = float(state.get("speed", 0.0))

		density_sum += density
		speed_sum += speed
		max_density = maxf(max_density, density)
		active += 1

		if not exit_id.is_empty():
			assigned[exit_id] = int(assigned.get(exit_id, 0)) + 1

		rows.append([
			int(state.get("serial", -1)),
			String(state.get("status", "active")),
			int(state.get("state", 0)),
			_n(position.x), _n(position.y), _n(position.z),
			_n(velocity.x), _n(velocity.y), _n(velocity.z),
			_n(speed),
			_n(acceleration.x), _n(acceleration.y), _n(acceleration.z),
			_n(destination.x), _n(destination.y), _n(destination.z),
			exit_id,
			int(state.get("route_id", 0)),
			int(state.get("route_index", 0)),
			int(state.get("route_points", 0)),
			_n(float(state.get("route_length", 0.0))),
			_n(float(state.get("remaining_length", 0.0))),
			_n(float(state.get("distance", 0.0))),
			_n(float(state.get("contact_force", 0.0))),
			_n(density),
			int(state.get("route_changes", 0)),
			int(state.get("route_switches", 0)),
			int(state.get("stuck_strikes", 0)),
			_n(float(state.get("evacuated_at", -1.0))),
		])

	var mean_density: float = density_sum / float(maxi(active, 1))
	var mean_speed: float = speed_sum / float(maxi(active, 1))
	_density_peak = maxf(_density_peak, max_density)

	if dt > 0.0:
		_density_integral += mean_density * dt
		_density_time += dt
		_speed_integral += mean_speed * dt
		_speed_time += dt

	var exit_rows: Array = []
	var statuses: Dictionary = {}
	var exits: Array = _collect_exits()

	for entry: Dictionary in exits:
		var node: Node = entry["node"]
		var status: Dictionary = entry["status"]
		var exit_id: String = String(status.get("exit_id", ""))
		var accepted: int = maxi(
			0,
			int(status.get("accepted", 0))
			- int(_exit_accepted_at_start.get(exit_id, 0))
		)
		var service_rate: float = float(status.get("service_rate", 0.0))
		var elapsed: float = maxf(now - _started_sim, 0.001)
		var admission_rate: float = float(accepted) / elapsed
		var utilization: Variant = null

		if service_rate > 0.0:
			utilization = admission_rate / service_rate

		statuses[exit_id] = status
		exit_rows.append([
			exit_id,
			String(status.get("name", "")),
			bool(status.get("operational", true)),
			bool(status.get("available", true)),
			accepted,
			int(status.get("current_queue", 0)),
			int(status.get("max_queue", 0)),
			int(status.get("receiving_occupancy", 0)),
			int(status.get("peak_occupancy", 0)),
			_n(float(status.get("average_wait", 0.0))),
			_n(float(status.get("max_wait", 0.0))),
			_n(service_rate),
			_n(admission_rate),
			null if utilization == null else _n(float(utilization)),
			int(assigned.get(exit_id, 0)),
			_n(float(accepted) / float(maxi(GlobalData.npcs_evacuated, 1))),
			int(status.get("rejected", 0)),
			int(status.get("capacity_waits", 0)),
			int(status.get("capacity_rejections", 0)),
			int(status.get("queue_full_rejections", 0)),
		])

		if not _known_exit_ids.has(exit_id):
			_known_exit_ids[exit_id] = true
			_write({
				"type": "exit_added",
				"t": now,
				"exit": _exit_catalog_entry(status),
			})

		_connect_exit_signal(node)

	for known_id: String in _known_exit_ids.keys():
		if statuses.has(known_id):
			continue

		_known_exit_ids.erase(known_id)
		_write({"type": "exit_removed", "t": now, "exit_id": known_id})

	var sim_stats: Dictionary = _sample_sim_stats(now, active, mean_density, max_density, mean_speed)
	var available_exits: int = 0

	for status_key: String in statuses:
		if bool(statuses[status_key].get("available", true)):
			available_exits += 1

	sim_stats["active_exits"] = statuses.size()
	sim_stats["available_exits"] = available_exits

	_last_exit_statuses = statuses
	_last_exit_rows = exit_rows
	_last_sim_stats = sim_stats
	_sample_count += 1

	_write({
		"type": "tick",
		"t": now,
		"sim": sim_stats,
		"agents": rows,
		"exits": exit_rows,
	})


func _sample_sim_stats(
	now: float,
	active: int,
	mean_density: float,
	max_density: float,
	mean_speed: float
) -> Dictionary:
	var crowd := get_node_or_null("/root/CrowdManager")
	var contact: Dictionary = {}

	if crowd != null and crowd.has_method("get_contact_force_stats"):
		contact = crowd.call("get_contact_force_stats")

	var nav_total: int = 0
	var nav_last: int = 0

	if _grid != null and is_instance_valid(_grid):
		nav_total = _grid.nav_refresh_total_usec + _grid.path_request_total_usec
		nav_last = _grid.last_nav_refresh_usec + _grid.last_path_request_usec

	_summary_peak_contact_force = maxf(
		_summary_peak_contact_force,
		float(contact.get("peak_force", 0.0))
	)
	_summary_contact_pairs = maxi(
		_summary_contact_pairs,
		int(contact.get("contact_pairs_total", 0))
	)
	_summary_contact_samples = maxi(
		_summary_contact_samples,
		int(contact.get("agent_contact_samples_total", 0))
	)
	_summary_contact_solves = maxi(
		_summary_contact_solves,
		int(contact.get("solves", 0))
	)

	return {
		"time": now,
		"elapsed": now - _started_sim,
		"active": active,
		"spawned": GlobalData.npcs_spawned,
		"evacuated": GlobalData.npcs_evacuated,
		"density_mean": mean_density,
		"density_max": max_density,
		"speed_mean": mean_speed,
		"peak_contact_force": float(contact.get("peak_force", 0.0)),
		"contact_pairs_total": int(contact.get("contact_pairs_total", 0)),
		"agent_contact_samples_total": int(contact.get("agent_contact_samples_total", 0)),
		"contact_solves": int(contact.get("solves", 0)),
		"nav_total_usec": nav_total,
		"nav_last_usec": nav_last,
		"optimizer_available": bool(_optimizer_configuration.get("available", false)),
		"optimizer_usec": _optimizer_last_usec,
		"hazard_level": null,
	}


# ---------------------------------------------------------------------------
# EXITS
# ---------------------------------------------------------------------------

func _collect_exits() -> Array:
	var result: Array = []
	var tree: SceneTree = get_tree()

	if tree == null:
		return result

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node):
			continue

		if not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")
		var exit_id: String = String(status.get("exit_id", ""))

		if exit_id.is_empty():
			continue

		var duplicate: bool = false

		for existing: Dictionary in result:
			if String(existing["status"].get("exit_id", "")) == exit_id:
				duplicate = true
				break

		if duplicate:
			continue

		result.append({"node": node, "status": status})

	return result


func _connect_exit_signal(node: Node) -> void:
	var id: int = node.get_instance_id()

	if _exit_signal_ids.has(id):
		return

	if not node.has_signal("availability_changed"):
		return

	node.availability_changed.connect(_on_exit_availability_changed)

	if node.has_signal("queue_event"):
		node.queue_event.connect(_on_exit_queue_event)

	_exit_signal_ids[id] = true


func _on_exit_queue_event(
	point: Area3D,
	agent: Node,
	event: String,
	queue_length: int
) -> void:
	if not _recording or point == null or not is_instance_valid(point):
		return

	var exit_id: String = point.get_exit_id() if point.has_method("get_exit_id") else ""
	var serial: int = int(agent.get("agent_serial")) if agent != null and is_instance_valid(agent) else -1
	_write({
		"type": "queue",
		"t": GlobalData.sim_now(),
		"exit_id": exit_id,
		"agent": serial,
		"event": event,
		"queue_length": queue_length,
	})


func _on_contact_threshold_crossed(
	npc: Node,
	force: float,
	threshold: float,
	rising: bool
) -> void:
	if not _recording or npc == null or not is_instance_valid(npc):
		return

	_write({
		"type": "contact",
		"t": GlobalData.sim_now(),
		"agent": int(npc.get("agent_serial")),
		"force": force,
		"threshold": threshold,
		"rising": rising,
	})


func _on_exit_availability_changed(point: Area3D, available: bool) -> void:
	if not _recording or point == null or not is_instance_valid(point):
		return

	var status: Dictionary = point.get_exit_status()
	var exit_id: String = String(status.get("exit_id", ""))
	_write({
		"type": "exit_state",
		"t": GlobalData.sim_now(),
		"exit_id": exit_id,
		"name": String(status.get("name", "")),
		"available": available,
		"operational": bool(status.get("operational", available)),
		"location": point.global_position,
	})

	var affected: Array = []

	for serial: int in _agent_serials_with_exit(exit_id):
		_affected[serial] = true
		affected.append(serial)

	_write_disruption(
		"exit_enabled" if available else "exit_disabled",
		point.global_position,
		[],
		-1,
		0,
		{"exit_id": exit_id},
		affected
	)


func _agent_serials_with_exit(exit_id: String) -> Array:
	var result: Array = []
	var tree: SceneTree = get_tree()

	if tree == null:
		return result

	for npc: Node in tree.get_nodes_in_group("npc"):
		if npc == null or not is_instance_valid(npc):
			continue

		if not npc.has_method("get_measurement_state"):
			continue

		var state: Dictionary = npc.call("get_measurement_state")

		if String(state.get("exit_id", "")) == exit_id:
			result.append(int(state.get("serial", -1)))

	return result


func _exit_catalog_entry(status: Dictionary) -> Dictionary:
	return {
		"exit_id": String(status.get("exit_id", "")),
		"name": String(status.get("name", "")),
		"location": status.get("location", []),
		"operational": bool(status.get("operational", true)),
		"available": bool(status.get("available", true)),
		"service_rate": float(status.get("service_rate", 0.0)),
		"max_queue_length": int(status.get("max_queue_length", 0)),
		"receiving_capacity": int(status.get("receiving_capacity", 0)),
		"receiving_full_behavior": int(status.get("receiving_full_behavior", 0)),
		"retain": bool(status.get("retain", false)),
	}


# ---------------------------------------------------------------------------
# ENVIRONMENT / DISRUPTIONS
# ---------------------------------------------------------------------------

func _cache_grid() -> void:
	var tree: SceneTree = get_tree()

	if tree == null:
		return

	_grid = tree.get_first_node_in_group("grid_map") as NavGridMap

	if _grid == null:
		return

	if not _grid.block_placed.is_connected(_on_block_placed):
		_grid.block_placed.connect(_on_block_placed)
	if not _grid.block_removed.is_connected(_on_block_removed):
		_grid.block_removed.connect(_on_block_removed)
	if not _grid.nav_refresh_measured.is_connected(_on_nav_refresh_measured):
		_grid.nav_refresh_measured.connect(_on_nav_refresh_measured)


func _on_block_placed(cell: Vector3i, item: int) -> void:
	if not _recording or _grid == null or not is_instance_valid(_grid):
		return

	_queue_environment(
		"block_added",
		_grid.to_global(_grid.map_to_local(cell)),
		[cell],
		item,
		_grid.last_nav_refresh_usec
	)


func _on_block_removed(cell: Vector3i) -> void:
	if not _recording or _grid == null or not is_instance_valid(_grid):
		return

	_queue_environment(
		"block_removed",
		_grid.to_global(_grid.map_to_local(cell)),
		[cell],
		-1,
		_grid.last_nav_refresh_usec
	)


func _on_nav_refresh_measured(duration_usec: int, changed_cells: int) -> void:
	_last_nav_cells = changed_cells

	if _recording:
		_write({
			"type": "nav",
			"t": GlobalData.sim_now(),
			"duration_usec": duration_usec,
			"changed_cells": changed_cells,
		})


func _on_environment_changed(
	location: Vector3,
	change_type: String,
	detail: Dictionary
) -> void:
	if not _recording:
		return

	_queue_environment(
		change_type,
		location,
		detail.get("cells", []),
		int(detail.get("item", -1)),
		0,
		detail
	)


func _queue_environment(
	kind: String,
	location: Vector3,
	cells: Array,
	item: int,
	nav_usec: int,
	detail: Dictionary = {}
) -> void:
	_pending_environment.append({
		"kind": kind,
		"location": location,
		"cells": cells.duplicate(),
		"item": item,
		"nav_usec": nav_usec,
		"detail": detail.duplicate(true),
	})


func _flush_environment() -> void:
	var groups: Array = []

	for entry: Dictionary in _pending_environment:
		var merged: bool = false

		# Coalesce one drag stroke of the same block kind/item so a 500-cell
		# edit is one event instead of 500 near-identical lines.
		if entry["kind"] in ["block_added", "block_removed"]:
			for group: Dictionary in groups:
				if (
					group["kind"] == entry["kind"]
					and int(group["item"]) == int(entry["item"])
					and int(group["nav_usec"]) == int(entry["nav_usec"])
				):
					group["cells"].append_array(entry["cells"])
					merged = true
					break

		if not merged:
			var copy: Dictionary = entry.duplicate(true)
			copy["cells"] = entry["cells"].duplicate()
			groups.append(copy)

	_pending_environment.clear()
	var shared_connectivity: Dictionary = {}

	if record_nav_graph and _grid != null and is_instance_valid(_grid):
		shared_connectivity = _grid.get_connectivity_snapshot()

	for group: Dictionary in groups:
		_environment_seq += 1
		var env_id: String = "env_%04d" % _environment_seq
		var connectivity: Dictionary = shared_connectivity

		var item: int = int(group["item"])
		var item_name: String = ""

		if item >= 0 and _grid != null and is_instance_valid(_grid) and _grid.mesh_library != null:
			item_name = String(_grid.mesh_library.get_item_name(item))

		var record: Dictionary = {
			"type": "environment",
			"t": GlobalData.sim_now(),
			"id": env_id,
			"kind": String(group["kind"]),
			"location": group["location"],
			"cells": group["cells"],
			"cell_count": group["cells"].size(),
			"item": item,
			"item_name": item_name,
			"nav_usec": int(group["nav_usec"]),
			"changed_cells": _last_nav_cells,
			"connectivity": connectivity,
			"detail": group["detail"],
		}

		if GlobalData.is_spawning_enabled:
			var affected: Array = _affected_agents(group["location"])
			record["disruption_id"] = _write_disruption(
				String(group["kind"]),
				group["location"],
				group["cells"],
				item,
				int(group["nav_usec"]),
				group["detail"],
				affected,
				shared_connectivity
			)

		_write(record)


func _write_disruption(
	kind: String,
	location: Vector3,
	cells: Array,
	item: int,
	nav_usec: int,
	detail: Dictionary,
	affected: Array = [],
	connectivity: Dictionary = {}
) -> String:
	_disruption_seq += 1
	var disruption_id: String = "d_%04d" % _disruption_seq

	if connectivity.is_empty() and record_nav_graph and _grid != null and is_instance_valid(_grid):
		connectivity = _grid.get_connectivity_snapshot()

	var record: Dictionary = {
		"type": "disruption",
		"id": disruption_id,
		"t": GlobalData.sim_now(),
		"kind": kind,
		"location": location,
		"cells": cells,
		"cell_count": cells.size(),
		"item": item,
		"nav_usec": nav_usec,
		"changed_cells": _last_nav_cells,
		"connectivity": connectivity,
		"detail": detail,
		"affected": affected,
		"affected_count": affected.size(),
		"active_agents": _agents.size(),
		"rerouted": 0,
	}
	_write(record)
	_disruptions.append(record)
	_active_disruption = record

	# Per-disruption attribution sets. The global _rerouted set is kept for the
	# summary; these let a later disruption count its own affected agents.
	_pre_disruption.clear()
	_rerouted_current.clear()
	_affected.clear()

	for serial: int in affected:
		_affected[serial] = true
		_pre_disruption[serial] = _route_state_for_serial(serial)

	return disruption_id


func _affected_agents(location: Vector3) -> Array:
	var result: Array = []

	for serial: int in _spawn_serials.keys():
		var npc: Node = _agent_for_serial(serial)

		if npc == null or not is_instance_valid(npc):
			continue

		if npc.has_meta("evacuated") or _dead_serials.has(serial):
			continue

		if not npc.has_method("is_route_affected"):
			continue

		if npc.call(
			"is_route_affected",
			location,
			disruption_route_radius,
			disruption_vertical_tolerance
		):
			_affected[serial] = true
			result.append(serial)

	return result


func _route_state_for_serial(serial: int) -> Dictionary:
	var previous: Dictionary = _last_routes.get(serial, {})

	if not previous.is_empty():
		return {
			"route_id": int(previous.get("route_id", 0)),
			"exit_id": String(previous.get("exit_id", "")),
			"target": previous.get("target", Vector3.ZERO),
		}

	var npc: Node = _agent_for_serial(serial)

	if npc != null and is_instance_valid(npc) and npc.has_method("get_measurement_state"):
		var state: Dictionary = npc.call("get_measurement_state")

		return {
			"route_id": int(state.get("route_id", 0)),
			"exit_id": String(state.get("exit_id", "")),
			"target": state.get("destination", Vector3.ZERO),
		}

	return {}


func _agent_for_serial(serial: int) -> Node:
	var tree: SceneTree = get_tree()

	if tree == null:
		return null

	for npc: Node in tree.get_nodes_in_group("npc"):
		if npc != null and is_instance_valid(npc) and int(npc.get("agent_serial")) == serial:
			return npc

	return null


func _active_disruption_for(t: float) -> Dictionary:
	for index: int in range(_disruptions.size() - 1, -1, -1):
		var disruption: Dictionary = _disruptions[index]

		if t - float(disruption.get("t", 0.0)) <= disruption_window:
			return disruption

	return {}


# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

func _build_summary(reason: String) -> Dictionary:
	var now: float = GlobalData.sim_now()
	var sim: Dictionary = _last_sim_stats.duplicate(true)
	var statuses: Dictionary = _last_exit_statuses.duplicate(true)

	if statuses.is_empty():
		for entry: Dictionary in _collect_exits():
			statuses[String(entry["status"].get("exit_id", ""))] = entry["status"]

	var elapsed: float = maxf(now - _started_sim, 0.001)
	var sorted_times: Array[float] = _evac_times.duplicate()
	sorted_times.sort()
	var average_time: float = 0.0
	var median_time: float = 0.0

	if not sorted_times.is_empty():
		var total: float = 0.0

		for value: float in sorted_times:
			total += value

		average_time = total / float(sorted_times.size())
		var middle: int = int(sorted_times.size() / 2.0)
		median_time = sorted_times[middle]

		if sorted_times.size() % 2 == 0:
			median_time = (sorted_times[middle - 1] + sorted_times[middle]) * 0.5

	var exits: Array = []
	var assigned_by_exit: Dictionary = {}

	for row: Array in _last_exit_rows:
		if row.size() > 14:
			assigned_by_exit[String(row[0])] = int(row[14])

	var available_exits: int = 0

	for exit_id: String in statuses:
		var status: Dictionary = statuses[exit_id]
		var accepted: int = maxi(
			0,
			int(status.get("accepted", 0))
			- int(_exit_accepted_at_start.get(exit_id, 0))
		)
		var service_rate: float = float(status.get("service_rate", 0.0))
		var admission_rate: float = float(accepted) / elapsed
		var utilization: Variant = null

		if bool(status.get("available", true)):
			available_exits += 1

		if service_rate > 0.0:
			utilization = admission_rate / service_rate

		exits.append({
			"exit_id": exit_id,
			"name": String(status.get("name", "")),
			"operational": bool(status.get("operational", true)),
			"available": bool(status.get("available", true)),
			"accepted": accepted,
			"share": float(accepted) / float(maxi(_evacuated_serials.size(), 1)),
			"admission_rate": admission_rate,
			"service_rate": service_rate,
			"utilization": utilization,
			"average_wait": float(status.get("average_wait", 0.0)),
			"max_wait": float(status.get("max_wait", 0.0)),
			"peak_queue": int(status.get("max_queue", 0)),
			"peak_occupancy": int(status.get("peak_occupancy", 0)),
			"rejected": int(status.get("rejected", 0)),
			"capacity_waits": int(status.get("capacity_waits", 0)),
			"capacity_rejections": int(status.get("capacity_rejections", 0)),
			"queue_full_rejections": int(status.get("queue_full_rejections", 0)),
			"assigned_at_end": int(assigned_by_exit.get(exit_id, 0)),
		})

	var nav_total: int = 0
	var path_total: int = 0
	var nav_count: int = 0
	var path_count: int = 0

	if _grid != null and is_instance_valid(_grid):
		nav_total = _grid.nav_refresh_total_usec - _nav_total_at_start
		path_total = _grid.path_request_total_usec - _path_total_at_start
		nav_count = _grid.nav_refresh_count - _nav_count_at_start
		path_count = _grid.path_request_count - _path_count_at_start

	var disruption_rows: Array = []

	for disruption: Dictionary in _disruptions:
		disruption_rows.append({
			"id": String(disruption.get("id", "")),
			"t": float(disruption.get("t", 0.0)),
			"kind": String(disruption.get("kind", "")),
			"location": disruption.get("location", Vector3.ZERO),
			"cells": int(disruption.get("cell_count", 0)),
			"item": int(disruption.get("item", -1)),
			"nav_usec": int(disruption.get("nav_usec", 0)),
			"affected": disruption.get("affected", []),
			"affected_count": int(disruption.get("affected_count", 0)),
			"rerouted": int(disruption.get("rerouted", 0)),
			"route_reassignment_t": float(disruption.get("route_reassignment_t", -1.0)),
		})

	return {
		"format": FORMAT,
		"version": VERSION,
		"run_id": _run_id,
		"reason": reason,
		"started_at": _started_unix,
		"sim_start": _started_sim,
		"sim_end": now,
		"duration": elapsed,
		"rng_seed": GlobalData.rng_seed,
		"scene": _scene_path(),
		"sample_interval": sampling_interval,
		"samples": _sample_count,
		"agents_spawned": _spawn_serials.size(),
		"agents_evacuated": _evacuated_serials.size(),
		"agents_died": _dead_serials.size(),
		"agents_active": int(sim.get("active", 0)),
		"agents_required": _spawn_serials.size(),
		"all_required_evacuated": (
			_spawn_serials.size() > 0
			and _evacuated_serials.size() >= _spawn_serials.size()
		),
		"total_evacuation_time": (
			maxf(0.0, _last_evac_sim - _started_sim)
			if _last_evac_sim >= 0.0
			else 0.0
		),
		"average_evacuation_time": average_time,
		"median_evacuation_time": median_time,
		"max_evacuation_time": (
			sorted_times[sorted_times.size() - 1] if not sorted_times.is_empty() else 0.0
		),
		"total_distance": _evacuation_distance_total,
		"global_max_density": _density_peak,
		"global_average_density": (
			_density_integral / _density_time if _density_time > 0.0 else 0.0
		),
		"global_average_speed": (
			_speed_integral / _speed_time if _speed_time > 0.0 else 0.0
		),
		"peak_contact_force": _summary_peak_contact_force,
		"contact_pairs_total": _summary_contact_pairs,
		"agent_contact_samples_total": _summary_contact_samples,
		"contact_solves": _summary_contact_solves,
		"route_changes_total": _route_changes_total,
		"route_switches_total": _route_switches_total,
		"destination_changes_total": _destination_changes_total,
		"max_route_changes_per_agent": _max_route_changes,
		"max_route_switches_per_agent": _max_route_switches,
		"navigation": {
			"refresh_total_usec": nav_total,
			"refresh_count": nav_count,
			"path_total_usec": path_total,
			"path_count": path_count,
			"total_usec": nav_total + path_total,
		},
		"navigation_computation_usec": nav_total + path_total,
		"optimizer_available": bool(_optimizer_configuration.get("available", false)),
		"optimizer_execution_usec": _optimizer_last_usec,
		"hazard_level": null,
		"optimizer": {
			"available": bool(_optimizer_configuration.get("available", false)),
			"execution_usec": _optimizer_last_usec,
			"executions": _optimizer_executions,
			"algorithm": String(_optimizer_configuration.get("algorithm", "")),
			"mode": String(_optimizer_configuration.get("mode", "")),
			"configuration": _optimizer_configuration.duplicate(true),
			"note": "Predicted costs are optimizer estimates; measured outcomes are in the summary fields.",
		},
		"hazard": {
			"available": false,
			"level": null,
			"note": "No hazard/smoke model exists.",
		},
		"exits": exits,
		"active_exits": statuses.size(),
		"available_exits": available_exits,
		"disruptions": disruption_rows,
		"rerouted_agents": _rerouted.size(),
		"files": {
			"recording": _run_dir.path_join("recording.jsonl"),
			"manifest": _run_dir.path_join("manifest.json"),
			"summary": _run_dir.path_join("summary.json"),
		},
	}


# ---------------------------------------------------------------------------
# FILES
# ---------------------------------------------------------------------------

func _collect_experiment_metadata(exit_catalog: Array) -> Dictionary:
	var version: String = String(ProjectSettings.get_setting(
		"application/config/version",
		"dev"
	))
	return {
		"simulation_version": version,
		"recording_format": FORMAT,
		"recording_version": VERSION,
		"save_slug": _demo_save_slug,
		"scene": _scene_path(),
		"rng_seed": GlobalData.rng_seed,
		"initial_agent_count": _agent_count_now(),
		"planned_agent_count": GlobalData.get_total_max_spawns(),
		"configured_agent_cap": GlobalData.global_unit_cap,
		"agent_parameters": _collect_agent_parameters(),
		"crowd_parameters": _collect_crowd_parameters(),
		"navigation_parameters": _collect_navigation_parameters(),
		"optimizer": {
			"available": bool(_optimizer_configuration.get("available", false)),
			"configuration": _optimizer_configuration.duplicate(true),
			"note": "Baseline runs use local logit exit choice; optimized runs apply cohort assignments from OptimizerManager.",
		},
		"exit_configuration": exit_catalog,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"physics_timestep": 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0),
		"sampling_interval": sampling_interval,
		"scenario": _collect_scenario(),
		"environment_event_model": "runtime_events",
		"scheduled_events": _scheduled_events.duplicate(true),
	}


func _agent_count_now() -> int:
	var tree: SceneTree = get_tree()

	if tree == null:
		return 0

	return tree.get_nodes_in_group("npc").size()


func _collect_agent_parameters() -> Dictionary:
	var tree: SceneTree = get_tree()

	if tree != null:
		for npc: Node in tree.get_nodes_in_group("npc"):
			if npc != null and is_instance_valid(npc) and npc.has_method("get_behavior_parameters"):
				return npc.call("get_behavior_parameters")

	var packed: PackedScene = load("res://scenes/npcs/Member.tscn")

	if packed == null:
		return {}

	var instance: Node = packed.instantiate()

	if instance == null:
		return {}

	# The instance is not in the tree, so _ready() has not applied the Agent
	# panel's GlobalData overrides. Apply them before reading the export values,
	# otherwise a run that starts before any NPC exists records the scene
	# defaults instead of the parameters new agents will actually use.
	if not GlobalData.agent_overrides.is_empty() and instance.has_method("apply_agent_overrides"):
		instance.call("apply_agent_overrides", GlobalData.agent_overrides)

	var result: Dictionary = {}

	if instance.has_method("get_behavior_parameters"):
		result = instance.call("get_behavior_parameters")

	instance.free()
	return result


func _collect_crowd_parameters() -> Dictionary:
	var crowd := get_node_or_null("/root/CrowdManager")

	if crowd == null:
		return {}

	var keys: Array[String] = [
		"cell_size", "solve_interval", "density_radius", "density_vertical_tolerance",
		"repulsion_a", "repulsion_b", "anisotropy", "social_cutoff",
		"contact_stiffness", "contact_friction", "contact_damping_ratio",
		"max_agent_acceleration", "vertical_tolerance",
	]
	var result: Dictionary = {}

	for key: String in keys:
		result[key] = crowd.get(key)

	return result


func _collect_navigation_parameters() -> Dictionary:
	if _grid == null or not is_instance_valid(_grid):
		return {}

	if _grid.has_method("get_navigation_parameters"):
		return _grid.call("get_navigation_parameters")

	return {}


func _collect_scenario() -> Dictionary:
	var placeables: Array = []

	var tree: SceneTree = get_tree()

	if tree != null:
		for node: Node in tree.get_nodes_in_group("placeables"):
			if node == null or not is_instance_valid(node) or not node is Node3D:
				continue

			placeables.append({
				"scene": String(node.scene_file_path),
				"name": String(node.name),
				"position": (node as Node3D).global_position,
			})

	var spawner_count: int = 0
	var spawner_config: Array = []
	var used_cells: int = 0

	if tree != null:
		var spawner_nodes: Array = tree.get_nodes_in_group("spawners")
		spawner_count = spawner_nodes.size()

		for node: Node in spawner_nodes:
			if node == null or not is_instance_valid(node) or not node is Node3D:
				continue

			spawner_config.append({
				"scene": String(node.scene_file_path),
				"name": String(node.name),
				"position": (node as Node3D).global_position,
				"spawn_quota": int(node.get("spawn_quota")) if "spawn_quota" in node else 0,
				"spawn_interval": float(node.get("spawn_interval")) if "spawn_interval" in node else 0.0,
				"spawn_batch_size": int(node.get("spawn_batch_size")) if "spawn_batch_size" in node else 0,
			})

	if _grid != null and is_instance_valid(_grid):
		used_cells = _grid.get_used_cells().size()

	var quality: String = ""

	if PerformanceSettings != null:
		quality = PerformanceSettings.quality_name()

	return {
		"placeables": placeables,
		"placeable_count": placeables.size(),
		"spawners": spawner_config,
		"spawner_count": spawner_count,
		"agent_cap": GlobalData.global_unit_cap,
		"global_spawn_quota": GlobalData.global_spawn_quota,
		"evacuation_mode": GlobalData.evacuation_mode,
		"quality_preset": quality,
		"used_grid_cells": used_cells,
	}


func _write_manifest(exit_catalog: Array, metadata: Dictionary) -> void:
	var manifest: Dictionary = {
		"format": FORMAT,
		"version": VERSION,
		"run_id": _run_id,
		"demo_id": _demo_id,
		"save_slug": _demo_save_slug,
		"created_at": _started_unix,
		"scene": _scene_path(),
		"rng_seed": GlobalData.rng_seed,
		"sample_interval": sampling_interval,
		"fields": {"agent": AGENT_FIELDS, "exit": EXIT_FIELDS},
		"capabilities": _capabilities(),
		"exits_at_start": exit_catalog,
		"nav_at_start": _connectivity(),
		"metadata": metadata,
	}
	var file := FileAccess.open(_run_dir.path_join("manifest.json"), FileAccess.WRITE)

	if file == null:
		return

	file.store_string(JSON.stringify(_json_ready(manifest), "\t"))
	file.close()


func _write_summary_file(summary: Dictionary) -> void:
	var file := FileAccess.open(_run_dir.path_join("summary.json"), FileAccess.WRITE)

	if file == null:
		return

	file.store_string(JSON.stringify(_json_ready(summary), "\t"))
	file.close()


func _write(record: Dictionary) -> void:
	if _file == null:
		return

	_file.store_line(JSON.stringify(_json_ready(record)))


func _write_nav_graph() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return

	var graph: Dictionary = _grid.get_nav_graph_snapshot(nav_graph_edge_limit)
	_write({
		"type": "nav_graph",
		"t": GlobalData.sim_now(),
		"nodes": graph.get("nodes", []),
		"edges": graph.get("edges", []),
		"node_count": int(graph.get("node_count", 0)),
		"edge_count": int(graph.get("edge_count", 0)),
		"truncated": bool(graph.get("truncated", false)),
	})


## Initial obstacle layout so the comparer can diff two runs' geometry.
func _write_layout() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return

	var used: Array[Vector3i] = _grid.get_used_cells()
	var cells: Array = []
	var truncated: bool = used.size() > layout_cell_limit

	for cell: Vector3i in used:
		if cells.size() >= layout_cell_limit:
			break

		cells.append([cell.x, cell.y, cell.z, _grid.get_cell_item(cell)])

	_write({
		"type": "layout",
		"t": GlobalData.sim_now(),
		"cell_count": used.size(),
		"recorded_count": cells.size(),
		"cells": cells,
		"truncated": truncated,
	})


func _capabilities() -> Dictionary:
	return {
		"optimizer": bool(_optimizer_configuration.get("available", false)),
		"hazard_model": false,
		"replay": true, # DemoPlayer plays recordings in the map
		"comparison": true, # DemoComparer compares recordings in sync
		"jsonl_recording": true,
		"per_save_library": true,
	}


func _connectivity() -> Dictionary:
	if _grid == null or not is_instance_valid(_grid):
		return {}

	return _grid.get_connectivity_snapshot()


func _scene_path() -> String:
	var tree: SceneTree = get_tree()

	if tree == null or tree.current_scene == null:
		return ""

	return String(tree.current_scene.scene_file_path)


func _safe_stamp(value: String) -> String:
	return value.replace(":", "-").replace("T", "_").replace(" ", "_")


func _json_ready(value: Variant) -> Variant:
	if value is Vector3:
		var vector: Vector3 = value
		return [_n(vector.x), _n(vector.y), _n(vector.z)]

	if value is Vector3i:
		var cell: Vector3i = value
		return [cell.x, cell.y, cell.z]

	if value is PackedVector3Array:
		return _path_array(value)

	if value is Array:
		var array: Array = []

		for item: Variant in value:
			array.append(_json_ready(item))

		return array

	if value is Dictionary:
		var dictionary: Dictionary = {}

		for key: Variant in value:
			dictionary[String(key)] = _json_ready(value[key])

		return dictionary

	if value is float and not is_finite(value):
		return 0.0

	return value


func _path_array(path: PackedVector3Array) -> Array:
	var result: Array = []
	var step: int = 1

	if max_path_points > 1 and path.size() > max_path_points:
		step = int(ceil(float(path.size()) / float(max_path_points)))

	for index: int in range(0, path.size(), step):
		var point: Vector3 = path[index]
		result.append([_n(point.x), _n(point.y), _n(point.z)])

	return result


func _n(value: float) -> float:
	if not is_finite(value):
		return 0.0

	return snappedf(value, 0.001)
