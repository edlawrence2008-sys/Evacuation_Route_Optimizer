@tool
class_name ConnectedBlockGenerator
extends EditorScript

## Generates connected-texture block items from textures in
## textures/auto_connecting_blocks. One visible base item is created per
## texture; the world mesher selects the CTM tile from the item's 8-neighbour
## mask, so there are no per-state inventory items.
##
## Editor entry point: File > Run on this script, or
## Project > Tools > Content: Generate Connected Blocks. The plugin calls
## generate_runtime() directly so it never has to instantiate an EditorScript.

const TEXTURES_FOLDER := "res://textures/auto_connecting_blocks/"
const BLOCKS_SCENE_PATH := "res://models/Blocks/blocks.tscn"
const MESH_LIBRARY_PATH := "res://resources/blocks/.tres"
const SYNC_SCRIPT := preload("res://scripts/block_mesh_library_sync.gd")
const CTM_BUILDER := preload("res://scripts/connected_texture_builder.gd")
const COLOR_PALETTE := preload("res://scripts/color_palette_db.gd")
const ITEM_PREFIX := "Auto_Connect_"


## File > Run entry point.
func _run() -> void:
	var result := generate_runtime()
	if result.has("error"):
		push_error("Connected blocks: " + String(result["error"]))
		return
	var added: Array = result.get("added", [])
	print("Connected blocks: %d item(s), %d MeshLibrary item(s) synced." % [
		added.size(),
		int(result.get("synced", 0)),
	])


static func generate_runtime() -> Dictionary:
	var packed := load(BLOCKS_SCENE_PATH) as PackedScene
	if packed == null:
		return {"error": "Could not load blocks scene"}

	var blocks_root := packed.instantiate() as Node3D
	if blocks_root == null:
		return {"error": "Blocks scene root is not a Node3D"}

	for child: Node in blocks_root.get_children():
		if String(child.name).begins_with(ITEM_PREFIX):
			blocks_root.remove_child(child)
			child.free()

	var added: Array[String] = []
	var previews: Dictionary = {}
	var colors := COLOR_PALETTE.colors()

	for entry in _scan_textures():
		var base_name: String = entry["base"]
		var texture := _load_texture(String(entry["path"]))
		if texture == null:
			continue

		var display := _make_display_texture(texture, 0)
		var surface := _make_display_texture(texture, 255)

		# Keep the uncolored set so existing saves keep resolving it, then add
		# one tinted full/slab/stair set per palette color. The atlas material
		# stays shared and is tinted per color at runtime.
		_add_connected_set(
			blocks_root,
			base_name,
			display,
			surface,
			added,
			previews
		)

		if base_name.ends_with("_colorbase"):
			for index in colors.size():
				var color: Color = colors[index]
				var suffix := "_c%02d" % index
				_add_connected_set(
					blocks_root,
					base_name + suffix,
					_tint_texture(display, color),
					_tint_texture(surface, color),
					added,
					previews
				)

	var scene := PackedScene.new()
	if scene.pack(blocks_root) != OK:
		blocks_root.free()
		return {"error": "Failed to pack blocks scene"}

	if ResourceSaver.save(scene, BLOCKS_SCENE_PATH) != OK:
		blocks_root.free()
		return {"error": "Failed to save blocks scene"}

	# Preserve IDs for every name that is still generated; only stale managed
	# items are removed. Saved chunks store MeshLibrary IDs, so re-creating all
	# CTM items on every run would silently break existing worlds.
	_clean_old_library_items(added)
	var synced := SYNC_SCRIPT.sync_from_blocks(
		blocks_root,
		MESH_LIBRARY_PATH,
		previews
	)
	blocks_root.free()
	return {"added": added, "synced": synced}


## Adds the full block plus its top/bottom/side slab and normal/upside-down
## stair variants for one texture set.
static func _add_connected_set(
	blocks_root: Node3D,
	item_base: String,
	display: Texture2D,
	surface: Texture2D,
	added: Array[String],
	previews: Dictionary
) -> void:
	var item_name := ITEM_PREFIX + item_base
	var node := _create_item(item_name, display)
	blocks_root.add_child(node)
	node.owner = blocks_root
	added.append(item_name)
	previews[item_name] = _make_preview(display)

	# Slabs and stairs use the connected texture's interior tile as their
	# preview/fallback material. In the world the mesher overrides it with the
	# shared CTM atlas and computes per-face border masks.
	var variants: Array = [
		[
			ITEM_PREFIX + "Slab_Top_" + item_base,
			BlockGenerator._create_block_mesh(
				surface,
				Vector3(1.0, 0.5, 1.0),
				Vector3(0.0, 0.25, 0.0)
			),
			BlockGenerator._create_block_collision(
				Vector3(1.0, 0.5, 1.0),
				Vector3(0.0, 0.25, 0.0)
			),
		],
		[
			ITEM_PREFIX + "Slab_Bottom_" + item_base,
			BlockGenerator._create_block_mesh(
				surface,
				Vector3(1.0, 0.5, 1.0),
				Vector3(0.0, -0.25, 0.0)
			),
			BlockGenerator._create_block_collision(
				Vector3(1.0, 0.5, 1.0),
				Vector3(0.0, -0.25, 0.0)
			),
		],
		[
			ITEM_PREFIX + "Slab_Side_" + item_base,
			BlockGenerator._create_block_mesh(
				surface,
				Vector3(0.5, 1.0, 1.0),
				Vector3(0.25, 0.0, 0.0)
			),
			BlockGenerator._create_block_collision(
				Vector3(0.5, 1.0, 1.0),
				Vector3(0.25, 0.0, 0.0)
			),
		],
		[
			ITEM_PREFIX + "Stairs_" + item_base,
			BlockGenerator._create_stairs_mesh(surface, false),
			BlockGenerator._create_stairs_collision(false),
		],
		[
			ITEM_PREFIX + "Stairs_UpsideDown_" + item_base,
			BlockGenerator._create_stairs_mesh(surface, true),
			BlockGenerator._create_stairs_collision(true),
		],
	]

	for variant: Array in variants:
		var variant_name: String = variant[0]
		var variant_node := _create_mesh_item(
			variant_name,
			variant[1],
			variant[2]
		)
		blocks_root.add_child(variant_node)
		variant_node.owner = blocks_root
		added.append(variant_name)
		previews[variant_name] = _make_preview(surface)


static func _tint_texture(texture: Texture2D, color: Color) -> Texture2D:
	var image := texture.get_image()
	if image == null:
		return texture
	var tinted := COLOR_PALETTE.tint_image_multiplicative(image, color)
	if tinted == null:
		return texture
	return ImageTexture.create_from_image(tinted)


static func _scan_textures() -> Array:
	var result: Array = []
	for file_name: String in DirAccess.get_files_at(TEXTURES_FOLDER):
		if not file_name.ends_with(".png"):
			continue
		result.append({
			"base": file_name.get_basename(),
			"path": TEXTURES_FOLDER + file_name,
		})
	return result


static func _clean_old_library_items(keep_names: Array = []) -> void:
	if not FileAccess.file_exists(MESH_LIBRARY_PATH):
		return
	var library := load(MESH_LIBRARY_PATH) as MeshLibrary
	if library == null:
		return

	var keep: Dictionary = {}
	for item_name: Variant in keep_names:
		keep[String(item_name)] = true

	var remove_ids: PackedInt32Array = PackedInt32Array()
	for id: int in library.get_item_list():
		var item_name := String(library.get_item_name(id))
		var managed := (
			item_name.begins_with(ITEM_PREFIX)
			or item_name.begins_with("Auto_Stairs_Connect_")
		)
		if managed and not keep.has(item_name):
			remove_ids.append(id)

	# Remove from the highest id down: MeshLibrary shifts ids when an item is
	# removed, so ascending removal would delete the wrong entries.
	for index in range(remove_ids.size() - 1, -1, -1):
		library.remove_item(remove_ids[index])

	ResourceSaver.save(library, MESH_LIBRARY_PATH)


static func _create_item(
	item_name: String,
	texture: Texture2D
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = item_name

	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var arrays := box.get_mesh_arrays()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _make_material(texture))
	node.mesh = mesh

	var body := StaticBody3D.new()
	body.name = "StaticBody3D"
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE
	collision.shape = shape
	body.add_child(collision)
	node.add_child(body)

	return node


static func _create_mesh_item(
	item_name: String,
	mesh: Mesh,
	body: StaticBody3D
) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = item_name
	node.mesh = mesh
	body.name = "StaticBody3D"
	node.add_child(body)
	return node


static func _make_material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_BACK
	material.roughness = 0.15
	material.metallic = 0.0

	var image := texture.get_image()
	if image != null:
		match image.detect_alpha():
			Image.ALPHA_BLEND:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			Image.ALPHA_BIT:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				material.alpha_scissor_threshold = 0.5
			_:
				material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	return material


static func _make_preview(texture: Texture2D) -> Texture2D:
	var image := texture.get_image()
	if image == null:
		return null
	image = image.duplicate()
	if image.is_compressed():
		if image.decompress() != OK:
			return null
	image.convert(Image.FORMAT_RGBA8)
	image.resize(64, 64, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(image)


## Builds the isolated-cell tile (atlas tile 0) so the held item and inventory
## preview show one finished pane instead of the four-quadrant source layout.
static func _make_display_texture(
	texture: Texture2D,
	mask: int = 0
) -> Texture2D:
	var image := texture.get_image()
	if image == null:
		return texture
	image = image.duplicate()
	if image.is_compressed():
		if image.decompress() != OK:
			return texture
	image.convert(Image.FORMAT_RGBA8)

	var atlas := CTM_BUILDER.build_atlas_image(image)
	if atlas == null:
		return texture

	var size := image.get_height()
	var tile := Image.create(size, size, false, Image.FORMAT_RGBA8)
	tile.blit_rect(
		atlas,
		Rect2i(
			(mask % 16) * size,
			int(mask / 16) * size,
			size,
			size
		),
		Vector2i.ZERO
	)
	return ImageTexture.create_from_image(tile)


static func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path, "Texture2D"):
		return load(path) as Texture2D
	var image := Image.new()
	if image.load(path) == OK:
		return ImageTexture.create_from_image(image)
	return null
