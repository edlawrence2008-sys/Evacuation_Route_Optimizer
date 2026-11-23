class_name ExplosiveComponent
extends BlockComponent

## TNT blocks, bombs, and any placeable that should explode. `arm()` starts the
## fuse; `detonate()` can also be called directly by a projectile or logic gate.

signal armed
signal detonated

@export var fuse_time: float = 2.5
@export var radius: float = 4.0
@export var terrain_radius: float = 1.5
@export var damage: float = 120.0
@export var effect_scene: PackedScene
@export var arm_on_ready: bool = false
@export var destroy_owner: bool = true
## Automatically arm when an InteractableComponent sibling is used.
@export var arm_on_interact: bool = true

var _armed: bool = false
var _time: float = 0.0


func _ready() -> void:
	if arm_on_ready:
		arm()
	elif arm_on_interact:
		var interactable := ComponentLookup.find_interactable(get_parent())
		if interactable != null:
			interactable.interacted.connect(_on_interacted)


func _on_interacted(_actor: Node) -> void:
	if _armed:
		return
	arm()


func arm() -> void:
	if _armed:
		return

	_armed = true
	_time = 0.0
	set_process(true)
	armed.emit()


func is_armed() -> bool:
	return _armed


func _process(delta: float) -> void:
	if not _armed:
		return

	_time += delta
	if _time >= fuse_time:
		detonate()


func detonate() -> void:
	_armed = false
	set_process(false)

	var owner_node := get_parent()
	var center := Vector3.ZERO
	if owner_node is Node3D:
		center = (owner_node as Node3D).global_position

	if effect_scene != null:
		var effect := effect_scene.instantiate()
		get_tree().current_scene.add_child(effect)
		if effect is Node3D:
			(effect as Node3D).global_position = center

	Explosion.explode(self, center, radius, damage, terrain_radius)
	detonated.emit()

	if destroy_owner and owner_node != null:
		owner_node.queue_free()
