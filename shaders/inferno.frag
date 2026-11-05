#version 440
// Orpheus "Inferno": the infinite fire. A full-frame domain-warped firestorm
// (iq's q / r / f warp, stretched tall and scrolled upward by flow) painted
// entirely through the theme palette. Kicks make the flame front leap in
// layered surges; loudness is global heat; snares throw sparks. A build is the
// INHALE (the fire sinks, darkens, the top starves) and the drop is the
// ERUPTION: a column blasts up the centre and an ember storm follows. At rest
// it settles to slow coals. Light themes get dark smoke with ember accents.

//#common

// Hoskins-style hash, no sin().
float h12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h12(i), h12(i + vec2(1.0, 0.0)), f.x),
               mix(h12(i + vec2(0.0, 1.0)), h12(i + vec2(1.0, 1.0)), f.x), f.y);
}

const mat2 ROT = mat2(0.8, 0.6, -0.6, 0.8);

// 4 octaves, domain rotated between each so no axis-aligned artefacts.
float fbm(vec2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 4; i++) {
        s += a * vnoise(p);
        p = ROT * p * 2.03 + vec2(1.7, 9.2);
        a *= 0.5;
    }
    return s * 1.0667;     // 0..1
}

void main() {
    vec2 frag = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 uv = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y);     // y up, 0 = base
    float asp = res.x / res.y;
    float dark = 1.0 - light;

    // ---- the song, as fire parameters ----------------------------------------
    float inhale = build * (1.0 - drop);
    float erupt = drop;
    float conf = beatConfidence;
    float breathe = 0.5 + 0.5 * sin(time * 0.63);              // ~0.1 Hz coals breathing

    // Layered kick surges: a bump of flame rolling up from the base, per recent kick.
    float surge = 0.0, surgeWarp = 0.0;
    for (int i = 0; i < 3; i++) {
        float age = i == 0 ? kickAge.x : (i == 1 ? kickAge.y : kickAge.z);
        float amp = i == 0 ? mix(0.5, 1.0, kickAge.w) : (i == 1 ? 0.55 : 0.3);
        float front = 0.04 + age * 1.5;                       // height the surge has reached
        float env = exp(-age * 3.2) * amp * step(age, 7.9);
        surge += env * exp(-pow((uv.y - front) * 3.2, 2.0));
        surgeWarp += env * smoothstep(0.0, 0.4, front) * smoothstep(1.2, 0.2, front);
    }

    // Flame height: coals at rest, breathing, heat with loudness, leaps on kicks.
    float H = 0.30 + 0.05 * breathe + 0.22 * swell + 0.22 * kick + 0.10 * clamp(energy, 0.0, 1.0);
    H = H * (1.0 - 0.50 * inhale) + 0.55 * erupt;
    H += 0.12 * (surge > 0.0 ? 1.0 : 0.0) * min(surgeWarp, 1.0);
    float heat = 0.55 + 0.45 * swell;                          // global brightness/saturation
    float warpAmt = 0.9 + 0.7 * swell + 0.9 * kick + 0.5 * min(surgeWarp, 1.5) + 1.4 * erupt - 0.3 * inhale;

    // ---- domain-warped fire --------------------------------------------------
    vec2 p = vec2((uv.x - 0.5) * asp * 2.4, uv.y * 1.35 - flow * 0.55);
    p.y *= 0.8 + 0.15 * inhale;                                // stretch tall
    float drift = flow * 0.1 + time * 0.03;
    float q = fbm(p + vec2(0.0, drift));
    float r = fbm(p + warpAmt * vec2(q - 0.5, 0.6 * (q - 0.5)) * 1.8 + vec2(3.1 + drift, 1.7));
    float f = fbm(p + warpAmt * vec2(r - 0.5, q - 0.5) * 1.5 + vec2(8.3, 2.8));

    // ---- vertical shape: hottest base, ragged noisy top ----------------------
    float yn = uv.y / max(H, 0.05);
    float ragged = yn + (f - 0.5) * 0.7 + (r - 0.5) * 0.35;
    float body = pow(max(1.0 - ragged, 0.0), 1.6);
    float baseGlow = exp(-uv.y * 9.0);
    float pulse = conf * (pow(max(1.0 - beatPhase, 0.0), 3.0) * 0.07 + downbeat * 0.12);
    baseGlow *= 0.55 + pulse + 0.35 * kick;

    float I = body * (0.35 + 1.15 * f * (0.6 + 0.5 * r)) * heat + baseGlow * (0.6 + 0.4 * f);
    I += surge * body * 0.5 + surge * 0.12 * f;

    // The eruption: a column blasting up the middle, fed by the warp field.
    float cx = (uv.x - 0.5) * asp + (q - 0.5) * 0.25;
    float colW = 0.07 + 0.05 * (1.0 - uv.y);
    float column = exp(-pow(cx / colW, 2.0)) * smoothstep(1.25, 0.2, uv.y + (f - 0.5) * 0.45);
    I += erupt * column * (0.9 + 0.7 * f);
    I += erupt * 0.25 * body;

    // The inhale: top starves black, whole fire dims, tension.
    I *= 1.0 - inhale * (0.30 + 0.55 * smoothstep(0.1, 0.55, uv.y));
    // Coals at rest never die.
    I = max(I, baseGlow * 0.35);

    // ---- sparks: sparse hashed embers rising fast ----------------------------
    float spark = 0.0;
    float rate = 0.015 + 0.16 * snap + 0.08 * kick + 0.45 * erupt;
    for (int L = 0; L < 2; L++) {
        float fl = float(L);
        float cols = 26.0 + 22.0 * fl;
        vec2 g = vec2(uv.x * asp * cols, 0.0);
        float cid = floor(g.x);
        float hs = h12(vec2(cid, fl * 7.0 + kicks * 1.3));
        float hs2 = h12(vec2(cid + 31.0, fl * 3.0));
        float live = step(hs, rate * (L == 0 ? 1.0 : 0.7));
        float spd = 0.35 + 0.5 * hs2 + 0.5 * erupt;
        float yy = fract(hs2 * 5.0 + flow * spd * 0.7 + fl * 0.37);
        float sy = yy * (0.35 + H * 1.1);
        float sx = (cid + 0.5 + sin(yy * 9.0 + hs * 6.28) * 0.35) / cols;
        vec2 d = vec2((uv.x * asp - sx * asp) * res.y, (uv.y - sy) * res.y);
        float rad = (1.6 + 1.4 * hs) * (res.y / 1080.0 + 0.4);
        spark += live * exp(-dot(d, d) / (rad * rad)) * (1.0 - yy) * (0.8 + 0.5 * (1.0 - fl));
    }
    spark = min(spark, 1.2);

    // ---- colour: black-body shaped ramp through the theme palette -------------
    float t = clamp(I, 0.0, 1.5);
    vec3 body3 = pal(clamp(t * 0.95, 0.0, 1.0));               // c1 -> c2 -> c3
    vec3 deep = mix(bg.rgb, c1.rgb, 0.55);
    vec3 fireRgb = mix(deep, body3, smoothstep(0.04, 0.35, t));
    fireRgb = mix(fireRgb, mix(c3.rgb, fg.rgb, 0.7), smoothstep(0.9, 1.5, t) * (0.5 + 0.4 * heat));
    fireRgb *= 0.55 + 0.75 * smoothstep(0.0, 1.0, t) + 0.25 * heat;
    fireRgb += mix(c3.rgb, fg.rgb, 0.5) * spark * 0.9;
    float aD = clamp(smoothstep(0.015, 0.30, t) + spark * 0.8, 0.0, 1.0);
    vec3 outD = fireRgb * aD;
    outD = outD / (1.0 + max(max(outD.r, outD.g), outD.b) * 0.35);   // soft clip, keeps hue

    // Light themes: dark smoke and calligraphy on the paper, small warm embers.
    vec3 smoke = mix(fg.rgb, c1.rgb, 0.35 * (1.0 - smoothstep(0.2, 0.8, t)));
    vec3 ember = mix(c2.rgb, c3.rgb, 0.6) * 0.75;
    vec3 inkRgb = mix(smoke, ember, smoothstep(0.75, 1.2, t) * 0.8);
    inkRgb = mix(inkRgb, ember, clamp(spark, 0.0, 1.0));
    float aL = clamp(smoothstep(0.04, 0.9, t) * (0.55 + 0.35 * heat) + spark * 0.7, 0.0, 0.92);
    vec3 outL = inkRgb * aL;

    vec3 rgb = mix(outD, outL, light);
    float a = mix(aD, aL, light);

    // Vignette: corners sink toward shadow.
    vec2 qv = qt_TexCoord0 - 0.5;
    float vig = smoothstep(0.35, 0.9, length(qv * vec2(1.0, 1.1))) * mix(0.45, 0.10, light);
    rgb *= 1.0 - vig;

    rgb = max(rgb, 0.0);
    a = clamp(a, 0.0, 1.0);
    fragColor = vec4(rgb + dither(frag) * a, a) * qt_Opacity;
}
