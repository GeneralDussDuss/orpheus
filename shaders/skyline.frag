#version 440
// Orpheus "Skyline": 32 extruded columns on a mirrored floor. Anti-aliased
// faces, emissive tops that bloom, peak caps that float down with a trail,
// a rippling reflection, and a floor grid that rolls toward you and flashes
// on every kick.

//#common

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    p = rotateAround(p, vec2(res.x * 0.5, res.y * 0.3), camRoll() * 0.6);   // a subtle sway
    p.y -= camBob(res.y);
    float n = 32.0;
    float margin = res.x * 0.05;
    float pitch = (res.x - margin * 2.0) / n;
    float w = pitch * 0.58;
    float dx = pitch * 0.32, dy = pitch * 0.22;               // oblique extrusion, up and right
    float base = res.y * 0.30;
    float maxH = res.y * 0.60;

    vec4 col = vec4(0.0);
    vec3 bloom = vec3(0.0);

    // ---- floor: perspective grid rolling toward you -----------------------------
    if (p.y < base) {
        float d = (base - p.y) / base;                       // 0 at the baseline, 1 at the bottom
        float z = 1.0 / max(d, 0.03);
        float travel = flow * 1.8;
        float gz = abs(fract(z * 0.5 - travel) - 0.5);
        float gx = abs(fract((p.x - res.x * 0.5) / (pitch * 2.0) * d * 2.0 + 0.5) - 0.5);
        float lz = 1.0 - smoothstep(0.0, fwidth(z * 0.5) * 1.5 + 1e-4, gz);
        float lx = 1.0 - smoothstep(0.0, fwidth(p.x / (pitch * 2.0) * d * 2.0) * 1.5 + 1e-4, gx);
        float g = max(lz * smoothstep(0.02, 0.35, d), lx) * smoothstep(0.0, 0.2, d) * (1.0 - d * 0.45);
        g *= 0.22 + bass * 0.30 + beat * 0.50;
        col = over(col, mix(c2.rgb, c1.rgb, beat), g);
    }

    for (int i = 0; i < 32; i++) {
        float x0 = margin + float(i) * pitch;
        if (p.x < x0 - pitch || p.x > x0 + pitch * 2.0) continue;   // only nearby columns matter
        float v = bandAt(i);
        float h = max(2.0, v * maxH);
        float pk = peakAt(i) * maxH;
        vec3 tint = pal(float(i) / 31.0);
        float heat = smoothstep(0.35, 1.0, v);
        vec3 hot = mix(tint, vec3(1.0), (0.12 + 0.45 * heat) * (1.0 - light));
        float t = clamp((p.y - base) / h, 0.0, 1.0);

        // Faces, anti-aliased.
        float aF = boxAA(p, vec2(x0, base), vec2(x0 + w, base + h));
        float sx = (p.x - (x0 + w)) / dx;
        float yb = base + sx * dy;
        float aS = clamp(min(min(p.x - (x0 + w), x0 + w + dx - p.x), min(p.y - yb, yb + h - p.y)) + 0.5, 0.0, 1.0);
        float aT = shearAA(p, x0, base + h, w, dx, dy);
        col = over(col, tint * (0.30 + 0.12 * t), aS);
        col = over(col, mix(tint * 0.45, hot, pow(t, 1.3)), aF);
        col = over(col, mix(hot, fg.rgb, 0.2 + 0.45 * heat), aT);

        // Peak cap with a short fading trail above the column.
        if (pk > h + 3.0) {
            float cap = boxAA(p, vec2(x0, base + pk - 1.5), vec2(x0 + w, base + pk + 1.5));
            float trail = boxAA(p, vec2(x0, base + h), vec2(x0 + w, base + pk)) * smoothstep(base + h, base + pk, p.y) * 0.12;
            col = over(col, mix(tint, fg.rgb, 0.5), max(cap * 0.95, lit(trail)));
        }

        // Reflection: the front face mirrored under the floor, rippling, fading out.
        float ry = base - (p.y - base);
        float ripple = sin(p.y * 0.35 + time * 3.0) * (1.0 - p.y / base) * 1.5;
        float aR = boxAA(vec2(p.x + ripple, ry), vec2(x0, base), vec2(x0 + w, base + h * 0.7));
        float rf = smoothstep(base - h * 0.7, base, p.y) * 0.45;
        col = over(col, tint * 0.8, aR * rf * step(p.y, base));

        // Bloom over hot tops.
        bloom += tint * lit(glow(p.y - (base + h + dy * 0.5), pitch * 1.4) * glow(p.x - (x0 + w * 0.5), pitch * 0.9) * heat * (0.5 + beat * 0.6));
    }

    // Soft light above the skyline that swells with the energy.
    float sky = lit(glow(p.y - base, res.y * 0.5) * energy * 0.22);
    col = over(col, c1.rgb, sky * (1.0 - col.a));

    col.rgb += bloom;
    col.a = clamp(col.a + length(bloom) * 0.5, 0.0, 1.0);
    fragColor = vec4(col.rgb * col.a + dither(p) * col.a, col.a) * qt_Opacity;
}
