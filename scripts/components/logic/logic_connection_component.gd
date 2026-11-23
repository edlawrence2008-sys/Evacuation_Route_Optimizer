class_name LogicConnectionComponent
extends Node

## Editor-friendly wiring: point at a source component and a target component.
## Both paths are resolved relative to this node (absolute paths also work).
## Use one connection node per target input.

@export var source_path: NodePath
@export var target_path: NodePath
@export var target_input: int = 0


func _ready() -> void:
	var source := get_node_or_null(source_path) as LogicComponent
	var target := get_node_or_null(target_path) as LogicComponent

	if source != null and target != null:
		source.connect_to(target, target_input)
