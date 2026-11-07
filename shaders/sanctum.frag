#version 440
// Orpheus "Sanctum": a vast interior where the light is the instrument. You
// stand in the nave of an endless cathedral; seven tall windows climb the
// left wall and seven god-ray shafts fall from them through slow dust to the
// floor. Each window is a region of the spectrum: its shaft brightens,
// widens and reaches further across the floor as its bands sing, so a chord
// is architecture — the whole nave is a spectrum analyser drawn in light.
// High in the apse hangs the rose window, a 12-petal radial spectrum that
// barely glimmers through the gloom; a build kindles it petal by petal, the
// drop-map wind-up makes the dust itself begin to rise, and the drop is the
// moment the sun finds it: the rose blazes and pours a burst of radial beams
// down the nave, then the gloom settles back. Kicks are a low toll that
// swells the shaft roots; the downbeat breathes the fog. Pointed arches rib
// the far wall as thin lines, grey until a shaft crosses them. No travel,
// no strobe: stillness, scale, and patience are the whole point.
// Light themes: morning service — dark stone lines on pale air, shafts as
// soft shade, the rose in muted glass colours.
// Cost: 7 shafts + 12 petals of 2D analytic light, ~30 noise taps, no march.

//#common

const float PI = 3.14159265;
const int WINDOWS = 7;
const int PETALS = 12;

mat2 rot(float a) { return mat2(cos(a), -sin(a), sin(a), cos(a)); }

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

float fbm3(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p = rot(0.62) * p * 2.1 + 17.0; a *= 0.5; }
    return v;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 uv = px / res;                                    // 0..1, y up
    float asp = res.x / res.y;
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float breathe = 0.5 + 0.5 * sin(time * 0.6);           // the fog's slow breath
    float toll = kick * kick;

    // ---- the air: layered gloom that the downbeat stirs ----
    float fog = fbm3(vec2(uv.x * 3.0 * asp + time * 0.015, uv.y * 2.0 - time * 0.01));
    fog = 0.4 + 0.6 * fog;
    float gloom = mix(0.85, 1.0, breathe * 0.5 + downbeat * beatConfidence * 0.25);

    vec3 shaftSum = vec3(0.0);
    float shaftCov = 0.0;                                  // how much shaft light sits on this pixel

    // ---- seven shafts from the high left, each a spectrum region ----
    float slope = 1.15;                                    // dx per dy of the falling light
    for (int w = 0; w < WINDOWS; w++) {
        float fw = float(w);
        float u0 = (fw + 0.5) / float(WINDOWS);
        // three bands around this window's centre, smoothed: never flickers
        float e = (band(u0 - 0.04) + band(u0) * 1.2 + band(u0 + 0.04)) / 3.2;
        e = pow(clamp(e, 0.0, 1.0), 0.6);                  // quiet bands still light their window
        e = clamp(e * (0.6 + 0.7 * swell), 0.0, 1.0);
        // where this window's shaft enters the frame at the top
        float topX = 0.06 + 0.95 * fw / float(WINDOWS) - 0.25;
        float wWide = (0.035 + 0.05 * e) ;
        // signed distance across the slanted shaft
        float across = (uv.x - (topX + (1.0 - uv.y) * slope / asp)) * asp;
        float inShaft = exp(-pow(across / wWide, 2.0));
        // the shaft reaches down with energy; its foot fades into the floor
        float reach = smoothstep(-0.15, 0.35, uv.y - (0.42 - 0.38 * e));
        // dust: the light is only visible where motes hang in it
        float dust = fbm3(vec2(across * 6.0 + fw * 7.0, uv.y * 4.0 - time * (0.03 + 0.05 * ant) - fw));
        dust = mix(0.55, 1.0, dust);
        // the wind-up: dust begins to RISE and sparkle before the drop lands
        float riseSpark = 0.0;
        if (ant > 0.02) {
            vec2 sp = vec2(across * 30.0 + fw * 13.0, uv.y * 24.0 - time * (0.6 + 1.4 * ant));
            riseSpark = step(0.985 - ant * 0.012, hash(floor(sp))) * ant;
        }
        float root = exp(-pow((uv.y - 0.1) / 0.1, 2.0)) * toll * 0.5;   // kicks swell the foot
        float s = inShaft * reach * dust * (0.22 + 1.6 * e) * gloom;
        shaftSum += pal(0.15 + 0.7 * u0) * (s + root * inShaft) + c3.rgb * riseSpark * inShaft * reach;
        shaftCov += s;
    }

    // ---- the rose window: a 12-petal radial spectrum in the high apse ----
    vec2 rc = vec2(0.76, 0.74);
    vec2 d = (uv - rc) * vec2(asp, 1.0);
    float rr = length(d) / 0.14;                           // 1 at the rim
    float ang = atan(d.y, d.x);
    float pet = floor((ang / (2.0 * PI) + 0.5) * float(PETALS));
    float petU = fract((pet + 0.5) / float(PETALS) + 0.25);
    float pe = clamp(pow(clamp(band(petU), 0.0, 1.0), 0.6) * (0.6 + 0.7 * swell), 0.0, 1.0);
    float petEdge = abs(fract((ang / (2.0 * PI) + 0.5) * float(PETALS)) - 0.5) * 2.0;  // 0 mid, 1 at lead line
    float glass = smoothstep(1.0, 0.92, rr) * smoothstep(0.1, 0.25, rr)      // annulus
                * smoothstep(1.0, 0.75, petEdge);                             // lead lines stay dark
    float hub = exp(-rr * rr * 6.0);
    // its light: a glimmer at rest, kindled by the build, ablaze on the drop
    float roseLit = 0.22 + 0.45 * pe + 0.65 * bd * smoothstep(fract(pet * 0.618), 0.0, bd) + 1.4 * dr;
    vec3 rose = pal(0.3 + 0.6 * petU) * glass * roseLit + c3.rgb * hub * (0.2 + 1.2 * dr);

    // ---- the drop: the rose pours radial beams down the nave ----
    float burst = 0.0;
    if (dr > 0.003) {
        float rayA = ang;
        float rays = pow(abs(sin(rayA * 6.0 + flow * 0.1)), 18.0);
        burst = rays * exp(-rr * 0.35) * dr * dr * smoothstep(0.25, 1.0, rr);
    }

    // ---- the stone: pointed arches ribbing the far wall, grey until lit ----
    float arch = 0.0;
    {
        vec2 ap = vec2(fract(uv.x * asp * 1.6) - 0.5, uv.y);
        float a1 = abs(length(vec2(ap.x + 0.22, ap.y - 0.18) * vec2(1.0, 0.62)) - 0.42);
        float a2 = abs(length(vec2(ap.x - 0.22, ap.y - 0.18) * vec2(1.0, 0.62)) - 0.42);
        float dline = min(a1, a2);
        float fwp = fwidth(dline) * 1.4 + 1e-4;
        arch = (1.0 - smoothstep(0.0015, 0.0015 + fwp, dline)) * smoothstep(0.95, 0.5, uv.y) * step(uv.y, 0.72);
    }

    // ---- the floor: a dim mirror of the shafts ----
    float floorY = smoothstep(0.16, 0.0, uv.y);
    vec3 floorGlow = shaftSum * floorY * 0.35;

    // ---- compose ----
    vec3 col;
    if (light < 0.5) {
        col = bg.rgb * (0.75 + 0.15 * fog * gloom);                      // the gloom itself
        col += fg.rgb * arch * (0.16 + 0.5 * shaftCov);                  // stone, lit only by light
        col += shaftSum * lit(1.4) * fog;
        col += floorGlow * lit(1.0);
        col += rose * lit(1.0) + pal(0.8) * burst * lit(0.9);
        col = 1.0 - exp(-col * 1.1);
    } else {
        // morning service: shade and glass on pale air
        col = bg.rgb * (0.96 + 0.04 * fog);
        col = mix(col, fg.rgb * 0.35, arch * 0.6);
        vec3 tint = clamp(shaftSum / max(shaftCov, 1e-3), 0.0, 1.0);
        col = mix(col, mix(tint, bg.rgb, 0.45), clamp(shaftCov, 0.0, 1.0) * 0.5);
        col = mix(col, rose * 0.8 + bg.rgb * 0.3, clamp(glass * (0.3 + roseLit * 0.4) + hub * dr, 0.0, 1.0));
        col = mix(col, pal(0.8) * 0.7, burst * 0.5);
    }

    // vignette: the vault swallows the corners
    vec2 vc = (uv - vec2(0.5, 0.45)) * vec2(asp, 1.0);
    col = mix(col, bg.rgb * mix(0.55, 1.0, light), smoothstep(0.65, 1.25, length(vc)) * 0.6);

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
