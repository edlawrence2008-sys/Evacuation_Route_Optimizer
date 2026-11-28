extends CharacterBody3D

## Cheap, non-directional wanderer tuned for running hundreds to 1000+ instances.
##
## Performance notes:
## - Scare detection uses a cached tree-group list plus a squared-distance test,
##   so no per-animal physics shape query is performed (this was previously the
##   dominant cost by an order of magnitude at high NPC counts).
## - The cached group list is refreshed at most every `vision_group_cache_frames`
##   physics ticks and shared by every animal using that group.
## - Gravity and turn direction are cached once in `_ready()`.
## - `move_and_slide()` is skipped while grounded and standing still.
## - The eye/floor probes are the only per-animal physics queries left.
## - The old SpeedJumpComponent is folded into this script (no extra node or
##   physics callback per animal).
## - Calm animals randomly idle; idle updates skip both probes and the move
##   solver, so a herd spends less time in physics work.

## Configuration
@export var is_left_handed: bool = false
@export var scare_groups: Array[String] = ["player", "enemy", "monster"]

## Speeds
@export var base_speed: float = 1.5
@export var max_speed: float = 8.0
@export var turn_speed: float = 2.0

## Uncomfortability Settings
@export var uncomfortability: float = 0.0  # Ranges from 0.0 to 1.0
@export var uncomfortability_increase_rate: float = 0.5
@export var uncomfortability_decay_rate: float = 0.2

## Oscillation (Wander) Settings
@export var sway_frequency: float = 3.0  # How fast it sways back and forth
@export var max_sway_angle: float = 1.5   # Turning strength at 0 uncomfortability

## Performance Settings
@export_range(1, 10, 1) var vision_update_interval: int = 2
@export_range(1, 120, 1) var vision_group_cache_frames: int = 10
@export var vision_radius: float = 5.0
@export var enable_vision_check: bool = true
@export var skip_move_and_slide_when_idle: bool = true

## Distance LOD (updates far animals less often; physics interpolation keeps
## their motion smooth). Near animals always run at the full physics rate.
@export var enable_distance_lod: bool = true
@export var lod_near_distance: float = 15.0
@export var lod_mid_distance: float = 35.0
@export var lod_far_distance: float = 70.0
@export var lod_sleep_distance: float = 140.0
@export_range(1, 32, 1) var lod_max_stride: int = 16

## Idle behaviour (only while calm). Calm animals randomly stop, look around,
## and start moving again. Idle animals skip their probes and move solver.
@export var enable_idle: bool = true
@export var idle_max_uncomfortability: float = 0.15
@export_range(0.0, 1.0, 0.01) var idle_chance_per_second: float = 0.12
@export var idle_min_duration: float = 1.5
@export var idle_max_duration: float = 6.0
@export var idle_look_interval_min: float = 0.5
@export var idle_look_interval_max: float = 1.8
@export var idle_look_angle: float = 1.2
@export var idle_look_speed: float = 1.2

## Speed Jump (stuck recovery)
## The old SpeedJumpComponent is folded into this script so it costs no extra
## node or physics callback. When the body is grounded and its actual horizontal
## speed stays near zero, it hops to clear small obstacles.
@export var enable_speed_jump: bool = true
## 0 uses this animal's current intended speed. A positive fixed value is the
## safe option: a fraction of a fleeing animal's 8 m/s speed is far above the
## half-speed it uses while turning, which causes constant bunny-hopping.
@export var jump_target_speed: float = 1.0
@export_range(0.1, 1.0) var jump_speed_threshold_ratio: float = 0.1
## How long the actual speed must stay below the threshold before jumping.
## This also prevents a single zero-speed frame (spawn, landing) from hopping.
@export var jump_stuck_time: float = 0.1
@export var jump_cooldown: float = 0.4
@export var jump_velocity: float = 5.5

## Build Catalog Metadata (read by BuildController when placed as a placeable)
@export_multiline var description: String = "A skittish animal that wanders the level, stops to look around when calm, and hops over small obstacles. It flees faster when a configured scare group is nearby."
@export var requires_voxel_below: bool = true
@export var grid_xz_offset: Vector2 = Vector2.ZERO

var sway_timer: float = 0.0

@onready var eye_ray: ShapeCast3D = $Eyeray
@onready var floor_cast: RayCast3D = $FloorCast

# Cached state (avoids per-tick allocations, String conversions and physics queries).
var _scare_group_names: Array[StringName] = []
var _turn_direction: float = -1.0
var _gravity: Vector3 = Vector3.ZERO
var _sees_scary: bool = false
var _vision_ticks_left: int = 1
var _vision_interval: int = 2
var _stride: int = 1
var _ticks_until_update: int = 0
var _jump_cooldown_left: float = 0.0
var _stuck_time: float = 0.0
var _stuck_samples: int = 0
var _idle: bool = false
var _idle_time_left: float = 0.0
var _idle_roll_left: float = 1.0
var _look_time_left: float = 0.0
var _look_yaw: float = 0.0

# Shared across every animal instance: group name -> node list / refresh frame.
static var _group_cache_nodes: Dictionary = {}
static var _group_cache_frame: Dictionary = {}

# Shared player lookup for the distance LOD.
static var _player_cache: Node3D = null
static var _player_cache_frame: int = -1000000


func _ready() -> void:
	_turn_direction = 1.0 if is_left_handed else -1.0
	_gravity = get_gravity()
	_vision_interval = maxi(vision_update_interval, 1)
	# Stagger instances so they never all refresh their vision or move on the
	# same tick.
	_vision_ticks_left = 1 + (get_instance_id() % _vision_interval)
	_ticks_until_update = (
		get_instance_id() % mini(maxi(lod_max_stride, 1), 8)
		if enable_distance_lod
		else 0
	)
	for group_name in scare_groups:
		_scare_group_names.append(StringName(group_name))
	_idle_roll_left = randf_range(0.5, 2.0)
	_look_yaw = rotation.y
	# Query the probes on demand from active LOD updates instead of every tick.
	eye_ray.enabled = false
	floor_cast.enabled = false


func _physics_process(delta: float) -> void:
	# Distance LOD: far animals solve at a lower rate, with the skipped time
	# folded into this step. Physics interpolation keeps them visually smooth.
	if _ticks_until_update > 0:
		_ticks_until_update -= 1
		return

	# 1. Remember the previous solve's state for stuck detection and LOD.
	var on_floor := is_on_floor()
	_stride = _compute_update_stride(on_floor)
	_ticks_until_update = _stride - 1
	var step_delta: float = delta * _stride

	var horizontal_speed_sq: float = (
		velocity.x * velocity.x + velocity.z * velocity.z
	)

	# 2. Throttled vision check. The cached flag is still applied every update
	#    so uncomfortability changes smoothly.
	_vision_ticks_left -= 1
	if _vision_ticks_left <= 0:
		_vision_ticks_left = _vision_interval
		_sees_scary = _check_for_scary_objects()

	if _sees_scary:
		uncomfortability = minf(uncomfortability + uncomfortability_increase_rate * step_delta, 1.0)
	else:
		uncomfortability = maxf(uncomfortability - uncomfortability_decay_rate * step_delta, 0.0)

	# 3. Calm idle state. Idle animals skip probes and the move solver entirely.
	if _idle:
		if _sees_scary or uncomfortability > idle_max_uncomfortability:
			_idle = false
			_idle_roll_left = randf_range(0.5, 2.0)
			# React/resume on the very next tick, not after the LOD gap.
			_ticks_until_update = 0
		else:
			_update_idle(step_delta)
			velocity.x = 0.0
			velocity.z = 0.0
			velocity.y = 0.0
			return
	elif (
		enable_idle
		and on_floor
		and not _sees_scary
		and uncomfortability <= idle_max_uncomfortability
	):
		_idle_roll_left -= step_delta
		if _idle_roll_left <= 0.0:
			_idle_roll_left = 1.0
			if randf() < idle_chance_per_second:
				_enter_idle()
				velocity.x = 0.0
				velocity.z = 0.0
				velocity.y = 0.0
				return

	# 4. Determine base movement speed based on uncomfortability
	var current_speed: float = base_speed + (max_speed - base_speed) * uncomfortability

	# 5. Check environmental conditions (probes are forced on demand).
	floor_cast.force_raycast_update()
	if not floor_cast.is_colliding():
		# Complete stop while turning when no floor is detected directly ahead
		current_speed = 0.0
		rotate_y(_turn_direction * turn_speed * step_delta)
	else:
		eye_ray.force_shapecast_update()
		if eye_ray.is_colliding() or not on_floor:
			# Slow down to half speed and turn when hitting a wall OR mid-air
			current_speed *= 0.5
			rotate_y(_turn_direction * turn_speed * step_delta)
		else:
			# Apply directional oscillation when path is clear on the ground
			sway_timer += step_delta * sway_frequency
			rotate_y(sin(sway_timer) * max_sway_angle * (1.0 - uncomfortability) * step_delta)

	# 6. Vertical motion + speed jump (the old SpeedJumpComponent behaviour).
	_jump_cooldown_left = maxf(_jump_cooldown_left - step_delta, 0.0)
	var jump_now := false
	if on_floor:
		jump_now = _update_speed_jump(
			horizontal_speed_sq,
			current_speed,
			step_delta
		)
		if jump_now:
			velocity.y = jump_velocity
			_jump_cooldown_left = jump_cooldown
			# Land/fall physics must resume next tick, not after the LOD gap.
			_ticks_until_update = 0
		else:
			velocity.y = 0.0
	else:
		_stuck_time = 0.0
		_stuck_samples = 0
		velocity += _gravity * step_delta

	# 7. Move continuously forward relative to local transform.
	# Skipping the solver while grounded and perfectly still is free.
	if current_speed == 0.0 and on_floor and skip_move_and_slide_when_idle:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	# The basis is orthonormal, so no normalize() call is required.
	var basis: Basis = transform.basis
	velocity.x = -basis.z.x * current_speed
	velocity.z = -basis.z.z * current_speed

	# move_and_slide() integrates one physics tick; scale horizontal velocity so
	# this update covers all skipped ticks. Vertical motion is never scaled:
	# airborne bodies always run at stride 1, so this only affects a jump tick.
	if _stride > 1:
		velocity.x *= _stride
		velocity.z *= _stride
	move_and_slide()
	if _stride > 1:
		velocity.x /= _stride
		velocity.z /= _stride


## Returns how many physics ticks to skip before the next update, based on the
## distance to the player. 1 = every tick.
func _compute_update_stride(on_floor: bool) -> int:
	if not enable_distance_lod:
		return 1
	# Airborne bodies must integrate gravity every physics tick.
	if not on_floor:
		return 1

	var player := _get_cached_player()
	if player == null:
		return 1

	var max_stride := maxi(lod_max_stride, 1)
	var distance_sq := global_position.distance_squared_to(player.global_position)
	if distance_sq <= lod_near_distance * lod_near_distance:
		return 1
	if distance_sq <= lod_mid_distance * lod_mid_distance:
		return 2
	if distance_sq <= lod_far_distance * lod_far_distance:
		return mini(max_stride, 4)
	if distance_sq <= lod_sleep_distance * lod_sleep_distance:
		return mini(max_stride, 8)
	return max_stride


## Tracks how long the body has been trying to move but staying near zero
## speed. Returns true only after the stuck state has lasted `jump_stuck_time`
## (sampled at least twice), so spawn/landing frames do not trigger a hop.
## A positive `jump_target_speed` reproduces the old fixed-target component;
## 0 compares against the animal's own intended speed instead.
func _update_speed_jump(
	horizontal_speed_sq: float,
	intended_speed: float,
	step_delta: float
) -> bool:
	if not enable_speed_jump or intended_speed <= 0.001:
		_stuck_time = 0.0
		_stuck_samples = 0
		return false

	var target: float = (
		jump_target_speed if jump_target_speed > 0.0 else intended_speed
	)
	var threshold: float = target * jump_speed_threshold_ratio
	if horizontal_speed_sq >= threshold * threshold:
		_stuck_time = 0.0
		_stuck_samples = 0
		return false

	_stuck_time += step_delta
	_stuck_samples += 1
	if (
		_stuck_samples < 2
		or _stuck_time < jump_stuck_time
		or _jump_cooldown_left > 0.0
	):
		return false

	_stuck_time = 0.0
	_stuck_samples = 0
	return true


## One shared player lookup per 30 physics frames instead of one per animal.
func _get_cached_player() -> Node3D:
	var frame := Engine.get_physics_frames()
	if (
		frame - _player_cache_frame >= 30
		or (_player_cache != null and not is_instance_valid(_player_cache))
	):
		_player_cache_frame = frame
		_player_cache = (
			get_tree().get_first_node_in_group("player") as Node3D
		)
	return _player_cache


## Starts a calm idle pause with a random duration.
func _enter_idle() -> void:
	_idle = true
	_idle_time_left = randf_range(
		minf(idle_min_duration, idle_max_duration),
		maxf(idle_min_duration, idle_max_duration)
	)
	_look_time_left = 0.0
	_stuck_time = 0.0
	_stuck_samples = 0


## Advances the idle pause and smoothly turns toward a random look direction.
func _update_idle(step_delta: float) -> void:
	_idle_time_left -= step_delta
	if _idle_time_left <= 0.0:
		_idle = false
		_idle_roll_left = randf_range(1.0, 3.0)
		# Start moving again on the next tick instead of after the LOD gap.
		_ticks_until_update = 0
		return

	_look_time_left -= step_delta
	if _look_time_left <= 0.0:
		_look_time_left = randf_range(
			minf(idle_look_interval_min, idle_look_interval_max),
			maxf(idle_look_interval_min, idle_look_interval_max)
		)
		_look_yaw = rotation.y + randf_range(-idle_look_angle, idle_look_angle)

	rotation.y += clampf(
		angle_difference(rotation.y, _look_yaw),
		-idle_look_speed * step_delta,
		idle_look_speed * step_delta
	)


## True when any node in the configured scare groups is within `vision_radius`.
## Uses a shared, periodically refreshed group cache and a squared-distance
## test, avoiding a physics shape query per animal per tick.
func _check_for_scary_objects() -> bool:
	if not enable_vision_check:
		return false

	var tree := get_tree()
	if tree == null:
		return false

	var frame := Engine.get_physics_frames()
	var origin := global_position
	var radius_sq: float = vision_radius * vision_radius
	var cache_frames: int = maxi(vision_group_cache_frames, 1)

	for group_name in _scare_group_names:
		var last_frame := int(_group_cache_frame.get(group_name, -1000000))
		var nodes: Array
		if (
			frame - last_frame >= cache_frames
			or not _group_cache_nodes.has(group_name)
		):
			nodes = tree.get_nodes_in_group(group_name)
			_group_cache_nodes[group_name] = nodes
			_group_cache_frame[group_name] = frame
		else:
			nodes = _group_cache_nodes[group_name]

		for node in nodes:
			if not is_instance_valid(node):
				continue
			if not node is Node3D:
				continue
			if (
				origin.distance_squared_to((node as Node3D).global_position)
				<= radius_sq
			):
				return true

	return false
