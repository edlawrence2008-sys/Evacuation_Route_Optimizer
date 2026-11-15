shader_type spatial;

// Minecraft-style cloud faces: flat, unshaded, with per-direction brightness.
// The geometry is a MultiMesh of boxes, so NORMAL selects the top, bottom, or
// side shade without needing a texture.
render_mode unshaded, cull_back, depth_draw_opaque, blend_mix,
	shadows_disabled, fog_disabled;

uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 0.8);
uniform float brightness_top : hint_range(0.0, 2.0) = 1.0;
uniform float brightness_bottom : hint_range(0.0, 2.0) = 0.72;
uniform float brightness_side : hint_range(0.0, 2.0) = 0.86;
uniform float distance_fade_start : hint_range(0.0, 4096.0) = 600.0;
uniform float distance_fade_end : hint_range(0.0, 4096.0) = 1000.0;

varying vec3 v_cloud_normal;

void vertex() {
	v_cloud_normal = NORMAL;
}

void fragment() {
	float brightness = brightness_side;

	if (v_cloud_normal.y > 0.5) {
		brightness = brightness_top;
	} else if (v_cloud_normal.y < -0.5) {
		brightness = brightness_bottom;
	}

	// VERTEX is the fragment position in view space. Fade toward the far
	// plane so cloud banks melt into the sky instead of ending on a hard edge.
	float view_distance = length(VERTEX);
	float fade = 1.0 - smoothstep(
		distance_fade_start,
		max(distance_fade_end, distance_fade_start + 0.01),
		view_distance
	);

	ALBEDO = cloud_color.rgb * brightness;
	ALPHA = cloud_color.a * fade;
}
