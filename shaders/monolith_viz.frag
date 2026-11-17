#version 440
// Orpheus Monolith deck: the dot-matrix visualizer behind black smoked glass.
// 32 columns of round emitters, one per spectrum band, lit from the bottom up
// to the band's level (the top emitter fades in by the fraction), a peak-hold
// emitter in a second tint, and the unlit emitters still visible as dark
// lenses through the glass. Light blooms twice: a tight halo round every lit
// emitter and a wide soft glow off each column, both scaled by the bloom
// budget. Over it the glass: smoked, an inner shadow from the bezel, a
// reflection streak and a fresnel rim.
//
// Per frame only while the music runs (the item binds the bands only then).
// Pixel space, y down, premultiplied, opaque.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;
    float light;
    float bloomAmt;
    float beat;
    float energy;    // the music's overall level, 0..1
    float rad;       // the glass's corner radius
    vec4 lit;        // the emitter colour (accent)
    vec4 peak;       // the peak-hold tint
    vec4 glass;      // the smoked glass's own tint (near black)
    vec4 b0; vec4 b1; vec4 b2; vec4 b3; vec4 b4; vec4 b5; vec4 b6; vec4 b7;
    vec4 p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5; vec4 p6; vec4 p7;
};

const vec2 TOL = vec2(-0.59, -0.80);   // toward the key light, screen plane

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float sdRBox(vec2 p, vec2 h, float r) {
    vec2 q = abs(p) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float lv[32];
float pk[32];

// a column's level: its band, or between two bands when there are more columns
float bandAt(float a[32], float col, float cols) {
    float f = cols <= 32.0 ? col : (col + 0.5) / cols * 32.0 - 0.5;
    f = clamp(f, 0.0, 31.0);
    int i = int(floor(f));
    int j = min(31, i + 1);
    return clamp(mix(a[i], a[j], fract(f)), 0.0, 1.0);
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    float s = sc;
    vec4 B[8] = vec4[8](b0, b1, b2, b3, b4, b5, b6, b7);
    vec4 P[8] = vec4[8](p0, p1, p2, p3, p4, p5, p6, p7);
    for (int i = 0; i < 8; i++) {
        lv[i * 4] = B[i].x; lv[i * 4 + 1] = B[i].y; lv[i * 4 + 2] = B[i].z; lv[i * 4 + 3] = B[i].w;
        pk[i * 4] = P[i].x; pk[i * 4 + 1] = P[i].y; pk[i * 4 + 2] = P[i].z; pk[i * 4 + 3] = P[i].w;
    }

    // ---- the grid ----------------------------------------------------------
    // 32 columns, one a band; a wide, shallow window keeps at least 8 rows
    // and adds columns instead (the bands spread across them)
    float margin = 9.0 * s;
    float pitch = (res.x - 2.0 * margin) / 32.0;
    pitch = min(pitch, (res.y - 2.0 * margin) / 8.0);
    float colsF = min(96.0, floor((res.x - 2.0 * margin) / pitch + 0.01));
    float rows = max(4.0, floor((res.y - 2.0 * margin) / pitch));
    vec2 origin = vec2((res.x - colsF * pitch) * 0.5, (res.y - rows * pitch) * 0.5);   // top-left of the grid
    float er = pitch * 0.33;                                      // emitter radius

    vec2 gp = (p - origin) / pitch;
    vec2 cell = floor(gp);

    vec3 base = glass.rgb;
    vec3 col = base;
    vec3 emit = vec3(0.0);
    vec3 litC = lit.rgb;
    vec3 hotC = mix(litC, vec3(1.0), 0.55);
    float kickGain = 1.0 + 0.18 * beat;

    // the emitters near this pixel: its own cell and the ring round it
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 c = cell + vec2(dx, dy);
            if (c.x < 0.0 || c.x >= colsF || c.y < 0.0 || c.y >= rows) continue;
            int ci = int(c.x);
            float r = rows - 1.0 - c.y;                    // 0 = bottom row
            float level = clamp(lv[ci], 0.0, 1.0) * rows;
            float on = clamp(level - r, 0.0, 1.0);
            float pkRow = floor(clamp(pk[ci], 0.0, 1.0) * rows - 0.15);
            float isPk = (pkRow >= ceil(level) && abs(r - pkRow) < 0.5 && pk[ci] > 0.02) ? 1.0 : 0.0;
            vec2 ec = origin + (c + 0.5) * pitch;
            vec2 d = p - ec;
            float dist = length(d);
            // a little warmer and brighter up the column
            float hgt = r / max(1.0, rows - 1.0);
            vec3 ecol = mix(litC * 0.82, mix(litC, hotC, 0.18), hgt);
            float I = on * (0.62 + 0.38 * hgt) * kickGain;
            vec3 tint = ecol * I + peak.rgb * isPk * 1.05;
            float Itot = I + isPk;
            // the lens: a soft dome, hotter at the centre
            float disk = ss(er + 0.7, er - 0.7, dist);
            float dome = sqrt(max(0.0, 1.0 - (dist * dist) / (er * er)));
            if (dx == 0 && dy == 0) {
                // the dark lens of an unlit emitter, with its own tiny highlight
                vec3 lens = mix(base, litC, 0.07) + 0.025;
                lens *= 0.75 + 0.25 * dome;
                float hl = ss(er * 0.42, 0.0, length(d - vec2(-0.32, -0.36) * er));
                lens += vec3(0.10) * hl * (1.0 - 0.6 * light);
                col = mix(col, lens, disk);
                // lit: the colour, whitening at the core as it drives harder
                vec3 core = mix(tint, mix(tint, vec3(1.0), 0.40), pow(dome, 4.0) * min(1.0, Itot));
                emit += core * disk * (0.50 + 0.50 * dome);
            }
            // the tight halo round a lit emitter
            float halo = exp(-max(0.0, dist - er * 0.6) * max(0.0, dist - er * 0.6) / (er * er * 1.3));
            emit += tint * halo * 0.40 * bloomAmt * (1.0 - disk);
        }
    }

    // the wide glow off each column's lit run, a vertical segment of light
    if (bloomAmt > 0.0) {
        for (int dx = -3; dx <= 3; dx++) {
            float cx = cell.x + float(dx);
            if (cx < 0.0 || cx >= colsF) continue;
            float level = bandAt(lv, cx, colsF) * rows;
            if (level < 0.05) continue;
            float x = origin.x + (cx + 0.5) * pitch;
            float yb = origin.y + rows * pitch - pitch * 0.5;
            float yt = yb - max(0.0, level - 1.0) * pitch;
            float dyy = p.y > yb ? p.y - yb : (p.y < yt ? yt - p.y : 0.0);
            vec2 dd = vec2(p.x - x, dyy);
            float g = exp(-dot(dd, dd) / (pitch * pitch * 2.6));
            emit += litC * g * 0.08 * min(1.0, level / 3.0) * bloomAmt * kickGain;
        }
    }

    // a faint wash of the light over the whole glass, breathing with the music
    vec2 uv = p / res;
    emit += litC * energy * 0.06 * bloomAmt * ss(0.0, 1.0, uv.y);

    // tone: a soft shoulder so the hot cores never clip flat
    emit = emit / (1.0 + 0.25 * max(emit.r, max(emit.g, emit.b)));
    col += emit;

    // ---- the glass ---------------------------------------------------------
    vec2 hsz = res * 0.5;
    float d = sdRBox(p - hsz, hsz, rad);
    // inner shadow: the bezel's wall nearest the light shades the glass
    float sh = ss(-6.0 * s, 1.0, sdRBox(p - hsz + TOL * 4.0 * s, hsz, rad));
    col *= 1.0 - 0.55 * sh;
    col *= 1.0 - 0.35 * exp(d / (2.0 * s));
    // the reflection streak: a long soft band of the room across the glass
    vec2 dir = normalize(vec2(1.0, -0.62));
    float across = dot(uv - vec2(0.30, 0.24), vec2(-dir.y, dir.x) * vec2(res.x / res.y, 1.0));
    float streak = exp(-across * across / 0.0035) * 0.075 + exp(-across * across / 0.03) * 0.03;
    streak *= ss(1.05, 0.2, uv.x + uv.y * 0.3);
    // a second, thinner one lower down
    float a2 = dot(uv - vec2(0.62, 0.62), vec2(-dir.y, dir.x) * vec2(res.x / res.y, 1.0));
    streak += exp(-a2 * a2 / 0.0006) * 0.025;
    // the top half catches a little more of the room
    float sky = 0.045 * ss(0.75, 0.0, uv.y);
    // fresnel: the rim brightens where the glass meets its frame
    float fres = exp(d / (1.6 * s)) * 0.08 * ss(0.0, 1.0, 1.0 - uv.y * 0.8);
    col += vec3(1.0) * (streak + sky + fres);
    // a hairline of light along the glass's top edge
    col += vec3(1.0) * 0.10 * ss(1.2 * s, 0.0, abs(p.y - 1.4 * s)) * ss(0.0, 6.0 * s, min(p.x, res.x - p.x));

    col += (hash(p) - 0.5) / 255.0;
    float a = clamp(0.5 - d, 0.0, 1.0);
    fragColor = vec4(col * a, a) * qt_Opacity;
}
