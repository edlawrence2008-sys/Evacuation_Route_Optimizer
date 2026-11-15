class_name ComponentLookup
extends RefCounted

## Small helpers so gameplay systems do not need to know a component's node
## name or position. Components can live anywhere under the placed scene.


static func find_component(root: Node, type: Script) -> BlockComponent:
	if root == null:
		return null

	for node in root.find_children("*", "", true, false):
		if node is BlockComponent and is_instance_of(node, type):
			return node

	return null


static func find_interactable(root: Node) -> InteractableComponent:
	return find_component(root, InteractableComponent) as InteractableComponent


static func find_container(root: Node) -> ContainerComponent:
	return find_component(root, ContainerComponent) as ContainerComponent


static func find_gui(root: Node) -> GuiComponent:
	return find_component(root, GuiComponent) as GuiComponent


static func find_use(root: Node) -> UseComponent:
	return find_component(root, UseComponent) as UseComponent


static func find_explosive(root: Node) -> ExplosiveComponent:
	return find_component(root, ExplosiveComponent) as ExplosiveComponent


static func find_fire(root: Node) -> FireComponent:
	return find_component(root, FireComponent) as FireComponent


static func find_powered(root: Node) -> PoweredComponent:
	return find_component(root, PoweredComponent) as PoweredComponent


## The component that should receive an Interact press, preferring an explicit
## InteractableComponent and falling back to a GUI opener.
static func find_usable(root: Node) -> BlockComponent:
	var interactable := find_interactable(root)
	if interactable != null:
		return interactable

	var gui := find_gui(root)
	if gui != null and gui.can_interact(null):
		return gui

	return null


static func all(root: Node) -> Array[BlockComponent]:
	var result: Array[BlockComponent] = []
	if root == null:
		return result

	for node in root.find_children("*", "", true, false):
		if node is BlockComponent:
			result.append(node)

	return result
