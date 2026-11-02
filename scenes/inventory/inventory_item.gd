extends Control

signal item_selected(item_id: int)

@onready var texture_rect: TextureRect = $TextureRect
@onready var label: Label = $Label
@onready var top_or_bottom: Sprite2D = $Top_Or_Bottom
@onready var sprite_2d: Sprite2D = $Sprite2D # Reference to your background Sprite2D

var item_id: int = -1

func setup(id: int, item_name: String, icon: Texture2D = null) -> void:
	item_id = id
	
	# --- SET TOOLTIP TO TRUE NAME ---
	tooltip_text = item_name  # Shows the raw/true name on hover
	
	if label:
		var clean_name = item_name.trim_prefix("Auto_")
		var lower_name = clean_name.to_lower()
		
		# Remove slab prefix and add _Slab suffix for slab items
		if lower_name.begins_with("slab_top"):
			clean_name = clean_name.substr(8).trim_prefix("_") + "_Slab"
		elif lower_name.begins_with("slab_bottom"):
			clean_name = clean_name.substr(11).trim_prefix("_") + "_Slab"
			
		label.text = clean_name
	
	if texture_rect:
		if icon:
			texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			texture_rect.texture = icon
			texture_rect.visible = true
			texture_rect.scale = Vector2.ONE
			# Sets the pivot point to the center so it scales and stays centered
			texture_rect.pivot_offset = texture_rect.size / 2
			
			# Hide Sprite2D and Label when TextureRect has an icon to display
			if sprite_2d:
				sprite_2d.visible = false
			if label:
				label.visible = false
		else:
			texture_rect.visible = false
			
			# Unhide Sprite2D and Label when there is no icon
			if sprite_2d:
				sprite_2d.visible = true
			if label:
				label.visible = true

	# Handle $Top_Or_Bottom visibility and orientation based on "slab_" prefix
	if top_or_bottom:
		var clean_name_node = item_name.trim_prefix("Auto_").to_lower()
		if clean_name_node.begins_with("slab_"):
			top_or_bottom.visible = true
			if clean_name_node.begins_with("slab_bottom"):
				top_or_bottom.flip_v = true  # Flips vertically for bottom slab
			else:
				top_or_bottom.flip_v = false # Keeps default orientation for top slab
		else:
			top_or_bottom.visible = false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		item_selected.emit(item_id)

func _on_mouse_entered() -> void:
	if texture_rect and texture_rect.visible:
		texture_rect.modulate = Color(1.5, 1.5, 1.5) # Brightens/whitens the icon
	
	if label and label.visible:
		label.modulate = Color(0.2, 0.2, 0.2) # Darkens/makes the text blacker

func _on_mouse_exited() -> void:
	if texture_rect and texture_rect.visible:
		texture_rect.modulate = Color(1, 1, 1) # Resets icon color
	
	if label and label.visible:
		label.modulate = Color(1, 1, 1) # Resets text color
