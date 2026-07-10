# SPECTRE PROTOCOL // Audio

Same disclaimer as the render stack: **none of this has been run in a real Godot
editor.** It is careful, unverified code. The list of things most likely to be
wrong is at the bottom.

## The one idea

**The mix is built in code, not in a `.tres`.** `scripts/audio/audio_director.gd`
is an autoload singleton (`Audio`). On `_ready()` it creates the bus graph, hangs
the effects, and owns every player. There is no `default_bus_layout.tres` to open
in the mixer and drift out of sync with what the game actually asks for — for the
same reason `main.gd` builds the render tree in code instead of shipping a
`.tscn`.

```
  Master   AudioEffectHardLimiter, ceiling -0.5 dB   <- safety net
   |
   +- Music   the bed. AudioEffectCompressor, sidechain = SFX
   +- SFX     world sound: gunfire, the channel cut, vehicles
   +- UI      menu blips, selection ticks. never ducked.
```

## Why any of this

Every asset in this project is mastered **hot**. `music1.wav` peaks at 0.00 dBFS
with -5.6 dBFS RMS — a brickwalled master with zero headroom. The SFX will arrive
the same way. Three things fall out of that, and the bus graph answers each:

- **The bed would bury the SFX.** So `Music` sits at `MUSIC_BED_DB = -6.0`. That
  is the "reduce it a few dB" — done on the bus, not baked into the file, so the
  source stays pristine and the number stays tunable in one place.
- **The bed would still fight a gunshot.** So a compressor on `Music` is
  **sidechained to `SFX`**: world sound ducks the music while it plays and lets
  it back up after. With nothing on the SFX bus yet this is transparent, so it is
  safe to have live now — it simply starts working the day the first shot lands.
- **Hot things stack over the rail.** A shot, over the bed, over the channel-cut
  static, summed, will clip the master. `AudioEffectHardLimiter` at -0.5 dB on
  `Master` catches it. Nobody has to ride a fader.

## Looping

`music1.wav` is authored as a seamless loop (no lead/tail silence, tail butts the
head). The loop is forced **in code** in `_apply_loop()` at the moment the stream
is handed to a player:

    w.loop_mode = AudioStreamWAV.LOOP_FORWARD
    w.loop_begin = 0
    w.loop_end   = <full length in frames>

This deliberately does **not** depend on the WAV importer, which defaults loop to
Disabled. Ship the `.wav`, let Godot import it however it likes, and the loop is
still correct because we set it after `load()`. OGG/MP3 streams use their single
`loop` flag instead; `_apply_loop()` handles all three.

## Adding the sounds you send next

1. Drop the file in `audio/sfx/` (world) or `audio/ui/` (interface), or another
   track in `audio/music/`.
2. Trigger it:

        Audio.sfx(preload("res://audio/sfx/rifle_shot.wav"), -2.0)
        Audio.ui("res://audio/ui/select_tick.wav")
        Audio.crossfade_music("res://audio/music/music2.wav", 3.0)

   `sfx`/`ui` take a preloaded `AudioStream` or a `res://` path. One-shots run
   through a small pooled set of players, so rapid fire does not allocate.

Two hooks already have an obvious home in `main.gd` the moment the assets exist:

- **The channel cut** — `_channel_change()` / the `CUT_SWAP` beat. A static burst
  on `SFX` here will duck the bed exactly on the cut, which is free drama.
- **Selection / move orders** — `_select_nearest`, `order_move` → a `Audio.ui()`
  tick.

I left these unwired because there is no asset to point them at yet, not because
they are hard. One line each when the sounds land.

## Level / options menu

`Audio.set_bus_linear("Music", value)` maps a 0..1 slider to dB for you.
`set_bus_db`, `mute_bus` are there too. Wire these to sliders whenever the options
screen exists.

## Positional audio (not built yet)

`sfx()` is non-positional — it plays flat, centred. True 3D audio (a shot that
pans and attenuates with the trooper's distance from the optic) needs an
`AudioStreamPlayer3D` **inside the SubViewport** plus an `AudioListener3D` on the
camera there, because the game world lives in that 640x360 viewport, not the main
one. Worth doing for gunfire and vehicles; skipped now because there is nothing to
play and the listener plumbing is its own small job.

## Release-time: convert to OGG

The bed ships as a 23 MB WAV. Godot keeps that uncompressed in RAM (~46 MB as
float). Fine for a dev build, wasteful for a release. One line, once you have a
tool in the environment:

    ffmpeg -i audio/music/music1.wav -c:a libvorbis -q:a 6 audio/music/music1.ogg

Then repoint `MUSIC_BED` in `main.gd`. `_apply_loop()` already handles OGG, so
nothing else changes. ~2-3 MB, streamed from disk instead of held in memory.

## Most likely to be broken

Ranked by how much of an evening it costs.

1. **`AudioEffectCompressor.sidechain`.** I set it to the StringName `"SFX"`. If
   Godot wants the *bus index* or refuses a sidechain to a bus that carried no
   signal at init, the duck silently does nothing. Check the compressor on the
   Music bus in the mixer once there is SFX to test with.
2. **`AudioEffectHardLimiter`.** Added in Godot 4.3. On 4.2 it does not exist and
   the autoload will throw on `_install_master_limiter()`. If you are on 4.2, swap
   it for `AudioEffectLimiter` (`ceiling_db` → `ceiling_db`, same idea).
3. **Autoload timing.** `Audio._ready()` builds the buses before `main.gd`
   `_ready()` calls `play_music`, because autoloads initialise first. If you ever
   call `Audio` from another autoload, ordering is no longer guaranteed.
4. **The bed level.** `-6 dB` is a guess with no SFX to balance against. It is one
   constant, `MUSIC_BED_DB`. Expect to move it once real sound is in the mix.
