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
const ZOOM_MIN: float = 150.0         # closest: a clustered force still fits the screen at once
const ZOOM_MAX: float = 1650.0        # farthest: the whole peninsula frames; ocean, never void, beyond
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
const POP_INFECTED: int = 70    # ambient horde, spread over the ~806 m city
const POP_CIV: int = 55         # the crowd -- warm panicked bodies to read among
const POP_SAN: int = 6          # the wipe force: rare, deadly, cool signatures (v0.19 elite = 6)
# The wider ecology -- cheap now that units are shapes. Counts span the whole city.
const POP_RUNNERS: int = 22     # fast, fragile infected mixed through the horde
const POP_BRUTES: int = 10      # slow, tanky infected
const BANDIT_CREWS: int = 5     # roaming armed crews...
const BANDIT_PER_CREW: int = 5
const SURVIVOR_HOLDOUTS: int = 6   # dug-in armed holdouts...
const SURVIVOR_PER_HOLDOUT: int = 3
const GAUNTLET_PER_BRIDGE: int = 44   # infected choking each bridge deck
const ELEMENTS: int = 4
const ELEMENT_ROSTER: Array = [&"cdr", &"cbt", &"med", &"snp", &"rec"]   # per team; CMD leads

# --- Read of the units. FLIR flattens PS1 mesh detail to a blob at this range, so
# the role is carried by HEAT + SIZE, not the model. false = minimalist thermal
# shapes (the rymdkapsel read, matches v0.19); true = the PS1 .glb + idle rigs.
const USE_MODELS: bool = false
const HELP_TEXT: String = "[LMB] pick   [RMB] move   [F] weapons free   [V] AC-130 strike\n[TAB]/[1-4] element   [SPACE] AC-130 view   [WASD] pan   [wheel] zoom\n[T] palette   [C] snow   [H] hide      EXFIL: cross a bridge on foot"

# AC-130 gunship ISR HUD palette
const HUD_COL: Color = Color(0.74, 0.95, 0.80, 0.90)   # ISR green-white
const HUD_DIM: Color = Color(0.74, 0.95, 0.80, 0.42)
const HUD_RED: Color = Color(1.00, 0.34, 0.28, 0.95)   # threat / alert

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
var banner: Label                      # win / lose card, hidden until the mission ends
var help: Label
var show_help: bool = true

# AC-130 HUD + touch
var _touch_bar: Control                # on-screen control bar (mobile); null until built
var _kills: int = 0                    # confirmed hostile kills, for the threat readout
var _touches: Dictionary = {}          # active touch index -> position
var _touch_moved: float = 0.0          # primary-touch travel, to tell a tap from a drag
var _pinch_prev: float = 0.0           # last two-finger spread, for pinch-zoom

# AC-130 fire support -- a kill-charged boresight strike (v0.19's killstreak)
const AC_COST: int = 14                # kills to arm one fire mission
const STRIKE_R: float = 16.0           # kill radius, metres
const STRIKE_DMG: float = 460.0        # one burst flattens even the Sanitation elite
var _ac_charge: int = 0                # kills banked toward the next strike
var _fire_req: bool = false            # a strike was requested this frame
var _strike_pos: Vector2 = Vector2.ZERO
var _strike_t: float = 999.0           # seconds since the last strike, for the impact FX
var _flashes: Array = []               # muzzle flashes: [{pos: Vector2, t: float}], newest last
const FLASH_LIFE: float = 0.12         # seconds a muzzle flash stays lit
const FLASH_MAX: int = 80              # cap, so a big firefight can't flood the overlay

# feeds
const FEED: Dictionary = {
	"deploy": {"dist": 240.0, "el": 0.90, "fov": 40.0, "follow": true, "orbit": 0.0},
	"orbit":  {"dist": 1500.0, "el": 1.25, "fov": 40.0, "follow": false, "orbit": 0.015},
}
var feed := "deploy"
var cam_tx := 300.0
var cam_tz := 470.0
var cam_dist := 240.0
var cam_az := -0.85
var cam_el := 0.90
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
var _map_dir: String = OS.get_environment("SPECTRE_MAP")   # set to grab one whole-map PNG, then quit

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
	_init_res()                    # frame the feed to the window we were opened with
	_build_tree()
	_spawn()
	get_window().size_changed.connect(_reframe)   # ...and re-frame if it changes / rotates
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
	# The optic never sits below ZOOM_MIN (~150 m out), so nothing is ever within
	# ~100 m of the lens. A near of 6 m (vs 0.35) buys far better depth precision at
	# the max-zoom altitude, so the 1.5 m coast step never z-fights the ocean.
	cam.near = 6.0
	cam.far = 2600.0
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

	_build_touch_bar(layer)

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


## The detector array reshapes to the WINDOW: a fixed vertical resolution (the R
## key cycles it) and a width that follows the window aspect, so the thermal feed
## fills any screen -- landscape desktop or portrait phone -- without letterboxing
## or stretch. This is v0.19's frame-to-the-interface behaviour.
func _init_res() -> void:
	var win: Vector2i = get_window().size
	if win.x <= 0 or win.y <= 0:
		return
	var aspect: float = float(win.x) / float(win.y)
	var base_h: int = RESOLUTIONS[res_idx].y
	snap_res = Vector2i(maxi(160, int(round(float(base_h) * aspect))), base_h)


func _push_res() -> void:
	vp.size = snap_res
	if screen != null:
		screen.texture = vp.get_texture()
	sensor_mat.set_shader_parameter("res", Vector2(snap_res))
	cut_mat.set_shader_parameter("res", Vector2(snap_res))
	ThermalLib.clear_cache()   # snap_res is baked into every material


## Window resized or the device rotated: reshape the feed + re-lay the controls.
## Light -- no world rebuild (the meshes keep their materials; only the detector
## grid + HUD layout follow the new frame).
func _reframe() -> void:
	if vp == null:
		return
	_init_res()
	vp.size = snap_res
	if screen != null:
		screen.texture = vp.get_texture()
	sensor_mat.set_shader_parameter("res", Vector2(snap_res))
	cut_mat.set_shader_parameter("res", Vector2(snap_res))
	_layout_controls()


## Re-lay the on-screen touch controls for the current window/orientation. The
## drawn HUD anchors itself; only the touch bar needs re-placing.
func _layout_controls() -> void:
	_place_touch_bar()


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
	sim = WorldSim.new()
	var walls: Array[Rect2] = city.building_rects()
	if cars != null:
		walls.append_array(cars.rects)     # semis block; the rest you walk around
	# walls block LOS + nav; the land polygon is the coastline (ocean outside);
	# bridge decks are slowed gaps the nav carves through the water.
	sim.load_map(walls, city.water, city.bridges, city.map_lo, city.map_hi, city.land_poly)
	# four elements, staged in a 2x2 in the west-central city (Ocean Beach side);
	# the exfil bridges are north (Golden Gate) and east (Bay) -- a real traverse.
	for e in ELEMENTS:
		var base: Vector2 = Vector2(300.0 + float(e % 2) * 16.0, 470.0 + float(e / 2) * 16.0)
		for j in ELEMENT_ROSTER.size():
			var p: Vector2 = base + Vector2(float(j % 3) * 1.4, float(j / 3) * 1.4)
			sim.spawn(p, ELEMENT_ROSTER[j], WorldSim.SQUAD, e)
	_populate_world()
	# the only way off the peninsula is on foot across a bridge (city.escapes).
	mission = Mission.new()
	mission.setup(city.escapes, ELEMENTS)
	# one visual per sim unit, index-aligned with the sim arrays.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	for i in sim.count():
		var v: Node3D = _make_unit_view(sim.team[i], sim.kind[i], rng)
		if v != null:
			v.position = Vector3(sim.pos[i].x, 0.0, sim.pos[i].y)
			vp.add_child(v)
		views.append(v)
		_anim.append(Animator.new(v, _rng) if v != null else null)
	_select_element(active_element)


## Seed the whole ecology: the ambient horde + crowd + sanitation on the land, a
## mix of zombie variants, roaming bandit crews, dug-in survivor holdouts, and a
## dense infected gauntlet choking each bridge deck.
func _populate_world() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	sim.populate(POP_INFECTED, POP_CIV, POP_SAN, city.land)   # ambient zed/civ/san on land
	sim.scatter(&"run", WorldSim.INFECTED, POP_RUNNERS, city.land, rng)
	sim.scatter(&"bru", WorldSim.INFECTED, POP_BRUTES, city.land, rng)
	for _c in BANDIT_CREWS:
		sim.spawn_cluster(&"bnd", WorldSim.BANDIT, _random_land_point(rng), BANDIT_PER_CREW, 6.0, rng)
	for _h in SURVIVOR_HOLDOUTS:
		sim.spawn_cluster(&"svr", WorldSim.SURVIVOR, _random_land_point(rng), SURVIVOR_PER_HOLDOUT, 4.0, rng)
	for b in city.bridges:
		sim.spawn_line(&"zed", WorldSim.INFECTED, b, GAUNTLET_PER_BRIDGE, rng)   # the choked deck


func _random_land_point(rng: RandomNumberGenerator) -> Vector2:
	for _try in 48:
		var p: Vector2 = Vector2(
			rng.randf_range(city.land.position.x, city.land.end.x),
			rng.randf_range(city.land.position.y, city.land.end.y))
		if Geometry2D.is_point_in_polygon(p, city.land_poly):
			return p
	return Vector2(400.0, 500.0)   # central-land fallback


## Build the visual for one sim unit. Returns null for an unknown team (still kept
## in the array, for index alignment). Dispatches to a minimalist thermal shape
## (default) or the PS1 model, per USE_MODELS.
func _make_unit_view(team: int, kind: StringName, rng: RandomNumberGenerator) -> Node3D:
	return _make_unit_model(team, rng) if USE_MODELS else _make_unit_shape(team, kind)


## Minimalist thermal body -- the mesh never betrays the role, HEAT and SIZE do.
## Coldest/dimmest to hottest/brightest: infected 17.5 C (cool blob; runner small,
## brute a big mass), sanitation 21.5 C (tall broad cool pillar), squad/bandit/
## survivor 27 C (warm upright -- told apart by the allegiance overlay, not heat),
## civilian 33.5 C (small bright panicked speck). One mesh, no rig.
func _make_unit_shape(team: int, kind: StringName) -> Node3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var key: String = "cloth"
	match team:
		WorldSim.SQUAD:
			_capsule(mi, 1.8, 0.34)
			key = "cloth"
		WorldSim.INFECTED:
			if kind == &"run":
				_sphere(mi, 0.4, 0.85)      # runner: small, quick blob
			elif kind == &"bru":
				_sphere(mi, 0.72, 1.5)      # brute: a big cool mass
			else:
				_sphere(mi, 0.5, 1.1)       # walker
			key = "zed"
		WorldSim.CIVILIAN:
			_capsule(mi, 1.6, 0.24)
			key = "skin"
		WorldSim.SANITATION:
			_capsule(mi, 2.15, 0.46)
			key = "suit_elite"
		WorldSim.BANDIT:
			_capsule(mi, 1.75, 0.33)        # lean armed human
			key = "cloth"
		WorldSim.SURVIVOR:
			_capsule(mi, 1.78, 0.35)        # dug-in armed human
			key = "cloth"
		_:
			return null
	mi.material_override = ThermalLib.get_material(key, snap_res)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var root: Node3D = Node3D.new()
	root.add_child(mi)
	return root


func _capsule(mi: MeshInstance3D, h: float, r: float) -> void:
	var c: CapsuleMesh = CapsuleMesh.new()
	c.height = h
	c.radius = r
	mi.mesh = c
	mi.position.y = h * 0.5


func _sphere(mi: MeshInstance3D, r: float, h: float) -> void:
	var s: SphereMesh = SphereMesh.new()
	s.radius = r
	s.height = h
	mi.mesh = s
	mi.position.y = h * 0.5


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
				if _flashes.size() < FLASH_MAX:
					_flashes.append({"pos": e["pos"], "t": 0.0})
			"claw":
				_sfx_at(at, _sfx_claw)
			"zed_death":
				_sfx_at(at, _sfx_death)
				_score_kill()
			"kill":
				if e["team"] != WorldSim.CIVILIAN:
					_score_kill()
			"strike":
				_sfx_at(at, _sfx_gun)   # placeholder cannon burst -- drop a GAU sfx in audio/sfx
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


func _score_kill() -> void:
	_kills += 1
	_ac_charge = mini(AC_COST, _ac_charge + 1)


## Request an AC-130 fire mission (if armed). Fired next frame, on the boresight.
func _request_strike() -> void:
	if _ac_charge >= AC_COST:
		_fire_req = true


## Call the strike on the optic boresight (the camera target). Everything in the
## ring dies -- friendly fire included, so slew off your own squad first.
func _fire_ac130() -> void:
	if _ac_charge < AC_COST:
		return
	_ac_charge = 0
	_strike_pos = Vector2(cam_tx, cam_tz)
	_strike_t = 0.0
	sim.air_strike(_strike_pos, STRIKE_R, STRIKE_DMG)
	Audio.comms("open_fire", 0)


func _process(delta: float) -> void:
	frame_n += 1.0
	if int(frame_n) == 3:
		_layout_controls()   # re-place the touch bar once the viewport size has settled
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
	if _fire_req:
		_fire_req = false
		_fire_ac130()          # appends strike + kill events for the drain below
	_sync_visuals(delta)
	_drain_audio()
	_strike_t += delta
	_age_flashes(delta)

	if mission != null:
		var was: int = mission.result
		mission.update(sim, delta)
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

	# bound the optic to the map (+ its ocean margin) and to the zoom band, so the
	# view never leaves the peninsula for the void, never zooms out past the coast,
	# and never zooms in past a clustered force.
	if city != null:
		cam_tx = clampf(cam_tx, city.map_lo.x, city.map_hi.x)
		cam_tz = clampf(cam_tz, city.map_lo.y, city.map_hi.y)
	cam_dist = clampf(cam_dist, ZOOM_MIN, ZOOM_MAX)

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

	if _map_dir != "":
		_map_overview()


## SPECTRE_MAP=<dir>: override the optic to a near-top-down frame of the WHOLE map
## (land + water + both bridges), then grab a single PNG and quit. A dev capture
## hook; no effect on normal play.
func _map_overview() -> void:
	if city == null:
		return
	mode = 0          # WHT HOT: bright warm land, dark cold water
	cctv = 0.0        # no monitor snow, for a clean map
	# flatten the detector look so fine geography survives the wide framing --
	# bloom especially floods the whole sheet bright from this altitude.
	sensor_mat.set_shader_parameter("bloom", 0.0)
	sensor_mat.set_shader_parameter("noise_amt", 0.0)
	sensor_mat.set_shader_parameter("fpn_amt", 0.0)
	sensor_mat.set_shader_parameter("vignette", 0.0)
	sensor_mat.set_shader_parameter("dither", false)
	var cx: float = city.land.get_center().x        # centre on the peninsula, not the bbox
	var cz: float = city.land.get_center().y
	var span: float = maxf(city.map_hi.x - city.map_lo.x, city.map_hi.y - city.map_lo.y)
	var h: float = span * 1.1
	# bracket near/far TIGHTLY around the ground -- a wide range at this altitude
	# z-fights the water plane against the dirt bed beneath it (dirt bleeds through
	# warm). Tight planes restore depth precision so cold water reads cold.
	cam.near = h * 0.65
	cam.far = h * 1.6
	cam.fov = 52.0
	cam.position = Vector3(cx, h, cz + h * 0.14)     # a hair south of straight down, for depth
	cam.look_at(Vector3(cx, 0.0, cz), Vector3.UP)
	if int(frame_n) == 150:
		_grab_map(_map_dir + "/sf_map_overview.png")


func _grab_map(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(path)
		print("SPECTRE_MAP saved ", path)
	get_tree().quit()


## The exfil status line: the survival clock, then a per-element tally (OUT / CLEAR / LOST).
func _mission_line() -> String:
	if mission == null:
		return ""
	var head: String
	if mission.result == Mission.WON:
		head = "EXFIL COMPLETE  //  ELEMENTS CLEAR"
	elif mission.result == Mission.LOST:
		head = "OVERRUN  //  ALL ELEMENTS LOST"
	else:
		head = "EXFIL ON FOOT -- CROSS A BRIDGE   T+%d:%02d" % [int(mission.t) / 60, int(mission.t) % 60]
	var tags: Array = ["OUT", "CLEAR", "LOST"]
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
	_draw_hud()
	_draw_allegiance()
	_draw_flashes()
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
	_draw_escapes()


## The two bridge escape zones, ringed on the deck -- the only ways out. Green,
## labelled EXIT, wherever they fall on screen so you can steer for one.
func _draw_escapes() -> void:
	if mission == null or mission.result != Mission.ONGOING or city == null:
		return
	var col: Color = Color(0.5, 1.0, 0.6, 0.85)
	for z in city.escapes:
		var centre: Vector3 = Vector3(z.position.x + z.size.x * 0.5, 0.6, z.position.y + z.size.y * 0.5)
		if cam.is_position_behind(centre):
			continue
		var c: Vector2 = _screen_point(centre)
		var edge: Vector2 = _screen_point(centre + Vector3(maxf(z.size.x, z.size.y) * 0.5, 0.0, 0.0))
		var rad: float = clampf(c.distance_to(edge), 8.0, 70.0)
		sel_layer.draw_arc(c, rad, 0.0, TAU, 40, col, 2.0)
		sel_layer.draw_string(ThemeDB.fallback_font, c + Vector2(rad + 5.0, 4.0), "EXIT", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)


## A tiny allegiance pip over every living unit -- the v0.19 coloured-unit read, so
## warm human shapes (squad / bandit / survivor) don't all look alike on FLIR.
func _draw_allegiance() -> void:
	for i in sim.count():
		if not sim.alive[i]:
			continue
		var col: Color = _alleg_color(sim.team[i])
		if col.a <= 0.0:
			continue
		var w: Vector3 = Vector3(sim.pos[i].x, 0.9, sim.pos[i].y)
		if cam.is_position_behind(w):
			continue
		sel_layer.draw_circle(_screen_point(w), 2.5, col)


func _alleg_color(t: int) -> Color:
	match t:
		WorldSim.SQUAD: return Color(0.45, 0.95, 0.70, 0.90)      # friendly green
		WorldSim.SANITATION: return Color(1.00, 0.28, 0.28, 0.95) # apex threat, hard red
		WorldSim.BANDIT: return Color(1.00, 0.55, 0.20, 0.90)     # hostile, orange
		WorldSim.SURVIVOR: return Color(1.00, 0.85, 0.35, 0.90)   # wary, amber
		WorldSim.INFECTED: return Color(0.65, 0.45, 0.80, 0.70)   # horde, dim violet
		WorldSim.CIVILIAN: return Color(0.85, 0.88, 0.95, 0.55)   # neutral, pale
	return Color(0, 0, 0, 0)


## The AC-130 gunship ISR HUD: corner targeting brackets, a gapped centre reticle
## with range ticks + pipper, a rotating cardinal compass, the slant range, and a
## red threat box (living hostiles + kills). Window space, over the feed.
func _draw_hud() -> void:
	var font: Font = ThemeDB.fallback_font
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var c: Vector2 = win * 0.5
	var short: float = minf(win.x, win.y)

	# corner targeting brackets
	var m: float = 24.0
	var arm: float = 30.0
	for k in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		var p: Vector2 = Vector2(lerpf(m, win.x - m, k.x), lerpf(m, win.y - m, k.y))
		var sx: float = 1.0 if k.x < 0.5 else -1.0
		var sy: float = 1.0 if k.y < 0.5 else -1.0
		sel_layer.draw_line(p, p + Vector2(arm * sx, 0.0), HUD_DIM, 1.5)
		sel_layer.draw_line(p, p + Vector2(0.0, arm * sy), HUD_DIM, 1.5)

	# centre reticle: gapped cross, range ticks, pipper
	var gap: float = 15.0
	var reach: float = short * 0.24
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		sel_layer.draw_line(c + d * gap, c + d * reach, HUD_COL, 1.5)
		var perp: Vector2 = Vector2(-d.y, d.x)
		for t in [0.42, 0.66, 0.9]:
			var at: Vector2 = c + d * lerpf(gap, reach, t)
			sel_layer.draw_line(at - perp * 5.0, at + perp * 5.0, HUD_COL, 1.5)
	sel_layer.draw_arc(c, 5.0, 0.0, TAU, 16, HUD_COL, 1.5)

	# rotating cardinal compass on a fixed ring around the reticle
	var ring: float = short * 0.36
	var tgt: Vector3 = Vector3(cam_tx, 1.0, cam_tz)
	for card in [["N", Vector3(0, 0, -1)], ["E", Vector3(1, 0, 0)], ["S", Vector3(0, 0, 1)], ["W", Vector3(-1, 0, 0)]]:
		var wp: Vector3 = tgt + (card[1] as Vector3) * 120.0
		if cam.is_position_behind(wp):
			continue
		var dir: Vector2 = _screen_point(wp) - c
		if dir.length() < 1.0:
			continue
		sel_layer.draw_string(font, c + dir.normalized() * ring - Vector2(4.0, -5.0), card[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, HUD_COL)

	# slant range by the reticle
	sel_layer.draw_string(font, c + Vector2(reach + 8.0, 4.0), "%dM" % int(cam_dist), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HUD_COL)

	# TARGET LOCKED when the element you're driving has a foe acquired
	var locked: bool = false
	for i in sim.count():
		if sim.alive[i] and sim.element[i] == active_element and sim.foe[i] != -1:
			locked = true
			break
	if locked:
		sel_layer.draw_string(font, c + Vector2(-42.0, reach + 22.0), "TGT LOCKED", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HUD_RED)

	# AC-130 fire-mission status, bottom-left above the attitude gauge
	if _ac_charge >= AC_COST:
		sel_layer.draw_string(font, Vector2(30.0, win.y - 178.0), "AC-130 GUNSHIP  READY", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, HUD_COL)
	else:
		sel_layer.draw_string(font, Vector2(30.0, win.y - 178.0), "AC-130  ARMING  %d/%d" % [_ac_charge, AC_COST], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HUD_DIM)

	_draw_attitude(font, win)
	_draw_threat(font, win)
	_draw_strike()


## The impact FX: a hot ring blooming out from the strike point, fading over ~0.7 s.
func _draw_strike() -> void:
	if _strike_t > 0.7:
		return
	var w3: Vector3 = Vector3(_strike_pos.x, 0.5, _strike_pos.y)
	if cam.is_position_behind(w3):
		return
	var cc: Vector2 = _screen_point(w3)
	var edge: Vector2 = _screen_point(Vector3(_strike_pos.x + STRIKE_R, 0.5, _strike_pos.y))
	var rad: float = maxf(8.0, cc.distance_to(edge))
	var k: float = _strike_t / 0.7
	var fade: float = 1.0 - k
	sel_layer.draw_circle(cc, rad * (0.35 + k * 0.2), Color(1.0, 0.95, 0.82, fade * 0.8))
	sel_layer.draw_arc(cc, rad * (0.5 + k * 0.6), 0.0, TAU, 44, Color(1.0, 0.78, 0.45, fade), 3.0)


func _age_flashes(delta: float) -> void:
	var i: int = _flashes.size() - 1
	while i >= 0:
		_flashes[i]["t"] += delta
		if _flashes[i]["t"] > FLASH_LIFE:
			_flashes.remove_at(i)
		i -= 1


## Muzzle flashes: a hot pip at each shot for a few frames, so firefights read on
## the thermal feed instead of being audio-only.
func _draw_flashes() -> void:
	for f in _flashes:
		var wp: Vector2 = f["pos"]
		var w3: Vector3 = Vector3(wp.x, 1.1, wp.y)
		if cam.is_position_behind(w3):
			continue
		var sp: Vector2 = _screen_point(w3)
		var fade: float = 1.0 - float(f["t"]) / FLASH_LIFE
		var r: float = 3.0 + fade * 2.5
		# warm flash reads on bright land AND dark ocean; hot white core
		sel_layer.draw_circle(sp, r, Color(1.0, 0.60, 0.18, fade * 0.9))
		sel_layer.draw_circle(sp, r * 0.42, Color(1.0, 0.96, 0.82, fade))


## Attitude gauge, bottom-left: a heading dial with the optic azimuth pointer, the
## optic elevation, and the pylon-turn state -- the AC-130's bank/attitude circle.
func _draw_attitude(font: Font, win: Vector2) -> void:
	var gc: Vector2 = Vector2(66.0, win.y - 132.0)
	var gr: float = 27.0
	sel_layer.draw_arc(gc, gr, 0.0, TAU, 40, HUD_DIM, 1.5)
	for a in range(0, 360, 30):
		var av: Vector2 = Vector2(sin(deg_to_rad(a)), -cos(deg_to_rad(a)))
		var inner: float = gr - (8.0 if a % 90 == 0 else 4.0)
		sel_layer.draw_line(gc + av * inner, gc + av * gr, HUD_DIM, 1.5)
	var hv: Vector2 = Vector2(sin(-cam_az), -cos(-cam_az))
	sel_layer.draw_line(gc, gc + hv * (gr - 3.0), HUD_COL, 2.0)
	sel_layer.draw_circle(gc, 2.5, HUD_COL)
	var hdg: int = (int(round(rad_to_deg(-cam_az))) % 360 + 360) % 360
	sel_layer.draw_string(font, gc + Vector2(gr + 8.0, -4.0), "HDG %03d" % hdg, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, HUD_COL)
	sel_layer.draw_string(font, gc + Vector2(gr + 8.0, 12.0), "EL %02d" % int(rad_to_deg(cam_el)), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, HUD_COL)


## Red threat box (INFESTATION-style): living hostiles + confirmed kills.
func _draw_threat(font: Font, win: Vector2) -> void:
	var hostiles: int = 0
	for i in sim.count():
		if sim.alive[i] and sim.team[i] != WorldSim.SQUAD and sim.team[i] != WorldSim.CIVILIAN:
			hostiles += 1
	var w: float = 190.0
	var box: Rect2 = Rect2(win.x - w - 20.0, 18.0, w, 44.0)
	sel_layer.draw_rect(box, Color(HUD_RED.r, HUD_RED.g, HUD_RED.b, 0.12), true)
	sel_layer.draw_rect(box, HUD_RED, false, 1.5)
	sel_layer.draw_string(font, box.position + Vector2(9.0, 17.0), "INFESTATION", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, HUD_RED)
	sel_layer.draw_string(font, box.position + Vector2(9.0, 36.0), "HOSTILES %d   KILLS %d" % [hostiles, _kills], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, HUD_COL)


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
		# pull the pylon turn back over the middle of the peninsula itself
		cam_tx = city.land.get_center().x
		cam_tz = city.land.get_center().y
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
			KEY_F: _toggle_fire()
			KEY_V: _request_strike()
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
				_init_res()
				_push_res()
				_rebuild_world()
	# --- touch (mobile). One-finger drag pans, two-finger pinch zooms, and a tap
	# selects your squad's element or moves it to the tapped ground. Buttons on the
	# control bar swallow their own taps (see _over_ui).
	elif e is InputEventScreenTouch:
		if e.pressed:
			if _over_ui(e.position):
				return
			_touches[e.index] = e.position
			if _touches.size() == 1:
				_touch_moved = 0.0
			elif _touches.size() == 2:
				_pinch_prev = _two_touch_dist()
		else:
			if _touches.size() == 1 and _touch_moved < 14.0 and _touches.has(e.index):
				_tap(e.position)
			_touches.erase(e.index)
	elif e is InputEventScreenDrag:
		if not _touches.has(e.index):
			return
		_touches[e.index] = e.position
		if _touches.size() >= 2:
			var d: float = _two_touch_dist()
			if _pinch_prev > 1.0 and d > 1.0:
				cam_dist = clampf(cam_dist * (_pinch_prev / d), ZOOM_MIN, ZOOM_MAX)
			_pinch_prev = d
		else:
			_touch_moved += e.relative.length()
			cam_manual = true
			var ca: float = cos(cam_az)
			var sa: float = sin(cam_az)
			var k: float = cam_dist * 0.0022
			cam_tx += (-e.relative.x * sa - e.relative.y * ca) * k
			cam_tz += (e.relative.x * ca - e.relative.y * sa) * k


func _two_touch_dist() -> float:
	var pts: Array = _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1] as Vector2)


func _over_ui(pos: Vector2) -> bool:
	return _touch_bar != null and _touch_bar.get_global_rect().has_point(pos)


## A tap: tap your own squad to drive that element; tap open ground to move the
## element you are driving to that spot.
func _tap(pos: Vector2) -> void:
	var g: Vector2 = _ground_pick(pos)
	var best: int = -1
	var bd: float = 7.0
	for i in sim.count():
		if sim.alive[i] and sim.team[i] == WorldSim.SQUAD:
			var d: float = sim.pos[i].distance_to(g)
			if d < bd:
				bd = d
				best = i
	if best >= 0:
		_pick_element(sim.element[best])
		Audio.comms("ack_affirmative", 2500)
	elif not sim.selected_ids().is_empty():
		sim.order_move(sim.selected_ids(), g)
		Audio.comms_order()


func _toggle_fire() -> void:
	sim.weapons_free = not sim.weapons_free
	Audio.comms("open_fire" if sim.weapons_free else "hold_fire", 0)


func _toggle_feed() -> void:
	_channel_change("orbit" if feed == "deploy" else "deploy")


func _cycle_palette() -> void:
	mode = (mode + 1) % 3


## Bottom control bar for touch: element picks, weapons-free, ISR view, palette.
## Styled like the gunship HUD; works with mouse too.
func _build_touch_bar(host: CanvasLayer) -> void:
	_touch_bar = HBoxContainer.new()
	_touch_bar.add_theme_constant_override("separation", 7)
	for n in ELEMENTS:
		var b: Button = _hud_button(str(n + 1))
		b.pressed.connect(_pick_element.bind(n))
		_touch_bar.add_child(b)
	var bf: Button = _hud_button("WPN")
	bf.pressed.connect(_toggle_fire)
	_touch_bar.add_child(bf)
	var bs: Button = _hud_button("STRK")
	bs.pressed.connect(_request_strike)
	_touch_bar.add_child(bs)
	var bi: Button = _hud_button("ISR")
	bi.pressed.connect(_toggle_feed)
	_touch_bar.add_child(bi)
	var bp: Button = _hud_button("PAL")
	bp.pressed.connect(_cycle_palette)
	_touch_bar.add_child(bp)
	host.add_child(_touch_bar)
	_place_touch_bar()


func _hud_button(text: String) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(58, 46)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", load(HUD_FONT))
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", HUD_COL)
	b.add_theme_color_override("font_hover_color", HUD_COL)
	b.add_theme_color_override("font_pressed_color", Color(0.08, 0.12, 0.09))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.09, 0.06, 0.5)
	sb.border_color = Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	b.add_theme_stylebox_override("normal", sb)
	var sbp: StyleBoxFlat = sb.duplicate()
	sbp.bg_color = Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.55)
	b.add_theme_stylebox_override("hover", sbp)
	b.add_theme_stylebox_override("pressed", sbp)
	return b


func _place_touch_bar() -> void:
	if _touch_bar == null:
		return
	# canvas space, not raw window pixels -- the CanvasLayer lives in the stretched
	# logical viewport (same space the drawn HUD uses).
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	_touch_bar.reset_size()
	var sz: Vector2 = _touch_bar.get_combined_minimum_size()
	_touch_bar.size = sz
	# bottom-right (thumb reach), clear of the bottom-left keyboard card
	_touch_bar.position = Vector2(win.x - sz.x - 16.0, win.y - sz.y - 16.0)
	# the keyboard controls card is desktop-only; drop it on a portrait phone
	if help != null:
		help.visible = show_help and win.x >= win.y


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
