class_name ChunkFileStore
extends RefCounted

## File-backed chunk store used by ChunkStreamer.
##
## Each chunk is a Godot Variant dictionary (the output of
## NavGridMap.serialize_chunk) stored at:
##   <directory>/<chunk_x>_<chunk_z>.chunk

const CHUNK_EXTENSION: String = ".chunk"

var directory: String


func _init(store_directory: String) -> void:
	directory = store_directory.rstrip("/")
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(directory)
	)


func chunk_path(chunk: Vector2i) -> String:
	return "%s/%d_%d%s" % [
		directory,
		chunk.x,
		chunk.y,
		CHUNK_EXTENSION,
	]


func has_chunk(chunk: Vector2i) -> bool:
	return FileAccess.file_exists(chunk_path(chunk))


func load_chunk(chunk: Vector2i) -> Dictionary:
	var path: String = chunk_path(chunk)

	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		push_warning("ChunkFileStore: could not read %s" % path)
		return {}

	var value: Variant = file.get_var()
	file.close()

	if value is not Dictionary:
		push_warning("ChunkFileStore: malformed chunk %s" % path)
		return {}

	return value


func save_chunk(chunk: Vector2i, data: Dictionary) -> bool:
	var path: String = chunk_path(chunk)
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		push_warning("ChunkFileStore: could not write %s" % path)
		return false

	file.store_var(data)
	file.close()
	return true


## Returns chunk coordinates for every .chunk file in the store.
func list_chunks() -> Dictionary:
	var result: Dictionary = {}
	var dir := DirAccess.open(directory)

	if dir == null:
		return result

	dir.list_dir_begin()
	var file: String = dir.get_next()

	while not file.is_empty():
		if not dir.current_is_dir() and file.ends_with(CHUNK_EXTENSION):
			var stem: String = file.get_basename()
			var parts: PackedStringArray = stem.split("_")

			if parts.size() == 2:
				result[Vector2i(
					parts[0].to_int(),
					parts[1].to_int()
				)] = true

		file = dir.get_next()

	dir.list_dir_end()
	return result
