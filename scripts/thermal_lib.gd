class_name ThermalLib
extends RefCounted

## The temperature table. Nothing here is a colour.
##
##   t      surface temperature, celsius
##   sky    degrees shed to a cold night sky by an up-facing face
##   e      emissivity. 0.30 gun metal reads COLD; 0.98 skin reads hot.
##   solar  residual afternoon loading on a sun-facing face
##   d      detail kind: 0 none, 1 concrete+windows, 2 roof gravel,
##          3 asphalt, 4 vehicle panel, 5 glass streaks
##   dt     detail temperature swing, peak to peak
##   de     detail emissivity swing
##
## Two entries earn their keep on their own:
##   weapon  e = 0.30. Same temperature as the air, and it looks it.
##   zed     17.5 C, near ambient. Zombies are hard to pick out. By design.

const SHADER_PATH: String = "res://shaders/thermal.gdshader"
const RADIANCE_SCALE: float = 1.0     # requires SubViewport.use_hdr_2d = true
const SUN_DIR: Vector3 = Vector3(0.855, 0.300, -0.425)   # where the sun set

const MAT: Dictionary = {
	"water":     {"t": 14.0, "sky": 15.0, "e": 0.96, "solar": 0.5, "d": 5, "dt": 0.5, "de": 0.0},
	"ground":    {"t": 19.0, "sky": 3.0, "e": 0.94, "solar": 3.2, "d": 2, "dt": 2.0, "de": 0.03},
	"park":      {"t": 12.5, "sky": 4.0, "e": 0.97, "solar": 1.0, "d": 2, "dt": 2.6, "de": 0.02, "ms": Vector2(3.0, 3.0)},
	"road":      {"t": 21.0, "sky": 2.5, "e": 0.93, "solar": 4.0, "d": 3, "dt": 2.0, "de": 0.05, "ms": Vector2(4.0, 2.586)},
	"sidewalk":  {"t": 17.5, "sky": 3.5, "e": 0.94, "solar": 3.0, "d": 6, "dt": 1.3, "de": 0.02, "ms": Vector2(1.8, 1.8)},
	"grass":     {"t": 12.0, "sky": 4.5, "e": 0.97, "solar": 0.8, "d": 7, "dt": 2.4, "de": 0.02, "ms": Vector2(1.5, 1.5)},
	"lot":       {"t": 20.0, "sky": 2.8, "e": 0.93, "solar": 3.6, "d": 8, "dt": 1.8, "de": 0.04},
	"wall":      {"t": 16.5, "sky": 8.5, "e": 0.92, "solar": 5.5, "d": 1, "dt": 2.0, "de": 0.04, "ms": Vector2(2.4, 1.2)},
	"brick":     {"t": 16.5, "sky": 8.5, "e": 0.94, "solar": 5.5, "d": 1, "dt": 2.0, "de": 0.04, "ms": Vector2(2.0, 2.0)},
	"window":    {"t": 12.0, "sky": 2.0, "e": 0.75, "solar": 1.5, "d": 5, "dt": 0.8, "de": 0.0, "ms": Vector2(1.2, 1.2)},
	"parapet":   {"t": 11.0, "sky": 5.0, "e": 0.91, "solar": 3.0, "d": 2, "dt": 1.0, "de": 0.02, "ms": Vector2(1.6, 1.6)},
	"hvac":      {"t": 34.0, "sky": 0.5, "e": 0.93, "solar": 0.0, "d": 4, "dt": 1.5, "de": 0.02, "ms": Vector2(0.6, 0.6)},
	"tank":      {"t": 13.0, "sky": 4.0, "e": 0.92, "solar": 2.5, "d": 4, "dt": 0.8, "de": 0.02, "ms": Vector2(1.2, 1.2)},

	"body_cold": {"t": 11.0, "sky": 3.0, "e": 0.88, "solar": 3.5, "d": 4, "dt": 0.9, "de": 0.05},
	"glass_veh": {"t": 12.0, "sky": 2.5, "e": 0.75, "solar": 1.0, "d": 5, "dt": 0.6, "de": 0.0},
	"hood_hot":  {"t": 52.0, "sky": 0.5, "e": 0.90, "solar": 0.0, "d": 4, "dt": 6.0, "de": 0.03},
	"hood_warm": {"t": 27.0, "sky": 1.0, "e": 0.90, "solar": 1.0, "d": 4, "dt": 2.5, "de": 0.03},
	"tyre":      {"t": 24.0, "sky": 0.5, "e": 0.95, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"exhaust":   {"t": 78.0, "sky": 0.0, "e": 0.95, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},

	"skin":      {"t": 33.5, "sky": 0.4, "e": 0.98, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"cloth":     {"t": 27.0, "sky": 0.8, "e": 0.95, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"cloth_hvy": {"t": 24.0, "sky": 0.8, "e": 0.95, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"helmet":    {"t": 21.0, "sky": 1.6, "e": 0.94, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"weapon":    {"t": 15.0, "sky": 1.0, "e": 0.30, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"suit_elite":{"t": 21.5, "sky": 1.0, "e": 0.93, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"zed":       {"t": 17.5, "sky": 1.0, "e": 0.96, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
	"fire":      {"t": 340.0, "sky": 0.0, "e": 1.00, "solar": 0.0, "d": 0, "dt": 0.0, "de": 0.0},
}

static var _shader: Shader
static var _cache: Dictionary = {}
static var snap_default: bool = true   # the J key flips this, then clears the cache
static var detail_on: bool = true      # the K key flips this
static var maps_on: bool = true        # photographic structure maps, if present
const MAP_DIR: String = "res://textures/thermal/"


static func radiance(temp_c: float) -> float:
	var k: float = (temp_c + 273.15) / 300.0
	return k * k * k * k


static func get_material(name: String, snap_res: Vector2i, snap: int = -1) -> ShaderMaterial:
	var snap_on: bool = snap_default if snap < 0 else bool(snap)
	var key: String = "%s|%d|%d|%d|%d|%d" % [name, snap_res.x, snap_res.y, int(snap_on), int(detail_on), int(maps_on)]
	if _cache.has(key):
		return _cache[key]
	if _shader == null:
		_shader = load(SHADER_PATH)
	assert(MAT.has(name), "unknown thermal material: " + name)
	var m: Dictionary = MAT[name]
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("temp_c", m["t"])
	mat.set_shader_parameter("sky_loss", m["sky"])
	mat.set_shader_parameter("emissivity", m["e"])
	mat.set_shader_parameter("solar_gain", m["solar"])
	mat.set_shader_parameter("detail", m["d"] if detail_on else 0)
	mat.set_shader_parameter("detail_temp", m["dt"])
	mat.set_shader_parameter("detail_emis", m["de"])
	mat.set_shader_parameter("sun_dir", SUN_DIR)
	mat.set_shader_parameter("radiance_scale", RADIANCE_SCALE)
	mat.set_shader_parameter("snap_res", Vector2(snap_res))
	mat.set_shader_parameter("snap_enabled", snap_on)
	mat.set_shader_parameter("fpn", (hash(name) % 1000) / 1000.0 * 0.02 - 0.01)

	# A baked structure map, if one exists for this material. Falls back to the
	# procedural detail above when it does not, so the game runs with an empty
	# textures folder. Nothing here is licensed art.
	var map_path: String = MAP_DIR + name + ".png"
	if maps_on and ResourceLoader.exists(map_path):
		var tex: Texture2D = load(map_path)
		mat.set_shader_parameter("thermal_map", tex)
		mat.set_shader_parameter("use_map", true)
		mat.set_shader_parameter("map_scale", m.get("ms", Vector2(2.4, 2.4)))
		mat.set_shader_parameter("map_temp", 1.6)
		mat.set_shader_parameter("map_emis", 0.05)
	else:
		mat.set_shader_parameter("use_map", false)
	_cache[key] = mat
	return mat


## The sky. Radiance of a -14 C night, used as the viewport clear colour.
static func sky_color() -> Color:
	var v: float = radiance(-14.0) * RADIANCE_SCALE
	return Color(v, v, v, 1.0)


static func clear_cache() -> void:
	_cache.clear()
