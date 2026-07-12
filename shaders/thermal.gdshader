// SPECTRE PROTOCOL // thermal.gdshader  r4
//
// Every surface is a temperature, not a colour. ALBEDO carries radiance:
//   radiance = ((T_celsius + 273.15) / 300)^4        (Stefan-Boltzmann)
//
// r4 adds surface detail. It is NOT albedo texture. A brick photo would be
// discarded: there is no colour channel to put it in. Detail here is a
// per-fragment modulation of TEMPERATURE and EMISSIVITY, which is the only
// thing an infrared sensor can resolve.
//
//   sky_loss    degrees shed by an up-facing surface to a cold night sky. One
//               "wall" material therefore renders a 16.5 C wall and an 8 C roof.
//   solar_gain  residual afternoon loading. The wall that faced the sun is still
//               warm hours after dusk. Largest cue in a real night frame, and it
//               costs one dot product.
//
// Triplanar, so boxes need no UVs and nothing has to be unwrapped.

shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, shadows_disabled, fog_disabled;

uniform float temp_c        = 16.5;
uniform float sky_loss      = 8.5;
uniform float emissivity    = 0.92;
uniform float fpn           = 0.0;
uniform float radiance_scale = 1.0;   // requires SubViewport.use_hdr_2d = true

uniform vec3  sun_dir       = vec3(0.855, 0.300, -0.425);
uniform float solar_gain    = 0.0;

// 0 none | 1 concrete+windows | 2 roof gravel | 3 asphalt | 4 vehicle panel
// 5 glass | 6 sidewalk | 7 grass | 8 parking lot
uniform int   detail        = 0;
uniform float detail_temp   = 0.0;    // degrees C, peak to peak
uniform float detail_emis   = 0.0;
uniform float storey_h      = 3.4;
uniform float flicker       = 0.0;    // 1.0 for fire: a live swell/shrink pulse in radiance
uniform float writhe        = 0.0;    // 1.0 for a fire PLUME: the mesh licks/dances (not wreck hulls)

// Optional photographic detail. NOT albedo: the map holds the high-pass residual
// of a real texture, which is structure (mortar, gaps, rivets) rather than colour.
// 0.5 is a flat surface, below is recessed, above is proud.
uniform sampler2D thermal_map : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool  use_map       = false;
uniform vec2  map_scale     = vec2(2.4);  // metres per tile, u and v.
                                          // Non-square source art stretches if this is scalar.
uniform float map_temp      = 1.6;    // degrees C at full-scale structure
uniform float map_emis      = 0.05;

uniform vec2  snap_res      = vec2(640.0, 360.0);
uniform bool  snap_enabled  = true;

varying flat vec3 v_world_normal;
varying vec3 v_world_pos;

float radiance(float tc) {
    float k = (tc + 273.15) / 300.0;
    float k2 = k * k;
    return k2 * k2;
}

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    return vnoise(p) * 0.6 + vnoise(p * 2.17) * 0.26 + vnoise(p * 4.4) * 0.14;
}

// distance to the nearest grid line, in metres
float seam(float x, float pitch) {
    return abs(fract(x / pitch) - 0.5) * pitch;
}

void vertex() {
    // Fire plume: writhe the mesh so the flame licks and dances (silhouette moves even
    // when the hot core saturates white). Upward-biased -- the tips whip, the base holds.
    if (writhe > 0.0) {
        float t = TIME;
        float up = clamp(VERTEX.y * 0.5 + 0.55, 0.0, 1.4);
        VERTEX.x += (sin(t * 3.3 + VERTEX.y * 2.3) * 0.20 + sin(t * 5.9 + VERTEX.z * 3.1) * 0.10) * up * writhe;
        VERTEX.z += (cos(t * 3.0 + VERTEX.z * 2.0) * 0.16 + sin(t * 6.4 + VERTEX.x * 3.0) * 0.09) * up * writhe;
        VERTEX.y += (sin(t * 4.2 + VERTEX.x * 2.6 + VERTEX.z * 2.6) * 0.12 + 0.09 * sin(t * 7.0)) * up * writhe;
    }
    v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

    vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
    if (snap_enabled && clip.w > 0.0) {
        vec2 half_res = snap_res * 0.5;
        clip.xy = floor(clip.xy / clip.w * half_res + 0.5) / half_res * clip.w;
    }
    POSITION = clip;
}

void fragment() {
    vec3 n = v_world_normal;
    vec3 p = v_world_pos;

    vec3 aw = abs(n);
    aw /= (aw.x + aw.y + aw.z);
    vec2 uv_side = (aw.x > aw.z) ? vec2(p.z, p.y) : vec2(p.x, p.y);
    vec2 uv = mix(uv_side, p.xz, aw.y);

    float dT = 0.0;
    float dE = 0.0;

    if (detail == 1) {
        // Cast concrete. Formwork lines every 0.6 m, panel joints every 3.0 m.
        // A joint has more mass behind it, lags the surface, and reads cold.
        float form = smoothstep(0.035, 0.0, seam(uv.y, 0.6));
        float joint = smoothstep(0.05, 0.0, min(seam(uv.x, 3.0), seam(uv.y, storey_h)));
        float mottle = fbm(uv * 1.6) - 0.5;
        dT = mottle * detail_temp - (form * 0.35 + joint * 0.9);
        dE = -joint * detail_emis;

        // Heated interior bleeding through glass, one band per storey. Some bays
        // are dark and cold. Glass is low emissivity, so a lit window is warm
        // but flat, never as hot as the body behind it.
        float y = fract(p.y / storey_h) * storey_h;
        float win = smoothstep(0.9, 1.15, y) * (1.0 - smoothstep(2.30, 2.55, y));
        float mullion = smoothstep(0.06, 0.0, seam(uv.x, 1.5));
        win *= (1.0 - mullion) * (1.0 - aw.y);
        float lit = step(0.42, hash21(floor(vec2(uv.x / 1.5, p.y / storey_h))));
        dT += win * lit * 7.5 - win * (1.0 - lit) * 2.0;
        dE -= win * 0.16;
    } else if (detail == 2) {
        // Roof gravel: high-frequency mottle plus membrane seams.
        float g = fbm(uv * 7.0) - 0.5;
        float s = smoothstep(0.07, 0.0, seam(uv.x, 1.8));
        dT = g * detail_temp - s * 0.5;
        dE = (fbm(uv * 13.0) - 0.5) * detail_emis;
    } else if (detail == 3) {
        // Asphalt. Warm, but the wheel tracks are polished and hold water, so
        // they run cold and shiny. Emissivity rises where the surface is wet.
        float grain = fbm(uv * 5.5) - 0.5;
        float across = (abs(n.y) > 0.5) ? uv.y : uv.x;
        float track = smoothstep(1.4, 0.55, abs(seam(across, 7.0) - 1.05));
        dT = grain * detail_temp - track * 1.6;
        dE = track * detail_emis;
    } else if (detail == 4) {
        // Vehicle sheet metal. Panel gaps are cold; the metal itself is thin
        // and even. This is what makes a car read as a car and not a crate.
        float gap = smoothstep(0.022, 0.0, min(seam(uv.x, 0.85), seam(uv.y, 0.7)));
        dT = (fbm(uv * 9.0) - 0.5) * detail_temp - gap * 2.2;
        dE = -gap * detail_emis;
    } else if (detail == 5) {
        float streak = fbm(vec2(uv.x * 2.0, uv.y * 0.35)) - 0.5;
        dT = streak * detail_temp;
    } else if (detail == 6) {
        // Poured concrete walk. Expansion joints on a 1.5 m grid: more mass,
        // they lag, they read cold. Occasional cast-iron cover: low emissivity,
        // so it reads very cold even though it is the same temperature.
        float j = min(seam(uv.x, 1.5), seam(uv.y, 1.5));
        float joint = smoothstep(0.06, 0.0, j);
        vec2 cell = floor(uv / 6.0);
        float cover = (hash21(cell) > 0.94) ? smoothstep(0.42, 0.30, length(fract(uv / 6.0) - 0.5) * 6.0) : 0.0;
        dT = (fbm(uv * 2.4) - 0.5) * detail_temp - joint * 0.8;
        dE = -joint * detail_emis - cover * 0.55;
    } else if (detail == 7) {
        // Vegetation. Evaporative, so it runs cold and blotchy. The blotches are
        // where the canopy is thin and bare soil shows through, which is warmer.
        float coarse = fbm(uv * 0.35) - 0.5;
        float fine = fbm(uv * 3.2) - 0.5;
        dT = coarse * detail_temp * 1.3 + fine * detail_temp * 0.5;
        dE = fine * detail_emis;
    } else if (detail == 8) {
        // Surface parking. Stall lines every 2.6 m, and asphalt patches of a
        // different age that never quite match the temperature around them.
        float stall = smoothstep(0.07, 0.0, seam(uv.x, 2.6)) * step(seam(uv.y, 11.0), 2.6);
        float patch = step(0.62, fbm(uv * 0.22));
        dT = (fbm(uv * 4.0) - 0.5) * detail_temp + patch * 1.1 - stall * 0.6;
        dE = stall * detail_emis;
    }

    if (use_map) {
        float s = texture(thermal_map, uv / map_scale).r * 2.0 - 1.0;
        // A recess (s < 0) is a cavity. Cavities approach a blackbody, so their
        // apparent emissivity RISES. They also sit behind more mass, so their
        // temperature falls. The two fight; the cavity usually wins on a facade.
        dT += s * map_temp * 0.35;
        dE += -s * map_emis;
    }

    float solar = solar_gain * max(0.0, dot(n, normalize(sun_dir)));
    float sky   = sky_loss * max(0.0, n.y);
    // Emissivity is flat out to roughly 55 degrees of incidence and then falls
    // off a cliff. The old linear term (0.62 + 0.38*graze) put a 19% radiance
    // ramp across every flat facet, which is exactly the gouraud gradient that
    // made this look like a cheap render.
    float graze = abs(dot(normalize(NORMAL), VIEW));
    float fall = 1.0 - 0.30 * pow(1.0 - graze, 5.0);   // flat to ~60 deg, then a cliff
    float em    = clamp(emissivity + dE, 0.05, 1.0) * fall;

    float r = radiance(temp_c - sky + solar + dT) * em * (1.0 + fpn);
    // Flame: bands of shimmer rising through the body + a breathing pulse. The shimmer
    // carves moving DARK tongues (visible even when the hot core saturates to white) and
    // brightens the cores, so the sensor bloom reads them as licking, growing glow.
    if (flicker > 0.0) {
        float t = TIME;
        vec2 fp = vec2((v_world_pos.x + v_world_pos.z) * 0.7, v_world_pos.y * 1.1 - t * 2.6);
        float shim = fbm(fp);                                    // 0..1 rising structure
        float pulse = 0.5 + 0.5 * sin(t * 5.2 + v_world_pos.x * 0.5 + v_world_pos.z * 0.5);
        float m = mix(0.42, 1.28, shim) * (0.82 + 0.18 * pulse);
        r *= mix(1.0, m, flicker);
        r = max(r, 0.0);
    }
    ALBEDO = vec3(r * radiance_scale);
}
