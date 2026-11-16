class_name FalseBoidFlock
extends Node3D

## Hybrid "false boid" flock director.
##
## Flight particles are emitted by separate placeable FalseBoidEmitter nodes
## around the map. This director owns ONE moving leader/attractor that gathers
## them into a shared flock. The leader is a real boid: it always has a forward
## speed, steers with acceleration, and orbits its target instead of stopping on
## it. Perching is handled by promoting a small number of real FalseBoid sprite
## nodes at FalseBoidPerch markers. Promoted birds spawn from, and return to, a
## sampled dense point in the particle cloud so the promotion transition is
## hidden; they also leave the perch on their own after a while.

const FALSE_BOID_SCRIPT := preload("res://scripts/world/false_boid.gd")
const BOID_TEXTURE := preload("res://textures/particles/Boid.png")
const EMITTER_GROUP := &"false_boid_emitters"
const LEADER_GROUP := &"false_boid_leaders"
const CLOUD_SAMPLE_COUNT: int = 28

@export_group("Shared Attractor")
## Radius and strength are deliberately much smaller than the old map-scale
## attractor. A huge, strong attractor crushed every particle into a tight ball
## under the leader and made the whole flock read as a hovering UFO.
@export var attractor_radius: float = 180.0
@export var attractor_strength: float = 12.0
@export var attractor_attenuation: float = 0.6
## Keep the flock near the player instead of perches; perching is disabled
## while this is on.
@export var follow_player: bool = false
@export var follow_offset: Vector3 = Vector3(0.0, 9.0, 0.0)

@export_group("Boid Flight")
@export var flight_altitude: float = 9.0
## Cruise speed of the leader. It never falls below min_flight_speed, so the
## flock keeps travelling like a plane rather than parking mid-air.
@export var flight_speed: float = 7.5
@export var min_flight_speed: float = 5.0
@export var max_flight_speed: float = 12.0
## Acceleration available for steering, m/s².
@export var steer_strength: float = 15.0
@export var arrival_distance: float = 3.0
## Leaders circle their target at this radius instead of arriving and stopping.
@export var loiter_radius_min: float = 5.0
@export var loiter_radius_max: float = 12.0
## Leaders are not allowed to dip below terrain + this clearance.
@export var min_ground_clearance: float = 9.0
@export var player_group: StringName = &"Player"
@export var perch_group: StringName = &"false_boid_perches"

@export_group("Boid Flocking")
@export var separation_radius: float = 7.0
@export_range(0.0, 4.0, 0.01) var separation_weight: float = 1.1
@export var alignment_radius: float = 18.0
@export_range(0.0, 4.0, 0.01) var alignment_weight: float = 0.45
@export var cohesion_radius: float = 26.0
@export_range(0.0, 4.0, 0.01) var cohesion_weight: float = 0.3

@export_group("Perching")
@export_range(0, 20, 1) var max_perched_birds: int = 20
@export_range(1, 8, 1) var perch_spawn_batch: int = 2
@export var perch_spawn_interval: float = 0.45
## How long the flock circles a perch before moving on. The birds that remain
## behind decide for themselves when to leave.
@export var perch_loiter_time_min: float = 6.0
@export var perch_loiter_time_max: float = 11.0
@export var flee_radius: float = 5.5
@export var flee_speed_multiplier: float = 2.0

@export_group("Leader Visual")
## The leader is a real bird too; this is the size of its billboard sprite.
@export var leader_sprite_pixel_size: float = 0.07
@export var leader_wing_fps: float = 15.0
## Vertical bob of the leader's visual sprite, metres.
@export var leader_sprite_bob: float = 0.1

@export_group("Exploration")
## Probability of choosing a chunk exploration target when perching is also
## possible. Exploration is suppressed automatically once the perch cap is full.
@export_range(0.0, 1.0, 0.01) var explore_chance: float = 0.55
## Target height above the highest block in the chosen chunk.
@export var chunk_clearance_min: float = 18.0
@export var chunk_clearance_max: float = 35.0
@export var explore_dwell_min: float = 4.0
@export var explore_dwell_max: float = 9.0
## Cost removed from a chunk per second after it is explored.
@export var chunk_cost_decay_per_sec: float = 0.12
@export var chunk_scan_interval: float = 2.0
## Small lateral/vertical wobble so leaders do not fly perfectly straight.
@export var leader_wobble: float = 2.0

@export_group("Migration")
## While migrating, the leader's attractor grows and strengthens so the emitted
## cloud is dragged across the map instead of being left behind at the emitters.
@export var migration_attractor_radius_mult: float = 2.2
@export var migration_attractor_strength_mult: float = 1.6
## Time spent circling the migration waypoint before the flock moves on / ends.
@export var migration_loiter_time: float = 3.0

@export_group("Crowd Control")
## Chance that a leader chooses the densest nearby leader cluster as its next
## target instead of a perch/chunk.
@export_range(0.0, 1.0, 0.01) var hotspot_chance: float = 0.22
@export var hotspot_radius: float = 18.0
## Negative attractor strength used when a leader is in an over-dense cluster.
@export var repel_strength: float = 25.0
@export var repel_duration: float = 1.5

var _leader: Node3D = null
var _leader_sprite: Sprite3D = null
var _leader_frame_time: float = 0.0
var _attractor: GPUParticlesAttractorSphere3D = null
var _velocity: Vector3 = Vector3.ZERO
var _repel_timer: float = 0.0
var _perches: Array[Node] = []
var _perched: Array[Node] = []
var _target_perch: Node3D = null
var _target_position: Vector3 = Vector3.ZERO
var _has_target: bool = false
var _target_is_perch: bool = false
var _migrating: bool = false
var _migration_target: Vector3 = Vector3.ZERO
var _is_loitering: bool = false
var _loiter_center: Vector3 = Vector3.ZERO
var _loiter_radius: float = 4.0
var _loiter_sign: float = 1.0
var _loiter_timer: float = 0.0
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
var _terrain_floor_y: float = 0.0
var _terrain_timer: float = 0.0
var _grid: NavGridMap = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group(LEADER_GROUP)
	max_perched_birds = clampi(max_perched_birds, 0, 20)
	_rng.randomize()
	_wobble_phase = _rng.randf() * TAU
	_ensure_leader()
	_ensure_leader_sprite()
	_ensure_attractor()
	_refresh_perches()
	_leader.global_position = global_position + Vector3(0.0, flight_altitude, 0.0)
	_choose_next_target(true)
	_velocity = (_target_position - _leader.global_position).normalized() * flight_speed


func _process(delta: float) -> void:
	_wobble_time += delta
	_retreat_timer = maxf(0.0, _retreat_timer - delta)
	_update_attractor_strength(delta)
	_decay_exploration_costs(delta)
	_update_terrain_floor(delta)
	_update_perches(delta)
	_update_player_reaction(delta)
	_update_leader(delta)
	_update_leader_sprite(delta)
	_update_loiter(delta)
	_update_perching(delta)
	_prune_perched()


func _ensure_leader() -> void:
	_leader = get_node_or_null("Leader") as Node3D

	if _leader == null:
		_leader = Node3D.new()
		_leader.name = "Leader"
		add_child(_leader)


## The leader is an actual bird in the flock too, not just an invisible force.
func _ensure_leader_sprite() -> void:
	_leader_sprite = _leader.get_node_or_null("Sprite") as Sprite3D

	if _leader_sprite == null:
		_leader_sprite = Sprite3D.new()
		_leader_sprite.name = "Sprite"
		_leader.add_child(_leader_sprite)

	_leader_sprite.texture = BOID_TEXTURE
	_leader_sprite.hframes = 3
	_leader_sprite.frame = 0
	_leader_sprite.pixel_size = leader_sprite_pixel_size
	_leader_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Unshaded keeps the silhouette dark regardless of time of day. A shaded
	# sprite picks up enough light at noon/day-cycle peaks to wash out.
	_leader_sprite.shaded = false
	_leader_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	_leader_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_leader_sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _update_leader_sprite(delta: float) -> void:
	if _leader_sprite == null:
		return

	_leader_frame_time += delta

	if _leader_frame_time >= 1.0 / maxf(leader_wing_fps, 0.1):
		_leader_frame_time = 0.0
		_leader_sprite.frame = (_leader_sprite.frame + 1) % 3

	_leader_sprite.position.y = sin(_wobble_time * 3.2 + _wobble_phase) * leader_sprite_bob

	var camera := get_viewport().get_camera_3d()

	if camera == null or _velocity.length_squared() < 0.01:
		return

	var side: float = _velocity.normalized().dot(camera.global_transform.basis.x)

	if absf(side) > 0.08:
		_leader_sprite.flip_h = side > 0.0


func _ensure_attractor() -> void:
	_attractor = get_node_or_null("Leader/Attractor") as GPUParticlesAttractorSphere3D

	if _attractor == null:
		_attractor = GPUParticlesAttractorSphere3D.new()
		_attractor.name = "Attractor"
		_leader.add_child(_attractor)

	_attractor.radius = attractor_radius
	_attractor.strength = attractor_strength
	_attractor.attenuation = attractor_attenuation


## Called by the director when this leader is in an over-dense cluster. The
## attractor temporarily becomes a repulsor, splitting the particle cloud.
func repel_for(duration: float) -> void:
	_repel_timer = maxf(_repel_timer, duration)


## Called by the director when the whole flock should cross the map. The leader
## drops whatever local target it had and follows the migration waypoint.
func begin_migration(target: Vector3) -> void:
	_migrating = true
	_migration_target = target
	_target_position = target
	_target_perch = null
	_target_is_perch = false
	_has_target = true
	_is_loitering = false
	_loiter_timer = 0.0


## Called when the migration window ends; the leader picks a normal local target
## again (perch / chunk / hotspot).
func end_migration() -> void:
	if not _migrating:
		return

	_migrating = false
	_is_loitering = false
	_choose_next_target(true)


func _update_attractor_strength(delta: float) -> void:
	if _attractor == null:
		return

	_repel_timer = maxf(0.0, _repel_timer - delta)
	var radius_mult: float = migration_attractor_radius_mult if _migrating else 1.0
	var strength_mult: float = migration_attractor_strength_mult if _migrating else 1.0
	_attractor.radius = attractor_radius * radius_mult
	_attractor.strength = (
		-absf(repel_strength)
		if _repel_timer > 0.0
		else attractor_strength * strength_mult
	)


func _refresh_perches() -> void:
	_perches.clear()

	for node: Node in get_tree().get_nodes_in_group(perch_group):
		if is_instance_valid(node) and node is Node3D and node.has_method("claim_slot"):
			_perches.append(node)


## Placeable perches can be deleted between the 1 Hz refresh scans. A freed
## Object reference invalidates typed loop variables in GDScript, so strip them
## out before any typed `for perch: Node3D in _perches` loop.
func _prune_perches() -> void:
	for index: int in range(_perches.size() - 1, -1, -1):
		var entry: Variant = _perches[index]

		if entry == null or not is_instance_valid(entry):
			_perches.remove_at(index)


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


func _update_player_reaction(_delta: float) -> void:
	if follow_player:
		return

	_prune_perches()

	var player := _find_player()

	if player == null:
		return

	for perch: Node3D in _perches:
		if not is_instance_valid(perch):
			continue

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


## Boid steering. The leader has a persistent velocity and bounded acceleration;
## it is never moved directly towards a point and never comes to rest.
func _update_leader(delta: float) -> void:
	if follow_player:
		_is_loitering = false

	var target: Vector3 = _target_position
	var cruise: float = flight_speed

	if follow_player:
		var player := _find_player()

		if player != null:
			target = player.global_position + follow_offset
			cruise *= 1.35
	elif _retreat_timer > 0.0:
		target.y += 4.0
		cruise *= flee_speed_multiplier

	var floor_y: float = _terrain_floor_y + min_ground_clearance

	if target.y < floor_y:
		target.y = floor_y

	if _leader.global_position.y < floor_y:
		_leader.global_position.y = floor_y

	var position_now: Vector3 = _leader.global_position
	var to_target: Vector3 = target - position_now
	var distance: float = to_target.length()
	var trigger: float = loiter_radius_max + arrival_distance

	if not _is_loitering:
		if distance <= trigger:
			_begin_loiter(target)
		elif not follow_player and distance > trigger * 3.0:
			# Small lateral/vertical wobble while travelling so the approach is
			# not a perfectly straight line. Applied before aiming.
			target += Vector3(
				sin(_wobble_time * 0.7 + _wobble_phase) * leader_wobble,
				sin(_wobble_time * 0.9 + _wobble_phase) * leader_wobble * 0.35,
				cos(_wobble_time * 0.6 + _wobble_phase) * leader_wobble
			)
			to_target = target - position_now
			distance = to_target.length()

	var desired: Vector3

	if _is_loitering:
		desired = _loiter_velocity(position_now, cruise)
	elif distance > 0.001:
		var approach_speed: float = cruise * clampf(
			distance / maxf(loiter_radius_max * 4.0, 0.001),
			0.75,
			1.0
		)
		desired = to_target.normalized() * approach_speed
	else:
		desired = _velocity.normalized() * cruise

	_steer_towards(desired, delta)
	_apply_flock_forces(delta)
	_clamp_velocity()
	_leader.global_position = position_now + _velocity * delta

	if _leader.global_position.y < floor_y:
		_leader.global_position.y = floor_y

		if _velocity.y < 0.0:
			_velocity.y = 0.0


func _steer_towards(desired_velocity: Vector3, delta: float) -> void:
	var steering: Vector3 = desired_velocity - _velocity
	_velocity += steering.limit_length(steer_strength) * delta


## Separation / alignment / cohesion against the other leaders. Weights are low
## on purpose: the flock should drift together, not collapse into one point.
func _apply_flock_forces(delta: float) -> void:
	var leaders := get_tree().get_nodes_in_group(LEADER_GROUP)

	if leaders.size() < 2:
		return

	var position_now: Vector3 = _leader.global_position
	var separation := Vector3.ZERO
	var alignment := Vector3.ZERO
	var cohesion := Vector3.ZERO
	var separation_count: int = 0
	var alignment_count: int = 0
	var cohesion_count: int = 0

	for node: Node in leaders:
		if node == self or not (node is Node3D):
			continue

		var other_position: Vector3 = _leader_position_of(node)
		var offset: Vector3 = position_now - other_position
		var distance: float = offset.length()

		if distance < separation_radius:
			if distance < 0.01:
				offset = Vector3.RIGHT
				distance = 0.01
			separation += (offset / distance) * (1.0 - distance / separation_radius)
			separation_count += 1

		if distance < alignment_radius:
			if node.has_method("get_leader_velocity"):
				alignment += node.get_leader_velocity()
				alignment_count += 1

		if distance < cohesion_radius:
			cohesion += other_position
			cohesion_count += 1

	var acceleration := Vector3.ZERO

	if separation_count > 0:
		acceleration += separation.normalized() * flight_speed * separation_weight

	if alignment_count > 0:
		var average: Vector3 = alignment / float(alignment_count)

		if average.length_squared() > 0.01:
			acceleration += (
				average.normalized() * flight_speed - _velocity
			) * alignment_weight

	if cohesion_count > 0:
		var center: Vector3 = cohesion / float(cohesion_count)
		var towards: Vector3 = center - position_now

		if towards.length_squared() > 0.01:
			acceleration += towards.normalized() * flight_speed * cohesion_weight

	if acceleration.length_squared() > 0.001:
		_velocity += acceleration.limit_length(steer_strength) * delta


func _clamp_velocity() -> void:
	var speed: float = _velocity.length()

	if speed < 0.001:
		_velocity = Vector3.FORWARD * flight_speed
		return

	if speed > max_flight_speed:
		_velocity = _velocity * (max_flight_speed / speed)
	elif speed < min_flight_speed:
		_velocity = _velocity * (min_flight_speed / speed)


func _begin_loiter(center: Vector3) -> void:
	_is_loitering = true
	_loiter_center = center
	_loiter_radius = _rng.randf_range(loiter_radius_min, loiter_radius_max)
	_loiter_sign = 1.0 if _rng.randf() < 0.5 else -1.0

	if _migrating:
		_loiter_timer = migration_loiter_time
	elif _target_is_perch:
		_loiter_timer = _rng.randf_range(
			perch_loiter_time_min,
			perch_loiter_time_max
		)
	else:
		_loiter_timer = _rng.randf_range(explore_dwell_min, explore_dwell_max)


## Tangent + radial correction + gentle altitude hold: a banked circle rather
## than a stop.
func _loiter_velocity(position_now: Vector3, cruise: float) -> Vector3:
	var radial: Vector3 = position_now - _loiter_center
	radial.y = 0.0

	if radial.length_squared() < 0.01:
		radial = Vector3.FORWARD

	var outward: Vector3 = radial.normalized()
	var tangent := Vector3(-outward.z, 0.0, outward.x) * _loiter_sign
	var radius_error: float = _loiter_radius - radial.length()
	var correction: Vector3 = outward * clampf(
		radius_error * 0.7,
		-cruise,
		cruise
	)
	var vertical: float = (
		clampf(_loiter_center.y - position_now.y, -8.0, 8.0) * 0.6
		+ sin(_wobble_time * 0.9 + _wobble_phase) * 1.2
	)

	return (tangent * cruise + correction + Vector3.UP * vertical).limit_length(
		cruise * 1.2
	)


func _update_loiter(delta: float) -> void:
	if not _is_loitering:
		return

	_loiter_timer -= delta

	if _loiter_timer > 0.0:
		return

	if _migrating:
		# Keep the flock circling the migration area until the director ends
		# the migration window.
		_loiter_timer = migration_loiter_time
	else:
		_choose_next_target(true)


func _update_terrain_floor(delta: float) -> void:
	_terrain_timer -= delta

	if _terrain_timer > 0.0:
		return

	_terrain_timer = 0.5
	var grid: NavGridMap = _get_grid()

	if grid == null:
		return

	var local: Vector3 = grid.to_local(_leader.global_position)
	var chunk := Vector2i(
		floori(local.x / float(grid.CHUNK_SIZE)),
		floori(local.z / float(grid.CHUNK_SIZE))
	)
	var highest: int = grid.get_chunk_highest_block_y(chunk)
	_terrain_floor_y = grid.to_global(
		Vector3(0.0, float(highest + 1), 0.0)
	).y


func _update_perching(delta: float) -> void:
	if follow_player or _migrating or not _target_is_perch or not _is_loitering:
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

	# Birds are dropped while the flock circles the perch, not only when the
	# leader is exactly on top of it. Only the horizontal offset matters: the
	# flock circles above the perch and the new birds glide down to it.
	var flat_distance: float = Vector2(
		_leader.global_position.x - _target_position.x,
		_leader.global_position.z - _target_position.z
	).length()

	if flat_distance > _loiter_radius + arrival_distance + 3.0:
		return

	_spawn_timer += delta

	if _spawn_timer < perch_spawn_interval:
		return

	_spawn_timer = 0.0
	_spawn_perched_batch()


func _spawn_perched_batch() -> void:
	if _target_perch == null or not is_instance_valid(_target_perch):
		return

	var global_count: int = get_tree().get_nodes_in_group("false_boid_perched").size()
	var count: int = mini(
		perch_spawn_batch,
		mini(
			max_perched_birds - global_count,
			_target_perch.available_slots()
		)
	)

	if count <= 0:
		_choose_next_target(true)
		return

	for _index: int in range(count):
		if global_count >= max_perched_birds:
			break

		var slot: int = _target_perch.claim_slot()

		if slot < 0:
			break

		# Spawn inside a dense part of the particle cloud, never at the leader
		# point itself. The sprite fades/scales in there so the promotion is
		# hidden by the surrounding birds.
		var spawn_position: Vector3 = find_cloud_hideout(_leader.global_position, 18.0)
		var bird: Node3D = FALSE_BOID_SCRIPT.new()
		bird.name = "PerchedBoid%d" % _perched.size()
		bird.flight_speed = maxf(flight_speed * 1.6, 10.0)
		add_child(bird)
		bird.configure(
			self,
			_target_perch,
			slot,
			spawn_position,
			_target_perch.slot_position(slot),
			flee_radius,
			player_group,
			_velocity
		)
		_perched.append(bird)
		global_count += 1

	if _target_perch.available_slots() <= 0 or global_count >= max_perched_birds:
		_choose_next_target(true)


func _prune_perched() -> void:
	for index: int in range(_perched.size() - 1, -1, -1):
		var bird: Node = _perched[index]

		if bird == null or not is_instance_valid(bird):
			_perched.remove_at(index)


func _choose_target_perch(force_change: bool = false) -> void:
	_refresh_perches()
	_prune_perches()
	var player := _find_player()
	var current: Node3D = _target_perch
	var candidates: Array[Node3D] = []

	for perch: Node3D in _perches:
		if not is_instance_valid(perch):
			continue

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
			if is_instance_valid(perch):
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
	_is_loitering = false


func _choose_next_target(force_change: bool = false) -> void:
	if _migrating:
		# The director owns the target for the duration of a migration.
		_target_perch = null
		_target_is_perch = false
		_target_position = _migration_target
		_has_target = true
		_is_loitering = false
		return

	if _rng.randf() < hotspot_chance and _try_choose_hotspot():
		_is_loitering = false
		return

	var can_perch: bool = _perched.size() < max_perched_birds

	if can_perch and _rng.randf() > explore_chance:
		_choose_target_perch(force_change)
	else:
		_choose_exploration_target()

	_is_loitering = false


## Sometimes fly toward the densest cluster of leaders. There is no GPU particle
## position readback, so leader clustering is the available bird-density proxy.
func _try_choose_hotspot() -> bool:
	var leaders := get_tree().get_nodes_in_group(LEADER_GROUP)

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
		return

	var chunks: Array[Vector2i] = _active_chunks(grid)

	if chunks.is_empty():
		_target_perch = null
		_target_is_perch = false
		_has_target = true
		_target_position = global_position + Vector3(0.0, flight_altitude, 0.0)
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


# ---------------------------------------------------------------------------
# Particle-cloud density
# ---------------------------------------------------------------------------
#
# GPU particle positions cannot be read back, so density is modelled from the
# things that actually create and gather the cloud: the emitters (sources) and
# every leader's attractor (sinks). Promoted birds sample this field to appear
# from, and disappear into, a dense part of the cloud instead of popping in and
# out at the leader point.

func _cloud_sources() -> Array[Dictionary]:
	var sources: Array[Dictionary] = []

	if _leader != null:
		sources.append({
			"position": _leader.global_position,
			"weight": 2.6,
			"spread": maxf(attractor_radius * 0.18, 1.0),
		})

	for node: Node in get_tree().get_nodes_in_group(EMITTER_GROUP):
		if not (node is Node3D):
			continue

		var amount: float = 500.0

		if node.has_method("get_emitter_state"):
			amount = float(node.get_emitter_state().get("particles", 500))

		sources.append({
			"position": (node as Node3D).global_position,
			"weight": 0.35 * (amount / 500.0),
			"spread": 11.0,
		})

	for node: Node in get_tree().get_nodes_in_group(LEADER_GROUP):
		if node == self or not (node is Node3D):
			continue

		sources.append({
			"position": _leader_position_of(node),
			"weight": 1.2,
			"spread": 9.0,
		})

	return sources


func _density_from_sources(point: Vector3, sources: Array[Dictionary]) -> float:
	var density: float = 0.0

	for source: Dictionary in sources:
		var source_position: Vector3 = source["position"]
		var offset: float = source_position.distance_to(point)
		var spread: float = maxf(float(source["spread"]), 0.5)
		density += float(source["weight"]) / (1.0 + pow(offset / spread, 2.0))

	return density


func _cloud_anchors() -> Array[Vector3]:
	var anchors: Array[Vector3] = []

	if _leader != null:
		anchors.append(_leader.global_position)

	for node: Node in get_tree().get_nodes_in_group(EMITTER_GROUP):
		if node is Node3D:
			anchors.append((node as Node3D).global_position)

	for node: Node in get_tree().get_nodes_in_group(LEADER_GROUP):
		if node == self or not (node is Node3D):
			continue

		anchors.append(_leader_position_of(node))

	return anchors


## Estimated local particle density. Public for diagnostics and bird logic.
func get_cloud_density(point: Vector3) -> float:
	return _density_from_sources(point, _cloud_sources())


## Pick the densest point within `search_radius` of `from_position` that is still
## inside the cloud volume. Used for both promotion (appear) and demotion
## (disappear) so the transitions read as birds joining/leaving the flock.
func find_cloud_hideout(from_position: Vector3, search_radius: float) -> Vector3:
	var anchors := _cloud_anchors()

	if anchors.is_empty():
		return from_position + Vector3(0.0, flight_altitude, 0.0)

	var sources := _cloud_sources()
	var best: Vector3 = anchors[0]
	var best_score: float = -INF
	var radius: float = maxf(search_radius, 1.0)

	for index: int in range(CLOUD_SAMPLE_COUNT):
		# Most samples come from this flock's own cloud; a few may use other
		# dense areas so the bird can still join a neighbouring flock.
		var anchor: Vector3 = (
			anchors[0]
			if index % 3 != 0
			else anchors[index % anchors.size()]
		)
		var direction := Vector3(
			_rng.randf_range(-1.0, 1.0),
			_rng.randf_range(-0.35, 0.8),
			_rng.randf_range(-1.0, 1.0)
		)

		if direction.length_squared() < 0.001:
			direction = Vector3.UP

		var candidate: Vector3 = anchor + direction.normalized() * _rng.randf_range(2.0, 8.0)
		var travel: float = candidate.distance_to(from_position)

		if travel > radius:
			candidate = from_position + (candidate - from_position).normalized() * radius
			travel = radius

		# Prefer dense spots, but stay reasonably close: a bird should join the
		# nearest flock, not a cloud on the far side of the map.
		var score: float = (
			_density_from_sources(candidate, sources) - travel * 0.004
		)

		if score > best_score:
			best_score = score
			best = candidate

	return best


## Read-only diagnostics for tests and the results/debug HUD.
func get_leader_position() -> Vector3:
	return _leader.global_position if _leader != null else global_position


func get_leader_velocity() -> Vector3:
	return _velocity


func get_flock_state() -> Dictionary:
	return {
		"leader": _leader.global_position if _leader != null else global_position,
		"velocity": _velocity,
		"speed": _velocity.length(),
		"loitering": _is_loitering,
		"migrating": _migrating,
		"migration_target": _migration_target,
		"loiter_center": _loiter_center,
		"loiter_radius": _loiter_radius,
		"loiter_timer": _loiter_timer,
		"perched": _perched.size(),
		"max_perched": max_perched_birds,
		"perches": _perches.size(),
		"target": (
			_target_perch.name
			if _target_perch != null and is_instance_valid(_target_perch)
			else ""
		),
		"target_position": _target_position,
		"target_is_perch": _target_is_perch,
		"explored_chunks": _exploration_cost.size(),
		"has_target": _has_target,
	}


## Called by a bird when it frees itself.
func notify_bird_gone(bird: Node) -> void:
	_perched.erase(bird)


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
