extends Node

## Demo Comparer: synchronized playback and metric comparison across two or more
## recordings from the active save.
##
## Opened from the pause menu's Demos tab via Compare. The tree stays paused;
## this node and its CanvasLayer use PROCESS_MODE_ALWAYS. Every recording is
## aligned on run-relative simulation time (tick `sim.elapsed`), so t = 0 is the
## start of each run regardless of when it was captured. The comparer only reads
## the structured demo files, never live NPCs or rendered state.

signal closed

const FONT: Font = preload("res://font/dogicapixel.ttf")
const COLORS: Array[Color] = [
	Color(1.0, 0.84, 0.34),
	Color(0.36, 0.80, 1.0),
	Color(1.0, 0.46, 0.78),
	Color(0.52, 1.0, 0.56),
	Color(1.0, 0.63, 0.30),
	Color(0.86, 0.86, 0.94),
]
const LETTERS: Array[String] = ["A", "B", "C", "D", "E", "F"]
const MAX_COMPARE := 6
const THROUGHPUT_WINDOW := 5.0
const MAX_CHART_POINTS := 260
const NOCLIP_BASE_SPEED := 10.0
const NOCLIP_LOOK_SENSITIVITY := 0.004
const NOCLIP_MIN_MULT := 0.2
const NOCLIP_MAX_MULT := 10.0
const NOCLIP_HOLD_RESET_TIME := 0.4
const BG := Color(0.055, 0.05, 0.045, 0.94)
const PANEL := Color(0.10, 0.09, 0.08, 0.96)
const GOLD := Color(1.0, 0.84, 0.34, 1.0)
const TEXT := Color(0.92, 0.93, 0.9, 1.0)
const MUTED := Color(0.68, 0.68, 0.64, 1.0)

var _active: bool = false
var _demos: Array = []
var _duration: float = 0.0
var _time: float = 0.0
var _speed: float = 1.0
var _playing: bool = true

var _world: Node3D = null
var _camera: Camera3D = null
var _saved_camera_transform: Transform3D = Transform3D.IDENTITY
var _saved_camera_fov: float = 75.0
var _saved_camera_current: bool = true
var _overview_transform: Transform3D = Transform3D.IDENTITY
var _noclip: bool = false
var _noclip_speed_mult: float = 1.0
var _noclip_yaw: float = 0.0
var _noclip_pitch: float = 0.0
var _noclip_hold_active: bool = false
var _noclip_hold_elapsed: float = 0.0
var _noclip_hold_reset_done: bool = false

var _layer: CanvasLayer = null
var _ui: Control = null
var _title: Label = null
var _state_label: Label = null
var _play_button: Button = null
var _speed_button: Button = null
var _noclip_button: Button = null
var _timeline: HSlider = null
var _time_label: Label = null
var _recordings_box: VBoxContainer = null
var _chart: ChartBoard = null
var _values_box: VBoxContainer = null
var _deltas_box: VBoxContainer = null
var _value_labels: Array = []
var _delta_labels: Array = []
var _differences_toggle: CheckButton = null
var _differences: RichTextLabel = null

var _ui_accum: float = 0.0
var _chart_accum: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	_build_ui()
	_ui.visible = false


func is_active() -> bool:
	return _active


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func play(demo_ids: Array) -> bool:
	if _active:
		close()

	if demo_ids.size() < 2:
		return false

	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return false

	var active_slug: String = String(store.call("active_save_slug"))
	var loaded: Array = []

	for raw_id: Variant in demo_ids:
		var demo_id := String(raw_id)
		var meta: Dictionary = store.call("get_demo", demo_id)

		if meta.is_empty():
			continue

		if String(meta.get("save_slug", "")) != active_slug:
			continue

		var path: String = String(store.call("recording_path", demo_id))

		if not FileAccess.file_exists(path):
			continue

		var data := _load_recording(path)

		if data.is_empty():
			continue

		data["id"] = demo_id
		data["meta"] = meta
		data["name"] = String(meta.get("name", demo_id))
		data["description"] = String(meta.get("description", ""))
		var experiment: Dictionary = meta.get("experiment", {})

		if experiment.is_empty():
			# demo.json only gains `experiment` when a run finalises. Fall back
			# to the run header so an in-progress or older demo still compares.
			experiment = data.get("experiment", {})

		data["experiment"] = experiment
		loaded.append(data)

	if loaded.size() < 2:
		return false

	_demos = loaded
	_duration = 0.0

	for index in _demos.size():
		var demo: Dictionary = _demos[index]
		demo["index"] = index
		demo["letter"] = LETTERS[index % LETTERS.size()]
		demo["color"] = COLORS[index % COLORS.size()]
		demo["visible"] = true
		demo["exit_names"] = _exit_names(demo)
		_duration = maxf(_duration, float(demo.get("duration", 0.0)))

	if _duration <= 0.0:
		_demos = []
		return false

	_time = 0.0
	_speed = 1.0
	_playing = true
	_ui_accum = 0.0
	_chart_accum = 0.0
	_noclip = false
	_noclip_speed_mult = 1.0
	_noclip_hold_active = false
	_noclip_hold_elapsed = 0.0
	_noclip_hold_reset_done = false
	_active = true
	_ui.visible = true
	_play_button.text = "Pause"
	_speed_button.text = "Speed 1x"
	_noclip_button.text = "Noclip"
	_title.text = "DEMO COMPARER  ·  %d RECORDINGS" % _demos.size()
	_timeline.min_value = 0.0
	_timeline.max_value = _duration
	_timeline.step = 0.01
	_timeline.set_value_no_signal(0.0)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_world()
	_setup_camera()
	_build_recordings_ui()
	_build_charts()
	_update_scene()
	_update_text(true)
	set_process(true)
	return true


func close() -> void:
	if not _active:
		return

	_active = false
	_playing = false
	_noclip = false
	_noclip_hold_active = false
	_noclip_hold_elapsed = 0.0
	_noclip_hold_reset_done = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	set_process(false)
	_clear_world()
	_restore_camera()
	_ui.visible = false
	_demos = []
	closed.emit()


func _process(delta: float) -> void:
	if not _active:
		return

	if _world == null or not is_instance_valid(_world):
		close()
		return

	if _noclip:
		_update_noclip(delta)

	_update_noclip_hold(delta)

	if _playing:
		_time = minf(_duration, _time + delta * _speed)

		if _time >= _duration:
			_playing = false
			_play_button.text = "Play"

	_update_scene()
	_ui_accum += delta
	_chart_accum += delta

	if _ui_accum >= 0.2:
		_ui_accum = 0.0
		_update_text(false)

	if _chart_accum >= 0.1:
		_chart_accum = 0.0

		if _chart != null:
			_chart.set_cursor(_time)


func _input(event: InputEvent) -> void:
	if not _active:
		return

	if event.is_action_pressed("ui_noclip"):
		get_viewport().set_input_as_handled()
		_begin_noclip_hold()
		return

	if event.is_action_released("ui_noclip"):
		get_viewport().set_input_as_handled()
		_end_noclip_hold()
		return

	if _noclip and _camera != null and is_instance_valid(_camera):
		if (
			event is InputEventMouseMotion
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
		):
			_noclip_yaw -= event.relative.x * NOCLIP_LOOK_SENSITIVITY
			_noclip_pitch = clampf(
				_noclip_pitch - event.relative.y * NOCLIP_LOOK_SENSITIVITY,
				deg_to_rad(-89.0),
				deg_to_rad(89.0)
			)
			_camera.global_rotation = Vector3(_noclip_pitch, _noclip_yaw, 0.0)
			get_viewport().set_input_as_handled()
			return

		if (
			event is InputEventMouseButton
			and event.pressed
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
		):
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_noclip_speed_mult = minf(
					_noclip_speed_mult + 0.2,
					NOCLIP_MAX_MULT
				)
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_noclip_speed_mult = maxf(
					_noclip_speed_mult - 0.2,
					NOCLIP_MIN_MULT
				)
				get_viewport().set_input_as_handled()
			return

	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


# ---------------------------------------------------------------------------
# Noclip camera
# ---------------------------------------------------------------------------

## Tap to toggle free flight; hold to return the camera to the overview shot,
## matching the Demo Player.
func _set_noclip(enabled: bool) -> void:
	if enabled == _noclip:
		return

	if enabled and (_camera == null or not is_instance_valid(_camera)):
		return

	_noclip = enabled

	if enabled:
		var rotation: Vector3 = _camera.global_rotation
		_noclip_yaw = rotation.y
		_noclip_pitch = rotation.x
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if _noclip_button != null:
		_noclip_button.text = "Noclip: On" if _noclip else "Noclip"

	_update_text(true)


func _begin_noclip_hold() -> void:
	_noclip_hold_active = true
	_noclip_hold_elapsed = 0.0
	_noclip_hold_reset_done = false


func _end_noclip_hold() -> void:
	if not _noclip_hold_active:
		return

	var was_hold: bool = _noclip_hold_reset_done
	_noclip_hold_active = false
	_noclip_hold_elapsed = 0.0
	_noclip_hold_reset_done = false

	if was_hold:
		_update_text(true)
		return

	_set_noclip(not _noclip)


func _update_noclip_hold(delta: float) -> void:
	if not _noclip_hold_active:
		return

	_noclip_hold_elapsed += delta

	if _noclip_hold_reset_done or _noclip_hold_elapsed < NOCLIP_HOLD_RESET_TIME:
		return

	_noclip_hold_reset_done = true
	_reset_camera_view()
	_update_text(true)


func _reset_camera_view() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return

	_camera.global_transform = _overview_transform
	_camera.current = true
	var rotation: Vector3 = _camera.global_rotation
	_noclip_yaw = rotation.y
	_noclip_pitch = rotation.x


func _update_noclip(delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return

	var input_dir: Vector2 = Input.get_vector("left", "right", "up", "down")
	var wish: Vector3 = _camera.global_transform.basis * Vector3(
		input_dir.x,
		0.0,
		input_dir.y
	)

	if wish.length_squared() > 0.0001:
		wish = wish.normalized()

	var vertical: float = 0.0

	if Input.is_action_pressed("jump"):
		vertical += 1.0

	if Input.is_action_pressed("crouch"):
		vertical -= 1.0

	if wish.length_squared() <= 0.0001 and is_zero_approx(vertical):
		return

	var speed: float = NOCLIP_BASE_SPEED * _noclip_speed_mult
	_camera.global_position += (wish + Vector3.UP * vertical) * speed * delta


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

func _load_recording(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return {}

	var ticks: Array = []
	var events: Array = []
	var start_t := 0.0
	var have_start := false
	var run_record: Dictionary = {}

	while not file.eof_reached():
		var line := file.get_line()

		if line.strip_edges().is_empty():
			continue

		var parsed: Variant = JSON.parse_string(line)

		if not parsed is Dictionary:
			continue

		var obj: Dictionary = parsed
		var type := String(obj.get("type", ""))

		if type == "run":
			start_t = float(obj.get("t", 0.0))
			have_start = true
			run_record = obj
		elif type == "tick":
			ticks.append(obj)
		elif type in [
			"agent_spawn", "destination", "evacuation", "agent_death",
			"route", "route_change", "queue", "contact", "environment",
			"disruption", "exit_state", "exit_added", "exit_removed", "end",
		]:
			events.append(obj)

	file.close()

	if ticks.is_empty():
		return {}

	if not have_start:
		start_t = float(ticks[0].get("t", 0.0))

	var times: Array = []
	var tick_maps: Array = []

	for tick: Dictionary in ticks:
		var sim: Dictionary = tick.get("sim", {})
		var rel := float(sim.get("elapsed", float(tick.get("t", 0.0)) - start_t))
		times.append(rel)
		var map: Dictionary = {}

		for row: Variant in tick.get("agents", []):
			if row is Array and row.size() >= 4:
				map[int(row[0])] = row

		tick_maps.append(map)

	var evacuation_times: Array = []
	var route_times: Array = []
	var disruptions: Array = []

	for event: Dictionary in events:
		event["_rel"] = float(event.get("t", 0.0)) - start_t

	for event: Dictionary in events:
		var type := String(event.get("type", ""))

		if type == "evacuation":
			evacuation_times.append(float(event["_rel"]))
		elif type == "route" or type == "route_change":
			if String(event.get("reason", "")) != "snapshot":
				route_times.append(float(event["_rel"]))
		elif type == "environment":
			# A linked disruption record carries the same edit plus the
			# affected/rerouted attribution; keep only that one.
			if String(event.get("disruption_id", "")).is_empty():
				disruptions.append(event)
		elif type == "disruption":
			disruptions.append(event)

	evacuation_times.sort()
	route_times.sort()

	var series: Dictionary = {
		"evacuated": [],
		"active": [],
		"density": [],
		"throughput": [],
		"contact": [],
		"routes": [],
	}
	var accepted_history: Array = []
	var evac_index := 0
	var route_index := 0
	var contact_peak := 0.0
	var peak_active := 0

	for index in ticks.size():
		var rel := float(times[index])
		var tick: Dictionary = ticks[index]

		while (
			evac_index < evacuation_times.size()
			and float(evacuation_times[evac_index]) <= rel
		):
			evac_index += 1

		while (
			route_index < route_times.size()
			and float(route_times[route_index]) <= rel
		):
			route_index += 1

		var sim: Dictionary = tick.get("sim", {})
		var active := int(sim.get("active", tick.get("agents", []).size()))
		var accepted := 0
		peak_active = maxi(peak_active, active)

		for row: Variant in tick.get("exits", []):
			if row is Array and row.size() > 4:
				accepted += int(row[4])

		contact_peak = maxf(
			contact_peak,
			float(sim.get("peak_contact_force", 0.0))
		)

		accepted_history.append(Vector2(rel, float(accepted)))
		series["evacuated"].append(Vector2(rel, float(evac_index)))
		series["active"].append(Vector2(rel, float(active)))
		series["density"].append(Vector2(rel, float(sim.get("density_mean", 0.0))))
		series["contact"].append(Vector2(rel, contact_peak / 1000.0))
		series["routes"].append(Vector2(rel, float(route_index)))

	var history_index := 0

	for index in ticks.size():
		var rel := float(times[index])

		while (
			history_index < accepted_history.size()
			and float(accepted_history[history_index].x) < rel - THROUGHPUT_WINDOW
		):
			history_index += 1

		var base := 0.0

		if history_index > 0:
			base = float(accepted_history[history_index - 1].y)

		var accepted_now := float(accepted_history[index].y)
		var value := (accepted_now - base) / THROUGHPUT_WINDOW
		series["throughput"].append(Vector2(rel, maxf(value, 0.0)))

	var duration := float(times[times.size() - 1]) if not times.is_empty() else 0.0

	if duration <= 0.0:
		return {}

	for key: Variant in series:
		series[key] = _downsample(series[key])

	return {
		"ticks": ticks,
		"times": times,
		"tick_maps": tick_maps,
		"events": events,
		"evacuation_times": evacuation_times,
		"route_times": route_times,
		"disruptions": disruptions,
		"series": series,
		"duration": duration,
		"start_t": start_t,
		"run": run_record,
		"experiment": run_record.get("metadata", {}),
		"peak_active": peak_active,
	}


func _downsample(points: Array) -> Array:
	if points.size() <= MAX_CHART_POINTS:
		return points

	var stride := int(ceil(float(points.size()) / float(MAX_CHART_POINTS)))
	var result: Array = []

	for index in range(0, points.size(), stride):
		result.append(points[index])

	if not result.is_empty() and result[result.size() - 1] != points[points.size() - 1]:
		result.append(points[points.size() - 1])

	return result


func _exit_names(demo: Dictionary) -> Dictionary:
	var names: Dictionary = {}
	var run: Dictionary = demo.get("run", {})

	for entry: Variant in run.get("exits", []):
		if entry is Dictionary:
			names[String(entry.get("exit_id", ""))] = String(entry.get("name", ""))

	var experiment: Dictionary = demo.get("experiment", demo.get("meta", {}).get("experiment", {}))

	for entry: Variant in experiment.get("exit_configuration", []):
		if entry is Dictionary:
			names[String(entry.get("exit_id", ""))] = String(entry.get("name", ""))

	return names


# ---------------------------------------------------------------------------
# World representation
# ---------------------------------------------------------------------------

func _build_world() -> void:
	_clear_world()
	var scene := get_tree().current_scene

	if scene == null:
		return

	_world = Node3D.new()
	_world.name = "DemoComparerWorld"
	scene.add_child(_world)

	for demo: Dictionary in _demos:
		var root := Node3D.new()
		root.name = "Demo_%s" % String(demo["letter"])
		_world.add_child(root)
		demo["root"] = root

		var mesh := SphereMesh.new()
		mesh.radius = 0.26
		mesh.height = 0.52
		mesh.radial_segments = 8
		mesh.rings = 5

		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(demo["color"], 0.82)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		var proxies: Dictionary = {}

		for tick_map: Dictionary in demo["tick_maps"]:
			for serial_key: Variant in tick_map:
				var serial := int(serial_key)

				if proxies.has(serial):
					continue

				var node := MeshInstance3D.new()
				node.name = "Agent_%d" % serial
				node.mesh = mesh
				node.material_override = material
				root.add_child(node)
				proxies[serial] = node

		demo["proxies"] = proxies


func _clear_world() -> void:
	if _world != null and is_instance_valid(_world):
		_world.queue_free()

	_world = null

	for demo: Dictionary in _demos:
		demo.erase("root")
		demo.erase("proxies")


func _update_scene() -> void:
	for demo: Dictionary in _demos:
		var root: Node3D = demo.get("root")

		if root == null or not is_instance_valid(root):
			continue

		root.visible = bool(demo.get("visible", true))

		if not root.visible:
			continue

		var index := _tick_index(demo, _time)

		if index < 0:
			continue

		var maps: Array = demo["tick_maps"]
		var times: Array = demo["times"]
		var map: Dictionary = maps[index]
		var next_map: Dictionary = maps[mini(index + 1, maps.size() - 1)]
		var t0 := float(times[index])
		var t1 := float(times[mini(index + 1, times.size() - 1)])
		var alpha := 0.0 if t1 <= t0 else clampf((_time - t0) / (t1 - t0), 0.0, 1.0)
		var proxies: Dictionary = demo.get("proxies", {})

		for serial_key: Variant in proxies:
			var node: MeshInstance3D = proxies[serial_key]
			var row: Variant = map.get(serial_key)

			if row == null:
				node.visible = false
				continue

			node.visible = true
			var position := Vector3(float(row[3]), float(row[4]), float(row[5]))
			var following: Variant = next_map.get(serial_key)

			if following != null:
				position = position.lerp(
					Vector3(
						float(following[3]),
						float(following[4]),
						float(following[5])
					),
					alpha
				)

			node.position = position + Vector3(0, 0.28, 0)


func _tick_index(demo: Dictionary, rel: float) -> int:
	var times: Array = demo.get("times", [])

	if times.is_empty():
		return -1

	var low := 0
	var high := times.size() - 1

	while low < high:
		var middle := int((low + high + 1) / 2.0)

		if float(times[middle]) <= rel:
			low = middle
		else:
			high = middle - 1

	return low


func _map_at(demo: Dictionary, rel: float) -> Dictionary:
	var index := _tick_index(demo, rel)

	if index < 0:
		return {}

	return demo["tick_maps"][index]


# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------

func _setup_camera() -> void:
	_camera = get_viewport().get_camera_3d()

	if _camera == null:
		return

	_saved_camera_transform = _camera.global_transform
	_saved_camera_fov = _camera.fov
	_saved_camera_current = _camera.current
	_overview_transform = _camera.global_transform

	var min_point := Vector3(INF, INF, INF)
	var max_point := Vector3(-INF, -INF, -INF)
	var found := false

	for demo: Dictionary in _demos:
		for tick_map: Dictionary in demo["tick_maps"]:
			for row: Variant in tick_map.values():
				var point := Vector3(float(row[3]), float(row[4]), float(row[5]))
				min_point = min_point.min(point)
				max_point = max_point.max(point)
				found = true

	if not found:
		return

	var center: Vector3 = (min_point + max_point) * 0.5
	var span: float = maxf(maxf(
		max_point.x - min_point.x,
		max_point.z - min_point.z
	), 16.0)
	var height: float = maxf(span * 2.1, 26.0)
	_camera.global_position = center + Vector3(span * 0.65, height, span * 0.65)
	_camera.look_at(center, Vector3.UP)
	_camera.current = true
	_overview_transform = _camera.global_transform


func _restore_camera() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return

	_camera.global_transform = _saved_camera_transform
	_camera.fov = _saved_camera_fov
	_camera.current = _saved_camera_current
	_camera = null


# ---------------------------------------------------------------------------
# Current values and differences
# ---------------------------------------------------------------------------

func _series_value(series: Array, t: float) -> float:
	if series.is_empty():
		return 0.0

	var low := 0
	var high := series.size() - 1

	while low < high:
		var middle := int((low + high + 1) / 2.0)

		if float(series[middle].x) <= t:
			low = middle
		else:
			high = middle - 1

	var point: Vector2 = series[low]

	if low >= series.size() - 1:
		return point.y

	var next: Vector2 = series[low + 1]

	if next.x <= point.x:
		return point.y

	var alpha := clampf((t - point.x) / (next.x - point.x), 0.0, 1.0)
	return lerpf(point.y, next.y, alpha)


func _series_step(series: Array, t: float) -> float:
	if series.is_empty():
		return 0.0

	var low := 0
	var high := series.size() - 1

	while low < high:
		var middle := int((low + high + 1) / 2.0)

		if float(series[middle].x) <= t:
			low = middle
		else:
			high = middle - 1

	return float(series[low].y)


func _sample_values(demo: Dictionary, t: float) -> Dictionary:
	var series: Dictionary = demo["series"]
	return {
		"evacuated": _series_step(series["evacuated"], t),
		"active": _series_value(series["active"], t),
		"density": _series_value(series["density"], t),
		"throughput": _series_value(series["throughput"], t),
		"contact": _series_step(series["contact"], t),
		"routes": _series_step(series["routes"], t),
	}


func _positions_at(demo: Dictionary, rel: float) -> Dictionary:
	var index := _tick_index(demo, rel)
	var positions: Dictionary = {}

	if index < 0:
		return positions

	var maps: Array = demo["tick_maps"]
	var times: Array = demo["times"]
	var map: Dictionary = maps[index]
	var next_map: Dictionary = maps[mini(index + 1, maps.size() - 1)]
	var t0 := float(times[index])
	var t1 := float(times[mini(index + 1, times.size() - 1)])
	var alpha := 0.0 if t1 <= t0 else clampf((rel - t0) / (t1 - t0), 0.0, 1.0)

	for serial: Variant in map:
		var row: Variant = map[serial]
		var position := Vector3(float(row[3]), float(row[4]), float(row[5]))
		var following: Variant = next_map.get(serial)

		if following != null:
			position = position.lerp(
				Vector3(
					float(following[3]),
					float(following[4]),
					float(following[5])
				),
				alpha
			)

		positions[serial] = position

	return positions


func _update_text(force: bool) -> void:
	if _demos.is_empty():
		return

	var state := "PLAYING" if _playing else "PAUSED"
	_time_label.text = "t %.2f / %.2f s" % [_time, _duration]
	_state_label.text = "%s  ·  %d recordings" % [state, _demos.size()]

	if _noclip:
		_state_label.text += "  ·  NOCLIP %.1f m/s" % (
			NOCLIP_BASE_SPEED * _noclip_speed_mult
		)

	var values_list: Array = []
	var base: Dictionary = _sample_values(_demos[0], _time)

	for demo: Dictionary in _demos:
		values_list.append(_sample_values(demo, _time))

	_update_metric_tables(values_list, base)
	_differences.text = _build_differences()


func _build_differences() -> String:
	var lines: Array[String] = []
	var maps: Array = []
	var positions: Array = []

	for demo: Dictionary in _demos:
		maps.append(_map_at(demo, _time))
		positions.append(_positions_at(demo, _time))

	lines.append("[color=#f5d45a]TRAJECTORIES[/color]")

	for index in range(1, _demos.size()):
		var stats := _divergence(positions[0], positions[index])
		var letter_a := String(_demos[0]["letter"])
		var letter_b := String(_demos[index]["letter"])

		if int(stats["common"]) == 0:
			lines.append("%s vs %s: no shared agents at this time" % [letter_a, letter_b])
			continue

		var line := "%s vs %s · %d shared · mean %.2f m · max %.2f m · %d over 2 m" % [
			letter_a,
			letter_b,
			int(stats["common"]),
			float(stats["mean"]),
			float(stats["max"]),
			int(stats["over"]),
		]
		lines.append(line)

		if not stats["worst"].is_empty():
			var worst_parts: Array[String] = []

			for entry: Array in stats["worst"]:
				worst_parts.append("#%d %.2f m" % [int(entry[0]), float(entry[1])])

			lines.append("  worst " + " · ".join(PackedStringArray(worst_parts)))

	lines.append("")
	lines.append("[color=#f5d45a]EXIT ASSIGNMENTS[/color]")

	for index in _demos.size():
		var demo: Dictionary = _demos[index]
		var counts := _assignment_counts(maps[index])
		var parts: Array[String] = []

		for exit_id: Variant in counts:
			parts.append("%d %s" % [int(counts[exit_id]), _exit_label(demo, String(exit_id))])

		parts.sort()
		lines.append("%s  %s" % [
			String(demo["letter"]),
			" · ".join(PackedStringArray(parts)) if not parts.is_empty() else "no assignments",
		])

	for index in range(1, _demos.size()):
		var shared := 0
		var differing := 0

		for serial: Variant in maps[0]:
			var row_a: Variant = maps[0][serial]
			var row_b: Variant = maps[index].get(serial)

			if row_b == null:
				continue

			shared += 1

			if String(row_a[16]) != String(row_b[16]):
				differing += 1

		if shared > 0:
			lines.append("common agents with a different exit  %s/%s: %d / %d" % [
				String(_demos[0]["letter"]),
				String(_demos[index]["letter"]),
				differing,
				shared,
			])

	lines.append("")
	lines.append("[color=#f5d45a]DISRUPTION RESPONSES[/color]")

	for demo: Dictionary in _demos:
		var disruptions: Array = demo["disruptions"]

		if disruptions.is_empty():
			lines.append("%s  none recorded" % String(demo["letter"]))
			continue

		for event: Dictionary in disruptions.slice(maxi(0, disruptions.size() - 4)):
			var kind := String(event.get("kind", event.get("type", "event")))
			var affected := int(event.get("affected_count", 0))
			var rerouted := int(event.get("rerouted", 0))
			lines.append("%s  %.1f s  %s  affected %d  rerouted %d" % [
				String(demo["letter"]),
				float(event.get("_rel", 0.0)),
				kind,
				affected,
				rerouted,
			])

	var base_disruptions: Array = _demos[0]["disruptions"]

	for index in range(1, _demos.size()):
		var other: Array = _demos[index]["disruptions"]
		var paired: Array[String] = []

		for event: Dictionary in base_disruptions:
			var rel := float(event.get("_rel", 0.0))
			var best: Dictionary = {}
			var best_gap := 2.0

			for candidate: Dictionary in other:
				var gap: float = absf(float(candidate.get("_rel", 0.0)) - rel)

				if gap <= best_gap:
					best_gap = gap
					best = candidate

			if best.is_empty():
				continue

			paired.append("%.1f s → rerouted %d vs %d" % [
				rel,
				int(event.get("rerouted", 0)),
				int(best.get("rerouted", 0)),
			])

		if not paired.is_empty():
			lines.append("%s/%s response pairs: %s" % [
				String(_demos[0]["letter"]),
				String(_demos[index]["letter"]),
				" · ".join(PackedStringArray(paired)),
			])

	lines.append("")
	lines.append("[color=#f5d45a]ENVIRONMENT EDITS[/color]")

	for demo: Dictionary in _demos:
		var edits := _environment_summary(demo)

		if int(edits["total"]) == 0:
			lines.append("%s  no block edits recorded" % String(demo["letter"]))
			continue

		lines.append("%s  placed %d cells / %d edits · broke %d cells / %d edits · %d other" % [
			String(demo["letter"]),
			int(edits["added_cells"]),
			int(edits["added_edits"]),
			int(edits["removed_cells"]),
			int(edits["removed_edits"]),
			int(edits["other"]),
		])

		for entry: Dictionary in edits["recent"]:
			lines.append("  %.1f s  %s" % [float(entry["t"]), String(entry["text"])])

	lines.append("")
	lines.append("[color=#f5d45a]CONFIGURATION DIFFERENCES[/color]")
	lines.append_array(_config_differences())

	lines.append("")
	lines.append("[color=#f5d45a]FINAL SUMMARIES[/color]")

	for demo: Dictionary in _demos:
		var summary: Dictionary = demo.get("meta", {}).get("summary", {})

		if summary.is_empty():
			var series: Dictionary = demo["series"]
			var evacuated := 0.0
			var active := 0.0
			var density_max := 0.0
			var contact := 0.0

			if not series["evacuated"].is_empty():
				evacuated = float(series["evacuated"][-1].y)

			if not series["active"].is_empty():
				active = float(series["active"][-1].y)

			for point: Vector2 in series["density"]:
				density_max = maxf(density_max, float(point.y))

			if not series["contact"].is_empty():
				contact = float(series["contact"][-1].y)

			lines.append("%s  recording in progress · evacuated %d · active %d · max density %.2f · peak %.1f kN" % [
				String(demo["letter"]),
				int(round(evacuated)),
				int(round(active)),
				density_max,
				contact,
			])
			continue

		lines.append("%s  evacuated %d · avg %.1f s · max density %.2f · peak %.1f kN · disruptions %d" % [
			String(demo["letter"]),
			int(summary.get("agents_evacuated", 0)),
			float(summary.get("average_evacuation_time", 0.0)),
			float(summary.get("global_max_density", 0.0)),
			float(summary.get("peak_contact_force", 0.0)) / 1000.0,
			int(summary.get("disruptions", 0)),
		])

	return "\n".join(PackedStringArray(lines))


func _divergence(a: Dictionary, b: Dictionary) -> Dictionary:
	var common := 0
	var total := 0.0
	var max_distance := 0.0
	var over_two := 0
	var worst: Array = []

	for serial: Variant in a:
		if not b.has(serial):
			continue

		var distance: float = (a[serial] as Vector3).distance_to(b[serial] as Vector3)
		common += 1
		total += distance
		max_distance = maxf(max_distance, distance)

		if distance > 2.0:
			over_two += 1

		worst.append([int(serial), distance])

	worst.sort_custom(func(left: Array, right: Array) -> bool:
		return float(left[1]) > float(right[1])
	)

	return {
		"common": common,
		"mean": total / float(maxi(common, 1)),
		"max": max_distance,
		"over": over_two,
		"worst": worst.slice(0, 3),
	}


func _environment_summary(demo: Dictionary) -> Dictionary:
	var added_cells := 0
	var removed_cells := 0
	var added_edits := 0
	var removed_edits := 0
	var other := 0
	var recent: Array = []

	for event: Dictionary in demo.get("events", []):
		if String(event.get("type", "")) != "environment":
			continue

		var kind := String(event.get("kind", ""))
		var cells := int(event.get("cell_count", 0))
		var item := String(event.get("item_name", ""))
		var verb := kind.replace("_", " ")

		match kind:
			"block_added":
				added_cells += cells
				added_edits += 1
				verb = "placed"
			"block_removed":
				removed_cells += cells
				removed_edits += 1
				verb = "broke"
			_:
				other += 1

		var text := verb

		if cells > 0:
			text += " %d cells" % cells

		if not item.is_empty():
			text += " · " + item

		recent.append({"t": float(event.get("_rel", 0.0)), "text": text})

	return {
		"total": added_edits + removed_edits + other,
		"added_cells": added_cells,
		"removed_cells": removed_cells,
		"added_edits": added_edits,
		"removed_edits": removed_edits,
		"other": other,
		"recent": recent.slice(maxi(0, recent.size() - 3)),
	}


func _assignment_counts(tick_map: Dictionary) -> Dictionary:
	var counts: Dictionary = {}

	for row: Variant in tick_map.values():
		var exit_id := String(row[16])

		if exit_id.is_empty():
			continue

		counts[exit_id] = int(counts.get(exit_id, 0)) + 1

	return counts


func _exit_label(demo: Dictionary, exit_id: String) -> String:
	var names: Dictionary = demo.get("exit_names", {})

	if names.has(exit_id) and not String(names[exit_id]).is_empty():
		return String(names[exit_id])

	var slash := exit_id.rfind("/")
	return exit_id.substr(slash + 1) if slash >= 0 else exit_id


func _config_differences() -> Array[String]:
	var result: Array[String] = []

	if _demos.size() < 2:
		return result

	var raw_a: Dictionary = _demos[0].get("experiment", {})

	if raw_a.is_empty():
		raw_a = _demos[0].get("meta", {}).get("experiment", {})

	if raw_a.is_empty():
		result.append("No configuration metadata recorded for %s" % String(_demos[0]["letter"]))
		return result

	var experiment_a: Dictionary = _comparable_experiment(raw_a)

	for index in range(1, _demos.size()):
		var raw_b: Dictionary = _demos[index].get("experiment", {})

		if raw_b.is_empty():
			raw_b = _demos[index].get("meta", {}).get("experiment", {})

		if raw_b.is_empty():
			result.append("No configuration metadata recorded for %s" % String(_demos[index]["letter"]))
			continue

		var experiment_b: Dictionary = _comparable_experiment(raw_b)
		var diffs: Array = []
		_collect_config_diffs(experiment_a, experiment_b, "", diffs)

		for entry: Dictionary in diffs:
			if result.size() >= 16:
				result.append("… more differences omitted")
				return result

			result.append("%s/%s  %s  A=%s %s=%s" % [
				String(_demos[0]["letter"]),
				String(_demos[index]["letter"]),
				String(entry["path"]),
				String(entry["a"]),
				String(_demos[index]["letter"]),
				String(entry["b"]),
			])

	if result.is_empty():
		result.append("No configuration differences found")

	return result


## Reduces the experiment metadata to the knobs that actually describe the
## scenario, so the diff is readable instead of listing placeable arrays.
func _comparable_experiment(experiment: Dictionary) -> Dictionary:
	var scenario: Dictionary = experiment.get("scenario", {})
	return {
		"rng_seed": experiment.get("rng_seed"),
		"initial_agent_count": experiment.get("initial_agent_count"),
		"planned_agent_count": experiment.get("planned_agent_count"),
		"configured_agent_cap": experiment.get("configured_agent_cap"),
		"sampling_interval": experiment.get("sampling_interval"),
		"agent_parameters": experiment.get("agent_parameters", {}),
		"crowd_parameters": experiment.get("crowd_parameters", {}),
		"navigation_parameters": experiment.get("navigation_parameters", {}),
		"optimizer": experiment.get("optimizer", {}),
		"exits": experiment.get("exit_configuration", []),
		"scenario": {
			"agent_cap": scenario.get("agent_cap"),
			"evacuation_mode": scenario.get("evacuation_mode"),
			"global_spawn_quota": scenario.get("global_spawn_quota"),
			"placeable_count": scenario.get("placeable_count"),
			"spawner_count": scenario.get("spawner_count"),
			"quality_preset": scenario.get("quality_preset"),
		},
	}


func _collect_config_diffs(
	left: Variant,
	right: Variant,
	path: String,
	out: Array
) -> void:
	if out.size() >= 16:
		return

	if left is Dictionary and right is Dictionary:
		var keys: Array = []

		for key: Variant in left:
			keys.append(key)

		for key: Variant in right:
			if not left.has(key):
				keys.append(key)

		keys.sort()

		for key: Variant in keys:
			var child_path := path + ("." if not path.is_empty() else "") + String(key)
			_collect_config_diffs(left.get(key), right.get(key), child_path, out)

			if out.size() >= 16:
				return

		return

	if left is Array and right is Array:
		if JSON.stringify(left) != JSON.stringify(right):
			out.append({"path": path, "a": _short_value(left), "b": _short_value(right)})

		return

	if _values_equal(left, right):
		return

	out.append({"path": path, "a": _short_value(left), "b": _short_value(right)})


func _values_equal(left: Variant, right: Variant) -> bool:
	var left_number := left is int or left is float
	var right_number := right is int or right is float

	if left_number and right_number:
		return absf(float(left) - float(right)) <= 0.0005

	return typeof(left) == typeof(right) and left == right


func _short_value(value: Variant) -> String:
	if value == null:
		return "null"

	if value is bool:
		return "true" if bool(value) else "false"

	if value is int:
		return str(value)

	if value is float:
		var number := float(value)

		if is_equal_approx(number, round(number)):
			return str(int(round(number)))

		return str(snappedf(number, 0.001))

	if value is String or value is StringName:
		return String(value)

	if value is Array or value is Dictionary:
		var text := JSON.stringify(value)
		return text if text.length() <= 40 else text.substr(0, 37) + "..."

	return str(value)


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "DemoComparerUI"
	_layer.layer = 41
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)

	_ui = Control.new()
	_ui.name = "DemoComparer"
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_STOP

	var theme := Theme.new()
	theme.default_font = FONT
	theme.default_font_size = 13
	_ui.theme = theme
	_layer.add_child(_ui)

	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12
	top.offset_right = -12
	top.offset_top = 10
	top.add_theme_stylebox_override("panel", _style(PANEL))
	_ui.add_child(top)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 12)
	top.add_child(top_row)

	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_color_override("font_color", GOLD)
	_title.text = "DEMO COMPARER"
	top_row.add_child(_title)

	_state_label = Label.new()
	_state_label.add_theme_color_override("font_color", MUTED)
	top_row.add_child(_state_label)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(close)
	top_row.add_child(close_button)

	var side := PanelContainer.new()
	side.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	side.offset_left = -566
	side.offset_right = -12
	side.offset_top = 62
	side.offset_bottom = -118
	side.add_theme_stylebox_override("panel", _style(BG))
	_ui.add_child(side)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(scroll)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	scroll.add_child(column)

	column.add_child(_section_label("RECORDINGS"))

	_recordings_box = VBoxContainer.new()
	_recordings_box.add_theme_constant_override("separation", 4)
	column.add_child(_recordings_box)

	column.add_child(_section_label("AT CURSOR"))

	_values_box = VBoxContainer.new()
	_values_box.add_theme_constant_override("separation", 4)
	column.add_child(_values_box)

	column.add_child(_section_label("DELTAS VS A"))

	_deltas_box = VBoxContainer.new()
	_deltas_box.add_theme_constant_override("separation", 4)
	column.add_child(_deltas_box)

	column.add_child(_section_label("SYNCHRONIZED METRICS"))

	_chart = ChartBoard.new()
	_chart.custom_minimum_size = Vector2(0, 286)
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chart.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_chart)

	_differences_toggle = CheckButton.new()
	_differences_toggle.text = "Show detailed differences"
	_differences_toggle.button_pressed = false
	_differences_toggle.add_theme_font_size_override("font_size", 11)
	_differences_toggle.toggled.connect(_on_differences_toggled)
	column.add_child(_differences_toggle)

	_differences = RichTextLabel.new()
	_differences.visible = false
	_differences.bbcode_enabled = true
	_differences.fit_content = true
	_differences.scroll_active = false
	_differences.add_theme_font_override("normal_font", FONT)
	_differences.add_theme_font_size_override("normal_font_size", 11)
	_differences.add_theme_constant_override("line_separation", 6)
	column.add_child(_differences)

	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 12
	bottom.offset_right = -12
	bottom.offset_top = -122
	bottom.offset_bottom = -10
	bottom.add_theme_stylebox_override("panel", _style(BG))
	_ui.add_child(bottom)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	bottom.add_child(root)

	# Transport controls can exceed the width with several demos. A horizontal
	# scroller keeps every button reachable.
	var controls_scroll := ScrollContainer.new()
	controls_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	controls_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	controls_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_scroll.custom_minimum_size = Vector2(0, 44)
	root.add_child(controls_scroll)

	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_scroll.add_child(controls)

	_play_button = _button("Pause", _toggle_play)
	controls.add_child(_play_button)

	controls.add_child(_button("<< Start", _restart))

	_speed_button = _button("Speed 1x", _cycle_speed)
	controls.add_child(_speed_button)

	_noclip_button = _button("Noclip", Callable())
	_noclip_button.tooltip_text = "Tap: toggle free flight  ·  Hold: reset camera to overview"
	_noclip_button.button_down.connect(_begin_noclip_hold)
	_noclip_button.button_up.connect(_end_noclip_hold)
	controls.add_child(_noclip_button)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(150, 0)
	_time_label.add_theme_color_override("font_color", TEXT)
	controls.add_child(_time_label)

	controls.add_child(_spacer())

	var hint := Label.new()
	hint.text = "Esc: close  ·  scroll for values & differences"
	hint.add_theme_color_override("font_color", MUTED)
	controls.add_child(hint)

	_timeline = HSlider.new()
	_timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline.custom_minimum_size = Vector2(0, 20)
	_timeline.value_changed.connect(_on_timeline_changed)
	root.add_child(_timeline)


func _section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", GOLD)
	label.add_theme_font_size_override("font_size", 11)
	return label


func _style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = Color(0.45, 0.36, 0.12, 1)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text

	if callback.is_valid():
		button.pressed.connect(callback)

	button.add_theme_color_override("font_color", TEXT)
	return button


func _spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spacer


func _build_recordings_ui() -> void:
	for child in _recordings_box.get_children():
		child.free()

	for demo: Dictionary in _demos:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 1)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		var chip := Label.new()
		chip.text = String(demo["letter"])
		chip.add_theme_color_override("font_color", demo["color"])
		row.add_child(chip)

		var name_label := Label.new()
		name_label.text = String(demo["name"])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_color_override("font_color", TEXT)
		row.add_child(name_label)

		var check := CheckBox.new()
		check.text = "Show"
		check.button_pressed = bool(demo.get("visible", true))
		var letter := String(demo["letter"])
		check.toggled.connect(func(on: bool) -> void: _set_demo_visible(letter, on))
		row.add_child(check)
		box.add_child(row)

		var description := String(demo.get("description", "")).strip_edges()

		if not description.is_empty():
			box.add_child(_small_label(description))

		box.add_child(_small_label(_scenario_line(demo)))
		_recordings_box.add_child(box)

	_build_metrics_tables()


func _small_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", MUTED)
	label.add_theme_font_size_override("font_size", 10)
	return label


## The six metrics shown by the charts, reused by the tables so the numbers and
## the lines cannot drift apart.
func _metric_rows() -> Array:
	return [
		{"key": "evacuated", "label": "Evacuated", "digits": 0},
		{"key": "active", "label": "Active", "digits": 0},
		{"key": "density", "label": "Density", "digits": 2},
		{"key": "throughput", "label": "Throughput", "digits": 1},
		{"key": "contact", "label": "Peak kN", "digits": 2},
		{"key": "routes", "label": "Routes", "digits": 0},
	]


## Compact per-demo table at the cursor. Values and deltas are separate grids so
## the deltas can start at B (A is the reference).
func _build_metrics_tables() -> void:
	_value_labels = []
	_delta_labels = []

	for container_value: Variant in [_values_box, _deltas_box]:
		if not container_value is VBoxContainer:
			continue

		var container := container_value as VBoxContainer

		for child: Node in container.get_children():
			child.free()

	if _demos.is_empty():
		return

	var metrics: Array = _metric_rows()
	var values_grid := _metric_grid(metrics, true, false)
	_values_box.add_child(values_grid)

	if _demos.size() > 1:
		_deltas_box.add_child(_metric_grid(metrics, false, true))
	else:
		_deltas_box.add_child(_small_label(
			"Select at least two recordings to compare deltas against A."
		))


func _metric_grid(
	metrics: Array,
	include_base: bool,
	deltas: bool
) -> GridContainer:
	var demo_count: int = _demos.size()
	var columns: int = 1 + (demo_count if include_base else demo_count - 1)
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 2)

	var header := Label.new()
	header.text = "Δ vs A" if deltas else "Metric"
	header.add_theme_color_override("font_color", MUTED)
	header.add_theme_font_size_override("font_size", 10)
	header.custom_minimum_size = Vector2(88, 0)
	grid.add_child(header)

	var first_demo: int = 0 if include_base else 1

	for demo_index: int in range(first_demo, demo_count):
		var demo: Dictionary = _demos[demo_index]
		var chip := Label.new()
		chip.text = String(demo.get("letter"))
		chip.tooltip_text = String(demo.get("name"))
		chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.add_theme_color_override("font_color", demo["color"])
		chip.add_theme_font_size_override("font_size", 11)
		grid.add_child(chip)

	var row_labels: Array = []

	for metric: Dictionary in metrics:
		var name_label := Label.new()
		name_label.text = String(metric.get("label", ""))
		name_label.add_theme_color_override("font_color", MUTED)
		name_label.add_theme_font_size_override("font_size", 10)
		name_label.custom_minimum_size = Vector2(88, 0)
		grid.add_child(name_label)

		var cells: Array = []

		for _column: int in range(first_demo, demo_count):
			var cell := Label.new()
			cell.text = "—"
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cell.add_theme_font_size_override("font_size", 10)
			grid.add_child(cell)
			cells.append(cell)

		row_labels.append(cells)

	if deltas:
		_delta_labels = row_labels
	else:
		_value_labels = row_labels

	return grid


func _format_metric(value: float, digits: int) -> String:
	match digits:
		0:
			return str(roundi(value))
		1:
			return "%.1f" % value
		_:
			return "%.2f" % value


func _format_delta(value: float, digits: int) -> String:
	if absf(value) < 0.000001:
		return "—"

	var sign_text := "+" if value > 0.0 else "−"
	return sign_text + _format_metric(absf(value), digits)


func _update_metric_tables(values_list: Array, base: Dictionary) -> void:
	var metrics: Array = _metric_rows()

	for metric_index: int in range(metrics.size()):
		var metric: Dictionary = metrics[metric_index]
		var key: String = String(metric["key"])
		var digits: int = int(metric["digits"])

		if metric_index < _value_labels.size():
			var value_row: Array = _value_labels[metric_index]

			for demo_index: int in range(mini(value_row.size(), values_list.size())):
				var value: float = float(values_list[demo_index].get(key, 0.0))
				(value_row[demo_index] as Label).text = _format_metric(value, digits)

		if metric_index < _delta_labels.size():
			var delta_row: Array = _delta_labels[metric_index]

			for column: int in range(delta_row.size()):
				var demo_index: int = column + 1

				if demo_index >= values_list.size():
					break

				var value: float = float(values_list[demo_index].get(key, 0.0))
				var base_value: float = float(base.get(key, 0.0))
				(delta_row[column] as Label).text = _format_delta(
					value - base_value, digits
				)


func _on_differences_toggled(show_details: bool) -> void:
	if _differences != null:
		_differences.visible = show_details


func _scenario_line(demo: Dictionary) -> String:
	var meta: Dictionary = demo.get("meta", {})
	var experiment: Dictionary = demo.get("experiment", meta.get("experiment", {}))
	var navigation: Dictionary = experiment.get("navigation_parameters", {})
	var agent: Dictionary = experiment.get("agent_parameters", {})
	var parts: Array[String] = []
	var agents := maxi(
		int(meta.get("agents", experiment.get("initial_agent_count", 0))),
		int(demo.get("peak_active", 0))
	)
	parts.append("seed %d" % int(meta.get("seed", experiment.get("rng_seed", 0))))
	parts.append("%d agents" % agents)
	var sampling := float(meta.get("sample_interval", experiment.get("sampling_interval", 0.0)))

	if sampling > 0.0:
		parts.append("%.2f s" % sampling)

	parts.append(
		"congestion "
		+ ("on" if bool(navigation.get("enable_congestion_routing", false)) else "off")
	)
	parts.append("retries %d" % int(agent.get("max_evacuation_failures", 0)))
	return " · ".join(PackedStringArray(parts))


func _set_demo_visible(letter: String, visible: bool) -> void:
	for demo: Dictionary in _demos:
		if String(demo["letter"]) == letter:
			demo["visible"] = visible
			break

	_update_scene()


func _build_charts() -> void:
	var entries: Array = []
	entries.append(_metric_entry("Evacuated", "evacuated"))
	entries.append(_metric_entry("Active", "active"))
	entries.append(_metric_entry("Global density", "density"))
	entries.append(_metric_entry("Throughput", "throughput"))
	entries.append(_metric_entry("Peak contact (kN)", "contact"))
	entries.append(_metric_entry("Route changes", "routes"))
	_chart.setup(entries, _duration, FONT)
	_chart.set_cursor(_time)


func _metric_entry(label: String, key: String) -> Dictionary:
	var series_list: Array = []
	var colors: Array = []
	var max_value := 0.0

	for demo: Dictionary in _demos:
		var data: Array = demo["series"].get(key, [])
		series_list.append(data)
		colors.append(demo["color"])

		for point: Vector2 in data:
			max_value = maxf(max_value, float(point.y))

	return {
		"label": label,
		"series": series_list,
		"colors": colors,
		"max": max_value,
	}


func _toggle_play() -> void:
	_playing = not _playing
	_play_button.text = "Pause" if _playing else "Play"

	if _playing and _time >= _duration:
		_time = 0.0


func _restart() -> void:
	_time = 0.0
	_playing = true
	_play_button.text = "Pause"
	_timeline.set_value_no_signal(0.0)
	_update_scene()
	_update_text(true)

	if _chart != null:
		_chart.set_cursor(_time)


func _cycle_speed() -> void:
	var speeds: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0]
	var index: int = speeds.find(_speed)
	_speed = speeds[(index + 1) % speeds.size()]
	_speed_button.text = "Speed %sx" % str(_speed)


func _on_timeline_changed(value: float) -> void:
	_time = value
	_playing = false
	_play_button.text = "Play"
	_update_scene()
	_update_text(true)

	if _chart != null:
		_chart.set_cursor(_time)


# ---------------------------------------------------------------------------
# Chart board
# ---------------------------------------------------------------------------

class ChartBoard extends Control:
	var metrics: Array = []
	var duration: float = 1.0
	var cursor: float = 0.0
	var board_font: Font = null

	func setup(entries: Array, total_duration: float, font: Font) -> void:
		metrics = entries
		duration = maxf(total_duration, 0.001)
		board_font = font
		queue_redraw()

	func set_cursor(value: float) -> void:
		cursor = clampf(value, 0.0, duration)
		queue_redraw()

	func _format_max(value: float) -> String:
		if value < 10.0:
			return "%.2f" % value
		if value < 100.0:
			return "%.1f" % value
		return "%d" % int(round(value))

	func _draw() -> void:
		if metrics.is_empty():
			return

		var row_height: float = size.y / float(metrics.size())
		var label_color := Color(0.78, 0.79, 0.74)
		var axis_color := Color(1.0, 1.0, 1.0, 0.10)

		for index in metrics.size():
			var metric: Dictionary = metrics[index]
			var top: float = row_height * float(index)
			var plot := Rect2(
				138.0,
				top + 3.0,
				maxf(size.x - 144.0, 10.0),
				maxf(row_height - 8.0, 6.0)
			)

			if board_font != null:
				draw_string(
					board_font,
					Vector2(2.0, top + row_height * 0.5 + 4.0),
					String(metric.get("label", "")),
					HORIZONTAL_ALIGNMENT_LEFT,
					132.0,
					10,
					label_color
				)

			draw_rect(plot, Color(1.0, 1.0, 1.0, 0.03), true)
			draw_line(
				Vector2(plot.position.x, plot.end.y),
				Vector2(plot.end.x, plot.end.y),
				axis_color,
				1.0
			)

			var max_value: float = float(metric.get("max", 0.0))

			if max_value <= 0.0:
				max_value = 1.0

			var series_list: Array = metric.get("series", [])
			var colors: Array = metric.get("colors", [])
			var max_text := _format_max(max_value)

			if board_font != null:
				draw_string(
					board_font,
					Vector2(plot.end.x - 48.0, plot.position.y + 9.0),
					max_text,
					HORIZONTAL_ALIGNMENT_RIGHT,
					48.0,
					9,
					Color(0.7, 0.7, 0.66)
				)

			# Draw the later demos first so the first demo's line stays visible
			# when runs overlap exactly.
			for series_index in range(series_list.size() - 1, -1, -1):
				var points: Array = series_list[series_index]
				var color: Color = (
					colors[series_index] if series_index < colors.size() else Color.WHITE
				)
				var width := 2.0 if series_index == 0 else 1.4

				if points.is_empty():
					continue

				if points.size() == 1:
					var single: Vector2 = points[0]
					draw_circle(
						Vector2(
							plot.position.x + clampf(single.x / duration, 0.0, 1.0) * plot.size.x,
							plot.end.y - clampf(single.y / max_value, 0.0, 1.0) * plot.size.y
						),
						1.5,
						color
					)
					continue

				var packed := PackedVector2Array()
				packed.resize(points.size())

				for point_index in points.size():
					var point: Vector2 = points[point_index]
					packed[point_index] = Vector2(
						plot.position.x + clampf(point.x / duration, 0.0, 1.0) * plot.size.x,
						plot.end.y - clampf(point.y / max_value, 0.0, 1.0) * plot.size.y
					)

				draw_polyline(packed, color, width, true)

			var cursor_x: float = (
				plot.position.x + clampf(cursor / duration, 0.0, 1.0) * plot.size.x
			)
			draw_line(
				Vector2(cursor_x, plot.position.y),
				Vector2(cursor_x, plot.end.y),
				Color(1.0, 0.84, 0.34, 0.55),
				1.0
			)
