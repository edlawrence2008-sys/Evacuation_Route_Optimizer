extends RichTextLabel

## Toggles with F4. Shows the live run summary recorded by EvacuationManager.

var _refresh_accum: float = 0.0
const REFRESH_INTERVAL: float = 0.2


func _ready() -> void:
	visible = false
	bbcode_enabled = true
	scroll_active = true

	var manager := get_node_or_null("/root/EvacuationManager")
	if manager and manager.has_signal("metrics_changed"):
		manager.metrics_changed.connect(_on_metrics_changed)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("ui_results_toggle"):
		visible = not visible
		if visible:
			_refresh()

	if not visible:
		return

	_refresh_accum += delta
	if _refresh_accum >= REFRESH_INTERVAL:
		_refresh_accum = 0.0
		_refresh()


func _on_metrics_changed() -> void:
	if visible:
		_refresh()


func _refresh() -> void:
	var manager := get_node_or_null("/root/EvacuationManager")
	if manager == null or not manager.has_method("get_summary"):
		text = "[color=red]EvacuationManager is not available.[/color]"
		return

	var summary: Dictionary = manager.get_summary()
	var running: bool = bool(summary.get("running", false))
	var complete: bool = bool(summary.get("complete", false))
	var state_text: String = "COMPLETE" if complete else ("RUNNING" if running else "STOPPED")
	var state_color: String = "green" if complete or running else "gray"

	var spawned: int = int(summary.get("spawned", 0))
	var evacuated: int = int(summary.get("evacuated", 0))
	var alive: int = int(summary.get("alive", 0))
	var quota: int = int(summary.get("total_quota", -1))
	var quota_text: String = "unlimited" if quota < 0 else str(quota)
	var completion: float = 0.0
	if spawned > 0:
		completion = float(evacuated) / float(spawned) * 100.0

	var lines: Array[String] = []
	lines.append("[b][color=yellow]EVACUATION RESULTS[/color][/b]")
	lines.append(
		"State: [color=%s]%s[/color]   Elapsed: %s"
		% [state_color, state_text, _format_duration(float(summary.get("elapsed", 0.0)))]
	)
	lines.append(
		"Spawned: [b]%d[/b]   Evacuated: [b]%d[/b]   Alive: [b]%d[/b]"
		% [spawned, evacuated, alive]
	)
	lines.append(
		"Total spawn quota: [b]%s[/b]   Completion: [b]%.1f%%[/b]"
		% [quota_text, completion]
	)
	lines.append("")

	lines.append("[b]Timing[/b]")
	lines.append(
		"Average: %s   Median: %s"
		% [
			_format_duration(float(summary.get("average_time", 0.0))),
			_format_duration(float(summary.get("median_time", 0.0))),
		]
	)
	lines.append(
		"P95: %s   Min/Max: %s / %s"
		% [
			_format_duration(float(summary.get("p95_time", 0.0))),
			_format_duration(float(summary.get("min_time", 0.0))),
			_format_duration(float(summary.get("max_time", 0.0))),
		]
	)
	lines.append(
		"Failed paths: %d   Deaths: %d   Peak density: %.1f"
		% [
			int(summary.get("failed_paths", 0)),
			int(summary.get("deaths", 0)),
			float(summary.get("peak_density", 0.0)),
		]
	)
	var contact: Dictionary = summary.get("contact_force_stats", {})

	if not contact.is_empty() and int(contact.get("samples", 0)) > 0:
		var above: Dictionary = contact.get("agent_seconds_above", {})
		lines.append(
			"Contact: peak %.2f kN at %.1f s   p99 loaded: %.2f kN"
			% [
				float(contact.get("peak_force", 0.0)) / 1000.0,
				float(contact.get("peak_time", 0.0)),
				float(contact.get("p99_loaded", 0.0)) / 1000.0,
			]
		)
		lines.append(
			"Compression: >2 kN %.2f agent-s, >3 kN %.2f agent-s (%.3f%% samples in contact)"
			% [
				float(above.get("2000", 0.0)),
				float(above.get("3000", 0.0)),
				float(contact.get("nonzero_fraction", 0.0)) * 100.0,
			]
		)
	lines.append(
		"Distance: %.0f m total (%.1f m avg)   Stuck: %s (%d strikes)"
		% [
			float(summary.get("total_distance", 0.0)),
			float(summary.get("average_distance", 0.0)),
			_format_duration(float(summary.get("total_stuck_time", 0.0))),
			int(summary.get("total_stuck_strikes", 0)),
		]
	)
	lines.append("")

	lines.append("[b]Exits[/b]")
	var exits: Array = summary.get("exits", [])
	if exits.is_empty():
		lines.append("[i]No arrivals yet.[/i]")
	else:
		for exit: Dictionary in exits:
			var share: float = float(exit.get("share", 0.0)) * 100.0
			lines.append(
				"- [b]%s[/b]: %d evacuees (%.0f%%) | avg %s | %.1f/min"
				% [
					String(exit.get("name", "Exit")),
					int(exit.get("arrivals", 0)),
					share,
					_format_duration(float(exit.get("average_time", 0.0))),
					float(exit.get("throughput_per_minute", 0.0)),
				]
			)

			var details: Array[String] = []
			var service_rate: float = float(exit.get("service_rate", 0.0))
			var capacity: int = int(exit.get("receiving_capacity", 0))
			var occupancy: int = int(exit.get("receiving_occupancy", 0))
			var queue: int = int(exit.get("current_queue", 0))
			var average_wait: float = float(exit.get("average_wait", 0.0))
			var capacity_rejections: int = int(
				exit.get("capacity_rejections", 0)
			)
			var capacity_waits: int = int(exit.get("capacity_waits", 0))

			if service_rate > 0.0:
				details.append("%.2f/s service" % service_rate)
			if capacity > 0:
				details.append("%d/%d safe area" % [occupancy, capacity])
			elif occupancy > 0:
				details.append("%d in safe area" % occupancy)
			if queue > 0:
				details.append("%d waiting" % queue)
			if average_wait >= 0.1:
				details.append("wait %s" % _format_duration(average_wait))
			if capacity_waits + capacity_rejections > 0:
				details.append(
					"%d full waits / %d rejections"
					% [capacity_waits, capacity_rejections]
				)

			if not details.is_empty():
				lines.append(
					"   [color=gray]%s[/color]"
					% " · ".join(PackedStringArray(details))
				)

	var receiving_occupancy: int = int(
		summary.get("receiving_occupancy", 0)
	)
	var receiving_capacity: int = int(summary.get("receiving_capacity", 0))
	var receiving_queue: int = int(summary.get("receiving_queue", 0))
	var capacity_events: int = (
		int(summary.get("capacity_waits", 0))
		+ int(summary.get("capacity_rejections", 0))
		+ int(summary.get("queue_full_rejections", 0))
	)

	if (
		receiving_occupancy > 0
		or receiving_queue > 0
		or capacity_events > 0
		or receiving_capacity > 0
	):
		var capacity_text: String = "unlimited"

		if not bool(summary.get("receiving_unlimited", true)):
			capacity_text = str(receiving_capacity)

			if int(summary.get("receiving_unlimited_exits", 0)) > 0:
				capacity_text += " + unlimited"

		lines.append("")
		lines.append(
			"Receiving areas: [b]%d[/b] / %s occupied (peak %d)   Queue: %d"
			% [
				receiving_occupancy,
				capacity_text,
				int(summary.get("peak_receiving_occupancy", 0)),
				receiving_queue,
			]
		)
		lines.append(
			"Capacity events: %d waits, %d rejections   Retained: %d"
			% [
				int(summary.get("capacity_waits", 0)),
				int(summary.get("capacity_rejections", 0)),
				int(summary.get("retained_agents", 0)),
			]
		)

	lines.append("")
	lines.append("[color=gray]F4: toggle results · F3: statistics[/color]")
	text = "\n".join(PackedStringArray(lines))


func _format_duration(seconds: float) -> String:
	if seconds < 60.0:
		return "%.1fs" % seconds

	var whole: int = int(seconds)
	return "%d:%02d" % [int(whole / 60.0), whole % 60]
