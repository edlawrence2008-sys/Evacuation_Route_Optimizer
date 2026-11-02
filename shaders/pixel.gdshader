shader_type spatial;
render_mode unshaded, skip_vertex_transform;

// In Godot 4 Spatial shaders, we use hint_screen_texture and hint_depth_texture
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

group_uniforms Effect_Controls;
uniform float brightness : hint_range(0.0, 4.0) = 1.0;
uniform float contrast : hint_range(0.0, 4.0) = 1.5;
uniform float gamma : hint_range(0.1, 4.0) = 1.2;
uniform vec4 nv_tint : source_color = vec4(0.2, 1.0, 0.4, 1.0);
uniform bool invert = true;

group_uniforms Lidar_Settings;
uniform float dot_density : hint_range(1.0, 100.0) = 50.0;
uniform float dot_size : hint_range(0.01, 0.5) = 0.15;
uniform vec4 dot_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

group_uniforms Outline;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float edge_threshold : hint_range(0.0, 1.0) = 0.1;

float get_luminance(vec3 rgb) {
    return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

void vertex() {
    // This forces the mesh to stay pinned to the camera screen
    POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
    vec2 uv = SCREEN_UV;
    
    // 1. Reconstruct World Position from Depth
    float depth = texture(depth_texture, uv).r;
    vec4 upos = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec3 view_pos = upos.xyz / upos.w;
    // We use the View Matrix to get coordinates relative to the world
    vec3 world_pos = (INV_VIEW_MATRIX * vec4(view_pos, 1.0)).xyz;

    // 2. Create the Lidar Dot Grid (World-Space Locked)
    vec3 dots = sin(world_pos * dot_density);
    float dot_mask = smoothstep(1.0 - dot_size, 1.0, dots.x * dots.y * dots.z);

    // 3. Base Image & Night Vision Logic
    vec3 raw_color = texture(screen_texture, uv).rgb;
    
    // Apply Contrast
    vec3 color = mix(vec3(0.5), raw_color, contrast);
    color *= brightness;
    
    // Invert & Gamma
    if (invert) color = 1.0 - color;
    color = pow(max(color, vec3(0.0)), vec3(1.0 / gamma));
    color *= nv_tint.rgb;

    // 4. Sharp Outlines (Sobel)
    // We sample surrounding pixels for edge detection
    vec2 ps = VIEWPORT_SIZE;
    float top    = get_luminance(texture(screen_texture, uv + vec2(0.0, -1.0/ps.y)).rgb);
    float bottom = get_luminance(texture(screen_texture, uv + vec2(0.0, 1.0/ps.y)).rgb);
    float left   = get_luminance(texture(screen_texture, uv + vec2(-1.0/ps.x, 0.0)).rgb);
    float right  = get_luminance(texture(screen_texture, uv + vec2(1.0/ps.x, 0.0)).rgb);
    float edge = abs(top - bottom) + abs(left - right);
    float edge_mask = step(edge_threshold, edge);

    // 5. Combine everything
    color = mix(color, dot_color.rgb, dot_mask * dot_color.a);
    color = mix(color, outline_color.rgb, edge_mask * outline_color.a);

    ALBEDO = color;
}