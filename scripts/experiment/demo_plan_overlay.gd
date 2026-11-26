class_name DemoPlanOverlay
extends Node3D

## Reconstructed optimizer plan for playback.
##
## The Demo Player and Demo Comparer do not re-run the optimizer. This node reads
## the `optimizer` events (cohort -> exit), the `route` events (the path each
## agent actually walked) and the recorded exit positions, and draws:
##   - a coloured cohort -> exit line per assignment;
##   - the recorded route polyline for each cohort's representative agent;
##   - an exit label with the assigned count at that moment.
##
## A route polyline may be absent (flow-field runs). The line is then drawn as a
## straight cohort -> exit stem and the legend says "assignment only".

const MAX_ROUTES: int = 80

var _enabled: bool = false
var _show_routes: bool = true
var _routes: Dictionary = {}          # serial -> Array[route event]
var _optimizer_events: Array = []
var _exit_positions: Dictionary = {}  # exit_id -> Vector3
var _line_mesh: MeshInstance3D = null
var _label_root: Node3D = null
var _material: StandardMaterial3D = null
var _last_time: float = -INF
var _last_event_index: int = -1
var _last_exit_signature: String = ""
var _vertex_count: int = 0


func configure(
	routes: Dictionary,
	optimizer_events: Array,
	exit_positions: Dictionary
) -> void:
	_routes = routes
	_optimizer_events = optimizer_events
	_exit_positions = exit_positions
	_last_time = -INF
	_last_event_index = -1
	_ensure_nodes()
	_rebuild(0.0)


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value

	if value:
		_rebuild(_last_time if _last_time > -INF else 0.0)


func set_show_routes(value: bool) -> void:
	if _show_routes == value:
		return

	_show_routes = value
	_last_time = -INF


func is_enabled() -> bool:
	return _enabled


func set_time(time: float) -> void:
	_last_time = time
	_rebuild(time)


func _ensure_nodes() -> void:
	if _line_mesh != null and is_instance_valid(_line_mesh):
		return

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.no_depth_test = true
	_material.albedo_color = Color.WHITE
	_material.vertex_color_use_as_albedo = true
	_line_mesh = MeshInstance3D.new()
	_line_mesh.name = "PlanLines"
	_line_mesh.material_override = _material
	add_child(_line_mesh)

	_label_root = Node3D.new()
	_label_root.name = "PlanLabels"
	add_child(_label_root)


func _rebuild(time: float) -> void:
	if not _enabled:
		return

	if _line_mesh == null or not is_instance_valid(_line_mesh):
		_ensure_nodes()

	var event_index := _latest_event_index(time)
	var exit_signature := _exit_signature()

	if (
		event_index == _last_event_index
		and exit_signature == _last_exit_signature
		and absf(time - _last_time) < 0.4
	):
		return

	_last_event_index = event_index
	_last_exit_signature = exit_signature
	_last_time = time
	_clear_labels()

	_vertex_count = 0
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _material)

	if event_index >= 0:
		var detail: Dictionary = _optimizer_events[event_index].get("detail", {})
		var cohorts: Array = detail.get("cohorts", [])

		for cohort_value: Variant in cohorts:
			if not cohort_value is Dictionary:
				continue

			var cohort: Dictionary = cohort_value
			var exit_id := String(cohort.get("exit_id", ""))
			var color := _exit_color(exit_id)
			var start := _point(cohort.get("position", []), Vector3.ZERO)
			var finish: Vector3 = _exit_positions.get(exit_id, Vector3.ZERO)

			if start == Vector3.ZERO or finish == Vector3.ZERO:
				continue

			_add_line(mesh, start + Vector3.UP * 0.25, finish + Vector3.UP * 0.25, color, true)

			if _show_routes:
				var route: Array = cohort.get("route", [])

				if route.size() < 2:
					for serial_value: Variant in cohort.get("members", []):
						var snapshot := _latest_route(int(serial_value), time)

						if not snapshot.is_empty() and (snapshot.get("path", []) as Array).size() >= 2:
							route = snapshot.get("path", [])
							break

				if route.size() >= 2:
					_add_polyline(mesh, route, color)
				else:
					# Flow-field or old recording: the straight stem is the only
					# honest representation of the assignment.
					_add_line(mesh, start + Vector3.UP * 0.2, finish + Vector3.UP * 0.2, color, false)

		_build_labels(cohorts, time)
	else:
		# Old recording without an optimizer event: draw the recorded
		# optimizer-labelled routes directly, capped so the view stays legible.
		var drawn := 0

		for serial_value: Variant in _routes.keys():
			var route := _latest_route(int(serial_value), time)

			if route.is_empty() or String(route.get("reason", "")) not in ["optimizer", "plan"]:
				continue

			var path: Array = route.get("path", [])

			if path.size() < 2:
				continue

			_add_polyline(mesh, path, _exit_color(String(route.get("exit_id", ""))))
			drawn += 1

			if drawn >= MAX_ROUTES:
				break

	if _vertex_count > 0:
		mesh.surface_end()
		_line_mesh.mesh = mesh
		_line_mesh.visible = true
	else:
		_line_mesh.mesh = null
		_line_mesh.visible = false


func _latest_event_index(time: float) -> int:
	var index := -1

	for i: int in range(_optimizer_events.size()):
		var event: Dictionary = _optimizer_events[i]

		if float(event.get("t", 0.0)) <= time + 0.001:
			index = i
		else:
			break

	return index


func _latest_route(serial: int, time: float) -> Dictionary:
	var list: Array = _routes.get(serial, [])
	var latest: Dictionary = {}

	for route: Dictionary in list:
		if float(route.get("t", 0.0)) <= time + 0.001:
			latest = route
		else:
			break

	return latest


func _build_labels(cohorts: Array, _time: float) -> void:
	var assigned: Dictionary = {}

	for cohort_value: Variant in cohorts:
		if cohort_value is Dictionary:
			var exit_id := String((cohort_value as Dictionary).get("exit_id", ""))
			assigned[exit_id] = int(assigned.get(exit_id, 0)) + int(
				(cohort_value as Dictionary).get("count", 0)
			)

	for exit_id_value: Variant in assigned.keys():
		var exit_id := String(exit_id_value)
		var exit_position: Vector3 = _exit_positions.get(exit_id, Vector3.ZERO)

		if exit_position == Vector3.ZERO:
			continue

		var label := Label3D.new()
		label.text = "%s  assigned %d" % [exit_id, int(assigned[exit_id])]
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.pixel_size = 0.0025
		label.font_size = 28
		label.modulate = _exit_color(exit_id)
		label.position = exit_position + Vector3.UP * 1.8
		_label_root.add_child(label)


func _clear_labels() -> void:
	if _label_root == null or not is_instance_valid(_label_root):
		return

	for child: Node in _label_root.get_children():
		child.queue_free()


func _exit_signature() -> String:
	var keys: Array[String] = []

	for key: Variant in _exit_positions.keys():
		keys.append(String(key))

	keys.sort()
	return ",".join(keys)


func _add_line(
	mesh: ImmediateMesh,
	from: Vector3,
	to: Vector3,
	color: Color,
	_stem: bool
) -> void:
	var steps: int = maxi(1, int(ceil(from.distance_to(to) / 1.5)))

	for index: int in range(steps):
		var a := from.lerp(to, float(index) / float(steps))
		var b := from.lerp(to, float(index + 1) / float(steps))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(a)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(b)
		_vertex_count += 2


func _add_polyline(mesh: ImmediateMesh, points: Array, color: Color) -> void:
	var previous := _point(points[0], Vector3.ZERO)

	if previous == Vector3.ZERO:
		return

	for index: int in range(1, points.size()):
		var current := _point(points[index], Vector3.ZERO)

		if current == Vector3.ZERO:
			continue

		_add_line(mesh, previous + Vector3.UP * 0.3, current + Vector3.UP * 0.3, color, false)
		previous = current


func _point(value: Variant, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value

	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return fallback


func _exit_color(exit_id: String) -> Color:
	if exit_id.is_empty():
		return Color(0.8, 0.8, 0.8)

	var hue := float(abs(hash(exit_id)) % 360) / 360.0
	return Color.from_hsv(hue, 0.65, 1.0, 0.95)
