shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec4 shallow_color : source_color = vec4(0.10, 0.46, 0.78, 0.6);
uniform vec4 deep_color : source_color = vec4(0.01, 0.07, 0.22, 0.92);
uniform vec4 foam_color : source_color = vec4(0.88, 0.96, 1.0, 0.35);

// Depth fading: water is shallow-coloured near the surface and deep-coloured
// where the scene behind it is far below.
uniform float depth_fade_distance = 4.0;

// Shoreline foam from the water-surface / ground-depth comparison.
uniform float foam_depth = 0.1;
uniform float foam_texel_size = 0.0625;

varying vec3 world_pos;


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	scene_view.xyz /= scene_view.w;

	float scene_depth = -scene_view.z;
	float surface_depth = -VERTEX.z;
	float thickness = max(scene_depth - surface_depth, 0.0);
	float depth_factor = clamp(thickness / max(depth_fade_distance, 0.001), 0.0, 1.0);

	vec3 color = mix(shallow_color.rgb, deep_color.rgb, depth_factor);
	float alpha = mix(shallow_color.a, deep_color.a, depth_factor);

	// Foam where the water surface is close to the ground. The hash is taken
	// at 1/16 m world texels so the foam matches the block texture grid.
	float foam_band = 1.0 - smoothstep(0.0, max(foam_depth, 0.001), thickness);
	vec2 foam_texel = floor(world_pos.xz / max(foam_texel_size, 0.0001));
	float foam_noise = hash12(foam_texel);
	float foam = foam_band * smoothstep(0.52, 0.78, foam_noise);
	color = mix(color, foam_color.rgb, foam * foam_color.a);

	ALBEDO = color;
	ALPHA = alpha;
	ROUGHNESS = 0.12;
	METALLIC = 0.0;
}
