extends Node3D

## HL2-style wind sway for generated foliage. Materials are shared per
## (texture, pixel size), and the shader derives the phase from the plant's
## world origin, so hundreds of plants do not create hundreds of materials.
## Each plant's crossed cards therefore move together.

const SWAY_SHADER: Shader = preload("res://shaders/foliage_sway.gdshader")
const SWAY_FRACTION: float = 0.035

## Foliage cards beyond this distance stop drawing and casting shadows. This
## keeps large 32-64 chunk draws from submitting hundreds of tiny alpha quads.
static var max_view_distance: float = 150.0
static var fade_distance: float = 20.0

static var _material_cache: Dictionary = {}


func _ready() -> void:
	_apply_sway()


func _apply_sway() -> void:
	for node in find_children("*", "Sprite3D", true, false):
		var sprite := node as Sprite3D
		if sprite == null:
			continue

		if max_view_distance > 0.0:
			sprite.visibility_range_end = max_view_distance
			sprite.visibility_range_end_margin = fade_distance
			sprite.visibility_range_fade_mode = (
				GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			)

		# Billboard cards need their own view-facing shader; the current
		# foliage set uses crossed fixed-Y cards, so leave billboards alone
		# rather than breaking their orientation.
		if sprite.billboard != BaseMaterial3D.BILLBOARD_DISABLED:
			continue
		if sprite.material_override is ShaderMaterial:
			continue

		var material := _shared_material(sprite)
		if material != null:
			sprite.material_override = material


static func _shared_material(sprite: Sprite3D) -> ShaderMaterial:
	if sprite.texture == null:
		return null

	var key := "%s|%.4f" % [sprite.texture.resource_path, sprite.pixel_size]
	if _material_cache.has(key):
		return _material_cache[key]

	var material := ShaderMaterial.new()
	material.shader = SWAY_SHADER
	material.set_shader_parameter("albedo_tex", sprite.texture)
	material.set_shader_parameter(
		"sway_height",
		maxf(sprite.texture.get_height() * sprite.pixel_size, 0.1)
	)
	material.set_shader_parameter("sway_strength", SWAY_FRACTION)
	material.set_shader_parameter(
		"flip_backface_normals",
		sprite.texture.resource_path.to_lower().contains("grass")
	)
	material.set_shader_parameter(
		"stable_grass_shading",
		sprite.texture.resource_path.to_lower().contains("grass")
	)
	_material_cache[key] = material
	return material
