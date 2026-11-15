extends Control
class_name ConsulCharacter

enum GazeMode {
	AUTO,
	CURSOR,
	RANDOM,
	TARGET,
	DEFAULT,
}

enum Emotion {
	NEUTRAL,
	HAPPY,
	ANGRY,
	SAD,
	SURPRISED,
	SLEEPY,
	SCARED,
	SUSPICIOUS,
	EXCITED,
	BORED,
}

## width_scale, height_scale pairs for the eyelid opening.
const EMOTION_PRESETS := {
	Emotion.NEUTRAL: Vector2(1.45, 1.0),
	Emotion.HAPPY: Vector2(1.45, 0.7),
	Emotion.ANGRY: Vector2(1.6, 0.45),
	Emotion.SAD: Vector2(1.25, 0.65),
	Emotion.SURPRISED: Vector2(1.35, 1.35),
	Emotion.SLEEPY: Vector2(1.5, 0.28),
	Emotion.SCARED: Vector2(1.7, 1.2),
	Emotion.SUSPICIOUS: Vector2(1.3, 0.45),
	Emotion.EXCITED: Vector2(1.55, 1.15),
	Emotion.BORED: Vector2(1.5, 0.5),
}

enum HandGesture {
	FIST_REST,
	FIST,
	POINT_SIDE,
	POINT_UP,
	OKAY,
	PALM_EXPLAIN,
	PALM_FALTER,
	PALM_JAZZED,
	PALM_STERN,
}

const HAND_GESTURE_TEXTURES := {
	HandGesture.FIST_REST: preload("res://textures/Consul/back_fist_rest.png"),
	HandGesture.FIST: preload("res://textures/Consul/back_fist.png"),
	HandGesture.POINT_SIDE: preload("res://textures/Consul/back_point_side.png"),
	HandGesture.POINT_UP: preload("res://textures/Consul/front_open_point_up.png"),
	HandGesture.OKAY: preload("res://textures/Consul/open_okay.png"),
	HandGesture.PALM_EXPLAIN: preload("res://textures/Consul/open_palm_explain.png"),
	HandGesture.PALM_FALTER: preload("res://textures/Consul/open_palm_falter.png"),
	HandGesture.PALM_JAZZED: preload("res://textures/Consul/open_palm_jazzed.png"),
	HandGesture.PALM_STERN: preload("res://textures/Consul/open_palm_stern.png"),
}

const RIM_SHADER := preload("res://scenes/menu/consul_rim.gdshader")

## [left, right] gestures applied when gestures_follow_emotion is enabled.
const EMOTION_HAND_GESTURES := {
	Emotion.NEUTRAL: [HandGesture.FIST_REST, HandGesture.FIST_REST],
	Emotion.HAPPY: [HandGesture.PALM_JAZZED, HandGesture.PALM_JAZZED],
	Emotion.ANGRY: [HandGesture.FIST, HandGesture.FIST],
	Emotion.SAD: [HandGesture.PALM_FALTER, HandGesture.PALM_FALTER],
	Emotion.SURPRISED: [HandGesture.PALM_EXPLAIN, HandGesture.PALM_JAZZED],
	Emotion.SLEEPY: [HandGesture.FIST_REST, HandGesture.FIST_REST],
	Emotion.SCARED: [HandGesture.PALM_FALTER, HandGesture.PALM_FALTER],
	Emotion.SUSPICIOUS: [HandGesture.POINT_SIDE, HandGesture.FIST_REST],
	Emotion.EXCITED: [HandGesture.PALM_JAZZED, HandGesture.PALM_JAZZED],
	Emotion.BORED: [HandGesture.FIST_REST, HandGesture.FIST_REST],
}

@export var max_iris_radius: float = 110.0  # Maximum distance the iris can travel from the eyeball center
@export var min_scale_factor: float = 0.5  # Prevents the iris from collapsing to 0 at the edge (0.0 to 1.0)

@export_group("Lag & Motion")
@export var base_lag_speed: float = 2  # Base smoothing speed for following the cursor
@export var speed_lag_factor: float = 0.0015 # How much extra lag is added when moving the cursor fast

@export_group("Eye Jitter")
@export var jitter_radius: float = 10.0      # Radius size of the jitter points around the cursor
@export var jitter_frequency: float = 12.0  # How fast the eye twitches/jitters

@export_group("Procedural Eyelid Cutout")
@export var eye_socket_radius: float = 60 # Base radius of the eyelid hole, in eyelid pixels
## Widens the opening horizontally, like a real eye. Change at runtime for expressions.
@export_range(0.1, 4.0, 0.01) var eye_socket_width_scale: float = 1.45
## Squints (below 1.0) or opens the eye vertically. Change at runtime for expressions.
@export_range(0.1, 4.0, 0.01) var eye_socket_height_scale: float = 1.0
## Manual tilt of the eyelid opening, in degrees.
@export_range(-45.0, 45.0, 0.5) var eye_rotation_degrees: float = 0.0
## Extra tilt from the horizontal gaze, in degrees at full travel.
@export_range(0.0, 20.0, 0.5) var gaze_rotation_degrees: float = 0.0
## Extra wobble applied to the opening by the eye jitter, in degrees.
@export_range(0.0, 20.0, 0.5) var jitter_rotation_degrees: float = 20.0
## Sharpen the left/right eye corners without changing the top/bottom curve.
@export_range(0.0, 1.0, 0.01) var eye_socket_corner_sharpness: float = 0.7

@export_group("Gaze Behaviour")
## How the eye decides what to look at. Dialogue can switch this at runtime.
@export var gaze_mode: GazeMode = GazeMode.AUTO
## Fallback point used by CURSOR / DEFAULT when no default node is set.
@export var default_gaze_target: Vector2 = Vector2.ZERO
## Cursor glances only apply within this distance of the eye, in pixels.
@export var gaze_cursor_radius: float = 700.0
## Seconds between random glances in RANDOM mode.
@export var gaze_random_interval: float = 2.0
## Seconds between cursor samples while the eye is idle.
@export var gaze_poll_interval: float = 1.0
## Cursor speed (px/s) that makes the eye lock on and follow continuously.
@export var follow_speed_threshold: float = 120.0
## Cursor travel (px) since the last sample that also starts following.
@export var follow_move_threshold: float = 12.0
## Seconds the cursor must stay still before continuous following stops.
@export var follow_settle_time: float = 0.6
## Chance that an idle cursor sample looks at a random point instead.
@export_range(0.0, 1.0, 0.01) var random_look_chance: float = 0.35
## Maximum distance (px) of a random glance from the eye centre.
@export var random_look_radius: float = 90.0
## Shortest hold time for a random glance before returning to the cursor.
@export var random_look_pause_min: float = 1.0
## Longest hold time for a random glance before returning to the cursor.
@export var random_look_pause_max: float = 5.0
## Speed multiplier for a random glance at random_look_slowdown_distance.
@export_range(0.05, 1.0, 0.01) var random_look_slowdown: float = 0.45
## Distance (px) from the cursor at which the random-glance slowdown maxes out.
@export var random_look_slowdown_distance: float = 400.0

@export_group("Emotions")
## Current expression. Assign at runtime to blend to it.
@export var emotion: Emotion = Emotion.NEUTRAL:
	set(value):
		emotion = value
		if is_inside_tree():
			play_emotion(value)
## Seconds a play_emotion() transition takes.
@export var emotion_blend_time: float = 0.2

@export_group("Blinking")
@export var blink_enabled: bool = true
@export var blink_interval_min: float = 2.5
@export var blink_interval_max: float = 6.5
@export var blink_duration: float = 0.14

@export_group("Squash & Stretch")
## Idle breathing deformation of the whole body.
@export_range(0.0, 0.2, 0.001) var breath_amount: float = 0.015
@export var breath_speed: float = 2.2
## Idle vertical bob, in pixels.
@export var idle_bob_height: float = 1.5
@export var idle_bob_speed: float = 1.4
## Squash applied on a blink (positive squashes vertically).
@export_range(0.0, 1.0, 0.01) var blink_squash: float = 0.3
## Squash applied when the emotion changes.
@export_range(0.0, 1.0, 0.01) var emotion_squash: float = 0.4
## Bounce height for blink and emotion reactions, in pixels.
@export var bounce_height: float = 5.0

@export_group("Rim & Bounce Light")
@export var rim_enabled: bool = true
@export var rim_color: Color = Color(1.0, 0.93, 0.62, 1.0)
@export_range(0.0, 1.0, 0.01) var rim_strength: float = 1.0
@export_range(0.0, 12.0, 0.1) var rim_width: float = 5.0
@export var bounce_color: Color = Color(0.35, 0.65, 1.0, 0.9)
@export_range(0.0, 1.0, 0.01) var bounce_strength: float = 0.9
@export_range(0.0, 12.0, 0.1) var bounce_width: float = 5.0
@export_range(0.0, 1.0, 0.01) var rim_light_mix: float = 0.85
@export var rim_light_direction: Vector2 = Vector2(-1.0, -0.25)

@export_group("Hover")
## Pixels the whole Consul drifts toward its gaze.
@export var gaze_hover_sway: float = 4.0
## Degrees the whole Consul tilts toward its gaze.
@export_range(0.0, 15.0, 0.5) var gaze_hover_tilt_degrees: float = 2.0

@export_group("Hands")
## Vertical hover distance for each hand, in pixels.
@export var hand_bob_height: float = 2.5
@export var hand_bob_speed: float = 2.0
## Fraction of the body's gaze drift applied to the hands.
@export_range(0.0, 2.0, 0.01) var hand_gaze_sway: float = 0.75
## Degrees the hands tilt with the gaze.
@export_range(0.0, 15.0, 0.5) var hand_gaze_tilt_degrees: float = 3.0
## Mirror the right hand so its gestures face outward.
@export var mirror_right_hand: bool = true:
	set(value):
		mirror_right_hand = value
		if right_hand != null:
			right_hand.flip_h = value
## Pick hand gestures automatically from the current emotion.
@export var gestures_follow_emotion: bool = true
## Gesture shown by the left hand.
@export var left_hand_gesture: HandGesture = HandGesture.FIST_REST:
	set(value):
		left_hand_gesture = value
		_apply_hand_gesture(left_hand, left_hand_gesture)
## Gesture shown by the right hand.
@export var right_hand_gesture: HandGesture = HandGesture.FIST_REST:
	set(value):
		right_hand_gesture = value
		_apply_hand_gesture(right_hand, right_hand_gesture)

@onready var eyeball: Sprite2D = $Consul_body/Consul_eyeball
@onready var iris: Sprite2D = $Consul_body/Consul_eyeball/Consul_iris
@onready var eyelid: Sprite2D = $Consul_body/Consul_eyelid
@onready var body: Sprite2D = $Consul_body
@onready var left_hand: Sprite2D = $Hand_L
@onready var right_hand: Sprite2D = $Hand_R

var original_iris_scale: Vector2
var current_iris_local_pos: Vector2 = Vector2.ZERO
var last_mouse_pos: Vector2 = Vector2.ZERO
var gaze_target_global: Vector2 = Vector2.ZERO
var current_emotion: Emotion = Emotion.NEUTRAL
var _eyelid_material: ShaderMaterial
var _rim_material: ShaderMaterial

var _following_cursor: bool = false
var _gaze_poll_timer: float = 0.0
var _cursor_still_timer: float = 0.0
var _last_polled_mouse: Vector2 = Vector2.ZERO
var _random_look_hold: float = 0.0
var _random_gaze_active: bool = false
var _random_look_returning: bool = false
var _random_gaze_speed: float = 1.0
var _emotion_tween: Tween
var _blink_timer: float = 0.0
var _blink_amount: float = 0.0
var _blink_tween: Tween
var _body_base_scale: Vector2 = Vector2.ONE
var _body_base_position: Vector2 = Vector2.ZERO
var _anim_time: float = 0.0
var _squash: float = 0.0
var _bounce: float = 0.0
var _squash_tween: Tween
var _bounce_tween: Tween
var _hover_offset: Vector2 = Vector2.ZERO
var _hand_left_base: Vector2 = Vector2.ZERO
var _hand_right_base: Vector2 = Vector2.ZERO
var _point_target: Variant = null
var _point_hand_index: int = 0
var _wave_remaining: float = 0.0
var _wave_duration: float = 0.0
var _default_gaze_node: Node = null
var _gaze_random_timer: float = 0.0

# Noise generator for smooth, organic micro-movements
var noise = FastNoiseLite.new()
var noise_seed: float = 0.0

func _ready() -> void:
	if iris:
		original_iris_scale = iris.scale
		current_iris_local_pos = iris.position

	# z_index breaks a parent's clip mask, so keep the iris on the same layer.
	if body != null:
		body.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		_body_base_scale = body.scale
		_body_base_position = body.position
	if eyeball != null:
		eyeball.clip_children = CanvasItem.CLIP_CHILDREN_DISABLED
	if iris != null:
		iris.z_index = 0

	if left_hand != null:
		_hand_left_base = left_hand.position
	if right_hand != null:
		_hand_right_base = right_hand.position
		right_hand.flip_h = mirror_right_hand

	_apply_hand_gesture(left_hand, left_hand_gesture)
	_apply_hand_gesture(right_hand, right_hand_gesture)
	_setup_rim_shader()

	# Configure simplex noise for the eye twitch/jitter
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.05
	noise_seed = randf() * 1000.0

	last_mouse_pos = get_global_mouse_position()
	_last_polled_mouse = last_mouse_pos
	gaze_target_global = last_mouse_pos

	# Setup the procedural hole that the iris shows through.
	_setup_procedural_eyelid()
	_schedule_blink()
	play_emotion(emotion, 0.0)

func _setup_rim_shader() -> void:
	if not rim_enabled:
		return
	_rim_material = ShaderMaterial.new()
	_rim_material.shader = RIM_SHADER
	for sprite in [body, left_hand, right_hand]:
		if sprite != null:
			sprite.material = _rim_material
	_apply_rim_parameters()


func _apply_rim_parameters() -> void:
	if _rim_material == null:
		return
	var direction := rim_light_direction
	if direction.length_squared() < 0.0001:
		direction = Vector2(-0.7, -0.7)
	_rim_material.set_shader_parameter("light_dir", direction.normalized())
	_rim_material.set_shader_parameter("rim_color", rim_color)
	_rim_material.set_shader_parameter("rim_strength", rim_strength)
	_rim_material.set_shader_parameter("rim_width", rim_width)
	_rim_material.set_shader_parameter("bounce_color", bounce_color)
	_rim_material.set_shader_parameter("bounce_strength", bounce_strength)
	_rim_material.set_shader_parameter("bounce_width", bounce_width)
	_rim_material.set_shader_parameter("light_mix", rim_light_mix)


func _setup_procedural_eyelid() -> void:
	if eyelid == null:
		return

	_eyelid_material = eyelid.material as ShaderMaterial

	if _eyelid_material == null:
		_eyelid_material = ShaderMaterial.new()
		_eyelid_material.shader = load(
			"res://scenes/menu/consul_eyelid.gdshader"
		)
		eyelid.material = _eyelid_material

	# clip_children only clips child nodes; the hole is carved by the shader.
	eyelid.clip_children = CanvasItem.CLIP_CHILDREN_DISABLED
	_update_eyelid_cutout(Vector2.ONE)


## Mirrors the iris position and directional foreshortening onto the eyelid hole.
func _update_eyelid_cutout(iris_scale: Vector2) -> void:
	if _eyelid_material == null or eyelid == null or iris == null:
		return

	var center: Vector2 = iris.global_position
	var iris_squash := Vector2(
		maxf(iris_scale.x, 0.001),
		maxf(iris_scale.y, 0.001)
	)
	var canvas_scale: Vector2 = eyelid.get_global_transform().get_scale().abs()
	var radius := Vector2(
		eye_socket_radius * eye_socket_width_scale * iris_squash.x,
		eye_socket_radius * eye_socket_height_scale * iris_squash.y
	) * canvas_scale

	# Blinking closes the opening vertically while the iris stays put.
	radius.y *= maxf(0.02, 1.0 - _blink_amount)

	_eyelid_material.set_shader_parameter("cutout_center", center)
	_eyelid_material.set_shader_parameter("cutout_radius", radius)
	_eyelid_material.set_shader_parameter(
		"cutout_sharpness",
		eye_socket_corner_sharpness
	)

	var gaze_roll: float = 0.0
	if max_iris_radius > 0.0:
		gaze_roll = (
			current_iris_local_pos.x / max_iris_radius
			* deg_to_rad(gaze_rotation_degrees)
		)

	var jitter_roll: float = deg_to_rad(
		noise.get_noise_2d(100.0, noise_seed * 0.5)
		* jitter_rotation_degrees
	)
	var cutout_rotation: float = (
		deg_to_rad(eye_rotation_degrees) + gaze_roll + jitter_roll
	)
	if body != null:
		cutout_rotation += body.rotation

	_eyelid_material.set_shader_parameter("cutout_rotation", cutout_rotation)


## Changes the eyelid opening for expressions; applied immediately.
## width_scale > 1.0 widens the eye, height_scale < 1.0 squints it.
func set_eye_shape(width_scale: float, height_scale: float = 1.0) -> void:
	eye_socket_width_scale = maxf(width_scale, 0.01)
	eye_socket_height_scale = maxf(height_scale, 0.01)
	_update_eyelid_cutout(_current_iris_scale())


## Axis-aligned foreshortening for the current gaze direction.
## Looking left/right squashes X; looking up/down squashes Y.
func _current_iris_scale() -> Vector2:
	if max_iris_radius <= 0.0:
		return Vector2.ONE

	var distance: float = current_iris_local_pos.length()
	var t: float = clampf(distance / max_iris_radius, 0.0, 1.0)
	var squash_factor: float = maxf(
		sqrt(maxf(0.0, 1.0 - t * t)),
		min_scale_factor
	)
	var direction: Vector2 = (
		current_iris_local_pos / distance
		if distance > 0.0
		else Vector2.RIGHT
	)
	var dx: float = absf(direction.x)
	var dy: float = absf(direction.y)

	# Axis-aligned extents of an ellipse squashed along the gaze axis.
	return Vector2(
		sqrt(squash_factor * squash_factor * dx * dx + dy * dy),
		sqrt(squash_factor * squash_factor * dy * dy + dx * dx)
	)

func _process(delta: float) -> void:
	if not eyeball or not iris:
		return

	var mouse_pos: Vector2 = get_global_mouse_position()
	var mouse_velocity: Vector2 = (
		(mouse_pos - last_mouse_pos) / maxf(delta, 0.00001)
	)
	var mouse_speed: float = mouse_velocity.length()
	last_mouse_pos = mouse_pos

	_update_gaze_mode(delta, mouse_pos, mouse_speed)
	_update_blink(delta)

	# Organic jitter around whatever the eye is currently looking at.
	noise_seed += delta * jitter_frequency
	var jitter_x: float = noise.get_noise_2d(noise_seed, 0.0)
	var jitter_y: float = noise.get_noise_2d(0.0, noise_seed)
	var jitter_offset: Vector2 = Vector2(jitter_x, jitter_y) * jitter_radius

	var target_mouse_pos: Vector2 = gaze_target_global + jitter_offset
	var eyeball_center: Vector2 = eyeball.global_position
	var to_target: Vector2 = target_mouse_pos - eyeball_center
	var distance: float = to_target.length()
	var clamped_distance: float = minf(distance, max_iris_radius)
	var direction: Vector2 = (
		to_target / distance if distance > 0.0 else Vector2.ZERO
	)
	var target_local_pos: Vector2 = direction * clamped_distance

	# Apply lag proportional to cursor speed.
	# Random glances are deliberately slower, especially far from the cursor.
	var gaze_speed: float = 1.0
	if _random_gaze_active:
		gaze_speed = _random_gaze_speed

	var effective_lag: float = (
		base_lag_speed / (1.0 + mouse_speed * speed_lag_factor)
		* gaze_speed
	)
	current_iris_local_pos = current_iris_local_pos.lerp(
		target_local_pos,
		clampf(effective_lag * delta, 0.0, 1.0)
	)
	iris.position = current_iris_local_pos

	if (
		_random_gaze_active
		and _random_look_returning
		and current_iris_local_pos.distance_to(target_local_pos) < 1.0
	):
		_random_gaze_active = false
		_random_look_returning = false
		_random_gaze_speed = 1.0

	# Mimic 3D sphere curvature. The iris squashes along the gaze axis.
	var iris_scale: Vector2 = _current_iris_scale()
	iris.scale = Vector2(
		original_iris_scale.x * iris_scale.x,
		original_iris_scale.y * iris_scale.y
	)

	# The iris stays upright; the eye jitter only moves it.
	iris.rotation = 0.0

	# Hover drift toward the gaze.
	_hover_offset = Vector2.ZERO
	if max_iris_radius > 0.0:
		_hover_offset = (
			current_iris_local_pos / max_iris_radius * gaze_hover_sway
		)

	# Squash, stretch and bob the whole Consul before re-cutting the eyelid.
	_anim_time += delta
	var breath: float = sin(_anim_time * breath_speed) * breath_amount
	var bob: float = sin(_anim_time * idle_bob_speed) * idle_bob_height

	if body != null:
		body.scale = Vector2(
			_body_base_scale.x * (1.0 - breath + _squash * 0.5),
			_body_base_scale.y * (1.0 + breath - _squash * 0.5)
		)
		body.position = (
			_body_base_position
			+ _hover_offset
			+ Vector2(0.0, _bounce + bob)
		)
		body.rotation = 0.0
		if max_iris_radius > 0.0:
			body.rotation = (
				current_iris_local_pos.x / max_iris_radius
				* deg_to_rad(gaze_hover_tilt_degrees)
			)

	# Hands hover at the sides and follow a fraction of the body's drift.
	var hand_tilt: float = 0.0
	if max_iris_radius > 0.0:
		hand_tilt = (
			current_iris_local_pos.x / max_iris_radius
			* deg_to_rad(hand_gaze_tilt_degrees)
		)
	if left_hand != null:
		left_hand.position = (
			_hand_left_base
			+ _hover_offset * hand_gaze_sway
			+ Vector2(
				0.0,
				sin(_anim_time * hand_bob_speed) * hand_bob_height
			)
		)
		left_hand.rotation = hand_tilt
	if right_hand != null:
		right_hand.position = (
			_hand_right_base
			+ _hover_offset * hand_gaze_sway
			+ Vector2(
				0.0,
				sin(_anim_time * hand_bob_speed + PI * 0.6)
				* hand_bob_height
			)
		)
		right_hand.rotation = hand_tilt

	# Pointing and waving override the normal hand tilt.
	if _point_target != null:
		var point_hand: Sprite2D = (
			left_hand if _point_hand_index == 0 else right_hand
		)
		if point_hand != null:
			var to_point: Vector2 = _point_target - point_hand.global_position
			if to_point.length_squared() > 0.001:
				var point_rotation: float = to_point.angle()
				if point_hand == right_hand and point_hand.flip_h:
					point_rotation -= PI
				point_hand.rotation = point_rotation
	elif _wave_remaining > 0.0:
		_wave_remaining -= delta
		var wave: float = (
			sin((_wave_duration - _wave_remaining) * 22.0)
			* deg_to_rad(18.0)
		)
		if left_hand != null:
			left_hand.rotation = hand_tilt - wave * 0.5
		if right_hand != null:
			right_hand.rotation = hand_tilt + wave

	# Cut the eyelid with the same centre and squash as the iris.
	_update_eyelid_cutout(iris_scale)


## Points a hand at a global screen position and looks at it.
func point_at_screen(screen_position: Vector2, hand_index: int = 0) -> void:
	set_gaze_target_position(screen_position)
	_point_target = screen_position
	_point_hand_index = hand_index

	var hand: Sprite2D = left_hand if hand_index == 0 else right_hand
	if hand != null:
		_apply_hand_gesture(hand, HandGesture.POINT_SIDE)


## Points at any Control, Node2D or Node3D.
func point_at_node(node: Node, hand_index: int = 0) -> void:
	if node == null:
		return

	point_at_screen(screen_position_of(node), hand_index)


## Stops the current pointing override.
func clear_point() -> void:
	_point_target = null


## Screen-space centre of a Control/Node2D, or the projection of a Node3D.
func screen_position_of(node: Node) -> Vector2:
	if node is Control:
		return (node as Control).get_global_rect().get_center()
	if node is Node2D:
		return (node as Node2D).global_position
	if node is Node3D:
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			return camera.unproject_position((node as Node3D).global_position)
	return Vector2.ZERO


## Waves a hand for the given duration.
func wave_goodbye(duration: float = 1.0) -> void:
	_point_target = null
	_wave_duration = maxf(duration, 0.1)
	_wave_remaining = _wave_duration
	set_hand_gestures(HandGesture.PALM_EXPLAIN, HandGesture.PALM_EXPLAIN)


## Tweens the Consul root to a local position in its parent.
func move_to_local(target: Vector2, duration: float = 0.6) -> void:
	# The shader hole follows the iris from _process, so keep processing while
	# moving even if the view had paused Consul.
	set_process(true)
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "position", target, duration)


## Moves near a node, with an offset in the Consul's parent space.
func move_toward_node(
	node: Node,
	offset: Vector2 = Vector2(-220.0, 0.0),
	duration: float = 0.6
) -> void:
	if node == null or get_parent() == null:
		return

	var target_global: Vector2 = screen_position_of(node)
	var target_local: Vector2 = target_global
	var parent := get_parent()
	if parent is CanvasItem:
		target_local = (
			(parent as CanvasItem).get_global_transform().affine_inverse()
			* target_global
		)
	move_to_local(target_local + offset, duration)


## Samples the cursor every gaze_poll_interval, then follows continuously while
## the cursor keeps moving. Idle samples sometimes glance somewhere random, and
## a random glance is held for 0.5-1.0 s unless the cursor moves.
func _update_gaze(
	delta: float,
	mouse_pos: Vector2,
	mouse_speed: float
) -> void:
	var travelled: float = mouse_pos.distance_to(_last_polled_mouse)
	var cursor_moved: bool = (
		mouse_speed > follow_speed_threshold
		or travelled > follow_move_threshold
	)

	# Hold a random glance, but abandon it as soon as the cursor moves.
	if _random_look_hold > 0.0:
		if cursor_moved:
			_random_look_hold = 0.0
			_random_gaze_active = false
			_random_look_returning = false
			_random_gaze_speed = 1.0
			_last_polled_mouse = mouse_pos
			gaze_target_global = mouse_pos
			_following_cursor = true
			_cursor_still_timer = 0.0
			return

		_random_look_hold -= delta
		if _random_look_hold <= 0.0:
			# Pause is over: return to the cursor and resume polling.
			_last_polled_mouse = mouse_pos
			gaze_target_global = mouse_pos
			_following_cursor = false
			_random_look_returning = true
			_gaze_poll_timer = 0.0
		return

	if _following_cursor:
		gaze_target_global = mouse_pos
		_last_polled_mouse = mouse_pos

		if mouse_speed > follow_speed_threshold:
			_cursor_still_timer = 0.0
		else:
			_cursor_still_timer += delta
			if _cursor_still_timer >= follow_settle_time:
				_following_cursor = false
				_gaze_poll_timer = 0.0
		return

	_gaze_poll_timer += delta
	if _gaze_poll_timer < gaze_poll_interval:
		return

	_gaze_poll_timer = 0.0
	_last_polled_mouse = mouse_pos

	if cursor_moved:
		gaze_target_global = mouse_pos
		_following_cursor = true
		_cursor_still_timer = 0.0
		_random_gaze_active = false
		_random_look_returning = false
		_random_gaze_speed = 1.0
		return

	if randf() < random_look_chance:
		look_at_random()
	else:
		gaze_target_global = mouse_pos


## Chooses a target according to gaze_mode. Dialogue uses the explicit modes.
func _update_gaze_mode(
	delta: float,
	mouse_pos: Vector2,
	mouse_speed: float
) -> void:
	match gaze_mode:
		GazeMode.AUTO:
			_update_gaze(delta, mouse_pos, mouse_speed)
		GazeMode.CURSOR:
			var radius_sq: float = gaze_cursor_radius * gaze_cursor_radius
			if mouse_pos.distance_squared_to(eyeball.global_position) <= radius_sq:
				gaze_target_global = mouse_pos
			else:
				gaze_target_global = _default_gaze_position()
			_random_gaze_active = false
		GazeMode.RANDOM:
			_gaze_random_timer -= delta
			if _gaze_random_timer <= 0.0:
				look_at_random()
				_gaze_random_timer = randf_range(
					gaze_random_interval * 0.7,
					gaze_random_interval * 1.3
				)
		GazeMode.TARGET:
			pass
		GazeMode.DEFAULT:
			gaze_target_global = _default_gaze_position()


func _default_gaze_position() -> Vector2:
	if is_instance_valid(_default_gaze_node):
		return screen_position_of(_default_gaze_node)
	return default_gaze_target


## Switches gaze behaviour at runtime.
func set_gaze_mode(mode: GazeMode) -> void:
	gaze_mode = mode
	if mode == GazeMode.RANDOM:
		_gaze_random_timer = 0.0


func set_gaze_auto() -> void:
	set_gaze_mode(GazeMode.AUTO)


func set_gaze_random() -> void:
	set_gaze_mode(GazeMode.RANDOM)


func set_gaze_cursor(radius: float = -1.0) -> void:
	if radius >= 0.0:
		gaze_cursor_radius = radius
	set_gaze_mode(GazeMode.CURSOR)


func set_gaze_default_mode() -> void:
	set_gaze_mode(GazeMode.DEFAULT)


func set_gaze_target_position(world_position: Vector2) -> void:
	gaze_target_global = world_position
	_random_look_hold = 0.0
	_random_gaze_active = false
	_random_look_returning = false
	_random_gaze_speed = 1.0
	_following_cursor = false
	gaze_mode = GazeMode.TARGET


func set_gaze_target_node(node: Node) -> void:
	if node != null:
		set_gaze_target_position(screen_position_of(node))


func set_gaze_default_position(world_position: Vector2) -> void:
	default_gaze_target = world_position
	_default_gaze_node = null
	set_gaze_mode(GazeMode.DEFAULT)


func set_gaze_default_node(node: Node) -> void:
	_default_gaze_node = node
	if node != null:
		set_gaze_mode(GazeMode.DEFAULT)


## Glances at a random point inside random_look_radius.
func look_at_random() -> void:
	if eyeball == null:
		return

	var angle: float = randf() * TAU
	var reach: float = minf(random_look_radius, max_iris_radius)
	var radius: float = sqrt(randf()) * reach
	gaze_target_global = (
		eyeball.global_position
		+ Vector2(cos(angle), sin(angle)) * radius
	)
	_following_cursor = false

	var pause_min: float = minf(
		random_look_pause_min,
		random_look_pause_max
	)
	var pause_max: float = maxf(
		random_look_pause_min,
		random_look_pause_max
	)
	_random_look_hold = randf_range(pause_min, pause_max)

	# Distant glances are deliberately slower, outbound and on the way back.
	var cursor: Vector2 = get_global_mouse_position()
	_random_gaze_speed = _random_gaze_speed_for(
		gaze_target_global.distance_to(cursor)
	)
	_random_gaze_active = true
	_random_look_returning = false


## 1.0 when the glance is at the cursor, random_look_slowdown when it is
## random_look_slowdown_distance away or farther.
func _random_gaze_speed_for(distance: float) -> float:
	var slowdown: float = clampf(
		distance / maxf(random_look_slowdown_distance, 1.0),
		0.0,
		1.0
	)
	return lerpf(1.0, random_look_slowdown, slowdown)


## Forces the eye to look at a world-space point until told otherwise.
func look_at_position(world_position: Vector2) -> void:
	gaze_target_global = world_position
	_following_cursor = false
	_cursor_still_timer = 0.0
	_random_look_hold = 0.0
	_random_gaze_active = false
	_random_look_returning = false
	_random_gaze_speed = 1.0


## Immediately locks the eye onto the cursor and keeps following it.
func follow_cursor() -> void:
	gaze_target_global = get_global_mouse_position()
	_following_cursor = true
	_cursor_still_timer = 0.0
	_random_look_hold = 0.0
	_random_gaze_active = false
	_random_look_returning = false
	_random_gaze_speed = 1.0


## Blends the eyelid opening to a named emotion preset.
func play_emotion(value: Emotion, blend_time: float = -1.0) -> void:
	var preset: Vector2 = EMOTION_PRESETS[Emotion.NEUTRAL]

	if EMOTION_PRESETS.has(value):
		preset = EMOTION_PRESETS[value]

	current_emotion = value

	if gestures_follow_emotion and EMOTION_HAND_GESTURES.has(value):
		var gestures: Array = EMOTION_HAND_GESTURES[value]
		set_hand_gestures(gestures[0], gestures[1])

	if blend_time < 0.0:
		blend_time = emotion_blend_time

	if _emotion_tween != null and _emotion_tween.is_valid():
		_emotion_tween.kill()

	if blend_time <= 0.0:
		eye_socket_width_scale = preset.x
		eye_socket_height_scale = preset.y
		_update_eyelid_cutout(_current_iris_scale())
		return

	_emotion_tween = create_tween().set_parallel(true)
	_emotion_tween.tween_property(
		self,
		"eye_socket_width_scale",
		preset.x,
		blend_time
	)
	_emotion_tween.tween_property(
		self,
		"eye_socket_height_scale",
		preset.y,
		blend_time
	)
	_play_squash(emotion_squash, blend_time * 1.4)
	_play_bounce(bounce_height, blend_time * 1.8)


func _update_blink(delta: float) -> void:
	if not blink_enabled:
		return

	_blink_timer -= delta
	if (
		_blink_timer <= 0.0
		and (_blink_tween == null or not _blink_tween.is_valid())
	):
		blink()
		_schedule_blink()


func _schedule_blink() -> void:
	_blink_timer = randf_range(blink_interval_min, blink_interval_max)


## Quickly closes and reopens the eyelid opening.
func blink() -> void:
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()

	_blink_tween = create_tween()
	_blink_tween.tween_property(
		self,
		"_blink_amount",
		1.0,
		blink_duration * 0.35
	)
	_blink_tween.tween_property(
		self,
		"_blink_amount",
		0.0,
		blink_duration * 0.65
	)

	_play_squash(blink_squash, blink_duration * 1.6)
	_play_bounce(bounce_height * 0.5, blink_duration * 2.2)


## Quick squash-and-stretch pulse. Positive values squash vertically.
func squash(amount: float = 0.4, duration: float = 0.35) -> void:
	_play_squash(amount, duration)


## Vertical bounce. Height is in pixels.
func bounce(height: float = 5.0, duration: float = 0.5) -> void:
	_play_bounce(height, duration)


func _play_squash(amount: float, duration: float) -> void:
	if _squash_tween != null and _squash_tween.is_valid():
		_squash_tween.kill()

	_squash_tween = create_tween()
	_squash_tween.tween_property(
		self,
		"_squash",
		amount,
		maxf(duration * 0.35, 0.01)
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_squash_tween.tween_property(
		self,
		"_squash",
		0.0,
		maxf(duration * 0.65, 0.01)
	).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _play_bounce(height: float, duration: float) -> void:
	if _bounce_tween != null and _bounce_tween.is_valid():
		_bounce_tween.kill()

	_bounce_tween = create_tween()
	_bounce_tween.tween_property(
		self,
		"_bounce",
		-height,
		maxf(duration * 0.35, 0.01)
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_bounce_tween.tween_property(
		self,
		"_bounce",
		0.0,
		maxf(duration * 0.65, 0.01)
	).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


## Applies a gesture to both hands at once.
func set_hand_gestures(left: HandGesture, right: HandGesture) -> void:
	left_hand_gesture = left
	right_hand_gesture = right


func _apply_hand_gesture(node: Sprite2D, gesture: HandGesture) -> void:
	if node == null:
		return

	var texture: Texture2D = HAND_GESTURE_TEXTURES.get(gesture, null)
	if texture != null:
		node.texture = texture
