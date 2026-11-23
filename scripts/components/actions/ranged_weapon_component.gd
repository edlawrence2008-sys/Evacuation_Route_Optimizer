class_name RangedWeaponComponent
extends UseComponent

## Flare guns, dart guns, and other projectile launchers. The projectile scene
## should contain a ProjectileComponent (and optionally an ExplosiveComponent or
## FireComponent) plus its own visuals.

signal fired(actor: Node, projectile: Node)

@export var projectile_scene: PackedScene
@export var projectile_speed: float = 30.0
## Maximum random deviation from the aim direction, in degrees.
@export_range(0.0, 30.0, 0.1) var spread_degrees: float = 0.5
## -1 = infinite.
@export var ammo: int = -1
@export var muzzle_distance: float = 0.45


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if projectile_scene == null or not can_use(actor):
		return
	if ammo == 0:
		return

	begin_cooldown()
	if ammo > 0:
		ammo -= 1

	var launch_direction := _spread(direction)
	var muzzle := origin + launch_direction * muzzle_distance

	var projectile := projectile_scene.instantiate()
	actor.get_tree().current_scene.add_child(projectile)

	if projectile is Node3D:
		(projectile as Node3D).global_position = muzzle

	if projectile.has_method("launch"):
		projectile.call("launch", muzzle, launch_direction, projectile_speed)

	fired.emit(actor, projectile)


func _spread(direction: Vector3) -> Vector3:
	var result := direction.normalized()
	if spread_degrees <= 0.0:
		return result

	var up := Vector3.UP
	if absf(result.dot(up)) > 0.99:
		up = Vector3.FORWARD

	var side := result.cross(up).normalized()
	up = side.cross(result).normalized()

	result = result.rotated(up, deg_to_rad(randf_range(
		-spread_degrees, spread_degrees
	)))
	result = result.rotated(side, deg_to_rad(randf_range(
		-spread_degrees, spread_degrees
	)))
	return result.normalized()
