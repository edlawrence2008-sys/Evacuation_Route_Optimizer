extends Node

@export var console_output_path: NodePath = NodePath("../ConsoleOutput")

var log_path = "user://logs/godot.log"
var file: FileAccess
var last_position: int = 0

func _ready() -> void:
	# Use a small timer delay to let the game fully boot and initialize the log file
	var timer = Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(_check_for_new_logs)
	add_child(timer)

func _check_for_new_logs() -> void:
	if not FileAccess.file_exists(log_path):
		return
		
	file = FileAccess.open(log_path, FileAccess.READ)
	if not file:
		return
		
	# If the file shrank (e.g. game restarted / log cleared), reset position
	var current_len = file.get_length()
	if current_len < last_position:
		last_position = 0
		
	if current_len > last_position:
		file.seek(last_position)
		
		while file.get_position() < current_len:
			var line = file.get_line()
			_process_log_line(line)
			
		last_position = file.get_position()
		
	file.close()

func _process_log_line(line: String) -> void:
	if line.strip_edges().is_empty():
		return
		
	var out = get_node_or_null(console_output_path)
	if out and out.has_method("print_to_console"):
		# Optional: Color code errors or warnings differently if they appear in the log
		if "ERROR:" in line or "SCRIPT ERROR:" in line:
			out.print_to_console("[color=red]" + line + "[/color]")
		elif "WARNING:" in line:
			out.print_to_console("[color=yellow]" + line + "[/color]")
		else:
			out.print_to_console(line)
