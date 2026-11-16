class_name FalseBoid
extends Node3D

## A promoted member of a FalseBoidFlock. It is a real node only while perched
## or fleeing; once it has flown away it frees itself and releases its perch
## slot. This is the "demote" half of the particle/NPC hybrid and avoids the
## old problem of particles getting stuck to the ground.

enum State { FLYING_TO_PERCH, PERCHED, ALERT, FLEEING }

const BOID_TEXTURE := preload("res://textures/particles/Boid.png")
const FRAME_COUNT: int = 3

@export var sprite_pixel_size: float = 0.0625
@export var flight_speed: float = 4.0
@export var flee_speed: float = 7.0
@export var flee_duration: float = 1.6
@export var alert_duration: float = 0.25

var perch: Node3D = null
var slot_index: int = -1
var state: State = State.FLYING_TO_PERCH

var _flock: Node = null
var _sprite: Sprite3D = null
var _slot_position: Vector3 = Vector3.ZERO
var _approach_position: Vector3 = Vector3.ZERO
var _flight_stage: int = 0
var _player_group: StringName = &"Player"
var _flee_radius: float = 5.0
var _flee_time: float = 0.0
var _alert_time: float = 0.0
var _bob_phase: float = 0.0
var _frame_time: float = 0.0
var _facing: float = 0.0
var _sprite_base_y: float = 0.0


func configure(
	flock: Node,
	perch_node: Node3D,
	slot: int,
	spawn_world_position: Vector3,
	slot_world_position: Vector3,
	flee_radius: float,
	player_group: StringName
) -> void:
	_flock = flock
	perch = perch_node
	slot_index = slot
	_slot_position = slot_world_position
	_approach_position = slot_world_position + Vector3(
		randf_range(-3.0, 3.0),
		randf_range(1.5, 4.0),
		randf_range(-3.0, 3.0)
	)
	_flight_stage = 0
	_flee_radius = maxf(0.1, flee_radius)
	_player_group = player_group
	global_position = spawn_world_position
	_bob_phase = randf() * TAU
	_facing = randf() * TAU
	rotation.y = _facing


func _ready() -> void:
	add_to_group(&"false_boid_perched")
	_build_sprite()
	rotation.y = _facing
	set_process(true)


func _build_sprite() -> void:
	_sprite = Sprite3D.new()
	_sprite.name = "Sprite"
	_sprite.texture = BOID_TEXTURE
	_sprite.hframes = FRAME_COUNT
	_sprite.frame = 0
	_sprite.pixel_size = sprite_pixel_size
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.shaded = true
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sprite_base_y = sprite_pixel_size * float(BOID_TEXTURE.get_height()) * 0.5
	_sprite.position.y = _sprite_base_y
	add_child(_sprite)


func _process(delta: float) -> void:
	match state:
		State.FLYING_TO_PERCH:
			_process_flying(delta)
		State.PERCHED:
			_process_perched(delta)
		State.ALERT:
			_process_alert(delta)
		State.FLEEING:
			_process_flee(delta)


func _process_flying(delta: float) -> void:
	var target: Vector3 = _approach_position if _flight_stage == 0 else _slot_position
	global_position = global_position.move_toward(
		target,
		flight_speed * delta
	)
	_advance_frames(delta, 8.0)

	if _sprite != null:
		_sprite.position.y = _sprite_base_y

	if global_position.distance_to(target) > 0.15:
		return

	if _flight_stage == 0:
		_flight_stage = 1
		return

	global_position = _slot_position
	state = State.PERCHED
	_frame_time = 0.0

	if _sprite != null:
		_sprite.frame = 0
		_sprite.rotation_degrees.z = 0.0


func _process_perched(delta: float) -> void:
	_bob_phase += delta * 2.2

	if _sprite != null:
		_sprite.position.y = _sprite_base_y + sin(_bob_phase) * 0.025
		_sprite.frame = 0

	var player := _find_player()

	if player != null and global_position.distance_to(player.global_position) <= _flee_radius:
		_begin_alert()


func _process_alert(delta: float) -> void:
	_alert_time += delta

	var player := _find_player()

	if player != null:
		_facing = atan2(
			player.global_position.x - global_position.x,
			player.global_position.z - global_position.z
		)
		rotation.y = _facing

	if _alert_time >= alert_duration:
		_begin_flee(player)


func _process_flee(delta: float) -> void:
	_flee_time += delta

	if _flock != null and is_instance_valid(_flock) and _flock.has_method("get_leader_position"):
		var toward_flock: Vector3 = _flock.get_leader_position() - global_position

		if toward_flock.length_squared() > 0.01:
			_flee_direction = (
				toward_flock.normalized() + Vector3.UP * 0.35
			).normalized()

	position += _flee_direction * flee_speed * delta
	_advance_frames(delta, 12.0)

	if _sprite != null:
		_sprite.rotation_degrees.z = sin(_flee_time * 18.0) * 12.0

	if _flee_time >= flee_duration:
		queue_free()


func _begin_alert() -> void:
	if state != State.PERCHED:
		return

	state = State.ALERT
	_alert_time = 0.0
	_flee_time = 0.0


func startle() -> void:
	if state == State.FLEEING:
		return

	if state == State.FLYING_TO_PERCH:
		_begin_flee(_find_player())
		return

	_begin_alert()


var _flee_direction: Vector3 = Vector3.UP


func _begin_flee(player: Node3D) -> void:
	state = State.FLEEING
	_flee_time = 0.0

	var target := global_position + Vector3.FORWARD

	if _flock != null and is_instance_valid(_flock) and _flock.has_method("get_leader_position"):
		target = _flock.get_leader_position()

	var toward_flock := target - global_position

	if toward_flock.length_squared() < 0.01:
		toward_flock = Vector3(
			randf_range(-1.0, 1.0),
			1.0,
			randf_range(-1.0, 1.0)
		)

	# Fly back into the flock rather than directly away from the player: the
	# particle cloud masks the departing bird.
	_flee_direction = (toward_flock.normalized() + Vector3.UP * 0.35).normalized()


func _advance_frames(delta: float, fps: float) -> void:
	if _sprite == null:
		return

	_frame_time += delta

	if _frame_time < 1.0 / fps:
		return

	_frame_time = 0.0
	_sprite.frame = (_sprite.frame + 1) % FRAME_COUNT


func _find_player() -> Node3D:
	var players := get_tree().get_nodes_in_group(_player_group)

	if players.is_empty():
		return null

	return players[0] as Node3D


func _exit_tree() -> void:
	if perch != null and is_instance_valid(perch):
		perch.release_slot(slot_index)

	if _flock != null and is_instance_valid(_flock):
		_flock.notify_bird_gone(self)
