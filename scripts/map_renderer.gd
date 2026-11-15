class_name MapRenderer
extends RefCounted

## Builds the statistics map images and the isometric save thumbnail directly
## from NavGridMap data. No SubViewport or 3D capture is needed, so it works
## while the game is paused.

const VOID := Color(0.015, 0.018, 0.025, 1.0)
const EXIT_COLOR := Color(0.25, 1.0, 0.35, 1.0)
const SPAWN_COLOR := Color(1.0, 0.35, 0.2, 1.0)
const ROUTE_COLOR := Color(1.0, 0.88, 0.2, 1.0)
const HEAT_COLD := Color(0.08, 0.28, 0.85, 1.0)
const HEAT_MID := Color(1.0, 0.85, 0.1, 1.0)
const HEAT_HOT := Color(1.0, 0.12, 0.04, 1.0)


static func collect_columns(grid: NavGridMap) -> Dictionary:
	var columns: Dictionary = {}

	for chunk: Vector2i in grid.get_populated_chunks():
		var cells: Dictionary = grid.get_chunk_cells(chunk)
		for cell: Vector3i in cells:
			var item: int = grid.get_cell_item(cell)
			if item == -1:
				continue
			var key := Vector2i(cell.x, cell.z)
			var previous: Dictionary = columns.get(key, {})
			if previous.is_empty() or cell.y > int(previous.get("y", -2147483648)):
				columns[key] = {"y": cell.y, "item": item}

	return columns


static func get_bounds(columns: Dictionary) -> Rect2i:
	if columns.is_empty():
		return Rect2i()

	var min_x: int = 2147483647
	var min_z: int = 2147483647
	var max_x: int = -2147483648
	var max_z: int = -2147483648

	for key: Vector2i in columns:
		min_x = mini(min_x, key.x)
		min_z = mini(min_z, key.y)
		max_x = maxi(max_x, key.x)
		max_z = maxi(max_z, key.y)

	return Rect2i(min_x, min_z, max_x - min_x + 1, max_z - min_z + 1)


static func get_height_range(columns: Dictionary) -> Vector2i:
	if columns.is_empty():
		return Vector2i.ZERO

	var min_y: int = 2147483647
	var max_y: int = -2147483648
	for key: Vector2i in columns:
		var y: int = int(columns[key].get("y", 0))
		min_y = mini(min_y, y)
		max_y = maxi(max_y, y)
	return Vector2i(min_y, max_y)


static func get_exit_cells(grid: NavGridMap) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for node in grid.get_tree().get_nodes_in_group("EvacPoint"):
		if not (node is Node3D):
			continue
		var cell: Vector3i = grid.world_to_cell((node as Node3D).global_position)
		var key := Vector2i(cell.x, cell.z)
		if seen.has(key):
			continue
		seen[key] = true
		result.append(key)
	return result


static func get_spawner_cells(grid: NavGridMap) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for node in grid.get_tree().get_nodes_in_group("spawners"):
		if not (node is Node3D):
			continue
		var cell: Vector3i = grid.world_to_cell((node as Node3D).global_position)
		var key := Vector2i(cell.x, cell.z)
		if seen.has(key):
			continue
		seen[key] = true
		result.append(key)
	return result


static func render_top_down(
	grid: NavGridMap,
	mode: String = "topo",
	image_size: int = 256
) -> Image:
	var columns: Dictionary = collect_columns(grid)
	if columns.is_empty():
		return null

	var bounds: Rect2i = get_bounds(columns)
	var heights: Vector2i = get_height_range(columns)
	var base := Image.create(bounds.size.x, bounds.size.y, false, Image.FORMAT_RGBA8)
	base.fill(VOID)

	var heat_map: Dictionary = grid.get_congestion_heat_map()
	var heat_by_cell: Dictionary = {}
	var max_heat: float = 0.0
	for cell: Vector3i in heat_map:
		var heat: float = float(heat_map[cell])
		var key := Vector2i(cell.x, cell.z)
		heat_by_cell[key] = maxf(float(heat_by_cell.get(key, 0.0)), heat)
		max_heat = maxf(max_heat, heat)
	max_heat = maxf(max_heat, 1.0)

	for key: Vector2i in columns:
		var y: int = int(columns[key].get("y", 0))
		var color: Color
		match mode:
			"heat":
				color = _heat_color(float(heat_by_cell.get(key, 0.0)), max_heat)
			"route":
				color = _topo_color(y, heights.x, heights.y).darkened(0.55)
			_:
				color = _topo_color(y, heights.x, heights.y)
				if y % 4 == 0:
					color = color.lightened(0.12)
		base.set_pixel(key.x - bounds.position.x, key.y - bounds.position.y, color)

	if mode == "route":
		var routes: Dictionary = compute_routes(grid)
		for path: PackedVector3Array in routes.get("paths", []):
			_draw_path(base, path, grid, bounds)

	for cell: Vector2i in get_exit_cells(grid):
		_marker(base, bounds, cell, EXIT_COLOR)
	for cell: Vector2i in get_spawner_cells(grid):
		_marker(base, bounds, cell, SPAWN_COLOR)

	return _fit_square(base, image_size)


static func render_isometric(grid: NavGridMap, image_size: int = 256) -> Image:
	var columns: Dictionary = collect_columns(grid)
	if columns.is_empty():
		return null

	var bounds: Rect2i = get_bounds(columns)
	var heights: Vector2i = get_height_range(columns)
	var tw: int = 4
	var th: int = 2
	var hs: int = 1
	var height_span: int = maxi(1, heights.y - heights.x + 1)

	var min_iso_x: int = 2147483647
	var max_iso_x: int = -2147483648
	var min_iso_y: int = 2147483647
	var max_iso_y: int = -2147483648
	for key: Vector2i in columns:
		var y: int = int(columns[key].get("y", 0))
		var ix: int = (key.x - key.y) * tw
		var iy: int = (key.x + key.y) * th - (y - heights.x) * hs
		min_iso_x = mini(min_iso_x, ix)
		max_iso_x = maxi(max_iso_x, ix)
		min_iso_y = mini(min_iso_y, iy)
		max_iso_y = maxi(max_iso_y, iy)

	var width: int = max_iso_x - min_iso_x + tw * 2 + 4
	var height: int = max_iso_y - min_iso_y + th * 2 + hs * height_span + 4
	var iso := Image.create(width, height, false, Image.FORMAT_RGBA8)
	iso.fill(VOID)

	var order: Array = columns.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x + a.y < b.x + b.y
	)

	var exits: Dictionary = {}
	for cell: Vector2i in get_exit_cells(grid):
		exits[cell] = true
	var spawners: Dictionary = {}
	for cell: Vector2i in get_spawner_cells(grid):
		spawners[cell] = true

	for key: Vector2i in order:
		var y: int = int(columns[key].get("y", 0))
		var cx: int = (key.x - key.y) * tw - min_iso_x + tw + 2
		var cy: int = (key.x + key.y) * th - (y - heights.x) * hs - min_iso_y + th + 2
		var color: Color = _topo_color(y, heights.x, heights.y)
		_diamond(iso, cx, cy, tw, th, color)
		# A darker lower edge gives the flat diamonds some depth.
		_line(iso, cx - tw, cy, cx, cy + th, color.darkened(0.35))
		_line(iso, cx, cy + th, cx + tw, cy, color.darkened(0.35))
		if exits.has(key):
			_diamond(iso, cx, cy, 2, 1, EXIT_COLOR)
		elif spawners.has(key):
			_diamond(iso, cx, cy, 2, 1, SPAWN_COLOR)

	return _fit_square(iso, image_size)


static func compute_routes(grid: NavGridMap) -> Dictionary:
	var tree: SceneTree = grid.get_tree()
	if tree == null:
		return {"paths": [], "exits": [], "spawners": []}

	var exits: Array = []
	var seen_exits: Dictionary = {}
	for node in tree.get_nodes_in_group("EvacPoint"):
		if not (node is Node3D):
			continue
		var cell: Vector3i = grid.world_to_cell((node as Node3D).global_position)
		var key := Vector2i(cell.x, cell.z)
		if seen_exits.has(key):
			continue
		seen_exits[key] = true
		exits.append(node)

	var spawners: Array = []
	for node in tree.get_nodes_in_group("spawners"):
		if node is Node3D:
			spawners.append(node)

	if spawners.is_empty():
		var player = tree.get_first_node_in_group("Player")
		if player is Node3D:
			spawners.append(player)

	var paths: Array = []
	for spawner: Node3D in spawners:
		var best_exit: Node3D = null
		var best_distance: float = INF
		for exit: Node3D in exits:
			var distance: float = grid.estimate_path_distance(
				spawner.global_position,
				exit.global_position
			)
			if distance < best_distance:
				best_distance = distance
				best_exit = exit

		if best_exit == null:
			continue

		var path: PackedVector3Array = grid.request_path_immediate(
			spawner.global_position,
			best_exit.global_position
		)
		if not path.is_empty():
			paths.append(path)

	return {"paths": paths, "exits": exits, "spawners": spawners}


static func format_statistics(grid: NavGridMap) -> String:
	var summary: Dictionary = {}
	var manager = grid.get_node_or_null("/root/EvacuationManager")
	if manager != null and manager.has_method("get_summary"):
		summary = manager.get_summary()

	var columns: Dictionary = collect_columns(grid)
	var heights: Vector2i = get_height_range(columns)
	var exits: Array = get_exit_cells(grid)
	var spawners: Array = get_spawner_cells(grid)
	var heat_map: Dictionary = grid.get_congestion_heat_map()
	var max_heat: float = 0.0
	for cell: Vector3i in heat_map:
		max_heat = maxf(max_heat, float(heat_map[cell]))

	var routes: Dictionary = compute_routes(grid)
	var route_count: int = int(routes.get("paths", []).size())
	var route_total: float = 0.0
	for path: PackedVector3Array in routes.get("paths", []):
		for index in range(1, path.size()):
			route_total += path[index - 1].distance_to(path[index])

	var alive: int = int(summary.get("alive", grid.get_tree().get_nodes_in_group("npc").size()))
	var cap: int = GlobalData.global_unit_cap
	var spawned: int = int(summary.get("spawned", GlobalData.npcs_spawned))
	var evacuated: int = int(summary.get("evacuated", GlobalData.npcs_evacuated))
	var failed: int = int(summary.get("failed_paths", 0))
	var deaths: int = int(summary.get("deaths", 0))
	var average_time: float = float(summary.get("average_time", 0.0))
	var p95_time: float = float(summary.get("p95_time", 0.0))
	var peak_density: float = float(summary.get("peak_density", 0.0))
	var total_distance: float = float(summary.get("total_distance", 0.0))
	var stuck_time: float = float(summary.get("total_stuck_time", 0.0))
	var stuck_strikes: int = int(summary.get("total_stuck_strikes", 0))

	var lines: Array[String] = [
		"POPULATION",
		"Alive %d / %d" % [alive, cap],
		"Spawned %d   Evacuated %d" % [spawned, evacuated],
		"Failed %d   Deaths %d" % [failed, deaths],
		"Avg evac %s   P95 %s" % [_format_time(average_time), _format_time(p95_time)],
		"Peak density %.1f" % peak_density,
		"Distance %.0f m   Stuck %s (%d)" % [total_distance, _format_time(stuck_time), stuck_strikes],
		"",
		"MAP",
		"Columns %d   Height %d..%d" % [columns.size(), heights.x, heights.y],
		"Exits %d   Spawners %d" % [exits.size(), spawners.size()],
		"Heat %d cells   Peak %.2f" % [heat_map.size(), max_heat],
		"Ideal routes %d   Avg %.0f m" % [route_count, route_total / maxf(float(route_count), 1.0)],
	]
	return "\n".join(PackedStringArray(lines))


static func save_thumbnail(grid: NavGridMap, path: String) -> bool:
	var image: Image = render_isometric(grid, 256)
	if image == null:
		return false
	return image.save_png(path) == OK


static func _draw_path(
	image: Image,
	path: PackedVector3Array,
	grid: NavGridMap,
	bounds: Rect2i
) -> void:
	if path.size() < 2:
		return

	var previous := Vector2i(-1, -1)
	for point: Vector3 in path:
		var cell: Vector3i = grid.world_to_cell(point)
		var current := Vector2i(
			clampi(cell.x - bounds.position.x, 0, bounds.size.x - 1),
			clampi(cell.z - bounds.position.y, 0, bounds.size.y - 1)
		)
		if previous.x >= 0:
			_line(image, previous.x, previous.y, current.x, current.y, ROUTE_COLOR)
		image.set_pixel(current.x, current.y, ROUTE_COLOR)
		previous = current


static func _marker(
	image: Image,
	bounds: Rect2i,
	cell: Vector2i,
	color: Color
) -> void:
	var x: int = cell.x - bounds.position.x
	var y: int = cell.y - bounds.position.y
	if x < 0 or y < 0 or x >= bounds.size.x or y >= bounds.size.y:
		return
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var px: int = x + dx
			var py: int = y + dy
			if px >= 0 and py >= 0 and px < image.get_width() and py < image.get_height():
				image.set_pixel(px, py, color)


static func _line(
	image: Image,
	x0: int,
	y0: int,
	x1: int,
	y1: int,
	color: Color
) -> void:
	var dx: int = absi(x1 - x0)
	var sx: int = 1 if x0 < x1 else -1
	var dy: int = -absi(y1 - y0)
	var sy: int = 1 if y0 < y1 else -1
	var error: int = dx + dy

	while true:
		if x0 >= 0 and y0 >= 0 and x0 < image.get_width() and y0 < image.get_height():
			image.set_pixel(x0, y0, color)
		if x0 == x1 and y0 == y1:
			break
		var twice: int = error * 2
		if twice >= dy:
			error += dy
			x0 += sx
		if twice <= dx:
			error += dx
			y0 += sy


static func _diamond(
	image: Image,
	cx: int,
	cy: int,
	tw: int,
	th: int,
	color: Color
) -> void:
	for dy in range(-th, th + 1):
		var ratio: float = 1.0 - float(absi(dy)) / float(maxi(th, 1))
		var half: int = int(float(tw) * ratio)
		for dx in range(-half, half + 1):
			var px: int = cx + dx
			var py: int = cy + dy
			if px >= 0 and py >= 0 and px < image.get_width() and py < image.get_height():
				image.set_pixel(px, py, color)


static func _topo_color(y: int, min_y: int, max_y: int) -> Color:
	var span: float = maxf(float(max_y - min_y), 1.0)
	var t: float = clampf(float(y - min_y) / span, 0.0, 1.0)
	if t < 0.5:
		return Color(0.10, 0.16, 0.28).lerp(
			Color(0.25, 0.52, 0.30), t * 2.0
		)
	return Color(0.25, 0.52, 0.30).lerp(
		Color(0.72, 0.60, 0.38), (t - 0.5) * 2.0
	)


static func _heat_color(heat: float, max_heat: float) -> Color:
	if heat <= 0.0:
		return Color(0.05, 0.06, 0.08)
	var t: float = clampf(heat / maxf(max_heat, 0.001), 0.0, 1.0)
	if t < 0.5:
		return HEAT_COLD.lerp(HEAT_MID, t * 2.0)
	return HEAT_MID.lerp(HEAT_HOT, (t - 0.5) * 2.0)


static func _fit_square(source: Image, image_size: int) -> Image:
	var fit: float = minf(
		float(image_size) / float(source.get_width()),
		float(image_size) / float(source.get_height())
	)
	var width: int = maxi(1, int(float(source.get_width()) * fit))
	var height: int = maxi(1, int(float(source.get_height()) * fit))
	var resized: Image = source.duplicate()
	resized.resize(width, height, Image.INTERPOLATE_NEAREST)

	var square := Image.create(image_size, image_size, false, Image.FORMAT_RGBA8)
	square.fill(VOID)
	square.blit_rect(
		resized,
		Rect2i(0, 0, width, height),
		Vector2i(
			(image_size - width) / 2,
			(image_size - height) / 2
		)
	)
	return square


static func _format_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "0.0s"
	if seconds < 60.0:
		return "%.1fs" % seconds
	return "%d:%02d" % [int(seconds / 60.0), int(seconds) % 60]
