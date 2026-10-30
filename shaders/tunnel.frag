#version 440
// Orpheus "Tunnel": flying through a winding tube of light rings. The tube is
// a real 3D path: every ring sits at a fixed depth along a curve and is
// projected through a camera that rides the curve and banks into the bends,
// so the tunnel snakes away to a glowing vanishing point. Each ring is the
// spectrum wrapped around the tube (bass at the bottom, treble meeting at the
// top), swelling hardest near you and calming with depth. The walls between
// the rings are lit by them, panel lights stream past on the beat of the
// snares, dust streaks rush by, and fog swallows the far end.
// Kicks slam: the camera punches forward and kicks sideways, the rings
// overdrive, a pulse races down the tube, the vanishing point flares with an
// anamorphic streak and the lens splits colour for a moment. Loudness swells
// the push-in and the haze. Loops are bounded (32 rings, 6 dust layers).

//#common

const float PI = 3.14159265;
const int N = 32;            // rings in view
const float SP = 0.55;       // world spacing between rings
const float RW = 1.0;        // tube radius
const float SPEED = 2.4;     // world units per unit of flow

vec2 path(float z) {
    return vec2(sin(z * 0.13) * 2.4 + sin(z * 0.051 + 1.3) * 3.0,
                sin(z * 0.093 + 0.4) * 1.6 + cos(z * 0.041) * 1.4);
}

// Shape a band level: quiet stays small, loud dominates.
float shape(float v) { return pow(clamp(v, 0.0, 1.0), 1.4); }

// Angle around a ring centre -> mirrored spectrum position (0 bass at the bottom, 1 treble on top).
float specU(vec2 d) { return abs(atan(d.x, -d.y)) / PI; }

void main() {
    float m = min(res.x, res.y);
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 p = (px - res * 0.5) / m;
    float pxU = 1.0 / m;

    float hit = max(kick, beat * 0.8);
    float kh = hash(vec2(kicks, 3.7)) - 0.5;                 // per-kick variation
    float loud = smoothstep(0.03, 0.8, max(swell, energy));

    // ---- camera -------------------------------------------------------------
    float zc = flow * SPEED;
    vec2 cam = path(zc);
    vec2 aim = (path(zc + 4.0) - cam) / 4.0;                 // look a little ahead
    vec2 aim2 = (path(zc + 8.0) - path(zc + 4.0)) / 4.0;
    float bank = clamp((aim2.x - aim.x) * 4.0, -0.35, 0.35); // lean into the bend
    float roll = camRoll() + bank + hit * kh * 0.06;
    p = rotateAround(p, vec2(0.0), roll);
    p += vec2(kh, hash(vec2(kicks, 9.1)) - 0.5) * hit * 0.018;   // a sideways jolt per kick
    float FOC = 0.55 * (1.0 + loud * 0.18 + hit * 0.16);    // push in with the loudness, punch on kicks

    vec4 col = vec4(0.0);      // premultiplied, front to back
    vec3 glowSum = vec3(0.0);

    float k0 = floor(zc / SP) + 1.0;
    float ca = hit * 0.006 * (1.0 - light);                   // lens colour split on kicks

    // Wall depth bookkeeping: the innermost ring that still contains this pixel.
    float prevSd = -1.0, prevZ = 0.0;
    vec2 prevC = vec2(0.0);
    float wallInvZ = -1.0;
    vec2 wallC = vec2(0.0);
    bool found = false;
    vec2 cFar = vec2(0.0);
    float firstSd = 0.0, firstZ = 1.0, firstRR = 1.0;
    vec2 firstC = vec2(0.0);

    for (int i = 0; i < N; i++) {
        float k = k0 + float(i);
        float zk = k * SP;
        float zi = zk - zc;                                   // depth in front of the camera
        vec2 c = FOC * (path(zk) - cam - aim * zi) / zi;      // projected ring centre
        cFar = c;
        vec2 d = p - c;
        float rho = length(d) + 1e-5;
        float u = specU(d);
        float near = exp(-zi * 0.16);
        float lvl = shape(0.25 * band(u - 0.035) + 0.5 * band(u) + 0.25 * band(u + 0.035));
        float def = lvl * (0.07 + 0.26 * near) * (1.0 + hit * 0.7) + hit * 0.04 * near;
        float rr = FOC * RW * (1.0 + def) / zi;
        float sd = rho - rr;

        if (i == 0) { firstSd = sd; firstZ = zi; firstRR = rr; firstC = c; }
        if (!found && sd > 0.0 && i > 0 && prevSd < 0.0) {
            float f = -prevSd / (sd - prevSd);
            wallInvZ = mix(1.0 / prevZ, 1.0 / zi, f);
            wallC = mix(prevC, c, f);
            found = true;
        }
        prevSd = sd; prevZ = zi; prevC = c;

        // Ring line.
        bool major = mod(k, 4.0) < 0.5;
        float tw = (major ? 0.030 : 0.016) * (1.0 + hit * 0.9 + lvl * 0.6);
        float wpx = FOC * tw / zi * m;
        float halfw = max(wpx, 0.5);
        float sub = min(1.0, wpx / 0.5);                      // sub-pixel rings fade, no shimmer
        float fog = exp(-zi * 0.105);
        float arrive = smoothstep(0.0, 0.5, zi);
        // A pulse races down the tube on every kick.
        float pulse = exp(-pow((zi - (1.0 - kick) * float(N) * SP * 0.9) / 1.6, 2.0)) * kick;
        float bright = (0.25 + lvl * 1.1 + (major ? 0.30 : 0.0)) * (1.0 + hit * 1.2 * near) + pulse * 1.5;
        float a = fog * arrive * sub;
        if (a < 0.002) continue;
        vec3 cov = vec3(clamp(halfw - abs(sd - ca * rho) * m + 0.5, 0.0, 1.0),
                        clamp(halfw - abs(sd) * m + 0.5, 0.0, 1.0),
                        clamp(halfw - abs(sd + ca * rho) * m + 0.5, 0.0, 1.0));
        vec3 rc = pal(fract(k * 0.0625));
        vec3 hot = mix(rc, fg.rgb, clamp(lvl * 0.25 + hit * 0.25, 0.0, 0.5) * (1.0 - light));
        float ca1 = clamp(bright, 0.0, 1.0) * a;
        vec3 cc = cov * ca1;
        float cm = max(cc.r, max(cc.g, cc.b));
        col.rgb += (1.0 - col.a) * cc * hot;
        col.a += (1.0 - col.a) * cm;
        // Glow around the ring, wider when loud.
        float gr = FOC * (0.035 + lvl * 0.03 + hit * 0.03) / zi;
        glowSum += rc * glow(sd, gr) * bright * a * 0.16;
    }

    // ---- walls: between the rings, lit by them, fading into fog ------------------
    if (!found && firstSd > 0.0) {                           // nearer than the first ring
        wallInvZ = 1.0 / firstZ * firstRR / max(length(p - firstC), 1e-4);
        wallC = firstC;
        found = true;
    }
    float wallZ = 1e3;
    if (found) {
        wallZ = 1.0 / max(wallInvZ, 1e-4);
        vec2 d = p - wallC;
        float ang = atan(d.y, d.x);
        float zw = wallZ + zc;
        // Coordinates on the wall: around (16 panels) and along (one panel per ring gap).
        vec2 wuv = vec2(ang / (2.0 * PI) * 16.0 + time * 0.05, zw / SP);
        vec2 cell = floor(wuv);
        vec2 f = fract(wuv);
        vec2 aa = fwidth(wuv) + 1e-4;
        aa.x = min(aa.x, 0.5);
        float fog = exp(-wallZ * 0.105);
        float u = specU(d);
        float lvl = shape(band(u));
        // Rings light the wall around them.
        float dzr = min(f.y, 1.0 - f.y) * SP;
        float ringLight = exp(-dzr * dzr / 0.02) * (0.2 + lvl * 0.6 + hit * 0.5);
        // Seams between panels.
        vec2 seam = 1.0 - smoothstep(vec2(0.0), aa * 1.5, abs(f - 0.5) * -1.0 + 0.5);
        float seams = max(seam.x, seam.y * 0.6);
        // Panel lights: a few panels glow with their band, more flash on snares.
        float h = hash(cell + vec2(0.0, 31.0));
        float on = step(0.86, h) * (0.4 + lvl * 1.4) + step(0.70, h) * step(h, 0.86) * snap * 1.6;
        float inset = boxAA(f / aa, vec2(0.12) / aa, vec2(0.88) / aa);
        vec3 pc = pal(fract(h * 3.7 + cell.y * 0.031));
        float base = (0.10 + 0.10 * loud) * fog;
        vec3 wallCol = mix(bg.rgb, mix(c1.rgb, c2.rgb, 0.5 + 0.5 * sin(ang * 2.0 + zw * 0.08)), 0.22 + 0.12 * light);
        float wa = base + seams * 0.10 * fog;
        col.rgb += (1.0 - col.a) * wa * wallCol;
        col.a += (1.0 - col.a) * wa;
        float pa = clamp(inset * on * fog * 0.6, 0.0, 1.0);
        col.rgb += (1.0 - col.a) * pa * pc;
        col.a += (1.0 - col.a) * pa;
        glowSum += pc * lit(inset * on * fog) * 0.12 + mix(c1.rgb, c3.rgb, u) * lit(ringLight * fog) * 0.18;
    }

    // ---- dust: streaks rushing past the camera inside the tube --------------------
    {
        vec2 d = p - mix(firstC, cFar, 0.5);
        float r = length(d) + 1e-5;
        float ang = atan(d.y, d.x);
        for (int l = 0; l < 6; l++) {
            float fl = float(l);
            float S = 40.0 + fl * 13.0;
            float sx = ang / (2.0 * PI) * S + fl * 0.37;
            float sl = floor(sx);
            float seed = hash(vec2(sl, fl + 5.0));
            if (seed < 0.6) continue;
            float z = 1.0 - fract(seed * 7.3 + flow * (0.55 + seed * 0.5));   // 1 far, 0 here
            z = max(z, 0.03);
            float rad = 0.04 + seed * 0.08;
            float rh = rad / z;                               // head
            float rt = rad / (z + (0.025 + energy * 0.05 + hit * 0.15) * (0.5 + seed));   // tail
            float lat = abs(fract(sx) - 0.5) * (2.0 * PI * r / S) * m;
            float along = max(max(rt - r, r - rh), 0.0) * m;
            float w = 0.4 + 0.9 * (1.0 - z);
            float ds = length(vec2(lat, along));
            float sa = clamp(w - ds + 0.5, 0.0, 1.0) * smoothstep(1.0, 0.6, z) * (0.2 + snap * 0.6 + energy * 0.3) * (1.0 - 0.5 * light);
            vec3 sc = mix(c3.rgb, fg.rgb, 0.4 * (1.0 - light));
            col.rgb += (1.0 - col.a) * sa * sc * (0.6 + 0.4 * light);
            col.a += (1.0 - col.a) * sa * (0.6 + 0.4 * light);
        }
    }

    // ---- the end of the tunnel: light, flare, haze --------------------------------
    {
        vec2 d = p - cFar;
        float r = length(d);
        float core = glow(r, 0.035 + bass * 0.03 + hit * 0.03) * (0.3 + bass * 0.6 + hit * 1.0);
        float bloom = glow(r, 0.16 + loud * 0.10) * (0.06 + loud * 0.14 + hit * 0.22);
        float flare = glow(d.y, 0.004 + hit * 0.004) * glow(d.x, 0.35 + hit * 0.6) * (0.10 + hit * 1.2);
        glowSum += mix(c1.rgb, fg.rgb, 0.45) * core + c2.rgb * bloom + mix(c3.rgb, fg.rgb, 0.5) * flare;
        // On light themes the end of the tunnel is a soft bright opening instead of light.
        float open = glow(r, 0.10 + bass * 0.06) * light;
        col.rgb = mix(col.rgb, bg.rgb * col.a, open * 0.6);
    }
    // Haze: the whole tube fills with coloured air when it's loud.
    glowSum += mix(c1.rgb, c2.rgb, 0.5) * (0.02 + loud * 0.03 + hit * 0.04);

    vec3 g = vec3(lit(1.0)) * glowSum;
    col.rgb += 1.0 - exp(-g * 1.3);                           // soft-saturated: kicks flash, not clip
    col.a += dot(1.0 - exp(-g * 1.3), vec3(0.33)) * 0.6;
    col.a = clamp(col.a, 0.0, 1.0);

    // ---- vignette -----------------------------------------------------------------
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.2, 0.85, length(vq * vec2(1.0, 0.9)));
    float va = vig * mix(0.6 - loud * 0.15, 0.14, light);
    vec3 vc = mix(vec3(0.0), bg.rgb * 0.82, light);
    col.rgb = col.rgb * (1.0 - va) + vc * va;
    col.a = col.a + va * (1.0 - col.a);

    fragColor = vec4(col.rgb + dither(px) * col.a, col.a) * qt_Opacity;
}
