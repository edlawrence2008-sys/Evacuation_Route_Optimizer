extends VBoxContainer

## Edits the exported properties of the member/NPC scene. The values are stored
## in GlobalData so every future spawn inherits them; Apply also updates the
## live agents immediately.

const ROW_SCENE: PackedScene = preload(
	"res://scenes/inventory/AdjustableVariableRow.tscn"
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
		var line_edit: LineEdit = row.get_node_or_null(
			"HBoxContainer/LineEdit"
		)

		if label:
			label.text = property_name.capitalize()
		if line_edit:
			line_edit.text = _value_to_text(temp.get(prop.name))

		row.set_meta("var_name", property_name)
		row.set_meta("var_type", prop.type)
		_defaults[property_name] = temp.get(prop.name)

	temp.free()
	_set_status("Edit values, then Apply to live and future agents.")


## Refreshes the fields from the currently applied overrides (or scene defaults).
func _sync_from_state() -> void:
	for row in properties.get_children():
		if not row.has_meta("var_name"):
			continue

		var property_name: String = row.get_meta("var_name")
		var value: Variant = GlobalData.agent_overrides.get(
			property_name,
			_defaults.get(property_name)
		)
		var line_edit: LineEdit = row.get_node_or_null(
			"HBoxContainer/LineEdit"
		)

		if line_edit:
			line_edit.text = _value_to_text(value)


func _collect_overrides() -> Dictionary:
	var overrides: Dictionary = {}

	for row in properties.get_children():
		if not row.has_meta("var_name"):
			continue

		var property_name: String = row.get_meta("var_name")
		var property_type: int = row.get_meta("var_type")
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
