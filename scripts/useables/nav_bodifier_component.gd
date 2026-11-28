class_name NavBodifierComponent
extends UseComponent

## Freezes an aimed sub-level as a diagonal map piece and bakes an invisible
## navigation grid along its walkable top surface. The body keeps its exact
## visual/collision shape; the markers let the existing grid A*, authored routes
## and optimizer route across it as normal walkable cells.
##
## Secondary fire removes the markers and unfreezes the body.

@export var description: String = (
	"Primary fire freezes the aimed sub-level in place and bakes an invisible "
	+ "navigation grid over its walkable surfaces. The diagonal shape and "
	+ "collision stay; members, routes and the optimizer can use it as map "
	+ "terrain. Secondary fire removes the nav grid and unfreezes it."
)
@export_range(2.0, 128.0, 1.0) var reach: float = 32.0


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	_apply(actor, origin, direction, true)


func alt_use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	_apply(actor, origin, direction, false)


func _apply(
	actor: Node,
	origin: Vector3,
	direction: Vector3,
	bake: bool
) -> void:
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
	if manager == null:
		return

	var controller := get_parent()
	if controller != null and controller.has_method("end_gun_hold"):
		controller.call("end_gun_hold")

	if bake:
		var placed: int = int(manager.call("bake_nav", sublevel))
		if placed > 0:
			print("Nav Bodifier: baked %d nav cell(s)." % placed)
	else:
		var removed: int = int(manager.call("unbake_nav", sublevel))
		print("Nav Bodifier: removed %d nav cell(s)." % removed)


func _find_sublevel(node: Variant) -> SubLevel:
	var current := node as Node
	while current != null:
		if current is SubLevel:
			return current as SubLevel
		current = current.get_parent()
	return null
