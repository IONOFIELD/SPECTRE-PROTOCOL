class_name RectGrid
extends RefCounted

## Static broadphase for buildings. Built once after CityGen, never touched again.
## Without it, collision was 300 units x 120 buildings x 60 Hz = 2.2 M Rect2
## overlap tests per second, for a unit that is nowhere near a wall.

var cell: float = 24.0
var _ox: float = 0.0
var _oy: float = 0.0
var _nx: int = 1
var _ny: int = 1
var _buckets: Array = [PackedInt32Array()]   # a no-buildings map must still answer at()


## `margin` must be at least the radius of whatever will be collided against,
## because callers resolve against rect.grow(radius). Bucket by the raw rect and
## a unit hugging a wall can land in a cell that rect never touched.
func build(rects: Array[Rect2], cell_size: float = 24.0, margin: float = 0.5) -> void:
	cell = cell_size
	if rects.is_empty():
		_nx = 1
		_ny = 1
		_buckets = [PackedInt32Array()]
		return
	var lo: Vector2 = rects[0].position
	var hi: Vector2 = rects[0].end
	for r in rects:
		lo = lo.min(r.position)
		hi = hi.max(r.end)
	lo -= Vector2(cell + margin, cell + margin)
	hi += Vector2(cell + margin, cell + margin)
	_ox = lo.x
	_oy = lo.y
	_nx = maxi(1, int(ceil((hi.x - lo.x) / cell)))
	_ny = maxi(1, int(ceil((hi.y - lo.y) / cell)))
	_buckets.resize(_nx * _ny)
	for i in _nx * _ny:
		_buckets[i] = PackedInt32Array()
	for i in rects.size():
		var r: Rect2 = rects[i].grow(margin)
		var x0: int = _cx(r.position.x)
		var x1: int = _cx(r.end.x)
		var y0: int = _cy(r.position.y)
		var y1: int = _cy(r.end.y)
		for cy in range(y0, y1 + 1):
			for cx in range(x0, x1 + 1):
				var b: PackedInt32Array = _buckets[cy * _nx + cx]
				b.append(i)
				_buckets[cy * _nx + cx] = b


func _cx(x: float) -> int:
	return clampi(int(floor((x - _ox) / cell)), 0, _nx - 1)


func _cy(y: float) -> int:
	return clampi(int(floor((y - _oy) / cell)), 0, _ny - 1)


func at(p: Vector2) -> PackedInt32Array:
	return _buckets[_cy(p.y) * _nx + _cx(p.x)]
