class_name VoxelCellHost
extends RefCounted

## Thin adapter over the two cell containers in the project:
##   - NavGridMap: streamed world blocks
##   - SubLevel:   local cells on a moving RigidBody3D
##
## The build controller's shape/surface code talks to this interface instead of
## branching on GridMap vs SubLevel for every brush. The storage/collision hosts
## remain different for the reasons in docs/SUB_LEVELS.md, but cell reads,
## world/local conversion and the flood-fill tools are shared.

const DIRS_6: Array[Vector3i] = [
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

var _host: Node


func _init(host_node: Node) -> void:
	_host = host_node


func is_valid() -> bool:
	return _host != null and is_instance_valid(_host)


func has_cell(cell: Vector3i) -> bool:
	if _host is SubLevel:
		return (_host as SubLevel).cells.has(cell)
	if _host is NavGridMap:
		return (_host as NavGridMap).has_block(cell)
	return false


func item_at(cell: Vector3i) -> int:
	if _host is SubLevel:
		var entry: Dictionary = (_host as SubLevel).cells.get(cell, {})
		return int(entry.get("item", -1))
	if _host is NavGridMap:
		return int((_host as NavGridMap).get_block_item(cell))
	return -1


func orientation_at(cell: Vector3i) -> int:
	if _host is SubLevel:
		var entry: Dictionary = (_host as SubLevel).cells.get(cell, {})
		return int(entry.get("orientation", 0))
	if _host is NavGridMap:
		return int((_host as NavGridMap).get_block_orientation(cell))
	return 0


func cell_center(cell: Vector3i) -> Vector3:
	if _host is SubLevel:
		var sub := _host as SubLevel
		return sub.to_global(sub.cell_center_local(cell))
	if _host is NavGridMap:
		var grid := _host as NavGridMap
		return grid.to_global(grid.map_to_local(cell))
	return Vector3.ZERO


func world_to_cell(world_position: Vector3) -> Vector3i:
	if _host is SubLevel:
		return (_host as SubLevel).local_cell_at_world(world_position)
	if _host is NavGridMap:
		return (_host as NavGridMap).world_to_cell(world_position)
	return Vector3i.ZERO


func cell_size() -> Vector3:
	if _host is SubLevel:
		return (_host as SubLevel).block_size
	if _host is NavGridMap:
		return (_host as NavGridMap).cell_size
	return Vector3.ONE


func cell_aabb(cell: Vector3i) -> AABB:
	var size := cell_size()
	return AABB(cell_center(cell) - size * 0.5, size)


## Shared Surface flood fill. `replace_mode` means the tool acts on solid cells
## (Replace/Clear/Flatten); otherwise it fills exposed empty cells on the face
## side. `host` may be a NavGridMap or SubLevel.
static func surface_cells(
	host: VoxelCellHost,
	target_cell: Vector3i,
	face: Vector3i,
	target_item: int,
	replace_mode: bool,
	radius: int
) -> Array[Vector3i]:
	if host == null or not host.is_valid() or target_item < 0:
		return []

	var axis := _face_axis(face)
	var start: Vector3i = target_cell if replace_mode else target_cell + face
	var offsets: Array[Vector3i] = []

	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var offset := Vector3i(dx, dy, dz)
				if offset == Vector3i.ZERO:
					continue
				if offset[axis] != 0:
					continue
				if absi(dx) + absi(dy) + absi(dz) > 1:
					continue
				offsets.append(offset)

	var visited: Dictionary = {}
	var frontier: Array[Vector3i] = [start]
	var result: Array[Vector3i] = []

	while not frontier.is_empty():
		var current: Vector3i = frontier.pop_front()
		if visited.has(current):
			continue
		visited[current] = true
		if (current - start).length_squared() > radius * radius:
			continue

		if replace_mode:
			if not host.has_cell(current):
				continue
			if host.item_at(current) != target_item:
				continue
			if host.has_cell(current + face):
				continue
			result.append(current)
		else:
			if host.has_cell(current):
				continue
			var behind := current - face
			if not host.has_cell(behind):
				continue
			if host.item_at(behind) != target_item:
				continue
			result.append(current)

		for offset: Vector3i in offsets:
			frontier.append(current + offset)

	return result


## Shared Cluster flood fill: connected occupied cells of the same material.
static func cluster_cells(
	host: VoxelCellHost,
	target_cell: Vector3i,
	target_item: int,
	radius: int
) -> Array[Vector3i]:
	if host == null or not host.is_valid() or target_item < 0:
		return []

	var visited: Dictionary = {}
	var frontier: Array[Vector3i] = [target_cell]
	var result: Array[Vector3i] = []

	while not frontier.is_empty():
		var current: Vector3i = frontier.pop_front()
		if visited.has(current):
			continue
		visited[current] = true
		if (current - target_cell).length_squared() > radius * radius:
			continue
		if not host.has_cell(current):
			continue
		if host.item_at(current) != target_item:
			continue
		result.append(current)
		for offset: Vector3i in DIRS_6:
			frontier.append(current + offset)

	return result


static func _face_axis(face: Vector3i) -> int:
	if absi(face.x) > 0:
		return 0
	if absi(face.y) > 0:
		return 1
	return 2
