extends LineEdit

@export var global_data_node_path: NodePath = NodePath("/root/GlobalData") 
@export var console_output_path: NodePath = NodePath("../ConsoleOutput")
@export var console_control: NodePath = NodePath("..")

func _ready() -> void:
	# Hide the entire console container by default on start
	var ctrl = get_node_or_null(console_control)
	if ctrl:
		ctrl.visible = false
		
	text = "> "
	set_caret_column(2)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_console_toggle"):
		var ctrl = get_node_or_null(console_control)
		if not ctrl:
			return
			
		ctrl.visible = !ctrl.visible
		
		# --- PLAYER MOVEMENT & MOUSE TOGGLE ---
		var player = get_tree().get_first_node_in_group("player")
		
		if ctrl.visible:
			grab_focus()
			set_caret_column(text.length())
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			if player and player.has_method("set_movement_enabled"):
				player.set_movement_enabled(false)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			if player and player.has_method("set_movement_enabled"):
				player.set_movement_enabled(true)
				
		accept_event()

func _gui_input(event: InputEvent) -> void:
	var ctrl = get_node_or_null(console_control)
	if ctrl and not ctrl.visible:
		return
		
	if event is InputEventKey and event.pressed:
		var prompt_prefix = "> "
		var c_col = get_caret_column()
		
		# Prevent moving or deleting before the prompt prefix
		if c_col < prompt_prefix.length():
			if event.keycode != KEY_BACKSPACE and event.keycode != KEY_LEFT:
				set_caret_column(prompt_prefix.length())
		
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			var full_line = text
			if full_line.begins_with(prompt_prefix):
				var command_str = full_line.substr(prompt_prefix.length()).strip_edges()
				
				# Echo user command to the output RichTextLabel
				var out = get_node_or_null(console_output_path)
				if out and out.has_method("print_to_console"):
					out.print_to_console("> " + command_str)
				
				_process_command(command_str)
				
				# Reset input line for next command
				text = "> "
				set_caret_column(2)
				accept_event()
		elif event.keycode == KEY_BACKSPACE:
			if c_col <= prompt_prefix.length():
				accept_event()


func _process_command(cmd_line: String) -> void:
	if cmd_line.is_empty():
		return

	var tokens = cmd_line.split(" ", false)
	var command = tokens[0].to_lower()
	var args = tokens.slice(1)

	var g_data = get_node_or_null(global_data_node_path)
	var out = get_node_or_null(console_output_path)

	if not g_data:
		if out:
			out.print_to_console("Error: GlobalData node not found at path: %s" % global_data_node_path)
		return

	match command:
		"help":
			if out:
				out.print_to_console("=== Available Commands ===")
				out.print_to_console("  setglobalunitcap <int>   - Sets the global unit cap.")
				out.print_to_console("  debug_greedy [on|off]   - Toggles debug greedy-mesh colours.")
				out.print_to_console("  ao [on|off]             - Toggles baked voxel-corner ambient occlusion.")
				out.print_to_console("  lod [on|off]            - Toggles distance LOD for the chunk mesher.")
				out.print_to_console("  slabs                    - Adds half-step bottom slabs to the loaded world's risers.")
				out.print_to_console("  path_mode [astar|flow]  - Switches between A* and baked flow fields.")
				out.print_to_console("  show_paths [on|off]     - Toggles A* paths and flow-field arrows.")
				out.print_to_console("  opt_overlay [on|off]    - Toggles the optimizer assignment overlay.")
				out.print_to_console("  opt_resolve             - Requests one optimizer solve now.")
				out.print_to_console("  opt_interval <s>        - Sets the periodic re-solve interval.")
				out.print_to_console("  clear                   - Clears the console window.")

				out.print_to_console("\n--- GlobalData Script Methods ---")

				var script = g_data.get_script()
				if script:
					for method in script.get_script_method_list():
						var m_name = method["name"]
						if not m_name.begins_with("_"):
							out.print_to_console("  %s" % m_name)

		"setglobalunitcap":
			if args.size() > 0 and args[0].is_valid_int():
				g_data.global_unit_cap = args[0].to_int()
				if out:
					out.print_to_console("Global unit cap set to: %d" % g_data.global_unit_cap)
			else:
				if out:
					out.print_to_console("Usage: setglobalunitcap <integer_value>")

		"debug_greedy", "greedy", "greedy_colors", "debug_greedy_meshing":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out:
					out.print_to_console("Error: no grid map found.")
			else:
				var enabled: bool = _resolve_toggle(args, grid.debug_greedy_colors)
				grid.debug_greedy_colors = enabled
				if out:
					out.print_to_console("Debug greedy colours: %s" % ("ON" if enabled else "OFF"))

		"ao", "baked_ao", "ambient_occlusion":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out:
					out.print_to_console("Error: no grid map found.")
			else:
				var enabled: bool = _resolve_toggle(args, grid.baked_ao_enabled)
				grid.baked_ao_enabled = enabled
				if out:
					out.print_to_console(
						"Baked voxel AO: %s"
						% ("ON (greedy merging deferred)" if enabled else "OFF")
					)

		"lod", "lod_enabled":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out:
					out.print_to_console("Error: no grid map found.")
			else:
				var mesher = grid.get_mesher()

				if mesher == null:
					if out:
						out.print_to_console("No chunk mesher is active.")
				else:
					var enabled: bool = _resolve_toggle(args, mesher.is_lod_enabled())
					var streamer = get_tree().get_first_node_in_group("chunk_streamer")

					if streamer != null:
						streamer.lod_override = 1 if enabled else 0

					mesher.set_lod_enabled(enabled)

					if out:
						out.print_to_console(
							"Distance LOD: %s" % ("ON" if enabled else "OFF")
						)

		"slabs", "step_slabs":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out:
					out.print_to_console("Error: no grid map found.")
			else:
				var placed: int = grid.add_step_slabs(46)

				if out:
					out.print_to_console(
						"Step slabs: %d added." % placed
					)

		"path_mode", "pathfinding", "flowfields", "flow_fields":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out:
					out.print_to_console("Error: no grid map found.")
			else:
				var use_flow: bool = grid.enable_flow_fields

				if not args.is_empty():
					var mode := str(args[0]).to_lower()
					match mode:
						"astar", "a*", "a_star", "a-star", "a":
							use_flow = false
						"flow", "flowfield", "flowfields", "baked", "f":
							use_flow = true
						_:
							use_flow = _resolve_toggle(args, grid.enable_flow_fields)
				else:
					use_flow = not use_flow

				grid.enable_flow_fields = use_flow
				if out:
					out.print_to_console(
						"Path mode: %s"
						% ("baked flow fields" if use_flow else "A*")
					)

		"show_paths", "paths", "debug_paths":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out:
					out.print_to_console("Error: no grid map found.")
			else:
				var enabled: bool = _resolve_toggle(args, grid.debug_show_paths)
				grid.debug_show_paths = enabled
				if out:
					out.print_to_console("Path debug drawing: %s" % ("ON" if enabled else "OFF"))

		"opt_overlay", "optimizer_overlay":
			var bridge: Node = _optimizer_bridge()

			if bridge == null:
				if out:
					out.print_to_console("Error: no optimizer bridge.")
			else:
				var enabled: bool = _resolve_toggle(
					args, bool(bridge.get("overlay_enabled"))
				)
				bridge.call("set_overlay_enabled", enabled)

				if out:
					out.print_to_console(
						"Optimizer overlay: %s" % ("ON" if enabled else "OFF")
					)

		"opt_resolve", "optimizer_solve":
			var bridge: Node = _optimizer_bridge()

			if bridge == null:
				if out:
					out.print_to_console("Error: no optimizer bridge.")
			else:
				bridge.call("request_solve")

				if out:
					out.print_to_console("Optimizer solve requested.")

		"opt_interval", "optimizer_interval":
			var bridge: Node = _optimizer_bridge()

			if bridge == null:
				if out:
					out.print_to_console("Error: no optimizer bridge.")
			elif args.is_empty():
				if out:
					out.print_to_console(
						"Re-solve interval: %.1f s."
						% float(bridge.get("re_solve_interval"))
					)
			elif str(args[0]).is_valid_float():
				bridge.call("set_re_solve_interval", float(args[0]))

				if out:
					out.print_to_console(
						"Re-solve interval: %.1f s."
						% float(bridge.get("re_solve_interval"))
					)
			else:
				if out:
					out.print_to_console("Usage: opt_interval <seconds>")

		"clear":
			if out and out.has_method("clear_console"):
				out.clear_console()

		_:
			if g_data.has_method(command):
				var converted_args = []

				for arg in args:
					if arg.is_valid_int():
						converted_args.append(arg.to_int())
					elif arg.is_valid_float():
						converted_args.append(arg.to_float())
					else:
						converted_args.append(arg)

				var result = g_data.callv(command, converted_args)

				if out:
					if result != null:
						out.print_to_console("Result: %s" % str(result))
					else:
						out.print_to_console("Executed %s successfully." % command)
			else:
				if out:
					out.print_to_console("Unknown command: '%s'. Type help for options." % command)


func _resolve_toggle(args: Array, current_value: bool) -> bool:
	if args.is_empty():
		return not current_value

	var value := str(args[0]).to_lower()
	match value:
		"on", "true", "1", "yes", "enable", "enabled":
			return true
		"off", "false", "0", "no", "disable", "disabled":
			return false
		_:
			return not current_value


func _optimizer_bridge() -> Node:
	return get_tree().get_first_node_in_group("optimizer_bridge")
