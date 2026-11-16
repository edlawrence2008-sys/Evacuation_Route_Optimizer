class_name NPCSpawner
extends Node3D

const GROUP_MEMBERS := &"Members"

@export var npc_scene: PackedScene
@export var spawn_container_path: NodePath ## Where spawned NPCs are added; defaults to this spawner's parent

@export_group("Spawn Settings")
@export var spawn_quota: int = 20:
	set(value):
		spawn_quota = value
		_update_registered_quota()
@export var spawn_interval: float = 1.0  
@export var spawn_section: String = ""   
@export var spawn_radius: float = 1.5
## How many agents one spawner may emit in a single interval. Batching avoids
## re-running the area/cap checks for every individual NPC.
@export var spawn_batch_size: int = 6
## Prefer random walkable cells within this radius instead of a tight disc.
@export var spawn_scatter_radius: float = 5.0
## Reject spawn candidates closer than this to another NPC or batch slot.
@export var spawn_clearance: float = 1.5

@onready var spawn_area: Area3D = $Area3D

var _spawn_timer: float = 0.0
var _spawned_count: int = 0 # Used only if spawn_section is empty
var _quota_registered: bool = false
var _grid: NavGridMap = null
var _evacuation_manager: Node = null


func _ready() -> void:
	add_to_group("spawners")
	spawn_area.monitoring = true
	_grid = get_tree().get_first_node_in_group("grid_map") as NavGridMap
	_evacuation_manager = get_node_or_null("/root/EvacuationManager")

	GlobalData.spawning_reset.connect(_on_spawning_reset)
	_register_quota()


func _exit_tree() -> void:
	_unregister_quota()


func _process(delta: float) -> void:
	if spawn_interval <= 0.0:
		return

	_spawn_timer += delta
	if _spawn_timer < spawn_interval:
		return

	# One batch per frame. This avoids a long catch-up loop after a hitch and
	# amortizes the area/cap checks across several agents.
	_spawn_timer = fmod(_spawn_timer, spawn_interval)
	_spawn_batch()


func _quota_remaining_count() -> int:
	if npc_scene == null or not GlobalData.is_spawning_enabled:
		return 0

	if GlobalData.is_spawning_paused:
		return 0

	if not GlobalData.is_global_quota_available():
		return 0

	var alive: int = _global_npc_count()
	var by_cap: int = maxi(0, GlobalData.global_unit_cap - alive)
	var by_quota: int = 1 << 30

	if spawn_quota >= 0:
		if spawn_section.is_empty():
			by_quota = spawn_quota - _spawned_count
		else:
			var section_quota: int = GlobalData.get_section_quota(spawn_section)
			if section_quota >= 0:
				by_quota = section_quota - GlobalData.get_section_spawn_count(spawn_section)

	if GlobalData.global_spawn_quota >= 0:
		by_quota = mini(
			by_quota,
			GlobalData.global_spawn_quota - GlobalData.npcs_spawned
		)

	return maxi(0, mini(by_cap, by_quota))


func _spawn_batch() -> void:
	if npc_scene == null:
		push_warning("NPCSpawner: no npc_scene assigned.")
		return

	if _area_has_npc():
		return

	var remaining: int = _quota_remaining_count()

	if remaining <= 0:
		return

	var count: int = mini(maxi(spawn_batch_size, 1), remaining)
	var claimed: Array[Vector3] = []

	for _index in count:
		var spawn_pos: Vector3 = _find_spawn_position(claimed)

		if not spawn_pos.is_finite():
			continue

		claimed.append(spawn_pos)
		_spawn_one(spawn_pos)


func _spawn_one(spawn_pos: Vector3) -> void:
	var npc := npc_scene.instantiate() as Node3D
	var container := _get_spawn_container()

	# Place the body before it enters the tree. Adding at the origin first makes
	# the physics server see every new agent at the world origin for a tick, so
	# an exit or trigger volume near (0, 0, 0) fires a false entry for it.
	if container is Node3D:
		npc.position = (container as Node3D).to_local(spawn_pos)
	else:
		npc.position = spawn_pos

	container.add_child(npc)

	if spawn_section.is_empty():
		_spawned_count += 1
	else:
		GlobalData.increment_section_spawn_count(spawn_section)

	GlobalData.register_npc_spawned()

	if _evacuation_manager:
		_evacuation_manager.register_npc(npc)


func _find_spawn_position(claimed: Array[Vector3]) -> Vector3:
	var min_radius: float = minf(spawn_radius, spawn_scatter_radius)

	for _attempt in 12:
		var candidate: Vector3

		if _grid != null:
			var angle: float = randf() * TAU
			var radius: float = randf_range(
				min_radius,
				spawn_scatter_radius
			)
			var cell: Vector3i = _grid.resolve_nav_cell(
				global_position + Vector3(
					cos(angle) * radius,
					0.0,
					sin(angle) * radius
				)
			)

			if cell == NavGridMap.NO_CELL:
				continue

			candidate = _grid.to_global(
				_grid.map_to_local(cell)
				+ Vector3(0.0, _grid.cell_size.y * 1.5, 0.0)
			)
		else:
			var rand_vec := Vector2.from_angle(randf() * TAU) * randf_range(
				0.0,
				spawn_radius
			)
			candidate = global_position + Vector3(
				rand_vec.x,
				0.0,
				rand_vec.y
			)

		if _is_spawn_position_clear(candidate, claimed):
			return candidate

	return Vector3(INF, INF, INF)


func _is_spawn_position_clear(
	candidate: Vector3,
	claimed: Array[Vector3]
) -> bool:
	var clearance_sq: float = spawn_clearance * spawn_clearance

	for claimed_pos: Vector3 in claimed:
		var difference: Vector3 = claimed_pos - candidate
		difference.y = 0.0

		if difference.length_squared() < clearance_sq:
			return false

	if _npc_within(candidate, spawn_clearance):
		return false

	return GlobalData.reserve_spawn_position(candidate, spawn_clearance)


## Physics query rather than the crowd hash: the hash can be up to 0.1 s stale
## and misses bodies that spawned in the current batch.
func _npc_within(query_position: Vector3, radius: float) -> bool:
	var world := get_world_3d()
	if world == null:
		return false

	var sphere := SphereShape3D.new()
	sphere.radius = maxf(radius, 0.05)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(
		Basis.IDENTITY,
		query_position + Vector3(0.0, 0.5, 0.0)
	)
	query.collision_mask = 1 << 1
	query.collide_with_bodies = true
	query.collide_with_areas = false

	return not world.direct_space_state.intersect_shape(query, 1).is_empty()


func _area_has_npc() -> bool:
	return spawn_area.get_overlapping_bodies().any(
		func(body: Node3D) -> bool: return body.is_in_group(GROUP_MEMBERS)
	)


func _global_npc_count() -> int:
	return get_tree().get_node_count_in_group(GROUP_MEMBERS)


func _get_spawn_container() -> Node:
	if not spawn_container_path.is_empty():
		var n := get_node_or_null(spawn_container_path)
		if n:
			return n
	return get_parent() if get_parent() else get_tree().current_scene


func _register_quota() -> void:
	if _quota_registered:
		return

	if spawn_section.is_empty():
		GlobalData.register_independent_spawner(spawn_quota, self)
	else:
		GlobalData.register_section(spawn_section, spawn_quota, self)

	_quota_registered = true


func _unregister_quota() -> void:
	if not _quota_registered:
		return

	if spawn_section.is_empty():
		GlobalData.unregister_independent_spawner(self)
	else:
		GlobalData.unregister_section(spawn_section, self)

	_quota_registered = false


func _update_registered_quota() -> void:
	if not _quota_registered:
		return

	if spawn_section.is_empty():
		GlobalData.update_independent_spawner_quota(self, spawn_quota)
	else:
		GlobalData.update_section_quota(spawn_section, spawn_quota)


func _on_spawning_reset() -> void:
	_spawned_count = 0
	_spawn_timer = 0.0
