class_name BlockUVMapper
extends RefCounted

## Replaces BoxMesh UVs with a cell-space planar projection. Full blocks keep
## the full texture; slabs and stairs sample the part of the texture that lies
## under each face instead of stretching the whole image across a partial face.

const CELL_SIZE := Vector3(1.0, 1.0, 1.0)
const SYNC_SCRIPT := preload("res://scripts/block_mesh_library_sync.gd")


static func apply(arrays: Array, cell_size: Vector3 = CELL_SIZE) -> void:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

	if vertices.is_empty() or normals.size() != vertices.size():
		return

	var half := cell_size * 0.5
	var uvs := PackedVector2Array()
	uvs.resize(vertices.size())

	for index in vertices.size():
		var point := vertices[index]
		var normal := normals[index]
		var u: float = 0.0
		var v: float = 0.0

		if absf(normal.x) > 0.5:
			u = (point.z + half.z) / cell_size.z
			v = (half.y - point.y) / cell_size.y
			if normal.x < 0.0:
				u = 1.0 - u
		elif absf(normal.z) > 0.5:
			u = (point.x + half.x) / cell_size.x
			v = (half.y - point.y) / cell_size.y
			if normal.z < 0.0:
				u = 1.0 - u
		else:
			u = (point.x + half.x) / cell_size.x
			v = (point.z + half.z) / cell_size.z
			if normal.y < 0.0:
				v = 1.0 - v

		uvs[index] = Vector2(
			clampf(u, 0.0, 1.0),
			clampf(v, 0.0, 1.0)
		)

	arrays[Mesh.ARRAY_TEX_UV] = uvs


static func remap_mesh(mesh: Mesh, cell_size: Vector3 = CELL_SIZE) -> ArrayMesh:
	var remapped := ArrayMesh.new()

	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)

		if arrays.is_empty():
			continue

		apply(arrays, cell_size)
		remapped.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			arrays
		)

		var material: Material = mesh.surface_get_material(surface_index)
		if material != null:
			remapped.surface_set_material(surface_index, material)

	return remapped


## Rebuilds a mesh with scaled vertices and cell-space UVs.
static func scale_mesh(
	mesh: Mesh,
	factors: Vector3,
	cell_size: Vector3 = CELL_SIZE
) -> ArrayMesh:
	var remapped := ArrayMesh.new()

	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)

		if arrays.is_empty():
			continue

		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for index in vertices.size():
			vertices[index] *= factors
		arrays[Mesh.ARRAY_VERTEX] = vertices

		apply(arrays, cell_size)
		remapped.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			arrays
		)

		var material: Material = mesh.surface_get_material(surface_index)
		if material != null:
			remapped.surface_set_material(surface_index, material)

	return remapped


## One-shot migration from the old 1.5 m blocks to the current 1.0 m voxel.
static func rescale_project(
	blocks_scene_path: String,
	mesh_library_path: String,
	factors: Vector3
) -> Dictionary:
	var packed := load(blocks_scene_path) as PackedScene

	if packed == null:
		return {"scaled": 0, "synced": 0, "error": "missing blocks scene"}

	var root := packed.instantiate() as Node3D

	if root == null:
		return {"scaled": 0, "synced": 0, "error": "invalid blocks root"}

	var scaled: int = 0

	for child: Node in root.get_children():
		var mesh_node := child as MeshInstance3D

		if mesh_node == null or mesh_node.mesh == null:
			continue

		mesh_node.mesh = scale_mesh(mesh_node.mesh, factors, CELL_SIZE)
		scaled += 1

		var node_transform := mesh_node.transform
		node_transform.origin *= factors
		mesh_node.transform = node_transform

		for body_child: Node in mesh_node.get_children():
			var body := body_child as StaticBody3D

			if body == null:
				continue

			var body_transform := body.transform
			body_transform.origin *= factors
			body.transform = body_transform

			for shape_child: Node in body.get_children():
				var shape_node := shape_child as CollisionShape3D

				if shape_node == null or shape_node.shape == null:
					continue

				shape_node.shape = _scale_shape(shape_node.shape, factors)
				shape_node.position *= factors

	var scene := PackedScene.new()
	var pack_error := scene.pack(root)

	if pack_error != OK:
		root.free()
		return {"scaled": scaled, "synced": 0, "error": "pack failed"}

	var save_error := ResourceSaver.save(scene, blocks_scene_path)

	if save_error != OK:
		root.free()
		return {"scaled": scaled, "synced": 0, "error": "save failed"}

	var synced: int = SYNC_SCRIPT.sync_from_blocks(root, mesh_library_path)
	root.free()
	return {"scaled": scaled, "synced": synced, "error": ""}


static func _scale_shape(shape: Shape3D, factors: Vector3) -> Shape3D:
	var scaled := shape.duplicate() as Shape3D

	if scaled is BoxShape3D:
		scaled.size *= factors
	elif scaled is SphereShape3D:
		scaled.radius *= factors.x
	elif scaled is CapsuleShape3D:
		scaled.radius *= factors.x
		scaled.height *= factors.y
	elif scaled is CylinderShape3D:
		scaled.radius *= factors.x
		scaled.height *= factors.y
	elif scaled is ConcavePolygonShape3D:
		var faces: PackedVector3Array = scaled.get_faces()
		for index in faces.size():
			faces[index] *= factors
		scaled.set_faces(faces)
	elif scaled is ConvexPolygonShape3D:
		var points: PackedVector3Array = scaled.points
		for index in points.size():
			points[index] *= factors
		scaled.points = points

	return scaled


## One-shot repair for collision shapes that were authored at an older block
## size. A collider larger than its visual mesh makes the build ray stop on the
## invisible collider, which reports the empty neighbour cell as the hit cell;
## the placement ghost then appears one cell away from the face being aimed at.
##
## - Stairs get the current two-box step collider rebuilt from `cell_size`.
## - Full-cube items (e.g. Debug_Box) get one cell-sized box.
## - Legacy meshes that are still larger than the cell are scaled down first.
static func normalize_block_collisions(
	blocks_scene_path: String,
	mesh_library_path: String,
	cell_size: Vector3 = CELL_SIZE
) -> Dictionary:
	var packed := load(blocks_scene_path) as PackedScene

	if packed == null:
		return {"repaired": 0, "synced": 0, "error": "missing blocks scene"}

	var root := packed.instantiate() as Node3D

	if root == null:
		return {"repaired": 0, "synced": 0, "error": "invalid blocks root"}

	var repaired: int = 0
	var cell_max: float = maxf(cell_size.x, maxf(cell_size.y, cell_size.z))

	for child: Node in root.get_children():
		var mesh_node := child as MeshInstance3D

		if mesh_node == null or mesh_node.mesh == null:
			continue

		var bounds: AABB = mesh_node.mesh.get_aabb()
		var max_extent: float = maxf(
			bounds.size.x,
			maxf(bounds.size.y, bounds.size.z)
		)

		# Legacy meshes (for example Stair_Echidna) still span 1.5 m.
		if max_extent > cell_max + 0.01:
			var uniform: float = cell_max / max_extent
			var factors := Vector3.ONE * uniform
			var node_transform := mesh_node.transform

			mesh_node.mesh = _scale_vertices(mesh_node.mesh, uniform)
			mesh_node.transform = Transform3D(
				node_transform.basis,
				node_transform.origin * uniform
			)
			_scale_node_shapes(mesh_node, factors)
			bounds = mesh_node.mesh.get_aabb()
			repaired += 1

		var item_name := String(mesh_node.name).to_lower()
		var is_full_cube: bool = (
			(bounds.size - cell_size).abs().length() <= 0.03
			and bounds.position.distance_to(-cell_size * 0.5) <= 0.03
		)

		if "stair" in item_name:
			# Generated stairs are two 0.5 m deep steps inside one cell.
			# Legacy stairs keep their authored concave hull (already scaled).
			if not _has_concave_shape(mesh_node):
				_rebuild_body(mesh_node, root, [
					{
						"name": "BackCollision",
						"size": Vector3(
							cell_size.x,
							cell_size.y,
							cell_size.z * 0.5
						),
						"offset": Vector3(0.0, 0.0, -cell_size.z * 0.25),
					},
					{
						"name": "FrontCollision",
						"size": Vector3(
							cell_size.x,
							cell_size.y * 0.5,
							cell_size.z * 0.5
						),
						"offset": Vector3(
							0.0,
							-cell_size.y * 0.25,
							cell_size.z * 0.25
						),
					},
				])
				repaired += 1
		elif is_full_cube:
			_rebuild_body(mesh_node, root, [
				{
					"name": "CollisionShape3D",
					"size": cell_size,
					"offset": Vector3.ZERO,
				},
			])
			repaired += 1

	var scene := PackedScene.new()
	var pack_error := scene.pack(root)

	if pack_error != OK:
		root.free()
		return {"repaired": repaired, "synced": 0, "error": "pack failed"}

	var save_error := ResourceSaver.save(scene, blocks_scene_path)

	if save_error != OK:
		root.free()
		return {"repaired": repaired, "synced": 0, "error": "save failed"}

	var synced: int = SYNC_SCRIPT.sync_from_blocks(root, mesh_library_path)
	root.free()
	return {"repaired": repaired, "synced": synced, "error": ""}


## Scales mesh vertices only, keeping the authored UVs and normals intact.
static func _scale_vertices(mesh: Mesh, factor: float) -> ArrayMesh:
	var scaled := ArrayMesh.new()

	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)

		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue

		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for index in vertices.size():
			vertices[index] *= factor
		arrays[Mesh.ARRAY_VERTEX] = vertices

		scaled.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			arrays
		)

		var material: Material = mesh.surface_get_material(surface_index)
		if material != null:
			scaled.surface_set_material(surface_index, material)

	return scaled


static func _scale_node_shapes(mesh_node: MeshInstance3D, factors: Vector3) -> void:
	for body_child: Node in mesh_node.get_children():
		var body := body_child as StaticBody3D

		if body == null:
			continue

		var body_transform := body.transform
		body.transform = Transform3D(
			body_transform.basis,
			body_transform.origin * factors
		)

		for shape_child: Node in body.get_children():
			var shape_node := shape_child as CollisionShape3D

			if shape_node == null or shape_node.shape == null:
				continue

			shape_node.shape = _scale_shape(shape_node.shape, factors)
			shape_node.position *= factors


## Replaces one item's collision with simple boxes.
static func _rebuild_body(
	mesh_node: MeshInstance3D,
	scene_root: Node3D,
	boxes: Array
) -> void:
	for child: Node in mesh_node.get_children():
		if child is StaticBody3D:
			mesh_node.remove_child(child)
			child.free()

	var body := StaticBody3D.new()
	body.name = "StaticBody3D"

	for entry: Dictionary in boxes:
		var collision := CollisionShape3D.new()
		collision.name = String(entry["name"])
		collision.position = entry["offset"]

		var box := BoxShape3D.new()
		box.size = entry["size"]
		collision.shape = box
		body.add_child(collision)

	mesh_node.add_child(body)

	# Ownership can only be assigned once the nodes are parented under the scene
	# root, otherwise they are not written into the packed scene.
	body.owner = scene_root

	for child: Node in body.get_children():
		child.owner = scene_root


static func _has_concave_shape(mesh_node: MeshInstance3D) -> bool:
	for body_child: Node in mesh_node.get_children():
		if body_child is not StaticBody3D:
			continue

		for shape_child: Node in body_child.get_children():
			var collision := shape_child as CollisionShape3D

			if collision != null and collision.shape is ConcavePolygonShape3D:
				return true

	return false


## One-shot utility for updating the existing generated scene and MeshLibrary.
static func update_project(
	blocks_scene_path: String,
	mesh_library_path: String
) -> Dictionary:
	var packed := load(blocks_scene_path) as PackedScene

	if packed == null:
		return {"remapped": 0, "synced": 0, "error": "missing blocks scene"}

	var root := packed.instantiate() as Node3D

	if root == null:
		return {"remapped": 0, "synced": 0, "error": "invalid blocks root"}

	var remapped: int = 0

	for child: Node in root.get_children():
		var mesh_node := child as MeshInstance3D

		if mesh_node == null or mesh_node.mesh == null:
			continue

		if not String(mesh_node.name).begins_with("Auto_"):
			continue

		mesh_node.mesh = remap_mesh(mesh_node.mesh)
		remapped += 1

	var scene := PackedScene.new()
	var pack_error := scene.pack(root)

	if pack_error != OK:
		root.free()
		return {"remapped": remapped, "synced": 0, "error": "pack failed"}

	var save_error := ResourceSaver.save(scene, blocks_scene_path)

	if save_error != OK:
		root.free()
		return {"remapped": remapped, "synced": 0, "error": "save failed"}

	var synced: int = SYNC_SCRIPT.sync_from_blocks(root, mesh_library_path)
	root.free()
	return {"remapped": remapped, "synced": synced, "error": ""}
