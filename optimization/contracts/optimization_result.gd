class_name OptimizationResult
extends RefCounted

## Decisions returned by the optimizer. Contains no node references, callables
## or scene paths: the simulation adapter validates it and applies it, and the
## recorder can store it verbatim.

var source_environment_version: int = -1
var algorithm: String = ""
var mode: String = ""
var feasible: bool = false

## One row per optimized cohort:
##   cohort_id, members (Array[int] serials), count, position, cell,
##   exit_id, exit_index, predicted_distance, predicted_travel_time
var cohorts: Array = []

var agent_exit_assignments: Dictionary = {}   # serial -> exit_id
var agent_targets: Dictionary = {}            # serial -> Vector3
var exit_counts: Dictionary = {}              # exit_id -> assigned agents

var estimated_cost: float = INF
var terms: Dictionary = {}                    # time, congestion, queue (seconds)
var estimated_completion_time: float = 0.0
var estimated_average_time: float = 0.0
var convergence_history: Array = []
var computation_time_ms: float = 0.0
var evaluations: int = 0
var violations: Array = []

## Non-fatal information for the panel/recorder (cohort count, search space...).
var detail: Dictionary = {}


func is_usable() -> bool:
	return feasible and not cohorts.is_empty() and not agent_exit_assignments.is_empty()


func get_violation_summary() -> String:
	if violations.is_empty():
		return ""

	return ", ".join(violations)


func to_dictionary() -> Dictionary:
	return {
		"algorithm": algorithm,
		"mode": mode,
		"feasible": feasible,
		"environment_version": source_environment_version,
		"cohort_count": cohorts.size(),
		"agent_count": agent_exit_assignments.size(),
		"exit_counts": exit_counts.duplicate(true),
		"estimated_cost": estimated_cost,
		"terms": terms.duplicate(true),
		"estimated_completion_time": estimated_completion_time,
		"estimated_average_time": estimated_average_time,
		"convergence": convergence_history.duplicate(true),
		"computation_time_ms": computation_time_ms,
		"evaluations": evaluations,
		"violations": violations.duplicate(),
		"detail": detail.duplicate(true),
	}
