class_name StabilityReadout
extends Label3D

## Small floating label over the aimed block. It owns formatting only; the
## build controller decides when the value is worth evaluating and where the
## label sits. Splitting it out keeps the readout testable without the player,
## camera and autoloads that BuildController needs.

const MATERIALS = preload("res://scripts/block_materials.gd")

const SUPPORTED_COLOR := Color(0.7, 1.0, 0.7)
const UNSUPPORTED_COLOR := Color(1.0, 0.3, 0.22)
const ANCHOR_COLOR := Color(0.45, 0.75, 1.0)


func _ready() -> void:
	font_size = 48
	pixel_size = 0.0032
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	no_depth_test = true
	render_priority = 12
	outline_size = 10
	outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	visible = false

	var font := load("res://font/dogicapixel.ttf") as Font
	if font != null:
		self.font = font


## `value` is 0..255 and `reach` is the material's maximum span.
func show_value(value: int, reach: int) -> void:
	if value >= MATERIALS.STABILITY_ANCHORED:
		text = "∞"
		modulate = ANCHOR_COLOR
	elif value <= 0:
		text = "0 / %d  UNSUPPORTED" % maxi(1, reach)
		modulate = UNSUPPORTED_COLOR
	else:
		text = "%d / %d" % [value, maxi(value, reach)]
		modulate = SUPPORTED_COLOR

	visible = true


func hide_value() -> void:
	visible = false
