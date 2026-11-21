@tool
class_name ChunkStreamer
extends Node

const CHUNK_STORE = preload("res://scripts/world/ChunkFileStore.gd")

## Budgeted chunk streaming around the player.
##
## Loaded chunk data lives in NavGridMap. Only chunks near the player are
## meshed and only chunks near the player are added to the navigation graph;
## chunks farther out stay as data until the view reaches them.

@export var player_path: NodePath = NodePath("../Player")
@export var grid_path: NodePath = NodePath("../GridMap")

@export_group("Ranges")
### Chunk columns loaded around the player. 20 means 20 * 16 blocks.
@export var load_radius_chunks: int = 20
## Extra distance a chunk may stay loaded before it is unloaded.
@export var unload_radius_chunks: int = 22
## Chunks farther than this are not meshed.
@export var mesh_radius_chunks: int = 8
## Chunks farther than this are not added to the AStar graph.
@export var nav_radius_chunks: int = 4
## Missing chunks inside this radius receive a generated flat floor.
@export var generation_radius_chunks: int = 4

@export_group("Budgets")
@export var max_chunk_loads_per_frame: int = 3
@export var max_chunk_unloads_per_frame: int = 8
@export var max_nav_builds_per_frame: int = 2
@export var load_budget_usec: int = 2000
@export var scan_interval: float = 0.25
## Safety ceiling. 0 means unlimited; a finite ceiling prevents a huge
## requested radius from exhausting memory before the player ever reaches it.
@export var max_loaded_chunks: int = 2048

@export_group("Generation")
## Disabled for now: missing chunks stay empty instead of receiving a flat floor.
@export var generate_flat_floor: bool = false
@export var floor_item: int = 44
@export var floor_y: int = 0
@export var min_block_y: int = -256
@export var max_block_y: int = 255
@export var chunk_store_dir: String = "user://world/chunks"
@export var protect_initial_chunks: bool = true

@export_group("Editor Preview")
## Show saved chunks in the editor viewport. The preview is an internal node,
## so it is not serialized into the scene and does not modify the GridMap data.
@export var editor_show_saved_chunks: bool = true
## Safety cap for the editor preview; 0 means no cap.
@export var editor_preview_max_chunks: int = 256
## How often editor edits are written back to the chunk store.
@export var editor_save_interval: float = 0.5

var _player: Node3D = null
var _grid: NavGridMap = null
var _mesher: ChunkMesher = null
var _store = null
var _floor_item: int = 44
var _editor_preview: GridMap = null
var _editor_chunk_signatures: Dictionary = {}
var _editor_preview_ready: bool = false
var _editor_save_timer: float = 0.0

var _saved: Dictionary = {}
var _loaded: Dictionary = {}
var _protected: Dictionary = {}
var _generated: Dictionary = {}
var _floor_filled: Dictionary = {}

var _desired: Dictionary = {}
var _load_queue: Array[Vector2i] = []
var _unload_queue: Array[Vector2i] = []
var _nav_queue: Array[Vector2i] = []

var _last_center: Vector2i = Vector2i.ZERO
var _view_initialized: bool = false
var _scan_timer: float = 0.0
var _cap_warned: bool = false


func _ready() -> void:
	add_to_group("chunk_streamer")
	_player = get_node_or_null(player_path) as Node3D
	_grid = get_node_or_null(grid_path) as NavGridMap

	if Engine.is_editor_hint():
		call_deferred("_setup_editor_preview")
		return

	if _player == null or _grid == null:
		push_warning(
			"ChunkStreamer: player or grid path is invalid; streaming disabled."
		)
		set_process(false)
		return

	_store = CHUNK_STORE.new(chunk_store_dir)
	_saved = _store.list_chunks()
	_mesher = _grid.get_mesher()
	_floor_item = _resolve_floor_item()

	for chunk: Vector2i in _grid.get_populated_chunks():
		# A saved chunk is the authoritative version of that chunk. This lets
		# editor edits override the scene's starter cells on the next run.
		if _saved.has(chunk):
			continue

		_loaded[chunk] = true
		if protect_initial_chunks:
			_protected[chunk] = true

	_update_view(true)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if is_instance_valid(_editor_preview) and _grid != null:
			_editor_preview.global_transform = _grid.global_transform
			_editor_save_timer -= delta

			if _editor_save_timer <= 0.0:
				_editor_save_timer = maxf(editor_save_interval, 0.1)
				_save_editor_preview_changes()
		return

	_scan_timer -= delta

	if _scan_timer <= 0.0:
		_scan_timer = maxf(scan_interval, 0.05)
		_update_view(false)

	_pump_loads()
	_pump_unloads()
	_pump_nav()


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		_save_editor_preview_changes(true)
		if _grid != null:
			_grid.visible = true
		if is_instance_valid(_editor_preview):
			_editor_preview.queue_free()
		_editor_preview = null
		_editor_preview_ready = false
		return

	# Quitting no longer flushes the live world. The player saves explicitly
	# from the pause menu; streamed chunk unloads still save normally.
	pass


## Stops this streamer from processing while the scene is replaced by
## SaveManager, so it cannot flush chunks into the live store mid-load.
func prepare_for_scene_reload() -> void:
	set_process(false)
	set_physics_process(false)


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return

	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_save_editor_preview_changes(true)
		# Do not serialize the main GridMap as hidden just because the editor
		# preview replaced it in the viewport.
		if _grid != null:
			_grid.visible = true
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		if _grid != null and is_instance_valid(_editor_preview):
			_grid.visible = false


## Editor-only world preview. The preview GridMap contains the scene cells plus
## saved chunks, and the main GridMap is hidden while editing. Edits are written
## back to the chunk store by the polling saver. The preview is ownerless, so it
## is never serialized into the scene.
func _setup_editor_preview() -> void:
	_editor_preview_ready = false
	_editor_chunk_signatures.clear()
	_editor_save_timer = maxf(editor_save_interval, 0.1)

	if is_instance_valid(_editor_preview):
		_editor_preview.queue_free()
		_editor_preview = null
	if _grid != null:
		_grid.visible = true

	if (
		not editor_show_saved_chunks
		or not is_inside_tree()
		or _grid == null
		or _grid.mesh_library == null
	):
		return

	_store = CHUNK_STORE.new(chunk_store_dir)
	var saved: Dictionary = _store.list_chunks() if _store != null else {}

	var preview := GridMap.new()
	preview.name = "EditorSavedChunks"
	preview.mesh_library = _grid.mesh_library
	preview.cell_size = _grid.cell_size
	preview.cell_scale = _grid.cell_scale
	preview.cell_octant_size = _grid.cell_octant_size
	preview.collision_layer = 0
	preview.collision_mask = 0
	# A normal child (not internal) so the GridMap editor can select and edit it.
	add_child(preview)
	preview.owner = null # ownerless, so it is not serialized with the scene
	preview.global_transform = _grid.global_transform
	_editor_preview = preview

	var valid_items: PackedInt32Array = preview.mesh_library.get_item_list()

	# Start with the scene cells; saved chunks overwrite them below.
	for cell: Vector3i in _grid.get_used_cells():
		var item: int = _grid.get_cell_item(cell)
		if valid_items.has(item):
			preview.set_cell_item(
				cell,
				item,
				_grid.get_cell_item_orientation(cell)
			)

	var chunks_loaded: int = 0
	for chunk: Vector2i in saved:
		if editor_preview_max_chunks > 0 and chunks_loaded >= editor_preview_max_chunks:
			break

		var data: Dictionary = _store.load_chunk(chunk)
		if not data.is_empty():
			_apply_saved_chunk_to_preview(preview, data, valid_items)
			chunks_loaded += 1

	_grid.visible = false
	_snapshot_editor_chunks()
	_editor_preview_ready = true

	if Engine.is_editor_hint():
		call_deferred("_select_editor_preview")


func _select_editor_preview() -> void:
	if not Engine.is_editor_hint() or not is_instance_valid(_editor_preview):
		return

	# Resolve dynamically so an exported build never needs the editor singleton
	# to exist at compile time.
	var editor_interface = Engine.get_singleton("EditorInterface")
	if editor_interface == null:
		return

	var selection = editor_interface.get_selection()
	if selection != null:
		selection.clear()
		selection.add_node(_editor_preview)


func _apply_saved_chunk_to_preview(
	preview: GridMap,
	data: Dictionary,
	valid_items: PackedInt32Array
) -> int:
	if int(data.get("version", 0)) != NavGridMap.CHUNK_DATA_VERSION:
		return 0

	var packed_value: Variant = data.get("cells", PackedInt32Array())
	if packed_value is not PackedInt32Array:
		return 0

	var packed: PackedInt32Array = packed_value
	var chunk := Vector2i(
		int(data.get("chunk_x", 0)),
		int(data.get("chunk_z", 0))
	)
	var origin: Vector2i = NavGridMap.chunk_origin(chunk)
	var stride: int = NavGridMap.INTS_PER_BLOCK
	var placed: int = 0

	for index in range(0, packed.size() - stride + 1, stride):
		var cell := Vector3i(
			origin.x + packed[index],
			packed[index + 1],
			origin.y + packed[index + 2]
		)
		var item: int = packed[index + 3]

		if not valid_items.has(item):
			continue

		preview.set_cell_item(cell, item, packed[index + 4])
		placed += 1

	return placed


func _editor_cells_by_chunk() -> Dictionary:
	var result: Dictionary = {}

	if not is_instance_valid(_editor_preview):
		return result

	for cell: Vector3i in _editor_preview.get_used_cells():
		var chunk: Vector2i = NavGridMap.cell_to_chunk(cell)

		if not result.has(chunk):
			result[chunk] = []

		result[chunk].append(cell)

	for chunk: Vector2i in result:
		result[chunk].sort_custom(
			func(a: Vector3i, b: Vector3i) -> bool:
				if a.x != b.x:
					return a.x < b.x
				if a.y != b.y:
					return a.y < b.y
				return a.z < b.z
		)

	return result


func _editor_chunk_signature(preview: GridMap, cells: Array) -> int:
	var stride: int = NavGridMap.INTS_PER_BLOCK
	var packed := PackedInt32Array()
	packed.resize(cells.size() * stride)
	var index: int = 0

	for cell: Vector3i in cells:
		packed[index] = cell.x
		packed[index + 1] = cell.y
		packed[index + 2] = cell.z
		packed[index + 3] = preview.get_cell_item(cell)
		packed[index + 4] = preview.get_cell_item_orientation(cell)
		index += stride

	return hash(packed)


func _snapshot_editor_chunks() -> void:
	_editor_chunk_signatures.clear()
	var cells_by_chunk: Dictionary = _editor_cells_by_chunk()

	for chunk: Vector2i in cells_by_chunk:
		_editor_chunk_signatures[chunk] = _editor_chunk_signature(
			_editor_preview,
			cells_by_chunk[chunk]
		)


func _save_editor_preview_changes(force: bool = false) -> void:
	if (
		not is_instance_valid(_editor_preview)
		or _store == null
		or (not _editor_preview_ready and not force)
	):
		return

	var cells_by_chunk: Dictionary = _editor_cells_by_chunk()
	var chunks: Dictionary = {}

	for chunk: Vector2i in cells_by_chunk:
		chunks[chunk] = true

	for chunk: Vector2i in _editor_chunk_signatures:
		chunks[chunk] = true

	for chunk: Vector2i in chunks:
		var cells: Array = cells_by_chunk.get(chunk, [])
		var signature: int = _editor_chunk_signature(_editor_preview, cells)

		if _editor_chunk_signatures.get(chunk, null) == signature:
			continue

		var data := _serialize_editor_chunk(chunk, cells)

		if _store.save_chunk(chunk, data):
			_editor_chunk_signatures[chunk] = signature


func _serialize_editor_chunk(chunk: Vector2i, cells: Array) -> Dictionary:
	var origin: Vector2i = NavGridMap.chunk_origin(chunk)
	var stride: int = NavGridMap.INTS_PER_BLOCK
	var packed := PackedInt32Array()
	packed.resize(cells.size() * stride)
	var index: int = 0

	for cell: Vector3i in cells:
		packed[index] = cell.x - origin.x
		packed[index + 1] = cell.y
		packed[index + 2] = cell.z - origin.y
		packed[index + 3] = _editor_preview.get_cell_item(cell)
		packed[index + 4] = _editor_preview.get_cell_item_orientation(cell)
		index += stride

	return {
		"version": NavGridMap.CHUNK_DATA_VERSION,
		"chunk_x": chunk.x,
		"chunk_z": chunk.y,
		"cells": packed,
	}


func refresh_view() -> void:
	_update_view(true)


func get_stats() -> Dictionary:
	return {
		"center": _last_center,
		"desired": _desired.size(),
		"loaded": _loaded.size(),
		"saved": _saved.size(),
		"load_queue": _load_queue.size(),
		"unload_queue": _unload_queue.size(),
		"nav_queue": _nav_queue.size(),
		"generation_radius": generation_radius_chunks,
		"mesh_radius": mesh_radius_chunks,
		"nav_radius": nav_radius_chunks,
	}


func save_dirty_loaded() -> int:
	if not is_instance_valid(_grid) or _store == null:
		return 0

	var saved: int = 0

	for chunk: Vector2i in _loaded.keys():
		if not _grid.is_chunk_dirty(chunk):
			continue

		if _store.save_chunk(chunk, _grid.serialize_chunk(chunk)):
			_grid.mark_chunk_clean(chunk)
			_saved[chunk] = true
			saved += 1

	return saved


# ---------------------------------------------------------------------------
# View / queues
# ---------------------------------------------------------------------------

func _update_view(force: bool) -> void:
	if _player == null or _grid == null:
		return

	var center: Vector2i = _grid.position_to_chunk(_player.global_position)

	if not force and _view_initialized and center == _last_center:
		return

	_last_center = center
	_view_initialized = true

	if _mesher != null:
		_mesher.set_view_center(center, mesh_radius_chunks)

	_rebuild_desired(center)
	_rebuild_load_queue(center)
	_rebuild_unload_queue(center)
	_rebuild_nav_queue(center)
	_fill_protected_floors(center)


## Re-evaluates radii/queues immediately, e.g. after the pause menu changes the
## draw distance while the player is standing still.
func refresh_streaming() -> void:
	_scan_timer = 0.0
	_update_view(true)


## Writes every populated/dirty chunk to the chunk store. Used by SaveManager
## before copying the live folder into a save slot.
func flush_world() -> int:
	if _grid == null or _store == null:
		return 0
	var saved: int = _grid.save_all_chunks(Callable(_store, "save_chunk"))
	for chunk in _store.list_chunks():
		_saved[chunk] = true
	return saved


func get_chunk_store_dir() -> String:
	return chunk_store_dir


func _rebuild_desired(center: Vector2i) -> void:
	_desired.clear()
	var radius: int = maxi(load_radius_chunks, 0)
	var radius_sq: int = radius * radius

	for x in range(-radius, radius + 1):
		for z in range(-radius, radius + 1):
			if x * x + z * z <= radius_sq:
				_desired[Vector2i(center.x + x, center.y + z)] = true


func _rebuild_load_queue(center: Vector2i) -> void:
	_load_queue.clear()

	for chunk: Vector2i in _desired:
		if _loaded.has(chunk):
			continue

		if _saved.has(chunk) or _should_generate(chunk, center):
			_load_queue.append(chunk)

	_load_queue.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return _chunk_distance_sq(a, center) < _chunk_distance_sq(b, center)
	)


func _rebuild_unload_queue(center: Vector2i) -> void:
	_unload_queue.clear()
	var radius_sq: int = unload_radius_chunks * unload_radius_chunks

	for chunk: Vector2i in _loaded:
		if _protected.has(chunk):
			continue

		if _chunk_distance_sq(chunk, center) > radius_sq:
			_unload_queue.append(chunk)


func _rebuild_nav_queue(center: Vector2i) -> void:
	_nav_queue.clear()
	var radius_sq: int = nav_radius_chunks * nav_radius_chunks

	for chunk: Vector2i in _loaded:
		if _chunk_distance_sq(chunk, center) > radius_sq:
			continue

		if not _grid.is_chunk_navigation_loaded(chunk):
			_nav_queue.append(chunk)


func _fill_protected_floors(center: Vector2i) -> void:
	if not generate_flat_floor:
		return

	var radius_sq: int = generation_radius_chunks * generation_radius_chunks

	for chunk: Vector2i in _protected:
		if _chunk_distance_sq(chunk, center) > radius_sq:
			continue

		if _floor_filled.has(chunk):
			continue

		_fill_floor(chunk)
		_floor_filled[chunk] = true


# ---------------------------------------------------------------------------
# Load / unload / navigation pumps
# ---------------------------------------------------------------------------

func _pump_loads() -> void:
	if max_loaded_chunks > 0 and _loaded.size() >= max_loaded_chunks:
		_load_queue.clear()

		if not _cap_warned:
			_cap_warned = true
			push_warning(
				"ChunkStreamer: max_loaded_chunks (%d) reached; "
				+ "increase it or reduce load_radius_chunks."
				% max_loaded_chunks
			)
		return

	var start_usec: int = Time.get_ticks_usec()
	var loaded_count: int = 0

	while (
		not _load_queue.is_empty()
		and loaded_count < max_chunk_loads_per_frame
	):
		var chunk: Vector2i = _load_queue.pop_front()

		if _loaded.has(chunk) or not _desired.has(chunk):
			continue

		var data: Dictionary = {}

		if _saved.has(chunk):
			data = _store.load_chunk(chunk)

		if data.is_empty():
			if not _should_generate(chunk, _last_center):
				continue

			data = _make_flat_chunk(chunk)

			if data.is_empty():
				continue

			_generated[chunk] = true

		var build_navigation: bool = (
			_chunk_distance_sq(chunk, _last_center)
			<= nav_radius_chunks * nav_radius_chunks
		)

		_grid.load_chunk(data, false, build_navigation)
		_loaded[chunk] = true
		loaded_count += 1

		if Time.get_ticks_usec() - start_usec >= load_budget_usec:
			break


func _pump_unloads() -> void:
	var count: int = 0

	while (
		not _unload_queue.is_empty()
		and count < max_chunk_unloads_per_frame
	):
		var chunk: Vector2i = _unload_queue.pop_front()

		if not _loaded.has(chunk) or _desired.has(chunk):
			continue

		if _chunk_distance_sq(chunk, _last_center) <= (
			unload_radius_chunks * unload_radius_chunks
		):
			continue

		if _grid.is_chunk_dirty(chunk):
			if _store.save_chunk(chunk, _grid.serialize_chunk(chunk)):
				_grid.mark_chunk_clean(chunk)
				_saved[chunk] = true

		_grid.unload_chunk(
			chunk,
			false,
			_grid.is_chunk_navigation_loaded(chunk)
		)
		_loaded.erase(chunk)
		_generated.erase(chunk)
		_floor_filled.erase(chunk)
		count += 1


func _pump_nav() -> void:
	var start_usec: int = Time.get_ticks_usec()
	var count: int = 0

	while not _nav_queue.is_empty() and count < max_nav_builds_per_frame:
		var chunk: Vector2i = _nav_queue.pop_front()

		if not _loaded.has(chunk):
			continue

		if _grid.is_chunk_navigation_loaded(chunk):
			continue

		if _chunk_distance_sq(chunk, _last_center) > (
			nav_radius_chunks * nav_radius_chunks
		):
			continue

		_grid.build_chunk_navigation(chunk)
		count += 1

		if Time.get_ticks_usec() - start_usec >= load_budget_usec:
			break


# ---------------------------------------------------------------------------
# Generated chunks
# ---------------------------------------------------------------------------

func _should_generate(chunk: Vector2i, center: Vector2i) -> bool:
	if not generate_flat_floor:
		return false

	if floor_y < min_block_y or floor_y > max_block_y:
		return false

	return _chunk_distance_sq(chunk, center) <= (
		generation_radius_chunks * generation_radius_chunks
	)


func _resolve_floor_item() -> int:
	if _grid == null or _grid.mesh_library == null:
		return floor_item

	var items: PackedInt32Array = _grid.mesh_library.get_item_list()

	if items.has(floor_item):
		return floor_item

	if items.is_empty():
		return floor_item

	return int(items[0])


func _make_flat_chunk(chunk: Vector2i) -> Dictionary:
	if not generate_flat_floor:
		return {}

	if floor_y < min_block_y or floor_y > max_block_y:
		return {}

	var packed := PackedInt32Array()
	var cells: int = NavGridMap.CHUNK_SIZE * NavGridMap.CHUNK_SIZE
	packed.resize(cells * NavGridMap.INTS_PER_BLOCK)

	var index: int = 0

	for x in NavGridMap.CHUNK_SIZE:
		for z in NavGridMap.CHUNK_SIZE:
			packed[index] = x
			packed[index + 1] = floor_y
			packed[index + 2] = z
			packed[index + 3] = _floor_item
			packed[index + 4] = 0
			index += NavGridMap.INTS_PER_BLOCK

	return {
		"version": NavGridMap.CHUNK_DATA_VERSION,
		"chunk_x": chunk.x,
		"chunk_z": chunk.y,
		"cells": packed,
	}


func _fill_floor(chunk: Vector2i) -> void:
	if _grid == null or not generate_flat_floor:
		return

	if floor_y < min_block_y or floor_y > max_block_y:
		return

	var origin: Vector2i = NavGridMap.chunk_origin(chunk)
	var missing: Array[Vector3i] = []

	for x in NavGridMap.CHUNK_SIZE:
		for z in NavGridMap.CHUNK_SIZE:
			var cell := Vector3i(
				origin.x + x,
				floor_y,
				origin.y + z
			)

			if not _grid.has_block(cell):
				missing.append(cell)

	if not missing.is_empty():
		_grid.place_blocks(missing, _floor_item, 0)


func _chunk_distance_sq(a: Vector2i, b: Vector2i) -> int:
	var dx: int = a.x - b.x
	var dz: int = a.y - b.y
	return dx * dx + dz * dz
