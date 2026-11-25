extends Node

## Central background-music owner.
##
## Scenes do not create their own music players; they call
## `play_menu_playlist()` or `play_track()`. The manager knows which file is
## playing, maps it to `resources/credits/credits.json`, and broadcasts the
## metadata so the BGM pop-up can credit the track.

signal track_changed(track: Dictionary)
signal playback_stopped()

const DATA_PATH := "res://resources/credits/credits.json"

const FALLBACK_MENU_THEMES := [
	"res://sounds/songs/menu_themes/1932 Lullaby Of The Leaves (with vocal group)_by George Olsen.mp3",
	"res://sounds/songs/menu_themes/Goodnight, My Beautiful_by Russ Morgan and His Orchestra.mp3",
	"res://sounds/songs/menu_themes/This Is Romance_by Hal Kemp and His Orchestra.mp3",
]

var _player: AudioStreamPlayer = null
var _entries: Array = []
var _catalog: Dictionary = {} # source path -> track metadata
var _playlist: Array[String] = []
var _order: Array[int] = []
var _order_position: int = -1
var _current_source: String = ""
var _current_track: Dictionary = {}
var _volume_db: float = -18.0
var _music_volume: float = 0.75


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.name = "MusicPlayer"
	_player.bus = &"Master"
	_player.volume_db = _volume_db
	_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_player)
	_player.finished.connect(_on_finished)
	_load_catalog()

	var settings := get_node_or_null("/root/PerformanceSettings")

	if settings != null and settings.has_signal("settings_changed"):
		if not settings.settings_changed.is_connected(_on_settings_changed):
			settings.settings_changed.connect(_on_settings_changed)

	_read_music_volume()
	_apply_volume()


## Stop and release the stream before the autoload is torn down. A playing
## AudioStreamPlayer keeps its AudioStreamPlayback alive; without this, Godot
## reports a leaked AudioStreamMP3/AudioStreamPlaybackMP3 at exit.
func _exit_tree() -> void:
	if _player != null:
		if _player.finished.is_connected(_on_finished):
			_player.finished.disconnect(_on_finished)

		# Synchronise with the audio thread before dropping the stream. MP3
		# playback is mixed on that thread; stopping without the lock can leave
		# the AudioStreamPlayback (and its stream) referenced at exit.
		AudioServer.lock()
		_player.stop()
		_player.stream = null
		AudioServer.unlock()
		_player.free()
		_player = null

	_current_source = ""
	_current_track = {}
	_playlist.clear()
	_order.clear()
	_order_position = -1


## Music level (0..1) stored by PerformanceSettings' Audio page. Kept in sync
## through `settings_changed`, so the Volume/Music buttons take effect live.
func _on_settings_changed() -> void:
	_read_music_volume()
	_apply_volume()


func _read_music_volume() -> void:
	var settings := get_node_or_null("/root/PerformanceSettings")

	if settings == null:
		return

	var value: Variant = settings.get("music_volume")
	var level: float = _music_volume

	if value is float:
		level = value
	elif value is int:
		level = float(value)

	_music_volume = clampf(level, 0.0, 1.0)


func _apply_volume() -> void:
	if _player == null:
		return

	if _music_volume <= 0.0:
		_player.volume_db = -80.0
	else:
		_player.volume_db = _volume_db + linear_to_db(_music_volume)


func _load_catalog() -> void:
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)

	if file != null:
		var parsed: Variant = JSON.parse_string(file.get_as_text())

		if parsed is Dictionary:
			var music: Variant = (parsed as Dictionary).get("music", [])

			if music is Array:
				for entry_value: Variant in music:
					if not entry_value is Dictionary:
						continue

					var entry: Dictionary = entry_value
					var source := String(entry.get("source", "")).strip_edges()

					if source.is_empty():
						continue

					var copy: Dictionary = entry.duplicate(true)
					copy["source"] = source
					_entries.append(copy)
					_catalog[source] = copy

	if _entries.is_empty():
		for path: String in FALLBACK_MENU_THEMES:
			var fallback_entry := {
				"title": _title_from_path(path),
				"artist": "Unknown",
				"source": path,
				"license": "Menu theme",
			}
			_entries.append(fallback_entry)
			_catalog[path] = fallback_entry


func get_music_entries() -> Array:
	return _entries.duplicate(true)


func get_current_track() -> Dictionary:
	return _current_track.duplicate(true)


func current_source() -> String:
	return _current_source


func is_playing() -> bool:
	return _player != null and _player.playing


## Starts the menu-theme playlist. If one of those themes is already playing,
## the current track continues instead of restarting on every scene change.
func play_menu_playlist(volume_db: float = -18.0) -> void:
	var paths: Array[String] = []

	for entry_value: Variant in _entries:
		if not entry_value is Dictionary:
			continue

		var entry: Dictionary = entry_value
		var source := String(entry.get("source", ""))
		var license := String(entry.get("license", ""))

		if license == "Menu theme" and ResourceLoader.exists(source):
			paths.append(source)

	if paths.is_empty():
		for path: String in FALLBACK_MENU_THEMES:
			if ResourceLoader.exists(path):
				paths.append(path)

	play_playlist(paths, volume_db, true, false)


func play_playlist(
	paths: Array,
	volume_db: float = -18.0,
	shuffle: bool = true,
	restart: bool = false
) -> void:
	var filtered: Array[String] = []

	for path_value: Variant in paths:
		var path := String(path_value)
		if not path.is_empty() and ResourceLoader.exists(path):
			filtered.append(path)

	if filtered.is_empty():
		return

	if not restart and is_playing() and filtered.has(_current_source):
		_volume_db = volume_db
		_apply_volume()
		return

	_playlist = filtered
	_order.clear()
	for index in filtered.size():
		_order.append(index)

	if shuffle:
		_order.shuffle()

	_order_position = 0
	_volume_db = volume_db
	_play_source(_playlist[_order[_order_position]])


func play_track(source: String, volume_db: float = -18.0) -> void:
	if source.is_empty() or not ResourceLoader.exists(source):
		return

	_playlist.clear()
	_order.clear()
	_order_position = -1
	_volume_db = volume_db
	_play_source(source)


func stop() -> void:
	if _player != null:
		_player.stop()

	_current_source = ""
	_current_track = {}
	playback_stopped.emit()


func _play_source(source: String) -> void:
	if _player == null:
		return

	# Same file still playing: do not restart it and do not re-announce it.
	if source == _current_source and _player.playing:
		_current_track = _track_for(source)
		return

	var stream := load(source) as AudioStream

	if stream == null:
		push_warning("MusicManager: could not load %s" % source)
		return

	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = false
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false

	_current_source = source
	_current_track = _track_for(source)
	_player.stream = stream
	_apply_volume()
	_player.play()
	track_changed.emit(get_current_track())


func _track_for(source: String) -> Dictionary:
	var entry: Variant = _catalog.get(source, {})

	if entry is Dictionary and not (entry as Dictionary).is_empty():
		var copy: Dictionary = (entry as Dictionary).duplicate(true)
		copy["source"] = source
		return copy

	var derived := _title_from_path(source)
	return {
		"title": derived,
		"artist": "Unknown",
		"source": source,
		"license": "",
	}


func _title_from_path(source: String) -> String:
	var file_name := source.get_file()
	var title := file_name.get_basename()
	return title.replace("_", " ").strip_edges()


func _on_finished() -> void:
	if _playlist.is_empty() or _order.is_empty():
		playback_stopped.emit()
		return

	_order_position += 1

	if _order_position >= _order.size():
		_order.shuffle()
		_order_position = 0

	if _order_position < 0 or _order_position >= _order.size():
		return

	var index := _order[_order_position]

	if index < 0 or index >= _playlist.size():
		return

	_play_source(_playlist[index])
