class_name ExitCostAnalyzer
extends RefCounted

## Deterministic FIFO model of the exit admission policy.
##
## Each exit is the single server that `EvacPoint.exit_service_rate` models:
## one admitted agent every 1 / rate seconds. Arrivals are the predicted travel
## times of the assigned cohorts, expanded per agent and sorted. The completion
## of each arrival is max(arrival, previous completion + service interval).
##
## rate = 0 means unlimited admission: completion equals arrival and the wait is
## zero. That is a required case, not a fallback: the default exit has no
## configured service rate.

func evaluate(
	assignments: Array,
	cohorts: Array,
	exit_ids: Array,
	exits: Array,
	analyzer: PathAnalyzer
) -> Dictionary:
	var per_exit: Dictionary = {}

	for exit_index: int in range(exit_ids.size()):
		var exit_id: String = exit_ids[exit_index]
		var exit_data: Dictionary = _find_exit(exits, exit_id)

		per_exit[exit_id] = {
			"exit_id": exit_id,
			"exit_index": exit_index,
			"arrivals": [],
			"count": 0,
			"rate": maxf(float(exit_data.get("service_rate", 0.0)), 0.0),
			"queue_length": maxi(int(exit_data.get("queue_length", 0)), 0),
			"max_queue_length": maxi(int(exit_data.get("max_queue_length", 0)), 0),
		}

	for index: int in range(cohorts.size()):
		var exit_index: int = int(assignments[index]) if index < assignments.size() else -1

		if exit_index < 0 or exit_index >= exit_ids.size():
			continue

		var cohort: Dictionary = cohorts[index]
		var exit_id: String = exit_ids[exit_index]
		var route: Dictionary = analyzer.get_route(cohort, exit_id)

		if not bool(route.get("reachable", false)):
			continue

		var arrival: float = maxf(float(route.get("time", 0.0)), 0.0)
		var distance: float = maxf(float(route.get("distance", 0.0)), 0.0)
		var count: int = int(cohort.get("count", 0))
		var exit_row: Dictionary = per_exit[exit_id]
		var speeds: Array = cohort.get("speeds", [])

		# Use each member's own desired speed when the builder provided it: a
		# 0.65 m/s walker must not be averaged into a 1.34 m/s cohort and
		# predicted to arrive early. The slow tail defines the makespan.
		if speeds.size() == count and distance > 0.0:
			for speed_value: Variant in speeds:
				var member_speed: float = maxf(float(speed_value), 0.2)
				(exit_row["arrivals"] as Array).append(distance / member_speed)
		else:
			for _agent: int in range(count):
				(exit_row["arrivals"] as Array).append(arrival)

		exit_row["count"] = int(exit_row["count"]) + count

	var completion_time: float = 0.0
	var total_wait: float = 0.0
	var total_completion: float = 0.0
	var total_agents: int = 0
	var violations: Array = []

	for exit_id: String in per_exit.keys():
		var row: Dictionary = per_exit[exit_id]
		var arrivals: Array = row["arrivals"]
		arrivals.sort()

		var rate: float = float(row["rate"])
		var interval: float = (1.0 / rate) if rate > 0.0 else 0.0
		var server_ready: float = (
			float(row["queue_length"]) / rate if rate > 0.0 else 0.0
		)
		var completion: float = server_ready - interval
		var exit_wait: float = 0.0
		var exit_completion: float = 0.0

		for arrival_value: Variant in arrivals:
			var current_arrival: float = float(arrival_value)
			completion = maxf(current_arrival, completion + interval)
			exit_wait += maxf(completion - current_arrival, 0.0)
			exit_completion = completion
			total_completion += completion
			total_agents += 1

		row["wait"] = exit_wait
		row["completion"] = exit_completion
		row["predicted_queue"] = arrivals.size() + int(row["queue_length"])
		row.erase("arrivals")

		var max_queue: int = int(row["max_queue_length"])

		if max_queue > 0 and int(row["predicted_queue"]) > max_queue:
			violations.append("queue_limit:%s" % exit_id)

		completion_time = maxf(completion_time, exit_completion)
		total_wait += exit_wait

	return {
		"completion_time": completion_time,
		"total_wait": total_wait,
		"average_time": (
			total_completion / float(total_agents) if total_agents > 0 else 0.0
		),
		"total_agents": total_agents,
		"per_exit": per_exit,
		"violations": violations,
	}


static func _find_exit(exits: Array, exit_id: String) -> Dictionary:
	for exit_data: Dictionary in exits:
		if String(exit_data.get("exit_id", "")) == exit_id:
			return exit_data

	return {}
