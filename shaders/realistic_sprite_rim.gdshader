shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Set once per frame by SpriteLight3D.
global uniform vec2 sprite_sun_dir;
// Alpha carries rim strength; the rim itself reveals the unshaded texture.
global uniform vec4 sprite_sun_color;
// RGB is the complementary bounce tint; alpha carries bounce strength.
global uniform vec4 sprite_bounce_color;

uniform sampler2D sprite_atlas : source_color, filter_linear, repeat_disable;
uniform vec4 sprite_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 atlas_size = vec2(1.0, 1.0);

uniform float rim_thickness : hint_range(0.0, 0.1) = 0.02;
uniform float bounce_thickness : hint_range(0.0, 0.1) = 0.02;
uniform vec2 sprite_scale = vec2(1.0, 1.0);

uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float color_tolerance : hint_range(0.0, 1.0) = 0.1;
// How much of the light/bounce colour is mixed into the texture.
uniform float light_mix : hint_range(0.0, 1.0) = 0.5;
// Per-agent multipliers on the shared sun/bounce strengths.
uniform float rim_strength : hint_range(0.0, 1.0) = 1.0;
uniform float bounce_strength : hint_range(0.0, 4.0) = 1.0;

void vertex() {
	// Match AnimatedSprite3D.billboard = BILLBOARD_FIXED_Y. The base sprite
	// material rotates its quad, but material_overlay is a separate pass and
	// must apply the same Y-only billboard transform.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
		MODEL_MATRIX[3]
	);
}

vec2 frame_to_atlas(vec2 frame_uv) {
	vec2 region_origin = sprite_region.xy / atlas_size;
	vec2 region_size = sprite_region.zw / atlas_size;
	return region_origin + clamp(frame_uv, 0.0, 1.0) * region_size;
}

void fragment() {
	// UV is atlas-space; convert it to 0-1 within the current frame and
	// clamp every rim/bounce sample so neighbouring cells are never read.
	vec2 region_origin = sprite_region.xy / atlas_size;
	vec2 region_size = sprite_region.zw / atlas_size;
	vec2 frame_uv = (UV - region_origin) / region_size;

	vec4 tex_color = texture(sprite_atlas, frame_to_atlas(frame_uv));

	vec2 base_dir = normalize(sprite_sun_dir) * sign(sprite_scale);
	vec2 rim_offset = base_dir * rim_thickness;
	vec2 bounce_offset = base_dir * bounce_thickness;

	float alpha_rim = texture(
		sprite_atlas,
		frame_to_atlas(frame_uv - rim_offset)
	).a;
	float rim_mask = clamp(tex_color.a - alpha_rim, 0.0, 1.0);

	float alpha_bounce = texture(
		sprite_atlas,
		frame_to_atlas(frame_uv + bounce_offset)
	).a;
	float bounce_mask = clamp(tex_color.a - alpha_bounce, 0.0, 1.0);

	float is_not_outline = step(
		color_tolerance,
		distance(tex_color.rgb, outline_color.rgb)
	);

	float rim_amount = clamp(
		rim_mask * is_not_outline * sprite_sun_color.a * rim_strength,
		0.0,
		1.0
	);
	float bounce_amount = clamp(
		bounce_mask * is_not_outline * sprite_bounce_color.a * bounce_strength,
		0.0,
		1.0
	);

	// Both edges are the same kind of mix: unshaded texture blended with the
	// actual directional-light colour for the rim, and with the complementary
	// bounce colour for the bounce. Neither hard-replaces the sprite detail.
	vec3 bounced = mix(
		tex_color.rgb,
		sprite_bounce_color.rgb,
		light_mix
	);
	vec3 unshaded = mix(
		tex_color.rgb,
		sprite_sun_color.rgb,
		light_mix
	);
	vec3 final_color = mix(bounced, unshaded, rim_amount);

	ALBEDO = final_color;
	ALPHA = max(rim_amount, bounce_amount);
}
