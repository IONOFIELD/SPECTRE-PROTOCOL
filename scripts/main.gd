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
const INTRO_HOLD: float = 4.5         # seconds holding CLOSE on the drop before pulling out to the wide view
const ZOOM_MIN: float = 240.0         # closest: the ISR narrow-view distance -- you can't zoom in past the tactical frame
const ZOOM_MAX: float = 1650.0        # farthest: the whole peninsula frames; ocean, never void, beyond
const MUSIC_MENU: String = "res://audio/music/music 1.wav"     # the menu / startup theme (loops)
const MUSIC_DEPLOY: String = "res://audio/music/music 2.wav"   # kicks in the moment you deploy (loops)
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
const POP_INFECTED: int = 99    # ambient horde, spread over the ~806 m city (+10%)
const POP_CIV: int = 61         # the crowd -- warm panicked bodies to read among (+10%)
const POP_SAN: int = 6          # the wipe force: rare, deadly, cool signatures (v0.19 elite = 6)
# The wider ecology -- cheap now that units are shapes. Counts span the whole city.
const POP_RUNNERS: int = 33     # fast, fragile infected mixed through the horde
const POP_BRUTES: int = 14      # slow, tanky infected
const ZED_HORDES: int = 3       # dense zombie clusters -- overwhelming if you wander in
const ZED_PER_HORDE: int = 35   # a wall of bodies packed into a tight radius
const BANDIT_CREWS: int = 6     # roaming armed crews... (+10%)
const BANDIT_PER_CREW: int = 5
const SURVIVOR_HOLDOUTS: int = 7   # dug-in armed holdouts... (+10%)
const SURVIVOR_PER_HOLDOUT: int = 3
const GAUNTLET_PER_BRIDGE: int = 44   # infected choking each bridge deck
const ELEMENTS: int = 4                 # max player teams (touch bar 1-4)
var _team_count: int = 4                 # chosen at the startup menu (solo / 2 / 3 / 4)
var _team_colors: Array[Color] = []      # per-element unit-icon colour, randomized every game (distinct hues)
# Your squad's loadout, chosen at the menu -- how many of each unit type deploy (element 0).
const FIXED_CDR: int = 1                  # every team fields exactly one commander -- fixed, not choosable
const CHOOSABLE: Array = [&"cbt", &"med", &"snp", &"rec", &"eod"]   # the five tunable roles (the commander is set)
var _loadout: Dictionary = {&"cbt": 15, &"med": 4, &"snp": 3, &"rec": 2, &"eod": 1}   # choosable roles; +1 cdr = REQUIRED_TROOPS
var _pending_count: int = 1              # team count picked, awaiting the loadout confirm
var _squad_max: int = 26                 # how many troopers you deployed with (for the SQUAD n/max readout)
const LOADOUT_MAX: int = 22              # cap per unit type
const REQUIRED_TROOPS: int = 26          # EVERY team fields exactly this many (1 commander + 25 choosable) to deploy
# Parley: rival teams (SQUAD element != 0) are hostile by default, but some are OPEN to a
# truce. A truce is MUTUAL -- you offer (PARLEY) and they're open -> allied (both hold fire).
var _rival_open: Dictionary = {}         # rival element -> true if that team also runs a passive stance
var _tutorial: bool = false              # tutorial run: calmer map, control hints
var _menu_active: bool = true            # true until the player starts from the menu
var _menu_layer: CanvasLayer             # the startup menu overlay, freed on start
var _menu_sim: bool = true               # menu backdrop: a heavy Sanitation force sweeping the city
var _menu_title: Label                   # the SPECTRE PROTOCOL title -- scanner rays fire from it
var _menu_fade: ColorRect                # black wash over the feed for the sim-reset transition
var _menu_teams: Control                 # the team-count buttons
var _menu_loadout: Control               # the squad-loadout steppers (shown after a team pick)
var _menu_thermal_btn: Button            # menu palette-flip button (WHT/BLK HOT / IRONBOW)
const MODE_NAMES: Array = ["WHT HOT", "BLK HOT", "IRONBOW"]
var _loadout_lbls: Dictionary = {}       # unit kind -> its count Label in the loadout panel
var _loadout_total_lbl: Label            # "TROOPS n/26" readout
var _deploy_btn: Button                  # DEPLOY -- enabled only when the total hits REQUIRED_TROOPS
var _menu_ping_age: float = 999.0        # seconds since the last scanner ping (>= show = idle)
var _menu_ping_next: float = 1.2         # seconds until the next ping (irregular)
var _menu_resetting: bool = false        # a fade-out / respawn / fade-in cycle is running
const MENU_PING_SHOW: float = 5.0        # a ping's markers live this long, then fade for the next
const MENU_RAY_MAX: int = 48             # cap the contacts a ping paints, so the fan stays legible
# ISR scan: enemy teams (sanitation + rival teams) stay unidentified until a scan pulse
# paints them for SCAN_REVEAL s; SCAN_COOLDOWN s between scans.
var _scan_t: float = 999.0               # seconds since the last scan (>= REVEAL = hidden)
var _scan_pulse_t: float = 99.0          # animation clock for the green scan sweep
var _sfx_scan: AudioStream
const SCAN_REVEAL: float = 15.0
const SCAN_COOLDOWN: float = 25.0
const SCAN_PULSE: float = 1.3            # seconds the green sweep ring takes to cross the feed
const FOG_SIGHT: float = 100.0           # a unit passively sees enemies this close (fog of war)
const FOG_SIGHT_SNP: float = 150.0       # the sniper's optic reaches further -- a scout's eyes
const SCAN_RANGE: float = 175.0          # a commander scan IDs enemies out to here for SCAN_REVEAL s


## The player's commander (element 0's cdr), or any element-0 unit if the cdr is down; -1
## if the player has no one left. Scans originate from here.
func _commander() -> int:
	var fallback: int = -1
	for i in sim.count():
		if sim.alive[i] and sim.team[i] == WorldSim.SQUAD and sim.element[i] == 0:
			if sim.kind[i] == &"cdr":
				return i
			if fallback < 0:
				fallback = i
	return fallback


## Is enemy unit i currently visible to you? Fog of war: revealed if any of your units is
## within FOG_SIGHT of it, OR a live commander scan reaches it (SCAN_RANGE for SCAN_REVEAL s).
func _identified(i: int) -> bool:
	return _in_los(sim.pos[i])


## Is a ground point currently inside your fog-of-war reveal -- within any of your units'
## sight (the sniper's reaches further), or a live commander scan's SCAN_RANGE bubble?
func _in_los(p: Vector2) -> bool:
	for j in sim.count():
		if sim.alive[j] and sim.team[j] == WorldSim.SQUAD and sim.element[j] == 0:
			var s: float = FOG_SIGHT_SNP if sim.kind[j] == &"snp" else FOG_SIGHT   # the sniper sees further
			if p.distance_squared_to(sim.pos[j]) <= s * s:
				return true
	if _scan_t < SCAN_REVEAL:
		var cmd: int = _commander()
		if cmd >= 0 and p.distance_squared_to(sim.pos[cmd]) <= SCAN_RANGE * SCAN_RANGE:
			return true
	return false


## Fire an ISR scan if off cooldown: a green sweep + robotic beeps that paints the enemy
## teams for SCAN_REVEAL s. SCAN_COOLDOWN s between scans.
func _request_scan() -> void:
	if _scan_t < SCAN_COOLDOWN or _commander() < 0:
		return                                 # off cooldown + a live commander to scan from
	_scan_t = 0.0
	_scan_pulse_t = 0.0
	if _sfx_scan != null:
		Audio.sfx(_sfx_scan, 2.0, 0.6)   # the actual scanner: dropped low, sonar-like
# Insertion edges, spread around the peninsula so no two teams deploy close. Order is
# W, E, N, S so 2 teams land opposite (W+E), 3 add N, 4 add S.
const EDGE_BASES: Array = [Vector2(205, 615), Vector2(885, 480), Vector2(500, 215), Vector2(520, 945)]
const ELEMENT_ROSTER: Array = [&"cdr", &"cbt", &"med", &"snp", &"rec", &"eod"]   # per team; CMD leads, EOD lobs grenades

# --- Read of the units. FLIR flattens PS1 mesh detail to a blob at this range, so
# the role is carried by HEAT + SIZE, not the model. false = minimalist thermal
# shapes (the rymdkapsel read, matches v0.19); true = the PS1 .glb + idle rigs.
const USE_MODELS: bool = false
const HELP_TEXT: String = "[LMB] pick   [RMB] move   [P] passive stance   [V] arm  [B] AC-130 strike\n[TAB]/[Q] unit type   [1] select all   [E] scan   [SPACE] wide / ISR view\n[WASD] pan   [wheel] zoom   [T] palette   [C] snow   [H] hide\nEXFIL: cross a bridge, reach an evac LZ, or wipe the rival teams"

# AC-130 gunship ISR HUD palette
const HUD_COL: Color = Color(0.30, 0.82, 0.36, 0.95)   # deep radiation green -- saturated, high contrast
const HUD_DIM: Color = Color(0.30, 0.82, 0.36, 0.45)
# Build version: v0.19 (the prototype) + one v0.01 per push. Bump BUILD_PUSHES by 1 each push.
const BUILD_PUSHES: int = 94
const HUD_RED: Color = Color(1.00, 0.34, 0.28, 0.95)   # threat / alert
# target-tag palette (AC-130): yellow vehicles, green friendlies, red hostiles
const TAG_FRIEND: Color = Color(0.36, 0.76, 0.56, 0.95)
const TAG_ENEMY: Color = Color(1.00, 0.30, 0.30, 0.95)
const TAG_VEHICLE: Color = Color(0.96, 0.90, 0.32, 0.95)
const TAG_ZED: Color = Color(0.72, 0.42, 0.95, 0.90)   # the horde, purple
const TAG_ALLY: Color = Color(0.40, 0.90, 0.95, 0.95)  # rival team at truce with you -- cyan
const TAG_PASSIVE: Color = Color(0.98, 0.72, 0.28, 0.95) # rival open to a truce -- amber
const TEAM_CARET_ZOOM: float = 780.0   # above this altitude, one team caret not per-unit boxes
const TAG_ZOOM_MAX: float = 900.0      # target tags only when zoomed in like the real optic

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
var _hud_font: Font                    # the game HUD font (Inversionz), for drawn banners/threat text
var _warn_ctrl: Control                # top overlay for the RADIATION WARNING -- above the bars + all HUD

var sensor_mat: ShaderMaterial
var cut_mat: ShaderMaterial
var agc := AGC.new()

var sim: WorldSim = WorldSim.new()
var views: Array[Node3D] = []          # one visual per sim unit, index-aligned
var active_element: int = 0            # which of the four teams the player is driving
var _type_idx: int = -1                # unit-type cycle position within the active element
var _cyc_btn: Button                   # the TYPE button (shows the current type, or ALL)
var _all_btn: Button                   # the ALL button (dark when ALL is the current selection)
var _scan_btn: Button                  # the SCAN button (shows the cooldown countdown, lit when ready)
var _anim: Array = []                  # an Animator per view (or null), index-aligned
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _sfx_pool: Array[AudioStreamPlayer3D] = []
var _sfx_next: int = 0
var _sfx_gun: AudioStream
var _sfx_claw: AudioStream
var _sfx_death: AudioStream
var _sfx_strike: AudioStream
var _sfx_blast: AudioStream
var _sfx_flash: AudioStream
var _sfx_flame: AudioStream            # sanitation flamethrower whoosh
var _flame_sfx_cd: float = 0.0         # throttle so overlapping jets don't machine-gun the whoosh
var _sfx_expl: AudioStream             # distant explosion, for ambient war
var _sfx_yell: AudioStream             # civilian panic (drop audio/sfx/civ_panic.wav to enable)
var _sfx_sanvox: Array[AudioStream] = []   # sanitation vocals: the squad comms, reversed (eerie)
var _sanvox_t: float = 0.0
var _sanvox_next: float = 6.0
var _ambient_t: float = 0.0            # ambient-combat timer: war rumbling around the map
var _ambient_next: float = 3.0
# panic driver: a warm car bolts down a street, crashes, and burns -- environmental
var _panics: Array = []                # active panic-driven cars: [{body, fire, pos, dir, phase, t}]
var _panic_next: float = 6.0           # seconds to the next civilian bolting in a car
const PANIC_SPEED: float = 15.0
const PANIC_DRIVE: float = 5.0         # seconds it careens before the crash
const PANIC_BURN: float = 45.0         # a crashed wreck burns ~45 s
const PANIC_MAX: int = 4               # up to this many careening / burning at once
var sel_layer: Control
var drag_start: Vector2 = Vector2.ZERO
var dragging: bool = false
var _ui_press: bool = false             # the current mouse press landed on a control-bar button

# mission / exfil
var mission: Mission
# The Sanitation force isn't on the board at deploy -- it's called in once you draw enough
# heat (kills). Once deployed, the only way out is a bridge or wiping the whole force.
var _sani_deployed: bool = false
var _sani_music_on: bool = false       # the wipe-force theme layer is live (asset present)
var _deploy_anim: Dictionary = {}      # {body, rotor, mode, base, ex, t}: your insertion, animated v0.19-style
var _deploy_mode: int = 0              # 0 heli / 1 truck / 2 walk -- element 0's insertion this run
const HELI_ALT: float = 19.0           # heli altitude scale (max ~42 m at v0.19 lift 2.2)
const ROTOR_SPD: float = 22.0          # main-rotor spin, rad/s (v0.19 elapsed*22)
var _deploy_stagger: Array = []        # [{i, at, form}]: element-0 troopers disembarking one by one
var _deploy_clock: float = 0.0         # seconds since the drop, drives the disembark stagger
var _intro_t: float = -1.0             # >=0: the intro camera is holding close on the drop before pulling out wide
var _nuke_fired: bool = false          # hoarding 50 HDDs trips a nuke -- total loss
const NUKE_HDD: int = 50               # drives that draw the strike that ends everything
# The Sanitation theme layer -- drop one of these in and it rides in by proximity on deploy.
const MUSIC_SANI: Array = ["res://audio/music/musicSANI.ogg", "res://audio/music/musicSANI.wav"]
const SANI_MUS_NEAR: float = 30.0      # within this many metres the theme is at full presence
const SANI_MUS_FAR: float = 240.0      # past this the theme fades toward the floor
var banner: Label                      # win / lose card, hidden until the mission ends
var help: Label
var show_help: bool = false             # controls card off by default -- CTRL/H brings it up (keeps the HUD clean)

# AC-130 HUD + touch
var _bar_l: Control                    # lower-LEFT cluster: REGROUP / unit-type / ALL
var _bar_r: Control                    # lower-RIGHT cluster: command + camera + AC-130 arm/fire
var _arm_btn: Button                   # AC-130 ARM (lit only when unlocked + disarmed)
var _fire_btn: Button                  # AC-130 FIRE (lit only when armed)
var _locked_btn: Button                # big LOCKED cover over ARM/FIRE until the kill threshold
var _psv_btn: Button                   # PSV: passive-stance toggle (lit while passive)
var _pal_btn: Button                   # PAL: shows the current palette name (WHT/BLK HOT / IRONBOW)
var _passive: bool = false             # your team holds fire on any rival team that's also passive
var _status_panel: Label               # squad status readout, toggled by the STATUS button
var _kills: int = 0                    # confirmed hostile kills, for the threat readout
var _san_kills: int = 0                # Sanitation elites down -- debrief highlight
var _collateral: int = 0               # civilians dropped by your fire missions
var _score: int = 0                    # running mission score (kills by type, collateral)
# Score weights. Infected are cheap and countless; the armed factions are worth more;
# a Sanitation elite is the prize. Civilians dropped by YOUR strike cost you.
const KILL_PTS: Dictionary = {
	&"zed": 10, &"run": 12, &"bru": 25,   # infected: shambler / runner / brute
	&"bnd": 30, &"svr": 35,               # bandits, dug-in survivors
	&"san": 120,                          # Sanitation elite -- the apex kill
}
const COLLATERAL_PTS: int = -75        # a civilian killed in your fire mission
const EXTRACT_PTS: int = 250           # per element that walks off the peninsula
const FULLSQUAD_PTS: int = 750         # bonus if every element gets clear
var _touches: Dictionary = {}          # active touch index -> position
var _touch_moved: float = 0.0          # primary-touch travel, to tell a tap from a drag
var _pinch_prev: float = 0.0           # last two-finger spread, for pinch-zoom
var _move_marker: Dictionary = {}      # {pos, ids}: a spinning triangle at the move destination, up until the commanded units arrive
const MOVE_ARRIVE_M: float = 9.0       # commanded units within this of the mark = arrived, mark vanishes

# Loot: press-and-HOLD on a building fills a ring; releasing or dragging cancels.
var _loot_idx: int = -1                # building being looted, -1 = none
var _loot_t: float = 0.0               # seconds held on it
var _press_pos: Vector2 = Vector2.ZERO # where the hold began (drag past this cancels)
var _looted: Dictionary = {}           # building index -> true (cleared, can't re-loot)
var _loot_count: int = 0               # buildings looted this mission
var _hdd: int = 0                       # HDD drives recovered -> end-of-mission score multiplier
var _hdd_pickups: Array[Vector2] = []  # dedicated intel drops scattered on the map
var _landmarks: Array = []             # [{pos, name, col, idx}] named civic buildings, randomized per game
var _landmark_class: Dictionary = {}   # building idx -> loot class for the named civic buildings
var _loot_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _loot_toast: String = ""           # transient readout: what the last building held
var _loot_toast_t: float = 0.0         # seconds of toast left
const LOOT_TIME: float = 1.5           # hold seconds to clear a building
const LOOT_PTS: int = 60               # score per building cleared (before its payout)
const LOOT_NEAR_M: float = 22.0        # a unit within this of a building's edge can breach it
const LOOT_CANCEL_PX: float = 42.0     # drag past this and it's a pan, not a loot
const LOOT_TOAST_TIME: float = 3.2     # how long a loot result stays on the HUD
const LOOT_AMBUSH_CHANCE: float = 0.16 # odds a cleared building was a nest that bites back
const HDD_PICKUPS: int = 10            # dedicated drives seeded on the map
const HDD_GRAB_M: float = 5.0          # a unit this close scoops a drive
# building payout classes (stable per building index)
const LC_HDD: int = 0
const LC_HOSP: int = 1
const LC_POLICE: int = 2
const LC_BIO: int = 3

# AC-130 fire support -- a kill-charged boresight strike (v0.19's killstreak)
const AC_UNLOCK: int = 100             # INFECTED kills to unlock a fire mission (killstreak; resets on use)
const STRIKE_R: float = 16.0           # kill radius, metres
const STRIKE_DMG: float = 1200.0       # one burst still flattens even the buffed Sanitation elite
const STRIKE_TOF: float = 3.5          # round time-of-flight, seconds -- a long flight sells the distance
const STRIKE_BOW: float = 0.26         # arc height of the inbound round, as a fraction of its screen run
var _zombie_kills: int = 0             # infected killed toward the next AC-130 unlock
var _strike_arming: bool = false       # armed: the next tap designates the strike point
var _strike_pending: bool = false      # a round is inbound (in flight)
var _strike_target: Vector2 = Vector2.ZERO
var _strike_tof: float = 0.0           # seconds since the round left the gun
var _strike_pos: Vector2 = Vector2.ZERO
var _strike_t: float = 999.0           # seconds since impact, for the blast FX
var _flashes: Array = []               # muzzle flashes: [{pos: Vector2, t: float}], newest last
const FLASH_LIFE: float = 0.12         # seconds a muzzle flash stays lit
const FLASH_MAX: int = 80              # cap, so a big firefight can't flood the overlay
# 3D thermal blasts: hot emissive blobs in the feed that bloom + fade -- reused
# for the AC-130 strike, EOD grenades, the sanitation flamethrower + flash-nades.
const FLASH3D_POOL: int = 56               # a flamethrower burst sprays 11 streaming blobs; run deep
var _flash3d: Array[MeshInstance3D] = []   # free pool
var _flash3d_busy: Array = []              # active: [{node, t, life, peak}]
const FLAME_LEN: float = 11.0              # visible reach of the fire jet, m
const FLAME_H: float = 1.3                 # nozzle height, m

# feeds
const FEED: Dictionary = {
	"deploy": {"dist": 240.0, "el": 0.90, "fov": 40.0, "follow": true, "orbit": 0.015},
	"orbit":  {"dist": 1350.0, "el": 1.25, "fov": 40.0, "follow": false, "orbit": 0.015},
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
	if (_shot_dir != "" or _map_dir != "") and OS.get_environment("SPECTRE_MENU") == "":
		_menu_sim = false          # captures/dev hooks show the real game, not the menu sweep
		_menu_active = false       # straight into gameplay -- set BEFORE _spawn so the disembark stages
		_intro_t = 0.0             # capture runs still play the intro (deploy hold -> wide pull)
	_init_res()                    # frame the feed to the window we were opened with
	_build_tree()
	_build_version_stamp()         # the build number, top-right, always on top
	_randomize_team_colors()       # distinct per-team icon colours (also reshuffled on each _start_game)
	_spawn()
	get_window().size_changed.connect(_reframe)   # ...and re-frame if it changes / rotates
	set_process_input(true)
	Audio.play_music(MUSIC_MENU, 0.15)   # menu theme; quick 0.15 s fade in (and out on deploy)
	Audio.play_ambience(AMBIENCE_BED, 3.0)   # ghost-town ambience swells under the mix
	_sfx_gun = load("res://audio/sfx/gun_rifle.wav")
	_sfx_claw = load("res://audio/sfx/zed_attack.wav")
	_sfx_death = load("res://audio/sfx/zed_death.wav")
	_sfx_strike = load("res://audio/sfx/ac130_strike.wav")
	_sfx_blast = load("res://audio/sfx/blast.wav")
	_sfx_flash = load("res://audio/sfx/flashbang.wav")
	_sfx_flame = load("res://audio/sfx/flamethrower.wav")
	_sfx_expl = load("res://audio/sfx/dist_explosion.wav")
	_sfx_yell = load("res://audio/sfx/civ_panic.wav") if ResourceLoader.exists("res://audio/sfx/civ_panic.wav") else null
	for stem in ["ack_affirmative", "ack_inposition", "hold_fire", "need_backup", "open_fire", "order_go", "order_move_out", "order_push", "order_ready"]:
		var pth: String = "res://audio/sfx/sanvox/" + stem + ".wav"
		if ResourceLoader.exists(pth):
			_sfx_sanvox.append(load(pth))
	_sfx_scan = load("res://audio/sfx/scan.wav")
	_hud_font = load(HUD_FONT)          # the game font, for the drawn banners + threat box
	# Players get the startup menu (music1 already playing) over a slowly-rotating feed;
	# captures/dev hooks (which cleared _menu_active above) drop straight into gameplay.
	if _menu_active:
		feed = "orbit"
		_apply_feed()
		_build_menu()


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
	# CRITICAL: a SubViewport does NOT process 3D audio unless this is on. Every combat SFX
	# plays from an AudioStreamPlayer3D pool that lives in here -- without this the listener
	# is dead and ALL gunfire/explosions/claws are silent (music/ambience are 2D, so they play).
	vp.audio_listener_enable_3d = true
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
	_build_flash_pool()

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

	# top overlay for the RADIATION WARNING -- its own high CanvasLayer so it draws OVER the
	# control bars and every other HUD element.
	var warn_layer: CanvasLayer = CanvasLayer.new()
	warn_layer.layer = 45
	_warn_ctrl = Control.new()
	_warn_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_warn_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warn_ctrl.draw.connect(_draw_radiation_warning)
	warn_layer.add_child(_warn_ctrl)
	add_child(warn_layer)

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
	help.offset_top = -150      # lifted to sit ABOVE the lower-corner control clusters
	help.offset_bottom = -86
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
	sim.player_element = 0                  # you command team 0; the rest are AI rivals
	_sani_deployed = false
	var walls: Array[Rect2] = city.building_rects()
	if cars != null:
		walls.append_array(cars.rects)     # semis block; the rest you walk around
	# walls block LOS + nav; the land polygon is the coastline (ocean outside);
	# bridge decks are slowed gaps the nav carves through the water.
	sim.load_map(walls, city.water, city.bridges, city.map_lo, city.map_hi, city.land_poly)
	# Each team inserts from a different edge (EDGE_BASES) so no two deploy close; an
	# insertion vehicle marks the drop. The exfil bridges are N (Golden Gate) and E (Bay).
	var base0: Vector2 = Vector2(300.0, 470.0)
	for e in _team_count:
		var base: Vector2 = EDGE_BASES[e % EDGE_BASES.size()]
		if not Geometry2D.is_point_in_polygon(base, city.land_poly):
			base = Vector2(300.0, 470.0)
		if e == 0:
			base0 = base
		_deploy_vehicle(base, e)
		# EVERY team fields REQUIRED_TROOPS (1 commander + 25). You pick element 0's mix;
		# rivals field the standard 26. Element 0 spawns CLUSTERED at the drop and disembarks
		# to formation (see the stagger); rivals spawn already spread into a loose block.
		var roster: Array = _loadout_roster() if e == 0 else _rival_roster()
		if e == 0:
			_squad_max = roster.size()
		for j in roster.size():
			var p: Vector2 = base if e == 0 else base + Vector2(float(j % 6) * 1.6, float(j / 6) * 1.6)
			sim.spawn(p, roster[j], WorldSim.SQUAD, e)
	_populate_world()
	# win by escaping a bridge, extracting via an evac LZ, or eliminating the rival teams.
	mission = Mission.new()
	mission.setup(city.escapes, _evac_zones(), 0, _team_count)
	_spawn_hdd_pickups()
	_assign_landmarks()
	_init_dispositions()
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
	if not _menu_active:
		_setup_deploy_stagger(base0)   # element 0 disembarks the insertion vehicle one by one


## Seed the whole ecology: the ambient horde + crowd + sanitation on the land, a
## mix of zombie variants, roaming bandit crews, dug-in survivor holdouts, and a
## dense infected gauntlet choking each bridge deck.
func _populate_world() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	# Tutorial is a calm map to learn on -- a fraction of the ecology, no hordes/gauntlet.
	# The menu backdrop instead deploys a heavy Sanitation sweep to 'sanitize' the city.
	var s: float = 0.16 if _tutorial else 1.0
	sim.populate(int(POP_INFECTED * s), int(POP_CIV * s), 0, city.land)   # ecology only; san is a cluster
	if _menu_sim:
		# the menu sweep: a big Sanitation force spawned as one TIGHT pack, not scattered
		sim.spawn_cluster(&"san", WorldSim.SANITATION, _random_land_point(rng), 26, 8.0, rng)
	sim.scatter(&"run", WorldSim.INFECTED, int(POP_RUNNERS * s), city.land, rng)
	sim.scatter(&"bru", WorldSim.INFECTED, int(POP_BRUTES * s), city.land, rng)
	if not _tutorial:
		for _z in ZED_HORDES:
			sim.spawn_cluster(&"zed", WorldSim.INFECTED, _random_land_point(rng), ZED_PER_HORDE, 15.0, rng)
		for _c in BANDIT_CREWS:
			sim.spawn_cluster(&"bnd", WorldSim.BANDIT, _random_land_point(rng), BANDIT_PER_CREW, 6.0, rng)
		for _h in SURVIVOR_HOLDOUTS:
			sim.spawn_cluster(&"svr", WorldSim.SURVIVOR, _random_land_point(rng), SURVIVOR_PER_HOLDOUT, 4.0, rng)
		for b in city.bridges:
			sim.spawn_line(&"zed", WorldSim.INFECTED, b, GAUNTLET_PER_BRIDGE, rng)   # the choked deck


## The insertion vehicle, animated EXACTLY like v0.19: a HELI drops straight DOWN onto the drop,
## hovers while the troops pour out, then lifts off vertically and departs; a TRUCK drives in from
## off-map and parks as scenery; a WALK insertion has NO vehicle (the troops just march in). YOUR
## team (element 0) plays the animation (see _advance_deploy); rivals get a static prop.
func _deploy_vehicle(base: Vector2, e: int) -> void:
	if city == null:
		return
	var mode: int = (_rng.randi() % 3) if e == 0 else (e % 3)   # 0 heli / 1 truck / 2 walk
	if e == 0:
		_deploy_mode = mode
	if mode == 2:
		return                                                 # foot march -- no vehicle at all
	var outward: Vector2 = (base - city.land.get_center()).normalized()
	if mode == 0:
		var body: MeshInstance3D = _heli_body()
		var rotor: MeshInstance3D = _heli_rotor()
		city.add_child(body)
		city.add_child(rotor)
		if e == 0:
			body.position = Vector3(base.x, 1.4 + HELI_ALT * 2.2, base.y)   # start high (v0.19 lift 2.2)
			rotor.position = body.position + Vector3(0.0, 1.7, 0.0)
			_deploy_anim = {"body": body, "rotor": rotor, "mode": 0, "base": Vector3(base.x, 0.0, base.y), "t": 0.0}
		else:
			body.position = Vector3(base.x, 1.4, base.y)                    # rival: landed, static
			rotor.position = body.position + Vector3(0.0, 1.7, 0.0)
	else:
		var tm: BoxMesh = BoxMesh.new()
		tm.size = Vector3(3.0, 3.0, 7.0)
		var truck: MeshInstance3D = MeshInstance3D.new()
		truck.mesh = tm
		truck.material_override = ThermalLib.get_material("hood_warm", snap_res)
		truck.rotation.y = 0.0 if absf(outward.x) < absf(outward.y) else PI * 0.5   # axis-snapped (a rotated box blows out)
		var rest: Vector3 = Vector3(base.x, 1.5, base.y)
		var ex: Vector3 = rest + Vector3(outward.x, 0.0, outward.y) * 70.0
		truck.position = ex if e == 0 else rest
		city.add_child(truck)
		if e == 0:
			_deploy_anim = {"body": truck, "rotor": null, "mode": 1, "base": rest, "ex": ex, "t": 0.0}


func _heli_body() -> MeshInstance3D:
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(3.0, 2.4, 8.0)
	var body: MeshInstance3D = MeshInstance3D.new()
	body.mesh = bm
	body.material_override = ThermalLib.get_material("hood_warm", snap_res)
	return body


## The rotor: a thin flat DISC (v0.19's rotor "blur disc"). Axis-symmetric, so spinning it about
## its own axis never changes the silhouette -- it reads as a spinning rotor WITHOUT the bright
## over-draw a rotated flat blade would trip on the PSX vertex-snap shader.
func _heli_rotor() -> MeshInstance3D:
	var cm: CylinderMesh = CylinderMesh.new()
	cm.top_radius = 7.0
	cm.bottom_radius = 7.0
	cm.height = 0.18
	cm.radial_segments = 14
	var r: MeshInstance3D = MeshInstance3D.new()
	r.mesh = cm
	r.material_override = ThermalLib.get_material("parapet", snap_res)
	return r


## Stage element 0's disembark: each trooper starts hidden aboard the insertion vehicle at
## the drop, then pops out on a stagger and walks to its slot in a loose formation ring
## around the base -- the v0.19 insertion read. (Rivals just spawn in place.)
func _setup_deploy_stagger(base: Vector2) -> void:
	_deploy_stagger.clear()
	_deploy_clock = 0.0
	var ids: Array = []
	for i in sim.count():
		if sim.team[i] == WorldSim.SQUAD and sim.element[i] == 0:
			ids.append(i)
	# v0.19 disembark timing by insertion mode: heli t0 2.0 (once it lands), truck 2.6 (once it
	# arrives), walk 0.3 (straight in); step 0.10 (0.16 on foot).
	var t0: float = 2.0 if _deploy_mode == 0 else (2.6 if _deploy_mode == 1 else 0.3)
	var step: float = 0.16 if _deploy_mode == 2 else 0.10
	for k in ids.size():
		var i: int = ids[k]
		var ang: float = float(k) / maxf(1.0, float(ids.size())) * TAU
		var rad: float = 7.0 + float(k % 4) * 3.5                 # a few loose rings, not a stack
		var form: Vector2 = base + Vector2(cos(ang), sin(ang)) * rad
		var at: float = t0 + float(k) * step                     # disembark one by one
		_deploy_stagger.append({"i": i, "at": at, "form": form})
		sim.pos[i] = base                                         # aboard the vehicle at the drop
		if i < views.size() and views[i] != null:
			views[i].visible = false                             # inside -- revealed on disembark


## Ease the player's insertion vehicle in from off-map, and release the troopers on their
## stagger: each appears at the drop (with a little jitter) and is ordered out to formation.
func _advance_deploy(delta: float) -> void:
	if not _deploy_anim.is_empty():
		_deploy_anim["t"] += delta
		var t: float = _deploy_anim["t"]
		var body: MeshInstance3D = _deploy_anim["body"]
		if int(_deploy_anim["mode"]) == 0:
			# HELI (v0.19): drop straight down (0-2 s) -> hover on the deck (2-5.5 s, troops out)
			# -> lift off vertically + depart (5.5-8 s) -> gone.
			if t >= 8.0 or not is_instance_valid(body):
				if is_instance_valid(body):
					body.queue_free()
				var rr: Variant = _deploy_anim.get("rotor")
				if rr != null and is_instance_valid(rr):
					rr.queue_free()
				_deploy_anim = {}
			else:
				var lift: float = 0.0
				if t < 2.0:
					lift = (2.0 - t) / 2.0 * 2.2
				elif t >= 5.5:
					lift = minf(2.2, (t - 5.5) / 2.0 * 2.2)
				var base: Vector3 = _deploy_anim["base"]
				body.position = Vector3(base.x, 1.4 + lift * HELI_ALT, base.z)
				var rotor: MeshInstance3D = _deploy_anim["rotor"]
				if rotor != null and is_instance_valid(rotor):
					rotor.position = body.position + Vector3(0.0, 1.7, 0.0)
					rotor.rotate_y(delta * ROTOR_SPD)                     # spinning rotor disc
		else:
			# TRUCK (v0.19): drive in from off-map over 2.4 s, then PARK (stays as scenery).
			var f: float = clampf(t / 2.4, 0.0, 1.0)
			if is_instance_valid(body):
				body.position = (_deploy_anim["ex"] as Vector3).lerp(_deploy_anim["base"] as Vector3, f)
			if f >= 1.0:
				_deploy_anim = {}                                        # parked -- leave it in place
	if _deploy_stagger.is_empty():
		return
	_deploy_clock += delta
	var out: Array = []
	for s in _deploy_stagger:
		if _deploy_clock < float(s["at"]):
			continue
		var i: int = s["i"]
		if i < views.size() and views[i] != null and sim.alive[i]:
			views[i].visible = true
			sim.pos[i] += Vector2(_rng.randf_range(-1.6, 1.6), _rng.randf_range(-1.6, 1.6))
			sim.order_move([i], s["form"])                        # walk out to the formation slot
		out.append(s)
	for s in out:
		_deploy_stagger.erase(s)


## Evac-helo LZs: one for solo/2/3 teams, two for 4. Marked on the HUD; reaching one
## with the whole team extracts you (when no Sanitation force is loose).
func _evac_zones() -> Array[Rect2]:
	var zones: Array[Rect2] = []
	if city == null:
		return zones
	# The evac chopper's takeoff pad(s) are RANDOMISED each game -- a new open spot every run,
	# labelled on the HUD so you know where to steer for extraction.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var n: int = 2 if _team_count >= 4 else 1
	for i in n:
		var c: Vector2 = _random_land_point(rng)
		zones.append(Rect2(c.x - 9.0, c.y - 9.0, 18.0, 18.0))
	return zones


## Name a handful of random civic buildings each game -- a police station, two hospitals, a
## bio lab -- for the in-world headers + matching loot payouts. Randomised every run.
func _assign_landmarks() -> void:
	_landmarks.clear()
	_landmark_class.clear()
	if _menu_sim or city == null or city.buildings.is_empty():
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var specs: Array = [["POLICE STATION", LC_POLICE], ["HOSPITAL", LC_HOSP], ["HOSPITAL", LC_HOSP], ["BIO LAB", LC_BIO]]
	var used: Dictionary = {}
	for spec in specs:
		var bi: int = _pick_landmark_building(rng, used)
		if bi < 0:
			continue
		used[bi] = true
		var b: Dictionary = city.buildings[bi]
		_landmarks.append({"pos": Vector2(b["x"] + b["w"] * 0.5, b["z"] + b["d"] * 0.5), "name": String(spec[0]), "idx": bi})
		_landmark_class[bi] = int(spec[1])


## A random building index not already taken, preferring a taller footprint (a civic
## building isn't a shack); falls back to any free building.
func _pick_landmark_building(rng: RandomNumberGenerator, used: Dictionary) -> int:
	var best: int = -1
	for _try in 40:
		var bi: int = rng.randi() % city.buildings.size()
		if used.has(bi):
			continue
		if int(city.buildings[bi].get("fl", 1)) >= 3:
			return bi                    # a good tall pick -- take it
		if best < 0:
			best = bi                    # otherwise remember a fallback
	return best


## Roll each rival team's disposition: about half are OPEN to a truce, the rest fight to
## the end. You still have to PARLEY to actually stand a truce up (it's mutual).
func _init_dispositions() -> void:
	_rival_open.clear()
	for e in range(1, _team_count):
		_rival_open[e] = _rng.randf() < 0.5   # ~half the rival teams run a passive stance
	_recompute_alliances()


## Fold the player's passive stance into the sim's allied map: a rival is allied (mutual
## hold-fire, both still hunting the infected + Sanitation) only when YOU are passive AND it
## is also passive. A battered rival (<=1 unit left) turns passive to beg off.
func _recompute_alliances() -> void:
	if sim == null:
		return
	for e in range(1, _team_count):
		if sim.element_ids(e).size() <= 1:
			_rival_open[e] = true
		sim.allied[e] = _passive and _rival_open.get(e, false)


## Distinct random unit-icon colours, one per element, reshuffled each game -- so the teams
## read apart at a glance (yours + the rivals). Evenly-spaced hues + a little jitter.
func _randomize_team_colors() -> void:
	_team_colors.clear()
	var base: float = _rng.randf()
	for e in ELEMENTS:
		var h: float = fposmod(base + float(e) / float(ELEMENTS) + _rng.randf_range(-0.05, 0.05), 1.0)
		_team_colors.append(Color.from_hsv(h, 0.68, 1.0, 0.95))


## A squad unit's bracket colour is its team's assigned colour (stance now reads in the
## top-left element roster + the PSV button, not the bracket).
func _squad_col(i: int) -> Color:
	var e: int = sim.element[i]
	if e >= 0 and e < _team_colors.size():
		return _team_colors[e]
	return TAG_FRIEND


## Call in the Sanitation force: POP_SAN cool elites scattered across the city, with
## their views built + appended so the arrays stay index-aligned. Once they're loose the
## board changes -- extraction/elimination close, only a bridge or wiping them wins.
func _deploy_sanitation() -> void:
	if _sani_deployed or sim == null:
		return
	_sani_deployed = true
	sim.san_speed = WorldSim.STATS[&"cbt"][0] * 1.05   # in-game: only 5% faster than your troopers
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var pack: Vector2 = _random_edge_point(rng)     # they land at the MAP EDGE and push in, as a tight pack
	for _s in POP_SAN:
		var p: Vector2 = pack + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
		sim.spawn(p, &"san", WorldSim.SANITATION)
		var v: Node3D = _make_unit_view(WorldSim.SANITATION, &"san", rng)
		if v != null:
			v.position = Vector3(p.x, 0.0, p.y)
			vp.add_child(v)
		views.append(v)
		_anim.append(Animator.new(v, _rng) if v != null else null)
	# Fire up the wipe-force theme layer (rides in by proximity below). Silent no-op
	# until the asset is provided; tries .ogg then .wav.
	_sani_music_on = false
	for path in MUSIC_SANI:
		if Audio.sani_theme(path):
			_sani_music_on = true
			break


## Ride the Sanitation theme's level by how close the nearest elite is to your team:
## full presence within SANI_MUS_NEAR, fading toward the floor past SANI_MUS_FAR.
func _ride_sani_music() -> void:
	var here: Vector3 = _follow_point()
	var me: Vector2 = Vector2(here.x, here.z)
	var best: float = INF
	for i in sim.count():
		if sim.alive[i] and sim.team[i] == WorldSim.SANITATION:
			best = minf(best, me.distance_to(sim.pos[i]))
	if best == INF:
		Audio.set_sani_db(-80.0)             # none left (or wiped) -- silent
		return
	var t: float = clampf(1.0 - (best - SANI_MUS_NEAR) / (SANI_MUS_FAR - SANI_MUS_NEAR), 0.0, 1.0)
	Audio.set_sani_db(lerpf(-40.0, -5.0, t))


## Greed's end: recover NUKE_HDD drives and a nuclear strike levels the whole map. Nothing
## survives -- your team included -- so it's a total loss, by your own hand.
func _fire_nuke() -> void:
	if _nuke_fired or sim == null or city == null:
		return
	_nuke_fired = true
	var c: Vector2 = (city.map_lo + city.map_hi) * 0.5
	var reach: float = c.distance_to(city.map_hi) + 400.0
	sim.air_strike(c, reach, 99999.0)          # flatten everything, no survivors
	_spawn_flash3d(c, 80.0, 1.5, 45.0)         # a blinding thermal white-out at ground zero
	for a in 10:
		var ang: float = float(a) * TAU / 10.0
		_spawn_flash3d(c + Vector2(cos(ang), sin(ang)) * reach * 0.33, 44.0, 1.3, 22.0)
	if _sfx_strike != null:
		Audio.sfx(_sfx_strike, 8.0)
	if _sfx_expl != null:
		Audio.sfx(_sfx_expl, 8.0)
	mission.result = Mission.LOST
	mission.reason = "NUCLEAR DETONATION"
	_show_banner(false)


func _random_land_point(rng: RandomNumberGenerator) -> Vector2:
	for _try in 48:
		var p: Vector2 = Vector2(
			rng.randf_range(city.land.position.x, city.land.end.x),
			rng.randf_range(city.land.position.y, city.land.end.y))
		if Geometry2D.is_point_in_polygon(p, city.land_poly):
			return p
	return Vector2(400.0, 500.0)   # central-land fallback


## A random land point biased toward the map PERIMETER -- an external force (the Sanitation
## wipe team) lands at the edge and pushes IN, never in the middle of the city.
func _random_edge_point(rng: RandomNumberGenerator) -> Vector2:
	var c: Vector2 = city.land.get_center()
	var best: Vector2 = _random_land_point(rng)
	var bd: float = best.distance_squared_to(c)
	for _t in 10:
		var p: Vector2 = _random_land_point(rng)
		var d: float = p.distance_squared_to(c)
		if d > bd:
			bd = d
			best = p
	return best


## Seed the dedicated HDD drives across the city -- intel to scoop by walking a unit
## over one. Kept out of buildings/water so they're always reachable on foot.
func _spawn_hdd_pickups() -> void:
	_hdd_pickups.clear()
	if city == null or _menu_sim:
		return
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	for _k in HDD_PICKUPS:
		for _try in 24:
			var p: Vector2 = _random_land_point(rng)
			if _building_at(p) < 0:
				_hdd_pickups.append(p)
				break


## A living player-element trooper standing on a drive scoops it: +1 HDD, gone from the map.
func _collect_hdd_pickups() -> void:
	if _hdd_pickups.is_empty():
		return
	var grab2: float = HDD_GRAB_M * HDD_GRAB_M
	for k in range(_hdd_pickups.size() - 1, -1, -1):
		var g: Vector2 = _hdd_pickups[k]
		for i in sim.count():
			if not sim.alive[i] or sim.extracted[i]:
				continue
			if sim.team[i] != WorldSim.SQUAD or sim.element[i] != 0:
				continue
			if sim.pos[i].distance_squared_to(g) <= grab2:
				_hdd += 1
				_hdd_pickups.remove_at(k)
				_loot_say("HDD RECOVERED   x%d" % _hdd)
				Audio.comms("ack_affirmative", 1500)
				break


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
				# your squad's fire cuts loudest; the firefights around the map are louder now too
				_sfx_at(at, _sfx_gun, 5.0 if e["team"] == WorldSim.SQUAD else 1.5)
				if _flashes.size() < FLASH_MAX:
					_flashes.append({"pos": e["pos"], "to": e["to"], "t": 0.0})
			"panic":
				_sfx_at(at, _sfx_yell)   # civilian scream -- no-op until audio/sfx/civ_panic.wav exists
			"claw":
				_sfx_at(at, _sfx_claw)
			"zed_death":
				_sfx_at(at, _sfx_death)
				_score_kill(e["unit"])
			"kill":
				if e["team"] != WorldSim.CIVILIAN:
					_score_kill(e["unit"])   # a bandit eaten by the horde still counts for you
			"collateral":
				_sfx_at(at, _sfx_death)
				_collateral += 1
				_score += COLLATERAL_PTS      # you dropped a civilian with the fire mission
			"strike":
				_sfx_at(at, _sfx_strike, 5.0)   # AC-130 cannon report at the impact -- loud
			"blast":
				_sfx_at(at, _sfx_blast, 4.0)    # EOD grenade / RPG
				_spawn_flash3d(e["pos"], 4.0, 0.35, 1.6)
			"flame":
				_spawn_flame(e["pos"], e["to"])   # sanitation fire jet
				if _sfx_flame != null and _flame_sfx_cd <= 0.0:
					_sfx_at(at, _sfx_flame, -3.0)  # the whoosh -- throttled so jets don't stack
					_flame_sfx_cd = 0.5
			"flash":
				_sfx_at(at, _sfx_flash)            # sanitation flash-bang: bright bloom + ring-out
				_spawn_flash3d(e["pos"], 6.0, 0.40, 2.0)
			"turn":
				_turn_view(int(e.get("idx", -1)), at)   # a civilian just rose as a zombie -- swap its shape
			"man_down":
				pass   # (no callout -- the squad's together, no backup to call)


## A civilian just TURNED (the sim converted it to an infected in place). Swap its warm
## civilian shape for a cool zombie one and reset its animator.
func _turn_view(i: int, at: Vector3) -> void:
	if i < 0 or i >= views.size():
		return
	if views[i] != null:
		views[i].queue_free()
	var v: Node3D = _make_unit_view(WorldSim.INFECTED, &"zed", _rng)
	if v != null:
		v.position = Vector3(sim.pos[i].x, 0.0, sim.pos[i].y)
		vp.add_child(v)
	views[i] = v
	_anim[i] = Animator.new(v, _rng) if v != null else null
	_sfx_at(at, _sfx_claw, -1.0)   # a wet, close turn


## Ambient war: every few seconds, a distant blast or a burst of gunfire somewhere on
## the map -- positional (3D), so it pans + attenuates. Other teams and NPCs are always
## fighting the horde out there; you hear it happening around you.
func _ambient_combat(delta: float) -> void:
	if city == null:
		return
	_ambient_t += delta
	if _ambient_t < _ambient_next:
		return
	_ambient_t = 0.0
	_ambient_next = _rng.randf_range(3.5, 8.0)
	var g: Vector2 = _random_land_point(_rng)
	var at: Vector3 = Vector3(g.x, 1.0, g.y)
	if _rng.randf() < 0.4:
		_sfx_at(at, _sfx_expl, -1.0)     # a distant blast -- louder, the war is all around you
	else:
		_sfx_at(at, _sfx_gun, -3.5)      # a distant burst of fire


## Panic drivers: civilians bolting in cars. Each careens down a street, crashes into a
## building/edge, and burns for ~45 s -- several going at once, so there's always chaos on
## the streets. Axis-aligned travel so the thermal shader doesn't over-draw it (rotated-mesh
## bright bug).
func _advance_panic(delta: float) -> void:
	if city == null or (mission != null and mission.result != Mission.ONGOING):
		return
	_panic_next -= delta
	if _panic_next <= 0.0 and _panics.size() < PANIC_MAX:
		_spawn_panic()
		_panic_next = _rng.randf_range(4.0, 11.0)
	var done: Array = []
	for pc in _panics:
		pc["t"] += delta
		if pc["phase"] == 0:
			pc["pos"] += (pc["dir"] as Vector2) * PANIC_SPEED * delta
			if is_instance_valid(pc["body"]):
				pc["body"].position = Vector3(pc["pos"].x, 0.7, pc["pos"].y)
			var crashed: bool = pc["t"] > PANIC_DRIVE or _building_at(pc["pos"]) >= 0 \
				or not Geometry2D.is_point_in_polygon(pc["pos"], city.land_poly)
			if crashed:
				pc["phase"] = 1
				pc["t"] = 0.0
				if is_instance_valid(pc["body"]):
					pc["body"].material_override = ThermalLib.get_material("burning", snap_res)
				var fm: BoxMesh = BoxMesh.new()
				fm.size = Vector3(2.4, 3.2, 2.8)
				var fire: MeshInstance3D = MeshInstance3D.new()
				fire.mesh = fm
				fire.position = Vector3(pc["pos"].x, 2.4, pc["pos"].y)
				fire.material_override = ThermalLib.get_material("fire", snap_res)
				vp.add_child(fire)
				pc["fire"] = fire
				_sfx_at(Vector3(pc["pos"].x, 1.0, pc["pos"].y), _sfx_expl, -2.0)
				_spawn_flash3d(pc["pos"], 3.0, 0.4, 1.6)
		elif pc["t"] > PANIC_BURN:
			done.append(pc)
	for pc in done:
		_free_panic(pc)
		_panics.erase(pc)


func _spawn_panic() -> void:
	var pos: Vector2 = _random_land_point(_rng)
	var dir: Vector2 = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)][_rng.randi() % 4]
	var m: BoxMesh = BoxMesh.new()
	m.size = Vector3(2.0, 1.4, 4.6)
	var body: MeshInstance3D = MeshInstance3D.new()
	body.mesh = m
	body.position = Vector3(pos.x, 0.7, pos.y)
	body.rotation.y = PI * 0.5 if dir.x != 0.0 else 0.0
	body.material_override = ThermalLib.get_material("hood_warm", snap_res)
	vp.add_child(body)
	_panics.append({"body": body, "fire": null, "pos": pos, "dir": dir, "phase": 0, "t": 0.0})


func _free_panic(pc: Dictionary) -> void:
	if is_instance_valid(pc["body"]):
		pc["body"].queue_free()
	if pc.get("fire") != null and is_instance_valid(pc["fire"]):
		pc["fire"].queue_free()


func _clear_panic() -> void:
	for pc in _panics:
		_free_panic(pc)
	_panics.clear()


## Sanitation vocals: every so often a living Sanitation unit mutters a reversed radio
## callout from its position -- ISR-filtered + positional, so it's an eerie backwards
## voice that gets louder as the apex faction closes on you.
func _sanitation_vox(delta: float) -> void:
	if _sfx_sanvox.is_empty() or sim == null or _menu_active:
		return
	_sanvox_t += delta
	if _sanvox_t < _sanvox_next:
		return
	_sanvox_t = 0.0
	_sanvox_next = _rng.randf_range(7.0, 16.0)
	var pick: int = -1
	var seen: int = 0
	for i in sim.count():
		if sim.alive[i] and sim.team[i] == WorldSim.SANITATION:
			seen += 1
			if _rng.randi() % seen == 0:      # reservoir pick, one pass
				pick = i
	if pick < 0:
		return
	_sfx_at(Vector3(sim.pos[pick].x, 1.0, sim.pos[pick].y), _sfx_sanvox[_rng.randi() % _sfx_sanvox.size()], -1.0)


func _sfx_at(at: Vector3, stream: AudioStream, vol_db: float = 0.0) -> void:
	if stream == null or _sfx_pool.is_empty():
		return
	var p: AudioStreamPlayer3D = _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_pool.size()
	p.stream = stream
	p.position = at
	p.volume_db = vol_db
	p.play()


func _score_kill(unit: StringName) -> void:
	_kills += 1
	if unit == &"san":
		_san_kills += 1
	# Only the infected charge the AC-130 killstreak (the zombie kill counter).
	if unit == &"zed" or unit == &"run" or unit == &"bru":
		_zombie_kills += 1
	_score += int(KILL_PTS.get(unit, 10))


## STRK / V: arm (or cancel) target designation, if a fire mission is charged.
## While armed, the next tap/click on the ground calls the strike there.
func _request_strike() -> void:
	if _zombie_kills >= AC_UNLOCK:
		_strike_arming = not _strike_arming
	else:
		_strike_arming = false


## Call the strike at a designated ground point. Everything in the ring dies --
## friendly fire included, so mind your own squad.
func _fire_ac130_at(target: Vector2) -> void:
	if _zombie_kills < AC_UNLOCK or _strike_pending:
		return
	_zombie_kills = 0          # spend the killstreak; earn the next 100
	_strike_arming = false
	_strike_target = target
	_strike_tof = 0.0
	_strike_pending = true                        # round in flight; impact after STRIKE_TOF
	Audio.comms("open_fire", 0)                   # fire-mission callout


func _process(delta: float) -> void:
	frame_n += 1.0
	if int(frame_n) == 3:
		_layout_controls()   # re-place the touch bar once the viewport size has settled
	if _shot_dir != "":
		_maybe_capture()
	# intro: hold CLOSE on the drop while the squad disembarks, then pull out to the wide
	# gunship view (the default gameplay framing) -- the v0.19 insertion camera.
	if not _menu_active and _intro_t >= 0.0:
		_intro_t += delta
		if _intro_t >= INTRO_HOLD:
			_intro_t = -1.0
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
	if _strike_pending:
		_strike_tof += delta
		if _strike_tof >= STRIKE_TOF:
			_strike_pending = false
			_strike_pos = _strike_target
			_strike_t = 0.0
			sim.air_strike(_strike_target, STRIKE_R, STRIKE_DMG)   # impact: kills + "strike" event
			_spawn_flash3d(_strike_target, STRIKE_R * 0.7, 0.55, 3.0)   # hot blast on the feed
	_sync_visuals(delta)
	_drain_audio()
	_strike_t += delta
	_age_flashes(delta)
	_age_flash3d(delta)
	_advance_loot(delta)
	_advance_deploy(delta)
	_collect_hdd_pickups()
	if _flame_sfx_cd > 0.0:
		_flame_sfx_cd = maxf(0.0, _flame_sfx_cd - delta)
	if _sani_music_on:
		_ride_sani_music()
	if _loot_toast_t > 0.0:
		_loot_toast_t = maxf(0.0, _loot_toast_t - delta)
	_ambient_combat(delta)
	_advance_panic(delta)
	_sanitation_vox(delta)
	_scan_t += delta
	_scan_pulse_t += delta
	_update_move_marker()
	_update_ac_buttons()
	_update_scan_button()
	_update_status_panel()
	if _bar_l != null:
		# control bars: hidden at the menu and once the game is over (debrief needs no controls)
		var show_bars: bool = not _menu_active and (mission == null or mission.result == Mission.ONGOING)
		_bar_l.visible = show_bars
		_bar_r.visible = show_bars

	if _menu_active:
		_update_menu(delta)
	if not _menu_active and not _nuke_fired and _hdd >= NUKE_HDD and mission != null and mission.result == Mission.ONGOING:
		_fire_nuke()
	# the Sanitation force lands when the evac helo lifts off (T+EVAC_LEAVE), not on a kill count
	if not _menu_active and not _tutorial and not _sani_deployed and mission != null and mission.result == Mission.ONGOING and mission.t >= Mission.EVAC_LEAVE:
		_deploy_sanitation()
	if mission != null and not _menu_active:
		_recompute_alliances()          # a rival worn down to its last man begs off
		var was: int = mission.result
		mission.update(sim, delta, _sani_deployed)
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
	if mv != Vector2.ZERO and not _menu_active:
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
	if f.orbit > 0.0 and cut_t < 0.0:
		cam_az += f.orbit * delta            # the gunship always pylon-turns -- no static view

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
	# Bloom haloes hot bodies at tactical range (correct) but at the wide view the mostly-cold-
	# ocean frame drops the scene median, collapses the bloom threshold, and the whole city
	# blooms over the sea -- washing out the land/water/bridge read. Taper it right down with
	# altitude so the map stays legible. (_map_overview forces it to 0 for captures.)
	sensor_mat.set_shader_parameter("bloom", lerpf(0.50, 0.05, clampf((cam_dist - 380.0) / 800.0, 0.0, 1.0)))

	cut_mat.set_shader_parameter("cut_p", p)
	cut_mat.set_shader_parameter("frame_n", frame_n)
	cut_mat.set_shader_parameter("cctv", cctv)
	if sel_layer != null:
		sel_layer.queue_redraw()
	if _warn_ctrl != null:
		_warn_ctrl.queue_redraw()

	if _menu_active:
		hud.text = ""                       # the menu stays clean -- just the sweep + the ping
	elif p >= 0.0 and p < 0.46:
		hud.text = "" if int(frame_n) % 16 < 8 else "SIGNAL ACQ"
	else:
		hud.text = "%s\n%s\n\nFEED  %s\nSQUAD %d/%d   STANCE %s\nMODE  %s\nRES   %dx%d\nALT   %d M   SLANT %d M\nAGC   %s %.3f/%.3f\nFPS   %d" % [
			_mission_line(),
			_intel_line(),
			"AC-130 / PYLON TURN" if feed == "orbit" else "ELEMENT / GROUND",
			sim.element_ids(0).size(), _squad_max, ("PASSIVE" if _passive else "ENGAGE"),
			MODE_NAMES[mode], snap_res.x, snap_res.y,
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
	if mission.result == Mission.WON:
		return mission.reason + "  //  WIN"
	if mission.result == Mission.LOST:
		return "OVERRUN  //  TEAM LOST"
	var clock: String = "T+%d:%02d" % [int(mission.t) / 60, int(mission.t) % 60]
	if _sani_deployed:
		return "SANITATION LOOSE -- REACH A BRIDGE OR WIPE THEM   %s" % clock
	if mission.evac_open():
		var left: int = int(ceil(Mission.EVAC_LEAVE - mission.t))
		return "EVAC ON STATION -- BOARD THE LZ  (%d:%02d LEFT)   %s" % [left / 60, left % 60, clock]
	# before the bird arrives: hold out; escape or wipe the rivals if you can
	var until: int = int(ceil(Mission.EVAC_ARRIVE - mission.t))
	var obj: String = "ELIMINATE %d TEAMS / ESCAPE" % mission.rivals_left(sim) if _team_count > 1 else "HOLD / ESCAPE"
	return "%s -- EVAC IN %d:%02d   %s" % [obj, until / 60, until % 60, clock]


## The intel line under the objective: running HDD count, plus the last loot result
## while its toast is still up.
func _intel_line() -> String:
	var s: String = "INTEL  HDD %d" % _hdd
	if _hdd >= 40:
		s += "  [!] CRITICAL MASS %d/%d" % [_hdd, NUKE_HDD]   # a nuke waits at NUKE_HDD
	if _loot_toast_t > 0.0 and _loot_toast != "":
		s += "   //  " + _loot_toast
	return s


## Post-mission debrief: finalise the score (extractions + full-squad bonus + a
## point per second held out), then print the tally as a sensor-feed readout.
func _show_banner(won: bool) -> void:
	if banner == null:
		return
	var extracted: int = 0
	for i in sim.count():
		if sim.extracted[i] and sim.team[i] == WorldSim.SQUAD and sim.element[i] == 0:
			extracted += 1
	if won:
		_score += FULLSQUAD_PTS
	_score += int(mission.t)             # survival: a point for every second you lasted
	# HDDs recovered multiply the whole board (x1 per HDD, so 3 HDDs = x1.3).
	var mult: float = 1.0 + 0.1 * float(_hdd)
	_score = maxi(0, int(round(float(_score) * mult)))

	var mm: int = int(mission.t) / 60
	var ss: int = int(mission.t) % 60
	var headline: String = mission.reason if won else ("NUCLEAR DETONATION -- TOTAL LOSS" if _nuke_fired else "OVERRUN")
	var rows: PackedStringArray = [
		headline,
		"",
		"YOUR TEAM EXTRACTED   %d" % extracted,
		"HOSTILES DOWN         %d" % _kills,
		"SANITATION ELITES     %d" % _san_kills,
		"CIVILIAN COLLATERAL   %d" % _collateral,
		"HDDs RECOVERED        %d  (x%.1f)" % [_hdd, mult],
		"SURVIVAL              T+%d:%02d" % [mm, ss],
		"",
		"SCORE   %d" % _score,
	]
	banner.text = "\n".join(rows)
	banner.add_theme_font_size_override("font_size", 26)
	banner.add_theme_color_override("font_color", Color(0.44, 0.80, 0.52) if won else Color(1.0, 0.5, 0.42))
	# dim the frozen battlefield behind the printout so the readout reads cleanly
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = Color(0.0, 0.02, 0.0, 0.72)
	banner.add_theme_stylebox_override("normal", bg)
	banner.visible = true


const SEL_COL: Color = Color(0.85, 1.00, 0.85, 0.95)   # bright selection overlay, over the team-coloured ID bracket

## Menu backdrop bookkeeping: fire the scanner ping on an irregular beat (its own SFX),
## and when the Sanitation force has cleared every other entity, roll the sim over.
func _update_menu(delta: float) -> void:
	if sim == null:
		return
	# top-down look over the whole map for the menu backdrop (always slowly turning)
	cam_el = 1.45
	cam_dist = 1600.0
	if city != null:
		cam_tx = city.land.get_center().x
		cam_tz = city.land.get_center().y
	_menu_ping_age += delta
	if _menu_ping_age >= _menu_ping_next:
		_menu_ping_age = 0.0
		_menu_ping_next = _rng.randf_range(5.5, 8.5)   # irregular cadence
		if _sfx_scan != null:
			Audio.sfx(_sfx_scan, 1.0, 0.6)   # sonar-low, like the gameplay scan
	if not _menu_resetting and _menu_prey_left() == 0:
		_menu_reset_cycle()


## Living entities that AREN'T the Sanitation force -- the sweep's remaining prey.
func _menu_prey_left() -> int:
	var n: int = 0
	for i in sim.count():
		if sim.alive[i] and sim.team[i] != WorldSim.SANITATION:
			n += 1
	return n


## The Sanitation force is all that's left: fade the feed to black, respawn a fresh city
## + population, then fade back in for a new sweep. Menu options stay up throughout.
func _menu_reset_cycle() -> void:
	if _menu_resetting or _menu_fade == null:
		return
	_menu_resetting = true
	var tw: Tween = create_tween()
	tw.tween_property(_menu_fade, "color:a", 1.0, 1.2)
	await tw.finished
	await _rebuild_world()                 # fresh menu sim (still _menu_sim, so Sanitation reseeds)
	_menu_ping_age = MENU_PING_SHOW        # let a ping fire soon after the reveal
	var tw2: Tween = create_tween()
	tw2.tween_property(_menu_fade, "color:a", 0.0, 1.2)
	await tw2.finished
	_menu_resetting = false


## The menu's ISR scanner ping: on each beat, rays lance from the SPECTRE PROTOCOL title
## out to every contact and drop a bracket on it, then the whole paint fades over 5 s.
## Nothing else draws in the menu -- no reticle, no persistent tags.
func _draw_menu_scan() -> void:
	if sim == null or _menu_title == null:
		return
	# ALWAYS mark the Sanitation force in red so you can watch them roam + sanitize the map.
	for i in sim.count():
		if sim.alive[i] and sim.team[i] == WorldSim.SANITATION:
			var sw: Vector3 = Vector3(sim.pos[i].x, 0.9, sim.pos[i].y)
			if not cam.is_position_behind(sw):
				_corner_box(_screen_point(sw), 6.0, TAG_ENEMY)
	var t: float = _menu_ping_age
	if t >= MENU_PING_SHOW:
		return
	var origin: Vector2 = _menu_title.get_global_rect().get_center()
	var reach: float = clampf(t / 0.5, 0.0, 1.0)                       # rays lance out over 0.5 s
	var fade: float = 1.0 if t < 1.0 else clampf(1.0 - (t - 1.0) / (MENU_PING_SHOW - 1.0), 0.0, 1.0)
	var strobe: float = 1.0
	if t < 0.6:
		strobe = 0.3 + 0.7 * (0.5 + 0.5 * sin(t * 47.0))              # irregular flicker as it fires
	var a: float = fade * strobe
	if a <= 0.01:
		return
	var green: Color = Color(0.32, 0.80, 0.44, a)
	var ray: Color = Color(0.32, 0.80, 0.44, a * 0.45)
	var drawn: int = 0
	for i in sim.count():
		if drawn >= MENU_RAY_MAX:
			break
		if not sim.alive[i]:
			continue
		var w: Vector3 = Vector3(sim.pos[i].x, 0.9, sim.pos[i].y)
		if cam.is_position_behind(w):
			continue
		var tp: Vector2 = _screen_point(w)
		sel_layer.draw_line(origin, origin.lerp(tp, reach), ray, 1.0)
		if reach >= 1.0:
			# the Sanitation force keeps its red brackets on every ping; the rest green
			var bcol: Color = TAG_ENEMY if sim.team[i] == WorldSim.SANITATION else green
			_corner_box(tp, 5.0, Color(bcol.r, bcol.g, bcol.b, a))
		drawn += 1


func _draw_selection() -> void:
	if cut_t >= 0.0:
		return                      # the overlay generator rides the same signal
	if _menu_active:
		_draw_menu_scan()           # menu: only the scanner-ping paints the feed, nothing else
		return
	if mission != null and mission.result != Mission.ONGOING:
		return                      # mission over: clear the sensor clutter for the debrief
	# (no drawn road overlay -- the asphalt road corridors in the map speak for themselves)
	_draw_loot()
	_draw_hdd_pickups()
	_draw_landmarks()
	_draw_move_marker()
	_draw_hud()
	_draw_scan_pulse()
	_draw_allegiance()
	_draw_unit_boxes()
	_draw_tags(ThemeDB.fallback_font)
	_draw_flashes()
	_draw_incoming()
	# (selection brackets are drawn per-unit inside _draw_unit_boxes now -- one combined marker)
	if dragging:
		var m: Vector2 = get_viewport().get_mouse_position()
		sel_layer.draw_rect(Rect2(drag_start, m - drag_start), SEL_COL, false, 1.0)
	_draw_escapes()
	_draw_evac()


## The ISR scan sweep: a green ring expanding from the reticle out past the corners,
## fading as it goes -- the pulse that paints the enemy teams for the reveal window.
func _draw_scan_pulse() -> void:
	if _scan_pulse_t >= SCAN_PULSE or sim == null:
		return
	var cmd: int = _commander()
	if cmd < 0:
		return
	# the pulse expands FLAT ON THE GROUND from the commander -- a world-space ring
	# projected to screen (an ellipse in perspective), not a screen-space disc.
	var o: Vector2 = sim.pos[cmd]
	var k: float = _scan_pulse_t / SCAN_PULSE
	var rad_m: float = k * SCAN_RANGE
	var a: float = (1.0 - k) * 0.85
	_draw_ground_ring(o, rad_m, Color(0.32, 0.80, 0.44, a), 2.5)
	_draw_ground_ring(o, rad_m * 0.7, Color(0.32, 0.80, 0.44, a * 0.5), 1.5)


## A ring lying FLAT on the ground: a world-space circle of radius `rad_m` metres about a
## ground point, projected to screen. Breaks the line if it wraps behind the camera.
func _draw_ground_ring(centre: Vector2, rad_m: float, col: Color, width: float) -> void:
	if rad_m < 0.5:
		return
	var pts: PackedVector2Array = PackedVector2Array()
	var seg: int = 48
	for s in seg + 1:
		var ang: float = float(s) / float(seg) * TAU
		var w: Vector3 = Vector3(centre.x + cos(ang) * rad_m, 0.3, centre.y + sin(ang) * rad_m)
		if cam.is_position_behind(w):
			break
		pts.append(_screen_point(w))
	if pts.size() >= 2:
		sel_layer.draw_polyline(pts, col, width)


## The move-order marker: a spinning equilateral triangle at the destination. It stays up
## the whole way there and vanishes the instant the commanded units arrive (see
## _update_move_marker) -- so you always know where you last sent them.
func _draw_move_marker() -> void:
	if not _move_marker.has("pos"):
		return
	var g: Vector2 = _move_marker["pos"]
	var col: Color = Color(0.40, 0.80, 0.52, 0.95)
	var r: float = 3.6                          # metres on the ground plane (40% smaller)
	var spin: float = frame_n * 0.05
	# build the triangle in WORLD space on the ground, then project -- so it lies flat on
	# the ground in perspective (a spinning decal), not a flat billboard facing the camera.
	var pts: PackedVector2Array = PackedVector2Array()
	for k in 3:
		var ang: float = spin + float(k) * TAU / 3.0 - PI * 0.5
		var w: Vector3 = Vector3(g.x + cos(ang) * r, 0.3, g.y + sin(ang) * r)
		if cam.is_position_behind(w):
			return
		pts.append(_screen_point(w))
	pts.append(pts[0])
	sel_layer.draw_polyline(pts, col, 2.0)


## Drop the move marker the instant the commanded units reach it (their centroid within
## MOVE_ARRIVE_M), or if they're all gone.
func _update_move_marker() -> void:
	if not _move_marker.has("pos"):
		return
	var g: Vector2 = _move_marker["pos"]
	var sum: Vector2 = Vector2.ZERO
	var n: int = 0
	for i in _move_marker["ids"]:
		if i < sim.count() and sim.alive[i]:
			sum += sim.pos[i]
			n += 1
	if n == 0 or (sum / float(n)).distance_to(g) <= MOVE_ARRIVE_M:
		_move_marker.clear()


## Loot: a filling ring on the building you're holding, and a small dim ring on each
## building already cleared (only at tactical zoom, where it's a useful read).
func _draw_loot() -> void:
	if city == null:
		return
	if cam_dist < 520.0:
		var mk: Color = Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.28)
		for idx in _looted:
			var lb: Dictionary = city.buildings[idx]
			var m3: Vector3 = Vector3(lb["x"] + lb["w"] * 0.5, 0.5, lb["z"] + lb["d"] * 0.5)
			if cam.is_position_behind(m3):
				continue
			sel_layer.draw_arc(_screen_point(m3), 5.0, 0.0, TAU, 12, mk, 1.5)
	if _loot_idx >= 0:
		var b: Dictionary = city.buildings[_loot_idx]
		var c3: Vector3 = Vector3(b["x"] + b["w"] * 0.5, 0.5, b["z"] + b["d"] * 0.5)
		if not cam.is_position_behind(c3):
			var p: Vector2 = _screen_point(c3)
			var k: float = clampf(_loot_t / LOOT_TIME, 0.0, 1.0)
			sel_layer.draw_arc(p, 15.0, 0.0, TAU, 28, Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.22), 2.0)
			sel_layer.draw_arc(p, 15.0, -PI * 0.5, -PI * 0.5 + TAU * k, 28, HUD_COL, 2.5)


## Dedicated HDD drives: a small rotating diamond wherever one waits, faint across the
## map and captioned "HDD" once it's inside the centre reticle box (AC-130 tag rules).
func _draw_hdd_pickups() -> void:
	if _hdd_pickups.is_empty():
		return
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var ctr: Vector2 = win * 0.5
	var rb: float = minf(win.x, win.y) * 0.24
	var box: Rect2 = Rect2(ctr.x - rb, ctr.y - rb, rb * 2.0, rb * 2.0)
	var spin: float = frame_n * 0.05
	var font: Font = ThemeDB.fallback_font
	for g in _hdd_pickups:
		var w3: Vector3 = Vector3(g.x, 0.5, g.y)
		if cam.is_position_behind(w3):
			continue
		var p: Vector2 = _screen_point(w3)
		var inside: bool = box.has_point(p)
		var col: Color = Color(TAG_VEHICLE.r, TAG_VEHICLE.g, TAG_VEHICLE.b, 0.9 if inside else 0.34)   # HDDs are the only yellow now
		var r: float = 5.0
		var pts: PackedVector2Array = PackedVector2Array()
		for a in 4:
			var ang: float = spin + float(a) * PI * 0.5
			pts.append(p + Vector2(cos(ang), sin(ang)) * r)
		pts.append(pts[0])
		sel_layer.draw_polyline(pts, col, 1.5)
		if inside:
			sel_layer.draw_string(font, p + Vector2(9.0, 3.0), "HDD", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


## The two bridge escape zones, ringed on the deck -- the only ways out. Green,
## labelled EXIT, wherever they fall on screen so you can steer for one.
func _draw_escapes() -> void:
	if mission == null or mission.result != Mission.ONGOING or city == null:
		return
	var col: Color = Color(0.40, 0.80, 0.48, 0.85)
	for z in city.escapes:
		var centre: Vector3 = Vector3(z.position.x + z.size.x * 0.5, 0.6, z.position.y + z.size.y * 0.5)
		if cam.is_position_behind(centre):
			continue
		var c: Vector2 = _screen_point(centre)
		var edge: Vector2 = _screen_point(centre + Vector3(maxf(z.size.x, z.size.y) * 0.5, 0.0, 0.0))
		var rad: float = clampf(c.distance_to(edge), 8.0, 70.0)
		sel_layer.draw_arc(c, rad, 0.0, TAU, 40, col, 2.0)
		sel_layer.draw_string(ThemeDB.fallback_font, c + Vector2(rad + 5.0, 4.0), "EXIT", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)


## The evac-helo LZ(s), drawn only while the bird is on station (T+2:00 .. T+3:00). A green
## ring with a spinning rotor cross; once it lifts off (Sanitation lands) these vanish.
func _draw_evac() -> void:
	if mission == null or mission.result != Mission.ONGOING or _sani_deployed or not mission.evac_open():
		return
	var col: Color = Color(0.44, 0.80, 0.54, 0.85)
	for z in mission.evacs:
		var centre: Vector3 = Vector3(z.position.x + z.size.x * 0.5, 0.6, z.position.y + z.size.y * 0.5)
		if cam.is_position_behind(centre):
			continue
		var c: Vector2 = _screen_point(centre)
		var edge: Vector2 = _screen_point(centre + Vector3(maxf(z.size.x, z.size.y) * 0.5, 0.0, 0.0))
		var rad: float = clampf(c.distance_to(edge), 10.0, 80.0)
		sel_layer.draw_arc(c, rad, 0.0, TAU, 40, col, 2.0)
		var a: float = frame_n * 0.14
		for s in 2:
			var d: Vector2 = Vector2(cos(a + float(s) * PI * 0.5), sin(a + float(s) * PI * 0.5)) * rad * 0.72
			sel_layer.draw_line(c - d, c + d, Color(col.r, col.g, col.b, 0.5), 1.5)
		sel_layer.draw_string(ThemeDB.fallback_font, c + Vector2(rad + 5.0, 4.0), "EVAC", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)


## Small in-world headers over the named civic buildings + the evac takeoff pad -- police
## station, hospitals, bio lab, and where the chopper lifts from. Reads at tactical/mid
## zoom, fades out at the wide pull-back. Not fogged (these are known landmarks).
func _draw_landmarks() -> void:
	if _menu_active or city == null:
		return
	var a: float = clampf((900.0 - cam_dist) / 260.0, 0.0, 1.0)
	if a <= 0.02:
		return
	var font: Font = ThemeDB.fallback_font
	for lm in _landmarks:
		var pos: Vector2 = lm["pos"]
		var p3: Vector3 = Vector3(pos.x, 7.0, pos.y)
		if cam.is_position_behind(p3):
			continue
		_landmark_header(font, _screen_point(p3), String(lm["name"]), Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, a))
	if mission != null and mission.result == Mission.ONGOING:
		var gc: Color = Color(0.44, 0.80, 0.54, a)
		for z in mission.evacs:
			var c3: Vector3 = Vector3(z.get_center().x, 6.0, z.get_center().y)
			if cam.is_position_behind(c3):
				continue
			_landmark_header(font, _screen_point(c3), "EVAC LZ", gc)


## A centred header label with a small narrow INVERTED triangle (apex down) marking the
## structure below it -- reads as part of the HUD, not a stray tick.
func _landmark_header(font: Font, p: Vector2, text: String, col: Color) -> void:
	var fs: int = 11
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	sel_layer.draw_colored_polygon(PackedVector2Array([
		p + Vector2(-2.6, 0.0), p + Vector2(2.6, 0.0), p + Vector2(0.0, 6.0)]), col)
	sel_layer.draw_string(font, Vector2(p.x - w * 0.5, p.y - 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## A tiny allegiance pip over each contact you can SEE -- the v0.19 coloured-unit read, so
## warm human shapes (squad / bandit / survivor) don't all look alike on FLIR. Fog of war:
## a contact is pipped only within your units' line of sight or a live commander scan;
## purple horde, red loose combatants, white civilians. Sanitation shows a black signature
## with red brackets + the radiation trefoil once identified.
func _draw_allegiance() -> void:
	for i in sim.count():
		if not sim.alive[i] or sim.team[i] == WorldSim.SQUAD:
			continue
		if not _identified(i):
			continue                                                        # fog of war: only what you can see
		var w: Vector3 = Vector3(sim.pos[i].x, 0.9, sim.pos[i].y)
		if cam.is_position_behind(w):
			continue
		var p: Vector2 = _screen_point(w)
		var t: int = sim.team[i]
		if t == WorldSim.SANITATION:
			sel_layer.draw_circle(p, 2.7, Color(0.05, 0.05, 0.06, 0.95))   # black hull
			_corner_box(p, 5.5, TAG_ENEMY)                                 # red brackets
			_unit_glyph(&"san", p - Vector2(0.0, 13.0), 5.0, TAG_ENEMY)    # radiation trefoil
		else:
			var col: Color = _alleg_color(t)
			if col.a > 0.0:
				sel_layer.draw_circle(p, 2.5, col)


func _alleg_color(t: int) -> Color:
	match t:
		WorldSim.SQUAD: return Color(0.90, 0.95, 1.00, 0.90)      # my units, white (green brackets)
		WorldSim.SANITATION: return Color(0.05, 0.05, 0.06, 0.95) # black hull, red brackets
		WorldSim.BANDIT: return Color(1.00, 0.30, 0.30, 0.90)     # loose combatant, red
		WorldSim.SURVIVOR: return Color(1.00, 0.30, 0.30, 0.90)   # loose combatant, red
		WorldSim.INFECTED: return Color(0.72, 0.42, 0.95, 0.80)   # the horde, purple
		WorldSim.CIVILIAN: return Color(0.92, 0.94, 1.00, 0.60)   # civilian, white
	return Color(0, 0, 0, 0)


## Squad brackets, ALL IN ONE per unit: a THIN, SMALL team-coloured ID bracket always on,
## plus -- only when the unit is selected -- a slightly larger bracket overlaid on top (so a
## selected unit reads as one combined marker, not a pile of brackets). Zoomed way out, drop
## the per-unit clutter for ONE team caret over the active element.
func _draw_unit_boxes() -> void:
	if sim == null:
		return
	if cam_dist > TEAM_CARET_ZOOM:
		var ctr: Vector3 = _follow_point()
		var wc: Vector3 = Vector3(ctr.x, 6.0, ctr.z)
		if not cam.is_position_behind(wc):
			var tc: Color = _team_colors[active_element] if active_element < _team_colors.size() else TAG_FRIEND
			_caret(_screen_point(wc), 15.0, tc, true)
		return
	for i in sim.count():
		if not sim.alive[i] or sim.team[i] != WorldSim.SQUAD:
			continue
		if sim.element[i] != 0 and not _identified(i):
			continue                                  # fog of war: a rival team you can't see yet
		var w: Vector3 = Vector3(sim.pos[i].x, 0.9, sim.pos[i].y)
		if cam.is_position_behind(w):
			continue
		var p: Vector2 = _screen_point(w)
		var col: Color = _squad_col(i)
		_corner_box(p, 4.0, col, 1.0)                 # thin, small ID bracket (interior corners)
		if sim.selected[i]:
			_corner_box(p, 8.0, SEL_COL, 1.5)         # selection bracket overlays -- all in one
		# the role glyph over the head -- your team + any rival team you can see
		_unit_glyph(sim.kind[i], p - Vector2(0.0, 13.0), 4.5, col)


## AC-130 target tags -- ONLY inside the centre reticle box, like the real optic when
## it's slewed onto a target. Yellow vehicles, green friendlies, red hostiles, red
## carets + range on the horde. Gated to zoomed-in views + capped so it never clutters.
func _draw_tags(font: Font) -> void:
	if sim == null or cam_dist > TAG_ZOOM_MAX:
		return
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var c: Vector2 = win * 0.5
	var rb: float = minf(win.x, win.y) * 0.24
	var box: Rect2 = Rect2(c.x - rb, c.y - rb, rb * 2.0, rb * 2.0)
	var me3: Vector3 = _follow_point()
	var me: Vector2 = Vector2(me3.x, me3.z)
	var look: Vector2 = Vector2(cam_tx, cam_tz)
	var r2: float = pow(cam_dist * 0.4, 2.0)   # skip anything too far from the reticle to be in the box
	var drawn: int = 0
	# (no vehicle tags -- yellow is reserved for the HDD pickups now)
	for i in sim.count():
		if drawn > 60:
			break
		if not sim.alive[i] or sim.team[i] == WorldSim.CIVILIAN:
			continue
		if sim.pos[i].distance_squared_to(look) > r2:
			continue
		var w: Vector3 = Vector3(sim.pos[i].x, 0.9, sim.pos[i].y)
		if cam.is_position_behind(w):
			continue
		var p: Vector2 = _screen_point(w)
		if not box.has_point(p):
			continue
		var t: int = sim.team[i]
		var mine: bool = t == WorldSim.SQUAD and sim.element[i] == 0
		if not mine and not _identified(i):
			continue                             # fog of war: tag only what you can see
		if t == WorldSim.SQUAD:
			continue                             # squad already boxed by _draw_unit_boxes -- no double bracket
		elif t == WorldSim.INFECTED:
			_caret(p - Vector2(0.0, 9.0), 5.0, TAG_ZED, true)
			sel_layer.draw_string(font, p + Vector2(7.0, -3.0), "%dm" % int(sim.pos[i].distance_to(me)), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, TAG_ZED)
		else:
			_corner_box(p, 7.0, TAG_ENEMY)       # sanitation / bandit / survivor
		drawn += 1


## An AC-130 corner-bracket box around p (half-size h): four L-shaped corners.
func _corner_box(p: Vector2, h: float, col: Color, width: float = 1.5) -> void:
	var a: float = h * 0.55
	for k in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var cn: Vector2 = p + Vector2(k.x * h, k.y * h)
		sel_layer.draw_line(cn, cn - Vector2(k.x * a, 0.0), col, width)
		sel_layer.draw_line(cn, cn - Vector2(0.0, k.y * a), col, width)


## A hollow triangle (outline) centred at p. down=true points the apex down (at a unit).
func _caret(p: Vector2, size: float, col: Color, down: bool) -> void:
	var s: float = 1.0 if down else -1.0
	var a: Vector2 = p + Vector2(-size, -size * s)
	var b: Vector2 = p + Vector2(size, -size * s)
	var apex: Vector2 = p + Vector2(0.0, size * s)
	sel_layer.draw_line(a, b, col, 1.5)
	sel_layer.draw_line(b, apex, col, 1.5)
	sel_layer.draw_line(apex, a, col, 1.5)


## The role glyph that sits over a unit's head -- one distinct shape per unit type so
## you can read a team's composition at a glance (all teams, incl. scanned enemies):
## combat down-triangle, commander diamond, medic cross, sniper turned-Y, recon bullseye,
## EOD pentagon, sanitation radiation trefoil.
func _unit_glyph(kind: StringName, p: Vector2, s: float, col: Color) -> void:
	match kind:
		&"cdr":                                  # commander -- diamond
			sel_layer.draw_polyline(PackedVector2Array([
				p + Vector2(0, -s), p + Vector2(s, 0), p + Vector2(0, s), p + Vector2(-s, 0), p + Vector2(0, -s)]), col, 1.5)
		&"med":                                  # medic -- cross
			sel_layer.draw_line(p + Vector2(0, -s), p + Vector2(0, s), col, 2.0)
			sel_layer.draw_line(p + Vector2(-s, 0), p + Vector2(s, 0), col, 2.0)
		&"snp":                                  # sniper -- turned Y (fork up, stem down)
			sel_layer.draw_line(p, p + Vector2(0, s), col, 1.5)
			sel_layer.draw_line(p, p + Vector2(-s * 0.85, -s), col, 1.5)
			sel_layer.draw_line(p, p + Vector2(s * 0.85, -s), col, 1.5)
		&"rec":                                  # recon -- bullseye
			sel_layer.draw_arc(p, s, 0.0, TAU, 16, col, 1.5)
			sel_layer.draw_circle(p, s * 0.34, col)
		&"eod":                                  # EOD -- pentagon
			var pent: PackedVector2Array = PackedVector2Array()
			for a in 6:
				var ang: float = -PI * 0.5 + float(a) * TAU / 5.0
				pent.append(p + Vector2(cos(ang), sin(ang)) * s)
			sel_layer.draw_polyline(pent, col, 1.5)
		&"san":                                  # sanitation -- radiation trefoil
			sel_layer.draw_circle(p, s * 0.3, col)
			for a in 3:
				var ang: float = -PI * 0.5 + float(a) * TAU / 3.0
				sel_layer.draw_colored_polygon(PackedVector2Array([
					p + Vector2(cos(ang - 0.42), sin(ang - 0.42)) * s * 0.55,
					p + Vector2(cos(ang), sin(ang)) * s,
					p + Vector2(cos(ang + 0.42), sin(ang + 0.42)) * s * 0.55]), col)
		_:                                       # combat + fallback -- down triangle
			_caret(p, s, col, true)


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

	# AC-130 fire-mission status -- by its BUTTONS (bottom-right), right-aligned above the bar.
	var ac_txt: String
	var ac_col: Color
	if _strike_arming:
		ac_txt = "AC-130  DESIGNATE"
		ac_col = HUD_RED
		sel_layer.draw_string(font, Vector2(0.0, 94.0), "DESIGNATE STRIKE  --  TAP TARGET", HORIZONTAL_ALIGNMENT_CENTER, win.x, 15, HUD_RED)
	elif _zombie_kills >= AC_UNLOCK:
		ac_txt = "AC-130 GUNSHIP READY"
		ac_col = HUD_COL
	else:
		ac_txt = "AC-130  %d/%d KILLS" % [_zombie_kills, AC_UNLOCK]
		ac_col = HUD_DIM
	var acw: float = font.get_string_size(ac_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	sel_layer.draw_string(font, Vector2(win.x - 18.0 - acw, win.y - 74.0), ac_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ac_col)

	# (SCAN status now lives ON the SCAN button; the passive/stance line moved to the
	#  top-left element roster + the PSV button.)
	_draw_element_roster(win)
	_draw_top_banner(font, win)
	_draw_attitude(font, win)
	_draw_threat(font, win)
	_draw_strike()


## Top-centre evac clock: a countdown to the helo (T-minus), then the on-station timer.
## (Once Sanitation lands this stops and the RADIATION WARNING takes over -- drawn on the
## top overlay layer so it sits above the bars and everything else, see _draw_radiation_warning.)
func _draw_top_banner(_font: Font, win: Vector2) -> void:
	if _menu_active or mission == null or mission.result != Mission.ONGOING or _sani_deployed:
		return
	var font: Font = _hud_font
	var cx: float = win.x * 0.5
	var y: float = 72.0
	var txt2: String
	if mission.evac_open():
		var left: int = int(ceil(Mission.EVAC_LEAVE - mission.t))
		txt2 = "EVAC ON STATION   %d:%02d LEFT" % [left / 60, left % 60]
	else:
		var until: int = int(ceil(Mission.EVAC_ARRIVE - mission.t))
		txt2 = "EVAC INBOUND   T-%d:%02d" % [until / 60, until % 60]
	var fs2: int = 16
	var tw2: float = font.get_string_size(txt2, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
	var pad2: float = 14.0
	var box2: Rect2 = Rect2(cx - tw2 * 0.5 - pad2, y - 15.0, tw2 + pad2 * 2.0, 27.0)
	sel_layer.draw_rect(box2, Color(0.0, 0.03, 0.0, 0.5), true)
	sel_layer.draw_rect(box2, Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.6), false, 1.5)
	sel_layer.draw_string(font, Vector2(cx - tw2 * 0.5, y + 4.0), txt2, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, HUD_COL)


## A compact roster of the teams in play, under the top-left readout: each element's colour
## swatch, aggregate HP%, headcount, and A(rmor)/B(uff) tallies, plus a [P] when that team
## is passive (allied) with you. Your team is marked YOU.
func _draw_element_roster(win: Vector2) -> void:
	if _menu_active or sim == null or _team_count <= 0:
		return
	var font: Font = _hud_font
	var x: float = 26.0
	var y: float = 236.0
	sel_layer.draw_string(font, Vector2(x, y), "ELEMENTS", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, HUD_DIM)
	y += 17.0
	for e in _team_count:
		var ids: Array = sim.element_ids(e)
		var col: Color = _team_colors[e] if e < _team_colors.size() else HUD_COL
		if ids.is_empty():
			sel_layer.draw_string(font, Vector2(x + 13.0, y), ("YOU" if e == 0 else "T%d" % (e + 1)) + "  WIPED", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.5, 0.5, 0.5, 0.5))
			y += 15.0
			continue
		var hp_sum: float = 0.0
		var hp_max: float = 0.0
		var armored: int = 0
		var buffed: int = 0
		for i in ids:
			hp_sum += sim.hp[i]
			hp_max += WorldSim.STATS[sim.kind[i]][1]
			if sim.armor[i] > 0.0:
				armored += 1
			if sim.buff_t[i] > 0.0:
				buffed += 1
		var pct: int = int(round(100.0 * hp_sum / maxf(1.0, hp_max)))
		sel_layer.draw_rect(Rect2(x, y - 8.0, 8.0, 8.0), col, true)          # team colour swatch
		var line: String = "%s  %d%%  x%d" % ["YOU" if e == 0 else "T%d" % (e + 1), pct, ids.size()]
		if armored > 0:
			line += "  A%d" % armored
		if buffed > 0:
			line += "  B%d" % buffed
		if e != 0 and sim.allied.get(e, false):
			line += "  [P]"
		sel_layer.draw_string(font, Vector2(x + 13.0, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
		y += 15.0


## The Sanitation RADIATION WARNING -- drawn on the TOP overlay layer (above the bars and all
## HUD), a dark-grey transparent header with a red outline + red bloom, present while the
## wipe force is loose.
func _draw_radiation_warning() -> void:
	if _warn_ctrl == null or _menu_active or mission == null or mission.result != Mission.ONGOING or not _sani_deployed:
		return
	var win: Vector2 = _warn_ctrl.size
	var cx: float = win.x * 0.5
	var y: float = 72.0
	var txt: String = "RADIATION WARNING  :  CAUTION  :  SANITATION FORCE DEPLOYED  :  CAUTION  :  EVACUATE IMMEDIATELY"
	var fs: int = 14 if win.x >= 900.0 else 9
	var tw: float = _hud_font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pad: float = 18.0
	var box: Rect2 = Rect2(cx - tw * 0.5 - pad, y - 16.0, tw + pad * 2.0, 30.0)
	var pulse: float = 0.5 + 0.5 * sin(frame_n * 0.11)
	for k in range(5, 0, -1):
		_warn_ctrl.draw_rect(box.grow(float(k) * 7.0), Color(1.0, 0.13, 0.10, 0.04 + 0.03 * pulse), true)
	_warn_ctrl.draw_rect(box, Color(0.07, 0.06, 0.07, 0.78), true)
	_warn_ctrl.draw_rect(box, Color(1.0, 0.28, 0.24, 0.6 + 0.4 * pulse), false, 2.0)
	_warn_ctrl.draw_string(_hud_font, Vector2(cx - tw * 0.5, y + 4.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HUD_RED)


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


## The inbound AC-130 round. The gun flashes big + bright on the RIGHT edge of screen
## (the orbiting gunship's quarter), then the round arcs across over the whole TOF --
## large near the muzzle, tapering as it recedes into the distance -- and lands on the
## designated point. A danger-close ring marks the impact the whole way in.
func _draw_incoming() -> void:
	if not _strike_pending:
		return
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var k: float = clampf(_strike_tof / STRIKE_TOF, 0.0, 1.0)
	var g3: Vector3 = Vector3(_strike_target.x, 0.3, _strike_target.y)
	if cam.is_position_behind(g3):
		return
	var end: Vector2 = _screen_point(g3)
	var edge: Vector2 = _screen_point(Vector3(_strike_target.x + STRIKE_R, 0.3, _strike_target.y))
	sel_layer.draw_arc(end, maxf(6.0, end.distance_to(edge)), 0.0, TAU, 36, Color(1.0, 0.42, 0.30, 0.55), 1.5)
	var start: Vector2 = Vector2(win.x - 40.0, win.y * 0.24)   # the muzzle, high on the right edge
	# muzzle flash: big + bright the instant it fires, fading over the first ~0.5 s
	var lf: float = clampf(1.0 - _strike_tof / 0.5, 0.0, 1.0)
	if lf > 0.0:
		sel_layer.draw_circle(start, 8.0 + lf * 30.0, Color(1.0, 0.95, 0.82, lf * 0.9))
		sel_layer.draw_arc(start, 14.0 + (1.0 - lf) * 46.0, 0.0, TAU, 32, Color(1.0, 0.80, 0.48, lf * 0.7), 3.0)
	# a curved contrail trailing the round along the arc
	var prev: Vector2 = _arc_point(start, end, maxf(0.0, k - 0.18))
	for s in range(1, 7):
		var q: Vector2 = _arc_point(start, end, maxf(0.0, k - 0.18 + 0.18 * float(s) / 6.0))
		sel_layer.draw_line(prev, q, Color(1.0, 0.9, 0.62, 0.18 + 0.55 * float(s) / 6.0), 2.0)
		prev = q
	# the round: large as it leaves the muzzle, shrinking as it flies off into the distance
	var rp: Vector2 = _arc_point(start, end, k)
	var rr: float = lerpf(8.0, 3.0, k)
	sel_layer.draw_circle(rp, rr + 1.5, Color(1.0, 0.68, 0.30, 0.85))
	sel_layer.draw_circle(rp, rr * 0.5, Color(1.0, 0.97, 0.86, 1.0))


## A ballistic screen-space arc from a to b: a straight run bowed upward by
## STRIKE_BOW of its length (0 at both ends, peak at the midpoint).
func _arc_point(a: Vector2, b: Vector2, t: float) -> Vector2:
	var base: Vector2 = a.lerp(b, t)
	base.y -= sin(t * PI) * a.distance_to(b) * STRIKE_BOW
	return base


func _age_flashes(delta: float) -> void:
	var i: int = _flashes.size() - 1
	while i >= 0:
		_flashes[i]["t"] += delta
		if _flashes[i]["t"] > FLASH_LIFE:
			_flashes.remove_at(i)
		i -= 1


func _build_flash_pool() -> void:
	var mat: ShaderMaterial = ThermalLib.get_material("fire", snap_res)
	for _i in FLASH3D_POOL:
		var mi: MeshInstance3D = MeshInstance3D.new()
		var s: SphereMesh = SphereMesh.new()
		s.radius = 1.0
		s.height = 2.0
		s.radial_segments = 12
		s.rings = 6
		mi.mesh = s
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		vp.add_child(mi)
		_flash3d.append(mi)


## Spawn a hot thermal blast at a world point: a fire-hot blob that blooms to
## `peak` metres and fades over `life` s. Pooled -- no-ops if all are busy.
func _spawn_flash3d(pos: Vector2, peak: float, life: float, h: float = 2.0, vel: Vector3 = Vector3.ZERO) -> void:
	if _flash3d.is_empty():
		return
	var mi: MeshInstance3D = _flash3d.pop_back()
	mi.position = Vector3(pos.x, h, pos.y)
	mi.scale = Vector3.ONE * 0.02
	mi.visible = true
	_flash3d_busy.append({"node": mi, "t": 0.0, "life": life, "peak": peak, "vel": vel})


## Sanitation flamethrower: a streaming jet of hot particles. A single burst sprays a
## cone of fire-blobs from the nozzle that FLY outward along the aim and drift upward as
## they fade, so the tongue licks and rolls (vs. the old four static blobs). The thermal
## `fire` material (writhe + shimmer) + the sensor bloom smear them into one live flame.
func _spawn_flame(from: Vector2, to: Vector2) -> void:
	var dir: Vector2 = to - from
	var dist: float = dir.length()
	if dist < 1e-3:
		return
	dir /= dist
	var reach: float = minf(dist, FLAME_LEN)
	var perp: Vector2 = Vector2(-dir.y, dir.x)
	var dir3: Vector3 = Vector3(dir.x, 0.0, dir.y)
	var n: int = 11
	for k in n:
		var f: float = float(k) / float(n - 1)                     # 0 root .. 1 tip
		# seed each blob along the jet so the tongue is fully drawn from the first frame,
		# then give it outward speed (faster toward the tip) + a rising drift.
		var spread: float = (0.5 + f * 1.7) * _rng.randf_range(-1.0, 1.0)
		var p: Vector2 = from + dir * (reach * f) + perp * spread
		var size: float = lerpf(2.0, 0.45, f)                      # fat hot root, thin tip
		var speed: float = 7.0 + f * 12.0
		var v3: Vector3 = dir3 * speed \
			+ Vector3(perp.x, 0.0, perp.y) * (spread * 3.0) \
			+ Vector3(0.0, 2.2 + f * 2.0, 0.0)                     # heat rises, tips roll up
		_spawn_flash3d(p, size, 0.30 + f * 0.16, FLAME_H + f * 0.6, v3)


func _age_flash3d(delta: float) -> void:
	var i: int = _flash3d_busy.size() - 1
	while i >= 0:
		var f: Dictionary = _flash3d_busy[i]
		f["t"] += delta
		var k: float = f["t"] / float(f["life"])
		if k >= 1.0:
			f["node"].visible = false
			_flash3d.append(f["node"])
			_flash3d_busy.remove_at(i)
		else:
			f["node"].scale = Vector3.ONE * maxf(0.02, float(f["peak"]) * sin(k * PI))   # 0 -> peak -> 0
			f["node"].position += (f["vel"] as Vector3) * delta                          # stream + rise
		i -= 1


## Tracers + muzzle flashes: each shot streaks a hot round from shooter to target
## and pips the muzzle, for a few frames, so firefights read on the feed.
func _draw_flashes() -> void:
	for f in _flashes:
		var from2: Vector2 = f["pos"]
		var w_from: Vector3 = Vector3(from2.x, 1.1, from2.y)
		if cam.is_position_behind(w_from):
			continue
		var sp: Vector2 = _screen_point(w_from)
		var fade: float = 1.0 - float(f["t"]) / FLASH_LIFE
		# tracer streak shooter -> target
		var to2: Vector2 = f["to"]
		var w_to: Vector3 = Vector3(to2.x, 1.1, to2.y)
		if not cam.is_position_behind(w_to):
			sel_layer.draw_line(sp, _screen_point(w_to), Color(1.0, 0.74, 0.34, fade * 0.7), 1.5)
		# muzzle pip: warm ring + hot white core, reads on bright land + dark ocean
		var r: float = 3.0 + fade * 2.0
		sel_layer.draw_circle(sp, r, Color(1.0, 0.60, 0.18, fade * 0.9))
		sel_layer.draw_circle(sp, r * 0.42, Color(1.0, 0.96, 0.82, fade))


## Attitude gauge, bottom-left: a heading dial with the optic azimuth pointer, the
## optic elevation, and the pylon-turn state -- the AC-130's bank/attitude circle.
func _draw_attitude(font: Font, win: Vector2) -> void:
	var gc: Vector2 = Vector2(win.x - 60.0, win.y - 150.0)   # FAR RIGHT now (above the AC-130 status + bar)
	var gr: float = 24.0
	sel_layer.draw_arc(gc, gr, 0.0, TAU, 40, HUD_DIM, 1.5)
	for a in range(0, 360, 30):
		var av: Vector2 = Vector2(sin(deg_to_rad(a)), -cos(deg_to_rad(a)))
		var inner: float = gr - (8.0 if a % 90 == 0 else 4.0)
		sel_layer.draw_line(gc + av * inner, gc + av * gr, HUD_DIM, 1.5)
	var hv: Vector2 = Vector2(sin(-cam_az), -cos(-cam_az))
	sel_layer.draw_line(gc, gc + hv * (gr - 3.0), HUD_COL, 2.0)
	sel_layer.draw_circle(gc, 2.5, HUD_COL)
	var hdg: int = (int(round(rad_to_deg(-cam_az))) % 360 + 360) % 360
	# labels to the LEFT of the wheel (it sits against the right edge)
	sel_layer.draw_string(font, gc + Vector2(-gr - 62.0, -4.0), "HDG %03d" % hdg, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, HUD_COL)
	sel_layer.draw_string(font, gc + Vector2(-gr - 62.0, 12.0), "EL %02d" % int(rad_to_deg(cam_el)), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, HUD_COL)


## Red threat box (INFESTATION-style): living hostiles + confirmed kills. Game HUD font.
func _draw_threat(_font: Font, win: Vector2) -> void:
	var font: Font = _hud_font
	var hostiles: int = 0
	for i in sim.count():
		if sim.alive[i] and sim.team[i] != WorldSim.SQUAD and sim.team[i] != WorldSim.CIVILIAN:
			hostiles += 1
	var w: float = 200.0
	var box: Rect2 = Rect2(win.x - w - 20.0, 18.0, w, 62.0)
	sel_layer.draw_rect(box, Color(HUD_RED.r, HUD_RED.g, HUD_RED.b, 0.12), true)
	sel_layer.draw_rect(box, HUD_RED, false, 1.5)
	sel_layer.draw_string(font, box.position + Vector2(9.0, 17.0), "INFESTATION", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HUD_RED)
	sel_layer.draw_string(font, box.position + Vector2(9.0, 36.0), "HOSTILES %d   KILLS %d" % [hostiles, _kills], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, HUD_COL)
	sel_layer.draw_string(font, box.position + Vector2(9.0, 54.0), "SCORE %d" % _score, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, HUD_COL)


func _select_in_rect(r: Rect2) -> void:
	for i in sim.count():
		sim.selected[i] = sim.alive[i] and r.abs().has_point(_screen_of(i))


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
		cam_manual = false     # re-take the view


func _input(e: InputEvent) -> void:
	if _menu_active:
		return                     # the menu buttons handle their own clicks; no gameplay input
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
				if _over_ui(e.position):
					_ui_press = true          # let the control-bar button handle it
					return
				_ui_press = false
				dragging = true
				drag_start = e.position
				_begin_loot(e.position)       # hold-to-loot starts here
			elif _ui_press:
				_ui_press = false             # release of a button press -- no gameplay action
			else:
				dragging = false
				_end_loot()
				if e.position.distance_to(drag_start) < 6.0:
					_command_move()          # a click sends the squad to the reticle centre
				else:
					_select_in_rect(Rect2(drag_start, e.position - drag_start))   # drag = box-select
					if not sim.selected_ids().is_empty():
						Audio.comms("ack_affirmative", 2500)
		elif e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
			# right-click: a precise move to the clicked ground (desktop convenience)
			var ids: Array = sim.selected_ids()
			if ids.is_empty():
				_select_element(0)
				ids = sim.selected_ids()
			if not ids.is_empty():
				var g: Vector2 = _ground_pick(e.position)
				sim.order_move(ids, g)
				Audio.comms_order()   # squad acks the move over the net
				_move_marker = {"pos": g, "ids": ids.duplicate()}
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_SPACE: _channel_change("orbit" if feed == "deploy" else "deploy")
			KEY_T: mode = (mode + 1) % 3
			KEY_C: cctv = 0.0 if cctv > 0.0 else 0.85
			KEY_G: agc.frozen = not agc.frozen
			KEY_H:
				show_help = not show_help
				if help != null:
					help.visible = show_help
			KEY_V: _request_strike()          # arm the AC-130
			KEY_B: _fire_reticle()            # fire it on the reticle
			KEY_E: _request_scan()
			KEY_P: _toggle_passive()          # passive stance -- hold fire with other passive teams
			KEY_TAB: _cycle_unit_type()       # cycle which of your unit types is selected
			KEY_Q: _cycle_unit_type()
			KEY_1: _select_all_squad()        # select the whole squad
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
				_begin_loot(e.position)       # hold-to-loot starts here
			elif _touches.size() == 2:
				_pinch_prev = _two_touch_dist()
				_end_loot()                   # a second finger = pinch, not a loot
		else:
			if _touches.size() == 1 and _touch_moved < 14.0 and _touches.has(e.index):
				_handle_tap(e.position)
			_end_loot()
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
	if _bar_l != null and _bar_l.visible and _bar_l.get_global_rect().has_point(pos):
		return true
	if _bar_r != null and _bar_r.visible and _bar_r.get_global_rect().has_point(pos):
		return true
	return false


## A single tap on the field: command the squad to the reticle centre.
func _handle_tap(_pos: Vector2) -> void:
	_command_move()


## Single click / tap: order the current selection -- or your whole squad if nothing is
## picked -- to the ground under the RETICLE CENTRE, and drop the spinning move marker.
func _command_move() -> void:
	var ids: Array = sim.selected_ids()
	if ids.is_empty():
		_select_element(0)                 # nothing picked -> command the whole squad
		ids = sim.selected_ids()
	if ids.is_empty():
		return                             # no one left to command
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var g: Vector2 = _ground_pick(win * 0.5)
	sim.order_move(ids, g)
	Audio.comms_order()
	_move_marker = {"pos": g, "ids": ids.duplicate()}


## Call the AC-130 down on the reticle centre (the FIRE button / key). No-op unless armed
## and unlocked.
func _fire_reticle() -> void:
	if not _strike_arming:
		return
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	_fire_ac130_at(_ground_pick(win * 0.5))


## Cycle the selection through the unit TYPES of the active element (cdr -> cbt -> med
## -> snp -> rec -> eod). 1-4 still pick a whole element; this drills into one role so
## you can peel off, say, the sniper. Empty types (dead) are skipped over on the next tap.
func _cycle_unit_type() -> void:
	_type_idx = (_type_idx + 1) % ELEMENT_ROSTER.size()
	var want: StringName = ELEMENT_ROSTER[_type_idx]
	var found: bool = false
	for i in sim.count():
		var hit: bool = sim.alive[i] and sim.team[i] == WorldSim.SQUAD and sim.element[i] == active_element and sim.kind[i] == want
		sim.selected[i] = hit
		if hit:
			found = true
	if _cyc_btn != null:
		_cyc_btn.text = String(want).to_upper()
	if _all_btn != null:
		_all_btn.modulate = Color(1, 1, 1, 1.0)     # an individual type is up -> ALL lights (return path)
	if found:
		Audio.comms("ack_affirmative", 2500)


## Reflect the ALL-vs-individual selection on the buttons: when ALL is the current selection
## the TYPE box reads ALL and the ALL button goes dark (it IS the state); a single type lights
## the ALL button back up.
func _update_type_all_buttons() -> void:
	var all_sel: bool = _type_idx < 0
	if _cyc_btn != null and all_sel:
		_cyc_btn.text = "ALL"
	if _all_btn != null:
		_all_btn.modulate = Color(1, 1, 1, 0.35) if all_sel else Color(1, 1, 1, 1.0)


## The building under a ground point (AABB test), or -1. O(buildings), press-time only.
func _building_at(g: Vector2) -> int:
	if city == null:
		return -1
	for i in city.buildings.size():
		var b: Dictionary = city.buildings[i]
		if Rect2(b["x"], b["z"], b["w"], b["d"]).has_point(g):
			return i
	return -1


## Begin a loot hold if the press landed on an un-looted building AND your units are near
## it (they have to be there to breach + clear it). _process fills the hold while the
## finger stays put; release cancels.
func _begin_loot(pos: Vector2) -> void:
	_press_pos = pos
	_loot_t = 0.0
	_loot_idx = -1
	if _strike_arming:
		return
	var b: int = _building_at(_ground_pick(pos))
	if b >= 0 and not _looted.has(b):
		var bd: Dictionary = city.buildings[b]
		var c: Vector2 = Vector2(bd["x"] + bd["w"] * 0.5, bd["z"] + bd["d"] * 0.5)
		var near: float = maxf(bd["w"], bd["d"]) * 0.5 + LOOT_NEAR_M     # edge of the building + a margin
		if _nearest_player_unit(c, near) >= 0:                           # a unit is close enough to enter
			_loot_idx = b


func _end_loot() -> void:
	_loot_idx = -1
	_loot_t = 0.0


## Fill the active loot hold; a drag off the spot (pan) or a release cancels it. On
## completion the building is cleared for a loot bonus -- once each.
func _advance_loot(delta: float) -> void:
	if _loot_idx < 0:
		return
	var cur: Vector2 = get_viewport().get_mouse_position()
	if not _touches.is_empty():
		cur = _touches.values()[0]
	if _looted.has(_loot_idx) or cur.distance_to(_press_pos) > LOOT_CANCEL_PX:
		_end_loot()
		return
	_loot_t += delta
	if _loot_t >= LOOT_TIME:
		_resolve_loot(_loot_idx)
		_end_loot()


## What a cleared building held. Every clear pays its base points; on top of that it
## drops an HDD, or a specialist payout (field hospital / police armory / bio-lab), and
## may have been a nest that mauls whoever breached it. Payout class is stable per index.
func _resolve_loot(bidx: int) -> void:
	_looted[bidx] = true
	_loot_count += 1
	_score += LOOT_PTS
	var b: Dictionary = city.buildings[bidx]
	var c: Vector2 = Vector2(b["x"] + b["w"] * 0.5, b["z"] + b["d"] * 0.5)
	var unit: int = _nearest_player_unit(c, 120.0)   # who breached (nearest of your team)
	match _loot_class(bidx):
		LC_HOSP:
			if unit >= 0:
				sim.heal_frac(unit, 0.45)
			_loot_say("FIELD HOSPITAL   +45% HP")
		LC_POLICE:
			if _loot_rng.randf() < 0.5:
				if unit >= 0:
					sim.add_armor(unit, 0.22)
				_loot_say("POLICE ARMORY   +ARMOR")
			else:
				if unit >= 0:
					sim.grant_buff(unit, 24.0, 1.5, 0.0)
				_loot_say("POLICE ARMORY   DMG +50% 24s")
		LC_BIO:
			if unit >= 0:
				sim.grant_buff(unit, 24.0, 1.0, 0.4)
			_loot_say("BIO-LAB   DMG RESIST 24s")
		_:
			_hdd += 1
			_score += LOOT_PTS
			_loot_say("HDD RECOVERED   x%d" % _hdd)
	# any building can turn out to be a nest -- a bite for whoever went in.
	if _loot_rng.randf() < LOOT_AMBUSH_CHANCE:
		_loot_ambush(c, unit)
	else:
		Audio.comms("ack_inposition", 1500)   # "in position" -- clean clear


## Payout class for a building, stable across the mission (a cheap index hash). HDD is
## the common drop; the specialist sites are rarer.
func _loot_class(bidx: int) -> int:
	if _landmark_class.has(bidx):
		return int(_landmark_class[bidx])   # a named civic building pays out its kind
	var r: int = int(abs(bidx * 2654435761)) % 100
	if r < 60:
		return LC_HDD
	if r < 74:
		return LC_HOSP
	if r < 88:
		return LC_POLICE
	return LC_BIO


## Nearest living player-element trooper to a ground point, within `max_m`; -1 if none.
func _nearest_player_unit(g: Vector2, max_m: float) -> int:
	var best: int = -1
	var bd: float = max_m * max_m
	for i in sim.count():
		if not sim.alive[i] or sim.extracted[i]:
			continue
		if sim.team[i] != WorldSim.SQUAD or sim.element[i] != 0:
			continue
		var d: float = g.distance_squared_to(sim.pos[i])
		if d < bd:
			bd = d
			best = i
	return best


## The building was occupied: 1-2 infected boil out at the door, and whoever breached
## takes a bite that can drop them. Spawns keep views/_anim index-aligned with the sim.
func _loot_ambush(c: Vector2, unit: int) -> void:
	var n: int = 1 + (_loot_rng.randi() % 2)
	for _z in n:
		var p: Vector2 = c + Vector2(_loot_rng.randf_range(-6.0, 6.0), _loot_rng.randf_range(-6.0, 6.0))
		sim.spawn(p, &"zed", WorldSim.INFECTED)
		var v: Node3D = _make_unit_view(WorldSim.INFECTED, &"zed", _rng)
		if v != null:
			v.position = Vector3(p.x, 0.0, p.y)
			vp.add_child(v)
		views.append(v)
		_anim.append(Animator.new(v, _rng) if v != null else null)
	if unit >= 0 and sim.injure(unit, _loot_rng.randf_range(18.0, 58.0)):
		_loot_say(_loot_toast + "   [!] MAN DOWN")
	else:
		_loot_say(_loot_toast + "   [!] CONTACT")


func _loot_say(s: String) -> void:
	_loot_toast = s
	_loot_toast_t = LOOT_TOAST_TIME


func _toggle_feed() -> void:
	_channel_change("orbit" if feed == "deploy" else "deploy")


func _cycle_palette() -> void:
	mode = (mode + 1) % 3
	if _pal_btn != null:
		_pal_btn.text = MODE_NAMES[mode]                    # the button reads the current palette
	if is_instance_valid(_menu_thermal_btn):
		_menu_thermal_btn.text = "THERMAL: " + MODE_NAMES[mode]


## PSV: toggle your team's passive stance. While passive, any RIVAL team that's also
## running passive is held as an ally -- you don't fire on each other, and both keep
## engaging the infected + Sanitation. Drop it and you're free-fire on every team again.
func _toggle_passive() -> void:
	_passive = not _passive
	_recompute_alliances()
	if _psv_btn != null:
		_psv_btn.modulate = Color(1, 1, 1, 1.0) if _passive else Color(1, 1, 1, 0.7)
	Audio.comms("ack_affirmative" if _passive else "order_ready", 800)
	_loot_say("PASSIVE STANCE  --  %s" % ("ON" if _passive else "OFF"))


## The two thumb-reach control clusters. LOWER-LEFT is unit selection: REGROUP, a big
## tap-to-cycle unit-TYPE box, and ALL. LOWER-RIGHT is command + camera + the AC-130's
## ARM/FIRE pair. Styled like the gunship HUD; works with mouse too.
func _build_touch_bar(host: CanvasLayer) -> void:
	# --- lower-left: STATUS + unit selection ---
	var lbar: HBoxContainer = HBoxContainer.new()
	lbar.add_theme_constant_override("separation", 6)
	var bstat: Button = _hud_button("STATUS", 72)
	bstat.pressed.connect(_toggle_status)
	lbar.add_child(bstat)
	var breg: Button = _hud_button("REGROUP", 78)
	breg.pressed.connect(_regroup)
	lbar.add_child(breg)
	_cyc_btn = _hud_button("TYPE", 118)                 # the big tap-to-cycle unit-type box
	_cyc_btn.add_theme_font_size_override("font_size", 26)   # bigger -- the most-tapped button, 3-letter labels
	_cyc_btn.pressed.connect(_cycle_unit_type)
	lbar.add_child(_cyc_btn)
	_all_btn = _hud_button("ALL", 62)
	_all_btn.pressed.connect(_select_all_squad)
	lbar.add_child(_all_btn)
	var bctrl: Button = _hud_button("CTRL")           # controls card lives on the LEFT, by the card it opens
	bctrl.pressed.connect(_toggle_controls)
	lbar.add_child(bctrl)
	host.add_child(lbar)
	_bar_l = lbar

	# --- lower-right: command + camera + AC-130 ---
	var rbar: HBoxContainer = HBoxContainer.new()
	rbar.add_theme_constant_override("separation", 6)
	_scan_btn = _hud_button("SCAN", 74)          # shows the cooldown countdown, lit when ready
	_scan_btn.pressed.connect(_request_scan)
	rbar.add_child(_scan_btn)
	# PSV: one passive-stance toggle (replaces WPN + PRLY). Two passive teams hold fire on
	# each other and both keep firing on the infected + Sanitation.
	_psv_btn = _hud_button("PSV")
	_psv_btn.pressed.connect(_toggle_passive)
	rbar.add_child(_psv_btn)
	var bisr: Button = _hud_button("ISR")
	bisr.pressed.connect(_toggle_feed)
	rbar.add_child(bisr)
	# PAL: labelled with the CURRENT palette; press cycles WHT HOT -> BLK HOT -> IRONBOW.
	_pal_btn = _hud_button(MODE_NAMES[mode], 92)
	_pal_btn.pressed.connect(_cycle_palette)
	rbar.add_child(_pal_btn)
	# the AC-130 slot: a LOCKED cover until the kill threshold, then it vanishes to reveal
	# the ARM-over-FIRE stack (mutually exclusive -- see _update_ac_buttons).
	var ac_slot: Control = Control.new()
	ac_slot.custom_minimum_size = Vector2(76, 45)
	var ac: VBoxContainer = VBoxContainer.new()
	ac.add_theme_constant_override("separation", 3)
	ac.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_arm_btn = _ac_button("ARM")
	_arm_btn.pressed.connect(_request_strike)
	ac.add_child(_arm_btn)
	_fire_btn = _ac_button("FIRE")
	_fire_btn.pressed.connect(_fire_reticle)
	ac.add_child(_fire_btn)
	ac_slot.add_child(ac)
	_locked_btn = _ac_button("LOCKED")
	_locked_btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_locked_btn.disabled = true         # a cover, not a control -- clicks pass to nothing
	ac_slot.add_child(_locked_btn)
	rbar.add_child(ac_slot)
	host.add_child(rbar)
	_bar_r = rbar

	# squad-status panel (left side, toggled by STATUS) -- hidden until asked for
	_status_panel = Label.new()
	_status_panel.add_theme_font_override("font", load(HUD_FONT))
	_status_panel.add_theme_font_size_override("font_size", 14)
	_status_panel.add_theme_color_override("font_color", HUD_COL)
	var sbx: StyleBoxFlat = StyleBoxFlat.new()
	sbx.bg_color = Color(0.0, 0.03, 0.0, 0.74)
	sbx.border_color = Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.6)
	sbx.set_border_width_all(1)
	sbx.set_corner_radius_all(2)
	sbx.content_margin_left = 12
	sbx.content_margin_right = 12
	sbx.content_margin_top = 8
	sbx.content_margin_bottom = 8
	_status_panel.add_theme_stylebox_override("normal", sbx)
	_status_panel.visible = false
	host.add_child(_status_panel)

	_bar_l.visible = not _menu_active
	_bar_r.visible = not _menu_active
	_update_ac_buttons()
	_update_type_all_buttons()          # ALL selected by default -> TYPE reads ALL, ALL button dark
	_place_touch_bar()


func _hud_button(text: String, w: float = 58.0) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, 46)
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


## A red AC-130 button (ARM / FIRE). Narrow + short so the pair stacks in a corner box.
func _ac_button(text: String) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(74, 21)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", load(HUD_FONT))
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", HUD_RED)
	b.add_theme_color_override("font_hover_color", HUD_RED)
	b.add_theme_color_override("font_pressed_color", Color(0.1, 0.02, 0.02))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.03, 0.03, 0.6)
	sb.border_color = Color(HUD_RED.r, HUD_RED.g, HUD_RED.b, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	b.add_theme_stylebox_override("normal", sb)
	var sbp: StyleBoxFlat = sb.duplicate()
	sbp.bg_color = Color(HUD_RED.r, HUD_RED.g, HUD_RED.b, 0.5)
	b.add_theme_stylebox_override("hover", sbp)
	b.add_theme_stylebox_override("pressed", sbp)
	b.add_theme_stylebox_override("disabled", sb)
	return b


## ARM lights only when the fire mission is unlocked (enough kills) and NOT yet armed;
## FIRE lights only once armed. They cycle -- lighting one darkens + disables the other.
func _update_ac_buttons() -> void:
	if _arm_btn == null or _fire_btn == null or _locked_btn == null:
		return
	var unlocked: bool = _zombie_kills >= AC_UNLOCK
	# LOCKED cover hides the pair until the threshold is met, then it vanishes.
	_locked_btn.visible = not unlocked
	_arm_btn.visible = unlocked
	_fire_btn.visible = unlocked
	var arm_on: bool = unlocked and not _strike_arming
	var fire_on: bool = unlocked and _strike_arming
	_arm_btn.disabled = not arm_on
	_fire_btn.disabled = not fire_on
	_arm_btn.modulate = Color(1, 1, 1, 1.0) if arm_on else Color(1, 1, 1, 0.32)
	_fire_btn.modulate = Color(1, 1, 1, 1.0) if fire_on else Color(1, 1, 1, 0.32)


## The SCAN button carries its own cooldown: "SCAN Ns" while the reveal is live, a plain
## countdown (dark, disabled) while recharging, then "SCAN" lit again when it's ready.
func _update_scan_button() -> void:
	if _scan_btn == null:
		return
	if _scan_t < SCAN_REVEAL:
		_scan_btn.text = "SCAN %ds" % int(ceil(SCAN_REVEAL - _scan_t))
		_scan_btn.modulate = Color(1, 1, 1, 1.0)
		_scan_btn.disabled = false
	elif _scan_t < SCAN_COOLDOWN:
		_scan_btn.text = "%ds" % int(ceil(SCAN_COOLDOWN - _scan_t))
		_scan_btn.modulate = Color(1, 1, 1, 0.4)
		_scan_btn.disabled = true
	else:
		_scan_btn.text = "SCAN"
		_scan_btn.modulate = Color(1, 1, 1, 1.0)
		_scan_btn.disabled = false


## STATUS button: toggle the squad readout (each trooper's role + HP).
func _toggle_status() -> void:
	if _status_panel == null:
		return
	_status_panel.visible = not _status_panel.visible
	_update_status_panel()


## CONTROLS button: toggle the keyboard/controls reference card.
func _toggle_controls() -> void:
	show_help = not show_help
	if help != null:
		help.visible = show_help and not _menu_active


const _ROLE_ABBR: Dictionary = {&"cdr": "CMD", &"cbt": "CBT", &"med": "MED", &"snp": "SNP", &"rec": "REC", &"eod": "EOD"}

func _update_status_panel() -> void:
	if _status_panel == null or not _status_panel.visible or sim == null:
		return
	var rows: PackedStringArray = ["SQUAD STATUS", "ROLE  HP  ARMOR  BUFFS", ""]
	for i in sim.count():
		if sim.alive[i] and sim.team[i] == WorldSim.SQUAD and sim.element[i] == 0:
			var nm: String = _ROLE_ABBR.get(sim.kind[i], String(sim.kind[i]).to_upper())
			var maxhp: float = WorldSim.STATS[sim.kind[i]][1]
			var hp_pct: int = int(round(100.0 * sim.hp[i] / maxf(1.0, maxhp)))
			var armor_pct: int = int(round(sim.armor[i] * 100.0))
			var buffs: String = ""
			if sim.buff_t[i] > 0.0:
				if sim.buff_dmg[i] > 1.0:
					buffs += "DMGx%.1f " % sim.buff_dmg[i]
				if sim.buff_res[i] > 0.0:
					buffs += "RES%d%% " % int(round(sim.buff_res[i] * 100.0))
				buffs += "(%ds)" % int(ceil(sim.buff_t[i]))
			rows.append("%-4s %3d%%  %3d%%   %s" % [nm, hp_pct, armor_pct, buffs if buffs != "" else "--"])
	if rows.size() == 3:
		rows.append("-- NO SURVIVORS --")
	rows.append("")
	rows.append("HDD %d   HOSTILES DOWN %d" % [_hdd, _kills])
	_status_panel.text = "\n".join(rows)


## REGROUP: select the whole squad and pull it in to its own centroid (form up).
func _regroup() -> void:
	_select_element(0)
	var ids: Array = sim.selected_ids()
	if ids.is_empty():
		return
	var sum: Vector2 = Vector2.ZERO
	for i in ids:
		sum += sim.pos[i]
	var g: Vector2 = sum / float(ids.size())
	sim.order_move(ids, g)
	Audio.comms_order()
	_move_marker = {"pos": g, "ids": ids.duplicate()}


## ALL: select every living unit in your squad; the TYPE box reads ALL and this button darkens.
func _select_all_squad() -> void:
	_select_element(0)
	_type_idx = -1
	_update_type_all_buttons()
	if not sim.selected_ids().is_empty():
		Audio.comms("ack_affirmative", 2500)


func _place_touch_bar() -> void:
	# canvas space, not raw window pixels -- the CanvasLayer lives in the stretched
	# logical viewport (same space the drawn HUD uses).
	var win: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var hmax: float = 0.0
	if _bar_l != null:
		_bar_l.reset_size()
		var szl: Vector2 = _bar_l.get_combined_minimum_size()
		_bar_l.size = szl
		_bar_l.position = Vector2(16.0, win.y - szl.y - 16.0)                  # lower-LEFT
		hmax = maxf(hmax, szl.y)
	if _bar_r != null:
		_bar_r.reset_size()
		var szr: Vector2 = _bar_r.get_combined_minimum_size()
		_bar_r.size = szr
		_bar_r.position = Vector2(win.x - szr.x - 16.0, win.y - szr.y - 16.0)  # lower-RIGHT
		hmax = maxf(hmax, szr.y)
	if _status_panel != null:
		_status_panel.reset_size()
		_status_panel.position = Vector2(16.0, win.y * 0.30)                   # left side, mid
	# the keyboard controls card is desktop-only; drop it on a portrait phone
	if help != null:
		help.visible = show_help and win.x >= win.y and not _menu_active


## The startup menu: TUTORIAL (default-highlighted) / SOLO / 2-4 TEAMS, over the slowly
## rotating feed with music1 playing. Picking one deploys that many teams from spread edges.
## The build stamp -- v0.19 (the prototype) + one v0.01 per push -- small in the HUD font,
## top-right, on its own top layer so it shows over the menu AND gameplay at all times.
func _build_version_stamp() -> void:
	var vh: int = 19 + BUILD_PUSHES              # version in hundredths, from the v0.19 base
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 40                             # above the menu (20) and the HUD
	var lbl: Label = Label.new()
	lbl.text = "v%d.%02d" % [vh / 100, vh % 100]
	lbl.add_theme_font_override("font", load(HUD_FONT))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", HUD_COL)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	lbl.offset_left = -96.0
	lbl.offset_right = -10.0
	lbl.offset_top = 3.0
	lbl.offset_bottom = 19.0
	layer.add_child(lbl)
	add_child(layer)


func _build_menu() -> void:
	_menu_layer = CanvasLayer.new()
	_menu_layer.layer = 20
	var dim: ColorRect = ColorRect.new()
	dim.color = Color(0.0, 0.015, 0.0, 0.52)   # a stronger dark wash so the green menu text stands out (sweep still reads behind)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_layer.add_child(dim)
	# a black wash that rises to reset the sim (last entity standing) then clears -- sits over
	# the feed but UNDER the menu box, so the options stay visible through the transition.
	_menu_fade = ColorRect.new()
	_menu_fade.color = Color(0.0, 0.0, 0.0, 0.0)
	_menu_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_layer.add_child(_menu_fade)
	# a CenterContainer keeps the menu box centred no matter its height -- so the taller
	# loadout screen (and its DEPLOY button) never grows off the bottom of the screen.
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_layer.add_child(center)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(box)
	_menu_title = _menu_label("SPECTRE PROTOCOL", 40, HUD_COL)
	box.add_child(_menu_title)
	box.add_child(_menu_label("SELECT DEPLOYMENT", 15, HUD_DIM))
	var gap: Control = Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	box.add_child(gap)
	# team selection -- picking a count (not Tutorial) opens the loadout screen
	_menu_teams = VBoxContainer.new()
	(_menu_teams as VBoxContainer).add_theme_constant_override("separation", 9)
	(_menu_teams as VBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(_menu_teams)
	var first: Button = null
	for o in [["TUTORIAL", -1], ["SOLO", 1], ["2 TEAMS", 2], ["3 TEAMS", 3], ["4 TEAMS", 4]]:
		var b: Button = _menu_button(String(o[0]))
		var cnt: int = int(o[1])
		if cnt < 0:
			b.pressed.connect(_start_game.bind(cnt))   # tutorial: the default squad, straight in
		else:
			b.pressed.connect(_open_loadout.bind(cnt))
		_menu_teams.add_child(b)
		if first == null:
			first = b
	# loadout panel -- hidden until a team count is chosen
	_menu_loadout = _build_loadout_panel()
	box.add_child(_menu_loadout)
	_menu_loadout.visible = false
	# thermal-flip button, top-right corner -- previews the palette on the backdrop
	_menu_thermal_btn = _menu_button("THERMAL: " + MODE_NAMES[mode])
	_menu_thermal_btn.custom_minimum_size = Vector2(162, 28)
	_menu_thermal_btn.add_theme_font_size_override("font_size", 12)
	_menu_thermal_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_menu_thermal_btn.offset_left = -178.0
	_menu_thermal_btn.offset_right = -16.0
	_menu_thermal_btn.offset_top = 16.0
	_menu_thermal_btn.offset_bottom = 44.0
	_menu_thermal_btn.pressed.connect(_menu_flip_thermal)
	_menu_layer.add_child(_menu_thermal_btn)
	add_child(_menu_layer)
	if first != null:
		first.grab_focus()   # Tutorial default-highlighted


## Menu thermal-flip: cycle the palette so you can preview WHT/BLK HOT + IRONBOW on the
## backdrop; the choice carries into the run.
func _menu_flip_thermal() -> void:
	mode = (mode + 1) % 3
	if _menu_thermal_btn != null:
		_menu_thermal_btn.text = "THERMAL: " + MODE_NAMES[mode]


## The squad-loadout panel: one row per unit type with -/+ steppers, then DEPLOY / BACK.
func _build_loadout_panel() -> Control:
	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(_menu_label("SQUAD LOADOUT", 18, HUD_COL))
	var g0: Control = Control.new()
	g0.custom_minimum_size = Vector2(0, 6)
	v.add_child(g0)
	# the commander is fixed at 1 -- shown but not adjustable
	var cdr_row: HBoxContainer = HBoxContainer.new()
	cdr_row.add_theme_constant_override("separation", 8)
	var cdr_nm: Label = _menu_label("COMMANDER", 15, HUD_DIM)
	cdr_nm.custom_minimum_size = Vector2(150, 0)
	cdr_nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	cdr_row.add_child(cdr_nm)
	cdr_row.add_child(_menu_label("1  (FIXED)", 15, HUD_DIM))
	v.add_child(cdr_row)
	_loadout_lbls = {}
	var names: Dictionary = {&"cbt": "COMBAT", &"med": "MEDIC", &"snp": "SNIPER", &"rec": "RECON", &"eod": "EOD"}
	for k in CHOOSABLE:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var nm: Label = _menu_label(names[k], 15, HUD_COL)
		nm.custom_minimum_size = Vector2(150, 0)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_child(nm)
		var minus: Button = _menu_button("-")
		minus.custom_minimum_size = Vector2(42, 34)
		minus.pressed.connect(_adjust_loadout.bind(k, -1))
		row.add_child(minus)
		var cl: Label = _menu_label(str(_loadout[k]), 17, HUD_COL)
		cl.custom_minimum_size = Vector2(34, 0)
		row.add_child(cl)
		_loadout_lbls[k] = cl
		var plus: Button = _menu_button("+")
		plus.custom_minimum_size = Vector2(42, 34)
		plus.pressed.connect(_adjust_loadout.bind(k, 1))
		row.add_child(plus)
		v.add_child(row)
	_loadout_total_lbl = _menu_label("", 16, HUD_COL)   # the running "TROOPS n/26" tally
	v.add_child(_loadout_total_lbl)
	var g1: Control = Control.new()
	g1.custom_minimum_size = Vector2(0, 6)
	v.add_child(g1)
	_deploy_btn = _menu_button("DEPLOY")
	_deploy_btn.pressed.connect(_confirm_loadout)
	v.add_child(_deploy_btn)
	var back: Button = _menu_button("BACK")
	back.pressed.connect(_close_loadout)
	v.add_child(back)
	return v


func _open_loadout(count: int) -> void:
	_pending_count = count
	if _menu_teams != null:
		_menu_teams.visible = false
	if _menu_loadout != null:
		_menu_loadout.visible = true
	_refresh_loadout_labels()


func _close_loadout() -> void:
	if _menu_loadout != null:
		_menu_loadout.visible = false
	if _menu_teams != null:
		_menu_teams.visible = true


func _adjust_loadout(k: StringName, d: int) -> void:
	_loadout[k] = clampi(int(_loadout[k]) + d, 0, LOADOUT_MAX)
	_refresh_loadout_labels()


func _refresh_loadout_labels() -> void:
	var total: int = FIXED_CDR                      # the commander is always in the count
	for k in _loadout_lbls:
		(_loadout_lbls[k] as Label).text = str(_loadout[k])
		total += int(_loadout[k])
	if _loadout_total_lbl != null:
		var ok: bool = total == REQUIRED_TROOPS
		_loadout_total_lbl.text = "TROOPS  %d / %d" % [total, REQUIRED_TROOPS]
		_loadout_total_lbl.add_theme_color_override("font_color", HUD_COL if ok else HUD_RED)
	if _deploy_btn != null:
		var ready: bool = total == REQUIRED_TROOPS   # must field exactly the required squad
		_deploy_btn.disabled = not ready
		_deploy_btn.modulate = Color(1, 1, 1, 1.0 if ready else 0.35)


func _confirm_loadout() -> void:
	var total: int = FIXED_CDR
	for k in _loadout:
		total += int(_loadout[k])
	if total != REQUIRED_TROOPS:
		return                       # must field exactly the required squad size (26)
	_start_game(_pending_count)


## Expand the player's loadout into a spawn roster (element 0): the fixed commander first,
## then the choosable roles. Always exactly REQUIRED_TROOPS.
func _loadout_roster() -> Array:
	var r: Array = []
	for _c in FIXED_CDR:
		r.append(&"cdr")
	for k in CHOOSABLE:
		for _n in int(_loadout.get(k, 0)):
			r.append(k)
	return r


## Every rival team fields the same 26 -- one commander + a standard 25-strong spread --
## so all deployed teams are real forces, not a token six.
func _rival_roster() -> Array:
	var r: Array = [&"cdr"]
	for spec in [[&"cbt", 15], [&"med", 4], [&"snp", 3], [&"rec", 2], [&"eod", 1]]:
		for _n in int(spec[1]):
			r.append(spec[0])
	return r


func _menu_label(text: String, size: int, col: Color) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_override("font", load(HUD_FONT))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _menu_button(text: String) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(250, 42)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", load(HUD_FONT))
	b.add_theme_font_size_override("font_size", 19)
	b.add_theme_color_override("font_color", HUD_COL)
	b.add_theme_color_override("font_hover_color", Color(0.08, 0.12, 0.09))
	b.add_theme_color_override("font_focus_color", Color(0.08, 0.12, 0.09))
	b.add_theme_color_override("font_pressed_color", Color(0.08, 0.12, 0.09))
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.09, 0.06, 0.6)
	sb.border_color = Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	b.add_theme_stylebox_override("normal", sb)
	var sbf: StyleBoxFlat = sb.duplicate()
	sbf.bg_color = Color(HUD_COL.r, HUD_COL.g, HUD_COL.b, 0.6)
	b.add_theme_stylebox_override("hover", sbf)
	b.add_theme_stylebox_override("focus", sbf)
	b.add_theme_stylebox_override("pressed", sbf)
	b.pressed.connect(_menu_click)   # every menu selection blips the scanner
	return b


## The scanner blip on any main-menu selection.
func _menu_click() -> void:
	if _sfx_scan != null:
		Audio.ui(_sfx_scan, -1.0)


## Start a run with `count` teams (or the tutorial, count < 0). Respawns at the edges.
func _start_game(count: int) -> void:
	_tutorial = count < 0
	_menu_sim = false
	_team_count = clampi(1 if _tutorial else count, 1, ELEMENTS)
	active_element = 0
	_randomize_team_colors()       # fresh distinct team colours each run
	_kills = 0
	_zombie_kills = 0
	_score = 0
	_san_kills = 0
	_collateral = 0
	_hdd = 0
	_hdd_pickups.clear()
	_loot_toast = ""
	_loot_toast_t = 0.0
	_nuke_fired = false
	_sani_music_on = false
	Audio.stop_sani(0.3)
	if _menu_layer != null:
		_menu_layer.queue_free()
		_menu_layer = null
	_menu_active = false
	Audio.play_music(MUSIC_DEPLOY, 0.0)   # hard cut to the deploy track the instant you drop
	_layout_controls()                 # (bars auto-show in _process once _menu_active is false)
	await _rebuild_world()          # respawn with the chosen team count at the edges
	feed = "deploy"
	_apply_feed()
	_intro_t = 0.0                  # hold close on the disembark, then auto-pull to the wide view
	if _tutorial and help != null:
		show_help = true
		help.visible = true


func _rebuild_world() -> void:
	_looted.clear()          # building indices are about to change; drop stale loot marks
	_end_loot()
	_clear_panic()
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
