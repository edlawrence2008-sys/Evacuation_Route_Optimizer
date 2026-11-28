extends CharacterBody3D
## Animated player controller + parkour mechanics:
## slide, dash, wallrun, walljump, coyote time, jump buffering, air jumps,
## bunny hop (speed accumulation) and fly mode.
##
## NOTE: this rig's forward direction is local +Z and its "right" is local -X
## (that's what your original `Vector3(-input_dir.x, 0, -input_dir.y)` implies).

enum PlayerState { NORMAL, SLIDE, DASH, WALLRUN, FLY }
var state: PlayerState = PlayerState.NORMAL

@onready var head = $head
@onready var collision_shape = $CollisionShape3D
@onready var anim_player = $AnimationMan/AnimationPlayer
@onready var movement_dust = $"../PhysicsMan/Rig/Skeleton3D/PhysicalBoneSimulator3D/Physical Bone DEF-foot_R/MovementDust"
@onready var movement_dust_2 = $"../PhysicsMan/Rig/Skeleton3D/PhysicalBoneSimulator3D/Physical Bone DEF-foot_R/MovementDust"

const WALK_SPEED = 2.0
const SPRINT_SPEED = 8.0
const CROUCH_SPEED = 2.5
const SENSITIVITY = 0.004
const ACCELERATION = 10.0
const FRICTION = 10.0

# ----------------------------------------------------------------------------
# Exports
# ----------------------------------------------------------------------------
@export_group("Input actions")
@export var jump_action: StringName = &"ui_accept"
@export var crouch_action: StringName = &"ui_crouch"
@export var sprint_action: StringName = &"ui_sprint"
@export var slide_action: StringName = &"ui_crouch" # shares the key with crouch
@export var dash_action: StringName = &"play_char_dash_action" # auto-registered (Ctrl) if missing
@export var fly_action: StringName = &"play_char_fly_action" # auto-registered (F) if missing

@export_group("Body")
@export var standing_height: float = 2.0
@export var crouch_height: float = 0.5
@export var slide_height: float = 1.0
@export_range(0.0, 1.0) var air_control: float = 0.4 # 1.0 = same as ground

@export_group("Jump")
@export var jump_height: float = 1.2
@export var jump_time_to_peak: float = 0.35
@export var jump_time_to_fall: float = 0.3
@export var jump_cooldown: float = 0.25
@export var nb_jumps_in_air_allowed: int = 1
@export var coyote_time: float = 0.15
@export var jump_buffer_time: float = 0.15
@export var auto_bunny_hop: bool = false
@export var hit_ground_cooldown: float = 0.1 # window after landing in which a jump counts as a bunny hop
@export var bunny_hop_bonus: float = 2.0 # speed added per chained bunny hop
@export var max_speed_bonus: float = 10.0
@export var speed_bonus_decay: float = 6.0 # bonus lost per second on the ground

@export_group("Slide")
@export var slide_speed: float = 10.0
@export var slide_min_speed: float = 5.5 # need at least this speed to start a slide
@export var slide_time: float = 1.2
@export var time_bef_can_slide_again: float = 1.5
@export_range(0.0, 90.0, 0.1) var max_slope_angle: float = 75.0
@export_range(0.0, 0.1, 0.001) var uphill_tolerance: float = 0.05
@export var amount_velocity_lost_per_sec: float = 4.0
@export var slope_sliding_speed_incre: float = 3.0 # speed gained per second sliding downhill
@export var continious_slide: bool = true # if false, key must be held
@export var slide_anim: StringName = &"Crouch_Idle"

@export_group("Dash")
@export var dash_speed: float = 60.0
@export var dash_time: float = 0.12
@export var nb_dashs_allowed: int = 3
@export var time_bef_can_dash_again: float = 0.8
@export var time_bef_reload_dash: float = 3.0
@export var dash_anim: StringName = &"Sprint"

@export_group("Wallrun / Walljump")
@export var wallrun_speed: float = 9.0
@export var wallrun_accel: float = 6.0
@export_range(0.0, 1.0, 0.001) var wallrun_fall_gravity_multiplier: float = 0.05
@export var wallrun_time: float = 3.5
@export var infinite_wallrun_time: bool = false
@export var time_bef_can_wallrun_again: float = 0.2
@export var wall_check_distance: float = 0.8
@export var wall_check_height: float = 1.0 # height above the origin where side rays start
@export var min_wallrun_height: float = 0.8 # must be this far above the floor to start
@export var wall_stick_speed: float = 2.0
@export var walljump_push_force: float = 8.0
@export var walljump_y_velocity: float = 6.0
@export var walljump_lock_in_air_movement_time: float = 0.15
@export var wallrun_anim: StringName = &"Sprint"

@export_group("Fly")
@export var fly_speed: float = 10.0
@export var fly_accel: float = 15.0
@export var fly_deccel: float = 15.0
@export var fly_boost_multiplier: float = 3.0

# ----------------------------------------------------------------------------
# Runtime state
# ----------------------------------------------------------------------------
@onready var jump_velocity: float = (2.0 * jump_height) / jump_time_to_peak
@onready var jump_gravity: float = (-2.0 * jump_height) / (jump_time_to_peak * jump_time_to_peak)
@onready var fall_gravity: float = (-2.0 * jump_height) / (jump_time_to_fall * jump_time_to_fall)

var was_on_floor: bool = true
var just_landed: bool = false

# per-frame input
var input_dir: Vector2
var direction: Vector3
var is_sprinting: bool
var is_crouching: bool
var is_moving_backward: bool
var is_sprint_anim: bool
var emit_dust: bool
var target_h: float

# jump
var jump_cooldown_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var coyote_timer: float = 0.0
var ground_grace_timer: float = 0.0
var air_jumps_left: int = 0
var speed_bonus: float = 0.0

# slide
var slide_dir: Vector3
var slide_cur_speed: float
var slide_time_left: float
var slide_cooldown: float = 0.0

# dash
var dash_dir: Vector3
var dash_time_left: float
var dash_cooldown: float = 0.0
var dash_charges: int
var dash_reload_timer: float = 0.0
var velocity_pre_dash: Vector3

# wallrun
var wall_normal: Vector3
var wall_dir: Vector3
var wallrun_time_left: float
var wallrun_cooldown: float = 0.0
var last_wall_normal: Vector3 = Vector3.ZERO
var lock_air_timer: float = 0.0


# ----------------------------------------------------------------------------
# Setup / input
# ----------------------------------------------------------------------------
func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	dash_charges = nb_dashs_allowed
	air_jumps_left = nb_jumps_in_air_allowed
	_ensure_action(dash_action, KEY_CTRL)
	_ensure_action(fly_action, KEY_F)


func _ensure_action(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	push_warning("'%s' missing in InputMap, adding it at runtime with key %s" % [action, OS.get_keycode_string(keycode)])
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)


func _unhandled_input(event):
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * SENSITIVITY)


# ----------------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------------
func _physics_process(delta):
	_update_ground_state()
	_tick_timers(delta)
	_read_input()

	if state != PlayerState.FLY:
		if Input.is_action_just_pressed(jump_action) or (auto_bunny_hop and Input.is_action_pressed(jump_action)):
			jump_buffer_timer = jump_buffer_time

	if Input.is_action_just_pressed(fly_action):
		_toggle_fly()
	if state != PlayerState.FLY and state != PlayerState.DASH and Input.is_action_just_pressed(dash_action):
		_try_dash()

	emit_dust = false
	is_sprint_anim = false
	target_h = _standing_target()

	match state:
		PlayerState.NORMAL: _state_normal(delta)
		PlayerState.SLIDE: _state_slide(delta)
		PlayerState.DASH: _state_dash(delta)
		PlayerState.WALLRUN: _state_wallrun(delta)
		PlayerState.FLY: _state_fly(delta)

	_update_hitbox(delta)

	if movement_dust:
		movement_dust.emitting = emit_dust
	if movement_dust_2:
		movement_dust_2.emitting = emit_dust

	move_and_slide()


func _update_ground_state() -> void:
	var on_floor := is_on_floor()
	just_landed = on_floor and not was_on_floor
	was_on_floor = on_floor

	if on_floor:
		coyote_timer = coyote_time
		air_jumps_left = nb_jumps_in_air_allowed
		last_wall_normal = Vector3.ZERO
		if just_landed:
			ground_grace_timer = hit_ground_cooldown


func _tick_timers(delta: float) -> void:
	jump_cooldown_timer = maxf(jump_cooldown_timer - delta, 0.0)
	jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)
	coyote_timer = maxf(coyote_timer - delta, 0.0)
	ground_grace_timer = maxf(ground_grace_timer - delta, 0.0)
	slide_cooldown = maxf(slide_cooldown - delta, 0.0)
	dash_cooldown = maxf(dash_cooldown - delta, 0.0)
	wallrun_cooldown = maxf(wallrun_cooldown - delta, 0.0)
	lock_air_timer = maxf(lock_air_timer - delta, 0.0)

	# dash charges reload one at a time
	if dash_charges < nb_dashs_allowed:
		dash_reload_timer -= delta
		if dash_reload_timer <= 0.0:
			dash_charges += 1
			dash_reload_timer = time_bef_reload_dash

	# accumulated speed (bunny hop / slide / wallrun) bleeds off on the ground
	if state == PlayerState.NORMAL and is_on_floor() and ground_grace_timer <= 0.0:
		speed_bonus = move_toward(speed_bonus, 0.0, speed_bonus_decay * delta)


func _read_input() -> void:
	input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	direction = (transform.basis * Vector3(-input_dir.x, 0, -input_dir.y)).normalized()
	is_sprinting = Input.is_action_pressed(sprint_action)
	is_crouching = Input.is_action_pressed(crouch_action)
	is_moving_backward = input_dir.y > 0 and direction.length() > 0.0


# ----------------------------------------------------------------------------
# NORMAL (walk / run / crouch / air)
# ----------------------------------------------------------------------------
func _state_normal(delta: float) -> void:
	var on_floor := is_on_floor()

	# transitions
	if on_floor:
		if Input.is_action_just_pressed(slide_action):
			_try_start_slide()
	else:
		_try_start_wallrun()
	if state != PlayerState.NORMAL:
		return

	# gravity (different when rising / falling)
	if not on_floor:
		velocity.y += (jump_gravity if velocity.y >= 0.0 else fall_gravity) * delta

	var jumped := _handle_jump()

	# horizontal movement
	var target_speed := WALK_SPEED
	if is_sprinting:
		target_speed = SPRINT_SPEED
	elif is_crouching:
		target_speed = CROUCH_SPEED
	target_speed += speed_bonus

	var control := 1.0 if on_floor else air_control
	if lock_air_timer <= 0.0: # locked briefly after a walljump
		if direction != Vector3.ZERO:
			velocity.x = lerp(velocity.x, direction.x * target_speed, ACCELERATION * control * delta)
			velocity.z = lerp(velocity.z, direction.z * target_speed, ACCELERATION * control * delta)
		else:
			velocity.x = lerp(velocity.x, 0.0, FRICTION * control * delta)
			velocity.z = lerp(velocity.z, 0.0, FRICTION * control * delta)

	target_h = crouch_height if is_crouching else _standing_target()

	_animate_normal(on_floor and not jumped)

	emit_dust = is_sprint_anim and direction.length() > 0.0 and is_on_floor()


func _animate_normal(on_floor: bool) -> void:
	if on_floor:
		if just_landed:
			if is_sprinting:
				var roll_scale = -1.0 if is_moving_backward else 1.0
				anim_player.speed_scale = roll_scale
				anim_player.play("Roll")
			else:
				var land_scale = 1.0
				if Input.is_action_pressed("ui_up"):
					var horizontal_speed = Vector2(velocity.x, velocity.z).length()
					if horizontal_speed > WALK_SPEED:
						land_scale = clamp(remap(horizontal_speed, WALK_SPEED, SPRINT_SPEED, 1.0, 2.2), 1.0, 2.2)
				if is_moving_backward:
					land_scale = -land_scale
				anim_player.speed_scale = land_scale
				anim_player.play("Jump_Land")
		else:
			var current_anim = anim_player.current_animation
			var can_interrupt = true

			if (current_anim == "Jump_Land" or current_anim == "Roll") and anim_player.is_playing():
				if anim_player.current_animation_position < 1.0:
					can_interrupt = false

			if can_interrupt or not anim_player.is_playing():
				var base_scale = -1.0 if is_moving_backward else 1.0
				anim_player.speed_scale = base_scale
				if is_crouching:
					if direction:
						anim_player.play("Swim_Fwd")
					else:
						anim_player.play("Crouch_Idle")
				elif is_sprinting and direction:
					anim_player.play("Sprint")
					is_sprint_anim = true
				elif direction:
					anim_player.play("Walk")
				else:
					anim_player.play("Idle")
			else:
				if is_sprinting and direction:
					is_sprint_anim = true
	else:
		anim_player.speed_scale = 1.0
		if velocity.y > 0 and anim_player.current_animation != "Jump_Start":
			anim_player.play("Jump_Start")
		elif velocity.y <= 0:
			if anim_player.current_animation != "Jump_Start" or not anim_player.is_playing():
				anim_player.play("Jump")


# ----------------------------------------------------------------------------
# Jump (coyote time, buffering, air jumps, bunny hop)
# ----------------------------------------------------------------------------
func _handle_jump() -> bool:
	if jump_buffer_timer <= 0.0 or jump_cooldown_timer > 0.0:
		return false
	if is_on_floor() or coyote_timer > 0.0:
		_do_jump(true)
		return true
	if air_jumps_left > 0:
		air_jumps_left -= 1
		_do_jump(false)
		return true
	return false


func _do_jump(from_ground: bool) -> void:
	# jumping right after landing = chained bunny hop -> accumulate speed
	if from_ground and ground_grace_timer > 0.0:
		speed_bonus = minf(speed_bonus + bunny_hop_bonus, max_speed_bonus)
	velocity.y = jump_velocity
	jump_buffer_timer = 0.0
	jump_cooldown_timer = jump_cooldown
	coyote_timer = 0.0
	ground_grace_timer = 0.0
	anim_player.speed_scale = 1.0
	anim_player.play("Jump_Start")


# ----------------------------------------------------------------------------
# SLIDE
# ----------------------------------------------------------------------------
func _try_start_slide() -> void:
	if slide_cooldown > 0.0 or not is_on_floor():
		return
	if _h_speed() < slide_min_speed:
		return # too slow -> falls back to a normal crouch
	slide_dir = Vector3(velocity.x, 0.0, velocity.z).normalized()
	slide_cur_speed = maxf(_h_speed(), slide_speed)
	slide_time_left = slide_time
	state = PlayerState.SLIDE


func _state_slide(delta: float) -> void:
	target_h = slide_height
	emit_dust = is_on_floor()
	play_anim(slide_anim)

	if not is_on_floor():
		_end_slide()
		return

	if jump_buffer_timer > 0.0 and jump_cooldown_timer <= 0.0:
		_end_slide()
		_do_jump(true)
		return

	var n := get_floor_normal()
	var slope_angle := rad_to_deg(acos(clampf(n.dot(Vector3.UP), -1.0, 1.0)))
	var sloped := slope_angle > 1.0 and slope_angle <= max_slope_angle
	var downhill := Vector3(n.x, 0.0, n.z).normalized()

	if sloped and slide_dir.dot(downhill) > uphill_tolerance:
		# sliding downhill: free time, gain speed
		slide_cur_speed += slope_sliding_speed_incre * delta
	else:
		slide_cur_speed = maxf(slide_cur_speed - amount_velocity_lost_per_sec * delta, 0.0)
		slide_time_left -= delta

	var v := slide_dir * slide_cur_speed
	if sloped:
		v = v.slide(n).normalized() * slide_cur_speed # follow the slope
	velocity = v

	if slide_time_left <= 0.0 or slide_cur_speed < CROUCH_SPEED:
		_end_slide()
	elif not continious_slide and not Input.is_action_pressed(slide_action):
		_end_slide()


func _end_slide() -> void:
	state = PlayerState.NORMAL
	slide_cooldown = time_bef_can_slide_again
	_carry_momentum()


# ----------------------------------------------------------------------------
# DASH
# ----------------------------------------------------------------------------
func _try_dash() -> void:
	if dash_charges <= 0 or dash_cooldown > 0.0:
		return
	var dir := direction
	if dir == Vector3.ZERO:
		dir = transform.basis.z # facing direction
	dir.y = 0.0
	dash_dir = dir.normalized()
	velocity_pre_dash = velocity
	if dash_charges == nb_dashs_allowed:
		dash_reload_timer = time_bef_reload_dash
	dash_charges -= 1
	dash_cooldown = time_bef_can_dash_again
	dash_time_left = dash_time
	state = PlayerState.DASH


func _state_dash(delta: float) -> void:
	play_anim(dash_anim)
	dash_time_left -= delta
	velocity = dash_dir * dash_speed # no gravity while dashing
	if dash_time_left <= 0.0:
		var h := maxf(Vector2(velocity_pre_dash.x, velocity_pre_dash.z).length(), WALK_SPEED)
		velocity = Vector3(dash_dir.x * h, velocity_pre_dash.y, dash_dir.z * h)
		state = PlayerState.NORMAL
		_carry_momentum()


# ----------------------------------------------------------------------------
# WALLRUN / WALLJUMP
# ----------------------------------------------------------------------------
func _try_start_wallrun() -> void:
	if wallrun_cooldown > 0.0 or direction == Vector3.ZERO:
		return
	if not _high_enough_for_wallrun():
		return

	var hit := _find_wall()
	if hit.is_empty():
		return

	var n := Vector3(hit.normal.x, 0.0, hit.normal.z).normalized()
	if last_wall_normal != Vector3.ZERO and n.dot(last_wall_normal) > 0.9:
		return # same wall as last time, must touch the ground first

	var dir := n.cross(Vector3.UP).normalized()
	if dir.dot(direction) < 0.0:
		dir = -dir
	if dir.dot(direction) < 0.3:
		return # not moving along the wall

	wall_normal = n
	wall_dir = dir
	wallrun_time_left = wallrun_time
	velocity.y = maxf(velocity.y, 0.0) * 0.3
	state = PlayerState.WALLRUN


func _state_wallrun(delta: float) -> void:
	play_anim(wallrun_anim)

	# keep the wall updated, stop if it's gone
	var origin := global_position + Vector3.UP * wall_check_height
	var hit := _raycast(origin, origin - wall_normal * wall_check_distance * 1.5)
	if hit.is_empty() or absf(hit.normal.y) > 0.2:
		_end_wallrun()
		return
	wall_normal = Vector3(hit.normal.x, 0.0, hit.normal.z).normalized()
	var new_dir := wall_normal.cross(Vector3.UP).normalized()
	wall_dir = new_dir if new_dir.dot(wall_dir) >= 0.0 else -new_dir

	if is_on_floor() or direction == Vector3.ZERO or wallrun_time_left <= 0.0:
		_end_wallrun()
		return

	if jump_buffer_timer > 0.0:
		_do_walljump()
		return

	if not infinite_wallrun_time:
		wallrun_time_left -= delta

	var spd := move_toward(_h_speed(), wallrun_speed, wallrun_accel * delta)
	velocity.x = wall_dir.x * spd
	velocity.z = wall_dir.z * spd
	velocity.y += fall_gravity * wallrun_fall_gravity_multiplier * delta
	velocity -= wall_normal * wall_stick_speed # keep the player pressed on the wall


func _do_walljump() -> void:
	velocity = wall_normal * walljump_push_force \
		+ wall_dir * _h_speed() * 0.5 \
		+ Vector3.UP * walljump_y_velocity
	jump_buffer_timer = 0.0
	lock_air_timer = walljump_lock_in_air_movement_time
	air_jumps_left = nb_jumps_in_air_allowed
	last_wall_normal = wall_normal
	wallrun_cooldown = time_bef_can_wallrun_again
	state = PlayerState.NORMAL
	_carry_momentum()
	anim_player.speed_scale = 1.0
	anim_player.play("Jump_Start")


func _end_wallrun() -> void:
	state = PlayerState.NORMAL
	wallrun_cooldown = time_bef_can_wallrun_again
	last_wall_normal = wall_normal
	_carry_momentum()


func _find_wall() -> Dictionary:
	var origin := global_position + Vector3.UP * wall_check_height
	var best := {}
	var best_dist := INF
	for side in [-1.0, 1.0]:
		var side_dir: Vector3 = transform.basis.x * side
		var hit := _raycast(origin, origin + side_dir * wall_check_distance)
		if hit.is_empty() or absf(hit.normal.y) > 0.2: # ignore floors / ceilings / slopes
			continue
		var d := origin.distance_to(hit.position)
		if d < best_dist:
			best_dist = d
			best = hit
	return best


func _high_enough_for_wallrun() -> bool:
	var from := global_position + Vector3.UP * 0.1
	return _raycast(from, from + Vector3.DOWN * min_wallrun_height).is_empty()


# ----------------------------------------------------------------------------
# FLY
# ----------------------------------------------------------------------------
func _toggle_fly() -> void:
	state = PlayerState.NORMAL if state == PlayerState.FLY else PlayerState.FLY
	if state == PlayerState.NORMAL:
		_carry_momentum()


func _state_fly(delta: float) -> void:
	play_anim(&"Jump")
	var vertical := Input.get_action_strength(jump_action) - Input.get_action_strength(crouch_action)
	var spd := fly_speed * (fly_boost_multiplier if is_sprinting else 1.0)
	var wish := (direction + Vector3.UP * vertical).limit_length(1.0) * spd
	var rate := fly_accel if wish != Vector3.ZERO else fly_deccel
	velocity = velocity.lerp(wish, rate * delta)


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
func _h_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Turns leftover speed (after slide / dash / wallrun / walljump) into a bonus
## that decays once the player is back on the ground.
func _carry_momentum() -> void:
	speed_bonus = clampf(maxf(speed_bonus, _h_speed() - SPRINT_SPEED), 0.0, max_speed_bonus)


func _raycast(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


func _ceiling_blocked() -> bool:
	return not _raycast(global_position, global_position + Vector3(0, standing_height, 0)).is_empty()


func _standing_target() -> float:
	return crouch_height if _ceiling_blocked() else standing_height


func _update_hitbox(delta: float) -> void:
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		collision_shape.shape.height = lerp(collision_shape.shape.height, target_h, delta * 10.0)


## Plays an animation only if it exists and isn't already playing.
func play_anim(anim: StringName, speed: float = 1.0) -> void:
	anim_player.speed_scale = speed
	if anim_player.has_animation(anim) and anim_player.current_animation != anim:
		anim_player.play(anim)
