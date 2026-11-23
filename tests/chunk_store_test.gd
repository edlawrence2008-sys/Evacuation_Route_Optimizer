extends SceneTree

## Integration test for the packed chunk store behind NavGridMap:
##   - v2 section serialization round-trip through the real grid,
##   - v1 legacy cell-array loading,
##   - WorldRecipe -> chunk data -> load_chunk end to end,
##   - memory accounting for the section index.
##
##   godot --headless --path . --script res://tests/chunk_store_test.gd

const FlatGen = preload("res://scripts/world/FlatGenerator.gd")
const Recipe = preload("res://scripts/world/WorldRecipe.gd")
const ChunkStore = preload("res://scripts/world/ChunkFileStore.gd")

const TEST_STORE_DIR := "user://test_chunk_store"

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== chunk store integration ===")

	_test_v2_round_trip()
	_test_v1_migration()
	_test_recipe_to_grid()
	_test_file_store()
	_test_memory()
	_test_step_slabs_retrofit()
	await _test_collision_mesh()

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _test_v2_round_trip() -> void:
	var source: NavGridMap = _make_grid()
	var chunk := Vector2i(0, 0)
	var expected: Dictionary = {}

	# 16x16 ground floor, a second storey, and one basement cell.
	for x in 16:
		for z in 16:
			_place(source, Vector3i(x, 0, z), 1, 0, expected)
			_place(source, Vector3i(x, 16, z), 2, 1, expected)

	_place(source, Vector3i(3, -1, 4), 3, 2, expected)

	var data: Dictionary = source.serialize_chunk(chunk)

	_expect("v2: version", int(data.get("version", 0)) == 2, str(data.get("version")))
	_expect("v2: section blob", data.get("sections") is PackedByteArray, "")
	_expect("v2: no legacy cells", not data.has("cells"), "")

	var restored: NavGridMap = _make_grid()
	restored.load_chunk(data)
	var restored_cells: Array[Vector3i] = restored.get_chunk_cell_list(chunk)

	_expect("v2: cell count", restored_cells.size() == expected.size(), str(restored_cells.size()))

	var mismatches: int = 0

	for cell: Vector3i in expected:
		var want: Vector2i = expected[cell]

		if (
			restored.get_block_item(cell) != want.x
			or restored.get_block_orientation(cell) != want.y
		):
			mismatches += 1

	_expect("v2: items and orientations match", mismatches == 0, str(mismatches))
	_expect("v2: populated chunk listed", restored.get_populated_chunks().has(chunk), "")
	_expect(
		"v2: chunk cell count",
		restored.get_chunk_cell_count(chunk) == expected.size(),
		str(restored.get_chunk_cell_count(chunk))
	)
	_expect("v2: lowest block Y", restored.get_chunk_lowest_block_y(chunk) == -1, "")
	_expect("v2: highest block Y", restored.get_chunk_highest_block_y(chunk) == 16, "")

	# Fast path: no navigation rebuild means the blob is imported section-by-
	# section instead of decoded into per-cell inserts.
	var fast: NavGridMap = _make_grid()
	fast.load_chunk(data, false, false)
	_expect(
		"v2: fast import cell count",
		fast.get_chunk_cell_count(chunk) == expected.size(),
		str(fast.get_chunk_cell_count(chunk))
	)
	_expect(
		"v2: fast import item",
		fast.get_block_item(Vector3i(3, 0, 3)) == 1,
		str(fast.get_block_item(Vector3i(3, 0, 3)))
	)
	_expect(
		"v2: fast import lowest Y",
		fast.get_chunk_lowest_block_y(chunk) == -1,
		""
	)

	# A sparse section serializes palette_size 0. The fast importer used to
	# reject that and fall back to a per-cell decode.
	var sparse_source: NavGridMap = _make_grid()
	sparse_source.place_block(Vector3i(1, 0, 1), 1, 0)
	sparse_source.place_block(Vector3i(2, 0, 1), 1, 0)
	sparse_source.place_block(Vector3i(1, 0, 2), 1, 0)
	sparse_source.place_block(Vector3i(2, 1, 1), 1, 0)
	var sparse_data: Dictionary = sparse_source.serialize_chunk(chunk)
	var sparse_fast: NavGridMap = _make_grid()
	sparse_fast.load_chunk(sparse_data, false, false)
	_expect(
		"v2: sparse fast import cell count",
		sparse_fast.get_chunk_cell_count(chunk) == 4,
		str(sparse_fast.get_chunk_cell_count(chunk))
	)
	_expect(
		"v2: sparse fast import item",
		sparse_fast.get_block_item(Vector3i(2, 1, 1)) == 1,
		str(sparse_fast.get_block_item(Vector3i(2, 1, 1)))
	)

	var cells: Array = []
	var items: Array = []
	restored.get_chunk_cells_and_items(chunk, cells, items)
	var item_mismatches: int = 0

	for index in cells.size():
		if restored.get_block_item(cells[index]) != int(items[index]):
			item_mismatches += 1

	_expect(
		"v2: cells and items read together",
		cells.size() == items.size() and cells.size() == expected.size(),
		"%d / %d" % [cells.size(), items.size()]
	)
	_expect("v2: parallel item values match", item_mismatches == 0, str(item_mismatches))

	source.free()
	restored.free()
	fast.free()
	sparse_source.free()
	sparse_fast.free()


func _test_v1_migration() -> void:
	var packed := PackedInt32Array()

	for x in 4:
		for z in 4:
			packed.append_array([x, 5, z, 1, 0])

	var legacy: Dictionary = {
		"version": 1,
		"chunk_x": 0,
		"chunk_z": 0,
		"cells": packed,
	}

	var grid: NavGridMap = _make_grid()
	grid.load_chunk(legacy)

	_expect(
		"v1: legacy cells load",
		grid.get_chunk_cell_count(Vector2i(0, 0)) == 16,
		str(grid.get_chunk_cell_count(Vector2i(0, 0)))
	)
	_expect("v1: item preserved", grid.get_block_item(Vector3i(2, 5, 2)) == 1, "")

	# The next save is upgraded to v2.
	var upgraded: Dictionary = grid.serialize_chunk(Vector2i(0, 0))
	_expect("v1 -> v2 on save", int(upgraded.get("version", 0)) == 2, "")

	grid.free()


func _test_recipe_to_grid() -> void:
	var generator = FlatGen.new()
	generator.surface_item = 0  # the fixture MeshLibrary only has item 0

	var recipe = Recipe.new()
	recipe.generator = generator

	var data: Dictionary = recipe.generate_chunk_data(Vector2i(0, 0))
	var grid: NavGridMap = _make_grid()
	grid.load_chunk(data)

	_expect(
		"recipe: cells reach the grid",
		grid.get_chunk_cell_count(Vector2i(0, 0)) == 25,
		str(grid.get_chunk_cell_count(Vector2i(0, 0)))
	)
	_expect(
		"recipe: walkable surface item",
		grid.get_block_item(Vector3i(0, 0, 0)) == 0,
		str(grid.get_block_item(Vector3i(0, 0, 0)))
	)

	# Loading the same data twice must replace, not accumulate.
	grid.load_chunk(data)
	_expect(
		"recipe: reload is idempotent",
		grid.get_chunk_cell_count(Vector2i(0, 0)) == 25,
		str(grid.get_chunk_cell_count(Vector2i(0, 0)))
	)

	grid.free()


func _test_file_store() -> void:
	var store = ChunkStore.new(TEST_STORE_DIR)
	var chunk := Vector2i(0, 0)
	var source: NavGridMap = _make_grid()

	for x in 8:
		for z in 8:
			_place(source, Vector3i(x, 2, z), 1, 0, {})

	var data: Dictionary = source.serialize_chunk(chunk)
	_expect("file: save", store.save_chunk(chunk, data), "")

	var read_back: Dictionary = store.load_chunk(chunk)
	_expect("file: read back", not read_back.is_empty(), "")
	_expect(
		"file: section blob survives",
		read_back.get("sections") is PackedByteArray,
		""
	)

	var restored: NavGridMap = _make_grid()
	restored.load_chunk(read_back)

	_expect(
		"file: cells restore",
		restored.get_chunk_cell_count(chunk) == 64,
		str(restored.get_chunk_cell_count(chunk))
	)
	_expect(
		"file: item restores",
		restored.get_block_item(Vector3i(4, 2, 4)) == 1,
		str(restored.get_block_item(Vector3i(4, 2, 4)))
	)

	DirAccess.remove_absolute(
		ProjectSettings.globalize_path(store.chunk_path(chunk))
	)
	DirAccess.remove_absolute(
		ProjectSettings.globalize_path(TEST_STORE_DIR)
	)

	source.free()
	restored.free()


func _test_collision_mesh() -> void:
	var grid: NavGridMap = _make_grid(true)
	var cells: Array[Vector3i] = []

	for x in 8:
		for z in 8:
			cells.append(Vector3i(x, 0, z))

	grid.place_blocks(cells, 1)

	_expect(
		"mirror: GridMap stores no cells",
		grid.get_used_cells().is_empty(),
		str(grid.get_used_cells().size())
	)
	_expect(
		"mirror: packed store keeps the cells",
		grid.get_block_item(Vector3i(3, 0, 3)) == 1,
		""
	)

	# Let the deferred ChunkMeshes root enter the tree and the mesher build.
	for _i in 12:
		await process_frame

	_expect(
		"collision: chunk bodies built",
		grid.get_chunk_collision_body_count() > 0,
		str(grid.get_chunk_collision_body_count())
	)

	await physics_frame

	var space := grid.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		grid.to_global(Vector3(3.5, 6.0, 3.5)),
		grid.to_global(Vector3(3.5, -2.0, 3.5))
	)
	query.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(query)

	_expect("collision: ray hits a chunk body", not hit.is_empty(), "")

	var collider: Object = hit.get("collider")
	_expect(
		"collision: body belongs to the grid",
		collider is Node and (collider as Node).has_meta("nav_grid"),
		""
	)

	grid.free()


func _test_memory() -> void:
	var grid: NavGridMap = _make_grid()
	var cells: Array[Vector3i] = []

	for x in 16:
		for z in 16:
			cells.append(Vector3i(x, 0, z))

	grid.place_blocks(cells, 1)

	var byte_count: int = grid.get_section_index_memory_bytes()
	var per_cell: float = float(byte_count) / float(cells.size())

	_expect("memory: floor cell count", grid.get_chunk_cell_count(Vector2i(0, 0)) == 256, "")
	_expect(
		"memory: floor index under 6 bytes/cell (got %.2f)" % per_cell,
		per_cell < 6.0,
		str(byte_count)
	)

	grid.free()


func _test_step_slabs_retrofit() -> void:
	var grid: NavGridMap = _make_grid()
	grid.place_block(Vector3i(0, 0, 0), 0, 0)
	grid.place_block(Vector3i(1, 0, 0), 0, 0)
	grid.place_block(Vector3i(1, 1, 0), 0, 0)

	var placed: int = grid.add_step_slabs(2)
	_expect("slabs: retrofit adds one", placed == 1, str(placed))
	_expect(
		"slabs: retrofit lands at low side top + 1",
		grid.get_block_item(Vector3i(0, 1, 0)) == 2,
		str(grid.get_block_item(Vector3i(0, 1, 0)))
	)
	_expect(
		"slabs: retrofit leaves the high side untouched",
		grid.get_block_item(Vector3i(1, 2, 0)) == GridMap.INVALID_CELL_ITEM,
		str(grid.get_block_item(Vector3i(1, 2, 0)))
	)

	var again: int = grid.add_step_slabs(2)
	_expect("slabs: retrofit is idempotent", again == 0, str(again))
	grid.free()


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

func _make_grid(with_mesher: bool = false) -> NavGridMap:
	var grid := NavGridMap.new()
	grid.name = "ChunkStoreTestGrid"
	grid.mesh_library = _make_library()
	grid.cell_size = Vector3.ONE
	grid.enable_greedy_meshing = with_mesher
	grid.enable_flow_fields = false
	grid.auto_generate_stairs = false
	grid.wall_force_enabled = false
	root.add_child(grid)
	return grid


func _make_library() -> MeshLibrary:
	var library := MeshLibrary.new()
	var box := BoxMesh.new()
	var shape := BoxShape3D.new()
	box.size = Vector3.ONE
	shape.size = Vector3.ONE

	for item in 4:
		library.create_item(item)
		library.set_item_name(item, "TestCube%d" % item)
		library.set_item_mesh(item, box)
		library.set_item_shapes(item, [shape, Transform3D.IDENTITY])

	return library


func _place(
	grid: NavGridMap,
	cell: Vector3i,
	item: int,
	orientation: int,
	expected: Dictionary
) -> void:
	grid.place_block(cell, item, orientation)
	expected[cell] = Vector2i(item, orientation)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + label)
		return

	_failures += 1
	print("  FAIL  " + label + ("" if detail.is_empty() else "  [" + detail + "]"))
