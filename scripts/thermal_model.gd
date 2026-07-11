class_name ThermalModel
extends RefCounted

## Loads a .glb and re-skins every surface with a THERMAL material so imported
## PS1/PSX art survives the render pipeline (temperature, not albedo).
##
## Single-mat props (barrel, dumpster, AC): one ThermalLib key for the whole model.
## Multi-temp objects (cars, bodies) still need part splits (see vehicles.gd).
##
## Scale is per-model — verify in the feed. Godot imports .glb Y-up, facing -Z.

static var _cache: Dictionary = {}   # glb path -> PackedScene


static func spawn(glb_path: String, mat: String, snap_res: Vector2i,
		scale: float = 1.0, yaw: float = 0.0, ground_align: bool = true) -> Node3D:
	var node: Node3D = _instantiate(glb_path)
	if node == null:
		return null
	node.scale = Vector3(scale, scale, scale)
	node.rotation.y = yaw
	_reskin(node, ThermalLib.get_material(mat, snap_res))
	if ground_align:
		_align_bottom_to_y0(node)
	return node


## Stretch a light single-mesh GLB to a target footprint × height (metres).
## Non-uniform scale is intentional: PSX shells fill the citygen parcel cheaply.
static func spawn_fit(glb_path: String, mat: String, snap_res: Vector2i,
		size_m: Vector3, yaw: float = 0.0) -> Node3D:
	var node: Node3D = _instantiate(glb_path)
	if node == null:
		return null
	node.scale = Vector3.ONE
	node.rotation.y = 0.0
	_reskin(node, ThermalLib.get_material(mat, snap_res))
	var aabb: AABB = _combined_aabb(node)
	if aabb.size.x < 1e-4 or aabb.size.y < 1e-4 or aabb.size.z < 1e-4:
		node.queue_free()
		return null
	node.scale = Vector3(
		size_m.x / aabb.size.x,
		size_m.y / aabb.size.y,
		size_m.z / aabb.size.z)
	node.rotation.y = yaw
	_align_bottom_to_y0(node)
	return node


## Keyword map on mesh / surface material names → ThermalLib keys.
## First matching rule wins. Default covers the rest.
static func spawn_rules(glb_path: String, snap_res: Vector2i, default_mat: String,
		rules: Array, scale: float = 1.0, yaw: float = 0.0,
		ground_align: bool = true) -> Node3D:
	var node: Node3D = _instantiate(glb_path)
	if node == null:
		return null
	node.scale = Vector3(scale, scale, scale)
	node.rotation.y = yaw
	_reskin_rules(node, snap_res, default_mat, rules)
	if ground_align:
		_align_bottom_to_y0(node)
	return node


static func _instantiate(glb_path: String) -> Node3D:
	var scene: PackedScene = _cache.get(glb_path)
	if scene == null:
		if not ResourceLoader.exists(glb_path):
			push_warning("[ThermalModel] missing: " + glb_path)
			return null
		scene = load(glb_path)
		_cache[glb_path] = scene
	var root: Node = scene.instantiate()
	var node: Node3D = root as Node3D
	if node == null:
		push_warning("[ThermalModel] .glb root is not Node3D: " + glb_path)
		root.queue_free()
		return null
	return node


static func _reskin(n: Node, thermal: ShaderMaterial) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = thermal
	for c in n.get_children():
		_reskin(c, thermal)


static func _reskin_rules(n: Node, snap_res: Vector2i, default_mat: String, rules: Array) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n as MeshInstance3D
		var key: String = _classify(mi, default_mat, rules)
		mi.material_override = ThermalLib.get_material(key, snap_res)
	for c in n.get_children():
		_reskin_rules(c, snap_res, default_mat, rules)


## rules: Array of [String keyword_lowercase, String thermal_key]
static func _classify(mi: MeshInstance3D, default_mat: String, rules: Array) -> String:
	var hay: String = mi.name.to_lower()
	if mi.mesh != null:
		hay += " " + str(mi.mesh.resource_name).to_lower()
	if mi.mesh != null:
		for si in mi.mesh.get_surface_count():
			var am: Variant = mi.mesh.surface_get_material(si)
			if am is Material and (am as Material).resource_name != "":
				hay += " " + (am as Material).resource_name.to_lower()
	for r in rules:
		if hay.contains(String(r[0])):
			return String(r[1])
	return default_mat


## Shift so the lowest mesh bound sits on y = 0 in the node's local space.
static func _align_bottom_to_y0(root: Node3D) -> void:
	var aabb: AABB = _combined_aabb(root)
	if aabb.size == Vector3.ZERO:
		return
	root.position.y -= aabb.position.y


static func _combined_aabb(root: Node3D) -> AABB:
	var has: bool = false
	var out: AABB = AABB()
	for mi in _mesh_instances(root):
		var xf: Transform3D = _xform_to_root(root, mi)
		var a: AABB = mi.get_aabb()
		var corners: Array[Vector3] = [
			a.position,
			a.position + Vector3(a.size.x, 0, 0),
			a.position + Vector3(0, a.size.y, 0),
			a.position + Vector3(0, 0, a.size.z),
			a.position + Vector3(a.size.x, a.size.y, 0),
			a.position + Vector3(a.size.x, 0, a.size.z),
			a.position + Vector3(0, a.size.y, a.size.z),
			a.position + a.size,
		]
		for c in corners:
			var p: Vector3 = xf * c
			if not has:
				out = AABB(p, Vector3.ZERO)
				has = true
			else:
				out = out.expand(p)
	return out if has else AABB()


static func _xform_to_root(root: Node3D, n: Node3D) -> Transform3D:
	var t: Transform3D = Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


static func _mesh_instances(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n as MeshInstance3D)
	for c in n.get_children():
		out.append_array(_mesh_instances(c))
	return out
