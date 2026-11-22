class_name HeightmapTerrainGenerator
extends "res://scripts/world/WorldGenerator.gd"

## Deterministic heightmap terrain with a hard one-block-per-cell slope limit.
##
## The footprint is bounded (default 256 x 256 blocks). Coarse heights are
## generated on a lattice, projected to a Lipschitz surface with slope 1 block
## per cell, then bilinearly interpolated and floored. Because adjacent lattice
## nodes differ by at most `coarse_spacing` blocks, adjacent columns differ by at
## most one block after interpolation, which is exactly what the existing A*
## one-block stair steps and the walkability rule need.
##
## Every column emits `column_depth` blocks (surface + subsurface) so collision
## and the downward ground probe have real geometry. This is not implicit solid:
## no cells are stored below the emitted depth.
##
## Purity: output is a function of (seed, params, x, z). The coarse lattice is a
## deterministic cache rebuilt after `invalidate()`.

const SIZE_CHUNK: int = 16

@export_group("Footprint")
@export var footprint_origin: Vector2i = Vector2i(-128, -128)
@export var footprint_size: Vector2i = Vector2i(256, 256)

@export_group("Terrain")
@export var base_height: int = 0
@export var amplitude: float = 6.0
@export var scale: float = 64.0
@export var octaves: int = 4
@export var persistence: float = 0.5
@export var lacunarity: float = 2.0
## 0 = rolling FBM, 1 = fully ridged. Blended into the height field.
@export var ridge_amount: float = 0.35
## Lattice spacing in blocks. The Lipschitz projection guarantees
## |adjacent lattice heights| <= this, so the interpolated slope is <= 1 block
## per cell regardless of amplitude.
@export var coarse_spacing: int = 8

@export_group("Blocks")
@export var surface_item: int = 44
@export var subsurface_item: int = 44
@export var column_depth: int = 3
## Bottom slab placed on the low side of every one-block terrain step. It splits
## the riser into two half-block steps and softens the dark terrace contour.
## Set to -1 (or disable `step_slabs_enabled`) to emit plain full-block columns.
@export var step_slab_item: int = 46
@export var step_slabs_enabled: bool = true

# Coarse lattice cache, rebuilt lazily.
var _coarse: PackedFloat32Array = PackedFloat32Array()
var _coarse_nx: int = 0
var _coarse_nz: int = 0
var _coarse_ready: bool = false


func get_id() -> String:
	return "heightmap_v1"


func get_version() -> int:
	return 1


func get_params() -> Dictionary:
	return {
		"noise_seed": noise_seed,
		"footprint_origin": [footprint_origin.x, footprint_origin.y],
		"footprint_size": [footprint_size.x, footprint_size.y],
		"base_height": base_height,
		"amplitude": amplitude,
		"scale": scale,
		"octaves": octaves,
		"persistence": persistence,
		"lacunarity": lacunarity,
		"ridge_amount": ridge_amount,
		"coarse_spacing": coarse_spacing,
		"surface_item": surface_item,
		"subsurface_item": subsurface_item,
		"column_depth": column_depth,
		"step_slab_item": step_slab_item,
		"step_slabs_enabled": step_slabs_enabled,
	}


func apply_params(params: Dictionary) -> void:
	super.apply_params(params)

	var origin: Variant = params.get("footprint_origin", null)
	if origin is Array and (origin as Array).size() >= 2:
		footprint_origin = Vector2i(int(origin[0]), int(origin[1]))

	var size: Variant = params.get("footprint_size", null)
	if size is Array and (size as Array).size() >= 2:
		footprint_size = Vector2i(int(size[0]), int(size[1]))

	base_height = int(params.get("base_height", base_height))
	amplitude = float(params.get("amplitude", amplitude))
	scale = maxf(1.0, float(params.get("scale", scale)))
	octaves = maxi(1, int(params.get("octaves", octaves)))
	persistence = clampf(float(params.get("persistence", persistence)), 0.0, 1.0)
	lacunarity = maxf(1.0, float(params.get("lacunarity", lacunarity)))
	ridge_amount = clampf(float(params.get("ridge_amount", ridge_amount)), 0.0, 1.0)
	coarse_spacing = maxi(1, int(params.get("coarse_spacing", coarse_spacing)))
	surface_item = int(params.get("surface_item", surface_item))
	subsurface_item = int(params.get("subsurface_item", subsurface_item))
	column_depth = maxi(1, int(params.get("column_depth", column_depth)))
	step_slab_item = int(params.get("step_slab_item", step_slab_item))
	step_slabs_enabled = bool(
		params.get("step_slabs_enabled", step_slabs_enabled)
	)
	invalidate()


## Call after changing exported fields directly (the inspector does not know
## when the cache is stale).
func invalidate() -> void:
	_coarse_ready = false


func covers(x: int, z: int) -> bool:
	return (
		x >= footprint_origin.x
		and x < footprint_origin.x + footprint_size.x
		and z >= footprint_origin.y
		and z < footprint_origin.y + footprint_size.y
	)


func covers_chunk(chunk: Vector2i) -> bool:
	var origin := chunk * SIZE_CHUNK
	return (
		origin.x < footprint_origin.x + footprint_size.x
		and origin.x + SIZE_CHUNK > footprint_origin.x
		and origin.y < footprint_origin.y + footprint_size.y
		and origin.y + SIZE_CHUNK > footprint_origin.y
	)


func get_footprint_chunk_count() -> int:
	var chunks_x: int = int(ceil(float(footprint_size.x) / float(SIZE_CHUNK)))
	var chunks_z: int = int(ceil(float(footprint_size.y) / float(SIZE_CHUNK)))
	return chunks_x * chunks_z


func get_footprint_chunk_rect() -> Rect2i:
	if footprint_size.x <= 0 or footprint_size.y <= 0:
		return Rect2i()

	var min_chunk := Vector2i(
		floori(float(footprint_origin.x) / float(SIZE_CHUNK)),
		floori(float(footprint_origin.y) / float(SIZE_CHUNK))
	)
	var max_chunk := Vector2i(
		floori(float(footprint_origin.x + footprint_size.x - 1) / float(SIZE_CHUNK)),
		floori(float(footprint_origin.y + footprint_size.y - 1) / float(SIZE_CHUNK))
	)

	return Rect2i(min_chunk, max_chunk - min_chunk + Vector2i.ONE)


func sample_column(x: int, z: int) -> Dictionary:
	if not covers(x, z):
		return {}

	var top: int = _height_at(x, z)
	return {
		"height": top,
		"surface_item": surface_item,
		"subsurface_item": subsurface_item,
		"depth": maxi(1, column_depth),
	}


func generate_column(
	chunk: Vector2i,
	context: Dictionary = {}
) -> Array:
	var result: Array = []
	var chunk_size: int = int(context.get("chunk_size", 16))
	var min_y: int = int(context.get("min_y", -256))
	var max_y: int = int(context.get("max_y", 255))
	var origin: Vector2i = chunk * chunk_size
	var depth: int = maxi(1, column_depth)

	_ensure_coarse()

	# Sample the chunk plus a one-cell border once, so step detection does not
	# re-interpolate the height field four extra times per column.
	var span: int = chunk_size + 2
	var heights := PackedInt32Array()
	heights.resize(span * span)
	heights.fill(-1000000)

	for gx in span:
		for gz in span:
			var sample_x: int = origin.x + gx - 1
			var sample_z: int = origin.y + gz - 1

			if covers(sample_x, sample_z):
				heights[gx + gz * span] = _height_at(sample_x, sample_z)

	for local_x in chunk_size:
		for local_z in chunk_size:
			var world_x: int = origin.x + local_x
			var world_z: int = origin.y + local_z

			if not covers(world_x, world_z):
				continue

			var grid_x: int = local_x + 1
			var grid_z: int = local_z + 1
			var top: int = heights[grid_x + grid_z * span]

			for step in depth:
				var y: int = top - step

				if y < min_y or y > max_y:
					continue

				result.append({
					"position": Vector3i(world_x, y, world_z),
					"item": surface_item if step == 0 else subsurface_item,
					"orientation": 0,
				})

			if not step_slabs_enabled or step_slab_item < 0:
				continue

			var has_higher_neighbour: bool = (
				heights[grid_x + 1 + grid_z * span] > top
				or heights[grid_x - 1 + grid_z * span] > top
				or heights[grid_x + (grid_z + 1) * span] > top
				or heights[grid_x + (grid_z - 1) * span] > top
			)

			if not has_higher_neighbour:
				continue

			var slab_y: int = top + 1

			if slab_y < min_y or slab_y > max_y:
				continue

			result.append({
				"position": Vector3i(world_x, slab_y, world_z),
				"item": step_slab_item,
				"orientation": 0,
			})

	return result


# ---------------------------------------------------------------------------
# Height field
# ---------------------------------------------------------------------------

func _ensure_coarse() -> void:
	if _coarse_ready:
		return

	var spacing: int = maxi(1, coarse_spacing)
	var size_x: int = maxi(1, footprint_size.x)
	var size_z: int = maxi(1, footprint_size.y)

	_coarse_nx = int(ceil(float(size_x) / float(spacing))) + 1
	_coarse_nz = int(ceil(float(size_z) / float(spacing))) + 1
	_coarse_nx = maxi(2, _coarse_nx)
	_coarse_nz = maxi(2, _coarse_nz)

	var count: int = _coarse_nx * _coarse_nz
	_coarse = PackedFloat32Array()
	_coarse.resize(count)

	for gz in _coarse_nz:
		var base_row: int = gz * _coarse_nx
		var world_z: int = footprint_origin.y + gz * spacing

		for gx in _coarse_nx:
			var world_x: int = footprint_origin.x + gx * spacing
			var n: float = _fbm(world_x, world_z)
			n = lerpf(n, 1.0 - absf(2.0 * n - 1.0), ridge_amount)
			_coarse[base_row + gx] = (
				float(base_height) + (n - 0.5) * 2.0 * amplitude
			)

	_lipschitz_project(float(spacing))
	_coarse_ready = true


## Exact 4-neighbour min-plus projection:
## h[i] = min over all nodes j of (h0[j] + spacing * |i-j|_1).
## The result is Lipschitz along both axes, so bilinear interpolation changes
## by at most `spacing / spacing = 1` block per cell.
func _lipschitz_project(step: float) -> void:
	for gz in _coarse_nz:
		var base_row: int = gz * _coarse_nx

		for gx in _coarse_nx:
			var index: int = base_row + gx
			var value: float = _coarse[index]

			if gx > 0:
				value = minf(value, _coarse[index - 1] + step)
			if gz > 0:
				value = minf(value, _coarse[index - _coarse_nx] + step)

			_coarse[index] = value

	for gz in range(_coarse_nz - 1, -1, -1):
		var base_row: int = gz * _coarse_nx

		for gx in range(_coarse_nx - 1, -1, -1):
			var index: int = base_row + gx
			var value: float = _coarse[index]

			if gx < _coarse_nx - 1:
				value = minf(value, _coarse[index + 1] + step)
			if gz < _coarse_nz - 1:
				value = minf(value, _coarse[index + _coarse_nx] + step)

			_coarse[index] = value


func _height_at(x: int, z: int) -> int:
	_ensure_coarse()

	var spacing: float = float(maxi(1, coarse_spacing))
	var fx: float = float(x - footprint_origin.x) / spacing
	var fz: float = float(z - footprint_origin.y) / spacing

	var x0: int = clampi(floori(fx), 0, _coarse_nx - 2)
	var z0: int = clampi(floori(fz), 0, _coarse_nz - 2)
	var tx: float = clampf(fx - float(x0), 0.0, 1.0)
	var tz: float = clampf(fz - float(z0), 0.0, 1.0)

	var row0: int = z0 * _coarse_nx
	var row1: int = (z0 + 1) * _coarse_nx

	var h00: float = _coarse[row0 + x0]
	var h10: float = _coarse[row0 + x0 + 1]
	var h01: float = _coarse[row1 + x0]
	var h11: float = _coarse[row1 + x0 + 1]

	var top: float = lerpf(
		lerpf(h00, h10, tx),
		lerpf(h01, h11, tx),
		tz
	)
	return floori(top)


## Value-noise FBM in [0, 1]. No shared RNG; every lattice value comes from the
## coordinate hash, so the result is stable across processes and call orders.
func _fbm(x: int, z: int) -> float:
	var frequency: float = 1.0
	var octave_amplitude: float = 1.0
	var total: float = 0.0
	var normaliser: float = 0.0
	var scale_inv: float = 1.0 / maxf(1.0, scale)

	for octave in maxi(1, octaves):
		total += octave_amplitude * _value_noise(
			float(x) * frequency * scale_inv,
			float(z) * frequency * scale_inv,
			octave
		)
		normaliser += octave_amplitude
		octave_amplitude *= clampf(persistence, 0.0, 1.0)
		frequency *= maxf(1.0, lacunarity)

	return total / maxf(normaliser, 0.0001)


func _value_noise(x: float, z: float, salt: int) -> float:
	var x0: int = floori(x)
	var z0: int = floori(z)
	var tx: float = x - float(x0)
	var tz: float = z - float(z0)

	# Smoothstep keeps the interpolant C1 and reduces visible lattice creases.
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)

	var v00: float = _lattice(x0, z0, salt)
	var v10: float = _lattice(x0 + 1, z0, salt)
	var v01: float = _lattice(x0, z0 + 1, salt)
	var v11: float = _lattice(x0 + 1, z0 + 1, salt)

	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), tz)


func _lattice(x: int, z: int, salt: int) -> float:
	var h: int = WorldGenerator.hash_coords(noise_seed, x, z, salt * 7919)
	return float(h & 0xFFFF) / 65535.0
