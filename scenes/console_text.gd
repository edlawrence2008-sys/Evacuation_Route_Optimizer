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
				out.print_to_console("  plan_save [name]        - Saves the current assignment/routes as a reusable plan.")
				out.print_to_console("  plan_list               - Lists saved plans for the active save.")
				out.print_to_console("  plan_apply <id>         - Applies a saved plan to the live crowd.")
				out.print_to_console("  plan_render <id|off>    - Draws a saved plan in the live world.")
				out.print_to_console("  plan_paint <id>         - Loads a plan's routes into the Route Paint tool.")
				out.print_to_console("  plan_import <file>      - Imports an exported plan JSON into this save's library.")
				out.print_to_console("  route_paint_clear       - Clears the authored painted corridor for this layout.")
				out.print_to_console("  export [last|all|<id>]  - Writes tidy CSVs to user://exports.")
				out.print_to_console("  experiment_start <file> - Runs a manifest-driven batch experiment.")
				out.print_to_console("  experiment_dry_run <file> - Validates a manifest without running.")
				out.print_to_console("  experiment_status       - Prints the runner state.")
				out.print_to_console("  experiment_abort        - Stops after the current cell.")
				out.print_to_console("  fixture_build <s1|s2|s3|s4|clear> - Builds a deterministic test fixture.")
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

		"plan_save", "plan_save_current":
			var bridge: Node = _optimizer_bridge()

			if bridge == null:
				if out:
					out.print_to_console("Error: no optimizer bridge.")
			else:
				var plan_name := "Console plan %s" % Time.get_time_string_from_system()

				if not args.is_empty():
					plan_name = " ".join(args)

				var plan: Variant = bridge.call("capture_plan", plan_name)

				if plan == null:
					if out:
						out.print_to_console("Nothing to save: no optimizer assignment or live route.")
				else:
					var plan_id: String = PlanStore.save_plan(plan, plan_name)

					if out:
						out.print_to_console(
							"Saved plan '%s' (%d assignments, %d routes)."
							% [plan_id, plan.assignment_count(), plan.routes_with_polylines()]
						)

		"plan_list", "plans":
			var plans: Array = PlanStore.list_plans()

			if out:
				if plans.is_empty():
					out.print_to_console("No saved plans for this save.")
				else:
					for plan: Dictionary in plans:
						out.print_to_console(
							"  %-32s %4d agents  seed %d  %s"
							% [
								String(plan.get("id", "")),
								int(plan.get("assignments", 0)),
								int(plan.get("seed", 0)),
								String(plan.get("created_at", "")),
							]
						)

		"plan_apply", "plan_load":
			var bridge: Node = _optimizer_bridge()

			if bridge == null:
				if out:
					out.print_to_console("Error: no optimizer bridge.")
			elif args.is_empty():
				if out:
					out.print_to_console("Usage: plan_apply <plan id>")
			else:
				var plan: Variant = PlanStore.load_plan(String(args[0]))

				if plan == null:
					if out:
						out.print_to_console("Plan not found: %s" % String(args[0]))
				else:
					var result: Dictionary = bridge.call("apply_plan", plan)

					if out:
						if bool(result.get("ok", false)):
							out.print_to_console(
								"Applied %s: %d applied, %d skipped, %d unmatched."
								% [
									String(args[0]),
									int(result.get("applied", 0)),
									int(result.get("skipped", 0)),
									int(result.get("missing", 0)),
								]
							)
						else:
							out.print_to_console(
								"Apply failed: %s" % String(result.get("error", "unknown"))
							)

		"plan_import", "plan_load_file":
			if args.is_empty():
				if out:
					out.print_to_console("Usage: plan_import <plan.json>")
			else:
				var plan_path := String(args[0])

				if not FileAccess.file_exists(plan_path):
					for prefix: String in ["res://", "user://"]:
						if FileAccess.file_exists(prefix + plan_path):
							plan_path = prefix + plan_path
							break

				var plan: Variant = EvacuationPlan.load_from(plan_path)

				if plan == null:
					if out:
						out.print_to_console("Could not read a plan from: %s" % plan_path)
				else:
					var plan_id: String = PlanStore.save_plan(plan)
					var bridge: Node = _optimizer_bridge()

					if bridge != null:
						bridge.call("set_startup_plan", plan)

					if out:
						out.print_to_console(
							"Imported %s (%d assignments, %d routes); armed for the next Start."
							% [plan_id, plan.assignment_count(), plan.routes_with_polylines()]
						)

		"plan_render", "plan_show":
			if args.is_empty():
				if out:
					out.print_to_console("Usage: plan_render <plan id|off>")
			elif String(args[0]).to_lower() == "off":
				LivePlanOverlay.hide_plan()

				if out:
					out.print_to_console("Live plan overlay hidden.")
			else:
				var plan: Variant = PlanStore.load_plan(String(args[0]))

				if plan == null:
					if out:
						out.print_to_console("Plan not found: %s" % String(args[0]))
				elif LivePlanOverlay.show_plan(plan):
					if out:
						out.print_to_console(
							"Rendering plan '%s' (%d assignments, %d routes)."
							% [String(args[0]), plan.assignment_count(), plan.routes_with_polylines()]
						)
				elif out:
					out.print_to_console("Could not create the live plan overlay.")

		"plan_paint", "plan_edit":
			if args.is_empty():
				if out:
					out.print_to_console("Usage: plan_paint <plan id>")
			else:
				var plan: Variant = PlanStore.load_plan(String(args[0]))

				if plan == null:
					if out:
						out.print_to_console("Plan not found: %s" % String(args[0]))
				else:
					var count: int = RoutePainter.set_from_plan(plan)

					if out:
						out.print_to_console(
							"Loaded %d painted route cells from '%s'. Equip the Route Paint tool to edit."
							% [count, String(args[0])]
						)

		"route_paint_clear", "paint_clear":
			RoutePainter.clear_all()

			if out:
				out.print_to_console("Authored route paint cleared for this layout.")

		"export":
			var demo_id := "last"

			if not args.is_empty():
				demo_id = String(args[0])

			var output_root := ExperimentExporter.output_root()

			if args.size() > 1:
				output_root = String(args[1])

			var result: Dictionary = {}

			if demo_id == "all":
				result = ExperimentExporter.export_all_active_save(output_root)
			elif demo_id == "last":
				var last_id := SimRecorder.get_demo_id()

				if last_id.is_empty():
					var demos: Array = DemoStore.list_demos()

					if not demos.is_empty():
						last_id = String(demos[0].get("id", ""))

				result = ExperimentExporter.export_demo(last_id, output_root)
			else:
				result = ExperimentExporter.export_demo(demo_id, output_root)

			if out:
				if bool(result.get("ok", false)):
					out.print_to_console(
						"Export: %d run(s) -> %s"
						% [int(result.get("runs", 0)), String(result.get("output_display", ""))]
					)
				else:
					out.print_to_console(
						"Export failed: %s" % str(result.get("error", result.get("errors", "")))
					)

		"experiment_start":
			if args.is_empty():
				if out:
					out.print_to_console("Usage: experiment_start <manifest.json>")
			else:
				var status: Dictionary = ExperimentRunner.status()

				if bool(status.get("running", false)):
					if out:
						out.print_to_console("An experiment is already running.")
				else:
					# start_from_file() is a coroutine; defer it so the console
					# does not need to await the whole batch.
					ExperimentRunner.call_deferred("start_from_file", String(args[0]))

					if out:
						out.print_to_console("Experiment start requested: %s" % String(args[0]))

		"experiment_dry_run", "experiment_check":
			if args.is_empty():
				if out:
					out.print_to_console("Usage: experiment_dry_run <manifest.json>")
			else:
				var result: Dictionary = ExperimentRunner.dry_run(String(args[0]))

				if out:
					if bool(result.get("ok", false)):
						out.print_to_console(
							"Manifest OK: %d cell(s), %d scenario(s), output %s"
							% [
								int(result.get("cells", 0)),
								int(result.get("scenarios", 0)),
								String(result.get("output_display", "")),
							]
						)
					else:
						out.print_to_console("Manifest invalid: %s" % str(result.get("errors", [])))

		"experiment_status":
			if out:
				var status: Dictionary = ExperimentRunner.status()
				out.print_to_console(
					"Runner: %s %s (%d/%d) - %s"
					% [
						"running" if bool(status.get("running", false)) else "idle",
						String(status.get("experiment", "")),
						int(status.get("index", 0)),
						int(status.get("total", 0)),
						String(status.get("status", "")),
					]
				)

		"experiment_abort":
			ExperimentRunner.abort()

			if out:
				out.print_to_console("Experiment abort requested.")

		"fixture_build", "fixture":
			if args.is_empty():
				if out:
					out.print_to_console("Usage: fixture_build <s1|s2|s3|s4|clear>")
			else:
				var result: Dictionary = ExperimentFixture.build_preset(String(args[0]))

				if out:
					if bool(result.get("ok", false)):
						out.print_to_console(
							"Fixture built: %d exits, %s cells."
							% [int(result.get("exits", 0)), str(result.get("cells", 0))]
						)
					else:
						out.print_to_console("Fixture failed: %s" % String(result.get("error", "")))

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
