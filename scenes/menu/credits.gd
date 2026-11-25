extends Node3D

## 3D credits screen in the menu visual language. Credits are data-driven from
## `resources/credits/credits.json`; typing filters the music credits, and
## MusicManager supplies the now-playing track and playlist.

const MENU_LAYER: int = 1 << 9
const MAIN_MENU_SCENE := "res://scenes/menu/main_menu.tscn"
const DATA_PATH := "res://resources/credits/credits.json"

const PIXEL_FONT: Font = preload("res://font/Pixelta.ttf")
const BODY_FONT: Font = preload("res://font/dogicapixel.ttf")
const UI_SOUND_HOVER := preload("res://sounds/ui/menu_hover.wav")
const UI_SOUND_CLICK := preload("res://sounds/ui/menu_click.wav")
const UI_SOUND_TRANSITION := preload("res://sounds/ui/menu_transition.wav")

const GOLD := Color(1.0, 0.84, 0.32, 1.0)
const WHITE := Color(0.93, 0.95, 0.98, 1.0)
const MUTED := Color(0.62, 0.68, 0.78, 1.0)

const COLUMN_LEFT: float = -0.66
const COLUMN_RIGHT: float = 0.66
const COLUMN_TOP: float = 0.44
const MUSIC_LIMIT: int = 4

@onready var _camera: Camera3D = $Camera3D
@onready var _panel: Node3D = $Panel
@onready var _main_title: Label3D = $Panel/MainTitle
@onready var _subtitle: Label3D = $Panel/Subtitle
@onready var _now_playing: Label3D = $Panel/NowPlaying
@onready var _credits_list: Node3D = $Panel/CreditsList
@onready var _music_title: Label3D = $Panel/MusicTitle
@onready var _music_list: Node3D = $Panel/MusicList
@onready var _search_label: Label3D = $Panel/SearchLabel
@onready var _hint: Label3D = $Panel/Hint
@onready var _back_button: Area3D = $Panel/BackButton

var _data: Dictionary = {}
var _search_text: String = ""
var _hovered: Area3D = null
var _panel_rest_position: Vector3 = Vector3.ZERO
var _panel_rest_rotation: Vector3 = Vector3.ZERO
var _camera_h_rest: float = 0.0
var _camera_v_rest: float = 0.0
var _cursor_nx: float = 0.0
var _cursor_ny: float = 0.0
var _sway_tween: Tween = null
var _intro_labels: Array[Label3D] = []
var _credits_entries: Array[Dictionary] = []
var _credits_scroll: float = 0.0
var _credits_scroll_limit: float = 0.0
var _ui_players: Array[AudioStreamPlayer] = []
var _ui_play_index: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_setup_ui_audio()
	_panel_rest_position = _panel.position
	_panel_rest_rotation = _panel.rotation
	_panel.scale = Vector3.ONE * 1.25
	_camera_h_rest = _camera.h_offset
	_camera_v_rest = _camera.v_offset

	_load_data()
	_render_credits()
	_render_music("")
	_update_search_label()
	_connect_music()
	_play_intro()
	MusicManager.play_menu_playlist()


func _connect_music() -> void:
	if MusicManager.track_changed.is_connected(_on_track_changed):
		return

	MusicManager.track_changed.connect(_on_track_changed)
	_on_track_changed(MusicManager.get_current_track())


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_set_cursor_sway(event.position)
		_set_hover(_button_at(event.position), true)
		_sway_to(_hovered)
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_click_at(event.position)
			if is_inside_tree():
				get_viewport().set_input_as_handled()
		elif (
			event.pressed
			and (
				event.button_index == MOUSE_BUTTON_WHEEL_UP
				or event.button_index == MOUSE_BUTTON_WHEEL_DOWN
			)
		):
			_handle_credits_wheel(event)
		return

	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_go_back()
		return

	if event is InputEventKey and event.pressed:
		_handle_search_key(event)


func _handle_credits_wheel(event: InputEventMouseButton) -> void:
	if _credits_scroll_limit <= 0.0:
		return

	var step := -0.12 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.12
	_credits_scroll = clampf(_credits_scroll + step, 0.0, _credits_scroll_limit)
	_apply_credits_scroll()
	get_viewport().set_input_as_handled()


func _handle_search_key(event: InputEventKey) -> void:
	if event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_go_back()
		return

	if event.keycode == KEY_BACKSPACE:
		if not _search_text.is_empty():
			_search_text = _search_text.substr(0, _search_text.length() - 1)
			_render_music(_search_text)
			_update_search_label()
		get_viewport().set_input_as_handled()
		return

	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		return

	var unicode: int = event.unicode

	if unicode >= 32 and unicode < 127 and _search_text.length() < 28:
		_search_text += char(unicode)
		_render_music(_search_text)
		_update_search_label()
		get_viewport().set_input_as_handled()


func _go_back() -> void:
	_play_ui(UI_SOUND_CLICK, -8.0)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ============================================================
# DATA
# ============================================================

func _load_data() -> void:
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)

	if file == null:
		_data = _fallback_data()
		return

	var parsed: Variant = JSON.parse_string(file.get_as_text())

	if parsed is Dictionary:
		_data = parsed
	else:
		_data = _fallback_data()

	var subtitle := String(_data.get("subtitle", "")).strip_edges()
	if not subtitle.is_empty():
		_subtitle.text = subtitle


func _fallback_data() -> Dictionary:
	return {
		"subtitle": "SHS Final Capstone Project",
		"sections": [
			{
				"title": "LEAD DEVELOPER & RESEARCHER",
				"entries": [
					{
						"name": "Ed Lawrence Zenarosa",
						"roles": ["Lead Developer", "Researcher"],
					},
				],
			},
		],
	}


# ============================================================
# 3D LABELS
# ============================================================

func _make_label(
	parent: Node3D,
	text_value: String,
	font_value: Font,
	font_size: int,
	pixel: float,
	color: Color,
	position: Vector3
) -> Label3D:
	var label := Label3D.new()
	label.text = text_value
	label.font = font_value
	label.font_size = font_size
	label.pixel_size = pixel
	label.modulate = color
	label.outline_modulate = Color(0, 0, 0, 0.85)
	label.outline_size = 6
	label.no_depth_test = true
	label.render_priority = 5
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.position = position
	parent.add_child(label)
	return label


func _clear(node: Node3D) -> void:
	for child in node.get_children():
		child.queue_free()


func _render_credits() -> void:
	_clear(_credits_list)
	_intro_labels.clear()
	_credits_entries.clear()

	var sections_value: Variant = _data.get("sections", [])
	var sections: Array = sections_value if sections_value is Array else []
	var y: float = COLUMN_TOP
	var wrote_any := false

	for section_value: Variant in sections:
		if not section_value is Dictionary:
			continue

		var section: Dictionary = section_value
		var entries_value: Variant = section.get("entries", [])
		var entries: Array = entries_value if entries_value is Array else []

		if entries.is_empty():
			continue

		var title := String(section.get("title", "")).strip_edges()

		if not title.is_empty():
			y -= 0.03
			y = _add_section_header(title, y)
			y -= 0.02

		for entry_value: Variant in entries:
			if not entry_value is Dictionary:
				continue

			var entry: Dictionary = entry_value
			var person := String(entry.get("name", "")).strip_edges()

			if person.is_empty():
				continue

			_add_credit_label(
				_shorten(person, 22),
				PIXEL_FONT,
				30,
				0.0015,
				WHITE,
				y
			)
			y -= 0.09

			var roles_text := _roles_text(entry.get("roles", []))
			if not roles_text.is_empty():
				_add_credit_label(
					_shorten(roles_text, 32),
					BODY_FONT,
					24,
					0.0013,
					MUTED,
					y
				)
				y -= 0.075

			y -= 0.04
			wrote_any = true

		y -= 0.04

	if not wrote_any:
		_add_credit_label(
			"No credits listed yet.",
			BODY_FONT,
			24,
			0.0014,
			MUTED,
			COLUMN_TOP
		)

	var min_y := 0.0
	for entry: Dictionary in _credits_entries:
		min_y = minf(min_y, float(entry.get("base_y", 0.0)))

	_credits_scroll_limit = maxf(0.0, -0.45 - min_y)
	_credits_scroll = 0.0
	_apply_credits_scroll()


func _add_credit_label(
	text_value: String,
	font_value: Font,
	font_size: int,
	pixel: float,
	color: Color,
	y: float
) -> void:
	var label := _make_label(
		_credits_list,
		text_value,
		font_value,
		font_size,
		pixel,
		color,
		Vector3(COLUMN_LEFT, y, 0.04)
	)
	_intro_labels.append(label)
	_credits_entries.append({"node": label, "base_y": y})


func _apply_credits_scroll() -> void:
	_credits_list.position.y = _credits_scroll

	for entry: Dictionary in _credits_entries:
		var node: Variant = entry.get("node")

		if node == null or not is_instance_valid(node):
			continue

		var screen_y: float = float(entry.get("base_y", 0.0)) + _credits_scroll
		(node as Label3D).visible = screen_y <= 0.52 and screen_y >= -0.45


func _add_section_header(text_value: String, y: float) -> float:
	var pieces := _split_header(text_value)

	for piece in pieces:
		_add_credit_label(
			piece,
			PIXEL_FONT,
			34,
			0.0016,
			GOLD,
			y
		)
		y -= 0.085

	return y


func _split_header(text_value: String) -> Array[String]:
	var text := String(text_value).strip_edges()

	if text.length() <= 20:
		return [text]

	var separator := text.find(" & ")

	if separator < 0:
		separator = text.find(" AND ")

	if separator >= 0:
		var first := text.substr(0, separator).strip_edges()
		var second := text.substr(separator + 1).strip_edges()
		return [first, second]

	var middle := text.length() >> 1
	var left_space := text.rfind(" ", middle)
	var right_space := text.find(" ", middle)
	var split_at := left_space

	if split_at < 0 or (right_space >= 0 and right_space - middle < middle - split_at):
		split_at = right_space

	if split_at <= 0 or split_at >= text.length() - 1:
		return [text]

	return [
		text.substr(0, split_at).strip_edges(),
		text.substr(split_at + 1).strip_edges(),
	]


func _shorten(value: Variant, max_chars: int) -> String:
	var text := String(value).strip_edges()
	if text.length() <= max_chars or max_chars <= 3:
		return text
	return text.substr(0, max_chars - 3).strip_edges() + "..."


func _roles_text(value: Variant) -> String:
	if value is String:
		return String(value)

	if not value is Array:
		return ""

	var parts: Array[String] = []

	for role: Variant in value:
		var text := String(role).strip_edges()
		if not text.is_empty():
			parts.append(text)

	if parts.is_empty():
		return ""
	if parts.size() == 1:
		return parts[0]
	if parts.size() == 2:
		return "%s and %s" % [parts[0], parts[1]]

	var leading := ", ".join(PackedStringArray(parts.slice(0, parts.size() - 1)))
	return "%s and %s" % [leading, parts[parts.size() - 1]]


func _render_music(query: String) -> void:
	_clear(_music_list)

	var needle := query.strip_edges().to_lower()
	var entries: Array = MusicManager.get_music_entries()
	var matches: Array[Dictionary] = []

	for entry_value: Variant in entries:
		if not entry_value is Dictionary:
			continue

		var entry: Dictionary = entry_value
		var title := String(entry.get("title", "")).strip_edges()
		var artist := String(entry.get("artist", "")).strip_edges()
		var source := String(entry.get("source", "")).strip_edges()
		var license := String(entry.get("license", "")).strip_edges()
		var haystack := "%s %s %s %s" % [title, artist, source, license]

		if needle.is_empty() or haystack.to_lower().contains(needle):
			matches.append(entry)

	var y: float = COLUMN_TOP
	var current_source := MusicManager.current_source()

	if matches.is_empty():
		_intro_labels.append(_make_label(
			_music_list,
			"No music credits match.",
			BODY_FONT,
			20,
			0.0012,
			MUTED,
			Vector3(COLUMN_RIGHT, y, 0.04)
		))
		return

	_intro_labels.append(_make_label(
		_music_list,
		"%d track%s" % [matches.size(), "" if matches.size() == 1 else "s"],
		BODY_FONT,
		24,
		0.0013,
		MUTED,
		Vector3(COLUMN_RIGHT, y, 0.04)
	))
	y -= 0.085

	var shown := mini(matches.size(), MUSIC_LIMIT)

	for index in shown:
		var entry: Dictionary = matches[index]
		var source := String(entry.get("source", ""))
		var marker := "> " if source == current_source else ""
		var title := String(entry.get("title", "")).strip_edges()
		var artist := String(entry.get("artist", "")).strip_edges()

		_intro_labels.append(_make_label(
			_music_list,
			marker + _shorten(title, 24),
			PIXEL_FONT,
			28,
			0.0014,
			GOLD,
			Vector3(COLUMN_RIGHT, y, 0.04)
		))
		y -= 0.08

		_intro_labels.append(_make_label(
			_music_list,
			_shorten(artist, 30) if not artist.is_empty() else "Unknown artist",
			BODY_FONT,
			24,
			0.0013,
			WHITE,
			Vector3(COLUMN_RIGHT, y, 0.04)
		))
		y -= 0.075
		y -= 0.02

	if matches.size() > shown:
		_intro_labels.append(_make_label(
			_music_list,
			"+%d more - type to narrow" % (matches.size() - shown),
			BODY_FONT,
			22,
			0.0012,
			MUTED,
			Vector3(COLUMN_RIGHT, y, 0.04)
		))


func _update_search_label() -> void:
	_search_label.text = (
		"SEARCH: %s_" % _shorten(_search_text, 28)
		if not _search_text.is_empty()
		else "TYPE TO SEARCH MUSIC"
	)


func _on_track_changed(track: Dictionary) -> void:
	var title := String(track.get("title", "")).strip_edges()
	var artist := String(track.get("artist", "")).strip_edges()

	if title.is_empty():
		_now_playing.text = ""
	elif artist.is_empty():
		_now_playing.text = "NOW PLAYING: " + _shorten(title, 32)
	else:
		_now_playing.text = "NOW PLAYING: %s - %s" % [
			_shorten(title, 30),
			_shorten(artist, 18),
		]

	_render_music(_search_text)


func _play_intro() -> void:
	_panel.position = _panel_rest_position + Vector3(0.18, 0.0, -0.12)

	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_panel, "position", _panel_rest_position, 0.42)
	tween.tween_method(_set_intro_alpha, 0.0, 1.0, 0.34)


func _set_intro_alpha(value: float) -> void:
	for label in _intro_labels:
		if is_instance_valid(label):
			label.modulate.a = value


# ============================================================
# INPUT / SWAY
# ============================================================

func _button_at(screen_position: Vector2) -> Area3D:
	if _camera == null or not is_instance_valid(_camera) or not _camera.is_inside_tree():
		return null

	var from: Vector3 = _camera.project_ray_origin(screen_position)
	var to: Vector3 = from + _camera.project_ray_normal(screen_position) * 10.0
	var query := PhysicsRayQueryParameters3D.create(from, to, MENU_LAYER)
	query.collide_with_areas = true
	query.collide_with_bodies = false

	var hit: Dictionary = _camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null

	var collider: Object = hit.get("collider")
	if collider is Area3D and collider.has_method("set_hovered"):
		return collider
	return null


func _click_at(screen_position: Vector2) -> void:
	var button := _button_at(screen_position)
	if button == null:
		return

	_play_ui(UI_SOUND_CLICK, -8.0)

	if String(button.action) == "back":
		_go_back()


func _set_hover(button: Area3D, audible: bool = false) -> void:
	if _hovered == button:
		return

	if is_instance_valid(_hovered):
		_hovered.set_hovered(false)

	_hovered = button

	if is_instance_valid(_hovered):
		_hovered.set_hovered(true)
		if audible:
			_play_ui(UI_SOUND_HOVER, -14.0)

	_sway_to(button)


func _set_cursor_sway(screen_position: Vector2) -> void:
	var viewport_size := get_viewport().get_visible_rect().size

	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	_cursor_nx = clampf((screen_position.x / viewport_size.x) * 2.0 - 1.0, -1.0, 1.0)
	_cursor_ny = clampf((screen_position.y / viewport_size.y) * 2.0 - 1.0, -1.0, 1.0)


func _sway_to(button: Area3D) -> void:
	if is_instance_valid(_sway_tween):
		_sway_tween.kill()

	var target_position: Vector3 = _panel_rest_position
	var target_rotation: Vector3 = _panel_rest_rotation
	var target_h: float = _camera_h_rest
	var target_v: float = _camera_v_rest

	target_position += Vector3(-_cursor_nx * 0.016, -_cursor_ny * 0.013, 0.0)
	target_rotation += Vector3(
		deg_to_rad(_cursor_ny * 0.35),
		deg_to_rad(_cursor_nx * 0.45),
		0.0
	)
	target_h += -_cursor_nx * 0.03
	target_v += -_cursor_ny * 0.026

	if is_instance_valid(button):
		var local: Vector3 = _panel.to_local(button.global_position)
		var nx: float = clampf(local.x / 1.1, -1.0, 1.0)
		var ny: float = clampf(local.y / 0.9, -1.0, 1.0)
		target_position += Vector3(-nx * 0.02, -ny * 0.016, 0.0)
		target_h += -nx * 0.045
		target_v += -ny * 0.035

	_sway_tween = create_tween().set_parallel(true)
	_sway_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_sway_tween.tween_property(_panel, "position", target_position, 0.4)
	_sway_tween.tween_property(_panel, "rotation", target_rotation, 0.4)
	_sway_tween.tween_property(_camera, "h_offset", target_h, 0.4)
	_sway_tween.tween_property(_camera, "v_offset", target_v, 0.4)


func _setup_ui_audio() -> void:
	for index in 6:
		var player := AudioStreamPlayer.new()
		player.name = "UISound%d" % index
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		player.bus = &"Master"
		add_child(player)
		_ui_players.append(player)


func _play_ui(stream: AudioStream, volume_db: float = -8.0) -> void:
	if stream == null or _ui_players.is_empty():
		return

	var player: AudioStreamPlayer = _ui_players[_ui_play_index]
	_ui_play_index = (_ui_play_index + 1) % _ui_players.size()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = randf_range(0.96, 1.04)
	player.play()
