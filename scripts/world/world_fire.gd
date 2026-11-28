class_name WorldFire
extends Node

## Cell-level fire for ordinary world blocks. The Fire Tool/WorldFire API stores
## burning cells, spreads through neighbours, damages health targets and consumes
## sustained fuel. Sub-level fire remains in SubLevel because it owns a local grid.
##
## Any block can be ignited, but only materials with real flammability sustain a
## fire. A concrete/stone surface fire burns briefly and goes out without
## spreading or consuming the block. Smoke is fed into the shared HazardWorld CA
## used by the smoke tool, and consumed cells are replaced by ash panel blocks.

const BLOCK_MATERIALS = preload("res://scripts/block_materials.gd")
const FIRE_TEXTURE: Texture2D = preload("res://textures/specialblocks/fire.png")
const FIRE_FRAME_SIZE: int = 16
const NEIGHBOURS_6: Array[Vector3i] = [
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]
const SIDE_DIRS: Array[Vector3i] = [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

const TICK_INTERVAL: float = 0.5
const BURN_FUEL: float = 6.0
## Flames on a non-fuel surface; long enough to see, short enough to self-clear.
const SURFACE_FUEL: float = 1.4
const DAMAGE_RADIUS: float = 2.0
const DAMAGE_PER_TICK: float = 5.0
## Spread only into materials above this value; concrete/stone stay fireproof.
const MIN_FLAMMABILITY: float = 0.04
## Materials at or above this value burn until consumed and leave ash.
const SUSTAINED_FLAMMABILITY: float = 0.15
## Chance per neighbour per tick = flammability * this.
const SPREAD_CHANCE_SCALE: float = 0.65
const MAX_BURNING_CELLS: int = 96
const ASH_PANEL_NAME: String = "Auto_Panel_Bottom_ash"
const ASH_SCAN_LIMIT: int = 32
const SMOKE_SAMPLES_PER_TICK: int = 8

var grid: NavGridMap = null
var burning_cells: Dictionary = {}

var _accum: float = 0.0
var _visual: MultiMeshInstance3D = null
var _multimesh: MultiMesh = null
var _material: StandardMaterial3D = null
var _anim_accum: float = 0.0
var _light: OmniLight3D = null

## item id -> flammability; avoids re-parsing material names every spread roll.
var _flammability_cache: Dictionary = {}
var _ash_item: int = -2

static var _fire_frame_textures: Array[ImageTexture] = []


func setup(grid_ref: NavGridMap) -> void:
	grid = grid_ref
	add_to_group("world_fire")
	set_physics_process(true)


func ignite_at_world(world_position: Vector3) -> bool:
	if grid == null or not is_instance_valid(grid):
		return false

	var cell := grid.world_to_cell(world_position)
	if ignite_cell(cell):
		return true

	# A hit exactly on a face can round into the adjacent air cell. Search the
	# immediate neighbourhood for the solid block the player clicked.
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				if x == 0 and y == 0 and z == 0:
					continue
				if ignite_cell(cell + Vector3i(x, y, z)):
					return true
	return false


## Ignites the actual block under a world-space hit, using the hit normal so a
## face-aligned click does not round into the empty neighbouring cell.
func ignite_at_hit(world_position: Vector3, normal: Vector3) -> bool:
	if grid == null or not is_instance_valid(grid):
		return false

	var cell := grid.get_hit_cell(world_position, normal)
	if ignite_cell(cell):
		return true

	# Fall back to the nearest solid cell around the contact point.
	return ignite_at_world(world_position)


func ignite_cell(cell: Vector3i) -> bool:
	if grid == null or not is_instance_valid(grid):
		return false
	if not grid.has_block(cell):
		return false
	if burning_cells.has(cell):
		return true
	if burning_cells.size() >= MAX_BURNING_CELLS:
		return false

	var flammability := _cell_flammability(cell)
	burning_cells[cell] = (
		BURN_FUEL if flammability >= SUSTAINED_FLAMMABILITY else SURFACE_FUEL
	)
	_refresh_visual()
	return true


func extinguish_at_world(world_position: Vector3, radius: float) -> int:
	var removed := 0
	var radius_sq := radius * radius
	for cell_value: Variant in burning_cells.keys():
		var cell: Vector3i = cell_value
		if _cell_world(cell).distance_squared_to(world_position) > radius_sq:
			continue
		burning_cells.erase(cell)
		removed += 1
	if removed > 0:
		_refresh_visual()
	return removed


func is_burning() -> bool:
	return not burning_cells.is_empty()


## Frame count follows the actual strip height, so replacing fire.png with a
## different-length animation needs no code change (one column of 16 px frames).
static func fire_frame_count() -> int:
	return maxi(1, FIRE_TEXTURE.get_height() / FIRE_FRAME_SIZE)


func _physics_process(delta: float) -> void:
	if grid == null or not is_instance_valid(grid):
		burning_cells.clear()
		return
	if burning_cells.is_empty():
		return

	_animate_visual(delta)
	_accum += delta
	if _accum < TICK_INTERVAL:
		return
	var step := _accum
	_accum = 0.0

	var burning: Array = burning_cells.keys()
	var damage_centers: Array = []
	var consumed: Array[Vector3i] = []
	var expired: Array[Vector3i] = []

	for cell_value: Variant in burning:
		var cell: Vector3i = cell_value
		burning_cells[cell] = float(burning_cells[cell]) - step
		damage_centers.append(_cell_world(cell))

		if burning_cells.size() < MAX_BURNING_CELLS:
			_try_spread(cell)

		if float(burning_cells[cell]) <= 0.0:
			if _cell_flammability(cell) >= SUSTAINED_FLAMMABILITY:
				consumed.append(cell)
			else:
				expired.append(cell)

	if not damage_centers.is_empty():
		Explosion.damage_area_clustered(
			self,
			damage_centers,
			DAMAGE_RADIUS,
			DAMAGE_PER_TICK
		)

	for cell: Vector3i in expired:
		burning_cells.erase(cell)

	if not consumed.is_empty():
		for cell: Vector3i in consumed:
			burning_cells.erase(cell)
		_consume_cells(consumed)

	_inject_smoke(burning)
	_refresh_visual()


func _try_spread(cell: Vector3i) -> void:
	if _cell_flammability(cell) < SUSTAINED_FLAMMABILITY:
		return
	for offset: Vector3i in NEIGHBOURS_6:
		var neighbour: Vector3i = cell + offset
		if burning_cells.has(neighbour) or not grid.has_block(neighbour):
			continue
		var flammability := _cell_flammability(neighbour)
		if flammability <= MIN_FLAMMABILITY:
			continue
		var chance := clampf(flammability * SPREAD_CHANCE_SCALE, 0.0, 0.85)
		if randf() < chance:
			burning_cells[neighbour] = BURN_FUEL
			if burning_cells.size() >= MAX_BURNING_CELLS:
				return


func _cell_flammability(cell: Vector3i) -> float:
	if grid == null or not is_instance_valid(grid):
		return 0.0
	if not grid.has_block(cell) or grid.mesh_library == null:
		return 0.0
	var item: int = grid.get_block_item(cell)
	if item < 0:
		return 0.0
	if _flammability_cache.has(item):
		return float(_flammability_cache[item])
	var value := BLOCK_MATERIALS.flammability_for_item(
		String(grid.mesh_library.get_item_name(item))
	)
	_flammability_cache[item] = value
	return value


## Removes the burned blocks, then lets their ash fall to the nearest surface
## below and places a real ash panel block there.
func _consume_cells(cells: Array[Vector3i]) -> void:
	if grid == null or not is_instance_valid(grid) or cells.is_empty():
		return

	grid.remove_blocks(cells)
	var ash_item := _ash_panel_item()
	if ash_item < 0:
		return

	var landing: Dictionary = {}
	for cell: Vector3i in cells:
		var target: Variant = _ash_landing_cell(cell)
		if target != null:
			landing[target] = true

	if landing.is_empty():
		return

	var ash_cells: Array[Vector3i] = []
	ash_cells.assign(landing.keys())
	grid.place_blocks(ash_cells, ash_item, 0)
	for cell: Vector3i in ash_cells:
		grid.settle_ash_cell(cell)


## First empty cell above a solid block in this column, or null when the column
## has no floor within ASH_SCAN_LIMIT cells.
func _ash_landing_cell(start: Vector3i) -> Variant:
	var cell := start
	for _index in ASH_SCAN_LIMIT:
		if grid.has_block(cell):
			return null
		var below := cell + Vector3i.DOWN
		if grid.has_block(below):
			return cell
		cell = below
	return null


func _ash_panel_item() -> int:
	if _ash_item != -2:
		return _ash_item
	_ash_item = -1
	if grid == null or not is_instance_valid(grid) or grid.mesh_library == null:
		return _ash_item
	for id: int in grid.mesh_library.get_item_list():
		if String(grid.mesh_library.get_item_name(id)) == ASH_PANEL_NAME:
			_ash_item = id
			return _ash_item
	for id: int in grid.mesh_library.get_item_list():
		var lower := String(grid.mesh_library.get_item_name(id)).to_lower()
		if "panel" in lower and "ash" in lower:
			_ash_item = id
			return _ash_item
	return _ash_item


## Feed the same block smoke CA used by the gas/smoke tool, sampling a handful of
## burning cells per tick instead of adding one emitter per cell.
func _inject_smoke(cells: Array) -> void:
	if cells.is_empty():
		return
	var hazard := get_tree().get_first_node_in_group("hazard_world")
	if hazard == null or not hazard.has_method("add_smoke"):
		return
	var stride := maxi(
		1,
		int(ceil(float(cells.size()) / float(SMOKE_SAMPLES_PER_TICK)))
	)
	var index := 0
	for cell_value: Variant in cells:
		if index % stride == 0:
			var cell: Vector3i = cell_value
			hazard.call(
				"add_smoke",
				_cell_world(cell) + Vector3.UP * 0.8,
				0.32,
				1.3
			)
		index += 1


static func _build_fire_frames() -> Array[ImageTexture]:
	if not _fire_frame_textures.is_empty():
		return _fire_frame_textures
	var image := FIRE_TEXTURE.get_image()
	var frames := fire_frame_count()
	for index in frames:
		var region := image.get_region(Rect2i(
			0,
			index * FIRE_FRAME_SIZE,
			FIRE_FRAME_SIZE,
			FIRE_FRAME_SIZE
		))
		_fire_frame_textures.append(ImageTexture.create_from_image(region))
	return _fire_frame_textures


func _animate_visual(delta: float) -> void:
	if _material == null:
		return
	_anim_accum += delta
	if _anim_accum < 0.08:
		return
	_anim_accum = 0.0
	var frames := _build_fire_frames()
	if frames.is_empty():
		return
	var frame := int(Time.get_ticks_msec() / 80) % frames.size()
	_material.albedo_texture = frames[frame]


func _cell_world(cell: Vector3i) -> Vector3:
	if grid == null or not is_instance_valid(grid):
		return Vector3.ZERO
	return grid.to_global(grid.map_to_local(cell))


func _refresh_visual() -> void:
	if burning_cells.is_empty():
		if is_instance_valid(_visual):
			_visual.visible = false
		if is_instance_valid(_light):
			_light.visible = false
		return

	_ensure_fire_visual()
	var transforms: Array[Transform3D] = []
	var first := Vector3.ZERO
	var has_first := false
	var t := Time.get_ticks_msec() * 0.01
	var camera_pos := Vector3.ZERO
	var has_camera := false
	var viewport := get_viewport()
	if viewport != null:
		var camera := viewport.get_camera_3d()
		if camera != null:
			camera_pos = camera.global_position
			has_camera = true

	for cell_value: Variant in burning_cells:
		var cell: Vector3i = cell_value
		var world_pos := _cell_world(cell)
		if not has_first:
			first = world_pos
			has_first = true
		var flame_position: Variant = _flame_world_position(
			cell,
			camera_pos,
			has_camera
		)
		if flame_position == null:
			continue
		var scale := 1.0 + sin(t + float(cell.x + cell.z)) * 0.08
		transforms.append(Transform3D(
			Basis.from_scale(Vector3(scale, scale, scale)),
			flame_position
		))

	_multimesh.instance_count = transforms.size()
	for index in transforms.size():
		_multimesh.set_instance_transform(index, transforms[index])

	_visual.visible = not transforms.is_empty()
	if is_instance_valid(_light):
		_light.visible = not transforms.is_empty()
		_light.global_position = first + Vector3.UP * 0.8


## Pick an exposed face for the flame: top when the cell is exposed upward,
## otherwise the side face that most directly faces the camera. Fully enclosed
## cells return null and draw nothing.
func _flame_world_position(
	cell: Vector3i,
	camera_pos: Vector3,
	has_camera: bool
) -> Variant:
	if grid == null or not is_instance_valid(grid):
		return null
	var size: Vector3 = grid.cell_size
	var center := _cell_world(cell)
	if not grid.has_block(cell + Vector3i(0, 1, 0)):
		return center + Vector3.UP * (size.y * 0.5 + 0.15)

	var best_dir := Vector3i.ZERO
	var best_score := -2.0
	for dir: Vector3i in SIDE_DIRS:
		if grid.has_block(cell + dir):
			continue
		var face := center + Vector3(dir) * size * 0.5
		var score := 0.0
		if has_camera:
			score = Vector3(dir).dot((camera_pos - face).normalized())
		if score > best_score:
			best_score = score
			best_dir = dir

	if best_dir == Vector3i.ZERO:
		return null
	return (
		center
		+ Vector3(best_dir) * size * 0.5
		+ Vector3(best_dir) * 0.15
	)


func _ensure_fire_visual() -> void:
	if _visual != null and is_instance_valid(_visual):
		return

	_visual = MultiMeshInstance3D.new()
	_visual.name = "WorldFire"
	_visual.top_level = true
	_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(0.7, 0.7)
	_multimesh.mesh = quad
	_visual.multimesh = _multimesh
	var frames := _build_fire_frames()
	_material = StandardMaterial3D.new()
	_material.albedo_texture = frames[0] if not frames.is_empty() else FIRE_TEXTURE
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_material.no_depth_test = false
	_material.render_priority = 1
	_visual.material_override = _material
	_add_to_scene(_visual)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.42, 0.08, 1.0)
	_light.light_energy = 1.5
	_light.omni_range = 4.5
	_light.shadow_enabled = false
	_add_to_scene(_light)


func _add_to_scene(node: Node) -> void:
	if get_tree() == null:
		return
	if get_tree().current_scene != null:
		get_tree().current_scene.add_child(node)
	else:
		get_tree().root.add_child(node)


func _exit_tree() -> void:
	if is_instance_valid(_visual):
		_visual.queue_free()
	if is_instance_valid(_light):
		_light.queue_free()
