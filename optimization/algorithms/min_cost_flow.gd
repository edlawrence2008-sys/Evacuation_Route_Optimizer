class_name MinCostFlow
extends RefCounted

## Successive-shortest-path min-cost flow over an integer-capacity network.
##
## The optimizer uses it for two assignment models:
##   - a static transportation network (cohort -> exit capacities),
##   - a time-expanded network where exit service slots occupy time bins.
##
## Costs are floats (seconds); capacities are integers (agents). The solver is
## deliberately small and dependency-free: SPFA finds the cheapest residual path,
## and every augmentation pushes the path bottleneck, so the number of
## augmentations is bounded by the number of saturated edges, not by the agent
## count. That keeps a 600-agent instance cheap even though flow is modelled per
## agent rather than per cohort.
##
## All costs must be finite. Use a large finite value instead of INF for an
## "unlimited" capacity: an integer overflow in the residual graph would make
## the path search meaningless.

const INF_CAPACITY: int = 1 << 30
const INF_COST: float = 1.0e18

var _node_count: int = 0
var _edges: Array = []
var _adjacency: Array = []


func add_node() -> int:
	_node_count += 1
	_adjacency.append([])
	return _node_count - 1


func node_count() -> int:
	return _node_count


## Adds a directed edge with the given capacity and cost, plus its residual.
## Returns the forward edge index so the caller can read `get_flow(index)`.
func add_edge(from_node: int, to_node: int, capacity: int, cost: float) -> int:
	assert(from_node >= 0 and from_node < _node_count)
	assert(to_node >= 0 and to_node < _node_count)
	var forward: int = _edges.size()
	_edges.append({
		"from": from_node,
		"to": to_node,
		"capacity": maxi(capacity, 0),
		"cost": cost,
		"flow": 0,
	})
	_edges.append({
		"from": to_node,
		"to": from_node,
		"capacity": 0,
		"cost": -cost,
		"flow": 0,
	})
	(_adjacency[from_node] as Array).append(forward)
	(_adjacency[to_node] as Array).append(forward + 1)
	return forward


func get_flow(edge_index: int) -> int:
	if edge_index < 0 or edge_index >= _edges.size():
		return 0

	return int((_edges[edge_index] as Dictionary).get("flow", 0))


func get_edge_count() -> int:
	return _edges.size() >> 1


## Pushes at most `max_flow` units from `source` to `sink`.
## Returns {flow, cost, augmentations, exhausted}. `exhausted` is true when no
## residual source-to-sink path exists (rather than the requested flow being
## reached): the caller can use it to detect an infeasible/locked network.
func solve(source: int, sink: int, max_flow: int) -> Dictionary:
	if source < 0 or sink < 0 or source >= _node_count or sink >= _node_count:
		return {"flow": 0, "cost": 0.0, "augmentations": 0, "exhausted": true}

	var target: int = maxi(max_flow, 0)
	var flow: int = 0
	var cost: float = 0.0
	var augmentations: int = 0

	while flow < target:
		var path: Dictionary = _shortest_path(source, sink)

		if bool(path.get("found", false)) == false:
			return {
				"flow": flow,
				"cost": cost,
				"augmentations": augmentations,
				"exhausted": true,
			}

		var bottleneck: int = target - flow
		var edge_indices: Array = path.get("edges", [])

		for edge_index: int in edge_indices:
			var edge: Dictionary = _edges[edge_index]
			bottleneck = mini(
				bottleneck,
				int(edge["capacity"]) - int(edge["flow"])
			)

		if bottleneck <= 0:
			return {
				"flow": flow,
				"cost": cost,
				"augmentations": augmentations,
				"exhausted": true,
			}

		for edge_index: int in edge_indices:
			var edge: Dictionary = _edges[edge_index]
			edge["flow"] = int(edge["flow"]) + bottleneck
			var reverse: Dictionary = _edges[edge_index ^ 1]
			reverse["flow"] = int(reverse["flow"]) - bottleneck
			cost += float(bottleneck) * float(edge["cost"])

		flow += bottleneck
		augmentations += 1

	return {
		"flow": flow,
		"cost": cost,
		"augmentations": augmentations,
		"exhausted": false,
	}


## SPFA over the residual graph. The graph is small (a few hundred nodes for a
## time-expanded instance) and residual costs can be negative, so a label-
## correcting queue is simpler and safer than maintaining Dijkstra potentials.
func _shortest_path(source: int, sink: int) -> Dictionary:
	var distance: Array[float] = []
	var previous_edge: Array[int] = []
	var in_queue: Array[bool] = []
	distance.resize(_node_count)
	previous_edge.resize(_node_count)
	in_queue.resize(_node_count)
	distance.fill(INF_COST)
	previous_edge.fill(-1)
	in_queue.fill(false)

	distance[source] = 0.0
	var queue: Array[int] = [source]
	var head: int = 0
	var queued: Dictionary = {source: true}
	var relaxations: int = 0
	var relaxation_cap: int = maxi(64, _node_count * _node_count * 4)

	while head < queue.size():
		var node: int = queue[head]
		head += 1

		if head > 4096 and head * 2 > queue.size():
			queue = queue.slice(head)
			head = 0

		queued.erase(node)

		for edge_index: int in _adjacency[node]:
			var edge: Dictionary = _edges[edge_index]

			if int(edge["capacity"]) - int(edge["flow"]) <= 0:
				continue

			var candidate: float = distance[node] + float(edge["cost"])

			if candidate >= distance[int(edge["to"])] - 0.000000001:
				continue

			distance[int(edge["to"])] = candidate
			previous_edge[int(edge["to"])] = edge_index
			relaxations += 1

			if relaxations > relaxation_cap:
				return {"found": false, "edges": [], "cost": 0.0}


			if not queued.has(int(edge["to"])):
				queued[int(edge["to"])] = true
				queue.append(int(edge["to"]))

	if distance[sink] >= INF_COST * 0.5:
		return {"found": false, "edges": [], "cost": 0.0}

	var path_edges: Array[int] = []
	var cursor: int = sink
	var guard: int = 0

	while cursor != source and guard <= _node_count:
		guard += 1
		var edge_index: int = previous_edge[cursor]

		if edge_index < 0:
			return {"found": false, "edges": [], "cost": 0.0}

		path_edges.append(edge_index)
		cursor = int((_edges[edge_index] as Dictionary)["from"])

	path_edges.reverse()
	return {"found": true, "edges": path_edges, "cost": distance[sink]}


## Debug/diagnostic view of every forward edge.
func describe_edges() -> Array:
	var rows: Array = []

	for index: int in range(0, _edges.size(), 2):
		var edge: Dictionary = _edges[index]
		rows.append({
			"from": int(edge["from"]),
			"to": int(edge["to"]),
			"capacity": int(edge["capacity"]),
			"flow": int(edge["flow"]),
			"cost": float(edge["cost"]),
		})

	return rows
