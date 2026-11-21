class_name WaterSystem
extends Node3D

## Lightweight voxel water layer.
##
## Every water cell stores a float depth from 0 to its capacity. Air and water
## items hold a full block (MAX_HEIGHT = 16 units); waterlogged partial blocks
## hold less, so water no longer clips through slabs, panels or stairs:
## a bottom slab leaves the top half free, a top slab the bottom half, a bottom
## panel leaves all but 3/16, and a top panel caps the cell. Stairs and
## side-mounted variants use the slab rule because a height field cannot express
## a vertical half-cell.
##
## Water falls when it can, spreads into lower horizontal neighbours, and a
## periodic hydrostatic pass fills lower layers before sharing the remainder
## across the top layer. That is the same down/spread/level behaviour as a
## cellular mass model, while keeping one float per cell for cheap rendering.
##
## Surface and full water are the same volume; the exposed top renders slightly
## lower and picks as "Water_Surface", while covered water picks as "Water_Full".

const MAX_HEIGHT := 16
## Solid footprint of a bottom/top slab, in 1/16-block water units. Water can
## occupy the other half only; it no longer fills the whole cell and clips
## through the slab.
const SLAB_UNITS := 8.0
## Generated panels are 3 texture pixels thick (3/16 of a block).
const PANEL_UNITS := 3.0
## Mirrors Member.FALL_KILL_MARGIN_BLOCKS: water this far below the chunk's
## lowest block is destroyed instead of falling forever.
const FALL_KILL_MARGIN_BLOCKS := 5.0

const WATER_SURFACE := "Water_Surface"
const WATER_FULL := "Water_Full"
const WATER_SLAB := "Water_Slab"
const WATER_PANEL := "Water_Panel"

const FACE_NORMALS: Array[Vector3i] = [
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
]

const WALL_FACES: Array[int] = [0, 1, 4, 5]
const NO_CELL := Vector3i(2147483647, 0, 0)
## Extra foam texels drawn inside the shoreline. The shader uses UV.y as the
## distance from the crisp outer strip, so this controls how far the denser
## inner foam band reaches into the water.
## The sea-foam texture is 64x5; each texture pixel is one 1/16 m voxel texel.
const FOAM_TEXELS := 5
const FOAM_TEXTURE_WIDTH := 64.0
## Lift the unshaded foam slightly above the water surface.
const EDGE_SURFACE_OFFSET := 0.01

## Reference wake palette (transparent -> faint slate -> light gray-blue ->
## pale gray-blue -> white).
const WAKE_PALETTE: Array[Color] = [
	Color(0.0, 0.0, 0.0, 0.0),
	Color(0.576, 0.600, 0.651, 0.157),
	Color(0.620, 0.647, 0.690, 0.392),
	Color(0.769, 0.792, 0.820, 0.706),
	Color(1.0, 1.0, 1.0, 1.0),
]

## Fewer, more saturated colours for the vivid wake style.
const VIVID_PALETTE: Array[Color] = [
	Color(0.05, 0.35, 0.80, 0.0),
	Color(0.10, 0.55, 0.95, 0.45),
	Color(0.45, 0.80, 1.00, 0.85),
	Color(1.0, 1.0, 1.0, 1.0),
]

@export var flow_interval: float = 0.15
@export var global_equalize_interval: float = 0.5
@export var max_updates_per_tick: int = 512
## Visual mesh rebuild rate while the flow is changing. Flow runs at
## flow_interval, so 20 Hz is already smoother than the simulation.
@export var mesh_rebuild_interval: float = 0.05
@export_range(0.05, 1.0, 0.01) var surface_level: float = 0.9

@export_group("Waves")
## Master switch for the 2D wave simulation and wake rendering.
@export var waves_enabled: bool = true
## Ambient surface droplets. Disable together with waves on low-end machines.
@export var surface_particles_enabled: bool = true
## Entry/impact splash sprites. The wake brush and ripple are still emitted
## when this is off; only the particle sprites are skipped.
@export var splashes_enabled: bool = true
## World-space distance between wave samples.
@export var wave_step: float = 0.125
@export var wave_update_interval: float = 0.05
## Crest/wake mesh updates are cheaper than simulation but still cost ~3 ms on
## a large pool. 10 Hz looks continuous against 20 Hz simulation.
@export var wave_mesh_interval: float = 0.1
@export var wave_speed: float = 1.4
@export_range(0.9, 1.0, 0.001) var wave_damping: float = 0.995
@export var wave_crest_threshold: float = 0.005
## Relative wake thickness. Lower values raise the draw threshold and make
## the visible wake thinner; higher values make it fatter.
@export_range(0.25, 2.0, 0.05) var wake_thickness: float = 0.85
## How quickly the wake reaches the bright palette bands. Higher values keep
## more of the wake in the darker blue bands.
@export_range(1.0, 32.0, 1.0) var wake_band_scale: float = 8.0
## Strength of the stochastic palette dither. 0 = clean bands, 1 = full dither.
@export_range(0.0, 1.0, 0.01) var wake_dither: float = 0.5
## Texel size of the dither pattern. 1 is per-texel (finest); larger values
## make the dither coarser.
@export_range(1, 4, 1) var wake_dither_scale: int = 1
## How ragged the low-amplitude edge is. 0 = smooth edge, higher = more holes.
@export_range(0.0, 2.0, 0.05) var wake_edge_dither: float = 0
@export var wave_max_samples: int = 32768
@export var ambient_wave_interval: float = 1.2
@export var ambient_wave_strength: float = 0.045
@export var brush_interval: float = 0.08
@export_enum("Soft", "Vivid") var wake_style: int = 1
@export_range(0.9, 1.0, 0.001) var vivid_wave_damping: float = 0.982

@export_group("Splashes")
@export var splash_particle_count: int = 32
@export var splash_lifetime: float = 0.6
@export var splash_size: float = 0.25
@export var splash_rotation_interval: float = 0.12
@export var splash_gravity: float = 4.0
@export var splash_surface_interval: float = 0.3

var _grid = null
## Vector3i -> float depth (0..capacity). Only non-empty cells are stored.
var _cells: Dictionary = {}
var _active: Dictionary = {}
var _dirty: bool = false
var _tick_accum: float = 0.0
var _mesh_accum: float = 0.0
var _global_accum: float = 0.0
var _global_dirty: bool = true
## Incremental hydrostatic pass state. A large body is scanned over several
## frames instead of one 17–30 ms spike.
var _eq_active: bool = false
var _eq_keys: Array = []
var _eq_key_index: int = 0
var _eq_visited: Dictionary = {}
var _eq_queue: Array[Vector3i] = []
var _eq_body: Array[Vector3i] = []
var _eq_start_y: int = 0
var _eq_expanded: bool = false
## One water/foam/corner mesh pair per 16x16 grid chunk, so a change only
## rebuilds the chunks it touches and the renderer can frustum-cull them
## independently.
var _water_chunks: Dictionary = {}
var _mesh_dirty_chunks: Dictionary = {}
var _ripple_instance: MeshInstance3D = null
var _water_material: ShaderMaterial = null
var _foam_material: ShaderMaterial = null
var _foam_corner_material: StandardMaterial3D = null
var _ripple_material: StandardMaterial3D = null
var _preview_material: StandardMaterial3D = null
var _preview: Texture2D = null
var _item_ids: Dictionary = {}
var _waterloggable_cache: Dictionary = {}
var _water_bounds_cache: Dictionary = {}
## Per-pass cell -> (base, capacity). Cleared at the start of each flow tick,
## mesh rebuild and block change so repeated neighbour queries stay cheap.
var _bounds_scratch: Dictionary = {}

var _wave_curr := PackedFloat32Array()
var _wave_prev := PackedFloat32Array()
var _wave_next := PackedFloat32Array()
var _wave_wet := PackedByteArray()
var _wave_top := PackedFloat32Array()
var _wave_width: int = 0
var _wave_height: int = 0
var _wave_step_actual: float = 0.125
var _wave_origin := Vector3.ZERO
var _wave_layer_y: int = 0
var _wave_bounds_min := Vector2i.ZERO
var _wave_bounds_max := Vector2i.ZERO
var _wave_accum: float = 0.0
var _wave_mesh_accum: float = 0.0
var _wave_layout_accum: float = 0.0
var _ambient_wave_accum: float = 0.0
var _brush_accum: float = 0.0
var _brush_last_pos: Dictionary = {}
var _wave_cell_count: int = 0

var _splash_texture: Texture2D = null
var _splash_atlas: Texture2D = null
var _splash_nodes: Array[Sprite3D] = []
var _splash_ripples: Array[Dictionary] = []
var _splash_ripple_instance: MeshInstance3D = null
var _splash_surface_accum: float = 0.0
var _splash_ripple_accum: float = 0.0
var _air_y: Dictionary = {}


func setup(grid) -> void:
	_grid = grid
	_ensure_items()
	_create_renderer()

	if _grid != null:
		_grid.block_placed.connect(_on_block_changed)
		_grid.block_removed.connect(_on_block_changed)


func _on_block_changed(cell: Vector3i, _item: int = -1) -> void:
	_bounds_scratch.clear()
	# A full block placed into a water cell displaces the water.
	if _grid.get_block_item(cell) != -1 and not _is_waterloggable(cell):
		if _cells.erase(cell):
			_mark_cell_dirty(cell)
			_dirty = true
	elif _cells.has(cell):
		# A partial block shrinks the free space; push the displaced volume
		# upward instead of letting the column clip through the new block.
		var capacity := _water_capacity(cell)
		var current := get_height(cell)
		if current > capacity + 0.0001:
			_set_height(cell, capacity)
			_add_stacked(cell + Vector3i.UP, current - capacity)

	if _cells.has(cell):
		_active[cell] = true

	for direction: Vector3i in FACE_NORMALS:
		var neighbour := cell + direction
		if _cells.has(neighbour):
			_active[neighbour] = true
	_dirty = true
	_global_dirty = true


func _process(delta: float) -> void:
	if _grid == null:
		return

	_tick_accum += delta
	if _tick_accum >= flow_interval:
		_tick_accum = 0.0
		_tick()

	# Local equalization is fast for small puddles but diffuses slowly across
	# a large body. A periodic hydrostatic pass removes any leftover gradient
	# in one step: lower layers fill first, the top layer evens out.
	_global_accum += delta
	if _eq_active:
		_equalize_all_bodies()
	elif _global_accum >= global_equalize_interval:
		_global_accum = 0.0
		if _global_dirty:
			_equalize_all_bodies()

	_update_waves(delta)
	_update_splash_particles(delta)
	_splash_ripple_accum += delta

	if _splash_ripple_accum >= 0.05:
		var ripple_step: float = _splash_ripple_accum
		_splash_ripple_accum = 0.0
		_update_splash_ripples(ripple_step)

	_splash_surface_accum += delta
	if (
		surface_particles_enabled
		and _splash_surface_accum >= splash_surface_interval
	):
		_splash_surface_accum = 0.0
		_spawn_surface_water_particles()

	if _dirty:
		_mesh_accum += delta
		if _mesh_accum >= mesh_rebuild_interval:
			_mesh_accum = 0.0
			_rebuild_mesh()
			_dirty = false
	else:
		# Rebuild immediately on the next change after an idle period.
		_mesh_accum = mesh_rebuild_interval


# ---------------------------------------------------------------------------
# Surface waves
# ---------------------------------------------------------------------------

func _update_waves(delta: float) -> void:
	if _grid == null:
		return

	if not waves_enabled:
		if _wave_width > 0:
			_clear_wave_field()
		return

	if _cells.is_empty():
		if _wave_width > 0:
			_clear_wave_field()
		return

	_wave_layout_accum += delta
	if _wave_layout_accum >= 1.0:
		_wave_layout_accum = 0.0
		var info := _dominant_layer_info()
		if info.is_empty():
			if _wave_width > 0:
				_clear_wave_field()
		elif (
			_wave_width == 0
			or int(info["layer"]) != _wave_layer_y
			or int(info["count"]) != _wave_cell_count
			or info["min"] != _wave_bounds_min
			or info["max"] != _wave_bounds_max
		):
			_rebuild_wave_field()

	if _wave_width == 0:
		return

	_ambient_wave_accum += delta
	if _ambient_wave_accum >= ambient_wave_interval:
		_ambient_wave_accum = 0.0
		_spawn_ambient_wave()

	_brush_accum += delta
	if _brush_accum >= brush_interval:
		_brush_accum = 0.0
		_inject_entity_brushes()

	_wave_accum += delta
	_wave_mesh_accum += delta
	var stepped := false
	var steps := 0
	while _wave_accum >= wave_update_interval and steps < 3:
		_wave_accum -= wave_update_interval
		_step_waves()
		steps += 1
		stepped = true

	if stepped and _wave_mesh_accum >= wave_mesh_interval:
		_wave_mesh_accum = 0.0
		_rebuild_wave_crest_mesh()


func _dominant_layer_info() -> Dictionary:
	var counts := {}
	var mins := {}
	var maxs := {}

	for key in _cells.keys():
		var cell: Vector3i = key
		if get_height(cell) <= 0.0001:
			continue
		if _is_covered_above(cell):
			continue

		var y := cell.y
		counts[y] = int(counts.get(y, 0)) + 1
		if not mins.has(y):
			mins[y] = Vector2i(cell.x, cell.z)
			maxs[y] = Vector2i(cell.x, cell.z)
		else:
			var mn: Vector2i = mins[y]
			var mx: Vector2i = maxs[y]
			mn.x = mini(mn.x, cell.x)
			mn.y = mini(mn.y, cell.z)
			mx.x = maxi(mx.x, cell.x)
			mx.y = maxi(mx.y, cell.z)
			mins[y] = mn
			maxs[y] = mx

	if counts.is_empty():
		return {}

	# Prefer whatever water layer the player is standing in, so the pool the
	# player is watching always carries waves even when another pool is larger.
	var preferred := -2147483648
	var player := get_tree().get_first_node_in_group("player")
	if player is Node3D:
		var player_cell: Vector3i = _grid.world_to_cell(
			(player as Node3D).global_position
		)
		var player_water := _water_cell_near(player_cell)
		if (
			player_water != NO_CELL
			and not _is_covered_above(player_water)
		):
			preferred = player_water.y

	var best_y := 0
	var best_count := -1
	if preferred != -2147483648 and counts.has(preferred):
		best_y = preferred
		best_count = int(counts[preferred])
	else:
		for y in counts.keys():
			var count: int = counts[y]
			if count > best_count or (
				count == best_count and int(y) > best_y
			):
				best_count = count
				best_y = int(y)

	return {
		"layer": best_y,
		"count": best_count,
		"min": mins[best_y],
		"max": maxs[best_y],
	}


func _rebuild_wave_field() -> void:
	_bounds_scratch.clear()
	var info := _dominant_layer_info()
	if info.is_empty():
		_clear_wave_field()
		return

	_wave_layer_y = int(info["layer"])
	_wave_bounds_min = info["min"]
	_wave_bounds_max = info["max"]
	_wave_cell_count = int(info["count"])

	var cell_size: Vector3 = _grid.cell_size
	var min_cell := Vector3i(
		_wave_bounds_min.x,
		_wave_layer_y,
		_wave_bounds_min.y
	)
	var max_cell := Vector3i(
		_wave_bounds_max.x,
		_wave_layer_y,
		_wave_bounds_max.y
	)
	var local_min: Vector3 = (
		_grid.map_to_local(min_cell)
		- Vector3(cell_size.x * 0.5, 0.0, cell_size.z * 0.5)
	)
	var local_max: Vector3 = (
		_grid.map_to_local(max_cell)
		+ Vector3(cell_size.x * 0.5, 0.0, cell_size.z * 0.5)
	)
	var world_width := maxf(local_max.x - local_min.x, 0.001)
	var world_depth := maxf(local_max.z - local_min.z, 0.001)

	var texel := 1.0 / float(MAX_HEIGHT)
	var step := wave_step
	while true:
		var nx := maxi(1, int(ceil(world_width / step)))
		var nz := maxi(1, int(ceil(world_depth / step)))
		if nx * nz <= wave_max_samples:
			break
		step *= 1.5

	# Keep the simulation step on whole texture texels so the rendered crest
	# pixels line up with the 1/16 m block texture grid.
	step = maxf(texel, ceil(step / texel) * texel)
	_wave_step_actual = step
	_wave_origin = local_min
	_wave_width = maxi(1, int(ceil(world_width / step)))
	_wave_height = maxi(1, int(ceil(world_depth / step)))

	var total := _wave_width * _wave_height
	_wave_curr.resize(total)
	_wave_curr.fill(0.0)
	_wave_prev.resize(total)
	_wave_prev.fill(0.0)
	_wave_next.resize(total)
	_wave_next.fill(0.0)
	_wave_wet.resize(total)
	_wave_wet.fill(0)
	_wave_top.resize(total)
	_wave_top.fill(0.0)

	# Cache the wet/top result per cell: a 1 m cell contains up to 64 wave
	# texels at the finest step, so this avoids repeating the grid lookup and
	# visual-height math for every texel.
	var top_cache: Dictionary = {}

	for iz in range(_wave_height):
		var local_z := local_min.z + (float(iz) + 0.5) * step
		for ix in range(_wave_width):
			var local_x := local_min.x + (float(ix) + 0.5) * step
			var world: Vector3 = _grid.to_global(
				Vector3(local_x, 0.0, local_z)
			)
			var cell: Vector3i = _grid.world_to_cell(world)
			cell.y = _wave_layer_y

			var top: float
			if top_cache.has(cell):
				top = float(top_cache[cell])
			else:
				top = -INF
				var height := get_height(cell)
				if (
					height > 0.0001
					and not _is_covered_above(cell)
					and not _water_has_ceiling(cell, height)
				):
					top = _water_top(cell, cell_size)
				top_cache[cell] = top

			if top == -INF:
				continue

			var index := iz * _wave_width + ix
			_wave_wet[index] = 1
			_wave_top[index] = top

	if _ripple_instance != null:
		_ripple_instance.mesh = null


func _clear_wave_field() -> void:
	_wave_width = 0
	_wave_height = 0
	_wave_cell_count = 0
	_wave_curr.resize(0)
	_wave_prev.resize(0)
	_wave_next.resize(0)
	_wave_wet.resize(0)
	_wave_top.resize(0)
	if _ripple_instance != null:
		_ripple_instance.mesh = null


func _step_waves() -> void:
	if _wave_width < 3 or _wave_height < 3:
		return

	var width := _wave_width
	var height := _wave_height
	var curr := _wave_curr
	var prev := _wave_prev
	var next := _wave_next
	var wet := _wave_wet

	var courant := wave_speed * wave_update_interval / maxf(_wave_step_actual, 0.0001)
	var c2 := minf(courant * courant, 0.45)
	var damping := vivid_wave_damping if wake_style == 1 else wave_damping

	for iz in range(height):
		var row := iz * width
		for ix in range(width):
			var index := row + ix
			if wet[index] == 0:
				next[index] = 0.0
				continue
			if ix == 0 or ix == width - 1 or iz == 0 or iz == height - 1:
				next[index] = 0.0
				continue

			var laplacian := (
				curr[index - 1]
				+ curr[index + 1]
				+ curr[index - width]
				+ curr[index + width]
				- 4.0 * curr[index]
			)
			next[index] = (
				2.0 * curr[index]
				- prev[index]
				+ c2 * laplacian
			) * damping

	_wave_prev = curr
	_wave_curr = next
	_wave_next = prev


func _inject_brush(world_pos: Vector3, radius: float, strength: float) -> void:
	if _wave_width == 0:
		return

	var local: Vector3 = _grid.to_local(world_pos)
	var fx: float = (local.x - _wave_origin.x) / _wave_step_actual - 0.5
	var fz: float = (local.z - _wave_origin.z) / _wave_step_actual - 0.5
	var sample_radius := radius / _wave_step_actual
	var x0 := maxi(0, int(floor(fx - sample_radius)))
	var x1 := mini(_wave_width - 1, int(ceil(fx + sample_radius)))
	var z0 := maxi(0, int(floor(fz - sample_radius)))
	var z1 := mini(_wave_height - 1, int(ceil(fz + sample_radius)))
	var radius_sq := radius * radius

	for iz in range(z0, z1 + 1):
		var dz: float = (float(iz) - fz) * _wave_step_actual
		var dz_sq: float = dz * dz
		var row := iz * _wave_width
		for ix in range(x0, x1 + 1):
			var index := row + ix
			if _wave_wet[index] == 0:
				continue
			var dx: float = (float(ix) - fx) * _wave_step_actual
			var distance_sq: float = dx * dx + dz_sq
			if distance_sq > radius_sq:
				continue

			var falloff: float = 1.0 - distance_sq / maxf(radius_sq, 0.0001)
			var amount: float = strength * falloff
			_wave_curr[index] = clampf(
				_wave_curr[index] - amount,
				-0.5,
				0.5
			)
			_wave_prev[index] = clampf(
				_wave_prev[index] - amount,
				-0.5,
				0.5
			)


func _inject_entity_brushes() -> void:
	var nodes: Array = []
	nodes.append_array(get_tree().get_nodes_in_group("player"))
	nodes.append_array(get_tree().get_nodes_in_group("npc"))

	for node in nodes:
		if not is_instance_valid(node):
			continue
		if not (node is Node3D):
			continue

		var world: Vector3 = (node as Node3D).global_position
		var cell: Vector3i = _grid.world_to_cell(world)
		var water_cell := _water_cell_near(cell)
		var id: int = node.get_instance_id()

		if water_cell == NO_CELL:
			_brush_last_pos.erase(id)
			# Keep the highest point reached while out of water, not the last
			# sampled point, so a long fall reports its full drop height.
			_air_y[id] = maxf(float(_air_y.get(id, world.y)), world.y)
			continue

		if not _brush_last_pos.has(id):
			_brush_last_pos[id] = world
			var fall_height := maxf(
				0.0,
				float(_air_y.get(id, world.y)) - world.y
			)
			_air_y.erase(id)
			var radius := _brush_radius(node)
			var size_scale := clampf(radius / 0.3, 0.5, 3.0)
			var impact_speed := _vertical_impact_speed(node)
			var energy := clampf(
				1.0 + fall_height * 0.45 + impact_speed * 0.55,
				1.0,
				10.0
			)
			var particle_scale := clampf(
				size_scale * (0.7 + energy * 0.25),
				0.5,
				6.0
			)
			var ripple_scale := clampf(
				size_scale * (0.45 + energy * 0.4),
				0.5,
				8.0
			)
			var count := int(clampf(
				4.0 + energy * 4.0 + size_scale * 2.0,
				4.0,
				32.0
			))
			var strength := clampf(
				0.05 + energy * 0.03,
				0.05,
				0.35
			)
			_spawn_splash(
				world,
				count,
				radius * (0.9 + energy * 0.12),
				strength,
				particle_scale,
				ripple_scale
			)
			continue

		var previous: Vector3 = _brush_last_pos[id]
		var movement := world - previous
		movement.y = 0.0
		var distance := movement.length()
		if distance < 0.02:
			continue

		var speed := distance / maxf(brush_interval, 0.001)
		var sweep_radius := _brush_radius(node)
		var sweep_strength := (
			clampf(0.07 + speed * 0.02, 0.07, 0.24)
			* clampf(sweep_radius / 0.3, 0.7, 2.0)
		)
		_inject_brush(world, sweep_radius, sweep_strength)
		_brush_last_pos[id] = world
		_air_y.erase(id)


func _vertical_impact_speed(node: Node) -> float:
	if node is CharacterBody3D:
		return maxf(0.0, -(node as CharacterBody3D).velocity.y)
	if node is RigidBody3D:
		return maxf(0.0, -(node as RigidBody3D).linear_velocity.y)
	return 0.0


func _brush_radius(node: Node) -> float:
	if node.has_meta("wake_brush_radius"):
		return clampf(float(node.get_meta("wake_brush_radius")), 0.1, 1.0)

	for child in node.find_children("*", "CollisionShape3D", true, false):
		var collider := child as CollisionShape3D
		if collider == null or collider.shape == null:
			continue

		var shape := collider.shape
		var radius := 0.3
		if shape is SphereShape3D:
			radius = shape.radius
		elif shape is CapsuleShape3D:
			radius = shape.radius
		elif shape is CylinderShape3D:
			radius = shape.radius
		elif shape is BoxShape3D:
			radius = maxf(shape.size.x, shape.size.z) * 0.5
		return clampf(radius + 0.08, 0.15, 0.9)

	return 0.3


func _spawn_ambient_wave() -> void:
	var total := _wave_width * _wave_height
	if total <= 0:
		return

	for attempt in range(8):
		var index := randi() % total
		if _wave_wet[index] == 0:
			continue

		var ix := index % _wave_width
		var iz := int(float(index) / float(_wave_width))
		var local := Vector3(
			_wave_origin.x + (float(ix) + 0.5) * _wave_step_actual,
			0.0,
			_wave_origin.z + (float(iz) + 0.5) * _wave_step_actual
		)
		var world: Vector3 = _grid.to_global(local)
		_inject_brush(
			world,
			randf_range(0.15, 0.35),
			ambient_wave_strength
		)
		return


func _rebuild_wave_crest_mesh() -> void:
	if _ripple_instance == null:
		return
	if _wave_width == 0:
		_ripple_instance.mesh = null
		return

	var step := _wave_step_actual
	var threshold := maxf(
		wave_crest_threshold / maxf(wake_thickness, 0.01),
		0.00001
	)
	var dither_scale := maxi(1, wake_dither_scale)
	var band_scale := maxf(wake_band_scale, 1.0)
	var dither_amount := clampf(wake_dither, 0.0, 1.0)
	var texel := 1.0 / float(MAX_HEIGHT)
	var texels_per_sample := maxi(1, int(round(step / texel)))
	var sub_texel := step / float(texels_per_sample)
	var width := _wave_width
	var height := _wave_height
	var wave := _wave_curr
	var wet := _wave_wet
	var palette := VIVID_PALETTE if wake_style == 1 else WAKE_PALETTE
	var bands := palette.size() - 1

	# Sub-texel positions inside one simulation sample, as offsets from the
	# sample centre in sample units plus the bilinear blend weights.
	var x_offsets: Array[int] = []
	var x_weights: Array[float] = []
	var z_offsets: Array[int] = []
	var z_weights: Array[float] = []
	var x_positions: Array[float] = []
	var z_positions: Array[float] = []
	for index in range(texels_per_sample):
		var offset := (
			(float(index) + 0.5) / float(texels_per_sample) - 0.5
		)
		if offset < 0.0:
			x_offsets.append(-1)
			x_weights.append(offset + 1.0)
			z_offsets.append(-1)
			z_weights.append(offset + 1.0)
		else:
			x_offsets.append(0)
			x_weights.append(offset)
			z_offsets.append(0)
			z_weights.append(offset)
		x_positions.append((float(index) + 0.5) * sub_texel)
		z_positions.append((float(index) + 0.5) * sub_texel)

	# Zero-padded amplitude buffer for cheap bilinear lookups.
	var pad_width := width + 2
	var padded := PackedFloat32Array()
	padded.resize(pad_width * (height + 2))
	for iz in range(height):
		var src := iz * width
		var dst := (iz + 1) * pad_width + 1
		for ix in range(width):
			var index := src + ix
			if wet[index] != 0:
				padded[dst + ix] = wave[index]

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var half := texel * 0.51
	var origin_x := _wave_origin.x
	var origin_z := _wave_origin.z

	for iz in range(height):
		var row := iz * width
		for ix in range(width):
			var index := row + ix
			if wet[index] == 0:
				continue

			if wave[index] <= threshold:
				var strong := 0.0
				if ix > 0:
					strong = maxf(strong, wave[index - 1])
				if ix < width - 1:
					strong = maxf(strong, wave[index + 1])
				if iz > 0:
					strong = maxf(strong, wave[index - width])
				if iz < height - 1:
					strong = maxf(strong, wave[index + width])
				if strong <= threshold:
					continue

			var top := _wave_top[index] + 0.004
			var sample_x := origin_x + float(ix) * step
			var sample_z := origin_z + float(iz) * step
			for sy in range(texels_per_sample):
				var pz := iz + 1 + z_offsets[sy]
				var tz := z_weights[sy]
				var row0 := pz * pad_width
				var row1 := row0 + pad_width
				var local_z := sample_z + z_positions[sy]
				var texel_z := int(floor(local_z / texel))
				for sx in range(texels_per_sample):
					var px := ix + 1 + x_offsets[sx]
					var tx := x_weights[sx]
					var value := lerpf(
						lerpf(
							padded[row0 + px],
							padded[row0 + px + 1],
							tx
						),
						lerpf(
							padded[row1 + px],
							padded[row1 + px + 1],
							tx
						),
						tz
					)
					if value <= threshold:
						continue

					var local_x := sample_x + x_positions[sx]
					var texel_x := int(floor(local_x / texel))
					# A per-texel jitter breaks up the low-amplitude edge so
					# the wake reads as a textured field rather than a flat
					# contour or a solid blob.
					var dither_x := int(
						floor(float(texel_x) / float(dither_scale))
					)
					var dither_z := int(
						floor(float(texel_z) / float(dither_scale))
					)
					var jitter := _wave_texel_hash(dither_x, dither_z)
					if value < threshold * (1.0 + jitter * wake_edge_dither):
						continue

					# Continuous strength with stochastic palette quantisation,
					# so broad wakes show a dithered mix of palette bands
					# instead of one flat saturated colour.
					var strength := clampf(
						(value - threshold)
						/ maxf(threshold * band_scale, 0.0001),
						0.0,
						1.0
					)
					var scaled := strength * float(bands - 1)
					var level := 1 + int(floor(scaled))
					var dither_mix := lerpf(1.0, jitter, dither_amount)
					if scaled - floor(scaled) > dither_mix:
						level += 1
					level = clampi(level, 1, bands)
					var color: Color = palette[level]

					var base := vertices.size()
					vertices.append(
						Vector3(local_x - half, top, local_z - half)
					)
					vertices.append(
						Vector3(local_x + half, top, local_z - half)
					)
					vertices.append(
						Vector3(local_x + half, top, local_z + half)
					)
					vertices.append(
						Vector3(local_x - half, top, local_z + half)
					)
					for _vertex in range(4):
						normals.append(Vector3.UP)
						colors.append(color)
					indices.append(base)
					indices.append(base + 1)
					indices.append(base + 2)
					indices.append(base)
					indices.append(base + 2)
					indices.append(base + 3)

	if vertices.is_empty():
		_ripple_instance.mesh = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_ripple_instance.mesh = mesh


func _wave_texel_hash(x: int, z: int) -> float:
	var h := (x * 73856093) ^ (z * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	return float(h & 0xFFFF) / 65535.0



func _add_wave_quad(
	st: SurfaceTool,
	x: float,
	z: float,
	size: float,
	top: float,
	color: Color
) -> void:
	var half := size * 0.5
	_add_colored_quad(
		st,
		Vector3(x - half, top, z - half),
		Vector3(x + half, top, z - half),
		Vector3(x + half, top, z + half),
		Vector3(x - half, top, z + half),
		Vector3.UP,
		color
	)


func _water_top(cell: Vector3i, cell_size: Vector3) -> float:
	var height := get_height(cell)
	if height <= 0.0001:
		return -INF
	var center: Vector3 = _grid.map_to_local(cell)
	var half := cell_size * 0.5
	return (
		center.y - half.y
		+ _visual_height(cell, height) * cell_size.y
		+ 0.004
	)


func _water_cell_near(cell: Vector3i) -> Vector3i:
	if get_height(cell) > 0.0001:
		return cell
	var below := cell + Vector3i.DOWN
	if get_height(below) > 0.0001:
		return below
	return NO_CELL


# ---------------------------------------------------------------------------
# Splashes
# ---------------------------------------------------------------------------

func _update_splash_particles(delta: float) -> void:
	for sprite in _splash_nodes:
		if not sprite.visible:
			continue

		var age := float(sprite.get_meta("age", 0.0)) + delta
		var lifetime := float(sprite.get_meta("lifetime", splash_lifetime))
		if age >= lifetime:
			sprite.visible = false
			continue

		var velocity: Vector3 = sprite.get_meta(
			"velocity",
			Vector3.ZERO
		)
		sprite.position += velocity * delta
		velocity.y -= splash_gravity * delta
		sprite.set_meta("velocity", velocity)
		sprite.set_meta("age", age)

		sprite.frame = (
			int(age / maxf(splash_rotation_interval, 0.001)) % 4
		)
		var fade := 1.0 - age / maxf(lifetime, 0.001)
		var base_scale := float(sprite.get_meta("base_scale", 1.0))
		sprite.modulate = Color(1.0, 1.0, 1.0, fade)
		sprite.scale = Vector3.ONE * base_scale * (0.75 + 0.5 * fade)


func _spawn_splash(
	world_pos: Vector3,
	count: int,
	radius: float,
	wake_strength: float = 0.06,
	particle_scale: float = 1.0,
	ripple_scale: float = 1.0
) -> void:
	_inject_brush(world_pos, radius, wake_strength)
	_add_splash_ripple(world_pos, ripple_scale)

	if not splashes_enabled:
		return
	if _splash_nodes.is_empty() or _splash_atlas == null:
		return

	var cell := _water_cell_near(_grid.world_to_cell(world_pos))
	var local := to_local(world_pos)
	if cell != NO_CELL:
		local.y = _water_top(cell, _grid.cell_size) + 0.02

	for index in range(count):
		var sprite := _free_splash_sprite()
		if sprite == null:
			break

		var spread := 0.08 * particle_scale
		sprite.position = local + Vector3(
			randf_range(-spread, spread),
			randf_range(0.0, 0.1 * particle_scale),
			randf_range(-spread, spread)
		)
		sprite.visible = true
		sprite.frame = randi() % 4
		sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)
		sprite.scale = Vector3.ONE * particle_scale
		sprite.set_meta("base_scale", particle_scale)
		sprite.set_meta("age", 0.0)
		sprite.set_meta(
			"lifetime",
			splash_lifetime * randf_range(0.8, 1.2)
		)
		sprite.set_meta("velocity", Vector3(
			randf_range(-0.4, 0.4) * particle_scale,
			randf_range(0.6, 1.2) * particle_scale,
			randf_range(-0.4, 0.4) * particle_scale
		))


func _free_splash_sprite() -> Sprite3D:
	for sprite in _splash_nodes:
		if not sprite.visible:
			return sprite
	return null


func _add_splash_ripple(
	world_pos: Vector3,
	ripple_scale: float = 1.0
) -> void:
	var cell := _water_cell_near(_grid.world_to_cell(world_pos))
	if cell == NO_CELL:
		return

	var local := to_local(world_pos)
	local.y = _water_top(cell, _grid.cell_size)
	_splash_ripples.append({
		"origin": local,
		"layer_y": cell.y,
		"age": 0.0,
		"strength": 0.85,
		"max_radius": 0.55 * ripple_scale,
	})
	while _splash_ripples.size() > 12:
		_splash_ripples.pop_front()


func _update_splash_ripples(delta: float) -> void:
	if _splash_ripples.is_empty():
		if _splash_ripple_instance != null:
			_splash_ripple_instance.mesh = null
		return

	var alive: Array[Dictionary] = []
	for ripple in _splash_ripples:
		ripple["age"] = float(ripple.get("age", 0.0)) + delta
		if float(ripple["age"]) < splash_lifetime:
			alive.append(ripple)
	_splash_ripples = alive
	_rebuild_splash_ripple_mesh()


func _rebuild_splash_ripple_mesh() -> void:
	if _splash_ripple_instance == null:
		return
	if _splash_ripples.is_empty() or _grid == null:
		_splash_ripple_instance.mesh = null
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	var texel := 1.0 / float(MAX_HEIGHT)
	var cell_size: Vector3 = _grid.cell_size

	for ripple in _splash_ripples:
		var origin: Vector3 = ripple.get("origin", Vector3.ZERO)
		var layer_y: int = int(ripple.get("layer_y", 0))
		var age := float(ripple.get("age", 0.0))
		var strength := float(ripple.get("strength", 0.8))
		var fade := clampf(
			1.0 - age / maxf(splash_lifetime, 0.001),
			0.0,
			1.0
		)
		if fade <= 0.001:
			continue

		var max_radius := float(ripple.get("max_radius", 0.55))
		var radius := minf(
			max_radius,
			0.12 + age * (0.9 * max_radius / 0.55)
		)
		var steps := maxi(1, int(radius / texel))
		var alpha := fade * strength

		for index in range(-steps, steps + 1):
			var offset := float(index) * texel
			quads += _add_splash_texel(
				st,
				origin + Vector3(offset, 0.0, radius),
				layer_y,
				cell_size,
				texel,
				alpha
			)
			quads += _add_splash_texel(
				st,
				origin + Vector3(offset, 0.0, -radius),
				layer_y,
				cell_size,
				texel,
				alpha
			)
			quads += _add_splash_texel(
				st,
				origin + Vector3(radius, 0.0, offset),
				layer_y,
				cell_size,
				texel,
				alpha
			)
			quads += _add_splash_texel(
				st,
				origin + Vector3(-radius, 0.0, offset),
				layer_y,
				cell_size,
				texel,
				alpha
			)

	_splash_ripple_instance.mesh = st.commit() if quads > 0 else null


func _add_splash_texel(
	st: SurfaceTool,
	local_pos: Vector3,
	layer_y: int,
	cell_size: Vector3,
	size: float,
	alpha: float
) -> int:
	var world: Vector3 = _grid.to_global(
		Vector3(local_pos.x, 0.0, local_pos.z)
	)
	var cell: Vector3i = _grid.world_to_cell(world)
	cell.y = layer_y
	if get_height(cell) <= 0.0001:
		return 0
	if _is_covered_above(cell):
		return 0

	var top := _water_top(cell, cell_size)
	if top <= -100000.0:
		return 0

	_add_wave_quad(
		st,
		local_pos.x,
		local_pos.z,
		size,
		top,
		Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0))
	)
	return 1


func _spawn_surface_water_particles() -> void:
	if _cells.is_empty():
		return

	# Ambient droplets only need one valid surface cell. Scanning every water
	# cell here cost ~17 ms on a 2,000-cell pool; sample a few candidates.
	var keys: Array = _cells.keys()
	var attempts: int = mini(8, keys.size())

	for _attempt in attempts:
		var candidate_cell: Vector3i = keys[randi() % keys.size()]
		var height := get_height(candidate_cell)
		if height < 0.9 or height > 1.1:
			continue
		if get_height(candidate_cell + Vector3i.DOWN) < _water_capacity(
			candidate_cell + Vector3i.DOWN
		) - 0.1:
			continue
		if _is_covered_above(candidate_cell):
			continue

		var local: Vector3 = _grid.map_to_local(candidate_cell)
		local.y = _water_top(candidate_cell, _grid.cell_size)
		var world: Vector3 = _grid.to_global(local)
		_spawn_splash(world, 2, 0.12, 0.015)
		return


# ---------------------------------------------------------------------------
# Item registration
# ---------------------------------------------------------------------------

func _ensure_items() -> void:
	if _grid == null or _grid.mesh_library == null:
		return

	var library: MeshLibrary = _grid.mesh_library
	var existing: Dictionary = {}
	var next_id := 0
	for id: int in library.get_item_list():
		existing[String(library.get_item_name(id))] = id
		next_id = maxi(next_id, id + 1)

	_water_material = _make_water_material()
	_preview_material = _make_preview_material()
	_preview = _make_preview()

	# These meshes are only used for the inventory preview. The world uses the
	# exposed-face ArrayMesh with the depth/foam shader.
	var definitions := {
		WATER_SURFACE: Vector3(1.0, surface_level, 1.0),
		WATER_FULL: Vector3(1.0, 1.0, 1.0),
		WATER_SLAB: Vector3(1.0, 0.5, 1.0),
		WATER_PANEL: Vector3(1.0, 1.0 / MAX_HEIGHT, 1.0),
	}

	for item_name: String in definitions:
		var item_id: int = int(existing.get(item_name, -1))
		if item_id == -1:
			item_id = next_id
			next_id += 1
			library.create_item(item_id)
			library.set_item_name(item_id, item_name)

		var box := BoxMesh.new()
		box.size = definitions[item_name]
		box.material = _preview_material
		library.set_item_mesh(item_id, box)
		library.set_item_mesh_transform(item_id, Transform3D.IDENTITY)
		library.set_item_preview(item_id, _preview)
		_item_ids[item_name] = item_id


func _make_water_material() -> ShaderMaterial:
	# Simple lit depth-fade + foam shader. The white shoreline edge and ripple
	# pixels are separate meshes.
	var shader := load("res://scripts/world/water.gdshader") as Shader
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _make_foam_material() -> ShaderMaterial:
	var shader := load("res://scripts/world/water_edge.gdshader") as Shader
	var material := ShaderMaterial.new()
	material.shader = shader

	# Load the source PNG directly too, so the foam works even before the
	# texture has been imported by the editor.
	var texture: Texture2D = null
	var texture_path := "res://textures/particles/sea_foam.png"
	if ResourceLoader.exists(texture_path, "Texture2D"):
		texture = load(texture_path) as Texture2D
	if texture == null:
		var image := Image.new()
		if image.load(texture_path) == OK:
			texture = ImageTexture.create_from_image(image)

	material.set_shader_parameter("foam_texture", texture)
	material.set_shader_parameter(
		"texture_width",
		float(texture.get_width()) if texture != null else FOAM_TEXTURE_WIDTH
	)
	# Draw after the water so the unshaded foam is never tinted by the water's
	# transparent pass when their depth ordering ties.
	material.render_priority = 1
	return material


func _make_foam_corner_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 1

	var path := "res://textures/particles/sea_foam_corner.png"
	var texture: Texture2D = null
	if ResourceLoader.exists(path, "Texture2D"):
		texture = load(path) as Texture2D
	if texture == null:
		var image := Image.new()
		if image.load(path) == OK:
			texture = ImageTexture.create_from_image(image)
	material.albedo_texture = texture
	return material


func _make_preview_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.albedo_color = Color(0.05, 0.32, 0.72, 0.55)
	material.roughness = 0.12
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _make_preview() -> Texture2D:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.05, 0.32, 0.72, 0.75))
	return ImageTexture.create_from_image(image)


func get_item_id(item_name: String) -> int:
	return int(_item_ids.get(item_name, -1))


func get_height(cell: Vector3i) -> float:
	return float(_cells.get(cell, 0.0))


## Forces the 2D wave field to rebuild on the next wave update. Used when the
## wave step, sample cap or wake palette changes in the settings.
func refresh_wave_settings() -> void:
	_wave_width = 0
	_wave_height = 0
	_wave_accum = 0.0
	_wave_layout_accum = 0.0
	if _ripple_instance != null:
		_ripple_instance.mesh = null


func get_pick_item(cell: Vector3i) -> int:
	var height := get_height(cell)
	if height <= 0.0001:
		return -1

	var capacity := _water_capacity(cell)
	if height >= capacity - 0.5:
		# Surface and full are the same volume; only the exposed top is called
		# surface water.
		if _is_covered_above(cell):
			return get_item_id(WATER_FULL)
		return get_item_id(WATER_SURFACE)

	if height >= capacity * 0.5:
		return get_item_id(WATER_SLAB)
	return get_item_id(WATER_PANEL)


func _is_covered_above(cell: Vector3i) -> bool:
	if get_height(cell + Vector3i.UP) > 0:
		return true
	return _grid.get_block_item(cell + Vector3i.UP) != -1


# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

func place(
	cells: Array[Vector3i],
	kind: String,
	_face_direction: int = -1
) -> void:
	if _grid == null:
		return

	var amount := float(MAX_HEIGHT)
	if kind == WATER_SLAB:
		amount = float(MAX_HEIGHT) * 0.5
	elif kind == WATER_PANEL:
		amount = 1.0

	for cell: Vector3i in cells:
		if _is_blocking(cell):
			continue
		_add_stacked(cell, amount)

	_dirty = true


## Adds water to a cell, then keeps stacking the remainder upward. This lets a
## repeated placement fill a tank instead of silently discarding the overflow.
func _add_stacked(cell: Vector3i, amount: float) -> void:
	var remaining := amount
	var current := cell

	while remaining > 0.0001:
		if current.y < _grid.min_block_y or current.y > _grid.max_block_y:
			return
		if not _is_waterloggable(current):
			return

		var height := get_height(current)
		var space := _water_capacity(current) - height
		if space > 0.0001:
			var added := minf(space, remaining)
			_set_height(current, height + added)
			remaining -= added

		current += Vector3i.UP


func _set_height(cell: Vector3i, height: float) -> void:
	var capacity := _water_capacity(cell)
	var clamped := clampf(height, 0.0, capacity)
	var current := get_height(cell)
	var decreased := clamped < current - 0.0001

	if clamped <= 0.0001:
		if current > 0.0001:
			_cells.erase(cell)
			_mark_cell_dirty(cell)
			_dirty = true
			_global_dirty = true
		if decreased:
			_activate_above_layer(cell)
		return

	if absf(current - clamped) <= 0.0001:
		return

	_cells[cell] = clamped
	_active[cell] = true
	_mark_cell_dirty(cell)
	_dirty = true
	_global_dirty = true
	if decreased:
		_activate_above_layer(cell)


func _activate(cell: Vector3i) -> void:
	if _cells.has(cell):
		_active[cell] = true


## A lower cell losing water can strand a whole 1-high layer above it, not just
## the cell directly overhead. Wake that layer so it can flow into the drop.
func _activate_above_layer(cell: Vector3i) -> void:
	var above := cell + Vector3i.UP
	_activate(above)
	for direction: int in WALL_FACES:
		_activate(cell + FACE_NORMALS[direction])
		_activate(above + FACE_NORMALS[direction])


# ---------------------------------------------------------------------------
# Flow
# ---------------------------------------------------------------------------

func _tick() -> void:
	if _active.is_empty():
		return

	_bounds_scratch.clear()
	var keys: Array = _active.keys()
	_active.clear()

	var updates := 0
	for key in keys:
		var cell: Vector3i = key
		if updates >= max_updates_per_tick:
			_activate(cell)
			continue
		updates += 1
		_tick_cell(cell)


func _tick_cell(cell: Vector3i) -> void:
	var height := get_height(cell)
	if height <= 0.0001:
		_cells.erase(cell)
		_mark_cell_dirty(cell)
		_global_dirty = true
		return

	if _is_below_world_floor(cell):
		_cells.erase(cell)
		_mark_cell_dirty(cell)
		_activate_above_layer(cell)
		_dirty = true
		_global_dirty = true
		return

	var below := cell + Vector3i.DOWN
	if below.y < _grid.min_block_y:
		_cells.erase(cell)
		_mark_cell_dirty(cell)
		_activate_above_layer(cell)
		_dirty = true
		_global_dirty = true
		return

	# Gravity first: fill the cell below before spreading sideways.
	if _is_waterloggable(below) and _water_open_from_above(below):
		var below_height := get_height(below)
		var space := _water_capacity(below) - below_height
		if space > 0.0001:
			var amount := minf(height, space)
			_set_height(below, below_height + amount)
			height -= amount
			_set_height(cell, height)

			_activate(below)
			_activate(cell)
			# Pull the water above into the vacated cell in the same tick so a
			# falling column stays together instead of showing a one-tick gap
			# between falling water boxes.
			var above := cell + Vector3i.UP
			if _cells.has(above):
				_pull_down_column(above)
			_dirty = true

			if height <= 0.0001:
				return
			# Still falling; give it another tick rather than spreading while
			# the column is in motion.
			if get_height(below) < _water_capacity(below) - 0.0001:
				return

	_equalize(cell, get_height(cell))


func _pull_down_column(cell: Vector3i) -> void:
	var height := get_height(cell)
	if height <= 0.0001:
		return

	var below := cell + Vector3i.DOWN
	if not _is_waterloggable(below) or not _water_open_from_above(below):
		return

	var below_height := get_height(below)
	var space := _water_capacity(below) - below_height
	if space <= 0.0001:
		return

	var amount := minf(height, space)
	_set_height(below, below_height + amount)
	_set_height(cell, height - amount)
	_activate(below)
	_activate(cell)

	var above := cell + Vector3i.UP
	if _cells.has(above):
		_pull_down_column(above)


## Spreads water as a one-unit film first, then equalizes wet cells smoothly.
## Heights are floats internally (0..capacity), so long gradients drain instead
## of freezing at adjacent differences of one integer step. Cells with a
## partial block have a raised floor and a smaller capacity, so comparisons use
## the water surface (floor + depth) rather than raw depth.
func _equalize(cell: Vector3i, height: float) -> void:
	if height <= 0.0001:
		return
	var surface := _water_base(cell) + height

	# A one-unit film can move into an empty neighbour when that neighbour is
	# over a drop (air, a hole, or a non-full water cell). This lets a stranded
	# 1-high layer drain after the full block beneath it disappears instead of
	# sitting next to an empty column forever.
	if height <= 1.0 + 0.0001:
		for direction: int in WALL_FACES:
			var neighbour := cell + FACE_NORMALS[direction]
			if not _is_waterloggable(neighbour):
				continue
			if get_height(neighbour) > 0.0001:
				continue
			var below_neighbour := neighbour + Vector3i.DOWN
			if not _is_waterloggable(below_neighbour):
				continue
			if (
				get_height(below_neighbour)
				>= _water_capacity(below_neighbour) - 0.0001
			):
				continue
			# Never lift water above the donor's own surface: a low puddle on a
			# floor must not wet the top of a neighbouring slab.
			var reach := surface - _water_base(neighbour)
			if reach <= 0.0001:
				continue
			var amount := minf(height, reach)

			_set_height(cell, height - amount)
			_set_height(neighbour, amount)
			_activate(cell)
			_activate(neighbour)
			_dirty = true
			return

	# Spread a new one-unit film into an empty neighbour using the water above
	# the minimum layer. Requiring a meaningful excess avoids endless 0.02-unit
	# slivers; the global pass consolidates any temporary overshoot.
	var excess := height - 1.0
	if excess >= 0.1:
		for direction: int in WALL_FACES:
			var neighbour := cell + FACE_NORMALS[direction]
			if not _is_waterloggable(neighbour):
				continue
			if get_height(neighbour) > 0.0001:
				continue

			# The neighbour's free space must be reachable at this water
			# surface; otherwise this is an uphill transfer onto a slab top.
			var reach := surface - _water_base(neighbour)
			if reach <= 0.0001:
				continue
			var amount := minf(minf(excess, 1.0), reach)
			_set_height(cell, height - amount)
			_set_height(neighbour, amount)
			_activate(cell)
			_activate(neighbour)
			_dirty = true
			return

	# A wet cell can also pass water from a higher neighbour into an empty one,
	# extending the film without thickening the middle cell.
	if height > 0.0001:
		var high_cell := cell
		var has_high := false
		var empty_cell := cell
		var has_empty := false
		var high_height := height

		for direction: int in WALL_FACES:
			var neighbour := cell + FACE_NORMALS[direction]
			if not _is_waterloggable(neighbour):
				continue
			var neighbour_height := get_height(neighbour)
			if (
				_water_base(neighbour) + neighbour_height > surface
				and not has_high
			):
				high_cell = neighbour
				high_height = neighbour_height
				has_high = true
			elif neighbour_height <= 0.0001 and not has_empty:
				empty_cell = neighbour
				has_empty = true

		if has_high and has_empty:
			var high_surface := _water_base(high_cell) + high_height
			var reach := high_surface - _water_base(empty_cell)
			var amount := minf(high_height - 1.0, _water_capacity(empty_cell))
			amount = minf(amount, reach)
			amount = minf(amount, 1.0)
			if amount >= 0.1:
				_set_height(high_cell, high_height - amount)
				_set_height(empty_cell, amount)
				_activate(high_cell)
				_activate(empty_cell)
				_activate(cell)
				_dirty = true
				return

	# Smooth wet neighbours with float half-difference transfers. Because the
	# transfer can be fractional, long gradients keep draining instead of
	# freezing at a one-unit step.
	for direction: int in WALL_FACES:
		var neighbour := cell + FACE_NORMALS[direction]
		if not _is_waterloggable(neighbour):
			continue

		var neighbour_height := get_height(neighbour)
		if neighbour_height <= 0.0001:
			continue
		var neighbour_surface := _water_base(neighbour) + neighbour_height
		if surface <= neighbour_surface + 0.0001:
			continue

		var amount := minf((surface - neighbour_surface) * 0.5, height)
		amount = minf(
			amount,
			_water_capacity(neighbour) - neighbour_height
		)
		if amount <= 0.0001:
			continue

		_set_height(cell, height - amount)
		_set_height(neighbour, neighbour_height + amount)
		height -= amount
		surface -= amount

		_activate(cell)
		_activate(neighbour)
		_dirty = true


## Hydrostatic pass over every connected water body, spread across frames. The
## body BFS and levelling stop at a small time budget and resume next frame, so
## a large pool cannot produce a 17–30 ms hitch.
func _equalize_all_bodies() -> void:
	if _cells.is_empty():
		_global_dirty = false
		_eq_reset()
		return

	if not _eq_active:
		_bounds_scratch.clear()
		_eq_keys = _cells.keys()
		_eq_key_index = 0
		_eq_visited.clear()
		_eq_queue.clear()
		_eq_body.clear()
		_eq_expanded = false
		_eq_active = true
		# Detect changes made while this pass runs.
		_global_dirty = false

	var start_usec: int = Time.get_ticks_usec()
	var budget_usec: int = 2000
	var processed: int = 0

	while _eq_key_index < _eq_keys.size():
		if _eq_queue.is_empty() and _eq_body.is_empty():
			var start := NO_CELL

			while _eq_key_index < _eq_keys.size():
				var key: Vector3i = _eq_keys[_eq_key_index]
				_eq_key_index += 1

				if _eq_visited.has(key):
					continue
				if get_height(key) <= 0.0001:
					continue

				start = key
				break

			if start == NO_CELL:
				break

			_eq_start_y = start.y
			_eq_visited[start] = true
			_eq_queue.append(start)

		while not _eq_queue.is_empty():
			var cell: Vector3i = _eq_queue.pop_back()
			_eq_body.append(cell)
			processed += 1

			# Only level water within the same Y layer. Vertical movement is
			# gravity's job; connecting through higher layers looked like
			# equalizing through walls.
			for direction: int in WALL_FACES:
				var neighbour := cell + FACE_NORMALS[direction]

				if neighbour.y != _eq_start_y:
					continue
				if _eq_visited.has(neighbour):
					continue
				if not _cells.has(neighbour):
					continue
				if get_height(neighbour) <= 0.0001:
					continue

				_eq_visited[neighbour] = true
				_eq_queue.append(neighbour)

			if (
				(processed & 63) == 0
				and Time.get_ticks_usec() - start_usec >= budget_usec
			):
				_global_dirty = true
				return

		if _eq_body.size() >= 2:
			if _level_body(_eq_body):
				_eq_expanded = true

		_eq_body.clear()

		if Time.get_ticks_usec() - start_usec >= budget_usec:
			_global_dirty = true
			return

	_eq_active = false
	_eq_keys.clear()
	_eq_visited.clear()
	_global_dirty = _eq_expanded or _global_dirty


func _eq_reset() -> void:
	_eq_active = false
	_eq_keys.clear()
	_eq_key_index = 0
	_eq_visited.clear()
	_eq_queue.clear()
	_eq_body.clear()
	_eq_expanded = false


func _level_body(body: Array[Vector3i]) -> bool:
	var total := 0.0
	var layers: Dictionary = {}

	for cell: Vector3i in body:
		total += get_height(cell)
		var y := cell.y
		if not layers.has(y):
			layers[y] = []
		layers[y].append(cell)

	var levels: Array = layers.keys()
	levels.sort()

	# If there is at least one full unit per wet cell to spare, grow the top
	# layer into adjacent empty cells before equalizing. This reaches the
	# minimum-height film in a few passes instead of waiting for slow local
	# spreading.
	var top_y: int = levels.back()
	var slots := int(floor(total)) - body.size()
	var added := 0
	if slots > 0:
		var candidates: Array[Vector3i] = []
		var seen: Dictionary = {}
		for cell: Vector3i in body:
			for direction: int in WALL_FACES:
				var neighbour := cell + FACE_NORMALS[direction]
				if neighbour.y != top_y or seen.has(neighbour):
					continue
				if _cells.has(neighbour):
					if get_height(neighbour) > 0.0001:
						continue
				if not _is_waterloggable(neighbour):
					continue
				seen[neighbour] = true
				candidates.append(neighbour)

		added = mini(slots, candidates.size())
		var top_layer: Array = layers[top_y]
		for index in range(added):
			top_layer.append(candidates[index])
		layers[top_y] = top_layer

	var remaining := total
	var drained := false
	for y in levels:
		var layer: Array = layers[y]
		if drained:
			for cell: Vector3i in layer:
				_set_height(cell, 0.0)
			continue

		var layer_capacity := 0.0
		for cell: Vector3i in layer:
			layer_capacity += _water_capacity(cell)
		if remaining >= layer_capacity - 0.0001:
			for cell: Vector3i in layer:
				_set_height(cell, _water_capacity(cell))
			remaining -= layer_capacity
		else:
			_fill_layer_surface(layer, remaining)
			remaining = 0.0
			drained = true

	return added > 0


## Distributes a layer's volume so every cell settles at the same water
## surface (floor + depth), clamped by each cell's capacity. This is what lets
## a slab cell hold less water than a full cell while sharing the same surface.
func _fill_layer_surface(layer: Array, volume: float) -> void:
	if layer.is_empty() or volume <= 0.0001:
		for cell: Vector3i in layer:
			_set_height(cell, 0.0)
		return

	var bases := PackedFloat32Array()
	var caps := PackedFloat32Array()
	bases.resize(layer.size())
	caps.resize(layer.size())
	var uniform := true
	var uniform_cap := -1.0
	var low := INF
	var high := -INF

	for index in range(layer.size()):
		var cell: Vector3i = layer[index]
		var base := _water_base(cell)
		var capacity := _water_capacity(cell)
		bases[index] = base
		caps[index] = capacity
		if base > 0.0001:
			uniform = false
		if uniform_cap < 0.0:
			uniform_cap = capacity
		elif not is_equal_approx(uniform_cap, capacity):
			uniform = false
		low = minf(low, base)
		high = maxf(high, base + capacity)

	if uniform:
		if volume < float(layer.size()) - 0.0001:
			# Preserve the tuned minimum-film rule on plain floors: keep the
			# deepest cells at one unit or more rather than wetting every cell
			# with an almost invisible sliver.
			layer.sort_custom(
				func(a: Vector3i, b: Vector3i) -> bool:
					return get_height(a) > get_height(b)
			)
			var keep := maxi(1, mini(layer.size(), int(floor(volume))))
			var per_kept := volume / float(keep)
			for index in range(layer.size()):
				_set_height(
					layer[index],
					per_kept if index < keep else 0.0
				)
		else:
			var per := volume / float(layer.size())
			for cell: Vector3i in layer:
				_set_height(cell, per)
		return

	if high <= low:
		return

	for _iteration in range(28):
		var mid := (low + high) * 0.5
		var filled := 0.0
		for index in range(layer.size()):
			filled += clampf(mid - bases[index], 0.0, caps[index])
		if filled > volume:
			high = mid
		else:
			low = mid

	var surface := (low + high) * 0.5
	for index in range(layer.size()):
		_set_height(
			layer[index],
			clampf(surface - bases[index], 0.0, caps[index])
		)


# ---------------------------------------------------------------------------
# Grid helpers
# ---------------------------------------------------------------------------

## Mirrors Member._is_below_chunk_floor(): compare the water cell's world Y
## with its chunk's lowest block minus the same five-block margin.
func _is_below_world_floor(cell: Vector3i) -> bool:
	var chunk: Vector2i = _grid.cell_to_chunk(cell)
	var lowest_y: int = _grid.get_chunk_lowest_block_y(chunk)
	if lowest_y == _grid.NO_CHUNK_FLOOR:
		lowest_y = 0

	var floor_world_y: float = _grid.to_global(
		_grid.map_to_local(Vector3i(0, lowest_y, 0))
	).y
	var cell_world_y: float = _grid.to_global(
		_grid.map_to_local(cell)
	).y
	return cell_world_y < floor_world_y - FALL_KILL_MARGIN_BLOCKS * _grid.cell_size.y


func _is_blocking(cell: Vector3i) -> bool:
	var item: int = _grid.get_block_item(cell)
	if item == -1:
		return false
	return not _is_waterloggable_item(item)


func _is_waterloggable(cell: Vector3i) -> bool:
	var item: int = _grid.get_block_item(cell)
	return item == -1 or _is_waterloggable_item(item)


func _is_waterloggable_item(item: int) -> bool:
	if _waterloggable_cache.has(item):
		return bool(_waterloggable_cache[item])

	var item_name := String(
		_grid.mesh_library.get_item_name(item)
	).to_lower()
	var result := false

	for prefix in [
		"auto_slab_",
		"auto_panel_",
		"auto_stairs_",
		"water_",
	]:
		if item_name.begins_with(prefix):
			result = true
			break

	_waterloggable_cache[item] = result
	return result


## Returns (base, capacity) for the free space in a cell, in 1/16-block water
## units. Slabs/panels/stairs are partial solids: water can be logged in the
## remaining space instead of occupying the whole cell. Side-mounted variants
## use the slab rule (half free) because the height-field model cannot express
## a vertical half-cell.
func _water_bounds(cell: Vector3i) -> Vector2:
	if _bounds_scratch.has(cell):
		return _bounds_scratch[cell]
	var bounds := _water_bounds_for_item(_grid.get_block_item(cell))
	_bounds_scratch[cell] = bounds
	return bounds


func _water_bounds_for_item(item: int) -> Vector2:
	if _water_bounds_cache.has(item):
		return _water_bounds_cache[item]
	if item == -1:
		return Vector2(0.0, float(MAX_HEIGHT))
	if not _is_waterloggable_item(item):
		_water_bounds_cache[item] = Vector2.ZERO
		return Vector2.ZERO

	var item_name := String(_grid.mesh_library.get_item_name(item)).to_lower()
	var bounds := Vector2(0.0, float(MAX_HEIGHT))
	if item_name.begins_with("auto_slab_"):
		if item_name.contains("_top_"):
			# Top slab: the free half is underneath it.
			bounds = Vector2(0.0, float(MAX_HEIGHT) - SLAB_UNITS)
		else:
			# Bottom and side slabs: the free half is above the solid.
			bounds = Vector2(SLAB_UNITS, float(MAX_HEIGHT) - SLAB_UNITS)
	elif item_name.begins_with("auto_stairs_"):
		if item_name.contains("upsidedown"):
			bounds = Vector2(0.0, float(MAX_HEIGHT) - SLAB_UNITS)
		else:
			bounds = Vector2(SLAB_UNITS, float(MAX_HEIGHT) - SLAB_UNITS)
	elif item_name.begins_with("auto_panel_"):
		if item_name.contains("_top_"):
			bounds = Vector2(0.0, float(MAX_HEIGHT) - PANEL_UNITS)
		elif item_name.contains("_bottom_"):
			bounds = Vector2(PANEL_UNITS, float(MAX_HEIGHT) - PANEL_UNITS)
		else:
			bounds = Vector2(SLAB_UNITS, float(MAX_HEIGHT) - SLAB_UNITS)

	_water_bounds_cache[item] = bounds
	return bounds


func _water_capacity(cell: Vector3i) -> float:
	return _water_bounds(cell).y


## Water can fall into the cell from above unless a top-mounted partial block
## closes its top. Bottom/side partials leave the top open, so falling water
## lands in their free space instead of passing through the solid.
func _water_open_from_above(cell: Vector3i) -> bool:
	var bounds := _water_bounds(cell)
	if bounds.y <= 0.0:
		return false
	if bounds.x <= 0.0001 and bounds.y < float(MAX_HEIGHT) - 0.0001:
		return false
	return true


func _water_base(cell: Vector3i) -> float:
	return _water_bounds(cell).x


## Water surface relative to the cell floor, in 1/16-block units. Two cells
## with different floors are level when these values match.
func _water_surface(cell: Vector3i) -> float:
	return _water_base(cell) + get_height(cell)


## True when a top-mounted partial block caps the cell and the water has filled
## the space underneath it. The exposed top face would otherwise z-fight with
## the block's underside.
func _water_has_ceiling(cell: Vector3i, height: float) -> bool:
	var bounds := _water_bounds(cell)
	if bounds.x > 0.0001:
		return false
	if bounds.y >= float(MAX_HEIGHT) - 0.0001:
		return false
	return height >= bounds.y - 0.0001


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _create_renderer() -> void:
	# Per-chunk MeshInstance3D nodes are created lazily by
	# _ensure_water_chunk(); only the shared materials live here.
	# Textured sea-foam border. A separate unshaded mesh keeps the foam crisp
	# and lets it scroll independently of the water shader.
	_foam_material = _make_foam_material()

	# Solid 5x5 corner fills bridge the two foam banks where walls meet.
	_foam_corner_material = _make_foam_corner_material()

	# Fading white voxel pixels for ambient ripples and movement wakes.
	_ripple_material = StandardMaterial3D.new()
	_ripple_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ripple_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ripple_material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	_ripple_material.vertex_color_use_as_albedo = true
	_ripple_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ripple_material.render_priority = 2

	_ripple_instance = MeshInstance3D.new()
	_ripple_instance.name = "WaterRipples"
	_ripple_instance.material_override = _ripple_material
	_ripple_instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(_ripple_instance)

	_splash_ripple_instance = MeshInstance3D.new()
	_splash_ripple_instance.name = "SplashRipples"
	_splash_ripple_instance.material_override = _ripple_material
	_splash_ripple_instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(_splash_ripple_instance)

	_create_splash_pool()


func _create_splash_pool() -> void:
	_splash_texture = load(
		"res://textures/particles/splash_small.png"
	) as Texture2D
	if _splash_texture == null:
		return

	var image := _splash_texture.get_image()
	image.convert(Image.FORMAT_RGBA8)
	var width := image.get_width()
	var height := image.get_height()
	var atlas := Image.create(
		width * 2,
		height * 2,
		false,
		Image.FORMAT_RGBA8
	)
	for frame in range(4):
		var rotated := image.duplicate()
		for turn in range(frame):
			rotated.rotate_90(true)
		var dst := Vector2i(
			(frame % 2) * width,
			int(frame >> 1) * height
		)
		atlas.blit_rect(
			rotated,
			Rect2i(0, 0, rotated.get_width(), rotated.get_height()),
			dst
		)
	_splash_atlas = ImageTexture.create_from_image(atlas)

	for index in range(splash_particle_count):
		var sprite := Sprite3D.new()
		sprite.name = "Splash%d" % index
		sprite.texture = _splash_atlas
		sprite.hframes = 2
		sprite.vframes = 2
		sprite.frame = 0
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		sprite.shaded = false
		sprite.transparent = true
		sprite.pixel_size = splash_size / float(maxi(width, 1))
		sprite.visible = false
		add_child(sprite)
		_splash_nodes.append(sprite)


## Builds only the exterior faces of the water body. Faces between two water
## cells, or against solid blocks, are omitted so the inside of a water volume
## no longer shows a grid of internal box faces.
func _rebuild_mesh() -> void:
	if _grid == null:
		return
	_bounds_scratch.clear()

	if _cells.is_empty():
		for chunk: Vector2i in _water_chunks:
			var entry: Dictionary = _water_chunks[chunk]
			entry["water"].mesh = null
			if entry.get("foam") != null:
				entry["foam"].mesh = null
			if entry.get("corner") != null:
				entry["corner"].mesh = null
		_mesh_dirty_chunks.clear()
		return

	if _mesh_dirty_chunks.is_empty():
		return

	# Bucket the wet cells by chunk once, then rebuild only the dirty chunks.
	var buckets: Dictionary = {}
	for key in _cells:
		var cell: Vector3i = key
		var chunk: Vector2i = _grid.cell_to_chunk(cell)
		if not _mesh_dirty_chunks.has(chunk):
			continue
		var bucket: Array = buckets.get(chunk, [])
		bucket.append(cell)
		buckets[chunk] = bucket

	var cell_size: Vector3 = _grid.cell_size

	for chunk: Vector2i in _mesh_dirty_chunks.keys():
		var cells: Array = buckets.get(chunk, [])
		if cells.is_empty():
			# Do not allocate an empty chunk node for the neighbour-marking
			# ring; just clear a chunk that used to contain water.
			var existing: Dictionary = _water_chunks.get(chunk, {})
			if not existing.is_empty():
				existing["water"].mesh = null
				if existing.get("foam") != null:
					existing["foam"].mesh = null
				if existing.get("corner") != null:
					existing["corner"].mesh = null
			continue

		var entry := _ensure_water_chunk(chunk)

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var foam_st := SurfaceTool.new()
		foam_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var corner_st := SurfaceTool.new()
		corner_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var foam_quads := 0
		var corner_quads := 0

		for key: Vector3i in cells:
			var height := float(_cells.get(key, 0.0))
			if height <= 0.0001:
				continue
			var center: Vector3 = _grid.map_to_local(key)
			_add_horizontal_faces(st, key, height, center, cell_size)
			foam_quads += _add_horizontal_foam(
				foam_st,
				key,
				height,
				center,
				cell_size
			)
			corner_quads += _add_horizontal_corners(
				corner_st,
				key,
				height,
				center,
				cell_size
			)

		entry["water"].mesh = st.commit()
		_set_chunk_foam_mesh(entry, chunk, "foam", foam_st, foam_quads)
		_set_chunk_foam_mesh(entry, chunk, "corner", corner_st, corner_quads)

	_mesh_dirty_chunks.clear()


func _set_chunk_foam_mesh(
	entry: Dictionary,
	chunk: Vector2i,
	key: String,
	st: SurfaceTool,
	quad_count: int
) -> void:
	var instance: MeshInstance3D = entry.get(key)
	if quad_count > 0:
		if instance == null:
			instance = MeshInstance3D.new()
			instance.name = (
				"WaterFoam_%d_%d" if key == "foam" else "WaterCorners_%d_%d"
			) % [chunk.x, chunk.y]
			var chosen_material: Material = _foam_material

			if key != "foam":
				chosen_material = _foam_corner_material

			instance.material_override = chosen_material
			instance.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			add_child(instance)
			entry[key] = instance
		instance.mesh = st.commit()
	elif instance != null:
		instance.mesh = null


func _ensure_water_chunk(chunk: Vector2i) -> Dictionary:
	var entry: Dictionary = _water_chunks.get(chunk, {})
	if not entry.is_empty():
		return entry

	var water := MeshInstance3D.new()
	water.name = "WaterMesh_%d_%d" % [chunk.x, chunk.y]
	water.material_override = _water_material
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)

	entry = {"water": water}
	_water_chunks[chunk] = entry
	return entry


## Marks the chunks whose water faces can be affected by a cell change. Only
## the cell's chunk is rebuilt unless the cell sits on a chunk border, in which
## case the touching neighbour chunk is included for the shared side faces.
func _mark_cell_dirty(cell: Vector3i) -> void:
	if _grid == null:
		return
	var chunk: Vector2i = _grid.cell_to_chunk(cell)
	_mesh_dirty_chunks[chunk] = true

	var local_x := posmod(cell.x, _grid.CHUNK_SIZE)
	var local_z := posmod(cell.z, _grid.CHUNK_SIZE)
	for dx in [-1, 0, 1]:
		if dx < 0 and local_x != 0:
			continue
		if dx > 0 and local_x != _grid.CHUNK_SIZE - 1:
			continue
		for dz in [-1, 0, 1]:
			if dx == 0 and dz == 0:
				continue
			if dz < 0 and local_z != 0:
				continue
			if dz > 0 and local_z != _grid.CHUNK_SIZE - 1:
				continue
			_mesh_dirty_chunks[chunk + Vector2i(dx, dz)] = true


func _visual_height(cell: Vector3i, height: float) -> float:
	if height <= 0.0001:
		return 0.0
	var base := _water_base(cell)
	var surface := (base + height) / float(MAX_HEIGHT)
	# A wet cell never renders thinner than one of the 16 levels, so spreading
	# films stay visible at the minimum height.
	surface = maxf(surface, (base + 1.0) / float(MAX_HEIGHT))
	# Surface and full are the same volume. Only the exposed top of a cell that
	# reaches the top of the block gets the slightly lower cosmetic surface.
	if (
		height >= _water_capacity(cell) - 0.0001
		and base + height >= float(MAX_HEIGHT) - 0.0001
		and not _is_covered_above(cell)
	):
		surface = surface_level
	return surface


func _add_horizontal_faces(
	st: SurfaceTool,
	cell: Vector3i,
	height: float,
	center: Vector3,
	cell_size: Vector3
) -> void:
	var half := cell_size * 0.5
	var cell_bottom := center.y - half.y
	var bottom := (
		cell_bottom
		+ _water_base(cell) / float(MAX_HEIGHT) * cell_size.y
	)
	var top := cell_bottom + _visual_height(cell, height) * cell_size.y
	var min_x := center.x - half.x
	var max_x := center.x + half.x
	var min_z := center.z - half.z
	var max_z := center.z + half.z

	# Top face: visible only when nothing is above the cell.
	if not _is_covered_above(cell) and not _water_has_ceiling(cell, height):
		_add_quad(
			st,
			Vector3(min_x, top, min_z),
			Vector3(max_x, top, min_z),
			Vector3(max_x, top, max_z),
			Vector3(min_x, top, max_z),
			Vector3.UP
		)

	# Bottom face: hidden when resting on a partial block, a block or another
	# water cell.
	var below := cell + Vector3i.DOWN
	var bottom_hidden: bool = (
		_water_base(cell) > 0.0001
		or get_height(below) > 0
		or _grid.get_block_item(below) != -1
	)
	if not bottom_hidden:
		_add_quad(
			st,
			Vector3(min_x, bottom, min_z),
			Vector3(min_x, bottom, max_z),
			Vector3(max_x, bottom, max_z),
			Vector3(max_x, bottom, min_z),
			Vector3.DOWN
		)

	for direction: int in WALL_FACES:
		var neighbour := cell + FACE_NORMALS[direction]
		# Solid blocks hide their side of the water.
		if _grid.get_block_item(neighbour) != -1:
			continue

		var neighbour_height := get_height(neighbour)
		var exposed_bottom := bottom
		if neighbour_height > 0.0001:
			var neighbour_center: Vector3 = _grid.map_to_local(neighbour)
			var neighbour_top: float = (
				neighbour_center.y - half.y
				+ _visual_height(neighbour, neighbour_height) * cell_size.y
			)
			exposed_bottom = maxf(bottom, neighbour_top)
		if exposed_bottom >= top - 0.0001:
			continue

		match direction:
			0:
				_add_quad(
					st,
					Vector3(min_x, exposed_bottom, min_z),
					Vector3(min_x, exposed_bottom, max_z),
					Vector3(min_x, top, max_z),
					Vector3(min_x, top, min_z),
					Vector3.LEFT
				)
			1:
				_add_quad(
					st,
					Vector3(max_x, exposed_bottom, min_z),
					Vector3(max_x, top, min_z),
					Vector3(max_x, top, max_z),
					Vector3(max_x, exposed_bottom, max_z),
					Vector3.RIGHT
				)
			4:
				_add_quad(
					st,
					Vector3(min_x, exposed_bottom, min_z),
					Vector3(min_x, top, min_z),
					Vector3(max_x, top, min_z),
					Vector3(max_x, exposed_bottom, min_z),
					Vector3.FORWARD
				)
			5:
				_add_quad(
					st,
					Vector3(min_x, exposed_bottom, max_z),
					Vector3(max_x, exposed_bottom, max_z),
					Vector3(max_x, top, max_z),
					Vector3(min_x, top, max_z),
					Vector3.BACK
				)


func _foam_band_texels(height: float, cell_size: Vector3) -> int:
	var texel := 1.0 / float(MAX_HEIGHT)
	var depth_fraction := clampf(height / float(MAX_HEIGHT), 0.0, 1.0)
	var max_band := mini(
		FOAM_TEXELS,
		maxi(1, int(floor(minf(cell_size.x, cell_size.z) / texel * 0.5)))
	)
	var band := int(round(float(FOAM_TEXELS) * depth_fraction))
	return clampi(band, 1, max_band)


## Clean, fully opaque foam strip inside the shoreline. The strip width scales
## with water depth, and its UVs crop the texture so each foam texel keeps the
## 1:1 voxel-pixel mapping.
func _add_horizontal_foam(
	st: SurfaceTool,
	cell: Vector3i,
	height: float,
	center: Vector3,
	cell_size: Vector3
) -> int:
	if _is_covered_above(cell) or _water_has_ceiling(cell, height):
		return 0

	var half := cell_size * 0.5
	var top := (
		center.y - half.y
		+ _visual_height(cell, height) * cell_size.y
		+ EDGE_SURFACE_OFFSET
	)
	var min_x := center.x - half.x
	var max_x := center.x + half.x
	var min_z := center.z - half.z
	var max_z := center.z + half.z
	var texel := 1.0 / float(MAX_HEIGHT)
	var band := _foam_band_texels(height, cell_size)
	var foam_width := float(band) * texel
	var v_far := 1.0 - float(band) / float(FOAM_TEXELS)
	var u_scale := 1.0 / (texel * FOAM_TEXTURE_WIDTH)
	var count := 0

	for direction: int in WALL_FACES:
		if not _is_blocking(cell + FACE_NORMALS[direction]):
			continue

		# Trim the band where it meets a perpendicular wall so two banks never
		# overlap at a corner. Lower-index walls (0/1) keep the corner.
		var start_trim := 0.0
		var end_trim := 0.0
		if direction == 4 or direction == 5:
			if _is_blocking(cell + FACE_NORMALS[0]):
				start_trim = foam_width
			if _is_blocking(cell + FACE_NORMALS[1]):
				end_trim = foam_width

		match direction:
			0:
				_add_edge_uv_quad(
					st,
					Vector3(min_x, top, min_z),
					Vector3(min_x, top, max_z),
					Vector3(min_x + foam_width, top, max_z),
					Vector3(min_x + foam_width, top, min_z),
					Vector3.UP,
					min_z * u_scale,
					max_z * u_scale,
					max_z * u_scale,
					min_z * u_scale,
					1.0,
					1.0,
					v_far,
					v_far
				)
			1:
				_add_edge_uv_quad(
					st,
					Vector3(max_x, top, min_z),
					Vector3(max_x, top, max_z),
					Vector3(max_x - foam_width, top, max_z),
					Vector3(max_x - foam_width, top, min_z),
					Vector3.UP,
					min_z * u_scale,
					max_z * u_scale,
					max_z * u_scale,
					min_z * u_scale,
					1.0,
					1.0,
					v_far,
					v_far
				)
			4:
				var x0 := min_x + start_trim
				var x1 := max_x - end_trim
				_add_edge_uv_quad(
					st,
					Vector3(x0, top, min_z),
					Vector3(x1, top, min_z),
					Vector3(x1, top, min_z + foam_width),
					Vector3(x0, top, min_z + foam_width),
					Vector3.UP,
					x0 * u_scale,
					x1 * u_scale,
					x1 * u_scale,
					x0 * u_scale,
					1.0,
					1.0,
					v_far,
					v_far
				)
			5:
				var x0 := min_x + start_trim
				var x1 := max_x - end_trim
				_add_edge_uv_quad(
					st,
					Vector3(x0, top, max_z),
					Vector3(x1, top, max_z),
					Vector3(x1, top, max_z - foam_width),
					Vector3(x0, top, max_z - foam_width),
					Vector3.UP,
					x0 * u_scale,
					x1 * u_scale,
					x1 * u_scale,
					x0 * u_scale,
					1.0,
					1.0,
					v_far,
					v_far
				)
		count += 1

	return count


## Fills the 5x5 corner square where two perpendicular foam bands meet.
## The patch sits just above the bands so it bridges their texture ends
## without z-fighting.
func _add_horizontal_corners(
	st: SurfaceTool,
	cell: Vector3i,
	height: float,
	center: Vector3,
	cell_size: Vector3
) -> int:
	if _is_covered_above(cell) or _water_has_ceiling(cell, height):
		return 0

	var half := cell_size * 0.5
	var top := (
		center.y - half.y
		+ _visual_height(cell, height) * cell_size.y
		+ EDGE_SURFACE_OFFSET
		+ 0.0006
	)
	var min_x := center.x - half.x
	var max_x := center.x + half.x
	var min_z := center.z - half.z
	var max_z := center.z + half.z
	var texel := 1.0 / float(MAX_HEIGHT)
	var band := _foam_band_texels(height, cell_size)
	var size := float(band) * texel
	var uv0 := 1.0 - float(band) / float(FOAM_TEXELS)
	var count := 0
	var corners := [
		[0, 4, min_x, min_z, 1.0, 1.0],
		[0, 5, min_x, max_z, 1.0, -1.0],
		[1, 4, max_x, min_z, -1.0, 1.0],
		[1, 5, max_x, max_z, -1.0, -1.0],
	]

	for corner in corners:
		var first: int = corner[0]
		var second: int = corner[1]
		if not _is_blocking(cell + FACE_NORMALS[first]):
			continue
		if not _is_blocking(cell + FACE_NORMALS[second]):
			continue

		var x0: float = corner[2]
		var z0: float = corner[3]
		var x1: float = x0 + float(corner[4]) * size
		var z1: float = z0 + float(corner[5]) * size
		_add_edge_uv_quad(
			st,
			Vector3(x0, top, z0),
			Vector3(x1, top, z0),
			Vector3(x1, top, z1),
			Vector3(x0, top, z1),
			Vector3.UP,
			uv0,
			1.0,
			1.0,
			uv0,
			uv0,
			uv0,
			1.0,
			1.0
		)
		count += 1

	return count


func _add_box_faces(st: SurfaceTool, min_corner: Vector3, max_corner: Vector3) -> void:
	var min_x := min_corner.x
	var min_y := min_corner.y
	var min_z := min_corner.z
	var max_x := max_corner.x
	var max_y := max_corner.y
	var max_z := max_corner.z

	_add_quad(
		st,
		Vector3(min_x, max_y, min_z),
		Vector3(max_x, max_y, min_z),
		Vector3(max_x, max_y, max_z),
		Vector3(min_x, max_y, max_z),
		Vector3.UP
	)
	_add_quad(
		st,
		Vector3(min_x, min_y, min_z),
		Vector3(min_x, min_y, max_z),
		Vector3(max_x, min_y, max_z),
		Vector3(max_x, min_y, min_z),
		Vector3.DOWN
	)
	_add_quad(
		st,
		Vector3(min_x, min_y, min_z),
		Vector3(min_x, max_y, min_z),
		Vector3(max_x, max_y, min_z),
		Vector3(max_x, min_y, min_z),
		Vector3.FORWARD
	)
	_add_quad(
		st,
		Vector3(min_x, min_y, max_z),
		Vector3(max_x, min_y, max_z),
		Vector3(max_x, max_y, max_z),
		Vector3(min_x, max_y, max_z),
		Vector3.BACK
	)
	_add_quad(
		st,
		Vector3(min_x, min_y, min_z),
		Vector3(min_x, min_y, max_z),
		Vector3(min_x, max_y, max_z),
		Vector3(min_x, max_y, min_z),
		Vector3.LEFT
	)
	_add_quad(
		st,
		Vector3(max_x, min_y, min_z),
		Vector3(max_x, max_y, min_z),
		Vector3(max_x, max_y, max_z),
		Vector3(max_x, min_y, max_z),
		Vector3.RIGHT
	)


func _add_quad(
	st: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3
) -> void:
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_normal(normal)
	st.add_vertex(c)
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_normal(normal)
	st.add_vertex(c)
	st.set_normal(normal)
	st.add_vertex(d)


func _add_colored_quad(
	st: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3,
	color: Color
) -> void:
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(a)
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(b)
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(c)
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(a)
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(c)
	st.set_normal(normal)
	st.set_color(color)
	st.add_vertex(d)


func _add_edge_uv_quad(
	st: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3,
	u_a: float,
	u_b: float,
	u_c: float,
	u_d: float,
	v_a: float,
	v_b: float,
	v_c: float,
	v_d: float
) -> void:
	st.set_normal(normal)
	st.set_uv(Vector2(u_a, v_a))
	st.add_vertex(a)
	st.set_normal(normal)
	st.set_uv(Vector2(u_b, v_b))
	st.add_vertex(b)
	st.set_normal(normal)
	st.set_uv(Vector2(u_c, v_c))
	st.add_vertex(c)
	st.set_normal(normal)
	st.set_uv(Vector2(u_a, v_a))
	st.add_vertex(a)
	st.set_normal(normal)
	st.set_uv(Vector2(u_c, v_c))
	st.add_vertex(c)
	st.set_normal(normal)
	st.set_uv(Vector2(u_d, v_d))
	st.add_vertex(d)
