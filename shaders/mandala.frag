#version 440
// Orpheus "Mandala": the set visual. An infinite kaleidoscopic fold — the
// pseudo-Kleinian iteration under a 7-fold polar symmetry around the travel
// axis — flown through forever. Everything on screen is one piece of
// geometry folding into itself: box folds and sphere inversions carve
// endless vaulted cells, and the polar fold stamps them into a turning
// mandala around you. The surface is near-black; the light is the fold's
// own mathematics: orbit traps etch neon seams along the creases (the
// closer the iteration passed to the axes, the hotter the line), coloured
// through the palette by trap depth and tilted by the treble. It never
// stops shifting: the fold sizes breathe on the slow loudness, the
// symmetry turns with `flow`, and the whole structure morphs continuously
// as the fold centre drifts. Kicks send a symmetric flash ring out through
// the cells; snares sparkle the nearest seams. A build crushes the fold
// inward — cells crowd, seams tighten, the mandala winds up — the drop-map
// wind-up over-rotates it — and the drop IS the shift: the fold constants
// jump to a new attractor (seeded per drop), the architecture becomes a
// different architecture under one flash, and settles. Breakdown relaxes
// everything open. Light themes: porcelain fold, seams as dark inlay.
// Cost: 60 steps x 7 fold iterations, all algebra, no noise, no textures.

//#common

const float PI = 3.14159265;
const int STEPS = 60;
const int ITER = 7;
const float TMAX = 14.0;
const float SPEED = 0.9;

mat2 rot2(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

// fold state, set once in main()
vec3 gC = vec3(0.9076, 0.9244, 0.9076);
float gMins = 1.07;
float gSym = 7.0;
float gTwist = 0.0;

float gTrapA = 1e9, gTrapB = 1e9;    // orbit traps: axis seam, plane seam

float map(vec3 p) {
    // periodic along the travel axis: every cell inhabited, no empty pockets
    p.z = mod(p.z + 1.1, 2.2) - 1.1;
    // the mandala: polar-fold the cross-section into gSym wedges, turning
    p.xy = rot2(gTwist) * p.xy;
    float a = atan(p.y, p.x);
    float w = 2.0 * PI / gSym;
    a = abs(mod(a + w * 0.5, w) - w * 0.5);
    p.xy = vec2(cos(a), sin(a)) * length(p.xy);
    // the fold
    float d = 1.0;
    gTrapA = 1e9; gTrapB = 1e9;
    for (int i = 0; i < ITER; i++) {
        p = 2.0 * clamp(p, -gC, gC) - p;
        float r2 = dot(p, p);
        float k = max(gMins / max(r2, 1e-6), 1.0);
        p *= k; d *= k;
        gTrapA = min(gTrapA, length(p.xy));
        gTrapB = min(gTrapB, abs(p.z));
    }
    float rxy = length(p.xy);
    return max(rxy - 0.92784, abs(rxy * p.z) / max(length(p), 1e-6)) / d;
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
    float tilt = (band(0.7) + band(0.78)) * 0.5;

    // ---- the fold's life: breathe, crush, SHIFT ----
    float breath = sin(time * 0.5) * 0.5 + 0.5;
    // each drop lands on a new attractor: the seed steps when the drop fires
    float seed = floor(kicks / 4.0) + floor(dr * 0.999 + 0.5) * 7.0;
    vec3 attr = vec3(0.88 + 0.1 * hash(vec2(seed, 1.1)),
                     0.9 + 0.09 * hash(vec2(seed, 2.2)),
                     0.88 + 0.1 * hash(vec2(seed, 3.3)));
    // continuous morph at rest; the drop slams the constants toward the new attractor
    vec3 drift = vec3(0.012 * sin(flow * 0.11), 0.012 * sin(flow * 0.083 + 2.0), 0.012 * sin(flow * 0.067 + 4.0));
    gC = mix(vec3(0.9076, 0.9244, 0.9076), attr, 0.35 + 0.65 * smoothstep(0.0, 0.4, dr)) + drift;
    gC *= 1.0 - 0.06 * bd + 0.02 * breath * (1.0 - bd);      // the build crushes the cells
    gMins = 1.07 + 0.05 * loud - 0.04 * bd;
    gSym = 7.0;
    gTwist = flow * 0.05 + ant * ant * 1.2 + dr * 0.6;       // turning; over-wound before the drop

    // ---- the flight: straight down the fold's z, drifting off-axis ----
    float zc = flow * SPEED;
    vec3 ro = vec3(0.24 * sin(zc * 0.21), 0.24 * cos(zc * 0.17), zc);
    vec3 fw = normalize(vec3(0.3 * sin(zc * 0.21 + 1.5) - ro.x, 0.3 * cos(zc * 0.17 + 1.5) - ro.y, 2.2));
    float roll = camRoll() * 1.4;
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(up, fw));
    vec3 upv = cross(fw, rt);
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * (0.85 + 0.05 * loud));

    // ---- march ----
    float jit = hash(px + fract(time) * 61.7);
    float t = 0.12 + jit * 0.1;
    bool hitS = false;
    int i;
    for (i = 0; i < STEPS; i++) {
        float d = map(ro + rd * t);
        if (d < 0.0012 * t + 0.0006) { hitS = true; break; }
        t += d * 0.85;
        if (t > TMAX) break;
    }
    hitS = hitS && t < TMAX;

    vec3 fogCol = mix(bg.rgb * 0.4, pal(0.5) * 0.08, 0.3) * dark + bg.rgb * light;
    vec3 col = fogCol;
    if (hitS) {
        vec3 p = ro + rd * t;
        float trapA = gTrapA, trapB = gTrapB;                // traps at the hit
        vec2 e2 = vec2(1.0, -1.0) * 0.0012 * max(t, 0.1);
        vec3 n = normalize(e2.xyy * map(p + e2.xyy) + e2.yyx * map(p + e2.yyx)
                         + e2.yxy * map(p + e2.yxy) + e2.xxx * map(p + e2.xxx));
        float ndv = abs(dot(n, -rd));
        float rim = pow(1.0 - ndv, 2.0);
        float ao = clamp(map(p + n * 0.08) / 0.08, 0.0, 1.0);
        ao = 0.3 + 0.7 * ao;

        // ---- the seams: orbit traps become the neon line-work ----
        float seamA = exp(-trapA * trapA * 9.0);             // the axis seam
        float seamB = exp(-trapB * trapB * 16.0);            // the plane seam
        float depthK = clamp(t / TMAX, 0.0, 1.0);
        vec3 lcA = pal(clamp(0.15 + 0.5 * depthK + 0.25 * tilt, 0.0, 1.0));
        vec3 lcB = pal(clamp(0.75 - 0.35 * depthK + 0.2 * tilt, 0.0, 1.0));
        float seamGain = (0.5 + 0.6 * loud) * (1.0 - 0.45 * bd);

        // kick rings: symmetric flashes radiating out through the cells
        float rings = 0.0;
        for (int j = 0; j < 3; j++) {
            float age = kickAge[j];
            if (age < 1.8) {
                float zr = 0.3 + age * 7.0;
                rings += exp(-pow((t - zr) / (0.7 + age * 0.5), 2.0)) * exp(-age * 1.6)
                       * (j == 0 ? kickAge.w : 0.55);
            }
        }
        // snares sparkle the nearest seams
        float sparkle = snap * exp(-t * 0.8) * seamB;
        // the drop's flash lives on the seams, not the whole field
        float flash = dr * dr * dr * (seamA + seamB) * 1.6;

        vec3 matte = mix(bg.rgb * 0.45, fg.rgb * 0.05, 0.5) * ao * (0.5 + 0.5 * ndv);
        vec3 emis = (lcA * seamA + lcB * seamB * 0.8) * (seamGain + rings * 0.9) * (0.4 + 0.6 * ao)
                  + lcB * sparkle * 0.8
                  + mix(lcA, c3.rgb, 0.6) * flash
                  + c3.rgb * rim * ant * 0.25;               // the wind-up charges the edges
        vec3 sDark = matte + emis * faux(1.0, 0.35);

        // porcelain fold: seams as dark inlay, a blush of palette in the cuts
        vec3 porc = mix(bg.rgb, vec3(1.0), 0.12) * (0.75 + 0.25 * ndv) * (0.6 + 0.4 * ao);
        porc = mix(porc, lcA * 0.45, seamA * 0.55);
        porc = mix(porc, lcB * 0.4, seamB * 0.4);
        vec3 surf = mix(sDark, porc, light);

        float fogA = 1.0 - exp(-t * (0.22 - 0.06 * loud));
        fogA = fogA * fogA * (3.0 - 2.0 * fogA);
        col = mix(surf, fogCol, fogA);
    }

    // the air hums with the seams' light
    col += mix(pal(0.3), pal(0.7), tilt) * lit(0.012 + 0.03 * loud + 0.02 * kick) * faux(1.0, 0.4);

    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.25, 0.85, length(vq * vec2(1.0, 0.9)));
    col = mix(col, mix(vec3(0.0), bg.rgb * 0.88, light), vig * mix(0.5, 0.18, light));
    col = max(col, vec3(0.0));
    col = col / (1.0 + col * 0.15);
    fragColor = vec4(max(col + dither(px), vec3(0.0)), 1.0) * qt_Opacity;
}
