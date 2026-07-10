// SPECTRE PROTOCOL // sensor.gdshader
//
// Goes on the SubViewportContainer. TEXTURE is the radiance buffer coming out
// of thermal.gdshader. This is the optic and the detector, in order:
//
//   optics defocus -> bloom/halo -> AGC stretch -> gamma -> fixed pattern
//   noise -> column noise -> temporal noise -> vignette -> dead pixels ->
//   ordered dither -> 5-bit quantise -> palette
//
// agc_lo / agc_hi are driven from GDScript (agc.gd) by percentile-sampling the
// viewport. Freeze them during the channel cut and throw them wide on lock and
// the optic visibly hunts. That beat is what makes it read as a real camera.

shader_type canvas_item;
render_mode unshaded;

uniform vec2  res         = vec2(640.0, 360.0);
uniform float agc_lo      = 0.60;
uniform float agc_hi      = 1.10;
uniform float gamma_c     = 0.72;
uniform float bloom       = 0.50;
uniform float bloom_thresh_mul = 2.2;
uniform float scene_median = 0.85;   // pushed in from agc.gd
uniform float noise_amt   = 0.007;
uniform float fpn_amt     = 0.007;
uniform float vignette    = 0.18;
uniform float levels      = 64.0;
uniform bool  dither      = true;
uniform int   mode        = 0;       // 0 white hot, 1 black hot, 2 ironbow
uniform float time_s      = 0.0;

float hash1(float n) { return fract(sin(n) * 43758.5453123); }
float hash2(vec2 p)  { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }

const float BAYER[16] = float[16](
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0
);

vec3 ironbow(float v) {
    float r = min(1.0, pow(v, 0.55) * 1.35);
    float g = max(0.0, pow(v, 1.9) * 1.15 - 0.05);
    float b = min(1.0, pow(max(0.0, 0.55 - abs(v - 0.38) * 1.7), 1.2) + pow(v, 7.0) * 0.9);
    return vec3(r, g, b);
}

void fragment() {
    vec2 px = 1.0 / res;

    // --- optics defocus: 5-tap cross, the diffraction/focus limit of the lens
    float c = texture(TEXTURE, UV).r;
    float v = c * 0.44
            + texture(TEXTURE, UV + vec2( px.x, 0.0)).r * 0.14
            + texture(TEXTURE, UV + vec2(-px.x, 0.0)).r * 0.14
            + texture(TEXTURE, UV + vec2(0.0,  px.y)).r * 0.14
            + texture(TEXTURE, UV + vec2(0.0, -px.y)).r * 0.14;

    // --- bloom: threshold above the scene median, blur wide, add back.
    // Hot bodies halo. Fires blow the frame out. Both are correct.
    if (bloom > 0.0) {
        float thr = scene_median * bloom_thresh_mul;
        float b = 0.0;
        for (int i = 0; i < 12; i++) {
            float a = float(i) * 0.5236;                    // 30 deg apart
            float r = (i < 6) ? 3.0 : 7.0;
            vec2 o = vec2(cos(a), sin(a)) * r * px;
            b += max(0.0, texture(TEXTURE, UV + o).r - thr);
        }
        v += (b / 12.0) * bloom;
    }

    // --- AGC: percentile stretch, then the detector's transfer curve
    v = clamp((v - agc_lo) / max(1e-4, agc_hi - agc_lo), 0.0, 1.0);
    v = pow(v, gamma_c);

    // --- detector artifacts
    vec2 ipx = floor(UV * res);
    v *= 1.0 + (hash2(ipx) - 0.5) * 2.0 * fpn_amt;               // per-pixel gain, fixed
    v += (hash1(ipx.x * 977.0) - 0.5) * fpn_amt * 0.6;           // column offset, fixed
    v += (hash2(ipx + vec2(time_s * 61.0)) - 0.5) * 2.0 * noise_amt;   // temporal
    v += (hash1(ipx.y * 613.0 + floor(time_s * 60.0)) - 0.5) * noise_amt * 0.7; // row noise

    vec2 d = UV - 0.5;
    v *= 1.0 - vignette * dot(d, d) * 2.0;

    if (hash2(ipx * 7.0 + 13.0) > 0.99965) {                      // stuck pixels
        v = hash2(ipx) > 0.5 ? 1.0 : 0.0;
    }

    float q = levels - 1.0;
    if (dither) {
        int bi = int(mod(ipx.y, 4.0)) * 4 + int(mod(ipx.x, 4.0));
        v += (BAYER[bi] / 16.0 - 0.5) / q;
    }
    v = clamp(v, 0.0, 1.0);
    v = floor(v * q + 0.5) / q;                                   // 5-bit grey, PS1-ish

    vec3 col;
    if (mode == 1)      col = vec3(1.0 - v);
    else if (mode == 2) col = ironbow(v);
    else                col = vec3(v);

    COLOR = vec4(col, 1.0);
}
