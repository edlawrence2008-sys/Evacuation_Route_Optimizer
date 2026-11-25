extends CharacterBody3D

# --- Node References ---
@onready var head = $head
@onready var camera = $head/CameraSmooth/Camera3D
@onready var camera_smooth = $head/CameraSmooth
@onready var collision_shape = $CollisionShape3D
@onready var sfx_step = $step
@onready var sfx_slide_loop = $slide
@onready var sfx_slide_start = $SlideStart
@onready var sfx_jump = $Jump
@onready var sfx_wall_jump = $WallJump
@onready var sfx_wall_run_start = $WallRunStart
@onready var sfx_wall_slide_loop = $WallRunStart
@onready var sfx_land = $GenericLandImpact

# --- Health Settings ---
@export_group("Health")
@onready var health_component: HealthComponent = $HealthComponent

# --- Camera Settings ---
@export_group("Camera")
## Degrees of camera roll at full sideways input. Positive rolls into the
## strafe direction; the settings menu overrides this through
## PerformanceSettings.
@export var view_roll: float = 1.0
var _view_roll_current: float = 0.0

# --- Movement Settings ---
const WALK_SPEED = 5.0
const SPRINT_SPEED = 8.0
## Jump apex height. The project gravity is 12 m/s^2, so this clears one 1 m
## block with margin (even when the block is reached mid-ascent) while staying
## well below two blocks.
const JUMP_HEIGHT: float = 1.35
const SENSITIVITY = 0.004
const ACCELERATION = 10.0
const FRICTION = 10.0
const CROUCH_SPEED = 2.5

# --- Ledge Settings ---
const LEDGE_DETECTION_DISTANCE = 0.8
const LEDGE_JUMP_VELOCITY = 6.0 
const LEDGE_CHECK_HEIGHT = 0.5 
## Space required above a ledge before it can be mantled. A ledge with a block
## stacked on top of it is a wall, not a ledge, and must not be climbable.
const LEDGE_CLEARANCE_MARGIN = 0.05
const LEDGE_CAPSULE_RADIUS = 0.25
var is_on_ledge = false
var ledge_y_position = 0.0
var mantle_timer = 0.0 

# --- Slide Settings ---
const SLIDE_SPEED = 12.0
const SLIDE_FRICTION = 4.0    
const SLIDE_TILT = -4.0      
var is_sliding = false
var slide_vector = Vector3.ZERO
## Short enough to pass under a one-block gap (1 m) with 0.1 m to spare.
var crouch_height = 0.9
## Slightly under two block heights (2.0 m) so the standing capsule can pass
## through a two-block doorway without catching its top on the ceiling.
var standing_height = 1.8

# --- Wall Run Settings ---
const MAX_WALL_UPWARD_VELOCITY = 1.8
const WALL_RUN_GRAVITY = 3.0
const WALL_JUMP_HORIZONTAL_FORCE = 18 
const WALL_JUMP_VERTICAL_FORCE = 4.5    
const WALL_STICK_DISTANCE = 0.5
const MAX_WALL_STAMINA = 100.0
const STAMINA_REGEN_RATE = 40.0
const PENALTY_REGEN_RATE = 8
const REGEN_PENALTY_TIME = 1.5
const SAME_WALL_JUMP_COST = 65.0
const NEW_WALL_JUMP_COST = 25.0

var can_wall_jump = true 
var last_wall_normal = Vector3.ZERO 
var current_wall_side = "none"
var wall_stamina = MAX_WALL_STAMINA
var penalty_timer = 0.0

# --- Visual Settings ---
const BOB_FREQ = 2.4
const BOB_AMP = 0.06
const LAND_BOUNCE_AMOUNT = -0.15
const WALL_RUN_TILT = 5.0
var camera_x_rotation = 0.0
var camera_tween : Tween
var damage_tween : Tween

# --- Bunny Hop Settings ---
## Holding jump through a landing immediately jumps again and keeps the
## horizontal momentum, so slide jumps and chained hops carry their speed.
const BHOP_MAX_SPEED = 3500
const BHOP_HOP_GAIN = 1.03
const BHOP_AIR_TURN_RATE = 4.0
var bhop_chain: int = 0

# --- Zoom Settings ---
const ZOOM_FOV = 40.0
const DEFAULT_FOV = 75.0
const ZOOM_SPEED = 0.2
var is_zooming = false

# --- Noclip Settings ---
var cam_aligned_wish_dir: Vector3 = Vector3.ZERO
var noclip_speed_mult: float = 1.0
var noclip: bool = false
const DEBUG_MODE: bool = true

# Internal state
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
## Derived from gravity so the apex stays at JUMP_HEIGHT if gravity is retuned.
var jump_velocity: float = sqrt(2.0 * gravity * JUMP_HEIGHT)
var was_on_floor = true
var is_wall_running = false
var wall_normal = Vector3.ZERO
var _jumped_this_frame: bool = false
var t_bob = 0.0
var last_bob_y = 0.0

# --- State Variables ---
var is_dead: bool = false
var movement_enabled: bool = true

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	add_to_group("player")

	if health_component:
		health_component.health_depleted.connect(_on_player_death)
		health_component.damaged.connect(_on_player_damaged)


## Release active audio playbacks so shutdown does not report leaked MP3
## streams (Godot keeps a playback reference while a sound is playing).
func _exit_tree() -> void:
	for child in get_children():
		if child is AudioStreamPlayer3D:
			child.stop()
			child.stream = null

func _input(event):
	if is_dead: return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var current_sensitivity = SENSITIVITY * (0.5 if is_zooming else 1.0)
		# Yaw turns the whole CharacterBody3D so the body (and anything that
		# reads its basis) follows the camera. Pitch stays on the camera.
		rotate_y(-event.relative.x * current_sensitivity)
		camera_x_rotation -= event.relative.y * current_sensitivity
		camera_x_rotation = clamp(camera_x_rotation, deg_to_rad(-89), deg_to_rad(89))

	if (
		_can_adjust_noclip_speed()
		and event is InputEventMouseButton
		and event.pressed
	):
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			noclip_speed_mult = clamp(noclip_speed_mult + 0.2, 0.2, 10.0)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			noclip_speed_mult = clamp(noclip_speed_mult - 0.2, 0.2, 10.0)
			get_viewport().set_input_as_handled()

func _physics_process(delta):
	if is_dead:
		_update_view_roll(0.0, delta)
		if not is_on_floor():
			velocity.y -= gravity * delta
		velocity.x = lerp(velocity.x, 0.0, delta * 4.0)
		velocity.z = lerp(velocity.z, 0.0, delta * 4.0)
		move_and_slide()
		return
	# Freeze the player when the inventory or console owns the cursor.
	if not movement_enabled:
		_update_view_roll(0.0, delta)
		move_and_slide()
		return

	_jumped_this_frame = false

	var input_dir = Input.get_vector("left", "right", "up", "down")
	var direction = (global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	cam_aligned_wish_dir = (camera.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	_update_view_roll(input_dir.x, delta)

	handle_noclip(delta)
	if noclip: return
	_update_stamina(delta)

	handle_wall_run_logic(delta, direction)
	handle_slide_logic(delta, direction)
	handle_ledge_logic()
	handle_zoom_logic()

	# Landing is handled before a fresh jump press so holding jump through a
	# landing chains straight into the next hop without a ground-friction frame.
	if is_on_floor() and not was_on_floor:
		_handle_landing()

	if Input.is_action_just_pressed("jump"):
		_handle_jump()

	was_on_floor = is_on_floor()

	_apply_movement_velocity(delta, direction, input_dir)

	var target_h = crouch_height if Input.is_action_pressed("crouch") else standing_height

	# Do not grow the capsule into a ceiling: stay crouched until there is
	# standing room above the current capsule top.
	if target_h > collision_shape.shape.height and _is_ceiling_blocked(target_h):
		target_h = collision_shape.shape.height

	collision_shape.shape.height = lerp(collision_shape.shape.height, target_h, delta * 10.0)
	
	if not is_on_floor() and not is_wall_running and not is_on_ledge:
		velocity.y -= gravity * delta
		
	if mantle_timer > 0:
		mantle_timer -= delta

	move_and_slide()

	_handle_visuals(delta)

# --- Noclip ---
## Mouse-wheel speed changes belong to active gameplay noclip only. Menus and
## the console release the mouse cursor, so they never adjust the fly speed.
func _can_adjust_noclip_speed() -> bool:
	return (
		DEBUG_MODE
		and noclip
		and movement_enabled
		and not is_dead
		and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	)


func handle_noclip(delta: float):
	if not DEBUG_MODE: return

	if Input.is_action_just_pressed("ui_noclip"):
		noclip = !noclip
		_cancel_mantle()
		collision_shape.disabled = noclip
		velocity = Vector3.ZERO

	if noclip:
		const NOCLIP_BASE_SPEED = 10.0
		var noclip_speed: float = NOCLIP_BASE_SPEED * noclip_speed_mult
		var vertical_input: float = 0.0
		if Input.is_action_pressed("jump"):
			vertical_input += 1.0
		if Input.is_action_pressed("crouch"):
			vertical_input -= 1.0
		# Vertical flight uses the same scroll-adjusted speed as horizontal
		# flight, so jump/crouch feel identical to forward movement.
		velocity = (
			cam_aligned_wish_dir * noclip_speed
			+ Vector3.UP * vertical_input * noclip_speed
		)
		global_position += velocity * delta
		velocity = Vector3.ZERO
		_handle_visuals(delta)

# --- Health Callbacks ---
func _on_player_damaged(_amount: float):
	if is_dead: return
	
	_play_sfx(sfx_land, 0.7, 0.9)
	if camera_tween: camera_tween.kill()

	var tilt_dir = 1 if randf() > 0.5 else -1

	camera_tween = create_tween().set_parallel(true)
	camera_tween.tween_property(camera, "position:y", -0.1, 0.1)
	camera_tween.tween_property(camera, "rotation:z", deg_to_rad(5) * tilt_dir, 0.1)
	camera_tween.chain().tween_property(camera, "position:y", 0.0, 0.3)
	camera_tween.chain().tween_property(camera, "rotation:z", 0.0, 0.3)

func _on_player_death():
	is_dead = true
	_cancel_mantle()
	sfx_slide_loop.stop()
	if camera_tween: camera_tween.kill()
	if damage_tween: damage_tween.kill()

	velocity.y = 0.0

	var death_tween = create_tween().set_parallel(true)
	death_tween.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	death_tween.tween_property(camera, "rotation:z", deg_to_rad(75), 0.8)
	death_tween.tween_property(camera, "position:y", -0.5, 0.8)
	death_tween.tween_property(camera, "position:x", 0.4, 0.8)

func _update_stamina(delta):
	if penalty_timer > 0:
		penalty_timer -= delta
		wall_stamina = move_toward(wall_stamina, MAX_WALL_STAMINA, PENALTY_REGEN_RATE * delta)
	else:
		wall_stamina = move_toward(wall_stamina, MAX_WALL_STAMINA, STAMINA_REGEN_RATE * delta)
	
	if is_on_floor() or is_on_ledge:
		can_wall_jump = true
		last_wall_normal = Vector3.ZERO
		wall_stamina = MAX_WALL_STAMINA
		penalty_timer = 0.0

func _handle_landing():
	# Auto-hop: holding jump on touchdown launches again immediately and keeps
	# the horizontal speed the player arrived with (plus a small hop bonus).
	if Input.is_action_pressed("jump"):
		bhop_chain += 1
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		var speed := minf(horizontal.length() * BHOP_HOP_GAIN, BHOP_MAX_SPEED)
		if speed > 0.01:
			horizontal = horizontal.normalized() * speed
			velocity.x = horizontal.x
			velocity.z = horizontal.z
		_handle_jump()
		if _jumped_this_frame:
			return

	bhop_chain = 0
	_on_land()


func _handle_jump():
	if _jumped_this_frame:
		return
	if is_on_floor():
		if is_sliding: _exit_slide()
		# A jump from the ground starts momentum preservation, so a slide jump
		# carries its speed and a held jump can chain on landing.
		bhop_chain = maxi(bhop_chain, 1)
		_on_jump()
	elif is_on_ledge:
		_on_ledge_jump()
	elif is_wall_running and can_wall_jump and wall_stamina >= NEW_WALL_JUMP_COST:
		_on_wall_jump()

func set_movement_enabled(enabled: bool) -> void:
	movement_enabled = enabled
	if not enabled:
		_cancel_mantle()
		velocity = Vector3.ZERO
		bhop_chain = 0
		if is_sliding:
			_exit_slide()
		if is_wall_running:
			is_wall_running = false
			_tilt_camera("none")
			sfx_wall_run_start.stop()

func _apply_movement_velocity(delta, direction, input_dir):
	if _jumped_this_frame:
		return

	if is_sliding:
		var slide_speed: float = maxf(
			SLIDE_SPEED,
			Vector3(velocity.x, 0.0, velocity.z).length()
		)
		velocity.x = lerp(velocity.x, slide_vector.x * slide_speed, delta * SLIDE_FRICTION)
		velocity.z = lerp(velocity.z, slide_vector.z * slide_speed, delta * SLIDE_FRICTION)
		if velocity.length() < WALK_SPEED: _exit_slide()
	elif is_on_ledge:
		velocity = Vector3.ZERO
		if input_dir.y > 0: _exit_ledge()
	elif bhop_chain > 0 and not is_on_floor() and not is_wall_running:
		_apply_bhop_air_movement(delta, direction)
	else:
		var target_speed = WALK_SPEED

		if is_wall_running:
			# A wall run guarantees at least sprint speed, but never caps a
			# faster slide/bhop momentum.
			target_speed = maxf(
				SPRINT_SPEED,
				Vector3(velocity.x, 0.0, velocity.z).length()
			)
		elif Input.is_action_pressed("sprint"):
			target_speed = SPRINT_SPEED
		elif Input.is_action_pressed("crouch"):
			target_speed = CROUCH_SPEED
			
		if direction:
			velocity.x = lerp(velocity.x, direction.x * target_speed, ACCELERATION * delta)
			velocity.z = lerp(velocity.z, direction.z * target_speed, ACCELERATION * delta)
		else:
			velocity.x = lerp(velocity.x, 0.0, FRICTION * delta)
			velocity.z = lerp(velocity.z, 0.0, FRICTION * delta)


## Air control while a bunny-hop chain is active: keep the horizontal speed and
## turn the momentum toward the input instead of lerping straight to walk speed.
func _apply_bhop_air_movement(delta: float, direction: Vector3) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var speed := minf(horizontal.length(), BHOP_MAX_SPEED)

	if speed < 0.01:
		if direction != Vector3.ZERO:
			velocity.x = direction.x * WALK_SPEED
			velocity.z = direction.z * WALK_SPEED
		return

	if direction == Vector3.ZERO:
		velocity.x = horizontal.x
		velocity.z = horizontal.z
		return

	var current_dir := horizontal / horizontal.length()
	var turn := clampf(BHOP_AIR_TURN_RATE * delta, 0.0, 1.0)
	var new_dir := current_dir.slerp(direction.normalized(), turn)
	velocity.x = new_dir.x * speed
	velocity.z = new_dir.z * speed


## True when growing the crouched capsule to `target_height` would run into
## geometry above the current capsule top (a low ceiling or one-block gap).
func _is_ceiling_blocked(target_height: float) -> bool:
	var current_height: float = collision_shape.shape.height
	var extra: float = target_height - current_height

	if extra <= 0.0:
		return false

	var radius: float = 0.25
	if collision_shape.shape is CapsuleShape3D:
		radius = (collision_shape.shape as CapsuleShape3D).radius

	# Only the volume the taller capsule would gain above the current head is
	# tested, so the floor and the body's current shape never self-collide.
	var headroom := BoxShape3D.new()
	var width: float = maxf(radius * 2.0 - 0.04, 0.05)
	headroom.size = Vector3(width, extra, width)

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = headroom
	params.transform = Transform3D(
		Basis(),
		global_position + Vector3.UP * (
			current_height * 0.5 + extra * 0.5 + 0.01
		)
	)
	params.collision_mask = collision_mask
	params.collide_with_areas = false
	params.collide_with_bodies = true
	params.exclude = [get_rid()]

	return (
		not get_world_3d().direct_space_state.intersect_shape(
			params,
			1
		).is_empty()
	)


func handle_zoom_logic():
	if Input.is_action_pressed("zoom"):
		if not is_zooming:
			_toggle_zoom(true)
	else:
		if is_zooming:
			_toggle_zoom(false)

func _toggle_zoom(active: bool):
	is_zooming = active
	var target_fov = ZOOM_FOV if active else DEFAULT_FOV
	
	var zoom_tween = create_tween()
	zoom_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	zoom_tween.tween_property(camera, "fov", target_fov, ZOOM_SPEED)

func handle_slide_logic(_delta, direction):
	var crouch_input = Input.is_action_pressed("crouch")
	if crouch_input and is_on_floor() and velocity.length() > WALK_SPEED:
		if not is_sliding: _enter_slide(direction)
	if not crouch_input and is_sliding:
		_exit_slide()

func _enter_slide(dir):
	is_sliding = true
	slide_vector = dir if dir != Vector3.ZERO else -head.global_transform.basis.z
	if camera_tween: camera_tween.kill()
	camera_tween = create_tween()
	camera_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	camera_tween.tween_property(camera, "rotation:z", deg_to_rad(SLIDE_TILT), 0.3)
	_play_sfx(sfx_slide_start)
	sfx_slide_loop.play()

func _exit_slide():
	is_sliding = false
	if camera_tween: camera_tween.kill()
	camera_tween = create_tween().set_parallel(true)
	camera_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	camera_tween.tween_property(camera, "fov", 75.0, 0.3)
	camera_tween.tween_property(camera, "rotation:z", 0.0, 0.4)
	sfx_slide_loop.stop()

func handle_wall_run_logic(delta, direction):
	var left_ray = _check_wall(head.global_transform.basis.x * -1)
	var right_ray = _check_wall(head.global_transform.basis.x)
	var hit_data = left_ray if left_ray else right_ray
	var is_valid_wall = hit_data and abs(hit_data["normal"].y) < 0.3

	if not is_on_floor() and is_valid_wall and direction.dot(-head.global_transform.basis.z) > 0:
		wall_normal = hit_data["normal"]
		if wall_normal.dot(last_wall_normal) < 0.9: can_wall_jump = true
		is_wall_running = true
		var new_side = "left" if left_ray else "right"
		if current_wall_side != new_side:
			current_wall_side = new_side
			_tilt_camera(current_wall_side)
		velocity.y -= WALL_RUN_GRAVITY * delta
		velocity.y = clamp(velocity.y, -WALL_RUN_GRAVITY, MAX_WALL_UPWARD_VELOCITY)
		if not sfx_wall_run_start.playing:
			_play_sfx(sfx_land)
			sfx_wall_run_start.play()
	else:
		if is_wall_running:
			is_wall_running = false
			_tilt_camera("none")
			current_wall_side = "none"
			if sfx_wall_run_start:
				sfx_wall_run_start.stop()
			if sfx_wall_slide_loop:
				sfx_wall_slide_loop.stop()

func _check_wall(dir: Vector3) -> Variant:
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(global_position, global_position + dir * WALL_STICK_DISTANCE)
	query.exclude = [get_rid()] 
	return space_state.intersect_ray(query)

# --- Visual Effects ---
func _on_jump():
	_jumped_this_frame = true
	velocity.y = jump_velocity
	if camera_tween: camera_tween.kill()
	camera_tween = create_tween().set_parallel(true)
	camera_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	camera_tween.tween_property(camera, "rotation:z", 0.0, 0.3)
	camera_tween.tween_property(camera, "fov", 85.0, 0.1)
	camera_tween.tween_property(camera, "position:y", 0.05, 0.1)
	camera_tween.chain().set_parallel(true)
	camera_tween.tween_property(camera, "fov", 75.0, 0.3)
	camera_tween.tween_property(camera, "position:y", 0.0, 0.2)
	_play_sfx(sfx_jump)

func _on_land():
	if camera_tween: camera_tween.kill()
	camera_tween = create_tween().set_parallel(true)
	camera_tween.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	camera_tween.tween_property(camera, "rotation:z", 0.0, 0.2)
	camera_tween.tween_property(camera, "position:y", LAND_BOUNCE_AMOUNT, 0.1)
	camera_tween.chain().tween_property(camera, "position:y", 0.0, 0.2)
	_play_sfx(sfx_land)

func _on_wall_jump():
	bhop_chain = 0
	velocity = (wall_normal * WALL_JUMP_HORIZONTAL_FORCE) + (Vector3.UP * WALL_JUMP_VERTICAL_FORCE)
	penalty_timer = REGEN_PENALTY_TIME
	wall_stamina -= SAME_WALL_JUMP_COST if wall_normal.dot(last_wall_normal) > 0.8 else NEW_WALL_JUMP_COST
	last_wall_normal = wall_normal
	can_wall_jump = false 
	is_wall_running = false
	var kick_tilt = deg_to_rad(8.0) if current_wall_side == "left" else deg_to_rad(-8.0)
	current_wall_side = "none"
	if camera_tween: camera_tween.kill()
	camera_tween = create_tween().set_parallel(true)
	camera_tween.tween_property(camera, "rotation:z", kick_tilt, 0.1)
	camera_tween.chain().tween_property(camera, "rotation:z", 0.0, 0.4)
	_play_sfx(sfx_wall_jump)

func _tilt_camera(side):
	if is_sliding: return 
	var target_tilt = 0.0
	match side:
		"left": target_tilt = deg_to_rad(-WALL_RUN_TILT)
		"right": target_tilt = deg_to_rad(WALL_RUN_TILT)
		"none": target_tilt = 0.0
	if camera_tween: camera_tween.kill()
	camera_tween = create_tween()
	camera_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	camera_tween.tween_property(camera, "rotation:z", target_tilt, 0.25)

## Applies the strafe-based view roll to the camera rig. Kept on the smooth
## pivot so slide/wall-run/death camera tweens can still use the camera's own
## z rotation without fighting this offset.
func _update_view_roll(strafe: float, delta: float) -> void:
	var target := -deg_to_rad(view_roll) * clampf(strafe, -1.0, 1.0)
	_view_roll_current = lerpf(
		_view_roll_current,
		target,
		clampf(delta * 8.0, 0.0, 1.0)
	)
	if camera_smooth != null:
		camera_smooth.rotation.z = _view_roll_current


func _handle_visuals(delta):
	camera_x_rotation = clamp(camera_x_rotation, deg_to_rad(-89), deg_to_rad(89))

	var is_damage_animating = damage_tween and damage_tween.is_running()

	if not is_damage_animating:
		camera.rotation.x = camera_x_rotation
	else:
		camera.rotation.x = lerp(camera.rotation.x, camera_x_rotation, delta * 20.0)

	var is_animating = is_damage_animating or (camera_tween and camera_tween.is_running())

	if is_on_floor() and velocity.length() > 1.0 and not is_sliding:
		t_bob += delta * velocity.length()
		
		var bob_x = cos(t_bob * BOB_FREQ / 2) * BOB_AMP
		var bob_y = sin(t_bob * BOB_FREQ) * BOB_AMP

		if not is_animating:
			camera.transform.origin.x = bob_x
			camera.transform.origin.y = bob_y
		
		if bob_y < last_bob_y and bob_y < -BOB_AMP * 0.9: 
			if not sfx_step.playing:
				_play_sfx(sfx_step)
		
		last_bob_y = bob_y
	else:
		t_bob = 0.0
		if not is_animating:
			camera.transform.origin = camera.transform.origin.lerp(Vector3.ZERO, delta * 5.0)
		last_bob_y = 0.0

func handle_ledge_logic():
	if is_on_floor() or is_on_ledge or mantle_timer > 0: return
	var wall_dir = -head.global_transform.basis.z * LEDGE_DETECTION_DISTANCE
	var wall_hit = _check_ray(global_position, global_position + wall_dir)
	if wall_hit:
		var check_pos = global_position + (wall_dir * 1.2) + Vector3(0, LEDGE_CHECK_HEIGHT, 0)
		var floor_hit = _check_ray(check_pos, check_pos + Vector3.DOWN * (LEDGE_CHECK_HEIGHT * 2.0))
		# Only a truly exposed top counts as a ledge: if a block sits above it,
		# the standing capsule cannot fit and the surface is a wall instead.
		if (
			floor_hit
			and floor_hit["normal"].y > 0.5
			and _ledge_has_standing_clearance(floor_hit["position"])
		):
			ledge_y_position = floor_hit.position.y
			is_on_ledge = true
			is_wall_running = false


## Checks that the full standing capsule fits above `ledge_top`.
func _ledge_has_standing_clearance(ledge_top: Vector3) -> bool:
	var capsule := CapsuleShape3D.new()
	capsule.radius = LEDGE_CAPSULE_RADIUS
	capsule.height = standing_height

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = capsule
	params.transform = Transform3D(
		Basis(),
		ledge_top + Vector3.UP * (standing_height * 0.5 + LEDGE_CLEARANCE_MARGIN)
	)
	params.collision_mask = collision_mask
	params.collide_with_areas = false
	params.collide_with_bodies = true
	params.exclude = [get_rid()]

	var hits := get_world_3d().direct_space_state.intersect_shape(params, 1)
	return hits.is_empty()

func _on_ledge_jump():
	bhop_chain = 0
	var height_to_climb = ledge_y_position - global_position.y
	var vertical_needed = sqrt(2 * gravity * (height_to_climb + 1.5))
	velocity = (Vector3.UP * vertical_needed) + (-head.global_transform.basis.z * 4.0)
	mantle_timer = 0.3
	is_on_ledge = false
	
	if camera_tween: camera_tween.kill()
	camera_tween = create_tween()
	
	var start_rot = camera_x_rotation
	var peak_rot = clamp(start_rot - deg_to_rad(15), deg_to_rad(-89), deg_to_rad(89))
	
	camera_tween.tween_property(self, "camera_x_rotation", peak_rot, 0.15)
	camera_tween.chain().tween_property(self, "camera_x_rotation", start_rot, 0.2)
	
	_play_sfx(sfx_wall_jump)

func _exit_ledge():
	is_on_ledge = false


## Drops any in-progress mantle. Noclip, the inventory/console, and death all
## interrupt movement while `mantle_timer` is still ticking; leaving it set
## would re-enter the mantle path (and its upward velocity) later.
func _cancel_mantle() -> void:
	is_on_ledge = false
	mantle_timer = 0.0

func _check_ray(from: Vector3, to: Vector3) -> Variant:
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var result = space_state.intersect_ray(query)

	if result:
		return result

	return null

func _play_sfx(stream_node: AudioStreamPlayer3D, pitch_min: float = 0.85, pitch_max: float = 1.15):
	if stream_node:
		stream_node.pitch_scale = randf_range(pitch_min, pitch_max)
		stream_node.play()
