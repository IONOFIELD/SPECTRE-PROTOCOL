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
const ROAD_HALF: float = 22.0   # buildings whose cell-centre is within this of an arterial are held off the roadway
const ROAD_W: float = 15.0      # actual road WIDTH -- a narrow street, to the scale of the cars/buildings
const ROAD_Y: float = 0.08      # roads ride a hair over the ground base (avoids z-fighting the ground quads)
const BEACH_W: float = 24.0     # how far the sand reaches inland from the coastline
const BEACH_SEA: float = 10.0   # ...and how far it laps out over the water

@export var grid_n: int = 13     # (kept for compat; the layout is arterial-driven now)
@export var seed_value: int = 11

var _snap_res: Vector2i = Vector2i(640, 360)
var buildings: Array[Dictionary] = []
var _surfaces: Dictionary = {}   # material -> Array[Rect2], all disjoint, all y = 0
var _road_tris: PackedVector3Array = PackedVector3Array()   # continuous road ribbons (free triangles, y = ROAD_Y)

# geography, filled by generate() and read by main + the sim
var land_poly: PackedVector2Array = PackedVector2Array()   # the SF coastline (irregular)
var water: Array[Rect2] = []     # (unused with a polygon; the ocean plane is the sea now)
var bridges: Array[Rect2] = []   # walkable decks, movement-slowed -- the only ways off the peninsula
var escapes: Array[Rect2] = []   # bridge far ends: step inside to get off the map
var far_lands: Array = []        # large model-free landmasses the bridges run to (illusion of a wider world)
var dogleg: PackedVector2Array = PackedVector2Array()   # Bay Bridge's 45deg span past Treasure Island (visual deck)
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
			# The CORRECT single winding (front faces up). The old [a,c,b,a,d,c] wound the quads
			# the wrong way -> culled (invisible) under cull_back; the double-winding hack that
			# followed flip-flopped at grazing/altitude and z-fought. This is just the up-facing set.
			for v in [a, b, c, a, c, d]:
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

	# the road network: one continuous ribbon mesh laid over the ground along the arterials
	if not _road_tris.is_empty():
		var rst: SurfaceTool = SurfaceTool.new()
		rst.begin(Mesh.PRIMITIVE_TRIANGLES)
		for v in _road_tris:
			rst.set_normal(Vector3.UP)
			rst.set_uv(Vector2(v.x, v.z) * 0.02)
			rst.add_vertex(v)
		rst.generate_tangents()
		var rmi: MeshInstance3D = MeshInstance3D.new()
		rmi.mesh = rst.commit()
		rmi.material_override = ThermalLib.get_material("road", _snap_res)
		add_child(rmi)


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
	_road_tris.clear()
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
	_lay_islands()          # the far landmasses (bare ground) the bridges run out to

	# bridge decks over the water (a mid-tone between water and land, so they read)
	for b in bridges:
		_tile(b, "bridge")
	if not dogleg.is_empty():
		_fill_polygon(dogleg, "bridge", 0.0)   # the Bay Bridge's off-screen dogleg past Treasure Island
	_bridge_towers(bridges[1], false)    # Bay Bridge towers (procedural); the Golden Gate's come from the GLB
	_lay_gg_bridge()                     # the iconic Golden Gate, a low-poly GLB reskinned as cold steel

	# the arterials, as overlay centrelines (main draws these as the "black line" roads)
	for art in arterials:
		for i in art.size() - 1:
			road_lines.append([art[i], art[i + 1]])

	_lay_city(rng)          # cell grid: parks / ground base / building blocks (roadway kept clear)
	_lay_roads()            # continuous road ribbons flowing along the arterials, over the ground
	_scatter_trees(rng)     # trees + shrubs -- a real, vegetated environment
	_scatter_far_foliage(rng)   # wooded groves on the far landmasses (Marin / East Bay hills)
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
			# a continuous GROUND base under every non-park cell (fills the inter-building gaps AND
			# beds the road ribbons that are laid over the top in _lay_roads).
			_tile(cell, "ground")
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
			var bx: float = c.x - bw * 0.5 + rng.randf_range(-3.0, 3.0)
			var bz: float = c.y - bd * 0.5 + rng.randf_range(-3.0, 3.0)
			# never spill a footprint into the bay or onto a road ribbon: the shell must sit fully on
			# land, clear of every arterial. Roads then read as running BETWEEN the blocks, never through
			# a building. (Park cells were already handled above, so roads/blocks never land in a park.)
			if not _footprint_in_land(bx, bz, bw, bd):
				continue
			if _footprint_hits_road(bx, bz, bw, bd):
				continue
			_building(rng, bx, bz, bw, bd, fl, tall)


## All four corners of the footprint inside the coastline? Cell-centre-in-land isn't enough at an
## irregular coast -- this keeps the whole shell on land so nothing hangs out over the water.
func _footprint_in_land(x: float, z: float, w: float, d: float) -> bool:
	for corner in [Vector2(x, z), Vector2(x + w, z), Vector2(x + w, z + d), Vector2(x, z + d)]:
		if not _in_land(corner):
			return false
	return true


## Would this footprint touch a road? Tests the outline (corners, edge midpoints, centre) against
## every arterial segment, so a building is never placed on the roadway -- roads route between blocks.
func _footprint_hits_road(x: float, z: float, w: float, d: float) -> bool:
	var clr: float = ROAD_W * 0.5 + 2.5
	var pts: Array = [
		Vector2(x, z), Vector2(x + w, z), Vector2(x + w, z + d), Vector2(x, z + d),
		Vector2(x + w * 0.5, z), Vector2(x + w * 0.5, z + d),
		Vector2(x, z + d * 0.5), Vector2(x + w, z + d * 0.5),
		Vector2(x + w * 0.5, z + d * 0.5),
	]
	for art in arterials:
		for i in art.size() - 1:
			for p in pts:
				if _dist_to_seg(p, art[i], art[i + 1]) < clr:
					return true
	return false


## The road NETWORK, laid as continuous ribbons that FLOW along each arterial polyline and
## OVERLAP where arterials cross -> one interconnected mesh, no fractured per-cell strips. Each
## segment is an oriented quad of width ROAD_W; each vertex a rounded disc so turns join cleanly
## (a diagonal like Market St now reads as a true diagonal avenue, not a staircase of steps).
func _lay_roads() -> void:
	var half: float = ROAD_W * 0.5
	for art in arterials:
		var n: int = art.size()
		# walk each segment in short steps and DROP any step whose midpoint is inside a park -- roads
		# run only along the park BORDERS (the edge arterials), never across a park's interior.
		for i in n - 1:
			var a: Vector2 = art[i]
			var b: Vector2 = art[i + 1]
			var steps: int = maxi(1, int(ceil(a.distance_to(b) / 11.0)))
			for k in steps:
				var p0: Vector2 = a.lerp(b, float(k) / float(steps))
				var p1: Vector2 = a.lerp(b, float(k + 1) / float(steps))
				if _in_park((p0 + p1) * 0.5):
					continue
				_road_seg(p0, p1, half)
		# a disc at every vertex rounds the joint on turns -- but not where a vertex sits in a park
		for i in n:
			if not _in_park(art[i]):
				_road_disc(art[i], half)


## One straight ribbon quad down segment a->b, ROAD_W wide, at y = ROAD_Y. Corners ordered to the
## same front-up winding as _emit_surfaces (right-of-a, right-of-b, left-of-b, left-of-a).
func _road_seg(a: Vector2, b: Vector2, half: float) -> void:
	var dv: Vector2 = b - a
	if dv.length() < 0.001:
		return
	var dir: Vector2 = dv.normalized()
	var nrm: Vector2 = Vector2(-dir.y, dir.x) * half     # unit perpendicular, scaled to half-width
	var c0: Vector2 = a - nrm
	var c1: Vector2 = b - nrm
	var c2: Vector2 = b + nrm
	var c3: Vector2 = a + nrm
	_road_tris.append_array([
		Vector3(c0.x, ROAD_Y, c0.y), Vector3(c1.x, ROAD_Y, c1.y), Vector3(c2.x, ROAD_Y, c2.y),
		Vector3(c0.x, ROAD_Y, c0.y), Vector3(c2.x, ROAD_Y, c2.y), Vector3(c3.x, ROAD_Y, c3.y),
	])


## A filled disc (triangle fan) at a road vertex -- rounds the joint so consecutive segments and
## crossing arterials merge into a continuous surface with no gap on the outside of the turn.
func _road_disc(ctr: Vector2, r: float, segs: int = 10) -> void:
	var prev: Vector2 = ctr + Vector2(r, 0.0)
	for k in range(1, segs + 1):
		var ang: float = TAU * float(k) / float(segs)
		var cur: Vector2 = ctr + Vector2(cos(ang), sin(ang)) * r
		_road_tris.append_array([
			Vector3(ctr.x, ROAD_Y, ctr.y), Vector3(prev.x, ROAD_Y, prev.y), Vector3(cur.x, ROAD_Y, cur.y),
		])
		prev = cur


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


func _foliage(p: Vector2, rng: RandomNumberGenerator, mat: ShaderMaterial, tree: bool, scale: float = 1.0) -> void:
	var r: float = (rng.randf_range(2.1, 3.3) if tree else rng.randf_range(0.8, 1.5)) * scale
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


## Wooded GROVES on the far landmasses -- Marin's headlands + the East Bay hills are green, not bare
## slabs. Clumped (not evenly scattered) so they read as thickets of dark canopy at a distance, using
## the same cool evaporative foliage as the city. far_lands aren't gameplay space -- pure dressing.
func _scatter_far_foliage(rng: RandomNumberGenerator) -> void:
	if far_lands.is_empty():
		return
	var mat: ShaderMaterial = ThermalLib.get_material("foliage", _snap_res)
	for poly in far_lands:
		var lo: Vector2 = poly[0]
		var hi: Vector2 = poly[0]
		for v in poly:
			lo = lo.min(v)
			hi = hi.max(v)
		var clumps: int = clampi(int((hi.x - lo.x) * (hi.y - lo.y) / 7000.0), 8, 26)
		for _c in clumps:
			var ctr: Vector2 = Vector2.ZERO
			var ok: bool = false
			for _try in 14:                              # find a clump centre inside the coastline
				var q: Vector2 = Vector2(rng.randf_range(lo.x, hi.x), rng.randf_range(lo.y, hi.y))
				if Geometry2D.is_point_in_polygon(q, poly):
					ctr = q
					ok = true
					break
			if not ok:
				continue
			# big canopy blobs (2.2x city trees) packed tight -> merge into a dark thicket that reads
			# as woods even from the AC-130's altitude, not a pixel-sized speck.
			for _t in 5 + rng.randi() % 5:               # 5-9 blobs per grove
				var p: Vector2 = ctr + Vector2(rng.randf_range(-11.0, 11.0), rng.randf_range(-11.0, 11.0))
				if Geometry2D.is_point_in_polygon(p, poly):
					_foliage(p, rng, mat, rng.randf() < 0.9, 2.2)


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
		for v in [p0, p1, p2, p0, p2, p3]:   # correct single winding, front up (see _emit_surfaces)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(v.x, v.z) * 0.02)
			st.add_vertex(v)
	st.generate_tangents()      # normals-without-tangents breaks custom shaders (see _emit_surfaces)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = ThermalLib.get_material("beach", _snap_res)
	add_child(mi)


## The far landmasses the bridges run to -- large, MODEL-FREE ground (no city, no props) that sells
## an interconnected world. Bare `ground`, laid a hair below y=0 so the bridge decks read cleanly
## on top where they plug in. Not in land_poly, so nothing spawns/walks there -- pure backdrop.
func _lay_islands() -> void:
	for poly in far_lands:
		_fill_polygon(poly, "ground", -0.05)


## Fill a simple polygon with a flat mesh of `mat` at height y. Triangles are forced to the same
## front-up winding as _emit_surfaces (+ tangents), so it renders under the thermal shader.
func _fill_polygon(poly: PackedVector2Array, mat: String, y: float) -> void:
	var idx: PackedInt32Array = Geometry2D.triangulate_polygon(poly)
	if idx.is_empty():
		return
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var i: int = 0
	while i < idx.size():
		var a: Vector2 = poly[idx[i]]
		var b: Vector2 = poly[idx[i + 1]]
		var c: Vector2 = poly[idx[i + 2]]
		if (b - a).cross(c - a) < 0.0:          # flip to the up-facing winding (see _emit_surfaces)
			var t: Vector2 = b
			b = c
			c = t
		for p in [a, b, c]:
			st.set_normal(Vector3.UP)
			st.set_uv(p * 0.02)
			st.add_vertex(Vector3(p.x, y, p.y))
		i += 3
	st.generate_tangents()
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = ThermalLib.get_material(mat, _snap_res)
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

	# Golden Gate Park is ONE long RECTANGLE on the left, standing alone. The little parks that used to
	# crowd it are GONE: the Panhandle (hugging its east end) and Buena Vista (which overlapped its SE
	# corner, breaking the rectangle) are removed. The Presidio (by the GG Bridge) keeps its natural
	# shape; the other, larger parks are unchanged.
	parks = [
		Rect2(155, 552, 430, 105),   # Golden Gate Park -- the long E-W green, west-centre (RECTANGLE, standalone)
		Rect2(195, 180, 190, 150),   # the Presidio -- NW, by the GG Bridge (exception, not squared)
		Rect2(180, 297, 76, 76),     # Lincoln Park / Lands End -- NW coast
		Rect2(642, 715, 45, 45),     # Dolores Park -- the Mission
		Rect2(727, 892, 100, 100),   # McLaren Park -- SE
		Rect2(435, 690, 110, 110),   # Twin Peaks / Mount Sutro -- the central hills
	]
	# BRIDGES. The Golden Gate runs north to a big MARIN landmass (a low-poly GLB sits on this deck);
	# the Bay Bridge runs east to TREASURE ISLAND, then doglegs ~45deg and trails off the map to
	# Oakland (never reached). The walkable decks (nav / gauntlet / escape) are the axis-aligned Rect2s
	# below; the dogleg past Treasure Island is a VISUAL deck only. WIN zones sit on the reachable decks.
	bridges = [
		Rect2(251, -450, 34, 630),   # Golden Gate, north: SF coast (~z150) -> Marin (~z-405). Narrow -- the GLB rides here.
		Rect2(950, 435, 340, 72),    # Bay Bridge, east: SF coast (~x940) -> Treasure Island (~x1290)
	]
	escapes = [
		Rect2(251, -120, 34, 46),    # Marin end -- win zone on the GG deck (unchanged position, narrowed to the deck)
		Rect2(1246, 435, 44, 72),    # Treasure Island end -- win zone on the Bay deck (UNCHANGED)
	]
	# Large, MODEL-FREE landmasses (NOT in land_poly -> nothing spawns or walks there; pure backdrop).
	far_lands = [
		PackedVector2Array([   # MARIN -- big, fills the north horizon well beyond the widest view
			Vector2(-360, -410), Vector2(-320, -820), Vector2(-120, -1240), Vector2(280, -1400),
			Vector2(680, -1330), Vector2(970, -1000), Vector2(1010, -640), Vector2(840, -420),
			Vector2(520, -395), Vector2(120, -405),
		]),
		PackedVector2Array([   # TREASURE ISLAND -- a modest island midway on the Bay Bridge
			Vector2(1090, 360), Vector2(1150, 340), Vector2(1290, 350), Vector2(1330, 440),
			Vector2(1310, 520), Vector2(1210, 545), Vector2(1100, 520), Vector2(1075, 440),
		]),
	]
	# Past Treasure Island the Bay Bridge turns ~45deg and runs off the map SE (Oakland, never reached).
	# A VISUAL deck only -- a diagonal quad over the water, trailing beyond the map bounds "into nothing".
	var dl_a: Vector2 = Vector2(1305, 500)          # off Treasure Island's SE shoulder
	var dl_b: Vector2 = Vector2(1820, 1015)         # off-screen SE, past the map edge
	var dl_n: Vector2 = (dl_b - dl_a).normalized().orthogonal() * 36.0    # half the deck width
	dogleg = PackedVector2Array([dl_a - dl_n, dl_b - dl_n, dl_b + dl_n, dl_a + dl_n])

	map_lo = poly_lo
	map_hi = poly_hi
	for b in bridges:
		map_lo = map_lo.min(b.position)
		map_hi = map_hi.max(b.end)
	for e in escapes:
		map_lo = map_lo.min(e.position)
		map_hi = map_hi.max(e.end)
	for fl in far_lands:                 # the camera must be able to pan out far enough to see them
		for v in fl:
			map_lo = map_lo.min(v)
			map_hi = map_hi.max(v)
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


## The Golden Gate as a HERO PROP: a low-poly GLB reskinned to cold steel (`parapet`), scaled to span
## its deck and grounded, so the bridge reads as the icon instead of a bare grey slab + boxy towers.
## The walkable deck tile underneath stays (units cross it at y=0); this is the superstructure on top.
func _lay_gg_bridge() -> void:
	var deck: Rect2 = bridges[0]
	var model: Vector3 = Vector3(18.5, 74.1, 392.7)     # measured GLB bounds (metres)
	var s: float = deck.size.y / model.z                # deck runs N-S (z) -- uniform-fit to its length
	var node: Node3D = ThermalModel.spawn_fit(
		"res://models/buildings and scenery/golden_gate_bridge.glb", "parapet", _snap_res, model * s, 0.0)
	if node == null:
		return
	node.position.x = deck.position.x + deck.size.x * 0.5   # centre on the deck; spawn_fit already grounded y
	node.position.z = deck.position.y + deck.size.y * 0.5
	add_child(node)


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
		# spawn_fit already grounded the base to y=0 (via _align_bottom_to_y0) -- KEEP that y and
		# only place it in XZ. Overwriting y with 0.0 (the old bug) discarded the grounding, so any
		# shell whose model origin wasn't at its base floated in the sky or sank into the ground.
		shell.position.x = x + w * 0.5
		shell.position.z = z + d * 0.5
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
