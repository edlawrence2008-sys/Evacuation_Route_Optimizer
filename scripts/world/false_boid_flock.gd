class_name FalseBoidFlock
extends Node3D

## Hybrid "false boid" flock director.
##
## Flight particles are emitted by separate placeable FalseBoidEmitter nodes
## around the map. This director owns ONE moving leader/attractor; the attractor
## is large enough to pull particles from every emitter into a shared flock that
## can cross the whole level. Perching is handled by promoting a small number of
## real FalseBoid sprite nodes at FalseBoidPerch markers. When a player comes
## near, those nodes flee and free themselves.

const FALSE_BOID_SCRIPT := preload("res://scripts/world/false_boid.gd")

@export_group("Shared Attractor")
## The attractor spans the map so particles emitted by separate placeable
## emitters are pulled into one flock instead of staying at their source.
@export var attractor_radius: float = 600.0
@export var attractor_strength: float = 30.0
## Keep the attractor/flock near the player instead of perches; perching is
## disabled while this is on.
@export var follow_player: bool = false
@export var follow_offset: Vector3 = Vector3(0.0, 5.0, 0.0)

@export_group("Flight")
@export var flight_altitude: float = 5.0
@export var flight_speed: float = 4.0
@export var arrival_distance: float = 1.2
@export var player_group: StringName = &"Player"
@export var perch_group: StringName = &"false_boid_perches"

@export_group("Perching")
@export_range(0, 20, 1) var max_perched_birds: int = 20
@export_range(1, 8, 1) var perch_spawn_batch: int = 2
@export var perch_spawn_interval: float = 0.45
@export var flee_radius: float = 5.5
@export var flee_speed_multiplier: float = 2.0

@export_group("Exploration")
## Probability of choosing a chunk exploration target when perching is also
## possible. Exploration is suppressed automatically once the perch cap is full.
@export_range(0.0, 1.0, 0.01) var explore_chance: float = 0.55
## Target height above the highest block in the chosen chunk.
@export var chunk_clearance_min: float = 10.0
@export var chunk_clearance_max: float = 25.0
@export var explore_dwell_min: float = 1.5
@export var explore_dwell_max: float = 4.0
## Cost removed from a chunk per second after it is explored.
@export var chunk_cost_decay_per_sec: float = 0.12
@export var chunk_scan_interval: float = 2.0
## Small lateral/vertical wobble so leaders do not fly perfectly straight.
@export var leader_wobble: float = 1.4

@export_group("Crowd Control")
## Chance that a leader chooses the densest nearby leader cluster as its next
## target instead of a perch/chunk.
@export_range(0.0, 1.0, 0.01) var hotspot_chance: float = 0.22
@export var hotspot_radius: float = 12.0
## Negative attractor strength used when a leader is in an over-dense cluster.
@export var repel_strength: float = 80.0
@export var repel_duration: float = 1.5

var _leader: Node3D = null
var _attractor: GPUParticlesAttractorSphere3D = null
var _repel_timer: float = 0.0
var _perches: Array[Node] = []
var _perched: Array[Node] = []
var _target_perch: Node3D = null
var _target_position: Vector3 = Vector3.ZERO
var _has_target: bool = false
var _target_is_perch: bool = false
var _explore_dwell: float = 0.0
var _spawn_timer: float = 0.0
var _perch_scan_timer: float = 0.0
var _retreat_timer: float = 0.0
var _full_perch_cooldown: float = 0.0
var _exploration_cost: Dictionary = {} # chunk Vector2i -> cost
var _chunk_decay_accum: float = 0.0
var _chunk_cache: Array[Vector2i] = []
var _chunk_cache_timer: float = 0.0
var _wobble_time: float = 0.0
var _wobble_phase: float = 0.0
var _grid: NavGridMap = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group(&"false_boid_leaders")
	max_perched_birds = clampi(max_perched_birds, 0, 20)
	_rng.randomize()
	_wobble_phase = _rng.randf() * TAU
	_ensure_leader()
	_ensure_attractor()
	_refresh_perches()
	_leader.global_position = global_position + Vector3(0.0, flight_altitude, 0.0)
	_choose_next_target(true)


func _process(delta: float) -> void:
	_wobble_time += delta
	_update_attractor_strength(delta)
	_decay_exploration_costs(delta)
	_update_perches(delta)
	_update_player_reaction(delta)
	_update_leader(delta)
	_update_exploration(delta)
	_update_perching(delta)
	_prune_perched()


func _ensure_leader() -> void:
	_leader = get_node_or_null("Leader") as Node3D

	if _leader == null:
		_leader = Node3D.new()
		_leader.name = "Leader"
		add_child(_leader)


func _ensure_attractor() -> void:
	_attractor = get_node_or_null("Leader/Attractor") as GPUParticlesAttractorSphere3D

	if _attractor == null:
		_attractor = GPUParticlesAttractorSphere3D.new()
		_attractor.name = "Attractor"
		_leader.add_child(_attractor)

	_attractor.radius = attractor_radius
	_attractor.strength = attractor_strength
	_attractor.attenuation = 0.2


## Called by the director when this leader is in an over-dense cluster. The
## attractor temporarily becomes a repulsor, splitting the particle cloud.
func repel_for(duration: float) -> void:
	_repel_timer = maxf(_repel_timer, duration)


func _update_attractor_strength(delta: float) -> void:
	if _attractor == null:
		return

	_repel_timer = maxf(0.0, _repel_timer - delta)
	_attractor.strength = (
		-absf(repel_strength) if _repel_timer > 0.0 else attractor_strength
	)


func _refresh_perches() -> void:
	_perches.clear()

	for node: Node in get_tree().get_nodes_in_group(perch_group):
		if node is Node3D and node.has_method("claim_slot"):
			_perches.append(node)


func _update_perches(delta: float) -> void:
	_perch_scan_timer += delta

	if _perch_scan_timer < 1.0:
		return

	_perch_scan_timer = 0.0
	_refresh_perches()

	if not _has_target:
		_choose_next_target()

	if _target_is_perch and (
		_target_perch == null or not is_instance_valid(_target_perch)
	):
		_choose_next_target(true)


func _update_player_reaction(delta: float) -> void:
	if follow_player:
		return

	var player := _find_player()

	if player == null:
		return

	if _retreat_timer > 0.0:
		_retreat_timer -= delta

	for perch: Node3D in _perches:
		if perch.available_slots() >= perch.capacity:
			continue

		if player.global_position.distance_to(perch.global_position) <= flee_radius:
			for bird: Node in _perched:
				if is_instance_valid(bird) and bird.perch == perch:
					bird.startle()

	# If the flock itself is approached, move to a different perch instead of
	# orbiting the player.
	if _leader.global_position.distance_to(player.global_position) <= flee_radius:
		_retreat_timer = maxf(_retreat_timer, 2.0)
		_choose_next_target(true)


func _update_leader(delta: float) -> void:
	var target: Vector3 = _target_position
	var speed: float = flight_speed

	if follow_player:
		var player := _find_player()

		if player != null:
			target = player.global_position + follow_offset
			speed *= 1.5
	else:
		if _retreat_timer > 0.0:
			target.y += 3.0

		if _retreat_timer > 0.0:
			speed *= flee_speed_multiplier

		if not _target_is_perch and _leader.global_position.distance_to(target) > arrival_distance * 4.0:
			target += Vector3(
				sin(_wobble_time * 0.7 + _wobble_phase) * leader_wobble,
				sin(_wobble_time * 0.9 + _wobble_phase) * leader_wobble * 0.25,
				cos(_wobble_time * 0.6 + _wobble_phase) * leader_wobble
			)

	_leader.global_position = _leader.global_position.move_toward(
		target,
		speed * delta
	)


func _update_perching(delta: float) -> void:
	if follow_player or not _target_is_perch:
		return

	_full_perch_cooldown = maxf(0.0, _full_perch_cooldown - delta)

	if _target_perch == null or not is_instance_valid(_target_perch):
		return

	if _perched.size() >= max_perched_birds:
		return

	if _target_perch.available_slots() <= 0:
		if _full_perch_cooldown <= 0.0:
			_full_perch_cooldown = 0.8
			_choose_next_target(true)

		return

	var player := _find_player()

	if player != null:
		if player.global_position.distance_to(_target_perch.global_position) <= flee_radius:
			if _full_perch_cooldown <= 0.0:
				_full_perch_cooldown = 1.0
				_choose_next_target(true)

			return

	if _leader.global_position.distance_to(_target_position) > arrival_distance:
		return

	_spawn_timer += delta

	if _spawn_timer < perch_spawn_interval:
		return

	_spawn_timer = 0.0
	_spawn_perched_batch()


func _spawn_perched_batch() -> void:
	var global_count: int = get_tree().get_nodes_in_group("false_boid_perched").size()
	var count: int = mini(
		perch_spawn_batch,
		mini(
			max_perched_birds - global_count,
			_target_perch.available_slots()
		)
	)

	for _index: int in range(count):
		if global_count >= max_perched_birds:
			break

		var slot: int = _target_perch.claim_slot()

		if slot < 0:
			break

		var bird: Node3D = FALSE_BOID_SCRIPT.new()
		bird.name = "PerchedBoid%d" % _perched.size()
		bird.flight_speed = flight_speed * 1.25
		var spawn_offset := Vector3(
			_rng.randf_range(-2.2, 2.2),
			_rng.randf_range(-0.6, 0.6),
			_rng.randf_range(-2.2, 2.2)
		)
		add_child(bird)
		bird.configure(
			self,
			_target_perch,
			slot,
			_leader.global_position + spawn_offset,
			_target_perch.slot_position(slot),
			flee_radius,
			player_group
		)
		_perched.append(bird)
		global_count += 1


func _prune_perched() -> void:
	for index: int in range(_perched.size() - 1, -1, -1):
		var bird: Node = _perched[index]

		if bird == null or not is_instance_valid(bird):
			_perched.remove_at(index)


func _choose_target_perch(force_change: bool = false) -> void:
	_refresh_perches()
	var player := _find_player()
	var current: Node3D = _target_perch
	var candidates: Array[Node3D] = []

	for perch: Node3D in _perches:
		if perch == current and not force_change:
			continue

		if perch.available_slots() <= 0:
			continue

		if player != null:
			if player.global_position.distance_to(perch.global_position) <= flee_radius:
				continue

		candidates.append(perch)

	if candidates.is_empty():
		for perch: Node3D in _perches:
			candidates.append(perch)

	if candidates.is_empty():
		_target_perch = null
		_choose_exploration_target()
		return

	_target_perch = candidates[_rng.randi_range(0, candidates.size() - 1)]
	_target_position = (
		_target_perch.global_position
		+ Vector3(0.0, flight_altitude, 0.0)
	)
	_target_is_perch = true
	_has_target = true
	_explore_dwell = 0.0


func _choose_next_target(force_change: bool = false) -> void:
	if _rng.randf() < hotspot_chance and _try_choose_hotspot():
		return

	var can_perch: bool = _perched.size() < max_perched_birds

	if can_perch and _rng.randf() > explore_chance:
		_choose_target_perch(force_change)
	else:
		_choose_exploration_target()


## Sometimes fly toward the densest cluster of leaders. There is no GPU particle
## position readback, so leader clustering is the available bird-density proxy.
func _try_choose_hotspot() -> bool:
	var leaders := get_tree().get_nodes_in_group("false_boid_leaders")

	if leaders.size() < 2:
		return false

	var best: Node3D = null
	var best_count: int = 0

	for candidate: Node in leaders:
		if not (candidate is Node3D):
			continue

		var candidate_position: Vector3 = _leader_position_of(candidate)
		var count: int = 0

		for other: Node in leaders:
			if other == candidate or not (other is Node3D):
				continue

			if _leader_position_of(other).distance_to(candidate_position) <= hotspot_radius:
				count += 1

		if count > best_count:
			best_count = count
			best = candidate as Node3D

	if best == null or best_count < 2:
		# Even when no cluster exists, occasionally visit another leader so the
		# "go toward the flock" behaviour is visible with only two or three
		# emitters.
		var others := leaders.filter(func(candidate: Node) -> bool:
			return candidate != self and candidate is Node3D
		)

		if others.is_empty():
			return false

		best = others[_rng.randi_range(0, others.size() - 1)] as Node3D

	if best == null:
		return false

	_target_position = _leader_position_of(best) + Vector3(
		_rng.randf_range(-2.5, 2.5),
		0.0,
		_rng.randf_range(-2.5, 2.5)
	)
	_target_perch = null
	_target_is_perch = false
	_has_target = true
	_explore_dwell = 0.0
	return true


func _leader_position_of(node: Node) -> Vector3:
	if node.has_method("get_leader_position"):
		return node.get_leader_position()

	if node is Node3D:
		return (node as Node3D).global_position

	return global_position


func _choose_exploration_target() -> void:
	var grid: NavGridMap = _get_grid()

	if grid == null:
		_target_perch = null
		_target_is_perch = false
		_has_target = true
		_target_position = global_position + Vector3(0.0, flight_altitude, 0.0)
		_explore_dwell = 2.0
		return

	var chunks: Array[Vector2i] = _active_chunks(grid)

	if chunks.is_empty():
		_target_perch = null
		_target_is_perch = false
		_has_target = true
		_target_position = global_position + Vector3(0.0, flight_altitude, 0.0)
		_explore_dwell = 2.0
		return

	var total_weight: float = 0.0
	var weights := PackedFloat32Array()
	weights.resize(chunks.size())

	for index: int in range(chunks.size()):
		var cost: float = float(_exploration_cost.get(chunks[index], 0.0))
		var weight: float = 1.0 / (1.0 + cost)
		weights[index] = weight
		total_weight += weight

	var roll: float = _rng.randf() * total_weight
	var chosen: Vector2i = chunks[0]

	for index: int in range(chunks.size()):
		roll -= weights[index]

		if roll <= 0.0:
			chosen = chunks[index]
			break

	var highest: int = grid.get_chunk_highest_block_y(chosen)
	var x: float = float(chosen.x * grid.CHUNK_SIZE) + _rng.randf_range(0.0, float(grid.CHUNK_SIZE))
	var z: float = float(chosen.y * grid.CHUNK_SIZE) + _rng.randf_range(0.0, float(grid.CHUNK_SIZE))
	var y: float = float(highest + 1) + _rng.randf_range(
		chunk_clearance_min,
		maxf(chunk_clearance_min, chunk_clearance_max)
	)
	_target_position = grid.to_global(Vector3(x, y, z))
	_target_perch = null
	_target_is_perch = false
	_has_target = true
	_explore_dwell = 0.0
	_exploration_cost[chosen] = float(_exploration_cost.get(chosen, 0.0)) + 1.0


func _active_chunks(grid: NavGridMap) -> Array[Vector2i]:
	_chunk_cache_timer -= get_process_delta_time()

	if _chunk_cache.is_empty() or _chunk_cache_timer <= 0.0:
		_chunk_cache_timer = chunk_scan_interval

		if grid.has_method("get_active_chunks"):
			_chunk_cache = grid.get_active_chunks()
		else:
			_chunk_cache = grid.get_populated_chunks()

	return _chunk_cache


func _decay_exploration_costs(delta: float) -> void:
	if _exploration_cost.is_empty():
		return

	_chunk_decay_accum += delta

	if _chunk_decay_accum < 0.5:
		return

	var elapsed: float = _chunk_decay_accum
	_chunk_decay_accum = 0.0
	var decay: float = chunk_cost_decay_per_sec * elapsed

	for chunk: Vector2i in _exploration_cost.keys():
		var next_cost: float = float(_exploration_cost[chunk]) - decay

		if next_cost <= 0.0:
			_exploration_cost.erase(chunk)
		else:
			_exploration_cost[chunk] = next_cost


func _update_exploration(delta: float) -> void:
	if follow_player or not _has_target or _target_is_perch:
		return

	if _leader.global_position.distance_to(_target_position) > arrival_distance:
		_explore_dwell = 0.0
		return

	if _explore_dwell <= 0.0:
		_explore_dwell = _rng.randf_range(explore_dwell_min, explore_dwell_max)

	_explore_dwell -= delta

	if _explore_dwell <= 0.0:
		_choose_next_target(true)


func _get_grid() -> NavGridMap:
	if is_instance_valid(_grid):
		return _grid

	_grid = get_tree().get_first_node_in_group("grid_map") as NavGridMap
	return _grid


func _find_player() -> Node3D:
	var players := get_tree().get_nodes_in_group(player_group)

	if players.is_empty():
		return null

	return players[0] as Node3D


## Called by a bird when it frees itself.
func notify_bird_gone(bird: Node) -> void:
	_perched.erase(bird)


## Read-only diagnostics for tests and the results/debug HUD.
func get_leader_position() -> Vector3:
	return _leader.global_position if _leader != null else global_position


func get_flock_state() -> Dictionary:
	return {
		"leader": _leader.global_position if _leader != null else global_position,
		"perched": _perched.size(),
		"max_perched": max_perched_birds,
		"perches": _perches.size(),
		"target": _target_perch.name if _target_perch != null else "",
		"target_position": _target_position,
		"target_is_perch": _target_is_perch,
		"explored_chunks": _exploration_cost.size(),
		"has_target": _has_target,
	}
