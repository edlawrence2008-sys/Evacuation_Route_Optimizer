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
## Direction the stair mesh's low/front side points in its unrotated state.
## The generated stair collider puts the low half-step at +Z (see
## block_uv_mapper.gd), so that is the front axis.
@export var stair_front_axis: Vector3 = Vector3.BACK

@export_group("Placeables")
## Extra X/Z offset applied after a placeable is snapped to the voxel grid.
@export var placeable_xz_offset: Vector2 = Vector2.ZERO
## Give each placed foliage scene a random Y rotation.
@export var randomize_foliage_yaw: bool = true

@export_group("Scene Paths")
@export var camera_path: NodePath = NodePath("../head/CameraSmooth/Camera3D")
@export var collision_shape_path: NodePath = NodePath("../CollisionShape3D")
@export var hud_path: NodePath = NodePath("../HUD/HUD")

var player: CharacterBody3D = null
var hud_manager: HUDManager = null

var grid_map: NavGridMap
var build_items: PackedInt32Array = PackedInt32Array()
var inventory_open: bool = false
var build_mode_active: bool = true

enum BuildPlane { FLOOR, WALL }
## Toggled by the `switch_axis` action. Floors are the default.
var build_plane: BuildPlane = BuildPlane.FLOOR

var _camera: Camera3D = null
var _collision_shape: CollisionShape3D = null
var _sfx_land: AudioStreamPlayer3D = null
var _sfx_build_loop: AudioStreamPlayer3D = null
var _sfx_build_increment: AudioStreamPlayer3D = null
var _sfx_build_cancel: AudioStreamPlayer3D = null
var _sfx_build_rotate: AudioStreamPlayer3D = null
var _sfx_build_increment_voices: Array[AudioStreamPlayer3D] = []
var _increment_voice_busy_until: Array[int] = []
var _build_loop_base_volume_db: float = -12.0
var _build_loop_tween: Tween = null
var _build_loop_stopping: bool = false
const BUILD_LOOP_FADE_IN := 0.12
const BUILD_LOOP_FADE_OUT := 0.18
const BUILD_LOOP_SILENT_DB := -60.0
const BUILD_INCREMENT_MAX_VOICES := 16
var _hand: Node = null
var _setup_done: bool = false
var _selected_placeable_scene: PackedScene = null
## A placeable scene can be a held tool (flare gun, extinguisher, throwable)
## instead of a placeable object when it owns a UseComponent.
var _held_use_component: UseComponent = null
var _held_use_scene: PackedScene = null

var _place_held: bool = false
var _break_held: bool = false
var _hold_time: float = 0.0
var _drag_unlocked: bool = false
var _area_last_size: Vector3i = Vector3i.ZERO
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
## Quarter-turns applied on top of the automatic orientation by `ui_rotate`.
var _manual_rotation: int = 0

var _face_indicator: MeshInstance3D = null

## Ghost visual for the selected placeable. It is a scripts-free copy of the
## scene's mesh/sprite nodes, tinted translucent and red when the placement is
## invalid (e.g. unsupported foliage).
var _placeable_ghost: Node3D = null
var _placeable_ghost_scene: PackedScene = null
var _placeable_ghost_offset: Vector2 = Vector2.ZERO
var _placeable_ghost_requires_support: bool = false
var _placeable_ghost_blocked: bool = false
var _placeable_ghost_is_foliage: bool = false
var _placeable_ghost_yaw: float = 0.0
var _placeable_ghost_base_basis: Basis = Basis.IDENTITY
var _placeable_ghost_blocked_material: StandardMaterial3D = null
var _face_material: StandardMaterial3D = null
var _face_key: String = ""
## Latest face under the crosshair: axis, cell, tangent_u/v, u/v and zone.
## Cleared when the indicator hides, so placement never uses a stale face.
var _last_face_info: Dictionary = {}
## Face snapshot taken when a drag starts, used as a fallback if the release
## ray leaves the grid.
var _area_face_info: Dictionary = {}
## Placement resolved on the initial press. The whole drag reuses this item,
## variant and orientation, so a slab/stair cannot rotate or flip while the
## selection grows.
var _area_source_item: int = -1
var _area_resolved_item: int = -1
var _area_resolved_orientation: int = 0
## Placeable area drag: one scene is stored for the whole stroke, along with
## the anchor hit (surface height + normal) used to position every copy.
var _area_placeable_scene: PackedScene = null
var _area_placeable_hit: Dictionary = {}
## Palette active for the current stroke, plus the anchor hit used to place
## random placeable members on the same surface.
var _area_palette_id: String = ""
var _area_anchor_hit: Dictionary = {}
## Random block currently shown/used for a palette hotbar slot.
var _palette_preview_item: int = -1
## Item name -> MeshLibrary id, rebuilt when the grid/library is resolved.
var _library_name_to_id: Dictionary = {}

## Face-indicator zones. The ids are used both by the mesh (which draws one quad
## per id) and by `_face_zone_for_uv()`, so the highlighted quad can never drift
## out of sync with the region under the crosshair.
const FACE_ZONE_CENTER := 0
const FACE_ZONE_RIGHT := 1
const FACE_ZONE_LEFT := 2
const FACE_ZONE_TOP := 3
const FACE_ZONE_BOTTOM := 4
const FACE_ZONE_INNER: float = 0.42

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
	_sfx_build_loop = _find_build_sfx(
		["build_hold_loop", "BuildHoldLoop"],
		"res://sounds/entities/player/build_hold_loop.wav",
		-12.0
	)
	_sfx_build_increment = _find_build_sfx(
		["build_hold_increment", "BuildHoldIncrement"],
		"res://sounds/entities/player/build_hold_increment.mp3",
		-6.0
	)
	_sfx_build_cancel = _find_build_sfx(
		["build_hold_cancel", "BuildHoldCancel"],
		"res://sounds/entities/player/build_hold_cancel.mp3",
		-8.0
	)
	_sfx_build_rotate = _find_build_sfx(
		["build_rotate", "BuildRotate"],
		"res://sounds/entities/player/build_rotate.mp3",
		-8.0
	)
	_build_loop_base_volume_db = (
		_sfx_build_loop.volume_db if _sfx_build_loop != null else -12.0
	)
	if _sfx_build_increment != null:
		_sfx_build_increment_voices = [_sfx_build_increment]
		_increment_voice_busy_until = [0]
	# The player is still setting up its children in _ready, so adding the
	# extra increment voices has to wait one deferred call.
	_setup_build_increment_voices.call_deferred()
	_hand = player.get_node_or_null(
		"head/CameraSmooth/Camera3D/hands"
	)

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
		hud_manager.hotbar_slot_selected.connect(_on_hotbar_slot_selected)

	_get_grid_map()
	_init_ghost_block()
	_update_build_ui()


func _input(event: InputEvent) -> void:
	if not _setup_done or player == null or player.is_dead:
		return

	# Keys typed into the console or an inventory text field must never trigger
	# build shortcuts (Shift+R opening/closing the inventory, B leaving build
	# mode, / switching planes, 1-9 changing slots).
	if _is_typing():
		return

	if not inventory_open and event.is_action_pressed("interact"):
		_try_interact()
		return

	if not inventory_open and event.is_action_pressed("pick_block"):
		_pick_aimed()
		return

	if _held_use_component != null and not inventory_open:
		if event.is_action_pressed("primary_use"):
			_use_held_tool(false)
			return
		if event.is_action_pressed("secondary_use"):
			_use_held_tool(true)
			return

	if event.is_action_pressed("toggle_build_mode"):
		_toggle_build_mode()
		return

	if event.is_action_pressed("switch_axis"):
		_toggle_build_plane()
		return

	if build_mode_active and event.is_action_pressed("ui_rotate"):
		_rotate_placement()
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
		else:
			for slot in Hotbar.SLOT_COUNT:
				if event.is_action_pressed("hotbar_%d" % (slot + 1)):
					_select_hotbar_slot(slot)
					return


## True while the console is open or a text-entry control has keyboard focus,
## so build shortcuts do not steal keys from typing.
func _is_typing() -> bool:
	if hud_manager:
		var console := hud_manager.get_node_or_null("Console")
		if console and console.visible:
			return true

	var focus := get_viewport().gui_get_focus_owner()
	if focus == null or not focus.is_visible_in_tree():
		return false

	return focus is LineEdit or focus is TextEdit


func _process(_delta: float) -> void:
	if not _setup_done or player == null:
		return

	if player.is_dead:
		_cancel_build_drag()
		_hide_placeable_ghost()
		_hide_ghost_block()
		return

	if build_mode_active and not inventory_open:
		# Resolve the aimed face/zone first: the ghost preview picks the slab
		# variant and orientation from this same face data.
		_update_face_indicator()
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
		_hide_placeable_ghost()
		_hide_face_indicator()
		_cancel_build_drag()

	if not player.movement_enabled:
		_cancel_build_drag()


func _exit_tree() -> void:
	if _build_loop_tween != null and _build_loop_tween.is_valid():
		_build_loop_tween.kill()
	if _sfx_build_loop != null:
		_sfx_build_loop.stop()
	if is_instance_valid(ghost_area):
		ghost_area.queue_free()
	if is_instance_valid(_face_indicator):
		_face_indicator.queue_free()
	_clear_placeable_ghost()
# --- Building & UI Integration ---
func _get_grid_map() -> NavGridMap:
	if not is_instance_valid(grid_map):
		grid_map = get_tree().get_first_node_in_group("grid_map") as NavGridMap
		if grid_map and grid_map.mesh_library:
			build_items = grid_map.mesh_library.get_item_list()
			_build_library_index()
			if hud_manager:
				hud_manager.setup_inventory(build_items, grid_map.mesh_library)
			_update_build_ui()
	return grid_map


## Cache item names by id so slab variants can be found by name at placement
## time without scanning the library every frame.
func _build_library_index() -> void:
	_library_name_to_id.clear()
	if grid_map == null or grid_map.mesh_library == null:
		return

	for id: int in grid_map.mesh_library.get_item_list():
		_library_name_to_id[
			String(grid_map.mesh_library.get_item_name(id))
		] = id

func _init_ghost_block() -> void:
	ghost_area = MultiMeshInstance3D.new()
	ghost_area.name = "PlacementGhost"
	ghost_area.top_level = true
	ghost_area.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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

	_face_material = StandardMaterial3D.new()
	_face_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_face_material.vertex_color_use_as_albedo = true
	_face_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_face_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_face_indicator = MeshInstance3D.new()
	_face_indicator.name = "FaceIndicator"
	_face_indicator.top_level = true
	_face_indicator.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_face_indicator.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	_face_indicator.material_override = _face_material
	_face_indicator.visible = false
	get_tree().current_scene.add_child.call_deferred(_face_indicator)

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

	if _selected_placeable_scene:
		_hide_ghost_block()

		if _held_use_component != null:
			_hide_placeable_ghost()
			return

		var placeable_hit := _get_build_hit()
		if placeable_hit.is_empty():
			_hide_placeable_ghost()
			return

		_update_placeable_ghost(placeable_hit)
		return

	_hide_placeable_ghost()

	var preview_item := _current_build_item()
	var palette_active := not _active_palette_id().is_empty()
	if (preview_item == -1 and not palette_active) or grid_map.mesh_library == null:
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


## Builds the translucent placeable ghost once per selected scene. Only
## MeshInstance3D/Sprite3D nodes are copied, so no scene script ever runs.
func _ensure_placeable_ghost(scene: PackedScene) -> void:
	if _placeable_ghost_scene == scene and is_instance_valid(_placeable_ghost):
		return

	_clear_placeable_ghost()
	_placeable_ghost_scene = scene

	if scene == null:
		return

	var temp := scene.instantiate()
	_placeable_ghost_offset = _scene_grid_offset(temp)
	_placeable_ghost_requires_support = _placeable_requires_support(temp)
	_placeable_ghost_is_foliage = temp.is_in_group("foliage")
	_placeable_ghost_yaw = 0.0
	_placeable_ghost_base_basis = Basis.IDENTITY

	if _placeable_ghost_is_foliage and randomize_foliage_yaw:
		_placeable_ghost_yaw = randf() * TAU

	var holder := Node3D.new()
	holder.name = "PlaceableGhost"
	holder.top_level = true
	holder.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if temp is Node3D:
		var temp_3d := temp as Node3D
		_placeable_ghost_base_basis = temp_3d.transform.basis
		holder.transform = Transform3D(_placeable_ghost_base_basis, Vector3.ZERO)

	_copy_ghost_visuals(temp, holder, Transform3D.IDENTITY)
	temp.free()

	if _placeable_ghost_blocked_material == null:
		_placeable_ghost_blocked_material = StandardMaterial3D.new()
		_placeable_ghost_blocked_material.transparency = (
			BaseMaterial3D.TRANSPARENCY_ALPHA
		)
		_placeable_ghost_blocked_material.shading_mode = (
			BaseMaterial3D.SHADING_MODE_UNSHADED
		)
		_placeable_ghost_blocked_material.cull_mode = (
			BaseMaterial3D.CULL_DISABLED
		)
		_placeable_ghost_blocked_material.albedo_color = Color(
			1.0, 0.18, 0.12, 0.55
		)

	_placeable_ghost = holder
	_placeable_ghost_blocked = false
	get_tree().current_scene.add_child(holder)
	holder.visible = false


func _copy_ghost_visuals(
	source: Node,
	target: Node3D,
	parent_xform: Transform3D
) -> void:
	for child in source.get_children():
		var child_xform: Transform3D = parent_xform

		if child is Node3D:
			child_xform = parent_xform * (child as Node3D).transform

		if child is MeshInstance3D:
			var source_mesh := child as MeshInstance3D
			if source_mesh.mesh != null:
				var mesh_copy := MeshInstance3D.new()
				mesh_copy.mesh = source_mesh.mesh
				mesh_copy.transform = child_xform
				mesh_copy.material_override = source_mesh.material_override
				mesh_copy.transparency = 0.55
				mesh_copy.cast_shadow = (
					GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				)
				target.add_child(mesh_copy)
		elif child is Sprite3D:
			var source_sprite := child as Sprite3D
			var sprite_copy := Sprite3D.new()
			sprite_copy.texture = source_sprite.texture
			sprite_copy.pixel_size = source_sprite.pixel_size
			sprite_copy.billboard = source_sprite.billboard
			sprite_copy.shaded = false
			sprite_copy.double_sided = source_sprite.double_sided
			sprite_copy.alpha_cut = source_sprite.alpha_cut
			sprite_copy.texture_filter = source_sprite.texture_filter
			sprite_copy.transform = child_xform
			sprite_copy.transparency = 0.55
			sprite_copy.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
			target.add_child(sprite_copy)

		_copy_ghost_visuals(child, target, child_xform)


func _update_placeable_ghost(hit: Dictionary) -> void:
	_ensure_placeable_ghost(_selected_placeable_scene)

	if _placeable_ghost == null:
		return

	_placeable_ghost.global_position = _placeable_grid_position(
		_placeable_ghost_offset,
		hit
	)
	var ghost_spin := _manual_rotation * PI * 0.5
	if _placeable_ghost_is_foliage:
		ghost_spin += _placeable_ghost_yaw
	_placeable_ghost.basis = (
		Basis(Vector3.UP, ghost_spin) * _placeable_ghost_base_basis
	)
	_placeable_ghost.visible = true

	var supported := (
		not _placeable_ghost_requires_support
		or _placeable_has_voxel_support(hit)
	)
	var blocked := not supported
	if blocked != _placeable_ghost_blocked:
		_placeable_ghost_blocked = blocked
		_set_ghost_blocked(_placeable_ghost, blocked)


func _set_ghost_blocked(node: Node, blocked: bool) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).material_overlay = (
				_placeable_ghost_blocked_material if blocked else null
			)
		_set_ghost_blocked(child, blocked)


func _hide_placeable_ghost() -> void:
	if _placeable_ghost != null and is_instance_valid(_placeable_ghost):
		_placeable_ghost.visible = false


func _clear_placeable_ghost() -> void:
	if _placeable_ghost != null and is_instance_valid(_placeable_ghost):
		# Do not remove/free the ghost synchronously: _exit_tree can run while
		# the scene tree is already removing children, and remove_child() then
		# errors with "Parent node is busy adding/removing children". Hiding and
		# queueing the node keeps normal ghost swaps visually clean and lets the
		# tree remove it at a safe point during shutdown.
		_placeable_ghost.visible = false
		_placeable_ghost.queue_free()
	_placeable_ghost = null
	_placeable_ghost_scene = null


## Foliage must sit on a voxel top face; other placeables opt in with
## `requires_voxel_below`.
func _placeable_requires_support(instance: Node) -> bool:
	if instance == null:
		return false
	if instance.is_in_group("foliage"):
		return true
	if "requires_voxel_below" in instance:
		return bool(instance.get("requires_voxel_below"))
	return false


func _placeable_has_voxel_support(hit: Dictionary) -> bool:
	if grid_map == null:
		return false

	var normal: Vector3 = hit.get("normal", Vector3.DOWN)
	if normal.y <= 0.5:
		return false
	if hit.get("collider") != grid_map:
		return false

	var support_cell: Vector3i = grid_map.get_hit_cell(
		hit.get("position", Vector3.ZERO),
		normal
	)
	return grid_map.get_cell_item(support_cell) != GridMap.INVALID_CELL_ITEM


func _scene_grid_offset(instance: Node) -> Vector2:
	if instance != null and "grid_xz_offset" in instance:
		var value: Variant = instance.get("grid_xz_offset")
		if value is Vector2:
			return value
	return Vector2.ZERO


## Five-part overlay on the block face under the crosshair: an inset centre
## square plus one trapezoid per face edge. The region under the crosshair is
## highlighted. The axes are fixed per face (not camera-relative), so the
## overlay stays static on the voxel while its zones still read correctly from
## the face's outside.
func _update_face_indicator() -> void:
	if _face_indicator == null:
		return

	if not grid_map:
		_get_grid_map()
		if not grid_map:
			_hide_face_indicator()
			return

	var hit := _get_build_hit()
	if hit.is_empty() or hit.collider != grid_map:
		_hide_face_indicator()
		return

	var axis: Vector3 = hit.normal
	if absf(axis.x) > 0.5:
		axis = Vector3(signf(axis.x), 0.0, 0.0)
	elif absf(axis.y) > 0.5:
		axis = Vector3(0.0, signf(axis.y), 0.0)
	elif absf(axis.z) > 0.5:
		axis = Vector3(0.0, 0.0, signf(axis.z))
	else:
		_hide_face_indicator()
		return

	var cell: Vector3i = grid_map.get_hit_cell(hit.position, axis)
	var size: Vector3 = grid_map.cell_size
	var center: Vector3 = _cell_preview_origin(cell)
	var face_center: Vector3 = center + axis * (
		absf(size.dot(axis)) * 0.5 + 0.004
	)

	# Static face-local axes. For vertical faces the local "right" is the
	# direction that appears right when looking at that face from outside;
	# horizontal faces use a fixed world tangent so they never spin with the
	# camera.
	var tangent_u: Vector3

	if absf(axis.y) > 0.5:
		tangent_u = Vector3.RIGHT
	else:
		tangent_u = Vector3.UP.cross(axis).normalized()

	var tangent_v: Vector3 = axis.cross(tangent_u).normalized()

	var half_u: float = absf(size.dot(tangent_u)) * 0.5
	var half_v: float = absf(size.dot(tangent_v)) * 0.5

	var offset: Vector3 = hit.position - face_center
	var u: float = clampf(
		offset.dot(tangent_u) / maxf(half_u, 0.0001),
		-1.0,
		1.0
	)
	var v: float = clampf(
		offset.dot(tangent_v) / maxf(half_v, 0.0001),
		-1.0,
		1.0
	)

	var zone: int = _face_zone_for_uv(u, v)

	_last_face_info = {
		"axis": axis,
		"cell": cell,
		"tangent_u": tangent_u,
		"tangent_v": tangent_v,
		"u": u,
		"v": v,
		"zone": zone,
	}

	var key := "%d:%d:%d|%d|%d" % [
		cell.x,
		cell.y,
		cell.z,
		int(axis.x + axis.y * 2.0 + axis.z * 3.0),
		zone,
	]

	if key != _face_key or _face_indicator.mesh == null:
		_face_key = key
		_build_face_mesh(zone)

	# The mesh is a unit face; this transform maps it onto the aimed face.
	_face_indicator.transform = Transform3D(
		Basis(
			tangent_u * half_u,
			tangent_v * half_v,
			axis
		),
		face_center
	)
	_face_indicator.visible = true


func _hide_face_indicator() -> void:
	_face_key = ""
	_last_face_info.clear()
	if _face_indicator != null:
		_face_indicator.visible = false


## Classifies a point on the aimed face into the same five zones the mesh draws.
## `u` grows along tangent_u (face-right) and `v` along tangent_v (face-up), both
## measured from the face centre in the range -1..1.
func _face_zone_for_uv(u: float, v: float) -> int:
	if absf(u) <= FACE_ZONE_INNER and absf(v) <= FACE_ZONE_INNER:
		return FACE_ZONE_CENTER

	if absf(u) >= absf(v):
		return FACE_ZONE_RIGHT if u > 0.0 else FACE_ZONE_LEFT

	return FACE_ZONE_TOP if v > 0.0 else FACE_ZONE_BOTTOM


## Unit-coordinate mesh for the current zone. The node transform maps local
## (x, y) onto the face's fixed axes. Quads are indexed by `FACE_ZONE_*`, which
## is the same classification `_face_zone_for_uv()` performs, so the highlighted
## quad always contains the crosshair.
func _build_face_mesh(zone: int) -> void:
	var inner: float = FACE_ZONE_INNER
	var base_color := Color(1.0, 1.0, 1.0, 0.14)
	var active_color := Color(0.35, 0.85, 1.0, 0.55)

	# Zone id -> quad in local face space. Keep these in the same order as the
	# FACE_ZONE_* constants: centre, right (+u), left (-u), top (+v), bottom (-v).
	var quads: Array = []
	quads.resize(5)
	quads[FACE_ZONE_CENTER] = [
		Vector2(-inner, -inner), Vector2(inner, -inner),
		Vector2(inner, inner), Vector2(-inner, inner),
	]
	quads[FACE_ZONE_RIGHT] = [
		Vector2(inner, -inner), Vector2(1.0, -1.0),
		Vector2(1.0, 1.0), Vector2(inner, inner),
	]
	quads[FACE_ZONE_LEFT] = [
		Vector2(-1.0, -1.0), Vector2(-inner, -inner),
		Vector2(-inner, inner), Vector2(-1.0, 1.0),
	]
	quads[FACE_ZONE_TOP] = [
		Vector2(-1.0, 1.0), Vector2(1.0, 1.0),
		Vector2(inner, inner), Vector2(-inner, inner),
	]
	quads[FACE_ZONE_BOTTOM] = [
		Vector2(-inner, -inner), Vector2(inner, -inner),
		Vector2(1.0, -1.0), Vector2(-1.0, -1.0),
	]

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	for index in quads.size():
		var color: Color = active_color if index == zone else base_color
		var points: Array = []

		for point in quads[index]:
			points.append(Vector3(point.x, point.y, 0.0))

		for vertex_index: int in [0, 1, 2, 0, 2, 3]:
			tool.set_color(color)
			tool.add_vertex(points[vertex_index])

	tool.generate_normals()
	_face_indicator.mesh = tool.commit()


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

	_area_source_item = -1
	_area_resolved_item = -1
	_area_resolved_orientation = 0
	_area_placeable_scene = null
	_area_placeable_hit = {}
	_area_palette_id = ""
	_area_anchor_hit = {}

	if not destroying:
		_reroll_palette_preview()

	var active_palette := _active_palette_id()
	if not destroying and not _selected_placeable_scene:
		if active_palette.is_empty():
			if _current_build_item() == -1:
				return
		elif hud_manager.get_palette_entries(active_palette).is_empty():
			return

	if not destroying and _held_use_component != null:
		return

	if _hand != null:
		_hand.call("play_place_swing" if not destroying else "play_break_swing")

	var hit := _get_build_hit()
	if hit.is_empty():
		return

	if not destroying:
		_area_palette_id = active_palette
		_area_anchor_hit = hit.duplicate()

	# Refresh the face/zone for this exact click before the preview resolves
	# the slab variant from it.
	_update_face_indicator()
	_area_face_info = _last_face_info.duplicate()

	var hit_cell: Vector3i = grid_map.get_hit_cell(hit.position, hit.normal)

	if destroying:
		# Start a removal area over either a block or a placeable. The area
		# completion removes grid blocks in the cells plus any placeables whose
		# centres fall inside the stretched footprint.
		var placeable := _find_placeable_ancestor(hit.collider)
		if placeable is Node3D:
			_area_anchor = grid_map.local_to_map(
				grid_map.to_local((placeable as Node3D).global_position)
			)
		elif hit.collider == grid_map:
			_area_anchor = hit_cell
		else:
			return
	else:
		if _selected_placeable_scene:
			_area_placeable_scene = _selected_placeable_scene
			_area_placeable_hit = hit.duplicate()
			_area_anchor = grid_map.get_place_cell(hit.position, hit.normal)
			_hide_placeable_ghost()
			if (
				_placeable_scene_requires_support(_area_placeable_scene)
				and not _placeable_has_voxel_support(hit)
			):
				_play_sfx(_sfx_build_cancel, 1.0, 1.0)
				_area_placeable_scene = null
				_area_placeable_hit = {}
				return
		else:
			_area_anchor = grid_map.get_place_cell(hit.position, hit.normal)

	_area_destroying = destroying
	_area_active = true
	_area_target = _area_anchor

	if _hand != null:
		_hand.call("set_shaking", true)

	# The first cell is one corner. The axis toggle chooses a floor or a wall;
	# the cursor then selects the opposite corner on that plane.
	_area_plane_point = _cell_preview_origin(_area_anchor)
	_area_plane_axis = _current_plane_axis()
	_area_plane_normal = _plane_normal_for_axis(_area_plane_axis)

	# Freeze the initial placement's variant and orientation for the whole
	# drag. Moving the cursor across faces or enlarging the area must not
	# rotate stairs/slabs or swap their downside.
	_area_source_item = -1
	_area_resolved_item = -1
	_area_resolved_orientation = 0
	if not destroying and _area_placeable_scene == null and _area_palette_id.is_empty():
		_area_source_item = _current_build_item()
		if _area_source_item != -1:
			var locked := _resolve_placement(
				_area_source_item,
				[_area_anchor]
			)
			_area_resolved_item = int(locked["item"])
			_area_resolved_orientation = int(locked["orientation"])

	# Start as a single-cell click. The drag only unlocks after a deliberate
	# hold, so a normal click cannot accidentally place a whole line.
	_hold_time = 0.0
	_drag_unlocked = false
	_area_target = _area_anchor
	_area_cells = _collect_area_cells(_area_anchor, _area_anchor, _area_destroying)
	_preview_item = -1
	_show_area_preview(_area_cells, _area_destroying)
	_area_last_size = _area_cells_size_key(_area_cells)

## Grows/shrinks the selection after the press has been held long enough.
func _update_build_drag(delta: float) -> void:
	if not _area_active:
		return

	if not _drag_unlocked:
		_hold_time += delta
		if _hold_time < build_hold_delay:
			return
		_drag_unlocked = true
		# A quick click never reaches this point, so the loop only plays
		# once the press has become a real hold/stretch.
		_start_build_loop()

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

	var size_key: Vector3i = _area_cells_size_key(_area_cells)
	if size_key != _area_last_size:
		var new_volume: int = _area_size_volume(size_key)
		var old_volume: int = _area_size_volume(_area_last_size)
		_area_last_size = size_key
		if new_volume >= old_volume:
			_play_build_increment(1.02, 1.10)
		else:
			# Shrinking the ghost drops the cue's pitch so it reads as
			# "taking blocks away" rather than adding them.
			_play_build_increment(0.82, 0.90)

	# Stronger vibration as the drag covers more blocks.
	if _hand != null:
		_hand.call("set_shaking", true, _area_cells.size())

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

	if hud_manager:
		hud_manager.show_build_notice(
			"Build Axis: %s"
			% ("Floor" if build_plane == BuildPlane.FLOOR else "Wall")
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
	_area_last_size = Vector3i.ZERO
	_stop_build_loop()

	if _hand != null:
		_hand.call("set_shaking", false)

	var cells: Array[Vector3i] = []
	cells.append_array(_area_cells)
	_area_cells.clear()
	_hide_ghost_block()

	var source_item := _area_source_item
	var resolved_item := _area_resolved_item
	var resolved_orientation := _area_resolved_orientation
	var area_placeable_scene := _area_placeable_scene
	var area_placeable_hit := _area_placeable_hit
	var area_palette_id := _area_palette_id
	var area_anchor_hit := _area_anchor_hit
	_area_source_item = -1
	_area_resolved_item = -1
	_area_resolved_orientation = 0
	_area_placeable_scene = null
	_area_placeable_hit = {}
	_area_palette_id = ""
	_area_anchor_hit = {}

	if cells.is_empty():
		return

	if _area_destroying:
		grid_map.remove_blocks(cells)
		_remove_placeables_in_cells(cells)
		_play_sfx(_sfx_land, 0.7, 0.9)
	elif area_placeable_scene != null:
		_spawn_placeables_in_cells(area_placeable_scene, cells, area_placeable_hit)
		_play_sfx(_sfx_land, 1.0, 1.2)
	elif not area_palette_id.is_empty():
		if _finish_palette_area(area_palette_id, cells, area_anchor_hit):
			_play_sfx(_sfx_land, 1.1, 1.3)
		_reroll_palette_preview()
	else:
		var selected: int = (
			source_item
			if source_item != -1
			else _current_build_item()
		)
		if selected == -1:
			return

		var water_kind := _water_kind_for_item(selected)
		if not water_kind.is_empty():
			var water := _get_water_system()
			if water != null:
				water.place(cells, water_kind)
				if not cells.is_empty():
					GlobalData.report_environment_change(
						grid_map.to_global(grid_map.map_to_local(cells[0])),
						"water_placed",
						{"cells": cells, "water_kind": water_kind}
					)
				_play_sfx(_sfx_land, 1.1, 1.3)
				_reroll_palette_preview()
				if _hand != null:
					_hand.call("play_impact")
			return

		grid_map.place_blocks(
			cells,
			resolved_item if resolved_item != -1 else selected,
			resolved_orientation
		)
		_play_sfx(_sfx_land, 1.1, 1.3)
		_reroll_palette_preview()

	if _hand != null:
		_hand.call("play_impact")

func _cancel_build_drag() -> void:
	var was_holding: bool = _area_active or _place_held or _break_held
	_stop_build_loop()
	_area_last_size = Vector3i.ZERO
	if was_holding:
		_play_sfx(_sfx_build_cancel, 0.97, 1.03)

	_place_held = false
	_break_held = false
	_area_active = false
	_area_destroying = false
	_hold_time = 0.0
	_drag_unlocked = false
	_area_cells.clear()
	_area_face_info.clear()
	_area_source_item = -1
	_area_resolved_item = -1
	_area_resolved_orientation = 0
	_area_placeable_scene = null
	_area_placeable_hit = {}
	_area_palette_id = ""
	_area_anchor_hit = {}
	_hide_ghost_block()

	if _hand != null:
		_hand.call("set_shaking", false)

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

			# Removal keeps the whole rectangle, including empty cells, so the
			# red preview can stretch past the last block/placeable. The finish
			# pass removes whatever is actually there.
			if destroying or (
				not grid_map.has_block(cell) and not _cell_overlaps_player(cell)
			):
				cells.append(cell)

	return cells

func _area_cells_size_key(cells: Array[Vector3i]) -> Vector3i:
	if cells.is_empty():
		return Vector3i.ZERO

	var min_cell: Vector3i = cells[0]
	var max_cell: Vector3i = cells[0]

	for cell: Vector3i in cells:
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		min_cell.z = mini(min_cell.z, cell.z)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
		max_cell.z = maxi(max_cell.z, cell.z)

	return max_cell - min_cell + Vector3i.ONE


func _area_size_volume(size: Vector3i) -> int:
	return maxi(size.x, 0) * maxi(size.y, 0) * maxi(size.z, 0)


func _show_area_preview(cells: Array[Vector3i], destroying: bool) -> void:
	if ghost_area == null:
		return

	if cells.is_empty():
		_hide_ghost_block()
		return

	var item: int = -1
	var orientation: int = 0
	if not destroying:
		if _area_source_item != -1 and _area_resolved_item != -1:
			item = _area_resolved_item
			orientation = _area_resolved_orientation
		elif _area_palette_id.is_empty():
			var selected: int = _current_build_item()
			if selected != -1:
				var resolved: Dictionary = _resolve_placement(selected, cells)
				item = int(resolved["item"])
				orientation = int(resolved["orientation"])

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

## Returns the material suffix for any slab variant, or "" for other items.
func _slab_material(item_name: String) -> String:
	var clean := item_name.trim_prefix("Auto_")
	var lower := clean.to_lower()

	for prefix in ["slab_top_", "slab_bottom_", "slab_side_", "slab_"]:
		if lower.begins_with(prefix):
			return clean.substr(prefix.length())

	return ""


## Returns the material suffix for any panel variant, or "" for other items.
func _panel_material(item_name: String) -> String:
	var clean := item_name.trim_prefix("Auto_")
	var lower := clean.to_lower()

	for prefix in ["panel_top_", "panel_bottom_", "panel_side_", "panel_"]:
		if lower.begins_with(prefix):
			return clean.substr(prefix.length())

	return ""


## Returns the material suffix for any stair variant, or "" for other items.
func _stair_material(item_name: String) -> String:
	var clean := item_name.trim_prefix("Auto_")
	var lower := clean.to_lower()

	if lower.begins_with("stairs_upsidedown_"):
		return clean.substr(18)
	if lower.begins_with("stairs_"):
		return clean.substr(7)
	if lower.begins_with("stair_"):
		return clean.substr(6)

	return ""


func _find_library_item(item_name: String) -> int:
	return int(_library_name_to_id.get(item_name, -1))


## Resolves the canonical inventory slab into the actual variant and GridMap
## orientation selected by the face/quad under the crosshair.
func _resolve_placement(
	selected_item: int,
	cells: Array[Vector3i]
) -> Dictionary:
	var resolved := {
		"item": selected_item,
		"orientation": _placement_orientation(selected_item, cells),
	}

	if grid_map == null or grid_map.mesh_library == null:
		return resolved

	var item_name := String(
		grid_map.mesh_library.get_item_name(selected_item)
	)
	var slab_material := _slab_material(item_name)
	var panel_material := _panel_material(item_name)
	var stair_material := _stair_material(item_name)

	if (
		slab_material.is_empty()
		and panel_material.is_empty()
		and stair_material.is_empty()
	):
		return resolved

	var face_info: Dictionary = _last_face_info
	if face_info.is_empty():
		face_info = _area_face_info
	if face_info.is_empty():
		return resolved

	var axis: Vector3 = face_info["axis"]
	var zone: int = int(face_info["zone"])

	if not stair_material.is_empty():
		# One inventory stair entry resolves to the normal or upside-down
		# variant. On a wall, the top quad asks for the upside-down stair;
		# every other wall quad and all floor/ceiling quads use the normal one.
		var stair_name := "Auto_Stairs_" + stair_material
		if absf(axis.y) < 0.5 and zone == FACE_ZONE_TOP:
			stair_name = "Auto_Stairs_UpsideDown_" + stair_material

		var stair_item := _find_library_item(stair_name)
		if stair_item != -1:
			resolved["item"] = stair_item
			resolved["orientation"] = _placement_orientation(
				stair_item,
				cells
			)
		return resolved

	var tangent_u: Vector3 = face_info["tangent_u"]
	var tangent_v: Vector3 = face_info["tangent_v"]
	var plate_shape := "Panel" if not panel_material.is_empty() else "Slab"
	var plate_material := panel_material if not panel_material.is_empty() else slab_material
	var variant := ""
	var side_direction := Vector3.ZERO

	if absf(axis.y) > 0.5:
		# Floor / ceiling: the four edge quads choose which half of the new
		# cell a vertical slab fills.
		match zone:
			FACE_ZONE_RIGHT:
				variant = "Side"
				side_direction = tangent_u
			FACE_ZONE_LEFT:
				variant = "Side"
				side_direction = -tangent_u
			FACE_ZONE_TOP:
				variant = "Side"
				side_direction = tangent_v
			FACE_ZONE_BOTTOM:
				variant = "Side"
				side_direction = -tangent_v
			_:
				# Middle of a floor -> bottom slab; ceiling -> top slab.
				variant = "Bottom" if axis.y > 0.0 else "Top"
	else:
		match zone:
			FACE_ZONE_TOP:
				variant = "Top"
			FACE_ZONE_BOTTOM:
				variant = "Bottom"
			FACE_ZONE_LEFT:
				variant = "Side"
				side_direction = -tangent_u
			FACE_ZONE_RIGHT:
				variant = "Side"
				side_direction = tangent_u
			_:
				# Middle of a wall -> vertical slab hugging that wall.
				variant = "Side"
				side_direction = -axis

	var variant_item := -1
	var orientation := 0

	if variant == "Side":
		side_direction.y = 0.0
		if side_direction.length_squared() < 0.0001:
			return resolved

		side_direction = side_direction.normalized()
		variant_item = _find_library_item(
			"Auto_" + plate_shape + "_Side_" + plate_material
		)
		orientation = grid_map.get_stair_orientation(
			Vector3i(
				roundi(side_direction.x),
				0,
				roundi(side_direction.z)
			),
			Vector3.RIGHT
		)
	else:
		variant_item = _find_library_item(
			"Auto_" + plate_shape + "_" + variant + "_" + plate_material
		)

	if variant_item == -1:
		return resolved

	resolved["item"] = variant_item
	resolved["orientation"] = orientation
	return resolved


## The orientation used when the current item is placed. Non-stair blocks use
## orientation 0; stairs face toward the player automatically. `ui_rotate`
## turns the facing direction a quarter turn at a time first.
func _placement_orientation(item: int, cells: Array[Vector3i]) -> int:
	var direction: Vector3i = _stair_facing_direction(
		_cells_center(cells)
	)

	if _manual_rotation != 0:
		direction = _rotate_cardinal(direction, _manual_rotation)

	if grid_map != null and grid_map.mesh_library != null:
		var raw_name: String = grid_map.mesh_library.get_item_name(item)
		# Connected textures are resolved per face in the mesher, so the cell
		# orientation is irrelevant.
		if raw_name.begins_with("Auto_Connect_"):
			return 0

		if auto_stairs and "stair" in raw_name.to_lower():
			return grid_map.get_stair_orientation(
				direction,
				stair_front_axis
			)

	return 0


## Turns a cardinal direction by `steps` quarter turns around Y.
func _rotate_cardinal(direction: Vector3i, steps: int) -> Vector3i:
	var rotated: Vector3 = Vector3(direction).rotated(
		Vector3.UP,
		-PI * 0.5 * float(steps)
	)

	if absf(rotated.x) >= absf(rotated.z):
		return Vector3i(1 if rotated.x >= 0.0 else -1, 0, 0)

	return Vector3i(0, 0, 1 if rotated.z >= 0.0 else -1)


## Rotates the held placement by a quarter turn (`ui_rotate`).
func _rotate_placement() -> void:
	_manual_rotation = (_manual_rotation + 1) % 4
	_play_sfx(_sfx_build_rotate, 0.97, 1.03)
	_preview_orientation = -1

	if _area_active:
		_refresh_area_target(true)


func _cells_center(cells: Array[Vector3i]) -> Vector3i:
	if cells.is_empty():
		return Vector3i.ZERO

	var total := Vector3i.ZERO
	for cell: Vector3i in cells:
		total += cell

	return Vector3i(
		roundi(float(total.x) / float(cells.size())),
		roundi(float(total.y) / float(cells.size())),
		roundi(float(total.z) / float(cells.size()))
	)


## Direction from the stair cell to the player, snapped to a cardinal axis.
func _stair_facing_direction(cell: Vector3i) -> Vector3i:
	var cell_center: Vector3 = grid_map.to_global(
		grid_map.map_to_local(cell)
	)
	var facing: Vector3 = player.global_position - cell_center
	facing.y = 0.0

	if facing.length_squared() < 0.0001:
		return Vector3i.FORWARD

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
	var active_palette := _active_palette_id()
	if not active_palette.is_empty():
		item_name = hud_manager.get_palette_name(active_palette)
	elif _selected_placeable_scene:
		item_name = _selected_placeable_scene.resource_path.get_file().get_basename().capitalize()
	elif grid_map and grid_map.mesh_library:
		var current_item_id: int = _current_build_item()
		if current_item_id != -1:
			item_name = grid_map.mesh_library.get_item_name(current_item_id)

	hud_manager.update_build_ui(build_mode_active, inventory_open, item_name)
	_refresh_held_use_component()
	_update_hand()


## Detects whether the selected placeable scene is a held tool. The temp scene
## is never added to the tree; it is only used to find a UseComponent.
func _refresh_held_use_component() -> void:
	if _held_use_scene == _selected_placeable_scene:
		return

	_held_use_scene = _selected_placeable_scene

	if is_instance_valid(_held_use_component):
		_held_use_component.queue_free()
	_held_use_component = null

	if _selected_placeable_scene == null:
		return

	var temp := _selected_placeable_scene.instantiate()
	var component := ComponentLookup.find_use(temp)

	if component != null:
		# Keep the component alive after the inspection instance is freed. It
		# is a plain Node, so it can live under the controller.
		component.get_parent().remove_child(component)
		add_child(component)
		_held_use_component = component

		if hud_manager != null:
			var overrides := hud_manager.get_placeable_overrides()
			for key in overrides:
				if key in component:
					component.set(key, overrides[key])

	temp.free()


func _use_held_tool(alt: bool) -> void:
	if _held_use_component == null or not _held_use_component.can_use(player):
		return

	var origin := _camera.global_position
	var direction := -_camera.global_transform.basis.z

	if alt:
		_held_use_component.alt_use(player, origin, direction)
	else:
		_held_use_component.use(player, origin, direction)

	if _hand != null:
		_hand.call("play_place_swing")


## Mirrors the held hotbar item onto the first-person hand using its real 3D
## mesh (blocks) or the placeable's own visuals.
func _update_hand() -> void:
	if _hand == null:
		return

	if build_mode_active:
		if _selected_placeable_scene:
			_hand.call("show_placeable", _selected_placeable_scene)
			return

		if grid_map and grid_map.mesh_library:
			var item_id: int = _current_build_item()
			if item_id != -1:
				_hand.call(
					"show_block",
					grid_map.mesh_library,
					item_id
				)
				return

	_hand.call("clear_item")

## Block currently held in the selected hotbar slot, or -1 when the slot is
## empty. Palette slots return one of their blocks; the preview is rerolled at
## the start of each placement.
func _current_build_item() -> int:
	if hud_manager:
		var palette_id := _active_palette_id()
		if not palette_id.is_empty():
			var palette_ids := _palette_block_ids(palette_id)
			if palette_ids.is_empty():
				_palette_preview_item = -1
			elif not palette_ids.has(_palette_preview_item):
				_palette_preview_item = palette_ids[randi() % palette_ids.size()]
			return _palette_preview_item
		_palette_preview_item = -1
		return hud_manager.get_hotbar_item(
			hud_manager.get_hotbar_selected_slot()
		)

	if build_items.is_empty():
		return -1

	return build_items[0]


func _active_palette_id() -> String:
	if hud_manager == null:
		return ""
	return hud_manager.get_hotbar_palette(hud_manager.get_hotbar_selected_slot())


## Picks the next random block for a selected palette. Called when the slot is
## selected and after each placement, so every stroke can use a different block.
func _reroll_palette_preview() -> void:
	var palette_id := _active_palette_id()
	if palette_id.is_empty() or hud_manager == null:
		_palette_preview_item = -1
		return
	var ids := _palette_block_ids(palette_id)
	_palette_preview_item = -1
	if not ids.is_empty():
		_palette_preview_item = ids[randi() % ids.size()]


func _palette_block_ids(palette_id: String) -> Array[int]:
	var ids: Array[int] = []
	if hud_manager == null:
		return ids
	return hud_manager.get_palette_block_ids(palette_id)

func _select_hotbar_slot(slot: int) -> void:
	if not hud_manager:
		return

	hud_manager.select_hotbar_slot(slot)

func _on_hotbar_slot_selected(slot: int) -> void:
	# The held item follows the selected slot: a block id or a placeable scene.
	_selected_placeable_scene = (
		hud_manager.get_hotbar_placeable(slot)
		if hud_manager
		else null
	)
	_preview_item = -1
	_manual_rotation = 0
	_preview_orientation = -1

	if _area_active:
		_refresh_area_target(true)

	var palette_id: String = hud_manager.get_hotbar_palette(slot) if hud_manager else ""
	_reroll_palette_preview()

	_update_build_ui()

	# Selecting a palette while the inventory is open is an edit action; while
	# playing it is a build item, so the popup stays closed.
	if not palette_id.is_empty() and inventory_open:
		hud_manager.open_hotbar_palette(slot, palette_id)

func _on_inventory_item_selected(id: int) -> void:
	_selected_placeable_scene = null # picking a block exits placeable mode

	if hud_manager:
		hud_manager.assign_hotbar_item(
			hud_manager.get_hotbar_selected_slot(),
			id
		)

	_preview_item = -1
	_manual_rotation = 0
	_preview_orientation = -1
	_update_build_ui()

func _on_placeable_selected(scene: PackedScene) -> void:
	_selected_placeable_scene = scene
	_manual_rotation = 0
	_preview_orientation = -1
	_update_build_ui()

## Interact (E) on the aimed placeable. Components supply the actual behaviour;
## a door/lever uses InteractableComponent, a chest can use ContainerComponent,
## and a GUI opener can use GuiComponent.
func _try_interact() -> void:
	var hit: Dictionary = _get_build_hit()
	if hit.is_empty():
		return

	var placeable := _find_placeable_ancestor(hit.collider)
	if placeable == null:
		return

	var usable := ComponentLookup.find_usable(placeable)
	if usable != null and usable.can_interact(player):
		usable.interact(player)


## Middle-click eyedropper: pick the aimed block (canonicalised to its visible
## inventory variant) or placeable scene into the selected hotbar slot.
func _pick_aimed() -> void:
	var hit: Dictionary = _get_build_hit()
	if hit.is_empty():
		return

	var placeable := _find_placeable_ancestor(hit.collider)
	if placeable != null:
		var path := placeable.scene_file_path
		if path.is_empty():
			return
		var scene := load(path) as PackedScene
		if scene == null or hud_manager == null:
			return

		var slot := hud_manager.get_hotbar_selected_slot()
		hud_manager.assign_hotbar_placeable(slot, scene)
		_selected_placeable_scene = scene
		_preview_item = -1
		_manual_rotation = 0
		_preview_orientation = -1
		_refresh_held_use_component()
		_update_build_ui()
		return

	if hit.collider != grid_map:
		return

	var cell: Vector3i = grid_map.get_hit_cell(hit.position, hit.normal)
	var item: int = grid_map.get_cell_item(cell)
	var water := _get_water_system()
	var water_item: int = water.get_pick_item(cell) if water != null else -1
	var picked := -1

	if water_item != -1:
		picked = water_item
	elif item != -1:
		picked = _canonical_pick_item(item)

	if picked == -1 or hud_manager == null:
		return

	var slot := hud_manager.get_hotbar_selected_slot()
	hud_manager.assign_hotbar_item(slot, picked)
	_selected_placeable_scene = null
	_preview_item = -1
	_manual_rotation = 0
	_preview_orientation = -1
	_refresh_held_use_component()
	_update_build_ui()


## Maps a placed slab/panel/stair variant back to the single visible inventory
## entry for that shape, so the eyedropper does not select a hidden item.
func _canonical_pick_item(item: int) -> int:
	if grid_map == null or grid_map.mesh_library == null:
		return item

	var item_name := String(grid_map.mesh_library.get_item_name(item))
	var slab_material := _slab_material(item_name)
	if not slab_material.is_empty():
		var slab_item := _find_library_item("Auto_Slab_Top_" + slab_material)
		if slab_item != -1:
			return slab_item

	var panel_material := _panel_material(item_name)
	if not panel_material.is_empty():
		var panel_item := _find_library_item("Auto_Panel_Top_" + panel_material)
		if panel_item != -1:
			return panel_item

	var stair_material := _stair_material(item_name)
	if not stair_material.is_empty():
		var stair_item := _find_library_item("Auto_Stairs_" + stair_material)
		if stair_item != -1:
			return stair_item

	return item


func _water_kind_for_item(item: int) -> String:
	if grid_map == null or grid_map.mesh_library == null:
		return ""

	var item_name := String(grid_map.mesh_library.get_item_name(item))
	if item_name in [
		"Water_Surface",
		"Water_Full",
		"Water_Slab",
		"Water_Panel",
	]:
		return item_name
	return ""


func _get_water_system() -> WaterSystem:
	if grid_map == null:
		_get_grid_map()
	if grid_map == null:
		return null
	return grid_map.get_water_system()


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
	if _held_use_component != null:
		return

	var instance: Node = _selected_placeable_scene.instantiate()
	var overrides: Dictionary = hud_manager.get_placeable_overrides()
	for key in overrides:
		if key in instance:
			instance.set(key, overrides[key])

	if (
		_placeable_requires_support(instance)
		and not _placeable_has_voxel_support(hit)
	):
		instance.free()
		_play_sfx(_sfx_build_cancel, 1.0, 1.0)
		return

	var scene_offset := _scene_grid_offset(instance)
	get_tree().current_scene.add_child(instance)

	if instance is Node3D:
		instance.global_position = _placeable_grid_position(
			scene_offset,
			hit
		)

	var spin := _manual_rotation * PI * 0.5
	if randomize_foliage_yaw and instance.is_in_group("foliage"):
		if (
			_placeable_ghost_scene == _selected_placeable_scene
			and _placeable_ghost_is_foliage
		):
			spin += _placeable_ghost_yaw
		else:
			spin += randf() * TAU

		# The next preview should show a different random rotation.
		_placeable_ghost_yaw = randf() * TAU
		if _placeable_ghost != null and is_instance_valid(_placeable_ghost):
			var next_spin := _manual_rotation * PI * 0.5 + _placeable_ghost_yaw
			_placeable_ghost.basis = (
				Basis(Vector3.UP, next_spin) * _placeable_ghost_base_basis
			)

	if not is_zero_approx(spin):
		instance.rotate_y(spin)

	instance.add_to_group("placeables")

	GlobalData.report_environment_change(
		(instance as Node3D).global_position,
		"placeable_added",
		{
			"scene": String(instance.scene_file_path),
			"name": String(instance.name),
		}
	)

	_play_sfx(_sfx_land, 1.0, 1.2)

	if _hand != null:
		_hand.call("play_impact")


## Snaps a placeable to the centre of the hit cell's X/Z footprint while
## keeping the surface Y. Wall-mounted placeables are pushed half a cell along
## the wall normal so their base sits on the face instead of inside the block.
## A scene may export `grid_xz_offset: Vector2` for per-placeable fine-tuning.
func _placeable_grid_position(scene_offset: Vector2, hit: Dictionary) -> Vector3:
	var fallback: Vector3 = hit.get("position", Vector3.ZERO)
	if grid_map == null:
		return fallback

	var cell: Vector3i = grid_map.get_hit_cell(fallback, hit.get("normal", Vector3.UP))
	var center: Vector3 = grid_map.to_global(grid_map.map_to_local(cell))
	var xz := Vector2(center.x, center.z)

	var normal: Vector3 = hit.get("normal", Vector3.UP)
	if absf(normal.y) < 0.5:
		var flat := Vector2(normal.x, normal.z)
		if flat.length_squared() > 0.0001:
			xz += flat.normalized() * (grid_map.cell_size.x * 0.5)

	return Vector3(
		xz.x + placeable_xz_offset.x + scene_offset.x,
		fallback.y,
		xz.y + placeable_xz_offset.y + scene_offset.y
	)

## True when the scene's instance has a component that requires voxel support.
## Used once at the start of a placeable area stroke.
func _placeable_scene_requires_support(scene: PackedScene) -> bool:
	if scene == null:
		return false
	var temp: Node = scene.instantiate()
	var requires := _placeable_requires_support(temp)
	temp.free()
	return requires


## Removes every placeable whose grid cell is in `cells`, plus wall-mounted
## placeables sitting within three-quarters of a cell of an area centre.
func _remove_placeables_in_cells(cells: Array[Vector3i]) -> void:
	if grid_map == null or cells.is_empty():
		return

	var cell_set: Dictionary = {}
	var centers: Array[Vector3] = []
	for cell: Vector3i in cells:
		cell_set[cell] = true
		centers.append(grid_map.to_global(grid_map.map_to_local(cell)))

	var radius := maxf(grid_map.cell_size.x, grid_map.cell_size.z) * 0.7
	for node in get_tree().get_nodes_in_group("placeables"):
		if not is_instance_valid(node) or not node is Node3D:
			continue
		var position := (node as Node3D).global_position
		var node_cell := grid_map.local_to_map(grid_map.to_local(position))
		var remove := cell_set.has(node_cell)
		if not remove:
			for center: Vector3 in centers:
				if position.distance_to(center) <= radius:
					remove = true
					break
		if remove:
			var placeable_position := (node as Node3D).global_position
			GlobalData.report_environment_change(
				placeable_position,
				"placeable_removed",
				{
					"scene": String((node as Node).scene_file_path),
					"name": String((node as Node).name),
				}
			)
			node.queue_free()


## Palette stroke: one random palette entry per cell. Blocks resolve their
## normal/slab/stair variant and orientation; placeables are spawned on the
## anchor surface. Returns true if anything was placed.
func _finish_palette_area(
	palette_id: String,
	cells: Array[Vector3i],
	anchor_hit: Dictionary
) -> bool:
	if hud_manager == null or grid_map == null or cells.is_empty():
		return false
	var entries := hud_manager.get_palette_entries(palette_id)
	if entries.is_empty():
		return false

	var supported := _placeable_has_voxel_support(anchor_hit)
	var water := _get_water_system()
	var one: Array[Vector3i] = []
	var placed := false

	for cell: Vector3i in cells:
		var entry: Dictionary = entries[randi() % entries.size()]
		if String(entry.get("kind", "")) == "block":
			var item := int(entry.get("item_id", -1))
			if item == -1:
				continue
			one.clear()
			one.append(cell)
			var water_kind := _water_kind_for_item(item)
			if not water_kind.is_empty():
				if water != null:
					water.place(one, water_kind)
					placed = true
				continue
			var resolved := _resolve_placement(item, one)
			grid_map.place_blocks(
				one,
				int(resolved["item"]),
				int(resolved["orientation"])
			)
			placed = true
		elif String(entry.get("kind", "")) == "placeable":
			var scene: PackedScene = entry.get("scene")
			if scene == null:
				continue
			if _placeable_scene_requires_support(scene) and not supported:
				continue
			one.clear()
			one.append(cell)
			_spawn_placeables_in_cells(scene, one, anchor_hit)
			placed = true

	return placed


## Places one copy of `scene` per selected cell. The whole area shares the
## anchor hit's surface height and normal, so a stretched placeable row stays
## flat on the clicked surface.
func _spawn_placeables_in_cells(
	scene: PackedScene,
	cells: Array[Vector3i],
	area_hit: Dictionary
) -> void:
	if scene == null or grid_map == null or cells.is_empty():
		return

	var normal: Vector3 = area_hit.get("normal", Vector3.UP)
	var hit_position: Vector3 = area_hit.get("position", Vector3.ZERO)
	var surface_y := hit_position.y
	var wall_mounted := absf(normal.y) < 0.5
	var supported := _placeable_has_voxel_support(area_hit)
	var overrides: Dictionary = (
		hud_manager.get_placeable_overrides()
		if hud_manager != null
		else {}
	)

	for cell: Vector3i in cells:
		var instance: Node = scene.instantiate()
		for key in overrides:
			if key in instance:
				instance.set(key, overrides[key])

		if _placeable_requires_support(instance) and not supported:
			instance.free()
			continue

		var scene_offset := _scene_grid_offset(instance)
		get_tree().current_scene.add_child(instance)

		if instance is Node3D:
			instance.global_position = _placeable_cell_position(
				scene_offset,
				cell,
				normal,
				surface_y,
				wall_mounted
			)

		var spin := _manual_rotation * PI * 0.5
		if randomize_foliage_yaw and instance.is_in_group("foliage"):
			spin += randf() * TAU
		if not is_zero_approx(spin):
			instance.rotate_y(spin)

		instance.add_to_group("placeables")

		GlobalData.report_environment_change(
			(instance as Node3D).global_position,
			"placeable_added",
			{
				"scene": String(instance.scene_file_path),
				"name": String(instance.name),
			}
		)


## Cell-based twin of _placeable_grid_position used by area placement.
func _placeable_cell_position(
	scene_offset: Vector2,
	cell: Vector3i,
	normal: Vector3,
	surface_y: float,
	wall_mounted: bool = false
) -> Vector3:
	if grid_map == null:
		return Vector3.ZERO

	var center: Vector3 = grid_map.to_global(grid_map.map_to_local(cell))
	var xz := Vector2(center.x, center.z)
	if wall_mounted:
		var flat := Vector2(normal.x, normal.z)
		if flat.length_squared() > 0.0001:
			xz += flat.normalized() * (grid_map.cell_size.x * 0.5)

	return Vector3(
		xz.x + placeable_xz_offset.x + scene_offset.x,
		center.y if wall_mounted else surface_y,
		xz.y + placeable_xz_offset.y + scene_offset.y
	)

func _play_sfx(
	stream_node: AudioStreamPlayer3D,
	pitch_min: float = 0.85,
	pitch_max: float = 1.15
) -> void:
	if stream_node:
		stream_node.pitch_scale = randf_range(pitch_min, pitch_max)
		stream_node.play()


## Looks up one of the player's build-sound nodes, creating it if the scene
## does not have one (so existing saved scenes keep working).
func _find_build_sfx(
	node_names: Array[String],
	fallback_path: String,
	fallback_volume_db: float
) -> AudioStreamPlayer3D:
	# Match case/underscore-insensitively and by stream path, so a node the
	# designer renamed (or placed in an older scene) is still reused instead of
	# being duplicated at runtime.
	for child: Node in player.get_children():
		var candidate := child as AudioStreamPlayer3D
		if candidate == null:
			continue

		var candidate_key := String(candidate.name).to_lower().replace(
			"_",
			""
		)
		for node_name: String in node_names:
			if candidate_key == String(node_name).to_lower().replace("_", ""):
				if candidate.stream == null:
					candidate.stream = load(fallback_path)
				return candidate

		if (
			candidate.stream != null
			and candidate.stream.resource_path == fallback_path
		):
			return candidate

	var created := AudioStreamPlayer3D.new()
	created.name = node_names[0]
	created.stream = load(fallback_path)
	created.volume_db = fallback_volume_db
	player.add_child(created)
	return created


func _start_build_loop() -> void:
	if _sfx_build_loop == null:
		return

	if _build_loop_tween != null and _build_loop_tween.is_valid():
		_build_loop_tween.kill()

	_build_loop_stopping = false

	if not _sfx_build_loop.playing:
		_sfx_build_loop.volume_db = BUILD_LOOP_SILENT_DB
		_sfx_build_loop.play()

	_build_loop_tween = create_tween()
	_build_loop_tween.tween_property(
		_sfx_build_loop,
		"volume_db",
		_build_loop_base_volume_db,
		BUILD_LOOP_FADE_IN
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _stop_build_loop() -> void:
	if _sfx_build_loop == null or not _sfx_build_loop.playing:
		return
	if _build_loop_stopping:
		return

	_build_loop_stopping = true

	if _build_loop_tween != null and _build_loop_tween.is_valid():
		_build_loop_tween.kill()

	_build_loop_tween = create_tween()
	_build_loop_tween.tween_property(
		_sfx_build_loop,
		"volume_db",
		BUILD_LOOP_SILENT_DB,
		BUILD_LOOP_FADE_OUT
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_build_loop_tween.tween_callback(_finish_build_loop_stop)


func _finish_build_loop_stop() -> void:
	_build_loop_stopping = false
	if _sfx_build_loop != null:
		_sfx_build_loop.stop()


## Four increment voices so rapid ghost-size changes do not restart (and cut
## off) the previous cue before it finishes.
func _setup_build_increment_voices() -> void:
	_sfx_build_increment_voices.clear()
	_increment_voice_busy_until.clear()
	if _sfx_build_increment == null:
		return

	_sfx_build_increment_voices.append(_sfx_build_increment)
	_increment_voice_busy_until.append(0)

	for index in range(3):
		_add_build_increment_voice(index + 2)


func _add_build_increment_voice(index: int) -> AudioStreamPlayer3D:
	if _sfx_build_increment == null:
		return null

	var voice := _sfx_build_increment.duplicate() as AudioStreamPlayer3D
	if voice == null:
		return null

	voice.name = "build_hold_increment_%d" % index
	player.add_child(voice)
	if not voice.is_inside_tree():
		voice.free()
		return null

	_sfx_build_increment_voices.append(voice)
	_increment_voice_busy_until.append(0)
	return voice


func _play_build_increment(pitch_min: float, pitch_max: float) -> void:
	if _sfx_build_increment_voices.is_empty():
		return

	var now: int = Time.get_ticks_msec()
	var voice_index: int = -1
	var oldest_index: int = 0
	var oldest_busy: int = 0x7FFFFFFF

	for index in _sfx_build_increment_voices.size():
		if not _sfx_build_increment_voices[index].is_inside_tree():
			continue
		if _increment_voice_busy_until[index] <= now:
			voice_index = index
			break
		if _increment_voice_busy_until[index] < oldest_busy:
			oldest_busy = _increment_voice_busy_until[index]
			oldest_index = index

	if voice_index == -1 and _sfx_build_increment_voices.size() < BUILD_INCREMENT_MAX_VOICES:
		if _add_build_increment_voice(_sfx_build_increment_voices.size() + 1) != null:
			voice_index = _sfx_build_increment_voices.size() - 1

	if voice_index == -1:
		# All voices are still busy; reuse the oldest rather than skipping the
		# cue entirely.
		if _sfx_build_increment_voices[oldest_index].is_inside_tree():
			voice_index = oldest_index
		else:
			return

	var voice: AudioStreamPlayer3D = _sfx_build_increment_voices[voice_index]
	var length_ms: int = 250
	if voice.stream != null:
		length_ms = maxi(50, int(ceilf(voice.stream.get_length() * 1000.0)))

	voice.pitch_scale = randf_range(pitch_min, pitch_max)
	# Lower pitches play the clip for longer, so keep the voice reserved for the
	# actual (pitch-adjusted) duration.
	_increment_voice_busy_until[voice_index] = now + int(
		ceilf(float(length_ms) / maxf(voice.pitch_scale, 0.1))
	)
	voice.play()

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
