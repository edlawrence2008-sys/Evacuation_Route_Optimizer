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
@export_range(0, 2000, 1) var particle_count: int = 300
@export var particle_size: float = 1.0
@export var particle_texture: Texture2D = BOID_TEXTURE
@export var particle_lifetime: float = 30.0
@export var emission_radius: float = 2.5
@export var velocity_min: float = 1.2
@export var velocity_max: float = 3.2
@export var turbulence: float = 2.4

var _particles: GPUParticles3D = null
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


func _build_particles() -> void:
	if particle_count <= 0:
		return

	_particles = GPUParticles3D.new()
	_particles.name = "Particles"
	_particles.emitting = false
	add_child(_particles)
	call_deferred("_start_emitting")

	# World-space particles are the key difference from a leader-parented
	# cloud: the emitter can sit anywhere on the map and the flock can still
	# pull its birds across the whole level.
	_particles.local_coords = false
	_particles.amount = particle_count
	_particles.lifetime = maxf(0.5, particle_lifetime)
	_particles.preprocess = 2.0
	_particles.fixed_fps = 60
	_particles.explosiveness = 0.8
	_particles.randomness = 0.1
	_particles.visibility_aabb = AABB(
		Vector3(-800.0, -200.0, -800.0),
		Vector3(1600.0, 500.0, 1600.0)
	)

	var process_material := ParticleProcessMaterial.new()
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
	process_material.gravity = Vector3(0.0, -0.25, 0.0)
	process_material.linear_accel_min = 0.0
	process_material.linear_accel_max = 2.0
	process_material.radial_accel_min = -0.5
	process_material.radial_accel_max = 1.0
	process_material.tangential_accel_min = -0.5
	process_material.tangential_accel_max = 0.5
	process_material.damping_min = 0.1
	process_material.damping_max = 0.5
	process_material.scale_min = 0.5
	process_material.scale_max = 1.5
	process_material.turbulence_enabled = turbulence > 0.0
	process_material.turbulence_noise_strength = turbulence
	process_material.turbulence_noise_scale = 4.0
	process_material.turbulence_influence_min = 0.04
	process_material.turbulence_influence_max = 0.16
	process_material.anim_speed_min = 18.0
	process_material.anim_speed_max = 26.0
	process_material.anim_offset_max = 1.0
	process_material.collision_mode = 1
	process_material.collision_friction = 1.0
	process_material.collision_bounce = 1.0
	_particles.process_material = process_material

	var texture: Texture2D = particle_texture

	if texture == null:
		texture = BOID_TEXTURE

	var quad := QuadMesh.new()
	quad.size = Vector2(particle_size, particle_size)

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
	quad.material = material
	_particles.draw_pass_1 = quad


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
