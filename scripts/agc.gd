class_name AGC
extends RefCounted

## Automatic gain control. Real uncooled sensors renormalise the whole frame to
## whatever is in it. Put a fire in shot and everything else goes dim. Your own
## explosions blind your own optic. That is not a bug to fix, it is the mechanic.
##
## get_image() forces a GPU -> CPU sync, so we only do it every N frames on a
## downscaled copy. At 80x45 that is 3,600 samples, plenty for a percentile.

const SAMPLE_W: int = 80
const SAMPLE_H: int = 45
const EVERY_N_FRAMES: int = 3

var lo := 0.60
var hi := 1.10
var median := 0.85
var speed := 0.10        # per-update damping. 0 = frozen, 1 = instant.
var frozen := false

var _counter := 0
var _vals := PackedFloat32Array()


## Call once per frame, after the SubViewport has drawn.
func update(vp: SubViewport) -> void:
	_counter += 1
	if frozen or (_counter % EVERY_N_FRAMES) != 0:
		return
	if DisplayServer.get_name() == "headless":
		return              # dummy renderer has no texture to read back
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return
	img.resize(SAMPLE_W, SAMPLE_H, Image.INTERPOLATE_NEAREST)

	_vals.resize(SAMPLE_W * SAMPLE_H)
	var i: int = 0
	for y in SAMPLE_H:
		for x in SAMPLE_W:
			_vals[i] = img.get_pixel(x, y).r
			i += 1
	_vals.sort()

	var n: int = _vals.size()
	var t_lo: float = _vals[int(float(n) * 0.02)]
	var t_hi: float = _vals[int(float(n) * 0.985)]
	var t_med: float = _vals[n / 2]
	if t_hi <= t_lo:
		t_hi = t_lo + 1e-3

	lo = lerpf(lo, t_lo, speed)
	hi = lerpf(hi, t_hi, speed)
	median = lerpf(median, t_med, speed)


## Called at the moment the new feed goes live behind the snow. Throwing the
## window wide is what makes the picture wash out and then visibly settle.
func knock_out_of_lock() -> void:
	lo = 0.20
	hi = 3.00
	median = 0.60


func push(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("agc_lo", lo)
	mat.set_shader_parameter("agc_hi", hi)
	mat.set_shader_parameter("scene_median", median)
