class_name WaterWorld
extends Node3D

## Global 2.5D water height field.
##
## There is one world-wide field, split into fixed 32 x 32 m tiles so a lake can
## cross chunk and tile boundaries. Each simulation cell stores a terrain floor,
## a free height to a ceiling, a water volume and a surface. Shared edges carry
## a signed volume flux driven by the water-surface difference.
##
## The field is deliberately cheap: 2 m cells by default, a 10 Hz fixed step,
## only active tiles step, and tiles render as one top-quad ArrayMesh. There are
## no per-body bounds and no cloth/side-sheet layer.

const SHADER_PATH := "res://shaders/water_surface.gdshader"
const TILE_CELLS := 16
const DEFAULT_CELL_SIZE := 2.0
const SIM_STEP := 0.1
const EPSILON := 0.0004
const MESH_BUDGET_USEC := 2000
const SPLASH_POOL_SIZE := 8
const SPLASH_ENABLED := true

@export var cell_size: float = DEFAULT_CELL_SIZE
@export var max_depth: float = 8.0
## Linear pipe conductance. Higher levels water faster and is less stable.
@export_range(0.05, 5.0, 0.05) var pipe_conductance: float = 1.0
## Per-edge safety factor: total outflow from a cell is at most 4 * this.
@export_range(0.1, 0.25, 0.01) var flow_relax: float = 0.25
@export var flow_sleep_threshold: float = 0.0008
@export var sleep_after_seconds: float = 1.0
@export var splash_particles_enabled: bool = true
@export var auto_create_demo: bool = false
@export var demo_radius: float = 10.0
@export var demo_depth: float = 1.0


class Tile:
	var key: Vector2i = Vector2i.ZERO
	var origin: Vector2 = Vector2.ZERO
	var area: float = 4.0
	var floor_y: PackedFloat32Array = PackedFloat32Array()
	var capacity: PackedFloat32Array = PackedFloat32Array()
	var volume: PackedFloat32Array = PackedFloat32Array()
	var velocity_x: PackedFloat32Array = PackedFloat32Array()
	var velocity_z: PackedFloat32Array = PackedFloat32Array()
	var flux_x: PackedFloat32Array = PackedFloat32Array()
	var flux_z: PackedFloat32Array = PackedFloat32Array()
	var terrain_dirty: bool = false
	var active: bool = false
	var quiet_time: float = 0.0
	var dirty: bool = true
	var mesh_instance: MeshInstance3D = null

	func index(ix: int, iz: int) -> int:
		return iz * 16 + ix

	func depth_at(index: int) -> float:
		return volume[index] / area if index >= 0 and index < volume.size() else 0.0

	func surface_at(index: int) -> float:
		return floor_y[index] + depth_at(index)


var _grid: Node = null
var _material: ShaderMaterial = null
var _tiles: Dictionary = {}
var _active_tiles: Dictionary = {}
var _sim_accum: float = 0.0
var _splash_pool: Array[CPUParticles3D] = []
var _splash_cursor: int = 0


func _ready() -> void:
	add_to_group("water_world")
	_material = _make_material()
	if splash_particles_enabled and SPLASH_ENABLED:
		_create_splash_pool()
	_grid = get_tree().get_first_node_in_group("grid_map")
	if _grid != null:
		if not _grid.block_placed.is_connected(_on_block_changed):
			_grid.block_placed.connect(_on_block_changed)
		if not _grid.block_removed.is_connected(_on_block_removed):
			_grid.block_removed.connect(_on_block_removed)

	if auto_create_demo:
		var player := get_tree().get_first_node_in_group("player") as Node3D
		var center := player.global_position if player != null else Vector3.ZERO
		create_lake_at(center, demo_radius, demo_depth)


func _process(delta: float) -> void:
	if _tiles.is_empty():
		return

	_sim_accum += delta
	var steps := 0
	while _sim_accum >= SIM_STEP and steps < 2:
		_sim_accum -= SIM_STEP
		_step_all(SIM_STEP)
		steps += 1
	_update_meshes()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func get_stats() -> Dictionary:
	var cells := 0
	var wet := 0
	for tile: Tile in _tiles.values():
		cells += 256
		for value in tile.volume:
			if value > EPSILON:
				wet += 1
	return {
		"tiles": _tiles.size(),
		"cells": cells,
		"wet_cells": wet,
		"active_tiles": _active_tiles.size(),
	}


func clear_all() -> void:
	for tile: Tile in _tiles.values():
		if tile.mesh_instance != null and is_instance_valid(tile.mesh_instance):
			tile.mesh_instance.queue_free()
	_tiles.clear()
	_active_tiles.clear()
	_sim_accum = 0.0


## Creates a calm lake patch around a world position. Tiles are global, so this
## can cross chunk and tile boundaries without a body limit.
func create_lake_at(
	world_pos: Vector3,
	radius: float = 8.0,
	depth: float = 1.0,
	_simulated: bool = true,
	_cell_size: float = -1.0
) -> int:
	var ground := _floor_height_at(world_pos)
	var level := ground + maxf(depth, 0.05)
	_fill_level(world_pos, radius, level)
	return 1


## Adds or removes water height in a circular brush. Positive raises the local
## surface, negative lowers it. This is the water tool's primary operation.
func add_water_height(world_pos: Vector3, radius: float, height_delta: float) -> int:
	return _change_height(world_pos, radius, height_delta)


func remove_water_height(world_pos: Vector3, radius: float, height_delta: float) -> int:
	return _change_height(world_pos, radius, -absf(height_delta))


## Adds volume per cell (m3) in a radius. Kept for the console/Useables paths.
func add_water_area(world_pos: Vector3, radius: float, amount_per_cell: float) -> int:
	if amount_per_cell <= 0.0:
		return 0
	var changed := 0
	var tiles := _tiles_in_radius(world_pos, radius)
	for tile: Tile in tiles:
		for iz in TILE_CELLS:
			for ix in TILE_CELLS:
				var index := tile.index(ix, iz)
				if tile.capacity[index] <= 0.0:
					continue
				var center := _cell_center(tile, ix, iz)
				if Vector2(center.x - world_pos.x, center.z - world_pos.z).length() > radius:
					continue
				tile.volume[index] = minf(
					tile.capacity[index],
					tile.volume[index] + amount_per_cell
				)
				tile.dirty = true
				_wake_tile(tile.key)
				changed += 1
	return changed


func remove_water_area(world_pos: Vector3, radius: float, amount_per_cell: float) -> int:
	if amount_per_cell <= 0.0:
		return 0
	var changed := 0
	var tiles := _tiles_in_radius(world_pos, radius)
	for tile: Tile in tiles:
		for iz in TILE_CELLS:
			for ix in TILE_CELLS:
				var index := tile.index(ix, iz)
				if tile.volume[index] <= 0.0:
					continue
				var center := _cell_center(tile, ix, iz)
				if Vector2(center.x - world_pos.x, center.z - world_pos.z).length() > radius:
					continue
				tile.volume[index] = maxf(0.0, tile.volume[index] - amount_per_cell)
				tile.dirty = true
				_wake_tile(tile.key)
				changed += 1
	return changed


## One agent-facing sample. Returns {} when the point is not inside water.
func sample_water(world_pos: Vector3) -> Dictionary:
	var key := _tile_key(world_pos)
	var tile: Tile = _tiles.get(key)
	if tile == null:
		return {}
	var coords := _local_cell(tile, world_pos)
	var index := tile.index(coords.x, coords.y)
	var depth := tile.depth_at(index)
	if depth <= 0.01:
		return {}
	var floor_y := tile.floor_y[index]
	var surface_y := floor_y + depth
	if world_pos.y > surface_y + 0.02:
		return {}
	if world_pos.y < floor_y - 0.2:
		return {}
	return {
		"in_water": true,
		"floor_y": floor_y,
		"surface_y": surface_y,
		"depth": depth,
		"submerged": maxf(0.0, surface_y - world_pos.y),
		"flow": Vector2(tile.velocity_x[index], tile.velocity_z[index]),
		"cell_size": cell_size,
	}


func water_depth_at(world_pos: Vector3) -> float:
	var sample := sample_water(world_pos)
	return float(sample.get("depth", 0.0)) if not sample.is_empty() else 0.0


func get_water_surface(world_pos: Vector3) -> float:
	var sample := sample_water(world_pos)
	return float(sample.get("surface_y", -INF)) if not sample.is_empty() else -INF


## Wake/impulse helper. It raises a small local surface and shows a splash.
func add_impulse(world_pos: Vector3, radius: float, strength: float) -> void:
	_add_height_direct(world_pos, radius, maxf(0.0, strength))
	spawn_splash(world_pos, clampf(strength * 3.0, 0.4, 2.0))


func spawn_splash(world_pos: Vector3, strength: float = 1.0) -> void:
	if _splash_pool.is_empty():
		return
	var particles := _splash_pool[_splash_cursor]
	_splash_cursor = (_splash_cursor + 1) % _splash_pool.size()
	particles.global_position = world_pos + Vector3.UP * 0.06
	particles.amount = clampi(int(6.0 + strength * 8.0), 4, 24)
	particles.restart()
	particles.emitting = true


# ---------------------------------------------------------------------------
# Height operations
# ---------------------------------------------------------------------------

func _change_height(world_pos: Vector3, radius: float, height_delta: float) -> int:
	if radius <= 0.0 or absf(height_delta) <= 0.00001:
		return 0
	var area := cell_size * cell_size
	var changed := 0
	var tiles := _tiles_in_radius(world_pos, radius)
	for tile: Tile in tiles:
		for iz in TILE_CELLS:
			for ix in TILE_CELLS:
				var index := tile.index(ix, iz)
				if tile.capacity[index] <= 0.0:
					continue
				var center := _cell_center(tile, ix, iz)
				var distance := Vector2(center.x - world_pos.x, center.z - world_pos.z).length()
				if distance > radius:
					continue
				var falloff := clampf(1.0 - (distance / radius) * (distance / radius), 0.0, 1.0)
				var delta_volume := height_delta * area * falloff
				tile.volume[index] = clampf(
					tile.volume[index] + delta_volume,
					0.0,
					tile.capacity[index]
				)
				tile.dirty = true
				_wake_tile(tile.key)
				changed += 1
	return changed


func _add_height_direct(world_pos: Vector3, radius: float, height_delta: float) -> int:
	return _change_height(world_pos, radius, height_delta)


func _fill_level(world_pos: Vector3, radius: float, level: float) -> void:
	var area := cell_size * cell_size
	var tiles := _tiles_in_radius(world_pos, radius)
	for tile: Tile in tiles:
		for iz in TILE_CELLS:
			for ix in TILE_CELLS:
				var index := tile.index(ix, iz)
				if tile.capacity[index] <= 0.0:
					continue
				var center := _cell_center(tile, ix, iz)
				if Vector2(center.x - world_pos.x, center.z - world_pos.z).length() > radius:
					continue
				var depth := clampf(level - tile.floor_y[index], 0.0, 100.0)
				tile.volume[index] = minf(tile.capacity[index], depth * area)
				tile.dirty = true
				_wake_tile(tile.key)


func _floor_height_at(world_pos: Vector3) -> float:
	var key := _tile_key(world_pos)
	var tile := _ensure_tile(key)
	var coords := _local_cell(tile, world_pos)
	var index := tile.index(coords.x, coords.y)
	if tile.capacity[index] <= 0.0:
		return world_pos.y
	return tile.floor_y[index]


# ---------------------------------------------------------------------------
# Tiles and terrain
# ---------------------------------------------------------------------------

func _tile_key(world_pos: Vector3) -> Vector2i:
	var tile_world := cell_size * float(TILE_CELLS)
	return Vector2i(
		floori(world_pos.x / tile_world),
		floori(world_pos.z / tile_world)
	)


func _tile_world_size() -> float:
	return cell_size * float(TILE_CELLS)


func _ensure_tile(key: Vector2i) -> Tile:
	var existing: Tile = _tiles.get(key)
	if existing != null:
		return existing
	var tile := Tile.new()
	tile.key = key
	tile.area = cell_size * cell_size
	tile.origin = Vector2(
		float(key.x) * _tile_world_size(),
		float(key.y) * _tile_world_size()
	)
	var count := TILE_CELLS * TILE_CELLS
	tile.floor_y.resize(count)
	tile.capacity.resize(count)
	tile.volume.resize(count)
	tile.velocity_x.resize(count)
	tile.velocity_z.resize(count)
	tile.flux_x.resize(count)
	tile.flux_z.resize(count)
	for index in count:
		tile.floor_y[index] = 0.0
		tile.capacity[index] = 0.0
		tile.volume[index] = 0.0
		tile.velocity_x[index] = 0.0
		tile.velocity_z[index] = 0.0
		tile.flux_x[index] = 0.0
		tile.flux_z[index] = 0.0
	tile.mesh_instance = MeshInstance3D.new()
	tile.mesh_instance.name = "WaterTile_%d_%d" % [key.x, key.y]
	tile.mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tile.mesh_instance.material_override = _material
	add_child(tile.mesh_instance)
	_tiles[key] = tile
	_rebuild_tile_terrain(tile)
	return tile


func _rebuild_tile_terrain(tile: Tile) -> void:
	var intervals: Dictionary = {}
	var tile_world := _tile_world_size()
	var xmin := int(floor(tile.origin.x))
	var xmax := int(ceil(tile.origin.x + tile_world)) - 1
	var zmin := int(floor(tile.origin.y))
	var zmax := int(ceil(tile.origin.y + tile_world)) - 1
	var chunk_x0 := floori(float(xmin) / 16.0)
	var chunk_x1 := floori(float(xmax) / 16.0)
	var chunk_z0 := floori(float(zmin) / 16.0)
	var chunk_z1 := floori(float(zmax) / 16.0)

	if _grid != null and _grid.mesh_library != null:
		for chunk_z in range(chunk_z0, chunk_z1 + 1):
			for chunk_x in range(chunk_x0, chunk_x1 + 1):
				var cells: Array = []
				var items: Array = []
				_grid.get_chunk_cells_and_items(Vector2i(chunk_x, chunk_z), cells, items)
				for cell_index in cells.size():
					var cell: Vector3i = cells[cell_index]
					if cell.x < xmin or cell.x > xmax or cell.z < zmin or cell.z > zmax:
						continue
					var item_name := String(_grid.mesh_library.get_item_name(int(items[cell_index])))
					var units := _top_units_for_item(item_name)
					var key := Vector2i(cell.x, cell.z)
					if not intervals.has(key):
						intervals[key] = []
					intervals[key].append(Vector2(float(cell.y), float(cell.y) + units))

	for key: Vector2i in intervals.keys():
		var list: Array = intervals[key]
		list.sort_custom(func(a: Vector2, b: Vector2) -> bool:
			return a.x < b.x
		)
		var merged: Array = []
		for interval: Vector2 in list:
			if merged.is_empty() or interval.x > float(merged[merged.size() - 1].y) + 0.001:
				merged.append(interval)
			else:
				var last: Vector2 = merged[merged.size() - 1]
				last.y = maxf(last.y, interval.y)
				merged[merged.size() - 1] = last
		intervals[key] = merged

	var block_step := maxi(1, int(round(cell_size)))
	for iz in TILE_CELLS:
		for ix in TILE_CELLS:
			var index := tile.index(ix, iz)
			var base_x := int(tile.origin.x) + ix * block_step
			var base_z := int(tile.origin.y) + iz * block_step
			var floor_min := INF
			var floor_max := -INF
			var ceiling_min := INF
			var missing := false
			for sz in block_step:
				for sx in block_step:
					var column: Array = intervals.get(Vector2i(base_x + sx, base_z + sz), [])
					if column.is_empty():
						missing = true
						continue
					var lowest: Vector2 = column[0]
					var floor_value := float(lowest.y)
					var ceiling_value := floor_value + max_depth
					if column.size() > 1:
						ceiling_value = float(column[1].x)
					floor_min = minf(floor_min, floor_value)
					floor_max = maxf(floor_max, floor_value)
					ceiling_min = minf(ceiling_min, ceiling_value)
			# A coarse cell cannot represent a wall or a full one-block step
			# inside itself. Treat that subcolumn mix as solid so water does not
			# render through the wall.
			if (
				missing
				or ceiling_min <= floor_min + 0.001
				or floor_max - floor_min > 0.75
			):
				tile.floor_y[index] = floor_min if floor_min < INF else 0.0
				tile.capacity[index] = 0.0
				tile.volume[index] = 0.0
			else:
				tile.floor_y[index] = floor_min
				var usable := clampf(ceiling_min - floor_min, 0.0, max_depth)
				tile.capacity[index] = tile.area * usable
	tile.terrain_dirty = false


func _top_units_for_item(item_name: String) -> float:
	var lower := item_name.to_lower()
	if lower.contains("panel_top"):
		return 1.0
	if lower.contains("panel"):
		return 3.0 / 16.0
	if lower.contains("slab_side"):
		return 1.0
	if lower.contains("slab_top"):
		return 1.0
	if lower.contains("slab"):
		return 0.5
	if lower.contains("stair"):
		return 1.0
	return 1.0


func _tiles_in_radius(world_pos: Vector3, radius: float) -> Array[Tile]:
	var tile_world := _tile_world_size()
	var min_key := Vector2i(
		floori((world_pos.x - radius) / tile_world),
		floori((world_pos.z - radius) / tile_world)
	)
	var max_key := Vector2i(
		floori((world_pos.x + radius) / tile_world),
		floori((world_pos.z + radius) / tile_world)
	)
	var result: Array[Tile] = []
	for kz in range(min_key.y, max_key.y + 1):
		for kx in range(min_key.x, max_key.x + 1):
			var key := Vector2i(kx, kz)
			result.append(_ensure_tile(key))
	return result


func _cell_center(tile: Tile, ix: int, iz: int) -> Vector3:
	return Vector3(
		tile.origin.x + (float(ix) + 0.5) * cell_size,
		0.0,
		tile.origin.y + (float(iz) + 0.5) * cell_size
	)


func _local_cell(tile: Tile, world_pos: Vector3) -> Vector2i:
	return Vector2i(
		clampi(floori((world_pos.x - tile.origin.x) / cell_size), 0, TILE_CELLS - 1),
		clampi(floori((world_pos.z - tile.origin.y) / cell_size), 0, TILE_CELLS - 1)
	)


func _on_block_changed(cell: Vector3i, _item: int = -1) -> void:
	_on_block_removed(cell)


func _on_block_removed(cell: Vector3i) -> void:
	var size := _tile_world_size()
	var key := Vector2i(
		floori(float(cell.x) / size),
		floori(float(cell.z) / size)
	)
	var tile: Tile = _tiles.get(key)
	if tile == null:
		return
	tile.terrain_dirty = true
	_wake_tile(key)


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

func _wake_tile(key: Vector2i) -> void:
	var tile: Tile = _tiles.get(key)
	if tile == null:
		return
	tile.active = true
	tile.quiet_time = 0.0
	_active_tiles[key] = true


func _step_all(dt: float) -> void:
	for key: Vector2i in _active_tiles.keys():
		var tile: Tile = _tiles.get(key)
		if tile == null:
			_active_tiles.erase(key)
			continue
		if tile.terrain_dirty:
			_rebuild_tile_terrain(tile)
			for index in tile.volume.size():
				tile.volume[index] = clampf(tile.volume[index], 0.0, tile.capacity[index])
			tile.dirty = true
		if not tile.active:
			_active_tiles.erase(key)
			continue
		_step_tile(tile, dt)
		if not tile.active:
			_active_tiles.erase(key)


func _step_tile(tile: Tile, dt: float) -> void:
	var right_key := tile.key + Vector2i(1, 0)
	var down_key := tile.key + Vector2i(0, 1)
	# Touch all four sides so a wet edge can create its neighbour tile. A
	# left/up neighbour is stepped on the next frame and then feeds this tile.
	_neighbour_tile(tile, tile.key + Vector2i(-1, 0))
	_neighbour_tile(tile, tile.key + Vector2i(0, -1))
	var right_tile := _neighbour_tile(tile, right_key)
	var down_tile := _neighbour_tile(tile, down_key)
	var max_change := 0.0

	for iz in TILE_CELLS:
		for ix in TILE_CELLS - 1:
			var index := tile.index(ix, iz)
			tile.flux_x[index] = _edge_flux(
				tile, index, tile, index + 1, dt
			)
			max_change = maxf(max_change, absf(tile.flux_x[index]))
		var edge_index := tile.index(TILE_CELLS - 1, iz)
		if right_tile != null:
			tile.flux_x[edge_index] = _edge_flux(
				tile, edge_index, right_tile, right_tile.index(0, iz), dt
			)
			max_change = maxf(max_change, absf(tile.flux_x[edge_index]))
		else:
			tile.flux_x[edge_index] = 0.0

	for iz in TILE_CELLS - 1:
		for ix in TILE_CELLS:
			var index := tile.index(ix, iz)
			tile.flux_z[index] = _edge_flux(
				tile, index, tile, index + TILE_CELLS, dt
			)
			max_change = maxf(max_change, absf(tile.flux_z[index]))
	for ix in TILE_CELLS:
		var edge_index := tile.index(ix, TILE_CELLS - 1)
		if down_tile != null:
			tile.flux_z[edge_index] = _edge_flux(
				tile, edge_index, down_tile, down_tile.index(ix, 0), dt
			)
			max_change = maxf(max_change, absf(tile.flux_z[edge_index]))
		else:
			tile.flux_z[edge_index] = 0.0

	for iz in TILE_CELLS:
		for ix in TILE_CELLS - 1:
			var index := tile.index(ix, iz)
			var flow := tile.flux_x[index]
			if absf(flow) <= EPSILON:
				continue
			tile.volume[index] -= flow
			tile.volume[index + 1] += flow
			tile.dirty = true
		var edge_index := tile.index(TILE_CELLS - 1, iz)
		var edge_flow := tile.flux_x[edge_index]
		if absf(edge_flow) <= EPSILON:
			continue
		tile.volume[edge_index] -= edge_flow
		if right_tile != null:
			right_tile.volume[right_tile.index(0, iz)] += edge_flow
			right_tile.dirty = true
			if absf(edge_flow) > 0.001:
				_wake_tile(right_tile.key)

	for iz in TILE_CELLS - 1:
		for ix in TILE_CELLS:
			var index := tile.index(ix, iz)
			var flow := tile.flux_z[index]
			if absf(flow) <= EPSILON:
				continue
			tile.volume[index] -= flow
			tile.volume[index + TILE_CELLS] += flow
			tile.dirty = true
	for ix in TILE_CELLS:
		var edge_index := tile.index(ix, TILE_CELLS - 1)
		var edge_flow := tile.flux_z[edge_index]
		if absf(edge_flow) <= EPSILON:
			continue
		tile.volume[edge_index] -= edge_flow
		if down_tile != null:
			down_tile.volume[down_tile.index(ix, 0)] += edge_flow
			down_tile.dirty = true
			if absf(edge_flow) > 0.001:
				_wake_tile(down_tile.key)

	for index in tile.volume.size():
		tile.volume[index] = clampf(tile.volume[index], 0.0, tile.capacity[index])
		var ix := index % TILE_CELLS
		var iz := index / TILE_CELLS
		var left := tile.flux_x[index - 1] if ix > 0 else 0.0
		var right := tile.flux_x[index] if ix < TILE_CELLS - 1 else 0.0
		var up := tile.flux_z[index - TILE_CELLS] if iz > 0 else 0.0
		var down := tile.flux_z[index] if iz < TILE_CELLS - 1 else 0.0
		tile.velocity_x[index] = (right - left) / (tile.area * dt)
		tile.velocity_z[index] = (down - up) / (tile.area * dt)

	if max_change < flow_sleep_threshold:
		tile.quiet_time += dt
		if tile.quiet_time >= sleep_after_seconds:
			tile.active = false
			tile.quiet_time = 0.0
	else:
		tile.quiet_time = 0.0


func _neighbour_tile(tile: Tile, key: Vector2i) -> Tile:
	var neighbour: Tile = _tiles.get(key)
	if neighbour != null:
		return neighbour
	# Only create a neighbour when the touching edge is wet. This lets a lake
	# spread across tile/chunk borders without pre-building the whole world.
	var edge_wet := false
	if key.x > tile.key.x:
		for iz in TILE_CELLS:
			if tile.depth_at(tile.index(TILE_CELLS - 1, iz)) > EPSILON:
				edge_wet = true
				break
	elif key.x < tile.key.x:
		for iz in TILE_CELLS:
			if tile.depth_at(tile.index(0, iz)) > EPSILON:
				edge_wet = true
				break
	elif key.y > tile.key.y:
		for ix in TILE_CELLS:
			if tile.depth_at(tile.index(ix, TILE_CELLS - 1)) > EPSILON:
				edge_wet = true
				break
	else:
		for ix in TILE_CELLS:
			if tile.depth_at(tile.index(ix, 0)) > EPSILON:
				edge_wet = true
				break
	if not edge_wet:
		return null
	var created := _ensure_tile(key)
	_wake_tile(key)
	return created


func _edge_flux(a_tile: Tile, a: int, b_tile: Tile, b: int, dt: float) -> float:
	if a_tile.capacity[a] <= 0.0 or b_tile.capacity[b] <= 0.0:
		return 0.0
	var surface_a := a_tile.floor_y[a] + a_tile.volume[a] / a_tile.area
	var surface_b := b_tile.floor_y[b] + b_tile.volume[b] / b_tile.area
	var head := surface_a - surface_b
	if absf(head) <= EPSILON:
		return 0.0
	var free_a := maxf(0.0, a_tile.capacity[a] - a_tile.volume[a])
	var free_b := maxf(0.0, b_tile.capacity[b] - b_tile.volume[b])
	var limit := minf(a_tile.volume[a], free_b) * flow_relax if head >= 0.0 else minf(b_tile.volume[b], free_a) * flow_relax
	if limit <= EPSILON:
		return 0.0
	return clampf(
		pipe_conductance * head * a_tile.area * dt,
		-limit,
		limit
	)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _make_material() -> ShaderMaterial:
	var shader: Shader = load(SHADER_PATH) as Shader
	if shader == null:
		return null
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = 1
	return material


func _update_meshes() -> void:
	var start := Time.get_ticks_usec()
	for tile: Tile in _tiles.values():
		if not tile.dirty:
			continue
		tile.dirty = false
		_rebuild_tile_mesh(tile)
		if Time.get_ticks_usec() - start >= MESH_BUDGET_USEC:
			return


func _rebuild_tile_mesh(tile: Tile) -> void:
	if tile.mesh_instance == null:
		return
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var inv := global_transform.affine_inverse()
	for iz in TILE_CELLS:
		for ix in TILE_CELLS:
			var index := tile.index(ix, iz)
			var depth := tile.depth_at(index)
			if depth <= 0.02:
				continue
			var x0 := tile.origin.x + float(ix) * cell_size
			var x1 := x0 + cell_size
			var z0 := tile.origin.y + float(iz) * cell_size
			var z1 := z0 + cell_size
			var y := tile.floor_y[index] + depth
			var base := verts.size()
			verts.append(inv * Vector3(x0, y, z0))
			verts.append(inv * Vector3(x0, y, z1))
			verts.append(inv * Vector3(x1, y, z1))
			verts.append(inv * Vector3(x1, y, z0))
			for _i in 4:
				normals.append(Vector3.UP)
				uvs.append(Vector2(x0, z0))
				uv2s.append(Vector2(clampf(depth / 4.0, 0.0, 1.0), 0.0))
			indices.append(base)
			indices.append(base + 1)
			indices.append(base + 2)
			indices.append(base)
			indices.append(base + 2)
			indices.append(base + 3)
	if verts.is_empty():
		tile.mesh_instance.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	tile.mesh_instance.mesh = mesh


func _create_splash_pool() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.11, 0.11)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.62, 0.84, 1.0, 0.8)
	quad.material = material
	for index in SPLASH_POOL_SIZE:
		var particles := CPUParticles3D.new()
		particles.name = "WaterSplash_%d" % index
		particles.emitting = false
		particles.one_shot = true
		particles.amount = 10
		particles.lifetime = 0.6
		particles.explosiveness = 0.9
		particles.randomness = 0.35
		particles.direction = Vector3.UP
		particles.spread = 55.0
		particles.initial_velocity_min = 1.2
		particles.initial_velocity_max = 2.6
		particles.gravity = Vector3(0.0, -9.8, 0.0)
		particles.scale_amount_min = 0.55
		particles.scale_amount_max = 1.4
		particles.color = Color(0.62, 0.84, 1.0, 0.8)
		particles.mesh = quad
		particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(particles)
		_splash_pool.append(particles)


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

func serialize() -> Dictionary:
	var entries: Array = []
	for tile: Tile in _tiles.values():
		var wet := false
		for value in tile.volume:
			if value > EPSILON:
				wet = true
				break
		if not wet:
			continue
		entries.append({
			"key": [tile.key.x, tile.key.y],
			"floor": Marshalls.raw_to_base64(var_to_bytes(tile.floor_y)),
			"capacity": Marshalls.raw_to_base64(var_to_bytes(tile.capacity)),
			"volume": Marshalls.raw_to_base64(var_to_bytes(tile.volume)),
		})
	return {
		"version": 2,
		"cell_size": cell_size,
		"tiles": entries,
	}


func deserialize(data: Dictionary) -> void:
	clear_all()
	if data.is_empty():
		return
	cell_size = float(data.get("cell_size", cell_size))
	for entry: Dictionary in data.get("tiles", []):
		var key_values: Array = entry.get("key", [])
		if key_values.size() != 2:
			continue
		var key := Vector2i(int(key_values[0]), int(key_values[1]))
		var tile := _ensure_tile(key)
		var floor_values := _decode_float_array(entry.get("floor", ""))
		var capacity_values := _decode_float_array(entry.get("capacity", ""))
		var volume_values := _decode_float_array(entry.get("volume", ""))
		if floor_values.size() == 256:
			tile.floor_y = floor_values
		if capacity_values.size() == 256:
			tile.capacity = capacity_values
		if volume_values.size() == 256:
			tile.volume = volume_values
		tile.dirty = true
		_wake_tile(key)


func _decode_float_array(value: Variant) -> PackedFloat32Array:
	if not (value is String) or String(value).is_empty():
		return PackedFloat32Array()
	var bytes := Marshalls.base64_to_raw(String(value))
	if bytes.is_empty():
		return PackedFloat32Array()
	var decoded: Variant = bytes_to_var(bytes)
	if decoded is PackedFloat32Array:
		return decoded
	return PackedFloat32Array()
