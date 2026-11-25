extends Control

## Top-left BGM credit pop-up. Listens to MusicManager, slides in from the
## left corner, scrolls the title, and slides back out after a short dwell.
## Deliberately small and slightly translucent so it never fights the HUD.

const REST_POSITION: Vector2 = Vector2.ZERO
const POPUP_SIZE: Vector2 = Vector2(268.0, 66.0)
const SLIDE_OFFSET: float = 12.0
const HOLD_SECONDS: float = 8.0
const FADE_IN: float = 0.42
const FADE_OUT: float = 0.38

const MARQUEE_SPEED: float = 38.0
const MARQUEE_DELAY: float = 1.3
const MARQUEE_END_HOLD: float = 1.0

const MIN_FONT_SIZE: int = 16

const PIXEL_FONT: Font = preload("res://font/Pixelta.ttf")
const BODY_FONT: Font = preload("res://font/dogicapixel.ttf")
const ICON_TEXTURE: Texture2D = preload("res://textures/particles/sound_visual.png")

const GOLD := Color(1.0, 0.84, 0.32, 1.0)
const MUTED := Color(0.62, 0.68, 0.78, 1.0)

@onready var _panel: Control = $Panel
@onready var _icon: TextureRect = $Panel/Margin/Row/Icon
@onready var _title_clip: Control = $Panel/Margin/Row/Text/TitleClip
@onready var _title: Label = $Panel/Margin/Row/Text/TitleClip/Title
@onready var _creator: Label = $Panel/Margin/Row/Text/CreatorClip/Creator

var _slide_tween: Tween = null
var _show_id: int = 0
var _last_source: String = ""
var _marquee_time: float = 0.0
var _marquee_distance: float = 0.0
var _marquee_active: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = POPUP_SIZE
	position = Vector2(-size.x - SLIDE_OFFSET, REST_POSITION.y)
	modulate.a = 0.0
	visible = false

	_apply_style()

	var music := get_node_or_null("/root/MusicManager")
	if music != null:
		if music.has_signal("track_changed"):
			music.track_changed.connect(_on_track_changed)
		if music.has_signal("playback_stopped"):
			music.playback_stopped.connect(_on_playback_stopped)

		if music.has_method("is_playing") and music.is_playing():
			_on_track_changed(music.get_current_track())


func _process(delta: float) -> void:
	if not _marquee_active:
		return

	_marquee_time += delta

	var travel_time: float = _marquee_distance / MARQUEE_SPEED
	var cycle: float = MARQUEE_DELAY + travel_time + MARQUEE_END_HOLD
	var local_time: float = fmod(_marquee_time, cycle)

	if local_time <= MARQUEE_DELAY:
		_title.position.x = 0.0
	elif local_time <= MARQUEE_DELAY + travel_time:
		_title.position.x = -(local_time - MARQUEE_DELAY) * MARQUEE_SPEED
	else:
		_title.position.x = -_marquee_distance


func _apply_style() -> void:
	if _panel != null:
		_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_icon.texture = ICON_TEXTURE
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	_title.add_theme_font_override("font", BODY_FONT)
	_title.add_theme_font_size_override("font_size", MIN_FONT_SIZE)
	_title.add_theme_color_override("font_color", GOLD)
	_title.position = Vector2.ZERO

	_creator.add_theme_font_override("font", BODY_FONT)
	_creator.add_theme_font_size_override("font_size", MIN_FONT_SIZE)
	_creator.add_theme_color_override("font_color", MUTED)


func _on_track_changed(track: Dictionary) -> void:
	var source := String(track.get("source", "")).strip_edges()

	# The same track can be re-broadcast (playlist re-request, scene reload).
	# Only announce it once; it should not pop up again on its own.
	if not source.is_empty() and source == _last_source:
		return

	_last_source = source

	var title := String(track.get("title", "Unknown track")).strip_edges()
	if title.is_empty():
		title = "Unknown track"

	var artist := String(track.get("artist", "")).strip_edges()
	_title.text = title
	_creator.text = "by " + artist if not artist.is_empty() else ""

	_reveal()
	_setup_marquee.call_deferred()


func _on_playback_stopped() -> void:
	_last_source = ""
	_show_id += 1
	_hide()


func _reveal() -> void:
	_show_id += 1
	var request_id := _show_id
	_kill_slide()

	visible = true
	modulate.a = 0.0
	position = Vector2(-size.x - SLIDE_OFFSET, REST_POSITION.y)

	_slide_tween = create_tween().set_parallel(true)
	_slide_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide_tween.tween_property(self, "position:x", REST_POSITION.x, FADE_IN)
	_slide_tween.tween_property(self, "modulate:a", 1.0, FADE_IN * 0.72)

	await get_tree().create_timer(HOLD_SECONDS).timeout

	if request_id == _show_id:
		_hide()


func _hide() -> void:
	if not visible:
		return

	_marquee_active = false
	_kill_slide()

	_slide_tween = create_tween().set_parallel(true)
	_slide_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_slide_tween.tween_property(
		self,
		"position:x",
		-size.x - SLIDE_OFFSET,
		FADE_OUT
	)
	_slide_tween.tween_property(self, "modulate:a", 0.0, FADE_OUT * 0.8)
	_slide_tween.chain().tween_callback(func() -> void:
		visible = false
	)


func _kill_slide() -> void:
	if is_instance_valid(_slide_tween):
		_slide_tween.kill()
		_slide_tween = null


func _setup_marquee() -> void:
	if not is_inside_tree() or _title == null:
		return

	# Wait for the container layout so the clip width is the real one.
	await get_tree().process_frame

	if not is_inside_tree() or _title == null:
		return

	var font: Font = _title.get_theme_font("font")
	if font == null:
		font = BODY_FONT

	var font_size: int = maxi(_title.get_theme_font_size("font_size"), MIN_FONT_SIZE)
	var text_width: float = font.get_string_size(
		_title.text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size
	).x
	var clip_width: float = _title_clip.size.x

	if clip_width <= 1.0:
		clip_width = _title_clip.custom_minimum_size.x

	_title.position.x = 0.0
	_marquee_time = 0.0

	var distance: float = text_width - clip_width

	if distance <= 2.0:
		_marquee_distance = 0.0
		_marquee_active = false
		return

	_marquee_distance = distance
	_marquee_active = true
