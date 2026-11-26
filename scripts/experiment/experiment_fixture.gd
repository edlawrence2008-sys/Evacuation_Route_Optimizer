extends Node

## Programmatic experiment fixture builder.
##
## The shipped map has no exits or spawners, so a manifest can declare a fixture
## instead of pointing at a hand-made save. This node builds it in the current
## scene, beside the HUD/optimizer panel, so the batch runner still finds the
## bridge and RandomPopulator.
##
## Console:
##   fixture_build s1
##   fixture_build clear
##
## Manifest scenario:
##   "fixture": {
##     "id": "S1_symmetric",
##     "width": 30, "depth": 20,
##     "exits": [{"id": "E1", "position": [3,1,3], "rate": 1.2}, ...],
##     "spawners": [{"position": [15,0,10], "quota": 600, "interval": 0.1}],
##     "disable_at": [{"exit_id": "E4", "t": 20}]
##   }

const MEMBER_SCENE := preload("res://scenes/npcs/Member.tscn")
const EVAC_SCENE := preload("res://scenes/placeables/sim/sim_evac_point.tscn")
const SPAWNER_SCENE := preload("res://scenes/placeables/sim/sim_spawner.tscn")

var _root: Node3D = null
var _exits: Array = []
var _disable_events: Array = []
var _started_sim: float = 0.0
var _fixture_cells: Array[Vector3i] = []

const PRESETS: Dictionary = {
	"s1": {
		"id": "S1_symmetric",
		"width": 30,
		"depth": 20,
		"exits": [
			{"id": "E1", "position": [3.0, 1.0, 3.0], "rate": 1.2},
			{"id": "E2", "position": [26.5, 1.0, 3.0], "rate": 1.2},
			{"id": "E3", "position": [3.0, 1.0, 16.5], "rate": 1.2},
			{"id": "E4", "position": [26.5, 1.0, 16.5], "rate": 1.2},
		],
	},
	"s2": {
		"id": "S2_asymmetric",
		"width": 30,
		"depth": 20,
		"exits": [
			{"id": "E1", "position": [3.0, 1.0, 3.0], "rate": 1.6},
			{"id": "E2", "position": [26.5, 1.0, 3.0], "rate": 1.1},
			{"id": "E3", "position": [3.0, 1.0, 16.5], "rate": 0.7},
			{"id": "E4", "position": [26.5, 1.0, 16.5], "rate": 0.4},
		],
	},
	"s3": {
		"id": "S3_scale",
		"width": 40,
		"depth": 24,
		"exits": [
			{"id": "E1", "position": [3.0, 1.0, 3.0], "rate": 1.2},
			{"id": "E2", "position": [36.5, 1.0, 3.0], "rate": 1.2},
			{"id": "E3", "position": [3.0, 1.0, 20.5], "rate": 1.2},
			{"id": "E4", "position": [36.5, 1.0, 20.5], "rate": 1.2},
		],
		"spawners": [
			{"position": [20.0, 0.0, 5.0], "quota": 600, "interval": 0.05, "batch": 3},
			{"position": [20.0, 0.0, 18.0], "quota": 0, "interval": 0.05, "batch": 3},
		],
	},
	"s4": {
		"id": "S4_disruption",
		"width": 30,
		"depth": 20,
		"exits": [
			{"id": "E1", "position": [3.0, 1.0, 3.0], "rate": 1.2},
			{"id": "E2", "position": [26.5, 1.0, 3.0], "rate": 1.2},
			{"id": "E3", "position": [3.0, 1.0, 16.5], "rate": 1.2},
			{"id": "E4", "position": [26.5, 1.0, 16.5], "rate": 1.2},
		],
		"disable_at": [{"exit_id": "E4", "t": 20.0}],
	},
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func build(config: Dictionary) -> Dictionary:
	clear()

	var tree := get_tree()

	if tree == null:
		return {"ok": false, "error": "no scene tree"}

	var host: Node = tree.current_scene

	if host == null:
		host = tree.root

	_root = Node3D.new()
	_root.name = "ExperimentFixture"
	host.add_child(_root)

	var width := maxi(4, int(config.get("width", 30)))
	var depth := maxi(4, int(config.get("depth", 20)))
	var grid := tree.get_first_node_in_group("grid_map") as NavGridMap

	if grid == null:
		grid = NavGridMap.new()
		grid.name = "FixtureGrid"
		grid.mesh_library = _make_library()
		grid.cell_size = Vector3.ONE
		grid.enable_greedy_meshing = false
		grid.enable_flow_fields = bool(config.get("flow_fields", false))
		grid.auto_generate_stairs = false
		grid.wall_force_enabled = false
		host.add_child(grid)

	# Replace the walkable cells with a clean rectangle. keeping existing
	# blocks is not appropriate for a frozen fixture.
	_clear_grid(grid)
	var cells: Array[Vector3i] = []

	for x: int in range(width):
		for z: int in range(depth):
			cells.append(Vector3i(x, 0, z))

	grid.place_blocks(cells, 0)
	_fixture_cells = cells

	var exits: Array = config.get("exits", [])

	if exits.is_empty():
		exits = PRESETS["s1"]["exits"]

	for exit_value: Variant in exits:
		if not exit_value is Dictionary:
			continue

		var exit_data: Dictionary = exit_value
		_add_exit(
			String(exit_data.get("id", "E%d" % (_exits.size() + 1))),
			_vector(exit_data.get("position", [3.0, 1.0, 3.0])),
			float(exit_data.get("rate", 1.2))
		)

	for spawner_value: Variant in config.get("spawners", []):
		if spawner_value is Dictionary:
			_add_spawner(spawner_value)

	_disable_events = config.get("disable_at", []).duplicate(true)
	_started_sim = GlobalData.sim_now()
	set_process(true)
	return {
		"ok": true,
		"exits": _exits.size(),
		"cells": cells.size(),
		"spawners": _root.get_child_count(),
	}


func build_preset(preset: String) -> Dictionary:
	var key := preset.to_lower()

	if key == "clear":
		clear()
		return {"ok": true, "cleared": true}

	if not PRESETS.has(key):
		return {"ok": false, "error": "unknown fixture preset: %s" % preset}

	return build(PRESETS[key])


func clear() -> void:
	set_process(false)
	_disable_events.clear()
	_exits.clear()

	if not _fixture_cells.is_empty():
		var tree := get_tree()
		var grid: NavGridMap = null

		if tree != null:
			grid = tree.get_first_node_in_group("grid_map") as NavGridMap

		if grid != null:
			grid.remove_blocks(_fixture_cells)

		_fixture_cells.clear()

	if _root != null and is_instance_valid(_root):
		_root.queue_free()

	_root = null


func _process(_delta: float) -> void:
	if _disable_events.is_empty():
		return

	var elapsed := GlobalData.sim_now() - _started_sim
	var pending: Array = []

	for event_value: Variant in _disable_events:
		if not event_value is Dictionary:
			continue

		var event: Dictionary = event_value

		if elapsed >= float(event.get("t", 0.0)):
			var exit_id := String(event.get("exit_id", ""))

			for exit_node: Node in _exits:
				if exit_node != null and is_instance_valid(exit_node) and exit_node.has_method("get_exit_id"):
					if String(exit_node.call("get_exit_id")) == exit_id:
						exit_node.call("set_operational", false)
		else:
			pending.append(event)

	_disable_events = pending


func _add_exit(exit_id: String, position: Vector3, rate: float) -> void:
	var exit_instance: Node3D = EVAC_SCENE.instantiate()
	var area := exit_instance.get_node("Area3D") as Area3D
	area.set("exit_id", exit_id)
	area.set("exit_service_rate", rate)
	area.set("track_evacuation", true)
	area.set("retain_evacuated", false)
	exit_instance.position = position
	_root.add_child(exit_instance)
	_exits.append(area)


func _add_spawner(config: Dictionary) -> void:
	var spawner: Node3D = SPAWNER_SCENE.instantiate()
	spawner.position = _vector(config.get("position", [15.0, 0.0, 10.0]))
	spawner.set("spawn_quota", int(config.get("quota", 100)))
	spawner.set("spawn_interval", float(config.get("interval", 0.5)))
	spawner.set("spawn_batch_size", int(config.get("batch", 1)))
	_root.add_child(spawner)


func _clear_grid(grid: NavGridMap) -> void:
	var used: Array = grid.get_used_block_cells()

	if not used.is_empty():
		grid.remove_blocks(used)


func _make_library() -> MeshLibrary:
	var library := MeshLibrary.new()
	var box := BoxMesh.new()
	var shape := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.size = Vector3.ONE
	library.create_item(0)
	library.set_item_name(0, "FixtureFloor")
	library.set_item_mesh(0, box)
	library.set_item_shapes(0, [shape, Transform3D.IDENTITY])
	return library


func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value

	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return Vector3.ZERO
