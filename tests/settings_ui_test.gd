extends SceneTree

## Guards the structural toggles staying reachable in both menus. The main menu
## and the pause menu both instance `scenes/menu/settings/gameplay_menu.tscn`,
## so checking the scene once covers both.
##
##   godot --headless --path . --script res://tests/settings_ui_test.gd

const GAMEPLAY_MENU := "res://scenes/menu/settings/gameplay_menu.tscn"

const EXPECTED := {
	"LeftColumn/Stability": "stability",
	"LeftColumn/Destruction": "destruction",
	"RightColumn/PhysicsLevel": "physics_level",
	"RightColumn/StabilityOverlay": "stability_debug",
	"RightColumn/AutoDock": "auto_dock",
}

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== structural settings ui ===")

	var packed: PackedScene = load(GAMEPLAY_MENU)
	_expect("gameplay menu loads", packed != null)
	if packed == null:
		_finish()
		return

	var root: Node = packed.instantiate()
	for path: String in EXPECTED:
		var node: Node = root.get_node_or_null(path)
		_expect("%s exists" % path, node != null)
		if node != null:
			_expect(
				"%s action" % path,
				String(node.get("action")) == String(EXPECTED[path]),
				String(node.get("action"))
			)

	# The existing rows must not have been displaced by the new ones.
	for path in ["LeftColumn/AgentLimit", "LeftColumn/ViewRoll", "RightColumn/ExportDefaults", "GameplayBack"]:
		_expect("%s still present" % path, root.get_node_or_null(path) != null)

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
