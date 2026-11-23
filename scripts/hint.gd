extends RichTextLabel

func _ready() -> void:
	bbcode_enabled = true
	text = ""

func display_hint(action_name: String, key_name: String):
	# Example: Grab [E] 
	# The [color] tag makes the key stand out
	text = "[center]%s [color=yellow][%s][/color][/center]" % [action_name, key_name]

func clear_hint():
	text = ""
