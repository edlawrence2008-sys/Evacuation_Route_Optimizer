extends GPUParticlesCollisionBox3D

@export_group("Speed Settings")
## The absolute slowest the box can spin (in radians per second)
@export var min_speed: float = 1
## The absolute fastest the box can spin (in radians per second)
@export var max_speed: float = 3
## How fast the speed adjusts to the new random target (higher = snappier, lower = smoother)
@export var acceleration_smoothness: float = 1.5

@export_group("Timing Settings")
## Minimum time (in seconds) before picking a new speed
@export var change_interval_min: float = 1.5
## Maximum time (in seconds) before picking a new speed
@export var change_interval_max: float = 4.0

# Internal state variables (No 'private' keyword needed in GDScript)
var current_speed: float = 0.0
var target_speed: float = 0.0
var time_until_next_change: float = 0.0


func _ready() -> void:
	# Initialize with a random starting speed and set the first countdown
	target_speed = randf_range(min_speed, max_speed)
	current_speed = target_speed
	pick_new_speed_and_time()


func _process(delta: float) -> void:
	# 1. Handle the countdown timer
	time_until_next_change -= delta
	if time_until_next_change <= 0.0:
		pick_new_speed_and_time()
	
	# 2. Smoothly interpolate the current speed toward the target speed
	current_speed = lerp(current_speed, target_speed, acceleration_smoothness * delta)
	
	# 3. Apply the rotation using the smoothed current speed
	rotate_y(current_speed * delta)


## Selects a new random speed and decides how long to stay at/transition to it
func pick_new_speed_and_time() -> void:
	target_speed = randf_range(min_speed, max_speed)
	time_until_next_change = randf_range(change_interval_min, change_interval_max)
