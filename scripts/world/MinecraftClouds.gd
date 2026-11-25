class_name MinecraftClouds
extends Node3D

## Two blocky Minecraft-style cloud layers built from shaded box faces.
## The geometry is generated once into one merged mesh per layer, using the
## same face-brightness idea as Minecraft's cloud shader. The primary layer
## sits at y = 128 and the secondary at y = 256 by default.

const CLOUD_SHADER: Shader = preload(
	"res://shaders/minecraft_clouds.gdshader"
)

@export_group("Common")
@export var sun_path: NodePath = NodePath(
	"../CycleController/DirectionalLight3D"
)
@export var cloud_seed: int = 9317
@export_range(0.005, 0.2, 0.001) var noise_frequency: float = 0.052
@export_range(0.05, 0.8, 0.01) var noise_gain: float = 0.5
@export var night_tint: Color = Color(0.18, 0.21, 0.32)
## Global playback speed multiplier used by Graphics > Sky & Clouds.
@export_range(0.0, 4.0, 0.01) var speed_scale: float = 1.0
## Clouds are fully opaque before this view distance and invisible after it.
@export var distance_fade_start: float = 250.0
@export var distance_fade_end: float = 1000.0

@export_group("Primary Layer")
@export var primary_height: float = 128.0
@export var primary_cell_size: Vector2 = Vector2(12.0, 12.0)
@export var primary_grid_cells: int = 160
@export_range(0.05, 0.8, 0.01) var primary_coverage: float = 0.32
@export var primary_thickness: float = 4.0
@export var primary_speed: float = 3.0
@export var primary_color: Color = Color(1.0, 1.0, 1.0, 0.8)

@export_group("Secondary Layer")
@export var secondary_height: float = 256.0
@export var secondary_cell_size: Vector2 = Vector2(16.0, 16.0)
@export var secondary_grid_cells: int = 120
@export_range(0.05, 0.8, 0.01) var secondary_coverage: float = 0.22
@export var secondary_thickness: float = 6.0
@export var secondary_speed: float = 1.0
@export var secondary_color: Color = Color(0.92, 0.95, 1.0, 0.55)

var _sun: DirectionalLight3D = null
var _layers: Array[Dictionary] = []


func _ready() -> void:
	add_to_group("minecraft_clouds")
	_sun = get_node_or_null(sun_path) as DirectionalLight3D
	_build_layers()
	_update_colors(1.0)


## Rebuilds both cloud layers from the current exported coverage/height/speed
## values. Called by the Graphics menu when cloud coverage changes.
func rebuild_layers() -> void:
	for layer: Dictionary in _layers:
		var node: Node3D = layer.get("node") as Node3D

		if is_instance_valid(node):
			remove_child(node)
			node.queue_free()

	_layers.clear()
	_build_layers()
	_update_colors(1.0)


func set_coverage(primary: float, secondary: float) -> void:
	var next_primary: float = clampf(primary, 0.05, 0.8)
	var next_secondary: float = clampf(secondary, 0.05, 0.8)

	if (
		is_equal_approx(next_primary, primary_coverage)
		and is_equal_approx(next_secondary, secondary_coverage)
	):
		return

	primary_coverage = next_primary
	secondary_coverage = next_secondary
	rebuild_layers()


func set_speed_scale(value: float) -> void:
	speed_scale = maxf(value, 0.0)


func _build_layers() -> void:
	_add_layer(
		"PrimaryClouds",
		primary_height,
		primary_cell_size,
		primary_grid_cells,
		primary_coverage,
		primary_thickness,
		primary_speed,
		primary_color,
		0
	)
	_add_layer(
		"SecondaryClouds",
		secondary_height,
		secondary_cell_size,
		secondary_grid_cells,
		secondary_coverage,
		secondary_thickness,
		secondary_speed,
		secondary_color,
		7919
	)


func _process(delta: float) -> void:
	for layer: Dictionary in _layers:
		var node: Node3D = layer["node"]
		var span: float = layer["span"]
		node.position.x += float(layer["speed"]) * speed_scale * delta

		# The field is ~1.9 km wide; wrapping happens well past the draw
		# distance, so the change is invisible during normal play.
		if node.position.x > span * 0.5:
			node.position.x -= span
		elif node.position.x < -span * 0.5:
			node.position.x += span

	_update_colors(delta)


func _add_layer(
	layer_name: String,
	height: float,
	cell_size: Vector2,
	grid_cells: int,
	coverage: float,
	thickness: float,
	speed: float,
	base_color: Color,
	seed_offset: int
) -> void:
	var size: int = maxi(grid_cells, 4)
	var mask: PackedByteArray = _build_cloud_mask(
		size,
		coverage,
		cloud_seed + seed_offset
	)
	var half: float = float(size) * 0.5
	var half_thickness: float = thickness * 0.5

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vertex_count: int = 0

	# Top and bottom faces are merged into coplanar rectangles, so the large
	# cloud banks do not show a grid of per-cell seams.
	var rectangles: Array[Vector4i] = _build_rectangles(mask, size)

	for rect: Vector4i in rectangles:
		var x0: float = (float(rect.x) - half) * cell_size.x
		var x1: float = (float(rect.x + rect.z) - half) * cell_size.x
		var z0: float = (float(rect.y) - half) * cell_size.y
		var z1: float = (float(rect.y + rect.w) - half) * cell_size.y

		# Clockwise when viewed from outside, so cull_back keeps the outside.
		_add_quad(
			st,
			Vector3(x0, half_thickness, z0),
			Vector3(x1, half_thickness, z0),
			Vector3(x1, half_thickness, z1),
			Vector3(x0, half_thickness, z1),
			Vector3.UP,
			vertex_count
		)
		vertex_count += 4

		_add_quad(
			st,
			Vector3(x0, -half_thickness, z0),
			Vector3(x0, -half_thickness, z1),
			Vector3(x1, -half_thickness, z1),
			Vector3(x1, -half_thickness, z0),
			Vector3.DOWN,
			vertex_count
		)
		vertex_count += 4

	# Sides are emitted only where a neighbouring cell is empty. Runs of
	# adjacent exposed faces are merged along the wall direction.
	vertex_count = _add_side_faces(
		st,
		mask,
		size,
		cell_size,
		half,
		half_thickness,
		vertex_count
	)

	var material := ShaderMaterial.new()
	material.shader = CLOUD_SHADER
	material.set_shader_parameter("cloud_color", base_color)
	material.set_shader_parameter("distance_fade_start", distance_fade_start)
	material.set_shader_parameter("distance_fade_end", distance_fade_end)

	var instance := MeshInstance3D.new()
	instance.name = layer_name
	instance.mesh = st.commit()
	instance.material_override = material
	instance.position.y = height
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	instance.extra_cull_margin = maxf(cell_size.x, cell_size.y) * 4.0
	add_child(instance)

	_layers.append({
		"node": instance,
		"material": material,
		"span": float(size) * cell_size.x,
		"speed": speed,
		"base_color": base_color,
	})


func _add_side_faces(
	st: SurfaceTool,
	mask: PackedByteArray,
	size: int,
	cell_size: Vector2,
	half: float,
	half_thickness: float,
	start_index: int
) -> int:
	var vertex_count: int = start_index
	var top_y: float = half_thickness
	var bottom_y: float = -half_thickness

	# North (−Z) and south (+Z) walls, merged along X.
	for z: int in size:
		for direction: int in [-1, 1]:
			var x: int = 0

			while x < size:
				var index: int = z * size + x
				var neighbour_z: int = z + direction
				var exposed: bool = (
					mask[index] == 1
					and (
						neighbour_z < 0
						or neighbour_z >= size
						or mask[neighbour_z * size + x] == 0
					)
				)

				if not exposed:
					x += 1
					continue

				var run_start: int = x
				x += 1

				while x < size:
					var next_index: int = z * size + x
					var next_exposed: bool = (
						mask[next_index] == 1
						and (
							neighbour_z < 0
							or neighbour_z >= size
							or mask[neighbour_z * size + x] == 0
						)
					)
					if not next_exposed:
						break
					x += 1

				var x0: float = (float(run_start) - half) * cell_size.x
				var x1: float = (float(x) - half) * cell_size.x
				var wall_z: float = (
					float(z + (1 if direction > 0 else 0)) - half
				) * cell_size.y

				if direction < 0:
					_add_quad(
						st,
						Vector3(x0, bottom_y, wall_z),
						Vector3(x1, bottom_y, wall_z),
						Vector3(x1, top_y, wall_z),
						Vector3(x0, top_y, wall_z),
						Vector3.FORWARD,
						vertex_count
					)
				else:
					_add_quad(
						st,
						Vector3(x0, bottom_y, wall_z),
						Vector3(x0, top_y, wall_z),
						Vector3(x1, top_y, wall_z),
						Vector3(x1, bottom_y, wall_z),
						Vector3.BACK,
						vertex_count
					)

				vertex_count += 4

	# West (−X) and east (+X) walls, merged along Z.
	for x: int in size:
		for direction: int in [-1, 1]:
			var z: int = 0

			while z < size:
				var index: int = z * size + x
				var neighbour_x: int = x + direction
				var exposed: bool = (
					mask[index] == 1
					and (
						neighbour_x < 0
						or neighbour_x >= size
						or mask[z * size + neighbour_x] == 0
					)
				)

				if not exposed:
					z += 1
					continue

				var run_start: int = z
				z += 1

				while z < size:
					var next_index: int = z * size + x
					var next_exposed: bool = (
						mask[next_index] == 1
						and (
							neighbour_x < 0
							or neighbour_x >= size
							or mask[z * size + neighbour_x] == 0
						)
					)
					if not next_exposed:
						break
					z += 1

				var z0: float = (float(run_start) - half) * cell_size.y
				var z1: float = (float(z) - half) * cell_size.y
				var wall_x: float = (
					float(x + (1 if direction > 0 else 0)) - half
				) * cell_size.x

				if direction < 0:
					_add_quad(
						st,
						Vector3(wall_x, bottom_y, z0),
						Vector3(wall_x, top_y, z0),
						Vector3(wall_x, top_y, z1),
						Vector3(wall_x, bottom_y, z1),
						Vector3.LEFT,
						vertex_count
					)
				else:
					_add_quad(
						st,
						Vector3(wall_x, bottom_y, z0),
						Vector3(wall_x, bottom_y, z1),
						Vector3(wall_x, top_y, z1),
						Vector3(wall_x, top_y, z0),
						Vector3.RIGHT,
						vertex_count
					)

				vertex_count += 4

	return vertex_count


func _add_quad(
	st: SurfaceTool,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	normal: Vector3,
	base_index: int
) -> void:
	st.set_normal(normal)
	st.add_vertex(p0)
	st.add_vertex(p1)
	st.add_vertex(p2)
	st.add_vertex(p3)

	st.add_index(base_index)
	st.add_index(base_index + 1)
	st.add_index(base_index + 2)
	st.add_index(base_index)
	st.add_index(base_index + 2)
	st.add_index(base_index + 3)


## Merges the cloud mask into axis-aligned rectangles. This is a simple greedy
## fill: extend the full run to the right, then extend identical rows downward.
func _build_rectangles(
	mask: PackedByteArray,
	size: int
) -> Array[Vector4i]:
	var used := PackedByteArray()
	used.resize(size * size)
	var rectangles: Array[Vector4i] = []

	for z: int in size:
		for x: int in size:
			var index: int = z * size + x

			if mask[index] == 0 or used[index] == 1:
				continue

			var width: int = 1
			while x + width < size:
				var next_index: int = z * size + x + width
				if mask[next_index] == 0 or used[next_index] == 1:
					break
				width += 1

			var height: int = 1
			while z + height < size:
				var row_clear: bool = true

				for offset: int in width:
					var row_index: int = (
						(z + height) * size + x + offset
					)
					if (
						mask[row_index] == 0
						or used[row_index] == 1
					):
						row_clear = false
						break

				if not row_clear:
					break
				height += 1

			for row: int in height:
				for column: int in width:
					used[(z + row) * size + x + column] = 1

			rectangles.append(Vector4i(x, z, width, height))

	return rectangles


## Returns a packed bitmask of cloud cells. Sampling the noise for every cell
## and taking the requested top percentile keeps the layer density predictable
## no matter how the noise distribution shifts with the seed.
func _build_cloud_mask(
	size: int,
	coverage: float,
	layer_seed: int
) -> PackedByteArray:
	var noise := FastNoiseLite.new()
	noise.seed = layer_seed
	noise.noise_type = FastNoiseLite.TYPE_VALUE
	noise.frequency = noise_frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = noise_gain

	var total: int = size * size
	var values := PackedFloat32Array()
	values.resize(total)

	var index: int = 0

	for z: int in size:
		for x: int in size:
			values[index] = noise.get_noise_2d(float(x), float(z))
			index += 1

	var sorted := values.duplicate()
	sorted.sort()

	var cutoff_index: int = clampi(
		int(round(float(total) * (1.0 - coverage))),
		0,
		total - 1
	)
	var threshold: float = sorted[cutoff_index]
	var mask := PackedByteArray()
	mask.resize(total)

	for cell: int in total:
		mask[cell] = 1 if values[cell] >= threshold else 0

	return mask


func _update_colors(_delta: float) -> void:
	var day_factor: float = 1.0
	var sun_tint: Color = Color.WHITE

	if is_instance_valid(_sun):
		day_factor = clampf(_sun.light_energy, 0.0, 1.0)
		sun_tint = _sun.light_color

	var blend: float = smoothstep(0.0, 0.85, day_factor)
	var tint: Color = night_tint.lerp(sun_tint, blend)
	var brightness: float = lerpf(0.32, 1.0, blend)

	for layer: Dictionary in _layers:
		var material: ShaderMaterial = layer["material"]
		var base_color: Color = layer["base_color"]
		material.set_shader_parameter(
			"cloud_color",
			Color(
				tint.r * brightness,
				tint.g * brightness,
				tint.b * brightness,
				base_color.a
			)
		)
