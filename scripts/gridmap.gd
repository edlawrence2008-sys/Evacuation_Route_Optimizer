class_name NavGridMap
extends GridMap

signal block_placed(cell: Vector3i, item: int)
signal block_removed(cell: Vector3i)
signal navigation_changed(changed_cells: Array[Vector3i])
signal chunk_loaded(chunk: Vector2i)
signal chunk_unloaded(chunk: Vector2i)
signal flow_field_baked(target_cell: Vector3i)

@export var agent_radius: float = 1.0
@export var wall_penalty_max: float = 2.0
@export var gap_penalty_max: float = 3.0
@export var enable_greedy_meshing: bool = true

@export var debug_greedy_colors: bool = false:
	set(value):
		debug_greedy_colors = value
		if _mesher != null:
			_mesher.set_debug_colors(value)

@export_group("Block Library")
## Stair items are generated from the full block set on first load. The
## template item supplies the stair geometry and collision.
@export var auto_generate_stairs: bool = true
## Preferred stair model. Its mesh and generated collision are reused for every
## Auto_Stairs_<texture> item. Point this at res://models/Specialblocks/stair.gltf.
@export var auto_stair_scene: PackedScene = preload("res://models/Specialblocks/stair.gltf")
## Fallback MeshLibrary item when auto_stair_scene is empty.
@export var auto_stair_template_item: int = 1
@export var auto_stair_prefix: String = "Auto_Stairs_"
## Refresh existing Auto_Stairs_* items when the template changes.
@export var auto_stair_replace_existing: bool = true

@export_group("Debug Drawing")
## Draw recent A* paths and baked flow-field arrows.
@export var debug_show_paths: bool = false:
	set(value):
		debug_show_paths = value
		if value:
			_ensure_debug_mesh()
			_debug_redraw()
		else:
			_debug_clear()
## How long a requested A* path stays visible.
@export var debug_path_lifetime: float = 2.0

@export var path_collision_mask: int = 1
@export var smoothing_max_lookahead: int = 16
@export var closest_point_max_distance: float = 2.0
@export var path_budget_usec: int = 2000

@export_group("Baked Flow Fields")
@export var enable_flow_fields: bool = true
@export var flow_field_max_cache: int = 32
@export var flow_field_max_path_steps: int = 4096
@export var flow_field_max_cells: int = 10000 # cap on cells per baked field
@export var flow_bake_budget_usec: int = 1500 # per frame, shared by all bakes in progress

@export_group("Parallel Lanes")
@export var lane_taper_distance: float = 4.0 # distance from each end over which the offset fades in/out
@export var lane_sample_spacing: float = 2.5 # a lane is built from points this far apart
@export var lane_wall_margin: float = 0.6 # clearance kept between a lane and any wall
@export var lane_max_gap_exposure: float = 0.34 # lanes avoid cells with more open sides than this

## How a placed block's mesh is allowed to rotate.
enum DirectionalKind {
	CARDINAL, ## Four horizontal directions.
	FACING,   ## Four horizontal directions plus up/down.
	PILLAR,   ## Three axes, like a log.
}

var _directional_kinds: Dictionary = {} # item id -> DirectionalKind

const WALL_CHECK_DIRS: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.FORWARD,
	Vector3i.BACK,
]

## "No cell found". Vector3i.ZERO can't be used for this, it is a real cell.
const NO_CELL: Vector3i = Vector3i(2147483647, 2147483647, 2147483647)

## Vertical offsets probed when looking for ground under a point.
const GROUND_PROBE_DY: Array[int] = [1, 0, -1, -2]

## Chunks are CHUNK_SIZE x CHUNK_SIZE columns in X/Z and span every Y level.
const CHUNK_SIZE: int = 16
const CHUNK_DATA_VERSION: int = 1
const INTS_PER_BLOCK: int = 5

var astar: AStar3D = AStar3D.new()
var cell_to_id_map: Dictionary = {}
var _id_to_cell: Dictionary = {} # astar point id -> cell
var free_ids: Array[int] = []
var next_id: int = 1

## chunk -> { cell: true }
var _chunk_cells: Dictionary = {}

## chunk -> true
var _dirty_chunks: Dictionary = {}

var _mesher: ChunkMesher = null
var request_queue: Array[Dictionary] = []

## Debug path drawing state.
var _debug_paths: Array[Dictionary] = []
var _debug_mesh_instance: MeshInstance3D = null
var _debug_immediate: ImmediateMesh = null
var _debug_astar_material: StandardMaterial3D = null
var _debug_flow_material: StandardMaterial3D = null
var _debug_redraw_accum: float = 0.0

const DEBUG_PATH_MAX_RECORDS: int = 64
const DEBUG_REFRESH_INTERVAL: float = 0.1
const DEBUG_MAX_FLOW_SEGMENTS: int = 6000

## target_cell -> { cell: next_cell }
var _flow_fields: Dictionary = {}

## target_cell -> FlowBakeJob (fields still being baked across frames)
var _bake_jobs: Dictionary = {}

## Real length of each NEIGHBOR_OFFSETS step, so flow-field costs match A* distances.
var _step_lengths: Array[float] = []

## Moves: 4 straight, 4 flat diagonals, and 8 one-block stair steps.
## Flat diagonals are only allowed when both cells beside them are walkable
## (see _can_move_between), so agents can't cut across a blocked corner.
const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i.RIGHT,
	Vector3i.LEFT,
	Vector3i.FORWARD,
	Vector3i.BACK,
	Vector3i(1, 0, 1),
	Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1),
	Vector3i(-1, 0, -1),
	Vector3i(1, 1, 0),
	Vector3i(-1, 1, 0),
	Vector3i(0, 1, 1),
	Vector3i(0, -1, 1),
	Vector3i(0, 1, -1),
	Vector3i(0, -1, -1),
	Vector3i(1, -1, 0),
	Vector3i(-1, -1, 0),
]


## Progress of one flow field that is being baked a few thousand cells per frame.
class FlowBakeJob:
	var target: Vector3i
	var costs: Dictionary = {}
	var next_cell: Dictionary = {}
	var queue: Array[Vector3i] = []
	var head: int = 0


func _ready() -> void:
	add_to_group("grid_map")

	if auto_generate_stairs:
		_generate_auto_stairs()

	initialize_navigation()

	if enable_greedy_meshing:
		_mesher = ChunkMesher.new(self)
		_mesher.debug_colors = debug_greedy_colors
		_mesher.start()

	if debug_show_paths:
		_ensure_debug_mesh()


func _exit_tree() -> void:
	if _mesher != null:
		_mesher.stop()

	if is_instance_valid(_debug_mesh_instance):
		_debug_mesh_instance.queue_free()
		_debug_mesh_instance = null


# ---------------------------------------------------------------------------
# Debug path drawing
# ---------------------------------------------------------------------------

func _debug_record_path(path: PackedVector3Array, from_flow_field: bool) -> void:
	if not debug_show_paths or path.size() < 2:
		return

	_debug_paths.append({
		"points": path.duplicate(),
		"flow": from_flow_field,
		"expires_ms": Time.get_ticks_msec() + int(debug_path_lifetime * 1000.0),
	})

	while _debug_paths.size() > DEBUG_PATH_MAX_RECORDS:
		_debug_paths.remove_at(0)


func _update_debug_paths(delta: float) -> void:
	if not debug_show_paths:
		return

	_debug_redraw_accum += delta
	if _debug_redraw_accum < DEBUG_REFRESH_INTERVAL:
		return

	_debug_redraw_accum = 0.0
	var now: int = Time.get_ticks_msec()

	for index in range(_debug_paths.size() - 1, -1, -1):
		if int(_debug_paths[index]["expires_ms"]) < now:
			_debug_paths.remove_at(index)

	_debug_redraw()


func _ensure_debug_mesh() -> void:
	if _debug_mesh_instance != null or not is_inside_tree():
		return

	var host: Node = get_parent()
	if host == null:
		host = get_tree().current_scene
	if host == null:
		return

	_debug_mesh_instance = MeshInstance3D.new()
	_debug_mesh_instance.name = "PathDebug"
	_debug_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_immediate = ImmediateMesh.new()
	_debug_mesh_instance.mesh = _debug_immediate
	_debug_mesh_instance.visible = false
	host.add_child(_debug_mesh_instance)
	_debug_mesh_instance.global_transform = Transform3D.IDENTITY

	_debug_astar_material = _make_debug_material(Color(1.0, 0.7, 0.1))
	_debug_flow_material = _make_debug_material(Color(0.1, 0.85, 1.0))


func _make_debug_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true
	material.disable_receive_shadows = true
	return material


func _debug_redraw() -> void:
	_ensure_debug_mesh()
	if _debug_immediate == null:
		return

	_debug_immediate.clear_surfaces()
	var drew_something: bool = false

	var astar_started: bool = false
	for record: Dictionary in _debug_paths:
		if bool(record["flow"]):
			continue

		if not astar_started:
			_debug_immediate.surface_begin(
				Mesh.PRIMITIVE_LINES,
				_debug_astar_material
			)
			astar_started = true

		_debug_add_polyline(record["points"])
		drew_something = true

	if astar_started:
		_debug_immediate.surface_end()

	var flow_started: bool = false
	var flow_segments: int = 0

	for target_cell: Vector3i in _flow_fields:
		var field: Dictionary = _flow_fields[target_cell]

		for cell: Vector3i in field:
			if flow_segments >= DEBUG_MAX_FLOW_SEGMENTS:
				break

			var next_cell: Vector3i = field[cell]
			if next_cell == cell:
				continue

			if not flow_started:
				_debug_immediate.surface_begin(
					Mesh.PRIMITIVE_LINES,
					_debug_flow_material
				)
				flow_started = true

			_debug_immediate.surface_add_vertex(
				to_global(_nav_point_position(cell))
			)
			_debug_immediate.surface_add_vertex(
				to_global(_nav_point_position(next_cell))
			)
			flow_segments += 1
			drew_something = true

		if flow_segments >= DEBUG_MAX_FLOW_SEGMENTS:
			break

	if flow_started:
		_debug_immediate.surface_end()

	_debug_mesh_instance.visible = drew_something


func _debug_add_polyline(points: PackedVector3Array) -> void:
	for index in range(points.size() - 1):
		_debug_immediate.surface_add_vertex(points[index])
		_debug_immediate.surface_add_vertex(points[index + 1])


func _debug_clear() -> void:
	_debug_paths.clear()
	_debug_redraw_accum = 0.0

	if _debug_immediate != null:
		_debug_immediate.clear_surfaces()
	if is_instance_valid(_debug_mesh_instance):
		_debug_mesh_instance.visible = false


func initialize_navigation() -> void:
	astar.clear()
	cell_to_id_map.clear()
	_id_to_cell.clear()
	free_ids.clear()
	next_id = 1
	_chunk_cells.clear()
	_dirty_chunks.clear()
	_flow_fields.clear()
	_bake_jobs.clear()
	_build_step_lengths()

	var used_cells: Array[Vector3i] = get_used_cells()

	for cell in used_cells:
		_track_cell(cell)

		if not _is_walkable(cell):
			continue

		var point_id: int = _get_next_id()
		cell_to_id_map[cell] = point_id
		_id_to_cell[point_id] = cell
		astar.add_point(
			point_id,
			_nav_point_position(cell),
			_point_weight_scale(cell)
		)

	for cell: Vector3i in cell_to_id_map:
		_connect_cell_neighbors(cell)


func _build_step_lengths() -> void:
	_step_lengths.clear()

	for offset in NEIGHBOR_OFFSETS:
		_step_lengths.append((Vector3(offset) * cell_size).length())


func cancel_path_requests(requester: Node) -> void:
	if requester == null:
		return

	for index in range(request_queue.size() - 1, -1, -1):
		var request: Dictionary = request_queue[index]

		if request.get("requester") == requester:
			request_queue.remove_at(index)


func _get_next_id() -> int:
	if not free_ids.is_empty():
		return free_ids.pop_back()

	var point_id: int = next_id
	next_id += 1
	return point_id


func _connect_cell_neighbors(cell: Vector3i) -> void:
	var point_id: int = cell_to_id_map[cell]

	for offset in NEIGHBOR_OFFSETS:
		var neighbor_cell: Vector3i = cell + offset
		var neighbor_id: int = cell_to_id_map.get(neighbor_cell, -1)

		if neighbor_id == -1:
			continue

		if not _can_move_between(cell, offset):
			continue

		if not astar.are_points_connected(point_id, neighbor_id):
			astar.connect_points(point_id, neighbor_id, true)


## Allows diagonal movement only when both orthogonal alternatives are walkable.
## This prevents cutting across blocked corners or unsupported diagonal gaps.
func _can_move_between(cell: Vector3i, offset: Vector3i) -> bool:
	if offset.y != 0:
		# Both cells are already registered as walkable navigation points.
		# Do not reject stair connections by testing the lower side cell.
		return true

	if offset.x == 0 or offset.z == 0:
		return true

	var side_a: Vector3i = cell + Vector3i(offset.x, 0, 0)
	var side_b: Vector3i = cell + Vector3i(0, 0, offset.z)

	return _is_walkable(side_a) and _is_walkable(side_b)


func _wall_penalty_scale(cell: Vector3i) -> float:
	var open_count: int = 0

	for dir in WALL_CHECK_DIRS:
		if not has_block(cell + Vector3i.UP + dir):
			open_count += 1

	var openness: float = float(open_count) / float(WALL_CHECK_DIRS.size())
	return lerpf(wall_penalty_max, 1.0, openness)


func _gap_penalty_scale(cell: Vector3i) -> float:
	return lerpf(1.0, gap_penalty_max, _gap_exposure(cell))


func _point_weight_scale(cell: Vector3i) -> float:
	var wall_scale: float = _wall_penalty_scale(cell)
	var gap_scale: float = _gap_penalty_scale(cell)

	return maxf(wall_scale, gap_scale)


## Fraction (0..1) of a cell's 4 sides that are open air: no wall at body height
## and no floor beside it. 0 = fully supported, 1 = a lone pillar.
func _gap_exposure(cell: Vector3i) -> float:
	var exposed_count: int = 0

	for dir in WALL_CHECK_DIRS:
		var has_wall: bool = has_block(cell + Vector3i.UP + dir)
		var has_floor: bool = has_block(cell + dir)

		if not has_wall and not has_floor:
			exposed_count += 1

	return float(exposed_count) / float(WALL_CHECK_DIRS.size())


# ---------------------------------------------------------------------------
# Baked flow fields
# ---------------------------------------------------------------------------

## Queues a path request that uses a baked flow field for the destination. The first
## request to a destination starts baking the field in the background (a little each
## frame); until it is ready, requests are answered with normal A*. Once it exists,
## every request to that destination, from any NPC, just follows the cached field.
## Use this for destinations many NPCs share (evac points), not for random wander targets.
func request_flow_path(
	requester: Node,
	start: Vector3,
	end: Vector3,
	callback: Callable
) -> void:
	if requester == null or not is_instance_valid(requester):
		return

	if not callback.is_valid():
		return

	request_queue.append({
		"requester": requester,
		"start": start,
		"end": end,
		"callback": callback,
		"flow": true,
	})


## Follows an existing field, baking it right now (all at once) if it doesn't exist yet.
func request_flow_path_immediate(
	start: Vector3,
	end: Vector3
) -> PackedVector3Array:
	if not enable_flow_fields:
		return PackedVector3Array()

	var end_cell: Vector3i = _resolve_nav_cell(end)

	if end_cell == NO_CELL:
		return PackedVector3Array()

	if not _flow_fields.has(end_cell):
		_bake_flow_field_now(end_cell)

	return _path_from_flow_field(start, end_cell)


func _calculate_flow_path(
	start_world: Vector3,
	end_world: Vector3,
	smooth: bool = true
) -> PackedVector3Array:
	if enable_flow_fields:
		var end_cell: Vector3i = _resolve_nav_cell(end_world)

		if end_cell != NO_CELL:
			if _flow_fields.has(end_cell):
				var path: PackedVector3Array = _path_from_flow_field(
					start_world,
					end_cell,
					smooth
				)

				if not path.is_empty():
					return path
			else:
				_start_flow_bake(end_cell) # no-op if it is already baking

	# Field not ready yet, or the start is outside it: plain A* in the meantime.
	return _calculate_path(start_world, end_world, smooth)


## World-space steering direction from a baked field, aimed at the next cell from the
## agent's actual position (not from its cell centre, which makes movement zig-zag).
func get_flow_direction(
	world_pos: Vector3,
	target_world: Vector3
) -> Vector3:
	if not enable_flow_fields:
		return Vector3.ZERO

	var target_cell: Vector3i = _resolve_nav_cell(target_world)

	if target_cell == NO_CELL:
		return Vector3.ZERO

	var field: Dictionary = _flow_fields.get(target_cell, {})
	var cell: Vector3i = _resolve_nav_cell(world_pos)

	if field.is_empty() or cell == NO_CELL or not field.has(cell):
		return Vector3.ZERO

	var next_cell: Vector3i = field[cell]
	var direction: Vector3 = to_global(_nav_point_position(next_cell)) - world_pos
	direction.y = 0.0

	if direction.length_squared() < 0.0001:
		return Vector3.ZERO

	return direction.normalized()


func has_flow_field(target_world: Vector3) -> bool:
	if not enable_flow_fields:
		return false

	var target_cell: Vector3i = _resolve_nav_cell(target_world)

	return target_cell != NO_CELL and _flow_fields.has(target_cell)


## Resolves a world position to its navigation cell (NO_CELL when outside).
func resolve_nav_cell(world_pos: Vector3) -> Vector3i:
	return _resolve_nav_cell(world_pos)


func is_nav_cell_valid(cell: Vector3i) -> bool:
	return cell != NO_CELL and cell_to_id_map.has(cell)


## Starts baking the field for a destination if needed. Returns true when the
## field is already usable; false when it is still baking or the target is
## outside the navigation grid.
func ensure_flow_field(target_world: Vector3) -> bool:
	return ensure_flow_field_cell(_resolve_nav_cell(target_world))


func ensure_flow_field_cell(target_cell: Vector3i) -> bool:
	if not enable_flow_fields:
		return false

	if not is_nav_cell_valid(target_cell):
		return false

	if _flow_fields.has(target_cell):
		return true

	_start_flow_bake(target_cell)
	return false


func is_flow_field_ready(target_cell: Vector3i) -> bool:
	return _flow_fields.has(target_cell)


## Same steering as get_flow_direction(), but with the target cell already
## resolved so agents following the same exit do not resolve it every frame.
func get_flow_direction_for_cell(
	world_pos: Vector3,
	target_cell: Vector3i
) -> Vector3:
	var field: Dictionary = _flow_fields.get(target_cell, {})

	if field.is_empty():
		return Vector3.ZERO

	# Fast cell lookup: agents stand on a walkable cell, which may map to the
	# air cell above it. Skip the AStar closest-point fallback on this hot path.
	var base_cell: Vector3i = local_to_map(to_local(world_pos))
	var cell: Vector3i = NO_CELL

	for dy: int in [0, -1, 1, -2]:
		var candidate: Vector3i = base_cell + Vector3i(0, dy, 0)

		if cell_to_id_map.has(candidate):
			cell = candidate
			break

	if cell == NO_CELL:
		return Vector3.ZERO

	var next: Vector3i = field.get(cell, NO_CELL)

	if next == NO_CELL or next == cell:
		return Vector3.ZERO

	var direction: Vector3 = to_global(_nav_point_position(next)) - world_pos
	direction.y = 0.0

	if direction.length_squared() < 0.0001:
		return Vector3.ZERO

	return direction.normalized()


## Closest registered nav cell to a world position, or NO_CELL.
func _resolve_nav_cell(world_pos: Vector3) -> Vector3i:
	var id: int = _find_nav_id(to_local(world_pos))

	if id == -1:
		return NO_CELL

	return _id_to_cell.get(id, NO_CELL)


func _start_flow_bake(target_cell: Vector3i) -> void:
	if _bake_jobs.has(target_cell) or _flow_fields.has(target_cell):
		return

	if target_cell == NO_CELL or not cell_to_id_map.has(target_cell):
		return

	if _step_lengths.size() != NEIGHBOR_OFFSETS.size():
		_build_step_lengths()

	var job := FlowBakeJob.new()
	job.target = target_cell
	job.costs[target_cell] = 0.0
	job.queue.append(target_cell)
	_bake_jobs[target_cell] = job


func _bake_flow_field_now(target_cell: Vector3i) -> void:
	_start_flow_bake(target_cell)

	var job: FlowBakeJob = _bake_jobs.get(target_cell)

	if job == null:
		return

	_step_bake_job(job, 0, -1) # no time limit
	_bake_jobs.erase(target_cell)
	_finish_bake_job(job)


## Spends the per-frame bake budget on whichever fields are still being baked.
func _advance_bake_jobs() -> void:
	if _bake_jobs.is_empty():
		return

	var start_usec: int = Time.get_ticks_usec()

	for target_cell: Vector3i in _bake_jobs.keys():
		var job: FlowBakeJob = _bake_jobs[target_cell]

		if _step_bake_job(job, start_usec, flow_bake_budget_usec):
			_bake_jobs.erase(target_cell)
			_finish_bake_job(job)

		if Time.get_ticks_usec() - start_usec >= flow_bake_budget_usec:
			break


## Floods outward from the target until the budget runs out. Returns true when the whole
## field has been built. Each cell's cost is the cheapest way to reach the target, and it
## remembers the neighbour to step to next. Step cost is real distance times the weight of
## the cell being entered, which is what AStar3D uses, so flow-field routes and A* routes
## agree about walls and gaps. A negative budget means no limit.
func _step_bake_job(job: FlowBakeJob, start_usec: int, budget_usec: int) -> bool:
	var processed: int = 0

	while job.head < job.queue.size():
		var current: Vector3i = job.queue[job.head]
		job.head += 1

		var current_id: int = cell_to_id_map.get(current, -1)

		if current_id != -1:
			var current_cost: float = job.costs[current]

			for i in NEIGHBOR_OFFSETS.size():
				var step: Vector3i = NEIGHBOR_OFFSETS[i]
				var neighbor: Vector3i = current + step

				if not cell_to_id_map.has(neighbor):
					continue

				if not _can_move_between(current, step):
					continue

				# The search runs backwards from the target. In the forward A* path,
				# this edge enters `current`, not `neighbor`, so charge current's weight.
				var enter_weight: float = astar.get_point_weight_scale(current_id)
				var neighbor_cost: float = current_cost + _step_lengths[i] * enter_weight
				var known: bool = job.costs.has(neighbor)

				if known and neighbor_cost >= float(job.costs[neighbor]):
					continue

				# Cap the field size. Cells beyond it fall back to A* at request time.
				if not known and job.costs.size() >= flow_field_max_cells:
					continue

				job.costs[neighbor] = neighbor_cost
				job.next_cell[neighbor] = current
				job.queue.append(neighbor)

				processed += 1

				if budget_usec >= 0 and processed % 32 == 0:
					if Time.get_ticks_usec() - start_usec >= budget_usec:
						return false

	return true


func _finish_bake_job(job: FlowBakeJob) -> void:
	if job.next_cell.is_empty():
		return

	_flow_fields[job.target] = job.next_cell
	_enforce_flow_field_cache_limit()
	flow_field_baked.emit(job.target)


func _path_from_flow_field(
	start_world: Vector3,
	target_cell: Vector3i,
	smooth: bool = true
) -> PackedVector3Array:
	var field: Dictionary = _flow_fields.get(target_cell, {})

	if field.is_empty():
		return PackedVector3Array()

	var start_cell: Vector3i = _resolve_nav_cell(start_world)

	if start_cell == NO_CELL:
		return PackedVector3Array()

	if start_cell == target_cell:
		var direct_path := PackedVector3Array()
		direct_path.append(to_global(_nav_point_position(start_cell)))
		return direct_path

	if not field.has(start_cell):
		return PackedVector3Array()

	var cells: Array[Vector3i] = [start_cell]
	var current: Vector3i = start_cell

	while current != target_cell:
		if not field.has(current):
			return PackedVector3Array()

		var next: Vector3i = field[current]

		if next == current:
			return PackedVector3Array()

		cells.append(next)
		current = next

		if cells.size() > flow_field_max_path_steps:
			return PackedVector3Array()

	var world_path := PackedVector3Array()

	for cell in cells:
		world_path.append(to_global(_nav_point_position(cell)))

	var final_path: PackedVector3Array = _finalize_path(
		start_world,
		world_path,
		smooth
	)
	_debug_record_path(final_path, true)
	return final_path


func _enforce_flow_field_cache_limit() -> void:
	while _flow_fields.size() > flow_field_max_cache:
		var oldest_key: Variant = null

		for key: Vector3i in _flow_fields:
			oldest_key = key
			break

		if oldest_key == null:
			return

		_flow_fields.erase(oldest_key)


func _invalidate_flow_fields(affected_cells: Array[Vector3i]) -> void:
	if not enable_flow_fields:
		return

	if _flow_fields.is_empty() and _bake_jobs.is_empty():
		return

	var stale: Array[Vector3i] = []

	for target_cell: Vector3i in _flow_fields:
		var field: Dictionary = _flow_fields[target_cell]

		for cell in affected_cells:
			if _cell_touches_field(cell, target_cell, field):
				stale.append(target_cell)
				break

	for target_cell in stale:
		_flow_fields.erase(target_cell)

	# A half-baked field can be stale too. Drop it; the next request restarts the bake.
	var stale_jobs: Array[Vector3i] = []

	for target_cell: Vector3i in _bake_jobs:
		var job: FlowBakeJob = _bake_jobs[target_cell]

		for cell in affected_cells:
			if _cell_touches_field(cell, target_cell, job.next_cell):
				stale_jobs.append(target_cell)
				break

	for target_cell in stale_jobs:
		_bake_jobs.erase(target_cell)


## A change matters to a field if it happened in the field, on its target, or right
## beside it: a newly walkable cell next to a field can open a shortcut or a new way in.
func _cell_touches_field(
	cell: Vector3i,
	target_cell: Vector3i,
	field: Dictionary
) -> bool:
	if cell == target_cell or field.has(cell):
		return true

	for offset in NEIGHBOR_OFFSETS:
		if field.has(cell + offset):
			return true

	return false


# ---------------------------------------------------------------------------
# Path requests
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _mesher != null:
		_mesher.process()

	_update_debug_paths(_delta)
	_advance_bake_jobs()

	if request_queue.is_empty():
		return

	var start_usec: int = Time.get_ticks_usec()
	# During a burst (hundreds of NPCs routing at once), skip the expensive
	# per-path smoothing and lane offsetting. Raw cell paths are still valid
	# and normal play keeps the full quality.
	var fast_paths: bool = request_queue.size() >= 32

	while not request_queue.is_empty():
		var request: Dictionary = request_queue[0]
		request_queue.remove_at(0)

		var requester: Variant = request.get("requester")
		var callback: Variant = request.get("callback")

		var requester_valid: bool = (
			requester != null
			and is_instance_valid(requester)
		)
		var callback_valid: bool = (
			callback is Callable
			and callback.is_valid()
		)

		if not requester_valid or not callback_valid:
			continue

		var path: PackedVector3Array

		if request.get("flow", false):
			path = _calculate_flow_path(
				request.start,
				request.end,
				not fast_paths
			)
		else:
			path = _calculate_path(
				request.start,
				request.end,
				not fast_paths
			)

		if not fast_paths:
			path = _apply_requester_lane(requester, path)

		callback.call(path)

		if Time.get_ticks_usec() - start_usec >= path_budget_usec:
			break


func estimate_path_distance(start_world: Vector3, end_world: Vector3) -> float:
	if astar.get_point_count() == 0:
		return INF

	var start_id: int = _find_nav_id(to_local(start_world))
	var end_id: int = _find_nav_id(to_local(end_world))

	if start_id == -1 or end_id == -1:
		return INF

	var raw_local_path: PackedVector3Array = astar.get_point_path(
		start_id,
		end_id
	)

	if raw_local_path.is_empty():
		return INF

	var total: float = 0.0

	for i in range(raw_local_path.size() - 1):
		var p1: Vector3 = to_global(raw_local_path[i])
		var p2: Vector3 = to_global(raw_local_path[i + 1])
		total += p1.distance_to(p2)

	return total


func request_path_immediate(start: Vector3, end: Vector3) -> PackedVector3Array:
	return _calculate_path(start, end)


func request_path(
	requester: Node,
	start: Vector3,
	end: Vector3,
	callback: Callable
) -> void:
	if requester == null or not is_instance_valid(requester):
		return

	if not callback.is_valid():
		return

	request_queue.append({
		"requester": requester,
		"start": start,
		"end": end,
		"callback": callback,
	})


func _calculate_path(
	start_world: Vector3,
	end_world: Vector3,
	smooth: bool = true
) -> PackedVector3Array:
	if astar.get_point_count() == 0:
		return PackedVector3Array()

	var start_id: int = _find_nav_id(to_local(start_world))
	var end_id: int = _find_nav_id(to_local(end_world))

	if start_id == -1 or end_id == -1:
		return PackedVector3Array()

	var raw_local_path: PackedVector3Array = astar.get_point_path(
		start_id,
		end_id
	)

	if raw_local_path.is_empty():
		return PackedVector3Array()

	var raw_world_path: PackedVector3Array = PackedVector3Array()

	for point in raw_local_path:
		raw_world_path.append(to_global(point))

	var final_path: PackedVector3Array = _finalize_path(
		start_world,
		raw_world_path,
		smooth
	)
	_debug_record_path(final_path, false)
	return final_path


## Smooths a raw cell-to-cell path, then removes the backtrack at its start.
func _finalize_path(
	start_world: Vector3,
	raw_world_path: PackedVector3Array,
	smooth: bool = true
) -> PackedVector3Array:
	var path: PackedVector3Array = raw_world_path

	if smooth and path.size() > 2:
		path = _physics_smooth_path(path)

	return _trim_path_start(start_world, path)


## The first waypoint is the centre of the cell the agent is standing in. If the agent
## is already closer to the second waypoint than that centre is, walking to the centre
## first is a little backwards step at the start of every path, so drop it.
func _trim_path_start(
	start_world: Vector3,
	path: PackedVector3Array
) -> PackedVector3Array:
	if path.size() < 2:
		return path

	var start_flat := Vector2(start_world.x, start_world.z)
	var first := Vector2(path[0].x, path[0].z)
	var second := Vector2(path[1].x, path[1].z)

	if start_flat.distance_squared_to(second) < first.distance_squared_to(second):
		return path.slice(1)

	return path


func _physics_smooth_path(raw_path: PackedVector3Array) -> PackedVector3Array:
	var smoothed: PackedVector3Array = PackedVector3Array()
	smoothed.append(raw_path[0])

	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state

	# One query object reused for every ray in this path, instead of one per ray.
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = path_collision_mask

	var current_index: int = 0
	var count: int = raw_path.size()

	while current_index < count - 1:
		var furthest_visible: int = current_index + 1
		var max_lookahead: int = mini(
			current_index + smoothing_max_lookahead,
			count
		)

		for test_index in range(current_index + 2, max_lookahead):
			if _segment_clear(
				space_state,
				query,
				raw_path[current_index],
				raw_path[test_index]
			):
				furthest_visible = test_index
			else:
				break

		smoothed.append(raw_path[furthest_visible])
		current_index = furthest_visible

	return smoothed


## A shortcut is allowed only if there is ground under the whole way (so smoothing can't
## cut a corner across a hole or off a ledge) and three rays, centre plus one agent
## radius to each side, hit nothing.
func _segment_clear(
	space_state: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D,
	from_pt: Vector3,
	to_pt: Vector3
) -> bool:
	var direction: Vector3 = to_pt - from_pt
	direction.y = 0.0

	if direction.length_squared() < 0.0001:
		return true

	if not _segment_has_ground(from_pt, to_pt):
		return false

	var side: Vector3 = direction.normalized().cross(Vector3.UP) * agent_radius
	var lift := Vector3(0.0, maxf(agent_radius * 0.5, 0.2), 0.0)

	if _ray_blocked(space_state, query, from_pt + lift, to_pt + lift):
		return false

	if _ray_blocked(space_state, query, from_pt + lift + side, to_pt + lift + side):
		return false

	return not _ray_blocked(space_state, query, from_pt + lift - side, to_pt + lift - side)


func _ray_blocked(
	space_state: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D,
	from_pos: Vector3,
	to_pos: Vector3
) -> bool:
	query.from = from_pos
	query.to = to_pos
	return not space_state.intersect_ray(query).is_empty()


## Samples along a segment (every half cell) and checks that walkable ground is under it.
func _segment_has_ground(from_world: Vector3, to_world: Vector3) -> bool:
	var from_local: Vector3 = to_local(from_world)
	var to_local_pos: Vector3 = to_local(to_world)
	var step: float = maxf(minf(cell_size.x, cell_size.z) * 0.5, 0.01)
	var samples: int = maxi(int(ceilf(from_local.distance_to(to_local_pos) / step)), 1)

	for i in range(1, samples):
		var t: float = float(i) / float(samples)

		if not _has_ground_near(from_local.lerp(to_local_pos, t)):
			return false

	return true


## True if a registered walkable cell sits within about one block of this local position.
func _has_ground_near(local_pos: Vector3) -> bool:
	var base_cell: Vector3i = local_to_map(local_pos)

	for dy: int in GROUND_PROBE_DY:
		var cell: Vector3i = base_cell + Vector3i(0, dy, 0)
		var id: int = cell_to_id_map.get(cell, -1)

		if id == -1:
			continue

		if absf(astar.get_point_position(id).y - local_pos.y) <= cell_size.y * 1.1:
			return true

	return false


# ---------------------------------------------------------------------------
# Parallel lanes
# ---------------------------------------------------------------------------

## If the requester has a non-zero `lane_offset` property, shifts the path by it.
func _apply_requester_lane(
	requester: Object,
	path: PackedVector3Array
) -> PackedVector3Array:
	if path.size() < 2:
		return path

	var lane: Variant = requester.get("lane_offset")

	if lane is float and absf(lane) >= 0.05:
		return apply_lane_offset(path, lane)

	return path


## Moves a path sideways by `offset` metres (positive one way, negative the other) so
## agents with different offsets walk parallel to each other instead of along one line.
## The offset fades in from the start and out toward the end, is cut back where a wall is
## closer than the offset, and is dropped where there is no safe ground. If the shifted
## path would collide with something, the offset is halved and retried (twice); the
## original path is returned as a last resort.
func apply_lane_offset(
	path: PackedVector3Array,
	offset: float
) -> PackedVector3Array:
	if absf(offset) < 0.05 or path.size() < 2:
		return path

	var points: PackedVector3Array = _resample_path(
		path,
		maxf(lane_sample_spacing, 0.5)
	)

	if points.size() < 3:
		return path

	var along := PackedFloat32Array()
	along.resize(points.size())
	var total: float = 0.0

	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
		along[i] = total

	if total < 0.01:
		return path

	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = path_collision_mask

	var attempt_offset: float = offset

	for attempt in 3:
		var lane: PackedVector3Array = _build_lane(
			points,
			along,
			total,
			attempt_offset,
			space_state,
			query
		)

		if not lane.is_empty():
			return lane

		attempt_offset *= 0.5

	return path


## Splits long segments so the offset can change smoothly along a straight path.
func _resample_path(
	path: PackedVector3Array,
	spacing: float
) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.append(path[0])

	for i in range(1, path.size()):
		var a: Vector3 = path[i - 1]
		var b: Vector3 = path[i]
		var pieces: int = maxi(int(ceilf(a.distance_to(b) / spacing)), 1)

		for k in range(1, pieces):
			result.append(a.lerp(b, float(k) / float(pieces)))

		result.append(b)

	return result


## Returns the shifted path, or an empty array if it could not produce a safe lane.
## A blocked sample reverts that sample toward the centreline instead of rejecting the
## entire lane, so one tight corner does not erase an otherwise useful parallel route.
func _build_lane(
	points: PackedVector3Array,
	along: PackedFloat32Array,
	total: float,
	offset: float,
	space_state: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D
) -> PackedVector3Array:
	var lane := PackedVector3Array()
	var lift := Vector3(0.0, maxf(agent_radius * 0.5, 0.2), 0.0)
	var last_index: int = points.size() - 1

	lane.append(points[0])

	for i in range(1, last_index):
		var original: Vector3 = points[i]
		var direction: Vector3 = points[i + 1] - points[i - 1]
		direction.y = 0.0

		if direction.length_squared() < 0.0001:
			lane.append(original)
			continue

		direction = direction.normalized()
		var perpendicular := Vector3(-direction.z, 0.0, direction.x)

		var edge_distance: float = minf(along[i], total - along[i])
		var fade: float = smoothstep(
			0.0,
			1.0,
			clampf(edge_distance / maxf(lane_taper_distance, 0.01), 0.0, 1.0)
		)

		var desired: float = offset * fade
		var allowed: float = _clamp_to_clearance(
			original,
			perpendicular,
			desired,
			lift,
			space_state,
			query
		)
		var candidate: Vector3 = original + perpendicular * allowed

		if absf(allowed) > 0.01 and not is_path_position_safe(
			candidate,
			lane_max_gap_exposure
		):
			# No safe sideways room here: fall back to the centreline.
			candidate = original

		lane.append(candidate)

	lane.append(points[last_index])

	# Validate locally. Revert only the point after a blocked segment, keeping the
	# rest of the lane intact.
	for i in range(lane.size() - 1):
		if not _segment_clear_light(space_state, query, lane[i], lane[i + 1]):
			if i + 1 < last_index:
				lane[i + 1] = points[i + 1]
			else:
				return PackedVector3Array()

	return lane


## Shortens a sideways offset so it stops lane_wall_margin short of any wall.
func _clamp_to_clearance(
	origin: Vector3,
	perpendicular: Vector3,
	desired: float,
	lift: Vector3,
	space_state: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D
) -> float:
	if absf(desired) < 0.01:
		return 0.0

	var side: float = signf(desired)
	var from_pos: Vector3 = origin + lift

	query.from = from_pos
	query.to = from_pos + perpendicular * side * (absf(desired) + lane_wall_margin)

	var hit: Dictionary = space_state.intersect_ray(query)

	if hit.is_empty():
		return desired

	var free: float = from_pos.distance_to(hit.position) - lane_wall_margin

	return side * clampf(free, 0.0, absf(desired))


## Cheaper version of _segment_clear: ground under the segment plus one centre ray.
func _segment_clear_light(
	space_state: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D,
	from_pt: Vector3,
	to_pt: Vector3
) -> bool:
	if not _segment_has_ground(from_pt, to_pt):
		return false

	var lift := Vector3(0.0, maxf(agent_radius * 0.5, 0.2), 0.0)

	return not _ray_blocked(space_state, query, from_pt + lift, to_pt + lift)


# ---------------------------------------------------------------------------
# Grid and navigation
# ---------------------------------------------------------------------------

func _is_walkable(cell: Vector3i) -> bool:
	return has_block(cell) and not has_block(cell + Vector3i.UP)


func _nav_point_position(cell: Vector3i) -> Vector3:
	return map_to_local(cell) + Vector3(0.0, cell_size.y * 0.5, 0.0)


## Registers how a MeshLibrary item is allowed to rotate. This is metadata-only;
## the future block generator can populate it automatically.
func set_directional_kind(item: int, kind: DirectionalKind) -> void:
	_directional_kinds[item] = kind
	if _mesher != null:
		_mesher.rebuild_all()


func get_directional_kind(item: int) -> int:
	return int(_directional_kinds.get(item, -1))


func get_orientation_basis(orientation: int) -> Basis:
	return get_basis_with_orthogonal_index(orientation)


func get_direction_for_orientation(
	kind: DirectionalKind,
	orientation: int
) -> Vector3i:
	var orientation_basis := get_basis_with_orthogonal_index(orientation)
	var axis: Vector3 = (
		Vector3.UP
		if kind == DirectionalKind.PILLAR
		else Vector3.FORWARD
	)
	var direction: Vector3 = orientation_basis * axis

	return Vector3i(
		roundi(direction.x),
		roundi(direction.y),
		roundi(direction.z)
	)


func get_block_direction(cell: Vector3i, kind: DirectionalKind) -> Vector3i:
	if not has_block(cell):
		return Vector3i.ZERO

	return get_direction_for_orientation(
		kind,
		get_cell_item_orientation(cell)
	)


## Converts a block-facing direction into the GridMap orientation index.
func get_orientation_for_direction(
	kind: DirectionalKind,
	direction: Vector3i
) -> int:
	var direction_vector := Vector3(direction)

	if direction_vector.length_squared() < 0.0001:
		direction_vector = Vector3.FORWARD
	else:
		direction_vector = direction_vector.normalized()

	match kind:
		DirectionalKind.CARDINAL:
			direction_vector.y = 0.0
			if direction_vector.length_squared() < 0.0001:
				direction_vector = Vector3.FORWARD
			direction_vector = direction_vector.normalized()
			return get_orthogonal_index_from_basis(
				Basis.looking_at(direction_vector, Vector3.UP)
			)

		DirectionalKind.FACING:
			var up := Vector3.UP
			if absf(direction_vector.dot(Vector3.UP)) > 0.99:
				up = Vector3.FORWARD
			return get_orthogonal_index_from_basis(
				Basis.looking_at(direction_vector, up)
			)

		DirectionalKind.PILLAR:
			return get_orthogonal_index_from_basis(
				_pillar_basis(direction_vector)
			)

	return 0


## Stairs face a horizontal direction. `front_axis` is the direction the
## stair mesh's low/front side points in its unrotated state.
func get_stair_orientation(
	direction: Vector3i,
	front_axis: Vector3 = Vector3.RIGHT
) -> int:
	var from := Vector3(front_axis)
	from.y = 0.0
	if from.length_squared() < 0.0001:
		from = Vector3.FORWARD
	else:
		from = from.normalized()

	var to := Vector3(direction)
	to.y = 0.0
	if to.length_squared() < 0.0001:
		to = Vector3.FORWARD
	else:
		to = to.normalized()

	var cross := from.cross(to)
	if cross.length_squared() < 0.0001:
		if from.dot(to) >= 0.0:
			return 0
		return get_orthogonal_index_from_basis(
			Basis(Vector3.UP, PI)
		)

	return get_orthogonal_index_from_basis(
		Basis(cross.normalized(), from.angle_to(to))
	)


func _pillar_basis(direction: Vector3) -> Basis:
	if absf(direction.dot(Vector3.UP)) > 0.999:
		if direction.y > 0.0:
			return Basis.IDENTITY
		return Basis(Vector3.RIGHT, PI)

	var axis := Vector3.UP.cross(direction).normalized()
	var angle := Vector3.UP.angle_to(direction)
	return Basis(axis, angle)


## Places a block and rotates it for the requested direction.
func place_directional_block(
	cell: Vector3i,
	item: int,
	kind: DirectionalKind,
	direction: Vector3i
) -> bool:
	return place_block(
		cell,
		item,
		get_orientation_for_direction(kind, direction)
	)


## Multitexture blocks use the same orientation field as directional blocks.
func place_multitexture_block(
	cell: Vector3i,
	item: int,
	orientation: int
) -> bool:
	return place_block(cell, item, orientation)


## Generates Auto_Stairs_<texture> items from each full Auto_<texture> block.
## The stair scene (or fallback MeshLibrary item) supplies geometry and collision.
func _generate_auto_stairs() -> void:
	if mesh_library == null:
		return

	var template := _auto_stair_template()
	if template.is_empty():
		return

	var template_mesh: Mesh = template["mesh"]
	var template_transform: Transform3D = template["transform"]
	var template_shapes: Array = template["shapes"]

	if template_mesh == null:
		return

	var item_ids: PackedInt32Array = mesh_library.get_item_list()
	var existing_ids: Dictionary = {}
	var next_stair_id: int = 0

	for id: int in item_ids:
		existing_ids[mesh_library.get_item_name(id)] = id
		next_stair_id = maxi(next_stair_id, id + 1)

	for id: int in item_ids:
		var source_name: String = mesh_library.get_item_name(id)

		if not source_name.begins_with("Auto_"):
			continue
		if "Slab" in source_name or "Stair" in source_name:
			continue

		var stair_name: String = auto_stair_prefix + source_name.trim_prefix("Auto_")
		var source_mesh: Mesh = mesh_library.get_item_mesh(id)
		if source_mesh == null or source_mesh.get_surface_count() == 0:
			continue

		var source_material: Material = source_mesh.surface_get_material(0)
		var source_preview: Texture2D = mesh_library.get_item_preview(id)
		var stair_id: int = -1

		if existing_ids.has(stair_name):
			stair_id = int(existing_ids[stair_name])
			if not auto_stair_replace_existing:
				_directional_kinds[stair_id] = DirectionalKind.CARDINAL
				continue
		else:
			stair_id = next_stair_id
			next_stair_id += 1
			mesh_library.create_item(stair_id)
			mesh_library.set_item_name(stair_id, stair_name)
			existing_ids[stair_name] = stair_id

		var stair_mesh: Mesh = template_mesh.duplicate()
		for surface_index in stair_mesh.get_surface_count():
			if source_material != null:
				stair_mesh.surface_set_material(surface_index, source_material)

		mesh_library.set_item_mesh(stair_id, stair_mesh)
		mesh_library.set_item_mesh_transform(stair_id, template_transform)

		if not template_shapes.is_empty():
			mesh_library.set_item_shapes(stair_id, template_shapes)

		if source_preview != null:
			mesh_library.set_item_preview(stair_id, source_preview)

		_directional_kinds[stair_id] = DirectionalKind.CARDINAL


## Returns the stair mesh, centered mesh transform, and collision shapes.
func _auto_stair_template() -> Dictionary:
	if auto_stair_scene != null:
		var instance: Node = auto_stair_scene.instantiate()
		var mesh_instance := _find_mesh_instance(instance)

		if mesh_instance != null and mesh_instance.mesh != null:
			var mesh: Mesh = mesh_instance.mesh
			var source_transform := mesh_instance.transform
			var source_aabb: AABB = source_transform * mesh.get_aabb()
			var fit_scale: float = minf(
				cell_size.x / maxf(source_aabb.size.x, 0.0001),
				minf(
					cell_size.y / maxf(source_aabb.size.y, 0.0001),
					cell_size.z / maxf(source_aabb.size.z, 0.0001)
				)
			)
			var fit_basis := Basis.IDENTITY.scaled(Vector3.ONE * fit_scale)
			var origin: Vector3 = -source_aabb.get_center() * fit_scale
			var fit_transform := Transform3D(fit_basis, origin) * source_transform
			var shapes: Array = []

			var faces: PackedVector3Array = mesh.get_faces()
			if faces.size() >= 3:
				var shape := ConcavePolygonShape3D.new()
				shape.set_faces(faces)
				shapes = [shape, fit_transform]

			if is_instance_valid(instance):
				instance.free()

			return {
				"mesh": mesh,
				"transform": fit_transform,
				"shapes": shapes,
			}

		if is_instance_valid(instance):
			instance.free()

	# Fallback: use an existing MeshLibrary stair item as the template.
	var template_mesh: Mesh = mesh_library.get_item_mesh(
		auto_stair_template_item
	)
	if template_mesh == null:
		return {}

	var template_transform: Transform3D = (
		mesh_library.get_item_mesh_transform(auto_stair_template_item)
	)
	var template_shapes: Array = mesh_library.get_item_shapes(
		auto_stair_template_item
	).duplicate()

	if template_shapes.is_empty():
		var faces: PackedVector3Array = template_mesh.get_faces()
		if faces.size() >= 3:
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(faces)
			template_shapes = [shape, template_transform]
			mesh_library.set_item_shapes(
				auto_stair_template_item,
				template_shapes
			)

	_directional_kinds[auto_stair_template_item] = DirectionalKind.CARDINAL

	return {
		"mesh": template_mesh,
		"transform": template_transform,
		"shapes": template_shapes,
	}


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node

	for child: Node in node.get_children():
		var found := _find_mesh_instance(child)
		if found != null:
			return found

	return null


func place_block(cell: Vector3i, item: int, orientation: int = 0) -> bool:
	if mesh_library == null:
		return false

	if not mesh_library.get_item_list().has(item):
		return false

	if (
		get_cell_item(cell) == item
		and get_cell_item_orientation(cell) == orientation
	):
		return false

	set_cell_item(cell, item, orientation)
	_track_cell(cell)
	mark_chunk_dirty(cell_to_chunk(cell))
	_refresh_nav_around(cell)
	block_placed.emit(cell, item)

	return true


func remove_block(cell: Vector3i) -> bool:
	if get_cell_item(cell) == GridMap.INVALID_CELL_ITEM:
		return false

	set_cell_item(cell, GridMap.INVALID_CELL_ITEM)
	_untrack_cell(cell)
	mark_chunk_dirty(cell_to_chunk(cell))
	_refresh_nav_around(cell)
	block_removed.emit(cell)

	return true


## Places `item` into every empty cell in `cells` with a single navigation
## refresh. Used by drag building so a 500-block selection does not rebuild
## the navigation graph 500 times.
func place_blocks(
	cells: Array[Vector3i],
	item: int,
	orientation: int = 0
) -> int:
	if mesh_library == null:
		return 0

	if not mesh_library.get_item_list().has(item):
		return 0

	var placed_cells: Array[Vector3i] = []

	for cell: Vector3i in cells:
		if has_block(cell):
			continue

		set_cell_item(cell, item, orientation)
		_track_cell(cell)
		placed_cells.append(cell)

	if placed_cells.is_empty():
		return 0

	_mark_chunks_dirty(placed_cells)
	var affected: Array[Vector3i] = _refresh_nav_region(placed_cells)

	for cell: Vector3i in placed_cells:
		block_placed.emit(cell, item)

	navigation_changed.emit(affected)
	return placed_cells.size()


## Removes every existing cell in `cells` with a single navigation refresh.
func remove_blocks(cells: Array[Vector3i]) -> int:
	var removed: Array[Vector3i] = []

	for cell: Vector3i in cells:
		if not has_block(cell):
			continue

		set_cell_item(cell, GridMap.INVALID_CELL_ITEM)
		_untrack_cell(cell)
		removed.append(cell)

	if removed.is_empty():
		return 0

	_mark_chunks_dirty(removed)
	var affected: Array[Vector3i] = _refresh_nav_region(removed)

	for cell: Vector3i in removed:
		block_removed.emit(cell)

	navigation_changed.emit(affected)
	return removed.size()


func _mark_chunks_dirty(cells: Array[Vector3i]) -> void:
	var seen: Dictionary = {}

	for cell: Vector3i in cells:
		var chunk: Vector2i = cell_to_chunk(cell)

		if seen.has(chunk):
			continue

		seen[chunk] = true
		mark_chunk_dirty(chunk)


func has_block(cell: Vector3i) -> bool:
	return get_cell_item(cell) != GridMap.INVALID_CELL_ITEM


func _refresh_point_weights_around(changed_cell: Vector3i) -> void:
	var affected: Array[Vector3i] = [changed_cell]

	for dir in WALL_CHECK_DIRS:
		affected.append(changed_cell - Vector3i.UP - dir)
		affected.append(changed_cell - dir)

	for cell: Vector3i in affected:
		var id: int = cell_to_id_map.get(cell, -1)

		if id != -1:
			astar.set_point_weight_scale(id, _point_weight_scale(cell))


func _refresh_nav_around(cell: Vector3i) -> void:
	var origin_cells: Array[Vector3i] = [cell]
	var affected: Array[Vector3i] = _expand_nav_affected(origin_cells)

	for affected_cell: Vector3i in affected:
		_refresh_nav_cell(affected_cell)

	# A changed cell can be a side-cell for a diagonal edge between two other
	# cells. Rebuild connections for the full local neighborhood to remove stale edges.
	_rebuild_nav_connections(affected)
	_refresh_point_weights_around(cell)
	_invalidate_flow_fields(affected)
	navigation_changed.emit(affected)


func _expand_nav_affected(cells: Array[Vector3i]) -> Array[Vector3i]:
	var expanded: Dictionary = {}

	for cell: Vector3i in cells:
		expanded[cell] = true
		expanded[cell + Vector3i.UP] = true
		expanded[cell + Vector3i.DOWN] = true
		for offset in NEIGHBOR_OFFSETS:
			expanded[cell + offset] = true
		# These cells can be endpoints of a diagonal edge for which `cell` is
		# one of the two orthogonal side-cells.
		expanded[cell + Vector3i.LEFT] = true
		expanded[cell + Vector3i.RIGHT] = true
		expanded[cell + Vector3i.FORWARD] = true
		expanded[cell + Vector3i.BACK] = true

	var result: Array[Vector3i] = []
	for cell: Vector3i in expanded:
		result.append(cell)
	return result


func _rebuild_nav_connections(cells: Array[Vector3i]) -> void:
	# Disconnect first so forbidden diagonal links cannot survive a block edit.
	for cell: Vector3i in cells:
		var point_id: int = cell_to_id_map.get(cell, -1)
		if point_id == -1:
			continue
		for connected_id in astar.get_point_connections(point_id):
			astar.disconnect_points(point_id, int(connected_id), true)

	for cell: Vector3i in cells:
		if cell_to_id_map.has(cell):
			_connect_cell_neighbors(cell)


func _refresh_nav_cell(cell: Vector3i) -> void:
	var walkable: bool = _is_walkable(cell)
	var registered: bool = cell_to_id_map.has(cell)

	if walkable and not registered:
		_add_nav_cell(cell)
	elif not walkable and registered:
		_remove_nav_cell(cell)


func _add_nav_cell(cell: Vector3i) -> void:
	var point_id: int = _get_next_id()
	cell_to_id_map[cell] = point_id
	_id_to_cell[point_id] = cell

	astar.add_point(
		point_id,
		_nav_point_position(cell),
		_point_weight_scale(cell)
	)
	_connect_cell_neighbors(cell)


func _remove_nav_cell(cell: Vector3i) -> void:
	var point_id: int = cell_to_id_map.get(cell, -1)

	if point_id == -1:
		return

	astar.remove_point(point_id)
	cell_to_id_map.erase(cell)
	_id_to_cell.erase(point_id)
	free_ids.append(point_id)


func _find_nav_id(local_pos: Vector3) -> int:
	var base_cell: Vector3i = local_to_map(local_pos)

	for dy: int in [0, -1, 1, -2]:
		var cell: Vector3i = base_cell + Vector3i(0, dy, 0)
		var id: int = cell_to_id_map.get(cell, -1)

		if id == -1:
			continue

		var point_position: Vector3 = astar.get_point_position(id)

		if point_position.distance_to(local_pos) <= closest_point_max_distance:
			return id

	var closest_id: int = astar.get_closest_point(local_pos)

	if closest_id == -1:
		return -1

	var closest_pos: Vector3 = astar.get_point_position(closest_id)

	if closest_pos.distance_to(local_pos) > closest_point_max_distance:
		return -1

	return closest_id


func world_to_cell(world_pos: Vector3) -> Vector3i:
	return local_to_map(to_local(world_pos))


func get_hit_cell(hit_position: Vector3, hit_normal: Vector3) -> Vector3i:
	var nudge: float = minf(
		cell_size.x,
		minf(cell_size.y, cell_size.z)
	) * 0.05

	return world_to_cell(hit_position - hit_normal * nudge)


func get_place_cell(hit_position: Vector3, hit_normal: Vector3) -> Vector3i:
	var hit_cell: Vector3i = get_hit_cell(hit_position, hit_normal)
	var grid_basis: Basis = global_transform.basis.orthonormalized()
	var local_normal: Vector3 = grid_basis.inverse() * hit_normal

	return hit_cell + Vector3i(local_normal.round())


## True if a world position sits over a walkable cell that isn't too exposed to a drop.
## max_gap_exposure is a fraction of sides: 0.34 allows at most 1 open side out of 4.
func is_path_position_safe(
	world_pos: Vector3,
	max_gap_exposure: float = 0.5
) -> bool:
	var base_cell: Vector3i = local_to_map(to_local(world_pos))

	# Path points sit on the top face of a block, which can round into the air cell
	# above it, so check that cell and the one below.
	for dy in [0, -1]:
		var cell: Vector3i = base_cell + Vector3i(0, dy, 0)

		if cell_to_id_map.has(cell):
			return _gap_exposure(cell) <= max_gap_exposure

	return false


# ---------------------------------------------------------------------------
# Chunk coordinates and tracking
# ---------------------------------------------------------------------------

static func cell_to_chunk(cell: Vector3i) -> Vector2i:
	return Vector2i(
		floori(float(cell.x) / float(CHUNK_SIZE)),
		floori(float(cell.z) / float(CHUNK_SIZE))
	)


static func chunk_origin(chunk: Vector2i) -> Vector2i:
	return chunk * CHUNK_SIZE


func position_to_chunk(world_pos: Vector3) -> Vector2i:
	return cell_to_chunk(world_to_cell(world_pos))


func _track_cell(cell: Vector3i) -> void:
	var chunk: Vector2i = cell_to_chunk(cell)

	if not _chunk_cells.has(chunk):
		_chunk_cells[chunk] = {}

	_chunk_cells[chunk][cell] = true


func _untrack_cell(cell: Vector3i) -> void:
	var chunk: Vector2i = cell_to_chunk(cell)

	if not _chunk_cells.has(chunk):
		return

	_chunk_cells[chunk].erase(cell)

	if _chunk_cells[chunk].is_empty():
		_chunk_cells.erase(chunk)


func mark_chunk_dirty(chunk: Vector2i) -> void:
	_dirty_chunks[chunk] = true


func mark_chunk_clean(chunk: Vector2i) -> void:
	_dirty_chunks.erase(chunk)


func is_chunk_dirty(chunk: Vector2i) -> bool:
	return _dirty_chunks.has(chunk)


func get_dirty_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []

	for chunk: Vector2i in _dirty_chunks:
		result.append(chunk)

	return result


func get_populated_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []

	for chunk: Vector2i in _chunk_cells:
		result.append(chunk)

	return result


func get_chunk_cell_count(chunk: Vector2i) -> int:
	return _chunk_cells.get(chunk, {}).size()


## The set of cells in a chunk (cell -> true). Treat it as read-only.
func get_chunk_cells(chunk: Vector2i) -> Dictionary:
	return _chunk_cells.get(chunk, {})


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

## Packs one chunk into a plain Dictionary. "cells" is a flat PackedInt32Array, 5 ints
## per block: [local_x, y, local_z, item, orientation, ...]. X and Z are relative to the
## chunk origin so the data doesn't depend on where the chunk sits in the world.
func serialize_chunk(chunk: Vector2i) -> Dictionary:
	var cells: Dictionary = _chunk_cells.get(chunk, {})
	var origin: Vector2i = chunk_origin(chunk)

	var packed: PackedInt32Array = PackedInt32Array()
	packed.resize(cells.size() * INTS_PER_BLOCK)

	var index: int = 0

	for key: Vector3i in cells:
		packed[index] = key.x - origin.x
		packed[index + 1] = key.y
		packed[index + 2] = key.z - origin.y
		packed[index + 3] = get_cell_item(key)
		packed[index + 4] = get_cell_item_orientation(key)
		index += INTS_PER_BLOCK

	return {
		"version": CHUNK_DATA_VERSION,
		"chunk_x": chunk.x,
		"chunk_z": chunk.y,
		"cells": packed,
	}


## Replaces everything in a chunk with the contents of `data` (from serialize_chunk),
## then rebuilds navigation for the area in one batch. Does not mark the chunk dirty.
## navigation_changed is not emitted unless emit_nav_signal is true: a full chunk is
## thousands of cells and every NPC loops over the whole list.
func load_chunk(data: Dictionary, emit_nav_signal: bool = false) -> void:
	if mesh_library == null:
		push_error("NavGridMap.load_chunk: no MeshLibrary assigned.")
		return

	if int(data.get("version", 0)) != CHUNK_DATA_VERSION:
		push_error("NavGridMap.load_chunk: unsupported chunk data version.")
		return

	var chunk := Vector2i(
		int(data.get("chunk_x", 0)),
		int(data.get("chunk_z", 0))
	)
	var origin: Vector2i = chunk_origin(chunk)

	var packed_value: Variant = data.get("cells", PackedInt32Array())

	if packed_value is not PackedInt32Array:
		push_error("NavGridMap.load_chunk: cells must be PackedInt32Array.")
		return

	var packed: PackedInt32Array = packed_value

	if packed.size() % INTS_PER_BLOCK != 0:
		push_error("NavGridMap.load_chunk: malformed cell data size.")
		return

	var valid_items: PackedInt32Array = mesh_library.get_item_list()
	var touched: Array[Vector3i] = _wipe_chunk(chunk)
	var skipped: int = 0

	for index in range(0, packed.size(), INTS_PER_BLOCK):
		var local_x: int = packed[index]
		var y: int = packed[index + 1]
		var local_z: int = packed[index + 2]
		var item: int = packed[index + 3]
		var orientation: int = packed[index + 4]

		var in_range: bool = (
			local_x >= 0
			and local_x < CHUNK_SIZE
			and local_z >= 0
			and local_z < CHUNK_SIZE
		)

		if not in_range or not valid_items.has(item):
			skipped += 1
			continue

		var cell := Vector3i(
			origin.x + local_x,
			y,
			origin.y + local_z
		)

		set_cell_item(cell, item, orientation)
		_track_cell(cell)
		touched.append(cell)

	if skipped > 0:
		push_warning(
			"NavGridMap.load_chunk: skipped %d invalid cell(s) in chunk %s."
			% [skipped, chunk]
		)

	var affected: Array[Vector3i] = _refresh_nav_region(touched)
	_dirty_chunks.erase(chunk)

	if emit_nav_signal and not affected.is_empty():
		navigation_changed.emit(affected)

	chunk_loaded.emit(chunk)


## Removes a chunk's blocks and navigation, e.g. when streaming it out.
## Does NOT save it first: if it is dirty, write it out before calling this.
func unload_chunk(chunk: Vector2i, emit_nav_signal: bool = false) -> void:
	if _dirty_chunks.has(chunk):
		push_warning(
			"NavGridMap.unload_chunk: refusing to unload dirty chunk %s; save it first."
			% chunk
		)
		return

	var removed: Array[Vector3i] = _wipe_chunk(chunk)
	var affected: Array[Vector3i] = _refresh_nav_region(removed)

	if emit_nav_signal and not affected.is_empty():
		navigation_changed.emit(affected)

	chunk_unloaded.emit(chunk)


## Saves every dirty chunk through `writer`, a Callable taking (chunk: Vector2i,
## data: Dictionary) and returning true on success. Only chunks the writer reports
## as saved are marked clean. Returns how many were saved.
func save_dirty_chunks(writer: Callable) -> int:
	var saved: int = 0

	for chunk: Vector2i in _dirty_chunks.keys():
		if writer.call(chunk, serialize_chunk(chunk)):
			_dirty_chunks.erase(chunk)
			saved += 1

	return saved


## Same, but for every populated chunk plus any chunk emptied by edits. Use for a full save.
func save_all_chunks(writer: Callable) -> int:
	var chunks_to_save: Dictionary = {}

	for chunk: Vector2i in _chunk_cells:
		chunks_to_save[chunk] = true

	for chunk: Vector2i in _dirty_chunks:
		chunks_to_save[chunk] = true

	var saved: int = 0

	for chunk: Vector2i in chunks_to_save:
		if writer.call(chunk, serialize_chunk(chunk)):
			_dirty_chunks.erase(chunk)
			saved += 1

	return saved


## Clears every block in a chunk from the GridMap and the index. Returns the cells
## that were removed so the caller can refresh navigation for them.
func _wipe_chunk(chunk: Vector2i) -> Array[Vector3i]:
	var removed: Array[Vector3i] = []
	var cells: Dictionary = _chunk_cells.get(chunk, {})

	for key: Vector3i in cells:
		removed.append(key)
		set_cell_item(key, GridMap.INVALID_CELL_ITEM)

	_chunk_cells.erase(chunk)

	return removed


## Batch version of _refresh_nav_around. Call it AFTER all the blocks are already set,
## so walkability and connection checks see the final state.
func _refresh_nav_region(cells: Array[Vector3i]) -> Array[Vector3i]:
	var result: Array[Vector3i] = _expand_nav_affected(cells)

	for cell: Vector3i in result:
		_refresh_nav_cell(cell)

	_rebuild_nav_connections(result)

	for cell: Vector3i in cells:
		_refresh_point_weights_around(cell)

	_invalidate_flow_fields(result)
	return result
