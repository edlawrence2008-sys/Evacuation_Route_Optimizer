class_name ContainerComponent
extends BlockComponent

## Shared storage component. It implements the same duck-typed container API as
## the hotbar (`container_slot_count`, `container_get_slot`,
## `container_set_slot`, `container_take_slot`), so chests, crates, and future
## storage blocks can reuse the drag/drop code without special cases.

signal contents_changed(index: int)
signal opened(actor: Node)

@export var slot_count: int = 9
@export var title: String = "Container"

var _slots: Array[Dictionary] = []


func _ready() -> void:
	_ensure_slots()


func _ensure_slots() -> void:
	var target := maxi(slot_count, 0)

	while _slots.size() < target:
		_slots.append({})

	if _slots.size() > target:
		_slots.resize(target)


func can_interact(_actor: Node) -> bool:
	return true


func interact(actor: Node) -> void:
	opened.emit(actor)


func container_slot_count() -> int:
	_ensure_slots()
	return _slots.size()


func container_get_slot(index: int) -> Dictionary:
	_ensure_slots()
	if index < 0 or index >= _slots.size():
		return {}
	return _slots[index].duplicate(true)


## Places `data` in the slot and returns the item that was there before.
func container_set_slot(index: int, data: Dictionary) -> Dictionary:
	_ensure_slots()
	if index < 0 or index >= _slots.size():
		return {}

	var previous := _slots[index].duplicate(true)
	_slots[index] = data.duplicate(true)
	contents_changed.emit(index)
	return previous


## Removes and returns the slot's item, leaving the slot empty.
func container_take_slot(index: int) -> Dictionary:
	var data := container_get_slot(index)
	if data.is_empty():
		return {}

	container_set_slot(index, {})
	return data


func serialize() -> Dictionary:
	return {"slots": _slots.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	var saved: Variant = data.get("slots", [])
	if saved is Array:
		_slots.clear()
		for entry: Variant in saved:
			_slots.append(
				entry.duplicate(true) if entry is Dictionary else {}
			)
	_ensure_slots()
