class_name WaterToolComponent
extends UseComponent

## Held water tool. Primary fire adds water height where the player aims;
## secondary fire removes it. The brush exports are shown in the Property tab
## through the Useables inventory entry.

@export var description: String = (
	"Adds water height on primary fire and removes it on secondary fire. "
	+ "Aim at a floor, wall or existing water surface."
)
@export_range(0.5, 20.0, 0.25) var radius: float = 4.0
@export_range(0.05, 4.0, 0.05) var height_per_shot: float = 0.45
@export_range(2.0, 64.0, 1.0) var reach: float = 28.0
@export_range(0.1, 2.0, 0.05) var remove_scale: float = 0.75
@export var splash_on_use: bool = true


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if not can_use(actor):
		return
	begin_cooldown()
	var point := _aim_point(actor, origin, direction)
	var water := get_tree().get_first_node_in_group("water_world")
	if water == null:
		return
	water.call("add_water_height", point, radius, height_per_shot)
	if splash_on_use and water.has_method("spawn_splash"):
		water.call("spawn_splash", point, 1.0)


func alt_use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if not can_use(actor):
		return
	begin_cooldown()
	var point := _aim_point(actor, origin, direction)
	var water := get_tree().get_first_node_in_group("water_world")
	if water == null:
		return
	water.call(
		"remove_water_height",
		point,
		radius,
		height_per_shot * remove_scale
	)


func _aim_point(actor: Node, origin: Vector3, direction: Vector3) -> Vector3:
	var end := origin + direction.normalized() * reach
	if actor is Node3D:
		var world := (actor as Node3D).get_world_3d()
		if world != null:
			var query := PhysicsRayQueryParameters3D.create(origin, end)
			query.collide_with_bodies = true
			query.collide_with_areas = false
			if actor is CollisionObject3D:
				query.exclude = [(actor as CollisionObject3D).get_rid()]
			var hit: Dictionary = world.direct_space_state.intersect_ray(query)
			if not hit.is_empty():
				return hit.position
	return end
