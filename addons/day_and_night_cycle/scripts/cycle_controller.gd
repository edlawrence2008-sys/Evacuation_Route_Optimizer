class_name CycleController
extends Node3D

signal day_started
signal night_started
## Emitted when a settings/menu change is pushed into this controller.
signal sky_param_changed(name: StringName)

enum TimeMode { CYCLE, DAWN, DAY, DUSK, NIGHT }

#region Export
@export_group("Presets")
@export var day_data: CycleData
@export var night_data: CycleData

@export_group("General")
@export var world_environment: WorldEnvironment
@export_enum("Cycle", "Dawn", "Day", "Dusk", "Night") var time_mode: int = 0
@export_range(0.0, 8.0, 0.01) var cycle_speed: float = 1.0

@export_group("Lighting")
@export var sun_light: DirectionalLight3D
@export var ambient_light_color: Color
## Percentage of light used from the sky. If your sky is red and you set this value to 1.0
## there'll be a red ambient light in the world.
@export_range(0, 1, 0.01) var sky_contribution: float = 0.05

@export_group("Shadow Styling")
@export var enable_purple_shadows: bool = true
## The dark purple color used to tint ambient light filling the shadows.
@export var shadow_purple_color: Color = Color(0.072, 0.024, 0.12, 1.0)
## How strongly the purple shadow tint blends into the ambient/horizon lighting (0.0 to 1.0).
@export_range(0, 1, 0.01) var shadow_tint_strength: float = 0.1

@export_group("Look / Color Grade")
## Master switch for the look overrides. Neutral values preserve the existing
## environment, so these are safe to leave alone until you want to tune the
## image. All values are multipliers on the scene's authored environment.
@export var enable_look_overrides: bool = true
@export_range(0.0, 4.0, 0.01) var brightness_scale: float = 1.0
@export_range(0.0, 4.0, 0.01) var contrast_scale: float = 1.0
@export_range(0.0, 4.0, 0.01) var saturation_scale: float = 1.0
@export_range(0.0, 4.0, 0.01) var exposure_scale: float = 1.0
@export_range(0.0, 4.0, 0.01) var sun_energy_scale: float = 1.0
@export var sun_color: Color = Color.WHITE
@export_range(0.0, 4.0, 0.01) var ambient_energy_scale: float = 1.0
## Saturation multiplier applied to the procedural sky colours.
@export_range(0.0, 4.0, 0.01) var sky_saturation: float = 1.0
@export var sky_tint: Color = Color.WHITE
@export_range(0.0, 4.0, 0.01) var fog_density_scale: float = 1.0
@export_range(0.0, 4.0, 0.01) var volumetric_fog_density_scale: float = 1.0
@export var override_tonemap: bool = false
@export var tonemap_mode: Environment.ToneMapper = Environment.TONE_MAPPER_FILMIC

@export_group("Solar")
## Latitude and day of year set the noon sun height. The east/west arc keeps
## the authored day/night lengths; only the arc's tilt changes.
@export_range(-90.0, 90.0, 0.1) var latitude: float = 50.0
@export_range(1, 365) var day_of_year: int = 180
@export_range(-180.0, 180.0, 0.1) var sun_azimuth_offset: float = 0.0
## Sunset warmth fades out by this sun elevation (degrees).
@export_range(0.0, 60.0, 0.1) var sunset_fade_end_elevation: float = 18.0
@export var sunset_horizon_color: Color = Color(1.0, 0.45, 0.18)
@export var sunset_zenith_color: Color = Color(0.42, 0.28, 0.55)
@export var sunset_ground_color: Color = Color(0.24, 0.16, 0.22)
@export_range(0.0, 2.0, 0.01) var sunset_strength: float = 1.0

@export_group("Sun & Moon Discs")
@export var sun_disc_enabled: bool = true
@export var moon_disc_enabled: bool = true
## Optional textures. When empty a soft procedural disc is generated.
@export var sun_texture: Texture2D:
	set(value):
		sun_texture = value
		_refresh_disc_textures()
@export var moon_texture: Texture2D:
	set(value):
		moon_texture = value
		_refresh_disc_textures()
@export var sun_disc_size: float = 32.0
@export var moon_disc_size: float = 22.0
@export var sun_disc_color: Color = Color(1.0, 0.95, 0.8)
@export var moon_disc_color: Color = Color(0.82, 0.88, 1.0)
@export var sky_disc_distance: float = 600.0

@export_group("Rainbow")
@export var rainbow_enabled: bool = true
@export_range(0.0, 1.0, 0.01) var rainbow_intensity: float = 0.55
@export var rainbow_distance: float = 600.0
@export var rainbow_size: float = 260.0
@export_range(0.1, 0.7, 0.005) var rainbow_inner_radius: float = 0.30
@export_range(0.1, 0.7, 0.005) var rainbow_outer_radius: float = 0.48

@export_group("Storm")
@export var storm_flashes_enabled: bool = true
@export_range(0.0, 4.0, 0.01) var storm_strength: float = 1.0
@export var storm_min_interval: float = 7.0
@export var storm_max_interval: float = 18.0
@export var storm_flash_duration: float = 0.4
@export var storm_flash_color: Color = Color(0.82, 0.88, 1.0)
@export_range(0.0, 1.0, 0.01) var storm_ambient_share: float = 0.55

@export_group("Debug")
@export var show_debug_time: bool = false
#endregion

var _current_time: float = 0.0
var _cycle_time: float = 0.0
var _is_day: bool = true
var _was_day: bool = true
var _applied_time_mode: int = -1
var _night_weight: float = 0.0
var _sun_elevation: float = 0.0
var _sun_dir: Vector3 = Vector3.UP
var _moon_dir: Vector3 = Vector3.DOWN
var _sunset_blend: float = 0.0

## Authored environment values captured at boot; the Look multipliers apply to
## these so neutral defaults never change the scene.
var _base_adjustment_enabled: bool = false
var _base_brightness: float = 1.0
var _base_contrast: float = 1.0
var _base_saturation: float = 1.0
var _base_tonemap_exposure: float = 1.0
var _base_ambient_energy: float = 1.0
var _base_fog_density: float = 0.0
var _base_volumetric_fog_density: float = 0.0
var _base_volumetric_fog_enabled: bool = false
var _has_fog_density_curve: bool = false
var _base_background_energy: float = 1.0
var _base_sun_color: Color = Color.WHITE

var _phase_light_color: Color = Color.WHITE
var _phase_ambient_energy: float = 1.0
var _phase_fog_density: float = 0.0
var _phase_vol_fog_density: float = 0.0

var _sun_sprite: Sprite3D
var _moon_sprite: Sprite3D
var _rainbow_sprite: Sprite3D
var _default_sun_texture: Texture2D
var _default_moon_texture: Texture2D
var _default_rainbow_texture: Texture2D

var _storm_timer: float = 0.0
var _storm_flash: float = 0.0
var _warned_missing_data: bool = false
var _fog_enabled: bool = false
## Depth-fog end in metres, driven by Graphics > Draw Distance minus Fog Offset.
var _fog_distance: float = 0.0


func _ready():
	# Auto register into tracking group so spawning units can instantly bind events
	add_to_group("CycleControllers")

	_sample_cycle_length()
	_capture_environment_bases()
	_load_default_disc_textures()
	_setup_sky_sprites()

	_phase_ambient_energy = _base_ambient_energy
	_phase_fog_density = _base_fog_density
	_phase_vol_fog_density = _base_volumetric_fog_density
	_phase_light_color = Color.WHITE
	_storm_timer = randf_range(
		maxf(0.5, storm_min_interval),
		maxf(maxf(0.5, storm_min_interval), storm_max_interval)
	)

	_apply_fog_state()
	_apply_look()


func _sample_cycle_length() -> void:
	if day_data == null or night_data == null:
		_cycle_time = 0.0
		return

	_cycle_time = maxf(day_data.length + night_data.length, 0.001)


func _capture_environment_bases() -> void:
	if world_environment != null and world_environment.environment != null:
		var environment := world_environment.environment
		_base_adjustment_enabled = environment.adjustment_enabled
		_base_brightness = environment.adjustment_brightness
		_base_contrast = environment.adjustment_contrast
		_base_saturation = environment.adjustment_saturation
		_base_tonemap_exposure = environment.tonemap_exposure
		_base_ambient_energy = environment.ambient_light_energy
		_base_fog_density = environment.fog_density
		_base_volumetric_fog_density = environment.volumetric_fog_density
		_base_volumetric_fog_enabled = environment.volumetric_fog_enabled
		_base_background_energy = environment.background_energy_multiplier
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		environment.ambient_light_color = ambient_light_color
		environment.ambient_light_sky_contribution = sky_contribution
	if sun_light != null:
		_base_sun_color = sun_light.light_color


func _process(delta):
	if not _has_cycle_data():
		return

	_sample_cycle_length()

	if time_mode != _applied_time_mode:
		_apply_time_mode()

	if time_mode == TimeMode.CYCLE:
		_current_time += delta * maxf(cycle_speed, 0.0)

	if _cycle_time > 0.0:
		_current_time = fmod(_current_time, _cycle_time)
	else:
		_current_time = 0.0

	_current_time = maxf(_current_time, 0.0)
	_is_day = _current_time < day_data.length

	if _is_day != _was_day:
		_was_day = _is_day

		if _is_day:
			day_started.emit()
		else:
			night_started.emit()

	var day_progress: float = clampf(
		_current_time / maxf(day_data.length, 0.001),
		0.0,
		1.0
	)
	var night_progress: float = clampf(
		(_current_time - day_data.length) / maxf(night_data.length, 0.001),
		0.0,
		1.0
	)

	_update_solar_position(day_progress, night_progress)
	_night_weight = 1.0 - smoothstep(-4.0, 2.0, _sun_elevation)
	_night_weight = clampf(_night_weight, 0.0, 1.0)
	_sunset_blend = (
		1.0 - smoothstep(0.0, sunset_fade_end_elevation, absf(_sun_elevation))
	) * clampf(sunset_strength, 0.0, 2.0)

	_update_phase_lighting(day_progress, night_progress)
	_update_sky_colors(day_progress, night_progress)
	_apply_look()
	_update_sky_bodies()
	_update_storm(delta)
	_apply_storm_flash()

	if show_debug_time:
		_print_debug_info()


func _has_cycle_data() -> bool:
	if day_data == null or night_data == null:
		if not _warned_missing_data:
			_warned_missing_data = true
			push_warning("CycleController: day_data and night_data must both be assigned.")
		return false

	if sun_light == null:
		if not _warned_missing_data:
			_warned_missing_data = true
			push_warning("CycleController: sun_light must be assigned.")
		return false

	if world_environment == null or world_environment.environment == null:
		if not _warned_missing_data:
			_warned_missing_data = true
			push_warning("CycleController: world_environment must have an Environment.")
		return false

	return true


func _update_solar_position(day_progress: float, night_progress: float) -> void:
	var declination: float = 23.44 * sin(
		TAU * float(day_of_year - 81) / 365.0
	)
	var max_elevation: float = clampf(
		90.0 - absf(latitude - declination),
		0.0,
		90.0
	)

	var elevation: float
	var azimuth: float

	if _is_day:
		var theta: float = day_progress * PI
		elevation = max_elevation * sin(theta)
		azimuth = lerpf(90.0, 270.0, day_progress)
	else:
		var theta: float = night_progress * PI
		elevation = -max_elevation * sin(theta)
		azimuth = wrapf(lerpf(270.0, 450.0, night_progress), 0.0, 360.0)

	azimuth += sun_azimuth_offset
	_sun_elevation = elevation

	var elevation_rad: float = deg_to_rad(elevation)
	var azimuth_rad: float = deg_to_rad(azimuth)
	var horizontal: float = cos(elevation_rad)

	# +X east, +Y up, -Z north. Azimuth 0 = north, 90 = east.
	_sun_dir = Vector3(
		sin(azimuth_rad) * horizontal,
		sin(elevation_rad),
		-cos(azimuth_rad) * horizontal
	).normalized()

	var moon := -_sun_dir
	moon.y += 0.06
	_moon_dir = moon.normalized()

	_set_sun_light_direction(_sun_dir)


func _set_sun_light_direction(sun_dir: Vector3) -> void:
	var light_dir: Vector3 = -sun_dir
	var up := Vector3.UP

	if absf(light_dir.dot(up)) > 0.99:
		up = Vector3.BACK

	var basis := Basis.looking_at(light_dir, up)
	sun_light.global_transform = Transform3D(basis, sun_light.global_position)


func _update_phase_lighting(day_progress: float, night_progress: float) -> void:
	var day_energy: float = _sample_curve(
		day_data.light_energy,
		day_progress,
		1.0
	)
	var night_energy: float = _sample_curve(
		night_data.light_energy,
		night_progress,
		0.0
	)
	sun_light.light_energy = lerpf(day_energy, night_energy, _night_weight)

	_phase_light_color = day_data.light_color.lerp(
		night_data.light_color,
		_night_weight
	)

	_phase_ambient_energy = lerpf(
		_sample_curve(
			day_data.ambient_energy,
			day_progress,
			_base_ambient_energy
		),
		_sample_curve(
			night_data.ambient_energy,
			night_progress,
			_base_ambient_energy
		),
		_night_weight
	)
	_has_fog_density_curve = (
		day_data.fog_density != null or night_data.fog_density != null
	)
	_phase_fog_density = lerpf(
		_sample_curve(day_data.fog_density, day_progress, _base_fog_density),
		_sample_curve(night_data.fog_density, night_progress, _base_fog_density),
		_night_weight
	)
	_phase_vol_fog_density = lerpf(
		_sample_curve(
			day_data.volumetric_fog_density,
			day_progress,
			_base_volumetric_fog_density
		),
		_sample_curve(
			night_data.volumetric_fog_density,
			night_progress,
			_base_volumetric_fog_density
		),
		_night_weight
	)


func _update_sky_colors(day_progress: float, night_progress: float) -> void:
	var environment := world_environment.environment
	var sky_material := environment.sky.sky_material if environment.sky != null else null

	if sky_material == null:
		push_warning("Could not find sky material. Please assign WorldEnvironment accordingly.")
		return

	var day_sky: Color = _sample_gradient(
		day_data.colors,
		day_progress,
		Color(0.55, 0.72, 0.9, 1.0)
	)
	var night_sky: Color = _sample_gradient(
		night_data.colors,
		night_progress,
		Color(0.03, 0.05, 0.09, 1.0)
	)
	var sky_color: Color = day_sky.lerp(night_sky, _night_weight)
	var day_ground_bottom: Color = day_sky.darkened(
		day_data.ground_bottom_darkening_multiplier
	)
	var night_ground_bottom: Color = night_sky.darkened(
		night_data.ground_bottom_darkening_multiplier
	)
	var ground_bottom: Color = day_ground_bottom.lerp(
		night_ground_bottom,
		_night_weight
	)

	var zenith: Color = _blend_sky_layer(
		day_data.zenith_colors,
		night_data.zenith_colors,
		day_progress,
		night_progress,
		sky_color
	)
	var horizon: Color = _blend_sky_layer(
		day_data.horizon_colors,
		night_data.horizon_colors,
		day_progress,
		night_progress,
		day_sky.darkened(
			day_data.horizon_darkening_multiplier
		).lerp(
			night_sky.darkened(night_data.horizon_darkening_multiplier),
			_night_weight
		)
	)
	var lower_sky: Color = _blend_sky_layer(
		day_data.lower_sky_colors,
		night_data.lower_sky_colors,
		day_progress,
		night_progress,
		ground_bottom
	)
	var ground_horizon: Color = day_sky.darkened(
		day_data.ground_horizon_darkening_multiplier
	).lerp(
		night_sky.darkened(night_data.ground_horizon_darkening_multiplier),
		_night_weight
	)

	if _sunset_blend > 0.0:
		horizon = horizon.lerp(sunset_horizon_color, _sunset_blend * 0.8)
		zenith = zenith.lerp(sunset_zenith_color, _sunset_blend * 0.6)
		ground_horizon = ground_horizon.lerp(
			sunset_horizon_color,
			_sunset_blend * 0.35
		)
		ground_bottom = ground_bottom.lerp(
			sunset_ground_color,
			_sunset_blend * 0.25
		)

	# Apply dark purple shadow tinting to ambient light colour.
	var effective_ambient: Color = ambient_light_color

	if enable_purple_shadows:
		effective_ambient = effective_ambient.lerp(
			shadow_purple_color,
			shadow_tint_strength
		)
		horizon = horizon.lerp(shadow_purple_color, shadow_tint_strength * 0.5)
		ground_horizon = ground_horizon.lerp(
			shadow_purple_color,
			shadow_tint_strength * 0.5
		)
		ground_bottom = ground_bottom.lerp(
			shadow_purple_color,
			shadow_tint_strength * 0.5
		)

	environment.ambient_light_color = effective_ambient
	# Keep the distance fog close to the horizon colour, so the far chunks fade
	# into the sky instead of into a flat grey band.
	environment.fog_light_color = horizon.lerp(sky_color, 0.25)

	if sky_material is ProceduralSkyMaterial:
		var procedural := sky_material as ProceduralSkyMaterial
		procedural.sky_top_color = zenith
		procedural.sky_horizon_color = horizon
		procedural.ground_horizon_color = ground_horizon
		procedural.ground_bottom_color = ground_bottom
		procedural.energy_multiplier = maxf(
			procedural.energy_multiplier,
			0.0
		)
		if lower_sky_colors_present():
			procedural.ground_bottom_color = lower_sky

	_update_sky_cover(sky_material, day_progress, night_progress)


func lower_sky_colors_present() -> bool:
	return (
		(day_data.lower_sky_colors != null)
		or (night_data.lower_sky_colors != null)
	)


func _update_sky_cover(
	sky_material: Material,
	day_progress: float,
	night_progress: float
) -> void:
	if not (sky_material is ProceduralSkyMaterial):
		return

	var procedural := sky_material as ProceduralSkyMaterial
	var use_night: bool = _night_weight >= 0.5
	var data: CycleData = night_data if use_night else day_data

	if data.sky_cover == null:
		procedural.sky_cover = null
		procedural.sky_cover_modulate = Color(1, 1, 1, 0)
		return

	procedural.sky_cover = data.sky_cover

	var alpha: float
	if use_night:
		alpha = (
			smoothstep(0.0, 0.3, night_progress)
			* (1.0 - smoothstep(0.7, 1.0, night_progress))
		)
	else:
		alpha = 1.0 - smoothstep(0.8, 1.0, day_progress)

	procedural.sky_cover_modulate = Color(1, 1, 1, alpha)


func _blend_sky_layer(
	day_texture: GradientTexture2D,
	night_texture: GradientTexture2D,
	day_progress: float,
	night_progress: float,
	fallback: Color
) -> Color:
	var day_color: Color = _sample_gradient(day_texture, day_progress, fallback)
	var night_color: Color = _sample_gradient(night_texture, night_progress, fallback)
	return day_color.lerp(night_color, _night_weight)


func _sample_gradient(
	texture: GradientTexture2D,
	progress: float,
	fallback: Color
) -> Color:
	if texture == null or texture.gradient == null:
		return fallback
	return texture.gradient.sample(clampf(progress, 0.0, 1.0))


func _sample_curve(
	curve: Curve,
	progress: float,
	fallback: float
) -> float:
	if curve == null:
		return fallback
	return curve.sample(clampf(progress, 0.0, 1.0))


func _apply_time_mode() -> void:
	_applied_time_mode = time_mode

	if time_mode == TimeMode.CYCLE:
		return

	if day_data == null or night_data == null:
		return

	match time_mode:
		TimeMode.DAWN:
			_current_time = 0.0
		TimeMode.DAY:
			_current_time = day_data.length * 0.5
		TimeMode.DUSK:
			_current_time = day_data.length * 0.95
		TimeMode.NIGHT:
			_current_time = day_data.length + night_data.length * 0.5

	_is_day = _current_time < day_data.length
	_was_day = _is_day


func set_time_mode(mode: int) -> void:
	var clamped := clampi(mode, 0, TimeMode.NIGHT)
	if time_mode == clamped:
		return
	time_mode = clamped
	_apply_time_mode()
	sky_param_changed.emit(&"time_mode")


func set_cycle_speed(value: float) -> void:
	cycle_speed = maxf(value, 0.0)
	sky_param_changed.emit(&"cycle_speed")


## Graphics > Sky & Clouds fog switch. Controls distance fog and the
## environment's volumetric fog together.
func set_fog_enabled(value: bool) -> void:
	_fog_enabled = value
	_apply_fog_state()
	sky_param_changed.emit(&"fog")


## Keeps the depth fog just inside the rendered chunk ring. `distance` is the
## far fog edge in metres; the settings menu supplies chunk radius - offset.
func set_fog_distance(distance: float) -> void:
	_fog_distance = maxf(distance, 1.0)
	_apply_fog_state()
	sky_param_changed.emit(&"fog_distance")


func _apply_fog_state() -> void:
	if world_environment == null or world_environment.environment == null:
		return

	var environment := world_environment.environment
	environment.fog_enabled = _fog_enabled
	environment.volumetric_fog_enabled = (
		_fog_enabled and _base_volumetric_fog_enabled
	)

	if _fog_distance > 0.0:
		environment.fog_mode = Environment.FOG_MODE_DEPTH
		environment.fog_depth_end = _fog_distance
		# Start the fog well inside the edge so near/mid objects stay clear and
		# the far ring fades out before the chunk itself disappears.
		environment.fog_depth_begin = maxf(
			1.0,
			_fog_distance * 0.55
		)
		environment.fog_depth_curve = 1.5

	# Keep the sky mostly readable: with depth fog the background sits at the
	# far depth, so sky_affect = 1 would flood the whole sky with fog colour.
	environment.fog_sky_affect = 0.25
	environment.fog_sun_scatter = 0.0
	# Apply the opacity immediately too. Maps without CycleData never run
	# _apply_look(), so relying only on the per-frame pass left depth fog at the
	# authored 0.01 density and effectively invisible.
	if _fog_enabled:
		var fog_intensity: float = (
			_phase_fog_density if _has_fog_density_curve else 1.0
		)
		environment.fog_density = clampf(
			fog_intensity * fog_density_scale,
			0.0,
			1.0
		)


## Applies the Graphics > Sky & Clouds menu state without touching authored
## values that are not in the payload.
func apply_sky_settings(settings: Dictionary) -> void:
	if settings.has("time_mode"):
		set_time_mode(int(settings["time_mode"]))
	if settings.has("cycle_speed"):
		set_cycle_speed(float(settings["cycle_speed"]))
	if settings.has("sun_disc"):
		sun_disc_enabled = bool(settings["sun_disc"])
	if settings.has("moon_disc"):
		moon_disc_enabled = bool(settings["moon_disc"])
	if settings.has("rainbow"):
		rainbow_enabled = bool(settings["rainbow"])
	if settings.has("storm_flashes"):
		storm_flashes_enabled = bool(settings["storm_flashes"])
	if settings.has("storm_strength"):
		storm_strength = maxf(float(settings["storm_strength"]), 0.0)
	if settings.has("fog"):
		set_fog_enabled(bool(settings["fog"]))
	if settings.has("fog_distance"):
		set_fog_distance(float(settings["fog_distance"]))


## Uses the project's 32x32 pixel-art sun/moon textures when present. The
## inspector slots still override these.
func _load_default_disc_textures() -> void:
	if sun_texture == null and ResourceLoader.exists("res://textures/sun.png"):
		sun_texture = load("res://textures/sun.png")

	if moon_texture == null and ResourceLoader.exists("res://textures/moon.png"):
		moon_texture = load("res://textures/moon.png")


func _setup_sky_sprites() -> void:
	_default_sun_texture = _make_disc_texture(
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 0.86, 0.55, 0.55),
		128
	)
	_default_moon_texture = _make_disc_texture(
		Color(0.92, 0.96, 1.0, 1.0),
		Color(0.55, 0.66, 0.9, 0.45),
		128
	)
	_default_rainbow_texture = _make_rainbow_texture(256)

	_sun_sprite = _make_sky_sprite(
		"SunDisc",
		_default_sun_texture,
		BaseMaterial3D.BILLBOARD_ENABLED,
		sun_disc_size
	)
	_moon_sprite = _make_sky_sprite(
		"MoonDisc",
		_default_moon_texture,
		BaseMaterial3D.BILLBOARD_ENABLED,
		moon_disc_size
	)
	_rainbow_sprite = _make_sky_sprite(
		"Rainbow",
		_default_rainbow_texture,
		BaseMaterial3D.BILLBOARD_FIXED_Y,
		rainbow_size
	)
	_rainbow_sprite.modulate = Color(1, 1, 1, 0)

	_refresh_disc_textures()


func _make_sky_sprite(
	sprite_name: String,
	texture: Texture2D,
	billboard_mode: BaseMaterial3D.BillboardMode,
	size: float
) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.name = sprite_name
	sprite.texture = texture
	sprite.billboard = billboard_mode
	sprite.shaded = false
	sprite.transparent = true
	sprite.texture_filter = (
		BaseMaterial3D.TEXTURE_FILTER_NEAREST
		if texture.get_width() <= 64
		else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	)
	sprite.no_depth_test = false
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sprite.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	sprite.top_level = true
	sprite.visible = false
	sprite.pixel_size = size / maxf(float(texture.get_width()), 1.0)
	add_child(sprite)
	return sprite


func _refresh_disc_textures() -> void:
	if _sun_sprite != null:
		_sun_sprite.texture = (
			sun_texture if sun_texture != null else _default_sun_texture
		)
		_apply_disc_filter(_sun_sprite)

	if _moon_sprite != null:
		_moon_sprite.texture = (
			moon_texture if moon_texture != null else _default_moon_texture
		)
		_apply_disc_filter(_moon_sprite)


func _apply_disc_filter(sprite: Sprite3D) -> void:
	if sprite == null or sprite.texture == null:
		return

	sprite.texture_filter = (
		BaseMaterial3D.TEXTURE_FILTER_NEAREST
		if sprite.texture.get_width() <= 64
		else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	)


func _make_disc_texture(
	core: Color,
	edge: Color,
	size: int
) -> Texture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.55, 0.78, 1.0])
	gradient.colors = PackedColorArray([
		core,
		core,
		Color(edge.r, edge.g, edge.b, edge.a),
		Color(edge.r, edge.g, edge.b, 0.0),
	])

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = size
	texture.height = size
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture


func _make_rainbow_texture(size: int) -> Texture2D:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var inner := clampf(rainbow_inner_radius, 0.05, 0.69)
	var outer := clampf(rainbow_outer_radius, inner + 0.01, 0.70)
	var feather := maxf((outer - inner) * 0.18, 0.01)

	for y in size:
		for x in size:
			var u := (float(x) + 0.5) / float(size)
			var v := (float(y) + 0.5) / float(size)
			var dx := u - 0.5
			var dy := 1.0 - v
			var radius := sqrt(dx * dx + dy * dy)

			if dy < 0.0:
				continue

			var band := (
				smoothstep(inner, inner + feather, radius)
				* (1.0 - smoothstep(outer - feather, outer, radius))
			)

			if band <= 0.001:
				continue

			var t := clampf((radius - inner) / maxf(outer - inner, 0.001), 0.0, 1.0)
			var hue := lerpf(0.78, 0.0, t)
			var color := Color.from_hsv(hue, 0.82, 1.0, band * 0.85)
			image.set_pixel(x, y, color)

	return ImageTexture.create_from_image(image)


func _update_sky_bodies() -> void:
	var camera := get_viewport().get_camera_3d()

	if camera == null:
		return

	var camera_position := camera.global_position
	var sun_alpha: float = (
		smoothstep(-8.0, 2.0, _sun_elevation)
		if sun_disc_enabled
		else 0.0
	)
	var moon_elevation: float = rad_to_deg(
		asin(clampf(_moon_dir.y, -1.0, 1.0))
	)
	var moon_alpha: float = (
		smoothstep(-8.0, 4.0, moon_elevation)
		if moon_disc_enabled
		else 0.0
	)

	if _sun_sprite != null:
		_sun_sprite.visible = sun_alpha > 0.01
		_sun_sprite.global_position = (
			camera_position + _sun_dir * sky_disc_distance
		)
		_sun_sprite.pixel_size = (
			sun_disc_size / maxf(float(_sun_sprite.texture.get_width()), 1.0)
			if _sun_sprite.texture != null
			else 0.01
		)
		_sun_sprite.modulate = Color(
			sun_disc_color.r,
			sun_disc_color.g,
			sun_disc_color.b,
			sun_alpha
		)

	if _moon_sprite != null:
		_moon_sprite.visible = moon_alpha > 0.01
		_moon_sprite.global_position = (
			camera_position + _moon_dir * sky_disc_distance
		)
		_moon_sprite.pixel_size = (
			moon_disc_size / maxf(float(_moon_sprite.texture.get_width()), 1.0)
			if _moon_sprite.texture != null
			else 0.01
		)
		_moon_sprite.modulate = Color(
			moon_disc_color.r,
			moon_disc_color.g,
			moon_disc_color.b,
			moon_alpha
		)

	if _rainbow_sprite != null:
		var rainbow_alpha: float = 0.0

		if rainbow_enabled and _sun_elevation > 0.0:
			rainbow_alpha = (
				rainbow_intensity
				* smoothstep(2.0, 8.0, _sun_elevation)
				* (1.0 - smoothstep(35.0, 55.0, _sun_elevation))
			)

		_rainbow_sprite.visible = rainbow_alpha > 0.01
		var anti_sun := Vector3(-_sun_dir.x, 0.22, -_sun_dir.z)

		if anti_sun.length_squared() < 0.0001:
			anti_sun = Vector3.BACK

		_rainbow_sprite.global_position = (
			camera_position
			+ anti_sun.normalized() * rainbow_distance
		)
		_rainbow_sprite.pixel_size = (
			rainbow_size / maxf(float(_rainbow_sprite.texture.get_width()), 1.0)
			if _rainbow_sprite.texture != null
			else 0.01
		)
		_rainbow_sprite.modulate = Color(1, 1, 1, rainbow_alpha)


func _update_storm(delta: float) -> void:
	if not storm_flashes_enabled:
		_storm_flash = 0.0
		return

	_storm_timer -= delta

	if _storm_timer <= 0.0:
		_storm_flash = 1.0
		_storm_timer = randf_range(
			maxf(0.5, storm_min_interval),
			maxf(maxf(0.5, storm_min_interval), storm_max_interval)
		)
	else:
		_storm_flash = maxf(
			0.0,
			_storm_flash - delta / maxf(storm_flash_duration, 0.01)
		)


func _apply_storm_flash() -> void:
	if _storm_flash <= 0.0:
		return

	var flash: float = _storm_flash * maxf(storm_strength, 0.0)

	sun_light.light_energy += flash * 2.0
	sun_light.light_color = sun_light.light_color.lerp(
		storm_flash_color,
		clampf(flash * 0.6, 0.0, 1.0)
	)

	var environment := world_environment.environment
	if environment != null:
		environment.ambient_light_energy += (
			flash * 1.5 * storm_ambient_share
		)
		environment.background_energy_multiplier = (
			_base_background_energy + flash * 2.0
		)


## Applies the inspector's Look multipliers to the child WorldEnvironment and
## DirectionalLight3D. Called after the normal day/night pass so the base
## colours/energies are recomputed each frame and the scales never compound.
func _apply_look() -> void:
	if world_environment == null or world_environment.environment == null:
		return

	var environment := world_environment.environment
	# Always restore the authored background energy before any storm flash is
	# added, even when the Look overrides are disabled.
	environment.background_energy_multiplier = _base_background_energy

	if not enable_look_overrides:
		environment.ambient_light_energy = _base_ambient_energy
		return

	var needs_adjustment := (
		_base_adjustment_enabled
		or not is_equal_approx(brightness_scale, 1.0)
		or not is_equal_approx(contrast_scale, 1.0)
		or not is_equal_approx(saturation_scale, 1.0)
	)

	environment.adjustment_enabled = needs_adjustment
	environment.adjustment_brightness = _base_brightness * brightness_scale
	environment.adjustment_contrast = _base_contrast * contrast_scale
	environment.adjustment_saturation = _base_saturation * saturation_scale
	environment.tonemap_exposure = _base_tonemap_exposure * exposure_scale
	environment.ambient_light_energy = (
		_phase_ambient_energy * ambient_energy_scale
	)

	if override_tonemap:
		environment.tonemap_mode = tonemap_mode

	if environment.fog_enabled:
		# Depth fog's fog_density is its maximum opacity (0..1). The shipped
		# environment uses 0.01, which barely hides anything. Use full opacity
		# at the far edge so a chunk cannot poke through just before it is
		# unloaded; a CycleData curve can still lower the intensity.
		var fog_intensity: float = (
			_phase_fog_density if _has_fog_density_curve else 1.0
		)
		environment.fog_density = clampf(
			fog_intensity * fog_density_scale,
			0.0,
			1.0
		)

	environment.volumetric_fog_density = (
		_phase_vol_fog_density * volumetric_fog_density_scale
	)

	if sun_light != null:
		sun_light.light_energy *= sun_energy_scale
		sun_light.light_color = (
			_base_sun_color * _phase_light_color * sun_color
		)

	if (
		environment.sky != null
		and environment.sky.sky_material is ProceduralSkyMaterial
	):
		var sky := environment.sky.sky_material as ProceduralSkyMaterial
		sky.sky_top_color = _grade_sky_color(sky.sky_top_color)
		sky.sky_horizon_color = _grade_sky_color(sky.sky_horizon_color)
		sky.ground_horizon_color = _grade_sky_color(sky.ground_horizon_color)
		sky.ground_bottom_color = _grade_sky_color(sky.ground_bottom_color)


func _grade_sky_color(color: Color) -> Color:
	var tinted := color * sky_tint
	var luminance := tinted.get_luminance()
	var graded := Color(
		luminance + (tinted.r - luminance) * sky_saturation,
		luminance + (tinted.g - luminance) * sky_saturation,
		luminance + (tinted.b - luminance) * sky_saturation,
		tinted.a
	)
	return graded.clamp()


## Formatted time string (hh:mm:ss) since entering the tree.
func get_current_time_formatted() -> String:
	var hours = int(_current_time / 3600.0)
	var minutes = int(fmod(_current_time, 3600.0) / 60.0)
	var seconds = int(fmod(_current_time, 60.0))
	return "%02d:%02d:%02d" % [hours, minutes, seconds]


## Normalized progress [0.0, 1.0] of the whole cycle (day + night).
func get_cycle_progress() -> float:
	return _current_time / maxf(_cycle_time, 0.001)


## Normalized progress [0.0, 1.0] of current phase (day OR night).
func get_phase_progress() -> float:
	if day_data == null or night_data == null:
		return 0.0

	if _is_day:
		return _current_time / maxf(day_data.length, 0.001)
	else:
		return (_current_time - day_data.length) / maxf(night_data.length, 0.001)


## Jump to any state of the cycle. Progress Value from 0.0 (Start) to 1.0 (End) of the cycle's progress.
func set_cycle_progress(progress: float):
	_current_time = progress * _cycle_time
	_current_time = clamp(_current_time, 0.0, _cycle_time)
	time_mode = TimeMode.CYCLE


## Jump to begin of the day.
func skip_to_day():
	_current_time = 0.0
	_is_day = true
	_was_day = true
	time_mode = TimeMode.CYCLE
	day_started.emit()


## Jump to begin of the night.
func skip_to_night():
	_current_time = day_data.length if day_data != null else 0.0
	_is_day = false
	_was_day = false
	time_mode = TimeMode.CYCLE
	night_started.emit()


func _print_debug_info():
	var cycle_progress = get_cycle_progress() * 100
	var phase = "Day" if _is_day else "Night"
	var phase_progress = get_phase_progress() * 100

	print("Time: %s | Cycle: %.1f%% | Phase: %s (%.1f%%) | Sun: %.1f°" % [
		get_current_time_formatted(),
		cycle_progress,
		phase,
		phase_progress,
		_sun_elevation,
	])
