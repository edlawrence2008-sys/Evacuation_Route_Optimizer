class_name RandomPopulator
extends Node

## One-shot population tool. Spawns members on random navigation cells and can
## restrict them to cells that have a real path to an evacuation point.

@export_group("Population")
@export var member_count: int = 50
## Keep the population still until Start. This is the correct mode for a
## pre-populated fixture: agents exist before time zero but do not walk.
@export var freeze_until_start: bool = true
@export var start_evacuating: bool = true
@export var only_pathfindable_blocks: bool = true
## Reject spawn cells closer than this to another NPC or an earlier slot in the
## same populate batch. Without this, several agents can be created in one cell
## and the physics depenetration launches them upward.
@export var spawn_clearance: float = 1.5

@export_group("Scene")
@export var member_scene: PackedScene = preload("res://scenes/npcs/Member.tscn")


func _ready() -> void:
	add_to_group("random_populator")
	# New maps start from the Settings > Gameplay defaults. A save load
	# overrides these through RuntimeExports.apply_live().
	var defaults: Dictionary = RuntimeExports.get_default_section("populator")

	if defaults.is_empty():
		return

	if defaults.has("member_count"):
		member_count = maxi(1, int(defaults["member_count"]))
	if defaults.has("start_evacuating"):
		start_evacuating = bool(defaults["start_evacuating"])
	if defaults.has("only_pathfindable_blocks"):
		only_pathfindable_blocks = bool(defaults["only_pathfindable_blocks"])
	if defaults.has("spawn_clearance"):
		spawn_clearance = maxf(0.0, float(defaults["spawn_clearance"]))


func populate() -> Dictionary:
	var tree := get_tree()
	if tree == null:
		return {"spawned": 0, "reason": "No scene tree."}

	var grid := tree.get_first_node_in_group("grid_map") as NavGridMap
	if grid == null:
		return {"spawned": 0, "reason": "No grid map found."}

	if member_scene == null:
		return {"spawned": 0, "reason": "No member scene assigned."}

	if freeze_until_start:
		GlobalData.population_frozen = true

	var evac_positions: Array[Vector3] = []
	var use_pathfind_filter := only_pathfindable_blocks
	var warning := ""
	if only_pathfindable_blocks:
		for node in tree.get_nodes_in_group("EvacPoint"):
			var point := node as Node3D
			if point != null and is_instance_valid(point):
				evac_positions.append(point.global_position)

		if evac_positions.is_empty():
			# Sandbox maps often have no evacuation point yet. Falling back to
			# any walkable cell keeps Random Populate useful instead of failing.
			use_pathfind_filter = false
			warning = (
				"No evacuation point found; populated on any walkable cell."
			)

	var candidates: Array[Vector3i] = []
	for cell: Vector3i in grid.get_used_block_cells():
		if grid.is_nav_cell_valid(cell):
			candidates.append(cell)

	if candidates.is_empty():
		return {"spawned": 0, "reason": "No walkable navigation cells."}

	var parent: Node = tree.current_scene
	if parent == null:
		parent = tree.root

	var spawned: int = 0
	var attempts: int = 0
	var claimed: Array[Vector3] = []
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

		if use_pathfind_filter:
			var reachable: bool = false
			for evac_position: Vector3 in evac_positions:
				if grid.estimate_path_distance(spawn_position, evac_position) < INF:
					reachable = true
					break

			if not reachable:
				continue

		if not _is_spawn_position_clear(spawn_position, claimed):
			continue

		var member := member_scene.instantiate() as Node3D
		if member == null:
			continue

		parent.add_child(member)
		member.global_position = spawn_position

		if member.has_method("set_evacuation_mode"):
			member.set_evacuation_mode(start_evacuating)

		GlobalData.register_npc_spawned(member)

		var manager := tree.root.get_node_or_null("EvacuationManager")
		if manager and manager.has_method("register_npc"):
			manager.register_npc(member)

		spawned += 1
		alive += 1
		claimed.append(spawn_position)

	var reason: String = ""
	if spawned < member_count and attempts >= max_attempts:
		reason = "Could not find enough valid spawn cells."

	return {
		"spawned": spawned,
		"requested": member_count,
		"attempts": attempts,
		"reason": reason,
		"warning": warning,
	}


func _is_spawn_position_clear(
	position: Vector3,
	claimed: Array[Vector3]
) -> bool:
	var clearance_sq: float = spawn_clearance * spawn_clearance

	for other: Vector3 in claimed:
		var difference: Vector3 = other - position
		difference.y = 0.0

		if difference.length_squared() < clearance_sq:
			return false

	if _npc_within(position, spawn_clearance):
		return false

	return GlobalData.reserve_spawn_position(position, spawn_clearance)


## Physics query rather than the crowd hash: the hash can be up to 0.1 s stale
## and does not include agents instantiated earlier in this batch until the next
## physics frame.
func _npc_within(position: Vector3, radius: float) -> bool:
	var viewport := get_viewport()
	var world: World3D = null

	if viewport != null:
		world = viewport.find_world_3d()

	if world == null:
		return false

	var sphere := SphereShape3D.new()
	sphere.radius = maxf(radius, 0.05)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(
		Basis.IDENTITY,
		position + Vector3(0.0, 0.5, 0.0)
	)
	query.collision_mask = 1 << 1
	query.collide_with_bodies = true
	query.collide_with_areas = false

	return not world.direct_space_state.intersect_shape(query, 1).is_empty()
