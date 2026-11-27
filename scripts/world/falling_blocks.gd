class_name FallingBlocks
extends MultiMeshInstance3D

## One-shot visual for the Falling collapse style. The world move already
## happened (or is scheduled to land when this node frees), so this node is pure
## presentation: each instance slides from its old cell to its landing cell.

var _from: Array[Vector3] = []
var _to: Array[Vector3] = []
var _elapsed: float = 0.0
var _duration: float = 0.45


func setup(moves: Array, block_size: Vector3, duration: float) -> void:
	_duration = maxf(0.05, duration)

	var box := BoxMesh.new()
	box.size = block_size * 0.92

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.46, 0.42)
	material.roughness = 1.0
	box.material = material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = box
	multimesh.instance_count = moves.size()
	self.multimesh = multimesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	for index in moves.size():
		var move: Dictionary = moves[index]
		var from: Vector3 = move.get("from", Vector3.ZERO)
		var to: Vector3 = move.get("to", from)
		_from.append(from)
		_to.append(to)
		multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, from))


func _process(delta: float) -> void:
	if _from.is_empty():
		return

	_elapsed += delta
	var t: float = clampf(_elapsed / _duration, 0.0, 1.0)
	var eased: float = t * t

	for index in _from.size():
		var position: Vector3 = _from[index].lerp(_to[index], eased)
		multimesh.set_instance_transform(
			index,
			Transform3D(Basis.IDENTITY, position)
		)

	if t >= 1.0:
		_from.clear()
		_to.clear()
		queue_free()
