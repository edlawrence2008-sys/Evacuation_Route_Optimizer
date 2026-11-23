class_name FalseBoidPerch
extends Node3D

## A designated landing spot for a FalseBoidFlock. The flock claims and
## releases slots as it promotes particles into perched sprites and demotes
## them when they flee. Keep these nodes outside the particle system: a perch
## is a real point in the world, not a particle force target.

@export_range(1, 12, 1) var capacity: int = 3
## Radius of the ring used to lay out multiple birds on one perch.
@export var slot_radius: float = 0.8
## Vertical jitter between slots, metres.
@export var slot_height: float = 0.12

var _occupied: Array[bool] = []


func _ready() -> void:
	add_to_group(&"false_boid_perches")
	_resize_slots()


func _resize_slots() -> void:
	var wanted: int = maxi(capacity, 1)

	if _occupied.size() != wanted:
		_occupied.resize(wanted)
		_occupied.fill(false)


func available_slots() -> int:
	var free_count: int = 0

	for occupied: bool in _occupied:
		if not occupied:
			free_count += 1

	return free_count


## Claims the lowest free slot. Returns -1 when the perch is full.
func claim_slot() -> int:
	_resize_slots()

	for index: int in range(_occupied.size()):
		if not _occupied[index]:
			_occupied[index] = true
			return index

	return -1


func release_slot(index: int) -> void:
	if index < 0 or index >= _occupied.size():
		return

	_occupied[index] = false


## World-space position for a claimed slot.
func slot_position(index: int) -> Vector3:
	var count: int = maxi(_occupied.size(), 1)
	var angle: float = TAU * float(index) / float(count)
	var offset := Vector3(
		cos(angle) * slot_radius,
		float(index % 2) * slot_height,
		sin(angle) * slot_radius
	)

	return to_global(offset)
