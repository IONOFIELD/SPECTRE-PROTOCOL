# SPECTRE PROTOCOL — Mobile (Android / iOS)

The game is built to run on phones. The sim, thermal render stack, and gameplay
are input-agnostic; the touch layer and responsive framing sit on top. This doc
is the build guide + what's already configured.

## What already works (verified on desktop)

- **Renderer.** The thermal stack (SubViewport HDR `use_hdr_2d` / RGBA16F +
  `thermal.gdshader` spatial + `sensor.gdshader` canvas) renders **identically on
  Forward Mobile (Vulkan) and GL Compatibility (OpenGL 3.3)** as on Forward+.
  No shader changes are needed for mobile. `project.godot` sets
  `renderer/rendering_method.mobile="mobile"`, so Android/iOS use Forward Mobile.
  Very old / non-Vulkan devices can fall back to `gl_compatibility`.
- **Responsive framing.** `window/stretch/aspect="expand"` +
  `handheld/orientation="sensor"` + `resizable` — the game **fills any window /
  orientation** instead of letterboxing 16:9. The thermal detector reshapes to
  the window aspect (`main._init_res` from the launch window, `main._reframe` on
  resize/rotate). Portrait phone fills portrait; landscape fills landscape.
- **Touch.** One-finger drag pans, two-finger pinch zooms, a tap selects your
  squad's element / moves it to the tapped ground. `emulate_mouse_from_touch=off`
  so touch doesn't double-fire the mouse path. On-screen control bar (element
  1-4 / FIRE / ISR / PAL), bottom-right in landscape, along the bottom in
  portrait (the keyboard card is dropped there). Mouse + keyboard still work, so
  desktop is unaffected.

## Build steps (one-time setup, then export)

1. **Export templates.** Editor → *Editor → Manage Export Templates* → download
   the 4.7-stable templates.
2. **Android SDK/JDK.** Install Android Studio (or the command-line SDK) + a JDK
   17. Editor → *Editor → Editor Settings → Export → Android*: point *Android SDK
   Path* + *Debug/Release Keystore* at them. (See the Godot "Exporting for
   Android" docs for the exact keystore + `debug.keystore` steps.)
3. **Export preset.** *Project → Export → Add… → Android*. It inherits the
   project's Mobile renderer + sensor orientation. Set the package name (e.g.
   `com.ionofield.spectreprotocol`), min SDK 24+, and the architectures
   (`arm64-v8a` for modern phones; add `armeabi-v7a` for older).
4. **Export.** *Export Project* → `.apk` for sideload/test, or `.aab` for Play.

### iOS — same project, second preset (no fork)

Android and iOS ship from **one codebase / one `main`** — add an **iOS** export
preset alongside the Android one; do **not** fork the repo. Everything here
(touch, responsive framing, the Mobile renderer, gameplay) is platform-agnostic
and runs on both. iOS specifics:

- Build the final app on **macOS with Xcode** (Godot exports an Xcode project you
  then build/sign). The Godot side is identical to Android.
- Set the bundle identifier + a team/signing profile in the iOS preset.
- The **Mobile (Vulkan→Metal)** renderer path is the one already verified; Godot
  maps Forward Mobile onto Metal on iOS.
- Platform-specific code (rare — IAP, a native API) uses `OS.get_name()` checks +
  feature tags, never a separate repo.

## Testing without a device (desktop)

- `Godot --path . --rendering-method mobile` — run under the mobile Vulkan backend.
- `Godot --path . --rendering-method gl_compatibility` — the old-device path.
- `Godot --path . --resolution 480x900` (or any WxH) — check a portrait/landscape
  layout. `SPECTRE_MAP=<dir>` grabs one whole-map PNG for a quick visual check.

## Performance on phone GPUs

The **sim is not the bottleneck** — ~1.7–3.9 ms/tick for the full ecology
(300+ units, land polygon, LOS). The render cost is dominated by the **~300
building shells** (`ThermalModel.spawn_fit` GLBs) plus the units.

Tunables, coarsest first, if a target device drops frames:

- **Resolution** — `main.RESOLUTIONS` vertical res (the `R` key cycles it). The
  detector is deliberately low-res; drop to the 180-line preset on weak GPUs.
- **Building density** — `citygen` block park/lot probabilities, or cull small
  buildings.
- **Unit counts** — `main.POP_INFECTED/CIV/SAN`, `POP_RUNNERS/BRUTES`,
  `BANDIT_CREWS`, `SURVIVOR_HOLDOUTS`, `GAUNTLET_PER_BRIDGE`.
- **Detail** — `ThermalLib.detail_on` / `maps_on` (env vars `SPECTRE_NODETAIL` /
  `SPECTRE_NOMAPS`) drop the procedural + photographic structure passes.
- Old devices: force `gl_compatibility` in the export preset.
