extends Control

# --- Node References ---
@onready var texture_rect = $TextureRect
@onready var icon = $TextureRect/TextureRect_Icon
@onready var label = $TextureRect/Label

func _ready():
	await get_tree().process_frame  # Wait for layout so size is valid
	_center_pivot(self)
	_center_pivot(icon)
	
	# --- Initial State Configuration ---
	scale = Vector2(1.0, 1.0)
	
	# Set independent initial colors using self_modulate
	self_modulate        = Color(1.0, 1.0, 1.0, 1.0) # Root node wrapper
	texture_rect.self_modulate = Color(0.2, 0.2, 0.2, 0.8) # Just the slot background
	icon.self_modulate         = Color(1.0, 1.0, 1.0, 1.0) # Just the item icon
	label.self_modulate        = Color(1.0, 1.0, 1.0, 1.0) # Just the text font tint

# Called by HUD to assign this slot's index label
func set_index(index: int):
	label.text = str(index + 1) # 1-based display (1, 2, 3...)

# Called by HUD to update the icon
func set_item(item_data):
	_center_pivot(self)
	_center_pivot(icon)
	
	if item_data != null and item_data.data != null:
		icon.texture = item_data.data.icon
		icon.show()
	else:
		icon.texture = null
		icon.hide()

# Called by HUD when this slot becomes the active one
func set_active():
	var tween = create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector2(1.1, 1.1), 0.1)
	
	# --- Active Colors via self_modulate ---
	tween.tween_property(texture_rect, "self_modulate", Color(0.98, 0.0, 0.0, 1.0), 0.1)
	tween.tween_property(icon,         "self_modulate", Color(0.98, 0.0, 0.0, 1.0), 0.1)
	tween.tween_property(label,        "self_modulate", Color(1.0, 1.0, 1.0, 1.0), 0.1)

func set_inactive():
	var tween = create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.1)
	
	# --- Inactive Colors via self_modulate ---
	tween.tween_property(texture_rect, "self_modulate", Color(0.2, 0.2, 0.2, 0.8), 0.1)
	tween.tween_property(icon,         "self_modulate", Color(0.51, 0.25, 0.25, 1.0), 0.1)
	tween.tween_property(label,        "self_modulate", Color(1.0, 1.0, 1.0, 1.0), 0.1)

func _center_pivot(node: Control):
	node.pivot_offset = node.size / 2
