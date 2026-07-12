# SPECTRE PROTOCOL

A thermal-optic squad-tactical game. You command ground elements through an
AC-130 gunship's ISR sensor feed — a FLIR downlink over a night-time San
Francisco — while an infection, rival teams, and an apex "Sanitation" force
work the same streets.

Built in **Godot 4.7**. Open the folder in Godot and press Play (`main.tscn`
is the entry scene). Runs on both the Forward+ and Mobile renderers.

## The one idea

**The framebuffer stores radiance, not colour.**

Every surface carries a temperature in Celsius. `thermal.gdshader` converts it
with Stefan-Boltzmann, `((T + 273.15) / 300)^4`, and writes that scalar to
ALBEDO. Nothing downstream knows about colour until `sensor.gdshader` applies a
palette at the very last step. Things fall out of the physics for free:

- **WHT HOT / BLK HOT is a sign flip**, not two parallel colour tables.
- **Roofs cool on their own.** `sky_loss` is how many degrees an up-facing
  surface sheds to the cold night sky, so one material renders a warm wall *and*
  a cold roof from a single draw call.
- **Weapons read cold.** Gun metal sits at emissivity 0.30 against a 33 °C
  operator.
- **The infected are hard to see.** Near-ambient body heat — a mechanic, not a
  palette choice.
- **Fire blinds the optic.** A flame is many times a warm body in radiance, and
  the AGC re-exposes the whole frame around it.

## Pipeline

```
  thermal.gdshader     temperature -> radiance, PSX vertex snap, flat shading
        |              (HDR SubViewport, the detector array)
        v
  sensor.gdshader      defocus -> bloom -> AGC -> noise (fixed-pattern, column,
        |              temporal) -> vignette -> dead pixels -> dither -> palette
        v
  channel_cut.gdshader flash -> snow -> roll -> tearing -> sync -> lock, plus
                       interlace, head-switching, dropout
```

The split is deliberate: sensor artifacts belong to the *optic* and ride in the
radiance buffer; display artifacts belong to the *monitor* and sit on top. The
internal render target is **640×360** — a detector resolution, not an art
choice. The AGC (`agc.gd`) is an auto-exposure that percentile-stretches each
frame, so the picture hunts and settles the way a real sensor does.

## Playing

A startup menu picks the run: **Tutorial**, or **Solo / 2 / 3 / 4 teams**.
Behind the menu, a Sanitation force sweeps a live simulation of the city.

You drive **one** element; the other teams are AI rivals fighting each other and
you. The board is worked through the optic:

- **Scan** (`E`) — enemy teams sit unidentified until an ISR scan paints them
  for a few seconds, on a cooldown.
- **Parley** (`P`) — offer a truce to the team under the reticle. Truces are
  mutual; a bracket colour tells you each team's stance (green yours, cyan
  allied, amber open to a truce, red hostile).
- **Loot** — hold on a building to clear it. It pays out an HDD drive, a field
  hospital (heal), a police armory (armor or a damage buff), or a bio-lab
  (damage resistance) — and can turn out to be a nest that mauls whoever
  breached it. Dedicated HDD drives are also scattered to scoop on foot.
- **AC-130** — a boresight fire mission unlocks after 100 infected kills; `V`
  designates a target. Friendly fire is real.
- **Sanitation** — draw enough heat and the apex force deploys. Once it's loose,
  extraction closes and only a bridge (or wiping the force) gets you out.

**Win** by eliminating every rival team, extracting on an evac LZ, or escaping
across a bridge. **Lose** if your element is wiped — or if you hoard 50 HDDs and
trip the nuke that levels everything. HDDs recovered multiply the final score.

Each unit type flies its own marker over the bracket — combat, commander, medic,
sniper, recon, EOD, and the Sanitation trefoil.

### Controls

```
LMB pick    RMB move    double-click send to reticle    hold-on-building loot
TAB / 1-4 element    Q / TYP cycle unit type    F weapons free    V AC-130 strike
E scan    P parley    SPACE AC-130 / ground view    WASD pan    wheel zoom
T palette    C monitor snow    G freeze AGC    H toggle help
```

Touch is supported (tap select, double-tap move, drag pan, pinch zoom, and an
on-screen control bar), so the same build runs on desktop and mobile.

## The simulation

`scripts/sim/world_sim.gd` is a struct-of-arrays sim (RefCounted, no nodes):
six factions on an irregular SF coastline with bridges, line-of-sight, steering,
axis-separated collision, medics, an EOD area weapon, and the Sanitation force's
flash-evade. It runs headless and is covered by `scripts/sim/sim_test.gd`:

```
Godot_v4.7-stable_win64_console.exe --headless --path . --script res://scripts/sim/sim_test.gd
```

## Audio

The whole mix is built in code by the `Audio` autoload
(`scripts/audio/audio_director.gd`) — no bus-layout resource to desync. The bus
graph is `Master -> ISR -> {Music, Ambience, SFX, UI, Comms}`. The **ISR** bus
is the gunship downlink: a radio band-pass, lo-fi crush, and AGC that every
diegetic sound rides. Squad radio calls run through a baked cyborg voice on the
**Comms** bus. World SFX are positional (an `AudioStreamPlayer3D` pool with a
listener on the camera).

## Files

| file | what |
|---|---|
| `shaders/thermal.gdshader` | temperature → radiance, vertex snap, flat shading, fire writhe |
| `shaders/sensor.gdshader` | the detector: AGC, bloom, noise, dither, palette |
| `shaders/channel_cut.gdshader` | the monitor: snow, roll, tearing, sync |
| `scripts/thermal_lib.gd` | the material temperature table |
| `scripts/agc.gd` | percentile-stretch auto-exposure |
| `scripts/citygen.gd` | the procedural San Francisco (coast, bridges, SoMa, Market St) |
| `scripts/sim/world_sim.gd` | the struct-of-arrays combat sim |
| `scripts/sim/mission.gd` | win / lose logic |
| `scripts/main.gd` | builds the tree in code, drives render / input / HUD / FX |
| `scripts/audio/audio_director.gd` | the `Audio` autoload: buses, ISR filter, comms voice |

`main.tscn` is the entry scene; the render tree, HUD, and audio graph are all
assembled in code so there is nothing in a scene file to fall out of sync.
