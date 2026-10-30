#version 440
// Orpheus "Scope": an oscilloscope on a stage. The spectrum is played back as
// a sum of eight standing waves (one per group of four bands), so the bass
// bends the beam in long swells and the treble shivers along it. Three
// strands in the theme colours hang over a lit floor that recedes to a
// horizon; behind them, real afterimages (the wave as it was over the last
// half second, from the shared spectrum history) fall back into the dark.
// The floor mirrors the beam, light shafts cut through the haze, and the
// camera pushes in when it's loud and settles back when it's quiet.
// Kicks slam (kick), each jolting the camera its own way (kicks); snares make
// the grid and shafts shimmer (snap); swell drives the push-in. The beam
// overdrives and flashes, the camera punches in, the
// floor grid flares. Quiet passages go thin and calm, so the contrast is the show.

//#common

layout(binding = 1) uniform sampler2D hist;
// The album cover (Viz.qml): alpha 0 when there is none.
layout(binding = 2) uniform sampler2D art;

const float PI = 3.14159265;
const int ECHOES = 9;        // afterimages, every ESTEP history rows (~0.45 s at 60 fps)
const int ESTEP = 3;
const float EDEPTH = 0.22;   // depth between afterimages; scale = 1 / (1 + z)
const float VPY = 0.16;      // horizon / vanishing point height (view-height units from centre)
const float Y0 = -0.36;      // stage floor height at the beam's plane
const float YC = -0.03;      // beam centre line
const float CLIP = 0.30;     // soft-clip ceiling on the wave height: loud = overdriven, flat-topped

// Shape a band level: quiet stays small, loud dominates (the contrast is the show).
float shape(float v) { return pow(clamp(v, 0.0, 1.0), 1.5) * 1.55; }

// Wave height and slope (both in view-height units, slope per unit of xn) at xn in 0..1.
vec2 wave(float xn, float amp[8], float t, float ph, float speed) {
    float y = 0.0, dy = 0.0;
    for (int k = 0; k < 8; k++) {
        float fk = float(k);
        float f = (1.0 + fk * 1.65) * 2.0 * PI;              // spatial frequency
        float w = t * speed * (0.6 + fk * 0.35) + ph * (1.0 + fk * 0.5);
        float a = amp[k] * (0.13 / (1.0 + fk * 0.45));        // treble ripples are smaller
        y += a * sin(f * xn + w);
        dy += a * f * cos(f * xn + w);
    }
    // Pin the ends like a plucked string: envelope e = sin(pi x)^0.6.
    float s = max(sin(PI * xn), 1e-3);
    float e = pow(s, 0.6);
    float de = 0.6 * pow(s, -0.4) * PI * cos(PI * xn);
    y = y * e;
    dy = dy * e + (y / e) * de;
    // Soft clip: big swings flatten into an overdriven plateau instead of leaving the stage.
    float th = tanh(y / CLIP);
    return vec2(CLIP * th, dy * (1.0 - th * th));
}

// Largest |y| the wave can reach for these amplitudes (for skipping far pixels).
float reach(float amp[8]) {
    float r = 0.0;
    for (int k = 0; k < 8; k++) r += amp[k] * (0.13 / (1.0 + float(k) * 0.45));
    return min(r, CLIP);
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float H = res.y;
    float aspect = res.x / res.y;

    // ---- camera: pushes in with the loudness, punches on kicks, drifts slowly ----
    float loud = smoothstep(0.05, 0.7, energy);
    float zoom = 1.0 + swell * 0.14 + kick * 0.07;             // swell pushes in, kicks punch
    vec2 q = (px - res * 0.5) / H;                           // view-height units, centred
    q = rotateAround(q, vec2(0.0), camRoll() * 0.6);
    q /= zoom;
    // Each kick jolts the camera a different way (kicks counts them).
    float ja = hash(vec2(kicks, 3.7)) * 6.2831853;
    vec2 jolt = vec2(cos(ja), sin(ja) * 0.6 - 0.5) * kick * 0.014;
    q += vec2(sin(time * 0.11) * 0.025, camBob(1.0)) + jolt;
    float pxU = 1.0 / (H * zoom);                            // one screen pixel in q units

    // ---- amplitudes: current bands (or their falling peaks, whichever is higher) ----
    vec4 bb[8] = vec4[8](b0, b1, b2, b3, b4, b5, b6, b7);
    vec4 pp[8] = vec4[8](p0, p1, p2, p3, p4, p5, p6, p7);
    float amp[8];
    float drive = 1.0 + kick * 0.7;                          // a brief overdrive spike on kicks
    for (int k = 0; k < 8; k++) {
        float g = dot(bb[k], vec4(0.25));
        float pk = dot(pp[k], vec4(0.25));
        amp[k] = shape(max(g, pk * 0.75)) * drive + 0.010;   // a hair of idle motion
    }
    float peakAvg = 0.0;
    for (int k = 0; k < 8; k++) peakAvg += dot(pp[k], vec4(0.125 / 4.0));
    float hot = smoothstep(0.08, 0.6, max(energy, peakAvg)); // drives thickness and brightness

    vec3 cs[3] = vec3[3](c1.rgb, c2.rgb, c3.rgb);
    float W = aspect * 0.94;                                 // beam span in the z = 0 plane
    vec4 col = vec4(0.0);                                    // premultiplied, front to back

    // ---- front beam: three strands --------------------------------------------
    float R0 = reach(amp);
    vec3 haloSum = vec3(0.0);
    float haloA = 0.0;
    float xn = q.x / W + 0.5;
    if (xn > 0.0 && xn < 1.0) {
        float near = abs(q.y - YC) - R0;                     // > 0: outside the beam's envelope
        // Narrower under real bloom, which also shrinks the band of pixels that run the strands.
        float glowR = (0.008 + hot * 0.016 + kick * 0.010) * (1.0 - 0.5 * light) * (1.0 - 0.3 * bloomAmt);
        float ends = smoothstep(0.0, 0.03, xn) * smoothstep(1.0, 0.97, xn);   // the beam fades into the wings
        if (near < glowR * 4.0) {
            for (int s = 0; s < 3; s++) {
                float fs = float(s);
                float sc = 1.0 - fs * 0.18;                  // back strands are a little quieter
                vec2 w = wave(xn, amp, time, fs * 2.1, 1.0 + fs * 0.25) * sc;
                float d = abs(q.y - (YC + w.x)) / sqrt(1.0 + (w.y / W) * (w.y / W)) / pxU;   // pixels
                float width = 0.6 + (1.0 - fs * 0.2) * (0.4 + hot * 3.2) + kick * 2.2;
                float core = clamp(width - d + 0.5, 0.0, 1.0) * ends;
                vec3 hc = mix(cs[s], fg.rgb, (0.20 + 0.30 * hot + 0.25 * kick) * (1.0 - light));
                col.rgb += (1.0 - col.a) * core * hc;
                col.a += (1.0 - col.a) * core;
                float halo = lit(glow(d * pxU, glowR)) * faux(0.15 + hot * 0.45 + kick * 0.30, 0.4) * ends;
                haloSum += halo * cs[s];
                haloA += halo;
            }
        }
    }

    // ---- afterimages: the beam as it was, receding toward the horizon ----------
    // Only while there is sound: the history holds still in silence.
    float echoOn = smoothstep(0.002, 0.03, energy);
    if (echoOn > 0.0) {
        for (int e = 1; e <= ECHOES; e++) {
            float fe = float(e);
            float sE = 1.0 / (1.0 + fe * EDEPTH);
            vec2 q0 = vec2(0.0, VPY) + (q - vec2(0.0, VPY)) / sE;   // pixel in that plane
            float xe = q0.x / W + 0.5;
            if (xe <= 0.0 || xe >= 1.0) continue;
            float row = (fe * float(ESTEP) + 0.5) / 40.0;
            float ea[8];
            for (int k = 0; k < 8; k++)                     // linear filtering averages 2 bands
                ea[k] = shape(texture(hist, vec2((float(k) * 4.0 + 2.0) / 32.0, row)).r) + 0.010;
            float pxE = pxU / sE;
            if (abs(q0.y - YC) - reach(ea) > pxE * 3.0) continue;
            float fade = pow(1.0 - fe / float(ECHOES + 1), 1.6) * echoOn;
            float tE = time - fe * float(ESTEP) / 60.0;
            for (int s = 0; s < 3; s++) {
                float fs = float(s);
                vec2 w = wave(xe, ea, tE, fs * 2.1, 1.0 + fs * 0.25) * (1.0 - fs * 0.18);
                float d = abs(q0.y - (YC + w.x)) / sqrt(1.0 + (w.y / W) * (w.y / W)) / pxE;
                float core = clamp(0.5 + hot * 1.0 - d + 0.5, 0.0, 1.0) * fade * 0.55;
                vec3 ec = mix(cs[s], bg.rgb, (fe / float(ECHOES)) * 0.55);
                col.rgb += (1.0 - col.a) * core * ec;
                col.a += (1.0 - col.a) * core;
            }
        }
    }

    // ---- floor: perspective grid, a spotlight pool, the beam's reflection -------
    if (q.y < VPY - 0.004) {
        float s = (q.y - VPY) / (Y0 - VPY);                  // plane scale at this floor row
        float zw = 1.0 / s - 1.0;                            // depth; < 0 is in front of the beam
        float xw = q.x / s;
        float cross = abs(fract(zw * 1.4 + flow * 0.55) - 0.5);
        float side = abs(fract(xw * 5.0 + 0.5) - 0.5);
        float aZ = fwidth(zw * 1.4) + 1e-4, aX = fwidth(xw * 5.0) + 1e-4;
        float lines = max(1.0 - smoothstep(0.0, aZ * 1.5, cross), 1.0 - smoothstep(0.0, aX * 1.5, side));
        float distFade = smoothstep(VPY, VPY - 0.10, q.y);
        float pool = exp(-(xw * xw) / (0.35 + loud * 0.4) - (zw * zw) / 0.5);
        // Snares and hats make the grid shimmer: alternate lines catch the light.
        float shimmer = snap * (0.5 + 0.5 * sin(floor(zw * 1.4 + flow * 0.55) * 2.7 + floor(xw * 5.0 + 0.5) * 1.9));
        lines *= distFade * (0.07 + 0.16 * loud + 0.45 * kick + 0.35 * shimmer) * (0.5 + pool) * (1.0 - 0.4 * light);
        vec3 lc = mix(c2.rgb, c1.rgb, 0.35 + 0.5 * kick);
        col.rgb += (1.0 - col.a) * lines * lc;
        col.a += (1.0 - col.a) * lines;

        float lp = lit(pool * distFade * (0.06 + loud * 0.22 + kick * 0.25));
        col.rgb += lp * mix(c1.rgb, c3.rgb, 0.5);
        col.a += lp * 0.4;

        // Reflection of the front beam: the floor mirrors the z = 0 plane about Y0.
        if (q.y < Y0 && xn > 0.0 && xn < 1.0) {
            float depth = Y0 - q.y;
            float yr = 2.0 * Y0 - q.y + sin(q.x * 38.0 + time * 2.3) * 0.004 * depth * 6.0;
            if (abs(yr - YC) - R0 < 0.03) {
                float refl = exp(-depth * 5.5) * 0.45 * smoothstep(0.0, 0.03, xn) * smoothstep(1.0, 0.97, xn);
                for (int s = 0; s < 3; s++) {
                    float fs = float(s);
                    vec2 w = wave(xn, amp, time, fs * 2.1, 1.0 + fs * 0.25) * (1.0 - fs * 0.18);
                    float d = abs(yr - (YC + w.x)) / pxU;
                    float rc = clamp(1.2 + hot * 2.0 - d * 0.6, 0.0, 1.0) * refl;
                    float rg = lit(glow(d * pxU, 0.012 + hot * 0.015)) * refl * faux(0.3 + hot, 0.3);
                    col.rgb += (1.0 - col.a) * rc * cs[s] + rg * cs[s];
                    col.a += (1.0 - col.a) * rc + rg * 0.3;
                }
            }
        }
    }

    // ---- the cover, projected onto the haze behind the stage -----------------------
    // Soft-edged, scanlined like a CRT, breathing with the loudness.
    {
        vec2 cu = (q - vec2(0.0, 0.10)) / 0.70 + 0.5;
        vec4 A = texture(art, vec2(cu.x, 1.0 - cu.y));
        vec2 e = min(cu, 1.0 - cu);
        float m = smoothstep(0.0, 0.18, e.x) * smoothstep(0.0, 0.18, e.y);
        float scan = 0.72 + 0.28 * sin(px.y * 2.2);
        float ka = A.a * m * scan * mix(0.20 + 0.10 * loud + 0.08 * kick, 0.22, light);
        col.rgb += (1.0 - col.a) * ka * A.rgb;
        col.a += (1.0 - col.a) * ka;
    }

    // ---- light: beam glow, shafts through the haze, a backlight behind the stage ----
    col.rgb += 1.0 - exp(-haloSum * 1.2);                     // soft-saturate so kicks flash, not blow out
    col.a += haloA * 0.35;

    // Two shafts from above, swaying, aimed at the stage; they flare on kicks.
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        vec2 top = vec2((fi * 2.0 - 1.0) * 0.55 + sin(time * 0.21 + fi * 2.0) * 0.12, 0.62);
        vec2 aim = vec2((fi * 2.0 - 1.0) * 0.12 + sin(time * 0.17 + fi) * 0.20, Y0);
        vec2 ax = aim - top;
        float t = clamp(dot(q - top, ax) / dot(ax, ax), 0.0, 1.2);
        float dl = length(q - (top + ax * t));
        float wide = 0.02 + t * 0.20;
        float shaft = lit(glow(dl, wide) * smoothstep(0.0, 0.35, t) * smoothstep(1.2, 0.8, t)
                    * (0.03 + loud * 0.12 + kick * 0.22 + snap * 0.12));
        col.rgb += shaft * cs[i * 2];
        col.a += shaft * 0.5;
    }
    float back = lit(glow(q.y - (YC + 0.05), 0.22) * glow(q.x, 0.9) * (0.04 + loud * 0.12 + kick * 0.15));
    col.rgb += back * c2.rgb;
    col.a += back * 0.5;

    col.a = clamp(col.a, 0.0, 1.0);

    // ---- vignette: a dark spotlight falloff laid over everything ------------------
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.25, 0.85, length(vq * vec2(1.0, 0.9)));
    float va = vig * mix(0.55 - loud * 0.15, 0.12, light);
    vec3 vc = mix(vec3(0.0), bg.rgb * 0.82, light);
    col.rgb = col.rgb * (1.0 - va) + vc * va;
    col.a = col.a + va * (1.0 - col.a);

    fragColor = vec4(col.rgb + dither(px) * col.a, col.a) * qt_Opacity;
}
