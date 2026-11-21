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
	_auto.tooltip_text = "Run one solve 1 s after Start. Late spawns are adopted by the nearest cohort of that result."
	_auto.toggled.connect(_on_auto_toggled)
	column.add_child(_auto)

	_run = Button.new()
	_run.text = "Run once"
	_run.tooltip_text = "Capture the current agents and exits and apply new assignments. Agents in a queue or near their exit are kept."
	_run.pressed.connect(_on_run_pressed)
	column.add_child(_run)

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
	var budget_note: String = ""

	if bool(solver.get("timed_out", false)):
		budget_note = " · stopped at budget"
	elif bool(solver.get("exact", false)):
		budget_note = " · exact"

	_result.text = (
		"%s\n"
		+ "predicted T %.1f s · avg %.1f s\n"
		+ "queue %.0f s (%.1f s/agent) · congestion %.0f s (%.1f s/agent)\n"
		+ "applied %d · skipped %d · %d cohorts · %.0f ms%s\n"
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
