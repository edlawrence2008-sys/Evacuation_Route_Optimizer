class_name HUDManager
extends Control

@onready var build_ui_label: Label = $Label
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

const FOLIAGE_PLACEABLES_FOLDER := "res://scenes/placeables/foilage/"

# --- OFFSET CONTROLS ---
@export var arrow_x_offset: float = 10.0
@export var arrow_y_offset: float = 0.0

@onready var adjustable_vars_container: VBoxContainer = $Inventory/VarScroll/AdjustableVars
@onready var adjustable_var_row_scene: PackedScene = load("res://scenes/inventory/AdjustableVariableRow.tscn")

signal item_selected(item_id: int)
signal placeable_selected(scene: PackedScene)

var _last_inventory_visible: bool = false

var _cached_build_items: PackedInt32Array
var _cached_mesh_library: MeshLibrary

var _selected_placeable_scene: PackedScene = null

enum Category { BLOCKS, PLACEABLES, SIMULATION, AGENTS }
var _current_category: Category = Category.BLOCKS

# Active filter tracking
var _active_filters: Array[String] = []
var _search_query: String = ""

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

	if placeable_scenes.is_empty():
		var evac: PackedScene = load("res://scenes/evac_point.tscn")
		var spawner: PackedScene = load("res://scenes/spawner.tscn")
		if evac:
			placeable_scenes.append(evac)
		if spawner:
			placeable_scenes.append(spawner)

	_append_foliage_placeables()

	_update_category_arrow.call_deferred()
	_update_category_panel.call_deferred()


## Adds every generated foliage scene from the placeables folder to the
## inventory. The scenes are produced by scripts/foliage_generator.gd.
func _append_foliage_placeables() -> void:
	if not DirAccess.dir_exists_absolute(FOLIAGE_PLACEABLES_FOLDER):
		return

	var files := DirAccess.get_files_at(FOLIAGE_PLACEABLES_FOLDER)
	files.sort()

	for file_name: String in files:
		if not file_name.ends_with(".tscn"):
			continue

		var scene := load(
			FOLIAGE_PLACEABLES_FOLDER.path_join(file_name)
		) as PackedScene

		if scene != null and not placeable_scenes.has(scene):
			placeable_scenes.append(scene)

func setup_inventory(build_items: PackedInt32Array, mesh_library: MeshLibrary) -> void:
	_cached_build_items = build_items
	_cached_mesh_library = mesh_library
	
	_refresh_filters()
	_refresh_inventory_display()
	_update_category_arrow()

func _refresh_filters() -> void:
	if not category_filters_container and has_node("Inventory/ItemFilters/GridContainer"):
		category_filters_container = $Inventory/ItemFilters/GridContainer as Container

	if not category_filters_container or not filter_checkbox_scene:
		return

	for child in category_filters_container.get_children():
		child.queue_free()

	if _current_category == Category.SIMULATION or _current_category == Category.AGENTS:
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
				var display_name: String = scene.resource_path.get_file().get_basename().capitalize()
				var tags = _get_item_tags(display_name)
				for t in tags:
					if not available_tags.has(t):
						available_tags.append(t)

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

## Extracts all applicable tags for an item (e.g. both Material and Slab type)
func _get_item_tags(item_name: String) -> Array[String]:
	var tags: Array[String] = []
	var clean = item_name.trim_prefix("Auto_")
	clean = clean.replace(" ", "_")
	var lower = clean.to_lower()
	
	# Check for slab / stair shape type, then keep the material as a second tag.
	if "slab_top" in lower:
		tags.append("Slab_Top")
		clean = clean.replace("slab_top", "").replace("Slab_Top", "")
	elif "slab_bottom" in lower:
		tags.append("Slab_Bottom")
		clean = clean.replace("slab_bottom", "").replace("Slab_Bottom", "")
	elif "slab" in lower:
		clean = clean.replace("slab", "").replace("Slab", "")
	elif lower.begins_with("stairs_"):
		tags.append("Stairs")
		clean = clean.substr(7)
	elif lower.begins_with("stair_"):
		tags.append("Stairs")
		clean = clean.substr(6)
	
	# Extract material/category tag from remaining name parts
	clean = clean.strip_edges().trim_prefix("_").trim_suffix("_")
	var parts = clean.split("_")
	if parts.size() > 0 and not parts[0].is_empty():
		var material_tag = parts[0].capitalize()
		if not tags.has(material_tag):
			tags.append(material_tag)
			
	return tags

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

	for child in inventory_container.get_children():
		child.free()

	if not _search_query.is_empty():
		_display_search_results()
		return

	match _current_category:
		Category.BLOCKS:
			_add_block_groups()
		Category.PLACEABLES:
			_add_placeable_group()
		Category.SIMULATION, Category.AGENTS:
			pass


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
	show_icon: bool = true
) -> void:
	var icon: Texture2D = (
		_cached_mesh_library.get_item_preview(id)
		if show_icon and _cached_mesh_library
		else null
	)

	var btn = item_button_scene.instantiate()
	parent.add_child(btn)
	btn.setup(id, item_name, icon)
	btn.tooltip_text = "Block: %s" % item_name
	btn.item_selected.connect(_on_inventory_item_selected)


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
	btn.setup(index, display_name, icon)
	btn.tooltip_text = "Placeable: %s" % display_name
	btn.item_selected.connect(_on_placeable_item_selected)


func _add_block_groups() -> void:
	if not _cached_mesh_library:
		return

	var groups: Dictionary = {}

	for id in _cached_build_items:
		var item_name: String = _cached_mesh_library.get_item_name(id)
		var tags: Array[String] = _get_item_tags(item_name)

		if not _passes_active_filters(tags):
			continue

		# Group by the material tag; shape tags remain available as filters.
		var group_name: String = (
			tags[tags.size() - 1] if not tags.is_empty() else "Other"
		)
		if not groups.has(group_name):
			groups[group_name] = []
		groups[group_name].append({"id": id, "name": item_name})

	var group_names: Array = groups.keys()
	group_names.sort()

	for group_name: String in group_names:
		var grid := _add_group(group_name, groups[group_name].size())
		for entry: Dictionary in groups[group_name]:
			_add_block_button(
				grid,
				int(entry["id"]),
				String(entry["name"])
			)


func _add_placeable_group() -> void:
	var grid := _add_group("Placeables")

	for index in placeable_scenes.size():
		var scene: PackedScene = placeable_scenes[index]
		if not scene:
			continue

		var display_name: String = (
			scene.resource_path.get_file().get_basename().capitalize()
		)
		var tags: Array[String] = _get_item_tags(display_name)

		if not _passes_active_filters(tags):
			continue

		_add_placeable_button(grid, index, display_name)


func _display_search_results() -> void:
	var block_matches: Array[Dictionary] = []
	var placeable_matches: Array[Dictionary] = []

	if _cached_mesh_library:
		for id in _cached_build_items:
			var item_name: String = _cached_mesh_library.get_item_name(id)
			if _matches_search(item_name):
				block_matches.append({"id": id, "name": item_name})

	for index in placeable_scenes.size():
		var scene: PackedScene = placeable_scenes[index]
		if not scene:
			continue
		var display_name: String = (
			scene.resource_path.get_file().get_basename().capitalize()
		)
		if _matches_search(display_name):
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
			_add_block_button(
				block_grid,
				int(entry["id"]),
				String(entry["name"]),
				false
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
	var temp: Node = scene.instantiate()
	var icon: Texture2D = null
	var sprite = _find_child_by_type(temp, [Sprite2D, Sprite3D])
	if sprite:
		if sprite is Sprite2D and sprite.texture:
			icon = sprite.texture
		elif sprite is Sprite3D and sprite.texture:
			icon = sprite.texture
	temp.free()
	return icon

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

	if adjustable_vars_container:
		adjustable_vars_container.visible = (_current_category == Category.PLACEABLES)
	if _current_category != Category.PLACEABLES:
		_clear_adjustable_vars()

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

	var variables := get_node_or_null("Inventory/VarScroll")
	if variables:
		variables.visible = (
			not simulation_selected
			and not agents_selected
			and not searching
		)

func update_build_ui(build_mode_active: bool, inventory_open: bool, current_item_name: String = "") -> void:
	var should_show_inventory = build_mode_active and inventory_open
	
	if inventory_panel:
		inventory_panel.visible = should_show_inventory
		if should_show_inventory:
			_update_category_arrow.call_deferred()

	if build_ui_label:
		build_ui_label.visible = build_mode_active
		if build_mode_active:
			if current_item_name != "":
				build_ui_label.text = "Selected Block: %s" % current_item_name
			else:
				build_ui_label.text = "Selected Block: None"

	if should_show_inventory != _last_inventory_visible:
		_last_inventory_visible = should_show_inventory
		
		var player = get_tree().get_first_node_in_group("player")
		
		if should_show_inventory:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			if player and player.has_method("set_movement_enabled"):
				player.set_movement_enabled(false)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			if player and player.has_method("set_movement_enabled"):
				player.set_movement_enabled(true)

func _on_inventory_item_selected(id: int) -> void:
	item_selected.emit(id)

func _on_placeable_item_selected(index: int) -> void:
	if index < 0 or index >= placeable_scenes.size():
		return
	var scene: PackedScene = placeable_scenes[index]
	if not scene:
		return

	_selected_placeable_scene = scene
	_show_adjustable_vars(scene)
	placeable_selected.emit(scene)

func _show_adjustable_vars(scene: PackedScene) -> void:
	_clear_adjustable_vars()
	if not adjustable_vars_container or not adjustable_var_row_scene:
		return

	var temp: Node = scene.instantiate()
	var script: Script = temp.get_script()

	if script:
		for prop in script.get_script_property_list():
			if prop.usage & PROPERTY_USAGE_EDITOR == 0:
				continue
			if not _is_editable_property_type(prop.type):
				continue

			var row: Control = adjustable_var_row_scene.instantiate()
			adjustable_vars_container.add_child(row)

			var label: Label = row.get_node_or_null("HBoxContainer/Label")
			var line_edit: LineEdit = row.get_node_or_null("HBoxContainer/LineEdit")
			if label:
				label.text = String(prop.name).capitalize()
			if line_edit:
				line_edit.text = _value_to_text(temp.get(prop.name))

			row.set_meta("var_name", prop.name)
			row.set_meta("var_type", prop.type)

	temp.free()

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
		child.queue_free()

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
