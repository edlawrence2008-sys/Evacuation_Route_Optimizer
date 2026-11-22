#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;


layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
//layout(set = 0, binding = 1) uniform sampler2D texture_in;


layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float some_property;
	float _;
} params;

//#include "../General/Includes/scene_data.glsl"
/*
layout(binding = 2) uniform SceneDataBlock {
	SceneData data;
} scene;
*/

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (coord.x >= size.x || coord.y >= size.y) {
		return;
	}

	//vec2 uv = (coord + 0.5) / size;

	vec4 color = imageLoad(color_image, coord);

	imageStore(color_image, coord, color);
}
