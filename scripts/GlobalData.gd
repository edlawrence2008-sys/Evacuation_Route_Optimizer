extends Node

var npcs_evacuated: int = 0
var npcs_spawned: int = 0
@export var global_unit_cap: int = 700 # Maximum NPCs alive across the whole game/scene
## Total spawn limit for the run. -1 means "use the sum of each spawner's quota".
@export var global_spawn_quota: int = -1
## Default evacuation behaviour inherited by newly spawned members.
var evacuation_mode: bool = true
var is_spawning_enabled: bool = false # Default to false so they don't spawn directly on start

## Exported Agent/Member properties applied to every new spawn and, on Apply,
## to every live agent. Owned by the Agents category in the inventory.
var agent_overrides: Dictionary = {}

## Quota ownership is keyed by the spawner instance id so a spawner can be
## removed without leaving a phantom quota behind.
var _independent_quotas: Dictionary = {} # spawner instance id -> quota
var _section_registrations: Dictionary = {} # section -> { spawner instance id: true }
var _section_spawn_counts: Dictionary = {}
var _section_quotas: Dictionary = {}

signal npc_evacuated(total_count: int)
signal npc_spawned(total_count: int)
signal spawning_reset() # Signal to reset local spawner states
signal spawning_started()
signal spawning_stopped()

func register_npc_spawned() -> void:
	npcs_spawned += 1
	npc_spawned.emit(npcs_spawned)


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

func reset_all() -> void:
	_independent_quotas.clear()
	_section_registrations.clear()
	_section_spawn_counts.clear()
	_section_quotas.clear()
	npcs_spawned = 0
	npcs_evacuated = 0
	is_spawning_enabled = false

func start_spawning() -> void:
	if is_spawning_enabled:
		return
	is_spawning_enabled = true
	spawning_started.emit()

func stop_spawning() -> void:
	if not is_spawning_enabled:
		return
	is_spawning_enabled = false
	spawning_stopped.emit()

func reset_spawning() -> void:
	# Keeps sections and quotas intact, but resets current spawn counters and state
	_section_spawn_counts.clear()
	npcs_spawned = 0
	npcs_evacuated = 0
	is_spawning_enabled = false
	spawning_reset.emit()

func _registration_key(spawner: Object) -> int:
	if spawner != null and is_instance_valid(spawner):
		return spawner.get_instance_id()
	return 0
