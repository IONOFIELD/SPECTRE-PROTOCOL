SOURCE MAPS (Displacement → thermal structure)
==============================================
One PNG per ThermalLib material key. FEED DISPLACEMENT / HEIGHT, NOT COLOR.

Pipeline:
  H:\SPECTRE PROTOCOL\texture_library\<category>\*__Displacement.jpg
    → textures/source/<key>.png
    → tools/bake_thermal_maps.gd
    → textures/thermal/<key>.png  (runtime)

Keys present:
  wall  brick  window  parapet  road  sidewalk  park  ground  grass  tank  hvac

ground and park share Ground037 displacement (earth structure).

See: H:\SPECTRE PROTOCOL\texture_library\README.md
     CREDITS.txt (CC0 ambientCG provenance)

Bake:
  Godot --path "H:\SPECTRE PROTOCOL\SPECTRE PROTOCOL" --headless --script res://tools/bake_thermal_maps.gd
