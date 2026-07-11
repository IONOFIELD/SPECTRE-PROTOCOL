class_name Mission
extends RefCounted

## The exfil objective for the SF map: get off the peninsula ON FOOT. The only ways
## out are the two bridges -- Golden Gate (north) and the Bay Bridge (east) -- each
## a zombie-choked deck. An element whose living members ALL reach a bridge's far
## end (an escape zone) has ESCAPED; one wiped to the last is LOST. Win when no
## element is still out and at least one got clear; lose when every element dies.
## No helicopter, no clock pressure -- the Sanitation Force is the pressure. `t` is
## just the survival clock.
##
## Pure logic over a WorldSim -- no nodes, no rendering -- so it runs headless.
## main.gd owns the clock display, the bridge markers, and the banner.

enum { ONGOING, WON, LOST }

var t: float = 0.0                    # elapsed mission time (survival clock)
var escapes: Array[Rect2] = []        # bridge far-end zones; a unit inside one is clear
var n_elements: int = 4
var status: Array[int] = []           # per element: 0 active, 1 escaped, 2 lost
var result: int = ONGOING


func setup(escape_zones: Array[Rect2], elements: int) -> void:
	escapes = escape_zones
	n_elements = elements
	status.clear()
	for e in elements:
		status.append(0)
	result = ONGOING
	t = 0.0


func update(sim: WorldSim, dt: float) -> void:
	if result != ONGOING:
		return
	t += dt
	for e in n_elements:
		if status[e] != 0:
			continue
		var ids: Array = sim.element_ids(e)      # living, not-yet-extracted members
		if ids.is_empty():
			status[e] = 2                         # wiped to the last
			continue
		if _all_clear(sim, ids):
			for i in ids:
				sim.extract(i)                   # off the map -- saved, not dead
			status[e] = 1
	_tally()


## Has any element made it out? (drives the "keep moving" HUD cue)
func any_clear() -> bool:
	for s in status:
		if s == 1:
			return true
	return false


func _all_clear(sim: WorldSim, ids: Array) -> bool:
	for i in ids:
		if not _in_escape(sim.pos[i]):
			return false
	return true


func _in_escape(p: Vector2) -> bool:
	for z in escapes:
		if z.has_point(p):
			return true
	return false


func _tally() -> void:
	var active: int = 0
	var clear: int = 0
	for s in status:
		if s == 0:
			active += 1
		elif s == 1:
			clear += 1
	if active == 0:
		result = WON if clear > 0 else LOST
