shader_type spatial;
render_mode blend_mix, depth_draw_opaque, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_disabled;

// HL2-style foliage sway. The phase is derived from the plant's world origin,
// so every card in one plant shares the same motion and all plants using the
// same texture can share one material (no per-instance material creation).

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform float sway_height = 1.0;
uniform float sway_strength = 0.035;
// Flip the view-space normal on back faces. Enabled only for grass materials;
// other foliage keeps the default lighting.
uniform bool flip_backface_normals = false;
// Grass-only stable lighting: use a world-up normal and view direction so the
// brightness depends on the sun, not on which crossed card faces the camera.
uniform bool stable_grass_shading = false;

// Green-masked subsurface scattering for foliage. Only pixels where green is
// the dominant albedo channel receive the extra translucency term.
uniform float sss_strength : hint_range(0.0, 2.0, 0.01) = 0.65;
uniform float sss_sigma : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float sss_power : hint_range(0.0, 100.0, 0.25) = 5.0;
uniform float sss_scale : hint_range(0.0, 50.0, 0.1) = 3.3;
uniform float sss_attenuation_influence : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float sss_albedo_influence : hint_range(0.0, 1.0, 0.01) = 0.7;
uniform float sss_light_color_influence : hint_range(0.0, 1.0, 0.01) = 0.3;
uniform float sss_green_min : hint_range(-1.0, 1.0, 0.01) = 0.0;
uniform float sss_green_max : hint_range(-1.0, 1.0, 0.01) = 0.18;

float foliage_sss(vec3 n, vec3 v, vec3 l, float sigma_value) {
	l = normalize(l);
	return pow(clamp(dot((-l + n * sigma_value), v), 0.0, 1.0), sss_power);
}

float foliage_green_mask(vec3 albedo) {
	float green = albedo.g;
	float other = max(albedo.r, albedo.b);
	float dominance = (green - other) / max(green + other, 0.001);
	return smoothstep(sss_green_min, sss_green_max, dominance)
		* smoothstep(0.02, 0.15, green);
}

float world_phase(vec3 world_origin) {
	return fract(sin(dot(world_origin.xz, vec2(12.9898, 78.233))) * 43758.5453)
		* 6.2831853;
}

void vertex() {
	float height_factor = clamp(1.0 - UV.y, 0.0, 1.0);
	height_factor = height_factor * height_factor;

	float phase = world_phase(MODEL_MATRIX[3].xyz);
	float speed = 0.85 + fract(phase * 0.15915494) * 0.4;
	float t = TIME * speed + phase;

	float bend = sin(t) * 0.65 + sin(t * 2.17 + 1.3) * 0.25;
	float sideways = cos(t * 0.73 + 0.4) * 0.4;

	vec3 world_offset = vec3(bend, 0.0, sideways);
	world_offset *= sway_height * sway_strength * height_factor;

	// Transpose of the model basis converts the world-space bend back into the
	// sprite's local space (the cards are yawed differently).
	VERTEX += transpose(mat3(MODEL_MATRIX)) * world_offset;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;

	if (stable_grass_shading) {
		NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	} else if (flip_backface_normals && !FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}

void light() {
	vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 n = normalize(NORMAL);
	vec3 v = stable_grass_shading ? up_view : normalize(VIEW);
	vec3 l = normalize(LIGHT);
	// Bias the card normal upward so thin, vertical foliage still catches light.
	vec3 n2 = stable_grass_shading
		? up_view
		: normalize(vec3(0.0, 1.0, 0.0) + 0.5 * n);
	float kd = max(dot(l, n2), 0.0);
	float ndl = max(dot(n, l), 0.0);

	float green_mask = foliage_green_mask(ALBEDO);
	float sss = foliage_sss(n, v, l, sss_sigma) * green_mask;
	float attenuation = max(
		mix(1.0, ATTENUATION, sss_attenuation_influence),
		0.001
	);
	vec3 sss_color = (
		sss_albedo_influence * ALBEDO
		+ sss_light_color_influence * LIGHT_COLOR
	);
	vec3 normal_diffuse = ALBEDO * ndl * LIGHT_COLOR;

	// Green pixels get the wrap-lit SSS response; everything else keeps a
	// normal Lambert response so brown trunks and non-green cards are untouched.
	vec3 green_diffuse = sss_color * (
		0.3 + max(kd * sss_scale, sss * sss_strength * sss_scale)
	);
	DIFFUSE_LIGHT += mix(normal_diffuse, green_diffuse, green_mask) * attenuation;
}
