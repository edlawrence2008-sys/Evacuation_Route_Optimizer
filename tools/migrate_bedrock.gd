extends SceneTree

## One-off save migration: write a Bedrock anchor under every existing column.
##
##   godot --headless --path . --script res://tools/migrate_bedrock.gd
##   godot --headless --path . --script res://tools/migrate_bedrock.gd -- --dry-run
##   godot --headless --path . --script res://tools/migrate_bedrock.gd -- --only=Plains
##
## Why per-column: a saved world only stores the cells the player built. Adding
## one bedrock block directly under each column's lowest cell anchors every
## column without inventing a huge solid fill under the whole map. Chunks that
## already contain bedrock in a column are left alone, so the script is safe to
## run more than once.
##
## Modified files are copied to `<chunks>/_bedrock_backup/` before they are
## rewritten. The rewritten payload uses the current version-2 section format;
## version-1 legacy chunks are upgraded in the same pass.

const VOXEL_STORE = preload("res://scripts/world/VoxelSectionStore.gd")
const GRID = preload("res://scripts/gridmap.gd")
const BLOCK_IDS = preload("res://scripts/world/block_ids.gd")

const SAVES_ROOT := "user://saves"
const LIVE_CHUNKS := "user://world/chunks"
const CHUNK_EXTENSION := ".chunk"
## Leading dot so SaveManager's recursive chunk copy/clear (which skips
## dot-files) never carries backups into the live store or deletes them.
const BACKUP_DIR := ".bedrock_backup"
## Matches NavGridMap.min_block_y's default. A bedrock cell below this would be
## dropped when the chunk loads, so it is reported instead of written.
const MIN_BEDROCK_Y := -256

var _bedrock_item: int = -1
var _dry_run: bool = false
var _verify: bool = false
var _backup: bool = true
var _only_slug: String = ""

var _chunks_scanned: int = 0
var _chunks_changed: int = 0
var _columns_anchored: int = 0
var _columns_already: int = 0
var _columns_unanchored: int = 0
var _errors: int = 0


func _initialize() -> void:
	_parse_args()
	_section("migrate bedrock")
	_bedrock_item = BLOCK_IDS.bedrock_id()
	print("bedrock item: %d (%s)" % [_bedrock_item, BLOCK_IDS.item_name(_bedrock_item)])
	print("dry run: %s" % _dry_run)
	print("verify: %s" % _verify)

	if _bedrock_item < 0:
		push_error("migrate_bedrock: Auto_bedrock is missing from the MeshLibrary. Run res://tools/rebuild_blocks.gd first.")
		quit(1)
		return

	_migrate_folder(LIVE_CHUNKS)

	var saves := DirAccess.open(SAVES_ROOT)
	if saves != null:
		for slug in saves.get_directories():
			if not _only_slug.is_empty() and slug != _only_slug:
				continue
			_migrate_folder(SAVES_ROOT.path_join(slug).path_join("chunks"))

	_section("summary")
	print("chunks scanned:    %d" % _chunks_scanned)
	print("chunks changed:    %d" % _chunks_changed)
	print("columns anchored:  %d" % _columns_anchored)
	print("already anchored:  %d" % _columns_already)
	print("unanchored:        %d" % _columns_unanchored)
	print("errors:            %d" % _errors)
	quit(0 if _errors == 0 and _columns_unanchored == 0 else 1)


func _parse_args() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()

	for arg: String in args:
		if arg == "--dry-run":
			_dry_run = true
		elif arg == "--verify":
			_verify = true
		elif arg == "--no-backup":
			_backup = false
		elif arg.begins_with("--only="):
			_only_slug = arg.trim_prefix("--only=")


func _migrate_folder(folder: String) -> void:
	if not DirAccess.dir_exists_absolute(folder):
		return

	var dir := DirAccess.open(folder)
	if dir == null:
		push_warning("migrate_bedrock: cannot open " + folder)
		_errors += 1
		return

	var files: PackedStringArray = dir.get_files()
	var folder_changed: int = 0

	for file in files:
		if not file.ends_with(CHUNK_EXTENSION):
			continue
		folder_changed += _migrate_file(folder.path_join(file))

	if folder_changed > 0:
		print("%s: %d chunk(s) updated" % [folder, folder_changed])


func _migrate_file(path: String) -> int:
	_chunks_scanned += 1

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("migrate_bedrock: cannot read " + path)
		_errors += 1
		return 0

	var value: Variant = file.get_var()
	file.close()

	if not value is Dictionary:
		push_warning("migrate_bedrock: malformed chunk " + path)
		_errors += 1
		return 0

	var data: Dictionary = value
	if data.is_empty():
		return 0

	var chunk := Vector2i(
		int(data.get("chunk_x", 0)),
		int(data.get("chunk_z", 0))
	)
	if not data.has("chunk_x") or not data.has("chunk_z"):
		var parts: PackedStringArray = path.get_file().get_basename().split("_")
		if parts.size() == 2:
			chunk = Vector2i(parts[0].to_int(), parts[1].to_int())
	var version: int = int(data.get("version", 0))
	var entries := _decode_entries(chunk, data, version, path)

	if entries.is_empty():
		return 0

	if _verify:
		_verify_entries(entries)
		return 0

	var added := _add_bedrock(entries)
	if added == 0:
		return 0

	_columns_anchored += added
	_chunks_changed += 1

	if _dry_run:
		return 1

	if _backup:
		_backup_file(path)

	var store = VOXEL_STORE.new()
	for entry: Dictionary in entries:
		store.set_cell(
			entry["position"] as Vector3i,
			int(entry["item"]),
			int(entry.get("orientation", 0))
		)

	var payload := {
		"version": GRID.CHUNK_DATA_VERSION,
		"chunk_x": chunk.x,
		"chunk_z": chunk.y,
		"sections": store.serialize_column_compressed(chunk),
	}

	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		push_warning("migrate_bedrock: cannot write " + path)
		_errors += 1
		return 0
	out.store_var(payload)
	out.close()
	return 1


func _decode_entries(
	chunk: Vector2i,
	data: Dictionary,
	version: int,
	path: String
) -> Array:
	if version == GRID.CHUNK_DATA_VERSION:
		var blob_value: Variant = data.get("sections", PackedByteArray())
		if not blob_value is PackedByteArray:
			push_warning("migrate_bedrock: sections missing in " + path)
			_errors += 1
			return []
		return VOXEL_STORE.decode_column_compressed(chunk, blob_value as PackedByteArray)

	if version == GRID.LEGACY_CHUNK_DATA_VERSION:
		return _decode_legacy(chunk, data, path)

	push_warning("migrate_bedrock: unknown chunk version %d in %s" % [version, path])
	_errors += 1
	return []


func _decode_legacy(chunk: Vector2i, data: Dictionary, path: String) -> Array:
	var packed_value: Variant = data.get("cells", PackedInt32Array())
	if not packed_value is PackedInt32Array:
		push_warning("migrate_bedrock: legacy cells missing in " + path)
		_errors += 1
		return []

	var packed: PackedInt32Array = packed_value
	if packed.size() % GRID.INTS_PER_BLOCK != 0:
		push_warning("migrate_bedrock: malformed legacy cells in " + path)
		_errors += 1
		return []

	var origin: Vector2i = GRID.chunk_origin(chunk)
	var entries: Array = []
	for index in range(0, packed.size(), GRID.INTS_PER_BLOCK):
		entries.append({
			"position": Vector3i(
				origin.x + packed[index],
				packed[index + 1],
				origin.y + packed[index + 2]
			),
			"item": packed[index + 3],
			"orientation": packed[index + 4],
		})
	return entries


## Adds one bedrock cell under every column that has none. Returns the number of
## cells added. Mutates `entries`, which is then re-serialized by the caller.
func _add_bedrock(entries: Array) -> int:
	var bedrock_columns: Dictionary = {}
	var min_y_by_column: Dictionary = {}

	for entry: Dictionary in entries:
		var cell: Vector3i = entry["position"]
		if int(entry["item"]) == _bedrock_item:
			bedrock_columns[Vector2i(cell.x, cell.z)] = true

		var column := Vector2i(cell.x, cell.z)
		var lowest: Variant = min_y_by_column.get(column, 0x7FFFFFFF)
		min_y_by_column[column] = mini(int(lowest), cell.y)

	var added: Array[Dictionary] = []

	for column: Vector2i in min_y_by_column:
		if bedrock_columns.has(column):
			_columns_already += 1
			continue

		var y: int = int(min_y_by_column[column]) - 1
		if y < MIN_BEDROCK_Y:
			push_warning("migrate_bedrock: column %s has no room for bedrock" % column)
			continue

		added.append({
			"position": Vector3i(column.x, y, column.y),
			"item": _bedrock_item,
			"orientation": 0,
		})

	entries.append_array(added)
	return added.size()


## Verifies the post-migration invariant: in every column, the lowest stored
## cell is bedrock, so the whole column is anchored. Reports columns that are
## not.
func _verify_entries(entries: Array) -> void:
	var lowest: Dictionary = {}

	for entry: Dictionary in entries:
		var cell: Vector3i = entry["position"]
		var column := Vector2i(cell.x, cell.z)
		var previous: Array = lowest.get(column, [0x7FFFFFFF, -1])
		if cell.y < int(previous[0]):
			lowest[column] = [cell.y, int(entry["item"])]

	for column: Vector2i in lowest:
		if int((lowest[column] as Array)[1]) == _bedrock_item:
			_columns_already += 1
		else:
			_columns_unanchored += 1


func _backup_file(path: String) -> void:
	var backup_dir := path.get_base_dir().path_join(BACKUP_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(backup_dir))

	var target := backup_dir.path_join(path.get_file())
	if FileAccess.file_exists(target):
		return

	var source := FileAccess.open(path, FileAccess.READ)
	if source == null:
		return
	var bytes: PackedByteArray = source.get_buffer(source.get_length())
	source.close()

	var out := FileAccess.open(target, FileAccess.WRITE)
	if out == null:
		return
	out.store_buffer(bytes)
	out.close()


func _section(title: String) -> void:
	print("")
	print("=== %s ===" % title)
