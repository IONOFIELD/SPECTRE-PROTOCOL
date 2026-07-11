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
var water: Array[Rect2] = []     # nav + collision, NOT line of sight
var bridges: Array[Rect2] = []   # walkable decks, movement-slowed
var escapes: Array[Rect2] = []   # bridge far ends: step inside to get off the map
var land: Rect2 = Rect2()        # the walkable city block, for ambient population
var map_lo: Vector2 = Vector2.ZERO
var map_hi: Vector2 = Vector2.ZERO
var park: Rect2 = Rect2()        # Golden Gate Park, carved from the grid


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
		var rects: Array = _surfaces[mat]
		var st: SurfaceTool = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_normal(Vector3.UP)
		for r in rects:
			var a: Vector3 = Vector3(r.position.x, 0.0, r.position.y)
			var b: Vector3 = Vector3(r.end.x, 0.0, r.position.y)
			var c: Vector3 = Vector3(r.end.x, 0.0, r.end.y)
			var d: Vector3 = Vector3(r.position.x, 0.0, r.end.y)
			for v in [a, c, b, a, d, c]:      # CCW seen from above
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
	var pitch: float = BLOCK + STREET
	var span: float = float(grid_n) * pitch

	_lay_geography(span)

	# dirt bed, 80 mm down. Never coplanar with anything; covers the whole map.
	var ground: PlaneMesh = PlaneMesh.new()
	ground.size = Vector2(map_hi.x - map_lo.x + 200.0, map_hi.y - map_lo.y + 200.0)
	ground.subdivide_width = 12
	ground.subdivide_depth = 12
	var gmi: MeshInstance3D = MeshInstance3D.new()
	gmi.mesh = ground
	gmi.position = Vector3((map_lo.x + map_hi.x) * 0.5, -0.08, (map_lo.y + map_hi.y) * 0.5)
	gmi.material_override = ThermalLib.get_material("ground", _snap_res)
	add_child(gmi)

	# --- water on three sides + the two bridge decks (disjoint from the land grid)
	for w in water:
		_tile(w, "water")
	for b in bridges:
		_tile(b, "road")
	_bridge_towers(bridges[0], true)     # Golden Gate runs north -- towers span x
	_bridge_towers(bridges[1], false)    # Bay Bridge runs east -- towers span z

	# --- roads, clipped to the land so they meet the water cleanly at the edge.
	var lr: Rect2 = Rect2(0.0, 0.0, span, span)
	for j in grid_n + 1:
		var cz: float = float(j) * pitch
		_tile(Rect2(-HALF_ST, cz - HALF_ST, span + STREET, STREET).intersection(lr), "road")
	for i in grid_n + 1:
		var cx: float = float(i) * pitch
		for j in grid_n:
			var z0: float = float(j) * pitch + HALF_ST
			_tile(Rect2(cx - HALF_ST, z0, STREET, pitch - STREET).intersection(lr), "road")

	# --- blocks. Downtown leans toward the bay (Financial District, by the Bay
	# Bridge); Golden Gate Park is carved out as a green swath.
	for gx in grid_n:
		for gz in grid_n:
			var bx: float = float(gx) * pitch + HALF_ST
			var bz: float = float(gz) * pitch + HALF_ST
			if park.has_point(Vector2(bx + BLOCK * 0.5, bz + BLOCK * 0.5)):
				_tile(Rect2(bx, bz, BLOCK, BLOCK), "park")
				continue
			var dc: float = Vector2(float(gx) - (float(grid_n) - 3.0), float(gz) - 5.5).length()
			_block(rng, bx, bz, dc)

	_emit_surfaces()


## Water, bridges, escape zones and bounds around a `span`-metre land grid. Water
## avoids the bridge lanes, so the decks are walkable gaps the nav routes onto for
## free. Everything abuts the land at z=0 (north), x=span (east), x=0 (west).
func _lay_geography(span: float) -> void:
	water.clear()
	bridges.clear()
	escapes.clear()
	land = Rect2(0.0, 0.0, span, span)
	park = Rect2(70.0, 300.0, 360.0, 96.0)      # long green strip, west-centre

	# north strait, flanking the Golden Gate lane
	water.append(Rect2(0.0, -STRAIT, GG_X, STRAIT))
	water.append(Rect2(GG_X + LANE, -STRAIT, span - GG_X - LANE, STRAIT))
	# east bay, flanking the Bay Bridge lane
	water.append(Rect2(span, 0.0, BAY, BAY_Z))
	water.append(Rect2(span, BAY_Z + LANE, BAY, span - BAY_Z - LANE))
	# west ocean, wrapping the north-west corner
	water.append(Rect2(-OCEAN, -STRAIT, OCEAN, span + STRAIT))

	bridges.append(Rect2(GG_X, -STRAIT, LANE, STRAIT))          # Golden Gate, north
	bridges.append(Rect2(span, BAY_Z, BAY, LANE))               # Bay Bridge, east
	escapes.append(Rect2(GG_X, -STRAIT, LANE, FAR))             # Marin end (far north)
	escapes.append(Rect2(span + BAY - FAR, BAY_Z, FAR, LANE))   # Oakland end (far east)

	map_lo = Vector2(-OCEAN - 20.0, -STRAIT - 20.0)
	map_hi = Vector2(span + BAY + 20.0, span + 20.0)


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
