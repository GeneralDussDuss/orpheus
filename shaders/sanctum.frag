#version 440
// Orpheus "Sanctum", third build: ethereal means VOLUME. The corridor
// raycast still read as a box (user call, 2026-11-07); this one glides you
// through an endless hypostyle hall — a forest of columns rising into dark
// vaults — and the subject is the air: slanted god-rays fall between the
// columns in sheets, and the march ACCUMULATES them, so light has body,
// columns swim in it as silhouettes, and depth is fog you move through.
// Each sheet of light is a region of the spectrum (sheets you are passing
// are bass, sheets far ahead treble), so a chord hangs in the air as depth.
// Dust sparks drift in the bright sheets and begin to RISE when the drop
// map arms. Kicks are a low toll: a wave of light rolls away through the
// sheets. A build thickens the gloom and steepens the shafts until only
// embers of light survive — and the drop is dawn: the air itself ignites
// from ahead and the whole hall stands lit for a breath. The camera walks
// on `flow`, weaving gently between the columns. No walls, no box: columns
// and light to the fog limit in every direction.
// Light themes: morning hall — pale air, graphite columns, shade for rays.
// Cost: 48 steps; per step one column SDF (2D), one shaft term, cheap hash.

//#common

const float PI = 3.14159265;
const int STEPS = 48;
const float TMAX = 24.0;
const float SPEED = 1.1;       // a procession, not a dive
const float COLS = 2.6;        // column lattice spacing
const float CRAD = 0.34;       // column radius
const float CEIL = 3.4;        // vault height
const float FLOORY = -1.2;

mat2 rot2(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

// The hall: columns on a lattice (every cell, jittered), floor, vault.
// Columns swell into capitals near the ceiling.
float map(vec3 p) {
    vec2 cell = floor(p.xz / COLS);
    vec2 q = fract(p.xz / COLS) - 0.5;
    vec2 jx = (vec2(hash(cell), hash(cell + 7.3)) - 0.5) * 0.3;
    float rad = CRAD * (1.0 + 0.5 * smoothstep(CEIL * 0.55, CEIL, p.y));   // the capital
    float dcol = (length(q - jx) * COLS) - rad;
    float dfloor = p.y - FLOORY;
    float dceil = CEIL - p.y + 0.35 * sin(p.x * 1.1) * sin(p.z * 1.1);     // shallow vaults
    return min(dcol, min(dfloor, dceil));
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float mres = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / mres;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));
    float conf = clamp(beatConfidence, 0.0, 1.0);
    float breath = 0.5 + 0.5 * sin(time * 0.5);

    // ---- the walk: forward on flow, weaving between the columns ----
    float zc = flow * SPEED;
    vec3 ro = vec3(COLS * 0.5 + 0.8 * sin(zc * 0.17), 0.25 + 0.1 * sin(zc * 0.11 + 1.0), zc);
    vec3 ahead = ro + vec3(0.8 * 0.17 * cos(zc * 0.17) * 3.0, 0.0, 3.0);
    vec3 fw = normalize(ahead - ro);
    float roll = camRoll() * 0.6;
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(up, fw));
    vec3 upv = cross(fw, rt);
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * 0.95);

    // ---- the light: slanted sheets falling between the columns ----
    // A sheet lives on planes of constant s = z + x * lean; its brightness is
    // its band of the spectrum, by how far ahead of the camera the sheet is.
    float lean = 0.55 + 0.25 * bd;                           // the shafts steepen as it builds
    float gloom = 0.22 + 0.1 * bd - 0.05 * loud;             // fog density
    gloom *= 1.0 - 0.12 * downbeat * conf;

    float jit = hash(px + fract(time) * 61.7);
    float t = 0.05 + jit * 0.3;
    vec3 acc = vec3(0.0);
    float trans = 1.0;
    bool hitS = false;
    vec3 hp = ro;
    for (int i = 0; i < STEPS; i++) {
        vec3 p = ro + rd * t;
        float d = map(p);
        if (d < 0.004 * t + 0.003) { hitS = true; hp = p; break; }
        float dt = min(d * 0.85, 0.65);
        // --- the air in this stretch ---
        float s = (p.z + p.x * 0.3 - p.y * lean);            // sheet coordinate
        float cellI = floor(s / 2.1);
        float su = fract(s / 2.1);
        float sheet = exp(-pow((su - 0.5) / (0.1 + 0.08 * loud), 2.0));
        float frq = clamp((cellI * 2.1 - zc) * 0.03 + 0.1, 0.0, 1.0);     // ahead = treble
        float e = pow(clamp(band(frq), 0.0, 1.0), 0.6) * (0.5 + 0.8 * swell);
        // height shaping: light falls from above, dies toward the floor
        float fall = smoothstep(FLOORY, CEIL * 0.8, p.y) * 0.7 + 0.3;
        // the kick toll: a wave of light rolling away through the sheets
        float toll = 0.0;
        for (int k = 0; k < 2; k++) {
            float age = kickAge[k];
            if (age < 2.0) {
                float zr = 1.0 + age * 8.0;
                toll += exp(-pow((t - zr) / 1.4, 2.0)) * exp(-age * 1.5) * (k == 0 ? kickAge.w : 0.5);
            }
        }
        float lum = sheet * (0.3 + 2.6 * e) * fall * (1.0 - 0.5 * bd) + sheet * toll * 1.2;
        // the drop: dawn — the air ignites from ahead
        lum += dr * dr * (0.3 + 0.6 * sheet) * smoothstep(0.0, 10.0, t) * 1.4;
        vec3 sheetC = pal(clamp(0.2 + 0.6 * frq + 0.15 * breath * 0.3, 0.0, 1.0));
        // dust: sparse sparks living only inside bright sheets, rising on the wind-up
        float spark = 0.0;
        if (sheet > 0.3) {
            vec3 sp = p * 7.0; sp.y += time * (0.25 + 1.6 * ant);
            spark = step(0.982 - ant * 0.012, hash(floor(sp.xy + sp.z * 13.1))) * sheet * (0.3 + ant);
        }
        acc += (sheetC * lum + c3.rgb * spark) * gloom * dt * trans;
        trans *= exp(-gloom * dt * (0.55 + 0.3 * sheet * (0.3 + e)));
        t += dt;
        if (t > TMAX || trans < 0.03) break;
    }

    // ---- the stone the march landed on ----
    vec3 col;
    vec3 bgfar = mix(bg.rgb * 0.3, pal(0.5) * 0.08, 0.4) * dark + bg.rgb * light;
    bgfar += pal(0.75) * dr * dr * 0.4 * dark;               // dawn behind everything
    if (hitS) {
        vec2 e2 = vec2(1.0, -1.0) * 0.012 * max(t, 0.4);
        vec3 n = normalize(e2.xyy * map(hp + e2.xyy) + e2.yyx * map(hp + e2.yyx)
                         + e2.yxy * map(hp + e2.yxy) + e2.xxx * map(hp + e2.xxx));
        float ndv = abs(dot(n, -rd));
        float rim = pow(1.0 - ndv, 2.5);
        // columns stand as silhouettes; light kisses their edges where sheets pass
        float s = (hp.z + hp.x * 0.3 - hp.y * lean);
        float sheetHere = exp(-pow((fract(s / 2.1) - 0.5) / 0.12, 2.0));
        float frq = clamp((floor(s / 2.1) * 2.1 - zc) * 0.03 + 0.1, 0.0, 1.0);
        float eh = pow(clamp(band(frq), 0.0, 1.0), 0.6);
        vec3 stone = (bg.rgb * 0.4 + fg.rgb * 0.03) * (0.4 + 0.6 * ndv);
        vec3 kiss = pal(0.25 + 0.6 * frq) * rim * sheetHere * (0.3 + 1.2 * eh + dr);
        float floorHit = smoothstep(0.3, 0.0, abs(hp.y - FLOORY));
        // the floor carries a dim mirror of the air above it
        vec3 sheen = acc * floorHit * 0.5;
        vec3 sDark = stone * 0.5 + kiss + sheen;
        vec3 sLight = mix(bg.rgb * 0.85, fg.rgb * 0.35, 0.5 + 0.3 * rim) ;
        sLight = mix(sLight, pal(0.3 + 0.5 * frq) * 0.6, sheetHere * eh * 0.5);
        vec3 surf = mix(sDark, sLight, light);
        float fogA = 1.0 - exp(-t * 0.14);
        col = mix(surf, bgfar, fogA * fogA);
    } else {
        col = bgfar;
    }

    if (light < 0.5) {
        col += acc * lit(1.0);
        col = 1.0 - exp(-col * 1.25);
    } else {
        // morning hall: the accumulated light becomes soft shade and glass tints
        float a = clamp(dot(acc, vec3(0.5)), 0.0, 1.0);
        vec3 tint = clamp(acc / max(a, 1e-3), 0.0, 1.0);
        col = mix(col, mix(bg.rgb, tint * 0.65 + bg.rgb * 0.3, 0.7), a * 0.65);
    }

    // vignette
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.3, 0.9, length(vq * vec2(1.0, 0.9)));
    col = mix(col, mix(vec3(0.0), bg.rgb * 0.9, light), vig * mix(0.5, 0.16, light));

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
