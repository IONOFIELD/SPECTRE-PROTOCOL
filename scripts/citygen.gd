class_name CityGen
extends Node3D

## Low-poly city. One box is the mass. The parapet, the HVAC condenser and the
## water tank are the three details that stop a box reading as a box.
##
## Note the material trick: "wall" carries sky_loss 8.5, so the same material
## renders a 16.5 C wall and an 8 C roof with no second material and no second
## draw call. The physics does the shading.

const FLOOR_H: float = 3.4
const BLOCK: float = 46.0
const STREET: float = 16.0

@export var grid_n: int = 7
@export var seed_value: int = 11

var _snap_res := Vector2i(640, 360)
var buildings: Array[Dictionary] = []


## Ground-plane AABBs for the sim. The renderer wants boxes, the sim wants rects,
## and neither should know about the other's coordinate conventions.
func building_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for b in buildings:
		out.append(Rect2(b["x"], b["z"], b["w"], b["d"]))
	return out


func _add_box(pos: Vector3, size: Vector3, mat_name: String) -> void:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos + Vector3(0, size.y * 0.5, 0)   # BoxMesh is centred; we want a base
	mi.material_override = ThermalLib.get_material(mat_name, _snap_res)
	add_child(mi)


func generate(snap_res: Vector2i) -> void:
	_snap_res = snap_res
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var pitch: float = BLOCK + STREET

	# ground and streets. Roads sit 4 cm proud of the dirt so z-fighting cannot start.
	_add_ground(float(grid_n) * pitch)
	for i in grid_n + 1:
		var p: float = float(i) * pitch - STREET * 0.5
		_add_slab(Vector3(-STREET, 0.04, p), Vector3(grid_n * pitch + STREET * 2.0, 0.0, STREET), "road")
		_add_slab(Vector3(p, 0.04, -STREET), Vector3(STREET, 0.0, grid_n * pitch + STREET * 2.0), "road")

	for gx in grid_n:
		for gz in grid_n:
			var bx: float = float(gx) * pitch
			var bz: float = float(gz) * pitch
			var dc: float = Vector2(float(gx) - 2.2, float(gz) - 2.4).length()
			var zone: int = 2
			if dc < 1.6:
				zone = 0
			elif dc < 3.2:
				zone = 1
			var r0: float = rng.randf()
			var park_p: float = 0.20 if zone == 2 else 0.06
			var lot_p: float = 0.30 if zone == 2 else 0.10
			if r0 < park_p:
				_add_slab(Vector3(bx, 0.03, bz), Vector3(BLOCK, 0.0, BLOCK), "park")
				continue
			if r0 < lot_p:
				continue   # vacant lot
			var fl: int = 1 + rng.randi() % 2
			if zone == 0:
				fl = 4 + rng.randi() % 5
			elif zone == 1:
				fl = 2 + rng.randi() % 4
			var style: float = rng.randf()
			if style < 0.42:
				_building(rng, bx + rng.randf_range(1, 3), bz + rng.randf_range(1, 3),
						BLOCK - rng.randf_range(3, 7), BLOCK - rng.randf_range(3, 7), fl)
			elif style < 0.75:
				var g: float = rng.randf_range(4.0, 8.0)
				var w: float = BLOCK - 4.0 - g
				_building(rng, bx + 2, bz + 2, w * 0.55, BLOCK - 4.0, fl)
				_building(rng, bx + 2 + w * 0.55 + g, bz + 2, w * 0.45, BLOCK - 4.0, maxi(1, fl - 1))
			else:
				_building(rng, bx + 3, bz + 3, BLOCK * 0.55, BLOCK * 0.55, fl + 2)
				_building(rng, bx + 3, bz + 3 + BLOCK * 0.58, BLOCK * 0.62, BLOCK * 0.34, 1)


func _add_ground(extent: float) -> void:
	var mesh: PlaneMesh = PlaneMesh.new()
	mesh.size = Vector2(extent + 160.0, extent + 160.0)
	mesh.subdivide_width = 12       # not for shading. it keeps triangles small
	mesh.subdivide_depth = 12       # so affine depth error stays invisible.
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = Vector3(extent * 0.5, 0.0, extent * 0.5)
	mi.material_override = ThermalLib.get_material("ground", _snap_res)
	add_child(mi)


func _add_slab(corner: Vector3, size: Vector3, mat: String) -> void:
	var mesh: PlaneMesh = PlaneMesh.new()
	mesh.size = Vector2(size.x, size.z)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = corner + Vector3(size.x * 0.5, 0.0, size.z * 0.5)
	mi.material_override = ThermalLib.get_material(mat, _snap_res)
	add_child(mi)


func _building(rng: RandomNumberGenerator, x: float, z: float, w: float, d: float, fl: int) -> void:
	var h: float = float(fl) * FLOOR_H
	buildings.append({"x": x, "z": z, "w": w, "d": d, "fl": fl})
	_add_box(Vector3(x + w * 0.5, 0.0, z + d * 0.5), Vector3(w, h, d), "wall")

	# parapet: a thin cold lip around the roof
	var t: float = maxf(0.6, minf(w, d) * 0.03)
	_add_box(Vector3(x + w * 0.5, h, z + t * 0.5), Vector3(w, 0.9, t), "parapet")
	_add_box(Vector3(x + w * 0.5, h, z + d - t * 0.5), Vector3(w, 0.9, t), "parapet")
	_add_box(Vector3(x + t * 0.5, h, z + d * 0.5), Vector3(t, 0.9, d), "parapet")
	_add_box(Vector3(x + w - t * 0.5, h, z + d * 0.5), Vector3(t, 0.9, d), "parapet")

	# the only warm thing on a roof, and a real ISR tell
	if rng.randf() > 0.25:
		_add_box(Vector3(x + w * (0.25 + 0.4 * rng.randf()), h + 0.9, z + d * (0.25 + 0.4 * rng.randf())),
				Vector3(3.4, 1.5, 2.6), "hvac")
	if rng.randf() < 0.30:
		var tx: float = x + w * 0.70
		var tz: float = z + d * 0.72
		_add_box(Vector3(tx, h + 0.9, tz), Vector3(3.0, 1.2, 3.0), "parapet")
		_add_box(Vector3(tx, h + 2.1, tz), Vector3(2.2, 3.2, 2.2), "tank")
	if fl >= 4 and rng.randf() > 0.55:
		_add_box(Vector3(x + w * 0.5, h + 0.9, z + d * 0.5), Vector3(2.0, 2.6, 2.0), "wall")
