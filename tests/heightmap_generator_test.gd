extends SceneTree

## Heightmap terrain generator tests and cost measurements.
##
##   godot --headless --path . --script res://tests/heightmap_generator_test.gd
##
## Covers the hard slope guarantee (adjacent columns differ by at most one
## block), footprint bounds, determinism, the recipe path, 256 x 256 generation
## cost, and per-chunk collision build cost on a real NavGridMap.

const Gen = preload("res://scripts/world/HeightmapTerrainGenerator.gd")
const Recipe = preload("res://scripts/world/WorldRecipe.gd")
const Store = preload("res://scripts/world/VoxelSectionStore.gd")
const Streamer = preload("res://scripts/world/ChunkStreamer.gd")

const SEED: int = 12345

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== heightmap terrain ===")

	_test_slope_and_bounds()
	_test_step_slabs()
	_test_determinism()
	_test_params_round_trip()
	_test_generation_cost()
	await _test_collision_cost()
	await _test_lod()
	await _test_streamer_generation()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _make_generator(origin: Vector2i, size: Vector2i) -> Gen:
	var generator = Gen.new()
	generator.noise_seed = SEED
	generator.footprint_origin = origin
	generator.footprint_size = size
	generator.base_height = 0
	generator.amplitude = 6.0
	generator.scale = 64.0
	generator.octaves = 4
	generator.persistence = 0.5
	generator.lacunarity = 2.0
	generator.ridge_amount = 0.35
	generator.coarse_spacing = 8
	generator.surface_item = 0
	generator.subsurface_item = 1
	generator.column_depth = 3
	# Most tests assert exact column cell counts; the slab pass is covered by
	# `_test_step_slabs()` with its own generator.
	generator.step_slabs_enabled = false
	generator.invalidate()
	return generator


func _test_step_slabs() -> void:
	var fresh = Gen.new()
	_expect(
		"slabs: enabled by default with the bottom slab item",
		fresh.step_slabs_enabled and fresh.step_slab_item == 46,
		"%s / %s" % [fresh.step_slabs_enabled, fresh.step_slab_item]
	)

	var generator = _make_generator(Vector2i(-64, -64), Vector2i(128, 128))
	generator.step_slabs_enabled = true
	generator.step_slab_item = 2
	var chunk := Vector2i(0, 0)
	var cells: Array = generator.generate_column(chunk, {})
	var by_position: Dictionary = {}
	var slab_columns: Dictionary = {}

	for cell: Dictionary in cells:
		var position: Vector3i = cell["position"]
		by_position[position] = int(cell["item"])

		if int(cell["item"]) == generator.step_slab_item:
			slab_columns[Vector2i(position.x, position.z)] = position.y

	var expected_slabs: int = 0
	var missing: int = 0
	var false_positives: int = 0

	for local_x in 16:
		for local_z in 16:
			var x: int = chunk.x * 16 + local_x
			var z: int = chunk.y * 16 + local_z
			var column: Dictionary = generator.sample_column(x, z)

			if column.is_empty():
				continue

			var top: int = int(column["height"])
			var higher: bool = false

			for offset: Vector2i in [
				Vector2i(1, 0),
				Vector2i(-1, 0),
				Vector2i(0, 1),
				Vector2i(0, -1),
			]:
				var neighbor: Dictionary = generator.sample_column(
					x + offset.x,
					z + offset.y
				)

				if not neighbor.is_empty() and int(neighbor["height"]) > top:
					higher = true
					break

			var has_slab: bool = slab_columns.has(Vector2i(x, z))

			if higher:
				expected_slabs += 1

				if not has_slab or int(slab_columns[Vector2i(x, z)]) != top + 1:
					missing += 1
			elif has_slab:
				false_positives += 1

	_expect("slabs: at least one step slab emitted", expected_slabs > 0, str(expected_slabs))
	_expect(
		"slabs: every lower side of a step gets a slab at top + 1",
		missing == 0,
		"%d missing of %d" % [missing, expected_slabs]
	)
	_expect("slabs: no slab on flat or high columns", false_positives == 0, str(false_positives))


func _test_slope_and_bounds() -> void:
	var origin := Vector2i(-32, -32)
	var size := Vector2i(64, 64)
	var generator = _make_generator(origin, size)
	var heights: Dictionary = {}
	var holes: int = 0

	for x in size.x:
		for z in size.y:
			var column: Dictionary = generator.sample_column(
				origin.x + x,
				origin.y + z
			)

			if column.is_empty():
				holes += 1
				continue

			heights[Vector2i(x, z)] = int(column["height"])

	_expect("slope: no holes in the footprint", holes == 0, str(holes))
	_expect(
		"slope: every column sampled",
		heights.size() == size.x * size.y,
		str(heights.size())
	)

	var worst: int = 0

	for x in size.x:
		for z in size.y:
			var here: int = int(heights[Vector2i(x, z)])

			if x + 1 < size.x:
				worst = maxi(
					worst,
					absi(here - int(heights[Vector2i(x + 1, z)]))
				)
			if z + 1 < size.y:
				worst = maxi(
					worst,
					absi(here - int(heights[Vector2i(x, z + 1)]))
				)

	_expect("slope: worst adjacent delta <= 1 block", worst <= 1, str(worst))

	_expect(
		"bounds: outside returns nothing",
		generator.sample_column(origin.x - 1, origin.y).is_empty()
		and generator.sample_column(
			origin.x + size.x,
			origin.y
		).is_empty()
		and generator.sample_column(
			origin.x,
			origin.y - 1
		).is_empty()
		and generator.sample_column(
			origin.x,
			origin.y + size.y
		).is_empty(),
		""
	)

	# A chunk fully outside the footprint emits no cells.
	_expect(
		"bounds: chunk outside is empty",
		generator.generate_column(Vector2i(50, 50), {}).is_empty(),
		""
	)


func _test_determinism() -> void:
	var generator_a = _make_generator(Vector2i(-64, -64), Vector2i(128, 128))
	var generator_b = _make_generator(Vector2i(-64, -64), Vector2i(128, 128))

	var recipe_a = Recipe.new()
	recipe_a.generator = generator_a
	var recipe_b = Recipe.new()
	recipe_b.generator = generator_b

	var chunk := Vector2i(0, 0)
	var first: Dictionary = recipe_a.generate_chunk_data(chunk)
	var second: Dictionary = recipe_b.generate_chunk_data(chunk)

	_expect("determinism: data emitted", not first.is_empty(), "")
	_expect(
		"determinism: same params produce identical bytes",
		first.get("sections") == second.get("sections"),
		""
	)

	var third: Dictionary = recipe_a.generate_chunk_data(chunk)
	_expect(
		"determinism: repeat call is identical",
		first.get("sections") == third.get("sections"),
		""
	)

	# Changing the seed must change the world.
	generator_a.noise_seed = SEED + 1
	generator_a.invalidate()
	var changed: Dictionary = recipe_a.generate_chunk_data(chunk)
	_expect(
		"determinism: a different seed changes the bytes",
		first.get("sections") != changed.get("sections"),
		""
	)


func _test_params_round_trip() -> void:
	var source = _make_generator(Vector2i(-64, -64), Vector2i(128, 128))
	var copy = Gen.new()
	copy.apply_params(source.get_params())

	var recipe_a = Recipe.new()
	recipe_a.generator = source
	var recipe_b = Recipe.new()
	recipe_b.generator = copy

	var chunk := Vector2i(0, 0)
	var first: Dictionary = recipe_a.generate_chunk_data(chunk)
	var second: Dictionary = recipe_b.generate_chunk_data(chunk)

	_expect("params: round-trip emits data", not first.is_empty(), "")
	_expect(
		"params: get_params -> apply_params reproduces the world",
		first.get("sections") == second.get("sections"),
		""
	)


func _test_generation_cost() -> void:
	var origin := Vector2i(-128, -128)
	var size := Vector2i(256, 256)
	var generator = _make_generator(origin, size)
	var recipe = Recipe.new()
	recipe.generator = generator

	var chunk_origin: Vector2i = origin / 16
	var chunks_per_axis: int = size.x / 16
	var chunks: int = 0
	var blob_bytes: int = 0
	var section_blobs: Array[PackedByteArray] = []
	var chunk_keys: Array[Vector2i] = []

	var start: int = Time.get_ticks_usec()

	for cx in chunks_per_axis:
		for cz in chunks_per_axis:
			var chunk := Vector2i(
				chunk_origin.x + cx,
				chunk_origin.y + cz
			)
			var data: Dictionary = recipe.generate_chunk_data(chunk)

			if data.is_empty():
				continue

			var blob: PackedByteArray = data["sections"]
			chunks += 1
			blob_bytes += blob.size()
			section_blobs.append(blob)
			chunk_keys.append(chunk)

	var generate_usec: int = Time.get_ticks_usec() - start

	var store_start: int = Time.get_ticks_usec()
	var store = Store.new()
	var decoded_entries: int = 0

	for index in section_blobs.size():
		var entries: Array[Dictionary] = Store.decode_column_compressed(
			chunk_keys[index],
			section_blobs[index]
		)

		for entry: Dictionary in entries:
			store.set_cell(
				entry["position"],
				int(entry["item"]),
				int(entry["orientation"])
			)
			decoded_entries += 1

	var store_usec: int = Time.get_ticks_usec() - store_start
	var cells: int = store.cell_count()
	var store_bytes: int = store.memory_bytes()
	var bytes_per_cell: float = float(store_bytes) / float(maxi(cells, 1))
	var expected_cells: int = size.x * size.y * generator.column_depth

	_expect("cost: all chunks generated", chunks == chunks_per_axis * chunks_per_axis, str(chunks))
	_expect("cost: decoded entries", decoded_entries == expected_cells, str(decoded_entries))
	_expect("cost: store cells", cells == expected_cells, str(cells))
	_expect(
		"cost: store under 8 bytes/cell",
		bytes_per_cell < 8.0,
		"%.2f" % bytes_per_cell
	)

	print(
		"[terrain] %dx%d: %d chunks, %d cells | generate %.1f ms (%.2f ms/chunk) | blobs %d B | store %d B (%.2f B/cell) | store build %.1f ms"
		% [
			size.x,
			size.y,
			chunks,
			cells,
			float(generate_usec) / 1000.0,
			float(generate_usec) / 1000.0 / float(maxi(chunks, 1)),
			blob_bytes,
			store_bytes,
			bytes_per_cell,
			float(store_usec) / 1000.0,
		]
	)


func _test_collision_cost() -> void:
	var origin := Vector2i(-32, -32)
	var size := Vector2i(64, 64)
	var generator = _make_generator(origin, size)
	var recipe = Recipe.new()
	recipe.generator = generator

	var grid := _make_grid()
	var chunk_origin: Vector2i = origin / 16
	var chunks_per_axis: int = size.x / 16
	var loaded: int = 0

	for cx in chunks_per_axis:
		for cz in chunks_per_axis:
			var chunk := Vector2i(
				chunk_origin.x + cx,
				chunk_origin.y + cz
			)
			var data: Dictionary = recipe.generate_chunk_data(chunk)

			if data.is_empty():
				continue

			grid.load_chunk(data, false, false)
			loaded += 1

	_expect("collision: chunks loaded", loaded == chunks_per_axis * chunks_per_axis, str(loaded))

	# Let the deferred ChunkMeshes root enter the tree and the mesher build.
	for _i in 30:
		await process_frame

	await physics_frame

	var stats: Dictionary = grid.get_chunk_collision_stats()
	var bodies: int = int(stats.get("bodies", 0))
	var builds: int = int(stats.get("builds", 0))
	var build_usec: int = int(stats.get("build_usec", 0))
	var average_usec: float = float(build_usec) / float(maxi(builds, 1))

	_expect("collision: bodies built", bodies > 0, str(bodies))
	_expect("collision: trimeshes built", builds > 0, str(builds))

	var space := grid.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		grid.to_global(Vector3(0.5, 20.0, 0.5)),
		grid.to_global(Vector3(0.5, -20.0, 0.5))
	)
	query.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(query)

	_expect("collision: terrain ray hits", not hit.is_empty(), "")

	# Chunk navigation must connect across a chunk border. This exercises the
	# fast initial-build path used by the streamer (no full expanded refresh).
	var left_chunk := Vector2i(chunk_origin.x, chunk_origin.y)
	var right_chunk := left_chunk + Vector2i(1, 0)
	grid.build_chunk_navigation(left_chunk)
	grid.build_chunk_navigation(right_chunk)
	var start_top: int = int(generator.sample_column(-20, -20).get("height", 0))
	var end_top: int = int(generator.sample_column(-12, -20).get("height", 0))
	var start_world: Vector3 = (
		grid.map_to_local(Vector3i(-20, start_top, -20)) + Vector3.UP * 0.5
	)
	var end_world: Vector3 = (
		grid.map_to_local(Vector3i(-12, end_top, -20)) + Vector3.UP * 0.5
	)
	var path: Array = grid.get_path_cells(start_world, end_world)
	_expect(
		"nav: chunk navigation loads both chunks",
		grid.is_chunk_navigation_loaded(left_chunk)
		and grid.is_chunk_navigation_loaded(right_chunk),
		""
	)
	_expect("nav: path crosses the chunk border", path.size() >= 8, str(path.size()))
	_expect(
		"nav: path starts and ends on the requested cells",
		not path.is_empty()
		and Vector3i(path[0]) == Vector3i(-20, start_top, -20)
		and Vector3i(path[path.size() - 1]) == Vector3i(-12, end_top, -20),
		"" if path.is_empty() else "%s -> %s" % [path[0], path[path.size() - 1]]
	)

	print(
		"[terrain] collision %dx%d: %d chunks | %d bodies, %d builds | %.2f ms/build, %.1f ms total"
		% [
			size.x,
			size.y,
			loaded,
			bodies,
			builds,
			average_usec / 1000.0,
			float(build_usec) / 1000.0,
		]
	)

	grid.free()


func _test_lod() -> void:
	var origin := Vector2i(-64, -64)
	var size := Vector2i(128, 128)
	var generator = _make_generator(origin, size)
	var recipe = Recipe.new()
	recipe.generator = generator

	var grid: NavGridMap = _make_grid()
	var mesher := grid.get_mesher()

	if mesher == null:
		_expect("lod: mesher exists", false, "")
		grid.free()
		return

	mesher.lod0_radius_chunks = 1
	mesher.lod1_radius_chunks = 2
	mesher.set_lod_enabled(true)

	var chunk_origin: Vector2i = origin / 16
	var chunks_per_axis: int = size.x / 16

	for cx in chunks_per_axis:
		for cz in chunks_per_axis:
			var chunk := Vector2i(
				chunk_origin.x + cx,
				chunk_origin.y + cz
			)
			var data: Dictionary = recipe.generate_chunk_data(chunk)

			if not data.is_empty():
				grid.load_chunk(data, false, false)

	mesher.set_view_center(Vector2i.ZERO, chunks_per_axis)

	for _i in 100:
		await process_frame

	await physics_frame

	var stats: Dictionary = grid.get_chunk_lod_stats()
	var populated: int = grid.get_populated_chunks().size()

	_expect(
		"lod: all populated chunks meshed",
		int(stats.get("meshed", 0)) == populated,
		"%s/%s" % [stats.get("meshed", 0), populated]
	)
	_expect("lod: full detail present", int(stats.get("lod0", 0)) > 0, str(stats))
	_expect("lod: mid detail present", int(stats.get("lod1", 0)) > 0, str(stats))
	_expect("lod: far detail present", int(stats.get("lod2", 0)) > 0, str(stats))
	_expect(
		"lod: collision only on full detail",
		int(stats.get("collision", 0)) == int(stats.get("lod0", 0)),
		str(stats)
	)

	var far := Vector3i(60, 20, 60)
	var query := PhysicsRayQueryParameters3D.create(
		grid.to_global(Vector3(far.x + 0.5, 40.0, far.z + 0.5)),
		grid.to_global(Vector3(far.x + 0.5, -20.0, far.z + 0.5))
	)
	query.collision_mask = 1
	var hit: Dictionary = grid.get_world_3d().direct_space_state.intersect_ray(
		query
	)

	_expect("lod: far chunk has no collision body", hit.is_empty(), "")

	grid.free()


func _test_streamer_generation() -> void:
	var temp_dir := "user://test_terrain_world"
	_remove_dir(temp_dir)

	var container := Node3D.new()
	container.name = "TerrainStreamTest"
	root.add_child(container)

	var player := Node3D.new()
	player.name = "Player"
	player.position = Vector3(0, 6, 0)
	container.add_child(player)

	var grid: NavGridMap = _make_grid(container)
	grid.name = "GridMap"

	var recipe = Recipe.new()
	recipe.generator = _make_generator(Vector2i(-128, -128), Vector2i(256, 256))

	var streamer = Streamer.new()
	streamer.name = "ChunkStreamer"
	streamer.player_path = NodePath("../Player")
	streamer.grid_path = NodePath("../GridMap")
	streamer.chunk_store_dir = temp_dir
	streamer.generate_flat_floor = true
	streamer.world_recipe = recipe
	streamer.load_radius_chunks = 4
	streamer.unload_radius_chunks = 6
	streamer.mesh_radius_chunks = 4
	streamer.nav_radius_chunks = 2
	streamer.max_loaded_chunks = 128
	streamer.scan_interval = 100.0
	container.add_child(streamer)

	for _i in 90:
		await process_frame

	var stats: Dictionary = streamer.get_stats()
	var loaded: int = int(stats.get("loaded", 0))
	var cells: int = grid.get_used_block_cells().size()
	var bodies: int = grid.get_chunk_collision_body_count()

	_expect(
		"streamer: recipe reported",
		str(stats.get("recipe", "")) == "heightmap_v1",
		str(stats.get("recipe", ""))
	)
	_expect("streamer: generated chunks loaded", loaded > 0, str(loaded))
	_expect("streamer: generated cells present", cells > 0, str(cells))
	_expect("streamer: collision built", bodies > 0, str(bodies))

	container.queue_free()
	await process_frame
	_remove_dir(temp_dir)


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)

	if dir != null:
		dir.list_dir_begin()
		var file: String = dir.get_next()

		while not file.is_empty():
			if not dir.current_is_dir():
				dir.remove(file)
			file = dir.get_next()

		dir.list_dir_end()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

func _make_grid(parent: Node = null) -> NavGridMap:
	var grid := NavGridMap.new()
	grid.name = "HeightmapTestGrid"
	grid.mesh_library = _make_library()
	grid.cell_size = Vector3.ONE
	grid.enable_greedy_meshing = true
	grid.enable_flow_fields = false
	grid.auto_generate_stairs = false
	grid.wall_force_enabled = false

	var host: Node = parent if parent != null else root
	host.add_child(grid)
	return grid


func _make_library() -> MeshLibrary:
	var library := MeshLibrary.new()
	var box := BoxMesh.new()
	var shape := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.size = Vector3.ONE

	for item in 4:
		library.create_item(item)
		library.set_item_name(item, "Terrain%d" % item)
		library.set_item_mesh(item, box)
		library.set_item_shapes(item, [shape, Transform3D.IDENTITY])

	return library


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + label)
		return

	_failures += 1
	print("  FAIL  " + label + ("" if detail.is_empty() else "  [" + detail + "]"))
