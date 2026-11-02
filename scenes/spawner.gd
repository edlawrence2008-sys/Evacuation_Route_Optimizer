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

@onready var spawn_area: Area3D = $Area3D

var _spawn_timer: float = 0.0
var _spawned_count: int = 0 # Used only if spawn_section is empty
var _quota_registered: bool = false


func _ready() -> void:
	add_to_group("spawners")
	spawn_area.monitoring = true
	
	GlobalData.spawning_reset.connect(_on_spawning_reset)
	_register_quota()


func _exit_tree() -> void:
	_unregister_quota()


func _process(delta: float) -> void:
	if spawn_interval <= 0.0 or not _quota_remaining():
		return

	_spawn_timer += delta
	if _spawn_timer >= spawn_interval:
		# Use a loop in case delta accumulated enough time for multiple spawns
		var quota_func := _quota_remaining
		while _spawn_timer >= spawn_interval and quota_func.call():
			_spawn_timer -= spawn_interval
			_try_spawn()


func _quota_remaining() -> bool:
	if not GlobalData.is_spawning_enabled:
		return false

	if not GlobalData.is_global_quota_available():
		return false

	if spawn_quota < 0:
		return true

	if spawn_section.is_empty():
		return _spawned_count < spawn_quota
	
	var quota: int = GlobalData.get_section_quota(spawn_section)
	return quota < 0 or GlobalData.get_section_spawn_count(spawn_section) < quota


func _try_spawn() -> void:
	if npc_scene == null:
		push_warning("NPCSpawner: no npc_scene assigned.")
		return

	if _area_has_npc() or _global_npc_count() >= GlobalData.global_unit_cap:
		return  

	var npc := npc_scene.instantiate() as Node3D
	_get_spawn_container().add_child(npc)
	
	# Optimized polar-to-cartesian vector calculation
	var rand_vec := Vector2.from_angle(randf() * TAU) * randf_range(0.0, spawn_radius)
	npc.global_position = global_position + Vector3(rand_vec.x, 0.0, rand_vec.y)
	
	if spawn_section.is_empty():
		_spawned_count += 1
	else:
		GlobalData.increment_section_spawn_count(spawn_section)

	GlobalData.register_npc_spawned()

	var evacuation_manager := get_node_or_null("/root/EvacuationManager")
	if evacuation_manager:
		evacuation_manager.register_npc(npc)


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
