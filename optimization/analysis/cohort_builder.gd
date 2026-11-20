class_name CohortBuilder
extends RefCounted

## Groups active agents into spatial cohorts so the assignment search stays
## small. With 600 agents and 4 exits there are 4^600 per-agent assignments;
## a 4 m bucket typically yields 10-40 cohorts.
##
## Cohorts are built from the `npc` population at solve time, not from spawners:
## agents move, so spawner membership stops representing the crowd immediately.
## The builder is deterministic: buckets are ordered by cell and the
## representative nav cell is chosen by a stable tie-break.

const MAX_BUCKET_EXPANSIONS: int = 8
const BUCKET_GROWTH: float = 1.5
const DEFAULT_SPEED: float = 1.34


static func build(
	snapshot: SimulationSnapshot,
	bucket_size: float,
	max_cohorts: int
) -> Array:
	if snapshot == null or snapshot.agents.is_empty():
		return []

	var size: float = maxf(0.5, bucket_size)
	var limit: int = maxi(1, max_cohorts)
	var buckets: Dictionary = {}

	# Merge by coarsening the bucket rather than by running a clustering pass.
	# Coarsening is deterministic and keeps the search space bounded.
	for _attempt: int in range(MAX_BUCKET_EXPANSIONS):
		buckets = _bucketize(snapshot, size)

		if buckets.size() <= limit:
			break

		size *= BUCKET_GROWTH
	# Coarsening alone cannot always reach the cap when clusters are far apart;
	# merge the closest buckets until the search space fits.
	if buckets.size() > limit:
		buckets = _merge_to_limit(buckets, limit)

	return _finalize(buckets)


static func _bucketize(snapshot: SimulationSnapshot, size: float) -> Dictionary:
	var buckets: Dictionary = {}
	var level_height: float = maxf(1.0, snapshot.get_cell_size().y)

	for agent: Dictionary in snapshot.agents:
		if String(agent.get("state", "")) in ["dead", "evacuated"]:
			continue

		var position: Vector3 = agent.get("position", Vector3.ZERO)
		var key := Vector3i(
			floori(position.x / size),
			floori(position.y / level_height),
			floori(position.z / size)
		)
		var bucket: Variant = buckets.get(key)

		if bucket == null:
			bucket = {
				"members": [],
				"cells": [],
				"sum_position": Vector3.ZERO,
				"sum_speed": 0.0,
				"sum_remaining": 0.0,
			}
			buckets[key] = bucket

		var serial: int = int(agent.get("serial", -1))

		if serial < 0:
			continue

		(bucket["members"] as Array).append(serial)
		(bucket["cells"] as Array).append(agent.get("cell", Vector3i.ZERO))
		bucket["sum_position"] = Vector3(bucket["sum_position"]) + position
		bucket["sum_speed"] = float(bucket["sum_speed"]) + float(
			agent.get("desired_speed", DEFAULT_SPEED)
		)
		bucket["sum_remaining"] = float(bucket["sum_remaining"]) + float(
			agent.get("path_remaining", 0.0)
		)

	return buckets


## Deterministic fallback: repeatedly join the two closest bucket centroids
## until the cohort count fits. Used only when far-apart clusters survive every
## coarsening step.
static func _merge_to_limit(buckets: Dictionary, limit: int) -> Dictionary:
	var working: Dictionary = buckets.duplicate(true)

	while working.size() > limit:
		var keys: Array = working.keys()
		keys.sort_custom(
			func(a: Vector3i, b: Vector3i) -> bool:
				return _cell_less(a, b)
		)

		var best_a: Vector3i = keys[0]
		var best_b: Vector3i = keys[1]
		var best_distance: float = INF

		for i: int in range(keys.size()):
			var a: Vector3i = keys[i]
			var centroid_a: Vector3 = _bucket_centroid(working[a])

			for j: int in range(i + 1, keys.size()):
				var b: Vector3i = keys[j]
				var distance: float = centroid_a.distance_to(
					_bucket_centroid(working[b])
				)

				if distance < best_distance - 0.000001:
					best_distance = distance
					best_a = a
					best_b = b

		var target: Dictionary = working[best_a]
		var source: Dictionary = working[best_b]

		(target["members"] as Array).append_array(source["members"])
		(target["cells"] as Array).append_array(source["cells"])
		target["sum_position"] = (
			Vector3(target["sum_position"]) + Vector3(source["sum_position"])
		)
		target["sum_speed"] = (
			float(target["sum_speed"]) + float(source["sum_speed"])
		)
		target["sum_remaining"] = (
			float(target["sum_remaining"]) + float(source["sum_remaining"])
		)
		working.erase(best_b)

	return working


static func _bucket_centroid(bucket: Dictionary) -> Vector3:
	var count: int = (bucket["members"] as Array).size()

	if count <= 0:
		return Vector3.ZERO

	return Vector3(bucket["sum_position"]) / float(count)


static func _finalize(buckets: Dictionary) -> Array:
	var keys: Array = buckets.keys()
	keys.sort_custom(
		func(a: Vector3i, b: Vector3i) -> bool:
			return _cell_less(a, b)
	)

	var cohorts: Array = []

	for index: int in keys.size():
		var key: Vector3i = keys[index]
		var bucket: Dictionary = buckets[key]
		var members: Array = bucket["members"]
		var count: int = members.size()

		if count == 0:
			continue

		var cohort_id: int = cohorts.size()
		var speed_sum: float = float(bucket["sum_speed"])
		var speed: float = speed_sum / float(count)

		cohorts.append({
			"cohort_id": cohort_id,
			"bucket": key,
			"members": members,
			"count": count,
			"centroid": Vector3(bucket["sum_position"]) / float(count),
			"speed": speed if speed > 0.1 else DEFAULT_SPEED,
			"remaining": float(bucket["sum_remaining"]) / float(count),
			"cell": _modal_cell(bucket["cells"]),
		})

	return cohorts


## The nav cell most members of the cohort occupy. Deterministic ties pick the
## lowest cell so two identical snapshots always produce the same cohort.
static func _modal_cell(cells: Array) -> Vector3i:
	var counts: Dictionary = {}

	for value: Variant in cells:
		if not value is Vector3i:
			continue

		var cell: Vector3i = value
		counts[cell] = int(counts.get(cell, 0)) + 1

	var best_cell := Vector3i.ZERO
	var best_count: int = -1

	for cell: Vector3i in counts.keys():
		var count: int = int(counts[cell])

		if count > best_count or (count == best_count and _cell_less(cell, best_cell)):
			best_cell = cell
			best_count = count

	return best_cell


static func _cell_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x

	if a.y != b.y:
		return a.y < b.y

	return a.z < b.z
