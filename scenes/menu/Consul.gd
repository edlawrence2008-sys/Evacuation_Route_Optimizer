extends Control

@export var max_iris_radius: float = 100.0  # Maximum distance the iris can travel from the eyeball center
@export var min_scale_factor: float = 0.50  # Prevents the iris from collapsing to 0 at the edge (0.0 to 1.0)

@export_group("Lag & Motion")
@export var base_lag_speed: float = 12.0     # Base smoothing speed for following the cursor
@export var speed_lag_factor: float = 0.0015 # How much extra lag is added when moving the cursor fast

@export_group("Eye Jitter")
@export var jitter_radius: float = 10.0     # Radius size of the jitter points around the cursor
@export var jitter_frequency: float = 12.0  # How fast the eye twitches/jitters

@onready var eyeball: Sprite2D = $Consul_body/Consul_eyeball
@onready var iris: Sprite2D = $Consul_body/Consul_eyeball/Consul_iris

var original_iris_scale: Vector2
var current_iris_local_pos: Vector2 = Vector2.ZERO
var last_mouse_pos: Vector2 = Vector2.ZERO

# Noise generator for smooth, organic micro-movements
var noise = FastNoiseLite.new()
var noise_seed: float = 0.0

func _ready() -> void:
	if iris:
		original_iris_scale = iris.scale
		current_iris_local_pos = iris.position
		
	# Configure simplex noise for the eye twitch/jitter
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.05
	noise_seed = randf() * 1000.0

func _process(delta: float) -> void:
	if not eyeball or not iris:
		return
		
	# 1. Get positions & calculate cursor speed
	var eyeball_center = eyeball.global_position
	var mouse_pos = get_global_mouse_position()
	
	var mouse_velocity = (mouse_pos - last_mouse_pos) / max(delta, 0.00001)
	var mouse_speed = mouse_velocity.length()
	last_mouse_pos = mouse_pos
	
	# 2. Generate organic jitter offset around the cursor
	noise_seed += delta * jitter_frequency
	var jitter_x = noise.get_noise_2d(noise_seed, 0.0)
	var jitter_y = noise.get_noise_2d(0.0, noise_seed)
	var jitter_offset = Vector2(jitter_x, jitter_y) * jitter_radius
	
	# Target position is the mouse position offset by the jitter radius
	var target_mouse_pos = mouse_pos + jitter_offset
	
	# 3. Calculate target offset from eyeball center
	var to_target = target_mouse_pos - eyeball_center
	var distance = to_target.length()
	
	var clamped_distance = min(distance, max_iris_radius)
	var direction = to_target.normalized() if distance > 0 else Vector2.ZERO
	var target_local_pos = direction * clamped_distance
	
	# 4. Apply lag proportional to cursor speed
	# Faster mouse movement lowers the interpolation weight, making the iris lag/drag more
	var effective_lag = base_lag_speed / (1.0 + (mouse_speed * speed_lag_factor))
	current_iris_local_pos = current_iris_local_pos.lerp(target_local_pos, clamp(effective_lag * delta, 0.0, 1.0))
	
	iris.position = current_iris_local_pos
	
	# 5. Mimic 3D sphere curvature based on current smoothed position
	var current_distance = current_iris_local_pos.length()
	if max_iris_radius > 0:
		var t = current_distance / max_iris_radius  # Ranges from 0 (center) to 1 (edge)
		
		var spherical_factor = sqrt(max(0.0, 1.0 - (t * t)))
		var scale_factor = max(spherical_factor, min_scale_factor)
		
		var current_direction = current_iris_local_pos.normalized() if current_distance > 0 else Vector2.RIGHT
		iris.rotation = current_direction.angle()
		iris.scale = Vector2(original_iris_scale.x * scale_factor, original_iris_scale.y)
