#version 440
// Orpheus "Quasar", third build: the real thing. The first was a sticker,
// the second a brighter sticker (user calls, 2026-11-07). This one marches
// geodesics: every ray BENDS toward the hole as it flies (pseudo-Newtonian
// pull per step), so the lensing is not painted on — the Einstein ring, the
// crown of the far disk folded over the shadow, the second and third images
// hugging the photon sphere, and the warped starfield behind all fall out
// of the same integrator. The accretion disk is a volume: a thin torus of
// plasma the rays pass THROUGH, its density the spectrum history wound into
// Keplerian spirals (what you hear lands on the rim and winds inward, bass
// deep, treble out), its glow doppler-boosted toward you on the approaching
// side. Rays that fall below the horizon end black; that blackness is the
// shadow, earned. Kicks drop hot clumps that orbit and shear apart. A build
// feeds the disk until it thickens and brightens inward; the drop-map
// wind-up kindles the poles — and the drop drives the volumetric jet, twin
// cones of light the rays cross on their way past. The camera orbits very
// slowly and breathes with the loudness. Light themes: the ink singularity —
// density becomes ink wash, the shadow stays the one true black.
// Cost: 64 bent steps, ~2 fbm + 1 history tap per step inside the disk only.

//#common

layout(binding = 1) uniform sampler2D hist;   // 32 x 40 spectrum history, row 0 = now

const float PI = 3.14159265;
const int STEPS = 64;
const float RS = 0.55;         // horizon radius, world units
const float RIN = 1.15;        // inner disk edge (~ISCO)
const float ROUT = 4.6;        // outer rim
const float FAR = 13.0;

mat2 rot2(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm2(vec2 p) {
    float v = 0.5 * vnoise(p);
    v += 0.25 * vnoise(rot2(0.62) * p * 2.07 + 19.0);
    return v;
}

// Plasma density and emission of the disk at point p. The disk lies in y=0.
float diskDens(vec3 p, float feed, out vec3 emis) {
    float r = length(p.xz);
    emis = vec3(0.0);
    if (r < RIN * 0.92 || r > ROUT) return 0.0;
    float t = clamp((r - RIN) / (ROUT - RIN), 0.0, 1.0);
    float thick = 0.045 + 0.16 * t + 0.1 * feed;            // thin inside, flared rim
    float vert = exp(-p.y * p.y / (thick * thick));
    if (vert < 0.01) return 0.0;
    // Keplerian spiral coordinates: the matter at radius r has turned by
    // flow * r^-1.5, so the noise and the history both wind into trailing arms.
    float phase = atan(p.z, p.x) + flow * 0.5 / pow(max(t, 0.05), 1.5);
    float age = (1.0 - t) * (0.72 + 0.28 * feed);           // rim is now, inner edge the past
    float e = texture(hist, vec2(clamp(t, 0.02, 0.98), clamp(age, 0.0, 0.975))).r;
    e = max(e, band(clamp(t, 0.02, 0.98)) * smoothstep(0.85, 1.0, t));
    e = pow(clamp(e, 0.0, 1.0), 0.6);
    float arms = fbm2(vec2(phase * 2.2, r * 2.6 - flow * 0.1));
    arms = pow(arms + 0.25, 3.0);
    float inner = exp(-(t) * 2.2) * (0.5 + 0.8 * feed);     // the burn near the ISCO
    float dens = vert * (e * (0.4 + 1.6 * arms) + inner * (0.3 + arms))
               * smoothstep(RIN * 0.92, RIN * 1.15, r) * smoothstep(ROUT, ROUT * 0.82, r);
    // emission: hot toward the centre, whitening at the ISCO; doppler applied later
    vec3 c = mix(pal(0.98), pal(0.3), t);
    c = mix(c, fg.rgb, exp(-t * 5.0) * 0.55);
    emis = c * dens * (1.4 + 2.2 * inner);
    return dens;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float mres = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / mres;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float feed = clamp(bd + dr * 0.5, 0.0, 1.0);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));

    // ---- the camera: a very slow orbit, a shallow tilt that precesses ----
    float orb = time * 0.012 + flow * 0.004;
    float tilt = 0.16 + 0.05 * sin(time * 0.027);
    float dist = 7.2 - 0.5 * loud;
    vec3 ro = vec3(cos(orb) * dist, sin(tilt * PI * 0.5) * dist * 0.35, sin(orb) * dist);
    vec3 fw = normalize(-ro);
    vec3 rt = normalize(cross(vec3(0.0, 1.0, 0.0), fw));
    vec3 upv = cross(fw, rt);
    uv = rot2(camRoll() * 0.4) * uv;
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * 1.05);

    // ---- march bent rays through the volume ----
    float jit = hash(px + fract(time) * 61.7);
    vec3 p = ro + rd * jit * 0.15;
    vec3 col3 = vec3(0.0);
    float trans = 1.0;
    bool captured = false;
    float inkD = 0.0;                                        // light-theme ink accumulator
    for (int i = 0; i < STEPS; i++) {
        float r = length(p);
        if (r < RS) { captured = true; break; }
        if (r > FAR && dot(p, rd) > 0.0) break;              // flying away: done
        // adaptive step: fine near the hole and through the disk plane
        float dt = clamp(r * 0.16, 0.035, 0.42);
        dt *= 0.5 + 0.5 * smoothstep(0.0, 1.2, abs(p.y));    // slow down crossing the disk
        // gravity bends the ray (pseudo-Newtonian; strong enough to ring at ~1.5 RS)
        vec3 g = -p / (r * r * r + 1e-4) * (RS * 1.9);
        rd = normalize(rd + g * dt);
        // the disk volume
        vec3 emis;
        float dens = diskDens(p, feed, emis);
        if (dens > 0.0) {
            // doppler: orbital velocity ~ r^-1/2, boost where matter comes at you
            vec3 vel = normalize(vec3(-p.z, 0.0, p.x)) * inversesqrt(max(length(p.xz), 0.3));
            float dop = 1.0 + 1.1 * dot(vel, -rd);
            dop = clamp(dop, 0.35, 2.2);
            vec3 cc = emis * dop;
            cc = mix(cc, c1.rgb * dens, clamp(0.6 - dop * 0.3, 0.0, 0.5));  // recede reddens
            float a = dens * dt * 2.6;
            col3 += cc * dt * 2.6 * trans;
            trans *= exp(-a * 0.9);
            inkD += a;
            if (trans < 0.02) break;
        }
        // kick clumps: three hot knots orbiting at their own radii, shearing out
        for (int k = 0; k < 3; k++) {
            float age = kickAge[k];
            if (age < 2.5) {
                float s = kicks - float(k);
                float kt = 0.15 + 0.3 * hash(vec2(s, 3.3));
                float kr = mix(RIN, ROUT * 0.7, kt);
                float ka = hash(vec2(s, 7.7)) * 2.0 * PI + flow * 0.5 / pow(kt, 1.5);
                vec3 at = vec3(cos(ka) * kr, 0.0, sin(ka) * kr);
                float d2 = dot(p - at, p - at) / (0.05 + age * 0.12);
                float kd = exp(-d2 * 6.0) * exp(-age * 1.2) * (k == 0 ? kickAge.w : 0.6);
                col3 += pal(0.95) * kd * dt * 3.0 * trans;
                inkD += kd * dt;
            }
        }
        // the jet: twin cones of light on the spin axis, driven by the drop
        if (dr > 0.003 || ant > 0.02) {
            float ax = length(p.xz);
            float along = abs(p.y);
            float cone = exp(-pow(ax / (0.12 + along * 0.16), 2.0)) * smoothstep(RS, RS * 2.0, along);
            float pulse = exp(-pow((along - (1.0 - dr) * 7.0 - RS) / 0.9, 2.0));
            float jd = cone * (dr * (exp(-along * 0.35) * 0.8 + pulse * 1.1)
                             + ant * 0.12 * exp(-pow(along - RS * 1.6, 2.0) * 2.0)
                               * (0.6 + 0.4 * sin(time * 7.0 + p.y * 5.0)));
            if (jd > 0.001) {
                col3 += mix(c3.rgb, pal(0.7), 0.4) * jd * dt * 2.2 * trans;
                inkD += jd * dt * 0.6;
            }
        }
        p += rd * dt;
    }

    // ---- whatever escaped samples the sky along its BENT direction ----
    vec3 skyC = vec3(0.0);
    if (!captured && trans > 0.02) {
        vec3 d = normalize(rd);
        // nebula wash
        float neb = fbm2(d.xy * 2.2 + d.z * 1.3 + vec2(0.0, flow * 0.004));
        skyC += mix(pal(0.15), pal(0.45), fbm2(d.zx * 1.4 + 31.0)) * pow(max(neb - 0.3, 0.0), 1.8) * 0.5;
        // stars on the celestial sphere: warped by every bend the ray took
        vec2 sph = vec2(atan(d.z, d.x) * 1.4, d.y * 2.6);
        for (int L = 0; L < 2; L++) {
            float g = 22.0 + 20.0 * float(L);
            vec2 cellp = floor(sph * g + float(L) * 17.0);
            float h = hash(cellp);
            if (h > 0.91) {
                vec2 at = (cellp + vec2(hash(cellp + 1.3), hash(cellp + 2.6))) / g;
                float d2 = dot(sph - at, sph - at);
                float tw = 0.5 + 0.5 * sin(time * (0.8 + h * 2.0) + h * 40.0);
                skyC += mix(fg.rgb, pal(h), 0.4) * exp(-d2 * g * g * 230.0)
                      * (0.3 + 0.4 * tw + 0.3 * band(0.85)) * (1.0 - 0.4 * float(L));
            }
        }
    }

    // ---- compose ----
    vec3 col;
    if (light < 0.5) {
        col = bg.rgb * 0.15 + skyC * trans * lit(1.0) + col3 * lit(1.0);
        col = 1.0 - exp(-col * 1.35);
        if (captured) col *= 0.0;                            // the shadow, earned
        col = max(col, bg.rgb * 0.05);                       // never a dead panel, even in the hole
    } else {
        // the ink singularity: accumulated plasma becomes wash on paper
        float ink = 1.0 - exp(-inkD * 1.6);
        vec3 tint = clamp(col3 / max(inkD, 1e-3), 0.0, 1.0);
        col = bg.rgb;
        col = mix(col, fg.rgb * 0.5, clamp(skyC.r + skyC.g, 0.0, 1.0) * trans * 0.4);
        col = mix(col, mix(tint, fg.rgb, 0.5) * 0.45, ink);
        if (captured) col = mix(bg.rgb, fg.rgb, 0.94);       // near-black, still printable
    }

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
