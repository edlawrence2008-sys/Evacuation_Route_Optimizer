extends Node
class_name InteractableComponent

signal interacted(player: Node3D)

@export var interact_prompt: String = "Interact"
@export var is_enabled: bool = true

func interact(player: Node3D) -> void:
	if not is_enabled: return
	
	interacted.emit(player)
	
	# Optional: Call a method on the parent if you prefer direct logic over signals
	var parent = get_parent()
	if parent and parent.has_method("_on_interact"):
		parent._on_interact(player)
