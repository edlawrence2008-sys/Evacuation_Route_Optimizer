# False boids

> Status: **2026-11-15**. Hybrid ambient-bird system in
> `scripts/world/false_boid_emitter.gd`, `false_boid_director.gd`,
> `false_boid_flock.gd`, `false_boid.gd`, and `false_boid_perch.gd`;
> demo placement in `Maps/test.tscn`.

## Why a hybrid

The previous implementation used only GPU particles, with attractors and
player-shaped forces to simulate landing. That produced a fly/hornet swarm:
particles have no persistent state, cannot reliably stop on a surface, and
hacks such as pushing them upward or scooping them with the player are visibly
artificial.

False boids split the two jobs:

- **Flight is world-space particles.** Placeable `FalseBoidEmitter` nodes
  around the map emit shaded, animated bird particles. Particles are not
  parented to the moving leaders; the director creates **one leader per
  emitter, capped at 10**, and each leader has a map-scale attractor that pulls
  the shared particle cloud. The emitters use `Boid.png`'s three animation
  frames, ring emission, turbulence, and 60 FPS simulation.
- **Perching is real nodes.** When a leader reaches a `FalseBoidPerch`, a
  small number of lightweight `FalseBoid` sprite nodes are promoted **at the
  flock**, then physically fly to the perch. They are capped at
  `max_perched_birds` (default **20**), react to the player, and free themselves
  after fleeing (demotion). This solves the exact "particles stuck on the
  ground" problem without simulating every bird.

## Runtime flow

1. Each placed `FalseBoidEmitter` emits world-space particles at its own
   position. The first emitter creates a shared `FalseBoidDirector`, which
   creates one `FalseBoidFlock` leader per emitter (up to 10).
2. Each leader alternates between perching, **chunk exploration**, and — with
   `hotspot_chance` — flying toward the densest nearby leader cluster. It
   selects an active chunk, picks a random point inside it, and flies to
   `highest_block_y + 10…25` above that chunk. A recent-chunk cost decays over
   time so leaders revisit recently explored chunks less often.
3. If a leader is in an over-dense cluster (`crowd_threshold` leaders within
   `crowd_radius`), the director calls `repel_for()` and its attractor strength
   temporarily becomes **negative**, pushing the particle cloud apart.
4. For perching, the leader selects a perch with free slots that is not within
   `flee_radius` of the player and flies to `perch_position + flight_altitude`.
5. On arrival, it promotes `perch_spawn_batch` birds every
   `perch_spawn_interval` until the perch or the global cap is full.
6. Each promoted bird spawns near the leader in `FLYING_TO_PERCH`, picks a
   curved approach point above its slot, then descends and switches to
   `PERCHED`.
7. When the player comes within `flee_radius` of a perch, its birds go
   `PERCHED → ALERT (0.25 s) → FLEEING`, fly **toward the flock leader** to be
   hidden by the cloud, then `queue_free()` and release their slots.
8. Leaders keep moving between perches and active chunks. The director creates
   or deletes leaders as the emitter count changes: `leaders = min(emitters, 10)`.

The burst is capped globally, not just per emitter: promoted birds join the
`false_boid_perched` group, so multiple leaders/emitters cannot exceed 20 active
perched/flying birds at once.

A `GPUParticlesCollisionBox3D` sits at world `y = 0`, sized 220×2×220, and
follows the player's X/Z each frame. It stops particles sinking below the
ground; emitters use the reference collision mode.

## Files and scenes

| File | Role |
|---|---|
| `scripts/world/false_boid_emitter.gd` | Placeable world-space particle source; creates the shared director |
| `scripts/world/false_boid_director.gd` | Leader lifecycle (`min(emitters, 10)`), ground collision box, player following |
| `scripts/world/false_boid_flock.gd` | Per-leader attractor, perch selection, chunk exploration with decaying cost, promotion cap |
| `scripts/world/false_boid.gd` | Curved flight to perch, perching/alert/flee-toward-flock state machine, slot release |
| `scripts/world/false_boid_perch.gd` | Perch marker with capacity and ring slots |
| `scenes/placeables/sim/sim_false_boid_emitter.tscn` | **Placeable** bird emitter with a feeder mesh; appears in the Placeables inventory automatically |
| `scenes/placeables/sim/sim_false_boid_perch.tscn` | **Placeable** perch marker with a visible disc; capacity 5 |
| `Maps/test.tscn` | Three placed emitters at `(8, 0, 8)`, `(-10, 2, 10)`, and `(20, 2, 12)`, plus four placed perches |

The particle draw pass uses the full 48×16 `textures/particles/Boid.png` sheet
with `particles_anim_h_frames = 3`, `BILLBOARD_PARTICLES`, and normal per-pixel
shading. Promoted birds use the same sheet through a `Sprite3D` with
`hframes = 3`, so both stages share the same animation.

## Tuning

| Export | Default | Effect |
|---|---:|---|
| `particle_count` (emitter) | 300 | Particles per placed emitter |
| `particle_size` (emitter) | 1.0 m | Full billboard size; scale variance 0.5–1.5 matches the reference |
| `particle_lifetime` (emitter) | 30.0 | Faster turnover; less static drift than the 200 s reference |
| `emission_radius` (emitter) | 2.5 m | Ring emission size |
| `velocity_min/max` (emitter) | 1.2 / 3.2 | Higher initial motion, less floaty |
| `linear_accel_max` | 2.0 | Keeps particles moving rather than hovering |
| `damping_max` | 0.5 | Bleeds off aimless drift |
| `anim_speed_min/max` | 18 / 26 | Faster wing animation |
| `attractor_radius` | 600.0 | Map-scale pull radius |
| `attractor_strength` | 30.0 | Pull strength toward the leader |
| `repel_strength` | 80.0 | Negative strength when a leader is crowded |
| `hotspot_chance` | 0.22 | Chance to fly toward the densest leader cluster |
| `MAX_LEADERS` (director) | 10 | One leader per emitter, capped at 10 |
| `crowd_threshold` | 3 | Leaders within `crowd_radius` that trigger repulsion |
| `crowd_radius` | 12.0 m | Leader cluster radius for repulsion/hotspots |
| `ground_collision_size` | 220×2×220 | Player-following ground collision box size |
| `chunk_clearance_min/max` | 10 / 25 | Target height above the highest block in a chunk |
| `explore_chance` | 0.55 | Chance to explore instead of perch |
| `chunk_cost_decay_per_sec` | 0.12 | How fast recently explored chunks become attractive again |
| `flight_altitude` | 5.0 | Hover height above a perch |
| `flight_speed` | 4.0 | Leader travel speed |
| `follow_player` | false | Keeps the shared attractor around the player instead of perching |
| `follow_offset` | `(0, 5, 0)` | Offset used by `follow_player` |
| `flee_speed_multiplier` | 2.0 | Leader retreat speed when approached |
| `max_perched_birds` | 20 | Hard global promotion cap across emitters |
| `perch_spawn_batch` | 2 | Birds promoted per interval |
| `perch_spawn_interval` | 0.45 | Promotion cadence |
| `flee_radius` | 5.5 | Player distance that startles a perch |
| `FalseBoidPerch.capacity` | 3 (5 on the placeable/test perches) | Slots per perch |
| `FalseBoid.flight_speed` | 4.0 (multiplied by 1.25 when promoted) | Flight speed from flock to perch |
| `FalseBoid.sprite_pixel_size` | 0.0625 | Perched/fleeing sprite scale (about 1 m) |
| `FalseBoid.flee_duration` | 1.6 s | Time before a fleeing bird frees itself |

Emitters and perches are placeable scenes. Drop `sim_false_boid_emitter` and
`sim_false_boid_perch` from the Placeables inventory. Emitters are independent
sources; the director creates one leader/attractor per emitter (up to 10), so a
map with several emitters produces several interacting flocks over the same
particle cloud. Perches are discovered through the `false_boid_perches` group;
no nav mesh or collision is required.

## Current limitations

- The flight cloud is **not** a true boid simulation. It is a set of emission
  volumes with ring emission and turbulence, pulled by per-leader attractors.
  The user-visible behaviour is a flock, but there is no per-particle
  separation/alignment/cohesion.
- There is one leader per emitter up to 10; leaders share perches and the global
  20-bird promotion cap, but do not explicitly coordinate targets.
- `follow_player` moves the attractor/leader, not the emitter itself; perching
  is disabled while it is on.
- Perched birds are silhouettes using the same 3-frame flight sheet; there is
  no dedicated perched pose, pecking, or landing animation.
- Promoted birds do not collide with the world or each other. They are visual
  ambient agents with a simple state machine, not full NPCs.
- No smoke/fire/hazard response. Player proximity is the only flight trigger.
- The leader can occasionally change targets when the player approaches,
  leaving a perch before it fills; this is intentional avoidance, not a bug.

## Possible next steps

- **Sub-emitters as state transitions:** a flying emitter could spawn a short
  landing burst, then the perched node pool takes over. The pool already gives
  the same visual contract with more control.
- **Vector fields per perch:** replace the sphere attractor with a baked
  vector field that pushes birds toward the perch, then fades as the leader
  arrives.
- **True boids:** add alignment/cohesion/separation per particle on the CPU or
  compute shader only if the visual difference justifies the cost.
- **Dedicated perched art:** a perched frame or separate silhouette sheet would
  make the promotion/demotion less obvious than the current flight frame.
