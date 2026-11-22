@tool
extends EditorPlugin

## Editor entry points for the content generators.
##
## These generators write project assets (`models/Blocks/blocks.tscn`,
## `resources/blocks/.tres`, foliage scenes and voxel item icons), so they are
## deliberately editor-side tools rather than runtime buttons. The menu lives
## under Project > Tools and is available whenever this plugin is enabled.
##
## Every generator exposes a static entry point, so the menu never has to
## instantiate an `EditorScript` (which is restricted to the editor context).

const BLOCK_GENERATOR := preload("res://scripts/block_generator.gd")
const CONNECTED_GENERATOR := preload("res://scripts/connected_block_generator.gd")
const FOLIAGE_GENERATOR := preload("res://scripts/foliage_generator.gd")
const VOXEL_ITEMS := preload("res://scripts/voxel_item_generator.gd")

const MENU_BLOCKS := "Content: Generate Blocks (autoblocks)"
const MENU_CONNECTED := "Content: Generate Connected Blocks"
const MENU_FOLIAGE := "Content: Generate Foliage Scenes"
const MENU_VOXEL := "Content: Generate Voxel Item Icons"


func _enter_tree() -> void:
	add_tool_menu_item(MENU_BLOCKS, _generate_blocks)
	add_tool_menu_item(MENU_CONNECTED, _generate_connected_blocks)
	add_tool_menu_item(MENU_FOLIAGE, _generate_foliage)
	add_tool_menu_item(MENU_VOXEL, _generate_voxel_items)
	print("Content Generators: ready (Project > Tools).")


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_BLOCKS)
	remove_tool_menu_item(MENU_CONNECTED)
	remove_tool_menu_item(MENU_FOLIAGE)
	remove_tool_menu_item(MENU_VOXEL)


func _generate_blocks() -> void:
	print("Content generators: blocks...")
	var result: Dictionary = BLOCK_GENERATOR.generate_all()
	_report("blocks", result)


func _generate_connected_blocks() -> void:
	print("Content generators: connected blocks...")
	var result: Dictionary = CONNECTED_GENERATOR.generate_runtime()
	_report("connected blocks", result)


func _generate_foliage() -> void:
	print("Content generators: foliage scenes...")
	FOLIAGE_GENERATOR.generate_all()
	print("Content generators: foliage finished.")


func _generate_voxel_items() -> void:
	print("Content generators: voxel item icons...")
	var host: Node = EditorInterface.get_base_control()
	var result: Dictionary = await VOXEL_ITEMS.generate_all(host)
	_report("voxel items", result)


func _report(label: String, result: Dictionary) -> void:
	if result.has("error"):
		push_error("Content generators: %s failed: %s" % [
			label,
			String(result["error"]),
		])
		return

	for message: String in result.get("errors", []):
		push_warning("Content generators: %s: %s" % [label, message])

	var parts: Array[String] = []

	for key: String in ["textures", "variants", "created", "updated", "synced"]:
		if result.has(key):
			parts.append("%s=%d" % [key, int(result[key])])

	var added: Variant = result.get("generated", result.get("added", null))

	if added is Array:
		parts.append("entries=%d" % (added as Array).size())

	print("Content generators: %s finished (%s)." % [
		label,
		", ".join(parts),
	])
