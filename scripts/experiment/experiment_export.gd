class_name ExperimentExporter
extends RefCounted

## Flat analysis tables for recorded runs.
##
## A `recording.jsonl` is a faithful event stream, but every table and figure
## needs a bespoke parser. This class reads one or more demos and writes the
## tidy tables the research backlog requires:
##
##   runs.csv          one row per run
##   agents.csv        one row per agent (evacuated or still active at the end)
##   exits.csv         one row per run x exit
##   solves.csv        one row per optimizer solve
##   convergence.csv   one row per convergence iteration
##   data_dictionary.md
##
## The raw recording/manifest/summary are copied beside the tables so an export
## is self-contained. Tables join on `run_id` and `demo_id`.

const FORMAT_VERSION: int = 1
const DEFAULT_ROOT: String = "user://exports"

const RUN_HEADERS: Array[String] = [
	"experiment", "scenario", "condition", "condition_type", "seed",
	"repeat_index", "run_id", "demo_id", "build", "engine", "renderer",
	"physics_tick", "sampling_interval", "started_at", "sim_duration_s",
	"completed", "agents_spawned", "agents_evacuated", "agents_active",
	"incomplete_agents", "deaths", "failed_paths",
	"total_evacuation_time_s", "average_evacuation_time_s",
	"median_evacuation_time_s", "p95_evacuation_time_s", "max_evacuation_time_s",
	"peak_density", "mean_density", "peak_contact_force_n", "contact_p99_n",
	"contact_agent_seconds_above_2kn", "contact_agent_seconds_above_3kn",
	"density_agent_seconds_above_1_5", "density_agent_seconds_above_2_0",
	"density_agent_seconds_above_2_5", "peak_density_time_s",
	"route_changes", "route_switches", "solver_solves", "solver_total_usec",
	"solver_mean_usec", "solver_max_usec", "pipeline_total_usec",
	"solver_rejected", "solver_timed_out", "objective_evaluations",
	"predicted_completion_s", "prediction_error_s",
	"coverage_assigned_fraction", "coverage_assigned_agents",
	"coverage_adopted_agents", "coverage_logit_fallback",
	"coverage_commitment_skipped", "coverage_hysteresis_held",
	"first_assignment_t", "last_assignment_t",
	"objective_mode", "cohort_size_m", "max_cohorts", "time_budget_ms",
	"horizon_s", "layout_signature", "hardware_fingerprint", "source_recording",
]

const AGENT_HEADERS: Array[String] = [
	"run_id", "demo_id", "condition", "serial", "exit_id", "spawn_time_s",
	"evacuation_time_s", "time_since_run_start_s", "wait_time_s", "distance_m",
	"stuck_time_s", "stuck_strikes", "pre_movement_s", "peak_density",
	"peak_contact_force_n", "density_seconds_above_1_5",
	"density_seconds_above_2_0", "density_seconds_above_2_5",
	"route_changes", "route_switches", "optimizer_assigned", "evacuated",
]

const EXIT_HEADERS: Array[String] = [
	"run_id", "demo_id", "exit_id", "name", "accepted", "share",
	"assigned_at_end", "admission_rate", "utilization", "average_wait_s",
	"max_wait_s", "peak_queue", "receiving_occupancy", "rejected",
	"capacity_waits", "capacity_rejections", "queue_full_rejections",
	"service_rate", "available",
]

const SOLVE_HEADERS: Array[String] = [
	"run_id", "demo_id", "condition", "t", "algorithm", "mode", "cohorts",
	"assigned_agents", "applied", "unchanged", "skipped", "held",
	"environment_version", "estimated_cost", "estimated_completion_s",
	"estimated_average_s", "term_time_s", "term_congestion_s", "term_queue_s",
	"norm_time", "norm_congestion", "norm_queue", "solver_usec", "pipeline_usec",
	"objective_evaluations", "budget_ms", "seed_cost", "final_cost",
	"termination_reason", "timed_out", "exact", "flow_rounding_usec",
	"convergence_points", "solver_metadata",
]

const CONVERGENCE_HEADERS: Array[String] = [
	"run_id", "demo_id", "condition", "algorithm", "iteration", "best_cost",
	"mean_cost", "evaluations", "elapsed_usec",
]

const ROUTE_HEADERS: Array[String] = [
	"run_id", "demo_id", "condition", "agent", "t", "route_id", "reason", "mode",
	"exit_id", "success", "switched", "route_changes", "route_switches",
	"path_points", "route_length_m", "remaining_length_m", "path",
]


## Export one demo. Returns {ok, output_dir, output_display, files, counts}.
static func export_demo(
	demo_id: String,
	root_dir: String = DEFAULT_ROOT,
	save_slug: String = ""
) -> Dictionary:
	return export_demos([demo_id], "", root_dir, save_slug)


## Export a set of demos into one experiment folder. When `experiment_name` is
## empty, a single demo keeps its own folder and a multi-demo export uses a
## timestamped name.
static func export_demos(
	demo_ids: Array,
	experiment_name: String = "",
	root_dir: String = DEFAULT_ROOT,
	save_slug: String = "",
	overwrite: bool = false
) -> Dictionary:
	var store := _demo_store()

	if store == null:
		return {"ok": false, "error": "DemoStore autoload is unavailable"}

	if demo_ids.is_empty():
		return {"ok": false, "error": "no demos selected"}

	var root := root_dir if not root_dir.is_empty() else DEFAULT_ROOT
	var folder_name := experiment_name

	if folder_name.is_empty():
		folder_name = (
			String(demo_ids[0])
			if demo_ids.size() == 1
			else "experiment_%s" % Time.get_datetime_string_from_system().replace(":", "-")
		)

	var output_dir := (
		root.path_join(_slugify(folder_name))
		if overwrite
		else _unique_dir(root.path_join(_slugify(folder_name)))
	)
	DirAccess.make_dir_recursive_absolute(output_dir)

	var runs: Array[Dictionary] = []
	var agents: Array[Dictionary] = []
	var exits: Array[Dictionary] = []
	var solves: Array[Dictionary] = []
	var convergence: Array[Dictionary] = []
	var route_rows: Array[Dictionary] = []
	var loaded: Array[Dictionary] = []
	var errors: Array[String] = []

	for demo_id_value: Variant in demo_ids:
		var demo_id := String(demo_id_value)
		var run := _load_run(store, demo_id, save_slug)

		if run.is_empty():
			errors.append("%s: recording not found" % demo_id)
			continue

		loaded.append(run)
		runs.append(_run_row(run, experiment_name))
		agents.append_array(_agent_rows(run))
		exits.append_array(_exit_rows(run))
		solves.append_array(_solve_rows(run))
		convergence.append_array(_convergence_rows(run))
		route_rows.append_array(_route_rows(run))

		var raw_dir := output_dir.path_join("raw").path_join(_slugify(demo_id))
		DirAccess.make_dir_recursive_absolute(raw_dir)
		_copy_if_present(String(run["recording_path"]), raw_dir.path_join("recording.jsonl"))
		_copy_if_present(String(run["manifest_path"]), raw_dir.path_join("manifest.json"))
		_copy_if_present(String(run["summary_path"]), raw_dir.path_join("summary.json"))

		var plan := EvacuationPlan.from_recording(String(run["recording_path"]), demo_id)

		if plan != null and plan.assignment_count() > 0:
			var plans_dir := output_dir.path_join("plans")
			DirAccess.make_dir_recursive_absolute(plans_dir)
			plan.save_to(plans_dir.path_join("%s.json" % _slugify(demo_id)))

	_write_csv(output_dir.path_join("runs.csv"), RUN_HEADERS, runs)
	_write_csv(output_dir.path_join("agents.csv"), AGENT_HEADERS, agents)
	_write_csv(output_dir.path_join("exits.csv"), EXIT_HEADERS, exits)
	_write_csv(output_dir.path_join("solves.csv"), SOLVE_HEADERS, solves)
	_write_csv(output_dir.path_join("convergence.csv"), CONVERGENCE_HEADERS, convergence)
	_write_csv(output_dir.path_join("routes.csv"), ROUTE_HEADERS, route_rows)
	_write_dictionary(output_dir.path_join("data_dictionary.md"))
	_write_index(output_dir.path_join("export.json"), loaded, runs.size())

	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"output_dir": output_dir,
		"output_display": ProjectSettings.globalize_path(output_dir),
		"runs": runs.size(),
		"agents": agents.size(),
		"exits": exits.size(),
		"solves": solves.size(),
		"convergence": convergence.size(),
		"routes": route_rows.size(),
		"files": [
			"runs.csv", "agents.csv", "exits.csv", "solves.csv",
			"convergence.csv", "routes.csv", "data_dictionary.md",
			"export.json", "raw/", "plans/",
		],
	}


## Export every completed demo in the active save's library.
static func export_all_active_save(root_dir: String = DEFAULT_ROOT) -> Dictionary:
	var store := _demo_store()

	if store == null:
		return {"ok": false, "error": "DemoStore autoload is unavailable"}

	var ids: Array = []

	for demo: Dictionary in store.call("list_demos"):
		ids.append(String(demo.get("id", "")))

	return export_demos(ids, "all_runs", root_dir)


static func output_root() -> String:
	return DEFAULT_ROOT


# ---------------------------------------------------------------------------
# Loading and parsing
# ---------------------------------------------------------------------------

static func _demo_store() -> Node:
	var tree := Engine.get_main_loop() as SceneTree

	if tree == null:
		return null

	return tree.root.get_node_or_null("DemoStore")


static func _load_run(store: Node, demo_id: String, save_slug: String) -> Dictionary:
	var recording_path := String(store.call("recording_path", demo_id, save_slug))

	if not FileAccess.file_exists(recording_path):
		return {}

	var manifest_path := String(store.call("manifest_path", demo_id, save_slug))
	var summary_path := String(store.call("summary_path", demo_id, save_slug))
	var file := FileAccess.open(recording_path, FileAccess.READ)

	if file == null:
		return {}

	var run: Dictionary = {
		"demo_id": demo_id,
		"save_slug": save_slug,
		"recording_path": recording_path,
		"manifest_path": manifest_path,
		"summary_path": summary_path,
		"manifest": _read_json(manifest_path),
		"summary": _read_json(summary_path),
		"run": {},
		"end": {},
		"optimizer_events": [],
		"routes": {},
		"route_events": [],
		"destinations": {},
		"evacuations": [],
		"spawns": {},
		"last_tick": {},
		"queue_events": [],
		"contacts": [],
		"route_failures": 0,
	}

	while not file.eof_reached():
		var line := file.get_line()

		if line.strip_edges().is_empty():
			continue

		var parsed: Variant = JSON.parse_string(line)

		if not parsed is Dictionary:
			continue

		var record: Dictionary = parsed
		var type := String(record.get("type", ""))

		match type:
			"run":
				run["run"] = record
			"end":
				run["end"] = record

				if (run["summary"] as Dictionary).is_empty():
					run["summary"] = record.get("summary", {})
			"optimizer":
				(run["optimizer_events"] as Array).append(record)
			"route", "route_change":
				(run["routes"] as Dictionary)[int(record.get("agent", -1))] = record
				(run["route_events"] as Array).append(record)

				if not bool(record.get("success", true)) or String(record.get("reason", "")) == "failed":
					run["route_failures"] = int(run["route_failures"]) + 1
			"destination":
				(run["destinations"] as Dictionary)[int(record.get("agent", -1))] = record
			"evacuation":
				(run["evacuations"] as Array).append(record)
			"agent_spawn":
				(run["spawns"] as Dictionary)[int(record.get("agent", -1))] = record
			"tick":
				run["last_tick"] = record
			"queue":
				(run["queue_events"] as Array).append(record)
			"contact":
				(run["contacts"] as Array).append(record)

	file.close()

	if (run["run"] as Dictionary).is_empty():
		return {}

	var summary: Dictionary = run["summary"]

	if summary.is_empty():
		summary = _summary_from_run(run)
	else:
		var end_summary: Dictionary = (run["end"] as Dictionary).get("summary", {})

		for key: Variant in end_summary.keys():
			if not summary.has(key):
				summary[key] = end_summary[key]

	run["summary"] = summary

	return run


static func _summary_from_run(run: Dictionary) -> Dictionary:
	var source: Dictionary = run.get("end", {}).get("summary", {})
	return source


static func _read_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


# ---------------------------------------------------------------------------
# rows: runs
# ---------------------------------------------------------------------------

static func _run_row(run: Dictionary, experiment_name: String) -> Dictionary:
	var manifest: Dictionary = run.get("manifest", {})
	var summary: Dictionary = run.get("summary", {})
	var header: Dictionary = run.get("run", {})
	var metadata: Dictionary = manifest.get("metadata", {})
	var hardware: Dictionary = metadata.get("hardware_fingerprint", {})
	var optimizer_config: Dictionary = metadata.get("optimizer", {})
	var configuration: Dictionary = optimizer_config.get("configuration", {})
	var algorithm := String(configuration.get("algorithm", ""))
	var releases: Array = run.get("optimizer_events", [])
	var last_solver: Dictionary = releases[releases.size() - 1] if not releases.is_empty() else {}
	var last_detail: Dictionary = last_solver.get("detail", {})
	var coverage: Dictionary = summary.get("coverage", {})
	var spawned := int(summary.get("agents_spawned", 0))
	var evacuated := int(summary.get("agents_evacuated", 0))
	var died := int(summary.get("agents_died", 0))
	var predicted := float(last_detail.get("estimated_completion_time", 0.0))
	var measured := float(summary.get("total_evacuation_time", 0.0))
	var experiment := String(metadata.get("experiment", experiment_name))
	var scenario := String(
		metadata.get("experiment_scenario",
		metadata.get("scenario_label", manifest.get("save_slug", "")))
	)

	if experiment.is_empty():
		experiment = "ad_hoc"

	return {
		"experiment": experiment,
		"scenario": scenario,
		"condition": algorithm if not algorithm.is_empty() else "baseline",
		"condition_type": _condition_type(algorithm),
		"seed": int(summary.get("rng_seed", header.get("rng_seed", 0))),
		"repeat_index": int(metadata.get("repeat_index", 0)),
		"run_id": String(summary.get("run_id", header.get("run_id", run.get("demo_id", "")))),
		"demo_id": String(run.get("demo_id", "")),
		"build": String(metadata.get("simulation_version", hardware.get("project_version", ""))),
		"engine": String(hardware.get("engine_version", "")),
		"renderer": String(hardware.get("renderer", "")),
		"physics_tick": float(metadata.get("physics_ticks_per_second", 0.0)),
		"sampling_interval": float(metadata.get("sampling_interval", header.get("sample_interval", 0.0))),
		"started_at": String(summary.get("started_at", header.get("started_at", ""))),
		"sim_duration_s": float(summary.get("duration", 0.0)),
		"completed": bool(summary.get("all_required_evacuated", false)),
		"agents_spawned": spawned,
		"agents_evacuated": evacuated,
		"agents_active": int(summary.get("agents_active", 0)),
		"incomplete_agents": maxi(0, spawned - evacuated - died),
		"deaths": died,
		"failed_paths": int(run.get("route_failures", 0)),
		"total_evacuation_time_s": measured,
		"average_evacuation_time_s": float(summary.get("average_evacuation_time", 0.0)),
		"median_evacuation_time_s": float(summary.get("median_evacuation_time", 0.0)),
		"p95_evacuation_time_s": float(summary.get("p95_evacuation_time", 0.0)),
		"max_evacuation_time_s": float(summary.get("max_evacuation_time", 0.0)),
		"peak_density": float(summary.get("global_max_density", 0.0)),
		"mean_density": float(summary.get("global_average_density", 0.0)),
		"peak_contact_force_n": float(summary.get("peak_contact_force", 0.0)),
		"contact_p99_n": float(summary.get("contact_force_p99", 0.0)),
		"contact_agent_seconds_above_2kn": float(summary.get("contact_agent_seconds_above_2kn", 0.0)),
		"contact_agent_seconds_above_3kn": float(summary.get("contact_agent_seconds_above_3kn", 0.0)),
		"density_agent_seconds_above_1_5": float(summary.get("density_agent_seconds_above_1_5", 0.0)),
		"density_agent_seconds_above_2_0": float(summary.get("density_agent_seconds_above_2_0", 0.0)),
		"density_agent_seconds_above_2_5": float(summary.get("density_agent_seconds_above_2_5", 0.0)),
		"peak_density_time_s": float(summary.get("peak_density_time", 0.0)),
		"route_changes": int(summary.get("route_changes_total", 0)),
		"route_switches": int(summary.get("route_switches_total", 0)),
		"solver_solves": int(summary.get("optimizer", {}).get("solve_count", releases.size())),
		"solver_total_usec": int(summary.get("optimizer", {}).get("total_solver_usec", 0)),
		"solver_mean_usec": float(summary.get("optimizer", {}).get("mean_solver_usec", 0.0)),
		"solver_max_usec": int(summary.get("optimizer", {}).get("max_solver_usec", 0)),
		"pipeline_total_usec": int(summary.get("optimizer", {}).get("total_pipeline_usec", 0)),
		"solver_rejected": int(summary.get("optimizer", {}).get("rejected", 0)),
		"solver_timed_out": int(summary.get("optimizer", {}).get("timed_out", 0)),
		"objective_evaluations": int(summary.get("optimizer", {}).get("evaluations", 0)),
		"predicted_completion_s": predicted,
		"prediction_error_s": predicted - measured if predicted > 0.0 and measured > 0.0 else null,
		"coverage_assigned_fraction": float(coverage.get("assigned_fraction", 0.0)),
		"coverage_assigned_agents": int(coverage.get("assigned_agents", 0)),
		"coverage_adopted_agents": int(coverage.get("adopted_agents", 0)),
		"coverage_logit_fallback": int(coverage.get("logit_fallback", 0)),
		"coverage_commitment_skipped": int(coverage.get("commitment_skipped", 0)),
		"coverage_hysteresis_held": int(coverage.get("hysteresis_held", 0)),
		"first_assignment_t": float(coverage.get("first_assignment_t", -1.0)),
		"last_assignment_t": float(coverage.get("last_assignment_t", -1.0)),
		"objective_mode": String(configuration.get("mode", last_detail.get("mode", ""))),
		"cohort_size_m": float(configuration.get("cohort_size", 0.0)),
		"max_cohorts": int(configuration.get("max_cohorts", 0)),
		"time_budget_ms": float(
			last_detail.get("solver", {}).get(
				"budget_ms",
				configuration.get("parameters", {}).get("time_budget_ms", 0.0)
			)
		),
		"horizon_s": float(metadata.get("experiment_horizon_s", 0.0)),
		"layout_signature": String(metadata.get("layout_signature", "")),
		"hardware_fingerprint": String(hardware.get("fingerprint", "")),
		"source_recording": String(run.get("recording_path", "")),
	}


static func _condition_type(algorithm: String) -> String:
	match algorithm:
		"", "baseline", "logit", "off":
			return "behavioural_control"
		"nearest", "equal_split", "greedy", "greedy_congestion":
			return "deterministic_assignment"
		"exhaustive", "local_search", "aco", "pso":
			return "budgeted_search"
		"network_flow", "time_expanded":
			return "flow"
		_:
			return "other"


# ---------------------------------------------------------------------------
# rows: agents / exits / solves / convergence
# ---------------------------------------------------------------------------

static func _agent_rows(run: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var summary: Dictionary = run.get("summary", {})
	var condition := String(
		summary.get("optimizer", {}).get(
			"algorithm",
			run.get("manifest", {}).get("metadata", {}).get("optimizer", {}).get("configuration", {}).get("algorithm", "baseline")
		)
	)
	var spawns: Dictionary = run.get("spawns", {})
	var last_tick: Dictionary = run.get("last_tick", {})
	var final_rows: Dictionary = {}

	for row_value: Variant in last_tick.get("agents", []):
		if row_value is Array and (row_value as Array).size() > 5:
			final_rows[int(row_value[0])] = row_value

	var evacuated: Dictionary = {}

	for evac_value: Variant in run.get("evacuations", []):
		if not evac_value is Dictionary:
			continue

		var evac: Dictionary = evac_value
		var serial := int(evac.get("agent", -1))
		evacuated[serial] = true
		var spawn: Dictionary = spawns.get(serial, {})
		var final_row: Array = final_rows.get(serial, [])
		rows.append({
			"run_id": String(summary.get("run_id", "")),
			"demo_id": String(run.get("demo_id", "")),
			"condition": condition,
			"serial": serial,
			"exit_id": String(evac.get("exit_id", "")),
			"spawn_time_s": float(spawn.get("t", 0.0)),
			"evacuation_time_s": float(evac.get("evacuation_time", 0.0)),
			"time_since_run_start_s": float(evac.get("time_since_run_start", 0.0)),
			"wait_time_s": float(evac.get("wait_time", 0.0)),
			"distance_m": float(evac.get("distance", 0.0)),
			"stuck_time_s": float(evac.get("stuck_time", 0.0)),
			"stuck_strikes": int(evac.get("stuck_strikes", 0)),
			"pre_movement_s": float(evac.get("pre_movement_wait", spawn.get("pre_movement_delay", 0.0))),
			"peak_density": float(evac.get("peak_density", 0.0)),
			"peak_contact_force_n": float(evac.get("peak_contact_force", 0.0)),
			"density_seconds_above_1_5": float(evac.get("density_seconds_above_1_5", 0.0)),
			"density_seconds_above_2_0": float(evac.get("density_seconds_above_2_0", 0.0)),
			"density_seconds_above_2_5": float(evac.get("density_seconds_above_2_5", 0.0)),
			"route_changes": int(evac.get("route_changes", _row_int(final_row, 25, 0))),
			"route_switches": int(evac.get("route_switches", _row_int(final_row, 26, 0))),
			"optimizer_assigned": bool(_row_int(final_row, 40, 0)) or bool(evac.get("optimizer_assigned", false)),
			"evacuated": true,
		})

	# Agents still alive/queued when the run was stopped still matter for a
	# per-agent analysis (censoring), so include the final sampled row.
	for serial: int in final_rows.keys():
		if evacuated.has(serial):
			continue

		var row: Array = final_rows[serial]
		var spawn: Dictionary = spawns.get(serial, {})
		rows.append({
			"run_id": String(summary.get("run_id", "")),
			"demo_id": String(run.get("demo_id", "")),
			"condition": condition,
			"serial": serial,
			"exit_id": _row_string(row, 16, ""),
			"spawn_time_s": float(spawn.get("t", _row_float(row, 39, 0.0))),
			"evacuation_time_s": "",
			"time_since_run_start_s": "",
			"wait_time_s": "",
			"distance_m": _row_float(row, 22, 0.0),
			"stuck_time_s": _row_float(row, 32, 0.0),
			"stuck_strikes": _row_int(row, 27, 0),
			"pre_movement_s": _row_float(row, 30, spawn.get("pre_movement_delay", 0.0)),
			"peak_density": _row_float(row, 37, 0.0),
			"peak_contact_force_n": _row_float(row, 38, 0.0),
			"density_seconds_above_1_5": "",
			"density_seconds_above_2_0": "",
			"density_seconds_above_2_5": "",
			"route_changes": _row_int(row, 25, 0),
			"route_switches": _row_int(row, 26, 0),
			"optimizer_assigned": bool(_row_int(row, 40, 0)),
			"evacuated": false,
		})

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("serial", 0)) < int(b.get("serial", 0))
	)
	return rows


static func _exit_rows(run: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var summary: Dictionary = run.get("summary", {})
	var final_tick: Dictionary = run.get("last_tick", {})
	var tick_exits: Dictionary = {}

	for row_value: Variant in final_tick.get("exits", []):
		if row_value is Array and (row_value as Array).size() > 5:
			tick_exits[String(row_value[0])] = row_value

	for exit_value: Variant in summary.get("exits", []):
		if not exit_value is Dictionary:
			continue

		var exit_data: Dictionary = exit_value
		var exit_id := String(exit_data.get("exit_id", ""))
		var tick_row: Array = tick_exits.get(exit_id, [])
		rows.append({
			"run_id": String(summary.get("run_id", "")),
			"demo_id": String(run.get("demo_id", "")),
			"exit_id": exit_id,
			"name": String(exit_data.get("name", "")),
			"accepted": int(exit_data.get("accepted", 0)),
			"share": float(exit_data.get("share", 0.0)),
			"assigned_at_end": int(exit_data.get("assigned_at_end", _row_int(tick_row, 14, 0))),
			"admission_rate": float(exit_data.get("admission_rate", _row_float(tick_row, 12, 0.0))),
			"utilization": exit_data.get("utilization", ""),
			"average_wait_s": float(exit_data.get("average_wait", _row_float(tick_row, 9, 0.0))),
			"max_wait_s": float(exit_data.get("max_wait", _row_float(tick_row, 10, 0.0))),
			"peak_queue": int(exit_data.get("peak_queue", _row_int(tick_row, 6, 0))),
			"receiving_occupancy": int(exit_data.get("receiving_occupancy", _row_int(tick_row, 7, 0))),
			"rejected": int(exit_data.get("rejected", _row_int(tick_row, 16, 0))),
			"capacity_waits": int(exit_data.get("capacity_waits", _row_int(tick_row, 17, 0))),
			"capacity_rejections": int(exit_data.get("capacity_rejections", _row_int(tick_row, 18, 0))),
			"queue_full_rejections": int(exit_data.get("queue_full_rejections", _row_int(tick_row, 19, 0))),
			"service_rate": float(exit_data.get("service_rate", _row_float(tick_row, 11, 0.0))),
			"available": bool(exit_data.get("available", true)),
		})

	return rows


static func _solve_rows(run: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var summary: Dictionary = run.get("summary", {})

	for event_value: Variant in run.get("optimizer_events", []):
		if not event_value is Dictionary:
			continue

		var event: Dictionary = event_value
		var detail: Dictionary = event.get("detail", {})
		var solver: Dictionary = detail.get("solver", {})
		var terms: Dictionary = detail.get("terms", {})
		var normalised: Dictionary = detail.get("normalised_terms", {})
		var apply: Dictionary = detail.get("apply", {})
		var terminated := _termination_reason(detail, solver)
		var seed_cost: Variant = solver.get(
			"seed_cost",
			solver.get(
				"local_seed_cost",
				solver.get("initial_seed_cost", solver.get("pso_seed_cost", ""))
			)
		)
		var budget: Variant = solver.get(
			"budget_ms",
			detail.get(
				"budget_ms",
				(solver.get("configuration", {}) as Dictionary).get("parameters", {}).get("time_budget_ms", "")
			)
		)

		if budget == "":
			var optimizer_config: Dictionary = summary.get("optimizer", {}).get("configuration", {})
			budget = (optimizer_config.get("parameters", {}) as Dictionary).get("time_budget_ms", "")
		rows.append({
			"run_id": String(summary.get("run_id", "")),
			"demo_id": String(run.get("demo_id", "")),
			"condition": String(detail.get("algorithm", event.get("name", ""))),
			"t": float(event.get("t", 0.0)),
			"algorithm": String(detail.get("algorithm", event.get("name", ""))),
			"mode": String(detail.get("mode", "")),
			"cohorts": int(detail.get("cohort_count", 0)),
			"assigned_agents": int(detail.get("agent_count", 0)),
			"applied": int(detail.get("applied", 0)),
			"unchanged": int(apply.get("unchanged", 0)),
			"skipped": int(detail.get("skipped", 0)),
			"held": int(apply.get("held", 0)),
			"environment_version": int(detail.get("environment_version", -1)),
			"estimated_cost": float(detail.get("estimated_cost", 0.0)),
			"estimated_completion_s": float(detail.get("estimated_completion_time", 0.0)),
			"estimated_average_s": float(detail.get("estimated_average_time", 0.0)),
			"term_time_s": float(terms.get("time", 0.0)),
			"term_congestion_s": float(terms.get("congestion", 0.0)),
			"term_queue_s": float(terms.get("queue", 0.0)),
			"norm_time": float(normalised.get("time", 0.0)),
			"norm_congestion": float(normalised.get("congestion", 0.0)),
			"norm_queue": float(normalised.get("queue", 0.0)),
			"solver_usec": int(round(float(detail.get("computation_time_ms", 0.0)) * 1000.0)),
			"pipeline_usec": int(detail.get("total_usec", event.get("duration_usec", 0))),
			"objective_evaluations": int(detail.get("evaluations", solver.get("evaluations", 0))),
			"budget_ms": budget,
			"seed_cost": seed_cost,
			"final_cost": float(detail.get("estimated_cost", 0.0)),
			"termination_reason": terminated,
			"timed_out": bool(solver.get("timed_out", false)),
			"exact": bool(solver.get("exact", false)),
			"flow_rounding_usec": int(solver.get("flow_rounding_usec", 0)),
			"convergence_points": (detail.get("convergence", []) as Array).size(),
			"solver_metadata": JSON.stringify(solver),
		})

	return rows


static func _convergence_rows(run: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var summary: Dictionary = run.get("summary", {})

	for event_value: Variant in run.get("optimizer_events", []):
		if not event_value is Dictionary:
			continue

		var event: Dictionary = event_value
		var detail: Dictionary = event.get("detail", {})
		var algorithm := String(detail.get("algorithm", event.get("name", "")))
		var index := 0

		for point_value: Variant in detail.get("convergence", []):
			if not point_value is Dictionary:
				index += 1
				continue

			var point: Dictionary = point_value
			rows.append({
				"run_id": String(summary.get("run_id", "")),
				"demo_id": String(run.get("demo_id", "")),
				"condition": algorithm,
				"algorithm": algorithm,
				"iteration": int(point.get("iteration", index)),
				"best_cost": float(point.get("best_cost", 0.0)),
				"mean_cost": point.get("mean_cost", ""),
				"evaluations": point.get("evaluations", ""),
				"elapsed_usec": point.get("elapsed_usec", point.get("elapsed_ms", "")),
			})
			index += 1

	return rows


static func _route_rows(run: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var summary: Dictionary = run.get("summary", {})
	var condition := String(
		summary.get("optimizer", {}).get("algorithm", "baseline")
	)

	for event_value: Variant in run.get("route_events", []):
		if not event_value is Dictionary:
			continue

		var event: Dictionary = event_value
		var path: Array = event.get("path", [])
		rows.append({
			"run_id": String(summary.get("run_id", "")),
			"demo_id": String(run.get("demo_id", "")),
			"condition": condition,
			"agent": int(event.get("agent", -1)),
			"t": float(event.get("t", 0.0)),
			"route_id": int(event.get("route_id", 0)),
			"reason": String(event.get("reason", "")),
			"mode": String(event.get("mode", "")),
			"exit_id": String(event.get("exit_id", "")),
			"success": bool(event.get("success", true)),
			"switched": bool(event.get("switched", false)),
			"route_changes": int(event.get("route_changes", 0)),
			"route_switches": int(event.get("route_switches", 0)),
			"path_points": int(event.get("path_points", path.size())),
			"route_length_m": float(event.get("route_length", 0.0)),
			"remaining_length_m": float(event.get("remaining_length", 0.0)),
			"path": _pack_path(path),
		})

	return rows


static func _pack_path(path: Array) -> String:
	var parts: Array[String] = []

	for point: Variant in path:
		if point is Array and (point as Array).size() >= 3:
			parts.append("%.3f,%.3f,%.3f" % [
				float(point[0]), float(point[1]), float(point[2])
			])
		elif point is Vector3:
			parts.append("%.3f,%.3f,%.3f" % [point.x, point.y, point.z])

	return ";".join(parts)


static func _termination_reason(detail: Dictionary, solver: Dictionary) -> String:
	if not String(detail.get("rejected_reason", "")).is_empty():
		return "refused"

	if bool(solver.get("timed_out", false)):
		return "budget"

	if bool(solver.get("exact", false)):
		return "exact"

	if solver.has("termination"):
		return String(solver.get("termination", ""))

	if solver.has("passes_completed"):
		return "iteration_limit"

	return "iteration_limit"


# ---------------------------------------------------------------------------
# CSV / dictionary output
# ---------------------------------------------------------------------------

static func _write_csv(path: String, headers: Array[String], rows: Array[Dictionary]) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return false

	var header_cells: Array[String] = []

	for header: String in headers:
		header_cells.append(_csv_cell(header))

	file.store_line(",".join(header_cells))

	for row: Dictionary in rows:
		var cells: Array[String] = []

		for header: String in headers:
			cells.append(_csv_cell(row.get(header, "")))

		file.store_line(",".join(cells))

	file.close()
	return true


static func _csv_cell(value: Variant) -> String:
	var text := ""

	if value == null:
		text = ""
	elif value is bool:
		text = "true" if value else "false"
	elif value is float:
		text = str(value)
	elif value is int:
		text = str(value)
	elif value is Array or value is Dictionary:
		text = JSON.stringify(_json_ready(value))
	elif value is Vector3:
		var point: Vector3 = value
		text = "%.6g;%.6g;%.6g" % [point.x, point.y, point.z]
	else:
		text = str(value)

	if text.contains(",") or text.contains("\"") or text.contains("\n") or text.contains("\r"):
		return "\"%s\"" % text.replace("\"", "\"\"")

	return text


static func _write_dictionary(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return

	file.store_string(
		"# Export data dictionary\n\n"
		+ "Generated by `ExperimentExporter` from recorded demos. Tables join on "
		+ "`run_id`; `demo_id` identifies the source demo folder.\n\n"
		+ "## runs.csv (one row per run)\n\n"
		+ "| Column | Unit | Source |\n|---|---|---|\n"
		+ "| experiment | - | manifest.metadata.experiment or the export name |\n"
		+ "| scenario | - | manifest.metadata.experiment_scenario / save |\n"
		+ "| condition | - | optimizer.algorithm (`baseline` when off) |\n"
		+ "| condition_type | - | behavioural_control / deterministic_assignment / budgeted_search / flow |\n"
		+ "| seed | - | summary.rng_seed |\n"
		+ "| repeat_index | - | manifest.metadata.repeat_index (0 when absent) |\n"
		+ "| run_id / demo_id | - | run header / demo folder |\n"
		+ "| build / engine / renderer | - | manifest hardware fingerprint |\n"
		+ "| physics_tick | Hz | manifest.metadata.physics_ticks_per_second |\n"
		+ "| sampling_interval | s | manifest.metadata.sampling_interval |\n"
		+ "| started_at | ISO 8601 | run.started_at |\n"
		+ "| sim_duration_s | s | summary.duration (simulation clock, pauses excluded) |\n"
		+ "| completed | bool | summary.all_required_evacuated |\n"
		+ "| agents_spawned / agents_evacuated / agents_active | agents | summary |\n"
		+ "| incomplete_agents | agents | spawned - evacuated - deaths |\n"
		+ "| deaths | agents | summary.agents_died |\n"
		+ "| failed_paths | count | route events with success=false or reason=failed |\n"
		+ "| total_evacuation_time_s | s | last admission - run start |\n"
		+ "| average/median/p95/max_evacuation_time_s | s | per-agent evacuation times |\n"
		+ "| peak_density | agents/m^2 | summary.global_max_density |\n"
		+ "| mean_density | agents/m^2 | time-weighted mean of per-sample mean density |\n"
		+ "| peak_contact_force_n | N | summary.peak_contact_force |\n"
		+ "| contact_p99_n | N | loaded per-agent contact-force samples |\n"
		+ "| contact_agent_seconds_above_2kn / 3kn | agent-s | contact exposure above threshold |\n"
		+ "| density_agent_seconds_above_1_5 / 2_0 / 2_5 | agent-s | density exposure |\n"
		+ "| peak_density_time_s | s | simulation time of the peak sample |\n"
		+ "| route_changes / route_switches | count | route events |\n"
		+ "| solver_solves | count | optimizer events |\n"
		+ "| solver_total_usec / mean / max | us | sum of result.computation_time_ms |\n"
		+ "| pipeline_total_usec | us | sum of optimizer event total_usec (capture + solve + apply) |\n"
		+ "| solver_rejected / timed_out | count | optimizer events |\n"
		+ "| objective_evaluations | count | optimizer result.evaluations |\n"
		+ "| predicted_completion_s | s | last optimizer estimate (never a measurement) |\n"
		+ "| prediction_error_s | s | predicted - measured total time |\n"
		+ "| coverage_* | agents / fraction / s | summary.coverage |\n"
		+ "| objective_mode / cohort_size_m / max_cohorts / time_budget_ms | - | optimizer configuration |\n"
		+ "| horizon_s | s | manifest.metadata.experiment_horizon_s |\n"
		+ "| layout_signature | hash | eviction plan / manifest map signature |\n"
		+ "| hardware_fingerprint | text | OS + CPU + GPU + engine build |\n"
		+ "| source_recording | path | demo recording file |\n\n"
		+ "## agents.csv (one row per agent)\n\n"
		+ "`run_id, demo_id, condition, serial, exit_id, spawn_time_s, "
		+ "evacuation_time_s, time_since_run_start_s, wait_time_s, distance_m, "
		+ "stuck_time_s, stuck_strikes, pre_movement_s, peak_density, "
		+ "peak_contact_force_n, density_seconds_above_1_5/2_0/2_5, "
		+ "route_changes, route_switches, optimizer_assigned, evacuated`.\n\n"
		+ "Evacuated agents come from `evacuation` events. Agents still active at "
		+ "the end are included from the final `tick` with `evacuated=false` "
		+ "(right-censored).\n\n"
		+ "## exits.csv (one row per run x exit)\n\n"
		+ "Accepted, share, assigned_at_end, admission_rate, utilization, "
		+ "average/max wait, peak queue, receiving occupancy, rejections, "
		+ "capacity/queue-full rejections, configured service rate, availability. "
		+ "`utilization` is blank when the service rate is 0 (unlimited).\n\n"
		+ "## solves.csv (one row per optimizer solve)\n\n"
		+ "Solver time is `computation_time_ms`; pipeline time is the optimizer "
		+ "event's `total_usec` (capture + solve + apply). `termination_reason` is "
		+ "budget / exact / refused / iteration_limit. `seed_cost` / `final_cost` "
		+ "separate the hybrid seed from the search result. `solver_metadata` is "
		+ "the method-specific JSON block.\n\n"
		+ "## convergence.csv (one row per convergence point)\n\n"
		+ "`best_cost` is best-so-far; `mean_cost`, `evaluations` and `elapsed_usec` "
		+ "are present when the algorithm reports them. This supports the "
		+ "best-so-far-over-time figure.\n\n"
		+ "## routes.csv (one row per route assignment)\n\n"
		+ "`agent, t, route_id, reason (destination/optimizer/plan/navigation/"
		+ "corner/detour/failed), mode (path/flow/failed), exit_id, success, "
		+ "switched, route_changes, route_switches, path_points, "
		+ "route_length_m, remaining_length_m, path`. `path` is "
		+ "`x,y,z;x,y,z;...` in world metres; it is empty for flow-field routes. "
		+ "Use this table for route figures and corridor checks.\n"
	)
	file.close()


static func _write_index(path: String, runs: Array, count: int) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return

	var ids: Array = []

	for run: Dictionary in runs:
		ids.append({
			"demo_id": String(run.get("demo_id", "")),
			"recording": String(run.get("recording_path", "")),
			"run_id": String(run.get("summary", {}).get("run_id", "")),
		})

	file.store_string(JSON.stringify({
		"format": "ero-experiment-export",
		"version": FORMAT_VERSION,
		"exported_at": Time.get_datetime_string_from_system(true, true),
		"runs": count,
		"tables": ["runs.csv", "agents.csv", "exits.csv", "solves.csv", "convergence.csv", "routes.csv"],
		"sources": ids,
	}, "\t", false))
	file.close()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _copy_if_present(source: String, target: String) -> void:
	if not source.is_empty() and FileAccess.file_exists(source):
		DirAccess.copy_absolute(source, target)


static func _unique_dir(path: String) -> String:
	if not DirAccess.dir_exists_absolute(path):
		return path

	var index := 2

	while DirAccess.dir_exists_absolute("%s_%d" % [path, index]):
		index += 1

	return "%s_%d" % [path, index]


static func _slugify(value: String) -> String:
	var cleaned := value.strip_edges().to_lower()
	var result := ""

	for character: String in cleaned:
		if character in "abcdefghijklmnopqrstuvwxyz0123456789_-":
			result += character
		elif character == " " or character == ".":
			result += "_"

	return result if not result.is_empty() else "export"


static func _row_int(row: Array, index: int, fallback: int) -> int:
	if index < row.size():
		return int(row[index])

	return fallback


static func _row_float(row: Array, index: int, fallback: float) -> float:
	if index < row.size():
		return float(row[index])

	return fallback


static func _row_string(row: Array, index: int, fallback: String) -> String:
	if index < row.size():
		return String(row[index])

	return fallback


static func _json_ready(value: Variant) -> Variant:
	if value == null or value is String or value is bool or value is int or value is float:
		return value

	if value is Vector3:
		var point: Vector3 = value
		return [point.x, point.y, point.z]

	if value is Vector3i:
		var cell: Vector3i = value
		return [cell.x, cell.y, cell.z]

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

	return str(value)
