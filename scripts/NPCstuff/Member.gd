extends CharacterBody3D

## Measurement/recording hook. Emitted whenever this agent is assigned a new
## evacuation route or target, and once when a route attempt fails. The payload
## is intentionally self-contained so a recorder can be added without Member
## knowing about it. See docs/SIM_MEASUREMENTS.md.
signal route_changed(info: Dictionary)
## Emitted immediately when the chosen exit/destination changes, before a path
## is requested. Recorders must not infer this from later snapshots.
signal destination_changed(info: Dictionary)

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
## Mean free-walking speed, m/s. Weidmann (1993) reports 1.34 m/s with a
## 0.26 m/s standard deviation for mixed pedestrian traffic; that is the
## default distribution (see use_desired_speed_distribution).
@export var movement_speed: float = 1.34
@export var enable_energy: bool = false
@export var energy: float = 100.0
@export var hunger: float = 0.0

@export_group("Individuality & Variety")
## Legacy uniform speed spread. Only used when
## use_desired_speed_distribution is false.
@export var max_extra_speed: float = 0.0
## Extra lateral path offset (metres). Defaults to zero because lanes are an
## emergent property of the social force model, not an authored offset.
@export var max_extra_lane_offset: float = 0.0

@export_group("Crowd Dynamics")
@export var enable_crowd_damage: bool = false
@export var crowd_threshold: int = 10
@export var crush_damage_per_sec: float = 0.5
@export var max_neighbors: int = 16
## When enabled, a higher-serial agent backs off to break a crowd deadlock.
## Disable to make agents keep their line and rely on the social forces.
@export var allow_yielding: bool = true

@export_group("Collision")
## Only used on the engine-collision path. In the default kinematic mode NPCs
## carry collision_mask = 0 and rely on the SFM contact force instead.
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
## How often the sprite's facing/animation state is refreshed, seconds. The
## node transform still follows the body every frame; this only throttles the
## per-agent visual bookkeeping (row selection, ground offset, frame changes).
@export_range(0.0, 0.5, 0.01) var sprite_update_interval: float = 0.1:
	set(value):
		sprite_update_interval = maxf(value, 0.0)
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

@export_group("AI State")
@export var is_evacuee: bool = true
@export var evac_shortlist_size: int = 3
@export var evac_choice_tolerance: float = 5
@export var evac_confirm_timeout: float = 3.0
@export var max_evacuation_failures: int = 3
@export var failed_evac_point_cooldown: float = 5.0
## Maximum time an agent will wait at an exit that is processing a queue. When
## the wait expires the agent gives up on that exit and re-routes. This is a
## fail-safe against a permanently full receiving area.
@export var max_exit_hold_time: float = 120.0

@export_group("Movement & Physics")
## Only used on the engine-collision path. Kinematic agents climb one-block
## steps with the ground probe and never use the obstacle/random hop.
@export var allow_jumping: bool = true
@export var jump_force: float = 6.0
@export var jump_push_force: float = 3.0
@export var stuck_time_threshold: float = 0.5
@export var jump_cooldown: float = 1.5
@export var stuck_progress_ratio: float = 0.25
@export var obstacle_hop_cooldown: float = 0.4
@export var waypoint_arrival_distance: float = 0.3

@export_group("Social Force Model")
## Collision radius of the body used by the crowd solver, metres. Must match
## the collider in Member.tscn.
@export_range(0.05, 1.0, 0.01) var body_radius: float = 0.25
## Body mass, kg. Used for force -> acceleration and contact impulse.
@export_range(20.0, 200.0, 1.0) var body_mass: float = 78.0
## Relaxation time tau, seconds. Helbing et al. use ~0.5 s; it sets how
## quickly an agent reaches its desired velocity.
@export_range(0.05, 2.0, 0.01) var relaxation_time: float = 0.5
## Sample the individual desired speed from a truncated normal distribution
## instead of using movement_speed verbatim.
@export var use_desired_speed_distribution: bool = true
@export var desired_speed_std: float = 0.26
@export var desired_speed_min: float = 0.6
@export var desired_speed_max: float = 2.2
## Multiplier on the crowd solver's psychological force. 1 = as solved.
@export_range(0.0, 2.0, 0.01) var social_force_scale: float = 1.0
## Multiplier on the wall repulsion. 1 = as configured on the grid map.
@export_range(0.0, 2.0, 0.01) var wall_force_scale: float = 1.0:
	set(value):
		wall_force_scale = value
		_wall_force_dirty = true
## How often wall repulsion is re-sampled, seconds. The force changes smoothly
## with distance, so 0.1 s (10 Hz) is indistinguishable from per-tick sampling.
@export_range(0.0, 0.5, 0.01) var wall_force_update_interval: float = 0.1
## When true, NPCs keep colliding with each other's physics bodies and the
## social contact force is disabled. When false (default), NPC-NPC contact is
## handled by SFM and the engine only resolves world geometry.
@export var use_physics_contact: bool = false:
	set(value):
		use_physics_contact = value
		_refresh_movement_mode()
		_apply_collision_policy()
## Hard cap on horizontal speed (m/s) so a dense pile cannot launch an agent.
@export var max_horizontal_speed: float = 4.0
## Kinematic movement mode. The agent is moved by its own ground probe instead
## of move_and_slide() against world collision. Required for 600 agents: on a
## voxel GridMap, 600 CharacterBody3D sweeps cost ~20 ms/frame, while one
## downward ray per agent is a fraction of that.
@export var use_kinematic_movement: bool = true:
	set(value):
		use_kinematic_movement = value
		_refresh_movement_mode()
		_apply_collision_policy()
## Highest step (metres) the kinematic probe climbs in one tick. The nav grid
## connects one-block step-up edges (NEIGHBOR_OFFSETS includes y = +1), and
## slabs/stairs can present a full 1 m surface, so this must cover one voxel.
## 1.05 keeps a small float margin; a two-block face is still a wall.
@export var kinematic_step_height: float = 1.05
## Largest drop the probe snaps down in one tick. Keeping this below the step
## height lets a 1 m ledge be a short fall rather than an instant snap.
@export var kinematic_snap_down_height: float = 0.65

@export_group("Pre-movement")
## Time from the alarm to the first movement, seconds. Sampled lognormal so
## the distribution is right-skewed like observed pre-movement times.
@export var pre_movement_enabled: bool = true
@export var pre_movement_mean: float = 6.0
@export var pre_movement_sigma: float = 0.7
@export var pre_movement_max: float = 45.0

@export_group("Exit Choice")
## Utility = -beta_d * path_distance - beta_q * queue_density
##           + beta_visible * line_of_sight + familiarity.
@export var exit_choice_beta_distance: float = 0.012
@export var exit_choice_beta_queue: float = 3.0
@export var exit_choice_beta_visible: float = 1.5
@export var exit_choice_familiarity: float = 0.8
## Softmax temperature used to sample the exit. 0 = always the best utility.
@export_range(0.0, 2.0, 0.01) var exit_choice_temperature: float = 0.35


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

var lane_offset: float = 0.0
var local_density: float = 0.0

# --- Social Force Model state ---------------------------------------------
## Monotonic agent id assigned at spawn. Used for the deterministic
## right-of-way tie-break and as part of the agent RNG seed.
var agent_serial: int = 0
## Per-agent random stream. Seeded from (GlobalData.rng_seed, agent_serial) so
## spawn order and instance ids never influence behaviour.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Desired (free) walking speed sampled once at spawn.
var desired_speed: float = 1.34
## Unit vector the agent wants to walk along. Read by the crowd solver for
## the anisotropy weight.
var _desired_direction: Vector3 = Vector3.ZERO
## Acceleration (m/s^2) produced by the crowd solver this tick.
var _social_accel: Vector3 = Vector3.ZERO
## Acceleration (m/s^2) from wall repulsion this tick.
var _wall_accel: Vector3 = Vector3.ZERO
## Sum of contact normal forces this tick, N. Instrumentation and crush model.
var contact_force: float = 0.0
var contact_overlaps: int = 0
## Pre-movement delay sampled at spawn and the time already spent waiting.
var _pre_movement_delay: float = 0.0
var _pre_movement_elapsed: float = 0.0
var _has_started_moving: bool = false

# --- Kinematic movement state --------------------------------------------
## Cached movement-mode flag, refreshed by the export setters so hot paths do
## not recompute it thousands of times per frame.
var _kinematic_active: bool = true
## True when the last ground probe found support under the agent.
var _kinematic_grounded: bool = false
## Origin height that corresponds to standing on the last probed ground.
var _kinematic_stand_y: float = 0.0
## Distance from the node origin to the bottom of the collision sphere.
var _foot_offset: float = 0.25
## Reused ray query so 600 agents do not allocate one per tick.
var _ground_query: PhysicsRayQueryParameters3D = null
## Single-entry ground-probe cache. Agents move a few centimetres per tick, so
## re-probing the same 0.2 m bucket every tick is wasted work. Only used while
## grounded; airborne agents need a fresh hit to detect the landing surface.
var _ground_probe_cache_valid: bool = false
var _ground_probe_cache_key: Vector3i = Vector3i.ZERO
var _ground_probe_cache_hit: Dictionary = {}
const GROUND_PROBE_CACHE_HORIZONTAL: float = 0.15
const GROUND_PROBE_CACHE_VERTICAL: float = 0.4
## Wall repulsion is smooth relative to walking, so sampling it at 10 Hz is
## visually indistinguishable and removes a large per-tick dictionary lookup.
var _wall_force_accum: float = 0.0
var _wall_force_dirty: bool = true
## Sprite animation runs at 5 FPS; updating its visual state every physics tick
## is unnecessary. The transform still follows the body every frame.
var _sprite_update_accum: float = 0.0

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
var _peak_contact_force: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _has_last_position: bool = false

# --- Run measurement state -------------------------------------------------
## Number of route/target reassessments (each emitted route event + failures).
var route_changes: int = 0
## Number of times the chosen destination exit changed.
var route_switch_count: int = 0
## Monotonic id for the current route; 0 = no evacuation route assigned yet.
var route_id: int = 0
var destination_exit_id: String = ""
var destination_exit_name: String = ""
var last_route_reason: String = ""

## External assignment override. When active, the agent keeps this exit instead
## of re-running the local logit choice. Set only through
## set_optimizer_assignment(); cleared on rejection, failure, unavailability,
## admission or an evacuation-mode change. A pre-movement agent stores the
## assignment and uses it when its pre-movement delay expires.
var _optimizer_assignment_active: bool = false
var _optimizer_assigned_exit_id: String = ""
var _optimizer_assigned_target: Vector3 = Vector3.ZERO
## Set by the demo-state importer so the deferred initial action does not
## overwrite the restored state on the next frame.
var _imported_demo_state: bool = false
var last_path_usec: int = 0
## Finite-difference acceleration over one physics tick, m/s^2.
var acceleration: Vector3 = Vector3.ZERO
var _previous_velocity: Vector3 = Vector3.ZERO
var _route_previous_id: int = 0
var _route_previous_target: Vector3 = Vector3.ZERO
var _route_previous_exit_id: String = ""
var _last_requested_target: Vector3 = Vector3.ZERO
var _last_requested_exit_id: String = ""
var _pending_route_reason: String = ""
var _pending_route_started_usec: int = 0
var _spawned_at_sim: float = -1.0
var _evacuated_at_sim: float = -1.0

const LOGIC_TICK_RATE: float = 0.15
const FALL_CHECK_INTERVAL: float = 0.25
## Substeps used to integrate the social force acceleration. Three substeps at
## a 30 Hz physics rate gives an effective 90 Hz integration for contact.
const SFM_SUBSTEPS: int = 3
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
var _exit_hold_active: bool = false
var _exit_hold_exit: Node = null
var _exit_hold_deadline: float = 0.0
var has_evacuation_target: bool = false
var _evacuation_failures: int = 0


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	add_to_group("npc")
	# Identity and randomness are assigned before anything else so every
	# behaviour derived from them is reproducible for a given run seed.
	agent_serial = GlobalData.claim_agent_serial()
	_rng.seed = hash([GlobalData.rng_seed, agent_serial])
	_spawned_at_sim = GlobalData.sim_now()
	_foot_offset = _measure_foot_offset()
	_ground_query = PhysicsRayQueryParameters3D.new()
	_ground_query.collision_mask = 1
	_ground_query.collide_with_bodies = true
	_ground_query.collide_with_areas = false
	_refresh_ground_exclusions()
	_refresh_movement_mode()
	_apply_collision_policy()

	crowd_manager = get_node_or_null("/root/CrowdManager")
	evacuation_manager = get_node_or_null("/root/EvacuationManager")
	_get_gridmap()

	if not GlobalData.agent_overrides.is_empty():
		_apply_export_overrides(GlobalData.agent_overrides)

	_sanitize_agent_settings()
	_refresh_derived_stats()
	_sample_pre_movement()
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
	# Pre-movement: the agent stays IDLE until this timer expires. IDLE is
	# ticked by _process_npc_brain, so a pause or a hitch does not shorten it.
	wait_timer = _pre_movement_delay
	logic_tick_timer = _rng.randf_range(0.0, LOGIC_TICK_RATE)
	call_deferred("_begin_initial_action")


func _begin_initial_action() -> void:
	# Allow the scene and navigation nodes to finish their current setup.
	await get_tree().process_frame

	if _imported_demo_state:
		# The demo importer restored a concrete state (possibly pre-movement or
		# already seeking an exit). Running the normal opening choice here would
		# overwrite it one frame later.
		return

	if not is_inside_tree() or current_state == State.DEAD:
		return

	if wait_timer > 0.0:
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


## Best-effort restore from a recorded demo tick. This preserves identity,
## position, chosen exit, speed, pre-movement remainder and the measurement
## counters that the recorder captures. Route geometry, queue membership and
## contact state are rebuilt by the normal simulation after the import.
func apply_demo_state(state: Dictionary) -> void:
	if state.is_empty():
		return

	_imported_demo_state = true

	var restored_serial: int = int(state.get("serial", agent_serial))
	if restored_serial > 0:
		agent_serial = restored_serial
		_rng.seed = hash([GlobalData.rng_seed, agent_serial])

	var restored_position: Vector3 = state.get(
		"position", global_position
	)
	global_position = restored_position
	_last_position = restored_position
	_has_last_position = true
	velocity = state.get("velocity", Vector3.ZERO)
	acceleration = state.get("acceleration", Vector3.ZERO)

	var recorded_speed: float = float(state.get("desired_speed", 0.0))

	if recorded_speed > 0.0:
		desired_speed = maxf(0.1, recorded_speed)

	is_evacuee = bool(state.get("is_evacuee", is_evacuee))
	contact_force = maxf(0.0, float(state.get("contact_force", 0.0)))
	local_density = maxf(0.0, float(state.get("density", 0.0)))

	_distance_travelled = maxf(0.0, float(state.get("distance", 0.0)))
	_peak_density = maxf(
		local_density, float(state.get("peak_density", 0.0))
	)
	_peak_contact_force = maxf(
		contact_force, float(state.get("peak_contact_force", 0.0))
	)
	route_changes = maxi(0, int(state.get("route_changes", 0)))
	route_switch_count = maxi(0, int(state.get("route_switches", 0)))

	var spawned_at: float = float(state.get("spawned_at", -1.0))
	if spawned_at >= 0.0:
		_spawned_at_sim = spawned_at

	_reset_stuck()
	_stuck_time_total = maxf(0.0, float(state.get("stuck_time", 0.0)))
	_stuck_strikes = maxi(0, int(state.get("stuck_strikes", 0)))

	var pre_delay: float = maxf(0.0, float(state.get("pre_movement_delay", 0.0)))
	var pre_wait: float = maxf(0.0, float(state.get("pre_movement_wait", 0.0)))
	var was_pre_movement: bool = String(state.get("status", "")) == "pre_movement"

	if pre_delay > 0.0:
		_pre_movement_delay = pre_delay

		if was_pre_movement:
			_pre_movement_elapsed = clampf(pre_wait, 0.0, pre_delay)
			_has_started_moving = false
			wait_timer = maxf(pre_delay - _pre_movement_elapsed, 0.0)
		else:
			_pre_movement_elapsed = pre_delay
			_has_started_moving = true
			wait_timer = 0.0
	else:
		_pre_movement_delay = 0.0
		_pre_movement_elapsed = 0.0
		_has_started_moving = true
		wait_timer = 0.0

	clear_optimizer_assignment()
	has_evacuation_target = false

	var recorded_state: int = int(state.get("state", State.IDLE))
	var exit_id: String = String(state.get("exit_id", ""))
	var exit_target: Vector3 = state.get("destination", Vector3.ZERO)

	if exit_target == Vector3.ZERO and not exit_id.is_empty():
		exit_target = _live_exit_target(exit_id)

	var has_exit: bool = (
		not exit_id.is_empty() and exit_target != Vector3.ZERO
	)

	if was_pre_movement:
		current_state = State.IDLE
	elif recorded_state == State.WANDERING:
		# A recorded wanderer did not have a destination yet. Let the normal
		# brain choose a fresh one after a short delay.
		current_state = State.IDLE
		_has_started_moving = true
		wait_timer = _rng.randf_range(0.1, 0.5)
	elif recorded_state == State.SEEKING_EVAC or recorded_state == State.ARRIVED:
		current_state = State.SEEKING_EVAC
	elif recorded_state == State.IDLE:
		current_state = State.IDLE
		_has_started_moving = true
		wait_timer = 0.0
	else:
		current_state = State.IDLE
		_has_started_moving = true
		wait_timer = 0.0

	if has_exit and not was_pre_movement:
		var used_optimizer: bool = bool(state.get("optimizer_assigned", false))

		if used_optimizer:
			set_optimizer_assignment(exit_id, exit_target)
		else:
			request_evacuation_target(exit_target, "demo_restore")
	elif has_exit and bool(state.get("optimizer_assigned", false)):
		# Pre-movement agents keep an optimizer assignment until their delay
		# expires, exactly as the live assignment path does.
		set_optimizer_assignment(exit_id, exit_target)

	if not has_exit and current_state == State.SEEKING_EVAC:
		# Recorded exit no longer exists in this map. Let the normal choice run
		# instead of leaving the agent stuck on a missing target.
		current_state = State.IDLE
		_has_started_moving = true
		wait_timer = 0.0


## Resolves a recorded exit id to the live EvacPoint position. Missing exits
## return ZERO so the caller can fall back to the local choice.
func _live_exit_target(exit_id: String) -> Vector3:
	if exit_id.is_empty() or get_tree() == null:
		return Vector3.ZERO

	for node: Node in get_tree().get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node):
			continue

		if not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")

		if String(status.get("exit_id", "")) != exit_id:
			continue

		if node is Node3D:
			return (node as Node3D).global_position

	return Vector3.ZERO


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
	sprite_pixel_size = maxf(sprite_pixel_size, 0.0001)
	sprite_walk_fps = maxf(sprite_walk_fps, 1.0)
	sprite_rim_strength = clampf(sprite_rim_strength, 0.0, 1.0)
	sprite_bounce_strength = maxf(sprite_bounce_strength, 0.0)
	sprite_normal_strength = maxf(sprite_normal_strength, 0.0)
	body_radius = clampf(body_radius, 0.05, 1.0)
	body_mass = maxf(1.0, body_mass)
	relaxation_time = maxf(0.05, relaxation_time)
	desired_speed_std = maxf(0.0, desired_speed_std)
	desired_speed_min = maxf(0.05, desired_speed_min)
	desired_speed_max = maxf(desired_speed_min, desired_speed_max)
	max_horizontal_speed = maxf(0.5, max_horizontal_speed)
	kinematic_step_height = maxf(0.1, kinematic_step_height)
	kinematic_snap_down_height = clampf(
		kinematic_snap_down_height,
		0.05,
		kinematic_step_height
	)
	wall_force_update_interval = maxf(0.0, wall_force_update_interval)
	sprite_update_interval = maxf(0.0, sprite_update_interval)
	pre_movement_mean = maxf(0.0, pre_movement_mean)
	pre_movement_sigma = maxf(0.0, pre_movement_sigma)
	pre_movement_max = maxf(0.0, pre_movement_max)
	exit_choice_beta_distance = maxf(0.0, exit_choice_beta_distance)
	exit_choice_beta_queue = maxf(0.0, exit_choice_beta_queue)
	exit_choice_beta_visible = maxf(0.0, exit_choice_beta_visible)
	exit_choice_temperature = maxf(0.0, exit_choice_temperature)


func _refresh_derived_stats() -> void:
	# Weidmann-style free-walking speed distribution. The mean is the export
	# value; the spread is a truncated normal around it.
	if use_desired_speed_distribution:
		desired_speed = clampf(
			maxf(0.0, movement_speed)
			+ _rng.randfn(0.0, desired_speed_std),
			desired_speed_min,
			desired_speed_max
		)
	else:
		desired_speed = clampf(
			maxf(0.0, movement_speed)
			+ _rng.randf_range(0.0, maxf(0.0, max_extra_speed)),
			desired_speed_min,
			desired_speed_max
		)

	actual_movement_speed = desired_speed

	var cell_size: float = gridmap.cell_size.x if gridmap else 1.0
	var effective_lane_strength: float = (
		maxf(0.0, lane_offset_strength)
		+ _rng.randf_range(0.0, maxf(0.0, max_extra_lane_offset))
	)

	lane_offset = (
		_rng.randf_range(-1.0, 1.0)
		* effective_lane_strength
		* cell_size
	)


## Lognormal pre-movement time, truncated at pre_movement_max. A lognormal is
## the usual empirical shape for "time until the first move" (right-skewed,
## non-negative). mean is the arithmetic mean of the untruncated distribution.
func _sample_pre_movement() -> void:
	_pre_movement_elapsed = 0.0
	_has_started_moving = false

	if not pre_movement_enabled or pre_movement_mean <= 0.0:
		_pre_movement_delay = 0.0
		return

	var sigma: float = pre_movement_sigma
	var mu: float = log(pre_movement_mean) - 0.5 * sigma * sigma
	var sample: float = exp(mu + sigma * _rng.randfn(0.0, 1.0))
	_pre_movement_delay = clampf(sample, 0.0, pre_movement_max)


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

	_movement_accum += delta
	var interval: float = 1.0 / maxf(movement_rate, 1.0)
	# The epsilon keeps an exact 30 Hz movement_rate from skipping ticks through
	# float accumulation, which would otherwise halve the covered distance.
	var update_steering: bool = _movement_accum + 0.0001 >= interval
	var step: float = _movement_accum
	var wants_to_move: bool = false
	var move_direction: Vector3 = Vector3.ZERO
	var speed_scale: float = 1.0

	if update_steering:
		_movement_accum = 0.0

		_update_timers(step)

		# Another character's body is never valid ground: an agent balanced on
		# someone's head counts as airborne so it cannot walk, hop or steer
		# from on top of the crowd.
		var is_grounded: bool = _is_grounded()

		# Kinematic mode integrates gravity in _move_kinematic(), including
		# stair support, so it must not double-apply here.
		if not _uses_kinematic_movement():
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

		if _yield_timer > 0.0:
			# Deadlock yield: the lower-priority agent steps aside. The social
			# force model then resolves the physical squeeze without turning off
			# NPC-NPC collision.
			wants_to_move = true
			move_direction = _yield_direction
			speed_scale = YIELD_SPEED_SCALE
		elif not wants_to_move:
			_last_move_direction = Vector3.ZERO

		# Direction the solver uses for the anisotropy weight. Zero when the
		# agent has no goal, which makes it isotropic (and therefore easier to
		# push around) while queueing.
		_desired_direction = Vector3.ZERO

		if wants_to_move and move_direction.length_squared() > 0.0001:
			_desired_direction = move_direction.normalized()

		var desired_velocity: Vector3 = (
			_desired_direction * actual_movement_speed * speed_scale
		)

		_update_wall_force(step)
		_steer_with_social_forces(
			step,
			desired_velocity,
			is_grounded
		)

	# Movement runs every physics tick. Steering may run at movement_rate, but
	# the integrator always advances by the physics delta; skipping a tick
	# silently halves the distance the NPC can cover.
	var pre_move_position: Vector3 = global_position
	var pre_move_grounded: bool = _is_grounded()

	if _uses_kinematic_movement():
		_move_kinematic(delta)
	else:
		# Agents never stand on other characters (or the player): a body
		# balanced on someone else's collider slides off instead of becoming
		# a step.
		_slide_off_character_floor(delta)
		move_and_slide()
		_keep_on_walkable_ground(pre_move_position, pre_move_grounded)

	if realistic_sprites_mode and _sprite_visual != null:
		_sprite_update_accum += delta

		if (
			sprite_update_interval <= 0.0
			or _sprite_update_accum >= sprite_update_interval
		):
			_sprite_visual.call("tick", _sprite_update_accum)
			_sprite_update_accum = 0.0

	_track_movement_distance()

	# Measurement: acceleration is the change in velocity over this tick. The
	# SFM integrator writes velocity directly, so this is the effective
	# kinematic acceleration rather than only the steering force.
	acceleration = (velocity - _previous_velocity) / maxf(delta, 0.0001)
	_previous_velocity = velocity

	if update_steering:
		var grounded_now: bool = _is_grounded()
		if wants_to_move and grounded_now and _yield_timer <= 0.0:
			_try_obstacle_hop(move_direction)
			_update_stuck_detection(step, wants_to_move, grounded_now)

		logic_tick_timer += step

		if logic_tick_timer >= LOGIC_TICK_RATE:
			_process_npc_brain(logic_tick_timer)
			logic_tick_timer = 0.0


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
	if _uses_kinematic_movement():
		# The kinematic step already refuses unsupported ground.
		return

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
	_pending_route_reason = "detour"
	_pending_route_started_usec = Time.get_ticks_usec()
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
	_pending_route_reason = "corner"
	_pending_route_started_usec = Time.get_ticks_usec()
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
		wait_timer = _rng.randf_range(1.0, 3.0)


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
		wait_timer = _rng.randf_range(1.0, 3.0)


# ============================================================
# EXIT QUEUE / EVACUATION LIFECYCLE
# ============================================================

## Called by an EvacPoint when this agent has to wait for an exit service slot
## or for room in the receiving area. The agent stops navigating and keeps its
## place in the Active crowd so it still contributes to density and contact
## force while queueing.
func begin_exit_hold(exit_point: Node) -> void:
	if current_state == State.DEAD or has_meta("evacuated"):
		return

	_exit_hold_active = true
	_exit_hold_exit = exit_point
	_exit_hold_deadline = (
		_now_seconds() + maxf(1.0, max_exit_hold_time)
	)

	has_evacuation_target = true
	current_state = State.ARRIVED
	_flow_active = false
	_flow_wait = 0.0
	is_awaiting_path = false
	_repath_pending = false
	current_path.clear()
	path_index = 0
	wait_timer = evac_confirm_timeout


## The area was left, or the exit was deleted, before service completed. Clear
## the hold without treating it as an evacuation failure so the agent can pick
## a route again.
func on_exit_area_exited() -> void:
	if not _exit_hold_active or has_meta("evacuated"):
		return

	_exit_hold_active = false
	_exit_hold_exit = null
	_exit_hold_deadline = 0.0

	if current_state == State.DEAD:
		return

	has_evacuation_target = false
	current_state = State.IDLE
	wait_timer = 0.35


## The exit rejected this agent (full receiving area or full queue). Put that
## specific exit on cooldown so the next choice goes elsewhere, but do not count
## it as a path failure.
func reject_evacuation(_reason: String = "capacity") -> void:
	if current_state == State.DEAD or has_meta("evacuated"):
		return

	_exit_hold_active = false
	_exit_hold_exit = null
	_exit_hold_deadline = 0.0
	clear_optimizer_assignment()

	if _last_evac_target != Vector3.ZERO:
		_mark_evacuation_point_failed(_last_evac_target)

	has_evacuation_target = false
	current_state = State.IDLE
	current_path.clear()
	path_index = 0
	is_awaiting_path = false
	_flow_active = false
	_flow_wait = 0.0
	wait_timer = _rng.randf_range(0.2, 0.8)


## Fail-safe used when a queued agent waits longer than max_exit_hold_time.
## Removes the agent from the exit queue and asks the normal failure path to
## choose a different exit.
func resume_evacuation() -> void:
	if (
		_exit_hold_exit != null
		and is_instance_valid(_exit_hold_exit)
		and _exit_hold_exit.has_method("cancel_agent")
	):
		_exit_hold_exit.cancel_agent(self)

	_exit_hold_active = false
	_exit_hold_exit = null
	_exit_hold_deadline = 0.0
	_fail_evacuation()


## Marks the agent as successfully evacuated and removes it from every active
## agent system. The node can stay alive (and visible) afterwards without
## influencing navigation, crowd density, contact force or run completion.
func mark_evacuated() -> void:
	if has_meta("evacuated"):
		return

	set_meta("evacuated", true)
	_evacuated_at_sim = GlobalData.sim_now()
	_exit_hold_active = false
	_exit_hold_exit = null
	_exit_hold_deadline = 0.0
	clear_optimizer_assignment()
	is_evacuee = false
	has_evacuation_target = false
	_awaiting_evac_confirmation = false
	_flow_active = false
	_flow_wait = 0.0
	is_awaiting_path = false
	_repath_pending = false
	current_path.clear()
	path_index = 0
	velocity = Vector3.ZERO

	if is_instance_valid(gridmap):
		gridmap.cancel_path_requests(self)

	remove_from_group("npc")
	# The spawner uses the Members group for its live-agent cap; a retained
	# evacuated agent must not count against future spawns.
	remove_from_group("Members")
	collision_layer = 0
	collision_mask = 0
	set_physics_process(false)
	set_process(false)

	if animator != null:
		animator.set_physics_process(false)
		animator.set_process(false)

	if _sprite_visual != null:
		_sprite_visual.set_physics_process(false)
		_sprite_visual.set_process(false)


func is_evacuated() -> bool:
	return has_meta("evacuated")


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
	if _uses_kinematic_movement():
		# Kinematic bodies do not collide with each other or the world, so
		# there are no slide collisions to inspect.
		return null

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
	if not use_physics_contact:
		return

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
	if not use_physics_contact:
		return

	if not allow_collision_disable:
		_apply_collision_policy()
		return

	if not _layer_2_disabled:
		_layer_2_disabled = true
		collision_mask &= ~(1 << 1)


## NPC-NPC contact is owned by the Social Force Model by default. Kinematic
## movement additionally takes the body out of world collision and follows the
## grid with a downward probe, which is what makes 600 agents affordable.
## Set use_physics_contact (or use_kinematic_movement = false) to restore
## engine-level collision.
func _apply_collision_policy() -> void:
	_layer_2_disabled = false

	if _uses_kinematic_movement():
		collision_mask = 0
		return

	collision_mask = 1

	if use_physics_contact:
		collision_mask |= 1 << 1


func _refresh_movement_mode() -> void:
	_kinematic_active = use_kinematic_movement and not use_physics_contact
	_ground_probe_cache_valid = false


func _uses_kinematic_movement() -> bool:
	return _kinematic_active


func _measure_foot_offset() -> float:
	var shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D

	if shape_node != null and shape_node.shape is SphereShape3D:
		return shape_node.position.y - (shape_node.shape as SphereShape3D).radius

	return 0.25


func _random_hop(is_grounded: bool) -> void:
	# Kinematic agents do not collide with the world, so a hop could carry one
	# through a wall and leave it inside geometry. Hopping was only a workaround
	# for engine collision, and the solver + repath handle stuck agents instead.
	if _uses_kinematic_movement():
		return

	if not allow_jumping or not is_grounded or jump_cooldown_timer > 0.0:
		return

	var random_angle: float = _rng.randf_range(0.0, TAU)

	velocity.y = jump_force
	velocity.x = cos(random_angle) * jump_push_force
	velocity.z = sin(random_angle) * jump_push_force
	jump_cooldown_timer = jump_cooldown


## Deterministic right-of-way. When two agents block each other, the higher
## agent serial backs away diagonally for a short time; the lower serial keeps
## moving. This breaks head-on deadlocks without disabling NPC collision and,
## unlike instance IDs, is independent of spawn/engine order.
func _try_deadlock_yield(blocker: CharacterBody3D = null) -> bool:
	if not allow_yielding or _yield_timer > 0.0:
		return false

	if blocker == null:
		blocker = _find_blocking_npc()

	if blocker == null:
		return false

	var other_serial: int = agent_serial

	if blocker.has_method("get_agent_serial"):
		other_serial = int(blocker.get_agent_serial())
	elif blocker.has_method("get_instance_id"):
		other_serial = int(blocker.get_instance_id())

	if agent_serial < other_serial:
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
	var side_sign: float = 1.0 if (agent_serial & 1) == 0 else -1.0
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
	clear_optimizer_assignment()
	_exit_hold_active = false
	_exit_hold_exit = null
	_exit_hold_deadline = 0.0
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

	_update_crowd_health(elapsed_time)

	if current_state == State.ARRIVED:
		# A finite exit holds the agent while it waits for a service slot or
		# receiving-area capacity. The hold must outlive the normal arrival
		# confirmation timeout, otherwise the agent would abandon its place in
		# the queue and walk away.
		if _exit_hold_active:
			if (
				_exit_hold_deadline > 0.0
				and _now_seconds() >= _exit_hold_deadline
			):
				resume_evacuation()
			return

		wait_timer -= elapsed_time

		if wait_timer <= 0.0:
			# The evac area should have freed this member. If it did not, allow
			# another evacuation attempt instead of wandering forever.
			has_evacuation_target = false
			current_state = State.IDLE
			wait_timer = _rng.randf_range(1.0, 3.0)

		return

	match current_state:
		State.IDLE:
			wait_timer -= elapsed_time

			if not _has_started_moving:
				_pre_movement_elapsed = minf(
					_pre_movement_elapsed + elapsed_time,
					_pre_movement_delay
				)

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


## Crush injury model. The crowd solver measures density inside the density
## radius; crowd_threshold is still expressed in "people nearby", so convert it
## to persons/m^2 with the same area the solver uses. Damage is linear in the
## excess density, which is the usual simplification for a crushing load.
func _update_crowd_health(elapsed_time: float) -> void:
	if (
		not enable_crowd_damage
		or health_component == null
		or crowd_threshold <= 0
	):
		return

	var density_radius: float = 1.4
	var configured_radius: Variant = crowd_manager.get("density_radius") if crowd_manager != null else null

	if configured_radius != null:
		density_radius = float(configured_radius)

	var threshold_density: float = (
		float(crowd_threshold) / (PI * density_radius * density_radius)
	)

	if threshold_density <= 0.0 or local_density <= threshold_density:
		return

	var excess_ratio: float = (
		local_density / threshold_density - 1.0
	)
	health_component.take_damage(
		crush_damage_per_sec * elapsed_time * excess_ratio
	)


# ============================================================
# SOCIAL FORCE MODEL INTERFACE
# ============================================================

## Called by CrowdManager once per solve with the net acceleration (m/s^2)
## from every other agent, the summed contact normal force (N), the overlap
## count and the measured density. Pairwise forces are accumulated centrally
## so both agents are updated in the same pass, with no neighbour cap.
func apply_social_forces(
	social_acceleration: Vector3,
	contact_force_sum: float,
	overlaps: int,
	density: float
) -> void:
	_social_accel = social_acceleration
	contact_force = contact_force_sum
	contact_overlaps = overlaps
	_peak_contact_force = maxf(_peak_contact_force, contact_force_sum)
	set_local_density(density)


func get_body_radius() -> float:
	return body_radius


func get_body_mass() -> float:
	return body_mass


func get_desired_direction() -> Vector3:
	return _desired_direction


func get_flat_velocity() -> Vector3:
	return Vector3(velocity.x, 0.0, velocity.z)


func get_agent_serial() -> int:
	return agent_serial


func get_desired_speed() -> float:
	return desired_speed


## Complete behavioural parameter set for run metadata. Keep this list aligned
## with the exports above; the comparer needs to know what differed between runs.
func get_behavior_parameters() -> Dictionary:
	return {
		"movement_speed": movement_speed,
		"max_extra_speed": max_extra_speed,
		"max_extra_lane_offset": max_extra_lane_offset,
		"lane_offset_strength": lane_offset_strength,
		"use_desired_speed_distribution": use_desired_speed_distribution,
		"desired_speed_std": desired_speed_std,
		"desired_speed_min": desired_speed_min,
		"desired_speed_max": desired_speed_max,
		"body_radius": body_radius,
		"body_mass": body_mass,
		"relaxation_time": relaxation_time,
		"social_force_scale": social_force_scale,
		"wall_force_scale": wall_force_scale,
		"wall_force_update_interval": wall_force_update_interval,
		"use_physics_contact": use_physics_contact,
		"use_kinematic_movement": use_kinematic_movement,
		"kinematic_step_height": kinematic_step_height,
		"kinematic_snap_down_height": kinematic_snap_down_height,
		"max_horizontal_speed": max_horizontal_speed,
		"allow_jumping": allow_jumping,
		"allow_yielding": allow_yielding,
		"waypoint_arrival_distance": waypoint_arrival_distance,
		"stuck_time_threshold": stuck_time_threshold,
		"stuck_progress_ratio": stuck_progress_ratio,
		"enable_crowd_damage": enable_crowd_damage,
		"crowd_threshold": crowd_threshold,
		"crush_damage_per_sec": crush_damage_per_sec,
		"is_evacuee": is_evacuee,
		"evac_shortlist_size": evac_shortlist_size,
		"evac_choice_tolerance": evac_choice_tolerance,
		"evac_confirm_timeout": evac_confirm_timeout,
		"max_evacuation_failures": max_evacuation_failures,
		"failed_evac_point_cooldown": failed_evac_point_cooldown,
		"max_exit_hold_time": max_exit_hold_time,
		"pre_movement_enabled": pre_movement_enabled,
		"pre_movement_mean": pre_movement_mean,
		"pre_movement_sigma": pre_movement_sigma,
		"pre_movement_max": pre_movement_max,
		"exit_choice_beta_distance": exit_choice_beta_distance,
		"exit_choice_beta_queue": exit_choice_beta_queue,
		"exit_choice_beta_visible": exit_choice_beta_visible,
		"exit_choice_familiarity": exit_choice_familiarity,
		"exit_choice_temperature": exit_choice_temperature,
	}


func get_pre_movement_delay() -> float:
	return _pre_movement_delay


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
	_exit_hold_active = false
	_exit_hold_exit = null
	_exit_hold_deadline = 0.0

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
	if is_awaiting_path or current_state == State.DEAD or has_meta("evacuated"):
		return

	_has_started_moving = true

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


## Applies a global assignment from the optimizer bridge. Returns false when the
## agent cannot take one (dead, admitted, already in the exit queue).
##
## Pre-movement is preserved: the assignment is stored, but the agent keeps its
## IDLE wait and picks the assigned exit when the delay expires. That lets the
## optimizer cover the whole population without bypassing the behavioural model.
func set_optimizer_assignment(exit_id: String, target: Vector3) -> bool:
	if current_state == State.DEAD or has_meta("evacuated"):
		return false

	if current_state == State.ARRIVED:
		return false

	if exit_id.is_empty() or target == Vector3.ZERO:
		return false

	_optimizer_assignment_active = true
	_optimizer_assigned_exit_id = exit_id
	_optimizer_assigned_target = target

	if current_state == State.IDLE and not _has_started_moving:
		return true

	if is_instance_valid(gridmap):
		gridmap.cancel_path_requests(self)

	request_evacuation_target(target, "optimizer")
	return true


func clear_optimizer_assignment() -> void:
	_optimizer_assignment_active = false
	_optimizer_assigned_exit_id = ""
	_optimizer_assigned_target = Vector3.ZERO


func has_optimizer_assignment() -> bool:
	return _optimizer_assignment_active


func get_optimizer_exit_id() -> String:
	return _optimizer_assigned_exit_id


func get_optimizer_target() -> Vector3:
	return _optimizer_assigned_target


func request_evacuation_target(
	target: Vector3,
	reason: String = "destination"
) -> void:
	if current_state == State.DEAD or has_meta("evacuated"):
		return

	has_evacuation_target = true
	_last_evac_target = target
	current_state = State.SEEKING_EVAC
	current_path.clear()
	path_index = 0
	_flow_wait = 0.0
	_pending_route_reason = reason
	_pending_route_started_usec = Time.get_ticks_usec()
	_emit_destination_changed(target)

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
			_assign_route(reason, PackedVector3Array(), "flow")
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
	clear_optimizer_assignment()

	if _last_evac_target != Vector3.ZERO:
		_mark_evacuation_point_failed(_last_evac_target)

	if evacuation_manager:
		evacuation_manager.notify_evacuation_failed(
			_last_evac_target
		)

	if route_id > 0 or has_evacuation_target:
		_assign_route("failed", PackedVector3Array(), "failed")

	has_evacuation_target = false
	current_state = State.IDLE
	current_path.clear()
	path_index = 0
	wait_timer = _rng.randf_range(0.5, 1.5)
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
	return GlobalData.sim_now()


func _route_to_closest_evac_point() -> void:
	if is_awaiting_path or _flow_active or current_state == State.DEAD:
		return

	# The optimizer bridge owns this agent's choice. Keep the assigned exit
	# instead of re-running the local logit model; the override is cleared by
	# rejection, failure, unavailability or admission.
	if _optimizer_assignment_active and _optimizer_assigned_target != Vector3.ZERO:
		request_evacuation_target(_optimizer_assigned_target, "optimizer")
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

	var valid_points: Array[Vector3] = []
	var seen_positions: Dictionary = {}
	var unavailable: Dictionary = {}

	# Exits can be disabled at runtime. Collect their quantised keys first so a
	# root node visited before its Area3D cannot sneak an unavailable exit in.
	for node: Node in evacuation_nodes:
		var disabled_exit := node as Node3D

		if (
			disabled_exit == null
			or not is_instance_valid(disabled_exit)
			or not disabled_exit.has_method("is_available")
			or disabled_exit.is_available()
		):
			continue

		var disabled_position: Vector3 = disabled_exit.global_position
		unavailable[Vector3i(
			roundi(disabled_position.x * 2.0),
			roundi(disabled_position.y * 2.0),
			roundi(disabled_position.z * 2.0)
		)] = true

	for node: Node in evacuation_nodes:
		var point := node as Node3D

		if point == null or not is_instance_valid(point):
			continue

		var point_position: Vector3 = point.global_position

		# Each exit is registered twice (root node + trigger area). Deduplicate
		# by position so a duplicated exit does not win twice in the utility
		# model.
		var key := Vector3i(
			roundi(point_position.x * 2.0),
			roundi(point_position.y * 2.0),
			roundi(point_position.z * 2.0)
		)

		if seen_positions.has(key):
			continue

		seen_positions[key] = true

		if unavailable.has(key):
			continue

		if not _is_evacuation_point_failed(point_position):
			valid_points.append(point_position)

	if valid_points.is_empty():
		# Every exit is temporarily on cooldown. Wait for the earliest cooldown
		# instead of clearing all of them and immediately re-choosing: clearing
		# made agents alternate between two failed exits every retry.
		var now: float = _now_seconds()
		var earliest_ready: float = now + 2.0

		for failed_position: Variant in _failed_evac_points.keys():
			earliest_ready = minf(
				earliest_ready, float(_failed_evac_points[failed_position])
			)

		has_evacuation_target = false
		_flow_active = false
		is_awaiting_path = false
		current_state = State.IDLE
		wait_timer = clampf(earliest_ready - now, 0.5, 2.0)
		return

	request_evacuation_target(
		_choose_evacuation_point(grid, valid_points)
	)


## Discrete-choice exit model. Agents do not simply take the nearest exit:
## they weigh route distance, queueing at the exit, whether they can see it,
## and a persistent (per-agent) familiarity term. Utilities are sampled with a
## Gumbel softmax, which is equivalent to a multinomial logit over exits, so
## two agents in the same place need not make the same choice.
##
##   U_j = -beta_d * d_j - beta_q * rho_j + beta_v * visible_j + fam_j
##
## d_j is the route length in metres (baked flow-field cost when available,
## otherwise a straight-line estimate scaled by a documented detour factor),
## rho_j is crowd density in persons/m^2 at the exit, and fam_j is a stable
## uniform value in [0, familiarity] derived from (agent serial, exit).
func _choose_evacuation_point(
	grid: NavGridMap,
	candidates: Array[Vector3]
) -> Vector3:
	var best_point: Vector3 = candidates[0]
	var best_score: float = -INF
	var temperature: float = maxf(exit_choice_temperature, 0.001)

	for point: Vector3 in candidates:
		var path_distance: float = -1.0

		if grid.has_method("get_path_distance"):
			path_distance = grid.get_path_distance(global_position, point)

		if path_distance < 0.0 or not is_finite(path_distance):
			# No baked cost field yet: scale the straight line by 1.2 to
			# approximate route detours without issuing an A* query per exit
			# per agent.
			path_distance = (
				Vector2(
					point.x - global_position.x,
					point.z - global_position.z
				).length() * 1.2
			)

		var queue_density: float = 0.0

		if crowd_manager != null and crowd_manager.has_method("get_density_per_m2"):
			queue_density = crowd_manager.get_density_per_m2(point, 2.0)

		var visibility_score: float = 1.0 if _has_line_of_sight(point) else 0.0
		var familiarity: float = _exit_familiarity(point)

		var utility: float = (
			-exit_choice_beta_distance * path_distance
			-exit_choice_beta_queue * queue_density
			+exit_choice_beta_visible * visibility_score
			+familiarity
		)

		# Gumbel-max sampling: logit noise with the correct extreme-value
		# distribution, so this is a true multinomial logit draw.
		var u: float = clampf(_rng.randf(), 0.000001, 0.999999)
		var gumbel: float = -log(-log(u))
		var score: float = utility / temperature + gumbel

		if score > best_score:
			best_score = score
			best_point = point

	return best_point


## Stable per-agent, per-exit preference. Hashing the serial and the quantised
## exit position means the value does not depend on iteration order.
func _exit_familiarity(point: Vector3) -> float:
	if exit_choice_familiarity <= 0.0:
		return 0.0

	var key: Array = [
		agent_serial,
		roundi(point.x * 10.0),
		roundi(point.y * 10.0),
		roundi(point.z * 10.0),
	]
	var normalized: float = float(abs(hash(key)) % 1000) / 1000.0
	return normalized * exit_choice_familiarity


func _has_line_of_sight(point: Vector3) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, 1.2, 0.0),
		point + Vector3(0.0, 1.0, 0.0),
		1
	)
	query.exclude = [get_rid()]
	query.collide_with_areas = false

	return world.direct_space_state.intersect_ray(query).is_empty()


func _request_random_wander_path() -> void:
	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return

	is_awaiting_path = true

	var random_angle: float = _rng.randf_range(0.0, TAU)
	var target_position: Vector3 = global_position + Vector3(
		cos(random_angle),
		0.0,
		sin(random_angle)
	) * _rng.randf_range(5.0, 12.0)

	grid.request_path(
		self,
		global_position,
		target_position,
		_on_path_received
	)


func _on_path_received(new_path: PackedVector3Array) -> void:
	# A path request can complete after the agent was admitted through an exit.
	# Do not let the late callback revive an inactive, retained agent.
	if has_meta("evacuated"):
		return

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
			_pending_route_reason = ""
			_pending_route_started_usec = 0
			_reset_stuck()
			return

		_detour_from_flow = false
		_evacuation_failures = 0
		# Cooldowns are time-based and must survive a successful path request.
		# Clearing them here let an agent alternate between two failed exits
		# every few hundred milliseconds.

		# NavGridMap applies lane_offset to flow-field evacuation paths.
		current_path = new_path
		path_index = 0
		_reset_stuck()

		if current_state == State.SEEKING_EVAC or has_evacuation_target:
			var reason: String = _pending_route_reason
			if reason.is_empty():
				reason = "path"
			_assign_route(reason, new_path, "path")

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
	# Geometry changed: no cached probe or wall sample is trustworthy.
	_ground_probe_cache_valid = false
	_wall_force_dirty = true

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
				_rng.randf_range(0.05, 0.5)
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
		or has_meta("evacuated")
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
		# A navigation refresh must re-path to the same exit, not re-run the
		# exit choice. Re-choosing here made chunk/nav edits flip agents
		# between near-equal exits.
		var keep_target: Vector3 = (
			_optimizer_assigned_target
			if _optimizer_assignment_active
			else _last_evac_target
		)

		if keep_target != Vector3.ZERO:
			request_evacuation_target(keep_target, "navigation")
		else:
			_route_to_closest_evac_point()
		return

	var grid: NavGridMap = _get_gridmap()

	if grid == null:
		return

	is_awaiting_path = true
	_pending_route_reason = "navigation"
	_pending_route_started_usec = Time.get_ticks_usec()

	grid.request_path(
		self,
		global_position,
		current_path[current_path.size() - 1],
		_on_path_received
	)


## Publish a route assignment for recording and expose the destination exit.
## `mode` is "path", "flow" or "failed". Route ids are monotonic per agent; the
## recorder uses `previous_route_id` to link before/after disruption snapshots.
func _emit_destination_changed(target: Vector3) -> void:
	var identity: Dictionary = _resolve_exit_identity(target)
	var new_exit_id: String = String(identity.get("exit_id", ""))
	var changed: bool = (
		target.distance_to(_last_requested_target) > 0.25
		or new_exit_id != _last_requested_exit_id
	)

	if not changed:
		return

	destination_changed.emit({
		"agent_serial": agent_serial,
		"previous_target": _last_requested_target,
		"previous_exit_id": _last_requested_exit_id,
		"target": target,
		"exit_id": new_exit_id,
		"exit_name": String(identity.get("name", "")),
		"at": GlobalData.sim_now(),
	})
	_last_requested_target = target
	_last_requested_exit_id = new_exit_id


func _assign_route(reason: String, path: PackedVector3Array, mode: String) -> void:
	var target: Vector3 = _last_evac_target
	var identity: Dictionary = _resolve_exit_identity(target)
	var new_exit_id: String = String(identity.get("exit_id", ""))
	var new_exit_name: String = String(identity.get("name", ""))
	var switched: bool = (
		route_id > 0
		and (
			target.distance_to(_route_previous_target) > 0.25
			or new_exit_id != _route_previous_exit_id
		)
	)
	var previous_id: int = route_id
	var path_usec: int = 0

	if _pending_route_started_usec > 0:
		path_usec = Time.get_ticks_usec() - _pending_route_started_usec

	_pending_route_started_usec = 0
	_pending_route_reason = ""
	route_id += 1
	route_changes += 1

	if switched:
		route_switch_count += 1

	_route_previous_id = previous_id
	_route_previous_target = target
	_route_previous_exit_id = new_exit_id
	destination_exit_id = new_exit_id
	destination_exit_name = new_exit_name
	last_route_reason = reason
	last_path_usec = path_usec

	var path_cells: Array = []

	if gridmap != null:
		for point: Vector3 in path:
			var cell: Vector3i = gridmap.local_to_map(
				gridmap.to_local(point)
			)
			path_cells.append([cell.x, cell.y, cell.z])

		if path.is_empty():
			var target_cell: Vector3i = gridmap.local_to_map(
				gridmap.to_local(target)
			)
			path_cells.append([target_cell.x, target_cell.y, target_cell.z])

	var info: Dictionary = {
		"agent_serial": agent_serial,
		"agent_id": get_instance_id(),
		"route_id": route_id,
		"previous_route_id": previous_id,
		"reason": reason,
		"mode": mode,
		"success": mode != "failed",
		"evacuating": current_state == State.SEEKING_EVAC or has_evacuation_target,
		"target": target,
		"exit_id": destination_exit_id,
		"exit_name": destination_exit_name,
		"path": path,
		"path_cells": path_cells,
		"path_points": path.size(),
		"path_usec": path_usec,
		"route_length": _route_length(path),
		"remaining_length": _remaining_route_length(),
		"switched": switched,
		"route_changes": route_changes,
		"route_switches": route_switch_count,
		"at": GlobalData.sim_now(),
	}
	route_changed.emit(info)


func _route_length(path: PackedVector3Array) -> float:
	if path.is_empty():
		return 0.0

	var from: Vector3 = global_position
	var total: float = 0.0

	for point: Vector3 in path:
		total += from.distance_to(point)
		from = point

	return total


func _remaining_route_length() -> float:
	if _flow_active:
		return global_position.distance_to(_flow_target)

	if path_index < current_path.size():
		return _path_length_from_here(current_path)

	return 0.0


## Finds the EvacPoint node that owns `point` and returns its stable id/name.
## Exits are deduplicated by quantised position because the root and Area3D
## both join the group.
func _resolve_exit_identity(point: Vector3) -> Dictionary:
	var tree: SceneTree = get_tree()

	if tree == null or point == Vector3.ZERO:
		return {}

	var best_distance: float = INF
	var best: Dictionary = {}

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		var exit_node := node as Node3D

		if exit_node == null or not is_instance_valid(exit_node):
			continue

		if not exit_node.has_method("get_exit_status"):
			continue

		var distance: float = exit_node.global_position.distance_to(point)

		if distance >= best_distance or distance > 0.5:
			continue

		var status: Dictionary = exit_node.get_exit_status()
		best_distance = distance
		best = {
			"exit_id": String(status.get("exit_id", exit_node.get_path())),
			"name": String(status.get("name", exit_node.name)),
		}

	return best


## True when this agent's current evacuation route runs within `radius` of the
## point. Used by the recorder to count agents affected by an environment edit.
func is_route_affected(
	point: Vector3,
	radius: float = 3.0,
	vertical_tolerance: float = 2.0
) -> bool:
	if has_meta("evacuated") or current_state == State.DEAD:
		return false

	if _flow_active:
		var closest: Vector3 = Geometry3D.get_closest_point_to_segment(
			point,
			global_position,
			_flow_target
		)
		var difference: Vector3 = closest - point
		return (
			Vector2(difference.x, difference.z).length() <= radius
			and absf(difference.y) <= vertical_tolerance
		)

	if current_path.is_empty():
		var direct := global_position - point

		return (
			Vector2(direct.x, direct.z).length() <= radius
			and absf(direct.y) <= vertical_tolerance
		)

	return _path_passes_near(point, radius, vertical_tolerance)


## Called by an EvacPoint that was disabled at runtime while this agent was
## heading for it. Drops the target and lets the normal IDLE timer choose a
## different exit.
func on_exit_unavailable(exit_point: Node3D) -> void:
	if exit_point == null or not is_instance_valid(exit_point):
		return

	var distance: float = _last_evac_target.distance_to(exit_point.global_position)

	if distance > 1.5:
		return

	clear_optimizer_assignment()

	if _last_evac_target != Vector3.ZERO:
		_mark_evacuation_point_failed(_last_evac_target)

	if route_id > 0:
		_assign_route("exit_unavailable", PackedVector3Array(), "failed")

	has_evacuation_target = false
	current_state = State.IDLE
	current_path.clear()
	path_index = 0
	is_awaiting_path = false
	_repath_pending = false
	_flow_active = false
	_flow_wait = 0.0
	_exit_hold_active = false
	_exit_hold_exit = null
	_exit_hold_deadline = 0.0
	wait_timer = 0.1


## Route snapshot for a recorder that attaches after the route was assigned.
func get_route_snapshot() -> Dictionary:
	if route_id == 0:
		return {}

	var path: PackedVector3Array = (
		PackedVector3Array() if _flow_active else current_path
	)
	var path_cells: Array = []

	if gridmap != null:
		for point: Vector3 in path:
			var cell: Vector3i = gridmap.local_to_map(gridmap.to_local(point))
			path_cells.append([cell.x, cell.y, cell.z])

		if path.is_empty():
			var target_cell: Vector3i = gridmap.local_to_map(
				gridmap.to_local(_last_evac_target)
			)
			path_cells.append([target_cell.x, target_cell.y, target_cell.z])

	return {
		"agent_serial": agent_serial,
		"agent_id": get_instance_id(),
		"route_id": route_id,
		"previous_route_id": _route_previous_id,
		"reason": "snapshot",
		"mode": "flow" if _flow_active else "path",
		"success": true,
		"evacuating": true,
		"target": _last_evac_target,
		"exit_id": destination_exit_id,
		"exit_name": destination_exit_name,
		"path": path,
		"path_cells": path_cells,
		"path_points": path.size(),
		"path_usec": 0,
		"route_length": _route_length(path),
		"remaining_length": _remaining_route_length(),
		"switched": false,
		"route_changes": route_changes,
		"route_switches": route_switch_count,
		"at": GlobalData.sim_now(),
	}


## Flat snapshot consumed by the simulator recorder and any future player.
func get_measurement_state() -> Dictionary:
	return {
		"serial": agent_serial,
		"id": get_instance_id(),
		"state": int(current_state),
		"status": _status_name(),
		"position": global_position,
		"velocity": velocity,
		"speed": Vector2(velocity.x, velocity.z).length(),
		"acceleration": acceleration,
		"destination": _last_evac_target,
		"exit_id": destination_exit_id,
		"exit_name": destination_exit_name,
		"route_id": route_id,
		"route_index": path_index,
		"route_points": current_path.size(),
		"route_length": _remaining_route_length(),
		"remaining_length": _remaining_route_length(),
		"distance": _distance_travelled,
		"contact_force": contact_force,
		"density": local_density,
		"route_changes": route_changes,
		"route_switches": route_switch_count,
		"stuck_strikes": _stuck_strikes,
		"evacuated": is_evacuated(),
		"evacuated_at": _evacuated_at_sim,
		"spawned_at": _spawned_at_sim,
		"desired_speed": desired_speed,
		"pre_movement_delay": _pre_movement_delay,
		"pre_movement_wait": (
			_pre_movement_delay if _has_started_moving else _pre_movement_elapsed
		),
		"stuck_time": _stuck_time_total,
		"flow_active": _flow_active,
		"exit_hold": _exit_hold_active,
		"is_evacuee": is_evacuee,
		"has_target": has_evacuation_target,
		"peak_density": _peak_density,
		"peak_contact_force": _peak_contact_force,
		"optimizer_assigned": _optimizer_assignment_active,
		"optimizer_exit_id": _optimizer_assigned_exit_id,
	}


func _status_name() -> String:
	if has_meta("evacuated"):
		return "evacuated"

	match current_state:
		State.DEAD:
			return "dead"
		State.ARRIVED:
			return "queued" if _exit_hold_active else "arrived"
		State.SEEKING_EVAC:
			return "seeking_exit"
		State.WANDERING:
			return "wandering"
		State.IDLE:
			return "pre_movement" if not _has_started_moving else "idle"
		_:
			return "active"


## Snapshot consumed by EvacuationManager when this NPC reaches an exit.
func get_evacuation_snapshot() -> Dictionary:
	return {
		"distance": _distance_travelled,
		"stuck_time": _stuck_time_total,
		"peak_density": _peak_density,
		"stuck_strikes": _stuck_strikes,
		"state": int(current_state),
		"target": _last_evac_target,
		"agent_serial": agent_serial,
		"desired_speed": desired_speed,
		"pre_movement_delay": _pre_movement_delay,
		"pre_movement_wait": (
			_pre_movement_delay if _has_started_moving else _pre_movement_elapsed
		),
		"peak_contact_force": _peak_contact_force,
		"contact_overlaps": contact_overlaps,
		"route_changes": route_changes,
		"route_switches": route_switch_count,
	}
