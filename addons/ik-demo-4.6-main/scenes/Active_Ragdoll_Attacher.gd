
extends PhysicalBoneSimulator3D

@export var target_skeleton: Skeleton3D

@export var stiffness: float = 1500.0
@export var damping: float = 30.0

var physics_bones: Array[PhysicalBone3D] = []
var hand_bones: Array[PhysicalBone3D] = []

var owner_skeleton: Skeleton3D


func _ready() -> void:
	owner_skeleton = get_parent() as Skeleton3D

	if owner_skeleton == null:
		push_error("Active Ragdoll: Parent must be a Skeleton3D.")
		return

	if target_skeleton == null:
		push_error("Active Ragdoll: Assign target_skeleton in the Inspector.")
		return

	var anchor_keywords: Array[String] = [
		"hand",
		"thumb",
		"index",
		"middle",
		"ring",
		"pinky"
	]

	var simulated_bone_names: Array[StringName] = []

	# Classify physical bones before starting simulation.
	for child in get_children():
		if not (child is PhysicalBone3D):
			continue

		var bone := child as PhysicalBone3D
		var bone_idx: int = bone.get_bone_id()

		if bone_idx < 0:
			push_warning(
				"Active Ragdoll: Invalid bone assignment on " + bone.name
			)
			continue

		var skeleton_bone_name: String = owner_skeleton.get_bone_name(bone_idx)
		var search_name: String = (
			(skeleton_bone_name + " " + bone.name).to_lower()
		)

		var is_hand_bone := false

		for keyword in anchor_keywords:
			if search_name.contains(keyword):
				is_hand_bone = true
				break

		if is_hand_bone:
			# Leave these bones animation-driven.
			hand_bones.append(bone)
		else:
			# These bones participate in physics.
			physics_bones.append(bone)
			simulated_bone_names.append(
				StringName(skeleton_bone_name)
			)

	# Start simulation only for the selected body bones.
	if not simulated_bone_names.is_empty():
		physical_bones_start_simulation(simulated_bone_names)
	else:
		push_warning(
			"Active Ragdoll: No body bones were selected for simulation."
		)


func _physics_process(_delta: float) -> void:
	if target_skeleton == null or owner_skeleton == null:
		return

	# Drive simulated body bones toward the animated target pose.
	for bone in physics_bones:
		var bone_idx: int = bone.get_bone_id()

		if bone_idx < 0:
			continue

		if bone_idx >= target_skeleton.get_bone_count():
			continue

		# Convert target bone pose into world space.
		var target_transform: Transform3D = (
			target_skeleton.global_transform
			* target_skeleton.get_bone_global_pose(bone_idx)
		)

		var current_transform: Transform3D = bone.global_transform

		var current_rot: Quaternion = (
			current_transform.basis.get_rotation_quaternion()
		)

		var target_rot: Quaternion = (
			target_transform.basis.get_rotation_quaternion()
		)

		# Calculate rotational error.
		var rot_error: Quaternion = (
			target_rot * current_rot.inverse()
		).normalized()

		if rot_error.w < 0.0:
			rot_error = Quaternion(
				-rot_error.x,
				-rot_error.y,
				-rot_error.z,
				-rot_error.w
			)

		var axis: Vector3 = rot_error.get_axis()
		var angle: float = rot_error.get_angle()

		# Proportional-derivative angular velocity controller.
		var control_velocity: Vector3 = (
			axis * angle * stiffness
			- bone.angular_velocity * damping
		)

		bone.angular_velocity = control_velocity
