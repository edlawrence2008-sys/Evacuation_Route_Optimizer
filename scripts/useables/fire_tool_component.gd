class_name FireToolComponent
extends UseComponent

## Held igniter. Primary fire ignites sub-level cells or a FireComponent
## placeable under the crosshair. Fire on a sub-level spreads through its local
## cells, damages nearby health targets, and consumes the burning cells.

@export var description: String = (
	"Primary fire ignites any world block, sub-level cell, or fire-enabled "
	+ "placeable. Fuel keeps burning; concrete and other non-fuel surfaces "
	+ "self-extinguish."
)
@export_range(2.0, 128.0, 1.0) var reach: float = 32.0


func _ready() -> void:
	cooldown = maxf(cooldown, 0.05)


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if not can_use(actor):
		return
	begin_cooldown()

	var from: Vector3 = origin
	var to: Vector3 = from + direction.normalized() * reach
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true

	if actor is CollisionObject3D:
		query.exclude = [(actor as CollisionObject3D).get_rid()]

	var hit: Dictionary = actor.get_world_3d().direct_space_state.intersect_ray(
		query
	)
	if hit.is_empty():
		return

	var collider: Object = hit.get("collider")
	if collider is Node:
		var sublevel := _find_sublevel(collider as Node)
		if sublevel != null:
			sublevel.ignite_at_world(hit.get("position", to))
			return

		var fire := _find_fire(collider as Node)
		if fire != null:
			fire.ignite()
			return

		# Ordinary world blocks use the grid's WorldFire manager.
		var world_fire := actor.get_tree().get_first_node_in_group("world_fire")
		if world_fire != null:
			world_fire.call(
				"ignite_at_hit",
				hit.get("position", to),
				hit.get("normal", Vector3.UP)
			)


func _find_sublevel(node: Node) -> SubLevel:
	var current := node
	while current != null:
		if current is SubLevel:
			return current as SubLevel
		current = current.get_parent()
	return null


func _find_fire(node: Node) -> FireComponent:
	var current := node
	while current != null:
		if current is FireComponent:
			return current as FireComponent
		var fire := current.get_node_or_null("FireComponent") as FireComponent
		if fire != null:
			return fire
		current = current.get_parent()
	return null
