extends VBoxContainer

## Simulation controls: start/reset the run, tune the run limits, switch every
## member between evacuation and wandering, and populate the level randomly.
##
## The optimizer has its own side panel (OptimizerPanel) to the right of the
## inventory; this panel only exposes the button that opens it.

@onready var start_button: Button = $Actions/Start
@onready var reset_button: Button = $Actions/Reset
@onready var pause_spawning: CheckButton = $Actions/PauseSpawning
@onready var evac_mode: CheckButton = $EvacuationMode
@onready var record_run: CheckButton = $RecordRun
@onready var record_now: Button = $RecordNow
@onready var quota_spin: SpinBox = $Limits/QuotaValue
@onready var cap_spin: SpinBox = $Limits/CapValue
@onready var seed_spin: SpinBox = $Limits/SeedRow/SeedValue
@onready var randomize_seed_button: Button = $Limits/SeedRow/Randomize
@onready var member_count_spin: SpinBox = $RandomGrid/CountValue
@onready var start_evacuating_check: CheckButton = $RandomGrid/StartModeValue
@onready var pathfind_only_check: CheckButton = $RandomGrid/PathOnlyValue
@onready var populate_button: Button = $Populate
@onready var status_label: Label = $Status
@onready var populator = $RandomPopulator

var _status_accum: float = 0.0
var _optimizer_button: Button = null


func _ready() -> void:
	start_button.pressed.connect(_on_start_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	pause_spawning.toggled.connect(_on_pause_spawning_toggled)
	evac_mode.toggled.connect(_on_evac_mode_toggled)
	record_run.toggled.connect(_on_record_run_toggled)
	record_now.pressed.connect(_on_record_now_pressed)
	SimRecorder.recording_state_changed.connect(_on_recording_state_changed)
	RuntimeExports.runtime_exports_applied.connect(_on_run_state_changed)
	quota_spin.value_changed.connect(_on_quota_changed)
	cap_spin.value_changed.connect(_on_cap_changed)
	randomize_seed_button.pressed.connect(_on_randomize_seed_pressed)
	member_count_spin.value_changed.connect(_on_member_count_changed)
	start_evacuating_check.toggled.connect(_on_start_evacuating_toggled)
	pathfind_only_check.toggled.connect(_on_pathfind_only_toggled)
	populate_button.pressed.connect(_on_populate_pressed)

	GlobalData.spawning_reset.connect(_on_run_state_changed)
	GlobalData.spawning_started.connect(_on_run_state_changed)
	GlobalData.spawning_stopped.connect(_on_run_state_changed)
	GlobalData.spawning_paused.connect(_on_run_state_changed)
	GlobalData.spawning_resumed.connect(_on_run_state_changed)
	GlobalData.npc_spawned.connect(_on_npc_count_changed)
	GlobalData.npc_evacuated.connect(_on_npc_count_changed)

	_ensure_optimizer_button()
	_sync_from_state()


func _exit_tree() -> void:
	# These autoloads outlive the panel. Disconnect while the node is still
	# valid so a finalize/scene-change update cannot run after detaching, when
	# `get_tree()` is already null.
	if SimRecorder.recording_state_changed.is_connected(_on_recording_state_changed):
		SimRecorder.recording_state_changed.disconnect(_on_recording_state_changed)

	if RuntimeExports.runtime_exports_applied.is_connected(_on_run_state_changed):
		RuntimeExports.runtime_exports_applied.disconnect(_on_run_state_changed)

	for signal_ref: Signal in [
		GlobalData.spawning_reset,
		GlobalData.spawning_started,
		GlobalData.spawning_stopped,
		GlobalData.spawning_paused,
		GlobalData.spawning_resumed,
	]:
		if signal_ref.is_connected(_on_run_state_changed):
			signal_ref.disconnect(_on_run_state_changed)

	if GlobalData.npc_spawned.is_connected(_on_npc_count_changed):
		GlobalData.npc_spawned.disconnect(_on_npc_count_changed)

	if GlobalData.npc_evacuated.is_connected(_on_npc_count_changed):
		GlobalData.npc_evacuated.disconnect(_on_npc_count_changed)


func _process(delta: float) -> void:
	if not visible:
		return

	_status_accum += delta
	if _status_accum >= 0.25:
		_status_accum = 0.0
		_update_status()


func _sync_from_state() -> void:
	quota_spin.set_value_no_signal(GlobalData.global_spawn_quota)
	cap_spin.set_value_no_signal(GlobalData.global_unit_cap)
	seed_spin.set_value_no_signal(GlobalData.rng_seed)
	evac_mode.set_pressed_no_signal(GlobalData.evacuation_mode)
	record_run.set_pressed_no_signal(SimRecorder.recording_enabled)
	_update_record_button()
	pause_spawning.set_pressed_no_signal(GlobalData.is_spawning_paused)
	pause_spawning.disabled = not GlobalData.is_spawning_enabled

	if populator:
		member_count_spin.set_value_no_signal(populator.member_count)
		start_evacuating_check.set_pressed_no_signal(populator.start_evacuating)
		pathfind_only_check.set_pressed_no_signal(populator.only_pathfindable_blocks)

	_update_status()


func _apply_limits() -> void:
	GlobalData.global_spawn_quota = int(quota_spin.value)
	GlobalData.global_unit_cap = maxi(1, int(cap_spin.value))
	GlobalData.rng_seed = int(seed_spin.value)


func _on_randomize_seed_pressed() -> void:
	seed_spin.value = float(randi() % 2147483647)
	status_label.text = "Seed %d - press Start or Populate to apply." % int(seed_spin.value)


func _on_start_pressed() -> void:
	_apply_limits()
	GlobalData.start_spawning()
	_update_status()


func _on_reset_pressed() -> void:
	GlobalData.reset_spawning()
	_update_status()


func _on_pause_spawning_toggled(paused: bool) -> void:
	GlobalData.set_spawning_paused(paused)
	_update_status()


func _on_evac_mode_toggled(enabled: bool) -> void:
	GlobalData.set_evacuation_mode(enabled)
	_update_status()


func _on_record_run_toggled(enabled: bool) -> void:
	SimRecorder.set_recording_enabled(enabled)
	_update_record_button()
	_update_status()


func _on_record_now_pressed() -> void:
	if SimRecorder.is_recording():
		SimRecorder.stop_manual_recording()
	else:
		SimRecorder.start_manual_recording()

	_update_record_button()
	_update_status()


func _on_recording_state_changed(_recording: bool) -> void:
	_update_record_button()
	_update_status()


func _update_record_button() -> void:
	if record_now == null:
		return

	record_now.text = "Stop Recording" if SimRecorder.is_recording() else "Start Recording"


func _on_quota_changed(value: float) -> void:
	GlobalData.global_spawn_quota = int(value)
	_update_status()


func _on_cap_changed(value: float) -> void:
	GlobalData.global_unit_cap = maxi(1, int(value))
	_update_status()


func _on_member_count_changed(value: float) -> void:
	if populator:
		populator.member_count = int(value)


func _on_start_evacuating_toggled(enabled: bool) -> void:
	if populator:
		populator.start_evacuating = enabled


func _on_pathfind_only_toggled(enabled: bool) -> void:
	if populator:
		populator.only_pathfindable_blocks = enabled


func _on_populate_pressed() -> void:
	if not populator:
		return

	_apply_limits()
	if get_tree().get_nodes_in_group("npc").is_empty():
		# Populate uses the global RNG for candidate selection, so reseed it
		# with the chosen seed to make a fresh population repeatable.
		GlobalData.reset_determinism(int(seed_spin.value))
	populator.member_count = int(member_count_spin.value)
	populator.start_evacuating = start_evacuating_check.button_pressed
	populator.only_pathfindable_blocks = pathfind_only_check.button_pressed

	var result: Dictionary = populator.populate()
	var reason: String = String(result.get("reason", ""))

	if reason.is_empty():
		status_label.text = "Populated %d of %d members." % [
			int(result.get("spawned", 0)),
			int(result.get("requested", 0)),
		]
	else:
		status_label.text = "Populate failed: %s" % reason

	_update_status(true)


func _on_run_state_changed() -> void:
	_sync_from_state()


func _on_npc_count_changed(_total: int) -> void:
	_update_status()


func _update_status(keep_message: bool = false) -> void:
	if keep_message:
		return

	if not is_inside_tree():
		return

	var quota: int = GlobalData.get_total_max_spawns()
	var quota_text: String = "∞" if quota < 0 else str(quota)
	var alive: int = get_tree().get_nodes_in_group("npc").size()
	var state: String = "spawning"

	if GlobalData.is_spawning_paused:
		state = "paused"
	elif not GlobalData.is_spawning_enabled:
		state = "stopped"

	var rec: String = "recording" if SimRecorder.is_recording() else (
		"record on start" if SimRecorder.recording_enabled else "recording off"
	)

	status_label.text = (
		"Spawned %d / %s | Alive %d / %d | %s | %s"
		% [
			GlobalData.npcs_spawned,
			quota_text,
			alive,
			GlobalData.global_unit_cap,
			state,
			rec,
		]
	)


# ---------------------------------------------------------------------------
# Optimizer side panel
# ---------------------------------------------------------------------------

## Adds a compact button to the Simulation title row. The panel itself lives to
## the right of the inventory, alongside the block/placeable property tab.
func _ensure_optimizer_button() -> void:
	if _optimizer_button != null:
		return

	var title := get_node_or_null("Title") as Label

	if title == null:
		return

	var row := HBoxContainer.new()
	row.name = "TitleRow"
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	move_child(row, 0)
	remove_child(title)
	row.add_child(title)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_optimizer_button = Button.new()
	_optimizer_button.name = "OptimizerButton"
	_optimizer_button.text = "Optimizer"
	_optimizer_button.tooltip_text = (
		"Open the optimizer panel: global exit assignment, method descriptions, "
		+ "cohort settings and Run once."
	)
	_optimizer_button.pressed.connect(_on_optimizer_button_pressed)
	row.add_child(_optimizer_button)


func _on_optimizer_button_pressed() -> void:
	var panel := _get_optimizer_panel()

	if panel == null:
		return

	panel.call("toggle")


func _get_optimizer_panel() -> Node:
	var parent := get_parent()

	if parent == null:
		return null

	return parent.get_node_or_null("OptimizerPanel")
