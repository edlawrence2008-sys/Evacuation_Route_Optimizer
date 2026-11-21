class_name ChunkMesher
extends RefCounted

## Builds one merged mesh per NavGridMap chunk.
##
## Improvements over the previous version:
## - Chunk data is snapshotted before meshing, making future worker-thread use safer.
## - Face visibility and greedy meshing are unchanged in behavior.
## - Non-cube meshes handle missing normals/UVs/indices more safely.
## - Chunk meshes are committed only after a complete rebuild.
## - Optional baked voxel-corner ambient occlusion (per-block-corner brightness,
##   no runtime light cost). Greedy merging is skipped while AO is on.

const CUBE_TOLERANCE: float = 0.02

## Tiles per atlas axis for connected textures (16 x 16 = 256 masks).
const CTM_ATLAS_GRID: int = 16

## Multipliers for AO levels 0 (most occluded) .. 3 (open).
const AO_BRIGHTNESS: Array[float] = [0.50, 0.66, 0.83, 1.0]

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
## 0 keeps every populated chunk meshed. A positive radius only meshes chunks
## within that many chunk columns of the current view centre.
@export var mesh_radius_chunks: int = 0

var debug_colors: bool = false
## Bakes classic voxel-corner AO into the chunk mesh vertex colours. While this
## is on, greedy face merging is disabled so every visible face gets correct
## per-corner occlusion. Toggle from the console with /ao.
var baked_ao_enabled: bool = true

var _grid: NavGridMap
var _root: Node3D
var _chunk_nodes: Dictionary = {}
var _dirty: Dictionary = {}
var _item_info: Dictionary = {}
var _item_part_cache: Dictionary = {}
## AO-enabled duplicates of item-mesh materials, keyed by source material id.
var _item_ao_material_cache: Dictionary = {}
var _running: bool = false
var _view_center: Vector2i = Vector2i.ZERO

var _debug_material: StandardMaterial3D = null
var _debug_faces: int = 0
var _debug_quads: int = 0

## Flat, padded item snapshot for the chunk currently being meshed. One border
## cell on every axis keeps face/AO/CTM neighbour lookups out of the GridMap
## hash and makes the build data array-based.
var _snap_items: PackedInt32Array = PackedInt32Array()
var _snap_origin: Vector3i = Vector3i.ZERO
var _snap_dims: Vector3i = Vector3i.ZERO
var _snap_slice: int = 0


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
	# Newest edits are queued last; process them first so placed/removed blocks
	# show up immediately instead of waiting behind streamed chunks.
	chunks.reverse()

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


func set_baked_ao(enabled: bool) -> void:
	if baked_ao_enabled == enabled:
		return

	baked_ao_enabled = enabled

	if _running:
		# Materials gain/lose the vertex-colour flag, and AO changes the merge
		# policy, so both the item cache and all chunk meshes must rebuild.
		_build_item_info()
		queue_all()


func queue_all() -> void:
	for chunk: Vector2i in _grid.get_populated_chunks():
		_dirty[chunk] = true

	for chunk: Vector2i in _chunk_nodes:
		_dirty[chunk] = true


## Limits meshing to a radius around the player and immediately frees chunk
## meshes that left the radius. A negative radius keeps the current value.
func set_view_center(center: Vector2i, radius: int = -1) -> void:
	if radius >= 0:
		mesh_radius_chunks = radius

	if center == _view_center and radius < 0:
		return

	_view_center = center

	if mesh_radius_chunks <= 0:
		return

	for chunk: Vector2i in _chunk_nodes.keys():
		if not _within_mesh_radius(chunk):
			_remove_chunk_node(chunk)

	for chunk: Vector2i in _grid.get_populated_chunks():
		if _within_mesh_radius(chunk):
			_dirty[chunk] = true
		elif _chunk_nodes.has(chunk):
			_remove_chunk_node(chunk)


func _within_mesh_radius(chunk: Vector2i) -> bool:
	if mesh_radius_chunks <= 0:
		return true

	var dx: int = chunk.x - _view_center.x
	var dz: int = chunk.y - _view_center.y
	return dx * dx + dz * dz <= mesh_radius_chunks * mesh_radius_chunks


func queue_chunk(chunk: Vector2i, include_neighbors: bool = false) -> void:
	_dirty.erase(chunk)
	_dirty[chunk] = true

	if include_neighbors:
		for offset: Vector2i in NEIGHBOR_CHUNKS:
			_dirty.erase(chunk + offset)
			_dirty[chunk + offset] = true


func queue_cell(cell: Vector3i) -> void:
	var chunk: Vector2i = NavGridMap.cell_to_chunk(cell)
	var origin: Vector2i = NavGridMap.chunk_origin(chunk)
	var local_x: int = cell.x - origin.x
	var local_z: int = cell.z - origin.y
	var last: int = NavGridMap.CHUNK_SIZE - 1

	_dirty.erase(chunk)
	_dirty[chunk] = true

	if local_x == 0:
		_dirty.erase(chunk + Vector2i(-1, 0))
		_dirty[chunk + Vector2i(-1, 0)] = true

	if local_x == last:
		_dirty.erase(chunk + Vector2i(1, 0))
		_dirty[chunk + Vector2i(1, 0)] = true

	if local_z == 0:
		_dirty.erase(chunk + Vector2i(0, -1))
		_dirty[chunk + Vector2i(0, -1)] = true

	if local_z == last:
		_dirty.erase(chunk + Vector2i(0, 1))
		_dirty[chunk + Vector2i(0, 1)] = true


func _on_block_placed(cell: Vector3i, _item: int) -> void:
	queue_cell(cell)


func _on_block_removed(cell: Vector3i) -> void:
	queue_cell(cell)


func _on_chunk_loaded(chunk: Vector2i) -> void:
	if _within_mesh_radius(chunk):
		queue_chunk(chunk, true)


func _on_chunk_unloaded(chunk: Vector2i) -> void:
	if _within_mesh_radius(chunk):
		queue_chunk(chunk, true)
	else:
		_remove_chunk_node(chunk)


# ---------------------------------------------------------------------------
# Item classification
# ---------------------------------------------------------------------------

func _build_item_info() -> void:
	_item_info.clear()
	_item_part_cache.clear()
	_item_ao_material_cache.clear()

	var library: MeshLibrary = _grid.mesh_library
	var expected_size: Vector3 = _grid.cell_size * _grid.cell_scale
	var tolerance: Vector3 = expected_size * CUBE_TOLERANCE

	for id: int in library.get_item_list():
		var mesh: Mesh = library.get_item_mesh(id)
		var info: Dictionary = {
			"cube": false,
			"opaque": false,
			"ctm": false,
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

			if (
				baked_ao_enabled
				and info["cube"]
				and material is BaseMaterial3D
			):
				var ao_material := material.duplicate() as BaseMaterial3D
				if ao_material != null:
					ao_material.vertex_color_use_as_albedo = true
					material = ao_material

			info["material"] = material

			var opaque: bool = true

			for surface_index in mesh.get_surface_count():
				var surface_material: Material = mesh.surface_get_material(
					surface_index
				)
				if surface_material is BaseMaterial3D:
					var base_material := surface_material as BaseMaterial3D
					if (
						base_material.transparency
						!= BaseMaterial3D.TRANSPARENCY_DISABLED
					):
						opaque = false
						break

			info["opaque"] = opaque

		# Connected-texture blocks are always full cubes, but each face must be
		# emitted separately so it can pick the atlas tile for its neighbour
		# mask. Override the authored material with the runtime CTM atlas.
		if _grid.is_ctm_item(id):
			info["ctm"] = true
			info["cube"] = true
			info["opaque"] = false
			info["material"] = _grid.get_ctm_material(id)

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


## Builds the flat padded snapshot used by the rest of the chunk build. Interior
## cells come from the existing chunk snapshot; only the one-cell border and the
## top/bottom layers are queried from the GridMap.
func _build_snapshot(
	snapshot: ChunkSnapshot,
	origin: Vector3i,
	dims: Vector3i
) -> void:
	_snap_origin = origin - Vector3i.ONE
	_snap_dims = dims + Vector3i(2, 2, 2)
	_snap_slice = _snap_dims.x * _snap_dims.z

	var total: int = _snap_dims.x * _snap_dims.y * _snap_dims.z
	_snap_items.resize(total)
	_snap_items.fill(-1)

	for cell: Vector3i in snapshot.cells:
		var lx: int = cell.x - _snap_origin.x
		var ly: int = cell.y - _snap_origin.y
		var lz: int = cell.z - _snap_origin.z
		_snap_items[lx + lz * _snap_dims.x + ly * _snap_slice] = int(
			snapshot.items.get(cell, -1)
		)

	var end_x: int = origin.x + dims.x
	var end_y: int = origin.y + dims.y
	var end_z: int = origin.z + dims.z

	for x: int in _snap_dims.x:
		var world_x: int = _snap_origin.x + x
		var border_x: bool = world_x < origin.x or world_x >= end_x
		for z: int in _snap_dims.z:
			var world_z: int = _snap_origin.z + z
			var border: bool = (
				border_x or world_z < origin.z or world_z >= end_z
			)
			var column: int = x + z * _snap_dims.x
			for y: int in _snap_dims.y:
				var world_y: int = _snap_origin.y + y
				if (
					not border
					and world_y >= origin.y
					and world_y < end_y
				):
					continue
				var item: int = _grid.get_cell_item(
					Vector3i(world_x, world_y, world_z)
				)
				if item != -1:
					_snap_items[column + y * _snap_slice] = item


func _snap_item(cell: Vector3i) -> int:
	var lx: int = cell.x - _snap_origin.x
	var ly: int = cell.y - _snap_origin.y
	var lz: int = cell.z - _snap_origin.z

	if (
		lx < 0
		or ly < 0
		or lz < 0
		or lx >= _snap_dims.x
		or ly >= _snap_dims.y
		or lz >= _snap_dims.z
	):
		return -1

	return _snap_items[lx + lz * _snap_dims.x + ly * _snap_slice]


func _rebuild_chunk(chunk: Vector2i) -> void:
	if not _within_mesh_radius(chunk):
		_remove_chunk_node(chunk)
		return

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

	_build_snapshot(snapshot, origin, dims)

	var masks: Dictionary = {}
	var surfaces: Dictionary = {}

	for cell: Vector3i in snapshot.cells:
		var item: int = _snap_item(cell)
		var info: Dictionary = _item_info.get(item, {})

		if info.is_empty():
			continue

		if info["ctm"]:
			_emit_ctm_block(surfaces, cell, item)
			continue

		if not info["cube"]:
			_emit_item_mesh(surfaces, cell, item)
			continue

		var local: Vector3i = cell - origin

		for direction_id: int in 6:
			var neighbor_item: int = _snap_item(
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

			if not baked_ao_enabled or debug_colors:
				while (
					u + width < u_dimension
					and mask[u + width + v * u_dimension] == item
				):
					width += 1

			var height: int = 1

			if not baked_ao_enabled or debug_colors:
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

			if debug_colors:
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
				color,
				cell_low,
				direction_id
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
	color: Color,
	cell: Vector3i,
	direction_id: int
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
	var ao_colors: Array[Color] = [
		Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE
	]

	if baked_ao_enabled and not debug_colors:
		for index in corners.size():
			ao_colors[index] = _corner_ao(
				cell,
				direction_id,
				corners[index],
				size
			)

	for index in corners.size():
		surface.vertices.append(corners[index])
		surface.normals.append(normal)
		surface.uvs.append(
			_face_uv(corners[index], axis, _sign, size)
		)

		if debug_colors:
			surface.colors.append(color)
		elif baked_ao_enabled:
			surface.colors.append(ao_colors[index])

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


## Classic voxel AO: for each face corner, sample the two edge neighbours and
## the diagonal neighbour on the outside of the face. Two solid edge neighbours
## means fully occluded; otherwise the count of the three samples sets the
## brightness. The result is written to the vertex colour, so it is baked with
## the chunk mesh and costs nothing at runtime.
func _corner_ao(
	cell: Vector3i,
	direction_id: int,
	corner: Vector3,
	size: Vector3
) -> Color:
	var axis: int = direction_id >> 1
	var u_axis: int = (axis + 1) % 3
	var v_axis: int = (axis + 2) % 3
	var center: Vector3 = _cell_min_corner(cell) + size * 0.5

	var du: int = 1 if corner[u_axis] > center[u_axis] else -1
	var dv: int = 1 if corner[v_axis] > center[v_axis] else -1

	var outside: Vector3i = cell + FACE_NORMALS[direction_id]
	var side_u: Vector3i = outside
	var side_v: Vector3i = outside
	var diagonal: Vector3i = outside

	side_u[u_axis] += du
	side_v[v_axis] += dv
	diagonal[u_axis] += du
	diagonal[v_axis] += dv

	var solid_u := _is_ao_solid(side_u)
	var solid_v := _is_ao_solid(side_v)
	var solid_diagonal := _is_ao_solid(diagonal)

	var level: int
	if solid_u and solid_v:
		level = 0
	else:
		level = 3 - int(solid_u) - int(solid_v) - int(solid_diagonal)

	var brightness: float = AO_BRIGHTNESS[level]
	return Color(brightness, brightness, brightness, 1.0)


func _is_ao_solid(cell: Vector3i) -> bool:
	var item: int = _snap_item(cell)
	if item == -1:
		return false

	var info: Dictionary = _item_info.get(item, {})
	return bool(info.get("opaque", true))


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
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
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
		var material: Material = part["material"]
		if baked_ao_enabled and not debug_colors and material is BaseMaterial3D:
			material = _item_ao_material(material as BaseMaterial3D)
		var surface: MeshSurface = _get_surface(
			surfaces,
			material
		)
		var vertices: PackedVector3Array = part["vertices"]
		var normals: PackedVector3Array = part["normals"]
		var uvs: PackedVector2Array = part["uvs"]
		var indices: PackedInt32Array = part["indices"]
		var first_index: int = surface.vertices.size()

		for vertex_index: int in vertices.size():
			var vertex: Vector3 = vertices[vertex_index]
			var local_vertex: Vector3 = transform * vertex
			surface.vertices.append(local_vertex)

			var normal: Vector3 = (
				normals[vertex_index]
				if vertex_index < normals.size()
				else Vector3.UP
			)
			var local_normal: Vector3 = (
				transform.basis * normal
			).normalized()
			surface.normals.append(local_normal)

			var uv: Vector2 = (
				uvs[vertex_index]
				if vertex_index < uvs.size()
				else Vector2.ZERO
			)
			surface.uvs.append(uv)

			if debug_colors:
				surface.colors.append(Color.WHITE)
			elif baked_ao_enabled:
				surface.colors.append(
					_item_vertex_ao(cell, local_vertex, local_normal)
				)

		if indices.is_empty():
			for vertex_index: int in vertices.size():
				surface.indices.append(first_index + vertex_index)
		else:
			for index: int in indices:
				surface.indices.append(first_index + index)


# ---------------------------------------------------------------------------
# Non-full block AO
# ---------------------------------------------------------------------------

func _item_ao_material(material: BaseMaterial3D) -> BaseMaterial3D:
	var key: int = material.get_instance_id()
	var cached: Variant = _item_ao_material_cache.get(key)
	if cached is BaseMaterial3D:
		return cached
	var duplicated_material := material.duplicate() as BaseMaterial3D
	if duplicated_material == null:
		return material
	duplicated_material.vertex_color_use_as_albedo = true
	_item_ao_material_cache[key] = duplicated_material
	return duplicated_material


## Per-vertex AO for slabs, stairs, panels and other non-full items. The
## classic corner test is applied around the vertex using the face's tangent
## axes, so partial blocks darken against neighbouring cells instead of staying
## flat white.
func _item_vertex_ao(
	cell: Vector3i,
	local_vertex: Vector3,
	local_normal: Vector3
) -> Color:
	var abs_normal := Vector3(
		absf(local_normal.x),
		absf(local_normal.y),
		absf(local_normal.z)
	)
	var axis: int = 1
	if abs_normal.x >= abs_normal.y and abs_normal.x >= abs_normal.z:
		axis = 0
	elif abs_normal.z >= abs_normal.y:
		axis = 2

	var sign_value: float = local_normal[axis]
	if is_zero_approx(sign_value):
		return Color.WHITE

	var u_axis: int = (axis + 1) % 3
	var v_axis: int = (axis + 2) % 3
	var center: Vector3 = _cell_min_corner(cell) + _grid.cell_size * 0.5

	var du: int = 1 if local_vertex[u_axis] > center[u_axis] else -1
	var dv: int = 1 if local_vertex[v_axis] > center[v_axis] else -1

	var outside := cell
	outside[axis] += 1 if sign_value > 0.0 else -1

	var side_u: Vector3i = outside
	var side_v: Vector3i = outside
	var diagonal: Vector3i = outside
	side_u[u_axis] += du
	side_v[v_axis] += dv
	diagonal[u_axis] += du
	diagonal[v_axis] += dv

	var solid_u := _is_ao_solid(side_u)
	var solid_v := _is_ao_solid(side_v)
	var solid_diagonal := _is_ao_solid(diagonal)

	var level: int
	if solid_u and solid_v:
		level = 0
	else:
		level = 3 - int(solid_u) - int(solid_v) - int(solid_diagonal)

	var brightness: float = AO_BRIGHTNESS[level]
	return Color(brightness, brightness, brightness, 1.0)


# ---------------------------------------------------------------------------
# Connected textures
# ---------------------------------------------------------------------------

## Emits one quad per visible face of a connected-texture block. CTM faces are
## never greedy-merged: each face samples the atlas tile selected by its eight
## in-plane neighbours.
func _emit_ctm_block(
	surfaces: Dictionary,
	cell: Vector3i,
	item: int
) -> void:
	var surface: MeshSurface = _get_surface(
		surfaces,
		_grid.get_ctm_material(item)
	)
	var size: Vector3 = _grid.cell_size

	for direction_id: int in 6:
		var neighbor: int = _snap_item(
			cell + FACE_NORMALS[direction_id]
		)
		if not _face_visible(item, neighbor):
			continue

		var axis: int = direction_id >> 1
		var face_sign: int = 1 if (direction_id & 1) == 1 else -1
		var u_dir: Vector3i
		var v_dir: Vector3i

		# Direction that increases texture U / texture V for this face. V points
		# "down" the sprite, matching Image row order.
		match axis:
			0:
				u_dir = Vector3i(0, 0, -face_sign)
				v_dir = Vector3i(0, -1, 0)
			1:
				u_dir = Vector3i(1, 0, 0)
				v_dir = Vector3i(0, 0, face_sign)
			_:
				u_dir = Vector3i(face_sign, 0, 0)
				v_dir = Vector3i(0, -1, 0)

		# Mask bit order: N=1 E=2 S=4 W=8 NE=16 SE=32 SW=64 NW=128, where N is
		# the top of the sprite. This matches ConnectedTextureBuilder.
		var mask: int = 0
		var checks: Array = [
			[1, -v_dir],
			[2, u_dir],
			[4, v_dir],
			[8, -u_dir],
			[16, u_dir - v_dir],
			[32, u_dir + v_dir],
			[64, -u_dir + v_dir],
			[128, -u_dir - v_dir],
		]
		for check: Array in checks:
			if _snap_item(cell + check[1]) == item:
				mask |= int(check[0])

		_emit_ctm_quad(
			surface, axis, face_sign, u_dir, v_dir, cell, size, mask, direction_id
		)
		_debug_faces += 1
		_debug_quads += 1


func _emit_ctm_quad(
	surface: MeshSurface,
	axis: int,
	face_sign: int,
	u_dir: Vector3i,
	v_dir: Vector3i,
	cell: Vector3i,
	size: Vector3,
	mask: int,
	direction_id: int
) -> void:
	var cell_min: Vector3 = _cell_min_corner(cell)
	var u_axis: int = (axis + 1) % 3
	var v_axis: int = (axis + 2) % 3

	# Geometry always spans the cell in positive axis order; the texture
	# directions are applied to the UVs below. Using u_dir/v_dir for the
	# geometry would shift the quad one cell whenever a texture axis points
	# negative.
	var p00: Vector3 = cell_min
	p00[axis] += size[axis] if face_sign > 0 else 0.0

	var p10: Vector3 = p00
	p10[u_axis] += size[u_axis]

	var p11: Vector3 = p10
	p11[v_axis] += size[v_axis]

	var p01: Vector3 = p00
	p01[v_axis] += size[v_axis]

	var normal: Vector3 = Vector3.ZERO
	normal[axis] = float(face_sign)

	var tile := Vector2(
		float(mask % CTM_ATLAS_GRID),
		float(mask) / float(CTM_ATLAS_GRID)
	)
	var first_index: int = surface.vertices.size()
	var corners: Array[Vector3] = [p00, p10, p11, p01]
	var u_vec: Vector3 = Vector3(u_dir)
	var v_vec: Vector3 = Vector3(v_dir)
	var u_extent: float = absf(u_vec.dot(size))
	var v_extent: float = absf(v_vec.dot(size))
	var u_base: float = minf(0.0, u_vec.dot(size))
	var v_base: float = minf(0.0, v_vec.dot(size))
	var debug_color: Color = Color.WHITE
	if debug_colors:
		debug_color = _debug_quad_color(cell, direction_id)

	for corner: Vector3 in corners:
		var local: Vector3 = corner - cell_min
		var uv := Vector2(
			(local.dot(u_vec) - u_base) / u_extent,
			(local.dot(v_vec) - v_base) / v_extent
		)
		surface.vertices.append(corner)
		surface.normals.append(normal)
		surface.uvs.append(
			(tile + uv) / float(CTM_ATLAS_GRID)
		)

		if debug_colors:
			surface.colors.append(debug_color)
		elif baked_ao_enabled:
			surface.colors.append(
				_corner_ao(cell, direction_id, corner, size)
			)
		else:
			surface.colors.append(Color.WHITE)

	if face_sign > 0:
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


# ---------------------------------------------------------------------------
# Committing meshes
# ---------------------------------------------------------------------------

func _commit_chunk(chunk: Vector2i, surfaces: Dictionary) -> void:
	# Reuse the chunk's ArrayMesh instead of allocating a new mesh resource on
	# every rebuild. The node and its RID survive, and only the surface buffers
	# are replaced.
	var node: MeshInstance3D = _chunk_nodes.get(chunk)

	if node == null or not is_instance_valid(node):
		node = MeshInstance3D.new()
		node.name = "Chunk_%d_%d" % [chunk.x, chunk.y]
		node.mesh = ArrayMesh.new()
		_root.add_child(node)
		_chunk_nodes[chunk] = node

	var mesh := node.mesh as ArrayMesh
	if mesh == null:
		mesh = ArrayMesh.new()
		node.mesh = mesh
	else:
		mesh.clear_surfaces()

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


func _remove_chunk_node(chunk: Vector2i) -> void:
	var node: MeshInstance3D = _chunk_nodes.get(chunk)

	if node != null and is_instance_valid(node):
		node.queue_free()

	_chunk_nodes.erase(chunk)
