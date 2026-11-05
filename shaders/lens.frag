#version 440
// Orpheus "Lens": bending spacetime with the music. Deep space is a fine
// lattice of thin lines and a sparse starfield; a dark mass drifts through it
// on a slow orbit and bends everything around it like a gravitational lens,
// so the lines curve smoothly past it and light at the critical radius
// smears into an Einstein ring glowing from c1 to c2.
// The loudness swell lets the lens breathe in and out; every kick launches a
// gravitational wave, a thin travelling ring of compression in the metric
// itself (the lattice bunches and stretches as it passes, nothing flashes),
// and up to three coexist. A build lets the stars slowly fall in toward the
// mass; a drop rings the lens down: the ring blooms in c3 and a few echo rings
// chase outward before it all settles. Light themes flip to dark ink on the
// pale ground and the lens darkens instead of glowing. Single pass, 2D math.

//#common

const float PI = 3.14159265;

// Distance of x to the nearest multiple of 1 (0..0.5).
vec2 gridD(vec2 x) { vec2 f = fract(x); return min(f, 1.0 - f); }

// Thin anti-aliased line coverage from a distance in grid units and its pixel footprint.
float lineAA(float d, float fw) { return 1.0 - smoothstep(0.0, max(fw * 1.3, 1e-4), d); }

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    vec2 p = (px - res * 0.5) / res.y;                       // height units, y up
    float dark = 1.0 - light;

    // ---- the mass: a slow Lissajous orbit, driven by distance travelled, never by time ----
    vec2 M = vec2(0.30 * sin(flow * 0.052 + 0.4) + 0.08 * sin(flow * 0.021 + 2.1),
                  0.17 * sin(flow * 0.037 + 1.6) + 0.05 * sin(flow * 0.016));
    float breathe = 0.5 + 0.5 * sin(time * 0.31);            // the resting breath
    float E = 0.150 * (1.0 + 0.40 * clamp(swell, 0.0, 1.0) + 0.05 * clamp(bass, 0.0, 1.0) + 0.04 * breathe);
    E *= 1.0 + 0.10 * drop;

    vec2 d0 = p - M;
    float r0 = length(d0);
    vec2 dir0 = d0 / max(r0, 1e-4);

    // ---- gravitational waves: radial displacement of the sampling coordinate ----
    vec2 q = p;
    float waveCompress = 0.0;
    for (int j = 0; j < 3; j++) {
        float a = kickAge[j];
        if (a >= 4.0) continue;
        float str = (j == 0 ? 0.45 + 0.55 * kickAge.w : 0.7) * exp(-a * 0.9);
        float R = 0.04 + a * 0.46;
        float w = 0.030 + a * 0.020;
        float x = (r0 - R) / w;
        float prof = x * exp(-x * x);                        // odd bump: compresses ahead, rarefies behind
        q -= dir0 * prof * 0.030 * str * smoothstep(0.0, 0.05, a + 0.01);
        waveCompress += abs(prof) * str;
    }

    // ---- the lens: point-mass deflection, softened at the centre ----
    vec2 dq = q - M;
    float rq2 = dot(dq, dq);
    float soft = 0.0025;
    vec2 S = M + dq * (1.0 - (E * E) / (rq2 + soft));        // source-plane coordinate (lines curve, inside flips)
    float rq = sqrt(rq2);

    // ---- lattice: a fine grid in the source plane, major lines every 4 ----
    vec2 g = S * 7.0 + vec2(flow * 0.010, flow * 0.004);
    vec2 gd = gridD(g);
    vec2 gfw = fwidth(g);
    float minor = max(lineAA(gd.x, gfw.x), lineAA(gd.y, gfw.y));
    vec2 g4 = g * 0.25;
    vec2 gd4 = gridD(g4);
    vec2 gfw4 = fwidth(g4);
    float major = max(lineAA(gd4.x, gfw4.x), lineAA(gd4.y, gfw4.y));
    // and a faint polar graticule of rings around the world origin
    float rs = length(S) * 5.0;
    float ringsL = lineAA(min(fract(rs), 1.0 - fract(rs)), fwidth(rs));
    float lat = 0.40 * minor + 0.60 * major + 0.22 * ringsL;
    float edgeFade = 1.0 - smoothstep(0.45, 1.1, length(p));  // lattice dims toward the corners
    lat *= (0.55 + 0.45 * edgeFade);

    // beat-locked shimmer, gentle and only when the grid is trusted
    float bsh = 0.5 + 0.5 * cos(beatPhase * 2.0 * PI);
    lat *= 1.0 + 0.10 * clamp(beatConfidence, 0.0, 1.0) * bsh * (0.3 + 0.7 * clamp(energy, 0.0, 1.0));
    // the waves visibly bunch the lattice a little more
    lat *= 1.0 + 0.5 * clamp(waveCompress, 0.0, 1.0);

    // ---- stars: sparse, hashed, falling inward as the build rises ----
    vec2 sc = S - M;
    float scl = 1.0 + 0.55 * clamp(build, 0.0, 1.0);
    float rr = length(sc);
    float spin = clamp(build, 0.0, 1.0) * 0.5 / (0.3 + rr);  // inner stars wind round faster
    float cs = cos(spin), sn = sin(spin);
    sc = vec2(sc.x * cs - sc.y * sn, sc.x * sn + sc.y * cs) * scl + M;
    float cellW = 0.085;
    vec2 cp = sc / cellW;
    vec2 cell = floor(cp);
    vec2 fc = fract(cp);
    float h0 = hash(cell + 1.3);
    vec2 at = 0.2 + 0.6 * vec2(hash(cell + 3.1), hash(cell + 5.7));
    float h1 = hash(cell + 7.0);
    float mag = step(0.86, h0) * (0.35 + 0.65 * fract(h0 * 23.0));
    float tw = 0.75 + 0.25 * sin(time * (0.5 + h1 * 1.2) + h0 * 50.0);
    float sd = length(fc - at) * cellW;
    float pxw = 1.0 / res.y;
    float star = mag * tw * exp(-(sd * sd) / (pxw * pxw * 1.6 + 1e-9));
    star *= 0.55 + 0.45 * edgeFade;

    // ---- the Einstein ring: light smeared around the critical radius ----
    float ang = atan(dq.y, dq.x);
    float ang0 = flow * 0.03 + 1.1;
    float arc = 0.30 + 0.70 * pow(0.5 + 0.5 * cos(ang - ang0), 2.0) + 0.35 * pow(0.5 + 0.5 * cos(2.0 * (ang - ang0 * 1.7) + 1.0), 3.0);
    float rw = 0.010 + 0.006 * clamp(swell, 0.0, 1.0);
    float x = (rq - E) / rw;
    float core = exp(-x * x);
    float halo = (rq > E ? exp(-(rq - E) / 0.055) : exp(-(E - rq) / 0.02)) * 0.28;
    float lensGain = 0.40 + 0.55 * clamp(swell, 0.0, 1.0) + 0.25 * clamp(bass, 0.0, 1.0);
    float ringI = (core * arc + halo * (0.5 + 0.5 * arc)) * lensGain;
    float tcol = 0.5 + 0.5 * sin(ang * 1.0 + ang0 * 0.8);     // c1 -> c2 around the ring
    vec3 ringC = pal(tcol * 0.55);

    // ringdown: bloom in c3 plus two or three echo rings chasing outward
    float dp = clamp(drop, 0.0, 1.0);
    float bloomI = dp * (core * 2.2 + exp(-pow((rq - E * 1.06) / (rw * 3.0), 2.0)) * 0.9);
    float echo = 0.0;
    for (int k = 1; k <= 3; k++) {
        float fk = float(k);
        float Re = E + (1.0 - dp) * (0.17 * fk) + 0.02 * fk;
        float wk = rw * (1.5 + 0.8 * fk);
        float xe = (rq - Re) / wk;
        echo += exp(-xe * xe) * dp * (0.9 / fk) * smoothstep(0.0, 0.15, 1.0 - dp + 0.04);
    }
    float dropI = bloomI + echo;

    // the dark mass itself
    float hr = E * 0.42;
    float shadow = smoothstep(hr * 0.75, hr * 1.25, rq);     // 0 inside the horizon .. 1 outside

    vec3 col;
    float vq = length(qt_TexCoord0 - 0.5);
    if (light < 0.5) {
        vec3 lat_c = mix(fg.rgb, c1.rgb, 0.30);
        vec3 starC = mix(fg.rgb, c3.rgb, 0.25);
        vec3 add = lat_c * lat * 0.20 + starC * star * 0.55;
        add *= 0.85 + 0.3 * clamp(swell, 0.0, 1.0);
        add += ringC * ringI * 1.1 * faux(1.0, 0.3);
        add += c3.rgb * dropI * 1.3 * faux(1.0, 0.3);
        // soft hue-keeping curve so bright arcs saturate toward their colour, not white
        float m = max(max(add.r, add.g), add.b);
        add *= (1.0 - exp(-m)) / max(m, 1e-4);
        col = bg.rgb * 0.9 + add;
        col = mix(bg.rgb * 0.5, col, shadow);
        // vignette toward the ground colour
        col = mix(col, bg.rgb * 0.35, smoothstep(0.35, 0.85, vq) * 0.55);
    } else {
        // dark ink on pale ground; the lens darkens instead of glowing
        vec3 ink = mix(fg.rgb, c1.rgb, 0.25);
        col = bg.rgb;
        col = mix(col, ink, clamp(lat * 0.30, 0.0, 0.6));
        col = mix(col, fg.rgb, clamp(star * 0.7, 0.0, 0.8));
        float ra = clamp(ringI * 0.55 + dropI * 0.5, 0.0, 0.85);
        vec3 rc = mix(ringC, c3.rgb, clamp(dropI, 0.0, 1.0)) * 0.55;
        col = mix(col, rc, ra);
        col = mix(fg.rgb * 0.55, col, shadow);
        col = mix(col, bg.rgb, smoothstep(0.35, 0.85, vq) * 0.45);
    }

    col = max(col, 0.0) + dither(px);
    fragColor = vec4(max(col, 0.0), 1.0) * qt_Opacity;
}
