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

// 0 none | 1 concrete+windows | 2 roof gravel | 3 asphalt | 4 vehicle panel | 5 glass
uniform int   detail        = 0;
uniform float detail_temp   = 0.0;    // degrees C, peak to peak
uniform float detail_emis   = 0.0;
uniform float storey_h      = 3.4;

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
    }

    float solar = solar_gain * max(0.0, dot(n, normalize(sun_dir)));
    float sky   = sky_loss * max(0.0, n.y);
    float graze = abs(dot(normalize(NORMAL), VIEW));
    float em    = clamp(emissivity + dE, 0.05, 1.0) * (0.62 + 0.38 * graze);

    float r = radiance(temp_c - sky + solar + dT) * em * (1.0 + fpn);
    ALBEDO = vec3(r * radiance_scale);
}
