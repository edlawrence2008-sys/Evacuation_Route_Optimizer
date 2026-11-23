extends CheckBox

signal filter_toggled(tag_name: String, is_toggled: bool)

var _tag_name: String = ""

func setup(tag: String, default_pressed: bool = true) -> void:
	_tag_name = tag
	text = tag
	button_pressed = default_pressed
	
	if not toggled.is_connected(_on_check_box_toggled):
		toggled.connect(_on_check_box_toggled)

func _on_check_box_toggled(toggled_on: bool) -> void:
	filter_toggled.emit(_tag_name, toggled_on)
