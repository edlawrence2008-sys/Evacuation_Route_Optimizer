class_name ExtinguisherComponent
extends UseComponent

## Fire extinguisher. Sprays a cone in front of the player and removes fuel from
## every FireComponent in range.

signal sprayed(origin: Vector3, direction: Vector3)

@export var range: float = 4.5
@export_range(1.0, 180.0, 1.0) var cone_degrees: float = 45.0
@export var power: float = 8.0
@export var spray_effect_scene: PackedScene


func use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	if not can_use(actor):
		return

	begin_cooldown()
	var aim := direction.normalized()
	var cos_limit := cos(deg_to_rad(cone_degrees * 0.5))

	for node in actor.get_tree().get_nodes_in_group("fire"):
		var fire := node as FireComponent
		if fire == null or not fire.burning:
			continue

		var owner_node := fire.get_parent()
		if not (owner_node is Node3D):
			continue

		var target := (owner_node as Node3D).global_position - origin
		if target.length() > range:
			continue
		if target.length_squared() > 0.0001:
			if aim.dot(target.normalized()) < cos_limit:
				continue

		fire.extinguish(power)

	if spray_effect_scene != null:
		var effect := spray_effect_scene.instantiate()
		actor.get_tree().current_scene.add_child(effect)
		if effect is Node3D:
			(effect as Node3D).global_position = origin

	sprayed.emit(origin, aim)


func alt_use(actor: Node, origin: Vector3, direction: Vector3) -> void:
	use(actor, origin, direction)
