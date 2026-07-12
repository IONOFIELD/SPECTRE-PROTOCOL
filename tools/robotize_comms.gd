extends SceneTree

## Robotize the radio comms -> a cyborg / HL2-Combine operator voice.
##
## Godot ships no ring-modulator or vocoder bus effect, so the metallic robot
## character is baked into the clips OFFLINE here (deterministic DSP), and the live
## ISR bus (radio bandpass + bitcrush + AGC) then sits on top for the downlink feel.
## Together they read as a synthetic radio operator, not a deep human.
##
## Per-sample chain:
##   ring modulation  -- multiply by a low sine carrier -> inharmonic metallic
##                        sidebands (the classic robot timbre), blended with dry so
##                        the words stay intelligible
##   feedback comb     -- a short tuned delay -> a resonant "robot formant"
##   soft clip         -- cubic saturator -> the harsh, over-driven vocoded edge
##
## Idempotent: pristine originals live in audio/comms/_raw/ (Godot-ignored) and are
## always the source, so re-running with new constants re-processes cleanly. Tune
## the five numbers below and re-run:
##   <godot_console> --headless --path . --script res://tools/robotize_comms.gd

const COMMS := "res://audio/comms/"
const RAW := "res://audio/comms/_raw/"

const CARRIER_HZ := 90.0     # ring-mod carrier: lower = motor buzz, higher = metallic/Dalek
const RING_MIX := 0.70       # 0 = dry, 1 = full ring mod (less intelligible)
const COMB_HZ := 175.0       # comb resonance frequency -- the robotic formant
const COMB_FB := 0.42        # comb feedback (keep < 1 for stability)
const DRIVE := 1.30          # pre-clip gain -> harsher synthetic edge


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RAW))
	_write_gdignore()
	var d := DirAccess.open(COMMS)
	if d == null:
		push_error("[robotize] cannot open " + COMMS)
		quit(1)
		return
	var names: PackedStringArray = []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.to_lower().ends_with(".wav"):
			names.append(n)
		n = d.get_next()
	d.list_dir_end()
	names.sort()
	var ok := 0
	for name in names:
		var raw_path := RAW + name
		if not FileAccess.file_exists(raw_path):
			_copy(COMMS + name, raw_path)        # seed the pristine source on first run
		if _robotize(raw_path, COMMS + name):
			ok += 1
			print("[robotize] ", name)
		else:
			push_warning("[robotize] skipped " + name)
	print("[robotize] done: %d/%d clips" % [ok, names.size()])
	quit(0 if ok == names.size() else 1)


func _write_gdignore() -> void:
	var p := ProjectSettings.globalize_path(RAW + ".gdignore")
	if not FileAccess.file_exists(p):
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string("")   # keep Godot from importing the pristine backups
			f.close()


func _copy(src: String, dst: String) -> void:
	var b := FileAccess.get_file_as_bytes(src)
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f != null:
		f.store_buffer(b)
		f.close()


## Read a 16/24-bit PCM WAV, run the robot chain, write 16-bit PCM (the ISR bus
## bitcrushes it anyway, so bit depth past 16 is wasted on a radio voice).
func _robotize(src: String, dst: String) -> bool:
	var b := FileAccess.get_file_as_bytes(src)
	if b.size() < 44:
		return false
	var ch := 0
	var rate := 0
	var bits := 0
	var data_off := -1
	var data_len := 0
	var p := 12
	while p + 8 <= b.size():
		var cid := b.slice(p, p + 4).get_string_from_ascii()
		var csz := b.decode_u32(p + 4)
		var body := p + 8
		if cid == "fmt ":
			ch = b.decode_u16(body + 2)
			rate = b.decode_u32(body + 4)
			bits = b.decode_u16(body + 14)
		elif cid == "data":
			data_off = body
			data_len = csz
		p = body + csz + (csz & 1)   # chunks are word-aligned
	if data_off == -1 or ch == 0 or (bits != 16 and bits != 24):
		return false
	var bytes_per := bits / 8
	var frame_bytes := bytes_per * ch
	var data_end := mini(data_off + data_len, b.size())
	var nframes := (data_end - data_off) / frame_bytes
	if nframes <= 0:
		return false

	# decode interleaved samples to float [-1, 1]
	var samp := PackedFloat32Array()
	samp.resize(nframes * ch)
	var idx := data_off
	for i in nframes * ch:
		var v := 0
		if bits == 16:
			v = b.decode_s16(idx)
			samp[i] = float(v) / 32768.0
		else:
			v = b[idx] | (b[idx + 1] << 8) | (b[idx + 2] << 16)
			if v & 0x800000:
				v -= 0x1000000
			samp[i] = float(v) / 8388608.0
		idx += bytes_per

	# robot chain
	var w_c := TAU * CARRIER_HZ / float(rate)
	var comb_d := maxi(1, int(round(float(rate) / COMB_HZ)))
	var comb_buf := PackedFloat32Array()
	comb_buf.resize(comb_d * ch)
	comb_buf.fill(0.0)
	var cbi := 0
	var out16 := PackedByteArray()
	out16.resize(nframes * ch * 2)
	var oi := 0
	for fr in nframes:
		var car := sin(w_c * float(fr))
		for c in ch:
			var s := samp[fr * ch + c]
			var r := lerpf(s, s * car, RING_MIX)       # ring modulation
			var y := r + COMB_FB * comb_buf[cbi + c]   # feedback comb
			comb_buf[cbi + c] = y
			var x := clampf(y * DRIVE, -1.5, 1.5)       # soft clip (cubic)
			var cl := x
			if x > 1.0:
				cl = 1.0
			elif x < -1.0:
				cl = -1.0
			else:
				cl = 1.5 * x - 0.5 * x * x * x
			out16.encode_s16(oi, int(round(clampf(cl, -1.0, 1.0) * 32767.0)))
			oi += 2
		cbi = (cbi + ch) % (comb_d * ch)

	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = ch == 2
	w.mix_rate = rate
	w.data = out16
	return w.save_to_wav(ProjectSettings.globalize_path(dst)) == OK
