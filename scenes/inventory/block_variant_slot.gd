extends Control

## One variant cell inside the block-group chooser. It is drawn with the same
## hotbar slot art as the real hotbar, so the chooser reads as a row of hotbar
## icons. Click selects the variant for the group's inventory display; drag
## carries the variant's item id onto any hotbar slot.

signal variant_selected(item_id: int)
signal variant_hovered(item_id: int)
signal variant_unhovered(item_id: int)

const SLOT_TEXTURE := preload("res://textures/inventory/hotbar.png")
const SELECTION_TEXTURE := preload("res://textures/inventory/hotbar_selection.png")
const SLOT_SIZE := 60.0

var item_id: int = -1
var item_name: String = ""
var preview: Texture2D = null

var _selection: TextureRect = null
var _icon: TextureRect = null


func _init() -> void:
	custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	size = Vector2(SLOT_SIZE, SLOT_SIZE)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build()

	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func _build() -> void:
	var background := TextureRect.new()
	background.texture = SLOT_TEXTURE
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	_selection = TextureRect.new()
	_selection.texture = SELECTION_TEXTURE
	_selection.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_selection.stretch_mode = TextureRect.STRETCH_SCALE
	_selection.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_selection.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_selection.visible = false
	_selection.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_selection.offset_left = -3.0
	_selection.offset_top = -3.0
	_selection.offset_right = 3.0
	_selection.offset_bottom = 3.0
	add_child(_selection)

	_icon = TextureRect.new()
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.visible = false
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon.offset_left = 9.0
	_icon.offset_top = 9.0
	_icon.offset_right = -9.0
	_icon.offset_bottom = -9.0
	add_child(_icon)


func setup(id: int, display_name: String, icon: Texture2D, selected: bool) -> void:
	item_id = id
	item_name = display_name
	preview = icon
	tooltip_text = display_name
	if _icon != null:
		_icon.texture = icon
		_icon.visible = icon != null
	set_selected(selected)


func set_selected(selected: bool) -> void:
	if _selection != null:
		_selection.visible = selected


func _gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and not event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
	):
		variant_selected.emit(item_id)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if item_id == -1:
		return null

	var drag_preview := Control.new()
	drag_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_preview.z_index = 4096

	if preview != null:
		var icon_rect := TextureRect.new()
		icon_rect.texture = preview
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon_rect.size = Vector2(48.0, 48.0)
		icon_rect.position = Vector2(-24.0, -24.0)
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_rect.modulate = Color(1.0, 1.0, 1.0, 0.85)
		drag_preview.add_child(icon_rect)
	else:
		var drag_label := Label.new()
		drag_label.text = item_name
		drag_label.position = Vector2(-40.0, -12.0)
		drag_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		drag_label.add_theme_color_override("font_color", Color.WHITE)
		drag_label.add_theme_color_override("font_outline_color", Color.BLACK)
		drag_label.add_theme_constant_override("outline_size", 4)
		drag_preview.add_child(drag_label)

	set_drag_preview(drag_preview)
	return {
		"type": "inventory_block",
		"hotbar_item_id": item_id,
		"item_name": item_name,
	}


func _on_mouse_entered() -> void:
	if item_id != -1:
		variant_hovered.emit(item_id)
	if _icon != null and _icon.visible:
		_icon.modulate = Color(1.5, 1.5, 1.5)


func _on_mouse_exited() -> void:
	if item_id != -1:
		variant_unhovered.emit(item_id)
	if _icon != null:
		_icon.modulate = Color.WHITE
