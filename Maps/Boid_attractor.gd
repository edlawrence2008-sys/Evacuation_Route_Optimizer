class_name ParticleAttractorStateMachine
extends GPUParticlesAttractor3D

enum State { CENTER, CIRCLE, RANDOM_POINT }

@export_category("State Machine Settings")
@export var current_state: State = State.CENTER
@export var arrival_threshold: float = 0.5 # Increased slightly to prevent physics jitter

# --- Custom State Weights ---
@export_group("State Selection Weights")
@export var weight_center: float = 1.0
@export var weight_circle: float = 1.0
@export var weight_random_point: float = 1.5

# --- Physical Speed & Smoothing Settings ---
@export_group("Movement Settings")
@export var constant_speed: float = 12.0     # The actual target speed in units/sec
@export var acceleration_smoothness: float = 5.0 # How fast it accelerates/decelerates
@export var rotation_smoothness: float = 6.0 # Fluidity for the Circle state entry

@export_category("Center State Settings")
@export var target_particles: GPUParticles3D

@export_category("Circle State Settings")
@export var min_radius: float = 2.0
@export var max_radius: float = 6.0
@export var orbit_speed: float = 5.0 
@export var min_orbits: float = 1.0
@export var max_orbits: float = 3.0

# Internal tracking variables
var _target_position: Vector3 = Vector3.ZERO
var _is_target_set: bool = false
var _velocity: Vector3 = Vector3.ZERO

# Circle state specific variables
var _circle_center: Vector3 = Vector3.ZERO
var _current_radius: float = 0.0
var _current_angle: float = 0.0
var _target_orbit_radians: float = 0.0
var _accumulated_radians: float = 0.0

func _ready() -> void:
	_enter_state(current_state)

func _process(delta: float) -> void:
	match current_state:
		State.CENTER:
			_process_linear_tracking(delta)
		State.CIRCLE:
			_process_circle(delta)
		State.RANDOM_POINT:
			_process_linear_tracking(delta)

### --- State Transition Management ---

func change_state(new_state: State) -> void:
	current_state = new_state
	_enter_state(new_state)

func _enter_state(state: State) -> void:
	_is_target_set = false
	
	match state:
		State.CENTER:
			if is_instance_valid(target_particles):
				_target_position = target_particles.global_position
				_is_target_set = true
			else:
				push_warning("ParticlesAttractor: No target particles assigned for CENTER state.")
				_pick_weighted_next_state()

		State.CIRCLE:
			_circle_center = global_position
			_current_radius = randf_range(min_radius, max_radius)
			_current_angle = randf_range(0, TAU) 
			
			_accumulated_radians = 0.0
			var chosen_orbits = randf_range(min_orbits, max_orbits)
			_target_orbit_radians = chosen_orbits * TAU
			
			# Reset velocity when entering orbit to let rotation math take cleanly over
			_velocity = Vector3.ZERO
			_is_target_set = true

		State.RANDOM_POINT:
			var nodes = get_tree().get_nodes_in_group("Air_migration_nodes")
			if nodes.size() > 0:
				var random_node = nodes.pick_random()
				if random_node is Node3D:
					_target_position = random_node.global_position
					_is_target_set = true
			
			if not _is_target_set:
				push_warning("ParticlesAttractor: No valid Node3D found in 'Air_migration_nodes' group.")
				_pick_weighted_next_state()

### --- State Process Logic ---

# Combined logic for CENTER and RANDOM_POINT to maintain true, physical speed limits
func _process_linear_tracking(delta: float) -> void:
	if not _is_target_set: return
	
	# 1. Find the direction to the node
	var to_target = _target_position - global_position
	var distance = to_target.length()
	
	if distance <= arrival_threshold:
		_velocity = Vector3.ZERO
		_pick_weighted_next_state()
		return
		
	var target_direction = to_target.normalized()
	
	# 2. Define our desired physical velocity vector
	var desired_velocity = target_direction * constant_speed
	
	# 3. Smoothly lerp our CURRENT velocity toward the DESIRED velocity (Framerate independent)
	_velocity = _velocity.lerp(desired_velocity, 1.0 - exp(-acceleration_smoothness * delta))
	
	# 4. Apply velocity to position
	global_position += _velocity * delta

func _process_circle(delta: float) -> void:
	if not _is_target_set: return
	
	var calculated_angular_speed: float = orbit_speed / max(_current_radius, 0.01)
	var angle_step = calculated_angular_speed * delta
	
	_current_angle += angle_step
	_accumulated_radians += angle_step
	
	# Pure mathematical target coordinate
	var offset = Vector3(cos(_current_angle), 0, sin(_current_angle)) * _current_radius
	var target_orbit_pos = _circle_center + offset
	
	# Smooth the transition into the orbit path smoothly rather than snapping instantly
	global_position = global_position.lerp(target_orbit_pos, 1.0 - exp(-rotation_smoothness * delta))
	
	if _accumulated_radians >= _target_orbit_radians:
		_pick_weighted_next_state()

### --- Weighted State Selection Algorithm ---

func _pick_weighted_next_state() -> void:
	var pool: Dictionary = {}
	
	if current_state != State.CENTER:
		pool[State.CENTER] = weight_center
	if current_state != State.CIRCLE:
		pool[State.CIRCLE] = weight_circle
		
	pool[State.RANDOM_POINT] = weight_random_point

	var total_weight: float = 0.0
	for state_key in pool:
		total_weight += pool[state_key]
		
	var roll: float = randf_range(0.0, total_weight)
	var current_sum: float = 0.0
	
	for state_key in pool:
		current_sum += pool[state_key]
		if roll <= current_sum:
			change_state(state_key)
			return
