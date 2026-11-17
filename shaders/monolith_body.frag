#version 440
// Orpheus Monolith deck (WidgetMonolith.qml): the block itself. One piece of
// bead-blasted aluminium, anodised in the theme, seen from just above: a
// diamond-cut chamfer round the face that catches a top-left key light, a
// fine isotropic grain, a broad soft sheen, a sliver of the block's front
// wall, and a contact shadow on the desk. Every opening (the visualizer
// window, the art well, the display, the seek slot, the key holes, the LED,
// the wheel slot) is cut into it with a machined lip; what sits in an opening
// is drawn by its own item on top.
//
// Static: no clock. The item is layer-cached, so this runs on a resize or a
// theme change, never per frame. Pixel space, y down, premultiplied output.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 res;
    float sc;        // deck scale (1 = the 400 px design)
    float light;     // 1 on a light theme
    vec4 metal;      // the anodised tone
    vec4 accent;
    vec4 rBody;      // x, y, w, h of the top face
    vec4 rViz; vec4 rArt; vec4 rLcd; vec4 rSeek;
    vec4 rK0; vec4 rK1; vec4 rK2; vec4 rK3; vec4 rK4;
    vec4 rWheel;     // the wheel's slot
    vec4 rLed;       // the status LED's hole
    vec4 rGrille;    // the speaker grille's field (w = 0: none)
    vec4 radA;       // body, viz, art, lcd corner radii
    vec4 radB;       // seek, big key, small key, wheel
};

const vec3 LDIR = vec3(-0.50, -0.68, 0.53);   // toward the key light (top left, y down)

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float sdRBox(vec2 p, vec4 r, float rad) {
    vec2 h = r.zw * 0.5;
    vec2 q = abs(p - r.xy - h) - h + rad;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}
float sdBody(vec2 p) { return sdRBox(p, rBody, radA.x); }
vec2 gradBody(vec2 p) {
    vec2 e = vec2(0.5, 0.0);
    return normalize(vec2(sdBody(p + e.xy) - sdBody(p - e.xy), sdBody(p + e.yx) - sdBody(p - e.yx)) + 1e-6);
}
vec2 gradBox(vec2 p, vec4 r, float rad) {
    vec2 e = vec2(0.5, 0.0);
    return normalize(vec2(sdRBox(p + e.xy, r, rad) - sdRBox(p - e.xy, r, rad),
                          sdRBox(p + e.yx, r, rad) - sdRBox(p - e.yx, r, rad)) + 1e-6);
}

// Lit metal: a soft diffuse term plus a broad dye-tinted specular, the
// anodised look (the colour lives in the oxide, so highlights carry it).
vec3 shade(vec3 alb, vec3 n, float gloss, float specAmt) {
    vec3 L = normalize(LDIR);
    float wrap = clamp((dot(n, L) + 0.35) / 1.35, 0.0, 1.0);
    vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
    float sp = pow(max(dot(n, H), 0.0), gloss);
    vec3 spc = mix(vec3(1.0), alb / max(0.001, max(alb.r, max(alb.g, alb.b))), 0.35 + 0.25 * light);
    return alb * (0.30 + 0.86 * wrap) + spc * sp * specAmt;
}

void main() {
    vec2 p = qt_TexCoord0 * res;
    float s = sc;
    vec3 M = metal.rgb;
    float dB = sdBody(p);

    // ---- below the face: the block's front wall, then the desk shadow -------
    float thick = 7.0 * s;
    if (dB > 0.0) {
        vec4 o = vec4(0.0);
        // contact shadow on the desk: a wide soft one under the block's footprint
        // and a tight dark one where it meets the desk
        float dS = sdRBox(p - vec2(2.0 * s, thick + 7.0 * s), rBody + vec4(5.0, 0.0, -10.0, 0.0) * s, radA.x);
        float dC = sdRBox(p - vec2(0.5 * s, thick + 0.5 * s), rBody + vec4(1.5, 0.0, -3.0, 0.0) * s, radA.x);
        float shA = 0.42 * exp(-max(dS, 0.0) / (13.0 * s)) * ss(-14.0 * s, 10.0 * s, -dS + 6.0 * s);
        shA = max(shA, 0.62 * exp(-max(dC, 0.0) / (2.4 * s)));
        shA *= mix(1.0, 0.55, light);
        o = vec4(0.0, 0.0, 0.0, shA);
        // the front wall: the face's outline swept down by the block's thickness
        float dW = sdBody(p - vec2(0.0, thick));
        if (dW < 0.0 && p.y > rBody.y + rBody.w * 0.5) {
            float t = clamp((p.y - (rBody.y + rBody.w)) / thick + 0.0, 0.0, 1.0);
            // facing the viewer and down: in the light's shade, with a bounce off
            // the desk along its foot and the chamfer's glint along its top
            vec3 wall = M * mix(0.42, 0.26, t);
            float xg = (p.x - rBody.x) / rBody.z;
            wall *= 0.92 + 0.16 * ss(0.0, 0.45, xg) * ss(1.0, 0.55, xg);
            wall += M * 0.20 * ss(0.55, 1.0, t);
            wall += vec3(1.0) * 0.06 * ss(0.1, 0.0, t);
            // the wall's own rounded ends darken into the corner radius
            float side = ss(0.0, -3.0 * s, dW);
            wall *= mix(0.55, 1.0, side);
            wall += (hash(floor(p)) - 0.5) * 0.02;
            float a = clamp(-dW + 0.5, 0.0, 1.0);
            o = vec4(wall * a, a) + o * (1.0 - a);
        }
        fragColor = o * qt_Opacity;
        return;
    }

    // ---- the top face ------------------------------------------------------
    vec2 uv = (p - rBody.xy) / rBody.zw;
    // bead blast: a fine isotropic grain (two scales) and the odd glint
    float g1 = hash(floor(p * 1.0));
    float g2 = vnoise(p * 0.55);
    float g3 = vnoise(p * 0.09 + 3.1);
    float gk = mix(1.0, 0.45, light);
    float grain = ((g1 - 0.5) * 0.050 + (g2 - 0.5) * 0.022) * gk + (g3 - 0.5) * 0.035;
    float glint = step(0.9982, hash(floor(p) + 17.0)) * mix(0.09, 0.05, light);
    vec3 alb = M * (1.0 + grain);

    // studio light: brighter toward the top left, falling off to the bottom right
    float fall = mix(1.16, 0.80, ss(0.0, 1.0, uv.y * 0.78 + uv.x * 0.30));
    vec3 n = vec3(0.0, 0.0, 1.0);
    vec3 col = shade(alb, n, 6.0, 0.10) * fall;

    // a soft anisotropic sheen: a long, blurred reflection of the softbox
    // lying across the face (bead blast scatters it into a broad band)
    vec2 q = uv - vec2(0.22, 0.20);
    vec2 da = normalize(vec2(1.0, 0.42));
    float along = dot(q, da), across = dot(q, vec2(-da.y, da.x));
    float sheen = exp(-across * across / 0.02) * exp(-along * along / 0.45);
    float sheen2 = exp(-pow(dot(uv - vec2(0.85, 0.92), vec2(-da.y, da.x)), 2.0) / 0.01) * 0.35;
    col += mix(vec3(1.0), M / max(0.01, max(M.r, max(M.g, M.b))), 0.45) * (sheen + sheen2) * mix(0.16, 0.20, light);
    col += glint;

    // ---- the chamfer: diamond cut, bright where it faces the light -----------
    float cw = 3.2 * s;
    if (dB > -cw - 1.0) {
        vec2 gb = gradBody(p);
        float t = clamp(-dB / cw, 0.0, 1.0);          // 0 at the outer edge
        // a 45 degree cut, rolled over at both ends
        float slope = mix(1.6, 0.9, ss(0.0, 0.35, t)) * ss(1.0, 0.75, t);
        vec3 cn = normalize(vec3(gb * slope, 1.0));
        vec3 calb = mix(M, vec3(dot(M, vec3(0.33))) + 0.18, 0.28 + 0.12 * light);
        vec3 cc = shade(calb, cn, 18.0, 1.45);
        float k = ss(cw + 1.0, cw - 0.5, -dB);
        col = mix(col, cc, k);
        // the very edge: a dark hairline where the face turns away
        col *= mix(0.65, 1.0, ss(0.0, 1.0, -dB));
    }

    // ---- the openings --------------------------------------------------------
    // Each is a hole with a machined lip (a small chamfer down into it). The
    // floor is dark; the item in the opening covers it, leaving the lip.
    vec4 rs[11];
    float rr[11];
    float depth[11];
    rs[0] = rViz;  rr[0] = radA.y; depth[0] = 1.0;
    rs[1] = rArt;  rr[1] = radA.z; depth[1] = 1.0;
    rs[2] = rLcd;  rr[2] = radA.w; depth[2] = 0.8;
    rs[3] = rSeek; rr[3] = radB.x; depth[3] = 0.9;
    rs[4] = rK0;   rr[4] = radB.z; depth[4] = 0.6;
    rs[5] = rK1;   rr[5] = radB.y; depth[5] = 0.6;
    rs[6] = rK2;   rr[6] = radB.y; depth[6] = 0.6;
    rs[7] = rK3;   rr[7] = radB.y; depth[7] = 0.6;
    rs[8] = rK4;   rr[8] = radB.z; depth[8] = 0.6;
    rs[9] = rWheel; rr[9] = radB.w; depth[9] = 1.0;
    rs[10] = rLed; rr[10] = rLed.z * 0.5; depth[10] = 0.5;
    float lip = 1.8 * s;
    for (int i = 0; i < 11; i++) {
        if (rs[i].z <= 0.0) continue;
        float d = sdRBox(p, rs[i], rr[i]);
        // a soft occlusion ring on the face just outside every opening
        col *= 1.0 - 0.10 * depth[i] * exp(-max(d, 0.0) / (2.0 * s)) * step(0.0, d);
        if (d > 0.5) continue;
        vec2 g = gradBox(p, rs[i], rr[i]);
        if (d > -lip) {
            // the lip: sloping down into the hole (normal leans inward)
            float t = clamp(-d / lip, 0.0, 1.0);
            vec3 ln = normalize(vec3(-g * mix(1.4, 0.7, t), 1.0));
            vec3 lalb = mix(M, vec3(dot(M, vec3(0.33))) + 0.25, 0.3 + 0.15 * light);
            vec3 lc = shade(lalb, ln, 24.0, 0.75);
            // the far wall of the lip falls into the hole's own shade
            lc *= mix(1.0, 0.55, t * t);
            float a = clamp(0.5 - d, 0.0, 1.0);
            col = mix(col, lc, a);
        } else {
            // the floor: deep and dark, a little of the metal's tint, shaded by
            // the wall nearest the light
            vec3 fl = M * 0.16 + 0.012;
            vec2 toL = normalize(LDIR.xy);
            float sh = ss(-3.0 * s, 1.0 * s, sdRBox(p + toL * 5.0 * s * depth[i], rs[i], rr[i]));
            fl *= 1.0 - 0.6 * sh;
            col = fl;
        }
    }

    // ---- the seek scale: etched ticks under the slot, every 5 %, longer at
    // the quarters ------------------------------------------------------------
    {
        float x0 = rSeek.x + rSeek.w * 0.5, x1 = rSeek.x + rSeek.z - rSeek.w * 0.5;
        float yT = rSeek.y + rSeek.w + 4.0 * s;
        float u = (p.x - x0) / (x1 - x0) * 20.0;
        float k = floor(u + 0.5);
        if (k >= 0.0 && k <= 20.0) {
            float major = mod(k, 5.0) < 0.5 ? 1.0 : 0.0;
            float len = mix(2.2, 4.0, major) * s;
            float tx = x0 + k / 20.0 * (x1 - x0);
            float dx = abs(p.x - tx);
            float w = 0.5 * max(1.0, 0.8 * s);
            float cov = ss(w + 0.5, w - 0.5, dx) * ss(-0.5, 0.5, p.y - yT) * ss(0.5, -0.5, p.y - yT - len);
            // the cut: a groove that shades its top, its foot catching the light
            vec3 cut = mix(M * 0.30, M * 0.62 + 0.05, light);
            col = mix(col, cut, cov * 0.85);
            float foot = ss(w + 0.5, w - 0.5, dx) * ss(0.9, 0.0, abs(p.y - yT - len - 0.6));
            col += vec3(1.0) * foot * mix(0.10, 0.28, light);
        }
    }

    // ---- the speaker grille: a field of drilled holes ----------------------
    if (rGrille.z > 0.0) {
        float pitch = 8.0 * s;
        vec2 gp = p - rGrille.xy;
        if (gp.x > -pitch && gp.y > -pitch && gp.x < rGrille.z + pitch && gp.y < rGrille.w + pitch) {
            vec2 cell = floor(gp / pitch);
            // offset every other row: a hex-ish drilling pattern
            float off = mod(cell.y, 2.0) * 0.5;
            cell = floor(vec2(gp.x / pitch - off, gp.y / pitch));
            vec2 c = (cell + vec2(0.5 + off, 0.5)) * pitch;
            bool inField = sdRBox(c + rGrille.xy, rGrille, 9.0 * s) < -1.0 * s;
            if (inField) {
                vec2 lp = gp - c;
                float r = 2.05 * s;
                float d = length(lp) - r;
                if (d < 0.8) {
                    vec2 g = normalize(lp + 1e-5);
                    float t = clamp(-d / (0.9 * s), 0.0, 1.0);
                    vec3 ln = normalize(vec3(-g * 1.2, 1.0));
                    vec3 lc = shade(mix(M, vec3(dot(M, vec3(0.33))) + 0.25, 0.3), ln, 20.0, 0.6);
                    vec3 hole = M * 0.10;
                    vec3 hc = mix(lc, hole, ss(0.2, 0.8, t));
                    col = mix(col, hc, clamp(0.5 - d, 0.0, 1.0));
                }
            }
        }
    }

    float a = clamp(0.5 - dB, 0.0, 1.0);
    col += (hash(p + 0.37) - 0.5) / 255.0;
    fragColor = vec4(col * a, a) * qt_Opacity;
}
