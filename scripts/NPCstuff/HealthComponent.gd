# HealthComponent.gd
extends Node
class_name HealthComponent

signal health_changed(current_health: float, max_health: float)
signal health_depleted
signal damaged(amount: float)
signal healed(amount: float)

@export var max_health: float = 100.0

var current_health: float


func _ready() -> void:
	current_health = max_health


func take_damage(amount: float) -> void:
	if current_health <= 0.0 or amount <= 0.0:
		return

	current_health = clampf(current_health - amount, 0.0, max_health)
	damaged.emit(amount)
	health_changed.emit(current_health, max_health)

	if current_health <= 0.0:
		health_depleted.emit()


func heal(amount: float) -> void:
	if current_health <= 0.0 or amount <= 0.0:
		return # Can't heal the dead or apply 0/negative healing

	current_health = clampf(current_health + amount, 0.0, max_health)
	healed.emit(amount)
	health_changed.emit(current_health, max_health)


func get_health_percent() -> float:
	if max_health <= 0.0:
		return 0.0
	return (current_health / max_health) * 100.0
