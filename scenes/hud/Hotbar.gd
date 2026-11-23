class_name Hotbar
extends Control

## Nine-slot build hotbar. Slots show a mesh-library preview, a number, and the
## bundled slot/selection textures. Selection is driven by the hotbar_1 ...
## hotbar_9 input actions (handled by BuildController) or by clicking a slot.

signal slot_selected(index: int)
signal slot_hovered(index: int)
signal slot_unhovered(index: int)
## Emitted whenever a slot's contents change (drop, swap, drag pickup or
## deletion). The HUD uses it to keep the Property tab in sync.
signal slot_contents_changed(index: int)

const SLOT_COUNT: int = 9
const SLOT_SIZE: float = 60.0
const SLOT_SEPARATION: int = 6

const SLOT_TEXTURE_PATH: String = "res://textures/inventory/hotbar.png"
const SELECTION_TEXTURE_PATH: String = (
	"res://textures/inventory/hotbar_selection.png"
)
## The selection art is a full 22x22 overlay (border + tinted centre), so the
## whole texture is used — cropping any row cuts the top of the frame off.
const SELECTION_REGION := Rect2(0.0, 0.0, 22.0, 22.0)

var _slots: Array[Dictionary] = []
var _item_ids := PackedInt32Array()
var _placeable_scenes: Array[PackedScene] = []
var _placeable_previews: Array[Texture2D] = []
var _palette_ids: Array[String] = []
var _palette_previews: Array[Texture2D] = []
var _palette_names: Array[String] = []
var _mesh_library: MeshLibrary = null
var _selected_index: int = 0
var _selection_atlas: AtlasTexture = null
var _slot_texture: Texture2D = null
var _selection_texture: Texture2D = null


## Per-slot Control so a slot can accept a block or placeable dragged out of
## the inventory (see `_get_drag_data` in scenes/inventory/inventory_item.gd).
class SlotControl extends Control:
	signal item_dropped(index: int, item_id: int)
	signal placeable_dropped(index: int, scene: PackedScene, preview: Texture2D)
	signal palette_dropped(
		index: int,
		palette_id: String,
		preview: Texture2D,
		display_name: String
	)

	var index: int = -1

	func _ready() -> void:
		mouse_entered.connect(_set_highlight.bind(true))
		mouse_exited.connect(_set_highlight.bind(false))

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return (
			data is Dictionary
			and (
				data.get("type", "") == "hotbar_item"
				or data.has("hotbar_item_id")
				or data.has("placeable_path")
				or data.has("palette_id")
			)
		)

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		_set_highlight(false)

		if data.get("type", "") == "hotbar_item":
			var container = get_meta("item_container")
			var source = data.get("source_container")
			var source_index: int = int(data.get("source_index", -1))
			var moved: Dictionary = data.get("item", {})
			if container == null or not container.has_method("container_set_slot"):
				return

			# Dropping an item back onto the slot it came from must not delete it:
			# the source was already cleared on pickup.
			if source == container and source_index == index:
				container.container_set_slot(index, moved)
				if container.has_method("select_slot"):
					container.select_slot(index)
				return

			var replaced: Dictionary = container.container_get_slot(index)
			container.container_set_slot(index, moved)

			# Swap the replaced item back into the source slot. The drag source
			# was cleared on pickup, so dropping outside is what deletes an item.
			if (
				source != null
				and is_instance_valid(source)
				and source.has_method("container_set_slot")
				and source_index >= 0
			):
				source.container_set_slot(source_index, replaced)

			if container.has_method("select_slot"):
				container.select_slot(index)
			return

		if data.has("palette_id"):
			palette_dropped.emit(
				index,
				String(data["palette_id"]),
				data.get("preview"),
				String(data.get("item_name", ""))
			)
			return

		if data.has("placeable_path"):
			var scene := load(String(data["placeable_path"])) as PackedScene
			var preview: Texture2D = data.get("preview")
			placeable_dropped.emit(index, scene, preview)
		else:
			item_dropped.emit(index, int(data["hotbar_item_id"]))

	func _get_drag_data(_at_position: Vector2) -> Variant:
		var container = get_meta("item_container")
		if container == null or not container.has_method("container_take_slot"):
			return null

		var item: Dictionary = container.container_take_slot(index)
		if item.is_empty():
			return null

		var preview := _build_drag_preview(item)
		if preview != null:
			set_drag_preview(preview)

		return {
			"type": "hotbar_item",
			"source_container": container,
			"source_index": index,
			"item": item,
		}

	func _build_drag_preview(item: Dictionary) -> Control:
		var root := Control.new()
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.z_index = 4096
		root.size = Vector2(52.0, 52.0)

		var icon: Texture2D = item.get("preview")
		if icon != null:
			var rect := TextureRect.new()
			rect.texture = icon
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			rect.size = Vector2(48.0, 48.0)
			rect.position = Vector2(2.0, 2.0)
			rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(rect)
		else:
			var label := Label.new()
			label.text = String(item.get("name", ""))
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			label.add_theme_font_size_override("font_size", 11)
			label.add_theme_color_override("font_color", Color.WHITE)
			label.add_theme_color_override("font_outline_color", Color.BLACK)
			label.add_theme_constant_override("outline_size", 4)
			label.position = Vector2(-20.0, 16.0)
			root.add_child(label)

		return root

	func _set_highlight(enabled: bool) -> void:
		self_modulate = Color(1.18, 1.18, 1.18) if enabled else Color.WHITE


func _ready() -> void:
	_ensure_built()
	_refresh_all()


## Release the runtime-loaded textures while the renderer is still alive so
## shutdown does not report texture RIDs still in use.
func _exit_tree() -> void:
	for slot in _slots:
		var icon: TextureRect = slot.get("icon")
		var selection: TextureRect = slot.get("selection")
		if icon != null:
			icon.texture = null
		if selection != null:
			selection.texture = null
	for child in get_children():
		if child is HBoxContainer:
			for slot_control in child.get_children():
				for grandchild in slot_control.get_children():
					if grandchild is TextureRect:
						(grandchild as TextureRect).texture = null
	_selection_atlas = null
	_slot_texture = null
	_selection_texture = null


func _ensure_built() -> void:
	if not _slots.is_empty():
		return

	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_slot_texture = load(SLOT_TEXTURE_PATH) as Texture2D
	_selection_texture = load(SELECTION_TEXTURE_PATH) as Texture2D
	_selection_atlas = AtlasTexture.new()
	_selection_atlas.atlas = _selection_texture
	_selection_atlas.region = SELECTION_REGION

	_item_ids.resize(SLOT_COUNT)
	_item_ids.fill(-1)
	_placeable_scenes.resize(SLOT_COUNT)
	_placeable_scenes.fill(null)
	_placeable_previews.resize(SLOT_COUNT)
	_placeable_previews.fill(null)
	_palette_ids.resize(SLOT_COUNT)
	_palette_ids.fill("")
	_palette_previews.resize(SLOT_COUNT)
	_palette_previews.fill(null)
	_palette_names.resize(SLOT_COUNT)
	_palette_names.fill("")

	_build_slots()


## Populates the bar. Items past the ninth are ignored and missing entries
## become empty slots.
func setup(ids: PackedInt32Array, mesh_library: MeshLibrary = null) -> void:
	_ensure_built()

	_mesh_library = mesh_library
	_item_ids.resize(SLOT_COUNT)

	for index in SLOT_COUNT:
		_item_ids[index] = ids[index] if index < ids.size() else -1
		_placeable_scenes[index] = null
		_placeable_previews[index] = null
		_palette_ids[index] = ""
		_palette_previews[index] = null
		_palette_names[index] = ""

	_refresh_all()
	select_slot(_selected_index)


func set_slot_item(index: int, item_id: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return

	_item_ids[index] = item_id
	_placeable_scenes[index] = null
	_placeable_previews[index] = null
	_palette_ids[index] = ""
	_palette_previews[index] = null
	_palette_names[index] = ""
	_refresh_icon(index)
	slot_contents_changed.emit(index)


func get_slot_item(index: int) -> int:
	if index < 0 or index >= SLOT_COUNT:
		return -1

	return _item_ids[index]


## Stores a placeable scene in a slot. The slot shows a placeable instead of a
## mesh-library block; the selected slot decides what the build controller uses.
func set_slot_placeable(
	index: int,
	scene: PackedScene,
	preview: Texture2D = null
) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return

	_item_ids[index] = -1
	_placeable_scenes[index] = scene
	_placeable_previews[index] = preview
	_palette_ids[index] = ""
	_palette_previews[index] = null
	_palette_names[index] = ""
	_refresh_icon(index)
	slot_contents_changed.emit(index)


func get_slot_placeable(index: int) -> PackedScene:
	if index < 0 or index >= SLOT_COUNT:
		return null

	return _placeable_scenes[index]


## Stores a palette as a hotbar item. Palettes are menu items, not buildable
## blocks, so they use their own storage and leave the block id at -1.
func set_slot_palette(
	index: int,
	palette_id: String,
	preview: Texture2D = null,
	display_name: String = ""
) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return

	_item_ids[index] = -1
	_placeable_scenes[index] = null
	_placeable_previews[index] = null
	_palette_ids[index] = palette_id
	_palette_previews[index] = preview
	_palette_names[index] = display_name
	_refresh_icon(index)
	slot_contents_changed.emit(index)


func get_slot_palette(index: int) -> String:
	if index < 0 or index >= SLOT_COUNT:
		return ""
	return _palette_ids[index]


# ---------------------------------------------------------------------------
# Generic item-container protocol
# ---------------------------------------------------------------------------
# Any future container (chest, crate, etc.) can implement these methods and
# tag each clickable slot control with `item_container` = container node and
# `container_index` = slot index. HUDManager handles the shared cursor item.

func container_slot_count() -> int:
	return SLOT_COUNT


func container_get_slot(index: int) -> Dictionary:
	if index < 0 or index >= SLOT_COUNT:
		return {}

	if not _palette_ids[index].is_empty():
		return {
			"kind": "palette",
			"palette_id": _palette_ids[index],
			"preview": _palette_previews[index],
			"name": _palette_names[index],
		}

	if _placeable_scenes[index] != null:
		var scene: PackedScene = _placeable_scenes[index]
		return {
			"kind": "placeable",
			"scene": scene,
			"preview": _placeable_previews[index],
			"name": scene.resource_path.get_file().get_basename().capitalize(),
		}

	var item_id: int = _item_ids[index]
	if item_id == -1:
		return {}

	return {
		"kind": "block",
		"item_id": item_id,
		"preview": (
			_mesh_library.get_item_preview(item_id)
			if _mesh_library != null
			else null
		),
		"name": (
			_mesh_library.get_item_name(item_id)
			if _mesh_library != null
			else str(item_id)
		),
	}


## Places `data` into the slot and returns the item that was there before.
func container_set_slot(index: int, data: Dictionary) -> Dictionary:
	var previous := container_get_slot(index)

	if data.is_empty():
		set_slot_item(index, -1)
	elif String(data.get("kind", "")) == "palette":
		set_slot_palette(
			index,
			String(data.get("palette_id", "")),
			data.get("preview"),
			String(data.get("name", ""))
		)
	elif String(data.get("kind", "")) == "placeable":
		var scene: PackedScene = data.get("scene")
		var preview: Texture2D = data.get("preview")
		set_slot_placeable(index, scene, preview)
	else:
		set_slot_item(index, int(data.get("item_id", -1)))

	return previous


## Removes and returns the slot's item, leaving the slot empty.
func container_take_slot(index: int) -> Dictionary:
	var data := container_get_slot(index)
	if data.is_empty():
		return {}

	set_slot_item(index, -1)
	return data


func select_slot(index: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return

	_selected_index = index
	_refresh_selection()
	slot_selected.emit(index)


func get_selected_slot() -> int:
	return _selected_index


func _build_slots() -> void:
	var row := HBoxContainer.new()
	row.name = "Slots"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", SLOT_SEPARATION)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(row)

	for index in SLOT_COUNT:
		row.add_child(_build_slot(index))


func _build_slot(index: int) -> Control:
	var slot := SlotControl.new()
	slot.name = "Slot%d" % (index + 1)
	slot.index = index
	slot.set_meta("item_container", self)
	slot.set_meta("container_index", index)
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.gui_input.connect(_on_slot_gui_input.bind(index))
	slot.item_dropped.connect(_on_slot_item_dropped)
	slot.placeable_dropped.connect(_on_slot_placeable_dropped)
	slot.palette_dropped.connect(_on_slot_palette_dropped)
	slot.mouse_entered.connect(func(): slot_hovered.emit(index))
	slot.mouse_exited.connect(func(): slot_unhovered.emit(index))

	# 1. Background slot texture (Bottom layer)
	var background := TextureRect.new()
	background.texture = _slot_texture
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	background.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	slot.add_child(background)

	# 2. Selection frame (Above background, behind icon)
	var selection := TextureRect.new()
	selection.name = "Selection"
	selection.texture = _selection_atlas
	selection.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	selection.stretch_mode = TextureRect.STRETCH_SCALE
	selection.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	selection.mouse_filter = Control.MOUSE_FILTER_IGNORE
	selection.visible = false
	selection.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	# Push the borders outward so the selection is larger than the 60x60 slot
	selection.offset_left = -3.0
	selection.offset_top = -3.0
	selection.offset_right = 3.0
	selection.offset_bottom = 3.0
	
	slot.add_child(selection)

	# 3. Item icon preview (Above selection)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.visible = false
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 9.0
	icon.offset_top = 9.0
	icon.offset_right = -9.0
	icon.offset_bottom = -9.0
	slot.add_child(icon)

	# 4. Slot number label (Top layer)
	var number := Label.new()
	number.name = "Number"
	number.text = str(index + 1)
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	number.add_theme_font_size_override("font_size", 12)
	number.add_theme_color_override("font_color", Color(0.94, 0.94, 0.9))
	number.add_theme_color_override(
		"font_outline_color",
		Color(0.02, 0.02, 0.03, 0.9)
	)
	number.add_theme_constant_override("outline_size", 4)
	number.position = Vector2(5.0, 2.0)
	slot.add_child(number)

	_slots.append({
		"icon": icon,
		"selection": selection,
	})

	return slot


func _refresh_all() -> void:
	for index in SLOT_COUNT:
		_refresh_icon(index)

	_refresh_selection()


func _refresh_icon(index: int) -> void:
	var slot: Dictionary = _slots[index]
	var icon: TextureRect = slot["icon"]
	var item_id: int = _item_ids[index]
	var preview: Texture2D = null

	if _placeable_scenes[index] != null:
		preview = _placeable_previews[index]
	elif not _palette_ids[index].is_empty():
		preview = _palette_previews[index]
	elif item_id != -1 and _mesh_library != null:
		preview = _mesh_library.get_item_preview(item_id)

	icon.texture = preview
	icon.visible = preview != null


func _refresh_selection() -> void:
	for index in SLOT_COUNT:
		var slot: Dictionary = _slots[index]
		var selection: TextureRect = slot["selection"]
		selection.visible = index == _selected_index


func _on_slot_gui_input(event: InputEvent, index: int) -> void:
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
	):
		select_slot(index)


## Called when a block is dragged from the inventory onto a slot. Selecting the
## slot also refreshes the preview/label through the usual signal chain.
func _on_slot_item_dropped(index: int, item_id: int) -> void:
	set_slot_item(index, item_id)
	select_slot(index)


## Called when a placeable is dragged from the inventory onto a slot.
func _on_slot_placeable_dropped(
	index: int,
	scene: PackedScene,
	preview: Texture2D
) -> void:
	set_slot_placeable(index, scene, preview)
	select_slot(index)


## Called when a palette is dragged from the inventory onto a slot.
func _on_slot_palette_dropped(
	index: int,
	palette_id: String,
	preview: Texture2D,
	display_name: String
) -> void:
	set_slot_palette(index, palette_id, preview, display_name)
	select_slot(index)
