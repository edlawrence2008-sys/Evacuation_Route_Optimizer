class_name WorldGeneratorRegistry
extends RefCounted

## Single source of truth for the world generators exposed by the UI.
##
## Add a generator here and it appears in Extras > Generators and in the
## World Settings dropdown automatically. A generator must extend
## `WorldGenerator`, have a stable `get_id()` and support `apply_params()`.

const FLAT_GENERATOR = preload("res://scripts/world/FlatGenerator.gd")
const HEIGHTMAP_GENERATOR = preload(
	"res://scripts/world/HeightmapTerrainGenerator.gd"
)

const ENTRIES: Array[Dictionary] = [
	{
		"id": "flat_v1",
		"label": "Flat Platform",
		"description": "The authored 10 x 8 starter platform, generated through the recipe API.",
		"sizes": false,
		"default_size": "small",
	},
	{
		"id": "heightmap_v1",
		"label": "Heightmap Terrain",
		"description": "Bounded FBM/ridge terrain with a hard one-block slope and half-step risers.",
		"sizes": true,
		"default_size": "medium",
	},
]


static func all() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in ENTRIES:
		result.append(entry.duplicate(true))
	return result


static func find(generator_id: String) -> Dictionary:
	for entry: Dictionary in ENTRIES:
		if String(entry.get("id", "")) == generator_id:
			return entry.duplicate(true)
	return {}


static func label(generator_id: String) -> String:
	var entry := find(generator_id)
	if entry.is_empty():
		return generator_id if not generator_id.is_empty() else "Procedural"
	return String(entry.get("label", generator_id))


static func supports_sizes(generator_id: String) -> bool:
	return bool(find(generator_id).get("sizes", false))


static func default_size(generator_id: String) -> String:
	return String(find(generator_id).get("default_size", "medium"))


## Instantiates the generator resource for an id, or null when unknown.
static func create(generator_id: String) -> WorldGenerator:
	match generator_id:
		"flat_v1":
			return FLAT_GENERATOR.new()
		"heightmap_v1":
			return HEIGHTMAP_GENERATOR.new()
		_:
			return null
