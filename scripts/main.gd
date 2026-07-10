extends Node

## SPECTRE PROTOCOL // Godot 4 render stack
##
## Tree built in code so there is no .tscn to get out of sync:
##
##   Main (this)
##    +- SubViewportContainer   material = sensor.gdshader, filter = nearest
##    |   +- SubViewport 640x360, MSAA off, debanding off
##    |       +- WorldEnvironment  (clear colour = -14 C sky radiance)
##    |       +- Camera3D
##    |       +- CityGen
##    |       +- Trooper x N
##    +- CanvasLayer
##        +- ColorRect            material = channel_cut.gdshader
##        +- Label                HUD
##
## The SubViewport is not an art decision. A FLIR Boson is 640x512. The render
## target IS the detector array.
##
## Keys: SPACE channel change | T palette | J vertex snap | C cctv | R res
##       G freeze AGC | O auto orbit | drag orbit | wheel zoom

const RESOLUTIONS: Array = [Vector2i(320, 180), Vector2i(640, 360), Vector2i(960, 540)]
const CUT_DUR: float = 0.52
const CUT_SWAP: float = 0.30          # the new feed goes live here, under the snow
const MUSIC_BED: String = "res://audio/music/music1.wav"   # loops; Audio owns the level

var res_idx := 1
var snap_res: Vector2i = RESOLUTIONS[1]

var screen: TextureRect
var vp: SubViewport
var cam: Camera3D
var city: CityGen
var cars: Vehicles
var cut_rect: ColorRect
var hud: Label

var sensor_mat: ShaderMaterial
var cut_mat: ShaderMaterial
var agc := AGC.new()

var sim: WorldSim = WorldSim.new()
var troopers: Array[Trooper] = []
var sel_layer: Control
var drag_start: Vector2 = Vector2.ZERO
var dragging: bool = false

# feeds
const FEED: Dictionary = {
	"deploy": {"dist": 34.0, "el": 0.40, "fov": 30.0, "follow": true, "orbit": 0.0},
	"orbit":  {"dist": 250.0, "el": 0.98, "fov": 24.0, "follow": false, "orbit": 0.035},
}
var feed := "deploy"
var cam_tx := 74.0
var cam_tz := 69.0
var cam_dist := 22.0
var cam_az := -0.85
var cam_el := 0.28

var cut_t := -1.0
var cut_to := "orbit"
var cut_swapped := false

var frame_n := 0.0
var mode := 0
var snap_on := true
var cctv := 0.85
var orbit_auto := true
var _auto_fired := false
var probe_lock: bool = false   # freeze the follow cam for A/B captures
var agc_pinned: bool = false   # A/B rig only
var _shot_dir: String = OS.get_environment("SPECTRE_SHOT")
const SHOT_FRAMES: Array = [60, 104, 260, 700]

func _maybe_capture() -> void:
	if not SHOT_FRAMES.has(int(frame_n)):
		return
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s/frame_%03d.png" % [_shot_dir, int(frame_n)])
		print("captured frame ", int(frame_n))


func _ready() -> void:
	if OS.get_environment("SPECTRE_NODETAIL") != "":
		ThermalLib.detail_on = false
	if OS.get_environment("SPECTRE_NOSNAP") != "":
		ThermalLib.snap_default = false
	_build_tree()
	_spawn()
	set_process_input(true)
	Audio.play_music(MUSIC_BED, 2.0)   # the bed fades up over the cold open


func _build_tree() -> void:
	# A SubViewportContainer with stretch=true FORCES the viewport to the
	# container size. It silently refuses SubViewport.size and you render at
	# window resolution with no pixelation at all. Use a bare SubViewport plus
	# a TextureRect, so the detector array size is ours to set.
	vp = SubViewport.new()
	vp.size = snap_res
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_DISABLED          # PS1 had no MSAA and neither do you
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_debanding = false                     # the dither in the sensor shader is the point
	vp.positional_shadow_atlas_size = 0
	# RGBA16F. An 8-bit target puts the entire roof-to-skin range inside five
	# code values, because radiance is a fourth power and fire is 17x a wall.
	vp.use_hdr_2d = true
	add_child(vp)

	sensor_mat = ShaderMaterial.new()
	sensor_mat.shader = load("res://shaders/sensor.gdshader")

	var feed_layer: CanvasLayer = CanvasLayer.new()
	feed_layer.layer = 0
	add_child(feed_layer)

	screen = TextureRect.new()
	screen.texture = vp.get_texture()
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # no bilinear on a pixel buffer
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.material = sensor_mat
	feed_layer.add_child(screen)

	var we: WorldEnvironment = WorldEnvironment.new()
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = ThermalLib.sky_color()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.glow_enabled = false                     # bloom lives in sensor.gdshader
	env.ssao_enabled = false
	env.sdfgi_enabled = false
	we.environment = env
	vp.add_child(we)

	cam = Camera3D.new()
	cam.fov = 24.0
	cam.near = 0.08
	cam.far = 6000.0
	vp.add_child(cam)

	city = CityGen.new()
	vp.add_child(city)
	city.generate(snap_res)
	cars = Vehicles.new()
	vp.add_child(cars)
	cars.generate(snap_res, city, 26)

	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 1
	add_child(layer)

	cut_rect = ColorRect.new()
	cut_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	cut_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cut_mat = ShaderMaterial.new()
	cut_mat.shader = load("res://shaders/channel_cut.gdshader")
	cut_rect.material = cut_mat
	layer.add_child(cut_rect)

	sel_layer = Control.new()
	sel_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sel_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sel_layer.draw.connect(_draw_selection)
	layer.add_child(sel_layer)

	hud = Label.new()
	hud.position = Vector2(24, 20)
	hud.add_theme_font_size_override("font_size", 13)
	layer.add_child(hud)

	_push_res()
	if OS.get_environment("SPECTRE_CLEAN") != "":
		# A/B rig: kill the detector noise so a diff measures surface detail only
		cctv = 0.0
		sensor_mat.set_shader_parameter("noise_amt", 0.0)
		sensor_mat.set_shader_parameter("fpn_amt", 0.0)
		sensor_mat.set_shader_parameter("dither", false)
		# and pin the gain, or the diff measures the AGC re-exposing, not the surface
		agc_pinned = true
		agc.frozen = true
		agc.lo = 0.62
		agc.hi = 1.18
		agc.median = 0.86


func _push_res() -> void:
	vp.size = snap_res
	if screen != null:
		screen.texture = vp.get_texture()
	sensor_mat.set_shader_parameter("res", Vector2(snap_res))
	cut_mat.set_shader_parameter("res", Vector2(snap_res))
	ThermalLib.clear_cache()   # snap_res is baked into every material


func _spawn() -> void:
	sim = WorldSim.new()
	var obstacles: Array[Rect2] = city.building_rects()
	if cars != null:
		obstacles.append_array(cars.rects)     # semis block; the rest you walk around
	sim.load_buildings(obstacles)
	var classes: Array = [&"cdr", &"cbt", &"med", &"snp", &"rec", &"eod"]
	for i in classes.size():
		var p: Vector2 = Vector2(70.0 + float(i % 3) * 1.4, 68.0 + float(i / 3) * 1.4)
		sim.spawn(p, classes[i])
		var t: Trooper = Trooper.new()
		t.unit_type = classes[i]
		t.gait = i * 1.6
		vp.add_child(t)
		t.setup(snap_res)
		troopers.append(t)


## The sim owns position and heading. The Trooper node owns nothing but its pose.
func _sync_visuals(delta: float) -> void:
	for i in troopers.size():
		var t: Trooper = troopers[i]
		t.position = Vector3(sim.pos[i].x, 0.0, sim.pos[i].y)
		# Godot models face -Z. A yaw of theta points forward at (-sin, 0, -cos).
		var v: Vector2 = sim.vel[i]
		if v.length_squared() > 0.04:
			t.rotation.y = atan2(-v.x, -v.y)
		t.speed_mps = v.length()
		t.advance(delta, sim.moving(i))


## Mouse pixel -> point on the ground plane. The mouse is in window pixels and
## the camera lives inside a 640x360 SubViewport, so the ray must be cast in
## viewport pixels or every click lands somewhere else.
func _ground_pick(mouse: Vector2) -> Vector2:
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var vpm: Vector2 = mouse * (Vector2(snap_res) / win)
	var origin: Vector3 = cam.project_ray_origin(vpm)
	var dir: Vector3 = cam.project_ray_normal(vpm)
	if absf(dir.y) < 1e-5:
		return Vector2.ZERO
	var d: float = -origin.y / dir.y
	var hit: Vector3 = origin + dir * d
	return Vector2(hit.x, hit.z)


func _screen_of(i: int) -> Vector2:
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var p: Vector2 = cam.unproject_position(Vector3(sim.pos[i].x, 0.9, sim.pos[i].y))
	return p * (win / Vector2(snap_res))


func _process(delta: float) -> void:
	frame_n += 1.0
	if _shot_dir != "":
		_maybe_capture()
	if not _auto_fired and frame_n > 96.0:
		_auto_fired = true
		_channel_change("orbit")
	if _shot_dir != "" and OS.get_environment("SPECTRE_PROBE") != "" and int(frame_n) == 55:
		# stand in the street and look straight at one facade
		var b: Dictionary = city.buildings[0]
		for cand in city.buildings:
			if cand["fl"] > b["fl"]:
				b = cand
		var cx: float = b["x"] + b["w"] * 0.5
		var cz: float = b["z"]
		cut_t = -1.0
		feed = "deploy"
		cam_tx = cx
		cam_tz = cz
		cam_dist = 26.0
		cam_el = 0.30
		cam_az = PI * 0.5
		cam.fov = 30.0
		probe_lock = true
	if _shot_dir != "" and int(frame_n) == 400:
		feed = "deploy"
		cam_dist = 26.0
		cam_el = 0.30
		cam.fov = 30.0
	if _shot_dir != "" and int(frame_n) == 30:
		for i in sim.count():
			sim.selected[i] = true
		sim.order_move(sim.selected_ids(), Vector2(150, 132))   # scripted order, for capture

	sim.step(delta)
	_sync_visuals(delta)

	var p: float = -1.0
	if cut_t >= 0.0:
		cut_t += delta
		p = cut_t / CUT_DUR
		if not cut_swapped and p >= CUT_SWAP:
			cut_swapped = true
			feed = cut_to
			_apply_feed()
			agc.knock_out_of_lock()   # the optic loses lock. it will visibly hunt back.
			agc.frozen = false
		if p >= 1.0:
			cut_t = -1.0
			p = -1.0
	if not agc_pinned:
		agc.frozen = (p >= 0.0 and p < CUT_SWAP)

	var f: Dictionary = FEED[feed]
	if f.follow:
		var c: Vector3 = troopers[0].position
		cam_tx = lerpf(cam_tx, c.x, minf(1.0, delta * 1.6))
		cam_tz = lerpf(cam_tz, c.z, minf(1.0, delta * 1.6))
	if orbit_auto and f.orbit > 0.0 and cut_t < 0.0:
		cam_az += f.orbit * delta

	cam.fov = f.fov
	var eye: Vector3 = Vector3(
		cam_tx - cos(cam_az) * cos(cam_el) * cam_dist,
		maxf(1.2, sin(cam_el) * cam_dist),
		cam_tz - sin(cam_az) * cos(cam_el) * cam_dist)
	cam.position = eye
	cam.look_at(Vector3(cam_tx, 1.2, cam_tz), Vector3.UP)

	agc.update(vp)
	agc.push(sensor_mat)
	sensor_mat.set_shader_parameter("mode", mode)
	sensor_mat.set_shader_parameter("time_s", float(Time.get_ticks_msec()) / 1000.0)

	cut_mat.set_shader_parameter("cut_p", p)
	cut_mat.set_shader_parameter("frame_n", frame_n)
	cut_mat.set_shader_parameter("cctv", cctv)
	if sel_layer != null:
		sel_layer.queue_redraw()

	var names: Array = ["WHT HOT", "BLK HOT", "IRONBOW"]
	if p >= 0.0 and p < 0.46:
		hud.text = "" if int(frame_n) % 16 < 8 else "SIGNAL ACQ"
	else:
		hud.text = "FEED  %s\nMODE  %s\nRES   %dx%d\nALT   %d M   SLANT %d M\nAGC   %s %.3f/%.3f\nFPS   %d" % [
			"AC-130 / PYLON TURN" if feed == "orbit" else "ELEMENT / GROUND",
			names[mode], snap_res.x, snap_res.y,
			int(cam.position.y), int(cam_dist),
			"FROZEN" if agc.frozen else "AUTO", agc.lo, agc.hi,
			Engine.get_frames_per_second()]


const SEL_COL: Color = Color(0.62, 0.88, 0.70, 0.85)

func _draw_selection() -> void:
	if cut_t >= 0.0:
		return                      # the overlay generator rides the same signal
	for i in sim.count():
		if not sim.alive[i] or not sim.selected[i]:
			continue
		var p: Vector2 = _screen_of(i)
		var r: float = 9.0
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var a: Vector2 = p + c * r
			sel_layer.draw_line(a, a - Vector2(c.x * 5.0, 0), SEL_COL, 1.0)
			sel_layer.draw_line(a, a - Vector2(0, c.y * 5.0), SEL_COL, 1.0)
		if sim.has_order[i]:
			var t: Vector2 = cam.unproject_position(Vector3(sim.target[i].x, 0.1, sim.target[i].y))
			var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
			t *= win / Vector2(snap_res)
			sel_layer.draw_line(p, t, Color(SEL_COL.r, SEL_COL.g, SEL_COL.b, 0.25), 1.0)
	if dragging:
		var m: Vector2 = get_viewport().get_mouse_position()
		sel_layer.draw_rect(Rect2(drag_start, m - drag_start), SEL_COL, false, 1.0)


func _select_in_rect(r: Rect2) -> void:
	for i in sim.count():
		sim.selected[i] = sim.alive[i] and r.abs().has_point(_screen_of(i))


func _select_nearest(g: Vector2) -> void:
	var best: int = -1
	var bd: float = 2.5
	for i in sim.count():
		if not sim.alive[i]:
			continue
		var d: float = sim.pos[i].distance_to(g)
		if d < bd:
			bd = d
			best = i
	for i in sim.count():
		sim.selected[i] = (i == best)


func _channel_change(to: String) -> void:
	if cut_t >= 0.0:
		return
	cut_t = 0.0
	cut_to = to
	cut_swapped = false


func _apply_feed() -> void:
	var f: Dictionary = FEED[feed]
	cam_dist = f.dist
	cam_el = f.el
	if feed == "orbit":
		cam_tx = 150.0
		cam_tz = 110.0
		cam_az = -1.05


func _input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_MIDDLE or (e.button_mask & MOUSE_BUTTON_MASK_LEFT and Input.is_key_pressed(KEY_SHIFT))):
		if Input.is_key_pressed(KEY_CTRL):
			var ca: float = cos(cam_az)
			var sa: float = sin(cam_az)
			var k: float = cam_dist * 0.0022
			cam_tx += (-e.relative.x * sa - e.relative.y * ca) * k
			cam_tz += (e.relative.x * ca - e.relative.y * sa) * k
		else:
			cam_az -= e.relative.x * 0.006
			cam_el = clampf(cam_el + e.relative.y * 0.005, 0.12, 1.45)
	elif e is InputEventMouseButton:
		if e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = clampf(cam_dist * 0.9, 6.0, 520.0)
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = clampf(cam_dist * 1.1, 6.0, 520.0)
		elif e.button_index == MOUSE_BUTTON_LEFT and not Input.is_key_pressed(KEY_SHIFT):
			if e.pressed:
				dragging = true
				drag_start = e.position
			else:
				dragging = false
				if e.position.distance_to(drag_start) < 6.0:
					_select_nearest(_ground_pick(e.position))
				else:
					_select_in_rect(Rect2(drag_start, e.position - drag_start))
		elif e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
			var ids: Array = sim.selected_ids()
			if not ids.is_empty():
				sim.order_move(ids, _ground_pick(e.position))
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_SPACE: _channel_change("orbit" if feed == "deploy" else "deploy")
			KEY_T: mode = (mode + 1) % 3
			KEY_C: cctv = 0.0 if cctv > 0.0 else 0.85
			KEY_G: agc.frozen = not agc.frozen
			KEY_O: orbit_auto = not orbit_auto
			KEY_K:
				ThermalLib.detail_on = not ThermalLib.detail_on
				ThermalLib.clear_cache()
				_rebuild_world()
			KEY_J:
				snap_on = not snap_on
				ThermalLib.snap_default = snap_on
				ThermalLib.clear_cache()
				_rebuild_world()
			KEY_R:
				res_idx = (res_idx + 1) % RESOLUTIONS.size()
				snap_res = RESOLUTIONS[res_idx]
				_push_res()
				_rebuild_world()


func _rebuild_world() -> void:
	city.queue_free()
	if cars != null:
		cars.queue_free()
	for t in troopers:
		t.queue_free()
	troopers.clear()
	await get_tree().process_frame
	city = CityGen.new()
	vp.add_child(city)
	city.generate(snap_res)
	cars = Vehicles.new()
	vp.add_child(cars)
	cars.generate(snap_res, city, 26)
	_spawn()
