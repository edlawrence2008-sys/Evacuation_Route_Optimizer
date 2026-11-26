class_name EvacuationPlan
extends RefCounted

## A saved, reusable evacuation plan.
##
## The optimizer decides cohort -> exit assignments and the simulation turns
## them into paths. Both are ephemeral: reset the run and the plan is gone. This
## object captures the decision and the routes so it can be saved, inspected,
## exported, and applied to a later run of the same scenario.
##
## The plan is deliberately plain JSON. It contains no node references, so it
## can be written by the game, opened by an analysis script, and reconstructed
## by the Demo Player. A route may be empty (flow-field assignment); consumers
## must then fall back to a straight cohort -> exit line and label it as an
## assignment-only plan.

const FORMAT: String = "ero-evacuation-plan"
const VERSION: int = 1

var name: String = ""
var created_at: String = ""
var source: String = "live"               # live | recording | manual
var source_demo_id: String = ""
var scene: String = ""
var save_slug: String = ""
var rng_seed: int = 0
var layout_signature: String = ""
var environment_version: int = -1

var algorithm: String = ""
var mode: String = ""
var weights: Dictionary = {}
var parameters: Dictionary = {}
var estimated_cost: float = INF
var estimated_completion_time: float = 0.0
var estimated_average_time: float = 0.0
var notes: String = ""
## Authored Route Paint cells bundled with the plan. Empty for a pure optimizer
## plan; present when the plan was created or edited with the Route Paint tool.
var authored_route_cells: Array = []

## Exit catalog: [{exit_id, name, position: [x,y,z], service_rate,
##                 max_queue_length, receiving_capacity, retain}]
var exits: Array = []

## [{cohort_id, position: [x,y,z], exit_id, count, members: [serial],
##   predicted_distance, predicted_travel_time, route: [[x,y,z], ...]}]
var cohorts: Array = []

## [{serial, exit_id, target: [x,y,z], spawn_position: [x,y,z],
##   route: [[x,y,z], ...], route_source: "recorded"|"live"|"straight",
##   reason: String}]
var assignments: Array = []


# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------

func to_dictionary() -> Dictionary:
	return {
		"format": FORMAT,
		"version": VERSION,
		"name": name,
		"created_at": created_at,
		"source": source,
		"source_demo_id": source_demo_id,
		"scene": scene,
		"save_slug": save_slug,
		"rng_seed": rng_seed,
		"layout_signature": layout_signature,
		"environment_version": environment_version,
		"algorithm": algorithm,
		"mode": mode,
		"weights": weights.duplicate(true),
		"parameters": parameters.duplicate(true),
		"estimated_cost": estimated_cost,
		"estimated_completion_time": estimated_completion_time,
		"estimated_average_time": estimated_average_time,
		"notes": notes,
		"exits": exits.duplicate(true),
		"cohorts": cohorts.duplicate(true),
		"assignments": assignments.duplicate(true),
		"authored_route_cells": authored_route_cells.duplicate(true),
	}


static func from_dictionary(data: Dictionary) -> EvacuationPlan:
	var plan := EvacuationPlan.new()

	if String(data.get("format", "")) != FORMAT:
		return null

	plan.name = String(data.get("name", ""))
	plan.created_at = String(data.get("created_at", ""))
	plan.source = String(data.get("source", "live"))
	plan.source_demo_id = String(data.get("source_demo_id", ""))
	plan.scene = String(data.get("scene", ""))
	plan.save_slug = String(data.get("save_slug", ""))
	plan.rng_seed = int(data.get("rng_seed", 0))
	plan.layout_signature = String(data.get("layout_signature", ""))
	plan.environment_version = int(data.get("environment_version", -1))
	plan.algorithm = String(data.get("algorithm", ""))
	plan.mode = String(data.get("mode", ""))
	plan.weights = _dictionary_value(data.get("weights", {}))
	plan.parameters = _dictionary_value(data.get("parameters", {}))
	plan.estimated_cost = float(data.get("estimated_cost", INF))
	plan.estimated_completion_time = float(data.get("estimated_completion_time", 0.0))
	plan.estimated_average_time = float(data.get("estimated_average_time", 0.0))
	plan.notes = String(data.get("notes", ""))
	plan.exits = _array_value(data.get("exits", []))
	plan.cohorts = _array_value(data.get("cohorts", []))
	plan.assignments = _array_value(data.get("assignments", []))
	plan.authored_route_cells = _array_value(data.get("authored_route_cells", []))
	return plan


func save_to(path: String) -> bool:
	var directory := path.get_base_dir()

	if not directory.is_empty():
		DirAccess.make_dir_recursive_absolute(directory)

	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return false

	file.store_string(JSON.stringify(to_dictionary(), "\t", false))
	file.close()
	return true


static func load_from(path: String) -> EvacuationPlan:
	if not FileAccess.file_exists(path):
		return null

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return null

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()

	if not parsed is Dictionary:
		return null

	return from_dictionary(parsed)


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func assignment_count() -> int:
	return assignments.size()


func cohort_count() -> int:
	return cohorts.size()


func routes_with_polylines() -> int:
	var count: int = 0

	for assignment: Dictionary in assignments:
		if _point_array(assignment.get("route", [])).size() >= 2:
			count += 1

	return count


func authored_cell_count() -> int:
	return authored_route_cells.size()


func exit_counts() -> Dictionary:
	var counts: Dictionary = {}

	for assignment: Dictionary in assignments:
		var exit_id := String(assignment.get("exit_id", ""))
		counts[exit_id] = int(counts.get(exit_id, 0)) + 1

	return counts


func summary_line() -> String:
	return "%s | %s / %s | %d assignments | %d routes | %d painted cells | seed %d" % [
		name if not name.is_empty() else "(unnamed plan)",
		algorithm if not algorithm.is_empty() else "plan",
		mode if not mode.is_empty() else "-",
		assignments.size(),
		routes_with_polylines(),
		authored_route_cells.size(),
		rng_seed,
	]


## A hash of the exit set and the used block cells. Two runs with the same
## signature have the same walkable layout and exits, so a saved assignment can
## be trusted. A different signature does not prove the plan is wrong, but the
## caller should ask before applying it.
static func compute_layout_signature(exit_rows: Array, used_cells: Array) -> String:
	var cell_keys: Array[String] = []

	for cell: Variant in used_cells:
		if cell is Vector3i:
			var value: Vector3i = cell
			cell_keys.append("%d,%d,%d" % [value.x, value.y, value.z])
		elif cell is Array and (cell as Array).size() >= 3:
			cell_keys.append("%s,%s,%s" % [cell[0], cell[1], cell[2]])
		elif cell is String:
			cell_keys.append(cell)

	cell_keys.sort()

	var exit_keys: Array[String] = []

	for row: Variant in exit_rows:
		if row is Dictionary:
			var data: Dictionary = row
			var position: Array = _point_to_array(data.get("position", data.get("location", [])))
			exit_keys.append("%s@%.2f,%.2f,%.2f" % [
				String(data.get("exit_id", "")),
				float(position[0]) if position.size() >= 3 else 0.0,
				float(position[1]) if position.size() >= 3 else 0.0,
				float(position[2]) if position.size() >= 3 else 0.0,
			])

	exit_keys.sort()

	return JSON.stringify({"cells": cell_keys, "exits": exit_keys}).sha256_text()


static func capture_layout_signature() -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree

	if tree == null:
		return {"signature": "", "exits": [], "used_cells": []}

	var exit_rows: Array = []
	var exit_keys: Dictionary = {}

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node) or not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")
		var exit_id := String(status.get("exit_id", ""))

		if exit_id.is_empty() or exit_keys.has(exit_id):
			continue

		exit_keys[exit_id] = true
		exit_rows.append({
			"exit_id": exit_id,
			"name": String(status.get("name", "")),
			"position": _point_to_array((node as Node3D).global_position),
			"service_rate": float(status.get("service_rate", 0.0)),
			"max_queue_length": int(status.get("max_queue_length", 0)),
			"receiving_capacity": int(status.get("receiving_capacity", 0)),
			"retain": bool(status.get("retain", false)),
		})

	var used_cells: Array = []
	var grid := tree.get_first_node_in_group("grid_map")

	if grid != null and grid.has_method("get_used_block_cells"):
		used_cells = grid.call("get_used_block_cells")

	return {
		"signature": compute_layout_signature(exit_rows, used_cells),
		"exits": exit_rows,
		"used_cells": used_cells,
	}


# ---------------------------------------------------------------------------
# Capture from a recording
# ---------------------------------------------------------------------------

## Rebuild a plan from a recorded demo. This is what makes an old run reusable:
## the recording already contains every optimizer decision and the actual route
## each agent walked, so no re-solve is needed.
static func from_recording(recording_path: String, demo_id: String = "") -> EvacuationPlan:
	if not FileAccess.file_exists(recording_path):
		return null

	var file := FileAccess.open(recording_path, FileAccess.READ)

	if file == null:
		return null

	var plan := EvacuationPlan.new()
	plan.source = "recording"
	plan.source_demo_id = demo_id
	plan.created_at = Time.get_datetime_string_from_system(true, true)

	var run_record: Dictionary = {}
	var latest_optimizer: Dictionary = {}
	var latest_route_by_serial: Dictionary = {}
	var latest_destination_by_serial: Dictionary = {}
	var spawn_by_serial: Dictionary = {}
	var final_tick: Dictionary = {}
	var evac_exit_by_serial: Dictionary = {}
	var last_end: Dictionary = {}

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
				run_record = record
			"optimizer":
				latest_optimizer = record
			"route", "route_change":
				latest_route_by_serial[int(record.get("agent", -1))] = record
			"destination":
				latest_destination_by_serial[int(record.get("agent", -1))] = record
			"agent_spawn":
				spawn_by_serial[int(record.get("agent", -1))] = record
			"evacuation":
				evac_exit_by_serial[int(record.get("agent", -1))] = String(record.get("exit_id", ""))
			"tick":
				final_tick = record
			"end":
				last_end = record

	file.close()

	plan.scene = String(run_record.get("scene", ""))
	plan.save_slug = String(run_record.get("save_slug", ""))
	plan.rng_seed = int(run_record.get("rng_seed", 0))
	plan.exits = _array_value(run_record.get("exits", []))

	var metadata: Dictionary = _dictionary_value(run_record.get("metadata", {}))
	var optimizer_config: Dictionary = _dictionary_value(metadata.get("optimizer", {}))
	var configuration: Dictionary = _dictionary_value(optimizer_config.get("configuration", {}))
	var detail: Dictionary = _dictionary_value(latest_optimizer.get("detail", {}))
	plan.algorithm = String(detail.get("algorithm", configuration.get("algorithm", "")))
	plan.mode = String(detail.get("mode", configuration.get("mode", "")))
	plan.weights = _dictionary_value(configuration.get("weights", {}))
	plan.parameters = _dictionary_value(configuration.get("parameters", {}))
	plan.estimated_cost = float(detail.get("estimated_cost", INF))
	plan.estimated_completion_time = float(detail.get("estimated_completion_time", 0.0))
	plan.estimated_average_time = float(detail.get("estimated_average_time", 0.0))
	plan.environment_version = int(detail.get("environment_version", -1))

	var recorded_cohorts: Array = _array_value(detail.get("cohorts", []))
	var recorded_assignments: Dictionary = _dictionary_value(detail.get("assignments", {}))

	var exit_position_by_id: Dictionary = {}

	for exit_row: Variant in plan.exits:
		if exit_row is Dictionary:
			var exit_data: Dictionary = exit_row
			exit_position_by_id[String(exit_data.get("exit_id", ""))] = _point_array(
				exit_data.get("position", exit_data.get("location", []))
			)

	# Serial -> exit. Prefer the optimizer event's explicit assignment map,
	# then optimizer/plan-labelled routes, then the recorded destination.
	var serial_exit: Dictionary = {}

	for serial_value: Variant in recorded_assignments.keys():
		serial_exit[int(serial_value)] = String(recorded_assignments[serial_value])

	var final_rows: Dictionary = {}

	for row_value: Variant in final_tick.get("agents", []):
		if row_value is Array and (row_value as Array).size() > 41:
			final_rows[int(row_value[0])] = row_value

	for serial: int in latest_route_by_serial.keys():
		var route: Dictionary = latest_route_by_serial[serial]
		var reason := String(route.get("reason", ""))

		if reason not in ["optimizer", "plan"]:
			continue

		var exit_id := String(route.get("exit_id", ""))

		if not exit_id.is_empty():
			serial_exit[serial] = exit_id

	for serial: int in final_rows.keys():
		var row: Array = final_rows[serial]

		if bool(row[40]) and not serial_exit.has(serial):
			serial_exit[serial] = String(row[41])

	for serial: int in evac_exit_by_serial.keys():
		if not serial_exit.has(serial):
			serial_exit[serial] = String(evac_exit_by_serial[serial])

	# Build assignments with the actual recorded polyline where it exists.
	for serial_value: Variant in serial_exit.keys():
		var serial := int(serial_value)
		var exit_id := String(serial_exit[serial_value])

		if exit_id.is_empty():
			continue

		var route: Dictionary = latest_route_by_serial.get(serial, {})
		var route_points: Array = _point_array_list(route.get("path", []))
		var route_source := "recorded"

		if route_points.size() < 2:
			var destination: Dictionary = latest_destination_by_serial.get(serial, {})
			var spawn: Dictionary = spawn_by_serial.get(serial, {})
			var start := _point_array(
				spawn.get("position", destination.get("previous_target", []))
			)
			var finish := _point_array(exit_position_by_id.get(exit_id, route.get("target", [])))

			if start.size() >= 3 and finish.size() >= 3:
				route_points = [start, finish]
				route_source = "straight"

		plan.assignments.append({
			"serial": serial,
			"exit_id": exit_id,
			"target": _point_array(exit_position_by_id.get(exit_id, route.get("target", []))),
			"spawn_position": _point_array(
				(spawn_by_serial.get(serial, {}) as Dictionary).get("position", [])
			),
			"route": route_points,
			"route_source": route_source,
			"reason": "optimizer",
		})

	plan.assignments.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("serial", 0)) < int(b.get("serial", 0))
	)

	# Cohort rows are useful for drawing the assignment overlay. Old recordings
	# did not store them, so rebuild an exit-grouped approximation.
	if recorded_cohorts.is_empty():
		var groups: Dictionary = {}

		for assignment: Dictionary in plan.assignments:
			var exit_id := String(assignment.get("exit_id", ""))
			var bucket := Vector3i(
				int(floor(float((assignment.get("spawn_position", [0, 0, 0]) as Array)[0]) / 4.0)),
				0,
				int(floor(float((assignment.get("spawn_position", [0, 0, 0]) as Array)[2]) / 4.0))
			)
			var key := "%s:%d:%d" % [exit_id, bucket.x, bucket.z]

			if not groups.has(key):
				groups[key] = {
					"cohort_id": groups.size(),
					"position": assignment.get("spawn_position", []),
					"exit_id": exit_id,
					"count": 0,
					"members": [],
					"route": assignment.get("route", []),
				}

			var group: Dictionary = groups[key]
			group["count"] = int(group["count"]) + 1
			(group["members"] as Array).append(int(assignment.get("serial", 0)))

		for key: Variant in groups.keys():
			plan.cohorts.append(groups[key])
	else:
		for cohort_value: Variant in recorded_cohorts:
			if cohort_value is Dictionary:
				plan.cohorts.append((cohort_value as Dictionary).duplicate(true))

	plan.name = "%s %s" % [
		"Retrieved",
		String(run_record.get("started_at", demo_id if not demo_id.is_empty() else "run")),
	]
	plan.notes = "Reconstructed from a recording; routes are the recorded paths."

	if not last_end.is_empty():
		plan.estimated_completion_time = maxf(
			plan.estimated_completion_time,
			float(_dictionary_value(last_end.get("summary", {})).get("total_evacuation_time", 0.0))
		)

	return plan


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _point_to_array(value: Variant) -> Array:
	if value is Vector3:
		var point: Vector3 = value
		return [point.x, point.y, point.z]

	if value is Vector3i:
		var cell: Vector3i = value
		return [cell.x, cell.y, cell.z]

	if value is Array:
		return (value as Array).duplicate()

	return []


static func _point_array(value: Variant) -> Array:
	if value is Array:
		return (value as Array).duplicate()

	if value is Vector3:
		return _point_to_array(value)

	return []


static func _point_array_list(value: Variant) -> Array:
	var result: Array = []

	if not value is Array:
		return result

	for point: Variant in value:
		var flat := _point_array(point)

		if flat.size() >= 3:
			result.append([float(flat[0]), float(flat[1]), float(flat[2])])

	return result


static func _dictionary_value(value: Variant) -> Dictionary:
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


static func _array_value(value: Variant) -> Array:
	return (value as Array).duplicate(true) if value is Array else []
