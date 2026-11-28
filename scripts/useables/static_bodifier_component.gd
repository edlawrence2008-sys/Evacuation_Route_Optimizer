class_name StaticBodifierComponent
extends UseComponent

## Held tool that turns a moving SubLevel into normal world cells. Unlike the
## physics gun's temporary freeze, this removes the rigid body and writes its
## blocks into the world grid, so navigation, authored routes, the optimizer and
## the normal map save all see it as static map geometry.

@export var description: String = (
	"Primary fire converts the aimed sub-level into permanent world blocks. "
	+ "The result is navigation terrain, appears in routes and the optimizer, "
	+ "and is saved with the map. This is not the physics gun's temporary freeze."
)
@export_range(2.0, 128.0, 1.0) var reach: float = 32.0


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if not can_use(actor):
		return
	begin_cooldown()

	var from: Vector3 = origin
	var to: Vector3 = from + direction.normalized() * reach
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.collision_mask = 1 | SubLevel.SUBLEVEL_LAYER

	if actor is CollisionObject3D:
		query.exclude = [(actor as CollisionObject3D).get_rid()]

	var hit: Dictionary = actor.get_world_3d().direct_space_state.intersect_ray(
		query
	)
	if hit.is_empty():
		return

	var sublevel := _find_sublevel(hit.get("collider"))
	if sublevel == null:
		return

	var grid := get_tree().get_first_node_in_group("grid_map")
	if grid == null or not grid.has_method("get_sublevel_manager"):
		return
	var manager: Variant = grid.call("get_sublevel_manager")
	if manager == null or not manager.has_method("staticify"):
		return

	# Release any gun hold before the body is removed, so the controller does
	# not keep a freed rigid-body reference.
	var controller := get_parent()
	if controller != null and controller.has_method("end_gun_hold"):
		controller.call("end_gun_hold")

	var converted: int = int(manager.call("staticify", sublevel))
	if converted > 0:
		print("Static Bodifier: converted %d cell(s) to world blocks." % converted)


func _find_sublevel(node: Variant) -> SubLevel:
	var current := node as Node
	while current != null:
		if current is SubLevel:
			return current as SubLevel
		current = current.get_parent()
	return null
