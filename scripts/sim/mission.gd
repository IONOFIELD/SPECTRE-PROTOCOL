class_name Mission
extends RefCounted

## The mission from the PLAYER's team's point of view (element `player_element`); the
## other teams are AI rivals. You WIN by any of:
##   - escaping across a bridge (all your living units in an escape zone), OR
##   - extracting by evac helo (all your living units on an evac LZ), OR
##   - eliminating every rival team.
## But once the SANITATION FORCE is deployed the board changes: extraction + elimination
## are off -- you can only escape a bridge, OR defeat the whole Sanitation force.
## You LOSE the moment your team is wiped (another team, the horde, or Sanitation).
##
## Pure logic over a WorldSim; main owns the deploy trigger, the markers, the banner.

enum { ONGOING, WON, LOST }

var t: float = 0.0                    # survival clock
var escapes: Array[Rect2] = []        # bridge far ends
var evacs: Array[Rect2] = []          # evac-helo LZs
var player_element: int = 0
var n_elements: int = 4
var result: int = ONGOING
var reason: String = ""               # why it ended (debrief headline)


func setup(escape_zones: Array[Rect2], evac_zones: Array[Rect2], player_elem: int, elements: int) -> void:
	escapes = escape_zones
	evacs = evac_zones
	player_element = player_elem
	n_elements = elements
	result = ONGOING
	reason = ""
	t = 0.0


## `sani_deployed` is owned by main (the Sanitation force arrives on a trigger).
func update(sim: WorldSim, dt: float, sani_deployed: bool) -> void:
	if result != ONGOING:
		return
	t += dt
	var mine: Array = sim.element_ids(player_element)   # living, not-yet-extracted
	if mine.is_empty():
		result = LOST
		reason = "TEAM OVERRUN"
		return
	if _all_in(sim, mine, escapes):
		_board(sim, mine)
		result = WON
		reason = "EXFIL ON FOOT"
		return
	if sani_deployed:
		# apex loose: escape (above) is the only exit unless you wipe the whole force.
		if not _any_alive(sim, WorldSim.SANITATION):
			result = WON
			reason = "SANITATION DEFEATED"
		return
	if not evacs.is_empty() and _all_in(sim, mine, evacs):
		_board(sim, mine)
		result = WON
		reason = "EXTRACTED BY AIR"
		return
	if n_elements > 1 and rivals_left(sim) == 0:
		result = WON
		reason = "ENEMY TEAMS ELIMINATED"


func rivals_left(sim: WorldSim) -> int:
	var n: int = 0
	for e in n_elements:
		if e != player_element and not sim.element_ids(e).is_empty():
			n += 1
	return n


func _board(sim: WorldSim, ids: Array) -> void:
	for i in ids:
		sim.extract(i)   # off the map -- saved, not dead


func _all_in(sim: WorldSim, ids: Array, zones: Array[Rect2]) -> bool:
	if zones.is_empty():
		return false
	for i in ids:
		var inside: bool = false
		for z in zones:
			if z.has_point(sim.pos[i]):
				inside = true
				break
		if not inside:
			return false
	return true


func _any_alive(sim: WorldSim, team_id: int) -> bool:
	for i in sim.count():
		if sim.alive[i] and sim.team[i] == team_id and not sim.extracted[i]:
			return true
	return false
