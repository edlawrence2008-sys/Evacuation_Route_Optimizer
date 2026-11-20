# Evacuation points: finite throughput and receiving areas

> **Status:** 2026-11-18 · **Applies to:** `scenes/evac_point.gd`,
> `evacuation_manager.gd`, `scripts/NPCstuff/Member.gd`,
> `scenes/EvacuationResults_hud.gd`, `scripts/map_renderer.gd` ·
> **Companions:** [`SIMULATION_MODEL.md`](SIMULATION_MODEL.md) §5.6,
> [`CODEBASE_ANALYSIS.md`](CODEBASE_ANALYSIS.md) §4.5.

`scenes/placeables/sim/sim_evac_point.tscn` still works exactly as before: an
NPC that enters the 1 m radius, 2 m tall trigger is recorded and removed from
the simulation. Everything below is opt-in on the `Area3D` child's script.

## Where the policy lives

| Concern | Owner |
|---|---|
| Trigger volume, queue, service timer, receiving slots | `scenes/evac_point.gd` |
| Retained-agent container, run records, aggregate stats | `evacuation_manager.gd` |
| Agent-side hold/reject/resume and deactivation | `scripts/NPCstuff/Member.gd` |
| Display of the resulting metrics | `scenes/EvacuationResults_hud.gd` (F4) |
| Statistics-image summary | `scripts/map_renderer.gd` (`format_statistics`) |

Only the `Area3D` carries the script, but both the root and the area are in the
`EvacPoint` group. Exit choice and `map_renderer` deduplicate them by quantised
position, so the pair is still treated as one exit.

## Exported settings

### Tracking and retention

| Setting | Default | Meaning |
|---|---|---|
| `exit_id` | `""` | Stable id for stats/optimizer. Empty falls back to the node path. Two exits with the same explicit id merge their aggregates. |
| `operational` | `true` | Whether the exit is usable. Disabling removes it from exit choice, releases queued/service-held agents, notifies assigned agents, and records the change for the recorder. |
| `track_evacuation` | `true` | Write per-exit and per-agent records. When false, the global evacuated counter still advances and `retain_evacuated` still applies; only the detailed records are suppressed. |
| `retain_evacuated` | `false` | Keep the evacuated node instead of freeing it. |
| `keep_retained_visible` | `true` | Show or hide retained nodes. Ignored when not retaining. |
| `retained_hold_time` | `0` | Seconds before a retained node is freed and its slot released. `0` = forever. Expiry is checked at most every 0.25 s. |

### Exit throughput

| Setting | Default | Meaning |
|---|---|---|
| `exit_service_rate` | `0` | People per second through the exit. `0` = immediate admission (original behaviour). |
| `max_queue_length` | `0` | Maximum waiting agents at this exit. `0` = unlimited. Over-limit arrivals are rejected. |

### Receiving area

| Setting | Default | Meaning |
|---|---|---|
| `receiving_capacity` | `0` | Simultaneous retained occupants past the exit. `0` = unlimited. Cannot bind with `retain_evacuated = false`. |
| `receiving_full_behavior` | `QUEUE` | `QUEUE` holds arrivals, `REJECT` sends them back to exit choice with this exit on cooldown. |
| `receiving_area_offset` | `Vector3.ZERO` | Local offset from the marker to the receiving-area centre. |
| `receiving_slot_spacing` | `0.9` | Metres between retained agents in the receiving area. |

Agent-side fail-safe: `Member.max_exit_hold_time` (default 120 s) makes a
queued agent give up, cancel its queue entry and re-route rather than wait
forever.

## Semantics

- **Throughput and capacity are independent.** Service rate controls how fast
  agents pass the trigger. Capacity controls how many retained agents may sit
  beyond it. Enabling one does not enable the other, and neither is on by
  default.
- **Capacity needs retention.** A despawned agent leaves the safe area on the
  admission frame, so `receiving_capacity` only binds when `retain_evacuated`
  is true. This is deliberate: it keeps existing scenes at their old behaviour.
- **Disabled exits.** `operational = false` (or `set_operational(false)`) removes
  the exit from choice, clears its queue/service slot, calls
  `Member.on_exit_unavailable()` for agents whose target is that exit, and emits
  `availability_changed`. Re-enabling makes it eligible again. The recorder
  writes `exit_state` and a `disruption` row for both transitions.
- **Admission is counted once.** An agent added to the queue is admitted at
  most once. `GlobalData.register_evacuation()` always advances at completion;
  the per-agent record is written only when `track_evacuation` is true.
- **Queue wait** is measured from enqueue to service start on
  `GlobalData.sim_now()`, so pauses and frame hitches do not inflate it.
- **Full behaviours:**
  - `QUEUE` — the agent stays in `ARRIVED` with `_exit_hold_active`, keeps its
    place and still contributes to the active crowd until admitted or expired.
  - `REJECT` — `reject_evacuation()` clears the hold, puts that exit on the
    agent's cooldown map and lets it choose again.
- **Deleted exit.** `_exit_tree()` releases every queued and service-held
  agent and drops the retained agents owned by that exit, so removing a live
  evac point cannot strand or orphan anything.
- **Run reset and global kill.** `reset_spawning()` and
  `GlobalData.kill_all_npcs()` call `EvacuationManager.clear_retained_agents()`,
  so retained visuals do not survive a clean reset or a full crowd kill.
- **Retained agents are inactive.** `Member.mark_evacuated()` sets the
  `evacuated` metadata, removes the `npc` **and `Members`** groups, zeroes
  collision layers, stops physics/process on the body and its visuals, cancels
  pending path requests, and ignores late path callbacks. `EvacuationManager`
  then reparents the node to an `EvacuatedAgents` container at the exit-owned
  slot.

## Invariants and limitations

- `CrowdManager` rebuilds its agent list from the `npc` group every solve, so
  group removal is what excludes retained agents from density, contact force
  and navigation. The spawner counts the `Members` group against its live-agent
  cap, so retained agents are removed from that group too. Do not re-add a
  retained node to either group.
- Retained agents are still scene nodes and still render when visible. They are
  not simulated, so they neither block nor push active agents.
- Receiving capacity is a policy limit, not a geometric area. It does not
  compute floor space or body packing.
- Service rate is an imposed schedule. It does not simulate door geometry,
  body width or local walking speed inside an opening. It is a single-server
  constant interval (`1 / rate`), so the first agent after an idle period also
  waits one interval.
- Waiting-time statistics cover admitted agents (enqueue to service start).
  Rejected agents are counted as capacity/queue events rather than in the wait
  average.
- The default (all limits `0`, no retention) is deliberately unchanged from the
  original trigger so existing maps and saved runs keep their results.
- Per-exit summaries include configured exits with zero arrivals, so capacity
  can be inspected before the first agent reaches the point.
- The F4 results panel and the statistics-image summary both show receiving
  occupancy, peak, queue and capacity events when any of them are active.
- `SimRecorder` writes exit availability, admission rate, queue, wait,
  occupancy, utilization and assigned-agent counts per sample; see
  `docs/SIM_MEASUREMENTS.md`.
- `GlobalData.reset_all()` is a debug path that kills active NPCs and clears
  counters, but it does not emit `spawning_reset`; use `reset_spawning()` for a
  complete run reset that also clears manager records and exit policies.
