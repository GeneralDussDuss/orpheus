#version 440
// Orpheus "Ridge": Unknown Pleasures ridgelines. Forty spectrum lines stand in
// rows receding toward a horizon, one moment of the song per row: the newest
// at the front, the last ~2/3 s falling back into the haze. Each line mirrors
// the spectrum about the middle (bass in the centre, treble out to flat tails)
// with a pulsar-like jag riding on the loud parts. True hidden-line drawing:
// every ridge is filled with the background below its line, so a nearer ridge
// hides the ones behind it. Colour runs c1 at the front through c2 to c3 far
// away, and depth fades into fog. Kicks bump and brighten the front lines; a
// drop fires a flare that races back through the stack; a build tightens and
// raises it; the camera sways with the bar.

//#common

layout(binding = 1) uniform sampler2D hist;

const int R = 40;            // rows of history (the 32x40 history target)
const float RF = 40.0;
const float SFAR = 0.5;      // perspective scale of the farthest row (front = 1)
const float SPREAD = 0.80;   // half-width (row units) the 32 bands spread over from the centre
const float FREQ = 17.0;     // jag cells per row unit

float sq(float x) { return x * x; }
// Soft saturation so stacked glow flashes instead of clipping flat.
vec3 sat3(vec3 x) { return x / (1.0 + max(max(x.r, x.g), x.b) * 0.6); }

// Value noise along x for row r: value and derivative (per unit x).
vec2 vnoise(float x, float r) {
    float i = floor(x), t = x - i;
    float h0 = hash(vec2(i, r)), h1 = hash(vec2(i + 1.0, r));
    float s = t * t * (3.0 - 2.0 * t);
    return vec2(mix(h0, h1, s), (h1 - h0) * 6.0 * t * (1.0 - t));
}

// A ridge's height (in units of its amplitude) and its slope d/dX, at X in -1..1.
vec2 profile(float X, float r, float quiet) {
    float c = X - sin(time * 0.07) * 0.04;                  // the mirror line wanders a little
    float sgn = c < 0.0 ? -1.0 : 1.0;
    float st = sgn > 0.0 ? 1.07 : 1.0;                      // and the halves differ, so it isn't a mirror
    float ax = abs(c) * st;
    float dax = sgn * st;

    // Band value from this history row, smoothly between bins.
    // (bins advance quicker near the centre, so the bass doesn't swallow the middle)
    float u = clamp(ax / SPREAD, 1e-3, 1.0);
    float bb = pow(u, 0.8) * 31.0;
    float dbb = (ax < SPREAD) ? dax * 31.0 * 0.8 * pow(u, -0.2) / SPREAD : 0.0;
    float i = min(floor(bb), 30.0), f = bb - i;
    float row = (r + 0.5) / RF;
    float v0 = texture(hist, vec2((i + 0.5) / 32.0, row)).r;
    float v1 = texture(hist, vec2((i + 1.5) / 32.0, row)).r;
    float s = f * f * (3.0 - 2.0 * f);
    float vr = mix(v0, v1, s);
    float dvr = (v1 - v0) * 6.0 * f * (1.0 - f) * dbb;
    // Quiet stays low, loud dominates.
    float v = vr * sqrt(vr + 1e-4) * 1.05;
    float dv = 1.5 * sqrt(vr + 1e-4) * dvr * 1.05;

    // Envelope: the activity lives in the middle; the outer ends lie flat.
    float e0 = 0.45, e1 = 0.93;
    float et = clamp((ax - e0) / (e1 - e0), 0.0, 1.0);
    float e = 1.0 - et * et * (3.0 - 2.0 * et);
    float de = (ax > e0 && ax < e1) ? -6.0 * et * (1.0 - et) / (e1 - e0) * dax : 0.0;

    // Jag: two octaves of noise riding on the loud parts, drifting slowly along.
    float xn = X * FREQ + r * 7.31 + time * 0.35;
    vec2 n1 = vnoise(xn, r);
    vec2 n2 = vnoise(xn * 2.3 + 11.0, r + 57.0);
    float n = n1.x * 0.62 + n2.x * 0.38;
    float dn = (n1.y * 0.62 + n2.y * 0.38 * 2.3) * FREQ;
    float m = 0.48 + 1.04 * n;
    float dm = 1.04 * dn;

    // A faint breath on every line, so even silence reads as a living trace.
    float q = (n - 0.5) * quiet * (0.35 + 0.65 * e);
    float dq = dn * quiet * (0.35 + 0.65 * e) + (n - 0.5) * quiet * 0.65 * de;

    float h = e * v * m + q;
    float dh = de * v * m + e * dv * m + e * v * dm + dq;
    return vec2(h, dh);
}

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float H = res.y;
    float dark = 1.0 - light;
    float px = H / 1440.0;                        // pixel scale against a 1440p reference

    // ---- camera: a slow roll, a bob, and a sideways sway on the bar -----------
    vec2 focus = vec2(res.x * 0.5, H * 0.45);
    p = rotateAround(p, focus, camRoll() * 0.25);
    p.y -= camBob(H) * 0.6;
    float conf = beatConfidence;
    float sway = res.x * (0.011 * sin(barPhase * 6.2831853) * conf + 0.007 * sin(time * 0.21) * (1.0 - conf));

    // ---- the stack: a build raises it and pulls the rows together -------------
    float yFront = H * (0.10 + 0.075 * build);
    float yFar = H * (0.73 + 0.025 * build);
    float halfW0 = min(res.x * 0.42, H * 0.98);
    float A0 = H * 0.30 * (1.0 + 0.12 * build + 0.18 * drop);
    float K = (1.0 / SFAR - 1.0) / (RF - 1.0);
    float quiet = 0.010 + 0.008 * energy;
    float dropAt = (1.0 - drop) * RF * 1.3;                  // the drop's flare races front to back

    vec3 acc = vec3(0.0);                                    // premultiplied colour, front to back
    vec3 glowAcc = vec3(0.0);                                // self-glow, already occluded
    float T = 1.0;                                           // transmittance

    for (int ir = 0; ir < R; ir++) {
        float r = float(ir);
        float sr = 1.0 / (1.0 + r * K);
        float tr = (1.0 - sr) / (1.0 - SFAR);
        float baseY = mix(yFront, yFar, tr) + kick * H * 0.008 * exp(-r * 0.4);
        float hw = halfW0 * sr;
        float cx = res.x * 0.5 + sway * (sr - 0.75) * 2.0;
        float X = (p.x - cx) / hw;
        float ax = abs(X);
        if (ax > 1.0) continue;                              // this row doesn't reach here
        float ends = smoothstep(1.0, 0.985, ax);
        float front = exp(-r * 0.35);
        float amp = A0 * sr * (1.0 + kick * 0.24 * front);
        float lw = max((0.85 + 0.85 * sr + kick * 0.9 * front) * px, 0.35);
        float sig = (3.0 + 9.0 * sr) * (H / 1440.0) * (1.0 + drop * 0.8 + kick * 0.6 * front);

        // Cheap bounds before touching the history.
        if (p.y > baseY + amp * 1.45 + quiet * amp + lw + sig * 3.0) continue;
        if (p.y < baseY - quiet * amp - lw - sig * 2.0) {
            acc += T * bg.rgb * ends;                        // deep inside this ridge's fill
            T *= 1.0 - ends;
            if (T < 0.004) break;
            continue;
        }

        vec2 hp = profile(X, r, quiet);
        float yl = baseY + amp * hp.x;
        float slope = amp * hp.y / hw;
        float d = (p.y - yl) * inversesqrt(1.0 + slope * slope);   // signed px, + above the line

        // Colour by depth, fading into fog; kicks and the drop light it up.
        float dz = r / (RF - 1.0);
        float flare = drop * (1.6 * exp(-sq((r - dropAt) / 2.5)) + 0.35);
        float bri = mix(1.0, 0.12, pow(dz, 0.6)) * (1.0 + kick * 0.9 * front + flare + build * snap * 0.3);
        vec3 tint = pal(dz);
        float heat = clamp(hp.x, 0.0, 1.0);
        vec3 lineC;
        if (dark > 0.5) {
            lineC = mix(tint, vec3(1.0), clamp((0.10 + 0.40 * heat) * bri + flare * 0.3, 0.0, 0.85)) * min(bri, 2.2);
            lineC = mix(lineC, mix(c2.rgb, c3.rgb, 0.5) * 0.25 + bg.rgb, smoothstep(0.3, 1.0, dz) * 0.55);
        } else {
            // Ink on paper: dark strokes, paling with distance, no light.
            vec3 ink = mix(tint, fg.rgb, 0.35) * 0.62;
            lineC = mix(ink, bg.rgb, smoothstep(0.0, 1.0, dz) * 0.72 - kick * 0.15 * front);
        }

        float cov = clamp(lw + 0.5 - abs(d), 0.0, 1.0) * ends;
        float fill = clamp(0.5 - d, 0.0, 1.0) * ends;
        // Self-glow above the line, behind nearer ridges only (T holds them).
        float gk = lit(faux(0.45, 0.7)) * min(bri, 2.5) * ends;
        // (vertical distance: steep walls keep a thin halo instead of stacking into streaks)
        float dv = p.y - yl;
        if (dv > 0.0) glowAcc += T * tint * gk * glow(dv, sig) * (0.6 + 0.6 * heat);
        // Under the line, the ridge's own face is lit faintly by it.
        vec3 face = bg.rgb + tint * lit(gk * 0.30 * glow(min(dv, 0.0), sig * 1.6));

        acc += T * cov * lineC;
        T *= 1.0 - cov;
        acc += T * fill * face;
        T *= 1.0 - fill;
        if (T < 0.004) break;
    }

    // ---- sky: a low haze over the horizon, flaring on the drop ----------------
    vec4 col = vec4(acc + sat3(glowAcc), 1.0 - T);
    if (dark > 0.5) {
        float hz = glow(p.y - yFar - H * 0.06, H * 0.22) * (0.05 + energy * 0.08 + swell * 0.05 + drop * 0.25);
        hz *= glow((p.x - res.x * 0.5) / res.x, 0.45);
        col.rgb += T * mix(c3.rgb, c2.rgb, 0.4) * hz;
        col.a += T * hz;
    }
    col.a = clamp(col.a + length(glowAcc) * 0.4, 0.0, 1.0);

    // Vignette: the edges fall into shadow.
    vec2 qv = qt_TexCoord0 - 0.5;
    float vig = smoothstep(0.35, 0.85, length(qv * vec2(1.0, 1.3))) * mix(0.5, 0.12, light);
    vec3 vc = mix(vec3(0.0), bg.rgb * 0.82, light);
    col.rgb = col.rgb * (1.0 - vig) + vc * vig;
    col.a = col.a + vig * (1.0 - col.a);

    fragColor = vec4(col.rgb + dither(p) * col.a, col.a) * qt_Opacity;
}
