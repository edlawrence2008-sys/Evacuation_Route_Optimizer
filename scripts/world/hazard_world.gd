class_name HazardWorld
extends Node

## Cheap block-based gas and smoke cellular automata.
##
## Gas (LPG) is heavier than air and pools downward. Smoke is lighter and rises.
## Both use sparse 1 m cells, a low update rate, a cell cap, and a MultiMesh of
## translucent cubes so they are actually visible. Water is only read through
## WaterWorld.sample_water() for the shared sample_hazard() contract.

const DEFAULT_CELL := 1.0
const DEFAULT_STEP := 0.2
const DEFAULT_MAX_CELLS := 4096
const DEFAULT_MAX_VISUAL := 2048

@export var gas_cell_size: float = DEFAULT_CELL
@export var field_step_interval: float = DEFAULT_STEP
@export_range(0.01, 0.45, 0.01) var gas_diffusion: float = 0.16
@export_range(0.0, 0.45, 0.01) var gas_settle: float = 0.16
@export_range(0.0, 0.2, 0.005) var gas_decay: float = 0.02
@export_range(0.01, 0.45, 0.01) var smoke_diffusion: float = 0.12
@export_range(0.0, 0.45, 0.01) var smoke_rise: float = 0.22
@export_range(0.0, 0.2, 0.005) var smoke_decay: float = 0.035
@export var max_active_cells: int = DEFAULT_MAX_CELLS
@export var max_visual_cells: int = DEFAULT_MAX_VISUAL
@export var visual_interval: float = 0.2

var _gas: Dictionary = {}
var _smoke: Dictionary = {}
var _field_accum: float = 0.0
var _visual_accum: float = 0.0
var _gas_multimesh: MultiMesh = null
var _smoke_multimesh: MultiMesh = null
var _gas_instance: MultiMeshInstance3D = null
var _smoke_instance: MultiMeshInstance3D = null


func _ready() -> void:
	add_to_group("hazard_world")
	_create_visuals()


func _process(delta: float) -> void:
	_field_accum += delta
	while _field_accum >= field_step_interval:
		_field_accum -= field_step_interval
		_inject_fire_smoke()
		_step_gas(field_step_interval)
		_step_smoke(field_step_interval)
	_visual_accum += delta
	if _visual_accum >= visual_interval:
		_visual_accum = 0.0
		_refresh_visuals()


## Adds LPG-like gas around a world position. The field is heavier than air.
func add_gas(world_pos: Vector3, amount: float, radius: float = 2.0) -> void:
	_add_field(_gas, world_pos, amount, radius)
	_trim_cells(_gas)


## Adds smoke around a world position. Smoke is lighter than air.
func add_smoke(world_pos: Vector3, amount: float, radius: float = 2.0) -> void:
	_add_field(_smoke, world_pos, amount, radius)
	_trim_cells(_smoke)


func sample_gas(world_pos: Vector3) -> float:
	if _gas.is_empty():
		return 0.0
	return float(_gas.get(_cell_for(world_pos), 0.0))


func sample_smoke(world_pos: Vector3) -> float:
	if _smoke.is_empty():
		return 0.0
	return float(_smoke.get(_cell_for(world_pos), 0.0))


func sample_heat(world_pos: Vector3) -> float:
	var heat := 0.0
	for node in get_tree().get_nodes_in_group("fire"):
		if not is_instance_valid(node):
			continue
		var burning_value: Variant = node.get("burning")
		if burning_value == null or not bool(burning_value):
			continue
		var owner_node := node.get_parent()
		if not (owner_node is Node3D):
			continue
		var radius_value: Variant = node.get("damage_radius")
		var radius := maxf(float(radius_value) if radius_value != null else 2.5, 0.5)
		var distance := (owner_node as Node3D).global_position.distance_to(world_pos)
		if distance > radius:
			continue
		heat = maxf(heat, clampf(1.0 - distance / radius, 0.0, 1.0))
	return heat


## Unified agent sensor entry point.
func sample_hazard(world_pos: Vector3) -> Dictionary:
	var water: Dictionary = {}
	var water_world := get_tree().get_first_node_in_group("water_world")
	if water_world != null and water_world.has_method("sample_water"):
		var result: Variant = water_world.call("sample_water", world_pos)
		if result is Dictionary:
			water = result
	var heat := sample_heat(world_pos)
	var low := world_pos - Vector3.UP * 0.8
	var gas := maxf(sample_gas(world_pos), sample_gas(low))
	var smoke := maxf(sample_smoke(world_pos), sample_smoke(low))
	return {
		"water": water,
		"gas": gas,
		"heat": heat,
		"smoke": smoke,
	}


func clear_gas() -> void:
	_gas.clear()
	_refresh_visuals()


func clear_smoke() -> void:
	_smoke.clear()
	_refresh_visuals()


func clear_all() -> void:
	_gas.clear()
	_smoke.clear()
	_refresh_visuals()


func get_stats() -> Dictionary:
	return {"gas_cells": _gas.size(), "smoke_cells": _smoke.size()}


# ---------------------------------------------------------------------------
# Fields
# ---------------------------------------------------------------------------

func _add_field(field: Dictionary, world_pos: Vector3, amount: float, radius: float) -> void:
	if amount <= 0.0:
		return
	var cell := _cell_for(world_pos)
	var range_cells := maxi(1, int(ceil(radius / maxf(gas_cell_size, 0.01))))
	for dz in range(-range_cells, range_cells + 1):
		for dy in range(-range_cells, range_cells + 1):
			for dx in range(-range_cells, range_cells + 1):
				var offset := Vector3(float(dx), float(dy), float(dz)) * gas_cell_size
				var distance := offset.length()
				if distance > radius:
					continue
				var falloff := clampf(1.0 - distance / maxf(radius, 0.01), 0.0, 1.0)
				var key := cell + Vector3i(dx, dy, dz)
				field[key] = float(field.get(key, 0.0)) + amount * falloff


func _step_gas(delta: float) -> void:
	var next: Dictionary = {}
	for key: Vector3i in _gas.keys():
		var value := float(_gas[key])
		if value <= 0.00001:
			continue
		var spread := value * gas_diffusion
		var decayed := value * maxf(0.0, 1.0 - gas_decay * delta * 10.0)
		var share := spread * 0.15
		_add(next, key, decayed - spread)
		_add(next, key + Vector3i.RIGHT, share)
		_add(next, key + Vector3i.LEFT, share)
		_add(next, key + Vector3i.FORWARD, share)
		_add(next, key + Vector3i.BACK, share)
		_add(next, key + Vector3i.UP, share * 0.35)
		_add(next, key + Vector3i.DOWN, share + spread * gas_settle)
	_gas = next
	_prune(_gas)


func _step_smoke(delta: float) -> void:
	var next: Dictionary = {}
	for key: Vector3i in _smoke.keys():
		var value := float(_smoke[key])
		if value <= 0.00001:
			continue
		var spread := value * smoke_diffusion
		var decayed := value * maxf(0.0, 1.0 - smoke_decay * delta * 10.0)
		var share := spread * 0.15
		_add(next, key, decayed - spread)
		_add(next, key + Vector3i.RIGHT, share)
		_add(next, key + Vector3i.LEFT, share)
		_add(next, key + Vector3i.FORWARD, share)
		_add(next, key + Vector3i.BACK, share)
		_add(next, key + Vector3i.UP, share + spread * smoke_rise)
		_add(next, key + Vector3i.DOWN, share * 0.35)
	_smoke = next
	_prune(_smoke)


func _inject_fire_smoke() -> void:
	for node in get_tree().get_nodes_in_group("fire"):
		if not is_instance_valid(node):
			continue
		var burning_value: Variant = node.get("burning")
		if burning_value == null or not bool(burning_value):
			continue
		var owner_node := node.get_parent()
		if owner_node is Node3D:
			add_smoke(
				(owner_node as Node3D).global_position + Vector3.UP * 1.0,
				0.35,
				1.2
			)


func _add(field: Dictionary, key: Vector3i, amount: float) -> void:
	if absf(amount) <= 0.0000001:
		return
	field[key] = float(field.get(key, 0.0)) + amount


func _prune(field: Dictionary) -> void:
	for key: Vector3i in field.keys():
		if float(field[key]) <= 0.00001:
			field.erase(key)
	_trim_cells(field)


func _trim_cells(field: Dictionary) -> void:
	if field.size() <= max_active_cells:
		return
	var keys: Array = field.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return float(field[a]) > float(field[b])
	)
	while keys.size() > max_active_cells:
		field.erase(keys.pop_back())


func _cell_for(world_pos: Vector3) -> Vector3i:
	var size := maxf(gas_cell_size, 0.01)
	return Vector3i(
		floori(world_pos.x / size),
		floori(world_pos.y / size),
		floori(world_pos.z / size)
	)


# ---------------------------------------------------------------------------
# Block visuals
# ---------------------------------------------------------------------------

func _create_visuals() -> void:
	_gas_multimesh = _make_multimesh(Color(0.95, 0.78, 0.24, 0.28))
	_smoke_multimesh = _make_multimesh(Color(0.48, 0.48, 0.52, 0.24))
	_gas_instance = MultiMeshInstance3D.new()
	_gas_instance.name = "GasBlocks"
	_gas_instance.multimesh = _gas_multimesh
	_gas_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_gas_instance.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_OFF
	)
	add_child(_gas_instance)
	_smoke_instance = MultiMeshInstance3D.new()
	_smoke_instance.name = "SmokeBlocks"
	_smoke_instance.multimesh = _smoke_multimesh
	_smoke_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_smoke_instance.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_OFF
	)
	add_child(_smoke_instance)


func _make_multimesh(color: Color) -> MultiMesh:
	var box := BoxMesh.new()
	var size := maxf(gas_cell_size * 0.9, 0.05)
	box.size = Vector3(size, size, size)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = color
	box.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = box
	multimesh.instance_count = 0
	return multimesh


func _refresh_visuals() -> void:
	_refresh_field_visual(
		_gas_multimesh,
		_gas,
		Color(0.95, 0.78, 0.24, 0.28)
	)
	_refresh_field_visual(
		_smoke_multimesh,
		_smoke,
		Color(0.48, 0.48, 0.52, 0.24)
	)


func _refresh_field_visual(
	multimesh: MultiMesh,
	field: Dictionary,
	base_color: Color
) -> void:
	if multimesh == null:
		return
	var keys: Array = []
	for key: Vector3i in field.keys():
		if float(field[key]) > 0.02:
			keys.append(key)
	if keys.size() > max_visual_cells:
		keys.resize(max_visual_cells)
	multimesh.instance_count = keys.size()
	multimesh.visible_instance_count = keys.size()
	for index in keys.size():
		var key: Vector3i = keys[index]
		var value := clampf(float(field[key]), 0.0, 1.0)
		var center := (Vector3(key) + Vector3.ONE * 0.5) * gas_cell_size
		multimesh.set_instance_transform(
			index,
			Transform3D(Basis.IDENTITY, center)
		)
		var color := base_color
		color.a = clampf(base_color.a * (0.45 + value * 0.9), 0.03, 0.65)
		multimesh.set_instance_color(index, color)
