extends Node

## Demo Player: inspect a recorded experiment in the map itself.
##
## Launched from the pause menu's Demos tab. The tree stays paused; this node
## and its CanvasLayer use PROCESS_MODE_ALWAYS. Recorded agents are represented
## by lightweight proxy spheres over the frozen world, with routes, exit
## assignments, density/contact colour modes and an event timeline.
##
## It reads only the structured demo files (DemoStore), never rendered objects.

signal closed

const FONT: Font = preload("res://font/dogicapixel.ttf")
const NOCLIP_BASE_SPEED := 10.0
const NOCLIP_LOOK_SENSITIVITY := 0.004
const NOCLIP_MIN_MULT := 0.2
const NOCLIP_MAX_MULT := 10.0
const NOCLIP_HOLD_RESET_TIME := 0.4
const MEMBER_SCENE := preload("res://scenes/npcs/Member.tscn")

# Tick row indices, mirrored from SimRecorder.AGENT_FIELDS. Keep in sync.
const AGENT_STATUS := 1
const AGENT_STATE := 2
const AGENT_EXIT_ID := 16
const AGENT_DISTANCE := 22
const AGENT_CONTACT_FORCE := 23
const AGENT_DENSITY := 24
const AGENT_ROUTE_CHANGES := 25
const AGENT_ROUTE_SWITCHES := 26
const AGENT_STUCK_STRIKES := 27
const AGENT_DESIRED_SPEED := 29
const AGENT_PRE_DELAY := 30
const AGENT_PRE_WAIT := 31
const AGENT_STUCK_TIME := 32
const AGENT_IS_EVACUEE := 35
const AGENT_HAS_TARGET := 36
const AGENT_PEAK_DENSITY := 37
const AGENT_PEAK_CONTACT := 38
const AGENT_SPAWNED_AT := 39
const AGENT_OPTIMIZER_ASSIGNED := 40
const AGENT_OPTIMIZER_EXIT_ID := 41

# Exit row indices, mirrored from SimRecorder.EXIT_FIELDS.
const EXIT_ACCEPTED := 4
const EXIT_MAX_QUEUE := 6
const EXIT_PEAK_OCCUPANCY := 8
const EXIT_AVERAGE_WAIT := 9
const EXIT_MAX_WAIT := 10
const EXIT_REJECTED := 16
const EXIT_CAPACITY_WAITS := 17
const EXIT_CAPACITY_REJECTIONS := 18
const EXIT_QUEUE_FULL_REJECTIONS := 19
const BG := Color(0.055, 0.05, 0.045, 0.94)
const PANEL := Color(0.10, 0.09, 0.08, 0.96)
const GOLD := Color(1.0, 0.84, 0.34, 1.0)
const TEXT := Color(0.92, 0.93, 0.9, 1.0)
const MUTED := Color(0.68, 0.68, 0.64, 1.0)

var _active: bool = false
var _meta: Dictionary = {}
var _ticks: Array = []
var _tick_maps: Array = []
var _events: Array = []
var _routes: Dictionary = {} # serial -> Array[route event]
var _demo_id: String = ""
var _workspace_build_controller: Node = null
var _workspace_pause_active: bool = false
var _world: Node3D = null
var _proxies: Dictionary = {} # serial -> MeshInstance3D
var _exit_nodes: Dictionary = {} # exit_id -> MeshInstance3D
var _exit_labels: Dictionary = {} # exit_id -> Label3D
var _env_nodes: Array = []
var _route_mesh: MeshInstance3D = null
var _route_material: StandardMaterial3D = null
var _route_markers_root: Node3D = null
var _last_route_key: String = ""

var _layer: CanvasLayer = null
var _ui: Control = null
var _panel: PanelContainer = null
var _title: Label = null
var _time_label: Label = null
var _state_label: Label = null
var _play_button: Button = null
var _speed_button: Button = null
var _noclip_button: Button = null
var _timeline: HSlider = null
var _agent_select: OptionButton = null
var _mode_select: OptionButton = null
var _route_check: CheckBox = null
var _inspector: RichTextLabel = null
var _event_log: RichTextLabel = null

var _time: float = 0.0
var _duration: float = 0.0
var _speed: float = 1.0
var _playing: bool = false
var _selected_serial: int = -1
var _mode: int = 0
var _show_route: bool = true
var _ui_accum: float = 0.0
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
var _started_t: float = 0.0
## The run header's absolute start time. Unlike `_started_t` (the first tick),
## this is the true run start used when replaying evacuation history.
var _run_start_t: float = -1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	_build_ui()
	_ui.visible = false


func is_active() -> bool:
	return _active


func play(demo_id: String) -> bool:
	if _active:
		close()

	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return false

	var meta: Dictionary = store.call("get_demo", demo_id)

	if meta.is_empty():
		return false

	var active_slug: String = String(store.call("active_save_slug"))

	if String(meta.get("save_slug", "")) != active_slug:
		return false

	var path: String = String(store.call("recording_path", demo_id))

	if not FileAccess.file_exists(path):
		return false

	if not _load_recording(path):
		return false

	_demo_id = demo_id
	_meta = meta
	_duration = _max_tick_time()
	_started_t = _min_tick_time()
	_time = _started_t
	_speed = 1.0
	_playing = true
	_selected_serial = -1
	_mode = 0
	_show_route = true
	_last_route_key = ""
	_noclip = false
	_noclip_speed_mult = 1.0
	_noclip_hold_active = false
	_noclip_hold_elapsed = 0.0
	_noclip_hold_reset_done = false
	_active = true
	_ui.visible = true
	_noclip_button.text = "Noclip"
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_play_button.text = "Pause"
	_speed_button.text = "Speed 1x"
	_mode_select.select(0)
	_route_check.button_pressed = true
	_timeline.min_value = _started_t
	_timeline.max_value = maxf(_duration, _started_t + 0.1)
	_timeline.step = 0.01
	_timeline.set_value_no_signal(_started_t)
	_title.text = "DEMO  ·  %s" % String(meta.get("name", demo_id))
	_build_world()
	_build_agent_select()
	_setup_camera()
	_update_scene(true)
	_update_text(true)
	_playing = true
	_play_button.text = "Pause"
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

	_update_scene(false)
	_ui_accum += delta

	if _ui_accum >= 0.2:
		_ui_accum = 0.0
		_update_text(false)


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


## Mirrors the gameplay noclip: camera-relative flight, mouse look, jump/crouch
## for vertical movement and mouse-wheel speed. The demo tree stays paused.
## Toggling only changes the flight state; the camera stays wherever it is.
func _set_noclip(enabled: bool) -> void:
	if enabled == _noclip:
		return

	if enabled and (_camera == null or not is_instance_valid(_camera)):
		return

	_noclip = enabled

	if enabled:
		var rotation: Vector3 = _camera.global_rotation if _camera != null else Vector3.ZERO
		_noclip_yaw = rotation.y
		_noclip_pitch = rotation.x
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_noclip_button.text = "Noclip: On" if _noclip else "Noclip"
	_update_text(true)


## Pressing the noclip control starts a hold. Releasing it before the reset
## threshold is a tap and toggles free flight; holding past the threshold
## resets the camera angle and suppresses the toggle.
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


## Restores the demo's overview framing (position and orientation). Holding
## the noclip control is a "return to the shot"; tapping only toggles flight.
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

func _load_recording(path: String) -> bool:
	_ticks.clear()
	_tick_maps.clear()
	_events.clear()
	_routes.clear()
	_run_start_t = -1.0

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return false

	while not file.eof_reached():
		var line := file.get_line()

		if line.strip_edges().is_empty():
			continue

		var obj: Variant = JSON.parse_string(line)

		if not obj is Dictionary:
			continue

		var type := String(obj.get("type", ""))
		var t := float(obj.get("t", 0.0))

		if type == "run":
			_run_start_t = t
			var run_metadata: Dictionary = obj.get("metadata", {})

			for key: Variant in run_metadata:
				if not _meta.has(key):
					_meta[key] = run_metadata[key]

			_meta["exit_configuration"] = obj.get("exits", _meta.get("exit_configuration", []))
		elif type == "tick":
			_ticks.append(obj)
		elif type == "route" or type == "route_change":
			var serial := int(obj.get("agent", -1))
			if not _routes.has(serial):
				_routes[serial] = []
			_routes[serial].append(obj)
			_events.append(obj)
		elif type in [
			"agent_spawn", "destination", "evacuation", "agent_death", "queue", "contact",
			"environment", "disruption", "exit_state", "exit_added",
			"exit_removed", "nav", "optimizer", "layout", "nav_graph", "end"
		]:
			if type != "nav" and type != "layout" and type != "nav_graph":
				_events.append(obj)

	file.close()

	_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("t", 0.0)) < float(b.get("t", 0.0))
	)

	for routes_for_agent: Array in _routes.values():
		routes_for_agent.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("t", 0.0)) < float(b.get("t", 0.0))
		)

	# A block edit made while spawning also writes a disruption record pointing
	# back at the environment event. Keep the named environment entry in the
	# timeline instead of showing both.
	var linked_disruptions: Dictionary = {}

	for event: Dictionary in _events:
		if String(event.get("type", "")) == "environment":
			var disruption_id := String(event.get("disruption_id", ""))

			if not disruption_id.is_empty():
				linked_disruptions[disruption_id] = true

	if not linked_disruptions.is_empty():
		var filtered: Array = []

		for event: Dictionary in _events:
			if (
				String(event.get("type", "")) == "disruption"
				and linked_disruptions.has(String(event.get("id", "")))
			):
				continue

			filtered.append(event)

		_events = filtered

	return not _ticks.is_empty()


func _min_tick_time() -> float:
	return float(_ticks[0].get("t", 0.0)) if not _ticks.is_empty() else 0.0


func _max_tick_time() -> float:
	return float(_ticks[_ticks.size() - 1].get("t", 0.0)) if not _ticks.is_empty() else 0.0


# ---------------------------------------------------------------------------
# World representation
# ---------------------------------------------------------------------------

func _build_world() -> void:
	_clear_world()
	var scene: Node = get_tree().current_scene

	if scene == null:
		return

	_world = Node3D.new()
	_world.name = "DemoPlayback"
	scene.add_child(_world)

	_route_material = StandardMaterial3D.new()
	_route_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_route_material.albedo_color = GOLD
	_route_material.no_depth_test = true
	_route_mesh = MeshInstance3D.new()
	_route_mesh.name = "SelectedRoute"
	_route_mesh.material_override = _route_material
	_world.add_child(_route_mesh)

	_route_markers_root = Node3D.new()
	_route_markers_root.name = "SelectedRouteMarkers"
	_world.add_child(_route_markers_root)

	var first_tick: Dictionary = _ticks[0]
	var first_map: Dictionary = _tick_map(0)

	for serial_key: Variant in first_map:
		_create_proxy(int(serial_key))

	# Later spawns.
	for index: int in range(1, _ticks.size()):
		for serial_key: Variant in _tick_map(index):
			var serial := int(serial_key)
			if not _proxies.has(serial):
				_create_proxy(serial)

	_build_exit_markers(first_tick)
	_build_environment_markers()


func _clear_world() -> void:
	if _world != null and is_instance_valid(_world):
		_world.queue_free()

	_world = null
	_proxies.clear()
	_exit_nodes.clear()
	_exit_labels.clear()
	_env_nodes.clear()
	_route_mesh = null
	_route_material = null
	_route_markers_root = null
	_last_route_key = ""


func _create_proxy(serial: int) -> void:
	if _world == null:
		return

	var mesh := SphereMesh.new()
	mesh.radius = 0.28
	mesh.height = 0.56
	mesh.radial_segments = 10
	mesh.rings = 6

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.4, 0.8, 1.0)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color.a = 0.92

	var node := MeshInstance3D.new()
	node.name = "Agent_%d" % serial
	node.mesh = mesh
	node.material_override = material
	node.scale = Vector3.ONE
	_world.add_child(node)
	_proxies[serial] = node


func _tick_map(index: int) -> Dictionary:
	while _tick_maps.size() <= index:
		_tick_maps.append({})

	if not _tick_maps[index].is_empty():
		return _tick_maps[index]

	var map: Dictionary = {}
	var agents: Array = _ticks[index].get("agents", [])

	for row: Array in agents:
		if row.size() >= 4:
			map[int(row[0])] = row

	_tick_maps[index] = map
	return map


func _build_exit_markers(_tick: Dictionary) -> void:
	var exits: Array = _meta.get("exit_configuration", [])

	if exits.is_empty():
		exits = _meta.get("exits", [])

	for entry: Dictionary in exits:
		var location: Variant = entry.get("location")
		var position := Vector3.ZERO

		if location is Array and location.size() >= 3:
			position = Vector3(float(location[0]), float(location[1]), float(location[2]))
		else:
			continue

		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.7
		mesh.bottom_radius = 0.7
		mesh.height = 0.04
		mesh.radial_segments = 20

		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.3, 1.0, 0.55, 0.75)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		var node := MeshInstance3D.new()
		node.name = "Exit_%s" % String(entry.get("exit_id", ""))
		node.mesh = mesh
		node.material_override = material
		node.position = position + Vector3(0, 0.03, 0)
		_world.add_child(node)
		_exit_nodes[String(entry.get("exit_id", ""))] = node

		var label := Label3D.new()
		label.text = "%s  q0" % String(entry.get("name", entry.get("exit_id", "Exit")))
		label.font = FONT
		label.font_size = 32
		label.pixel_size = 0.008
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color(1, 1, 1, 0.9)
		label.position = position + Vector3(0, 0.8, 0)
		_world.add_child(label)
		_exit_labels[String(entry.get("exit_id", ""))] = label


func _build_environment_markers() -> void:
	var grid := get_tree().get_first_node_in_group("grid_map") as GridMap
	var linked_disruptions: Dictionary = {}

	# Block edits made while spawning is enabled also write a disruption record
	# that points back at the environment event. Only the environment marker is
	# drawn so one edit does not produce two overlapping markers.
	for event: Dictionary in _events:
		if String(event.get("type", "")) == "environment":
			var disruption_id := String(event.get("disruption_id", ""))

			if not disruption_id.is_empty():
				linked_disruptions[disruption_id] = true

	for event: Dictionary in _events:
		var type := String(event.get("type", ""))

		if type != "environment" and type != "disruption":
			continue

		if type == "disruption" and linked_disruptions.has(String(event.get("id", ""))):
			continue

		var kind := String(event.get("kind", type))
		var rel := float(event.get("t", 0.0)) - _started_t
		var color := _environment_color(kind)
		var cells: Variant = event.get("cells", [])

		if cells is Array and not cells.is_empty() and grid != null:
			_add_cell_markers(cells, grid, color, rel)
			continue

		var location: Variant = event.get("location")

		if not location is Array or location.size() < 3:
			continue

		var box := BoxMesh.new()
		box.size = Vector3(0.35, 0.35, 0.35)

		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

		var node := MeshInstance3D.new()
		node.mesh = box
		node.material_override = material
		node.position = Vector3(
			float(location[0]),
			float(location[1]) + 0.2,
			float(location[2])
		)
		node.set_meta("event_t", rel)
		_world.add_child(node)
		_env_nodes.append(node)


## Draws one box per recorded grid cell. Stretched drags and held place/remove
## strokes are coalesced into a single event whose `cells` array holds the whole
## footprint, so a single marker at `location` would only show its first cell.
func _add_cell_markers(
	cells: Array,
	grid: GridMap,
	color: Color,
	rel: float
) -> void:
	var cell_size: Vector3 = grid.cell_size

	if cell_size == Vector3.ZERO:
		cell_size = Vector3.ONE

	var positions: Array[Vector3] = []

	for cell: Variant in cells:
		if not cell is Array or cell.size() < 3:
			continue

		var cell_pos := Vector3i(int(cell[0]), int(cell[1]), int(cell[2]))
		positions.append(grid.to_global(grid.map_to_local(cell_pos)))

	if positions.is_empty():
		return

	var box := BoxMesh.new()
	box.size = cell_size * 0.82

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = box
	multimesh.instance_count = positions.size()

	for index in positions.size():
		multimesh.set_instance_transform(index, Transform3D(Basis(), positions[index]))

	var node := MultiMeshInstance3D.new()
	node.multimesh = multimesh
	node.material_override = material
	node.set_meta("event_t", rel)
	_world.add_child(node)
	_env_nodes.append(node)


## Green marks a placement/addition, red a removal/closure, amber a disruption
## that is not a direct block or placeable edit.
func _environment_color(kind: String) -> Color:
	match kind:
		"block_added", "placeable_added", "water_placed", "exit_added", "exit_enabled":
			return Color(0.38, 1.0, 0.52, 0.9)
		"block_removed", "placeable_removed", "exit_removed", "exit_disabled":
			return Color(1.0, 0.32, 0.20, 0.9)
		_:
			return Color(1.0, 0.62, 0.18, 0.9)


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

	for tick: Dictionary in _ticks:
		for row: Array in tick.get("agents", []):
			if row.size() < 6:
				continue
			var p := Vector3(float(row[3]), float(row[4]), float(row[5]))
			min_point = min_point.min(p)
			max_point = max_point.max(p)
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
# Playback
# ---------------------------------------------------------------------------

func _tick_index_at(time: float) -> int:
	if _ticks.is_empty():
		return -1

	var low: int = 0
	var high: int = _ticks.size() - 1

	while low < high:
		var middle: int = int((low + high + 1) / 2.0)
		if float(_ticks[middle].get("t", 0.0)) <= time:
			low = middle
		else:
			high = middle - 1

	return low


func _update_scene(force_text: bool) -> void:
	if _ticks.is_empty():
		return

	var index: int = _tick_index_at(_time)
	var tick: Dictionary = _ticks[index]
	var next_index: int = mini(index + 1, _ticks.size() - 1)
	var next_tick: Dictionary = _ticks[next_index]
	var t0: float = float(tick.get("t", 0.0))
	var t1: float = float(next_tick.get("t", t0))
	var alpha: float = 0.0 if t1 <= t0 else clampf((_time - t0) / (t1 - t0), 0.0, 1.0)
	var current: Dictionary = _tick_map(index)
	var following: Dictionary = _tick_map(next_index)

	for serial: int in _proxies:
		var node: MeshInstance3D = _proxies[serial]

		if node == null or not is_instance_valid(node):
			continue

		var row: Variant = current.get(serial)

		if row == null:
			node.visible = false
			continue

		node.visible = true
		var next_row: Variant = following.get(serial)
		var p0 := Vector3(float(row[3]), float(row[4]), float(row[5]))
		var p1 := p0

		if next_row != null:
			p1 = Vector3(float(next_row[3]), float(next_row[4]), float(next_row[5]))

		node.position = p0.lerp(p1, alpha) + Vector3(0, 0.28, 0)
		node.scale = Vector3.ONE * (1.35 if serial == _selected_serial else 1.0)
		var material := node.material_override as StandardMaterial3D
		if material != null:
			material.albedo_color = _agent_color(row, serial)

	for exit_id: String in _exit_nodes:
		var node: MeshInstance3D = _exit_nodes[exit_id]

		if node == null or not is_instance_valid(node):
			continue

		var material := node.material_override as StandardMaterial3D
		var available := true
		var queue := 0

		for row: Array in tick.get("exits", []):
			if String(row[0]) == exit_id:
				available = bool(row[3])
				queue = int(row[5])
				break

		if material != null:
			material.albedo_color = (
				Color(0.25, 1.0, 0.5, 0.8)
				if available
				else Color(1.0, 0.25, 0.2, 0.8)
			)

		var label: Label3D = _exit_labels.get(exit_id)

		if label != null:
			label.text = "%s  q%d" % [exit_id, queue]

	for marker: Node in _env_nodes:
		if marker == null or not is_instance_valid(marker):
			continue

		var event_t := float(marker.get_meta("event_t", -1.0))
		marker.visible = (_time - _started_t) >= event_t

	_refresh_selected_route()
	_timeline.set_value_no_signal(_time)

	if force_text:
		_update_text(true)


func _agent_color(row: Array, _serial: int) -> Color:
	if _mode == 1:
		var density := float(row[24]) if row.size() > 24 else 0.0
		return Color(0.25, 0.55, 0.35).lerp(
			Color(1.0, 0.25, 0.15),
			clampf(density / 2.0, 0.0, 1.0)
		)

	if _mode == 2:
		var force := float(row[23]) if row.size() > 23 else 0.0
		return Color(0.9, 0.9, 0.85).lerp(
			Color(1.0, 0.15, 0.1),
			clampf(force / 3000.0, 0.0, 1.0)
		)

	if _mode == 3:
		var exit_id := String(row[16]) if row.size() > 16 else ""
		var hue := float(abs(hash(exit_id)) % 360) / 360.0
		return Color.from_hsv(hue, 0.62, 1.0)

	var status := String(row[1]) if row.size() > 1 else "active"
	match status:
		"pre_movement":
			return Color(0.55, 0.55, 0.58)
		"seeking_exit":
			return Color(0.35, 0.75, 1.0)
		"queued":
			return Color(1.0, 0.82, 0.25)
		"arrived":
			return Color(0.5, 1.0, 0.55)
		"wandering":
			return Color(0.7, 0.55, 1.0)
		"evacuated":
			return Color(0.2, 0.9, 0.3)
		"dead":
			return Color(0.4, 0.1, 0.1)
		_:
			return Color(0.8, 0.9, 1.0)


func _refresh_selected_route() -> void:
	if _route_mesh == null or not is_instance_valid(_route_mesh) or not _show_route or _selected_serial < 0:
		if _route_mesh != null and is_instance_valid(_route_mesh):
			_route_mesh.visible = false
		_clear_route_markers()
		_last_route_key = ""
		return

	var route: Dictionary = _latest_route_for(_selected_serial, _time)

	if route.is_empty():
		_route_mesh.visible = false
		_clear_route_markers()
		return

	var key := "%d:%d" % [_selected_serial, int(route.get("route_id", 0))]

	if key == _last_route_key:
		_route_mesh.visible = true
		return

	_last_route_key = key
	var path: Array = route.get("path", [])
	var points: Array = []

	if path is Array and not path.is_empty():
		for point: Variant in path:
			if point is Array and point.size() >= 3:
				points.append(Vector3(float(point[0]), float(point[1]), float(point[2])))
	else:
		var row: Variant = _tick_map(_tick_index_at(_time)).get(_selected_serial)
		var target: Variant = route.get("target", [])
		if row != null and target is Array and target.size() >= 3:
			points.append(Vector3(float(row[3]), float(row[4]), float(row[5])))
			points.append(Vector3(float(target[0]), float(target[1]), float(target[2])))

	if points.size() < 2:
		_route_mesh.visible = false
		return

	_rebuild_route_markers(points)

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _route_material)

	for point: Vector3 in points:
		mesh.surface_add_vertex(Vector3(point.x, point.y + 0.15, point.z))

	mesh.surface_end()
	_route_mesh.mesh = mesh
	_route_mesh.visible = true


func _rebuild_route_markers(points: Array) -> void:
	if _route_markers_root == null or not is_instance_valid(_route_markers_root):
		return

	for child in _route_markers_root.get_children():
		child.queue_free()

	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	sphere.radial_segments = 6
	sphere.rings = 4
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = GOLD
	material.no_depth_test = true

	var count: int = 0
	var previous: Vector3 = points[0]

	for index: int in range(1, points.size()):
		var current: Vector3 = points[index]
		var segment: Vector3 = current - previous
		var length: float = segment.length()

		if length > 0.01:
			var steps: int = maxi(1, int(ceil(length / 0.45)))

			for step: int in range(steps + 1):
				var point: Vector3 = previous + segment * (float(step) / float(steps))
				var marker := MeshInstance3D.new()
				marker.mesh = sphere
				marker.material_override = material
				marker.position = Vector3(point.x, point.y + 0.15, point.z)
				_route_markers_root.add_child(marker)
				count += 1

				if count >= 160:
					return

		previous = current


func _clear_route_markers() -> void:
	if _route_markers_root == null or not is_instance_valid(_route_markers_root):
		return

	for child in _route_markers_root.get_children():
		child.queue_free()


func _latest_route_for(serial: int, time: float) -> Dictionary:
	var list: Array = _routes.get(serial, [])
	var latest: Dictionary = {}

	for route: Dictionary in list:
		if float(route.get("t", 0.0)) <= time:
			latest = route

	return latest


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _show_load_state_dialog() -> void:
	if _ticks.is_empty():
		return

	var index: int = _tick_index_at(_time)
	var count: int = _tick_map(index).size() if index >= 0 else 0
	var text := (
		"Replace the live crowd with the %d agents at t = %.1f s?\n\n"
		+ "The current crowd and run counters are cleared. Agents load at their "
		+ "recorded positions with their chosen exits, speeds, pre-movement "
		+ "remainder and measurement counters. Exit totals and spawner counts/"
		+ "timers are restored, and the spawners keep spawning.\n\n"
		+ "The recording is continued into a new demo: everything before this "
		+ "point is copied into it, then live recording starts.\n\n"
		+ "Exact paths, queue order and already-evacuated agents are not "
		+ "recreated. After loading, time stays paused with the inventory open; "
		+ "close the inventory to resume."
	) % [count, _time - _started_t]
	_show_scroll_dialog(
		"Load demo state",
		text,
		"Load State",
		_apply_demo_state,
		"Cancel"
	)


func _show_scroll_dialog(
	title: String,
	text: String,
	ok_text: String,
	on_ok: Callable,
	cancel_text: String = ""
) -> void:
	var win := Window.new()
	win.title = title
	win.process_mode = Node.PROCESS_MODE_ALWAYS
	win.exclusive = true
	win.transient = true
	win.unresizable = false
	var theme := Theme.new()
	theme.default_font = FONT
	theme.default_font_size = 15

	var view: Vector2 = get_viewport().get_visible_rect().size
	win.size = Vector2i(
		int(minf(760.0, maxf(420.0, view.x - 80.0))),
		int(minf(560.0, maxf(300.0, view.y - 80.0)))
	)

	var margin := MarginContainer.new()
	margin.theme = theme
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	win.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var label := RichTextLabel.new()
	label.text = text
	label.bbcode_enabled = false
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	if not cancel_text.is_empty():
		var cancel := Button.new()
		cancel.text = cancel_text
		cancel.pressed.connect(func() -> void:
			win.hide()
			win.queue_free()
		)
		buttons.add_child(cancel)

	var ok := Button.new()
	ok.text = ok_text
	ok.pressed.connect(func() -> void:
		win.hide()
		win.queue_free()

		if on_ok.is_valid():
			on_ok.call()
	)
	buttons.add_child(ok)
	win.close_requested.connect(func() -> void:
		win.hide()
		win.queue_free()
	)

	get_tree().root.add_child(win)
	win.popup_centered(win.size)


func _apply_demo_state() -> void:
	var index: int = _tick_index_at(_time)

	if index < 0 or index >= _ticks.size():
		return

	var tick: Dictionary = _ticks[index]
	var map: Dictionary = _tick_map(index)

	var exit_positions: Dictionary = _live_exit_positions()
	var scene: Node = get_tree().current_scene

	if scene == null:
		scene = get_tree().root

	var sim_stats: Dictionary = tick.get("sim", {})
	var tick_time: float = float(tick.get("t", GlobalData.sim_time))
	var max_serial: int = 0
	var loaded: int = 0

	GlobalData.rng_seed = int(
		_meta.get("rng_seed", _meta.get("seed", GlobalData.rng_seed))
	)
	GlobalData.sim_time = tick_time
	GlobalData.set_evacuation_mode(true)
	# Kill the crowd but do not call reset_spawning(): that would stop the
	# spawners and wipe their quotas. The imported agents take over the live
	# population, and the spawners keep working from their recorded counts.
	GlobalData.kill_all_npcs()

	var manager := get_node_or_null("/root/EvacuationManager")

	if manager != null and manager.has_method("reset_run"):
		manager.call("reset_run")

	# Clear the previous run's exit aggregates, then restore the tick's totals.
	for exit_node: Node in get_tree().get_nodes_in_group("EvacPoint"):
		if exit_node != null and exit_node.has_method("reset_counters"):
			exit_node.call("reset_counters")

	_restore_exit_counters(tick)

	var restored_history: int = 0

	if manager != null and manager.has_method("restore_evacuation_history"):
		var run_start: float = _run_start_t
		if run_start < 0.0:
			run_start = _started_t

		restored_history = int(
			manager.call(
				"restore_evacuation_history",
				_events,
				tick_time,
				run_start
			)
		)

	_restore_spawners(tick)

	for serial_value: Variant in map.keys():
		var row: Array = map[serial_value]
		var status: String = _row_string(row, AGENT_STATUS, "")

		if status in ["evacuated", "dead"] or row.size() < 17:
			continue

		var member: Node3D = MEMBER_SCENE.instantiate()
		var serial: int = int(serial_value)
		member.name = "DemoAgent_%d" % serial
		member.position = _row_vector3(row, 3, Vector3.ZERO)
		scene.add_child(member)

		var state: Dictionary = _agent_state_from_row(row, exit_positions)
		member.call("apply_demo_state", state)
		GlobalData.notify_agent_spawned(member)

		if (
			manager != null
			and manager.has_method("restore_agent_spawn_time")
			and float(state.get("spawned_at", -1.0)) >= 0.0
		):
			manager.call(
				"restore_agent_spawn_time",
				member,
				float(state["spawned_at"])
			)

		max_serial = maxi(max_serial, serial)
		loaded += 1

	GlobalData.npcs_spawned = maxi(
		int(sim_stats.get("spawned", 0)), max_serial
	)
	GlobalData.npcs_evacuated = maxi(0, int(sim_stats.get("evacuated", 0)))
	GlobalData.set_agent_serial_floor(maxi(max_serial, GlobalData.npcs_spawned))

	# Continue the source demo into a new recording: copy its prefix through
	# this tick, then append live records. Do this before Start so the
	# start-spawning signal does not create an unrelated blank demo.
	var recorder := get_node_or_null("/root/SimRecorder")

	if recorder != null and not _demo_id.is_empty():
		recorder.call("prepare_continuation", _demo_id, tick_time)

	# Resume spawning. With imported agents alive, start_spawning keeps the
	# serial counter monotonic instead of resetting determinism.
	GlobalData.start_spawning()

	if recorder != null:
		recorder.call("resume_continuation")

	print(
		"DemoPlayer: loaded %d agents and %d earlier evacuations from the recording at t=%.2f"
		% [loaded, restored_history, _time - _started_t]
	)

	close()
	_enter_loaded_workspace()

	var text := (
		"Loaded %d agents at t = %.1f s (%d earlier evacuations replayed).\n\n"
		+ "Restored: serials, positions, chosen exits, desired speeds, "
		+ "pre-movement remainder, route/contact counters, evacuation history, "
		+ "exit admission totals and spawner quota/timers. Spawners keep "
		+ "spawning as before.\n\n"
		+ "A new demo recording was created from everything before this point "
		+ "and is now recording the continuation.\n\n"
		+ "Time is paused and the inventory is open. Close the inventory to "
		+ "resume. Use Optimizer → Run once to optimize from this state."
	) % [loaded, _time - _started_t, restored_history]
	_show_scroll_dialog("Demo state loaded", text, "OK", Callable(), "")


func _enter_loaded_workspace() -> void:
	var tree := get_tree()

	if tree == null:
		return

	var player := tree.get_first_node_in_group("Player")

	if player == null:
		return

	var pause_menu := player.get_node_or_null(
		"head/CameraSmooth/Camera3D/PauseMenu"
	)

	if pause_menu != null and pause_menu.has_method("set_paused"):
		pause_menu.call("set_paused", false)

	var build_controller := player.get_node_or_null("BuildController")

	if build_controller == null:
		return

	_workspace_build_controller = build_controller

	if (
		build_controller.has_signal("inventory_toggled")
		and not build_controller.is_connected(
			"inventory_toggled",
			Callable(self, "_on_workspace_inventory_toggled")
		)
	):
		build_controller.connect(
			"inventory_toggled",
			Callable(self, "_on_workspace_inventory_toggled")
		)

	# Freeze simulation time without pausing the tree, so the inventory and the
	# optimizer panel still receive input. Closing the inventory resumes time.
	_workspace_pause_active = true
	Engine.time_scale = 0.0

	if build_controller.has_method("open_inventory"):
		build_controller.call("open_inventory")
	else:
		build_controller.set("inventory_open", true)
		build_controller.call("_update_build_ui")

	if build_controller.get("hud_manager") == null:
		# No HUD means no inventory to close and no signal will arrive.
		_workspace_pause_active = false
		Engine.time_scale = 1.0


func _on_workspace_inventory_toggled(open: bool) -> void:
	if open or not _workspace_pause_active:
		return

	_workspace_pause_active = false
	Engine.time_scale = 1.0


func _agent_state_from_row(
	row: Array, exit_positions: Dictionary
) -> Dictionary:
	var exit_id: String = _row_string(row, AGENT_EXIT_ID, "")
	var destination: Vector3 = _row_vector3(row, 13, Vector3.ZERO)

	if not exit_id.is_empty() and exit_positions.has(exit_id):
		destination = exit_positions[exit_id]

	return {
		"serial": _row_int(row, 0, 0),
		"status": _row_string(row, AGENT_STATUS, ""),
		"state": _row_int(row, AGENT_STATE, 0),
		"position": _row_vector3(row, 3, Vector3.ZERO),
		"velocity": _row_vector3(row, 6, Vector3.ZERO),
		"acceleration": _row_vector3(row, 9, Vector3.ZERO),
		"destination": destination,
		"exit_id": exit_id,
		"distance": _row_float(row, AGENT_DISTANCE, 0.0),
		"contact_force": _row_float(row, AGENT_CONTACT_FORCE, 0.0),
		"density": _row_float(row, AGENT_DENSITY, 0.0),
		"route_changes": _row_int(row, AGENT_ROUTE_CHANGES, 0),
		"route_switches": _row_int(row, AGENT_ROUTE_SWITCHES, 0),
		"stuck_strikes": _row_int(row, AGENT_STUCK_STRIKES, 0),
		"desired_speed": _row_float(row, AGENT_DESIRED_SPEED, 0.0),
		"pre_movement_delay": _row_float(row, AGENT_PRE_DELAY, 0.0),
		"pre_movement_wait": _row_float(row, AGENT_PRE_WAIT, 0.0),
		"stuck_time": _row_float(row, AGENT_STUCK_TIME, 0.0),
		"is_evacuee": _row_int(row, AGENT_IS_EVACUEE, 1) != 0,
		"has_target": _row_int(row, AGENT_HAS_TARGET, 0) != 0,
		"peak_density": _row_float(row, AGENT_PEAK_DENSITY, 0.0),
		"peak_contact_force": _row_float(row, AGENT_PEAK_CONTACT, 0.0),
		"spawned_at": _row_float(row, AGENT_SPAWNED_AT, -1.0),
		"optimizer_assigned": _row_int(row, AGENT_OPTIMIZER_ASSIGNED, 0) != 0,
		"optimizer_exit_id": _row_string(row, AGENT_OPTIMIZER_EXIT_ID, ""),
	}


func _restore_exit_counters(tick: Dictionary) -> void:
	var rows: Array = tick.get("exits", [])
	var live: Dictionary = _live_exits_by_id()
	var recorded_locations: Dictionary = _recorded_exit_locations()
	var live_positions: Array = []

	for exit_id: String in live:
		var live_node: Node = live[exit_id]

		if live_node is Node3D:
			live_positions.append([live_node, (live_node as Node3D).global_position])

	for row_value: Variant in rows:
		if not row_value is Array:
			continue

		var row: Array = row_value
		var exit_id: String = _row_string(row, 0, "")
		var node: Node = live.get(exit_id)

		if node == null and recorded_locations.has(exit_id):
			var recorded: Vector3 = recorded_locations[exit_id]
			var best_distance: float = 3.0

			for entry: Array in live_positions:
				var distance: float = recorded.distance_to(entry[1])

				if distance < best_distance:
					best_distance = distance
					node = entry[0]

		if node == null:
			continue

		if node.has_method("set_operational"):
			node.call("set_operational", _row_int(row, 2, 1) != 0)

		if not node.has_method("restore_counters"):
			continue

		node.call("restore_counters", {
			"accepted": _row_int(row, EXIT_ACCEPTED, 0),
			"max_queue": _row_int(row, EXIT_MAX_QUEUE, 0),
			"peak_occupancy": _row_int(row, EXIT_PEAK_OCCUPANCY, 0),
			"average_wait": _row_float(row, EXIT_AVERAGE_WAIT, 0.0),
			"max_wait": _row_float(row, EXIT_MAX_WAIT, 0.0),
			"rejected": _row_int(row, EXIT_REJECTED, 0),
			"capacity_waits": _row_int(row, EXIT_CAPACITY_WAITS, 0),
			"capacity_rejections": _row_int(
				row, EXIT_CAPACITY_REJECTIONS, 0
			),
			"queue_full_rejections": _row_int(
				row, EXIT_QUEUE_FULL_REJECTIONS, 0
			),
		})


func _recorded_exit_locations() -> Dictionary:
	var result: Dictionary = {}
	var catalog: Array = _meta.get("exit_configuration", [])

	for value: Variant in catalog:
		if not value is Dictionary:
			continue

		var entry: Dictionary = value
		var location: Array = entry.get("location", [])

		if location.size() < 3:
			continue

		result[String(entry.get("exit_id", ""))] = Vector3(
			float(location[0]), float(location[1]), float(location[2])
		)

	return result


func _restore_spawners(tick: Dictionary) -> void:
	var states: Array = tick.get("spawners", [])

	if states.is_empty():
		return

	var live: Dictionary = {}
	var by_name: Dictionary = {}
	var by_position: Array = []

	for node: Node in get_tree().get_nodes_in_group("spawners"):
		if node == null or not is_instance_valid(node):
			continue

		live[String(node.get_path())] = node

		if not by_name.has(String(node.name)):
			by_name[String(node.name)] = node

		if node is Node3D:
			by_position.append([node, (node as Node3D).global_position])

	for value: Variant in states:
		if not value is Dictionary:
			continue

		var state: Dictionary = value
		var node: Node = live.get(String(state.get("path", "")))

		if node == null:
			node = by_name.get(String(state.get("name", "")))

		if node == null:
			var recorded: Array = state.get("position", [])
			var target := Vector3.ZERO

			if recorded.size() >= 3:
				target = Vector3(
					float(recorded[0]), float(recorded[1]), float(recorded[2])
				)
				var best_distance: float = 2.0

				for entry: Array in by_position:
					var candidate: Node = entry[0]
					var distance: float = target.distance_to(entry[1])

					if distance < best_distance:
						best_distance = distance
						node = candidate

		if node != null and node.has_method("restore_measurement_state"):
			node.call("restore_measurement_state", state)


func _live_exits_by_id() -> Dictionary:
	var result: Dictionary = {}

	for node: Node in get_tree().get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node):
			continue

		if not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")
		result[String(status.get("exit_id", ""))] = node

	return result


func _row_value(row: Array, index: int, fallback: Variant) -> Variant:
	return row[index] if index >= 0 and index < row.size() else fallback


func _row_string(row: Array, index: int, fallback: String) -> String:
	return String(_row_value(row, index, fallback))


func _row_int(row: Array, index: int, fallback: int) -> int:
	return int(_row_value(row, index, fallback))


func _row_float(row: Array, index: int, fallback: float) -> float:
	return float(_row_value(row, index, fallback))


func _row_vector3(row: Array, start: int, fallback: Vector3) -> Vector3:
	return Vector3(
		_row_float(row, start, fallback.x),
		_row_float(row, start + 1, fallback.y),
		_row_float(row, start + 2, fallback.z)
	)


func _live_exit_positions() -> Dictionary:
	var positions: Dictionary = {}
	var tree: SceneTree = get_tree()

	if tree == null:
		return positions

	for node: Node in tree.get_nodes_in_group("EvacPoint"):
		if node == null or not is_instance_valid(node):
			continue

		if not node.has_method("get_exit_status"):
			continue

		var status: Dictionary = node.call("get_exit_status")
		positions[String(status.get("exit_id", ""))] = (
			node as Node3D
		).global_position

	return positions


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "DemoPlayerUI"
	_layer.layer = 40
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)

	_ui = Control.new()
	_ui.name = "DemoPlayer"
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_STOP

	var theme := Theme.new()
	theme.default_font = FONT
	theme.default_font_size = 14
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
	_title.text = "DEMO"
	top_row.add_child(_title)

	_state_label = Label.new()
	_state_label.add_theme_color_override("font_color", MUTED)
	top_row.add_child(_state_label)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(close)
	top_row.add_child(close_button)

	# Right-hand inspector: leaves the map visible on the left.
	var side := PanelContainer.new()
	side.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	side.offset_left = -470
	side.offset_right = -12
	side.offset_top = 62
	side.offset_bottom = -132
	side.add_theme_stylebox_override("panel", _style(BG))
	_ui.add_child(side)

	var side_root := VBoxContainer.new()
	side_root.add_theme_constant_override("separation", 4)
	side.add_child(side_root)

	var inspector_title := Label.new()
	inspector_title.text = "AGENT INSPECTOR"
	inspector_title.add_theme_color_override("font_color", GOLD)
	side_root.add_child(inspector_title)

	_inspector = RichTextLabel.new()
	_inspector.bbcode_enabled = true
	_inspector.fit_content = false
	_inspector.scroll_active = true
	_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_inspector.custom_minimum_size = Vector2(0, 180)
	side_root.add_child(_inspector)

	var event_title := Label.new()
	event_title.text = "EVENT TIMELINE"
	event_title.add_theme_color_override("font_color", GOLD)
	side_root.add_child(event_title)

	_event_log = RichTextLabel.new()
	_event_log.bbcode_enabled = true
	_event_log.fit_content = false
	_event_log.scroll_active = true
	_event_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_event_log.custom_minimum_size = Vector2(0, 140)
	side_root.add_child(_event_log)

	# Bottom transport/timeline bar.
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_left = 12
	_panel.offset_right = -12
	_panel.offset_top = -132
	_panel.offset_bottom = -10
	_panel.add_theme_stylebox_override("panel", _style(BG))
	_ui.add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	_panel.add_child(root)

	# Controls can exceed the width at high agent/demo counts. Keep them in a
	# horizontal scroller so the right-hand buttons remain reachable.
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

	var step_back := _button("< Frame", func() -> void: _step(-1))
	controls.add_child(step_back)

	var step_forward := _button("Frame >", func() -> void: _step(1))
	controls.add_child(step_forward)

	_speed_button = _button("Speed 1x", _cycle_speed)
	controls.add_child(_speed_button)

	_noclip_button = _button("Noclip", Callable())
	_noclip_button.tooltip_text = "Tap: toggle free flight  ·  Hold: reset camera to overview"
	_noclip_button.button_down.connect(_begin_noclip_hold)
	_noclip_button.button_up.connect(_end_noclip_hold)
	controls.add_child(_noclip_button)

	var load_state_button := _button("Load State", _show_load_state_dialog)
	load_state_button.tooltip_text = (
		"Replace the live crowd with the agents at the current playback time, "
		+ "then run the optimizer on that state."
	)
	controls.add_child(load_state_button)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(150, 0)
	_time_label.add_theme_color_override("font_color", TEXT)
	controls.add_child(_time_label)

	controls.add_child(_spacer())

	var agent_label := Label.new()
	agent_label.text = "Agent"
	agent_label.add_theme_color_override("font_color", MUTED)
	controls.add_child(agent_label)

	_agent_select = OptionButton.new()
	_agent_select.custom_minimum_size = Vector2(150, 0)
	_agent_select.item_selected.connect(_on_agent_selected)
	controls.add_child(_agent_select)

	var mode_label := Label.new()
	mode_label.text = "View"
	mode_label.add_theme_color_override("font_color", MUTED)
	controls.add_child(mode_label)

	_mode_select = OptionButton.new()
	_mode_select.add_item("Status")
	_mode_select.add_item("Density heat")
	_mode_select.add_item("Contact force")
	_mode_select.add_item("Exit assignment")
	_mode_select.item_selected.connect(func(index: int) -> void: _mode = index)
	controls.add_child(_mode_select)

	_route_check = CheckBox.new()
	_route_check.text = "Route"
	_route_check.button_pressed = true
	_route_check.toggled.connect(func(on: bool) -> void:
		_show_route = on
		_last_route_key = ""
	)
	controls.add_child(_route_check)

	_timeline = HSlider.new()
	_timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline.custom_minimum_size = Vector2(0, 20)
	_timeline.value_changed.connect(_on_timeline_changed)
	root.add_child(_timeline)


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


func _build_agent_select() -> void:
	_agent_select.clear()
	var serials: Array = _proxies.keys()
	serials.sort()

	for serial: int in serials:
		_agent_select.add_item("#%d" % serial)
		_agent_select.set_item_metadata(_agent_select.item_count - 1, serial)

	if _agent_select.item_count > 0:
		_agent_select.select(0)
		_selected_serial = int(_agent_select.get_item_metadata(0))


func _toggle_play() -> void:
	_playing = not _playing
	_play_button.text = "Pause" if _playing else "Play"

	if _playing and _time >= _duration:
		_time = _started_t


func _cycle_speed() -> void:
	var speeds: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0]
	var index: int = speeds.find(_speed)
	_speed = speeds[(index + 1) % speeds.size()]
	_speed_button.text = "Speed %sx" % str(_speed)


func _step(direction: int) -> void:
	_playing = false
	_play_button.text = "Play"
	var index: int = _tick_index_at(_time) + direction

	if direction > 0 and index <= _tick_index_at(_time):
		index = _tick_index_at(_time) + 1

	index = clampi(index, 0, _ticks.size() - 1)
	_time = float(_ticks[index].get("t", _time))
	_update_scene(true)


func _on_timeline_changed(value: float) -> void:
	_time = value
	_playing = false
	_play_button.text = "Play"
	_update_scene(true)


func _on_agent_selected(index: int) -> void:
	_selected_serial = int(_agent_select.get_item_metadata(index))
	_last_route_key = ""
	_update_scene(true)


func _update_text(_force: bool) -> void:
	var relative: float = _time - _started_t
	_time_label.text = "t %.2f / %.2f s" % [relative, _duration - _started_t]
	_state_label.text = "PLAYING" if _playing else "PAUSED"

	if _noclip:
		_state_label.text += "  ·  NOCLIP %.1f m/s" % (
			NOCLIP_BASE_SPEED * _noclip_speed_mult
		)

	var index: int = _tick_index_at(_time)
	var tick: Dictionary = _ticks[index] if index >= 0 else {}
	_update_inspector(tick)
	_update_event_log()


func _update_inspector(_tick: Dictionary) -> void:
	if _selected_serial < 0:
		_inspector.text = "[color=#aaa]No agent selected[/color]"
		return

	var row: Variant = _tick_map(_tick_index_at(_time)).get(_selected_serial)
	var lines: Array[String] = []
	lines.append("[color=#f5d45a]Agent #%d[/color]" % _selected_serial)

	if row == null:
		lines.append("[color=#aaa]Not active at this time[/color]")
	else:
		lines.append("Status: %s" % String(row[1]))
		lines.append("Exit: %s" % (String(row[16]) if String(row[16]) != "" else "—"))
		lines.append("Route: %d  index %d/%d" % [int(row[17]), int(row[18]), int(row[19])])
		lines.append("Speed %.2f m/s  Density %.2f/m²" % [float(row[9]), float(row[24])])
		lines.append("Contact %.0f N  Distance %.1f m" % [float(row[23]), float(row[22])])
		lines.append("Changes %d  Switches %d" % [int(row[25]), int(row[26])])

	lines.append("")
	lines.append("[color=#f5d45a]History[/color]")

	for route: Dictionary in _routes.get(_selected_serial, []):
		if float(route.get("t", 0.0)) > _time:
			break

		lines.append("%.2f  route %d  %s → %s%s" % [
			float(route.get("t", 0.0)) - _started_t,
			int(route.get("route_id", 0)),
			String(route.get("reason", "")),
			String(route.get("exit_id", "—")),
			("  [switched]" if bool(route.get("switched", false)) else ""),
		])

		if route.has("disruption_id") and not String(route.get("disruption_id", "")).is_empty():
			lines.append("        after disruption %s" % String(route.get("disruption_id")))

	for event: Dictionary in _events:
		var type := String(event.get("type", ""))
		var agent := int(event.get("agent", -1))
		var affected: Array = event.get("affected", [])
		var touches_agent := agent == _selected_serial or affected.has(_selected_serial)

		if not touches_agent or float(event.get("t", 0.0)) > _time:
			continue

		if type == "evacuation":
			lines.append("%.2f  EVACUATED via %s (%.2fs)" % [
				float(event.get("t", 0.0)) - _started_t,
				String(event.get("exit_id", "")),
				float(event.get("evacuation_time", 0.0)),
			])
		elif type == "destination":
			lines.append("%.2f  destination %s → %s" % [
				float(event.get("t", 0.0)) - _started_t,
				String(event.get("previous_exit_id", "—")) if not String(event.get("previous_exit_id", "")).is_empty() else "—",
				String(event.get("exit_id", "—")),
			])
		elif type == "queue":
			lines.append("%.2f  queue %s at %s" % [
				float(event.get("t", 0.0)) - _started_t,
				String(event.get("event", "")),
				String(event.get("exit_id", "")),
			])
		elif type == "contact":
			lines.append("%.2f  contact %s %.0f N" % [
				float(event.get("t", 0.0)) - _started_t,
				"above" if bool(event.get("rising", false)) else "below",
				float(event.get("threshold", 0.0)),
			])

	_inspector.text = "\n".join(PackedStringArray(lines))


func _update_event_log() -> void:
	if _events.is_empty():
		_event_log.text = "[color=#aaa]No events recorded.[/color]"
		return

	var lines: Array[String] = []
	var current_index: int = 0

	for index: int in range(_events.size()):
		if float(_events[index].get("t", 0.0)) <= _time:
			current_index = index
		else:
			break

	var start: int = maxi(0, current_index - 6)
	var end: int = mini(_events.size(), current_index + 7)

	for index: int in range(start, end):
		var event: Dictionary = _events[index]
		var marker := ">" if index == current_index else " "
		var color := "#f5d45a" if index == current_index else "#c8c8c0"
		lines.append(
			"[color=%s]%s %.2f  %s[/color]" % [
				color,
				marker,
				float(event.get("t", 0.0)) - _started_t,
				_event_summary(event),
			]
		)

	_event_log.text = "\n".join(PackedStringArray(lines))


func _environment_summary(event: Dictionary) -> String:
	var kind := String(event.get("kind", "change"))
	var cells := int(event.get("cell_count", 0))
	var item := String(event.get("item_name", ""))
	var detail: Dictionary = event.get("detail", {})
	var text := ""

	match kind:
		"block_added":
			text = "placed"
		"block_removed":
			text = "broke"
		"placeable_added":
			text = "placeable placed"
		"placeable_removed":
			text = "placeable removed"
		"water_placed":
			text = "water placed"
		"exit_added":
			text = "exit added"
		"exit_removed":
			text = "exit removed"
		"exit_enabled":
			text = "exit enabled"
		"exit_disabled":
			text = "exit disabled"
		_:
			text = kind.replace("_", " ")

	if cells > 0:
		text += " %d cell%s" % [cells, "" if cells == 1 else "s"]

	if not item.is_empty():
		text += " · " + item
	elif detail.has("scene"):
		var scene := String(detail.get("scene", ""))
		text += " · " + scene.substr(scene.rfind("/") + 1)
	elif detail.has("water_kind"):
		text += " · " + String(detail.get("water_kind", ""))

	return text


func _event_summary(event: Dictionary) -> String:
	var type := String(event.get("type", ""))

	match type:
		"agent_spawn":
			return "spawn #%d" % int(event.get("agent", -1))
		"route":
			return "route #%d agent #%d %s" % [
				int(event.get("route_id", 0)),
				int(event.get("agent", -1)),
				String(event.get("reason", "")),
			]
		"route_change":
			return "REASSIGN #%d → %s" % [
				int(event.get("agent", -1)),
				String(event.get("exit_id", "")),
			]
		"destination":
			return "destination #%d → %s" % [
				int(event.get("agent", -1)),
				String(event.get("exit_id", "")),
			]
		"evacuation":
			return "evacuated #%d via %s" % [
				int(event.get("agent", -1)),
				String(event.get("exit_id", "")),
			]
		"queue":
			return "queue %s agent #%d (%d waiting)" % [
				String(event.get("event", "")),
				int(event.get("agent", -1)),
				int(event.get("queue_length", 0)),
			]
		"contact":
			return "contact #%d %s %.0f N" % [
				int(event.get("agent", -1)),
				"rise" if bool(event.get("rising", false)) else "fall",
				float(event.get("threshold", 0.0)),
			]
		"environment":
			return _environment_summary(event)
		"disruption":
			return "DISRUPTION %s (%d affected)" % [
				String(event.get("kind", "")),
				int(event.get("affected_count", 0)),
			]
		"exit_state":
			return "exit %s %s" % [
				String(event.get("exit_id", "")),
				"open" if bool(event.get("available", true)) else "closed",
			]
		"optimizer":
			return "optimizer %s" % String(event.get("name", ""))
		"agent_death":
			return "death #%d" % int(event.get("agent", -1))
		_:
			return type
