class_name Mission
extends RefCounted

## The exfil objective. A clock runs from insertion; at HELI_ARRIVE the birds are
## on station at the LZ. An element whose living members ALL reach the LZ (bird
## present) is EXTRACTED; one whose members ALL cross the map edge has ESCAPED;
## one wiped to the last is LOST. Win when no team is still out and at least one
## got clear; lose when every team is lost.
##
## Pure logic over a WorldSim -- no nodes, no rendering -- so it runs headless.
## main.gd owns the clock's start, the Chinook, the LZ marker, and the banner.

enum { ONGOING, WON, LOST }

const HELI_ARRIVE: float = 120.0    # seconds until the exfil birds are on station
const LZ_RADIUS: float = 8.0        # a team is "on the bird" inside this

var t: float = 0.0
var lz: Vector2 = Vector2.ZERO
var edge_lo: Vector2 = Vector2.ZERO
var edge_hi: Vector2 = Vector2(512, 512)
var n_elements: int = 4
var status: Array[int] = []          # per element: 0 active, 1 extracted, 2 escaped, 3 lost
var result: int = ONGOING


func setup(lz_pos: Vector2, lo: Vector2, hi: Vector2, elements: int) -> void:
	lz = lz_pos
	edge_lo = lo
	edge_hi = hi
	n_elements = elements
	status.clear()
	for e in elements:
		status.append(0)
	result = ONGOING
	t = 0.0


func helo_on_station() -> bool:
	return t >= HELI_ARRIVE


func update(sim: WorldSim, dt: float) -> void:
	if result != ONGOING:
		return
	t += dt
	for e in n_elements:
		if status[e] != 0:
			continue
		var ids: Array = sim.element_ids(e)      # living, not-yet-extracted members
		if ids.is_empty():
			status[e] = 3                         # wiped to the last
			continue
		if _all_past_edge(sim, ids):
			for i in ids:
				sim.extract(i)
			status[e] = 2                         # broke out at the edge
		elif helo_on_station() and _all_in_lz(sim, ids):
			for i in ids:
				sim.extract(i)
			status[e] = 1                         # lifted out
	_tally()


func _all_in_lz(sim: WorldSim, ids: Array) -> bool:
	for i in ids:
		if sim.pos[i].distance_to(lz) > LZ_RADIUS:
			return false
	return true


func _all_past_edge(sim: WorldSim, ids: Array) -> bool:
	for i in ids:
		var p: Vector2 = sim.pos[i]
		if p.x >= edge_lo.x and p.x <= edge_hi.x and p.y >= edge_lo.y and p.y <= edge_hi.y:
			return false            # still on the map
	return true


func _tally() -> void:
	var active: int = 0
	var clear: int = 0
	for s in status:
		if s == 0:
			active += 1
		elif s == 1 or s == 2:
			clear += 1
	if active == 0:
		result = WON if clear > 0 else LOST
