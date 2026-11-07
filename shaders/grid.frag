#version 440
// Orpheus "Grid", second build: not a postcard, a place. The first cut was a
// flat outrun poster (sun, ridge, floor); this one flies you down an endless
// data canyon, raymarched: two walls of extruded panels — server racks the
// size of buildings — and the classic neon grid as the canyon floor. All
// light is the machine's own: the creases between panels run glowing trace
// lines, every panel's face carries a circuit block that lights with its
// band of the spectrum (near panels bass, far panels treble, so a chord
// lights the canyon in depth), and the far end burns with the core the
// canyon runs toward. The camera rides `flow` down the street, drifting and
// banking like gyre's; kicks fire pulses that race away along the creases
// in depth; the downbeat lifts the haze; a build narrows the canyon and
// pulls the traces toward the hot end of the palette; the drop-map wind-up
// walks a power surge panel by panel toward the core — and the drop is
// power-on: light floods back up the canyon and every trace burns at full.
// Light themes: the blueprint hall — pale panels, dark traces, no additive.
// Cost: 44 steps of a 3-plane DE with one hash per step, tetra normals.

//#common

const float PI = 3.14159265;
const int STEPS = 44;
const float TMAX = 30.0;
const float SPEED = 2.4;       // world units per unit of flow
const float HALLW = 1.5;       // half-width of the canyon at rest
const float FLOORD = 1.0;      // floor below the camera line
const float PANEL = 1.7;       // panel size on the walls

float gHallW = HALLW;

// Panel extrusion: each PANEL x PANEL tile of a wall juts out a hashed depth.
float panelAt(vec2 zy, out vec2 id) {
    id = floor(zy / PANEL);
    return hash(id) * 0.34;
}

// The canyon: left wall, right wall (paneled), floor. Returns distance.
float map(vec3 p, out int side) {
    vec2 idL, idR;
    float eL = panelAt(p.zy, idL);
    float eR = panelAt(p.zy + 61.7, idR);
    float dL = p.x + gHallW - eL;
    float dR = gHallW - eR - p.x;
    float dF = p.y + FLOORD;
    float d = dL; side = 0;
    if (dR < d) { d = dR; side = 1; }
    if (dF < d) { d = dF; side = 2; }
    return d;
}

float mapD(vec3 p) { int s; return map(p, s); }

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float m = min(res.x, res.y);
    vec2 uv = (px - res * 0.5) / m;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float loud = smoothstep(0.03, 0.8, max(swell, energy));
    float conf = clamp(beatConfidence, 0.0, 1.0);

    gHallW = HALLW * (1.0 - 0.22 * bd);                   // the walls close in as it builds

    // ---- camera: down the street on flow, drifting and banking ----
    float zc = flow * SPEED;
    vec3 ro = vec3(0.55 * sin(zc * 0.11) + 0.3 * sin(zc * 0.047 + 1.1),
                   0.18 * sin(zc * 0.083 + 0.5),
                   zc);
    vec3 ahead = vec3(0.55 * sin((zc + 4.0) * 0.11) + 0.3 * sin((zc + 4.0) * 0.047 + 1.1),
                      0.18 * sin((zc + 4.0) * 0.083 + 0.5),
                      zc + 4.0);
    vec3 fw = normalize(ahead - ro);
    float roll = camRoll() * 2.0 + sin(zc * 0.06) * 0.1;
    vec3 up = vec3(sin(roll), cos(roll), 0.0);
    vec3 rt = normalize(cross(up, fw));
    vec3 upv = cross(fw, rt);
    float fov = 0.9 + loud * 0.05 + kick * 0.02;
    vec3 rd = normalize(fw + (uv.x * rt + uv.y * upv) * fov);

    // ---- march ----
    float jit = hash(px + fract(time) * 61.7);
    float t = 0.05 + jit * 0.3;
    int side = 0;
    bool hitS = false;
    float fogK = 0.10 - loud * 0.012;
    fogK *= 1.0 - 0.15 * downbeat * conf;                 // the exhale
    for (int i = 0; i < STEPS; i++) {
        float d = map(ro + rd * t, side);
        if (d < 0.003 * t + 0.002) { hitS = true; break; }
        t += d * 0.9;
        if (t > TMAX) break;
    }
    hitS = hitS && t < TMAX;

    // ---- the air and the core ----
    float toward = max(dot(rd, fw), 0.0);
    vec3 coreC = mix(c2.rgb, c3.rgb, 0.5 + 0.5 * sin(time * 0.1));
    vec3 fogCol = mix(bg.rgb * 0.4, mix(c1.rgb, c2.rgb, 0.5) * 0.16, 0.3 + 0.3 * loud) * dark
                + bg.rgb * light;
    fogCol += coreC * pow(toward, 7.0) * (0.25 + 0.45 * loud + 1.3 * dr) * dark;  // the core, flaring on the drop
    fogCol += c3.rgb * dr * dr * (0.2 + 0.7 * pow(toward, 3.0)) * dark;           // power-on floods back up

    vec3 col = fogCol;
    if (hitS) {
        vec3 p = ro + rd * t;
        vec2 e2 = vec2(1.0, -1.0) * 0.008 * max(t, 0.5);
        vec3 n = normalize(e2.xyy * mapD(p + e2.xyy) + e2.yyx * mapD(p + e2.yyx)
                         + e2.yxy * mapD(p + e2.yxy) + e2.xxx * mapD(p + e2.xxx));

        vec3 surf;
        float depthK = clamp(t / TMAX, 0.0, 1.0);
        if (side == 2) {
            // ---- the floor: the neon grid, inside the canyon ----
            vec2 g = abs(fract(p.xz) - 0.5);
            vec2 fwp = fwidth(p.xz) + 1e-4;
            vec2 lw = clamp(vec2(0.03) + fwp, 0.0, 0.45);
            float lines = max(1.0 - smoothstep(lw.x - fwp.x, lw.x + fwp.x, 0.5 - g.x),
                              1.0 - smoothstep(lw.y - fwp.y, lw.y + fwp.y, 0.5 - g.y));
            vec3 lineC = mix(c2.rgb, c1.rgb, depthK);
            surf = bg.rgb * 0.05 + lineC * lines * (0.6 + 0.4 * energy) * dark;
            surf += c3.rgb * exp(-length(p.xz - ro.xz - vec2(0.0, 2.0)) * 0.8) * kick * kick * 0.7;
            surf = mix(surf, bg.rgb * 0.92 - fg.rgb * lines * 0.5, light); // blueprint floor
        } else {
            // ---- a wall panel: dark slab, glowing creases, a circuit block ----
            vec2 zy = side == 0 ? p.zy : p.zy + 61.7;
            vec2 id = floor(zy / PANEL);
            vec2 pc = fract(zy / PANEL);
            // this panel's voice: its depth bucket of the spectrum
            float fr = clamp(fract((id.x * PANEL - zc) * 0.021 + 0.08), 0.0, 1.0);
            float eng = pow(clamp(band(fr), 0.0, 1.0), 0.6) * (0.55 + 0.75 * swell);
            // creases between panels: the trace lines
            float crease = 1.0 - smoothstep(0.0, 0.045, min(min(pc.x, 1.0 - pc.x), min(pc.y, 1.0 - pc.y)));
            // circuit block: a few 45-degree-snapped hash traces inside the panel
            vec2 cp = (pc - 0.5) * 6.0;
            float hseed = hash(id + 7.0);
            cp = abs(fract(cp + hseed * 4.0) - 0.5);
            float circuit = 1.0 - smoothstep(0.03, 0.1, min(cp.x, cp.y));
            circuit *= step(0.1, pc.x) * step(pc.x, 0.9) * step(0.1, pc.y) * step(pc.y, 0.9);
            // the wind-up: a surge walks the panels toward the core, panel by panel
            float surge = 0.0;
            if (ant > 0.02) {
                float ph = fract(id.x * 0.13 - time * (0.5 + 1.5 * ant));
                surge = exp(-ph * 6.0) * ant;
            }
            // trace colour slides toward the hot end as the build climbs
            vec3 traceC = pal(clamp(0.3 + 0.45 * fr + 0.25 * bd, 0.0, 1.0));
            float glowAmt = crease * (0.5 + 0.5 * eng)
                          + circuit * (0.12 + 1.1 * eng + 0.8 * surge + 1.2 * dr);
            float ndv = abs(dot(n, -rd));
            float rim = pow(1.0 - ndv, 2.0);
            vec3 slab = mix(bg.rgb * 0.35, fg.rgb * 0.06, 0.5) * (0.5 + 0.5 * ndv);
            surf = slab * dark + traceC * glowAmt * faux(1.0, 0.35) * dark
                 + traceC * rim * 0.2 * (0.3 + eng) * dark;
            // kick pulses race away along the creases, in depth
            float pulses = 0.0;
            for (int j = 0; j < 3; j++) {
                float age = kickAge[j];
                if (age < 2.0) {
                    float zr = 0.5 + age * 11.0;
                    pulses += exp(-pow((t - zr) / (0.9 + age), 2.0)) * exp(-age * 1.4)
                            * (j == 0 ? kickAge.w : 0.55);
                }
            }
            surf += mix(c3.rgb, c2.rgb, 0.3) * crease * pulses * 1.3 * dark;
            // the blueprint hall
            surf = mix(surf, bg.rgb * 0.9 - fg.rgb * (crease * 0.45 + circuit * 0.3 * (0.3 + eng)), light);
        }

        float fogA = 1.0 - exp(-t * fogK);
        fogA = fogA * fogA * (3.0 - 2.0 * fogA);
        col = mix(surf, fogCol, fogA);
    }

    // the air carries a hum of the machine's light
    col += mix(c1.rgb, c2.rgb, 0.5) * lit(0.015 + 0.03 * loud + 0.03 * kick) * faux(1.0, 0.4);

    // ---- vignette and shoulder ----
    vec2 vq = (px - res * 0.5) / res;
    float vig = smoothstep(0.3, 0.9, length(vq * vec2(1.0, 0.9)));
    col = mix(col, mix(vec3(0.0), bg.rgb * 0.9, light), vig * mix(0.45, 0.15, light));
    col = max(col, vec3(0.0));
    col = col / (1.0 + col * 0.15);
    fragColor = vec4(max(col + dither(px), vec3(0.0)), 1.0) * qt_Opacity;
}
