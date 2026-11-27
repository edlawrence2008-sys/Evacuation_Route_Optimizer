extends SceneTree

## Physics gun appears in the Useables catalog, owns a UseComponent for the
## separate gun hold, and exposes the emitter the beam starts from.
##
##   godot --headless --path . --script res://tests/useables_test.gd

const HUD_SCRIPT = preload("res://scenes/hud.gd")

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
