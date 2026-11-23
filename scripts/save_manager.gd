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
const SORT_LAST_PLAYED := "last_played"
const SORT_CREATED := "created"
const SORT_NAME := "name"
const SORT_MODIFIED := "modified"
const SORT_MODES: Array[String] = [
	SORT_LAST_PLAYED,
	SORT_CREATED,
	SORT_NAME,
	SORT_MODIFIED,
]
const MAP_RENDERER := preload("res://scripts/map_renderer.gd")
const WORLD_RECIPE_SCRIPT := preload("res://scripts/world/WorldRecipe.gd")
const WORLD_GENERATOR_REGISTRY := preload("res://scripts/world/WorldGeneratorRegistry.gd")
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
## Order used by list_saves(): last played (default), date created,
## alphabetically, or date modified. Persisted in active_save.cfg.
var sort_mode: String = SORT_LAST_PLAYED


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
		var modified := float(manifest.get("modified", 0.0))
		result.append({
			"slug": slug,
			"name": String(manifest.get("name", slug)),
			"created": float(manifest.get("created", modified)),
			"modified": modified,
			"last_played": float(manifest.get("last_played", modified)),
			"thumbnail": _thumbnail_path(slug),
			"world_type": String(
				manifest.get("world", {}).get("type", "existing")
			),
			"world_generator": String(
				manifest.get("world", {}).get("generator", "")
			),
			"world_seed": int(manifest.get("world", {}).get("seed", 0)),
			"world_size": String(
				manifest.get("world", {}).get("size", "")
			),
		})
	result.sort_custom(_save_sort_before)
	return result


## True when `a` should appear before `b` under the current sort mode.
func _save_sort_before(a: Dictionary, b: Dictionary) -> bool:
	if sort_mode == SORT_NAME:
		var a_name := String(a.get("name", "")).to_lower()
		var b_name := String(b.get("name", "")).to_lower()
		if a_name == b_name:
			return float(a.get("modified", 0.0)) > float(b.get("modified", 0.0))
		return a_name < b_name

	var field := SORT_LAST_PLAYED
	if sort_mode == SORT_CREATED:
		field = "created"
	elif sort_mode == SORT_MODIFIED:
		field = "modified"

	var a_time := float(a.get(field, 0.0))
	var b_time := float(b.get(field, 0.0))
	if absf(a_time - b_time) < 0.0001:
		return (
			String(a.get("name", "")).to_lower()
			< String(b.get("name", "")).to_lower()
		)
	return a_time > b_time


## Cycles "last played" -> "date created" -> "alphabetically" -> "date
## modified" -> back. The choice is persisted with the active-save pointer.
func cycle_sort_mode() -> String:
	var index := SORT_MODES.find(sort_mode)
	sort_mode = SORT_MODES[(index + 1) % SORT_MODES.size()]
	_save_active()
	saves_changed.emit()
	return sort_mode


## Human-readable name for the current sort mode, used by the Saves button.
func sort_mode_label() -> String:
	match sort_mode:
		SORT_CREATED:
			return "Date Created"
		SORT_NAME:
			return "Alphabetically"
		SORT_MODIFIED:
			return "Date Modified"
		_:
			return "Last Played"


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


func save_as(save_name: String) -> String:
	var pair := _make_unique(save_name)
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

	# Loading is the "play" event that the default sort uses.
	manifest["last_played"] = Time.get_unix_time_from_system()
	_write_manifest(folder, manifest)

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
	manifest["last_played"] = Time.get_unix_time_from_system()
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
func new_blank_map(map_name: String, world_options: Dictionary = {}) -> String:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return ""

	var display := map_name.strip_edges()
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

	var world := _normalise_world_metadata(world_options, "blank")
	var is_procgen := String(world.get("type", "")) == "procgen"

	if is_procgen:
		var version_recipe := _make_world_recipe(world)
		if version_recipe != null:
			var version_generator: Variant = version_recipe.get("generator")
			if (
				version_generator != null
				and version_generator.has_method("get_version")
			):
				world["generator_version"] = int(
					version_generator.get_version()
				)

	var new_streamer := tree.get_first_node_in_group("chunk_streamer")

	if is_procgen:
		# A generated world must not inherit the scene's starter platform.
		grid.reset_world()

		if new_streamer != null and new_streamer.has_method("reset_streaming"):
			new_streamer.reset_streaming()

	_apply_world_to_streamer(new_streamer, world)

	# A scene reload creates fresh nodes with their inspector defaults. Re-apply
	# the saved quality/radii here so a New Map uses the same draw distance and
	# budgets as a loaded save instead of silently falling back to Medium.
	var settings = get_node_or_null("/root/PerformanceSettings")
	if settings != null and settings.has_method("apply_all"):
		settings.apply_all()

	if is_procgen and new_streamer != null:
		# Bulk generation does not need A*; keep it out of the generation frames.
		new_streamer.set("defer_navigation", true)

	var gd := get_node_or_null("/root/GlobalData")

	if gd != null and gd.has_method("reset_spawning"):
		gd.call("reset_spawning")

	var runtime = get_node_or_null("/root/RuntimeExports")
	if runtime != null and runtime.has_method("apply_defaults_to_live"):
		runtime.call("apply_defaults_to_live")

	var player := tree.get_first_node_in_group("Player") as Node3D
	var spawn_cell := Vector3i.ZERO

	if is_procgen:
		# Find the terrain surface at the world origin and wait for the streamer
		# to generate that chunk before dropping the player in.
		var top: int = 0
		var recipe := _make_world_recipe(world)

		if recipe != null:
			var generator: Variant = recipe.get("generator")

			if generator != null and generator.has_method("sample_column"):
				var column: Dictionary = generator.sample_column(0, 0)
				top = int(column.get("height", 0))

		spawn_cell = Vector3i(0, top, 0)

		var deadline: int = Time.get_ticks_msec() + 5000

		while not grid.has_block(spawn_cell) and Time.get_ticks_msec() < deadline:
			await tree.process_frame

		if not grid.has_block(spawn_cell):
			push_warning(
				"SaveManager: procgen spawn chunk did not generate in time."
			)
	else:
		var platform_y := clampi(
			0,
			int(grid.min_block_y),
			int(grid.max_block_y)
		)
		var block_id := _blank_platform_item(grid)
		var platform_cells: Array[Vector3i] = []
		for dx in range(-3, 4):
			for dz in range(-3, 4):
				platform_cells.append(Vector3i(dx, platform_y, dz))
		grid.place_blocks(platform_cells, block_id, 0)
		spawn_cell = Vector3i(0, platform_y, 0)

	if player != null:
		var center: Vector3 = grid.to_global(
			grid.map_to_local(spawn_cell)
		)
		player.global_position = Vector3(
			center.x,
			center.y + grid.cell_size.y * 0.5 + 1.6,
			center.z
		)
		player.rotation = Vector3.ZERO
		player.set("camera_x_rotation", 0.0)

		# A generated world still has to stream/mesh its spawn chunk. Keep the
		# player frozen so it cannot fall while the floor is being built; it is
		# re-placed on the finished surface before the save is written.
		if is_procgen:
			player.set_physics_process(false)
		else:
			# The starter platform is placed into a fresh chunk; wait for its
			# collision before letting the player fall onto it.
			await _wait_for_spawn_collision(player)

	if is_procgen:
		# Fill the whole bounded footprint before saving. Otherwise the slot
		# stores only the first few seconds of generation and every load shows
		# holes until the rest regenerates.
		var footprint_recipe := _make_world_recipe(world)
		var expected_chunks: int = 0

		if footprint_recipe != null:
			if footprint_recipe.has_method("get_footprint_chunk_count"):
				expected_chunks = int(
					footprint_recipe.get_footprint_chunk_count()
				)

		if expected_chunks > 0:
			var gen_deadline: int = Time.get_ticks_msec() + 25000

			while (
				grid.get_populated_chunks().size() < expected_chunks
				and Time.get_ticks_msec() < gen_deadline
			):
				await tree.process_frame

			if grid.get_populated_chunks().size() < expected_chunks:
				push_warning(
					"SaveManager: generated %d/%d world chunks before saving."
					% [grid.get_populated_chunks().size(), expected_chunks]
				)

			# Also wait for the mesher to finish the initial LOD pass. The save
			# itself only needs cells, but opening a world with unmeshed chunks
			# looks like missing terrain.
			var mesh_deadline: int = Time.get_ticks_msec() + 15000

			while (
				int(grid.get_chunk_lod_stats().get("meshed", 0)) < expected_chunks
				and Time.get_ticks_msec() < mesh_deadline
			):
				await tree.process_frame

		if new_streamer != null:
			new_streamer.set("defer_navigation", false)

		if player != null:
			var spawn_center: Vector3 = grid.to_global(
				grid.map_to_local(spawn_cell)
			)
			player.global_position = Vector3(
				spawn_center.x,
				spawn_center.y + grid.cell_size.y * 0.5 + 1.6,
				spawn_center.z
			)

			if player is CharacterBody3D:
				(player as CharacterBody3D).velocity = Vector3.ZERO

			player.set_physics_process(true)

	await tree.create_timer(0.35).timeout

	_flush_world()
	var folder := SAVES_ROOT.path_join(slug)
	DirAccess.make_dir_recursive_absolute(folder)
	_clear_dir(folder.path_join("chunks"))
	_copy_dir(_live_chunks(), folder.path_join("chunks"))
	_write_thumbnail(folder)

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
func new_map(map_name: String, world_options: Dictionary = {}) -> String:
	return await new_blank_map(map_name, world_options)


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
		var item_name := String(grid.mesh_library.get_item_name(item_id)).to_lower()
		if (
			not item_name.contains("slab")
			and not item_name.contains("panel")
			and not item_name.contains("stairs")
			and not item_name.begins_with("water_")
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
		"last_played": now,
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
		"generator_version": 0,
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
	result["generator_version"] = int(world.get("generator_version", 0))
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


## Builds the generator recipe pinned by a world descriptor. Returns null for
## non-procgen worlds or an unknown generator id.
func _make_world_recipe(world: Dictionary) -> Resource:
	if String(world.get("type", "")) != "procgen":
		return null

	var generator_id := String(world.get("generator", "heightmap_v1"))
	var generator: WorldGenerator = WORLD_GENERATOR_REGISTRY.create(generator_id)

	if generator == null:
		push_warning("SaveManager: unknown world generator '%s'." % generator_id)
		return null

	generator.apply_params(_generator_params(world))

	var pinned_version := int(world.get("generator_version", 0))

	if (
		pinned_version != 0
		and pinned_version != int(generator.get_version())
	):
		push_warning(
			"SaveManager: world generator version changed (%d -> %d); "
			% [pinned_version, int(generator.get_version())]
			+ "unedited chunks will regenerate."
		)

	var recipe = WORLD_RECIPE_SCRIPT.new()
	recipe.generator = generator
	return recipe


## Size presets are UI-level names; the generator stores blocks. Non-heightmap
## generators keep their own defaults and receive only `options`.
func _generator_params(world: Dictionary) -> Dictionary:
	var generator_id := String(world.get("generator", "heightmap_v1"))
	var params := {}

	if generator_id == "heightmap_v1":
		var size_name := String(world.get("size", "medium"))
		var extent := Vector2i(256, 256)

		match size_name:
			"small":
				extent = Vector2i(128, 128)
			"large":
				extent = Vector2i(384, 384)

		params = {
			"noise_seed": int(world.get("seed", 0)),
			"footprint_origin": [
				-int(extent.x * 0.5),
				-int(extent.y * 0.5),
			],
			"footprint_size": [extent.x, extent.y],
			"column_depth": 3,
		}
	elif generator_id == "flat_v1":
		params = {
			"noise_seed": int(world.get("seed", 0)),
			"floor_y": 0,
		}

	var options: Variant = world.get("options", {})

	if options is Dictionary:
		for key: Variant in options:
			params[key] = options[key]

	return params


## Applies a world descriptor to the live streamer. Procgen worlds get a recipe
## and generation enabled; other worlds get neither. Refreshes streaming so the
## recipe takes effect around the current player position.
func _apply_world_to_streamer(streamer, world: Dictionary) -> void:
	if streamer == null:
		return

	if String(world.get("type", "")) != "procgen":
		streamer.world_recipe = null
		streamer.generate_flat_floor = false
		return

	var recipe := _make_world_recipe(world)

	if recipe == null:
		return

	streamer.world_recipe = recipe
	streamer.generate_flat_floor = true

	if streamer.has_method("refresh_streaming"):
		streamer.refresh_streaming()


## World descriptor for one save slot, for UI display.
func get_world_metadata(slug: String) -> Dictionary:
	var manifest := _read_manifest(slug)

	if manifest.is_empty():
		return {}

	var value: Variant = manifest.get("world", {})

	if value is not Dictionary:
		return _default_world_metadata()

	return _normalise_world_metadata(value)


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

	# Freeze the newly loaded player until the chunk under the saved position
	# has streamed in and built its collision. Otherwise gravity runs against an
	# empty physics world and the player falls through the floor.
	var player := tree.get_first_node_in_group("Player") as Node3D
	var player_physics_was_enabled := true
	if player != null:
		player_physics_was_enabled = player.is_physics_processing()
		player.set_physics_process(false)
		if player is CharacterBody3D:
			(player as CharacterBody3D).velocity = Vector3.ZERO

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

	# Apply the world recipe after the player is in its saved position so the
	# streamer refreshes around the right chunk. Procgen saves keep generating
	# outside their saved chunk area; blank/existing saves do not.
	var world_value: Variant = manifest.get("world", {})
	var world: Dictionary = (
		_normalise_world_metadata(world_value)
		if world_value is Dictionary
		else _default_world_metadata()
	)
	_apply_world_to_streamer(
		tree.get_first_node_in_group("chunk_streamer"),
		world
	)

	if player != null:
		await _wait_for_spawn_collision(player)
		if is_instance_valid(player):
			player.set_physics_process(player_physics_was_enabled)
			if player is CharacterBody3D:
				(player as CharacterBody3D).velocity = Vector3.ZERO

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


## Keeps the player frozen until the saved spawn chunk has streamed in and the
## mesher has committed its collision body. The physics server gets two extra
## frames so move_and_slide cannot run before the new shape is registered.
func _wait_for_spawn_collision(player: Node3D) -> void:
	if player == null or not is_instance_valid(player):
		return

	var tree := get_tree()
	var grid = tree.get_first_node_in_group("grid_map")
	var was_physics := player.is_physics_processing()
	player.set_physics_process(false)
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO

	if grid != null:
		var streamer = tree.get_first_node_in_group("chunk_streamer")
		var chunk: Vector2i = grid.position_to_chunk(player.global_position)

		if streamer != null and streamer.has_method("refresh_streaming"):
			streamer.call("refresh_streaming")

		var uses_mesher: bool = (
			grid.has_method("get_mesher")
			and grid.get_mesher() != null
		)
		var deadline: int = Time.get_ticks_msec() + 10000
		var spawn_ready := false
		var spawn_empty := false

		while Time.get_ticks_msec() < deadline:
			if not is_instance_valid(player):
				break

			var loaded := true
			if streamer != null and streamer.has_method("is_chunk_loaded"):
				loaded = bool(streamer.call("is_chunk_loaded", chunk))

			var collision_ready := true
			if uses_mesher and grid.has_method("has_chunk_collision"):
				collision_ready = bool(grid.call("has_chunk_collision", chunk))
				if not collision_ready:
					var mesher = grid.get_mesher()
					if (
						mesher != null
						and mesher.has_method("queue_chunk")
						and not grid.is_chunk_dirty(chunk)
					):
						mesher.queue_chunk(chunk, true)

			if loaded and collision_ready:
				spawn_ready = true
				break

			# An empty loaded chunk has no floor to wait for (and no collision
			# body will ever appear), so stop blocking instead of timing out.
			if loaded and grid.has_method("get_chunk_cell_count"):
				if int(grid.call("get_chunk_cell_count", chunk)) == 0:
					spawn_empty = true
					break

			await tree.process_frame

		if not spawn_ready and not spawn_empty:
			push_warning(
				"SaveManager: spawn chunk %s was not ready after 10 s." % chunk
			)

		# Let the physics server register the freshly added collision shape.
		await tree.physics_frame
		await tree.physics_frame

	if is_instance_valid(player):
		player.set_physics_process(was_physics)
		if player is CharacterBody3D:
			(player as CharacterBody3D).velocity = Vector3.ZERO


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


func _make_unique(base_name: String) -> Array:
	var base := base_name.strip_edges()
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


func _slugify(raw_name: String) -> String:
	var slug := raw_name.strip_edges()
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
	config.set_value("save", "sort_mode", sort_mode)
	config.save(ACTIVE_PATH)


func _load_active() -> void:
	var config := ConfigFile.new()
	if config.load(ACTIVE_PATH) != OK:
		return
	active_slug = String(config.get_value("save", "active_slug", ""))
	var loaded_sort := String(
		config.get_value("save", "sort_mode", SORT_LAST_PLAYED)
	)
	sort_mode = (
		loaded_sort if SORT_MODES.has(loaded_sort) else SORT_LAST_PLAYED
	)
