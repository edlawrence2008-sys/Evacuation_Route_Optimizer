extends SceneTree

## Physics gun appears in the Useables catalog, owns a UseComponent for the
## separate gun hold, and exposes the emitter the beam starts from.
##
##   godot --headless --path . --script res://tests/useables_test.gd

const HUD_SCRIPT = preload("res://scenes/hud.gd")
const VOXEL_ITEMS = preload("res://scripts/voxel_item_generator.gd")

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== useables ===")

	var path := "res://scenes/useables/physics_gun.tscn"
	_expect(
		"catalog lists the physics gun",
		HUD_SCRIPT.USEABLE_SCENE_PATHS.has(path)
	)

	var packed := load(path) as PackedScene
	_expect("physics gun scene loads", packed != null)
	if packed == null:
		_finish()
		return

	var root: Node = packed.instantiate()
	var component: UseComponent = null
	for child in root.get_children():
		if child is UseComponent:
			component = child
			break
	_expect("physics gun owns a UseComponent", component != null)

	if component != null:
		_expect(
			"component script is the physics gun",
			component.get_script().resource_path.ends_with(
				"physics_gun_component.gd"
			)
		)
		_expect(
			"component has a description",
			not String(component.get("description")).is_empty()
		)
		for method in [
			"use", "alt_use", "hold", "release", "rotate_held"
		]:
			_expect("component implements %s" % method, component.has_method(method))
		_expect(
			"component exposes a reach override",
			"reach_override" in component
		)
		_expect(
			"component exposes the held-collision toggle",
			"ignore_collision_while_held" in component
		)

	var meshes := 0
	for child in root.get_children():
		if child is MeshInstance3D:
			meshes += 1
	_expect("physics gun has a model", meshes > 0, str(meshes))

	var emitter := root.get_node_or_null("Emitter") as MeshInstance3D
	_expect("physics gun has an emitter", emitter != null)
	if emitter != null:
		_expect("emitter is tagged as the beam muzzle", emitter.has_meta("muzzle"))

	root.free()

	var fire_path := "res://scenes/useables/fire_tool.tscn"
	_expect(
		"catalog lists the fire tool",
		HUD_SCRIPT.USEABLE_SCENE_PATHS.has(fire_path)
	)
	var fire_packed := load(fire_path) as PackedScene
	_expect("fire tool scene loads", fire_packed != null)
	if fire_packed != null:
		var fire_root: Node = fire_packed.instantiate()
		var fire_component: UseComponent = null
		for child in fire_root.get_children():
			if child is UseComponent:
				fire_component = child
				break
		_expect("fire tool owns a UseComponent", fire_component != null)
		if fire_component != null:
			_expect(
				"component script is the fire tool",
				fire_component.get_script().resource_path.ends_with(
					"fire_tool_component.gd"
				)
			)
			_expect("fire tool has a reach", "reach" in fire_component)
			_expect("fire tool can use", fire_component.has_method("use"))
		fire_root.free()

	var static_path := "res://scenes/useables/static_bodifier.tscn"
	_expect(
		"catalog lists the static bodifier",
		HUD_SCRIPT.USEABLE_SCENE_PATHS.has(static_path)
	)
	var static_packed := load(static_path) as PackedScene
	_expect("static bodifier scene loads", static_packed != null)
	if static_packed != null:
		var static_root: Node = static_packed.instantiate()
		var static_component: UseComponent = null
		for child in static_root.get_children():
			if child is UseComponent:
				static_component = child
				break
		_expect(
			"static bodifier owns a UseComponent",
			static_component != null
		)
		if static_component != null:
			_expect(
				"component script is the static bodifier",
				static_component.get_script().resource_path.ends_with(
					"static_bodifier_component.gd"
				)
			)
			_expect(
				"static bodifier has a reach",
				"reach" in static_component
			)
			_expect(
				"static bodifier has a description",
				not String(static_component.get("description")).is_empty()
			)
		static_root.free()

	for tool_spec in [
		["res://scenes/useables/nav_bodifier.tscn", "nav_bodifier_component.gd"],
		["res://scenes/useables/dupe_gun.tscn", "dupe_gun_component.gd"],
	]:
		var tool_path := String(tool_spec[0])
		var component_script := String(tool_spec[1])
		_expect(
			"catalog lists %s" % tool_path.get_file(),
			HUD_SCRIPT.USEABLE_SCENE_PATHS.has(tool_path)
		)
		var tool_packed := load(tool_path) as PackedScene
		_expect("%s loads" % tool_path.get_file(), tool_packed != null)
		if tool_packed == null:
			continue
		var tool_root: Node = tool_packed.instantiate()
		var tool_component: UseComponent = null
		for child in tool_root.get_children():
			if child is UseComponent:
				tool_component = child
				break
		_expect(
			"%s owns a UseComponent" % tool_path.get_file(),
			tool_component != null
		)
		if tool_component != null:
			_expect(
				"%s has the expected script" % tool_path.get_file(),
				tool_component.get_script().resource_path.ends_with(
					component_script
				)
			)
			_expect(
				"%s has a reach" % tool_path.get_file(),
				"reach" in tool_component
			)
			_expect(
				"%s has a description" % tool_path.get_file(),
				not String(tool_component.get("description")).is_empty()
			)
		tool_root.free()

	for path_value: Variant in HUD_SCRIPT.USEABLE_SCENE_PATHS:
		var scene_path := String(path_value)
		var scene := load(scene_path) as PackedScene
		var icon: Texture2D = VOXEL_ITEMS.icon_for_scene(scene)
		_expect(
			"useable has an icon: %s" % scene_path.get_file(),
			icon != null
		)

	_finish()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("FAIL: %s" % label)
	else:
		print("FAIL: %s (%s)" % [label, detail])


func _finish() -> void:
	print("checks=%d failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== PASS ===")
	quit(1 if _failures > 0 else 0)
