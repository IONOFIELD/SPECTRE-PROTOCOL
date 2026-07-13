class_name Corpses
extends Node3D

## Dead bodies, scattered organically across the city.
##
## Every character mesh in the population packs is a candidate body. We harvest
## the meshes once, normalize each to human height (the packs' own scale is
## arbitrary), tip it prone, and cool it to body_cold so it reads as a dark shape
## on the warmer ground. Placement mixes singletons with small huddles (people who
## fell together) and is reseeded per run -- no two plays scatter the same.
## Building interiors are rejected.
##
## Same bodies, three roles, told apart ONLY by heat + motion: warm+walking is a
## civilian, near-ambient+hostile is infected, cold+prone is one of these.
##
## VERIFY in the feed and tune: TARGET_H (body length), REST_Y (prone lift off the
## ground), and the count main passes. Pack figures are standing poses tipped flat
## -- stiff, but at PS1 thermal resolution a dark human blob reads as a body.

const PACKS: Array[String] = [
	"res://models/characters/characters_psx.glb",
	"res://models/characters/psx_base_-_civilian_pack.glb",
]
const BODY_MAT: String = "body_cold"
const TARGET_H: float = 1.75    # metres; every body normalized to ~this tall
const REST_Y: float = 0.12      # lift so the prone body rests ON the ground

var _pool: Array[Mesh] = []
var _brects: Array[Rect2] = []


## `count` bodies scattered. seed_value < 0 => randomize (different every play).
func generate(snap_res: Vector2i, city: CityGen, count: int, seed_value: int = -1) -> void:
	_harvest()
	if _pool.is_empty():
		push_warning("[Corpses] no character meshes harvested; nothing to scatter")
		return
	_brects = city.building_rects()

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	if seed_value < 0:
		rng.randomize()
	else:
		rng.seed = seed_value

	var mat: ShaderMaterial = ThermalLib.get_material(BODY_MAT, snap_res)
	var lo: Vector2 = city.poly_lo
	var hi: Vector2 = city.poly_hi

	var placed: int = 0
	var tries: int = 0
	while placed < count and tries < count * 40:
		tries += 1
		# organic: ~55% lone bodies, else a small huddle that fell together
		var huddle: int = 1 if rng.randf() < 0.55 else 2 + rng.randi() % 4
		var cx: float = rng.randf_range(lo.x, hi.x)
		var cz: float = rng.randf_range(lo.y, hi.y)
		for _k in huddle:
			if placed >= count:
				break
			var at: Vector2 = Vector2(cx + rng.randfn(0.0, 1.2), cz + rng.randfn(0.0, 1.2))
			if _in_building(at) or not Geometry2D.is_point_in_polygon(at, city.land_poly):
				continue
			_place(at, rng, mat)
			placed += 1


func _place(at: Vector2, rng: RandomNumberGenerator, mat: ShaderMaterial) -> void:
	var mesh: Mesh = _pool[rng.randi() % _pool.size()]
	var a: AABB = mesh.get_aabb()
	var s: float = TARGET_H / maxf(0.05, a.size.y)

	# pivot carries the world position + a random compass facing
	var pivot: Node3D = Node3D.new()
	pivot.position = Vector3(at.x, REST_Y, at.y)
	pivot.rotation.y = rng.randf() * TAU
	add_child(pivot)

	# the mesh is tipped prone (-90 about X), scaled to human size, and re-centred
	# so the body's middle sits on the pivot.
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	var b: Basis = Basis(Vector3(1.0, 0.0, 0.0), -PI * 0.5) * Basis.from_scale(Vector3(s, s, s))
	mi.transform = Transform3D(b, -(b * a.get_center()))
	pivot.add_child(mi)


## Harvest every mesh resource out of the population packs, once. skins=0 on these
## packs, so the figures are plain static meshes -- no rig to carry.
func _harvest() -> void:
	for pack_path in PACKS:
		if not ResourceLoader.exists(pack_path):
			push_warning("[Corpses] missing pack: " + pack_path)
			continue
		var inst: Node = (load(pack_path) as PackedScene).instantiate()
		_collect(inst)
		inst.queue_free()


func _collect(n: Node) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		_pool.append((n as MeshInstance3D).mesh)
	for c in n.get_children():
		_collect(c)


func _in_building(at: Vector2) -> bool:
	for r in _brects:
		if r.has_point(at):
			return true
	return false
