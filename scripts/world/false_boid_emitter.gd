class_name FalseBoidEmitter
extends Node3D

## A placeable particle source for the false-boid flock. Unlike the earlier
## version, the particles are emitted in world space and are NOT parented to
## the moving flock leader. Place several of these around the map: each emits
## birds at its own location, and the shared FalseBoidFlock attractor pulls
## them across the map.

const BOID_TEXTURE := preload("res://textures/particles/Boid.png")
const DIRECTOR_GROUP := &"false_boid_director"

@export_group("Particle Source")
@export_range(0, 2000, 1) var particle_count: int = 30
@export var particle_size: float = 1.0
@export var particle_texture: Texture2D = BOID_TEXTURE
@export var particle_lifetime: float = 90.0
## Height above the feeder that the cloud is emitted from. Keeps birds clear of
## the ground now that the player-following particle collision box is gone.
@export var emission_height: float = 2.0
@export var emission_radius: float = 2.5
@export var velocity_min: float = 3.0
@export var velocity_max: float = 6.0
@export var turbulence: float = 6.0
## Constant swirl acceleration around the emitter. This is what keeps the cloud
## moving like the older implementation instead of drifting to a stop.
@export var radial_accel_min: float = 1.5
@export var radial_accel_max: float = 7.0
@export var tangential_accel_min: float = 1.5
@export var tangential_accel_max: float = 6.0

var _particles: GPUParticles3D = null
var _normal_draw: Mesh = null
var _flipped_draw: Mesh = null
var _flip_timer: float = 0.0
var _cloud_flipped: bool = false
var _flip_pending_time: float = 0.0
static var _director_pending: bool = false
var _director_check_timer: float = 1.0


func _ready() -> void:
	add_to_group(&"false_boid_emitters")
	_build_particles()
	call_deferred("_ensure_director")


func _process(delta: float) -> void:
	_director_check_timer -= delta

	if _director_check_timer <= 0.0:
		_director_check_timer = 1.0
		call_deferred("_ensure_director")

	_flip_timer -= delta

	if _flip_timer <= 0.0:
		_flip_timer = 0.2
		_update_direction_flip(0.2)


func _build_particles() -> void:
	if particle_count <= 0:
		return

	_particles = GPUParticles3D.new()
	_particles.name = "Particles"
	_particles.emitting = false
	_particles.position.y = emission_height
	add_child(_particles)
	call_deferred("_start_emitting")

	# World-space particles are the key difference from a leader-parented
	# cloud: the emitter can sit anywhere on the map and the flock can still
	# pull its birds across the whole level.
	_particles.local_coords = false
	_particles.amount = particle_count
	_particles.lifetime = maxf(0.5, particle_lifetime)
	_particles.preprocess = 4.0
	_particles.fixed_fps = 60
	_particles.explosiveness = 0.5
	_particles.randomness = 0.15
	_particles.visibility_aabb = AABB(
		Vector3(-800.0, -200.0, -800.0),
		Vector3(1600.0, 500.0, 1600.0)
	)

	var process_material := ParticleProcessMaterial.new()
	process_material.lifetime_randomness = 0.25
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	process_material.emission_ring_axis = Vector3.UP
	process_material.emission_ring_height = 1.0
	process_material.emission_ring_radius = emission_radius
	process_material.emission_ring_inner_radius = 0.0
	process_material.emission_ring_cone_angle = 90.0
	process_material.direction = Vector3(0.0, 0.0, 0.0)
	process_material.spread = 180.0
	process_material.initial_velocity_min = velocity_min
	process_material.initial_velocity_max = velocity_max
	# Nearly weightless so the flock stays high and never rains to the ground.
	process_material.gravity = Vector3(0.0, 0.15, 0.0)
	process_material.linear_accel_min = 0.0
	process_material.linear_accel_max = 0.0
	process_material.radial_accel_min = radial_accel_min
	process_material.radial_accel_max = radial_accel_max
	process_material.tangential_accel_min = tangential_accel_min
	process_material.tangential_accel_max = tangential_accel_max
	# Almost no damping: the previous version's constant motion is what made it
	# read as flight. Damping was turning the new cloud into hovering dots.
	process_material.damping_min = 0.0
	process_material.damping_max = 0.05
	process_material.scale_min = 0.5
	process_material.scale_max = 1.5
	process_material.turbulence_enabled = turbulence > 0.0
	process_material.turbulence_noise_strength = turbulence
	process_material.turbulence_noise_scale = 6.0
	process_material.turbulence_influence_min = 0.08
	process_material.turbulence_influence_max = 0.25
	# The old implementation ran the wing cycle at roughly 250 fps. The slow
	# 18-26 fps cycle here made the particles look like floating leaves.
	process_material.anim_speed_min = 210.0
	process_material.anim_speed_max = 280.0
	process_material.anim_offset_max = 1.0
	# No collision box follows the player any more; disabling collision also
	# removes the per-particle reference lookup cost.
	process_material.collision_mode = ParticleProcessMaterial.COLLISION_DISABLED
	_particles.process_material = process_material

	var texture: Texture2D = particle_texture

	if texture == null:
		texture = BOID_TEXTURE

	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.particles_anim_h_frames = 3
	material.particles_anim_v_frames = 1
	material.particles_anim_loop = true
	_normal_draw = _build_quad(particle_size, material, false)
	_flipped_draw = _build_quad(particle_size, material, true)
	_particles.draw_pass_1 = _normal_draw


## A quad with reversed U coordinates. The draw pass is switched at runtime to
## mirror the whole cloud when the flock's average heading crosses the camera.
func _build_quad(size: float, material: Material, flipped: bool) -> ArrayMesh:
	var half: float = maxf(size, 0.01) * 0.5
	var vertices := PackedVector3Array([
		Vector3(-half, -half, 0.0),
		Vector3(half, -half, 0.0),
		Vector3(half, half, 0.0),
		Vector3(-half, half, 0.0),
	])
	var normals := PackedVector3Array([
		Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK,
	])
	var uvs := PackedVector2Array(
		[
			Vector2(1.0, 1.0), Vector2(0.0, 1.0),
			Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		]
		if flipped
		else [
			Vector2(0.0, 1.0), Vector2(1.0, 1.0),
			Vector2(1.0, 0.0), Vector2(0.0, 0.0),
		]
	)
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


## The GPU cloud cannot mirror per particle, so mirror all of it according to
## the flock's average heading relative to the camera. This still makes the cloud
## read as facing the migration direction instead of always facing left.
func _update_direction_flip(delta: float = 0.2) -> void:
	if _particles == null or _normal_draw == null or _flipped_draw == null:
		return

	var director: Node = get_tree().get_first_node_in_group(DIRECTOR_GROUP)

	if director == null or not director.has_method("get_cloud_direction"):
		return

	var direction: Vector3 = director.get_cloud_direction()
	var camera := get_viewport().get_camera_3d()

	if camera == null:
		return

	direction.y = 0.0

	if direction.length_squared() < 0.01:
		return

	var side: float = direction.normalized().dot(camera.global_transform.basis.x)

	if absf(side) < 0.12:
		return

	var desired_flip: bool = side > 0.0

	if desired_flip == _cloud_flipped:
		_flip_pending_time = 0.0
		return

	# Hold a consistent direction for a moment before mirroring the whole cloud;
	# otherwise a circling leader can flip it back and forth.
	_flip_pending_time += delta

	if _flip_pending_time < 0.5:
		return

	_cloud_flipped = desired_flip
	_flip_pending_time = 0.0
	_particles.draw_pass_1 = _flipped_draw if desired_flip else _normal_draw


func _start_emitting() -> void:
	if _particles != null and is_instance_valid(_particles):
		_particles.emitting = true


func _ensure_director() -> void:
	if _director_pending:
		return

	var tree := get_tree()

	if tree == null or tree.get_first_node_in_group(DIRECTOR_GROUP) != null:
		return

	var scene := tree.current_scene

	if scene == null:
		return

	_director_pending = true
	var director_script := preload("res://scripts/world/false_boid_director.gd")
	var director: Node = director_script.new()
	director.name = "FalseBoidDirector"
	director.ready.connect(_on_director_ready)
	scene.add_child(director)


func _on_director_ready() -> void:
	_director_pending = false


func get_emitter_state() -> Dictionary:
	return {
		"particles": _particles.amount if _particles != null else 0,
		"particle_size": particle_size,
		"local_coords": _particles.local_coords if _particles != null else true,
		"lifetime": _particles.lifetime if _particles != null else 0.0,
		"position": global_position,
	}
