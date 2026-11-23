class_name LogicTimerComponent
extends LogicComponent

## Clock / timer. One central LogicNetwork tick drives every timer, so hundreds
## of clocks do not each run a `_process` callback.

enum Mode { LOOP, ONE_SHOT }

@export var period: float = 2.0
@export_range(0.0, 1.0, 0.01) var duty: float = 0.5
@export var mode: Mode = Mode.LOOP
@export var auto_start: bool = true

var _time: float = 0.0
var _running: bool = false


func _ready() -> void:
	super._ready()
	if auto_start:
		start()


func _exit_tree() -> void:
	LogicNetwork.unregister_timer(self)


func start() -> void:
	_running = true
	_time = 0.0
	LogicNetwork.register_timer(self)
	set_output(true)


func stop() -> void:
	_running = false
	LogicNetwork.unregister_timer(self)
	set_output(false)


func tick(delta: float) -> void:
	if not _running:
		return

	var cycle := maxf(period, 0.05)
	_time += delta

	if _time >= cycle:
		if mode == Mode.ONE_SHOT:
			_time = cycle
			_running = false
			LogicNetwork.unregister_timer(self)
			set_output(false)
			return
		_time = fmod(_time, cycle)

	set_output(_time < cycle * clampf(duty, 0.0, 1.0))
