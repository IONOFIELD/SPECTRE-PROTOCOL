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
const ARRIVE: float = 0.6             # slow down inside this, stop inside RADIUS
const WAYPOINT: float = 1.1           # corner-cutting tolerance on intermediate nodes
const MAX_PUSH: float = 2.4           # m/s of separation velocity, capped
const CELL: float = 12.0              # measured knee: rebuild cost falls with cell size,
                                      # query cost is flat (call overhead dominates candidates).
const HEAL_RANGE: float = 9.0
const HEAL_RATE: float = 14.0         # hp/s a medic restores to nearby allies

# teams. Civilians never fight (they run); everyone else is hostile across team
# lines. Infected hunt every warm body; the Sanitation Force clears the lot.
enum { SQUAD = 0, INFECTED = 1, CIVILIAN = 2, SANITATION = 3 }

# type: [speed m/s, hp, sight m, range m, damage, interval s]. Range is a rifle
# reach for shooters and a claw reach for the infected; interval is the seconds
# between a unit's shots or strikes.
const STATS: Dictionary = {
	&"cbt": [2.6, 100.0, 80.0, 67.0, 20.0, 0.5],
	&"rec": [4.2, 70.0, 133.0, 52.0, 14.0, 0.4],
	&"snp": [2.3, 80.0, 129.0, 138.0, 65.0, 1.8],
	&"eod": [2.5, 130.0, 73.0, 67.0, 30.0, 0.9],
	&"med": [2.9, 90.0, 77.0, 39.0, 12.0, 0.5],
	&"cdr": [2.8, 120.0, 129.0, 67.0, 22.0, 0.55],
	&"zed": [1.4, 55.0, 40.0, 1.4, 11.0, 1.1],      # infected: slow, melee, near-ambient
	&"civ": [2.2, 20.0, 30.0, 0.0, 0.0, 0.0],       # civilian: unarmed, runs
	&"san": [3.4, 150.0, 95.0, 60.0, 24.0, 0.6],    # Sanitation Force: fast, armoured, ranged
}

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

## Combat discipline + output. weapons_free gates squad auto-fire (the hold-fire /
## open-fire toggle). events is the per-tick log main drains for positional audio:
## [{kind, pos, team, unit}]. Both cleared at the top of every step().
var weapons_free: bool = true
var events: Array = []
var _dmg: Dictionary = {}             # target index -> damage queued this tick
var _tick: int = 0

var buildings: Array[Rect2] = []      # ground-plane AABBs, metres
var nav: NavGrid = NavGrid.new()
var path: Array[PackedVector2Array] = []
var path_i: Array[int] = []
var grid: SpatialGrid = SpatialGrid.new()
var bgrid: RectGrid = RectGrid.new()
var _near: PackedInt32Array = PackedInt32Array()   # reused every unit, every tick
var _bounds_lo: Vector2 = Vector2(-64, -64)
var _bounds_hi: Vector2 = Vector2(640, 640)


func set_bounds(lo: Vector2, hi: Vector2) -> void:
	_bounds_lo = lo
	_bounds_hi = hi
	grid.setup(lo, hi, CELL)


func _init() -> void:
	grid.setup(_bounds_lo, _bounds_hi, CELL)


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
	return pos.size() - 1


func speed_of(i: int) -> float:
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
	# Two passes. Pushing out of one building can push you into its neighbour,
	# and the second bucket lookup is a few nanoseconds.
	for _pass in 2:
		var moved: bool = false
		for bi in bgrid.at(p):
			var e: Rect2 = buildings[bi].grow(r)
			if not e.has_point(p):
				continue
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
			moved = true
		if not moved:
			break
	return p


func step(dt: float) -> void:
	grid.rebuild(pos, alive)
	events.clear()
	_dmg.clear()
	_tick += 1

	for i in count():
		if not alive[i]:
			continue
		var sp: float = speed_of(i)
		cd[i] = maxf(0.0, cd[i] - dt)
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

		# separation. Query the grid, not the whole array.
		var push: Vector2 = Vector2.ZERO
		grid.query_into(pos[i], SEPARATION, _near)
		for j in _near:
			if j == i or not alive[j]:
				continue
			var off: Vector2 = pos[i] - pos[j]
			var dist: float = off.length()
			if dist > SEPARATION or dist < 1e-5:
				continue
			push += off / dist * (1.0 - dist / SEPARATION)
		if push.length() > 0.0:
			desired += push.normalized() * minf(push.length() * sp, MAX_PUSH)

		vel[i] = vel[i].lerp(desired, minf(1.0, dt * 10.0))
		var np: Vector2 = pos[i] + vel[i] * dt
		np = _resolve_buildings(np, RADIUS)
		pos[i] = np

		if vel[i].length_squared() > 0.04:
			heading[i] = atan2(vel[i].x, vel[i].y)

	_reap()
	_heal(dt)


func moving(i: int) -> bool:
	return vel[i].length_squared() > 0.04


## Anything the sim needs to know about the map. Called once, after CityGen.
func load_buildings(rects: Array[Rect2]) -> void:
	buildings = rects
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


# ---- combat ----------------------------------------------------------------

## Does team `a` shoot/claw team `b`? Civilians fight no one. Infected hunt every
## non-infected; the Sanitation Force clears everyone but itself; the squad
## engages infected + sanitation.
func _targets(a: int, b: int) -> bool:
	if a == b:
		return false
	match a:
		SQUAD:
			return b == INFECTED or b == SANITATION
		INFECTED:
			return b != INFECTED
		SANITATION:
			return b != SANITATION
	return false


## Refresh foe[i]: keep a live target still in sight, else acquire the nearest
## hostile with a clear line. Civilians never acquire -- they only flee.
func _acquire(i: int) -> void:
	var t: int = team[i]
	if t == CIVILIAN:
		foe[i] = -1
		return
	# Infected + Sanitation HUNT: they sense the nearest warm body anywhere on the
	# map, no line of sight -- the horde closes on you rather than standing idle.
	# The scan is O(n) but staggered (see step), so it costs a fraction of a tick.
	if t == INFECTED or t == SANITATION:
		var best: int = -1
		var bestd: float = INF
		for j in count():
			if j == i or not alive[j] or not _targets(t, team[j]):
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
		if j == i or not alive[j] or not _targets(team[i], team[j]):
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
	var f: int = foe[i]
	if f == -1 or not alive[f]:
		return Vector2.ZERO
	var d: float = pos[i].distance_to(pos[f])
	var reach: float = STATS[kind[i]][3]
	if t == INFECTED:
		if d <= reach:
			if cd[i] <= 0.0:
				_strike(i, f)
			return Vector2.ZERO
		return (pos[f] - pos[i]) / maxf(d, 1e-5) * sp
	# shooters: squad + sanitation. Fire in range with a clear line.
	if d <= reach and _los(pos[i], pos[f]):
		if cd[i] <= 0.0 and (t == SANITATION or weapons_free):
			_strike(i, f)
		return Vector2.ZERO          # in range: stand and shoot (squad also holds; orders move it)
	if t == SANITATION:
		return (pos[f] - pos[i]) / maxf(d, 1e-5) * sp   # out of range: close in
	return Vector2.ZERO              # squad out of range: hold (the player orders it forward)


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
		return away.normalized() * sp
	return Vector2.ZERO


## Queue a hit on `f` and log the muzzle/claw for audio. Damage is applied in
## _reap() after the loop, so a kill never depends on unit iteration order.
func _strike(i: int, f: int) -> void:
	cd[i] = STATS[kind[i]][5]
	_dmg[f] = float(_dmg.get(f, 0.0)) + STATS[kind[i]][4]
	var what: String = "claw" if team[i] == INFECTED else "gunfire"
	events.append({"kind": what, "pos": pos[i], "team": team[i], "unit": kind[i]})


## Apply the tick's queued damage; anything that drops dies and is logged.
func _reap() -> void:
	for k in _dmg:
		if not alive[k]:
			continue
		hp[k] -= _dmg[k]
		if hp[k] <= 0.0:
			alive[k] = false
			vel[k] = Vector2.ZERO
			has_order[k] = false
			selected[k] = false
			foe[k] = -1
			var kd: String = "man_down" if team[k] == SQUAD else ("zed_death" if team[k] == INFECTED else "kill")
			events.append({"kind": kd, "pos": pos[k], "team": team[k], "unit": kind[k]})


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
func populate(n_infected: int, n_civ: int, n_san: int, seed_value: int = -1) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	if seed_value < 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	_scatter(&"zed", INFECTED, n_infected, rng)
	_scatter(&"civ", CIVILIAN, n_civ, rng)
	_scatter(&"san", SANITATION, n_san, rng)


func _scatter(unit_kind: StringName, team_id: int, n: int, rng: RandomNumberGenerator) -> void:
	var placed: int = 0
	var tries: int = 0
	while placed < n and tries < n * 40:
		tries += 1
		var p: Vector2 = Vector2(
			rng.randf_range(_bounds_lo.x, _bounds_hi.x),
			rng.randf_range(_bounds_lo.y, _bounds_hi.y))
		var blocked: bool = false
		for bi in bgrid.at(p):
			if buildings[bi].has_point(p):
				blocked = true
				break
		if blocked:
			continue
		spawn(p, unit_kind, team_id)
		placed += 1


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
