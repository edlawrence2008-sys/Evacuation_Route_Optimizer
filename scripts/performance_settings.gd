extends Node

## Global performance/quality settings with persistence.
##
## Autoloaded so the pause menu, console and startup can all read/write the same
## values. Presets are tuned so the Medium default is comfortable on integrated
## laptop GPUs; Low is the safety net for very old machines.

const CONFIG_PATH := "user://settings.cfg"
const FOLIAGE_SWAY_SCRIPT = preload("res://scripts/foliage_sway.gd")

const QUALITY_NAMES: Array[String] = ["Low", "Medium", "High"]
const RENDER_SCALES: Array[float] = [0.5, 0.65, 0.8, 1.0]
const MESH_RADII: Array[int] = [4, 6, 8, 12, 16, 24, 32, 48, 64]
const AGENT_CAPS: Array[int] = [40, 80, 120, 200, 300, 500, 600, 700, 1000]
const VOLUMES: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]
const MUSIC_VOLUMES: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]
const FPS_CAPS: Array[int] = [30, 60, 0]
const VIEW_ROLLS: Array[float] = [0.0, 0.75, 1.5, 2.5]
const VIEW_ROLL_NAMES: Array[String] = ["Off", "Low", "Medium", "High"]
const SKY_TIME_NAMES: Array[String] = ["Cycle", "Dawn", "Day", "Dusk", "Night"]
const SKY_SPEEDS: Array[float] = [0.5, 1.0, 2.0, 4.0]
const CLOUD_SPEEDS: Array[float] = [0.35, 0.7, 1.0, 1.5]
const CLOUD_COVERAGES: Array[float] = [0.18, 0.26, 0.32, 0.42]
const STORM_STRENGTHS: Array[float] = [0.4, 0.7, 1.0, 1.5]
const STORM_STRENGTH_NAMES: Array[String] = ["Low", "Medium", "High", "Severe"]
const SHADOW_DISTANCES: Array[float] = [20.0, 40.0, 60.0, 90.0, 120.0, 160.0]
const FOLIAGE_SCALES: Array[float] = [0.5, 0.75, 1.0, 1.25]
const FOG_OFFSETS: Array[float] = [0.0, 8.0, 16.0, 24.0, 32.0, 48.0, 64.0]

## Structural physics tiers. Stability is independent of this: a world can
## compute support without ever collapsing. `Collapse` removes unsupported
## blocks; `Debris` also detaches disconnected islands as rigid bodies.
const PHYSICS_LEVELS: Array[String] = ["Off", "Collapse", "Debris"]

const WATER_FLOW_STEPS: Array[float] = [0.067, 0.1, 0.15, 0.22, 0.3]
const WATER_EQUALIZE_STEPS: Array[float] = [0.25, 0.5, 0.75, 1.0, 1.5]
const WATER_UPDATE_BUDGETS: Array[int] = [96, 192, 384, 512, 768, 1024]
const WATER_MESH_RATES: Array[float] = [0.033, 0.05, 0.08, 0.12, 0.2]
const WATER_WAVE_STEPS: Array[float] = [0.0625, 0.125, 0.25, 0.5]
const WATER_WAVE_SAMPLES: Array[int] = [4096, 8192, 12288, 32768]

signal settings_changed

var quality: int = 1
var render_scale: float = 0.8
var shadows: bool = true
var shadow_distance: float = 60.0
var ambient_occlusion: bool = false
var mesh_radius: int = 8
var load_radius: int = 20
var nav_radius: int = 4
var agent_cap: int = 120
var clouds: bool = true
var water_effects: bool = true
var master_volume: float = 0.8
## Background-music level, applied by MusicManager on top of its base volume.
var music_volume: float = 0.75
var max_fps: int = 60
## Camera view-roll strength, stored as an index into VIEW_ROLLS.
var view_roll_index: int = 1

# Sky / weather presentation. These are cosmetic and never affect simulation.
var sky_time_mode: int = 0
var sky_speed_index: int = 1
var sun_visible: bool = true
var moon_visible: bool = true
var rainbows: bool = true
var storm_flashes: bool = true
var storm_strength_index: int = 2
var fog_enabled: bool = false
var cloud_speed_index: int = 2
var cloud_coverage_index: int = 2
var foliage_scale: float = 1.0
## How far inside the rendered chunk ring the depth fog ends.
var fog_distance_offset: float = 16.0

# Water simulation tuning (also editable from the pause menu's Water tab).
var water_flow_interval: float = 0.15
var water_equalize_interval: float = 0.5
var water_update_budget: int = 384
var water_mesh_interval: float = 0.08
var water_waves: bool = true
var water_wave_step: float = 0.125
var water_wave_samples: int = 12288
var water_wake_style: int = 1
var water_splashes: bool = true
var water_surface_particles: bool = true

# Structural systems. Stability computes the per-cell support field; physics
# level decides what happens when a cell loses support.
var stability_enabled: bool = true
var physics_level: int = 1
var stability_debug: bool = false
## Restored by the Destruction toggle so turning collapse back on keeps the
## tier the player last chose in the Physics row.
var last_physics_level: int = 1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()
	call_deferred("apply_all")


func apply_preset(index: int, save: bool = true) -> void:
	quality = clampi(index, 0, QUALITY_NAMES.size() - 1)

	match quality:
		0:
			render_scale = 0.5
			shadows = false
			ambient_occlusion = false
			mesh_radius = 4
			load_radius = 12
			nav_radius = 3
			agent_cap = 40
			clouds = false
			water_effects = false
			foliage_scale = 0.5
			shadow_distance = 20.0
			max_fps = 30
		1:
			render_scale = 0.8
			shadows = true
			shadow_distance = 60.0
			ambient_occlusion = false
			mesh_radius = 8
			load_radius = 20
			nav_radius = 4
			agent_cap = 120
			clouds = true
			water_effects = true
			foliage_scale = 1.0
			shadow_distance = 60.0
			max_fps = 60
		_:
			render_scale = 1.0
			shadows = true
			ambient_occlusion = true
			mesh_radius = 16
			load_radius = 40
			nav_radius = 8
			agent_cap = 600
			clouds = true
			water_effects = true
			foliage_scale = 1.0
			shadow_distance = 120.0
			max_fps = 0

	_apply_water_preset(quality)
	_apply_physics_preset(quality)

	if save:
		save_settings()

	apply_all()


## Water-specific defaults for a quality preset. These are copied into the
## editable water settings so the Water tab and the presets stay in sync.
func _apply_water_preset(index: int) -> void:
	match clampi(index, 0, QUALITY_NAMES.size() - 1):
		0:
			water_flow_interval = 0.3
			water_equalize_interval = 1.0
			water_update_budget = 96
			water_mesh_interval = 0.12
			water_waves = true
			water_wave_step = 0.25
			water_wave_samples = 4096
			water_wake_style = 0
			water_splashes = false
			water_surface_particles = false
		1:
			water_flow_interval = 0.15
			water_equalize_interval = 0.5
			water_update_budget = 384
			water_mesh_interval = 0.08
			water_waves = true
			water_wave_step = 0.125
			water_wave_samples = 12288
			water_wake_style = 1
			water_splashes = true
			water_surface_particles = true
		_:
			water_flow_interval = 0.1
			water_equalize_interval = 0.4
			water_update_budget = 768
			water_mesh_interval = 0.05
			water_waves = true
			water_wave_step = 0.0625
			water_wave_samples = 32768
			water_wake_style = 1
			water_splashes = true
			water_surface_particles = true


## Structural defaults for a quality preset. Low skips collapse, Medium removes
## unsupported blocks, High also spawns island debris.
func _apply_physics_preset(index: int) -> void:
	stability_enabled = true
	stability_debug = false
	physics_level = clampi(index, 0, PHYSICS_LEVELS.size() - 1)


func apply_all() -> void:
	var tree := get_tree()
	if tree == null:
		return

	if tree.root != null:
		tree.root.scaling_3d_scale = clampf(render_scale, 0.4, 1.0)

	Engine.max_fps = maxi(max_fps, 0)

	if master_volume <= 0.0:
		AudioServer.set_bus_volume_db(0, -80.0)
	else:
		AudioServer.set_bus_volume_db(
			0,
			linear_to_db(clampf(master_volume, 0.0001, 1.0))
		)

	GlobalData.global_unit_cap = agent_cap

	var grid := tree.get_first_node_in_group("grid_map")
	if grid != null:
		grid.baked_ao_enabled = ambient_occlusion

		if "stability_enabled" in grid:
			grid.stability_enabled = stability_enabled
		if "physics_level" in grid:
			grid.physics_level = physics_level
		if "stability_debug" in grid:
			grid.stability_debug = stability_debug

		var mesher = grid.get_mesher()
		if mesher != null:
			mesher.build_budget_usec = (
				2000 if quality == 0 else (3000 if quality == 1 else 4000)
			)

		var water = grid.get_water_system()
		if water != null:
			var waves_changed: bool = (
				not is_equal_approx(water.wave_step, water_wave_step)
				or water.wave_max_samples != water_wave_samples
				or water.wake_style != water_wake_style
			)
			water.flow_interval = water_flow_interval
			water.global_equalize_interval = water_equalize_interval
			water.max_updates_per_tick = water_update_budget
			water.mesh_rebuild_interval = water_mesh_interval
			water.wave_step = water_wave_step
			water.wave_max_samples = water_wave_samples
			water.wake_style = water_wake_style
			water.waves_enabled = water_effects and water_waves
			water.splashes_enabled = water_effects and water_splashes
			water.surface_particles_enabled = (
				water_effects and water_surface_particles
			)
			if waves_changed and water.has_method("refresh_wave_settings"):
				water.refresh_wave_settings()

	var streamer := tree.get_first_node_in_group("chunk_streamer")
	if streamer != null:
		# Load exactly around what is drawn (plus one ring for neighbour
		# meshing). Keeping the old larger preset load radius made low draw
		# distance settings still load a huge ring of chunks.
		var effective_load: int = maxi(6, mesh_radius + 2)
		streamer.load_radius_chunks = effective_load
		streamer.unload_radius_chunks = effective_load + 2
		streamer.mesh_radius_chunks = mesh_radius
		streamer.nav_radius_chunks = nav_radius
		streamer.max_loaded_chunks = maxi(
			1024 if quality == 0 else (2048 if quality == 1 else 4096),
			effective_load * effective_load * 4
		)
		streamer.max_chunk_loads_per_frame = 2 if quality == 0 else (3 if quality == 1 else 4)
		streamer.max_chunk_unloads_per_frame = 6 if quality == 0 else 8
		streamer.load_budget_usec = 1500 if quality == 0 else (2000 if quality == 1 else 2500)

		if streamer.has_method("refresh_streaming"):
			streamer.refresh_streaming()

	var player = tree.get_first_node_in_group("Player")
	if player != null:
		var camera = player.get_node_or_null("head/CameraSmooth/Camera3D") as Camera3D
		if camera != null:
			camera.far = maxf(1024.0, mesh_radius * 16.0 + 64.0)
		if "view_roll" in player:
			player.view_roll = view_roll_degrees()

	var sky_settings := {
		"time_mode": sky_time_mode,
		"cycle_speed": SKY_SPEEDS[clampi(sky_speed_index, 0, SKY_SPEEDS.size() - 1)],
		"sun_disc": sun_visible,
		"moon_disc": moon_visible,
		"rainbow": rainbows,
		"storm_flashes": storm_flashes,
		"storm_strength": STORM_STRENGTHS[
			clampi(storm_strength_index, 0, STORM_STRENGTHS.size() - 1)
		],
		"fog": fog_enabled,
		"fog_distance": maxf(
			32.0,
			float(mesh_radius) * 16.0 - fog_distance_offset
		),
	}
	for controller in tree.get_nodes_in_group("CycleControllers"):
		if controller.has_method("apply_sky_settings"):
			controller.apply_sky_settings(sky_settings)

	var cloud_layer := tree.get_first_node_in_group("minecraft_clouds")
	if cloud_layer != null:
		cloud_layer.visible = clouds

		if "speed_scale" in cloud_layer:
			cloud_layer.set(
				"speed_scale",
				CLOUD_SPEEDS[
					clampi(cloud_speed_index, 0, CLOUD_SPEEDS.size() - 1)
				]
			)

		if cloud_layer.has_method("set_coverage"):
			var coverage: float = CLOUD_COVERAGES[
				clampi(cloud_coverage_index, 0, CLOUD_COVERAGES.size() - 1)
			]
			cloud_layer.call("set_coverage", coverage, coverage * 0.72)

	# Foliage lives inside the streamed chunk ring. Scale its cutoff with the
	# actual chunk draw distance so foliage cannot outlive its ground.
	var foliage_distance: float = maxf(
		16.0,
		float(mesh_radius) * 16.0 * 0.9 * foliage_scale
	)
	FOLIAGE_SWAY_SCRIPT.max_view_distance = foliage_distance
	FOLIAGE_SWAY_SCRIPT.mid_view_distance = foliage_distance * 0.5
	for plant in tree.get_nodes_in_group("foliage"):
		FOLIAGE_SWAY_SCRIPT.apply_distance_settings(
			plant,
			foliage_distance,
			foliage_distance * 0.5
		)

	for node in tree.get_nodes_in_group("sun_light"):
		if node is DirectionalLight3D:
			node.shadow_enabled = shadows
			node.directional_shadow_max_distance = shadow_distance

	settings_changed.emit()


func cycle_quality() -> void:
	apply_preset((quality + 1) % QUALITY_NAMES.size())


func cycle_render_scale() -> void:
	render_scale = _next_float(RENDER_SCALES, render_scale)
	_commit()


func cycle_mesh_radius() -> void:
	mesh_radius = _next_int(MESH_RADII, mesh_radius)
	_commit()


func cycle_agent_cap() -> void:
	agent_cap = _next_int(AGENT_CAPS, agent_cap)
	_commit()


func cycle_volume() -> void:
	master_volume = _next_float(VOLUMES, master_volume)
	_commit()


func cycle_music_volume() -> void:
	music_volume = _next_float(MUSIC_VOLUMES, music_volume)
	_commit()


func cycle_fps() -> void:
	max_fps = _next_int(FPS_CAPS, max_fps)
	_commit()


func view_roll_degrees() -> float:
	return VIEW_ROLLS[clampi(view_roll_index, 0, VIEW_ROLLS.size() - 1)]


func view_roll_name() -> String:
	return VIEW_ROLL_NAMES[clampi(view_roll_index, 0, VIEW_ROLL_NAMES.size() - 1)]


func cycle_view_roll() -> void:
	view_roll_index = (view_roll_index + 1) % VIEW_ROLLS.size()
	_commit()


func toggle_shadows() -> void:
	shadows = not shadows
	_commit()


func cycle_shadow_distance() -> void:
	shadow_distance = _next_float(SHADOW_DISTANCES, shadow_distance)
	_commit()


func cycle_foliage_scale() -> void:
	foliage_scale = _next_float(FOLIAGE_SCALES, foliage_scale)
	_commit()


func cycle_fog_offset() -> void:
	fog_distance_offset = _next_float(FOG_OFFSETS, fog_distance_offset)
	_commit()


func toggle_occlusion() -> void:
	ambient_occlusion = not ambient_occlusion
	_commit()


func toggle_clouds() -> void:
	clouds = not clouds
	_commit()


func cycle_sky_time() -> void:
	sky_time_mode = (sky_time_mode + 1) % SKY_TIME_NAMES.size()
	_commit()


func toggle_sun_disc() -> void:
	sun_visible = not sun_visible
	_commit()


func toggle_moon_disc() -> void:
	moon_visible = not moon_visible
	_commit()


func toggle_rainbows() -> void:
	rainbows = not rainbows
	_commit()


func toggle_storm_flashes() -> void:
	storm_flashes = not storm_flashes
	_commit()


func toggle_fog() -> void:
	fog_enabled = not fog_enabled
	_commit()


func cycle_storm_strength() -> void:
	storm_strength_index = (storm_strength_index + 1) % STORM_STRENGTHS.size()
	_commit()


func cycle_sky_speed() -> void:
	sky_speed_index = (sky_speed_index + 1) % SKY_SPEEDS.size()
	_commit()


func cycle_cloud_speed() -> void:
	cloud_speed_index = (cloud_speed_index + 1) % CLOUD_SPEEDS.size()
	_commit()


func cycle_cloud_coverage() -> void:
	cloud_coverage_index = (cloud_coverage_index + 1) % CLOUD_COVERAGES.size()
	_commit()


func reset_sky_clouds() -> void:
	sky_time_mode = 0
	sky_speed_index = 1
	sun_visible = true
	moon_visible = true
	rainbows = true
	storm_flashes = true
	storm_strength_index = 2
	fog_enabled = false
	fog_distance_offset = 16.0
	cloud_speed_index = 2
	cloud_coverage_index = 2
	clouds = true
	_commit()


func toggle_water() -> void:
	water_effects = not water_effects
	_commit()


func cycle_water_flow() -> void:
	water_flow_interval = _next_float(WATER_FLOW_STEPS, water_flow_interval)
	_commit()


func cycle_water_equalize() -> void:
	water_equalize_interval = _next_float(
		WATER_EQUALIZE_STEPS,
		water_equalize_interval
	)
	_commit()


func cycle_water_budget() -> void:
	water_update_budget = _next_int(WATER_UPDATE_BUDGETS, water_update_budget)
	_commit()


func cycle_water_mesh() -> void:
	water_mesh_interval = _next_float(WATER_MESH_RATES, water_mesh_interval)
	_commit()


func cycle_water_wave_detail() -> void:
	water_wave_step = _next_float(WATER_WAVE_STEPS, water_wave_step)
	_commit()


func cycle_water_wave_cap() -> void:
	water_wave_samples = _next_int(WATER_WAVE_SAMPLES, water_wave_samples)
	_commit()


func toggle_water_waves() -> void:
	water_waves = not water_waves
	_commit()


func toggle_water_splashes() -> void:
	water_splashes = not water_splashes
	_commit()


func toggle_water_surface_particles() -> void:
	water_surface_particles = not water_surface_particles
	_commit()


func cycle_water_wake_style() -> void:
	water_wake_style = (water_wake_style + 1) % 2
	_commit()


func reset_water_settings() -> void:
	_apply_water_preset(quality)
	_commit()


func stability_name() -> String:
	return "On" if stability_enabled else "Off"


func destruction_name() -> String:
	return physics_level_name()


func physics_level_name() -> String:
	return PHYSICS_LEVELS[clampi(physics_level, 0, PHYSICS_LEVELS.size() - 1)]


func stability_debug_name() -> String:
	return "On" if stability_debug else "Off"


func destruction_enabled() -> bool:
	return stability_enabled and physics_level > 0


func toggle_stability() -> void:
	stability_enabled = not stability_enabled
	_commit()


func toggle_destruction() -> void:
	if physics_level > 0:
		last_physics_level = physics_level
		physics_level = 0
	else:
		physics_level = clampi(last_physics_level, 1, PHYSICS_LEVELS.size() - 1)
		stability_enabled = true
	_commit()


func cycle_physics_level() -> void:
	# Collapse needs the support field; turning destruction on turns stability
	# back on rather than silently doing nothing.
	physics_level = (physics_level + 1) % PHYSICS_LEVELS.size()
	if physics_level > 0:
		last_physics_level = physics_level
		stability_enabled = true
	_commit()


func toggle_stability_debug() -> void:
	stability_debug = not stability_debug
	_commit()


func quality_name() -> String:
	return QUALITY_NAMES[quality]


func render_scale_name() -> String:
	return "%d%%" % roundi(render_scale * 100.0)


func mesh_radius_name() -> String:
	return "%d chunks / %d m" % [mesh_radius, mesh_radius * 16]


func agent_cap_name() -> String:
	return str(agent_cap)


func volume_name() -> String:
	return "%d%%" % roundi(master_volume * 100.0)


func music_volume_name() -> String:
	return "%d%%" % roundi(music_volume * 100.0)


func fps_name() -> String:
	return "Unlimited" if max_fps <= 0 else str(max_fps)


func shadows_name() -> String:
	return "On" if shadows else "Off"


func shadow_distance_name() -> String:
	return "%d m" % roundi(shadow_distance)


func foliage_scale_name() -> String:
	return "%d%%" % roundi(foliage_scale * 100.0)


func fog_offset_name() -> String:
	return "%d m" % roundi(fog_distance_offset)


func occlusion_name() -> String:
	return "On" if ambient_occlusion else "Off"


func clouds_name() -> String:
	return "On" if clouds else "Off"


func sky_time_name() -> String:
	return SKY_TIME_NAMES[clampi(sky_time_mode, 0, SKY_TIME_NAMES.size() - 1)]


func sun_disc_name() -> String:
	return "On" if sun_visible else "Off"


func moon_disc_name() -> String:
	return "On" if moon_visible else "Off"


func rainbows_name() -> String:
	return "On" if rainbows else "Off"


func storm_flashes_name() -> String:
	return "On" if storm_flashes else "Off"


func fog_name() -> String:
	return "On" if fog_enabled else "Off"


func storm_strength_name() -> String:
	return STORM_STRENGTH_NAMES[
		clampi(storm_strength_index, 0, STORM_STRENGTH_NAMES.size() - 1)
	]


func sky_speed_name() -> String:
	return "%.1fx" % SKY_SPEEDS[
		clampi(sky_speed_index, 0, SKY_SPEEDS.size() - 1)
	]


func cloud_speed_name() -> String:
	return "%.2fx" % CLOUD_SPEEDS[
		clampi(cloud_speed_index, 0, CLOUD_SPEEDS.size() - 1)
	]


func cloud_coverage_name() -> String:
	return "%d%%" % roundi(
		100.0 * CLOUD_COVERAGES[
			clampi(cloud_coverage_index, 0, CLOUD_COVERAGES.size() - 1)
		]
	)


func water_name() -> String:
	return "On" if water_effects else "Off"


func water_flow_name() -> String:
	return "%.2f s" % water_flow_interval


func water_equalize_name() -> String:
	return "%.2f s" % water_equalize_interval


func water_budget_name() -> String:
	return str(water_update_budget)


func water_mesh_rate_name() -> String:
	return "%d Hz" % roundi(1.0 / maxf(water_mesh_interval, 0.001))


func water_wave_detail_name() -> String:
	return "%.2f m" % water_wave_step


func water_wave_cap_name() -> String:
	return str(water_wave_samples)


func water_waves_name() -> String:
	return "On" if water_waves else "Off"


func water_splashes_name() -> String:
	return "On" if water_splashes else "Off"


func water_surface_particles_name() -> String:
	return "On" if water_surface_particles else "Off"


func water_wake_name() -> String:
	return "Vivid" if water_wake_style == 1 else "Soft"


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("preset", "quality", quality)
	config.set_value("graphics", "render_scale", render_scale)
	config.set_value("graphics", "shadows", shadows)
	config.set_value("graphics", "shadow_distance", shadow_distance)
	config.set_value("graphics", "ambient_occlusion", ambient_occlusion)
	config.set_value("graphics", "foliage_scale", foliage_scale)
	config.set_value("graphics", "mesh_radius", mesh_radius)
	config.set_value("graphics", "load_radius", load_radius)
	config.set_value("graphics", "nav_radius", nav_radius)
	config.set_value("graphics", "clouds", clouds)
	config.set_value("graphics", "water_effects", water_effects)
	config.set_value("sky", "time_mode", sky_time_mode)
	config.set_value("sky", "speed_index", sky_speed_index)
	config.set_value("sky", "sun_visible", sun_visible)
	config.set_value("sky", "moon_visible", moon_visible)
	config.set_value("sky", "rainbows", rainbows)
	config.set_value("sky", "storm_flashes", storm_flashes)
	config.set_value("sky", "storm_strength_index", storm_strength_index)
	config.set_value("sky", "fog", fog_enabled)
	config.set_value("sky", "fog_offset", fog_distance_offset)
	config.set_value("clouds", "speed_index", cloud_speed_index)
	config.set_value("clouds", "coverage_index", cloud_coverage_index)
	config.set_value("water", "flow_interval", water_flow_interval)
	config.set_value("water", "equalize_interval", water_equalize_interval)
	config.set_value("water", "update_budget", water_update_budget)
	config.set_value("water", "mesh_interval", water_mesh_interval)
	config.set_value("water", "waves", water_waves)
	config.set_value("water", "wave_step", water_wave_step)
	config.set_value("water", "wave_samples", water_wave_samples)
	config.set_value("water", "wake_style", water_wake_style)
	config.set_value("water", "splashes", water_splashes)
	config.set_value("water", "surface_particles", water_surface_particles)
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("structure", "stability", stability_enabled)
	config.set_value("structure", "physics_level", physics_level)
	config.set_value("structure", "debug", stability_debug)
	config.set_value("system", "agent_cap", agent_cap)
	config.set_value("system", "max_fps", max_fps)
	config.set_value("camera", "view_roll", view_roll_index)
	config.save(CONFIG_PATH)


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		apply_preset(1, false)
		return

	quality = int(config.get_value("preset", "quality", 1))
	var has_water_settings := config.has_section_key("water", "flow_interval")
	render_scale = float(config.get_value("graphics", "render_scale", 0.8))
	shadows = bool(config.get_value("graphics", "shadows", true))
	shadow_distance = float(config.get_value("graphics", "shadow_distance", 60.0))
	ambient_occlusion = bool(config.get_value("graphics", "ambient_occlusion", false))
	foliage_scale = float(config.get_value("graphics", "foliage_scale", 1.0))
	mesh_radius = int(config.get_value("graphics", "mesh_radius", 8))
	load_radius = int(config.get_value("graphics", "load_radius", 20))
	nav_radius = int(config.get_value("graphics", "nav_radius", 4))
	clouds = bool(config.get_value("graphics", "clouds", true))
	water_effects = bool(config.get_value("graphics", "water_effects", true))
	sky_time_mode = clampi(
		int(config.get_value("sky", "time_mode", 0)),
		0,
		SKY_TIME_NAMES.size() - 1
	)
	sky_speed_index = clampi(
		int(config.get_value("sky", "speed_index", 1)),
		0,
		SKY_SPEEDS.size() - 1
	)
	sun_visible = bool(config.get_value("sky", "sun_visible", true))
	moon_visible = bool(config.get_value("sky", "moon_visible", true))
	rainbows = bool(config.get_value("sky", "rainbows", true))
	storm_flashes = bool(config.get_value("sky", "storm_flashes", true))
	storm_strength_index = clampi(
		int(config.get_value("sky", "storm_strength_index", 2)),
		0,
		STORM_STRENGTHS.size() - 1
	)
	fog_enabled = bool(config.get_value("sky", "fog", false))
	fog_distance_offset = float(
		config.get_value("sky", "fog_offset", 16.0)
	)
	cloud_speed_index = clampi(
		int(config.get_value("clouds", "speed_index", 2)),
		0,
		CLOUD_SPEEDS.size() - 1
	)
	cloud_coverage_index = clampi(
		int(config.get_value("clouds", "coverage_index", 2)),
		0,
		CLOUD_COVERAGES.size() - 1
	)
	water_flow_interval = float(config.get_value("water", "flow_interval", water_flow_interval))
	water_equalize_interval = float(config.get_value("water", "equalize_interval", water_equalize_interval))
	water_update_budget = int(config.get_value("water", "update_budget", water_update_budget))
	water_mesh_interval = float(config.get_value("water", "mesh_interval", water_mesh_interval))
	water_waves = bool(config.get_value("water", "waves", water_waves))
	water_wave_step = float(config.get_value("water", "wave_step", water_wave_step))
	water_wave_samples = int(config.get_value("water", "wave_samples", water_wave_samples))
	water_wake_style = int(config.get_value("water", "wake_style", water_wake_style))
	water_splashes = bool(config.get_value("water", "splashes", water_splashes))
	water_surface_particles = bool(config.get_value("water", "surface_particles", water_surface_particles))

	if not has_water_settings:
		_apply_water_preset(quality)
	master_volume = float(config.get_value("audio", "master_volume", 0.8))
	music_volume = float(config.get_value("audio", "music_volume", 0.75))
	stability_enabled = bool(
		config.get_value("structure", "stability", stability_enabled)
	)
	physics_level = clampi(
		int(config.get_value("structure", "physics_level", physics_level)),
		0,
		PHYSICS_LEVELS.size() - 1
	)
	stability_debug = bool(
		config.get_value("structure", "debug", stability_debug)
	)
	last_physics_level = maxi(1, physics_level)
	agent_cap = int(config.get_value("system", "agent_cap", 120))
	max_fps = int(config.get_value("system", "max_fps", 60))
	view_roll_index = int(config.get_value("camera", "view_roll", 1))


func _commit() -> void:
	save_settings()
	apply_all()


func _next_float(values: Array[float], current: float) -> float:
	for index in values.size():
		if is_equal_approx(values[index], current):
			return values[(index + 1) % values.size()]
	return values[0]


func _next_int(values: Array[int], current: int) -> int:
	for index in values.size():
		if values[index] == current:
			return values[(index + 1) % values.size()]
	return values[0]
