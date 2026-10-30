#version 440
// Orpheus "Halo": the spectrum wrapped into a ring, hung in space like an
// eclipse. 64 bars radiate out of a glowing rim around a dark disc, mirrored
// left and right so the bass sits at the bottom and the treble meets at the
// top; each bar casts a short reflection inward and a long ray of light out
// through the haze. The ring is a real tilted disc seen in perspective: it
// sways in 3D, a dotted orbit of the peaks circles behind it on its own
// plane, and the camera pushes in as the music swells.
// Kicks slam: the bars overshoot, the rim and corona flare, the disc jolts,
// the camera punches in and a double shockwave rolls out. Snares sparkle the
// peak caps. Closed form per pixel apart from the two shockwave rings.

//#common

const float PI = 3.14159265;
const float SLOTS = 64.0;    // 32 bands, mirrored

float shape(float v) { return pow(clamp(v, 0.0, 1.0), 1.25); }

// Rotation of the disc: pitch a.x, yaw a.y.
mat3 discRot(vec2 a) {
    float cx = cos(a.x), sx = sin(a.x), cy = cos(a.y), sy = sin(a.y);
    mat3 rx = mat3(1.0, 0.0, 0.0,  0.0, cx, sx,  0.0, -sx, cx);
    mat3 ry = mat3(cy, 0.0, -sy,  0.0, 1.0, 0.0,  sy, 0.0, cy);
    return ry * rx;
}

// Screen pixel offset s -> point on the plane (rotated by R, pushed back by zOff)
// in that plane's own pixel units; .z = local pixels per screen pixel (from derivatives).
vec3 onPlane(vec2 s, float D, mat3 R, float zOff) {
    vec3 n = R * vec3(0.0, 0.0, 1.0);
    vec3 e = vec3(0.0, 0.0, -D);
    vec3 dir = vec3(s, D);
    float t = (dot(n, vec3(0.0, 0.0, zOff)) - dot(n, e)) / dot(n, dir);
    vec3 P = e + dir * t - vec3(0.0, 0.0, zOff);
    vec3 l = transpose(R) * P;
    vec2 dx = dFdx(l.xy), dy = dFdy(l.xy);
    return vec3(l.xy, sqrt(abs(dx.x * dy.y - dx.y * dy.x)));
}

void main() {
    float m = min(res.x, res.y);
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;

    float hit = max(kick, beat * 0.8);
    float kh = hash(vec2(kicks, 1.3)) - 0.5;
    float kv = hash(vec2(kicks, 7.9)) - 0.5;
    float loud = smoothstep(0.03, 0.8, max(swell, energy));

    // ---- camera: push in with the swell, punch on kicks, a slow roll -------------
    float zoom = 1.0 + loud * 0.10 + hit * 0.07;
    vec2 s = rotateAround(px, res * 0.5, camRoll() * 0.7) - res * 0.5 - vec2(0.0, camBob(res.y));
    s /= zoom;
    float D = m * 1.6;
    vec2 tilt = vec2(0.22 * sin(time * 0.19) + 0.10 * sin(time * 0.07 + 2.0) + hit * kv * 0.10,
                     0.28 * sin(time * 0.13 + 0.7) + hit * kh * 0.12);
    mat3 R = discRot(tilt);
    vec3 L0 = onPlane(s, D, R, 0.0);
    vec2 p = L0.xy;
    float k = max(L0.z, 0.3);                                 // plane px per screen px
    float kpx = 1.0 / k;                                      // converts plane px -> screen px

    float R0 = m * (0.18 + bass * 0.02 + hit * 0.015);
    float Lb = m * 0.17 * (1.0 + hit * 0.30);                 // bars overshoot on kicks

    // ---- gravity waves: each kick sends a lensing front out of the rim ------------
    // One front per recent kick (kickAge holds the last three), so quick kicks
    // layer their waves instead of restarting one. Each bends space as it passes:
    // a radial push (derivative of a gaussian: out ahead of the front, in behind
    // it) plus a twist, with a thin colour-split caustic riding the front.
    float r0 = length(p) + 1e-4;
    float dr = 0.0, dth = 0.0;
    vec3 caus = vec3(0.0);
    float causA = 0.0;
    for (int i = 0; i < 3; i++) {
        float ai = kickAge[i];
        if (ai >= 2.5) continue;                              // long faded (and 8.0 = no kick)
        float kid = kicks - float(i);                         // this wave's kick, for its own variety
        float kv2 = hash(vec2(kid, 4.4));
        float twistDir = kv2 < 0.5 ? -1.0 : 1.0;
        float Rw = R0 + ai * m * (0.80 + 0.35 * kv2);
        float w = m * (0.014 + ai * 0.045);
        float A = exp(-ai * 2.2) * (0.65 + 0.35 * hash(vec2(kid, 2.0))) * (i == 0 ? 0.55 + 0.45 * kickAge.w : 0.9)
                  * smoothstep(0.0, 0.03, ai + 0.01);
        float x = (r0 - Rw) / w;
        float g = exp(-x * x);
        dr += A * x * g * m * 0.07;
        dth += A * g * 0.08 * twistDir;
        // Caustic: three thin edges just ahead of the front, split by colour.
        float cw = m * max(0.0012, 0.0035 - ai * 0.003);      // thins as it expands
        float sp = m * 0.004 + w * 0.12;
        vec3 e = vec3(glow(r0 - Rw - w * 0.55 - sp, cw), glow(r0 - Rw - w * 0.55, cw), glow(r0 - Rw - w * 0.55 + sp, cw));
        caus += (c1.rgb * e.x + c2.rgb * e.y + c3.rgb * e.z) * A;
        causA += max(e.x, max(e.y, e.z)) * A;
    }
    vec2 dir0 = p / r0;
    vec2 pWarp = rotateAround(p - dir0 * dr, vec2(0.0), dth);
    vec2 dScreen = (pWarp - p) * kpx;                         // the same bend, roughly, in screen pixels
    p = pWarp;
    float r = length(p) + 1e-4;

    // Rotation: a slow continuous turn (one every 50 s), nudged on by the music's
    // travel and stepped forward a little by every kick (eased as the kick decays).
    // All three terms wrap to whole turns where their inputs wrap.
    float spin = time / 50.0 + flow / 128.0 + (kicks - kick) / 128.0;

    float a = fract(atan(p.x, -p.y) / (2.0 * PI) + 0.5 + spin);
    float slot = floor(a * SLOTS);
    float sf = fract(a * SLOTS);
    float u = abs((slot + 0.5) / SLOTS - 0.5) * 2.0;          // 0 bass (bottom) .. 1 treble (top)
    int bi = int(clamp(floor(u * 32.0), 0.0, 31.0));
    float v = shape(bandAt(bi));
    float pk = shape(peakAt(bi));
    vec3 tint = pal(u);
    float heat = smoothstep(0.30, 1.0, v);
    vec3 hot = mix(tint, fg.rgb, (0.05 + 0.28 * heat + 0.15 * hit) * (1.0 - light));

    vec4 col = vec4(0.0);      // premultiplied, front to back
    vec3 light3 = vec3(0.0);   // additive light, soft-saturated at the end

    // ---- bars ------------------------------------------------------------------
    float arc = 2.0 * PI * r / SLOTS;
    float lat = abs(sf - 0.5) * arc;
    float halfW = arc * 0.31;
    float latA = clamp((halfW - lat) * kpx + 0.5, 0.0, 1.0);
    float h = max(2.0, v * Lb);
    float outA = clamp(min(r - R0, R0 + h - r) * kpx + 0.5, 0.0, 1.0) * latA;
    float hIn = max(1.0, v * Lb * 0.30);
    float inA = clamp(min(R0 - r, r - (R0 - hIn)) * kpx + 0.5, 0.0, 1.0) * latA;

    float t = clamp((r - R0) / h, 0.0, 1.0);
    vec3 barCol = mix(tint * (0.45 + 0.2 * light), hot, pow(t, 1.1));
    barCol += lit(smoothstep(h - 4.0, h, r - R0)) * (0.35 + hit * 0.4) * tint;   // bright tip
    col.rgb += (1.0 - col.a) * outA * barCol;
    col.a += (1.0 - col.a) * outA;
    float ia = inA * (0.20 + 0.35 * (1.0 - clamp((R0 - r) / hIn, 0.0, 1.0)));
    col.rgb += (1.0 - col.a) * ia * tint * 0.8;
    col.a += (1.0 - col.a) * ia;

    // Peak caps, sparkling on snares.
    float pr = R0 + max(v, pk) * Lb + m * 0.012;
    float dotA = clamp(min(halfW - lat, m * 0.0045 - abs(r - pr)) * kpx + 0.5, 0.0, 1.0) * step(0.02, pk);
    float spark = snap * step(0.55, hash(vec2(slot, floor(time * 12.0))));
    col.rgb += (1.0 - col.a) * dotA * mix(tint, fg.rgb, 0.5 + 0.4 * spark * (1.0 - light));
    col.a += (1.0 - col.a) * dotA;
    light3 += glow(r - pr, m * 0.01) * glow(lat, arc * 0.4) * spark * 0.8 * fg.rgb;

    // Rays: each bar throws a beam of light out through the haze.
    float beyond = r - (R0 + h);
    float ray = glow(lat, arc * (0.35 + 0.25 * heat)) * step(0.0, beyond) * exp(-beyond / (m * (0.10 + 0.25 * v + 0.15 * hit)))
              * v * (0.12 + 0.28 * heat + 0.30 * hit);
    light3 += ray * tint;
    // Tip bloom.
    light3 += glow(beyond, m * 0.03) * glow(lat, arc * 0.9) * heat * faux(0.3 + hit * 0.5, 0.5) * tint;

    // ---- the rim and the eclipse ---------------------------------------------------
    float ringLine = clamp((1.6 + hit * 1.5) - abs(r - R0) * kpx, 0.0, 1.0);
    vec3 ringCol = mix(c1.rgb, c2.rgb, 0.5 + 0.5 * sin(a * 2.0 * PI * 2.0 + time * 0.4));
    col.rgb += (1.0 - col.a) * ringLine * mix(ringCol, fg.rgb, 0.3 * (1.0 - light));
    col.a += (1.0 - col.a) * ringLine;
    light3 += glow(r - R0, m * (0.025 + bass * 0.03 + hit * 0.02)) * faux(0.25 + bass * 0.45 + hit * 0.7, 0.4) * ringCol;

    // Inner contour: the spectrum again as one smooth closed line, counter-rotating.
    float a2 = fract(atan(p.x, -p.y) / (2.0 * PI) + 0.5 - time / 80.0);
    float u2 = abs(a2 - 0.5) * 2.0;
    float rc = R0 * (0.60 + shape(band(u2)) * 0.30 + hit * 0.05);
    float cl = clamp(1.2 - abs(r - rc) * kpx, 0.0, 1.0);
    vec3 cc = mix(c3.rgb, c2.rgb, u2);
    col.rgb += (1.0 - col.a) * cl * 0.8 * cc;
    col.a += (1.0 - col.a) * cl * 0.8;
    light3 += glow(r - rc, m * 0.015) * faux(0.15 + energy * 0.4, 0.35) * cc;

    // The disc: dark (a lighter well on light themes), with a coloured lens glow.
    float disc = clamp((R0 - r) * kpx + 0.5, 0.0, 1.0);
    vec3 discCol = mix(bg.rgb * 0.35, mix(bg.rgb, c1.rgb, 0.08), light);
    float da = disc * (0.75 - 0.35 * light);
    col.rgb += (1.0 - col.a) * da * discCol;
    col.a += (1.0 - col.a) * da;
    light3 += glow(r, R0 * 0.7) * disc * (0.06 + bass * 0.18 + hit * 0.25) * c1.rgb;

    // ---- the orbit: peaks as a dotted ring on its own plane, behind ---------------
    {
        vec3 Lb2 = onPlane(s + dScreen * 0.8, D, R, m * 0.55);
        vec2 q = Lb2.xy;
        float rq = length(q);
        float ROrb = m * 0.52;
        float ao = fract(atan(q.x, -q.y) / (2.0 * PI) + 0.5 - time * 0.012);
        float n = 128.0;
        float id = floor(ao * n);
        float uo = abs((id + 0.5) / n - 0.5) * 2.0;
        float lv = shape(peakAt(int(clamp(floor(uo * 32.0), 0.0, 31.0))));
        vec2 cdot = vec2(abs(fract(ao * n) - 0.5) * 2.0 * PI * rq / n, rq - ROrb);
        float rad = m * (0.0015 + lv * 0.004 + hit * 0.002);
        float dd = length(cdot);
        float ok = 1.0 / max(Lb2.z, 0.3);
        float dA = clamp((rad - dd) * ok + 0.5, 0.0, 1.0) * (0.25 + lv * 0.75);
        // Anything behind the halo's own disc is hidden by it.
        dA *= 1.0 - max(disc, outA);
        vec3 oc = mix(pal(uo), bg.rgb, 0.35 * light);
        col.rgb += (1.0 - col.a) * dA * oc * 0.85;
        col.a += (1.0 - col.a) * dA * 0.85;
        light3 += glow(dd, m * 0.008) * lv * faux(0.25, 0.35) * pal(uo) * (1.0 - disc);
        // A faint guide line for the orbit.
        float gl = clamp(0.8 - abs(rq - ROrb) * ok, 0.0, 1.0) * 0.12 * (1.0 - disc);
        col.rgb += (1.0 - col.a) * gl * c2.rgb;
        col.a += (1.0 - col.a) * gl;
    }

    // ---- the waves' caustics, and a field for them to bend --------------------------
    light3 += caus * 0.9;
    {
        float inkC = causA * light * 0.6;
        col.rgb += (1.0 - col.a) * inkC * c2.rgb;
        col.a += (1.0 - col.a) * inkC;
    }
    // Field: a faint polar grid on the disc's plane, outside the rim; the waves light it up.
    {
        float ra = r / (m * 0.05);
        float ta = fract(atan(p.x, -p.y) / (2.0 * PI) + 0.5 - time / 200.0) * 48.0;
        float fr = fract(ra), ft = fract(ta);
        float wr = fwidth(ra) + 1e-4, wt = min(fwidth(ta), 0.5) + 1e-4;
        float lines = max(1.0 - smoothstep(0.0, wr * 1.2, min(fr, 1.0 - fr)),
                          (1.0 - smoothstep(0.0, wt * 1.2, min(ft, 1.0 - ft))) * 0.7);
        float reach = smoothstep(R0 * 1.05, R0 * 1.4, r) * glow(r, m * 0.75);
        float fa = lines * reach * (0.05 + loud * 0.04 + causA * 0.2 + abs(dr) / m * 8.0) * (1.0 - outA);
        vec3 fc = mix(c2.rgb, c3.rgb, 0.5 + 0.5 * sin(r / m * 6.0 - time * 0.3));
        col.rgb += (1.0 - col.a) * fa * fc;
        col.a += (1.0 - col.a) * fa;
    }
    // Ticks: an outer dial of 96 marks turning the other way, flashing on snares.
    {
        float RT = R0 + m * 0.24;
        float at = fract(atan(p.x, -p.y) / (2.0 * PI) + 0.5 + time / 100.0) * 96.0;
        float idt = floor(at);
        float latT = abs(fract(at) - 0.5) * 2.0 * PI * r / 96.0;
        float major = step(0.5, 1.0 - mod(idt, 8.0) * 8.0);
        float len = m * (0.008 + 0.012 * major);
        float tA = clamp(min(m * 0.0016 - latT, len - abs(r - RT)) * kpx + 0.5, 0.0, 1.0);
        float fl = snap * step(0.6, hash(vec2(idt, floor(time * 10.0))));
        tA *= 0.30 + 0.25 * major + 0.6 * fl;
        col.rgb += (1.0 - col.a) * tA * mix(c3.rgb, fg.rgb, 0.4 * fl * (1.0 - light));
        col.a += (1.0 - col.a) * tA;
    }

    // ---- haze and backlight: the stage behind the halo --------------------------------
    vec2 sp = s / m;
    float back = glow(length(sp), 0.55 + loud * 0.2) * (0.04 + loud * 0.07 + hit * 0.10);
    light3 += back * mix(c2.rgb, c1.rgb, 0.5);

    vec3 g = light3 * (1.0 - 0.85 * light) * (1.0 - 0.65 * disc);
    vec3 gl3 = 1.0 - exp(-g * 1.4);
    col.rgb += gl3;
    col.a += dot(gl3, vec3(0.33)) * 0.6;
    // Light themes get the backlight as a soft tint rather than light.
    float tintA = back * light * 1.2;
    col.rgb += (1.0 - col.a) * tintA * c2.rgb;
    col.a += (1.0 - col.a) * tintA;
    col.a = clamp(col.a, 0.0, 1.0);

    // ---- vignette ----------------------------------------------------------------------
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.2, 0.85, length(vq * vec2(1.0, 0.9)));
    float va = vig * mix(0.55 - loud * 0.15, 0.12, light);
    vec3 vc = mix(vec3(0.0), bg.rgb * 0.82, light);
    col.rgb = col.rgb * (1.0 - va) + vc * va;
    col.a = col.a + va * (1.0 - col.a);

    fragColor = vec4(col.rgb + dither(px) * col.a, col.a) * qt_Opacity;
}
