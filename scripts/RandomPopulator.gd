class_name RandomPopulator
extends Node

## One-shot population tool. Spawns members on random navigation cells and can
## restrict them to cells that have a real path to an evacuation point.

@export_group("Population")
@export var member_count: int = 50
@export var start_evacuating: bool = true
@export var only_pathfindable_blocks: bool = true

@export_group("Scene")
@export var member_scene: PackedScene = preload("res://scenes/npcs/Member.tscn")


func populate() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"spawned": 0, "reason": "No scene tree."}

	var grid := tree.get_first_node_in_group("grid_map") as NavGridMap
	if grid == null:
		return {"spawned": 0, "reason": "No grid map found."}

	if member_scene == null:
		return {"spawned": 0, "reason": "No member scene assigned."}

	var evac_positions: Array[Vector3] = []
	if only_pathfindable_blocks:
		for node in tree.get_nodes_in_group("EvacPoint"):
			var point := node as Node3D
			if point != null and is_instance_valid(point):
				evac_positions.append(point.global_position)

		if evac_positions.is_empty():
			return {
				"spawned": 0,
				"reason": "Pathfind-only is enabled but there is no evacuation point.",
			}

	var candidates: Array[Vector3i] = []
	for cell: Vector3i in grid.get_used_cells():
		if grid.is_nav_cell_valid(cell):
			candidates.append(cell)

	if candidates.is_empty():
		return {"spawned": 0, "reason": "No walkable navigation cells."}

	var parent: Node = tree.current_scene
	if parent == null:
		parent = tree.root

	var spawned: int = 0
	var attempts: int = 0
	var alive: int = tree.get_nodes_in_group("npc").size()
	var max_attempts: int = maxi(candidates.size() * 2, member_count * 20 + 100)

	while spawned < member_count and attempts < max_attempts:
		attempts += 1

		if alive >= GlobalData.global_unit_cap:
			break

		if not GlobalData.is_global_quota_available():
			break

		var cell: Vector3i = candidates.pick_random()
		var spawn_position: Vector3 = grid.to_global(
			grid.map_to_local(cell) + Vector3(0.0, grid.cell_size.y * 0.5, 0.0)
		)

		if only_pathfindable_blocks:
			var reachable: bool = false
			for evac_position: Vector3 in evac_positions:
				if grid.estimate_path_distance(spawn_position, evac_position) < INF:
					reachable = true
					break

			if not reachable:
				continue

		var member := member_scene.instantiate() as Node3D
		if member == null:
			continue

		parent.add_child(member)
		member.global_position = spawn_position

		if member.has_method("set_evacuation_mode"):
			member.set_evacuation_mode(start_evacuating)

		GlobalData.register_npc_spawned()

		var manager := tree.root.get_node_or_null("EvacuationManager")
		if manager and manager.has_method("register_npc"):
			manager.register_npc(member)

		spawned += 1
		alive += 1

	var reason: String = ""
	if spawned < member_count and attempts >= max_attempts:
		reason = "Could not find enough valid spawn cells."

	return {
		"spawned": spawned,
		"requested": member_count,
		"attempts": attempts,
		"reason": reason,
	}
