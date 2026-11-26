class_name WorldGenerator
extends Resource

## Base class for one procedural generation stage.
##
## A generator is pure: given the same seed and coordinates it must return the
## same output, regardless of call order or which thread calls it. Do not draw
## from a shared RNG and do not read the scene tree. That is what makes worlds
## reproducible, edit-diffable and safe to run on a worker thread.
##
## Two entry points:
##   sample_column(x, z)  -> height map style output (one surface per column)
##   generate_column()    -> default adapter that turns columns into cell entries
##
## Volumetric generators can override `generate_column` and emit any cells they
## like (buildings, caves, overhangs). `generate_section` is reserved for a
## future section-native path and is not required.

const BLOCK_IDS = preload("res://scripts/world/block_ids.gd")

@export var noise_seed: int = 0

@export_group("Bedrock")
## Bedrock is the structural anchor every generated world ends on. It is
## emitted as one non-optional block directly under the lowest generated cell of
## each column, so no column starts unsupported.
@export var bedrock_enabled: bool = true
## Explicit item id. Leave -1 to resolve `bedrock_block` by name.
@export var bedrock_item: int = -1
## Block name resolved through BlockIds ("bedrock" -> Auto_bedrock).
@export var bedrock_block: String = "bedrock"

var _bedrock_resolved: int = -2


## Stable identity. A save pins this string plus `get_version()` and the params.
func get_id() -> String:
	return "world_generator_base"


func get_version() -> int:
	return 1


func get_params() -> Dictionary:
	return {
		"noise_seed": noise_seed,
		"bedrock_enabled": bedrock_enabled,
		"bedrock_item": bedrock_item,
		"bedrock_block": bedrock_block,
	}


func apply_params(params: Dictionary) -> void:
	noise_seed = int(params.get("noise_seed", noise_seed))
	bedrock_enabled = bool(params.get("bedrock_enabled", bedrock_enabled))
	bedrock_item = int(params.get("bedrock_item", bedrock_item))
	bedrock_block = String(params.get("bedrock_block", bedrock_block))
	_bedrock_resolved = -2


## Resolved bedrock item id, or -1 when the block cannot be found. Cached
## because generation calls this once per column and the lookup is a library
## scan on first use.
func resolved_bedrock_item() -> int:
	if _bedrock_resolved != -2:
		return _bedrock_resolved

	_bedrock_resolved = -1

	if not bedrock_enabled:
		return _bedrock_resolved

	if not bedrock_block.strip_edges().is_empty():
		_bedrock_resolved = BLOCK_IDS.id_for_name(bedrock_block)
	if _bedrock_resolved < 0:
		_bedrock_resolved = BLOCK_IDS.id_for(bedrock_item)
	if _bedrock_resolved < 0:
		_bedrock_resolved = BLOCK_IDS.bedrock_id()

	return _bedrock_resolved


## Appends the column's bedrock cell when it falls inside the y range.
func _append_bedrock(
	result: Array,
	world_x: int,
	world_z: int,
	y: int,
	min_y: int,
	max_y: int
) -> void:
	var item: int = resolved_bedrock_item()
	if item < 0:
		return
	if y < min_y or y > max_y:
		return
	result.append({
		"position": Vector3i(world_x, y, world_z),
		"item": item,
		"orientation": 0,
	})


## Height-map sampling. Return {} when the column has no surface.
## Expected keys: height (int), surface_item (int), orientation (int, optional).
func sample_column(_x: int, _z: int) -> Dictionary:
	return {}


## Turns `sample_column` into cell entries for one chunk column.
## Entries are {position: Vector3i, item: int, orientation: int}.
func generate_column(
	chunk: Vector2i,
	context: Dictionary = {}
) -> Array:
	var result: Array = []
	var chunk_size: int = int(context.get("chunk_size", 16))
	var min_y: int = int(context.get("min_y", -256))
	var max_y: int = int(context.get("max_y", 255))
	var origin: Vector2i = chunk * chunk_size

	for local_x in chunk_size:
		for local_z in chunk_size:
			var column: Dictionary = sample_column(
				origin.x + local_x,
				origin.y + local_z
			)

			if column.is_empty():
				continue

			var y: int = int(column.get("height", 0))

			if y < min_y or y > max_y:
				continue

			result.append({
				"position": Vector3i(
					origin.x + local_x,
					y,
					origin.y + local_z
				),
				"item": int(column.get("surface_item", 1)),
				"orientation": int(column.get("orientation", 0)),
			})

			_append_bedrock(
				result,
				origin.x + local_x,
				origin.y + local_z,
				y - 1,
				min_y,
				max_y
			)

	return result


## Optional placement stage: structures that span regions and need a wider
## context than one column (rooms, exits, props). Not used by the flat or
## height-map generators.
func generate_structures(
	_region: Rect2i,
	_context: Dictionary = {}
) -> Array:
	return []


## Optional section-native sampling for volumetric generators.
## Returns 4096 palette entries (-1 = air); empty means "nothing here".
func generate_section(
	_section: Vector3i,
	_context: Dictionary = {}
) -> PackedInt32Array:
	return PackedInt32Array()


## True when this generator may produce cells inside a chunk. Bounded
## generators override this so the streamer does not retry empty chunks forever.
func covers_chunk(_chunk: Vector2i) -> bool:
	return true


## Number of chunks the generator's footprint covers, or 0 when unbounded.
## Used to wait for a complete generated world before saving.
func get_footprint_chunk_count() -> int:
	return 0


## Chunk-space footprint, or an empty Rect2i when unbounded. The streamer uses
## this to avoid building a full load-radius disc around a small bounded world.
func get_footprint_chunk_rect() -> Rect2i:
	return Rect2i()


## Deterministic coordinate hash. 32-bit mixing keeps the arithmetic inside
## GDScript's 64-bit ints without relying on signed-overflow behaviour.
static func hash_coords(
	seed_value: int,
	x: int,
	z: int,
	salt: int = 0
) -> int:
	var h: int = (
		seed_value * 374761393
		+ x * 668265263
		+ z * 2147483647
		+ salt * 1274126177
	) & 0xFFFFFFFF

	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return h & 0x7FFFFFFF
