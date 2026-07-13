# SPECTRE PROTOCOL — Mobile (Android first, iOS next)

The game runs on phones from the same `main` — the sim, thermal render, and
gameplay are input-agnostic; the touch layer and responsive framing sit on top.
This is the build guide + a record of what's configured and what's verified.

---

## What's configured & verified

- **Mobile renderer — VERIFIED.** `project.godot` sets
  `renderer/rendering_method.mobile="mobile"`, so Android/iOS use **Forward
  Mobile (Vulkan)**. The full thermal stack (HDR SubViewport `use_hdr_2d` /
  RGBA16F + `thermal.gdshader` spatial + `sensor.gdshader` canvas) was booted
  under `--rendering-method mobile` and renders correctly — buildings, roads,
  bridges, HUD, element roster all intact, no shader errors. No shader changes
  needed for mobile.
- **Auto perf preset — VERIFIED.** On an Android/iOS build (`_is_mobile()` in
  `main.gd`) the game boots a lighter profile automatically: **320×180** thermal
  detector (vs 640×360 on desktop), detail-mesh pass **off**, ambient horde at
  **~60%**, and a **340** live-unit respawn ceiling (vs 620). All invisible
  through a 320-line optic. Preview it on desktop with `SPECTRE_MOBILE=1`.
- **Android export preset — SCAFFOLDED.** `export_presets.cfg` ships an
  `Android` preset: package `com.ionofield.spectreprotocol`, `arm64-v8a`,
  immersive fullscreen, APK output to `build/spectre-protocol.apk`. You still
  need the one-time toolchain below before it will export.
- **Responsive framing.** `window/stretch/aspect="expand"` +
  `handheld/orientation="sensor"` — fills any window/orientation instead of
  letterboxing 16:9. The detector reshapes to the window aspect
  (`main._init_res` on launch, `main._reframe` on resize/rotate).
- **Touch.** One-finger drag pans, two-finger pinch zooms, a tap
  selects/moves your squad. `emulate_mouse_from_touch=off` so touch doesn't
  double-fire the mouse path. On-screen control bars. Mouse + keyboard still
  work — desktop is unaffected.

> **`gl_compatibility` (OpenGL, pre-Vulkan phones) — renders, but WASHED OUT.**
> Tested under `--rendering-method gl_compatibility`: it boots and draws the map
> + HUD, **but the thermal contrast is muted** — buildings read as flat mid-gray
> instead of hot-white, because the FLIR look depends on an **HDR float render
> target** the compatibility renderer tonemaps differently. The hot/cold
> separation that is the entire point of the optic is lost. **Ship the beta for
> Vulkan devices** (Android 7+/2016+ hardware is effectively all Vulkan). A GL
> fallback needs a dedicated tonemap/exposure fix first — later task, not a claim.

---

## One-time toolchain setup (Windows)

Nothing Android-related is installed on this machine yet. You need three things:
**(A) Godot export templates, (B) a JDK, (C) the Android SDK.** The easiest way
to get B+C in one shot is Android Studio; a lighter command-line-only path is in
the collapsible section after.

### 1. Godot export templates (for 4.7-stable)

In the Godot editor: **Editor → Manage Export Templates → Download and Install**
(pick the 4.7-stable set). This adds the Android engine libraries the export
needs. One-time, ~700 MB.

### 2 + 3. JDK 17 + Android SDK — via Android Studio (recommended)

1. Install **Android Studio** (bundles a compatible JDK and the SDK manager).
2. First launch → let it install the default SDK. Then **SDK Manager → SDK
   Tools** and make sure these are checked/installed:
   - **Android SDK Platform-Tools** (gives you `adb`)
   - **Android SDK Build-Tools** (latest)
   - **Android SDK Command-line Tools (latest)**
3. Note the two paths you'll give Godot:
   - **Android SDK**: usually `C:\Users\III\AppData\Local\Android\Sdk`
   - **JDK (JBR bundled with Studio)**:
     `C:\Program Files\Android\Android Studio\jbr`

<details>
<summary>Alternative: command-line only (no Android Studio, lighter)</summary>

1. Install **OpenJDK 17** (e.g. Temurin/Adoptium). Note its home, e.g.
   `C:\Program Files\Eclipse Adoptium\jdk-17...`.
2. Download **Android "Command line tools only"** from the Android developer
   site. Unzip to `C:\Android\cmdline-tools\latest\` (the `bin` folder must sit
   directly under `latest`).
3. From that `bin` folder, install the pieces (accept licenses when asked):
   ```
   sdkmanager.bat "platform-tools" "build-tools;34.0.0" "platforms;android-34"
   sdkmanager.bat --licenses
   ```
   Your **Android SDK path** is `C:\Android` (the folder that contains
   `cmdline-tools`, `platform-tools`, …).
</details>

### Point Godot at the toolchain (once)

Godot editor → **Editor → Editor Settings → Export → Android**:
- **Android SDK Path** → the SDK folder from step 2/3.
- **Java SDK Path** → the JDK/JBR folder.
- **Debug Keystore** → leave blank and Godot auto-generates one on first
  export (debug user/pass `android`/`android`), or create it yourself:
  ```
  keytool -keyalg RSA -genkeypair -alias androiddebugkey -keypass android \
    -keystore debug.keystore -storepass android \
    -dname "CN=Android Debug,O=Android,C=US" -validity 9999 -deststoretype pkcs12
  ```

---

## Build the beta APK

The `Android` preset already exists (`export_presets.cfg`), so:

**Editor path (simplest first time):** **Project → Export → Android →
Export Project**, filename `build/spectre-protocol.apk`, **Export With Debug**
checked. That signs it with the debug keystore — installable on any phone.

**Command-line path (once the paths above are set):**
```
"C:\Users\III\Documents\Godot_v4.7-stable_win64_console.exe" \
  --headless --path "H:\SPECTRE PROTOCOL" \
  --export-debug "Android" "H:\SPECTRE PROTOCOL\build\spectre-protocol.apk"
```

If the export complains, it's almost always one of: templates not installed
(step 1), SDK/JDK path unset (step 3), or no keystore (leave it blank to
auto-gen).

## Get it onto your brothers'/friends' phones

- **USB:** enable Developer Options → USB debugging on the phone, then
  `adb install -r build\spectre-protocol.apk`.
- **No cable:** send them the `.apk` (email/Drive/Discord). On the phone, open it
  and allow "install from unknown sources" for that app. It's debug-signed, so it
  just installs — no Play Store, no account.

---

## iOS — same project, second preset (no fork)

Android and iOS ship from **one codebase / one `main`**. When you're ready, add
an **iOS** export preset alongside the Android one — do not fork. Everything
(touch, responsive framing, Mobile renderer, gameplay) is platform-agnostic.
iOS specifics: the final build happens on **macOS with Xcode** (Godot exports an
Xcode project you build/sign); set the bundle id + signing team in the preset;
Godot maps Forward Mobile onto **Metal**. Any rare native bits use
`OS.get_name()` / feature-tag checks, never a separate repo.

---

## Preview the phone build on desktop (no device)

- `--rendering-method mobile` — run under the mobile Vulkan backend (what Android
  uses). **Verified.**
- `SPECTRE_MOBILE=1` (env) — force the mobile perf preset (320×180, detail off,
  thinner horde) on a desktop box.
- `--resolution 480x900` (or any WxH) — check a portrait layout; `--resolution
  900x480` for landscape. The detector + HUD reflow to the aspect.

Combine them to see exactly what a phone renders:
```
SPECTRE_MOBILE=1  Godot ... main.tscn --rendering-method mobile --resolution 480x900
```

## Performance knobs (if a target device still drops frames)

The auto preset (`main._apply_mobile_preset`) already handles the big wins. If a
weak device needs more, coarsest first:

- **Detector resolution** — `main.RESOLUTIONS` / `res_idx` (in-game res-cycle
  key). The mobile default is the 180-line preset; there's nothing lower worth
  shipping.
- **Horde size** — `main._pop_scale` (spawn density) and `main._swarm_cap` /
  `_swarm_local` (respawn ceiling + squad-local top-up). Lower them in
  `_apply_mobile_preset`.
- **Detail passes** — `ThermalLib.detail_on` / `maps_on` (already off on mobile;
  `maps_on` can go too).
- **Building density** — `citygen` block/lot probabilities, or cull small shells.
  Heavy GLBs already ship auto-generated **LODs** (`generate_lods=true`), so
  distant buildings/bridges self-decimate; the 320×180 target makes LOD very
  aggressive already.
- **Last resort, old GPUs** — a `gl_compatibility` fallback (needs the HDR-target
  work noted up top first).
