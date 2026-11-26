extends Node

## Per-save library of saved evacuation plans.
##
## Layout:
##   user://saves/<save_slug>/plans/<slug>.json
##   user://plans/<slug>.json            (when no save is active)
##
## A plan is plain JSON (see EvacuationPlan) so it can be copied into an
## experiment export folder and inspected without the game.

const PLANS_DIR: String = "plans"
const UNSAVED_ROOT: String = "user://plans"


func plans_root(save_slug: String = "") -> String:
	var slug := save_slug

	if slug.is_empty():
		var demo_store := get_node_or_null("/root/DemoStore")

		if demo_store != null and demo_store.has_method("active_save_slug"):
			slug = String(demo_store.call("active_save_slug"))

	if slug.is_empty():
		return UNSAVED_ROOT

	return "user://saves/%s/%s" % [slug, PLANS_DIR]


func plan_path(plan_id: String, save_slug: String = "") -> String:
	return plans_root(save_slug).path_join("%s.json" % _slugify(plan_id))


func list_plans(save_slug: String = "") -> Array:
	var root := plans_root(save_slug)
	var result: Array = []
	var directory := DirAccess.open(root)

	if directory == null:
		return result

	directory.list_dir_begin()
	var file_name := directory.get_next()

	while not file_name.is_empty():
		if not directory.current_is_dir() and file_name.ends_with(".json"):
			var path := root.path_join(file_name)
			var plan := EvacuationPlan.load_from(path)

			if plan != null:
				result.append({
					"id": file_name.trim_suffix(".json"),
					"name": plan.name if not plan.name.is_empty() else file_name.trim_suffix(".json"),
					"path": path,
					"algorithm": plan.algorithm,
					"assignments": plan.assignment_count(),
					"routes": plan.routes_with_polylines(),
					"authored_cells": plan.authored_cell_count(),
					"seed": plan.rng_seed,
					"created_at": plan.created_at,
					"slots": 0,
				})

		file_name = directory.get_next()

	directory.list_dir_end()
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("created_at", "")) > String(b.get("created_at", ""))
	)
	return result


func save_plan(plan: EvacuationPlan, plan_id: String = "", save_slug: String = "") -> String:
	if plan == null:
		return ""

	var id := plan_id

	if id.is_empty():
		id = plan.name

	if id.is_empty():
		id = "plan"

	var unique := _unique_id(id, save_slug)
	plan.name = plan.name if not plan.name.is_empty() else unique

	var path := plan_path(unique, save_slug)

	if not plan.save_to(path):
		return ""

	return unique


func load_plan(plan_id: String, save_slug: String = "") -> EvacuationPlan:
	return EvacuationPlan.load_from(plan_path(plan_id, save_slug))


func delete_plan(plan_id: String, save_slug: String = "") -> bool:
	var path := plan_path(plan_id, save_slug)

	if not FileAccess.file_exists(path):
		return false

	return DirAccess.remove_absolute(path) == OK


## Capture the last optimizer plan from a recorded demo without replaying it.
func plan_from_demo(demo_id: String, save_slug: String = "") -> EvacuationPlan:
	var demo_store := get_node_or_null("/root/DemoStore")

	if demo_store == null:
		return null

	var path := String(demo_store.call("recording_path", demo_id, save_slug))
	var plan := EvacuationPlan.from_recording(path, demo_id)
	return plan


func _unique_id(base: String, save_slug: String) -> String:
	var cleaned := _slugify(base)
	var candidate := cleaned
	var index := 2

	while FileAccess.file_exists(plan_path(candidate, save_slug)):
		candidate = "%s_%d" % [cleaned, index]
		index += 1

	return candidate


func _slugify(value: String) -> String:
	var cleaned := value.strip_edges().to_lower()
	var result := ""

	for character: String in cleaned:
		if character in "abcdefghijklmnopqrstuvwxyz0123456789_-":
			result += character
		elif character == " " or character == ".":
			result += "_"

	if result.is_empty():
		result = "plan"

	if result.length() > 64:
		result = result.substr(0, 64)

	return result
