shader_type canvas_item;

// Controls how many pixels the texture jumps every single frame
uniform float pixels_per_frame : hint_range(10.0, 500.0) = 150.0;
// Controls how violently the frame jumps up and down randomly
uniform float jitter_intensity : hint_range(0.0, 0.1) = 0.02;

// Scanline controls
uniform float scanline_count : hint_range(10.0, 1000.0) = 300.0;
uniform float scanline_opacity : hint_range(0.0, 1.0) = 0.25;

// Simple pseudo-random noise function
float hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

void fragment() {
    // 1. Get the texture size in pixels so we can do pixel-perfect scrolling
    vec2 tex_size = vec2(textureSize(TEXTURE, 0));
    
    // 2. We use a high-frequency hash based on TIME to generate a unique ID for EVERY frame.
    // This acts as a rigid frame counter that forces a hard reset on every render tick.
    float frame_id = floor(TIME * 60.0); 
    
    // 3. Calculate a pixel-perfect scroll that jumps deterministically every frame, 
    // then divide by texture size to convert back to UV space (0.0 to 1.0)
    float pixel_scroll = mod(frame_id * pixels_per_frame, tex_size.y);
    float uv_scroll = pixel_scroll / tex_size.y;
    
    // 4. Add the choppy, mechanical jitter
    float jitter = hash(frame_id) * jitter_intensity;
    
    // 5. Wrap the UV coordinates strictly
    vec2 scrolled_uv = vec2(UV.x, fract(UV.y + uv_scroll + jitter));
    
    // 6. Sample the texture
    vec4 tex_color = texture(TEXTURE, scrolled_uv);
    
    // 7. Static scanlines (tied to raw Screen/UV coordinates, completely detached from the scroll)
    float scanline = sin(UV.y * scanline_count * 3.14159);
    scanline = smoothstep(-0.2, 0.2, scanline);
    vec3 final_color = mix(tex_color.rgb, tex_color.rgb * scanline, scanline_opacity);
    
    // 8. Subtle bulb flicker tied directly to the frame rate
    float bulb_flicker = mix(0.88, 1.0, hash(frame_id + 5.0));
    final_color *= bulb_flicker;
    
    // 9. Output while respecting Godot's built-in Modulate / Self-Modulate
    COLOR = vec4(final_color, tex_color.a) * COLOR;
}