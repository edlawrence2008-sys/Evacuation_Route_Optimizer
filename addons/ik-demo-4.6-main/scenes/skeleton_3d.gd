extends Skeleton3D

@export_category("IK Targets & Poles")
@export var body_target: Node3D

@export_group("Right Arm")
@export var r_arm_marker: Node3D
@export var r_arm_pole: Node3D

@export_group("Left Arm")
@export var l_arm_marker: Node3D
@export var l_arm_pole: Node3D

@export_group("Right Feet")
@export var r_feet_marker: Node3D
@export var r_feet_pole: Node3D

@export_group("Left Feet")
@export var l_feet_marker: Node3D
@export var l_feet_pole: Node3D

@export_category("Head")
@export var head_target: Node3D

# Bone indices (Update these strings to match your actual bone names in your Skeleton3D)
var r_arm_bone_idx: int
var l_arm_bone_idx: int
var r_feet_bone_idx: int
var l_feet_bone_idx: int
var head_bone_idx: int

func _ready() -> void:
	# Cache bone indices by their name in the skeleton
	# Replace "shoulder.R", "shoulder.L", etc., with your actual rig bone names
	r_arm_bone_idx = find_bone("upper_arm.R")
	l_arm_bone_idx = find_bone("upper_arm.L")
	r_feet_bone_idx = find_bone("leg.R")
	l_feet_bone_idx = find_bone("leg.L")
	head_bone_idx = find_bone("head")

func _process(delta: float) -> void:
	# Ensure targets are assigned before applying transforms
	if not body_target:
		return

	# Example: Aligning/moving specific bones or driving SkeletonIK nodes via script.
	# If you are managing transforms manually or syncing with SkeletonIK3D nodes in your tree,
	ynh_apply_ik()

func ynh_apply_ik() -> void:
	# Custom IK constraint logic or updating bone global poses goes here.
	# For example, to point the head toward the head_target:
	if head_target and head_bone_idx != -1:
		var head_global_pose = get_bone_global_pose(head_bone_idx)
		# Modify global pose rotation/position to look at head_target position...
		# set_bone_global_pose(head_bone_idx, head_global_pose)
		pass
