@tool
class_name FoliageSceneGenerator
extends EditorScript

## Scans the foliage textures and generates one placeable scene per texture.
## Run it from the editor (Script > Run) or call generate_all() from a tool script.
## Textures ending with "_billboard" use one fixed-Y Sprite3D; every other
## texture uses two crossed Sprite3D quads (Minecraft-style grass/plant cross).
## One texture pixel equals one block-texture pixel.

const TEXTURES_FOLDER := "res://textures/placeables/foilage/"
const OUTPUT_FOLDER := "res://scenes/placeables/foilage/"
const SCENE_PREFIX := "foliage_"

const UPDATE_EXISTING := true

const VOXEL_SIZE := 1.0
const VOXEL_TEXTURE_SIZE := 16
const PIXEL_SIZE := VOXEL_SIZE / float(VOXEL_TEXTURE_SIZE)

const SHADED := true


func _run() -> void:
	generate_all()


static func generate_all() -> void:
	if not DirAccess.dir_exists_absolute(TEXTURES_FOLDER):
		push_error("Foliage texture folder not found: " + TEXTURES_FOLDER)
		return

	if not DirAccess.dir_exists_absolute(OUTPUT_FOLDER):
		var make_error := DirAccess.make_dir_recursive_absolute(
			OUTPUT_FOLDER
		)
		if make_error != OK:
			push_error(
				"Could not create foliage output folder: " + OUTPUT_FOLDER
			)
			return

	var files := DirAccess.get_files_at(TEXTURES_FOLDER)
	files.sort()

	var created := 0
	var updated := 0
	var expected_scenes: Dictionary = {}

	for file_name: String in files:
		if not file_name.ends_with(".png"):
			continue

		var texture_path := TEXTURES_FOLDER.path_join(file_name)
		var texture := load(texture_path) as Texture2D

		if texture == null:
			push_warning("Could not load foliage texture: " + texture_path)
			continue

		var clean_name := file_name.get_basename().trim_prefix("foilage_")
		var scene_stem := SCENE_PREFIX + clean_name
		var output_path := OUTPUT_FOLDER.path_join(scene_stem + ".tscn")
		var exists := FileAccess.file_exists(output_path)
		expected_scenes[output_path] = true

		if exists and not UPDATE_EXISTING:
			continue

		if _build_scene(texture, scene_stem, output_path):
			if exists:
				updated += 1
			else:
				created += 1

	_remove_stale_scenes(expected_scenes)
	print("Foliage scenes: created %d, updated %d." % [created, updated])


static func _build_scene(
	texture: Texture2D,
	scene_stem: String,
	output_path: String
) -> bool:
	var root: Node3D = null

	if FileAccess.file_exists(output_path):
		var existing := load(output_path) as PackedScene
		if existing != null:
			root = existing.instantiate() as Node3D

	if root == null:
		root = Node3D.new()

	root.name = scene_stem
	root.add_to_group("placeables")
	root.add_to_group("foliage")

	var is_billboard := scene_stem.to_lower().ends_with("_billboard")
	_ensure_sprites(root, texture, is_billboard)
	_ensure_selection_area(root)
	_set_scene_owner(root, root)

	var packed := PackedScene.new()
	var pack_error := packed.pack(root)

	if pack_error != OK:
		push_error(
            "Could not pack foliage scene %s: %d"
			% [scene_stem, pack_error]
		)
		root.free()
		return false

	var save_error := ResourceSaver.save(packed, output_path)
	root.free()

	if save_error != OK:
		push_error(
            "Could not save foliage scene %s: %d"
			% [output_path, save_error]
		)
		return false

	_write_root_groups(output_path, scene_stem)
	return true


## PackedScene.pack() does not persist root group membership in this Godot
## build, so add the two groups directly to the saved root node header.
static func _remove_stale_scenes(expected_scenes: Dictionary) -> void:
	if expected_scenes.is_empty():
		return

	if not DirAccess.dir_exists_absolute(OUTPUT_FOLDER):
		return

	var files := DirAccess.get_files_at(OUTPUT_FOLDER)

	for file_name: String in files:
		if not file_name.ends_with(".tscn"):
			continue

		var path := OUTPUT_FOLDER.path_join(file_name)

		if expected_scenes.has(path):
			continue

		DirAccess.remove_absolute(path)
		print("Removed stale foliage scene: " + file_name)


static func _write_root_groups(output_path: String, scene_stem: String) -> void:
	var file := FileAccess.open(output_path, FileAccess.READ)

	if file == null:
		return

	var lines := file.get_as_text().split("\n")
	file.close()

	var root_prefix := '[node name="%s"' % scene_stem

	for index in lines.size():
		if not lines[index].begins_with(root_prefix):
			continue

		if lines[index].contains("groups="):
			return

		lines[index] = (
			lines[index].substr(0, lines[index].length() - 1)
			+ ' groups=["placeables", "foliage"]'
			+ "]"
		)
		break

	file = FileAccess.open(output_path, FileAccess.WRITE)

	if file == null:
		return

	file.store_string("\n".join(lines))
	file.close()


static func _ensure_sprites(
	root: Node3D,
	texture: Texture2D,
	billboard: bool
) -> void:
	var old_sprites: Array[Node] = []

	for child in root.get_children():
		if child is Sprite3D:
			old_sprites.append(child)

	for sprite in old_sprites:
		root.remove_child(sprite)
		sprite.free()

	if billboard:
		root.add_child(_make_sprite("Sprite3D", texture, 0.0, true))
		return

	var random_yaw := randf_range(0.0, TAU)
	root.add_child(
		_make_sprite("Sprite3D_A", texture, random_yaw + PI * 0.25, false)
	)
	root.add_child(
		_make_sprite("Sprite3D_B", texture, random_yaw - PI * 0.25, false)
	)


static func _make_sprite(
	node_name: String,
	texture: Texture2D,
	yaw: float,
	billboard: bool
) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.name = node_name
	sprite.texture = texture
	sprite.pixel_size = PIXEL_SIZE
	sprite.centered = true
	sprite.billboard = (
		BaseMaterial3D.BILLBOARD_FIXED_Y
		if billboard
		else BaseMaterial3D.BILLBOARD_DISABLED
	)
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.shaded = SHADED
	sprite.double_sided = true
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	sprite.rotation.y = yaw

	var world_height := float(texture.get_height()) * PIXEL_SIZE
	sprite.position = Vector3(0.0, world_height * 0.5, 0.0)

	return sprite


static func _ensure_selection_area(root: Node3D) -> void:
	var area := root.get_node_or_null("SelectionArea") as Area3D

	if area == null:
		area = Area3D.new()
		area.name = "SelectionArea"
		root.add_child(area)

	area.collision_layer = 7
	area.collision_mask = 3
	area.monitoring = false

	var shape_node := area.get_node_or_null(
        "CollisionShape3D"
	) as CollisionShape3D

	if shape_node == null:
		shape_node = CollisionShape3D.new()
		shape_node.name = "CollisionShape3D"
		area.add_child(shape_node)

	var box := BoxShape3D.new()
	box.size = Vector3(VOXEL_SIZE, VOXEL_SIZE, VOXEL_SIZE)
	shape_node.shape = box
	shape_node.position = Vector3(0.0, VOXEL_SIZE * 0.5, 0.0)


static func _set_scene_owner(node: Node, scene_root: Node) -> void:
	if node != scene_root:
		node.owner = scene_root

	for child: Node in node.get_children():
		_set_scene_owner(child, scene_root)
