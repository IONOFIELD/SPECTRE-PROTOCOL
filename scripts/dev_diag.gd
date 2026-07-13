extends SceneTree

## TEMP diagnostic: does CityGen's surface tiling actually emit meshes, and with what?

func _init() -> void:
	var cg: CityGen = CityGen.new()
	cg.generate(Vector2i(640, 360))
	var n_mesh: int = 0
	var n_flat: int = 0
	print("children: ", cg.get_child_count(), "  buildings: ", cg.buildings.size())
	for ch in cg.get_children():
		if ch is MeshInstance3D and ch.mesh != null:
			n_mesh += 1
			var aabb: AABB = (ch.mesh as Mesh).get_aabb()
			if aabb.size.y < 0.5 and aabb.size.x > 100.0:
				n_flat += 1
				var m: Material = ch.material_override
				var t: Variant = (m as ShaderMaterial).get_shader_parameter("temp_c") if m is ShaderMaterial else null
				print("FLAT mesh  size=", aabb.size, "  pos=", aabb.position, "  temp_c=", t)
	print("meshes: ", n_mesh, "  big flat sheets: ", n_flat)
	quit()
