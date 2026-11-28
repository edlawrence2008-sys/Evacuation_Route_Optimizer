class_name AshSettler
extends RefCounted

## Ash-only settling. Thin ash residues (panels and slabs) compact downward and
## merge in vertical pairs into a normal ash block. This keeps burned-out
## structures from leaving a ladder of floating 3/16 m panels. No other material
## is touched.

const BLOCK_MATERIALS = preload("res://scripts/block_materials.gd")
const NORMAL_ASH_NAME: String = "Auto_ash"
const MAX_COLUMN_HEIGHT: int = 32


static func is_ash_name(item_name: String) -> bool:
	if item_name == NORMAL_ASH_NAME:
		return true
	return BLOCK_MATERIALS.material_id(item_name) == "ash"


static func is_thin_ash_name(item_name: String) -> bool:
	if not is_ash_name(item_name):
		return false
	var lower := item_name.to_lower()
	return (
		lower.contains("panel_")
		or lower.contains("slab_")
	)


static func normal_ash_item(library: MeshLibrary) -> int:
	if library == null:
		return -1
	for id: int in library.get_item_list():
		if String(library.get_item_name(id)) == NORMAL_ASH_NAME:
			return id
	return -1


## Settles an ash cell that was just placed manually: finds the lowest empty
## cell above a solid surface in its column, then compacts/merges there.
static func settle_world_cell(grid: NavGridMap, cell: Vector3i) -> void:
	if grid == null or grid.mesh_library == null:
		return
	var cell_item: int = grid.get_block_item(cell)
	if cell_item < 0:
		return
	if not is_ash_name(String(grid.mesh_library.get_item_name(cell_item))):
		return

	var probe := cell
	for _index in MAX_COLUMN_HEIGHT:
		var below := probe + Vector3i.DOWN
		if not grid.has_block(below):
			probe = below
			continue
		var below_item: int = grid.get_block_item(below)
		if is_ash_name(String(grid.mesh_library.get_item_name(below_item))):
			# Include the existing ash stack so thin pairs can merge.
			probe = below
			continue
		break
	compact_world_column(grid, probe)


## Compacts one world column starting at `bottom` (an empty cell above a solid
## surface). Existing ash is gathered, thin pairs are merged into normal ash,
## and the result is rewritten bottom-up.
static func compact_world_column(grid: NavGridMap, bottom: Vector3i) -> void:
	if grid == null or grid.mesh_library == null:
		return
	if grid.has_block(bottom):
		var bottom_name := String(
			grid.mesh_library.get_item_name(grid.get_block_item(bottom))
		)
		if not is_ash_name(bottom_name):
			return

	var library := grid.mesh_library
	var items: Array[int] = []
	var orientations: Array[int] = []
	var ash_cells: Array[Vector3i] = []

	for step in MAX_COLUMN_HEIGHT:
		var cell := Vector3i(bottom.x, bottom.y + step, bottom.z)
		var item: int = grid.get_block_item(cell)
		if item < 0:
			continue
		var item_name := String(library.get_item_name(item))
		if not is_ash_name(item_name):
			break
		items.append(item)
		orientations.append(grid.get_block_orientation(cell))
		ash_cells.append(cell)

	if items.is_empty():
		return

	var normal := normal_ash_item(library)
	if normal < 0:
		return

	grid.remove_blocks(ash_cells)

	var output_items: Array[int] = []
	var output_orientations: Array[int] = []
	var index := 0
	while index < items.size():
		if (
			index + 1 < items.size()
			and is_thin_ash_name(String(library.get_item_name(items[index])))
			and is_thin_ash_name(
				String(library.get_item_name(items[index + 1]))
			)
		):
			output_items.append(normal)
			output_orientations.append(0)
			index += 2
		else:
			output_items.append(items[index])
			output_orientations.append(orientations[index])
			index += 1

	for offset in output_items.size():
		var cell := Vector3i(bottom.x, bottom.y + offset, bottom.z)
		if grid.has_block(cell):
			break
		grid.place_block(cell, output_items[offset], output_orientations[offset])


## Settles all thin ash in a sub-level dictionary after a manual edit.
static func settle_cells_columns(cells: Dictionary, library: MeshLibrary) -> void:
	if library == null or cells.is_empty():
		return

	var min_y: int = 2147483647
	for cell: Vector3i in cells:
		min_y = mini(min_y, cell.y)

	var columns: Dictionary = {}
	for cell: Vector3i in cells:
		var entry: Dictionary = cells[cell]
		var item: int = int(entry.get("item", -1))
		if item < 0:
			continue
		if not is_thin_ash_name(String(library.get_item_name(item))):
			continue

		var column := Vector2i(cell.x, cell.z)
		var bottom := cell
		for _index in MAX_COLUMN_HEIGHT:
			var below := bottom + Vector3i.DOWN
			if cells.has(below):
				var below_entry: Dictionary = cells[below]
				var below_item: int = int(below_entry.get("item", -1))
				if (
					below_item >= 0
					and is_ash_name(String(library.get_item_name(below_item)))
				):
					bottom = below
					continue
				break
			if bottom.y <= min_y:
				break
			bottom = below
		if columns.has(column):
			var existing: Vector3i = columns[column]
			if bottom.y < existing.y:
				columns[column] = bottom
		else:
			columns[column] = bottom

	for key: Variant in columns:
		var bottom: Vector3i = columns[key]
		compact_cells_column(cells, library, bottom)


## Sub-level variant: operates directly on the local cell dictionary.
static func compact_cells_column(
	cells: Dictionary,
	library: MeshLibrary,
	bottom: Vector3i
) -> void:
	if library == null:
		return
	if cells.has(bottom):
		var bottom_entry: Dictionary = cells[bottom]
		var bottom_item: int = int(bottom_entry.get("item", -1))
		var bottom_name := String(library.get_item_name(bottom_item))
		if not is_ash_name(bottom_name):
			return

	var items: Array[int] = []
	var orientations: Array[int] = []
	var ash_cells: Array[Vector3i] = []

	for step in MAX_COLUMN_HEIGHT:
		var cell := Vector3i(bottom.x, bottom.y + step, bottom.z)
		var entry_value: Variant = cells.get(cell, null)
		if entry_value == null:
			continue
		var entry: Dictionary = entry_value
		var item: int = int(entry.get("item", -1))
		if item < 0:
			continue
		var item_name := String(library.get_item_name(item))
		if not is_ash_name(item_name):
			break
		items.append(item)
		orientations.append(int(entry.get("orientation", 0)))
		ash_cells.append(cell)

	if items.is_empty():
		return

	var normal := normal_ash_item(library)
	if normal < 0:
		return

	for cell: Vector3i in ash_cells:
		cells.erase(cell)

	var output_items: Array[int] = []
	var output_orientations: Array[int] = []
	var index := 0
	while index < items.size():
		if (
			index + 1 < items.size()
			and is_thin_ash_name(String(library.get_item_name(items[index])))
			and is_thin_ash_name(
				String(library.get_item_name(items[index + 1]))
			)
		):
			output_items.append(normal)
			output_orientations.append(0)
			index += 2
		else:
			output_items.append(items[index])
			output_orientations.append(orientations[index])
			index += 1

	for offset in output_items.size():
		var cell := Vector3i(bottom.x, bottom.y + offset, bottom.z)
		if cells.has(cell):
			break
		cells[cell] = {
			"item": output_items[offset],
			"orientation": output_orientations[offset],
		}
