@tool
extends R_BaseCompositorEffect
class_name TexturePreview


const shader_path: String = "res://Compositor/General/Texture_preview.glsl"

## Context from render buffers.
@export var context: String

## Id from render buffers.
@export var id: String

## Running compositor effect to preview texture buffer from.
## 'Context' must be empty to use this.
@export var effect_target: CompositorEffect

## Variable name from 'effect_target', must be texture buffer RID.
@export var effect_texture_id: String

## Color channel to display.
## -1 - all, 0 - red, 1 - green, 2 - blue, 3 - alpha
@export_range(-1, 3) var channel: int = -1

## Size divider of the buffer relative to the screen
@export_range(1, 32) var size_div: int = 1

## Use bilinear sampling instead of nearest
@export var linear: bool

## Message from the script
@export_multiline() var msg: String

@export_group("Errors")
@export var show_nan_inf: bool
@export var nan_color: Color = Color(1,0,1)
@export var inf_color: Color = Color(0,1,1)
@export var screen_fade: float = 1


var shader: RID
var pipeline: RID


func _initialize_resource() -> void:
	workgroup_size_default = 8


func _initialize_render() -> void:
	shader = create_shader(shader_path)
	pipeline = create_pipeline(shader)


func _render_view(view : int) -> void:
	var texture: RID
	
	if !effect_target and context != "":
		if id == "":
			return
		if !render_scene_buffers.has_texture(context, id):
			msg = "Texture doesn't exist :("
			return
		else:
			msg = "Ok"
			texture = render_scene_buffers.get_texture(context, id)
	elif effect_target:
		var txid: String = effect_texture_id
		var arridx: int = -1
		txid = txid.strip_edges()
		if txid.contains("["):
			txid = txid.split("[")[0]
			arridx = effect_texture_id.split("[")[1].replace("]", "").to_int()
		
		var texture_from_target = effect_target.get(txid)
		if arridx != -1:
			texture_from_target = texture_from_target[arridx]
		if texture_from_target and texture_from_target is RID and rd.texture_is_valid(texture_from_target):
			if texture_from_target.is_valid():
				texture = texture_from_target
				msg = "Ok"
			else:
				msg = "Texture not valid :("
				return
		else:
			msg = "Texture var doesn't exist or is wrong :("
			return
	else:
		if show_nan_inf:
			msg = "Displaying error debug"
			texture = render_scene_buffers.get_color_texture()
		else:
			msg = "Provide context and id OR compositor effect and texture RID var name.
'Show Nan Inf' to show texture errors."
			return
	
	render_size /= size_div
	
	run_compute_shader("Preview", shader, pipeline, 
	[[get_color_image_uniform(view, 0), get_sampler_uniform(texture, nearest_sampler if !linear else linear_sampler, 1)]],
	create_push_constant([Vector2(render_size), int(channel), 
	1 if show_nan_inf else 0, 0,
	nan_color.r, nan_color.g, nan_color.b,
	inf_color.r, inf_color.g, inf_color.b,
	1.0 - screen_fade]))


func _render_setup() -> void: pass

func _render_size_changed() -> void: pass
