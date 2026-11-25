extends Node

## Keeps text entry from trapping the keyboard. Every LineEdit/TextEdit gets:
##   - Escape releases focus (so a second Escape can pause/close),
##   - Enter submits the line and releases focus,
##   - a click outside the field releases focus.
##
## Dialog text fields are left alone: their Window/ConfirmationDialog owns
## Escape and Enter so Cancel/OK still work.

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_on_node_added)
	_scan_existing(get_tree().root)


func _scan_existing(node: Node) -> void:
	if node is LineEdit or node is TextEdit:
		_bind_text_control(node as Control)

	for child in node.get_children():
		_scan_existing(child)


func _on_node_added(node: Node) -> void:
	if node is LineEdit or node is TextEdit:
		_bind_text_control(node as Control)


func _bind_text_control(control: Control) -> void:
	if control.has_meta("ui_focus_bound"):
		return

	control.set_meta("ui_focus_bound", true)
	control.gui_input.connect(_on_text_gui_input.bind(control))

	if control is LineEdit:
		(control as LineEdit).text_submitted.connect(
			func(_text: String) -> void:
				if is_instance_valid(control):
					control.release_focus()
		)


func _on_text_gui_input(event: InputEvent, control: Control) -> void:
	if not is_instance_valid(control):
		return

	if _inside_dialog(control):
		return

	if (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.keycode == KEY_ESCAPE
	):
		control.release_focus()
		control.accept_event()


func _unhandled_input(event: InputEvent) -> void:
	var viewport := get_viewport()

	if viewport == null:
		return

	var focus := viewport.gui_get_focus_owner()

	if focus == null or not is_instance_valid(focus):
		return

	if not (focus is LineEdit or focus is TextEdit):
		return

	if _inside_dialog(focus):
		return

	if event.is_action_pressed("ui_cancel"):
		focus.release_focus()
		viewport.set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed:
		if not focus.get_global_rect().has_point(event.position):
			focus.release_focus()


func _inside_dialog(control: Control) -> bool:
	var node: Node = control
	var root := get_tree().root

	while node != null and node != root:
		if node is Window:
			return true
		node = node.get_parent()

	return false
