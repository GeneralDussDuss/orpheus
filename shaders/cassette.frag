#version 440
// Orpheus cassette deck (Cassette.qml), the "shell" look: a lit machine. A
// smoked clear-plastic cassette in a brushed well, the tape glowing from inside
// with the music, machined hubs, backlit glass meters, and a glossy plinth that
// mirrors the deck's light. Straight-on, so every part sits on the rects
// Cassette.qml's MouseAreas hit-test: the depth is all lighting. Each part is a
// signed distance; its gradient and a bevel profile give a surface normal, lit
// by a key light that drifts and swings on the kick.
//
// Self-contained (no common-block splice): its own uniform block, the helpers it
// needs copied from _common.glsl. Pixel space, y down. Premultiplied output,
// transparent where there is no machine; light over the room backdrop carries
// its own alpha (max channel) so it lands instead of clamping away.
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
    vec4 music;      // bass, swell, build, drop: 0..1, eased, 0 while paused or ejected
    vec2 hits;       // snap 0..1, kicks (a new whole number every kick)
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
float max3(vec3 v) { return max(v.x, max(v.y, v.z)); }
// `over` composites premultiplied: paint rgb at coverage a onto dst.
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
// The outward direction of rrectD at p (its gradient), for the bevels.
vec2 rrectN(vec2 p, vec4 r, float rad) {
    vec2 c = r.xy + r.zw * 0.5;
    vec2 s = vec2(p.x < c.x ? -1.0 : 1.0, p.y < c.y ? -1.0 : 1.0);
    vec2 q = abs(p - c) - r.zw * 0.5 + rad;
    if (max(q.x, q.y) > 0.0) return s * normalize(max(q, 0.0) + 1e-5);
    return q.x > q.y ? vec2(s.x, 0.0) : vec2(0.0, s.y);
}
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

// ---- light ---------------------------------------------------------------------
vec3 Lk;    // toward the key light (x right, y down, z out of the screen)
vec3 Hk;    // Blinn half vector for a viewer straight on
float glowAmt;

// A rounded bevel: depth t px in from an edge whose outward direction is g,
// over a bevel bw px wide. Steep at the edge, flat at the top.
vec3 bevel(vec2 g, float t, float bw, float k) {
    float u = clamp(t / max(bw, 1e-3), 0.0, 1.0);
    float w = 1.0 - u;
    float slope = w / sqrt(max(1.0 - w * w, 0.04));
    return normalize(vec3(g * slope * k, 1.0));
}
// Diffuse + specular on a surface; `ks` the shine, `sh` the tightness.
vec3 shade(vec3 base, vec3 n, float ks, float sh) {
    float dif = 0.55 + 0.45 * dot(n, Lk);
    float spe = pow(max(dot(n, Hk), 0.0), sh) * ks;
    return base * dif + vec3(spe) * mix(vec3(1.0), fg.rgb, 0.3);
}
// Machined metal: the bowtie highlight a spun disc throws, across the light.
float aniso(float th, float k) {
    float la = atan(Lk.y, Lk.x);
    return pow(abs(cos(th - la)), k);
}

// One drive spindle: chrome ring with six teeth turning at `a`. The teeth blur
// analytically by the frame's angular travel (`motion`), so a shuttle smears
// them toward a disc instead of strobing.
vec4 spindle(vec4 col, vec2 p, vec2 c, float rMax, float a, float motion, float hot) {
    vec2 d = p - c;
    float r = length(d);
    float rh = R_HUB * rMax;
    if (r > rh * 1.5) return col;
    float th = atan(d.y, d.x);
    vec3 dark = mix(bg.rgb, vec3(0.0), 0.4);
    col = over(col, dark, circleAA(r, rh * 1.12) * 0.95);
    vec3 metal = mix(mix(bg.rgb, fg.rgb, 0.35), c1.rgb, 0.12 + 0.4 * hot);
    vec3 ringC = metal * (0.55 + 0.6 * aniso(th, 6.0));
    col = over(col, ringC, ringAA(r, rh * 0.72, rh) * 0.95);
    float t = fract((th - a) * 6.0 / (2.0 * PI));
    float aa = 0.955 / max(r, 1.0);
    float bw = clamp(0.025 + 0.53 * motion, 0.0, 0.45);
    bw = max(bw, aa);
    float tooth = 1.0 - smoothstep(0.16 - bw, 0.16 + bw, abs(t - 0.5));
    tooth *= mix(1.0, 0.55, smoothstep(0.05, 0.45, bw));
    col = over(col, ringC * 0.9, tooth * ringAA(r, rh * 0.38, rh * 0.74) * 0.95);
    // the axle: a chrome dot with its own glint
    float ax = circleAA(r, rh * 0.24);
    vec3 an = normalize(vec3(d / max(rh * 0.24, 1.0) * 0.9, 1.0));
    col = over(col, shade(metal * 0.8, an, 0.9, 40.0), ax);
    col.rgb += c1.rgb * lit(glow(abs(r - rh), 6.0) * 0.45 * hot);
    return col;
}

// A backlit glass VU meter: a lamp-lit face with dark ink, the needle's shadow
// on the scale, a metal bezel, a sweep of reflection over the cover glass and a
// peak LED that flares into the bloom.
vec4 face(vec4 col, vec2 p, vec4 f, float v, float led, float kk) {
    if (f.z <= 0.0) return col;
    float rad = f.w * 0.10;
    float bz = max(2.0, f.w * 0.07);
    float dF = rrectD(p, f, rad);
    vec3 lamp = mix(c1.rgb, vec3(1.0, 0.74, 0.44), 0.45);
    float bright = 0.50 + 0.22 * clamp(v, 0.0, 1.0) + 0.10 * music.y + 0.12 * kk;
    // the lamp spills a little light out around the meter
    if (dF > bz) {
        col.rgb += lamp * lit(0.10 * bright * glow(dF - bz, f.w * 0.22));
        return col;
    }
    vec2 g = rrectN(p, f, rad);
    // bezel: a rounded metal frame, highlight on the edge that faces the light
    float inO = clamp(0.5 - (dF - bz), 0.0, 1.0);
    float tb = clamp(dF / bz, 0.0, 1.0);
    vec3 nb = normalize(vec3(g * (tb - 0.5) * 2.4, 1.0));
    vec3 bez = shade(mix(bg.rgb, fg.rgb, 0.20), nb, 0.8, 24.0);
    col = over(col, bez, inO * step(0.0, dF));
    float inF = clamp(0.5 - dF, 0.0, 1.0);
    if (inF <= 0.0) return col;
    // the face: warm and brightest low in the middle, where the lamp sits
    vec2 fc = (p - f.xy) / f.zw;
    float vig = glow(length((fc - vec2(0.5, 0.78)) * vec2(1.0, 1.3)), 0.75);
    vec3 faceC = lamp * lit(bright) * (0.35 + 0.75 * vig) + mix(bg.rgb, fg.rgb, 0.04);
    faceC = mix(faceC, mix(bg.rgb, fg.rgb, 0.85), light * 0.8);
    col = over(col, faceC, inF);
    vec2 piv = vec2(f.x + f.z * 0.5, f.y + f.w * 1.08);      // below the face: only the needle's top shows
    float R = f.w;
    vec2 d = p - piv;
    float r = length(d);
    float a = atan(d.x, -d.y);
    float span = radians(47.0);
    float vAt = (a + span) / (2.0 * span);
    float onScale = step(0.0, vAt) * step(vAt, 1.0);
    vec3 ink = mix(bg.rgb, vec3(0.0), 0.55);
    float arcR = R * 0.80;
    col = over(col, ink, inF * onScale * ringAA(r, arcR - 0.6, arcR + 0.6) * 0.85);
    float red = smoothstep(0.705, 0.715, vAt) * onScale;
    vec3 redC = mix(c3.rgb, vec3(0.0), 0.25);
    col = over(col, redC, inF * red * ringAA(r, arcR + 0.5, arcR + max(2.5, f.w * 0.07)));
    float ticks[10] = float[10](0.0, 0.15, 0.30, 0.42, 0.52, 0.61, 0.71, 0.80, 0.90, 1.0);
    for (int i = 0; i < 10; i++) {
        float ta = -span + 2.0 * span * ticks[i];
        vec2 dir = vec2(sin(ta), -cos(ta));
        float lng = (i == 0 || i == 6 || i == 9) ? 0.10 : 0.06;
        vec3 tc = ticks[i] > 0.705 ? redC : ink;
        col = over(col, tc, inF * segAA(p, piv + dir * arcR, piv + dir * R * (0.80 + lng), 1.3) * 0.9);
    }
    // the needle, and its soft shadow thrown on the face away from the light
    float na = -span + 2.0 * span * clamp(v, 0.0, 1.06);
    vec2 nd = vec2(sin(na), -cos(na));
    vec2 tip = piv + nd * R * 0.93;
    vec2 so = -Lk.xy * max(2.0, f.w * 0.06);
    float shd = 1.0 - smoothstep(0.0, max(2.5, f.w * 0.05), segD(p - so, piv, tip));
    col = over(col, vec3(0.0), inF * shd * 0.30);
    col = over(col, mix(ink, redC, 0.35), inF * segAA(p, piv, tip, 1.6));
    // the hood over the pivot
    float hood = boxAA(p, vec2(f.x, f.y + f.w * 0.80), vec2(f.x + f.z, f.y + f.w));
    col = over(col, shade(mix(bg.rgb, fg.rgb, 0.10), vec3(0.0, -0.25, 1.0), 0.3, 16.0), inF * hood);
    col.rgb += fg.rgb * inF * lit(0.18 * clamp(1.0 - abs(p.y - (f.y + f.w * 0.80)), 0.0, 1.0));
    // peak LED, top right
    float s = max(3.0, f.w * 0.07);
    vec2 lc = vec2(f.x + f.z - s * 2.2, f.y + s * 2.2);
    float dL = length(p - lc);
    col = over(col, mix(mix(bg.rgb, fg.rgb, 0.18), c3.rgb, led), circleAA(dL, s * 0.6));
    col.rgb += c3.rgb * faux(lit(glow(dL, s * 2.2) * led * 1.6), 0.5);
    // the cover glass: a soft top-left sheen and a sweep that crosses on the kick
    float sweep = fract(fc.x * 0.7 + fc.y * 0.35 - time * 0.06);
    float band = smoothstep(0.0, 0.05, sweep) * (1.0 - smoothstep(0.05, 0.16, sweep));
    col.rgb += vec3(1.0) * inF * lit(0.05 * band + 0.14 * kk * band
                + 0.07 * glow(length(fc - vec2(0.18, 0.12)), 0.35));
    col = over(col, vec3(0.0), rimAA(dF) * 0.5);
    return col;
}

void main() {
    float kk = kick * (1.0 - light);
    // the cabinet thumps on the kick (a couple of px: the mouse rects stay true)
    vec2 p = qt_TexCoord0 * res + vec2(0.0, -1.8 * kk);
    vec4 col = vec4(0.0);
    float bass = music.x, swell = music.y, build = music.z, drp = music.w, snap = hits.x;
    float ej = state.x, hasTape = step(0.5, state.w);
    float W = body.z, H = body.w, rMax = reel.w;

    // the key light drifts slowly and swings to a new side on every kick
    float jolt = hash(vec2(hits.y, 3.7)) - 0.5;
    Lk = normalize(vec3(-0.45 + 0.22 * sin(time * 0.11) + jolt * kk * 0.9,
                        -0.62 + 0.08 * cos(time * 0.07), 0.85));
    Hk = normalize(Lk + vec3(0.0, 0.0, 1.0));
    // how hard the tape glows: never dark, even paused
    glowAmt = (0.22 + 0.55 * bass + 0.30 * swell + 0.55 * kk + 0.45 * drp + 0.15 * snap) * (1.0 - ej);

    vec2 cL = vec2(reel.x, reel.z), cR = vec2(reel.y, reel.z);
    vec3 tapeHot = mix(c1.rgb, c2.rgb, 0.5);

    // ---- the plinth: a glossy floor below the well, mirroring the deck's light ---
    vec4 well = vec4(body.x - W * 0.025, body.y - H * 0.04, W * 1.05, H * 1.08);
    float yF = well.y + well.w;
    if (p.y > yF) {
        float dy = p.y - yF;
        float fade = exp(-dy / (H * 0.30));
        float side = 1.0 - smoothstep(W * 0.48, W * 0.62, abs(p.x - (body.x + W * 0.5)));
        vec2 m = vec2(p.x, yF - dy * 1.4);                    // mirrored, squashed toward the floor
        float refl = 0.0;
        refl += glow(length((m - cL) / vec2(1.0, 1.25)), rMax * 0.95);
        refl += glow(length((m - cR) / vec2(1.0, 1.25)), rMax * 0.95);
        vec3 rc = tapeHot * refl * glowAmt * (1.0 - ej) * hasTape;
        // the shell's silhouette, faint, and the floor's own sheen
        float sil = clamp(0.5 - rrectD(m, body, W * 0.03), 0.0, 1.0) * (1.0 - ej) * hasTape;
        rc += mix(bg.rgb, fg.rgb, 0.10) * sil * 0.35;
        rc += fg.rgb * 0.05 * glow(dy, 1.5);                  // the floor's front edge catches the light
        col.rgb += lit(1.0) * rc * fade * side * (0.55 + 0.6 * drp);
        col.a = max(col.a, 0.35 * fade * side);              // a dark gloss: it dims the room behind
    }

    // ---- the well: a brushed plate the cassette sits in ------------------------
    float dW = rrectD(p, well, W * 0.035);
    float inW = clamp(0.5 - dW, 0.0, 1.0);
    // light spills out around the machine on the beat
    col.rgb += tapeHot * lit(glow(max(dW, 0.0), W * 0.05) * (0.06 + 0.22 * kk + 0.18 * drp) * hasTape) * (1.0 - inW);
    if (inW > 0.0) {
        float brush = 0.5 + 0.5 * sin(p.y * 1.7 + hash(vec2(floor(p.y * 0.6), 1.0)) * 6.0);
        vec3 plate = mix(bg.rgb, fg.rgb, 0.035 + 0.015 * brush);
        // recessed: the edge facing the light is in shadow, the far one catches it
        vec2 gw = rrectN(p, well, W * 0.035);
        float inner = glow(min(-dW, 40.0), W * 0.03);
        plate *= 1.0 - 0.5 * inner * clamp(dot(-gw, -Lk.xy) + 0.3, 0.0, 1.0);
        plate += fg.rgb * 0.08 * inner * clamp(dot(gw, -Lk.xy), 0.0, 1.0);
        col = over(col, plate, inW * (0.9 - 0.35 * glassy));
        col = over(col, mix(bg.rgb, fg.rgb, 0.25), rimAA(dW) * 0.35);
    }
    col = spindle(col, p, cL, rMax, ang.x, ang.z, state.y == 1.0 ? 1.0 : 0.0);
    col = spindle(col, p, cR, rMax, ang.y, ang.z, state.y == 2.0 ? 1.0 : 0.0);

    // ---- the cassette: it lifts out of the well and fades on eject ------------
    float lift = 0.35 * H * ej;
    float ca = (1.0 - ej) * hasTape;
    if (ca > 0.002) {
        vec2 q = p + vec2(0.0, lift);
        vec2 b = (q - body.xy) / body.zw;
        vec2 qL = cL, qR = cR;
        float dB = rrectD(q, body, W * 0.03);
        float inB = clamp(0.5 - dB, 0.0, 1.0);

        // its shadow on the plate, longer as it rises
        vec2 so = -Lk.xy * (W * 0.012 + lift * 0.5);
        float dS = rrectD(p - so + vec2(0.0, lift * 0.2), body, W * 0.03);
        col = over(col, vec3(0.0), (1.0 - smoothstep(-W * 0.01, W * 0.03 + lift * 0.2, dS)) * 0.45 * ca * (1.0 - inB));

        float holeR = 1.15 * R_HUB * rMax;
        float hole = max(circleAA(length(q - qL), holeR), circleAA(length(q - qR), holeR));
        vec4 win = vec4(body.x + W * 0.10, body.y + H * 0.24, W * 0.80, H * 0.48);
        float dWin = rrectD(q, win, W * 0.02);
        float inWin = clamp(0.5 - dWin, 0.0, 1.0);
        vec3 emit = vec3(0.0);                               // light from inside, shining through the shell

        // -- inside: the tape packs, lit from within -----------------------------
        vec3 tapeC = mix(bg.rgb, fg.rgb, 0.10);
        float blur = smoothstep(0.0, 0.35, ang.z);
        for (int k = 0; k < 2; k++) {
            vec2 c = k == 0 ? qL : qR;
            float pr = (k == 0 ? pack.x : pack.y) * rMax;
            float a = k == 0 ? ang.x : ang.y;
            vec2 d = q - c;
            float r = length(d);
            if (r > rMax * 1.3) continue;
            float th = atan(d.y, d.x);
            float r0 = R_MIN * rMax;
            float cov = ringAA(r, r0, pr) * inB;
            float u = clamp((r - r0) / max(1.0, pr - r0), 0.0, 1.0);
            float wind = 0.5 + 0.5 * sin(r * 2.3 + hash(vec2(floor(r * 0.45), float(k))) * 6.0);
            // the tape's sheen: a spun-disc bowtie across the light
            vec3 tc = tapeC * (0.85 + 0.25 * wind) + fg.rgb * 0.22 * aniso(th, 18.0) * (1.0 - 0.5 * blur);
            col = over(col, tc, cov);
            // light caught in the pack, turning with the reel (smeared when it races)
            float rel = th - a;
            float arc = pow(0.5 + 0.5 * cos(rel), mix(10.0, 1.2, blur)) + 0.45 * pow(0.5 + 0.5 * cos(rel + PI), mix(10.0, 1.2, blur));
            vec3 ec = mix(c1.rgb, c2.rgb, u);
            emit += ec * cov * glowAmt * (0.30 + 0.70 * arc) * (0.65 + 0.35 * wind);
            emit += c2.rgb * glow(r - pr, 2.5 + rMax * 0.02) * glowAmt * 0.8 * hasTape * inB;
            // the cassette's own hub: pale plastic with three slots turning with it
            float hub = ringAA(r, holeR, r0) * inB;
            float sl = fract((th - a) * 3.0 / (2.0 * PI));
            float slot = (1.0 - smoothstep(0.035, 0.06, abs(sl - 0.5))) * ringAA(r, holeR + 1.0, r0 - 1.5);
            vec3 hn = normalize(vec3(d / max(r, 1.0) * (r < (holeR + r0) * 0.5 ? -0.5 : 0.5), 1.0));
            col = over(col, shade(mix(bg.rgb, fg.rgb, 0.30), hn, 0.5, 30.0), hub);
            col = over(col, mix(bg.rgb, vec3(0.0), 0.5), hub * slot * 0.85);
            col = over(col, vec3(0.0), ringAA(r, holeR - 0.5, holeR + 0.6) * inB * 0.6);
        }

        // -- the tape path: a thread of light, pulses running at tape speed ----
        float tw = max(1.5, W * 0.004);
        vec2 gL = vec2(body.x + W * 0.09, body.y + H * 0.86), gR = vec2(body.x + W * 0.91, body.y + H * 0.86);
        float yRun = body.y + H * 0.91 + 2.0 * ang.w * sin(time * 63.0);
        vec2 hL = vec2(body.x + W * 0.15, yRun), hR = vec2(body.x + W * 0.85, yRun);
        vec2 tL = tangent(qL, pack.x * rMax, gL, -1.0), tR = tangent(qR, pack.y * rMax, gR, 1.0);
        float dPath = min(min(segD(q, tL, gL), segD(q, tR, gR)), min(segD(q, gL, hL), segD(q, hR, gR)));
        float dRun = segD(q, hL, hR);
        float dT = min(dPath, dRun);
        col = over(col, tapeC, clamp(tw * 0.5 - dT + 0.5, 0.0, 1.0) * hasTape);
        float pulse = pow(0.5 + 0.5 * sin((q.x - pack.w) * 0.09), 14.0) * (0.3 + 0.7 * pack.z);
        float thread = glow(dT, tw * 1.6) * (0.35 + 0.65 * glowAmt);
        emit += tapeHot * thread * glowAmt * 0.9 * hasTape;
        emit += mix(c1.rgb, vec3(1.0), 0.35) * glow(dRun, tw * 2.5) * pulse * glowAmt * 1.6 * hasTape;

        // -- the shell: smoked clear plastic over all of it ---------------------
        float shellMask = inB * (1.0 - hole);
        float tint = 0.10 + 0.04 * (1.0 - glassy);
        vec3 shellC = mix(bg.rgb, mix(fg.rgb, c2.rgb, 0.35), tint);
        float bwid = W * 0.028;
        vec3 n = bevel(rrectN(q, body, W * 0.03), -dB, bwid, 1.0);
        // molded ridge around the window
        float lipW = W * 0.012;
        if (dWin > 0.0 && dWin < lipW) n = normalize(n + vec3(rrectN(q, win, W * 0.02) * (dWin / lipW - 0.5) * 1.6, 0.0));
        vec3 sc = shade(shellC, n, 0.55, 48.0);
        float fres = pow(1.0 - n.z, 1.5);
        sc += mix(fg.rgb, c2.rgb, 0.4) * fres * 0.35;
        float shellA = (0.80 - 0.30 * glassy) * (1.0 - inWin * 0.88);
        col = over(col, sc, shellMask * shellA * ca);
        // the light through it: clear in the window, scattered by the smoke elsewhere
        float transmit = mix(0.30 + 0.25 * kk, 1.0, inWin);
        col.rgb += lit(1.0) * emit * transmit * ca;

        // window glass: a slow diagonal reflection, brighter on the kick
        float diag = fract((b.x + b.y * 0.6) * 0.8 - time * 0.05);
        float dband = smoothstep(0.0, 0.08, diag) * (1.0 - smoothstep(0.08, 0.22, diag));
        col.rgb += vec3(1.0) * inWin * (1.0 - hole) * ca * lit(0.06 * dband + 0.10 * kk * dband);
        col = over(col, mix(bg.rgb, fg.rgb, 0.35), rimAA(dWin) * ca * 0.6);

        // label band: matte card, two stripes that glow faintly in the palette
        vec2 lo = vec2(body.x + W * 0.06, body.y + H * 0.06), hi = vec2(body.x + W * 0.94, body.y + H * 0.22);
        float band = boxAA(q, lo, hi);
        float grain = hash(floor(q * 0.5)) * 0.015;
        col = over(col, mix(bg.rgb, fg.rgb, 0.055 + grain), band * ca * 0.95);
        col = over(col, vec3(0.0), boxAA(q, vec2(lo.x, hi.y), vec2(hi.x, hi.y + 2.0)) * ca * 0.35);
        float st1 = boxAA(q, vec2(lo.x, body.y + H * 0.195), vec2(hi.x, body.y + H * 0.205));
        float st2 = boxAA(q, vec2(lo.x, body.y + H * 0.21), vec2(hi.x, body.y + H * 0.22));
        col = over(col, c1.rgb, st1 * ca * 0.75);
        col = over(col, c3.rgb, st2 * ca * 0.65);
        col.rgb += lit(1.0) * (c1.rgb * glow(q.y - (body.y + H * 0.20), 3.0) + c3.rgb * glow(q.y - (body.y + H * 0.215), 3.0))
                   * step(lo.x, q.x) * step(q.x, hi.x) * ca * 0.10 * (0.6 + glowAmt);

        // the lower lip: a raised trapezoid, open for the head
        float yT = body.y + H * 0.79, yB = body.y + H;
        float tY = clamp((q.y - yT) / (yB - yT), 0.0, 1.0);
        float halfW = W * mix(0.34, 0.40, tY);
        float lip = step(yT, q.y) * clamp(halfW - abs(q.x - (body.x + W * 0.5)) + 0.5, 0.0, 1.0) * inB;
        col = over(col, shade(mix(bg.rgb, fg.rgb, 0.08), vec3(0.0, 0.0, 1.0), 0.3, 30.0), lip * ca * 0.75);
        col.rgb += fg.rgb * lit(0.22) * segAA(q, vec2(body.x + W * 0.16, yT), vec2(body.x + W * 0.84, yT), 1.0) * ca;

        // screws: chrome heads
        for (int k = 0; k < 2; k++) {
            vec2 scr = vec2(body.x + W * (k == 0 ? 0.045 : 0.955), body.y + H * 0.92);
            float sr = max(1.8, W * 0.010);
            vec2 sd = q - scr;
            vec3 sn = normalize(vec3(sd / sr * 0.8, 1.0));
            col = over(col, shade(mix(bg.rgb, fg.rgb, 0.30), sn, 1.0, 40.0), circleAA(length(sd), sr) * ca);
            col = over(col, mix(bg.rgb, vec3(0.0), 0.4), segAA(q, scr - vec2(sr * 0.6), scr + vec2(sr * 0.6), 1.0) * ca);
        }
        // guide pins
        col = over(col, shade(mix(bg.rgb, fg.rgb, 0.4), vec3(0.0, 0.0, 1.0), 0.8, 30.0), circleAA(length(q - gL), max(1.5, W * 0.011)) * ca);
        col = over(col, shade(mix(bg.rgb, fg.rgb, 0.4), vec3(0.0, 0.0, 1.0), 0.8, 30.0), circleAA(length(q - gR), max(1.5, W * 0.011)) * ca);

        // -- the music on the shell ------------------------------------------
        // kick: a ring of light rolls out from the middle as the hit decays
        vec2 bc = body.xy + body.zw * 0.5;
        float rr = (1.0 - kk) * W * 0.55;
        col.rgb += tapeHot * lit(glow(length((q - bc) / vec2(1.0, 0.7)) - rr, W * 0.025) * kk * 0.35) * inB * ca;
        // build: the shell's edge lights up from the bottom as it climbs
        float climb = smoothstep(1.0 - build * 1.15, 1.05 - build * 1.15, b.y);
        col.rgb += c3.rgb * lit(glow(dB, 2.0 + W * 0.006) * build * climb * 0.9) * ca;
        // drop: a streak of light sweeps across, again and again while it lasts
        float sx = b.x + (b.y - 0.5) * 0.35;
        float sp = fract(time * 0.42) * 1.8 - 0.4;
        col.rgb += mix(c1.rgb, vec3(1.0), 0.4) * lit(glow(sx - sp, 0.045) * drp * 0.45) * inB * ca;
        // the edge highlight that sells it as a solid
        col.rgb += fg.rgb * lit(0.10) * rimAA(dB) * clamp(dot(-rrectN(q, body, W * 0.03), Lk.xy) + 0.4, 0.0, 1.0) * ca;
    }

    // ---- the deck's transport, in front: head, pinch rollers, capstans --------
    {
        vec2 hc = vec2(body.x + W * 0.5, body.y + H * 0.925);
        vec4 hr = vec4(hc - vec2(W * 0.035, H * 0.025), W * 0.07, H * 0.05);
        float hd = rrectD(p, hr, 2.0);
        vec3 hn = bevel(rrectN(p, hr, 2.0), -hd, 3.0, 1.0);
        col = over(col, shade(mix(bg.rgb, fg.rgb, 0.35), hn, 1.0, 60.0), clamp(0.5 - hd, 0.0, 1.0));
        col = over(col, mix(c2.rgb, fg.rgb, 0.3), boxAA(p, hc - vec2(W * 0.012, H * 0.025), hc + vec2(W * 0.012, -H * 0.012)));
        // the head runs hot on the kick, where tape meets it
        col.rgb += c3.rgb * lit(glow(length((p - hc) / vec2(1.6, 1.0)), W * 0.03) * (0.12 + 0.75 * kk) * hasTape * (1.0 - ej));
        for (int k = 0; k < 2; k++) {
            float sg = k == 0 ? -1.0 : 1.0;
            vec2 pc = vec2(body.x + W * (0.5 + sg * 0.27), body.y + H * 0.90);
            float pr = W * 0.025;
            vec2 pd = p - pc;
            float dp = length(pd);
            vec3 rn = normalize(vec3(pd / pr * 0.7, 1.0));
            col = over(col, shade(mix(bg.rgb, fg.rgb, 0.09), rn, 0.25, 12.0), circleAA(dp, pr) * 0.97);
            vec2 cc = vec2(body.x + W * (0.5 + sg * 0.33), body.y + H * 0.93);
            float cr = W * 0.02;
            vec2 cd = p - cc;
            float dc = length(cd);
            vec3 cmetal = mix(bg.rgb, fg.rgb, 0.30) * (0.55 + 0.7 * aniso(atan(cd.y, cd.x), 8.0));
            col = over(col, cmetal, circleAA(dc, cr));
            float ca2 = pack.w / max(1.0, cr) * sg;
            vec2 pin = cc + cr * 0.6 * vec2(cos(ca2), sin(ca2));
            col = over(col, c1.rgb, circleAA(length(p - pin), max(1.0, cr * 0.18)));
            col.rgb += c1.rgb * lit(glow(length(p - pin), cr * 0.5) * 0.25 * pack.z);
        }
    }

    // ---- the meters ----------------------------------------------------------
    col = face(col, p, faceL, vu.x, vu.z, kk);
    col = face(col, p, faceR, vu.y, vu.w, kk);

    // light over the bare backdrop carries its own coverage
    col.a = max(col.a, clamp(max3(col.rgb), 0.0, 1.0));
    col.rgb += dither(p) * col.a;
    col = clamp(col, 0.0, 1.0);
    col.rgb = min(col.rgb, vec3(col.a));
    fragColor = col * qt_Opacity;
}
