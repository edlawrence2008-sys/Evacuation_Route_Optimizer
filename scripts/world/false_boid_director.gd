class_name FalseBoidDirector
extends Node3D

## Owns the map-wide false-boid state: one FalseBoidFlock leader per placed
## emitter, capped at MAX_LEADERS.
##
## Emitters only emit particles. Leaders own the attractors, perch behaviour and
## chunk exploration. The old player-following ground collision box has been
## removed: the cloud now flies high enough that it does not need to be scooped
## away from the terrain, and the box made birds visibly snap upward as the
## player walked around.

const LEADER_SCRIPT := preload("res://scripts/world/false_boid_flock.gd")
const MAX_LEADERS: int = 10
const EMITTER_GROUP := &"false_boid_emitters"

@export var crowd_radius: float = 5.0
@export_range(1, 10, 1) var crowd_threshold: int = 3
@export var crowd_repel_duration: float = 1.5

@export_group("Migration")
## Periodically send the whole flock to a far chunk so the birds traverse the
## map instead of orbiting one local area forever.
@export var migration_enabled: bool = true
@export var migration_interval_min: float = 30.0
@export var migration_interval_max: float = 55.0
@export var migration_duration_min: float = 16.0
@export var migration_duration_max: float = 26.0
## Preferred minimum travel distance for a migration waypoint. On small maps the
## farthest available chunk is used even when it is closer than this.
@export var migration_min_distance: float = 42.0
@export var migration_clearance_min: float = 20.0
@export var migration_clearance_max: float = 36.0
## Random score bonus when choosing the far chunk, so the flock does not always
## use the exact same corner.
@export var migration_distance_jitter: float = 10.0

var _leaders: Array[Node] = []
var _sync_timer: float = 0.0
var _migration_active: bool = false
var _migration_timer: float = 0.0
var _migration_duration: float = 0.0
var _migration_target: Vector3 = Vector3.INF
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group(&"false_boid_director")
	_rng.randomize()
	_migration_timer = _rng.randf_range(10.0, 20.0)
	set_process(true)


func _process(delta: float) -> void:
	_update_migration(delta)
	_sync_timer += delta

	if _sync_timer < 0.5:
		return

	_sync_timer = 0.0
	_sync_leaders()
	_update_crowding()


func _update_migration(delta: float) -> void:
	if not migration_enabled:
		if _migration_active:
			_end_migration()

		return

	if _migration_active:
		_migration_duration -= delta

		if _migration_duration <= 0.0:
			_end_migration()

		return

	_migration_timer -= delta

	if _migration_timer <= 0.0:
		_start_migration()


func _start_migration() -> void:
	if _leaders.is_empty():
		_migration_timer = 5.0
		return

	var target: Vector3 = _pick_migration_target()

	if target == Vector3.INF:
		_migration_timer = 8.0
		return

	_migration_target = target
	_migration_active = true
	_migration_duration = _rng.randf_range(
		migration_duration_min,
		maxf(migration_duration_min, migration_duration_max)
	)

	for leader: Node in _leaders:
		_begin_leader_migration(leader)

	_migration_timer = _rng.randf_range(
		migration_interval_min,
		maxf(migration_interval_min, migration_interval_max)
	)


func _end_migration() -> void:
	_migration_active = false
	_migration_target = Vector3.INF

	for leader: Node in _leaders:
		if is_instance_valid(leader) and leader.has_method("end_migration"):
			leader.end_migration()


func _begin_leader_migration(leader: Node) -> void:
	if not is_instance_valid(leader) or not leader.has_method("begin_migration"):
		return

	var offset := Vector3(
		_rng.randf_range(-9.0, 9.0),
		_rng.randf_range(-2.0, 4.0),
		_rng.randf_range(-9.0, 9.0)
	)
	leader.begin_migration(_migration_target + offset)


## Pick the active chunk with the highest distance score from the flock's
## current centroid. `migration_min_distance` only biases the choice; on a small
## map the farthest available chunk still wins.
func _pick_migration_target() -> Vector3:
	var grid := get_tree().get_first_node_in_group("grid_map") as NavGridMap

	if grid == null:
		return Vector3.INF

	var chunks: Array[Vector2i] = []

	if grid.has_method("get_active_chunks"):
		chunks = grid.get_active_chunks()
	else:
		chunks = grid.get_populated_chunks()

	if chunks.is_empty():
		return Vector3.INF

	var centroid := _leader_centroid()
	var best := Vector3.INF
	var best_score: float = -INF

	for chunk: Vector2i in chunks:
		var highest: int = grid.get_chunk_highest_block_y(chunk)
		var x: float = float(chunk.x * grid.CHUNK_SIZE) + float(grid.CHUNK_SIZE) * 0.5
		var z: float = float(chunk.y * grid.CHUNK_SIZE) + float(grid.CHUNK_SIZE) * 0.5
		var y: float = float(highest + 1) + _rng.randf_range(
			migration_clearance_min,
			maxf(migration_clearance_min, migration_clearance_max)
		)
		var point: Vector3 = grid.to_global(Vector3(x, y, z))
		var distance: float = Vector2(
			point.x - centroid.x,
			point.z - centroid.z
		).length()
		var score: float = distance + _rng.randf_range(0.0, migration_distance_jitter)

		if distance < migration_min_distance:
			score *= 0.5

		if score > best_score:
			best_score = score
			best = point

	return best


func _leader_centroid() -> Vector3:
	var total := Vector3.ZERO
	var count: int = 0

	for leader: Node in _leaders:
		if not is_instance_valid(leader):
			continue

		if leader.has_method("get_leader_position"):
			total += leader.get_leader_position()
			count += 1
		elif leader is Node3D:
			total += (leader as Node3D).global_position
			count += 1

	return total / float(maxi(count, 1))


func _sync_leaders() -> void:
	var emitters := get_tree().get_nodes_in_group(EMITTER_GROUP)
	var desired: int = mini(emitters.size(), MAX_LEADERS)

	while _leaders.size() > desired:
		var extra: Node = _leaders.pop_back()
		extra.queue_free()

	while _leaders.size() < desired:
		var index: int = _leaders.size()
		var emitter: Node3D = emitters[index] as Node3D if index < emitters.size() else null
		var leader: Node3D = LEADER_SCRIPT.new()
		leader.name = "FalseBoidLeader%d" % index

		if emitter != null:
			leader.position = to_local(emitter.global_position)

		add_child(leader)
		_leaders.append(leader)

		if _migration_active:
			_begin_leader_migration(leader)


func _update_crowding() -> void:
	var leaders := _leaders
	var count: int = leaders.size()

	if count < crowd_threshold:
		return

	for index: int in range(count):
		var leader: Node = leaders[index]

		if not is_instance_valid(leader):
			continue

		var near: int = 0
		var position: Vector3 = (
			leader.get_leader_position()
			if leader.has_method("get_leader_position")
			else (leader as Node3D).global_position
		)

		for other_index: int in range(count):
			if other_index == index:
				continue

			var other: Node = leaders[other_index]

			if not is_instance_valid(other):
				continue

			var other_position: Vector3 = (
				other.get_leader_position()
				if other.has_method("get_leader_position")
				else (other as Node3D).global_position
			)

			if other_position.distance_to(position) <= crowd_radius:
				near += 1

		if near >= crowd_threshold - 1 and leader.has_method("repel_for"):
			leader.repel_for(crowd_repel_duration)


func get_leader_count() -> int:
	return _leaders.size()


func get_leaders() -> Array[Node]:
	return _leaders


## Average heading of the leader flock; used by emitters to mirror the whole
## particle cloud towards the direction it is travelling.
func get_cloud_direction() -> Vector3:
	var total := Vector3.ZERO
	var count: int = 0

	for leader: Node in _leaders:
		if not is_instance_valid(leader) or not leader.has_method("get_leader_velocity"):
			continue

		total += leader.get_leader_velocity()
		count += 1

	if count == 0 or total.length_squared() < 0.0001:
		return Vector3.ZERO

	return total.normalized()


func get_director_state() -> Dictionary:
	return {
		"emitters": get_tree().get_nodes_in_group(EMITTER_GROUP).size(),
		"leaders": _leaders.size(),
		"max_leaders": MAX_LEADERS,
		"migrating": _migration_active,
		"migration_target": _migration_target,
		"migration_timer": _migration_timer,
		"migration_duration": _migration_duration,
	}
