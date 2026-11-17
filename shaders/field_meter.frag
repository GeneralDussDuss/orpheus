#version 440
// Orpheus "Field" deck (WidgetField.qml), the modulation meter. Two passes of
// one shader, with the dial's printed numerals (QML text) between them:
//   mode 0  the dial: backlit paper, the printed arcs and ticks, the hot zone.
//           Static while the lamp holds still, so the deck caches it.
//   mode 1  everything in front: the needle and its shadow, the pivot bridge,
//           the peak lamp, and the curved glass with the bezel's shade.
// Pixel space over the dial's rect, y down; premultiplied out.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float u;
    float mode;
    vec4 geo;         // pivot x, pivot y, arc radius, half span (rad)
    float lamp;       // the backlight, 0 off .. 1 on
    float needle;     // dial position 0..~1.06 (0 = rest, 1 = +3)
    float peak;       // the peak lamp, 0..1
    float light;      // 1 on a light theme
    float bloomAmt;   // 0 none (light themes, bloom off) .. 1 full
    float minor;      // 1: print the per-cent scale too
    vec4 paper;       // the dial's card
    vec4 ink;         // the printing
    vec4 hot;         // the over-zone and the peak lamp
    vec4 accent;      // the backlight's tint
    vec3 lightV;      // the stage's key light
    vec4 par;         // parallax px: the movement (xy) and the glass (zw), against the bezel
    vec2 cardOff;     // parallax px of the dial card (it sits deepest)
};

const float PI = 3.14159265;
#define LD lightV

float h12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h12(i), h12(i + vec2(1, 0)), f.x), mix(h12(i + vec2(0, 1)), h12(i + vec2(1, 1)), f.x), f.y);
}
float cov(float d) { return clamp(0.5 - d, 0.0, 1.0); }
float sdRB(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
float segD(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(1e-4, dot(ba, ba)), 0.0, 1.0);
    return length(pa - ba * h);
}
// dB on the VU law -> dial position (0 VU at 0.708, +3 at 1)
float vuPos(float db) { return pow(10.0, (db - 3.0) / 20.0); }
float angOf(float pos) { return -geo.w + 2.0 * geo.w * pos; }
vec2 dirOf(float a) { return vec2(sin(a), -cos(a)); }
vec4 over(vec4 dst, vec3 rgb, float a) { return vec4(rgb * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a)); }

void main() {
    vec2 p = qt_TexCoord0 * res;
    vec2 piv = geo.xy;
    float R = geo.z;
    vec2 q = p - piv;
    float rr = length(q);
    float a = atan(q.x, -q.y);            // 0 straight up, + clockwise
    float lit = clamp(lamp, 0.0, 1.0);

    if (mode < 0.5) {
        // ---- the dial card, lit from behind ------------------------------------
        float fib = vn(p * vec2(0.35, 1.6) / u) * 0.6 + vn(p * 1.3 / u) * 0.4;
        vec3 card = paper.rgb * (0.97 + 0.05 * fib);
        // the lamp sits low and centred behind the card: a warm pool, falling off
        vec2 lc = vec2(res.x * 0.5, res.y * 0.78);
        float pool = exp(-pow(length((p - lc) / vec2(res.x * 0.62, res.y * 0.85)), 2.0));
        vec3 glowC = mix(paper.rgb, accent.rgb, 0.22);
        vec3 offC = card * mix(0.62, 0.80, light);
        vec3 onC = card * (0.78 + 0.26 * pool) + glowC * pool * 0.22 * (1.0 - 0.6 * light);
        vec3 col = mix(offC, onC, lit);
        // corners fall away from the lamp
        vec2 e = (p / res - 0.5) * 2.0;
        col *= 1.0 - 0.30 * pow(max(abs(e.x), abs(e.y) * 0.9), 2.2) * (0.6 + 0.4 * lit);

        // ---- printing -------------------------------------------------------------
        float w = 0.55 * u;
        float pr = 0.0;   // ink coverage
        float hz = 0.0;   // hot coverage
        float a0 = angOf(0.0), a1 = angOf(1.0), aZ = angOf(vuPos(0.0));
        bool inArc = a > a0 - 0.02 && a < a1 + 0.02;
        // the main arc, thin to 0 VU, a bold hot band beyond
        if (inArc) {
            if (a < aZ) pr = max(pr, cov(abs(rr - R) - w));
            else hz = max(hz, cov(abs(rr - (R + 2.0 * u)) - 2.0 * u));
            pr = max(pr, cov(abs(rr - R) - w) * step(aZ, a));
            // the lower scale: modulation per cent
            pr = max(pr, cov(abs(rr - (R - 16.0 * u)) - w * 0.8) * step(a, a1) * step(a0, a) * minor);
        }
        // ticks at the VU marks
        for (int i = 0; i < 17; i++) {
            float db = i == 0 ? -20.0 : i == 1 ? -15.0 : i == 2 ? -10.0 : i == 3 ? -8.0 : i == 4 ? -7.0 : i == 5 ? -6.0
                     : i == 6 ? -5.0 : i == 7 ? -4.0 : i == 8 ? -3.0 : i == 9 ? -2.0 : i == 10 ? -1.0 : i == 11 ? -0.5
                     : i == 12 ? 0.0 : i == 13 ? 1.0 : i == 14 ? 2.0 : i == 15 ? 2.5 : 3.0;
            bool major = db == -20.0 || db == -10.0 || db == -7.0 || db == -5.0 || db == -3.0 || db == -2.0 || db == -1.0 || db == 0.0 || db == 1.0 || db == 2.0 || db == 3.0;
            vec2 d = dirOf(angOf(vuPos(db)));
            float len = major ? 8.0 * u : 4.5 * u;
            float dist = segD(p, piv + d * R, piv + d * (R + len)) - (major ? w * 1.2 : w * 0.9);
            if (db > 0.0) hz = max(hz, cov(dist)); else pr = max(pr, cov(dist));
        }
        // per-cent ticks inside the lower arc: every 10 %, long at 50 and 100
        {
            float pos = (a - a0) / (a1 - a0);
            float k = clamp(floor(pos * 10.0 + 0.5), 0.0, 10.0);
            vec2 d = dirOf(angOf(k / 10.0));
            float len = (k == 5.0 || k == 10.0 || k == 0.0) ? 6.0 * u : 3.5 * u;
            pr = max(pr, cov(segD(p, piv + d * (R - 16.0 * u), piv + d * (R - 16.0 * u - len)) - w * 0.9) * minor);
        }
        // ink soaks into the card a touch
        vec3 inkC = mix(ink.rgb, col, 0.12);
        col = mix(col, inkC, pr);
        vec3 hotC = hot.rgb * mix(0.8, 1.0, lit);
        col = mix(col, hotC, hz * 0.95);
        col += vec3(h12(p) - 0.5) / 255.0;
        fragColor = vec4(col, 1.0) * qt_Opacity;
        return;
    }

    // ==== mode 1: in front of the card ============================================
    vec4 o = vec4(0.0);

    // the backlight's bloom on the card (only with bloom): a soft lift centre-low
    if (bloomAmt > 0.0) {
        vec2 lc = vec2(res.x * 0.5, res.y * 0.8);
        float pool = exp(-pow(length((p - lc) / vec2(res.x * 0.45, res.y * 0.7)), 2.0));
        o = vec4(mix(paper.rgb, accent.rgb, 0.3) * pool * 0.10 * bloomAmt * lit, 0.0);
    }

    // ---- the needle -------------------------------------------------------------
    float na = angOf(needle);
    vec2 nd = dirOf(na);
    vec2 base = piv + par.xy;
    vec2 tip = base + nd * (R + 5.0 * u);
    // shadow on the card: it sits deeper, so it parallaxes with the card and
    // falls away from the key light
    {
        vec2 so = cardOff - par.xy - LD.xy / max(LD.z, 0.3) * 3.0 * u;
        float ds = segD(p - so, base, tip);
        float sa = exp(-pow(max(ds - 0.4 * u, 0.0) / (1.4 * u), 2.0)) * 0.22;
        o = over(o, vec3(0.0), sa);
    }
    {
        // tapered: thick at the counterweight, a hair at the tip
        vec2 pa = p - base, ba = tip - base;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float wn = mix(1.3 * u, 0.45 * u, h);
        float dn = length(pa - ba * h) - wn;
        vec3 nc = ink.rgb * 0.55;
        // the last fifth is lacquered in the hot colour, as on a studio meter
        nc = mix(nc, hot.rgb * 0.9, smoothstep(0.86, 0.885, h));
        // a hairline of light down one edge
        float side = dot(pa, vec2(-nd.y, nd.x));
        nc += vec3(0.14) * smoothstep(0.0, wn, -side);
        o = over(o, nc, cov(dn));
    }

    // ---- the pivot bridge: a black moulding over the bottom centre ----------------
    {
        // centred just under the card's foot, whatever the pivot's depth
        vec2 bc0 = vec2(res.x * 0.5, res.y + 26.0 * u) + par.xy;
        float br = 48.0 * u;
        vec2 q = p - bc0;
        float rr = length(q);
        float db = rr - br;
        float a2 = cov(db);
        if (a2 > 0.0) {
            vec2 g = q / max(rr, 1e-3);
            float rim = smoothstep(4.0 * u, 0.0, -db);
            vec3 n = normalize(vec3(g * rim * 1.5, 1.0));
            float spec = pow(max(dot(reflect(vec3(0, 0, -1), n), normalize(LD + vec3(0.1, 0.0, 0.0))), 0.0), 24.0);
            vec3 bc = mix(ink.rgb, vec3(0.0), 0.7) * (0.7 + 0.3 * n.z) + vec3(0.55) * spec;
            // a fine moulded ridge, and the screw that holds the movement
            bc += vec3(0.05) * cov(abs(db + 5.0 * u) - 0.4 * u) * step(q.y, 0.0);
            o = over(o, bc, a2);
        }
        // its shadow on the card
        o = over(o, vec3(0.0), (1.0 - a2) * 0.35 * exp(-max(db, 0.0) / (3.0 * u)));
    }

    // ---- the peak lamp ---------------------------------------------------------------
    {
        vec2 lc = vec2(res.x - 15.0 * u, 14.0 * u) + cardOff;
        float lr = 4.2 * u;
        float d = length(p - lc);
        vec3 off = mix(hot.rgb, vec3(0.0), 0.62);
        float pk = clamp(peak, 0.0, 1.0);
        // glow on the card first
        float halo = exp(-pow(max(d - lr, 0.0) / (7.0 * u), 2.0)) * pk * (0.35 + 0.65 * bloomAmt) * (1.0 - 0.5 * light);
        o.rgb += hot.rgb * halo * 0.55;
        o.a = max(o.a, 0.0);
        // chrome ring, then the dome
        float ring = cov(d - lr - 1.1 * u) * (1.0 - cov(d - lr));
        vec2 g = (p - lc) / max(d, 1e-3);
        o = over(o, vec3(0.35 + 0.5 * clamp(dot(g, vec2(-0.5, -0.8)), 0.0, 1.0)), ring);
        vec2 s = (p - lc) / lr;
        float dome = cov(d - lr);
        vec3 lens = mix(off, hot.rgb * 1.25 + vec3(0.25) * (1.0 - dot(s, s)) * pk, pk);
        lens *= 0.75 + 0.25 * (1.0 - dot(s, s));
        float spec = exp(-pow(length(s - vec2(-0.35, -0.4)) / 0.28, 2.0));
        lens += vec3(0.7) * spec;
        o = over(o, lens, dome);
    }

    // ---- the glass: the bezel's shade, a curved reflection, a fresnel rim --------------
    {
        vec2 e = (p - par.zw) / res - (LD.xy - vec2(-0.42, -0.62)) * vec2(0.55, 0.35);
        // the bezel overhangs the card: shade, deepest along the top
        float dEdge = -sdRB(p - res * 0.5, res * 0.5, 4.0 * u);
        float shade = exp(-dEdge / (6.0 * u)) * 0.45 + exp(-(p.y) / (14.0 * u)) * 0.22;
        o = over(o, vec3(0.0), clamp(shade, 0.0, 0.7));
        // the glass is bowed: a broad soft reflection of the studio key, bent by the curve
        float bow = (e.x - 0.5) * (e.x - 0.5) * 0.35;
        float band = smoothstep(0.02, 0.10, e.y - bow) * smoothstep(0.46, 0.20, e.y - bow);
        float diag = smoothstep(0.75, 0.15, e.x + e.y * 0.6);
        float refl = band * diag * 0.16 * mix(1.0, 0.75, light);
        // a crisp streak just under the top edge
        float streak = smoothstep(0.0, 0.02, e.y - bow * 0.6 - 0.035) * smoothstep(0.065, 0.04, e.y - bow * 0.6) * smoothstep(0.9, 0.3, e.x) * 0.35;
        // fresnel: the glass brightens toward the frame
        float fres = exp(-dEdge / (3.0 * u)) * 0.12;
        float wsum = refl + streak + fres;
        o = vec4(o.rgb * (1.0 - wsum) + vec3(1.0) * wsum, o.a + wsum * (1.0 - o.a));
    }
    fragColor = o * qt_Opacity;
}
