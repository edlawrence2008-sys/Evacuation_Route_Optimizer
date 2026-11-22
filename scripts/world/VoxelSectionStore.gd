class_name VoxelSectionStore
extends RefCounted

## Sparse 3D section storage for the voxel world.
##
## A chunk column (one `Vector2i` key) owns a sparse map of 16x16x16 vertical
## sections keyed by their section-Y. A one-storey floor costs one section per
## column; a ten-storey building costs ten; empty sections cost nothing. That is
## the whole point: cost follows content volume, not the height of the build
## range.
##
## Each section picks one of two encodings automatically:
##
##   SPARSE - sorted parallel arrays, 8 bytes per solid cell. Best below ~64 cells.
##   DENSE  - palette + bit-packed indices (1/2/4/8 bits). A full 16x16 layer at
##            one bit is 512 bytes, so floors and walls stay around 2 bytes/cell.
##
## This is the runtime cell index and the on-disk format. It is deliberately
## independent of Godot's GridMap: GridMap can keep acting as the physics mirror
## today and be dropped later without changing the file format.
##
## Determinism: sections are encoded in first-seen palette order and sections are
## written sorted by section-Y, so the same edit sequence always produces the same
## bytes. Decoding does not depend on palette order.

const SIZE: int = 16
const VOLUME: int = 4096
const MAGIC: int = 0x56584C31  # "VXL1"
const FORMAT_VERSION: int = 1
const INVALID: int = -1
const NO_HEIGHT: int = 2147483647


## One 16x16x16 cuboid. Modes are private to the store; use the store API.
class Section:
	const MODE_EMPTY: int = 0
	const MODE_SPARSE: int = 1
	const MODE_DENSE: int = 2

	# Sparse -> dense at 96 cells, dense -> sparse at 32. The gap is hysteresis:
	# an edit that crosses one boundary does not immediately cross back.
	const SPARSE_TO_DENSE: int = 96
	const DENSE_TO_SPARSE: int = 32

	var mode: int = MODE_EMPTY
	var count: int = 0
	var bits: int = 1
	# Set when the section has more distinct values than 8 bits can index.
	# Sparse stays authoritative from then on; prevents convert-loop recursion.
	var dense_disabled: bool = false

	# Dense: palette[0] is the air sentinel.
	var palette: PackedInt32Array = PackedInt32Array()
	var palette_lookup: Dictionary = {}
	var indices: PackedByteArray = PackedByteArray()

	# Sparse: parallel sorted arrays. Values are (item << 8) | orientation.
	var sparse_indices: PackedInt32Array = PackedInt32Array()
	var sparse_values: PackedInt32Array = PackedInt32Array()

	func is_empty() -> bool:
		return mode == MODE_EMPTY or count == 0

	func get_value(local: int) -> int:
		match mode:
			MODE_SPARSE:
				var at: int = _sparse_find(local)
				if at >= 0:
					return sparse_values[at]
				return -1
			MODE_DENSE:
				var palette_index: int = _read_index(local)
				if palette_index == 0:
					return -1
				return palette[palette_index]
			_:
				return -1

	func set_value(local: int, value: int) -> void:
		if value < 0:
			remove_value(local)
			return

		match mode:
			MODE_EMPTY:
				_begin_sparse()
				_sparse_set(local, value)
			MODE_SPARSE:
				_sparse_set(local, value)
			MODE_DENSE:
				_dense_set(local, value)

	func remove_value(local: int) -> void:
		match mode:
			MODE_SPARSE:
				var at: int = _sparse_find(local)
				if at < 0:
					return
				sparse_indices.remove_at(at)
				sparse_values.remove_at(at)
				count -= 1
				if count == 0:
					_reset()
			MODE_DENSE:
				if _read_index(local) == 0:
					return
				_write_index(local, 0)
				count -= 1
				if count == 0:
					_reset()
				elif count < DENSE_TO_SPARSE:
					_to_sparse()

	func append_cells(out: Array, base_x: int, base_y: int, base_z: int) -> void:
		if mode == MODE_SPARSE:
			for i in sparse_indices.size():
				var local: int = sparse_indices[i]
				out.append(Vector3i(
					base_x + (local & 15),
					base_y + (local >> 8),
					base_z + ((local >> 4) & 15)
				))
		elif mode == MODE_DENSE:
			for local in VOLUME:
				if _read_index(local) != 0:
					out.append(Vector3i(
						base_x + (local & 15),
						base_y + (local >> 8),
						base_z + ((local >> 4) & 15)
					))

	func append_entries(out: Array, base_x: int, base_y: int, base_z: int) -> void:
		if mode == MODE_SPARSE:
			for i in sparse_indices.size():
				var local: int = sparse_indices[i]
				var value: int = sparse_values[i]
				out.append({
					"position": Vector3i(
						base_x + (local & 15),
						base_y + (local >> 8),
						base_z + ((local >> 4) & 15)
					),
					"item": value >> 8,
					"orientation": value & 0xFF,
				})
		elif mode == MODE_DENSE:
			for local in VOLUME:
				var palette_index: int = _read_index(local)
				if palette_index == 0:
					continue
				var value: int = palette[palette_index]
				out.append({
					"position": Vector3i(
						base_x + (local & 15),
						base_y + (local >> 8),
						base_z + ((local >> 4) & 15)
					),
					"item": value >> 8,
					"orientation": value & 0xFF,
				})

	## Appends cells and their item ids in one pass, avoiding a second
	## `get_cell_item()` lookup per cell. Used by the chunk mesher snapshot.
	func append_cells_and_items(
		out_cells: Array,
		out_items: Array,
		base_x: int,
		base_y: int,
		base_z: int
	) -> void:
		if mode == MODE_SPARSE:
			for i in sparse_indices.size():
				var local: int = sparse_indices[i]
				out_cells.append(Vector3i(
					base_x + (local & 15),
					base_y + (local >> 8),
					base_z + ((local >> 4) & 15)
				))
				out_items.append(sparse_values[i] >> 8)
		elif mode == MODE_DENSE:
			for local in VOLUME:
				var palette_index: int = _read_index(local)
				if palette_index == 0:
					continue
				out_cells.append(Vector3i(
					base_x + (local & 15),
					base_y + (local >> 8),
					base_z + ((local >> 4) & 15)
				))
				out_items.append(palette[palette_index] >> 8)

	func get_min_local_y() -> int:
		var lowest: int = 16
		if mode == MODE_SPARSE:
			for local in sparse_indices:
				lowest = mini(lowest, local >> 8)
		elif mode == MODE_DENSE:
			for local in VOLUME:
				if _read_index(local) != 0:
					lowest = mini(lowest, local >> 8)
		return lowest

	func get_max_local_y() -> int:
		var highest: int = -1
		if mode == MODE_SPARSE:
			for local in sparse_indices:
				highest = maxi(highest, local >> 8)
		elif mode == MODE_DENSE:
			for local in VOLUME:
				if _read_index(local) != 0:
					highest = maxi(highest, local >> 8)
		return highest

	func memory_bytes() -> int:
		var total: int = 64  # object + dictionary entry estimate
		total += palette.size() * 4
		total += indices.size()
		total += sparse_indices.size() * 4
		total += sparse_values.size() * 4
		return total

	# ------------------------------------------------------------------
	# Sparse encoding
	# ------------------------------------------------------------------

	func _begin_sparse() -> void:
		mode = MODE_SPARSE
		count = 0
		dense_disabled = false
		sparse_indices = PackedInt32Array()
		sparse_values = PackedInt32Array()

	func _reset() -> void:
		mode = MODE_EMPTY
		count = 0
		dense_disabled = false
		palette = PackedInt32Array()
		palette_lookup.clear()
		indices = PackedByteArray()
		sparse_indices = PackedInt32Array()
		sparse_values = PackedInt32Array()

	# Returns the index of `local`, or -(insertion_point + 1).
	func _sparse_find(local: int) -> int:
		var low: int = 0
		var high: int = sparse_indices.size() - 1

		while low <= high:
			var mid: int = (low + high) >> 1
			var value: int = sparse_indices[mid]

			if value == local:
				return mid
			if value < local:
				low = mid + 1
			else:
				high = mid - 1

		return -(low + 1)

	func _sparse_set(local: int, value: int) -> void:
		var at: int = _sparse_find(local)

		if at >= 0:
			sparse_values[at] = value
			return

		var insert_at: int = -(at + 1)
		sparse_indices.insert(insert_at, local)
		sparse_values.insert(insert_at, value)
		count += 1

		if count > SPARSE_TO_DENSE and not dense_disabled:
			_to_dense()

	# ------------------------------------------------------------------
	# Dense palette encoding
	# ------------------------------------------------------------------

	func _to_dense() -> void:
		if mode == MODE_DENSE:
			return

		# 8 bits index at most 256 palette entries. A section above that must
		# stay sparse forever, or the two encodings bounce off each other.
		var distinct: Dictionary = {}

		for value in sparse_values:
			distinct[value] = true

			if distinct.size() > 256:
				dense_disabled = true
				return

		dense_disabled = false
		palette = PackedInt32Array([-1])
		palette_lookup = {-1: 0}
		bits = 1
		indices = PackedByteArray()
		indices.resize(VOLUME >> 3)
		indices.fill(0)

		var old_indices: PackedInt32Array = sparse_indices
		var old_values: PackedInt32Array = sparse_values

		mode = MODE_DENSE
		count = 0

		for i in old_indices.size():
			_dense_set(old_indices[i], old_values[i])

		sparse_indices = PackedInt32Array()
		sparse_values = PackedInt32Array()

	func _to_sparse() -> void:
		if mode == MODE_SPARSE:
			return

		var new_indices: PackedInt32Array = PackedInt32Array()
		var new_values: PackedInt32Array = PackedInt32Array()

		for local in VOLUME:
			var palette_index: int = _read_index(local)
			if palette_index == 0:
				continue
			new_indices.append(local)
			new_values.append(palette[palette_index])

		sparse_indices = new_indices
		sparse_values = new_values
		count = new_indices.size()
		mode = MODE_SPARSE
		palette = PackedInt32Array()
		palette_lookup.clear()
		indices = PackedByteArray()

	func _read_index(local: int) -> int:
		match bits:
			1:
				return (indices[local >> 3] >> (local & 7)) & 0x1
			2:
				return (indices[local >> 2] >> ((local & 3) << 1)) & 0x3
			4:
				return (indices[local >> 1] >> ((local & 1) << 2)) & 0xF
			8:
				return indices[local]
			_:
				return 0

	func _write_index(local: int, value: int) -> void:
		match bits:
			1:
				var byte_index: int = local >> 3
				var shift: int = local & 7
				indices[byte_index] = (
					(indices[byte_index] & ~(1 << shift)) | ((value & 0x1) << shift)
				)
			2:
				var byte_index: int = local >> 2
				var shift: int = (local & 3) << 1
				indices[byte_index] = (
					(indices[byte_index] & ~(0x3 << shift)) | ((value & 0x3) << shift)
				)
			4:
				var byte_index: int = local >> 1
				var shift: int = (local & 1) << 2
				indices[byte_index] = (
					(indices[byte_index] & ~(0xF << shift)) | ((value & 0xF) << shift)
				)
			8:
				indices[local] = value & 0xFF

	func _find_or_add(value: int) -> int:
		if palette_lookup.has(value):
			return int(palette_lookup[value])

		var index: int = palette.size()
		palette.append(value)
		palette_lookup[value] = index
		return index

	# Grows the bit width, or converts to sparse when the palette is too large.
	# Returns false when the section became sparse, in which case the caller
	# writes through the sparse path instead.
	func _ensure_capacity(needed: int) -> bool:
		var required: int = bits

		while required < 8 and (1 << required) < needed:
			required <<= 1

		if (1 << required) < needed:
			dense_disabled = true
			_to_sparse()
			return false

		if required > bits:
			_reencode(required)

		return true

	func _reencode(new_bits: int) -> void:
		var old_indices: PackedByteArray = indices
		var old_bits: int = bits

		bits = new_bits
		indices = PackedByteArray()
		indices.resize((VOLUME * new_bits) >> 3)
		indices.fill(0)

		for local in VOLUME:
			var value: int
			match old_bits:
				1:
					value = (old_indices[local >> 3] >> (local & 7)) & 0x1
				2:
					value = (old_indices[local >> 2] >> ((local & 3) << 1)) & 0x3
				4:
					value = (old_indices[local >> 1] >> ((local & 1) << 2)) & 0xF
				8:
					value = old_indices[local]
				_:
					value = 0
			if value != 0:
				_write_index(local, value)

	func _dense_set(local: int, value: int) -> void:
		var was_air: bool = _read_index(local) == 0
		var palette_index: int = _find_or_add(value)

		if palette_index >= (1 << bits):
			if not _ensure_capacity(palette_index + 1):
				_sparse_set(local, value)
				return

		_write_index(local, palette_index)

		if was_air:
			count += 1


## Column key from a world cell.
static func column_of(cell: Vector3i) -> Vector2i:
	return Vector2i(
		floori(float(cell.x) / float(SIZE)),
		floori(float(cell.z) / float(SIZE))
	)


## Section-Y from a world Y.
static func section_y(y: int) -> int:
	return floori(float(y) / float(SIZE))


## Local index inside a section: x + z * 16 + y * 256.
static func local_index(cell: Vector3i, column: Vector2i, sy: int) -> int:
	var local_x: int = cell.x - column.x * SIZE
	var local_z: int = cell.z - column.y * SIZE
	var local_y: int = cell.y - sy * SIZE
	return local_x + local_z * SIZE + local_y * SIZE * SIZE


var _columns: Dictionary = {}  # Vector2i -> {int section_y: Section}

# Last column/section touched by `set_cell`. Generated terrain writes several
# consecutive cells in the same column, so this avoids repeating the column
# dictionary lookup for every cell.
var _cache_valid: bool = false
var _cached_column: Vector2i = Vector2i.ZERO
var _cached_sy: int = 0
var _cached_sections: Dictionary = {}
var _cached_section: Section = null


func clear() -> void:
	_columns.clear()
	_cache_valid = false
	_cached_sections = {}
	_cached_section = null


func set_cell(cell: Vector3i, item: int, orientation: int = 0) -> void:
	if item < 0:
		remove_cell(cell)
		return

	var column: Vector2i = column_of(cell)
	var sy: int = section_y(cell.y)

	if not _cache_valid or column != _cached_column:
		_cached_sections = _columns.get(column, {})
		_cached_column = column
		_cached_sy = -2147483648
		_cached_section = null
		_cache_valid = true

	if sy != _cached_sy:
		_cached_section = _cached_sections.get(sy)

		if _cached_section == null:
			_cached_section = Section.new()
			_cached_sections[sy] = _cached_section
			_columns[column] = _cached_sections

		_cached_sy = sy

	_cached_section.set_value(
		local_index(cell, column, sy),
		(item << 8) | (orientation & 0xFF)
	)


func remove_cell(cell: Vector3i) -> void:
	_cache_valid = false
	var column: Vector2i = column_of(cell)
	var sections: Dictionary = _columns.get(column, {})
	var sy: int = section_y(cell.y)
	var section: Section = sections.get(sy)

	if section == null:
		return

	section.remove_value(local_index(cell, column, sy))

	if section.is_empty():
		sections.erase(sy)
		if sections.is_empty():
			_columns.erase(column)


func get_value(cell: Vector3i) -> int:
	var column: Vector2i = column_of(cell)
	var sections: Dictionary = _columns.get(column, {})
	var sy: int = section_y(cell.y)
	var section: Section = sections.get(sy)

	if section == null:
		return -1

	return section.get_value(local_index(cell, column, sy))


func get_cell_item(cell: Vector3i) -> int:
	var value: int = get_value(cell)
	return INVALID if value < 0 else (value >> 8)


func get_cell_orientation(cell: Vector3i) -> int:
	var value: int = get_value(cell)
	return 0 if value < 0 else (value & 0xFF)


func has_cell(cell: Vector3i) -> bool:
	return get_value(cell) >= 0


func has_column(column: Vector2i) -> bool:
	return _columns.has(column)


func get_column_chunks() -> Array[Vector2i]:
	var result: Array[Vector2i] = []

	for column: Vector2i in _columns:
		result.append(column)

	return result


func get_column_section_count(column: Vector2i) -> int:
	var sections: Dictionary = _columns.get(column, {})
	return sections.size()


func get_column_cell_count(column: Vector2i) -> int:
	var total: int = 0
	var sections: Dictionary = _columns.get(column, {})

	for sy: int in sections:
		total += (sections[sy] as Section).count

	return total


func get_column_cell_list(column: Vector2i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var sections: Dictionary = _columns.get(column, {})
	var base_x: int = column.x * SIZE
	var base_z: int = column.y * SIZE

	for sy: int in sections:
		(sections[sy] as Section).append_cells(
			result,
			base_x,
			sy * SIZE,
			base_z
		)

	return result


## Cells and item ids in one pass. `out_items` is parallel to `out_cells`.
func get_column_cells_and_items(
	column: Vector2i,
	out_cells: Array,
	out_items: Array
) -> void:
	var sections: Dictionary = _columns.get(column, {})
	var base_x: int = column.x * SIZE
	var base_z: int = column.y * SIZE

	for sy: int in sections:
		(sections[sy] as Section).append_cells_and_items(
			out_cells,
			out_items,
			base_x,
			sy * SIZE,
			base_z
		)


## Cell entries with item and orientation. Used by chunk loading and tooling.
func get_column_entries(column: Vector2i) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var sections: Dictionary = _columns.get(column, {})
	var base_x: int = column.x * SIZE
	var base_z: int = column.y * SIZE

	for sy: int in sections:
		(sections[sy] as Section).append_entries(
			result,
			base_x,
			sy * SIZE,
			base_z
		)

	return result


func get_column_min_y(column: Vector2i) -> int:
	var sections: Dictionary = _columns.get(column, {})
	var lowest: int = NO_HEIGHT

	for sy: int in sections:
		lowest = mini(
			lowest,
			sy * SIZE + (sections[sy] as Section).get_min_local_y()
		)

	return lowest


func get_column_max_y(column: Vector2i) -> int:
	var sections: Dictionary = _columns.get(column, {})
	var highest: int = -NO_HEIGHT - 1

	for sy: int in sections:
		highest = maxi(
			highest,
			sy * SIZE + (sections[sy] as Section).get_max_local_y()
		)

	return highest


func clear_column(column: Vector2i) -> void:
	_cache_valid = false
	_columns.erase(column)


func cell_count() -> int:
	var total: int = 0

	for column: Vector2i in _columns:
		total += get_column_cell_count(column)

	return total


func section_count() -> int:
	var total: int = 0

	for column: Vector2i in _columns:
		total += (_columns[column] as Dictionary).size()

	return total


## Conservative in-memory estimate. Includes per-dictionary overhead so sparse
## sections are not flattered.
func memory_bytes() -> int:
	var total: int = 64

	for column: Vector2i in _columns:
		var sections: Dictionary = _columns[column]
		total += 96

		for sy: int in sections:
			total += 96
			total += (sections[sy] as Section).memory_bytes()

	return total


# ---------------------------------------------------------------------------
# Column serialization
# ---------------------------------------------------------------------------

## Encodes every non-empty section in a column. Sections are sorted by
## section-Y so the bytes are deterministic for a given edit sequence.
static func _write_u8(out: PackedByteArray, value: int) -> void:
	out.append(value & 0xFF)


static func _write_u16(out: PackedByteArray, value: int) -> void:
	out.append(value & 0xFF)
	out.append((value >> 8) & 0xFF)


static func _write_s16(out: PackedByteArray, value: int) -> void:
	_write_u16(out, value & 0xFFFF)


static func _write_u32(out: PackedByteArray, value: int) -> void:
	_write_u16(out, value & 0xFFFF)
	_write_u16(out, (value >> 16) & 0xFFFF)


func serialize_column(column: Vector2i) -> PackedByteArray:
	var out := PackedByteArray()
	_write_u32(out, MAGIC)
	_write_u8(out, FORMAT_VERSION)

	var sections: Dictionary = _columns.get(column, {})
	var section_ys: Array = sections.keys()
	section_ys.sort()

	_write_u16(out, section_ys.size())

	for sy: int in section_ys:
		var section: Section = sections[sy]
		_write_s16(out, sy)
		_write_u8(out, section.mode)
		_write_u8(out, section.bits)
		_write_u16(out, section.palette.size())

		for value in section.palette:
			_write_u32(out, value)

		_write_u32(out, section.count)

		if section.mode == Section.MODE_DENSE:
			out.append_array(section.indices)
		elif section.mode == Section.MODE_SPARSE:
			_write_u32(out, section.sparse_indices.size())

			for local in section.sparse_indices:
				_write_u16(out, local)

			for value in section.sparse_values:
				_write_u32(out, value)

	return out


func serialize_column_compressed(column: Vector2i) -> PackedByteArray:
	return compress_blob(serialize_column(column))


## Little-endian reader with bounds checks. Corrupt blobs return short reads
## rather than crashing the game.
class Cursor:
	var data: PackedByteArray
	var offset: int = 0

	func remaining() -> int:
		return data.size() - offset

	func u8() -> int:
		var value: int = data[offset]
		offset += 1
		return value

	func u16() -> int:
		var value: int = data[offset] | (data[offset + 1] << 8)
		offset += 2
		return value

	func s16() -> int:
		var value: int = u16()
		return value - 65536 if value >= 32768 else value

	func u32() -> int:
		var value: int = (
			data[offset]
			| (data[offset + 1] << 8)
			| (data[offset + 2] << 16)
			| (data[offset + 3] << 24)
		)
		offset += 4
		return value

	func take(count: int) -> PackedByteArray:
		var value: PackedByteArray = data.slice(offset, offset + count)
		offset += count
		return value


func import_column_compressed(
	column: Vector2i,
	data: PackedByteArray,
	valid_items: PackedInt32Array,
	min_y: int,
	max_y: int
) -> bool:
	return import_column(
		column,
		decompress_blob(data),
		valid_items,
		min_y,
		max_y
	)


## Imports a serialized column directly into packed sections. Returns false
## without changing the store when a section is malformed, contains an item not
## in `valid_items`, or lies outside [min_y, max_y]; callers then fall back to
## the per-cell decoder.
func import_column(
	column: Vector2i,
	blob: PackedByteArray,
	valid_items: PackedInt32Array,
	min_y: int,
	max_y: int
) -> bool:
	_cache_valid = false

	if blob.size() < 7:
		return false

	var cursor := Cursor.new()
	cursor.data = blob

	if cursor.u32() != MAGIC or cursor.u8() != FORMAT_VERSION:
		return false

	var section_total: int = cursor.u16()
	var sections: Dictionary = {}

	for _index in section_total:
		if cursor.remaining() < 9:
			return false

		var sy: int = cursor.s16()
		var mode: int = cursor.u8()
		var bits: int = cursor.u8()
		var palette_size: int = cursor.u16()

		# Sparse sections carry their values inline and serialize palette_size 0;
		# dense sections always have at least the air sentinel.
		if palette_size < 0 or cursor.remaining() < palette_size * 4 + 4:
			return false

		if mode == Section.MODE_DENSE and palette_size < 1:
			return false

		if mode != Section.MODE_SPARSE and mode != Section.MODE_DENSE:
			return false

		if sy * SIZE + SIZE - 1 < min_y or sy * SIZE > max_y:
			return false

		var palette: PackedInt32Array = PackedInt32Array()
		palette.resize(palette_size)

		for i in palette_size:
			var raw: int = cursor.u32()
			# Dense palettes reserve index 0 for air and serialize it as -1.
			# `u32()` reads that as 0xFFFFFFFF; keep it as the signed sentinel
			# instead of validating it as an item id.
			if raw == 4294967295:
				palette[i] = -1
				continue

			palette[i] = raw
			var item: int = raw >> 8

			if not valid_items.has(item):
				return false

		var count: int = cursor.u32()
		var section := Section.new()

		if mode == Section.MODE_DENSE:
			if bits != 1 and bits != 2 and bits != 4 and bits != 8:
				return false

			var byte_count: int = (VOLUME * bits) >> 3

			if cursor.remaining() < byte_count:
				return false

			section.mode = Section.MODE_DENSE
			section.bits = bits
			section.palette = palette
			section.palette_lookup = {}

			for i in palette_size:
				section.palette_lookup[palette[i]] = i

			section.indices = cursor.take(byte_count)
			section.count = count
		elif mode == Section.MODE_SPARSE:
			if cursor.remaining() < 4:
				return false

			var sparse_count: int = cursor.u32()

			if sparse_count > VOLUME or cursor.remaining() < sparse_count * 6:
				return false

			var indices: PackedInt32Array = PackedInt32Array()
			indices.resize(sparse_count)

			for i in sparse_count:
				indices[i] = cursor.u16()

			var values: PackedInt32Array = PackedInt32Array()
			values.resize(sparse_count)

			for i in sparse_count:
				values[i] = cursor.u32()

				if not valid_items.has(values[i] >> 8):
					return false

			section.mode = Section.MODE_SPARSE
			section.sparse_indices = indices
			section.sparse_values = values
			section.count = sparse_count
		else:
			return false

		if section.count <= 0:
			continue

		sections[sy] = section

	if sections.is_empty():
		_columns.erase(column)
	else:
		_columns[column] = sections

	return true


## Decodes a column blob into cell entries. Returns an empty array on a
## malformed or unsupported blob.
static func decode_column(
	column: Vector2i,
	blob: PackedByteArray
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	# header + section count
	if blob.size() < 7:
		return result

	var cursor := Cursor.new()
	cursor.data = blob

	if cursor.u32() != MAGIC:
		push_error("VoxelSectionStore: bad column magic for %s." % column)
		return result

	if cursor.u8() != FORMAT_VERSION:
		push_error("VoxelSectionStore: unsupported column format for %s." % column)
		return result

	var section_total: int = cursor.u16()
	var base_x: int = column.x * SIZE
	var base_z: int = column.y * SIZE

	for _index in section_total:
		# sy + mode + bits + palette size + count
		if cursor.remaining() < 9:
			return result

		var sy: int = cursor.s16()
		var mode: int = cursor.u8()
		var bits: int = cursor.u8()
		var palette_size: int = cursor.u16()

		if cursor.remaining() < palette_size * 4 + 4:
			return result

		var palette: PackedInt32Array = PackedInt32Array()
		palette.resize(palette_size)

		for i in palette_size:
			palette[i] = cursor.u32()

		var _count: int = cursor.u32()
		var base_y: int = sy * SIZE

		if mode == Section.MODE_DENSE:
			if bits != 1 and bits != 2 and bits != 4 and bits != 8:
				return result

			var byte_count: int = (VOLUME * bits) >> 3

			if cursor.remaining() < byte_count:
				return result

			var data: PackedByteArray = cursor.take(byte_count)

			for local in VOLUME:
				var palette_index: int = _read_dense_index(data, bits, local)

				if palette_index == 0 or palette_index >= palette.size():
					continue

				var value: int = palette[palette_index]
				result.append({
					"position": Vector3i(
						base_x + (local & 15),
						base_y + (local >> 8),
						base_z + ((local >> 4) & 15)
					),
					"item": value >> 8,
					"orientation": value & 0xFF,
				})
		elif mode == Section.MODE_SPARSE:
			if cursor.remaining() < 4:
				return result

			var sparse_count: int = cursor.u32()

			if sparse_count > VOLUME:
				return result

			if cursor.remaining() < sparse_count * 6:
				return result

			var locals: PackedInt32Array = PackedInt32Array()
			locals.resize(sparse_count)

			for i in sparse_count:
				locals[i] = cursor.u16()

			for i in sparse_count:
				var value: int = cursor.u32()
				var local: int = locals[i]
				result.append({
					"position": Vector3i(
						base_x + (local & 15),
						base_y + (local >> 8),
						base_z + ((local >> 4) & 15)
					),
					"item": value >> 8,
					"orientation": value & 0xFF,
				})

	return result


static func decode_column_compressed(
	column: Vector2i,
	data: PackedByteArray
) -> Array[Dictionary]:
	return decode_column(column, decompress_blob(data))


static func _read_dense_index(
	data: PackedByteArray,
	bits: int,
	local: int
) -> int:
	match bits:
		1:
			return (data[local >> 3] >> (local & 7)) & 0x1
		2:
			return (data[local >> 2] >> ((local & 3) << 1)) & 0x3
		4:
			return (data[local >> 1] >> ((local & 1) << 2)) & 0xF
		8:
			return data[local]
		_:
			return 0


## Prefixes the uncompressed size so `decompress_dynamic` does not need a guess.
static func compress_blob(blob: PackedByteArray) -> PackedByteArray:
	var head := PackedByteArray()
	head.resize(4)
	head.encode_u32(0, blob.size())

	if blob.is_empty():
		return head

	return head + blob.compress(FileAccess.COMPRESSION_ZSTD)


static func decompress_blob(data: PackedByteArray) -> PackedByteArray:
	if data.size() < 4:
		return PackedByteArray()

	var size: int = data.decode_u32(0)

	if size == 0 or size > 64 * 1024 * 1024:
		return PackedByteArray()

	return data.slice(4).decompress(size, FileAccess.COMPRESSION_ZSTD)
