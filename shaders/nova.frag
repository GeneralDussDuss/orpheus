#version 440
// Orpheus "Nova": a starburst. Six layers of stars stream out of the centre
// toward you, faster with the tempo; every kick stretches them into light
// streaks and fires a shockwave. The burst is coloured by direction: the
// spectrum is mirrored around the circle (bass below, treble above), so loud
// bands light their side of the sky brighter and a spectral corona blooms
// out of the core in the same shape.

//#common

const float PI = 3.14159265;
const int L = 6;

vec2 hash2(vec2 q) { return vec2(hash(q), hash(q + vec2(19.19, 7.13))); }

void main() {
    float m = min(res.x, res.y);
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 p = (px - res * 0.5 - vec2(0.0, camBob(res.y))) / m;      // centred, short side = 1
    p = rotateAround(p, vec2(0.0), camRoll() + time * 0.015);
    float r = length(p) + 1e-4;
    vec2 dir = p / r;

    float u = abs(atan(p.x, -p.y)) / PI;                    // 0 = straight down (bass), 1 = up (treble)
    float lvl = band(u);
    vec3 tint = pal(u);

    vec4 col = vec4(0.0);    // premultiplied

    // Spectral corona: a soft flower whose petals are the bands.
    float cr = 0.05 + lvl * 0.20 + bass * 0.03;
    float corona = lit(exp(-pow(r / cr, 2.0)) * (0.25 + lvl * 0.6 + beat * 0.3));
    float rim = lit(glow(r - cr, 0.006 + lvl * 0.01)) * (0.25 + lvl * 0.7);
    col.rgb += corona * tint + rim * mix(tint, fg.rgb, 0.3);
    col.a += corona * 0.6 + rim * 0.5;

    // Stars: each layer is a grid of cells scaled down as it approaches, so its
    // stars slide outward from the centre and grow; the layers are staggered in depth.
    float stretch = 1.0 + energy * 4.0 + beat * 14.0;
    float bright = 0.35 + lvl * 1.6;
    for (int i = 0; i < L; i++) {
        float fi = float(i);
        float z = fract(flow * 0.22 + fi / float(L));       // 0 = far, 1 = passing you
        float scale = mix(16.0, 1.4, z);
        vec2 uv = p * scale + vec2(fi * 17.31, fi * 5.77);
        vec2 id = floor(uv);
        vec2 h = hash2(id + fi * 3.1);
        if (h.x < 0.30) continue;                            // empty cell
        vec2 s = (h - 0.5) * 0.40;
        vec2 d = fract(uv) - 0.5 - s;
        // Split into radial / tangential parts and stretch the tail back toward the centre.
        float dr = dot(d, dir);
        float dt = length(d - dr * dir);
        float sizeUv = mix(0.6, 3.2, z * z) / m * scale;    // star radius in cell units
        float tail = max(1.0, min(stretch * z, 0.18 / max(sizeUv, 1e-4)));
        float drE = dr < 0.0 ? dr / tail : dr;
        float dist = length(vec2(drE, dt)) / sizeUv;         // 1 = star edge
        float fade = smoothstep(0.0, 0.25, z) * smoothstep(1.0, 0.82, z);
        float star = clamp(1.6 - dist, 0.0, 1.0) * fade;
        float flare = lit(glow(dist, 3.0)) * fade * 0.35 * z;
        vec3 sc = mix(tint, fg.rgb, 0.35 + 0.4 * (1.0 - light) * h.y);
        float a = clamp(star * bright, 0.0, 1.0);
        col.rgb += (1.0 - col.a) * a * sc + flare * bright * tint;
        col.a += (1.0 - col.a) * a + flare * 0.3;
    }

    // Kick shockwave: expands as the beat decays.
    float sw = 0.08 + (1.0 - beat) * 0.55;
    float swA = lit(glow(r - sw, 0.006 + (1.0 - beat) * 0.03) * beat * (0.4 + bass * 0.5));
    col.rgb += swA * mix(c2.rgb, fg.rgb, 0.25);
    col.a += swA * 0.5;

    // White-hot core.
    float core = lit(glow(r, 0.02 + bass * 0.02) * (0.4 + beat * 0.8));
    col.rgb += core * mix(c1.rgb, fg.rgb, 0.5);
    col.a += core * 0.7;

    col.a = clamp(col.a, 0.0, 1.0);
    fragColor = vec4(col.rgb + dither(px) * col.a, col.a) * qt_Opacity;
}
