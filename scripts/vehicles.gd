class_name Vehicles
extends Node3D

## Parked traffic from LIGHT single-mesh PS1 cars only.
## Memory: one mesh + one material per car, PackedScene cached in ThermalModel.
## Skips multi-mesh / multi-atlas cars and greybox semis.
##
## Thermal: whole shell is body_cold; exactly one car uses hood_hot so the
## optic still gets a warm-engine tell without multi-part meshes.

## Prefer 1 mesh, 1 material, < ~0.25 MB GLBs.
const FLEET: Array = [
	"res://models/cars/toyota_corolla_-_ps1_low_poly.glb",
	"res://models/cars/honda_accord_-_ps1_low_poly.glb",
	"res://models/cars/mercedes-benz_s_500_-_ps1_low_poly.glb",
	"res://models/cars/suzuki_grand_vitara_-_ps1_low_poly.glb",
	"res://models/cars/transport_van_-_ps1_low_poly.glb",
	"res://models/cars/camper_ps1_spec.glb",
	"res://models/cars/covered_car.glb",
	"res://models/cars/lowpoly_mercedes.glb",
	"res://models/cars/psx_1967_shelby_gt500_lower_poly.glb",
	"res://models/cars/nissan_350z.glb",
	"res://models/cars/fiat_uno_1998.glb",
	"res://models/cars/luty_low_poly_ps1.glb",
]

## Uniform scale per asset (metres-ish length after scale). Eyeball-tuned.
const FLEET_SCALE: Array = [
	1.15, 1.15, 1.20, 1.15, 1.25, 1.10, 1.20, 1.15, 1.10, 1.15, 1.10, 1.00,
]

var _snap_res: Vector2i = Vector2i(640, 360)
var rects: Array[Rect2] = []   # empty: light cars are not sim blockers


func generate(snap_res: Vector2i, city: CityGen, count: int, seed_value: int = 3) -> void:
	_snap_res = snap_res
	rects.clear()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var pitch: float = CityGen.BLOCK + CityGen.STREET
	# Cap hard: 16 GLB cars is plenty for FLIR; more is just draw calls.
	var n: int = mini(count, 16)
	var running_i: int = 0   # first car is the warm-engine tell
	for i in n:
		var vertical: bool = rng.randf() < 0.5
		var lane: float = float(rng.randi() % (city.grid_n + 1)) * pitch
		lane += (CityGen.HALF_ST - 1.9) * (1.0 if rng.randf() < 0.5 else -1.0)
		var along: float = rng.randf_range(4.0, float(city.grid_n) * pitch - 4.0)
		var at: Vector2 = Vector2(lane, along) if vertical else Vector2(along, lane)
		var yaw: float = 0.0 if vertical else PI * 0.5
		yaw += rng.randf_range(-0.08, 0.08)
		var fi: int = rng.randi() % FLEET.size()
		var path: String = FLEET[fi]
		var sc: float = FLEET_SCALE[fi]
		var mat: String = "hood_hot" if i == running_i else "body_cold"
		var car: Node3D = ThermalModel.spawn(path, mat, _snap_res, sc, yaw, true)
		if car == null:
			continue
		car.position = Vector3(at.x, 0.0, at.y)
		add_child(car)
