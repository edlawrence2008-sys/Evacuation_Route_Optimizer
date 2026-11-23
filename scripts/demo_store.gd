extends Node

## Per-save demo library.
##
## Demos live inside their map save:
##   user://saves/<save_slug>/demos/<demo_id>/demo.json
## so duplicating/renaming/deleting a save moves or removes its demos with it.
## The Demo Player/Comparer only ever see demos for the active save.

signal demos_changed

const SAVES_ROOT: String = "user://saves"
const DEMOS_DIR: String = "demos"
const META_FILE: String = "demo.json"
const RECORDING_FILE: String = "recording.jsonl"
const SUMMARY_FILE: String = "summary.json"
const MANIFEST_FILE: String = "manifest.json"
const UNSAVED_SLUG: String = "_unsaved"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func active_save_slug() -> String:
	var save_manager := get_node_or_null("/root/SaveManager")

	if save_manager != null and not String(save_manager.active_slug).is_empty():
		return String(save_manager.active_slug)

	return UNSAVED_SLUG


func has_active_save() -> bool:
	var save_manager := get_node_or_null("/root/SaveManager")
	return save_manager != null and not String(save_manager.active_slug).is_empty()


func demos_root(save_slug: String = "") -> String:
	var slug: String = save_slug if not save_slug.is_empty() else active_save_slug()
	return SAVES_ROOT.path_join(slug).path_join(DEMOS_DIR)


func demo_dir(demo_id: String, save_slug: String = "") -> String:
	return demos_root(save_slug).path_join(demo_id)


func recording_path(demo_id: String, save_slug: String = "") -> String:
	return demo_dir(demo_id, save_slug).path_join(RECORDING_FILE)


func summary_path(demo_id: String, save_slug: String = "") -> String:
	return demo_dir(demo_id, save_slug).path_join(SUMMARY_FILE)


func manifest_path(demo_id: String, save_slug: String = "") -> String:
	return demo_dir(demo_id, save_slug).path_join(MANIFEST_FILE)


## Creates a demo folder and its metadata. Returns {id, dir, metadata}.
func create_demo(
	display_name: String,
	metadata: Dictionary = {},
	save_slug: String = ""
) -> Dictionary:
	var slug: String = save_slug if not save_slug.is_empty() else active_save_slug()
	var root: String = demos_root(slug)
	DirAccess.make_dir_recursive_absolute(root)

	var unique := _make_unique(display_name, root)
	var demo_id: String = String(unique["id"])
	var dir: String = root.path_join(demo_id)
	DirAccess.make_dir_recursive_absolute(dir)

	var now: float = Time.get_unix_time_from_system()
	var record: Dictionary = {
		"format": "ero-demo",
		"version": 1,
		"id": demo_id,
		"name": String(unique["name"]),
		"description": "",
		"folder": "",
		"save_slug": slug,
		"created": now,
		"modified": now,
		"status": "recording",
		"duration": 0.0,
		"agents": 0,
		"seed": 0,
		"scene": "",
		"sample_interval": 0.0,
		"summary": {},
	}
	record.merge(metadata, true)
	_write_json(dir.path_join(META_FILE), record)
	demos_changed.emit()
	return {"id": demo_id, "dir": dir, "metadata": record}


## All demos for a save, sorted by folder then name. Missing metadata is
## reconstructed as a minimal record so a copied/interrupted run still appears.
func list_demos(save_slug: String = "") -> Array:
	var slug: String = save_slug if not save_slug.is_empty() else active_save_slug()
	var root: String = demos_root(slug)
	var result: Array = []

	if not DirAccess.dir_exists_absolute(root):
		return result

	for demo_id: String in DirAccess.get_directories_at(root):
		var metadata := get_demo(demo_id, slug)

		if metadata.is_empty():
			continue

		result.append(metadata)

	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var folder_a := String(a.get("folder", ""))
		var folder_b := String(b.get("folder", ""))
		if folder_a != folder_b:
			return folder_a.to_lower() < folder_b.to_lower()
		return String(a.get("name", "")).to_lower() < String(b.get("name", "")).to_lower()
	)
	return result


func get_demo(demo_id: String, save_slug: String = "") -> Dictionary:
	var dir: String = demo_dir(demo_id, save_slug)
	var path: String = dir.path_join(META_FILE)
	var parsed: Variant = _read_json(path)

	if parsed is Dictionary:
		var metadata: Dictionary = parsed
		metadata["save_slug"] = save_slug if not save_slug.is_empty() else active_save_slug()
		return metadata

	# Reconstruct from the recording header if metadata was lost.
	var recording: String = dir.path_join(RECORDING_FILE)

	if not FileAccess.file_exists(recording):
		return {}

	var file := FileAccess.open(recording, FileAccess.READ)
	if file == null:
		return {}

	var meta: Dictionary = {}
	while not file.eof_reached():
		var line := file.get_line()

		if line.strip_edges().is_empty():
			continue

		var obj: Variant = JSON.parse_string(line)

		if obj is Dictionary and String(obj.get("type", "")) == "run":
			meta = {
				"format": "ero-demo",
				"version": 1,
				"id": demo_id,
				"name": demo_id,
				"description": "",
				"folder": "",
				"save_slug": active_save_slug() if save_slug.is_empty() else save_slug,
				"created": FileAccess.get_modified_time(recording),
				"modified": FileAccess.get_modified_time(recording),
				"status": "unknown",
				"duration": 0.0,
				"agents": 0,
				"seed": int(obj.get("rng_seed", 0)),
				"scene": String(obj.get("scene", "")),
				"sample_interval": float(obj.get("sample_interval", 0.0)),
			}
			break

	file.close()
	return meta


func update_demo(demo_id: String, changes: Dictionary, save_slug: String = "") -> bool:
	var metadata := get_demo(demo_id, save_slug)

	if metadata.is_empty():
		return false

	metadata.merge(changes, true)
	metadata["modified"] = Time.get_unix_time_from_system()
	var ok := _write_json(demo_dir(demo_id, save_slug).path_join(META_FILE), metadata)

	if ok:
		demos_changed.emit()

	return ok


func rename_demo(demo_id: String, new_name: String, save_slug: String = "") -> bool:
	var trimmed_name: String = new_name.strip_edges()

	if trimmed_name.is_empty():
		return false

	return update_demo(demo_id, {"name": trimmed_name}, save_slug)


func describe_demo(demo_id: String, description: String, save_slug: String = "") -> bool:
	return update_demo(demo_id, {"description": description.strip_edges()}, save_slug)


func move_demo(demo_id: String, folder: String, save_slug: String = "") -> bool:
	return update_demo(demo_id, {"folder": _sanitize_folder(folder)}, save_slug)


func list_folders(save_slug: String = "") -> Array[String]:
	var folders: Array[String] = []

	for demo: Dictionary in list_demos(save_slug):
		var folder := String(demo.get("folder", ""))

		if not folder.is_empty() and not folders.has(folder):
			folders.append(folder)

	folders.sort()
	return folders


func duplicate_demo(demo_id: String, save_slug: String = "") -> String:
	var metadata := get_demo(demo_id, save_slug)

	if metadata.is_empty():
		return ""

	var slug: String = save_slug if not save_slug.is_empty() else active_save_slug()
	var source: String = demo_dir(demo_id, slug)
	var unique := _make_unique(
		"%s Copy" % String(metadata.get("name", "Demo")),
		demos_root(slug)
	)
	var new_id: String = String(unique["id"])
	var target: String = demos_root(slug).path_join(new_id)

	if not _copy_dir(source, target):
		return ""

	var copy: Dictionary = metadata.duplicate(true)
	copy["id"] = new_id
	copy["name"] = String(unique["name"])
	copy["created"] = Time.get_unix_time_from_system()
	copy["modified"] = copy["created"]
	copy["save_slug"] = slug
	_write_json(target.path_join(META_FILE), copy)
	demos_changed.emit()
	return new_id


func delete_demo(demo_id: String, save_slug: String = "") -> bool:
	var dir: String = demo_dir(demo_id, save_slug)

	if not DirAccess.dir_exists_absolute(dir):
		return false

	_remove_dir(dir)
	demos_changed.emit()
	return true


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _make_unique(display_name: String, root: String) -> Dictionary:
	var base: String = display_name.strip_edges()

	if base.is_empty():
		base = "Demo"

	var candidate: String = base
	var id: String = _slugify(candidate)
	var index: int = 2

	while DirAccess.dir_exists_absolute(root.path_join(id)):
		candidate = "%s (%d)" % [base, index]
		id = _slugify(candidate)
		index += 1

	return {"name": candidate, "id": id}


func _slugify(value: String) -> String:
	var slug: String = value.strip_edges()

	for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]:
		slug = slug.replace(ch, "_")

	slug = slug.replace(" ", "_")

	if slug.is_empty():
		slug = "demo"

	if slug.length() > 64:
		slug = slug.substr(0, 64)

	return slug


func _sanitize_folder(value: String) -> String:
	var folder: String = value.strip_edges()

	for ch in ["\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]:
		folder = folder.replace(ch, "_")

	# Keep one level of grouping simple and predictable.
	while folder.contains("//"):
		folder = folder.replace("//", "/")

	folder = folder.trim_prefix("/").trim_suffix("/")
	return folder


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return null

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed


func _write_json(path: String, value: Variant) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return false

	file.store_string(JSON.stringify(value, "\t"))
	file.close()
	return true


func _copy_dir(source: String, target: String) -> bool:
	DirAccess.make_dir_recursive_absolute(target)
	var dir := DirAccess.open(source)

	if dir == null:
		return false

	dir.list_dir_begin()
	var entry_name := dir.get_next()

	while not entry_name.is_empty():
		if not entry_name.begins_with("."):
			var from: String = source.path_join(entry_name)
			var to: String = target.path_join(entry_name)

			if dir.current_is_dir():
				_copy_dir(from, to)
			else:
				DirAccess.copy_absolute(from, to)

		entry_name = dir.get_next()

	dir.list_dir_end()
	return true


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)

	if dir == null:
		return

	dir.list_dir_begin()
	var entry_name := dir.get_next()

	while not entry_name.is_empty():
		if entry_name != "." and entry_name != "..":
			var child: String = path.path_join(entry_name)

			if dir.current_is_dir():
				_remove_dir(child)
			else:
				DirAccess.remove_absolute(child)

		entry_name = dir.get_next()

	dir.list_dir_end()
	DirAccess.remove_absolute(path)
