extends Node

## Render batcher for large foliage populations.
##
## A generated foliage plant is a Node3D with one or two Sprite3D cards. On a
## big world that is thousands of alpha-cut draws. The batcher keeps the
## original placeables (Area3D selection, save data, deletion) and hides only
## their Sprite3D cards, replacing them with per-chunk MultiMeshes. The foliage
## sway shader already derives its phase from MODEL_MATRIX, so batching preserves
## wind animation.
##
## Batches are grouped by material, primary/secondary card and 64 m chunk. The
## chunk grouping keeps each MultiMesh's AABB small enough for frustum and
## visibility-range culling.
##
## Rebuilds are signal-driven: SceneTree node add/remove marks the batcher dirty
## and a 0.25 s debounce coalesces a stroke or a save-load burst into one build.
## There is no per-second full scan, so an idle world pays nothing. The scan and
## grouping happen in one pass only when the population actually changed.

const SWAY = preload("res://scripts/foliage_sway.gd")

const CHUNK_SIZE: float = 64.0
const MIN_BATCH_INSTANCES: int = 200
const REBUILD_DEBOUNCE: float = 0.25

var _batches: Array[MultiMeshInstance3D] = []
var _hidden_sprites: Array[Sprite3D] = []
## Parent node -> true. A Dictionary avoids the O(n^2) Array.has() scan that
## made the first rebuild of a big world take over a second.
var _hidden_nodes: Dictionary = {}
var _dirty: bool = true
var _dirty_age: float = REBUILD_DEBOUNCE
var _has_built: bool = false
## Diagnostic counter; also lets tests/profiling distinguish repeated rebuilds
## from one-time shader/batch cost.
var rebuild_count: int = 0


func _ready() -> void:
	set_process(true)

	var tree := get_tree()

	if tree != null:
		tree.node_added.connect(_on_node_added)
		tree.node_removed.connect(_on_node_removed)

	mark_dirty()


func _process(delta: float) -> void:
	if not _dirty:
		return

	_dirty_age += delta
	if _dirty_age < REBUILD_DEBOUNCE:
		return

	_dirty = false
	_dirty_age = 0.0
	_refresh()


func _exit_tree() -> void:
	if _has_built:
		_clear_batches()
		_restore_sprites()
		_has_built = false


func _on_node_added(node: Node) -> void:
	if node is Node3D and node.is_in_group("foliage"):
		mark_dirty()


func _on_node_removed(node: Node) -> void:
	if not node is Node3D:
		return
	# A batch node's name contains "foliage"; removing it must not trigger a
	# rebuild loop.
	if node is MultiMeshInstance3D and node.name == "FoliageBatch":
		return
	if node.is_in_group("foliage"):
		mark_dirty()
		return
	# A node removed during save/scene teardown may no longer report its groups.
	if String(node.name).to_lower().contains("foliage"):
		mark_dirty()


## Public so PerformanceSettings can request a rebuild after changing the
## foliage population/materials.
func mark_dirty() -> void:
	_dirty = true
	_dirty_age = 0.0


## Updates the distance bands of existing batches in place. Distance changes do
## not need a 16k-instance rebuild.
func apply_distance(far_distance: float, mid_distance: float) -> void:
	for batch: Variant in _batches:
		if not is_instance_valid(batch):
			continue
		var multi := batch as MultiMeshInstance3D
		var secondary: bool = bool(multi.get_meta("foliage_secondary", false))
		var distance := mid_distance if secondary else far_distance
		multi.visibility_range_end = distance
		multi.visibility_range_end_margin = maxf(8.0, distance * 0.15)


func _refresh() -> void:
	_rebuild(_collect_groups())


## One pass over every foliage card: verify the sprite, group it by
## material/secondary card/chunk, and count the batchable cards. Rebuilds are
## only requested for real population/settings changes, so there is no need to
## hash every card here.
func _collect_groups() -> Dictionary:
	var groups: Dictionary = {}
	var count := 0

	for node in get_tree().get_nodes_in_group("foliage"):
		if not node is Node3D or not node.is_inside_tree():
			continue

		var parent := node.get_parent()
		if parent is SubLevel:
			continue
		if parent != null and parent.get_parent() is SubLevel:
			continue

		var sprite_index := 0

		for child in node.get_children():
			if not child is Sprite3D:
				continue

			var sprite := child as Sprite3D
			var secondary := sprite_index > 0
			sprite_index += 1

			if not _is_batchable(sprite):
				continue

			var material := SWAY.material_for_sprite(sprite)
			if material == null:
				continue

			var chunk := Vector2i(
				floori((node as Node3D).global_position.x / CHUNK_SIZE),
				floori((node as Node3D).global_position.z / CHUNK_SIZE)
			)
			# Integer composite key: no per-sprite string formatting on a
			# 16k-card world.
			var key: int = material.get_instance_id()
			key = key * 31 + (1 if secondary else 0)
			key = key * 31 + chunk.x
			key = key * 31 + chunk.y

			if not groups.has(key):
				groups[key] = {
					"material": material,
					"secondary": secondary,
					"chunk": chunk,
					"first": sprite,
					"sprites": [],
				}

			groups[key]["sprites"].append(sprite)
			count += 1

	return {
		"groups": groups,
		"count": count,
	}


func _is_batchable(sprite: Sprite3D) -> bool:
	if sprite.texture == null:
		return false
	if sprite.billboard != BaseMaterial3D.BILLBOARD_DISABLED:
		return false
	if not sprite.shaded:
		return false
	if sprite.region_enabled or sprite.hframes > 1 or sprite.vframes > 1:
		return false
	if not sprite.centered or sprite.offset != Vector2.ZERO:
		return false
	return true


func _rebuild(scan: Dictionary) -> void:
	rebuild_count += 1
	_clear_batches()
	_restore_sprites()
	_has_built = false

	if int(scan["count"]) < MIN_BATCH_INSTANCES:
		return

	var groups: Dictionary = scan["groups"]

	for key: Variant in groups:
		var group: Dictionary = groups[key]
		var sprites: Array = group["sprites"]

		if sprites.is_empty():
			continue

		var first: Sprite3D = group["first"]
		var texture: Texture2D = first.texture
		var quad := QuadMesh.new()
		quad.size = Vector2(
			float(texture.get_width()) * first.pixel_size,
			float(texture.get_height()) * first.pixel_size
		)

		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = quad
		multimesh.instance_count = sprites.size()

		for index in sprites.size():
			var sprite: Sprite3D = sprites[index]
			multimesh.set_instance_transform(
				index,
				sprite.global_transform
			)
			_hide_sprite(sprite)

		var batch := MultiMeshInstance3D.new()
		batch.name = "FoliageBatch"
		batch.set_meta("foliage_batch", true)
		batch.set_meta("foliage_secondary", bool(group["secondary"]))
		batch.top_level = true
		batch.multimesh = multimesh
		batch.material_override = group["material"]
		batch.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if bool(group["secondary"])
			else GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		)

		var distance := (
			float(SWAY.mid_view_distance)
			if bool(group["secondary"])
			else float(SWAY.max_view_distance)
		)
		batch.visibility_range_end = distance
		batch.visibility_range_end_margin = maxf(8.0, distance * 0.15)
		batch.visibility_range_fade_mode = (
			GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		)

		var host := get_tree().current_scene
		if host == null:
			host = get_tree().root
		host.add_child(batch)
		_batches.append(batch)

	_has_built = not _batches.is_empty()


func _hide_sprite(sprite: Sprite3D) -> void:
	sprite.visible = false
	_hidden_sprites.append(sprite)

	var parent := sprite.get_parent() as Node3D
	if parent == null:
		return
	if not _hidden_nodes.has(parent):
		_hidden_nodes[parent] = parent.is_processing()
		parent.set_process(false)


func _clear_batches() -> void:
	for batch: Variant in _batches:
		if is_instance_valid(batch):
			batch.visible = false
			batch.queue_free()
	_batches.clear()


func _restore_sprites() -> void:
	for sprite: Variant in _hidden_sprites:
		if is_instance_valid(sprite):
			(sprite as Sprite3D).visible = true
	_hidden_sprites.clear()

	for node: Variant in _hidden_nodes:
		if is_instance_valid(node):
			(node as Node3D).set_process(bool(_hidden_nodes[node]))
	_hidden_nodes.clear()
