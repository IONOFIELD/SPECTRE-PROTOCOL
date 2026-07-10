class_name Vehicles
extends Node3D

## Parked traffic. A car is five boxes. What makes it read as a car rather than
## a crate is entirely thermal: the hood is hot, the glass is cold, the tyres
## are warm from friction, and the panel gaps run cold. Nothing here is texture.

const KINDS: Array = ["sedan", "suv", "semi"]
var _snap_res: Vector2i = Vector2i(640, 360)
var rects: Array[Rect2] = []       # only semis block; the sim decides


func _box(pos: Vector3, size: Vector3, mat: String, parent: Node3D) -> void:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos + Vector3(0.0, size.y * 0.5, 0.0)
	mi.material_override = ThermalLib.get_material(mat, _snap_res)
	parent.add_child(mi)


func _car(kind: String, at: Vector2, yaw: float, running: bool) -> void:
	var n: Node3D = Node3D.new()
	n.position = Vector3(at.x, 0.0, at.y)
	n.rotation.y = yaw
	add_child(n)
	var hood: String = "hood_hot" if running else "hood_warm"
	var wheel_z: float = 1.5
	var wheel_x: float = 0.85
	if kind == "sedan":
		_box(Vector3(0, 0.24, 0), Vector3(1.80, 0.58, 4.40), "body_cold", n)
		_box(Vector3(0, 0.80, -0.30), Vector3(1.66, 0.48, 2.10), "glass_veh", n)
		_box(Vector3(0, 0.80, 1.70), Vector3(1.70, 0.08, 1.20), hood, n)
		_box(Vector3(-0.40, 0.14, -2.15), Vector3(0.14, 0.14, 0.28), "exhaust", n)
	elif kind == "suv":
		_box(Vector3(0, 0.28, 0), Vector3(1.95, 0.72, 4.70), "body_cold", n)
		_box(Vector3(0, 1.00, -0.35), Vector3(1.80, 0.62, 2.60), "glass_veh", n)
		_box(Vector3(0, 0.98, 1.75), Vector3(1.85, 0.10, 1.10), hood, n)
		_box(Vector3(-0.45, 0.16, -2.30), Vector3(0.16, 0.16, 0.30), "exhaust", n)
	else:
		_box(Vector3(0, 0.55, -2.60), Vector3(2.50, 2.60, 8.40), "body_cold", n)
		_box(Vector3(0, 0.40, 2.60), Vector3(2.40, 1.90, 2.60), "body_cold", n)
		_box(Vector3(0, 0.36, 3.40), Vector3(2.30, 0.10, 1.00), hood, n)
		wheel_z = 3.2
		wheel_x = 1.10
		rects.append(Rect2(at.x - 1.6, at.y - 5.6, 3.2, 11.2))
	var wz: float = 0.55 if kind == "semi" else 0.34
	for sx in [wheel_x, -wheel_x]:
		for sz in [wheel_z, -wheel_z]:
			_box(Vector3(sx, 0.0, sz), Vector3(0.26, wz * 1.1, 0.62), "tyre", n)


func generate(snap_res: Vector2i, city: CityGen, count: int, seed_value: int = 3) -> void:
	_snap_res = snap_res
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var pitch: float = CityGen.BLOCK + CityGen.STREET
	for i in count:
		# park along a street kerb, facing down the street
		var vertical: bool = rng.randf() < 0.5
		# the kerb is at centre +/- HALF_ST; park 1.9 m off it, either side
		var lane: float = float(rng.randi() % (city.grid_n + 1)) * pitch
		lane += (CityGen.HALF_ST - 1.9) * (1.0 if rng.randf() < 0.5 else -1.0)
		var along: float = rng.randf_range(4.0, float(city.grid_n) * pitch - 4.0)
		var at: Vector2 = Vector2(lane, along) if vertical else Vector2(along, lane)
		var yaw: float = 0.0 if vertical else PI * 0.5
		var r: float = rng.randf()
		var kind: String = "sedan" if r < 0.55 else ("suv" if r < 0.85 else "semi")
		_car(kind, at, yaw, i == 0)   # exactly one engine still running
