class_name BuildController
extends Node

## Owns all placement/removal behaviour: the drag-plane selection, ghost
## preview, block edits and placeables. Player keeps movement and input.

@export_group("Building")
## Maximum number of cells a single flat drag can place or remove.
@export_range(1, 4096, 1) var max_build_area_volume: int = 512
## How far from the camera building rays reach.
@export var build_reach: float = 6.0
## How long the button must be held before a click becomes a drag selection.
@export_range(0.05, 1.0, 0.01) var build_hold_delay: float = 0.3
## Automatically rotate stair blocks toward the player when placed.
@export var auto_stairs: bool = true
## Direction the stair mesh's low/front side points before rotation.
## stair.gltf's low side faces +X.
@export var stair_front_axis: Vector3 = Vector3.RIGHT

@export_group("Scene Paths")
@export var camera_path: NodePath = NodePath("../head/CameraSmooth/Camera3D")
@export var collision_shape_path: NodePath = NodePath("../CollisionShape3D")
@export var hud_path: NodePath = NodePath("../HUD/HUD")

var player: CharacterBody3D = null
var hud_manager: HUDManager = null

var grid_map: NavGridMap
var build_items: PackedInt32Array = PackedInt32Array()
var build_index: int = 0
var inventory_open: bool = false
var build_mode_active: bool = true

enum BuildPlane { FLOOR, WALL }
## Toggled by the `switch_axis` action. Floors are the default.
var build_plane: BuildPlane = BuildPlane.FLOOR

var _camera: Camera3D = null
var _collision_shape: CollisionShape3D = null
var _sfx_land: AudioStreamPlayer3D = null
var _setup_done: bool = false
var _selected_placeable_scene: PackedScene = null

var _place_held: bool = false
var _break_held: bool = false
var _hold_time: float = 0.0
var _drag_unlocked: bool = false
var _area_active: bool = false
var _area_destroying: bool = false
var _area_anchor: Vector3i = Vector3i.ZERO
var _area_target: Vector3i = Vector3i.ZERO
var _area_plane_point: Vector3 = Vector3.ZERO
var _area_plane_normal: Vector3 = Vector3.UP
var _area_plane_axis: int = 1
var _area_cells: Array[Vector3i] = []
var _preview_cells: Array[Vector3i] = []
var _preview_destroying: bool = false
var _preview_item: int = -1
var _preview_orientation: int = -1

var ghost_area: MultiMeshInstance3D = null
var ghost_multimesh: MultiMesh = null
var ghost_material: StandardMaterial3D = null
var ghost_cube_mesh: BoxMesh = null

const PLACE_PREVIEW_COLOR := Color(0.35, 0.75, 1.0, 0.38)
const DESTROY_PREVIEW_COLOR := Color(1.0, 0.12, 0.08, 0.45)


func _ready() -> void:
	player = get_parent() as CharacterBody3D

	if player == null:
		push_error("BuildController must be a child of a CharacterBody3D.")
		return

	_camera = get_node_or_null(camera_path) as Camera3D
	_collision_shape = get_node_or_null(collision_shape_path) as CollisionShape3D
	hud_manager = get_node_or_null(hud_path) as HUDManager
	_sfx_land = player.get_node_or_null("GenericLandImpact") as AudioStreamPlayer3D

	if _camera == null or _collision_shape == null:
		push_error("BuildController: camera or collision shape path is invalid.")
		return

	call_deferred("_setup")


func _setup() -> void:
	if _setup_done or player == null:
		return

	_setup_done = true

	if hud_manager:
		hud_manager.item_selected.connect(_on_inventory_item_selected)
		hud_manager.placeable_selected.connect(_on_placeable_selected)

	_get_grid_map()
	_init_ghost_block()
	_update_build_ui()


func _input(event: InputEvent) -> void:
	if not _setup_done or player == null or player.is_dead:
		return

	if event.is_action_pressed("toggle_build_mode"):
		_toggle_build_mode()
		return

	if event.is_action_pressed("switch_axis"):
		_toggle_build_plane()
		return

	if build_mode_active and event.is_action_pressed("toggle_inventory"):
		_toggle_inventory()
		return

	if event.is_action_released("place_block") and _place_held:
		_place_held = false
		_finish_area()
	elif event.is_action_released("break_block") and _break_held:
		_break_held = false
		_finish_area()

	if build_mode_active and not inventory_open and player.movement_enabled:
		if event.is_action_pressed("place_block"):
			_start_build_hold(true)
		elif event.is_action_pressed("break_block"):
			_start_build_hold(false)
		elif event.is_action_pressed("next_block"):
			_cycle_build_item(1)
		elif event.is_action_pressed("prev_block"):
			_cycle_build_item(-1)


func _physics_process(_delta: float) -> void:
	if not _setup_done or player == null:
		return

	if player.is_dead:
		_cancel_build_drag()
		return

	if build_mode_active and not inventory_open:
		_update_ghost_block()

		if (
			player.movement_enabled
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
		):
			_update_build_drag(_delta)
		else:
			_cancel_build_drag()
	else:
		_hide_ghost_block()
		_cancel_build_drag()

	if not player.movement_enabled:
		_cancel_build_drag()


func _exit_tree() -> void:
	if is_instance_valid(ghost_area):
		ghost_area.queue_free()
# --- Building & UI Integration ---
func _get_grid_map() -> NavGridMap:
	if not is_instance_valid(grid_map):
		grid_map = get_tree().get_first_node_in_group("grid_map") as NavGridMap
		if grid_map and grid_map.mesh_library:
			build_items = grid_map.mesh_library.get_item_list()
			build_index = 0
			if hud_manager:
				hud_manager.setup_inventory(build_items, grid_map.mesh_library)
			_update_build_ui()
	return grid_map

func _init_ghost_block() -> void:
	ghost_area = MultiMeshInstance3D.new()
	ghost_area.name = "PlacementGhost"
	ghost_area.top_level = true
	ghost_area.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	ghost_multimesh = MultiMesh.new()
	ghost_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	ghost_multimesh.instance_count = 0
	ghost_area.multimesh = ghost_multimesh

	ghost_material = StandardMaterial3D.new()
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost_material.albedo_color = PLACE_PREVIEW_COLOR
	ghost_area.material_override = ghost_material

	ghost_cube_mesh = BoxMesh.new()
	ghost_cube_mesh.size = grid_map.cell_size if grid_map else Vector3.ONE * 1.5

	get_tree().current_scene.add_child.call_deferred(ghost_area)

## Hover preview: one cell for the selected block, or nothing for placeables.
## During a drag the area preview is owned by _update_build_drag.
func _update_ghost_block() -> void:
	if _area_active:
		return

	if not grid_map:
		_get_grid_map()
		if not grid_map:
			_hide_ghost_block()
			return

	if _selected_placeable_scene or build_items.is_empty() or grid_map.mesh_library == null:
		_hide_ghost_block()
		return

	var hit := _get_build_hit()
	if hit.is_empty():
		_hide_ghost_block()
		return

	var cell: Vector3i = grid_map.get_place_cell(hit.position, hit.normal)

	# Already occupied: the click would do nothing, so show no preview.
	if grid_map.has_block(cell):
		_hide_ghost_block()
		return

	var one: Array[Vector3i] = [cell]

	if _cell_overlaps_player(cell):
		_show_area_preview(one, true) # red = the placement is blocked
		return

	_show_area_preview(one, false)

func _hide_ghost_block() -> void:
	if ghost_area:
		ghost_area.visible = false
	_preview_cells.clear()
	_preview_destroying = false
	_preview_item = -1
	_preview_orientation = -1


## Starts a drag selection. The anchor cell is fixed here; the far corner
## follows the cursor until the button is released.
func _start_build_hold(placing: bool) -> void:
	if _area_active:
		return

	if placing:
		_place_held = true
	else:
		_break_held = true

	_begin_area(not placing)

func _begin_area(destroying: bool) -> void:
	if not grid_map:
		_get_grid_map()
		if not grid_map:
			return

	if not destroying and build_items.is_empty():
		return

	var hit := _get_build_hit()
	if hit.is_empty():
		return

	var hit_cell: Vector3i = grid_map.get_hit_cell(hit.position, hit.normal)

	if destroying:
		var placeable := _find_placeable_ancestor(hit.collider)
		if placeable:
			placeable.queue_free()
			_play_sfx(_sfx_land, 1.2, 1.4)
			return

		# Only carve the grid itself. A ray that stops on an NPC or another
		# body must not delete blocks behind it.
		if hit.collider != grid_map:
			return

		_area_anchor = hit_cell
	else:
		if _selected_placeable_scene:
			_place_placeable(hit)
			return

		_area_anchor = grid_map.get_place_cell(hit.position, hit.normal)

	_area_destroying = destroying
	_area_active = true
	_area_target = _area_anchor

	# The first cell is one corner. The axis toggle chooses a floor or a wall;
	# the cursor then selects the opposite corner on that plane.
	_area_plane_point = _cell_preview_origin(_area_anchor)
	_area_plane_axis = _current_plane_axis()
	_area_plane_normal = _plane_normal_for_axis(_area_plane_axis)

	# Start as a single-cell click. The drag only unlocks after a deliberate
	# hold, so a normal click cannot accidentally place a whole line.
	_hold_time = 0.0
	_drag_unlocked = false
	_area_target = _area_anchor
	_area_cells = _collect_area_cells(_area_anchor, _area_anchor, _area_destroying)
	_preview_item = -1
	_show_area_preview(_area_cells, _area_destroying)

## Grows/shrinks the selection after the press has been held long enough.
func _update_build_drag(delta: float) -> void:
	if not _area_active:
		return

	if not _drag_unlocked:
		_hold_time += delta
		if _hold_time < build_hold_delay:
			return
		_drag_unlocked = true

	_refresh_area_target()

func _refresh_area_target(force: bool = false) -> void:
	if not _area_active or not grid_map:
		return

	# The far corner comes from the drag plane, not from a surface hit, so the
	# selection can continue over empty space.
	var projected: Variant = _ray_plane_point(
		_area_plane_point,
		_area_plane_normal
	)

	if projected == null:
		return

	var cell: Vector3i = _cell_from_plane_point(
		projected,
		_area_plane_axis
	)
	cell = _clamp_area_target(_area_anchor, cell)

	if not force and cell == _area_target:
		return

	_area_target = cell
	_area_cells = _collect_area_cells(_area_anchor, cell, _area_destroying)
	_show_area_preview(_area_cells, _area_destroying)

## Null when the view is parallel to the plane or the plane is behind.
func _ray_plane_point(plane_point: Vector3, plane_normal: Vector3) -> Variant:
	var from: Vector3 = _camera.global_position
	var direction: Vector3 = -_camera.global_transform.basis.z
	var denominator: float = direction.dot(plane_normal)

	if absf(denominator) < 0.0001:
		return null

	var distance: float = (
		(plane_point - from).dot(plane_normal) / denominator
	)

	if distance <= 0.0:
		return null

	return from + direction * minf(distance, 10000.0)

## Cell under a point on the drag plane. `pin_axis` is the axis perpendicular
## to the plane; it stays on the anchor so the selection never leaves its layer.
func _cell_from_plane_point(world_point: Vector3, pin_axis: int) -> Vector3i:
	var local_point: Vector3 = grid_map.to_local(world_point)

	# Nudge exactly-on-boundary points 1 mm toward the anchor cell so a
	# cursor sitting on a cell edge does not silently grow the selection.
	var anchor_center: Vector3 = grid_map.to_local(
		_cell_preview_origin(_area_anchor)
	)
	local_point = local_point.move_toward(anchor_center, 0.001)
	var cell: Vector3i = grid_map.local_to_map(local_point)

	match pin_axis:
		0:
			cell.x = _area_anchor.x
		1:
			cell.y = _area_anchor.y
		2:
			cell.z = _area_anchor.z

	return cell

func _toggle_build_plane() -> void:
	build_plane = (
		BuildPlane.WALL
		if build_plane == BuildPlane.FLOOR
		else BuildPlane.FLOOR
	)

	# If a drag is already in progress, keep its anchor and re-project it onto
	# the newly selected plane.
	if _area_active:
		_area_plane_point = _cell_preview_origin(_area_anchor)
		_area_plane_axis = _current_plane_axis()
		_area_plane_normal = _plane_normal_for_axis(_area_plane_axis)
		_refresh_area_target(true)


func _current_plane_axis() -> int:
	if build_plane == BuildPlane.FLOOR:
		return 1

	# A wall faces the camera. Pick the dominant horizontal view axis so the
	# wall can be oriented along either world direction.
	var forward: Vector3 = -_camera.global_transform.basis.z
	var local_forward: Vector3 = (
		grid_map.global_transform.basis.inverse() * forward
	)

	if absf(local_forward.x) >= absf(local_forward.z):
		return 0

	return 2


func _plane_normal_for_axis(axis: int) -> Vector3:
	var local_normal := Vector3.ZERO
	local_normal[axis] = 1.0
	return (grid_map.global_transform.basis * local_normal).normalized()

func _finish_area() -> void:
	if not _area_active:
		return

	# Only refresh to the release position if the drag actually unlocked.
	# A quick click stays exactly on its one-cell anchor.
	if _drag_unlocked:
		_refresh_area_target(true)

	_area_active = false
	_drag_unlocked = false
	_hold_time = 0.0

	var cells: Array[Vector3i] = []
	cells.append_array(_area_cells)
	_area_cells.clear()
	_hide_ghost_block()

	if cells.is_empty():
		return

	if _area_destroying:
		grid_map.remove_blocks(cells)
	else:
		var item: int = build_items[build_index]
		grid_map.place_blocks(cells, item, _placement_orientation(item))

func _cancel_build_drag() -> void:
	_place_held = false
	_break_held = false
	_area_active = false
	_area_destroying = false
	_hold_time = 0.0
	_drag_unlocked = false
	_area_cells.clear()
	_hide_ghost_block()

## Keeps a huge drag from turning into an unbounded plane. The far corner is
## scaled toward the anchor uniformly, found with a small binary search so a
## near-parallel view cannot produce a millions-of-cells loop.
func _clamp_area_target(anchor: Vector3i, target: Vector3i) -> Vector3i:
	var delta: Vector3i = target - anchor
	var limit: int = maxi(max_build_area_volume, 1)

	# Cap each axis before multiplying, so a far projection cannot overflow
	# the volume calculation.
	var extents := Vector3i(
		mini(absi(delta.x) + 1, limit),
		mini(absi(delta.y) + 1, limit),
		mini(absi(delta.z) + 1, limit)
	)

	if extents.x * extents.y * extents.z > limit:
		var low: float = 0.0
		var high: float = 1.0

		for step in 24:
			var mid: float = (low + high) * 0.5
			var volume: int = (
				maxi(1, floori(extents.x * mid))
				* maxi(1, floori(extents.y * mid))
				* maxi(1, floori(extents.z * mid))
			)

			if volume <= limit:
				low = mid
			else:
				high = mid

		extents = Vector3i(
			maxi(1, floori(extents.x * low)),
			maxi(1, floori(extents.y * low)),
			maxi(1, floori(extents.z * low))
		)

	var direction := Vector3i(
		clampi(delta.x, -1, 1),
		clampi(delta.y, -1, 1),
		clampi(delta.z, -1, 1)
	)

	return anchor + Vector3i(
		direction.x * (extents.x - 1),
		direction.y * (extents.y - 1),
		direction.z * (extents.z - 1)
	)

## Collects the flat rectangle between the two corners. Only the two axes of
## the drag plane vary; the axis perpendicular to it stays on the anchor.
func _collect_area_cells(
	anchor: Vector3i,
	target: Vector3i,
	destroying: bool
) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var axes: Array[int] = []

	for axis in 3:
		if axis != _area_plane_axis:
			axes.append(axis)

	var low_a: int = mini(anchor[axes[0]], target[axes[0]])
	var high_a: int = maxi(anchor[axes[0]], target[axes[0]])
	var low_b: int = mini(anchor[axes[1]], target[axes[1]])
	var high_b: int = maxi(anchor[axes[1]], target[axes[1]])

	for a in range(low_a, high_a + 1):
		for b in range(low_b, high_b + 1):
			var cell: Vector3i = anchor
			cell[axes[0]] = a
			cell[axes[1]] = b
			cell[_area_plane_axis] = anchor[_area_plane_axis]

			if destroying:
				if grid_map.has_block(cell):
					cells.append(cell)
			elif not grid_map.has_block(cell) and not _cell_overlaps_player(cell):
				cells.append(cell)

	return cells

func _show_area_preview(cells: Array[Vector3i], destroying: bool) -> void:
	if ghost_area == null:
		return

	if cells.is_empty():
		_hide_ghost_block()
		return

	var item: int = -1
	if not destroying and not build_items.is_empty():
		item = build_items[build_index]

	var orientation: int = 0
	if not destroying and item != -1:
		orientation = _placement_orientation(item)

	if (
		cells == _preview_cells
		and destroying == _preview_destroying
		and item == _preview_item
		and orientation == _preview_orientation
	):
		ghost_area.visible = true
		return

	_preview_cells.clear()
	_preview_cells.append_array(cells)
	_preview_destroying = destroying
	_preview_item = item
	_preview_orientation = orientation

	var mesh: Mesh = ghost_cube_mesh
	var mesh_transform := Transform3D.IDENTITY

	if not destroying and grid_map and grid_map.mesh_library and item != -1:
		var item_mesh: Mesh = grid_map.mesh_library.get_item_mesh(item)
		if item_mesh:
			mesh = item_mesh
			mesh_transform = grid_map.mesh_library.get_item_mesh_transform(item)

	var placement_basis := Basis.IDENTITY
	if grid_map != null and orientation != 0:
		placement_basis = grid_map.get_orientation_basis(orientation)

	var mesh_basis: Basis = placement_basis * mesh_transform.basis
	var mesh_origin: Vector3 = placement_basis * mesh_transform.origin

	ghost_multimesh.mesh = mesh
	ghost_multimesh.instance_count = cells.size()

	for index in cells.size():
		var origin: Vector3 = (
			_cell_preview_origin(cells[index]) + mesh_origin
		)
		ghost_multimesh.set_instance_transform(
			index,
			Transform3D(mesh_basis, origin)
		)

	ghost_material.albedo_color = (
		DESTROY_PREVIEW_COLOR if destroying else PLACE_PREVIEW_COLOR
	)
	ghost_area.visible = true

## The orientation used when the current item is placed. Non-stair blocks use
## orientation 0; stairs face toward the player automatically.
func _placement_orientation(item: int) -> int:
	if not auto_stairs or grid_map == null or grid_map.mesh_library == null:
		return 0

	var item_name: String = grid_map.mesh_library.get_item_name(item).to_lower()
	if not "stair" in item_name:
		return 0

	return grid_map.get_stair_orientation(
		_stair_facing_direction(),
		stair_front_axis
	)


func _stair_facing_direction() -> Vector3i:
	var look: Vector3 = -_camera.global_transform.basis.z
	look.y = 0.0

	if look.length_squared() < 0.0001:
		return Vector3i.FORWARD

	# Stairs face toward the player, like Minecraft stairs.
	var facing: Vector3 = -look.normalized()

	if absf(facing.x) >= absf(facing.z):
		return Vector3i(1 if facing.x >= 0.0 else -1, 0, 0)

	return Vector3i(0, 0, 1 if facing.z >= 0.0 else -1)


## World-space centre of a cell, including GridMap cell-centre handling.
func _cell_preview_origin(cell: Vector3i) -> Vector3:
	var position: Vector3 = grid_map.to_global(grid_map.map_to_local(cell))
	var size: Vector3 = grid_map.cell_size

	if not grid_map.cell_center_x:
		position.x += size.x * 0.5
	if not grid_map.cell_center_y:
		position.y += size.y * 0.5
	if not grid_map.cell_center_z:
		position.z += size.z * 0.5

	return position

func _find_placeable_ancestor(collider: Object) -> Node:
	var node: Node = collider as Node

	while node != null and node != get_tree().root:
		if node.is_in_group("placeables"):
			return node
		node = node.get_parent()

	return null

func _toggle_build_mode() -> void:
	build_mode_active = !build_mode_active

	if build_mode_active:
		_get_grid_map()
	else:
		inventory_open = false
		_cancel_build_drag()

	_update_build_ui()

func _toggle_inventory() -> void:
	if not build_mode_active: return

	inventory_open = !inventory_open
	if inventory_open:
		_cancel_build_drag()
		_get_grid_map()

	_update_build_ui()

func _update_build_ui() -> void:
	if not hud_manager: return

	var item_name = ""
	if _selected_placeable_scene:
		item_name = _selected_placeable_scene.resource_path.get_file().get_basename().capitalize()
	elif grid_map and grid_map.mesh_library and not build_items.is_empty():
		var current_item_id = build_items[build_index]
		item_name = grid_map.mesh_library.get_item_name(current_item_id)

	hud_manager.update_build_ui(build_mode_active, inventory_open, item_name)

func _cycle_build_item(step: int) -> void:
	_get_grid_map()
	if build_items.is_empty():
		return
	build_index = posmod(build_index + step, build_items.size())
	_preview_item = -1

	if _area_active:
		_refresh_area_target(true)

	_update_build_ui()

func _on_inventory_item_selected(id: int) -> void:
	_selected_placeable_scene = null # picking a block exits placeable mode
	var found_index = build_items.find(id)
	if found_index != -1:
		build_index = found_index
		_update_build_ui()

func _on_placeable_selected(scene: PackedScene) -> void:
	_selected_placeable_scene = scene
	_update_build_ui()

func _get_build_hit() -> Dictionary:
	var from: Vector3 = _camera.global_position
	var to: Vector3 = from - _camera.global_transform.basis.z * build_reach
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	
	# CRITICAL: Allow the raycast to detect Area3D nodes
	query.collide_with_areas = true
	query.collide_with_bodies = true

	var hit: Dictionary = _camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	return hit

func _place_placeable(hit: Dictionary) -> void:
	if not hud_manager or not _selected_placeable_scene:
		return

	var instance: Node = _selected_placeable_scene.instantiate()
	var overrides: Dictionary = hud_manager.get_placeable_overrides()
	for key in overrides:
		if key in instance:
			instance.set(key, overrides[key])

	get_tree().current_scene.add_child(instance)
	if instance is Node3D:
		instance.global_position = hit.position

	instance.add_to_group("placeables")

func _play_sfx(
	stream_node: AudioStreamPlayer3D,
	pitch_min: float = 0.85,
	pitch_max: float = 1.15
) -> void:
	if stream_node:
		stream_node.pitch_scale = randf_range(pitch_min, pitch_max)
		stream_node.play()

func _cell_overlaps_player(cell: Vector3i) -> bool:
	var size: Vector3 = grid_map.cell_size
	var center: Vector3 = grid_map.to_global(grid_map.map_to_local(cell))
	var cell_box := AABB(center - size * 0.5, size)

	var r: float = _collision_shape.shape.radius
	var h: float = _collision_shape.shape.height
	var player_box := AABB(
		_collision_shape.global_position - Vector3(r, h * 0.5, r),
		Vector3(r * 2.0, h, r * 2.0)
	).grow(0.05)

	return cell_box.intersects(player_box)
