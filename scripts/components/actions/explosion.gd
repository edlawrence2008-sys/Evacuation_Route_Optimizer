class_name Explosion
extends RefCounted

## Shared explosion/damage helper used by ExplosiveComponent, FireComponent,
## and any future weapon. Terrain removal is optional and capped so a large
## blast cannot freeze the game.

const MAX_TERRAIN_CELLS: int = 4096


static func explode(
	source: Node,
	center: Vector3,
	radius: float,
	damage: float,
	terrain_radius: float = 0.0
) -> void:
	damage_area(source, center, radius, damage)

	if terrain_radius > 0.0:
		_remove_terrain(source, center, terrain_radius)


## Applies damage to every HealthComponent/`take_damage` target in range.
static func damage_area(
	source: Node,
	center: Vector3,
	radius: float,
	damage: float
) -> void:
	var world := _world_of(source)
	if world == null or radius <= 0.0 or damage <= 0.0:
		return

	var sphere := SphereShape3D.new()
	sphere.radius = maxf(radius, 0.1)

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, center)
	query.collide_with_areas = false
	query.collide_with_bodies = true

	for hit in world.direct_space_state.intersect_shape(query, 64):
		var collider: Object = hit.get("collider")
		if collider is Node:
			_damage_node(collider as Node, damage)


static func _damage_node(node: Node, damage: float) -> void:
	var current := node

	while current != null:
		if current.has_method("take_damage"):
			current.call("take_damage", damage)
			return

		var health := current.get_node_or_null("HealthComponent")
		if health != null and health.has_method("take_damage"):
			health.call("take_damage", damage)
			return

		current = current.get_parent()


static func _remove_terrain(
	source: Node,
	center: Vector3,
	radius: float
) -> void:
	var tree := source.get_tree()
	if tree == null:
		return

	var grid := tree.get_first_node_in_group("grid_map") as GridMap
	if grid == null or not grid.has_method("remove_blocks"):
		return

	var cell_size: Vector3 = grid.cell_size
	var step := maxf(minf(cell_size.x, minf(cell_size.y, cell_size.z)), 0.01)
	var cell_radius := mini(int(ceil(radius / step)), 12)
	var center_cell: Vector3i = grid.world_to_cell(center)

	var cells: Array[Vector3i] = []

	for x in range(-cell_radius, cell_radius + 1):
		for y in range(-cell_radius, cell_radius + 1):
			for z in range(-cell_radius, cell_radius + 1):
				var cell := center_cell + Vector3i(x, y, z)
				var world_pos: Vector3 = grid.to_global(
					grid.map_to_local(cell)
				)
				if world_pos.distance_to(center) > radius:
					continue
				if grid.get_block_item(cell) == GridMap.INVALID_CELL_ITEM:
					continue

				cells.append(cell)
				if cells.size() >= MAX_TERRAIN_CELLS:
					break
			if cells.size() >= MAX_TERRAIN_CELLS:
				break
		if cells.size() >= MAX_TERRAIN_CELLS:
			break

	if not cells.is_empty():
		grid.call("remove_blocks", cells)


static func _world_of(source: Node) -> World3D:
	if source == null or not source.is_inside_tree():
		return null

	var scene := source.get_tree().current_scene
	if scene is Node3D:
		return (scene as Node3D).get_world_3d()

	return null
