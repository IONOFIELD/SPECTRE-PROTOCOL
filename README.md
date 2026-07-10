# SPECTRE PROTOCOL // Godot 4 Render Stack

Godot 4.3+ (uses static vars). Forward+ renderer. Open the folder, run `main.tscn`.

Keys: `SPACE` channel change · `T` palette · `J` vertex snap · `C` cctv · `R` internal res · `G` freeze AGC · `O` auto orbit · drag orbit · shift-drag pan · wheel zoom

---

## Read this first

**None of this has been run against a real Godot editor.** I have no GPU and no
Godot binary in my environment. What I *did* verify is the only thing I could:
I re-implemented the GDScript rig line for line in another language and swept
the full gait at four speeds. Max bone-length error is 0.0000000 m, and the hip
(0.90) sits below the leg (0.455 + 0.455 = 0.910) so the knee never locks.

Everything else is careful, unverified code. The list of things most likely to
be wrong is at the bottom. Read it before you spend an hour debugging.

---

## The one idea

**The framebuffer stores radiance, not colour.**

Every surface carries a temperature in Celsius. `thermal.gdshader` converts it
with Stefan-Boltzmann, `((T + 273.15) / 300)^4`, and writes that scalar to
ALBEDO. Nothing downstream knows about colour until `sensor.gdshader` picks a
palette at the very last step.

Consequences that fall out for free rather than being authored:

- **WHT HOT / BLK HOT is a sign flip.** Not three parallel colour tables.
- **Roofs go black on their own.** `sky_loss` is how many degrees an up-facing
  surface sheds to a cold night sky. One `wall` material at 16.5 C with
  `sky_loss = 8.5` renders a 16.5 C wall *and* an 8 C roof. The physics does the
  shading. One material, one draw call.
- **Weapons read cold.** Gun metal has emissivity 0.30. It is the same
  temperature as the air and it looks it, against a 33 C operator.
- **Zombies are hard to see.** 17.5 C, near ambient. That is a mechanic, not a
  palette choice.
- **Your own explosions blind your optic.** Fire is 340 C, roughly 15x a warm
  body in radiance. The AGC renormalises the frame to whatever is in it.

## Pipeline

```
  thermal.gdshader   temperature -> radiance, vertex snap, flat shading
        |            (SubViewport 640x360, MSAA off, debanding off)
        v
  sensor.gdshader    optics defocus -> bloom -> AGC -> gamma -> fixed pattern
        |            noise -> column noise -> temporal noise -> vignette ->
        |            dead pixels -> ordered dither -> 5-bit quantise -> palette
        v
  channel_cut.gdshader   flash -> snow -> roll -> tearing -> sync -> lock
                         plus persistent interlace, head-switching, dropout
```

The split is not cosmetic. Sensor artifacts belong to the *optic*. Display
artifacts belong to the *monitor*. If snow went into the radiance buffer,
black-hot mode would invert your static and the AGC would try to expose for it.

## Why 640x360

A FLIR Boson is 640x512. The internal render target is not an art decision, it
is the detector array. `R` cycles 320x180 / 640x360 / 960x540.

## The channel cut, 520 ms

| t | phase | |
|---|---|---|
| 0 - 26 ms | FLASH | switch bounce, 16 px tear |
| 26 - 156 ms | SNOW | full-contrast static, roll, retrace bar. AGC frozen, HUD dropped |
| 156 ms | SWAP | new camera goes live, hidden under the snow |
| 156 - 239 ms | ACQUIRE | feed bleeds through, tearing decays |
| 239 - 270 ms | SYNC | discrete vertical-hold jumps |
| 270 - 520 ms | LOCK | `agc.knock_out_of_lock()` fires. The picture washes out and settles. |

That last beat is what sells it. The camera does not arrive already exposed.

## Files

| file | what |
|---|---|
| `shaders/thermal.gdshader` | spatial. temperature to radiance. vertex snapping. |
| `shaders/sensor.gdshader` | canvas. the detector. on the SubViewportContainer. |
| `shaders/channel_cut.gdshader` | canvas. the monitor. full-screen ColorRect. |
| `scripts/thermal_lib.gd` | the temperature table. 24 materials. |
| `scripts/trooper.gd` | 12-limb rig, two-bone IK, gait phase from distance. |
| `scripts/citygen.gd` | low-poly city. box + parapet + HVAC + tank. |
| `scripts/agc.gd` | percentile stretch from a downscaled viewport read. |
| `scripts/main.gd` | builds the whole tree in code. no .tscn to desync. |
| `scripts/audio/audio_director.gd` | autoload `Audio`. bus graph, ducking, master limiter, music bed. |
| `audio/music/music1.wav` | the bed. a seamless loop, mastered hot; level set on the bus. |

## Audio

Built after r8. The whole mix comes up in code in `scripts/audio/audio_director.gd`
(autoload `Audio`), for the same reason the render tree does — nothing to desync.
Bus graph is `Master -> {Music, SFX, UI}`, with a compressor on `Music`
sidechained to `SFX` so world sound ducks the bed, and a hard limiter on `Master`
because every asset here is mastered hot (`music1` peaks at 0 dBFS). The bed loops,
forced in code rather than trusted to the WAV importer. Drop new sounds in
`audio/sfx` / `audio/ui`, trigger with `Audio.sfx(...)` / `Audio.ui(...)`. Full
notes, the tuning knobs, and the obvious wiring hooks (the channel cut is the
first SFX cue that should exist) are in **`audio/README.md`**.

## Fixed in r2

GDScript's analyzer cannot infer a type from a conditional expression, and it
reports the failure as a **parse error**, not a warning. Every `var x := A if
cond else B` in the pack was one. Same for `var m := SOME_DICT[key]`, where the
index yields a Variant. Both patterns are now explicitly typed throughout:

    var zone := 0 if dc < 1.6 else 1        # parse error
    var zone: int = 0 if dc < 1.6 else 1    # fine

`citygen.gd:50` was simply the first one the loader reached, alphabetically.
`trooper.gd`, `main.gd`, and `thermal_lib.gd` had the same bug waiting.

## Most likely to be broken

Ranked by how much of your evening it will cost.

1. **AGC read.** `agc.gd` calls `vp.get_texture().get_image()`, which forces a
   GPU to CPU sync. It runs every 4th frame on an 80x45 downscale. If it stalls,
   move the sampling to a second tiny SubViewport, or swap the whole thing for
   `CameraAttributesPractical.auto_exposure_enabled` and drive `agc_lo/agc_hi`
   from `Environment` instead.

2. **Radiance range.** I default `radiance_scale` to 1/16 so everything stays in
   `[0, 1]` and the viewport does not need HDR. That costs precision at 8 bits.
   If you see banding in the roofs, set `SubViewport.use_hdr_2d = true` and
   `radiance_scale = 1.0`, then re-tune `agc_lo/agc_hi` (they will be 16x larger).

3. **`POSITION` in `vertex()`.** Writing clip-space POSITION is how the vertex
   snap works. If Godot fights you over `PROJECTION_MATRIX * MODELVIEW_MATRIX`,
   the fallback is `render_mode skip_vertex_transform` and doing the whole
   transform by hand.

4. **`varying flat vec3`.** Required for the flat-shaded facets. If the compiler
   rejects it, compute the world normal per-fragment from `dFdx/dFdy` of the
   world position instead.

5. **`hint_screen_texture` in `channel_cut.gdshader`.** The ColorRect must draw
   *after* the SubViewportContainer. It is on a `CanvasLayer` above it, which
   should be enough, but check.

6. **Trooper yaw.** Godot models face -Z, so `rotation.y = atan2(-dx, -dz)`. If
   the squad walks sideways, this is the line.

## Not ported from v0.20

Windows on the buildings (needs inset quads, not a box face). Vehicles. Fires
and explosion splats. Fog of war. Every HUD overlay. The whole sim.

The sim is roughly 2,800 lines of JavaScript with no physics engine, only AABBs,
arrays, and steering. It does not port, it gets rewritten. Estimate three to
five weekends. The look pipeline in front of you is the weekend that matters,
because it is the part that was expensive to get right the first time.
