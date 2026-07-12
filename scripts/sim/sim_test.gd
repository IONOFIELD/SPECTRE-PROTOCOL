extends SceneTree

## godot --headless --path . --script res://scripts/sim/sim_test.gd
## Exits non-zero on any failure so this can gate a commit.

const MissionScript = preload("res://scripts/sim/mission.gd")   # by path: class_name may be unscanned in a --script run

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
	test_new_factions()
	test_terrain()
	test_land_polygon()
	test_air_strike()
	test_eod_grenade()
	test_population_hunts_and_fights()
	test_elements_and_medic()
	test_mission_exfil()
	test_mission_loss()
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


## An unarmed civilian runs from the infected but can't outpace them (v0.19: zed
## 4.8 > civ 3.6) -- the horde closes, and the civ never fights back.
func test_civilian_flees() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-60, -60), Vector2(160, 160))
	var zed: int = s.spawn(Vector2(50, 50), &"zed", WorldSim.INFECTED)
	var civ: int = s.spawn(Vector2(50, 56), &"civ", WorldSim.CIVILIAN)   # 6 m ahead of the horde
	var d0: float = s.pos[civ].distance_to(s.pos[zed])
	for tick in 180:      # 3 s
		s.step(1.0 / 60.0)
	var d1: float = s.pos[civ].distance_to(s.pos[zed])
	check("the civilian runs but the horde runs it down", d1 < d0 - 1.0, "gap %.1f -> %.1f m" % [d0, d1])
	check("the civilian never shoots back", s.foe[civ] == -1, "foe=%d" % s.foe[civ])


## The new ecology: bandits hunt + gun you down, survivors hold ground and fire on
## what closes, runners outpace the squad, brutes soak a magazine to reach melee.
func test_new_factions() -> void:
	# 1) a bandit hunts a lone trooper and guns him down (squad holding fire)
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-40, -40), Vector2(160, 160))
	s.weapons_free = false
	var trooper: int = s.spawn(Vector2(50, 50), &"cbt", WorldSim.SQUAD)
	var bandit: int = s.spawn(Vector2(50, 74), &"bnd", WorldSim.BANDIT)
	for _t in 330:
		s.step(1.0 / 60.0)
	var bd: float = s.pos[bandit].distance_to(s.pos[trooper])
	check("a bandit hunts and guns down a lone trooper",
		s.hp[trooper] < 100.0 and s.alive[bandit] and bd < 18.0,
		"trooper hp %.0f, bandit %.1f m off" % [s.hp[trooper], bd])

	# 2) a survivor holds its ground and drops an approaching zombie
	var s2: WorldSim = WorldSim.new()
	s2.set_bounds(Vector2(-40, -40), Vector2(160, 160))
	var svr: int = s2.spawn(Vector2(50, 50), &"svr", WorldSim.SURVIVOR)
	var zed: int = s2.spawn(Vector2(50, 64), &"zed", WorldSim.INFECTED)
	for _t in 420:
		s2.step(1.0 / 60.0)
	var drift: float = s2.pos[svr].distance_to(Vector2(50, 50))
	check("a survivor holds ground and drops the infected",
		not s2.alive[zed] and s2.alive[svr] and drift < 4.0,
		"zed alive=%s, survivor drifted %.1f m" % [s2.alive[zed], drift])

	# 3) a runner closes faster than a walker chasing the same mark
	var s3: WorldSim = WorldSim.new()
	s3.set_bounds(Vector2(-40, -40), Vector2(160, 160))
	s3.weapons_free = false
	var mark: int = s3.spawn(Vector2(50, 50), &"cbt", WorldSim.SQUAD)
	var runner: int = s3.spawn(Vector2(48, 90), &"run", WorldSim.INFECTED)
	var walker: int = s3.spawn(Vector2(52, 90), &"zed", WorldSim.INFECTED)
	for _t in 120:
		s3.step(1.0 / 60.0)
	var dr: float = s3.pos[runner].distance_to(s3.pos[mark])
	var dw: float = s3.pos[walker].distance_to(s3.pos[mark])
	check("a runner outpaces a walker chasing the same mark", dr < dw - 3.0,
		"runner %.1f m vs walker %.1f m from the mark" % [dr, dw])

	# 4) a brute soaks the trooper's fire and still reaches melee
	var s4: WorldSim = WorldSim.new()
	s4.set_bounds(Vector2(-40, -40), Vector2(160, 160))
	s4.weapons_free = true
	var gun: int = s4.spawn(Vector2(50, 50), &"cbt", WorldSim.SQUAD)
	var brute: int = s4.spawn(Vector2(50, 72), &"bru", WorldSim.INFECTED)
	for _t in 400:
		s4.step(1.0 / 60.0)
	var brd: float = s4.pos[brute].distance_to(s4.pos[gun])
	check("a brute soaks fire and reaches melee",
		s4.alive[brute] and brd < 3.0 and s4.hp[gun] < 100.0,
		"brute hp %.0f at %.1f m, trooper hp %.0f" % [s4.hp[brute], brd, s4.hp[gun]])


## Water shoves a unit back to shore; a bridge deck slows the crossing.
func test_terrain() -> void:
	# water eject: a unit driven at the bay is stopped at the shoreline
	var s: WorldSim = WorldSim.new()
	var walls: Array[Rect2] = []
	var sea: Array[Rect2] = [Rect2(60, -40, 100, 240)]     # bay walls off everything east of x=60
	var decks: Array[Rect2] = []
	s.load_map(walls, sea, decks, Vector2(-40, -40), Vector2(200, 200))
	var u: int = s.spawn(Vector2(50, 60), &"cbt", WorldSim.SQUAD)
	s.order_move([u], Vector2(150, 60))    # march east, into the water
	for _t in 300:
		s.step(1.0 / 60.0)
	check("water stops a unit at the shore", s.pos[u].x <= 60.6,
		"unit x=%.1f (shore at 60)" % s.pos[u].x)

	# bridge slow: crossing a deck covers less ground than open street in the same time
	var s2: WorldSim = WorldSim.new()
	s2.load_map([], [], [Rect2(0, 40, 220, 30)], Vector2(-40, -40), Vector2(280, 160))
	var onb: int = s2.spawn(Vector2(10, 55), &"cbt", WorldSim.SQUAD)    # on the deck (z in 40..70)
	var off: int = s2.spawn(Vector2(10, 100), &"cbt", WorldSim.SQUAD)   # open ground
	s2.order_move([onb], Vector2(200, 55))
	s2.order_move([off], Vector2(200, 100))
	for _t in 180:
		s2.step(1.0 / 60.0)
	var da: float = s2.pos[onb].x - 10.0     # progress across the bridge
	var db: float = s2.pos[off].x - 10.0     # progress on open ground
	check("the bridge deck slows the crossing", da < db * 0.75,
		"bridge %.1f m vs open %.1f m in 3 s" % [da, db])


## A land polygon: units spawn only inside it, get shoved back off the coast, and
## a carved bridge still lets them off the land. Here a 200 m diamond + a south stub.
func test_land_polygon() -> void:
	var s: WorldSim = WorldSim.new()
	var poly: PackedVector2Array = PackedVector2Array([
		Vector2(100, 10), Vector2(190, 100), Vector2(130, 190), Vector2(70, 190), Vector2(10, 100)])
	var walls: Array[Rect2] = []
	var water: Array[Rect2] = []
	var decks: Array[Rect2] = [Rect2(90, 190, 20, 60)]     # off the flat south coast, into the water
	s.load_map(walls, water, decks, Vector2(-40, -40), Vector2(300, 300), poly)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 3
	s.scatter(&"cbt", WorldSim.SQUAD, 40, Rect2(30, 30, 140, 140), rng)   # inside, clear of the bridge
	var all_in: bool = s.count() > 0
	for i in s.count():
		if not Geometry2D.is_point_in_polygon(s.pos[i], poly):
			all_in = false
	check("units only spawn on the land", all_in, "spawned=%d, all inside=%s" % [s.count(), all_in])

	var u: int = s.spawn(Vector2(100, 100), &"cbt", WorldSim.SQUAD)
	s.order_move([u], Vector2(400, 100))     # drive hard east, into the ocean
	for _t in 300:
		s.step(1.0 / 60.0)
	check("the coast keeps a unit on land", Geometry2D.is_point_in_polygon(s.pos[u], poly),
		"unit at (%.0f, %.0f)" % [s.pos[u].x, s.pos[u].y])

	var b2: int = s.spawn(Vector2(100, 150), &"cbt", WorldSim.SQUAD)
	s.order_move([b2], Vector2(100, 240))    # down the bridge stub, off the land
	for _t in 540:                           # 9 s -- 40 m to the coast + the slowed deck
		s.step(1.0 / 60.0)
	check("a carved bridge lets a unit off the land", s.pos[b2].y > 196.0,
		"unit y=%.1f (south coast at 190)" % s.pos[b2].y)


## An AC-130 strike kills everything in the ring -- hostiles AND friendlies.
func test_air_strike() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-40, -40), Vector2(160, 160))
	var zed: int = s.spawn(Vector2(50, 50), &"zed", WorldSim.INFECTED)
	var san: int = s.spawn(Vector2(54, 50), &"san", WorldSim.SANITATION)   # 400 hp, still dies
	var squad: int = s.spawn(Vector2(52, 52), &"cbt", WorldSim.SQUAD)      # friendly fire
	var far: int = s.spawn(Vector2(92, 50), &"zed", WorldSim.INFECTED)     # outside the ring
	s.air_strike(Vector2(52, 50), 16.0, 450.0)
	check("the strike kills the hostiles in the ring", not s.alive[zed] and not s.alive[san],
		"zed alive=%s, san alive=%s" % [s.alive[zed], s.alive[san]])
	check("friendly fire is real -- squad in the ring dies too", not s.alive[squad], "squad alive=%s" % s.alive[squad])
	check("units outside the ring survive", s.alive[far], "far alive=%s" % s.alive[far])
	var logged: bool = false
	for e in s.events:
		if e["kind"] == "strike":
			logged = true
	check("the strike is logged for audio + FX", logged, "events=%d" % s.events.size())


## EOD lobs a grenade: area damage on the target's cluster, hostiles only.
func test_eod_grenade() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-40, -40), Vector2(160, 160))
	var eod: int = s.spawn(Vector2(50, 50), &"eod", WorldSim.SQUAD)
	var z1: int = s.spawn(Vector2(50, 60), &"zed", WorldSim.INFECTED)   # target, in throw range
	var z2: int = s.spawn(Vector2(52, 61), &"zed", WorldSim.INFECTED)   # near target -> caught
	var z3: int = s.spawn(Vector2(50, 92), &"zed", WorldSim.INFECTED)   # far -> spared
	var civ: int = s.spawn(Vector2(48, 60), &"civ", WorldSim.CIVILIAN)  # in the ring but friendly
	for _t in 300:
		s.step(1.0 / 60.0)
	check("the EOD grenade kills the target cluster", not s.alive[z1] and not s.alive[z2],
		"z1 alive=%s, z2 alive=%s" % [s.alive[z1], s.alive[z2]])
	check("the grenade spares the far infected", s.alive[z3], "z3 alive=%s" % s.alive[z3])
	check("no friendly fire on civilians in the ring", s.alive[civ], "civ alive=%s (eod alive=%s)" % [s.alive[civ], s.alive[eod]])


## A populated city: factions land on walkable ground, and the hunting horde
## converges and fights within the window -- nothing stands idle in a field.
func test_population_hunts_and_fights() -> void:
	var city: CityGen = CityGen.new()
	city.generate(Vector2i(640, 360))
	var s: WorldSim = WorldSim.new()
	s.load_buildings(city.building_rects())
	var classes: Array = [&"cdr", &"cbt", &"med", &"snp", &"rec", &"eod"]
	for i in classes.size():
		s.spawn(Vector2(70.0 + float(i % 3) * 1.4, 68.0 + float(i / 3) * 1.4), classes[i], WorldSim.SQUAD)
	s.populate(22, 12, 4, Rect2(), 7)
	check("population spawns in full", s.count() == 6 + 22 + 12 + 4, "count=%d" % s.count())

	var rects: Array[Rect2] = city.building_rects()
	var inside: int = 0
	for i in s.count():
		for r in rects:
			if r.has_point(s.pos[i]):
				inside += 1
	check("nobody spawns inside a building", inside == 0, "%d inside" % inside)

	var gunfire: int = 0
	var deaths: int = 0
	for tick in 5400:      # 90 s -- time for the horde to close
		s.step(1.0 / 60.0)
		for e in s.events:
			if e["kind"] == "gunfire":
				gunfire += 1
			elif e["kind"] == "zed_death" or e["kind"] == "man_down" or e["kind"] == "kill":
				deaths += 1
	check("the horde closes and the guns open up", gunfire > 0, "%d shots" % gunfire)
	check("bodies drop in a populated map", deaths > 0, "%d deaths" % deaths)
	city.free()


## Four teams live as elements, and a medic keeps its own patched up.
func test_elements_and_medic() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-20, -20), Vector2(120, 120))
	s.spawn(Vector2(50, 50), &"cdr", WorldSim.SQUAD, 0)
	s.spawn(Vector2(51, 50), &"med", WorldSim.SQUAD, 0)
	var hurt: int = s.spawn(Vector2(52, 50), &"cbt", WorldSim.SQUAD, 0)
	s.spawn(Vector2(80, 80), &"cdr", WorldSim.SQUAD, 1)
	check("element 0 holds its three", s.element_ids(0).size() == 3, "got %d" % s.element_ids(0).size())
	check("element 1 holds its one", s.element_ids(1).size() == 1, "got %d" % s.element_ids(1).size())
	s.hp[hurt] = 20.0
	for tick in 120:      # 2 s beside the medic
		s.step(1.0 / 60.0)
	check("the medic patches a wounded ally", s.hp[hurt] > 40.0, "hp 20 -> %.0f" % s.hp[hurt])


## The exfil: no lift before the birds arrive; a team on the LZ boards once they
## do; all teams clear -> WON.
func test_mission_exfil() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-40, -40), Vector2(240, 240))
	var a: int = s.spawn(Vector2(20, 20), &"cdr", WorldSim.SQUAD, 0)
	var b: int = s.spawn(Vector2(21, 20), &"cbt", WorldSim.SQUAD, 0)
	var c: int = s.spawn(Vector2(30, 30), &"cdr", WorldSim.SQUAD, 1)
	var m := MissionScript.new()
	var zones: Array[Rect2] = [Rect2(200, -40, 40, 280)]    # a bridge far end, east
	m.setup(zones, 2)
	m.update(s, 0.1)
	check("no element escapes short of the bridge end",
			m.status[0] == 0 and m.result == MissionScript.ONGOING, "status0=%d" % m.status[0])
	s.pos[a] = Vector2(210, 100)             # element 0 both reach the far end
	s.pos[b] = Vector2(216, 110)
	m.update(s, 0.1)
	check("an element all inside the escape zone gets clear", m.status[0] == 1, "status0=%d" % m.status[0])
	check("escaped units leave play but aren't dead", s.extracted[a] and not s.alive[a],
			"ex=%s alive=%s" % [s.extracted[a], s.alive[a]])
	check("mission ongoing while an element is still out", m.result == MissionScript.ONGOING, "result=%d" % m.result)
	s.pos[c] = Vector2(220, 60)              # element 1 reaches it too
	m.update(s, 0.1)
	check("all elements clear -> WON", m.result == MissionScript.WON, "result=%d" % m.result)


## Total loss: every element wiped.
func test_mission_loss() -> void:
	var s: WorldSim = WorldSim.new()
	s.set_bounds(Vector2(-40, -40), Vector2(240, 240))
	var u: int = s.spawn(Vector2(50, 50), &"cdr", WorldSim.SQUAD, 0)
	var zones: Array[Rect2] = [Rect2(200, -40, 40, 280)]
	var m := MissionScript.new()
	m.setup(zones, 1)
	s.alive[u] = false                       # the last operator down
	m.update(s, 0.1)
	check("an element wiped to the last is LOST", m.status[0] == 2, "status0=%d" % m.status[0])
	check("every element lost -> LOST", m.result == MissionScript.LOST, "result=%d" % m.result)


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
