class_name DialogueManager
extends Node

## Small step-based dialogue interpreter.
##
## Scripts are arrays of dictionaries. A step can carry:
##   label / goto / end
##   set_flag + value
##   emote / gesture (+ hand: 0 left, 1 right, -1 both)
##   say (+ optional button)            waits for advance()
##   choice (+ text + options[].goto)   waits for choose(index)
##   wait                                continues after N seconds
##   move_to (NodePath) + offset         view moves Consul, then calls advance()
##   point_at (NodePath)                 view points Consul, then calls advance()
##   gaze: "auto"|"cursor"|"random"|"target"|"default"
##         + gaze_target (NodePath or Vector2), gaze_radius
##   wave                                view waves, then playback continues
##   condition: {flag, not_flag, all, any}
##
## Flags live in GlobalData.dialogue_flags so they survive scene reloads.

signal say_requested(text: String, button_text: String)
signal choice_requested(prompt: String, options: Array)
signal gesture_requested(gesture: String, hand: int)
signal emote_requested(emote: String)
signal move_requested(target: NodePath, offset: Vector2)
signal point_requested(target: NodePath)
signal wave_requested()
signal gaze_requested(mode: String, target: Variant, radius: float)
signal finished()

var _steps: Array = []
var _labels: Dictionary = {}
var _index: int = 0
var _running: bool = false


func is_running() -> bool:
	return _running


func start(steps: Array) -> void:
	stop()
	_steps = normalize_steps(steps)

	for step_index in _steps.size():
		var step: Variant = _steps[step_index]
		if step is Dictionary and step.has("label"):
			_labels[String(step["label"])] = step_index

	_running = true
	_index = 0
	_run()


# ---------------------------------------------------------------------------
# JSON storage
# ---------------------------------------------------------------------------

func load_dialogue(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_warning("Dialogue file not found: " + path)
		return []

	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_warning("Dialogue file is empty: " + path)
		return []

	return steps_from_json(text)


func start_from_file(path: String) -> bool:
	var steps := load_dialogue(path)
	if steps.is_empty():
		return false

	start(steps)
	return true


func save_dialogue(path: String, steps: Array) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write dialogue file: " + path)
		return false

	file.store_string(steps_to_json(steps))
	file.close()
	return true


func steps_from_json(text: String) -> Array:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is not Array:
		push_warning("Dialogue JSON must be an array.")
		return []

	return normalize_steps(parsed)


func steps_to_json(steps: Array) -> String:
	return JSON.stringify(_serialize_value(steps), "\t")


## Converts JSON-friendly values back into runtime values (NodePath, Vector2).
func normalize_steps(steps: Array) -> Array:
	var normalized: Array = []

	for raw_step: Variant in steps:
		if raw_step is Dictionary:
			normalized.append(_normalize_step(raw_step))
		else:
			normalized.append(raw_step)

	return normalized


func _normalize_step(step: Dictionary) -> Dictionary:
	var out: Dictionary = step.duplicate(true)

	if out.has("move_to") and out["move_to"] is String:
		out["move_to"] = NodePath(out["move_to"])
	if out.has("point_at") and out["point_at"] is String:
		out["point_at"] = NodePath(out["point_at"])
	if out.has("gaze_target"):
		out["gaze_target"] = _normalize_gaze_target(out["gaze_target"])
	if out.has("offset"):
		out["offset"] = _to_vector2(out["offset"])

	return out


func _normalize_gaze_target(value: Variant) -> Variant:
	if value is String:
		return NodePath(value)
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return value


func _to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO


func _serialize_value(value: Variant) -> Variant:
	if value is NodePath:
		return String(value)
	if value is Vector2:
		return [value.x, value.y]
	if value is Array:
		var array: Array = []
		for item: Variant in value:
			array.append(_serialize_value(item))
		return array
	if value is Dictionary:
		var dictionary: Dictionary = {}
		for key: Variant in value:
			dictionary[String(key)] = _serialize_value(value[key])
		return dictionary
	return value


func stop() -> void:
	_running = false
	_steps = []
	_labels = {}
	_index = 0


func advance() -> void:
	if not _running:
		return

	_index += 1
	_run()


func choose(option_index: int) -> void:
	if not _running or _index >= _steps.size():
		return

	var step: Dictionary = _steps[_index]
	var options: Array = step.get("choice", [])

	if option_index < 0 or option_index >= options.size():
		return

	var option: Dictionary = options[option_index]
	var goto: Variant = option.get("goto", null)

	if goto != null and _labels.has(String(goto)):
		_index = int(_labels[String(goto)])
	else:
		_index += 1

	_run()


func get_flag(key: StringName, default_value: Variant = false) -> Variant:
	return GlobalData.get_dialogue_flag(key, default_value)


func set_flag(key: StringName, value: Variant = true) -> void:
	GlobalData.set_dialogue_flag(key, value)


func check_condition(condition: Variant) -> bool:
	if condition == null:
		return true
	if condition is not Dictionary:
		return true

	var checks: Dictionary = condition
	if checks.is_empty():
		return true

	if checks.has("flag"):
		var expected: Variant = checks.get("equals", true)
		if get_flag(StringName(checks["flag"]), false) != expected:
			return false

	if checks.has("not_flag"):
		if bool(get_flag(StringName(checks["not_flag"]), false)):
			return false

	if checks.has("all"):
		for sub_condition: Variant in checks["all"]:
			if not check_condition(sub_condition):
				return false

	if checks.has("any"):
		var any_ok: bool = false
		for sub_condition: Variant in checks["any"]:
			if check_condition(sub_condition):
				any_ok = true
				break
		if not any_ok:
			return false

	return true


func _run() -> void:
	if not _running:
		return

	while _running and _index < _steps.size():
		var raw_step: Variant = _steps[_index]

		if raw_step is not Dictionary:
			_index += 1
			continue

		var step: Dictionary = raw_step

		if not check_condition(step.get("condition")):
			_index += 1
			continue

		if step.has("set_flag"):
			set_flag(
				StringName(step["set_flag"]),
				step.get("value", true)
			)

		if step.has("emote"):
			emote_requested.emit(String(step["emote"]))

		if step.has("gesture"):
			gesture_requested.emit(
				String(step["gesture"]),
				int(step.get("hand", -1))
			)

		if step.has("wave"):
			wave_requested.emit()

		if step.has("gaze"):
			gaze_requested.emit(
				String(step["gaze"]),
				step.get("gaze_target", null),
				float(step.get("gaze_radius", 700.0))
			)

		if step.has("wait"):
			var seconds: float = maxf(float(step["wait"]), 0.0)
			_index += 1
			await get_tree().create_timer(seconds).timeout
			_run()
			return

		if step.has("goto"):
			var label: String = String(step["goto"])
			if _labels.has(label):
				_index = int(_labels[label])
				continue

		if step.has("move_to"):
			move_requested.emit(
				_as_node_path(step["move_to"]),
				step.get("offset", Vector2.ZERO)
			)
			return

		if step.has("point_at"):
			point_requested.emit(_as_node_path(step["point_at"]))
			return

		if step.has("choice"):
			choice_requested.emit(
				String(step.get("text", "")),
				step["choice"]
			)
			return

		if step.has("say"):
			say_requested.emit(
				String(step["say"]),
				String(step.get("button", "Continue"))
			)
			return

		if step.has("end"):
			_finish()
			return

		# Label / flag-only / emote-only step: keep going.
		_index += 1

	_finish()


func _finish() -> void:
	if not _running:
		return

	_running = false
	finished.emit()


func _as_node_path(value: Variant) -> NodePath:
	if value is NodePath:
		return value
	return NodePath(String(value))
