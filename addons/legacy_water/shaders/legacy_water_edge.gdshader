shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D foam_texture : repeat_enable, filter_nearest;
uniform float texture_width = 64.0;
uniform float scroll_speed = 3.0;


void fragment() {
	// UV.x is in texture-width units (one world texel advances by
	// 1 / texture_width). Snapping the scroll to whole texels keeps the foam
	// pattern pixel-locked while it moves along the shore.
	float scroll = floor(TIME * scroll_speed);
	vec2 uv = vec2(UV.x + scroll / texture_width, UV.y);
	vec4 tex = texture(foam_texture, uv);

	ALBEDO = tex.rgb;
	// Keep the foam either fully present or fully discarded so the texture
	// holes stay voxel-pixel shaped.
	ALPHA = step(0.5, tex.a);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
