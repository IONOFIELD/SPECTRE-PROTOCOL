class_name SpatialGrid
extends RefCounted

## Counting-sort uniform grid. Rebuilt every tick, allocation free after setup.
##
## The Dictionary version was correct and slow: hashing a Vector2i per insert,
## a fresh PackedInt32Array per query, 3.9 ms/tick at 300 units. This one sorts
## ids into a flat bucket array with a prefix sum, and queries write into a
## caller-owned buffer. No allocation in the hot loop.
##
## Cell size wants to match the query you make most often. That is separation
## (0.9 m), not weapon range. Long-range queries touch more cells and that is
## the correct trade: they are rare and they can afford it.

var cell: float = 2.5
var _ox: float = 0.0
var _oy: float = 0.0
var _nx: int = 1
var _ny: int = 1

var _starts: PackedInt32Array = PackedInt32Array()   # size nx*ny + 1
var _ids: PackedInt32Array = PackedInt32Array()
var _cell_of: PackedInt32Array = PackedInt32Array()


func setup(min_corner: Vector2, max_corner: Vector2, cell_size: float) -> void:
	cell = cell_size
	_ox = min_corner.x
	_oy = min_corner.y
	_nx = maxi(1, int(ceil((max_corner.x - min_corner.x) / cell)))
	_ny = maxi(1, int(ceil((max_corner.y - min_corner.y) / cell)))
	_starts.resize(_nx * _ny + 1)


func _cx(x: float) -> int:
	return clampi(int(floor((x - _ox) / cell)), 0, _nx - 1)


func _cy(y: float) -> int:
	return clampi(int(floor((y - _oy) / cell)), 0, _ny - 1)


func rebuild(pos: Array[Vector2], alive: Array[bool]) -> void:
	var n: int = pos.size()
	if _cell_of.size() != n:
		_cell_of.resize(n)
	var live: int = 0
	for i in n:
		if alive[i]:
			_cell_of[i] = _cy(pos[i].y) * _nx + _cx(pos[i].x)
			live += 1
		else:
			_cell_of[i] = -1

	var nc: int = _nx * _ny
	_starts.fill(0)                       # native memset, not an nc-long GDScript loop
	for i in n:
		if _cell_of[i] >= 0:
			_starts[_cell_of[i] + 1] += 1
	for c in nc:
		_starts[c + 1] += _starts[c]

	if _ids.size() != live:
		_ids.resize(live)
	# Place using _starts as the cursor. It ends up shifted left by one cell,
	# so afterwards: start(c) = c == 0 ? 0 : _starts[c - 1], end(c) = _starts[c].
	# No duplicate(), no second array, no allocation.
	for i in n:
		var c: int = _cell_of[i]
		if c >= 0:
			_ids[_starts[c]] = i
			_starts[c] += 1


## Appends candidate ids to `out` and returns how many. `out` is the caller's
## buffer; this never allocates. Candidates are a superset: the caller still
## checks true distance.
func query_into(p: Vector2, radius: float, out: PackedInt32Array) -> int:
	out.clear()
	var x0: int = _cx(p.x - radius)
	var x1: int = _cx(p.x + radius)
	var y0: int = _cy(p.y - radius)
	var y1: int = _cy(p.y + radius)
	var cy: int = y0
	while cy <= y1:
		var row: int = cy * _nx
		var cx: int = x0
		while cx <= x1:
			var c: int = row + cx
			var k: int = 0 if c == 0 else _starts[c - 1]
			var e: int = _starts[c]
			while k < e:
				out.append(_ids[k])
				k += 1
			cx += 1
		cy += 1
	return out.size()


func query(p: Vector2, radius: float) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	query_into(p, radius, out)
	return out


func cell_count() -> int:
	return _nx * _ny
