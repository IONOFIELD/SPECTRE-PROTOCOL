extends Node

## SPECTRE PROTOCOL // audio director   (autoload singleton: "Audio")
##
## The whole audio side, built in code for the same reason the render tree is:
## there is no default_bus_layout.tres to drift out of sync with what the game
## actually asks for. Buses, the ducking sidechain, the master limiter, the
## music bed and a small one-shot pool all come up here in _ready().
##
##   Master   AudioEffectHardLimiter, ceiling -0.5 dB  -- the safety net
##    |
##    +- Music   the bed. AudioEffectCompressor sidechained to SFX, so world
##    |          sound ducks the music instead of fighting it on the master.
##    +- SFX     world sound: gunfire, the channel cut, vehicles.
##    |   +- Comms   the radio voice, on its own bus (pitched down + trimmed),
##    |              routed through SFX so it still ducks the music.
##    +- UI      menu blips, selection ticks. never ducked.
##
## Everything the game plays is hot -- music1 masters at 0 dBFS, -5.6 RMS, and
## the SFX will land the same way. We do NOT touch the files. Level lives on the
## bus (MUSIC_BED_DB) so the source stays pristine and the mix stays tunable,
## and the master limiter catches whatever still stacks over the rail.
##
## API:
##   Audio.play_music("res://audio/music/music1.wav")   # loops, fades in
##   Audio.play_ambience("res://audio/ambience/ghost_town.wav")
##   Audio.comms("order_go")      Audio.comms_order()   # radio callouts
##   Audio.sfx(stream_or_path, -3.0)      Audio.ui(stream_or_path)
##   Audio.set_bus_linear("Music", 0.7)                 # for an options slider

const BUS_MASTER := "Master"
const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"
const BUS_UI := "UI"

## The bed sits this far under unity. "A few dB" off a hot master; the sidechain
## below pulls it further only while SFX are actually playing. Tune here -- this
## is the only place a music level is hardcoded.
const MUSIC_BED_DB := -6.0

## Master brickwall. Assets are mastered hot and will stack (a gunshot over the
## bed over the channel-cut static). This keeps the sum off the rail without
## anyone having to ride faders.
const MASTER_CEILING_DB := -0.5

const FADE_FLOOR_DB := -60.0   # "silent" for fades; below audibility, cheap

## A second looping bed under the music: the mission ambience (ghost-town wind,
## distant dread). Ducked by SFX like the music, and pitched lower still.
const BUS_AMBIENCE := "Ambience"
const AMBIENCE_BED_DB := -12.0
const BUS_ISR := "ISR"   # gunship-downlink filter; diegetic buses route through it, music bypasses
const COMMS_DIR := "res://audio/comms/"   # radio callouts, one file per phrase

## The radio voice gets its own bus so it can be levelled + weighted apart from the
## rest of the SFX. It routes THROUGH SFX (so it still ducks the music and picks up
## the ISR headset filter). The CYBORG character itself is baked into the clips
## offline (ring-mod + comb + clip -- see tools/robotize_comms.gd); this bus only
## trims the level and adds a little downward weight on top. Two tunables, here only.
const BUS_COMMS := "Comms"
const COMMS_DB := -0.75             # voice sits 0.75 dB under the rest of the net
const COMMS_PITCH_CENTS := -120.0   # a touch of weight; the robot timbre is baked in

var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_cur: AudioStreamPlayer
var _oneshots: Array[AudioStreamPlayer] = []
var _ambience: AudioStreamPlayer
var _comms_next_ms: int = 0


func _ready() -> void:
	_setup_buses()
	_music_a = _new_player(BUS_MUSIC)
	_music_b = _new_player(BUS_MUSIC)
	_music_cur = _music_a
	_ambience = _new_player(BUS_AMBIENCE)


# ---- bus graph -------------------------------------------------------------

func _setup_buses() -> void:
	# The ISR filter bus sits between the diegetic buses and Master. The MUSIC bed
	# BYPASSES it -- the score isn't coming through the gunship headset, so it
	# stays full-fidelity, straight to Master. Create ISR first so the buses that
	# route into it get a higher index (Godot processes high -> low).
	_ensure_bus(BUS_ISR, BUS_MASTER, 0.0)
	_install_isr(BUS_ISR)
	_ensure_bus(BUS_MUSIC, BUS_MASTER, MUSIC_BED_DB)        # clean, straight to Master
	_ensure_bus(BUS_AMBIENCE, BUS_ISR, AMBIENCE_BED_DB)     # ambience is a "noise" -> ISR
	_ensure_bus(BUS_SFX, BUS_ISR, 0.0)
	_ensure_bus(BUS_UI, BUS_ISR, 0.0)
	# Comms routes INTO SFX (higher index, so it's processed first): the voice still
	# drives the music duck and rides the ISR filter, this bus just pitches + trims it.
	_ensure_bus(BUS_COMMS, BUS_SFX, COMMS_DB)
	_install_comms_pitch(BUS_COMMS)
	_install_ducking(BUS_MUSIC, BUS_SFX)
	_install_ducking(BUS_AMBIENCE, BUS_SFX)
	_install_master_limiter()


func _ensure_bus(bus_name: String, send_to: String, volume_db: float) -> int:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, send_to)
	AudioServer.set_bus_volume_db(idx, volume_db)
	return idx


## SFX energy ducks the music bed. With nothing on SFX this is transparent, so
## it is safe to install now and starts working the moment sound arrives.
func _install_ducking(target_bus: String, sidechain_bus: String) -> void:
	var idx: int = AudioServer.get_bus_index(target_bus)
	if idx == -1:
		return
	_clear_effects(idx)
	var comp := AudioEffectCompressor.new()
	comp.threshold = -22.0
	comp.ratio = 6.0
	comp.attack_us = 100.0
	comp.release_ms = 380.0
	comp.gain = 0.0
	comp.sidechain = StringName(sidechain_bus)
	AudioServer.add_bus_effect(idx, comp)


## The safety rail. Everything -- the filtered diegetic feed AND the clean music
## bed -- lands on Master, so the brickwall limiter lives here and only here.
func _install_master_limiter() -> void:
	var idx: int = AudioServer.get_bus_index(BUS_MASTER)
	_clear_effects(idx)
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = MASTER_CEILING_DB
	AudioServer.add_bus_effect(idx, lim)


## The AC-130 ISR downlink. Every DIEGETIC sound -- guns, zeds, comms, the
## ambience -- routes through this bus, so it all comes through the gunship
## headset: a radio band (420 Hz - 3.4 kHz), bit/sample crushed for the low-bitrate
## feed, then AGC-squashed like a squelched net. The music bed skips it entirely.
## Four numbers to tune the character; this is the only place it lives.
func _install_isr(bus_name: String) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	_clear_effects(idx)

	var hp := AudioEffectHighPassFilter.new()   # kill the bass -- no chest, all comms
	hp.cutoff_hz = 420.0
	AudioServer.add_bus_effect(idx, hp)

	var lp := AudioEffectLowPassFilter.new()    # kill the air -- bandlimited downlink
	lp.cutoff_hz = 3400.0
	AudioServer.add_bus_effect(idx, lp)

	var crush := AudioEffectDistortion.new()    # the "low bitrate": sample/bit reduction
	crush.mode = AudioEffectDistortion.MODE_LOFI
	crush.drive = 0.35
	crush.post_gain = -2.0
	AudioServer.add_bus_effect(idx, crush)

	var agc := AudioEffectCompressor.new()      # radio AGC: pull everything to one level
	agc.threshold = -20.0
	agc.ratio = 4.0
	agc.attack_us = 400.0
	agc.release_ms = 180.0
	AudioServer.add_bus_effect(idx, agc)


## Drop the operator's voice a fixed interval without slowing it down -- a real
## pitch shifter (phase vocoder), not a resample, so the words keep their tempo.
## COMMS_PITCH_CENTS cents -> a pitch_scale of 2^(cents/1200).
func _install_comms_pitch(bus_name: String) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	_clear_effects(idx)
	var ps := AudioEffectPitchShift.new()
	ps.pitch_scale = pow(2.0, COMMS_PITCH_CENTS / 1200.0)
	AudioServer.add_bus_effect(idx, ps)


func _clear_effects(bus_idx: int) -> void:
	for i in range(AudioServer.get_bus_effect_count(bus_idx) - 1, -1, -1):
		AudioServer.remove_bus_effect(bus_idx, i)


# ---- music -----------------------------------------------------------------

## Start (or crossfade to) a looping bed. `source` is a res:// path or an
## AudioStream. Two players ping-pong so a track change is a real crossfade.
## Pass fade_in <= 0 for an abrupt cut-in: full level from the first sample.
## Loop is forced on the stream here -- see _apply_loop.
func play_music(source, fade_in := 0.8) -> void:
	var stream: AudioStream = _as_stream(source)
	if stream == null:
		push_warning("[Audio] could not load music: %s" % [source])
		return
	_apply_loop(stream)
	var incoming: AudioStreamPlayer = _music_b if _music_cur == _music_a else _music_a
	incoming.stream = stream
	var was_playing: bool = _music_cur != null and _music_cur.playing
	if fade_in <= 0.0:
		incoming.volume_db = 0.0          # abrupt: no ramp from silence
		incoming.play()
		if was_playing:
			_music_cur.stop()
	else:
		incoming.volume_db = FADE_FLOOR_DB
		incoming.play()
		_fade(incoming, 0.0, fade_in)
		if was_playing:
			_fade(_music_cur, FADE_FLOOR_DB, fade_in, true)
	_music_cur = incoming


func crossfade_music(source, dur := 2.0) -> void:
	play_music(source, dur)


func stop_music(fade_out := 1.0) -> void:
	if _music_cur != null and _music_cur.playing:
		_fade(_music_cur, FADE_FLOOR_DB, maxf(0.01, fade_out), true)


func _fade(p: AudioStreamPlayer, to_db: float, dur: float, stop_after := false) -> void:
	var tw := create_tween()
	tw.tween_property(p, "volume_db", to_db, dur)
	if stop_after:
		tw.tween_callback(p.stop)


# ---- one-shots -------------------------------------------------------------

func sfx(source, volume_db := 0.0) -> void:
	_one_shot(source, BUS_SFX, volume_db)


func ui(source, volume_db := 0.0) -> void:
	_one_shot(source, BUS_UI, volume_db)


# ---- ambience bed + radio comms --------------------------------------------

## The mission ambience loop -- a second bed beneath the music. fade_in <= 0 cuts
## in hard; otherwise it swells up over fade_in seconds.
func play_ambience(source, fade_in := 3.0) -> void:
	var stream: AudioStream = _as_stream(source)
	if stream == null:
		push_warning("[Audio] could not load ambience: %s" % [source])
		return
	_apply_loop(stream)
	_ambience.stream = stream
	if fade_in <= 0.0:
		_ambience.volume_db = 0.0
		_ambience.play()
	else:
		_ambience.volume_db = FADE_FLOOR_DB
		_ambience.play()
		_fade(_ambience, 0.0, fade_in)


func stop_ambience(fade_out := 2.0) -> void:
	if _ambience != null and _ambience.playing:
		_fade(_ambience, FADE_FLOOR_DB, maxf(0.01, fade_out), true)


## A radio callout by file stem under audio/comms/ (e.g. "order_go"). Cooldown-
## gated so rapid orders don't stack voice lines. Plays on the Comms bus (pitched +
## trimmed), which feeds SFX, so it still ducks the music + ambience -- the radio
## cuts through, just lower and deeper than the rest of the net.
func comms(stem: String, cooldown_ms := 1200) -> void:
	var now: int = Time.get_ticks_msec()
	if now < _comms_next_ms:
		return
	_comms_next_ms = now + cooldown_ms
	_one_shot(COMMS_DIR + stem + ".wav", BUS_COMMS, 0.0)


## A random move-order acknowledgement.
func comms_order() -> void:
	var lines: Array = ["order_go", "order_move_out", "order_push", "order_ready"]
	comms(lines[randi() % lines.size()])


func _one_shot(source, bus: String, volume_db: float) -> void:
	var stream: AudioStream = _as_stream(source)
	if stream == null:
		return
	var p: AudioStreamPlayer = _free_oneshot()
	p.bus = bus
	p.stream = stream
	p.volume_db = volume_db
	p.play()


func _free_oneshot() -> AudioStreamPlayer:
	for p in _oneshots:
		if not p.playing:
			return p
	var p: AudioStreamPlayer = _new_player(BUS_SFX)
	_oneshots.append(p)
	return p


# ---- mixer knobs (for a future options menu) -------------------------------

func set_bus_db(bus: String, db: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, db)


func set_bus_linear(bus: String, f: float) -> void:
	set_bus_db(bus, linear_to_db(clampf(f, 0.0001, 1.0)))


func mute_bus(bus: String, muted: bool) -> void:
	var idx: int = AudioServer.get_bus_index(bus)
	if idx != -1:
		AudioServer.set_bus_mute(idx, muted)


# ---- helpers ---------------------------------------------------------------

func _new_player(bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p


func _as_stream(source) -> AudioStream:
	if source is AudioStream:
		return source as AudioStream
	if source is String:
		var res: Resource = load(source)
		if res is AudioStream:
			return res as AudioStream
		if (source as String).to_lower().ends_with(".wav"):
			return load_wav_file(source)   # fallback: parse the raw file
	return null


## Ensure a full-file forward loop. The loop itself is baked by the importer
## (edit/loop_mode=1 in music1.wav.import); here we just guarantee FORWARD and,
## for the raw-parse fallback path only, fill in the bounds.
##
## Do NOT derive loop_end from data.size() unless the sample is uncompressed
## PCM. Godot 4.7 imports WAV as QOA by default, where data.size() is the
## COMPRESSED byte count -- dividing it by the frame size gives a loop_end far
## too early (the original "loops as the drums start" bug).
func _apply_loop(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var w := stream as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		if w.loop_end <= 0:                # only when the import baked no loop
			var chans: int = 1
			if w.stereo:
				chans = 2
			var frame_bytes: int = 0
			if w.format == AudioStreamWAV.FORMAT_16_BITS:
				frame_bytes = 2 * chans
			elif w.format == AudioStreamWAV.FORMAT_8_BITS:
				frame_bytes = chans
			if frame_bytes > 0:
				w.loop_begin = 0
				w.loop_end = w.data.size() / frame_bytes
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true


## Build an AudioStreamWAV straight from a .wav on disk. Used as a fallback when
## load() has nothing (asset not imported yet), and handy for hot-loading a new
## sound during a mixing pass. Handles 16-bit PCM -- what the pipeline produces
## -- and refuses anything else rather than returning garbage.
static func load_wav_file(path: String) -> AudioStreamWAV:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var b := f.get_buffer(f.get_length())
	f.close()
	if b.size() < 44:
		return null
	var channels: int = 0
	var rate: int = 0
	var bits: int = 0
	var data_off: int = -1
	var data_len: int = 0
	var p: int = 12   # past "RIFF" <size> "WAVE"
	while p + 8 <= b.size():
		var cid: String = b.slice(p, p + 4).get_string_from_ascii()
		var csz: int = b.decode_u32(p + 4)
		var body: int = p + 8
		if cid == "fmt ":
			channels = b.decode_u16(body + 2)
			rate = b.decode_u32(body + 4)
			bits = b.decode_u16(body + 14)
		elif cid == "data":
			data_off = body
			data_len = csz
		p = body + csz + (csz & 1)   # chunks are word-aligned
	if data_off == -1 or bits != 16 or channels == 0:
		return null
	var data_end: int = mini(data_off + data_len, b.size())
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = channels == 2
	w.mix_rate = rate
	w.data = b.slice(data_off, data_end)
	return w
