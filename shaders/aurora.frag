#version 440
// Orpheus "Aurora": northern lights over a still mountain lake. Four curtains
// of light hang at different depths, near ones high and broad, far ones low
// and tightly folded, each a bright lower hem fading up into rays. They fold
// and drift slowly across a deep night sky; the lake below holds a rippled
// reflection of everything above it.
// The calm one, but it listens: the spectrum lifts and brightens the curtains
// across the width (bass in the middle), kicks send a shimmer rippling along
// them, the swell brightens, a build agitates the folds and sharpens the rays,
// a drop erupts into a corona overhead, and the song's section picks which
// palette colour leads. Light themes get a dusk sky with softer, ink-like
// curtains. Closed form per pixel: a few octaves of 1D noise per curtain.

//#common

const int L = 4;             // curtains, near (0) to far
const float HY = 0.30;       // the shoreline, in view heights from the bottom

// Smooth 1D value noise, -1..1.
float n1(float x, float s) {
    float i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash(vec2(i, s)), hash(vec2(i + 1.0, s)), f) * 2.0 - 1.0;
}

float peakBand(float x) {
    float f = clamp(x, 0.0, 1.0) * 31.0;
    int i = int(floor(f));
    return mix(peakAt(i), peakAt(i + 1), smoothstep(0.0, 1.0, fract(f)));
}

// The far range and the nearer hills that frame the lake, as heights (view units).
float farRange(float x) {
    return HY + 0.030 + 0.022 * n1(x * 3.1 + 4.0, 1.0) + 0.012 * n1(x * 8.3, 2.0) + 0.004 * n1(x * 29.0, 3.0);
}
float nearHills(float x, float A) {
    float e = abs(x / A - 0.5) * 2.0;                        // 0 centre .. 1 edges
    float rise = smoothstep(0.35, 1.0, e);
    return HY - 0.01 + rise * (0.10 + 0.035 * n1(x * 4.7 + 9.0, 4.0)) + 0.008 * n1(x * 17.0, 5.0) + 0.002 * n1(x * 61.0, 6.0);
}

// Kick shimmer at screen x: each of the last three kicks starts at its own
// point on the curtains and spreads both ways along them.
float shimmerAt(float x, float A) {
    float s = 0.0;
    for (int j = 0; j < 3; j++) {
        float ai = kickAge[j];
        if (ai >= 3.0) continue;
        float kid = kicks - float(j);
        float x0 = A * (0.15 + 0.7 * hash(vec2(kid, 3.7)));
        float front = abs(x - x0) - ai * 0.85;
        float w = 0.05 + ai * 0.06;
        float str = (j == 0 ? 0.5 + 0.5 * kickAge.w : 0.85) * exp(-ai * 1.3);
        s += exp(-front * front / (w * w)) * str * smoothstep(0.0, 0.04, ai + 0.005);
    }
    return s;
}

// Lead colours for the section: base of the curtain, its upper rays, the fringe.
void sectionPal(out vec3 cb, out vec3 ct, out vec3 cf) {
    int s = int(section + 0.5);
    if (s == 1)      { cb = c3.rgb; ct = c1.rgb; cf = c2.rgb; }   // build: the cool one leads
    else if (s == 2) { cb = c2.rgb; ct = c3.rgb; cf = c1.rgb; }   // drop: the bold one leads
    else if (s == 3) { cb = c1.rgb; ct = c3.rgb; cf = c2.rgb; }   // breakdown
    else             { cb = c1.rgb; ct = c2.rgb; cf = c3.rgb; }   // intro, steady: home
}

// Aurora light (linear-ish, unbounded) at q (view-height units, y up).
vec3 aurora(vec2 q, float A, float shim, vec3 cb, vec3 ct, vec3 cf) {
    vec3 acc = vec3(0.0);
    float xn = (q.x / A - 0.5) * 2.0;                        // -1..1 across the width
    float agit = build;
    float glob = (0.55 + 0.55 * swell + 0.45 * build) * (1.0 + 1.3 * shim);
    for (int i = 0; i < L; i++) {
        float z = float(i) / float(L - 1);                   // 0 near .. 1 far
        float fi = float(i);
        float sd = fi * 7.31 + 1.0;
        // The curtain's own frame: far ones compressed (more folds in view) and drifting.
        float xs = (q.x - A * 0.5) * mix(1.0, 2.3, z);
        float dir = mod(fi, 2.0) < 0.5 ? 1.0 : -1.0;
        float u = xs * 1.5 + dir * time * (0.010 + 0.006 * fi) + flow * 0.004 + fi * 13.7;
        // Folds: two slow octaves, a faster one, and a build's agitation on top.
        float t = time;
        float Fs = n1(u * 1.0 + t * 0.020, sd) * 0.60 + n1(u * 2.6 - t * 0.037, sd + 1.0) * 0.28
                 + agit * n1(u * 3.3 + t * 0.55, sd + 3.0) * 0.45;
        float e = 0.02;
        float Fe = n1((u + e) * 1.0 + t * 0.020, sd) * 0.60 + n1((u + e) * 2.6 - t * 0.037, sd + 1.0) * 0.28
                 + agit * n1((u + e) * 3.3 + t * 0.55, sd + 3.0) * 0.45;
        float grad = abs(Fe - Fs) / e;                       // steep folds are curtains seen edge-on
        float F = Fs + n1(u * 6.1 + t * 0.08, sd + 2.0) * 0.12;

        // The music across the width, bass in the middle; each curtain reads a slightly different slice.
        float bx = clamp(abs(xn) * (0.80 + 0.1 * z) + 0.04 * z, 0.0, 1.0);
        float v = clamp(band(bx), 0.0, 1.0);
        float pk = clamp(peakBand(bx), 0.0, 1.0);
        v = smoothstep(0.0, 0.9, v);

        // The lower hem: an arc that sags toward the edges, folded, lifted by the music and the shimmer.
        float base = HY + mix(0.31, 0.08, z) - mix(0.10, 0.025, z) * xn * xn + 0.015 * sin(time * 0.05 + fi * 2.1)
                   + mix(0.09, 0.03, z) * n1(xs * 0.45 + time * 0.012 + fi * 3.3, sd + 8.0);   // each its own long sweep
        float amp = mix(0.13, 0.04, z) * (1.0 + 0.4 * agit);
        float yb = base + amp * F + shim * mix(0.014, 0.006, z) + v * mix(0.03, 0.012, z);
        float H = mix(0.24, 0.085, z) * (0.6 + 0.8 * v + 0.15 * swell);
        float dy = q.y - yb;
        float edge = mix(0.004, 0.002, z);
        if (dy < -edge * 8.0 || dy > H * 4.0) continue;      // well outside this curtain

        // Rays: thin vertical striations that follow the folds and shimmer slowly.
        float ur = u + F * 0.22;
        float r1 = n1(ur * 52.0 + time * 0.25, sd + 4.0) * 0.5 + 0.5;
        float r2 = n1(ur * 131.0 - time * 0.4 + agit * time * 0.9, sd + 5.0) * 0.5 + 0.5;
        float rays = r1 * r1 * (0.55 + 0.45 * r2);
        rays = mix(rays, pow(rays, 1.8), agit * 0.6);
        // Ray reach varies ray to ray, and the peaks push the tallest further.
        float reach = 0.45 + 0.9 * pow(n1(ur * 17.0, sd + 6.0) * 0.5 + 0.5, 1.5) + 0.6 * pk;
        // The curtain thins and thickens along its length.
        float patchy = 0.08 + 0.92 * smoothstep(-0.25, 0.6, n1(u * 0.7 - time * 0.015, sd + 7.0) + 0.3 * v - 0.2 * z);

        float below = smoothstep(-edge * 3.0, 0.0, dy);
        float ry = max(dy, 0.0) / (H * reach);
        float upper = exp(-ry * ry * 0.8 - ry * 0.6);
        float hem = exp(-max(dy, 0.0) / (H * 0.10));         // the bright lower band
        float prof = below * (upper * (0.18 + 0.82 * rays) + hem * (0.55 + 0.45 * rays));

        float foldB = 0.75 + 0.8 * smoothstep(0.8, 3.0, grad);
        float I = prof * foldB * patchy * (0.45 + 1.0 * v) * mix(1.0, 0.55, z) * glob;

        float tv = clamp(dy / H, 0.0, 1.0) * (1.0 - 0.55 * z);   // far curtains stay in their base colour
        vec3 c = mix(cb, ct, smoothstep(0.35, 1.3, tv));
        c = mix(c, cf, glow(dy + edge, edge * 2.0) * 0.45 * (1.0 - z));   // a faint lower fringe
        c = mix(c, fg.rgb, shim * 0.25 * hem);
        acc += c * I;
    }

    // A drop erupts overhead: a corona, rays converging on a point above the view.
    if (drop > 0.002) {
        vec2 Z = vec2(A * 0.5, 1.22);
        vec2 d = q - Z;
        float r = length(d);
        float ang = atan(d.x, -d.y);
        float cr = n1(ang * 38.0 + time * 0.3, 21.0) * 0.5 + 0.5;
        cr = cr * cr * (0.4 + 0.6 * (n1(ang * 97.0 - time * 0.5, 22.0) * 0.5 + 0.5));
        float low = smoothstep(HY + 0.05, HY + 0.4, q.y);   // the crown stays overhead
        float ringR = 0.25 + (1.0 - drop) * 0.9;                // the burst front races outward
        float ring = glow(r - ringR, 0.05 + (1.0 - drop) * 0.12);
        float fill = exp(-max(r - 0.22, 0.0) / (0.16 + 0.22 * drop)) * smoothstep(0.18, 0.3, r);
        float co = drop * (fill * 0.9 + ring * 0.7) * (0.15 + 0.85 * cr) * low;
        vec3 cc = mix(ct, cf, smoothstep(0.2, 0.9, r));
        acc += mix(cc, fg.rgb, ring * 0.15) * co * 1.3;
    }
    return acc;
}

// Stars on a jittered grid. Every star twinkles at its own slow rate, the same
// range everywhere in the sky; near the horizon they only dim.
float stars(vec2 p, float cellPx, out float hue) {
    vec2 cell = floor(p / cellPx);
    vec2 at = (cell + 0.2 + 0.6 * vec2(hash(cell + 3.1), hash(cell + 5.7))) * cellPx;
    float h0 = hash(cell), h1 = hash(cell + 7.0), h2 = hash(cell + 11.0);
    hue = h2;
    float rate = 1.3 + h1 * 1.9;                             // ~0.2-0.5 Hz
    float tw = 0.62 + 0.26 * sin(time * rate + h0 * 40.0) + 0.12 * sin(time * rate * 1.73 + h2 * 20.0);
    float rad = (0.75 + h1 * 0.6) * max(1.0, cellPx / 9.0);
    float mag = step(0.90, h0) * (0.35 + 0.65 * fract(h0 * 17.0));
    return mag * tw * glow(length(p - at), rad);
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float A = res.x / res.y;
    float dark = 1.0 - light;
    vec2 q = px / res.y;

    vec3 cb, ct, cf;
    sectionPal(cb, ct, cf);

    // Below the shore: the lake, a mirror rippled more the nearer it gets.
    bool water = q.y < HY;
    float wd = water ? (HY - q.y) / HY : 0.0;               // 0 at the shore .. 1 at the bottom
    vec2 s = q;
    if (water) {
        float rip = sin(q.y * 1.0 * (120.0 + 900.0 * wd) + time * 1.1 + sin(q.x * 9.0 + time * 0.4) * 1.5)
                  + 0.5 * sin(q.y * (260.0 + 1400.0 * wd) - time * 1.7 + q.x * 3.0);
        s.y = 2.0 * HY - q.y;
        s.x += rip * (0.0012 + 0.006 * wd) * (1.0 + 0.6 * kick);
        s.y += rip * 0.0015 * wd;
    }

    // ---- sky -----------------------------------------------------------------------
    float up = clamp((s.y - HY) / (1.0 - HY), 0.0, 1.0);
    vec3 nightTop = bg.rgb * 0.30 + c1.rgb * 0.015;
    vec3 nightLow = bg.rgb * 0.85 + c1.rgb * 0.035;
    vec3 duskTop = mix(bg.rgb, fg.rgb, 0.38) * 0.9;
    vec3 duskLow = mix(bg.rgb, mix(c2.rgb, vec3(1.0, 0.75, 0.6), 0.5), 0.25);
    vec3 sky = mix(mix(nightLow, nightTop, pow(up, 0.6)), mix(duskLow, duskTop, pow(up, 0.8)), light);

    vec2 sp = vec2(s.x, s.y) * res.y;                         // stars in pixels, mirrored for the lake
    float hue;
    float st = stars(sp, max(res.y / 160.0, 5.0), hue);
    st *= smoothstep(0.0, 0.25, up) * 0.55 + 0.45 * smoothstep(0.0, 0.04, up);
    st *= (1.0 - 0.8 * light) * (0.85 + 0.3 * swell);
    sky += mix(fg.rgb, mix(c3.rgb, fg.rgb, 0.5), hue) * st * 0.85;

    // ---- the aurora ------------------------------------------------------------------
    float shim = shimmerAt(s.x, A);
    vec3 au = aurora(s, A, shim, cb, ct, cf);
    // Its diffuse light washes the sky just above the far range.
    float wash = exp(-max(s.y - HY, 0.0) / 0.22) * (0.10 + 0.20 * swell + 0.25 * build + 0.3 * drop);
    vec3 washC = mix(cb, ct, 0.3) * wash * faux(1.0, 0.5);

    vec3 col;
    if (light < 0.5) {
        vec3 g = (au * faux(1.0, 0.35) + washC * 0.35) * 1.5;
        // Hue-keeping tone curve: bright curtains saturate toward their colour, not white.
        float m = max(max(g.r, g.g), g.b);
        col = sky + g * (1.0 - exp(-m)) / max(m, 1e-4);
    } else {
        // Dusk: the curtains as soft coloured veils rather than light.
        float lum = dot(au, vec3(0.3, 0.5, 0.2));
        vec3 hueC = au / max(max(au.r, max(au.g, au.b)), 1e-3);
        hueC = mix(hueC, (hueC - min(hueC.r, min(hueC.g, hueC.b))) / 0.8, 0.35);
        float a = (1.0 - exp(-max(lum - 0.06, 0.0) * 2.6)) * 0.8;   // the faint wash stays off, or it greys the dusk
        col = mix(sky, hueC * 0.68, a * 0.85);
        col = mix(col, mix(cb, bg.rgb, 0.4), wash * 0.25);
    }

    // ---- mountains: the far range hazed by the aurora's light, the near hills black ----
    {
        float aa = 1.0 / res.y;
        float fr = farRange(s.x);
        float aF = clamp((fr - s.y) / aa + 0.5, 0.0, 1.0);
        vec3 farC = mix(bg.rgb * 0.42 + mix(cb, ct, 0.3) * 0.05 * (1.0 + swell), mix(bg.rgb, fg.rgb, 0.42), light);
        // The crest catches the curtains' glow.
        float rim = glow(fr - s.y, 0.002) * (0.05 + 0.15 * swell + 0.3 * shim) * dark;
        col = mix(col, farC, aF);
        col += cb * rim * (1.0 - aF * 0.5) * faux(1.0, 0.3);
        float nh = nearHills(s.x, A);
        float aN = clamp((nh - s.y) / aa + 0.5, 0.0, 1.0);
        vec3 nearC = mix(bg.rgb * 0.16, mix(bg.rgb, fg.rgb, 0.62) * 0.8, light);
        col = mix(col, nearC, aN);
    }

    // ---- the lake: darker, a little tinted, brighter toward the shore (fresnel) ----------
    if (water) {
        float refl = mix(0.62, 0.30, pow(wd, 0.7));
        vec3 deep = mix(bg.rgb * 0.18, mix(bg.rgb, fg.rgb, 0.28), light);
        col = mix(deep, col, mix(refl, refl + 0.15, light));
        // A faint glint line where the shore meets the water.
        float seam = glow(HY - q.y, 0.0012) * (0.04 + 0.08 * swell) * dark;
        col += mix(cb, fg.rgb, 0.5) * seam;
    }

    // Vignette.
    vec2 vq = qt_TexCoord0 - 0.5;
    float vig = smoothstep(0.35, 0.9, length(vq * vec2(1.0, 1.25))) * mix(0.5, 0.12, light);
    col = mix(col, bg.rgb * mix(0.2, 0.85, light), vig);

    fragColor = vec4(col + dither(px), 1.0) * qt_Opacity;
}
