#version 440
// Orpheus "Abyss": a dive through a living cathedral. The stone is a
// kaleidoscopic sponge: every level carves a cross of square-arched halls
// through the one above it at a third of its size, and between levels the
// space is mirror-folded and turned, so the halls nest into vaults, piers,
// ribs and tracery. The camera rides the great nave (the first level's hall,
// which no finer level can fill), bent along a slow winding path, with the
// music's travel. Distance fog swallows the far end into a lantern glow.
// The beat grid sways the camera (bar and beat); the build narrows the halls
// and twists the folds and widens the lens; a drop flips the folds into a new
// architecture under a flash and lets it settle back as the drop fades. Kicks
// light the creases between levels and send rings of light running down the
// nave. Bass, mids and highs breathe the halls, so the stone listens.
// Section shifts how the palette is laid over the levels. Light themes: pale
// fog, dark stone, no neon.
// Cost: <= 80 march steps of a 4-level DE (no sqrt in the loop), 4 taps for the normal.

//#common

const float PI = 3.14159265;
const int STEPS = 80;
const int LEVELS = 4;
const float TMAX = 18.0;
const float WS = 0.5;        // sponge units per world unit: the nave is 2/3 sponge units wide
const float SPEED = 1.8;     // world units per unit of flow

// Fold parameters, set once per frame in main().
mat2 gTw, gTw2;
float gHole, gFold;
vec3 gRo;          // camera, for level of detail
float gPix;        // one pixel's width per unit distance

mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }

vec2 path(float z) {
    return vec2(sin(z * 0.13) * 1.1 + sin(z * 0.051 + 1.3) * 0.8,
                sin(z * 0.087 + 0.4) * 0.55 + cos(z * 0.039) * 0.45);
}

vec3 toSponge(vec3 p) {
    vec3 q = p;
    q.xy -= path(p.z);
    return q * WS;
}

// One level of the sponge: how far this level's halls carve (positive = air)
// at q, already turned and folded for this level.
float level(vec3 q, float s, float lod) {
    if (s < 1.5) q.xy = vec2(q.x + q.y, q.y - q.x) * 0.70710678;   // the great halls stand on a corner: pointed vaults
    vec3 a = mod(q * s, 2.0) - 1.0;
    vec3 r = abs(1.0 - 3.0 * abs(a));
    float m = min(max(r.x, r.y), min(max(r.y, r.z), max(r.z, r.x)));
    return (m - gHole - lod) / (s * 3.0);
}

// Level of detail: a level whose halls would be under ~3 px here closes up
// smoothly instead of shimmering (and costs the march fewer steps).
float lodAt(vec3 p, float s) {
    float px = 2.0 / (3.0 * s * WS) / max(length(p - gRo) * gPix, 1e-5);
    return 1.2 * (1.0 - smoothstep(2.0, 5.0, px));
}

// Next level's space: mirror-fold and turn (about the nave's axis, so the nave stays clear).
vec3 twist(vec3 q, int i) {
    q.xy = gTw * mix(q.xy, abs(q.xy), gFold);
    if (i == 1) q.xz = gTw2 * q.xz;
    return q;
}

float map(vec3 p) {
    vec3 q = toSponge(p);
    float d = -1e3, s = 1.0;
    for (int i = 0; i < LEVELS; i++) {
        d = max(d, level(q, s, i < 2 ? 0.0 : lodAt(p, s)));
        s *= 3.0;
        q = twist(q, i);
    }
    return d / WS;
}

// The same, for shading: which level shaped this surface, and how sharp the
// crease between the two levels meeting here is (0 = right on the edge).
float mapInfo(vec3 p, out float lvl, out float crease) {
    vec3 q = toSponge(p);
    float d = -1e3, d2 = -1e3, s = 1.0;
    lvl = 0.0;
    for (int i = 0; i < LEVELS; i++) {
        float c = level(q, s, i < 2 ? 0.0 : lodAt(p, s));
        if (c > d) { d2 = d; d = c; lvl = float(i); }
        else d2 = max(d2, c);
        s *= 3.0;
        q = twist(q, i);
    }
    crease = (d - d2) / WS;
    return d / WS;
}

vec3 sat3(vec3 x) { return x / (1.0 + max(max(x.r, x.g), x.b) * 0.5); }

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float m = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / m;
    float dark = 1.0 - light;
    float hit = max(kick, beat * 0.8);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));
    float conf = clamp(beatConfidence, 0.0, 1.0);

    // ---- the folds: slow morph, build tightens, drop flips, bands breathe -----
    float bLo = band(0.06), bMid = band(0.42), bHi = band(0.8);
    float dropF = smoothstep(0.0, 0.85, drop);              // 1 at the drop, settles back as it fades
    float tw = 0.10 * sin(time * 0.037) + 0.06 * sin(time * 0.013 + 2.0) + bMid * 0.04 + build * 0.22;
    tw = mix(tw, 0.62 - tw, dropF);                         // a new architecture on the drop
    gTw = rot(tw);
    gTw2 = rot(dropF * 0.45 + 0.05 * sin(time * 0.029));
    gFold = clamp(0.5 + 0.5 * sin(time * 0.019) + dropF, 0.0, 1.0);
    gHole = 1.0 + build * 0.14 - bLo * 0.06 + dropF * 0.10;   // narrower halls as the tension rises

    // ---- camera: ride the nave, sway on the beat grid --------------------------
    float zc = flow * SPEED + build * 0.6;
    vec3 ro = vec3(path(zc), zc);
    vec2 sway = vec2(sin(barPhase * 2.0 * PI) * 0.07, cos(beatPhase * 2.0 * PI) * 0.02) * conf * (0.5 + 0.5 * loud);
    sway += vec2(sin(time * 0.21) * 0.06, sin(time * 0.17 + 1.1) * 0.04);
    ro.xy += sway;
    vec3 ta = vec3(path(zc + 2.5), zc + 2.5);
    vec3 fw = normalize(ta - ro);
    vec2 bend = path(zc + 5.0) - 2.0 * path(zc + 2.5) + path(zc);
    float roll = camRoll() + clamp(bend.x * 1.4, -0.22, 0.22) + sin(barPhase * 2.0 * PI) * 0.015 * conf;
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(up, fw));
    vec3 upv = cross(fw, rt);
    float fov = 0.80 + build * 0.22 + loud * 0.04 + hit * 0.03;   // the lens widens as it builds
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * fov);

    // ---- march -------------------------------------------------------------------
    float t = 0.02, d = 1.0, glowA = 0.0;
    float pixA = fov / m;                                   // ray cone: one pixel per unit t
    gRo = ro; gPix = pixA;
    int i;
    for (i = 0; i < STEPS; i++) {
        d = map(ro + rd * t);
        glowA += exp(-d * 18.0);                            // near misses: haze hanging off the stone
        if (d < pixA * t * 0.7 || t > TMAX) break;
        t += d * 0.9;
    }
    bool solid = t < TMAX && d < pixA * t * 3.0;
    float steps = float(i) / float(STEPS);
    glowA /= float(STEPS);

    // ---- shade -------------------------------------------------------------------
    float sec = floor(section + 0.5);
    float palOff = sec * 0.21 + (sec == 2.0 ? 0.30 : 0.0);  // each section lays the palette differently
    float fogK = 0.13 - loud * 0.025 - light * 0.01;
    vec3 fogDark = mix(bg.rgb * 0.35, mix(c1.rgb, c2.rgb, 0.5) * 0.22, 0.3 + 0.3 * loud);
    vec3 fogLight = mix(bg.rgb, vec3(1.0), 0.3);
    vec3 fogCol = mix(fogDark, fogLight, light);
    // The lantern at the far end: the fog glows toward the vanishing point.
    vec3 vdir = normalize(vec3(path(zc + 10.0), zc + 10.0) - ro);
    float toward = max(dot(rd, vdir), 0.0);
    vec3 lantern = mix(pal(fract(0.5 + palOff)), fg.rgb, 0.3);
    fogCol += lantern * (pow(toward, 24.0) * 0.6 + pow(toward, 5.0) * 0.18) * lit(0.6 + bass * 0.5 + hit * 0.3);
    fogCol = mix(fogCol, mix(bg.rgb, c1.rgb, 0.12) * 0.92, light * pow(toward, 8.0) * 0.5);

    vec3 col = fogCol;
    if (solid) {
        vec3 p = ro + rd * t;
        float lvl, crease;
        mapInfo(p, lvl, crease);
        float e = max(pixA * t, 0.001);
        vec2 k2 = vec2(1.0, -1.0);
        vec3 n = normalize(k2.xyy * map(p + k2.xyy * e) + k2.yyx * map(p + k2.yyx * e)
                         + k2.yxy * map(p + k2.yxy * e) + k2.xxx * map(p + k2.xxx * e));
        float ao = clamp(1.0 - steps * 1.6, 0.0, 1.0);
        ao *= ao;
        // A lantern hanging ahead on the path, and a dim light riding with the camera.
        vec3 lp = vec3(path(zc + 3.0) + sway, zc + 3.0);
        vec3 ld = lp - p;
        float ll = length(ld);
        ld /= ll;
        float dif = max(dot(n, ld), 0.0) * (1.6 + hit * 0.3) / (1.0 + ll * ll * 0.12);
        float head = max(dot(n, -rd), 0.0);
        float rim = pow(1.0 - head, 4.0);

        // Stone: the big levels dark, the fine tracery taking the palette.
        float lv = lvl / float(LEVELS - 1);
        vec3 stone = pal(fract(lv * 0.55 + p.z * 0.02 + palOff));
        float alb = 0.10 + 0.18 * lv;
        vec3 base = stone * alb * (0.15 + dif + head * 0.25) * (0.3 + 0.7 * ao);
        base += mix(stone, fg.rgb, 0.3) * rim * 0.10 * ao;

        // Emissive creases: where two levels meet, a thin line of light, hard on kicks.
        float cw = e * (1.5 + hit * 2.5);
        float edge = 1.0 - smoothstep(0.0, cw, crease);
        edge *= smoothstep(TMAX * 0.8, 1.0, t) * (0.4 + 0.6 * ao);
        vec3 ec = pal(fract(0.3 + lv * 0.7 + palOff + p.z * 0.015));
        float eAmt = 0.3 + hit * 0.8 + snap * 0.2 + bHi * 0.35 + build * 0.3;
        // Rings of light running down the nave, one per recent kick.
        float dz = p.z - zc;
        float rings = 0.0;
        for (int j = 0; j < 3; j++) {
            float age = j == 0 ? kickAge.x : (j == 1 ? kickAge.y : kickAge.z);
            float zr = 2.2 + age * 9.0;                     // born a little ahead, then racing away
            rings += exp(-pow((dz - zr) * 2.4, 2.0)) * exp(-age * 1.1) * smoothstep(0.0, 0.06, age + 0.01);
        }
        rings *= kickAge.w;
        vec3 emis = ec * edge * eAmt + mix(c3.rgb, fg.rgb, 0.3) * rings * (0.08 + edge * 0.9 + min(dif, 1.0) * 0.15);

        vec3 litStone = base + emis * faux(1.0, 0.3);
        // Light themes: dark ink stone with a palette stain, edges as darker lines.
        vec3 ink = mix(stone * 0.22, bg.rgb * 0.30, 0.4) * (0.55 + 0.35 * min(dif, 1.0) + 0.2 * head) * (0.6 + 0.4 * ao);
        ink = mix(ink, stone * 0.18, edge * (0.5 + hit * 0.3));
        ink = mix(ink, c3.rgb * 0.5, rings * 0.25);
        vec3 sc = mix(litStone, ink, light);
        float fog = 1.0 - exp(-t * fogK);
        fog = fog * fog * (3.0 - 2.0 * fog);
        col = mix(sc, fogCol, fog);
    }

    // Haze off the near misses.
    col += mix(c1.rgb, c2.rgb, 0.5 + 0.5 * sin(time * 0.05)) * lit(glowA) * faux(0.5 + hit * 0.4 + build * 0.4, 0.45);

    // ---- drop flash: a white-hot burst that the new architecture appears out of ---
    float flash = pow(drop, 6.0);                          // a burst, gone in about half a second
    col += mix(lantern, vec3(1.0), 0.5) * flash * faux(0.8, 0.4) * dark;
    col = mix(col, mix(bg.rgb, vec3(1.0), 0.4), flash * 0.4 * light);
    // Build: the air thickens with light as the tension climbs.
    col += mix(c1.rgb, c3.rgb, 0.5) * build * 0.04 * dark;

    col = mix(col, sat3(col), dark);

    // ---- vignette ------------------------------------------------------------------
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.25, 0.85, length(vq * vec2(1.0, 0.9)));
    col = mix(col, mix(vec3(0.0), bg.rgb * 0.85, light), vig * mix(0.6, 0.2, light));

    fragColor = vec4(col + dither(px), 1.0) * qt_Opacity;
}
