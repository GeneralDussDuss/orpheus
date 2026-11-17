#version 440
// Orpheus "Field" deck (WidgetField.qml), the moving hardware. One shader, one
// small ShaderEffect per part, picked by `part`:
//   0 knob     the knurled push-to-play knob: spun cap, sinks on a press, an
//              index that clicks round, a light-pipe ring that breathes with the beat
//   1 lever    a prev/next key: machined top, a front wall that shortens as it travels
//   2 toggle   a bat-handle toggle on a hex nut; `val` -1 (down) .. 1 (up)
//   3 lamp     a jewelled indicator lamp in a chrome bezel
//   4 pointer  the tape scale's hot cursor
//   5 glass    the sapphire over the art: the bezel's shade, a glare, a rim
// Each draws its own shadow inside its padded rect. Pixel space, y down;
// premultiplied out.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float u;
    float part;
    float press;      // 0..1
    float hover;      // 0..1
    float val;        // knob: turn (rad); toggle: -1..1; pointer: grow 0..1
    float on;         // lamp / light-pipe, 0..1
    float beat;       // 0..1
    float light;
    float bloomAmt;
    float icon;       // 0 none, 1 play, 2 pause, 3 previous, 4 next
    vec4 dims;        // knob: radius, well radius, pad; lever: pad, depth; lamp: radius
    vec4 steel;
    vec4 ink;
    vec4 lampC;       // the lamp's / light-pipe's colour
    vec4 hot;
    vec3 lightV;      // the stage's key light, swung by the lean
};

#define LD lightV

float h12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h12(i), h12(i + vec2(1, 0)), f.x), mix(h12(i + vec2(0, 1)), h12(i + vec2(1, 1)), f.x), f.y);
}
float cov(float d) { return clamp(0.5 - d, 0.0, 1.0); }
float sdRB(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
float sdTri(vec2 p, vec2 a, vec2 b, vec2 c) {
    vec2 e0 = b - a, e1 = c - b, e2 = a - c;
    vec2 v0 = p - a, v1 = p - b, v2 = p - c;
    vec2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    vec2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    vec2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    vec2 d = min(min(vec2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                     vec2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                     vec2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
vec4 over(vec4 dst, vec3 rgb, float a) { return vec4(rgb * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a)); }

float studio(vec3 r, float rough) {
    vec3 kd = normalize(LD + vec3(0.08, 0.10, 0.10));   // the softbox rides with the key light
    float key = exp(-(1.0 - dot(r, kd)) / (0.025 + 1.25 * rough));
    float strip = exp(-abs(r.x - 0.62) / (0.02 + 0.3 * rough)) * smoothstep(0.9, 0.2, abs(r.y + 0.1));
    float sky = smoothstep(0.45, -0.75, r.y);
    return 0.08 + 0.26 * sky + 1.0 * key + 0.28 * strip;
}
vec3 metal(vec3 alb, vec3 n, vec2 p, float rough) {
    vec3 v = normalize(vec3((res * vec2(0.5, 0.2) - p) * 0.35, res.y * 2.5 + 200.0));
    vec3 r = reflect(-v, n);
    float dif = max(dot(n, normalize(LD)), 0.0);
    return alb * (0.16 + 0.24 * dif + 0.78 * studio(r, rough));
}
vec3 bev(vec2 g, float s) { return normalize(vec3(g * s, 1.0)); }

// The transport icons, as distances (centred on c, size s).
float iconD(vec2 p, vec2 c, float s, float kind) {
    vec2 q = (p - c) / s;
    float d = 1e3;
    if (kind < 1.5) d = sdTri(q, vec2(-0.38, -0.5), vec2(-0.38, 0.5), vec2(0.5, 0.0)) - 0.04;
    else if (kind < 2.5) d = min(sdRB(q - vec2(-0.26, 0.0), vec2(0.12, 0.48), 0.04), sdRB(q - vec2(0.26, 0.0), vec2(0.12, 0.48), 0.04));
    else {
        if (kind > 3.5) q.x = -q.x;
        d = min(sdRB(q - vec2(-0.42, 0.0), vec2(0.07, 0.42), 0.03),
                min(sdTri(q, vec2(0.02, -0.42), vec2(0.02, 0.42), vec2(-0.32, 0.0)),
                    sdTri(q, vec2(0.46, -0.42), vec2(0.46, 0.42), vec2(0.12, 0.0))) - 0.03);
    }
    return d * s;
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    vec3 L = normalize(LD);
    vec3 alb = steel.rgb;
    vec4 o = vec4(0.0);
    int k = int(part + 0.5);

    if (k == 0) {
        // ================= the knob ====================================================
        vec2 c = res * 0.5;
        float kr = dims.x * (1.0 - 0.035 * press);
        float wr = dims.y;
        vec2 q = p - c;
        float d = length(q);
        vec2 g = q / max(d, 1e-3);
        // the light-pipe ring at the foot of the well
        float lr = wr - 1.7 * u;
        float lon = clamp(on, 0.0, 1.0) * (0.6 + 0.4 * beat);
        {
            float ring = cov(abs(d - lr) - 0.8 * u);
            vec3 offc = mix(lampC.rgb, vec3(0.0), 0.78);
            vec3 onc = lampC.rgb * 1.15 + vec3(0.25) * lon;
            o = over(o, mix(offc, onc, lon), ring * cov(d - wr));
            float halo = exp(-pow((d - lr) / (3.2 * u), 2.0)) * lon * (0.25 + 0.75 * bloomAmt) * (1.0 - 0.6 * light);
            o.rgb += lampC.rgb * halo * 0.45 * cov(d - wr - 0.5);
            o.a = max(o.a, 0.0);
        }
        // the knob's shadow in the well (less of it when pressed in)
        {
            vec2 so = -LD.xy / max(LD.z, 0.3) * 3.2 * u * (1.0 - 0.6 * press);
            float ds = length(q - so) - kr;
            float sa = 0.75 * exp(-pow(max(ds, 0.0) / (3.2 * u), 1.4)) * cov(d - wr);
            o = over(o, vec3(0.0), sa * (1.0 - cov(d - kr)));
        }
        float a = cov(d - kr);
        if (a > 0.0) {
            float capR = kr * 0.72;
            float chamW = 2.4 * u;
            float ang = atan(q.y, q.x) - val;
            vec3 col;
            if (d > capR + chamW) {
                // knurled skirt: straight ridges, rolling off at the rim
                float N = floor(kr * 1.35 / u);
                float ph = ang * N;
                vec2 t = vec2(-g.y, g.x);
                float roll = smoothstep(kr - 3.5 * u, kr, d);
                vec3 n = normalize(vec3(t * sin(ph) * 0.75 + g * (0.25 + roll * 1.6), 1.0));
                vec3 ka = alb * (0.70 + 0.12 * cos(ph));
                col = metal(ka, n, p, 0.16);
                col *= 0.80 + 0.20 * smoothstep(-1.0, 0.6, cos(ph));
                // the land between skirt and cap: a dark step
                col *= 1.0 - 0.6 * cov(d - capR - chamW - 0.9 * u);
            } else if (d > capR) {
                // the polished chamfer round the cap
                vec3 n = bev(g, 1.5);
                col = metal(alb * 1.08, n, p, 0.02);
            } else {
                // the spun cap: fine rings, a bow-tie highlight on the light's axis, a shallow dish
                float rings = vn(vec2(d * 2.2 / u, 0.5)) * 0.6 + vn(vec2(d * 7.0 / u, 3.5)) * 0.4;
                vec3 n = normalize(vec3(-q / capR * 0.10, 1.0));
                vec3 cc = metal(alb * (0.97 + 0.06 * rings), n, p, 0.25);
                float phi = atan(q.y, q.x);
                float lphi = atan(L.y, L.x);
                float bow = exp(-pow(sin(phi - lphi) / 0.22, 2.0)) * smoothstep(0.0, capR * 0.5, d);
                cc += alb * bow * (0.30 + 0.12 * rings);
                cc *= 1.0 + 0.06 * hover - 0.12 * press;
                // the engraved transport icon
                float id = iconD(p, c, capR * 0.62, icon);
                float idUp = iconD(p - vec2(0.0, 0.9 * u), c, capR * 0.62, icon);
                cc = mix(cc, ink.rgb * 0.5 + cc * 0.12, cov(id) * 0.95);
                cc += alb * 0.25 * clamp(cov(idUp) - cov(id), 0.0, 1.0);
                // the index: an engraved notch at the cap's edge that clicks round
                vec2 idir = vec2(sin(val), -cos(val));
                vec2 i0 = idir * capR * 0.70, i1 = idir * capR * 0.90;
                vec2 qa = q - i0, ia = i1 - i0;
                float nd = length(qa - ia * clamp(dot(qa, ia) / dot(ia, ia), 0.0, 1.0)) - 0.9 * u;
                cc = mix(cc, mix(ink.rgb * 0.5, lampC.rgb, 0.65 * lon), cov(nd));
                col = cc;
            }
            o = over(o, col, a);
        }
    } else if (k == 1) {
        // ================= a lever key ==================================================
        float pad = dims.x;
        float depth = dims.y;
        float travel = press * (depth - 1.0 * u);
        vec4 kr = vec4(pad, pad + travel, res.x - 2.0 * pad, res.y - 2.0 * pad - depth);
        vec2 kc = kr.xy + kr.zw * 0.5;
        float r = 4.0 * u;
        // shadow on the well's floor
        float base = res.y - pad;
        vec2 sc = vec2(kc.x + 1.5 * u, (kr.y + base) * 0.5 + 2.0 * u);
        float ds = sdRB(p - sc, vec2(kr.z * 0.5, (base - kr.y) * 0.5), r);
        o = over(o, vec3(0.0), 0.6 * exp(-max(ds, 0.0) / (2.5 * u * (1.0 - 0.5 * press))));
        // the front wall, from the top face down to the floor
        float wallH = base - (kr.y + kr.w);
        vec2 wc = vec2(kc.x, kr.y + kr.w + wallH * 0.5 - r * 0.5);
        float dw = sdRB(p - wc, vec2(kr.z * 0.5, wallH * 0.5 + r * 0.5), r);
        if (dw < 1.0) {
            float t = clamp((p.y - (kr.y + kr.w)) / max(wallH, 1.0), 0.0, 1.0);
            vec3 n = normalize(vec3((p.x - kc.x) / kr.z * 0.6, 0.9, 0.45));
            vec3 wcol = metal(alb * 0.85, n, p, 0.2) * (0.55 - 0.25 * t);
            o = over(o, wcol, cov(dw));
        }
        // the top face
        float dt = sdRB(p - kc, kr.zw * 0.5, r);
        if (dt < 1.0) {
            vec2 e = vec2(0.5, 0.0);
            vec2 g = normalize(vec2(sdRB(p + e - kc, kr.zw * 0.5, r) - sdRB(p - e - kc, kr.zw * 0.5, r),
                                    sdRB(p + e.yx - kc, kr.zw * 0.5, r) - sdRB(p - e.yx - kc, kr.zw * 0.5, r)) + 1e-6);
            float ty = (p.y - kc.y) / (kr.w * 0.5);
            float br = vn(vec2(p.x * 0.03 / u, p.y * 1.4 / u));
            vec3 n = normalize(vec3(0.0, ty * 0.28 + (br - 0.5) * 0.08, 1.0));
            float rough = 0.18;
            if (-dt < 1.4 * u) { n = bev(g, 1.4); rough = 0.03; }
            vec3 tc = metal(alb * (1.0 + 0.04 * br), n, p, rough);
            tc *= 1.0 + 0.07 * hover;
            float id = iconD(p, kc, kr.w * 0.46, icon);
            float idUp = iconD(p - vec2(0.0, 0.9 * u), kc, kr.w * 0.46, icon);
            tc = mix(tc, ink.rgb * 0.5 + tc * 0.12, cov(id) * 0.95);
            tc += alb * 0.25 * clamp(cov(idUp) - cov(id), 0.0, 1.0);
            o = over(o, tc, cov(dt));
        }
    } else if (k == 2) {
        // ================= a bat-handle toggle =============================================
        vec2 c = res * 0.5;
        vec2 q = p - c;
        float d = length(q);
        float v = clamp(val, -1.25, 1.25);
        // lock washer, hex nut, threaded bushing
        float wr = 11.0 * u;
        o = over(o, vec3(0.0), 0.5 * exp(-max(length(q - vec2(1.2, 2.2) * u) - wr, 0.0) / (2.0 * u)) * (1.0 - cov(d - wr)));
        {
            float a = cov(d - wr);
            vec3 n = normalize(vec3(q / wr * 0.25, 1.0));
            vec3 wcol = metal(alb * 0.62, n, p, 0.3);
            wcol *= 1.0 - 0.3 * cov(abs(d - wr * 0.86) - 0.3 * u);
            o = over(o, wcol, a);
        }
        {
            // a hexagon, flats top and bottom
            float hr = 8.8 * u;
            vec2 hq = abs(q);
            const vec3 kk = vec3(-0.866025404, 0.5, 0.577350269);
            vec2 hp = hq;
            hp -= 2.0 * min(dot(kk.xy, hp), 0.0) * kk.xy;
            hp -= vec2(clamp(hp.x, -kk.z * hr, kk.z * hr), hr);
            float dh = length(hp) * sign(hp.y);
            float a = cov(dh);
            if (a > 0.0) {
                // the face it shows nearest decides its tilt
                float sector = floor((atan(q.y, q.x) + 3.14159265 / 6.0) / (3.14159265 / 3.0));
                float sa = sector * 3.14159265 / 3.0;
                vec2 fn = vec2(cos(sa), sin(sa));
                float edge = smoothstep(2.4 * u, 0.0, -dh);
                vec3 n = normalize(vec3(fn * edge * 1.1, 1.0));
                vec3 hc = metal(alb * 0.95, n, p, edge > 0.0 ? 0.05 : 0.2);
                // the turned chamfer on the flat
                hc *= 1.0 - 0.18 * cov(abs(d - hr * 0.86) - 0.35 * u);
                o = over(o, hc, a);
            }
            float br = 5.4 * u;
            float ab = cov(d - br);
            if (ab > 0.0) {
                float th = 0.5 + 0.5 * sin(d / u * 4.2);
                vec3 n = normalize(vec3(q / br * 0.6, 1.0));
                vec3 bc = metal(alb * (0.85 + 0.15 * th), n, p, 0.12);
                bc *= 0.45 + 0.55 * smoothstep(2.0 * u, 3.0 * u, d);
                o = over(o, bc, ab);
            }
        }
        // the handle: a tapered bat, pivoting toward the viewer as it flips
        float Lh = 19.0 * u;
        float ra = 2.3 * u, rb = 3.9 * u;
        vec2 A = c;
        vec2 B = c + vec2(0.0, -v * Lh);
        float span = abs(B.y - A.y);
        float height = 1.0 - min(abs(v), 1.0) * 0.6;    // nearer the camera mid-flip
        // shadow first, thrown down-right by its height
        {
            vec2 so = -LD.xy / max(LD.z, 0.3) * 3.6 * u * (0.7 + 0.6 * height);
            vec2 pa = p - so - A, ba = B - A;
            float h = span > 0.5 ? clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0) : 1.0;
            float ds = length(pa - ba * h) - mix(ra, rb, h);
            o = over(o, vec3(0.0), 0.45 * exp(-pow(max(ds, 0.0) / (2.4 * u), 1.5)));
        }
        {
            vec2 pa = p - A, ba = B - A;
            float h = span > 0.5 ? clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0) : 1.0;
            float rr = mix(ra, rb, h);
            vec2 axis = span > 0.5 ? ba / span : vec2(0.0, -1.0);
            vec2 perp = vec2(-axis.y, axis.x);
            float dsh = length(pa - ba * h) - rr;
            // the shank and the ball end
            float dball = length(p - B) - rb;
            float dd = min(dsh, dball);
            float a = cov(dd);
            if (a > 0.0) {
                vec3 n;
                if (dball < dsh || h >= 0.999) {
                    vec2 s = (p - B) / rb;
                    n = normalize(vec3(s, sqrt(max(0.0, 1.0 - dot(s, s))) + 0.15));
                } else {
                    float s = clamp(dot(pa, perp) / rr, -1.0, 1.0);
                    n = normalize(vec3(perp * s, sqrt(max(0.0, 1.0 - s * s)) + 0.1));
                }
                vec3 hc = metal(mix(alb, vec3(luma(alb)), 0.5) * 1.15, n, p, 0.03);
                // chrome: a hard dark horizon band and a crisp key highlight
                hc *= 0.62 + 0.38 * smoothstep(-0.25, 0.15, -n.x * 0.8 - n.y * 0.6);
                vec3 hh = normalize(L + vec3(0.0, 0.0, 1.0));
                hc += vec3(0.9) * pow(max(dot(n, hh), 0.0), 70.0);
                hc *= 1.0 + 0.08 * hover;
                o = over(o, hc, a);
            }
        }
    } else if (k == 3) {
        // ================= a jewel lamp ======================================================
        vec2 c = res * 0.5;
        float lr = dims.x;
        vec2 q = p - c;
        float d = length(q);
        float lon = clamp(on, 0.0, 1.0);
        float halo = exp(-pow(max(d - lr, 0.0) / (4.5 * u), 1.6)) * lon * (0.25 + 0.75 * bloomAmt) * (1.0 - 0.65 * light);
        o = vec4(lampC.rgb * halo * 0.65, halo * 0.35);
        float br = lr + 1.3 * u;
        // bezel
        {
            float a = cov(d - br) * (1.0 - cov(d - lr));
            vec3 n = normalize(vec3(q / max(d, 1e-3) * 1.2, 1.0));
            o = over(o, metal(alb * 1.05, n, p, 0.04), a);
        }
        {
            float a = cov(d - lr);
            vec2 s = q / lr;
            float facet = 0.5 + 0.5 * cos(atan(q.y, q.x) * 8.0);
            vec3 offc = mix(lampC.rgb, vec3(0.0), 0.72) * (0.8 + 0.25 * facet);
            vec3 onc = lampC.rgb * (1.0 + 0.35 * (1.0 - dot(s, s))) + vec3(0.35) * exp(-dot(s, s) * 3.0) * lon;
            vec3 lc = mix(offc, onc, lon);
            lc *= 0.85 + 0.15 * facet;
            float spec = exp(-pow(length(s - LD.xy * 0.62) / 0.30, 2.0));
            lc += vec3(0.6) * spec;
            o = over(o, lc, a);
        }
    } else if (k == 4) {
        // ================= the scale's cursor ===================================================
        float cx = res.x * 0.5;
        float gw = 1.0 + 0.25 * val;
        float tw = 6.0 * u * gw, th = 9.0 * u * gw;
        float ty = dims.x;            // top of the triangle
        vec2 a0 = vec2(cx - tw, ty), a1 = vec2(cx + tw, ty), a2 = vec2(cx, ty + th);
        // hairline down across the ticks
        float hl = cov(abs(p.x - cx) - 0.45 * u) * step(ty + th * 0.5, p.y) * step(p.y, res.y - dims.y);
        o = over(o, hot.rgb * 0.95, hl * 0.9);
        float ds = sdTri(p - vec2(1.2, 2.2) * u, a0, a1, a2) - 1.0 * u;
        o = over(o, vec3(0.0), 0.45 * exp(-max(ds, 0.0) / (1.8 * u)));
        float dtr = sdTri(p, a0, a1, a2) - 1.0 * u;
        if (dtr < 1.0) {
            float rim = smoothstep(1.4 * u, 0.0, -dtr);
            vec3 enamel = hot.rgb * (0.92 + 0.12 * (1.0 - (p.y - ty) / th)) * (1.0 + 0.1 * hover);
            vec3 rc = metal(alb * 1.05, normalize(vec3(0.0, -0.6, 1.0)), p, 0.05);
            vec3 col = mix(enamel, rc, rim * 0.8);
            col += vec3(0.25) * exp(-pow((p.y - ty - 1.6 * u) / (0.9 * u), 2.0)) * (1.0 - rim);
            o = over(o, col, cov(dtr));
        }
    } else {
        // ================= the sapphire over the art ===============================================
        vec2 e = (p - dims.xy) / res + (LD.xy - vec2(-0.42, -0.62)) * vec2(-0.5, -0.4);   // the glare rides the light and the parallax
        float dEdge = -sdRB(p - res * 0.5, res * 0.5, 3.0 * u);
        // the bezel's shade, deepest at the top-left where it overhangs the light
        float shade = exp(-dEdge / (4.0 * u)) * 0.45 + exp(-p.y / (8.0 * u)) * 0.18 + exp(-p.x / (10.0 * u)) * 0.10;
        o = over(o, vec3(0.0), clamp(shade, 0.0, 0.7));
        // the sapphire's bevel: a hard bright line in from the top and left, a dark one in the foot
        float rimHi = cov(abs(dEdge - 1.2 * u) - 0.45 * u) * clamp((1.0 - e.y) * 1.2 - e.x * 0.2, 0.0, 1.0);
        float rimLo = cov(abs(dEdge - 1.2 * u) - 0.45 * u) * clamp(e.y * 1.2 - 0.4, 0.0, 1.0);
        o = over(o, vec3(0.0), rimLo * 0.35);
        // the glare: a broad soft sweep and a thin hard one, across the top-left
        float s1 = smoothstep(0.62, 0.40, e.x + e.y * 0.75) * smoothstep(0.05, 0.25, e.x + e.y * 0.75) * 0.10;
        float s2 = smoothstep(0.035, 0.0, abs(e.x + e.y * 0.75 - 0.70)) * 0.08;
        float wsum = (s1 + s2) * mix(1.0, 0.8, light) + rimHi * 0.55;
        vec3 tint = mix(vec3(1.0), lampC.rgb, 0.12);
        o = vec4(o.rgb * (1.0 - wsum) + tint * wsum, o.a + wsum * (1.0 - o.a));
    }
    fragColor = o * qt_Opacity;
}
