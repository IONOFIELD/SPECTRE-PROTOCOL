extends SceneTree

## TEMP isolated render test: does a SurfaceTool ground sheet render AT ALL outside the
## game's scene tree? A: 5-quad sheet y0. B: single quad y0. C: BoxMesh control.
## Captures one PNG to SPECTRE_ISO and quits.

var _frames: int = 0
var _cam: Camera3D


func _init() -> void:
	var root_node: Node3D = Node3D.new()
	root.add_child(root_node)

	var env: WorldEnvironment = WorldEnvironment.new()
	var e: Environment = Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.1, 0.1, 0.1)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	root_node.add_child(env)

	_cam = Camera3D.new()
	_cam.fov = 40.0
	root_node.add_child(_cam)
	_cam.look_at_from_position(Vector3(0.0, 260.0, 190.0), Vector3.ZERO, Vector3.UP)
	_cam.make_current()

	var mat: ShaderMaterial = ThermalLib.get_material("hood_hot", Vector2i(640, 360))

	# A: a 5-quad sheet at y 0 (the citygen shape), west
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for q in 5:
		var z0: float = -110.0 + float(q) * 45.0
		var a: Vector3 = Vector3(-200.0, 0.0, z0)
		var b: Vector3 = Vector3(-90.0, 0.0, z0)
		var c: Vector3 = Vector3(-90.0, 0.0, z0 + 38.0)
		var d: Vector3 = Vector3(-200.0, 0.0, z0 + 38.0)
		for v in [a, c, b, a, d, c]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	var mi_a: MeshInstance3D = MeshInstance3D.new()
	mi_a.mesh = st.commit()
	mi_a.material_override = mat
	root_node.add_child(mi_a)

	# B: a single quad at y 0, centre
	var st2: SurfaceTool = SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a2: Vector3 = Vector3(-30.0, 0.0, -30.0)
	var b2: Vector3 = Vector3(30.0, 0.0, -30.0)
	var c2: Vector3 = Vector3(30.0, 0.0, 30.0)
	var d2: Vector3 = Vector3(-30.0, 0.0, 30.0)
	for v in [a2, c2, b2, a2, d2, c2]:
		st2.set_normal(Vector3.UP)
		st2.add_vertex(v)
	var mi_b: MeshInstance3D = MeshInstance3D.new()
	mi_b.mesh = st2.commit()
	mi_b.material_override = mat
	root_node.add_child(mi_b)

	# C: a box control, east -- PLAIN unshaded StandardMaterial3D (no thermal shader)
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(40.0, 10.0, 40.0)
	var mi_c: MeshInstance3D = MeshInstance3D.new()
	mi_c.mesh = bm
	mi_c.position = Vector3(100.0, 5.0, 0.0)
	var smat: StandardMaterial3D = StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.albedo_color = Color(1.0, 0.2, 0.2)
	mi_c.material_override = smat
	root_node.add_child(mi_c)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 20:
		_grab()
	return false


func _grab() -> void:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img != null:
		img.save_png(OS.get_environment("SPECTRE_ISO") + "/iso.png")
		print("iso saved")
	quit()
