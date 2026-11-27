class_name UseComponent
extends BlockComponent

## Base for held tools: ranged weapons, extinguishers, throwables, and similar.
## `use()` is called by the build controller while the owning placeable scene is
## selected in the hotbar. Components must work even when the scene is only
## instantiated for inspection and never added to the tree, so use timestamps
## instead of `_process` for cooldowns.

@export var cooldown: float = 0.4

var _next_use_msec: int = 0


func can_use(_actor: Node) -> bool:
	return Time.get_ticks_msec() >= _next_use_msec


func use(_actor: Node, _origin: Vector3, _direction: Vector3) -> void:
	pass


func alt_use(_actor: Node, _origin: Vector3, _direction: Vector3) -> void:
	pass


## Called every physics frame while the primary-use button is held. The base
## tool is one-shot, so the default is a no-op.
func hold(
	_actor: Node,
	_origin: Vector3,
	_direction: Vector3,
	_delta: float
) -> void:
	pass


## Called when the primary-use button is released.
func release(_actor: Node) -> void:
	pass


## Q while the tool is selected. Return true when the tool consumed the input.
func rotate_held(_actor: Node, _step_degrees: float) -> bool:
	return false


func begin_cooldown() -> void:
	_next_use_msec = Time.get_ticks_msec() + int(
		maxf(cooldown, 0.0) * 1000.0
	)
