class_name RealisticSpriteLibrary
extends RefCounted

## Discovers realistic NPC sprite scenes by filename.
##
## Drop a new scene into res://scenes/npcs/realistic_npcs/ and name it after
## its ID (for example "sherwin.tscn" -> "sherwin") to add another variant.
## Each scene must use the eight clip names described in SpriteMemberVisual.

const SPRITE_DIRECTORY: String = "res://scenes/npcs/realistic_npcs/"
const DEFAULT_ID: StringName = &"sherwin"
## Sentinel used by the Agents panel to pick any available variant per agent.
const RANDOM_ID: StringName = &"random"

static var _scene_cache: Dictionary = {}
static var _ids_cache: PackedStringArray = PackedStringArray()


static func get_scene(id: StringName) -> PackedScene:
	var key: String = _normalise(id)

	if _scene_cache.has(key):
		return _scene_cache[key] as PackedScene

	var scene: PackedScene = _load_scene(key)

	if scene == null and key != String(DEFAULT_ID):
		scene = _load_scene(String(DEFAULT_ID))

	_scene_cache[key] = scene
	return scene


static func get_ids() -> PackedStringArray:
	if not _ids_cache.is_empty():
		return _ids_cache

	var directory := DirAccess.open(SPRITE_DIRECTORY)

	if directory == null:
		_ids_cache = PackedStringArray([String(DEFAULT_ID)])
		return _ids_cache

	var ids := PackedStringArray()
	directory.list_dir_begin()
	var file: String = directory.get_next()

	while not file.is_empty():
		if (
			not directory.current_is_dir()
			and file.ends_with(".tscn")
		):
			ids.append(file.get_basename())
		file = directory.get_next()

	directory.list_dir_end()
	ids.sort()

	if ids.is_empty():
		ids.append(String(DEFAULT_ID))

	_ids_cache = ids
	return _ids_cache


static func default_id() -> StringName:
	return DEFAULT_ID


static func pick_random_id() -> StringName:
	var ids: PackedStringArray = get_ids()

	if ids.is_empty():
		return DEFAULT_ID

	return StringName(ids[randi() % ids.size()])


static func _normalise(id: StringName) -> String:
	var key: String = String(id).strip_edges()
	return String(DEFAULT_ID) if key.is_empty() else key


static func _load_scene(key: String) -> PackedScene:
	var path: String = SPRITE_DIRECTORY + key + ".tscn"

	if not ResourceLoader.exists(path):
		path = SPRITE_DIRECTORY + key.to_lower() + ".tscn"

	if not ResourceLoader.exists(path):
		return null

	return load(path) as PackedScene


## Drops cached scenes before shutdown. Their sprite atlases are textures; if
## the static cache survives into static destruction, Godot frees them after
## the rendering server and reports leaked texture RIDs.
static func clear_cache() -> void:
	_scene_cache.clear()
	_ids_cache = PackedStringArray()
