# SPECTRE — H: texture & thermal map

**Workspace root:** `H:\SPECTRE PROTOCOL\`  
**Godot project:** `H:\SPECTRE PROTOCOL\SPECTRE PROTOCOL\`

## Layout (canonical)

```
H:\SPECTRE PROTOCOL\
  SPECTRE PROTOCOL\          ← open this in Godot
    textures\
      source\                Displacement greys (input to bake)
      thermal\               Baked structure maps (runtime)
    tools\bake_thermal_maps.gd
    scripts\thermal_lib.gd   MAP_DIR = res://textures/thermal/
    shaders\thermal.gdshader use_map + thermal_map
  texture_library\           Full ambientCG PBR packs (was GROK)
  texture_library.zip
  AUDIO\
```

## What was removed / renamed

| Old | New |
|-----|-----|
| `GROK` / `GROK.zip` | `texture_library` / `texture_library.zip` |
| Desktop `SP TEXTURES`, bulk `TEXTURES*` | Removed from H: — not used as runtime source |

## Material → files

| Key | Library folder | source PNG | thermal PNG |
|-----|----------------|------------|-------------|
| wall | wall_concrete | source/wall.png | thermal/wall.png |
| brick | wall_brick | source/brick.png | thermal/brick.png |
| window | window_frame | source/window.png | thermal/window.png |
| parapet | parapet_concrete | source/parapet.png | thermal/parapet.png |
| road | road_asphalt | source/road.png | thermal/road.png |
| sidewalk | sidewalk | source/sidewalk.png | thermal/sidewalk.png |
| park | park_ground | source/park.png | thermal/park.png |
| ground | park_ground | source/ground.png | thermal/ground.png |
| grass | grass | source/grass.png | thermal/grass.png |
| tank | tank_metal | source/tank.png | thermal/tank.png |
| hvac | hvac_grille | source/hvac.png | thermal/hvac.png |

## Runtime

`ThermalLib.get_material(name, snap_res)`:

1. Sets base T / sky_loss / emissivity / solar from `MAT` table  
2. If `maps_on` and `res://textures/thermal/<name>.png` exists → `use_map=true`  
3. Else procedural `detail` kinds 0–8  

Toggle structure maps in play if wired; cache key includes `maps_on`.

## Re-bake after library changes

```bat
"C:\Users\III\Documents\Godot_v4.7-stable_win64_console.exe" --path "H:\SPECTRE PROTOCOL\SPECTRE PROTOCOL" --headless --script res://tools/bake_thermal_maps.gd
```
