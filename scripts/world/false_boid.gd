class_name FalseBoid
extends Node3D

## A promoted member of a FalseBoidFlock. It is a real node only while flying to
## a perch, perching, or leaving; once it has flown back into the particle cloud
## it fades out and frees itself, releasing its perch slot.
##
## Everything about its motion is boid-like: it carries a velocity, steers with
## bounded acceleration, separates from other birds and aligns with the ones
## that are flying nearby. It does not slide along a straight line or stop in
## mid-air. Promotion/demotion samples the flock's particle-density field so the
## bird appears from and vanishes into a dense part of the cloud.

enum State { FLYING_TO_PERCH, PERCHED, ALERT, FLEEING }

const BOID_TEXTURE := preload("res://textures/particles/Boid.png")
const FRAME_COUNT: int = 3
const BIRD_GROUP := &"false_boid_perched"

@export var sprite_pixel_size: float = 0.0625
@export_group("Boid Flight")
@export var flight_speed: float = 7.0
@export var flee_speed: float = 12.0
@export var steer_strength: float = 24.0
@export var separation_radius: float = 1.8
@export_range(0.0, 4.0, 0.01) var separation_weight: float = 1.0
@export var alignment_radius: float = 6.0
@export_range(0.0, 4.0, 0.01) var alignment_weight: float = 0.55
@export var cohesion_radius: float = 10.0
@export_range(0.0, 4.0, 0.01) var cohesion_weight: float = 0.35
@export_group("Perch Life")
@export var alert_duration: float = 0.25
@export var perch_dwell_min: float = 7.0
@export var perch_dwell_max: float = 18.0
@export_group("Cloud Transition")
## Promotion fade-in. The bird starts at the cloud point at a tiny scale so it
## materialises between particles.
@export var appear_duration: float = 0.8
@export var vanish_duration: float = 0.5
## Begin fading once this close to the sampled cloud point. Pure boid steering
## can orbit a point forever at the turn radius, and the fade is hidden by the
## surrounding birds anyway.
@export var vanish_distance: float = 4.5
@export var hideout_search_radius: float = 110.0
@export var max_leave_time: float = 14.0

var perch: Node3D = null
var slot_index: int = -1
var state: State = State.FLYING_TO_PERCH

var _flock: Node = null
var _sprite: Sprite3D = null
var _velocity: Vector3 = Vector3.ZERO
var _slot_position: Vector3 = Vector3.ZERO
var _approach_position: Vector3 = Vector3.ZERO
var _flight_stage: int = 0
var _player_group: StringName = &"Player"
var _flee_radius: float = 5.0
var _perch_time: float = 0.0
var _perch_dwell: float = 10.0
var _alert_time: float = 0.0
var _leave_time: float = 0.0
var _bob_phase: float = 0.0
var _frame_time: float = 0.0
var _facing: float = 0.0
var _sprite_base_y: float = 0.0
var _appear_elapsed: float = 0.0
var _vanish_elapsed: float = 0.0
var _hideout: Vector3 = Vector3.ZERO
var _hideout_timer: float = 0.0
var _flutter_timer: float = 0.0
var _flutter_time: float = 0.0
var _hop_timer: float = 0.0
var _hop_time: float = 0.0
var _look_timer: float = 0.0


func configure(
	flock: Node,
	perch_node: Node3D,
	slot: int,
	spawn_world_position: Vector3,
	slot_world_position: Vector3,
	flee_radius: float,
	player_group: StringName,
	flock_velocity: Vector3 = Vector3.ZERO
) -> void:
	_flock = flock
	perch = perch_node
	slot_index = slot
	_slot_position = slot_world_position
	_approach_position = slot_world_position + Vector3(
		randf_range(-2.5, 2.5),
		randf_range(2.0, 5.0),
		randf_range(-2.5, 2.5)
	)
	_flight_stage = 0
	_flee_radius = maxf(0.1, flee_radius)
	_player_group = player_group
	global_position = spawn_world_position
	_bob_phase = randf() * TAU
	_facing = randf() * TAU
	rotation.y = _facing
	_perch_time = 0.0
	_perch_dwell = randf_range(
		perch_dwell_min,
		maxf(perch_dwell_min, perch_dwell_max)
	)
	_appear_elapsed = 0.0
	_vanish_elapsed = 0.0
	_flutter_timer = randf_range(1.5, 5.0)
	_hop_timer = randf_range(2.0, 6.0)
	_look_timer = randf_range(2.0, 5.0)
	_velocity = flock_velocity

	if _velocity.length() < 0.5:
		_velocity = Vector3(
			randf_range(-1.0, 1.0),
			1.0,
			randf_range(-1.0, 1.0)
		).normalized() * flight_speed

	if _sprite != null:
		_sprite.scale = Vector3.ONE * 0.18
		_sprite.modulate.a = 0.0


func _ready() -> void:
	add_to_group(BIRD_GROUP)
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
			_process_leave(delta)

	_update_transition(delta)
	_update_sprite_facing()


# ---------------------------------------------------------------------------
# Flight
# ---------------------------------------------------------------------------

func _process_flying(delta: float) -> void:
	var target: Vector3 = _approach_position if _flight_stage == 0 else _slot_position
	var distance: float = global_position.distance_to(target)

	if distance <= 2.0:
		# Final settle. Pure steering can orbit a point forever when the turn
		# radius matches the distance, so the last couple of metres use a
		# direct approach. This is the landing, not the flight, so it reads as
		# the bird slowing down onto the branch rather than snapping.
		var step: float = maxf(3.0, flight_speed * 0.35) * delta
		var next: Vector3 = global_position.move_toward(target, step)
		_velocity = (next - global_position) / maxf(delta, 0.0001)
		global_position = next
		_face_velocity()
	else:
		_steer_towards(target, flight_speed, delta, 7.0)
		# Fade separation/alignment/cohesion out during the final approach.
		# Without this the flock circles the perch indefinitely, because
		# cohesion pulls each bird back towards the group as it tries to descend.
		_apply_bird_flock_forces(delta, clampf((distance - 2.0) / 7.0, 0.0, 1.0))
		_integrate(delta)

	_advance_frames(delta, 16.0)

	if _sprite != null:
		_sprite.position.y = _sprite_base_y

	if global_position.distance_to(target) > 0.1:
		return

	if _flight_stage == 0:
		_flight_stage = 1
		return

	global_position = _slot_position
	_velocity = Vector3.ZERO
	state = State.PERCHED
	_perch_time = 0.0
	_frame_time = 0.0

	if _sprite != null:
		_sprite.frame = 0
		_sprite.rotation_degrees.z = 0.0


func _process_perched(delta: float) -> void:
	_perch_time += delta
	_bob_phase += delta * 2.2

	if _sprite != null:
		_idle_animation(delta)

	var player := _find_player()

	if player != null and global_position.distance_to(player.global_position) <= _flee_radius:
		_begin_alert()
		return

	if _perch_time >= _perch_dwell:
		_begin_departure()


## Perched birds are not statues: they breathe, hop and occasionally flutter
## their wings, then leave on their own after a random dwell.
func _idle_animation(delta: float) -> void:
	var hop: float = 0.0
	_hop_timer -= delta

	if _hop_timer <= 0.0:
		_hop_timer = randf_range(2.0, 6.0)
		_hop_time = 0.28

	if _hop_time > 0.0:
		_hop_time = maxf(0.0, _hop_time - delta)
		hop = sin((1.0 - _hop_time / 0.28) * PI) * 0.18

	_flutter_timer -= delta

	if _flutter_timer <= 0.0:
		_flutter_timer = randf_range(2.5, 7.0)
		_flutter_time = randf_range(0.25, 0.6)

	if _flutter_time > 0.0:
		_flutter_time = maxf(0.0, _flutter_time - delta)
		_advance_frames(delta, 14.0)
	else:
		_sprite.frame = 0

	_sprite.position.y = _sprite_base_y + sin(_bob_phase) * 0.025 + hop

	# Look around while resting: small yaw changes feed the left/right sprite
	# facing selection so perched birds do not stare in one direction forever.
	_look_timer -= delta

	if _look_timer <= 0.0:
		_look_timer = randf_range(2.5, 6.5)
		_facing += randf_range(-1.8, 1.8)
		rotation.y = _facing


func _process_alert(delta: float) -> void:
	_alert_time += delta

	var player := _find_player()

	if player != null:
		var direction: Vector3 = player.global_position - global_position
		_facing = atan2(-direction.x, -direction.z)
		rotation.y = _facing

	if _alert_time >= alert_duration:
		_begin_departure(true)


func _process_leave(delta: float) -> void:
	_leave_time += delta
	_hideout_timer -= delta

	if _hideout_timer <= 0.0:
		_hideout_timer = 0.4
		_hideout = _find_hideout()

	var distance: float = _steer_towards(_hideout, flee_speed, delta, 12.0)
	_apply_bird_flock_forces(delta)
	_integrate(delta)
	_advance_frames(delta, 18.0)

	if _sprite != null:
		_sprite.rotation_degrees.z = sin(_leave_time * 16.0) * 8.0

	if distance <= vanish_distance or _leave_time >= max_leave_time * 0.6:
		_vanish_elapsed += delta
	elif _leave_time < max_leave_time:
		_vanish_elapsed = maxf(0.0, _vanish_elapsed - delta * 2.0)
	else:
		_vanish_elapsed += delta

	if _vanish_elapsed >= vanish_duration:
		queue_free()


func _steer_towards(
	target: Vector3,
	speed: float,
	delta: float,
	slow_radius: float
) -> float:
	var to_target: Vector3 = target - global_position
	var distance: float = to_target.length()

	if distance < 0.001:
		return distance

	var desired_speed: float = speed * clampf(
		distance / maxf(slow_radius, 0.001),
		0.2,
		1.0
	)
	var desired: Vector3 = (to_target / distance) * desired_speed
	_velocity += (desired - _velocity).limit_length(steer_strength) * delta
	return distance


## Separation from all nearby birds plus alignment/cohesion with the ones that
## are actually in flight. `flock_scale` lets the landing approach ignore the
## flock so the bird can actually settle on its slot.
func _apply_bird_flock_forces(delta: float, flock_scale: float = 1.0) -> void:
	if flock_scale <= 0.001:
		return

	var birds := get_tree().get_nodes_in_group(BIRD_GROUP)

	if birds.size() < 2:
		return

	var separation := Vector3.ZERO
	var alignment := Vector3.ZERO
	var cohesion := Vector3.ZERO
	var separation_count: int = 0
	var alignment_count: int = 0
	var cohesion_count: int = 0

	for node: Node in birds:
		if node == self or not (node is Node3D):
			continue

		var other_position: Vector3 = (node as Node3D).global_position
		var offset: Vector3 = global_position - other_position
		var distance: float = offset.length()

		if distance < separation_radius:
			if distance < 0.01:
				offset = Vector3.RIGHT
				distance = 0.01
			separation += (offset / distance) * (1.0 - distance / separation_radius)
			separation_count += 1

		if not (node is FalseBoid) or not (node as FalseBoid).is_flying():
			continue

		if distance < alignment_radius:
			alignment += (node as FalseBoid).get_velocity()
			alignment_count += 1

		if distance < cohesion_radius:
			cohesion += other_position
			cohesion_count += 1

	var acceleration := Vector3.ZERO

	if separation_count > 0:
		acceleration += separation.normalized() * flight_speed * separation_weight

	if alignment_count > 0:
		var average: Vector3 = alignment / float(alignment_count)

		if average.length_squared() > 0.01:
			acceleration += (
				average.normalized() * flight_speed - _velocity
			) * alignment_weight

	if cohesion_count > 0:
		var center: Vector3 = cohesion / float(cohesion_count)
		var towards: Vector3 = center - global_position

		if towards.length_squared() > 0.01:
			acceleration += towards.normalized() * flight_speed * cohesion_weight

	if acceleration.length_squared() > 0.001:
		_velocity += (acceleration * flock_scale).limit_length(steer_strength) * delta


func _integrate(delta: float) -> void:
	var max_speed: float = maxf(flee_speed, flight_speed * 1.5)
	var speed: float = _velocity.length()

	if speed > max_speed:
		_velocity = _velocity * (max_speed / speed)

	global_position += _velocity * delta
	_face_velocity()


## Godot's forward axis is -Z, so yaw = atan2(-vx, -vz).
func _face_velocity() -> void:
	if _velocity.length_squared() < 0.0001:
		return

	_facing = atan2(-_velocity.x, -_velocity.z)
	rotation.y = _facing


# ---------------------------------------------------------------------------
# Perch / departure
# ---------------------------------------------------------------------------

func _begin_alert() -> void:
	if state != State.PERCHED:
		return

	state = State.ALERT
	_alert_time = 0.0


func startle() -> void:
	if state == State.FLEEING:
		return

	if state == State.FLYING_TO_PERCH:
		_begin_departure()
		return

	_begin_alert()


func _begin_departure(startled: bool = false) -> void:
	state = State.FLEEING
	_leave_time = 0.0
	_vanish_elapsed = 0.0
	_hideout_timer = 0.0
	_hideout = _find_hideout()

	if _sprite != null:
		_sprite.position.y = _sprite_base_y

	if _velocity.length() < 2.0:
		var away := Vector3(
			randf_range(-1.0, 1.0),
			0.8,
			randf_range(-1.0, 1.0)
		).normalized()

		# A startled bird bolted upwards before joining the cloud; a bird that
		# simply finished resting eases into it.
		_velocity = away * flee_speed * (0.65 if startled else 0.5)


func _find_hideout() -> Vector3:
	if _flock != null and is_instance_valid(_flock) and _flock.has_method("find_cloud_hideout"):
		return _flock.find_cloud_hideout(global_position, hideout_search_radius)

	return global_position + Vector3(0.0, 8.0, 0.0)


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

func _update_transition(delta: float) -> void:
	if _sprite == null:
		return

	_appear_elapsed = minf(_appear_elapsed + delta, appear_duration)
	var appear: float = smoothstep(
		0.0,
		1.0,
		clampf(_appear_elapsed / maxf(appear_duration, 0.01), 0.0, 1.0)
	)
	var vanish: float = clampf(
		_vanish_elapsed / maxf(vanish_duration, 0.01),
		0.0,
		1.0
	)
	var sprite_scale: float = lerpf(0.18, 1.0, appear) * (1.0 - vanish)
	_sprite.scale = Vector3.ONE * maxf(sprite_scale, 0.001)
	_sprite.modulate.a = appear * (1.0 - vanish * 0.95)


## Cosy Critters-style relative facing: a side-view billboard cannot yaw in 3D,
## so choose the left/right texture according to which way the bird is moving
## across the camera's view. This is what makes the flock read as directional.
func _update_sprite_facing() -> void:
	if _sprite == null:
		return

	var direction: Vector3

	if is_flying() and _velocity.length_squared() > 0.0001:
		direction = _velocity
	else:
		direction = Vector3(-sin(_facing), 0.0, -cos(_facing))

	direction.y = 0.0

	if direction.length_squared() < 0.0001:
		return

	var camera := get_viewport().get_camera_3d()

	if camera == null:
		return

	var side: float = direction.normalized().dot(camera.global_transform.basis.x)

	# Small deadband stops the sprite flickering when moving straight towards or
	# away from the camera.
	if absf(side) > 0.06:
		_sprite.flip_h = side > 0.0


func _advance_frames(delta: float, fps: float) -> void:
	if _sprite == null:
		return

	_frame_time += delta

	if _frame_time < 1.0 / fps:
		return

	_frame_time = 0.0
	_sprite.frame = (_sprite.frame + 1) % FRAME_COUNT


# ---------------------------------------------------------------------------
# Public helpers / queries
# ---------------------------------------------------------------------------

func is_flying() -> bool:
	return state == State.FLYING_TO_PERCH or state == State.FLEEING


func get_velocity() -> Vector3:
	return _velocity


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
