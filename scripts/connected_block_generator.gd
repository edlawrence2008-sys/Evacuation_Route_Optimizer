class_name ConnectedBlockGenerator
extends RefCounted

## Generates connected-texture block items from textures in
## textures/auto_connecting_blocks. One visible base item is created per
## texture; the world mesher selects the CTM tile from the item's 8-neighbour
## mask, so there are no per-state inventory items.

const TEXTURES_FOLDER := "res://textures/auto_connecting_blocks/"
const BLOCKS_SCENE_PATH := "res://models/Blocks/blocks.tscn"
const MESH_LIBRARY_PATH := "res://resources/blocks/.tres"
const SYNC_SCRIPT := preload("res://scripts/block_mesh_library_sync.gd")
const CTM_BUILDER := preload("res://scripts/connected_texture_builder.gd")
const ITEM_PREFIX := "Auto_Connect_"


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

	for entry in _scan_textures():
		var base_name: String = entry["base"]
		var texture := _load_texture(String(entry["path"]))
		if texture == null:
			continue

		var item_name := ITEM_PREFIX + base_name
		var display := _make_display_texture(texture)
		var node := _create_item(item_name, display)
		blocks_root.add_child(node)
		node.owner = blocks_root
		added.append(item_name)
		previews[item_name] = _make_preview(display)

	var scene := PackedScene.new()
	if scene.pack(blocks_root) != OK:
		blocks_root.free()
		return {"error": "Failed to pack blocks scene"}

	if ResourceSaver.save(scene, BLOCKS_SCENE_PATH) != OK:
		blocks_root.free()
		return {"error": "Failed to save blocks scene"}

	_clean_old_library_items()
	var synced := SYNC_SCRIPT.sync_from_blocks(
		blocks_root,
		MESH_LIBRARY_PATH,
		previews
	)
	blocks_root.free()
	return {"added": added, "synced": synced}


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


static func _clean_old_library_items() -> void:
	if not FileAccess.file_exists(MESH_LIBRARY_PATH):
		return
	var library := load(MESH_LIBRARY_PATH) as MeshLibrary
	if library == null:
		return

	var remove_ids: PackedInt32Array = PackedInt32Array()
	for id: int in library.get_item_list():
		var item_name := String(library.get_item_name(id))
		if (
			item_name.begins_with(ITEM_PREFIX)
			or item_name.begins_with("Auto_Stairs_Connect_")
		):
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


static func _make_material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.15
	material.metallic = 0.0
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
static func _make_display_texture(texture: Texture2D) -> Texture2D:
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
	tile.blit_rect(atlas, Rect2i(0, 0, size, size), Vector2i.ZERO)
	return ImageTexture.create_from_image(tile)


static func _load_texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path, "Texture2D"):
		return load(path) as Texture2D
	var image := Image.new()
	if image.load(path) == OK:
		return ImageTexture.create_from_image(image)
	return null
