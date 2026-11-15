extends Control

## Consul's dialogue view. Slides him in from the right, uses his own Textbox
## art for speech and choices, and forwards lines through DialogueManager.

const EMOTE_BY_NAME := {
	"neutral": ConsulCharacter.Emotion.NEUTRAL,
	"happy": ConsulCharacter.Emotion.HAPPY,
	"angry": ConsulCharacter.Emotion.ANGRY,
	"sad": ConsulCharacter.Emotion.SAD,
	"surprised": ConsulCharacter.Emotion.SURPRISED,
	"sleepy": ConsulCharacter.Emotion.SLEEPY,
	"scared": ConsulCharacter.Emotion.SCARED,
	"suspicious": ConsulCharacter.Emotion.SUSPICIOUS,
	"excited": ConsulCharacter.Emotion.EXCITED,
	"bored": ConsulCharacter.Emotion.BORED,
}

const GESTURE_BY_NAME := {
	"fist_rest": ConsulCharacter.HandGesture.FIST_REST,
	"fist": ConsulCharacter.HandGesture.FIST,
	"point_side": ConsulCharacter.HandGesture.POINT_SIDE,
	"point_up": ConsulCharacter.HandGesture.POINT_UP,
	"okay": ConsulCharacter.HandGesture.OKAY,
	"palm_explain": ConsulCharacter.HandGesture.PALM_EXPLAIN,
	"palm_falter": ConsulCharacter.HandGesture.PALM_FALTER,
	"palm_jazzed": ConsulCharacter.HandGesture.PALM_JAZZED,
	"palm_stern": ConsulCharacter.HandGesture.PALM_STERN,
}

const INTRO_PATH := "res://resources/dialogue/consul_intro.json"
const DIALOGUE_FONT: Font = preload("res://font/7-12-serif.otf")

const ARRIVAL_SOUND: AudioStream = preload("res://sounds/consul/arrival_intro.mp3")
const TALK_BLIP_SOUND: AudioStream = preload("res://sounds/consul/consul_talk_blip.mp3")
const EXIT_SOUND: AudioStream = preload("res://sounds/consul/exit_click.mp3")

## Undertale-style reveal: characters appear one by one with a short voice blip.
const TYPE_SPEED := 34.0
const BLIP_INTERVAL := 0.01
const COMMA_PAUSE := 0.09
const SENTENCE_PAUSE := 0.18

@onready var consul: ConsulCharacter = $Consul
@onready var textbox: Control = $Consul/Textbox
@onready var dialogue_manager: DialogueManager = $DialogueManager

var _home: Vector2 = Vector2.ZERO
var _offscreen: Vector2 = Vector2.ZERO
var _active: bool = false
var _waving: bool = false
var _pop_tween: Tween
var _text: RichTextLabel
var _buttons: HBoxContainer
var _bell: Node = null
var _voice_players: Array[AudioStreamPlayer] = []
var _voice_index: int = 0
var _blip_player: AudioStreamPlayer
var _typing: bool = false
var _reveal_chars: float = 0.0
var _reveal_target: int = 0
var _reveal_delay: float = 0.0
var _blip_cooldown: float = 0.0
var _on_reveal_done: Callable = Callable()


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	consul.visible = false
	consul.set_process(false)
	consul.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if consul.default_gaze_target == Vector2.ZERO:
		consul.default_gaze_target = get_viewport_rect().size * 0.5

	var viewport: Vector2 = get_viewport_rect().size
	_home = Vector2(viewport.x - 170.0, viewport.y * 0.56)
	_offscreen = Vector2(viewport.x + 260.0, _home.y)
	consul.position = _offscreen

	if textbox != null:
		textbox.visible = false
		textbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_build_textbox_ui()

	_connect_manager()
	_setup_audio()

	var parent := get_parent()
	if parent != null:
		var inventory := parent.get_node_or_null("Inventory") as Control
		if inventory != null:
			inventory.visibility_changed.connect(
				_on_inventory_visibility_changed
			)

		_bell = parent.get_node_or_null("ConsulBell")
		if _bell != null and _bell.has_signal("called"):
			_bell.connect(&"called", _on_bell_called)


func _setup_audio() -> void:
	for index in 4:
		var player := AudioStreamPlayer.new()
		player.name = "ConsulVoice%d" % index
		player.bus = &"Master"
		add_child(player)
		_voice_players.append(player)

	# Dedicated voice channel for the typewriter. Calling play() on an already
	# playing stream restarts it, so rapid calls only ever emit the first few
	# milliseconds of the blip - the Undertale-style short "voice" tick.
	_blip_player = AudioStreamPlayer.new()
	_blip_player.name = "ConsulBlip"
	_blip_player.bus = &"Master"
	_blip_player.stream = TALK_BLIP_SOUND
	_blip_player.volume_db = -17.0
	add_child(_blip_player)


func _play_sound(
	stream: AudioStream,
	volume_db: float = -8.0,
	pitch: float = 1.0
) -> void:
	if stream == null or _voice_players.is_empty():
		return

	var player := _voice_players[_voice_index]
	_voice_index = (_voice_index + 1) % _voice_players.size()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.play()


## One short vocalisation per spoken line. The blip is pitched a little
## differently each time so repeat lines do not sound mechanical.
func _play_talk_blip() -> void:
	if _blip_player == null:
		return

	_blip_player.pitch_scale = randf_range(0.88, 1.16)
	_blip_player.play()


func _stop_voices() -> void:
	for player in _voice_players:
		player.stop()
	if _blip_player != null:
		_blip_player.stop()


func _process(delta: float) -> void:
	if _typing:
		_advance_reveal(delta)


func _input(event: InputEvent) -> void:
	if not _active or not _typing:
		return
	if event.is_action_pressed("ui_accept"):
		_skip_typing()
		get_viewport().set_input_as_handled()


func _advance_reveal(delta: float) -> void:
	if _text == null:
		_finish_reveal()
		return

	if _reveal_delay > 0.0:
		_reveal_delay = maxf(_reveal_delay - delta, 0.0)
		return

	var previous: int = _text.visible_characters
	_reveal_chars += TYPE_SPEED * delta
	var next: int = mini(int(_reveal_chars), _reveal_target)
	if next <= previous:
		return

	var text := _text.text
	var blipped := false
	var sentence_pause := false
	var comma_pause := false

	for index in range(previous, next):
		if index < 0 or index >= text.length():
			continue
		var character := text[index]
		if character == " " or character == "\n" or character == "\t":
			continue
		blipped = true
		match character:
			".", "!", "?":
				sentence_pause = true
			",", ";", ":":
				comma_pause = true

	if blipped:
		_blip_cooldown -= delta
		if _blip_cooldown <= 0.0:
			_play_talk_blip()
			_blip_cooldown = BLIP_INTERVAL

	_text.visible_characters = next

	if sentence_pause:
		_reveal_delay = maxf(_reveal_delay, SENTENCE_PAUSE)
	elif comma_pause:
		_reveal_delay = maxf(_reveal_delay, COMMA_PAUSE)

	if next >= _reveal_target:
		_finish_reveal()


## Reveals the rest of the line immediately. Returns true if text was typing.
func _skip_typing() -> bool:
	if not _typing:
		return false

	_reveal_chars = float(_reveal_target)
	_finish_reveal()
	return true


func _finish_reveal() -> void:
	if not _typing and _on_reveal_done.is_null():
		return

	_typing = false
	_reveal_delay = 0.0
	if _text != null:
		_text.visible_characters = -1
	if _blip_player != null:
		_blip_player.stop()

	var callback := _on_reveal_done
	_on_reveal_done = Callable()
	if callback.is_valid():
		callback.call()


func _stop_typing() -> void:
	_typing = false
	_on_reveal_done = Callable()
	_reveal_delay = 0.0
	if _blip_player != null:
		_blip_player.stop()


func _on_textbox_gui_input(event: InputEvent) -> void:
	if not _typing:
		return

	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			_skip_typing()
			accept_event()


func _build_textbox_ui() -> void:
	var margin := MarginContainer.new()
	margin.position = Vector2(-125.0, -78.0)
	margin.size = Vector2(250.0, 156.0)
	margin.z_index = 10
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.gui_input.connect(_on_textbox_gui_input)
	textbox.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)

	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.custom_minimum_size = Vector2(234.0, 80.0)
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_size_override("normal_font_size", 16)
	for font_name in [
		"normal_font",
		"bold_font",
		"italics_font",
		"bold_italics_font",
		"mono_font",
	]:
		_text.add_theme_font_override(font_name, DIALOGUE_FONT)
	_text.add_theme_color_override(
		"default_color",
		Color(0.06, 0.07, 0.09)
	)
	column.add_child(_text)

	_buttons = HBoxContainer.new()
	_buttons.alignment = BoxContainer.ALIGNMENT_END
	_buttons.add_theme_constant_override("separation", 8)
	column.add_child(_buttons)


func _connect_manager() -> void:
	dialogue_manager.say_requested.connect(_on_say_requested)
	dialogue_manager.choice_requested.connect(_on_choice_requested)
	dialogue_manager.emote_requested.connect(_on_emote_requested)
	dialogue_manager.gesture_requested.connect(_on_gesture_requested)
	dialogue_manager.move_requested.connect(_on_move_requested)
	dialogue_manager.point_requested.connect(_on_point_requested)
	dialogue_manager.wave_requested.connect(_on_wave_requested)
	dialogue_manager.gaze_requested.connect(_on_gaze_requested)
	dialogue_manager.finished.connect(_on_finished)


func _on_inventory_visibility_changed() -> void:
	var parent := get_parent()
	if parent == null:
		return

	var inventory := parent.get_node_or_null("Inventory") as Control
	if inventory == null:
		return

	# Opening the inventory no longer calls Consul in. It only rings the bell in
	# the top-right corner; the player presses the bell to summon him.
	if inventory.visible and _bell != null:
		_bell.call(&"appear_and_shake")


func _on_bell_called() -> void:
	summon()


## Summons Consul for the player: the intro the first time, a short "you rang"
## line afterwards. Safe to call while he is already on screen.
func summon() -> void:
	if _active:
		consul.bounce(3.0, 0.3)
		return

	if dialogue_manager.check_condition({"not_flag": "consul_intro_seen"}):
		start_intro()
	else:
		start_recall()


func start_intro() -> void:
	if _active:
		return
	if not dialogue_manager.check_condition({"not_flag": "consul_intro_seen"}):
		return

	dialogue_manager.set_flag("consul_intro_seen", true)
	_begin_appearance(_start_dialogue)


func start_recall() -> void:
	if _active:
		return

	var steps := [
		{
			"gaze": "cursor",
			"gaze_radius": 700.0,
			"say": (
				"You rang? The inventory is yours to arrange. "
				+ "Press {console} whenever you need me."
			),
			"button": "Thanks",
			"emote": "happy",
			"gesture": "palm_explain",
		},
		{"end": true},
	]
	_begin_appearance(func() -> void: dialogue_manager.start(steps))


func _begin_appearance(after_pop_in: Callable) -> void:
	_active = true
	_waving = false
	_play_sound(ARRIVAL_SOUND, -6.0)

	visible = true
	consul.visible = true
	consul.set_process(true)
	consul.position = _offscreen
	consul.clear_point()

	if textbox != null:
		textbox.visible = true
		textbox.modulate.a = 1.0

	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()

	_pop_tween = create_tween()
	_pop_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pop_tween.tween_property(consul, "position", _home, 0.55)
	_pop_tween.tween_callback(after_pop_in)


func _start_dialogue() -> void:
	if dialogue_manager.start_from_file(INTRO_PATH):
		return

	var fallback := _build_intro()
	dialogue_manager.start(fallback)
	dialogue_manager.save_dialogue(INTRO_PATH, fallback)


## Writes the built-in intro back out as JSON.
func save_intro_json() -> bool:
	return dialogue_manager.save_dialogue(INTRO_PATH, _build_intro())


func _build_intro() -> Array:
	return [
		{
			"gaze": "cursor",
			"gaze_radius": 700.0,
			"choice": [
				{"text": "Yes", "goto": "help"},
				{"text": "No", "goto": "bye"},
			],
			"text": (
				"Hey, I'm Consul. It looks like you're new around here."
				+ "\nNeed any help?"
			),
			"emote": "neutral",
			"gesture": "fist_rest",
		},
		{"label": "help"},
		{
			"say": (
				"Alright! Open the console by pressing {console}. "
				+ "You can see statistics with {statistics} "
				+ "and results with {results}."
			),
			"button": "Got it",
			"emote": "happy",
			"gesture": "palm_explain",
		},
		{"end": true},
		{"label": "bye"},
		{"gesture": "palm_explain", "wave": true},
		{"end": true},
	]


func _action_key(action: StringName) -> String:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return _format_key(event as InputEventKey)

	return String(action).capitalize()


func _format_key(event: InputEventKey) -> String:
	var parts: Array[String] = []

	if event.ctrl_pressed:
		parts.append("Ctrl")
	if event.alt_pressed:
		parts.append("Alt")
	if event.shift_pressed:
		parts.append("Shift")

	var key_name := OS.get_keycode_string(event.physical_keycode)
	match key_name:
		"Slash":
			key_name = "/"
		"Backslash":
			key_name = "\\"
		"Period":
			key_name = "."
		"Comma":
			key_name = ","
		"Semicolon":
			key_name = ";"
		"Apostrophe":
			key_name = "'"
		"BracketLeft":
			key_name = "["
		"BracketRight":
			key_name = "]"
		"Minus":
			key_name = "-"
		"Equal":
			key_name = "="
		"Backquote":
			key_name = "`"

	parts.append(key_name)
	return "+".join(parts)


func _on_say_requested(text: String, button_text: String) -> void:
	_show_text(text)
	_set_buttons([
		{"text": button_text, "callback": _on_continue_pressed},
	])
	consul.bounce(3.0, 0.3)


func _on_choice_requested(prompt: String, options: Array) -> void:
	_clear_buttons()
	_show_text(prompt, func() -> void: _build_choice_buttons(options))
	consul.bounce(3.0, 0.3)


## Choices stay hidden until the prompt finishes typing, like Undertale.
func _build_choice_buttons(options: Array) -> void:
	if _buttons == null:
		return

	_clear_buttons()
	for option_index in options.size():
		var option: Dictionary = options[option_index]
		var button := Button.new()
		button.text = String(option.get("text", "..."))
		button.custom_minimum_size = Vector2(70.0, 28.0)
		button.add_theme_font_size_override("font_size", 16)
		button.add_theme_font_override("font", DIALOGUE_FONT)
		button.pressed.connect(_on_choice_pressed.bind(option_index))
		_buttons.add_child(button)


func _on_continue_pressed() -> void:
	# First press while the line is still typing reveals it; the next press
	# advances, matching the Undertale confirm behaviour.
	if _skip_typing():
		return

	_disable_buttons()
	dialogue_manager.advance()


func _on_choice_pressed(option_index: int) -> void:
	_disable_buttons()
	dialogue_manager.choose(option_index)


func _on_emote_requested(emote: String) -> void:
	consul.emotion = EMOTE_BY_NAME.get(
		emote,
		ConsulCharacter.Emotion.NEUTRAL
	)


func _on_gesture_requested(gesture: String, hand: int) -> void:
	var value = GESTURE_BY_NAME.get(
		gesture,
		ConsulCharacter.HandGesture.FIST_REST
	)

	if hand == 0:
		consul.left_hand_gesture = value
	elif hand == 1:
		consul.right_hand_gesture = value
	else:
		consul.set_hand_gestures(value, value)


func _on_gaze_requested(mode: String, target: Variant, radius: float) -> void:
	var resolved: Variant = _resolve_gaze_target(target)

	match mode:
		"auto":
			consul.set_gaze_auto()
		"random":
			consul.set_gaze_random()
		"cursor":
			_apply_gaze_default(resolved)
			consul.set_gaze_cursor(radius)
		"default":
			_apply_gaze_default(resolved)
			consul.set_gaze_default_mode()
		"target":
			if resolved is Node:
				consul.set_gaze_target_node(resolved)
			elif resolved is Vector2:
				consul.set_gaze_target_position(resolved)


func _apply_gaze_default(value: Variant) -> void:
	if value is Node:
		consul.set_gaze_default_node(value)
	elif value is Vector2:
		consul.set_gaze_default_position(value)


func _resolve_gaze_target(value: Variant) -> Variant:
	if value == null:
		return null
	if value is NodePath:
		return _resolve_node(value)
	if value is Node or value is Vector2:
		return value
	return null


func _on_move_requested(target: NodePath, offset: Vector2) -> void:
	var node := _resolve_node(target)
	if node == null:
		dialogue_manager.advance()
		return

	consul.move_toward_node(node, offset, 0.55)
	await get_tree().create_timer(0.6).timeout
	dialogue_manager.advance()


func _on_point_requested(target: NodePath) -> void:
	var node := _resolve_node(target)
	if node == null:
		dialogue_manager.advance()
		return

	consul.point_at_node(node)
	await get_tree().create_timer(0.7).timeout
	consul.clear_point()
	dialogue_manager.advance()


func _on_wave_requested() -> void:
	_waving = true
	consul.wave_goodbye(0.9)


func _on_finished() -> void:
	if _waving:
		_waving = false
		await get_tree().create_timer(0.9).timeout

	_pop_out()


func _pop_out() -> void:
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()

	_stop_typing()
	_stop_voices()
	_play_sound(EXIT_SOUND, -8.0)
	if textbox != null:
		textbox.visible = false
	_pop_tween = create_tween()
	_pop_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_pop_tween.tween_property(consul, "position", _offscreen, 0.5)
	_pop_tween.tween_callback(_finish_pop_out)


func _finish_pop_out() -> void:
	consul.visible = false
	consul.set_process(false)
	visible = false
	_active = false


func _dismiss() -> void:
	dialogue_manager.stop()
	_waving = false
	_stop_typing()
	_stop_voices()
	_play_sound(EXIT_SOUND, -8.0)

	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()

	if textbox != null:
		textbox.visible = false
	consul.visible = false
	consul.set_process(false)
	consul.position = _offscreen
	visible = false
	_active = false


func _show_text(text: String, on_done: Callable = Callable()) -> void:
	var formatted := text
	formatted = formatted.replace(
		"{console}",
		_action_key("ui_console_toggle")
	)
	formatted = formatted.replace(
		"{statistics}",
		_action_key("ui_statistics_toggle")
	)
	formatted = formatted.replace(
		"{results}",
		_action_key("ui_results_toggle")
	)

	if _text != null:
		_text.text = formatted
		_text.visible_characters = 0

	if textbox != null:
		textbox.visible = true

	_reveal_chars = 0.0
	_reveal_target = _text.get_total_character_count() if _text != null else 0
	_reveal_delay = 0.0
	_blip_cooldown = 0.0
	_on_reveal_done = on_done
	_typing = _reveal_target > 0

	if not _typing:
		_finish_reveal()


func _set_buttons(entries: Array) -> void:
	if _buttons == null:
		return

	_clear_buttons()

	for entry: Dictionary in entries:
		var button := Button.new()
		button.text = String(entry["text"])
		button.custom_minimum_size = Vector2(70.0, 28.0)
		button.add_theme_font_size_override("font_size", 16)
		button.add_theme_font_override("font", DIALOGUE_FONT)
		var callback: Callable = entry["callback"]
		button.pressed.connect(callback)
		_buttons.add_child(button)


func _clear_buttons() -> void:
	if _buttons == null:
		return

	for child in _buttons.get_children():
		_buttons.remove_child(child)
		child.queue_free()


func _disable_buttons() -> void:
	if _buttons == null:
		return

	for child in _buttons.get_children():
		if child is Button:
			(child as Button).disabled = true


func _resolve_node(path: NodePath) -> Node:
	var node := get_node_or_null(path)
	if node != null:
		return node

	var scene := get_tree().current_scene
	if scene != null:
		return scene.get_node_or_null(path)

	return null
