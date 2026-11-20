extends Node

## Demo state-restore acceptance: an imported agent keeps its recorded identity,
## speed, exit target, pre-movement remainder and counters; an exit's admission
## totals are restored; and a spawner with quota left keeps spawning after the
## live crowd is replaced.
##
##   godot --headless --path . res://tests/demo_restore_test.tscn

const MEMBER_SCENE := preload("res://scenes/npcs/Member.tscn")
const EVAC_SCENE := preload("res://scenes/placeables/sim/sim_evac_point.tscn")
const SPAWNER_SCENE := preload("res://scenes/placeables/sim/sim_spawner.tscn")

var _checks: int = 0
var _failures: int = 0
var _world: Node3D
var _grid: NavGridMap
var _exit_a: Node3D
var _exit_b: Node3D
var _spawner: Node3D


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== demo restore ===")
	# This harness starts a spawner on purpose; do not let the recorder write a
	# demo into the player's active save while testing.
	if SimRecorder != null:
		SimRecorder.set_recording_enabled(false)

	await get_tree().process_frame
	_build_world()
	await get_tree().process_frame
	await get_tree().physics_frame

	var recorded: Dictionary = _recorded_agent_state()
	var pre_recorded: Dictionary = _recorded_pre_movement_state()

	var recorder_constants: Dictionary = SimRecorder.get_script().get_script_constant_map()
	var agent_fields: Array = recorder_constants.get("AGENT_FIELDS", [])
	var player_constants: Dictionary = DemoPlayer.get_script().get_script_constant_map()
	_expect(
		"schema: agent row has 42 fields",
		agent_fields.size() == 42,
		str(agent_fields.size())
	)
	_expect(
		"schema: player spawned_at index matches",
		int(player_constants.get("AGENT_SPAWNED_AT", -1))
		== agent_fields.find("spawned_at"),
		str(agent_fields.find("spawned_at"))
	)
	_expect(
		"schema: player optimizer index matches",
		int(player_constants.get("AGENT_OPTIMIZER_EXIT_ID", -1))
		== agent_fields.find("optimizer_exit_id"),
		str(agent_fields.find("optimizer_exit_id"))
	)
	var exit_totals: Dictionary = {
		"accepted": 42,
		"rejected": 3,
		"capacity_waits": 5,
		"capacity_rejections": 1,
		"queue_full_rejections": 2,
		"max_queue": 6,
		"peak_occupancy": 4,
		"average_wait": 1.5,
		"max_wait": 4.25,
	}

	# Pretend one agent already came from this spawner and one admitted at A.
	_spawner.call("restore_measurement_state", {
		"spawned_count": 1,
		"spawn_timer": 0.0,
		"section_count": 0,
	})
	GlobalData.npcs_spawned = 1
	GlobalData.npcs_evacuated = 0
	GlobalData.sim_time = 40.0
	GlobalData.rng_seed = 777

	# --- Load State path -------------------------------------------------
	GlobalData.set_evacuation_mode(true)
	GlobalData.kill_all_npcs()

	var manager := get_node_or_null("/root/EvacuationManager")

	if manager != null and manager.has_method("reset_run"):
		manager.call("reset_run")

	for node: Node in get_tree().get_nodes_in_group("EvacPoint"):
		if node.has_method("reset_counters"):
			node.call("reset_counters")

	_exit_a.call("restore_counters", exit_totals)

	var history: Array = [
		{
			"type": "evacuation", "t": 20.0, "agent": 101, "exit_id": "A",
			"exit_name": "EvacPoint", "evacuation_time": 30.0, "wait_time": 0.5,
			"distance": 40.0, "stuck_time": 1.0, "stuck_strikes": 0,
			"peak_density": 1.2, "peak_contact_force": 10.0,
			"pre_movement_wait": 2.0, "route_changes": 1, "route_switches": 0,
		},
		{
			"type": "evacuation", "t": 35.0, "agent": 102, "exit_id": "B",
			"exit_name": "EvacPoint", "evacuation_time": 20.0, "wait_time": 0.0,
			"distance": 25.0, "stuck_time": 0.0, "stuck_strikes": 0,
			"peak_density": 0.8, "peak_contact_force": 6.0,
			"pre_movement_wait": 4.0, "route_changes": 0, "route_switches": 0,
		},
		{
			"type": "evacuation", "t": 60.0, "agent": 103, "exit_id": "A",
			"exit_name": "EvacPoint", "evacuation_time": 5.0,
		},
	]
	var replayed: int = 0

	if manager != null and manager.has_method("restore_evacuation_history"):
		replayed = int(
			manager.call("restore_evacuation_history", history, 40.0, 0.0)
		)

	var timing: Dictionary = manager.get_summary() if manager != null else {}
	_expect("restore: history respects cutoff", replayed == 2, str(replayed))
	_expect(
		"restore: history average",
		_is_close(float(timing.get("average_time", 0.0)), 25.0, 0.01),
		str(timing.get("average_time", 0.0))
	)
	_expect(
		"restore: history max",
		_is_close(float(timing.get("max_time", 0.0)), 30.0, 0.01),
		str(timing.get("max_time", 0.0))
	)

	var restored: Node3D = MEMBER_SCENE.instantiate()
	restored.position = recorded["position"]
	_world.add_child(restored)
	restored.call("apply_demo_state", recorded)
	GlobalData.notify_agent_spawned(restored)

	if manager != null and manager.has_method("restore_agent_spawn_time"):
		manager.call(
			"restore_agent_spawn_time",
			restored,
			float(recorded["spawned_at"])
		)

	var pre_member: Node3D = MEMBER_SCENE.instantiate()
	pre_member.position = pre_recorded["position"]
	_world.add_child(pre_member)
	pre_member.call("apply_demo_state", pre_recorded)

	GlobalData.set_agent_serial_floor(8)
	GlobalData.npcs_spawned = 1
	GlobalData.npcs_evacuated = 0
	GlobalData.start_spawning()

	# --- Assertions ------------------------------------------------------
	var status: Dictionary = _exit_a.call("get_exit_status")
	_expect("restore: exit accepted", int(status["accepted"]) == 42, str(status["accepted"]))
	_expect(
		"restore: exit average wait",
		_is_close(float(status["average_wait"]), 1.5, 0.001),
		str(status["average_wait"])
	)
	_expect("restore: exit max queue", int(status["max_queue"]) == 6, str(status["max_queue"]))
	_expect(
		"restore: exit peak occupancy",
		int(status["peak_occupancy"]) == 4,
		str(status["peak_occupancy"])
	)

	var state: Dictionary = restored.call("get_measurement_state")
	_expect("restore: agent serial", int(state["serial"]) == 7, str(state["serial"]))
	_expect(
		"restore: agent speed",
		_is_close(float(state["desired_speed"]), 0.65, 0.001),
		str(state["desired_speed"])
	)
	_expect(
		"restore: agent position",
		Vector3(state["position"]).distance_to(recorded["position"]) < 0.05,
		str(state["position"])
	)
	_expect("restore: route changes", int(state["route_changes"]) == 4, str(state["route_changes"]))
	_expect(
		"restore: distance travelled",
		_is_close(float(state["distance"]), 33.0, 0.001),
		str(state["distance"])
	)
	_expect(
		"restore: spawn time",
		_is_close(float(state["spawned_at"]), 20.0, 0.001),
		str(state["spawned_at"])
	)
	_expect("restore: exit target retained", bool(state["has_target"]))

	var pre_state: Dictionary = pre_member.call("get_measurement_state")
	_expect(
		"restore: pre-movement status",
		String(pre_state["status"]) == "pre_movement",
		String(pre_state["status"])
	)
	_expect(
		"restore: pre-movement remainder",
		_is_close(float(pre_state["pre_movement_wait"]), 3.0, 0.001),
		str(pre_state["pre_movement_wait"])
	)

	var next_serial: int = GlobalData.claim_agent_serial()
	_expect("restore: serial floor", next_serial > 8, str(next_serial))

	var before_spawn: int = GlobalData.npcs_spawned
	var deadline: int = Time.get_ticks_msec() + 4000

	while (
		GlobalData.npcs_spawned < 3
		and Time.get_ticks_msec() < deadline
	):
		await get_tree().process_frame

	_expect(
		"restore: spawners keep spawning",
		GlobalData.npcs_spawned > before_spawn,
		"%d -> %d" % [before_spawn, GlobalData.npcs_spawned]
	)
	_expect(
		"restore: restored quota is respected",
		GlobalData.npcs_spawned <= 3,
		str(GlobalData.npcs_spawned)
	)

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "DemoRestore"
	add_child(_world)

	_grid = NavGridMap.new()
	_grid.name = "RestoreGrid"
	_grid.mesh_library = _make_library()
	_grid.cell_size = Vector3.ONE
	_grid.enable_greedy_meshing = false
	_grid.enable_flow_fields = false
	_grid.auto_generate_stairs = false
	_grid.wall_force_enabled = false
	_world.add_child(_grid)

	var floor_cells: Array[Vector3i] = []

	for x: int in range(30):
		for z: int in range(12):
			floor_cells.append(Vector3i(x, 0, z))

	_grid.place_blocks(floor_cells, 0)

	_exit_a = _add_exit("A", Vector3(2.5, 1.0, 2.5))
	_exit_b = _add_exit("B", Vector3(27.5, 1.0, 9.5))

	_spawner = SPAWNER_SCENE.instantiate()
	_spawner.name = "RestoreSpawner"
	_spawner.position = Vector3(24.0, 0.0, 4.0)
	_spawner.set("spawn_quota", 3)
	_spawner.set("spawn_interval", 0.05)
	_spawner.set("spawn_batch_size", 1)
	_spawner.set("spawn_radius", 1.0)
	_spawner.set("spawn_scatter_radius", 1.5)
	_world.add_child(_spawner)


func _recorded_agent_state() -> Dictionary:
	return {
		"serial": 7,
		"status": "seeking_exit",
		"state": 4,
		"position": Vector3(10.0, 0.75, 5.0),
		"velocity": Vector3(0.4, 0.0, 0.2),
		"acceleration": Vector3.ZERO,
		"destination": _exit_b.global_position,
		"exit_id": "B",
		"distance": 33.0,
		"contact_force": 12.0,
		"density": 1.4,
		"route_changes": 4,
		"route_switches": 2,
		"stuck_strikes": 2,
		"desired_speed": 0.65,
		"pre_movement_delay": 0.0,
		"pre_movement_wait": 0.0,
		"stuck_time": 5.5,
		"is_evacuee": true,
		"has_target": true,
		"peak_density": 2.2,
		"peak_contact_force": 120.0,
		"spawned_at": 20.0,
		"optimizer_assigned": false,
		"optimizer_exit_id": "",
	}


func _recorded_pre_movement_state() -> Dictionary:
	return {
		"serial": 8,
		"status": "pre_movement",
		"state": 0,
		"position": Vector3(12.0, 0.75, 5.0),
		"velocity": Vector3.ZERO,
		"acceleration": Vector3.ZERO,
		"destination": Vector3.ZERO,
		"exit_id": "",
		"distance": 0.0,
		"contact_force": 0.0,
		"density": 0.0,
		"route_changes": 0,
		"route_switches": 0,
		"stuck_strikes": 0,
		"desired_speed": 1.1,
		"pre_movement_delay": 10.0,
		"pre_movement_wait": 3.0,
		"stuck_time": 0.0,
		"is_evacuee": true,
		"has_target": false,
		"peak_density": 0.0,
		"peak_contact_force": 0.0,
		"spawned_at": 30.0,
		"optimizer_assigned": false,
		"optimizer_exit_id": "",
	}


func _add_exit(exit_id: String, position: Vector3) -> Node3D:
	var exit_instance: Node3D = EVAC_SCENE.instantiate()
	var area := exit_instance.get_node("Area3D") as Area3D
	area.set("exit_id", exit_id)
	area.set("exit_service_rate", 1.0)
	area.set("track_evacuation", true)
	exit_instance.position = position
	_world.add_child(exit_instance)
	return area


func _make_library() -> MeshLibrary:
	var library := MeshLibrary.new()
	var box := BoxMesh.new()
	var shape := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.size = Vector3.ONE
	library.create_item(0)
	library.set_item_name(0, "TestCube")
	library.set_item_mesh(0, box)
	library.set_item_shapes(0, [shape, Transform3D.IDENTITY])
	return library


func _is_close(value: float, expected: float, tolerance: float) -> bool:
	return absf(value - expected) <= tolerance


func _expect(name: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + name)
		return

	_failures += 1
	print("  FAIL  " + name + ("" if detail.is_empty() else "  [" + detail + "]"))
