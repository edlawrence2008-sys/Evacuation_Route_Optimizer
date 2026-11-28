@tool
class_name NavGridMap
extends GridMap

signal block_placed(cell: Vector3i, item: int)
signal block_removed(cell: Vector3i)
signal navigation_changed(changed_cells: Array[Vector3i])
## One structural collapse event (not one per removed cell). The optimizer uses
## it as a route disruption and the recorder stores it as a summary event.
signal structure_collapsed(cells: Array[Vector3i], style: int)
signal chunk_loaded(chunk: Vector2i)
signal chunk_unloaded(chunk: Vector2i)
signal flow_field_baked(target_cell: Vector3i)
signal congestion_changed(affected_cells: Array[Vector3i])
## Emitted after every incremental navigation rebuild. `duration_usec` covers
## the A* cell refresh + connection rebuild, not the caller's mesh work.
signal nav_refresh_measured(duration_usec: int, changed_cells: int)

const CTM_BUILDER := preload("res://scripts/connected_texture_builder.gd")
const COLOR_PALETTE := preload("res://scripts/color_palette_db.gd")
const VoxelSectionStoreScript := preload("res://scripts/world/VoxelSectionStore.gd")
const STRUCTURAL_STABILITY := preload("res://scripts/world/structural_stability.gd")
const BLOCK_IDS = preload("res://scripts/world/block_ids.gd")
const FALLING_BLOCKS = preload("res://scripts/world/falling_blocks.gd")
const SUB_LEVEL_MANAGER = preload("res://scripts/world/sub_level_manager.gd")
const FOLIAGE_BATCHER = preload("res://scripts/world/foliage_batcher.gd")
const WORLD_FIRE = preload("res://scripts/world/world_fire.gd")
const ASH_SETTLER = preload("res://scripts/world/ash_settler.gd")

## Body radius used for navigation clearance checks. The spawned NPC body is a
## 0.25 m sphere; matching it here keeps path validation honest.
@export var agent_radius: float = 0.25
## Side clearance used by smoothed-path ground checks. Keep this near the NPC
## body radius so a shortcut cannot put half the body over a ledge.
@export var path_ground_radius: float = 0.3
@export var wall_penalty_max: float = 2.0
@export var gap_penalty_max: float = 3.0

@export_group("Social Force Walls")
## Wall repulsion strength A_w, newtons (Helbing & Molnar 1995 use ~2000).
@export var wall_repulsion_a: float = 2000.0
## Wall repulsion range B_w, metres.
@export var wall_repulsion_b: float = 0.08
## How far from the body centre walls are sampled, metres. Wall force is
## negligible beyond ~0.6 m with B_w = 0.08 m.
@export var wall_query_radius: float = 0.8
@export var wall_force_enabled: bool = true

@export_group("Navigation Costs")
## Multiplier for cells whose top block is a stair. Values below 1 make
## stair routes cheaper than walking/climbing over full blocks.
@export_range(0.1, 2.0, 0.01) var stair_path_cost: float = 0.75
## Multiplier for top/bottom slab cells, between stairs and full blocks.
@export_range(0.1, 2.0, 0.01) var slab_path_cost: float = 0.9
## Multiplier for full-block cells.
@export_range(0.1, 2.0, 0.01) var full_block_path_cost: float = 1.0
## Cost multiplier for cells painted as an authored evacuation corridor. Below
## 1 makes the painted route cheaper than the surrounding floor, so A* and the
## optimizer's cost fields prefer it. Paint via the Route Paint tool.
@export_range(0.1, 1.0, 0.01) var authored_route_cost_scale: float = 0.55
## Cells painted by the Route Paint tool. Not serialized in the GridMap; the
## RoutePainter autoload persists them per save and re-applies on load.
var authored_route_cells: Dictionary = {}

@export var enable_greedy_meshing: bool = true
## Hard vertical bounds for loaded and placed blocks.
@export var min_block_y: int = -256
@export var max_block_y: int = 255

## Structural settings, mirrored from PerformanceSettings.apply_all().
## `stability_enabled` computes the support field; `collapse_enabled` decides
## whether unsupported cells collapse at all; `collapse_style` picks how.
@export var stability_enabled: bool = true
@export var collapse_enabled: bool = false
@export var collapse_style: int = 1
## When on, a settled sub-level that lines up with the world docks back into the
## normal chunk grid. Off by default so sub-levels stay editable.
@export var auto_dock_sublevels: bool = false
## Sub-level rules. Stability uses the body's local grid with its lowest layer
## as the foundation; contact damage and fire are opt-in.
@export var sublevel_stability_enabled: bool = false
@export var sublevel_contact_damage_enabled: bool = false
@export var sublevel_contact_damage_scale: float = 0.05
@export var sublevel_collision_destruction_enabled: bool = false
@export var sublevel_collision_destruction_radius: float = 1.5
@export var sublevel_fire_enabled: bool = true
@export var stability_debug: bool = false:
	set(value):
		stability_debug = value
		_stability_overlay_dirty = true
## Copy the live PerformanceSettings on _ready. Fixture grids in tests set this
## false before adding the node so the developer's saved settings do not leak
## into the assertion world.
@export var sync_settings_on_ready: bool = true

const COLLAPSE_REMOVE: int = 0
const COLLAPSE_FALL: int = 1
const COLLAPSE_RIGID: int = 2
const COLLAPSE_SUBLEVEL: int = 3

@export var debug_greedy_colors: bool = false:
	set(value):
		debug_greedy_colors = value
		if _mesher != null:
			_mesher.set_debug_colors(value)

## Baked voxel-corner ambient occlusion. Disables greedy face merging while
## enabled so every face gets correct per-corner shading. Toggle live with /ao.
## Defaults off for the Medium preset; High turns it on.
@export var baked_ao_enabled: bool = false:
	set(value):
		baked_ao_enabled = value
		if _mesher != null:
			_mesher.set_baked_ao(value)

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

@export_group("Editor Tools")
## Reload the editor's saved-chunk world, discarding unsaved preview state.
@export_tool_button("Reload Editor World", "Reload")
var reload_editor_world_action: Callable = reload_editor_world
## Flush the editable editor preview's changed chunks to user://world/chunks.
@export_tool_button("Save Editor World", "Save")
var save_editor_world_action: Callable = save_editor_world

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

@export_group("Congestion Routing")
## Raise A* cost around cells where agents repeatedly fail to make progress.
@export var enable_congestion_routing: bool = true
## Extra path weight applied to a fully heated cell (1.0 heat).
@export var congestion_penalty_max: float = 2.0
## Heat added by one stuck report. Heat is clamped to 1.0.
@export var congestion_heat_per_report: float = 0.5
## How much heat is lost per second once nobody reports the cell again.
@export var congestion_decay_per_sec: float = 0.35
## Horizontal cell radius that receives heat from a reported deadlock.
@export var congestion_spread_radius: int = 1
## How often heat decays and congestion weights refresh.
@export var congestion_tick_interval: float = 0.5
## Safety cap on tracked hot cells, so a pathological crowd cannot grow forever.
@export var congestion_max_cells: int = 512

## How a placed block's mesh is allowed to rotate.
enum DirectionalKind {
	CARDINAL, ## Four horizontal directions.
	FACING,   ## Four horizontal directions plus up/down.
	PILLAR,   ## Three axes, like a log.
}

var _directional_kinds: Dictionary = {} # item id -> DirectionalKind
## Connected-texture item id -> runtime atlas material. Shared by the full
## block and its slab/stair variants so they sample one atlas.
var _ctm_materials: Dictionary = {}
## Connected-texture item id -> source base name (e.g. "concrete_polished").
## Shape variants map back to the same base, which is what the mesher compares
## when building per-face neighbour masks.
var _ctm_bases: Dictionary = {}

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

## Vertical tolerance, in cell heights, for "there is ground here". It must
## cover one full step: an agent origin sits 0.25 m below the floor surface and
## a one-block step raises the navigation point by 1 m, so the difference from
## the origin is 1.25 m. 1.35 leaves a small margin while still rejecting a
## two-block face. The smaller side tolerance used for ledge checks is separate.
const GROUND_HEIGHT_TOLERANCE: float = 1.35

## Chunks are CHUNK_SIZE x CHUNK_SIZE columns in X/Z. Storage is split into
## 16 x 16 x 16 sections inside each column, so a one-storey floor costs one
## section and a ten-storey building costs ten. See VoxelSectionStore.
const CHUNK_SIZE: int = 16
## v1 = flat 5-int cells, v2 = compressed 3D sections. v1 is still loadable.
const CHUNK_DATA_VERSION: int = 2
const LEGACY_CHUNK_DATA_VERSION: int = 1
const INTS_PER_BLOCK: int = 5
const NO_CHUNK_FLOOR: int = -2147483647

var astar: AStar3D = AStar3D.new()
var cell_to_id_map: Dictionary = {}
var _id_to_cell: Dictionary = {} # astar point id -> cell
var free_ids: Array[int] = []
var next_id: int = 1

# --- Measurement counters -------------------------------------------------
## Duration of the most recent incremental navigation refresh.
var last_nav_refresh_usec: int = 0
var last_nav_refresh_cells: int = 0
var nav_refresh_total_usec: int = 0
var nav_refresh_count: int = 0
## Duration of queued A* path requests (sum and last).
var last_path_request_usec: int = 0
var path_request_total_usec: int = 0
var path_request_count: int = 0

## Packed sparse 3D section storage. Replaces the old per-cell
## Dictionary[chunk][Vector3i] index: cost follows content, not build height.
var _sections = VoxelSectionStoreScript.new()

## Structural support evaluation. Computed on demand from the cells; nothing is
## serialized, so the save format stays unchanged.
var _structural = null
## Moving editable block structures (Sable-style sub-levels).
var _sublevel_manager = null
## True while the collapse loop is removing cells, so the removal hook does not
## re-enter and recurse.
var _structural_busy: bool = false
## Guards the ash-only settle pass while it rewrites blocks.
var _ash_settling: bool = false
## Debug overlay.
var _stability_overlay: MultiMeshInstance3D = null
var _stability_overlay_accum: float = 0.0
var _stability_overlay_dirty: bool = true
var _stability_overlay_center: Vector2i = Vector2i(2147483647, 2147483647)
var _debris_bodies: Array[Node3D] = []
const STABILITY_OVERLAY_INTERVAL: float = 0.25
const STABILITY_OVERLAY_MAX_INSTANCES: int = 2000
const STABILITY_OVERLAY_CHUNK_RADIUS: int = 1
const STABILITY_OVERLAY_DRAW_RADIUS: float = 16.0
const MAX_COLLAPSE_PASSES: int = 32
const MAX_DEBRIS_BODIES: int = 6
const MAX_DEBRIS_CELLS: int = 512
const DEBRIS_LIFETIME: float = 6.0
const FALL_DURATION: float = 0.45
const MAX_FALL_VISUALS: int = 512
## True when GridMap keeps its own cells for collision (chunk meshing off).
## When the mesher owns collision, the runtime mirror is dropped entirely.
var _grid_mirror_enabled: bool = true
## chunk -> lowest occupied Y. Maintained incrementally so the NPC fall check
## does not scan a whole chunk every frame.
var _chunk_min_y: Dictionary = {}

## chunk -> true when its cells are present in the AStar graph.
var _nav_chunks: Dictionary = {}

## chunk -> true
var _dirty_chunks: Dictionary = {}

var _mesher: ChunkMesher = null
var _water_system: WaterSystem = null
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

## target_cell -> { cell: cost } from the same bake. Used for exit-choice
## route lengths (metres, including congestion weights at bake time).
var _flow_costs: Dictionary = {}

## Quantised world position -> wall repulsion force (newtons). Cached between
## navigation changes because 600 agents share far fewer cells than positions.
var _wall_force_cache: Dictionary = {}
## 0.2 m buckets: fine enough to follow the exponential force profile.
const WALL_CACHE_QUANTISATION: float = 5.0
## Sized above the walkable area of a typical map at 0.2 m buckets so the cache
## does not churn through a full clear every few seconds at 600 agents.
const WALL_FORCE_CACHE_LIMIT: int = 65536

## target_cell -> FlowBakeJob (fields still being baked across frames)
var _bake_jobs: Dictionary = {}

## Real length of each NEIGHBOR_OFFSETS step, so flow-field costs match A* distances.
var _step_lengths: Array[float] = []
## Item-id caches for navigation surface height and traversal cost.
var _surface_low_by_item: Dictionary = {}
var _surface_cost_kind_by_item: Dictionary = {}
## Lazily filled block-item cache for one chunk navigation build. Wall/gap
## penalties query ~24 neighbours per cell; without this each query goes through
## the packed section store.
var _nav_snapshot_active: bool = false
var _nav_snapshot_items: Dictionary = {}

## Recent deadlock heat per nav cell (0..1). Hot cells cost more to enter, so
## later A* requests and flow bakes route around a jam instead of feeding it.
var _congestion_heat: Dictionary = {}
## Cells whose congestion weight changed since the last signal emission.
var _congestion_dirty: Dictionary = {}
var _congestion_accum: float = 0.0
## Cells whose A* weight still needs updating. A synchronized jam can heat
## hundreds of cells in one frame; applying every weight immediately caused
## 4-6 ms spikes. They are flushed in small batches instead.
var _congestion_weight_pending: Dictionary = {}
var _congestion_weight_accum: float = 0.0
const CONGESTION_WEIGHT_FLUSH_INTERVAL: float = 0.1
const CONGESTION_WEIGHT_FLUSH_BUDGET: int = 64

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


## Pulls the live PerformanceSettings on startup. `apply_all()` can run before
## the grid exists (direct scene launch, or a settings change before the map
## loads), so relying on it alone leaves the grid at its inspector defaults and
## collapse silently never runs.
func _sync_structural_settings() -> void:
	var settings := get_node_or_null("/root/PerformanceSettings")
	if settings == null:
		return

	if "stability_enabled" in settings:
		stability_enabled = bool(settings.stability_enabled)
	if "collapse_enabled" in settings:
		collapse_enabled = bool(settings.collapse_enabled)
	if "collapse_style" in settings:
		collapse_style = int(settings.collapse_style)
	if "auto_dock_sublevels" in settings:
		auto_dock_sublevels = bool(settings.auto_dock_sublevels)
	if "sublevel_stability" in settings:
		sublevel_stability_enabled = bool(settings.sublevel_stability)
	if "sublevel_contact_damage" in settings:
		sublevel_contact_damage_enabled = bool(
			settings.sublevel_contact_damage
		)
	if "sublevel_contact_damage_scale" in settings:
		sublevel_contact_damage_scale = float(
			settings.sublevel_contact_damage_scale
		)
	if "sublevel_collision_destruction" in settings:
		sublevel_collision_destruction_enabled = bool(
			settings.sublevel_collision_destruction
		)
	if "sublevel_collision_destruction_radius" in settings:
		sublevel_collision_destruction_radius = float(
			settings.sublevel_collision_destruction_radius
		)
	if "sublevel_fire" in settings:
		sublevel_fire_enabled = bool(settings.sublevel_fire)
	if "stability_debug" in settings:
		stability_debug = bool(settings.stability_debug)


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	add_to_group("grid_map")
	if sync_settings_on_ready:
		_sync_structural_settings()

	# Any navigation change can move or remove a wall, so the cached wall force
	# is only valid until the next change.
	if not navigation_changed.is_connected(_on_navigation_changed_clear_wall_cache):
		navigation_changed.connect(_on_navigation_changed_clear_wall_cache)

	if auto_generate_stairs:
		_generate_auto_stairs()

	# The mesher provides per-chunk trimesh collision, so GridMap's duplicate
	# cell grid can be dropped. Without the mesher (disabled, or no MeshLibrary
	# to build from), GridMap stays authoritative for collision.
	_grid_mirror_enabled = not enable_greedy_meshing or mesh_library == null

	initialize_navigation()
	_build_ctm_items()
	_ensure_water_system()

	if enable_greedy_meshing:
		_mesher = ChunkMesher.new(self)
		_mesher.debug_colors = debug_greedy_colors
		_mesher.baked_ao_enabled = baked_ao_enabled
		_mesher.start()

	# Large generated worlds can contain thousands of crossed-card foliage
	# placeables. Their editable nodes stay; only their Sprite3D cards are
	# replaced by per-chunk MultiMeshes.
	if get_tree().get_first_node_in_group("foliage_batcher") == null:
		var batcher := FOLIAGE_BATCHER.new()
		batcher.name = "FoliageBatcher"
		batcher.add_to_group("foliage_batcher")
		add_child(batcher)

	if get_tree().get_first_node_in_group("world_fire") == null:
		var world_fire := WORLD_FIRE.new()
		world_fire.name = "WorldFire"
		add_child(world_fire)
		world_fire.setup(self)

	if debug_show_paths:
		_ensure_debug_mesh()


func _exit_tree() -> void:
	if _mesher != null:
		_mesher.stop()

	if is_instance_valid(_debug_mesh_instance):
		_debug_mesh_instance.queue_free()
		_debug_mesh_instance = null


func _on_navigation_changed_clear_wall_cache(
	_affected: Array[Vector3i]
) -> void:
	_wall_force_cache.clear()


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
	_sections.clear()
	_chunk_min_y.clear()
	_nav_chunks.clear()
	_dirty_chunks.clear()
	_flow_fields.clear()
	_flow_costs.clear()
	_bake_jobs.clear()
	_wall_force_cache.clear()
	_congestion_weight_pending.clear()
	_congestion_weight_accum = 0.0
	_rebuild_surface_profiles()
	_build_step_lengths()

	# The packed store is the runtime source of truth. On the first run the
	# scene's GridMap cells are copied into it; after that the grid is only a
	# coordinate/mesh-library host and is cleared so collision can be owned by
	# the chunk meshes instead of a duplicate cell grid.
	var used_cells: Array[Vector3i]

	if _sections.cell_count() == 0:
		used_cells = _seed_sections_from_gridmap()
	else:
		used_cells = get_used_block_cells()

	if not _grid_mirror_enabled:
		clear()

	for chunk: Vector2i in _sections.get_column_chunks():
		var lowest: int = _sections.get_column_min_y(chunk)
		_chunk_min_y[chunk] = (
			lowest
			if lowest != VoxelSectionStoreScript.NO_HEIGHT
			else NO_CHUNK_FLOOR
		)

	for cell in used_cells:
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

	for chunk: Vector2i in _sections.get_column_chunks():
		_nav_chunks[chunk] = true


## Copies the scene's authored GridMap cells into the packed store. Only the
## first initialize_navigation() call needs this; afterwards the store is the
## source of truth and the grid is empty at runtime.
##
## Authored worlds (the shipped starter platform) predate the generator's
## bedrock layer, so a bedrock anchor is added under each authored column here.
## This keeps the starter map buildable when collapse is enabled without
## editing every map scene.
func _seed_sections_from_gridmap() -> Array[Vector3i]:
	var cells: Array[Vector3i] = get_used_cells()
	var lowest_by_column: Dictionary = {}

	for cell in cells:
		var item: int = get_cell_item(cell)

		if item < 0:
			continue

		_sections.set_cell(cell, item, get_cell_item_orientation(cell))
		var column := Vector2i(cell.x, cell.z)
		lowest_by_column[column] = mini(
			int(lowest_by_column.get(column, cell.y)),
			cell.y
		)

	_anchor_authored_columns(lowest_by_column)
	return cells


func _anchor_authored_columns(lowest_by_column: Dictionary) -> void:
	var bedrock: int = BLOCK_IDS.id_for_name_in("bedrock", mesh_library)
	if bedrock < 0:
		return

	for column: Vector2i in lowest_by_column:
		var y: int = int(lowest_by_column[column]) - 1
		if y < min_block_y or y > max_block_y:
			continue
		var cell := Vector3i(column.x, y, column.y)
		if _sections.has_cell(cell):
			continue
		_sections.set_cell(cell, bedrock, 0)


## Drops every stored cell and rebuilds an empty navigation graph. Used when a
## save is replaced by a generated world, so the scene's starter cells do not
## survive into the new world.
func reset_world() -> void:
	_sections.clear()
	_chunk_min_y.clear()
	_dirty_chunks.clear()
	_nav_chunks.clear()

	if _grid_mirror_enabled:
		clear()

	initialize_navigation()

	if _mesher != null:
		_mesher.stop()
		_mesher.start()


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
		if not _nav_has_block(cell + Vector3i.UP + dir):
			open_count += 1

	var openness: float = float(open_count) / float(WALL_CHECK_DIRS.size())
	return lerpf(wall_penalty_max, 1.0, openness)


func _gap_penalty_scale(cell: Vector3i) -> float:
	return lerpf(1.0, gap_penalty_max, _gap_exposure(cell))


func _point_weight_scale(cell: Vector3i) -> float:
	var wall_scale: float = _wall_penalty_scale(cell)
	var gap_scale: float = _gap_penalty_scale(cell)
	var route_scale: float = (
		authored_route_cost_scale if authored_route_cells.has(cell) else 1.0
	)

	return maxf(wall_scale, gap_scale) * _surface_weight_scale(cell) * route_scale


## Rebuilds the per-item surface profiles used for nav-point heights and path
## costs. Called after initialization and whenever the library is rescanned.
func _rebuild_surface_profiles() -> void:
	_surface_low_by_item.clear()
	_surface_cost_kind_by_item.clear()

	if mesh_library == null:
		return

	for id: int in mesh_library.get_item_list():
		var lower := String(mesh_library.get_item_name(id)).to_lower()
		var low_surface := false
		var cost_kind: int = 0 # 0 = full block, 1 = slab, 2 = stair

		if "stair" in lower:
			cost_kind = 2
			# An upside-down stair is full height at its centre; a normal
			# stair's low front step is the useful path height.
			low_surface = not ("upsidedown" in lower)
		elif "slab_side" in lower:
			# Vertical slabs are full-height panels, not walkable half-steps.
			cost_kind = 0
		elif "slab_bottom" in lower:
			cost_kind = 1
			low_surface = true
		elif "slab" in lower:
			cost_kind = 1

		_surface_low_by_item[id] = low_surface
		_surface_cost_kind_by_item[id] = cost_kind


## Item read used by navigation hot paths. During a chunk build, neighbours are
## memoized so the 24 wall/gap probes per cell become dictionary reads.
func _nav_block_item(cell: Vector3i) -> int:
	if _nav_snapshot_active:
		var cached: Variant = _nav_snapshot_items.get(cell)

		if cached != null:
			return int(cached)

		var item: int = _sections.get_cell_item(cell)
		_nav_snapshot_items[cell] = item
		return item

	return _sections.get_cell_item(cell)


func _nav_has_block(cell: Vector3i) -> bool:
	return _nav_block_item(cell) != GridMap.INVALID_CELL_ITEM


func _nav_snapshot_begin() -> void:
	_nav_snapshot_items.clear()
	_nav_snapshot_active = true


func _nav_snapshot_end() -> void:
	_nav_snapshot_active = false
	_nav_snapshot_items.clear()


func _surface_is_low(cell: Vector3i) -> bool:
	return bool(_surface_low_by_item.get(_nav_block_item(cell), false))


func _surface_weight_scale(cell: Vector3i) -> float:
	var kind: int = int(
		_surface_cost_kind_by_item.get(_nav_block_item(cell), 0)
	)

	match kind:
		2:
			return stair_path_cost
		1:
			return slab_path_cost
		_:
			return full_block_path_cost


# ---------------------------------------------------------------------------
# Congestion routing
# ---------------------------------------------------------------------------

## Records a cell as locally jammed. Repeated reports build heat; hot cells cost
## more to enter, so later A* requests and flow bakes prefer going around them.
func report_congestion(world_pos: Vector3, amount: float = 1.0) -> void:
	if not enable_congestion_routing or amount <= 0.0:
		return

	var cell: Vector3i = _resolve_nav_cell(world_pos)

	if cell == NO_CELL:
		return

	_heat_cell(cell, amount)

	var radius: int = maxi(0, congestion_spread_radius)

	for dx: int in range(-radius, radius + 1):
		for dz: int in range(-radius, radius + 1):
			if dx == 0 and dz == 0:
				continue

			var neighbour: Vector3i = cell + Vector3i(dx, 0, dz)
			var stair_scale: float = (
				0.45 if absi(dx) + absi(dz) == 1 else 0.2
			)

			# A neighbour can sit one stair step above or below the reported cell.
			for dy: int in [0, -1, 1, -2]:
				var candidate: Vector3i = neighbour + Vector3i(0, dy, 0)

				if cell_to_id_map.has(candidate):
					_heat_cell(candidate, amount * stair_scale)
					break


func _heat_cell(cell: Vector3i, amount: float) -> void:
	if not cell_to_id_map.has(cell):
		return

	var current: float = float(_congestion_heat.get(cell, 0.0))

	if current <= 0.0 and _congestion_heat.size() >= congestion_max_cells:
		var keys: Array = _congestion_heat.keys()

		if not keys.is_empty():
			var oldest: Vector3i = keys[0]
			_congestion_heat.erase(oldest)
			_congestion_weight_pending[oldest] = true
			_congestion_dirty[oldest] = true

	var next_heat: float = minf(1.0, current + amount)
	_congestion_heat[cell] = next_heat
	_congestion_weight_pending[cell] = true
	_congestion_dirty[cell] = true


func _apply_nav_point_weight(cell: Vector3i, heat: float = -1.0) -> void:
	var id: int = cell_to_id_map.get(cell, -1)

	if id == -1:
		return

	if heat < 0.0:
		heat = float(_congestion_heat.get(cell, 0.0))

	var multiplier: float = 1.0

	if enable_congestion_routing:
		multiplier = 1.0 + heat * congestion_penalty_max

	astar.set_point_weight_scale(id, _point_weight_scale(cell) * multiplier)


## Heat at a world position, using the same closest-cell lookup as pathing.
func get_congestion_heat(world_pos: Vector3) -> float:
	if not enable_congestion_routing or _congestion_heat.is_empty():
		return 0.0

	return get_congestion_heat_at_cell(_resolve_nav_cell(world_pos))


func get_congestion_heat_at_cell(cell: Vector3i) -> float:
	if cell == NO_CELL:
		return 0.0

	return float(_congestion_heat.get(cell, 0.0))


## Read-only congestion heat keyed by navigation cell. Used by the statistics
## map renderer; callers must not mutate it.
func get_congestion_heat_map() -> Dictionary:
	return _congestion_heat


func is_congested(world_pos: Vector3, threshold: float = 0.35) -> bool:
	return get_congestion_heat(world_pos) >= threshold


func clear_congestion() -> void:
	for cell: Vector3i in _congestion_heat.keys():
		_apply_nav_point_weight(cell, 0.0)
		_congestion_dirty[cell] = true

	_congestion_heat.clear()
	_congestion_weight_pending.clear()
	_congestion_weight_accum = 0.0


## Applies queued congestion weights in bounded batches. Keeping this separate
## from heat updates means a crowd-wide jam cannot monopolise one frame while
## still letting A* see the heat almost immediately (64 cells per 0.1 s).
func _flush_congestion_weights(delta: float) -> void:
	if _congestion_weight_pending.is_empty():
		return

	_congestion_weight_accum += delta

	if _congestion_weight_accum < CONGESTION_WEIGHT_FLUSH_INTERVAL:
		return

	_congestion_weight_accum = 0.0
	var keys: Array = _congestion_weight_pending.keys()
	var budget: int = mini(keys.size(), CONGESTION_WEIGHT_FLUSH_BUDGET)

	for index: int in range(budget):
		var cell: Vector3i = keys[index]
		_congestion_weight_pending.erase(cell)
		_apply_nav_point_weight(cell)


func _advance_congestion(delta: float) -> void:
	if not enable_congestion_routing or _congestion_heat.is_empty():
		return

	_congestion_accum += delta

	if _congestion_accum < congestion_tick_interval:
		return

	var elapsed: float = _congestion_accum
	_congestion_accum = 0.0
	var decay: float = clampf(
		1.0 - congestion_decay_per_sec * elapsed,
		0.0,
		1.0
	)
	var expired: Array[Vector3i] = []

	for cell: Vector3i in _congestion_heat.keys():
		var heat: float = float(_congestion_heat[cell]) * decay

		if heat < 0.02:
			expired.append(cell)
			continue

		if absf(heat - float(_congestion_heat[cell])) > 0.005:
			_congestion_heat[cell] = heat
			_congestion_weight_pending[cell] = true
			_congestion_dirty[cell] = true

	for cell: Vector3i in expired:
		_congestion_heat.erase(cell)
		_congestion_weight_pending[cell] = true
		_congestion_dirty[cell] = true

	if _congestion_dirty.is_empty():
		return

	var affected: Array[Vector3i] = []
	affected.assign(_congestion_dirty.keys())
	_congestion_dirty.clear()
	congestion_changed.emit(affected)


## Fraction (0..1) of a cell's 4 sides that are open air: no wall at body height
## and no floor beside it. 0 = fully supported, 1 = a lone pillar.
func _gap_exposure(cell: Vector3i) -> float:
	var exposed_count: int = 0

	for dir in WALL_CHECK_DIRS:
		var has_wall: bool = _nav_has_block(cell + Vector3i.UP + dir)
		var has_floor: bool = _nav_has_block(cell + dir)

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


## Route length in metres from a world position to a destination, taken from
## the baked flow-field costs. Returns -1 when no field exists yet, so callers
## can fall back without paying for an A* query per exit per agent.
func get_path_distance(from_world: Vector3, to_world: Vector3) -> float:
	var target_cell: Vector3i = _resolve_nav_cell(to_world)

	if target_cell == NO_CELL:
		return -1.0

	var costs: Variant = _flow_costs.get(target_cell)

	if costs == null:
		return -1.0

	var from_cell: Vector3i = _resolve_nav_cell(from_world)

	if from_cell == NO_CELL:
		return -1.0

	if not costs.has(from_cell):
		return -1.0

	return float(costs[from_cell])


## Repulsive force from nearby walls, newtons. Sampled in eight directions out
## to wall_query_radius against the voxel grid, then converted to acceleration
## by the caller's mass. A single block with nothing above it is a climbable
## step (the nav grid links it and the kinematic probe climbs it), so it does
## not contribute force; stacked blocks do. The result is cached per quantised
## position so the per-tick cost for a crowd is a Dictionary lookup.
func get_wall_acceleration(
	world_pos: Vector3,
	agent_radius_value: float,
	mass: float
) -> Vector3:
	if not wall_force_enabled or mass <= 0.0:
		return Vector3.ZERO

	# Body radius is part of the key: the sampled force depends on it, so two
	# agents with different radii must not share an entry.
	var key := Vector4i(
		roundi(world_pos.x * WALL_CACHE_QUANTISATION),
		roundi(world_pos.y * WALL_CACHE_QUANTISATION),
		roundi(world_pos.z * WALL_CACHE_QUANTISATION),
		roundi(agent_radius_value * 1000.0)
	)

	var force: Variant = _wall_force_cache.get(key)

	if force == null:
		force = _compute_wall_force(world_pos, agent_radius_value)

		# Positions keep changing as agents walk, so an unbounded cache would
		# grow for the whole run. Dropping it only costs the next recompute.
		if _wall_force_cache.size() >= WALL_FORCE_CACHE_LIMIT:
			_wall_force_cache.clear()

		_wall_force_cache[key] = force

	return (force as Vector3) / mass


func _compute_wall_force(
	world_pos: Vector3,
	agent_radius_value: float
) -> Vector3:
	var force: Vector3 = Vector3.ZERO
	var reach: float = maxf(wall_query_radius, agent_radius_value + 0.15)
	var step: float = 0.2
	var exponent_cap: float = 8.0

	for index in range(8):
		var angle: float = TAU * float(index) / 8.0
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var distance: float = maxf(0.05, agent_radius_value * 0.5)

		while distance <= reach:
			var sample: Vector3 = world_pos + direction * distance
			var cell: Vector3i = world_to_cell(sample)

			# A single block with nothing above it is a one-block step, which
			# the navigation graph treats as walkable and the kinematic probe
			# climbs. Repelling it would stop agents ~0.4 m short of a step they
			# are supposed to take, so keep scanning past it. Two or more blocks
			# stacked (or a block directly above the sample height) is a wall.
			var solid_at_sample: bool = has_block(cell)
			var solid_above: bool = has_block(cell + Vector3i.UP)

			if solid_above:
				# Psychological wall repulsion: A_w exp((r - d_w) / B_w).
				var exponent: float = (
					(agent_radius_value - distance)
					/ maxf(wall_repulsion_b, 1e-4)
				)
				var magnitude: float = (
					wall_repulsion_a
					* exp(clampf(exponent, -20.0, exponent_cap))
				)
				force -= direction * magnitude
				break

			if solid_at_sample:
				distance += step
				continue

			distance += step

	return force


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
	_flow_costs[job.target] = job.costs
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
		_flow_costs.erase(oldest_key)


func _invalidate_flow_fields(affected_cells: Array[Vector3i]) -> void:
	# Wall force depends on block layout, so drop it even when no flow fields
	# exist yet.
	_wall_force_cache.clear()

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
		_flow_costs.erase(target_cell)

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

func reload_editor_world() -> void:
	if not Engine.is_editor_hint():
		return

	var streamer := _get_editor_streamer()
	if streamer != null:
		streamer.call("_setup_editor_preview")


func save_editor_world() -> void:
	if not Engine.is_editor_hint():
		return

	var streamer := _get_editor_streamer()
	if streamer != null:
		streamer.call("_save_editor_preview_changes", true)


func _get_editor_streamer() -> Node:
	var tree := get_tree()
	if tree == null:
		return null

	var scene: Node = null
	if tree.edited_scene_root != null:
		scene = tree.edited_scene_root
	else:
		scene = tree.current_scene

	if scene == null:
		return null

	for node: Node in scene.find_children("*", "", true, false):
		var script: Script = node.get_script()
		if (
			script != null
			and script.resource_path.ends_with("ChunkStreamer.gd")
		):
			return node

	return null


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if _mesher != null:
		_mesher.process()

	_update_debug_paths(_delta)
	_update_stability_overlay(_delta)
	_advance_bake_jobs()
	_flush_congestion_weights(_delta)
	_advance_congestion(_delta)

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

		var path_start_usec: int = Time.get_ticks_usec()
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

		last_path_request_usec = Time.get_ticks_usec() - path_start_usec
		path_request_total_usec += last_path_request_usec
		path_request_count += 1
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


## Read-only, synchronous cost field to a destination, for the evacuation
## optimizer (docs/OPTIMIZER.md). One bake gives every cohort its distance to
## this exit, instead of one A* query per cohort per exit.
##
## Step cost is real distance times the weight of the cell being entered, which
## is what AStar3D and the flow-field bake use, so the optimizer and the agents
## agree about walls, gaps and surface classes. This does NOT touch the flow
## field cache, returns even when `enable_flow_fields` is false, and is not
## capped by `flow_field_max_cells` unless a positive `cell_limit` is passed.
##
## Returns { Vector3i: float } in weighted metres, or {} when the target is not
## a navigation cell. The caller owns the dictionary and should cache it for the
## duration of one optimization. Keep it off the physics tick: a full-map bake
## costs one pass over the nav graph.
func build_cost_field_to(target_world: Vector3, cell_limit: int = 0) -> Dictionary:
	var target_cell: Vector3i = _resolve_nav_cell(target_world)

	if target_cell == NO_CELL:
		return {}

	if _step_lengths.size() != NEIGHBOR_OFFSETS.size():
		_build_step_lengths()

	var costs: Dictionary = {target_cell: 0.0}
	var queue: Array[Vector3i] = [target_cell]
	var head: int = 0

	# Label-correcting flood, the same scheme as _step_bake_job but without a
	# frame budget. Re-expansion is allowed when a cheaper route is found.
	while head < queue.size():
		var current: Vector3i = queue[head]
		head += 1

		var current_id: int = cell_to_id_map.get(current, -1)

		if current_id == -1:
			continue

		var current_cost: float = float(costs[current])
		var enter_weight: float = astar.get_point_weight_scale(current_id)

		for index: int in range(NEIGHBOR_OFFSETS.size()):
			var step: Vector3i = NEIGHBOR_OFFSETS[index]
			var neighbor: Vector3i = current + step

			if not cell_to_id_map.has(neighbor):
				continue

			if not _can_move_between(current, step):
				continue

			var neighbor_cost: float = current_cost + _step_lengths[index] * enter_weight
			var known: bool = costs.has(neighbor)

			if known and neighbor_cost >= float(costs[neighbor]):
				continue

			if not known and cell_limit > 0 and costs.size() >= cell_limit:
				continue

			costs[neighbor] = neighbor_cost
			queue.append(neighbor)

	return costs


## Cell-by-cell route through the navigation graph, for congestion prediction.
## Returns the nav cells the cheapest path occupies, start first. Unlike
## `_calculate_path`, it does not smooth or shift the route, because the
## optimizer needs the cells the agents will actually occupy.
func get_path_cells(from_world: Vector3, to_world: Vector3) -> Array[Vector3i]:
	var result: Array[Vector3i] = []

	if astar.get_point_count() == 0:
		return result

	var start_id: int = _find_nav_id(to_local(from_world))
	var end_id: int = _find_nav_id(to_local(to_world))

	if start_id == -1 or end_id == -1:
		return result

	var ids: PackedInt64Array = astar.get_id_path(start_id, end_id)

	for point_id: int in ids:
		var cell: Vector3i = _id_to_cell.get(point_id, NO_CELL)

		if cell != NO_CELL:
			result.append(cell)

	return result


## Number of registered navigation points. Diagnostics only.
func get_nav_point_count() -> int:
	return astar.get_point_count()


func request_path_immediate(start: Vector3, end: Vector3) -> PackedVector3Array:
	return _calculate_path(start, end)


## Concatenate synchronous A* legs through ordered world-space waypoints. This
## is the primitive behind saved plans and authored routes: the caller supplies
## a corridor, the navigation layer supplies walkable geometry. A blocked or
## unreachable leg falls back to a direct path so an agent never deadlocks.
func request_path_via(
	start: Vector3,
	points: Array,
	end: Vector3,
	smooth: bool = true
) -> PackedVector3Array:
	var waypoints: Array[Vector3] = []

	for point: Variant in points:
		if point is Vector3:
			waypoints.append(point)
		elif point is Array and (point as Array).size() >= 3:
			waypoints.append(Vector3(
				float(point[0]), float(point[1]), float(point[2])
			))

	if waypoints.is_empty():
		return _calculate_path(start, end, smooth)

	var combined := PackedVector3Array()
	var current: Vector3 = start

	for waypoint: Vector3 in waypoints:
		var leg: PackedVector3Array = _calculate_path(current, waypoint, smooth)

		if leg.is_empty():
			return _calculate_path(start, end, smooth)

		for point: Vector3 in leg:
			if combined.is_empty() or combined[combined.size() - 1].distance_to(point) > 0.05:
				combined.append(point)

		current = waypoint

	var final_leg: PackedVector3Array = _calculate_path(current, end, smooth)

	if final_leg.is_empty():
		return _calculate_path(start, end, smooth)

	for point: Vector3 in final_leg:
		if combined.is_empty() or combined[combined.size() - 1].distance_to(point) > 0.05:
			combined.append(point)

	return combined


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


## Samples along a segment (every half cell) and checks that walkable ground is
## under the centre line and under the agent's width either side of it.
func _segment_has_ground(from_world: Vector3, to_world: Vector3) -> bool:
	var from_local: Vector3 = to_local(from_world)
	var to_local_pos: Vector3 = to_local(to_world)
	var direction: Vector3 = to_local_pos - from_local
	direction.y = 0.0

	var side := Vector3.ZERO
	if direction.length_squared() > 0.0001:
		side = direction.normalized().cross(Vector3.UP) * path_ground_radius

	var step: float = maxf(minf(cell_size.x, cell_size.z) * 0.5, 0.01)
	var samples: int = maxi(int(ceilf(from_local.distance_to(to_local_pos) / step)), 1)
	var side_height_tolerance: float = 0.6

	for i in range(1, samples + 1):
		var t: float = float(i) / float(samples)
		var point: Vector3 = from_local.lerp(to_local_pos, t)

		if not _has_ground_near(point):
			return false

		if side.length_squared() > 0.0001:
			if not _has_ground_near(point + side, side_height_tolerance):
				return false
			if not _has_ground_near(point - side, side_height_tolerance):
				return false

	return true


func is_ground_supported(
	world_pos: Vector3,
	height_tolerance: float = GROUND_HEIGHT_TOLERANCE
) -> bool:
	return _has_ground_near(to_local(world_pos), height_tolerance)


## Samples the whole segment, not just its endpoint, so a diagonal move cannot
## clip across an unsupported corner between two apparently valid probe cells.
func is_ground_path_supported(
	from_world: Vector3,
	to_world: Vector3,
	height_tolerance: float = GROUND_HEIGHT_TOLERANCE
) -> bool:
	var from_local: Vector3 = to_local(from_world)
	var to_local_pos: Vector3 = to_local(to_world)
	var step: float = maxf(minf(cell_size.x, cell_size.z) * 0.35, 0.05)
	var samples: int = maxi(
		int(ceilf(from_local.distance_to(to_local_pos) / step)),
		1
	)

	for index: int in range(samples + 1):
		var sample: Vector3 = from_local.lerp(
			to_local_pos,
			float(index) / float(samples)
		)

		if not _has_ground_near(sample, height_tolerance):
			return false

	return true


## True if a registered walkable cell sits within the height tolerance of this
## local position. The default tolerance allows normal stair steps; side checks
## pass a smaller value so a shortcut cannot step off a ledge.
func _has_ground_near(
	local_pos: Vector3,
	height_tolerance: float = GROUND_HEIGHT_TOLERANCE
) -> bool:
	var base_cell: Vector3i = local_to_map(local_pos)

	for dy: int in GROUND_PROBE_DY:
		var cell: Vector3i = base_cell + Vector3i(0, dy, 0)
		var id: int = cell_to_id_map.get(cell, -1)

		if id == -1:
			continue

		if absf(astar.get_point_position(id).y - local_pos.y) <= (
			cell_size.y * height_tolerance
		):
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
	return _nav_has_block(cell) and not _nav_has_block(cell + Vector3i.UP)


func _nav_point_position(cell: Vector3i) -> Vector3:
	var y_offset: float = cell_size.y * 0.5

	if _surface_is_low(cell):
		# Bottom slabs and normal stairs are half-height at the cell centre.
		y_offset = 0.0 if cell_center_y else cell_size.y * 0.5

	return map_to_local(cell) + Vector3(0.0, y_offset, 0.0)


## Registers how a MeshLibrary item is allowed to rotate. This is metadata-only;
## the future block generator can populate it automatically.
func set_directional_kind(item: int, kind: DirectionalKind) -> void:
	_directional_kinds[item] = kind
	if _mesher != null:
		_mesher.rebuild_all()


func get_directional_kind(item: int) -> int:
	return int(_directional_kinds.get(item, -1))


## Scans the MeshLibrary for connected-texture items and builds their runtime
## atlas material from the matching source texture. Full blocks and their
## slab/stair variants share one material per source: the mesher picks the
## per-face atlas tile for all of them.
func _build_ctm_items() -> void:
	_ctm_materials.clear()
	_ctm_bases.clear()
	if mesh_library == null:
		return

	var base_materials: Dictionary = {}
	var tinted_materials: Dictionary = {}
	for id: int in mesh_library.get_item_list():
		var item_name := String(mesh_library.get_item_name(id))
		var base_name := ctm_base_name(item_name)
		if base_name.is_empty():
			continue
		var material: Material = base_materials.get(base_name)
		if material == null:
			var source_path := (
				"res://textures/auto_connecting_blocks/"
				+ base_name
				+ ".png"
			)
			if not FileAccess.file_exists(source_path):
				continue
			material = CTM_BUILDER.build_material(source_path)
			if material == null:
				continue
			base_materials[base_name] = material

		var color_index := ctm_color_index(item_name)
		var group_name := base_name
		var item_material := material
		if color_index >= 0:
			var tint_key := "%s|c%02d" % [base_name, color_index]
			item_material = tinted_materials.get(tint_key)
			if item_material == null:
				var tinted := material.duplicate() as StandardMaterial3D
				if tinted != null:
					tinted.albedo_color = COLOR_PALETTE.color_at(color_index)
					item_material = tinted
				else:
					item_material = material
				tinted_materials[tint_key] = item_material
			group_name = tint_key
		_ctm_materials[id] = item_material
		_ctm_bases[id] = group_name


## Maps an `Auto_Connect_*` item name to its CTM source base name, stripping
## the shape prefix and any trailing color index. Returns "" for non-CTM items.
func ctm_base_name(item_name: String) -> String:
	if not item_name.begins_with("Auto_Connect_"):
		return ""
	var base_name := item_name.trim_prefix("Auto_Connect_")
	for prefix: String in [
		"Slab_Top_",
		"Slab_Bottom_",
		"Slab_Side_",
		"Slab_",
		"Stairs_UpsideDown_",
		"Stairs_",
		"Stair_",
		"Panel_Top_",
		"Panel_Bottom_",
		"Panel_Side_",
		"Panel_",
	]:
		if base_name.begins_with(prefix):
			base_name = base_name.substr(prefix.length())
			break

	var color_pos := base_name.rfind("_c")
	if color_pos != -1 and base_name.length() - color_pos == 4:
		var color_tail := base_name.substr(color_pos + 2)
		if color_tail.is_valid_int():
			base_name = base_name.substr(0, color_pos)
	return base_name


## Trailing `_cNN` palette index on a CTM item, or -1 when uncolored.
func ctm_color_index(item_name: String) -> int:
	return COLOR_PALETTE.color_index(item_name)


func is_ctm_item(item: int) -> bool:
	return _ctm_materials.has(item)


func get_ctm_material(item: int) -> Material:
	return _ctm_materials.get(item) as Material


## CTM source group for an item. Adjacent shapes with the same base connect in
## the mesher's per-face border mask.
func get_ctm_base(item: int) -> String:
	return String(_ctm_bases.get(item, ""))


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
		get_block_orientation(cell)
	)


func get_facing_orientation(direction: Vector3i) -> int:
	return get_orientation_for_direction(DirectionalKind.FACING, direction)


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

	# Older runs generated stairs for connected-window items. Remove those
	# clutter entries; connected autoblocks are not full block materials.
	var remove_ids: PackedInt32Array = PackedInt32Array()
	for id: int in item_ids:
		var existing_name: String = mesh_library.get_item_name(id)
		if existing_name.begins_with(auto_stair_prefix + "Connect_"):
			remove_ids.append(id)
	for id: int in remove_ids:
		mesh_library.remove_item(id)
	if not remove_ids.is_empty():
		item_ids = mesh_library.get_item_list()

	for id: int in item_ids:
		existing_ids[mesh_library.get_item_name(id)] = id
		next_stair_id = maxi(next_stair_id, id + 1)

	for id: int in item_ids:
		var source_name: String = mesh_library.get_item_name(id)

		if not source_name.begins_with("Auto_"):
			continue
		if (
			"Slab" in source_name
			or "Stair" in source_name
			or "Panel" in source_name
			or "Water" in source_name
			or "Connect" in source_name
		):
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


## Ash-only settle/merge. Safe to call for every block; it does nothing for
## non-ash items. The guard prevents compaction's own place_block calls from
## re-entering the settle pass.
func settle_ash_cell(cell: Vector3i) -> void:
	if _ash_settling or mesh_library == null:
		return
	var item: int = get_block_item(cell)
	if item < 0:
		return
	if not ASH_SETTLER.is_ash_name(String(mesh_library.get_item_name(item))):
		return
	_ash_settling = true
	ASH_SETTLER.settle_world_cell(self, cell)
	_ash_settling = false


func place_block(cell: Vector3i, item: int, orientation: int = 0) -> bool:
	if mesh_library == null:
		return false

	if cell.y < min_block_y or cell.y > max_block_y:
		return false

	if not mesh_library.get_item_list().has(item):
		return false

	if (
		get_block_item(cell) == item
		and get_block_orientation(cell) == orientation
	):
		return false

	_track_cell_values(cell, item, orientation)
	mark_chunk_dirty(cell_to_chunk(cell))
	_refresh_nav_around(cell)
	block_placed.emit(cell, item)
	_apply_structure_after_edit([cell], {}, true)
	settle_ash_cell(cell)

	return true


func remove_block(cell: Vector3i) -> bool:
	if get_block_item(cell) == GridMap.INVALID_CELL_ITEM:
		return false

	var before: Dictionary = {}
	if stability_enabled and collapse_enabled and not _structural_busy:
		before = _structural_snapshot([cell])

	_untrack_cell(cell)
	mark_chunk_dirty(cell_to_chunk(cell))
	_refresh_nav_around(cell)
	block_removed.emit(cell)
	_apply_structure_after_edit([cell], before)

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
		if cell.y < min_block_y or cell.y > max_block_y:
			continue

		if has_block(cell):
			continue

		_track_cell_values(cell, item, orientation)
		placed_cells.append(cell)

	if placed_cells.is_empty():
		return 0

	_mark_chunks_dirty(placed_cells)
	var affected: Array[Vector3i] = _refresh_nav_region(placed_cells)

	for cell: Vector3i in placed_cells:
		block_placed.emit(cell, item)

	navigation_changed.emit(affected)
	_apply_structure_after_edit(placed_cells, {}, true)
	for cell: Vector3i in placed_cells:
		settle_ash_cell(cell)
	return placed_cells.size()


## Adds a bottom slab above every column that is one block lower than an
## orthogonal neighbour. This retrofits the half-step risers onto an existing
## saved world; new terrain gets them from `HeightmapTerrainGenerator`.
## Idempotent: a cell is only added when `top + 1` is empty.
func add_step_slabs(item: int = 46) -> int:
	if mesh_library == null or not mesh_library.get_item_list().has(item):
		return 0

	var tops: Dictionary = {}
	var missing_top: int = -2147483648

	for cell: Vector3i in get_used_block_cells():
		# Existing step slabs must not become the terrain top, otherwise a
		# second call would stack another slab on top of them.
		if get_block_item(cell) == item:
			continue

		var column := Vector2i(cell.x, cell.z)
		var previous: int = int(tops.get(column, missing_top))

		if cell.y > previous:
			tops[column] = cell.y

	var additions: Array[Vector3i] = []

	for column: Vector2i in tops:
		var top: int = int(tops[column])
		var higher: bool = (
			int(tops.get(column + Vector2i(1, 0), missing_top)) > top
			or int(tops.get(column + Vector2i(-1, 0), missing_top)) > top
			or int(tops.get(column + Vector2i(0, 1), missing_top)) > top
			or int(tops.get(column + Vector2i(0, -1), missing_top)) > top
		)

		if not higher:
			continue

		var slab := Vector3i(column.x, top + 1, column.y)

		if not has_block(slab):
			additions.append(slab)

	if additions.is_empty():
		return 0

	return place_blocks(additions, item, 0)


## Removes every existing cell in `cells` with a single navigation refresh.
func remove_blocks(cells: Array[Vector3i]) -> int:
	var before: Dictionary = {}
	if stability_enabled and collapse_enabled and not _structural_busy:
		before = _structural_snapshot(cells)

	var removed: Array[Vector3i] = []

	for cell: Vector3i in cells:
		if not has_block(cell):
			continue

		_untrack_cell(cell)
		removed.append(cell)

	if removed.is_empty():
		return 0

	_mark_chunks_dirty(removed)
	var affected: Array[Vector3i] = _refresh_nav_region(removed)

	for cell: Vector3i in removed:
		block_removed.emit(cell)

	navigation_changed.emit(affected)
	_apply_structure_after_edit(removed, before)
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
	return get_block_item(cell) != GridMap.INVALID_CELL_ITEM


# ---------------------------------------------------------------------------
# Structural stability
# ---------------------------------------------------------------------------

func get_structural_stability() -> RefCounted:
	if _structural == null:
		_structural = STRUCTURAL_STABILITY.new(self)
	return _structural


## Lazily owns the sub-level manager. It lives beside the grid (the grid itself
## is hidden by chunk streaming) and survives across collapses.
func get_sublevel_manager():
	if _sublevel_manager == null or not is_instance_valid(_sublevel_manager):
		var manager = SUB_LEVEL_MANAGER.new()
		manager.name = "SubLevelManager"
		var host := _visual_host()
		host.add_child(manager)
		manager.setup(self, host)
		_sublevel_manager = manager
	return _sublevel_manager


## Support reach of one cell, or -1 when stability is disabled or the cell is
## empty. Anchored cells (bedrock) report 255.
func get_stability(cell: Vector3i) -> int:
	if not stability_enabled:
		return -1
	if not has_block(cell):
		return -1
	return get_structural_stability().stability_at(cell)


## Support values for an explicit set of cells. Used by the debug overlay and
## by diagnostics; the caller should include a margin around the area it draws.
func get_stability_field(cells: Array[Vector3i]) -> Dictionary:
	if not stability_enabled:
		return {}
	return get_structural_stability().field_for_cells(cells)


## Runs the collapse loop for a set of edited cells.
##
## `before` is the support field captured *before* a removal. Only cells that
## were supported before and are unsupported now collapse, so pre-existing
## unanchored geometry (an authored platform, an old save without bedrock) is
## never demolished by an unrelated edit. Placement cannot reduce support, so
## only the placed cells themselves are checked.
##
## Cascades are driven here rather than by nested hooks so the whole collapse is
## one bounded loop.
func _apply_structure_after_edit(
	seeds: Array[Vector3i],
	before: Dictionary = {},
	placement: bool = false
) -> void:
	_stability_overlay_dirty = true

	if not stability_enabled:
		return
	if not collapse_enabled:
		return
	if _structural_busy:
		return
	if seeds.is_empty():
		return

	var placed: Dictionary = {}
	if placement:
		for cell: Vector3i in seeds:
			placed[cell] = true

	_structural_busy = true
	var pending: Array[Vector3i] = seeds
	var previous: Dictionary = before
	var pass_index: int = 0
	var removed_any: bool = false
	var collapsed_cells: Array[Vector3i] = []

	while pass_index < MAX_COLLAPSE_PASSES and not pending.is_empty():
		var current: Dictionary = {}
		var unsupported: Dictionary = {}

		var centers: Array[Vector3i] = _select_stability_centers(
			pending,
			get_structural_stability().decision_radius()
		)

		for center: Vector3i in centers:
			var result: Dictionary = get_structural_stability().evaluate_around(center)
			if bool(result.get("aborted", false)):
				continue

			var values: Dictionary = result.get("values", {})
			for cell: Vector3i in values:
				current[cell] = maxi(
					int(current.get(cell, 0)),
					int(values[cell])
				)

			for cell: Vector3i in result.get("unsupported", []):
				if placement and pass_index == 0:
					if placed.has(cell):
						unsupported[cell] = true
					continue
				if int(previous.get(cell, 0)) > 0:
					unsupported[cell] = true

		if unsupported.is_empty():
			break

		# Accumulate the earliest (highest) value seen for each cell. Values only
		# fall as cells are removed, so a cell that was supported when it first
		# entered a window stays eligible later even if its own seed was folded
		# into a nearby evaluation centre.
		for cell: Vector3i in current:
			previous[cell] = maxi(
				int(previous.get(cell, 0)),
				int(current[cell])
			)

		placement = false

		var batch: Array[Vector3i] = []
		batch.assign(unsupported.keys())
		var moved_items: Dictionary = {}
		var moved_orientations: Dictionary = {}
		if collapse_style != COLLAPSE_REMOVE:
			var captured := _capture_cells(batch)
			moved_items = captured["items"]
			moved_orientations = captured["orientations"]

		remove_blocks(batch)
		collapsed_cells.append_array(batch)

		match collapse_style:
			COLLAPSE_FALL:
				_drop_collapsed_blocks(batch, moved_items, moved_orientations)
			COLLAPSE_RIGID:
				_spawn_collapse_debris(batch, moved_items, moved_orientations)
			COLLAPSE_SUBLEVEL:
				get_sublevel_manager().spawn(
					batch,
					moved_items,
					moved_orientations
				)
		pending = _solid_neighbours(batch)
		removed_any = true
		pass_index += 1

	_structural_busy = false

	if removed_any:
		_stability_overlay_dirty = true

	if not collapsed_cells.is_empty():
		structure_collapsed.emit(collapsed_cells, collapse_style)


## Picks evaluation centres so every seed is within `decision` columns of one
## centre. Adjacent seeds fold together, but a long drag still gets centres
## every `decision` columns, which is what keeps the whole batch covered. The
## old "skip any seed inside any window" rule could leave the far side of a long
## batch unevaluated and floating.
func _select_stability_centers(
	seeds: Array[Vector3i],
	decision: int
) -> Array[Vector3i]:
	var centers: Array[Vector3i] = []
	if decision <= 0 or seeds.is_empty():
		return centers

	var buckets: Dictionary = {}

	for seed: Vector3i in seeds:
		var key := Vector2i(
			floori(float(seed.x) / float(decision)),
			floori(float(seed.z) / float(decision))
		)
		var covered: bool = false

		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var list_value: Variant = buckets.get(
					key + Vector2i(dx, dz),
					null
				)
				if list_value == null:
					continue
				for center: Vector3i in list_value:
					if (
						absi(seed.x - center.x)
						+ absi(seed.z - center.z)
						<= decision
					):
						covered = true
						break
				if covered:
					break
			if covered:
				break

		if covered:
			continue

		centers.append(seed)
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(seed)

	return centers


## Reads each placed/removed cell's item and orientation while it still exists.
func _capture_cells(cells: Array[Vector3i]) -> Dictionary:
	var items: Dictionary = {}
	var orientations: Dictionary = {}

	for cell: Vector3i in cells:
		items[cell] = get_block_item(cell)
		orientations[cell] = get_block_orientation(cell)

	return {"items": items, "orientations": orientations}


## Support field for a set of cells *before* they are removed. Captured by the
## removal entry points so the collapse loop can tell "was supported" from
## "was already floating".
func _structural_snapshot(cells: Array[Vector3i]) -> Dictionary:
	var values: Dictionary = {}
	var covered: Dictionary = {}
	var evaluator = get_structural_stability()

	for cell: Vector3i in cells:
		if covered.has(cell):
			continue
		var result: Dictionary = evaluator.evaluate_around(cell)
		if bool(result.get("aborted", false)):
			continue
		for covered_cell: Vector3i in result.get("cells", []):
			covered[covered_cell] = true
		var window: Dictionary = result.get("values", {})
		for window_cell: Vector3i in window:
			values[window_cell] = window[window_cell]

	return values


## Solid cells orthogonally touching any of `cells`. Used as the next cascade
## seeds after a removal batch.
func _solid_neighbours(cells: Array[Vector3i]) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var seen: Dictionary = {}

	for cell: Vector3i in cells:
		for offset: Vector3i in STRUCTURAL_STABILITY.DIRS_6:
			var neighbour: Vector3i = cell + offset
			if seen.has(neighbour) or not has_block(neighbour):
				continue
			seen[neighbour] = true
			result.append(neighbour)

	return result


## Chunk streaming hides the GridMap (`ChunkMesher` sets `grid.visible = false`)
## and renders sibling `ChunkMeshes` instead. Anything visual must therefore be
## parented to the grid's parent, not the grid, or it is invisible in game. The
## path debug mesh already follows this rule.
func _visual_host() -> Node:
	var host := get_parent()
	if host != null:
		return host
	if is_inside_tree():
		return get_tree().current_scene
	return self


## Rigid tier: one rigid body per collapse batch, built from the removed cells'
## real block meshes (materials included). The body sits on collision layer 0 and
## only collides with the world layer, so it cannot disturb agents, navigation or
## the optimizer. Bodies are capped and expire so a long session cannot
## accumulate them.
func _spawn_collapse_debris(
	cells: Array[Vector3i],
	items: Dictionary,
	orientations: Dictionary
) -> void:
	if collapse_style != COLLAPSE_RIGID or cells.is_empty():
		return

	var count: int = mini(cells.size(), MAX_DEBRIS_CELLS)
	var centre := Vector3.ZERO
	for index in count:
		centre += to_global(map_to_local(cells[index]))
	centre /= float(count)

	var mesh: ArrayMesh = _build_debris_mesh(
		cells,
		items,
		orientations,
		centre,
		count
	)
	if mesh == null or mesh.get_surface_count() == 0:
		return

	var body := RigidBody3D.new()
	body.name = "StabilityDebris"
	body.add_to_group("stability_debris")
	body.collision_layer = 0
	body.collision_mask = 1
	body.mass = clampf(float(count) * 0.15, 1.0, 200.0)
	body.linear_damp = 0.15
	body.angular_damp = 0.3
	# A small deterministic tumble makes the collapse read as debris rather than
	# a static prop, and it is presentation-only.
	body.angular_velocity = Vector3(0.15, 0.35, 0.1)

	var collision := CollisionShape3D.new()
	# The world's chunk collision is a concave trimesh. Jolt does not reliably
	# collide a moving concave body against a static concave mesh, so the debris
	# collider is the convex hull of the batch; the visual keeps the exact shape.
	collision.shape = mesh.create_convex_shape(true, false)
	body.add_child(collision)

	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.add_child(visual)

	var host := _visual_host()
	host.add_child(body)
	body.global_position = centre

	# A child timer is freed with the body, so a scene change can never invoke
	# a callback on a freed grid or body.
	var lifetime := Timer.new()
	lifetime.one_shot = true
	lifetime.wait_time = DEBRIS_LIFETIME
	lifetime.process_mode = Node.PROCESS_MODE_ALWAYS
	lifetime.timeout.connect(body.queue_free)
	body.add_child(lifetime)
	lifetime.start()

	# Expired bodies leave dangling references; drop them before capping so the
	# eviction never has to assign a freed instance to a typed variable.
	for index in range(_debris_bodies.size() - 1, -1, -1):
		if not is_instance_valid(_debris_bodies[index]):
			_debris_bodies.remove_at(index)

	_debris_bodies.append(body)

	while _debris_bodies.size() > MAX_DEBRIS_BODIES:
		var oldest: Variant = _debris_bodies.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()


## Merges the removed cells' block meshes into one mesh, one surface per
## (item, source surface) so the rigid body keeps the real block materials and
## stair/slab shapes. Unknown items fall back to a box.
func _build_debris_mesh(
	cells: Array[Vector3i],
	items: Dictionary,
	orientations: Dictionary,
	centre: Vector3,
	count: int
) -> ArrayMesh:
	var groups: Dictionary = {}
	var missing: Array[Vector3i] = []

	for index in count:
		var cell: Vector3i = cells[index]
		var item: int = int(items.get(cell, -1))
		var source: Mesh = null
		if mesh_library != null and item >= 0:
			source = mesh_library.get_item_mesh(item)

		if source == null or source.get_surface_count() == 0:
			missing.append(cell)
			continue

		for surface in source.get_surface_count():
			var key := "%d:%d" % [item, surface]
			if not groups.has(key):
				groups[key] = {
					"item": item,
					"surface": surface,
					"cells": [],
				}
			groups[key]["cells"].append(cell)

	if groups.is_empty() and missing.is_empty():
		return null

	var result := ArrayMesh.new()
	var fallback_material := StandardMaterial3D.new()
	fallback_material.albedo_color = Color(0.5, 0.46, 0.42)
	fallback_material.roughness = 1.0

	for key: Variant in groups:
		var group: Dictionary = groups[key]
		var item: int = int(group["item"])
		var surface: int = int(group["surface"])
		var source: Mesh = mesh_library.get_item_mesh(item)
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)

		for cell: Vector3i in group["cells"]:
			var basis := get_orientation_basis(int(orientations.get(cell, 0)))
			builder.append_from(
				source,
				surface,
				Transform3D(basis, to_global(map_to_local(cell)) - centre)
			)

		builder.commit(result)
		var material: Material = source.surface_get_material(surface)
		result.surface_set_material(
			result.get_surface_count() - 1,
			material if material != null else fallback_material
		)

	if not missing.is_empty():
		var box := BoxMesh.new()
		box.size = cell_size * 0.92
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)

		for cell: Vector3i in missing:
			builder.append_from(
				box,
				0,
				Transform3D(Basis.IDENTITY, to_global(map_to_local(cell)) - centre)
			)

		builder.commit(result)
		result.surface_set_material(
			result.get_surface_count() - 1,
			fallback_material
		)

	return result


# ---------------------------------------------------------------------------
# Falling collapse style
# ---------------------------------------------------------------------------

## Unsupported cells drop down their own column, stack on the first solid cell
## below, and settle back into the world as normal blocks. The world move is
## delayed until the visual fall ends so a block is never visible in two places
## at once. Landing uses the structural guard, so settling rubble never starts
## a new collapse cascade.
func _drop_collapsed_blocks(
	cells: Array[Vector3i],
	items: Dictionary,
	orientations: Dictionary
) -> void:
	if cells.is_empty():
		return

	var by_column: Dictionary = {}

	for cell: Vector3i in cells:
		var column := Vector2i(cell.x, cell.z)
		if not by_column.has(column):
			by_column[column] = []
		by_column[column].append(cell.y)

	var moves: Dictionary = {}
	var visuals: Array = []
	var any_move: bool = false

	for column: Vector2i in by_column:
		var ys: Array = by_column[column]
		ys.sort()
		var occupied: Dictionary = {}

		for value: Variant in ys:
			var source_y: int = int(value)
			var source := Vector3i(column.x, source_y, column.y)
			var item: int = int(items.get(source, -1))
			if item < 0:
				continue

			# Land on the first solid cell (or already landed block) below.
			var landing_y: int = min_block_y - 1
			for probe in range(source_y - 1, min_block_y - 1, -1):
				if occupied.has(probe):
					landing_y = probe + 1
					break
				if has_block(Vector3i(column.x, probe, column.y)):
					landing_y = probe + 1
					break

			if landing_y < min_block_y or landing_y > max_block_y:
				continue

			var destination := Vector3i(column.x, landing_y, column.y)
			occupied[landing_y] = true

			var orientation: int = int(orientations.get(source, 0))
			var key := "%d:%d" % [item, orientation]
			if not moves.has(key):
				moves[key] = {
					"item": item,
					"orientation": orientation,
					"cells": [],
				}
			moves[key]["cells"].append(destination)

			if destination != source:
				any_move = true
				if visuals.size() < MAX_FALL_VISUALS:
					visuals.append({
						"from": to_global(map_to_local(source)),
						"to": to_global(map_to_local(destination)),
					})

	if moves.is_empty():
		return

	if not any_move:
		_land_fallen_blocks(moves)
		return

	_spawn_falling_blocks(visuals)

	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = FALL_DURATION
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	timer.timeout.connect(
		func() -> void:
			_land_fallen_blocks(moves)
			timer.queue_free()
	)
	add_child(timer)
	timer.start()


func _land_fallen_blocks(moves: Dictionary) -> void:
	var was_busy: bool = _structural_busy
	_structural_busy = true

	for key: Variant in moves:
		var entry: Dictionary = moves[key]
		var cells: Array[Vector3i] = []
		cells.assign(entry["cells"])
		place_blocks(cells, int(entry["item"]), int(entry["orientation"]))

	_structural_busy = was_busy
	_stability_overlay_dirty = true


func _spawn_falling_blocks(visuals: Array) -> void:
	if visuals.is_empty():
		return

	var falling = FALLING_BLOCKS.new()
	falling.name = "FallingBlocks"
	falling.process_mode = Node.PROCESS_MODE_ALWAYS
	falling.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_visual_host().add_child(falling)
	falling.setup(visuals, cell_size, FALL_DURATION)


# ---------------------------------------------------------------------------
# Structural debug overlay
# ---------------------------------------------------------------------------

func _update_stability_overlay(delta: float) -> void:
	if not stability_debug or not stability_enabled:
		if _stability_overlay != null and _stability_overlay.visible:
			_stability_overlay.visible = false
		return

	_stability_overlay_accum += delta

	var player := get_tree().get_first_node_in_group("Player") as Node3D
	var origin := Vector3.ZERO
	if player != null:
		origin = player.global_position
	else:
		var used: Array[Vector3i] = get_used_block_cells()
		if not used.is_empty():
			origin = to_global(map_to_local(used[0]))
	var center_chunk: Vector2i = position_to_chunk(origin)

	if not _stability_overlay_dirty and _stability_overlay_center == center_chunk:
		return

	# Rebuild on edits and chunk changes, throttled so a drag does not rebuild
	# the whole overlay once per placed cell. No idle refresh: a clean overlay
	# stays put instead of popping once a second.
	if _stability_overlay_dirty and _stability_overlay_accum < STABILITY_OVERLAY_INTERVAL:
		return

	_stability_overlay_accum = 0.0
	_stability_overlay_dirty = false
	_stability_overlay_center = center_chunk

	# Collect a margin of chunks wider than the drawn radius: a cell at the
	# drawn edge needs support from up to `window_radius` farther out.
	var chunks: Array[Vector2i] = []

	for dx in range(-STABILITY_OVERLAY_CHUNK_RADIUS, STABILITY_OVERLAY_CHUNK_RADIUS + 1):
		for dz in range(-STABILITY_OVERLAY_CHUNK_RADIUS, STABILITY_OVERLAY_CHUNK_RADIUS + 1):
			var chunk := center_chunk + Vector2i(dx, dz)
			if _nav_chunks.has(chunk) or _sections.has_column(chunk):
				chunks.append(chunk)

	chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (
			Vector2(a - center_chunk).length_squared()
			< Vector2(b - center_chunk).length_squared()
		)
	)

	var draw_radius_sq: float = STABILITY_OVERLAY_DRAW_RADIUS * STABILITY_OVERLAY_DRAW_RADIUS
	var margin_cells: Array[Vector3i] = []
	var draw_set: Dictionary = {}

	for chunk: Vector2i in chunks:
		for cell: Vector3i in get_chunk_cell_list(chunk):
			margin_cells.append(cell)
			var world := to_global(map_to_local(cell))
			if world.distance_squared_to(origin) <= draw_radius_sq:
				draw_set[cell] = true
		if margin_cells.size() >= STRUCTURAL_STABILITY.MAX_WINDOW_CELLS:
			break

	var field: Dictionary = get_stability_field(margin_cells)
	if field.is_empty():
		return

	if _stability_overlay == null:
		_stability_overlay = _make_stability_overlay()

	var visible_cells: Array[Vector3i] = []
	for cell: Vector3i in margin_cells:
		if not draw_set.has(cell):
			continue
		if not _cell_is_exposed(cell):
			continue
		visible_cells.append(cell)
		if visible_cells.size() >= STABILITY_OVERLAY_MAX_INSTANCES:
			break

	var multimesh: MultiMesh = _stability_overlay.multimesh
	multimesh.instance_count = visible_cells.size()
	var max_reach: int = get_structural_stability().max_reach()

	for index in visible_cells.size():
		var cell: Vector3i = visible_cells[index]
		multimesh.set_instance_transform(
			index,
			Transform3D(Basis.IDENTITY, to_global(map_to_local(cell)))
		)
		multimesh.set_instance_color(index, _stability_color(int(field.get(cell, 0)), max_reach))

	_stability_overlay.visible = true


func _cell_is_exposed(cell: Vector3i) -> bool:
	for offset: Vector3i in STRUCTURAL_STABILITY.DIRS_6:
		if not has_block(cell + offset):
			return true
	return false


func _make_stability_overlay() -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = cell_size * 0.92

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.55)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	box.material = material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = box
	multimesh.instance_count = 0

	var overlay := MultiMeshInstance3D.new()
	overlay.name = "StabilityOverlay"
	overlay.multimesh = multimesh
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Updated from _process; interpolating a MultiMesh causes the overlay to
	# judder/flicker when physics interpolation is enabled.
	overlay.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	overlay.visible = false
	_visual_host().add_child(overlay)
	return overlay


func _stability_color(value: int, max_reach: int) -> Color:
	if value >= STRUCTURAL_STABILITY.STABILITY_ANCHORED:
		return Color(0.35, 0.65, 1.0, 0.75)
	if value <= 0:
		return Color(1.0, 0.08, 0.05, 0.8)
	var t: float = clampf(float(value) / float(maxi(1, max_reach)), 0.0, 1.0)
	return Color.from_hsv(lerpf(0.0, 0.33, t), 0.9, 1.0, 0.55)


func _refresh_point_weights_around(changed_cell: Vector3i) -> void:
	var affected: Array[Vector3i] = [changed_cell]

	for dir in WALL_CHECK_DIRS:
		affected.append(changed_cell - Vector3i.UP - dir)
		affected.append(changed_cell - dir)

	for cell: Vector3i in affected:
		if cell_to_id_map.has(cell):
			_apply_nav_point_weight(cell)


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
	elif walkable and registered:
		# The cell may have changed from a full block to a slab/stair (or
		# back), so keep its path point at the new walking surface and refresh
		# its surface cost.
		var point_id: int = int(cell_to_id_map[cell])
		astar.set_point_position(point_id, _nav_point_position(cell))
		_apply_nav_point_weight(cell)


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

	_congestion_heat.erase(cell)
	_congestion_dirty.erase(cell)
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
	_track_cell_values(
		cell,
		get_block_item(cell),
		get_block_orientation(cell)
	)


## Indexes a cell whose item and orientation are already known. Bulk placement
## and chunk loading pass them so they do not re-query GridMap for every cell.
func _track_cell_values(
	cell: Vector3i,
	item: int,
	orientation: int
) -> void:
	var chunk: Vector2i = cell_to_chunk(cell)

	if item < 0:
		_sections.remove_cell(cell)
		_untrack_min_y(chunk, cell.y)
		return

	_sections.set_cell(cell, item, orientation)

	if _grid_mirror_enabled:
		set_cell_item(cell, item, orientation)

	var lowest: int = int(_chunk_min_y.get(chunk, NO_CHUNK_FLOOR))
	if lowest == NO_CHUNK_FLOOR or cell.y < lowest:
		_chunk_min_y[chunk] = cell.y


func _untrack_cell(cell: Vector3i) -> void:
	var chunk: Vector2i = cell_to_chunk(cell)

	_sections.remove_cell(cell)

	if _grid_mirror_enabled:
		set_cell_item(cell, GridMap.INVALID_CELL_ITEM)

	_untrack_min_y(chunk, cell.y)


func _untrack_min_y(chunk: Vector2i, removed_y: int) -> void:
	if not _sections.has_column(chunk):
		_chunk_min_y.erase(chunk)
		return

	if int(_chunk_min_y.get(chunk, NO_CHUNK_FLOOR)) != removed_y:
		return

	var lowest: int = _sections.get_column_min_y(chunk)
	_chunk_min_y[chunk] = (
		lowest
		if lowest != VoxelSectionStoreScript.NO_HEIGHT
		else NO_CHUNK_FLOOR
	)


func get_chunk_lowest_block_y(chunk: Vector2i) -> int:
	return int(_chunk_min_y.get(chunk, NO_CHUNK_FLOOR))


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


func get_mesher() -> ChunkMesher:
	return _mesher


## Number of per-chunk collision bodies currently built by the mesher.
func get_chunk_collision_body_count() -> int:
	if _mesher == null:
		return 0

	return _mesher.get_collision_body_count()


## True when the chunk already has physics collision. Without the mesher the
## GridMap mirror owns collision, so loaded cells are enough.
func has_chunk_collision(chunk: Vector2i) -> bool:
	if _mesher == null:
		return get_chunk_cell_count(chunk) > 0
	return _mesher.has_chunk_collision(chunk)


## Collision build stats: bodies, number of trimesh builds, total build usec.
func get_chunk_collision_stats() -> Dictionary:
	if _mesher == null:
		return {"bodies": 0, "builds": 0, "build_usec": 0}

	return _mesher.get_collision_stats()


## LOD mesh counts and collision body count.
func get_chunk_lod_stats() -> Dictionary:
	if _mesher == null:
		return {"lod0": 0, "lod1": 0, "lod2": 0, "meshed": 0, "collision": 0}

	return _mesher.get_lod_stats()


func _ensure_water_system() -> WaterSystem:
	if _water_system == null or not is_instance_valid(_water_system):
		_water_system = WaterSystem.new()
		_water_system.name = "WaterSystem"
		# Sibling, not a child: ChunkMesher hides the GridMap node, which would
		# hide a child renderer too. Copy the grid transform so the water's
		# grid-local MultiMesh transforms line up. The parent is still busy in
		# _ready, so defer only the tree insertion; item registration happens
		# synchronously in setup() so the HUD and mesher see the water items.
		_water_system.transform = transform
		_water_system.setup(self)
		get_parent().add_child.call_deferred(_water_system)
	return _water_system


func get_water_system() -> WaterSystem:
	return _ensure_water_system()


func get_populated_chunks() -> Array[Vector2i]:
	return _sections.get_column_chunks()


## Chunks that currently have built navigation. This is the active/loaded set
## the false-boid leaders are allowed to explore.
func get_active_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []

	for chunk: Vector2i in _nav_chunks:
		result.append(chunk)

	return result


func get_chunk_highest_block_y(chunk: Vector2i) -> int:
	if not _sections.has_column(chunk):
		return 0

	return _sections.get_column_max_y(chunk)


func get_chunk_cell_count(chunk: Vector2i) -> int:
	return _sections.get_column_cell_count(chunk)


## The set of cells in a chunk (cell -> true). Treat it as read-only.
## Prefer `get_chunk_cell_list()` on hot paths: it does not allocate entries.
func get_chunk_cells(chunk: Vector2i) -> Dictionary:
	var result: Dictionary = {}

	for cell: Vector3i in _sections.get_column_cell_list(chunk):
		result[cell] = true

	return result


## The cells in a chunk as a flat list. Used by the mesher and map renderer.
func get_chunk_cell_list(chunk: Vector2i) -> Array[Vector3i]:
	return _sections.get_column_cell_list(chunk)


## Cells plus parallel item ids in one pass. Hot mesher path: avoids one
## section lookup per cell.
func get_chunk_cells_and_items(
	chunk: Vector2i,
	out_cells: Array,
	out_items: Array
) -> void:
	_sections.get_column_cells_and_items(chunk, out_cells, out_items)


## Cell entries with item and orientation, for serialization and tooling.
func get_chunk_entries(chunk: Vector2i) -> Array[Dictionary]:
	return _sections.get_column_entries(chunk)


## Source-of-truth cell reads. GridMap's native `get_cell_item()` is emptied at
## runtime once the mirror is cleared, so game code must use these.
func get_block_item(cell: Vector3i) -> int:
	return _sections.get_cell_item(cell)


## Invisible navigation-only marker items used by the Nav Bodifier.
func nav_marker_item(low: bool) -> int:
	if mesh_library == null:
		return -1
	var name := "NavMarker_Slab" if low else "NavMarker"
	return mesh_library.find_item_by_name(name)


func is_nav_marker_item(item: int) -> bool:
	if item < 0 or mesh_library == null:
		return false
	return String(mesh_library.get_item_name(item)).begins_with("NavMarker")


func is_nav_marker_cell(cell: Vector3i) -> bool:
	return is_nav_marker_item(get_block_item(cell))


func get_block_orientation(cell: Vector3i) -> int:
	return _sections.get_cell_orientation(cell)


## Every stored cell. Use this instead of `GridMap.get_used_cells()`.
func get_used_block_cells() -> Array[Vector3i]:
	var result: Array[Vector3i] = []

	for chunk: Vector2i in _sections.get_column_chunks():
		result.append_array(_sections.get_column_cell_list(chunk))

	return result


## In-memory estimate for the packed section index (excludes GridMap's own copy).
func get_section_index_memory_bytes() -> int:
	return _sections.memory_bytes()


func get_section_count() -> int:
	return _sections.section_count()


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

## Packs one chunk into a plain Dictionary. Version 2 stores a compressed blob
## of 3D sections (see VoxelSectionStore); version 1's flat 5-int cell array is
## still accepted by `load_chunk` for old saves.
func serialize_chunk(chunk: Vector2i) -> Dictionary:
	return {
		"version": CHUNK_DATA_VERSION,
		"chunk_x": chunk.x,
		"chunk_z": chunk.y,
		"sections": _sections.serialize_column_compressed(chunk),
	}


## Replaces everything in a chunk with the contents of `data` (from serialize_chunk),
## then rebuilds navigation for the area in one batch. Does not mark the chunk dirty.
## navigation_changed is not emitted unless emit_nav_signal is true: a full chunk is
## thousands of cells and every NPC loops over the whole list.
func load_chunk(
	data: Dictionary,
	emit_nav_signal: bool = false,
	build_navigation: bool = true
) -> void:
	if mesh_library == null:
		push_error("NavGridMap.load_chunk: no MeshLibrary assigned.")
		return

	var version: int = int(data.get("version", 0))

	if version != CHUNK_DATA_VERSION and version != LEGACY_CHUNK_DATA_VERSION:
		push_error(
			"NavGridMap.load_chunk: unsupported chunk data version %d." % version
		)
		return

	var chunk := Vector2i(
		int(data.get("chunk_x", 0)),
		int(data.get("chunk_z", 0))
	)

	var valid_items: PackedInt32Array = mesh_library.get_item_list()
	var had_navigation: bool = _nav_chunks.has(chunk)
	var touched: Array[Vector3i] = _wipe_chunk(chunk)
	var skipped: int = 0

	if had_navigation and not build_navigation:
		# Drop the old AStar points before replacing the cells with a
		# non-navigable streaming version.
		_refresh_nav_region(touched)
		_nav_chunks.erase(chunk)

	if version == LEGACY_CHUNK_DATA_VERSION:
		skipped = _load_legacy_cells(chunk, data, valid_items, touched)
	else:
		# Fast path: generated/saved v2 blobs can be imported section-by-section
		# instead of decoding every cell and re-inserting it. Only used when no
		# navigation rebuild needs the touched-cell list.
		var blob_value: Variant = data.get("sections", PackedByteArray())
		var imported: bool = false

		if (
			not build_navigation
			and blob_value is PackedByteArray
			and _sections.import_column_compressed(
				chunk,
				blob_value,
				valid_items,
				min_block_y,
				max_block_y
			)
		):
			var lowest: int = _sections.get_column_min_y(chunk)

			if lowest != VoxelSectionStoreScript.NO_HEIGHT:
				_chunk_min_y[chunk] = lowest

			imported = true

		if not imported:
			skipped = _load_section_cells(chunk, data, valid_items, touched)

	if skipped > 0:
		push_warning(
			"NavGridMap.load_chunk: skipped %d invalid cell(s) in chunk %s."
			% [skipped, chunk]
		)

	var affected: Array[Vector3i] = []

	if build_navigation:
		affected = _refresh_nav_region(touched)
		_nav_chunks[chunk] = true
	else:
		_nav_chunks.erase(chunk)

	_dirty_chunks.erase(chunk)

	if emit_nav_signal and not affected.is_empty():
		navigation_changed.emit(affected)

	chunk_loaded.emit(chunk)


## Version-1 loader: flat 5-int cells. Kept so old saves and the current
## ChunkStreamer flat-floor path keep working through the same entry point.
func _load_legacy_cells(
	chunk: Vector2i,
	data: Dictionary,
	valid_items: PackedInt32Array,
	touched: Array[Vector3i]
) -> int:
	var packed_value: Variant = data.get("cells", PackedInt32Array())

	if packed_value is not PackedInt32Array:
		push_error("NavGridMap.load_chunk: cells must be PackedInt32Array.")
		return 0

	var packed: PackedInt32Array = packed_value

	if packed.size() % INTS_PER_BLOCK != 0:
		push_error("NavGridMap.load_chunk: malformed cell data size.")
		return 0

	var origin: Vector2i = chunk_origin(chunk)
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
			and y >= min_block_y
			and y <= max_block_y
		)

		if not in_range or not valid_items.has(item):
			skipped += 1
			continue

		var cell := Vector3i(
			origin.x + local_x,
			y,
			origin.y + local_z
		)

		_track_cell_values(cell, item, orientation)
		touched.append(cell)

	return skipped


## Version-2 loader: compressed 3D section blob.
func _load_section_cells(
	chunk: Vector2i,
	data: Dictionary,
	valid_items: PackedInt32Array,
	touched: Array[Vector3i]
) -> int:
	var blob_value: Variant = data.get("sections", PackedByteArray())

	if blob_value is not PackedByteArray:
		push_error("NavGridMap.load_chunk: sections must be PackedByteArray.")
		return 0

	var entries: Array[Dictionary] = VoxelSectionStoreScript.decode_column_compressed(
		chunk,
		blob_value
	)
	var skipped: int = 0

	for entry: Dictionary in entries:
		var cell: Vector3i = entry.get("position", Vector3i.ZERO)
		var item: int = int(entry.get("item", -1))
		var orientation: int = int(entry.get("orientation", 0))

		if cell.y < min_block_y or cell.y > max_block_y:
			skipped += 1
			continue

		if not valid_items.has(item):
			skipped += 1
			continue

		_track_cell_values(cell, item, orientation)
		touched.append(cell)

	return skipped


## Adds a loaded chunk's cells to the AStar graph. Use this when a chunk first
## enters the navigation radius of a streamed world.
func build_chunk_navigation(
	chunk: Vector2i,
	emit_nav_signal: bool = false
) -> void:
	if _nav_chunks.has(chunk):
		return

	var cells: Array[Vector3i] = _sections.get_column_cell_list(chunk)

	if cells.is_empty():
		return

	# This is an initial build, not an edit: add the chunk's walkable cells and
	# connect them to existing neighbours. Refreshing the full expanded region
	# here was ~134 ms per chunk because every cell recomputed 24 wall/gap
	# lookups. Only the chunk border needs a weight refresh for old neighbours.
	var origin: Vector2i = NavGridMap.chunk_origin(chunk)
	var border: Array[Vector3i] = []
	_nav_snapshot_begin()

	for cell: Vector3i in cells:
		var walkable: bool = _is_walkable(cell)
		var registered: bool = cell_to_id_map.has(cell)

		if walkable and not registered:
			_add_nav_cell(cell)
		elif not walkable and registered:
			_remove_nav_cell(cell)
		elif walkable and registered:
			_refresh_nav_cell(cell)

		var local_x: int = cell.x - origin.x
		var local_z: int = cell.z - origin.y

		if (
			local_x == 0
			or local_x == NavGridMap.CHUNK_SIZE - 1
			or local_z == 0
			or local_z == NavGridMap.CHUNK_SIZE - 1
		):
			border.append(cell)

	for cell: Vector3i in border:
		_refresh_point_weights_around(cell)

	# Re-check connections for the first ring outside the new chunk: a new block
	# at the border can invalidate a diagonal between two older nav points.
	var outer: Dictionary = {}

	for cell: Vector3i in border:
		for offset: Vector3i in [
			Vector3i.LEFT,
			Vector3i.RIGHT,
			Vector3i.FORWARD,
			Vector3i.BACK,
		]:
			var neighbor: Vector3i = cell + offset

			if cell_to_id_map.has(neighbor):
				outer[neighbor] = true

	if not outer.is_empty():
		var outer_cells: Array[Vector3i] = []
		for cell: Vector3i in outer:
			outer_cells.append(cell)
		_rebuild_nav_connections(outer_cells)

	_invalidate_flow_fields(cells)
	_nav_snapshot_end()

	_nav_chunks[chunk] = true

	if emit_nav_signal and not cells.is_empty():
		navigation_changed.emit(cells)


func is_chunk_navigation_loaded(chunk: Vector2i) -> bool:
	return _nav_chunks.has(chunk)


## Removes a chunk's blocks and navigation, e.g. when streaming it out.
## Does NOT save it first: if it is dirty, write it out before calling this.
func unload_chunk(
	chunk: Vector2i,
	emit_nav_signal: bool = false,
	clear_navigation: bool = true
) -> void:
	if _dirty_chunks.has(chunk):
		push_warning(
			"NavGridMap.unload_chunk: refusing to unload dirty chunk %s; save it first."
			% chunk
		)
		return

	var had_navigation: bool = _nav_chunks.has(chunk)
	var removed: Array[Vector3i] = _wipe_chunk(chunk)
	var affected: Array[Vector3i] = []

	if had_navigation and clear_navigation:
		affected = _refresh_nav_region(removed)

	_nav_chunks.erase(chunk)

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

	for chunk: Vector2i in _sections.get_column_chunks():
		chunks_to_save[chunk] = true

	for chunk: Vector2i in _dirty_chunks:
		chunks_to_save[chunk] = true

	var saved: int = 0

	for chunk: Vector2i in chunks_to_save:
		if writer.call(chunk, serialize_chunk(chunk)):
			_dirty_chunks.erase(chunk)
			saved += 1

	return saved


## Clears every block in a chunk from the packed index. Returns the cells that
## were removed so the caller can refresh navigation for them.
func _wipe_chunk(chunk: Vector2i) -> Array[Vector3i]:
	var removed: Array[Vector3i] = _sections.get_column_cell_list(chunk)

	if _grid_mirror_enabled:
		for key: Vector3i in removed:
			set_cell_item(key, GridMap.INVALID_CELL_ITEM)

	_sections.clear_column(chunk)
	_chunk_min_y.erase(chunk)

	return removed


## Batch version of _refresh_nav_around. Call it AFTER all the blocks are already set,
## so walkability and connection checks see the final state.
## Full navigation parameter set for experiment metadata.
## Replaces the authored corridor layer and refreshes the A* point weights.
## Called by RoutePainter after a paint/erase or when a save's authored routes
## are loaded. The cells are walkable nav cells, not new blocks.
func set_authored_route_cells(cells: Array) -> void:
	authored_route_cells.clear()
	var changed_cells: Array[Vector3i] = []

	for value: Variant in cells:
		var cell: Vector3i

		if value is Vector3i:
			cell = value
		elif value is Array and (value as Array).size() >= 3:
			cell = Vector3i(int(value[0]), int(value[1]), int(value[2]))
		else:
			continue

		if not cell_to_id_map.has(cell):
			continue

		authored_route_cells[cell] = true
		changed_cells.append(cell)

	for cell: Vector3i in cell_to_id_map:
		_apply_nav_point_weight(cell)

	if not changed_cells.is_empty():
		navigation_changed.emit(changed_cells)


func get_navigation_parameters() -> Dictionary:
	return {
		"cell_size": [cell_size.x, cell_size.y, cell_size.z],
		"wall_penalty_max": wall_penalty_max,
		"gap_penalty_max": gap_penalty_max,
		"stair_path_cost": stair_path_cost,
		"slab_path_cost": slab_path_cost,
		"full_block_path_cost": full_block_path_cost,
		"authored_route_cost_scale": authored_route_cost_scale,
		"authored_route_cell_count": authored_route_cells.size(),
		"path_ground_radius": path_ground_radius,
		"smoothing_max_lookahead": smoothing_max_lookahead,
		"path_budget_usec": path_budget_usec,
		"wall_repulsion_a": wall_repulsion_a,
		"wall_repulsion_b": wall_repulsion_b,
		"wall_query_radius": wall_query_radius,
		"wall_force_enabled": wall_force_enabled,
		"enable_flow_fields": enable_flow_fields,
		"flow_field_max_cache": flow_field_max_cache,
		"flow_field_max_cells": flow_field_max_cells,
		"flow_bake_budget_usec": flow_bake_budget_usec,
		"lane_taper_distance": lane_taper_distance,
		"lane_sample_spacing": lane_sample_spacing,
		"lane_wall_margin": lane_wall_margin,
		"lane_max_gap_exposure": lane_max_gap_exposure,
		"enable_congestion_routing": enable_congestion_routing,
		"congestion_penalty_max": congestion_penalty_max,
		"congestion_heat_per_report": congestion_heat_per_report,
		"congestion_decay_per_sec": congestion_decay_per_sec,
		"congestion_spread_radius": congestion_spread_radius,
		"congestion_tick_interval": congestion_tick_interval,
		"congestion_max_cells": congestion_max_cells,
	}


## Compact navigation-graph state for the recorder/comparer: node count, edge
## count, connected components and largest component. Full connectivity is
## skipped above MAX_CONNECTIVITY_NODES so a huge map cannot stall a run.
const MAX_CONNECTIVITY_NODES: int = 50000


func get_connectivity_snapshot() -> Dictionary:
	var ids: PackedInt64Array = astar.get_point_ids()
	var node_count: int = ids.size()
	var edge_count: int = 0

	for id: int in ids:
		edge_count += astar.get_point_connections(id).size()

	edge_count >>= 1

	if node_count == 0:
		return {
			"nodes": 0,
			"edges": 0,
			"components": 0,
			"largest_component": 0,
			"computed": true,
		}

	if node_count > MAX_CONNECTIVITY_NODES:
		return {
			"nodes": node_count,
			"edges": edge_count,
			"components": -1,
			"largest_component": -1,
			"computed": false,
		}

	var seen: Dictionary = {}
	var components: int = 0
	var largest: int = 0

	for id: int in ids:
		if seen.has(id):
			continue

		components += 1
		var stack: Array[int] = [id]
		var size: int = 0
		seen[id] = true

		while not stack.is_empty():
			var current: int = stack.pop_back()
			size += 1

			for neighbour: int in astar.get_point_connections(current):
				if seen.has(neighbour):
					continue
				seen[neighbour] = true
				stack.append(neighbour)

		largest = maxi(largest, size)

	return {
		"nodes": node_count,
		"edges": edge_count,
		"components": components,
		"largest_component": largest,
		"computed": true,
	}


## Full graph dump for the future comparer. Nodes are [id, cell.x, cell.y,
## cell.z]; edges are unique [id_a, id_b] pairs. Truncated past `max_edges`.
func get_nav_graph_snapshot(max_edges: int = 20000) -> Dictionary:
	var ids: PackedInt64Array = astar.get_point_ids()
	var nodes: Array = []
	var edges: Array = []
	var truncated: bool = false

	for id: int in ids:
		var cell: Vector3i = _id_to_cell.get(id, NO_CELL)

		if cell == NO_CELL:
			continue

		nodes.append([id, cell.x, cell.y, cell.z])

	for id: int in ids:
		for neighbour: int in astar.get_point_connections(id):
			if neighbour <= id:
				continue

			if edges.size() >= max_edges:
				truncated = true
				break

			edges.append([id, neighbour])

		if truncated:
			break

	return {
		"nodes": nodes,
		"edges": edges,
		"node_count": nodes.size(),
		"edge_count": edges.size(),
		"truncated": truncated,
	}


func _refresh_nav_region(cells: Array[Vector3i]) -> Array[Vector3i]:
	var start_usec: int = Time.get_ticks_usec()
	var result: Array[Vector3i] = _expand_nav_affected(cells)

	for cell: Vector3i in result:
		_refresh_nav_cell(cell)

	_rebuild_nav_connections(result)

	for cell: Vector3i in cells:
		_refresh_point_weights_around(cell)

	_invalidate_flow_fields(result)
	last_nav_refresh_usec = Time.get_ticks_usec() - start_usec
	last_nav_refresh_cells = result.size()
	nav_refresh_total_usec += last_nav_refresh_usec
	nav_refresh_count += 1
	nav_refresh_measured.emit(last_nav_refresh_usec, last_nav_refresh_cells)
	return result
