class_name LegacyWaterBootstrap
extends Node3D

const LegacyWaterSystemScript = preload(
	"res://addons/legacy_water/legacy_water_system.gd"
)

## LEGACY ARCHIVE - optional scene hook for the old water system.
##
## The core game no longer creates a water system. To run the archived system
## in a scene, add this node (or instance `legacy_water.tscn`) as a sibling of
## the GridMap and press Play. It creates one `LegacyWaterSystem` next to the
## grid, copies the grid transform, and applies the archived tuning.

@export var grid_path: NodePath
@export var settings: Node
@export var auto_start: bool = true

var _water = null


func _ready() -> void:
	if auto_start:
		start()


func start() -> Node:
	if _water != null and is_instance_valid(_water):
		return _water

	var grid := _resolve_grid()
	if grid == null:
		push_warning("LegacyWaterBootstrap: no GridMap found.")
		return null

	_water = LegacyWaterSystemScript.new()
	_water.name = "LegacyWaterSystem"

	# Sibling, not a child: ChunkMesher hides the GridMap node.
	var host := get_parent()
	if host == null:
		host = grid.get_parent()
	host.add_child(_water)
	_water.global_transform = grid.global_transform
	_water.setup(grid)

	if settings != null:
		settings.call("apply_to", _water)

	return _water


func get_water() -> Node:
	return _water


func stop() -> void:
	if _water != null and is_instance_valid(_water):
		_water.queue_free()
	_water = null


func _resolve_grid() -> Node3D:
	if not grid_path.is_empty():
		var node := get_node_or_null(grid_path)
		if node is Node3D:
			return node

	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("grid_map") as Node3D
