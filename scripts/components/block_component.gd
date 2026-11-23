class_name BlockComponent
extends Node

## Base class for behaviour attached to a block or placeable. Components are
## ordinary child nodes, so they can be added, moved, and configured in the
## scene editor. Systems find them with ComponentLookup instead of hard-coding
## every feature into the placeable script.

@export var component_id: StringName = &""


func get_component_id() -> StringName:
	if component_id != &"":
		return component_id
	return StringName(String(name).to_snake_case())


## True when this component wants the player's Interact (E) press.
func can_interact(_actor: Node) -> bool:
	return false


func interact(_actor: Node) -> void:
	pass


## Optional hooks for systems that place/remove the owning scene.
func on_placed() -> void:
	pass


func on_removed() -> void:
	pass


func serialize() -> Dictionary:
	return {}


func deserialize(_data: Dictionary) -> void:
	pass
