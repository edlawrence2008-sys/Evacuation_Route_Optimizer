extends Node3D

## Reference-style 3D menu: a large title, a vertical entry list, and subviews
## for Settings, Statistics (heat/route/topography maps) and Maps & Saves.
##
## The layout lives in pause_menu.tscn so it can be arranged in the editor.

const MENU_LAYER: int = 1 << 9
const UI_FONT: Font = preload("res://font/dogicapixel.ttf")
const MENU_FONT: Font = preload("res://font/Pixelta.ttf")
const MAP_RENDERER := preload("res://scripts/map_renderer.gd")
const WORLD_GENERATORS := preload("res://scripts/world/WorldGeneratorRegistry.gd")

const UI_SOUND_HOVER := preload("res://sounds/ui/menu_hover.wav")
const UI_SOUND_CLICK := preload("res://sounds/ui/menu_click.wav")
const UI_SOUND_TRANSITION := preload("res://sounds/ui/menu_transition.wav")
const UI_SOUND_ACCEPT := preload("res://sounds/ui/accept.wav")
const UI_SOUND_DONE := preload("res://sounds/ui/done.wav")
const UI_SOUND_SAVE := preload("res://sounds/ui/save_finish.wav")
const UI_SOUND_NOTIF := preload("res://sounds/ui/notif_subtle.wav")
const UI_SOUND_NOTIF_SHARP := preload("res://sounds/ui/notif_sharp.wav")
const UI_SOUND_TYPE_0 := preload("res://sounds/ui/type_0.wav")
const UI_SOUND_TYPE_1 := preload("res://sounds/ui/type_1.wav")
const UI_SOUND_TYPING_FINISH := preload("res://sounds/ui/typing_input_finish.wav")
const TRANSITION_ACTIONS := [
	"settings", "stats", "saves", "water_tuning", "back_main", "back_settings",
	"settings_graphics", "settings_gameplay", "settings_audio", "settings_controls",
	"sky_clouds", "back_graphics", "export_defaults",
]

## Actions shown in the dedicated Controls page. Internal ui_* actions that are
## engine navigation (ui_accept, ui_cancel, ...) are intentionally excluded.
const BINDABLE_ACTIONS: Array[StringName] = [
	&"left", &"right", &"up", &"down", &"jump", &"sprint", &"crouch",
	&"interact", &"primary_use", &"secondary_use", &"place_block",
	&"break_block", &"pick_block", &"toggle_build_mode",
	&"toggle_inventory", &"switch_axis", &"ui_rotate", &"zoom",
	&"ui_noclip", &"ui_statistics_toggle", &"ui_results_toggle",
	&"ui_console_toggle",
]

@export var save_row_step: float = 0.15
@export var save_rows_per_page: int = 6
## When true this instance is a saves-only overlay for the main menu: Save and
## Save As are hidden, Back closes the overlay instead of showing the pause
## menu's main page, and the tree is never paused.
@export var saves_only: bool = false

signal saves_closed
## Emitted when a save (or a new blank map) is about to be loaded, so menu-only
## music can stop before the game scene takes over.
signal save_loaded

var _camera: Camera3D = null
var _player: Node3D = null
var _hud: CanvasLayer = null
var _hands: Node3D = null
var _dialog_layer: CanvasLayer = null
var _save_manager: Node = null
var _defaults_layer: CanvasLayer = null
var _defaults_agent_panel: Node = null
var _defaults_cap: SpinBox = null
var _defaults_quota: SpinBox = null
var _defaults_seed: SpinBox = null
var _defaults_evac: CheckBox = null
var _defaults_record: CheckBox = null

@onready var _panel: Node3D = $Panel
@onready var _dim: MeshInstance3D = $Dim
@onready var _main_title: Label3D = $Panel/MainTitle
@onready var _section_title: Label3D = $Panel/SectionTitle
@onready var _main_panel: Node3D = $Panel/MainPanel
@onready var _settings_panel: Node3D = $Panel/SettingsPanel
@onready var _water_panel: Node3D = $Panel/WaterPanel
@onready var _graphics_panel: Node3D = $Panel/GraphicsPanel
@onready var _sky_clouds_panel: Node3D = $Panel/SkyCloudsPanel
@onready var _gameplay_panel: Node3D = $Panel/GameplayPanel
@onready var _audio_panel: Node3D = $Panel/AudioPanel
@onready var _controls_panel: Node3D = $Panel/ControlsPanel
var _keybinds_panel: Node3D = null
var _keybind_buttons: Array[Node] = []
var _keybind_page_label: Label3D = null
var _keybind_page: int = 0
var _binding_button_3d: Node = null
const KEYBINDS_PER_PAGE := 8
var _keybind_layer: CanvasLayer = null
var _keybind_list: VBoxContainer = null
var _binding_action: StringName = &""
var _binding_button: Button = null
@onready var _stats_panel: Node3D = $Panel/StatisticsPanel
@onready var _saves_panel: Node3D = $Panel/SavesPanel
@onready var _save_list: Node3D = $Panel/SavesPanel/SaveList
@onready var _page_label: Label3D = $Panel/SavesPanel/PageLabel
@onready var _status_label: Label3D = $Panel/SavesPanel/StatusLabel

# Demos tab (built at runtime in _ensure_demos_ui).
var _demos_panel: Node3D = null
var _demo_list: Node3D = null
var _demo_page_label: Label3D = null
var _demo_details: Label3D = null
var _demo_status_label: Label3D = null
var _demo_folder_button: Node = null
var _demo_compare_button: Node = null
var _demos: Array = []
var _demo_start: int = 0
var _selected_demo_id: String = ""
var _demo_folder_filter: String = ""
var _demo_compare_mode: bool = false
var _demo_compare_ids: Array[String] = []
@onready var _stats_map: MeshInstance3D = $Panel/StatisticsPanel/StatsMap
@onready var _stats_text: Label3D = $Panel/StatisticsPanel/StatsText
@onready var _thumbnail: MeshInstance3D = $Panel/SavesPanel/Thumbnail
@onready var _save_details: Label3D = $Panel/SavesPanel/SaveDetails

var _button_scene: PackedScene = preload("res://scenes/menu/pause_button_3d.tscn")
var _view: String = "main"
## Last non-main page, restored when the menu is paused again.
var _last_view: String = "main"
var _stats_mode: String = "topo"
var _saves: Array = []
var _save_start: int = 0
var _selected_slug: String = ""
var _hovered: Area3D = null
var _paused: bool = false
var _dialog_open: bool = false
var _saved_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_CAPTURED
var _saved_hands_visible: bool = true
var _saved_hud_visible: bool = true

# Animation state
var _dim_material: StandardMaterial3D = null
var _dim_alpha: float = 0.985
var _panel_rest_position: Vector3 = Vector3.ZERO
var _panel_rest_rotation: Vector3 = Vector3.ZERO
var _section_rest_position: Vector3 = Vector3.ZERO
var _stats_rest_scale: Vector3 = Vector3.ONE
var _thumbnail_rest_scale: Vector3 = Vector3.ONE
var _camera_h_rest: float = 0.0
var _camera_v_rest: float = 0.0
var _title_root: Node3D = null
var _title_rest_position: Vector3 = Vector3.ZERO
var _title_rest_rotation: Vector3 = Vector3.ZERO
var _cursor_nx: float = 0.0
var _cursor_ny: float = 0.0
var _title_letters: Array = []
var _title_tween: Tween = null
var _section_tween: Tween = null
var _map_tween: Tween = null
var _preview_tween: Tween = null
var _sway_tween: Tween = null
var _status_tween: Tween = null
var _preview_slug: String = ""
var _ui_players: Array[AudioStreamPlayer] = []
var _ui_play_index: int = 0
var _ui_type_toggle: bool = false
var _new_map_world_type: String = "blank"
var _new_map_generator_id: String = "heightmap_v1"
var _new_map_world_size: String = "medium"
var _new_map_seed: int = 0
var _pending_new_map_name: String = "New Map"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_ui_audio()
	_camera = get_parent() as Camera3D
	_player = get_tree().get_first_node_in_group("Player") as Node3D
	if _player != null:
		_hud = _player.get_node_or_null("HUD") as CanvasLayer
	if _camera != null:
		_hands = _camera.get_node_or_null("hands") as Node3D
		_camera_h_rest = _camera.h_offset
		_camera_v_rest = _camera.v_offset

	_panel_rest_position = _panel.position
	_panel_rest_rotation = _panel.rotation
	_section_rest_position = _section_title.position
	_stats_rest_scale = _stats_map.scale
	_thumbnail_rest_scale = _thumbnail.scale
	_dim_material = _dim.material_override as StandardMaterial3D
	if _dim_material != null:
		_dim_alpha = _dim_material.albedo_color.a
	_build_title_letters()
	_ensure_saves_ui()
	_ensure_demos_ui()
	_bind_keybind_ui()
	_load_input_bindings()

	_save_manager = get_node_or_null("/root/SaveManager")
	if _save_manager != null:
		_save_manager.saves_changed.connect(_on_saves_changed)

	if not saves_only:
		get_tree().auto_accept_quit = false
		if not get_tree().root.close_requested.is_connected(_on_close_requested):
			get_tree().root.close_requested.connect(_on_close_requested)

	visible = false
	_stats_map.visible = false
	_thumbnail.visible = false
	_show_view("main", false, false)


	if saves_only:
		_deactivate_all_panels()


## Opens the pause menu's Saves page as a main-menu overlay. The tree is not
## paused; the overlay simply takes input until Back/Load closes it.
func open_saves_only() -> void:
	if not saves_only:
		return

	_paused = true
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_show_view("saves", true, false)
	_apply_saves_only_layout()
	_refresh_save_list()
	_set_hover(null)


func close_saves_only() -> void:
	if not saves_only:
		return

	_paused = false
	visible = false
	_reset_sway()
	_deactivate_all_panels()
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	saves_closed.emit()


func _deactivate_all_panels() -> void:
	for panel: Node3D in [
		_main_panel,
		_settings_panel,
		_water_panel,
		_graphics_panel,
		_gameplay_panel,
		_audio_panel,
		_controls_panel,
		_stats_panel,
		_saves_panel,
		_demos_panel,
	]:
		if panel != null:
			_set_panel_buttons_active(panel, false)


## Hide the actions that only make sense while a live world is loaded. Rename,
## Duplicate and Delete operate on save folders and remain available.
func _apply_saves_only_layout() -> void:
	if _saves_panel == null:
		return

	for path: String in [
		"LeftActions/Save",
		"LeftActions/SaveAs",
	]:
		var node := _saves_panel.get_node_or_null(path)

		if node != null:
			node.set("visible", false)
			if node is Area3D:
				(node as Area3D).collision_layer = 0

	# With Save/Save As hidden, lift Load into the first action row so the
	# left column does not end up with a lone button at the bottom.
	var load_button := _saves_panel.get_node_or_null(
		"LeftActions/Load"
	) as Node3D
	if load_button != null:
		load_button.position = Vector3(0.0, -0.48, 0.0)
		load_button.set("_rest_position", load_button.position)

	# World Type stays available: New Map needs it in both menus.


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
	var variation := _ui_pitch_variation(stream)
	var final_pitch := pitch
	if variation > 0.0:
		final_pitch *= 1.0 + randf_range(-variation, variation)
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = clampf(final_pitch, 0.05, 4.0)
	player.play()


func _ui_pitch_variation(stream: AudioStream) -> float:
	if stream == UI_SOUND_HOVER:
		return 0.05
	if stream == UI_SOUND_CLICK:
		return 0.06
	if stream == UI_SOUND_TYPE_0 or stream == UI_SOUND_TYPE_1:
		return 0.09
	if stream == UI_SOUND_TRANSITION:
		return 0.02
	if stream == UI_SOUND_TYPING_FINISH:
		return 0.04
	return 0.035


func _input(event: InputEvent) -> void:
	if not is_inside_tree():
		return

	# A focused text field gets Escape first. Without this the pause handler
	# below swallowed it and the field could only be left by clicking away.
	if _release_text_focus_on_escape(event):
		get_viewport().set_input_as_handled()
		return

	if saves_only:
		if event.is_action_pressed("ui_cancel"):
			close_saves_only()
			get_viewport().set_input_as_handled()
			return

	if _keybind_layer != null and _keybind_layer.visible:
		_handle_keybind_input(event)
		return

	if _defaults_layer != null and _defaults_layer.visible:
		if event.is_action_pressed("ui_cancel"):
			_defaults_layer.visible = false
			get_viewport().set_input_as_handled()
		return

	if _view == "controls":
		if not _binding_action.is_empty():
			_handle_keybind_capture(event)
			return
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_show_view("settings")
			get_viewport().set_input_as_handled()
			return

	if event.is_action_pressed("ui_cancel"):
		if _dialog_open:
			return
		if _paused and _view != "main":
			_show_view("main")
		else:
			set_paused(not _paused)
		get_viewport().set_input_as_handled()
		return

	if not _paused or _dialog_open:
		return

	if event is InputEventMouseMotion:
		_set_cursor_sway(event.position)
		_set_hover(_button_at(event.position), true)
		_sway_to(_hovered)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_click_at(event.position)
			if is_inside_tree():
				get_viewport().set_input_as_handled()
		elif _saves_panel.visible and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_save_start = maxi(0, _save_start - 1)
				_refresh_save_list()
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_save_start = mini(maxi(0, _saves.size() - 1), _save_start + 1)
				_refresh_save_list()
				get_viewport().set_input_as_handled()
		elif _demos_panel != null and _demos_panel.visible and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_demo_start = maxi(0, _demo_start - 1)
				_refresh_demo_list()
				get_viewport().set_input_as_handled()
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_demo_start = mini(
					maxi(0, _filtered_demo_count() - 1), _demo_start + 1
				)
				_refresh_demo_list()
				get_viewport().set_input_as_handled()


func set_paused(value: bool) -> void:
	if value == _paused:
		return
	if value and not is_inside_tree():
		return

	_paused = value
	visible = value

	if value:
		_saved_mouse_mode = Input.get_mouse_mode()
		_saved_hands_visible = _hands == null or _hands.visible
		_saved_hud_visible = _hud == null or _hud.visible

		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		if _hands != null:
			_hands.visible = false
		if _hud != null:
			_hud.visible = false

		_fit_to_camera()

		var restore_view: String = (
			_last_view if not _last_view.is_empty() else "main"
		)
		_show_view(restore_view, true, false)
		_refresh_labels()
		_set_status("")
		_play_open_intro()
		_play_ui(UI_SOUND_TRANSITION, -9.0)
		get_tree().paused = true
		var mouse_position := get_viewport().get_mouse_position()
		_set_cursor_sway(mouse_position)
		_set_hover(_button_at(mouse_position))
		_sway_to(_hovered)
	else:
		if _demo_compare_mode:
			_cancel_demo_compare(false)
		_play_ui(UI_SOUND_TRANSITION, -11.0)
		_reset_sway()
		if _defaults_layer != null and is_instance_valid(_defaults_layer):
			_defaults_layer.visible = false
		get_tree().paused = false
		Input.set_mouse_mode(_saved_mouse_mode)
		if _hands != null:
			_hands.visible = _saved_hands_visible
		if _hud != null:
			_hud.visible = _saved_hud_visible
		_set_hover(null)


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


func is_paused() -> bool:
	return _paused


func is_export_defaults_open() -> bool:
	return (
		_defaults_layer != null
		and is_instance_valid(_defaults_layer)
		and _defaults_layer.visible
	)


func _fit_to_camera() -> void:
	if _camera == null or not is_instance_valid(_camera) or not _camera.is_inside_tree():
		return
	var reference := tan(deg_to_rad(75.0 * 0.5))
	var current := tan(deg_to_rad(clampf(_camera.fov, 5.0, 120.0) * 0.5))
	_panel.scale = Vector3.ONE * (current / reference)


func _show_view(view: String, refresh: bool = true, animate: bool = true) -> void:
	if view != "demos" and _demo_compare_mode:
		_cancel_demo_compare(false)

	var previous_view := _view
	_view = view

	if view != "main":
		_last_view = view
	_main_panel.visible = view == "main"
	_settings_panel.visible = view == "settings"
	_water_panel.visible = view == "water"
	_graphics_panel.visible = view == "graphics"
	_sky_clouds_panel.visible = view == "sky_clouds"
	_gameplay_panel.visible = view == "gameplay"
	_audio_panel.visible = view == "audio"
	_controls_panel.visible = view == "controls"
	_stats_panel.visible = view == "statistics"
	_saves_panel.visible = view == "saves"
	_demos_panel.visible = view == "demos"
	if _title_root != null:
		_title_root.visible = view == "main"
	_main_title.visible = false
	_section_title.visible = view != "main"

	match view:
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
		"controls":
			_section_title.text = "CONTROLS"
		"water":
			_section_title.text = "WATER"
		"statistics":
			_section_title.text = "STATISTICS"
		"saves":
			_section_title.text = "SAVES"
		"demos":
			_section_title.text = "DEMOS"

	_set_panel_buttons_active(_main_panel, view == "main")
	_set_panel_buttons_active(_settings_panel, view == "settings")
	_set_panel_buttons_active(_water_panel, view == "water")
	_set_panel_buttons_active(_graphics_panel, view == "graphics")
	_set_panel_buttons_active(_sky_clouds_panel, view == "sky_clouds")
	_set_panel_buttons_active(_gameplay_panel, view == "gameplay")
	_set_panel_buttons_active(_audio_panel, view == "audio")
	_set_panel_buttons_active(_controls_panel, view == "controls")
	_set_panel_buttons_active(_stats_panel, view == "statistics")
	_set_panel_buttons_active(_saves_panel, view == "saves")
	_set_panel_buttons_active(_demos_panel, view == "demos")
	_set_hover(null)

	if refresh:
		if view == "settings":
			_refresh_labels()
		elif (
			view == "graphics"
			or view == "sky_clouds"
			or view == "gameplay"
			or view == "audio"
		):
			_refresh_labels()
		elif view == "controls":
			_refresh_labels()
			_refresh_keybind_page()
		elif view == "water":
			_refresh_labels()
		elif view == "statistics":
			_refresh_statistics(false)
		elif view == "saves":
			_refresh_labels()
			_refresh_save_list()
		elif view == "demos":
			_refresh_labels()
			_refresh_demo_list()

	if animate:
		_animate_view(view)
		if _paused and view != previous_view:
			_play_ui(UI_SOUND_TRANSITION, -10.0)


## Builds one Label3D per title character so the letters can fly in
## independently. The authored MainTitle label stays in the scene as the
## editable template and is hidden at runtime.
func _build_title_letters() -> void:
	var font: Font = _main_title.font
	if font == null:
		font = MENU_FONT
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


## The Water tab is authored in pause_menu.tscn, but the Godot editor can
## resave an older copy of the scene over it. Rebuild any missing Water nodes
## at runtime so the menu never references a null panel.
func _ensure_water_ui() -> void:
	var panel := get_node_or_null("Panel") as Node3D
	if panel == null:
		return

	var water := panel.get_node_or_null("WaterPanel") as Node3D
	if water == null:
		water = Node3D.new()
		water.name = "WaterPanel"
		water.visible = false
		panel.add_child(water)
	_water_panel = water

	var left := _ensure_water_column(water, "LeftColumn", Vector3(-0.68, 0, 0.035))
	var right := _ensure_water_column(water, "RightColumn", Vector3(0.68, 0, 0.035))

	_ensure_water_button(left, "FlowStep", "water_flow", "Flow Step", 0.47)
	_ensure_water_button(left, "Equalize", "water_equalize", "Equalize", 0.265)
	_ensure_water_button(left, "UpdateBudget", "water_budget", "Update Budget", 0.06)
	_ensure_water_button(left, "MeshRate", "water_mesh", "Mesh Rate", -0.145)
	_ensure_water_button(left, "WaveDetail", "water_wave_detail", "Wave Detail", -0.35)
	_ensure_water_button(left, "WaveCap", "water_wave_cap", "Wave Samples", -0.555)

	_ensure_water_button(right, "Waves", "water_waves", "Waves", 0.47)
	_ensure_water_button(right, "Splashes", "water_splashes", "Splashes", 0.265)
	_ensure_water_button(right, "SurfaceDrops", "water_surface_drops", "Surface Drops", 0.06)
	_ensure_water_button(right, "WakeStyle", "water_wake", "Wake Style", -0.145)
	_ensure_water_button(right, "ResetWater", "water_reset", "Reset Water", -0.35)
	_ensure_water_button(
		water,
		"WaterBack",
		"back_settings",
		"Back",
		-0.79,
		Vector3(1.9, 1.2, 1.0)
	)

	var settings_right := get_node_or_null(
		"Panel/SettingsPanel/RightColumn"
	) as Node3D
	if settings_right != null:
		_ensure_water_button(
			settings_right,
			"WaterTuning",
			"water_tuning",
			"Water Tuning",
			-0.555
		)


## Reorganizes the authored Settings panel into dedicated pages. Existing
## buttons are reparented (with their action bindings intact) so the editor
## scene remains the single source for their look and captions.
func _ensure_settings_ui() -> void:
	if _graphics_panel != null:
		return

	_graphics_panel = _ensure_category_panel("GraphicsPanel")
	_gameplay_panel = _ensure_category_panel("GameplayPanel")
	_audio_panel = _ensure_category_panel("AudioPanel")
	_controls_panel = _ensure_category_panel("ControlsPanel")

	var graphics_left := _ensure_water_column(
		_graphics_panel, "LeftColumn", Vector3(-0.68, 0, 0.035)
	)
	var graphics_right := _ensure_water_column(
		_graphics_panel, "RightColumn", Vector3(0.68, 0, 0.035)
	)
	var gameplay_left := _ensure_water_column(
		_gameplay_panel, "LeftColumn", Vector3(-0.68, 0, 0.035)
	)
	var gameplay_right := _ensure_water_column(
		_gameplay_panel, "RightColumn", Vector3(0.68, 0, 0.035)
	)
	var audio_left := _ensure_water_column(
		_audio_panel, "LeftColumn", Vector3(-0.68, 0, 0.035)
	)
	var controls_left := _ensure_water_column(
		_controls_panel, "LeftColumn", Vector3(-0.68, 0, 0.035)
	)

	_move_settings_button("Quality", graphics_left, 0.45)
	_move_settings_button("RenderScale", graphics_left, 0.18)
	_move_settings_button("DrawDistance", graphics_left, -0.09)
	_move_settings_button("Shadows", graphics_left, -0.36)
	_move_settings_button("Clouds", graphics_right, 0.45)
	_move_settings_button("Occlusion", graphics_right, 0.18)
	_move_settings_button("Fps", graphics_right, -0.09)
	_move_settings_button("Reset", graphics_right, -0.36)

	_move_settings_button("AgentLimit", gameplay_left, 0.45)
	_ensure_water_button(
		gameplay_left, "ViewRoll", "view_roll", "View Roll", 0.22
	)
	_ensure_water_button(
		gameplay_left, "Stability", "stability", "Stability", -0.01
	)
	_ensure_water_button(
		gameplay_left, "Destruction", "destruction", "Destruction", -0.24
	)
	_ensure_water_button(
		gameplay_right,
		"ExportDefaults",
		"export_defaults",
		"Simulation Defaults",
		0.45
	)
	_ensure_water_button(
		gameplay_right, "PhysicsLevel", "physics_level", "Collapse Style", 0.22
	)
	_ensure_water_button(
		gameplay_right,
		"StabilityOverlay",
		"stability_debug",
		"Stability Overlay",
		-0.01
	)
	_ensure_water_button(
		gameplay_right, "AutoDock", "auto_dock", "Auto Dock", -0.24
	)

	_move_settings_button("Volume", audio_left, 0.10)
	_ensure_water_button(audio_left, "Music", "music", "Music", 0.40)
	_ensure_water_button(
		controls_left, "Keybinds", "keybinds", "Keybinds", 0.15
	)

	var water_right := _water_panel.get_node_or_null("RightColumn") as Node3D
	if water_right != null:
		_move_settings_button("Water", water_right, -0.555)
		if water_right.get_node_or_null("Water") == null:
			_ensure_water_button(
				water_right, "Water", "water", "Water FX", -0.555
			)

	var hub_left := _ensure_water_column(
		_settings_panel, "HubLeft", Vector3(-0.68, 0, 0.035)
	)
	var hub_right := _ensure_water_column(
		_settings_panel, "HubRight", Vector3(0.68, 0, 0.035)
	)
	_ensure_water_button(hub_left, "Graphics", "settings_graphics", "Graphics", 0.35)
	_ensure_water_button(hub_left, "Gameplay", "settings_gameplay", "Gameplay", 0.05)
	_ensure_water_button(hub_left, "Controls", "settings_controls", "Controls", -0.25)
	_ensure_water_button(hub_right, "Audio", "settings_audio", "Audio", 0.35)
	_move_settings_button("WaterTuning", hub_right, 0.05)
	var settings_back := _settings_panel.get_node_or_null("SettingsBack") as Node3D
	if settings_back != null:
		settings_back.position = Vector3(0.0, -0.55, 0.035)
		settings_back.set("_rest_position", settings_back.position)

	for entry in [
		[_graphics_panel, "GraphicsBack", -0.62],
		[_gameplay_panel, "GameplayBack", -0.62],
		[_audio_panel, "AudioBack", -0.15],
		[_controls_panel, "ControlsBack", -0.15],
	]:
		var panel: Node3D = entry[0]
		_ensure_water_button(
			panel,
			String(entry[1]),
			"back_settings",
			"Back",
			float(entry[2])
		)


func _bind_keybind_ui() -> void:
	_keybind_buttons.clear()
	if _controls_panel == null:
		return
	for slot in KEYBINDS_PER_PAGE:
		var button := _controls_panel.find_child("Bind%d" % slot, true, false)
		if button != null:
			_keybind_buttons.append(button)
	_keybind_page_label = _controls_panel.get_node_or_null("PageLabel") as Label3D
	_refresh_keybind_page()


func _open_keybinds() -> void:
	_ensure_keybind_layer()
	if _keybind_layer == null:
		return
	_keybind_layer.visible = true
	_refresh_keybind_rows()
	_play_ui(UI_SOUND_TRANSITION, -10.0)


func _close_keybinds() -> void:
	_cancel_rebind()
	if _keybind_layer != null:
		_keybind_layer.visible = false


func _ensure_keybind_layer() -> void:
	if _keybind_layer != null:
		return

	_keybind_layer = CanvasLayer.new()
	_keybind_layer.name = "Keybinds"
	_keybind_layer.layer = 3
	_keybind_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_keybind_layer.visible = false
	add_child(_keybind_layer)

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_keybind_layer.add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.theme = _dialog_theme(16)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -300.0
	panel.offset_top = -240.0
	panel.offset_right = 300.0
	panel.offset_bottom = 240.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.045, 0.065, 0.98)
	style.border_color = Color(1.0, 0.84, 0.32, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.text = "CONTROLS"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.32))
	box.add_child(title)

	var hint := Label.new()
	hint.text = "Click a binding and press a key or mouse button."
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	box.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_keybind_list = VBoxContainer.new()
	_keybind_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_keybind_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_keybind_list)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	box.add_child(actions)

	var reset := Button.new()
	reset.text = "Reset Defaults"
	reset.pressed.connect(_reset_input_bindings)
	actions.add_child(reset)

	var close := Button.new()
	close.text = "Back"
	close.pressed.connect(_close_keybinds)
	actions.add_child(close)


func _refresh_keybind_rows() -> void:
	if _keybind_list == null:
		return
	for child in _keybind_list.get_children():
		child.free()

	for action: StringName in BINDABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_keybind_list.add_child(row)

		var label := Label.new()
		label.text = _action_title(action)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 14)
		row.add_child(label)

		var button := Button.new()
		button.text = _binding_text(action)
		button.custom_minimum_size = Vector2(170.0, 26.0)
		button.add_theme_font_size_override("font_size", 14)
		button.pressed.connect(
			func() -> void: _start_rebind(action, button)
		)
		row.add_child(button)


func _action_title(action: StringName) -> String:
	return String(action).replace("_", " ").capitalize()


func _binding_text(action: StringName) -> String:
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "Unbound"
	var event: InputEvent = events[0]
	# Prefer the keyboard/mouse binding when an action also has a joypad event.
	for candidate in events:
		if candidate is InputEventKey or candidate is InputEventMouseButton:
			event = candidate
			break
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var code: int = (
			key_event.physical_keycode
			if key_event.physical_keycode != 0
			else key_event.keycode
		)
		return OS.get_keycode_string(code)
	if event is InputEventMouseButton:
		return "Mouse %d" % (event as InputEventMouseButton).button_index
	if event is InputEventJoypadButton:
		return "Joy %d" % (event as InputEventJoypadButton).button_index
	if event is InputEventJoypadMotion:
		return "Joy Axis"
	return "Bound"


func _start_rebind(action: StringName, button: Button) -> void:
	_binding_action = action
	_binding_button = button
	button.text = "Press a key..."
	_play_ui(UI_SOUND_CLICK, -11.0)


func _cancel_rebind() -> void:
	if _binding_button != null and is_instance_valid(_binding_button) and not _binding_action.is_empty():
		_binding_button.text = _binding_text(_binding_action)
	_binding_action = &""
	_binding_button = null


func _handle_keybind_input(event: InputEvent) -> void:
	if _binding_action.is_empty():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_keybinds()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_ESCAPE:
			_cancel_rebind()
		else:
			var code: int = (
				key_event.physical_keycode
				if key_event.physical_keycode != 0
				else key_event.keycode
			)
			if code != 0:
				var binding := InputEventKey.new()
				binding.physical_keycode = code as Key
				_apply_binding(binding)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event := event as InputEventMouseButton
		var mouse_binding := InputEventMouseButton.new()
		mouse_binding.button_index = mouse_event.button_index
		_apply_binding(mouse_binding)
		get_viewport().set_input_as_handled()


func _apply_binding(binding: InputEvent) -> void:
	if _binding_action.is_empty():
		return
	InputMap.action_erase_events(_binding_action)
	InputMap.action_add_event(_binding_action, binding)
	_save_input_bindings()
	var action := _binding_action
	_binding_action = &""
	if _binding_button != null and is_instance_valid(_binding_button):
		_binding_button.text = _binding_text(action)
	_binding_button = null
	_play_ui(UI_SOUND_ACCEPT, -9.0)


func _reset_input_bindings() -> void:
	InputMap.load_from_project_settings()
	_save_input_bindings()
	_cancel_rebind()
	_cancel_keybind_rebind()
	_refresh_keybind_rows()
	_refresh_keybind_page()
	_play_ui(UI_SOUND_ACCEPT, -9.0)


func _save_input_bindings() -> void:
	var config := ConfigFile.new()
	for action: StringName in BINDABLE_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var encoded: Array = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				var key_event := event as InputEventKey
				encoded.append({
					"type": "key",
					"physical": int(key_event.physical_keycode),
					"key": int(key_event.keycode),
				})
			elif event is InputEventMouseButton:
				encoded.append({
					"type": "mouse",
					"button": int((event as InputEventMouseButton).button_index),
				})
		config.set_value("bindings", String(action), encoded)
	config.save("user://input_map.cfg")


func _load_input_bindings() -> void:
	var config := ConfigFile.new()
	if config.load("user://input_map.cfg") != OK:
		return
	for action: StringName in BINDABLE_ACTIONS:
		var value: Variant = config.get_value("bindings", String(action), null)
		if not value is Array:
			continue
		InputMap.action_erase_events(action)
		for entry: Variant in value:
			if not entry is Dictionary:
				continue
			var data: Dictionary = entry
			if String(data.get("type", "")) == "key":
				var key_event := InputEventKey.new()
				key_event.physical_keycode = int(data.get("physical", 0)) as Key
				key_event.keycode = int(data.get("key", 0)) as Key
				InputMap.action_add_event(action, key_event)
			elif String(data.get("type", "")) == "mouse":
				var mouse_event := InputEventMouseButton.new()
				mouse_event.button_index = int(data.get("button", 0)) as MouseButton
				InputMap.action_add_event(action, mouse_event)


func _ensure_keybinds_ui() -> void:
	if _keybinds_panel != null:
		return
	_keybinds_panel = _ensure_category_panel("KeybindsPanel")
	var left := _ensure_water_column(
		_keybinds_panel, "LeftColumn", Vector3(-0.68, 0, 0.035)
	)
	var right := _ensure_water_column(
		_keybinds_panel, "RightColumn", Vector3(0.68, 0, 0.035)
	)
	var rows: Array[float] = [0.45, 0.20, -0.05, -0.30]
	for slot in KEYBINDS_PER_PAGE:
		var column := left if slot < 4 else right
		var button := _button_scene.instantiate()
		button.name = "Bind%d" % slot
		button.set("label_left", true)
		button.set("label_size", 18)
		button.set("action", &"keybind_empty")
		button.set("caption", "")
		button.position = Vector3(0.0, rows[slot % 4], 0.0)
		column.add_child(button)
		_keybind_buttons.append(button)

	_keybind_page_label = Label3D.new()
	_keybind_page_label.name = "PageLabel"
	_keybind_page_label.font = UI_FONT
	_keybind_page_label.font_size = 18
	_keybind_page_label.pixel_size = 0.0021
	_keybind_page_label.no_depth_test = true
	_keybind_page_label.render_priority = 5
	_keybind_page_label.outline_size = 5
	_keybind_page_label.outline_modulate = Color(0, 0, 0, 0.85)
	_keybind_page_label.position = Vector3(0.0, -0.42, 0.035)
	_keybind_panel_add(_keybind_page_label)

	_ensure_water_button(
		_keybinds_panel, "KeybindPrev", "keybind_prev", "Prev",
		-0.58, Vector3(0.75, 0.75, 1.0), 20, -0.65
	)
	_ensure_water_button(
		_keybinds_panel, "KeybindNext", "keybind_next", "Next",
		-0.58, Vector3(0.75, 0.75, 1.0), 20, 0.65
	)
	_ensure_water_button(
		_keybinds_panel, "KeybindReset", "keybind_reset", "Reset",
		-0.78, Vector3(0.65, 0.65, 1.0), 20, -0.65
	)
	_ensure_water_button(
		_keybinds_panel, "KeybindsBack", "back_settings", "Back",
		-0.78, Vector3(0.65, 0.65, 1.0), 20, 0.65
	)
	_refresh_keybind_page()


func _keybind_panel_add(node: Node3D) -> void:
	if _keybinds_panel != null:
		_keybinds_panel.add_child(node)


func _keybind_page_count() -> int:
	return maxi(
		1,
		int(ceil(float(BINDABLE_ACTIONS.size()) / float(KEYBINDS_PER_PAGE)))
	)


func _refresh_keybind_page() -> void:
	if _keybind_buttons.is_empty():
		return
	var pages := _keybind_page_count()
	_keybind_page = clampi(_keybind_page, 0, pages - 1)
	var start := _keybind_page * KEYBINDS_PER_PAGE
	for slot in _keybind_buttons.size():
		var button := _keybind_buttons[slot]
		var index := start + slot
		if index >= BINDABLE_ACTIONS.size():
			button.visible = false
			continue
		var action: StringName = BINDABLE_ACTIONS[index]
		button.visible = InputMap.has_action(action)
		button.set("action", StringName("keybind_" + String(action)))
		button.call("set_caption", _keybind_caption(action))
	if _keybind_page_label != null:
		_keybind_page_label.text = "Page %d / %d" % [
			_keybind_page + 1,
			pages,
		]


func _keybind_caption(action: StringName) -> String:
	return "%s: %s" % [_action_title(action), _binding_text(action)]


func _change_keybind_page(delta: int) -> void:
	var pages := _keybind_page_count()
	_keybind_page = posmod(_keybind_page + delta, pages)
	_refresh_keybind_page()
	_play_ui(UI_SOUND_CLICK, -11.0)


func _start_keybind_rebind(action: StringName, button: Node) -> void:
	_binding_action = action
	_binding_button = null
	_binding_button_3d = button
	button.call("set_caption", _action_title(action) + ": Press a key...")
	_play_ui(UI_SOUND_CLICK, -11.0)


func _cancel_keybind_rebind() -> void:
	if _binding_button_3d != null and is_instance_valid(_binding_button_3d):
		if not _binding_action.is_empty():
			_binding_button_3d.call("set_caption", _keybind_caption(_binding_action))
	_binding_action = &""
	_binding_button_3d = null


func _handle_keybind_capture(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_ESCAPE:
			_cancel_keybind_rebind()
		else:
			var code: int = (
				key_event.physical_keycode
				if key_event.physical_keycode != 0
				else key_event.keycode
			)
			if code != 0:
				var binding := InputEventKey.new()
				binding.physical_keycode = code as Key
				_apply_keybind_binding(binding)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed:
		var mouse_event := event as InputEventMouseButton
		var mouse_binding := InputEventMouseButton.new()
		mouse_binding.button_index = mouse_event.button_index
		_apply_keybind_binding(mouse_binding)
		get_viewport().set_input_as_handled()


func _apply_keybind_binding(binding: InputEvent) -> void:
	if _binding_action.is_empty():
		return
	InputMap.action_erase_events(_binding_action)
	InputMap.action_add_event(_binding_action, binding)
	_save_input_bindings()
	var action := _binding_action
	_binding_action = &""
	if _binding_button_3d != null and is_instance_valid(_binding_button_3d):
		_binding_button_3d.call("set_caption", _keybind_caption(action))
	_binding_button_3d = null
	_play_ui(UI_SOUND_ACCEPT, -9.0)


func _ensure_category_panel(node_name: String) -> Node3D:
	var panel_root := get_node_or_null("Panel") as Node3D
	if panel_root == null:
		return null
	var panel := panel_root.get_node_or_null(node_name) as Node3D
	if panel == null:
		panel = Node3D.new()
		panel.name = node_name
		panel.visible = false
		panel_root.add_child(panel)
	return panel


func _move_settings_button(
	node_name: String,
	parent: Node3D,
	local_y: float,
	local_x: float = 0.0
) -> void:
	if _settings_panel == null or parent == null:
		return
	var button := _settings_panel.find_child(node_name, true, false) as Node3D
	if button == null:
		return
	button.reparent(parent, false)
	button.position = Vector3(local_x, local_y, 0.0)
	button.set("_rest_position", button.position)


## The Saves view can also be resaved from an older editor copy. Normalize its
## layout and recreate the New Map / Rename / World Type controls if missing.
func _ensure_saves_ui() -> void:
	var saves := get_node_or_null("Panel/SavesPanel") as Node3D
	if saves == null:
		return

	# Sort is part of the saves view even in older scene copies that already
	# have the other controls.
	_ensure_save_sort_button(saves)

	var has_rename := (
		saves.get_node_or_null("LeftActions/Rename") != null
		or saves.get_node_or_null("RightActions/Rename") != null
	)
	if (
		saves.get_node_or_null("NewMap") != null
		and saves.get_node_or_null("WorldType") != null
		and has_rename
	):
		return

	var save_list := saves.get_node_or_null("SaveList") as Node3D
	if save_list != null:
		save_list.position = Vector3(-0.55, 0.50, 0.035)
	var page := saves.get_node_or_null("PageLabel") as Label3D
	if page != null:
		page.position = Vector3(-0.55, -0.36, 0.04)

	var left := saves.get_node_or_null("LeftActions") as Node3D
	var right := saves.get_node_or_null("RightActions") as Node3D
	if left != null:
		var header_scale := Vector3(0.7, 0.85, 1.0)
		_place_saves_button(left, "Save", -0.48, header_scale, 20)
		_place_saves_button(left, "SaveAs", -0.65, header_scale, 20)
		_place_saves_button(left, "Load", -0.82, header_scale, 20)
	if right != null:
		_place_saves_button(right, "Duplicate", -0.48)
		_place_saves_button(right, "Delete", -0.65)
		_place_saves_button(right, "Back", -0.82)
		_ensure_water_button(
			right, "Rename", "rename", "Rename", 0.66,
			Vector3(0.7, 0.85, 1.0), 20, 0.0, true
		)

	_ensure_water_button(
		saves, "NewMap", "new_map", "New Map...", 0.80,
		Vector3(0.7, 0.85, 1.0), 20, -0.62, true
	)
	_ensure_water_button(
		saves, "WorldType", "world_type", "World: Blank Platform", 0.66,
		Vector3(0.7, 0.85, 1.0), 18, -0.62, true
	)


func _ensure_save_sort_button(saves: Node3D) -> void:
	var right := saves.get_node_or_null("RightActions") as Node3D
	var parent: Node3D = right if right != null else saves
	var local_x: float = 0.0 if right != null else 0.62
	_ensure_water_button(
		parent,
		"Sort",
		"save_sort",
		"Sort: Last Played",
		0.80,
		Vector3(0.7, 0.85, 1.0),
		18,
		local_x,
		true
	)


func _place_saves_button(
	parent: Node3D,
	node_name: String,
	local_y: float,
	button_scale: Vector3 = Vector3(0.52, 0.85, 1.0),
	label_size_value: int = 22
) -> void:
	var button := parent.get_node_or_null(node_name) as Node3D
	if button == null:
		return
	button.position = Vector3(0.0, local_y, 0.0)
	button.scale = button_scale
	button.set("label_size", label_size_value)
	button.set("keep_label_aspect", true)
	if button.has_method("refresh_label_aspect"):
		button.call("refresh_label_aspect")
	button.set("_rest_position", button.position)


# ============================================================
# DEMOS LIBRARY
# ============================================================

func _ensure_demos_ui() -> void:
	_demos_panel = get_node_or_null("Panel/DemosPanel") as Node3D

	if _demos_panel == null:
		return

	if _demo_list != null and is_instance_valid(_demo_list):
		return

	_demo_list = Node3D.new()
	_demo_list.name = "DemoList"
	_demo_list.position = Vector3(-0.55, 0.40, 0.035)
	_demos_panel.add_child(_demo_list)

	_demo_page_label = Label3D.new()
	_demo_page_label.name = "PageLabel"
	_demo_page_label.position = Vector3(-0.55, -0.20, 0.04)
	_demo_page_label.font = UI_FONT
	_demo_page_label.font_size = 20
	_demo_page_label.pixel_size = 0.0018
	_demo_page_label.modulate = Color(0.85, 0.84, 0.76, 1)
	_demos_panel.add_child(_demo_page_label)

	_demo_details = Label3D.new()
	_demo_details.name = "DemoDetails"
	_demo_details.position = Vector3(0.62, 0.66, 0.04)
	_demo_details.font = UI_FONT
	_demo_details.font_size = 16
	_demo_details.pixel_size = 0.0022
	_demo_details.line_spacing = 26.0
	_demo_details.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_demo_details.modulate = Color(0.92, 0.92, 0.86, 1)
	_demo_details.width = 320.0
	_demo_details.no_depth_test = true
	_demo_details.render_priority = 5
	_demo_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_demos_panel.add_child(_demo_details)

	_demo_status_label = Label3D.new()
	_demo_status_label.name = "StatusLabel"
	_demo_status_label.position = Vector3(-0.55, -0.97, 0.04)
	_demo_status_label.font = UI_FONT
	_demo_status_label.font_size = 18
	_demo_status_label.pixel_size = 0.0016
	_demo_status_label.modulate = Color(1.0, 0.84, 0.34, 1)
	_demo_status_label.no_depth_test = true
	_demo_status_label.render_priority = 5
	_demos_panel.add_child(_demo_status_label)

	var left := Node3D.new()
	left.name = "LeftActions"
	left.position = Vector3(-0.68, 0, 0)
	_demos_panel.add_child(left)

	var right := Node3D.new()
	right.name = "RightActions"
	right.position = Vector3(0.68, 0, 0)
	_demos_panel.add_child(right)

	_ensure_water_button(left, "Play", "play_demo", "Play", -0.34, Vector3.ONE, 22)
	_ensure_water_button(left, "Rename", "rename_demo", "Rename", -0.50, Vector3.ONE, 22)
	_ensure_water_button(left, "Description", "describe_demo", "Description", -0.66, Vector3.ONE, 22)
	_ensure_water_button(left, "Folder", "folder_demo", "Move to Folder", -0.82, Vector3.ONE, 20)
	_ensure_water_button(right, "Compare", "compare_demo", "Compare", -0.34, Vector3.ONE, 22)
	_ensure_water_button(right, "Duplicate", "duplicate_demo", "Duplicate", -0.50, Vector3.ONE, 22)
	_ensure_water_button(right, "Delete", "delete_demo", "Delete", -0.66, Vector3.ONE, 22)
	_ensure_water_button(right, "Back", "back_demos", "Back", -0.82, Vector3.ONE, 22)

	_ensure_water_button(
		_demos_panel,
		"FolderFilter",
		"demo_folder_filter",
		"Folder: All",
		0.62,
		Vector3.ONE,
		18,
		-0.55
	)
	_demo_folder_button = _demos_panel.get_node_or_null("FolderFilter")
	_demo_compare_button = _demos_panel.get_node_or_null("RightActions/Compare")
	_sync_compare_button()


func _filtered_demo_count() -> int:
	var count: int = 0

	for demo: Dictionary in _demos:
		if (
			_demo_folder_filter.is_empty()
			or String(demo.get("folder", "")) == _demo_folder_filter
		):
			count += 1

	return count


func _refresh_demo_list() -> void:
	if _demo_list == null or not is_instance_valid(_demo_list):
		return

	for child in _demo_list.get_children():
		child.free()

	if _hovered != null and not is_instance_valid(_hovered):
		_hovered = null

	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		_demo_page_label.text = "Demo library unavailable"
		_demo_details.text = ""
		return

	if not bool(store.call("has_active_save")):
		# Direct scene runs have no save; they are grouped under "_unsaved" so
		# the demos are still inspectable, but they are not attached to a map.
		pass

	_demos = store.call("list_demos")

	var filtered: Array = []

	for demo: Dictionary in _demos:
		if _demo_folder_filter.is_empty() or String(demo.get("folder", "")) == _demo_folder_filter:
			filtered.append(demo)

	if filtered.is_empty():
		_selected_demo_id = ""
		_demo_page_label.text = (
			"No demos in this folder"
			if _demos.size() > 0
			else "No demos recorded for this save"
		)
		_demo_details.text = ""
		_update_demo_folder_caption()
		return

	var found := false

	for demo: Dictionary in filtered:
		if String(demo.get("id", "")) == _selected_demo_id:
			found = true
			break

	if not found:
		_selected_demo_id = String(filtered[0].get("id", ""))

	_demo_start = clampi(_demo_start, 0, maxi(0, filtered.size() - 1))
	var last := mini(_demo_start + save_rows_per_page, filtered.size())

	for index in range(_demo_start, last):
		var demo: Dictionary = filtered[index]
		var demo_id := String(demo.get("id", ""))
		var compare_index := _demo_compare_ids.find(demo_id)
		var button := _button_scene.instantiate()
		button.action = &"select_demo"
		button.payload = demo_id
		var folder := String(demo.get("folder", ""))
		var caption := (
			("%s / %s" % [folder, String(demo.get("name", "Demo"))])
			if not folder.is_empty()
			else String(demo.get("name", "Demo"))
		)
		if _demo_compare_mode and compare_index >= 0:
			caption = "%s · %s" % [char(65 + compare_index), caption]
		button.caption = caption
		button.position = Vector3(0, -save_row_step * (index - _demo_start), 0)
		button.label_size = 20
		button.label_pixel = 0.0019
		_demo_list.add_child(button)

		if _demo_compare_mode:
			if compare_index >= 0:
				button.set_selected(true)
		elif demo_id == _selected_demo_id:
			button.set_selected(true)

	var page := int(float(_demo_start) / float(save_rows_per_page)) + 1
	var pages := int(ceil(float(filtered.size()) / float(save_rows_per_page)))
	_demo_page_label.text = "Page %d/%d  ·  wheel to scroll" % [page, pages]
	_update_demo_details()
	_update_demo_folder_caption()


func _update_demo_details() -> void:
	if _demo_details == null:
		return

	var demo := _selected_demo_meta()

	if demo.is_empty():
		_demo_details.text = ""
		return

	var created := _format_modified(float(demo.get("created", 0.0)))
	var duration := _format_duration(float(demo.get("duration", 0.0)))
	var status := String(demo.get("status", "unknown"))
	var summary: Dictionary = demo.get("summary", {})
	var description := String(demo.get("description", ""))

	if description.is_empty():
		description = "(no description)"

	_demo_details.text = "\n".join(PackedStringArray([
		String(demo.get("name", "Demo")),
		"Folder: " + (String(demo.get("folder", "")) if not String(demo.get("folder", "")).is_empty() else "—"),
		created + "  ·  " + duration + "  ·  " + status,
		"Agents %d  ·  Seed %d" % [
			int(demo.get("agents", 0)),
			int(demo.get("seed", 0)),
		],
		"Evacuated %d  ·  Avg %.1fs  ·  Max density %.2f/m²" % [
			int(summary.get("agents_evacuated", 0)),
			float(summary.get("average_evacuation_time", 0.0)),
			float(summary.get("global_max_density", 0.0)),
		],
		description,
	]))


func _update_demo_folder_caption() -> void:
	if _demo_folder_button != null and is_instance_valid(_demo_folder_button):
		_demo_folder_button.set_caption(
			"Folder: " + (_demo_folder_filter if not _demo_folder_filter.is_empty() else "All")
		)


func _selected_demo_meta() -> Dictionary:
	for demo: Dictionary in _demos:
		if String(demo.get("id", "")) == _selected_demo_id:
			return demo
	return {}


func _select_demo(demo_id: String) -> void:
	if _demo_compare_mode:
		_toggle_demo_compare_id(demo_id)
		return

	_selected_demo_id = demo_id
	_refresh_demo_list()
	_set_demo_status("Selected: " + String(_selected_demo_meta().get("name", demo_id)))


func _toggle_demo_compare_id(demo_id: String) -> void:
	var index := _demo_compare_ids.find(demo_id)

	if index >= 0:
		_demo_compare_ids.remove_at(index)
	elif _demo_compare_ids.size() >= 6:
		_set_demo_status("Compare supports up to 6 demos")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return
	else:
		_demo_compare_ids.append(demo_id)

	_selected_demo_id = demo_id
	_refresh_demo_list()
	_sync_compare_button()
	_set_demo_status("Compare: %d selected (need 2+)" % _demo_compare_ids.size())


func _sync_compare_button() -> void:
	if _demo_compare_button == null or not is_instance_valid(_demo_compare_button):
		return

	_demo_compare_button.set_caption(
		("Start (%d)" % _demo_compare_ids.size()) if _demo_compare_mode else "Compare"
	)


func _toggle_demo_compare() -> void:
	if not _demo_compare_mode:
		_demo_compare_mode = true
		_demo_compare_ids.clear()
		_sync_compare_button()
		_refresh_demo_list()
		_set_demo_status("Compare: select 2+ demos, then press Start")
		return

	if _demo_compare_ids.size() < 2:
		_set_demo_status("Select at least two demos to compare")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return

	_start_demo_compare()


func _cancel_demo_compare(refresh: bool = true) -> void:
	_demo_compare_mode = false
	_demo_compare_ids.clear()
	_sync_compare_button()

	if refresh:
		_refresh_demo_list()
		_set_demo_status("")


func _start_demo_compare() -> void:
	var comparer := get_node_or_null("/root/DemoComparer")

	if comparer == null:
		_set_demo_status("Demo comparer unavailable")
		return

	if not bool(comparer.call("play", _demo_compare_ids.duplicate())):
		_set_demo_status("Could not compare these demos")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return

	if not comparer.closed.is_connected(_on_demo_comparer_closed):
		comparer.closed.connect(_on_demo_comparer_closed)

	_play_ui(UI_SOUND_ACCEPT, -8.0)
	set_process_input(false)
	set_process(false)
	visible = false


func _on_demo_comparer_closed() -> void:
	visible = true
	set_process_input(true)
	set_process(true)
	_show_view("demos")
	_set_demo_status(
		("Compare: %d selected" % _demo_compare_ids.size())
		if _demo_compare_mode
		else ""
	)


func _set_demo_status(text: String) -> void:
	if _demo_status_label == null:
		return

	_demo_status_label.text = text


func _play_selected_demo() -> void:
	if _selected_demo_id.is_empty():
		_set_demo_status("Select a demo first")
		return

	var player := get_node_or_null("/root/DemoPlayer")

	if player == null:
		_set_demo_status("Demo player unavailable")
		return

	if not bool(player.call("play", _selected_demo_id)):
		_set_demo_status("Could not play this demo")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return

	if not player.closed.is_connected(_on_demo_player_closed):
		player.closed.connect(_on_demo_player_closed)

	_play_ui(UI_SOUND_ACCEPT, -8.0)
	set_process_input(false)
	set_process(false)
	visible = false


func _on_demo_player_closed() -> void:
	visible = true
	set_process_input(true)
	set_process(true)
	_show_view("demos")


func _prompt_demo_rename() -> void:
	var demo := _selected_demo_meta()

	if demo.is_empty():
		return

	_prompt_name(
		"Rename Demo",
		String(demo.get("name", "Demo")),
		_finish_demo_rename
	)


func _finish_demo_rename(value: String) -> void:
	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return

	if bool(store.call("rename_demo", _selected_demo_id, value)):
		_set_demo_status("Renamed")
		_play_ui(UI_SOUND_SAVE, -7.0)
		_refresh_demo_list()
	else:
		_set_demo_status("Rename failed (empty name?)")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)


func _prompt_demo_description() -> void:
	var demo := _selected_demo_meta()

	if demo.is_empty():
		return

	_prompt_text(
		"Demo Description",
		String(demo.get("description", "")),
		_finish_demo_description
	)


func _finish_demo_description(value: String) -> void:
	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return

	if bool(store.call("describe_demo", _selected_demo_id, value)):
		_set_demo_status("Description saved")
		_play_ui(UI_SOUND_SAVE, -7.0)
		_refresh_demo_list()


func _prompt_demo_folder() -> void:
	var demo := _selected_demo_meta()

	if demo.is_empty():
		return

	_prompt_name(
		"Demo Folder (empty = none)",
		String(demo.get("folder", "")),
		_finish_demo_folder
	)


func _finish_demo_folder(value: String) -> void:
	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return

	if bool(store.call("move_demo", _selected_demo_id, value)):
		_set_demo_status("Folder updated")
		_demo_folder_filter = ""
		_play_ui(UI_SOUND_SAVE, -7.0)
		_refresh_demo_list()


func _cycle_demo_folder() -> void:
	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return

	var folders: Array = store.call("list_folders")
	var options: Array[String] = [""]
	options.append_array(folders)
	var index: int = options.find(_demo_folder_filter)
	_demo_folder_filter = options[(index + 1) % options.size()]
	_demo_start = 0
	_refresh_demo_list()


func _prompt_demo_duplicate() -> void:
	var demo := _selected_demo_meta()

	if demo.is_empty():
		return

	_prompt_name(
		"Duplicate Demo",
		String(demo.get("name", "Demo")) + " Copy",
		_finish_demo_duplicate
	)


func _finish_demo_duplicate(value: String) -> void:
	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return

	var new_id: String = String(store.call("duplicate_demo", _selected_demo_id))

	if new_id.is_empty():
		_set_demo_status("Duplicate failed")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return

	if not value.strip_edges().is_empty():
		store.call("rename_demo", new_id, value)

	_selected_demo_id = new_id
	_set_demo_status("Duplicated")
	_play_ui(UI_SOUND_SAVE, -7.0)
	_refresh_demo_list()


func _confirm_demo_delete() -> void:
	var demo := _selected_demo_meta()

	if demo.is_empty():
		return

	_confirm(
		"Delete Demo",
		"Delete \"%s\" and its recording files?\nThis cannot be undone."
		% String(demo.get("name", "Demo")),
		_finish_demo_delete,
		"Delete"
	)


func _finish_demo_delete() -> void:
	var store := get_node_or_null("/root/DemoStore")

	if store == null:
		return

	if bool(store.call("delete_demo", _selected_demo_id)):
		_selected_demo_id = ""
		_set_demo_status("Deleted")
		_play_ui(UI_SOUND_ACCEPT, -8.0)
		_refresh_demo_list()


func _format_duration(seconds: float) -> String:
	var total := maxi(0, int(round(seconds)))
	return "%d:%02d" % [int(float(total) / 60.0), total % 60]



func _ensure_water_column(
	parent: Node3D,
	column_name: String,
	local_position: Vector3
) -> Node3D:
	var column := parent.get_node_or_null(column_name) as Node3D
	if column == null:
		column = Node3D.new()
		column.name = column_name
		column.position = local_position
		parent.add_child(column)
	return column


func _ensure_water_button(
	parent: Node3D,
	node_name: String,
	action: String,
	caption: String,
	local_y: float,
	button_scale: Vector3 = Vector3.ONE,
	label_size_value: int = 24,
	local_x: float = 0.0,
	keep_aspect: bool = false
) -> void:
	if parent.get_node_or_null(node_name) != null:
		return

	var button := _button_scene.instantiate()
	button.name = node_name
	button.action = StringName(action)
	button.caption = caption
	button.label_size = label_size_value
	button.set("keep_label_aspect", keep_aspect)
	button.position = Vector3(local_x, local_y, 0.0)
	button.scale = button_scale
	parent.add_child(button)


func _animate_view(view: String) -> void:
	if view == "main":
		_play_title_intro()
		_play_buttons_intro(_main_panel)
		return

	_play_section_intro()
	match view:
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
		"controls":
			_play_buttons_intro(_controls_panel)
		"water":
			_play_buttons_intro(_water_panel)
		"statistics":
			_play_map_intro()
			_play_buttons_intro(_stats_panel)
		"saves":
			_play_buttons_intro(_saves_panel)
			_play_preview_intro()
		"demos":
			_play_buttons_intro(_demos_panel)


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


## Every title letter rushes in from the bottom-right, slightly rotated, then
## settles. Letters are staggered so the word assembles like a title card.
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


## Buttons drop in from above, top row first.
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


func _play_map_intro() -> void:
	if not _stats_map.visible:
		return
	var map_material := _stats_map.material_override as StandardMaterial3D
	if map_material == null:
		return
	if is_instance_valid(_map_tween):
		_map_tween.kill()

	_stats_map.scale = _stats_rest_scale * 0.96
	map_material.albedo_color.a = 0.0
	_stats_text.modulate.a = 0.0
	_map_tween = create_tween().set_parallel(true)
	_map_tween.tween_property(_stats_map, "scale", _stats_rest_scale, 0.32) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_map_tween.tween_property(map_material, "albedo_color:a", 1.0, 0.26)
	_map_tween.tween_property(_stats_text, "modulate:a", 1.0, 0.3).set_delay(0.06)


func _play_preview_intro() -> void:
	if not _thumbnail.visible:
		return
	var preview_material := _thumbnail.material_override as StandardMaterial3D
	if preview_material == null:
		return
	if is_instance_valid(_preview_tween):
		_preview_tween.kill()

	_thumbnail.scale = _thumbnail_rest_scale * 0.97
	preview_material.albedo_color.a = 0.0
	_save_details.modulate.a = 0.0
	_preview_tween = create_tween().set_parallel(true)
	_preview_tween.tween_property(
		_thumbnail,
		"scale",
		_thumbnail_rest_scale,
		0.28
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_preview_tween.tween_property(preview_material, "albedo_color:a", 1.0, 0.24)
	_preview_tween.tween_property(
		_save_details,
		"modulate:a",
		1.0,
		0.24
	).set_delay(0.05)


## Subtle parallax: the panel leans toward the hovered entry and the camera
## offsets a hair, so the whole menu feels alive without moving much.
func _set_cursor_sway(screen_position: Vector2) -> void:
	var viewport_size := get_viewport().get_visible_rect().size

	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	_cursor_nx = clampf((screen_position.x / viewport_size.x) * 2.0 - 1.0, -1.0, 1.0)
	_cursor_ny = clampf((screen_position.y / viewport_size.y) * 2.0 - 1.0, -1.0, 1.0)


## `button` is intentionally untyped: it can be a hovered entry that the Saves
## or Settings rebuild just freed, and a typed Area3D parameter would throw a
## "previously freed" type error before the validity check below could run.
func _sway_to(button: Variant) -> void:
	if not _paused:
		return

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
	if _camera != null:
		_sway_tween.tween_property(_camera, "h_offset", target_h, 0.4)
		_sway_tween.tween_property(_camera, "v_offset", target_v, 0.4)

	if _title_root != null:
		# The title is a child of the panel, so it already travels with every
		# button. Keep its anchor pinned and only add a small cursor tilt, which
		# reads as the title following the mouse without sliding out of sync.
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
	if _camera != null:
		_camera.h_offset = _camera_h_rest
		_camera.v_offset = _camera_v_rest
	if _title_root != null:
		_title_root.position = _title_rest_position
		_title_root.rotation = _title_rest_rotation


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
		"shadows":
			return "Shadows: " + PerformanceSettings.shadows_name()
		"shadow_distance":
			return "Shadow Dist: " + PerformanceSettings.shadow_distance_name()
		"foliage_distance":
			return "Foliage: " + PerformanceSettings.foliage_scale_name()
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
		"water":
			return "Water FX: " + PerformanceSettings.water_name()
		"water_flow":
			return "Flow: " + PerformanceSettings.water_flow_name()
		"water_equalize":
			return "Equalize: " + PerformanceSettings.water_equalize_name()
		"water_budget":
			return "Budget: " + PerformanceSettings.water_budget_name()
		"water_mesh":
			return "Mesh: " + PerformanceSettings.water_mesh_rate_name()
		"water_wave_detail":
			return "Wave Size: " + PerformanceSettings.water_wave_detail_name()
		"water_wave_cap":
			return "Samples: " + PerformanceSettings.water_wave_cap_name()
		"water_waves":
			return "Waves: " + PerformanceSettings.water_waves_name()
		"water_splashes":
			return "Splashes: " + PerformanceSettings.water_splashes_name()
		"water_surface_drops":
			return "Drops: " + PerformanceSettings.water_surface_particles_name()
		"water_wake":
			return "Wake: " + PerformanceSettings.water_wake_name()
		"world_type":
			return _world_caption()
		"save_sort":
			return "Sort: " + (
				"Last Played"
				if _save_manager == null
				else String(_save_manager.sort_mode_label())
			)
		"demo_folder_filter":
			return "Folder: " + (_demo_folder_filter if not _demo_folder_filter.is_empty() else "All")
		"volume":
			return "Volume: " + PerformanceSettings.volume_name()
		"music":
			return "Music: " + PerformanceSettings.music_volume_name()
		"fps":
			return "FPS Cap: " + PerformanceSettings.fps_name()
		"view_roll":
			return "View Roll: " + PerformanceSettings.view_roll_name()
	return ""


func _world_size_label(size_name: String) -> String:
	match size_name:
		"small":
			return "Small (128)"
		"large":
			return "Large (384)"
		_:
			return "Medium (256)"


func _world_size_short(size_name: String) -> String:
	match size_name:
		"small":
			return "128"
		"large":
			return "384"
		_:
			return "256"


func _generator_label(generator_id: String) -> String:
	return WORLD_GENERATORS.label(generator_id)


## One-line caption for the shared World Type button.
func _world_caption() -> String:
	if _new_map_world_type == "blank":
		return "World: Blank Platform"

	var label := WORLD_GENERATORS.label(_new_map_generator_id)

	if WORLD_GENERATORS.supports_sizes(_new_map_generator_id):
		return "World: %s %s" % [label, _world_size_short(_new_map_world_size)]

	return "World: %s" % label


func _all_buttons() -> Array:
	var result: Array = []
	_collect_buttons(self, result)
	return result


func _collect_buttons(node: Node, result: Array) -> void:
	for child in node.get_children():
		if child is Area3D and child.has_method("set_hovered"):
			result.append(child)
		_collect_buttons(child, result)


func _button_at(screen_position: Vector2) -> Area3D:
	if (
		not is_inside_tree()
		or _camera == null
		or not is_instance_valid(_camera)
		or not _camera.is_inside_tree()
	):
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
## a list rebuild freed a frame earlier.
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
	if action not in TRANSITION_ACTIONS:
		_play_ui(UI_SOUND_CLICK, -8.0)

	if action.begins_with("keybind_"):
		var bind_key := action.trim_prefix("keybind_")
		if bind_key == "prev":
			_change_keybind_page(-1)
		elif bind_key == "next":
			_change_keybind_page(1)
		elif bind_key == "reset":
			_reset_input_bindings()
			_refresh_keybind_page()
		elif BINDABLE_ACTIONS.has(StringName(bind_key)):
			_start_keybind_rebind(StringName(bind_key), button)
		return

	match action:
		"resume":
			set_paused(false)
		"quit":
			_confirm_quit()
		"settings":
			_show_view("settings")
		"stats":
			_show_view("statistics")
		"saves":
			_show_view("saves")
		"demos":
			_show_view("demos")
		"back_main":
			if saves_only:
				close_saves_only()
			else:
				_show_view("main")
		"back_settings":
			_show_view("settings")
		"water_tuning":
			_show_view("water")
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
		"settings_controls":
			_show_view("controls")
		"export_defaults":
			_open_export_defaults()
		"keybinds":
			_show_view("controls")
		"back_controls":
			_show_view("settings")
		"view_roll":
			PerformanceSettings.cycle_view_roll()
			_refresh_labels()
		"water_flow":
			PerformanceSettings.cycle_water_flow()
			_refresh_labels()
		"water_equalize":
			PerformanceSettings.cycle_water_equalize()
			_refresh_labels()
		"water_budget":
			PerformanceSettings.cycle_water_budget()
			_refresh_labels()
		"water_mesh":
			PerformanceSettings.cycle_water_mesh()
			_refresh_labels()
		"water_wave_detail":
			PerformanceSettings.cycle_water_wave_detail()
			_refresh_labels()
		"water_wave_cap":
			PerformanceSettings.cycle_water_wave_cap()
			_refresh_labels()
		"water_waves":
			PerformanceSettings.toggle_water_waves()
			_refresh_labels()
		"water_splashes":
			PerformanceSettings.toggle_water_splashes()
			_refresh_labels()
		"water_surface_drops":
			PerformanceSettings.toggle_water_surface_particles()
			_refresh_labels()
		"water_wake":
			PerformanceSettings.cycle_water_wake_style()
			_refresh_labels()
		"water_reset":
			PerformanceSettings.reset_water_settings()
			_refresh_labels()
		"mode_heat":
			_stats_mode = "heat"
			_refresh_statistics()
		"mode_route":
			_stats_mode = "route"
			_refresh_statistics()
		"mode_topo":
			_stats_mode = "topo"
			_refresh_statistics()
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
		"shadows":
			PerformanceSettings.toggle_shadows()
			_refresh_labels()
		"shadow_distance":
			PerformanceSettings.cycle_shadow_distance()
			_refresh_labels()
		"foliage_distance":
			PerformanceSettings.cycle_foliage_scale()
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
		"water":
			PerformanceSettings.toggle_water()
			_refresh_labels()
		"volume":
			PerformanceSettings.cycle_volume()
			_refresh_labels()
		"music":
			PerformanceSettings.cycle_music_volume()
			_refresh_labels()
		"fps":
			PerformanceSettings.cycle_fps()
			_refresh_labels()
		"reset":
			PerformanceSettings.apply_preset(1)
			_refresh_labels()
		"save":
			_on_save()
		"save_as":
			_prompt_save_as()
		"new_map":
			_prompt_new_map()
		"rename":
			_prompt_rename()
		"world_type":
			_prompt_world_settings()
		"save_sort":
			_cycle_save_sort()
		"load":
			_on_load()
		"duplicate":
			_prompt_duplicate()
		"delete":
			_confirm_delete()
		"load_save":
			_select_save(button.payload)
		"select_demo":
			_select_demo(String(button.payload))
		"play_demo":
			_play_selected_demo()
		"compare_demo":
			_toggle_demo_compare()
		"rename_demo":
			_prompt_demo_rename()
		"describe_demo":
			_prompt_demo_description()
		"folder_demo":
			_prompt_demo_folder()
		"demo_folder_filter":
			_cycle_demo_folder()
		"duplicate_demo":
			_prompt_demo_duplicate()
		"delete_demo":
			_confirm_demo_delete()
		"back_demos":
			if _demo_compare_mode:
				_cancel_demo_compare()
			else:
				_show_view("main")


func _refresh_statistics(pop: bool = true) -> void:
	var grid = get_tree().get_first_node_in_group("grid_map")
	if grid == null:
		return

	var image: Image = MAP_RENDERER.render_top_down(grid, _stats_mode, 256)
	var stats_material := _stats_map.material_override as StandardMaterial3D
	if stats_material != null:
		stats_material.albedo_texture = (
			ImageTexture.create_from_image(image) if image != null else null
		)
	_stats_map.visible = image != null
	_stats_text.text = MAP_RENDERER.format_statistics(grid)

	for button in _all_buttons():
		var action := String(button.action)
		if action == "mode_heat":
			button.set_selected(_stats_mode == "heat")
		elif action == "mode_route":
			button.set_selected(_stats_mode == "route")
		elif action == "mode_topo":
			button.set_selected(_stats_mode == "topo")

	if pop and _paused and _view == "statistics":
		_play_map_intro()


func _select_save(slug: String) -> void:
	_selected_slug = slug
	_refresh_save_list()
	_set_status("Selected: " + _display_name(slug))


func _display_name(slug: String) -> String:
	if _save_manager == null:
		return slug
	return String(_save_manager.display_name(slug))


func _cycle_save_sort() -> void:
	if _save_manager == null:
		return
	_save_manager.cycle_sort_mode()
	_refresh_labels()
	_set_status("Sorted by " + _save_manager.sort_mode_label())


func _refresh_save_list() -> void:
	for child in _save_list.get_children():
		child.free()

	# Rows are freed immediately, so any hover reference to them is dead now.
	if _hovered != null and not is_instance_valid(_hovered):
		_hovered = null

	if _save_manager == null:
		_page_label.text = "Save system unavailable"
		return

	_saves = _save_manager.list_saves()

	if _saves.is_empty():
		_page_label.text = "No saves yet"
		_selected_slug = ""
		_update_save_preview()
		return

	var found := false
	for entry: Dictionary in _saves:
		if String(entry.get("slug", "")) == _selected_slug:
			found = true
			break
	if not found:
		_selected_slug = String(_saves[0].get("slug", ""))

	_save_start = clampi(_save_start, 0, maxi(0, _saves.size() - 1))
	var last := mini(_save_start + save_rows_per_page, _saves.size())

	for index in range(_save_start, last):
		var entry: Dictionary = _saves[index]
		var raw_name := String(entry.get("name", "Save"))
		var list_name := raw_name
		var list_label_size := 22

		# Long save names overflow the narrower list rows. Keep the list tidy
		# and show the full name in the details panel.
		if raw_name.length() > 32:
			list_name = raw_name.substr(0, 29).strip_edges() + "..."
			list_label_size = 18
		elif raw_name.length() > 25:
			list_label_size = 20

		var button := _button_scene.instantiate()
		button.action = &"load_save"
		button.caption = list_name
		button.payload = String(entry.get("slug", ""))
		button.position = Vector3(0, -save_row_step * (index - _save_start), 0)
		button.scale = Vector3(0.9, 0.85, 1.0)
		button.label_size = list_label_size
		button.label_pixel = 0.0019
		button.keep_label_aspect = true
		_save_list.add_child(button)
		if String(entry.get("slug", "")) == _selected_slug:
			button.set_selected(true)

	var page := int(float(_save_start) / float(save_rows_per_page)) + 1
	var pages := int(ceil(float(_saves.size()) / float(save_rows_per_page)))
	_page_label.text = "Page %d/%d  ·  wheel to scroll" % [page, pages]
	_update_save_preview()


func _update_save_preview() -> void:
	var thumbnail_material := _thumbnail.material_override as StandardMaterial3D
	if thumbnail_material == null:
		return

	if _save_manager == null or _selected_slug.is_empty():
		thumbnail_material.albedo_texture = null
		_thumbnail.visible = false
		_save_details.text = "Select a save"
		_preview_slug = ""
		return

	var selection_changed: bool = _selected_slug != _preview_slug
	_preview_slug = _selected_slug
	var texture: Texture2D = _save_manager.get_thumbnail(_selected_slug)
	thumbnail_material.albedo_texture = texture
	_thumbnail.visible = texture != null

	var modified := 0.0
	var world_type := "existing"
	var world_generator := ""
	var world_seed := 0
	var world_size := ""

	for entry: Dictionary in _saves:
		if String(entry.get("slug", "")) == _selected_slug:
			modified = float(entry.get("modified", 0.0))
			world_type = String(entry.get("world_type", "existing"))
			world_generator = String(entry.get("world_generator", ""))
			world_seed = int(entry.get("world_seed", 0))
			world_size = String(entry.get("world_size", ""))
			break

	var lines: Array[String] = [
		_display_name(_selected_slug),
		_format_modified(modified),
		(
			"Blank platform"
			if world_type == "blank"
			else ("Procedural" if world_type == "procgen" else "Existing map")
		),
	]

	if world_type == "procgen":
		var detail := "%s · seed %d" % [
			_generator_label(world_generator),
			world_seed,
		]

		if not world_size.is_empty():
			detail += " · " + _world_size_label(world_size)

		lines.append(detail)

	_save_details.text = "\n".join(PackedStringArray(lines))

	if selection_changed and texture != null and _paused:
		_play_preview_intro()


func _format_modified(unix_time: float) -> String:
	if unix_time <= 0.0:
		return "Unknown date"
	var dt: Dictionary = Time.get_datetime_dict_from_unix_time(int(unix_time))
	return "%04d-%02d-%02d  %02d:%02d" % [
		int(dt["year"]),
		int(dt["month"]),
		int(dt["day"]),
		int(dt["hour"]),
		int(dt["minute"]),
	]


func _set_panel_buttons_active(panel: Node, active: bool) -> void:
	var buttons: Array = []
	_collect_buttons(panel, buttons)
	for button in buttons:
		button.collision_layer = MENU_LAYER if active else 0


func _set_status(text: String) -> void:
	_status_label.text = text
	if is_instance_valid(_status_tween):
		_status_tween.kill()
	if text.is_empty():
		_status_label.modulate.a = 1.0
		return
	_status_label.modulate.a = 0.0
	_status_tween = create_tween()
	_status_tween.tween_property(_status_label, "modulate:a", 1.0, 0.2)


func _on_saves_changed() -> void:
	if _saves_panel != null and _saves_panel.visible:
		_refresh_save_list()


func _on_save() -> void:
	if _save_manager == null:
		_set_status("Save system unavailable")
		return
	if not _save_manager.has_active_save():
		_prompt_save_as()
		return
	if _save_manager.save_active():
		_set_status("Saved: " + _save_manager.active_name())
		_play_ui(UI_SOUND_SAVE, -6.0)
		_refresh_save_list()
	else:
		_set_status("Save failed")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)


func _prompt_save_as() -> void:
	if _save_manager == null:
		_set_status("Save system unavailable")
		return
	var initial: String = _save_manager.active_name()
	if initial.is_empty():
		initial = "New Map"
	_prompt_name("Save As", initial, _finish_save_as)


func _finish_save_as(new_name: String) -> void:
	if _save_manager == null:
		return
	var slug: String = _save_manager.save_as(new_name)
	if slug.is_empty():
		_set_status("Save failed")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return
	_selected_slug = slug
	_set_status("Saved: " + _display_name(slug))
	_play_ui(UI_SOUND_SAVE, -6.0)
	_refresh_save_list()


func _prompt_world_settings() -> void:
	_ensure_dialog_layer()
	_dialog_open = true
	_play_ui(UI_SOUND_NOTIF, -11.0)

	var dialog := ConfirmationDialog.new()
	dialog.title = "World Settings"
	dialog.ok_button_text = "Apply"
	dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	dialog.theme = _dialog_theme(16)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size = Vector2(400.0, 0.0)

	var type_option := OptionButton.new()
	type_option.add_item("Blank Platform", 0)
	var generator_entries: Array[Dictionary] = WORLD_GENERATORS.all()
	var selected_index := 0

	for index in generator_entries.size():
		var entry: Dictionary = generator_entries[index]
		type_option.add_item(String(entry.get("label", entry.get("id", ""))), index + 1)
		type_option.set_item_metadata(index + 1, String(entry.get("id", "")))

		if String(entry.get("id", "")) == _new_map_generator_id:
			selected_index = index + 1

	type_option.selected = 0 if _new_map_world_type == "blank" else selected_index
	type_option.theme = _dialog_theme(16)
	box.add_child(type_option)

	var size_option := OptionButton.new()
	size_option.add_item("Small (128)", 0)
	size_option.add_item("Medium (256)", 1)
	size_option.add_item("Large (384)", 2)

	match _new_map_world_size:
		"small":
			size_option.selected = 0
		"large":
			size_option.selected = 2
		_:
			size_option.selected = 1

	size_option.theme = _dialog_theme(16)
	box.add_child(size_option)

	var seed_edit := LineEdit.new()
	seed_edit.text = "0" if _new_map_seed == 0 else str(_new_map_seed)
	seed_edit.placeholder_text = "Seed (0 = random)"
	seed_edit.custom_minimum_size = Vector2(400.0, 32.0)
	seed_edit.theme = _dialog_theme(16)
	box.add_child(seed_edit)

	var procgen_selected := type_option.selected > 0
	var supports_sizes := WORLD_GENERATORS.supports_sizes(
		_new_map_generator_id
	)
	size_option.disabled = not (procgen_selected and supports_sizes)
	seed_edit.editable = procgen_selected

	type_option.item_selected.connect(func(index: int) -> void:
		var generator_id := String(
			type_option.get_item_metadata(index)
		)
		var sizes := WORLD_GENERATORS.supports_sizes(generator_id)
		size_option.disabled = index == 0 or not sizes
		seed_edit.editable = index > 0
	)

	dialog.add_child(box)

	_dialog_layer.add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_TYPING_FINISH, -9.0)
		_new_map_world_type = "blank" if type_option.selected == 0 else "procgen"

		if type_option.selected > 0:
			_new_map_generator_id = String(
				type_option.get_item_metadata(type_option.selected)
			)

		match size_option.selected:
			0:
				_new_map_world_size = "small"
			2:
				_new_map_world_size = "large"
			_:
				_new_map_world_size = "medium"

		var value := seed_edit.text.strip_edges().to_int()
		_new_map_seed = value if value != 0 else (randi() & 0x7FFFFFFF)

		dialog.queue_free()
		_refresh_labels()
	)
	dialog.canceled.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_CLICK, -11.0)
		dialog.queue_free()
	)
	dialog.popup_centered(Vector2i(500, 280))


func _prompt_new_map() -> void:
	if _new_map_world_type == "procgen" and _new_map_seed == 0:
		_new_map_seed = randi() & 0x7FFFFFFF
		_refresh_labels()

	_prompt_name("New Map", "New Map", _request_new_map_confirm)


func _request_new_map_confirm(new_name: String) -> void:
	_pending_new_map_name = new_name
	var world_line := "Blank platform"

	if _new_map_world_type == "procgen":
		var generator_label := WORLD_GENERATORS.label(_new_map_generator_id)

		if WORLD_GENERATORS.supports_sizes(_new_map_generator_id):
			world_line = "%s, %s, seed %d" % [
				generator_label,
				_world_size_label(_new_map_world_size),
				_new_map_seed,
			]
		else:
			world_line = "%s, seed %d" % [generator_label, _new_map_seed]

	_confirm(
		"Create New Map",
		"Create \"%s\"?\nWorld: %s\nUnsaved changes to the current map will be lost."
		% [new_name, world_line],
		_finish_new_map,
		"Create"
	)


func _finish_new_map() -> void:
	if _save_manager == null:
		_set_status("Save system unavailable")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return

	var world_options: Dictionary = {
		"type": _new_map_world_type,
		"generator": "",
		"seed": 0,
		"size": "small",
		"options": {},
	}

	if _new_map_world_type == "procgen":
		if _new_map_seed == 0:
			_new_map_seed = randi() & 0x7FFFFFFF

		world_options = {
			"type": "procgen",
			"generator": _new_map_generator_id,
			"seed": _new_map_seed,
			"size": _new_map_world_size,
			"options": {},
		}

	if saves_only:
		close_saves_only()
	else:
		set_paused(false)
	save_loaded.emit()
	_save_manager.new_blank_map(_pending_new_map_name, world_options)


func _prompt_rename() -> void:
	if _selected_slug.is_empty():
		_set_status("Select a save first")
		_play_ui(UI_SOUND_NOTIF_SHARP, -9.0)
		return
	if _save_manager == null:
		_set_status("Save system unavailable")
		return
	_prompt_name(
		"Rename Map",
		_display_name(_selected_slug),
		_finish_rename
	)


func _finish_rename(new_name: String) -> void:
	if _save_manager == null:
		return
	var renamed_slug: String = _save_manager.rename_save(_selected_slug, new_name)
	if renamed_slug.is_empty():
		_set_status("Rename failed")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return
	_selected_slug = renamed_slug
	_set_status("Renamed: " + _display_name(renamed_slug))
	_play_ui(UI_SOUND_ACCEPT, -8.0)
	_refresh_save_list()


func _on_load() -> void:
	if _selected_slug.is_empty():
		_set_status("Select a save first")
		return
	if _save_manager == null:
		_set_status("Save system unavailable")
		return
	_play_ui(UI_SOUND_ACCEPT, -7.0)
	save_loaded.emit()
	if saves_only:
		close_saves_only()
	else:
		set_paused(false)
	_save_manager.load_save(_selected_slug)


func _prompt_duplicate() -> void:
	if _selected_slug.is_empty():
		_set_status("Select a save first")
		return
	if _save_manager == null:
		_set_status("Save system unavailable")
		return
	_prompt_name(
		"Duplicate Save",
		_display_name(_selected_slug) + " Copy",
		_finish_duplicate
	)


func _finish_duplicate(new_name: String) -> void:
	if _save_manager == null:
		return
	var slug: String = _save_manager.duplicate_save(_selected_slug, new_name)
	if slug.is_empty():
		_set_status("Duplicate failed")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
		return
	_selected_slug = slug
	_set_status("Duplicated: " + _display_name(slug))
	_play_ui(UI_SOUND_DONE, -8.0)
	_refresh_save_list()


func _confirm_delete() -> void:
	if _selected_slug.is_empty():
		_set_status("Select a save first")
		return
	if _save_manager == null:
		_set_status("Save system unavailable")
		return
	_confirm(
		"Delete Save",
		"Delete \"%s\"? This cannot be undone." % _display_name(_selected_slug),
		_finish_delete
	)


func _finish_delete() -> void:
	if _save_manager == null:
		return
	if _save_manager.delete_save(_selected_slug):
		_set_status("Deleted")
		_play_ui(UI_SOUND_ACCEPT, -8.0)
	else:
		_set_status("Delete failed")
		_play_ui(UI_SOUND_NOTIF_SHARP, -8.0)
	_selected_slug = ""
	_refresh_save_list()


func _confirm_quit() -> void:
	_confirm(
		"Quit to Desktop",
		"Quit without saving?\nUnsaved changes will be lost.",
		_finish_quit,
		"Quit"
	)


func _finish_quit() -> void:
	# Drop the pause overlay and any open 2D layers before handing the tree to
	# the engine; the scene teardown itself is then the only remaining work.
	visible = false
	if _keybind_layer != null:
		_keybind_layer.queue_free()
		_keybind_layer = null
	if _dialog_layer != null:
		_dialog_layer.queue_free()
		_dialog_layer = null
	get_tree().paused = false
	get_tree().quit()


func _on_close_requested() -> void:
	if _dialog_open:
		return
	if not _paused:
		set_paused(true)
	_confirm_quit()


func _prompt_name(title: String, initial: String, callback: Callable) -> void:
	_ensure_dialog_layer()
	_dialog_open = true
	_play_ui(UI_SOUND_NOTIF, -11.0)

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.ok_button_text = "OK"
	dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	dialog.theme = _dialog_theme(16)

	var edit := LineEdit.new()
	edit.text = initial
	edit.custom_minimum_size = Vector2(380.0, 32.0)
	edit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	edit.theme = _dialog_theme(16)
	edit.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
	edit.add_theme_color_override("font_selected_color", Color(1.0, 1.0, 1.0))
	edit.add_theme_color_override("selection_color", Color(0.55, 0.40, 0.05, 0.65))
	edit.add_theme_color_override("caret_color", Color(1.0, 0.88, 0.3))
	dialog.add_child(edit)
	dialog.register_text_enter(edit)
	edit.text_changed.connect(func(_text: String) -> void:
		_play_ui(
			UI_SOUND_TYPE_0 if _ui_type_toggle else UI_SOUND_TYPE_1,
			-16.0
		)
		_ui_type_toggle = not _ui_type_toggle
	)

	_dialog_layer.add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_TYPING_FINISH, -9.0)
		var value := edit.text
		dialog.queue_free()
		callback.call(value)
	)
	dialog.canceled.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_CLICK, -11.0)
		dialog.queue_free()
	)
	dialog.popup_centered(Vector2i(440, 150))
	edit.grab_focus()
	edit.caret_column = edit.text.length()


func _prompt_text(title: String, initial: String, callback: Callable) -> void:
	_ensure_dialog_layer()
	_dialog_open = true
	_play_ui(UI_SOUND_NOTIF, -11.0)

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.ok_button_text = "Save"
	dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	dialog.theme = _dialog_theme(16)

	var edit := TextEdit.new()
	edit.text = initial
	edit.custom_minimum_size = Vector2(460, 140)
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.theme = _dialog_theme(16)
	dialog.add_child(edit)

	_dialog_layer.add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_TYPING_FINISH, -9.0)
		var value := edit.text
		dialog.queue_free()
		callback.call(value)
	)
	dialog.canceled.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_CLICK, -11.0)
		dialog.queue_free()
	)
	dialog.popup_centered(Vector2i(500, 230))
	edit.grab_focus()


func _confirm(
	title: String,
	message: String,
	callback: Callable,
	ok_text: String = "Delete"
) -> void:
	_ensure_dialog_layer()
	_dialog_open = true
	_play_ui(UI_SOUND_NOTIF, -11.0)

	var dialog := ConfirmationDialog.new()
	dialog.title = title
	dialog.dialog_text = message
	dialog.ok_button_text = ok_text
	dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	dialog.theme = _dialog_theme(16)
	_dialog_layer.add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_ACCEPT, -8.0)
		dialog.queue_free()
		callback.call()
	)
	dialog.canceled.connect(func() -> void:
		_dialog_open = false
		_play_ui(UI_SOUND_CLICK, -11.0)
		dialog.queue_free()
	)
	dialog.popup_centered(Vector2i(440, 160))


func _ensure_dialog_layer() -> void:
	if _dialog_layer != null and is_instance_valid(_dialog_layer):
		return
	_dialog_layer = CanvasLayer.new()
	_dialog_layer.name = "Dialogs"
	_dialog_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_dialog_layer)


func _dialog_theme(font_size: int = 16) -> Theme:
	var theme := Theme.new()
	theme.default_font = UI_FONT
	theme.default_font_size = font_size
	theme.default_base_scale = 1.0
	return theme


# ---------------------------------------------------------------------------
# Export defaults (Settings > Gameplay)
# ---------------------------------------------------------------------------

func _open_export_defaults() -> void:
	_ensure_defaults_layer()
	_sync_export_defaults_fields()
	_defaults_layer.visible = true
	_play_ui(UI_SOUND_TRANSITION, -10.0)


func _ensure_defaults_layer() -> void:
	if _defaults_layer != null and is_instance_valid(_defaults_layer):
		return

	_defaults_layer = CanvasLayer.new()
	_defaults_layer.name = "ExportDefaults"
	_defaults_layer.layer = 24
	_defaults_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_defaults_layer)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.02, 0.74)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_defaults_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_defaults_layer.add_child(center)

	var view := get_viewport().get_visible_rect().size
	var panel := PanelContainer.new()
	panel.theme = _dialog_theme(15)
	panel.custom_minimum_size = Vector2(
		minf(780.0, view.x * 0.92),
		minf(620.0, view.y * 0.88)
	)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	var title := Label.new()
	title.text = "SIMULATION DEFAULTS"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.32))
	column.add_child(title)

	var info := Label.new()
	info.text = (
		"New saves start from these values. An existing save keeps the exports "
		+ "stored in its own save file, so changing a default does not rewrite it."
	)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 14)
	info.add_theme_color_override("font_color", Color(0.75, 0.75, 0.7))
	column.add_child(info)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 6)
	scroll.add_child(content)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	content.add_child(grid)

	_defaults_cap = _defaults_spin(grid, "Active Cap", 1, 100000, 1)
	_defaults_quota = _defaults_spin(grid, "Spawn Quota", -1, 100000, 1)
	_defaults_seed = _defaults_spin(grid, "Seed", 0, 2147483647, 1)

	_defaults_evac = _defaults_check(grid, "Evacuation Mode")
	_defaults_record = _defaults_check(grid, "Record On Start")

	_defaults_cap.value_changed.connect(func(_v: float) -> void: _save_global_defaults())
	_defaults_quota.value_changed.connect(func(_v: float) -> void: _save_global_defaults())
	_defaults_seed.value_changed.connect(func(_v: float) -> void: _save_global_defaults())
	_defaults_evac.toggled.connect(func(_v: bool) -> void: _save_global_defaults())
	_defaults_record.toggled.connect(func(_v: bool) -> void: _save_global_defaults())

	var separator := HSeparator.new()
	content.add_child(separator)

	var agent_info := Label.new()
	agent_info.text = (
		"Simulation defaults are the runtime exports new saves start from: "
		+ "active cap, spawn quota, seed, evacuation/recording flags, Random "
		+ "Populate, optimizer and the Member properties below. "
		+ "Use Current Session captures all of them at once."
	)
	agent_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	agent_info.add_theme_font_size_override("font_size", 13)
	agent_info.add_theme_color_override("font_color", Color(0.75, 0.75, 0.7))
	content.add_child(agent_info)

	var agent_scene: PackedScene = load("res://scenes/inventory/AgentPanel.tscn")
	_defaults_agent_panel = agent_scene.instantiate()
	_defaults_agent_panel.set("defaults_mode", true)
	_defaults_agent_panel.custom_minimum_size = Vector2(0, 340)
	_defaults_agent_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_defaults_agent_panel)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 8)
	column.add_child(actions)

	var capture := Button.new()
	capture.text = "Use Current Session"
	capture.pressed.connect(_capture_export_defaults)
	actions.add_child(capture)

	var reset := Button.new()
	reset.text = "Reset All Defaults"
	reset.pressed.connect(_reset_export_defaults)
	actions.add_child(reset)

	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func() -> void: _defaults_layer.visible = false)
	actions.add_child(close)


func _defaults_spin(
	grid: GridContainer, label_text: String, minimum: float,
	maximum: float, step: float
) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 14)
	grid.add_child(label)

	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.allow_greater = true
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(spin)
	return spin


func _defaults_check(grid: GridContainer, label_text: String) -> CheckBox:
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 14)
	grid.add_child(label)

	var check := CheckBox.new()
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(check)
	return check


func _sync_export_defaults_fields() -> void:
	if _defaults_cap == null:
		return

	_defaults_cap.set_value_no_signal(
		float(
			RuntimeExports.get_default(
				"global", "global_unit_cap", GlobalData.global_unit_cap
			)
		)
	)
	_defaults_quota.set_value_no_signal(
		float(
			RuntimeExports.get_default(
				"global", "global_spawn_quota", GlobalData.global_spawn_quota
			)
		)
	)
	_defaults_seed.set_value_no_signal(
		float(RuntimeExports.get_default("global", "rng_seed", GlobalData.rng_seed))
	)
	_defaults_evac.set_pressed_no_signal(
		bool(
			RuntimeExports.get_default(
				"global", "evacuation_mode", GlobalData.evacuation_mode
			)
		)
	)
	_defaults_record.set_pressed_no_signal(
		bool(
			RuntimeExports.get_default(
				"global",
				"recording_enabled",
				SimRecorder.recording_enabled
			)
		)
	)

	if (
		_defaults_agent_panel != null
		and _defaults_agent_panel.has_method("rebuild")
	):
		_defaults_agent_panel.call("rebuild")


func _save_global_defaults() -> void:
	if _defaults_cap == null:
		return

	RuntimeExports.set_default(
		"global", "global_unit_cap", int(_defaults_cap.value)
	)
	RuntimeExports.set_default(
		"global", "global_spawn_quota", int(_defaults_quota.value)
	)
	RuntimeExports.set_default("global", "rng_seed", int(_defaults_seed.value))
	RuntimeExports.set_default(
		"global", "evacuation_mode", _defaults_evac.button_pressed
	)
	RuntimeExports.set_default(
		"global", "recording_enabled", _defaults_record.button_pressed
	)


func _reset_export_defaults() -> void:
	RuntimeExports.clear_all_defaults()
	_sync_export_defaults_fields()
	_play_ui(UI_SOUND_ACCEPT, -9.0)


func _capture_export_defaults() -> void:
	RuntimeExports.save_live_as_defaults()
	_sync_export_defaults_fields()
	_play_ui(UI_SOUND_ACCEPT, -9.0)
