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

# type: [speed m/s, hp, sight m, weapon range m]
const STATS: Dictionary = {
	&"cbt": [2.6, 100.0, 80.0, 67.0],
	&"rec": [4.2, 70.0, 133.0, 52.0],
	&"snp": [2.3, 80.0, 129.0, 138.0],
	&"eod": [2.5, 130.0, 73.0, 67.0],
	&"med": [2.9, 90.0, 77.0, 39.0],
	&"cdr": [2.8, 120.0, 129.0, 67.0],
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


func spawn(p: Vector2, t: StringName, tm: int = 0) -> int:
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


	for i in count():
		if not alive[i]:
			continue
		var sp: float = speed_of(i)
		var desired: Vector2 = Vector2.ZERO

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
