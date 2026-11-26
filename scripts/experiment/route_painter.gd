extends Node

## Authored evacuation-route painter.
##
## The route paint tool is a held UseComponent scene in the Useables tab. While
## it is held:
##   - left click picks the first cell, then previews an A* corridor to the cell
##     under the crosshair; a second left click commits those cells;
##   - right click erases the painted cell under the crosshair.
##
## Painted cells are not new blocks. They are stored per save/layout and applied
## to `NavGridMap.authored_route_cells`, which lowers their path cost. A*, flow
## fields, the optimizer's cost fields and therefore the agents all prefer the
## corridor. The coloured overlay exists only while the tool is held.
##
## Console: route_paint_list, route_paint_clear, plan_paint <plan_id>.

const ROUTE_TOOL_PATH: String = "res://scenes/useables/route_paint_tool.tscn"
const FILE_NAME: String = "authored_routes.json"
const FORMAT: String = "ero-authored-routes"
const VERSION: int = 1
const MAX_RAY_DISTANCE: float = 36.0
const MAX_ROUTE_CELLS: int = 160
const PREVIEW_REFRESH: float = 0.06

var active: bool = false
var max_ray_distance: float = MAX_RAY_DISTANCE
var max_route_cells: int = MAX_ROUTE_CELLS

var _grid: NavGridMap = null
var _overlay: Node3D = null
var _committed: Dictionary = {}      # Vector3i -> true
var _preview: Array[Vector3i] = []
var _start_cell: Vector3i = Vector3i.ZERO
var _has_start: bool = false
var _hover_cell: Vector3i = Vector3i.ZERO
var _hover_valid: bool = false
var _hover_world: Vector3 = Vector3.ZERO
var _load_key: String = ""
var _layout_signature: String = ""
var _signature_checked_msec: int = 0
var _accum: float = 0.0
var _status_accum: float = 0.0
var _last_status: String = ""
var _mesh_committed: MeshInstance3D = null
var _mesh_preview: MeshInstance3D = null
var _mesh_start: MeshInstance3D = null
var _mesh_hover: MeshInstance3D = null
var _overlay_signature: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	_ensure_grid()

	if _grid != null and is_instance_valid(_grid):
		_load_for_current_world()

	var build := _build_controller()
	var held: PackedScene = null

	if build != null and build.has_method("get_held_placeable_scene"):
		held = build.call("get_held_placeable_scene")

	active = (
		held != null
		and is_instance_valid(held)
		and held.resource_path == ROUTE_TOOL_PATH
	)

	if not active:
		_set_overlay_visible(false)

		if _has_start:
			_has_start = false

		_preview.clear()
		return

	_ensure_overlay()

	if _grid == null or _overlay == null:
		return

	_accum += delta

	if _accum >= PREVIEW_REFRESH:
		_accum = 0.0
		_update_hover_and_preview()
		_draw_overlay()
		_refresh_status()


# ---------------------------------------------------------------------------
# Tool callbacks (from RoutePaintComponent)
# ---------------------------------------------------------------------------

func primary_click() -> void:
	if not active:
		return

	_update_hover_and_preview()

	if not _hover_valid:
		_show_status("Aim at a walkable block first.")
		return

	if not _has_start:
		_start_cell = _hover_cell
		_has_start = true
		_show_status("Start set. Aim at the destination block; left click confirms.")
		_draw_overlay()
		return

	if _preview.is_empty():
		_show_status("No walkable route between those blocks.")
		return

	var painted := _preview.size()

	for cell: Vector3i in _preview:
		_committed[cell] = true

	_apply_to_grid()
	_save()
	_has_start = false
	_preview.clear()
	_show_status("Painted %d cells. Right click erases a painted cell." % painted)
	_draw_overlay()


func secondary_click() -> void:
	if not active:
		return

	_update_hover_and_preview()

	if not _hover_valid:
		return

	if _committed.has(_hover_cell):
		_committed.erase(_hover_cell)
		_apply_to_grid()
		_save()
		_show_status("Erased one painted cell.")
	else:
		_show_status("No painted route on that block.")
	_draw_overlay()


## Called when the player switches away from the tool or presses Escape.
func cancel() -> void:
	_has_start = false
	_preview.clear()
	_set_overlay_visible(false)


## Programmatic authoring/testing entry point: paint the A* corridor between two
## nav cells. Returns the number of cells added.
func paint_between(start: Vector3i, finish: Vector3i) -> int:
	_ensure_grid()

	if _grid == null or not _grid.is_nav_cell_valid(start) or not _grid.is_nav_cell_valid(finish):
		return 0

	if _layout_signature.is_empty():
		_load_for_current_world()

	var cells: Array[Vector3i] = _grid.get_path_cells(
		_grid.to_global(_grid.map_to_local(start)),
		_grid.to_global(_grid.map_to_local(finish))
	)

	if cells.is_empty() or cells.size() > max_route_cells:
		return 0

	var added := 0

	for cell: Vector3i in cells:
		if not _committed.has(cell):
			_committed[cell] = true
			added += 1

	_apply_to_grid()
	_save()
	_show_status("Painted %d cells. Right click erases a painted cell." % added)
	return added


func get_committed_cells() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []

	for cell: Vector3i in _committed.keys():
		cells.append(cell)

	cells.sort()
	return cells


func clear_all() -> void:
	_committed.clear()
	_has_start = false
	_preview.clear()
	_apply_to_grid()
	_save()
	_show_status("Painted route cleared.")


## Bundle the current painted corridor into a plan file. The plan has no agent
## assignments; applying it restores the corridor preference. This is the
## "authored route plan" path.
func capture_authored_plan(plan_name: String) -> EvacuationPlan:
	_ensure_grid()

	if _grid == null:
		return null

	var layout: Dictionary = EvacuationPlan.capture_layout_signature()
	var plan := EvacuationPlan.new()
	plan.name = plan_name if not plan_name.is_empty() else "Authored route %s" % Time.get_time_string_from_system()
	plan.created_at = Time.get_datetime_string_from_system(true, true)
	plan.source = "authored"
	plan.scene = String(get_tree().current_scene.scene_file_path) if get_tree().current_scene != null else ""
	plan.layout_signature = String(layout.get("signature", ""))
	plan.environment_version = GlobalData.environment_version
	plan.exits = layout.get("exits", [])
	plan.algorithm = "authored_route"
	plan.mode = "preferred_corridor"
	plan.notes = "Painted corridor. Apply to make these cells cheaper than the surrounding floor."

	for cell: Vector3i in _committed.keys():
		plan.authored_route_cells.append([cell.x, cell.y, cell.z])

	return plan


## Replace the painted layer from a plan and persist it.
func set_cells(cells: Array) -> int:
	_ensure_grid()

	if _grid == null:
		return 0

	if _layout_signature.is_empty():
		_load_for_current_world()

	_committed.clear()
	var count := 0

	for value: Variant in cells:
		var cell := _cell_from_array(value)

		if cell != NavGridMap.NO_CELL and _grid.is_nav_cell_valid(cell):
			if not _committed.has(cell):
				_committed[cell] = true
				count += 1

	_apply_to_grid()
	_save()
	return count


## Load an existing plan's routes into the paint layer for editing. The plan is
## not applied to agents; it only seeds the painted corridor.
func set_from_plan(plan: EvacuationPlan) -> int:
	if plan == null:
		return 0

	_ensure_grid()

	if _grid == null:
		return 0

	_committed.clear()
	var count := 0

	for assignment_value: Variant in plan.assignments:
		if not assignment_value is Dictionary:
			continue

		var route: Array = EvacuationPlan._point_array_list(
			(assignment_value as Dictionary).get("route", [])
		)

		for index: int in range(1, route.size()):
			var a := _world_from_array(route[index - 1])
			var b := _world_from_array(route[index])
			var cells: Array[Vector3i] = _grid.get_path_cells(a, b)

			for cell: Vector3i in cells:
				if not _committed.has(cell):
					_committed[cell] = true
					count += 1

	_apply_to_grid()
	_save()
	_show_status("Loaded %d route cells from %s; edit with left/right click." % [count, plan.name])
	return count


# ---------------------------------------------------------------------------
# Hover / preview
# ---------------------------------------------------------------------------

func _update_hover_and_preview() -> void:
	var cell := _raycast_cell()

	if not bool(cell.get("valid", false)):
		_hover_valid = false
		_preview.clear()
		return

	_hover_valid = true
	_hover_cell = cell["cell"]
	_hover_world = cell["world"]

	if not _has_start:
		_preview.clear()
		return

	var path_cells: Array[Vector3i] = _grid.get_path_cells(
		_grid.to_global(_grid.map_to_local(_start_cell)),
		_hover_world
	)

	if path_cells.is_empty() or path_cells.size() > max_route_cells:
		_preview.clear()
		return

	_preview = path_cells


func _raycast_cell() -> Dictionary:
	var camera := get_viewport().get_camera_3d()

	if camera == null or _grid == null:
		return {"valid": false}

	var origin := camera.global_position
	var end := origin - camera.global_transform.basis.z * max_ray_distance
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = get_viewport().get_world_3d().direct_space_state.intersect_ray(query)

	if hit.is_empty():
		return {"valid": false}

	var position: Vector3 = hit.get("position", Vector3.ZERO)
	var cell: Vector3i = _grid.resolve_nav_cell(position)

	if not _grid.is_nav_cell_valid(cell):
		cell = _grid.resolve_nav_cell(position + Vector3.UP * 0.5)

	if not _grid.is_nav_cell_valid(cell):
		return {"valid": false}

	return {
		"valid": true,
		"cell": cell,
		"world": _grid.to_global(_grid.map_to_local(cell)),
	}


# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

func _ensure_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		return

	var host: Node = get_tree().current_scene if get_tree() != null else null

	if host == null:
		return

	_overlay = Node3D.new()
	_overlay.name = "AuthoredRoutePaintOverlay"
	host.add_child(_overlay)

	_mesh_committed = _make_layer("Committed", Color(0.22, 0.95, 0.55, 0.62))
	_mesh_preview = _make_layer("Preview", Color(1.0, 0.78, 0.2, 0.72))
	_mesh_start = _make_layer("Start", Color(0.25, 0.65, 1.0, 0.9))
	_mesh_hover = _make_layer("Hover", Color(1.0, 1.0, 1.0, 0.55))
	_set_overlay_visible(false)


func _make_layer(layer_name: String, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = layer_name
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	node.material_override = material
	_overlay.add_child(node)
	return node


func _draw_overlay() -> void:
	if _overlay == null or _grid == null:
		return

	_set_overlay_visible(true)
	var signature := _compute_overlay_signature()

	if signature == _overlay_signature and _overlay.visible:
		return

	_overlay_signature = signature
	var committed_cells: Array[Vector3i] = []

	for cell: Vector3i in _committed.keys():
		committed_cells.append(cell)

	_set_layer(_mesh_committed, committed_cells, 0.015)
	_set_layer(_mesh_preview, _preview, 0.025)
	var start_cells: Array[Vector3i] = []
	var hover_cells: Array[Vector3i] = []

	if _has_start:
		start_cells.append(_start_cell)

	if _hover_valid:
		hover_cells.append(_hover_cell)

	_set_layer(_mesh_start, start_cells, 0.045)
	_set_layer(_mesh_hover, hover_cells, 0.06)


func _compute_overlay_signature() -> String:
	var preview_first := Vector3i.ZERO
	var preview_last := Vector3i.ZERO

	if not _preview.is_empty():
		preview_first = _preview[0]
		preview_last = _preview[_preview.size() - 1]

	return "%d|%d|%s|%s|%s|%s|%s|%s" % [
		_committed.size(),
		_preview.size(),
		preview_first,
		preview_last,
		_start_cell,
		_hover_cell,
		_has_start,
		_hover_valid,
	]


func _set_layer(node: MeshInstance3D, cells: Array[Vector3i], lift: float) -> void:
	if node == null or _grid == null:
		return

	node.visible = not cells.is_empty()

	if cells.is_empty():
		return

	# Build a flat quad per cell. ImmediateMesh avoids MultiMesh's deferred
	# instance buffer, which flickered and produced wrong-scale debris when it
	# was rewritten on every preview update.
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := _grid.cell_size * 0.46
	var y := _grid.cell_size.y * 0.5 + lift

	for cell: Vector3i in cells:
		var center: Vector3 = _grid.to_global(_grid.map_to_local(cell))
		center.y += y
		var a := center + Vector3(-half.x, 0.0, -half.z)
		var b := center + Vector3(half.x, 0.0, -half.z)
		var c := center + Vector3(half.x, 0.0, half.z)
		var d := center + Vector3(-half.x, 0.0, half.z)
		mesh.surface_add_vertex(a)
		mesh.surface_add_vertex(b)
		mesh.surface_add_vertex(c)
		mesh.surface_add_vertex(a)
		mesh.surface_add_vertex(c)
		mesh.surface_add_vertex(d)

	mesh.surface_end()
	node.mesh = mesh


func _set_overlay_visible(value: bool) -> void:
	if _overlay == null or not is_instance_valid(_overlay):
		return

	_overlay.visible = value


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _load_for_current_world() -> void:
	if get_tree() == null:
		return

	var demo_store := get_node_or_null("/root/DemoStore")
	var slug := String(demo_store.call("active_save_slug")) if demo_store != null else "_unsaved"
	var now := Time.get_ticks_msec()

	# Hashing every used block each frame is unnecessary. Grid edits change the
	# signature, so refresh at a low rate rather than every 60 Hz frame.
	if (
		_load_key.begins_with(slug + "|")
		and now - _signature_checked_msec < 2500
	):
		return

	_signature_checked_msec = now
	var layout := String(EvacuationPlan.capture_layout_signature().get("signature", ""))
	var key := "%s|%s" % [slug, layout]

	if key == _load_key:
		return

	_load_key = key
	_layout_signature = layout
	_committed.clear()
	var file_path := _file_path(slug)
	var data := _read_json(file_path)
	var layouts: Dictionary = data.get("layouts", {})
	var entry: Variant = layouts.get(layout, {})

	if entry is Dictionary:
		for value: Variant in (entry as Dictionary).get("cells", []):
			var cell := _cell_from_array(value)

			if _grid != null and _grid.is_nav_cell_valid(cell):
				_committed[cell] = true

	_apply_to_grid()


func _save() -> void:
	var demo_store := get_node_or_null("/root/DemoStore")
	var slug := String(demo_store.call("active_save_slug")) if demo_store != null else "_unsaved"
	var file_path := _file_path(slug)
	var data := _read_json(file_path)
	var layouts: Dictionary = data.get("layouts", {})
	layouts[_layout_signature] = {
		"cells": _cells_to_arrays(),
		"updated_at": Time.get_datetime_string_from_system(true, true),
	}
	DirAccess.make_dir_recursive_absolute(file_path.get_base_dir())
	var file := FileAccess.open(file_path, FileAccess.WRITE)

	if file == null:
		_show_status("Could not write authored route file.")
		return

	file.store_string(JSON.stringify({
		"format": FORMAT,
		"version": VERSION,
		"layouts": layouts,
	}, "\t", false))
	file.close()


func _file_path(slug: String) -> String:
	if slug.is_empty() or slug == "_unsaved":
		return "user://authored_routes.json"

	return "user://saves/%s/%s" % [slug, FILE_NAME]


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _cells_to_arrays() -> Array:
	var result: Array = []

	for cell: Vector3i in _committed.keys():
		result.append([cell.x, cell.y, cell.z])

	return result


func _apply_to_grid() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return

	_overlay_signature = ""
	var cells: Array = _committed.keys()
	_grid.set_authored_route_cells(cells)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _ensure_grid() -> void:
	if get_tree() == null:
		return

	if _grid != null and is_instance_valid(_grid):
		return

	_grid = get_tree().get_first_node_in_group("grid_map") as NavGridMap


func _build_controller() -> Node:
	if get_tree() == null:
		return null

	var player := get_tree().get_first_node_in_group("player")

	if player == null:
		return null

	return player.get_node_or_null("BuildController")


func _world_from_array(value: Array) -> Vector3:
	if value.size() < 3:
		return Vector3.ZERO

	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _cell_from_array(value: Variant) -> Vector3i:
	if not value is Array or (value as Array).size() < 3:
		return NavGridMap.NO_CELL

	return Vector3i(int(value[0]), int(value[1]), int(value[2]))


func _refresh_status() -> void:
	_status_accum += 0.06

	if _status_accum < 4.0:
		return

	_status_accum = 0.0
	var text := "Route Paint: left click start, left click confirm, right click erase."

	if _has_start:
		text = "Route Paint: aim at the destination and left click to confirm (%d preview cells)." % _preview.size()

	_show_status(text)


func _show_status(text: String) -> void:
	_last_status = text

	if get_tree() == null:
		return

	var player := get_tree().get_first_node_in_group("player")

	if player == null:
		return

	var hud := player.get_node_or_null("HUD/HUD")

	if hud != null and hud.has_method("show_build_label"):
		hud.call("show_build_label", text, 1.0, 0.4)


func _show_status_once(text: String) -> void:
	_show_status(text)
