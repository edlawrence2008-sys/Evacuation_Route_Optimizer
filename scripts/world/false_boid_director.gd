class_name FalseBoidDirector
extends Node3D

## Owns the map-wide false-boid state:
##   - one FalseBoidFlock leader per placed emitter, capped at MAX_LEADERS;
##   - a large particle collision box fixed at world y = 0 that follows the
##     player, so birds cannot sink into or stick to the ground.
##
## Emitters only emit particles. Leaders own the attractors, perch behaviour and
## chunk exploration. Keeping this in one small director lets the leader count
## track the emitter count without each emitter owning lifecycle logic.

const LEADER_SCRIPT := preload("res://scripts/world/false_boid_flock.gd")
const MAX_LEADERS: int = 10
const EMITTER_GROUP := &"false_boid_emitters"
const PLAYER_GROUP := &"Player"

@export var ground_collision_size: Vector3 = Vector3(220.0, 2.0, 220.0)
@export var crowd_radius: float = 12.0
@export_range(1, 10, 1) var crowd_threshold: int = 3
@export var crowd_repel_duration: float = 1.5

var _leaders: Array[Node] = []
var _sync_timer: float = 0.0
var _ground_box: GPUParticlesCollisionBox3D = null


func _ready() -> void:
	add_to_group(&"false_boid_director")
	_build_ground_box()
	set_process(true)


func _process(delta: float) -> void:
	_update_ground_box()
	_sync_timer += delta

	if _sync_timer < 0.5:
		return

	_sync_timer = 0.0
	_sync_leaders()
	_update_crowding()


func _build_ground_box() -> void:
	_ground_box = GPUParticlesCollisionBox3D.new()
	_ground_box.name = "GroundCollision"
	_ground_box.size = ground_collision_size
	add_child(_ground_box)


func _update_ground_box() -> void:
	if _ground_box == null:
		return

	var player := get_tree().get_first_node_in_group(PLAYER_GROUP) as Node3D

	if player == null:
		return

	_ground_box.global_position = Vector3(player.global_position.x, 0.0, player.global_position.z)


func _sync_leaders() -> void:
	var emitters := get_tree().get_nodes_in_group(EMITTER_GROUP)
	var desired: int = mini(emitters.size(), MAX_LEADERS)

	while _leaders.size() > desired:
		var extra: Node = _leaders.pop_back()
		extra.queue_free()

	while _leaders.size() < desired:
		var index: int = _leaders.size()
		var emitter: Node3D = emitters[index] as Node3D if index < emitters.size() else null
		var leader: Node3D = LEADER_SCRIPT.new()
		leader.name = "FalseBoidLeader%d" % index

		if emitter != null:
			leader.position = to_local(emitter.global_position)

		add_child(leader)
		_leaders.append(leader)


func _update_crowding() -> void:
	var leaders := _leaders
	var count: int = leaders.size()

	if count < crowd_threshold:
		return

	for index: int in range(count):
		var leader: Node = leaders[index]

		if not is_instance_valid(leader):
			continue

		var near: int = 0
		var position: Vector3 = (
			leader.get_leader_position()
			if leader.has_method("get_leader_position")
			else (leader as Node3D).global_position
		)

		for other_index: int in range(count):
			if other_index == index:
				continue

			var other: Node = leaders[other_index]

			if not is_instance_valid(other):
				continue

			var other_position: Vector3 = (
				other.get_leader_position()
				if other.has_method("get_leader_position")
				else (other as Node3D).global_position
			)

			if other_position.distance_to(position) <= crowd_radius:
				near += 1

		if near >= crowd_threshold - 1 and leader.has_method("repel_for"):
			leader.repel_for(crowd_repel_duration)


func get_leader_count() -> int:
	return _leaders.size()


func get_leaders() -> Array[Node]:
	return _leaders


func get_director_state() -> Dictionary:
	return {
		"emitters": get_tree().get_nodes_in_group(EMITTER_GROUP).size(),
		"leaders": _leaders.size(),
		"max_leaders": MAX_LEADERS,
		"ground_box": _ground_box.global_position if _ground_box != null else Vector3.ZERO,
	}
