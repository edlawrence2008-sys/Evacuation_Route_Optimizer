shader_type canvas_item;

// 2D port of shaders/realistic_sprite_rim.gdshader for Consul's Sprite2D art.
// The rim and complementary bounce are sampled from the sprite alpha, so the
// silhouette is outlined without affecting the interior line art.
// `light_dir` points from the light toward the sprite in UV space.

uniform vec2 light_dir = vec2(-1.0, -0.25);
uniform float rim_width : hint_range(0.0, 12.0) = 5.0;
uniform vec4 rim_color : source_color = vec4(1.0, 0.93, 0.62, 1.0);
uniform float rim_strength : hint_range(0.0, 1.0) = 1.0;
uniform float bounce_width : hint_range(0.0, 12.0) = 5.0;
uniform vec4 bounce_color : source_color = vec4(0.35, 0.65, 1.0, 0.9);
uniform float bounce_strength : hint_range(0.0, 1.0) = 0.9;
uniform float light_mix : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	if (base.a <= 0.001) {
		discard;
	}

	vec4 tint = COLOR;
	vec2 direction = normalize(light_dir);
	vec2 pixel = TEXTURE_PIXEL_SIZE;

	float alpha_rim = texture(
		TEXTURE,
		UV - direction * pixel * rim_width
	).a;
	float alpha_bounce = texture(
		TEXTURE,
		UV + direction * pixel * bounce_width
	).a;

	float rim_mask = clamp(base.a - alpha_rim, 0.0, 1.0);
	float bounce_mask = clamp(base.a - alpha_bounce, 0.0, 1.0);
	// Consul's line art sits right on the silhouette; keep the rim visible over
	// the dark outline instead of filtering it out.
	float not_outline = 1.0;

	float rim = clamp(rim_mask * not_outline * rim_strength, 0.0, 1.0);
	float bounce = clamp(
		bounce_mask * not_outline * bounce_strength,
		0.0,
		1.0
	);

	vec3 rimmed = mix(base.rgb, rim_color.rgb, light_mix);
	vec3 bounced = mix(base.rgb, bounce_color.rgb, light_mix);
	vec3 color = mix(base.rgb, bounced, bounce);
	color = mix(color, rimmed, rim);

	COLOR = vec4(color, base.a) * tint;
}
