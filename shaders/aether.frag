#version 440
// Orpheus "Aether", second build: the cave is gone, this is weather. You fly
// a bending channel between cumulus walls built from domain-warped noise
// (the vapour curls instead of crumbling — the first cut read as rock), under
// a broken overcast that lets a low sun stripe the canyon with crepuscular
// shafts: the march accumulates light in the CLEAR air wherever the sun's
// tap says the gap is open, so god rays hang between the walls and swing as
// they pass. Cloud faces that stand against the sun burn at the edges —
// forward scattering whitens thin vapour into silver linings. Now and then a
// bridge of cloud crosses the channel overhead and you pass beneath it in
// shadow. Bass is the mass of the walls; mids churn the warp; treble frays
// the wisps. Kicks are thunder buried in the nearest wall. A build lowers
// and seals the overcast until the canyon runs dim — the drop-map wind-up
// tears the first rays through — and the drop is the breach: the ceiling
// rips, the sun swings high, every shaft fires at once, and the gloom seals
// back as the pulse fades. Escaped rays find cirrus, the sun's disc and
// halo, and stars in the high blue. Light themes: the white sea — sunlit
// vapour drawn in shade on pale air.
// Cost: 50 steps; dense samples pay ~8 noise taps (density + sun tap),
// clear samples ~6 every other step for the rays; early-out when opaque.

//#common

const float PI = 3.14159265;
const int STEPS = 50;
const float TMAX = 30.0;
const float SPEED = 2.6;

float hash3(vec3 p) { return hash(p.xy + vec2(p.z * 17.17, p.z * 9.58)); }

float vnoise3(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x),
                  mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y);
    float b = mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x),
                  mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y);
    return mix(a, b, f.z);
}

float gBass = 0.0, gMid = 0.0, gBd = 0.0, gDr = 0.0;

// Where the channel runs at depth z (the canyon bends).
float channelX(float z) { return 1.3 * sin(z * 0.05) + 0.7 * sin(z * 0.021 + 2.0); }

// The vapour: domain-warped, wind-stretched noise carved by the canyon shape.
float cloud(vec3 p) {
    // wind anisotropy: stretch along z so the vapour streams, and warp the
    // domain so it CURLS — this is what separates weather from rock
    vec3 ws = vec3(p.x, p.y, p.z * 0.55);
    float q = vnoise3(ws * 0.31 + vec3(0.0, 0.0, 0.0));
    vec3 wp = ws + (q - 0.5) * (1.6 + gMid * 1.4);
    float n = 0.50 * vnoise3(wp * 0.34)
            + 0.27 * vnoise3(wp * 0.78 + vec3(0.0, 9.0, 4.0))
            + 0.14 * vnoise3(wp * 1.7 + 23.0)
            + 0.07 * vnoise3(wp * 3.6 + 47.0);
    float cx = channelX(p.z);
    float wall = smoothstep(5.5 - 1.0 * gBass, 8.5, abs(p.x - cx)) * (0.85 + 0.35 * smoothstep(1.5, 5.0, p.y));
    float ceilD = smoothstep(7.5 - 3.0 * gBd, 9.5, p.y) * gBd * (1.0 - gDr * 0.95);
    float sea = smoothstep(-4.2, -6.4, p.y);
    float shape = max(max(wall, ceilD), sea);
    return clamp((n - 0.80 + 0.72 * shape) * 2.1, 0.0, 1.0) * smoothstep(0.08, 0.4, shape);
}

// A cheap 2-octave tap for sun-shadow tests.
float cloudLo(vec3 p) {
    vec3 ws = vec3(p.x, p.y, p.z * 0.55);
    float n = 0.6 * vnoise3(ws * 0.34) + 0.3 * vnoise3(ws * 0.78 + vec3(0.0, 9.0, 4.0));
    float cx = channelX(p.z);
    float wall = smoothstep(5.5 - 1.0 * gBass, 8.5, abs(p.x - cx)) * (0.85 + 0.35 * smoothstep(1.5, 5.0, p.y));
    float ceilD = smoothstep(7.5 - 3.0 * gBd, 9.5, p.y) * gBd * (1.0 - gDr * 0.95);
    float sea = smoothstep(-4.2, -6.4, p.y);
    float shape = max(max(wall, ceilD), sea);
    return clamp((n - 0.80 + 0.72 * shape) * 2.1, 0.0, 1.0) * smoothstep(0.08, 0.4, shape);
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float mres = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / mres;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));
    gBass = clamp(bass * (2.0 + 2.0 * swell), 0.0, 1.0);
    gMid = band(0.45);
    gBd = bd; gDr = dr;

    // ---- the flight: riding the channel's bends, climbing as it builds ----
    float zc = flow * SPEED;
    vec3 ro = vec3(channelX(zc), 2.4 + 0.6 * sin(zc * 0.06) + 1.6 * bd, zc);
    vec3 ahead = vec3(channelX(zc + 5.0), ro.y + 0.1, zc + 5.0);
    vec3 fw = normalize(ahead - ro);
    float roll = camRoll() + (channelX(zc + 5.0) - channelX(zc)) * 0.08;   // bank into the bends
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(up, fw));
    vec3 upv = cross(fw, rt);
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * (0.95 + 0.05 * loud));

    // ---- the sun: low ahead-left, swinging high when the drop breaches ----
    vec3 sunL = normalize(vec3(-0.45, 0.24 + 0.55 * dr, 0.85));
    vec3 sunC = mix(pal(0.92), fg.rgb, 0.3);
    vec3 shadeC = mix(pal(0.25), bg.rgb, 0.45);
    float sunPow = 0.9 + 0.5 * loud + 2.4 * dr + 0.6 * ant;
    float toSun = max(dot(rd, sunL), 0.0);
    float scatter = pow(toSun, 6.0);                        // forward scattering

    // ---- march the weather ----
    float jit = hash(px + fract(time) * 61.7);
    float t = 0.1 + jit * 0.4;
    vec3 acc = vec3(0.0);
    float trans = 1.0;
    bool rayStep = jit > 0.5;                                // stagger the clear-air ray taps
    for (int i = 0; i < STEPS; i++) {
        vec3 p = ro + rd * t;
        float dens = cloud(p);
        float dt = clamp(0.18 + (1.0 - dens) * 0.34, 0.12, 0.52);
        if (dens > 0.01) {
            // sun shadow: one cheap tap a step toward the light
            float shade = cloudLo(p + sunL * 0.7);
            float sunK = clamp(0.55 + (dens - shade) * 2.4, 0.0, 1.7);
            vec3 cc = mix(shadeC, sunC, clamp(sunK * 0.65, 0.0, 1.0)) * (0.45 + 0.55 * sunK) * sunPow;
            // silver lining: thin, sun-facing vapour whitens hard
            cc += sunC * scatter * (1.0 - dens) * clamp(1.0 - shade * 3.0, 0.0, 1.0) * 1.6;
            // first light tearing through the ceiling on the wind-up
            cc += pal(0.8) * ant * smoothstep(2.8, 4.6, p.y) * 1.5;
            // thunder in the walls
            if (kickAge.x < 0.6) {
                vec3 at = vec3(channelX(zc + 3.0) + sign(sin(kicks * 2.39)) * 2.3,
                               0.7 + hash(vec2(kicks, 3.3)) * 1.6,
                               zc + 3.0 + hash(vec2(kicks, 8.1)) * 5.0);
                float d2 = dot(p - at, p - at);
                cc += mix(c2.rgb, c3.rgb, 0.4) * exp(-d2 * 0.5) * exp(-kickAge.x * 6.0) * kickAge.w * 3.5;
            }
            float a = dens * dt * 2.8;
            acc += cc * a * trans;
            trans *= exp(-a * 1.25);
            if (trans < 0.02) break;
        } else if (rayStep) {
            // crepuscular shafts: clear air glows faintly where the sun gets in
            float open = 1.0 - clamp(cloudLo(p + sunL * 1.1) * 3.0, 0.0, 1.0);
            acc += sunC * open * (0.016 + 0.05 * dr + 0.02 * ant) * sunPow * dt * trans * (0.4 + 0.6 * scatter);
        }
        rayStep = !rayStep;
        t += dt;
        if (t > TMAX) break;
    }

    // ---- the sky the survivors reach ----
    vec3 sky = vec3(0.0);
    if (trans > 0.02) {
        float upness = clamp(rd.y, 0.0, 1.0);
        sky = mix(pal(0.15) * 0.45, pal(0.5) * 0.14, upness) * dark + bg.rgb * light * (0.9 + 0.1 * upness);
        // high cirrus: a thin streaked sheet on the dome
        float cir = vnoise3(vec3(rd.x * 3.0, rd.y * 8.0, rd.z * 3.0) + vec3(flow * 0.01, 0.0, 0.0));
        sky += mix(shadeC, sunC, 0.5) * pow(max(cir - 0.45, 0.0), 1.6) * upness * 0.5 * dark;
        sky += bg.rgb * pow(max(cir - 0.45, 0.0), 1.6) * upness * 0.1 * light;
        float sunD = toSun;
        sky += sunC * (pow(sunD, 700.0) * 2.4 + pow(sunD, 32.0) * 0.5 + pow(sunD, 6.0) * 0.12) * sunPow * dark;
        sky += sunC * pow(sunD, 8.0) * 0.15 * light;
        vec2 sph = vec2(atan(rd.z, rd.x) * 1.4, rd.y * 2.6);
        vec2 cellp = floor(sph * 30.0);
        float h = hash(cellp);
        if (h > 0.93 && rd.y > 0.08) {
            vec2 at = (cellp + vec2(hash(cellp + 1.3), hash(cellp + 2.6))) / 30.0;
            float d2 = dot(sph - at, sph - at);
            sky += fg.rgb * exp(-d2 * 2.2e5) * (0.25 + 0.4 * band(0.85)) * (1.0 - sunD) * dark;
        }
    }

    vec3 col;
    if (light < 0.5) {
        col = sky * trans + acc;
        col = 1.0 - exp(-col * 1.2);
    } else {
        float body = clamp(1.0 - trans, 0.0, 1.0);
        vec3 tint = clamp(acc / max(dot(acc, vec3(0.6)), 1e-3), 0.0, 1.5);
        col = sky * trans + mix(bg.rgb * 0.95, mix(fg.rgb * 0.45, tint * 0.5, 0.45), body * 0.8);
        col += sunC * dr * 0.15;
    }

    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.35, 0.95, length(vq * vec2(1.0, 0.9)));
    col = mix(col, mix(vec3(0.0), bg.rgb * 0.92, light), vig * mix(0.4, 0.12, light));
    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
