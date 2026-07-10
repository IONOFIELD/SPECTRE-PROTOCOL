class_name Trooper
extends Node3D

## Ten box limbs, real two-bone IK, no keyframes. Ported from the JS solver that
## was verified to 0.00000 m bone-length error across the full gait sweep.
##
## Godot is Y-up and models face -Z. Local space here:
##   +Y up, -Z forward, +X left. Feet at y = 0.
##
## The pelvis is HIGHEST at midstance (single support, leg near straight) and
## drops at double support. Get that backwards and the walk looks like a bounce.
## The hip sits at 0.90 against a 0.91 leg, so the knee is never fully locked.

const HIP: float = 0.90
const HALF_HIP: float = 0.10
const HALF_SH: float = 0.19
const THIGH: float = 0.455
const SHIN: float = 0.455    # thigh + shin = 0.910 > HIP. required.
const ANKLE: float = 0.075
const FOOT_LEN: float = 0.15
const SPINE: float = 0.55     # offsets ABOVE the pelvis, so bob carries the torso
const NECK: float = 0.72
const UPPER_ARM: float = 0.31
const FORE_ARM: float = 0.27

const STRIDE_M: float = 0.60     # metres per half cycle
const BLIP_PX: float = 6.0

@export var unit_type: StringName = &"cbt"   # cbt rec snp med cdr eod
@export var is_elite := false
@export var speed_mps := 0.0

var gait := 0.0
var _limbs: Array[MeshInstance3D] = []
var _meshes: Array[BoxMesh] = []
var _radii: Array[float] = []
var _snap_res := Vector2i(640, 360)

# limb index -> [radius, material]
const LIMB_DEF: Array = [
	[0.122, "torso"], [0.072, "torso"], [0.058, "torso"], [0.050, "torso"],
	[0.072, "torso"], [0.058, "torso"], [0.050, "torso"],
	[0.055, "arm"],   [0.047, "arm"],
	[0.055, "arm"],   [0.047, "arm"],
	[0.033, "weapon"],
]


func setup(snap_res: Vector2i) -> void:
	_snap_res = snap_res
	var torso_mat: String = "cloth"
	if is_elite:
		torso_mat = "suit_elite"
	elif unit_type == &"eod" or unit_type == &"cbt":
		torso_mat = "cloth_hvy"
	var arm_mat: String = "suit_elite" if is_elite else "cloth"

	for def in LIMB_DEF:
		var r: float = def[0]
		var mesh: BoxMesh = BoxMesh.new()
		mesh.size = Vector3(r * 2.0, 0.1, r * 2.0)
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		var mat_name: String = "weapon"
		if def[1] == "torso":
			mat_name = torso_mat
		elif def[1] == "arm":
			mat_name = arm_mat
		mi.material_override = ThermalLib.get_material(mat_name, _snap_res)
		add_child(mi)
		_limbs.append(mi)
		_meshes.append(mesh)
		_radii.append(r)

	# head
	var head: MeshInstance3D = MeshInstance3D.new()
	var hm: BoxMesh = BoxMesh.new()
	hm.size = Vector3(0.19, 0.21, 0.185)
	head.mesh = hm
	head.material_override = ThermalLib.get_material("suit_elite" if is_elite else "helmet", _snap_res)
	add_child(head)
	_limbs.append(head)
	_meshes.append(hm)
	_radii.append(0.1)

	# exposed face. the single hottest thing on a person, and the reason a
	# helmeted operator still reads as a person and not a rock.
	if not is_elite:
		var face: MeshInstance3D = MeshInstance3D.new()
		var fm: BoxMesh = BoxMesh.new()
		fm.size = Vector3(0.125, 0.10, 0.05)
		face.mesh = fm
		face.material_override = ThermalLib.get_material("skin", _snap_res)
		add_child(face)
		_limbs.append(face)
		_meshes.append(fm)
		_radii.append(0.06)


## planar 2-bone IK in the sagittal plane (y up, z forward-negative).
## Returns [joint, clamped_end] so bone lengths stay exact when out of reach.
static func _two_bone(root: Vector2, target: Vector2, l1: float, l2: float, pole: float) -> Array:
	var d: Vector2 = target - root
	var len_d: float = d.length()
	var max_d: float = (l1 + l2) * 0.9995
	var min_d: float = absf(l1 - l2) * 1.0005 + 1e-4
	if len_d > max_d:
		d *= max_d / len_d
		len_d = max_d
	elif len_d < min_d:
		d *= min_d / maxf(len_d, 1e-6)
		len_d = min_d
	var ca: float = clampf((l1 * l1 + len_d * len_d - l2 * l2) / (2.0 * l1 * len_d), -1.0, 1.0)
	var th: float = atan2(d.y, d.x) + acos(ca) * pole
	return [root + Vector2(cos(th), sin(th)) * l1, root + d]


## joints in local space. x2 = (forward, height) sagittal pairs.
func _pose() -> Dictionary:
	var moving: bool = speed_mps > 0.05
	var amp: float = minf(1.0, speed_mps / 1.7)
	var p: float = gait

	var drop: float = (1.0 - absf(sin(p))) * 0.045 * amp if moving else 0.0
	var idle: float = 0.0 if moving else sin(p * 0.5) * 0.006
	var pel_y: float = HIP - drop + idle
	var lean: float = 0.14 * amp if moving else 0.04
	var roll: float = sin(p) * 0.020 * amp if moving else 0.0

	var stride: float = 0.30 * amp
	var lift: float = 0.17 * amp

	var ankle_t: Callable = func(ph: float) -> Vector2:
		var s: float = sin(ph)
		return Vector2(cos(ph) * stride, ANKLE + (s * lift if s > 0.0 else 0.0))

	var hipL: Vector2 = Vector2(0.0, pel_y - roll)
	var hipR: Vector2 = Vector2(0.0, pel_y + roll)
	# pole +1: the knee sits FORWARD of the hip-ankle line. With -1 the leg bent
	# backwards at the knee, which is a bird, not an operator.
	var legL: Array = _two_bone(hipL, ankle_t.call(p), THIGH, SHIN, 1.0)
	var legR: Array = _two_bone(hipR, ankle_t.call(p + PI), THIGH, SHIN, 1.0)

	var sh_c: Vector2 = Vector2(lean * 0.34, pel_y + SPINE)
	var twist: float = -sin(p) * 0.09 * amp if moving else 0.0
	var shL: Vector2 = Vector2(sh_c.x - twist * 0.16, sh_c.y)
	var shR: Vector2 = Vector2(sh_c.x + twist * 0.16, sh_c.y)
	var head: Vector2 = Vector2(sh_c.x + lean * 0.12, pel_y + NECK)

	var reach: float = 0.30 if unit_type == &"eod" else 0.35
	var gun_y: float = sh_c.y - 0.15
	# pole -1: the elbow hangs BELOW the shoulder-hand line. With +1 it floated
	# above the shoulder, which is a marionette.
	var armL: Array = _two_bone(shL, Vector2(sh_c.x + reach + 0.11, gun_y - 0.02), UPPER_ARM, FORE_ARM, -1.0)
	var armR: Array = _two_bone(shR, Vector2(sh_c.x + reach - 0.15, gun_y + 0.03), UPPER_ARM, FORE_ARM, -1.0)

	return {
		"pelvis": Vector3(0.0, pel_y, 0.0),
		"sh_c": Vector3(0.0, sh_c.y, -sh_c.x),
		"hipL": Vector3(HALF_HIP, hipL.y, 0.0),
		"hipR": Vector3(-HALF_HIP, hipR.y, 0.0),
		"kneeL": Vector3(HALF_HIP, legL[0].y, -legL[0].x),
		"kneeR": Vector3(-HALF_HIP, legR[0].y, -legR[0].x),
		"ankL": Vector3(HALF_HIP, legL[1].y, -legL[1].x),
		"ankR": Vector3(-HALF_HIP, legR[1].y, -legR[1].x),
		"toeL": Vector3(HALF_HIP, maxf(0.02, legL[1].y - ANKLE * 0.6), -legL[1].x - FOOT_LEN),
		"toeR": Vector3(-HALF_HIP, maxf(0.02, legR[1].y - ANKLE * 0.6), -legR[1].x - FOOT_LEN),
		"shL": Vector3(HALF_SH, shL.y, -shL.x),
		"shR": Vector3(-HALF_SH, shR.y, -shR.x),
		"elbL": Vector3(0.07, armL[0].y, -armL[0].x),
		"elbR": Vector3(-0.14, armR[0].y, -armR[0].x),
		"handL": Vector3(0.05, armL[1].y, -armL[1].x),
		"handR": Vector3(-0.14, armR[1].y, -armR[1].x),
		"head": Vector3(0.0, head.y, -head.x),
	}


func _set_limb(i: int, a: Vector3, b: Vector3) -> void:
	var d: Vector3 = b - a
	var l: float = d.length()
	if l < 1e-4:
		return
	var dir: Vector3 = d / l
	var up: Vector3 = Vector3.FORWARD if absf(dir.z) < 0.9 else Vector3.RIGHT
	var x: Vector3 = up.cross(dir).normalized()
	var z: Vector3 = dir.cross(x)
	var r: float = _radii[i]
	_meshes[i].size = Vector3(r * 2.0, l, r * 2.0)
	_limbs[i].transform = Transform3D(Basis(x, dir, z), (a + b) * 0.5)


func apply_pose() -> void:
	var J: Dictionary = _pose()
	_set_limb(0, J.pelvis, J.sh_c)
	_set_limb(1, J.hipL, J.kneeL);  _set_limb(2, J.kneeL, J.ankL);  _set_limb(3, J.ankL, J.toeL)
	_set_limb(4, J.hipR, J.kneeR);  _set_limb(5, J.kneeR, J.ankR);  _set_limb(6, J.ankR, J.toeR)
	_set_limb(7, J.shL, J.elbL);    _set_limb(8, J.elbL, J.handL)
	_set_limb(9, J.shR, J.elbR);    _set_limb(10, J.elbR, J.handR)

	var gun_len: float = 0.80
	if unit_type == &"snp":
		gun_len = 1.10
	elif unit_type == &"eod":
		gun_len = 0.62
	elif unit_type == &"rec":
		gun_len = 0.66
	_set_limb(11, J.handR, J.handR + Vector3(0.03, -0.02, -gun_len))

	_limbs[12].position = J.head + Vector3(0, 0.01, 0)      # head box
	if _limbs.size() > 13:
		_limbs[13].position = J.head + Vector3(0.0, 0.04, -0.085)   # face


func advance(delta: float, moving: bool) -> void:
	if moving:
		gait += (speed_mps * delta) / STRIDE_M * PI   # phase from distance. no foot slide.
	else:
		gait += delta * 0.7
		speed_mps = 0.0


func _process(delta: float) -> void:
	apply_pose()
