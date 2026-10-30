#version 440
// Orpheus "Nova": a starburst you fly through. Eight layers of stars stream
// out of the centre along their own rays at a constant speed in depth, so they
// crawl in the distance and whip past the edges; their streaks are drawn as
// true radial capsules, so a long tail never clips. Behind them, a slow nebula
// turns in the theme colours. The burst is coloured by direction: the spectrum
// is mirrored around the circle (bass below, treble above), so loud bands
// light their side of the sky brighter, and a spectral corona with diffraction
// spikes blooms out of the core in the same shape.
// Kicks slam: the camera punches in, every star stretches into a hyperspace
// streak, the core flares, the spikes lengthen and a colour-split shockwave
// rolls out. Snares make the stars twinkle and the spikes flicker. Light
// themes get pastel nebula ink, crisp coloured streaks and a bright opening.

//#common

const float PI = 3.14159265;
const int LAYERS = 8;
const float SPD = 0.32;      // depth cycles per unit of flow: ~3 s from the far plane to you at rest pace

float vnoise(vec2 x) {
    vec2 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 x) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * vnoise(x); x = x * 2.03 + vec2(1.7, 9.2); a *= 0.5; }
    return s;
}

float shape(float v) { return pow(clamp(v, 0.0, 1.0), 1.3); }

void main() {
    float m = min(res.x, res.y);
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;

    float hit = max(kick, beat * 0.8);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));
    float kh = hash(vec2(kicks, 2.1)) - 0.5;

    // ---- camera ---------------------------------------------------------------
    vec2 vp = vec2(sin(time * 0.11) * 0.05 + sin(time * 0.043) * 0.04, camBob(1.0) + sin(time * 0.083) * 0.025);
    vec2 p = (px - res * 0.5) / m - vp;
    p = rotateAround(p, vec2(0.0), camRoll() + time * 0.015 + hit * kh * 0.05);
    p /= 1.0 + loud * 0.08 + hit * 0.10;                     // push in with the swell, punch on kicks
    float pxU = 1.0 / m;
    float r = length(p) + 1e-5;
    float ang = atan(p.y, p.x);

    float u = abs(atan(p.x, -p.y)) / PI;                     // 0 = down (bass), 1 = up (treble)
    float lvl = shape(band(u));
    vec3 tint = pal(u);

    vec4 col = vec4(0.0);      // premultiplied, front to back
    vec3 L = vec3(0.0);        // additive light

    // ---- stars ---------------------------------------------------------------------
    float stretch = 0.012 + energy * 0.03 + hit * 0.30;      // tail length in depth
    float bright = 0.45 + lvl * 1.3 + snap * 0.4;
    for (int i = 0; i < LAYERS; i++) {
        float fi = float(i);
        float S = 60.0 + fi * 23.0;                           // sectors around the circle
        float sx = (ang / (2.0 * PI) + 0.5) * S + fi * 0.618;
        float side = fract(sx) < 0.5 ? -1.0 : 1.0;
        for (int j = 0; j < 2; j++) {                         // own sector and its nearer neighbour
            float sl = floor(sx) + (j == 0 ? 0.0 : side);
            float slw = mod(sl, S);
            float h = hash(vec2(slw, fi * 7.7 + 1.0));
            if (h < 0.35) continue;
            float h2 = hash(vec2(slw, fi * 3.1 + 40.0));
            float h3 = hash(vec2(slw, fi * 5.3 + 90.0));
            float thc = (sl + 0.5 + (h2 - 0.5) * 0.6 - fi * 0.618) / S * 2.0 * PI - PI;
            float dth = ang - thc;
            dth = dth - 2.0 * PI * floor((dth + PI) / (2.0 * PI));
            float rho = 0.015 + h3 * 0.10;
            float zf = fract(h * 13.7 + h2 * 3.1 + flow * SPD * (0.8 + 0.4 * h3));
            float z = 1.0 - zf * 0.97;                        // 1 = far plane, 0.03 = at your shoulder
            float rh = rho / z;
            float rt = rho / (z + stretch * (0.6 + h2));
            float along = r * cos(dth);
            float lat = abs(r * sin(dth)) * m;
            float out_ = max(max(rt - along, along - rh), 0.0) * m;
            float w = clamp(0.012 / z * (0.5 + h2), 0.45, 3.5);  // half-width in px
            float dist = length(vec2(lat, out_));
            float fade = smoothstep(1.0, 0.75, z) * (0.5 + 0.5 * h);
            float tw = 1.0 + snap * 0.8 * sin(h * 60.0 + time * 25.0);
            float core = clamp(w - dist + 0.5, 0.0, 1.0) * fade;
            // The tail dims toward its end so streaks read as motion, not bars.
            float tailT = clamp((rh - along) / max(rh - rt, 1e-4), 0.0, 1.0);
            core *= mix(1.0, 0.25, tailT);
            float uS = abs(abs(thc + PI * 0.5) - PI) / PI;    // spectrum position of the star's ray
            float sv = shape(band(1.0 - uS));
            float sb = (0.4 + sv * 1.4 + snap * 0.3) * tw * (1.0 + 0.6 * light);
            vec3 sc = mix(pal(1.0 - uS), fg.rgb, (0.45 * h2 + 0.15) * (1.0 - light));
            float a = clamp(core * sb, 0.0, 1.0);
            col.rgb += (1.0 - col.a) * a * sc;
            col.a += (1.0 - col.a) * a;
            L += glow(dist, w * 3.0 + 1.5) * fade * sb * 0.25 * (1.0 - z) * pal(1.0 - uS);
        }
    }

    // ---- far dust: static pinpricks that only turn with the camera -------------------
    {
        vec2 g = p * 70.0;
        vec2 id = floor(g);
        float h = hash(id + 3.3);
        vec2 o = vec2(hash(id + 7.1), hash(id + 1.9)) * 0.6 + 0.2;
        float d = length(fract(g) - o) / 70.0 * m;
        float tw = 0.5 + 0.5 * sin(h * 50.0 + time * (1.0 + h * 2.0));
        float a = clamp(0.7 - d, 0.0, 1.0) * step(0.86, h) * (0.15 + 0.25 * tw) * (1.0 - 0.4 * light);
        col.rgb += (1.0 - col.a) * a * mix(c3.rgb, fg.rgb, 0.5);
        col.a += (1.0 - col.a) * a;
    }

    // ---- shockwave: three colour-split rings roll out as the kick decays -------------
    {
        float e = 1.0 - kick;
        float sw = 0.06 + e * 0.75;
        float w = 0.003 + e * 0.012;
        float amt = kick * step(0.001, e) * (0.5 + bass * 0.5);
        vec3 ring = vec3(glow(r - sw - w * 0.6, w), glow(r - sw, w), glow(r - sw + w * 0.6, w));
        vec3 rc = c1.rgb * ring.x + c2.rgb * ring.y + c3.rgb * ring.z;
        L += rc * amt * 0.9;
        float ink = max(ring.x, max(ring.y, ring.z)) * amt * light * 0.45;
        col.rgb += (1.0 - col.a) * ink * c2.rgb;
        col.a += (1.0 - col.a) * ink;
    }

    // ---- corona, spikes, core ----------------------------------------------------------
    float cr = 0.05 + lvl * 0.16 + bass * 0.03 + hit * 0.03;
    float corona = exp(-pow(r / cr, 2.0)) * (0.25 + lvl * 0.5 + hit * 0.4);
    float rim = glow(r - cr, 0.005 + lvl * 0.008) * (0.25 + lvl * 0.6 + hit * 0.4);
    L += corona * tint + rim * mix(tint, fg.rgb, 0.3);
    // Diffraction spikes: six thin arms, longer and brighter on kicks, flickering on snares.
    {
        float a6 = mod(ang + time * 0.02, PI / 3.0) - PI / 6.0;
        float perp = abs(sin(a6)) * r;
        float len = 0.10 + bass * 0.10 + hit * 0.45;
        float spk = glow(perp, 0.0018 + r * 0.006) * exp(-r / len) * (0.25 + hit * 0.9 + snap * 0.3);
        L += spk * mix(c1.rgb, fg.rgb, 0.5);
    }
    float core = glow(r, 0.016 + bass * 0.012 + hit * 0.015) * (0.6 + hit * 1.2);
    L += core * mix(c1.rgb, fg.rgb, 0.6);
    // Light themes: the core and corona become a bright opening with a coloured rim.
    {
        float open = clamp(exp(-pow(r / (cr * 1.1), 2.0)) * (0.6 + hit * 0.3), 0.0, 1.0) * light;
        vec3 oc = mix(bg.rgb, vec3(1.0), 0.6);
        col.rgb += (1.0 - col.a) * open * oc;
        col.a += (1.0 - col.a) * open;
        float rimInk = clamp(1.4 - abs(r - cr) * m * 0.7, 0.0, 1.0) * (0.35 + lvl * 0.5) * light;
        col.rgb += (1.0 - col.a) * rimInk * tint;
        col.a += (1.0 - col.a) * rimInk;
    }

    // ---- nebula: a slow turning cloud in the theme colours, behind everything ---------
    {
        float rot = time * 0.01;
        vec2 q = rotateAround(p, vec2(0.0), rot);
        float lr = log(r + 0.05);
        vec2 dq = q / (length(q) + 1e-5);
        // Direction plus log-radius (no angle seam): the cloud drifts outward with the flow.
        vec2 polar = dq * 1.8 + vec2(lr * 1.6 - flow * 0.08, lr * 0.7);
        float n = fbm(q * 2.4 + vec2(time * 0.01, 0.0)) * 0.6 + fbm(polar) * 0.6;
        float neb = smoothstep(0.45, 1.0, n) * smoothstep(0.02, 0.25, r);
        vec3 nc = mix(pal(fract(n * 1.3 + 0.2)), tint, 0.4);
        float amt = neb * (0.10 + loud * 0.14 + hit * 0.10);
        L += nc * amt * 0.8;
        float ink = neb * (0.20 + loud * 0.15) * light;
        col.rgb += (1.0 - col.a) * ink * mix(nc, bg.rgb, 0.4);
        col.a += (1.0 - col.a) * ink;
    }

    vec3 g = L * (1.0 - 0.85 * light);
    vec3 gl = 1.0 - exp(-g * 1.4);
    col.rgb += gl;
    col.a += dot(gl, vec3(0.33)) * 0.6;
    col.a = clamp(col.a, 0.0, 1.0);

    // ---- vignette -----------------------------------------------------------------------
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.2, 0.85, length(vq * vec2(1.0, 0.9)));
    float va = vig * mix(0.6 - loud * 0.15, 0.12, light);
    vec3 vc = mix(vec3(0.0), bg.rgb * 0.82, light);
    col.rgb = col.rgb * (1.0 - va) + vc * va;
    col.a = col.a + va * (1.0 - col.a);

    fragColor = vec4(col.rgb + dither(px) * col.a, col.a) * qt_Opacity;
}
