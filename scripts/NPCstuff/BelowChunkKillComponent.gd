class_name BelowChunkKillComponent
extends Node

## Deletes the body when it falls below the lowest block of its current chunk.
##
## Mirrors Member's fall handling: a chunk whose collision is not built yet
## (for example a streamed-out chunk) is ignored, so a missing chunk is not
## mistaken for a fall out of the world. While a chunk is streamed out, the
## body is frozen and hidden instead (the animal is not in the "npc" group, so
## ChunkStreamer would not otherwise suspend it).
##
## The check is staggered per instance and runs a few times per second, so it
## stays cheap on large herds and does not add a per-tick physics query.

signal killed

@export var body: Node3D
@export var grid_group: StringName = &"grid_map"
@export_range(0.05, 2.0, 0.05) var check_interval: float = 0.25
## Blocks below the chunk's lowest block before the body is killed.
@export var margin_blocks: float = 5.0

var _timer: float = 0.0
var _grid: NavGridMap = null
var _next_grid_lookup_frame: int = 0
var _killed: bool = false
var _streamer: ChunkStreamer = null
var _next_streamer_lookup_frame: int = 0
var _suspended: bool = false
var _body_physics_was_enabled: bool = true
var _body_process_was_enabled: bool = true


func _ready() -> void:
	if body == null:
		body = get_parent() as Node3D
	# Stagger checks so a large herd never queries the grid on the same tick.
	_timer = randf() * maxf(check_interval, 0.05)


func _physics_process(delta: float) -> void:
	if _killed:
		return

	if body == null or not is_instance_valid(body):
		set_physics_process(false)
		return

	_timer -= delta
	if _timer > 0.0:
		return
	_timer = maxf(check_interval, 0.05)

	var grid := _get_grid()
	if grid == null:
		return

	var chunk := grid.position_to_chunk(body.global_position)
	var streamer := _get_streamer()

	# Chunk streaming: freeze/hide instead of falling through the missing floor.
	# This mirrors what ChunkStreamer does for Members without adding the animal
	# to the "npc" group (which would put it in the evacuation/agent systems).
	if streamer != null and not streamer.is_chunk_loaded(chunk):
		_set_suspended(true)
		return

	if _suspended:
		_set_suspended(false)

	if _is_below_floor(grid, chunk):
		_kill()


func _get_grid() -> NavGridMap:
	if is_instance_valid(_grid):
		return _grid

	# When the grid is missing (tests, menus), only retry once per second.
	var frame := Engine.get_physics_frames()
	if frame < _next_grid_lookup_frame:
		return null
	_next_grid_lookup_frame = frame + 60

	_grid = get_tree().get_first_node_in_group(grid_group) as NavGridMap
	return _grid


func _get_streamer() -> ChunkStreamer:
	if is_instance_valid(_streamer):
		return _streamer

	var frame := Engine.get_physics_frames()
	if frame < _next_streamer_lookup_frame:
		return null
	_next_streamer_lookup_frame = frame + 60

	_streamer = get_tree().get_first_node_in_group("chunk_streamer") as ChunkStreamer
	return _streamer


## Freezes and hides the body while its chunk is streamed out, then restores
## the exact processing state it had before.
func _set_suspended(value: bool) -> void:
	if _suspended == value:
		return
	_suspended = value

	if body == null or not is_instance_valid(body):
		return

	if value:
		_body_physics_was_enabled = body.is_physics_processing()
		_body_process_was_enabled = body.is_processing()
		if body is CharacterBody3D:
			(body as CharacterBody3D).velocity = Vector3.ZERO
		body.visible = false
		body.set_physics_process(false)
		body.set_process(false)
	else:
		body.visible = true
		body.set_physics_process(_body_physics_was_enabled)
		body.set_process(_body_process_was_enabled)


func _is_below_floor(grid: NavGridMap, chunk: Vector2i) -> bool:
	var position := body.global_position

	if not grid.has_chunk_collision(chunk):
		return false

	var lowest_y := grid.get_chunk_lowest_block_y(chunk)

	# An empty chunk has no local floor; use the world's zero level so bodies
	# that fall out of the map still die instead of falling forever.
	if lowest_y == NavGridMap.NO_CHUNK_FLOOR:
		lowest_y = 0

	var floor_y := grid.to_global(
		grid.map_to_local(Vector3i(0, lowest_y, 0))
	).y
	var kill_y := floor_y - margin_blocks * grid.cell_size.y
	return position.y < kill_y


func _kill() -> void:
	_killed = true
	killed.emit()

	if body != null and is_instance_valid(body):
		body.queue_free()
