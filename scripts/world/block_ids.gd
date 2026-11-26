class_name BlockIds
extends RefCounted

## Resolves block names to MeshLibrary item ids without a scene tree, so world
## generators can name a block ("bedrock", "dirt", "concrete_brick_yellow")
## instead of hardcoding an id that would break when the library is rebuilt.
##
## Resolution order for a String:
##   1. exact item name                 -> "Auto_bedrock"
##   2. "Auto_" + name                  -> "Auto_bedrock"
##   3. block group id                  -> "concrete_brick_yellow"
##   4. material id (first normal block) -> "concrete"
##
## Only "normal block" items are considered for groups and materials; slabs,
## stairs and panels are variants and would otherwise win depending on order.

const LIBRARY_PATH := "res://resources/blocks/.tres"
const BEDROCK_NAME := "bedrock"
const MATERIALS = preload("res://scripts/block_materials.gd")

static var _library: MeshLibrary = null
static var _by_name: Dictionary = {}
static var _group_normal: Dictionary = {}
static var _material_normal: Dictionary = {}
static var _ready := false


static func _ensure_ready() -> void:
	if _ready:
		return
	_ready = true

	if not ResourceLoader.exists(LIBRARY_PATH):
		return

	_library = load(LIBRARY_PATH) as MeshLibrary
	if _library == null:
		return

	for item_id: int in _library.get_item_list():
		var item_name := String(_library.get_item_name(item_id))
		if item_name.is_empty():
			continue
		_by_name[item_name] = item_id

		if MATERIALS.variant_of(item_name) != "block":
			continue

		var group := MATERIALS.block_group_id(item_name)
		if not _group_normal.has(group):
			_group_normal[group] = item_id

		var material := MATERIALS.material_id(item_name)
		if not material.is_empty() and not _material_normal.has(material):
			_material_normal[material] = item_id


## Accepts an int id (returned unchanged when >= 0) or a String name.
static func id_for(entry: Variant) -> int:
	if entry is int:
		return entry if int(entry) >= 0 else -1
	if entry is float:
		return int(entry) if int(entry) >= 0 else -1
	if not entry is String:
		return -1
	return id_for_name(String(entry))


static func id_for_name(name: String) -> int:
	var clean := name.strip_edges()
	if clean.is_empty():
		return -1

	_ensure_ready()

	var direct: Variant = _by_name.get(clean, -1)
	if int(direct) >= 0:
		return int(direct)

	var autoblocks := clean if clean.begins_with("Auto_") else "Auto_" + clean
	direct = _by_name.get(autoblocks, -1)
	if int(direct) >= 0:
		return int(direct)

	var group: Variant = _group_normal.get(clean.to_lower(), -1)
	if int(group) >= 0:
		return int(group)

	var material: Variant = _material_normal.get(clean.to_lower(), -1)
	if int(material) >= 0:
		return int(material)

	return -1


static func bedrock_id() -> int:
	return id_for_name(BEDROCK_NAME)


static func has_item(item_id: int) -> bool:
	_ensure_ready()
	if _library == null:
		return false
	return _library.get_item_list().has(item_id)


static func item_name(item_id: int) -> String:
	_ensure_ready()
	if not has_item(item_id):
		return ""
	return String(_library.get_item_name(item_id))


## Drops the cached library. Editor tools call this after regenerating blocks.
static func reload() -> void:
	_library = null
	_by_name.clear()
	_group_normal.clear()
	_material_normal.clear()
	_ready = false
