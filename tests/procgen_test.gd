extends SceneTree

## P0 + P0b foundation tests: packed 3D section storage, deterministic
## serialization, the generator interface and the flat generator.
##
##   godot --headless --path . --script res://tests/procgen_test.gd
##
## These are pure data tests: no scene, no autoloads, no Node.

const SectionStore = preload("res://scripts/world/VoxelSectionStore.gd")
const FlatGen = preload("res://scripts/world/FlatGenerator.gd")
const Recipe = preload("res://scripts/world/WorldRecipe.gd")

const CHUNK_FORMAT_VERSION := 2

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	print("=== procgen foundation ===")

	_test_section_round_trip()
	_test_palette_growth_and_dense()
	_test_dense_to_sparse()
	_test_negative_coordinates()
	_test_column_min_max()
	_test_serialization_round_trip()
	_test_determinism()
	_test_memory_floor()
	_test_memory_mixed()
	_test_flat_generator()
	_test_world_recipe()

	print("checks=%d failures=%d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, label: String) -> void:
	_checks += 1

	if condition:
		return

	_failures += 1
	push_error("FAIL: " + label)


func _test_section_round_trip() -> void:
	var store = SectionStore.new()
	var cell := Vector3i(3, 5, 7)

	store.set_cell(cell, 44, 2)
	_check(store.get_cell_item(cell) == 44, "item round-trip")
	_check(store.get_cell_orientation(cell) == 2, "orientation round-trip")
	_check(store.has_cell(cell), "has_cell")
	_check(store.cell_count() == 1, "cell_count is 1")
	_check(store.section_count() == 1, "section_count is 1")

	store.remove_cell(cell)
	_check(not store.has_cell(cell), "remove_cell clears the cell")
	_check(store.get_column_chunks().is_empty(), "empty column is dropped")
	_check(store.section_count() == 0, "empty section is dropped")

	# Overwriting an existing cell must not inflate the count.
	store.set_cell(cell, 1, 0)
	store.set_cell(cell, 2, 3)
	_check(store.cell_count() == 1, "overwrite keeps one cell")
	_check(store.get_cell_item(cell) == 2, "overwrite replaces the item")
	_check(store.get_cell_orientation(cell) == 3, "overwrite replaces orientation")


func _test_palette_growth_and_dense() -> void:
	var store = SectionStore.new()
	var base := Vector3i(0, 0, 0)
	var expected: Dictionary = {}

	# Sparse starts at 8 bytes/cell. Crossing 96 converts to dense and grows the
	# palette through 1 -> 2 -> 4 bits.
	for i in 200:
		var cell := Vector3i(i % 16, i / 16, 0)
		var item: int = 10 + (i % 5)
		var orientation: int = i % 3
		store.set_cell(cell, item, orientation)
		expected[cell] = Vector2i(item, orientation)

	var mismatches: int = 0

	for cell: Vector3i in expected:
		var want: Vector2i = expected[cell]

		if (
			store.get_cell_item(cell) != want.x
			or store.get_cell_orientation(cell) != want.y
		):
			mismatches += 1

	_check(mismatches == 0, "dense palette preserves every value")
	_check(store.cell_count() == 200, "dense palette count")

	# A full 16x16x16 block with a tiny palette should stay dense and compact.
	var solid = SectionStore.new()

	for x in 16:
		for y in 16:
			for z in 16:
				solid.set_cell(Vector3i(x, y, z), 1 + ((x + z) % 2), 0)

	_check(solid.cell_count() == 4096, "full section count")
	_check(
		solid.memory_bytes() < 4096 * 4,
		"full section stays under 4 bytes/cell"
	)

	# Palette overflow: more than 256 distinct (item, orientation) pairs in one
	# section must fall back to sparse instead of corrupting.
	var wide = SectionStore.new()
	var wide_ok: bool = true

	for i in 300:
		var cell := Vector3i(i % 16, i / 256, (i / 16) % 16)
		wide.set_cell(cell, 1000 + i, i % 24)

	for i in 300:
		var cell := Vector3i(i % 16, i / 256, (i / 16) % 16)

		if (
			wide.get_cell_item(cell) != 1000 + i
			or wide.get_cell_orientation(cell) != i % 24
		):
			wide_ok = false
			break

	_check(wide_ok, "palette overflow falls back without data loss")


func _test_dense_to_sparse() -> void:
	var store = SectionStore.new()

	for i in 120:
		store.set_cell(Vector3i(i % 16, i / 16, 0), 5, 1)

	for i in 110:
		store.remove_cell(Vector3i(i % 16, i / 16, 0))

	var remaining: int = 0
	var correct: bool = true

	for i in 110:
		if store.has_cell(Vector3i(i % 16, i / 16, 0)):
			remaining += 1

	for i in range(110, 120):
		var cell := Vector3i(i % 16, i / 16, 0)

		if store.get_cell_item(cell) != 5 or store.get_cell_orientation(cell) != 1:
			correct = false

	_check(remaining == 0, "removed cells are gone")
	_check(correct, "remaining cells survive dense -> sparse")
	_check(store.cell_count() == 10, "dense -> sparse count")


func _test_negative_coordinates() -> void:
	var store = SectionStore.new()
	var cells: Array[Vector3i] = [
		Vector3i(-1, -1, -17),
		Vector3i(-16, -16, -32),
		Vector3i(-17, 0, -1),
		Vector3i(0, 255, 0),
		Vector3i(15, -256, 15),
	]
	var correct: bool = true

	for i in cells.size():
		store.set_cell(cells[i], 100 + i, i)

	for i in cells.size():
		if (
			store.get_cell_item(cells[i]) != 100 + i
			or store.get_cell_orientation(cells[i]) != i
		):
			correct = false

	_check(correct, "negative and extreme Y coordinates")
	_check(store.cell_count() == cells.size(), "negative coordinate count")


func _test_column_min_max() -> void:
	var store = SectionStore.new()
	var column := Vector2i(2, -3)

	store.set_cell(Vector3i(35, 7, -41), 1, 0)
	store.set_cell(Vector3i(32, -9, -48), 1, 0)
	store.set_cell(Vector3i(47, 31, -33), 1, 0)

	_check(store.get_column_min_y(column) == -9, "column min Y")
	_check(store.get_column_max_y(column) == 31, "column max Y")
	_check(store.get_column_cell_count(column) == 3, "column cell count")

	var list: Array[Vector3i] = store.get_column_cell_list(column)
	_check(list.size() == 3, "column cell list size")


func _test_serialization_round_trip() -> void:
	var store = SectionStore.new()
	var column := Vector2i(4, -2)
	var origin := column * SectionStore.SIZE
	var expected: Dictionary = {}

	# Three vertical sections plus a negative-Y section.
	for y in [-5, 0, 3, 16, 19, 40]:
		for x in 4:
			for z in 4:
				var cell := Vector3i(origin.x + x, y, origin.y + z)
				store.set_cell(cell, 20 + (y & 7), (x + z) % 24)
				expected[cell] = Vector2i(20 + (y & 7), (x + z) % 24)

	var blob: PackedByteArray = store.serialize_column(column)
	var compressed: PackedByteArray = store.serialize_column_compressed(column)

	_check(not blob.is_empty(), "column blob is non-empty")
	_check(not compressed.is_empty(), "compressed blob is non-empty")

	var decoded: Array[Dictionary] = SectionStore.decode_column_compressed(
		column,
		compressed
	)
	var round_trip: Dictionary = {}

	for entry: Dictionary in decoded:
		round_trip[entry["position"]] = Vector2i(
			int(entry["item"]),
			int(entry["orientation"])
		)

	_check(decoded.size() == expected.size(), "decoded cell count")
	_check(round_trip == expected, "decoded values match")

	# A second decode is idempotent (no shared decoder state).
	var decoded_again: Array[Dictionary] = SectionStore.decode_column_compressed(
		column,
		compressed
	)
	_check(decoded_again.size() == decoded.size(), "decode is repeatable")

	# Empty column round-trips to zero entries.
	var empty_blob: PackedByteArray = store.serialize_column_compressed(
		Vector2i(99, 99)
	)
	_check(
		SectionStore.decode_column_compressed(Vector2i(99, 99), empty_blob).is_empty(),
		"empty column decodes to nothing"
	)

	# Garbage must not crash the decoder.
	_check(
		SectionStore.decode_column_compressed(
			column,
			PackedByteArray([1, 2, 3])
		).is_empty(),
		"malformed blob is rejected"
	)


func _test_determinism() -> void:
	var column := Vector2i(1, 1)
	var first = SectionStore.new()
	var second = SectionStore.new()
	var reverse = SectionStore.new()
	var cells: Array[Vector3i] = []

	for i in 300:
		cells.append(Vector3i(16 + (i % 16), i / 16, 16 + ((i * 7) % 16)))

	for cell in cells:
		first.set_cell(cell, 30 + (cell.x % 4), cell.z % 6)
		second.set_cell(cell, 30 + (cell.x % 4), cell.z % 6)

	var reversed: Array[Vector3i] = cells.duplicate()
	reversed.reverse()

	for cell in reversed:
		reverse.set_cell(cell, 30 + (cell.x % 4), cell.z % 6)

	var a: PackedByteArray = first.serialize_column(column)
	var b: PackedByteArray = second.serialize_column(column)
	var c: PackedByteArray = reverse.serialize_column(column)

	_check(a == b, "same edit sequence produces identical bytes")

	var first_map: Dictionary = _entry_map(
		SectionStore.decode_column(column, a)
	)
	var reverse_map: Dictionary = _entry_map(
		SectionStore.decode_column(column, c)
	)

	_check(first_map == reverse_map, "edit order does not change content")


func _test_memory_floor() -> void:
	var store = SectionStore.new()
	var column := Vector2i(0, 0)

	# 16 stacked 16x16 floors = 4096 cells. Dense one-bit should be ~2 B/cell.
	for section_index in 16:
		var y: int = section_index * SectionStore.SIZE

		for x in 16:
			for z in 16:
				store.set_cell(Vector3i(x, y, z), 44, 0)

	var cells: int = store.cell_count()
	var bytes: int = store.memory_bytes()
	var per_cell: float = float(bytes) / float(maxi(cells, 1))

	_check(cells == 4096, "floor cell count")
	_check(per_cell < 4.0, "floor memory under 4 bytes/cell (got %.2f)" % per_cell)
	_check(
		bytes < 4096 * 20,
		"floor memory under 20 bytes/cell including overhead"
	)


func _test_memory_mixed() -> void:
	var store = SectionStore.new()
	var column := Vector2i(0, 0)
	var cells: int = 0

	# 32 sparse sections with 20 cells each (wall segments, props).
	for section_index in 32:
		var y: int = section_index * SectionStore.SIZE

		for i in 20:
			store.set_cell(
				Vector3i(i % 16, y, i / 16),
				10 + (i % 3),
				0
			)
			cells += 1

	var per_cell: float = float(store.memory_bytes()) / float(maxi(cells, 1))

	_check(cells == 640, "mixed cell count")
	_check(
		per_cell < 24.0,
		"sparse section memory under 24 bytes/cell (got %.2f)" % per_cell
	)


func _test_flat_generator() -> void:
	var generator = FlatGen.new()
	var chunks: Array[Vector2i] = [
		Vector2i(-1, -1),
		Vector2i(-1, 0),
		Vector2i(0, -1),
		Vector2i(0, 0),
	]
	var cells: Dictionary = {}

	for chunk in chunks:
		for entry: Dictionary in generator.generate_column(chunk, {}):
			var cell: Vector3i = entry["position"]
			cells[cell] = int(entry["item"])

	_check(cells.size() == 80, "flat generator produces 80 cells")
	_check(
		generator.generate_column(Vector2i(5, 5), {}).is_empty(),
		"flat generator is bounded"
	)

	var valid: bool = true

	for cell: Vector3i in cells:
		if (
			cell.y != 0
			or cell.x < -5
			or cell.x > 4
			or cell.z < -3
			or cell.z > 4
			or cells[cell] != 44
		):
			valid = false
			break

	_check(valid, "flat generator matches the shipped 10 x 8 platform")
	_check(generator.get_id() == "flat_v1", "flat generator identity")


func _test_world_recipe() -> void:
	var recipe = Recipe.new()
	recipe.generator = FlatGen.new()

	var data: Dictionary = recipe.generate_chunk_data(Vector2i(0, 0))

	_check(int(data.get("version", 0)) == CHUNK_FORMAT_VERSION, "recipe emits v2")
	_check(data.has("sections"), "recipe emits a section blob")

	var decoded: Array[Dictionary] = SectionStore.decode_column_compressed(
		Vector2i(0, 0),
		data["sections"]
	)
	_check(decoded.size() == 25, "recipe chunk cell count")

	var again: Dictionary = recipe.generate_chunk_data(Vector2i(0, 0))
	_check(
		data["sections"] == again["sections"],
		"recipe output is deterministic"
	)

	var manifest: Dictionary = recipe.get_manifest()
	_check(manifest.get("recipe_id", "") == "flat_v1", "manifest recipe id")
	_check((manifest.get("stages", []) as Array).size() == 1, "manifest stages")

	# An empty region produces no data instead of an empty blob.
	var outside: Dictionary = recipe.generate_chunk_data(Vector2i(9, 9))
	_check(outside.is_empty(), "recipe returns empty outside its footprint")


func _entry_map(entries: Array) -> Dictionary:
	var result: Dictionary = {}

	for entry: Dictionary in entries:
		result[entry["position"]] = Vector2i(
			int(entry["item"]),
			int(entry["orientation"])
		)

	return result
