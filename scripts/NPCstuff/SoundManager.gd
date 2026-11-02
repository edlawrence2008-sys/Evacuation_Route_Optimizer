extends Node3D
class_name SoundManager

# ============================================================
# ENUMS
# ============================================================

enum FootstepStyle { SQUISHY, SQUEAKY }
enum VoiceProfile { TV, SAX }

# ============================================================
# EXPORTS
# ============================================================

@export_group("Global Footstep Settings")
@export var footstep_style: FootstepStyle = FootstepStyle.SQUISHY
@export var base_footstep_volume_db: float = -1.0
@export var footstep_min_speed_ratio: float = 0.01

@export_group("Footstep Style — Squishy")
@export var squishy_steps: Array[AudioStream] = []
@export var squishy_volume_offset_db: float = 0.0
@export var squishy_pitch_variance: float = 0.08
@export var squishy_sequential: bool = false

@export_group("Footstep Style — Squeaky")
@export var squeaky_steps: Array[AudioStream] = []
@export var squeaky_volume_offset_db: float = 0.0
@export var squeaky_pitch_variance: float = 0.05
@export var squeaky_sequential: bool = true

@export_group("Class Attack Sounds — Rock")
@export var rock_attack_sounds: Array[AudioStream] = []
@export var rock_attack_volume_offset_db: float = 0.0
@export var rock_attack_pitch_variance: float = 0.05
@export var rock_attack_sequential: bool = false

@export_group("Class Attack Sounds — Paper")
@export var paper_attack_sounds: Array[AudioStream] = []
@export var paper_attack_volume_offset_db: float = 0.0
@export var paper_attack_pitch_variance: float = 0.05
@export var paper_attack_sequential: bool = false

@export_group("Class Attack Sounds — Scissors")
@export var scissors_attack_sounds: Array[AudioStream] = []
@export var scissors_attack_volume_offset_db: float = 0.0
@export var scissors_attack_pitch_variance: float = 0.05
@export var scissors_attack_sequential: bool = false

@export_group("Class Attack Sounds — Gun")
@export var gun_attack_sounds: Array[AudioStream] = []
@export var gun_attack_volume_offset_db: float = 0.0
@export var gun_attack_pitch_variance: float = 0.02
@export var gun_attack_sequential: bool = false

@export_group("Voice Profiles — TV Group")
@export var tv_talk_sounds: Array[AudioStream] = []
@export var tv_track_sounds: Array[AudioStream] = []
@export var tv_retreat_sounds: Array[AudioStream] = []
@export var tv_charge_sounds: Array[AudioStream] = []
@export var tv_hurt_sounds: Array[AudioStream] = []
@export var tv_volume_offset_db: float = 0.0
@export var tv_pitch_variance: float = 0.12
## TV ONLY: The chance (0.0 to 1.0) that triggering a talk sound creates a multi-sound sentence chain.
@export var tv_combo_chance: float = 0.3
## TV ONLY: Minimum consecutive clips to play back-to-back in a rapid talk combo.
@export var tv_min_combo_sounds: int = 2
## TV ONLY: Maximum consecutive clips to play back-to-back in a rapid talk combo.
@export var tv_max_combo_sounds: int = 5
## TV ONLY: Delay spacing range (in seconds) between items parsing inside a TV combo chain.
@export var tv_combo_delay_range: Vector2 = Vector2(0.1, 0.25)

@export_group("Voice Profiles — Sax Group")
@export var sax_talk_sounds: Array[AudioStream] = []
@export var sax_track_sounds: Array[AudioStream] = []
@export var sax_retreat_sounds: Array[AudioStream] = []
@export var sax_charge_sounds: Array[AudioStream] = []
@export var sax_hurt_sounds: Array[AudioStream] = []
@export var sax_volume_offset_db: float = -2.0
@export var sax_pitch_variance: float = 0.08
## SAX ONLY: The chance (0.0 to 1.0) that triggering a talk sound creates a multi-sound sentence chain.
@export var sax_combo_chance: float = 0.15
## SAX ONLY: Minimum consecutive clips to play back-to-back in a rapid talk combo.
@export var sax_min_combo_sounds: int = 2
## SAX ONLY: Maximum consecutive clips to play back-to-back in a rapid talk combo.
@export var sax_max_combo_sounds: int = 3
## SAX ONLY: Delay spacing range (in seconds) between items parsing inside a Sax combo chain.
@export var sax_combo_delay_range: Vector2 = Vector2(0.18, 0.32)

@export_group("Voice Sync & Timing Settings")
## The probability (0.0 to 1.0) that a footstep will trigger a voice sound while moving.
@export var moving_voice_chance: float = 0.35
## Minimum time (in seconds) before a resting character plays a voice sound.
@export var idle_voice_delay_min: float = 3.5
## Maximum time (in seconds) before a resting character plays a voice sound.
@export var idle_voice_delay_max: float = 6.0


# ============================================================
# INTERNALS
# ============================================================

var assigned_voice: VoiceProfile = VoiceProfile.TV

var _parent: CharacterBody3D = null
var _animator: Node = null

# Dedicated footstep channels (alternating)
var _player_a: AudioStreamPlayer3D = null
var _player_b: AudioStreamPlayer3D = null
var _use_player_a: bool = true

# Polyphonic pooling for non-interrupting channels (Attacks, Hurts, Chatter, and Combos)
var _hit_players: Array[AudioStreamPlayer3D] = []
var _max_simultaneous_hits: int = 6

var _footstep_indices: Dictionary = { FootstepStyle.SQUISHY: 0, FootstepStyle.SQUEAKY: 0 }
var _attack_indices: Dictionary = {}

var _last_step_sign: float = 0.0
var _voice_timer: float = 0.0
var _is_moving_this_frame: bool = false


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	assigned_voice = VoiceProfile.values()[randi() % VoiceProfile.size()]

	for rps_enum in GlobalData.RPS.values():
		_attack_indices[rps_enum] = 0
		
	call_deferred("_initialize_manager")
	_reset_voice_timer()


func _initialize_manager() -> void:
	var p := get_parent()
	if p is CharacterBody3D:
		_parent = p
	else:
		push_error("SoundManager: Parent is not a CharacterBody3D! Sound processing aborted.")
		return

	for child in _parent.get_children():
		if child.has_method("get_speed_ratio") and "_walk_time" in child:
			_animator = child
			break

	_player_a = get_node_or_null("footstep_1") as AudioStreamPlayer3D
	if not is_instance_valid(_player_a):
		_player_a = AudioStreamPlayer3D.new()
		_player_a.name = "footstep_1"
		add_child(_player_a)

	_player_b = get_node_or_null("footstep_2") as AudioStreamPlayer3D
	if not is_instance_valid(_player_b):
		_player_b = AudioStreamPlayer3D.new()
		_player_b.name = "footstep_2"
		add_child(_player_b)

	for i in range(_max_simultaneous_hits):
		var hp := AudioStreamPlayer3D.new()
		hp.name = "hit_player_%d" % i
		add_child(hp)
		_hit_players.append(hp)


# ============================================================
# RUNTIME PROCESSORS & FOOTSTEPS
# ============================================================

func _physics_process(delta: float) -> void:
	if not is_instance_valid(_parent): return
	
	_is_moving_this_frame = false
	if _parent.is_on_floor():
		var speed_ratio := _get_speed_ratio()
		if speed_ratio >= footstep_min_speed_ratio:
			_is_moving_this_frame = true
			_detect_and_play_step(speed_ratio)
			
	_process_voice_chatter(delta)


func _detect_and_play_step(speed_ratio: float) -> void:
	if is_instance_valid(_animator) and "_walk_time" in _animator:
		var walk_time: float = _animator._walk_time
		var current_sign: float = sign(cos(walk_time))
		if _last_step_sign != 0.0 and current_sign != _last_step_sign:
			_play_step(speed_ratio)
		_last_step_sign = current_sign


func _play_step(speed_ratio: float) -> void:
	var config := _get_footstep_config()
	var pool: Array[AudioStream] = config["pool"]
	if pool.is_empty(): return

	var stream: AudioStream = null
	if config["sequential"] as bool:
		var idx: int = _footstep_indices[footstep_style]
		stream = pool[idx]
		_footstep_indices[footstep_style] = (idx + 1) % pool.size()
	else:
		stream = pool[randi() % pool.size()]

	var vol: float = base_footstep_volume_db + (config["volume_offset"] as float) + lerp(-3.0, 0.0, speed_ratio)
	_fire_footstep_channel(stream, vol, config["pitch_variance"] as float)

	# SIGNALS SYNC ENGINE: Handle voice triggers synchronized with the step frames.
	if _can_chatter():
		if randf() <= moving_voice_chance:
			_trigger_voice_or_combo()


# ============================================================
# AMBIENT VOICE CHATTER ENGINE
# ============================================================

func _can_chatter() -> bool:
	if not is_instance_valid(_animator) or not _animator.has_method("read_state_flags"): 
		return false
		
	var flags: Dictionary = _animator.read_state_flags()
	
	var is_talking: bool = flags["is_talking"] as bool
	var is_wandering: bool = (
		not flags["is_dead"] and 
		not flags["is_sleeping"] and 
		not flags["is_chasing"] and 
		not flags["is_fleeing"] and 
		not is_talking
	)
	return is_talking or is_wandering


func _process_voice_chatter(delta: float) -> void:
	if not _can_chatter():
		_voice_timer = 0.0 
		return

	if _is_moving_this_frame:
		return

	_voice_timer -= delta
	if _voice_timer <= 0.0:
		_trigger_voice_or_combo()
		_reset_voice_timer()


func _reset_voice_timer() -> void:
	_voice_timer = randf_range(idle_voice_delay_min, idle_voice_delay_max)


func _trigger_voice_or_combo() -> void:
	var current_chance: float = 0.0
	var min_sounds: int = 1
	var max_sounds: int = 1
	var delays: Vector2 = Vector2.ZERO

	match assigned_voice:
		VoiceProfile.TV:
			current_chance = tv_combo_chance
			min_sounds = tv_min_combo_sounds
			max_sounds = tv_max_combo_sounds
			delays = tv_combo_delay_range
		VoiceProfile.SAX:
			current_chance = sax_combo_chance
			min_sounds = sax_min_combo_sounds
			max_sounds = sax_max_combo_sounds
			delays = sax_combo_delay_range

	if randf() <= current_chance:
		var count: int = randi_range(min_sounds, max_sounds)
		_execute_voice_combo_chain(count, delays)
	else:
		play_ambient_voice_clip()


func _execute_voice_combo_chain(total_sounds: int, delays: Vector2) -> void:
	for i in range(total_sounds):
		play_ambient_voice_clip()
		if i < total_sounds - 1:
			var delay: float = randf_range(delays.x, delays.y)
			await get_tree().create_timer(delay, false).timeout


# ============================================================
# PUBLIC API CALLS
# ============================================================

## Localizes ambient sounds and handles them through the non-interrupting polyphonic pool.
func play_ambient_voice_clip() -> void:
	var pool: Array[AudioStream] = []
	var offset: float = 0.0
	var variance: float = 0.05
	
	match assigned_voice:
		VoiceProfile.TV:
			pool = tv_talk_sounds
			offset = tv_volume_offset_db
			variance = tv_pitch_variance
		VoiceProfile.SAX:
			pool = sax_talk_sounds
			offset = sax_volume_offset_db
			variance = sax_pitch_variance
			
	if pool.is_empty(): return
	
	var stream: AudioStream = pool[randi() % pool.size()]
	var vol: float = base_footstep_volume_db + offset
	_fire_hit_channel(stream, vol, variance)


func play_attack_sound() -> void:
	if not is_instance_valid(_parent) or not ("rps_class" in _parent):
		return
		
	var current_class = _parent.rps_class
	var config := _get_attack_config(current_class)
	var pool: Array[AudioStream] = config["pool"]
	if pool.is_empty(): return

	var stream: AudioStream = null
	if config["sequential"] as bool:
		var idx: int = _attack_indices[current_class]
		stream = pool[idx]
		_attack_indices[current_class] = (idx + 1) % pool.size()
	else:
		stream = pool[randi() % pool.size()]

	var vol: float = base_footstep_volume_db + (config["volume_offset"] as float)
	_fire_hit_channel(stream, vol, config["pitch_variance"] as float)


## Unique Phase Sound Call: Played when entering the standard tracking chase phase.
func play_chase_track_sound() -> void:
	var pool: Array[AudioStream] = []
	var offset: float = 0.0
	var variance: float = 0.05
	
	match assigned_voice:
		VoiceProfile.TV:
			pool = tv_track_sounds
			offset = tv_volume_offset_db + 0.5
			variance = tv_pitch_variance * 0.6
		VoiceProfile.SAX:
			pool = sax_track_sounds
			offset = sax_volume_offset_db + 0.5
			variance = sax_pitch_variance * 0.6
			
	_route_and_fire_phase_stream(pool, offset, variance)


## Unique Phase Sound Call: Played when the tactical engine forces a retreat phase backstep.
func play_chase_retreat_sound() -> void:
	var pool: Array[AudioStream] = []
	var offset: float = 0.0
	var variance: float = 0.05
	
	match assigned_voice:
		VoiceProfile.TV:
			pool = tv_retreat_sounds
			offset = tv_volume_offset_db + 0.8
			variance = tv_pitch_variance * 0.7
		VoiceProfile.SAX:
			pool = sax_retreat_sounds
			offset = sax_volume_offset_db + 0.8
			variance = sax_pitch_variance * 0.7
			
	_route_and_fire_phase_stream(pool, offset, variance)


## Unique Phase Sound Call: Played instantly when committing to a charge step.
func play_chase_charge_sound() -> void:
	var pool: Array[AudioStream] = []
	var offset: float = 0.0
	var variance: float = 0.05
	
	match assigned_voice:
		VoiceProfile.TV:
			pool = tv_charge_sounds
			offset = tv_volume_offset_db + 1.5
			variance = tv_pitch_variance * 0.4
		VoiceProfile.SAX:
			pool = sax_charge_sounds
			offset = sax_volume_offset_db + 1.5
			variance = sax_pitch_variance * 0.4
			
	_route_and_fire_phase_stream(pool, offset, variance)


func play_hurt_sound() -> void:
	var pool: Array[AudioStream] = []
	var offset: float = 0.0
	var variance: float = 0.05
	
	match assigned_voice:
		VoiceProfile.TV:
			pool = tv_hurt_sounds
			offset = tv_volume_offset_db + 1.5
			variance = tv_pitch_variance * 0.8
		VoiceProfile.SAX:
			pool = sax_hurt_sounds
			offset = sax_volume_offset_db + 1.5
			variance = sax_pitch_variance * 0.8
			
	if pool.is_empty(): return
	var stream: AudioStream = pool[randi() % pool.size()]
	var vol: float = base_footstep_volume_db + offset
	_fire_hit_channel(stream, vol, variance)


# ============================================================
# SOUND CONFIG ROUTING UTILITIES
# ============================================================

func _route_and_fire_phase_stream(pool: Array[AudioStream], offset: float, variance: float) -> void:
	if pool.is_empty(): return
	var stream: AudioStream = pool[randi() % pool.size()]
	var vol: float = base_footstep_volume_db + offset
	_fire_hit_channel(stream, vol, variance)


func _get_footstep_config() -> Dictionary:
	match footstep_style:
		FootstepStyle.SQUISHY:
			return { "pool": squishy_steps, "volume_offset": squishy_volume_offset_db, "pitch_variance": squishy_pitch_variance, "sequential": squishy_sequential }
		FootstepStyle.SQUEAKY:
			return { "pool": squeaky_steps, "volume_offset": squeaky_volume_offset_db, "pitch_variance": squeaky_pitch_variance, "sequential": squeaky_sequential }
	return {}


func _get_attack_config(rps_class: int) -> Dictionary:
	match rps_class:
		GlobalData.RPS.ROCK:
			return { "pool": rock_attack_sounds, "volume_offset": rock_attack_volume_offset_db, "pitch_variance": rock_attack_pitch_variance, "sequential": rock_attack_sequential }
		GlobalData.RPS.PAPER:
			return { "pool": paper_attack_sounds, "volume_offset": paper_attack_volume_offset_db, "pitch_variance": paper_attack_pitch_variance, "sequential": paper_attack_sequential }
		GlobalData.RPS.SCISSORS:
			return { "pool": scissors_attack_sounds, "volume_offset": scissors_attack_volume_offset_db, "pitch_variance": scissors_attack_pitch_variance, "sequential": scissors_attack_sequential }
		GlobalData.RPS.GUN:
			return { "pool": gun_attack_sounds, "volume_offset": gun_attack_volume_offset_db, "pitch_variance": gun_attack_pitch_variance, "sequential": gun_attack_sequential }
	return {}


# ============================================================
# LOW LEVEL AUDIO PLACEMENT DRIVERS
# ============================================================

func _fire_footstep_channel(stream: AudioStream, final_volume_db: float, variance: float) -> void:
	var player: AudioStreamPlayer3D = _player_a if _use_player_a else _player_b
	_use_player_a = not _use_player_a

	if not is_instance_valid(player): return

	player.stop()
	player.stream = stream
	player.volume_db = final_volume_db
	player.pitch_scale = 1.0 + randf_range(-variance, variance)
	player.play()


func _fire_hit_channel(stream: AudioStream, final_volume_db: float, variance: float) -> void:
	var available_player: AudioStreamPlayer3D = null
	
	for hp in _hit_players:
		if is_instance_valid(hp) and not hp.playing:
			available_player = hp
			break
			
	if not available_player:
		available_player = _hit_players[0]
		_hit_players.append(_hit_players.pop_front())

	if not is_instance_valid(available_player): return

	available_player.stream = stream
	available_player.volume_db = final_volume_db
	available_player.pitch_scale = 1.0 + randf_range(-variance, variance)
	available_player.play()


func _get_speed_ratio() -> float:
	if is_instance_valid(_animator) and _animator.has_method("get_speed_ratio"):
		var ref_speed: float = _animator.reference_speed if "reference_speed" in _animator else 10.0
		return _animator.get_speed_ratio(ref_speed)
	var h: float = Vector3(_parent.velocity.x, 0.0, _parent.velocity.z).length()
	return clamp(h / 5.0, 0.0, 1.0)


func set_footstep_style(style: FootstepStyle) -> void:
	footstep_style = style
