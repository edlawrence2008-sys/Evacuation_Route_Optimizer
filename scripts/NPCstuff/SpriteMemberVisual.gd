class_name SpriteMemberVisual
extends AnimatedSprite3D

## Doom-style controller for one realistic NPC sprite scene.
##
## The scene owns the SpriteFrames. Every variant must provide these eight
## clip names: front/back/left/right x idle/walk. Geometry metadata is exported
## so another sheet can override it without changing this script.

const ROW_FRONT: int = 0
const ROW_BACK: int = 1
const ROW_LEFT: int = 2
const ROW_RIGHT: int = 3

const EXPECTED_ANIMATIONS: Array[StringName] = [
	&"front_idle", &"front_walk",
	&"back_idle", &"back_walk",
	&"left_idle", &"left_walk",
	&"right_idle", &"right_walk",
]

const RIM_SHADER: Shader = preload(
	"res://shaders/realistic_sprite_rim.gdshader"
)

@export_group("Playback")
@export var walk_fps: float = 5.0
@export var update_hz: float = 12.0
## FPS the clips were authored at, used to scale playback with walk speed.
@export var base_walk_fps: float = 5.0

@export_group("Distance Culling")
## Stop updating/pausing far sprites and remove their rim overlay past this range.
## Nothing here changes the sprite's render visibility.
@export var animation_cull_distance: float = 45.0
@export var rim_cull_distance: float = 45.0

@export_group("Rim and Bounce")
## Per-agent multiplier on the shared sun-side rim strength.
@export_range(0.0, 1.0, 0.01) var rim_strength: float = 1.0:
	set(value):
		rim_strength = clampf(value, 0.0, 1.0)
		_sync_rim_settings()
## Per-agent multiplier on the shared complementary bounce strength.
@export_range(0.0, 4.0, 0.01) var bounce_strength: float = 1.0:
	set(value):
		bounce_strength = maxf(value, 0.0)
		_sync_rim_settings()

@export_group("Normal Mapping")
## Optional tangent-space normal atlas with the same frame layout as the sheet.
@export var normal_map: Texture2D = null
## Whether the material uses the normal map.
@export var normal_enabled: bool = true:
	set(value):
		normal_enabled = value
		_sync_surface_material()
## Multiplier applied to the normal map's tangent-space strength.
@export_range(0.0, 4.0, 0.05) var normal_strength: float = 1.0:
	set(value):
		normal_strength = maxf(value, 0.0)
		_sync_surface_material()

@export_group("Atlas Geometry")
## Per-variant floor correction baked into the scene. Member.sprite_offset
## adds on top of this at runtime.
@export var floor_offset: Vector3 = Vector3.ZERO
@export var frame_cell_height: float = 700.0
## Atlas columns per row. Used to index frame_bottom.
@export var frame_columns: int = 3
## Bottom-most opaque pixel of each cell, row-major (4 rows x frame_columns).
@export var frame_bottom: PackedInt32Array = PackedInt32Array([
	646, 696, 694, # front
	640, 640, 648, # back
	656, 644, 646, # left
	646, 644, 656, # right
])
## Atlas column used by the idle clip for each direction row.
@export var idle_columns: PackedInt32Array = PackedInt32Array([0, 0, 0, 2])
## Four atlas columns per direction row: row * 4 + frame index.
@export var walk_columns: PackedInt32Array = PackedInt32Array([
	0, 1, 0, 2, # front
	0, 1, 0, 2, # back
	0, 1, 0, 2, # left
	2, 0, 2, 1, # right
])

var visual_offset: Vector3 = Vector3.ZERO

var _member: CharacterBody3D = null
var _update_accum: float = 0.0
var _rim_material: ShaderMaterial = null
var _surface_material: StandardMaterial3D = null


func _ready() -> void:
	_member = get_parent() as CharacterBody3D
	billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	shaded = true
	double_sided = true
	centered = true
	visible = false
	set_process(false)
	set_physics_process(false)

	# Do not touch render visibility here; only animation/rim updates cull.
	_setup_surface_material()
	_setup_rim_overlay()
	frame_changed.connect(_on_frame_changed)
	if has_signal("animation_changed"):
		animation_changed.connect(_on_frame_changed)
	_warn_missing_animations()

	var initial: StringName = &"back_idle"
	if not _has_animation(initial):
		initial = _first_animation()
	if not String(initial).is_empty():
		play(initial)


func set_active(active: bool) -> void:
	visible = active
	if not active:
		stop()
		_update_accum = 0.0
		return

	_update_frame()


## Called from Member._physics_process; one update callback per NPC.
func tick(delta: float) -> void:
	if not visible:
		return

	_update_accum += delta
	var interval: float = 1.0 / maxf(update_hz, 1.0)

	if _update_accum < interval:
		return

	_update_accum = 0.0
	_update_frame()


## Re-applies the current clip and ground offset after a live settings change.
func refresh() -> void:
	if visible:
		_update_frame()
		_update_ground_offset()


## Local-space nudge applied on top of the per-frame floor alignment.
func set_visual_offset(value: Vector3) -> void:
	visual_offset = value
	_update_ground_offset()


func _update_frame() -> void:
	if _member == null:
		return

	_sync_surface_material()

	var camera: Camera3D = get_viewport().get_camera_3d()
	var distance: float = (
		_member.global_position.distance_to(camera.global_position)
		if camera != null
		else 0.0
	)

	var cull_animation: bool = distance > animation_cull_distance
	var cull_rim: bool = distance > rim_cull_distance

	if cull_rim:
		if material_overlay != null:
			material_overlay = null
	elif material_overlay == null:
		material_overlay = _rim_material

	if cull_animation:
		if is_playing():
			pause()
		return

	if not is_playing():
		play(animation)

	var speed: float = Vector3(
		_member.velocity.x,
		0.0,
		_member.velocity.z
	).length()
	var moving: bool = speed > 0.1
	var row: int = _row_for_camera()
	var animation_name: StringName = _animation_for(row, moving)

	if not _has_animation(animation_name):
		animation_name = _first_animation()

	if String(animation_name).is_empty():
		return

	var animation_started: bool = false

	if animation != animation_name:
		play(animation_name)
		animation_started = true
	elif not is_playing():
		play(animation_name)
		animation_started = true

	if animation_started:
		_update_rim_frame()

	if moving:
		var reference_speed: float = maxf(_member.actual_movement_speed, 1.0)
		var speed_scale_factor: float = clampf(speed / reference_speed, 0.5, 1.5)
		speed_scale = (
			walk_fps / maxf(base_walk_fps, 1.0) * speed_scale_factor
		)
	else:
		speed_scale = 1.0

	# The clip may have advanced while this tick was waiting; keep the feet
	# grounded even when the animation/frame did not change this tick.
	_update_ground_offset()


## AnimatedSprite3D has no normal-map property, so when a normal atlas is
## supplied we replace the sprite's surface material with an equivalent
## StandardMaterial3D that samples both atlases with the current frame UVs.
func _setup_surface_material() -> void:
	if normal_map == null:
		return

	_surface_material = StandardMaterial3D.new()
	_surface_material.albedo_texture = _current_atlas()
	_surface_material.normal_enabled = normal_enabled
	_surface_material.normal_texture = normal_map
	_surface_material.normal_scale = maxf(normal_strength, 0.0)
	_surface_material.vertex_color_use_as_albedo = true
	_surface_material.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	_surface_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_surface_material.alpha_scissor_threshold = 0.5
	_surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_surface_material.texture_filter = (
		BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	)
	_surface_material.roughness = 1.0
	_surface_material.metallic = 0.0
	_surface_material.shading_mode = (
		BaseMaterial3D.SHADING_MODE_PER_PIXEL
		if shaded
		else BaseMaterial3D.SHADING_MODE_UNSHADED
	)
	# The sprite mesh's UVs already point at the current atlas cell; do not
	# remap them. The normal atlas uses the same layout and UVs.
	_surface_material.uv1_scale = Vector3.ONE
	_surface_material.uv1_offset = Vector3.ZERO
	material_override = _surface_material


func _sync_surface_material() -> void:
	if _surface_material == null:
		return

	_surface_material.shading_mode = (
		BaseMaterial3D.SHADING_MODE_PER_PIXEL
		if shaded
		else BaseMaterial3D.SHADING_MODE_UNSHADED
	)
	_surface_material.normal_enabled = normal_enabled
	_surface_material.normal_scale = maxf(normal_strength, 0.0)


func _sync_rim_settings() -> void:
	if _rim_material == null:
		return

	_rim_material.set_shader_parameter(
		"rim_strength",
		clampf(rim_strength, 0.0, 1.0)
	)
	_rim_material.set_shader_parameter(
		"bounce_strength",
		maxf(bounce_strength, 0.0)
	)


func _current_atlas() -> Texture2D:
	if sprite_frames == null:
		return null

	var frame_texture: Texture2D = sprite_frames.get_frame_texture(
		animation,
		frame
	)

	if frame_texture is AtlasTexture:
		return (frame_texture as AtlasTexture).atlas

	return frame_texture


func _setup_rim_overlay() -> void:
	_rim_material = ShaderMaterial.new()
	_rim_material.shader = RIM_SHADER
	_sync_rim_settings()
	material_overlay = _rim_material
	_update_rim_frame()


func _update_rim_frame() -> void:
	if _rim_material == null or sprite_frames == null:
		return

	var frame_texture: Texture2D = sprite_frames.get_frame_texture(
		animation,
		frame
	)

	if frame_texture == null:
		return

	var atlas: Texture2D = frame_texture
	var region := Rect2(Vector2.ZERO, frame_texture.get_size())

	if frame_texture is AtlasTexture:
		var atlas_texture := frame_texture as AtlasTexture
		if atlas_texture.atlas != null:
			atlas = atlas_texture.atlas
			region = atlas_texture.region

	var atlas_size: Vector2 = atlas.get_size()

	_rim_material.set_shader_parameter("sprite_atlas", atlas)
	_rim_material.set_shader_parameter(
		"sprite_region",
		Vector4(
			region.position.x,
			region.position.y,
			region.size.x,
			region.size.y
		)
	)
	_rim_material.set_shader_parameter("atlas_size", atlas_size)
	_rim_material.set_shader_parameter(
		"sprite_scale",
		Vector2(
			-1.0 if flip_h else 1.0,
			-1.0 if flip_v else 1.0
		)
	)


func _on_frame_changed() -> void:
	_update_ground_offset()
	_update_rim_frame()


func _update_ground_offset() -> void:
	var row: int = _row_for_animation(animation)
	var column: int = _idle_column(row)

	if String(animation).ends_with("_walk"):
		column = _walk_column(row, int(frame))

	var bottom_px: float = _frame_bottom(row, column)
	var base_y: float = (
		bottom_px - frame_cell_height * 0.5
	) * pixel_size

	position = Vector3(
		floor_offset.x + visual_offset.x,
		floor_offset.y + base_y + visual_offset.y,
		floor_offset.z + visual_offset.z
	)


func _idle_column(row: int) -> int:
	return int(idle_columns[row]) if row < idle_columns.size() else 0


func _walk_column(row: int, frame_index: int) -> int:
	var index: int = row * 4 + (frame_index % 4)

	if index < 0 or index >= walk_columns.size():
		return _idle_column(row)

	return int(walk_columns[index])


func _frame_bottom(row: int, column: int) -> float:
	var index: int = row * maxi(frame_columns, 1) + column

	if index < 0 or index >= frame_bottom.size():
		return frame_cell_height

	return float(frame_bottom[index])


func _has_animation(animation_name: StringName) -> bool:
	return (
		sprite_frames != null
		and sprite_frames.has_animation(animation_name)
	)


func _first_animation() -> StringName:
	if sprite_frames == null:
		return &""

	var names: PackedStringArray = sprite_frames.get_animation_names()
	return names[0] if not names.is_empty() else &""


func _warn_missing_animations() -> void:
	for animation_name: StringName in EXPECTED_ANIMATIONS:
		if not _has_animation(animation_name):
			push_warning(
				"SpriteMemberVisual '%s' is missing animation '%s'."
				% [name, animation_name]
			)


func _animation_for(row: int, moving: bool) -> StringName:
	var direction: String = "front"

	match row:
		ROW_BACK:
			direction = "back"
		ROW_LEFT:
			direction = "left"
		ROW_RIGHT:
			direction = "right"

	return StringName("%s_%s" % [direction, "walk" if moving else "idle"])


func _row_for_animation(animation_name: StringName) -> int:
	var text: String = String(animation_name)

	if text.begins_with("back"):
		return ROW_BACK
	if text.begins_with("left"):
		return ROW_LEFT
	if text.begins_with("right"):
		return ROW_RIGHT
	return ROW_FRONT


func _row_for_camera() -> int:
	var camera: Camera3D = get_viewport().get_camera_3d()

	if camera == null:
		return ROW_FRONT

	var facing: Vector3 = -_member.global_transform.basis.z
	facing.y = 0.0

	if facing.length_squared() < 0.001:
		return ROW_FRONT

	facing = facing.normalized()
	var local: Vector3 = camera.global_transform.basis.inverse() * facing

	# Camera space: +X is right, -Z is forward/away from the camera.
	if absf(local.x) > absf(local.z):
		return ROW_RIGHT if local.x > 0.0 else ROW_LEFT

	return ROW_BACK if local.z < 0.0 else ROW_FRONT
