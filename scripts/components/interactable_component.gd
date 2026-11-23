extends BlockComponent
class_name InteractableComponent

## Doors, levers, switches, and anything else the player uses with Interact.
## Connect to `interacted` for one-shot behaviour, or enable `toggle_mode` and
## connect to `toggled` for on/off devices. The optional parent `_on_interact`
## hook is kept for older scenes.

signal interacted(actor: Node)
signal toggled(is_on: bool)

@export var interact_prompt: String = "Interact"
@export var is_enabled: bool = true
@export var toggle_mode: bool = false
@export var starts_on: bool = false

var is_on: bool = false


func _ready() -> void:
	is_on = starts_on


func can_interact(_actor: Node) -> bool:
	return is_enabled


func interact(actor: Node) -> void:
	if not is_enabled:
		return

	if toggle_mode:
		is_on = not is_on
		toggled.emit(is_on)

	interacted.emit(actor)

	var parent := get_parent()
	if parent and parent.has_method("_on_interact"):
		parent._on_interact(actor)
