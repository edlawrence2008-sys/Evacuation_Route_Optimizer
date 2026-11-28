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
	+ "body. Q rotates the held body. Reach defaults to the build reach; "
	+ "Ignore Collision While Held lets a blocked prop pass through geometry."
)
## 0 uses the BuildController's normal build reach. A positive value overrides
## it for this tool.
@export_range(0.0, 512.0, 1.0) var reach_override: float = 0.0
## When true, the held body ignores world and body collision while held. It can
## be pulled through walls instead of stopping against them; collision is
## restored on release.
@export var ignore_collision_while_held: bool = false


func use(_actor: Node, _origin: Vector3, _direction: Vector3) -> void:
	var controller := _controller()
	if controller != null:
		controller.call(
			"begin_gun_hold",
			reach_override,
			ignore_collision_while_held
		)


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
