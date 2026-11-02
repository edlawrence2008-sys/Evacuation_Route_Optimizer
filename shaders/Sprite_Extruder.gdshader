shader_type spatial;
// Removed "unshaded" to enable Godot's built-in PBR lighting system
render_mode depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

/** Controls the overall 3D thickness/depth of the extruded item */
uniform float thickness : hint_range(0.01, 2.0) = 0.2;

/** Ignore transparent pixels with alpha below this value for extrusion */
uniform float extruded_alpha_cull : hint_range(0.0, 1.0) = 1.0;
/** If transparent pixels are extruded, this makes extruded pixels opaque */
uniform bool opaque_extrude = true;
/** Keeps original image on front and back of cube
 * Unaffected by most other parameters */
uniform bool keep_image = true;
/** Removes transparent pixels with alpha below this value on original image */
uniform float image_alpha_cull : hint_range(0.0, 1.0) = 1.0;
/** Offset extruded portion by this vector */
uniform vec2 offset = vec2(0.0);
/** Color which will be mixed with extruded portion */
uniform vec4 color_mix : source_color = vec4(0.0, 0.0, 0.0, 1.0);
/** 0 is no color mix, 1 is solid color */
uniform float mix_strength : hint_range(0.0, 1.0) = 0.0;
/** 2D image where opaque pixels are extruded */ 
uniform sampler2D Texture : source_color, filter_nearest;
/** Amount of times each pixel refers to the original image */
uniform int texture_calls = 20;
/** Ray bias value shifts intersecton checks to try to avoid checking empty sides */
uniform float ray_bias = 1;
/** Allows hollow regions in texture to extrude infinitely */
uniform bool infinite_holes = false;
/** Parameters to change if your texture is a spritesheet */
uniform int Hframes = 1;
/** Parameters to change if your texture is a spritesheet */
uniform int Vframes = 1;
/** Parameters to change if your texture is a spritesheet */
uniform int frame = 0;

struct imgPoint {
    vec4 color;
    vec2 uv;
};

bool isInImg(vec2 uv){
     return     uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0;
}

vec2 getPositionAlongTheLine(vec2 a, vec2 b, float percentage) {
    return vec2(a.x * (1.0 - percentage) + b.x * percentage, a.y * (1.0 - percentage) + b.y * percentage);
}

vec2 lineImgIntersect(vec2 x, vec2 y){
    float t = 0.0;
    float xY = y.x;
    float yY = -y.y;
    float xX = x.x;
    float yX = -x.y;
    float xA = 0.0;
    float yA = -1.0;
    float xC = 1.0;
    float yC = -0.0;
    if(xY == xX) {
        t =  max((yA - yX)/(yY - yX), (yC - yX)/(yY - yX));
    } else {
        if(yY == yX) {
            t = max((xA - xX)/(xY - xX), (xC - xX)/(xY - xX));
        } else {
            if(xY > xX) {
                if(yY > yX) {
                    t = min((xC - xX)/(xY - xX), (yC - yX)/(yY - yX));
                } else {
                    t = min((xC - xX)/(xY - xX), (yA - yX)/(yY - yX));
                }
            } else {
                if(yY > yX) {
                    t = min((xA - xX)/(xY - xX), (yC - yX)/(yY - yX));
                } else {
                    t = min((xA - xX)/(xY - xX), (yA - yX)/(yY - yX));
                }
            }
        }
    }
    float xE = t * xY + (1.0 - t) * xX;
    float yE = t * yY + (1.0 - t) * yX;
    return vec2(xE, -yE);
}

vec2 frameUV(vec2 uv){
    int hFrame = frame % Hframes;
    int vFrame = frame / Vframes;
    uv.x = uv.x/float(Hframes) + float(hFrame)/float(Hframes);
    uv.y = uv.y/float(Vframes) + float(vFrame)/float(Vframes);
    return uv;
}

vec2 flippedFrameUV(vec2 uv){
    float frameCenter = 0.5/float(Hframes) + float(frame % Hframes)/float(Hframes);
    uv = frameUV(uv);
    uv.x = -(uv.x - frameCenter) + frameCenter;
    return uv;
}

imgPoint imgExtrude(vec2 pos_on_img, vec2 slope, bool flipped){
    vec4 color;
    slope.y *= -1.0;
    vec2 edge = lineImgIntersect(pos_on_img, pos_on_img + slope);
    if (flipped) {
        pos_on_img = flippedFrameUV(pos_on_img);
        edge = flippedFrameUV(edge);
    } else {
        pos_on_img = frameUV(pos_on_img);
        edge = frameUV(edge);
    }
    bool extrude = false;
    vec2 point;
    int calls = texture_calls;
    float log_dir = -1.0;
    float log_percentage;
    for (int i = 0; i < calls; i++){
        if (!extrude) {
            float percentage = float(i) * 1.0/float(texture_calls);
            percentage = pow(percentage, ray_bias);
            point = getPositionAlongTheLine(pos_on_img, edge, percentage);
            color = texture(Texture, point + offset);
            if (color.w >= extruded_alpha_cull) {
                extrude = true;
                if (i == 0) break;
                calls - i;
                i = 0;
                log_percentage = percentage;
            }
        } else {
            float incremenet = log_dir * 1.0/(float(texture_calls)*float(i*2));
            log_percentage += incremenet;
            vec2 check_point = getPositionAlongTheLine(pos_on_img, edge, log_percentage);
            vec4 check_color = texture(Texture, check_point + offset);
            if (check_color.w >= extruded_alpha_cull) {
                color = check_color;
                point = check_point;
                log_dir = -1.0;
            } else log_dir = 1.0;
        }
    }
    if (extrude) {
        if (opaque_extrude) color.w = 1.0;
        color = mix(color, color_mix, mix_strength);
        if (infinite_holes) return imgPoint(color, pos_on_img);
        return imgPoint(color, point);
    }
    return imgPoint(vec4(0.0), edge);
}

vec2 UVtoXY(vec2 uv){
    vec2 xy = uv * 2.0 - vec2(1.0);
    xy.y *= -1.0;
    return xy;
}
vec2 XYtoUV(vec2 xy){
    vec2 uv = (xy + vec2(1.0)) / 2.0;
    uv.y *= -1.0;
    return uv;
}

vec3 PlaneLineIntersection(vec3 plane_point, vec3 plane_normal, vec3 line_point, vec3 line_dir){
    float t = (dot(plane_normal, plane_point) - dot(plane_normal, line_point)) / (dot(plane_normal, normalize(line_dir)));
    return line_point + normalize(line_dir) * t;
}

void vertex() {
    VERTEX.z *= thickness;
}

void fragment() {
    vec3 frag_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 camera_ray = normalize(frag_pos - CAMERA_POSITION_WORLD);
    vec3 model_ray = normalize((inverse(MODEL_MATRIX) * vec4(camera_ray, 0.0)).xyz);
    
    ivec2 face = ivec2(UV / vec2(1.0/3.0, 1.0/2.0));
    vec2 adjusted_UV = mod(UV,vec2(1.0/3.0, 1.0/2.0)) * vec2(3.0, 2.0);
    
    // We will dynamically write to this to tell the lighting engine where light bounces
    vec3 calculated_normal = vec3(0.0, 0.0, 1.0);

    // Z (Front Face)
    if (face.x == 0 && face.y == 0) {
        calculated_normal = vec3(0.0, 0.0, 1.0);
        vec4 color = texture(Texture, frameUV(adjusted_UV));
        if (color.w >= image_alpha_cull && keep_image) {
            ALBEDO = color.rgb;
            ALPHA = color.w;
        } else {
            imgPoint first_pixel = imgExtrude(adjusted_UV, model_ray.xy, false);
            ALBEDO = first_pixel.color.rgb;
            ALPHA = first_pixel.color.w;
            vec3 point = vec3(UVtoXY(adjusted_UV),2.0);
            vec3 ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, model_ray);
            vec2 uv_point = XYtoUV(ray_intersection.xy) + vec2(0.0,1.0);
            if (isInImg(uv_point)) {
                imgPoint second_pixel = imgExtrude(uv_point, -model_ray.xy, false);
                if (model_ray.y <= 0.0 && second_pixel.uv.y < first_pixel.uv.y ) ALPHA = 0.0;
                else if (model_ray.y > 0.0 && second_pixel.uv.y > first_pixel.uv.y ) ALPHA = 0.0;    
            }
        }
    } 
    // -Z (Back Face)
    else if (face.x == 2 && face.y == 0) {
        calculated_normal = vec3(0.0, 0.0, -1.0);
        vec4 color = texture(Texture, flippedFrameUV(adjusted_UV));
        if (color.w >= image_alpha_cull && keep_image) {
            ALBEDO = color.rgb;
            ALPHA = color.w;
        } else {
            imgPoint first_pixel = imgExtrude(adjusted_UV, vec2(-model_ray.x, model_ray.y), true);
            ALBEDO = first_pixel.color.rgb;
            ALPHA = first_pixel.color.w;
            
            vec3 point = vec3(UVtoXY(vec2(-adjusted_UV.x, adjusted_UV.y)),-2.0);
            vec3 ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, model_ray);
            vec2 uv_point = XYtoUV(ray_intersection.xy) + vec2(1.0,1.0);
            if (isInImg(uv_point)) {
                imgPoint second_pixel = imgExtrude(uv_point, -model_ray.xy, false);
                if (model_ray.y <= 0.0 && second_pixel.uv.y < first_pixel.uv.y ) ALPHA = 0.0;
                else if (model_ray.y > 0.0 && second_pixel.uv.y > first_pixel.uv.y ) ALPHA = 0.0;
            }
        }
    }
    // X (Right Edge)
    else if (face.x == 1 && face.y == 0) {
        calculated_normal = vec3(1.0, 0.0, 0.0);
        vec3 point = vec3(0.0, UVtoXY(adjusted_UV).yx);
        vec3 ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, -model_ray);
        vec3 image_intersection = PlaneLineIntersection(vec3(0.0), vec3(1.0,0.0,0.0), ray_intersection, vec3(model_ray.xy, 0.0));
        vec2 new_uv = XYtoUV(image_intersection.xy) + vec2(0.5, 1.0);
        vec4 img_color = imgExtrude(new_uv, model_ray.xy, false).color;
        ALBEDO = img_color.rgb;
        ALPHA = img_color.w;
        vec2 xy = UVtoXY(adjusted_UV);
        if (model_ray.z > 0.0) point = vec3(1.0, xy.y, -1.0 - xy.x);
        else point = vec3(1.0, xy.y, 1.0 - xy.x);
        ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, model_ray);
        vec2 uv_point = XYtoUV(ray_intersection.xy) + vec2(0,1.0);
        if (isInImg(uv_point)) {
            vec4 img_color = imgExtrude(uv_point, -model_ray.xy, false).color;
            if (img_color.w == 0.0) ALPHA = 0.0;
        }
    }
    // -X (Left Edge)
    else if (face.x == 0 && face.y == 1) {
        calculated_normal = vec3(-1.0, 0.0, 0.0);
        vec3 point = vec3(0.0, UVtoXY(adjusted_UV).yx);
        vec3 ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, -model_ray);
        vec3 image_intersection = PlaneLineIntersection(vec3(0.0), vec3(-1.0,0.0,0.0), ray_intersection, vec3(model_ray.xy, 0.0));
        vec2 new_uv = XYtoUV(image_intersection.xy) + vec2(-0.5, 1.0);
        vec4 img_color = imgExtrude(new_uv, model_ray.xy, false).color;
        ALBEDO = img_color.rgb;
        ALPHA = img_color.w;
        
        vec2 xy = UVtoXY(adjusted_UV);
        if (model_ray.z > 0.0) point = vec3(-1.0, xy.y, -1.0 + xy.x);
        else point = vec3(-1.0, xy.y, 1.0 + xy.x);
        ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, model_ray);
        vec2 uv_point = XYtoUV(ray_intersection.xy) + vec2(0.0,1.0);
        if (isInImg(uv_point)) {
            vec4 img_color = imgExtrude(uv_point, -model_ray.xy, false).color;
            if (img_color.w == 0.0) ALPHA = 0.0;
        }
    }
    // Y (Top Edge)
    else if (face.x == 1 && face.y == 1) {
        calculated_normal = vec3(0.0, 1.0, 0.0);
        vec2 rotated_UV = -UVtoXY(adjusted_UV);
        vec3 point = vec3(rotated_UV.x, 0.0, rotated_UV.y);
        vec3 ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, -model_ray);
        vec3 image_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,1.0,0.0), ray_intersection, vec3(model_ray.xy, 0.0));
        vec2 new_uv = XYtoUV(image_intersection.xy) + vec2(0.0,0.5);
        vec4 img_color = imgExtrude(new_uv, model_ray.xy, false).color;
        ALBEDO = img_color.rgb;
        ALPHA = img_color.w;
        
        vec2 xy = UVtoXY(vec2(-adjusted_UV.x, adjusted_UV.y));
        if (model_ray.z > 0.0) point = vec3(xy.x, 1.0, xy.y - 1.0);
        else point = vec3(xy.x, 1.0, xy.y + 1.0);
        ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, model_ray);
        vec2 uv_point = XYtoUV(ray_intersection.xy) + vec2(1.0,1.0);
        if (isInImg(uv_point)) {
            vec4 img_color = imgExtrude(uv_point, -model_ray.xy, false).color;
            if (img_color.w == 0.0) ALPHA = 0.0;
        }
    }
    // -Y (Bottom Edge)
    else if (face.x == 2 && face.y == 1) {
        calculated_normal = vec3(0.0, -1.0, 0.0);
        vec2 XY = UVtoXY(adjusted_UV);
        vec3 point = vec3(XY.x, 0.0, XY.y);
        vec3 ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, -model_ray);
        vec3 image_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,-1.0,0.0), ray_intersection, vec3(model_ray.xy, 0.0));
        vec2 new_uv = XYtoUV(image_intersection.xy);
        new_uv += vec2(0.0, 1.5);
        vec4 img_color = imgExtrude(new_uv, model_ray.xy, false).color;
        ALBEDO = img_color.rgb;
        ALPHA = img_color.w;
        
        vec2 xy = UVtoXY(adjusted_UV);
        if (model_ray.z > 0.0) point = vec3(xy.x, -1.0, xy.y - 1.0);
        else point = vec3(xy.x, -1.0, xy.y + 1.0);
        ray_intersection = PlaneLineIntersection(vec3(0.0), vec3(0.0,0.0,1.0), point, model_ray);
        vec2 uv_point = XYtoUV(ray_intersection.xy) + vec2(0.0,1.0);
        if (isInImg(uv_point)) {
            vec4 img_color = imgExtrude(uv_point, -model_ray.xy, false).color;
            if (img_color.w == 0.0) ALPHA = 0.0;
        }
    }

    // Convert local face normal to world space so Godot lights can illuminate it accurately
    NORMAL = (MODEL_MATRIX * vec4(calculated_normal, 0.0)).xyz;
}