class_name PoweredComponent
extends LogicComponent

## Base for logic-driven devices. Connect a LogicComponent output to
## `receive_input()` (input 0) and override `_apply_power()`.

signal powered_changed(value: bool)

@export var inverted: bool = false
@export var starts_powered: bool = false

var powered: bool = false


func _ready() -> void:
	super._ready()
	powered = starts_powered
	_apply_power()


func receive_input(_input_index: int, value: bool) -> void:
	set_powered(value != inverted)


func set_powered(value: bool) -> void:
	if value == powered:
		return

	powered = value
	powered_changed.emit(value)
	_apply_power()


func _apply_power() -> void:
	pass
