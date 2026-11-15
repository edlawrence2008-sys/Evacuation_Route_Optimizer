class_name LogicDoorComponent
extends PoweredComponent

## Rotates a hinge Node3D when powered. Use for doors, gates, and shutters.

@export var hinge_path: NodePath
@export var open_rotation_degrees: Vector3 = Vector3(0.0, 90.0, 0.0)
@export var speed: float = 8.0

var _hinge: Node3D = null
var _closed_rotation: Vector3 = Vector3.ZERO
var _tween: Tween = null


func _ready() -> void:
	super._ready()
	_hinge = get_node_or_null(hinge_path) as Node3D
	if _hinge != null:
		_closed_rotation = _hinge.rotation
	_apply_power()


func _apply_power() -> void:
	if _hinge == null:
		return

	if _tween != null and _tween.is_valid():
		_tween.kill()

	var target := _closed_rotation
	if powered:
		target += Vector3(
			deg_to_rad(open_rotation_degrees.x),
			deg_to_rad(open_rotation_degrees.y),
			deg_to_rad(open_rotation_degrees.z)
		)

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(
		_hinge,
		"rotation",
		target,
		maxf(1.0 / maxf(speed, 0.01), 0.01)
	)
