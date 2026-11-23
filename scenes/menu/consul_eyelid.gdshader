shader_type canvas_item;

// Cuts a soft-edged elliptical hole out of the eyelid sprite.
// All values are in the eyelid's local pixel space (the sprite is centred).

uniform vec2 cutout_center = vec2(0.0, 0.0);
uniform vec2 cutout_radius = vec2(60.0, 60.0);
uniform float cutout_rotation = 0.0;
// 0 = ellipse, 1 = sharp left/right corners. The top/bottom stay elliptical.
uniform float cutout_sharpness = 0.7;

void fragment() {
	vec2 local = VERTEX - cutout_center;

	// Rotate into the iris frame so the hole squashes along the same axis.
	float c = cos(-cutout_rotation);
	float s = sin(-cutout_rotation);
	vec2 rotated = vec2(
		c * local.x - s * local.y,
		s * local.x + c * local.y
	);

	vec2 safe_radius = max(cutout_radius, vec2(0.0001));
	vec2 normalized = abs(rotated) / safe_radius;

	// Blend towards a diamond only near the horizontal ends. At x = 0 the
	// weight is zero, so the top/bottom curve stays a pure ellipse.
	float ellipse = normalized.x * normalized.x + normalized.y * normalized.y;
	float diamond = normalized.x + normalized.y;
	float corner_weight = smoothstep(0.1, 1.0, normalized.x);
	float distance = mix(ellipse, diamond, corner_weight * cutout_sharpness);

	// One-pixel antialiased rim instead of a hard discard edge.
	float aa = max(fwidth(distance), 0.0001);
	float hole_alpha = smoothstep(1.0 - aa, 1.0 + aa, distance);

	if (hole_alpha <= 0.0) {
		discard;
	}

	COLOR = texture(TEXTURE, UV) * COLOR;
	COLOR.a *= hole_alpha;
}
