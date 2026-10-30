#version 440
// Orpheus "Orb": a lit sphere hanging over a glossy stage floor, its outline
// pushed out by the spectrum. Inside, a plasma core swirls and burns hotter
// with the loudness; a fresnel rim wraps it. God rays stream out where the
// spectrum is loud, dust drifts outward, tilted rings orbit carrying beads
// with trails. Kicks punch the camera in, fire a shockwave and spike the
// outline; snares send a thinner ring out.

//#common

// The album cover (Viz.qml): alpha 0 when there is none.
layout(binding = 1) uniform sampler2D art;

vec3 sat3(vec3 x) { return x / (1.0 + max(max(x.r, x.g), x.b) * 0.6); }

float swirl(vec2 q, float t) {
    float a = 0.0;
    vec2 z = q;
    for (int i = 0; i < 4; i++) {
        float c = cos(t * 0.2 + float(i)), s = sin(t * 0.2 + float(i));
        z = vec2(z.x * c - z.y * s, z.x * s + z.y * c) * 1.7;
        a += sin(z.x * 3.0 + t) * cos(z.y * 3.0 - t * 0.7) / float(i + 1);
    }
    return a * 0.5 + 0.5;
}

void main() {
    vec2 uv = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y);
    vec2 p = (uv - 0.5) * res;
    float dark = 1.0 - light;
    float S = min(res.x, res.y);

    // ---- camera -----------------------------------------------------------------
    float zoom = 1.0 + swell * 0.05 + kick * kick * 0.06;
    float jolt = (hash(vec2(kicks, 8.1)) - 0.5) * 2.0;
    p /= zoom;
    p -= vec2(sin(time * 0.21), sin(time * 0.42) * 0.5) * S * 0.035;     // a slow figure-eight
    p = rotateAround(p, vec2(0.0), camRoll() + jolt * kick * kick * 0.04);
    p.y -= S * 0.04;                                         // lift the orb above the floor
    vec2 q = p / S;
    float px = 1.0 / (S * zoom);                             // one screen pixel in q units
    float r = length(q);
    float ang = atan(q.y, q.x);
    float mirrored = abs(ang) / 3.14159265;

    float r0 = 0.18 + bass * 0.035 + kick * 0.02;
    // The outline: smooth swell from neighbouring bands plus a sharper spike layer that kicks drive.
    float lv = (band(mirrored - 0.03) + band(mirrored) * 2.0 + band(mirrored + 0.03)) * 0.25;
    float spikes = max(band(mirrored) - lv, 0.0) * (0.10 + kick * 0.16);
    float rim = r0 + lv * 0.10 + spikes + 0.004 * sin(ang * 12.0 + time * 2.0);

    vec4 col = vec4(0.0);
    vec3 add = vec3(0.0);                                    // additive light, dark themes only

    // ---- stage floor: a glossy plane far below, catching the orb's light ----------
    float floorY = -0.36;
    if (q.y < floorY + 0.02) {
        float d = clamp((floorY - q.y) / 0.5, 0.0, 1.0);    // 0 at the horizon line, 1 at the bottom
        float z = 1.0 / max(d, 0.02);
        float gz = abs(fract(z * 0.35 - flow * 0.8) - 0.5);
        float gx = abs(fract(q.x * z * 1.6 + 0.5) - 0.5);
        // Lines fade out where they get finer than a pixel, instead of filling in.
        float fz = fwidth(z * 0.35) + 1e-4, fxw = fwidth(q.x * z * 1.6) + 1e-4;
        float lines = max((1.0 - smoothstep(0.0, fz * 1.5, gz)) * (1.0 - smoothstep(0.15, 0.4, fz)),
                          (1.0 - smoothstep(0.0, fxw * 1.5, gx)) * (1.0 - smoothstep(0.15, 0.4, fxw)));
        lines *= smoothstep(0.0, 0.25, d) * (1.0 - d * 0.5) * (0.20 + bass * 0.15 + kick * 0.35);
        col = over(col, mix(c2.rgb, c1.rgb, 0.5), lines * step(q.y, floorY));
        // The orb's reflection: a soft pool of light right under it.
        float pool = glow(length((q - vec2(0.0, floorY - 0.06)) * vec2(1.0, 3.5)), 0.16 + energy * 0.06) * smoothstep(floorY, floorY - 0.03, q.y);
        add += pal(0.4) * pool * (0.25 + energy * 0.35 + kick * 0.35);
    }

    // ---- space around it: haze, god rays, drifting dust ------------------------------
    float rr = max(r - rim, 0.0);
    add += mix(c2.rgb, c1.rgb, 0.5) * glow(rr, 0.35 + swell * 0.15) * (0.10 + energy * 0.15 + kick * 0.15);
    {
        float a = ang + time * 0.03;
        float streak = pow(0.5 + 0.5 * sin(a * 23.0 + sin(a * 7.0 + time * 0.4) * 2.0), 6.0)
                     + pow(0.5 + 0.5 * sin(a * 41.0 - time * 0.3), 10.0) * 0.6;
        float rays = streak * (lv * 1.2 + kick * 0.5) * exp(-rr * (4.0 - swell * 1.5)) * smoothstep(0.0, 0.02, rr);
        add += pal(mirrored) * rays * 0.45;
    }
    {
        // Dust: motes on a polar grid, flowing outward with the music's pace.
        float lr = log(max(r, 1e-3)) * 6.0 - flow * 1.2;
        vec2 cell = vec2(floor(lr), floor((ang + 3.1416) * 9.0));
        vec2 f = vec2(fract(lr), fract((ang + 3.1416) * 9.0));
        vec2 at = vec2(hash(cell), hash(cell + 2.3));
        float mote = step(0.6, hash(cell + 9.1)) * glow(length((f - at) * vec2(1.0, 0.6)), 0.06) * smoothstep(0.0, 0.05, rr);
        add += mix(fg.rgb, c3.rgb, 0.5) * mote * (0.25 + energy * 0.5 + snap * 0.6) * exp(-rr * 2.0);
    }

    // Shockwaves: a fat one on kicks, a thin one on snares.
    float wave = rim + (1.0 - kick) * 0.42;
    float aW = glow(r - wave, px * (2.0 + 6.0 * kick)) * kick * kick;
    add += mix(c1.rgb, fg.rgb, 0.3) * aW * faux(1.2, 0.35);
    col = over(col, mix(c1.rgb, fg.rgb, 0.2), glow(r - wave, px * 1.5) * kick * kick * light * 0.7);
    float wave2 = rim + (1.0 - snap) * 0.30;
    add += c3.rgb * glow(r - wave2, px * 1.5) * snap * snap * 0.8;

    // ---- rings (back halves), the sphere, rings (front halves) -----------------------
    for (int pass = 0; pass < 2; pass++) {
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float tilt = 0.28 + fk * 0.14;
            float spin = time * (0.15 + fk * 0.07) * (k == 1 ? -1.0 : 1.0) + fk * 2.1;
            vec2 rq = mat2(cos(spin), -sin(spin), sin(spin), cos(spin)) * q;
            bool back = rq.y > 0.0;
            if ((pass == 0) != back) continue;
            if (pass == 0 && r < rim) continue;              // hidden behind the orb
            float R = (0.36 + fk * 0.055) * (1.0 + kick * 0.04);
            vec2 e = vec2(rq.x, rq.y / tilt);
            float d = abs(length(e) - R) * tilt;             // approx. distance to the ellipse
            float line = clamp(1.0 - d / (px * 1.3), 0.0, 1.0);
            float ea = atan(e.y, e.x);
            float lvl = band(abs(ea) / 3.14159265);           // mirrored, so it has no seam
            vec3 rc = pal(0.2 + fk * 0.35);
            float a = line * (back ? 0.35 : 0.85) * (0.35 + lvl * 1.3);
            add += rc * glow(d, px * (3.0 + lvl * 5.0)) * faux(0.15 + lvl * 0.5 + kick * 0.3, 0.4) * (back ? 0.4 : 1.0);
            // Beads riding the ring, each dragging a fading trail behind it.
            float bead = 0.0;
            for (int b = 0; b < 3; b++) {
                float speed = 0.9 + fk * 0.3;
                float ba = time * speed + float(b) * 2.094 + fk;
                vec2 bp = vec2(cos(ba), sin(ba)) * R;
                bead += glow(length(e - bp) * S, 2.5 + lvl * 3.0 + kick * 3.0);
                float behind = mod(ba - ea, 6.2831853);        // angle the bead has travelled past this point
                bead += glow(d * S, 1.5) * exp(-behind * 4.0) * step(behind, 1.2) * 0.6;
            }
            col = over(col, rc, clamp(a + lit(bead) * (back ? 0.4 : 1.0), 0.0, 1.0));
        }
        if (pass == 0) {
            float aO = clamp((rim - r) / px + 0.5, 0.0, 1.0);
            if (aO > 0.0) {
                float z = sqrt(max(0.0, 1.0 - pow(min(r / rim, 1.0), 2.0)));
                vec3 n = normalize(vec3(q / rim, z));
                vec3 L = normalize(vec3(-0.5, 0.6, 0.8));
                float diff = max(dot(n, L), 0.0);
                float spec = pow(max(dot(reflect(-L, n), vec3(0, 0, 1)), 0.0), 32.0);
                float fres = pow(1.0 - z, 2.2);
                float sw = swirl(q / rim, time * (0.6 + energy * 1.2));
                vec3 body = mix(bg.rgb, pal(mirrored * 0.6 + 0.2 + sw * 0.15), 0.22 + diff * 0.45 + sw * 0.15);
                // The cover, refracted through the glass: magnified in the middle,
                // bent toward the rim, stirred by the plasma.
                {
                    vec2 ru = n.xy * (0.36 + 0.14 * (1.0 - z)) + (sw - 0.5) * 0.04 * vec2(cos(time * 0.7), sin(time * 0.5));
                    vec4 A = texture(art, vec2(0.5 + ru.x, 0.5 - ru.y));
                    float k = A.a * (0.62 - 0.45 * fres) * (1.0 - 0.25 * light);
                    body = mix(body, A.rgb * (0.55 + 0.5 * diff) + pal(mirrored) * 0.08, k);
                }
                // Plasma core: hot light from inside, brighter with the loudness and on kicks.
                float core = pow(z, 2.0) * smoothstep(0.45, 0.95, sw) * (0.12 + energy * 0.45 + kick * 0.25);
                body += lit(core) * mix(c2.rgb, fg.rgb, 0.4);
                body += c3.rgb * lit(fres * (0.40 + energy * 0.45 + kick * 0.35)) + vec3(lit(spec) * 0.40);
                body = mix(body, body * 0.85 + pal(mirrored) * 0.15, light * fres);
                col = over(col, body, aO);
            }
        }
    }
    // Outer halo hugging the outline.
    add += pal(mirrored) * glow(rr, 0.05 + lv * 0.04) * faux(0.30 + energy * 0.3 + kick * 0.25, 0.4) * step(rim, r);

    col.rgb = col.rgb * col.a;                               // to premultiplied
    vec3 L = sat3(add) * dark;
    col.rgb += L;
    col.a = clamp(col.a + max(max(L.r, L.g), L.b), 0.0, 1.0);

    // Vignette.
    vec2 vq = qt_TexCoord0 - 0.5;
    float vig = smoothstep(0.35, 0.85, length(vq * vec2(1.0, 1.3))) * mix(0.55, 0.15, light);
    col = vec4(col.rgb * (1.0 - vig) + bg.rgb * 0.25 * vig, col.a + (1.0 - col.a) * vig);

    fragColor = vec4(col.rgb + dither(p) * col.a, col.a) * qt_Opacity;
}
