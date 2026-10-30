#version 440
// Orpheus "Skyline": 32 extruded columns on a glossy stage floor. Behind them,
// fading echoes of the last few seconds stand in rows back into the haze, so
// the stage has depth. Spotlights sweep down through the haze; peak caps float
// down with a trail; the floor mirrors everything and rolls a grid toward you.
// Kicks punch the camera in, fire a shockwave across the floor, flare the
// lights and the tops; snares flicker the spots.

//#common

layout(binding = 1) uniform sampler2D hist;
// The album cover (Viz.qml): alpha 0 when there is none.
layout(binding = 2) uniform sampler2D art;

vec3 sat3(vec3 x) { return x / (1.0 + max(max(x.r, x.g), x.b) * 0.6); }

// A column's hot colour: its tint, washed toward white as it gets loud (dark themes only).
vec3 hotOf(vec3 tint, float heat, float dark) {
    return mix(tint * (1.1 + kick * 0.2 * dark), vec3(1.0), (0.06 + 0.32 * heat + kick * 0.08) * dark);
}

// One extruded column: front, side and top faces composited over `col`.
// x0/base/w/h in pixels, dx/dy the oblique extrusion; `dim` darkens it.
vec4 column(vec4 col, vec2 p, float x0, float base, float w, float h, float dx, float dy,
            vec3 tint, float heat, float dim, float dark) {
    vec3 hot = hotOf(tint, heat, dark);
    float t = clamp((p.y - base) / h, 0.0, 1.0);
    float aF = boxAA(p, vec2(x0, base), vec2(x0 + w, base + h));
    float sx = (p.x - (x0 + w)) / dx;
    float yb = base + sx * dy;
    float aS = clamp(min(min(p.x - (x0 + w), x0 + w + dx - p.x), min(p.y - yb, yb + h - p.y)) + 0.5, 0.0, 1.0);
    float aT = shearAA(p, x0, base + h, w, dx, dy);
    vec3 front = mix(tint * 0.20, hot, pow(t, 1.4));
    // A bright rim up the left edge, like a key light from stage left.
    front += lit(clamp(1.0 - (p.x - x0) / 2.0, 0.0, 1.0) * 0.25 * t);
    col = over(col, mix(tint * (0.18 + 0.14 * t), bg.rgb, dim), aS);
    col = over(col, mix(front, bg.rgb, dim), aF);
    col = over(col, mix(mix(hot, fg.rgb, 0.2 + 0.45 * heat), bg.rgb, dim), aT);
    return col;
}

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float dark = 1.0 - light;

    // ---- camera: push in with the loudness, punch on kicks, sway ---------------
    vec2 focus = vec2(res.x * 0.5, res.y * 0.32);
    float zoom = 1.0 + swell * 0.05 + kick * kick * 0.05;
    float jolt = (hash(vec2(kicks, 1.9)) - 0.5) * 2.0;
    p = focus + (p - focus) / zoom;
    p = rotateAround(p, focus, camRoll() * 0.6 + jolt * kick * kick * 0.02);
    p.y -= camBob(res.y) - kick * res.y * 0.01;

    float n = 32.0;
    float margin = res.x * 0.05;
    float pitch = (res.x - margin * 2.0) / n;
    float w = pitch * 0.58;
    float dx = pitch * 0.32, dy = pitch * 0.22;
    float base = res.y * 0.30;
    float maxH = res.y * 0.60;

    vec4 col = vec4(0.0);
    vec3 bloom = vec3(0.0);

    // ---- the LED wall: the cover, big, at the back of the stage ---------------
    {
        float sz = res.y * 0.42;
        vec2 lo = vec2(res.x * 0.5 - sz * 0.5, base + res.y * 0.17);
        vec2 cu = (p - lo) / sz;
        if (cu.x > 0.0 && cu.x < 1.0 && cu.y > 0.0 && cu.y < 1.0) {
            float pitchL = max(3.0, res.y / 160.0);
            vec2 cell = floor((p - lo) / pitchL);
            vec4 A = texture(art, vec2((cell.x + 0.5) * pitchL / sz, 1.0 - (cell.y + 0.5) * pitchL / sz));
            vec2 f = fract((p - lo) / pitchL) - 0.5;
            float led = smoothstep(0.5, 0.28, length(f));
            float edge = smoothstep(0.0, 0.03, min(min(cu.x, 1.0 - cu.x), min(cu.y, 1.0 - cu.y)));
            float k = A.a * edge * mix(led * (0.50 + 0.20 * swell + 0.25 * kick), 0.5, light);
            col = over(col, A.rgb * mix(1.15, 1.0, light), k);
        }
    }

    // ---- back of the stage: haze glow and sweeping spotlights -----------------
    if (dark > 0.0) {
        float hz = glow(p.y - base * 1.15, res.y * (0.30 + swell * 0.12)) * (0.10 + energy * 0.22 + kick * 0.25);
        col = over(col, mix(c2.rgb, c1.rgb, 0.4), hz * dark);
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            vec2 o = vec2(res.x * (0.1 + fi * 0.2), res.y * 1.08);
            float a = -1.5708 + sin(time * (0.23 + fi * 0.05) + fi * 1.7) * 0.42;
            vec2 dir = vec2(cos(a), sin(a));
            vec2 d = p - o;
            float along = dot(d, dir);
            float perp = abs(d.x * dir.y - d.y * dir.x);
            float cone = glow(perp, 6.0 + along * 0.13) * smoothstep(0.0, res.y * 0.15, along) * smoothstep(res.y * 1.2, res.y * 0.3, along);
            float flick = 1.0 + snap * (hash(vec2(fi, floor(time * 24.0))) - 0.3) * 1.2;
            float beam = cone * (0.07 + swell * 0.12 + kick * 0.22) * flick;
            col = over(col, pal(fi / 4.0), clamp(beam, 0.0, 1.0) * dark);
        }
    }

    // ---- floor: glossy, a grid rolling toward you, a kick shockwave -------------
    if (p.y < base) {
        float d = (base - p.y) / base;                       // 0 at the baseline, 1 at the bottom
        float z = 1.0 / max(d, 0.03);
        float travel = flow * 1.8;
        float gz = abs(fract(z * 0.5 - travel) - 0.5);
        float u = (p.x - res.x * 0.5) / (pitch * 2.0) * z * 0.12;  // world x: screen x times depth
        float gx = abs(fract(u + 0.5) - 0.5);
        float lz = 1.0 - smoothstep(0.0, fwidth(z * 0.5) * 1.5 + 1e-4, gz);
        u = clamp(u, -40.0, 40.0);
        float lx = 1.0 - smoothstep(0.0, fwidth(u) * 1.5 + 1e-4, gx);
        float g = max(lz * smoothstep(0.02, 0.35, d), lx) * smoothstep(0.0, 0.2, d) * (1.0 - d * 0.45);
        g *= 0.16 + bass * 0.22 + kick * 0.45;
        // Shockwave: an ellipse racing out from centre stage as the kick decays.
        vec2 e = vec2((p.x - res.x * 0.5) / res.x, (base - p.y) / base * 0.55);
        float ring = (1.0 - kick) * 0.9 + 0.06;
        float shock = glow(length(e) - ring, 0.012 + ring * 0.03) * kick * (1.0 - d * 0.3);
        // Stage light pooled on the floor in front of the columns.
        float pool = lit(glow((p.x - res.x * 0.5) / res.x, 0.35) * glow(d, 0.35) * (0.10 + swell * 0.25 + kick * 0.3));
        col = over(col, mix(c2.rgb, c1.rgb, kick), clamp(g + pool, 0.0, 1.0));
        col = over(col, mix(c1.rgb, fg.rgb, 0.4), clamp(lit(shock) + shock * light * 0.4, 0.0, 1.0));
    }

    // ---- echoes: the recent past standing in rows behind, fading into haze ------
    for (int e = 2; e >= 0; e--) {
        float fe = float(e);
        float s = 0.78 - fe * 0.12;                          // nearest echo is largest
        float eb = base + res.y * (0.07 + fe * 0.055);
        float ep = pitch * s;
        float exl = res.x * 0.5 - ep * n * 0.5 + res.x * 0.02 * (fe + 1.0);
        float c = floor((p.x - exl) / ep);
        float row = 6.0 + fe * 9.0;                          // frames back in the history
        float dim = 0.68 + fe * 0.10;
        for (int k = 0; k < 2; k++) {                        // this column and the one to its left (side faces)
            float ci = c - float(k);
            if (ci < 0.0 || ci >= n) continue;
            float v = texture(hist, vec2((ci + 0.5) / n, (row + 0.5) / 40.0)).r;
            float h = max(1.5, v * maxH * s * 0.9);
            col = column(col, p, exl + ci * ep, eb, w * s, h, dx * s, dy * s, pal(ci / 31.0), 0.0, mix(dim, 1.0, light * 0.3), dark);
        }
    }

    // ---- the columns ------------------------------------------------------------
    for (int i = 0; i < 32; i++) {
        float x0 = margin + float(i) * pitch;
        if (p.x < x0 - pitch * 1.5 || p.x > x0 + pitch * 2.5) continue;
        float v = bandAt(i);
        float vv = pow(v, 1.2) * (1.0 + kick * 0.10);
        float h = max(2.0, vv * maxH);
        float pk = peakAt(i) * maxH;
        vec3 tint = pal(float(i) / 31.0);
        float heat = smoothstep(0.3, 0.95, v);

        col = column(col, p, x0, base, w, h, dx, dy, tint, heat, 0.0, dark);

        // Peak cap with a fading trail; snares make the caps flare.
        if (pk > h + 3.0) {
            float cap = boxAA(p, vec2(x0, base + pk - 1.5), vec2(x0 + w, base + pk + 1.5));
            float trail = boxAA(p, vec2(x0, base + h), vec2(x0 + w, base + pk)) * smoothstep(base + h, base + pk, p.y) * 0.16;
            col = over(col, mix(tint, fg.rgb, 0.5 + snap * 0.3), max(cap * 0.95, lit(trail)));
            bloom += tint * lit(glow(p.y - (base + pk), 3.0 + snap * 4.0) * glow(p.x - (x0 + w * 0.5), w) * faux(0.2 + snap * 0.6, 0.4));
        }

        // Reflection: the column mirrored under the floor, rippling, fading out.
        if (p.y < base) {
            float ry = base - (p.y - base);
            float ripple = sin(p.y * 0.35 + time * 3.0) * (1.0 - p.y / base) * (1.5 + kick * 1.2);
            float aR = boxAA(vec2(p.x + ripple, ry), vec2(x0, base), vec2(x0 + w, base + h * 0.8));
            float rf = smoothstep(base - h * 0.8, base, p.y) * mix(0.50, 0.30, light);
            col = over(col, mix(tint * 0.9, hotOf(tint, heat, dark), smoothstep(base - h * 0.3, base - h * 0.8, p.y) * heat), aR * rf);
            if (heat > 0.0)
                bloom += tint * lit(glow(p.y - (base - h), pitch * 1.2) * glow(p.x - (x0 + w * 0.5), pitch * 0.8) * heat * faux(0.25, 0.4));
        }

        // Bloom over hot tops, swelling on kicks.
        // (heat is 0 for the quieter columns: they skip the two exps.)
        if (heat > 0.0)
            bloom += tint * lit(glow(p.y - (base + h + dy * 0.5), pitch * (1.3 + kick)) * glow(p.x - (x0 + w * 0.5), pitch * 0.9)
                     * heat * (faux(0.35, 0.4) + faux(kick * 0.8, 0.6)));
    }

    col.rgb = col.rgb * col.a;                               // to premultiplied
    col.rgb += sat3(bloom);
    col.a = clamp(col.a + length(bloom) * 0.5, 0.0, 1.0);

    // Vignette: the stage edges fall into shadow.
    vec2 q = qt_TexCoord0 - 0.5;
    float vig = smoothstep(0.35, 0.85, length(q * vec2(1.0, 1.3))) * mix(0.55, 0.15, light);
    col = vec4(col.rgb * (1.0 - vig) + bg.rgb * 0.25 * vig, col.a + (1.0 - col.a) * vig);

    fragColor = vec4(col.rgb + dither(p) * col.a, col.a) * qt_Opacity;
}
