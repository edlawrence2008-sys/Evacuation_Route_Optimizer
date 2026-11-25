class_name GasToolComponent
extends UseComponent

## Held LPG/smoke tool for testing and authoring the hazard CA. Primary fire
## releases gas at the aim point; secondary fire releases smoke.

@export var description: String = (
	"Primary fire releases LPG-like gas at the aim point. "
	+ "Secondary fire releases smoke. Both are block CA fields."
)
@export_range(0.1, 10.0, 0.1) var amount: float = 1.0
@export_range(0.5, 12.0, 0.25) var radius: float = 2.0
@export_range(2.0, 64.0, 1.0) var range: float = 24.0


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if not can_use(actor):
		return
	begin_cooldown()
	var hazard := get_tree().get_first_node_in_group("hazard_world")
	if hazard != null:
		hazard.call("add_gas", _aim_point(actor, origin, direction), amount, radius)


func alt_use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if not can_use(actor):
		return
	begin_cooldown()
	var hazard := get_tree().get_first_node_in_group("hazard_world")
	if hazard != null:
		hazard.call("add_smoke", _aim_point(actor, origin, direction), amount, radius)


func _aim_point(actor: Node, origin: Vector3, direction: Vector3) -> Vector3:
	var end := origin + direction.normalized() * range
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
