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
const INTRO_HOLD: float = 7.0         # seconds holding the deploy view before the AC-130 cut
const ZOOM_MIN: float = 22.0          # AC-130 optic floor -- never drops to a ground-level camera
const ZOOM_MAX: float = 900.0         # high enough to frame the whole ~806 m city from the pylon turn
const MUSIC_BED: String = "res://audio/music/music1.wav"   # loops; Audio owns the level
const AMBIENCE_BED: String = "res://audio/ambience/ghost_town.wav"   # ghost-town bed
const HUD_FONT: String = "res://fonts/inversionz_unboxed.ttf"   # Inversionz Unboxed, Darrell Flood

# --- Phase 01: living units. [glb, thermal key, scale to ~1.8 m off the model's
# bounds]. Placeholder temps -- Grok's per-mesh maps refine them later.
const UNIT_SQUAD: Array = ["res://models/characters/ps1low_poly_night_vision_special_forces_soldier.glb", "cloth", 0.38]
const UNIT_CIV: Array   = ["res://models/characters/ps1_game_character.glb", "skin", 0.069]
const UNIT_SAN: Array   = ["res://models/characters/lowpoly_hazmat_suit_ps1_style.glb", "suit_elite", 3.21]
const ZOMBIES: Array = [
	"res://models/characters/zombie_1.glb",
	"res://models/characters/zombie_2.glb",
	"res://models/characters/zombie_3.glb",
]
const ZOMBIE_SCALE: float = 0.32
const POP_INFECTED: int = 80    # v0.19's horde count, now spread over the bigger city
const POP_CIV: int = 60         # v0.19's crowd -- warm panicked bodies to read among
const POP_SAN: int = 6          # the wipe force: rare, deadly, cool signatures (v0.19 elite = 6)
const ELEMENTS: int = 4
const ELEMENT_ROSTER: Array = [&"cdr", &"cbt", &"med", &"snp", &"rec"]   # per team; CMD leads

# --- Read of the units. FLIR flattens PS1 mesh detail to a blob at this range, so
# the role is carried by HEAT + SIZE, not the model. false = minimalist thermal
# shapes (the rymdkapsel read, matches v0.19); true = the PS1 .glb + idle rigs.
const USE_MODELS: bool = false
# Exfil LZ: a central road intersection (open ground), a ~440 m fight from the
# deploy plaza. The birds are on station at Mission.HELI_ARRIVE (120 s).
const LZ_POS: Vector2 = Vector2(372.0, 372.0)
const HELP_TEXT: String = "[LMB] pick   [drag] box-select   [RMB] move   [F] weapons free\n[TAB]/[1-4] element   [SPACE] AC-130 view   [WASD] pan   [wheel] zoom\n[T] palette   [C] snow   [H] hide"

var res_idx := 1
var snap_res: Vector2i = RESOLUTIONS[1]

var screen: TextureRect
var vp: SubViewport
var cam: Camera3D
var city: CityGen
var cars: Vehicles
var props: Node3D
var cut_rect: ColorRect
var hud: Label

var sensor_mat: ShaderMaterial
var cut_mat: ShaderMaterial
var agc := AGC.new()

var sim: WorldSim = WorldSim.new()
var views: Array[Node3D] = []          # one visual per sim unit, index-aligned
var active_element: int = 0            # which of the four teams the player is driving
var _anim: Array = []                  # an Animator per view (or null), index-aligned
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _sfx_pool: Array[AudioStreamPlayer3D] = []
var _sfx_next: int = 0
var _sfx_gun: AudioStream
var _sfx_claw: AudioStream
var _sfx_death: AudioStream
var sel_layer: Control
var drag_start: Vector2 = Vector2.ZERO
var dragging: bool = false

# mission / exfil
var mission: Mission
var lz_node: Node3D                    # LZ pad + (once on station) the bird, freed on rebuild
var bird_up: bool = false
var banner: Label                      # win / lose card, hidden until the mission ends
var help: Label
var show_help: bool = true

# feeds
const FEED: Dictionary = {
	"deploy": {"dist": 34.0, "el": 0.40, "fov": 30.0, "follow": true, "orbit": 0.0},
	"orbit":  {"dist": 640.0, "el": 0.98, "fov": 24.0, "follow": false, "orbit": 0.035},
}
var feed := "deploy"
var cam_tx := 74.0
var cam_tz := 69.0
var cam_dist := 22.0
var cam_az := -0.85
var cam_el := 0.28
var cam_manual := false                # manual pan/keys stop the follow until you re-pick a team

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
	if OS.get_environment("SPECTRE_NOMAPS") != "":
		ThermalLib.maps_on = false
	if OS.get_environment("SPECTRE_NOSNAP") != "":
		ThermalLib.snap_default = false
	_build_tree()
	_spawn()
	set_process_input(true)
	Audio.play_music(MUSIC_BED, 0.0)   # abrupt cut-in; the track has its own hard start
	Audio.play_ambience(AMBIENCE_BED, 3.0)   # ghost-town ambience swells under the mix
	_sfx_gun = load("res://audio/sfx/gun_rifle.wav")
	_sfx_claw = load("res://audio/sfx/zed_attack.wav")
	_sfx_death = load("res://audio/sfx/zed_death.wav")


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
	# 0.08/6000 gave 47 mm of depth resolution at 250 m. The road slabs were
	# 40 mm apart. Now 0.35/2200: 1.6 mm at 250 m, and nothing is coplanar anyway.
	cam.near = 0.35
	cam.far = 2200.0
	vp.add_child(cam)

	# The ear rides the optic. Combat SFX play from an AudioStreamPlayer3D pool
	# positioned at each event, so a shot across town reads as distant.
	var listener: AudioListener3D = AudioListener3D.new()
	cam.add_child(listener)
	listener.make_current()
	for _i in 16:
		var sp: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		sp.bus = "SFX"
		sp.unit_size = 6.0
		sp.max_distance = 500.0
		vp.add_child(sp)
		_sfx_pool.append(sp)

	city = CityGen.new()
	vp.add_child(city)
	city.generate(snap_res)
	cars = Vehicles.new()
	vp.add_child(cars)
	# 16 light single-mesh cars max (memory). Was 26 greybox multi-part cars.
	cars.generate(snap_res, city, 16)
	_spawn_props()

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
	hud.add_theme_font_override("font", load(HUD_FONT))
	hud.add_theme_font_size_override("font_size", 16)
	layer.add_child(hud)

	# controls card, bottom-left (v0.19's key line). Toggle with H.
	help = Label.new()
	help.add_theme_font_override("font", load(HUD_FONT))
	help.add_theme_font_size_override("font_size", 13)
	help.add_theme_color_override("font_color", Color(0.72, 0.86, 0.78, 0.85))
	help.text = HELP_TEXT
	help.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	help.offset_left = 24
	help.offset_top = -72
	help.offset_bottom = -12
	layer.add_child(help)

	# end-of-mission card, centred, hidden until WON/LOST.
	banner = Label.new()
	banner.add_theme_font_override("font", load(HUD_FONT))
	banner.add_theme_font_size_override("font_size", 40)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	banner.visible = false
	layer.add_child(banner)

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


## PS1 props, thermal-reskinned.
## 1) Diagnostic row south of deploy zone (scale / orientation check).
## 2) Scatter street props on lots/sidewalks + roof HVAC/tank on buildings.
func _spawn_props() -> void:
	props = Node3D.new()
	props.name = "Props"
	vp.add_child(props)
	_spawn_prop_diag_row()
	_scatter_street_props()
	_scatter_roof_props()


## Path, thermal key, uniform scale. Scales are starting guesses — tune in feed.
const PROP_CATALOG: Dictionary = {
	"barrel": ["res://models/buildings and scenery/ps1_barrel.glb", "tank", 0.45],
	"dumpster": ["res://models/buildings and scenery/low_poly_psxps2_trash_filled_metal_dumpster.glb", "body_cold", 0.68],
	"dumpster_set": ["res://models/buildings and scenery/psx_style_dumpster_set.glb", "body_cold", 0.70],
	"trash": ["res://models/buildings and scenery/trash_container.glb", "body_cold", 1.00],
	"jerry": ["res://models/buildings and scenery/psx_jerry_can.glb", "tank", 0.29],
	"ac": ["res://models/buildings and scenery/psx_air_conditioner.glb", "hvac", 0.45],
	"tank": ["res://models/buildings and scenery/lowpoly_rusty_tank.glb", "tank", 0.55],
	"generator": ["res://models/buildings and scenery/emergency_power_station_ps1.glb", "hvac", 0.75],
	"stop": ["res://models/buildings and scenery/stop_sign_psx.glb", "body_cold", 1.20],
}


func _make_prop(id: String, yaw: float = 0.0) -> Node3D:
	if not PROP_CATALOG.has(id):
		return null
	var s: Array = PROP_CATALOG[id]
	return ThermalModel.spawn(s[0], s[1], snap_res, s[2], yaw, true)


func _spawn_prop_diag_row() -> void:
	var order: Array = ["barrel", "dumpster", "jerry", "ac", "tank", "generator", "trash", "stop"]
	for i in order.size():
		var prop: Node3D = _make_prop(order[i], float(i) * 0.15)
		if prop != null:
			prop.position = Vector3(58.0 + float(i) * 4.5, 0.0, 60.0)
			props.add_child(prop)


func _scatter_street_props() -> void:
	if city == null:
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = city.seed_value + 91
	# Keep street clutter light: draw calls + GLB instances add up on low-end GPUs.
	var kinds: Array = ["barrel", "dumpster", "jerry", "trash", "generator"]
	var n: int = mini(12, city.buildings.size())
	for i in n:
		if city.buildings.is_empty():
			break
		var b: Dictionary = city.buildings[rng.randi() % city.buildings.size()]
		# kerb / alley: just outside the footprint
		var side: int = rng.randi() % 4
		var x: float = b["x"] + b["w"] * 0.5
		var z: float = b["z"] + b["d"] * 0.5
		var pad: float = 1.2 + rng.randf() * 1.5
		match side:
			0: z = b["z"] - pad
			1: z = b["z"] + b["d"] + pad
			2: x = b["x"] - pad
			_: x = b["x"] + b["w"] + pad
		x += rng.randf_range(-1.5, 1.5)
		z += rng.randf_range(-1.5, 1.5)
		var id: String = kinds[rng.randi() % kinds.size()]
		var prop: Node3D = _make_prop(id, rng.randf() * TAU)
		if prop != null:
			prop.position = Vector3(x, 0.0, z)
			props.add_child(prop)


func _scatter_roof_props() -> void:
	if city == null:
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = city.seed_value + 17
	for b in city.buildings:
		var h: float = float(b["fl"]) * CityGen.FLOOR_H
		# Fewer roof instances: still the warm HVAC tell, lower mesh count.
		if rng.randf() > 0.45:
			var ac: Node3D = _make_prop("ac", rng.randf() * TAU)
			if ac != null:
				var ax: float = b["x"] + b["w"] * rng.randf_range(0.25, 0.75)
				var az: float = b["z"] + b["d"] * rng.randf_range(0.25, 0.75)
				ac.position = Vector3(ax, h + 0.9, az)
				props.add_child(ac)
		if rng.randf() < 0.18:
			var tk: Node3D = _make_prop("tank", rng.randf() * TAU)
			if tk != null:
				tk.position = Vector3(
					b["x"] + b["w"] * rng.randf_range(0.55, 0.85),
					h + 0.9,
					b["z"] + b["d"] * rng.randf_range(0.55, 0.85))
				props.add_child(tk)


func _spawn() -> void:
	if lz_node != null:
		lz_node.queue_free()
		lz_node = null
	bird_up = false
	sim = WorldSim.new()
	var obstacles: Array[Rect2] = city.building_rects()
	if cars != null:
		obstacles.append_array(cars.rects)     # semis block; the rest you walk around
	sim.load_buildings(obstacles)
	# four elements, staged in a 2x2 on the deploy plaza. CMD leads each; all one faction.
	for e in ELEMENTS:
		var base: Vector2 = Vector2(64.0 + float(e % 2) * 10.0, 62.0 + float(e / 2) * 10.0)
		for j in ELEMENT_ROSTER.size():
			var p: Vector2 = base + Vector2(float(j % 3) * 1.4, float(j / 3) * 1.4)
			sim.spawn(p, ELEMENT_ROSTER[j], WorldSim.SQUAD, e)
	sim.populate(POP_INFECTED, POP_CIV, POP_SAN)   # the horde, the crowd, the hunters
	# exfil objective: cross the city to the LZ, hold until the birds land at 120 s.
	mission = Mission.new()
	var span: float = float(city.grid_n) * (CityGen.BLOCK + CityGen.STREET)
	mission.setup(LZ_POS, Vector2(-30, -30), Vector2(span + 30, span + 30), ELEMENTS)
	_build_lz()
	# one visual per sim unit, index-aligned with the sim arrays.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	for i in sim.count():
		var v: Node3D = _make_unit_view(sim.team[i], rng)
		if v != null:
			v.position = Vector3(sim.pos[i].x, 0.0, sim.pos[i].y)
			vp.add_child(v)
		views.append(v)
		_anim.append(Animator.new(v, _rng) if v != null else null)
	_select_element(active_element)


## The exfil pad: a warm painted square on the deck -- a thermal landmark you can
## read from across the city. The bird itself sets down only once on station.
func _build_lz() -> void:
	lz_node = Node3D.new()
	lz_node.name = "LZ"
	vp.add_child(lz_node)
	var pad: MeshInstance3D = MeshInstance3D.new()
	var pm: PlaneMesh = PlaneMesh.new()
	pm.size = Vector2(Mission.LZ_RADIUS * 2.0, Mission.LZ_RADIUS * 2.0)
	pad.mesh = pm
	pad.position = Vector3(LZ_POS.x, 0.06, LZ_POS.y)   # just over the road, never coplanar
	pad.material_override = ThermalLib.get_material("road", snap_res)
	lz_node.add_child(pad)


## The bird lands: a tandem-rotor fuselage (engine-hot) with two hotter nacelles.
## A hard, bright signature over the pad that says "board here, now."
func _land_bird() -> void:
	bird_up = true
	if lz_node == null:
		return
	var body: MeshInstance3D = MeshInstance3D.new()
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(3.0, 2.2, 12.0)     # nose-to-ramp fuselage
	body.mesh = bm
	body.position = Vector3(LZ_POS.x, 1.3, LZ_POS.y)
	body.material_override = ThermalLib.get_material("hvac", snap_res)
	lz_node.add_child(body)
	for dz in [-4.2, 4.2]:                 # forward + aft engine, hottest points
		var eng: MeshInstance3D = MeshInstance3D.new()
		var em: BoxMesh = BoxMesh.new()
		em.size = Vector3(3.2, 1.0, 2.4)
		eng.mesh = em
		eng.position = Vector3(LZ_POS.x, 2.6, LZ_POS.y + dz)
		eng.material_override = ThermalLib.get_material("exhaust", snap_res)
		lz_node.add_child(eng)


## Build the visual for one sim unit. Returns null for an unknown team (still kept
## in the array, for index alignment). Dispatches to a minimalist thermal shape
## (default) or the PS1 model, per USE_MODELS.
func _make_unit_view(team: int, rng: RandomNumberGenerator) -> Node3D:
	return _make_unit_model(team, rng) if USE_MODELS else _make_unit_shape(team)


## Minimalist thermal body -- the mesh never betrays the role, HEAT and SIZE do.
## Coldest/dimmest to hottest/brightest: infected 17.5 C (squat cool blob),
## sanitation 21.5 C (tall broad cool pillar -- insulated, deliberate), squad 27 C
## (warm upright), civilian 33.5 C (small bright panicked speck). One mesh, no rig.
func _make_unit_shape(team: int) -> Node3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var key: String = "cloth"
	match team:
		WorldSim.SQUAD:
			var c: CapsuleMesh = CapsuleMesh.new()
			c.height = 1.8
			c.radius = 0.34
			mi.mesh = c
			mi.position.y = 0.9
			key = "cloth"
		WorldSim.INFECTED:
			var s: SphereMesh = SphereMesh.new()
			s.radius = 0.5
			s.height = 1.1
			mi.mesh = s
			mi.position.y = 0.55
			key = "zed"
		WorldSim.CIVILIAN:
			var c2: CapsuleMesh = CapsuleMesh.new()
			c2.height = 1.6
			c2.radius = 0.24
			mi.mesh = c2
			mi.position.y = 0.8
			key = "skin"
		WorldSim.SANITATION:
			var c3: CapsuleMesh = CapsuleMesh.new()
			c3.height = 2.15
			c3.radius = 0.46
			mi.mesh = c3
			mi.position.y = 1.075
			key = "suit_elite"
		_:
			return null
	mi.material_override = ThermalLib.get_material(key, snap_res)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var root: Node3D = Node3D.new()
	root.add_child(mi)
	return root


## The PS1 path: the right model, thermal-reskinned, scaled to human height,
## ground-aligned. Rigged models get a looping idle (see Animator) so they read as
## alive. Kept behind USE_MODELS; the shapes are the shipping read.
func _make_unit_model(team: int, rng: RandomNumberGenerator) -> Node3D:
	var path: String = ""
	var mat: String = ""
	var scale: float = 1.0
	match team:
		WorldSim.SQUAD:
			path = UNIT_SQUAD[0]
			mat = UNIT_SQUAD[1]
			scale = UNIT_SQUAD[2]
		WorldSim.INFECTED:
			path = ZOMBIES[rng.randi() % ZOMBIES.size()]
			mat = "zed"
			scale = ZOMBIE_SCALE
		WorldSim.CIVILIAN:
			path = UNIT_CIV[0]
			mat = UNIT_CIV[1]
			scale = UNIT_CIV[2]
		WorldSim.SANITATION:
			path = UNIT_SAN[0]
			mat = UNIT_SAN[1]
			scale = UNIT_SAN[2]
		_:
			return null
	return ThermalModel.spawn(path, mat, snap_res, scale, 0.0, true)


## The sim owns position + heading; the view owns nothing but where it stands.
func _sync_visuals(delta: float) -> void:
	for i in views.size():
		var v: Node3D = views[i]
		if v == null:
			continue
		if not sim.alive[i]:
			v.visible = false
			continue
		v.position = Vector3(sim.pos[i].x, 0.0, sim.pos[i].y)
		# Godot models face -Z; a heading theta points forward at (-sin, 0, -cos).
		var vel: Vector2 = sim.vel[i]
		if vel.length_squared() > 0.04:
			v.rotation.y = atan2(-vel.x, -vel.y)
		if _anim[i] != null:
			_anim[i].update(vel.length_squared() > 0.09, delta, _rng)


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


## Any world point -> window pixels. The sel overlay lives in window space but the
## camera sits in the 640x360 SubViewport, so rescale by win / snap_res.
func _screen_point(world: Vector3) -> Vector2:
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	return cam.unproject_position(world) * (win / Vector2(snap_res))


## The camera holds on the ACTIVE element -- the centroid of its living units,
## else its last mark.
func _follow_point() -> Vector3:
	var sum: Vector2 = Vector2.ZERO
	var n: int = 0
	for i in sim.count():
		if sim.element[i] == active_element and sim.alive[i]:
			sum += sim.pos[i]
			n += 1
	if n > 0:
		return Vector3(sum.x / float(n), 0.0, sum.y / float(n))
	return Vector3(cam_tx, 0.0, cam_tz)


## Turn the sim's per-tick combat log into positional sound at each event's spot.
func _drain_audio() -> void:
	for e in sim.events:
		var at: Vector3 = Vector3(e["pos"].x, 1.0, e["pos"].y)
		match e["kind"]:
			"gunfire":
				_sfx_at(at, _sfx_gun)
			"claw":
				_sfx_at(at, _sfx_claw)
			"zed_death":
				_sfx_at(at, _sfx_death)
			"man_down":
				Audio.comms("need_backup", 2500)


func _sfx_at(at: Vector3, stream: AudioStream) -> void:
	if stream == null or _sfx_pool.is_empty():
		return
	var p: AudioStreamPlayer3D = _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_pool.size()
	p.stream = stream
	p.position = at
	p.play()


func _process(delta: float) -> void:
	frame_n += 1.0
	if _shot_dir != "":
		_maybe_capture()
	if not _auto_fired and frame_n > INTRO_HOLD * 60.0:
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
	_drain_audio()

	if mission != null:
		var was: int = mission.result
		mission.update(sim, delta)
		if mission.helo_on_station() and not bird_up:
			_land_bird()
			# (drop an "exfil_inbound" clip into audio/comms/ to voice this beat)
		if was == Mission.ONGOING and mission.result != Mission.ONGOING:
			_show_banner(mission.result == Mission.WON)

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

	# WASD / arrows pan the map and drop the follow until you re-pick a team.
	var mv: Vector2 = Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)))
	if mv != Vector2.ZERO:
		cam_manual = true
		var s: float = cam_dist * 0.9 * delta
		var fwd: Vector2 = Vector2(cos(cam_az), sin(cam_az))    # into the screen
		var rgt: Vector2 = Vector2(-sin(cam_az), cos(cam_az))
		cam_tx += (rgt.x * mv.x + fwd.x * mv.y) * s
		cam_tz += (rgt.y * mv.x + fwd.y * mv.y) * s

	var f: Dictionary = FEED[feed]
	if f.follow and not cam_manual:
		var c: Vector3 = _follow_point()
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
		hud.text = "%s\n\nFEED  %s\nELMT  %d/%d   WPN %s\nMODE  %s\nRES   %dx%d\nALT   %d M   SLANT %d M\nAGC   %s %.3f/%.3f\nFPS   %d" % [
			_mission_line(),
			"AC-130 / PYLON TURN" if feed == "orbit" else "ELEMENT / GROUND",
			active_element + 1, ELEMENTS, ("FREE" if sim.weapons_free else "HOLD"),
			names[mode], snap_res.x, snap_res.y,
			int(cam.position.y), int(cam_dist),
			"FROZEN" if agc.frozen else "AUTO", agc.lo, agc.hi,
			Engine.get_frames_per_second()]


## The exfil status line: the clock while inbound, "LZ OPEN" once the bird's down,
## then a per-element tally (OUT / LIFTED / ESCAPED / LOST).
func _mission_line() -> String:
	if mission == null:
		return ""
	var head: String
	if mission.result == Mission.WON:
		head = "MISSION COMPLETE  //  ELEMENTS CLEAR"
	elif mission.result == Mission.LOST:
		head = "MISSION FAILED  //  ELEMENTS LOST"
	elif mission.helo_on_station():
		head = "EXFIL  LZ OPEN -- BOARD NOW"
	else:
		var trem: int = int(ceil(maxf(0.0, Mission.HELI_ARRIVE - mission.t)))
		head = "EXFIL  BIRDS INBOUND  T-%d:%02d" % [trem / 60, trem % 60]
	var tags: Array = ["OUT", "LIFTED", "ESCAPED", "LOST"]
	var tally: String = ""
	for e in mission.n_elements:
		tally += "  %d:%s" % [e + 1, tags[mission.status[e]]]
	return head + "\nTEAMS" + tally


func _show_banner(won: bool) -> void:
	if banner == null:
		return
	banner.text = "MISSION COMPLETE" if won else "MISSION FAILED"
	banner.add_theme_color_override("font_color", Color(0.55, 1.0, 0.65) if won else Color(1.0, 0.5, 0.42))
	banner.visible = true


const SEL_COL: Color = Color(0.62, 0.88, 0.70, 0.85)

func _draw_selection() -> void:
	if cut_t >= 0.0:
		return                      # the overlay generator rides the same signal
	for i in sim.count():
		if not sim.alive[i] or not sim.selected[i]:
			continue
		var p: Vector2 = _screen_of(i)
		var r: float = 14.0
		var arm: float = 8.0
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var a: Vector2 = p + c * r
			sel_layer.draw_line(a, a - Vector2(c.x * arm, 0), SEL_COL, 2.0)
			sel_layer.draw_line(a, a - Vector2(0, c.y * arm), SEL_COL, 2.0)
		if sim.has_order[i]:
			var t: Vector2 = cam.unproject_position(Vector3(sim.target[i].x, 0.1, sim.target[i].y))
			var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
			t *= win / Vector2(snap_res)
			sel_layer.draw_line(p, t, Color(SEL_COL.r, SEL_COL.g, SEL_COL.b, 0.35), 1.5)
	if dragging:
		var m: Vector2 = get_viewport().get_mouse_position()
		sel_layer.draw_rect(Rect2(drag_start, m - drag_start), SEL_COL, false, 1.0)
	_draw_lz()


## The exfil LZ, ringed on the deck: amber while the birds are inbound, green once
## they're down. Skipped when the pad is behind the optic.
func _draw_lz() -> void:
	if mission == null or mission.result != Mission.ONGOING:
		return
	var centre_w: Vector3 = Vector3(LZ_POS.x, 0.1, LZ_POS.y)
	if cam.is_position_behind(centre_w):
		return
	var c: Vector2 = _screen_point(centre_w)
	var edge: Vector2 = _screen_point(Vector3(LZ_POS.x + Mission.LZ_RADIUS, 0.1, LZ_POS.y))
	var rad: float = maxf(6.0, c.distance_to(edge))
	var open: bool = mission.helo_on_station()
	var col: Color = Color(0.5, 1.0, 0.6, 0.9) if open else Color(1.0, 0.78, 0.3, 0.7)
	sel_layer.draw_arc(c, rad, 0.0, TAU, 48, col, 2.0)
	sel_layer.draw_string(ThemeDB.fallback_font, c + Vector2(rad + 5.0, 4.0), "LZ", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)


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


## Element command: pick which of the four teams you're driving -- selection and
## the follow-cam both track it.
func _pick_element(e: int) -> void:
	active_element = clampi(e, 0, ELEMENTS - 1)
	_select_element(active_element)
	cam_manual = false                  # snap the follow-cam back onto the picked team


func _select_element(e: int) -> void:
	for i in sim.count():
		sim.selected[i] = sim.alive[i] and sim.element[i] == e


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
		# pull the pylon turn back over the middle of the whole city
		var span: float = float(city.grid_n) * (CityGen.BLOCK + CityGen.STREET)
		cam_tx = span * 0.5
		cam_tz = span * 0.5
		cam_az = -1.05


func _input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_MIDDLE or (e.button_mask & MOUSE_BUTTON_MASK_LEFT and Input.is_key_pressed(KEY_SHIFT))):
		if Input.is_key_pressed(KEY_CTRL):
			cam_manual = true
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
			cam_dist = clampf(cam_dist * 0.9, ZOOM_MIN, ZOOM_MAX)
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = clampf(cam_dist * 1.1, ZOOM_MIN, ZOOM_MAX)
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
				if not sim.selected_ids().is_empty():
					Audio.comms("ack_affirmative", 2500)   # "affirmative" on select
		elif e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
			var ids: Array = sim.selected_ids()
			if not ids.is_empty():
				sim.order_move(ids, _ground_pick(e.position))
				Audio.comms_order()   # squad acks the move over the net
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_SPACE: _channel_change("orbit" if feed == "deploy" else "deploy")
			KEY_T: mode = (mode + 1) % 3
			KEY_C: cctv = 0.0 if cctv > 0.0 else 0.85
			KEY_G: agc.frozen = not agc.frozen
			KEY_O: orbit_auto = not orbit_auto
			KEY_H:
				show_help = not show_help
				if help != null:
					help.visible = show_help
			KEY_F:
				sim.weapons_free = not sim.weapons_free
				Audio.comms("open_fire" if sim.weapons_free else "hold_fire", 0)
			KEY_TAB: _pick_element((active_element + 1) % ELEMENTS)
			KEY_1: _pick_element(0)
			KEY_2: _pick_element(1)
			KEY_3: _pick_element(2)
			KEY_4: _pick_element(3)
			KEY_M:
				ThermalLib.maps_on = not ThermalLib.maps_on
				ThermalLib.clear_cache()
				_rebuild_world()
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
	if props != null:
		props.queue_free()
	for v in views:
		if v != null:
			v.queue_free()
	views.clear()
	_anim.clear()
	await get_tree().process_frame
	city = CityGen.new()
	vp.add_child(city)
	city.generate(snap_res)
	cars = Vehicles.new()
	vp.add_child(cars)
	cars.generate(snap_res, city, 16)
	_spawn_props()
	_spawn()


## Drives a rigged unit's clips. Walk when moving, idle when stopped; the infected
## (which carry damage/die/climb/bite clips) also throw the odd one-shot -- a
## convulse, a lunge, or a full collapse-and-rise -- so the horde shambles, heaves,
## and falls about instead of gliding in one frozen pose. Non-infected just walk
## and idle (no fidget clips to draw from).
class Animator extends RefCounted:
	var ap: AnimationPlayer
	var walk: String = ""
	var idle: String = ""
	var fall: String = ""      # DieZ  -- collapse
	var rise: String = ""      # ClimbGraveZ -- struggle back up
	var fidgets: Array = []    # convulse / lunge one-shots
	var t: float = 0.0
	var busy: bool = false

	func _init(node: Node3D, rng: RandomNumberGenerator) -> void:
		ap = node.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if ap == null:
			return
		var clips: PackedStringArray = ap.get_animation_list()
		walk = _pick(clips, ["walk"])
		idle = _pick(clips, ["idle", "default", "pose"])
		fall = _pick(clips, ["die", "death"])
		rise = _pick(clips, ["climb"])
		for key in ["damage", "grabbite", "bite", "howl", "taunt"]:
			var c: String = _pick(clips, [key])
			if c != "" and not fidgets.has(c):
				fidgets.append(c)
		if walk == "" and idle == "" and clips.size() > 0:
			idle = String(clips[0])
		for c in [walk, idle]:
			if c != "":
				ap.get_animation(c).loop_mode = Animation.LOOP_LINEAR
		t = rng.randf_range(2.0, 7.0)

	func update(moving: bool, dt: float, rng: RandomNumberGenerator) -> void:
		if ap == null:
			return
		if busy:
			if ap.is_playing():
				return
			busy = false
		if moving:
			_loop(walk if walk != "" else idle)
			return
		t -= dt
		if t > 0.0:
			_loop(idle if idle != "" else walk)
			return
		t = rng.randf_range(4.0, 10.0)
		if fall != "" and rise != "" and rng.randf() < 0.3:
			ap.get_animation(fall).loop_mode = Animation.LOOP_NONE
			ap.get_animation(rise).loop_mode = Animation.LOOP_NONE
			ap.play(fall)
			ap.queue(rise)
			busy = true
		elif not fidgets.is_empty():
			var c: String = fidgets[rng.randi() % fidgets.size()]
			ap.get_animation(c).loop_mode = Animation.LOOP_NONE
			ap.play(c)
			busy = true

	func _loop(clip: String) -> void:
		if clip != "" and ap.current_animation != clip:
			ap.play(clip)

	static func _pick(clips: PackedStringArray, keys: Array) -> String:
		for k in keys:
			for c in clips:
				if String(c).to_lower().contains(k):
					return String(c)
		return ""
