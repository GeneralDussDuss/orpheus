#version 440
// Orpheus "Gyre": a slow glide through an infinite gyroid, the minimal surface
// sin(x)cos(y)+sin(y)cos(z)+sin(z)cos(x) = t. The surface itself is near-black
// matte; all light is soft fresnel seeping along its curvature in c1 -> c2, as
// if the labyrinth were lit from within, and the far end dissolves into fog.
// No speculars, no hard shadows, no hard edges. Loudness (swell) opens the
// surface so the whole space breathes wider; a kick sends a soft band of light
// racing away along the walls; the downbeat lifts the fog a touch; a build
// tightens the labyrinth; a drop ignites the deepest fog in c3.
// One raymarch: 32 steps, one gyroid evaluation per step, jittered ray start.

//#common

const float PI = 3.14159265;
const int STEPS = 32;
const float TMAX = 26.0;
const float SPEED = 1.6;      // world units per unit of flow

float gyr(vec3 p) {
    return dot(sin(p), cos(p.yzx));
}

// Thin two-sided shell around the level set g = lvl. Shell half-thickness TH.
float gTh = 0.12;
float gLvl = 0.0;
float map(vec3 p) {
    return abs(abs(gyr(p) - gLvl) * 0.62 - gTh) * 0.9;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float m = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / m;
    float dark = 1.0 - light;
    float hit = max(kick, beat * 0.8);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));
    float conf = clamp(beatConfidence, 0.0, 1.0);
    float dropF = smoothstep(0.0, 0.85, drop);

    // ---- the breathing: ~0.1 Hz at rest, opened by loudness, eased ---------------
    float breath = 0.5 + 0.5 * sin(time * 0.628);
    float open = loud * loud * (3.0 - 2.0 * loud);
    gLvl = 0.10 * (breath - 0.5) + 0.55 * open * 0.6;      // the surface level drifts: channels widen
    gTh = 0.11 + 0.05 * (1.0 - open) - 0.03 * build;       // shell thins as it opens, firms as it builds

    // ---- camera: forward on flow, gently curving drift ---------------------------
    float zc = flow * SPEED;
    vec3 ro = vec3(1.1 * sin(zc * 0.21) + 0.6 * sin(zc * 0.083 + 1.3),
                   0.9 * sin(zc * 0.17 + 0.7) + 0.5 * sin(zc * 0.061),
                   zc);
    ro.xy += vec2(sin(time * 0.043), sin(time * 0.037 + 1.9)) * 0.25;
    vec3 ahead = vec3(1.1 * sin((zc + 3.0) * 0.21) + 0.6 * sin((zc + 3.0) * 0.083 + 1.3),
                      0.9 * sin((zc + 3.0) * 0.17 + 0.7) + 0.5 * sin((zc + 3.0) * 0.061),
                      zc + 3.0);
    vec3 fw = normalize(ahead - ro + vec3(0.0, 0.0, 0.0));
    // The domain rolls about the travel axis: a slow turn, flow-driven, tempo-flavoured.
    float roll = camRoll() + zc * 0.035 + sin(time * 0.07) * 0.18 * clamp(tempo, 0.4, 1.6);
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(up, fw));
    vec3 upv = cross(fw, rt);
    float fov = 0.85 + loud * 0.04 + hit * 0.02;
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * fov);

    // Build tightens the labyrinth: scale the ray's reach only, so nothing teleports.
    float sc = 1.0 + build * 0.30;
    vec3 base = ro * 0.9;

    // ---- march (jittered start, early-out on fog saturation) ---------------------
    float jit = hash(px + fract(time) * 61.7);
    float t = 0.05 + jit * 0.35;
    float d = 1.0;
    int i;
    float fogK = 0.115 - loud * 0.012 - light * 0.01;
    fogK *= 1.0 - 0.18 * downbeat * conf;                   // the exhale: fog lifts a touch
    bool hitS = false;
    for (i = 0; i < STEPS; i++) {
        d = map(base + rd * t * sc * 0.9);
        float e = 0.0035 * t;
        if (d < e) { hitS = true; break; }
        t += d / (0.9 * sc);
        if (t > TMAX || 1.0 - exp(-t * fogK) > 0.985) break;
    }
    hitS = hitS && t < TMAX;

    // ---- colours -----------------------------------------------------------------
    vec3 fogDark = mix(bg.rgb * 0.55, mix(c1.rgb, c2.rgb, 0.5) * 0.14, 0.25 + 0.25 * loud);
    vec3 fogLight = mix(bg.rgb, vec3(1.0), 0.25);
    vec3 fogCol = mix(fogDark, fogLight, light);
    float toward = max(dot(rd, fw), 0.0);
    // Drop: light floods in from ahead, the deepest fog ignites in c3 and fades back.
    fogCol += mix(c3.rgb, fg.rgb, 0.2) * dropF * dropF * (0.25 + 0.9 * pow(toward, 3.0)) * dark;
    fogCol = mix(fogCol, mix(bg.rgb, c3.rgb, 0.18), dropF * 0.5 * light);
    // A faint glow of the far end of the labyrinth.
    fogCol += mix(c1.rgb, c2.rgb, 0.5) * pow(toward, 6.0) * 0.05 * dark * (1.0 + loud);

    vec3 col = fogCol;
    if (hitS) {
        vec3 p = base + rd * t * sc * 0.9;
        float ex = max(0.012 * t, 0.01);
        vec2 k2 = vec2(1.0, -1.0);
        vec3 n = normalize(k2.xyy * map(p + k2.xyy * ex) + k2.yyx * map(p + k2.yyx * ex)
                         + k2.yxy * map(p + k2.yxy * ex) + k2.xxx * map(p + k2.xxx * ex));
        // Cheap curvature / occlusion: how far the field is from where flat geometry says it should be.
        float ao = clamp(map(p + n * 0.35) / 0.35 * 1.4 + 0.2, 0.0, 1.0);
        ao = ao * ao * (3.0 - 2.0 * ao);
        float ndv = abs(dot(n, -rd));
        float rim = pow(1.0 - ndv, 2.0);
        float soft = 0.5 + 0.5 * dot(n, -rd);

        // The light is from within: fresnel along curvature, c1 near, c2 farther, tracking depth.
        float depthK = clamp(t / TMAX, 0.0, 1.0);
        vec3 lc = pal(clamp(0.15 + depthK * 0.7 + 0.1 * sin(p.z * 0.4 + time * 0.05), 0.0, 1.0));
        float glowAmt = rim * (0.35 + 0.35 * loud) * (0.35 + 0.65 * ao);
        glowAmt *= 1.0 - 0.45 * build * (1.0 - ao);          // the folds darken as the tension climbs

        // Kick rings: a soft band of light racing away from the camera along the walls.
        float rings = 0.0;
        for (int j = 0; j < 3; j++) {
            float age = j == 0 ? kickAge.x : (j == 1 ? kickAge.y : kickAge.z);
            float zr = 0.4 + age * 7.5;
            float w = 1.1 + age * 0.8;
            float bnd = exp(-pow((t - zr) / w, 2.0)) * exp(-age * 1.1);
            rings += bnd * (j == 0 ? kickAge.w : 0.5 * kickAge.w) * smoothstep(0.0, 0.05, age + 0.01);
        }
        float ringLit = rings * (0.18 + 0.9 * rim + 0.25 * soft) * (0.4 + 0.6 * ao);

        vec3 matte = mix(bg.rgb * 0.5, lc * 0.05, 0.5) * (0.4 + 0.6 * ao) * (0.6 + 0.4 * soft);
        vec3 emis = lc * glowAmt + mix(c3.rgb, fg.rgb, 0.25) * ringLit;
        vec3 sDark = matte + emis * faux(1.0, 0.3);

        // Light themes: pale porcelain, dark creases where the folds close, a tint along the rim.
        vec3 porc = mix(bg.rgb, vec3(1.0), 0.15) * (0.80 + 0.20 * soft);
        porc = mix(porc * 0.55 + c1.rgb * 0.12, porc, ao);
        porc = mix(porc, lc * 0.55, rim * 0.22 + ringLit * 0.18);
        vec3 surf = mix(sDark, porc, light);

        float fog = 1.0 - exp(-t * fogK);
        fog = fog * fog * (3.0 - 2.0 * fog);
        float near = smoothstep(0.05, 0.5, t);               // surface melts in if the lens sits inside the shell
        col = mix(fogCol, mix(surf, fogCol, fog), near);
    }

    // Soft haze: the air carries a little of the surface light.
    col += mix(c1.rgb, c2.rgb, 0.5 + 0.5 * sin(time * 0.05)) * lit(0.015 + 0.03 * loud + 0.03 * hit) * faux(1.0, 0.4);
    col += mix(c1.rgb, c3.rgb, 0.5) * build * 0.025 * dark;

    // ---- vignette ----------------------------------------------------------------
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.25, 0.85, length(vq * vec2(1.0, 0.9)));
    col = mix(col, mix(vec3(0.0), bg.rgb * 0.88, light), vig * mix(0.5, 0.18, light));

    col = max(col, vec3(0.0));
    col = col / (1.0 + col * 0.15);                          // gentle shoulder, no clip
    fragColor = vec4(max(col + dither(px), vec3(0.0)), 1.0) * qt_Opacity;
}
