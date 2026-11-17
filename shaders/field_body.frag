#version 440
// Orpheus "Field" deck (WidgetField.qml), the chassis: a machined steel face
// between two pebble-grain hide rails, with every recess, bezel, plate, screw
// and engraving the controls sit in. Static: no clock, so the deck caches it in
// a layer and it is only redrawn when the theme, the size or the room changes.
//
// Lit like a product shot: a key softbox above and to the left, a thin strip on
// the right, a camera at a finite distance so a flat plate still sweeps from a
// bright top to a darker foot. Every part is a signed distance whose bevel
// profile gives a normal. Pixel space, y down; premultiplied out, transparent
// past the device except for its own shadow.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float u;          // the deck's scale (1 at 392 px wide)
    float light;      // 1 on a light theme
    vec4 dev;         // the whole device, rails included (x, y, w, h)
    vec4 face;        // the steel face between the rails
    vec4 meterR;      // the meter's bezel, outer edge
    vec4 plateR;      // the nameplate
    vec4 artR;        // the art window's bezel, outer edge
    vec4 cntR;        // the drum counter's well
    vec4 scaleR;      // the tape scale
    vec4 knob;        // cx, cy, knob radius, well radius
    vec4 levL;        // lever wells
    vec4 levR;
    vec4 togL;        // toggle plates: cx, cy, radius, 0
    vec4 togR;
    vec4 grilleR;     // the monitor speaker's grille (w = 0: none)
    vec4 steel;       // the metal's own tint
    vec4 ink;         // engraving fill / anodised black
    vec4 hide;        // the rails
    vec4 accent;
};

const vec3 LD = vec3(-0.36, -0.74, 0.57);   // toward the key light (normalised below)

float h12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vn(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h12(i), h12(i + vec2(1, 0)), f.x), mix(h12(i + vec2(0, 1)), h12(i + vec2(1, 1)), f.x), f.y);
}
float sdRB(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
float sdR(vec2 p, vec4 R, float r) { return sdRB(p - (R.xy + R.zw * 0.5), R.zw * 0.5, r); }
vec2 gR(vec2 p, vec4 R, float r) {
    return normalize(vec2(sdR(p + vec2(0.5, 0), R, r) - sdR(p - vec2(0.5, 0), R, r),
                          sdR(p + vec2(0, 0.5), R, r) - sdR(p - vec2(0, 0.5), R, r)) + 1e-6);
}
float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float cov(float d) { return clamp(0.5 - d, 0.0, 1.0); }

// ---- light -------------------------------------------------------------------
// The studio the metal reflects: a big soft key overhead-left, a cool fill
// strip on the right, a dim floor. `rough` widens every edge (satin vs polish).
float studio(vec3 r, float rough) {
    vec3 kd = normalize(vec3(-0.30, -0.62, 0.72));
    float key = exp(-(1.0 - dot(r, kd)) / (0.025 + 1.25 * rough));
    float strip = exp(-abs(r.x - 0.62) / (0.02 + 0.3 * rough)) * smoothstep(0.9, 0.2, abs(r.y + 0.1));
    float sky = smoothstep(0.45, -0.75, r.y);
    return 0.08 + 0.26 * sky + 1.0 * key + 0.28 * strip;
}
vec3 viewV(vec2 p) {
    vec2 eye = vec2(res.x * 0.5, res.y * 0.40);
    return normalize(vec3(eye - p, res.y * 2.6));
}
// Metal: reflection tinted by the albedo, a little diffuse under it.
vec3 metal(vec3 alb, vec3 n, vec2 p, float rough) {
    vec3 v = viewV(p);
    vec3 r = reflect(-v, n);
    float e = studio(r, rough);
    float dif = max(dot(n, normalize(LD)), 0.0);
    return alb * (0.16 + 0.24 * dif + 0.78 * e);
}
// Bevel normals: g is the outward gradient, s the slope (raised: +, recessed: -).
vec3 bev(vec2 g, float s) { return normalize(vec3(g * s, 1.0)); }

// ---- engraving -----------------------------------------------------------------
// Every cut line in one place, so the lip below each groove can catch the light
// (the same function, sampled a pixel higher).
float tick(vec2 p, vec2 a, vec2 b, float w) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(1e-4, dot(ba, ba)), 0.0, 1.0);
    return cov(length(pa - ba * h) - w);
}
float grooves(vec2 p) {
    float g = 0.0;
    float w = 0.42 * u;
    // the tape scale: a base rule, a tick every 2.5 %, long each eighth, longest each quarter
    if (scaleR.z > 0.0 && p.y > scaleR.y - 2.0 && p.y < scaleR.y + scaleR.w + 2.0) {
        float y0 = scaleR.y + scaleR.w * 0.42, y1 = scaleR.y + scaleR.w * 0.66;
        g = max(g, tick(p, vec2(scaleR.x, y1), vec2(scaleR.x + scaleR.z, y1), w));
        float f = (p.x - scaleR.x) / scaleR.z * 40.0;
        float k = floor(f + 0.5);
        if (k >= 0.0 && k <= 40.0) {
            float x = scaleR.x + k / 40.0 * scaleR.z;
            bool major = mod(k, 5.0) < 0.5;
            bool quarter = mod(k, 10.0) < 0.5;
            float top = quarter ? y0 - scaleR.w * 0.06 : major ? y0 + scaleR.w * 0.04 : y0 + scaleR.w * 0.13;
            g = max(g, tick(p, vec2(x, top), vec2(x, y1), quarter ? w * 1.15 : major ? w : w * 0.8));
        }
    }
    // the knob's level ring: 31 ticks round 270 degrees, every fifth long
    if (knob.z > 0.0) {
        vec2 q = p - knob.xy;
        float rr = length(q);
        float r0 = knob.w + 3.0 * u, r1 = knob.w + 7.0 * u;
        if (rr > r0 - 2.0 && rr < r1 + 4.0 * u) {
            float a = atan(q.x, -q.y);                 // 0 up, clockwise +
            float span = 2.36;                          // +-135 degrees
            float st = 2.0 * span / 30.0;
            float k = clamp(floor((a + span) / st + 0.5), 0.0, 30.0);
            float ak = -span + k * st;
            vec2 dir = vec2(sin(ak), -cos(ak));
            bool major = mod(k, 5.0) < 0.5;
            g = max(g, tick(p, knob.xy + dir * r0, knob.xy + dir * (major ? r1 + 3.0 * u : r1), major ? w : w * 0.8));
        }
    }
    // the toggles' engraved rings
    for (int i = 0; i < 2; i++) {
        vec4 t = i == 0 ? togL : togR;
        if (t.z > 0.0) g = max(g, cov(abs(length(p - t.xy) - t.z) - w));
    }
    // hairlines either side of the nameplate, out to the face's margins
    if (plateR.z > 0.0) {
        float yc = plateR.y + plateR.w * 0.5;
        float m = 14.0 * u;
        g = max(g, tick(p, vec2(face.x + m, yc), vec2(plateR.x - 7.0 * u, yc), w));
        g = max(g, tick(p, vec2(plateR.x + plateR.z + 7.0 * u, yc), vec2(face.x + face.z - m, yc), w));
        // small end posts, box-drawing style: ┤ plate ├
        g = max(g, tick(p, vec2(face.x + m, yc - 3.0 * u), vec2(face.x + m, yc + 3.0 * u), w));
        g = max(g, tick(p, vec2(face.x + face.z - m, yc - 3.0 * u), vec2(face.x + face.z - m, yc + 3.0 * u), w));
    }
    // the control bay: a cut frame round the knob, the levers and the switches
    {
        vec4 bay = vec4(face.x + 16.0 * u, knob.y - knob.w - 12.0 * u, face.z - 32.0 * u, 0.0);
        bay.w = face.y + face.w - 14.0 * u - bay.y;
        if (knob.z > 0.0 && bay.w > 10.0) g = max(g, cov(abs(sdR(p, bay, 6.0 * u)) - w));
    }
    return g;
}

// ---- screws ---------------------------------------------------------------------
// A domed slot-head screw in a countersink; returns colour and coverage.
vec4 screw(vec2 p, vec2 c, float r, float seed, vec3 alb) {
    vec2 q = p - c;
    float d = length(q);
    float a = cov(d - r - 0.9 * u);
    if (a <= 0.0) return vec4(0.0);
    // countersink: a dark ring round the head
    vec3 col = alb * 0.35;
    float head = cov(d - r);
    vec2 s = q / r;
    vec3 n = normalize(vec3(s * 0.75, 1.0));
    vec3 hc = metal(alb * 1.02, n, p, 0.18);
    // the slot, at a random angle
    float ang = seed * 6.2831;
    vec2 dir = vec2(cos(ang), sin(ang));
    float across = abs(dot(q, vec2(-dir.y, dir.x)));
    float along = abs(dot(q, dir));
    float slot = cov(across - r * 0.17) * cov(along - r * 0.86);
    float wall = clamp(dot(vec2(-dir.y, dir.x), normalize(LD.xy)) * sign(dot(q, vec2(-dir.y, dir.x))), -1.0, 1.0);
    vec3 sc = alb * (0.16 + 0.10 * wall);
    hc = mix(hc, sc, slot);
    col = mix(col, hc, head);
    return vec4(col, a);
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    vec3 alb = steel.rgb;
    vec3 L = normalize(LD);
    float lt = light;

    // ---- the device's shadow on whatever it stands on ------------------------
    float rad = 11.0 * u;
    float dd = sdR(p, dev, rad);
    float sh1 = sdR(p - vec2(0.0, 7.0 * u), dev, rad);
    float sh2 = sdR(p - vec2(1.5 * u, 2.5 * u), dev, rad);
    float shadowA = 0.42 * exp(-max(sh1, 0.0) / (10.0 * u)) + 0.40 * exp(-max(sh2, 0.0) / (2.2 * u));
    shadowA *= mix(1.0, 0.55, lt);
    vec4 outc = vec4(0.0, 0.0, 0.0, clamp(shadowA, 0.0, 0.85));

    float devA = cov(dd);
    if (devA <= 0.0) { fragColor = outc * qt_Opacity; return; }

    vec3 col;
    float railW = face.x - dev.x;
    bool inRail = p.x < face.x || p.x > face.x + face.z;

    if (inRail) {
        // ---- the hide rails: pebble grain over a domed wrap --------------------
        bool left = p.x < face.x;
        float cx = left ? dev.x + railW * 0.5 : face.x + face.z + railW * 0.5;
        float t = (p.x - cx) / (railW * 0.5);
        // rounded ends follow the device outline
        vec2 g = gR(p, dev, rad);
        float edge = smoothstep(4.0 * u, 0.0, -dd);
        vec2 slope = vec2(t * 0.9, 0.0) + g * edge * 1.4;
        // grain: cells with crevices between them
        vec2 gp = p / (3.4 * u);
        float e = 0.35;
        float g0 = 0.0, gx = 0.0, gy = 0.0;
        {
            vec2 pp[3]; pp[0] = gp; pp[1] = gp + vec2(e, 0.0); pp[2] = gp + vec2(0.0, e);
            float hv[3];
            for (int k = 0; k < 3; k++) {
                vec2 nn = floor(pp[k]), ff = fract(pp[k]);
                float f1 = 8.0, f2 = 8.0;
                for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
                    vec2 gg = vec2(float(i), float(j));
                    vec2 o = vec2(h12(nn + gg), h12(nn + gg + 17.31)) * 0.85 + 0.075;
                    float dist = length(gg + o - ff);
                    if (dist < f1) { f2 = f1; f1 = dist; } else if (dist < f2) f2 = dist;
                }
                hv[k] = smoothstep(0.0, 0.32, f2 - f1) * (1.0 - 0.35 * f1);
            }
            g0 = hv[0]; gx = (hv[1] - hv[0]) / e; gy = (hv[2] - hv[0]) / e;
        }
        vec3 n = normalize(vec3(slope - vec2(gx, gy) * 0.22, 1.0));
        vec3 halb = hide.rgb * (0.80 + 0.20 * g0) * (0.95 + 0.1 * vn(p * 0.05));
        float dif = max(dot(n, L), 0.0);
        vec3 v = viewV(p);
        vec3 r = reflect(-v, n);
        float sheen = pow(max(dot(r, normalize(vec3(-0.3, -0.62, 0.72))), 0.0), 18.0);
        col = halb * (0.30 + 0.85 * dif) + vec3(0.13 + 0.05 * g0) * sheen * mix(1.0, 0.6, lt);
        // the hide's soft gloss down the crown of the wrap
        float crown = exp(-pow((t + 0.25) / 0.35, 2.0)) * (0.6 + 0.4 * smoothstep(dev.y + dev.w, dev.y, p.y));
        col += mix(hide.rgb, vec3(1.0), 0.6) * crown * 0.16 * (0.4 + 0.6 * g0);
        // crevices hold dark
        col *= 0.72 + 0.28 * smoothstep(0.0, 0.5, g0);
        // the stitch line along the inner edge
        float sx = left ? face.x - 4.5 * u : face.x + face.z + 4.5 * u;
        float per = 5.2 * u;
        float yy = p.y - dev.y;
        float k = floor(yy / per);
        float fy = yy - (k + 0.5) * per;
        bool inRun = p.y > dev.y + 9.0 * u && p.y < dev.y + dev.w - 9.0 * u;
        vec2 sq = vec2(p.x - sx, fy);
        // slanted stitches: a capsule on the diagonal
        vec2 sa = vec2(-0.7 * u, -1.6 * u), sb = vec2(0.7 * u, 1.6 * u);
        float sd = length(sq - sa - (sb - sa) * clamp(dot(sq - sa, sb - sa) / dot(sb - sa, sb - sa), 0.0, 1.0)) - 0.62 * u;
        if (inRun) {
            float holeA = cov(length(sq - sa * 1.25) - 0.55 * u) + cov(length(sq - sb * 1.25) - 0.55 * u);
            col *= 1.0 - 0.45 * clamp(holeA, 0.0, 1.0);
            vec3 thread = mix(hide.rgb, mix(steel.rgb, accent.rgb, 0.35), 0.55);
            float ts = cov(sd);
            float lit = 0.6 + 0.6 * clamp(dot(normalize(vec2(sq.y, -sq.x) + 1e-4), -L.xy), 0.0, 1.0);
            col = mix(col, thread * lit, ts);
            col *= 1.0 - 0.35 * cov(sd - 0.9 * u) * (1.0 - ts) * step(0.0, sq.y);
        }
        // the face's step casts onto the rail's inner edge
        float ix = left ? face.x - p.x : p.x - (face.x + face.z);
        col *= 1.0 - (left ? 0.0 : 0.25) * exp(-ix / (1.4 * u));
    } else {
        // ---- the steel face --------------------------------------------------------
        // linear machining: long horizontal marks, finer ones over them
        float m1 = vn(vec2(p.x * 0.006 / u, p.y * 0.9 / u));
        float m2 = vn(vec2(p.x * 0.022 / u + 13.0, p.y * 2.4 / u));
        float m3 = h12(vec2(floor(p.y), floor(p.x / (70.0 * u))));
        float marks = 0.5 * m1 + 0.3 * m2 + 0.2 * m3;
        vec3 n = normalize(vec3(0.0, (marks - 0.5) * 0.035, 1.0));
        // the face's top and bottom edges roll off
        float top = p.y - face.y, bot = face.y + face.w - p.y;
        if (top < 3.0 * u) n = bev(vec2(0.0, -1.0), 1.6 * (1.0 - top / (3.0 * u)));
        if (bot < 3.0 * u) n = bev(vec2(0.0, 1.0), 1.6 * (1.0 - bot / (3.0 * u)));
        vec3 falb = alb * (0.965 + 0.06 * marks) * (0.99 + 0.02 * h12(floor(p)));
        col = metal(falb, n, p, 0.22);
        // the key softbox's broad reflection, swept across the plate on a diagonal
        vec2 fe = (p - face.xy) / face.zw;
        float sweep = exp(-pow((fe.x * 0.55 + fe.y * 0.85 - 0.30) / 0.30, 2.0));
        // brushed along x, the highlight smears across the grain: a soft upright
        // band, streaked by the marks themselves
        float aniso = exp(-pow((fe.x - 0.30 + 0.08 * fe.y) / 0.13, 2.0)) * (0.55 + 0.9 * (marks - 0.35));
        col += falb * (0.11 * sweep + 0.10 * aniso - 0.06 * smoothstep(0.6, 1.1, fe.y));
        // the rails stand proud: their walls shade the face's sides
        float lx = p.x - face.x, rx = face.x + face.z - p.x;
        col *= 1.0 - 0.30 * exp(-lx / (2.2 * u)) - 0.10 * exp(-rx / (1.8 * u));
        col += alb * 0.10 * exp(-rx / (1.2 * u));

        // ---- raised parts' shadows on the face -----------------------------------
        float shd = 0.0;
        shd = max(shd, 0.55 * exp(-max(sdR(p - vec2(1.2, 2.6) * u, meterR, 9.0 * u), 0.0) / (3.0 * u)));
        shd = max(shd, 0.50 * exp(-max(sdR(p - vec2(1.0, 2.0) * u, artR, 6.0 * u), 0.0) / (2.6 * u)));
        shd = max(shd, 0.45 * exp(-max(sdR(p - vec2(0.8, 1.6) * u, plateR, 2.0 * u), 0.0) / (1.6 * u)));
        col *= 1.0 - shd;

        // ---- engravings ------------------------------------------------------------
        float gv = grooves(p);
        float up = grooves(p - vec2(0.0, 0.9 * u));
        col = mix(col, ink.rgb * 0.55 + col * 0.18, gv * 0.92);
        col += alb * 0.22 * clamp(up - gv, 0.0, 1.0);

        // ---- the monitor grille: a field of drilled holes, a hex pitch -----------------
        if (grilleR.z > 0.0) {
            float d = sdR(p, grilleR, 3.0 * u);
            if (d < 0.0) {
                float pitch = 4.6 * u;
                vec2 gp = (p - grilleR.xy) / pitch;
                float row = floor(gp.y + 0.5);
                vec2 cc = vec2(floor(gp.x - 0.5 * mod(row, 2.0) + 0.5) + 0.5 * mod(row, 2.0), row);
                vec2 hc = grilleR.xy + cc * pitch;
                float inside = step(-d, 1e3) * cov(sdR(hc, grilleR, 3.0 * u) + 2.2 * u);
                vec2 hq = p - hc;
                float hr = 1.35 * u;
                float hole = cov(length(hq) - hr) * inside;
                // dark bore, the light catching its far lip
                vec3 bore = ink.rgb * 0.25 * (0.5 + 0.5 * clamp(hq.y / hr, -1.0, 1.0));
                col = mix(col, bore, hole);
                col += alb * 0.28 * cov(abs(length(hq) - hr - 0.45 * u) - 0.4 * u) * clamp(hq.y / hr, 0.0, 1.0) * inside;
            }
        }

        // ---- the knob well: a deep round recess ---------------------------------------
        if (knob.z > 0.0) {
            vec2 q = p - knob.xy;
            float d = length(q) - knob.w;
            if (d < 1.0) {
                float a = cov(d);
                vec2 g = q / max(length(q), 1e-3);
                float depth = clamp(-d / (knob.w - knob.z + 0.001), 0.0, 1.0);
                vec3 nw = bev(g, -2.2);
                vec3 wc = metal(alb * 0.55, nw, p, 0.3) * (0.55 + 0.45 * depth);
                // the floor, deep in shadow under the knob
                wc *= 0.55 + 0.45 * smoothstep(0.0, 1.0, clamp(dot(g, vec2(0.4, 0.8)), 0.0, 1.0));
                col = mix(col, wc, a);
                // the lip catches the light along its far (lower right) edge
                col += alb * 0.35 * cov(abs(d + 0.5 * u) - 0.5 * u) * clamp(dot(g, -L.xy * 1.6), 0.0, 1.0);
            }
        }

        // ---- lever wells -----------------------------------------------------------
        for (int i = 0; i < 2; i++) {
            vec4 R = i == 0 ? levL : levR;
            if (R.z <= 0.0) continue;
            float d = sdR(p, R, 5.0 * u);
            if (d < 1.0) {
                vec2 g = gR(p, R, 5.0 * u);
                float wall = clamp(-d / (2.4 * u), 0.0, 1.0);
                vec3 nw = wall < 1.0 ? bev(g, -1.8) : vec3(0, 0, 1);
                vec3 wc = metal(alb * 0.42, nw, p, 0.35);
                wc *= 0.55 + 0.45 * clamp((p.y - R.y) / R.w, 0.0, 1.0);
                col = mix(col, wc, cov(d));
                col += alb * 0.30 * cov(abs(d + 0.4 * u) - 0.45 * u) * clamp(dot(g, -L.xy * 1.6), 0.0, 1.0);
            }
        }

        // ---- the counter well -------------------------------------------------------
        if (cntR.z > 0.0) {
            float d = sdR(p, cntR, 3.0 * u);
            if (d < 2.0 * u) {
                vec2 g = gR(p, cntR, 3.0 * u);
                // a polished chamfer frames the window
                float ch = cov(d - 1.8 * u) * (1.0 - cov(d));
                vec3 nc = bev(g, 1.3);
                col = mix(col, metal(alb * 1.05, nc, p, 0.08), ch);
                vec3 wc = mix(ink.rgb, vec3(0.0), 0.6) * (0.4 + 0.6 * clamp((p.y - cntR.y) / cntR.w, 0.0, 1.0));
                col = mix(col, wc, cov(d));
            }
        }

        // ---- the meter bezel: black anodised, a bright chamfer out, a step down in ----
        {
            float d = sdR(p, meterR, 9.0 * u);
            if (d < 1.0) {
                vec4 inR = vec4(meterR.xy + 7.0 * u, meterR.zw - 14.0 * u);
                float di = sdR(p, inR, 4.0 * u);
                vec2 go = gR(p, meterR, 9.0 * u);
                vec2 gi = gR(p, inR, 4.0 * u);
                vec3 an = mix(ink.rgb, vec3(0.0), 0.45);
                vec3 n = vec3(0, 0, 1);
                float rough = 0.32;
                if (-d < 1.6 * u) { n = bev(go, 1.4); rough = 0.06; an = mix(an, alb, 0.55); }
                else if (di < 2.2 * u) n = bev(-gi, 1.2);
                float bead = vn(p * 0.9 / u);
                vec3 bc = metal(an * (0.9 + 0.2 * bead), n, p, rough);
                col = mix(col, bc, cov(d));
                // the dial's hole (the meter draws in it)
                col = mix(col, vec3(0.0), cov(di));
            }
        }

        // ---- the nameplate: anodised strip, two pins ----------------------------------
        if (plateR.z > 0.0) {
            float d = sdR(p, plateR, 2.0 * u);
            if (d < 1.0) {
                vec2 g = gR(p, plateR, 2.0 * u);
                vec3 n = -d < 1.2 * u ? bev(g, 1.2) : normalize(vec3(0.0, (vn(vec2(p.x * 0.02 / u, p.y * 1.4 / u)) - 0.5) * 0.12, 1.0));
                vec3 an = mix(ink.rgb, vec3(0.0), 0.35);
                col = mix(col, metal(an, n, p, -d < 1.2 * u ? 0.05 : 0.25), cov(d));
                for (int i = 0; i < 2; i++) {
                    vec2 c = vec2(i == 0 ? plateR.x + 6.5 * u : plateR.x + plateR.z - 6.5 * u, plateR.y + plateR.w * 0.5);
                    vec4 s = screw(p, c, 2.2 * u, h12(c), alb);
                    col = mix(col, s.rgb, s.a);
                }
            }
        }

        // ---- the art window: a polished bevel on a flat band, four screws -------------
        {
            float d = sdR(p, artR, 6.0 * u);
            if (d < 1.0) {
                float bw = 10.0 * u;
                vec4 inR = vec4(artR.xy + bw, artR.zw - 2.0 * bw);
                float di = sdR(p, inR, 3.0 * u);
                vec2 go = gR(p, artR, 6.0 * u);
                vec2 gi = gR(p, inR, 3.0 * u);
                vec3 n = normalize(vec3(0.0, (vn(vec2(p.x * 0.02 / u, p.y * 1.2 / u)) - 0.5) * 0.08, 1.0));
                float rough = 0.2;
                if (-d < 1.3 * u) { n = bev(go, 1.5); rough = 0.04; }
                else if (di < 3.8 * u) { n = bev(-gi, 0.95); rough = 0.02; }
                vec3 bc = metal(alb * 1.04, n, p, rough);
                col = mix(col, bc, cov(d));
                col = mix(col, vec3(0.0), cov(di));
                for (int i = 0; i < 4; i++) {
                    vec2 c = vec2(i % 2 == 0 ? artR.x + 4.6 * u : artR.x + artR.z - 4.6 * u,
                                  i < 2 ? artR.y + 4.6 * u : artR.y + artR.w - 4.6 * u);
                    vec4 s = screw(p, c, 1.9 * u, h12(c + 3.1), alb);
                    col = mix(col, s.rgb, s.a);
                }
            }
        }

        // ---- the face's corner screws -------------------------------------------------
        for (int i = 0; i < 4; i++) {
            vec2 c = vec2(i % 2 == 0 ? face.x + 7.5 * u : face.x + face.z - 7.5 * u,
                          i < 2 ? face.y + 7.5 * u : face.y + face.w - 7.5 * u);
            vec4 s = screw(p, c, 3.1 * u, h12(c * 0.37), alb);
            col = mix(col, s.rgb, s.a);
        }
    }

    // the device's outline: a dark seam so it reads on any ground
    col *= 1.0 - 0.5 * cov(-dd - 1.0);
    col += vec3(h12(p) - 0.5) / 255.0;
    vec4 dev4 = vec4(col, 1.0) * devA;
    fragColor = (dev4 + outc * (1.0 - devA)) * qt_Opacity;
}
