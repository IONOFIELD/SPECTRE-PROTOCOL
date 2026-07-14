class_name CityGen
extends Node3D

## San Francisco, from the poster: the coastline silhouette (Ocean Beach straight W, the Financial
## District jutting NE into the bay, Hunters Point SE, Lake Merced notch SW) + the named parks.
##
## The city is a STREET GRID (_lay_city): cardinal N-S + E-W streets on a BLOCK pitch, with buildings
## filling the blocks between them, aligned to the streets. Clean perpendicular intersections; roads
## read as running BETWEEN the blocks. N-S streets ride STREET_DY above the E-W ones so crossings draw
## cleanly with NO coplanar overlap (that overlap was a z-fighting shimmer). A fine CELL grid lays the
## ground/park base under everything. `road_lines` (the street centrelines) drive car + truck placement.

const FLOOR_H: float = 3.4
const CELL: float = 44.0        # fine grid for the ground/park base tiles
const BLOCK: float = 92.0       # STREET GRID pitch -- street centre to street centre (a city block)
const SETBACK: float = 3.5      # building set-back past the kerb into the block
const PERIM_INSET: float = 30.0 # the coastal RING road runs this far inside the shoreline (a clean outer loop)
const STREET_DY: float = 0.24   # N-S streets ride this much above E-W so crossings never z-fight
const ROAD_W: float = 15.0      # street WIDTH -- a narrow 2-lane street, to the scale of the cars/buildings
const ROAD_Y: float = 0.70      # roads sit clearly above the ground base. MOBILE's depth buffer resolves
                                # much less than desktop's at the max-zoom altitude (~0.5 m floor if it's a
                                # 16-bit buffer), so this is raised past 0.5 to clear it -- still ~sub-pixel
                                # at gameplay zooms. Paired with a tightened camera near/far.
const WALK_W: float = 2.3       # sidewalk width each side of the asphalt
const WALK_Y: float = 0.84      # sidewalks sit a touch higher than the road -> reads as a raised kerb
const BEACH_W: float = 24.0     # how far the sand reaches inland from the coastline
const BEACH_SEA: float = 10.0   # ...and how far it laps out over the water

@export var grid_n: int = 13     # (kept for compat; the layout is arterial-driven now)
@export var seed_value: int = 11

var _snap_res: Vector2i = Vector2i(640, 360)
var buildings: Array[Dictionary] = []
var _surfaces: Dictionary = {}   # material -> Array[Rect2], all disjoint, all y = 0
var _road_tris: PackedVector3Array = PackedVector3Array()   # asphalt (2-lane) road ribbons (free triangles, y = ROAD_Y)
var _walk_tris: PackedVector3Array = PackedVector3Array()   # raised sidewalk kerbs flanking the roads (y = WALK_Y)
var _mass_st: Dictionary = {}    # material -> SurfaceTool: ALL building boxes merge into one mesh per material (few draw calls, mobile-friendly)

# geography, filled by generate() and read by main + the sim
var land_poly: PackedVector2Array = PackedVector2Array()   # the SF coastline (irregular)
var water: Array[Rect2] = []     # (unused with a polygon; the ocean plane is the sea now)
var bridges: Array[Rect2] = []   # walkable decks, movement-slowed -- the only ways off the peninsula
var escapes: Array[Rect2] = []   # bridge far ends: step inside to get off the map
var far_lands: Array = []        # large model-free landmasses the bridges run to (illusion of a wider world)
var parks: Array[Rect2] = []     # Golden Gate Park, the Presidio, the Panhandle, Twin Peaks, ...
var road_lines: Array = []       # street centrelines [a, b] -- cars ride these; truck deploy snaps to them
var _no_build_lines: Array = []  # NON-grid road centrelines (perimeter loop + park borders + bridge spurs)
                                 # that buildings must clear -- the block grid already sets them back from
                                 # the GRID streets, but not from these, so shells used to sit on them
var ring_poly: PackedVector2Array = PackedVector2Array()   # the coastal RING road path (inset land_poly); city fits inside it
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
		mi.material_override = ThermalLib.get_material(mat, _snap_res, 0)   # snap OFF on flat terrain -- the PS1 vertex-snap makes large flat surfaces (roads/ground) crawl + shimmer as the camera orbits
		add_child(mi)

	# the road network: 2-lane asphalt ribbons + raised sidewalk kerbs, laid over the ground
	_emit_tris(_road_tris, "road")
	_emit_tris(_walk_tris, "sidewalk")


## Commit a free-triangle list (from _road_seg/_strip) as one mesh under `mat`, with the
## up-facing normals + UVs + tangents every thermal surface needs.
func _emit_tris(tris: PackedVector3Array, mat: String) -> void:
	if tris.is_empty():
		return
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in tris:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(v.x, v.z) * 0.02)
		st.add_vertex(v)
	st.generate_tangents()
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = ThermalLib.get_material(mat, _snap_res, 0)   # snap OFF on flat terrain -- the PS1 vertex-snap makes large flat surfaces (roads/ground) crawl + shimmer as the camera orbits
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
	_road_tris.clear()
	_walk_tris.clear()
	_mass_st.clear()
	road_lines.clear()
	_no_build_lines.clear()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value

	land_poly = _smooth_coast(_sf_polygon(), 2)   # round the 20-vertex silhouette so the shore reads smooth
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
		smi.material_override = ThermalLib.get_material("water", _snap_res, 0)   # snap OFF -- the huge flat ocean would shimmer worst of all
		add_child(smi)

	_lay_beach()
	_lay_islands()          # the far landmasses (bare ground) the bridges run out to
	_lay_alcatraz()         # a wee island out in the bay, just the rock + the cellhouse, for fun

	# bridge decks over the water (a mid-tone between water and land, so they read)
	for b in bridges:
		_tile(b, "bridge")
	_lay_gg_bridge()                     # the iconic Golden Gate (low-poly GLB), reskinned cold steel
	_lay_bay_bridge()                    # the Bay Bridge (McClintic-Marshall GLB): SF->TI span + the dogleg span

	_lay_city(rng)          # STREET GRID: ground/park base + grid roads + buildings filling the blocks
	_emit_massing()         # commit all the accumulated building boxes -> one merged mesh per material
	_scatter_trees(rng)     # trees + shrubs -- a real, vegetated environment
	_scatter_far_foliage(rng)   # wooded groves on the far landmasses (Marin / East Bay hills)
	_emit_surfaces()


## The city as a STREET GRID: cardinal N-S + E-W streets on a BLOCK pitch, with buildings filling the
## blocks between them (aligned to the streets). Ground/park base under everything (fine cells). This
## replaces the old sparse arterials -- sensible perpendicular intersections + road-aligned buildings.
func _lay_city(rng: RandomNumberGenerator) -> void:
	_compute_ring()                                            # the coastal RING path (land_poly, inset)
	var sxs: Array = _street_positions(poly_lo.x, poly_hi.x)   # N-S street centre x's
	var szs: Array = _street_positions(poly_lo.y, poly_hi.y)   # E-W street centre z's
	_grid_road_lines(sxs, szs)                                 # centrelines for cars / truck deploy
	# ground + park base (fine cells, disjoint, y = 0)
	var nx: int = int(ceil((poly_hi.x - poly_lo.x) / CELL)) + 1
	var nz: int = int(ceil((poly_hi.y - poly_lo.y) / CELL)) + 1
	for gx in nx:
		for gz in nz:
			var x: float = poly_lo.x + float(gx) * CELL
			var z: float = poly_lo.y + float(gz) * CELL
			var c: Vector2 = Vector2(x + CELL * 0.5, z + CELL * 0.5)
			if not _in_land(c):
				continue
			_tile(Rect2(x, z, CELL, CELL), "park" if _in_park(c) else "ground")
	_lay_grid_roads(sxs, szs)      # the street mesh (clipped to the ring), over the ground
	_lay_market_st()               # the diagonal MARKET ST avenue cutting NE->SW across the grid (SF's signature)
	_lay_perimeter_loop()          # ONE big coastal loop road around the outside -- no perimeter dead-ends
	_lay_park_roads()              # a loop road AROUND each park, so grid streets connect around it (not dead-end in)
	_lay_bridge_spurs()            # a short road from the grid onto each bridge deck (so a road actually leads to it)
	_lay_blocks(rng, sxs, szs)     # buildings filling each block, inside the ring + clear of ALL the above roads


## Evenly spaced street centres from lo..hi on a BLOCK pitch (half a block of margin at each end).
func _street_positions(lo: float, hi: float) -> Array:
	var out: Array = []
	var p: float = lo + BLOCK * 0.5
	while p < hi:
		out.append(p)
		p += BLOCK
	return out


## Street centrelines (whole spans) for car placement + truck-deploy snapping -- the grid + the ring.
func _grid_road_lines(sxs: Array, szs: Array) -> void:
	for sx in sxs:
		road_lines.append([Vector2(sx, poly_lo.y), Vector2(sx, poly_hi.y)])
	for sz in szs:
		road_lines.append([Vector2(poly_lo.x, sz), Vector2(poly_hi.x, sz)])
	var n: int = ring_poly.size()
	for i in n:
		road_lines.append([ring_poly[i], ring_poly[(i + 1) % n]])


## Lay the grid streets, clipped to land + out of parks. N-S streets ride STREET_DY ABOVE the E-W
## ones, so where they cross the raised street simply draws on top -- a clean intersection with NO
## coplanar overlap (that overlap was the "glitchy shimmer"). Both run continuously; no gaps needed.
func _lay_grid_roads(sxs: Array, szs: Array) -> void:
	var half: float = ROAD_W * 0.5
	var step: float = 16.0
	for sx in sxs:
		var z: float = poly_lo.y
		while z < poly_hi.y - 0.5:
			var e: float = minf(z + step, poly_hi.y)
			var mid: Vector2 = Vector2(sx, (z + e) * 0.5)
			if _in_ring(mid) and not _in_park(mid):
				_road_seg(Vector2(sx, z), Vector2(sx, e), half, STREET_DY)
			z = e
	for sz in szs:
		var x: float = poly_lo.x
		while x < poly_hi.x - 0.5:
			var e: float = minf(x + step, poly_hi.x)
			var mid: Vector2 = Vector2((x + e) * 0.5, sz)
			if _in_ring(mid) and not _in_park(mid):
				_road_seg(Vector2(x, sz), Vector2(e, sz), half, 0.0)
			x = e


## MARKET ST: SF's signature diagonal avenue, cutting NE (the Ferry Building / downtown, by the Bay
## Bridge) -> SW (toward Twin Peaks) across the cardinal grid. A touch wider than a street and ridden
## ABOVE the grid so it draws cleanly OVER every crossing (a grand avenue, not a mess of intersections).
func _lay_market_st() -> void:
	var half: float = ROAD_W * 0.5 + 3.5           # a broad avenue
	# EXTENDS FROM the Bay Bridge's peninsula terminus (the deck's west edge, on its centreline) and runs
	# SW toward Twin Peaks -- SF's real Market St starts at the Embarcadero by the bridge and cuts across
	# the grid. Anchoring it to the bridge stops it reading as a stub "jammed in" the middle of downtown.
	var bay: Rect2 = bridges[1]                    # the Bay Bridge deck
	var a: Vector2 = Vector2(bay.position.x - 20.0, bay.position.y + bay.size.y * 0.5)   # just inland of the deck, mid-z
	var b: Vector2 = Vector2(455.0, 725.0)         # SW end, toward Twin Peaks
	road_lines.append([a, b])
	_no_build_lines.append([a, b])
	var steps: int = maxi(1, int(ceil(a.distance_to(b) / 16.0)))
	for k in steps:
		var p0: Vector2 = a.lerp(b, float(k) / float(steps))
		var p1: Vector2 = a.lerp(b, float(k + 1) / float(steps))
		var mid: Vector2 = (p0 + p1) * 0.5
		# clip to LAND (not the ring inset) so the NE tip runs right up to the bridge approach; never in a park
		if _in_land(mid) and not _in_park(mid):
			_road_seg(p0, p1, half, STREET_DY + 0.16)   # rides highest -> wins over the grid at every crossing


## Fill each block (the land between four streets) with buildings ALIGNED to the grid + set back from
## the kerbs, so the city reads as buildings lining the streets. Downtown (near the Bay Bridge) rises
## into towers. Footprints are clipped to land + kept out of the parks.
func _lay_blocks(rng: RandomNumberGenerator, sxs: Array, szs: Array) -> void:
	var downtown: Vector2 = Vector2(890.0, 445.0)
	var m: float = ROAD_W * 0.5 + SETBACK
	for i in range(sxs.size() + 1):
		var x0: float = (poly_lo.x if i == 0 else float(sxs[i - 1])) + m
		var x1: float = (poly_hi.x if i == sxs.size() else float(sxs[i])) - m
		if x1 - x0 < 14.0:
			continue
		for j in range(szs.size() + 1):
			var z0: float = (poly_lo.y if j == 0 else float(szs[j - 1])) + m
			var z1: float = (poly_hi.y if j == szs.size() else float(szs[j])) - m
			if z1 - z0 < 14.0:
				continue
			var block: Rect2 = Rect2(x0, z0, x1 - x0, z1 - z0)
			if not _in_land(block.get_center()):
				continue
			_fill_block(rng, block, block.get_center().distance_to(downtown))


## One block -> a small tidy grid of building plots, aligned to the streets. Occasional gaps read as
## yards / parking. Each plot's shell is skipped if it would spill into the water or a park.
func _fill_block(rng: RandomNumberGenerator, block: Rect2, dc: float) -> void:
	# Small plots + a low skip rate PACK each block with buildings (the dense "real city" coverage) --
	# cheap now that the whole city is one merged mesh, so density costs a few triangles, not draw calls.
	var np_x: int = maxi(1, int(round(block.size.x / 26.0)))
	var np_z: int = maxi(1, int(round(block.size.y / 26.0)))
	var pw: float = block.size.x / float(np_x)
	var pd: float = block.size.y / float(np_z)
	for a in np_x:
		for b in np_z:
			if rng.randf() < 0.06:
				continue                                   # a yard / lot -- a few open plots
			var gap: float = 3.5
			var bw: float = pw - gap
			var bd: float = pd - gap
			if bw < 8.0 or bd < 8.0:
				continue
			var bx: float = block.position.x + float(a) * pw + gap * 0.5
			var bz: float = block.position.y + float(b) * pd + gap * 0.5
			if not _footprint_in_land(bx, bz, bw, bd) or _footprint_in_park(bx, bz, bw, bd) \
					or _footprint_hits_road(bx, bz, bw, bd):
				continue
			var fl: int = 1 + rng.randi() % 2
			var tall: bool = false
			if dc < 210.0:
				fl = 9 + rng.randi() % 12                   # DOWNTOWN SKYSCRAPERS
				tall = true
			elif dc < 360.0:
				fl = 4 + rng.randi() % 4                    # inner-city mid-rise
			elif dc < 540.0:
				fl = 2 + rng.randi() % 3
			_building(rng, bx, bz, bw, bd, fl, tall)


## The footprint (GROWN by COAST_MARGIN) fully inside the RING? Buildings sit inside the coastal loop
## road, set back off it -- so nothing overhangs the water, the ground always covers them, and they
## line the ring instead of dead-ending at the shore. (Ring is inset from the coast, so this is on land.)
const COAST_MARGIN: float = 13.0

func _footprint_in_land(x: float, z: float, w: float, d: float) -> bool:
	var m: float = COAST_MARGIN
	for corner in [Vector2(x - m, z - m), Vector2(x + w + m, z - m), Vector2(x + w + m, z + d + m), Vector2(x - m, z + d + m)]:
		if not _in_ring(corner):
			return false
	return true


## Does the footprint overlap any park? A whole-rect test (not just the centre) so a block-edge shell
## never bleeds into Golden Gate Park or the squares.
func _footprint_in_park(x: float, z: float, w: float, d: float) -> bool:
	var r: Rect2 = Rect2(x, z, w, d)
	for pk in parks:
		if r.intersects(pk):
			return true
	return false


## The coastal RING path: land_poly inset by PERIM_INSET, largest piece (the inset can split at a deep
## notch). Empty if the offset fails, in which case _in_ring falls back to the raw coastline.
func _compute_ring() -> void:
	ring_poly = PackedVector2Array()
	var best: float = 0.0
	for p in Geometry2D.offset_polygon(land_poly, -PERIM_INSET):
		var a: float = absf(_poly_area(p))
		if a > best:
			best = a
			ring_poly = p


func _poly_area(poly: PackedVector2Array) -> float:
	var a: float = 0.0
	var n: int = poly.size()
	for i in n:
		var p0: Vector2 = poly[i]
		var p1: Vector2 = poly[(i + 1) % n]
		a += p0.x * p1.y - p1.x * p0.y
	return a * 0.5


## Inside the coastal ring? (Falls back to the raw coastline if the inset failed.)
func _in_ring(p: Vector2) -> bool:
	if ring_poly.size() < 3:
		return _in_land(p)
	return Geometry2D.is_point_in_polygon(p, ring_poly)


## ONE big loop road following the coastal ring -- the outer belt every grid street runs out to, so the
## perimeter reads as a connected LOOP, not a fringe of dead-ends. Rides a touch above the grid so the
## T-junctions where the streets meet it never z-fight; clipped out of the parks like the grid.
func _lay_perimeter_loop() -> void:
	if ring_poly.size() < 3:
		return
	var half: float = ROAD_W * 0.5
	var n: int = ring_poly.size()
	for i in n:
		var a: Vector2 = ring_poly[i]
		var b: Vector2 = ring_poly[(i + 1) % n]
		_no_build_lines.append([a, b])          # keep buildings off the loop
		var steps: int = maxi(1, int(ceil(a.distance_to(b) / 16.0)))
		for k in steps:
			var p0: Vector2 = a.lerp(b, float(k) / float(steps))
			var p1: Vector2 = a.lerp(b, float(k + 1) / float(steps))
			if _in_park((p0 + p1) * 0.5):
				continue
			_road_seg(p0, p1, half, STREET_DY + 0.08)


## A road loop AROUND each park's border, so the grid streets that run up to a park connect to a road
## that routes around it instead of dead-ending at the edge. Rides a touch above the grid at junctions.
func _lay_park_roads() -> void:
	var half: float = ROAD_W * 0.5
	for pk in parks:
		var corners: Array = [pk.position, Vector2(pk.end.x, pk.position.y), pk.end, Vector2(pk.position.x, pk.end.y)]
		for i in 4:
			var a: Vector2 = corners[i]
			var b: Vector2 = corners[(i + 1) % 4]
			road_lines.append([a, b])
			_no_build_lines.append([a, b])
			var steps: int = maxi(1, int(ceil(a.distance_to(b) / 16.0)))
			for k in steps:
				var p0: Vector2 = a.lerp(b, float(k) / float(steps))
				var p1: Vector2 = a.lerp(b, float(k + 1) / float(steps))
				var mid: Vector2 = (p0 + p1) * 0.5
				# skip where the park border hugs the coast -- the perimeter LOOP already runs there, so
				# laying the park road on top of it was the "GGP meeting the beach" overlap the user saw.
				if _in_ring(mid) and not _near_ring(mid, ROAD_W + 6.0):
					_road_seg(p0, p1, half, STREET_DY + 0.11)


## A short road spur from the grid onto each bridge deck's peninsula end, so a road actually LEADS onto
## the bridge (the grid streets are clipped to the ring and otherwise stop short of the deck).
func _lay_bridge_spurs() -> void:
	var half: float = ROAD_W * 0.5
	for deck in bridges:
		# the deck's LONG axis tells us which end sits on the peninsula + which way to run the spur inland
		var horizontal: bool = deck.size.x >= deck.size.y
		var endp: Vector2
		var inland: Vector2
		if horizontal:                                   # Bay: runs E-W, peninsula end at min-x (west)
			endp = Vector2(deck.position.x, deck.position.y + deck.size.y * 0.5)
			inland = endp + Vector2(-80.0, 0.0)
		else:                                            # GG: runs N-S, peninsula end at max-z (south)
			endp = Vector2(deck.position.x + deck.size.x * 0.5, deck.position.y + deck.size.y)
			inland = endp + Vector2(0.0, 80.0)
		road_lines.append([inland, endp])
		_no_build_lines.append([inland, endp])
		var steps: int = maxi(1, int(ceil(inland.distance_to(endp) / 16.0)))
		for k in steps:
			var p0: Vector2 = inland.lerp(endp, float(k) / float(steps))
			var p1: Vector2 = inland.lerp(endp, float(k + 1) / float(steps))
			_road_seg(p0, p1, half, STREET_DY + 0.13)    # onto the deck; rides highest so junctions win


## Does the footprint (grown a little) come within a road-corridor's clearance of any NON-grid road
## (perimeter loop / park border / bridge spur)? The block grid already sets shells back from the GRID
## streets; this keeps them off the roads the grid doesn't know about.
func _footprint_hits_road(x: float, z: float, w: float, d: float) -> bool:
	var c: Vector2 = Vector2(x + w * 0.5, z + d * 0.5)
	var clr: float = ROAD_W * 0.5 + maxf(w, d) * 0.5 + 2.5    # road half + footprint radius + a margin
	for line in _no_build_lines:
		if _dist_point_seg(c, line[0], line[1]) < clr:
			return true
	return false


## Shortest distance from point p to segment a->b.
func _dist_point_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var l2: float = ab.length_squared()
	var t: float = 0.0 if l2 < 1e-6 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Is p within `d` of the coastal RING (the perimeter loop road path)? Used to stop other roads from
## being laid on top of the loop where they'd double up (the coastal-junction overlap).
func _near_ring(p: Vector2, d: float) -> bool:
	var n: int = ring_poly.size()
	if n < 2:
		return false
	for i in n:
		if _dist_point_seg(p, ring_poly[i], ring_poly[(i + 1) % n]) < d:
			return true
	return false


## One street segment a->b: a central 2-LANE asphalt ribbon flanked by a raised SIDEWALK kerb on each
## side, so the road reads as a real street. `half` is the corridor half-width (ROAD_W/2); `dy` lifts
## the whole street (N-S streets ride a hair up so they win cleanly where they cross the E-W ones).
func _road_seg(a: Vector2, b: Vector2, half: float, dy: float = 0.0) -> void:
	var road_half: float = maxf(1.0, half - WALK_W)
	_strip(a, b, -road_half, road_half, ROAD_Y + dy, _road_tris)     # the 2-lane asphalt
	_strip(a, b, road_half, half, WALK_Y + dy, _walk_tris)           # left sidewalk (raised kerb)
	_strip(a, b, -half, -road_half, WALK_Y + dy, _walk_tris)         # right sidewalk (raised kerb)


## A flat ribbon quad down a->b spanning perpendicular offsets o0..o1 at height y, front-up wound
## (right-of-a, right-of-b, left-of-b, left-of-a -- same order _emit_surfaces uses).
func _strip(a: Vector2, b: Vector2, o0: float, o1: float, y: float, arr: PackedVector3Array) -> void:
	var dv: Vector2 = b - a
	if dv.length() < 0.001:
		return
	var n: Vector2 = Vector2(-dv.y, dv.x).normalized()
	var c0: Vector2 = a + n * o0
	var c1: Vector2 = b + n * o0
	var c2: Vector2 = b + n * o1
	var c3: Vector2 = a + n * o1
	arr.append_array([
		Vector3(c0.x, y, c0.y), Vector3(c1.x, y, c1.y), Vector3(c2.x, y, c2.y),
		Vector3(c0.x, y, c0.y), Vector3(c2.x, y, c2.y), Vector3(c3.x, y, c3.y),
	])


## Trees + shrubs -- cool foliage that reads DARK on the feed (vegetation is evaporative).
## Dense in the named parks, along the coastal fringe, and scattered street trees, so the map
## reads as a real vegetated environment. Canopy-only spheres (trunk invisible at FLIR range).
func _scatter_trees(rng: RandomNumberGenerator) -> void:
	var mat: ShaderMaterial = ThermalLib.get_material("foliage", _snap_res)
	for pk in parks:
		var n: int = clampi(int(pk.size.x * pk.size.y / 300.0), 4, 55)
		for _t in n:
			var fp: Vector2 = Vector2(rng.randf_range(pk.position.x, pk.end.x), rng.randf_range(pk.position.y, pk.end.y))
			if not _in_land(fp):
				continue                       # a park's rect can lap over the coast -- no trees in the water
			_foliage(fp, rng, mat, rng.randf() < 0.75)
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
	mi.material_override = ThermalLib.get_material("beach", _snap_res, 0)   # snap OFF -- flat shoreline
	add_child(mi)


## The far landmasses the bridges run to -- large, MODEL-FREE ground (no city, no props) that sells
## an interconnected world. Bare `ground`, laid a hair below y=0 so the bridge decks read cleanly
## on top where they plug in. Not in land_poly, so nothing spawns/walks there -- pure backdrop.
func _lay_islands() -> void:
	for poly in far_lands:
		_fill_polygon(poly, "ground", -0.05)


## Alcatraz: a small rock out in the bay (north of the wharf) with a simple cellhouse block on it.
## Not gameplay space -- pure scenery, so no nav/spawns; just a ground fill + one box.
func _lay_alcatraz() -> void:
	var ctr: Vector2 = Vector2(720.0, 5.0)
	var isle: PackedVector2Array = PackedVector2Array([
		ctr + Vector2(-34.0, -18.0), ctr + Vector2(-8.0, -27.0), ctr + Vector2(26.0, -22.0),
		ctr + Vector2(39.0, 2.0), ctr + Vector2(27.0, 24.0), ctr + Vector2(-6.0, 29.0), ctr + Vector2(-36.0, 13.0),
	])
	_fill_polygon(isle, "ground", -0.05)
	_add_box(Vector3(ctr.x, 0.0, ctr.y), Vector3(36.0, 9.0, 13.0), "wall")   # the cellhouse -- one long block


## A copy of `poly` rotated by `ang` (about its own centroid) and re-centred on `ctr` -- used to
## reuse one landmass shape at another spot (the Marin blob becomes the Oakland blob at the Bay end).
func _placed_copy(poly: PackedVector2Array, ang: float, ctr: Vector2) -> PackedVector2Array:
	var src: Vector2 = Vector2.ZERO
	for v in poly:
		src += v
	src /= float(poly.size())
	var ca: float = cos(ang)
	var sa: float = sin(ang)
	var out: PackedVector2Array = PackedVector2Array()
	for v in poly:
		var r: Vector2 = v - src
		out.append(Vector2(r.x * ca - r.y * sa, r.x * sa + r.y * ca) + ctr)
	return out


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
	mi.material_override = ThermalLib.get_material(mat, _snap_res, 0)   # snap OFF on flat terrain -- the PS1 vertex-snap makes large flat surfaces (roads/ground) crawl + shimmer as the camera orbits
	add_child(mi)


## Chaikin corner-cutting: each pass replaces every vertex with two points 1/4 and 3/4 along its
## edges, rounding the polygon into a smooth curve. 2 passes turns the 20-vertex silhouette into an
## ~80-vertex smooth coastline, so the beach (which follows it) reads as a smooth shore, not facets.
func _smooth_coast(poly: PackedVector2Array, passes: int) -> PackedVector2Array:
	var p: PackedVector2Array = poly
	for _it in passes:
		var out: PackedVector2Array = PackedVector2Array()
		var n: int = p.size()
		for i in n:
			var a: Vector2 = p[i]
			var b: Vector2 = p[(i + 1) % n]
			out.append(a.lerp(b, 0.25))
			out.append(a.lerp(b, 0.75))
		p = out
	return p


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
		Rect2(220, 205, 175, 135),   # the Presidio -- NW, by the GG Bridge (pulled inside the coast so its NW corner no longer laps into the water by the bridge)
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
		Rect2(950, 456, 340, 30),    # Bay Bridge, east: SF coast (~x940) -> Treasure Island (~x1290). Narrow -- the GLB rides here.
	]
	escapes = [
		Rect2(251, -120, 34, 46),    # Marin end -- win zone on the GG deck (unchanged position, narrowed to the deck)
		Rect2(1246, 456, 44, 30),    # Treasure Island end -- win zone on the Bay deck (narrowed to the deck)
	]
	# Large, MODEL-FREE landmasses (NOT in land_poly -> nothing spawns or walks there; pure backdrop).
	far_lands = [
		PackedVector2Array([   # MARIN -- big, fills the north horizon well beyond the widest view. The one
			# sharp ~95deg SW corner (was the single vertex (-360,-410)) is rounded into a 3-point arc, so
			# no edge sticks out -- and Oakland, being a copy of this shape, gets the rounded corner too.
			Vector2(-250, -409), Vector2(-325, -441), Vector2(-349, -519),
			Vector2(-320, -820), Vector2(-120, -1240), Vector2(280, -1400),
			Vector2(680, -1330), Vector2(970, -1000), Vector2(1010, -640), Vector2(840, -420),
			Vector2(520, -395), Vector2(120, -405),
		]),
		PackedVector2Array([   # TREASURE ISLAND -- a SMALL island right where the Bay Bridge terminates
			Vector2(1255, 425), Vector2(1305, 415), Vector2(1360, 440),
			Vector2(1365, 495), Vector2(1330, 530), Vector2(1270, 528), Vector2(1245, 480),
		]),
	]
	# OAKLAND / East Bay: a COPY of the Marin landmass, rotated and dropped at the far end of the Bay
	# Bridge's dogleg span -- so that bridge also terminates on real land, like the Golden Gate does.
	# 135deg base minus 30deg = a 30deg COUNTER-CLOCKWISE spin (z is south/down, so +angle is CW here).
	far_lands.append(_placed_copy(far_lands[0], 2.356 - deg_to_rad(30.0), Vector2(1850.0, 1000.0)))
	# Past Treasure Island the Bay Bridge continues -- a SECOND copy of the bridge model runs off its
	# SE shoulder at ~45deg to the Oakland landmass above (never reached). See _lay_bay_bridge.

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


# --- Bridge FIT tuning (dialed in via the SPECTRE_BRIDGE side-on capture) ---
# The GLBs are fit to their deck in WIDTH + LENGTH (so the procedural deck tile is fully covered, no
# grey rectangle poking out) but kept LOW, then SUNK so the ROADWAY -- not the model's lowest strut --
# lands on the y=0 deck/road level. A suspension bridge's deck sits well above its base, so grounding
# the base alone floats the road "higher than the buildings". H = height as a fraction of the
# length-uniform scale; SINK = fraction of the scaled height to drop so the roadway reaches y=0.
# SINK = the roadway's height as a fraction of the model span above its base -- MEASURED from the GLB
# vertex distribution (GG deck sits at 0.43 of its height, Bay at 0.40). spawn_fit grounds the base to
# y=0, so subtracting SINK*scaled_height drops the ROADWAY onto the y=0 deck tile.
const GG_H: float = 0.42
const GG_SINK: float = 0.43
const BAY_H: float = 0.52
const BAY_SINK: float = 0.40


## The Golden Gate as a HERO PROP: a low-poly GLB reskinned to cold steel (`parapet`), fit to its deck
## + sunk so the ROADWAY sits on the y=0 walkable tile (units cross the tile; this is the superstructure).
func _lay_gg_bridge() -> void:
	var deck: Rect2 = bridges[0]
	var model: Vector3 = Vector3(18.5, 74.1, 392.7)     # measured GLB bounds (metres)
	var s: float = deck.size.y / model.z                # deck runs N-S (z) -- uniform-fit to its length
	var sh: float = model.y * s * GG_H                  # scaled height, kept low
	var node: Node3D = ThermalModel.spawn_fit(
		"res://models/buildings and scenery/golden_gate_bridge.glb", "parapet", _snap_res,
		Vector3(deck.size.x, sh, model.z * s), 0.0)     # width = the FULL deck (covers the tile); length = deck
	if node == null:
		return
	node.position.x = deck.position.x + deck.size.x * 0.5   # centre on the deck
	node.position.z = deck.position.y + deck.size.y * 0.5
	node.position.y += ROAD_Y - sh * GG_SINK           # roadway lands at ROAD level (just above the deck tile, no z-fight)
	add_child(node)


## The Bay Bridge as a hero prop: the McClintic-Marshall model (the firm that built the real one),
## reskinned cold steel. TWO spans, like the real bridge: the MAIN span SF -> Treasure Island (E-W),
## and a SECOND copy running off Treasure Island's SE shoulder at ~45deg, trailing off the map to
## Oakland (never reached). Procedural Bay towers are dropped in its favour.
const BAY_MODEL: Vector3 = Vector3(28.2, 49.8, 387.8)   # measured GLB bounds (metres)

func _lay_bay_bridge() -> void:
	var deck: Rect2 = bridges[1]
	var s: float = deck.size.x / BAY_MODEL.z            # uniform-fit the span to the deck length
	var w: float = deck.size.y                          # BOTH spans carry the deck WIDTH (covers the tile)
	# main span, SF -> Treasure Island (yaw 90deg -> the model's length runs east-west)
	_bay_span(Vector2(deck.position.x + deck.size.x * 0.5, deck.position.y + deck.size.y * 0.5), PI * 0.5, s, w)
	# second span, off Treasure Island's SE shoulder at 45deg, trailing off-screen SE (same width)
	var start: Vector2 = Vector2(1350.0, 500.0)
	var dir: Vector2 = Vector2(0.7071, 0.7071)          # SE
	_bay_span(start + dir * (BAY_MODEL.z * s * 0.5), PI * 0.25, s, w)


## One Bay Bridge span: fit to length + the passed `width` (so the deck tile is covered), kept low, and
## sunk so the roadway lands on the y=0 deck. `width` is the model's cross-span in world units -- after
## the yaw, the local-X (size_m.x) maps onto it, so both the 90deg main span and the 45deg dogleg get it.
func _bay_span(ctr: Vector2, yaw: float, s: float, width: float) -> void:
	var sh: float = BAY_MODEL.y * s * BAY_H
	var node: Node3D = ThermalModel.spawn_fit(
		"res://models/buildings and scenery/bay_bridge.glb", "parapet", _snap_res,
		Vector3(width, sh, BAY_MODEL.z * s), yaw)
	if node == null:
		return
	node.position.x = ctr.x
	node.position.z = ctr.y
	node.position.y += ROAD_Y - sh * BAY_SINK          # roadway at ROAD level (just above the deck tile, no z-fight)
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

	# PROCEDURAL MASSING: boxes placed to the EXACT footprint, so the visual IS the collision box --
	# no GLB-shell overhang, so units can never walk through a wall. Taller parcels get inset setback
	# tiers for a tapered skyline. (Replaces the GLB shells: cheaper, exact, and the FLIR flattens
	# building detail to a blob at range anyway, so the models bought nothing but bugs.)
	_massing(rng, x + w * 0.5, z + d * 0.5, w, d, h, fl, wall_mat)

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


## A building's mass: the ground box (== the collision footprint), a cool parapet lip round the roof,
## a hot HVAC unit on low/mid roofs, and for taller parcels 1-2 INSET SETBACK TIERS -> a tapered
## art-deco/SF skyline. Tiers sit ABOVE and INSET, so they never widen the ground footprint the sim
## collides with. Centre (cx,cz); base w x d x h.
func _massing(rng: RandomNumberGenerator, cx: float, cz: float, w: float, d: float, h: float, fl: int, wall_mat: String) -> void:
	_mass_box(wall_mat, cx, cz, 0.0, w, h, d)          # the shell -- exactly the footprint
	_roof_ring(cx, cz, w, d, h)
	# a hot rooftop unit on low/mid roofs -> a bright spot on the feed (skyscraper roofs get tiers instead)
	if fl < 6 and rng.randf() < 0.55:
		var hv: float = clampf(minf(w, d) * rng.randf_range(0.22, 0.36), 1.5, 6.0)
		_mass_box("hvac", cx + rng.randf_range(-w, w) * 0.18, cz + rng.randf_range(-d, d) * 0.18, h, hv, 1.8, hv)
	# SETBACK TIERS for taller parcels -- each tier smaller + shorter, stacked, with its own parapet
	if fl >= 6:
		var tw: float = w
		var td: float = d
		var ty: float = h
		var tiers: int = 1 if fl < 12 else 2
		for _ti in tiers:
			tw *= rng.randf_range(0.60, 0.76)
			td *= rng.randf_range(0.60, 0.76)
			if minf(tw, td) < 6.0:
				break
			var th: float = float(fl) * FLOOR_H * rng.randf_range(0.30, 0.50)
			_mass_box(wall_mat, cx, cz, ty, tw, th, td)
			_roof_ring(cx, cz, tw, td, ty + th)
			ty += th


## A thin cool parapet lip around a roof edge at height `top`, centred on (cx,cz), footprint w x d.
func _roof_ring(cx: float, cz: float, w: float, d: float, top: float) -> void:
	var t: float = clampf(minf(w, d) * 0.05, 0.6, 2.2)
	_mass_box("parapet", cx, cz - d * 0.5 + t * 0.5, top, w, 0.9, t)
	_mass_box("parapet", cx, cz + d * 0.5 - t * 0.5, top, w, 0.9, t)
	_mass_box("parapet", cx - w * 0.5 + t * 0.5, cz, top, t, 0.9, d)
	_mass_box("parapet", cx + w * 0.5 - t * 0.5, cz, top, t, 0.9, d)


## Accumulate one box into the merged per-material building mesh. (cx,cz) centre, base at y0, size sx/sy/sz.
## Uses BoxMesh + SurfaceTool.append_from so normals/UVs/winding come out correct, then all boxes of a
## material commit as ONE MeshInstance in _emit_massing -> a handful of draw calls for the whole city.
func _mass_box(mat: String, cx: float, cz: float, y0: float, sx: float, sy: float, sz: float) -> void:
	if not _mass_st.has(mat):
		var s: SurfaceTool = SurfaceTool.new()
		s.begin(Mesh.PRIMITIVE_TRIANGLES)
		_mass_st[mat] = s
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(sx, sy, sz)
	(_mass_st[mat] as SurfaceTool).append_from(bm, 0, Transform3D(Basis(), Vector3(cx, y0 + sy * 0.5, cz)))


## Commit every accumulated building box: one merged, tangent-generated mesh per material (buildings
## keep the PS1 vertex-snap -- the wobble is the point; only the flat TERRAIN opted out of snap).
func _emit_massing() -> void:
	for mat in _mass_st:
		var st: SurfaceTool = _mass_st[mat]
		st.generate_tangents()
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = ThermalLib.get_material(mat, _snap_res)
		add_child(mi)
	_mass_st.clear()
