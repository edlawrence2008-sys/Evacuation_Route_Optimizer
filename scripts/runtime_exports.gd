extends Node

## Per-save runtime exports and their global defaults.
##
## The player can change Member exports (Agents panel), simulation limits
## (Simulation panel), Random Populate settings and the optimizer configuration
## while the game is running. Those values are session state by default, so this
## node captures them into `save.json` and restores them on load. A separate
## `user://export_defaults.json` holds the values a *new* save should start
## from; the Settings > Gameplay > Export Defaults page edits that file.

const DEFAULTS_PATH: String = "user://export_defaults.json"
const VERSION: int = 1

var defaults: Dictionary = {}

signal defaults_changed
signal runtime_exports_applied


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_defaults()
	# Apply once the whole autoload set and the first scene are available.
	call_deferred("apply_defaults_to_live")


# ---------------------------------------------------------------------------
# Defaults file
# ---------------------------------------------------------------------------

func load_defaults() -> void:
	defaults = {}

	if not FileAccess.file_exists(DEFAULTS_PATH):
		return

	var file := FileAccess.open(DEFAULTS_PATH, FileAccess.READ)

	if file == null:
		return

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()

	if parsed is Dictionary:
		defaults = _revive(parsed)


func save_defaults() -> void:
	var file := FileAccess.open(DEFAULTS_PATH, FileAccess.WRITE)

	if file == null:
		push_warning("RuntimeExports: cannot write " + DEFAULTS_PATH)
		return

	file.store_string(JSON.stringify(_json_safe(defaults), "\t"))
	file.close()
	defaults_changed.emit()


func _json_safe(value: Variant) -> Variant:
	if value is StringName:
		return {"__export_type": "StringName", "value": String(value)}

	if value is Vector2:
		var v2: Vector2 = value
		return {"__export_type": "Vector2", "value": [v2.x, v2.y]}

	if value is Vector3:
		var v3: Vector3 = value
		return {"__export_type": "Vector3", "value": [v3.x, v3.y, v3.z]}

	if value is Vector2i:
		var v2i: Vector2i = value
		return {"__export_type": "Vector2i", "value": [v2i.x, v2i.y]}

	if value is Vector3i:
		var v3i: Vector3i = value
		return {"__export_type": "Vector3i", "value": [v3i.x, v3i.y, v3i.z]}

	if value is Color:
		var color: Color = value
		return {
			"__export_type": "Color",
			"value": [color.r, color.g, color.b, color.a],
		}

	if value is Dictionary:
		var dictionary: Dictionary = {}
		for key: Variant in (value as Dictionary):
			dictionary[key] = _json_safe((value as Dictionary)[key])
		return dictionary

	if value is Array:
		var array: Array = []
		for item: Variant in (value as Array):
			array.append(_json_safe(item))
		return array

	return value


func _revive(value: Variant) -> Variant:
	if value is Dictionary:
		var dictionary: Dictionary = value

		if dictionary.has("__export_type"):
			var kind := String(dictionary.get("__export_type", ""))
			var raw: Array = dictionary.get("value", [])

			match kind:
				"StringName":
					return StringName(String(dictionary.get("value", "")))
				"Vector2":
					if raw.size() >= 2:
						return Vector2(float(raw[0]), float(raw[1]))
				"Vector3":
					if raw.size() >= 3:
						return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
				"Vector2i":
					if raw.size() >= 2:
						return Vector2i(int(raw[0]), int(raw[1]))
				"Vector3i":
					if raw.size() >= 3:
						return Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
				"Color":
					if raw.size() >= 4:
						return Color(
							float(raw[0]), float(raw[1]),
							float(raw[2]), float(raw[3])
						)
			return null

		var revived: Dictionary = {}
		for key: Variant in dictionary:
			revived[key] = _revive(dictionary[key])
		return revived

	if value is Array:
		var array: Array = []
		for item: Variant in (value as Array):
			array.append(_revive(item))
		return array

	return value


func has_defaults() -> bool:
	return not defaults.is_empty()


func get_default_section(section: String) -> Dictionary:
	var value: Variant = defaults.get(section, {})
	return value.duplicate(true) if value is Dictionary else {}


func get_default(section: String, key: String, fallback: Variant) -> Variant:
	var block: Variant = defaults.get(section, {})

	if block is Dictionary and block.has(key):
		return block[key]

	return fallback


func set_default(section: String, key: String, value: Variant) -> void:
	var block: Dictionary = get_default_section(section)
	block[key] = value
	defaults[section] = block
	save_defaults()


func set_section_defaults(section: String, values: Dictionary) -> void:
	if values.is_empty():
		defaults.erase(section)
	else:
		defaults[section] = values.duplicate(true)

	save_defaults()


func clear_section_defaults(section: String) -> void:
	defaults.erase(section)
	save_defaults()


func clear_all_defaults() -> void:
	defaults.clear()
	save_defaults()


## Captures every live runtime export — global values, agent overrides, Random
## Populate and optimizer configuration — as the defaults new saves start from.
func save_live_as_defaults() -> void:
	var live := collect_live()
	live.erase("version")
	defaults = live
	save_defaults()


# ---------------------------------------------------------------------------
# Live capture and restore
# ---------------------------------------------------------------------------

func collect_live() -> Dictionary:
	var safe: Variant = _json_safe({
		"version": VERSION,
		"global": _collect_global(),
		"agents": GlobalData.agent_overrides.duplicate(true),
		"populator": _collect_populator(),
		"optimizer": _collect_optimizer(),
	})
	return safe if safe is Dictionary else {}


func apply_live(block: Dictionary) -> void:
	block = _revive(block) if block is Dictionary else {}
	var global_block: Dictionary = (
		block.get("global", {}) if block.get("global", {}) is Dictionary else {}
	)
	var global_defaults: Dictionary = get_default_section("global")

	GlobalData.global_unit_cap = maxi(
		1,
		int(
			_resolve(
				global_block,
				global_defaults,
				"global_unit_cap",
				GlobalData.global_unit_cap
			)
		)
	)
	GlobalData.global_spawn_quota = int(
		_resolve(
			global_block,
			global_defaults,
			"global_spawn_quota",
			GlobalData.global_spawn_quota
		)
	)
	GlobalData.rng_seed = maxi(
		0,
		int(
			_resolve(
				global_block,
				global_defaults,
				"rng_seed",
				GlobalData.rng_seed
			)
		)
	)
	GlobalData.evacuation_mode = bool(
		_resolve(
			global_block,
			global_defaults,
			"evacuation_mode",
			GlobalData.evacuation_mode
		)
	)

	var recorder := get_node_or_null("/root/SimRecorder")

	if recorder != null:
		recorder.recording_enabled = bool(
			_resolve(
				global_block,
				global_defaults,
				"recording_enabled",
				recorder.recording_enabled
			)
		)

	var agent_defaults: Variant = defaults.get("agents", {})
	var agent_values: Variant = block.get("agents", agent_defaults)

	if not agent_values is Dictionary:
		agent_values = {}

	GlobalData.set_agent_overrides(agent_values)

	var populator_block: Variant = block.get("populator", {})
	var populator_defaults: Variant = defaults.get("populator", {})

	_apply_populator(
		populator_block if populator_block is Dictionary else {},
		populator_defaults if populator_defaults is Dictionary else {}
	)

	var optimizer_block: Variant = block.get("optimizer", {})
	var optimizer_defaults: Variant = defaults.get("optimizer", {})

	_apply_optimizer(
		optimizer_block if optimizer_block is Dictionary else {},
		optimizer_defaults if optimizer_defaults is Dictionary else {}
	)
	runtime_exports_applied.emit()


func apply_defaults_to_live() -> void:
	apply_live({
		"global": get_default_section("global"),
		"agents": get_default_section("agents"),
		"populator": get_default_section("populator"),
		"optimizer": get_default_section("optimizer"),
	})


# ---------------------------------------------------------------------------
# Collection helpers
# ---------------------------------------------------------------------------

func _collect_global() -> Dictionary:
	var recorder := get_node_or_null("/root/SimRecorder")

	return {
		"global_unit_cap": GlobalData.global_unit_cap,
		"global_spawn_quota": GlobalData.global_spawn_quota,
		"rng_seed": GlobalData.rng_seed,
		"evacuation_mode": GlobalData.evacuation_mode,
		"recording_enabled": (
			bool(recorder.recording_enabled) if recorder != null else true
		),
	}


func _collect_populator() -> Dictionary:
	var node := _first_in_group("random_populator")

	if node == null:
		return {}

	return {
		"member_count": int(node.get("member_count")),
		"start_evacuating": bool(node.get("start_evacuating")),
		"only_pathfindable_blocks": bool(node.get("only_pathfindable_blocks")),
		"spawn_clearance": float(node.get("spawn_clearance")),
	}


func _collect_optimizer() -> Dictionary:
	var bridge := _first_in_group("optimizer_bridge")

	if bridge == null:
		return {}

	return {
		"enabled": bool(bridge.get("enabled")),
		"auto_solve": bool(bridge.get("auto_solve")),
		"re_solve_enabled": bool(bridge.get("re_solve_enabled")),
		"re_solve_interval": float(bridge.get("re_solve_interval")),
		"overlay_enabled": bool(bridge.get("overlay_enabled")),
		"algorithm": String(bridge.get("algorithm")),
		"mode": String(bridge.get("mode")),
		"cohort_size": float(bridge.get("cohort_size")),
		"max_cohorts": int(bridge.get("max_cohorts")),
		"weights": (bridge.get("weights") as Dictionary).duplicate(true),
		"parameters": (bridge.get("parameters") as Dictionary).duplicate(true),
	}


func _apply_populator(block: Dictionary, fallback: Dictionary) -> void:
	var node := _first_in_group("random_populator")

	if node == null:
		return

	node.set(
		"member_count",
		maxi(
			1,
			int(_resolve(block, fallback, "member_count", node.get("member_count")))
		)
	)
	node.set(
		"start_evacuating",
		bool(
			_resolve(
				block,
				fallback,
				"start_evacuating",
				node.get("start_evacuating")
			)
		)
	)
	node.set(
		"only_pathfindable_blocks",
		bool(
			_resolve(
				block,
				fallback,
				"only_pathfindable_blocks",
				node.get("only_pathfindable_blocks")
			)
		)
	)
	node.set(
		"spawn_clearance",
		maxf(
			0.0,
			float(
				_resolve(
					block,
					fallback,
					"spawn_clearance",
					node.get("spawn_clearance")
				)
			)
		)
	)


func _apply_optimizer(block: Dictionary, fallback: Dictionary) -> void:
	var bridge := _first_in_group("optimizer_bridge")

	if bridge == null or (block.is_empty() and fallback.is_empty()):
		return

	if block.has("algorithm") or fallback.has("algorithm"):
		bridge.call(
			"set_algorithm",
			String(_resolve(block, fallback, "algorithm", bridge.get("algorithm")))
		)

	if block.has("mode") or fallback.has("mode"):
		bridge.call(
			"set_mode",
			String(_resolve(block, fallback, "mode", bridge.get("mode")))
		)

	if block.has("cohort_size") or fallback.has("cohort_size"):
		bridge.call(
			"set_cohort_size",
			float(_resolve(block, fallback, "cohort_size", bridge.get("cohort_size")))
		)

	if block.has("max_cohorts") or fallback.has("max_cohorts"):
		bridge.call(
			"set_max_cohorts",
			int(_resolve(block, fallback, "max_cohorts", bridge.get("max_cohorts")))
		)

	if block.has("auto_solve") or fallback.has("auto_solve"):
		bridge.call(
			"set_auto_solve",
			bool(_resolve(block, fallback, "auto_solve", bridge.get("auto_solve")))
		)

	if block.has("re_solve_enabled") or fallback.has("re_solve_enabled"):
		bridge.call(
			"set_re_solve_enabled",
			bool(_resolve(
				block,
				fallback,
				"re_solve_enabled",
				bridge.get("re_solve_enabled")
			))
		)

	if block.has("re_solve_interval") or fallback.has("re_solve_interval"):
		bridge.call(
			"set_re_solve_interval",
			float(_resolve(
				block,
				fallback,
				"re_solve_interval",
				bridge.get("re_solve_interval")
			))
		)

	if block.has("overlay_enabled") or fallback.has("overlay_enabled"):
		bridge.call(
			"set_overlay_enabled",
			bool(_resolve(
				block,
				fallback,
				"overlay_enabled",
				bridge.get("overlay_enabled")
			))
		)

	if block.has("enabled") or fallback.has("enabled"):
		bridge.call(
			"set_enabled",
			bool(_resolve(block, fallback, "enabled", bridge.get("enabled")))
		)

	var weights: Variant = block.get("weights", fallback.get("weights", null))

	if weights is Dictionary:
		bridge.set("weights", weights.duplicate(true))

	var parameters: Variant = block.get(
		"parameters", fallback.get("parameters", null)
	)

	if parameters is Dictionary:
		bridge.set("parameters", parameters.duplicate(true))

	if bridge.has_method("_sync_recorder_configuration"):
		bridge.call("_sync_recorder_configuration")

	var panel := bridge.get_parent()

	if panel != null and panel.has_method("_sync_controls"):
		panel.call("_sync_controls")


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

func _resolve(
	block: Dictionary, fallback: Dictionary, key: String, value: Variant
) -> Variant:
	if block.has(key):
		return block[key]

	if fallback.has(key):
		return fallback[key]

	return value


func _first_in_group(group_name: String) -> Node:
	if get_tree() == null:
		return null

	return get_tree().get_first_node_in_group(group_name)


## Public JSON-safe conversion used by SaveManager for placeable exports.
func encode_value(value: Variant) -> Variant:
	return _json_safe(value)


func decode_value(value: Variant) -> Variant:
	return _revive(value)
