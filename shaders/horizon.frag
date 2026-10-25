#version 440
// Orpheus "Horizon": glowing ridgelines rolling toward you out of a banded
// sun. Each ridge is a moment of sound: new ones rise at the horizon and
// travel forward, mirrored so the bass swells in the middle. Stars twinkle
// above; every kick pulses the sun.

//#common

layout(binding = 1) uniform sampler2D hist;

const int K = 30;            // ridges, front (0) to back
const float R = 40.0;        // history rows

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    p = rotateAround(p, vec2(res.x * 0.5, res.y * 0.6), camRoll());     // the camera banks
    p.y -= camBob(res.y);
    vec2 uv = p / res;
    float horizon = res.y * 0.60;

    // col is premultiplied throughout (rgb already scaled by coverage).
    vec4 col = vec4(0.0);

    // ---- sky: stars and the sun -------------------------------------------------
    if (p.y > horizon) {
        // Round, sub-pixel stars on a sparse jittered grid, each with its own twinkle.
        vec2 cell = floor(p / 9.0);
        vec2 at = (cell + 0.2 + 0.6 * vec2(hash(cell + 3.1), hash(cell + 5.7))) * 9.0;
        float star = step(0.88, hash(cell)) * glow(length(p - at), 0.9 + hash(cell + 1.3) * 0.6);
        float tw = 0.45 + 0.55 * sin(time * (1.2 + hash(cell + 7.0) * 2.5) + hash(cell) * 40.0);
        float s = lit(star * tw * smoothstep(horizon, res.y, p.y) * 0.8);
        col = vec4(fg.rgb * s, s);
    }
    vec2 sc = vec2(res.x * 0.5, horizon + res.y * 0.05);
    float sr = res.y * (0.21 + bass * 0.03 + beat * 0.025);
    float sd = length(p - sc);
    if (p.y > horizon - 1.0) {
        float sv = clamp((p.y - (sc.y - sr)) / (2.0 * sr), 0.0, 1.0);
        // Bands thin out toward the bottom and drift down, classic synthwave.
        float bandsY = fract(sv * 10.0 - flow * 0.42);
        float gap = smoothstep(0.0, 0.08, bandsY - (1.0 - sv) * 0.55);
        float disc = clamp(sr - sd + 0.5, 0.0, 1.0) * gap;
        vec3 sun = mix(c2.rgb, c1.rgb, sv) + lit(beat * 0.25);
        float a = disc * 0.92;
        col = vec4(col.rgb * (1.0 - a) + sun * a, col.a * (1.0 - a) + a);
    }
    float halo = lit(glow(max(sd - sr, 0.0), sr * 0.9) * (0.28 + energy * 0.35 + beat * 0.45));
    col.rgb += c2.rgb * halo * 0.8 * (1.0 - col.a);
    col.a = max(col.a, halo * 0.8);

    // ---- ridges: front to back, the first one above the pixel owns it -------------
    for (int k = 0; k < K; k++) {
        float z = float(k) / float(K - 1);                   // 0 front, 1 back
        float persp = 1.0 / (1.0 + z * 3.2);
        float baseY = mix(res.y * 0.02, horizon, 1.0 - persp * (1.0 - z * 0.2));
        // Narrower toward the back, and the landscape winds left and right with depth.
        float cx = (uv.x - 0.5 - roadBend(z * 40.0) * 0.8) / mix(1.0, 0.42, z) + 0.5;
        if (cx < 0.0 || cx > 1.0) continue;
        float fx = abs(cx - 0.5) * 2.0;                      // 0 = centre (bass) .. 1 = edges (treble)

        // Newest sound at the back ridge, rolling forward.
        float hi = (float(K - 1 - k) / float(K - 1)) * (R - 1.0);
        float v = k == K - 1 ? band(fx) : texture(hist, vec2(fx, (hi + 0.5) / R)).r;
        float env = smoothstep(1.0, 0.5, fx);
        float h = v * env * res.y * 0.40 * persp + hash(vec2(floor(cx * 120.0), float(k))) * 0.8;
        float y = baseY + h;

        if (p.y <= y + 1.5) {
            float d = y - p.y;                               // distance below the ridge line
            float line = clamp(1.5 - abs(d), 0.0, 1.0);      // 1.5px anti-aliased line
            float halo2 = lit(glow(max(d, 0.0), 6.0 * persp) * 0.35);
            float fade = mix(1.0, 0.30, z);
            vec3 lc = pal(z * 0.7 + fx * 0.3) * (1.0 + lit(beat * 0.4 * (1.0 - z)));
            vec3 body = mix(bg.rgb * 0.72, bg.rgb, light);
            if (d < -0.5) {                                  // just above the line: glow only
                float a = line * fade;
                col = vec4(col.rgb * (1.0 - a) + lc * a, col.a * (1.0 - a) + a);
                continue;
            }
            vec3 rgb = mix(body, lc * fade + bg.rgb * (1.0 - fade), max(line, halo2 * fade));
            col = vec4(rgb * 0.95, 0.95);
            break;
        }
    }

    fragColor = vec4(col.rgb + dither(p) * col.a, col.a) * qt_Opacity;
}
