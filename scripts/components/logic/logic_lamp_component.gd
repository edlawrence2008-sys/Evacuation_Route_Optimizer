class_name LogicLampComponent
extends PoweredComponent

## Example powered device: switches a Light3D (and optionally an emission
## material) when the logic signal changes.

@export var light_path: NodePath
@export var on_energy: float = 2.0
@export var off_energy: float = 0.0

var _light: Light3D = null


func _ready() -> void:
	super._ready()
	_light = get_node_or_null(light_path) as Light3D
	if _light == null:
		_light = _find_light(get_parent())
	_apply_power()


func _find_light(root: Node) -> Light3D:
	if root == null:
		return null
	for node in root.find_children("*", "Light3D", true, false):
		return node as Light3D
	return null


func _apply_power() -> void:
	if _light != null:
		_light.light_energy = on_energy if powered else off_energy
