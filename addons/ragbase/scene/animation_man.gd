extends Node3D

@export var max_tilt_angle: float = 15.0        # Standard maximum tilt in degrees
@export var sprint_tilt_angle: float = 20       # Max tilt when sprinting
@export var crouch_tilt_angle: float = -5.0     # Max tilt when crouching
@export var tilt_speed: float = 10.0            # How fast it snaps/tilts

func _process(delta: float) -> void:
	# Get input from ui actions (returns a Vector2 between -1 and 1)
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	
	# Priority: Crouch takes priority over sprint
	var current_max_angle = max_tilt_angle
	
	if Input.is_action_pressed("ui_sprint"):
		current_max_angle = crouch_tilt_angle
	elif Input.is_action_pressed("ui_crouch"):
		current_max_angle = sprint_tilt_angle
	
	# Treat back as the new front: invert left/right banking when holding down (moving backward)
	var steer_x = input_dir.x
	if input_dir.y > 0:
		steer_x = -steer_x
	
	# Calculate target rotations (Pitch and Roll only):
	var target_x = -input_dir.y * deg_to_rad(current_max_angle)              # Pitch (Up/Down)
	var target_z = steer_x * deg_to_rad(current_max_angle)                   # Roll (Left/Right banking)
	
	# Smoothly interpolate current rotation to target rotation
	rotation.x = lerp_angle(rotation.x, target_x, tilt_speed * delta)
	rotation.z = lerp_angle(rotation.z, target_z, tilt_speed * delta)
