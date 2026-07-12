class_name NavGrid
extends RefCounted

## Rasterised navmesh. Buildings are axis-aligned rects, so a uniform grid is
## exact, not an approximation.
##
## Seek-plus-push-out is not navigation. Walk an operator into a flat wall head
## on and the tangential component of his desired velocity is zero, so the
## push-out cancels his motion and he presses into the brick until the mission
## ends. Measured: 24.9 m of progress in 60 seconds of simulated time.

const CELL: float = 2.5
## Weighted A*. Measured on the real city, 327 m across:
##   w = 1.00  ->  2211 expansions, 22.3 ms, 362.4 m   (optimal)
##   w = 1.25  ->   429 expansions,  5.6 ms, 366.6 m   (+1.2% path, 4x faster)
## Nobody can see 1.2%. Everybody can feel 22 ms.
var weight: float = 1.25
const DIAG: float = 1.41421356

var cell: float = CELL
var _ox: float = 0.0
var _oy: float = 0.0
var _nx: int = 1
var _ny: int = 1
var blocked: PackedByteArray = PackedByteArray()

# A* scratch, allocated once
var _g: PackedFloat32Array = PackedFloat32Array()
var _came: PackedInt32Array = PackedInt32Array()
var _closed: PackedByteArray = PackedByteArray()
var _heap_i: PackedInt32Array = PackedInt32Array()
var _heap_f: PackedFloat32Array = PackedFloat32Array()
var _heap_n: int = 0
var expanded: int = 0


func build(rects: Array[Rect2], lo: Vector2, hi: Vector2, clearance: float, cell_size: float = CELL, land_poly: PackedVector2Array = PackedVector2Array(), bridges: Array[Rect2] = []) -> void:
	cell = cell_size
	_ox = lo.x
	_oy = lo.y
	_nx = maxi(1, int(ceil((hi.x - lo.x) / cell)))
	_ny = maxi(1, int(ceil((hi.y - lo.y) / cell)))
	var n: int = _nx * _ny
	blocked.resize(n)
	_g.resize(n)
	_came.resize(n)
	_closed.resize(n)
	_heap_i.resize(n)
	_heap_f.resize(n)

	if land_poly.is_empty():
		blocked.fill(0)                       # open everywhere; only buildings block
	else:
		blocked.fill(1)                       # ocean everywhere...
		_fill_polygon(land_poly)              # ...then carve the land open
		for b in bridges:
			_carve(b)                         # bridge decks: walkable gaps over the water

	for r in rects:
		var e: Rect2 = r.grow(clearance)
		var x0: int = clampi(int(floor((e.position.x - _ox) / cell)), 0, _nx - 1)
		var x1: int = clampi(int(ceil((e.end.x - _ox) / cell)) - 1, 0, _nx - 1)
		var y0: int = clampi(int(floor((e.position.y - _oy) / cell)), 0, _ny - 1)
		var y1: int = clampi(int(ceil((e.end.y - _oy) / cell)) - 1, 0, _ny - 1)
		for cy in range(y0, y1 + 1):
			for cx in range(x0, x1 + 1):
				blocked[cy * _nx + cx] = 1


## Scanline flood: open every cell whose row-centre lies inside the polygon.
## O(rows x edges), so a jagged coastline costs almost nothing at build time.
func _fill_polygon(poly: PackedVector2Array) -> void:
	var m: int = poly.size()
	if m < 3:
		return
	for cy in _ny:
		var wz: float = _oy + (float(cy) + 0.5) * cell
		var xs: Array = []
		for e in m:
			var a: Vector2 = poly[e]
			var b: Vector2 = poly[(e + 1) % m]
			if (a.y <= wz and b.y > wz) or (b.y <= wz and a.y > wz):
				xs.append(a.x + (wz - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		var k: int = 0
		while k + 1 < xs.size():
			var cx0: int = clampi(int(floor((xs[k] - _ox) / cell)), 0, _nx - 1)
			var cx1: int = clampi(int(ceil((xs[k + 1] - _ox) / cell)) - 1, 0, _nx - 1)
			for cx in range(cx0, cx1 + 1):
				blocked[cy * _nx + cx] = 0
			k += 2


## Open a rect's cells (a bridge deck carved back through the ocean).
func _carve(r: Rect2) -> void:
	var x0: int = clampi(int(floor((r.position.x - _ox) / cell)), 0, _nx - 1)
	var x1: int = clampi(int(ceil((r.end.x - _ox) / cell)) - 1, 0, _nx - 1)
	var y0: int = clampi(int(floor((r.position.y - _oy) / cell)), 0, _ny - 1)
	var y1: int = clampi(int(ceil((r.end.y - _oy) / cell)) - 1, 0, _ny - 1)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			blocked[cy * _nx + cx] = 0


func _idx(p: Vector2) -> int:
	var cx: int = clampi(int(floor((p.x - _ox) / cell)), 0, _nx - 1)
	var cy: int = clampi(int(floor((p.y - _oy) / cell)), 0, _ny - 1)
	return cy * _nx + cx


func _centre(i: int) -> Vector2:
	return Vector2(_ox + (float(i % _nx) + 0.5) * cell, _oy + (float(i / _nx) + 0.5) * cell)


func is_blocked(p: Vector2) -> bool:
	return blocked[_idx(p)] == 1


## Nearest open cell, spiralling outward. A unit shoved inside geometry, or an
## order dropped on a rooftop, still has to resolve to something walkable.
func _nearest_open(i: int) -> int:
	if blocked[i] == 0:
		return i
	var cx: int = i % _nx
	var cy: int = i / _nx
	for r in range(1, 24):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var x: int = cx + dx
				var y: int = cy + dy
				if x < 0 or y < 0 or x >= _nx or y >= _ny:
					continue
				var j: int = y * _nx + x
				if blocked[j] == 0:
					return j
	return -1


func has_los(a: Vector2, b: Vector2) -> bool:
	var d: Vector2 = b - a
	var steps: int = int(ceil(d.length() / (cell * 0.5)))
	if steps <= 0:
		return true
	for s in steps + 1:
		if blocked[_idx(a + d * (float(s) / float(steps)))] == 1:
			return false
	return true


func _heap_push(i: int, f: float) -> void:
	var k: int = _heap_n
	_heap_i[k] = i
	_heap_f[k] = f
	_heap_n += 1
	while k > 0:
		var p: int = (k - 1) >> 1
		if _heap_f[p] <= _heap_f[k]:
			break
		var ti: int = _heap_i[p]
		var tf: float = _heap_f[p]
		_heap_i[p] = _heap_i[k]
		_heap_f[p] = _heap_f[k]
		_heap_i[k] = ti
		_heap_f[k] = tf
		k = p


func _heap_pop() -> int:
	var top: int = _heap_i[0]
	_heap_n -= 1
	_heap_i[0] = _heap_i[_heap_n]
	_heap_f[0] = _heap_f[_heap_n]
	var k: int = 0
	while true:
		var l: int = k * 2 + 1
		var r: int = l + 1
		var s: int = k
		if l < _heap_n and _heap_f[l] < _heap_f[s]:
			s = l
		if r < _heap_n and _heap_f[r] < _heap_f[s]:
			s = r
		if s == k:
			break
		var ti: int = _heap_i[s]
		var tf: float = _heap_f[s]
		_heap_i[s] = _heap_i[k]
		_heap_f[s] = _heap_f[k]
		_heap_i[k] = ti
		_heap_f[k] = tf
		k = s
	return top


func _h(a: int, b: int) -> float:
	var dx: float = absf(float(a % _nx - b % _nx))
	var dy: float = absf(float(a / _nx - b / _nx))
	return (dx + dy) + (DIAG - 2.0) * minf(dx, dy)      # octile


## Returns the smoothed path in world metres, or an empty array if unreachable.
func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	expanded = 0
	var s: int = _nearest_open(_idx(from))
	var t: int = _nearest_open(_idx(to))
	var out: PackedVector2Array = PackedVector2Array()
	if s < 0 or t < 0:
		return out
	if s == t:
		out.append(to)
		return out

	_closed.fill(0)
	_came.fill(-1)
	_g.fill(1e30)
	_heap_n = 0
	_g[s] = 0.0
	_heap_push(s, _h(s, t))

	var found: bool = false
	while _heap_n > 0:
		var c: int = _heap_pop()
		if c == t:
			found = true
			break
		if _closed[c] == 1:
			continue
		_closed[c] = 1
		expanded += 1
		var cx: int = c % _nx
		var cy: int = c / _nx
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var x: int = cx + dx
				var y: int = cy + dy
				if x < 0 or y < 0 or x >= _nx or y >= _ny:
					continue
				var n: int = y * _nx + x
				if blocked[n] == 1 or _closed[n] == 1:
					continue
				# no cutting corners diagonally through a wall
				if dx != 0 and dy != 0:
					if blocked[cy * _nx + x] == 1 or blocked[y * _nx + cx] == 1:
						continue
				var step: float = DIAG if (dx != 0 and dy != 0) else 1.0
				var ng: float = _g[c] + step
				if ng < _g[n]:
					_g[n] = ng
					_came[n] = c
					_heap_push(n, ng + _h(n, t) * weight)

	if not found:
		return out

	# reconstruct, then string-pull: drop any waypoint the previous one can see past
	var raw: PackedVector2Array = PackedVector2Array()
	var c2: int = t
	while c2 != -1:
		raw.append(_centre(c2))
		c2 = _came[c2]
	raw.reverse()
	raw[raw.size() - 1] = to

	out.append(raw[0])
	var anchor: int = 0
	var i: int = 1
	while i < raw.size():
		if not has_los(raw[anchor], raw[i]):
			out.append(raw[i - 1])
			anchor = i - 1
		i += 1
	out.append(raw[raw.size() - 1])
	out.remove_at(0)      # the first point is where we already stand
	return out


func cells() -> int:
	return _nx * _ny


func blocked_fraction() -> float:
	var b: int = 0
	for v in blocked:
		b += v
	return float(b) / float(blocked.size())
