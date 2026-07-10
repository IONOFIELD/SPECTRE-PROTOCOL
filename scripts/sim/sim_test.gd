extends SceneTree

## godot --headless --path . --script res://scripts/sim/sim_test.gd
## Exits non-zero on any failure so this can gate a commit.

var failures: int = 0


func check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  PASS  ", name, ("  " + detail) if detail != "" else "")
	else:
		failures += 1
		print("  FAIL  ", name, "  ", detail)


func _initialize() -> void:
	print("=== SPECTRE sim tests ===")
	test_grid_is_superset()
	test_no_unit_ends_inside_a_building()
	test_units_reach_their_order()
	test_separation_holds()
	test_tunnelling_bound()
	test_rig_joints_bend_like_a_human()
	test_navigation_beats_a_wall()
	test_combat_resolves()
	test_civilian_flees()
	perf()
	print("=== %d failure(s) ===" % failures)
	quit(1 if failures > 0 else 0)


func _rand_sim(n: int, rng: RandomNumberGenerator) -> WorldSim:
	var s: WorldSim = WorldSim.new()
	for i in n:
		s.spawn(Vector2(rng.randf_range(0, 200), rng.randf_range(0, 200)), &"cbt")
	return s


## The grid may return extra ids. It may never MISS one that is truly in range.
func test_grid_is_superset() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 4
	var s: WorldSim = _rand_sim(400, rng)
	s.set_bounds(Vector2(-20, -20), Vector2(220, 220))
	s.grid.rebuild(s.pos, s.alive)
	var misses: int = 0
	var extra_ratio: float = 0.0
	var trials: int = 60
	for t in trials:
		var p: Vector2 = Vector2(rng.randf_range(0, 200), rng.randf_range(0, 200))
		var r: float = rng.randf_range(1.0, 25.0)
		var truth: Array = []
		for i in s.count():
			if s.pos[i].distance_to(p) <= r:
				truth.append(i)
		var got: PackedInt32Array = s.grid.query(p, r)
		for i in truth:
			if not got.has(i):
				misses += 1
		extra_ratio += float(got.size()) / maxf(1.0, float(truth.size()))
	check("grid never misses a true neighbour", misses == 0, "misses=%d" % misses)

	# The number that matters is overdraw at the radius the hot loop uses, not
	# at a uniformly random radius. Separation is queried once per unit per tick.
	var cand: float = 0.0
	for i in s.count():
		cand += float(s.grid.query(s.pos[i], WorldSim.SEPARATION).size())
	cand /= float(s.count())
	check("separation query stays cheap", cand < 8.0,
			"%.2f candidates per unit at r=%.2f m" % [cand, WorldSim.SEPARATION])


func test_no_unit_ends_inside_a_building() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 9
	var s: WorldSim = WorldSim.new()
	var rects: Array[Rect2] = []
	for i in 24:
		rects.append(Rect2(rng.randf_range(10, 180), rng.randf_range(10, 180),
				rng.randf_range(8, 24), rng.randf_range(8, 24)))
	s.load_buildings(rects)

	var ids: Array = []
	for i in 60:
		ids.append(s.spawn(Vector2(rng.randf_range(0, 200), rng.randf_range(0, 200)), &"rec"))
	# order everyone straight across the map so they must plough through buildings
	for i in ids:
		s.target[i] = Vector2(200, 200) - s.pos[i]
		s.has_order[i] = true

	var worst: float = 0.0
	for tick in 1200:
		s.step(1.0 / 60.0)
		for i in ids:
			for b in rects:
				var e: Rect2 = b.grow(WorldSim.RADIUS - 0.001)
				if e.has_point(s.pos[i]):
					var pen: float = minf(
						minf(s.pos[i].x - e.position.x, e.end.x - s.pos[i].x),
						minf(s.pos[i].y - e.position.y, e.end.y - s.pos[i].y))
					worst = maxf(worst, pen)
	check("no unit ends a tick inside a building", worst < 1e-3, "worst penetration = %.6f m" % worst)


func test_units_reach_their_order() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-20, -20), Vector2(120, 120))
	var ids: Array = []
	for i in 4:
		ids.append(s.spawn(Vector2(10 + i * 1.2, 10), &"cbt"))
	s.order_move(ids, Vector2(60, 45))
	var ticks: int = 0
	while ticks < 3600:
		s.step(1.0 / 60.0)
		ticks += 1
		var done: bool = true
		for i in ids:
			if s.has_order[i]:
				done = false
		if done:
			break
	var worst: float = 0.0
	for i in ids:
		worst = maxf(worst, s.pos[i].distance_to(Vector2(60, 45)))
	# straight-line distance is 60.2 m at 2.6 m/s -> 23.1 s -> 1390 ticks
	check("squad completes a move order", ticks < 3600, "%d ticks (%.1f s)" % [ticks, ticks / 60.0])
	check("squad lands on the objective", worst < 4.0, "furthest operator %.2f m from the mark" % worst)


func test_separation_holds() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(0, 0), Vector2(80, 80))
	var ids: Array = []
	for i in 12:
		ids.append(s.spawn(Vector2(30.0 + randf() * 0.05, 30.0 + randf() * 0.05), &"cbt"))
	for t in 600:
		s.step(1.0 / 60.0)
	var closest: float = 1e9
	for a in ids:
		for b in ids:
			if a < b:
				closest = minf(closest, s.pos[a].distance_to(s.pos[b]))
	check("stacked spawns push apart", closest > WorldSim.RADIUS,
			"closest pair %.3f m (footprint %.2f)" % [closest, WorldSim.RADIUS])


## Collision is a push-out, not a swept test, so a tick must never move a unit
## further than the thinnest wall. Prove the margin rather than assume it.
func test_tunnelling_bound() -> void:
	var fastest: float = 0.0
	for t in WorldSim.STATS.keys():
		fastest = maxf(fastest, WorldSim.STATS[t][0])
	var step_m: float = (fastest + WorldSim.MAX_PUSH) / 60.0
	check("tick displacement is well under a wall", step_m < 0.5,
			"%.3f m/tick at %.1f m/s + %.1f m/s push" % [step_m, fastest, WorldSim.MAX_PUSH])


func test_navigation_beats_a_wall() -> void:
	var city: CityGen = CityGen.new()
	city.generate(Vector2i(640, 360))
	var rects: Array[Rect2] = city.building_rects()
	var s: WorldSim = WorldSim.new()
	s.load_buildings(rects)

	var ids: Array = []
	for i in 6:
		ids.append(s.spawn(Vector2(70.0 + float(i % 3) * 1.4, 68.0 + float(i / 3) * 1.4), &"cbt"))
	var goal: Vector2 = Vector2(300, 300)
	var t0: int = Time.get_ticks_usec()
	s.order_move(ids, goal)
	var order_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	check("a squad order costs one A*", order_ms < 12.0, "%.2f ms for 6 operators" % order_ms)

	var ticks: int = 0
	while ticks < 15000:
		s.step(1.0 / 60.0)
		ticks += 1
		var done: bool = true
		for i in ids:
			if s.has_order[i]:
				done = false
		if done:
			break
	var worst: float = 0.0
	for i in ids:
		worst = maxf(worst, s.pos[i].distance_to(goal))
	check("squad crosses the city", worst < 5.0,
			"%.1f s to cross 327 m, furthest %.2f m from the mark" % [ticks / 60.0, worst])

	var inside: int = 0
	for i in ids:
		for r in rects:
			if r.grow(WorldSim.RADIUS - 0.01).has_point(s.pos[i]):
				inside += 1
	check("nobody finished inside a building", inside == 0, "%d intersections" % inside)

	var unreachable: PackedVector2Array = s.nav.find_path(Vector2(70, 68), rects[0].get_center())
	check("an order on a rooftop resolves to the kerb", not unreachable.is_empty(),
			"%d waypoints" % unreachable.size())
	city.free()      # the city holds a few hundred MeshInstance3D. Perf is measured next.


## The rig lives in the sagittal plane. Local forward is -Z, up is +Y.
## A knee is forward of the hip-ankle line. An elbow is below the shoulder-hand
## line. Bone lengths alone will not catch a joint bending the wrong way: the
## limbs are the right length, they simply point into the wrong half-plane.
func _sag(v: Vector3) -> Vector2:
	return Vector2(-v.z, v.y)      # (forward, up)


func _cross(a: Vector2, b: Vector2, p: Vector2) -> float:
	var d: Vector2 = b - a
	return d.x * (p.y - a.y) - d.y * (p.x - a.x)


func test_rig_joints_bend_like_a_human() -> void:
	var t: Trooper = Trooper.new()
	t.unit_type = &"cbt"
	var bad_knee: int = 0
	var bad_elbow: int = 0
	var worst_knee: float = 1e9
	var worst_elbow: float = -1e9
	for sp in [0.0, 0.8, 1.7]:
		t.speed_mps = sp
		for k in 48:
			t.gait = TAU * float(k) / 48.0
			var J: Dictionary = t._pose()
			for side in [["hipL", "kneeL", "ankL"], ["hipR", "kneeR", "ankR"]]:
				var c: float = _cross(_sag(J[side[0]]), _sag(J[side[2]]), _sag(J[side[1]]))
				worst_knee = minf(worst_knee, c)
				if c <= 0.0:
					bad_knee += 1
			for side2 in [["shL", "elbL", "handL"], ["shR", "elbR", "handR"]]:
				var c2: float = _cross(_sag(J[side2[0]]), _sag(J[side2[2]]), _sag(J[side2[1]]))
				worst_elbow = maxf(worst_elbow, c2)
				if c2 >= 0.0:
					bad_elbow += 1
	t.free()
	check("knees bend forward, never backward", bad_knee == 0,
			"%d/288 samples inverted, worst margin %.4f" % [bad_knee, worst_knee])
	check("elbows hang below the shoulder-hand line", bad_elbow == 0,
			"%d/288 samples inverted, worst margin %.4f" % [bad_elbow, worst_elbow])


## A rifleman and one infected in the open: the squad must fire, the infected
## must take the hits and drop, and it must have closed ground while it lived.
func test_combat_resolves() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-20, -20), Vector2(120, 120))
	var trooper: int = s.spawn(Vector2(50, 50), &"cbt", WorldSim.SQUAD)
	var zed: int = s.spawn(Vector2(50, 62), &"zed", WorldSim.INFECTED)   # 12 m off, inside cbt reach
	var start: float = s.hp[zed]
	var shots: int = 0
	var killed: bool = false
	for tick in 1800:
		s.step(1.0 / 60.0)
		for e in s.events:
			if e["kind"] == "gunfire":
				shots += 1
			if e["kind"] == "zed_death":
				killed = true
		if not s.alive[zed]:
			break
	check("squad opens fire on the infected", shots > 0, "%d shots" % shots)
	check("the infected takes fire and drops", killed and not s.alive[zed], "hp %.0f -> %.0f" % [start, s.hp[zed]])
	check("the infected closed distance while alive", s.pos[zed].distance_to(Vector2(50, 50)) < 12.0,
			"%.1f m from the trooper" % s.pos[zed].distance_to(Vector2(50, 50)))
	# the trooper (i=0) must survive: the zed never crossed 12 m to claw reach
	check("the rifleman is still standing", s.alive[trooper], "trooper hp %.0f" % s.hp[trooper])


## An unarmed civilian sees the infected and must gain ground, never fighting.
func test_civilian_flees() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-60, -60), Vector2(160, 160))
	var zed: int = s.spawn(Vector2(50, 50), &"zed", WorldSim.INFECTED)
	var civ: int = s.spawn(Vector2(50, 55), &"civ", WorldSim.CIVILIAN)   # 5 m off, inside civ sight
	var d0: float = s.pos[civ].distance_to(s.pos[zed])
	for tick in 360:
		s.step(1.0 / 60.0)
	var d1: float = s.pos[civ].distance_to(s.pos[zed])
	check("a civilian outruns the infected", d1 > d0 + 2.0, "gap %.1f -> %.1f m" % [d0, d1])
	check("the civilian never shoots back", s.foe[civ] == -1, "foe=%d" % s.foe[civ])


func perf() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 1
	var s: WorldSim = _rand_sim(300, rng)
	var rects: Array[Rect2] = []
	for i in 120:
		rects.append(Rect2(rng.randf_range(0, 400), rng.randf_range(0, 400), 30, 30))
	s.load_buildings(rects)
	for i in s.count():
		s.target[i] = Vector2(rng.randf_range(0, 400), rng.randf_range(0, 400))
		s.has_order[i] = true
	var t0: int = Time.get_ticks_usec()
	for tick in 600:
		s.step(1.0 / 60.0)
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / 600.0
	print("  PERF  300 units, 120 buildings: %.3f ms/tick  (%.1f%% of a 60 Hz frame)" % [ms, ms / 16.67 * 100.0])
	check("sim fits in a frame with room to spare", ms < 3.0, "%.3f ms/tick" % ms)
