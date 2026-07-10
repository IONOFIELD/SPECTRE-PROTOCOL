extends SceneTree

## godot --headless --path . --script res://tools/bake_thermal_maps.gd
##
## Turns any photographic texture into a THERMAL DETAIL MAP.
##
## A texture's low-frequency content is albedo, and albedo does not exist in the
## 8-14 micron band. Black paint and white paint both sit near 0.92 emissivity.
## Feed a JPG straight into a thermal shader and you get a picture that is
## detailed and wrong: the dark bricks read cold, and real dark bricks do not.
##
## What survives into infrared is the HIGH-FREQUENCY content: mortar lines,
## panel gaps, rivets, seams, window frames. Those are geometric discontinuities,
## and geometry is thermally real. So: high-pass the image, keep the residual,
## throw the albedo away. Measured on real textures, the residual is 18% to 75%
## of the total variance depending on the surface.
##
## Output: greyscale PNG, 0.5 = flat surface, <0.5 = recessed, >0.5 = proud.
##
## FEED THIS THE DISPLACEMENT / HEIGHT MAP, NOT THE COLOR MAP.
## Measured on the ambientCG set, correlation between a high-passed Color map and
## the true height field:
##     road      +0.999      hvac  +0.923      window  +0.722    wall(concrete) +0.678
##     sidewalk  +0.376      park  +0.311      grass   +0.061    tank           -0.024
##     wall(brick) -0.416    parapet -0.508
## Where it goes negative the Color map is reporting PAINT. Mortar is lighter than
## brick, so a high-pass calls it proud; geometrically it is recessed. The shader
## then treats a ridge as a cavity and the joint reads cold. Height has no albedo
## in it, so this failure cannot occur. Colour input is accepted and warned about.

const SRC: String = "res://textures/source/"
const DST: String = "res://textures/thermal/"


func _box_blur(img: Image, r: int) -> Image:
	var w: int = img.get_width()
	var h: int = img.get_height()
	var tmp: Image = Image.create(w, h, false, Image.FORMAT_RF)
	for y in h:
		for x in w:
			var s: float = 0.0
			for k in range(-r, r + 1):
				s += img.get_pixel(posmod(x + k, w), y).r     # textures tile: wrap
			tmp.set_pixel(x, y, Color(s / float(2 * r + 1), 0, 0))
	var out: Image = Image.create(w, h, false, Image.FORMAT_RF)
	for y in h:
		for x in w:
			var s: float = 0.0
			for k in range(-r, r + 1):
				s += tmp.get_pixel(x, posmod(y + k, h)).r
			out.set_pixel(x, y, Color(s / float(2 * r + 1), 0, 0))
	return out


func _initialize() -> void:
	var dir: DirAccess = DirAccess.open(SRC)
	if dir == null:
		print("no source directory: ", SRC)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DST))

	for f in dir.get_files():
		if not f.ends_with(".png"):
			continue
		var img: Image = Image.load_from_file(SRC + f)
		var w: int = img.get_width()
		var h: int = img.get_height()

		# Chroma sniff. A height map is grey. Anything else is probably albedo.
		var chroma: float = 0.0
		for i in 64:
			var c: Color = img.get_pixel(randi() % w, randi() % h)
			chroma += absf(c.r - c.g) + absf(c.g - c.b)
		if chroma / 64.0 > 0.02:
			push_warning("%s looks like a COLOR map. Recessed joints may invert. Use Displacement." % f)

		var lum: Image = Image.create(w, h, false, Image.FORMAT_RF)
		for y in h:
			for x in w:
				var c: Color = img.get_pixel(x, y)
				lum.set_pixel(x, y, Color(c.r * 0.299 + c.g * 0.587 + c.b * 0.114, 0, 0))

		var r: int = maxi(2, w / 16)
		var lo: Image = _box_blur(lum, r)

		# residual, then normalise by its own spread so every material lands in
		# the same range whatever its contrast
		var vals: PackedFloat32Array = PackedFloat32Array()
		vals.resize(w * h)
		var mean: float = 0.0
		for y in h:
			for x in w:
				var v: float = lum.get_pixel(x, y).r - lo.get_pixel(x, y).r
				vals[y * w + x] = v
				mean += v
		mean /= float(w * h)
		var sd: float = 0.0
		for v in vals:
			sd += (v - mean) * (v - mean)
		sd = sqrt(sd / float(w * h))

		# Normalise by the 99th percentile of |residual|, NOT by sd.
		# sd tracks the shape of the height distribution rather than its depth.
		# Corrugated steel is a square wave: p99/sd ~ 1.2. A cast concrete wall is
		# gaussian: p99/sd ~ 2.7. Divide both by 3*sd and the deeper geometry gets
		# 2.5x less drive than the shallower one. A sparse surface (window frame,
		# p99/sd ~ 5.2) clips instead. The percentile is invariant to all of it.
		var absr: PackedFloat32Array = PackedFloat32Array()
		absr.resize(w * h)
		for i in vals.size():
			absr[i] = absf(vals[i] - mean)
		absr.sort()
		var p99: float = absr[mini(absr.size() - 1, int(absr.size() * 0.99))]
		if p99 < 1e-5:
			p99 = 1e-5

		var out: Image = Image.create(w, h, false, Image.FORMAT_RGB8)
		for y in h:
			for x in w:
				var z: float = clampf((vals[y * w + x] - mean) / p99 * 0.45 + 0.5, 0.0, 1.0)
				out.set_pixel(x, y, Color(z, z, z))
		out.save_png(DST + f)
		print("baked %-14s %dx%d   sd %.4f   p99 %.4f   p99/sd %.2f" % [f, w, h, sd, p99, p99 / maxf(sd, 1e-5)])
	quit(0)
