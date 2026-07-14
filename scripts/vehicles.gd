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
const LANE_OFF: float = 4.0    # how far off an arterial centreline a lane sits

var _snap_res: Vector2i = Vector2i(640, 360)
var rects: Array[Rect2] = []   # empty: light cars are not sim blockers


func generate(snap_res: Vector2i, city: CityGen, count: int, seed_value: int = 3) -> void:
	_snap_res = snap_res
	rects.clear()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	if city.road_lines.is_empty():
		return
	# A few loose parked cars scattered ALONG THE ARTERIALS...
	var n: int = mini(count, 12)
	for i in n:
		_car_on_road(city, rng, "hood_hot" if i == 0 else "body_cold")
	# ...and several ABANDONED TRAFFIC JAMS backed up nose-to-tail down an arterial -- the
	# city froze mid-evacuation on the main roads.
	for _j in 8:
		_traffic_jam(city, rng)
	_scatter_wrecks(city, rng)
	_bridge_jams(city, rng)     # the evac that never made it off -- cars choking the bridge decks


## A random arterial segment [a, b] from the city's road network, or [] if none.
func _random_seg(city: CityGen, rng: RandomNumberGenerator) -> Array:
	if city.road_lines.is_empty():
		return []
	return city.road_lines[rng.randi() % city.road_lines.size()]


## Yaw SNAPPED to the nearest cardinal along a road direction -- cars roughly follow the
## road but stay axis-aligned (a car rotated to a diagonal blows out on the PSX shader).
func _road_yaw(dir: Vector2) -> float:
	return 0.0 if absf(dir.x) < absf(dir.y) else PI * 0.5


## One car, fit to CAR_SIZE so the whole fleet is a single consistent size on FLIR.
func _car(pos: Vector2, yaw: float, mat: String, rng: RandomNumberGenerator) -> void:
	var path: String = FLEET[rng.randi() % FLEET.size()]
	var car: Node3D = ThermalModel.spawn_fit(path, mat, _snap_res, CAR_SIZE, yaw)
	if car == null:
		return
	car.position = Vector3(pos.x, 0.0, pos.y)
	add_child(car)


## One parked car sitting in a lane of a random arterial, roughly aligned to the road.
func _car_on_road(city: CityGen, rng: RandomNumberGenerator, mat: String) -> void:
	var seg: Array = _random_seg(city, rng)
	if seg.is_empty():
		return
	var a: Vector2 = seg[0]
	var b: Vector2 = seg[1]
	var dir: Vector2 = (b - a).normalized()
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var at: Vector2 = a.lerp(b, rng.randf()) + perp * (LANE_OFF * (1.0 if rng.randf() < 0.5 else -1.0))
	if not Geometry2D.is_point_in_polygon(at, city.land_poly):
		return
	_car(at, _road_yaw(dir), mat, rng)


## A gridlocked arterial: 4-11 cars bumper-to-bumper in one lane of a road, all pointed the
## same way, mostly cold (abandoned). Visual only (not a sim blocker) so units thread through.
func _traffic_jam(city: CityGen, rng: RandomNumberGenerator) -> void:
	var seg: Array = _random_seg(city, rng)
	if seg.is_empty():
		return
	var a: Vector2 = seg[0]
	var b: Vector2 = seg[1]
	var dir: Vector2 = (b - a).normalized()
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var seglen: float = a.distance_to(b)
	var lane: Vector2 = perp * (LANE_OFF * (1.0 if rng.randf() < 0.5 else -1.0))
	var yaw: float = _road_yaw(dir)
	var count: int = 4 + rng.randi() % 8
	var start: float = rng.randf_range(0.0, maxf(0.0, seglen - float(count) * JAM_GAP))
	for k in count:
		var d: float = start + float(k) * JAM_GAP
		if d > seglen:
			break
		var at: Vector2 = a + dir * d + lane
		if not Geometry2D.is_point_in_polygon(at, city.land_poly):
			continue
		_car(at, yaw, "hood_hot" if rng.randf() < 0.12 else "body_cold", rng)


## Abandoned cars backed up down the BRIDGE decks -- the evacuation that froze on the only ways off
## the peninsula. A few nose-to-tail clusters per deck in two lanes, mostly cold. Visual only (not
## sim blockers), so the squad + horde thread through. Cars sit on the deck (y=0, handled by _car).
func _bridge_jams(city: CityGen, rng: RandomNumberGenerator) -> void:
	for b in city.bridges:
		var ew: bool = b.size.x >= b.size.y                 # deck's long axis east-west?
		var length: float = b.size.x if ew else b.size.y
		var dir: Vector2 = Vector2(1.0, 0.0) if ew else Vector2(0.0, 1.0)
		var perp: Vector2 = Vector2(-dir.y, dir.x)
		var s0: Vector2 = b.get_center() - dir * (length * 0.5)   # centre of the near deck end
		var yaw: float = _road_yaw(dir)
		for _cluster in 5:                                  # backed-up clusters strung down the deck
			var lane: Vector2 = perp * (LANE_OFF * (1.0 if rng.randf() < 0.5 else -1.0))
			var cnt: int = 4 + rng.randi() % 5              # 4-8 cars nose-to-tail
			var smax: float = length - float(cnt) * JAM_GAP - 8.0
			var s: float = rng.randf_range(8.0, maxf(9.0, smax))
			for k in cnt:
				var at: Vector2 = s0 + dir * (s + float(k) * JAM_GAP) + lane
				_car(at, yaw, "hood_hot" if rng.randf() < 0.1 else "body_cold", rng)


## Box-car wrecks piled up + some ablaze in the streets -- an environmental read and
## (as blockers in `rects`) obstacles the squad and horde must route around. Yaws stay
## near-axis: the PSX vertex-snap shader over-draws rotated meshes into a bright mass.
func _scatter_wrecks(city: CityGen, rng: RandomNumberGenerator) -> void:
	for _p in 26:                                    # more wrecks -- the city is in chaos
		var seg: Array = _random_seg(city, rng)
		if seg.is_empty():
			continue
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		var dir: Vector2 = (b - a).normalized()
		var perp: Vector2 = Vector2(-dir.y, dir.x)
		var at: Vector2 = a.lerp(b, rng.randf()) + perp * rng.randf_range(-4.0, 4.0)
		if not Geometry2D.is_point_in_polygon(at, city.land_poly):
			continue
		var yaw: float = _road_yaw(dir)
		var burning: bool = rng.randf() < 0.55         # over half ablaze -- fires all over the map
		var count: int = 1 + rng.randi() % 3         # a pile of 1-3
		for c in count:
			var off: Vector2 = Vector2(rng.randf_range(-2.5, 2.5), rng.randf_range(-2.5, 2.5))
			_box_car(at + off, yaw, "burning" if (burning and c == 0) else "body_cold", burning and c == 0, rng)
		rects.append(Rect2(at.x - 4.0, at.y - 4.0, 8.0, 8.0))


func _box_car(pos: Vector2, yaw: float, mat: String, ablaze: bool, rng: RandomNumberGenerator) -> void:
	var m: BoxMesh = BoxMesh.new()
	m.size = Vector3(2.0, 1.4, 4.6)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = m
	mi.position = Vector3(pos.x, 0.7, pos.y)
	mi.rotation.y = yaw
	mi.material_override = ThermalLib.get_material(mat, _snap_res)
	add_child(mi)
	if ablaze:
		_wreck_fire(pos, rng)


## A wreck fire as a RAGGED CLUSTER of tumbled voxel embers -- NOT the old single smooth box, which
## bloomed into the round "ice cream scoop" the user kept flagging (these static wrecks are 55% of the
## scatter -- fires all over the map). The irregular tumbled silhouette + varied heights read as flame
## from the AC-130's altitude instead of a smooth ball; the fire material adds its own flick/writhe.
## Snap OFF so the tumbled boxes don't trip the vertex-snap bright bug.
func _wreck_fire(pos: Vector2, rng: RandomNumberGenerator) -> void:
	var mat: ShaderMaterial = ThermalLib.get_material("fire", _snap_res, 0)
	var n: int = 5 + rng.randi() % 2                     # 5-6 embers
	for _i in n:
		var ang: float = rng.randf() * TAU
		var rad: float = rng.randf_range(0.2, 2.3)       # irregular ground spread -> jagged footprint
		var s: float = rng.randf_range(0.8, 2.1)         # varied sizes -> ragged edge
		var bm: BoxMesh = BoxMesh.new()
		bm.size = Vector3(s, s * rng.randf_range(1.1, 1.9), s)
		var fi: MeshInstance3D = MeshInstance3D.new()
		fi.mesh = bm
		fi.transform = Transform3D(
			Basis.from_euler(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)),
			Vector3(pos.x + cos(ang) * rad, rng.randf_range(1.1, 3.0), pos.y + sin(ang) * rad))
		fi.material_override = mat
		fi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(fi)
