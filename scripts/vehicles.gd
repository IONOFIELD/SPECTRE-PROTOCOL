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

## Every car is FIT to the same footprint so a mixed fleet reads as one consistent
## size on the feed (spawn_fit stretches each GLB to this box; PSX proportions vary,
## the silhouette shouldn't). ~2 m wide, 4.6 m long -- a sedan.
const CAR_SIZE: Vector3 = Vector3(2.0, 1.5, 4.6)
const JAM_GAP: float = 5.4     # bumper-to-bumper spacing down a jammed lane, metres

var _snap_res: Vector2i = Vector2i(640, 360)
var rects: Array[Rect2] = []   # empty: light cars are not sim blockers


func generate(snap_res: Vector2i, city: CityGen, count: int, seed_value: int = 3) -> void:
	_snap_res = snap_res
	rects.clear()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var pitch: float = CityGen.BLOCK + CityGen.STREET
	# A few loose parked cars scattered on the streets...
	var n: int = mini(count, 10)
	for i in n:
		var vertical: bool = rng.randf() < 0.5
		var lane: float = float(rng.randi() % (city.grid_n + 1)) * pitch
		lane += (CityGen.HALF_ST - 1.9) * (1.0 if rng.randf() < 0.5 else -1.0)
		var along: float = rng.randf_range(4.0, float(city.grid_n) * pitch - 4.0)
		var at: Vector2 = Vector2(lane, along) if vertical else Vector2(along, lane)
		if not Geometry2D.is_point_in_polygon(at, city.land_poly):
			continue
		var yaw: float = (0.0 if vertical else PI * 0.5) + rng.randf_range(-0.08, 0.08)
		_car(at, yaw, "hood_hot" if i == 0 else "body_cold", rng)
	# ...and several ABANDONED TRAFFIC JAMS: cars backed up nose-to-tail down a lane,
	# all facing the same way -- the city froze mid-evacuation.
	for _j in 6:
		_traffic_jam(city, rng)
	_scatter_wrecks(city, rng)


## One car, fit to CAR_SIZE so the whole fleet is a single consistent size on FLIR.
func _car(pos: Vector2, yaw: float, mat: String, rng: RandomNumberGenerator) -> void:
	var path: String = FLEET[rng.randi() % FLEET.size()]
	var car: Node3D = ThermalModel.spawn_fit(path, mat, _snap_res, CAR_SIZE, yaw)
	if car == null:
		return
	car.position = Vector3(pos.x, 0.0, pos.y)
	add_child(car)


## A gridlocked lane: 5-12 cars bumper-to-bumper along one side of a street, all
## pointed the same way, mostly cold (abandoned) with the odd engine still warm. The
## jam is visual only (not a sim blocker) so the squad and horde still thread through.
func _traffic_jam(city: CityGen, rng: RandomNumberGenerator) -> void:
	var pitch: float = CityGen.BLOCK + CityGen.STREET
	var vertical: bool = rng.randf() < 0.5
	var lane: float = float(rng.randi() % (city.grid_n + 1)) * pitch
	var side: float = 1.0 if rng.randf() < 0.5 else -1.0
	lane += (CityGen.HALF_ST - 2.2) * side          # sit in one lane, not the centreline
	var facing: bool = rng.randf() < 0.5             # which way the queue points
	var count: int = 5 + rng.randi() % 8
	var span: float = float(city.grid_n) * pitch
	var start: float = rng.randf_range(6.0, maxf(7.0, span - 6.0 - float(count) * JAM_GAP))
	var yaw: float
	if vertical:
		yaw = 0.0 if facing else PI
	else:
		yaw = PI * 0.5 if facing else -PI * 0.5
	for k in count:
		var along: float = start + float(k) * JAM_GAP
		var at: Vector2 = Vector2(lane, along) if vertical else Vector2(along, lane)
		if not Geometry2D.is_point_in_polygon(at, city.land_poly):
			continue
		_car(at, yaw + rng.randf_range(-0.05, 0.05), "hood_hot" if rng.randf() < 0.12 else "body_cold", rng)


## Box-car wrecks piled up + some ablaze in the streets -- an environmental read and
## (as blockers in `rects`) obstacles the squad and horde must route around. Yaws stay
## near-axis: the PSX vertex-snap shader over-draws rotated meshes into a bright mass.
func _scatter_wrecks(city: CityGen, rng: RandomNumberGenerator) -> void:
	var pitch: float = CityGen.BLOCK + CityGen.STREET
	for _p in 26:                                    # more wrecks -- the city is in chaos
		var vertical: bool = rng.randf() < 0.5
		var lane: float = float(rng.randi() % (city.grid_n + 1)) * pitch + CityGen.HALF_ST
		var along: float = rng.randf_range(6.0, float(city.grid_n) * pitch - 6.0)
		var at: Vector2 = Vector2(lane, along) if vertical else Vector2(along, lane)
		if not Geometry2D.is_point_in_polygon(at, city.land_poly):
			continue
		var burning: bool = rng.randf() < 0.55         # over half ablaze -- fires all over the map
		var count: int = 1 + rng.randi() % 3         # a pile of 1-3
		for c in count:
			var off: Vector2 = Vector2(rng.randf_range(-2.5, 2.5), rng.randf_range(-2.5, 2.5))
			var yaw: float = (0.0 if vertical else PI * 0.5) + rng.randf_range(-0.15, 0.15)
			_box_car(at + off, yaw, "burning" if (burning and c == 0) else "body_cold", burning and c == 0)
		rects.append(Rect2(at.x - 4.0, at.y - 4.0, 8.0, 8.0))


func _box_car(pos: Vector2, yaw: float, mat: String, ablaze: bool) -> void:
	var m: BoxMesh = BoxMesh.new()
	m.size = Vector3(2.0, 1.4, 4.6)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = m
	mi.position = Vector3(pos.x, 0.7, pos.y)
	mi.rotation.y = yaw
	mi.material_override = ThermalLib.get_material(mat, _snap_res)
	add_child(mi)
	if ablaze:
		var fm: BoxMesh = BoxMesh.new()
		fm.size = Vector3(2.2, 3.0, 2.6)
		var fi: MeshInstance3D = MeshInstance3D.new()
		fi.mesh = fm
		fi.position = Vector3(pos.x, 2.3, pos.y)
		fi.material_override = ThermalLib.get_material("fire", _snap_res)
		add_child(fi)
