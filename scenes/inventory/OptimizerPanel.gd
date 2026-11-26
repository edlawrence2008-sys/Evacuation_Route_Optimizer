class_name OptimizerPanel
extends Control

## Right-side optimizer panel, modelled on the block/placeable property tab.
##
## It owns the OptimizerBridge (as a child) and all optimizer controls, and
## describes what each method and objective actually does. The Simulation panel
## only opens it.

signal state_changed(text: String)

const FONT := preload("res://font/7-12-serif.otf")
const GOLD := Color(1.0, 0.85, 0.35, 1.0)
const TEXT := Color(0.92, 0.92, 0.88, 1.0)
const MUTED := Color(0.68, 0.68, 0.64, 1.0)

const ALGORITHMS: Array[String] = [
	OptimizationRequest.ALGORITHM_NEAREST,
	OptimizationRequest.ALGORITHM_EQUAL_SPLIT,
	OptimizationRequest.ALGORITHM_GREEDY,
	OptimizationRequest.ALGORITHM_GREEDY_CONGESTION,
	OptimizationRequest.ALGORITHM_EXHAUSTIVE,
	OptimizationRequest.ALGORITHM_LOCAL_SEARCH,
	OptimizationRequest.ALGORITHM_ACO,
	OptimizationRequest.ALGORITHM_PSO,
	OptimizationRequest.ALGORITHM_NETWORK_FLOW,
	OptimizationRequest.ALGORITHM_TIME_EXPANDED,
]

const MODE_LABELS: Array[String] = [
	"Fastest",
	"Balanced",
	"Congestion",
	"Safety",
	"Disruption",
]

const ALGORITHM_DESCRIPTIONS: Dictionary = {
	"nearest": "Control condition. Each cohort walks to the exit with the shortest predicted travel time; queues and crowding are ignored.",
	"equal_split": "Balances the number of agents per exit and ignores geometry except reachability. Tests whether an even split is actually better.",
	"greedy": "Assigns the largest cohorts first and evaluates every reachable exit with the full objective. Fast, deterministic and capacity-aware.",
	"greedy_congestion": "Assigns cohorts one by one and prices only the marginal queue and corridor congestion each one adds. Cheaper than full evaluations and explicitly congestion-aware.",
	"exhaustive": "Tries every cohort-to-exit combination. Exact for small instances; stops at the combination or time budget and reports when it is not proven.",
	"local_search": "Starts from greedy, moves cohorts between exits and swaps pairs while the objective improves. The practical reference for the metaheuristics.",
	"aco": "Ant colony: pheromone-guided assignments with a congestion-priced heuristic, seeded by local search and restarted on stagnation.",
	"pso": "Particle swarm over a random-key encoding, seeded by local search. Swarm movement can jump between local optima that a hill climb cannot.",
	"network_flow": "Min-cost flow in a static transportation network. Exits are capacity-limited over a horizon; timing and queue order are ignored.",
	"time_expanded": "Min-cost flow in a time-expanded network: exit service slots exist per time bin, the current queue occupies early slots, and waiting has a cost.",
}

const MODE_DESCRIPTIONS: Dictionary = {
	"fastest": "Minimise evacuation completion time. Congestion and queues carry a small weight.",
	"balanced": "Trade completion time, predicted congestion and exit queue waiting time.",
	"congestion": "Put more weight on predicted corridor overload and less on raw completion time.",
	"safety": "Reserved for contact-force and hazard exposure. Until those terms exist it behaves like balanced.",
	"disruption": "Bias the assignment away from the busiest or most disrupted exits.",
}

var bridge: OptimizerBridge = null

var _enabled: CheckButton = null
var _algorithm: OptionButton = null
var _algorithm_description: Label = null
var _mode: OptionButton = null
var _mode_description: Label = null
var _cohort: SpinBox = null
var _max_cohorts: SpinBox = null
var _auto: CheckButton = null
var _resolve: CheckButton = null
var _interval: SpinBox = null
var _overlay: CheckButton = null
var _run: Button = null
var _status: Label = null
var _result: Label = null
var _aco_params: GridContainer = null
var _ants: SpinBox = null
var _iterations: SpinBox = null
var _budget: SpinBox = null
var _pso_params: GridContainer = null
var _swarm: SpinBox = null
var _pso_iterations: SpinBox = null
var _first_solve: SpinBox = null
var _wait_for_spawn: CheckButton = null
var _hysteresis: CheckButton = null
var _hysteresis_ratio: SpinBox = null
var _plan_name: LineEdit = null
var _plan_select: OptionButton = null
var _plan_apply_on_start: CheckButton = null
var _plan_status: Label = null
var _plan_detail: Label = null
var _plan_apply_button: Button = null
var _plan_arm_button: Button = null
var _plan_show_button: Button = null
var _plan_paint_button: Button = null
var _plan_delete_button: Button = null
var _plan_ids: Array[String] = []


func _ready() -> void:
	_build_theme()
	_build_ui()
	_create_bridge()

	var parent := get_parent()

	if parent is Control:
		(parent as Control).visibility_changed.connect(_on_parent_visibility)

	visible = false


func open_panel() -> void:
	visible = true
	move_to_front()
	_sync_controls()


func close_panel() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close_panel()
	else:
		open_panel()


func is_open() -> bool:
	return visible


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_theme() -> void:
	var panel_theme := Theme.new()
	panel_theme.default_font = FONT
	panel_theme.default_font_size = 13
	theme = panel_theme


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 4)
	scroll.add_child(column)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	column.add_child(title_row)

	var title := Label.new()
	title.text = "Optimizer"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", GOLD)
	title.add_theme_font_size_override("font_size", 20)
	title_row.add_child(title)

	var close_button := Button.new()
	close_button.text = "X"
	close_button.tooltip_text = "Close the optimizer panel"
	close_button.custom_minimum_size = Vector2(28, 0)
	close_button.pressed.connect(close_panel)
	title_row.add_child(close_button)

	column.add_child(_small_label(
		"Assigns cohorts to exits. The simulation still runs A*, the Social "
		+ "Force Model and the exit admission policy."
	))

	_enabled = CheckButton.new()
	_enabled.text = "Enable optimizer"
	_enabled.tooltip_text = "Optimized runs apply global exit assignments; disabled runs keep the local exit choice."
	_enabled.toggled.connect(_on_enabled_toggled)
	column.add_child(_enabled)

	column.add_child(_field_label("Method"))

	_algorithm = OptionButton.new()
	_algorithm.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	for index: int in range(ALGORITHMS.size()):
		_algorithm.add_item(
			OptimizerManager.algorithm_label(ALGORITHMS[index]), index
		)

	_algorithm.item_selected.connect(_on_algorithm_selected)
	column.add_child(_algorithm)

	_algorithm_description = _small_label("")
	column.add_child(_algorithm_description)

	column.add_child(_field_label("Objective"))

	_mode = OptionButton.new()
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	for index: int in range(MODE_LABELS.size()):
		_mode.add_item(MODE_LABELS[index], index)

	_mode.item_selected.connect(_on_mode_selected)
	column.add_child(_mode)

	_mode_description = _small_label("")
	column.add_child(_mode_description)

	var cohort_grid := GridContainer.new()
	cohort_grid.columns = 2
	cohort_grid.add_theme_constant_override("h_separation", 6)
	cohort_grid.add_theme_constant_override("v_separation", 2)
	column.add_child(cohort_grid)

	cohort_grid.add_child(_field_label("Cohort size"))

	_cohort = SpinBox.new()
	_cohort.min_value = 1.0
	_cohort.max_value = 20.0
	_cohort.step = 0.5
	_cohort.value = 4.0
	_cohort.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cohort.value_changed.connect(_on_cohort_changed)
	cohort_grid.add_child(_cohort)

	cohort_grid.add_child(_field_label("Max cohorts"))

	_max_cohorts = SpinBox.new()
	_max_cohorts.min_value = 1
	_max_cohorts.max_value = 400
	_max_cohorts.step = 1
	_max_cohorts.value = 60
	_max_cohorts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_max_cohorts.value_changed.connect(_on_max_cohorts_changed)
	cohort_grid.add_child(_max_cohorts)

	_aco_params = GridContainer.new()
	_aco_params.columns = 2
	_aco_params.add_theme_constant_override("h_separation", 6)
	_aco_params.add_theme_constant_override("v_separation", 2)
	column.add_child(_aco_params)

	_aco_params.add_child(_field_label("Ants"))

	_ants = SpinBox.new()
	_ants.min_value = 2
	_ants.max_value = 128
	_ants.step = 1
	_ants.value = 16
	_ants.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ants.value_changed.connect(_on_ants_changed)
	_aco_params.add_child(_ants)

	_aco_params.add_child(_field_label("Iterations"))

	_iterations = SpinBox.new()
	_iterations.min_value = 1
	_iterations.max_value = 500
	_iterations.step = 1
	_iterations.value = 40
	_iterations.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_iterations.value_changed.connect(_on_iterations_changed)
	_aco_params.add_child(_iterations)

	_pso_params = GridContainer.new()
	_pso_params.columns = 2
	_pso_params.add_theme_constant_override("h_separation", 6)
	_pso_params.add_theme_constant_override("v_separation", 2)
	column.add_child(_pso_params)

	_pso_params.add_child(_field_label("Swarm"))

	_swarm = SpinBox.new()
	_swarm.min_value = 2
	_swarm.max_value = 128
	_swarm.step = 1
	_swarm.value = 24
	_swarm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_swarm.value_changed.connect(_on_swarm_changed)
	_pso_params.add_child(_swarm)

	_pso_params.add_child(_field_label("Iterations"))

	_pso_iterations = SpinBox.new()
	_pso_iterations.min_value = 1
	_pso_iterations.max_value = 500
	_pso_iterations.step = 1
	_pso_iterations.value = 60
	_pso_iterations.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pso_iterations.value_changed.connect(_on_pso_iterations_changed)
	_pso_params.add_child(_pso_iterations)

	column.add_child(_field_label("Time budget ms (ACO/PSO)"))

	_budget = SpinBox.new()
	_budget.min_value = 50
	_budget.max_value = 5000
	_budget.step = 10
	_budget.value = 250
	_budget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_budget.value_changed.connect(_on_budget_changed)
	column.add_child(_budget)

	_auto = CheckButton.new()
	_auto.text = "Solve at run start"
	_auto.tooltip_text = "Run one solve after Start; with Keep re-solving on, continue during the run."
	_auto.toggled.connect(_on_auto_toggled)
	column.add_child(_auto)

	var first_row := HBoxContainer.new()
	first_row.add_theme_constant_override("separation", 6)
	column.add_child(first_row)

	var first_label := Label.new()
	first_label.text = "First solve (s)"
	first_label.add_theme_color_override("font_color", MUTED)
	first_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	first_row.add_child(first_label)

	_first_solve = SpinBox.new()
	_first_solve.min_value = 0.0
	_first_solve.max_value = 120.0
	_first_solve.step = 0.5
	_first_solve.value = 1.0
	_first_solve.custom_minimum_size = Vector2(80, 0)
	_first_solve.value_changed.connect(_on_first_solve_changed)
	first_row.add_child(_first_solve)

	_wait_for_spawn = CheckButton.new()
	_wait_for_spawn.text = "Wait for spawn quota"
	_wait_for_spawn.tooltip_text = (
		"Delay the first solve until the configured spawn quota is met. Use this "
		+ "for spawner-driven 600-agent scenarios instead of a fixed delay."
	)
	_wait_for_spawn.toggled.connect(_on_wait_for_spawn_toggled)
	column.add_child(_wait_for_spawn)

	_hysteresis = CheckButton.new()
	_hysteresis.text = "Hysteresis (keep near-tied exits)"
	_hysteresis.tooltip_text = (
		"Do not replace an existing exit assignment unless the new plan improves "
		+ "estimated cost by the threshold below. Prevents oscillation across re-solves."
	)
	_hysteresis.toggled.connect(_on_hysteresis_toggled)
	column.add_child(_hysteresis)

	var hysteresis_row := HBoxContainer.new()
	hysteresis_row.add_theme_constant_override("separation", 6)
	column.add_child(hysteresis_row)

	var hysteresis_label := Label.new()
	hysteresis_label.text = "Required improvement"
	hysteresis_label.add_theme_color_override("font_color", MUTED)
	hysteresis_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hysteresis_row.add_child(hysteresis_label)

	_hysteresis_ratio = SpinBox.new()
	_hysteresis_ratio.min_value = 0.0
	_hysteresis_ratio.max_value = 0.9
	_hysteresis_ratio.step = 0.01
	_hysteresis_ratio.value = 0.10
	_hysteresis_ratio.custom_minimum_size = Vector2(80, 0)
	_hysteresis_ratio.value_changed.connect(_on_hysteresis_ratio_changed)
	hysteresis_row.add_child(_hysteresis_ratio)

	_resolve = CheckButton.new()
	_resolve.text = "Keep re-solving"
	_resolve.tooltip_text = "When Solve at run start is on, re-solve every interval so queues and late arrivals change the assignment."
	_resolve.toggled.connect(_on_resolve_toggled)
	column.add_child(_resolve)

	var interval_row := HBoxContainer.new()
	interval_row.add_theme_constant_override("separation", 6)
	column.add_child(interval_row)

	var interval_label := Label.new()
	interval_label.text = "Every (s)"
	interval_label.add_theme_color_override("font_color", MUTED)
	interval_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	interval_row.add_child(interval_label)

	_interval = SpinBox.new()
	_interval.min_value = 5.0
	_interval.max_value = 120.0
	_interval.step = 1.0
	_interval.value = 15.0
	_interval.custom_minimum_size = Vector2(80, 0)
	_interval.value_changed.connect(_on_interval_changed)
	interval_row.add_child(_interval)

	_overlay = CheckButton.new()
	_overlay.text = "Show assignment overlay"
	_overlay.tooltip_text = "Colour agents by exit, draw cohort->exit lines and show live exit load."
	_overlay.toggled.connect(_on_overlay_toggled)
	column.add_child(_overlay)

	_run = Button.new()
	_run.text = "Run once"
	_run.tooltip_text = "Capture the current agents and exits and apply new assignments. Agents in a queue or near their exit are kept."
	_run.pressed.connect(_on_run_pressed)
	column.add_child(_run)

	column.add_child(_field_label("Saved plans"))
	column.add_child(_small_label(
		"A plan is a saved assignment plus routes, not the live run. Save captures "
		+ "the last solve; use Show to draw it, Apply to re-use it, or Paint to edit its corridor."
	))

	var plan_name_row := HBoxContainer.new()
	plan_name_row.add_theme_constant_override("separation", 6)
	column.add_child(plan_name_row)

	_plan_name = LineEdit.new()
	_plan_name.placeholder_text = "Plan name"
	_plan_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plan_name_row.add_child(_plan_name)

	var save_plan_button := Button.new()
	save_plan_button.text = "Save plan"
	save_plan_button.tooltip_text = "Save the current assignment and routes to this save's plan library."
	save_plan_button.pressed.connect(_on_save_plan_pressed)
	plan_name_row.add_child(save_plan_button)

	var save_painted := Button.new()
	save_painted.text = "Save painted route as plan"
	save_painted.tooltip_text = "Bundle the Route Paint corridor into a reusable plan."
	save_painted.pressed.connect(_on_save_painted_plan_pressed)
	column.add_child(save_painted)

	_plan_select = OptionButton.new()
	_plan_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plan_select.item_selected.connect(_on_plan_selected)
	column.add_child(_plan_select)

	_plan_detail = Label.new()
	_plan_detail.text = "No plan selected."
	_plan_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plan_detail.add_theme_color_override("font_color", MUTED)
	_plan_detail.add_theme_font_size_override("font_size", 10)
	column.add_child(_plan_detail)

	var plan_row := GridContainer.new()
	plan_row.columns = 3
	plan_row.add_theme_constant_override("h_separation", 4)
	plan_row.add_theme_constant_override("v_separation", 4)
	column.add_child(plan_row)

	_plan_apply_button = Button.new()
	_plan_apply_button.text = "Apply"
	_plan_apply_button.tooltip_text = "Apply the selected plan to the live crowd now."
	_plan_apply_button.pressed.connect(_on_apply_plan_pressed)
	_plan_apply_button.disabled = true
	plan_row.add_child(_plan_apply_button)

	_plan_arm_button = Button.new()
	_plan_arm_button.text = "Arm at Start"
	_plan_arm_button.tooltip_text = "Apply the selected plan automatically shortly after the next Start."
	_plan_arm_button.pressed.connect(_on_arm_plan_pressed)
	_plan_arm_button.disabled = true
	plan_row.add_child(_plan_arm_button)

	_plan_show_button = Button.new()
	_plan_show_button.text = "Show"
	_plan_show_button.tooltip_text = "Draw the selected plan in the live world (cohort -> exit lines and recorded routes)."
	_plan_show_button.pressed.connect(_on_show_plan_pressed)
	_plan_show_button.disabled = true
	plan_row.add_child(_plan_show_button)

	_plan_paint_button = Button.new()
	_plan_paint_button.text = "Paint"
	_plan_paint_button.tooltip_text = "Load the selected plan's routes into the Route Paint tool for editing."
	_plan_paint_button.pressed.connect(_on_paint_plan_pressed)
	_plan_paint_button.disabled = true
	plan_row.add_child(_plan_paint_button)

	var refresh_plan_button := Button.new()
	refresh_plan_button.text = "Refresh"
	refresh_plan_button.tooltip_text = "Reload the plan list for the active save."
	refresh_plan_button.pressed.connect(_refresh_plan_list)
	plan_row.add_child(refresh_plan_button)

	_plan_delete_button = Button.new()
	_plan_delete_button.text = "Delete"
	_plan_delete_button.pressed.connect(_on_delete_plan_pressed)
	_plan_delete_button.disabled = true
	plan_row.add_child(_plan_delete_button)

	_plan_apply_on_start = CheckButton.new()
	_plan_apply_on_start.text = "Apply selected plan at next Start"
	_plan_apply_on_start.toggled.connect(_on_plan_apply_on_start_toggled)
	column.add_child(_plan_apply_on_start)

	var open_plans := Button.new()
	open_plans.text = "Open plan folder"
	open_plans.pressed.connect(_on_open_plan_folder_pressed)
	column.add_child(open_plans)

	_plan_status = Label.new()
	_plan_status.text = "No plan selected."
	_plan_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plan_status.add_theme_color_override("font_color", MUTED)
	_plan_status.add_theme_font_size_override("font_size", 11)
	column.add_child(_plan_status)

	_status = Label.new()
	_status.text = "Optimizer off"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", GOLD)
	_status.add_theme_font_size_override("font_size", 12)
	column.add_child(_status)

	_result = Label.new()
	_result.text = "No solve yet."
	_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result.add_theme_color_override("font_color", MUTED)
	_result.add_theme_font_size_override("font_size", 11)
	column.add_child(_result)


func _create_bridge() -> void:
	bridge = OptimizerBridge.new()
	bridge.name = "OptimizerBridge"
	add_child(bridge)
	bridge.state_changed.connect(_on_bridge_state)
	bridge.result_ready.connect(_on_bridge_result)
	_sync_controls()


# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------

func _sync_controls() -> void:
	if bridge == null:
		return

	_enabled.set_pressed_no_signal(bridge.enabled)

	var algorithm_index: int = ALGORITHMS.find(bridge.algorithm)
	_algorithm.select(maxi(algorithm_index, 0))

	var mode_index: int = OptimizationRequest.MODES.find(bridge.mode)
	_mode.select(maxi(mode_index, 0))

	_cohort.set_value_no_signal(bridge.cohort_size)
	_max_cohorts.set_value_no_signal(bridge.max_cohorts)
	_auto.set_pressed_no_signal(bridge.auto_solve)
	_first_solve.set_value_no_signal(bridge.first_solve_delay)
	_wait_for_spawn.set_pressed_no_signal(bridge.solve_on_spawn_complete)
	_hysteresis.set_pressed_no_signal(bridge.hysteresis_enabled)
	_hysteresis_ratio.set_value_no_signal(bridge.hysteresis_ratio)
	_resolve.set_pressed_no_signal(bridge.re_solve_enabled)
	_interval.set_value_no_signal(bridge.re_solve_interval)
	_overlay.set_pressed_no_signal(bridge.overlay_enabled)
	_ants.set_value_no_signal(int(bridge.parameters.get("aco_ants", 16)))
	_iterations.set_value_no_signal(
		int(bridge.parameters.get("aco_iterations", 40))
	)
	_swarm.set_value_no_signal(int(bridge.parameters.get("pso_swarm", 24)))
	_pso_iterations.set_value_no_signal(
		int(bridge.parameters.get("pso_iterations", 60))
	)
	_budget.set_value_no_signal(
		float(bridge.parameters.get("time_budget_ms", 250.0))
	)
	_update_descriptions()
	_update_search_visibility()
	_refresh_plan_list()


func _update_descriptions() -> void:
	var algorithm: String = ALGORITHMS[maxi(_algorithm.selected, 0)]
	var objective: String = OptimizationRequest.MODES[maxi(_mode.selected, 0)]
	_algorithm_description.text = String(
		ALGORITHM_DESCRIPTIONS.get(algorithm, "")
	)
	_mode_description.text = String(MODE_DESCRIPTIONS.get(objective, ""))


func _update_search_visibility() -> void:
	var algorithm: String = ALGORITHMS[maxi(_algorithm.selected, 0)]
	_aco_params.visible = algorithm == OptimizationRequest.ALGORITHM_ACO
	_pso_params.visible = algorithm == OptimizationRequest.ALGORITHM_PSO


func _on_enabled_toggled(pressed: bool) -> void:
	if bridge != null:
		bridge.set_enabled(pressed)


func _on_algorithm_selected(index: int) -> void:
	if bridge == null or index < 0 or index >= ALGORITHMS.size():
		return

	bridge.set_algorithm(ALGORITHMS[index])
	_update_descriptions()
	_update_search_visibility()


func _on_mode_selected(index: int) -> void:
	if (
		bridge == null
		or index < 0
		or index >= OptimizationRequest.MODES.size()
	):
		return

	bridge.set_mode(OptimizationRequest.MODES[index])
	_update_descriptions()


func _on_cohort_changed(value: float) -> void:
	if bridge != null:
		bridge.set_cohort_size(value)


func _on_max_cohorts_changed(value: float) -> void:
	if bridge != null:
		bridge.set_max_cohorts(int(value))


func _on_auto_toggled(pressed: bool) -> void:
	if bridge != null:
		bridge.set_auto_solve(pressed)


func _on_first_solve_changed(value: float) -> void:
	if bridge != null:
		bridge.set_first_solve_delay(value)


func _on_wait_for_spawn_toggled(pressed: bool) -> void:
	if bridge != null:
		bridge.set_solve_on_spawn_complete(pressed)


func _on_hysteresis_toggled(pressed: bool) -> void:
	if bridge != null:
		bridge.set_hysteresis_enabled(pressed)


func _on_hysteresis_ratio_changed(value: float) -> void:
	if bridge != null:
		bridge.set_hysteresis_ratio(value)


# ---------------------------------------------------------------------------
# Saved plans
# ---------------------------------------------------------------------------

func _refresh_plan_list() -> void:
	if _plan_select == null:
		return

	var previous: String = ""

	if _plan_select.selected >= 0 and _plan_select.selected < _plan_ids.size():
		previous = _plan_ids[_plan_select.selected]

	_plan_ids.clear()
	_plan_select.clear()
	var plans := PlanStore.list_plans()

	for plan: Dictionary in plans:
		_plan_ids.append(String(plan.get("id", "")))
		_plan_select.add_item("%s  (%d agents, %d painted, seed %d)" % [
			String(plan.get("name", plan.get("id", ""))),
			int(plan.get("assignments", 0)),
			int(plan.get("authored_cells", 0)),
			int(plan.get("seed", 0)),
		])

	if not _plan_ids.is_empty():
		var index := maxi(_plan_ids.find(previous), 0)
		_plan_select.select(index)
		_update_plan_buttons()
		_update_plan_detail()
		_set_plan_status("Plan library: %d plan(s). Select one, then Apply / Show / Paint." % _plan_ids.size(), true)
	else:
		_plan_detail.text = "No plan files."
		_update_plan_buttons()
		_set_plan_status("No saved plans for this save. Run the optimizer, then press Save plan.", false)


func _selected_plan_id() -> String:
	if _plan_select == null or _plan_select.selected < 0:
		return ""

	if _plan_select.selected >= _plan_ids.size():
		return ""

	return _plan_ids[_plan_select.selected]


func _on_plan_selected(_index: int) -> void:
	_update_plan_buttons()
	_update_plan_detail()
	_set_plan_status("Selected plan loaded. Apply now, arm at Start, Show, Paint, or Delete.", true)


func _update_plan_buttons() -> void:
	var has_plan := not _selected_plan_id().is_empty()

	if _plan_apply_button != null:
		_plan_apply_button.disabled = not has_plan
	if _plan_arm_button != null:
		_plan_arm_button.disabled = not has_plan
	if _plan_show_button != null:
		_plan_show_button.disabled = not has_plan
	if _plan_paint_button != null:
		_plan_paint_button.disabled = not has_plan
	if _plan_delete_button != null:
		_plan_delete_button.disabled = not has_plan


func _update_plan_detail() -> void:
	if _plan_detail == null:
		return

	var plan_id := _selected_plan_id()

	if plan_id.is_empty():
		_plan_detail.text = "No plan selected."
		return

	var plan := PlanStore.load_plan(plan_id)

	if plan == null:
		_plan_detail.text = "Could not read %s." % plan_id
		return

	_plan_detail.text = "%d agents | %d cohorts | %d routes | %d painted cells | %s / %s | seed %d\n%s" % [
		plan.assignment_count(),
		plan.cohort_count(),
		plan.routes_with_polylines(),
		plan.authored_cell_count(),
		plan.algorithm if not plan.algorithm.is_empty() else "baseline",
		plan.mode if not plan.mode.is_empty() else "-",
		plan.rng_seed,
		PlanStore.plan_path(plan_id),
	]


func _set_plan_status(text: String, ok: bool) -> void:
	if _plan_status == null:
		return

	_plan_status.text = text
	_plan_status.add_theme_color_override(
		"font_color",
		Color(0.55, 1.0, 0.62) if ok else Color(1.0, 0.55, 0.45)
	)

	if text.begins_with("Plan library") or text.begins_with("No saved plans"):
		return

	_show_hud_toast(text, ok)


func _show_hud_toast(text: String, ok: bool) -> void:
	var tree := get_tree()

	if tree == null:
		return

	var player := tree.get_first_node_in_group("player")

	if player == null:
		return

	var hud := player.get_node_or_null("HUD/HUD")

	if hud != null and hud.has_method("show_build_label"):
		hud.call(
			"show_build_label",
			("%s %s" % ["OK:", text]) if ok else ("! " + text),
			1.2,
			0.5
		)


func _on_save_plan_pressed() -> void:
	if bridge == null:
		_set_plan_status("Cannot save: the optimizer bridge is not ready.", false)
		return

	var plan_name := _plan_name.text.strip_edges()

	if plan_name.is_empty():
		plan_name = "Plan %s" % Time.get_datetime_string_from_system(false, true).replace(":", "-")

	var plan := bridge.capture_plan(plan_name)

	if plan == null:
		_set_plan_status("Nothing to save: start a run, run the optimizer, or apply an assignment first.", false)
		return

	var plan_id := PlanStore.save_plan(plan, plan_name)

	if plan_id.is_empty():
		_set_plan_status("Could not write the plan file. Check the save library path.", false)
		return

	_plan_name.text = plan.name
	_refresh_plan_list()
	var index := _plan_ids.find(plan_id)

	if index >= 0:
		_plan_select.select(index)

	_update_plan_buttons()
	_update_plan_detail()
	_set_plan_status(
		"Saved '%s' (%d agents, %d routes) to %s"
		% [plan_id, plan.assignment_count(), plan.routes_with_polylines(), PlanStore.plan_path(plan_id)],
		true
	)


func _on_save_painted_plan_pressed() -> void:
	var plan_name := _plan_name.text.strip_edges()

	if plan_name.is_empty():
		plan_name = "Painted route %s" % Time.get_datetime_string_from_system(false, true).replace(":", "-")

	var plan := RoutePainter.capture_authored_plan(plan_name)

	if plan == null or plan.authored_cell_count() == 0:
		_set_plan_status("Nothing painted. Hold the Route Paint tool and paint a corridor first.", false)
		return

	var plan_id := PlanStore.save_plan(plan, plan_name)

	if plan_id.is_empty():
		_set_plan_status("Could not write the painted plan file.", false)
		return

	_plan_name.text = plan.name
	_refresh_plan_list()
	var index := _plan_ids.find(plan_id)

	if index >= 0:
		_plan_select.select(index)

	_update_plan_buttons()
	_update_plan_detail()
	_set_plan_status(
		"Saved painted plan '%s' (%d cells) to %s"
		% [plan_id, plan.authored_cell_count(), PlanStore.plan_path(plan_id)],
		true
	)


func _on_apply_plan_pressed() -> void:
	var plan_id := _selected_plan_id()

	if bridge == null or plan_id.is_empty():
		_set_plan_status("Select a saved plan first.", false)
		return

	var plan := PlanStore.load_plan(plan_id)

	if plan == null:
		_set_plan_status("The plan file could not be read.", false)
		return

	var result: Dictionary = bridge.apply_plan(plan)

	if bool(result.get("ok", false)):
		_set_plan_status(
			"Applied '%s': %d agents, %d painted cells, %d skipped, %d unmatched."
			% [
				plan_id,
				int(result.get("applied", 0)),
				int(result.get("authored_cells", 0)),
				int(result.get("skipped", 0)),
				int(result.get("missing", 0)),
			],
			true
		)
	else:
		_set_plan_status("Apply failed: %s" % String(result.get("error", "unknown")), false)


func _on_arm_plan_pressed() -> void:
	var plan_id := _selected_plan_id()

	if bridge == null or plan_id.is_empty():
		_set_plan_status("Select a saved plan first.", false)
		return

	var plan := PlanStore.load_plan(plan_id)

	if plan == null:
		_set_plan_status("The plan file could not be read.", false)
		return

	bridge.set_startup_plan(plan)
	_plan_apply_on_start.set_pressed_no_signal(true)
	_set_plan_status("Armed '%s' for the next Start." % plan_id, true)


func _on_show_plan_pressed() -> void:
	var plan_id := _selected_plan_id()

	if plan_id.is_empty():
		_set_plan_status("Select a saved plan first.", false)
		return

	var plan := PlanStore.load_plan(plan_id)

	if plan == null:
		_set_plan_status("The plan file could not be read.", false)
		return

	LivePlanOverlay.show_plan(plan)
	_set_plan_status("Showing '%s' in the world. Use plan_render off to hide." % plan_id, true)


func _on_paint_plan_pressed() -> void:
	var plan_id := _selected_plan_id()

	if plan_id.is_empty():
		_set_plan_status("Select a saved plan first.", false)
		return

	var plan := PlanStore.load_plan(plan_id)

	if plan == null:
		_set_plan_status("The plan file could not be read.", false)
		return

	var count := RoutePainter.set_from_plan(plan)
	_set_plan_status(
		"Loaded %d route cells from '%s'. Equip the Route Paint tool to edit them." % [count, plan_id],
		count > 0
	)


func _on_delete_plan_pressed() -> void:
	var plan_id := _selected_plan_id()

	if plan_id.is_empty():
		return

	if PlanStore.delete_plan(plan_id):
		_refresh_plan_list()
		_set_plan_status("Deleted plan '%s'." % plan_id, true)
	else:
		_set_plan_status("Could not delete '%s'." % plan_id, false)


func _on_open_plan_folder_pressed() -> void:
	var root := PlanStore.plans_root()
	DirAccess.make_dir_recursive_absolute(root)
	OS.shell_open(ProjectSettings.globalize_path(root))
	_plan_status.text = "Plan folder: %s" % ProjectSettings.globalize_path(root)


func _on_plan_apply_on_start_toggled(pressed: bool) -> void:
	if bridge == null:
		return

	if not pressed:
		bridge.clear_startup_plan()
		return

	var plan_id := _selected_plan_id()

	if plan_id.is_empty():
		_plan_apply_on_start.set_pressed_no_signal(false)
		_set_plan_status("Select a saved plan first.", false)
		return

	var plan := PlanStore.load_plan(plan_id)

	if plan == null:
		_plan_apply_on_start.set_pressed_no_signal(false)
		_set_plan_status("The plan file could not be read.", false)
		return

	bridge.set_startup_plan(plan)
	_set_plan_status("Armed '%s' for the next Start." % plan_id, true)


func _on_resolve_toggled(pressed: bool) -> void:
	if bridge != null:
		bridge.set_re_solve_enabled(pressed)


func _on_interval_changed(value: float) -> void:
	if bridge != null:
		bridge.set_re_solve_interval(value)


func _on_overlay_toggled(pressed: bool) -> void:
	if bridge != null:
		bridge.set_overlay_enabled(pressed)


func _on_ants_changed(value: float) -> void:
	if bridge != null:
		bridge.parameters["aco_ants"] = int(value)


func _on_iterations_changed(value: float) -> void:
	if bridge != null:
		bridge.parameters["aco_iterations"] = int(value)


func _on_swarm_changed(value: float) -> void:
	if bridge != null:
		bridge.parameters["pso_swarm"] = int(value)


func _on_pso_iterations_changed(value: float) -> void:
	if bridge != null:
		bridge.parameters["pso_iterations"] = int(value)


func _on_budget_changed(value: float) -> void:
	if bridge != null:
		bridge.parameters["time_budget_ms"] = float(value)


func _on_run_pressed() -> void:
	if bridge == null:
		return

	if not bridge.enabled:
		bridge.set_enabled(true)
		_sync_controls()

	bridge.request_solve()


func _on_bridge_state(text: String) -> void:
	_status.text = text
	state_changed.emit(text)


func _on_bridge_result(
	result: OptimizationResult,
	applied: int,
	skipped: int
) -> void:
	if result == null:
		return

	var counts: Dictionary = result.exit_counts
	var keys: Array = counts.keys()
	keys.sort()
	var parts: Array = []

	for key: Variant in keys:
		parts.append("%s %d" % [String(key), int(counts[key])])

	var terms: Dictionary = result.terms
	var normalised: Dictionary = result.detail.get("normalised_terms", {})
	var solver: Dictionary = result.detail.get("solver", {})
	var apply: Dictionary = result.detail.get("apply", {})
	var unchanged: int = int(apply.get("unchanged", 0))
	var budget_note: String = ""

	if bool(solver.get("timed_out", false)):
		budget_note = " · stopped at budget"
	elif bool(solver.get("exact", false)):
		budget_note = " · exact"

	_result.text = (
		"%s\n"
		+ "predicted T %.1f s · avg %.1f s\n"
		+ "queue %.0f s (%.1f s/agent) · congestion %.0f s (%.1f s/agent)\n"
		+ "changed %d · unchanged %d · skipped %d · %d cohorts · %.0f ms%s\n"
		+ "exits: %s"
	) % [
		OptimizerManager.algorithm_label(result.algorithm),
		result.estimated_completion_time,
		result.estimated_average_time,
		float(terms.get("queue", 0.0)),
		float(normalised.get("queue", 0.0)),
		float(terms.get("congestion", 0.0)),
		float(normalised.get("congestion", 0.0)),
		applied,
		unchanged,
		skipped,
		result.cohorts.size(),
		result.computation_time_ms,
		budget_note,
		"none" if parts.is_empty() else ", ".join(parts),
	]


func _on_parent_visibility() -> void:
	var parent := get_parent()

	if parent is CanvasItem and not (parent as CanvasItem).visible:
		close_panel()


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

func _field_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", TEXT)
	label.add_theme_font_size_override("font_size", 14)
	return label


func _small_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", MUTED)
	label.add_theme_font_size_override("font_size", 11)
	return label
