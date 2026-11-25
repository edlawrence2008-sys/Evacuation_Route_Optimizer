class_name OptimizationRequest
extends RefCounted

## What the caller asks the optimizer to solve. The request is plain data so it
## can be recorded, replayed and compared between runs.

const MODE_FASTEST := "fastest"
const MODE_BALANCED := "balanced"
const MODE_CONGESTION := "congestion"
const MODE_SAFETY := "safety"
const MODE_DISRUPTION := "disruption"

const ALGORITHM_NEAREST := "nearest"
const ALGORITHM_EQUAL_SPLIT := "equal_split"
const ALGORITHM_GREEDY := "greedy"
const ALGORITHM_GREEDY_CONGESTION := "greedy_congestion"
const ALGORITHM_EXHAUSTIVE := "exhaustive"
const ALGORITHM_LOCAL_SEARCH := "local_search"
const ALGORITHM_ACO := "aco"
const ALGORITHM_PSO := "pso"
const ALGORITHM_NETWORK_FLOW := "network_flow"
const ALGORITHM_TIME_EXPANDED := "time_expanded"

const MODES: Array[String] = [
	MODE_FASTEST,
	MODE_BALANCED,
	MODE_CONGESTION,
	MODE_SAFETY,
	MODE_DISRUPTION,
]

const ALGORITHMS: Array[String] = [
	ALGORITHM_NEAREST,
	ALGORITHM_EQUAL_SPLIT,
	ALGORITHM_GREEDY,
	ALGORITHM_GREEDY_CONGESTION,
	ALGORITHM_EXHAUSTIVE,
	ALGORITHM_LOCAL_SEARCH,
	ALGORITHM_ACO,
	ALGORITHM_PSO,
	ALGORITHM_NETWORK_FLOW,
	ALGORITHM_TIME_EXPANDED,
]

var snapshot: SimulationSnapshot
var algorithm: String = ALGORITHM_GREEDY
var mode: String = MODE_BALANCED
## Objective weights. Missing keys fall back to `default_weights(mode)`.
var weights: Dictionary = {}
## Algorithm parameters: cohort_size, max_cohorts, q_max, time_budget_ms,
## max_combinations, reference_time, violation_penalty, local_search_passes.
var parameters: Dictionary = {}
var cohort_size: float = 4.0
var max_cohorts: int = 60


## Starting weights, in seconds. These are behavioural priors to sweep, not
## calibrated constants. Phase 1 scores time, congestion and queue only; the
## other terms are accepted but stay at zero until their models exist.
static func default_weights(for_mode: String) -> Dictionary:
	match for_mode:
		MODE_FASTEST:
			return {"time": 1.0, "congestion": 0.1, "queue": 0.1}
		MODE_CONGESTION:
			return {"time": 0.6, "congestion": 1.0, "queue": 0.4}
		MODE_SAFETY:
			return {"time": 0.6, "congestion": 0.6, "queue": 0.2}
		MODE_DISRUPTION:
			return {"time": 1.0, "congestion": 0.6, "queue": 0.4}
		_:
			return {"time": 1.0, "congestion": 0.4, "queue": 0.3}


func get_weights() -> Dictionary:
	var result: Dictionary = default_weights(mode)
	var given: Variant = weights

	if given is Dictionary:
		for key: Variant in (given as Dictionary).keys():
			result[String(key)] = float(given[key])

	return result


func get_parameter(name: String, fallback: Variant) -> Variant:
	return parameters.get(name, fallback)


func get_algorithm_label() -> String:
	return algorithm


func is_supported_algorithm() -> bool:
	return ALGORITHMS.has(algorithm)


func describe() -> String:
	return (
		"algorithm=%s mode=%s cohort=%.1fm max=%d"
		% [algorithm, mode, cohort_size, max_cohorts]
	)
