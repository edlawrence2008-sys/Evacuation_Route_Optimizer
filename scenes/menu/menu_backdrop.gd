extends Node3D

## Shared drifting voxel backdrop for the 3D menus.

func _ready() -> void:
	_add_layer(
		22, 14, 0.38, 0.16,
		Color(0.05, 0.22, 0.20, 1.0),
		Color(0.02, 0.22, 0.18, 1.0),
		-8.0, 0.0
	)
	_add_layer(
		12, 8, 0.62, 0.24,
		Color(0.22, 0.16, 0.04, 1.0),
		Color(0.30, 0.20, 0.04, 1.0),
		-6.6, 0.7
	)


func _process(_delta: float) -> void:
	var t: float = float(Time.get_ticks_msec()) / 1000.0
	rotation.y = sin(t * 0.07) * 0.16
	rotation.x = sin(t * 0.05) * 0.05
	position.y = sin(t * 0.11) * 0.07


func _add_layer(
	cols: int,
	rows: int,
	spacing: float,
	size: float,
	albedo: Color,
	emission: Color,
	z: float,
	phase: float
) -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = albedo
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = 0.9
	mesh.material = material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = cols * rows

	var instance := 0

	for row in rows:
		for col in cols:
			var x := (float(col) - (float(cols) - 1.0) * 0.5) * spacing
			var y := (float(row) - (float(rows) - 1.0) * 0.5) * spacing
			var wave := sin(float(col) * 0.55 + float(row) * 0.8 + phase)
			var depth := z + wave * 0.45
			var tall := 1.0 + 0.6 * absf(wave)
			var basis := Basis.IDENTITY.scaled(Vector3(1.0, tall, 1.0))
			multimesh.set_instance_transform(
				instance,
				Transform3D(basis, Vector3(x, y, depth))
			)
			instance += 1

	var instance_node := MultiMeshInstance3D.new()
	instance_node.multimesh = multimesh
	instance_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance_node)
