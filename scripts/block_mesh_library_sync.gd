class_name BlockMeshLibrarySync
extends RefCounted

const COLOR_PALETTE := preload("res://scripts/color_palette_db.gd")

## Mirrors the nodes in models/Blocks/blocks.tscn into the MeshLibrary used by
## the GridMap. Existing item IDs are preserved by matching item names; new
## nodes are appended with fresh IDs. Existing previews and navigation data are
## left untouched.

static func sync_from_blocks(
	blocks_root: Node3D,
	library_path: String,
	scene_previews: Dictionary = {}
) -> int:
	if blocks_root == null:
		return 0

	if not FileAccess.file_exists(library_path):
		push_error("MeshLibrary not found: " + library_path)
		return 0

	var library := load(library_path) as MeshLibrary

	if library == null:
		push_error("Could not load MeshLibrary: " + library_path)
		return 0

	var name_to_id: Dictionary = {}
	var next_id: int = 0

	for id: int in library.get_item_list():
		name_to_id[String(library.get_item_name(id))] = id
		next_id = maxi(next_id, id + 1)

	var synced: int = 0

	for child: Node in blocks_root.get_children():
		var mesh_node := child as MeshInstance3D

		if mesh_node == null or mesh_node.mesh == null:
			continue

		var item_name := String(mesh_node.name)
		var item_id: int = int(name_to_id.get(item_name, -1))

		if item_id == -1:
			item_id = next_id
			next_id += 1
			library.create_item(item_id)
			name_to_id[item_name] = item_id

		library.set_item_name(item_id, item_name)
		library.set_item_mesh(item_id, mesh_node.mesh)
		library.set_item_mesh_transform(item_id, mesh_node.transform)
		library.set_item_shapes(item_id, _collect_mesh_shapes(mesh_node))

		var preview := library.get_item_preview(item_id)

		if scene_previews.has(item_name):
			var scene_preview: Texture2D = scene_previews[item_name]
			if scene_preview != null:
				library.set_item_preview(item_id, scene_preview)
		elif (
			preview == null
			or preview.get_width() != 64
			or preview.get_height() != 64
		):
			var generated_preview := _make_texture_preview(
				item_name,
				library
			)
			if generated_preview != null:
				library.set_item_preview(item_id, generated_preview)

		synced += 1

	var save_error := ResourceSaver.save(library, library_path)

	if save_error != OK:
		push_error(
			"Failed to save MeshLibrary. Error code: %d"
			% save_error
		)
		return 0

	return synced


## Fallback preview for newly generated items. Existing authored previews are
## left untouched; new items get a nearest-filtered 64×64 copy of their texture.
## Upside-down stairs reuse the matching normal stair preview, flipped vertically,
## so a headless generation still gets a readable stair icon.
static func _make_texture_preview(
	item_name: String,
	library: MeshLibrary = null
) -> Texture2D:
	var base := item_name.trim_prefix("Auto_")

	if library != null and "Stairs_UpsideDown_" in item_name:
		var normal_name := item_name.replace(
			"Stairs_UpsideDown_",
			"Stairs_"
		)
		for id: int in library.get_item_list():
			if String(library.get_item_name(id)) != normal_name:
				continue
			var normal_preview := library.get_item_preview(id)
			if normal_preview == null:
				break
			var image := normal_preview.get_image()
			if image == null:
				break
			image = image.duplicate()
			if image.is_compressed():
				if image.decompress() != OK:
					break
			image.flip_y()
			return ImageTexture.create_from_image(image)

	for prefix in [
		"Slab_Bottom_",
		"Slab_Side_",
		"Slab_Top_",
		"Panel_Bottom_",
		"Panel_Side_",
		"Panel_Top_",
		"Stairs_UpsideDown_",
		"Stairs_",
	]:
		if base.begins_with(prefix):
			base = base.trim_prefix(prefix)
			break

	var color_index := COLOR_PALETTE.color_index(base)
	if color_index >= 0:
		base = base.substr(0, base.length() - 4)

	var auto_base := base.trim_prefix("Connect_")
	var candidates: Array[String] = [
		"res://textures/autoblocks/" + base + ".png",
		"res://textures/auto_connecting_blocks/" + auto_base + ".png",
	]
	var texture: Texture2D = null

	for path in candidates:
		if not FileAccess.file_exists(path):
			continue
		texture = load(path) as Texture2D
		if texture != null:
			break
		var raw := Image.new()
		if raw.load(path) == OK:
			texture = ImageTexture.create_from_image(raw)
			break

	if texture == null:
		return null

	var image := texture.get_image()

	if image == null:
		return null

	image = image.duplicate()

	if image.is_compressed():
		var decompress_error := image.decompress()
		if decompress_error != OK:
			return null

	image.convert(Image.FORMAT_RGBA8)
	if color_index >= 0:
		image = COLOR_PALETTE.tint_image(
			image,
			COLOR_PALETTE.color_at(color_index)
		)
		if image == null:
			return null
	image.resize(64, 64, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(image)


static func _collect_mesh_shapes(mesh_node: MeshInstance3D) -> Array:
	var shapes: Array = []

	for child: Node in mesh_node.get_children():
		var body := child as StaticBody3D

		if body == null:
			continue

		for body_child: Node in body.get_children():
			var shape_node := body_child as CollisionShape3D

			if shape_node == null or shape_node.shape == null:
				continue

			shapes.append(shape_node.shape)
			shapes.append(body.transform * shape_node.transform)

	return shapes
