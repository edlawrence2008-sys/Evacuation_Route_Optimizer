@tool
extends EditorScript

## Editor entry point for the shared voxel item generator. Other generators can
## call scripts/voxel_item_generator.gd directly; this wrapper only supplies an
## in-tree host for the SubViewport renderer.

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
