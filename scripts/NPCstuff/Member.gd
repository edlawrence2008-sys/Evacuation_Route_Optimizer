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
@export var movement_speed: float = 4.0
@export var enable_energy: bool = false
@export var energy: float = 100.0
@export var hunger: float = 0.0

@export_group("Individuality & Variety")
@export var max_extra_speed: float = 1.5
@export var max_extra_lane_offset: float = 0.5
@export var max_extra_separation_radius: float = 0.5
@export var max_extra_separation_push: float = 1.0

@export_group("Crowd Dynamics")
@export var enable_crowd_damage: bool = false
@export var crowd_threshold: int = 10
@export var crush_damage_per_sec: float = 0.5
@export var max_neighbors: int = 16
@export var max_vertical_neighbor_distance: float = 1.5

@export_group("Collision")
## When enabled, a stuck NPC may briefly stop colliding with other NPCs.
## When disabled, NPCs always collide with each other.
@export var allow_collision_disable: bool = true:
	set(value):
		allow_collision_disable = value
		_apply_collision_policy()

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
@export var jump_force: float = 6.0
@export var jump_push_force: float = 3.0
@export var stuck_time_threshold: float = 0.5
@export var jump_cooldown: float = 1.5
@export var stuck_progress_ratio: float = 0.25
@export var obstacle_hop_cooldown: float = 0.4
@export var waypoint_arrival_distance: float = 0.6


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

## Metrics recorded for the evacuation results panel.
var _distance_travelled: float = 0.0
var _stuck_time_total: float = 0.0
var _peak_density: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _has_last_position: bool = false

const LOGIC_TICK_RATE: float = 0.15
## Steering decisions run at this rate. Movement still happens every physics tick.
@export var movement_rate: float = 30.0

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

	if evacuation_manager and evacuation_manager.has_method("register_npc"):
		evacuation_manager.register_npc(self)

	if health_component:
		health_component.damaged.connect(_on_damaged)
		health_component.health_depleted.connect(_on_health_depleted)
		health_component.health_changed.connect(
			func(current: float, max_health: float):
				if animator:
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

	_movement_accum += delta
	var interval: float = 1.0 / maxf(movement_rate, 1.0)
	var update_steering: bool = _movement_accum >= interval
	var step: float = _movement_accum
	var wants_to_move: bool = false
	var move_direction: Vector3 = Vector3.ZERO

	if update_steering:
		_movement_accum = 0.0

		_update_timers(step)

		var is_grounded: bool = is_on_floor()

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
				wants_to_move = not current_path.is_empty()

			if wants_to_move:
				move_direction = _get_direction_to_current_waypoint()

		var crowd_adjustment: Vector3 = Vector3.ZERO

		if wants_to_move and move_direction.length_squared() > 0.001:
			# Only apply sideways crowd separation while following a path.
			# This prevents separation forces from directly reversing navigation.
			var lateral_push: Vector3 = (
				_crowd_push
				- move_direction * _crowd_push.dot(move_direction)
			)

			crowd_adjustment = lateral_push.limit_length(
				actual_movement_speed * 0.35
			)

		var desired_velocity: Vector3 = (
			move_direction * actual_movement_speed
			+ crowd_adjustment
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

	# Movement runs every physics tick. Steering may run at movement_rate, but
	# move_and_slide() always integrates with the physics delta; skipping a tick
	# silently halves the distance the NPC can cover.
	move_and_slide()

	_track_movement_distance()

	if update_steering:
		if wants_to_move and is_on_floor():
			_try_obstacle_hop(move_direction)
			_update_stuck_detection(step, wants_to_move, is_on_floor())

		logic_tick_timer += step

		if logic_tick_timer >= LOGIC_TICK_RATE:
			_process_npc_brain(logic_tick_timer)
			logic_tick_timer = 0.0


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


# ============================================================
# MOVEMENT
# ============================================================

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
		var passed_waypoint: bool = false

		if path_index > 0:
			var previous: Vector3 = current_path[path_index - 1]
			var segment := Vector2(
				waypoint.x - previous.x,
				waypoint.z - previous.z
			)

			if segment.length_squared() > 0.0001:
				segment = segment.normalized()
				passed_waypoint = to_waypoint.dot(segment) < 0.0

		if reached_waypoint or passed_waypoint:
			path_index += 1
		else:
			break

	if path_index >= current_path.size():
		_finish_path()


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

func _try_obstacle_hop(move_direction: Vector3) -> void:
	if (
		_obstacle_hop_timer > 0.0
		or move_direction.length_squared() < 0.01
		or not is_on_wall()
	):
		return

	if path_index >= current_path.size():
		return

	var needs_climb: bool = (
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
	query.exclude = [get_rid()]

	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(
		query
	)

	return hit.is_empty() or hit.collider is CharacterBody3D


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

	if path_index >= current_path.size():
		_reset_stuck()
		return

	var waypoint: Vector3 = current_path[path_index]
	var distance: float = Vector2(
		global_position.x - waypoint.x,
		global_position.z - waypoint.z
	).length()

	if path_index != _stuck_sample_index:
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
	_restore_layer_2()


func _restore_layer_2() -> void:
	if _layer_2_disabled:
		_layer_2_disabled = false
		collision_mask |= 1 << 1


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
	if not is_grounded or jump_cooldown_timer > 0.0:
		return

	var random_angle: float = randf_range(0.0, TAU)

	velocity.y = jump_force
	velocity.x = cos(random_angle) * jump_push_force
	velocity.z = sin(random_angle) * jump_push_force
	jump_cooldown_timer = jump_cooldown


func _on_stuck(is_grounded: bool) -> void:
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
			if _should_evacuate():
				current_state = State.SEEKING_EVAC
				current_path.clear()
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
	if animator:
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

	if _should_evacuate():
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
		current_state = State.IDLE
		wait_timer = 2.0
		return

	var evacuation_nodes: Array[Node] = get_tree().get_nodes_in_group(
		"EvacPoint"
	)

	if evacuation_nodes.is_empty():
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

	if _flow_active:
		return

	if not new_path.is_empty():
		_evacuation_failures = 0
		_failed_evac_points.clear()

		# NavGridMap applies lane_offset to flow-field evacuation paths.
		current_path = new_path
		path_index = 0
		_reset_stuck()
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
