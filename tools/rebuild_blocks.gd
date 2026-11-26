extends SceneTree

## Headless wrapper around the editor block generator. Run it after adding or
## changing a texture in `res://textures/autoblocks/`:
##
##   godot --headless --path . --script res://tools/rebuild_blocks.gd
##
## It rewrites `models/Blocks/blocks.tscn` and the MeshLibrary. Gameplay code
## resolves blocks by name through `BlockIds`, so no item ids are hardcoded.

const BLOCK_GENERATOR = preload("res://scripts/block_generator.gd")
const BLOCK_IDS = preload("res://scripts/world/block_ids.gd")


func _initialize() -> void:
	print("=== rebuild blocks ===")
	var result: Variant = BLOCK_GENERATOR.generate_all()
	print("result: ", result)

	BLOCK_IDS.reload()
	var bedrock: int = BLOCK_IDS.bedrock_id()
	print("bedrock item: %d (%s)" % [bedrock, BLOCK_IDS.item_name(bedrock)])
	quit()
