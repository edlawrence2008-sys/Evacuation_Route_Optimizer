class_name SimulationSnapshot
extends RefCounted

## Read-only view of the simulation handed to the optimization layer.
##
## The optimizer never touches the scene tree. The bridge (a later phase) fills
## this object from live nodes, and `optimization/` treats it as immutable.
## Units are metres and seconds; `agents` and `exits` are arrays of plain
## dictionaries so the data survives recording and replay.
##
## Agent dictionary:
##   serial: int, position: Vector3, cell: Vector3i, desired_speed: float,
##   state: String, has_target: bool, exit_id: String,
##   path_remaining: float, path_cells: Array[Vector3i] (optional)
##
## Exit dictionary:
##   exit_id: String, name: String, position: Vector3, cell: Vector3i,
##   available: bool, service_rate: float, max_queue_length: int,
##   receiving_capacity: int, retain_evacuated: bool, queue_length: int,
##   receiving_occupancy: int, accepted: int, average_wait: float
##
## `nav` dictionary:
##   cell_size: Vector3,
##   cost_fields: { exit_id: { Vector3i: float } }  # weighted metres to exit

var sim_time: float = 0.0
var rng_seed: int = 0
var environment_version: int = 0
var agent_cap: int = 0

var agents: Array = []
var exits: Array = []
## Measured cell congestion heat, Vector3i -> float in 0..1. Used as a prior,
## never as the prediction of a proposed assignment.
var congestion_heat: Dictionary = {}
var nav: Dictionary = {}
## Hazard cells/volumes. Empty until the hazard phase; the optimizer ignores it.
var hazards: Array = []


func get_cell_size() -> Vector3:
	var value: Variant = nav.get("cell_size", Vector3.ONE)

	if value is Vector3:
		return value

	return Vector3.ONE


func get_cost_field(exit_id: String) -> Dictionary:
	var fields: Variant = nav.get("cost_fields", {})

	if not fields is Dictionary:
		return {}

	var field: Variant = (fields as Dictionary).get(exit_id, {})

	return field if field is Dictionary else {}


func get_exit(exit_id: String) -> Dictionary:
	for exit_data: Dictionary in exits:
		if String(exit_data.get("exit_id", "")) == exit_id:
			return exit_data

	return {}


func get_available_exits() -> Array:
	var result: Array = []

	for exit_data: Dictionary in exits:
		if bool(exit_data.get("available", true)):
			result.append(exit_data)

	return result


func get_exit_ids() -> Array:
	var result: Array = []

	for exit_data: Dictionary in exits:
		result.append(String(exit_data.get("exit_id", "")))

	return result


func is_empty() -> bool:
	return agents.is_empty() or get_available_exits().is_empty()


func get_agent_cells() -> Array:
	var cells: Array = []

	for agent: Dictionary in agents:
		cells.append(agent.get("cell", Vector3i.ZERO))

	return cells


func describe() -> String:
	return (
		"snapshot t=%.2f agents=%d exits=%d available=%d v=%d"
		% [
			sim_time,
			agents.size(),
			exits.size(),
			get_available_exits().size(),
			environment_version,
		]
	)
