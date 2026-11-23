class_name LogicAudioComponent
extends PoweredComponent

## Plays/stops an AudioStreamPlayer3D when powered. Use for speakers, alarms,
## and machine hum.

@export var player_path: NodePath
@export var on_stream: AudioStream
@export var loop: bool = true

var _audio: AudioStreamPlayer3D = null


func _ready() -> void:
	super._ready()
	_audio = get_node_or_null(player_path) as AudioStreamPlayer3D
	if _audio != null and on_stream != null:
		_audio.stream = on_stream
		if _audio.stream is AudioStreamWAV:
			(_audio.stream as AudioStreamWAV).loop_mode = (
				AudioStreamWAV.LOOP_FORWARD if loop
				else AudioStreamWAV.LOOP_DISABLED
			)
	_apply_power()


func _apply_power() -> void:
	if _audio == null:
		return
	if powered:
		_audio.play()
	else:
		_audio.stop()
