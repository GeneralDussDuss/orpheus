#version 440
// Orpheus "Quasar": the music falls into a black hole. An accretion disk
// seen nearly edge-on, drawn the Interstellar way in 2D: light from the far
// side of the disk is lensed over and under the shadow, so the hole wears
// the disk as a crown and a chin-strap, with a thin photon ring at the last
// orbit. The disk's matter IS the spectrum history: fresh energy lands on
// the outer rim and spirals inward with Keplerian shear (inner orbits run
// faster), so a phrase you heard four seconds ago is a glowing ring half
// swallowed by now. Frequencies are radii — bass burns at the inner edge,
// treble glitters at the rim. The approaching side is doppler-bright, the
// receding side dims and reddens toward c1. Kicks drop hot blobs on the
// inner edge that smear into arcs as they orbit. A build feeds the disk
// (accretion rate up, everything tightens inward); the drop-map wind-up
// makes the poles begin to shimmer — and the drop fires the relativistic
// jet, twin beams with a travelling pulse, that fade as the disk relaxes.
// The starfield behind is pulled toward the shadow, swirled by frame drag.
// Light themes: the hole stays black on paper — ink disk, no additive glow.
// Cost: 2 lensed disk taps + 1 history tap each, starfield hash, no march.

//#common

layout(binding = 1) uniform sampler2D hist;   // 32 x 40 spectrum history, row 0 = now

const float PI = 3.14159265;
const float RS = 0.11;         // the shadow's radius (screen height units)
const float RIN = 0.145;       // inner disk edge
const float ROUT = 0.60;       // outer rim

// Disk emission at polar (r, a) on the disk plane. Radius maps frequency,
// history spirals inward: age grows from rim to inner edge, sheared by orbit.
vec3 diskLight(float r, float a, float feed, out float amt) {
    float t = clamp((r - RIN) / (ROUT - RIN), 0.0, 1.0);   // 0 inner .. 1 rim
    // Keplerian shear: inner orbits run faster; flow drives the rotation.
    float orbit = a + flow * 0.55 / pow(max(t, 0.08), 1.5);
    // matter falls in as it ages: age 0 at the rim, 1 at the inner edge,
    // nudged inward faster while the disk is being fed
    float age = (1.0 - t) * (0.75 + 0.25 * feed);
    float freq = clamp(t, 0.02, 0.98);                      // bass inside, treble out
    float e = texture(hist, vec2(freq, clamp(age, 0.0, 0.975))).r;
    float live = band(freq) * smoothstep(0.9, 1.0, t);      // the rim takes the live signal
    e = max(e, live);
    // orbital grain so the disk is streaks, not a wash
    float grain = 0.75 + 0.25 * sin(orbit * 9.0 + t * 30.0) * sin(orbit * 3.7 - t * 11.0);
    // inner edge always simmers; everything brightens toward the centre
    float hot = exp(-(t) * 2.6) * (0.25 + 0.45 * bass);
    e = pow(clamp(e, 0.0, 1.0), 0.7);                       // quiet phrases still shine
    amt = (e * e * (0.7 + 0.5 * grain) + hot) * smoothstep(0.0, 0.06, t) * smoothstep(1.0, 0.94, t);
    vec3 c = pal(clamp(0.9 - t * 0.9, 0.0, 1.0));           // inner = hot end of the palette
    return c * amt;
}

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 uv = (px - res * 0.5) / res.y;                     // centered, y up, height units
    float dark = 1.0 - light;

    float bd = clamp(build, 0.0, 1.0);
    float ant = clamp(anticipate, 0.0, 1.0);
    float dr = clamp(drop, 0.0, 1.0);
    float feed = clamp(bd + dr * 0.5, 0.0, 1.0);

    // the camera breathes with the loudness envelope
    uv *= 1.0 - 0.06 * swell;
    uv = rotateAround(uv, vec2(0.0), camRoll() * 0.4);

    float rr = length(uv);
    float phi = atan(uv.y, uv.x);

    // ---- the disk, seen at a shallow tilt, plus its two lensed images ----
    const float TILT = 0.22;                                // how open the ellipse is
    vec3 colD = vec3(0.0);
    float amtD = 0.0;
    // direct image: deproject the screen point onto the disk plane
    {
        vec2 d = vec2(uv.x, uv.y / TILT);
        float r = length(d);
        if (r > RIN && r < ROUT && uv.y < RS * 0.4) {       // the near half, in front of the hole
            float a; vec3 c = diskLight(r, atan(d.y, d.x), feed, a);
            colD += c; amtD += a;
        }
    }
    // lensed far side: bent over (and under) the shadow. Approximation: fold
    // the vertical axis past the hole with a 1/r bend, strongest at the shadow.
    {
        float bend = RS * RS / max(rr, RS * 0.6);
        vec2 lp = vec2(uv.x, (abs(uv.y) + bend * 1.6));     // pulled over the pole
        vec2 d = vec2(lp.x, lp.y / TILT);
        float r = length(d);
        if (r > RIN && r < ROUT) {
            float a; vec3 c = diskLight(r, atan(d.y, d.x) + PI, feed, a);
            float arc = smoothstep(RS * 2.6, RS * 1.1, rr); // only near the hole
            colD += c * arc * 1.5; amtD += a * arc * 1.5;   // the crown must be SEEN
        }
    }
    // doppler: the left side approaches
    float dop = 1.0 + 0.55 * (-uv.x / max(rr, 1e-3)) * smoothstep(0.0, 0.2, rr);
    colD *= dop;
    colD = mix(colD, c1.rgb * amtD * 0.6, clamp(0.5 * (uv.x / max(rr, 1e-3)), 0.0, 0.5));  // recede reddens

    // ---- kicks: hot blobs smearing into arcs on the inner edge ----
    for (int k = 0; k < 3; k++) {
        float age = kickAge[k];
        if (age < 3.0) {
            float s = kicks - float(k);
            float bt = 0.1 + 0.2 * hash(vec2(s, 3.3));
            float br = mix(RIN, ROUT, bt);
            float ba = hash(vec2(s, 7.7)) * 2.0 * PI + flow * 0.55 / pow(bt, 1.5);
            vec2 at = vec2(cos(ba), sin(ba) * TILT) * br;
            float smear = 1.0 + age * 2.0;                   // the blob stretches along its orbit
            vec2 rel = uv - at;
            vec2 tang = normalize(vec2(-at.y, at.x) + 1e-5);
            float along = dot(rel, tang) * (1.0 / smear);
            float acrossB = dot(rel, normalize(at + 1e-5));
            float blob = exp(-(along * along + acrossB * acrossB * 4.0) / 0.0012)
                       * exp(-age * 1.4) * (k == 0 ? kickAge.w : 0.7);
            colD += pal(0.95) * blob * (uv.y < RS * 0.4 ? 1.0 : 0.4);
            amtD += blob * 0.5;
        }
    }

    // ---- the photon ring and the shadow ----
    float ring = exp(-pow((rr - RS * 1.18) / (0.0045 + 0.002 * swell), 2.0)) * (0.35 + 0.65 * swell);
    float shadow = smoothstep(RS * 1.04, RS * 0.9, rr);     // absolute black, the one true black

    // ---- the jet: charged by the wind-up, fired by the drop ----
    vec3 jet = vec3(0.0);
    float poleGlow = 0.0;
    {
        float ax = abs(uv.x) ;
        float along = abs(uv.y);
        if (ant > 0.01) {                                    // the poles shimmer before it blows
            poleGlow = exp(-ax * ax / 0.0015) * exp(-pow((along - RS * 1.4) / 0.08, 2.0)) * ant * (0.4 + 0.3 * sin(time * 7.0 + uv.y * 30.0));
        }
        if (dr > 0.003) {
            float coreW = 0.006 + 0.004 * dr;
            float core = exp(-ax * ax / (coreW * coreW)) * smoothstep(RS * 0.9, RS * 1.3, along);
            float sheath = exp(-ax * ax / 0.004) * smoothstep(RS * 0.9, RS * 2.0, along) * 0.4;
            float pulse = exp(-pow((along - (1.0 - dr) * 1.1 - RS) / 0.07, 2.0));   // rides outward
            float fade = exp(-along * 1.4);
            jet = (c3.rgb * core + pal(0.75) * sheath) * (fade * 0.8 + pulse * 0.9) * dr;
        }
    }

    // ---- the starfield, lensed near the hole only ----
    // The pull and any radius-dependent rotation must DIE OFF with distance:
    // warping the whole hash lattice by a function of r turns the cell grid
    // into giant moiré contour rings (seen live, first cut of this shader).
    vec3 stars = vec3(0.0);
    {
        float nearH = smoothstep(RS * 4.0, RS * 1.1, rr);
        float pull = (RS * RS / max(rr * rr, RS * RS * 0.8)) * nearH;
        vec2 sp = rotateAround(uv * (1.0 + pull * 1.2), vec2(0.0), flow * 0.004);
        vec2 cellp = floor(sp * 34.0);
        float h = hash(cellp);
        if (h > 0.962) {
            vec2 at = (cellp + vec2(hash(cellp + 1.3), hash(cellp + 2.6))) / 34.0;
            float d2 = dot(sp - at, sp - at);
            float tw = 0.5 + 0.5 * sin(time * (1.0 + h * 3.0) + h * 40.0);
            stars += mix(fg.rgb, pal(h), 0.4) * exp(-d2 / 0.0000035) * (0.25 + 0.3 * tw + 0.3 * band(0.85));
        }
    }

    // ---- compose ----
    vec3 col;
    if (light < 0.5) {
        col = bg.rgb * 0.22 + stars * lit(1.0);              // space is nearly black even on dark themes
        col += colD * lit(1.35);
        col += c3.rgb * ring * lit(0.9) * faux(1.0, 0.5);
        col += jet * lit(1.0) + c2.rgb * poleGlow * lit(0.8);
        col = 1.0 - exp(-col * 1.25);
        col *= 1.0 - shadow;                                  // the hole eats everything, last
    } else {
        // ink on paper: the disk as ink density, the hole stays black
        col = bg.rgb - (bg.rgb - fg.rgb * 0.1) * clamp(stars * 2.0, 0.0, 1.0).r * 0.3;
        float inkAmt = clamp(amtD * 1.3, 0.0, 1.0);
        vec3 tint = clamp(colD / max(amtD, 1e-3), 0.0, 1.0);
        col = mix(col, mix(tint, fg.rgb, 0.55) * 0.5, inkAmt);
        col = mix(col, fg.rgb * 0.25, ring * 0.8);
        col = mix(col, mix(fg.rgb, pal(0.75), 0.4) * 0.45, clamp(jet.b + jet.r + poleGlow, 0.0, 1.0));
        col *= 1.0 - shadow * 0.92;                           // near-black hole, still printable
    }

    fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
}
