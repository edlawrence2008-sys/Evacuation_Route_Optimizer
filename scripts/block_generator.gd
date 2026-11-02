@tool
class_name BlockGenerator
extends EditorScript


# ============================================================
# CONFIGURATION
# ============================================================

const TEXTURES_FOLDER := "res://textures/blocks/"
const BLOCKS_SCENE_PATH := "res://models/Blocks/blocks.tscn"
const MESH_LIBRARY_PATH := "res://resources/blocks/.tres"
const BLOCK_MESH_LIBRARY_SYNC := preload(
	"res://scripts/block_mesh_library_sync.gd"
)
const BLOCK_UV_MAPPER := preload("res://scripts/block_uv_mapper.gd")

const GENERATED_PREFIX := "Auto_"

## If true, existing Auto_ items are rebuilt when their texture changes.
## If false, existing Auto_ items are skipped.
const UPDATE_EXISTING_BLOCKS := true

## Generates a top and bottom half-slab for every texture.
const GENERATE_SLABS := true

## Generates a simple stair block for every texture.
const GENERATE_STAIRS := true

## Width, height, and depth of every generated full block.
const BLOCK_SIZE := Vector3(1.0, 1.0, 1.0)

## Height of each generated slab.
const SLAB_HEIGHT := BLOCK_SIZE.y * 0.5


# ============================================================
# GENERATION
# ============================================================

## Scans the block textures.
## Generates blocks/slabs/stairs in blocks.tscn, then mirrors the nodes into
## the MeshLibrary used by the GridMap so item meshes and collisions stay in sync.
func _run() -> void:
	var packed_scene: PackedScene = load(BLOCKS_SCENE_PATH)

	if packed_scene == null:
		push_error("Could not load Blocks scene: " + BLOCKS_SCENE_PATH)
		return

	var blocks_root: Node3D = packed_scene.instantiate() as Node3D

	if blocks_root == null:
		push_error("Blocks scene root must be a Node3D.")
		return

	var created_count := 0
	var updated_count := 0

	for file_name: String in DirAccess.get_files_at(TEXTURES_FOLDER):
		if not file_name.ends_with(".png"):
			continue

		var texture_path: String = TEXTURES_FOLDER.path_join(file_name)
		var texture: Texture2D = load(texture_path)

		if texture == null:
			push_warning("Could not load texture: " + texture_path)
			continue

		var base_name: String = file_name.get_basename()

		# Full block, centered in its GridMap cell.
		created_count += _generate_or_update_block(
			blocks_root,
			GENERATED_PREFIX + base_name,
			texture,
			BLOCK_SIZE,
			Vector3.ZERO
		)

		if GENERATE_SLABS:
			updated_count += _generate_or_update_block(
				blocks_root,
				GENERATED_PREFIX + "Slab_Top_" + base_name,
				texture,
				Vector3(BLOCK_SIZE.x, SLAB_HEIGHT, BLOCK_SIZE.z),
				Vector3(0.0, SLAB_HEIGHT * 0.5, 0.0)
			)

			updated_count += _generate_or_update_block(
				blocks_root,
				GENERATED_PREFIX + "Slab_Bottom_" + base_name,
				texture,
				Vector3(BLOCK_SIZE.x, SLAB_HEIGHT, BLOCK_SIZE.z),
				Vector3(0.0, -SLAB_HEIGHT * 0.5, 0.0)
			)

		if GENERATE_STAIRS:
			updated_count += _generate_or_update_stairs(
				blocks_root,
				GENERATED_PREFIX + "Stairs_" + base_name,
				texture
			)

	if created_count == 0 and updated_count == 0:
		var synced_items: int = _sync_mesh_library(blocks_root)
		print(
			"No blocks, slabs, or stairs changed; synced %d MeshLibrary item(s)."
			% synced_items
		)

		blocks_root.queue_free()
		return

	var updated_scene := PackedScene.new()
	var pack_error := updated_scene.pack(blocks_root)

	if pack_error != OK:
		push_error(
			"Failed to pack Blocks scene. Error code: %d"
			% pack_error
		)

		blocks_root.queue_free()
		return

	var save_error := ResourceSaver.save(
		updated_scene,
		BLOCKS_SCENE_PATH
	)

	if save_error != OK:
		push_error(
			"Failed to save Blocks scene. Error code: %d"
			% save_error
		)
	else:
		var synced_items: int = _sync_mesh_library(blocks_root)
		print(
			"Created %d item(s), updated %d item(s), and synced %d MeshLibrary item(s)."
			% [created_count, updated_count, synced_items]
		)

	blocks_root.queue_free()


func _sync_mesh_library(blocks_root: Node3D) -> int:
	var previews := _make_scene_previews(blocks_root)
	return BLOCK_MESH_LIBRARY_SYNC.sync_from_blocks(
		blocks_root,
		MESH_LIBRARY_PATH,
		previews
	)


## Renders the block meshes into preview textures through the editor. This
## keeps the inventory icons as shaded scene previews instead of flat texture
## thumbnails.
func _make_scene_previews(blocks_root: Node3D) -> Dictionary:
	var meshes: Array[Mesh] = []
	var names: Array[String] = []

	for child: Node in blocks_root.get_children():
		var mesh_node := child as MeshInstance3D

		if mesh_node == null or mesh_node.mesh == null:
			continue

		meshes.append(mesh_node.mesh)
		names.append(String(mesh_node.name))

	if meshes.is_empty():
		return {}

	var previews: Array = EditorInterface.make_mesh_previews(meshes, 64)
	var result: Dictionary = {}

	for index in mini(names.size(), previews.size()):
		var preview: Texture2D = previews[index]
		if preview != null:
			result[names[index]] = preview

	return result


func _generate_or_update_block(
	blocks_root: Node3D,
	item_name: String,
	texture: Texture2D,
	size: Vector3,
	local_offset: Vector3
) -> int:
	var existing_block := blocks_root.get_node_or_null(
		NodePath(item_name)
	) as MeshInstance3D

	if existing_block != null:
		if not UPDATE_EXISTING_BLOCKS:
			return 0

		_update_block(existing_block, texture, size, local_offset)
		_set_scene_owner(existing_block, blocks_root)

		return 1

	var block := _create_block(
		item_name,
		texture,
		size,
		local_offset
	)

	blocks_root.add_child(block)
	_set_scene_owner(block, blocks_root)

	return 1


func _generate_or_update_stairs(
	blocks_root: Node3D,
	item_name: String,
	texture: Texture2D
) -> int:
	var existing_stairs := blocks_root.get_node_or_null(
		NodePath(item_name)
	) as MeshInstance3D

	if existing_stairs != null:
		if not UPDATE_EXISTING_BLOCKS:
			return 0

		_update_stairs(existing_stairs, texture)
		_set_scene_owner(existing_stairs, blocks_root)

		return 1

	var stairs := _create_stairs(item_name, texture)

	blocks_root.add_child(stairs)
	_set_scene_owner(stairs, blocks_root)

	return 1


# ============================================================
# BLOCK CREATION
# ============================================================

func _create_block(
	item_name: String,
	texture: Texture2D,
	size: Vector3,
	local_offset: Vector3
) -> MeshInstance3D:
	var block := MeshInstance3D.new()
	block.name = item_name
	block.position = Vector3.ZERO

	block.mesh = _create_block_mesh(texture, size, local_offset)
	block.add_child(_create_block_collision(size, local_offset))

	return block


func _update_block(
	block: MeshInstance3D,
	texture: Texture2D,
	size: Vector3,
	local_offset: Vector3
) -> void:
	block.position = Vector3.ZERO
	block.mesh = _create_block_mesh(texture, size, local_offset)

	var existing_body := block.get_node_or_null(
		NodePath("StaticBody3D")
	) as StaticBody3D

	if existing_body == null:
		block.add_child(_create_block_collision(size, local_offset))
		return

	existing_body.position = Vector3.ZERO

	var existing_collision := existing_body.get_node_or_null(
		NodePath("CollisionShape3D")
	) as CollisionShape3D

	if existing_collision == null:
		existing_collision = CollisionShape3D.new()
		existing_collision.name = "CollisionShape3D"
		existing_body.add_child(existing_collision)

	existing_collision.position = local_offset

	var box_shape := BoxShape3D.new()
	box_shape.size = size

	existing_collision.shape = box_shape


func _create_block_mesh(
	texture: Texture2D,
	size: Vector3,
	local_offset: Vector3
) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size

	var arrays := box.get_mesh_arrays()

	if local_offset != Vector3.ZERO:
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

		for index: int in range(vertices.size()):
			vertices[index] += local_offset

		arrays[Mesh.ARRAY_VERTEX] = vertices

	BLOCK_UV_MAPPER.apply(arrays, BLOCK_SIZE)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := _create_block_material(texture)
	mesh.surface_set_material(0, material)

	return mesh


func _create_block_material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture

	# Keeps 16x16 pixel-art textures sharp.
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.roughness = 1.0
	material.metallic = 0.0

	return material


func _create_block_collision(
	size: Vector3,
	local_offset: Vector3
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "StaticBody3D"
	body.position = Vector3.ZERO

	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape3D"
	collision_shape.position = local_offset

	var box_shape := BoxShape3D.new()
	box_shape.size = size

	collision_shape.shape = box_shape
	body.add_child(collision_shape)

	return body


# ============================================================
# STAIR CREATION
# ============================================================

func _create_stairs(
	item_name: String,
	texture: Texture2D
) -> MeshInstance3D:
	var stairs := MeshInstance3D.new()
	stairs.name = item_name
	stairs.position = Vector3.ZERO

	stairs.mesh = _create_stairs_mesh(texture)
	stairs.add_child(_create_stairs_collision())

	return stairs


func _update_stairs(
	stairs: MeshInstance3D,
	texture: Texture2D
) -> void:
	stairs.position = Vector3.ZERO
	stairs.mesh = _create_stairs_mesh(texture)

	var existing_body := stairs.get_node_or_null(
		NodePath("StaticBody3D")
	) as StaticBody3D

	# The step collision must be rebuilt, not just moved: an older generation
	# may have left it at a different block size, which makes the no-hit collider
	# stick out past the visual face and breaks adjacent placement.
	if existing_body != null:
		stairs.remove_child(existing_body)
		existing_body.free()

	stairs.add_child(_create_stairs_collision())


func _create_stairs_mesh(texture: Texture2D) -> ArrayMesh:
	var mesh := ArrayMesh.new()

	var material := _create_block_material(texture)

	# Back half: full-height section.
	var back_arrays := _create_offset_box_arrays(
		Vector3(
			BLOCK_SIZE.x,
			BLOCK_SIZE.y,
			BLOCK_SIZE.z * 0.5
		),
		Vector3(
			0.0,
			0.0,
			-BLOCK_SIZE.z * 0.25
		)
	)

	mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES,
		back_arrays
	)
	mesh.surface_set_material(0, material)

	# Front half: lower step.
	var front_arrays := _create_offset_box_arrays(
		Vector3(
			BLOCK_SIZE.x,
			SLAB_HEIGHT,
			BLOCK_SIZE.z * 0.5
		),
		Vector3(
			0.0,
			-SLAB_HEIGHT * 0.5,
			BLOCK_SIZE.z * 0.25
		)
	)

	mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES,
		front_arrays
	)
	mesh.surface_set_material(1, material)

	return mesh


func _create_stairs_collision() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "StaticBody3D"
	body.position = Vector3.ZERO

	# Back half: full-height collision.
	var back_shape := CollisionShape3D.new()
	back_shape.name = "BackCollision"
	back_shape.position = Vector3(
		0.0,
		0.0,
		-BLOCK_SIZE.z * 0.25
	)

	var back_box := BoxShape3D.new()
	back_box.size = Vector3(
		BLOCK_SIZE.x,
		BLOCK_SIZE.y,
		BLOCK_SIZE.z * 0.5
	)

	back_shape.shape = back_box
	body.add_child(back_shape)

	# Front half: lower-step collision.
	var front_shape := CollisionShape3D.new()
	front_shape.name = "FrontCollision"
	front_shape.position = Vector3(
		0.0,
		-SLAB_HEIGHT * 0.5,
		BLOCK_SIZE.z * 0.25
	)

	var front_box := BoxShape3D.new()
	front_box.size = Vector3(
		BLOCK_SIZE.x,
		SLAB_HEIGHT,
		BLOCK_SIZE.z * 0.5
	)

	front_shape.shape = front_box
	body.add_child(front_shape)

	return body


func _create_offset_box_arrays(
	size: Vector3,
	offset: Vector3
) -> Array:
	var box := BoxMesh.new()
	box.size = size

	var arrays: Array = box.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

	for index: int in range(vertices.size()):
		vertices[index] += offset

	arrays[Mesh.ARRAY_VERTEX] = vertices
	BLOCK_UV_MAPPER.apply(arrays, BLOCK_SIZE)

	return arrays


# ============================================================
# SCENE OWNERSHIP
# ============================================================

func _set_scene_owner(node: Node, scene_root: Node) -> void:
	node.owner = scene_root

	for child: Node in node.get_children():
		_set_scene_owner(child, scene_root)
