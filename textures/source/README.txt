SOURCE MAPS
===========
One PNG per material, named after the key in scripts/thermal_lib.gd:
  wall  window  parapet  road  sidewalk  ground  lot  park  grass  tank  hvac

SUPPLY THE DISPLACEMENT / HEIGHT CHANNEL. NOT THE COLOR CHANNEL.
Albedo does not exist at 8-14 microns. A high-passed Color map reports paint,
and on brick and painted concrete it reports the mortar joint as PROUD when it
is RECESSED. The shader then treats a ridge as a cavity and the joint reads cold.
Measured correlation of high-passed Color against true height on this set:
  road +0.999   hvac +0.923   window +0.722   wall_concrete +0.678
  sidewalk +0.376   park +0.311   grass +0.061   tank -0.024
  wall_brick -0.416   parapet -0.508

The PNGs currently here are the Displacement channel of the ambientCG sets,
converted to 8-bit greyscale. Provenance in ../CREDITS.txt.

Bake:
  godot --headless --path . --script res://tools/bake_thermal_maps.gd
