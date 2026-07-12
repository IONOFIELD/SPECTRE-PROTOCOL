class_name CityGen
extends Node3D

## Ground is a TILING, not a stack of slabs.
##
## The old layout laid road strips over a ground plane at +40 mm, then laid the
## horizontal and vertical strips over each other at every intersection, exactly
## coplanar. At 250 m the depth buffer resolves 47 mm, so the +40 mm offset was
## already noise and the intersections were a straight tie. Hence the two flat
## squares clipping through each other.
##
## Now: every ground quad is disjoint in XZ and sits at exactly y = 0. Vertical
## road segments stop at the kerb of each horizontal strip. Nothing overlaps, so
## nothing can fight. The dirt surround sits 80 mm below and never coincides.
##
## Surfaces, coldest to warmest at night:
##   grass 12.0   sidewalk 17.5   ground 19.0   lot 20.0   road 21.0
## Vegetation is evaporative and reads dark. Asphalt held the afternoon and reads
## bright. Concrete sits between. That contrast is free navigation information.

const FLOOR_H: float = 3.4
const BLOCK: float = 46.0
const STREET: float = 16.0
const HALF_ST: float = 8.0
const SIDEWALK: float = 2.4
const SETBACK: float = 2.0     # building line, inside the sidewalk

# --- SF geography (metres). The land is the grid; water rings it on three sides
# (Pacific west, the strait north, the bay east) with two foot-bridges punched
# through -- the ONLY ways off the peninsula. Reach a bridge's far end to escape.
const STRAIT: float = 300.0    # depth of the Golden Gate strait the north bridge spans
const BAY: float = 300.0       # width of the bay the east bridge spans
const OCEAN: float = 200.0     # the Pacific shelf, west -- no crossing
const LANE: float = 64.0       # bridge deck width
const FAR: float = 40.0        # depth of a bridge's far-end escape zone
const GG_X: float = 90.0       # Golden Gate lane, off the west of the north edge
const BAY_Z: float = 360.0     # Bay Bridge lane, off the east edge

@export var grid_n: int = 13     # ~806 m across (13 x 62 m); ~120 s to cross at 6.6 m/s
@export var seed_value: int = 11

var _snap_res: Vector2i = Vector2i(640, 360)
var buildings: Array[Dictionary] = []
var _surfaces: Dictionary = {}   # material -> Array[Rect2], all disjoint, all y = 0

# geography, filled by generate() and read by main + the sim
var land_poly: PackedVector2Array = PackedVector2Array()   # the SF coastline (irregular)
var water: Array[Rect2] = []     # (unused with a polygon; the ocean plane is the sea now)
var bridges: Array[Rect2] = []   # walkable decks, movement-slowed
var escapes: Array[Rect2] = []   # bridge far ends: step inside to get off the map
var parks: Array[Rect2] = []     # Golden Gate Park, the Presidio, the Panhandle
var land: Rect2 = Rect2()        # polygon bounding box, for ambient population scatter
var poly_lo: Vector2 = Vector2.ZERO
var poly_hi: Vector2 = Vector2.ZERO
var map_lo: Vector2 = Vector2.ZERO
var map_hi: Vector2 = Vector2.ZERO

# SoMa's rotated grid. South of Market, SF's streets swing ~40 deg off the avenue
# grid to run parallel to Market St; the Financial District (north of Market) keeps
# the orthogonal grid. We hole SoMa out of the main grid and lay a second grid
# aligned to Market instead. Frame set in generate() from the Market endpoints.
const SOMA_NEAR: float = 15.0     # start this far SE of Market's avenue centreline
const SOMA_FAR: float = 250.0     # depth of the rotated wedge toward the bay
const SOMA_S0: float = -70.0      # NE extent along Market (past the Embarcadero end)
const SOMA_S1: float = 360.0      # SW extent along Market (down to Mission Bay)
const SOMA_Y: float = 0.02        # rotated quads ride a hair above the main grid (no z-fight)
var _mkt_a: Vector2 = Vector2.ZERO   # Market NE end (frame origin)
var _mkt_u: Vector2 = Vector2.ZERO   # unit along Market, toward the SW
var _mkt_v: Vector2 = Vector2.ZERO   # unit perpendicular, toward the bay (into SoMa)
var _rquads: Dictionary = {}         # material -> Array of [Vector2 x4], rotated ground quads


func building_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for b in buildings:
		out.append(Rect2(b["x"], b["z"], b["w"], b["d"]))
	return out


func _tile(r: Rect2, mat: String) -> void:
	if r.size.x <= 0.01 or r.size.y <= 0.01:
		return
	if not _surfaces.has(mat):
		_surfaces[mat] = []
	_surfaces[mat].append(r)


func _emit_surfaces() -> void:
	var mats: Dictionary = {}
	for mat in _surfaces:
		mats[mat] = true
	for mat in _rquads:
		mats[mat] = true
	for mat in mats:
		var st: SurfaceTool = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_normal(Vector3.UP)
		for r in _surfaces.get(mat, []):
			var a: Vector3 = Vector3(r.position.x, 0.0, r.position.y)
			var b: Vector3 = Vector3(r.end.x, 0.0, r.position.y)
			var c: Vector3 = Vector3(r.end.x, 0.0, r.end.y)
			var d: Vector3 = Vector3(r.position.x, 0.0, r.end.y)
			for v in [a, c, b, a, d, c]:      # CCW seen from above
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
		for q in _rquads.get(mat, []):
			# rotated ground quad (SoMa): 4 corners CCW, both windings so the optic
			# never culls it, riding SOMA_Y above the main grid.
			var p0: Vector3 = Vector3(q[0].x, SOMA_Y, q[0].y)
			var p1: Vector3 = Vector3(q[1].x, SOMA_Y, q[1].y)
			var p2: Vector3 = Vector3(q[2].x, SOMA_Y, q[2].y)
			var p3: Vector3 = Vector3(q[3].x, SOMA_Y, q[3].y)
			for v in [p0, p2, p1, p0, p3, p2, p0, p1, p2, p0, p2, p3]:
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = ThermalLib.get_material(mat, _snap_res)
		add_child(mi)


func _add_box(pos: Vector3, size: Vector3, mat_name: String) -> void:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos + Vector3(0.0, size.y * 0.5, 0.0)
	mi.material_override = ThermalLib.get_material(mat_name, _snap_res)
	add_child(mi)


func generate(snap_res: Vector2i) -> void:
	_snap_res = snap_res
	buildings.clear()
	_surfaces.clear()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value

	land_poly = _sf_polygon()
	_lay_geography()

	# The ocean: a cold thermal plane under and around the peninsula, extended far
	# past the bounds so a bounded camera never sees the void; 1.5 m below the land
	# so the coast reads as a clean step down to the water.
	var sea: PlaneMesh = PlaneMesh.new()
	sea.size = Vector2(map_hi.x - map_lo.x + 4000.0, map_hi.y - map_lo.y + 4000.0)
	sea.subdivide_width = 16
	sea.subdivide_depth = 16
	var smi: MeshInstance3D = MeshInstance3D.new()
	smi.mesh = sea
	smi.position = Vector3((map_lo.x + map_hi.x) * 0.5, -1.5, (map_lo.y + map_hi.y) * 0.5)
	smi.material_override = ThermalLib.get_material("water", _snap_res)
	add_child(smi)

	# --- bridge decks over the water
	for b in bridges:
		_tile(b, "road")
	_bridge_towers(bridges[0], true)     # Golden Gate runs north -- towers span x
	_bridge_towers(bridges[1], false)    # Bay Bridge runs east -- towers span z

	# --- the street grid, laid ONLY where a block centre falls on land, so the city
	# takes the shape of the coastline. Interior streets connect land to land;
	# coastal blocks have no seaward street. Downtown leans toward the bay.
	var pitch: float = BLOCK + STREET
	var nx: int = int(ceil((poly_hi.x - poly_lo.x) / pitch)) + 1
	var nz: int = int(ceil((poly_hi.y - poly_lo.y) / pitch)) + 1
	var downtown: Vector2 = Vector2(880.0, 430.0)     # Financial District, by the Bay Bridge
	# Market Street: SF's signature diagonal, cutting the grid from the Embarcadero
	# (NE) down to Twin Peaks (SW). Blocks on the line are cleared for the avenue.
	var mkt_a: Vector2 = Vector2(915.0, 375.0)
	var mkt_b: Vector2 = Vector2(435.0, 765.0)
	var mkt_half: float = 11.0
	# Market frame for the SoMa grid: u runs SW down Market, v runs SE toward the bay.
	_mkt_a = mkt_a
	_mkt_u = (mkt_b - mkt_a).normalized()
	_mkt_v = Vector2(-_mkt_u.y, _mkt_u.x)
	if _mkt_v.dot(Vector2(1.0, 1.0)) < 0.0:
		_mkt_v = -_mkt_v          # face the bay (SE), not inland
	for gx in nx:
		for gz in nz:
			var bx: float = poly_lo.x + float(gx) * pitch + HALF_ST
			var bz: float = poly_lo.y + float(gz) * pitch + HALF_ST
			var c: Vector2 = Vector2(bx + BLOCK * 0.5, bz + BLOCK * 0.5)
			if not _in_land(c):
				continue
			if _in_soma(c):
				continue          # SoMa is laid on the rotated Market grid instead
			var east_land: bool = _in_land(c + Vector2(pitch, 0.0))
			var south_land: bool = _in_land(c + Vector2(0.0, pitch))
			if east_land:
				_tile(Rect2(bx + BLOCK, bz, STREET, BLOCK), "road")
			if south_land:
				_tile(Rect2(bx, bz + BLOCK, BLOCK, STREET), "road")
			if east_land and south_land:
				_tile(Rect2(bx + BLOCK, bz + BLOCK, STREET, STREET), "road")
			if _in_park(c):
				_tile(Rect2(bx, bz, BLOCK, BLOCK), "park")
				continue
			if _dist_to_seg(c, mkt_a, mkt_b) < mkt_half + BLOCK * 0.12:
				continue     # Market St avenue -- no building on the line
			_block(rng, bx, bz, c.distance_to(downtown) / pitch)

	_lay_soma(rng)                               # rotated Market grid in the SoMa hole
	_emit_surfaces()
	_diag_road(mkt_a, mkt_b, mkt_half * 2.0)     # the avenue deck, over the cleared blocks


## Perpendicular distance from p to segment a-b.
func _dist_to_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / maxf(1e-4, ab.length_squared()), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## A rotated road quad from a to b (width w), for the diagonal avenue. Emitted
## double-sided so winding never culls it from the top-down optic.
func _diag_road(a: Vector2, b: Vector2, w: float) -> void:
	var perp: Vector2 = (b - a).orthogonal().normalized() * (w * 0.5)
	var y: float = 0.03
	var c0: Vector3 = Vector3(a.x + perp.x, y, a.y + perp.y)
	var c1: Vector3 = Vector3(b.x + perp.x, y, b.y + perp.y)
	var c2: Vector3 = Vector3(b.x - perp.x, y, b.y - perp.y)
	var c3: Vector3 = Vector3(a.x - perp.x, y, a.y - perp.y)
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [c0, c1, c2, c0, c2, c3, c0, c2, c1, c0, c3, c2]:   # both windings
		st.set_normal(Vector3.UP)
		st.add_vertex(v)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = ThermalLib.get_material("road", _snap_res)
	add_child(mi)


## Is p inside the SoMa wedge? SE of Market (v>0), a band toward the bay over the
## NE reach of the Market line. Holed out of the main grid; filled by _lay_soma.
func _in_soma(p: Vector2) -> bool:
	var rel: Vector2 = p - _mkt_a
	var s: float = rel.dot(_mkt_u)
	var t: float = rel.dot(_mkt_v)
	return t > SOMA_NEAR and t < SOMA_FAR and s > SOMA_S0 and s < SOMA_S1


## Collect a rotated ground quad (4 corners CCW) for a material; emitted in _emit_surfaces.
func _rtile(c0: Vector2, c1: Vector2, c2: Vector2, c3: Vector2, mat: String) -> void:
	if not _rquads.has(mat):
		_rquads[mat] = []
	_rquads[mat].append([c0, c1, c2, c3])


## A rectangle in the Market frame: centre, half-widths along u (Market) and v (bay).
func _rrect(centre: Vector2, hu: float, hv: float, mat: String) -> void:
	var u: Vector2 = _mkt_u
	var v: Vector2 = _mkt_v
	_rtile(centre - u * hu - v * hv, centre + u * hu - v * hv,
		centre + u * hu + v * hv, centre - u * hu + v * hv, mat)


## Fill the SoMa hole with a grid aligned to Market: for every cell that lands in the
## wedge, lay the two streets on its bay/SW edges, the lot, and a rotated mid-rise.
func _lay_soma(rng: RandomNumberGenerator) -> void:
	var pitch: float = BLOCK + STREET
	var yaw: float = atan2(_mkt_u.x, _mkt_u.y)      # heading of u, the sim's convention
	var i0: int = int(floor(SOMA_S0 / pitch)) - 1
	var i1: int = int(ceil(SOMA_S1 / pitch)) + 1
	var jn: int = int(ceil((SOMA_FAR - SOMA_NEAR) / pitch)) + 1
	for i in range(i0, i1):
		for j in range(jn):
			var s: float = float(i) * pitch + BLOCK * 0.5
			var t: float = SOMA_NEAR + float(j) * pitch + BLOCK * 0.5
			var c: Vector2 = _mkt_a + _mkt_u * s + _mkt_v * t
			if not _in_land(c) or _in_park(c) or not _in_soma(c):
				continue
			_soma_cell(rng, c, yaw)


func _soma_cell(rng: RandomNumberGenerator, c: Vector2, yaw: float) -> void:
	var pitch: float = BLOCK + STREET
	# the SE/SW streets + their intersection (each shared gap laid once), then the lot
	_rrect(c + _mkt_u * (pitch * 0.5), STREET * 0.5, pitch * 0.5, "road")
	_rrect(c + _mkt_v * (pitch * 0.5), pitch * 0.5, STREET * 0.5, "road")
	_rrect(c, BLOCK * 0.5, BLOCK * 0.5, "lot")

	if rng.randf() < 0.15:
		return                          # surface parking -- SoMa is full of it; breaks the lattice

	# dense mid-rise, taller toward the Financial District (near the NE end of Market)
	var near: float = c.distance_to(_mkt_a)
	var fl: int = 3 + rng.randi() % 4
	if near < 150.0:
		fl = 6 + rng.randi() % 6
	elif near < 300.0:
		fl = 4 + rng.randi() % 4
	var span: float = BLOCK - 2.0 * SIDEWALK - 2.0 * SETBACK
	var bw: float = span * rng.randf_range(0.72, 0.96)
	var bd: float = span * rng.randf_range(0.72, 0.96)
	_soma_building(rng, c, yaw, bw, bd, fl)


## A rotated shell centred on the cell. The sim gets a conservative inscribed AABB so
## the building's diagonal corners never clog SoMa's narrow streets for nav/LOS.
func _soma_building(rng: RandomNumberGenerator, c: Vector2, yaw: float, bw: float, bd: float, fl: int) -> void:
	var h: float = float(fl) * FLOOR_H
	var wall_mat: String = "brick" if rng.randf() < 0.35 else "wall"
	var path: String = LIGHT_BUILDINGS[rng.randi() % LIGHT_BUILDINGS.size()]
	var shell: Node3D = ThermalModel.spawn_fit(path, wall_mat, _snap_res, Vector3(bw, h, bd), yaw)
	if shell != null:
		shell.position = Vector3(c.x, 0.0, c.y)
		add_child(shell)
	else:
		_add_box(Vector3(c.x, 0.0, c.y), Vector3(bw, h, bd), wall_mat)
	var core: float = minf(bw, bd) * 0.82
	buildings.append({"x": c.x - core * 0.5, "z": c.y - core * 0.5, "w": core, "d": core, "fl": fl})


## The San Francisco coastline, ~1,150 m across, clockwise from the Lands End tip.
## Chunky at block resolution but unmistakably the peninsula: the north waterfront
## and Financial District jut into the bay (NE), Hunters Point points east (SE),
## and Ocean Beach is the straight Pacific edge (W).
func _sf_polygon() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(205, 185),   # NW -- Lands End / Presidio tip
		Vector2(360, 130),   # N  -- Presidio to Marina
		Vector2(560, 150),   # N  -- Marina waterfront
		Vector2(720, 140),   # N  -- Fort Mason
		Vector2(850, 205),   # NE -- Fisherman's Wharf
		Vector2(930, 320),   # NE -- Financial District jut
		Vector2(965, 470),   # E  -- Embarcadero (Bay Bridge)
		Vector2(935, 610),   # E  -- SoMa / South Beach
		Vector2(958, 760),   # E  -- Mission Bay
		Vector2(905, 875),   # SE -- Dogpatch
		Vector2(1005, 950),  # SE -- Hunters Point / India Basin point
		Vector2(865, 1015),  # SE -- Bayview
		Vector2(700, 1085),  # S  -- southern border
		Vector2(500, 1105),  # S  -- Visitacion Valley
		Vector2(330, 1070),  # S  -- Lake Merced approach
		Vector2(210, 990),   # SW -- Lake Merced
		Vector2(150, 830),   # W  -- Sunset / Ocean Beach south
		Vector2(130, 640),   # W  -- Ocean Beach mid
		Vector2(142, 450),   # W  -- Richmond / Ocean Beach north
		Vector2(165, 300),   # NW -- Lands End approach
	])


## Bridges (Golden Gate off the north tip, Bay Bridge off the east), their escape
## zones, the named parks, and map bounds -- all derived from the polygon bbox.
func _lay_geography() -> void:
	water = []
	poly_lo = land_poly[0]
	poly_hi = land_poly[0]
	for v in land_poly:
		poly_lo = poly_lo.min(v)
		poly_hi = poly_hi.max(v)
	land = Rect2(poly_lo, poly_hi - poly_lo)

	parks = [
		Rect2(175, 600, 380, 95),    # Golden Gate Park -- long E-W green, west-centre
		Rect2(205, 210, 165, 130),   # the Presidio -- NW
		Rect2(555, 628, 120, 40),    # the Panhandle -- E of GG Park
	]
	bridges = [
		Rect2(235, -120, 66, 300),   # Golden Gate, north (meets the N coast ~z 150)
		Rect2(950, 435, 340, 72),    # Bay Bridge, east (meets the E coast ~x 940)
	]
	escapes = [
		Rect2(235, -120, 66, 46),    # Marin end (far north)
		Rect2(1246, 435, 44, 72),    # Oakland end (far east)
	]

	map_lo = poly_lo
	map_hi = poly_hi
	for b in bridges:
		map_lo = map_lo.min(b.position)
		map_hi = map_hi.max(b.end)
	for e in escapes:
		map_lo = map_lo.min(e.position)
		map_hi = map_hi.max(e.end)
	map_lo -= Vector2(240, 170)
	map_hi += Vector2(240, 170)


func _in_land(p: Vector2) -> bool:
	return Geometry2D.is_point_in_polygon(p, land_poly)


func _in_park(p: Vector2) -> bool:
	for pk in parks:
		if pk.has_point(p):
			return true
	return false


## Two cold steel towers on a bridge deck -- the thermal landmark that reads "bridge".
func _bridge_towers(deck: Rect2, north_running: bool) -> void:
	var h: float = 42.0
	for f in [0.34, 0.66]:
		if north_running:
			var zc: float = deck.position.y + deck.size.y * f
			_add_box(Vector3(deck.position.x + 1.6, 0.0, zc), Vector3(3.2, h, 3.2), "parapet")
			_add_box(Vector3(deck.end.x - 1.6, 0.0, zc), Vector3(3.2, h, 3.2), "parapet")
		else:
			var xc: float = deck.position.x + deck.size.x * f
			_add_box(Vector3(xc, 0.0, deck.position.y + 1.6), Vector3(3.2, h, 3.2), "parapet")
			_add_box(Vector3(xc, 0.0, deck.end.y - 1.6), Vector3(3.2, h, 3.2), "parapet")


func _block(rng: RandomNumberGenerator, bx: float, bz: float, dc: float) -> void:
	# sidewalk ring, four disjoint rects
	var s: float = SIDEWALK
	_tile(Rect2(bx, bz, BLOCK, s), "sidewalk")
	_tile(Rect2(bx, bz + BLOCK - s, BLOCK, s), "sidewalk")
	_tile(Rect2(bx, bz + s, s, BLOCK - 2.0 * s), "sidewalk")
	_tile(Rect2(bx + BLOCK - s, bz + s, s, BLOCK - 2.0 * s), "sidewalk")

	var ix: float = bx + s
	var iz: float = bz + s
	var iw: float = BLOCK - 2.0 * s

	var zone: int = 2
	if dc < 1.6:
		zone = 0
	elif dc < 3.2:
		zone = 1

	var r0: float = rng.randf()
	var park_p: float = 0.22 if zone == 2 else 0.07
	var lot_p: float = 0.16 if zone == 2 else 0.10

	if r0 < park_p:
		# a path bisects the green. Subtract it; do not lay it on top.
		var ph: float = 1.8
		var py: float = iz + iw * 0.5 - ph * 0.5
		_tile(Rect2(ix, iz, iw, py - iz), "grass")
		_tile(Rect2(ix, py, iw, ph), "sidewalk")
		_tile(Rect2(ix, py + ph, iw, iz + iw - py - ph), "grass")
		return
	if r0 < park_p + lot_p:
		_tile(Rect2(ix, iz, iw, iw), "lot")     # surface parking, no building
		return

	# built parcel. If there is a green strip, the lot is what is left of the
	# parcel, not the whole parcel with grass laid over it.
	var green: float = 4.0 if rng.randf() < 0.35 else 0.0
	if green > 0.0:
		_tile(Rect2(ix, iz, iw, green), "grass")
	_tile(Rect2(ix, iz + green, iw, iw - green), "lot")

	var px: float = ix + SETBACK
	var pz: float = iz + green + SETBACK
	var pw: float = iw - 2.0 * SETBACK

	var fl: int = 1 + rng.randi() % 2
	if zone == 0:
		fl = 4 + rng.randi() % 5
	elif zone == 1:
		fl = 2 + rng.randi() % 4

	var style: float = rng.randf()
	var pd: float = iw - green - 2.0 * SETBACK
	if style < 0.42:
		_building(rng, px, pz, pw, pd * rng.randf_range(0.7, 1.0), fl)
	elif style < 0.75:
		var g: float = rng.randf_range(3.0, 6.0)
		var w: float = pw - g
		_building(rng, px, pz, w * 0.55, pd, fl)
		_building(rng, px + w * 0.55 + g, pz, w * 0.45, pd, maxi(1, fl - 1))
	else:
		_building(rng, px, pz, pw * 0.55, pd * 0.55, fl + 2)
		_building(rng, px, pz + pd * 0.60, pw * 0.62, pd * 0.34, 1)


## Single-mesh / low-mat PSX shells only. NEVER the mega-packs (tacos, laundry,
## buildings.glb, forest, industrial, downtown) — those are hundreds of meshes.
const LIGHT_BUILDINGS: Array = [
	"res://models/buildings and scenery/psx_russian_soviet_housing_3d_model.glb",
	"res://models/buildings and scenery/low-poly_building.glb",
	"res://models/buildings and scenery/psx_old_house.glb",
	"res://models/buildings and scenery/psx_old_abandoned_mansion.glb",
	"res://models/buildings and scenery/psxprop_-_old_warehouse.glb",
	"res://models/buildings and scenery/psx_prop_-_old_garage.glb",
	"res://models/buildings and scenery/building_-_square_-_illuminated.glb",
	"res://models/buildings and scenery/building_-_quarter_arc.glb",
	"res://models/buildings and scenery/building_-_stretched_octagonal_-_tier.glb",
	"res://models/buildings and scenery/psx_japanese_warehouse.glb",
	"res://models/buildings and scenery/ps1_style_workshop.glb",
]


func _building(rng: RandomNumberGenerator, x: float, z: float, w: float, d: float, fl: int) -> void:
	var h: float = float(fl) * FLOOR_H
	# 35% brick structure map vs cast concrete — same temperature class.
	var wall_mat: String = "brick" if rng.randf() < 0.35 else "wall"
	buildings.append({"x": x, "z": z, "w": w, "d": d, "fl": fl})

	# Prefer one stretched PSX shell (1–2 meshes) over 5+ greybox draw calls.
	var path: String = LIGHT_BUILDINGS[rng.randi() % LIGHT_BUILDINGS.size()]
	# 0° / 90° only — keeps stretched footprints aligned to the parcel axes.
	var yaw: float = PI * 0.5 if rng.randf() < 0.5 else 0.0
	var shell: Node3D = ThermalModel.spawn_fit(path, wall_mat, _snap_res, Vector3(w, h, d), yaw)
	if shell != null:
		shell.position = Vector3(x + w * 0.5, 0.0, z + d * 0.5)
		add_child(shell)
	else:
		# Fallback if a GLB fails to load
		_add_box(Vector3(x + w * 0.5, 0.0, z + d * 0.5), Vector3(w, h, d), wall_mat)
		var t: float = maxf(0.6, minf(w, d) * 0.03)
		_add_box(Vector3(x + w * 0.5, h, z + t * 0.5), Vector3(w, 0.9, t), "parapet")
		_add_box(Vector3(x + w * 0.5, h, z + d - t * 0.5), Vector3(w, 0.9, t), "parapet")
		_add_box(Vector3(x + t * 0.5, h, z + d * 0.5), Vector3(t, 0.9, d), "parapet")
		_add_box(Vector3(x + w - t * 0.5, h, z + d * 0.5), Vector3(t, 0.9, d), "parapet")

	# Roof HVAC / tanks: main._scatter_roof_props (small GLBs), not greyboxes.
