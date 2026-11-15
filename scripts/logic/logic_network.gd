extends Node

## Central event-driven logic network.
##
## Components only push values for *changes*. Gates evaluate when an input
## changes, and timers are ticked here once per frame instead of every logic
## node running its own `_process`. This keeps a large map of lamps, doors,
## gates, and clocks cheap: idle devices cost nothing beyond the timer list.

const MAX_STEPS_PER_FRAME: int = 512

var _timers: Array = []
var _pending: Array = []


func register_timer(timer: Node) -> void:
	if timer != null and not _timers.has(timer):
		_timers.append(timer)


func unregister_timer(timer: Node) -> void:
	_timers.erase(timer)


func post_input(target: Node, input_index: int, value: bool) -> void:
	if target == null:
		return
	_pending.append({
		"target": target,
		"input": input_index,
		"value": value,
	})


func _process(delta: float) -> void:
	for timer: Node in _timers.duplicate():
		if is_instance_valid(timer):
			timer.tick(delta)

	var steps := 0
	while not _pending.is_empty() and steps < MAX_STEPS_PER_FRAME:
		var entry: Dictionary = _pending.pop_front()
		var target: Node = entry["target"]
		if is_instance_valid(target):
			target.receive_input(
				int(entry["input"]),
				bool(entry["value"])
			)
		steps += 1

	# A feedback loop that never settles must not grow the queue forever.
	if _pending.size() > MAX_STEPS_PER_FRAME * 4:
		_pending.clear()
