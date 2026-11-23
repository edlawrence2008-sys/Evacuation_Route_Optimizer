class_name ProjectileComponent
extends Node3D

## Simple, reusable projectile body. Put it on the root of a projectile scene
## (bomb, flare, grenade) with the visual nodes as children. On impact it
## detonates/ignites components on the projectile or the hit object.

@export var speed: float = 20.0
@export var gravity: float = 9.8
@export var lifetime: float = 8.0
@export var impact_effect_scene: PackedScene
@export var collide_with_areas: bool = true
@export var collide_with_bodies: bool = true

var velocity: Vector3 = Vector3.ZERO

var _life: float = 0.0
var _launched: bool = false


func _ready() -> void:
	add_to_group("projectiles")


func launch(
	origin: Vector3,
	direction: Vector3,
	speed_override: float = 0.0
) -> void:
	global_position = origin
	velocity = direction.normalized() * (
		speed_override if speed_override > 0.0 else speed
	)
	_life = 0.0
	_launched = true


func _physics_process(delta: float) -> void:
	if not _launched:
		return

	_life += delta
	if _life >= lifetime:
		_impact({})
		return

	var from := global_position
	var to := from + velocity * delta
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = collide_with_areas
	query.collide_with_bodies = collide_with_bodies

	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		global_position = hit["position"]
		_impact(hit)
		return

	global_position = to
	velocity.y -= gravity * delta


func _impact(hit: Dictionary) -> void:
	if impact_effect_scene != null:
		var effect := impact_effect_scene.instantiate()
		get_tree().current_scene.add_child(effect)
		if effect is Node3D:
			(effect as Node3D).global_position = global_position

	# The projectile's own components (bomb/TNT).
	_trigger_components(self)

	# Chain reactions: hitting an armed explosive or a fire source.
	var collider: Object = hit.get("collider")
	if collider is Node:
		var target := _find_placeable(collider as Node)
		if target != null:
			_trigger_components(target)

	queue_free()


func _trigger_components(root: Node) -> void:
	if root == null:
		return

	for node in root.find_children("*", "", true, false):
		if node is ExplosiveComponent:
			(node as ExplosiveComponent).detonate()
		elif node is FireComponent and not (node as FireComponent).burning:
			(node as FireComponent).ignite()


func _find_placeable(node: Node) -> Node:
	var current := node
	while current != null:
		if current.is_in_group("placeables"):
			return current
		current = current.get_parent()
	return null
