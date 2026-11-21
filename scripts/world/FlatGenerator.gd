class_name FlatGenerator
extends "res://scripts/world/WorldGenerator.gd"

## Reproduces the shipped starter platform (and the previous
## `ChunkStreamer._make_flat_chunk` behaviour) through the generator interface.
##
## Defaults match `Maps/test.tscn`: a 10 x 8 floor at y = 0, item 44, spanning
## x = -5..4 and z = -3..4 (80 cells). Set `infinite` for an unbounded plane.

enum Fill { SINGLE_LAYER, SOLID_COLUMN }

@export var floor_y: int = 0
@export var surface_item: int = 44
@export var origin_x: int = -5
@export var origin_z: int = -3
@export var size_x: int = 10
@export var size_z: int = 8
@export var infinite: bool = false
@export var fill: Fill = Fill.SINGLE_LAYER
@export var column_depth: int = 1


func get_id() -> String:
	return "flat_v1"


func get_version() -> int:
	return 1


func get_params() -> Dictionary:
	return {
		"noise_seed": noise_seed,
		"floor_y": floor_y,
		"surface_item": surface_item,
		"origin_x": origin_x,
		"origin_z": origin_z,
		"size_x": size_x,
		"size_z": size_z,
		"infinite": infinite,
		"fill": int(fill),
		"column_depth": column_depth,
	}


func apply_params(params: Dictionary) -> void:
	super.apply_params(params)
	floor_y = int(params.get("floor_y", floor_y))
	surface_item = int(params.get("surface_item", surface_item))
	origin_x = int(params.get("origin_x", origin_x))
	origin_z = int(params.get("origin_z", origin_z))
	size_x = int(params.get("size_x", size_x))
	size_z = int(params.get("size_z", size_z))
	infinite = bool(params.get("infinite", infinite))
	fill = int(params.get("fill", fill))
	column_depth = maxi(1, int(params.get("column_depth", column_depth)))


func covers(x: int, z: int) -> bool:
	if infinite:
		return true

	return (
		x >= origin_x
		and x < origin_x + size_x
		and z >= origin_z
		and z < origin_z + size_z
	)


func get_footprint_chunk_count() -> int:
	if infinite:
		return 0

	var rect := get_footprint_chunk_rect()
	return rect.size.x * rect.size.y


func get_footprint_chunk_rect() -> Rect2i:
	if infinite or size_x <= 0 or size_z <= 0:
		return Rect2i()

	var min_chunk := Vector2i(
		floori(float(origin_x) / 16.0),
		floori(float(origin_z) / 16.0)
	)
	var max_chunk := Vector2i(
		floori(float(origin_x + size_x - 1) / 16.0),
		floori(float(origin_z + size_z - 1) / 16.0)
	)

	return Rect2i(min_chunk, max_chunk - min_chunk + Vector2i.ONE)


func sample_column(x: int, z: int) -> Dictionary:
	if not covers(x, z):
		return {}

	# `height` is the top of the column: the walkable block.
	return {
		"height": floor_y,
		"surface_item": surface_item,
		"orientation": 0,
		"depth": column_depth if fill == Fill.SOLID_COLUMN else 1,
	}


## Emits the platform cells directly. A flat generator has no need for the
## sample_column adapter's per-column allocation, and a solid column needs more
## than one cell per column.
func generate_column(
	chunk: Vector2i,
	context: Dictionary = {}
) -> Array:
	var result: Array = []
	var chunk_size: int = int(context.get("chunk_size", 16))
	var min_y: int = int(context.get("min_y", -256))
	var max_y: int = int(context.get("max_y", 255))
	var origin: Vector2i = chunk * chunk_size
	var depth: int = column_depth if fill == Fill.SOLID_COLUMN else 1

	for local_x in chunk_size:
		for local_z in chunk_size:
			var world_x: int = origin.x + local_x
			var world_z: int = origin.y + local_z

			if not covers(world_x, world_z):
				continue

			for step in depth:
				var y: int = floor_y - step

				if y < min_y or y > max_y:
					continue

				result.append({
					"position": Vector3i(world_x, y, world_z),
					"item": surface_item,
					"orientation": 0,
				})

	return result
