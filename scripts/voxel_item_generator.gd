class_name VoxelItemGenerator
extends RefCounted

## Generates Minecraft-style isometric item icons for non-block placeables.
##
## This is the shared implementation, not the editor tool. It is a plain
## `RefCounted` because gameplay code (`hand_item.gd`, `hud.gd`) preloads it for
## the runtime lookups (`icon_for_scene`, `entry_for_scene`). To generate icons,
## run `scripts/voxel_item_generator_editor.gd` or use
## Project > Tools > Content: Generate Voxel Item Icons.
##
## Each icon is rendered from the scene's own meshes/sprites through a
## SubViewport, so it keeps the object's silhouette and materials. The icons
## live in resources/voxel_items/ and are indexed by resources/voxel_items.json.
## Other generators can call `generate_for_scene()` / `generate_all()` and the
## runtime lookups stay shared.

const OUTPUT_DIR := "res://resources/voxel_items/"
const MANIFEST_PATH := "res://resources/voxel_items.json"
const ICON_SIZE := 64
const ITEM_MESH_SUFFIX := "_item"
const SOURCE_FOLDERS: Array[String] = [
	"res://scenes/placeables/sim/",
	"res://scenes/placeables/device/",
	"res://scenes/placeables/foilage/",
	"res://scenes/placeables/env/",
]

static var _manifest: Dictionary = {}
static var _manifest_loaded := false
static var _icon_cache: Dictionary = {}
static var _mesh_cache: Dictionary = {}


## Renders one icon and writes it next to the manifest. `host` must be in the
## scene tree (any Node) because the SubViewport needs frames to render.
static func generate_for_scene(
	host: Node,
	scene_path: String,
	output_dir: String = OUTPUT_DIR
) -> Dictionary:
	if host == null or not host.is_inside_tree():
		return {"error": "host must be inside the tree"}
	var scene := load(scene_path) as PackedScene
	if scene == null:
		return {"error": "could not load " + scene_path}

	var icon := await render_icon(host, scene)
	if icon == null:
		return {"error": "could not render " + scene_path}

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(output_dir)
	)
	var base := scene_path.get_file().get_basename()
	var icon_path := output_dir.path_join(base + ".tres")
	if ResourceSaver.save(icon, icon_path) != OK:
		return {"error": "could not save " + icon_path}

	var viewmodel := "scene"
	var mesh_path := ""
	var lower_path := scene_path.to_lower()
	if lower_path.contains("/foilage/") or lower_path.contains("/foliage/"):
		viewmodel = "extruded"
		var source_texture := find_source_texture(scene)
		if source_texture != null:
			var item_mesh := extruded_mesh_for_texture(
				source_texture,
				scene_path
			)
			if item_mesh != null:
				mesh_path = output_dir.path_join(base + ITEM_MESH_SUFFIX + ".res")
				if ResourceSaver.save(item_mesh, mesh_path) != OK:
					mesh_path = ""

	return {
		"scene": scene_path,
		"icon": icon_path,
		"viewmodel": viewmodel,
		"mesh": mesh_path,
	}


static func generate_all(
	host: Node,
	output_dir: String = OUTPUT_DIR,
	manifest_path: String = MANIFEST_PATH
) -> Dictionary:
	var entries: Dictionary = {}
	var generated: Array[String] = []
	var errors: Array[String] = []

	for folder: String in SOURCE_FOLDERS:
		if not DirAccess.dir_exists_absolute(folder):
			continue
		var files := DirAccess.get_files_at(folder)
		files.sort()
		for file_name: String in files:
			if not file_name.ends_with(".tscn"):
				continue
			var scene_path: String = folder.path_join(file_name)
			var result: Dictionary = await generate_for_scene(
				host,
				scene_path,
				output_dir
			)
			if result.has("error"):
				errors.append(String(result["error"]))
				continue
			entries[scene_path] = result
			generated.append(scene_path)

	var manifest := {
		"version": 1,
		"items": entries,
	}
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	if file == null:
		errors.append("could not write " + manifest_path)
	else:
		file.store_string(JSON.stringify(manifest, "\t"))
		file.close()

	_manifest = manifest
	_manifest_loaded = true
	_icon_cache.clear()
	return {
		"generated": generated,
		"errors": errors,
	}


## Renders a scene to a transparent isometric icon using a SubViewport.
static func render_icon(
	host: Node,
	scene: PackedScene,
	icon_size: int = ICON_SIZE
) -> Texture2D:
	if scene == null or host == null or not host.is_inside_tree():
		return null

	var viewport := SubViewport.new()
	viewport.size = Vector2i(icon_size, icon_size)
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	host.add_child(viewport)

	var holder := build_visual_holder(scene)
	viewport.add_child(holder)
	_fit_holder(holder, 1.55)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.9, 0.9, 0.9)
	environment.ambient_light_energy = 0.65
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	viewport.add_child(world_environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
	light.light_energy = 1.15
	viewport.add_child(light)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position = Vector3(2.3, 1.9, 2.3)
	camera.look_at_from_position(camera.position, Vector3.ZERO, Vector3.UP)
	camera.current = true
	viewport.add_child(camera)

	# Let the renderer produce at least one full frame.
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	if image == null or image.get_width() <= 0:
		return null
	return ImageTexture.create_from_image(image)


## Copies renderable nodes from a scene without adding the scene to the tree,
## so its scripts never run. Sprites are billboarded toward the icon camera.
static func build_visual_holder(scene: PackedScene) -> Node3D:
	var holder := Node3D.new()
	var temp: Node = scene.instantiate()
	_copy_visuals(temp, holder, Transform3D.IDENTITY)
	temp.free()
	return holder


static func _copy_visuals(
	source: Node,
	target: Node3D,
	parent_xform: Transform3D
) -> void:
	for child in source.get_children():
		var child_xform: Transform3D = parent_xform
		if child is Node3D:
			child_xform = parent_xform * (child as Node3D).transform

		if child is MeshInstance3D:
			var source_mesh := child as MeshInstance3D
			if source_mesh.mesh != null:
				var mesh_copy := MeshInstance3D.new()
				mesh_copy.mesh = source_mesh.mesh
				mesh_copy.transform = child_xform
				mesh_copy.cast_shadow = (
					GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				)
				target.add_child(mesh_copy)
		elif child is Sprite3D:
			var source_sprite := child as Sprite3D
			var sprite_copy := Sprite3D.new()
			sprite_copy.texture = source_sprite.texture
			sprite_copy.pixel_size = source_sprite.pixel_size
			sprite_copy.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			sprite_copy.shaded = true
			sprite_copy.double_sided = true
			sprite_copy.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
			sprite_copy.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			sprite_copy.transform = child_xform
			target.add_child(sprite_copy)

		_copy_visuals(child, target, child_xform)


## Centres the holder on the origin and scales its largest dimension to
## `target_size`, so every icon fills the same amount of the 64x64 canvas.
static func _fit_holder(holder: Node3D, target_size: float) -> void:
	var bounds := _holder_bounds(holder)
	if bounds.size.length() <= 0.0001:
		return
	var largest: float = maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
	if largest <= 0.0001:
		return
	var factor := target_size / largest
	holder.scale = Vector3.ONE * factor
	holder.position = -bounds.get_center() * factor


static func _holder_bounds(holder: Node3D) -> AABB:
	var has_bounds := false
	var result := AABB()
	for child in holder.get_children():
		if not child is Node3D:
			continue
		var node := child as Node3D
		var box: AABB
		var valid := false
		if node is MeshInstance3D:
			var mesh_instance := node as MeshInstance3D
			if mesh_instance.mesh != null:
				box = mesh_instance.transform * mesh_instance.mesh.get_aabb()
				valid = true
		elif node is Sprite3D:
			box = node.transform * (node as Sprite3D).get_aabb()
			valid = true
		elif node is Node3D:
			box = _holder_bounds(node)
			box = node.transform * box
			valid = box.size.length() > 0.0001
		if valid:
			result = box if not has_bounds else result.merge(box)
			has_bounds = true
	return result


# ---------------------------------------------------------------------------
# Extruded pixel item meshes (Minecraft-style items)
# ---------------------------------------------------------------------------

## Finds the first Sprite3D/Sprite2D texture in a scene. Foliage scenes use
## this texture as the source for their extruded hand item.
static func find_source_texture(scene: PackedScene) -> Texture2D:
	if scene == null:
		return null
	var temp: Node = scene.instantiate()
	var texture := _find_sprite_texture(temp)
	temp.free()
	return texture


static func _find_sprite_texture(node: Node) -> Texture2D:
	for child in node.get_children():
		if child is Sprite3D:
			var sprite3d := child as Sprite3D
			if sprite3d.texture != null:
				return sprite3d.texture
		elif child is Sprite2D:
			var sprite2d := child as Sprite2D
			if sprite2d.texture != null:
				return sprite2d.texture
		var nested := _find_sprite_texture(child)
		if nested != null:
			return nested
	return null


## Builds a small extruded item mesh from a 2D pixel texture: one front quad,
## one back quad, and a side quad for every edge pixel whose 4-neighbour is
## transparent. Side faces use the edge pixel's UV and a darker vertex colour.
static func build_extruded_mesh(
	texture: Texture2D,
	thickness_pixels: float = -1.0
) -> ArrayMesh:
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null:
		return null
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)

	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return null

	var thickness := thickness_pixels
	if thickness <= 0.0:
		thickness = maxf(1.0, minf(width, height) / 16.0)
	var half := thickness * 0.5

	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.vertex_color_use_as_albedo = true

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_material(material)

	# Whole-image front and back faces. Alpha scissor removes the empty pixels,
	# so only the silhouette is visible; side faces fill the outline.
	_add_quad(
		tool,
		Vector3(0.0, 0.0, half),
		Vector3(width, 0.0, half),
		Vector3(width, height, half),
		Vector3(0.0, height, half),
		Vector3.BACK,
		Vector2(0.0, 1.0),
		Vector2(1.0, 1.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, 0.0),
		Color.WHITE
	)
	_add_quad(
		tool,
		Vector3(width, 0.0, -half),
		Vector3(0.0, 0.0, -half),
		Vector3(0.0, height, -half),
		Vector3(width, height, -half),
		Vector3.FORWARD,
		Vector2(1.0, 1.0),
		Vector2(0.0, 1.0),
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Color.WHITE
	)

	var shade_x := Color(0.78, 0.78, 0.78, 1.0)
	var shade_y := Color(0.62, 0.62, 0.62, 1.0)
	var threshold := 0.5

	for y in height:
		for x in width:
			if image.get_pixel(x, y).a < threshold:
				continue

			var x0 := float(x)
			var x1 := float(x + 1)
			var y0 := float(height - 1 - y)
			var y1 := y0 + 1.0
			var uv := Vector2(
				(float(x) + 0.5) / float(width),
				(float(y) + 0.5) / float(height)
			)

			if not _pixel_solid(image, x + 1, y, threshold):
				_add_quad(
					tool,
					Vector3(x1, y0, -half),
					Vector3(x1, y0, half),
					Vector3(x1, y1, half),
					Vector3(x1, y1, -half),
					Vector3.RIGHT,
					uv, uv, uv, uv,
					shade_x
				)
			if not _pixel_solid(image, x - 1, y, threshold):
				_add_quad(
					tool,
					Vector3(x0, y0, half),
					Vector3(x0, y0, -half),
					Vector3(x0, y1, -half),
					Vector3(x0, y1, half),
					Vector3.LEFT,
					uv, uv, uv, uv,
					shade_x
				)
			if not _pixel_solid(image, x, y - 1, threshold):
				_add_quad(
					tool,
					Vector3(x0, y1, half),
					Vector3(x1, y1, half),
					Vector3(x1, y1, -half),
					Vector3(x0, y1, -half),
					Vector3.UP,
					uv, uv, uv, uv,
					shade_y
				)
			if not _pixel_solid(image, x, y + 1, threshold):
				_add_quad(
					tool,
					Vector3(x0, y0, -half),
					Vector3(x1, y0, -half),
					Vector3(x1, y0, half),
					Vector3(x0, y0, half),
					Vector3.DOWN,
					uv, uv, uv, uv,
					shade_y
				)

	return tool.commit()


static func _pixel_solid(
	image: Image,
	x: int,
	y: int,
	threshold: float
) -> bool:
	if x < 0 or y < 0:
		return false
	if x >= image.get_width() or y >= image.get_height():
		return false
	return image.get_pixel(x, y).a >= threshold


static func _add_quad(
	tool: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	normal: Vector3,
	uv_a: Vector2,
	uv_b: Vector2,
	uv_c: Vector2,
	uv_d: Vector2,
	color: Color
) -> void:
	var vertices: Array[Vector3] = [a, b, c, a, c, d]
	var uvs: Array[Vector2] = [uv_a, uv_b, uv_c, uv_a, uv_c, uv_d]
	for index in vertices.size():
		tool.set_normal(normal)
		tool.set_color(color)
		tool.set_uv(uvs[index])
		tool.add_vertex(vertices[index])


static func extruded_mesh_for_texture(
	texture: Texture2D,
	cache_key: String = ""
) -> ArrayMesh:
	if texture == null:
		return null
	var key := cache_key
	if key.is_empty():
		key = texture.resource_path
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var mesh := build_extruded_mesh(texture)
	_mesh_cache[key] = mesh
	return mesh


static func extruded_mesh_for_scene(scene: PackedScene) -> ArrayMesh:
	if scene == null:
		return null
	var entry := entry_for_scene(scene)
	var mesh_path := String(entry.get("mesh", ""))
	if not mesh_path.is_empty():
		if _mesh_cache.has(mesh_path):
			return _mesh_cache[mesh_path]
		var loaded := load(mesh_path) as ArrayMesh
		if loaded != null:
			_mesh_cache[mesh_path] = loaded
			return loaded

	var texture := find_source_texture(scene)
	if texture == null:
		return null
	return extruded_mesh_for_texture(texture, scene.resource_path)


# ---------------------------------------------------------------------------
# Runtime manifest / icon lookup
# ---------------------------------------------------------------------------

static func reload() -> void:
	_manifest = {}
	_manifest_loaded = false
	_icon_cache.clear()
	_mesh_cache.clear()


static func _ensure_manifest() -> void:
	if _manifest_loaded:
		return
	_manifest_loaded = true
	if not FileAccess.file_exists(MANIFEST_PATH):
		return
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		_manifest = parsed


static func entry_for_scene(scene: PackedScene) -> Dictionary:
	if scene == null:
		return {}
	_ensure_manifest()
	var items: Dictionary = _manifest.get("items", {})
	return items.get(scene.resource_path, {})


static func icon_for_scene(scene: PackedScene) -> Texture2D:
	if scene == null:
		return null
	_ensure_manifest()
	var entry := entry_for_scene(scene)
	var icon_path := String(entry.get("icon", ""))
	if icon_path.is_empty():
		return null
	if _icon_cache.has(icon_path):
		return _icon_cache[icon_path]
	var texture := load(icon_path) as Texture2D
	_icon_cache[icon_path] = texture
	return texture


static func viewmodel_for_scene(scene: PackedScene) -> String:
	var entry := entry_for_scene(scene)
	return String(entry.get("viewmodel", "scene"))
