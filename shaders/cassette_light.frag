#version 440
// Orpheus cassette deck, the light look (Cassette.qml, deckLook "light"): the
// same machine as cassette.frag, the same rects and the same moving parts, drawn
// as light instead of plastic. Neon outlines with soft halos; ghost layers of
// the shell and the packs receding behind it, so it reads as a deep hologram;
// comets riding the pack edges; light pulses running the tape path at tape
// speed; a read beam rising from the head. The music breathes through it: the
// bass swells the glow, the build drives a light around the shell and draws the
// depth in, a kick throws a shock ring off a hub, a drop pushes the depth out
// and fans the head's beam into rays.
//
// Self-contained (no common-block splice). Pixel space, y down. Premultiplied
// output, transparent where nothing is lit. Every rect comes from Cassette.qml's
// one geometry object, the one its MouseAreas hit-test against: light spills
// past the parts, the parts themselves stay put.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;      // the deck's own clock: frozen while the deck is settled
    vec2 res;
    vec4 c1; vec4 c2; vec4 c3; vec4 bg; vec4 fg;
    vec4 body;       // the cassette shell at rest, px (x, y, w, h)
    vec4 faceL;      // VU faces px; w = 0 hides the faces
    vec4 faceR;
    vec4 reel;       // cxL, cxR, cy, rMax (px, at rest)
    vec4 ang;        // angL, angR (screen rad, negative = visual CCW), motion (rad/frame), wobble
    vec4 pack;       // supplyR, takeR (fraction of rMax), spin, tapePx (tape travel, px)
    vec4 vu;         // vuL, vuR (0..1.06), ledL, ledR
    vec4 state;      // eject 0..1, hover (0 none / 1 left / 2 right), scrub 0/1, hasTape 0/1
    float light;     // 1 on a light theme: no glow, flat ink
    float bloomAmt;  // the post bloom over this view (0 off, 0.6 subtle, 1 full)
    float glassy;    // 1 under the Windows glass mode: thinner fills
    float kick;      // cabinet thump, 0..1 (the deck's copy of the kick)
    vec4 music;      // bass, swell, build, drop: 0..1, eased, 0 while paused or ejected
    vec2 hits;       // snap (0..1 mid/high onset), kicks (a counter: one more each kick)
};

const float PI = 3.14159265;
const float TAU = 6.28318531;
const float R_MIN = 0.42;       // Cassette.js: an empty pack
const float R_HUB = 0.30;       // the spindle's tooth ring

// The frame's light, summed, and the per-frame constants the helpers share.
vec3 E = vec3(0.0);
vec3 C1, C2, C3, HOT;
float U, LW;

// ---- helpers (from _common.glsl / cassette.frag) -------------------------------
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec3 dither(vec2 p) { return vec3((hash(p) - 0.5) / 255.0); }
float lit(float x) { return x * (1.0 - 0.85 * light); }
float faux(float x, float k) { return x * (1.0 - k * bloomAmt); }
float segD(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(1e-4, dot(ba, ba)), 0.0, 1.0);
    return length(pa - ba * h);
}
// distance to a segment, and how far along it (0..1) the nearest point sits
vec2 segDH(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(1e-4, dot(ba, ba)), 0.0, 1.0);
    return vec2(length(pa - ba * h), h);
}
float rrectD(vec2 p, vec4 r, float rad) {
    vec2 c = r.xy + r.zw * 0.5;
    vec2 q = abs(p - c) - r.zw * 0.5 + rad;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}
// The tangent point on circle (c, r) of a line from g, on the side `side`
// (-1 the left of the two, +1 the right): where the tape leaves a pack.
vec2 tangent(vec2 c, float r, vec2 g, float side) {
    vec2 v = g - c;
    float dd = max(length(v), r + 1e-3);
    float a0 = atan(v.y, v.x), al = acos(clamp(r / dd, -1.0, 1.0));
    vec2 t1 = c + r * vec2(cos(a0 + al), sin(a0 + al));
    vec2 t2 = c + r * vec2(cos(a0 - al), sin(a0 - al));
    return (t1.x - t2.x) * side > 0.0 ? t1 : t2;
}
// A theme colour as a light: lifted to full brightness on a dark theme (a dim
// palette entry would glow grey), kept as ink on a light one.
vec3 asLight(vec3 c) {
    float m = max(c.r, max(c.g, c.b));
    return mix(c / max(m, 0.05) * 0.95, mix(c, fg.rgb, 0.25), light);
}

// ---- light primitives ------------------------------------------------------------
// A neon tube at distance d: a w px core with a white-hot centre, a near halo
// and a wide one (the wide one gives way to the post bloom when it runs).
void tube(vec3 c, float d, float w, float k) {
    float core = clamp(w * 0.5 - d + 0.5, 0.0, 1.0);
    float nearH = exp(-d * d / (w * w * 2.5 + 2.0));
    float wide = exp(-d / (U * 1.8 + 2.0));
    E += k * (c * (0.75 * core + lit(0.45 * nearH + faux(0.22 * wide, 0.6))) + HOT * lit(0.30) * core * core);
}
// A fine line: core and near halo only (ticks, small marks).
void fine(vec3 c, float d, float w, float k) {
    float core = clamp(w * 0.5 - d + 0.5, 0.0, 1.0);
    E += k * c * (0.8 * core + lit(0.35 * exp(-d * d / (w * w * 2.0 + 1.5))));
}
// A soft blur of light: no core, a gaussian of radius r.
void haze(vec3 c, float d, float r, float k) { E += k * c * exp(-d * d / (r * r)); }

// ---- the deck's spindles ---------------------------------------------------------
// A ring of light with six spokes turning at `a`. The spokes blur by the
// frame's angular travel, so a shuttle smears them into a lit disc.
void spindle(vec2 p, vec2 c, float rMax, float a, float motion, float hot, float drive) {
    vec2 d = p - c;
    float r = length(d);
    float rh = R_HUB * rMax;
    vec3 col = mix(C1, HOT, 0.35 * hot);
    tube(col, abs(r - rh), LW, 0.65 * drive + 0.7 * hot);
    float t = fract((atan(d.y, d.x) - a) * 6.0 / TAU);
    float dx = abs(t - 0.5) * (TAU / 6.0) * r;               // px across the nearest spoke
    float blur = motion * r;                                  // px a spoke sweeps this frame
    float sp = (1.0 - smoothstep(-0.5, 0.5 + blur, dx - LW * 0.5)) / (1.0 + blur / (LW * 3.0));
    float span = smoothstep(rh * 0.30, rh * 0.42, r) * (1.0 - smoothstep(rh * 0.70, rh * 0.80, r));
    E += col * span * (0.9 * sp + lit(0.25 * exp(-dx * dx / (LW * LW * 4.0 + 2.0)))) * drive;
    haze(col, r, rh * 0.18, 0.7 * drive);                     // the axle
    if (hot > 0.0) haze(col, abs(r - rh), U * 3.0, lit(0.35 * hot));
}

// ---- a VU face: scale, red zone, the needle as a beam with a fan of afterlight ----
void face(vec2 p, vec4 f, float v, float led, float drive) {
    if (f.z <= 0.0) return;
    vec2 fc = f.xy + f.zw * 0.5;
    if (any(greaterThan(abs(p - fc), f.zw * 0.5 + U * 9.0))) return;
    float dF = rrectD(p, f, f.w * 0.08);
    float inF = clamp(0.5 - dF, 0.0, 1.0);
    fine(C2, abs(dF), LW * 0.8, 0.32);
    E += C2 * inF * lit(0.022) * (1.0 - 0.5 * glassy);

    vec2 piv = vec2(f.x + f.z * 0.5, f.y + f.w * 1.08);      // below the face: only the needle's top shows
    float R = f.w;
    vec2 d = p - piv;
    float r = length(d);
    float a = atan(d.x, -d.y);                                // 0 = straight up, + clockwise
    float span = radians(47.0);
    float vAt = (a + span) / (2.0 * span);
    float onScale = smoothstep(-0.004, 0.004, vAt) * (1.0 - smoothstep(0.996, 1.004, vAt));
    float arcR = R * 0.80;
    fine(mix(C1, C2, 0.5), abs(r - arcR), LW * 0.7, 0.5 * inF * onScale);
    float red = smoothstep(0.700, 0.720, vAt) * onScale;
    float rw = max(1.5, f.w * 0.05);
    fine(C3, abs(r - arcR - rw * 0.9), rw, inF * red * (0.55 + 0.6 * led));
    float ticks[10] = float[10](0.0, 0.15, 0.30, 0.42, 0.52, 0.61, 0.71, 0.80, 0.90, 1.0);
    for (int i = 0; i < 10; i++) {
        float ta = -span + 2.0 * span * ticks[i];
        vec2 dir = vec2(sin(ta), -cos(ta));
        float lng = (i == 0 || i == 6 || i == 9) ? 0.10 : 0.06;
        vec3 tc = ticks[i] > 0.705 ? C3 : mix(C1, C2, 0.5);
        fine(tc, segD(p, piv + dir * arcR, piv + dir * R * (0.80 + lng)), LW * 0.7, 0.55 * inF);
    }
    // the needle; its foot dims into the hood band along the face's bottom
    float lv = clamp(v, 0.0, 1.06);
    float na = -span + 2.0 * span * lv;
    vec2 nd = vec2(sin(na), -cos(na));
    vec2 tip = piv + nd * R * 0.93;
    float hood = 1.0 - 0.75 * smoothstep(f.y + f.w * 0.78, f.y + f.w * 0.84, p.y);
    vec3 nc = mix(C1, C3, smoothstep(0.69, 0.75, lv));
    tube(mix(nc, HOT, 0.25), segD(p, piv, tip), LW * 1.1, inF * hood * (0.8 + 0.5 * lv) * drive);
    haze(mix(nc, HOT, 0.5), length(p - tip), U * 1.4, inF * faux(lit(0.35 + 0.9 * lv), 0.4));
    // the afterlight: a fan from the scale's start up to the needle, hottest at it
    float behind = (na - a) * r;                              // px back from the needle, along the arc
    float fan = smoothstep(-1.0, 1.0, behind) * smoothstep(-0.02, 0.02, vAt)
              * (0.25 + 0.75 * exp(-max(behind, 0.0) / (R * 0.22)))
              * smoothstep(R * 0.30, R * 0.62, r) * (1.0 - smoothstep(arcR - 1.0, arcR + 1.0, r));
    E += mix(nc, C2, 0.3) * fan * inF * hood * lit(0.16) * (0.35 + lv) * drive;
    fine(C2, abs(p.y - (f.y + f.w * 0.80)), LW * 0.6, 0.22 * inF);
    // peak LED, top right
    float s = max(3.0, f.w * 0.07);
    vec2 lc = vec2(f.x + f.z - s * 2.2, f.y + s * 2.2);
    float dL = length(p - lc);
    E += C3 * clamp(s * 0.45 - dL + 0.5, 0.0, 1.0) * (0.22 + 1.1 * led);
    haze(C3, dL, s * 1.8, faux(lit(1.2 * led), 0.5));
}

void main() {
    U = max(0.5, body.z / 92.0);                              // one deck unit, px
    LW = max(1.0, U * 0.30);                                  // the main line's width
    C1 = asLight(c1.rgb); C2 = asLight(c2.rgb); C3 = asLight(c3.rgb);
    HOT = mix(vec3(1.0), fg.rgb, light);
    float kk = clamp(kick, 0.0, 1.0);
    float bass = music.x, swell = music.y, build = music.z, drop = music.w, snap = hits.x;
    // a small thump on the kick (dark themes only)
    vec2 p = qt_TexCoord0 * res + vec2(0.0, -1.2 * kk * (1.0 - light));
    float drive = 1.0 + 0.45 * kk + 0.55 * drop + 0.25 * bass;   // every light's gain
    float ej = state.x, hasTape = step(0.5, state.w);
    float W = body.z, H = body.w, rMax = reel.w;
    vec2 bc = body.xy + body.zw * 0.5;
    vec2 cL = vec2(reel.x, reel.z), cR = vec2(reel.y, reel.z);
    float thin = 1.0 - 0.5 * glassy;                         // fills thin out under glass

    // ---- the room glow the deck stands in ------------------------------------------
    {
        vec2 d = (p - bc - vec2(0.0, H * 0.05)) / vec2(W * 0.66, H * 0.82);
        float g = exp(-dot(d, d) * 1.5);
        vec3 gc = mix(C2, C1, 0.5 + 0.5 * sin(time * 0.11)) ;
        gc = mix(gc, C3, 0.45 * drop);
        E += gc * g * lit(faux(0.035 + 0.07 * swell + 0.06 * bass + 0.20 * drop, 0.3)) * thin;
    }

    // ---- the bay: a faint frame of light where the cassette sits ---------------------
    vec4 well = vec4(body.x - W * 0.025, body.y - H * 0.04, W * 1.05, H * 1.08);
    fine(C2, abs(rrectD(p, well, W * 0.035)), LW * 0.7, 0.20);

    // the deck's own spindles (they stand alone in an empty well)
    spindle(p, cL, rMax, ang.x, ang.z, state.y == 1.0 ? 1.0 : 0.0, drive);
    spindle(p, cR, rMax, ang.y, ang.z, state.y == 2.0 ? 1.0 : 0.0, drive);

    // ---- the cassette: it lifts out of the well and fades on eject -----------------
    float lift = 0.35 * H * ej;
    float ca = (1.0 - ej) * hasTape;
    if (ca > 0.002) {
        vec2 q = p + vec2(0.0, lift);                         // cassette-local, at its rest position
        vec2 b = (q - body.xy) / body.zw;
        float prL = pack.x * rMax, prR = pack.y * rMax;

        // depth: ghost layers of the shell and the packs behind it, toward a
        // vanishing point above. The build draws them in, a drop throws them out.
        float dz = 0.032 + 0.016 * bass + 0.075 * drop - 0.014 * build + 0.02 * kk;
        vec2 vp = bc + vec2(0.0, -1.4 * H);
        for (int k = 1; k <= 3; k++) {
            float fk = float(k);
            float s = 1.0 / (1.0 + fk * dz);
            vec2 g = vp + (q - vp) / s;                       // this pixel in the layer's own frame
            float soft = LW * (1.0 + fk * 1.2);
            float fall = exp(-fk * 0.75) * ca;
            vec3 ec = mix(C2, C3, fk / 3.0);
            float dd = abs(rrectD(g, body, W * 0.03)) * s;
            E += ec * fall * (0.55 * exp(-dd * dd / (soft * soft)) + lit(faux(0.18 * exp(-dd / (U * 2.5)), 0.5)));
            float dl = abs(length(g - cL) - prL) * s, dr = abs(length(g - cR) - prR) * s;
            float dp = min(dl, dr);
            E += mix(C1, ec, 0.5) * fall * 0.45 * exp(-dp * dp / (soft * soft)) * hasTape;
        }

        // the shell: a faint body of light, a neon outline with a light running round it
        float dB = rrectD(q, body, W * 0.03);
        float inB = clamp(0.5 - dB, 0.0, 1.0);
        vec3 shellC = mix(C2, C1, smoothstep(0.0, 1.0, b.x));
        E += shellC * inB * lit(0.022) * ca * thin;
        vec2 o = (q - bc) / body.zw;
        float th = atan(o.y, o.x);
        // (fixed speeds: a phase of time * music would race as the music changes)
        float chase = pow(0.5 + 0.5 * cos(th - time * 0.35), 14.0)
                    + build * (pow(0.5 + 0.5 * cos(th - time * 2.4), 14.0) + pow(0.5 + 0.5 * cos(th + PI - time * 2.4), 14.0));
        tube(mix(shellC, HOT, 0.35 * chase), abs(dB), LW, ca * (0.75 * drive + chase * (0.5 + 1.3 * build)));

        // the window onto the tape
        vec4 win = vec4(body.x + W * 0.10, body.y + H * 0.24, W * 0.80, H * 0.48);
        float dWin = rrectD(q, win, W * 0.02);
        float inWin = clamp(0.5 - dWin, 0.0, 1.0);
        fine(mix(C1, C2, 0.4), abs(dWin), LW * 0.8, 0.45 * ca * drive);
        E += C1 * inWin * lit(0.012) * ca * thin;

        // the label band: an outline and two light bars that follow the meters
        vec4 band = vec4(body.x + W * 0.06, body.y + H * 0.06, W * 0.88, H * 0.16);
        fine(C2, abs(rrectD(q, band, U * 0.6)), LW * 0.6, 0.22 * ca);
        float bx = step(body.x + W * 0.06, q.x) * step(q.x, body.x + W * 0.94);
        float wave = 0.75 + 0.25 * sin(b.x * 11.0 - time * 1.3);
        tube(C1, abs(q.y - (body.y + H * 0.200)), LW * 0.9, bx * ca * wave * (0.35 + 0.7 * vu.x));
        tube(C3, abs(q.y - (body.y + H * 0.215)), LW * 0.9, bx * ca * wave * (0.30 + 0.7 * vu.y));

        // the lower lip: a trapezoid, open for the head
        float yT = body.y + H * 0.79, yB = body.y + H;
        float dLip = min(segD(q, vec2(body.x + W * 0.16, yT), vec2(body.x + W * 0.84, yT)),
                     min(segD(q, vec2(body.x + W * 0.16, yT), vec2(body.x + W * 0.10, yB)),
                         segD(q, vec2(body.x + W * 0.84, yT), vec2(body.x + W * 0.90, yB))));
        fine(C2, dLip, LW * 0.8, 0.40 * ca);
        // screws: two points of light
        for (int k = 0; k < 2; k++) {
            vec2 sc = vec2(body.x + W * (k == 0 ? 0.045 : 0.955), body.y + H * 0.92);
            haze(mix(C2, HOT, 0.3), length(q - sc), max(1.2, U * 0.55), 0.6 * ca);
        }

        // ---- the packs: discs of light, a hot edge, comets riding it ---------------
        float tailL = 0.12 + 1.4 * pack.z;                    // the comet's tail, rad: long while the motor runs
        float sig = U * 0.9 + ang.z * rMax * 0.6;             // and its head, px: smeared by a shuttle
        for (int k = 0; k < 2; k++) {
            vec2 c = k == 0 ? cL : cR;
            float pr = k == 0 ? prL : prR;
            float a = k == 0 ? ang.x : ang.y;
            float hot = state.y == float(k + 1) ? 1.0 : 0.0;
            vec2 d = q - c;
            float r = length(d);
            float ta = atan(d.y, d.x);
            float r0 = R_MIN * rMax;
            // the pack: brighter toward its edge, a faint grain of wound layers,
            // and a slow glint that turns with the reel
            float cov = smoothstep(r0 - 0.5, r0 + 0.5, r) * (1.0 - smoothstep(pr - 0.5, pr + 0.5, r));
            float gr = clamp((r - r0) / max(1.0, pr - r0), 0.0, 1.0);
            float per = U * 1.1;
            float grain = 0.5 + 0.5 * cos(r * TAU / per);
            float glint = pow(0.5 + 0.5 * cos(ta - a - 0.8), 6.0) * (1.0 - smoothstep(0.08, 0.4, ang.z));
            float fill = (0.035 + 0.11 * gr * gr) * (1.0 + 0.30 * grain * smoothstep(3.0, 6.0, per))
                       * (0.75 + 0.8 * glint) * (1.0 + 0.7 * bass);
            E += mix(C1, C2, 0.35 * (1.0 - gr)) * fill * cov * lit(1.0) * ca * thin;
            // the edge, and the spool's core
            vec3 ecol = mix(C1, HOT, 0.25 * hot);
            tube(ecol, abs(r - pr), LW * 1.15, ca * (0.85 * drive + 0.6 * hot + 0.4 * state.z * hot));
            fine(mix(C1, C2, 0.5), abs(r - r0), LW * 0.7, 0.35 * ca);
            // three comets on the edge; forward play turns the reels toward
            // smaller angles, so the tails lie on the larger side. The tail
            // grows out of the head and fades before the next one: no seams.
            float seg = TAU / 3.0;
            float u = mod(ta - a - float(k) * 0.6, seg);        // angle back from the head ahead
            float ds = u < seg * 0.5 ? u : u - seg;            // signed angle from the nearest head
            float ax = ds * pr;
            float sigA = sig / max(pr, 1.0);
            float head = exp(-ax * ax / (sig * sig)) * exp(-(r - pr) * (r - pr) / (LW * LW * 3.0 + 1.0));
            float tail = smoothstep(0.0, 1.5 * sigA, u) * exp(-u / tailL) * (1.0 - smoothstep(seg * 0.55, seg - sigA, u))
                       * exp(-(r - pr) * (r - pr) / (LW * LW * 1.6 + 0.8));
            E += mix(C1, HOT, 0.55) * (1.3 * head + 0.75 * tail) * ca * drive;
            // the hover ring: a grab halo just outside the pack
            if (hot > 0.0) tube(mix(C1, HOT, 0.4), abs(r - rMax * 1.04), LW * 0.8, ca * (0.45 + 0.5 * state.z));
        }

        // ---- a kick throws a shock ring off a hub: which hub and which colour
        // change from kick to kick
        if (kk > 0.004) {
            float kc = floor(hits.y + 0.5);
            float pick = mod(kc, 4.0);
            float hue = mod(kc, 3.0);
            vec3 kcol = hue < 0.5 ? C1 : (hue < 1.5 ? C2 : C3);
            float age = 1.0 - kk;
            float rs = rMax * (0.45 + 1.45 * age);
            float sw = LW * (1.0 + 6.0 * age) + U * 0.4;
            float amp = kk * kk * (0.75 + 0.6 * drop) * ca;
            float wl = pick == 2.0 ? 0.0 : 1.0, wr = pick == 1.0 ? 0.0 : 1.0;
            float dl = abs(length(q - cL) - rs), dr = abs(length(q - cR) - rs);
            E += kcol * amp * (wl * exp(-dl * dl / (sw * sw)) + wr * exp(-dr * dr / (sw * sw)));
        }

        // ---- the tape path: a thread of light, pulses running it at tape speed ----
        float tw = LW * 0.9;
        vec2 gL = vec2(body.x + W * 0.09, body.y + H * 0.86), gR = vec2(body.x + W * 0.91, body.y + H * 0.86);
        float yRun = body.y + H * 0.91 + 2.0 * ang.w * sin(time * 63.0);
        vec2 hL = vec2(body.x + W * 0.15, yRun), hR = vec2(body.x + W * 0.85, yRun);
        vec2 tL = tangent(cL, prL, gL, -1.0), tR = tangent(cR, prR, gR, 1.0);
        vec2 P[6] = vec2[6](tL, gL, hL, hR, gR, tR);
        float sp = U * 7.0, s0 = 0.0;
        vec3 thread = mix(C2, C1, 0.5);
        for (int i = 0; i < 5; i++) {
            vec2 dh = segDH(q, P[i], P[i + 1]);
            float len = length(P[i + 1] - P[i]);
            float f = fract((s0 + dh.y * len - pack.w) / sp);
            float pulse = pow(f, 5.0) * (1.0 - smoothstep(0.90, 1.0, f));
            fine(thread, dh.x, tw, 0.55 * ca * drive);
            E += mix(C1, HOT, 0.4) * pulse * exp(-dh.x * dh.x / (tw * tw * 2.0 + 1.0)) * ca * (0.9 + 0.8 * snap) * drive;
            s0 += len;
        }
        haze(mix(C2, HOT, 0.3), length(q - gL), max(1.5, W * 0.011), (0.8 + snap) * ca);
        haze(mix(C2, HOT, 0.3), length(q - gR), max(1.5, W * 0.011), (0.8 + snap) * ca);
    }

    // ---- the read beam: a column of light rising from the head; a drop fans it
    // into rays. Only while a cassette is in.
    float loaded = (1.0 - ej) * hasTape;
    if (loaded > 0.002) {
        vec2 hp = vec2(bc.x, body.y + H * 0.90);
        vec2 v = p - hp;
        if (v.y < 0.0) {
            float dist = length(v);
            float phi = atan(v.x, -v.y);
            float col = exp(-phi * phi / 0.006) * exp(-dist / (H * 0.55));
            vec3 bcol = mix(C1, C3, 0.3);
            E += bcol * col * lit(faux(0.05 + 0.16 * bass + 0.30 * kk, 0.3)) * loaded;
            if (drop > 0.004) {
                float x = phi * 11.0 + 0.6 * sin(time * 0.23);
                float rays = pow(max(0.0, cos(x)), 12.0);
                float ri = mod(floor(x / TAU + 0.5), 3.0);
                vec3 rc = ri < 0.5 ? C1 : (ri < 1.5 ? C3 : C2);
                E += rc * rays * exp(-phi * phi / 1.1) * exp(-dist / (H * 0.9)) * smoothstep(0.0, U * 5.0, dist)
                   * lit(faux(0.40, 0.3)) * drop * loaded;
            }
        }
    }

    // ---- the deck's transport, in front: head, pinch rollers, capstans --------------
    {
        vec2 hc = vec2(body.x + W * 0.5, body.y + H * 0.925);
        float hd = max(abs(p.x - hc.x) - W * 0.035, abs(p.y - hc.y) - H * 0.025);
        fine(C2, abs(hd), LW * 0.8, 0.6 * drive);
        // the read gap glows with what it reads
        vec2 gap = vec2(hc.x, hc.y - H * 0.025);
        haze(mix(C1, HOT, 0.5), length(p - gap), U * 1.3, loaded * (0.45 + 0.6 * bass + 0.9 * kk + 0.4 * snap));
        for (int k = 0; k < 2; k++) {
            float sgn = k == 0 ? -1.0 : 1.0;
            vec2 pc = vec2(body.x + W * (0.5 + sgn * 0.27), body.y + H * 0.90);
            float pr = W * 0.025;
            fine(C2, abs(length(p - pc) - pr), LW * 0.7, 0.45);
            vec2 cc = vec2(body.x + W * (0.5 + sgn * 0.33), body.y + H * 0.93);
            float cr = W * 0.02;
            fine(mix(C1, C2, 0.5), abs(length(p - cc) - cr), LW * 0.7, 0.5);
            float ca2 = pack.w / max(1.0, cr) * sgn;
            vec2 pin = cc + cr * 0.6 * vec2(cos(ca2), sin(ca2));
            haze(mix(C1, HOT, 0.4), length(p - pin), max(1.0, cr * 0.2), 0.9 * drive);
        }
    }

    // ---- the meters ------------------------------------------------------------------
    face(p, faceL, vu.x, vu.z, drive);
    face(p, faceR, vu.y, vu.w, drive);

    // ---- out: a soft shoulder, alpha that covers the light, premultiplied --------------
    vec3 m = 1.0 - exp(-E * 1.35);
    vec4 col = vec4(m, max(m.r, max(m.g, m.b)));
    col.rgb += dither(p) * col.a;
    col = clamp(col, 0.0, 1.0);
    col.rgb = min(col.rgb, vec3(col.a));
    fragColor = col * qt_Opacity;
}
