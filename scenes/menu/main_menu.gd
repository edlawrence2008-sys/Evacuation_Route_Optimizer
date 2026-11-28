extends Node3D

## Standalone 3D main menu in the same visual language as the pause menu:
## angled 3D panel, Label3D title, reusable pause_button_3d rows, gold hover,
## staggered intros, UI blips and a dim voxel backdrop.

const MENU_LAYER: int = 1 << 9
const CREDITS_SCENE := "res://scenes/menu/credits.tscn"

const PIXEL_FONT: Font = preload("res://font/Pixelta.ttf")

const UI_SOUND_HOVER := preload("res://sounds/ui/menu_hover.wav")
const UI_SOUND_CLICK := preload("res://sounds/ui/menu_click.wav")
const UI_SOUND_TRANSITION := preload("res://sounds/ui/menu_transition.wav")
const UI_SOUND_ACCEPT := preload("res://sounds/ui/accept.wav")

@onready var _camera: Camera3D = $Camera3D
@onready var _dim: MeshInstance3D = $Dim
@onready var _panel: Node3D = $Panel
@onready var _main_title: Label3D = $Panel/MainTitle
@onready var _subtitle: Label3D = $Panel/Subtitle
@onready var _tagline: Label3D = $Panel/Tagline
@onready var _section_title: Label3D = $Panel/SectionTitle
@onready var _hint: Label3D = $Panel/Hint
@onready var _main_panel: Node3D = $Panel/MainPanel
@onready var _extras_panel: Node3D = $Panel/ExtrasPanel
@onready var _settings_panel: Node3D = $Panel/SettingsPanel
@onready var _graphics_panel: Node3D = $Panel/GraphicsPanel
@onready var _sky_clouds_panel: Node3D = $Panel/SkyCloudsPanel
@onready var _gameplay_panel: Node3D = $Panel/GameplayPanel
@onready var _audio_panel: Node3D = $Panel/AudioPanel
@onready var _saves_overlay: Node3D = $Camera3D/SavesOverlay

var _view: String = "main"
var _hovered: Area3D = null
var _panel_rest_position: Vector3 = Vector3.ZERO
var _panel_rest_rotation: Vector3 = Vector3.ZERO
var _section_rest_position: Vector3 = Vector3.ZERO
var _title_rest_position: Vector3 = Vector3.ZERO
var _title_rest_rotation: Vector3 = Vector3.ZERO
var _dim_material: StandardMaterial3D = null
var _dim_alpha: float = 0.9
var _camera_h_rest: float = 0.0
var _camera_v_rest: float = 0.0
var _title_root: Node3D = null
var _title_letters: Array = []
var _title_tween: Tween = null
var _section_tween: Tween = null
var _sway_tween: Tween = null
var _ui_players: Array[AudioStreamPlayer] = []
var _ui_play_index: int = 0
var _cursor_nx: float = 0.0
var _cursor_ny: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	_setup_ui_audio()

	_panel_rest_position = _panel.position
	_panel_rest_rotation = _panel.rotation
	_section_rest_position = _section_title.position
	_dim_material = _dim.material_override as StandardMaterial3D
	if _dim_material != null:
		_dim_alpha = _dim_material.albedo_color.a
	_camera_h_rest = _camera.h_offset
	_camera_v_rest = _camera.v_offset

	_fit_to_camera()
	_fit_title()
	_build_title_letters()
	_show_view("main", false, false)
	_play_open_intro()

	if _saves_overlay != null and _saves_overlay.has_signal("saves_closed"):
		_saves_overlay.saves_closed.connect(_on_saves_closed)

	if _saves_overlay != null and _saves_overlay.has_signal("save_loaded"):
		_saves_overlay.save_loaded.connect(_on_save_loaded)

	_start_music()


func _input(event: InputEvent) -> void:
	if _saves_overlay != null and _saves_overlay.visible:
		return

	if (
		_saves_overlay != null
		and _saves_overlay.has_method("is_export_defaults_open")
		and bool(_saves_overlay.call("is_export_defaults_open"))
	):
		return

	if _release_text_focus_on_escape(event):
		get_viewport().set_input_as_handled()
		return

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
		return

	if event.is_action_pressed("ui_cancel"):
		if _view != "main":
			_show_view("main")
			get_viewport().set_input_as_handled()


# ============================================================
# VIEWS
# ============================================================

func _show_view(view: String, refresh: bool = true, animate: bool = true) -> void:
	var previous_view := _view
	_view = view

	_main_panel.visible = view == "main"
	_extras_panel.visible = view == "extras"
	_settings_panel.visible = view == "settings"
	_graphics_panel.visible = view == "graphics"
	_sky_clouds_panel.visible = view == "sky_clouds"
	_gameplay_panel.visible = view == "gameplay"
	_audio_panel.visible = view == "audio"

	if _title_root != null:
		_title_root.visible = view == "main"
	_main_title.visible = false
	_subtitle.visible = view == "main"
	_tagline.visible = view == "main"
	_section_title.visible = view != "main"
	_hint.text = (
		"MOVE MOUSE TO SELECT  |  CLICK TO CONFIRM"
		if view == "main"
		else "ESC OR BACK TO RETURN"
	)

	match view:
		"extras":
			_section_title.text = "EXTRAS"
		"settings":
			_section_title.text = "SETTINGS"
		"graphics":
			_section_title.text = "GRAPHICS"
		"sky_clouds":
			_section_title.text = "SKY & CLOUDS"
		"gameplay":
			_section_title.text = "GAMEPLAY"
		"audio":
			_section_title.text = "AUDIO"

	_set_panel_buttons_active(_main_panel, view == "main")
	_set_panel_buttons_active(_extras_panel, view == "extras")
	_set_panel_buttons_active(_settings_panel, view == "settings")
	_set_panel_buttons_active(_graphics_panel, view == "graphics")
	_set_panel_buttons_active(_sky_clouds_panel, view == "sky_clouds")
	_set_panel_buttons_active(_gameplay_panel, view == "gameplay")
	_set_panel_buttons_active(_audio_panel, view == "audio")
	_set_hover(null)

	if refresh:
		_refresh_labels()

	if animate:
		_animate_view(view)
		if previous_view != view:
			_play_ui(UI_SOUND_TRANSITION, -10.0)


func _release_text_focus_on_escape(event: InputEvent) -> bool:
	if not event.is_action_pressed("ui_cancel"):
		return false

	var focus := get_viewport().gui_get_focus_owner()

	if focus == null or not is_instance_valid(focus):
		return false

	if not (focus is LineEdit or focus is TextEdit):
		return false

	var node: Node = focus
	var root := get_tree().root

	while node != null and node != root:
		if node is Window:
			return false
		node = node.get_parent()

	focus.release_focus()
	return true


func _animate_view(view: String) -> void:
	if view == "main":
		_play_title_intro()
		_play_buttons_intro(_main_panel)
		return

	_play_section_intro()

	match view:
		"extras":
			_play_buttons_intro(_extras_panel)
		"settings":
			_play_buttons_intro(_settings_panel)
		"graphics":
			_play_buttons_intro(_graphics_panel)
		"sky_clouds":
			_play_buttons_intro(_sky_clouds_panel)
		"gameplay":
			_play_buttons_intro(_gameplay_panel)
		"audio":
			_play_buttons_intro(_audio_panel)


func _play_open_intro() -> void:
	_reset_sway()

	if _dim_material != null:
		_dim_material.albedo_color.a = 0.0
		var dim_tween := create_tween()
		dim_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		dim_tween.tween_property(
			_dim_material,
			"albedo_color:a",
			_dim_alpha,
			0.24
		)

	_animate_view(_view)


func _fit_to_camera() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return

	var reference := tan(deg_to_rad(75.0 * 0.5))
	var current := tan(deg_to_rad(clampf(_camera.fov, 5.0, 120.0) * 0.5))
	_panel.scale = Vector3.ONE * (current / reference)


func _fit_title() -> void:
	var font: Font = _main_title.font
	if font == null:
		font = PIXEL_FONT
		_main_title.font = font

	var width: float = font.get_string_size(
		_main_title.text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		_main_title.font_size
	).x

	if width > 0.0:
		_main_title.pixel_size = minf(_main_title.pixel_size, 1.26 / width)


func _build_title_letters() -> void:
	var font: Font = _main_title.font
	if font == null:
		font = PIXEL_FONT

	var text: String = _main_title.text
	var font_size: int = maxi(_main_title.font_size, 1)
	var pixel: float = _main_title.pixel_size

	var advances: Array[float] = []
	var total: float = 0.0

	for index in text.length():
		var advance: float = font.get_char_size(
			text.unicode_at(index),
			font_size
		).x * pixel
		advances.append(advance)
		total += advance

	_title_root = Node3D.new()
	_title_root.name = "TitleLetters"
	_title_root.position = _main_title.position
	_title_root.rotation = _main_title.rotation
	_title_root.scale = _main_title.scale
	_title_rest_position = _title_root.position
	_title_rest_rotation = _title_root.rotation
	_panel.add_child(_title_root)

	var cursor: float = -total * 0.5

	for index in text.length():
		var character: String = text[index]
		var advance: float = advances[index]

		if character.strip_edges().is_empty():
			cursor += advance
			continue

		var letter := Label3D.new()
		letter.text = character
		letter.font = font
		letter.font_size = font_size
		letter.pixel_size = pixel
		letter.outline_size = _main_title.outline_size
		letter.outline_modulate = _main_title.outline_modulate
		letter.modulate = _main_title.modulate
		letter.no_depth_test = true
		letter.render_priority = _main_title.render_priority
		letter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		letter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		letter.position = Vector3(cursor + advance * 0.5, 0.0, 0.0)
		_title_root.add_child(letter)
		_title_letters.append({"node": letter, "rest": letter.position})
		cursor += advance


func _play_title_intro() -> void:
	if _title_letters.is_empty():
		return

	if is_instance_valid(_title_tween):
		_title_tween.kill()

	_title_tween = create_tween().set_parallel(true)

	for index in _title_letters.size():
		var entry: Dictionary = _title_letters[index]
		var letter: Label3D = entry["node"]
		var rest: Vector3 = entry["rest"]
		var delay: float = 0.052 * float(index)

		letter.position = rest + Vector3(2.2, -1.5, 0.0)
		letter.rotation.z = deg_to_rad(-24.0)
		letter.scale = Vector3.ONE * 1.14
		letter.modulate.a = 0.0

		_title_tween.tween_property(letter, "position", rest, 0.56) \
			.set_delay(delay) \
			.set_trans(Tween.TRANS_EXPO) \
			.set_ease(Tween.EASE_OUT)
		_title_tween.tween_property(letter, "rotation:z", 0.0, 0.52) \
			.set_delay(delay) \
			.set_trans(Tween.TRANS_CUBIC) \
			.set_ease(Tween.EASE_OUT)
		_title_tween.tween_property(letter, "scale", Vector3.ONE, 0.48) \
			.set_delay(delay) \
			.set_trans(Tween.TRANS_BACK) \
			.set_ease(Tween.EASE_OUT)
		_title_tween.tween_property(letter, "modulate:a", 1.0, 0.26) \
			.set_delay(delay)


func _play_section_intro() -> void:
	if is_instance_valid(_section_tween):
		_section_tween.kill()

	_section_title.position = _section_rest_position + Vector3(0.24, 0.05, 0.0)
	_section_title.modulate.a = 0.0
	_section_tween = create_tween().set_parallel(true)
	_section_tween.tween_property(
		_section_title,
		"position",
		_section_rest_position,
		0.34
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_section_tween.tween_property(_section_title, "modulate:a", 1.0, 0.26)


func _play_buttons_intro(panel: Node) -> void:
	var buttons: Array = []
	_collect_buttons(panel, buttons)
	buttons.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.position.y > b.position.y
	)

	for index in buttons.size():
		var button: Node = buttons[index]
		if button.has_method("play_intro"):
			button.play_intro(0.042 * float(index))


# ============================================================
# INPUT
# ============================================================

func _button_at(screen_position: Vector2) -> Area3D:
	if _camera == null or not is_instance_valid(_camera):
		return null
	if not _camera.is_inside_tree():
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


## Untyped for the same reason as `_sway_to`: the ray can report a collider that
## a view rebuild freed a frame earlier.
func _set_hover(button: Variant, audible: bool = false) -> void:
	if not is_instance_valid(button):
		button = null

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


func _click_at(screen_position: Vector2) -> void:
	var button := _button_at(screen_position)
	if button == null:
		return

	var action := String(button.action)
	_play_ui(UI_SOUND_CLICK, -8.0)

	match action:
		"saves":
			_open_saves()
		"extras":
			_show_view("extras")
		"credits":
			_open_credits()
		"settings":
			_show_view("settings")
		"settings_graphics":
			_show_view("graphics")
		"sky_clouds":
			_show_view("sky_clouds")
		"back_graphics":
			_show_view("graphics")
		"settings_gameplay":
			_show_view("gameplay")
		"settings_audio":
			_show_view("audio")
		"back_main":
			_show_view("main")
		"back_settings":
			_show_view("settings")
		"quit":
			_quit_game()
		"quality":
			PerformanceSettings.cycle_quality()
			_refresh_labels()
		"render":
			PerformanceSettings.cycle_render_scale()
			_refresh_labels()
		"distance":
			PerformanceSettings.cycle_mesh_radius()
			_refresh_labels()
		"agents":
			PerformanceSettings.cycle_agent_cap()
			_refresh_labels()
		"stability":
			PerformanceSettings.toggle_stability()
			_refresh_labels()
		"destruction":
			PerformanceSettings.toggle_destruction()
			_refresh_labels()
		"physics_level":
			PerformanceSettings.cycle_collapse_style()
			_refresh_labels()
		"stability_debug":
			PerformanceSettings.toggle_stability_debug()
			_refresh_labels()
		"auto_dock":
			PerformanceSettings.toggle_auto_dock()
			_refresh_labels()
		"sublevel_stability":
			PerformanceSettings.toggle_sublevel_stability()
			_refresh_labels()
		"sublevel_damage":
			PerformanceSettings.toggle_sublevel_contact_damage()
			_refresh_labels()
		"sublevel_destruction":
			PerformanceSettings.toggle_sublevel_collision_destruction()
			_refresh_labels()
		"sublevel_fire":
			PerformanceSettings.toggle_sublevel_fire()
			_refresh_labels()
		"shadows":
			PerformanceSettings.toggle_shadows()
			_refresh_labels()
		"shadow_distance":
			PerformanceSettings.cycle_shadow_distance()
			_refresh_labels()
		"foliage_distance":
			PerformanceSettings.cycle_foliage_scale()
			_refresh_labels()
		"water":
			PerformanceSettings.toggle_water()
			_refresh_labels()
		"ao":
			PerformanceSettings.toggle_occlusion()
			_refresh_labels()
		"clouds":
			PerformanceSettings.toggle_clouds()
			_refresh_labels()
		"sky_time":
			PerformanceSettings.cycle_sky_time()
			_refresh_labels()
		"sky_sun":
			PerformanceSettings.toggle_sun_disc()
			_refresh_labels()
		"sky_moon":
			PerformanceSettings.toggle_moon_disc()
			_refresh_labels()
		"sky_rainbow":
			PerformanceSettings.toggle_rainbows()
			_refresh_labels()
		"sky_storm":
			PerformanceSettings.toggle_storm_flashes()
			_refresh_labels()
		"sky_storm_power":
			PerformanceSettings.cycle_storm_strength()
			_refresh_labels()
		"sky_fog":
			PerformanceSettings.toggle_fog()
			_refresh_labels()
		"sky_fog_offset":
			PerformanceSettings.cycle_fog_offset()
			_refresh_labels()
		"sky_speed":
			PerformanceSettings.cycle_sky_speed()
			_refresh_labels()
		"cloud_speed":
			PerformanceSettings.cycle_cloud_speed()
			_refresh_labels()
		"cloud_coverage":
			PerformanceSettings.cycle_cloud_coverage()
			_refresh_labels()
		"sky_clouds_reset":
			PerformanceSettings.reset_sky_clouds()
			_refresh_labels()
		"fps":
			PerformanceSettings.cycle_fps()
			_refresh_labels()
		"volume":
			PerformanceSettings.cycle_volume()
			_refresh_labels()
		"music":
			PerformanceSettings.cycle_music_volume()
			_refresh_labels()
		"view_roll":
			PerformanceSettings.cycle_view_roll()
			_refresh_labels()
		"export_defaults":
			_open_export_defaults()
		"reset":
			PerformanceSettings.apply_preset(1)
			_refresh_labels()


func _open_export_defaults() -> void:
	if (
		_saves_overlay != null
		and is_instance_valid(_saves_overlay)
		and _saves_overlay.has_method("_open_export_defaults")
	):
		_play_ui(UI_SOUND_TRANSITION, -10.0)
		_saves_overlay.call("_open_export_defaults")
		return

	_hint.text = "SIMULATION DEFAULTS UNAVAILABLE"


func _open_saves() -> void:
	if _saves_overlay == null or not _saves_overlay.has_method("open_saves_only"):
		_hint.text = "SAVE SYSTEM UNAVAILABLE"
		return

	_play_ui(UI_SOUND_ACCEPT, -8.0)
	_panel.visible = false
	_set_panel_buttons_active(_main_panel, false)
	_set_panel_buttons_active(_extras_panel, false)
	_set_panel_buttons_active(_settings_panel, false)
	_set_panel_buttons_active(_graphics_panel, false)
	_set_panel_buttons_active(_sky_clouds_panel, false)
	_set_panel_buttons_active(_gameplay_panel, false)
	_set_panel_buttons_active(_audio_panel, false)
	_set_hover(null)
	_saves_overlay.open_saves_only()


func _on_saves_closed() -> void:
	_panel.visible = true
	_show_view(_view, false, false)
	_play_ui(UI_SOUND_TRANSITION, -10.0)


## Loading a save or starting a new map leaves the menu for the game, so the
## menu playlist must not keep playing underneath it.
func _on_save_loaded() -> void:
	var music := get_node_or_null("/root/MusicManager")

	if music != null and music.has_method("stop"):
		music.stop()


func _open_credits() -> void:
	_play_ui(UI_SOUND_TRANSITION, -9.0)
	var error := get_tree().change_scene_to_file(CREDITS_SCENE)

	if error != OK:
		_hint.text = "COULD NOT LOAD CREDITS"


func _quit_game() -> void:
	get_tree().quit()


# ============================================================
# LABELS / SWAY
# ============================================================

func _refresh_labels() -> void:
	for button in _all_buttons():
		var action := String(button.action)
		var dynamic := _dynamic_caption(action)
		if not dynamic.is_empty():
			button.set_caption(dynamic)


func _dynamic_caption(action: String) -> String:
	match action:
		"quality":
			return "Quality: " + PerformanceSettings.quality_name()
		"render":
			return "Render: " + PerformanceSettings.render_scale_name()
		"distance":
			return "Distance: %d chunks" % PerformanceSettings.mesh_radius
		"agents":
			return "Agents: " + PerformanceSettings.agent_cap_name()
		"stability":
			return "Stability: " + PerformanceSettings.stability_name()
		"destruction":
			return "Destruction: " + PerformanceSettings.destruction_name()
		"physics_level":
			return "Collapse: " + PerformanceSettings.collapse_style_name()
		"stability_debug":
			return "Stability Overlay: " + PerformanceSettings.stability_debug_name()
		"auto_dock":
			return "Auto Dock: " + PerformanceSettings.auto_dock_name()
		"sublevel_stability":
			return (
				"Sublevel Stability: "
				+ PerformanceSettings.sublevel_stability_name()
			)
		"sublevel_damage":
			return (
				"Sublevel Entity Damage: "
				+ PerformanceSettings.sublevel_contact_damage_name()
			)
		"sublevel_destruction":
			return (
				"Sublevel Block Damage: "
				+ PerformanceSettings.sublevel_collision_destruction_name()
			)
		"sublevel_fire":
			return "Sublevel Fire: " + PerformanceSettings.sublevel_fire_name()
		"shadows":
			return "Shadows: " + PerformanceSettings.shadows_name()
		"shadow_distance":
			return "Shadow Dist: " + PerformanceSettings.shadow_distance_name()
		"foliage_distance":
			return "Foliage: " + PerformanceSettings.foliage_scale_name()
		"water":
			return "Water FX: " + PerformanceSettings.water_name()
		"ao":
			return "AO: " + PerformanceSettings.occlusion_name()
		"clouds":
			return "Clouds: " + PerformanceSettings.clouds_name()
		"sky_time":
			return "Time: " + PerformanceSettings.sky_time_name()
		"sky_sun":
			return "Sun: " + PerformanceSettings.sun_disc_name()
		"sky_moon":
			return "Moon: " + PerformanceSettings.moon_disc_name()
		"sky_rainbow":
			return "Rainbow: " + PerformanceSettings.rainbows_name()
		"sky_storm":
			return "Storms: " + PerformanceSettings.storm_flashes_name()
		"sky_storm_power":
			return "Storm Power: " + PerformanceSettings.storm_strength_name()
		"sky_fog":
			return "Fog: " + PerformanceSettings.fog_name()
		"sky_fog_offset":
			return "Fog Offset: " + PerformanceSettings.fog_offset_name()
		"sky_speed":
			return "Cycle Speed: " + PerformanceSettings.sky_speed_name()
		"cloud_speed":
			return "Cloud Speed: " + PerformanceSettings.cloud_speed_name()
		"cloud_coverage":
			return "Coverage: " + PerformanceSettings.cloud_coverage_name()
		"volume":
			return "Volume: " + PerformanceSettings.volume_name()
		"music":
			return "Music: " + PerformanceSettings.music_volume_name()
		"fps":
			return "FPS Cap: " + PerformanceSettings.fps_name()
		"view_roll":
			return "View Roll: " + PerformanceSettings.view_roll_name()
	return ""


func _set_cursor_sway(screen_position: Vector2) -> void:
	var viewport_size := get_viewport().get_visible_rect().size

	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	_cursor_nx = clampf((screen_position.x / viewport_size.x) * 2.0 - 1.0, -1.0, 1.0)
	_cursor_ny = clampf((screen_position.y / viewport_size.y) * 2.0 - 1.0, -1.0, 1.0)


## `button` is intentionally untyped: the hovered entry can be freed by a saves
## refresh or view rebuild, and a typed Area3D parameter would throw a
## "previously freed" type error before the validity check could run.
func _sway_to(button: Variant) -> void:
	if not is_instance_valid(button):
		button = null

		if _hovered != null and not is_instance_valid(_hovered):
			_hovered = null

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

	if is_instance_valid(button) and button is Node3D:
		var local: Vector3 = _panel.to_local(button.global_position)
		var nx: float = clampf(local.x / 1.1, -1.0, 1.0)
		var ny: float = clampf(local.y / 0.9, -1.0, 1.0)
		target_position += Vector3(-nx * 0.02, -ny * 0.016, 0.0)
		target_rotation += Vector3(
			deg_to_rad(ny * 0.45),
			deg_to_rad(nx * 0.55),
			0.0
		)
		target_h += -nx * 0.045
		target_v += -ny * 0.035

	_sway_tween = create_tween().set_parallel(true)
	_sway_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_sway_tween.tween_property(_panel, "position", target_position, 0.4)
	_sway_tween.tween_property(_panel, "rotation", target_rotation, 0.4)
	_sway_tween.tween_property(_camera, "h_offset", target_h, 0.4)
	_sway_tween.tween_property(_camera, "v_offset", target_v, 0.4)

	if _title_root != null:
		# Pinned to the panel like the buttons, plus a gentle cursor tilt.
		_sway_tween.tween_property(
			_title_root,
			"position",
			_title_rest_position,
			0.4
		)
		_sway_tween.tween_property(
			_title_root,
			"rotation",
			_title_rest_rotation + Vector3(
				deg_to_rad(-_cursor_ny * 1.4),
				deg_to_rad(-_cursor_nx * 2.2),
				0.0
			),
			0.4
		)


func _reset_sway() -> void:
	if is_instance_valid(_sway_tween):
		_sway_tween.kill()

	_panel.position = _panel_rest_position
	_panel.rotation = _panel_rest_rotation
	_camera.h_offset = _camera_h_rest
	_camera.v_offset = _camera_v_rest

	if _title_root != null:
		_title_root.position = _title_rest_position
		_title_root.rotation = _title_rest_rotation


func _all_buttons() -> Array:
	var result: Array = []
	_collect_buttons(self, result)
	return result


func _collect_buttons(node: Node, result: Array) -> void:
	for child in node.get_children():
		if child is Area3D and child.has_method("set_hovered"):
			result.append(child)
		_collect_buttons(child, result)


func _set_panel_buttons_active(panel: Node, active: bool) -> void:
	var buttons: Array = []
	_collect_buttons(panel, buttons)

	for button in buttons:
		button.collision_layer = MENU_LAYER if active else 0


# ============================================================
# AUDIO
# ============================================================

func _setup_ui_audio() -> void:
	for index in 8:
		var player := AudioStreamPlayer.new()
		player.name = "UISound%d" % index
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		player.bus = &"Master"
		add_child(player)
		_ui_players.append(player)


func _play_ui(
	stream: AudioStream,
	volume_db: float = -8.0,
	pitch: float = 1.0
) -> void:
	if stream == null or _ui_players.is_empty():
		return

	var player: AudioStreamPlayer = _ui_players[_ui_play_index]
	_ui_play_index = (_ui_play_index + 1) % _ui_players.size()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = clampf(pitch * randf_range(0.96, 1.04), 0.05, 4.0)
	player.play()


func _start_music() -> void:
	var music := get_node_or_null("/root/MusicManager")

	if music != null and music.has_method("play_menu_playlist"):
		music.play_menu_playlist()
