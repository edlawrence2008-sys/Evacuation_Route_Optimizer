extends SceneTree

## Foliage render batching: many crossed-card plants are replaced by a small
## number of MultiMeshes while the original placeables stay alive for selection,
## deletion and saving.
##
##   godot --headless --path . --script res://tests/foliage_batcher_test.gd

const BATCHER = preload("res://scripts/world/foliage_batcher.gd")
const FOLIAGE_SCENE = preload(
	"res://scenes/placeables/foilage/foliage_short_grass.tscn"
)

const PLANT_COUNT: int = 120

var _checks: int = 0
var _failures: int = 0
var _world: Node3D
var _batcher: Node
var _plants: Array[Node3D] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== foliage batcher ===")

	_world = Node3D.new()
	_world.name = "BatcherTestWorld"
	root.add_child(_world)

	for index in PLANT_COUNT:
		var plant := FOLIAGE_SCENE.instantiate() as Node3D
		plant.position = Vector3(float(index % 12) * 0.8, 0.0, float(index / 12) * 0.8)
		_world.add_child(plant)
		_plants.append(plant)

	_batcher = BATCHER.new()
	_batcher.name = "FoliageBatcher"
	root.add_child(_batcher)

	await process_frame
	_batcher.call("_refresh")

	var sprites := _all_sprites()
	_expect("test plants are in the foliage group", _plants[0].is_in_group("foliage"))
	_expect(
		"all cards are batched",
		_batcher._hidden_sprites.size() == sprites.size(),
		"%d / %d" % [_batcher._hidden_sprites.size(), sprites.size()]
	)
	_expect("at least one MultiMesh batch", not _batcher._batches.is_empty())
	_expect(
		"batch instance count matches cards",
		_batch_instances() == sprites.size(),
		"%d / %d" % [_batch_instances(), sprites.size()]
	)

	var hidden_ok := true
	for sprite in sprites:
		if sprite.visible:
			hidden_ok = false
			break
	_expect("original cards are hidden", hidden_ok)

	var batch_ok := true
	for batch in _batcher._batches:
		if batch.multimesh == null:
			batch_ok = false
			break
		if batch.material_override == null:
			batch_ok = false
			break
	_expect("batches have a mesh and material", batch_ok)

	# Removing a plant must drop its cards from the next rebuild and restore
	# the survivor state cleanly.
	var removed := _plants[0]
	_plants.remove_at(0)
	removed.queue_free()
	await process_frame
	await process_frame
	_batcher.call("_refresh")
	var remaining := _all_sprites().size()
	_expect(
		"removing a plant shrinks the batch",
		_batch_instances() == remaining,
		"%d / %d" % [_batch_instances(), remaining]
	)

	_batcher.call("_clear_batches")
	_batcher.call("_restore_sprites")
	var visible_ok := true
	for plant in _plants:
		if not is_instance_valid(plant):
			continue
		for child in plant.get_children():
			if child is Sprite3D and not (child as Sprite3D).visible:
				visible_ok = false
				break
		if not visible_ok:
			break
	_expect("restore makes cards visible again", visible_ok)

	_world.queue_free()
	_batcher.queue_free()
	_finish()


func _all_sprites() -> Array[Sprite3D]:
	var result: Array[Sprite3D] = []
	for plant in _plants:
		if not is_instance_valid(plant):
			continue
		for child in plant.get_children():
			if child is Sprite3D:
				result.append(child as Sprite3D)
	return result


func _batch_instances() -> int:
	var total := 0
	for batch: Variant in _batcher._batches:
		if is_instance_valid(batch) and batch.multimesh != null:
			total += batch.multimesh.instance_count
	return total


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("FAIL: %s" % label)
	else:
		print("FAIL: %s (%s)" % [label, detail])


func _finish() -> void:
	print("checks=%d failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== PASS ===")
	quit(1 if _failures > 0 else 0)
