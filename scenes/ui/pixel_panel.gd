class_name PixelPanel
extends Control

## Reusable pixel-art panel. The supplied art is six 6x6 pieces (top/bottom
## corners, top/bottom edges, and one left side); the right side and the two
## right corners are mirrored. Everything is drawn in source-pixel space and
## scaled by `pixel_scale`, so the frame tiles cleanly at any size.

const DEFAULT_CORNER_TOP := preload(
	"res://textures/menu/pixelpanel_corner_top.png"
)
const DEFAULT_CORNER_BOTTOM := preload(
	"res://textures/menu/pixelpanel_corner_bottom.png"
)
const DEFAULT_EDGE_TOP := preload(
	"res://textures/menu/pixelpanel_edge_top.png"
)
const DEFAULT_EDGE_BOTTOM := preload(
	"res://textures/menu/pixelpanel_edge_bottom.png"
)
const DEFAULT_EDGE_SIDE := preload(
	"res://textures/menu/pixelpanel_edge_side.png"
)

const PIECE_SIZE := 6.0

@export var corner_top: Texture2D = DEFAULT_CORNER_TOP
@export var corner_bottom: Texture2D = DEFAULT_CORNER_BOTTOM
@export var edge_top: Texture2D = DEFAULT_EDGE_TOP
@export var edge_bottom: Texture2D = DEFAULT_EDGE_BOTTOM
@export var edge_side: Texture2D = DEFAULT_EDGE_SIDE
@export_range(1.0, 8.0, 1.0) var pixel_scale: float = 2.0
@export var fill_color: Color = Color(0.035, 0.035, 0.055, 0.97)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	clip_contents = true
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


## Width of the drawn frame in screen pixels. Hosts that add a content child
## can inset it by this many pixels so the art is not covered.
func get_border_pixels() -> float:
	return PIECE_SIZE * maxf(pixel_scale, 1.0)


func _draw() -> void:
	if (
		corner_top == null
		or corner_bottom == null
		or edge_top == null
		or edge_bottom == null
		or edge_side == null
	):
		return

	var scale_factor := maxf(pixel_scale, 1.0)
	var source_size := size / scale_factor
	if source_size.x <= PIECE_SIZE * 2.0 or source_size.y <= PIECE_SIZE * 2.0:
		return

	var inner_width := source_size.x - PIECE_SIZE * 2.0
	var inner_height := source_size.y - PIECE_SIZE * 2.0

	# Fill first, then the frame pieces on top.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(scale_factor, scale_factor))
	draw_rect(
		Rect2(PIECE_SIZE, PIECE_SIZE, inner_width, inner_height),
		fill_color
	)

	# Left-hand pieces.
	draw_texture_rect(corner_top, Rect2(0.0, 0.0, PIECE_SIZE, PIECE_SIZE), false)
	draw_texture_rect(
		corner_bottom,
		Rect2(0.0, source_size.y - PIECE_SIZE, PIECE_SIZE, PIECE_SIZE),
		false
	)
	draw_texture_rect(
		edge_top,
		Rect2(PIECE_SIZE, 0.0, inner_width, PIECE_SIZE),
		true
	)
	draw_texture_rect(
		edge_bottom,
		Rect2(PIECE_SIZE, source_size.y - PIECE_SIZE, inner_width, PIECE_SIZE),
		true
	)
	draw_texture_rect(
		edge_side,
		Rect2(0.0, PIECE_SIZE, PIECE_SIZE, inner_height),
		true
	)

	# Right-hand pieces are the left art mirrored across the panel's right edge.
	draw_set_transform(
		Vector2(size.x, 0.0),
		0.0,
		Vector2(-scale_factor, scale_factor)
	)
	draw_texture_rect(corner_top, Rect2(0.0, 0.0, PIECE_SIZE, PIECE_SIZE), false)
	draw_texture_rect(
		corner_bottom,
		Rect2(0.0, source_size.y - PIECE_SIZE, PIECE_SIZE, PIECE_SIZE),
		false
	)
	draw_texture_rect(
		edge_side,
		Rect2(0.0, PIECE_SIZE, PIECE_SIZE, inner_height),
		true
	)

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
