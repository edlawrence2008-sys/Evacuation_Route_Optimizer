class_name PaletteStore
extends RefCounted

## Persistent block/placeable palettes. A palette is an inventory item with a
## 3x3 container of blocks and placeables. Palettes live in the same player-data
## root as the save slots (`user://saves/palettes.json`), so they sit beside the
## save folders instead of in a hidden location.

const SAVE_PATH := "user://saves/palettes.json"
const LEGACY_PATH := "user://palettes.json"
const PLAYER_SAVES_DIR := "user://saves"
const SLOT_COUNT := 9
const VERSION := 2

var palettes: Array = []
var presets: Array = []


func _init() -> void:
	# A fresh install starts with no palettes; the player creates them with the
	# + cell. The old auto-created "Palette 1..3" entries are removed on load.
	if not _load_from_disk():
		palettes.clear()
		presets.clear()
		# Create the player-data file even before the first palette so the save
		# root always shows where palettes live.
		save_to_disk()


# ---------------------------------------------------------------------------
# Palette list
# ---------------------------------------------------------------------------

func palette_count() -> int:
	return palettes.size()


func get_palette(palette_id: String) -> Dictionary:
	for palette: Dictionary in palettes:
		if String(palette.get("id", "")) == palette_id:
			return palette
	return {}


func add_palette(name: String = "") -> Dictionary:
	var palette := _new_palette(
		name.strip_edges() if not name.strip_edges().is_empty() else default_palette_name()
	)
	palettes.append(palette)
	save_to_disk()
	return palette


func remove_palette(palette_id: String) -> void:
	for index in palettes.size():
		if String(palettes[index].get("id", "")) == palette_id:
			palettes.remove_at(index)
			save_to_disk()
			return


func set_palette_name(palette_id: String, new_name: String) -> void:
	var palette := get_palette(palette_id)
	if palette.is_empty():
		return
	var trimmed := new_name.strip_edges()
	if trimmed.is_empty():
		return
	palette["name"] = trimmed
	save_to_disk()


## Next free "Palette N" label, so deleting a palette does not immediately
## reuse the same name.
func default_palette_name() -> String:
	var used: Dictionary = {}
	for palette: Dictionary in palettes:
		used[String(palette.get("name", ""))] = true
	var number := 1
	while used.has("Palette %d" % number):
		number += 1
	return "Palette %d" % number


# ---------------------------------------------------------------------------
# Slots
# ---------------------------------------------------------------------------

func get_slot(palette_id: String, index: int) -> Dictionary:
	if index < 0 or index >= SLOT_COUNT:
		return {}
	var palette := get_palette(palette_id)
	if palette.is_empty():
		return {}
	var slots: Array = palette.get("slots", [])
	if index >= slots.size() or not slots[index] is Dictionary:
		return {}
	return slots[index]


func set_slot(palette_id: String, index: int, data: Dictionary) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	var palette := get_palette(palette_id)
	if palette.is_empty():
		return
	var slots: Array = palette.get("slots", [])
	if slots.size() != SLOT_COUNT:
		slots = _empty_slots()
		palette["slots"] = slots
	slots[index] = _clean_slot(data)
	save_to_disk()


func clear_slot(palette_id: String, index: int) -> void:
	set_slot(palette_id, index, {})


# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------

## Saves the palette's current 3x3 layout under its name. Saving again with the
## same name overwrites that preset.
func save_preset(palette_id: String) -> String:
	var palette := get_palette(palette_id)
	if palette.is_empty():
		return ""
	var preset_name := String(palette.get("name", "")).strip_edges()
	if preset_name.is_empty():
		preset_name = "Untitled"
	var slots: Array = palette.get("slots", []).duplicate(true)
	var existing := preset_index(preset_name)
	var entry := {"name": preset_name, "slots": slots}
	if existing >= 0:
		presets[existing] = entry
	else:
		presets.append(entry)
	save_to_disk()
	return preset_name


func load_preset(palette_id: String, preset_name: String) -> bool:
	var palette := get_palette(palette_id)
	if palette.is_empty():
		return false
	var index := preset_index(preset_name)
	if index < 0:
		return false
	palette["slots"] = presets[index].get("slots", []).duplicate(true)
	save_to_disk()
	return true


func preset_names() -> Array[String]:
	var names: Array[String] = []
	for preset: Dictionary in presets:
		names.append(String(preset.get("name", "")))
	return names


func preset_index(preset_name: String) -> int:
	for index in presets.size():
		if String(presets[index].get("name", "")) == preset_name:
			return index
	return -1


# ---------------------------------------------------------------------------
# Disk IO
# ---------------------------------------------------------------------------

func save_to_disk() -> void:
	DirAccess.make_dir_recursive_absolute(PLAYER_SAVES_DIR)
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	var payload := {
		"version": VERSION,
		"palettes": palettes,
		"presets": presets,
	}
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()


func _load_from_disk() -> bool:
	_migrate_legacy_file()
	if not FileAccess.file_exists(SAVE_PATH):
		return false

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return false
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return false
	var document := parsed as Dictionary
	var file_version := int(document.get("version", 1))

	var removed_defaults := false
	palettes.clear()
	for raw: Variant in document.get("palettes", []):
		if not raw is Dictionary:
			continue
		var entry := raw as Dictionary
		var palette := {
			"id": String(entry.get("id", "")) if not String(entry.get("id", "")).is_empty() else _make_id(),
			"name": String(entry.get("name", "Palette")),
			"slots": _sanitize_slots(entry.get("slots", [])),
		}
		if file_version < 2 and _is_untouched_default(palette):
			removed_defaults = true
			continue
		palettes.append(palette)

	presets.clear()
	for raw: Variant in document.get("presets", []):
		if not raw is Dictionary:
			continue
		var entry := raw as Dictionary
		var preset_name := String(entry.get("name", "")).strip_edges()
		if preset_name.is_empty():
			continue
		presets.append({
			"name": preset_name,
			"slots": _sanitize_slots(entry.get("slots", [])),
		})

	if removed_defaults or file_version < VERSION:
		save_to_disk()

	return true


## One-time move from the old `user://palettes.json` location into the shared
## player-save root. The legacy file is removed after a successful copy.
func _migrate_legacy_file() -> void:
	if FileAccess.file_exists(SAVE_PATH) or not FileAccess.file_exists(LEGACY_PATH):
		return
	DirAccess.make_dir_recursive_absolute(PLAYER_SAVES_DIR)
	var source := FileAccess.open(LEGACY_PATH, FileAccess.READ)
	if source == null:
		return
	var text := source.get_as_text()
	source.close()
	var destination := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if destination == null:
		return
	destination.store_string(text)
	destination.close()
	DirAccess.remove_absolute(LEGACY_PATH)


## Older builds created empty Palette 1/2/3 entries. They are not player-made,
## so drop only those untouched defaults; renamed or populated ones survive.
func _is_untouched_default(palette: Dictionary) -> bool:
	var palette_name := String(palette.get("name", ""))
	if not palette_name in ["Palette 1", "Palette 2", "Palette 3"]:
		return false
	var slots: Array = palette.get("slots", [])
	for slot: Variant in slots:
		if slot != null:
			return false
	return true


func _new_palette(name: String) -> Dictionary:
	return {
		"id": _make_id(),
		"name": name,
		"slots": _empty_slots(),
	}


func _empty_slots() -> Array:
	var slots: Array = []
	slots.resize(SLOT_COUNT)
	slots.fill(null)
	return slots


func _sanitize_slots(raw_slots: Variant) -> Array:
	var slots := _empty_slots()
	if not raw_slots is Array:
		return slots
	var source := raw_slots as Array
	for index in mini(source.size(), SLOT_COUNT):
		if source[index] is Dictionary:
			slots[index] = _clean_slot(source[index])
	return slots


## Strips runtime-only keys (preview textures, loaded scenes) before writing.
func _clean_slot(data: Dictionary) -> Variant:
	if data.is_empty():
		return null
	var kind := String(data.get("kind", ""))
	if kind == "block":
		var item_name := String(data.get("item_name", data.get("name", "")))
		var item_id := int(data.get("item_id", data.get("hotbar_item_id", -1)))
		if item_id < 0 and item_name.is_empty():
			return null
		return {
			"kind": "block",
			"item_id": item_id,
			"item_name": item_name,
		}
	if kind == "placeable":
		var scene_path := String(data.get("scene_path", data.get("placeable_path", "")))
		if scene_path.is_empty():
			var scene: PackedScene = data.get("scene")
			if scene != null:
				scene_path = scene.resource_path
		if scene_path.is_empty():
			return null
		return {
			"kind": "placeable",
			"scene_path": scene_path,
			"item_name": String(data.get("item_name", data.get("name", ""))),
		}
	return null


func _make_id() -> String:
	var stamp := int(Time.get_unix_time_from_system() * 1000.0)
	var candidate := "palette_%d" % stamp
	var suffix := 0
	while not get_palette(candidate).is_empty():
		suffix += 1
		candidate = "palette_%d_%d" % [stamp, suffix]
	return candidate
