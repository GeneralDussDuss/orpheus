#version 440
// Orpheus "Nebula": ethereal cosmic dust. A kaliset fractal field read as a
// slow, deep, glowing cloud: three depth slices drift at slightly different
// rates, far ones in c1, middle in c2, the near highlights in c3, so depth
// reads as a colour-temperature shift. The structure is wisps and filaments,
// not geometry. It orbits its fractal constant very slowly and breathes at
// about 0.1 Hz; bass eases the constant a hair (swell-enveloped), the treble
// tilt drifts the palette, snares ignite single stars that the dust swallows
// back, a build contracts the cloud toward a protostar core, and a drop is the
// star's birth: one soft shock shell and a single core flash. Breakdowns thin
// the dust into open space. No strobe anywhere. Light themes get dark ink wash.

//#common

const int LAYERS = 3;
const int ITER = 16;

// One kaliset slice: glow accumulated over the iterations, 0..~1.
float kali(vec2 p, vec2 c) {
    float a = 0.0;
    float pl = length(p);
    for (int i = 0; i < ITER; i++) {
        p = abs(p) / max(dot(p, p), 1e-4) - c;
        float l = length(p);
        a += abs(l - pl);
        pl = l;
    }
    return a / float(ITER);
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float m = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / m;
    float r0 = length(uv);

    // Smoothed treble tilt: three neighbouring bands, so it never flickers.
    float tilt = (band(0.70) + band(0.75) + band(0.80)) * 0.3333;
    tilt = clamp(tilt, 0.0, 1.0);

    // The cloud's slow life: ~0.1 Hz breath, a little more from the loudness envelope.
    float breath = 0.5 + 0.5 * sin(time * 0.63);
    float down = downbeat * beatConfidence;
    float thin = (int(section + 0.5) == 3) ? 0.55 : 1.0;
    float gainAll = (0.85 + 0.15 * breath + 0.05 * down + 0.15 * swell) * thin;

    // Build: contraction toward the centre; drop: one expanding shock shell.
    float bd = clamp(build, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    vec2 q = uv * (1.0 + 0.30 * bd * smoothstep(1.2, 0.0, r0));
    float ringR = (1.0 - dr) * 0.85;
    float ringW = 0.05 + (1.0 - dr) * 0.06;
    float ring = exp(-pow((r0 - ringR) / ringW, 2.0)) * dr * smoothstep(0.0, 0.12, 1.0 - dr);
    q += normalize(uv + vec2(1e-5)) * ring * 0.02;            // the shell displaces the dust

    // The fractal constant: orbits very slowly; bass eases it by <= 0.015.
    float ph = flow * 0.035 + time * 0.012;
    vec2 c = vec2(0.80, 0.62) + 0.045 * vec2(sin(ph), cos(ph * 0.73 + 1.0));
    c += 0.015 * clamp(bass * swell, 0.0, 1.0) * vec2(0.8, -0.6);

    vec3 acc = vec3(0.0);
    float dens = 0.0;
    for (int i = 0; i < LAYERS; i++) {
        float z = float(i) / float(LAYERS - 1);                // 0 far .. 1 near
        float s = 1.25 + 0.55 * float(i);
        float ang = 0.35 * float(i) + 0.02 * sin(flow * 0.02 + float(i));
        vec2 d = vec2(sin(flow * 0.011 + float(i) * 2.1), cos(flow * 0.009 + float(i) * 1.3)) * (0.08 + 0.06 * z);
        vec2 p = q * s;
        p = vec2(p.x * cos(ang) - p.y * sin(ang), p.x * sin(ang) + p.y * cos(ang)) + d;
        float a = kali(p, c);
        float x = clamp(a * mix(0.55, 0.9, z), 0.0, 20.0);
        float wisp = x / (1.0 + x);                            // soft, bounded
        wisp = wisp * wisp * (1.4 - 0.5 * z);                  // keep it filamentary, not a fog
        float off = clamp(z * 0.8 + 0.1 + 0.25 * tilt + 0.06 * sin(time * 0.05), 0.0, 1.0);
        acc += pal(off) * wisp * mix(0.9, 0.6, 1.0 - z) * gainAll;
        dens += wisp * (0.45 + 0.1 * z);
    }

    // Protostar core: brightens while building, flashes once at the drop.
    float core = exp(-r0 * r0 / 0.012) * (0.45 * bd * bd + 1.6 * dr * dr)
               + exp(-r0 * r0 / 0.08) * 0.25 * bd;
    vec3 coreC = mix(pal(0.85), pal(1.0), clamp(dr + 0.3 * bd, 0.0, 1.0));
    vec3 shell = c3.rgb * ring * 0.7;

    // Stars: sparse hashed points on a coarse grid; each onset picks different ones.
    vec3 stars = vec3(0.0);
    if (snap > 0.01) {
        for (int k = 0; k < 2; k++) {
            float g = 7.0 + 5.0 * float(k);
            vec2 cell = floor(uv * g + 0.5 * float(k));
            float h = hash(cell + vec2(kicks * 7.13 + float(k) * 3.0, 1.7));
            if (h > 0.965) {
                vec2 at = (cell + 0.25 + 0.5 * vec2(hash(cell + 2.3), hash(cell + 5.9)) - 0.5 * float(k)) / g;
                float dd = length(uv - at);
                stars += fg.rgb * exp(-dd * dd / 0.00012) * snap * 0.8;
            }
        }
    }

    vec3 col;
    if (light < 0.5) {
        vec3 add = acc * 1.15 + coreC * core + shell + stars;
        add = max(add, 0.0);
        add = 1.0 - exp(-add * 1.2);                           // tone map, hue-keeping enough at these levels
        col = bg.rgb * 0.9 + add * (1.0 - 0.5 * bg.rgb);
    } else {
        // Ink wash: multiplicative shading on the paper, no white-out.
        float ink = 1.0 - exp(-dens * 0.9 * gainAll);
        vec3 tint = clamp(acc / max(dens, 1e-3), 0.0, 1.0);
        vec3 inkC = mix(tint, fg.rgb, 0.5) * 0.7;
        col = bg.rgb * mix(vec3(1.0), inkC, ink * 0.8);
        float k = 1.0 - exp(-(core * 0.8 + ring * 0.5) * 1.5);
        col *= mix(vec3(1.0), c3.rgb * 0.8, k * 0.6);
        col = mix(col, fg.rgb * 0.6, clamp(stars.r + stars.g, 0.0, 1.0) * 0.5);
    }

    // Vignette toward the bg, so the cloud floats in space.
    float vig = smoothstep(0.55, 1.15, r0) * 0.55;
    col = mix(col, bg.rgb * mix(0.6, 1.0, light), vig);

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
