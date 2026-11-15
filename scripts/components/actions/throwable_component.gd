class_name ThrowableComponent
extends UseComponent

## Throwable bombs, grenades, and similar. The projectile scene should contain a
## ProjectileComponent and usually an ExplosiveComponent.

signal thrown(actor: Node, projectile: Node)

@export var projectile_scene: PackedScene
@export var throw_speed: float = 14.0
## Upward bias added to the aim vector (0.15 ≈ 9 degrees).
@export_range(0.0, 1.0, 0.01) var upward_bias: float = 0.12
@export var ammo: int = -1


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if projectile_scene == null or not can_use(actor):
		return
	if ammo == 0:
		return

	begin_cooldown()
	if ammo > 0:
		ammo -= 1

	var launch_direction := (direction.normalized() + Vector3.UP * upward_bias).normalized()
	var spawn := origin + direction.normalized() * 0.4

	var projectile := projectile_scene.instantiate()
	actor.get_tree().current_scene.add_child(projectile)

	if projectile is Node3D:
		(projectile as Node3D).global_position = spawn

	if projectile.has_method("launch"):
		projectile.call("launch", spawn, launch_direction, throw_speed)

	thrown.emit(actor, projectile)
