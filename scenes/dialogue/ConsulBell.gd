extends TextureButton

## Pixel bell in the top-right corner. It stays hidden until the inventory is
## opened for the first time, shakes to announce itself (and again on later
## inventory opens), and never hides once it has appeared. Pressing it asks
## ConsulDialogue to summon Consul.

signal called

const JIGGLE_1: AudioStream = preload("res://sounds/consul/bell_jiggle_1.mp3")
const JIGGLE_2: AudioStream = preload("res://sounds/consul/bell_jiggle_2.mp3")
const DING: AudioStream = preload("res://sounds/consul/bell_call_ding.mp3")

const SHAKE_ANGLES: Array[float] = [12.0, -9.0, 7.0, -5.0, 3.0, -1.5, 0.0]
const SHAKE_STEP := 0.065

var _shown: bool = false
var _shake_tween: Tween
var _pop_tween: Tween
var _ding_player: AudioStreamPlayer
var _jiggle_player: AudioStreamPlayer
var _jiggle_index: int = 0


func _ready() -> void:
	visible = false
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "Ring for Consul"
	pressed.connect(_on_pressed)

	_ding_player = _make_player("BellDing")
	_jiggle_player = _make_player("BellJiggle")


func _make_player(player_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.bus = &"Master"
	player.volume_db = -8.0
	add_child(player)
	return player


## Called whenever the inventory opens. The first call reveals the bell; every
## call makes it swing so it reads as a "ring for Consul" affordance.
func appear_and_shake() -> void:
	var reveals := not _shown

	if reveals:
		_shown = true
		visible = true
		modulate.a = 0.0
		scale = Vector2(0.65, 0.65)
		pivot_offset = Vector2(size.x * 0.5, 2.0)
		_play_pop_in()
	else:
		pivot_offset = Vector2(size.x * 0.5, 2.0)

	_shake(true)


func _play_pop_in() -> void:
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()

	_pop_tween = create_tween()
	_pop_tween.set_parallel(true)
	_pop_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pop_tween.tween_property(self, "modulate:a", 1.0, 0.2)
	_pop_tween.tween_property(self, "scale", Vector2.ONE, 0.35)


func _shake(with_sound: bool) -> void:
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()

	rotation_degrees = 0.0
	_shake_tween = create_tween()
	for angle in SHAKE_ANGLES:
		_shake_tween.tween_property(
			self, "rotation_degrees", angle, SHAKE_STEP
		).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	if with_sound:
		_play_jiggle()


func _play_jiggle() -> void:
	if _jiggle_player == null:
		return

	_jiggle_player.stream = JIGGLE_1 if _jiggle_index % 2 == 0 else JIGGLE_2
	_jiggle_index += 1
	_jiggle_player.volume_db = -10.0
	_jiggle_player.pitch_scale = randf_range(0.96, 1.05)
	_jiggle_player.play()


func _on_pressed() -> void:
	if _ding_player != null:
		_ding_player.stream = DING
		_ding_player.volume_db = -5.0
		_ding_player.pitch_scale = 1.0
		_ding_player.play()

	_shake(false)
	called.emit()
