class_name FireComponent
extends BlockComponent

## Simple burning state with fuel, damage-over-time, and an extinguishable
## interface. Fires join the `fire` group so extinguishers and other systems can
## find them without scanning the whole scene.

signal state_changed(burning: bool)

@export var fuel: float = 8.0
@export var burn_rate: float = 1.0
@export var damage_per_second: float = 5.0
@export var damage_radius: float = 2.5
@export var tick_interval: float = 0.5
@export var fire_effect_scene: PackedScene

var burning: bool = false

var _tick: float = 0.0
var _effect: Node3D = null


func _ready() -> void:
	add_to_group("fire")
	set_process(false)


func ignite() -> void:
	if burning:
		return

	burning = true
	_tick = 0.0
	set_process(true)
	state_changed.emit(true)

	if fire_effect_scene != null:
		_effect = fire_effect_scene.instantiate() as Node3D
		if _effect != null:
			var owner_node := get_parent()
			get_tree().current_scene.add_child(_effect)
			if owner_node is Node3D:
				_effect.global_position = (owner_node as Node3D).global_position


func extinguish(amount: float = 999.0) -> void:
	if not burning:
		return

	fuel -= amount
	if fuel <= 0.0:
		_stop()


func _stop() -> void:
	burning = false
	set_process(false)
	state_changed.emit(false)

	if _effect != null and is_instance_valid(_effect):
		_effect.queue_free()
	_effect = null


func _process(delta: float) -> void:
	if not burning:
		return

	fuel -= burn_rate * delta
	if fuel <= 0.0:
		_stop()
		return

	_tick += delta
	if _tick < tick_interval:
		return

	_tick = 0.0
	var owner_node := get_parent()
	if owner_node is Node3D:
		Explosion.damage_area(
			self,
			(owner_node as Node3D).global_position,
			damage_radius,
			damage_per_second * tick_interval
		)
