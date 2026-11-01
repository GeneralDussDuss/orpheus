#version 440
// Orpheus cassette deck (Cassette.qml): the mechanism, in the theme's colours.
// Self-contained (no common-block splice): its own uniform block, the helpers it
// needs copied from _common.glsl. Pixel space, y down. Premultiplied output,
// transparent where there is no machine, so the room light, glass and the
// stage background show around it. Every rect comes from Cassette.qml's one
// geometry object, the same one its MouseAreas hit-test against.
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
    float glassy;    // 1 under the Windows glass mode: the shell thins out
    float kick;      // cabinet thump, 0..1 (the deck's copy of the kick)
};

const float PI = 3.14159265;
const float R_MIN = 0.42;       // Cassette.js: an empty pack
const float R_HUB = 0.30;       // the spindle's tooth ring

// ---- helpers (from _common.glsl) ---------------------------------------------
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float boxAA(vec2 p, vec2 lo, vec2 hi) { vec2 d = min(p - lo, hi - p); return clamp(min(d.x, d.y) + 0.5, 0.0, 1.0); }
float glow(float d, float r) { return exp(-(d * d) / (r * r)); }
vec3 dither(vec2 p) { return vec3((hash(p) - 0.5) / 255.0); }
float lit(float x) { return x * (1.0 - 0.85 * light); }
float faux(float x, float k) { return x * (1.0 - k * bloomAmt); }
// `over` here composites premultiplied: paint rgb at coverage a onto dst.
vec4 over(vec4 dst, vec3 rgb, float a) { return vec4(rgb * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a)); }

// ---- shapes, 1 px anti-aliased -------------------------------------------------
float circleAA(float d, float r) { return clamp(r - d + 0.5, 0.0, 1.0); }
float ringAA(float d, float r0, float r1) { return clamp(min(d - r0, r1 - d) + 0.5, 0.0, 1.0); }
float segD(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(1e-4, dot(ba, ba)), 0.0, 1.0);
    return length(pa - ba * h);
}
float segAA(vec2 p, vec2 a, vec2 b, float w) { return clamp(w * 0.5 - segD(p, a, b) + 0.5, 0.0, 1.0); }
float rrectD(vec2 p, vec4 r, float rad) {
    vec2 c = r.xy + r.zw * 0.5;
    vec2 q = abs(p - c) - r.zw * 0.5 + rad;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}
float rrectAA(vec2 p, vec4 r, float rad) { return clamp(0.5 - rrectD(p, r, rad), 0.0, 1.0); }
// A 1 px rule just inside an outline at signed distance d.
float rimAA(float d) { return clamp(1.0 - abs(d + 0.75), 0.0, 1.0); }

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

// One drive spindle: a ring in c1 with six teeth turning at `a`. The teeth
// blur analytically by the frame's angular travel (`motion`), so a shuttle
// smears them toward a disc instead of strobing.
vec4 spindle(vec4 col, vec2 p, vec2 c, float rMax, float a, float motion, float hot) {
    vec2 d = p - c;
    float r = length(d);
    float rh = R_HUB * rMax;
    // the hole's shadow and floor
    col = over(col, mix(bg.rgb, fg.rgb, 0.02), circleAA(r, rh * 1.12) * 0.9);
    vec3 ringC = mix(c1.rgb, fg.rgb, 0.5 * hot);
    col = over(col, ringC, ringAA(r, rh * 0.72, rh) * 0.95);
    // teeth, from the ring inward
    float t = fract((atan(d.y, d.x) - a) * 6.0 / (2.0 * PI));
    float aa = 0.955 / max(r, 1.0);                         // 1 px, in tooth periods
    float bw = clamp(0.025 + 0.53 * motion, 0.0, 0.45);
    bw = max(bw, aa);
    float tooth = 1.0 - smoothstep(0.16 - bw, 0.16 + bw, abs(t - 0.5));
    // a blurred tooth spreads its plastic thinner over the swept arc
    tooth *= mix(1.0, 0.55, smoothstep(0.05, 0.45, bw));
    col = over(col, ringC, tooth * ringAA(r, rh * 0.38, rh * 0.74) * 0.95);
    // the axle
    col = over(col, mix(bg.rgb, fg.rgb, 0.12), circleAA(r, rh * 0.24));
    col.rgb += c1.rgb * lit(glow(abs(r - rh), 6.0) * 0.35 * hot);
    return col;
}

// A VU face: scale, red zone, needle with its lamp-lit tip, peak LED.
vec4 face(vec4 col, vec2 p, vec4 f, float v, float led, vec3 line) {
    if (f.z <= 0.0) return col;
    float rad = f.w * 0.08;
    float dF = rrectD(p, f, rad);
    float inF = clamp(0.5 - dF, 0.0, 1.0);
    col = over(col, mix(bg.rgb, fg.rgb, 0.06), inF * (0.92 - 0.3 * glassy));
    // the lamp behind the scale, breathing slowly
    vec2 lampC = vec2(f.x + f.z * 0.5, f.y + f.w * 0.62);
    col.rgb += c1.rgb * inF * lit(0.06 * (0.6 + 0.4 * sin(time * 0.7)) * glow(length((p - lampC) / vec2(f.z, f.w * 1.3)), 0.55));

    vec2 piv = vec2(f.x + f.z * 0.5, f.y + f.w * 1.08);    // below the face: only the needle's top shows
    float R = f.w;
    vec2 d = p - piv;
    float r = length(d);
    float a = atan(d.x, -d.y);                               // 0 = straight up, + clockwise
    float span = radians(47.0);
    float vAt = (a + span) / (2.0 * span);                   // where on the scale this pixel sits
    float onScale = step(0.0, vAt) * step(vAt, 1.0);
    vec3 ink = mix(fg.rgb, bg.rgb, 0.25);
    // the scale arc, and its red zone past 0 VU
    float arcR = R * 0.80;
    col = over(col, ink, inF * onScale * ringAA(r, arcR - 0.5, arcR + 0.5) * 0.8);
    float red = smoothstep(0.705, 0.715, vAt) * onScale;
    col = over(col, c3.rgb, inF * red * ringAA(r, arcR + 0.5, arcR + max(2.5, f.w * 0.06)));
    // ticks (0 VU at .71 and the ends long)
    float ticks[10] = float[10](0.0, 0.15, 0.30, 0.42, 0.52, 0.61, 0.71, 0.80, 0.90, 1.0);
    for (int i = 0; i < 10; i++) {
        float ta = -span + 2.0 * span * ticks[i];
        vec2 dir = vec2(sin(ta), -cos(ta));
        float lng = (i == 0 || i == 6 || i == 9) ? 0.10 : 0.06;
        vec3 tc = ticks[i] > 0.705 ? c3.rgb : ink;
        col = over(col, tc, inF * segAA(p, piv + dir * arcR, piv + dir * R * (0.80 + lng), 1.2));
    }
    // the needle
    float na = -span + 2.0 * span * clamp(v, 0.0, 1.06);
    vec2 nd = vec2(sin(na), -cos(na));
    vec2 tip = piv + nd * R * 0.93;
    col = over(col, fg.rgb, inF * segAA(p, piv, tip, 1.5));
    float dTip = length(p - tip);
    col.rgb += c1.rgb * inF * faux(lit(glow(dTip, 4.0) * (0.35 + 0.65 * clamp(v, 0.0, 1.0)) * 1.4), 0.5);
    // the hood over the pivot: a dark band along the face's foot
    float hood = boxAA(p, vec2(f.x, f.y + f.w * 0.80), vec2(f.x + f.z, f.y + f.w));
    col = over(col, mix(bg.rgb, fg.rgb, 0.10), inF * hood);
    col = over(col, line, inF * clamp(1.0 - abs(p.y - (f.y + f.w * 0.80)), 0.0, 1.0));
    // peak LED, top right
    float s = max(3.0, f.w * 0.07);
    vec2 lc = vec2(f.x + f.z - s * 2.2, f.y + s * 2.2);
    float dL = max(abs(p.x - lc.x), abs(p.y - lc.y));
    col = over(col, mix(mix(bg.rgb, fg.rgb, 0.18), c3.rgb, led), clamp(s * 0.5 - dL + 0.5, 0.0, 1.0));
    col.rgb += c3.rgb * faux(lit(glow(length(p - lc), s * 1.8) * led * 1.5), 0.6);
    // the rim
    col = over(col, line, rimAA(dF));
    return col;
}

void main() {
    // the cabinet thumps on the kick (dark themes only: on paper it reads as a jitter)
    vec2 p = qt_TexCoord0 * res + vec2(0.0, -0.8 * kick * (1.0 - light));
    vec4 col = vec4(0.0);
    vec3 line = mix(fg.rgb, bg.rgb, 0.72);
    float ej = state.x, hasTape = step(0.5, state.w);
    float W = body.z, H = body.w, rMax = reel.w;

    // ---- the bay: the deck's well the cassette sits in ------------------------
    vec4 well = vec4(body.x - W * 0.025, body.y - H * 0.04, W * 1.05, H * 1.08);
    float dW = rrectD(p, well, W * 0.035);
    col = over(col, mix(bg.rgb, fg.rgb, 0.025), clamp(0.5 - dW, 0.0, 1.0) * (0.55 - 0.25 * glassy));
    col = over(col, line, rimAA(dW) * 0.7);

    // the deck's own parts at rest: spindles (they show through the hub holes,
    // and stand alone in an empty well)
    vec2 cL = vec2(reel.x, reel.z), cR = vec2(reel.y, reel.z);
    col = spindle(col, p, cL, rMax, ang.x, ang.z, state.y == 1.0 ? 1.0 : 0.0);
    col = spindle(col, p, cR, rMax, ang.y, ang.z, state.y == 2.0 ? 1.0 : 0.0);

    // ---- the cassette: it lifts out of the well and fades on eject ------------
    float lift = 0.35 * H * ej;
    float ca = (1.0 - ej) * hasTape;
    if (ca > 0.002) {
        vec2 q = p + vec2(0.0, lift);                        // cassette-local, at its rest position
        vec2 b = (q - body.xy) / body.zw;                    // body-relative 0..1
        vec2 qL = cL, qR = cR;
        float dB = rrectD(q, body, W * 0.03);
        float inB = clamp(0.5 - dB, 0.0, 1.0);
        // hub holes: the shell is open there
        float holeR = 1.15 * R_HUB * rMax;
        float hole = max(circleAA(length(q - qL), holeR), circleAA(length(q - qR), holeR));
        vec3 shell = mix(bg.rgb, fg.rgb, 0.05 + 0.03 * (1.0 - glassy)) * (1.0 + 0.02 * (0.5 - b.y));
        float shellA = (0.85 - 0.30 * glassy) * ca;
        col = over(col, shell, inB * (1.0 - hole) * shellA);

        // the window onto the tape
        vec4 win = vec4(body.x + W * 0.10, body.y + H * 0.24, W * 0.80, H * 0.48);
        float dWin = rrectD(q, win, W * 0.02);
        float inWin = clamp(0.5 - dWin, 0.0, 1.0) * (1.0 - hole);
        col = over(col, mix(bg.rgb, fg.rgb, 0.015), inWin * ca * 0.9);

        // tape packs, seen through the window
        vec3 tapeC = mix(bg.rgb, fg.rgb, 0.28);
        for (int k = 0; k < 2; k++) {
            vec2 c = k == 0 ? qL : qR;
            float pr = (k == 0 ? pack.x : pack.y) * rMax;
            float a = k == 0 ? ang.x : ang.y;
            vec2 d = q - c;
            float r = length(d);
            float cov = ringAA(r, R_MIN * rMax, pr) * hasTape;
            float th = atan(d.y, d.x);
            float grain = 0.04 * sin(r * 180.0 / rMax + hash(vec2(floor(r * 0.5), float(k))) * 6.0);
            float shimmer = 0.04 * sin(th * 60.0 - a * 60.0) * pack.z;
            vec3 tc = tapeC * (1.0 + grain + shimmer);
            col = over(col, tc, cov * inWin * ca);
            // gloss toward the upper left, and the pack's own edge
            col.rgb += fg.rgb * cov * inWin * ca * lit(0.10 * glow(length(d / rMax - vec2(-0.6, -0.8) * 0.55), 0.45));
            col = over(col, mix(tapeC, bg.rgb, 0.35), ringAA(r, pr - 1.0, pr) * inWin * ca * hasTape * 0.8);
            // the spool core around the hole
            col = over(col, mix(bg.rgb, fg.rgb, 0.16), ringAA(r, holeR, R_MIN * rMax) * ca);
            col = over(col, line, ringAA(r, holeR - 0.5, holeR + 0.5) * ca);
        }
        // a slow diagonal highlight drifting across the window glass
        float diag = fract((b.x + b.y * 0.6) * 0.8 - time * 0.05);
        col.rgb += fg.rgb * inWin * ca * lit(0.06 * smoothstep(0.0, 0.08, diag) * (1.0 - smoothstep(0.08, 0.22, diag)));
        col = over(col, line, rimAA(dWin) * ca);

        // label band, with two thin stripes in the palette
        float band = boxAA(q, vec2(body.x + W * 0.06, body.y + H * 0.06), vec2(body.x + W * 0.94, body.y + H * 0.22));
        col = over(col, mix(bg.rgb, fg.rgb, 0.03 + 0.04 * (1.0 - glassy)), band * ca * 0.9);
        float st1 = boxAA(q, vec2(body.x + W * 0.06, body.y + H * 0.195), vec2(body.x + W * 0.94, body.y + H * 0.205));
        float st2 = boxAA(q, vec2(body.x + W * 0.06, body.y + H * 0.21), vec2(body.x + W * 0.94, body.y + H * 0.22));
        col = over(col, c1.rgb, st1 * ca * 0.55);
        col = over(col, c3.rgb, st2 * ca * 0.45);
        col = over(col, line, clamp(1.0 - abs(q.y - (body.y + H * 0.22) - 0.5), 0.0, 1.0)
                              * step(body.x + W * 0.06, q.x) * step(q.x, body.x + W * 0.94) * ca);

        // the lower lip: a trapezoid, wider at the foot, open for the head
        float yT = body.y + H * 0.79, yB = body.y + H;
        float tY = clamp((q.y - yT) / (yB - yT), 0.0, 1.0);
        float halfW = W * mix(0.34, 0.40, tY);
        float lip = step(yT, q.y) * clamp(halfW - abs(q.x - (body.x + W * 0.5)) + 0.5, 0.0, 1.0) * inB;
        col = over(col, mix(bg.rgb, fg.rgb, 0.07), lip * ca * 0.8);
        col = over(col, line, segAA(q, vec2(body.x + W * 0.16, yT), vec2(body.x + W * 0.84, yT), 1.0) * ca);
        col = over(col, line, segAA(q, vec2(body.x + W * 0.16, yT), vec2(body.x + W * 0.10, yB), 1.0) * ca);
        col = over(col, line, segAA(q, vec2(body.x + W * 0.84, yT), vec2(body.x + W * 0.90, yB), 1.0) * ca);

        // screws
        for (int k = 0; k < 2; k++) {
            vec2 sc = vec2(body.x + W * (k == 0 ? 0.045 : 0.955), body.y + H * 0.92);
            float sr = max(1.5, W * 0.009);
            float ds = length(q - sc);
            col = over(col, mix(c2.rgb, bg.rgb, 0.35), circleAA(ds, sr) * ca);
            col = over(col, mix(bg.rgb, fg.rgb, 0.1), segAA(q, sc - vec2(sr * 0.7, sr * 0.7), sc + vec2(sr * 0.7, sr * 0.7), 1.0) * ca);
        }

        // ---- the tape path ----------------------------------------------------
        float tw = max(1.5, W * 0.004);
        vec2 gL = vec2(body.x + W * 0.09, body.y + H * 0.86), gR = vec2(body.x + W * 0.91, body.y + H * 0.86);
        float yRun = body.y + H * 0.91 + 2.0 * ang.w * sin(time * 63.0);
        vec2 hL = vec2(body.x + W * 0.15, yRun), hR = vec2(body.x + W * 0.85, yRun);
        vec2 tL = tangent(qL, pack.x * rMax, gL, -1.0), tR = tangent(qR, pack.y * rMax, gR, 1.0);
        float path = max(segAA(q, tL, gL, tw) * inWin, segAA(q, tR, gR, tw) * inWin);
        path = max(path, max(segAA(q, gL, hL, tw), segAA(q, hR, gR, tw)));
        float run = segAA(q, hL, hR, tw);
        col = over(col, tapeC, max(path, run) * ca * hasTape);
        col.rgb += fg.rgb * run * ca * hasTape * lit(0.12 * (0.5 + 0.5 * sin((q.x - pack.w) * 0.35)) * pack.z);
        // guide pins
        col = over(col, line, circleAA(length(q - gL), max(1.5, W * 0.011)) * ca);
        col = over(col, line, circleAA(length(q - gR), max(1.5, W * 0.011)) * ca);
    }

    // ---- the deck's transport, in front: head, pinch rollers, capstans --------
    {
        vec2 hc = vec2(body.x + W * 0.5, body.y + H * 0.925);
        float hd = max(abs(p.x - hc.x) - W * 0.035, abs(p.y - hc.y) - H * 0.025);
        col = over(col, mix(bg.rgb, fg.rgb, 0.22), clamp(0.5 - hd, 0.0, 1.0));
        col = over(col, line, clamp(1.0 - abs(hd + 0.75), 0.0, 1.0));
        col = over(col, mix(c2.rgb, fg.rgb, 0.3), boxAA(p, hc - vec2(W * 0.012, H * 0.025), hc + vec2(W * 0.012, -H * 0.012)));
        for (int k = 0; k < 2; k++) {
            float sgn = k == 0 ? -1.0 : 1.0;
            vec2 pc = vec2(body.x + W * (0.5 + sgn * 0.27), body.y + H * 0.90);
            float pr = W * 0.025;
            float dp = length(p - pc);
            col = over(col, mix(bg.rgb, fg.rgb, 0.10), circleAA(dp, pr) * 0.95);
            col = over(col, line, ringAA(dp, pr - 1.0, pr));
            vec2 cc = vec2(body.x + W * (0.5 + sgn * 0.33), body.y + H * 0.93);
            float cr = W * 0.02;
            float dc = length(p - cc);
            col = over(col, mix(bg.rgb, fg.rgb, 0.18), circleAA(dc, cr));
            col = over(col, line, ringAA(dc, cr - 1.0, cr));
            float ca2 = pack.w / max(1.0, cr) * sgn;
            vec2 pin = cc + cr * 0.6 * vec2(cos(ca2), sin(ca2));
            col = over(col, c1.rgb, circleAA(length(p - pin), max(1.0, cr * 0.18)));
        }
    }

    // ---- the meters ----------------------------------------------------------
    col = face(col, p, faceL, vu.x, vu.z, line);
    col = face(col, p, faceR, vu.y, vu.w, line);

    col.rgb += dither(p) * col.a;
    col = clamp(col, 0.0, 1.0);
    col.rgb = min(col.rgb, vec3(col.a));                 // stay premultiplied after the additive light
    fragColor = col * qt_Opacity;
}
