#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, binding = 0) uniform restrict writeonly image2D image_out;
layout(binding = 1) uniform sampler2D image_in;

layout(push_constant, std430) uniform Params {
	vec2 size;
	int channel;
	int error_debug;
	int _;

	float nanR;
	float nanG;
	float nanB;
	float infR;
	float infG;
	float infB;
	float error_fade;
} params;


void main() {
	
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);

	vec4 img = texture(image_in, (coord + 0.5) / vec2(params.size.x, params.size.y));
	int channel = int(params.channel);

	if (params.error_debug == 1)
	{
		img.rgb = img.rgb * params.error_fade;
		img.a = 1.0;
		if (isnan(img.r) || isnan(img.g) || isnan(img.b) || isnan(img.a))
		{
			img.rgb = vec3(params.nanR, params.nanG, params.nanB);
		}
		if (isinf(img.r) || isinf(img.g) || isinf(img.b) || isinf(img.a))
		{
			img.rgb = vec3(params.infR, params.infG, params.infB);
		}
	}

	if(channel == -1){
		imageStore(image_out, coord, img);}
	else{
		imageStore(image_out, coord, vec4(vec3(img[channel]), 1));}
}