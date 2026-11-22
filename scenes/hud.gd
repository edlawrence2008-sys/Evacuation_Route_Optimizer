class_name HUDManager
extends Control

@onready var build_ui_label: Label = $Label
@onready var hotbar: Hotbar = $Hotbar
@onready var inventory_panel: Control = $Inventory
@onready var inventory_container: VBoxContainer = $Inventory/ContentScroll/Groups
@onready var search_bar: LineEdit = $Inventory/SearchBar

@onready var item_button_scene: PackedScene = load("res://scenes/inventory/InventoryItem.tscn")

@onready var blocks_button: Button = $Inventory/ItemCategoryScroll/ItemCategoryHbox/Blocks
@onready var placeables_button: Button = $Inventory/ItemCategoryScroll/ItemCategoryHbox/Placeables
@onready var simulation_button: Button = $Inventory/ItemCategoryScroll/ItemCategoryHbox/Simulation
@onready var agents_button: Button = $Inventory/ItemCategoryScroll/ItemCategoryHbox/Agents
@onready var category_arrow: Sprite2D = $Inventory/CategoryArrow
@onready var simulation_panel: Control = $Inventory/SimulationPanel
@onready var agent_panel: Control = $Inventory/AgentPanel

# --- FILTER CONTAINER & SCENE ---
@onready var category_filters_container: Container = $Inventory/ItemFilters/GridContainer
@onready var filter_checkbox_scene: PackedScene = load("res://scenes/inventory/InventoryCheckBox.tscn")

@export var placeable_scenes: Array[PackedScene] = []

## Preloaded so offline validators and first-run imports resolve the new
## registry before Godot rebuilds its global class cache.
const BlockMaterialsDB := preload("res://scripts/block_materials.gd")
const BlockVariantSlot := preload("res://scenes/inventory/block_variant_slot.gd")
const ColorPaletteDBScript := preload("res://scripts/color_palette_db.gd")
const PaletteSlotScript := preload("res://scenes/inventory/palette_slot.gd")
const PaletteStoreScript := preload("res://scripts/palette_store.gd")
const PixelPanelScript := preload("res://scenes/ui/pixel_panel.gd")
const VoxelItemDB := preload("res://scripts/voxel_item_generator.gd")
const PALETTE_ICON := preload("res://textures/inventory/palette_icon.png")
const PALETTE_BLANK_ICON := preload("res://textures/inventory/palette_blank.png")

const PLACEABLE_FOLDERS := [
	"res://scenes/placeables/sim/",
	"res://scenes/placeables/device/",
	"res://scenes/placeables/foilage/",
]

## Property-tab row labels -> canonical BlockMaterials keys.
const BLOCK_PROPERTY_KEYS := {
	"Base Stability": "base_stability",
	"Base Durability": "base_durability",
	"Base Weight": "base_weight",
	"Bouyancy": "buoyancy",
	"Base Path Cost": "base_path_cost",
	"Flammability": "flammability",
}

# --- OFFSET CONTROLS ---
@export var arrow_x_offset: float = 10.0
@export var arrow_y_offset: float = 0.0

@onready var property_tab: Control = $Inventory/Property_tab
var adjustable_vars_container: VBoxContainer = null
@onready var adjustable_var_row_scene: PackedScene = load("res://scenes/inventory/AdjustableVariableRow.tscn")

signal item_selected(item_id: int)
signal placeable_selected(scene: PackedScene)
signal hotbar_slot_selected(index: int)

var _last_inventory_visible: bool = false

## The build label is a general-purpose transient message. Item selection and
## axis changes write to it; it holds for a moment, then fades out.
const BUILD_LABEL_HOLD := 1.6
const BUILD_LABEL_FADE := 0.55
var _build_mode_active: bool = false
var _last_build_label_text: String = ""
var _build_label_hold_left: float = 0.0
var _build_label_fade_left: float = 0.0
var _build_label_fade_duration: float = BUILD_LABEL_FADE
var _build_label_fading: bool = false

var _cached_build_items: PackedInt32Array
var _cached_mesh_library: MeshLibrary

var _selected_placeable_scene: PackedScene = null
## Edits made to the clicked placeable, kept while hovering other items.
var _selected_placeable_overrides: Dictionary = {}
var _displayed_placeable_scene: PackedScene = null
## Item currently described by the Property tab. Hover previews take priority
## over the clicked/selected item, but are not persisted.
var _property_pinned_item: Dictionary = {}
var _property_hover_item: Dictionary = {}
var _placeable_property_cache: Dictionary = {}
## Instantiating a placeable scene just to steal its icon is expensive, so the
## previews are cached the first time the inventory is built.
var _scene_preview_cache: Dictionary = {}
var _property_title: Label = null
var _property_preview: Control = null
var _property_texture: TextureRect = null
var _property_viewport: SubViewport = null
var _property_viewport_container: SubViewportContainer = null
var _property_mesh_pivot: Node3D = null
var _property_mesh_instance: MeshInstance3D = null
var _property_camera: Camera3D = null
## Grafted placeable visuals shown in the Property-tab preview while a
## placeable is inspected. Blocks use `_property_mesh_instance` instead.
var _property_placeable_holder: Node3D = null
var _property_block_props: VBoxContainer = null
var _property_description: Label = null
var _property_separator: HSeparator = null
var _property_exports: VBoxContainer = null
var _property_spin_t: float = 0.0
## Resolved from the authored BlockProperties rows: one entry per row with its
## label text (used as the data key), value Label, and scene-authored default.
var _property_block_rows: Array[Dictionary] = []

enum Category { BLOCKS, PLACEABLES, SIMULATION, AGENTS }
var _current_category: Category = Category.BLOCKS

# Active filter tracking
var _active_filters: Array[String] = []
var _search_query: String = ""

## Block-group inventory state. Keyed by BlockMaterials.block_group_id; the
## value is the item id currently shown for that group. Slab/stairs/panel
## choices persist for the session and survive inventory rebuilds.
var _block_group_display: Dictionary = {}
## Selected palette color per colorbase group.
var _block_color_choice: Dictionary = {}
var _variants_panel: Control = null
var _variants_content: MarginContainer = null
var _variants_grid: GridContainer = null
var _variants_color_box: GridContainer = null
var _variants_color_label: Label = null
var _variants_title: Label = null
var _variants_group_id: String = ""

## Block/placeable palettes. Each palette is an inventory item that opens a
## 3x3 container. The store persists names and slot contents in the player save
## root (`user://saves/palettes.json`).
var _palette_store: PaletteStore = null
var _palettes_panel: PixelPanel = null
var _palettes_content: MarginContainer = null
var _palettes_grid: GridContainer = null
var _palettes_name: LineEdit = null
var _palettes_slots: Array = []
var _palettes_current_id: String = ""
var _palette_badge_msec: int = 0

## Popups follow their anchor by default. Once the player drags one, its local
## position is remembered (so it still moves with the inventory) and re-anchoring
## is skipped.
var _variants_user_moved: bool = false
var _variants_user_position: Vector2 = Vector2.ZERO
var _palettes_user_moved: bool = false
var _palettes_user_position: Vector2 = Vector2.ZERO
var _popup_drag_target: Control = null
var _popup_drag_moved: bool = false
var _palette_delete_dialog: ConfirmationDialog = null

const VARIANT_ORDER := {
	"block": 0,
	"slab": 1,
	"stairs": 2,
	"panel": 3,
}

## Drop texture and scene references while the rendering server is still alive
## so shutdown does not report leaked texture RIDs.
func _exit_tree() -> void:
	for node in find_children("*", "TextureRect", true, false):
		(node as TextureRect).texture = null
	for node in find_children("*", "Sprite2D", true, false):
		(node as Sprite2D).texture = null
	for node in find_children("*", "Sprite3D", true, false):
		(node as Sprite3D).texture = null
	item_button_scene = null
	_cached_mesh_library = null
	_selected_placeable_scene = null
	_selected_placeable_overrides.clear()
	_displayed_placeable_scene = null
	_scene_preview_cache.clear()
	_placeable_property_cache.clear()
	placeable_scenes.clear()


func _ready() -> void:
	if blocks_button:
		blocks_button.pressed.connect(func(): _on_category_pressed(Category.BLOCKS))
	if placeables_button:
		placeables_button.pressed.connect(func(): _on_category_pressed(Category.PLACEABLES))
	if simulation_button:
		simulation_button.pressed.connect(func(): _on_category_pressed(Category.SIMULATION))
	if agents_button:
		agents_button.pressed.connect(func(): _on_category_pressed(Category.AGENTS))
	if search_bar:
		search_bar.text_changed.connect(_on_search_changed)
	if hotbar:
		hotbar.slot_selected.connect(_on_hotbar_slot_selected)
		hotbar.slot_hovered.connect(_on_hotbar_slot_hovered)
		hotbar.slot_unhovered.connect(_on_hotbar_slot_unhovered)
		hotbar.slot_contents_changed.connect(_on_hotbar_contents_changed)

	_append_placeables_from_folders()

	_resolve_property_tab_ui()
	_ensure_variants_panel()
	_palette_store = PaletteStoreScript.new()
	_ensure_palettes_panel()
	if property_tab:
		property_tab.visible = false
		_clear_adjustable_vars()

	_update_category_arrow.call_deferred()
	_update_category_panel.call_deferred()


## Adds every placeable scene from the class folders (sim, device, foilage) to
## the inventory. Device lights and future class scenes appear automatically.
func _append_placeables_from_folders() -> void:
	for folder: String in PLACEABLE_FOLDERS:
		if not DirAccess.dir_exists_absolute(folder):
			continue

		var files := DirAccess.get_files_at(folder)
		files.sort()

		for file_name: String in files:
			if not file_name.ends_with(".tscn"):
				continue

			var scene := load(folder.path_join(file_name)) as PackedScene
			if scene != null and not placeable_scenes.has(scene):
				placeable_scenes.append(scene)

## Resolves the Property-tab nodes authored in property_tab.tscn. Layout,
## colors, fonts and the default stat values are edited in the scene; the HUD
## only fills in the dynamic parts (title, preview, values, exports).
func _resolve_property_tab_ui() -> void:
	if property_tab == null:
		return

	var list := property_tab.get_node_or_null(
		"Content/ContentScroll/ListPadding/List"
	)
	if list == null:
		# Fallback for an older/edited scene without the scrollbar padding.
		list = property_tab.get_node_or_null("Content/ContentScroll/List")
	if list == null:
		push_warning("Property_tab is missing Content/ContentScroll/ListPadding/List")
		return

	_property_preview = list.get_node_or_null("Preview") as Control
	_property_texture = list.get_node_or_null("Preview/PreviewTexture") as TextureRect
	_property_viewport_container = list.get_node_or_null(
		"Preview/PreviewViewport"
	) as SubViewportContainer
	_property_viewport = list.get_node_or_null(
		"Preview/PreviewViewport/MeshViewport"
	) as SubViewport
	_property_mesh_pivot = list.get_node_or_null(
		"Preview/PreviewViewport/MeshViewport/MeshPivot"
	) as Node3D
	_property_mesh_instance = list.get_node_or_null(
		"Preview/PreviewViewport/MeshViewport/MeshPivot/PreviewMesh"
	) as MeshInstance3D
	_property_camera = list.get_node_or_null(
		"Preview/PreviewViewport/MeshViewport/PreviewCamera"
	) as Camera3D
	_property_title = list.get_node_or_null("TitleSlot/Title") as Label
	if _property_title == null:
		# Fallback for an older scene without the title slot.
		_property_title = list.get_node_or_null("Title") as Label
	_property_block_props = list.get_node_or_null("BlockProperties") as VBoxContainer
	_property_description = list.get_node_or_null("Description") as Label
	_property_separator = list.get_node_or_null("Separator") as HSeparator
	_property_exports = list.get_node_or_null("Exports") as VBoxContainer
	adjustable_vars_container = _property_exports

	# Block stat rows are authored in the scene. Each row's name label doubles
	# as the data key, and its value label text is the default shown when the
	# block data does not provide that key.
	_property_block_rows.clear()
	if _property_block_props:
		for row in _property_block_props.get_children():
			var name_label := row.get_node_or_null("Name") as Label
			var value_label := row.get_node_or_null("Value") as Label
			if value_label == null:
				continue
			_property_block_rows.append({
				"key": name_label.text if name_label else "",
				"value": value_label,
				"default": value_label.text,
			})


## Closes the block-variant chooser when the player clicks outside it, presses
## Escape, or clicks another plus badge (which then opens its own group).
func _input(event: InputEvent) -> void:
	var variants_open: bool = _variants_panel != null and _variants_panel.visible
	var palettes_open: bool = _palettes_panel != null and _palettes_panel.visible
	if not variants_open and not palettes_open:
		return

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			if variants_open:
				_hide_variants_panel()
			if palettes_open:
				_hide_palettes_panel()
			get_viewport().set_input_as_handled()
		return

	if not (event is InputEventMouseButton):
		return
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed or mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return

	# Palettes stay open while the player switches inventory categories or drags
	# blocks/placeables into them. Only Escape, the palette badge, or closing the
	# inventory dismisses a palette.
	if not variants_open:
		return

	var mouse := get_global_mouse_position()
	if _variants_panel.get_global_rect().has_point(mouse):
		return
	if _pointer_over_variants_button(mouse):
		return
	_hide_variants_panel()


func _pointer_over_variants_button(mouse: Vector2) -> bool:
	for node in find_children("*", "", true, false):
		if not node is Control:
			continue
		var control := node as Control
		if (
			control.name == "VariantsButton"
			and control.visible
			and control.get_global_rect().has_point(mouse)
		):
			return true
	return false


func _process(delta: float) -> void:
	_update_build_label(delta)

	if (
		_property_mesh_pivot == null
		or property_tab == null
		or not property_tab.visible
	):
		return
	var has_block_mesh := (
		_property_mesh_instance != null
		and _property_mesh_instance.visible
	)
	var has_placeable := (
		_property_placeable_holder != null
		and is_instance_valid(_property_placeable_holder)
	)
	if not has_block_mesh and not has_placeable:
		return

	_property_spin_t += delta
	_property_mesh_pivot.rotation = Vector3(
		0.0,
		_property_spin_t * 0.8,
		0.0
	)


func setup_inventory(build_items: PackedInt32Array, mesh_library: MeshLibrary) -> void:
	_cached_build_items = build_items
	_cached_mesh_library = mesh_library
	
	_setup_hotbar()
	_refresh_filters()
	_refresh_inventory_display()
	_update_category_arrow()


## The bar starts empty-handed; the player fills slots by clicking inventory
## items or dragging them onto a slot.
func _setup_hotbar() -> void:
	if not hotbar:
		return

	hotbar.setup(PackedInt32Array(), _cached_mesh_library)


func select_hotbar_slot(index: int) -> void:
	if hotbar:
		hotbar.select_slot(index)


func get_hotbar_selected_slot() -> int:
	return hotbar.get_selected_slot() if hotbar else -1


func get_hotbar_item(index: int) -> int:
	return hotbar.get_slot_item(index) if hotbar else -1


func get_hotbar_placeable(index: int) -> PackedScene:
	if hotbar == null:
		return null

	return hotbar.get_slot_placeable(index)


func get_hotbar_palette(index: int) -> String:
	if hotbar == null:
		return ""
	return hotbar.get_slot_palette(index)


func get_palette_name(palette_id: String) -> String:
	if _palette_store == null:
		return "Palette"
	var palette := _palette_store.get_palette(palette_id)
	if palette.is_empty():
		return "Palette"
	return String(palette.get("name", "Palette"))


## Fast block-only view used by the hover/hand preview every frame. Avoids
## loading placeable scenes just to show a block ghost.
func get_palette_block_ids(palette_id: String) -> Array[int]:
	var ids: Array[int] = []
	if _palette_store == null:
		return ids
	for slot_index in PaletteStoreScript.SLOT_COUNT:
		var slot_data := _palette_store.get_slot(palette_id, slot_index)
		if slot_data.is_empty() or String(slot_data.get("kind", "")) != "block":
			continue
		var item_id := int(slot_data.get("item_id", -1))
		var item_name := String(slot_data.get("item_name", ""))
		if _cached_mesh_library != null:
			if (
				not _cached_build_items.has(item_id)
				or (
					not item_name.is_empty()
					and String(_cached_mesh_library.get_item_name(item_id)) != item_name
				)
			):
				item_id = _mesh_id_for_name(item_name)
			if not _cached_build_items.has(item_id):
				continue
		elif item_id < 0:
			continue
		if not ids.has(item_id):
			ids.append(item_id)
	return ids


## Every filled palette slot as a placement candidate. Blocks carry a repaired
## MeshLibrary id; placeables carry their loaded scene. Duplicate slots are
## intentionally preserved so repeated entries are weighted more heavily.
func get_palette_entries(palette_id: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if _palette_store == null:
		return entries
	for slot_index in PaletteStoreScript.SLOT_COUNT:
		var slot_data := _palette_store.get_slot(palette_id, slot_index)
		if slot_data.is_empty():
			continue
		var kind := String(slot_data.get("kind", ""))
		if kind == "block":
			var item_id := int(slot_data.get("item_id", -1))
			var item_name := String(slot_data.get("item_name", ""))
			if _cached_mesh_library != null:
				if (
					not _cached_build_items.has(item_id)
					or (
						not item_name.is_empty()
						and String(_cached_mesh_library.get_item_name(item_id)) != item_name
					)
				):
					item_id = _mesh_id_for_name(item_name)
				if not _cached_build_items.has(item_id):
					continue
			elif item_id < 0:
				continue
			entries.append({"kind": "block", "item_id": item_id})
		elif kind == "placeable":
			var scene_path := String(slot_data.get("scene_path", ""))
			if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
				continue
			var scene := load(scene_path) as PackedScene
			if scene != null:
				entries.append({"kind": "placeable", "scene": scene})
	return entries


## Opens the palette stored in a hotbar slot, anchored to that slot.
func open_hotbar_palette(index: int, palette_id: String) -> void:
	var anchor := Rect2()
	if hotbar != null:
		var slot := hotbar.find_child("Slot%d" % (index + 1), true, false) as Control
		if slot != null:
			anchor = slot.get_global_rect()
	_show_palette(palette_id, anchor)


func assign_hotbar_item(index: int, item_id: int) -> void:
	if hotbar:
		hotbar.set_slot_item(index, item_id)


func assign_hotbar_placeable(index: int, scene: PackedScene) -> void:
	if hotbar:
		hotbar.set_slot_placeable(index, scene, _get_scene_preview(scene))


func _on_hotbar_slot_selected(index: int) -> void:
	# The selected slot decides what is held, so keep the placeable selection
	# and the property sheet in sync when the player switches slots.
	if (
		_displayed_placeable_scene == _selected_placeable_scene
		and _selected_placeable_scene != null
	):
		_selected_placeable_overrides = get_placeable_overrides()

	var next_scene: PackedScene = get_hotbar_placeable(index)
	if next_scene != _selected_placeable_scene:
		_selected_placeable_overrides.clear()
	_selected_placeable_scene = next_scene
	_property_hover_item.clear()
	_property_pinned_item = _hotbar_item_data(index)
	_refresh_property_tab()

	hotbar_slot_selected.emit(index)

func _refresh_filters() -> void:
	if not category_filters_container and has_node("Inventory/ItemFilters/GridContainer"):
		category_filters_container = $Inventory/ItemFilters/GridContainer as Container

	if not category_filters_container or not filter_checkbox_scene:
		return

	for child in category_filters_container.get_children():
		child.queue_free()

	if (
		_current_category == Category.SIMULATION
		or _current_category == Category.AGENTS
	):
		_active_filters.clear()
		return

	var available_tags: Array[String] = []

	match _current_category:
		Category.BLOCKS:
			if _cached_mesh_library:
				for id in _cached_build_items:
					var item_name = _cached_mesh_library.get_item_name(id)
					var tags = _get_item_tags(item_name)
					for t in tags:
						if not available_tags.has(t):
							available_tags.append(t)
		Category.PLACEABLES:
			for scene in placeable_scenes:
				if not scene:
					continue
				var tag: String = _placeable_class(scene)
				if not available_tags.has(tag):
					available_tags.append(tag)

	# ALL filters are on by default
	_active_filters = available_tags.duplicate()

	for tag in available_tags:
		var cb_node = filter_checkbox_scene.instantiate()
		category_filters_container.add_child(cb_node)
		
		if cb_node.has_method("setup"):
			cb_node.setup(tag, true)
			if cb_node.has_signal("filter_toggled") and not cb_node.filter_toggled.is_connected(_on_filter_toggled):
				cb_node.filter_toggled.connect(_on_filter_toggled)
		elif cb_node is CheckBox:
			cb_node.text = tag
			cb_node.button_pressed = true
			if not cb_node.toggled.is_connected(func(toggled: bool): _on_filter_toggled(tag, toggled)):
				cb_node.toggled.connect(func(toggled: bool): _on_filter_toggled(tag, toggled))

## Extracts all applicable tags for an item (e.g. both Material and shape).
## Every slab variant shares the single "Slab" shape tag; upside-down stairs
## share "Stairs" with normal stairs so the inventory has one slab entry and one
## stair group per material.
func _get_item_tags(item_name: String) -> Array[String]:
	var tags: Array[String] = []
	var clean = item_name.trim_prefix("Auto_")
	clean = clean.replace(" ", "_")
	var lower = clean.to_lower()

	# Strip the shape prefix and keep the material as the second tag.
	if lower.begins_with("connect_"):
		clean = clean.substr(8)
		lower = clean.to_lower()
	if lower.begins_with("slab_top_"):
		tags.append("Slab")
		clean = clean.substr(9)
	elif lower.begins_with("slab_bottom_"):
		tags.append("Slab")
		clean = clean.substr(12)
	elif lower.begins_with("slab_side_"):
		tags.append("Slab")
		clean = clean.substr(10)
	elif lower.begins_with("slab_"):
		tags.append("Slab")
		clean = clean.substr(5)
	elif lower.begins_with("panel_top_"):
		tags.append("Panel")
		clean = clean.substr(10)
	elif lower.begins_with("panel_bottom_"):
		tags.append("Panel")
		clean = clean.substr(13)
	elif lower.begins_with("panel_side_"):
		tags.append("Panel")
		clean = clean.substr(11)
	elif lower.begins_with("panel_"):
		tags.append("Panel")
		clean = clean.substr(6)
	elif lower.begins_with("stairs_upsidedown_"):
		tags.append("Stairs")
		clean = clean.substr(18)
	elif lower.begins_with("stairs_"):
		tags.append("Stairs")
		clean = clean.substr(7)
	elif lower.begins_with("stair_"):
		tags.append("Stairs")
		clean = clean.substr(6)

	# Extract the block material label from the remaining name. The JSON
	# registry owns the display names so inventory headers and the Property tab
	# agree on the same block material.
	clean = clean.strip_edges().trim_prefix("_").trim_suffix("_")
	var material_tag := BlockMaterialsDB.material_label(item_name)
	if material_tag.is_empty():
		var parts = clean.split("_")
		if parts.size() > 0 and not parts[0].is_empty():
			material_tag = parts[0].capitalize()
	if not material_tag.is_empty() and not tags.has(material_tag):
		tags.append(material_tag)

	return tags


## Bottom/side slabs and upside-down stairs are placement variants of the one
## inventory Slab/Stairs entry. They stay in the MeshLibrary but are not listed
## as separate items.
func _is_hidden_block_variant(item_name: String) -> bool:
	var lower := item_name.to_lower()
	if lower.begins_with("auto_connect_"):
		for code in ["_tl", "_t", "_tr", "_l", "_c", "_r", "_bl", "_b", "_br"]:
			if lower.ends_with(code):
				return true
		if (
			lower.begins_with("auto_connect_slab_bottom_")
			or lower.begins_with("auto_connect_slab_side_")
			or lower.begins_with("auto_connect_stairs_upsidedown_")
		):
			return true
	return (
		lower.begins_with("auto_slab_bottom_")
		or lower.begins_with("auto_slab_side_")
		or lower.begins_with("auto_panel_bottom_")
		or lower.begins_with("auto_panel_side_")
		or lower.begins_with("auto_stairs_upsidedown_")
	)

func _on_filter_toggled(tag: String, toggled: bool) -> void:
	if toggled:
		if not _active_filters.has(tag):
			_active_filters.append(tag)
	else:
		_active_filters.erase(tag)
	
	_refresh_inventory_display()

func _on_search_changed(text: String) -> void:
	_search_query = text.strip_edges().to_lower()
	_update_category_panel()
	_refresh_inventory_display()


func _clear_search() -> void:
	_search_query = ""
	if search_bar:
		search_bar.text = ""
	_update_category_panel()
	_refresh_inventory_display()


func _refresh_inventory_display() -> void:
	if not inventory_container or not item_button_scene:
		return

	_hide_variants_panel(false)

	# Buttons are freed here, so any hover they owned is stale.
	_property_hover_item.clear()

	for child in inventory_container.get_children():
		child.free()

	if not _search_query.is_empty():
		_display_search_results()
		_refresh_property_tab()
		return

	match _current_category:
		Category.BLOCKS:
			_add_palette_group()
			_add_block_groups()
		Category.PLACEABLES:
			_add_placeable_group()
		Category.SIMULATION, Category.AGENTS:
			pass

	_refresh_property_tab()


func _add_group(title: String, item_count: int = -1) -> GridContainer:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 4)

	var label := Label.new()
	var header: String = title.to_upper()
	if item_count >= 0:
		header += "  (%d)" % item_count

	label.text = header
	label.custom_minimum_size = Vector2(0.0, 24.0)
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.32))
	group.add_child(label)

	var rule := ColorRect.new()
	rule.color = Color(1.0, 0.84, 0.32, 0.28)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.add_child(rule)

	var grid := GridContainer.new()
	grid.columns = 6
	group.add_child(grid)
	inventory_container.add_child(group)

	return grid


func _add_block_button(
	parent: GridContainer,
	id: int,
	item_name: String,
	show_icon: bool = true,
	variants: Array = [],
	group_id: String = ""
) -> void:
	var icon: Texture2D = (
		_cached_mesh_library.get_item_preview(id)
		if show_icon and _cached_mesh_library
		else null
	)

	var btn = item_button_scene.instantiate()
	parent.add_child(btn)
	btn.setup(id, item_name, icon)
	btn.tooltip_text = "Block: %s" % _format_item_title(item_name)
	btn.item_selected.connect(_on_inventory_item_selected)
	btn.item_hovered.connect(_on_block_hovered)
	btn.item_unhovered.connect(_on_item_unhovered)
	if btn.has_method("set_variants"):
		btn.set_variants(group_id, variants.size() > 1)
	if variants.size() > 1:
		btn.variants_requested.connect(_on_block_variants_requested)


func _add_placeable_button(
	parent: GridContainer,
	index: int,
	display_name: String,
	show_icon: bool = true
) -> void:
	var icon: Texture2D = null
	if show_icon:
		icon = _get_scene_preview(placeable_scenes[index])

	var btn = item_button_scene.instantiate()
	parent.add_child(btn)
	btn.setup(index, display_name, icon, true, placeable_scenes[index])
	btn.tooltip_text = "Placeable: %s" % display_name
	btn.item_selected.connect(_on_placeable_item_selected)
	if btn.has_signal("item_hovered"):
		var hovered_scene: PackedScene = placeable_scenes[index]
		btn.item_hovered.connect(
			func(_id: int): _on_placeable_hovered(hovered_scene)
		)
		btn.item_unhovered.connect(
			func(_id: int): _on_placeable_unhovered(hovered_scene)
		)


## Inventory Blocks are listed as one entry per block group (one texture's
## normal block plus its slab/stair/panel variants). The material label is the
## section header; the plus badge opens the group's variant chooser.
func _add_block_groups() -> void:
	if not _cached_mesh_library:
		return

	var materials: Dictionary = _collect_block_groups()
	var material_names: Array = materials.keys()
	material_names.sort()

	for material_name: String in material_names:
		var material_groups: Dictionary = materials[material_name]
		var group_ids: Array = material_groups.keys()
		group_ids.sort_custom(
			func(a: String, b: String) -> bool:
				return _block_group_sort_key(material_groups, a) < _block_group_sort_key(material_groups, b)
		)

		var entries: Array = []
		for group_id: String in group_ids:
			var visible_variants: Array = []
			for entry: Dictionary in material_groups[group_id]:
				if _passes_active_filters(entry["tags"]):
					visible_variants.append(entry)
			if visible_variants.is_empty():
				continue
			var display: Dictionary = _display_variant_for(
				group_id,
				visible_variants
			)
			entries.append({
				"id": int(display["id"]),
				"name": String(display["name"]),
				"group_id": group_id,
				"variants": visible_variants,
			})

		if entries.is_empty():
			continue
		var grid := _add_group(material_name, entries.size())
		for entry: Dictionary in entries:
			_add_block_button(
				grid,
				int(entry["id"]),
				String(entry["name"]),
				true,
				entry["variants"],
				String(entry["group_id"])
			)


## material label -> block_group_id -> array of {id, name, tags}
func _collect_block_groups() -> Dictionary:
	var materials: Dictionary = {}
	if not _cached_mesh_library:
		return materials

	for id in _cached_build_items:
		var item_name: String = String(_cached_mesh_library.get_item_name(id))
		if _is_hidden_block_variant(item_name):
			continue

		var tags: Array[String] = _get_item_tags(item_name)
		var material_name: String = BlockMaterialsDB.material_label(item_name)
		if material_name.is_empty():
			material_name = (
				tags[tags.size() - 1] if not tags.is_empty() else "Other"
			)
		var group_id: String = BlockMaterialsDB.block_group_id(item_name)
		if group_id.is_empty():
			group_id = item_name

		if not materials.has(material_name):
			materials[material_name] = {}
		var material_groups: Dictionary = materials[material_name]
		if not material_groups.has(group_id):
			material_groups[group_id] = []
		material_groups[group_id].append({
			"id": id,
			"name": item_name,
			"tags": tags,
		})

	return materials


func _block_group_sort_key(material_groups: Dictionary, group_id: String) -> String:
	var variants: Array = material_groups.get(group_id, [])
	if variants.is_empty():
		return group_id
	return BlockMaterialsDB.block_group_label(String(variants[0]["name"]))


## The variant currently shown for a group. Falls back to the normal block and
## then to the first visible variant when the stored choice is filtered out.
func _display_variant_for(group_id: String, variants: Array) -> Dictionary:
	var chosen := int(_block_group_display.get(group_id, -1))
	for entry: Dictionary in variants:
		if int(entry["id"]) == chosen:
			return entry
	for entry: Dictionary in variants:
		if BlockMaterialsDB.variant_of(String(entry["name"])) == "block":
			return entry
	return variants[0]


func _visible_variants_for_group(group_id: String) -> Array:
	if not _cached_mesh_library:
		return []
	var color_indices := _group_color_indices(group_id)
	var selected_color := -1
	if not color_indices.is_empty():
		selected_color = int(
			_block_color_choice.get(group_id, color_indices[0])
		)
	var variants: Array = []
	for id in _cached_build_items:
		var item_name: String = String(_cached_mesh_library.get_item_name(id))
		if _is_hidden_block_variant(item_name):
			continue
		if BlockMaterialsDB.block_group_id(item_name) != group_id:
			continue
		if not color_indices.is_empty():
			if ColorPaletteDBScript.color_index(item_name) != selected_color:
				continue
		if not _passes_active_filters(_get_item_tags(item_name)):
			continue
		variants.append({"id": id, "name": item_name})
	variants.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return _variant_sort_index(String(a["name"])) < _variant_sort_index(String(b["name"]))
	)
	return variants


## Palette indices present for a colorbase group, in palette order.
func _group_color_indices(group_id: String) -> Array[int]:
	var result: Array[int] = []
	if not _cached_mesh_library:
		return result
	for id in _cached_build_items:
		var item_name: String = String(_cached_mesh_library.get_item_name(id))
		if BlockMaterialsDB.block_group_id(item_name) != group_id:
			continue
		var index := ColorPaletteDBScript.color_index(item_name)
		if index >= 0 and not result.has(index):
			result.append(index)
	result.sort()
	return result


## Renders the palette as colored squares at the bottom-right of the group
## chooser. Clicking one switches the displayed/selected variant color.
func _rebuild_color_swatches(group_id: String) -> void:
	if _variants_color_box == null:
		return
	for child in _variants_color_box.get_children():
		_variants_color_box.remove_child(child)
		child.queue_free()

	var indices := _group_color_indices(group_id)
	var show_colors := not indices.is_empty()
	_variants_color_box.visible = show_colors
	if _variants_color_label != null:
		_variants_color_label.visible = show_colors
	if not show_colors:
		return

	var selected := int(
		_block_color_choice.get(group_id, indices[0])
	)
	for index: int in indices:
		var color := ColorPaletteDBScript.color_at(index)
		var button := Button.new()
		button.custom_minimum_size = Vector2(18.0, 18.0)
		button.tooltip_text = "Color %d" % index
		button.focus_mode = Control.FOCUS_NONE

		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = (
			Color.WHITE if index == selected else Color(0.05, 0.05, 0.05, 1)
		)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)

		button.pressed.connect(
			_on_color_chosen.bind(group_id, index)
		)
		_variants_color_box.add_child(button)


func _on_color_chosen(group_id: String, color_index: int) -> void:
	_block_color_choice[group_id] = color_index

	# Make the group cell show the full block of that color. The chooser is
	# reopened below so the user can still pick slab/stairs.
	for id in _cached_build_items:
		var item_name: String = String(_cached_mesh_library.get_item_name(id))
		if BlockMaterialsDB.block_group_id(item_name) != group_id:
			continue
		if ColorPaletteDBScript.color_index(item_name) != color_index:
			continue
		if BlockMaterialsDB.variant_of(item_name) != "block":
			continue
		_block_group_display[group_id] = id
		break

	# The button that emitted `pressed` is still locked for this frame; rebuild
	# after the signal returns instead of freeing it inside the callback.
	call_deferred("_refresh_inventory_display")
	call_deferred("_show_block_variants", group_id)


func _variant_sort_index(item_name: String) -> int:
	return int(VARIANT_ORDER.get(BlockMaterialsDB.variant_of(item_name), 9))


func _ensure_variants_panel() -> void:
	if _variants_panel != null or inventory_panel == null:
		return

	_variants_panel = PixelPanelScript.new()
	_variants_panel.name = "BlockVariantsPanel"
	_variants_panel.visible = false
	_variants_panel.z_index = 80
	_variants_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	inventory_panel.add_child(_variants_panel)
	_configure_popup_drag_handle(_variants_panel, true)

	_variants_content = MarginContainer.new()
	_variants_content.name = "Content"
	_variants_content.mouse_filter = Control.MOUSE_FILTER_PASS
	var border := int(_variants_panel.get_border_pixels()) + 2
	_variants_content.add_theme_constant_override("margin_left", border)
	_variants_content.add_theme_constant_override("margin_top", border)
	_variants_content.add_theme_constant_override("margin_right", border)
	_variants_content.add_theme_constant_override("margin_bottom", border)
	_variants_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_variants_panel.add_child(_variants_content)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_theme_constant_override("separation", 6)
	_variants_content.add_child(box)

	_variants_title = Label.new()
	_variants_title.text = "Block Group"
	_variants_title.add_theme_font_size_override("font_size", 16)
	_variants_title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.32))
	box.add_child(_variants_title)
	_configure_popup_drag_handle(_variants_title, true)

	_variants_grid = GridContainer.new()
	_variants_grid.columns = 4
	_variants_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	_variants_grid.add_theme_constant_override("h_separation", 4)
	_variants_grid.add_theme_constant_override("v_separation", 4)
	box.add_child(_variants_grid)

	_variants_color_label = Label.new()
	_variants_color_label.text = "Color"
	_variants_color_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_variants_color_label.add_theme_font_size_override("font_size", 12)
	_variants_color_label.add_theme_color_override(
		"font_color",
		Color(0.78, 0.78, 0.74, 1.0)
	)
	_variants_color_label.visible = false
	box.add_child(_variants_color_label)

	_variants_color_box = GridContainer.new()
	_variants_color_box.columns = 8
	_variants_color_box.size_flags_horizontal = Control.SIZE_SHRINK_END
	_variants_color_box.add_theme_constant_override("h_separation", 2)
	_variants_color_box.add_theme_constant_override("v_separation", 2)
	_variants_color_box.visible = false
	box.add_child(_variants_color_box)


func _on_block_variants_requested(
	_item_id: int,
	group_id: String,
	anchor_rect: Rect2
) -> void:
	if group_id.is_empty():
		return
	if (
		_variants_panel != null
		and _variants_panel.visible
		and _variants_group_id == group_id
	):
		_hide_variants_panel()
		return
	_show_block_variants(group_id, anchor_rect)


func _show_block_variants(
	group_id: String,
	anchor_rect: Rect2 = Rect2()
) -> void:
	var variants := _visible_variants_for_group(group_id)
	if variants.size() <= 1:
		return
	_hide_palettes_panel(false)
	_ensure_variants_panel()
	if _variants_panel == null:
		return

	for child in _variants_grid.get_children():
		_variants_grid.remove_child(child)
		child.queue_free()

	_variants_group_id = group_id
	_variants_title.text = BlockMaterialsDB.block_group_label(
		String(variants[0]["name"])
	)
	var displayed := _display_variant_for(group_id, variants)
	var displayed_id := int(displayed["id"])
	for entry: Dictionary in variants:
		_add_variant_cell(
			group_id,
			entry,
			int(entry["id"]) == displayed_id
		)
	_rebuild_color_swatches(group_id)

	_variants_panel.visible = true
	_set_variants_badge_open(group_id)
	_position_variants_panel(anchor_rect)


## Puts the chooser at the bottom-right of the plus badge, flipping to the
## left/top when it would leave the inventory panel. A player-moved chooser
## keeps its remembered inventory-local position instead.
func _position_variants_panel(anchor_rect: Rect2) -> void:
	var panel_size := _variants_content.get_combined_minimum_size()
	_variants_panel.size = panel_size

	if _variants_user_moved:
		_variants_panel.position = _clamp_popup_position(
			_variants_panel,
			_variants_user_position
		)
		return

	var local_end: Vector2 = inventory_panel.get_local_mouse_position()
	if anchor_rect.size != Vector2.ZERO:
		local_end = (
			inventory_panel.get_global_transform().affine_inverse()
			* anchor_rect.end
		)

	var bounds := _inventory_local_bounds()
	var panel_position := local_end + Vector2(4.0, 4.0)
	if panel_position.x + panel_size.x > bounds.end.x - 8.0:
		panel_position.x = local_end.x - panel_size.x - 4.0
	if panel_position.y + panel_size.y > bounds.end.y - 8.0:
		panel_position.y = local_end.y - panel_size.y - 4.0

	_variants_panel.position = _clamp_popup_position(
		_variants_panel,
		panel_position
	)


## Keeps a floating popup fully inside the authored inventory background.
func _clamp_popup_position(panel: Control, desired: Vector2) -> Vector2:
	var bounds := _inventory_local_bounds()
	var panel_size: Vector2 = panel.size
	var min_x := bounds.position.x + 8.0
	var min_y := bounds.position.y + 8.0
	return Vector2(
		clampf(
			desired.x,
			min_x,
			maxf(min_x, bounds.end.x - panel_size.x - 8.0)
		),
		clampf(
			desired.y,
			min_y,
			maxf(min_y, bounds.end.y - panel_size.y - 8.0)
		)
	)


## Makes a title/grip control drag its popup. The popup stays a child of the
## inventory, so a remembered position still travels with the inventory.
func _configure_popup_drag_handle(handle: Control, is_variants: bool) -> void:
	if handle == null:
		return
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = Control.CURSOR_DRAG
	if handle.tooltip_text.is_empty():
		handle.tooltip_text = "Drag to move"
	if not handle.gui_input.is_connected(_on_popup_drag_input):
		handle.gui_input.connect(_on_popup_drag_input.bind(is_variants))


func _on_popup_drag_input(event: InputEvent, is_variants: bool) -> void:
	var panel: Control = _variants_panel if is_variants else _palettes_panel
	if panel == null or not panel.visible:
		return

	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse_button.pressed:
			_popup_drag_target = panel
			_popup_drag_moved = false
			get_viewport().set_input_as_handled()
		elif _popup_drag_target == panel:
			_popup_drag_target = null
			get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion and _popup_drag_target == panel:
		var motion := event as InputEventMouseMotion
		var delta := motion.relative
		if not _popup_drag_moved and delta.length_squared() < 1.0:
			return
		_popup_drag_moved = true
		var new_position := panel.position + delta
		panel.position = new_position
		if is_variants:
			_variants_user_moved = true
			_variants_user_position = new_position
		else:
			_palettes_user_moved = true
			_palettes_user_position = new_position
		get_viewport().set_input_as_handled()


## The Inventory root is a zero-size anchor; its visible area comes from the
## authored background sprite. Use that rect for popup clamping.
func _inventory_local_bounds() -> Rect2:
	var background := inventory_panel.get_node_or_null("InventoryBgMain") as Sprite2D
	if background != null and background.texture != null:
		var background_size := background.texture.get_size() * background.scale
		return Rect2(background.position - background_size * 0.5, background_size)
	return Rect2(Vector2(-224.0, -146.0), Vector2(448.0, 296.0))


func _set_variants_badge_open(group_id: String) -> void:
	for node in inventory_container.find_children("*", "", true, false):
		if not node.has_method("set_variants_open"):
			continue
		node.set_variants_open(
			not group_id.is_empty()
			and String(node.get("block_group_id")) == group_id
		)


func _add_variant_cell(
	group_id: String,
	entry: Dictionary,
	selected: bool
) -> void:
	var cell := VBoxContainer.new()
	cell.custom_minimum_size = Vector2(62.0, 0.0)
	cell.add_theme_constant_override("separation", 2)
	_variants_grid.add_child(cell)

	var item_id := int(entry["id"])
	var item_name := String(entry["name"])
	var button: Control = BlockVariantSlot.new()
	cell.add_child(button)

	var icon: Texture2D = (
		_cached_mesh_library.get_item_preview(item_id)
		if _cached_mesh_library
		else null
	)
	button.setup(item_id, _format_item_title(item_name), icon, selected)
	button.variant_selected.connect(
		func(_id: int) -> void: _on_variant_chosen(group_id, item_id)
	)
	button.variant_hovered.connect(_on_block_hovered)
	button.variant_unhovered.connect(_on_item_unhovered)

	var caption := Label.new()
	caption.text = BlockMaterialsDB.variant_label(item_name)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 16)
	caption.add_theme_color_override("font_color", Color(0.82, 0.82, 0.82))
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(caption)


func _on_variant_chosen(group_id: String, item_id: int) -> void:
	_block_group_display[group_id] = item_id
	_hide_variants_panel(false)
	_refresh_inventory_display()

	# Clicking a shape is also a pick: run the same path as clicking the group
	# cell itself, so the chosen block/slab/stairs lands in the active hotbar
	# slot and the held item follows it. The color swatches keep their existing
	# display-only behaviour.
	_on_inventory_item_selected(item_id)


func _hide_variants_panel(refresh_property: bool = true) -> void:
	if _variants_panel != null:
		_variants_panel.visible = false
	_variants_group_id = ""
	_set_variants_badge_open("")
	if refresh_property:
		_property_hover_item.clear()
		_refresh_property_tab()


# ---------------------------------------------------------------------------
# Block / placeable palettes
# ---------------------------------------------------------------------------

## Palettes live at the very top of the Blocks category. The first cell is the
## blank new-palette cell: the normal palette texture modulated black with a
## centred group_plus overlay. Existing palette cells use the normal icon.
func _add_palette_group() -> void:
	if _palette_store == null:
		return

	var palettes: Array = _palette_store.palettes
	var grid := _add_group("Palettes", palettes.size())

	# Blank "new palette" cell first, then the player's palettes.
	var add_cell = item_button_scene.instantiate()
	grid.add_child(add_cell)
	add_cell.setup(-1, "New Palette", PALETTE_BLANK_ICON, false)
	add_cell.tooltip_text = "New palette"
	add_cell.item_selected.connect(func(_id: int) -> void: _on_new_palette_pressed())

	for palette: Dictionary in palettes:
		var palette_id := String(palette.get("id", ""))
		var palette_name := String(palette.get("name", "Palette"))
		var cell = item_button_scene.instantiate()
		grid.add_child(cell)
		cell.setup(-1, palette_name, PALETTE_ICON, true)
		cell.tooltip_text = "Palette: %s (click to open)" % palette_name
		cell.set_palette(palette_id)
		if cell.label != null:
			cell.label.visible = true
			cell.label.text = palette_name
			cell.label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cell.label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			cell.label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			cell.label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.label.add_theme_font_size_override("font_size", 12)
			cell.label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
			cell.label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
			cell.label.add_theme_constant_override("outline_size", 4)
			cell.label.offset_left = -26.0
			cell.label.offset_top = -24.0
			cell.label.offset_right = 26.0
			cell.label.offset_bottom = 24.0
		cell.palette_requested.connect(_on_palette_requested)
		cell.item_selected.connect(
			func(_id: int) -> void: _on_palette_selected(palette_id)
		)
		if (
			_palettes_panel != null
			and _palettes_panel.visible
			and _palettes_current_id == palette_id
		):
			cell.set_variants_open(true)


func _on_new_palette_pressed() -> void:
	if _palette_store == null:
		return
	var palette := _palette_store.add_palette()
	if palette.is_empty():
		return
	_refresh_inventory_display.call_deferred()
	_show_palette(String(palette.get("id", "")))


func _ensure_palettes_panel() -> void:
	if _palettes_panel != null or inventory_panel == null:
		return

	_palettes_panel = PixelPanelScript.new()
	_palettes_panel.name = "PalettesPanel"
	_palettes_panel.pixel_scale = 1.5
	_palettes_panel.visible = false
	_palettes_panel.z_index = 81
	_palettes_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	inventory_panel.add_child(_palettes_panel)
	_configure_popup_drag_handle(_palettes_panel, false)

	_palettes_content = MarginContainer.new()
	_palettes_content.name = "Content"
	_palettes_content.mouse_filter = Control.MOUSE_FILTER_PASS
	var border := int(_palettes_panel.get_border_pixels()) + 2
	_palettes_content.add_theme_constant_override("margin_left", border)
	_palettes_content.add_theme_constant_override("margin_top", border)
	_palettes_content.add_theme_constant_override("margin_right", border)
	_palettes_content.add_theme_constant_override("margin_bottom", border)
	_palettes_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_palettes_panel.add_child(_palettes_content)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_theme_constant_override("separation", 5)
	_palettes_content.add_child(box)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	box.add_child(name_row)

	var drag_grip := Label.new()
	drag_grip.text = "::"
	drag_grip.tooltip_text = "Drag to move"
	drag_grip.custom_minimum_size = Vector2(18.0, 26.0)
	drag_grip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	drag_grip.add_theme_font_size_override("font_size", 16)
	drag_grip.add_theme_color_override("font_color", Color(1.0, 0.84, 0.32))
	name_row.add_child(drag_grip)
	_configure_popup_drag_handle(drag_grip, false)

	_palettes_name = LineEdit.new()
	_palettes_name.placeholder_text = "Palette name"
	_palettes_name.max_length = 24
	_palettes_name.custom_minimum_size = Vector2(0.0, 26.0)
	_palettes_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palettes_name.add_theme_font_size_override("font_size", 16)
	var name_style := StyleBoxFlat.new()
	name_style.bg_color = Color(0.06, 0.06, 0.09, 0.95)
	name_style.border_color = Color(1.0, 0.84, 0.32, 0.55)
	name_style.set_border_width_all(1)
	name_style.content_margin_left = 4.0
	name_style.content_margin_right = 4.0
	_palettes_name.add_theme_stylebox_override("normal", name_style)
	_palettes_name.add_theme_stylebox_override("focus", name_style)
	_palettes_name.text_submitted.connect(_on_palette_name_submitted)
	_palettes_name.focus_exited.connect(_commit_palette_name)
	name_row.add_child(_palettes_name)

	var delete_button := Button.new()
	delete_button.text = "Del"
	delete_button.tooltip_text = "Delete palette"
	delete_button.custom_minimum_size = Vector2(34.0, 26.0)
	delete_button.add_theme_font_size_override("font_size", 16)
	delete_button.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	delete_button.pressed.connect(_on_palette_delete_pressed)
	name_row.add_child(delete_button)

	var close_button := Button.new()
	close_button.text = "X"
	close_button.tooltip_text = "Close palette"
	close_button.custom_minimum_size = Vector2(24.0, 26.0)
	close_button.add_theme_font_size_override("font_size", 16)
	close_button.pressed.connect(_hide_palettes_panel)
	name_row.add_child(close_button)

	_palettes_grid = GridContainer.new()
	_palettes_grid.columns = 3
	_palettes_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	_palettes_grid.add_theme_constant_override("h_separation", 4)
	_palettes_grid.add_theme_constant_override("v_separation", 4)
	box.add_child(_palettes_grid)

	_palettes_slots.clear()
	for slot_index in PaletteStoreScript.SLOT_COUNT:
		var slot = PaletteSlotScript.new()
		slot.icon_provider = _palette_slot_icon
		slot.setup(slot_index)
		slot.slot_changed.connect(_on_palette_slot_changed)
		_palettes_grid.add_child(slot)
		_palettes_slots.append(slot)


func _on_palette_requested(palette_id: String, anchor_rect: Rect2) -> void:
	_palette_badge_msec = Time.get_ticks_msec()
	if (
		_palettes_panel != null
		and _palettes_panel.visible
		and _palettes_current_id == palette_id
	):
		_hide_palettes_panel()
		return
	_show_palette(palette_id, anchor_rect)


func _on_palette_selected(palette_id: String) -> void:
	# The plus badge sits on top of the cell; ignore the cell press that can
	# follow the badge press in the same click.
	if Time.get_ticks_msec() - _palette_badge_msec < 250:
		return
	if (
		_palettes_panel != null
		and _palettes_panel.visible
		and _palettes_current_id == palette_id
	):
		_hide_palettes_panel()
		return
	_show_palette(palette_id)


func _show_palette(palette_id: String, anchor_rect: Rect2 = Rect2()) -> void:
	if _palette_store == null:
		return
	var palette := _palette_store.get_palette(palette_id)
	if palette.is_empty():
		return
	_ensure_palettes_panel()
	if _palettes_panel == null:
		return

	_hide_variants_panel(false)
	_palettes_current_id = palette_id
	_palettes_name.text = String(palette.get("name", "Palette"))
	_refresh_palette_slots()
	_palettes_panel.visible = true
	_set_palette_badge_open(palette_id)
	_position_palettes_panel(anchor_rect)


func _hide_palettes_panel(refresh_property: bool = true) -> void:
	if _palettes_panel != null:
		_palettes_panel.visible = false
	_palettes_current_id = ""
	_set_palette_badge_open("")
	if refresh_property:
		_property_hover_item.clear()
		_refresh_property_tab()


func _position_palettes_panel(anchor_rect: Rect2) -> void:
	var panel_size := _palettes_content.get_combined_minimum_size()
	_palettes_panel.size = panel_size

	if _palettes_user_moved:
		_palettes_panel.position = _clamp_popup_position(
			_palettes_panel,
			_palettes_user_position
		)
		return

	var local_end: Vector2 = inventory_panel.get_local_mouse_position()
	if anchor_rect.size != Vector2.ZERO:
		local_end = (
			inventory_panel.get_global_transform().affine_inverse()
			* anchor_rect.end
		)

	var bounds := _inventory_local_bounds()
	var panel_position := local_end + Vector2(4.0, 4.0)
	if panel_position.x + panel_size.x > bounds.end.x - 8.0:
		panel_position.x = local_end.x - panel_size.x - 4.0
	if panel_position.y + panel_size.y > bounds.end.y - 8.0:
		panel_position.y = local_end.y - panel_size.y - 4.0

	_palettes_panel.position = _clamp_popup_position(
		_palettes_panel,
		panel_position
	)


func _refresh_palette_slots() -> void:
	if _palette_store == null or _palettes_slots.is_empty():
		return
	for slot_index in _palettes_slots.size():
		var slot_data := _palette_store.get_slot(_palettes_current_id, slot_index)
		var resolved := _resolve_palette_slot(slot_data)
		_palettes_slots[slot_index].set_item(resolved)


func _on_palette_slot_changed(slot_index: int, slot_data: Dictionary) -> void:
	if _palette_store == null or _palettes_current_id.is_empty():
		return
	var normalized := _normalize_palette_slot(slot_data)
	_palette_store.set_slot(_palettes_current_id, slot_index, normalized)
	if slot_index >= 0 and slot_index < _palettes_slots.size():
		_palettes_slots[slot_index].set_item(
			_resolve_palette_slot(_palette_store.get_slot(_palettes_current_id, slot_index))
		)


func _normalize_palette_slot(slot_data: Dictionary) -> Dictionary:
	if slot_data.is_empty():
		return {}
	if String(slot_data.get("kind", "")) == "block":
		var item_id := int(slot_data.get("item_id", -1))
		var item_name := String(slot_data.get("item_name", slot_data.get("name", "")))
		if _cached_mesh_library != null and _cached_build_items.has(item_id):
			item_name = String(_cached_mesh_library.get_item_name(item_id))
		if item_name.is_empty():
			return {}
		return {
			"kind": "block",
			"item_id": item_id,
			"item_name": item_name,
			"display_name": _format_item_title(item_name),
			"preview": slot_data.get("preview"),
		}

	if String(slot_data.get("kind", "")) == "placeable":
		var scene_path := String(slot_data.get("scene_path", ""))
		if scene_path.is_empty():
			var scene: Variant = slot_data.get("scene")
			if scene is PackedScene:
				scene_path = (scene as PackedScene).resource_path
		if scene_path.is_empty():
			return {}
		var display := String(slot_data.get("display_name", slot_data.get("item_name", "")))
		if ResourceLoader.exists(scene_path):
			var scene := load(scene_path) as PackedScene
			if scene != null:
				display = _placeable_display_name(scene)
		if display.is_empty():
			display = scene_path.get_file().get_basename().capitalize()
		return {
			"kind": "placeable",
			"scene_path": scene_path,
			"item_name": display,
			"display_name": display,
			"preview": slot_data.get("preview"),
		}

	return {}


## Rebuilds a persisted slot with runtime-only fields (preview, display name)
## and repairs block ids from the stored item name.
func _resolve_palette_slot(slot_data: Dictionary) -> Dictionary:
	if slot_data.is_empty():
		return {}

	if String(slot_data.get("kind", "")) == "block":
		var item_id := int(slot_data.get("item_id", -1))
		var item_name := String(slot_data.get("item_name", ""))
		if _cached_mesh_library != null:
			if (
				not _cached_build_items.has(item_id)
				or (
					not item_name.is_empty()
					and String(_cached_mesh_library.get_item_name(item_id)) != item_name
				)
			):
				item_id = _mesh_id_for_name(item_name)
			if _cached_build_items.has(item_id):
				item_name = String(_cached_mesh_library.get_item_name(item_id))
		if item_name.is_empty():
			return {}
		var preview: Texture2D = null
		if _cached_mesh_library != null and _cached_build_items.has(item_id):
			preview = _cached_mesh_library.get_item_preview(item_id)
		return {
			"kind": "block",
			"item_id": item_id,
			"item_name": item_name,
			"display_name": _format_item_title(item_name),
			"preview": preview,
		}

	if String(slot_data.get("kind", "")) == "placeable":
		var scene_path := String(slot_data.get("scene_path", ""))
		var display := String(slot_data.get("item_name", ""))
		var preview: Texture2D = null
		if not scene_path.is_empty() and ResourceLoader.exists(scene_path):
			var scene := load(scene_path) as PackedScene
			if scene != null:
				display = _placeable_display_name(scene)
				preview = _get_scene_preview(scene)
		if display.is_empty():
			display = scene_path.get_file().get_basename().capitalize()
		return {
			"kind": "placeable",
			"scene_path": scene_path,
			"item_name": display,
			"display_name": display,
			"preview": preview,
		}

	return {}


func _palette_slot_icon(slot_data: Dictionary) -> Texture2D:
	var resolved := _resolve_palette_slot(slot_data)
	var preview: Variant = resolved.get("preview")
	if preview is Texture2D:
		return preview as Texture2D
	return null


func _mesh_id_for_name(item_name: String) -> int:
	if _cached_mesh_library == null or item_name.is_empty():
		return -1
	for item_id in _cached_build_items:
		if String(_cached_mesh_library.get_item_name(item_id)) == item_name:
			return item_id
	return -1


func _on_palette_name_submitted(text: String) -> void:
	_apply_palette_name(text)
	if _palettes_name != null:
		_palettes_name.release_focus()


func _commit_palette_name() -> void:
	if _palettes_name == null or _palettes_current_id.is_empty():
		return
	_apply_palette_name(_palettes_name.text)


func _apply_palette_name(text: String) -> void:
	if _palette_store == null or _palettes_current_id.is_empty():
		return
	var trimmed := text.strip_edges()
	var palette := _palette_store.get_palette(_palettes_current_id)
	if palette.is_empty():
		return
	if trimmed.is_empty():
		_palettes_name.text = String(palette.get("name", "Palette"))
		return
	if trimmed == String(palette.get("name", "")):
		return

	_palette_store.set_palette_name(_palettes_current_id, trimmed)
	_palettes_name.text = trimmed
	if _current_category == Category.BLOCKS:
		_refresh_inventory_display.call_deferred()


## Delete the open palette after a confirmation, and clear any hotbar slot that
## still points at it.
func _on_palette_delete_pressed() -> void:
	if _palette_store == null or _palettes_current_id.is_empty():
		return
	var palette := _palette_store.get_palette(_palettes_current_id)
	if palette.is_empty():
		return

	var palette_id := _palettes_current_id
	var palette_name := String(palette.get("name", "Palette"))

	if is_instance_valid(_palette_delete_dialog):
		_palette_delete_dialog.queue_free()
		_palette_delete_dialog = null

	var dialog := ConfirmationDialog.new()
	dialog.name = "DeletePaletteDialog"
	dialog.title = "Delete Palette"
	dialog.dialog_text = "Delete \"%s\"? This cannot be undone." % palette_name
	dialog.ok_button_text = "Delete"
	dialog.cancel_button_text = "Cancel"
	dialog.min_size = Vector2i(360, 140)
	dialog.get_ok_button().add_theme_font_size_override("font_size", 16)
	dialog.get_cancel_button().add_theme_font_size_override("font_size", 16)
	var label := dialog.get_label()
	if label != null:
		label.add_theme_font_size_override("font_size", 16)
	dialog.confirmed.connect(func() -> void:
		_delete_palette(palette_id)
		if is_instance_valid(dialog):
			dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void:
		if is_instance_valid(dialog):
			dialog.queue_free()
	)
	dialog.close_requested.connect(func() -> void:
		if is_instance_valid(dialog):
			dialog.queue_free()
	)
	_palette_delete_dialog = dialog
	add_child(dialog)
	dialog.popup_centered()


func _delete_palette(palette_id: String) -> void:
	if _palette_store == null:
		return
	var palette := _palette_store.get_palette(palette_id)
	if palette.is_empty():
		return
	var palette_name := String(palette.get("name", "Palette"))

	_palette_store.remove_palette(palette_id)
	_palette_store.save_to_disk()
	_clear_hotbar_palette(palette_id)
	if _palettes_current_id == palette_id:
		_hide_palettes_panel()
	if _current_category == Category.BLOCKS:
		_refresh_inventory_display()
	show_build_label("Palette deleted: %s" % palette_name)


func _clear_hotbar_palette(palette_id: String) -> void:
	if hotbar == null:
		return
	for index in Hotbar.SLOT_COUNT:
		if hotbar.get_slot_palette(index) == palette_id:
			hotbar.set_slot_item(index, -1)


func _set_palette_badge_open(palette_id: String) -> void:
	if inventory_container == null:
		return
	for node in inventory_container.find_children("*", "", true, false):
		if not node.has_method("set_variants_open") or not node.has_method("set_palette"):
			continue
		node.set_variants_open(
			not palette_id.is_empty()
			and String(node.get("palette_id")) == palette_id
		)


func _add_placeable_group() -> void:
	var groups: Dictionary = {}

	for index in placeable_scenes.size():
		var scene: PackedScene = placeable_scenes[index]
		if not scene:
			continue

		var placeable_class := _placeable_class(scene)
		if not _passes_active_filters([placeable_class]):
			continue

		if not groups.has(placeable_class):
			groups[placeable_class] = []
		groups[placeable_class].append(index)

	var class_names: Array = []
	for preferred: String in ["Sim", "Device", "Foliage", "Other"]:
		if groups.has(preferred):
			class_names.append(preferred)
	for extra: Variant in groups.keys():
		if not class_names.has(extra):
			class_names.append(extra)

	for placeable_class: String in class_names:
		var grid := _add_group(
			placeable_class,
			groups[placeable_class].size()
		)
		for index: int in groups[placeable_class]:
			_add_placeable_button(
				grid,
				index,
				_placeable_display_name(placeable_scenes[index])
			)


## Placeables are grouped by their filename prefix. Add new class prefixes
## here (and a matching folder under scenes/placeables/) to extend the catalog.
func _placeable_class(scene: PackedScene) -> String:
	if scene == null:
		return "Other"

	var base := scene.resource_path.get_file().get_basename().to_lower()

	if base.begins_with("sim_"):
		return "Sim"
	if base.begins_with("device_"):
		return "Device"
	if base.begins_with("foliage_") or base.begins_with("foilage_"):
		return "Foliage"

	return "Other"


## Strips the class prefix for the inventory label, e.g. sim_spawner -> Spawner.
func _placeable_display_name(scene: PackedScene) -> String:
	if scene == null:
		return ""

	var base := scene.resource_path.get_file().get_basename()
	var lower := base.to_lower()

	for prefix in ["sim_", "device_", "foliage_", "foilage_"]:
		if lower.begins_with(prefix):
			base = base.substr(prefix.length())
			break

	return base.capitalize()


func _display_search_results() -> void:
	var block_matches: Array[Dictionary] = []
	var placeable_matches: Array[Dictionary] = []

	if _cached_mesh_library:
		var materials: Dictionary = _collect_block_groups()
		for material_name: String in materials:
			var material_groups: Dictionary = materials[material_name]
			for group_id: String in material_groups:
				var variants: Array = []
				for entry: Dictionary in material_groups[group_id]:
					if _passes_active_filters(entry["tags"]):
						variants.append(entry)
				if variants.is_empty():
					continue
				if not _block_group_matches_search(
					group_id,
					material_name,
					variants
				):
					continue
				var display: Dictionary = _display_variant_for(
					group_id,
					variants
				)
				block_matches.append({
					"id": int(display["id"]),
					"name": String(display["name"]),
					"group_id": group_id,
					"variants": variants,
				})

	block_matches.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return (
				BlockMaterialsDB.block_group_label(String(a["name"]))
				< BlockMaterialsDB.block_group_label(String(b["name"]))
			)
	)

	for index in placeable_scenes.size():
		var scene: PackedScene = placeable_scenes[index]
		if not scene:
			continue
		var display_name: String = _placeable_display_name(scene)
		var placeable_class: String = _placeable_class(scene)
		if (
			_matches_search(display_name)
			or _matches_search(placeable_class)
		):
			placeable_matches.append({
				"index": index,
				"name": display_name,
			})

	if block_matches.is_empty() and placeable_matches.is_empty():
		_add_group("No items found")
		return

	if not block_matches.is_empty():
		var block_grid := _add_group("Blocks (%d)" % block_matches.size())
		for entry: Dictionary in block_matches:
			var clean_name := BlockMaterialsDB.block_group_label(
				String(entry["name"])
			)
			_add_block_button(
				block_grid,
				int(entry["id"]),
				clean_name,
				false,
				entry["variants"],
				String(entry["group_id"])
			)
			_style_search_label(
				block_grid.get_child(block_grid.get_child_count() - 1),
				clean_name
			)

	if not placeable_matches.is_empty():
		var placeable_grid := _add_group("Placeables (%d)" % placeable_matches.size())
		for entry: Dictionary in placeable_matches:
			_add_placeable_button(
				placeable_grid,
				int(entry["index"]),
				String(entry["name"]),
				false
			)
			_style_search_label(
				placeable_grid.get_child(placeable_grid.get_child_count() - 1),
				String(entry["name"])
			)


## Search results are ordinary inventory cells with their built-in label on.
## This keeps the clean display name readable instead of building a custom
## icon-plus-caption cell.
func _style_search_label(cell: Control, clean_name: String) -> void:
	if cell == null:
		return
	var label: Label = cell.get("label")
	if label == null:
		return
	label.visible = true
	label.text = clean_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
	label.add_theme_constant_override("outline_size", 3)
	label.offset_left = -28.0
	label.offset_top = -28.0
	label.offset_right = 28.0
	label.offset_bottom = 28.0

	cell.tooltip_text = clean_name


func _block_group_matches_search(
	group_id: String,
	material_name: String,
	variants: Array
) -> bool:
	if variants.is_empty():
		return false
	if _matches_search(BlockMaterialsDB.block_group_label(String(variants[0]["name"]))):
		return true
	if _matches_search(material_name) or _matches_search(group_id):
		return true
	for entry: Dictionary in variants:
		var item_name := String(entry["name"])
		if _matches_search(item_name) or _matches_search(_format_item_title(item_name)):
			return true
	return false


func _matches_search(text: String) -> bool:
	if _search_query.is_empty():
		return true
	if text.to_lower().contains(_search_query):
		return true

	for tag: String in _get_item_tags(text):
		if tag.to_lower().contains(_search_query):
			return true

	return false


func _passes_active_filters(tags: Array[String]) -> bool:
	for tag: String in tags:
		if not _active_filters.has(tag):
			return false
	return true


func _get_scene_preview(scene: PackedScene) -> Texture2D:
	if scene == null:
		return null

	var key := scene.resource_path
	if key.is_empty():
		key = str(scene)
	if _scene_preview_cache.has(key):
		return _scene_preview_cache[key]

	# Prefer a generated voxel item icon for non-block placeables.
	var voxel_icon: Texture2D = VoxelItemDB.icon_for_scene(scene)
	if voxel_icon != null:
		_scene_preview_cache[key] = voxel_icon
		return voxel_icon

	var temp: Node = scene.instantiate()
	var icon: Texture2D = null
	var sprite = _find_child_by_type(temp, [Sprite2D, Sprite3D])
	if sprite:
		if sprite is Sprite2D and sprite.texture:
			icon = sprite.texture
		elif sprite is Sprite3D and sprite.texture:
			icon = sprite.texture
	temp.free()
	_scene_preview_cache[key] = icon
	return icon


## Public accessor for the placeable folder preview pipeline.
func get_scene_preview(scene: PackedScene) -> Texture2D:
	return _get_scene_preview(scene)

func _find_child_by_type(node: Node, types: Array) -> Node:
	for type in types:
		if is_instance_of(node, type):
			return node
	for child in node.get_children():
		var found = _find_child_by_type(child, types)
		if found:
			return found
	return null

func _on_category_pressed(category: Category) -> void:
	if _current_category == category:
		if not _search_query.is_empty():
			_clear_search()
		return

	_current_category = category
	_hide_variants_panel(false)

	if not _search_query.is_empty():
		_search_query = ""
		if search_bar:
			search_bar.text = ""
	
	if blocks_button:
		blocks_button.button_pressed = (_current_category == Category.BLOCKS)
	if placeables_button:
		placeables_button.button_pressed = (_current_category == Category.PLACEABLES)
	if simulation_button:
		simulation_button.button_pressed = (_current_category == Category.SIMULATION)
	if agents_button:
		agents_button.button_pressed = (_current_category == Category.AGENTS)

	# Export rows belong to the Property tab and follow the pinned/hovered item,
	# not the inventory category.
	_refresh_filters()
	_refresh_inventory_display()
	_update_category_arrow()
	_update_category_panel()

func _update_category_arrow() -> void:
	if not category_arrow:
		return
		
	var target_button: Button = null
	match _current_category:
		Category.BLOCKS:
			target_button = blocks_button
		Category.PLACEABLES:
			target_button = placeables_button
		Category.SIMULATION:
			target_button = simulation_button
		Category.AGENTS:
			target_button = agents_button
			
	if target_button:
		var arrow_width = 0.0
		if category_arrow.texture:
			arrow_width = category_arrow.texture.get_width() * category_arrow.scale.x
			
		category_arrow.global_position.x = target_button.global_position.x - arrow_width + arrow_x_offset
		category_arrow.global_position.y = target_button.global_position.y + (target_button.size.y / 2.0) + arrow_y_offset

func _update_category_panel() -> void:
	var searching: bool = not _search_query.is_empty()
	var simulation_selected: bool = (
		_current_category == Category.SIMULATION and not searching
	)
	var agents_selected: bool = (
		_current_category == Category.AGENTS and not searching
	)

	if simulation_panel:
		simulation_panel.visible = simulation_selected
		if simulation_selected:
			simulation_panel.call("_sync_from_state")

	if agent_panel:
		agent_panel.visible = agents_selected
		if agents_selected:
			agent_panel.call("_sync_from_state")

	var content := get_node_or_null("Inventory/ContentScroll")
	if content:
		content.visible = not simulation_selected and not agents_selected

	var filters := get_node_or_null("Inventory/ItemFilters")
	if filters:
		filters.visible = (
			not simulation_selected
			and not agents_selected
			and not searching
		)

	# The property sheet follows hover/pinned items independently of category.
	_refresh_property_tab()

## General-purpose build message. Starts a hold timer, then fades the label.
func show_build_label(
	text: String,
	hold: float = BUILD_LABEL_HOLD,
	fade: float = BUILD_LABEL_FADE
) -> void:
	if build_ui_label == null:
		return
	build_ui_label.text = text
	build_ui_label.visible = true
	build_ui_label.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_build_label_hold_left = maxf(hold, 0.0)
	_build_label_fade_left = maxf(fade, 0.0)
	_build_label_fade_duration = maxf(fade, 0.001)
	_build_label_fading = false


## Build-mode notices (such as the axis change) use the same transient label.
func show_build_notice(text: String) -> void:
	if not _build_mode_active:
		return
	show_build_label(text)


func _update_build_label(delta: float) -> void:
	if build_ui_label == null or not build_ui_label.visible:
		return

	var remaining := delta
	if _build_label_hold_left > 0.0:
		var consumed := minf(_build_label_hold_left, remaining)
		_build_label_hold_left -= consumed
		remaining -= consumed
		if _build_label_hold_left > 0.0:
			return
		_build_label_fading = true

	if not _build_label_fading:
		return

	_build_label_fade_left = maxf(_build_label_fade_left - remaining, 0.0)
	var alpha := _build_label_fade_left / _build_label_fade_duration
	build_ui_label.modulate.a = clampf(alpha, 0.0, 1.0)
	if _build_label_fade_left <= 0.0:
		build_ui_label.visible = false
		_build_label_fading = false


func update_build_ui(build_mode_active: bool, inventory_open: bool, current_item_name: String = "") -> void:
	var should_show_inventory = build_mode_active and inventory_open
	
	if inventory_panel:
		inventory_panel.visible = should_show_inventory
		if should_show_inventory:
			_update_category_arrow.call_deferred()
			_update_category_panel.call_deferred()
		else:
			if (
				_displayed_placeable_scene == _selected_placeable_scene
				and _selected_placeable_scene != null
			):
				_selected_placeable_overrides = get_placeable_overrides()
			_property_hover_item.clear()
			_hide_property_tab()

	if hotbar:
		# Stay visible while the inventory is open so blocks can be dragged
		# straight from the inventory onto a slot.
		hotbar.visible = build_mode_active

	var was_build_mode_active := _build_mode_active
	_build_mode_active = build_mode_active
	if build_ui_label:
		if not build_mode_active:
			build_ui_label.visible = false
			_build_label_hold_left = 0.0
			_build_label_fading = false
		else:
			var display_name := "None"
			if current_item_name != "":
				display_name = _format_item_title(current_item_name)
			if (
				display_name != _last_build_label_text
				or not was_build_mode_active
			):
				_last_build_label_text = display_name
				show_build_label(display_name)

	if should_show_inventory != _last_inventory_visible:
		_last_inventory_visible = should_show_inventory
		
		var player = get_tree().get_first_node_in_group("player")
		
		if should_show_inventory:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			if player and player.has_method("set_movement_enabled"):
				player.set_movement_enabled(false)
			# The tab was hidden when the inventory closed; restore the pinned
			# item now that it is on screen again.
			_refresh_property_tab()
		else:
			_hide_variants_panel(false)
			_hide_palettes_panel(false)
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			if player and player.has_method("set_movement_enabled"):
				player.set_movement_enabled(true)

func _on_inventory_item_selected(id: int) -> void:
	if id < 0:
		_property_pinned_item.clear()
		_refresh_property_tab()
		return
	_property_hover_item.clear()
	_property_pinned_item = _block_item_data(id)
	_selected_placeable_scene = null
	_selected_placeable_overrides.clear()
	_displayed_placeable_scene = null
	_refresh_property_tab()
	item_selected.emit(id)

func _on_placeable_item_selected(index: int) -> void:
	if index < 0 or index >= placeable_scenes.size():
		return
	var scene: PackedScene = placeable_scenes[index]
	if not scene:
		return

	# Placeables are inventory items like blocks: clicking one stores it in the
	# currently selected hotbar slot, so the held item follows slot selection.
	_property_hover_item.clear()
	if _selected_placeable_scene != scene:
		_selected_placeable_overrides.clear()
	_selected_placeable_scene = scene
	_property_pinned_item = _placeable_item_data(scene)
	assign_hotbar_placeable(get_hotbar_selected_slot(), scene)
	_refresh_property_tab()
	placeable_selected.emit(scene)


func _on_block_hovered(item_id: int) -> void:
	if item_id < 0:
		return
	_property_hover_item = _block_item_data(item_id)
	_refresh_property_tab()


func _on_placeable_hovered(scene: PackedScene) -> void:
	if scene == null:
		return
	_property_hover_item = _placeable_item_data(scene)
	_refresh_property_tab()


func _on_item_unhovered(_item_id: int = -1) -> void:
	_property_hover_item.clear()
	_refresh_property_tab()


func _on_placeable_unhovered(_scene: PackedScene = null) -> void:
	_property_hover_item.clear()
	_refresh_property_tab()


func _on_hotbar_slot_hovered(index: int) -> void:
	var data := _hotbar_item_data(index)
	if data.is_empty():
		_property_hover_item.clear()
	else:
		_property_hover_item = data
	_refresh_property_tab()


func _on_hotbar_slot_unhovered(_index: int) -> void:
	_property_hover_item.clear()
	_refresh_property_tab()


## A drag/drop changed a slot. Re-run selection handling only for the selected
## slot, so the held item, hand preview and Property tab stay truthful when an
## item is picked up, swapped or dragged out of the hotbar and deleted.
func _on_hotbar_contents_changed(index: int) -> void:
	if hotbar == null or index != hotbar.get_selected_slot():
		return
	_on_hotbar_slot_selected(index)


## Shows the hovered item while hovering, otherwise the clicked/selected item.
func _refresh_property_tab() -> void:
	var item: Dictionary = (
		_property_hover_item
		if not _property_hover_item.is_empty()
		else _property_pinned_item
	)

	if item.is_empty():
		_clear_adjustable_vars()
		_hide_property_tab()
		return

	_render_property_item(item)
	_show_property_tab()

func _block_item_data(item_id: int) -> Dictionary:
	if _cached_mesh_library == null or item_id < 0:
		return {}

	var raw_name := String(_cached_mesh_library.get_item_name(item_id))
	return {
		"kind": "block",
		"item_id": item_id,
		"name": _format_item_title(raw_name),
		"raw_name": raw_name,
		"material": BlockMaterialsDB.material_label(raw_name),
		"block_group": BlockMaterialsDB.block_group_label(raw_name),
		"variant": BlockMaterialsDB.variant_label(raw_name),
		"properties": BlockMaterialsDB.properties_for_item(raw_name),
		"preview": _cached_mesh_library.get_item_preview(item_id),
		"description": _describe_block(raw_name),
	}


func _placeable_item_data(scene: PackedScene) -> Dictionary:
	if scene == null:
		return {}

	return {
		"kind": "placeable",
		"scene": scene,
		"name": _placeable_display_name(scene),
		"preview": _get_scene_preview(scene),
		"description": _placeable_description(scene),
	}


func _hotbar_item_data(index: int) -> Dictionary:
	if hotbar == null:
		return {}
	var data := hotbar.container_get_slot(index)
	if data.is_empty():
		return {}
	var kind := String(data.get("kind", ""))
	if kind == "placeable":
		return _placeable_item_data(data.get("scene"))
	if kind == "palette":
		return _palette_item_data(String(data.get("palette_id", "")))
	return _block_item_data(int(data.get("item_id", -1)))


func _palette_item_data(palette_id: String) -> Dictionary:
	var palette_name := "Palette"
	if _palette_store != null:
		var palette := _palette_store.get_palette(palette_id)
		if not palette.is_empty():
			palette_name = String(palette.get("name", palette_name))
	return {
		"kind": "palette",
		"palette_id": palette_id,
		"name": palette_name,
		"preview": PALETTE_ICON,
		"description": "A reusable 3x3 block and placeable palette. Select its hotbar slot to open it.",
	}


func _format_item_title(item_name: String) -> String:
	var clean := item_name.trim_prefix("Auto_")
	var lower := clean.to_lower()
	var material := clean
	var shape := ""

	if lower.begins_with("water_"):
		return "Water " + clean.substr(6).capitalize()
	if lower.begins_with("connect_"):
		material = clean.substr(8)
	elif lower.begins_with("slab_top_"):
		material = clean.substr(9)
		shape = "Slab"
	elif lower.begins_with("slab_bottom_"):
		material = clean.substr(12)
		shape = "Slab"
	elif lower.begins_with("slab_side_"):
		material = clean.substr(10)
		shape = "Slab"
	elif lower.begins_with("slab_"):
		material = clean.substr(5)
		shape = "Slab"
	elif lower.begins_with("panel_top_"):
		material = clean.substr(10)
		shape = "Panel"
	elif lower.begins_with("panel_bottom_"):
		material = clean.substr(13)
		shape = "Panel"
	elif lower.begins_with("panel_side_"):
		material = clean.substr(11)
		shape = "Panel"
	elif lower.begins_with("panel_"):
		material = clean.substr(6)
		shape = "Panel"
	elif lower.begins_with("stairs_upsidedown_"):
		material = clean.substr(18)
		shape = "Stairs Upside Down"
	elif lower.begins_with("stairs_"):
		material = clean.substr(7)
		shape = "Stairs"
	elif lower.begins_with("stair_"):
		material = clean.substr(6)
		shape = "Stairs"

	var pretty := material.replace("_", " ").capitalize()
	if shape.is_empty():
		return pretty
	return "%s %s" % [pretty, shape]


## Numeric block stats are shown without noisy trailing zeros: 1, 0.81, 0.19.
func _format_block_stat(value: Variant) -> String:
	if value is int or value is float:
		var number := float(value)
		if is_equal_approx(number, roundf(number)):
			return str(int(roundf(number)))
		return String.num(number, 2)
	return str(value)


## Short category description for auto blocks. Hand-authored blocks return "".
func _describe_block(item_name: String) -> String:
	if item_name == "Water_Slab":
		return "Half a block of water (8 units). It falls, spreads, and levels out."
	if item_name == "Water_Panel":
		return "A single unit of water. It spreads into the thinnest possible film."
	if item_name.begins_with("Water_"):
		return "A full block of water (16 units). It falls, spreads to the lowest level, and waterlogs non-full blocks."
	if not item_name.begins_with("Auto_"):
		return ""

	var lower := item_name.to_lower()
	var material := item_name.trim_prefix("Auto_").to_lower()
	for prefix in [
		"connect_",
		"slab_top_",
		"slab_bottom_",
		"slab_side_",
		"slab_",
		"panel_top_",
		"panel_bottom_",
		"panel_side_",
		"panel_",
		"stairs_upsidedown_",
		"stairs_",
		"stair_",
	]:
		if lower.begins_with("auto_" + prefix):
			material = material.substr(prefix.length())
			break

	if "concrete" in material:
		return "A sturdy cast-concrete building block."
	if "dirt" in material:
		return "A compacted dirt block."
	if "grass" in material:
		return "A dirt block with a grass surface."
	if "plank" in material or "wood" in material:
		return "A wooden plank block."
	if "window" in material:
		return "A framed glass window block."
	if "floortile" in material or "tile" in material:
		return "A tiled floor block."
	if "debug" in material:
		return ""
	return "An auto-generated block."


func _placeable_description(scene: PackedScene) -> String:
	for prop in _get_placeable_properties(scene):
		var prop_name := String(prop.get("name", ""))
		if prop_name != "description" and prop_name != "item_description":
			continue
		var prop_type: int = int(prop.get("type", TYPE_NIL))
		if prop_type != TYPE_STRING and prop_type != TYPE_STRING_NAME:
			continue
		return String(prop.get("default", ""))
	return ""


## Cached so hovering/selecting does not instantiate the scene every time.
func _get_placeable_properties(scene: PackedScene) -> Array:
	if scene == null:
		return []

	var key := scene.resource_path
	if key.is_empty():
		key = str(scene)
	if _placeable_property_cache.has(key):
		return _placeable_property_cache[key]

	var props: Array = []
	var temp: Node = scene.instantiate()
	var script: Script = temp.get_script()

	if script:
		for prop in script.get_script_property_list():
			if prop.usage & PROPERTY_USAGE_EDITOR == 0:
				continue
			if not _is_editable_property_type(prop.type):
				continue
			props.append({
				"name": String(prop.name),
				"type": int(prop.type),
				"default": temp.get(prop.name),
			})

	temp.free()
	_placeable_property_cache[key] = props
	return props


## Builds a compact, centred copy of a placeable's 3D visuals for the spinning
## Property-tab preview. The source scene is never added to the tree, so its
## scripts (including foliage sway) never run here.
func _build_placeable_preview(scene: PackedScene) -> Node3D:
	if scene == null:
		return null

	var temp: Node = scene.instantiate()
	var holder := Node3D.new()
	_copy_placeable_visuals(temp, holder, Transform3D.IDENTITY)
	temp.free()
	_fit_placeable_preview(holder, 1.45)
	return holder


func _copy_placeable_visuals(
	source: Node,
	target: Node3D,
	parent_xform: Transform3D
) -> void:
	for child in source.get_children():
		var child_xform: Transform3D = parent_xform

		if child is Node3D:
			child_xform = parent_xform * (child as Node3D).transform

		if child is MeshInstance3D:
			var source_mesh := child as MeshInstance3D
			if source_mesh.mesh != null:
				var mesh_copy := MeshInstance3D.new()
				mesh_copy.mesh = source_mesh.mesh
				mesh_copy.transform = child_xform
				mesh_copy.cast_shadow = (
					GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				)
				if source_mesh.material_override != null:
					mesh_copy.material_override = source_mesh.material_override
				target.add_child(mesh_copy)
		elif child is Sprite3D:
			var source_sprite := child as Sprite3D
			var sprite_copy := Sprite3D.new()
			sprite_copy.texture = source_sprite.texture
			sprite_copy.pixel_size = source_sprite.pixel_size
			sprite_copy.billboard = source_sprite.billboard
			# Unshaded so the preview keeps its colour under the preview lights.
			sprite_copy.shaded = false
			sprite_copy.double_sided = source_sprite.double_sided
			sprite_copy.alpha_cut = source_sprite.alpha_cut
			sprite_copy.texture_filter = source_sprite.texture_filter
			sprite_copy.transform = child_xform
			target.add_child(sprite_copy)

		_copy_placeable_visuals(child, target, child_xform)


## Recentres the grafted visuals and scales the largest dimension to
## `target_size`. Flat ground pieces are tipped up so they stay visible while
## the pivot spins them around Y.
func _fit_placeable_preview(holder: Node3D, target_size: float) -> void:
	var combined := AABB()
	var visual_count := 0

	for child in holder.get_children():
		var box: AABB

		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.mesh == null:
				continue
			box = mesh_instance.transform * mesh_instance.mesh.get_aabb()
		elif child is Sprite3D:
			var sprite := child as Sprite3D
			if sprite.texture == null:
				continue
			# Sprite3D's AABB is not ready until it enters the tree, so build
			# it from the texture and pixel size while the holder is off-tree.
			var sprite_size := Vector3(
				sprite.texture.get_width() * sprite.pixel_size,
				sprite.texture.get_height() * sprite.pixel_size,
				0.0
			)
			var local_box := AABB(-sprite_size * 0.5, sprite_size)
			box = sprite.transform * local_box
		else:
			continue

		combined = box if visual_count == 0 else combined.merge(box)
		visual_count += 1

	if visual_count == 0:
		return

	var center := combined.get_center()
	for child in holder.get_children():
		if child is Node3D:
			(child as Node3D).position -= center

	var max_dim := maxf(
		combined.size.x,
		maxf(combined.size.y, combined.size.z)
	)
	holder.scale = Vector3.ONE * (target_size / maxf(max_dim, 0.001))

	var horizontal := maxf(combined.size.x, combined.size.z)
	if combined.size.y < 0.12 * maxf(horizontal, 0.001):
		holder.rotation.x = deg_to_rad(-60.0)


func _clear_property_placeable_visual() -> void:
	if (
		_property_placeable_holder != null
		and is_instance_valid(_property_placeable_holder)
	):
		_property_placeable_holder.free()
	_property_placeable_holder = null


func _render_property_item(item: Dictionary) -> void:
	if (
		_property_title == null
		or _property_preview == null
		or _property_texture == null
		or _property_block_props == null
		or _property_exports == null
	):
		return

	# Preserve edits on the clicked placeable before a different hover preview
	# replaces the export rows.
	if (
		_displayed_placeable_scene == _selected_placeable_scene
		and _selected_placeable_scene != null
	):
		_selected_placeable_overrides = get_placeable_overrides()

	var kind := String(item.get("kind", ""))
	_property_title.text = String(item.get("name", ""))

	var preview: Texture2D = item.get("preview")
	var mesh: Mesh = null
	var placeable_visual: Node3D = null

	_clear_property_placeable_visual()

	if kind == "block" and _cached_mesh_library != null:
		mesh = _cached_mesh_library.get_item_mesh(int(item.get("item_id", -1)))
	elif kind == "placeable" and item.get("scene") != null:
		placeable_visual = _build_placeable_preview(
			item.get("scene") as PackedScene
		)

	var has_placeable_visual := (
		placeable_visual != null and placeable_visual.get_child_count() > 0
	)
	var can_spin_model := (
		_property_mesh_pivot != null
		and _property_viewport_container != null
	)

	if (
		mesh != null
		and can_spin_model
		and _property_mesh_instance != null
	):
		_property_texture.texture = null
		_property_texture.visible = false
		_property_viewport_container.visible = true

		# Centre the mesh on its own bounds: MeshLibrary transforms can offset
		# items (slabs, stairs), and spinning the pivot would orbit them instead
		# of turning them in place.
		var item_id := int(item.get("item_id", -1))
		_property_mesh_instance.mesh = mesh
		var mesh_transform := _cached_mesh_library.get_item_mesh_transform(item_id)
		var bounds := mesh.get_aabb()
		var centre := mesh_transform * bounds.get_center()
		_property_mesh_instance.transform = Transform3D(
			mesh_transform.basis,
			mesh_transform.origin - centre
		)
		_property_mesh_instance.visible = true

		if _property_camera != null:
			var extent := bounds.size.length()
			_property_camera.position = Vector3(
				0.0,
				0.0,
				maxf(2.4, extent * 1.4)
			)

		_property_mesh_pivot.rotation = Vector3.ZERO
		_property_spin_t = 0.0
	elif has_placeable_visual and can_spin_model:
		# Placeables preview their real grafted visuals (same as the held
		# model), so cross-card foliage and prop meshes read as 3D.
		_property_texture.texture = null
		_property_texture.visible = false
		_property_viewport_container.visible = true
		if _property_mesh_instance != null:
			_property_mesh_instance.visible = false

		_property_placeable_holder = placeable_visual
		_property_mesh_pivot.add_child(placeable_visual)

		if _property_camera != null:
			_property_camera.position = Vector3(0.0, 0.0, 2.8)

		_property_mesh_pivot.rotation = Vector3.ZERO
		_property_spin_t = 0.0
	else:
		if placeable_visual != null:
			placeable_visual.free()
		if _property_viewport_container != null:
			_property_viewport_container.visible = false
		if _property_mesh_instance != null:
			_property_mesh_instance.visible = false
		_property_texture.texture = preview
		_property_texture.visible = preview != null

	var is_block := kind == "block"
	_property_block_props.visible = is_block
	if is_block:
		var values: Dictionary = item.get("properties", {})
		for entry in _property_block_rows:
			var key := String(entry.get("key", ""))
			var value_label: Label = entry.get("value")
			var property_key: String = BLOCK_PROPERTY_KEYS.get(key, "")
			if property_key.is_empty():
				value_label.text = str(values.get(key, entry.get("default", "")))
			else:
				value_label.text = _format_block_stat(
					values.get(
						property_key,
						BlockMaterialsDB.FALLBACK_PROPERTIES.get(
							property_key,
							entry.get("default", "")
						)
					)
				)

	var description := String(item.get("description", ""))
	if description.is_empty() and is_block:
		description = _describe_block(String(item.get("raw_name", "")))
	if _property_description != null:
		_property_description.text = description
		_property_description.visible = not description.is_empty()

	_clear_adjustable_vars()
	if kind == "placeable" and item.get("scene") != null:
		var scene: PackedScene = item.get("scene")
		var overrides: Dictionary = (
			_selected_placeable_overrides
			if scene == _selected_placeable_scene
			else {}
		)
		var row_count := _show_adjustable_vars(scene, overrides)
		_property_exports.visible = row_count > 0
	else:
		# Nothing on screen belongs to the clicked placeable now, so the stored
		# overrides must not be overwritten from empty rows.
		_displayed_placeable_scene = null
		_property_exports.visible = false

	if _property_separator != null:
		_property_separator.visible = _property_exports.visible


func _show_adjustable_vars(
	scene: PackedScene,
	overrides: Dictionary = {}
) -> int:
	_clear_adjustable_vars()
	_displayed_placeable_scene = scene
	if not adjustable_vars_container or not adjustable_var_row_scene:
		return 0

	var row_count := 0
	for prop in _get_placeable_properties(scene):
		var row: Control = adjustable_var_row_scene.instantiate()
		adjustable_vars_container.add_child(row)

		var prop_name := String(prop.get("name", ""))
		var prop_type: int = int(prop.get("type", TYPE_NIL))
		var label: Label = row.get_node_or_null("HBoxContainer/Label")
		var line_edit: LineEdit = row.get_node_or_null("HBoxContainer/LineEdit")
		if label:
			label.text = prop_name.capitalize()
		if line_edit:
			line_edit.text = _value_to_text(
				overrides.get(prop_name, prop.get("default"))
			)

		row.set_meta("var_name", prop_name)
		row.set_meta("var_type", prop_type)
		row_count += 1

	return row_count


func _show_property_tab() -> void:
	if property_tab:
		property_tab.visible = true
	if _property_viewport:
		_property_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _hide_property_tab() -> void:
	if property_tab:
		property_tab.visible = false
	if _property_viewport:
		_property_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _is_editable_property_type(type: int) -> bool:
	match type:
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_STRING, TYPE_STRING_NAME, \
		TYPE_VECTOR2, TYPE_VECTOR3:
			return true
		_:
			return false


func _clear_adjustable_vars() -> void:
	if not adjustable_vars_container:
		return
	for child in adjustable_vars_container.get_children():
		# Free immediately: rebuilding the sheet must not stack the old rows
		# until the end of the frame (which also corrupts the placement overrides).
		child.free()

func _value_to_text(value: Variant) -> String:
	match typeof(value):
		TYPE_VECTOR2:
			return "%s,%s" % [value.x, value.y]
		TYPE_VECTOR3:
			return "%s,%s,%s" % [value.x, value.y, value.z]
		_:
			return str(value)

func _parse_value(text: String, type: int) -> Variant:
	match type:
		TYPE_INT:
			return text.to_int()
		TYPE_FLOAT:
			return text.to_float()
		TYPE_BOOL:
			return text.strip_edges().to_lower() == "true"
		TYPE_VECTOR2:
			var parts := text.split(",")
			if parts.size() >= 2:
				return Vector2(parts[0].to_float(), parts[1].to_float())
			return Vector2.ZERO
		TYPE_VECTOR3:
			var parts := text.split(",")
			if parts.size() >= 3:
				return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
			return Vector3.ZERO
		TYPE_STRING, TYPE_STRING_NAME:
			return text
		_:
			return text

func get_placeable_overrides() -> Dictionary:
	var overrides: Dictionary = {}

	# If the sheet currently on screen belongs to a hover preview rather than
	# the clicked placeable, placement must keep using the clicked values.
	if (
		_displayed_placeable_scene != null
		and _displayed_placeable_scene != _selected_placeable_scene
	):
		return _selected_placeable_overrides.duplicate()

	if not adjustable_vars_container:
		return overrides

	for row in adjustable_vars_container.get_children():
		if not row.has_meta("var_name"):
			continue
		var var_name: String = row.get_meta("var_name")
		var var_type: int = row.get_meta("var_type")
		var line_edit: LineEdit = row.get_node_or_null("HBoxContainer/LineEdit")
		if line_edit:
			overrides[var_name] = _parse_value(line_edit.text, var_type)

	return overrides

func get_selected_placeable_scene() -> PackedScene:
	return _selected_placeable_scene
