shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform int color_levels : hint_range(2, 256) = 12;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.05;

// New controls for the outline
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float edge_threshold : hint_range(0.0, 1.0) = 0.1;

float get_luminance(vec3 rgb) {
    return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
    vec2 uv = SCREEN_UV;
    vec2 pixel_size = SCREEN_PIXEL_SIZE;
    
    // 1. Sobel-style Edge Detection
    float center = get_luminance(texture(screen_texture, uv).rgb);
    float top    = get_luminance(texture(screen_texture, uv + vec2(0.0, -pixel_size.y)).rgb);
    float bottom = get_luminance(texture(screen_texture, uv + vec2(0.0, pixel_size.y)).rgb);
    float left   = get_luminance(texture(screen_texture, uv + vec2(-pixel_size.x, 0.0)).rgb);
    float right  = get_luminance(texture(screen_texture, uv + vec2(pixel_size.x, 0.0)).rgb);
    
    float edge = abs(top - bottom) + abs(left - right);
    
    // 2. Sample and Dither
    vec4 raw_color = texture(screen_texture, uv);
    float dither = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
    vec3 color = raw_color.rgb + (dither * dither_strength);
    
    // 3. Posterize
    float levels = float(color_levels);
    color = floor(color * levels) / levels;
    
    // 4. Apply Outline Color
    // We use clamp to ensure the edge value stays between 0 and 1
    float edge_mask = step(edge_threshold, edge);
    color = mix(color, outline_color.rgb, edge_mask * outline_color.a);

    COLOR = vec4(color, 1.0);
}