extends DirectionalLight3D

## Ports the 2D Consul-style rim/bounce light to the realistic sprite overlay.
##
## The values are pushed to global shader parameters once per frame, so every
## sprite overlay shares one sun direction/colour update.

@export var rim_strength: float = 1.0
@export var bounce_strength: float = 0.35

func _ready() -> void:
	add_to_group("sun_light")

func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	var to_light := global_transform.basis.z.normalized()
	var sun_dir := Vector2(0.0, -1.0)

	if camera != null:
		var camera_basis := camera.global_transform.basis
		# Camera space is Y-up; the shader's UV space is Y-down. Flipping X
		# makes the offset direction point away from the light in UV space.
		sun_dir = Vector2(
			-to_light.dot(camera_basis.x),
			to_light.dot(camera_basis.y)
		)

		if sun_dir.length_squared() < 0.0001:
			sun_dir = Vector2(0.0, -1.0)
		else:
			sun_dir = sun_dir.normalized()

	# Both edges follow the sun's energy, so they fade at dawn/dusk/night.
	var energy_scale: float = clampf(light_energy, 0.0, 1.0)

	# The rim reveals the unshaded sprite mixed with the real sunlight colour.
	var rim_col := light_color
	rim_col.a = clampf(rim_strength * energy_scale, 0.0, 1.0)

	# The bounce is a complementary tint derived from the sunlight colour.
	var bounce_col := light_color
	bounce_col.h = fmod(bounce_col.h + 0.5, 1.0)
	bounce_col.s = maxf(bounce_col.s, 0.5)
	bounce_col.v = 1.0
	bounce_col.a = clampf(
		bounce_strength * energy_scale * 0.5,
		0.0,
		1.0
	)

	RenderingServer.global_shader_parameter_set(
		&"sprite_sun_dir",
		sun_dir
	)
	RenderingServer.global_shader_parameter_set(
		&"sprite_sun_color",
		rim_col
	)
	RenderingServer.global_shader_parameter_set(
		&"sprite_bounce_color",
		bounce_col
	)
