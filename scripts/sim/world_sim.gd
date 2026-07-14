class_name WorldSim
extends RefCounted

## Everything lives in metres and seconds. v0.20 was 4,200 arbitrary units with
## a rifleman crossing 55 of them per second, which works out to 24 m/s. That was
## a gameplay number wearing a physics costume. Rescaled once, here, so no
## conversion factor has to be carried through combat, LOS or ordnance later.
##
## Positions are Vector2 on the ground plane (world XZ). Height is a render
## concern and the sim never asks about it.

const RADIUS: float = 0.35            # operator footprint
const SEPARATION: float = 0.90        # start pushing apart at this range
const SEP_CAP: int = 10               # max neighbours summed for the push (dense-pile guard)
const ARRIVE: float = 0.6             # slow down inside this, stop inside RADIUS
const WAYPOINT: float = 1.1           # corner-cutting tolerance on intermediate nodes
const MAX_PUSH: float = 2.4           # m/s of separation velocity, capped
const SAN_PACK_R: float = 6.0         # Sanitation cohesion kicks in past this from the pack centre
const SAN_COHESION: float = 1.5       # how hard a straggling elite is reeled back into formation
const CELL: float = 12.0              # measured knee: rebuild cost falls with cell size,
                                      # query cost is flat (call overhead dominates candidates).
const HEAL_RANGE: float = 9.0
const HEAL_RATE: float = 14.0         # hp/s a medic restores to nearby allies
const BRIDGE_SLOW: float = 0.55       # a shove through the horde: every metre of deck is fought for
const EOD_BLAST_R: float = 4.5        # EOD grenade / RPG area radius
const EOD_BLAST_DMG: float = 30.0     # damage per hostile in the ring
const SAN_FLAME_CHANCE: float = 0.14  # a Sanitation attack projects fire this often; else a round
const PANIC_CHANCE: float = 0.0015    # per-tick odds a fleeing civilian yells (audio hook)
const INFECTED_SENSE: float = 120.0   # zombies smell warm bodies within this, wander otherwise (v0.19-natural, not a map-wide magnet)
const WANDER_SPEED: float = 0.34      # idle amble as a fraction of full speed -- the crowd/horde drifts, never freezes

# Sanitation flash-grenade evasion: when pinned (recently hit), a Sanitation elite
# will RARELY pop a flash -- a bright thermal bloom -- break contact, and slide to a
# flank to re-engage from a new angle. Long per-unit cooldown + a low roll keep it
# a rare, unsettling tell, not a reflex.
const HURT_MEMORY: float = 1.2        # s a unit counts as "under fire" after a hit
const FLASH_CD: float = 22.0          # s before the same elite may flash again
const FLASH_CHANCE: float = 0.004     # per-tick roll while pinned (~rare over a firefight)
const EVADE_TIME: float = 2.6         # s of break-contact movement after the flash
const EVADE_DIST: float = 26.0        # m of the flanking side-step

# teams. Civilians never fight (they run). Infected + Sanitation + Bandits HUNT
# (roam for the nearest warm body); Squad + Survivors hold and engage what they
# see. Sanitation clears the whole board -- the apex threat. Hostility is a
# directional matrix (see HOSTILE).
enum { SQUAD = 0, INFECTED = 1, CIVILIAN = 2, SANITATION = 3, BANDIT = 4, SURVIVOR = 5 }

# [speed m/s, hp, sight m, range m, damage, interval s]. These are v0.19's EXACT
# stat ratios (hp, damage, sight/range shape) scaled by k = 0.12 m per v0.19 unit,
# so a rifleman crosses the ~806 m map in ~120 s. Note the v0.19 truth: zombies
# (4.8) OUTRUN civilians (3.6) -- the crowd can't escape the horde without you.
const STATS: Dictionary = {
	&"cbt": [6.6, 100.0, 22.2, 18.6, 12.0, 0.9],
	&"rec": [10.6, 70.0, 37.2, 14.4, 6.0, 0.5],     # scout: fastest, sees far, hits light
	&"snp": [5.8, 80.0, 36.0, 38.4, 43.0, 2.75],    # marksman: long reach, slow rate, hard hit
	&"eod": [6.2, 130.0, 20.4, 16.2, 8.0, 1.9],     # breacher: tanky, weak sidearm
	&"med": [7.2, 90.0, 21.6, 10.8, 6.0, 1.0],      # medic: heals in contact (see _heal)
	&"cdr": [7.0, 120.0, 26.4, 19.2, 15.0, 0.9],    # commander: leads the element
	&"zed": [4.8, 60.0, 35.0, 1.4, 12.0, 1.1],      # infected: FASTER than civs, melee claw
	&"run": [7.8, 34.0, 38.0, 1.4, 9.0, 0.8],       # runner: OUTRUNS the squad, fragile, quick claw
	&"bru": [3.4, 150.0, 28.0, 1.9, 26.0, 1.6],     # brute: slow, soaks a magazine, heavy claw
	&"civ": [3.6, 40.0, 30.0, 0.0, 0.0, 0.0],       # civilian: unarmed, runs but gets caught
	&"san": [9.2, 1000.0, 40.8, 30.0, 50.0, 0.4],   # Sanitation elite: near-unkillable (1000 hp), hits like a truck, fast trigger -- you do NOT win a straight fight
	&"bnd": [6.8, 75.0, 30.0, 16.0, 14.0, 1.0],     # bandit: aggressive armed hunter, squishy
	&"svr": [5.4, 95.0, 18.0, 20.0, 16.0, 1.1],     # survivor: dug-in holdout, short sight, hits hard
}

# Directional hostility: the teams A will shoot/claw. Civilians fight no one.
# Infected bite everything living; Sanitation clears the whole board (apex).
# Bandits prey on the living + brawl the horde but won't pick a fight with
# Sanitation. Survivors are paranoid -- they fire on anyone who closes, the
# squad included -- but they don't hunt the crowd's unarmed civilians.
const HOSTILE: Dictionary = {
	SQUAD:      [INFECTED, SANITATION, BANDIT, SURVIVOR],
	INFECTED:   [SQUAD, CIVILIAN, SANITATION, BANDIT, SURVIVOR],
	CIVILIAN:   [],
	SANITATION: [SQUAD, INFECTED, CIVILIAN, BANDIT, SURVIVOR],
	BANDIT:     [SQUAD, CIVILIAN, SURVIVOR, INFECTED],
	SURVIVOR:   [INFECTED, SANITATION, BANDIT, SQUAD],
}

# Teams that ROAM the whole map for the nearest warm body (no line of sight);
# the rest hold ground and engage only what they can see.
const HUNTERS: Array = [INFECTED, SANITATION, BANDIT]

# struct of arrays. Cache friendly, trivially serialisable, and the grid can
# rebuild straight off `pos` and `alive` without touching anything else.
var pos: Array[Vector2] = []
var vel: Array[Vector2] = []
var heading: Array[float] = []
var target: Array[Vector2] = []
var has_order: Array[bool] = []
var kind: Array[StringName] = []
var team: Array[int] = []
var hp: Array[float] = []
var alive: Array[bool] = []
var selected: Array[bool] = []
var element: Array[int] = []          # player element 0-3, or -1 for non-player units
var extracted: Array[bool] = []       # boarded the exfil bird -- out of play, not dead
var foe: Array[int] = []              # current target index, -1 = none
var cd: Array[float] = []             # seconds until this unit may fire/strike again
var hurt: Array[float] = []           # seconds of "just took a hit" left (pinned tell)
var flash_cd: Array[float] = []       # sanitation: seconds until it may flash-evade again
var evade: Array[float] = []          # sanitation: seconds of break-contact left, 0 = fighting
var evade_to: Array[Vector2] = []     # sanitation: the flank point it's sliding to
# Looted-buff modifiers (the player's building rewards; neutral by default, AI never loots).
var armor: Array[float] = []          # permanent incoming-damage cut 0..1 (police vests)
var buff_t: Array[float] = []         # seconds left on the two TIMED buffs below
var buff_dmg: Array[float] = []       # outgoing-damage x-mult while buff_t > 0 (police damage buff)
var buff_res: Array[float] = []       # extra incoming cut 0..1 while buff_t > 0 (bio-lab resistance)

## Combat discipline + output. weapons_free gates squad auto-fire (the hold-fire /
## open-fire toggle). events is the per-tick log main drains for positional audio:
## [{kind, pos, team, unit}]. Both cleared at the top of every step().
var weapons_free: bool = true
var player_element: int = 0            # the element the human commands; the rest are AI rivals
var san_speed: float = 0.0            # >0 overrides the Sanitation pack's speed (gameplay sets 5% over the squad; menu leaves the fast STATS roam)
var allied: Dictionary = {}           # element -> true if that rival is allied (passive) with you
var events: Array = []
var _dmg: Dictionary = {}             # target index -> damage queued this tick
var _dmg_src: Dictionary = {}         # target index -> attacker TEAM this tick (for civ->zombie infection)
var _tick: int = 0
var _san_c: Vector2 = Vector2.ZERO     # Sanitation pack centroid (cohesion anchor), per tick
var _san_foe: int = -1                 # the pack's shared hunt target, -1 = none

var buildings: Array[Rect2] = []      # ground-plane AABBs, metres -- block LOS + nav + collision
var water: Array[Rect2] = []          # the bay/strait/ocean -- block nav + collision, NOT LOS
var bridges: Array[Rect2] = []        # walkable decks where movement is slowed to a shove
var land_poly: PackedVector2Array = PackedVector2Array()   # coastline; empty = rectangular map
var _poly_centroid: Vector2 = Vector2.ZERO
var nav: NavGrid = NavGrid.new()
var path: Array[PackedVector2Array] = []
var path_i: Array[int] = []
var grid: SpatialGrid = SpatialGrid.new()
var bgrid: RectGrid = RectGrid.new()
var _near: PackedInt32Array = PackedInt32Array()   # reused every unit, every tick
var _rng := RandomNumberGenerator.new()            # AI dice (flash-evade); fixed seed = reproducible
var _bounds_lo: Vector2 = Vector2(-64, -64)
var _bounds_hi: Vector2 = Vector2(640, 640)


func set_bounds(lo: Vector2, hi: Vector2) -> void:
	_bounds_lo = lo
	_bounds_hi = hi
	grid.setup(lo, hi, CELL)


func _init() -> void:
	grid.setup(_bounds_lo, _bounds_hi, CELL)
	_rng.seed = 0xC0FFEE


func count() -> int:
	return pos.size()


func spawn(p: Vector2, t: StringName, tm: int = 0, elem: int = -1) -> int:
	assert(STATS.has(t), "unknown unit type: " + String(t))
	pos.append(p)
	vel.append(Vector2.ZERO)
	heading.append(0.0)
	target.append(p)
	has_order.append(false)
	path.append(PackedVector2Array())
	path_i.append(0)
	kind.append(t)
	team.append(tm)
	hp.append(STATS[t][1])
	alive.append(true)
	selected.append(false)
	element.append(elem)
	extracted.append(false)
	foe.append(-1)
	cd.append(0.0)
	hurt.append(0.0)
	flash_cd.append(0.0)
	evade.append(0.0)
	evade_to.append(p)
	armor.append(0.0)
	buff_t.append(0.0)
	buff_dmg.append(1.0)
	buff_res.append(0.0)
	return pos.size() - 1


## Reuse a DEAD infected slot in place, returning its index (or -1 if none free). The spawn arrays
## are append-only, so a CONTINUOUS respawner (the swarm upkeep) would grow them every mission -- this
## keeps the unit count bounded by resurrecting a corpse's slot instead of appending a fresh one.
func recycle_infected(p: Vector2, t: StringName) -> int:
	for i in alive.size():
		if alive[i] or extracted[i] or team[i] != INFECTED:
			continue
		pos[i] = p; vel[i] = Vector2.ZERO; heading[i] = 0.0; target[i] = p
		has_order[i] = false; path[i] = PackedVector2Array(); path_i[i] = 0
		kind[i] = t; hp[i] = STATS[t][1]; alive[i] = true; selected[i] = false
		foe[i] = -1; cd[i] = 0.0; hurt[i] = 0.0; flash_cd[i] = 0.0
		evade[i] = 0.0; evade_to[i] = p; armor[i] = 0.0
		buff_t[i] = 0.0; buff_dmg[i] = 1.0; buff_res[i] = 0.0
		return i
	return -1


func speed_of(i: int) -> float:
	if team[i] == SANITATION and san_speed > 0.0:
		return san_speed          # gameplay overrides the pack speed (menu keeps the fast STATS roam)
	return STATS[kind[i]][0]


func _issue(i: int, dst: Vector2) -> void:
	var p: PackedVector2Array = nav.find_path(pos[i], dst)
	if p.is_empty():
		p = PackedVector2Array([dst])      # unreachable: steer at it and let collision arbitrate
	path[i] = p
	path_i[i] = 0
	target[i] = p[0]
	has_order[i] = true


## One A* per ORDER, not per operator. The squad is clustered, so they share a
## route and differ only in the last metre. Six searches was 200 ms of hitch.
func order_move(ids: Array, dst: Vector2) -> void:
	var n: int = ids.size()
	if n == 0:
		return
	if n == 1:
		_issue(ids[0], dst)
		return

	var centroid: Vector2 = Vector2.ZERO
	for i in ids:
		centroid += pos[i]
	centroid /= float(n)

	var route: PackedVector2Array = nav.find_path(centroid, dst)
	var ring: float = SEPARATION * 1.15 * sqrt(float(n))
	for j in n:
		var i: int = ids[j]
		var a: float = TAU * float(j) / float(n)
		var mark: Vector2 = dst + Vector2(cos(a), sin(a)) * ring * 0.5
		var p: PackedVector2Array = route.duplicate()
		if p.is_empty():
			p = PackedVector2Array([mark])
		else:
			p[p.size() - 1] = mark
		path[i] = p
		path_i[i] = 0
		target[i] = p[0]
		has_order[i] = true


func final_target(i: int) -> Vector2:
	if path[i].is_empty():
		return target[i]
	return path[i][path[i].size() - 1]


func selected_ids() -> Array:
	var out: Array = []
	for i in count():
		if alive[i] and selected[i]:
			out.append(i)
	return out


## Living units in player element `e` (0-3).
func element_ids(e: int) -> Array:
	var out: Array = []
	for i in count():
		if alive[i] and element[i] == e:
			out.append(i)
	return out


## Pull a unit off the board -- boarded onto the exfil bird. NOT a death: alive
## goes false so the sim stops processing it, but `extracted` marks it as saved.
func extract(i: int) -> void:
	extracted[i] = true
	alive[i] = false
	selected[i] = false


## Push a point out of every building it is inside, along the shallowest axis.
## Rects are axis aligned, so this is exact and there is no tunnelling as long
## as a tick cannot move a unit further than the thinnest building. At 4.2 m/s
## and a 1/60 s tick that is 7 cm.
func _resolve_buildings(p: Vector2, r: float) -> Vector2:
	# Two passes. Pushing out of one solid can push you into its neighbour, and the
	# second bucket lookup is a few nanoseconds. Water ejects like a wall: a unit
	# that strays into the bay is shoved back to the nearest shore.
	for _pass in 2:
		var before: Vector2 = p
		for bi in bgrid.at(p):
			p = _eject(p, buildings[bi].grow(r))
		for w in water:
			p = _eject(p, w.grow(r))
		# off the coast (and not on a bridge)? shove back onto the nearest shore.
		if not land_poly.is_empty() and not _on_bridge(p) and not Geometry2D.is_point_in_polygon(p, land_poly):
			p = _to_shore(p, r)
		if p.is_equal_approx(before):
			break
	return p


## Would a unit footprint at p overlap a solid -- a building, a water rect, or off-coast
## ground that isn't a bridge? Movement rejects any axis step that lands here, so units
## slide around walls and can never step into the bay (bridges stay walkable).
func _solid(p: Vector2) -> bool:
	for bi in bgrid.at(p):
		if buildings[bi].grow(RADIUS).has_point(p):
			return true
	for w in water:
		if w.grow(RADIUS).has_point(p):
			return true
	if not land_poly.is_empty() and not _on_bridge(p) and not Geometry2D.is_point_in_polygon(p, land_poly):
		return true
	return false


## Nearest point on the coastline, nudged inland by r so the footprint clears the
## water. Shoves a unit that strayed off the coast back onto land.
func _to_shore(p: Vector2, r: float) -> Vector2:
	var m: int = land_poly.size()
	var best: Vector2 = p
	var bestd: float = INF
	for e in m:
		var cp: Vector2 = Geometry2D.get_closest_point_to_segment(p, land_poly[e], land_poly[(e + 1) % m])
		var d: float = p.distance_squared_to(cp)
		if d < bestd:
			bestd = d
			best = cp
	var inward: Vector2 = _poly_centroid - best
	if inward.length_squared() > 1e-6:
		best += inward.normalized() * r
	return best


## If p is inside axis-aligned rect e, push it out along the shallowest axis.
func _eject(p: Vector2, e: Rect2) -> Vector2:
	if not e.has_point(p):
		return p
	var l: float = p.x - e.position.x
	var rr: float = e.end.x - p.x
	var u: float = p.y - e.position.y
	var d: float = e.end.y - p.y
	var m: float = minf(minf(l, rr), minf(u, d))
	if m == l:
		p.x = e.position.x
	elif m == rr:
		p.x = e.end.x
	elif m == u:
		p.y = e.position.y
	else:
		p.y = e.end.y
	return p


## Is p on a bridge deck? Bridges are a couple of rects, so a direct scan.
func _on_bridge(p: Vector2) -> bool:
	for b in bridges:
		if b.has_point(p):
			return true
	return false


## Local steering: swing a hunter's heading around whatever is DIRECTLY AHEAD -- a building, the
## water's edge, the coast (all via _solid, which is bgrid-accelerated so this is cheap). Probes a
## short forward arc and returns the first clear bearing, so the pack routes AROUND blocks and flows
## along the shore toward a bridge instead of grinding straight into the wall (the "wall-hug" fix).
func _avoid(i: int, dir: Vector2) -> Vector2:
	if dir.length_squared() < 1e-6:
		return dir
	var here: Vector2 = pos[i]
	var probe: float = RADIUS + 10.0
	if not _solid(here + dir * probe):
		return dir
	for ang in [0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.1, -2.1]:
		var cand: Vector2 = dir.rotated(ang)
		if not _solid(here + cand * probe):
			return cand
	return dir   # boxed in -- push straight, the per-axis slide in step() handles the rest


## The mouth of the bridge deck that `target` sits on -- the point on that deck nearest `from`. A hunter
## whose prey has fled onto a bridge aims HERE first, so it makes for the deck entrance and then chases
## across, instead of beelining into the water beside the span.
func _bridge_mouth(from: Vector2, target: Vector2) -> Vector2:
	for b in bridges:
		if b.has_point(target):
			return Vector2(clampf(from.x, b.position.x, b.end.x), clampf(from.y, b.position.y, b.end.y))
	return target


func step(dt: float) -> void:
	grid.rebuild(pos, alive)
	events.clear()
	_dmg.clear()
	_dmg_src.clear()
	_tick += 1
	_update_san_pack()           # the Sanitation pack's shared centroid + hunt target

	for i in count():
		if not alive[i]:
			continue
		var sp: float = speed_of(i)
		if not bridges.is_empty() and _on_bridge(pos[i]):
			sp *= BRIDGE_SLOW          # wading through the gauntlet
		cd[i] = maxf(0.0, cd[i] - dt)
		hurt[i] = maxf(0.0, hurt[i] - dt)
		flash_cd[i] = maxf(0.0, flash_cd[i] - dt)
		evade[i] = maxf(0.0, evade[i] - dt)
		buff_t[i] = maxf(0.0, buff_t[i] - dt)
		# Perception scans the SIGHT radius -- the sim's most expensive query -- so
		# each unit re-acquires only every 20th tick (~0.33 s to notice a NEW foe),
		# staggered by index so the cost spreads evenly. A unit already locked onto
		# a live, visible foe keeps it (see _acquire) and reacts instantly, so this
		# cadence only gates fresh scans. AI draws its desired velocity from the
		# fight; the squad's comes from player orders below.
		if (_tick + i) % 20 == 0:
			_acquire(i)
		var desired: Vector2 = _combat(i, sp)

		if has_order[i]:
			var last: bool = path_i[i] >= path[i].size() - 1
			var to: Vector2 = target[i] - pos[i]
			var d: float = to.length()
			var reach: float = RADIUS if last else WAYPOINT
			if d < reach:
				if last:
					has_order[i] = false
					vel[i] = Vector2.ZERO
				else:
					path_i[i] += 1
					target[i] = path[i][path_i[i]]
			else:
				var scale: float = 1.0 if (d > ARRIVE or not last) else (d / ARRIVE)
				desired = to / d * sp * scale

		# separation. Query the grid, not the whole array, and CAP the neighbours summed: in a
		# teeming pile the nearest dozen give the push -- iterating all 40+ just costs, so cap it
		# and a city of hundreds stays affordable.
		var push: Vector2 = Vector2.ZERO
		var seen: int = 0
		grid.query_into(pos[i], SEPARATION, _near)
		for j in _near:
			if j == i or not alive[j]:
				continue
			var off: Vector2 = pos[i] - pos[j]
			var dist: float = off.length()
			if dist > SEPARATION or dist < 1e-5:
				continue
			push += off / dist * (1.0 - dist / SEPARATION)
			seen += 1
			if seen >= SEP_CAP:
				break
		if push.length() > 0.0:
			desired += push.normalized() * minf(push.length() * sp, MAX_PUSH)

		vel[i] = vel[i].lerp(desired, minf(1.0, dt * 10.0))
		# Axis-separated collision: try X then Y, rejecting either step that would put
		# the footprint into a building or the water. A unit SLIDES along a wall and
		# never tunnels through it or steps into the bay; a final eject un-sticks
		# anything already overlapping (a spawn or a separation shove).
		var np: Vector2 = pos[i]
		var mv: Vector2 = vel[i] * dt
		var tx: Vector2 = np + Vector2(mv.x, 0.0)
		if not _solid(tx):
			np = tx
		var ty: Vector2 = np + Vector2(0.0, mv.y)
		if not _solid(ty):
			np = ty
		pos[i] = _resolve_buildings(np, RADIUS)

		if vel[i].length_squared() > 0.04:
			heading[i] = atan2(vel[i].x, vel[i].y)

	_reap()
	_heal(dt)


func moving(i: int) -> bool:
	return vel[i].length_squared() > 0.04


## Walls-only shortcut: bounds auto-fit the buildings + a 40 m margin. Used by the
## tests and any map with no water. For the SF map with water + bridges, load_map.
func load_buildings(rects: Array[Rect2]) -> void:
	buildings = rects
	water = []
	bridges = []
	bgrid.build(rects, 24.0, RADIUS + 0.05)
	var lo: Vector2 = Vector2(-80, -80)
	var hi: Vector2 = Vector2(560, 560)
	if not rects.is_empty():
		lo = rects[0].position
		hi = rects[0].end
		for r in rects:
			lo = lo.min(r.position)
			hi = hi.max(r.end)
		lo -= Vector2(40, 40)
		hi += Vector2(40, 40)
	set_bounds(lo, hi)
	# clearance is the operator radius plus half a nav cell, so a path down the
	# middle of a free cell always clears the wall.
	nav.build(rects, lo, hi, RADIUS + NavGrid.CELL * 0.5)


## Full map: walls (block LOS + nav + collision), water (block nav + collision but
## NOT sight -- you can see across the bay), bridges (walkable, movement-slowed),
## and explicit bounds that must span the bridges + water, not just the land. The
## bridge lanes are gaps in the water, so nav routes onto them for free.
func load_map(walls: Array[Rect2], water_rects: Array[Rect2], bridge_rects: Array[Rect2], lo: Vector2, hi: Vector2, poly: PackedVector2Array = PackedVector2Array()) -> void:
	buildings = walls
	water = water_rects
	bridges = bridge_rects
	land_poly = poly
	_poly_centroid = _centroid_of(poly)
	bgrid.build(walls, 24.0, RADIUS + 0.05)
	set_bounds(lo, hi)
	var obstacles: Array[Rect2] = walls.duplicate()
	obstacles.append_array(water_rects)
	# with a coastline the nav floods the polygon open + carves the bridges through
	# the ocean; without one it is the old rect-only navmesh.
	nav.build(obstacles, lo, hi, RADIUS + NavGrid.CELL * 0.5, NavGrid.CELL, poly, bridge_rects)


func _centroid_of(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	var c: Vector2 = Vector2.ZERO
	for v in poly:
		c += v
	return c / float(poly.size())


# ---- combat ----------------------------------------------------------------

## Does team `a` shoot/claw team `b`? Straight matrix lookup (see HOSTILE).
func _targets(a: int, b: int) -> bool:
	return a != b and (HOSTILE[a] as Array).has(b)


## Unit-level hostility, so the SQUAD faction can hold RIVAL teams: two SQUAD units of
## different elements are enemies (free-for-all) unless one is the player and that rival
## is allied (passive). Everything else is the plain team matrix.
func _hostile_units(i: int, j: int) -> bool:
	var ti: int = team[i]
	var tj: int = team[j]
	if ti == SQUAD and tj == SQUAD:
		var ei: int = element[i]
		var ej: int = element[j]
		if ei == ej:
			return false
		if ei == player_element or ej == player_element:
			var other: int = ej if ei == player_element else ei
			return not allied.get(other, false)   # hostile unless allied with the player
		return true                                 # two rivals always fight each other
	return _targets(ti, tj)


## Roamers sense the nearest warm body anywhere; holders wait to see one. Rival player
## teams (any SQUAD element that isn't the player's) roam + fight like a hostile faction.
func _hunts(t: int) -> bool:
	return HUNTERS.has(t)


func _unit_hunts(i: int) -> bool:
	if team[i] == SQUAD:
		return element[i] != player_element
	return HUNTERS.has(team[i])


## Refresh foe[i]: keep a live target still in sight, else acquire the nearest
## hostile with a clear line. Civilians never acquire -- they only flee.
func _acquire(i: int) -> void:
	var t: int = team[i]
	if t == CIVILIAN:
		foe[i] = -1
		return
	# The INFECTED smell warm bodies only within a SENSE radius (v0.19-natural) -- a zombie
	# 600 m away doesn't beeline at you; it shambles after whatever's near and wanders
	# otherwise. Same O(n) staggered scan as the other hunters, just with a distance cutoff
	# (a grid query over a 120 m radius scans more empty cells than the map has units).
	if t == INFECTED:
		# Grid query over the SENSE radius (not an O(n) whole-map scan) -- so a teeming city of
		# hundreds of zombies stays cheap: each only looks at the handful of bodies actually near it.
		grid.query_into(pos[i], INFECTED_SENSE, _near)
		var bi: int = -1
		var bid: float = INFECTED_SENSE * INFECTED_SENSE
		for j in _near:
			if j == i or not alive[j] or not _hostile_units(i, j):
				continue
			var dz: float = pos[i].distance_squared_to(pos[j])
			if dz < bid:
				bid = dz
				bi = j
		foe[i] = bi
		return
	# The other HUNTERS (sanitation, bandits, rival squads) sense the nearest warm body
	# anywhere on the map -- relentless. Staggered O(n), a fraction of a tick.
	if _unit_hunts(i):
		var best: int = -1
		var bestd: float = INF
		for j in count():
			if j == i or not alive[j] or not _hostile_units(i, j):
				continue
			var dd: float = pos[i].distance_squared_to(pos[j])
			if dd < bestd:
				bestd = dd
				best = j
		foe[i] = best
		return
	# The squad only engages what it can actually see: sight radius + a clear line.
	var sight: float = STATS[kind[i]][2]
	var f: int = foe[i]
	if f != -1 and f < count() and alive[f] and pos[i].distance_to(pos[f]) <= sight and _los(pos[i], pos[f]):
		return
	grid.query_into(pos[i], sight, _near)
	var best2: int = -1
	var bestd2: float = sight * sight
	for j in _near:
		if j == i or not alive[j] or not _hostile_units(i, j):
			continue
		var dd: float = pos[i].distance_squared_to(pos[j])
		if dd < bestd2 and _los(pos[i], pos[j]):
			bestd2 = dd
			best2 = j
	foe[i] = best2


## AI desired velocity + any shot/strike for unit i. Squad movement stays player-
## driven (this returns ZERO for the squad); it only fires here.
func _combat(i: int, sp: float) -> Vector2:
	var t: int = team[i]
	if t == CIVILIAN:
		return _flee(i, sp)
	if t == SANITATION:
		return _san_combat(i, sp)      # one tight, fast, roaming pack -- search & destroy
	var f: int = foe[i]
	if f == -1 or not alive[f]:
		return _wander(i, sp) if t == INFECTED else Vector2.ZERO   # idle zombies shamble, don't freeze
	var d: float = pos[i].distance_to(pos[f])
	var reach: float = STATS[kind[i]][3]
	if t == INFECTED:
		if d <= reach:
			if cd[i] <= 0.0:
				_strike(i, f)
			return Vector2.ZERO
		return _avoid(i, (pos[f] - pos[i]) / maxf(d, 1e-5)) * sp   # zeds route around blocks too
	# shooters: squad, bandits, survivors. Fire in range, clear line.
	# Only the squad's trigger is disciplined (weapons_free); the rest fire at will.
	if d <= reach and _los(pos[i], pos[f]):
		if cd[i] <= 0.0 and (t != SQUAD or weapons_free or element[i] != player_element):
			_strike(i, f)
		return Vector2.ZERO          # in range: stand and shoot
	if _unit_hunts(i):
		return _avoid(i, (pos[f] - pos[i]) / maxf(d, 1e-5)) * sp   # rivals, bandits close in
	return Vector2.ZERO              # your squad + survivors hold (player-ordered; survivor digs in)


## The Sanitation force fights as ONE tight, fast pack. It roams to the nearest prey to
## the pack's centre (search & destroy), reels stragglers back with cohesion, fires
## anything in range, and still pops the odd flash-evade when pinned.
func _san_combat(i: int, sp: float) -> Vector2:
	if evade[i] > 0.0:                          # mid-evade: slide to the flank point
		var run: Vector2 = evade_to[i] - pos[i]
		var rd: float = run.length()
		return run / rd * sp if rd > 1.5 else Vector2.ZERO
	var f: int = foe[i]
	if f != -1 and alive[f] and hurt[i] > 0.0 and flash_cd[i] <= 0.0 and _rng.randf() < FLASH_CHANCE:
		return _pop_flash(i, f, sp)             # pinned: flash-bang + break contact
	# fire anything in range + line of sight, but KEEP MOVING with the pack -- they gun down
	# what they pass without ever breaking formation.
	if f != -1 and alive[f] and cd[i] <= 0.0:
		var reach: float = STATS[kind[i]][3]
		if pos[i].distance_to(pos[f]) <= reach and _los(pos[i], pos[f]):
			_strike(i, f)
	# ROAM as one tight pack: steer to the shared hunt target + cohesion toward the centre
	var dir: Vector2 = Vector2.ZERO
	if _san_foe != -1 and alive[_san_foe]:
		var goal: Vector2 = pos[_san_foe]
		if _on_bridge(goal) and not _on_bridge(pos[i]):
			goal = _bridge_mouth(pos[i], goal)   # prey fled onto a deck -> make for the mouth, then chase across
		dir += (goal - pos[i]).normalized()
	var coh: Vector2 = _san_c - pos[i]
	var cl: float = coh.length()
	if cl > SAN_PACK_R:
		dir += coh / cl * SAN_COHESION          # reel a straggler back into formation
	if dir.length() < 1e-4:
		return Vector2.ZERO
	return _avoid(i, dir.normalized()) * sp       # route around blocks instead of grinding the wall


## The Sanitation pack's shared brain: its centroid (cohesion anchor) + one shared hunt
## target -- the nearest prey to the centre, kept until it dies or a periodic re-look.
func _update_san_pack() -> void:
	_san_c = Vector2.ZERO
	var n: int = 0
	for i in count():
		if alive[i] and team[i] == SANITATION:
			_san_c += pos[i]
			n += 1
	if n == 0:
		_san_foe = -1
		return
	_san_c /= float(n)
	# Keep pursuing a live TEAM target between re-looks (stable hunt); but if we're only chewing on
	# fallback prey, re-check EVERY tick so the pack snaps onto a team the instant one is in play.
	if _san_foe != -1 and alive[_san_foe] and not extracted[_san_foe] and team[_san_foe] == SQUAD and _tick % 24 != 0:
		return
	# PRIORITY: SEARCH-AND-DESTROY THE DEPLOYED TEAMS (player + rivals). The wipe force's whole purpose
	# is to hunt the squads down -- it beelines the nearest team unit across the map and only when none
	# are left does it fall back to mopping up the nearest other prey (infected/bandits/civilians).
	_san_foe = -1
	var best: float = INF
	for j in count():
		if alive[j] and not extracted[j] and team[j] == SQUAD:
			var dd: float = _san_c.distance_squared_to(pos[j])
			if dd < best:
				best = dd
				_san_foe = j
	if _san_foe != -1:
		return
	best = INF
	for j in count():
		if alive[j] and not extracted[j] and team[j] != SANITATION:
			var dd: float = _san_c.distance_squared_to(pos[j])
			if dd < best:
				best = dd
				_san_foe = j


## A civilian steers directly away from the nearest thing that would kill it.
func _flee(i: int, sp: float) -> Vector2:
	var sight: float = STATS[kind[i]][2]
	grid.query_into(pos[i], sight, _near)
	var away: Vector2 = Vector2.ZERO
	for j in _near:
		if j == i or not alive[j] or not _targets(team[j], CIVILIAN):
			continue
		var off: Vector2 = pos[i] - pos[j]
		var dist: float = off.length()
		if dist > 1e-3 and dist < sight:
			away += off / dist * (1.0 - dist / sight)
	if away.length() > 0.0:
		if _rng.randf() < PANIC_CHANCE:
			events.append({"kind": "panic", "pos": pos[i], "to": pos[i], "team": CIVILIAN, "unit": kind[i]})
		return away.normalized() * sp
	return _wander(i, sp)                        # nothing to flee: amble naturally, don't freeze


## A slow, smoothly-curving idle drift, unique per unit and STATELESS (no RNG, no SoA
## state, so sim_test stays deterministic). Gives the idle crowd + horde organic motion
## instead of freezing in place -- the v0.19 living-world feel.
func _wander(i: int, sp: float) -> Vector2:
	var ph: float = float(i) * 1.7
	var ang: float = ph + float(_tick) * 0.010 + sin(float(_tick) * 0.005 + ph) * 2.2
	return Vector2(cos(ang), sin(ang)) * sp * WANDER_SPEED


## Sanitation pops a flash-bang: a bright thermal bloom (the 'flash' event), then
## commits to a break-contact side-step to a flank point, giving up a little ground
## to re-engage from a new angle. Returns the first step of that move.
func _pop_flash(i: int, f: int, sp: float) -> Vector2:
	flash_cd[i] = FLASH_CD
	evade[i] = EVADE_TIME
	var dir: Vector2 = (pos[f] - pos[i])
	dir /= maxf(dir.length(), 1e-5)
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
	# hard sidestep, ceding a little ground toward cover on the flank
	var flank: Vector2 = pos[i] + perp * (side * EVADE_DIST) - dir * (EVADE_DIST * 0.4)
	if _blocked(flank):
		flank = pos[i] + perp * (-side * EVADE_DIST) - dir * (EVADE_DIST * 0.4)   # try the other hand
	if _blocked(flank):
		flank = pos[i]                        # boxed in: flash in place and hold
	evade_to[i] = flank
	events.append({"kind": "flash", "pos": pos[i], "to": pos[i], "team": team[i], "unit": kind[i]})
	var run: Vector2 = flank - pos[i]
	return run / maxf(run.length(), 1e-5) * sp


## Queue a hit on `f` and log the muzzle/claw for audio. Damage is applied in
## _reap() after the loop, so a kill never depends on unit iteration order.
func _strike(i: int, f: int) -> void:
	cd[i] = STATS[kind[i]][5]
	if kind[i] == &"eod":
		# grenade / RPG: area damage on the target, hostiles only (no friendly fire
		# -- the sim auto-aims it, so it can't punish the player for the AI's throw).
		var r2: float = EOD_BLAST_R * EOD_BLAST_R
		var blast: float = EOD_BLAST_DMG * (buff_dmg[i] if buff_t[i] > 0.0 else 1.0)
		for j in count():
			if alive[j] and _hostile_units(i, j) and pos[j].distance_squared_to(pos[f]) <= r2:
				_dmg[j] = float(_dmg.get(j, 0.0)) + blast
		events.append({"kind": "blast", "pos": pos[f], "to": pos[f], "team": team[i], "unit": kind[i]})
		return
	var out: float = STATS[kind[i]][4] * (buff_dmg[i] if buff_t[i] > 0.0 else 1.0)
	_dmg[f] = float(_dmg.get(f, 0.0)) + out
	_dmg_src[f] = team[i]                        # who dealt it -- an infected kill TURNS a civilian
	# Sanitation projects fire -- a hot plume on thermal, no muzzle report. Everyone
	# else claws (infected) or fires a round (armed teams).
	var what: String = "gunfire"
	if team[i] == INFECTED:
		what = "claw"
	elif kind[i] == &"san" and _rng.randf() < SAN_FLAME_CHANCE:
		what = "flame"   # mostly it fires rounds (tracers); fire is an occasional burst
	events.append({"kind": what, "pos": pos[i], "to": pos[f], "team": team[i], "unit": kind[i]})


## Incoming damage after this unit's armor + any timed resistance (capped at 90% cut,
## so nothing is ever fully invulnerable).
func _incoming(k: int, raw: float) -> float:
	var red: float = armor[k]
	if buff_t[k] > 0.0:
		red += buff_res[k]
	return raw * (1.0 - clampf(red, 0.0, 0.9))


## --- Looted-buff grants (called by main when a building pays out) ---------------

## Hospital: instant top-up of `frac` of max HP (0..1), never past the cap.
func heal_frac(i: int, frac: float) -> void:
	if i < 0 or i >= count() or not alive[i]:
		return
	var maxhp: float = STATS[kind[i]][1]
	hp[i] = minf(maxhp, hp[i] + frac * maxhp)

## Police vests: permanent `amt` (0..1) added to this unit's damage cut.
func add_armor(i: int, amt: float) -> void:
	if i < 0 or i >= count():
		return
	armor[i] = clampf(armor[i] + amt, 0.0, 0.9)

## Timed buff: for `secs`, multiply this unit's outgoing damage by `dmg_mult` and add
## `resist` (0..1) to its incoming cut. Overwrites any running timed buff on that unit.
func grant_buff(i: int, secs: float, dmg_mult: float, resist: float) -> void:
	if i < 0 or i >= count():
		return
	buff_t[i] = secs
	buff_dmg[i] = dmg_mult
	buff_res[i] = resist

## An off-combat injury (a looted building's ambush). Applies `dmg` NOW through armor and
## runs the full death path itself -- callers outside step() can't lean on the event drain,
## so this returns true if it killed the unit and lets the caller cue the audio.
func injure(i: int, dmg: float) -> bool:
	if i < 0 or i >= count() or not alive[i]:
		return false
	hurt[i] = HURT_MEMORY
	hp[i] -= _incoming(i, dmg)
	if hp[i] > 0.0:
		return false
	hp[i] = 0.0
	alive[i] = false
	vel[i] = Vector2.ZERO
	has_order[i] = false
	selected[i] = false
	foe[i] = -1
	return true


## Apply the tick's queued damage; anything that drops dies and is logged.
func _reap() -> void:
	for k in _dmg:
		if not alive[k]:
			continue
		hurt[k] = HURT_MEMORY          # took fire: pinned for a moment (drives the flash-evade)
		hp[k] -= _incoming(k, _dmg[k])
		if hp[k] <= 0.0:
			# A civilian brought down by the INFECTED doesn't die -- it TURNS, rising as one of
			# the horde IN PLACE (index kept, no array resize), so the crowd feeds the swarm (v0.19).
			if team[k] == CIVILIAN and int(_dmg_src.get(k, -1)) == INFECTED:
				team[k] = INFECTED
				kind[k] = &"zed"
				hp[k] = STATS[&"zed"][1]
				foe[k] = -1
				has_order[k] = false
				selected[k] = false
				vel[k] = Vector2.ZERO
				events.append({"kind": "turn", "idx": k, "pos": pos[k], "team": INFECTED, "unit": &"zed"})
				continue
			alive[k] = false
			vel[k] = Vector2.ZERO
			has_order[k] = false
			selected[k] = false
			foe[k] = -1
			var kd: String = "man_down" if team[k] == SQUAD else ("zed_death" if team[k] == INFECTED else "kill")
			events.append({"kind": kd, "pos": pos[k], "team": team[k], "unit": kind[k]})


## An AC-130 fire mission on a point: everything within `radius` takes `dmg` at
## once. Friendly fire is real -- squad and civilians caught in the ring die too,
## so the optic has to be slewed off your own people first. Deaths log to events
## (audio + kill counter) exactly like combat. Call between step() and the drain.
func air_strike(center: Vector2, radius: float, dmg: float) -> void:
	events.append({"kind": "strike", "pos": center, "team": -1, "unit": &"ac130"})
	var r2: float = radius * radius
	for i in count():
		if not alive[i] or pos[i].distance_squared_to(center) > r2:
			continue
		hp[i] -= _incoming(i, dmg)
		if hp[i] <= 0.0:
			alive[i] = false
			vel[i] = Vector2.ZERO
			has_order[i] = false
			selected[i] = false
			foe[i] = -1
			# A civilian caught in YOUR ring is collateral (scored against you); the same
			# civilian eaten by the horde is just the apocalypse (a plain 'kill' in _reap).
			var kd: String = "man_down"
			if team[i] == INFECTED:
				kd = "zed_death"
			elif team[i] == CIVILIAN:
				kd = "collateral"
			elif team[i] != SQUAD:
				kd = "kill"
			events.append({"kind": kd, "pos": pos[i], "team": team[i], "unit": kind[i]})


## Line of sight on the ground plane: no building blocks the segment a->b. O(buildings)
## with a cheap bbox reject; buildings are few and this is only asked on a fresh
## acquire or a shot, never every unit every tick.
func _los(a: Vector2, b: Vector2) -> bool:
	var lo: Vector2 = a.min(b)
	var hi: Vector2 = a.max(b)
	for r in buildings:
		if r.position.x > hi.x or r.end.x < lo.x or r.position.y > hi.y or r.end.y < lo.y:
			continue
		if _seg_hits_rect(a, b, r):
			return false
	return true


## Seed the map with the ambient population + the hostile elements, scattered on
## walkable ground (rejected out of buildings). Call after load_buildings and the
## squad spawn. seed_value < 0 => randomize (different scatter every play).
func populate(n_infected: int, n_civ: int, n_san: int, region: Rect2 = Rect2(), seed_value: int = -1) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	if seed_value < 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	var reg: Rect2 = region if region.has_area() else Rect2(_bounds_lo, _bounds_hi - _bounds_lo)
	_scatter(&"zed", INFECTED, n_infected, rng, reg)
	_scatter(&"civ", CIVILIAN, n_civ, rng, reg)
	_scatter(&"san", SANITATION, n_san, rng, reg)


## n of a kind dropped on clear ground (no building, no water) inside `region`.
func scatter(unit_kind: StringName, team_id: int, n: int, region: Rect2, rng: RandomNumberGenerator) -> void:
	_scatter(unit_kind, team_id, n, rng, region)


## A knot of units around a centre -- bandit crews, survivor holdouts.
func spawn_cluster(unit_kind: StringName, team_id: int, centre: Vector2, n: int, spread: float, rng: RandomNumberGenerator) -> void:
	var placed: int = 0
	var tries: int = 0
	while placed < n and tries < n * 40:
		tries += 1
		var p: Vector2 = centre + Vector2(rng.randf_range(-spread, spread), rng.randf_range(-spread, spread))
		if _blocked(p):
			continue
		spawn(p, unit_kind, team_id)
		placed += 1


## Fill a rect densely -- a bridge deck packed with the horde (the gauntlet).
func spawn_line(unit_kind: StringName, team_id: int, rect: Rect2, n: int, rng: RandomNumberGenerator) -> void:
	for _i in n:
		var p: Vector2 = Vector2(
			rng.randf_range(rect.position.x, rect.end.x),
			rng.randf_range(rect.position.y, rect.end.y))
		spawn(p, unit_kind, team_id)


func _scatter(unit_kind: StringName, team_id: int, n: int, rng: RandomNumberGenerator, region: Rect2) -> void:
	var placed: int = 0
	var tries: int = 0
	while placed < n and tries < n * 40:
		tries += 1
		var p: Vector2 = Vector2(
			rng.randf_range(region.position.x, region.end.x),
			rng.randf_range(region.position.y, region.end.y))
		if _blocked(p):
			continue
		spawn(p, unit_kind, team_id)
		placed += 1


## Ground a unit can't stand on: inside a building, in the water, or off the coast.
func _blocked(p: Vector2) -> bool:
	for bi in bgrid.at(p):
		if buildings[bi].has_point(p):
			return true
	for w in water:
		if w.has_point(p):
			return true
	if not land_poly.is_empty() and not _on_bridge(p) and not Geometry2D.is_point_in_polygon(p, land_poly):
		return true
	return false


## Medics top up nearby allies -- same faction, within reach, up to the ally's max.
func _heal(dt: float) -> void:
	for i in count():
		if not alive[i] or kind[i] != &"med":
			continue
		grid.query_into(pos[i], HEAL_RANGE, _near)
		for j in _near:
			if j == i or not alive[j] or team[j] != team[i]:
				continue
			var maxhp: float = STATS[kind[j]][1]
			if hp[j] < maxhp:
				hp[j] = minf(maxhp, hp[j] + HEAL_RATE * dt)


## Segment [a,b] vs an axis-aligned rect, by slab-clipping the parameter range.
func _seg_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d: Vector2 = b - a
	var tmin: float = 0.0
	var tmax: float = 1.0
	for axis in 2:
		var da: float = d[axis]
		var r0: float = r.position[axis]
		var r1: float = r.end[axis]
		if absf(da) < 1e-9:
			if a[axis] < r0 or a[axis] > r1:
				return false
		else:
			var t1: float = (r0 - a[axis]) / da
			var t2: float = (r1 - a[axis]) / da
			if t1 > t2:
				var tmp: float = t1
				t1 = t2
				t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return false
	return true
