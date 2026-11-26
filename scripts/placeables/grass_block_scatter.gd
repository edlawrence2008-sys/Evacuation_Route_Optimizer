extends Node3D

## A normal grass block with a MultiMesh patch of wind-swayed grass clumps on
## top. The block mesh is extracted from the game's MeshLibrary item 53
## (Auto_grass_normal), so the block itself looks like the authored block.
##
## The scatter is built once per placed block. It is intentionally small: this
## is a decorative placeable, not a terrain-wide field.

const GRASS_CLUMP: Mesh = preload(
	"res://addons/EmacEArtStylizedGrass/Meshes/EA_Grass_Clump.mesh"
)
const GRASS_MATERIAL: Material = preload(
	"res://addons/EmacEArtStylizedGrass/Materials/EA_Grass_Green.tres"
)

## Turn off to use this as a scatter-only tuft patch on an existing grass block.
@export var show_block: bool = true
@export var density: float = 34.0
@export var area_size: Vector2 = Vector2(1.15, 1.15)
@export var scale_min: float = 0.55
@export var scale_max: float = 1.0
@export_range(0.0, 30.0, 0.5) var tilt_degrees: float = 6.0
## 0 picks a fresh random seed per placed block.
@export var random_seed: int = 0

@onready var block: MeshInstance3D = $Block
@onready var scatter: MultiMeshInstance3D = $Scatter


func _ready() -> void:
	if block != null:
		block.visible = show_block

	if scatter != null and not show_block:
		scatter.position.y = 0.0

	_build_scatter()


func _build_scatter() -> void:
	if scatter == null or GRASS_CLUMP == null:
		return

	var count: int = int(area_size.x * area_size.y * density)

	if count <= 0:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed if random_seed != 0 else randi()
	var half := area_size * 0.5
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = GRASS_CLUMP
	multimesh.instance_count = count

	for index in count:
		var instance_position := Vector3(
			rng.randf_range(-half.x, half.x),
			0.0,
			rng.randf_range(-half.y, half.y)
		)
		var instance_basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU))

		if tilt_degrees > 0.0:
			var axis := Vector3(
				rng.randf_range(-1.0, 1.0),
				0.0,
				rng.randf_range(-1.0, 1.0)
			).normalized()

			if axis.length_squared() > 0.0001:
				instance_basis = (
					Basis(
						axis,
						deg_to_rad(
							rng.randf_range(-tilt_degrees, tilt_degrees)
						)
					)
					* instance_basis
				)

		instance_basis = instance_basis.scaled(Vector3.ONE * rng.randf_range(scale_min, scale_max))
		multimesh.set_instance_transform(index, Transform3D(instance_basis, instance_position))

	scatter.multimesh = multimesh
	scatter.material_override = GRASS_MATERIAL
	scatter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scatter.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
