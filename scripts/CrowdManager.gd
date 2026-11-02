extends Node

@export var cell_size: float = 1.5
@export var default_max_neighbors: int = 20
@export var crowd_tick_rate: float = 0.1

var grid: Dictionary = {}
var npc_count: int = 0

var _crowd_tick_timer: float = 0.0


func _ready() -> void:
	process_physics_priority = -100


func _physics_process(delta: float) -> void:
	_crowd_tick_timer += delta

	if _crowd_tick_timer < crowd_tick_rate:
		return

	_crowd_tick_timer = 0.0
	var npcs: Array[Node] = get_tree().get_nodes_in_group("npc")
	_rebuild_grid(npcs)
	_update_crowd_density(npcs)


func _rebuild_grid(npcs: Array[Node]) -> void:
	grid.clear()
	npc_count = 0

	for npc: Node in npcs:
		var body := npc as CharacterBody3D

		if body == null or not is_instance_valid(body):
			continue

		var cell: Vector2i = position_to_cell(body.global_position)

		if not grid.has(cell):
			grid[cell] = []

		grid[cell].append(body)
		npc_count += 1


func get_nearby_npcs(
	position: Vector3,
	max_results: int = -1
) -> Array[CharacterBody3D]:
	if max_results < 0:
		max_results = default_max_neighbors

	var center_cell: Vector2i = position_to_cell(position)
	var result: Array[CharacterBody3D] = []

	for x: int in range(-1, 2):
		for z: int in range(-1, 2):
			var cell: Vector2i = center_cell + Vector2i(x, z)
			var cell_npcs: Array = grid.get(cell, [])

			# Read untyped: the hash can still contain an NPC freed since the
			# last rebuild, and a typed loop assignment errors on freed objects
			# before the validity check below can run.
			for npc in cell_npcs:
				if not is_instance_valid(npc) or not (npc is CharacterBody3D):
					continue

				result.append(npc)

				if result.size() >= max_results:
					return result

	return result


func get_density(position: Vector3, query_radius: float = 2.0) -> float:
	var nearby: Array[CharacterBody3D] = get_nearby_npcs(
		position,
		default_max_neighbors
	)
	var count: int = 0

	for npc: CharacterBody3D in nearby:
		if npc == null or not is_instance_valid(npc):
			continue

		var difference: Vector3 = npc.global_position - position
		difference.y = 0.0

		if difference.length_squared() <= query_radius * query_radius:
			count += 1

	return float(count)


func position_to_cell(position: Vector3) -> Vector2i:
	return Vector2i(
		floori(position.x / cell_size),
		floori(position.z / cell_size)
	)


func _update_crowd_density(npcs: Array[Node]) -> void:
	for npc: Node in npcs:
		var body := npc as CharacterBody3D

		if body == null or not is_instance_valid(body):
			continue

		if body.has_method("set_local_density"):
			var density: float = get_density(body.global_position)
			body.set_local_density(density)
