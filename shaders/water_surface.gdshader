shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec4 shallow_color : source_color = vec4(0.16, 0.54, 0.86, 0.48);
uniform vec4 deep_color : source_color = vec4(0.025, 0.15, 0.38, 0.86);
uniform vec4 foam_color : source_color = vec4(0.90, 0.97, 1.0, 0.62);

uniform float depth_fade_distance = 3.5;
uniform float foam_depth = 0.10;
uniform float foam_texel_size = 0.0625;
uniform float flow_streak_strength = 0.12;

varying vec3 world_pos;
varying float water_depth;


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	water_depth = UV2.x;
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

	// The column depth helps the shallow edge stay translucent even when the
	// camera is close to the surface and the scene-depth difference is tiny.
	float column_factor = clamp(water_depth, 0.0, 1.0);
	vec3 color = mix(shallow_color.rgb, deep_color.rgb, max(depth_factor, column_factor * 0.45));
	float alpha = mix(shallow_color.a, deep_color.a, max(depth_factor, column_factor * 0.45));

	// Foam where the surface is close to the ground. The hash is sampled on the
	// 1/16 m world texel grid so it matches the block/pixel art.
	float foam_band = 1.0 - smoothstep(0.0, max(foam_depth, 0.001), thickness);
	vec2 foam_texel = floor(world_pos.xz / max(foam_texel_size, 0.0001));
	float foam_noise = hash12(foam_texel + vec2(TIME * 0.15, -TIME * 0.1));
	float foam = foam_band * smoothstep(0.48, 0.78, foam_noise);
	color = mix(color, foam_color.rgb, foam * foam_color.a);

	// Very light animated streak so a calm body still reads as water.
	float streak = sin((world_pos.x + world_pos.z) * 0.65 + TIME * 0.7);
	color += vec3(streak * flow_streak_strength * 0.02);

	ALBEDO = color;
	// A small emission keeps the body readable in the project's dark ambient
	// lighting; it is not meant to look like glowing water.
	EMISSION = color * 0.14;
	ALPHA = clamp(alpha, 0.0, 1.0);
	ROUGHNESS = 0.14;
	METALLIC = 0.0;
}
