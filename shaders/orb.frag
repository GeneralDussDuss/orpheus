#version 440
// Orpheus "Orb": a lit sphere whose outline is pushed out by the spectrum,
// with a slowly swirling surface and a fresnel rim. Tilted rings orbit it
// carrying particles, and every kick fires a shockwave ring outward.

//#common

float swirl(vec2 q, float t) {
    float a = 0.0;
    vec2 z = q;
    for (int i = 0; i < 4; i++) {
        z = vec2(z.x * cos(t * 0.2 + float(i)) - z.y * sin(t * 0.2 + float(i)),
                 z.x * sin(t * 0.2 + float(i)) + z.y * cos(t * 0.2 + float(i))) * 1.7;
        a += sin(z.x * 3.0 + t) * cos(z.y * 3.0 - t * 0.7) / float(i + 1);
    }
    return a * 0.5 + 0.5;
}

void main() {
    vec2 p = (vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) - 0.5) * res;
    // The orb drifts on a slow figure-eight and leans with the camera.
    p -= vec2(sin(time * 0.21), sin(time * 0.42) * 0.5) * min(res.x, res.y) * 0.035;
    p = rotateAround(p, vec2(0.0), camRoll());
    float S = min(res.x, res.y);
    vec2 q = p / S;
    float px = 1.0 / S;                                      // one pixel in q units
    float r = length(q);
    float ang = atan(q.y, q.x);
    float mirrored = abs(ang) / 3.14159265;

    float r0 = 0.19 + bass * 0.035 + beat * 0.015;
    // Smooth the outline: average neighbouring bands so it swells instead of spiking.
    float lv = (band(mirrored - 0.03) + band(mirrored) * 2.0 + band(mirrored + 0.03)) * 0.25;
    float rim = r0 + lv * 0.11 + 0.004 * sin(ang * 12.0 + time * 2.0);

    vec4 col = vec4(0.0);

    // Halo.
    float halo = lit(glow(max(r - rim, 0.0), 0.11) * (0.22 + energy * 0.45 + beat * 0.3));
    col = over(col, pal(mirrored), halo * 0.85);

    // Kick shockwave: a thin ring that expands as the beat decays.
    float wave = rim + (1.0 - beat) * 0.32;
    float aW = clamp(1.0 - abs(r - wave) / (px * 2.0), 0.0, 1.0) * beat * beat;
    col = over(col, mix(c1.rgb, fg.rgb, 0.3), lit(aW) + aW * light * 0.5);

    // Rings: back halves first (behind the orb), particles riding them.
    for (int pass = 0; pass < 2; pass++) {
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float tilt = 0.28 + fk * 0.14;
            float spin = time * (0.15 + fk * 0.07) * (k == 1 ? -1.0 : 1.0) + fk * 2.1;
            vec2 rq = mat2(cos(spin), -sin(spin), sin(spin), cos(spin)) * q;
            bool back = rq.y > 0.0;
            if ((pass == 0) != back) continue;
            if (pass == 1 && r > rim) {}                    // front halves always draw
            if (pass == 0 && r < rim) continue;              // hidden behind the orb
            float R = 0.36 + fk * 0.055;
            vec2 e = vec2(rq.x, rq.y / tilt);
            float d = abs(length(e) - R) * tilt;             // approx. distance to the ellipse
            float line = clamp(1.0 - d / (px * 1.2), 0.0, 1.0);
            float ea = atan(e.y, e.x);
            float lvl = band(fract(ea / 6.2831853 + 0.5));
            vec3 rc = pal(0.2 + fk * 0.35);
            float a = line * (back ? 0.35 : 0.8) * (0.35 + lvl * 1.3);
            // Particles: bright beads travelling along the ring.
            float bead = 0.0;
            for (int b = 0; b < 3; b++) {
                float ba = time * (0.9 + fk * 0.3) + float(b) * 2.094 + fk;
                vec2 bp = vec2(cos(ba), sin(ba)) * R;
                bead += glow(length(e - bp) * S, 2.5 + lvl * 3.0);
            }
            col = over(col, rc, clamp(a + lit(bead) * (back ? 0.4 : 1.0), 0.0, 1.0));
        }
        // Between passes: the sphere itself.
        if (pass == 0) {
            float aO = clamp((rim - r) / px + 0.5, 0.0, 1.0);
            if (aO > 0.0) {
                float z = sqrt(max(0.0, 1.0 - pow(min(r / rim, 1.0), 2.0)));
                vec3 n = normalize(vec3(q / rim, z));
                vec3 L = normalize(vec3(-0.5, 0.6, 0.8));
                float diff = max(dot(n, L), 0.0);
                float spec = pow(max(dot(reflect(-L, n), vec3(0, 0, 1)), 0.0), 28.0);
                float fres = pow(1.0 - z, 2.4);
                float sw = swirl(q / rim, time * (0.6 + energy));
                vec3 body = mix(bg.rgb, pal(mirrored * 0.6 + 0.2 + sw * 0.15), 0.22 + diff * 0.5 + sw * 0.12);
                body += c3.rgb * lit(fres * (0.35 + energy * 0.5 + beat * 0.5)) + vec3(lit(spec) * 0.3);
                col = over(col, body, aO);
            }
        }
    }

    fragColor = vec4(col.rgb * col.a + dither(p) * col.a, col.a) * qt_Opacity;
}
