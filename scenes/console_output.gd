extends RichTextLabel

func _ready() -> void:
	text = "=== GAME CONSOLE ===\nType /help for a list of commands.\n"
	# Keep built-in scroll following enabled as well
	scroll_following = true

func print_to_console(message: String) -> void:
	text += message + "\n"
	# Defer scrolling to the next frame so the label has time 
	# to recalculate its line wrapping and max scroll height.
	call_deferred("_scroll_to_bottom")

func clear_console() -> void:
	text = ""

func _scroll_to_bottom() -> void:
	var v_bar = get_v_scroll_bar()
	if v_bar:
		v_bar.value = v_bar.max_value
