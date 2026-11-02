extends VBoxContainer

## Simulation controls: start/reset the run, tune the run limits, switch every
## member between evacuation and wandering, and populate the level randomly.

@onready var start_button: Button = $Actions/Start
@onready var reset_button: Button = $Actions/Reset
@onready var evac_mode: CheckButton = $EvacuationMode
@onready var quota_spin: SpinBox = $Limits/QuotaValue
@onready var cap_spin: SpinBox = $Limits/CapValue
@onready var member_count_spin: SpinBox = $RandomGrid/CountValue
@onready var start_evacuating_check: CheckButton = $RandomGrid/StartModeValue
@onready var pathfind_only_check: CheckButton = $RandomGrid/PathOnlyValue
@onready var populate_button: Button = $Populate
@onready var status_label: Label = $Status
@onready var populator = $RandomPopulator

var _status_accum: float = 0.0


func _ready() -> void:
	start_button.pressed.connect(_on_start_pressed)
	reset_button.pressed.connect(_on_reset_pressed)
	evac_mode.toggled.connect(_on_evac_mode_toggled)
	quota_spin.value_changed.connect(_on_quota_changed)
	cap_spin.value_changed.connect(_on_cap_changed)
	member_count_spin.value_changed.connect(_on_member_count_changed)
	start_evacuating_check.toggled.connect(_on_start_evacuating_toggled)
	pathfind_only_check.toggled.connect(_on_pathfind_only_toggled)
	populate_button.pressed.connect(_on_populate_pressed)

	GlobalData.spawning_reset.connect(_on_run_state_changed)
	GlobalData.spawning_started.connect(_on_run_state_changed)
	GlobalData.spawning_stopped.connect(_on_run_state_changed)
	GlobalData.npc_spawned.connect(_on_npc_count_changed)
	GlobalData.npc_evacuated.connect(_on_npc_count_changed)

	_sync_from_state()


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
	evac_mode.set_pressed_no_signal(GlobalData.evacuation_mode)

	if populator:
		member_count_spin.set_value_no_signal(populator.member_count)
		start_evacuating_check.set_pressed_no_signal(populator.start_evacuating)
		pathfind_only_check.set_pressed_no_signal(populator.only_pathfindable_blocks)

	_update_status()


func _apply_limits() -> void:
	GlobalData.global_spawn_quota = int(quota_spin.value)
	GlobalData.global_unit_cap = maxi(1, int(cap_spin.value))


func _on_start_pressed() -> void:
	_apply_limits()
	GlobalData.start_spawning()
	_update_status()


func _on_reset_pressed() -> void:
	GlobalData.reset_spawning()
	_update_status()


func _on_evac_mode_toggled(enabled: bool) -> void:
	GlobalData.set_evacuation_mode(enabled)
	_update_status()


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
	_update_status()


func _on_npc_count_changed(_total: int) -> void:
	_update_status()


func _update_status(keep_message: bool = false) -> void:
	if keep_message:
		return

	var quota: int = GlobalData.get_total_max_spawns()
	var quota_text: String = "∞" if quota < 0 else str(quota)
	var alive: int = get_tree().get_nodes_in_group("npc").size()
	var state: String = "spawning" if GlobalData.is_spawning_enabled else "stopped"

	status_label.text = (
		"Spawned %d / %s | Alive %d / %d | %s"
		% [GlobalData.npcs_spawned, quota_text, alive, GlobalData.global_unit_cap, state]
	)
