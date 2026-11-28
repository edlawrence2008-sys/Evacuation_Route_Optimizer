class_name DupeGunComponent
extends UseComponent

## GMod-style dupe gun for sub-levels. Aim at a moving structure and press
## primary fire to create a copy of its local cells, orientation and attached
## placeables in front of the camera. The copy is a normal editable SubLevel and
## is saved with the map's sub-level list.

@export var description: String = (
	"Primary fire duplicates the aimed sub-level, including its cells, "
	+ "orientation and attached placeables. The copy is a normal editable "
	+ "structure and is saved with the map."
)
@export_range(2.0, 128.0, 1.0) var reach: float = 32.0
## Minimum gap added in front of the original body.
@export_range(0.5, 20.0, 0.25) var copy_gap: float = 1.5


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
	if manager == null or not manager.has_method("duplicate_sublevel"):
		return

	var size := sublevel.world_aabb().size.length()
	var offset := (
		direction.normalized() * (maxf(size * 0.75, copy_gap) + 1.0)
	)
	var copy: Variant = manager.call("duplicate_sublevel", sublevel, offset)
	if copy != null:
		print("Dupe Gun: duplicated sub-level.")


func _find_sublevel(node: Variant) -> SubLevel:
	var current := node as Node
	while current != null:
		if current is SubLevel:
			return current as SubLevel
		current = current.get_parent()
	return null
