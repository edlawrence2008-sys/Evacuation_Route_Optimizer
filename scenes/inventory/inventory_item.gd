extends Control

signal item_selected(item_id: int)
signal item_hovered(item_id: int)
signal item_unhovered(item_id: int)
## Emitted by the bottom-right plus badge. The HUD opens the block-group
## variant chooser for this item's group, anchored at the badge's global rect.
signal variants_requested(item_id: int, group_id: String, anchor_rect: Rect2)
## Emitted by the same plus badge on palette cells. The HUD opens the palette's
## 3x3 container instead of the block-variant chooser.
signal palette_requested(palette_id: String, anchor_rect: Rect2)
## Emitted by Useables-tab tool cards. The scene owns a held UseComponent.
signal useable_selected(scene: PackedScene)

const GROUP_PLUS := preload("res://textures/inventory/group_plus.png")
const GROUP_MINUS := preload("res://textures/inventory/group_minus.png")

@onready var texture_rect: TextureRect = $TextureRect
@onready var label: Label = $Label
@onready var top_or_bottom: Sprite2D = $Top_Or_Bottom
@onready var sprite_2d: Sprite2D = $Sprite2D # Reference to your background Sprite2D
@onready var variants_button: TextureButton = get_node_or_null("VariantsButton")

var item_id: int = -1
## Placeables are also draggable: this points at the scene the cell represents.
var placeable_scene: PackedScene = null
## Blocks opt in by default; placeables always pass their scene instead.
var hotbar_draggable: bool = true
## Block-group identity for unified inventory entries. Empty on placeables and
## on inventory cells that are already a single variant.
var block_group_id: String = ""
## Palette cells share the block-group plus badge, but open a 3x3 palette.
var palette_id: String = ""
## Set for a Useables-tab tool card. Clicking selects the held tool.
var useable_scene: PackedScene = null


func _ready() -> void:
	_resolve_variants_button()


func _resolve_variants_button() -> void:
	if variants_button == null:
		variants_button = get_node_or_null("VariantsButton")
	if variants_button == null:
		return
	if not variants_button.pressed.is_connected(_on_variants_pressed):
		variants_button.pressed.connect(_on_variants_pressed)
	_set_variants_texture(GROUP_PLUS)
	variants_button.visible = false

func setup(
	id: int,
	item_name: String,
	icon: Texture2D = null,
	allow_hotbar_drag: bool = true,
	placeable: PackedScene = null
) -> void:
	item_id = id
	hotbar_draggable = allow_hotbar_drag
	placeable_scene = placeable
	_resolve_variants_button()
	
	# --- SET TOOLTIP TO TRUE NAME ---
	tooltip_text = item_name  # Shows the raw/true name on hover
	
	if label:
		var clean_name: String = item_name.trim_prefix("Auto_")
		var lower_name: String = clean_name.to_lower()
		if lower_name.begins_with("connect_"):
			clean_name = clean_name.substr(8)
			lower_name = clean_name.to_lower()

		# Present shape variants as one human-readable "<material>_<shape>".
		# All slab variants share the same "Slab" label; the placement zone
		# chooses top/bottom/vertical at build time.
		var material_name: String = clean_name
		var shape_suffix: String = ""

		if lower_name.begins_with("slab_top_"):
			material_name = clean_name.substr(9)
			shape_suffix = "_Slab"
		elif lower_name.begins_with("slab_bottom_"):
			material_name = clean_name.substr(12)
			shape_suffix = "_Slab"
		elif lower_name.begins_with("slab_side_"):
			material_name = clean_name.substr(10)
			shape_suffix = "_Slab"
		elif lower_name.begins_with("slab_"):
			material_name = clean_name.substr(5)
			shape_suffix = "_Slab"
		elif lower_name.begins_with("panel_top_"):
			material_name = clean_name.substr(10)
			shape_suffix = "_Panel"
		elif lower_name.begins_with("panel_bottom_"):
			material_name = clean_name.substr(13)
			shape_suffix = "_Panel"
		elif lower_name.begins_with("panel_side_"):
			material_name = clean_name.substr(11)
			shape_suffix = "_Panel"
		if lower_name.begins_with("panel_"):
			material_name = clean_name.substr(6)
			shape_suffix = "_Panel"
		elif lower_name.begins_with("water_"):
			material_name = "Water"
			shape_suffix = " " + clean_name.substr(6).capitalize()
		elif lower_name.begins_with("stairs_upsidedown_"):
			material_name = clean_name.substr(18)
			shape_suffix = "_Stairs_UpsideDown"
		elif lower_name.begins_with("stairs_"):
			material_name = clean_name.substr(7)
			shape_suffix = "_Stairs"
		elif lower_name.begins_with("stair_"):
			material_name = clean_name.substr(6)
			shape_suffix = "_Stairs"

		# Colored variants share one group label; the swatch, not the name,
		# communicates the chosen palette color.
		if item_name.to_lower().contains("_colorbase"):
			material_name = BlockMaterials.block_group_label(item_name)
		label.text = material_name + shape_suffix
		tooltip_text = label.text

	# Slabs are unified into one entry, so the old top/bottom badge is no longer
	# meaningful. Keep the node hidden instead of drawing an arbitrary side.
	if top_or_bottom:
		top_or_bottom.visible = false
	
	if texture_rect:
		# Let the whole tile receive the press so clicking anywhere on it selects
		# the item and dragging from anywhere starts a drop. Otherwise the icon
		# swallows the mouse press.
		texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if icon:
			texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			texture_rect.texture = icon
			texture_rect.visible = true
			texture_rect.scale = Vector2.ONE
			# Sets the pivot point to the center so it scales and stays centered
			texture_rect.pivot_offset = texture_rect.size / 2
			
			# Hide Sprite2D and Label when TextureRect has an icon to display
			if sprite_2d:
				sprite_2d.visible = false
			if label:
				label.visible = false
		else:
			texture_rect.visible = false
			
			# Unhide Sprite2D and Label when there is no icon
			if sprite_2d:
				sprite_2d.visible = true
			if label:
				label.visible = true

	# Slabs are unified into one entry, so the old top/bottom badge is no longer
	# meaningful. Keep the node hidden instead of drawing an arbitrary side.
	if top_or_bottom:
		top_or_bottom.visible = false


## Marks this cell as a unified block-group entry. The plus badge appears when
## the group has more than one selectable variant.
func set_variants(group_id: String, has_variants: bool) -> void:
	block_group_id = group_id
	_resolve_variants_button()
	if variants_button == null:
		return
	_set_variants_texture(GROUP_PLUS)
	variants_button.visible = has_variants
	variants_button.disabled = not has_variants
	variants_button.tooltip_text = (
		"Show block variants" if has_variants else ""
	)


## Turns this card into a Useables-tab tool entry. It reuses the normal item
## card so it sits in the same 60x60 inventory grid as blocks and placeables.
func set_useable(
	scene: PackedScene,
	display_name: String,
	icon: Texture2D = null
) -> void:
	useable_scene = scene
	setup(-1, display_name, icon, true, scene)

	if label:
		label.text = display_name
		label.visible = icon == null

	if texture_rect:
		texture_rect.visible = icon != null

	if sprite_2d:
		sprite_2d.visible = icon == null


## Turns this cell into a palette entry. The plus badge is always visible and
## opens the palette container.
func set_palette(id: String) -> void:
	palette_id = id
	_resolve_variants_button()
	if variants_button == null:
		return
	# The palette icon itself carries the centred plus, so the corner badge is
	# redundant. Clicking the cell opens the palette.
	variants_button.visible = false
	variants_button.disabled = true
	variants_button.tooltip_text = ""


## Swaps the badge between group_plus and group_minus while this group's
## variant chooser is open.
func set_variants_open(is_open: bool) -> void:
	if variants_button == null:
		return
	_set_variants_texture(GROUP_MINUS if is_open else GROUP_PLUS)


func _set_variants_texture(texture: Texture2D) -> void:
	if variants_button == null:
		return
	variants_button.texture_normal = texture
	variants_button.texture_pressed = texture
	variants_button.texture_hover = texture


func _on_variants_pressed() -> void:
	var anchor := (
		variants_button.get_global_rect()
		if variants_button != null
		else get_global_rect()
	)
	if not palette_id.is_empty():
		palette_requested.emit(palette_id, anchor)
		return
	variants_requested.emit(item_id, block_group_id, anchor)


func _gui_input(event: InputEvent) -> void:
	# Emit on release, not press: pressing also starts a drag, and a drag that
	# ends on the hotbar must not first assign the item to the current slot.
	if (
		event is InputEventMouseButton
		and not event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
	):
		if useable_scene != null:
			useable_selected.emit(useable_scene)
			return

		item_selected.emit(item_id)

## Enables dragging inventory blocks and placeables onto hotbar slots. The
## hotbar's slots look for `hotbar_item_id` or `placeable_path` in
## `_can_drop_data` / `_drop_data`.
func _get_drag_data(_at_position: Vector2) -> Variant:
	var is_palette := not palette_id.is_empty()
	if item_id == -1 and not is_palette and placeable_scene == null:
		return null

	if not is_palette and placeable_scene == null and not hotbar_draggable:
		return null

	var icon: Texture2D = texture_rect.texture if texture_rect else null
	var display_name: String = label.text if label else ""

	# Godot positions the preview control itself at the cursor each frame, so the
	# visible icon lives in a child offset by half its size to stay centred.
	var preview := Control.new()
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.z_index = 4096

	if icon:
		var icon_rect := TextureRect.new()
		icon_rect.texture = icon
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon_rect.size = Vector2(48.0, 48.0)
		icon_rect.position = Vector2(-24.0, -24.0)
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_rect.modulate = Color(1.0, 1.0, 1.0, 0.85)
		preview.add_child(icon_rect)
	else:
		var preview_label := Label.new()
		preview_label.text = display_name
		preview_label.position = Vector2(-40.0, -12.0)
		preview_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		preview_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
		preview_label.add_theme_color_override(
			"font_outline_color",
			Color(0.0, 0.0, 0.0)
		)
		preview_label.add_theme_constant_override("outline_size", 4)
		preview.add_child(preview_label)

	set_drag_preview(preview)

	if is_palette:
		return {
			"type": "inventory_palette",
			"palette_id": palette_id,
			"item_name": display_name,
			"preview": icon,
		}

	if placeable_scene:
		return {
			"type": "inventory_placeable",
			"placeable_path": placeable_scene.resource_path,
			"item_name": display_name,
			"preview": icon,
		}

	return {
		"type": "inventory_block",
		"hotbar_item_id": item_id,
		"item_name": display_name,
		"preview": icon,
	}

func _on_mouse_entered() -> void:
	if item_id != -1:
		item_hovered.emit(item_id)

	if texture_rect and texture_rect.visible:
		texture_rect.modulate = Color(1.5, 1.5, 1.5) # Brightens/whitens the icon
	
	if label and label.visible and (texture_rect == null or not texture_rect.visible):
		label.modulate = Color(0.2, 0.2, 0.2) # Darkens/makes the text blacker

func _on_mouse_exited() -> void:
	if item_id != -1:
		item_unhovered.emit(item_id)

	if texture_rect and texture_rect.visible:
		texture_rect.modulate = Color(1, 1, 1) # Resets icon color
	
	if label and label.visible and (texture_rect == null or not texture_rect.visible):
		label.modulate = Color(1, 1, 1) # Resets text color
