class_name LogicSourceComponent
extends LogicComponent

## Manual logic source for levers, buttons, and switches. If it shares a
## placeable with an InteractableComponent, it connects automatically:
## toggle-mode interactables drive the output, and one-shot interactables
## toggle it on each use.

func _ready() -> void:
	super._ready()

	var parent := get_parent()
	if parent == null:
		return

	var interactable := ComponentLookup.find_interactable(parent)
	if interactable == null:
		return

	if interactable.toggle_mode:
		interactable.toggled.connect(set_output)
	else:
		interactable.interacted.connect(_on_interacted)


func _on_interacted(_actor: Node) -> void:
	toggle_output()
