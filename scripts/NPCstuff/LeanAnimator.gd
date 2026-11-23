extends ProceduralAnimator

# ============================================================
# EXPORTS
# ============================================================

@export var animator_enabled: bool = true

@export_group("Lean Settings")
@export var max_tilt_degrees: float = 22.0
@export var min_tilt_degrees: float = 1.0
@export var tilt_smooth_speed: float = 8.0
@export var reference_speed: float = 10.0
@export var visual_node_path: NodePath = NodePath("../blockbench_export")

@export_group("Walk Bob Settings")
@export var walk_bob_frequency: float = 20.0
@export var walk_bob_vertical: float = 0.2
@export var walk_bob_horizontal: float = 0.08
@export var walk_roll_degrees: float = 5.0

@export_group("Hurt Animation Settings")
@export var hurt_kickback_distance: float = 0.4
@export var hurt_tilt_degrees: float = -12.0
@export var hurt_roll_degrees: float = 8.0
@export var hurt_recovery_speed: float = 6.0

@export_group("Hurt Visual Flash Settings")
@export var flash_color: Color = Color(1.0, 0.1, 0.1, 1.0)
@export var flash_emission_energy: float = 2.0

@export_group("Health Visual State")
@export var enable_health_darkening: bool = true
@export_range(0.0, 1.0) var min_health_darkness: float = 0.05

@export_group("Death Settings")
@export var death_jump_velocity: float = 4.5
@export var death_gravity: float = 14.0
@export var death_bounciness: float = 0.45
@export var death_squash_elasticity: float = 12.0
@export var death_sink_distance: float = -1.5
@export var death_transition_speed: float = 1.0

@export_group("Camera Culling")
@export var enable_camera_culling: bool = true
@export var max_animation_distance: float = 45.0
@export var distance_check_interval: float = 0.25
@export var cull_margin: float = 2.0


# ============================================================
# NODE / MATERIAL STATE
# ============================================================

var _visual: Node3D = null
var _original_visual_position: Vector3 = Vector3.ZERO
var _death_position: Vector3 = Vector3.ZERO

var _mesh_materials: Array[StandardMaterial3D] = []
var _original_albedos: Array[Color] = []
var _original_emissions: Array[Color] = []
var _original_emission_energies: PackedFloat64Array = []

var _current_health_percent: float = 1.0
var _last_health_percent: float = -1.0
var _last_hurt_intensity: float = -1.0


# ============================================================
# CACHED STATE
# ============================================================

var _cached_parent_script: GDScript = null
var _cached_state_map: Dictionary = {}
var _dead_state_id: int = -1

var _is_dead: bool = false
var _was_dead_last_frame: bool = false
var _death_weight: float = 0.0
var _death_bounce_settled: bool = false

var _speed_ratio: float = 0.0
var _is_moving: bool = false

var _current_tilt_basis: Basis = Basis.IDENTITY
var _walk_time: float = 0.0

var _hurt_intensity: float = 0.0
var _hurt_roll_direction: float = 1.0

var _death_vertical_velocity: float = 0.0
var _death_local_y_offset: float = 0.0
var _death_bounce_squash_y: float = 1.0


# ============================================================
# CAMERA CULLING STATE
# ============================================================

var _screen_notifier: VisibleOnScreenNotifier3D = null
var _is_on_screen: bool = true
var _is_too_far: bool = false
var _distance_timer: float = 0.0
var _camera: Camera3D = null


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	super._ready()

	_visual = get_node_or_null(visual_node_path) as Node3D
	if not is_instance_valid(_visual):
		push_warning("LeanAnimator: visual node not found at '%s'." % visual_node_path)
		return

	_original_visual_position = _visual.transform.origin
	_death_position = _original_visual_position + Vector3(0.0, death_sink_distance, 0.0)

	_initialize_flash_materials(_visual)
	_cache_parent_state()
	_setup_camera_culling()


func _cache_parent_state() -> void:
	if not is_instance_valid(_parent):
		return

	_cached_parent_script = _parent.get_script() as GDScript
	if _cached_parent_script == null:
		return

	var map: Dictionary = _cached_parent_script.get_script_constant_map()
	if not map.has("State"):
		return

	_cached_state_map = map["State"] as Dictionary

	if _cached_state_map.has("DEAD"):
		_dead_state_id = _cached_state_map["DEAD"] as int


func _initialize_flash_materials(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		var surface_count := mesh_inst.get_surface_override_material_count()

		for surface_idx in surface_count:
			var mat: Material = mesh_inst.get_surface_override_material(surface_idx)

			if mat == null and mesh_inst.mesh != null:
				mat = mesh_inst.mesh.surface_get_material(surface_idx)

			if mat is StandardMaterial3D:
				var local_mat := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
				mesh_inst.set_surface_override_material(surface_idx, local_mat)

				_mesh_materials.append(local_mat)
				_original_albedos.append(local_mat.albedo_color)
				_original_emissions.append(local_mat.emission)
				_original_emission_energies.append(local_mat.emission_energy_multiplier)

	for child in node.get_children():
		_initialize_flash_materials(child)


func _setup_camera_culling() -> void:
	if not enable_camera_culling:
		return

	_screen_notifier = VisibleOnScreenNotifier3D.new()
	_screen_notifier.name = "LeanAnimatorScreenNotifier"

	var size := cull_margin * 2.0
	_screen_notifier.aabb = AABB(
		Vector3(-cull_margin, -cull_margin, -cull_margin),
		Vector3(size, size, size)
	)

	_visual.add_child(_screen_notifier)
	_screen_notifier.global_transform = Transform3D.IDENTITY


# ============================================================
# PUBLIC API
# ============================================================

func play_hurt() -> void:
	if not animator_enabled or _death_weight > 0.1:
		return

	_hurt_intensity = 1.0
	_hurt_roll_direction = 1.0 if randf() > 0.5 else -1.0

	var sound_mgr := _parent.get_node_or_null("SoundManager")
	if is_instance_valid(sound_mgr) and sound_mgr.has_method("play_hurt_sound"):
		sound_mgr.play_hurt_sound()


func set_health_percent(percent_0_to_1: float) -> void:
	_current_health_percent = clampf(percent_0_to_1, 0.0, 1.0)


# ============================================================
# MAIN ANIMATION
# ============================================================

func _animate(delta: float) -> void:
	if not is_instance_valid(_visual):
		return

	_tick_camera_culling(delta)

	if not animator_enabled or not _should_animate():
		# Leave the last visible pose alone instead of resetting materials
		# every tick for hundreds of off-screen NPCs. Force a refresh when
		# the NPC comes back into view.
		_last_health_percent = -1.0
		_last_hurt_intensity = -1.0
		return

	_update_cached_state()
	_tick_hurt_and_health_color(delta)
	_tick_death_bounce(delta)
	_tick_death_weight(delta)
	_tick_locomotion_clock(delta)

	var target_pos := _build_position()
	var target_basis := _build_basis()
	var blend_speed := _compute_blend_speed() * delta

	_visual.transform.origin = _visual.transform.origin.lerp(target_pos, blend_speed)
	_current_tilt_basis = _current_tilt_basis.slerp(target_basis, blend_speed)
	_visual.transform.basis = _current_tilt_basis.orthonormalized()
	_visual.scale = _death_bounce_scale()


func _should_animate() -> bool:
	if not enable_camera_culling:
		return true

	return _is_on_screen and not _is_too_far


func _update_cached_state() -> void:
	_speed_ratio = get_speed_ratio(reference_speed)
	_is_moving = _speed_ratio >= 0.01

	if _dead_state_id == -1 or not is_instance_valid(_parent):
		_is_dead = false
		return

	_is_dead = parent_state == _dead_state_id


# ============================================================
# CAMERA CULLING
# ============================================================

func _tick_camera_culling(delta: float) -> void:
	if not enable_camera_culling:
		return

	_distance_timer -= delta
	if _distance_timer > 0.0:
		return

	_distance_timer = distance_check_interval

	_camera = get_viewport().get_camera_3d()
	if not is_instance_valid(_camera):
		_is_too_far = false
		return

	var distance := _parent.global_position.distance_to(_camera.global_position)
	_is_too_far = distance > max_animation_distance

# ============================================================
# MATERIAL / HEALTH / HURT
# ============================================================

func _tick_hurt_and_health_color(delta: float) -> void:
	_hurt_intensity = move_toward(_hurt_intensity, 0.0, delta * hurt_recovery_speed)

	var health_changed := not is_equal_approx(_current_health_percent, _last_health_percent)
	var hurt_changed := not is_equal_approx(_hurt_intensity, _last_hurt_intensity)

	if not health_changed and not hurt_changed:
		return

	_last_health_percent = _current_health_percent
	_last_hurt_intensity = _hurt_intensity

	var darkness_factor := lerpf(min_health_darkness, 1.0, _current_health_percent)
	var use_flash := _hurt_intensity > 0.001

	for i in _mesh_materials.size():
		var mat := _mesh_materials[i]
		if not is_instance_valid(mat):
			continue

		var original_albedo := _original_albedos[i]
		var target_base_color := original_albedo

		if enable_health_darkening:
			target_base_color = original_albedo * darkness_factor
			target_base_color.a = original_albedo.a

		if use_flash:
			mat.albedo_color = target_base_color.lerp(flash_color, _hurt_intensity)
			mat.emission_enabled = true
			mat.emission = flash_color
			mat.emission_energy_multiplier = lerpf(0.0, flash_emission_energy, _hurt_intensity)
		else:
			mat.albedo_color = target_base_color
			mat.emission_enabled = false
			mat.emission = _original_emissions[i]
			mat.emission_energy_multiplier = _original_emission_energies[i]


func _reset_materials_to_original() -> void:
	for i in _mesh_materials.size():
		var mat := _mesh_materials[i]
		if is_instance_valid(mat):
			mat.albedo_color = _original_albedos[i]
			mat.emission = _original_emissions[i]
			mat.emission_energy_multiplier = _original_emission_energies[i]


# ============================================================
# DEATH
# ============================================================

func _tick_death_bounce(delta: float) -> void:
	if _is_dead:
		if not _was_dead_last_frame:
			_was_dead_last_frame = true
			_death_vertical_velocity = death_jump_velocity
			_death_local_y_offset = 0.0
			_death_bounce_squash_y = 1.0
			_death_bounce_settled = false

		if not _death_bounce_settled:
			_death_vertical_velocity -= death_gravity * delta
			_death_local_y_offset += _death_vertical_velocity * delta

			if _death_local_y_offset <= 0.0:
				_death_local_y_offset = 0.0

				if absf(_death_vertical_velocity) > 1.2:
					_death_vertical_velocity = -_death_vertical_velocity * death_bounciness
					_death_bounce_squash_y = clampf(
						1.0 - absf(_death_vertical_velocity) * 0.08,
						0.45,
						1.0
					)
				else:
					_death_vertical_velocity = 0.0
					_death_bounce_settled = true

			_death_bounce_squash_y = lerpf(
				_death_bounce_squash_y,
				1.0,
				death_squash_elasticity * delta
			)
	else:
		_was_dead_last_frame = false
		_death_bounce_settled = false
		_death_local_y_offset = move_toward(
			_death_local_y_offset,
			0.0,
			delta * death_gravity
		)
		_death_bounce_squash_y = lerpf(
			_death_bounce_squash_y,
			1.0,
			death_squash_elasticity * delta
		)


func _tick_death_weight(delta: float) -> void:
	var target := 1.0 if (_is_dead and _death_bounce_settled) else 0.0
	_death_weight = move_toward(_death_weight, target, delta * death_transition_speed)


func _death_bounce_scale() -> Vector3:
	var y := maxf(_death_bounce_squash_y, 0.001)
	var xz := sqrt(1.0 / y)
	return Vector3(xz, y, xz)


# ============================================================
# LOCOMOTION
# ============================================================

func _tick_locomotion_clock(delta: float) -> void:
	if _is_moving and _death_weight < 0.99 and not _is_dead:
		_walk_time += delta * walk_bob_frequency * _speed_ratio
	else:
		_walk_time = move_toward(_walk_time, 0.0, delta * walk_bob_frequency)


# ============================================================
# TRANSFORMS
# ============================================================

func _build_position() -> Vector3:
	var pos := _awake_position()
	pos = pos.lerp(_death_position, _death_weight)
	pos.y += _death_local_y_offset
	pos.z += _hurt_intensity * hurt_kickback_distance
	return pos


func _awake_position() -> Vector3:
	var pos := _original_visual_position

	if _is_dead:
		return pos

	if _is_moving and parent_is_on_floor:
		var step_curve := absf(sin(_walk_time)) - 0.5
		pos.x += cos(_walk_time) * walk_bob_horizontal
		pos.y -= step_curve * walk_bob_vertical

	return pos


func _build_basis() -> Basis:
	var b := _awake_basis()

	if _is_dead:
		return Basis(Vector3.RIGHT, deg_to_rad(-90.0)) * _hurt_rotation()

	b = b.slerp(Basis(Vector3.RIGHT, deg_to_rad(-90.0)), _death_weight)
	return b * _hurt_rotation()


func _awake_basis() -> Basis:
	if _is_dead:
		return Basis.IDENTITY

	var b := Basis.IDENTITY

	var parent_vel := _parent.velocity
	var horiz_vel := Vector3(parent_vel.x, 0.0, parent_vel.z)
	var horiz_speed := horiz_vel.length()

	if horiz_speed > 0.05 and _is_moving:
		var world_dir := horiz_vel / horiz_speed
		var local_dir := (_parent.global_transform.basis.inverse() * world_dir).normalized()
		var lean_axis := local_dir.cross(Vector3.UP).normalized()

		if lean_axis.length_squared() > 0.001:
			var air_factor := 1.0 if parent_is_on_floor else 0.5
			var tilt_deg := lerpf(min_tilt_degrees, max_tilt_degrees, _speed_ratio) * air_factor
			b = Basis(lean_axis, deg_to_rad(tilt_deg))

	if parent_is_on_floor:
		b = b * Basis(Vector3.FORWARD, sin(_walk_time) * deg_to_rad(walk_roll_degrees))

	return b


func _hurt_rotation() -> Basis:
	if _hurt_intensity <= 0.001:
		return Basis.IDENTITY

	return Basis.from_euler(Vector3(
		deg_to_rad(hurt_tilt_degrees * _hurt_intensity),
		0.0,
		deg_to_rad(hurt_roll_degrees * _hurt_intensity * _hurt_roll_direction)
	))


# ============================================================
# BLEND SPEED
# ============================================================

func _compute_blend_speed() -> float:
	var base_speed := tilt_smooth_speed

	if _is_moving and absf(sin(_walk_time)) - 0.5 >= 0.0:
		base_speed *= 1.5

	var death_speed := 25.0 if (_is_dead and not _death_bounce_settled) else death_transition_speed * 2.0
	var death_factor := 1.0 if _is_dead else _death_weight

	return lerpf(base_speed, death_speed, death_factor)


# ============================================================
# NEUTRAL RESET
# ============================================================

func _reset_to_neutral(delta: float) -> void:
	var s := tilt_smooth_speed * delta

	_hurt_intensity = move_toward(_hurt_intensity, 0.0, delta * hurt_recovery_speed)
	_reset_materials_to_original()

	_death_weight = move_toward(_death_weight, 0.0, delta * death_transition_speed)
	_walk_time = move_toward(_walk_time, 0.0, delta * walk_bob_frequency)

	_death_vertical_velocity = 0.0
	_death_local_y_offset = move_toward(_death_local_y_offset, 0.0, delta * death_gravity)
	_death_bounce_squash_y = lerpf(_death_bounce_squash_y, 1.0, death_squash_elasticity * delta)

	_was_dead_last_frame = false
	_death_bounce_settled = false

	_visual.transform.origin = _visual.transform.origin.lerp(_original_visual_position, s)
	_current_tilt_basis = _current_tilt_basis.slerp(Basis.IDENTITY, s)
	_visual.transform.basis = _current_tilt_basis.orthonormalized()
	_visual.scale = _visual.scale.lerp(Vector3.ONE, s)


func _on_visible_on_screen_notifier_3d_screen_entered() -> void:
	_is_on_screen = true


func _on_visible_on_screen_notifier_3d_screen_exited() -> void:
	_is_on_screen = false
