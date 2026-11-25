extends CharacterBody3D

# ============================================================
# COMPONENT REFERENCES
# ============================================================

@onready var animator: ProceduralAnimator = $LeanAnimator
@onready var health_component: HealthComponent = $HealthComponent


# ============================================================
# EXPORTS
# ============================================================

@export_group("Personality & Stats")
@export var npc_name: String = "Villager"
@export var movement_speed: float = 3.0
@export var enable_energy: bool = false
@export var energy: float = 100.0
@export var hunger: float = 0.0

@export_group("Individuality & Variety")
@export var max_extra_speed: float = 2.5
@export var max_extra_lane_offset: float = 0.5
@export var max_extra_separation_radius: float = 0.5
@export var max_extra_separation_push: float = 1.0

@export_group("Crowd Dynamics")
@export var enable_crowd_damage: bool = false
@export var crowd_threshold: int = 10
@export var crush_damage_per_sec: float = 0.5
@export var max_neighbors: int = 16
@export var max_vertical_neighbor_distance: float = 1.5
## When enabled, a higher-instance-ID agent backs off to break a crowd
## deadlock. Disable to make agents keep their line and rely on collision.
@export var allow_yielding: bool = true

@export_group("Water & Hazards")
## Fraction of walking speed lost when fully submerged.
@export_range(0.0, 0.95, 0.01) var water_speed_loss: float = 0.65
## How strongly the local water flow drags the agent when submerged.
@export_range(0.0, 12.0, 0.1) var water_drag: float = 2.5
## How often depth/flow/hazard are sampled. 5-10 Hz is enough; the values move
## smoothly compared with the 30 Hz physics tick.
@export var water_query_interval: float = 0.15
@export var hazard_query_interval: float = 0.25
## Damage per second at full LPG concentration and at full fire heat.
## FireComponent already applies direct radius damage, so heat damage defaults
## to zero; raise it only if HazardWorld is the sole fire-damage source.
@export var gas_damage_per_sec: float = 8.0
@export var heat_damage_per_sec: float = 0.0

@export_group("Collision")
## When enabled, a stuck NPC may briefly stop colliding with other NPCs.
## When disabled, NPCs always collide with each other.
@export var allow_collision_disable: bool = false:
	set(value):
		allow_collision_disable = value
		_apply_collision_policy()

@export_group("Visual Mode")
## Draw the baked Doom-style sprite sheet instead of the 3D model.
## The 3D model and LeanAnimator are hidden/disabled while this is on.
@export var realistic_sprites_mode: bool = true:
	set(value):
		realistic_sprites_mode = value
		_apply_visual_mode()
## Scene ID under res://scenes/npcs/realistic_npcs (filename without .tscn).
@export var realistic_sprite: StringName = &"random":
	set(value):
		realistic_sprite = value
		_apply_visual_mode()
## World size of one sprite-sheet pixel. The sheet cell is 400 x 700 px.
@export_range(0.0005, 0.02, 0.0001) var sprite_pixel_size: float = 0.0042:
	set(value):
		sprite_pixel_size = maxf(value, 0.0001)
		_sync_sprite_settings()
## Playback rate of the walk clips. The imported clips are authored at 5 FPS.
@export_range(1.0, 30.0, 0.5) var sprite_walk_fps: float = 5.0:
	set(value):
		sprite_walk_fps = maxf(value, 1.0)
		_sync_sprite_settings()
## Local-space nudge applied on top of the per-frame floor alignment.
## Use Y to lift or sink the sprite.
@export var sprite_offset: Vector3 = Vector3.ZERO:
	set(value):
		sprite_offset = value
		_sync_sprite_settings()
## Whether the sprite receives 3D lighting instead of rendering unshaded.
@export var sprite_shaded: bool = true:
	set(value):
		sprite_shaded = value
		_sync_sprite_settings()

@export_group("Sprite Lighting")
## Per-agent multiplier on the shared sun-side rim strength.
@export_range(0.0, 1.0, 0.01) var sprite_rim_strength: float = 1.0:
	set(value):
		sprite_rim_strength = clampf(value, 0.0, 1.0)
		_sync_sprite_settings()
## Per-agent multiplier on the shared complementary bounce strength.
@export_range(0.0, 4.0, 0.01) var sprite_bounce_strength: float = 1.0:
	set(value):
		sprite_bounce_strength = maxf(value, 0.0)
		_sync_sprite_settings()
## Whether this agent's sprite material uses its normal map.
@export var sprite_normal_enabled: bool = true:
	set(value):
		sprite_normal_enabled = value
		_sync_sprite_settings()
## Per-agent multiplier on the sprite's normal-map strength.
@export_range(0.0, 4.0, 0.01) var sprite_normal_strength: float = 1.0:
	set(value):
		sprite_normal_strength = maxf(value, 0.0)
		_sync_sprite_settings()

@export_group("Path Diversity")
@export var lane_offset_strength: float = 0.0
@export var separation_push: float = 2.0
@export var separation_radius: float = 1.0

@export_group("AI State")
@export var is_evacuee: bool = true
@export var evac_shortlist_size: int = 3
@export var evac_choice_tolerance: float = 5
@export var evac_confirm_timeout: float = 3.0
@export var max_evacuation_failures: int = 3
@export var failed_evac_point_cooldown: float = 5.0

@export_group("Movement & Physics")
## When false, this agent never uses the automatic obstacle hop or the random
## stuck-hop. It still follows paths and falls normally.
@export var allow_jumping: bool = true
@export var jump_force: float = 6.0
@export var jump_push_force: float = 3.0
@export var stuck_time_threshold: float = 0.5
@export var jump_cooldown: float = 1.5
@export var stuck_progress_ratio: float = 0.25
@export var obstacle_hop_cooldown: float = 0.4
@export var waypoint_arrival_distance: float = 0.3


# ============================================================
# STATE & NAVIGATION
# ============================================================

enum State {
	IDLE,
	WANDERING,
	SEEKING_FOOD,
	SEEKING_REST,
	SEEKING_EVAC,
	ARRIVED,
	DEAD,
}

var current_state: State = State.IDLE
var gravity: float = ProjectSettings.get_setting(
	"physics/3d/default_gravity"
)

var gridmap: NavGridMap = null
var crowd_manager: Node = null
var evacuation_manager: Node = null

var current_path: PackedVector3Array = PackedVector3Array()
var path_index: int = 0
var is_awaiting_path: bool = false
var wait_timer: float = 0.0
var _repath_pending: bool = false

## Flow-field steering: no per-NPC path is built or smoothed.
var _flow_active: bool = false
var _flow_target: Vector3 = Vector3.ZERO
var _flow_target_cell: Vector3i = Vector3i.ZERO
var _flow_wait: float = 0.0

var actual_movement_speed: float = 4.0
var actual_separation_radius: float = 1.0
var actual_separation_push: float = 2.0

## Last unified environment sample. `water` is the WaterWorld sample; `gas`
## and `heat` come from HazardWorld. Empty when neither system is present.
var _environment_sample: Dictionary = {}
var _water_sample: Dictionary = {}
var _environment_accum: float = 0.0
var _was_in_water: bool = false

var lane_offset: float = 0.0
var _crowd_push: Vector3 = Vector3.ZERO
var local_density: float = 0.0

var _stuck_strikes: int = 0
var _stuck_sample_index: int = -1
var _stuck_sample_dist: float = 0.0
var stuck_timer: float = 0.0
var jump_cooldown_timer: float = 0.0
var _obstacle_hop_timer: float = 0.0
var logic_tick_timer: float = 0.0

var _layer_2_disabled: bool = false
var _movement_accum: float = 0.0

const SPRITE_LIBRARY = preload(
	"res://scripts/NPCstuff/RealisticSpriteLibrary.gd"
)
const SPRITE_VISUAL_SCRIPT: Script = preload(
	"res://scripts/NPCstuff/SpriteMemberVisual.gd"
)

## Sprite-mode visual. Created lazily so 3D-mode agents pay no node cost.
var _sprite_visual: AnimatedSprite3D = null
var _sprite_id: StringName = &""
var _sprite_hurt_tween: Tween = null

## Metrics recorded for the evacuation results panel.
var _distance_travelled: float = 0.0
var _stuck_time_total: float = 0.0
var _peak_density: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _has_last_position: bool = false

const LOGIC_TICK_RATE: float = 0.15
const FALL_CHECK_INTERVAL: float = 0.25
## A pushed agent this far off the path requests a fresh path instead of
## walking backwards to the waypoint it already passed.
const CORNER_REPATH_DISTANCE: float = 0.75
const CORNER_REPATH_INTERVAL: float = 1.0
## Blocks below a chunk's lowest block before the agent is killed.
const FALL_KILL_MARGIN_BLOCKS: float = 5.0
## Steering decisions run at this rate. Movement still happens every physics tick.
@export var movement_rate: float = 30.0
var _fall_check_timer: float = 0.0
var _corner_repath_timer: float = 0.0
var _last_move_direction: Vector3 = Vector3.ZERO
var _yield_timer: float = 0.0
var _yield_direction: Vector3 = Vector3.BACK
var _yield_repath_pending: bool = false
var _congestion_repath_timer: float = 0.0
var _congestion_check_timer: float = 0.0
var _detour_from_flow: bool = false
var _detour_previous_length: float = -1.0
var _stuck_sample_flow_cell: Vector3i = Vector3i.ZERO
var _has_stuck_flow_cell: bool = false

## Higher instance IDs yield to lower IDs when two agents block each other.
const YIELD_DETECT_RADIUS: float = 1.0
const YIELD_DURATION: float = 0.8
const YIELD_SPEED_SCALE: float = 0.55

## Congestion-aware detours. When the route ahead is hot, the agent asks for a
## fresh A* path whose weights already include the deadlock heat.
const CONGESTION_AVOID_THRESHOLD: float = 0.55
const CONGESTION_REPATH_INTERVAL: float = 2.0
const CONGESTION_CHECK_INTERVAL: float = 0.35
const CONGESTION_PROBE_CELL_SCALE: float = 0.9
const FLOW_STUCK_SAMPLE: int = -2

## evacuation point position -> unix-style engine time when it may be tried again
var _failed_evac_points: Dictionary = {}
var _last_evac_target: Vector3 = Vector3.ZERO
var _awaiting_evac_confirmation: bool = false
var has_evacuation_target: bool = false
var _evacuation_failures: int = 0


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	add_to_group("npc")
	_apply_collision_policy()

	crowd_manager = get_node_or_null("/root/CrowdManager")
	evacuation_manager = get_node_or_null("/root/EvacuationManager")
	_get_gridmap()

	if not GlobalData.agent_overrides.is_empty():
		_apply_export_overrides(GlobalData.agent_overrides)

	_sanitize_agent_settings()
	_refresh_derived_stats()
	_apply_visual_mode()

	if evacuation_manager and evacuation_manager.has_method("register_npc"):
		evacuation_manager.register_npc(self)

	if health_component:
		health_component.damaged.connect(_on_damaged)
		health_component.health_depleted.connect(_on_health_depleted)
		health_component.health_changed.connect(
			func(current: float, max_health: float):
				if not realistic_sprites_mode and animator:
					animator.set_health_percent(current / max_health)
		)

	is_evacuee = GlobalData.evacuation_mode
	logic_tick_timer = randf_range(0.0, LOGIC_TICK_RATE)
	call_deferred("_begin_initial_action")


func _begin_initial_action() -> void:
	# Allow the scene and navigation nodes to finish their current setup.
	await get_tree().process_frame

	if not is_inside_tree() or current_state == State.DEAD:
		return

	choose_next_action()


## Applies a dictionary of exported member properties to this live agent.
## New spawns apply GlobalData.agent_overrides in _ready(). Evacuation mode is
## owned by the Simulation panel and is intentionally ignored here.
func apply_agent_overrides(overrides: Dictionary) -> void:
	_apply_export_overrides(overrides)
	_sanitize_agent_settings()
	_refresh_derived_stats()
	_apply_visual_mode()


func _apply_export_overrides(overrides: Dictionary) -> void:
	for key: String in overrides:
		if key == "is_evacuee" or not (key in self):
			continue

		var value: Variant = overrides[key]
		var current_type: int = typeof(get(key))

		if current_type == TYPE_STRING_NAME and typeof(value) == TYPE_STRING:
			value = StringName(value)

		if typeof(value) != current_type:
			continue

		set(key, value)


func _sanitize_agent_settings() -> void:
	movement_speed = maxf(0.0, movement_speed)
	max_extra_speed = maxf(0.0, max_extra_speed)
	max_extra_lane_offset = maxf(0.0, max_extra_lane_offset)
	max_extra_separation_radius = maxf(0.0, max_extra_separation_radius)
	max_extra_separation_push = maxf(0.0, max_extra_separation_push)
	separation_radius = maxf(0.0, separation_radius)
	separation_push = maxf(0.0, separation_push)
	lane_offset_strength = maxf(0.0, lane_offset_strength)
	movement_rate = maxf(1.0, movement_rate)
	jump_force = maxf(0.0, jump_force)
	jump_push_force = maxf(0.0, jump_push_force)
	stuck_time_threshold = maxf(0.05, stuck_time_threshold)
	stuck_progress_ratio = clampf(stuck_progress_ratio, 0.0, 1.0)
	obstacle_hop_cooldown = maxf(0.0, obstacle_hop_cooldown)
	jump_cooldown = maxf(0.0, jump_cooldown)
	waypoint_arrival_distance = maxf(0.05, waypoint_arrival_distance)
	evac_shortlist_size = maxi(1, evac_shortlist_size)
	evac_choice_tolerance = maxf(1.0, evac_choice_tolerance)
	evac_confirm_timeout = maxf(0.0, evac_confirm_timeout)
	max_evacuation_failures = maxi(1, max_evacuation_failures)
	failed_evac_point_cooldown = maxf(0.0, failed_evac_point_cooldown)
	crowd_threshold = maxi(0, crowd_threshold)
	crush_damage_per_sec = maxf(0.0, crush_damage_per_sec)
	max_neighbors = maxi(1, max_neighbors)
	max_vertical_neighbor_distance = maxf(
		0.0,
		max_vertical_neighbor_distance
	)
	sprite_pixel_size = maxf(sprite_pixel_size, 0.0001)
	sprite_walk_fps = maxf(sprite_walk_fps, 1.0)
	sprite_rim_strength = clampf(sprite_rim_strength, 0.0, 1.0)
	sprite_bounce_strength = maxf(sprite_bounce_strength, 0.0)
	sprite_normal_strength = maxf(sprite_normal_strength, 0.0)


func _refresh_derived_stats() -> void:
	actual_movement_speed = maxf(0.0, movement_speed) + randf_range(
		0.0,
		maxf(0.0, max_extra_speed)
	)
	actual_separation_radius = maxf(0.0, separation_radius) + randf_range(
		0.0,
		maxf(0.0, max_extra_separation_radius)
	)
	actual_separation_push = maxf(0.0, separation_push) + randf_range(
		0.0,
		maxf(0.0, max_extra_separation_push)
	)

	var cell_size: float = gridmap.cell_size.x if gridmap else 1.0
	var effective_lane_strength: float = (
		maxf(0.0, lane_offset_strength)
		+ randf_range(0.0, maxf(0.0, max_extra_lane_offset))
	)

	lane_offset = (
		randf_range(-1.0, 1.0)
		* effective_lane_strength
		* cell_size
	)


## Switches between the 3D model + LeanAnimator and the baked sprite sheet.
func _apply_visual_mode() -> void:
	if not is_inside_tree():
		return

	if realistic_sprites_mode:
		_ensure_sprite_visual()

		if _sprite_visual == null:
			# Never leave an NPC invisible when a sprite scene cannot load.
			_set_3d_visual(true)
			return

		_sync_sprite_settings()
		_sprite_visual.call("set_active", true)
		_set_3d_visual(false)
	else:
		if _sprite_visual:
			_sprite_visual.call("set_active", false)
			if _sprite_hurt_tween != null and _sprite_hurt_tween.is_valid():
				_sprite_hurt_tween.kill()
			_sprite_visual.modulate = Color.WHITE
		_set_3d_visual(true)


func _set_3d_visual(active: bool) -> void:
	var model := get_node_or_null("blockbench_export") as Node3D

	if model:
		model.visible = active
	if animator:
		animator.set_physics_process(active)
		animator.set_process(active)


func _ensure_sprite_visual() -> void:
	var requested_id: StringName = realistic_sprite

	if String(requested_id).strip_edges().is_empty():
		requested_id = SPRITE_LIBRARY.default_id()

	if _sprite_visual != null and _sprite_id == requested_id:
		return

	if _sprite_visual != null:
		var old_visual: AnimatedSprite3D = _sprite_visual
		_sprite_visual = null
		old_visual.visible = false
		if _sprite_hurt_tween != null and _sprite_hurt_tween.is_valid():
			_sprite_hurt_tween.kill()
		# Detach immediately; a queued-free node with the same name would make
		# add_child() auto-rename the replacement visual.
		remove_child(old_visual)
		old_visual.queue_free()

	var resolved_id: StringName = requested_id
	if resolved_id == SPRITE_LIBRARY.RANDOM_ID:
		resolved_id = SPRITE_LIBRARY.pick_random_id()

	_sprite_id = &""
	var scene: PackedScene = SPRITE_LIBRARY.get_scene(resolved_id)

	if scene == null:
		push_warning(
			"Member could not load realistic sprite '%s'."
			% resolved_id
		)
		return

	_sprite_visual = scene.instantiate() as AnimatedSprite3D

	if _sprite_visual == null:
		push_warning(
			"Realistic sprite scene '%s' is not an AnimatedSprite3D."
			% resolved_id
		)
		return

	# Future variants may be plain AnimatedSprite3D scenes; attach the
	# controller before entering the tree so its _ready() runs normally.
	if not _sprite_visual.has_method("set_active"):
		_sprite_visual.set_script(SPRITE_VISUAL_SCRIPT)

	# Keep the requested ID ("random" stays random) so the chosen variant is
	# stable for this agent rather than rerolling on every refresh.
	_sprite_id = requested_id
	_sprite_visual.name = "SpriteVisual"
	add_child(_sprite_visual)
	_sync_sprite_settings()


func _sync_sprite_settings() -> void:
	if _sprite_visual == null:
		return

	_sprite_visual.pixel_size = sprite_pixel_size
	_sprite_visual.set("walk_fps", sprite_walk_fps)
	_sprite_visual.set("shaded", sprite_shaded)
	_sprite_visual.set("rim_strength", sprite_rim_strength)
	_sprite_visual.set("bounce_strength", sprite_bounce_strength)
	_sprite_visual.set("normal_enabled", sprite_normal_enabled)
	_sprite_visual.set("normal_strength", sprite_normal_strength)
	_sprite_visual.call("set_visual_offset", sprite_offset)
	_sprite_visual.call("refresh")


func _flash_sprite_hurt() -> void:
	if _sprite_visual == null or not _sprite_visual.visible:
		return

	if _sprite_hurt_tween != null and _sprite_hurt_tween.is_valid():
		_sprite_hurt_tween.kill()

	_sprite_visual.modulate = Color(1.0, 0.35, 0.35, 1.0)
	_sprite_hurt_tween = create_tween()
	_sprite_hurt_tween.tween_property(
		_sprite_visual,
		"modulate",
		Color.WHITE,
		0.18
	)


func _exit_tree() -> void:
	if is_instance_valid(gridmap):
		if gridmap.navigation_changed.is_connected(
			_on_navigation_changed
		):
			gridmap.navigation_changed.disconnect(
				_on_navigation_changed
			)


func _physics_process(delta: float) -> void:
	if current_state == State.DEAD:
		return

	_fall_check_timer -= delta
	if _fall_check_timer <= 0.0:
		_fall_check_timer = FALL_CHECK_INTERVAL
		if _is_below_chunk_floor():
			_on_health_depleted()
			return

	var env_interval: float = minf(
		maxf(water_query_interval, 0.02),
		maxf(hazard_query_interval, 0.02)
	)
	_environment_accum += delta
	if _environment_accum + 0.0001 >= env_interval:
		var elapsed := _environment_accum
		_environment_accum = 0.0
		_refresh_environment_sample(elapsed)

	_movement_accum += delta
	var interval: float = 1.0 / maxf(movement_rate, 1.0)
	var update_steering: bool = _movement_accum >= interval
	var step: float = _movement_accum
	var wants_to_move: bool = false
	var move_direction: Vector3 = Vector3.ZERO

	if update_steering:
		_movement_accum = 0.0

		_update_timers(step)

		# Another character's body is never valid ground: an agent balanced on
		# someone's head counts as airborne so it cannot walk, hop or steer
		# from on top of the crowd.
		var is_grounded: bool = (
			is_on_floor()
			and _character_floor_body() == null
		)

		if not is_grounded:
			velocity.y -= gravity * step
		elif velocity.y < 0.0:
			velocity.y = 0.0

		if _flow_active:
			if (
				gridmap != null
				and gridmap.is_flow_field_ready(_flow_target_cell)
			):
				_flow_wait = 0.0
				move_direction = gridmap.get_flow_direction_for_cell(
					global_position,
					_flow_target_cell
				)
				wants_to_move = move_direction.length_squared() > 0.0001

				if (
					global_position.distance_to(_flow_target)
					<= waypoint_arrival_distance + 1.0
				):
					_complete_flow_arrival()
					wants_to_move = false
					move_direction = Vector3.ZERO
			else:
				_flow_wait += step

				if _flow_wait > 3.0:
					_fail_evacuation()
		else:
			wants_to_move = (
				not current_path.is_empty()
				and path_index < current_path.size()
			)

			if wants_to_move:
				_advance_waypoint()
				wants_to_move = (
					not current_path.is_empty()
					and path_index < current_path.size()
				)

			if wants_to_move:
				move_direction = _get_direction_to_current_waypoint()

		if wants_to_move and move_direction.length_squared() > 0.001:
			_maybe_avoid_congestion(move_direction)
			_last_move_direction = move_direction.normalized()

		var crowd_adjustment: Vector3 = Vector3.ZERO
		var speed_scale: float = 1.0

		if _yield_timer > 0.0:
			# Deadlock yield: back away diagonally so the lower-priority agent
			# can get through without disabling NPC collision.
			wants_to_move = true
			move_direction = _yield_direction
			speed_scale = YIELD_SPEED_SCALE
		elif wants_to_move and move_direction.length_squared() > 0.001:
			# Only apply sideways crowd separation while following a path.
			# This prevents separation forces from directly reversing navigation.
			var lateral_push: Vector3 = (
				_crowd_push
				- move_direction * _crowd_push.dot(move_direction)
			)

			crowd_adjustment = lateral_push.limit_length(
				actual_movement_speed * 0.35
			)

		if not wants_to_move:
			_last_move_direction = Vector3.ZERO

		var desired_velocity: Vector3 = (
<<<<<<< Updated upstream
			move_direction * actual_movement_speed * speed_scale
			+ crowd_adjustment
		)

		if is_grounded and desired_velocity.length_squared() > 0.01:
			desired_velocity = _guard_ledge(
				desired_velocity,
				move_direction
			)

		if is_grounded:
			if desired_velocity.length_squared() > 0.01:
				velocity.x = lerpf(
					velocity.x,
					desired_velocity.x,
					15.0 * step
				)
				velocity.z = lerpf(
					velocity.z,
					desired_velocity.z,
					15.0 * step
				)

				var look_direction: Vector3 = Vector3(
					velocity.x,
					0.0,
					velocity.z
				)

				if look_direction.length_squared() > 0.1:
					look_at(global_position + look_direction, Vector3.UP)
			else:
				velocity.x = lerpf(velocity.x, 0.0, 15.0 * step)
				velocity.z = lerpf(velocity.z, 0.0, 15.0 * step)
		else:
			velocity.x = lerpf(
				velocity.x,
				desired_velocity.x,
				6.0 * step
			)
			velocity.z = lerpf(
				velocity.z,
				desired_velocity.z,
				6.0 * step
			)
=======
			_desired_direction
			* actual_movement_speed
			* speed_scale
			* _water_speed_scale()
		)

		_update_wall_force(step)
		_steer_with_social_forces(
			step,
			desired_velocity,
			is_grounded
		)
		_apply_water_drag(delta)
>>>>>>> Stashed changes

	# Movement runs every physics tick. Steering may run at movement_rate, but
	# move_and_slide() always integrates with the physics delta; skipping a tick
	# silently halves the distance the NPC can cover.
	var pre_move_position: Vector3 = global_position
	var pre_move_grounded: bool = is_on_floor()

	# Agents never stand on other characters (or the player): a body balanced
	# on someone else's collider slides off instead of becoming a step.
	_slide_off_character_floor(delta)

	move_and_slide()
	_keep_on_walkable_ground(pre_move_position, pre_move_grounded)

	if realistic_sprites_mode and _sprite_visual != null:
		_sprite_visual.call("tick", delta)

	_track_movement_distance()

	if update_steering:
		var grounded_now: bool = (
			is_on_floor()
			and _character_floor_body() == null
		)
		if wants_to_move and grounded_now and _yield_timer <= 0.0:
			_try_obstacle_hop(move_direction)
			_update_stuck_detection(step, wants_to_move, grounded_now)

		logic_tick_timer += step

		if logic_tick_timer >= LOGIC_TICK_RATE:
			_process_npc_brain(logic_tick_timer)
			logic_tick_timer = 0.0


<<<<<<< Updated upstream
=======
# ---------------------------------------------------------------------------
# Water and hazards
# ---------------------------------------------------------------------------

## One query for both systems. HazardWorld folds in the WaterWorld sample; if it
## is absent, query WaterWorld directly so water still works on its own.
func _refresh_environment_sample(elapsed: float) -> void:
	_environment_sample = {}
	_water_sample = {}

	var hazard_world := get_tree().get_first_node_in_group("hazard_world")
	var sample: Dictionary = {}
	if hazard_world != null and hazard_world.has_method("sample_hazard"):
		var hazard_result: Variant = hazard_world.call(
			"sample_hazard",
			global_position + Vector3.UP * 0.9
		)
		if hazard_result is Dictionary:
			sample = hazard_result
	else:
		var direct_water := get_tree().get_first_node_in_group("water_world")
		if direct_water != null and direct_water.has_method("sample_water"):
			var direct_result: Variant = direct_water.call(
				"sample_water",
				global_position + Vector3.UP * 0.9
			)
			if direct_result is Dictionary:
				sample = {"water": direct_result}

	var water_value: Variant = sample.get("water", {})
	var water: Dictionary = water_value if water_value is Dictionary else {}
	if water.is_empty():
		var fallback_water := get_tree().get_first_node_in_group("water_world")
		if fallback_water != null and fallback_water.has_method("sample_water"):
			var fallback_result: Variant = fallback_water.call(
				"sample_water",
				global_position
			)
			if fallback_result is Dictionary:
				water = fallback_result
	if not water.is_empty():
		var surface := float(water.get("surface_y", global_position.y))
		var submerged := clampf((surface - global_position.y) / 1.8, 0.0, 1.0)
		water["submerged_fraction"] = submerged

	_environment_sample = sample
	_water_sample = water

	var in_water := not water.is_empty()
	if in_water and not _was_in_water:
		var water_world := get_tree().get_first_node_in_group("water_world")
		if water_world != null and water_world.has_method("spawn_splash"):
			water_world.call("spawn_splash", global_position, 1.0)
	_was_in_water = in_water

	# Fire/LPG damage. This is intentionally separate from the water solver;
	# it only reads the shared hazard sample.
	if health_component != null and not sample.is_empty():
		var gas := maxf(0.0, float(sample.get("gas", 0.0)))
		var heat := maxf(0.0, float(sample.get("heat", 0.0)))
		var damage := (
			gas * gas_damage_per_sec
			+ heat * heat_damage_per_sec
		) * elapsed
		if damage > 0.0:
			health_component.take_damage(damage)


func _water_speed_scale() -> float:
	var submerged := clampf(
		float(_water_sample.get("submerged_fraction", 0.0)),
		0.0,
		1.0
	)
	return clampf(1.0 - water_speed_loss * submerged, 0.25, 1.0)


func _apply_water_drag(delta: float) -> void:
	if _water_sample.is_empty():
		return
	var submerged := clampf(
		float(_water_sample.get("submerged_fraction", 0.0)),
		0.0,
		1.0
	)
	if submerged <= 0.02:
		return
	var flow_value: Variant = _water_sample.get("flow", Vector2.ZERO)
	var flow: Vector2 = flow_value if flow_value is Vector2 else Vector2.ZERO
	var blend := 1.0 - exp(-water_drag * submerged * maxf(delta, 0.0001))
	velocity.x = lerpf(velocity.x, flow.x, blend)
	velocity.z = lerpf(velocity.z, flow.y, blend)


## Social Force Model integration (Helbing & Molnar 1995):
##
##   dv/dt = (v_desired - v) / tau + f_social / m + f_wall / m
##
## The crowd solver already returns a force/mass acceleration for every other
## agent (evaluated once per pair, applied symmetrically). This function adds
## the driving term and the wall term and integrates with a few substeps so a
## stiff contact force cannot tunnel through a body in one 33 ms tick.
func _steer_with_social_forces(
	step: float,
	desired_velocity: Vector3,
	is_grounded: bool
) -> void:
	if step <= 0.0:
		return

	var force_accel: Vector3 = (
		_social_accel * social_force_scale
		+ _wall_accel * wall_force_scale
	)

	if not is_grounded:
		# Airborne agents keep only limited air control: people cannot push a
		# body that has already left the ground.
		velocity.x = lerpf(
			velocity.x,
			desired_velocity.x,
			6.0 * step
		)
		velocity.z = lerpf(
			velocity.z,
			desired_velocity.z,
			6.0 * step
		)
		return

	var substep: float = step / float(SFM_SUBSTEPS)

	for _i in range(SFM_SUBSTEPS):
		var horizontal: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
		var step_acceleration: Vector3 = (
			(desired_velocity - horizontal) / relaxation_time
			+ force_accel
		)

		horizontal += step_acceleration * substep
		horizontal = horizontal.limit_length(max_horizontal_speed)
		velocity.x = horizontal.x
		velocity.z = horizontal.z

	var travel: Vector3 = Vector3(velocity.x, 0.0, velocity.z)

	if travel.length_squared() > 0.0025:
		# Kinematic movement already refuses unsupported steps and cancels
		# horizontal motion at a ledge, so the segment probe is redundant there
		# and was one of the most expensive per-tick operations.
		if not _kinematic_active:
			travel = _guard_ledge(travel, _desired_direction)
		velocity.x = travel.x
		velocity.z = travel.z

	if travel.length_squared() > 0.1:
		look_at(global_position + travel, Vector3.UP)


func _update_wall_force(step: float) -> void:
	if wall_force_scale <= 0.0:
		_wall_accel = Vector3.ZERO
		return

	_wall_force_accum += step

	if (
		not _wall_force_dirty
		and _wall_force_accum < wall_force_update_interval
	):
		return

	_wall_force_accum = 0.0
	_wall_force_dirty = false
	_wall_accel = Vector3.ZERO

	var grid: NavGridMap = _get_gridmap()

	if grid == null or not grid.has_method("get_wall_acceleration"):
		return

	# Sample at the body centre, not the foot origin. The origin sits inside the
	# floor voxel, so a foot-height ray reports the floor as a wall (large,
	# symmetric forces that cancel) and misses the first wall block above it.
	# foot_offset + body_radius is the collision sphere's centre.
	var body_centre: Vector3 = global_position + Vector3.UP * (_foot_offset + body_radius)
	_wall_accel = grid.get_wall_acceleration(
		body_centre,
		body_radius,
		body_mass
	)


## Grounded state used by movement and stuck detection. In kinematic mode this
## comes from the ground probe because the body does not collide with geometry.
func _is_grounded() -> bool:
	if _uses_kinematic_movement():
		return _kinematic_grounded

	return is_on_floor() and _character_floor_body() == null


## Downward ray used by kinematic movement. Returns the raw hit dictionary.
func _probe_ground(at: Vector3) -> Dictionary:
	if _ground_query == null:
		return {}

	var world := get_world_3d()

	if world == null:
		return {}

	# Start above the tallest legal step so a too-high surface is detected as a
	# wall instead of silently starting the ray inside the block.
	var lift: float = kinematic_step_height + _foot_offset + 0.1
	_ground_query.from = at + Vector3(0.0, lift, 0.0)
	_ground_query.to = at - Vector3(0.0, 4.0, 0.0)

	return world.direct_space_state.intersect_ray(_ground_query)


## Cached ground probe for the kinematic path. A walking agent moves a few
## centimetres per tick, so re-probing the same 0.15 m bucket every tick is
## wasted work. Airborne agents bypass the cache because they need a fresh hit
## to detect the landing surface.
func _probe_ground_cached(at: Vector3) -> Dictionary:
	if not _kinematic_active or not _kinematic_grounded:
		return _probe_ground(at)

	var key := Vector3i(
		roundi(at.x / GROUND_PROBE_CACHE_HORIZONTAL),
		roundi(at.y / GROUND_PROBE_CACHE_VERTICAL),
		roundi(at.z / GROUND_PROBE_CACHE_HORIZONTAL)
	)

	if _ground_probe_cache_valid and key == _ground_probe_cache_key:
		return _ground_probe_cache_hit

	var hit: Dictionary = _probe_ground(at)
	_ground_probe_cache_key = key
	_ground_probe_cache_hit = hit
	_ground_probe_cache_valid = true
	return hit


## Characters are never walkable ground. The player body lives on the world
## collision layer (its layer mask includes layer 1), so a bare layer-1 ground
## ray would let agents snap onto the player. Exclude explicit character RIDs.
func _refresh_ground_exclusions() -> void:
	if _ground_query == null:
		return

	var exclusions: Array[RID] = [get_rid()]
	var player := get_tree().get_first_node_in_group("Player")

	if player is CollisionObject3D and is_instance_valid(player):
		exclusions.append((player as CollisionObject3D).get_rid())

	_ground_query.exclude = exclusions


## Kinematic step. Replaces move_and_slide() against the voxel world:
##   1. Probe the ground under the proposed horizontal position.
##   2. Refuse the step when there is no support (ledge) or the ground rises
##      more than kinematic_step_height (a two-block wall). One-block steps
##      match the navigation graph's step-up edges and are climbed.
##   3. Follow the ground height while standing, snap down small drops, and
##      integrate gravity while airborne or jumping.
func _move_kinematic(delta: float) -> void:
	var start: Vector3 = global_position
	var target: Vector3 = start + Vector3(
		velocity.x,
		0.0,
		velocity.z
	) * delta

	var hit: Dictionary = _probe_ground_cached(target)
	var supported: bool = not hit.is_empty()
	var stand_y: float = start.y

	if supported:
		stand_y = float(hit["position"].y) - _foot_offset

		if stand_y > start.y + kinematic_step_height:
			# Too high to be a one-block step: treat it as a wall. This also
			# stops a falling or shoved agent from snapping up onto a two-block
			# stack it is standing beside; landing on something higher is still
			# possible because the agent descends from above it.
			supported = false

	if not supported:
		if not _kinematic_grounded:
			# Airborne: probe again under the current position to find a
			# landing surface. A grounded agent already knows its support is
			# start.y, so it needs no second ray.
			hit = _probe_ground_cached(start)
			supported = not hit.is_empty()

			if supported:
				stand_y = float(hit["position"].y) - _foot_offset
			else:
				stand_y = start.y

		# Never walk out over empty space while standing on solid ground.
		if _kinematic_grounded:
			target.x = start.x
			target.z = start.z
			velocity.x = 0.0
			velocity.z = 0.0

	_kinematic_stand_y = stand_y
	global_position.x = target.x
	global_position.z = target.z

	if (
		supported
		and velocity.y <= 0.01
		and global_position.y - stand_y <= kinematic_snap_down_height
	):
		global_position.y = stand_y
		velocity.y = 0.0
		_kinematic_grounded = true
	else:
		velocity.y -= gravity * delta
		global_position.y += velocity.y * delta
		_kinematic_grounded = false


>>>>>>> Stashed changes
func _track_movement_distance() -> void:
	if _has_last_position:
		var delta_position: Vector3 = global_position - _last_position
		delta_position.y = 0.0
		_distance_travelled += delta_position.length()
	else:
		_has_last_position = true

	_last_position = global_position


func _update_timers(delta: float) -> void:
	if jump_cooldown_timer > 0.0:
		jump_cooldown_timer -= delta

	if _obstacle_hop_timer > 0.0:
		_obstacle_hop_timer -= delta

	if _corner_repath_timer > 0.0:
		_corner_repath_timer -= delta

	if _congestion_repath_timer > 0.0:
		_congestion_repath_timer -= delta

	if _congestion_check_timer > 0.0:
		_congestion_check_timer -= delta

	if _yield_timer > 0.0:
		_yield_timer -= delta

		if _yield_timer <= 0.0 and _yield_repath_pending:
			_yield_repath_pending = false
			_request_congestion_detour(_current_route_target(), true)


# ============================================================
# MOVEMENT
# ============================================================

## Crowd depenetration can shove an agent sideways off a ledge even when its
## steering vector was safe. When a small push ends on unsupported ground,
## restore the pre-move spot so NPC-vs-NPC collision cannot kill agents.
func _keep_on_walkable_ground(
	pre_move_position: Vector3,
	pre_move_grounded: bool
) -> void:
	if not pre_move_grounded:
		return

	# Let intentional jumps leave the ground; only rescue a fall or a shove.
	if velocity.y > 0.01:
		return

	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return

	var displacement: Vector3 = global_position - pre_move_position
	displacement.y = 0.0

	# Only small depenetration shoves are corrected here. Real path movement is
	# already validated by _guard_ledge() before the move.
	if (
		displacement.length_squared() < 0.0001
		or displacement.length() > grid.cell_size.x * 1.25
	):
		return

	if grid.is_ground_supported(global_position):
		return

	if not grid.is_ground_supported(pre_move_position):
		return

	global_position = pre_move_position
	velocity = Vector3.ZERO


## Stops the final steering vector from stepping over unsupported ground.
## If crowd pressure points off a ledge, keep the forward component instead.
func _guard_ledge(desired: Vector3, forward: Vector3) -> Vector3:
	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return desired

	var probe_distance: float = grid.cell_size.x * 0.55
	var probe := Vector3(desired.x, 0.0, desired.z)

	if probe.length_squared() < 0.0001:
		return desired

	probe = probe.normalized()

	if grid.is_ground_path_supported(
		global_position,
		global_position + probe * probe_distance
	):
		return desired

	var forward_flat := Vector3(forward.x, 0.0, forward.z)

	if forward_flat.length_squared() > 0.0001:
		forward_flat = forward_flat.normalized()

		if grid.is_ground_path_supported(
			global_position,
			global_position + forward_flat * probe_distance
		):
			return forward_flat * desired.length()

	return Vector3.ZERO


## If the route immediately ahead is hot, leave the shared flow field (or the
## current A* path) and request a fresh congestion-weighted A* route. This is
## what stops agents from walking straight back into a jam they just left.
func _maybe_avoid_congestion(move_direction: Vector3) -> void:
	if (
		_yield_timer > 0.0
		or _congestion_repath_timer > 0.0
		or _congestion_check_timer > 0.0
		or is_awaiting_path
		or _repath_pending
		or move_direction.length_squared() < 0.0001
	):
		return

	_congestion_check_timer = CONGESTION_CHECK_INTERVAL

	var grid: NavGridMap = _get_gridmap()

	if grid == null or not grid.enable_congestion_routing:
		return

	var probe_distance: float = (
		maxf(grid.cell_size.x, grid.cell_size.z)
		* CONGESTION_PROBE_CELL_SCALE
	)

	if _flow_active:
		var flow_probe: Vector3 = (
			global_position + move_direction * probe_distance
		)

		if grid.is_congested(flow_probe, CONGESTION_AVOID_THRESHOLD):
			_request_congestion_detour(_flow_target)
		return

	if current_path.is_empty() or path_index >= current_path.size():
		return

	# Keep the final approach stable; detouring to the destination itself
	# would just create repath churn around the exit.
	if path_index >= current_path.size() - 1:
		return

	var waypoint: Vector3 = current_path[path_index]
	var to_waypoint := Vector3(
		waypoint.x - global_position.x,
		0.0,
		waypoint.z - global_position.z
	)

	if to_waypoint.length_squared() < 0.01:
		return

	var midpoint: Vector3 = global_position + to_waypoint * 0.5

	if (
		grid.is_congested(midpoint, CONGESTION_AVOID_THRESHOLD)
		or grid.is_congested(waypoint, CONGESTION_AVOID_THRESHOLD)
	):
		_request_congestion_detour(
			current_path[current_path.size() - 1]
		)


func _current_route_target() -> Vector3:
	if _flow_active:
		return _flow_target

	if not current_path.is_empty():
		return current_path[current_path.size() - 1]

	return Vector3.ZERO


## Length of the part of the current path the agent still has to walk.
func _remaining_path_length() -> float:
	if current_path.is_empty() or path_index >= current_path.size():
		return -1.0

	var total: float = global_position.distance_to(
		current_path[path_index]
	)

	for index: int in range(path_index, current_path.size() - 1):
		total += current_path[index].distance_to(
			current_path[index + 1]
		)

	return total


func _path_length_from_here(path: PackedVector3Array) -> float:
	if path.is_empty():
		return 0.0

	var total: float = global_position.distance_to(path[0])

	for index: int in range(path.size() - 1):
		total += path[index].distance_to(path[index + 1])

	return total


## Rejects a detour that trades a local jam for a much longer route. This keeps
## congestion avoidance from sending an agent back across the map.
func _detour_route_is_acceptable(
	path: PackedVector3Array,
	previous_length: float
) -> bool:
	if previous_length <= 0.0 or path.is_empty():
		return true

	var new_length: float = _path_length_from_here(path)
	var allowed_length: float = previous_length + maxf(
		3.0,
		previous_length * 0.2
	)

	if new_length > allowed_length:
		return false

	# Also reject an immediate reversal; a side-step at the next junction is
	# fine, but turning around and walking back through the crowd is not.
	var first: Vector3 = path[0] - global_position
	first.y = 0.0

	var forward: Vector3 = _last_move_direction
	forward.y = 0.0

	if (
		first.length_squared() > 0.01
		and forward.length_squared() > 0.01
		and first.length() > 1.0
		and first.normalized().dot(forward.normalized()) < -0.35
	):
		return false

	return true


## Switches this agent off its shared route and asks A* for a fresh route.
## A* already sees the congestion heat, so the new route avoids the jam.
func _request_congestion_detour(
	target: Vector3,
	force: bool = false
) -> bool:
	if is_awaiting_path or target == Vector3.ZERO:
		return false

	if not force and _congestion_repath_timer > 0.0:
		return false

	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return false

	_congestion_repath_timer = CONGESTION_REPATH_INTERVAL
	_detour_from_flow = _flow_active
	_detour_previous_length = -1.0

	if not _detour_from_flow:
		_detour_previous_length = _remaining_path_length()

	_flow_active = false
	_flow_wait = 0.0

	# Flow mode has no per-agent path to fall back on, so stop until the detour
	# arrives. Path mode keeps its current route until the replacement lands.
	if _detour_from_flow:
		current_path.clear()
		path_index = 0

	is_awaiting_path = true
	grid.request_path(
		self,
		global_position,
		target,
		_on_path_received
	)
	return true


func _advance_waypoint() -> void:
	while not current_path.is_empty() and path_index < current_path.size():
		var waypoint: Vector3 = current_path[path_index]

		var to_waypoint := Vector2(
			waypoint.x - global_position.x,
			waypoint.z - global_position.z
		)

		var arrival_distance_sq := (
			waypoint_arrival_distance
			* waypoint_arrival_distance
		)

		var reached_waypoint: bool = (
			to_waypoint.length_squared() < arrival_distance_sq
			and absf(global_position.y - waypoint.y) < 1.0
		)

		# If we have passed this waypoint, don't turn around to revisit it.
		# Walking backwards into the crowd heading for the same corner was the
		# cause of the deadlock; instead, keep moving forward and request a
		# fresh path from the current position when the push was large.
		var passed_waypoint: bool = false
		var lateral_offset: float = 0.0

		if path_index > 0:
			var previous: Vector3 = current_path[path_index - 1]
			var segment := Vector2(
				waypoint.x - previous.x,
				waypoint.z - previous.z
			)

			if segment.length_squared() > 0.0001:
				segment = segment.normalized()
				lateral_offset = absf(
					to_waypoint.dot(Vector2(-segment.y, segment.x))
				)
				passed_waypoint = to_waypoint.dot(segment) < 0.0

		if reached_waypoint or passed_waypoint:
			path_index += 1

			if (
				passed_waypoint
				and lateral_offset > CORNER_REPATH_DISTANCE
			):
				_request_corner_repath()
		else:
			break

	# A corner repath may have cleared the old path while a new one is being
	# requested; do not treat that as arrival.
	if path_index >= current_path.size() and not is_awaiting_path:
		_finish_path()


func _request_corner_repath() -> void:
	if _corner_repath_timer > 0.0 or is_awaiting_path:
		return

	_corner_repath_timer = CORNER_REPATH_INTERVAL
	_repath()


func _get_direction_to_current_waypoint() -> Vector3:
	var waypoint: Vector3 = current_path[path_index]
	var flat_waypoint: Vector3 = Vector3(
		waypoint.x,
		global_position.y,
		waypoint.z
	)

	return global_position.direction_to(flat_waypoint)


func _finish_path() -> void:
	current_path.clear()
	path_index = 0

	if current_state == State.SEEKING_EVAC:
		current_state = State.ARRIVED
		wait_timer = evac_confirm_timeout

		if evacuation_manager:
			evacuation_manager.notify_npc_arrived(
				_last_evac_target,
				self
			)
	else:
		current_state = State.IDLE
		wait_timer = randf_range(1.0, 3.0)


func _complete_flow_arrival() -> void:
	_flow_active = false
	_flow_wait = 0.0

	if current_state == State.SEEKING_EVAC:
		current_state = State.ARRIVED
		wait_timer = evac_confirm_timeout

		if evacuation_manager:
			evacuation_manager.notify_npc_arrived(
				_flow_target,
				self
			)
	else:
		current_state = State.IDLE
		wait_timer = randf_range(1.0, 3.0)


# ============================================================
# OBSTACLE HOPPING
# ============================================================

## Sideways speed used to slide an agent off a character it is balanced on.
const CHARACTER_FLOOR_SLIDE_SPEED: float = 2.0
## Radius of the landing-zone probe that rejects hops onto another character.
const HOP_LANDING_CLEARANCE_RADIUS: float = 0.45

func _try_obstacle_hop(move_direction: Vector3) -> void:
	if (
		not allow_jumping
		or _obstacle_hop_timer > 0.0
		or move_direction.length_squared() < 0.01
		or not is_on_wall()
	):
		return

	var needs_climb: bool = false

	if _flow_active:
		# Flow mode has no per-agent waypoint. Only spend a hop on an actual
		# stuck event, never on normal locomotion.
		if _stuck_strikes == 0:
			return
	else:
		if path_index >= current_path.size():
			return

		needs_climb = (
			current_path[path_index].y - global_position.y > 0.3
		)

		if not needs_climb and _stuck_strikes == 0:
			return

	if not _is_blocked_by_terrain(move_direction):
		return

	if not _is_obstacle_jumpable(move_direction):
		return

	velocity.y = jump_force
	velocity.x = move_direction.x * actual_movement_speed
	velocity.z = move_direction.z * actual_movement_speed
	_obstacle_hop_timer = obstacle_hop_cooldown


func _is_blocked_by_terrain(move_direction: Vector3) -> bool:
	for collision_index: int in get_slide_collision_count():
		var collision: KinematicCollision3D = get_slide_collision(
			collision_index
		)

		if collision.get_collider() is CharacterBody3D:
			continue

		var normal: Vector3 = collision.get_normal()

		if absf(normal.y) < 0.3 and normal.dot(move_direction) < -0.5:
			return true

	return false


func _is_obstacle_jumpable(direction: Vector3) -> bool:
	var jump_height: float = (
		jump_force * jump_force / (2.0 * gravity)
	)
	var from: Vector3 = global_position + Vector3(
		0.0,
		jump_height - 0.1,
		0.0
	)

	var query := PhysicsRayQueryParameters3D.create(
		from,
		from + direction * 0.8
	)
	query.collision_mask = 1 | (1 << 1)  # world + NPC bodies
	query.exclude = [get_rid()]

	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(
		query
	)

	# Never hop when another character occupies the apex. Treating another NPC
	# as a valid landing let agents climb over each other instead of waiting or
	# steering around them.
	if not hit.is_empty():
		return false

	# The hop lands well beyond the apex ray, so also reject it when another
	# character occupies the landing zone; landing on someone's head is the
	# other half of agents climbing each other.
	var flight_time: float = 2.0 * jump_force / maxf(gravity, 0.001)
	var flat_direction := Vector3(direction.x, 0.0, direction.z)

	if flat_direction.length_squared() < 0.0001:
		return true

	flat_direction = flat_direction.normalized()
	var landing: Vector3 = global_position + flat_direction * (
		actual_movement_speed * flight_time
	)

	var sphere := SphereShape3D.new()
	sphere.radius = HOP_LANDING_CLEARANCE_RADIUS

	var landing_query := PhysicsShapeQueryParameters3D.new()
	landing_query.shape = sphere
	landing_query.transform = Transform3D(
		Basis(),
		landing + Vector3(0.0, 0.5, 0.0)
	)
	landing_query.collision_mask = 1 << 1  # character bodies (NPCs + player)
	landing_query.collide_with_bodies = true
	landing_query.collide_with_areas = false
	landing_query.exclude = [get_rid()]

	return get_world_3d().direct_space_state.intersect_shape(
		landing_query,
		1
	).is_empty()


## Returns the character whose body this agent is currently standing on, or
## null when the floor is world geometry.
func _character_floor_body() -> CharacterBody3D:
	if not is_on_floor():
		return null

	for collision_index: int in get_slide_collision_count():
		var collision: KinematicCollision3D = get_slide_collision(
			collision_index
		)

		if (
			collision.get_collider() is CharacterBody3D
			and collision.get_normal().y > 0.5
		):
			return collision.get_collider()

	return null


## An agent balanced on another character (depenetration launch, hop landing)
## slides off sideways. Bodies must never act as stairs for each other.
func _slide_off_character_floor(delta: float) -> void:
	var other := _character_floor_body()
	if other == null:
		return

	var away: Vector3 = global_position - other.global_position
	away.y = 0.0

	if away.length_squared() < 0.0001:
		away = _last_move_direction
		away.y = 0.0

	if away.length_squared() < 0.0001:
		away = Vector3.RIGHT

	away = away.normalized()
	velocity.x = lerpf(
		velocity.x,
		away.x * CHARACTER_FLOOR_SLIDE_SPEED,
		10.0 * delta
	)
	velocity.z = lerpf(
		velocity.z,
		away.z * CHARACTER_FLOOR_SLIDE_SPEED,
		10.0 * delta
	)


# ============================================================
# STUCK DETECTION
# ============================================================

func _update_stuck_detection(
	delta: float,
	wants_to_move: bool,
	is_grounded: bool
) -> void:
	if not wants_to_move:
		_reset_stuck()
		return

	var waypoint: Vector3

	if _flow_active:
		if not is_instance_valid(gridmap):
			_reset_stuck()
			return

		waypoint = _flow_target
	else:
		if path_index >= current_path.size():
			_reset_stuck()
			return

		waypoint = current_path[path_index]

	var distance: float = Vector2(
		global_position.x - waypoint.x,
		global_position.z - waypoint.z
	).length()

	if _flow_active:
		# The flow field has no waypoint indices. Use the agent's nav cell as
		# the sample: crossing a cell counts as progress, staying in one cell
		# for the threshold counts as a jam.
		var flow_cell: Vector3i = gridmap.resolve_nav_cell(global_position)

		if not _has_stuck_flow_cell or flow_cell != _stuck_sample_flow_cell:
			_has_stuck_flow_cell = true
			_stuck_sample_flow_cell = flow_cell
			_stuck_sample_index = FLOW_STUCK_SAMPLE
			_stuck_sample_dist = distance
			stuck_timer = 0.0
			_stuck_strikes = 0
			return
	elif path_index != _stuck_sample_index:
		_stuck_sample_index = path_index
		_stuck_sample_dist = distance
		stuck_timer = 0.0
		_stuck_strikes = 0
		return

	stuck_timer += delta

	if stuck_timer < stuck_time_threshold:
		return

	var progress: float = _stuck_sample_dist - distance
	var required: float = (
		actual_movement_speed
		* stuck_time_threshold
		* stuck_progress_ratio
	)
	var observed_stuck_time: float = stuck_timer

	_stuck_sample_dist = distance
	stuck_timer = 0.0

	if progress >= required:
		_stuck_strikes = 0
		return

	_stuck_strikes += 1
	_stuck_time_total += observed_stuck_time
	_on_stuck(is_grounded)


func _reset_stuck() -> void:
	stuck_timer = 0.0
	_stuck_strikes = 0
	_stuck_sample_index = -1
	_has_stuck_flow_cell = false
	_restore_layer_2()


func _restore_layer_2() -> void:
	if not _layer_2_disabled:
		return

	# Re-enabling collision while another body overlaps causes a large
	# depenetration impulse (NPCs launch upward). Keep pass-through until the
	# local overlap has cleared.
	if not _can_restore_npc_collision():
		return

	_layer_2_disabled = false
	collision_mask |= 1 << 1


func _can_restore_npc_collision() -> bool:
	var world := get_world_3d()
	if world == null:
		return true

	var sphere := SphereShape3D.new()
	sphere.radius = 1.0

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(
		Basis.IDENTITY,
		global_position + Vector3(0.0, 0.5, 0.0)
	)
	query.collision_mask = 1 << 1
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	return world.direct_space_state.intersect_shape(query, 1).is_empty()


func _disable_layer_2() -> void:
	if not allow_collision_disable:
		_apply_collision_policy()
		return

	if not _layer_2_disabled:
		_layer_2_disabled = true
		collision_mask &= ~(1 << 1)


## Keeps NPC-vs-NPC collision enabled when this agent may not disable it.
func _apply_collision_policy() -> void:
	if allow_collision_disable:
		return

	_layer_2_disabled = false
	collision_mask |= 1 << 1


func _random_hop(is_grounded: bool) -> void:
	if not allow_jumping or not is_grounded or jump_cooldown_timer > 0.0:
		return

	var random_angle: float = randf_range(0.0, TAU)

	velocity.y = jump_force
	velocity.x = cos(random_angle) * jump_push_force
	velocity.z = sin(random_angle) * jump_push_force
	jump_cooldown_timer = jump_cooldown


## Deterministic right-of-way. When two agents block each other, the higher
## instance ID backs away diagonally for a short time; the lower ID keeps moving.
## This breaks head-on deadlocks without disabling NPC collision.
func _try_deadlock_yield(blocker: CharacterBody3D = null) -> bool:
	if not allow_yielding or allow_collision_disable or _yield_timer > 0.0:
		return false

	if blocker == null:
		blocker = _find_blocking_npc()

	if blocker == null:
		return false

	if get_instance_id() < blocker.get_instance_id():
		return false

	var forward: Vector3 = _last_move_direction
	forward.y = 0.0

	if forward.length_squared() < 0.01:
		forward = blocker.global_position - global_position
		forward.y = 0.0

	if forward.length_squared() < 0.01:
		forward = Vector3.BACK

	forward = forward.normalized()
	var side: Vector3 = forward.cross(Vector3.UP)
	var side_sign: float = (
		1.0 if (get_instance_id() & 1) == 0 else -1.0
	)
	var yield_candidate: Vector3 = (
		-forward + side * side_sign * 0.8
	).normalized()

	# Do not back off a ledge while yielding. Prefer the diagonal step; if the
	# whole route there is missing, back straight up along the path instead.
	var grid: NavGridMap = _get_gridmap()

	if grid != null:
		var probe_distance: float = grid.cell_size.x * 0.6

		if not grid.is_ground_path_supported(
			global_position,
			global_position + yield_candidate * probe_distance
		):
			yield_candidate = -forward

		if not grid.is_ground_path_supported(
			global_position,
			global_position + yield_candidate * probe_distance
		):
			return false

	_yield_direction = yield_candidate
	_yield_timer = YIELD_DURATION
	_yield_repath_pending = true
	return true


func _find_blocking_npc() -> CharacterBody3D:
	if crowd_manager == null:
		return null

	var nearby: Array[CharacterBody3D] = crowd_manager.get_nearby_npcs(
		global_position,
		max_neighbors
	)
	var forward: Vector3 = _last_move_direction
	forward.y = 0.0

	if forward.length_squared() < 0.01:
		forward = velocity
		forward.y = 0.0

	if forward.length_squared() < 0.01:
		return null

	forward = forward.normalized()
	var best: CharacterBody3D = null
	var best_distance: float = YIELD_DETECT_RADIUS

	for other: CharacterBody3D in nearby:
		if other == self or other == null or not is_instance_valid(other):
			continue

		if int(other.get("current_state")) == State.DEAD:
			continue

		var difference: Vector3 = other.global_position - global_position

		if absf(difference.y) > 1.2:
			continue

		difference.y = 0.0
		var distance: float = difference.length()

		if distance < 0.05 or distance > YIELD_DETECT_RADIUS:
			continue

		var to_other: Vector3 = difference / distance

		if to_other.dot(forward) < 0.5:
			continue

		# Yield to a head-on blocker, or to a slow blocker at a corner.
		# Same-direction spacious traffic is handled by normal steering.
		var other_forward: Variant = other.get("_last_move_direction")
		var other_oncoming: bool = false

		if other_forward is Vector3:
			var other_flat: Vector3 = other_forward
			other_flat.y = 0.0

			if other_flat.length_squared() > 0.01:
				other_flat = other_flat.normalized()
				other_oncoming = to_other.dot(other_flat) <= -0.2

		var other_intended: Variant = other.get("actual_movement_speed")
		var other_slow: bool = false

		if other_intended is float:
			other_slow = (
				other.velocity.length()
				< float(other_intended) * 0.5
			)
		else:
			other_slow = other.velocity.length_squared() < 0.01

		if not other_oncoming and not other_slow:
			continue

		if distance <= best_distance:
			best_distance = distance
			best = other

	return best


func _on_stuck(is_grounded: bool) -> void:
	var blocker: CharacterBody3D = _find_blocking_npc()
	_report_congestion(blocker)
	var yielded: bool = _try_deadlock_yield(blocker)

	if not yielded:
		_disable_layer_2()

		match _stuck_strikes:
			1:
				_random_hop(is_grounded)

			2:
				_random_hop(is_grounded)
				_repath()

			_:
				_random_hop(is_grounded)
				_restore_layer_2()

	# A yield already ends with a congestion-weighted repath, so do not also
	# count it as an evacuation failure.
	if yielded:
		return

	if current_state == State.SEEKING_EVAC:
		_evacuation_failures += 1

		if _evacuation_failures >= max_evacuation_failures:
			_fail_evacuation()
			_evacuation_failures = 0
		else:
			_repath()
	else:
		current_path.clear()
		current_state = State.IDLE
		wait_timer = 0.0


## Feeds the local jam into NavGridMap's congestion heat. That raises the cost
## of these cells for every future A* route and flow bake, so incoming agents
## start preferring a different corridor instead of joining the pile-up.
func _report_congestion(blocker: CharacterBody3D) -> void:
	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return

	var amount: float = maxf(0.05, grid.congestion_heat_per_report)
	grid.report_congestion(global_position, amount)

	if blocker != null and is_instance_valid(blocker):
		grid.report_congestion(blocker.global_position, amount * 0.6)


# ============================================================
# BRAIN & STATE MACHINE
# ============================================================

func set_local_density(density: float) -> void:
	local_density = density
	_peak_density = maxf(_peak_density, density)


## Switches this member between evacuating and wandering. Used by the simulation
## toggle and by Random Populate's per-member evacuation-mode export.
func set_evacuation_mode(enabled: bool) -> void:
	is_evacuee = enabled
	has_evacuation_target = false
	_awaiting_evac_confirmation = false
	_flow_active = false
	_flow_wait = 0.0
	is_awaiting_path = false
	_repath_pending = false
	_evacuation_failures = 0
	_failed_evac_points.clear()
	current_path.clear()
	path_index = 0

	if is_instance_valid(gridmap):
		gridmap.cancel_path_requests(self)

	if current_state == State.DEAD:
		return

	current_state = State.IDLE
	wait_timer = 0.1


func _process_npc_brain(elapsed_time: float) -> void:
	if current_state == State.DEAD:
		return

	hunger += elapsed_time * 0.5

	if enable_energy and current_state != State.IDLE:
		energy -= elapsed_time * 0.3

	_update_crowd_push(elapsed_time)

	if current_state == State.ARRIVED:
		wait_timer -= elapsed_time

		if wait_timer <= 0.0:
			# The evac area should have freed this member. If it did not, allow
			# another evacuation attempt instead of wandering forever.
			has_evacuation_target = false
			current_state = State.IDLE
			wait_timer = randf_range(1.0, 3.0)

		return

	match current_state:
		State.IDLE:
			wait_timer -= elapsed_time

			if wait_timer <= 0.0:
				if _awaiting_evac_confirmation:
					_awaiting_evac_confirmation = false

				choose_next_action()

		State.WANDERING:
			if _should_evacuate() or has_evacuation_target:
				# Recover agents left wandering with a stale evacuation target.
				has_evacuation_target = false
				current_state = State.SEEKING_EVAC
				current_path.clear()
				path_index = 0
				_route_to_closest_evac_point()


func _update_crowd_push(elapsed_time: float) -> void:
	var push: Vector3 = Vector3.ZERO

	if crowd_manager == null:
		_crowd_push = Vector3.ZERO
		return

	var nearby: Array[CharacterBody3D] = crowd_manager.get_nearby_npcs(
		global_position,
		max_neighbors
	)

	var neighbor_count: int = nearby.size() - 1

	if (
		enable_crowd_damage
		and neighbor_count >= crowd_threshold
		and health_component
	):
		health_component.take_damage(
			crush_damage_per_sec * elapsed_time
		)

	if actual_separation_push > 0.0:
		for other: CharacterBody3D in nearby:
			if other == self or not is_instance_valid(other):
				continue

			var difference: Vector3 = (
				global_position - other.global_position
			)

			if (
				absf(difference.y)
				> max_vertical_neighbor_distance
			):
				continue

			difference.y = 0.0

			var distance_squared: float = difference.length_squared()

			if (
				distance_squared
				> actual_separation_radius * actual_separation_radius
			):
				continue

			var distance: float = sqrt(distance_squared)

			if distance < 0.001:
				continue

			var falloff: float = (
				1.0 - distance / actual_separation_radius
			)
			push += (difference / distance) * falloff

	_crowd_push = push * actual_separation_push


# ============================================================
# DAMAGE & HEALTH
# ============================================================

func _on_damaged(_amount: float) -> void:
	if realistic_sprites_mode:
		_flash_sprite_hurt()
	elif animator:
		animator.play_hurt()


func _on_health_depleted() -> void:
	current_state = State.DEAD
	velocity = Vector3.ZERO

	if evacuation_manager and evacuation_manager.has_method("notify_npc_died"):
		evacuation_manager.notify_npc_died(self)

	queue_free()


# ============================================================
# NAVIGATION
# ============================================================

func _is_below_chunk_floor() -> bool:
	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return false

	var chunk: Vector2i = grid.position_to_chunk(global_position)
	var lowest_y: int = grid.get_chunk_lowest_block_y(chunk)

	# An empty chunk has no local floor; use the world's zero level so agents
	# that fall out of the map still die instead of falling forever.
	if lowest_y == NavGridMap.NO_CHUNK_FLOOR:
		lowest_y = 0

	var floor_y: float = grid.to_global(
		grid.map_to_local(Vector3i(0, lowest_y, 0))
	).y
	var kill_y: float = (
		floor_y - FALL_KILL_MARGIN_BLOCKS * grid.cell_size.y
	)

	return global_position.y < kill_y


func _get_gridmap() -> NavGridMap:
	if not is_instance_valid(gridmap):
		gridmap = get_tree().get_first_node_in_group(
			"grid_map"
		) as NavGridMap

		if gridmap:
			if not gridmap.navigation_changed.is_connected(
				_on_navigation_changed
			):
				gridmap.navigation_changed.connect(_on_navigation_changed)

	return gridmap


func choose_next_action() -> void:
	if is_awaiting_path or current_state == State.DEAD:
		return

	if _should_evacuate() or has_evacuation_target:
		# A stale target with no route (for example after all exits briefly
		# entered cooldown) must not strand the agent in WANDERING forever.
		has_evacuation_target = false
		current_state = State.SEEKING_EVAC
		_route_to_closest_evac_point()
		return

	current_state = State.WANDERING
	_request_random_wander_path()


func _should_evacuate() -> bool:
	return is_evacuee and not has_evacuation_target


func request_evacuation_target(target: Vector3) -> void:
	if current_state == State.DEAD:
		return

	has_evacuation_target = true
	_last_evac_target = target
	current_state = State.SEEKING_EVAC
	current_path.clear()
	path_index = 0
	_flow_wait = 0.0

	if gridmap:
		if gridmap.enable_flow_fields:
			# Shared destinations steer from the baked field instead of
			# rebuilding and smoothing one path per NPC.
			_flow_target = target
			_flow_target_cell = gridmap.resolve_nav_cell(target)

			if not gridmap.is_nav_cell_valid(_flow_target_cell):
				_fail_evacuation()
				return

			_flow_active = true
			gridmap.ensure_flow_field_cell(_flow_target_cell)
			is_awaiting_path = false
			_reset_stuck()
		else:
			_flow_active = false
			is_awaiting_path = true
			gridmap.request_path(
				self,
				global_position,
				target,
				_on_path_received
			)
	else:
		_fail_evacuation()
		return

	if evacuation_manager:
		evacuation_manager.notify_evacuation_target_chosen(
			target,
			self
		)


func _fail_evacuation() -> void:
	if _last_evac_target != Vector3.ZERO:
		_mark_evacuation_point_failed(_last_evac_target)

	if evacuation_manager:
		evacuation_manager.notify_evacuation_failed(
			_last_evac_target
		)

	has_evacuation_target = false
	current_state = State.IDLE
	current_path.clear()
	path_index = 0
	wait_timer = randf_range(0.5, 1.5)
	is_awaiting_path = false
	_flow_active = false
	_flow_wait = 0.0


func get_failed_evacuation_points() -> Array[Vector3]:
	var now: float = _now_seconds()
	var result: Array[Vector3] = []

	for point_position: Vector3 in _failed_evac_points:
		if now < float(_failed_evac_points[point_position]):
			result.append(point_position)

	return result


func _is_evacuation_point_failed(point_position: Vector3) -> bool:
	var now: float = _now_seconds()
	var unavailable_until: float = float(
		_failed_evac_points.get(point_position, 0.0)
	)

	return now < unavailable_until


func _mark_evacuation_point_failed(point_position: Vector3) -> void:
	var now: float = _now_seconds()
	_failed_evac_points[point_position] = (
		now + failed_evac_point_cooldown
	)


func _now_seconds() -> float:
	return Time.get_ticks_msec() / 1000.0


func _route_to_closest_evac_point() -> void:
	if is_awaiting_path or _flow_active or current_state == State.DEAD:
		return

	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		has_evacuation_target = false
		_flow_active = false
		is_awaiting_path = false
		current_state = State.IDLE
		wait_timer = 2.0
		return

	var evacuation_nodes: Array[Node] = get_tree().get_nodes_in_group(
		"EvacPoint"
	)

	if evacuation_nodes.is_empty():
		has_evacuation_target = false
		_flow_active = false
		is_awaiting_path = false
		current_state = State.IDLE
		wait_timer = 2.0
		return

	var my_position: Vector3 = global_position
	var valid_points: Array[Vector3] = []

	for node: Node in evacuation_nodes:
		var point := node as Node3D

		if point == null or not is_instance_valid(point):
			continue

		var point_position: Vector3 = point.global_position

		if not _is_evacuation_point_failed(point_position):
			valid_points.append(point_position)

	if valid_points.is_empty():
		# Every point is temporarily on cooldown. Clear cooldowns so the NPC
		# can try again rather than becoming permanently unable to evacuate.
		_failed_evac_points.clear()
		has_evacuation_target = false
		_flow_active = false
		is_awaiting_path = false
		current_state = State.IDLE
		wait_timer = 2.0
		return

	valid_points.sort_custom(
		func(a: Vector3, b: Vector3):
			return my_position.distance_squared_to(a) < my_position.distance_squared_to(b)
	)

	var shortlist_size: int = mini(
		evac_shortlist_size,
		valid_points.size()
	)

	# Straight-line ranking avoids running an A* query per NPC just to
	# shortlist candidates. The actual route is still found by A* or the
	# baked flow field when the request is made.
	var best_distance: float = sqrt(
		my_position.distance_squared_to(valid_points[0])
	)
	var near_best: Array[Vector3] = []

	for index: int in shortlist_size:
		var candidate: Vector3 = valid_points[index]
		var distance: float = sqrt(
			my_position.distance_squared_to(candidate)
		)

		if distance <= best_distance * evac_choice_tolerance:
			near_best.append(candidate)

	var best_point: Vector3 = valid_points[0]

	if not near_best.is_empty():
		best_point = near_best.pick_random()

	request_evacuation_target(best_point)


func _request_random_wander_path() -> void:
	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return

	is_awaiting_path = true

	var random_angle: float = randf_range(0.0, TAU)
	var target_position: Vector3 = global_position + Vector3(
		cos(random_angle),
		0.0,
		sin(random_angle)
	) * randf_range(5.0, 12.0)

	grid.request_path(
		self,
		global_position,
		target_position,
		_on_path_received
	)


func _on_path_received(new_path: PackedVector3Array) -> void:
	is_awaiting_path = false

	var previous_length: float = _detour_previous_length
	_detour_previous_length = -1.0

	if _flow_active:
		return

	if not new_path.is_empty():
		if not _detour_route_is_acceptable(new_path, previous_length):
			# Keep the existing route and keep moving; the heat still makes
			# other agents avoid this spot. Retry only after a longer pause.
			_detour_from_flow = false
			_congestion_repath_timer = maxf(
				_congestion_repath_timer,
				CONGESTION_REPATH_INTERVAL * 1.5
			)
			_reset_stuck()
			return

		_detour_from_flow = false
		_evacuation_failures = 0
		_failed_evac_points.clear()

		# NavGridMap applies lane_offset to flow-field evacuation paths.
		current_path = new_path
		path_index = 0
		_reset_stuck()
		return

	# A congestion detour that failed should not discard a still-usable route.
	if _detour_from_flow:
		_detour_from_flow = false
		_flow_active = true
		_flow_wait = 0.0

		if gridmap != null:
			gridmap.ensure_flow_field_cell(_flow_target_cell)
		return

	if not current_path.is_empty() and path_index < current_path.size():
		return

	if current_state == State.SEEKING_EVAC:
		_fail_evacuation()
	else:
		get_tree().create_timer(0.2).timeout.connect(
			choose_next_action
		)


# ============================================================
# RUNTIME MAP CHANGES
# ============================================================

func _on_navigation_changed(changed_cells: Array[Vector3i]) -> void:
	if _repath_pending or current_state == State.DEAD:
		return

	if _flow_active:
		if gridmap != null:
			gridmap.ensure_flow_field_cell(_flow_target_cell)
		return

	if current_path.is_empty() or path_index >= current_path.size():
		return

	if gridmap == null:
		return

	var radius: float = maxf(
		gridmap.cell_size.x,
		gridmap.cell_size.z
	) * 1.2
	var vertical_tolerance: float = gridmap.cell_size.y * 2.0

	for cell: Vector3i in changed_cells:
		var center: Vector3 = gridmap.to_global(
			gridmap.map_to_local(cell)
		)

		if _path_passes_near(
			center,
			radius,
			vertical_tolerance
		):
			_repath_pending = true
			get_tree().create_timer(
				randf_range(0.05, 0.5)
			).timeout.connect(_repath)
			return


func _path_passes_near(
	point: Vector3,
	radius: float,
	vertical_tolerance: float
) -> bool:
	var previous: Vector3 = global_position

	for index: int in range(path_index, current_path.size()):
		var next: Vector3 = current_path[index]
		var closest: Vector3 = (
			Geometry3D.get_closest_point_to_segment(
				point,
				previous,
				next
			)
		)
		var difference: Vector3 = closest - point

		if (
			Vector2(difference.x, difference.z).length() < radius
			and absf(difference.y) < vertical_tolerance
		):
			return true

		previous = next

	return false


func _repath() -> void:
	_repath_pending = false

	if (
		current_state == State.DEAD
		or is_awaiting_path
		or not is_inside_tree()
	):
		return

	if _flow_active:
		if gridmap != null:
			gridmap.ensure_flow_field_cell(_flow_target_cell)
		return

	if current_path.is_empty() or path_index >= current_path.size():
		return

	if current_state == State.SEEKING_EVAC:
		_route_to_closest_evac_point()
		return

	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return

	is_awaiting_path = true

	grid.request_path(
		self,
		global_position,
		current_path[current_path.size() - 1],
		_on_path_received
	)


## Snapshot consumed by EvacuationManager when this NPC reaches an exit.
func get_evacuation_snapshot() -> Dictionary:
	return {
		"distance": _distance_travelled,
		"stuck_time": _stuck_time_total,
		"peak_density": _peak_density,
		"stuck_strikes": _stuck_strikes,
		"state": int(current_state),
		"target": _last_evac_target,
	}
