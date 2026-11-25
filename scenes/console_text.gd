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
		if out: out.print_to_console("Error: GlobalData node not found at path: %s" % global_data_node_path)
		return

	match command:
		"/help":
			if out:
				out.print_to_console("=== Available Commands ===")
<<<<<<< Updated upstream
				out.print_to_console("  /setglobalunitcap <int>   - Sets the global unit cap.")
				out.print_to_console("  /debug_greedy [on|off]   - Toggles debug greedy-mesh colours.")
				out.print_to_console("  /ao [on|off]             - Toggles baked voxel-corner ambient occlusion.")
				out.print_to_console("  /path_mode [astar|flow]  - Switches between A* and baked flow fields.")
				out.print_to_console("  /show_paths [on|off]     - Toggles A* paths and flow-field arrows.")
				out.print_to_console("  /clear                    - Clears the console window.")
=======
				out.print_to_console("  setglobalunitcap <int>   - Sets the global unit cap.")
				out.print_to_console("  debug_greedy [on|off]   - Toggles debug greedy-mesh colours.")
				out.print_to_console("  ao [on|off]             - Toggles baked voxel-corner ambient occlusion.")
				out.print_to_console("  lod [on|off]            - Toggles distance LOD for the chunk mesher.")
				out.print_to_console("  slabs                    - Adds half-step bottom slabs to the loaded world's risers.")
				out.print_to_console("  water_lake [r] [depth] [sim] - Creates a calm (or simulated) lake at the player.")
				out.print_to_console("  water_fill [r] [amount]  - Adds volume around the player.")
				out.print_to_console("  water_drain [r] [amount] - Removes volume around the player.")
				out.print_to_console("  water_info               - Prints water body/cell counts.")
				out.print_to_console("  water_clear              - Removes every water body.")
				out.print_to_console("  gas [amount] [radius]    - Adds LPG-like gas at the player.")
				out.print_to_console("  smoke [amount] [radius]  - Adds smoke at the player.")
				out.print_to_console("  gas_clear                - Clears the gas and smoke fields.")
				out.print_to_console("  path_mode [astar|flow]  - Switches between A* and baked flow fields.")
				out.print_to_console("  show_paths [on|off]     - Toggles A* paths and flow-field arrows.")
				out.print_to_console("  opt_overlay [on|off]    - Toggles the optimizer assignment overlay.")
				out.print_to_console("  opt_resolve             - Requests one optimizer solve now.")
				out.print_to_console("  opt_interval <s>        - Sets the periodic re-solve interval.")
				out.print_to_console("  clear                   - Clears the console window.")

>>>>>>> Stashed changes
				out.print_to_console("\n--- GlobalData Script Methods ---")
				
				# Check if GlobalData actually has an attached script
				var script = g_data.get_script()
				if script:
					for method in script.get_script_method_list():
						var m_name = method["name"]
						if not m_name.begins_with("_"):
							out.print_to_console("  /%s" % m_name)
			
		"/setglobalunitcap":
			if args.size() > 0 and args[0].is_valid_int():
				g_data.global_unit_cap = args[0].to_int()
				if out: out.print_to_console("Global unit cap set to: %d" % g_data.global_unit_cap)
			else:
				if out: out.print_to_console("Usage: /setglobalunitcap <integer_value>")
				
		"/debug_greedy", "/greedy", "/greedy_colors", "/debug_greedy_meshing":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out: out.print_to_console("Error: no grid map found.")
			else:
				var enabled: bool = _resolve_toggle(args, grid.debug_greedy_colors)
				grid.debug_greedy_colors = enabled
				if out:
					out.print_to_console("Debug greedy colours: %s" % ("ON" if enabled else "OFF"))

		"/ao", "/baked_ao", "/ambient_occlusion":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out: out.print_to_console("Error: no grid map found.")
			else:
				var enabled: bool = _resolve_toggle(args, grid.baked_ao_enabled)
				grid.baked_ao_enabled = enabled
				if out:
					out.print_to_console(
						"Baked voxel AO: %s"
						% ("ON (greedy merging deferred)" if enabled else "OFF")
					)

		"/path_mode", "/pathfinding", "/flowfields", "/flow_fields":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
<<<<<<< Updated upstream
				if out: out.print_to_console("Error: no grid map found.")
=======
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

		"water_lake", "lake":
			var world = get_tree().get_first_node_in_group("water_world")
			var player = get_tree().get_first_node_in_group("player")
			if world == null or player == null:
				if out:
					out.print_to_console("Error: need a WaterWorld node and a player.")
			else:
				var radius := float(args[0]) if args.size() > 0 and args[0].is_valid_float() else 8.0
				var depth := float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 1.0
				var simulated := args.size() > 2 and args[2] == "1"
				var body_id: int = world.call(
					"create_lake_at",
					player.global_position,
					radius,
					depth,
					simulated,
					2.0
				)
				if out:
					out.print_to_console(
						"Water body %d: radius %.1f, depth %.1f, %s."
						% [body_id, radius, depth, "simulated" if simulated else "calm"]
					)

		"water_fill", "water_add":
			var world = get_tree().get_first_node_in_group("water_world")
			var player = get_tree().get_first_node_in_group("player")
			if world == null or player == null:
				if out:
					out.print_to_console("Error: need a WaterWorld node and a player.")
			else:
				var radius := float(args[0]) if args.size() > 0 and args[0].is_valid_float() else 3.0
				var amount := float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 0.5
				var changed: int = world.call(
					"add_water_area",
					player.global_position,
					radius,
					amount
				)
				if out:
					out.print_to_console("Water added to %d cells." % changed)

		"water_drain", "water_remove":
			var world = get_tree().get_first_node_in_group("water_world")
			var player = get_tree().get_first_node_in_group("player")
			if world == null or player == null:
				if out:
					out.print_to_console("Error: need a WaterWorld node and a player.")
			else:
				var radius := float(args[0]) if args.size() > 0 and args[0].is_valid_float() else 3.0
				var amount := float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 0.5
				var changed: int = world.call(
					"remove_water_area",
					player.global_position,
					radius,
					amount
				)
				if out:
					out.print_to_console("Water removed from %d cells." % changed)

		"water_clear":
			var world = get_tree().get_first_node_in_group("water_world")
			if world != null:
				world.call("clear_all")
			if out:
				out.print_to_console("Water cleared.")

		"water_info":
			var world = get_tree().get_first_node_in_group("water_world")
			if world == null:
				if out:
					out.print_to_console("Error: no WaterWorld node.")
			else:
				var stats: Dictionary = world.call("get_stats")
				if out:
					out.print_to_console(
						"Water: %d bodies, %d cells, %d wet, %d meshes."
						% [
							int(stats.get("bodies", 0)),
							int(stats.get("cells", 0)),
							int(stats.get("wet_cells", 0)),
							int(stats.get("meshes", 0)),
						]
					)

		"gas", "gas_add":
			var hazard = get_tree().get_first_node_in_group("hazard_world")
			var player = get_tree().get_first_node_in_group("player")
			if hazard == null or player == null:
				if out:
					out.print_to_console("Error: need a HazardWorld node and a player.")
			else:
				var amount := float(args[0]) if args.size() > 0 and args[0].is_valid_float() else 1.0
				var radius := float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 2.0
				hazard.call("add_gas", player.global_position, amount, radius)
				if out:
					out.print_to_console("Gas added (%.2f, radius %.1f)." % [amount, radius])

		"smoke", "smoke_add":
			var hazard = get_tree().get_first_node_in_group("hazard_world")
			var player = get_tree().get_first_node_in_group("player")
			if hazard == null or player == null:
				if out:
					out.print_to_console("Error: need a HazardWorld node and a player.")
			else:
				var amount := float(args[0]) if args.size() > 0 and args[0].is_valid_float() else 1.0
				var radius := float(args[1]) if args.size() > 1 and args[1].is_valid_float() else 2.0
				hazard.call("add_smoke", player.global_position + Vector3.UP, amount, radius)
				if out:
					out.print_to_console("Smoke added (%.2f, radius %.1f)." % [amount, radius])

		"gas_clear":
			var hazard = get_tree().get_first_node_in_group("hazard_world")
			if hazard != null:
				hazard.call("clear_all")
			if out:
				out.print_to_console("Gas and smoke cleared.")

		"path_mode", "pathfinding", "flowfields", "flow_fields":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out:
					out.print_to_console("Error: no grid map found.")
>>>>>>> Stashed changes
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

		"/show_paths", "/paths", "/debug_paths":
			var grid = get_tree().get_first_node_in_group("grid_map")
			if grid == null:
				if out: out.print_to_console("Error: no grid map found.")
			else:
				var enabled: bool = _resolve_toggle(args, grid.debug_show_paths)
				grid.debug_show_paths = enabled
				if out:
					out.print_to_console("Path debug drawing: %s" % ("ON" if enabled else "OFF"))

		"/clear":
			if out and out.has_method("clear_console"):
				out.clear_console()
			
		_:
			var clean_cmd = command
			if clean_cmd.begins_with("/"):
				clean_cmd = clean_cmd.substr(1)
			
			if g_data.has_method(clean_cmd):
				var converted_args = []
				for arg in args:
					if arg.is_valid_int():
						converted_args.append(arg.to_int())
					elif arg.is_valid_float():
						converted_args.append(arg.to_float())
					else:
						converted_args.append(arg)
				
				var result = g_data.callv(clean_cmd, converted_args)
				if out:
					if result != null:
						out.print_to_console("Result: %s" % str(result))
					else:
						out.print_to_console("Executed /%s successfully." % clean_cmd)
			else:
				if out: out.print_to_console("Unknown command: '%s'. Type /help for options." % command)


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
