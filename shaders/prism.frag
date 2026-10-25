#version 440
// Orpheus "Prism": the spectrum as a 2.5D city driving toward you, seen from a
// three-quarter angle. New sound rises at the horizon and rolls closer every
// frame, forever, along a road that winds left and right; the camera banks and
// bobs. A synthwave grid scrolls underneath. Faces are anti-aliased and
// composited front-to-back, hot tops bloom, kicks flare the horizon.

//#common

layout(binding = 1) uniform sampler2D hist;

const int R = 40;            // rows of history (matches the 32x40 history target)
const float N = 32.0;
const float K = 0.045;       // perspective: row r is scaled 1 / (1 + r*K)

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    p = rotateAround(p, vec2(res.x * 0.5, res.y * 0.35), camRoll());   // the camera banks
    float W = res.x * 0.94;
    float cx = res.x * 0.5;
    float base = res.y * (0.04 + beat * 0.012) + camBob(res.y);   // kick lifts, the camera bobs
    float maxH = res.y * 0.50;
    float rise = res.y * 1.15;
    float horizon = base + rise * (1.0 - 1.0 / (1.0 + float(R) * K));

    vec4 col = vec4(0.0);
    vec3 bloom = vec3(0.0);

    for (int r = 0; r < R; r++) {                            // r = 0 is the row nearest you
        float fr = float(r);
        float s = 1.0 / (1.0 + fr * K);
        float by = base + (1.0 - s) * rise;
        float rowW = W * s;
        // Three-quarter view (rows drift right with depth) plus the winding road.
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
        float h = max(1.0, v * maxH * s);
        float fog = smoothstep(float(R) * 0.15, float(R - 1), fr);
        vec3 tint = pal(c / 31.0);
        float heat = smoothstep(0.35, 1.0, v);
        vec3 hot = mix(tint, vec3(1.0), (0.12 + 0.45 * heat) * (1.0 - light));

        // Bloom above hot tops, strongest close to you.
        float topY = by + h + dy * 0.5;
        if (p.x > x0 - pitch * 0.4 && p.x < x0 + w + dx + pitch * 0.4) {
            bloom += tint * lit(glow(p.y - topY, pitch * 1.6) * glow(p.x - (x0 + w * 0.5 + dx * 0.5), pitch * 1.1)
                     * heat * (1.0 - fog) * (0.55 + beat * 0.6));
        }

        // Front face: dark at the foot, emissive toward the top, crisp rim.
        float aF = boxAA(p, vec2(x0, by), vec2(x0 + w, by + h));
        float t = clamp((p.y - by) / h, 0.0, 1.0);
        vec3 front = mix(tint * 0.45, hot, pow(t, 1.4));
        front += lit(smoothstep(h - 2.0, h, p.y - by)) * 0.25;

        // Side face (sheared up-right), in shadow.
        float sx = (p.x - (x0 + w)) / dx;
        float yb = by + sx * dy;
        float aS = clamp(min(min(p.x - (x0 + w), x0 + w + dx - p.x), min(p.y - yb, yb + h - p.y)) + 0.5, 0.0, 1.0);
        vec3 side = tint * (0.30 + 0.12 * t);

        // Top face: the hottest surface.
        float aT = shearAA(p, x0, by + h, w, dx, dy);
        vec3 top = mix(hot, fg.rgb, 0.20 + 0.45 * heat);

        float fade = mix(1.0, 0.16, fog * fog);
        vec3 face = aF > 0.0 ? front : (aT > 0.0 ? top : side);
        float a = max(aF, max(aT, aS)) * fade;
        if (a > 0.0) {
            face = mix(face, bg.rgb, fog * 0.88);
            col.rgb += (1.0 - col.a) * a * face;
            col.a += (1.0 - col.a) * a;
            if (col.a > 0.985) break;
        }
    }

    // Road grid under the city: cross lines roll toward you, side lines run to
    // the vanishing point. Speed follows the energy.
    if (p.y < horizon && p.y > base * 0.5) {
        float s = 1.0 - (p.y - base) / rise;                 // invert the row scale at this height
        float z = (1.0 / max(s, 0.02) - 1.0) / K;            // depth in rows
        float travel = flow * 3.4;
        float cross = abs(fract(z * 0.25 + travel) - 0.5);
        float u = (p.x - (cx - res.x * 0.06 + z * res.x * 0.0045 + roadBend(z) * res.x)) / (W * max(s, 0.02));
        float side = abs(fract(u * 8.0 + 0.5) - 0.5);
        float px = fwidth(z * 0.25) + 1e-4, pu = fwidth(u * 8.0) + 1e-4;
        float lines = max(1.0 - smoothstep(0.0, px * 1.5, cross), 1.0 - smoothstep(0.0, pu * 1.5, side));
        lines *= smoothstep(horizon, horizon - res.y * 0.08, p.y) * (0.16 + 0.22 * energy + 0.25 * beat);
        lines *= step(abs(u), 0.5);
        col.rgb += (1.0 - col.a) * lines * mix(c2.rgb, c1.rgb, 0.3);
        col.a += (1.0 - col.a) * lines;
    }

    // Horizon haze: swells with the bass, flares on kicks (none on light themes).
    float haze = lit(glow(p.y - horizon, res.y * 0.14) * (0.12 + bass * 0.30 + beat * 0.40));
    col.rgb += (1.0 - col.a) * haze * mix(c2.rgb, c1.rgb, beat);
    col.a += (1.0 - col.a) * haze;

    col.rgb += bloom * (1.0 - col.a * 0.6);
    col.a = clamp(col.a + length(bloom) * 0.5, 0.0, 1.0);
    fragColor = vec4(col.rgb + dither(p) * col.a, col.a) * qt_Opacity;
}
