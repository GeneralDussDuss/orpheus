#version 440
// Orpheus "Sanctum", second build: a true nave, not a wall of stripes. The
// first cut drew parallel bands and floating arch outlines and read as
// venetian blinds (user call, 2026-11-07); this one raycasts the classic
// infinite corridor, so the cathedral has real one-point perspective: from a
// vanishing point just above centre, every ray hits the left or right wall,
// the vaulted ceiling or the polished floor, at a true depth. The walls
// carry tall lancet windows, one bay per step of depth, and each bay is a
// region of the spectrum — near bays are bass, far bays treble — so a chord
// lights the nave in depth. The air between carries the glow of the windows
// it passes (cheap volumetrics: per-bay gaussians on the ray), and the floor
// mirrors everything, dimmer and fog-swallowed, which is what makes the
// stone read as polished. Dead centre, AT the vanishing point, hangs the
// rose window: a 12-petal radial spectrum the whole corridor converges on.
// It glimmers at rest, kindles with a build, the drop-map wind-up lifts
// sparks into the shafts — and the drop is the sun arriving: the rose blazes
// and floods the nave down its whole length. Kicks toll a ring of light down
// the ceiling ribs. `flow` processes you forward at walking pace, one bay at
// a time, forever. Light themes: morning stone — shade, not glow.
// Cost: analytic plane hits + ~8 bay gaussians, 3-tap fbm dust, no march.

//#common

const float PI = 3.14159265;
const int PETALS = 12;
const int BAYS = 8;           // visible window bays down each wall
const float BAYZ = 2.2;       // depth of one bay
const float HALLW = 1.0;      // half-width of the nave
const float HALLH = 1.35;     // ceiling height above eye
const float FLOORD = 0.55;    // floor below eye
const float FOGZ = 14.0;      // where the gloom swallows the far end

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

// A lancet window's lit coverage on a wall, in bay-local wall coords:
// u along the bay 0..1, h height above the floor line. Pointed top.
float lancet(float u, float h) {
    float du = abs(u - 0.5);
    float body = step(du, 0.14) * step(0.25, h) * step(h, 1.0);
    float tip = step(du, 0.14 * clamp((1.42 - h) / 0.42, 0.0, 1.0)) * step(1.0, h) * step(h, 1.42);
    float mullion = step(0.012, abs(u - 0.5));          // the central stone bar stays dark
    return (body + tip) * mullion;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 ndc = (px - res * 0.5) / res.y;                 // centered, y up
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);

    // The eye: a slow walk forward, a breath of sway. VP slightly above centre.
    float walk = flow * 0.35;                            // bays pass with the music's pace
    vec2 vp = vec2(camBob(0.04), 0.06 + camBob(0.03));
    vec2 rd2 = ndc - vp;                                  // ray direction, z = 1 implicit
    rd2 = rot(camRoll() * 0.3) * rd2;

    // ---- which plane does this ray hit, and how deep ----
    // Planes: x = +-HALLW, y = HALLH, y = -FLOORD; ray p = t * (rd2, 1).
    float tWallL = rd2.x < -1e-5 ? -HALLW / rd2.x : 1e9;
    float tWallR = rd2.x >  1e-5 ?  HALLW / rd2.x : 1e9;
    float tCeil  = rd2.y >  1e-5 ?  HALLH / rd2.y : 1e9;
    float tFloor = rd2.y < -1e-5 ? -FLOORD / rd2.y : 1e9;
    float t = min(min(tWallL, tWallR), min(tCeil, tFloor));
    float onFloor = step(tFloor, t - 1e-6) * step(t, tFloor + 1e-6);
    float onCeil = step(tCeil, t - 1e-6) * step(t, tCeil + 1e-6);
    float onWall = 1.0 - onFloor - onCeil;
    float z = t + walk;                                  // world depth of the hit
    float fog = exp(-t / FOGZ * 3.2);                    // the far end drowns

    // ---- the surfaces ----
    vec3 surf = vec3(0.0);
    float windowLit = 0.0;                               // how much window glass this pixel IS
    vec3 windowCol = vec3(0.0);

    // wall hit point: height above floor line, position along the hall
    if (onWall > 0.5) {
        float h = (t * rd2.y + FLOORD) / (HALLH + FLOORD) * 1.6;   // 0 floor .. ~1.6 vault
        float bay = z / BAYZ;
        float u = fract(bay);
        float bi = floor(bay);
        // this bay's voice: depth maps the spectrum, near = bass
        float fr = clamp((bi - walk / BAYZ) * (1.0 / float(BAYS)), 0.0, 1.0);
        float e = pow(clamp(band(fr), 0.0, 1.0), 0.6);
        e = clamp(e * (0.6 + 0.7 * swell), 0.0, 1.0);
        float glass = lancet(u, h);
        windowLit = glass;
        // glass colour: the palette by depth, charged a little by the wind-up
        windowCol = pal(0.2 + 0.65 * fr) * (0.25 + 1.5 * e + 0.5 * dr) * (1.0 + 0.4 * ant);
        // the stone between: dim but PRESENT, so the windows sit in a wall,
        // and each window's own light spills onto the stone around it
        float stone = 0.05 + 0.08 * vnoise(vec2(u * 7.0, h * 5.0) + bi);
        float spill = exp(-max(abs(u - 0.5) - 0.145, 0.0) * 8.0) * exp(-max(h - 1.42, 0.0) * 4.0) * step(0.1, h);
        surf = fg.rgb * stone * (0.3 + 0.7 * e) * 0.4 + windowCol * spill * 0.10 * (1.0 - glass);
        // pilaster edges between bays read as thin dark verticals: leave them dark
        surf *= smoothstep(0.0, 0.04, min(u, 1.0 - u));
    }
    // ceiling: ribs every bay, a kick tolls a ring of light down them
    if (onCeil > 0.5) {
        float u = fract(z / BAYZ);
        float rib = 1.0 - smoothstep(0.0, 0.05, min(u, 1.0 - u));
        float tollZ = kickAge.x * 9.0;                   // the newest kick's ring, running away
        float toll = exp(-pow((t - tollZ) / 1.1, 2.0)) * exp(-kickAge.x * 1.5) * kickAge.w;
        surf = fg.rgb * (0.04 + rib * (0.10 + 0.5 * toll)) + c2.rgb * rib * toll * 0.6;
    }

    // ---- the air: each bay's window pours glow into the ray that passes it ----
    vec3 air = vec3(0.0);
    for (int k = 0; k < BAYS; k++) {
        float bz = (floor(walk / BAYZ) + float(k) + 0.5) * BAYZ;   // this bay's window depth
        float bt = bz - walk;                                       // along our ray
        if (bt < 0.3) continue;
        float fr = clamp(float(k) / float(BAYS), 0.0, 1.0);
        float e = pow(clamp(band(fr), 0.0, 1.0), 0.6) * (0.6 + 0.7 * swell);
        // closest approach of the ray to the window's heart (high on both walls)
        vec2 at = vec2(sign(rd2.x + 1e-6) * HALLW * 0.99, HALLH * 0.45);
        vec2 pAt = rd2 * bt;
        float d2 = dot(pAt - at, pAt - at) / (bt * 0.22 + 0.08);
        float shaft = exp(-d2 * 2.2) * e;
        float dust = 0.6 + 0.4 * fbm3(vec2(ndc.x * 6.0 + float(k) * 7.0, ndc.y * 6.0 - time * 0.04));
        air += pal(0.2 + 0.65 * fr) * shaft * dust / (1.0 + bt * 0.5);
        // the wind-up: motes rise INTO the shafts before the drop lands
        if (ant > 0.02) {
            vec2 sp = vec2(ndc.x * 40.0 + float(k) * 13.0, ndc.y * 30.0 - time * (0.5 + 1.5 * ant));
            air += c3.rgb * step(0.986 - ant * 0.01, hash(floor(sp))) * ant * shaft * 2.0;
        }
    }

    // ---- the rose window, hanging at the vanishing point ----
    float roseR = 0.085 * (1.0 + 0.06 * sin(time * 0.6));           // it breathes
    vec2 rp = ndc - vp;
    float rr = length(rp) / roseR;
    float ang = atan(rp.y, rp.x);
    float petI = floor((ang / (2.0 * PI) + 0.5) * float(PETALS));
    float petU = fract((petI + 0.5) / float(PETALS) + 0.25);
    float pe = pow(clamp(band(petU), 0.0, 1.0), 0.6) * (0.6 + 0.7 * swell);
    float petEdge = abs(fract((ang / (2.0 * PI) + 0.5) * float(PETALS)) - 0.5) * 2.0;
    float glass = smoothstep(1.0, 0.94, rr) * smoothstep(0.12, 0.3, rr) * smoothstep(1.0, 0.72, petEdge);
    float hub = exp(-rr * rr * 5.0);
    float roseLit = 0.3 + 0.5 * pe + 0.8 * bd + 1.8 * dr;
    vec3 rose = (pal(0.25 + 0.6 * petU) * glass + c3.rgb * hub * 0.5) * roseLit;
    // the drop floods the nave FROM the rose: a halo that reaches down the corridor
    float floodR = length(rp);
    vec3 flood = pal(0.8) * exp(-floodR * floodR / (0.06 + 0.5 * dr)) * dr * 1.2;

    // ---- compose ----
    vec3 col;
    if (light < 0.5) {
        col = bg.rgb * 0.18;                                        // the gloom
        col += surf * fog;
        col += windowCol * windowLit * fog * lit(1.0);
        if (onFloor > 0.5) {
            // polished stone: mirror the hall above, dimmed and fogged harder
            vec2 mir = vec2(rd2.x, -rd2.y);
            float mt = min(mir.x < -1e-5 ? -HALLW / mir.x : 1e9, mir.x > 1e-5 ? HALLW / mir.x : 1e9);
            float mz = mt + walk;
            float mh = (mt * mir.y + FLOORD) / (HALLH + FLOORD) * 1.6;
            float mu = fract(mz / BAYZ);
            float mfr = clamp((floor(mz / BAYZ) - walk / BAYZ) / float(BAYS), 0.0, 1.0);
            float me = pow(clamp(band(mfr), 0.0, 1.0), 0.6) * (0.6 + 0.7 * swell);
            float mg = lancet(mu, mh);
            col += pal(0.2 + 0.65 * mfr) * mg * me * exp(-mt / FOGZ * 4.5) * lit(0.5);
            float sheen = 0.05 * exp(-t / FOGZ * 2.0);
            col += fg.rgb * sheen;
        }
        col += air * lit(1.0);
        col += (rose + flood) * lit(1.0) * smoothstep(0.0, 0.15, fog + 0.1);
        col = 1.0 - exp(-col * 1.2);
    } else {
        // morning stone: everything as shade on pale air
        col = bg.rgb * (0.9 + 0.1 * fog);
        col = mix(col, fg.rgb * 0.3, (onWall * 0.5 + onCeil * 0.4) * (1.0 - fog) * 0.7);
        col = mix(col, windowCol * 0.5 + bg.rgb * 0.3, windowLit * fog * 0.8);
        vec3 tintAir = clamp(air, 0.0, 1.0);
        col = mix(col, mix(tintAir, bg.rgb, 0.4), clamp(air.g + air.r, 0.0, 0.6));
        col = mix(col, rose * 0.7 + bg.rgb * 0.2, clamp(glass * roseLit * 0.5 + hub * dr, 0.0, 1.0));
    }

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
