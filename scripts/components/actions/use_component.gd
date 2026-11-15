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


func begin_cooldown() -> void:
	_next_use_msec = Time.get_ticks_msec() + int(
		maxf(cooldown, 0.0) * 1000.0
	)
