#version 440
// Orpheus "Quasar", second build. The first cut read as a flat ellipse
// sticker with hard Saturn rings (user call, 2026-11-07): the history was
// mapped straight to radius with no turbulence, and the lensed far side was
// too faint to see. This one renders plasma: the disk's emission is the
// spectrum history SHEARED into fire by orbital turbulence (fbm streaks
// stretched along Keplerian orbits — inner orbits outrun outer ones, so
// every phrase you heard smears into glowing filaments as it falls). The
// lensed crown is now the money shot: the far side of the disk bends over
// and under the shadow in two bright arcs that hug the hole, a crisp double
// photon ring sits at the last orbit, and the disk has thickness — a hot
// vertical glow that blooms near the inner edge. Doppler: the approaching
// side burns, the receding side dims toward c1. The camera precesses slowly
// so the tilt is alive even between songs. Behind it all: a faint nebula
// wash and a starfield dense enough to feel like space. Kicks drop hot
// blobs that smear into orbit-arcs; a build tightens the accretion; the
// drop-map wind-up shimmers the poles — and the drop fires the twin jet
// with a pulse that rides out along it. Light themes: ink disk on paper,
// the hole stays the one true black.
// Cost: 2 lensed disk evaluations (3 fbm taps each), nebula fbm, star hash.

//#common

layout(binding = 1) uniform sampler2D hist;   // 32 x 40 spectrum history, row 0 = now

const float PI = 3.14159265;
const float RS = 0.11;         // the shadow's radius (screen height units)
const float RIN = 0.14;        // inner disk edge
const float ROUT = 0.62;       // outer rim

mat2 rot(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm3(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p = rot(0.62) * p * 2.07 + 19.0; a *= 0.5; }
    return v;
}

// Disk emission at polar (r, a) on the disk plane: history sheared into fire.
vec3 diskLight(float r, float a, float feed, out float amt) {
    float t = clamp((r - RIN) / (ROUT - RIN), 0.0, 1.0);    // 0 inner .. 1 rim
    float omega = 0.55 / pow(max(t, 0.06), 1.5);            // Keplerian: inner runs faster
    float orbit = a + flow * omega;
    // the spectrum history as infalling matter: rim is now, inner edge is the past
    float age = (1.0 - t) * (0.72 + 0.28 * feed);
    float freq = clamp(t, 0.02, 0.98);                      // bass burns inside, treble at the rim
    float e = texture(hist, vec2(freq, clamp(age, 0.0, 0.975))).r;
    e = max(e, band(freq) * smoothstep(0.88, 1.0, t));      // the rim takes the live signal
    e = pow(clamp(e, 0.0, 1.0), 0.6);
    // TURBULENCE: streaks stretched hard along the orbit, sheared by radius,
    // so the energy reads as plasma filaments, never as printed rings
    float streak = fbm3(vec2(orbit * 1.4, t * 9.0 - flow * 0.05));
    streak = pow(streak, 2.0) * 1.8 + 0.15;
    float wisp = fbm3(vec2(orbit * 0.5 + 7.0, t * 3.0));    // slow large-scale unevenness
    // the inner edge always burns; feeding pushes the burn outward
    float hot = exp(-t * (3.2 - 1.2 * feed)) * (0.35 + 0.65 * bass + 0.4 * feed);
    amt = (e * (0.5 + 1.3 * streak) * (0.6 + 0.8 * wisp) + hot * streak)
        * smoothstep(0.0, 0.05, t) * smoothstep(1.0, 0.9, t);
    // colour runs hot to cold with radius: white-hot core palette out to the cool rim
    vec3 c = mix(pal(0.98), pal(0.25), t);
    c = mix(c, fg.rgb, exp(-t * 6.0) * 0.5);                // the innermost ring whitens
    return c * amt;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 uv = (px - res * 0.5) / res.y;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float feed = clamp(bd + dr * 0.5, 0.0, 1.0);

    // the camera: breathes with loudness, precesses so the tilt is alive
    uv *= 1.0 - 0.05 * swell;
    uv = rotateAround(uv, vec2(0.0), camRoll() * 0.5 + sin(time * 0.043) * 0.06);
    float TILT = 0.20 + 0.05 * sin(time * 0.031);

    float rr = length(uv);
    float phi = atan(uv.y, uv.x);

    // ---- the disk: direct image + the lensed crown and chin ----
    vec3 colD = vec3(0.0);
    float amtD = 0.0;
    {   // direct image: the near half, passing in front of the shadow
        vec2 d = vec2(uv.x, uv.y / TILT);
        float r = length(d);
        if (r > RIN && r < ROUT && uv.y < RS * 0.45) {
            float a; vec3 c = diskLight(r, atan(d.y, d.x), feed, a);
            // the near edge occludes the shadow: thicken it with a soft rim
            colD += c; amtD += a;
        }
    }
    {   // the crown: the far side, bent OVER the shadow. Bright. The money shot.
        float bend = RS * RS / max(rr, RS * 0.55);
        vec2 lp = vec2(uv.x, abs(uv.y) + bend * 1.7);
        vec2 d = vec2(lp.x, lp.y / TILT);
        float r = length(d);
        if (r > RIN && r < ROUT) {
            float a; vec3 c = diskLight(r, atan(d.y, d.x) + PI, feed, a);
            float arc = smoothstep(RS * 3.4, RS * 1.02, rr);
            colD += c * arc * 2.2; amtD += a * arc * 2.2;
        }
    }
    // doppler: the left side approaches and burns, the right recedes and cools
    float dop = 1.0 + 0.6 * (-uv.x / max(rr, 1e-3)) * smoothstep(0.0, 0.2, rr);
    colD *= dop;
    colD = mix(colD, c1.rgb * amtD * 0.55, clamp(0.55 * (uv.x / max(rr, 1e-3)), 0.0, 0.55));

    // ---- the disk's thickness: a hot haze above and below the plane ----
    float planeD = abs(uv.y) / TILT;
    float inR = smoothstep(ROUT, RIN, rr) * smoothstep(RIN * 0.6, RIN * 1.3, rr);
    vec3 haze = mix(pal(0.95), pal(0.5), clamp(rr / ROUT, 0.0, 1.0))
              * exp(-planeD * planeD / 0.035) * inR * (0.25 + 0.5 * bass + 0.3 * feed);

    // ---- kicks: hot blobs smearing into arcs along their orbits ----
    for (int k = 0; k < 3; k++) {
        float age = kickAge[k];
        if (age < 3.0) {
            float s = kicks - float(k);
            float bt = 0.12 + 0.25 * hash(vec2(s, 3.3));
            float br = mix(RIN, ROUT, bt);
            float ba = hash(vec2(s, 7.7)) * 2.0 * PI + flow * 0.55 / pow(bt, 1.5);
            vec2 at = vec2(cos(ba), sin(ba) * TILT) * br;
            float smear = 1.0 + age * 2.5;
            vec2 rel = uv - at;
            vec2 tang = normalize(vec2(-at.y, at.x) + 1e-5);
            float along = dot(rel, tang) / smear;
            float acrossB = dot(rel, normalize(at + 1e-5));
            float blob = exp(-(along * along + acrossB * acrossB * 4.0) / 0.0016)
                       * exp(-age * 1.3) * (k == 0 ? kickAge.w : 0.7);
            colD += pal(0.95) * blob * (uv.y < RS * 0.45 ? 1.2 : 0.5);
            amtD += blob * 0.5;
        }
    }

    // ---- the photon ring: crisp, doubled, and the shadow ----
    float ring = exp(-pow((rr - RS * 1.16) / (0.004 + 0.002 * swell), 2.0)) * (0.5 + 0.5 * swell);
    ring += exp(-pow((rr - RS * 1.30) / 0.006, 2.0)) * 0.25 * swell;
    float shadow = smoothstep(RS * 1.03, RS * 0.9, rr);

    // ---- the jet: charged by the wind-up, fired by the drop ----
    vec3 jet = vec3(0.0);
    float poleGlow = 0.0;
    {
        float ax = abs(uv.x);
        float along = abs(uv.y);
        if (ant > 0.01) {
            poleGlow = exp(-ax * ax / 0.002) * exp(-pow((along - RS * 1.5) / 0.1, 2.0))
                     * ant * (0.45 + 0.3 * sin(time * 7.0 + uv.y * 30.0));
        }
        if (dr > 0.003) {
            float coreW = 0.007 + 0.005 * dr;
            float core = exp(-ax * ax / (coreW * coreW)) * smoothstep(RS * 0.9, RS * 1.3, along);
            float sheath = exp(-ax * ax / 0.006) * smoothstep(RS * 0.9, RS * 2.0, along) * 0.5;
            float pulse = exp(-pow((along - (1.0 - dr) * 1.1 - RS) / 0.08, 2.0));
            float fade = exp(-along * 1.3);
            jet = (c3.rgb * core + pal(0.7) * sheath) * (fade * 0.9 + pulse * 1.0) * dr;
        }
    }

    // ---- space: a nebula wash and a starfield that feels populated ----
    vec3 deep = vec3(0.0);
    {
        float neb = fbm3(uv * 1.7 + vec2(flow * 0.006, 0.0));
        neb = pow(max(neb - 0.35, 0.0), 1.6);
        deep += mix(pal(0.15), pal(0.45), fbm3(uv * 0.9 + 31.0)) * neb * 0.16;
        float nearH = smoothstep(RS * 4.0, RS * 1.1, rr);
        float pull = (RS * RS / max(rr * rr, RS * RS * 0.8)) * nearH;
        vec2 sp = rotateAround(uv * (1.0 + pull * 1.2), vec2(0.0), flow * 0.003);
        for (int L = 0; L < 2; L++) {
            float g = 30.0 + 26.0 * float(L);
            vec2 cellp = floor(sp * g + float(L) * 17.0);
            float h = hash(cellp);
            if (h > 0.93) {
                vec2 at = (cellp + vec2(hash(cellp + 1.3), hash(cellp + 2.6)) - float(L) * 17.0) / g;
                float d2 = dot(sp - at, sp - at);
                float tw = 0.5 + 0.5 * sin(time * (0.8 + h * 2.5) + h * 40.0);
                deep += mix(fg.rgb, pal(h), 0.45) * exp(-d2 * g * g * 280.0)
                      * (0.2 + 0.35 * tw + 0.3 * band(0.85)) * (1.0 - 0.4 * float(L));
            }
        }
    }

    // ---- compose ----
    vec3 col;
    if (light < 0.5) {
        col = bg.rgb * 0.18 + deep * lit(1.0);
        col += haze * lit(1.0);
        col += colD * lit(1.5);
        col += c3.rgb * ring * lit(1.0) * faux(1.0, 0.5);
        col += jet * lit(1.0) + c2.rgb * poleGlow * lit(0.8);
        col = 1.0 - exp(-col * 1.3);
        col *= 1.0 - shadow;                                 // the hole eats everything, last
    } else {
        col = bg.rgb;
        col = mix(col, fg.rgb * 0.5, clamp(deep.r + deep.g, 0.0, 1.0) * 0.4);
        float inkAmt = clamp(amtD * 1.4 + haze.r + haze.g, 0.0, 1.0);
        vec3 tint = clamp(colD / max(amtD, 1e-3), 0.0, 1.0);
        col = mix(col, mix(tint, fg.rgb, 0.5) * 0.45, inkAmt);
        col = mix(col, fg.rgb * 0.2, ring * 0.85);
        col = mix(col, mix(fg.rgb, pal(0.7), 0.4) * 0.4, clamp(jet.b + jet.r + poleGlow, 0.0, 1.0));
        col *= 1.0 - shadow * 0.92;
    }

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
