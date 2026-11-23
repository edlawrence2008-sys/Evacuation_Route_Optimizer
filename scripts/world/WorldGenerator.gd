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

@export var noise_seed: int = 0


## Stable identity. A save pins this string plus `get_version()` and the params.
func get_id() -> String:
	return "world_generator_base"


func get_version() -> int:
	return 1


func get_params() -> Dictionary:
	return {"noise_seed": noise_seed}


func apply_params(params: Dictionary) -> void:
	noise_seed = int(params.get("noise_seed", noise_seed))


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
