class_name OptimizerOverlay
extends Node3D

## World-space debug overlay for the exit-assignment optimizer.
##
## Draws one line per cohort to its assigned exit, a coloured stem above every
## live evacuee (optimizer assignment or local destination), and a label beside
## each exit with assigned / queue / capacity numbers. It is intentionally
## unshaded and depth-test-free so it stays readable through walls.
##
## The overlay owns no simulation state: disabling it only hides geometry.

const REFRESH_INTERVAL: float = 0.2
const STEM_HEIGHT: float = 0.7
const LABEL_HEIGHT: float = 3.4

var _bridge: Node = null
var _result: OptimizationResult = null
var _enabled: bool = false
var _accum: float = 0.0
var _mesh_instance: MeshInstance3D = null
var _mesh: ImmediateMesh = null
var _material: StandardMaterial3D = null
var _labels: Dictionary = {}


func setup(bridge: Node) -> void:
	_bridge = bridge
	_ensure_mesh()


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value

	if _enabled:
		_redraw()


func set_result(result: OptimizationResult) -> void:
	_result = result

	if _enabled:
		_redraw()


func _process(delta: float) -> void:
	if not _enabled or _result == null:
		return

	_accum += delta

	if _accum < REFRESH_INTERVAL:
		return

	_accum = 0.0
	_redraw()


func _ensure_mesh() -> void:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		return

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "AssignmentMesh"
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh = ImmediateMesh.new()
	_mesh_instance.mesh = _mesh
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.no_depth_test = true
	_material.disable_receive_shadows = true
	add_child(_mesh_instance)


func _redraw() -> void:
	_ensure_mesh()

	if _mesh == null:
		return

	_mesh.clear_surfaces()

	if _result == null:
		_clear_labels()
		return

	var exits: Dictionary = _live_exits()
	_draw_cohorts(exits)
	_draw_agents(exits)
	_draw_exit_labels(exits)


func _draw_cohorts(exits: Dictionary) -> void:
	if _result.cohorts.is_empty():
		return

	var started: bool = false

	for cohort: Dictionary in _result.cohorts:
		var exit_id := String(cohort.get("exit_id", ""))
		var entry: Variant = exits.get(exit_id)

		if entry == null:
			continue

		if not started:
			_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _material)
			started = true

		var color := _exit_color(exit_id)
		var start: Vector3 = cohort.get("position", Vector3.ZERO)
		start.y += 1.1
		var finish: Vector3 = (entry as Dictionary).get("position", Vector3.ZERO)
		finish.y += 1.1

		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(start)
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(finish)

		var route: Array = cohort.get("route", [])

		if route.size() >= 2:
			var previous := _point(route[0], Vector3.ZERO)

			for index: int in range(1, route.size()):
				var current := _point(route[index], Vector3.ZERO)

				if previous == Vector3.ZERO or current == Vector3.ZERO:
					previous = current
					continue

				_mesh.surface_set_color(color)
				_mesh.surface_add_vertex(previous + Vector3.UP * 1.05)
				_mesh.surface_set_color(color)
				_mesh.surface_add_vertex(current + Vector3.UP * 1.05)
				previous = current

	if started:
		_mesh.surface_end()


func _draw_agents(exits: Dictionary) -> void:
	if not is_inside_tree():
		return

	var tree: SceneTree = get_tree()

	if tree == null:
		return

	var started: bool = false

	for node: Node in tree.get_nodes_in_group("npc"):
		if not node is Node3D or not is_instance_valid(node):
			continue

		if node.has_meta("evacuated"):
			continue

		if not started:
			_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _material)
			started = true

		var agent := node as Node3D
		var exit_id := _agent_exit_id(node)
		var color := (
			_exit_color(exit_id)
			if not exit_id.is_empty() and exits.has(exit_id)
			else Color(0.55, 0.55, 0.6, 0.8)
		)
		var base: Vector3 = agent.global_position + Vector3(0.0, 1.9, 0.0)

		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(base)
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(base + Vector3(0.0, STEM_HEIGHT, 0.0))

	if started:
		_mesh.surface_end()


func _agent_exit_id(node: Node) -> String:
	if node.has_method("has_optimizer_assignment"):
		if bool(node.call("has_optimizer_assignment")):
			return String(node.call("get_optimizer_exit_id"))

	return String(node.get("destination_exit_id"))


func _draw_exit_labels(exits: Dictionary) -> void:
	var seen: Dictionary = {}

	for exit_id_value: Variant in exits.keys():
		var exit_id := String(exit_id_value)
		var entry: Dictionary = exits[exit_id]
		var node: Node3D = entry.get("node")

		if node == null or not is_instance_valid(node):
			continue

		seen[exit_id] = true
		var label: Label3D = _labels.get(exit_id)

		if label == null:
			label = Label3D.new()
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.font_size = 48
			label.pixel_size = 0.0035
			label.outline_size = 10
			label.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			add_child(label)
			_labels[exit_id] = label

		var status: Dictionary = entry.get("status", {})
		var assigned: int = int(_result.exit_counts.get(exit_id, 0))
		var queue: int = int(status.get("current_queue", 0))
		var queue_cap: int = int(status.get("max_queue_length", 0))
		var capacity: int = int(status.get("receiving_capacity", 0))
		var rate: float = float(status.get("service_rate", 0.0))
		var queue_text := str(queue) if queue_cap <= 0 else "%d/%d" % [queue, queue_cap]
		var cap_text := "inf" if capacity <= 0 else str(capacity)
		var rate_text := "inf" if rate <= 0.0 else "%.1f/s" % rate

		label.text = "%s\nassigned %d\nqueue %s  cap %s  %s" % [
			exit_id,
			assigned,
			queue_text,
			cap_text,
			rate_text,
		]
		label.modulate = _exit_color(exit_id)
		label.global_position = node.global_position + Vector3(
			0.0, LABEL_HEIGHT, 0.0
		)

	for exit_id_value: Variant in _labels.keys():
		var exit_id := String(exit_id_value)

		if seen.has(exit_id):
			continue

		var label: Label3D = _labels[exit_id]

		if is_instance_valid(label):
			label.queue_free()

		_labels.erase(exit_id)


func _clear_labels() -> void:
	for label: Variant in _labels.values():
		if is_instance_valid(label):
			(label as Label3D).queue_free()

	_labels.clear()


func _live_exits() -> Dictionary:
	var result: Dictionary = {}

	if not is_inside_tree():
		return result

	var tree: SceneTree = get_tree()

	if tree == null:
		return result

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if not node is Node3D or not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")
		var exit_id := String(status.get("exit_id", ""))

		if exit_id.is_empty() or result.has(exit_id):
			continue

		if not bool(status.get("available", false)):
			continue

		result[exit_id] = {
			"node": node,
			"position": (node as Node3D).global_position,
			"status": status,
		}

	return result


func _exit_color(exit_id: String) -> Color:
	var hue: float = fmod(abs(float(hash(exit_id))) * 0.61803398875, 1.0)
	return Color.from_hsv(hue, 0.72, 1.0, 1.0)


func _point(value: Variant, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value

	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return fallback
