extends SceneTree

## Sanitation "vocals": the squad's radio callouts, played BACKWARDS, for an eerie
## non-language mutter from the apex faction. Reverses each 16-bit comms clip (which is
## already the cyborg voice) frame-by-frame into audio/sfx/sanvox/.
##
## Run once (re-run if the comms change):
##   <godot_console> --headless --path . --script res://tools/reverse_comms.gd

const SRC := "res://audio/comms/"
const DST := "res://audio/sfx/sanvox/"


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DST))
	var d := DirAccess.open(SRC)
	if d == null:
		push_error("[reverse] no comms dir")
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
		if _reverse(SRC + name, DST + name):
			ok += 1
			print("[reverse] ", name)
	print("[reverse] done: %d/%d clips" % [ok, names.size()])
	quit(0 if ok == names.size() else 1)


func _reverse(src: String, dst: String) -> bool:
	var b := FileAccess.get_file_as_bytes(src)
	if b.size() < 44:
		return false
	var ch := 0
	var rate := 0
	var bits := 0
	var off := -1
	var dlen := 0
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
			off = body
			dlen = csz
		p = body + csz + (csz & 1)
	if off == -1 or ch == 0 or bits != 16:
		return false
	var frame := 2 * ch
	var end := mini(off + dlen, b.size())
	var nframes := (end - off) / frame
	var out := PackedByteArray()
	out.resize(nframes * frame)
	for i in nframes:
		var sp := off + (nframes - 1 - i) * frame
		for k in frame:
			out[i * frame + k] = b[sp + k]
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = ch == 2
	w.mix_rate = rate
	w.data = out
	return w.save_to_wav(ProjectSettings.globalize_path(dst)) == OK
