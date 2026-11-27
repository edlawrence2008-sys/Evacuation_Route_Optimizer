class_name PhysicsGunComponent
extends UseComponent

## GMod-style physics gun held from the Useables tab. It is deliberately
## separate from the G-key grab: primary holds a RigidBody3D with gravity
## cancelled and its rotation axis-locked, while the beam is drawn from the gun
## model's emitter. Release throws it. Secondary freezes/unfreezes the held (or
## aimed) body; Q rotates the held body around the view axis.

@export var description: String = (
	"Primary grabs and holds a physics body with an axis-locked beam from the "
	+ "gun's emitter; release to throw it. Secondary freezes or unfreezes the "
	+ "body. Q rotates the held body."
)


func use(_actor: Node, _origin: Vector3, _direction: Vector3) -> void:
	var controller := _controller()
	if controller != null:
		controller.call("begin_gun_hold")


func alt_use(_actor: Node, _origin: Vector3, _direction: Vector3) -> void:
	var controller := _controller()
	if controller != null:
		controller.call("toggle_gun_freeze")


func hold(
	_actor: Node,
	_origin: Vector3,
	_direction: Vector3,
	delta: float
) -> void:
	var controller := _controller()
	if controller != null:
		controller.call("hold_gun", delta)


func release(_actor: Node) -> void:
	var controller := _controller()
	if controller != null:
		controller.call("end_gun_hold")


func rotate_held(_actor: Node, step_degrees: float) -> bool:
	var controller := _controller()
	if controller == null:
		return false
	return bool(controller.call("rotate_gun_held", step_degrees))


func _controller() -> Node:
	var parent := get_parent()
	if parent != null and parent.has_method("begin_gun_hold"):
		return parent
	return null
