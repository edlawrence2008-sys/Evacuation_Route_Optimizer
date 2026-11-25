# False boids

> **Status:** 2026-11-22 (flock groups, layer-scoped attractors and per-emitter tuning) - **Applies to:**
> `scripts/world/false_boid_emitter.gd`, `false_boid_director.gd`,
> `false_boid_flock.gd`, `false_boid.gd`, `false_boid_perch.gd` - **Companions:**
> [`CODEBASE_ANALYSIS.md`](CODEBASE_ANALYSIS.md) section 4.17.

## Why a hybrid

The previous implementation used only GPU particles, with attractors and
player-shaped forces to simulate landing. That produced a fly/hornet swarm:
particles have no persistent state, cannot reliably stop on a surface, and
hacks such as pushing them upward or scooping them with the player are visibly
artificial.

False boids split the two jobs:

- **Open flight is world-space particles.** Placeable `FalseBoidEmitter` nodes
  around the map emit shaded, animated bird particles. Particles are not
  parented to the moving leaders; the director creates **one leader per
  emitter, capped at 10**, and each leader has a modest attractor that gathers
  its flock. The emitters use `Boid.png`'s three animation frames, ring
  emission, a constant swirl, turbulence, and 60 FPS simulation.
- **Flocks are isolated by group and particle layer.** Every emitter exposes a
  `flock_group`. Emitters sharing a group share one particle visibility layer,
  and their leaders' `GPUParticlesAttractor3D.cull_mask` points at that layer,
  so a group's particles only react to that group's leaders. Leaders still see
  each other: same-group leaders use separation/alignment/cohesion, while
  different groups only apply an inter-flock separation force and spook each
  other temporarily with `repel_for()`. This is what prevents every flock from
  eventually merging into one sky blob.
- **Close flight and perching are real boids.** Leaders and promoted
  `FalseBoid` sprites are true boid agents: they carry a velocity, steer with
  bounded acceleration, separate from neighbours, align with nearby fliers,
  and never come to rest in mid-air. When a bird finishes resting it leaves on
  its own, rejoins a dense part of the cloud, and demotes. This solves the
  "particles stuck on the ground" problem without simulating every bird on the
  CPU.

## Flock tuning and groups

`FalseBoidEmitter` exposes a **Flock** group in the Property tab. Select an
emitter placeable to edit:

| Export | Default | Effect |
|---|---:|---|
| `flock_group` | `default` | Emitters sharing a group share a particle layer and cooperate. |
| `flock_attractor_radius` / `strength` / `attenuation` | 90 / 8 / 0.6 | How strongly the group's leaders pull their particles. |
| `flock_flight_altitude` | 9.0 | Cruise height above terrain. |
| `flock_flight_speed` / `min` / `max` | 7.5 / 5 / 14 | Leader cruise and speed limits. |
| `flock_steer_strength` | 15 | Leader steering acceleration. |
| `flock_separation_radius` / `weight` | 9 / 1.5 | Same-group leader spacing. Raise this to spread a flock. |
| `flock_alignment_radius` / `weight` | 20 / 0.25 | Same-group heading alignment. |
| `flock_cohesion_radius` / `weight` | 24 / 0.12 | Same-group gathering. Lower this to keep the flock loose. |
| `flock_loiter_radius_min` / `max` | 7 / 16 | Orbit size around perches/chunks. |
| `inter_flock_separation_radius` / `weight` | 32 / 2.5 | Repulsion between different groups. |
| `inter_flock_spook_radius` / `duration` | 18 / 2 | Distance/duration at which different groups spook each other. |

The first leader created for an emitter copies these values; it refreshes them
once per second, so tuning a placed emitter while the game is running takes
effect without a reload. If several emitters share a `flock_group`, each emitter
still owns one leader and its own tuning; keep their Flock values similar for a
coherent group.

To create multiple flocks, give the emitters different `flock_group` names. The
director assigns one particle visibility layer per group, and each group's
leaders cull-mask their attractors to that layer. Same-group leaders align and
cohere; different groups only repel and spook, so they cannot merge into one
blob.

## Runtime flow

1. Each placed `FalseBoidEmitter` emits world-space particles at its own
   position (`emission_height = 2 m`). The first emitter creates a shared
   `FalseBoidDirector`, which creates one `FalseBoidFlock` leader per emitter
   (up to 10) and assigns each `flock_group` its own particle layer.
2. Each leader is a boid **and a visible bird sprite**: it copies its emitter's
   **Flock** exports (attractor, speed limits, steer strength,
   separation/alignment/cohesion, loiter radii and inter-flock values) and
   refreshes them once per second. It steers towards its target with
   `flight_speed` (default 7.5 m/s), never drops below `min_flight_speed`
   (5 m/s), adds same-group separation/alignment/cohesion, and applies only
   inter-flock repulsion to leaders in other groups. Its wings flap, it bobs,
   and it mirrors left/right with the camera just like the promoted birds. When
   it reaches a target it **circles** it at a random loiter radius (7-16 m by
   default) instead of stopping. A loiter timer then sends it to the next
   target.
3. Targets are perches, active chunks (`highest_block_y + 18...35`, random X/Z
   inside the chunk, decaying recent-chunk cost), and - with `hotspot_chance` -
   the densest nearby leader cluster. Leaders are also held above
   `terrain + min_ground_clearance` (9 m).
4. While a leader circles above a `FalseBoidPerch`, it promotes
   `perch_spawn_batch` birds every `perch_spawn_interval` until the perch or the
   global 20-bird cap is full. Each new bird is spawned at a **sampled dense
   point in the particle cloud** (not at the leader point), fades and scales in,
   and is given the leader's current velocity so it starts moving with the
   flock.
5. Promoted birds fly as boids: separation from every nearby bird, alignment
   and cohesion with the birds that are in flight, then a short direct settle
   over the last 2 m so they do not orbit the branch. They land exactly on
   their perch slot.
6. Perched birds have life: they breathe, hop, and occasionally flutter. After
   a random 7-18 s dwell they take off on their own (or immediately if the
   player comes within `flee_radius`). They fly to a freshly sampled dense
   cloud point, fade out over `vanish_duration`, and release their slot.
7. When the player comes within `flee_radius` of a perch, its birds go
   `PERCHED -> ALERT (0.25 s) -> FLEEING`, fly to the densest cloud point near
   the flock, and vanish into it.
8. Leaders keep moving between perches and active chunks. The director creates
   or deletes leaders as the emitter count changes:
   `leaders = min(emitters, 10)`, one per emitter. Leaders in the same
   `flock_group` cooperate; different groups repel and spook.
9. **Migration.** Every 30-55 s the director starts a 16-26 s migration window.
   It picks the active chunk farthest from the flock centroid and sends every
   leader there. Different flock groups get separate offsets on a
   `migration_group_spread` circle rather than one shared point. Leaders drop
   local perching during the window, and each leader's attractor grows by the
   migration multipliers from its own tuned base. When the window ends, normal
   perching and exploration resume.

The burst is capped globally, not just per emitter: promoted birds join the
`false_boid_perched` group, so multiple leaders/emitters cannot exceed 20 active
perched/flying birds at once.

## Facing direction

The bird sheet is a side-view silhouette (beak on the left). Promoted
`FalseBoid` sprites use a Cosy Critters-style relative-direction test: the
horizontal velocity is projected onto the camera's right vector, and the sprite
is mirrored when it is travelling towards screen-right. A small deadband stops
it flickering when a bird flies straight at or away from the camera. Perched
birds keep a `_facing` yaw, look around while resting, and face the player
during the alert state. Flight also updates the node yaw correctly
(`atan2(-vx, -vz)`), so switching away from billboarding later will not require
another pass.

The emitted GPU particle cloud cannot mirror per bird: its draw pass always
billboards to the camera and Godot does not expose per-particle velocity to the
draw shader. Instead each `FalseBoidEmitter` keeps a normal and a horizontally
mirrored draw pass and switches between them every 0.2 s based on the director's
average leader heading relative to the camera (with a 0.5 s hold to stop a
circling flock flickering). During migration this makes the whole cloud face
the travel direction; during local swarming it is a best-effort average. The
promoted birds retain accurate per-bird facing.

The promoted birds, leader sprite, and particle draw material remain **shaded**,
so they pick up the world sun/ambient. The texture is a dark silhouette; under
bright daylight the lit result can appear lighter/whitish. That is the intended
shaded look; switching those materials to unshaded is the fallback if a
consistent silhouette is preferred later.

Placeable perches can be removed at runtime. The flock keeps a cached perch list
between its 1 Hz scans, so it prunes freed entries (`_prune_perches`) before any
typed loop; otherwise GDScript raises `Trying to assign invalid previously
freed instance` when a perch is deleted and the player-reaction pass runs in the
same second.

There is **no player-following particle collision box** any more. The old
`GPUParticlesCollisionBox3D` at world `y = 0` tracked the player's X/Z and made
the cloud snap upwards as the player walked; particles now use no collision
mode, near-zero gravity, and fly high enough not to need it.

## Cloud density sampling

GPU particle positions cannot be read back, so `FalseBoidFlock` models the
density field from the things that create and gather the cloud:

- the leader's own attractor (the strongest sink),
- every emitter (weighted by its particle count),
- every other leader's attractor.

`find_cloud_hideout(from, radius)` samples points around the flock's own cloud
(plus a few around other anchors), scores them with this model, subtracts a
small travel cost, and returns the densest nearby point. Promotion spawns the
bird there; demotion flies the bird there. This is what makes the appearance
and disappearance read as joining/leaving the flock rather than popping at the
leader.

## Files and scenes

| File | Role |
|---|---|
| `scripts/world/false_boid_emitter.gd` | Placeable world-space particle source; creates the shared director |
| `scripts/world/false_boid_director.gd` | Leader lifecycle (`min(emitters, 10)`), crowd repulsion, periodic map-wide migration |
| `scripts/world/false_boid_flock.gd` | Boid leader steering/loitering, reduced attractor, migration mode, density sampler, perch selection, chunk exploration, promotion cap |
| `scripts/world/false_boid.gd` | Boid flight, direction-facing sprite, cloud fade-in/out, perch dwell, self-departure, slot release |
| `scripts/world/false_boid_perch.gd` | Perch marker with capacity and ring slots |
| `scenes/placeables/sim/sim_false_boid_emitter.tscn` | **Placeable** bird emitter with a feeder mesh; appears in the Placeables inventory automatically |
| `scenes/placeables/sim/sim_false_boid_perch.tscn` | **Placeable** perch marker with a visible disc; capacity 5 |
| `Maps/test.tscn` | Three placed emitters (`(8,0,8)`, `(-10,2,10)`, `(20,2,12)`) and four placed perches |

The particle draw pass uses the full 48x16 `textures/particles/Boid.png` sheet
with `particles_anim_h_frames = 3`, `BILLBOARD_PARTICLES`, and normal per-pixel
shading. Promoted birds use the same sheet through a `Sprite3D` with
`hframes = 3`, so both stages share the same animation.

## Tuning

### Emitter

| Export | Default | Effect |
|---|---:|---|
| `particle_count` | 500 | Particles per placed emitter |
| `particle_size` | 1.0 m | Full billboard size; scale variance 0.5-1.5 |
| `particle_lifetime` | 90.0 | Turnover; long enough for a real flock to form |
| `emission_height` | 2.0 m | Cloud origin above the feeder; keeps birds off the ground |
| `emission_radius` | 2.5 m | Ring emission size |
| `velocity_min/max` | 3.0 / 6.0 | Initial motion, matched to the older implementation |
| `turbulence` | 6.0 | Noise strength; previously too weak to look alive |
| `radial_accel_min/max` | 1.5 / 7.0 | Constant swirl out from the emitter |
| `tangential_accel_min/max` | 1.5 / 6.0 | Constant swirl around the emitter |
| Wing animation | 210-280 FPS | Fast, continuous flapping |
| Damping | 0-0.05 | Almost none, so birds never drift to a stop |
| Collision | Disabled | No player-following collision box |

### Leader / flock

| Export | Default | Effect |
|---|---:|---|
| `attractor_radius` | 180.0 | Much smaller than the old map-scale 600 |
| `attractor_strength` | 12.0 | Much weaker than the old 30 |
| `attractor_attenuation` | 0.6 | Slower falloff |
| `flight_altitude` | 9.0 | Leader height above a perch target |
| `flight_speed` | 7.5 | Leader cruise speed |
| `min_flight_speed` | 5.0 | Leader never flies slower |
| `max_flight_speed` | 12.0 | Leader cap (and cap while retreating) |
| `steer_strength` | 15.0 | Leader steering acceleration, m/s^2 |
| `loiter_radius_min/max` | 5.0 / 12.0 | Orbit radius once at a target |
| `min_ground_clearance` | 9.0 | Leader height above terrain |
| `separation_radius/weight` | 7.0 / 1.1 | Leader-leader spacing |
| `alignment_radius/weight` | 18.0 / 0.45 | Leader velocity matching |
| `cohesion_radius/weight` | 26.0 / 0.3 | Leader flock pull |
| `perch_loiter_time_min/max` | 6.0 / 11.0 | Time spent circling a perch |
| `max_perched_birds` | 20 | Hard global promotion cap |
| `perch_spawn_batch` | 2 | Birds promoted per interval |
| `perch_spawn_interval` | 0.45 | Promotion cadence |
| `flee_radius` | 5.5 | Player distance that startles a perch |
| `explore_chance` | 0.55 | Chance to explore instead of perch |
| `chunk_clearance_min/max` | 18.0 / 35.0 | Target height above the highest block |
| `explore_dwell_min/max` | 4.0 / 9.0 | Time spent circling an exploration target |
| `chunk_cost_decay_per_sec` | 0.12 | How fast recently explored chunks become attractive again |
| `hotspot_chance` | 0.22 | Chance to fly toward the densest leader cluster |
| `repel_strength` | 25.0 | Negative strength when a leader is crowded |
| `MAX_LEADERS` (director) | 10 | One leader per emitter, capped at 10 |
| `crowd_threshold` / `crowd_radius` | 3 / 5.0 m | Leader cluster that triggers repulsion (kept below the boid separation radius so normal flocks do not trigger it) |
| `migration_attractor_radius_mult` | 2.2 | Attractor radius multiplier while migrating |
| `migration_attractor_strength_mult` | 1.6 | Attractor strength multiplier while migrating |
| `migration_loiter_time` | 3.0 | Time spent circling the migration waypoint |
| `leader_sprite_pixel_size` | 0.07 | Leader billboard size (slightly larger than the promoted birds) |
| `leader_wing_fps` | 15.0 | Leader wing animation rate |
| `leader_sprite_bob` | 0.1 m | Leader visual bob |

### Migration (director)

| Export | Default | Effect |
|---|---:|---|
| `migration_enabled` | true | Master toggle |
| `migration_interval_min/max` | 30 / 55 s | Time between migration windows |
| `migration_duration_min/max` | 16 / 26 s | How long the flock keeps travelling/circling the far waypoint |
| `migration_min_distance` | 42 m | Preferred travel distance; on small maps the farthest available chunk is still used |
| `migration_clearance_min/max` | 20 / 36 m | Waypoint height above the chosen chunk's highest block |
| `migration_distance_jitter` | 10 m | Random score bonus so the same corner is not always chosen |

### Promoted bird

| Export | Default | Effect |
|---|---:|---|
| `flight_speed` | set to `max(leader * 1.6, 10)` = 12 | Flight speed to the perch |
| `flee_speed` | 12.0 | Speed when leaving the perch |
| `steer_strength` | 24.0 | Bird steering acceleration, m/s^2 |
| `separation_radius/weight` | 1.8 / 1.0 | Bird-bird spacing |
| `alignment_radius/weight` | 6.0 / 0.55 | Matching nearby fliers |
| `cohesion_radius/weight` | 10.0 / 0.35 | Joining the flying group |
| `perch_dwell_min/max` | 7.0 / 18.0 | Rest time before self-departure |
| `alert_duration` | 0.25 | Startle reaction time |
| `appear_duration` | 0.8 | Fade/scale-in inside the cloud |
| `vanish_duration` | 0.5 | Fade/scale-out inside the cloud |
| `vanish_distance` | 4.5 | Distance from the cloud point at which fading starts |
| `hideout_search_radius` | 110.0 | How far a departing bird will look for a dense cloud spot |
| `max_leave_time` | 14.0 | Safety cap; fading starts after 60% of it regardless |
| `FalseBoidPerch.capacity` | 5 (placeable/test perches) | Slots per perch |

Emitters and perches are placeable scenes. Drop `sim_false_boid_emitter` and
`sim_false_boid_perch` from the Placeables inventory. Emitters are independent
sources; the director creates one leader/attractor per emitter (up to 10), so a
map with several emitters produces several interacting flocks over the same
particle cloud. Perches are discovered through the `false_boid_perches` group;
no nav mesh or collision is required.

## Current limitations

- The **emitted particle cloud** is still a GPU particle system, not a
  per-particle CPU boid simulation. The true boid steering covers the leaders
  and the promoted `FalseBoid` sprites. Particles get their motion from the
  emitter material, turbulence, and the leader attractor.
- Particle sprites cannot be mirrored per bird: the draw pass is a camera
  billboard and the draw shader has no per-particle velocity. Emitters mirror
  the **whole cloud** based on the flock's average heading, so the cloud reads
  as directional in flight/migration, while the promoted birds have accurate
  per-bird facing.
- The density sampler is an analytic model of the cloud (attractors + emitters);
  GPU particle positions themselves cannot be read back.
- Migration picks the farthest **active/loaded chunk**. On a map whose loaded
  area is small, the travel distance is naturally limited by that area.
- There is one leader per emitter up to 10; leaders share perches and the global
  20-bird promotion cap, but do not explicitly coordinate targets beyond the
  hotspot/cohesion behaviour.
- `follow_player` moves the attractor/leader, not the emitter itself; perching
  is disabled while it is on.
- Perched birds are silhouettes using the same 3-frame flight sheet; there is
  no dedicated perched pose, pecking, or landing animation.
- Promoted birds do not collide with the world or each other. They are visual
  ambient agents with boid steering, not full NPCs.
- No smoke/fire/hazard response. Player proximity is the only flight trigger.

## Possible next steps

- **Per-particle boids:** move the cloud to a CPU/compute simulation only if the
  visual difference justifies the cost. The leader and sprite boids already
  cover the close-up behaviour.
- **Dedicated perched art:** a perched frame or separate silhouette sheet would
  make the promotion/demotion even less obvious.
- **Wind and hazards:** let wind, smoke, and fire bias the boid steering fields.
