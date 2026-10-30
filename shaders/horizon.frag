#version 440
// Orpheus "Horizon": glowing ridgelines rolling toward you out of a banded
// sun. Each ridge is a moment of sound: new ones rise at the horizon and
// travel forward, mirrored so the bass swells in the middle. A far mountain
// range stands against the sun, the distance melts into its glow, and the
// stars scintillate. Kicks punch the camera, pulse the sun and send a wave
// of light rolling down the ridges toward you; snares make stars flare.

//#common

layout(binding = 1) uniform sampler2D hist;

const int K = 30;            // ridges, front (0) to back
const float R = 40.0;        // history rows

vec3 sat3(vec3 x) { return x / (1.0 + max(max(x.r, x.g), x.b) * 0.6); }

void main() {
    vec2 p = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float dark = 1.0 - light;

    // ---- camera -------------------------------------------------------------------
    vec2 focus = vec2(res.x * 0.5, res.y * 0.6);
    float zoom = 1.0 + swell * 0.06 + kick * kick * 0.05;
    float jolt = (hash(vec2(kicks, 5.3)) - 0.5) * 2.0;
    p = focus + (p - focus) / zoom;
    p = rotateAround(p, focus, camRoll() + jolt * kick * kick * 0.03);
    p.y -= camBob(res.y) - kick * res.y * 0.012;
    vec2 uv = p / res;
    float ridgeTop = res.y * 0.60;                          // ridge perspective reference
    float horizon = mix(res.y * 0.02, ridgeTop, 1.0 - 0.8 / 4.2) + 1.0;   // where the back ridge sits
    vec3 sunA = c2.rgb, sunB = c1.rgb;
    vec3 glowCol = mix(sunA, sunB, 0.35);

    // col is premultiplied throughout (rgb already scaled by coverage).
    vec4 col = vec4(0.0);

    // ---- sky: a glow rising off the horizon, scintillating stars ------------------
    if (p.y > horizon) {
        float up = (p.y - horizon) / (res.y - horizon);
        float skyGlow = dark * glow(up, 0.45 + swell * 0.15) * (0.16 + energy * 0.18 + kick * 0.22);
        col = vec4(glowCol * skyGlow, skyGlow);

        // Round, sub-pixel stars on a sparse jittered grid. Each twinkles at its
        // own rate (two detuned sines, so they scintillate rather than pulse in sync).
        vec2 cell = floor(p / 9.0);
        vec2 at = (cell + 0.2 + 0.6 * vec2(hash(cell + 3.1), hash(cell + 5.7))) * 9.0;
        float h0 = hash(cell), h1 = hash(cell + 7.0), h2 = hash(cell + 11.0);
        float rate = 4.5 + h1 * 9.0;                         // ~0.7-2.1 Hz
        float tw = 0.55 + 0.30 * sin(time * rate + h0 * 40.0) + 0.15 * sin(time * rate * 2.37 + h2 * 20.0);
        // Snares flare a random handful (re-picked 10x a second); kicks lift the whole field.
        float flare = snap * step(0.82, hash(cell + floor(time * 10.0) * 0.37));
        float bright = tw * (1.0 + kick * 0.9) + flare * 2.5;
        float star = step(0.88, h0) * glow(length(p - at), (0.9 + h1 * 0.6) * (1.0 + flare * 0.8));
        float s = lit(star * bright * smoothstep(horizon, res.y, p.y + res.y * 0.1) * 0.8);
        vec3 sc = mix(fg.rgb, mix(c3.rgb, fg.rgb, 0.5), h2);
        col.rgb = col.rgb * (1.0 - s) + sc * s;
        col.a = clamp(col.a + s, 0.0, 1.0);
    }

    // ---- the sun -------------------------------------------------------------------
    vec2 sc = vec2(res.x * 0.5, horizon + res.y * 0.07);
    float sr = res.y * (0.21 + bass * 0.03 + kick * 0.03);
    float sd = length(p - sc);
    if (p.y > horizon - 1.0) {
        float sv = clamp((p.y - (sc.y - sr)) / (2.0 * sr), 0.0, 1.0);
        float bandsY = fract(sv * 10.0 - flow * 0.42);
        float gap = smoothstep(0.0, 0.08, bandsY - (1.0 - sv) * 0.55);
        float disc = clamp(sr - sd + 0.5, 0.0, 1.0) * gap;
        vec3 sun = mix(sunA, sunB, sv);
        sun = mix(sun, vec3(1.0), lit(0.12 + kick * 0.3) * sv);
        float a = disc * 0.95;
        col = vec4(col.rgb * (1.0 - a) + sun * a, col.a * (1.0 - a) + a);
    }
    float corona = lit(glow(max(sd - sr, 0.0), sr * (0.8 + swell * 0.4 + kick * 0.5)) * faux(0.30 + energy * 0.35 + kick * 0.55, 0.35));
    col.rgb += sunA * corona * 0.8 * (1.0 - col.a);
    col.a = max(col.a, corona * 0.8);

    // ---- far mountains: a silhouette against the sun --------------------------------
    {
        float x = uv.x * 6.0 + 1.7;
        float m = sin(x) * 0.5 + sin(x * 2.3 + 1.1) * 0.25 + sin(x * 5.1 + 0.4) * 0.12 + sin(x * 11.3) * 0.05;
        float my = horizon + res.y * (0.035 + 0.03 * m);
        float aM = clamp(my - p.y + 0.5, 0.0, 1.0) * step(horizon - 2.0, p.y);
        vec3 mc = mix(bg.rgb, glowCol, dark * 0.18 + light * 0.10);
        // Their crest catches the sun.
        float rim = lit(glow(p.y - my, 1.5) * glow(p.x - sc.x, sr * 1.6) * (0.5 + kick * 0.6));
        col = vec4(col.rgb * (1.0 - aM) + mc * aM, col.a * (1.0 - aM) + aM);
        col.rgb += glowCol * rim; col.a = max(col.a, rim);
    }

    // Horizon line: a thin hot seam where the land meets the glow.
    float seam = lit(glow(p.y - horizon, 2.0 + kick * 3.0) * faux(0.35 + energy * 0.3 + kick * 0.6, 0.35) * glow(p.x - sc.x, res.x * 0.45));
    col.rgb += mix(sunA, vec3(1.0), 0.3) * seam; col.a = clamp(col.a + seam, 0.0, 1.0);

    // ---- ridges: front to back, the first one above the pixel owns it -------------
    for (int k = 0; k < K; k++) {
        float z = float(k) / float(K - 1);                   // 0 front, 1 back
        float persp = 1.0 / (1.0 + z * 3.2);
        float baseY = mix(res.y * 0.02, ridgeTop, 1.0 - persp * (1.0 - z * 0.2));
        float cx = (uv.x - 0.5 - roadBend(z * 40.0) * 0.8) / mix(1.0, 0.42, z) + 0.5;
        // The land runs out to the screen edges; beyond the spectrum it lies flat.
        float fx = min(abs(cx - 0.5) * 2.0, 1.0);            // 0 = centre (bass) .. 1 = edges (treble)

        float hi = (float(K - 1 - k) / float(K - 1)) * (R - 1.0);
        float v = k == K - 1 ? band(fx) : texture(hist, vec2(fx, (hi + 0.5) / R)).r;
        v = pow(v, 1.2);
        float env = smoothstep(1.0, 0.45, fx);
        float h = v * env * res.y * 0.46 * persp * (1.0 + kick * 0.15) + hash(vec2(floor(cx * 120.0), float(k))) * 0.8;
        float y = baseY + h;

        if (p.y <= y + 2.0) {
            float d = y - p.y;                               // distance below the ridge line
            float lw = 1.2 + 0.8 * (1.0 - z);                // nearer ridges draw thicker
            float line = clamp(lw - abs(d), 0.0, 1.0);
            // Kick light rolls down the ridges: the crest sits at depth = kick, so as
            // the kick decays it travels from the back toward you.
            float pulse = lit(glow(z - kick, 0.09)) * min(1.0, kick * 4.0);
            float halo2 = lit(glow(max(d, 0.0), (6.0 + 10.0 * v) * persp) * faux(0.45 + v * 0.5 + pulse, 0.35));
            float fade = mix(1.0, 0.35, z);
            float sunward = glow(p.x - sc.x, res.x * 0.30) * z;   // ridges near the sun catch its light
            vec3 lc = pal(z * 0.7 + fx * 0.3) * (1.25 + lit(1.2 * v + faux(pulse * 2.2, 0.4) + sunward * 0.6));
            vec3 fogC = mix(bg.rgb, glowCol, 0.35 * dark);
            vec3 body = mix(bg.rgb * 0.6, bg.rgb, light);
            body = mix(body, fogC, z * z * 0.6);             // distant land melts into the glow
            // Faint contour shading on the face below each ridge.
            body += lit(glow(d, 26.0 * persp) * 0.10) * pal(fx);
            if (d < -0.5) {                                  // just above the line: line coverage only
                float a = line * fade;
                col = vec4(col.rgb * (1.0 - a) + lc * a, col.a * (1.0 - a) + a);
                continue;
            }
            vec3 lineCol = mix(lc, fogC, z * z * 0.5);
            vec3 rgb = mix(body, lineCol, max(line * fade, halo2 * fade));
            col = vec4(rgb, 1.0) * 0.96;
            break;
        }
    }

    col.rgb = mix(col.rgb, sat3(col.rgb * 1.1), dark * 0.5);

    // Vignette.
    vec2 q = qt_TexCoord0 - 0.5;
    float vig = smoothstep(0.35, 0.85, length(q * vec2(1.0, 1.3))) * mix(0.55, 0.15, light);
    col = vec4(col.rgb * (1.0 - vig) + bg.rgb * 0.25 * vig, col.a + (1.0 - col.a) * vig);

    fragColor = vec4(col.rgb + dither(p) * col.a, col.a) * qt_Opacity;
}
