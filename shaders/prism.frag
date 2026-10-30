#version 440
// Orpheus "Prism": the spectrum as a 2.5D city driving toward you, seen from a
// three-quarter angle. New sound rises at the horizon and rolls closer every
// frame along a road that winds left and right. A low sun burns behind the
// skyline and throws shafts through the haze; distance dissolves into that
// glow. Lit windows, emissive rooftops, a synthwave grid underfoot. Kicks punch
// the camera in and jolt it sideways, flash the sun and flare the grid; the
// overall loudness slowly pushes the camera closer.

//#common

layout(binding = 1) uniform sampler2D hist;

const int R = 40;            // rows of history (matches the 32x40 history target)
const float N = 32.0;
const float K = 0.045;       // perspective: row r is scaled 1 / (1 + r*K)

// Soft saturation so stacked light flashes instead of clipping flat.
vec3 sat3(vec3 x) { return x / (1.0 + max(max(x.r, x.g), x.b) * 0.6); }

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;

    // ---- camera: push in with the loudness, punch and jolt on kicks -----------
    vec2 focus = vec2(res.x * 0.5, res.y * 0.42);
    float zoom = 1.0 + swell * 0.07 + kick * kick * 0.06;
    float jolt = (hash(vec2(kicks, 3.7)) - 0.5) * 2.0;      // a new direction every kick
    p = focus + (p - focus) / zoom;
    p = rotateAround(p, focus, camRoll() + jolt * kick * kick * 0.035);
    p += vec2(jolt * kick * kick * res.x * 0.012, kick * res.y * 0.015);

    float W = res.x * 0.94;
    float cx = res.x * 0.5;
    float base = res.y * (0.04 + beat * 0.012) + camBob(res.y);
    float maxH = res.y * 0.50 * (1.0 + kick * 0.12);
    float rise = res.y * 1.15;
    float horizon = base + rise * (1.0 - 1.0 / (1.0 + float(R) * K));
    float vanish = cx - res.x * 0.06 + float(R) * res.x * 0.0045 + roadBend(float(R)) * res.x;
    float dark = 1.0 - light;

    // Atmosphere colour: the sun's glow, which distant buildings fade into.
    vec3 sunCol = mix(c2.rgb, c1.rgb, 0.35 + 0.3 * sin(time * 0.07));
    vec3 fogCol = mix(bg.rgb, mix(bg.rgb, sunCol, 0.22), dark);

    vec4 col = vec4(0.0);
    vec3 bloom = vec3(0.0);

    for (int r = 0; r < R; r++) {                            // r = 0 is the row nearest you
        float fr = float(r);
        float s = 1.0 / (1.0 + fr * K);
        float by = base + (1.0 - s) * rise;
        if (p.y < by - 2.0) break;                           // everything further back sits higher
        float rowW = W * s;
        float xl = cx - rowW * 0.5 - res.x * 0.06 + fr * res.x * 0.0045 + roadBend(fr) * res.x;
        float pitch = rowW / N;
        float w = pitch * 0.62;
        float dx = pitch * 0.30, dy = pitch * 0.30;

        float c = floor((p.x - xl) / pitch);
        if (c < 0.0 || c >= N) continue;
        float x0 = xl + c * pitch;

        // Newest sound at the horizon (history row 0), oldest nearest you.
        float hi = float(R - 1 - r);
        float v = r == R - 1 ? band(c / 31.0)
                             : texture(hist, vec2((c + 0.5) / N, (hi + 0.5) / float(R))).r;
        v = pow(v, 1.25);                                     // quiet stays low, loud towers
        float h = max(1.0, v * maxH * s);
        float fog = smoothstep(float(R) * 0.22, float(R - 1), fr);
        vec3 tint = pal(c / 31.0);
        float heat = smoothstep(0.30, 0.95, v);
        vec3 hot = mix(tint * (1.1 + kick * 0.2 * dark), vec3(1.0), (0.05 + 0.30 * heat + kick * 0.06) * dark);

        // Rooftop bloom, strongest near you and on kicks.
        float topY = by + h + dy * 0.5;
        // (Only hot rows: heat is 0 below a third of full, so most rows skip the two exps.)
        if (dark > 0.0 && heat > 0.0 && p.x > x0 - pitch * 0.6 && p.x < x0 + w + dx + pitch * 0.6) {
            bloom += tint * glow(p.y - topY, pitch * (1.4 + kick)) * glow(p.x - (x0 + w * 0.5 + dx * 0.5), pitch * 1.1)
                     * heat * (1.0 - fog) * (faux(0.22, 0.4) + faux(kick * 0.7, 0.6));
        }

        // Front face: dark at the foot, emissive toward the top, crisp rim.
        float aF = boxAA(p, vec2(x0, by), vec2(x0 + w, by + h));
        float t = clamp((p.y - by) / h, 0.0, 1.0);
        vec3 front = mix(tint * 0.22, hot, pow(t, 1.5));
        front += lit(smoothstep(h - 2.0, h, p.y - by)) * 0.35;
        // Lit windows: a grid of panes, some on, brighter with the level.
        if (w > 7.0) {
            vec2 wc = vec2((p.x - x0) / w * 3.0, (p.y - by) / (pitch * 0.42));
            vec2 cell = floor(wc), f = fract(wc);
            float on = step(0.55 - v * 0.35 - kick * 0.15, hash(cell + vec2(c * 7.0, hi * 13.0)));
            float pane = step(0.22, f.x) * step(f.x, 0.78) * step(0.25, f.y) * step(f.y, 0.75) * step(cell.x, 2.0);
            front = mix(front, mix(fg.rgb, hot, 0.5) * (0.9 + kick * 0.6), pane * on * (0.25 + 0.55 * v) * smoothstep(1.0, 0.85, t) * dark);
        }

        // Side face (sheared up-right), in shadow but catching the sun.
        float sx = (p.x - (x0 + w)) / dx;
        float yb = by + sx * dy;
        float aS = clamp(min(min(p.x - (x0 + w), x0 + w + dx - p.x), min(p.y - yb, yb + h - p.y)) + 0.5, 0.0, 1.0);
        vec3 side = tint * (0.18 + 0.14 * t) + sunCol * lit(0.10 + kick * 0.15) * t;

        // Top face: the hottest surface.
        float aT = shearAA(p, x0, by + h, w, dx, dy);
        vec3 top = mix(hot, fg.rgb, 0.25 + 0.45 * heat) + lit(kick * 0.15 * heat);

        float fade = mix(1.0, 0.12, fog * fog);
        vec3 face = aF > 0.0 ? front : (aT > 0.0 ? top : side);
        float a = max(aF, max(aT, aS)) * fade;
        if (a > 0.0) {
            face = mix(face, fogCol, fog * 0.8);
            col.rgb += (1.0 - col.a) * a * face;
            col.a += (1.0 - col.a) * a;
            if (col.a > 0.985) break;
        }
    }

    // ---- road grid under the city -------------------------------------------
    if (p.y < horizon && p.y > base * 0.5) {
        float s = 1.0 - (p.y - base) / rise;
        float z = (1.0 / max(s, 0.02) - 1.0) / K;
        float travel = flow * 3.4;
        float cross = abs(fract(z * 0.25 + travel) - 0.5);
        float u = (p.x - (cx - res.x * 0.06 + z * res.x * 0.0045 + roadBend(z) * res.x)) / (W * max(s, 0.02));
        float side = abs(fract(u * 8.0 + 0.5) - 0.5);
        float px = fwidth(z * 0.25) + 1e-4, pu = fwidth(u * 8.0) + 1e-4;
        float lines = max(1.0 - smoothstep(0.0, px * 1.5, cross), 1.0 - smoothstep(0.0, pu * 1.5, side));
        float gfade = smoothstep(horizon, horizon - res.y * 0.10, p.y);
        lines *= gfade * (0.18 + 0.25 * energy + 0.55 * kick) * step(abs(u), 0.5);
        // The sun's reflection runs down the road.
        float sheen = lit(glow(u, 0.16) * gfade * smoothstep(base, horizon, p.y) * (0.10 + 0.25 * swell + 0.3 * kick));
        vec3 gc = mix(c2.rgb, c1.rgb, 0.3 + kick * 0.5);
        col.rgb += (1.0 - col.a) * (lines * gc + sheen * sunCol);
        col.a += (1.0 - col.a) * clamp(lines + sheen, 0.0, 1.0);
    }

    // ---- sky: a sun behind the skyline, shafts through the haze ---------------
    {
        vec2 sc = vec2(vanish, horizon + res.y * 0.02);
        float sd = length(p - sc);
        float sr = res.y * (0.10 + bass * 0.02 + kick * 0.03);
        float above = smoothstep(horizon - res.y * 0.02, horizon + res.y * 0.01, p.y);
        float ang = atan(p.y - sc.y, p.x - sc.x);
        float rays = 0.5 + 0.5 * sin(ang * 9.0 + time * 0.15) * sin(ang * 5.0 - time * 0.11 + 1.3);
        rays = pow(rays, 3.0) * smoothstep(sr, sr * 4.0, sd) * glow(sd, res.y * 0.9);
        float core = glow(sd, sr * 0.55) * above;
        float corona = glow(max(sd - sr * 0.3, 0.0), res.y * (0.13 + swell * 0.05 + kick * 0.05));
        float wide = glow(p.y - horizon, res.y * (0.16 + swell * 0.08));
        // Anamorphic streak through the sun: a thin horizontal flare that stretches on kicks.
        float streak = glow(p.y - sc.y, res.y * (0.006 + kick * 0.006)) * glow(p.x - sc.x, res.x * (0.25 + kick * 0.35));
        float skyL = dark * (faux(corona * (0.35 + energy * 0.3 + kick * 0.35), 0.35) + wide * (0.12 + bass * 0.18 + faux(kick * 0.25, 0.5))
                             + rays * above * (0.10 + 0.25 * swell + kick * 0.4));
        vec3 hotCore = mix(sunCol, vec3(1.0), 0.55);
        vec3 skyRgb = sunCol * skyL + hotCore * (core * (0.9 + faux(kick * 0.5, 0.4)) + streak * faux(0.35 + kick * 0.6, 0.4)) * dark;
        float skyA = clamp(skyL + (core + streak * 0.5) * dark, 0.0, 1.0);
        // Light themes: a soft tinted band at the horizon instead of light.
        float tint = light * glow(p.y - horizon, res.y * 0.20) * (0.10 + kick * 0.08);
        skyRgb += c1.rgb * tint; skyA += tint;
        col.rgb += (1.0 - col.a) * skyRgb;
        col.a += (1.0 - col.a) * clamp(skyA, 0.0, 1.0);
    }

    col.rgb += sat3(bloom) * (1.0 - col.a * 0.5);
    col.a = clamp(col.a + length(bloom) * 0.4, 0.0, 1.0);
    col.rgb *= 1.0 + faux(kick * 0.08, 0.5) * dark;

    // Vignette: corners sink toward shadow so the eye lands on the road.
    vec2 q = qt_TexCoord0 - 0.5;
    float vig = smoothstep(0.35, 0.85, length(q * vec2(1.0, 1.25))) * mix(0.55, 0.15, light);
    col = vec4(col.rgb * (1.0 - vig) + bg.rgb * 0.25 * vig, col.a + (1.0 - col.a) * vig);

    fragColor = vec4(col.rgb + dither(p) * col.a, col.a) * qt_Opacity;
}
