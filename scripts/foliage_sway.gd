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
static var mid_view_distance: float = 75.0
static var fade_distance: float = 40.0
static var mid_fade_distance: float = 30.0

static var _material_cache: Dictionary = {}

var _lod_accum: float = 0.0
var _lod_band: int = -1
var _primary: Sprite3D = null
var _primary_material: ShaderMaterial = null
var _supports_lod: bool = false
var _mid_distance: float = 75.0
var _far_distance: float = 150.0


func _ready() -> void:
	_apply_sway()
	_collect_lod_sprites()
	set_process(true)


func _apply_sway() -> void:
	apply_distance_settings(
		self,
		max_view_distance,
		mid_view_distance
	)

	for node in find_children("*", "Sprite3D", true, false):
		var sprite := node as Sprite3D
		if sprite == null:
			continue

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


func _collect_lod_sprites() -> void:
	var sprites: Array[Node] = find_children("*", "Sprite3D", true, false)

	if sprites.is_empty():
		return

	_primary = sprites[0] as Sprite3D

	if _primary == null:
		return

	# Already-billboard foliage has nothing to switch; crossed plants get a
	# single fixed-Y billboard at the mid LOD.
	_supports_lod = _primary.billboard == BaseMaterial3D.BILLBOARD_DISABLED
	_primary_material = _primary.material_override as ShaderMaterial


func _process(delta: float) -> void:
	if not _supports_lod or _primary == null:
		return

	_lod_accum += delta

	if _lod_accum < 0.2:
		return

	_lod_accum = 0.0

	var camera := get_viewport().get_camera_3d()

	if camera == null:
		return

	_mid_distance = float(
		get_meta("foliage_mid_distance", _mid_distance)
	)
	_far_distance = float(
		get_meta("foliage_far_distance", _far_distance)
	)
	var distance: float = global_position.distance_to(
		camera.global_position
	)
	var band: int = 0

	if distance >= _far_distance:
		band = 2
	elif distance >= _mid_distance:
		band = 1

	if band == _lod_band:
		return

	_lod_band = band

	if band == 0:
		_primary.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		_primary.material_override = _primary_material
		_primary.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		)
	else:
		# One view-facing card is cheaper and has no edge-on silhouette. The
		# built-in Sprite3D material is used because a custom material override
		# would bypass the billboard transform.
		_primary.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		_primary.material_override = null
		_primary.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)


## Two-stage foliage LOD. Crossed plants drop their second card at mid distance
## and their last card at the far distance; each transition fades over a wide
## margin so a crowd of plants thins out instead of all popping together.
static func apply_distance_settings(
	plant: Node3D,
	far_distance: float,
	mid_distance: float
) -> void:
	if plant == null:
		return

	var far := far_distance
	var mid := mid_distance
	var path := String(plant.scene_file_path).to_lower()

	if path.is_empty():
		path = String(plant.name).to_lower()

	# Trees, palms and large bushes are the main horizon silhouette; they are
	# worth keeping as a single billboard much farther out. Grass and small
	# plants keep the shorter preset cutoff.
	if (
		path.contains("tree")
		or path.contains("palm")
		or path.contains("bush")
	):
		far = maxf(far_distance, minf(300.0, far_distance * 2.0))
		mid = maxf(mid_distance, far * 0.5)

	plant.set_meta("foliage_far_distance", far)
	plant.set_meta("foliage_mid_distance", mid)

	var sprites: Array[Node] = plant.find_children("*", "Sprite3D", true, false)
	var crossed: bool = sprites.size() > 1
	var far_margin: float = minf(
		fade_distance,
		maxf(8.0, far * 0.35)
	)
	var mid_margin: float = minf(
		mid_fade_distance,
		maxf(6.0, mid * 0.4)
	)

	for index in sprites.size():
		var sprite := sprites[index] as Sprite3D

		if sprite == null:
			continue

		var secondary: bool = crossed and index > 0
		var end_distance: float = mid if secondary else far
		var margin: float = mid_margin if secondary else far_margin

		if end_distance > 0.0:
			sprite.visibility_range_end = end_distance
			sprite.visibility_range_end_margin = margin
			sprite.visibility_range_fade_mode = (
				GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			)
		else:
			sprite.visibility_range_end = 0.0
			sprite.visibility_range_end_margin = 0.0
			sprite.visibility_range_fade_mode = (
				GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			)

		# The second crossed card is mostly redundant with the first at
		# distance, so it does not need its own shadow pass.
		if secondary:
			sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


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
