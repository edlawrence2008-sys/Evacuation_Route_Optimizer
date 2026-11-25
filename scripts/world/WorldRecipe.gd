class_name WorldRecipe
extends Resource

## A composable world description: one base generator, optional overlays, and an
## optional scenario stage.
##
## The streamer and save system only ever see a recipe. That keeps procgen
## options pluggable: flat, height-map terrain, plate-river terrain, building
## overlays and scenario placement can be mixed without touching chunk
## streaming, navigation or the mesher.
##
## Reproducibility contract:
##   - the base generator defines the terrain columns;
##   - overlays run in array order after the base;
##   - the scenario stage runs last and adds exits, spawners and props;
##   - every generator must be pure for the same seed and coordinates.
##
## `get_manifest()` is written into the save and the run manifest so a demo can
## name the exact world that produced it.

const VoxelSectionStoreScript = preload(
	"res://scripts/world/VoxelSectionStore.gd"
)

## Version of the chunk payload this recipe emits. Keep in sync with
## NavGridMap.CHUNK_DATA_VERSION; duplicated here so this module stays pure.
const CHUNK_FORMAT_VERSION: int = 2

@export var generator: Resource = null
@export var overlays: Array[Resource] = []
@export var scenario: Resource = null
@export var min_y: int = -256
@export var max_y: int = 255


func get_recipe_id() -> String:
	if generator != null and generator.has_method("get_id"):
		return generator.get_id()

	return "empty"


## True when the recipe may produce cells in this chunk. Bounded generators
## use this to keep the streamer from retrying empty chunks forever.
func covers_chunk(chunk: Vector2i) -> bool:
	if generator != null and generator.has_method("covers_chunk"):
		return bool(generator.covers_chunk(chunk))

	return true


## Number of chunks in the base generator's footprint, or 0 when unbounded.
func get_footprint_chunk_count() -> int:
	if generator != null and generator.has_method("get_footprint_chunk_count"):
		return int(generator.get_footprint_chunk_count())

	return 0


## Base generator footprint in chunk space, or an empty Rect2i when unbounded.
func get_footprint_chunk_rect() -> Rect2i:
	if generator != null and generator.has_method("get_footprint_chunk_rect"):
		return generator.get_footprint_chunk_rect()

	return Rect2i()


## Stable block for `save.json` and `manifest.json`.
func get_manifest() -> Dictionary:
	var stages: Array = []

	if generator != null:
		stages.append(_describe(generator))

	for overlay in overlays:
		if overlay != null:
			stages.append(_describe(overlay))

	if scenario != null:
		stages.append(_describe(scenario))

	return {
		"recipe_id": get_recipe_id(),
		"min_y": min_y,
		"max_y": max_y,
		"stages": stages,
	}


func _describe(stage: Resource) -> Dictionary:
	if not stage.has_method("get_id"):
		return {"id": "unknown", "version": 0, "params": {}}

	return {
		"id": stage.get_id(),
		"version": stage.get_version() if stage.has_method("get_version") else 0,
		"params": stage.get_params() if stage.has_method("get_params") else {},
	}


## Builds one chunk in the current on-disk format (version 2: compressed 3D
## sections). Returns an empty dictionary when the recipe produces nothing.
func generate_chunk_data(chunk: Vector2i) -> Dictionary:
	var store = VoxelSectionStoreScript.new()
	var context: Dictionary = {
		"chunk_size": VoxelSectionStoreScript.SIZE,
		"min_y": min_y,
		"max_y": max_y,
		"recipe": get_recipe_id(),
	}

	_apply_stage(generator, chunk, context, store)

	for overlay in overlays:
		_apply_stage(overlay, chunk, context, store)

	_apply_stage(scenario, chunk, context, store)

	if store.get_column_cell_count(chunk) == 0:
		return {}

	return {
		"version": CHUNK_FORMAT_VERSION,
		"chunk_x": chunk.x,
		"chunk_z": chunk.y,
		"sections": store.serialize_column_compressed(chunk),
	}


func _apply_stage(
	stage: Resource,
	chunk: Vector2i,
	context: Dictionary,
	store
) -> void:
	if stage == null:
		return

	if stage.has_method("generate_column"):
		for entry: Dictionary in stage.generate_column(chunk, context):
			store.set_cell(
				entry.get("position", Vector3i.ZERO),
				int(entry.get("item", -1)),
				int(entry.get("orientation", 0))
			)

	if stage.has_method("generate_structures"):
		var region := Rect2i(
			chunk * VoxelSectionStoreScript.SIZE,
			Vector2i(VoxelSectionStoreScript.SIZE, VoxelSectionStoreScript.SIZE)
		)

		for entry: Dictionary in stage.generate_structures(region, context):
			store.set_cell(
				entry.get("position", Vector3i.ZERO),
				int(entry.get("item", -1)),
				int(entry.get("orientation", 0))
			)
