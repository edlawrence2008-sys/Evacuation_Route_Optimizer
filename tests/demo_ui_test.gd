extends SceneTree

## Layout smoke test for the Demo Player and Demo Comparer:
## - both transport bars sit inside a horizontal scroll container,
## - the comparer has the new per-demo tables and collapsed detail section.
##
##   godot --headless --path . --script res://tests/demo_ui_test.gd

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("=== demo ui ===")
	await process_frame

	var player: Node = root.get_node_or_null("DemoPlayer")
	var comparer: Node = root.get_node_or_null("DemoComparer")

	_expect("player autoload", player != null)
	_expect("comparer autoload", comparer != null)

	if player != null:
		var player_ui: Variant = player.get("_ui")
		_expect("player: UI built", player_ui != null)

		if player_ui is Control:
			_expect(
				"player: transport bar scrolls horizontally",
				_has_horizontal_scroll(player_ui)
			)
			_expect(
				"player: Load State action",
				_has_button_text(player_ui, "Load State")
			)

		var panel: Variant = player.get("_panel")
		_expect("player: bottom panel exists", panel != null)

		if panel is Control:
			_expect(
				"player: bottom panel reserves scroll height",
				(panel as Control).offset_top <= -120.0,
				str((panel as Control).offset_top)
			)

	if comparer != null:
		var comparer_ui: Variant = comparer.get("_ui")
		_expect("comparer: UI built", comparer_ui != null)

		if comparer_ui is Control:
			_expect(
				"comparer: transport bar scrolls horizontally",
				_has_horizontal_scroll(comparer_ui)
			)

		_expect("comparer: values table box", comparer.get("_values_box") != null)
		_expect("comparer: deltas table box", comparer.get("_deltas_box") != null)
		_expect("comparer: final summary box", comparer.get("_summary_box") != null)
		_expect("comparer: verdict label", comparer.get("_verdict_label") != null)
		_expect(
			"comparer: details toggle",
			comparer.get("_differences_toggle") != null
		)

		var details: Variant = comparer.get("_differences")
		_expect(
			"comparer: details hidden by default",
			details != null and not bool((details as CanvasItem).visible)
		)

		_test_comparer_tables(comparer)

	print("checks=%d failures=%d" % [_checks, _failures])
	print("=== %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(1 if _failures > 0 else 0)


func _test_comparer_tables(comparer: Node) -> void:
	var demo_a: Dictionary = {
		"letter": "A",
		"name": "Baseline",
		"color": Color(1.0, 0.4, 0.3),
		"events": [{
			"type": "end",
			"summary": {
				"total_evacuation_time": 100.0,
				"average_evacuation_time": 50.0,
				"p95_evacuation_time": 80.0,
				"max_evacuation_time": 90.0,
				"global_max_density": 1.0,
				"peak_contact_force": 1000.0,
				"agents_died": 0,
			},
		}],
	}
	var demo_b: Dictionary = {
		"letter": "B",
		"name": "Optimized",
		"color": Color(0.3, 0.7, 1.0),
		"events": [{
			"type": "end",
			"summary": {
				"total_evacuation_time": 80.0,
				"average_evacuation_time": 42.0,
				"p95_evacuation_time": 70.0,
				"max_evacuation_time": 85.0,
				"global_max_density": 1.1,
				"peak_contact_force": 1200.0,
				"agents_died": 0,
			},
		}],
	}
	comparer.set("_demos", [demo_a, demo_b])
	comparer.call("_build_metrics_tables")

	var values_box: Variant = comparer.get("_values_box")
	var deltas_box: Variant = comparer.get("_deltas_box")

	_expect(
		"comparer: values grid built",
		values_box != null and (values_box as VBoxContainer).get_child_count() == 1
	)
	_expect(
		"comparer: deltas grid built",
		deltas_box != null and (deltas_box as VBoxContainer).get_child_count() == 1
	)

	if values_box == null or deltas_box == null:
		return

	var values_grid := (values_box as VBoxContainer).get_child(0) as GridContainer
	var deltas_grid := (deltas_box as VBoxContainer).get_child(0) as GridContainer
	_expect("comparer: values columns", values_grid.columns == 3, str(values_grid.columns))
	_expect("comparer: deltas columns", deltas_grid.columns == 2, str(deltas_grid.columns))
	_expect(
		"comparer: values cells",
		values_grid.get_child_count() == 21,
		str(values_grid.get_child_count())
	)
	_expect(
		"comparer: delta cells",
		deltas_grid.get_child_count() == 14,
		str(deltas_grid.get_child_count())
	)

	var base: Dictionary = {
		"evacuated": 10.0, "active": 40.0, "density": 0.5,
		"throughput": 2.0, "contact": 1.2, "routes": 3.0,
	}
	var second: Dictionary = {
		"evacuated": 12.0, "active": 38.0, "density": 0.6,
		"throughput": 2.5, "contact": 1.0, "routes": 5.0,
	}
	comparer.call("_update_metric_tables", [base, second], base)

	var value_labels: Array = comparer.get("_value_labels")
	var delta_labels: Array = comparer.get("_delta_labels")
	_expect("comparer: value label rows", value_labels.size() == 6)
	_expect("comparer: delta label rows", delta_labels.size() == 6)

	if value_labels.size() > 0:
		var evacuated_row: Array = value_labels[0]
		_expect(
			"comparer: table shows A value",
			(evacuated_row[0] as Label).text == "10",
			(evacuated_row[0] as Label).text
		)
		_expect(
			"comparer: table shows B value",
			(evacuated_row[1] as Label).text == "12",
			(evacuated_row[1] as Label).text
		)
	if delta_labels.size() > 0:
		var delta_row: Array = delta_labels[0]
		_expect(
			"comparer: delta shows +2",
			(delta_row[0] as Label).text == "+2",
			(delta_row[0] as Label).text
		)

	var summary_box: Variant = comparer.get("_summary_box")
	_expect(
		"comparer: final summary table built",
		summary_box != null and (summary_box as VBoxContainer).get_child_count() == 1
	)
	var verdict: Variant = comparer.get("_verdict_label")
	_expect(
		"comparer: verdict reports the faster run",
		verdict is Label and String((verdict as Label).text).contains("faster"),
		"" if verdict == null else String((verdict as Label).text)
	)


func _has_horizontal_scroll(node: Node) -> bool:
	if node is ScrollContainer:
		var scroll := node as ScrollContainer

		if scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO:
			return true

	for child: Node in node.get_children():
		if _has_horizontal_scroll(child):
			return true

	return false


func _has_button_text(node: Node, text: String) -> bool:
	if node is Button and (node as Button).text == text:
		return true

	for child: Node in node.get_children():
		if _has_button_text(child, text):
			return true

	return false


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1

	if condition:
		print("  PASS  " + label)
		return

	_failures += 1
	print("  FAIL  " + label + ("" if detail.is_empty() else "  [" + detail + "]"))
