class_name LogicGateComponent
extends LogicComponent

## AND / OR / NOT / NAND / NOR / XOR / XNOR. Inputs are event-driven: the gate
## only evaluates when one of its inputs changes.

enum Gate { AND, OR, NOT, NAND, NOR, XOR, XNOR }

@export var gate: Gate = Gate.AND
@export_range(1, 8, 1) var input_count: int = 2
## Inverts the result; useful for active-low devices.
@export var invert_output: bool = false

var _inputs: Array[bool] = []


func _ready() -> void:
	super._ready()
	var count := maxi(input_count, 1)
	_inputs.resize(count)
	_inputs.fill(false)
	evaluate()


func receive_input(input_index: int, value: bool) -> void:
	if input_index < 0 or input_index >= _inputs.size():
		return
	if _inputs[input_index] == value:
		return

	_inputs[input_index] = value
	evaluate()


func evaluate() -> void:
	if _inputs.is_empty():
		set_output(false)
		return

	var result := _inputs[0]
	match gate:
		Gate.AND, Gate.NAND:
			for index in range(1, _inputs.size()):
				result = result and _inputs[index]
			if gate == Gate.NAND:
				result = not result
		Gate.OR, Gate.NOR:
			for index in range(1, _inputs.size()):
				result = result or _inputs[index]
			if gate == Gate.NOR:
				result = not result
		Gate.NOT:
			result = not _inputs[0]
		Gate.XOR, Gate.XNOR:
			var true_count := 0
			for value in _inputs:
				if value:
					true_count += 1
			result = (true_count % 2) == 1
			if gate == Gate.XNOR:
				result = not result

	if invert_output:
		result = not result

	set_output(result)
