extends VBoxContainer

## Edits the exported properties of the member/NPC scene. The values are stored
## in GlobalData so every future spawn inherits them; Apply also updates the
## live agents immediately.

const ROW_SCENE: PackedScene = preload(
	"res://scenes/inventory/AdjustableVariableRow.tscn"
)
const SPRITE_LIBRARY = preload(
	"res://scripts/NPCstuff/RealisticSpriteLibrary.gd"
)

@export var agent_scene: PackedScene = preload(
	"res://scenes/npcs/Member.tscn"
)

@onready var properties: VBoxContainer = $PropertiesScroll/Properties
@onready var apply_button: Button = $Actions/Apply
@onready var reset_button: Button = $Actions/Reset
@onready var status_label: Label = $Status

## Property defaults captured from the agent scene, used by Reset and by rows
## that have not been overridden yet.
var _defaults: Dictionary = {}


func _ready() -> void:
	apply_button.pressed.connect(_on_apply_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	_build_rows()
	_sync_from_state()


func _build_rows() -> void:
	for child in properties.get_children():
		child.queue_free()

	_defaults.clear()

	if agent_scene == null:
		_set_status("No agent scene assigned.")
		return

	var temp: Node = agent_scene.instantiate()
	var script: Script = temp.get_script()

	if script == null:
		temp.free()
		_set_status("Agent scene has no script.")
		return

	for prop in script.get_script_property_list():
		if prop.usage & PROPERTY_USAGE_EDITOR == 0:
			continue

		if not _is_editable_property_type(prop.type):
			continue

		# Evacuation mode is owned by the Simulation panel.
		if prop.name == "is_evacuee":
			continue

		var row: Control = ROW_SCENE.instantiate()
		properties.add_child(row)

		var property_name: String = String(prop.name)
		var label: Label = row.get_node_or_null("HBoxContainer/Label")

		if label:
			label.text = property_name.capitalize()

		var value: Variant = temp.get(prop.name)
		row.set_meta("var_name", property_name)
		row.set_meta("var_type", prop.type)
		_apply_row_value(row, value, prop.type)
		_defaults[property_name] = value

	temp.free()
	_set_status("Edit values, then Apply to live and future agents.")


## Refreshes the fields from the currently applied overrides (or scene defaults).
func _sync_from_state() -> void:
	for row in properties.get_children():
		if not row.has_meta("var_name"):
			continue

		var property_name: String = row.get_meta("var_name")
		var property_type: int = row.get_meta("var_type")
		var value: Variant = GlobalData.agent_overrides.get(
			property_name,
			_defaults.get(property_name)
		)
		_apply_row_value(row, value, property_type)


func _collect_overrides() -> Dictionary:
	var overrides: Dictionary = {}

	for row in properties.get_children():
		if not row.has_meta("var_name"):
			continue

		var property_name: String = row.get_meta("var_name")
		var property_type: int = row.get_meta("var_type")

		if property_type == TYPE_BOOL:
			var check_box: CheckBox = row.get_node_or_null(
				"HBoxContainer/CheckBox"
			)
			overrides[property_name] = (
				check_box.button_pressed if check_box != null else false
			)
			continue

		if property_name == "realistic_sprite":
			var sprite_option: OptionButton = row.get_node_or_null(
				"HBoxContainer/SpriteOption"
			)
			if sprite_option != null and sprite_option.selected >= 0:
				overrides[property_name] = String(
					sprite_option.get_item_metadata(sprite_option.selected)
				)
			continue

		var line_edit: LineEdit = row.get_node_or_null(
			"HBoxContainer/LineEdit"
		)

		if line_edit:
			overrides[property_name] = _parse_value(
				line_edit.text,
				property_type
			)

	return overrides


func _on_apply_pressed() -> void:
	var overrides: Dictionary = _collect_overrides()
	var live_count: int = GlobalData.set_agent_overrides(overrides)

	_set_status(
		"Applied %d settings to %d live agent%s (future spawns included)."
		% [
			overrides.size(),
			live_count,
			"" if live_count == 1 else "s",
		]
	)


func _on_reset_pressed() -> void:
	GlobalData.clear_agent_overrides()

	var live_count: int = 0

	for npc in get_tree().get_nodes_in_group("npc"):
		if npc.has_method("apply_agent_overrides"):
			npc.apply_agent_overrides(_defaults)
			live_count += 1

	_sync_from_state()
	_set_status(
		"Reset %d live agent%s to scene defaults."
		% [live_count, "" if live_count == 1 else "s"]
	)


func _set_status(message: String) -> void:
	if status_label:
		status_label.text = message


## Bool rows become checkboxes, sprite IDs become dropdowns, and every other
## editable type stays a text field.
func _apply_row_value(row: Control, value: Variant, type: int) -> void:
	var line_edit: LineEdit = row.get_node_or_null(
		"HBoxContainer/LineEdit"
	)
	var check_box: CheckBox = row.get_node_or_null(
		"HBoxContainer/CheckBox"
	)
	var property_name: String = row.get_meta("var_name", "")

	if property_name == "realistic_sprite":
		_apply_sprite_option(row, value)
		return

	if type == TYPE_BOOL:
		if check_box == null:
			check_box = CheckBox.new()
			check_box.name = "CheckBox"
			var row_box: HBoxContainer = row.get_node("HBoxContainer")
			row_box.add_child(check_box)

		check_box.button_pressed = bool(value)
		if line_edit:
			line_edit.visible = false
		return

	if check_box:
		check_box.queue_free()
	if line_edit:
		line_edit.visible = true
		line_edit.text = _value_to_text(value)


func _apply_sprite_option(row: Control, value: Variant) -> void:
	var line_edit: LineEdit = row.get_node_or_null(
		"HBoxContainer/LineEdit"
	)
	var sprite_option: OptionButton = row.get_node_or_null(
		"HBoxContainer/SpriteOption"
	)

	if sprite_option == null:
		sprite_option = OptionButton.new()
		sprite_option.name = "SpriteOption"
		sprite_option.custom_minimum_size = Vector2(150.0, 0.0)
		var row_box: HBoxContainer = row.get_node("HBoxContainer")
		row_box.add_child(sprite_option)

	if line_edit:
		line_edit.visible = false

	var wanted: String = String(value).strip_edges()
	if wanted.is_empty():
		wanted = String(SPRITE_LIBRARY.default_id())

	var ids: PackedStringArray = SPRITE_LIBRARY.get_ids()
	var selected: int = -1

	sprite_option.clear()

	# Keep the explicit single-sprite choices and add a per-agent random pick.
	sprite_option.add_item("Random")
	sprite_option.set_item_metadata(0, String(SPRITE_LIBRARY.RANDOM_ID))
	if wanted == String(SPRITE_LIBRARY.RANDOM_ID):
		selected = 0

	for index in ids.size():
		var item_index: int = sprite_option.item_count
		sprite_option.add_item(ids[index])
		sprite_option.set_item_metadata(item_index, ids[index])
		if ids[index] == wanted:
			selected = item_index

	if selected == -1:
		sprite_option.add_item(wanted)
		sprite_option.set_item_metadata(
			sprite_option.item_count - 1,
			wanted
		)
		selected = sprite_option.item_count - 1

	sprite_option.select(selected)


func _is_editable_property_type(type: int) -> bool:
	match type:
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_STRING, TYPE_STRING_NAME, \
		TYPE_VECTOR2, TYPE_VECTOR3:
			return true
		_:
			return false


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
			return text.strip_edges().to_lower() in [
				"true", "1", "on", "yes"
			]
		TYPE_VECTOR2:
			var parts: PackedStringArray = text.split(",")
			if parts.size() >= 2:
				return Vector2(parts[0].to_float(), parts[1].to_float())
			return Vector2.ZERO
		TYPE_VECTOR3:
			var parts: PackedStringArray = text.split(",")
			if parts.size() >= 3:
				return Vector3(
					parts[0].to_float(),
					parts[1].to_float(),
					parts[2].to_float()
				)
			return Vector3.ZERO
		TYPE_STRING, TYPE_STRING_NAME:
			return text
		_:
			return text
