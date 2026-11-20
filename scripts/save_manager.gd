extends Node

## Map save/load slots.
##
## Each save is a folder under user://saves/<slug> containing save.json and a
## copy of the world chunk store. Loading copies the chunks back into the live
## store and reloads the map scene.

const SAVES_ROOT := "user://saves"
const LIVE_CHUNKS_FALLBACK := "user://world/chunks"
const ACTIVE_PATH := "user://active_save.cfg"
const MANIFEST := "save.json"
const THUMBNAIL := "thumb.png"
const VERSION := 1
const MAP_RENDERER := preload("res://scripts/map_renderer.gd")
const PLACEABLE_SKIP := [
	"script", "owner", "name", "transform", "position", "rotation",
	"rotation_degrees", "scale", "scene_file_path", "metadata",
	"unique_name_in_owner", "editor_description", "multiplayer",
	"process_mode", "process_priority", "process_physics_priority",
	"auto_translate_mode", "physics_interpolation_mode", "process_thread_group",
	"rotation_edit_mode", "rotation_order",
	"visibility_range_begin", "visibility_range_begin_margin",
	"visibility_range_end", "visibility_range_end_margin",
	"visibility_range_fade_mode", "lod_bias", "gi_mode",
]

signal saves_changed

var active_slug: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(SAVES_ROOT)
	_load_active()


func has_active_save() -> bool:
	return not active_slug.is_empty()


func active_name() -> String:
	if active_slug.is_empty():
		return ""
	return display_name(active_slug)


func list_saves() -> Array:
	var result: Array = []
	for slug in DirAccess.get_directories_at(SAVES_ROOT):
		var manifest := _read_manifest(slug)
		if manifest.is_empty():
			continue
		result.append({
			"slug": slug,
			"name": String(manifest.get("name", slug)),
			"modified": float(manifest.get("modified", 0.0)),
			"thumbnail": _thumbnail_path(slug),
			"world_type": String(
				manifest.get("world", {}).get("type", "existing")
			),
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["name"]).to_lower() < String(b["name"]).to_lower()
	)
	return result


func get_thumbnail(slug: String) -> Texture2D:
	var path := _thumbnail_path(slug)
	if not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load(path) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _thumbnail_path(slug: String) -> String:
	var path := SAVES_ROOT.path_join(slug).path_join(THUMBNAIL)
	if FileAccess.file_exists(path):
		return path
	return ""


func display_name(slug: String) -> String:
	var manifest := _read_manifest(slug)
	return String(manifest.get("name", slug))


func save_active() -> bool:
	if active_slug.is_empty():
		return false
	var folder := SAVES_ROOT.path_join(active_slug)
	if not DirAccess.dir_exists_absolute(folder):
		return false

	var existing := _read_manifest(active_slug)
	var display := String(existing.get("name", active_slug))
	var created := float(existing.get("created", Time.get_unix_time_from_system()))
	var world: Dictionary = existing.get(
		"world",
		_default_world_metadata()
	)

	_flush_world()
	_clear_dir(folder.path_join("chunks"))
	_copy_dir(_live_chunks(), folder.path_join("chunks"))
	_write_thumbnail(folder)

	var manifest := _build_manifest(display, world)
	manifest["created"] = created
	_write_manifest(folder, manifest)
	saves_changed.emit()
	return true


func save_as(name: String) -> String:
	var pair := _make_unique(name)
	var display := String(pair[0])
	var slug := String(pair[1])
	var folder := SAVES_ROOT.path_join(slug)
	DirAccess.make_dir_recursive_absolute(folder)

	_flush_world()
	_clear_dir(folder.path_join("chunks"))
	_copy_dir(_live_chunks(), folder.path_join("chunks"))
	_write_thumbnail(folder)

	_write_manifest(folder, _build_manifest(display, _current_world_metadata()))
	active_slug = slug
	_save_active()
	saves_changed.emit()
	return slug


func load_save(slug: String) -> void:
	var manifest := _read_manifest(slug)
	if manifest.is_empty():
		return

	var folder := SAVES_ROOT.path_join(slug)
	var saved_chunks := folder.path_join("chunks")
	if not DirAccess.dir_exists_absolute(saved_chunks):
		return

	var streamer := get_tree().get_first_node_in_group("chunk_streamer")
	if streamer != null and streamer.has_method("prepare_for_scene_reload"):
		streamer.prepare_for_scene_reload()

	_clear_dir(_live_chunks())
	_copy_dir(saved_chunks, _live_chunks())

	active_slug = slug
	_save_active()

	var tree := get_tree()
	tree.paused = false
	Engine.time_scale = 1.0

	var map_path := String(manifest.get("map", ""))
	if not map_path.is_empty() and ResourceLoader.exists(map_path):
		tree.change_scene_to_file(map_path)
	else:
		tree.reload_current_scene()

	await tree.process_frame
	await tree.process_frame
	await _apply_manifest(manifest)
	var settings = get_node_or_null("/root/PerformanceSettings")
	if settings != null and settings.has_method("apply_all"):
		settings.apply_all()
	saves_changed.emit()


func delete_save(slug: String) -> bool:
	var folder := SAVES_ROOT.path_join(slug)
	if not DirAccess.dir_exists_absolute(folder):
		return false

	_remove_dir(folder)
	if active_slug == slug:
		active_slug = ""
		_save_active()
	saves_changed.emit()
	return true


func duplicate_save(slug: String, new_name: String) -> String:
	var source := SAVES_ROOT.path_join(slug)
	if not DirAccess.dir_exists_absolute(source):
		return ""

	var manifest := _read_manifest(slug)
	if manifest.is_empty():
		return ""

	var pair := _make_unique(new_name)
	var display := String(pair[0])
	var new_slug := String(pair[1])
	var target := SAVES_ROOT.path_join(new_slug)

	_copy_dir(source, target)
	manifest["name"] = display
	manifest["modified"] = Time.get_unix_time_from_system()
	manifest["created"] = Time.get_unix_time_from_system()
	_write_manifest(target, manifest)
	saves_changed.emit()
	return new_slug


## Renames a save's display name and, when the slug changes, its folder. The
## manifest and active-save pointer are kept in sync.
func rename_save(slug: String, new_name: String) -> String:
	var source := SAVES_ROOT.path_join(slug)
	if not DirAccess.dir_exists_absolute(source):
		return ""

	var manifest := _read_manifest(slug)
	if manifest.is_empty():
		return ""

	var display := new_name.strip_edges()
	if display.is_empty():
		return ""

	var new_slug := _slugify(display)
	if new_slug == slug:
		manifest["name"] = display
		_write_manifest(source, manifest)
		saves_changed.emit()
		return slug

	var pair := _make_unique(display)
	display = String(pair[0])
	new_slug = String(pair[1])
	var target := SAVES_ROOT.path_join(new_slug)
	if DirAccess.dir_exists_absolute(target):
		return ""

	if DirAccess.rename_absolute(source, target) != OK:
		if not _copy_dir(source, target):
			return ""
		_remove_dir(source)

	manifest["name"] = display
	_write_manifest(target, manifest)
	if active_slug == slug:
		active_slug = new_slug
		_save_active()
	saves_changed.emit()
	return new_slug


## Creates a new save whose world starts as a small platform at the player's
## current spawn position. The map scene is reloaded with an empty chunk store
## first, so this is also the hook for future generated worlds: pass a world
## descriptor with type "procgen", generator id, seed and options.
func new_blank_map(name: String, world_options: Dictionary = {}) -> String:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return ""

	var display := name.strip_edges()
	if display.is_empty():
		display = "New Map"
	var pair := _make_unique(display)
	display = String(pair[0])
	var slug := String(pair[1])

	var map_path := String(tree.current_scene.scene_file_path)
	if map_path.is_empty() or map_path.begins_with("res://scenes/menu/"):
		map_path = "res://Maps/test.tscn"

	var streamer := tree.get_first_node_in_group("chunk_streamer")
	if streamer != null and streamer.has_method("prepare_for_scene_reload"):
		streamer.prepare_for_scene_reload()
	_clear_dir(_live_chunks())

	tree.paused = false
	Engine.time_scale = 1.0
	if ResourceLoader.exists(map_path):
		tree.change_scene_to_file(map_path)
	else:
		tree.reload_current_scene()

	await tree.process_frame
	await tree.process_frame
	await tree.process_frame

	var grid = tree.get_first_node_in_group("grid_map")
	if grid == null:
		return ""

	# A blank map starts with no authored/saved placeables.
	for node in tree.get_nodes_in_group("placeables"):
		if is_instance_valid(node):
			node.queue_free()
	await tree.process_frame
	await tree.process_frame

	var gd := get_node_or_null("/root/GlobalData")

	if gd != null and gd.has_method("reset_spawning"):
		gd.call("reset_spawning")

	var runtime = get_node_or_null("/root/RuntimeExports")
	if runtime != null and runtime.has_method("apply_defaults_to_live"):
		runtime.call("apply_defaults_to_live")

	var player := tree.get_first_node_in_group("Player") as Node3D
	var cell := Vector3i(0, 0, 0)
	var platform_y := clampi(
		0,
		int(grid.min_block_y),
		int(grid.max_block_y)
	)
	var block_id := _blank_platform_item(grid)
	var platform_cells: Array[Vector3i] = []
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			platform_cells.append(Vector3i(cell.x + dx, platform_y, cell.z + dz))
	grid.place_blocks(platform_cells, block_id, 0)

	if player != null:
		var center: Vector3 = grid.to_global(
			grid.map_to_local(Vector3i(cell.x, platform_y, cell.z))
		)
		player.global_position = Vector3(
			center.x,
			center.y + grid.cell_size.y * 0.5 + 1.6,
			center.z
		)
		player.rotation = Vector3.ZERO
		player.set("camera_x_rotation", 0.0)

	await tree.create_timer(0.35).timeout

	_flush_world()
	var folder := SAVES_ROOT.path_join(slug)
	DirAccess.make_dir_recursive_absolute(folder)
	_clear_dir(folder.path_join("chunks"))
	_copy_dir(_live_chunks(), folder.path_join("chunks"))
	_write_thumbnail(folder)

	var world := _normalise_world_metadata(world_options, "blank")
	var manifest := _build_manifest(display, world)
	manifest["map"] = map_path
	_write_manifest(folder, manifest)
	active_slug = slug
	_save_active()
	saves_changed.emit()
	return slug


## Forward-compatible map-creation entry point. `world_options.type` is
## currently "blank"; a future "procgen" branch can generate chunks into the
## live store here before the same flush/copy/manifest path runs.
func new_map(name: String, world_options: Dictionary = {}) -> String:
	return await new_blank_map(name, world_options)


func _blank_platform_item(grid) -> int:
	if grid == null or grid.mesh_library == null:
		return 0
	for item_name in [
		"Auto_concrete_flat_offwhite",
		"Auto_dirt_normal",
		"Auto_dirt_flat",
	]:
		var id: int = grid.mesh_library.find_item_by_name(item_name)
		if id != -1:
			return id
	for item_id in grid.mesh_library.get_item_list():
		var name := String(grid.mesh_library.get_item_name(item_id)).to_lower()
		if (
			not name.contains("slab")
			and not name.contains("panel")
			and not name.contains("stairs")
			and not name.begins_with("water_")
		):
			return item_id
	return grid.mesh_library.get_item_list()[0]


func _build_manifest(display: String, world: Dictionary = {}) -> Dictionary:
	var now := Time.get_unix_time_from_system()
	var global_data := get_node_or_null("/root/GlobalData")
	var player := get_tree().get_first_node_in_group("Player") as Node3D
	var player_data := {}
	if player != null:
		var pitch: float = float(player.get("camera_x_rotation"))
		player_data = {
			"pos": [player.global_position.x, player.global_position.y, player.global_position.z],
			"yaw": player.rotation.y,
			"pitch": pitch,
		}

	var cycle := get_tree().current_scene.get_node_or_null("CycleController")
	var cycle_time := 0.0
	if cycle != null:
		cycle_time = float(cycle.get("_current_time"))

	var map_path := ""
	if get_tree().current_scene != null:
		map_path = get_tree().current_scene.scene_file_path

	return {
		"version": VERSION,
		"name": display,
		"created": now,
		"modified": now,
		"map": map_path,
		"thumbnail": THUMBNAIL,
		"player": player_data,
		"cycle_time": cycle_time,
		"sim_seed": int(global_data.rng_seed) if global_data != null else 0,
		"runtime_exports": _collect_runtime_exports(),
		"placeables": _collect_placeables(),
		"world": _normalise_world_metadata(world),
	}


func _collect_runtime_exports() -> Dictionary:
	var runtime = get_node_or_null("/root/RuntimeExports")

	if runtime == null or not runtime.has_method("collect_live"):
		return {}

	var result: Variant = runtime.call("collect_live")
	return result if result is Dictionary else {}


## World descriptor stored with every save. Only "existing" and "blank" are
## produced today; "procgen" is reserved for future generated maps.
func _default_world_metadata() -> Dictionary:
	return {
		"type": "existing",
		"generator": "",
		"seed": 0,
		"size": "",
		"options": {},
	}


func _normalise_world_metadata(
	world: Dictionary,
	fallback_type: String = "existing"
) -> Dictionary:
	var result := _default_world_metadata()
	result["type"] = String(world.get("type", fallback_type))
	result["generator"] = String(world.get("generator", ""))
	result["seed"] = int(world.get("seed", 0))
	result["size"] = String(world.get("size", ""))
	result["options"] = world.get("options", {})
	return result


func _current_world_metadata() -> Dictionary:
	if not active_slug.is_empty():
		var manifest := _read_manifest(active_slug)
		if not manifest.is_empty() and manifest.has("world"):
			return _normalise_world_metadata(manifest["world"])
	return _default_world_metadata()


func _write_thumbnail(folder: String) -> void:
	var grid = get_tree().get_first_node_in_group("grid_map")
	if grid == null:
		return
	MAP_RENDERER.save_thumbnail(grid, folder.path_join(THUMBNAIL))


func _collect_placeables() -> Array:
	var entries: Array = []
	for node in get_tree().get_nodes_in_group("placeables"):
		if not is_instance_valid(node):
			continue
		var scene_path := String(node.scene_file_path)
		if scene_path.is_empty():
			continue
		var xform: Transform3D = node.global_transform
		entries.append({
			"scene": scene_path,
			"xform": [
				xform.basis.x.x, xform.basis.x.y, xform.basis.x.z,
				xform.basis.y.x, xform.basis.y.y, xform.basis.y.z,
				xform.basis.z.x, xform.basis.z.y, xform.basis.z.z,
				xform.origin.x, xform.origin.y, xform.origin.z,
			],
			"props": _collect_simple_properties(node),
			"node_props": _collect_child_script_properties(node),
		})
	return entries


## Some placeable scenes put their script on a child (EvacPoint's script lives
## on Area3D). Collect those exports under a relative node path so runtime edits
## such as service rate, queue limits and receiving capacity survive a save.
func _collect_child_script_properties(root: Node) -> Array:
	var entries: Array = []

	for child: Node in root.find_children("*", "", true, false):
		if child.get_script() == null:
			continue

		var props := _collect_simple_properties(child)

		if props.is_empty():
			continue

		entries.append({
			"path": String(root.get_path_to(child)),
			"props": props,
		})

	return entries


func _collect_simple_properties(node: Node) -> Dictionary:
	var props: Dictionary = {}
	for info in node.get_property_list():
		if not (int(info.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
			continue
		var key := String(info.get("name", ""))
		if key.is_empty() or key.begins_with("_") or PLACEABLE_SKIP.has(key):
			continue
		var value: Variant = node.get(key)
		if (
			value is int
			or value is float
			or value is bool
			or value is String
			or value is StringName
			or value is Vector2
			or value is Vector3
			or value is Color
		):
			var runtime = get_node_or_null("/root/RuntimeExports")
			props[key] = (
				runtime.call("encode_value", value)
				if runtime != null and runtime.has_method("encode_value")
				else value
			)
	return props


func _apply_saved_props(target: Node, props: Dictionary) -> void:
	if target == null:
		return

	var runtime = get_node_or_null("/root/RuntimeExports")

	for key: Variant in props:
		var value: Variant = props[key]

		if runtime != null and runtime.has_method("decode_value"):
			value = runtime.call("decode_value", value)

		target.set(String(key), value)


func _apply_manifest(manifest: Dictionary) -> void:
	var tree := get_tree()

	for node in tree.get_nodes_in_group("placeables"):
		if is_instance_valid(node):
			node.queue_free()
	await tree.process_frame
	await tree.process_frame

	var scene_root := tree.current_scene
	if scene_root != null:
		for entry: Dictionary in manifest.get("placeables", []):
			var scene_path := String(entry.get("scene", ""))
			if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
				continue
			var packed := load(scene_path) as PackedScene
			if packed == null:
				continue
			var instance := packed.instantiate()
			if instance == null:
				continue
			var props: Dictionary = entry.get("props", {})
			_apply_saved_props(instance, props)

			for group: Dictionary in entry.get("node_props", []):
				var path := String(group.get("path", ""))

				if path.is_empty() or path == ".":
					continue

				var target := instance.get_node_or_null(NodePath(path))

				if target == null:
					continue

				var child_props: Dictionary = group.get("props", {})
				_apply_saved_props(target, child_props)

			scene_root.add_child(instance)
			# Keep restored placeables in the same group used by the save scan,
			# even if a scene forgets to register itself. This keeps them alive
			# through the next save/load cycle too.
			instance.add_to_group("placeables")
			var values: Array = entry.get("xform", [])
			if values.size() == 12:
				instance.global_transform = Transform3D(
					Vector3(values[0], values[1], values[2]),
					Vector3(values[3], values[4], values[5]),
					Vector3(values[6], values[7], values[8]),
					Vector3(values[9], values[10], values[11])
				)

	var player := tree.get_first_node_in_group("Player") as Node3D
	var player_data: Dictionary = manifest.get("player", {})
	if player != null and not player_data.is_empty():
		var pos: Array = player_data.get("pos", [])
		if pos.size() == 3:
			player.global_position = Vector3(pos[0], pos[1], pos[2])
		player.rotation.y = float(player_data.get("yaw", 0.0))
		var pitch := float(player_data.get("pitch", 0.0))
		player.set("camera_x_rotation", pitch)
		var camera := player.get_node_or_null("head/CameraSmooth/Camera3D") as Camera3D
		if camera != null:
			camera.rotation.x = pitch

	var cycle := scene_root.get_node_or_null("CycleController") if scene_root != null else null
	if cycle != null and manifest.has("cycle_time"):
		cycle.set("_current_time", float(manifest.get("cycle_time", 0.0)))

	# The run seed belongs to the save, so loading a slot restores the seed its
	# recorded runs were produced with.
	var global_data = get_node_or_null("/root/GlobalData")
	if global_data != null and manifest.has("sim_seed"):
		global_data.rng_seed = int(manifest.get("sim_seed", global_data.rng_seed))

	if global_data != null and global_data.has_method("reset_spawning"):
		global_data.reset_spawning()

	var runtime = get_node_or_null("/root/RuntimeExports")

	if runtime != null and runtime.has_method("apply_live"):
		var runtime_block: Variant = manifest.get("runtime_exports", {})

		if runtime_block is Dictionary and not runtime_block.is_empty():
			runtime.call("apply_live", runtime_block)
		elif runtime.has_method("apply_defaults_to_live"):
			runtime.call("apply_defaults_to_live")


func _flush_world() -> void:
	var streamer := get_tree().get_first_node_in_group("chunk_streamer")
	if streamer != null and streamer.has_method("flush_world"):
		streamer.flush_world()
		return

	var grid := get_tree().get_first_node_in_group("grid_map")
	if grid == null:
		return
	var store := ChunkFileStore.new(_live_chunks())
	grid.save_all_chunks(Callable(store, "save_chunk"))


func _live_chunks() -> String:
	var streamer := get_tree().get_first_node_in_group("chunk_streamer")
	if streamer != null and streamer.has_method("get_chunk_store_dir"):
		var path := String(streamer.get_chunk_store_dir())
		if not path.is_empty():
			return path
	return LIVE_CHUNKS_FALLBACK


func _read_manifest(slug: String) -> Dictionary:
	var path := SAVES_ROOT.path_join(slug).path_join(MANIFEST)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return parsed
	return {}


func _write_manifest(folder: String, manifest: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var file := FileAccess.open(folder.path_join(MANIFEST), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(manifest, "\t"))
	file.close()


func _make_unique(name: String) -> Array:
	var base := name.strip_edges()
	if base.is_empty():
		base = "New Map"

	var candidate := base
	var slug := _slugify(candidate)
	var index := 2
	while DirAccess.dir_exists_absolute(SAVES_ROOT.path_join(slug)):
		candidate = "%s (%d)" % [base, index]
		slug = _slugify(candidate)
		index += 1
	return [candidate, slug]


func _slugify(name: String) -> String:
	var slug := name.strip_edges()
	for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]:
		slug = slug.replace(ch, "_")
	slug = slug.replace(" ", "_")
	if slug.is_empty():
		slug = "save"
	if slug.length() > 48:
		slug = slug.substr(0, 48)
	return slug


func _copy_dir(source: String, target: String) -> bool:
	DirAccess.make_dir_recursive_absolute(target)
	var dir := DirAccess.open(source)
	if dir == null:
		return false
	dir.list_dir_begin()
	var file := dir.get_next()
	while not file.is_empty():
		if not file.begins_with("."):
			var from := source.path_join(file)
			var to := target.path_join(file)
			if dir.current_is_dir():
				_copy_dir(from, to)
			else:
				DirAccess.copy_absolute(from, to)
		file = dir.get_next()
	dir.list_dir_end()
	return true


func _clear_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while not file.is_empty():
		if not file.begins_with("."):
			var child := path.path_join(file)
			if dir.current_is_dir():
				_remove_dir(child)
			else:
				DirAccess.remove_absolute(child)
		file = dir.get_next()
	dir.list_dir_end()


func _remove_dir(path: String) -> void:
	_clear_dir(path)
	DirAccess.remove_absolute(path)


func _save_active() -> void:
	var config := ConfigFile.new()
	config.set_value("save", "active_slug", active_slug)
	config.save(ACTIVE_PATH)


func _load_active() -> void:
	var config := ConfigFile.new()
	if config.load(ACTIVE_PATH) != OK:
		return
	active_slug = String(config.get_value("save", "active_slug", ""))
