class_name ChunkMesher
extends RefCounted

## Builds one merged mesh per NavGridMap chunk.
##
## Improvements over the previous version:
## - Chunk data is snapshotted before meshing, making future worker-thread use safer.
## - Face visibility and greedy meshing are unchanged in behavior.
## - Non-cube meshes handle missing normals/UVs/indices more safely.
## - Chunk meshes are committed only after a complete rebuild.
## - No AO/light baking and no water pass.

const CUBE_TOLERANCE: float = 0.02

const FACE_NORMALS: Array[Vector3i] = [
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
]

const NEIGHBOR_CHUNKS: Array[Vector2i] = [
	Vector2i(-1, 0),
	Vector2i(1, 0),
	Vector2i(0, -1),
	Vector2i(0, 1),
]

@export var build_budget_usec: int = 4000

var debug_colors: bool = false

var _grid: NavGridMap
var _root: Node3D
var _chunk_nodes: Dictionary = {}
var _dirty: Dictionary = {}
var _item_info: Dictionary = {}
var _item_part_cache: Dictionary = {}
var _running: bool = false

var _debug_material: StandardMaterial3D = null
var _debug_faces: int = 0
var _debug_quads: int = 0


class MeshSurface:
	var material: Material
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var colors: PackedColorArray = PackedColorArray()
	var indices: PackedInt32Array = PackedInt32Array()


class ChunkSnapshot:
	var chunk: Vector2i
	var cells: Array[Vector3i] = []
	var items: Dictionary = {}


func _init(grid: NavGridMap) -> void:
	_grid = grid


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func start() -> void:
	if _running:
		return

	if _grid.mesh_library == null:
		push_warning(
			"ChunkMesher: the grid has no MeshLibrary, "
			+ "so normal GridMap rendering stays on."
		)
		return

	_build_item_info()

	_root = Node3D.new()
	_root.name = "ChunkMeshes"
	_grid.add_sibling.call_deferred(_root)

	_grid.block_placed.connect(_on_block_placed)
	_grid.block_removed.connect(_on_block_removed)
	_grid.chunk_loaded.connect(_on_chunk_loaded)
	_grid.chunk_unloaded.connect(_on_chunk_unloaded)

	_grid.visible = false
	_running = true
	queue_all()


func stop() -> void:
	if not _running:
		return

	_running = false

	if is_instance_valid(_grid):
		_grid.block_placed.disconnect(_on_block_placed)
		_grid.block_removed.disconnect(_on_block_removed)
		_grid.chunk_loaded.disconnect(_on_chunk_loaded)
		_grid.chunk_unloaded.disconnect(_on_chunk_unloaded)
		_grid.visible = true

	if is_instance_valid(_root):
		_root.queue_free()

	_chunk_nodes.clear()
	_dirty.clear()


func process() -> void:
	if not _running or _root == null or not _root.is_inside_tree():
		return

	if _root.global_transform != _grid.global_transform:
		_root.global_transform = _grid.global_transform

	if _dirty.is_empty():
		return

	var start_usec: int = Time.get_ticks_usec()
	var chunks: Array = _dirty.keys()

	for chunk: Vector2i in chunks:
		_dirty.erase(chunk)
		_rebuild_chunk(chunk)

		if Time.get_ticks_usec() - start_usec >= build_budget_usec:
			break


func rebuild_all() -> void:
	if not _running:
		return

	_build_item_info()
	queue_all()


func set_debug_colors(enabled: bool) -> void:
	if debug_colors == enabled:
		return

	debug_colors = enabled

	if _running:
		queue_all()


func queue_all() -> void:
	for chunk: Vector2i in _grid.get_populated_chunks():
		_dirty[chunk] = true

	for chunk: Vector2i in _chunk_nodes:
		_dirty[chunk] = true


func queue_chunk(chunk: Vector2i, include_neighbors: bool = false) -> void:
	_dirty[chunk] = true

	if include_neighbors:
		for offset: Vector2i in NEIGHBOR_CHUNKS:
			_dirty[chunk + offset] = true


func queue_cell(cell: Vector3i) -> void:
	var chunk: Vector2i = NavGridMap.cell_to_chunk(cell)
	var origin: Vector2i = NavGridMap.chunk_origin(chunk)
	var local_x: int = cell.x - origin.x
	var local_z: int = cell.z - origin.y
	var last: int = NavGridMap.CHUNK_SIZE - 1

	_dirty[chunk] = true

	if local_x == 0:
		_dirty[chunk + Vector2i(-1, 0)] = true

	if local_x == last:
		_dirty[chunk + Vector2i(1, 0)] = true

	if local_z == 0:
		_dirty[chunk + Vector2i(0, -1)] = true

	if local_z == last:
		_dirty[chunk + Vector2i(0, 1)] = true


func _on_block_placed(cell: Vector3i, _item: int) -> void:
	queue_cell(cell)


func _on_block_removed(cell: Vector3i) -> void:
	queue_cell(cell)


func _on_chunk_loaded(chunk: Vector2i) -> void:
	queue_chunk(chunk, true)


func _on_chunk_unloaded(chunk: Vector2i) -> void:
	queue_chunk(chunk, true)


# ---------------------------------------------------------------------------
# Item classification
# ---------------------------------------------------------------------------

func _build_item_info() -> void:
	_item_info.clear()
	_item_part_cache.clear()

	var library: MeshLibrary = _grid.mesh_library
	var expected_size: Vector3 = _grid.cell_size * _grid.cell_scale
	var tolerance: Vector3 = expected_size * CUBE_TOLERANCE

	for id: int in library.get_item_list():
		var mesh: Mesh = library.get_item_mesh(id)
		var info: Dictionary = {
			"cube": false,
			"opaque": false,
			"material": null,
		}

		if mesh != null and mesh.get_surface_count() > 0:
			var mesh_transform: Transform3D = library.get_item_mesh_transform(id)
			var bounds: AABB = mesh_transform * mesh.get_aabb()
			var diff: Vector3 = (bounds.size - expected_size).abs()
			var size_matches: bool = (
				diff.x <= tolerance.x
				and diff.y <= tolerance.y
				and diff.z <= tolerance.z
			)
			# A stair's bounding box is a full cube too, so also require the mesh to
			# actually cover every face of that box.
			# Multitexture meshes and registered directional blocks must keep
			# their per-face materials/orientation, so render them as item meshes
			# instead of merging them into the greedy cube pass.
			info["cube"] = (
				size_matches
				and _covers_all_faces(mesh, mesh_transform, bounds)
				and mesh.get_surface_count() == 1
				and _grid.get_directional_kind(id) == -1
			)

			var material: Material = mesh.surface_get_material(0)
			info["material"] = material

			var opaque: bool = true

			if material is BaseMaterial3D:
				var base_material := material as BaseMaterial3D
				opaque = (
					base_material.transparency
					== BaseMaterial3D.TRANSPARENCY_DISABLED
				)

			info["opaque"] = opaque

		_item_info[id] = info


## True if the mesh's triangles fully cover all six faces of its bounding box. A cube does;
## a stair covers only half of its top face, so it is not mistaken for a cube.
func _covers_all_faces(mesh: Mesh, xform: Transform3D, bounds: AABB) -> bool:
	var area := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var epsilon: float = maxf(
		minf(bounds.size.x, minf(bounds.size.y, bounds.size.z)) * 0.01,
		0.0001
	)
	
	# If it's a PrimitiveMesh (like BoxMesh), convert it to arrays safely using VertexTool or MeshDataTool if needed, 
	# or handle it directly. For standard meshes / ArrayMeshes:
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
			
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
			
		var count: int = indices.size() if not indices.is_empty() else vertices.size()
		if count < 3:
			continue
			
		for t in range(0, count - 2, 3):
			var i0: int = indices[t] if not indices.is_empty() else t
			var i1: int = indices[t + 1] if not indices.is_empty() else t + 1
			var i2: int = indices[t + 2] if not indices.is_empty() else t + 2
			
			if i0 >= vertices.size() or i1 >= vertices.size() or i2 >= vertices.size():
				continue
				
			var a: Vector3 = xform * vertices[i0]
			var b: Vector3 = xform * vertices[i1]
			var c: Vector3 = xform * vertices[i2]
			var triangle_area: float = 0.5 * (b - a).cross(c - a).length()
			
			for axis in 3:
				for side in 2:
					var plane: float = bounds.position[axis]
					if side == 1:
						plane += bounds.size[axis]
					if (
						absf(a[axis] - plane) <= epsilon
						and absf(b[axis] - plane) <= epsilon
						and absf(c[axis] - plane) <= epsilon
					):
						area[axis * 2 + side] += triangle_area
						
	for axis in 3:
		var full_area: float = bounds.size[(axis + 1) % 3] * bounds.size[(axis + 2) % 3]
		for side in 2:
			if area[axis * 2 + side] < full_area * 0.97:
				return false
	return true


func _face_visible(item: int, neighbor_item: int) -> bool:
	if neighbor_item == GridMap.INVALID_CELL_ITEM:
		return true

	var info: Dictionary = _item_info.get(neighbor_item, {})

	if info.is_empty():
		return true

	if info["cube"] and info["opaque"]:
		return false

	return not (info["cube"] and neighbor_item == item)


# ---------------------------------------------------------------------------
# Chunk building
# ---------------------------------------------------------------------------

func _create_chunk_snapshot(chunk: Vector2i) -> ChunkSnapshot:
	var snapshot := ChunkSnapshot.new()
	snapshot.chunk = chunk

	var cells: Dictionary = _grid.get_chunk_cells(chunk)

	for cell: Vector3i in cells:
		snapshot.cells.append(cell)
		snapshot.items[cell] = _grid.get_cell_item(cell)

	return snapshot


func _rebuild_chunk(chunk: Vector2i) -> void:
	var snapshot: ChunkSnapshot = _create_chunk_snapshot(chunk)

	if snapshot.cells.is_empty():
		_remove_chunk_node(chunk)
		return

	_debug_faces = 0
	_debug_quads = 0

	var y_min: int = 1 << 30
	var y_max: int = -(1 << 30)

	for cell: Vector3i in snapshot.cells:
		y_min = mini(y_min, cell.y)
		y_max = maxi(y_max, cell.y)

	var origin_xz: Vector2i = NavGridMap.chunk_origin(chunk)
	var origin := Vector3i(origin_xz.x, y_min, origin_xz.y)
	var dims := Vector3i(
		NavGridMap.CHUNK_SIZE,
		y_max - y_min + 1,
		NavGridMap.CHUNK_SIZE
	)

	var masks: Dictionary = {}
	var surfaces: Dictionary = {}

	for cell: Vector3i in snapshot.cells:
		var item: int = snapshot.items[cell]
		var info: Dictionary = _item_info.get(item, {})

		if info.is_empty():
			continue

		if not info["cube"]:
			_emit_item_mesh(surfaces, cell, item)
			continue

		var local: Vector3i = cell - origin

		for direction_id: int in 6:
			var neighbor_item: int = _grid.get_cell_item(
				cell + FACE_NORMALS[direction_id]
			)

			if not _face_visible(item, neighbor_item):
				continue

			var axis: int = direction_id >> 1
			var u_axis: int = (axis + 1) % 3
			var v_axis: int = (axis + 2) % 3
			var mask_key := Vector2i(direction_id, local[axis])

			var mask: PackedInt32Array = masks.get(
				mask_key,
				PackedInt32Array()
			)

			if mask.is_empty():
				mask.resize(dims[u_axis] * dims[v_axis])
				mask.fill(-1)
				masks[mask_key] = mask

			var mask_index: int = local[u_axis] + local[v_axis] * dims[u_axis]
			mask[mask_index] = item
			_debug_faces += 1

	for mask_key: Vector2i in masks:
		_greedy_emit(
			surfaces,
			masks[mask_key],
			mask_key.x,
			mask_key.y,
			origin,
			dims
		)

	_commit_chunk(chunk, surfaces)

	if debug_colors:
		print(
			"[ChunkMesher] chunk %s: %d visible faces -> %d quads (%.1fx fewer)"
			% [
				chunk,
				_debug_faces,
				_debug_quads,
				float(_debug_faces) / float(maxi(_debug_quads, 1)),
			]
		)


func _greedy_emit(
	surfaces: Dictionary,
	mask: PackedInt32Array,
	direction_id: int,
	slice: int,
	origin: Vector3i,
	dims: Vector3i
) -> void:
	var axis: int = direction_id >> 1
	var _sign: int = 1 if (direction_id & 1) == 1 else -1
	var u_axis: int = (axis + 1) % 3
	var v_axis: int = (axis + 2) % 3
	var u_dimension: int = dims[u_axis]
	var v_dimension: int = dims[v_axis]

	for v: int in v_dimension:
		var u: int = 0

		while u < u_dimension:
			var item: int = mask[u + v * u_dimension]

			if item < 0:
				u += 1
				continue

			var width: int = 1

			while (
				u + width < u_dimension
				and mask[u + width + v * u_dimension] == item
			):
				width += 1

			var height: int = 1
			var can_grow: bool = true

			while can_grow and v + height < v_dimension:
				for k: int in width:
					var next_index: int = (
						u + k + (v + height) * u_dimension
					)

					if mask[next_index] != item:
						can_grow = false
						break

				if can_grow:
					height += 1

			for dv: int in height:
				for du: int in width:
					var clear_index: int = (
						u + du + (v + dv) * u_dimension
					)
					mask[clear_index] = -1

			var cell_low: Vector3i = origin
			cell_low[axis] += slice
			cell_low[u_axis] += u
			cell_low[v_axis] += v

			var color: Color = Color.WHITE

			if debug_colors and width * height > 1:
				color = _debug_quad_color(cell_low, direction_id)

			var info: Dictionary = _item_info[item]
			var surface: MeshSurface = _get_surface(
				surfaces,
				info["material"]
			)

			_emit_quad(
				surface,
				axis,
				_sign,
				u_axis,
				v_axis,
				_cell_min_corner(cell_low),
				width,
				height,
				color
			)
			_debug_quads += 1

			u += width


func _emit_quad(
	surface: MeshSurface,
	axis: int,
	_sign: int,
	u_axis: int,
	v_axis: int,
	base: Vector3,
	width: int,
	height: int,
	color: Color
) -> void:
	var size: Vector3 = _grid.cell_size

	var p00: Vector3 = base
	p00[axis] += size[axis] if _sign > 0 else 0.0

	var p10: Vector3 = p00
	p10[u_axis] += width * size[u_axis]

	var p11: Vector3 = p10
	p11[v_axis] += height * size[v_axis]

	var p01: Vector3 = p00
	p01[v_axis] += height * size[v_axis]

	var normal: Vector3 = Vector3.ZERO
	normal[axis] = float(_sign)

	var first_index: int = surface.vertices.size()
	var corners: Array[Vector3] = [p00, p10, p11, p01]

	for corner: Vector3 in corners:
		surface.vertices.append(corner)
		surface.normals.append(normal)
		surface.uvs.append(
			_face_uv(corner, axis, _sign, size)
		)

		if debug_colors:
			surface.colors.append(color)

	if _sign > 0:
		surface.indices.append_array(PackedInt32Array([
			first_index,
			first_index + 2,
			first_index + 1,
			first_index,
			first_index + 3,
			first_index + 2,
		]))
	else:
		surface.indices.append_array(PackedInt32Array([
			first_index,
			first_index + 1,
			first_index + 2,
			first_index,
			first_index + 2,
			first_index + 3,
		]))


func _face_uv(
	position: Vector3,
	axis: int,
	_sign: int,
	size: Vector3
) -> Vector2:
	var u: float
	var v: float

	match axis:
		0:
			u = -_sign * position.z / size.z
			v = -position.y / size.y
		1:
			u = position.x / size.x
			v = _sign * position.z / size.z
		_:
			u = _sign * position.x / size.x
			v = -position.y / size.y

	return Vector2(u, v)


func _cell_min_corner(cell: Vector3i) -> Vector3:
	var position: Vector3 = _grid.map_to_local(cell)
	var size: Vector3 = _grid.cell_size

	return Vector3(
		position.x - (size.x * 0.5 if _grid.cell_center_x else 0.0),
		position.y - (size.y * 0.5 if _grid.cell_center_y else 0.0),
		position.z - (size.z * 0.5 if _grid.cell_center_z else 0.0),
	)


func _get_surface(
	surfaces: Dictionary,
	material: Material
) -> MeshSurface:
	if debug_colors:
		material = _get_debug_material()

	var key: Variant

	if material != null:
		key = material
	else:
		key = &"none"

	var surface: MeshSurface = surfaces.get(key)

	if surface == null:
		surface = MeshSurface.new()
		surface.material = material
		surfaces[key] = surface

	return surface


# ---------------------------------------------------------------------------
# Debug colors
# ---------------------------------------------------------------------------

func _get_debug_material() -> StandardMaterial3D:
	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.vertex_color_use_as_albedo = true
		_debug_material.albedo_color = Color.WHITE

	return _debug_material


func _debug_quad_color(cell: Vector3i, direction_id: int) -> Color:
	var hash_value: int = hash(
		Vector4i(cell.x, cell.y, cell.z, direction_id)
	)
	var hue: float = float(posmod(hash_value, 360)) / 360.0

	return Color.from_hsv(hue, 0.8, 0.95)


# ---------------------------------------------------------------------------
# Non-cube items
# ---------------------------------------------------------------------------

func _get_item_parts(item: int) -> Array:
	if _item_part_cache.has(item):
		return _item_part_cache[item]

	var parts: Array = []
	var mesh: Mesh = _grid.mesh_library.get_item_mesh(item)

	if mesh != null:
		# If it's a PrimitiveMesh (like BoxMesh, PrismMesh), we can get its arrays via surface_get_arrays directly 
		# without calling surface_get_primitive_type.
		var is_primitive := mesh is PrimitiveMesh
		
		for surface_index: int in mesh.get_surface_count():
			if not is_primitive:
				# surface_get_primitive_type only exists on certain mesh types or can be skipped safely,
				# but if it's an ArrayMesh we can check or just grab the arrays directly.
				pass

			var arrays: Array = mesh.surface_get_arrays(surface_index)

			if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
				continue

			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

			if vertices.is_empty():
				continue

			var normals: PackedVector3Array = PackedVector3Array()
			if arrays[Mesh.ARRAY_NORMAL] != null:
				normals = arrays[Mesh.ARRAY_NORMAL]

			var uvs: PackedVector2Array = PackedVector2Array()
			if arrays[Mesh.ARRAY_TEX_UV] != null:
				uvs = arrays[Mesh.ARRAY_TEX_UV]

			var indices: PackedInt32Array = PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				indices = arrays[Mesh.ARRAY_INDEX]

			parts.append({
				"material": mesh.surface_get_material(surface_index),
				"vertices": vertices,
				"normals": normals,
				"uvs": uvs,
				"indices": indices,
			})

	_item_part_cache[item] = parts

	return parts


func _emit_item_mesh(
	surfaces: Dictionary,
	cell: Vector3i,
	item: int
) -> void:
	var parts: Array = _get_item_parts(item)

	if parts.is_empty():
		return

	var placement := Transform3D(
		_grid.get_cell_item_basis(cell),
		_grid.map_to_local(cell)
	)
	var mesh_transform: Transform3D = (
		_grid.mesh_library.get_item_mesh_transform(item)
	)
	var transform: Transform3D = placement * mesh_transform

	for part: Dictionary in parts:
		var surface: MeshSurface = _get_surface(
			surfaces,
			part["material"]
		)
		var vertices: PackedVector3Array = part["vertices"]
		var normals: PackedVector3Array = part["normals"]
		var uvs: PackedVector2Array = part["uvs"]
		var indices: PackedInt32Array = part["indices"]
		var first_index: int = surface.vertices.size()

		for vertex_index: int in vertices.size():
			var vertex: Vector3 = vertices[vertex_index]
			surface.vertices.append(transform * vertex)

			var normal: Vector3 = (
				normals[vertex_index]
				if vertex_index < normals.size()
				else Vector3.UP
			)
			surface.normals.append(
				(transform.basis * normal).normalized()
			)

			var uv: Vector2 = (
				uvs[vertex_index]
				if vertex_index < uvs.size()
				else Vector2.ZERO
			)
			surface.uvs.append(uv)

			if debug_colors:
				surface.colors.append(Color.WHITE)

		if indices.is_empty():
			for vertex_index: int in vertices.size():
				surface.indices.append(first_index + vertex_index)
		else:
			for index: int in indices:
				surface.indices.append(first_index + index)


# ---------------------------------------------------------------------------
# Committing meshes
# ---------------------------------------------------------------------------

func _commit_chunk(chunk: Vector2i, surfaces: Dictionary) -> void:
	var mesh := ArrayMesh.new()

	for key: Variant in surfaces:
		var surface: MeshSurface = surfaces[key]

		if surface.vertices.is_empty():
			continue

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = surface.vertices
		arrays[Mesh.ARRAY_NORMAL] = surface.normals
		arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
		arrays[Mesh.ARRAY_INDEX] = surface.indices

		if not surface.colors.is_empty():
			arrays[Mesh.ARRAY_COLOR] = surface.colors

		mesh.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES,
			arrays
		)
		mesh.surface_set_material(
			mesh.get_surface_count() - 1,
			surface.material
		)

	if mesh.get_surface_count() == 0:
		_remove_chunk_node(chunk)
		return

	var node: MeshInstance3D = _chunk_nodes.get(chunk)

	if node == null or not is_instance_valid(node):
		node = MeshInstance3D.new()
		node.name = "Chunk_%d_%d" % [chunk.x, chunk.y]
		_root.add_child(node)
		_chunk_nodes[chunk] = node

	node.mesh = mesh


func _remove_chunk_node(chunk: Vector2i) -> void:
	var node: MeshInstance3D = _chunk_nodes.get(chunk)

	if node != null and is_instance_valid(node):
		node.queue_free()

	_chunk_nodes.erase(chunk)
