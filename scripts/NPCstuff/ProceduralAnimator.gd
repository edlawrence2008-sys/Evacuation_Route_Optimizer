extends Node
class_name ProceduralAnimator

## Animation is stepped at this rate instead of every physics frame.
@export var animation_hz: float = 30.0

# --- State readable by all subclasses ---
var _parent: CharacterBody3D = null
var _animation_accum: float = 0.0

var parent_state: int = -1
var parent_velocity: Vector3 = Vector3.ZERO
var parent_horizontal_speed: float = 0.0
var parent_facing_direction: Vector3 = Vector3.FORWARD
var parent_is_on_floor: bool = true

func _ready() -> void:
	var p = get_parent()
	if p is CharacterBody3D:
		_parent = p
		# Automatically look for a HealthComponent on the parent
		_find_and_connect_health_component()
	else:
		push_warning("ProceduralAnimator '%s': Parent is not a CharacterBody3D. Animator inactive." % name)

func _physics_process(delta: float) -> void:
	if not is_instance_valid(_parent):
		return

	# Sync all readable state from parent every physics tick
	parent_velocity          = _parent.velocity
	parent_horizontal_speed  = Vector3(_parent.velocity.x, 0.0, _parent.velocity.z).length()
	parent_is_on_floor       = _parent.is_on_floor()
	parent_facing_direction  = -_parent.global_transform.basis.z

	if "current_state" in _parent:
		parent_state = _parent.current_state

	_animation_accum += delta
	var interval: float = 1.0 / maxf(animation_hz, 1.0)

	if _animation_accum < interval:
		return

	var step: float = _animation_accum
	_animation_accum = 0.0
	_animate(step)

# --- Automated Signal Connection ---
func _find_and_connect_health_component() -> void:
	if not is_instance_valid(_parent): return
	
	# Scans the parent's children for any node matching our HealthComponent class type
	for child in _parent.get_children():
		if child is HealthComponent:
			# Connect the 'damaged' signal to our local listener method safely
			child.damaged.connect(_on_parent_damaged)
			return

# Local signal callback that passing child classes can tap into
func _on_parent_damaged(_amount: float) -> void:
	if has_method("play_hurt"):
		call("play_hurt")

# --- Override in subclasses ---
func _animate(_delta: float) -> void:
	pass

# --- Helpers available to all subclasses ---
func get_speed_ratio(reference_speed: float = 5.0) -> float:
	if reference_speed <= 0.0:
		return 0.0
	return clamp(parent_horizontal_speed / reference_speed, 0.0, 1.0)

func is_in_state_named(state_name: String) -> bool:
	if not is_instance_valid(_parent) or not "current_state" in _parent:
		return false
	var script = _parent.get_script()
	if script and script.get_script_constant_map().has("State"):
		return false  
	var state_val = _parent.current_state
	return str(state_val) == state_name
