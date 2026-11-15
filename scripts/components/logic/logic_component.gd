class_name LogicComponent
extends BlockComponent

## Base for logic sources, gates, and devices. Outputs propagate only when the
## value changes; connections are stored as direct component references so a
## large network does not need a per-frame graph walk.

signal output_changed(value: bool)

@export var output_enabled: bool = true
@export var start_output: bool = false

var _output: bool = false
var _listeners: Array[Dictionary] = []


func _ready() -> void:
	_output = start_output


func get_output() -> bool:
	return _output


func set_output(value: bool) -> void:
	if not output_enabled:
		return
	if value == _output:
		return

	_output = value
	output_changed.emit(value)

	for link: Dictionary in _listeners:
		LogicNetwork.post_input(
			link["target"] as Node,
			int(link["input"]),
			value
		)


func toggle_output() -> void:
	set_output(not _output)


## Connects this output to `target`'s input slot. The target receives the
## current value immediately so a newly placed wire initialises correctly.
func connect_to(target: LogicComponent, input_index: int = 0) -> void:
	if target == null:
		return

	for link: Dictionary in _listeners:
		if (
			link["target"] == target
			and int(link["input"]) == input_index
		):
			return

	_listeners.append({
		"target": target,
		"input": input_index,
	})
	LogicNetwork.post_input(target, input_index, _output)


func disconnect_from(target: LogicComponent) -> void:
	for index in range(_listeners.size() - 1, -1, -1):
		if _listeners[index]["target"] == target:
			_listeners.remove_at(index)


## Called by LogicNetwork when an upstream output changes.
func receive_input(_input_index: int, _value: bool) -> void:
	pass
