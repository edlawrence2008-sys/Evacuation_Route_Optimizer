extends Node3D

## First-person held-item display (Classic Game Isometric View).
##
## Shows the selected block's MeshLibrary mesh, or a placeable's own 3D visuals,
## at the `item` marker with classic 2:1 isometric angles. Driven by BuildController:
## `show_block()` / `show_placeable()` / `clear_item()` from `_update_build_ui()`,
## and `play_swing()` from `_begin_area()`.

const BLOCK_SIZE: float = 0.15
const PLACEABLE_SIZE: float = 0.5

const BLOCK_TILT := Vector3(26.565, 45.0, 0.0)
const PLACEABLE_TILT := Vector3(26.565, 45.0, -15.0)

const SWING_TIME: float = 0.2
const SWING_DIP: float = 0.075
const SWING_BACK: float = 0.055
const SWING_PITCH_DEG: float = 5.0
const SWING_ROLL_DEG: float = 2.0
const VoxelItemDB := preload("res://scripts/voxel_item_generator.gd")
## Build animation: push the model forward/up first, then settle back.
const PLACE_SWING_FORWARD: float = 0.085
const PLACE_SWING_LIFT: float = 0.012
const PLACE_SWING_PITCH_DEG: float = -9.0
const PLACE_SWING_ROLL_DEG: float = -2.0
const EQUIP_TIME: float = 0.18
const IMPACT_TIME: float = 0.12
const IDLE_HOVER: float = 0.0025
const IDLE_ROLL_DEG: float = 0.35

# --- Viewmodel motion ---
## Metres of sideways lag per m/s of local velocity.
const SWAY_LAG: float = 0.006
const MAX_SWAY: float = 0.03
## Metres of lag per radian of camera turn (per frame) and its vertical cap.
const TURN_LAG: float = 0.08
const MAX_LAG_Y: float = 0.025
const BOB_AMOUNT: float = 0.006
## Degrees of roll per m/s of strafing.
const ROLL_PER_SPEED: float = 1.4
## Degrees of roll per radian of camera yaw (per frame).
const TURN_ROLL_DEG: float = 90.0
const MAX_ROLL: float = 6.0
## Drag-build vibration.
const SHAKE_AMOUNT: float = 0.005
const SHAKE_HZ: float = 45.0
const SHAKE_ROLL: float = 1.5

@onready var item_marker: Marker3D = $item

var _item_root: Node3D = null
var _model: Node3D = null
var _holding: bool = false
var _model_key: String = ""
var _base_position: Vector3 = Vector3.ZERO
var _swing_tween: Tween = null

var _player: CharacterBody3D = null
var _camera: Camera3D = null
var _sway: Vector3 = Vector3.ZERO
var _roll: float = 0.0
var _bob_t: float = 0.0
var _shake_t: float = 0.0
var _shaking: bool = false
var _shake_scale: float = 1.0
var _prev_yaw: float = 0.0
var _prev_pitch: float = 0.0
var _base_rotation: Vector3 = Vector3.ZERO
var _equip_t: float = 1.0
var _impact_t: float = 1.0
var _idle_t: float = 0.0


func _ready() -> void:
	_base_position = position
	_base_rotation = rotation

	# Clean camera-space holder: only the marker position is used, because the
	# marker carries a non-uniform scale that would distort a 3D model.
	_item_root = Node3D.new()
	_item_root.name = "HeldModel"
	_item_root.position = item_marker.position
	add_child(_item_root)

	_player = get_tree().get_first_node_in_group("player") as CharacterBody3D
	_camera = get_parent() as Camera3D

	if _camera != null:
		_prev_yaw = _camera.global_rotation.y
		_prev_pitch = _camera.global_rotation.x


## Viewmodel sway, turn lag, roll and walk bob. The swing tween owns the
## `hands` node, so all of this lives on the clean item holder instead.
func _process(delta: float) -> void:
	if _item_root == null or _model == null:
		return

	# The player joins its group in its own _ready, which runs after this
	# child's _ready, so resolve it lazily.
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as CharacterBody3D

	var base: Vector3 = item_marker.position
	var target := Vector3.ZERO
	var target_roll: float = 0.0
	var speed: float = 0.0
	var grounded: bool = false

	if _player != null:
		speed = Vector2(_player.velocity.x, _player.velocity.z).length()
		grounded = _player.is_on_floor()

	if _camera != null and _player != null:
		var local_velocity: Vector3 = (
			_camera.global_transform.basis.inverse() * _player.velocity
		)
		target.x = -local_velocity.x * SWAY_LAG
		target.z = local_velocity.z * SWAY_LAG * 0.35
		target_roll = -local_velocity.x * ROLL_PER_SPEED

		var yaw: float = _camera.global_rotation.y
		var pitch: float = _camera.global_rotation.x
		var yaw_delta: float = wrapf(yaw - _prev_yaw, -PI, PI)
		var pitch_delta: float = wrapf(pitch - _prev_pitch, -PI, PI)
		_prev_yaw = yaw
		_prev_pitch = pitch

		target.x += yaw_delta * TURN_LAG
		target.y += -pitch_delta * TURN_LAG * 0.6
		target_roll += yaw_delta * TURN_ROLL_DEG

	target.y = clampf(target.y, -MAX_LAG_Y, MAX_LAG_Y)

	_sway = _sway.lerp(
		target,
		clampf(12.0 * delta, 0.0, 1.0)
	).limit_length(MAX_SWAY)
	_roll = lerpf(
		_roll,
		deg_to_rad(clampf(target_roll, -MAX_ROLL, MAX_ROLL)),
		clampf(10.0 * delta, 0.0, 1.0)
	)

	var bob: float = 0.0

	if grounded and speed > 0.5:
		_bob_t += delta * (6.0 + speed * 1.4)
		bob = (
			sin(_bob_t)
			* BOB_AMOUNT
			* clampf(speed / 5.0, 0.0, 1.0)
		)

	# Idle hover keeps the held model alive even when standing still.
	_idle_t += delta
	var idle_y: float = sin(_idle_t * 1.7) * IDLE_HOVER
	var idle_roll: float = sin(_idle_t * 1.1) * deg_to_rad(IDLE_ROLL_DEG)

	# Equip pop when the selected item changes.
	_equip_t = minf(_equip_t + delta, EQUIP_TIME)
	var equip: float = 1.0 - ease(
		clampf(_equip_t / EQUIP_TIME, 0.0, 1.0),
		0.35
	)

	# Impact punch at the moment blocks are placed or removed.
	_impact_t = minf(_impact_t + delta, IMPACT_TIME)
	var impact: float = sin(
		clampf(_impact_t / IMPACT_TIME, 0.0, 1.0) * PI
	)

	var shake := Vector3.ZERO
	var shake_roll: float = 0.0

	if _shaking:
		_shake_t += delta * SHAKE_HZ
		shake = Vector3(
			sin(_shake_t * 1.7),
			cos(_shake_t * 2.3),
			sin(_shake_t * 1.1)
		) * (SHAKE_AMOUNT * _shake_scale)
		shake_roll = (
			sin(_shake_t * 2.9)
			* deg_to_rad(SHAKE_ROLL * _shake_scale)
		)
	else:
		_shake_t = 0.0

	_item_root.position = (
		base
		+ _sway
		+ Vector3(0.0, bob + idle_y - equip * 0.035, 0.0)
		+ shake
	)
	_item_root.rotation = Vector3(0.0, 0.0, _roll + shake_roll + idle_roll)
	_item_root.scale = Vector3.ONE * (
		(1.0 - equip * 0.25) * (1.0 + impact * 0.06)
	)


## While a place/break drag is held, the item vibrates in place. `intensity`
## is the number of selected blocks: one block barely trembles while a large
## drag shakes and rotates noticeably.
func set_shaking(active: bool, intensity: int = 1) -> void:
	_shaking = active
	_shake_scale = clampf(
		0.2 + float(maxi(intensity, 1) - 1) * 0.08,
		0.2,
		2.2
	)
	if not active:
		_shake_t = 0.0


## Quick scale punch when blocks are actually placed or removed.
func play_impact() -> void:
	_impact_t = 0.0


## Shows a block from the MeshLibrary as its real 3D mesh.
func show_block(mesh_library: MeshLibrary, item_id: int) -> void:
	if mesh_library == null:
		clear_item()
		return

	var key := "b:%d:%d" % [mesh_library.get_instance_id(), item_id]

	if _holding and _model_key == key:
		return

	var mesh: Mesh = mesh_library.get_item_mesh(item_id)

	if mesh == null:
		clear_item()
		return

	var holder := Node3D.new()
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.transform = mesh_library.get_item_mesh_transform(item_id)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(instance)

	_finish_model(holder, BLOCK_SIZE, BLOCK_TILT, key)


## Shows a placeable's own 3D visuals (meshes and sprite cards). Foliage uses
## the generated voxel item icon as a flat MC-style held item instead.
func show_placeable(scene: PackedScene) -> void:
	if scene == null:
		clear_item()
		return

	var voxel_mesh: ArrayMesh = VoxelItemDB.extruded_mesh_for_scene(scene)
	var use_voxel_item := (
		voxel_mesh != null
		and VoxelItemDB.viewmodel_for_scene(scene) == "extruded"
	)
	var key := (
		("v:" if use_voxel_item else "p:")
		+ scene.resource_path
	)

	if _holding and _model_key == key:
		return

	var holder: Node3D = (
		_build_voxel_item_holder(voxel_mesh)
		if use_voxel_item
		else _build_placeable_holder(scene)
	)

	if holder == null or holder.get_child_count() == 0:
		if holder != null:
			holder.free()
		clear_item()
		return

	_finish_model(holder, PLACEABLE_SIZE, PLACEABLE_TILT, key)


## Removes the held model (empty slot / build mode off).
func clear_item() -> void:
	if not _holding and _model == null:
		return

	_model_key = ""
	_clear_model()
	_holding = false


## Plays the use swing: the held model dips and comes back.
## Breaking/destroying animation: dip and pull the model back toward the player.
func play_break_swing() -> void:
	if not _holding:
		return

	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()

	_swing_tween = create_tween()
	_swing_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_swing_tween.tween_property(
		self,
		"position",
		_base_position + Vector3(0.008, -SWING_DIP, SWING_BACK),
		SWING_TIME * 0.35
	)
	_swing_tween.parallel().tween_property(
		self,
		"rotation",
		_base_rotation + Vector3(
			deg_to_rad(SWING_PITCH_DEG),
			0.0,
			deg_to_rad(SWING_ROLL_DEG)
		),
		SWING_TIME * 0.35
	)
	_swing_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_swing_tween.tween_property(
		self,
		"position",
		_base_position,
		SWING_TIME * 0.65
	)
	_swing_tween.parallel().tween_property(
		self,
		"rotation",
		_base_rotation,
		SWING_TIME * 0.65
	)


## Build/place animation: extend the model forward and slightly up first, then
## settle back. The opposite silhouette from the break pull-back.
func play_place_swing() -> void:
	if not _holding:
		return

	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()

	_swing_tween = create_tween()
	_swing_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_swing_tween.tween_property(
		self,
		"position",
		_base_position + Vector3(0.006, PLACE_SWING_LIFT, -PLACE_SWING_FORWARD),
		SWING_TIME * 0.32
	)
	_swing_tween.parallel().tween_property(
		self,
		"rotation",
		_base_rotation + Vector3(
			deg_to_rad(PLACE_SWING_PITCH_DEG),
			0.0,
			deg_to_rad(PLACE_SWING_ROLL_DEG)
		),
		SWING_TIME * 0.32
	)
	_swing_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_swing_tween.tween_property(
		self,
		"position",
		_base_position,
		SWING_TIME * 0.68
	)
	_swing_tween.parallel().tween_property(
		self,
		"rotation",
		_base_rotation,
		SWING_TIME * 0.68
	)


## Backwards-compatible alias for older callers: the destroy animation.
func play_swing() -> void:
	play_break_swing()


func _finish_model(
	holder: Node3D,
	target_size: float,
	tilt: Vector3,
	key: String
) -> void:
	_clear_model()
	_model_key = key
	_model = holder
	_item_root.add_child(holder)
	_fit_model(holder, target_size, tilt)
	_holding = true
	_equip_t = 0.0


func _clear_model() -> void:
	if _model != null and is_instance_valid(_model):
		_model.queue_free()
	_model = null


## Recentres the model on the holder origin and scales it to `target_size`.
func _fit_model(holder: Node3D, target_size: float, tilt: Vector3) -> void:
	var combined := AABB()
	var visual_count: int = 0

	for child in holder.get_children():
		var box: AABB

		if child is MeshInstance3D:
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.mesh == null:
				continue
			box = mesh_instance.transform * mesh_instance.get_aabb()
		elif child is Sprite3D:
			var sprite := child as Sprite3D
			box = sprite.transform * sprite.get_aabb()
		else:
			continue

		combined = box if visual_count == 0 else combined.merge(box)
		visual_count += 1

	if visual_count == 0:
		return

	var center: Vector3 = combined.get_center()

	for child in holder.get_children():
		if child is Node3D:
			(child as Node3D).position -= center

	var max_dim: float = maxf(
		combined.size.x,
		maxf(combined.size.y, combined.size.z)
	)
	holder.scale = Vector3.ONE * (target_size / maxf(max_dim, 0.001))

	# Flat models (e.g. the Evac Point's ground disc) would be invisible
	# edge-on; tip them toward the camera so they read in the hand.
	var final_tilt: Vector3 = tilt
	var horizontal: float = maxf(combined.size.x, combined.size.z)

	if combined.size.y < 0.1 * maxf(horizontal, 0.001):
		final_tilt.x = -55.0

	holder.rotation = Vector3(
		deg_to_rad(final_tilt.x),
		deg_to_rad(final_tilt.y),
		deg_to_rad(final_tilt.z)
	)


## Extruded MC-style pixel item mesh used as the held model for foliage.
func _build_voxel_item_holder(mesh: ArrayMesh) -> Node3D:
	var holder := Node3D.new()
	if mesh == null:
		return holder

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(instance)

	return holder


## Copies only the renderable nodes of an instanced scene into a fresh holder.
## The source scene is never added to the tree, so its scripts never run.
func _build_placeable_holder(scene: PackedScene) -> Node3D:
	var temp: Node = scene.instantiate()
	var holder := Node3D.new()

	_copy_visuals(temp, holder, Transform3D.IDENTITY)
	temp.free()

	return holder


func _copy_visuals(
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
			# Unshaded so the preview keeps its colour in the hand even in
			# shadow or at night; world foliage stays shaded.
			sprite_copy.shaded = false
			sprite_copy.double_sided = source_sprite.double_sided
			sprite_copy.alpha_cut = source_sprite.alpha_cut
			sprite_copy.texture_filter = source_sprite.texture_filter
			sprite_copy.transform = child_xform
			target.add_child(sprite_copy)

		_copy_visuals(child, target, child_xform)
