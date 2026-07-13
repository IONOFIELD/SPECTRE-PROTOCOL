class_name CityGen
extends Node3D

## San Francisco, from the poster. The map is now built around the REAL city:
##   - the coastline silhouette (Ocean Beach straight W, the Financial District jutting
##     NE into the bay, Hunters Point SE, Lake Merced notch SW),
##   - the MAJOR ARTERIALS as the road network (Market, Van Ness, Geary, 19th Ave,
##     Fulton, Lincoln, the Embarcadero, 3rd St, Columbus, Cesar Chavez, ...),
##   - buildings packed into the blocks BETWEEN those arterials, aligned to them,
##   - the parks retained (Golden Gate Park, the Presidio, the Panhandle, Twin Peaks, ...).
##
## The layout is CELL-BASED: a fine grid over the land, each cell is either a park tile, a
## road-corridor tile (near an arterial), or a building block (ground tile + a shell). All
## cells are disjoint, all at y = 0, so nothing z-fights -- and, critically, NOTHING is a
## rotated flat quad (the PSX vertex-snap shader blows rotated geometry out to a bright
## rectangle). The diagonal avenues read from the cell corridor + the 2D overlay line main
## draws over the feed (road_lines).

const FLOOR_H: float = 3.4
const CELL: float = 44.0        # block cell -- one building each; ~6-10 m gaps read as the fine grid
const ROAD_HALF: float = 21.0   # a cell whose centre is within this of an arterial becomes road
const BEACH_W: float = 24.0     # how far the sand reaches inland from the coastline
const BEACH_SEA: float = 10.0   # ...and how far it laps out over the water

@export var grid_n: int = 13     # (kept for compat; the layout is arterial-driven now)
@export var seed_value: int = 11

var _snap_res: Vector2i = Vector2i(640, 360)
var buildings: Array[Dictionary] = []
var _surfaces: Dictionary = {}   # material -> Array[Rect2], all disjoint, all y = 0

# geography, filled by generate() and read by main + the sim
var land_poly: PackedVector2Array = PackedVector2Array()   # the SF coastline (irregular)
var water: Array[Rect2] = []     # (unused with a polygon; the ocean plane is the sea now)
var bridges: Array[Rect2] = []   # walkable decks, movement-slowed -- the only ways off the peninsula
var escapes: Array[Rect2] = []   # bridge far ends: step inside to get off the map
var parks: Array[Rect2] = []     # Golden Gate Park, the Presidio, the Panhandle, Twin Peaks, ...
var arterials: Array = []        # the major roads, each a PackedVector2Array polyline -- cars ride these
var road_lines: Array = []       # arterial centrelines [a, b] for the map overlay (main draws them)
var land: Rect2 = Rect2()        # polygon bounding box, for ambient population scatter
var poly_lo: Vector2 = Vector2.ZERO
var poly_hi: Vector2 = Vector2.ZERO
var map_lo: Vector2 = Vector2.ZERO
var map_hi: Vector2 = Vector2.ZERO


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
	for mat in _surfaces:
		var st: SurfaceTool = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for r in _surfaces[mat]:
			var a: Vector3 = Vector3(r.position.x, 0.0, r.position.y)
			var b: Vector3 = Vector3(r.end.x, 0.0, r.position.y)
			var c: Vector3 = Vector3(r.end.x, 0.0, r.end.y)
			var d: Vector3 = Vector3(r.position.x, 0.0, r.end.y)
			# Emit BOTH windings: the thermal shader is cull_back, and these ground quads were wound
			# the wrong way (facing down) so they were culled -> invisible. One set now always faces
			# up and renders; the other is the harmless back side.
			for v in [a, c, b, a, d, c, a, b, c, a, c, d]:
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(v.x, v.z) * 0.02)   # any UV -- the shader is triplanar, but the
				st.add_vertex(v)                      # vertex FORMAT needs UVs for tangents below
		# Godot's compressed vertex format packs normal+tangent together; a mesh with normals
		# but NO tangents breaks custom spatial shaders (renders invisible). Generate them.
		st.generate_tangents()
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
	road_lines.clear()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value

	land_poly = _sf_polygon()
	arterials = _arterials()
	_lay_geography()

	# The ocean: a cold thermal plane under and around the peninsula, extended far past the
	# bounds so a bounded camera never sees the void; 1.5 m below the land so the coast reads
	# as a clean step down to the water.
	if OS.get_environment("SPECTRE_NOSEA") == "":   # TEMP diag guard
		var sea: PlaneMesh = PlaneMesh.new()
		sea.size = Vector2(map_hi.x - map_lo.x + 4000.0, map_hi.y - map_lo.y + 4000.0)
		sea.subdivide_width = 16
		sea.subdivide_depth = 16
		var smi: MeshInstance3D = MeshInstance3D.new()
		smi.mesh = sea
		smi.position = Vector3((map_lo.x + map_hi.x) * 0.5, -1.5, (map_lo.y + map_hi.y) * 0.5)
		smi.material_override = ThermalLib.get_material("water", _snap_res)
		add_child(smi)

	_lay_beach()

	# bridge decks over the water (a mid-tone between water and land, so they read)
	for b in bridges:
		_tile(b, "bridge")
	_bridge_towers(bridges[0], true)     # Golden Gate runs north -- towers span x
	_bridge_towers(bridges[1], false)    # Bay Bridge runs east -- towers span z

	# the arterials, as overlay centrelines (main draws these as the "black line" roads)
	for art in arterials:
		for i in art.size() - 1:
			road_lines.append([art[i], art[i + 1]])

	_lay_city(rng)          # cell grid: parks / road corridors / building blocks
	_scatter_trees(rng)     # trees + shrubs -- a real, vegetated environment
	_emit_surfaces()


## The cell grid over the land. Each cell is a park tile, a road-corridor tile (near an
## arterial), or a building block (ground base + a shell). Disjoint, axis-aligned, y = 0.
func _lay_city(rng: RandomNumberGenerator) -> void:
	var nx: int = int(ceil((poly_hi.x - poly_lo.x) / CELL)) + 1
	var nz: int = int(ceil((poly_hi.y - poly_lo.y) / CELL)) + 1
	var downtown: Vector2 = Vector2(890.0, 445.0)     # Financial District, by the Bay Bridge
	for gx in nx:
		for gz in nz:
			var x: float = poly_lo.x + float(gx) * CELL
			var z: float = poly_lo.y + float(gz) * CELL
			var c: Vector2 = Vector2(x + CELL * 0.5, z + CELL * 0.5)
			if not _in_land(c):
				continue                              # ocean -- the sea plane shows through
			var cell: Rect2 = Rect2(x, z, CELL, CELL)
			if _in_park(c):
				_tile(cell, "park")
				continue
			if _near_arterials(c, ROAD_HALF):
				_tile(cell, "hood_hot" if OS.get_environment("SPECTRE_TDIAG2") != "" else "road")   # TEMP diag hook
				continue
			# a building block: ground base under it (fills the inter-building gaps)
			_tile(cell, "cloth" if OS.get_environment("SPECTRE_TDIAG2") != "" else "ground")        # TEMP diag hook
			if rng.randf() < 0.06:
				_tile(Rect2(x + 3.0, z + 3.0, CELL - 6.0, CELL - 6.0), "lot")   # open lot, no building
				continue
			var dc: float = c.distance_to(downtown)
			var fl: int = 1 + rng.randi() % 2
			var tall: bool = false
			if dc < 210.0:
				fl = 9 + rng.randi() % 12             # DOWNTOWN SKYSCRAPERS -- 9-20 storeys
				tall = true
			elif dc < 360.0:
				fl = 4 + rng.randi() % 4              # inner-city mid-rise
			elif dc < 540.0:
				fl = 2 + rng.randi() % 3
			# footprints kept well inside the cell -- WIDE gaps (~12-20 m) between buildings so
			# units have real room to move + fight in the streets. Downtown towers sit on a bigger base.
			var lo: float = 0.64 if tall else 0.54
			var hi: float = 0.82 if tall else 0.72
			var bw: float = CELL * rng.randf_range(lo, hi)
			var bd: float = CELL * rng.randf_range(lo, hi)
			_building(rng, c.x - bw * 0.5 + rng.randf_range(-3.0, 3.0), c.y - bd * 0.5 + rng.randf_range(-3.0, 3.0), bw, bd, fl, tall)


## Is c within `half` metres of any arterial segment?
func _near_arterials(c: Vector2, half: float) -> bool:
	for art in arterials:
		for i in art.size() - 1:
			if _dist_to_seg(c, art[i], art[i + 1]) < half:
				return true
	return false


## The MAJOR San Francisco arterials, each a polyline in the map's coordinate space
## (x = east, z = south). These ARE the roads -- the poster's thick black lines. Minor
## cross-streets are just the gaps between packed building blocks.
func _arterials() -> Array:
	return [
		PackedVector2Array([Vector2(895, 430), Vector2(660, 610), Vector2(440, 770)]),                 # Market St (Ferry -> Twin Peaks)
		PackedVector2Array([Vector2(585, 150), Vector2(585, 470), Vector2(600, 720), Vector2(645, 955)]), # Van Ness / S Van Ness / 101
		PackedVector2Array([Vector2(815, 405), Vector2(500, 390), Vector2(150, 375)]),                 # Geary Blvd
		PackedVector2Array([Vector2(258, 185), Vector2(258, 560), Vector2(255, 905)]),                 # 19th Ave / Park Presidio (Hwy 1)
		PackedVector2Array([Vector2(150, 552), Vector2(400, 550), Vector2(585, 535)]),                 # Fulton St (N edge of GG Park)
		PackedVector2Array([Vector2(150, 662), Vector2(400, 662), Vector2(578, 655)]),                 # Lincoln Way (S edge of GG Park)
		PackedVector2Array([Vector2(585, 600), Vector2(700, 575), Vector2(792, 555)]),                 # Fell / Oak (Panhandle -> downtown)
		PackedVector2Array([Vector2(835, 235), Vector2(900, 360), Vector2(925, 490), Vector2(915, 590)]), # The Embarcadero
		PackedVector2Array([Vector2(835, 375), Vector2(795, 300), Vector2(768, 238)]),                 # Columbus Ave
		PackedVector2Array([Vector2(890, 470), Vector2(862, 680), Vector2(835, 870), Vector2(830, 960)]), # 3rd St / Bayshore
		PackedVector2Array([Vector2(660, 610), Vector2(650, 780), Vector2(645, 945)]),                 # Mission / Guerrero
		PackedVector2Array([Vector2(845, 825), Vector2(640, 830), Vector2(440, 835)]),                 # Cesar Chavez (Army St)
		PackedVector2Array([Vector2(150, 890), Vector2(255, 900), Vector2(412, 905)]),                 # Sloat / Junipero Serra (SW)
		PackedVector2Array([Vector2(390, 180), Vector2(600, 195), Vector2(795, 225)]),                 # Bay St / North Point (N waterfront)
		PackedVector2Array([Vector2(440, 770), Vector2(360, 822), Vector2(300, 872)]),                 # Portola (Market SW -> West Portal)
		PackedVector2Array([Vector2(520, 300), Vector2(520, 540), Vector2(530, 760)]),                 # Divisadero (cross-town N-S)
	]


## Trees + shrubs -- cool foliage that reads DARK on the feed (vegetation is evaporative).
## Dense in the named parks, along the coastal fringe, and scattered street trees, so the map
## reads as a real vegetated environment. Canopy-only spheres (trunk invisible at FLIR range).
func _scatter_trees(rng: RandomNumberGenerator) -> void:
	var mat: ShaderMaterial = ThermalLib.get_material("foliage", _snap_res)
	for pk in parks:
		var n: int = clampi(int(pk.size.x * pk.size.y / 300.0), 4, 55)
		for _t in n:
			_foliage(Vector2(rng.randf_range(pk.position.x, pk.end.x), rng.randf_range(pk.position.y, pk.end.y)), rng, mat, rng.randf() < 0.75)
	for _s in 130:
		var p: Vector2 = Vector2(rng.randf_range(poly_lo.x, poly_hi.x), rng.randf_range(poly_lo.y, poly_hi.y))
		if not _in_land(p):
			continue
		_foliage(p, rng, mat, rng.randf() < 0.45)


func _foliage(p: Vector2, rng: RandomNumberGenerator, mat: ShaderMaterial, tree: bool) -> void:
	var r: float = rng.randf_range(2.1, 3.3) if tree else rng.randf_range(0.8, 1.5)
	var s: SphereMesh = SphereMesh.new()
	s.radius = r
	s.height = r * (2.3 if tree else 1.4)
	s.radial_segments = 6
	s.rings = 3
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = s
	mi.position = Vector3(p.x, r * (0.95 if tree else 0.5), p.y)
	mi.material_override = mat
	add_child(mi)


## A sand ring along the coastline: a beach band from BEACH_SEA out over the water to
## BEACH_W inland, laid just under the ground so the city covers the inland side and the
## beach shows as a bright fringe at the waterline.
func _lay_beach() -> void:
	if land_poly.is_empty():
		return
	var n: int = land_poly.size()
	var ctr: Vector2 = Vector2.ZERO
	for v in land_poly:
		ctr += v
	ctr /= float(n)
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for e in n:
		var a: Vector2 = land_poly[e]
		var b: Vector2 = land_poly[(e + 1) % n]
		var inward: Vector2 = (b - a).orthogonal().normalized()
		if (ctr - (a + b) * 0.5).dot(inward) < 0.0:
			inward = -inward
		var ai: Vector2 = a + inward * BEACH_W
		var bi: Vector2 = b + inward * BEACH_W
		var ao: Vector2 = a - inward * BEACH_SEA
		var bo: Vector2 = b - inward * BEACH_SEA
		var p0: Vector3 = Vector3(ao.x, -0.04, ao.y)
		var p1: Vector3 = Vector3(bo.x, -0.04, bo.y)
		var p2: Vector3 = Vector3(bi.x, -0.04, bi.y)
		var p3: Vector3 = Vector3(ai.x, -0.04, ai.y)
		for v in [p0, p2, p1, p0, p3, p2, p0, p1, p2, p0, p2, p3]:   # both windings (cull_back -- see _emit_surfaces)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v.x, v.z) * 0.02)
			st.add_vertex(v)
	st.generate_tangents()      # normals-without-tangents breaks custom shaders (see _emit_surfaces)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = ThermalLib.get_material("beach", _snap_res)
	add_child(mi)


## The San Francisco coastline, clockwise from the Lands End / Presidio tip. Unmistakably
## the peninsula: straight Ocean Beach (W), the Marina waterfront (N), the Financial District
## jutting NE into the bay, Hunters Point pointing E (SE), and the Lake Merced notch (SW).
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


## The named parks, the two escape bridges, and the map bounds -- derived from the polygon.
func _lay_geography() -> void:
	water = []
	poly_lo = land_poly[0]
	poly_hi = land_poly[0]
	for v in land_poly:
		poly_lo = poly_lo.min(v)
		poly_hi = poly_hi.max(v)
	land = Rect2(poly_lo, poly_hi - poly_lo)

	parks = [
		Rect2(155, 552, 430, 105),   # Golden Gate Park -- the long E-W green, west-centre
		Rect2(195, 180, 190, 150),   # the Presidio -- NW
		Rect2(585, 585, 115, 38),    # the Panhandle -- E of GG Park
		Rect2(175, 300, 85, 70),     # Lincoln Park / Lands End -- NW coast
		Rect2(545, 638, 62, 58),     # Buena Vista Park
		Rect2(642, 715, 45, 45),     # Dolores Park -- the Mission
		Rect2(720, 895, 115, 95),    # McLaren Park -- SE
		Rect2(430, 690, 120, 110),   # Twin Peaks / Mount Sutro -- the central hills
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


## Perpendicular distance from p to segment a-b.
func _dist_to_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / maxf(1e-4, ab.length_squared()), 0.0, 1.0)
	return p.distance_to(a + ab * t)


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


## Single-mesh / low-mat PSX shells only. NEVER the mega-packs (tacos, laundry,
## buildings.glb, forest, industrial, downtown) — those are hundreds of meshes.
## The general city: low/mid-rise shells + the Blender-extracted mid-rise blocks (buildings.glb
## storefront blocks + a few downtown residential/civic buildings) for a real, varied streetscape.
const LIGHT_BUILDINGS: Array = [
	"res://models/buildings and scenery/psx_russian_soviet_housing_3d_model.glb",
	"res://models/buildings and scenery/low-poly_building.glb",
	"res://models/buildings and scenery/psx_old_house.glb",
	"res://models/buildings and scenery/psx_old_abandoned_mansion.glb",
	"res://models/buildings and scenery/psxprop_-_old_warehouse.glb",
	"res://models/buildings and scenery/psx_prop_-_old_garage.glb",
	"res://models/buildings and scenery/building_-_quarter_arc.glb",
	"res://models/buildings and scenery/psx_japanese_warehouse.glb",
	"res://models/buildings and scenery/ps1_style_workshop.glb",
	"res://models/buildings and scenery/psx_apartment.glb",
	"res://models/buildings and scenery/psx_building.glb",
	# extracted storefront/mid-rise blocks (buildings.glb)
	"res://models/buildings and scenery/building_01.glb",
	"res://models/buildings and scenery/building_02.glb",
	"res://models/buildings and scenery/building_03.glb",
	"res://models/buildings and scenery/building_04.glb",
	"res://models/buildings and scenery/building_05.glb",
	"res://models/buildings and scenery/building_06.glb",
	"res://models/buildings and scenery/building_07.glb",
	"res://models/buildings and scenery/building_08.glb",
	"res://models/buildings and scenery/building_09.glb",
	"res://models/buildings and scenery/building_base.glb",
	# extracted downtown residential / civic (mid-rise)
	"res://models/buildings and scenery/downtown_residential_2.glb",
	"res://models/buildings and scenery/downtown_residential_3.glb",
	"res://models/buildings and scenery/downtown_residential_4.glb",
	"res://models/buildings and scenery/downtown_mall_1.glb",
	"res://models/buildings and scenery/downtown_publicbuilding_1.glb",
]


## Single-mesh shells that stretch cleanly into a TALL tower -- the downtown high-rises. Kept
## separate from LIGHT_BUILDINGS so only the right models get pulled up into skyscrapers.
const SKYSCRAPERS: Array = [
	"res://models/buildings and scenery/downtown_modernoffice_1.glb",
	"res://models/buildings and scenery/downtown_modernoffice_1_b.glb",
	"res://models/buildings and scenery/downtown_modernoffice_2.glb",
	"res://models/buildings and scenery/downtown_modernoffice_3.glb",
	"res://models/buildings and scenery/downtown_modernoffice_4.glb",
	"res://models/buildings and scenery/downtown_modernoffice_5.glb",
	"res://models/buildings and scenery/downtown_modernoffice_5_b.glb",
	"res://models/buildings and scenery/downtown_flatiron_1.glb",
	"res://models/buildings and scenery/downtown_classicoffice_1.glb",
	"res://models/buildings and scenery/downtown_brownstoneoffice_1.glb",
	"res://models/buildings and scenery/downtown_brownstoneoffice_2.glb",
	"res://models/buildings and scenery/downtown_artdeco_1.glb",
	"res://models/buildings and scenery/downtown_brutal_1.glb",
	"res://models/buildings and scenery/building_-_stretched_octagonal_-_tier.glb",
	"res://models/buildings and scenery/building_-_square_-_illuminated.glb",
]


## `tall` = a downtown skyscraper: pulled from the SKYSCRAPERS set and flagged NOT lootable
## (you don't clear a 15-storey tower like a corner shop). Everything else is a lootable shell.
func _building(rng: RandomNumberGenerator, x: float, z: float, w: float, d: float, fl: int, tall: bool = false) -> void:
	var h: float = float(fl) * FLOOR_H
	# 35% brick structure map vs cast concrete — same temperature class.
	var wall_mat: String = "brick" if rng.randf() < 0.35 else "wall"
	buildings.append({"x": x, "z": z, "w": w, "d": d, "fl": fl, "loot": not tall})

	# Prefer one stretched PSX shell (1–2 meshes) over 5+ greybox draw calls.
	var pool: Array = SKYSCRAPERS if tall else LIGHT_BUILDINGS
	var path: String = pool[rng.randi() % pool.size()]
	# 0° / 90° only — keeps stretched footprints aligned to the parcel axes (and off the
	# rotated-mesh bright-quad bug).
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

	# LOOTABLE buildings wear a small hot rooftop beacon that strobes + blooms on the feed, so
	# you can pick out what's worth breaching (skyscrapers don't get one -- they're not lootable).
	if not tall:
		var beacon: MeshInstance3D = MeshInstance3D.new()
		var bm: SphereMesh = SphereMesh.new()
		bm.radius = 0.7
		bm.height = 1.4
		bm.radial_segments = 6
		bm.rings = 3
		beacon.mesh = bm
		beacon.position = Vector3(x + w * 0.5, h + 1.1, z + d * 0.5)
		beacon.material_override = ThermalLib.get_material("loot_beacon", _snap_res)
		beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(beacon)
