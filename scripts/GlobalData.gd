extends Node

var npcs_evacuated: int = 0
var npcs_spawned: int = 0
@export var global_unit_cap: int = 120 # Maximum NPCs alive across the whole game/scene
## Total spawn limit for the run. -1 means "use the sum of each spawner's quota".
@export var global_spawn_quota: int = -1
## Default evacuation behaviour inherited by newly spawned members.
var evacuation_mode: bool = true
var is_spawning_enabled: bool = false # Default to false so they don't spawn directly on start
## Paused is distinct from stopped: counters, quotas, and the current run stay
## intact, but spawners stop emitting until resumed.
var is_spawning_paused: bool = false
## Pre-populated fixtures set this while agents are created before Start. Member
## holds still until start_spawning() clears it, so run-relative evacuation times
## are not corrupted by agents that began walking before time zero.
var population_frozen: bool = false

## Run mode for the optimizer. False is the baseline: agents choose exits with
## the local logit model. The bridge sets this; Member instances only honour an
## explicit per-agent assignment.
var optimizer_enabled: bool = false

## Last optimizer estimate, for the results panel's predicted-vs-measured line.
## Predicted values are never written into the measured summary fields.
var optimizer_last_estimate: float = 0.0
var optimizer_last_algorithm: String = ""
var optimizer_last_mode: String = ""

## Bumped whenever the world or an exit changes in a way that invalidates an
## optimizer result. A result whose source version differs is applied only after
## re-solving. Chunk streaming does not bump it.
var environment_version: int = 0

## Exported Agent/Member properties applied to every new spawn and, on Apply,
## to every live agent. Owned by the Agents category in the inventory.
var agent_overrides: Dictionary = {}

## Persistent dialogue/story flags, e.g. whether Consul's intro was seen.
var dialogue_flags: Dictionary = {}

# ============================================================
# SIMULATION CLOCK & DETERMINISM
# ============================================================

## Monotonic physics time for the current session. Advancing this only in
## _physics_process means pausing the game, a menu, or a frame hitch cannot
## inflate measured evacuation times. All run metrics must use sim_now().
var sim_time: float = 0.0

## Seed used for the current run. Change it (or call reset_determinism) to
## reproduce a run exactly. Agent-local streams are derived from
## (rng_seed, agent_serial), so spawn order no longer depends on instance IDs.
@export var rng_seed: int = 12345
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _agent_serial: int = 0


func _ready() -> void:
	rng.seed = rng_seed
	seed(rng_seed) # legacy randf_range() callers become reproducible too


func _physics_process(delta: float) -> void:
	# Paused trees do not tick, so sim_time stops while the game is paused.
	sim_time += delta


func sim_now() -> float:
	return sim_time


## Monotonic serial assigned on agent spawn. Used as the deterministic
## right-of-way tie-break instead of the engine instance id.
func claim_agent_serial() -> int:
	_agent_serial += 1
	return _agent_serial


func reset_determinism(seed_value: int = -1) -> void:
	if seed_value >= 0:
		rng_seed = seed_value

	_agent_serial = 0
	rng.seed = rng_seed
	seed(rng_seed)


## Release static scene caches while the rendering server is still alive.
func _exit_tree() -> void:
	RealisticSpriteLibrary.clear_cache()

func get_dialogue_flag(key: StringName, default_value: Variant = false) -> Variant:
	return dialogue_flags.get(key, default_value)

func set_dialogue_flag(key: StringName, value: Variant = true) -> void:
	dialogue_flags[key] = value

## Quota ownership is keyed by the spawner instance id so a spawner can be
## removed without leaving a phantom quota behind.
var _independent_quotas: Dictionary = {} # spawner instance id -> quota
var _section_registrations: Dictionary = {} # section -> { spawner instance id: true }
var _section_spawn_counts: Dictionary = {}
var _section_quotas: Dictionary = {}

signal npc_evacuated(total_count: int)
signal npc_spawned(total_count: int)
## Emitted with the spawned node so measurement/replay tooling can attach to it.
signal agent_spawned(npc: Node)
## Any runtime environment edit that can change navigation or the scenario.
## `change_type` is one of: block_added, block_removed, placeable_added,
## placeable_removed, water_placed, exit_added, exit_removed, exit_enabled,
## exit_disabled. `detail` carries recorder-specific fields (cells, scene, item).
signal environment_changed(location: Vector3, change_type: String, detail: Dictionary)
signal spawning_reset() # Signal to reset local spawner states
signal spawning_started()
signal spawning_stopped()
signal spawning_paused()
signal spawning_resumed()

func register_npc_spawned(npc: Node = null) -> void:
	npcs_spawned += 1
	npc_spawned.emit(npcs_spawned)

	if npc != null and is_instance_valid(npc):
		agent_spawned.emit(npc)


## Announces an agent that was created outside a spawner (demo import, debug
## spawn) to recorder/listener code without touching the run counters. The
## caller is responsible for restoring npcs_spawned/npcs_evacuated, because an
## imported agent was already counted in the recording.
func notify_agent_spawned(npc: Node) -> void:
	if npc != null and is_instance_valid(npc):
		agent_spawned.emit(npc)


## Keeps future serials strictly above an imported population so a new spawn
## cannot collide with a recorded agent's right-of-way tie-break id.
func set_agent_serial_floor(value: int) -> void:
	_agent_serial = maxi(_agent_serial, value)


## Public entry point for systems that modify the world after load. The recorder
## listens to this; gameplay code may ignore it.
func report_environment_change(
	location: Vector3,
	change_type: String,
	detail: Dictionary = {}
) -> void:
	bump_environment_version()
	environment_changed.emit(location, change_type, detail)


## Invalidates any optimizer result that was computed against the previous
## world state. Exit availability changes call this too.
func bump_environment_version() -> void:
	environment_version += 1


## Sets the run's assignment mode. The optimizer bridge owns the decision; this
## flag makes the mode visible to the recorder and the panels.
func set_optimizer_enabled(enabled: bool) -> void:
	optimizer_enabled = enabled


## Cross-spawner spawn-slot reservation. Physics bodies spawned in the same
## frame are not in the physics space yet, so the shape query alone can miss
## two spawners choosing the same spot.
var _spawn_reservations: Array[Dictionary] = []


func reserve_spawn_position(position: Vector3, radius: float) -> bool:
	var now: int = Time.get_ticks_msec()
	var radius_sq: float = radius * radius

	for index in range(_spawn_reservations.size() - 1, -1, -1):
		var entry: Dictionary = _spawn_reservations[index]

		if now - int(entry.get("time", 0)) > 400:
			_spawn_reservations.remove_at(index)
			continue

		var previous: Vector3 = entry.get("position", Vector3.ZERO)
		var difference: Vector3 = previous - position
		difference.y = 0.0

		if difference.length_squared() < radius_sq:
			return false

	_spawn_reservations.append({
		"position": position,
		"time": now,
	})
	return true


func clear_spawn_reservations() -> void:
	_spawn_reservations.clear()


func is_global_quota_available() -> bool:
	return global_spawn_quota < 0 or npcs_spawned < global_spawn_quota


## Applies the evacuation behaviour to every live member and to future spawns.
func set_evacuation_mode(enabled: bool) -> void:
	evacuation_mode = enabled

	if get_tree() == null:
		return

	for npc in get_tree().get_nodes_in_group("npc"):
		if npc.has_method("set_evacuation_mode"):
			npc.set_evacuation_mode(enabled)

func register_evacuation() -> void:
	npcs_evacuated += 1
	npc_evacuated.emit(npcs_evacuated)


## Stores the agent overrides and applies them to every live member.
## Returns the number of live agents updated.
func set_agent_overrides(overrides: Dictionary) -> int:
	agent_overrides = overrides.duplicate(true)

	if get_tree() == null:
		return 0

	var updated: int = 0

	for npc in get_tree().get_nodes_in_group("npc"):
		if npc.has_method("apply_agent_overrides"):
			npc.apply_agent_overrides(agent_overrides)
			updated += 1

	return updated


## Clears the overrides used by future spawns. Live agents keep their values;
## the Agents panel applies scene defaults explicitly when it resets.
func clear_agent_overrides() -> void:
	agent_overrides.clear()

## Registers an independent spawner's quota when it enters the scene tree.
## `owner` is the spawner node; pass it so the quota can be removed again.
func register_independent_spawner(quota: int, spawner: Object = null) -> void:
	_independent_quotas[_registration_key(spawner)] = quota

## Removes the quota owned by a spawner that left the scene tree.
func unregister_independent_spawner(spawner: Object) -> void:
	_independent_quotas.erase(_registration_key(spawner))

## Updates a live spawner's quota without re-registering it.
func update_independent_spawner_quota(spawner: Object, quota: int) -> void:
	var key: int = _registration_key(spawner)
	if _independent_quotas.has(key):
		_independent_quotas[key] = quota

## Registers a spawn section and its quota when a spawner enters the scene tree.
## Multiple spawners may share a section; the first quota wins.
func register_section(section: String, quota: int, spawner: Object = null) -> void:
	if not _section_registrations.has(section):
		_section_registrations[section] = {}
		_section_quotas[section] = quota

	_section_registrations[section][_registration_key(spawner)] = true

## Removes one spawner from a section. The section itself is removed only when
## its last spawner leaves.
func unregister_section(section: String, spawner: Object) -> void:
	if not _section_registrations.has(section):
		return

	_section_registrations[section].erase(_registration_key(spawner))

	if _section_registrations[section].is_empty():
		_section_registrations.erase(section)
		_section_quotas.erase(section)

## Updates a shared section's quota. All spawners in the section share this.
func update_section_quota(section: String, quota: int) -> void:
	if _section_quotas.has(section):
		_section_quotas[section] = quota

## Calculates the total combined maximum spawns across all independent spawners and sections.
## Returns -1 if any spawner or section is set to unlimited (-1).
func get_total_max_spawns() -> int:
	var total: int = 0

	# Sum up independent spawner quotas
	for q: Variant in _independent_quotas.values():
		if int(q) < 0:
			return -1
		total += int(q)

	# Sum up section quotas
	for q: Variant in _section_quotas.values():
		if int(q) < 0:
			return -1
		total += int(q)

	if global_spawn_quota >= 0:
		return mini(total, global_spawn_quota)

	return total

## Returns an array of all registered spawn section names.
func get_all_sections() -> Array:
	return _section_quotas.keys()

## Returns how many total NPCs have been spawned by a specific shared section.
func get_section_spawn_count(section: String) -> int:
	return _section_spawn_counts.get(section, 0)

## Returns the maximum quota for a specific shared section.
func get_section_quota(section: String) -> int:
	return _section_quotas.get(section, -1)

## Increments the spawn counter for a shared section.
func increment_section_spawn_count(section: String) -> void:
	var current: int = get_section_spawn_count(section)
	_section_spawn_counts[section] = current + 1


## Restores a shared section's spawn count after importing a recorded state.
## Without this, reloading a mid-run demo would let every section re-spend its
## full quota.
func set_section_spawn_count(section: String, count: int) -> void:
	if section.is_empty():
		return

	_section_spawn_counts[section] = maxi(0, count)

func reset_all() -> void:
	kill_all_npcs()
	_independent_quotas.clear()
	_section_registrations.clear()
	_section_spawn_counts.clear()
	_section_quotas.clear()
	clear_spawn_reservations()
	npcs_spawned = 0
	npcs_evacuated = 0
	is_spawning_enabled = false
	is_spawning_paused = false
	population_frozen = false

## Pauses or resumes spawning without changing quotas, counters, determinism,
## or the live crowd. A paused run is still "started"; Start clears the pause.
func set_spawning_paused(paused: bool) -> void:
	if is_spawning_paused == paused:
		return

	is_spawning_paused = paused

	if paused:
		spawning_paused.emit()
	else:
		spawning_resumed.emit()


## Removes every live NPC from the scene. The group is cleared immediately so
## counters and spawners see the empty crowd on the same frame; queue_free then
## releases the nodes at the end of the frame.
func kill_all_npcs() -> int:
	var tree: SceneTree = get_tree()

	if tree == null:
		return 0

	var killed: int = 0

	for npc: Node in tree.get_nodes_in_group("npc"):
		if npc == null or not is_instance_valid(npc):
			continue

		npc.remove_from_group("npc")
		npc.queue_free()
		killed += 1

	# Retained evacuated agents are outside the npc group by design, but a full
	# kill must still remove them and free their receiving slots.
	var manager := get_node_or_null("/root/EvacuationManager")

	if manager != null and manager.has_method("clear_retained_agents"):
		manager.clear_retained_agents(true)

	return killed


func start_spawning() -> void:
	var was_frozen: bool = population_frozen
	population_frozen = false

	if was_frozen:
		var frozen_tree: SceneTree = get_tree()

		if frozen_tree != null:
			for npc: Node in frozen_tree.get_nodes_in_group("npc"):
				if npc != null and is_instance_valid(npc) and npc.has_method("mark_run_start"):
					npc.call("mark_run_start")

	var was_paused: bool = is_spawning_paused
	is_spawning_paused = false

	if was_paused:
		spawning_resumed.emit()

	if is_spawning_enabled:
		return
	# Every run starts from the same seed and agent numbering, so a repeated
	# run on an unchanged layout is bit-for-bit reproducible. If agents from a
	# previous run are still alive, keep the serial counter monotonic instead:
	# two live agents must never share the right-of-way tie-break id.
	var tree: SceneTree = get_tree()

	if tree == null or tree.get_nodes_in_group("npc").is_empty():
		reset_determinism()
	else:
		rng.seed = rng_seed
		seed(rng_seed)

	clear_spawn_reservations()
	is_spawning_enabled = true
	spawning_started.emit()

func stop_spawning() -> void:
	var was_paused: bool = is_spawning_paused
	is_spawning_paused = false

	if was_paused:
		spawning_resumed.emit()

	if not is_spawning_enabled:
		return
	is_spawning_enabled = false
	spawning_stopped.emit()

func reset_spawning() -> void:
	# A reset is a new run: stop spawning, remove every live NPC, and reset
	# counters. Quotas and section registrations stay intact.
	bump_environment_version()
	kill_all_npcs()
	_section_spawn_counts.clear()
	clear_spawn_reservations()
	npcs_spawned = 0
	npcs_evacuated = 0
	is_spawning_enabled = false
	is_spawning_paused = false
	spawning_reset.emit()

func _registration_key(spawner: Object) -> int:
	if spawner != null and is_instance_valid(spawner):
		return spawner.get_instance_id()
	return 0
