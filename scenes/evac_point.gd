extends Area3D

## Evacuation trigger with optional finite throughput and receiving-area capacity.
##
## Defaults preserve the original behaviour: an agent that enters the trigger is
## recorded and despawned immediately. Enabling [member exit_service_rate] models
## a door/processing limit (people per second) and [member receiving_capacity]
## caps how many evacuated agents may occupy the safe area beyond the exit. The
## two constraints are independent:
##
## - service rate limits how fast agents pass through the exit;
## - receiving capacity limits how many evacuated agents accumulate past it.
##
## Retained agents are handed to EvacuationManager, which removes them from the
## `npc` group, disables their processing/collision and keeps them in a separate
## container. They therefore do not contribute to crowd density, contact force,
## navigation or the live-agent count.

signal occupancy_changed(point: Area3D)
## Emitted on queue lifecycle changes: entered, service_started, admitted,
## left, cancelled, rejected. `queue_length` is after the transition.
signal queue_event(point: Area3D, agent: Node, event: String, queue_length: int)
## Emitted when the exit is enabled/disabled at runtime. Disabled exits are
## skipped by exit choice and notify agents already assigned to them.
signal availability_changed(point: Area3D, available: bool)

enum FullBehavior {
	## Hold new arrivals at the exit until space in the receiving area frees up.
	QUEUE,
	## Send the agent back to the exit-choice step with this exit on cooldown.
	REJECT,
}

@export_group("Evacuation Tracking")
## Stable identifier used by stats, the optimizer and saved scenarios. When
## empty, the node path is used (unique, but breaks if the node is renamed).
@export var exit_id: String = ""
## Whether this exit is currently usable. Disabling it at runtime removes it
## from exit choice, releases queued/service agents, and records the change.
@export var operational: bool = true:
	set(value):
		if operational == value:
			return
		operational = value
		_notify_availability_changed()
## Record per-agent and per-exit statistics in EvacuationManager. The global
## evacuated counter is always maintained because it drives run completion.
@export var track_evacuation: bool = true
## Keep successfully evacuated agents as scene nodes instead of freeing them.
## Defaults to false, matching the original immediate-despawn behaviour.
@export var retain_evacuated: bool = false
## When retaining, leave the agent visible in the receiving area. Ignored when
## retain_evacuated is false.
@export var keep_retained_visible: bool = true
## Seconds before a retained agent is removed and its receiving slot freed.
## 0 keeps it forever. A finite value lets a QUEUE-full receiving area drain.
@export var retained_hold_time: float = 0.0

@export_group("Exit Throughput")
## Maximum people per second that can pass through this exit. 0 = unlimited
## (agents are processed on the frame they enter the trigger).
@export var exit_service_rate: float = 0.0
## Maximum waiting agents at this exit. 0 = unlimited.
@export var max_queue_length: int = 0

@export_group("Receiving Area")
## Maximum evacuated agents allowed in the safe area beyond the exit. 0 =
## unlimited. Capacity is only consumed by retained agents: with immediate
## despawn the receiving area empties at once, so this limit cannot bind.
@export var receiving_capacity: int = 0
## What to do when the receiving area is at capacity.
@export var receiving_full_behavior: FullBehavior = FullBehavior.QUEUE
## Local offset from the exit marker to the centre of the receiving area.
@export var receiving_area_offset: Vector3 = Vector3.ZERO
## Spacing (metres) between retained agents in the receiving area.
@export var receiving_slot_spacing: float = 0.9

var _occupancy: int = 0
var _peak_occupancy: int = 0
var _accepted: int = 0
var _rejected: int = 0
var _capacity_rejections: int = 0
var _capacity_waits: int = 0
var _queue_full_rejections: int = 0
var _max_queue: int = 0
var _total_wait: float = 0.0
var _wait_samples: int = 0
var _max_wait: float = 0.0
var _first_admit_time: float = -1.0
var _last_admit_time: float = -1.0

var _service_agent: Node = null
var _service_wait: float = 0.0
var _service_complete_at: float = 0.0
var _queue: Array[Dictionary] = []

var _free_slots: Array[int] = []
var _next_slot: int = 0


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

	if not GlobalData.spawning_reset.is_connected(_reset_state):
		GlobalData.spawning_reset.connect(_reset_state)


func _process(_delta: float) -> void:
	_service_tick()


func _on_body_entered(body: Node3D) -> void:
	if not operational:
		return

	if (
		body == null
		or not body.is_in_group("npc")
		or body.has_meta("evacuated")
	):
		return

	if _is_full():
		if receiving_full_behavior == FullBehavior.REJECT:
			_capacity_rejections += 1
			_reject(body, "receiving_area")
		else:
			_enqueue(body, "receiving_area")
		return

	_enqueue(body, "entry")


func _on_body_exited(body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return

	# Retained/despawned agents are moved out of the trigger deliberately.
	if body.has_meta("evacuated"):
		return

	var was_queued: bool = _remove_from_queue(body)
	var was_in_service: bool = (_service_agent == body)

	if was_in_service:
		_service_agent = null
		_service_wait = 0.0
		_service_complete_at = 0.0

	if (was_queued or was_in_service) and body.has_method("on_exit_area_exited"):
		body.on_exit_area_exited()

	if was_queued or was_in_service:
		_emit_queue(body, "left")

	_service_tick()


func _enqueue(agent: Node, reason: String) -> void:
	if max_queue_length > 0 and _queue.size() >= max_queue_length:
		_queue_full_rejections += 1
		_reject(agent, "queue_full")
		return

	_queue.append({
		"agent": agent,
		"enqueued_at": GlobalData.sim_now(),
		"reason": reason,
		"capacity_wait_counted": reason == "receiving_area",
	})
	_max_queue = maxi(_max_queue, _queue.size())

	if reason == "receiving_area":
		_capacity_waits += 1

	if agent.has_method("begin_exit_hold"):
		agent.begin_exit_hold(self)

	_emit_queue(agent, "entered")
	_service_tick()


func _service_tick() -> void:
	# A zero service rate means "process everything immediately", so this loop
	# can drain the whole queue in one frame. The guard prevents an accidental
	# endless loop if an exit is misconfigured.
	var guard: int = 0

	while guard < 512:
		guard += 1

		if _service_agent != null:
			if not _is_valid_agent(_service_agent):
				_service_agent = null
				_service_wait = 0.0
				continue

			if GlobalData.sim_now() < _service_complete_at:
				return

			_finish_service()
			continue

		while not _queue.is_empty() and not _is_valid_agent(
			_queue[0].get("agent")
		):
			_queue.pop_front()

		if _queue.is_empty():
			return

		if _is_full():
			# Count each agent once when it is actually blocked by the receiving
			# area, not just when it happened to arrive while the area was full.
			var front: Dictionary = _queue[0]
			if not bool(front.get("capacity_wait_counted", false)):
				front["capacity_wait_counted"] = true
				_capacity_waits += 1
			return

		var entry: Dictionary = _queue.pop_front()
		var next_agent: Node = entry.get("agent")

		if not _is_valid_agent(next_agent):
			continue

		_service_agent = next_agent
		_service_wait = maxf(
			0.0,
			GlobalData.sim_now() - float(entry.get("enqueued_at", 0.0))
		)
		_service_complete_at = (
			GlobalData.sim_now()
			+ (1.0 / exit_service_rate if exit_service_rate > 0.0 else 0.0)
		)
		_emit_queue(next_agent, "service_started")


func _finish_service() -> void:
	var agent: Node = _service_agent
	var wait_time: float = _service_wait
	_service_agent = null
	_service_wait = 0.0
	_service_complete_at = 0.0

	if not _is_valid_agent(agent):
		return

	# Capacity is checked again at completion in case another exit event filled
	# the area while this agent was being processed.
	if _is_full():
		if receiving_full_behavior == FullBehavior.REJECT:
			_capacity_rejections += 1
			_reject(agent, "receiving_area")
		else:
			_enqueue(agent, "receiving_area")
		return

	_accept(agent, wait_time)


func _accept(agent: Node, wait_time: float) -> void:
	_accepted += 1
	_emit_queue(agent, "admitted")
	var now: float = GlobalData.sim_now()

	if _first_admit_time < 0.0:
		_first_admit_time = now

	_last_admit_time = now
	_total_wait += wait_time
	_wait_samples += 1
	_max_wait = maxf(_max_wait, wait_time)

	var retained: bool = retain_evacuated
	var slot: int = -1

	if retained:
		slot = _allocate_slot()
		_occupancy += 1
		_peak_occupancy = maxi(_peak_occupancy, _occupancy)

	var info: Dictionary = {
		"exit_id": _resolved_exit_id(),
		"exit_name": _resolved_exit_name(),
		"track": track_evacuation,
		"retain": retained,
		"visible": keep_retained_visible,
		"retain_seconds": retained_hold_time,
		"wait_time": wait_time,
		"receiving_slot": slot,
		"occupancy": _occupancy,
		"service_rate": exit_service_rate,
	}

	var manager := get_node_or_null("/root/EvacuationManager")
	var handled: bool = false

	if manager != null and manager.has_method("register_evacuation"):
		var result: Dictionary = manager.register_evacuation(agent, self, info)
		handled = true

		if not bool(result.get("retained", false)) and retained:
			_release_slot(slot)
			_occupancy = maxi(0, _occupancy - 1)

	if not handled:
		if is_instance_valid(agent) and agent.has_method("mark_evacuated"):
			agent.mark_evacuated()

		GlobalData.register_evacuation()

		if retained:
			# Without EvacuationManager there is nowhere safe to store retained
			# agents, so fall back to despawn rather than leaking active ones.
			_release_slot(slot)
			_occupancy = maxi(0, _occupancy - 1)

		if is_instance_valid(agent):
			agent.queue_free()

	_notify_occupancy_changed()


func _reject(agent: Node, reason: String) -> void:
	_rejected += 1
	_emit_queue(agent, "rejected:" + reason)

	if is_instance_valid(agent) and agent.has_method("reject_evacuation"):
		agent.reject_evacuation(reason)


func _is_full() -> bool:
	return receiving_capacity > 0 and _occupancy >= receiving_capacity


func _is_valid_agent(agent: Variant) -> bool:
	if agent == null or not is_instance_valid(agent):
		return false

	var node := agent as Node

	return (
		node.is_inside_tree()
		and not node.has_meta("evacuated")
		and node.is_in_group("npc")
	)


func _remove_from_queue(agent: Node) -> bool:
	for index: int in range(_queue.size()):
		if _queue[index].get("agent") == agent:
			_queue.remove_at(index)
			return true

	return false


## Called by Member when its exit hold times out or by the manager when a
## retained agent leaves. Removes the agent without accepting it.
func cancel_agent(agent: Node) -> void:
	var was_queued: bool = _remove_from_queue(agent)

	if _service_agent == agent:
		_service_agent = null
		_service_wait = 0.0
		_service_complete_at = 0.0
		was_queued = true

	if was_queued:
		_emit_queue(agent, "cancelled")

	_service_tick()


func _emit_queue(agent: Node, event: String) -> void:
	if agent == null or not is_instance_valid(agent):
		return

	queue_event.emit(self, agent, event, _queue.size())


## Called by EvacuationManager when a retained agent is removed. Frees the
## receiving slot so a queued agent can be admitted.
func release_receiving_slot(slot: int) -> void:
	if slot >= 0:
		_release_slot(slot)

	_occupancy = maxi(0, _occupancy - 1)
	_notify_occupancy_changed()
	_service_tick()


## World position for a retained agent in the receiving area. Slot indices are
## stable and reused, so a long run does not push agents arbitrarily far away.
func get_receiving_slot_global_position(slot: int) -> Vector3:
	var center: Vector3 = to_global(receiving_area_offset)
	var index: int = maxi(slot, 0)

	if index == 0:
		return center

	var angle: float = float(index) * 2.39996323
	var radius: float = receiving_slot_spacing * sqrt(float(index))

	return center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)


## Lightweight occupancy read used by EvacuationManager's incremental peak
## tracker; avoids building the full status dictionary on every admission.
func get_receiving_occupancy() -> int:
	return _occupancy


func get_exit_status() -> Dictionary:
	return {
		"exit_id": _resolved_exit_id(),
		"name": _resolved_exit_name(),
		"location": [global_position.x, global_position.y, global_position.z],
		"operational": operational,
		"available": is_available(),
		"track": track_evacuation,
		"retain": retain_evacuated,
		"visible": keep_retained_visible,
		"service_rate": exit_service_rate,
		"max_queue_length": max_queue_length,
		"receiving_capacity": receiving_capacity,
		"receiving_full_behavior": int(receiving_full_behavior),
		"receiving_area_offset": [receiving_area_offset.x, receiving_area_offset.y, receiving_area_offset.z],
		"receiving_occupancy": _occupancy,
		"peak_occupancy": _peak_occupancy,
		"accepted": _accepted,
		"rejected": _rejected,
		"capacity_waits": _capacity_waits,
		"capacity_rejections": _capacity_rejections,
		"queue_full_rejections": _queue_full_rejections,
		"current_queue": _queue.size(),
		"max_queue": _max_queue,
		"average_wait": _total_wait / float(maxi(_wait_samples, 1)),
		"max_wait": _max_wait,
		"first_admit_time": _first_admit_time,
		"last_admit_time": _last_admit_time,
	}


## Usable for exit choice right now. Capacity/queue limits are admission
## policy, not availability, so they do not disable the exit.
func is_available() -> bool:
	return operational and is_inside_tree()


func get_exit_id() -> String:
	return _resolved_exit_id()


## Disable or re-enable this exit at runtime. Agents whose current target is
## this exit are notified so they can choose again.
func set_operational(value: bool) -> void:
	operational = value


func _notify_availability_changed() -> void:
	availability_changed.emit(self, is_available())

	if operational:
		return

	# An exit that disappears from the choice set must also release agents
	# already walking to it; otherwise they would keep a target they can no
	# longer use.
	for entry: Dictionary in _queue:
		var queued: Variant = entry.get("agent")

		if (
			queued != null
			and is_instance_valid(queued)
			and queued.has_method("on_exit_area_exited")
		):
			queued.on_exit_area_exited()

	_queue.clear()

	if (
		_service_agent != null
		and is_instance_valid(_service_agent)
		and _service_agent.has_method("on_exit_area_exited")
	):
		_service_agent.on_exit_area_exited()

	_service_agent = null
	_service_wait = 0.0
	_service_complete_at = 0.0

	var tree: SceneTree = get_tree()

	if tree == null:
		return

	for npc: Node in tree.get_nodes_in_group("npc"):
		if npc != null and is_instance_valid(npc) and npc.has_method("on_exit_unavailable"):
			npc.on_exit_unavailable(self)


func _resolved_exit_id() -> String:
	if not exit_id.is_empty():
		return exit_id

	return String(get_path())


func _resolved_exit_name() -> String:
	if name == "Area3D" and get_parent() != null:
		return String(get_parent().name)

	return String(name)


func _allocate_slot() -> int:
	if not _free_slots.is_empty():
		return _free_slots.pop_back()

	var slot: int = _next_slot
	_next_slot += 1
	return slot


func _release_slot(slot: int) -> void:
	if slot >= 0 and not _free_slots.has(slot):
		_free_slots.append(slot)


func _notify_occupancy_changed() -> void:
	occupancy_changed.emit(self)

	var manager := get_node_or_null("/root/EvacuationManager")
	if manager != null and manager.has_method("notify_receiving_occupancy_changed"):
		manager.notify_receiving_occupancy_changed(self)


func _reset_state() -> void:
	_queue.clear()
	_service_agent = null
	_service_wait = 0.0
	_service_complete_at = 0.0
	_free_slots.clear()
	_next_slot = 0
	_occupancy = 0
	_peak_occupancy = 0
	_accepted = 0
	_rejected = 0
	_capacity_rejections = 0
	_capacity_waits = 0
	_queue_full_rejections = 0
	_max_queue = 0
	_total_wait = 0.0
	_wait_samples = 0
	_max_wait = 0.0
	_first_admit_time = -1.0
	_last_admit_time = -1.0


func _exit_tree() -> void:
	# Occupancy belongs to this point. Zero it before notifying so the manager's
	# incremental total does not keep a stale value after the node is freed.
	_occupancy = 0
	_notify_occupancy_changed()

	var manager := get_node_or_null("/root/EvacuationManager")

	if manager != null and manager.has_method("release_retained_for_point"):
		manager.release_retained_for_point(self)

	# Never leave an agent permanently held when the exit is deleted.
	for entry: Dictionary in _queue:
		var queued: Variant = entry.get("agent")
		if (
			queued != null
			and is_instance_valid(queued)
			and queued.has_method("on_exit_area_exited")
		):
			queued.on_exit_area_exited()

	if (
		_service_agent != null
		and is_instance_valid(_service_agent)
		and _service_agent.has_method("on_exit_area_exited")
	):
		_service_agent.on_exit_area_exited()

	_queue.clear()
	_service_agent = null
