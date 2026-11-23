class_name GuiComponent
extends BlockComponent

## Opens a Control scene when the player interacts with the owning object.
## The actual host (HUD, console, or a future inventory screen) listens for
## `gui_requested` and decides where to mount the panel; the component itself
## never assumes a particular UI layout.

signal gui_requested(actor: Node, panel_scene: PackedScene)

@export var panel_scene: PackedScene
@export var panel_name: String = ""


func can_interact(_actor: Node) -> bool:
	return panel_scene != null


func interact(actor: Node) -> void:
	if panel_scene == null:
		return
	gui_requested.emit(actor, panel_scene)
