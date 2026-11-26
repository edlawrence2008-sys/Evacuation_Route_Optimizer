extends Node

## Renders a saved EvacuationPlan in the live world.
##
## This is the "show me the plan I saved" view: it reconstructs the optimizer
## event and route rows from the plan and feeds the same DemoPlanOverlay used by
## the Demo Player, so the live view and playback use one implementation.
## Console: `plan_render <id>` / `plan_render off`.

var current_plan: EvacuationPlan = null
var _overlay: DemoPlanOverlay = null


func show_plan(plan: EvacuationPlan) -> bool:
	hide_plan()

	if plan == null:
		return false

	var host: Node = get_tree().current_scene if get_tree() != null else null

	if host == null:
		return false

	var cohorts: Array = plan.cohorts.duplicate(true)
	var routes: Dictionary = {}
	var assignments: Dictionary = plan.exit_counts()

	for assignment_value: Variant in plan.assignments:
		if not assignment_value is Dictionary:
			continue

		var assignment: Dictionary = assignment_value
		var serial := int(assignment.get("serial", -1))
		var path: Array = EvacuationPlan._point_array_list(assignment.get("route", []))
		routes[serial] = [{
			"t": 0.0,
			"agent": serial,
			"reason": "plan",
			"exit_id": String(assignment.get("exit_id", "")),
			"path": path,
			"route_id": 1,
			"target": assignment.get("target", []),
			"route_changes": 1,
			"route_switches": 0,
		}]

	var exit_positions: Dictionary = {}

	for exit_value: Variant in plan.exits:
		if not exit_value is Dictionary:
			continue

		var exit_data: Dictionary = exit_value
		var position := EvacuationPlan._point_array(
			exit_data.get("position", exit_data.get("location", []))
		)

		if position.size() >= 3:
			exit_positions[String(exit_data.get("exit_id", ""))] = Vector3(
				float(position[0]), float(position[1]), float(position[2])
			)

	var events: Array = [{
		"type": "optimizer",
		"t": 0.0,
		"name": plan.algorithm,
		"detail": {
			"algorithm": plan.algorithm,
			"mode": plan.mode,
			"cohorts": cohorts,
			"exit_counts": assignments,
			"cohort_count": cohorts.size(),
			"agent_count": plan.assignment_count(),
		},
	}]

	_overlay = DemoPlanOverlay.new()
	_overlay.name = "LivePlanOverlay"
	host.add_child(_overlay)
	_overlay.configure(routes, events, exit_positions)
	_overlay.set_enabled(true)
	_overlay.set_show_routes(true)
	_overlay.set_time(1.0)
	current_plan = plan
	return true


func hide_plan() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()

	_overlay = null
	current_plan = null


func is_showing() -> bool:
	return _overlay != null and is_instance_valid(_overlay)
