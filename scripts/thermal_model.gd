class_name ThermalModel
extends RefCounted

## Loads a .glb and re-skins every surface with a THERMAL material, so imported
## PS1/PSX art survives the render pipeline -- which reads temperature, not
## albedo. The model's own PBR materials are replaced wholesale by one ThermalLib
## material. That is right for near-isothermal props (a barrel, a dumpster, an AC
## unit); multi-temperature objects (cars, bodies) still want their parts built
## by hand, the way vehicles.gd does (hot hood, cold glass, warm tyres).
##
## Scale is per-model and eyeballed from the glb geometry bounds -- VERIFY it in
## the feed and tune. Godot imports .glb Y-up, facing -Z.

static var _cache: Dictionary = {}   # glb path -> PackedScene, loaded once, shared


static func spawn(glb_path: String, mat: String, snap_res: Vector2i,
		scale: float = 1.0, yaw: float = 0.0) -> Node3D:
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
	node.scale = Vector3(scale, scale, scale)
	node.rotation.y = yaw
	_reskin(node, ThermalLib.get_material(mat, snap_res))
	return node


## Every MeshInstance3D under the model gets the thermal material as an override,
## replacing whatever PBR the artist shipped.
static func _reskin(n: Node, thermal: ShaderMaterial) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = thermal
	for c in n.get_children():
		_reskin(c, thermal)
