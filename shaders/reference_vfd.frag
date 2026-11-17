#version 440
// Orpheus "Reference" deck: the vacuum fluorescent display behind smoked glass.
// Everything that glows is phosphor in the theme's accent (the top of the
// scales in its `hot` colour): a 32-band segmented spectrum with peak hold, two
// peak meters on a dB scale, a segmented progress bar, a dot-matrix title that
// steps along in whole dots, seven-segment figures for the time, and the
// annunciators and legends (drawn by QML
// into `txt`: red = lit, green = an unlit segment's ghost, blue = a printed
// legend). Unlit segments ghost faintly as they do in a real tube; the grid
// mesh sits in front of the phosphor and shadows it; two filament wires cross
// the glass; the smoked front reflects the room. Bloom is analytic for the
// segments and a few taps of the text for the type; it backs off with the
// `bloomAmt` budget (zero on a light theme), leaving only the tube's own halo.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    vec4 phos;       // phosphor (the accent)
    vec4 phosHot;    // the top of the scales (`hot`)
    vec4 glass;      // the smoked glass
    vec4 b0; vec4 b1; vec4 b2; vec4 b3; vec4 b4; vec4 b5; vec4 b6; vec4 b7;
    vec4 p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5; vec4 p6; vec4 p7;
    vec4 specR;      // rects in px, this item's space
    vec4 meterR;     // both bars: x, y, w, h (bar h = meterBar.x, gap = meterBar.y)
    vec4 meterBar;   // bar height, gap between bars, -, -
    vec4 progR;
    vec4 titleR;
    vec4 flashR;     // the section annunciator that just changed
    vec4 dims;       // spectrum row pitch, title dot pitch, title texture width, title scroll px
    float frac;      // progress 0..1
    float power;     // 1 playing, dimmer paused
    float bloomAmt;
    float flash;     // the section flare 0..1
    float wrapT;     // 1: the title wraps (marquee); 0: one copy, as placed
    float beat;
    float progHot;   // the pointer is on the progress bar
    float bandX;     // the room light's band, px in this item (the plate's sheen)
    vec4 clockL;     // the elapsed figures: x, y, digit w, digit h
    vec4 clockR;     // the length figures
    vec4 clockG;     // digit gap, colon width, colon lit (L), colon lit (R)
    vec4 segL;       // segment masks per digit (a..g = bits 0..6)
    vec4 segR;
};
layout(binding = 1) uniform sampler2D txt;
layout(binding = 2) uniform sampler2D ttl;

vec3 vivid(vec3 c) {
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    vec3 v = max(mix(vec3(l), c, 1.55), 0.0);
    float m = max(v.r, max(v.g, v.b)), mc = max(c.r, max(c.g, c.b));
    return v * (mc / max(m, 1e-3));          // the same peak channel, more chroma
}
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float boxD(vec2 p, vec2 lo, vec2 hi) { vec2 d = max(lo - p, p - hi); return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }

float band(int i, bool peak) {
    vec4 v;
    int q = i / 4;
    if (peak) v = q == 0 ? p0 : q == 1 ? p1 : q == 2 ? p2 : q == 3 ? p3 : q == 4 ? p4 : q == 5 ? p5 : q == 6 ? p6 : p7;
    else v = q == 0 ? b0 : q == 1 ? b1 : q == 2 ? b2 : q == 3 ? b3 : q == 4 ? b4 : q == 5 ? b5 : q == 6 ? b6 : b7;
    int r = i - q * 4;
    return clamp(r == 0 ? v.x : r == 1 ? v.y : r == 2 ? v.z : v.w, 0.0, 1.0);
}

// The meters' dB scale: where a level lands along the bar (matches the QML legend).
float dbPos(float db) {
    // -40 -20 -10 -6 -3 0 +3  ->  0 .30 .50 .62 .74 .86 1
    if (db < -20.0) return clamp((db + 40.0) / 20.0 * 0.30, 0.0, 0.30);
    if (db < -10.0) return 0.30 + (db + 20.0) / 10.0 * 0.20;
    if (db < -6.0) return 0.50 + (db + 10.0) / 4.0 * 0.12;
    if (db < -3.0) return 0.62 + (db + 6.0) / 3.0 * 0.12;
    if (db < 0.0) return 0.74 + (db + 3.0) / 3.0 * 0.12;
    return min(1.0, 0.86 + db / 3.0 * 0.14);
}
float meterLevel(int ch, bool peak) {
    float s = 0.0, w = 0.0;
    for (int i = 0; i < 16; i++) {
        float k = (i % 2 == ch) ? 1.0 : 0.55;
        float wt = k * (1.0 - float(i) / 20.0);
        s += band(i, peak) * wt; w += wt;
    }
    float lvl = s / w * 1.0;
    return dbPos(20.0 * log(max(lvl, 1e-4)) / log(10.0));
}

// One seven-segment digit at origin o (w x h), italic like the real glass.
// Adds coverage to lit / ghost and the lit segments' glow.
void digit(vec2 p, vec2 o, float w, float h, int mask, inout float lit, inout float ghost, inout float glw) {
    vec2 q = p - o;
    q.x -= (h - q.y) * 0.09;                    // lean
    float t = max(1.2, h * 0.085);              // half thickness
    float gp = max(0.6, t * 0.45);              // the gap between segments
    float x0 = t, x1 = w - t, y0 = t, ym = h * 0.5, y1 = h - t;
    vec2 cs[7] = vec2[](vec2((x0 + x1) * 0.5, y0), vec2(x1, (y0 + ym) * 0.5), vec2(x1, (ym + y1) * 0.5),
                        vec2((x0 + x1) * 0.5, y1), vec2(x0, (ym + y1) * 0.5), vec2(x0, (y0 + ym) * 0.5), vec2((x0 + x1) * 0.5, ym));
    float hl = (x1 - x0) * 0.5 + t * 0.85 - gp, vl = (ym - y0) * 0.5 + t * 0.85 - gp;
    for (int i = 0; i < 7; i++) {
        bool vert = (i == 1 || i == 2 || i == 4 || i == 5);
        vec2 d = abs(q - cs[i]);
        if (vert) d = d.yx;
        float L = vert ? vl : hl;
        float sd = max(d.y - t, d.x + d.y - L);
        float cov = clamp(0.5 - sd, 0.0, 1.0);
        bool on = ((mask >> i) & 1) == 1;
        if (on) { lit += cov; float g = max(sd, 0.0); glw += 0.5 * exp(-g * g / (10.0 * sc * sc)); }
        else ghost += cov;
    }
}
void clockFig(vec2 p, vec4 R, vec4 m, float colonOn, inout float lit, inout float ghost, inout float glw) {
    float w = R.z, h = R.w, gap = clockG.x, cw = clockG.y;
    float W = 4.0 * w + 2.0 * gap + 2.0 * cw;
    if (p.x < R.x - 8.0 * sc || p.x > R.x + W + 8.0 * sc || p.y < R.y - 8.0 * sc || p.y > R.y + h + 8.0 * sc) return;
    float x = R.x;
    digit(p, vec2(x, R.y), w, h, int(m.x), lit, ghost, glw); x += w + gap;
    digit(p, vec2(x, R.y), w, h, int(m.y), lit, ghost, glw); x += w + cw;
    // the colon, leaning with the digits
    for (int k = 0; k < 2; k++) {
        float cy = R.y + h * (k == 0 ? 0.32 : 0.70);
        vec2 c = vec2(x - cw * 0.5 + (h - (cy - R.y)) * 0.09, cy);
        float r = max(1.1, h * 0.07);
        float sd = length(p - c) - r;
        float cov = clamp(0.5 - sd, 0.0, 1.0);
        if (colonOn > 0.5) { lit += cov; float g = max(sd, 0.0); glw += 0.4 * exp(-g * g / (8.0 * sc * sc)); }
        else ghost += cov;
    }
    x += cw;
    digit(p, vec2(x, R.y), w, h, int(m.z), lit, ghost, glw); x += w + gap;
    digit(p, vec2(x, R.y), w, h, int(m.w), lit, ghost, glw);
}

// A honeycomb grid mesh: 1 on a wire, 0 between.
float mesh(vec2 p, float pitch) {
    p /= pitch;
    vec2 r = vec2(1.0, 1.7320508), h = r * 0.5;
    vec2 a = mod(p, r) - h, b = mod(p - h, r) - h;
    vec2 g = dot(a, a) < dot(b, b) ? a : b;
    vec2 q = abs(g);
    float d = 0.5 - max(dot(q, vec2(0.5, 0.8660254)), q.x);
    return clamp(1.0 - d * pitch / (0.35 * sc + 0.25), 0.0, 1.0);
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    float lit = 0.0, ghost = 0.0, glowA = 0.0, hotMix = 0.0;
    float rowP = dims.x, dp = dims.y, tW = dims.z, scroll = dims.w;

    // ---- the spectrum: 32 columns of segments, peak caps held -----------------
    {
        vec2 lo = specR.xy, hi = specR.xy + specR.zw;
        if (p.x > lo.x - 14.0 * sc && p.x < hi.x + 14.0 * sc && p.y > lo.y - 14.0 * sc && p.y < hi.y + 8.0 * sc) {
            float cw = specR.z / 32.0;
            float rows = floor(specR.w / rowP);
            float base = lo.y + rows * rowP;
            int ci = int(floor((p.x - lo.x) / cw));
            float lx = p.x - lo.x - float(ci) * cw;
            float segW = cw - max(2.0, floor(cw * 0.32));
            float x0 = floor((cw - segW) * 0.5);
            float rj = floor((base - p.y) / rowP);
            float ly = base - p.y - rj * rowP;            // 0 at a row's bottom
            float segH = rowP - max(1.0, floor(rowP * 0.3));
            bool inCol = ci >= 0 && ci < 32 && rj >= 0.0 && rj < rows;
            if (inCol) {
                float cov = clamp(min(lx - x0, x0 + segW - lx) + 0.5, 0.0, 1.0) * clamp(min(ly, segH - ly) + 0.5, 0.0, 1.0);
                float v = band(ci, false);
                float pk = band(ci, true);
                float n = floor(v * rows + 0.35);
                float pr = min(rows - 1.0, floor(pk * rows));
                float on = (rj < n) ? 1.0 : 0.0;
                if (pk > 0.03 && abs(rj - pr) < 0.5 && pr >= n) on = max(on, 0.9);
                float hgt = (rj + 0.5) / rows;
                hotMix = smoothstep(0.74, 0.86, hgt);
                lit += cov * on;
                ghost += cov * (1.0 - on);
            }
            // segment glow: the three nearest lit columns as soft boxes
            for (int k = -1; k <= 1; k++) {
                int c = ci + k;
                if (c < 0 || c > 31) continue;
                float v = band(c, false);
                float hgt = floor(v * rows + 0.35) * rowP;
                if (hgt <= 0.0) continue;
                float cx0 = lo.x + float(c) * cw + floor((cw - segW) * 0.5);
                float d = boxD(p, vec2(cx0, base - hgt), vec2(cx0 + segW, base));
                d = max(d, 0.0);
                glowA += 0.55 * exp(-d * d / (16.0 * sc * sc)) + 0.25 * exp(-d / (7.0 * sc));
            }
        }
    }

    // ---- the meters: L and R, 0 dB and above in the hot colour -----------------
    {
        float bh = meterBar.x, gap = meterBar.y;
        for (int ch = 0; ch < 2; ch++) {
            float y0 = meterR.y + float(ch) * (bh + gap);
            if (p.y > y0 - 10.0 * sc && p.y < y0 + bh + 10.0 * sc && p.x > meterR.x - 10.0 * sc && p.x < meterR.x + meterR.z + 10.0 * sc) {
                float lv = meterLevel(ch, false), pk = meterLevel(ch, true);
                float segP = max(3.0, floor(3.0 * sc + 0.5));
                float nSeg = floor(meterR.z / segP);
                float j = floor((p.x - meterR.x) / segP);
                float lx = p.x - meterR.x - j * segP;
                float segW = segP - max(1.0, floor(segP * 0.34));
                float inS = (j >= 0.0 && j < nSeg) ? clamp(min(lx, segW - lx) + 0.5, 0.0, 1.0) * clamp(min(p.y - y0, y0 + bh - p.y) + 0.5, 0.0, 1.0) : 0.0;
                float pos = (j + 0.5) / nSeg;
                float on = pos < lv ? 1.0 : 0.0;
                if (abs(pos - pk) < 0.6 / nSeg && pk > 0.02) on = 1.0;
                if (inS > 0.0) hotMix = max(hotMix, step(0.86, pos));
                lit += inS * on;
                ghost += inS * (1.0 - on);
                float d = max(boxD(p, vec2(meterR.x, y0), vec2(meterR.x + meterR.z * lv, y0 + bh)), 0.0);
                glowA += lv > 0.005 ? 0.45 * exp(-d * d / (12.0 * sc * sc)) : 0.0;
            }
        }
    }

    // ---- the progress bar ------------------------------------------------------
    if (p.y > progR.y - 10.0 * sc && p.y < progR.y + progR.w + 10.0 * sc) {
        float segP = max(3.0, floor(4.0 * sc + 0.5));
        float nSeg = floor(progR.z / segP);
        float x0 = progR.x + (progR.z - nSeg * segP) * 0.5;
        float j = floor((p.x - x0) / segP);
        float lx = p.x - x0 - j * segP;
        float segW = segP - max(1.0, floor(segP * 0.3));
        float inS = (j >= 0.0 && j < nSeg) ? clamp(min(lx, segW - lx) + 0.5, 0.0, 1.0) * clamp(min(p.y - progR.y, progR.y + progR.w - p.y) + 0.5, 0.0, 1.0) : 0.0;
        float head = floor(frac * nSeg);
        float on = j < head ? 1.0 : (abs(j - head) < 0.5 && frac > 0.0 ? 1.0 : 0.0);
        lit += inS * on;
        ghost += inS * (1.0 - on) * (1.0 + 1.2 * progHot);
        float d = max(boxD(p, vec2(x0, progR.y), vec2(x0 + (head + 1.0) * segP, progR.y + progR.w)), 0.0);
        glowA += frac > 0.0 ? 0.4 * exp(-d * d / (14.0 * sc * sc)) : 0.0;
        // the head segment burns a little brighter
        float hd = max(boxD(p, vec2(x0 + head * segP, progR.y), vec2(x0 + head * segP + segW, progR.y + progR.w)), 0.0);
        glowA += frac > 0.0 ? 0.5 * exp(-hd * hd / (10.0 * sc * sc)) : 0.0;
    }

    // ---- the dot-matrix title -------------------------------------------------------
    {
        vec2 lo = titleR.xy, hi = titleR.xy + titleR.zw;
        if (p.x > lo.x - 6.0 * sc && p.x < hi.x + 6.0 * sc && p.y > lo.y - 6.0 * sc && p.y < hi.y + 6.0 * sc) {
            vec2 cell = floor((p - lo) / dp);
            vec2 cc = lo + (cell + 0.5) * dp;
            float rowsT = floor(titleR.w / dp), cols = floor(titleR.z / dp);
            bool inside = cell.x >= 0.0 && cell.y >= 0.0 && cell.x < cols && cell.y < rowsT;
            // fade the dots out toward the ends while it scrolls
            float fade = wrapT > 0.5 ? smoothstep(0.0, 4.0 * dp, cc.x - lo.x) * smoothstep(0.0, 4.0 * dp, lo.x + cols * dp - cc.x) : 1.0;
            float tx = cc.x - lo.x + scroll;
            if (wrapT > 0.5) tx = mod(tx, tW);
            vec2 tuv = vec2(tx / tW, (cc.y - lo.y) / titleR.w);
            float s = (tuv.x >= 0.0 && tuv.x <= 1.0) ? texture(ttl, tuv).r : 0.0;
            float on = smoothstep(0.32, 0.6, s) * fade;
            vec2 dv = p - cc;
            float dr = 0.40 * dp;
            float dotC = clamp(dr - length(dv) + 0.5, 0.0, 1.0);
            if (inside) {
                lit += dotC * on;
                ghost += dotC * (1.0 - on) * fade;
            }
            // halo: the same texture, smeared a little
            float acc = 0.0;
            for (int k = 0; k < 6; k++) {
                float a = float(k) * 1.0471976;
                vec2 o = vec2(cos(a), sin(a)) * dp * 1.6;
                float tx2 = p.x + o.x - lo.x + scroll;
                if (wrapT > 0.5) tx2 = mod(tx2, tW);
                vec2 u2 = vec2(tx2 / tW, (p.y + o.y - lo.y) / titleR.w);
                acc += (u2.x >= 0.0 && u2.x <= 1.0 && u2.y >= 0.0 && u2.y <= 1.0) ? texture(ttl, u2).r : 0.0;
            }
            glowA += acc / 6.0 * 0.8 * fade;
        }
    }

    // ---- the figures: elapsed and length on seven-segment digits -------------------
    {
        float dl = 0.0, dg = 0.0, dw = 0.0;
        clockFig(p, clockL, clockG.z > 0.5 ? segL : vec4(64.0), clockG.z, dl, dg, dw);
        clockFig(p, clockR, segR, clockG.w, dl, dg, dw);
        lit += dl; ghost += dg; glowA += dw;
    }

    // ---- the annunciators (QML type) ---------------------------------
    vec4 t = texture(txt, qt_TexCoord0);
    float flare = 0.0;
    {
        vec2 lo = flashR.xy, hi = flashR.xy + flashR.zw;
        float inF = step(lo.x, p.x) * step(p.x, hi.x) * step(lo.y, p.y) * step(p.y, hi.y);
        flare = inF * flash;
    }
    lit += t.r * (1.0 + 0.6 * flare);
    ghost += t.g;
    float legend = t.b;
    {
        float acc = 0.0;
        vec2 px = 1.0 / res;
        for (int k = 0; k < 8; k++) {
            float a = float(k) * 0.7853982 + 0.39;
            vec2 o1 = vec2(cos(a), sin(a)) * 2.2 * sc;
            vec2 o2 = vec2(cos(a + 0.39), sin(a + 0.39)) * 5.5 * sc;
            vec4 s1 = texture(txt, qt_TexCoord0 + o1 * px);
            vec4 s2 = texture(txt, qt_TexCoord0 + o2 * px);
            acc += (s1.r + 0.4 * s1.b) * 0.65 + (s2.r + 0.4 * s2.b) * 0.35;
        }
        glowA += acc / 8.0 * (1.1 + 2.6 * flare);
    }

    // ---- compose: glass, ghosts, phosphor, mesh, halo, bloom, the front ------------
    // phosphor is emissive: push the theme colour's chroma (hue kept), so a
    // pastel accent still reads as a lit tube, not as paint
    vec3 ph = vivid(mix(phos.rgb, phosHot.rgb, hotMix));
    vec3 phG = vivid(phos.rgb);
    float pw = power;
    vec3 col = glass.rgb;
    // the back of the tube: a faint warm-dark gradient so it reads as depth
    col *= mix(1.12, 0.82, p.y / res.y);
    float meshW = mesh(p, 3.4 * sc);
    // ghosts: unlit segments catch a little light through the filter
    col += phG * 0.085 * clamp(ghost, 0.0, 1.0);
    // phosphor: a hot core leaning white, the mesh in front of it
    float L1 = clamp(lit, 0.0, 1.0);
    vec3 em = ph * pw + vec3(0.07 * pw);
    // a section change flares its word: driven hot, nearly white, then cools
    em = em * (1.0 + 0.45 * flare) + vec3(0.32 * flare);
    em *= 1.0 - 0.38 * meshW;
    col = mix(col, em, L1);
    col += ph * 0.72 * clamp(legend, 0.0, 1.0) * pw * (1.0 - 0.3 * meshW);
    // halo and bloom: the tube's own (always) and the bloom budget's (wide)
    float halo = glowA * pw;
    col += ph * halo * (0.10 + 0.24 * bloomAmt) * (1.0 + 0.15 * beat * bloomAmt);
    // the mesh wires catch the room where nothing glows
    col += vec3(0.035) * meshW * (1.0 - L1) * mix(1.0, 0.6, light);
    // filament wires: two hairlines, barely there
    for (int k = 0; k < 2; k++) {
        float fy = res.y * (k == 0 ? 0.31 : 0.69) + sin(p.x * 0.013 + float(k)) * 0.6;
        float f = exp(-pow((p.y - fy) / (0.35 * sc + 0.2), 2.0));
        col += mix(phos.rgb, vec3(1.0), 0.6) * f * 0.035 * pw;
    }
    // the smoked front: a softbox reflection top-left, a fresnel lip, and the
    // bezel's shadow falling on the glass
    vec2 uv = qt_TexCoord0;
    // a softbox seen in the smoked front: a broad soft wash top-left with a
    // crisp lower edge, and the same moving band the plate's brushing shows
    float diag = uv.y + uv.x * 0.42;
    float refl = smoothstep(0.50, 0.40, diag) * 0.045 * smoothstep(-0.1, 0.4, diag);
    refl += exp(-pow((uv.y + uv.x * 0.18 - 0.06) / 0.03, 2.0)) * 0.03;
    float bx = p.x - bandX + (p.y - res.y * 0.5) * 0.18;
    refl += exp(-bx * bx / pow(res.x * 0.16, 2.0)) * 0.035;
    col += vec3(refl) * (1.0 - 0.6 * L1);
    float edgeT = p.y, edgeL = p.x, edgeR = res.x - p.x, edgeB = res.y - p.y;
    float shade = 1.0 - 0.55 * exp(-edgeT / (6.0 * sc)) - 0.3 * exp(-edgeL / (4.0 * sc)) - 0.2 * exp(-edgeR / (4.0 * sc));
    col *= clamp(shade, 0.0, 1.0);
    col += vec3(0.06) * exp(-edgeB / (1.2 * sc));           // the lower glass edge catches light
    col += vec3((hash(p) - 0.5) / 255.0);
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
