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
## Different flock groups get separate offsets around the migration waypoint so
## they do not all converge on the same point.
@export var migration_group_spread: float = 45.0

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

	var group := _leader_group(leader)
	var group_ids: Array = []
	for other: Node in _leaders:
		if not is_instance_valid(other):
			continue
		var other_group := _leader_group(other)
		if not group_ids.has(other_group):
			group_ids.append(other_group)

	var group_index := maxi(group_ids.find(group), 0)
	var angle := TAU * float(group_index) / float(maxi(group_ids.size(), 1))
	var offset := Vector3(cos(angle), 0.0, sin(angle)) * migration_group_spread
	offset += Vector3(
		_rng.randf_range(-6.0, 6.0),
		_rng.randf_range(-2.0, 4.0),
		_rng.randf_range(-6.0, 6.0)
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
	var groups: Dictionary = {} # StringName -> Array[Node]

	for node: Node in emitters:
		if not (node is Node3D):
			continue

		var group := _emitter_group(node)
		if not groups.has(group):
			groups[group] = []
		groups[group].append(node)

	# One visibility layer per flock group. Each group's particles and its
	# leaders' attractors share that layer, so other flocks' attractors cannot
	# drag them across the map into one merged cloud.
	var group_layers: Dictionary = {}
	var layer_index := 0
	for group: StringName in groups.keys():
		group_layers[group] = 1 << (layer_index % 20)
		layer_index += 1

	for group: StringName in groups.keys():
		var layer: int = int(group_layers[group])
		for node: Node in groups[group]:
			if node.has_method("set_flock_layer"):
				node.set_flock_layer(layer)

	# Remove leaders whose source emitter was deleted and any beyond the cap.
	for index in range(_leaders.size() - 1, -1, -1):
		var leader: Node = _leaders[index]
		var source: Node = null

		if is_instance_valid(leader) and leader.has_method("get_source_emitter"):
			source = leader.get_source_emitter()

		if (
			not is_instance_valid(leader)
			or source == null
			or not is_instance_valid(source)
			or not emitters.has(source)
			or index >= MAX_LEADERS
		):
			if is_instance_valid(leader):
				leader.queue_free()
			_leaders.remove_at(index)

	# Each emitter owns one leader. Leaders in the same flock group align and
	# cohere; leaders in other groups only repel/spook.
	for node: Node in emitters:
		if _leaders.size() >= MAX_LEADERS:
			break

		if _leader_for_emitter(node) != null:
			continue

		var emitter := node as Node3D
		if emitter == null:
			continue

		var group := _emitter_group(emitter)
		var layer: int = int(group_layers.get(group, 1))
		var leader: Node3D = LEADER_SCRIPT.new()
		leader.name = "FalseBoidLeader%d" % _leaders.size()
		leader.position = to_local(emitter.global_position)

		if leader.has_method("setup_from_emitter"):
			leader.setup_from_emitter(emitter, layer)

		add_child(leader)
		_leaders.append(leader)

		if _migration_active:
			_begin_leader_migration(leader)

	for leader: Node in _leaders:
		if not is_instance_valid(leader):
			continue

		var source: Node = null
		if leader.has_method("get_source_emitter"):
			source = leader.get_source_emitter()

		var group := _emitter_group(source) if source != null else &"default"

		if leader.has_method("set_flock_group"):
			leader.set_flock_group(group)

		if leader.has_method("set_flock_layer"):
			leader.set_flock_layer(int(group_layers.get(group, 1)))

		if leader.has_method("refresh_from_emitter"):
			leader.refresh_from_emitter()


func _leader_for_emitter(emitter: Node) -> Node:
	for leader: Node in _leaders:
		if (
			is_instance_valid(leader)
			and leader.has_method("get_source_emitter")
			and leader.get_source_emitter() == emitter
		):
			return leader
	return null


func _emitter_group(node: Node) -> StringName:
	if node.has_method("get_flock_group"):
		return node.get_flock_group()

	if "flock_group" in node:
		var text := String(node.get("flock_group")).strip_edges()
		return StringName(text) if not text.is_empty() else &"default"

	return &"default"


func _update_crowding() -> void:
	var leaders := _leaders
	var count: int = leaders.size()

	if count < 2:
		return

	for index: int in range(count):
		var leader: Node = leaders[index]

		if not is_instance_valid(leader):
			continue

		var near: int = 0
		var leader_group := _leader_group(leader)
		var leader_position: Vector3 = (
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
			var distance: float = other_position.distance_to(leader_position)

			if _leader_group(other) == leader_group:
				if distance <= crowd_radius:
					near += 1
				continue

			# Different flocks spook each other: both attractors flip to
			# repulsors for a moment so the clouds visibly split apart.
			var spook_radius := 18.0
			if leader.has_method("get_inter_flock_spook_radius"):
				spook_radius = float(leader.get_inter_flock_spook_radius())

			if distance > spook_radius:
				continue

			var spook_duration := crowd_repel_duration
			if leader.has_method("get_inter_flock_spook_duration"):
				spook_duration = float(leader.get_inter_flock_spook_duration())

			if leader.has_method("repel_for"):
				leader.repel_for(spook_duration)

			if other.has_method("repel_for"):
				other.repel_for(spook_duration)

		if near >= crowd_threshold - 1 and leader.has_method("repel_for"):
			leader.repel_for(crowd_repel_duration)


func _leader_group(node: Node) -> StringName:
	if node.has_method("get_flock_group"):
		return node.get_flock_group()
	return &"default"


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


## Average heading of one flock group; emitters mirror their own cloud with it.
func get_cloud_direction_for_group(group: StringName) -> Vector3:
	var total := Vector3.ZERO
	var count: int = 0

	for leader: Node in _leaders:
		if not is_instance_valid(leader) or not leader.has_method("get_leader_velocity"):
			continue

		if _leader_group(leader) != group:
			continue

		total += leader.get_leader_velocity()
		count += 1

	if count == 0 or total.length_squared() < 0.0001:
		return Vector3.ZERO

	return total.normalized()


func get_director_state() -> Dictionary:
	var group_ids: Array = []
	for leader: Node in _leaders:
		if not is_instance_valid(leader):
			continue
		var group := _leader_group(leader)
		if not group_ids.has(group):
			group_ids.append(group)

	return {
		"emitters": get_tree().get_nodes_in_group(EMITTER_GROUP).size(),
		"leaders": _leaders.size(),
		"groups": group_ids.size(),
		"group_names": group_ids,
		"max_leaders": MAX_LEADERS,
		"migrating": _migration_active,
		"migration_target": _migration_target,
		"migration_timer": _migration_timer,
		"migration_duration": _migration_duration,
	}
