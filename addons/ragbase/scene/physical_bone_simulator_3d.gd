extends PhysicalBoneSimulator3D

@export var target_skeleton: Skeleton3D

@export_group("Linear")
@export var linear_gain: float = 30.0      # 1/s: how fast position error is closed
@export var max_linear_speed: float = 20.0

@export_group("Angular")
@export var angular_gain: float = 30.0     # 1/s: how fast rotation error is closed
@export var max_angular_speed: float = 40.0

@export_group("Blend")
@export_range(0.0, 1.0) var strength: float = 0.8  # 1 = fully animation driven, 0 = limp ragdoll
@export var cancel_gravity: bool = true

var physics_bones: Array[PhysicalBone3D] = []
var prev_targets: Dictionary = {}  # PhysicalBone3D -> Transform3D

func _ready() -> void:
	for c in get_children():
		if c is PhysicalBone3D:
			physics_bones.append(c)
			if cancel_gravity:
				c.gravity_scale = 0.0
	physical_bones_start_simulation()

func _get_target_transform(b: PhysicalBone3D) -> Transform3D:
	var bone_id := b.get_bone_id()
	var t := target_skeleton.global_transform * target_skeleton.get_bone_global_pose(bone_id)
	t = t * b.body_offset          # <-- physics body is offset from the bone
	t.basis = t.basis.orthonormalized()
	return t

func _physics_process(delta: float) -> void:
	if not target_skeleton or delta <= 0.0:
		return

	for b in physics_bones:
		if b.get_bone_id() == -1:
			continue

		var target := _get_target_transform(b)
		var current := b.global_transform
		current.basis = current.basis.orthonormalized()

		# --- feedforward: how fast is the animated target itself moving? ---
		var ff_lin := Vector3.ZERO
		var ff_ang := Vector3.ZERO
		if prev_targets.has(b):
			var prev: Transform3D = prev_targets[b]
			ff_lin = (target.origin - prev.origin) / delta
			var dq := (target.basis * prev.basis.inverse()).get_rotation_quaternion()
			if dq.w < 0.0:
				dq = -dq
			ff_ang = _quat_to_rotvec(dq) / delta
		prev_targets[b] = target

		# --- linear: feedforward + proportional correction ---
		var pos_error := target.origin - current.origin
		var desired_lin := ff_lin + pos_error * linear_gain
		desired_lin = desired_lin.limit_length(max_linear_speed)

		# --- angular: feedforward + proportional correction (shortest path) ---
		var q_err := (target.basis * current.basis.inverse()).get_rotation_quaternion()
		if q_err.w < 0.0:
			q_err = -q_err
		var desired_ang := ff_ang + _quat_to_rotvec(q_err) * angular_gain
		desired_ang = desired_ang.limit_length(max_angular_speed)

		# --- blend toward desired velocities ---
		b.linear_velocity = b.linear_velocity.lerp(desired_lin, strength)
		b.angular_velocity = b.angular_velocity.lerp(desired_ang, strength)

func _quat_to_rotvec(q: Quaternion) -> Vector3:
	var s := sqrt(max(1.0 - q.w * q.w, 0.0))
	if s < 0.0001:
		return Vector3.ZERO
	var angle := 2.0 * acos(clampf(q.w, -1.0, 1.0))
	return Vector3(q.x, q.y, q.z) / s * angle
