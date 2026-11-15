class_name PaletteSlot
extends Control

## One 3x3 cell inside a block/placeable palette. It uses the hotbar slot art so
## the palette reads as a tiny hotbar grid. Accepts blocks and placeables
## dragged from the inventory, the hotbar, or another palette slot; right-click
## clears it. Palette contents are owned by `PaletteStore`, so the HUD listens
## to `slot_changed` and persists the new item.

signal slot_changed(index: int, data: Dictionary)

const SLOT_TEXTURE := preload("res://textures/inventory/hotbar.png")
const SLOT_SIZE := 56.0

var index: int = 0
var data: Dictionary = {}
## Called with the slot dictionary when the persisted item has no preview.
var icon_provider: Callable = Callable()

var _icon: TextureRect = null
var _label: Label = null
var _highlighted: bool = false


func _init() -> void:
	custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	size = Vector2(SLOT_SIZE, SLOT_SIZE)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build()
	mouse_entered.connect(_set_highlight.bind(true))
	mouse_exited.connect(_set_highlight.bind(false))


func _build() -> void:
	var background := TextureRect.new()
	background.texture = SLOT_TEXTURE
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	_icon = TextureRect.new()
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.visible = false
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon.offset_left = 7.0
	_icon.offset_top = 7.0
	_icon.offset_right = -7.0
	_icon.offset_bottom = -7.0
	add_child(_icon)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(1.0, 0.96, 0.8))
	_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
	_label.add_theme_constant_override("outline_size", 3)
	_label.visible = false
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.offset_left = 4.0
	_label.offset_top = 4.0
	_label.offset_right = -4.0
	_label.offset_bottom = -4.0
	add_child(_label)


func setup(slot_index: int, slot_data: Dictionary = {}) -> void:
	index = slot_index
	set_item(slot_data)


func set_item(slot_data: Dictionary) -> void:
	data = slot_data.duplicate(true) if slot_data is Dictionary else {}
	_refresh()


func get_item() -> Dictionary:
	return data.duplicate(true)


func notify_slot_changed() -> void:
	slot_changed.emit(index, data)


## Re-resolves the icon after the HUD has a mesh library or scene preview.
func refresh_icon() -> void:
	_refresh()


func _refresh() -> void:
	var icon := _resolved_icon()
	if _icon != null:
		_icon.texture = icon
		_icon.visible = icon != null

	var display := _display_name()
	if _label != null:
		_label.text = display
		_label.visible = not data.is_empty() and icon == null
	tooltip_text = display if not data.is_empty() else "Drop a block or placeable"


func _resolved_icon() -> Texture2D:
	if data.is_empty():
		return null
	var preview: Variant = data.get("preview")
	if preview is Texture2D:
		return preview as Texture2D
	if icon_provider.is_valid():
		var provided: Variant = icon_provider.call(data)
		if provided is Texture2D:
			return provided as Texture2D
	return null


func _display_name() -> String:
	var display := String(data.get("display_name", ""))
	if not display.is_empty():
		return display
	var item_name := String(data.get("item_name", data.get("name", "")))
	if not item_name.is_empty():
		return item_name
	var scene_path := String(data.get("scene_path", ""))
	if not scene_path.is_empty():
		return scene_path.get_file().get_basename().capitalize()
	return ""


# ---------------------------------------------------------------------------
# Drag and drop
# ---------------------------------------------------------------------------

func _can_drop_data(_at_position: Vector2, drag_data: Variant) -> bool:
	if not drag_data is Dictionary:
		return false
	var payload := drag_data as Dictionary
	var type := String(payload.get("type", ""))
	var accepted := (
		type == "inventory_block"
		or type == "inventory_placeable"
		or type == "hotbar_item"
		or type == "palette_item"
		or payload.has("hotbar_item_id")
		or payload.has("placeable_path")
	)
	if accepted:
		_set_highlight(true)
	return accepted


func _drop_data(_at_position: Vector2, drag_data: Variant) -> void:
	_set_highlight(false)
	if not drag_data is Dictionary:
		return
	var payload := drag_data as Dictionary
	var type := String(payload.get("type", ""))

	var source_slot: Variant = payload.get("source_slot")
	if source_slot == self:
		return

	var incoming := _normalize_drop(payload)
	if incoming.is_empty():
		return

	var previous := data.duplicate(true)
	set_item(incoming)
	slot_changed.emit(index, data)

	if type == "palette_item":
		if (
			source_slot != null
			and is_instance_valid(source_slot)
			and source_slot is Control
			and source_slot.has_method("set_item")
		):
			source_slot.set_item(previous)
			if source_slot.has_method("notify_slot_changed"):
				source_slot.notify_slot_changed()
		return

	if type == "hotbar_item":
		# The hotbar cleared its source slot on pickup; put the replaced palette
		# item back there so dragging between containers gracefully swaps.
		var source_container: Variant = payload.get("source_container")
		var source_index := int(payload.get("source_index", -1))
		if (
			source_container != null
			and is_instance_valid(source_container)
			and source_container.has_method("container_set_slot")
			and source_index >= 0
		):
			source_container.container_set_slot(source_index, _to_container_item(previous))


func _get_drag_data(_at_position: Vector2) -> Variant:
	if data.is_empty():
		return null

	var preview := _build_drag_preview()
	if preview != null:
		set_drag_preview(preview)

	return {
		"type": "palette_item",
		"source_slot": self,
		"item": data.duplicate(true),
	}


func _normalize_drop(payload: Dictionary) -> Dictionary:
	var type := String(payload.get("type", ""))

	if type == "palette_item":
		var item: Variant = payload.get("item", {})
		return item.duplicate(true) if item is Dictionary else {}

	if type == "hotbar_item":
		var hotbar_item: Variant = payload.get("item", {})
		if not hotbar_item is Dictionary:
			return {}
		var item := hotbar_item as Dictionary
		var hotbar_kind := String(item.get("kind", ""))
		if hotbar_kind == "palette":
			# Palettes hold blocks/placeables, not other palettes.
			return {}
		if hotbar_kind == "placeable":
			var scene: Variant = item.get("scene")
			var path := String(scene.resource_path) if scene is PackedScene else ""
			return {
				"kind": "placeable",
				"scene_path": path,
				"item_name": String(item.get("name", "")),
				"preview": item.get("preview"),
			}
		return {
			"kind": "block",
			"item_id": int(item.get("item_id", -1)),
			"item_name": String(item.get("name", "")),
			"preview": item.get("preview"),
		}

	if type == "inventory_placeable" or payload.has("placeable_path"):
		return {
			"kind": "placeable",
			"scene_path": String(payload.get("placeable_path", "")),
			"item_name": String(payload.get("item_name", "")),
			"preview": payload.get("preview"),
		}

	if type == "inventory_block" or payload.has("hotbar_item_id"):
		return {
			"kind": "block",
			"item_id": int(payload.get("hotbar_item_id", -1)),
			"item_name": String(payload.get("item_name", "")),
			"preview": payload.get("preview"),
		}

	return {}


func _to_container_item(item: Dictionary) -> Dictionary:
	if item.is_empty():
		return {}
	var icon := _icon_for_data(item)
	if String(item.get("kind", "")) == "placeable":
		var path := String(item.get("scene_path", ""))
		var scene: PackedScene = null
		if not path.is_empty():
			scene = load(path) as PackedScene
		if scene == null:
			return {}
		return {
			"kind": "placeable",
			"scene": scene,
			"preview": icon,
			"name": String(item.get("display_name", item.get("item_name", ""))),
		}
	return {
		"kind": "block",
		"item_id": int(item.get("item_id", -1)),
		"preview": icon,
		"name": String(item.get("display_name", item.get("item_name", ""))),
	}


func _icon_for_data(item: Dictionary) -> Texture2D:
	var preview: Variant = item.get("preview")
	if preview is Texture2D:
		return preview as Texture2D
	if icon_provider.is_valid():
		var provided: Variant = icon_provider.call(item)
		if provided is Texture2D:
			return provided as Texture2D
	return null


func _build_drag_preview() -> Control:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.z_index = 4096

	var icon := _resolved_icon()
	if icon != null:
		var rect := TextureRect.new()
		rect.texture = icon
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		rect.size = Vector2(44.0, 44.0)
		rect.position = Vector2(-22.0, -22.0)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.modulate = Color(1.0, 1.0, 1.0, 0.9)
		root.add_child(rect)
	else:
		var label := Label.new()
		label.text = _display_name()
		label.position = Vector2(-30.0, -10.0)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", 4)
		root.add_child(label)

	return root


func _gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_RIGHT
		and not data.is_empty()
	):
		set_item({})
		slot_changed.emit(index, {})
		accept_event()


func _set_highlight(enabled: bool) -> void:
	_highlighted = enabled
	self_modulate = Color(1.2, 1.2, 1.2) if enabled else Color.WHITE


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_set_highlight(false)
