// SPECTRE PROTOCOL // channel_cut.gdshader
//
// Full-screen ColorRect drawn OVER the sensor output. These are display-side
// artifacts. A channel change is something the monitor does, not something the
// optic sees. If snow went into the radiance buffer, black-hot would invert it
// and the AGC would try to expose for it.
//
// cut_p in [0,1]. Below 0 the cut is idle and only the CCTV layer runs.
//
//   0.00 - 0.05  FLASH     switch bounce, huge horizontal tear
//   0.05 - 0.30  SNOW      full-contrast static, vertical roll, retrace bar
//        0.30    SWAP      the game swaps camera here, hidden under the snow
//   0.30 - 0.46  ACQUIRE   feed bleeds through, tearing decays
//   0.46 - 0.52  SYNC      discrete vertical-hold jumps
//   0.52 - 1.00  LOCK      residual hot pixels, AGC hunts back down

shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform vec2  res       = vec2(640.0, 360.0);
uniform float cut_p     = -1.0;
uniform float time_s    = 0.0;
uniform float frame_n   = 0.0;
uniform float cctv      = 0.85;   // 0 disables the persistent layer

float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float seg(float p, float a, float b) { return clamp((p - a) / (b - a), 0.0, 1.0); }

// Analog snow is horizontally bandwidth limited: correlated along a scanline,
// uncorrelated between them. Three horizontal taps produce exactly that.
float snow(vec2 ipx, float field) {
    float a = hash2(vec2(ipx.x - 1.0, ipx.y) + field * 37.0);
    float b = hash2(vec2(ipx.x,       ipx.y) + field * 37.0);
    float c = hash2(vec2(ipx.x + 1.0, ipx.y) + field * 37.0);
    return clamp((a * 0.18 + b * 0.64 + c * 0.18 - 0.5) * 1.55 + 0.5, 0.0, 1.0);
}

void fragment() {
    vec2 uv   = SCREEN_UV;
    vec2 ipx  = floor(uv * res);
    float fld = floor(frame_n * 0.5);          // hold each snow field two frames

    float p = cut_p;
    float amt_snow = 0.0, tear = 0.0, roll = 0.0, flash = 0.0;
    bool settled = false;

    if (p >= 0.0) {
        flash    = 1.0 - seg(p, 0.0, 0.05);
        amt_snow = p < 0.30 ? 1.0 : 1.0 - seg(p, 0.30, 0.46);
        tear     = p < 0.04 ? 16.0 : (p < 0.30 ? 4.0 : 11.0 * (1.0 - seg(p, 0.30, 0.52)));
        roll     = p < 0.30 ? 1.0 : 1.0 - seg(p, 0.30, 0.42);
        settled  = p > 0.52;
    }

    // vertical hold slip, in discrete jumps as the sync separator re-locks
    float jump = 0.0;
    if (p >= 0.36 && p < 0.52) {
        float k = floor((p - 0.36) / 0.04);
        jump = k < 1.0 ? 6.0 : (k < 2.0 ? -3.0 : (k < 3.0 ? 2.0 : -1.0));
    }

    float roll_off = roll > 0.0 ? mod(frame_n * 13.0 + p * 1400.0, res.y) : 0.0;

    // interlace comb (CCTV, always on): the two fields never quite agree
    float odd = mod(ipx.y, 2.0);
    float comb_shift = (cctv > 0.0 && mod(frame_n, 2.0) > 0.5) ? odd : 0.0;

    float sy = ipx.y;
    if (roll > 0.0) sy = mod(sy + floor(roll_off * roll), res.y);
    sy = mod(sy + jump + res.y, res.y);

    float sh = comb_shift;
    if (tear > 0.05) {
        float n = hash2(vec2(ipx.y, floor(frame_n * 7.0))) * 2.0 - 1.0;
        sh += floor((n * 0.72 + 0.28 * sin(ipx.y * 0.31 + frame_n * 0.9)) * tear);
    }

    vec2 suv = (vec2(clamp(ipx.x + sh, 0.0, res.x - 1.0), sy) + 0.5) / res;
    vec3 col = texture(screen_tex, suv).rgb;

    if (amt_snow > 0.0) col = mix(col, vec3(snow(ipx, fld)), amt_snow);

    // retrace bar: the dark band with a bright leading edge
    if (roll > 0.0) {
        float d = mod(ipx.y - roll_off + res.y, res.y);
        if (d < 1.0)      col *= 1.9;
        else if (d < 9.0) col *= 0.16;
    }
    if (flash > 0.0) col += vec3(flash * 0.92);
    if (settled && hash2(ipx + frame_n * 3.7) > 0.9985) col = vec3(1.0);

    if (cctv > 0.0) {
        col *= 1.0 - 0.05 * cctv * odd;                       // comb darkening

        // head-switching noise: the torn band at the bottom of every tape frame
        float hs = res.y - 3.0;
        if (ipx.y >= hs) {
            float t = (ipx.y - hs) / 3.0;
            float a = (0.30 + 0.55 * t) * cctv;
            float off = floor((hash2(vec2(frame_n, ipx.y)) - 0.5) * 9.0 * cctv);
            vec2 huv = (vec2(clamp(ipx.x + off, 0.0, res.x - 1.0), ipx.y) + 0.5) / res;
            col = mix(col, vec3(snow(floor(huv * res), fld)), a);
        }

        // dropout: a row or two lose signal, roughly every four seconds
        if (hash2(vec2(floor(frame_n / 8.0), 3.0)) > 0.988) {
            float y0 = floor(hash2(vec2(frame_n, 31.0)) * (res.y - 4.0)) + 1.0;
            if (ipx.y >= y0 && ipx.y < y0 + 2.0) col = vec3(snow(ipx, fld) * 0.55 + 0.16);
        }
    }

    COLOR = vec4(col, 1.0);
}
