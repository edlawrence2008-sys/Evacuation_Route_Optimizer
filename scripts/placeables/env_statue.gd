extends Node3D

## A lit billboard statue. The albedo is a pre-rendered statue render and the
## optional normal map gives it volume under the sun/moon light. It uses the
## same world texel size as the NPC sprites (0.0042 m per texture pixel) so a
## statue and an NPC standing next to each other share the same pixel scale.
##
## The normal map is loaded lazily: the texture may not have an imported cache
## the first time the scene is opened, in which case `load()` fails and we read
## the PNG directly. Once the editor imports it, `load()` takes over.

const ALBEDO_PATH := "res://textures/placeables/env/env_statue.png"
const NORMAL_PATH := "res://textures/placeables/env/env_statue_n.png"
const FALLBACK_TEXTURE_SIZE := Vector2(229.0, 498.0)

static var _normal_texture: Texture2D = null
static var _normal_load_attempted: bool = false

@export var albedo_texture: Texture2D = preload(ALBEDO_PATH):
	set(value):
		albedo_texture = value
		_sync_material()
		_sync_size()

## Blank means the built-in `env_statue_n.png` is loaded automatically.
@export var normal_texture: Texture2D = null:
	set(value):
		normal_texture = value
		_sync_material()

## World size of one texture pixel. Matches Member.sprite_pixel_size.
@export_range(0.0005, 0.02, 0.0001) var pixel_size: float = 0.0042:
	set(value):
		pixel_size = maxf(value, 0.0001)
		_sync_size()

@export var shaded: bool = true:
	set(value):
		shaded = value
		_sync_material()

@export var normal_enabled: bool = true:
	set(value):
		normal_enabled = value
		_sync_material()

@export_range(0.0, 4.0, 0.01) var normal_strength: float = 1.0:
	set(value):
		normal_strength = maxf(value, 0.0)
		_sync_material()

@export_range(0.0, 1.0, 0.01) var alpha_scissor_threshold: float = 0.35:
	set(value):
		alpha_scissor_threshold = clampf(value, 0.0, 1.0)
		_sync_material()

@export var cast_shadow: bool = true:
	set(value):
		cast_shadow = value
		_sync_shadow()

## Statues are solid objects, so they need a voxel below their footprint.
@export var requires_voxel_below: bool = true
## Optional per-scene nudge, consumed by BuildController.
@export var grid_xz_offset: Vector2 = Vector2.ZERO

@onready var statue: MeshInstance3D = $Statue

var _material: StandardMaterial3D = null


func _ready() -> void:
	_sync_material()
	_sync_size()
	_sync_shadow()


func _sync_size() -> void:
	if not is_node_ready() or statue == null:
		return

	var quad := statue.mesh as QuadMesh
	if quad == null:
		return

	var texture_size := _texture_size()
	quad.size = Vector2(
		texture_size.x * pixel_size,
		texture_size.y * pixel_size
	)
	statue.position.y = quad.size.y * 0.5


func _texture_size() -> Vector2:
	if albedo_texture != null:
		var size := albedo_texture.get_size()

		if size.x > 0.0 and size.y > 0.0:
			return size

	return FALLBACK_TEXTURE_SIZE


func _sync_material() -> void:
	if not is_node_ready() or statue == null:
		return

	if _material == null:
		_material = StandardMaterial3D.new()

	_material.albedo_texture = albedo_texture
	_material.albedo_color = Color.WHITE
	_material.roughness = 1.0
	_material.metallic = 0.0
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_material.alpha_scissor_threshold = alpha_scissor_threshold
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_material.shading_mode = (
		BaseMaterial3D.SHADING_MODE_PER_PIXEL
		if shaded
		else BaseMaterial3D.SHADING_MODE_UNSHADED
	)

	var resolved_normal := _resolve_normal_texture()
	_material.normal_enabled = normal_enabled and resolved_normal != null
	_material.normal_texture = resolved_normal
	_material.normal_scale = normal_strength

	statue.material_override = _material


func _sync_shadow() -> void:
	if not is_node_ready() or statue == null:
		return

	statue.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if cast_shadow
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)


func _resolve_normal_texture() -> Texture2D:
	if normal_texture != null:
		return normal_texture

	if _normal_load_attempted:
		return _normal_texture

	_normal_load_attempted = true

	# Calling load() before the editor has generated the imported cache prints
	# an error and returns null. Check the .import deps first, then fall back to
	# reading the PNG directly so the statue still has a normal map.
	if _import_cache_present(NORMAL_PATH):
		var imported := ResourceLoader.load(NORMAL_PATH) as Texture2D
		if imported != null:
			_normal_texture = imported
			return _normal_texture

	var image := Image.new()
	if image.load(ProjectSettings.globalize_path(NORMAL_PATH)) != OK:
		return null

	image.convert(Image.FORMAT_RGB8)
	_normal_texture = ImageTexture.create_from_image(image)
	return _normal_texture


func _import_cache_present(resource_path: String) -> bool:
	var config := ConfigFile.new()
	if config.load(resource_path + ".import") != OK:
		return false

	var dest_files: Variant = config.get_value("deps", "dest_files", [])
	if dest_files is Array and not dest_files.is_empty():
		return FileAccess.file_exists(String(dest_files[0]))

	return false
