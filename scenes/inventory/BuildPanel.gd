class_name BuildPanel
extends Control

## Left build tab. All controls are authored in BuildTab.tscn so their layout
## can be edited in the editor; this script only binds them to BuildController.

const GOLD := Color(1.0, 0.85, 0.35, 1.0)
const MUTED := Color(0.68, 0.68, 0.64, 1.0)

var _controller: BuildController = null
var _syncing: bool = false

@onready var _brush_toggle: CheckButton = $Content/Scroll/Column/BrushToggle
@onready var _shape_box: VBoxContainer = $Content/Scroll/Column/ShapeBox
@onready var _brush_option: OptionButton = $Content/Scroll/Column/ShapeBox/ShapeGrid/BrushOption
@onready var _brush_hint: Label = $Content/Scroll/Column/ShapeBox/BrushHint
@onready var _tool_option: OptionButton = $Content/Scroll/Column/ToolGrid/ToolOption
@onready var _placement_option: OptionButton = $Content/Scroll/Column/ToolGrid/PlacementOption
@onready var _pattern_option: OptionButton = $Content/Scroll/Column/ToolGrid/PatternOption
@onready var _drag_box: VBoxContainer = $Content/Scroll/Column/DragBox
@onready var _param_boxes: Array[VBoxContainer] = [
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param1Box,
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param2Box,
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param3Box,
]
@onready var _param_labels: Array[Label] = [
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param1Box/Param1Label,
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param2Box/Param2Label,
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param3Box/Param3Label,
]
@onready var _param_spins: Array[SpinBox] = [
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param1Box/Param1,
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param2Box/Param2,
	$Content/Scroll/Column/ShapeBox/ParamsRow/Param3Box/Param3,
]


func _ready() -> void:
	_brush_toggle.toggled.connect(_on_brush_mode_toggled)
	_brush_option.item_selected.connect(_on_brush_selected)
	_tool_option.item_selected.connect(_on_control_changed)
	_placement_option.item_selected.connect(_on_control_changed)
	_pattern_option.item_selected.connect(_on_control_changed)
	for spin: SpinBox in _param_spins:
		spin.value_changed.connect(_on_param_changed)

	_update_brush_params()
	_update_brush_hint()
	_update_visibility()
	set_process(true)


func _process(_delta: float) -> void:
	if _controller != null:
		set_process(false)
		return

	var player := get_tree().get_first_node_in_group("Player")
	if player == null:
		player = get_tree().get_first_node_in_group("player")
	if player == null:
		return

	_controller = player.get_node_or_null("BuildController") as BuildController
	if _controller == null:
		return

	_sync_from_controller()
	set_process(false)


func _sync_from_controller() -> void:
	if _controller == null:
		return

	_syncing = true
	_brush_toggle.button_pressed = _controller.brush_mode
	_brush_option.selected = int(_controller.brush_kind)
	_tool_option.selected = int(_controller.build_tool)
	_placement_option.selected = int(_controller.placement_mode)
	_pattern_option.selected = int(_controller.brush_pattern)
	_update_brush_params()
	_set_param_values(_controller.brush_params)
	_syncing = false
	_update_visibility()
	_update_brush_hint()


func _apply_settings() -> void:
	if _syncing or _controller == null:
		return

	_controller.set_build_settings({
		"brush_mode": _brush_toggle.button_pressed,
		"brush_kind": _brush_option.get_selected_id(),
		"tool": _tool_option.get_selected_id(),
		"placement": _placement_option.get_selected_id(),
		"brush_params": Vector3i(
			int(_param_spins[0].value),
			int(_param_spins[1].value),
			int(_param_spins[2].value)
		),
		"pattern": _pattern_option.get_selected_id(),
	})

	# Mirror the controller's clamped parameters back into the fields.
	_syncing = true
	_set_param_values(_controller.brush_params)
	_syncing = false
	_update_visibility()
	_update_brush_hint()


func _on_brush_mode_toggled(_pressed: bool) -> void:
	_update_visibility()
	_apply_settings()


func _on_brush_selected(_index: int) -> void:
	_update_brush_params()
	_apply_settings()


## OptionButton.item_selected passes the index; wrap it so the zero-argument
## apply method can be used.
func _on_control_changed(_index: int) -> void:
	_apply_settings()


func _on_param_changed(_value: float) -> void:
	_apply_settings()


func _update_visibility() -> void:
	var brushes := _brush_toggle.button_pressed
	_shape_box.visible = brushes
	_drag_box.visible = not brushes
	_placement_option.disabled = (
		brushes
		and (
			_brush_option.get_selected_id() == BuildController.BrushKind.SURFACE
			or _brush_option.get_selected_id() == BuildController.BrushKind.CLUSTER
		)
	)


## Rebuilds the labels/ranges for the selected brush. Width/Height/Length for
## Cuboid, Radius for Sphere, Radius+Height for Cylinder, Range for the two
## dynamic brushes.
func _update_brush_params() -> void:
	var kind := _brush_option.get_selected_id()
	var labels: Array[String] = ["W", "H", "L"]
	var ranges: Array[int] = [32, 32, 32]
	var visible_count := 3

	match kind:
		BuildController.BrushKind.SPHERE:
			labels = ["Radius", "", ""]
			ranges = [10, 1, 1]
			visible_count = 1
		BuildController.BrushKind.CYLINDER:
			labels = ["Radius", "Height", ""]
			ranges = [8, 8, 1]
			visible_count = 2
		BuildController.BrushKind.SURFACE, BuildController.BrushKind.CLUSTER:
			labels = ["Range", "", ""]
			ranges = [10, 1, 1]
			visible_count = 1

	for index in 3:
		_param_labels[index].text = labels[index]
		_param_spins[index].max_value = ranges[index]
		_param_boxes[index].visible = index < visible_count


func _set_param_values(values: Vector3i) -> void:
	_param_spins[0].value = values.x
	_param_spins[1].value = maxi(1, values.y)
	_param_spins[2].value = maxi(1, values.z)


func _update_brush_hint() -> void:
	var kind := _brush_option.get_selected_id()
	var text := "All tools; W/H/L cuboid."
	if kind == BuildController.BrushKind.SPHERE:
		text = "All tools; radius sphere."
	elif kind == BuildController.BrushKind.CYLINDER:
		text = "All tools; vertical cylinder."
	elif kind == BuildController.BrushKind.SURFACE:
		text = "Overlay/Replace/Clear/Flatten; no placement offset."
	elif kind == BuildController.BrushKind.CLUSTER:
		text = "Replace or Clear connected blocks of the target type."
	_brush_hint.text = text
