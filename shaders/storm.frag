#version 440
// Orpheus "Storm": the sky that knows what's coming. A domain-warped FBM
// thunderhead hangs over a thin horizon glow; the wind rides `flow` so the
// cloud always drifts with the music's pace. Bass is the mass of the cloud
// (it swells and darkens the base), mids are the churn (warp strength),
// treble is spindrift torn off the top. A build rolls the pressure front in:
// the base lowers, the light under it dies, rain starts to fall. Then the
// part nobody else can do: `anticipate` — the drop map's 8-beat wind-up —
// charges the cloud base with crawling veins of light that brighten and
// crowd as the drop approaches, so the sky visibly loads before it breaks.
// The drop IS the strike: one jagged bolt (seeded per kick counter, so every
// strike forks differently), a capped sheet flash, and the rain sheets down.
// Kicks are distant in-cloud flicker. No full-field strobe: the flash is
// luminance-capped and brief, everything else moves rather than blinks.
// Light themes: a pale storm, graphite cloud on paper sky, rain as ink.
// Cost: ~20 FBM taps per pixel, single pass, no march.

//#common

const float PI = 3.14159265;

mat2 rot(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i), b = hash(i + vec2(1, 0)), c = hash(i + vec2(0, 1)), d = hash(i + vec2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// FBM with a rotated domain per octave (kills the axis-aligned artifacts).
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = rot(0.62) * p * 2.03 + vec2(13.7, 7.1);
        a *= 0.52;
    }
    return v;
}

// The bolt's horizontal wander at height t (0 top, 1 ground), seeded per strike.
float boltX(float t, float seed) {
    float x = 0.0, a = 0.26, f = 3.0;
    for (int i = 0; i < 4; i++) {
        x += a * (vnoise(vec2(t * f + seed * 61.7, seed * 17.3 + float(i) * 9.1)) - 0.5);
        a *= 0.55; f *= 2.4;
    }
    return x;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 uv = px / res;                                   // 0..1, y up
    float asp = res.x / res.y;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float charge = max(ant, bd * 0.5);                    // the sky loads on either signal

    // ---- the cloud: domain-warped FBM, wind on flow ----
    vec2 wind = vec2(flow * 0.055, time * 0.006);
    vec2 p = vec2(uv.x * asp, uv.y * 1.35) * 1.9;
    float churn = 0.9 + band(0.45) * 1.6 + energy * 0.8;  // mids drive the warp
    vec2 q = vec2(fbm(p + wind), fbm(p + wind + vec2(5.2, 1.3)));
    vec2 r = vec2(fbm(p + churn * 1.8 * q + wind * 1.3 + vec2(1.7, 9.2)),
                  fbm(p + churn * 1.8 * q + wind * 0.8 + vec2(8.3, 2.8)));
    float f = fbm(p + 1.9 * r);

    // Cloud base height: sinks as the storm builds; bass makes the base heave.
    float base = 0.62 - 0.16 * bd - 0.05 * bass * swell - 0.04 * sin(time * 0.1);
    float ceil0 = 0.98;
    float body = smoothstep(base - 0.28 * f, base + 0.22, uv.y);  // 0 below base .. 1 deep in cloud
    float dens = body * smoothstep(0.38, 0.74, f + 0.18 * bd);    // the thunderhead's flesh
    // spindrift: treble tears thin wisps off the top edge
    float wispB = band(0.8) * smoothstep(0.75, 0.95, uv.y) * smoothstep(0.5, 0.35, abs(f - 0.47));
    dens = clamp(dens + wispB * 0.5, 0.0, 1.0);

    // ---- light in the sky ----
    float horizon = exp(-uv.y * 13.0);                     // a THIN glow: the storm must stay dark
    float under = smoothstep(base + 0.05, base - 0.2, uv.y);

    // ---- the charge: veins of light crawling the cloud base (the wind-up) ----
    float veins = 0.0;
    if (charge > 0.01) {
        float ridge = 1.0 - abs(2.0 * fbm(p * 2.3 + 2.2 * r + vec2(0.0, flow * 0.02)) - 1.0);
        float nearBase = exp(-pow((uv.y - base) / (0.08 + 0.05 * charge), 2.0));
        veins = smoothstep(mix(0.995, 0.72, charge * charge), 1.0, ridge) * nearBase * charge;
    }

    // ---- the strike ----
    float bolt = 0.0, sheet = 0.0;
    if (dr > 0.003) {
        float flash = dr * dr * dr * dr;                   // dies fast: well under 3 flashes/s
        float seed = fract(kicks * 0.0173) + floor(kicks);
        float bx = 0.28 + 0.44 * hash(vec2(seed, 4.2));    // where this strike lands
        float t = clamp((base + 0.2 - uv.y) / (base + 0.2), 0.0, 1.0);  // 0 in cloud, 1 at ground
        float dx = abs(uv.x - (bx + boltX(t, seed) * 0.35)) * asp;
        float core = exp(-dx * dx / 0.000004) * step(uv.y, base + 0.2);
        float halo = exp(-dx * dx / 0.0012) * step(uv.y, base + 0.22);
        // a fork, fainter, peeling off halfway down
        float fx2 = abs(uv.x - (bx + boltX(t, seed) * 0.35 + (t - 0.45) * 0.3 * sign(hash(vec2(seed, 9.9)) - 0.5))) * asp;
        float fork = exp(-fx2 * fx2 / 0.000003) * smoothstep(0.4, 0.55, t) * 0.7;
        bolt = (core + fork) * smoothstep(0.0, 0.25, dr) * dr;
        sheet = clamp(halo * 0.5 + flash * under * 0.35, 0.0, 0.5);  // capped: never a white-out
    }

    // ---- kicks: distant flicker inside the cloud ----
    float flick = 0.0;
    for (int k = 0; k < 3; k++) {
        float age = kickAge[k];
        if (age < 0.5) {
            float s = kicks - float(k);
            vec2 at = vec2(0.2 + 0.6 * hash(vec2(s, 1.1)), base + 0.12 + 0.15 * hash(vec2(s, 2.7)));
            float d2 = dot((uv - at) * vec2(asp, 1.0), (uv - at) * vec2(asp, 1.0));
            flick += exp(-d2 / 0.012) * exp(-age * 7.0) * dens * (k == 0 ? kickAge.w : 0.6);
        }
    }

    // ---- rain: streaks under the base, density from energy + the drop ----
    float rainAmt = smoothstep(0.25, 0.8, bd * 0.7 + energy * 0.6 + dr);
    float rain = 0.0;
    if (rainAmt > 0.01) {
        float slant = 0.18 + 0.1 * sin(time * 0.07);
        vec2 rp = vec2((uv.x + uv.y * slant) * 90.0 * asp, uv.y * 7.0 + flow * 1.6);
        float lane = hash(vec2(floor(rp.x), 3.3));
        float streak = smoothstep(0.985 - rainAmt * 0.02, 1.0, fract(rp.y * (0.5 + lane) + lane * 7.0))
                     * step(0.72, lane) * under;
        rain = streak * rainAmt * (0.4 + 0.6 * smoothstep(base, 0.0, uv.y));
    }

    // ---- compose ----
    vec3 col;
    if (light < 0.5) {
        // the glow is broken by distant weather, never a solid printed strip
        float hz = horizon * (0.3 + 0.25 * swell) * (0.4 + 0.6 * fbm(vec2(uv.x * 5.0 * asp + wind.x * 0.4, 0.7)));
        vec3 sky = mix(bg.rgb * 0.55, pal(0.12) * 0.6, hz);
        // the cloud: lit from below by the horizon, from within by charge and flicker
        float lumTop = mix(0.30, 0.10, bd);                            // the storm darkens as it loads
        vec3 cloudC = mix(pal(0.3) * 0.5, fg.rgb * lumTop, smoothstep(0.4, 0.9, body));
        cloudC += pal(0.08) * exp(-pow((uv.y - base) / 0.1, 2.0)) * 0.25 * (1.0 - bd * 0.6);
        col = mix(sky, cloudC, dens);
        col += c3.rgb * veins * lit(0.9);                              // the wind-up crawls
        col += mix(c2.rgb, c3.rgb, 0.5) * flick * lit(0.5);
        col += c3.rgb * bolt * 1.4 + pal(0.9) * sheet * lit(1.0);
        col += pal(0.5) * rain * 0.35;
        col = 1.0 - exp(-col * 1.15);                                  // tone map
    } else {
        // paper sky, graphite storm, ink rain
        vec3 sky = mix(bg.rgb, pal(0.2), horizon * 0.25);
        vec3 cloudC = mix(bg.rgb, fg.rgb * mix(0.55, 0.3, bd), dens * (0.55 + 0.35 * body));
        col = mix(sky, cloudC, dens);
        col = mix(col, c3.rgb * 0.6, veins * 0.7);
        col = mix(col, fg.rgb * 0.2, bolt * 0.8);
        col = mix(col, c1.rgb * 0.5, sheet * 0.4);
        col = mix(col, fg.rgb * 0.45, rain * 0.5);
    }

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
