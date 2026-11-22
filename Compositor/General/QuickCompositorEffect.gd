@tool
extends R_BaseCompositorEffect
class_name QuickCompositorEffect


@export_enum("File", "Text") var shader_source: int
@export_file_path("*.glsl") var shader_file: String:
	set(v):
		shader_file = v; _initialize_render()
@export_multiline("monospace", "no_wrap") var shader_text: String:
	set(v):
		shader_text = v
		recompile_needed = true; recompile_timer = 1.0


@export var params: Array:
	set(v):
		params = v; update_push_constant()


var recompile_needed: bool
var recompile_timer: float


var shader: RID
var pipeline: RID

var push_constant: PackedByteArray


func _initialize_resource() -> void:
	if shader_text == "":
		shader_text = "#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D texture_in;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float some_property;
	float _;
} params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);

	if (coord.x >= size.x || coord.y >= size.y) {
		return;
	}

	vec2 uv = (coord + 0.5) / size;

	vec4 color = texture(texture_in, uv);

	imageStore(color_image, coord, color);
}
"


func _initialize_render() -> void:
	if shader.is_valid():
		free_rid(shader)
	
	if shader_source == 0 and shader_file != "":
		shader = create_shader(shader_file)
	elif shader_text != "":
		var source: RDShaderSource = RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.source_compute = shader_text
		
		var spirv = rd.shader_compile_spirv_from_source(source)
		if spirv.compile_error_compute != "":
			printerr(spirv.compile_error_compute)
		shader = rd.shader_create_from_spirv(spirv)
	
	if shader.is_valid():
		pipeline = create_pipeline(shader)
		add_rid_to_free(shader, "shader")
		
		update_push_constant()


func _render_setup() -> void:
	if recompile_needed:
		recompile_timer -= Engine.get_main_loop().root.get_process_delta_time()
		if recompile_timer < 0:
			_initialize_render()
			recompile_needed = false


func _render_view(view : int) -> void:
	if !shader.is_valid():
		return
	set_workgroups(8)
	run_compute_shader("Your shader", shader, pipeline,
		[[
			get_color_image_uniform(view, 0),
			#get_image_uniform(render_scene_buffers.get_texture_slice("rb_ssao", "final", 0, 0, 1, 1), 0),
			get_color_sampler_uniform(view, linear_sampler, 1),
			#get_sampler_uniform(render_scene_buffers.get_texture_slice("rb_ssao", "final", 0, 0, 1, 1), linear_sampler, 1),
		]],
		push_constant)


func _render_size_changed() -> void:
	update_push_constant()


func update_push_constant() -> void:
	var array: Array = [Vector2(render_size)]
	for param in params:
		array.append(param)
	
	push_constant = create_push_constant(array)
