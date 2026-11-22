extends Area3D

## Reusable 3D menu button: a mesh rectangle, a Label3D caption and an Area3D
## picker. Instances can be freely duplicated/moved in the pause menu scene.
##
## The parent PauseMenu owns hit-testing; it calls set_hovered/set_selected.
## Colours ease between states, the bar grows a touch while active, and
## play_intro() drops the button in from above for the staggered menu reveal.

@export var action: StringName = &""
@export var caption: String = "Button"
@export var label_font: Font = null
@export var label_size: int = 28
@export var label_pixel: float = 0.0021
@export var label_left: bool = false
@export var dim_unselected: bool = false
## When the button is widened with a non-uniform node scale, keep the Label3D
## at its natural aspect instead of letting the parent scale stretch the text.
@export var keep_label_aspect: bool = false
@export var base_color: Color = Color(0.14, 0.11, 0.06, 0.96)
@export var hover_color: Color = Color(0.58, 0.43, 0.07, 1.0)
@export var selected_color: Color = Color(0.38, 0.28, 0.04, 0.8)

var payload: String = ""

var _hovered: bool = false
var _selected: bool = false
var _material: StandardMaterial3D = null
var _rest_position: Vector3 = Vector3.ZERO
var _label_rest_scale: Vector3 = Vector3.ONE
var _visual_alpha: float = 1.0
var _color_target: Color = Color.WHITE
var _color_tween: Tween = null
var _intro_tween: Tween = null

@onready var label: Label3D = $Label
@onready var mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	_rest_position = position

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.render_priority = 4
	_material.albedo_color = base_color
	mesh.material_override = _material

	if label_font != null:
		label.font = label_font
	label.font_size = label_size
	label.pixel_size = label_pixel
	if label_left:
		# Keep every entry starting at the same x inside the hover bar.
		label.position.x = -0.4
		label.width = 520
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.text = caption
	refresh_label_aspect()
	_apply_color(true)


## Counter-scales the Label3D against a non-uniform button scale so glyphs keep
## their aspect ratio. Called at ready and after runtime layout changes.
func refresh_label_aspect() -> void:
	if keep_label_aspect:
		_label_rest_scale = Vector3(
			1.0 / maxf(absf(scale.x), 0.001),
			1.0 / maxf(absf(scale.y), 0.001),
			1.0 / maxf(absf(scale.z), 0.001)
		)
	else:
		_label_rest_scale = Vector3.ONE
	if is_instance_valid(label):
		label.scale = _label_rest_scale


## Drops the whole button into place, fading it in. Called by the menu with a
## per-row delay so the top entry is seen first.
func play_intro(
	delay: float = 0.0,
	from_offset: Vector3 = Vector3(0.0, 0.34, 0.0),
	duration: float = 0.38
) -> void:
	if is_instance_valid(_intro_tween):
		_intro_tween.kill()
	if is_instance_valid(_color_tween):
		_color_tween.kill()

	position = _rest_position + from_offset
	set_visual_alpha(0.0)
	label.scale = _label_rest_scale * 0.94

	_intro_tween = create_tween().set_parallel(true)
	_intro_tween.tween_property(self, "position", _rest_position, duration) \
		.set_delay(delay) \
		.set_trans(Tween.TRANS_CUBIC) \
		.set_ease(Tween.EASE_OUT)
	_intro_tween.tween_method(set_visual_alpha, 0.0, 1.0, duration * 0.72) \
		.set_delay(delay)
	_intro_tween.tween_property(label, "scale", _label_rest_scale, duration * 0.85) \
		.set_delay(delay) \
		.set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_OUT)


## Snap back to the resting look; used when a view is reset without animation.
func reset_visual() -> void:
	if is_instance_valid(_intro_tween):
		_intro_tween.kill()
	if is_instance_valid(_color_tween):
		_color_tween.kill()
	position = _rest_position
	label.scale = _label_rest_scale
	_visual_alpha = 1.0
	_apply_color(true)


func set_caption(value: String) -> void:
	caption = value
	if is_instance_valid(label):
		label.text = value


func set_payload(value: String) -> void:
	payload = value


func set_hovered(value: bool) -> void:
	if _hovered == value:
		return
	_hovered = value
	_apply_color()


func set_selected(value: bool) -> void:
	if _selected == value:
		return
	_selected = value
	_apply_color()


func set_visual_alpha(value: float) -> void:
	_visual_alpha = clampf(value, 0.0, 1.0)
	if _material != null:
		var color: Color = _color_target
		color.a *= _visual_alpha
		_material.albedo_color = color
	if is_instance_valid(label):
		var tint: Color = label.modulate
		tint.a = _visual_alpha
		label.modulate = tint


func _apply_color(instant: bool = false) -> void:
	if _material == null:
		return

	var color: Color = base_color
	if _selected:
		color = selected_color
	elif _hovered:
		color = hover_color
	_color_target = color

	var tint := Color(0.92, 0.94, 0.96, 1.0)
	if _selected or _hovered:
		tint = Color(1.0, 0.88, 0.25, 1.0)
	elif dim_unselected:
		tint = Color(0.52, 0.54, 0.58, 1.0)
	tint.a = _visual_alpha

	var mesh_target := (
		Vector3(1.025, 1.08, 1.0)
		if _hovered or _selected
		else Vector3.ONE
	)

	if is_instance_valid(_color_tween):
		_color_tween.kill()

	if instant:
		color.a *= _visual_alpha
		_material.albedo_color = color
		if is_instance_valid(label):
			label.modulate = tint
		mesh.scale = mesh_target
		return

	_color_tween = create_tween().set_parallel(true)
	_color_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	color.a *= _visual_alpha
	_color_tween.tween_property(_material, "albedo_color", color, 0.12)
	if is_instance_valid(label):
		_color_tween.tween_property(label, "modulate", tint, 0.12)
	_color_tween.tween_property(mesh, "scale", mesh_target, 0.16)
