@tool
extends EditorScript

## Editor entry point for the voxel item generator.
##
## The implementation lives in `voxel_item_generator.gd`, which is a plain
## `RefCounted` because `hand_item.gd` and `hud.gd` preload it at runtime for
## icon lookups. This wrapper exists only to give that shared code an
## `EditorScript` host: File > Run on this file, or use
## Project > Tools > Content: Generate Voxel Item Icons.
##
## The wrapper supplies the in-tree host node that the SubViewport renderer
## needs; it does not duplicate any generation logic.

const GENERATOR := preload("res://scripts/voxel_item_generator.gd")


func _run() -> void:
	var host: Node = EditorInterface.get_base_control()
	var result: Dictionary = await GENERATOR.generate_all(host)
	var generated: Array = result.get("generated", [])
	var errors: Array = result.get("errors", [])
	print("Voxel items generated: %d" % generated.size())
	for path: String in generated:
		print("  " + path)
	for error: String in errors:
		push_warning("Voxel item: " + error)
