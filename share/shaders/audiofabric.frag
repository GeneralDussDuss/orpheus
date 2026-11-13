//! name: Audiofabric
//! scale: 0.75
//! transition: 2

// After rolyatmax's audiofabric (github.com/rolyatmax/audiofabric, regl):
// a dark plane of fine grid lines, seen from a slow orbit, that billows up
// and glows where the music lands on it. Frequency anchors scattered over
// the fabric light their neighborhoods with their own band's energy, kicks
// throw expanding ripples from the last three kick points (kickAge), and
// the whole weave rides Orpheus's tempo-integrated flow: the orbit, the
// shimmer and the ripple speed all move at song pace, not clock pace.
//
// Orpheus uniforms used: flow, swell, energy, kick, kicks, kickAge, drop,
// build, downbeat, beatConfidence, bandAt(), c1/c2, light.

const float FAB_HMAX   = 0.34;   // how high the fabric billows
const float FAB_SPACE  = 0.115;  // grid line spacing
const float FAB_SIGMA  = 0.42;   // anchor glow radius
const float FAB_RIPPLE = 0.55;   // ripple travel speed (world units / s)
const int   FAB_ANCH   = 14;     // frequency anchors

vec2 fabHash22(float n) {
    uint h = uint(n * 1024.0) + 747796405u;
    h = h * 2891336453u ^ (h >> 13);
    uint h2 = h * 1664525u + 1013904223u;
    return vec2(float(h & 65535u), float(h2 & 65535u)) / 65535.0;
}

// The frequency field over the fabric: anchors lit by their band, kick
// ripples, and a loudness floor. This is audiofabric's blurred freq-map.
float fabField(vec2 q) {
    float f = 0.0;
    for (int i = 0; i < FAB_ANCH; i++) {
        vec2 h = fabHash22(float(i) + 7.0);
        float a = h.x * 6.2831853;
        float r = 0.25 + 1.15 * sqrt(h.y);
        vec2 ap = vec2(cos(a), sin(a)) * r;
        // low bands get the middle of the fabric, highs the edge
        float v = bandAt(i * 2);
        v = pow(clamp(v, 0.0, 1.0), 1.7);
        vec2 d = q - ap;
        f += v * exp(-dot(d, d) / (FAB_SIGMA * FAB_SIGMA));
    }
    // ripples from the last three kicks, placed by the kick counter so each
    // kick lands somewhere new, fading as they age (kickAge.w = strength)
    for (int k = 0; k < 3; k++) {
        float age = k == 0 ? kickAge.x : (k == 1 ? kickAge.y : kickAge.z);
        if (age > 6.0) continue;
        vec2 ep = (fabHash22(kicks - float(k) + 31.0) * 2.0 - 1.0) * 1.1;
        float w = (k == 0 ? max(kickAge.w, 0.35) : 0.45) * exp(-age * 0.9);
        float rr = age * FAB_RIPPLE;
        float dd = abs(length(q - ep) - rr);
        f += w * exp(-dd * dd / 0.012);
    }
    f += swell * 0.12 + drop * 0.25 * exp(-dot(q, q) * 0.5);
    return clamp(f, 0.0, 1.3);
}

float fabHeight(vec2 q) {
    float edge = exp(-max(0.0, length(q) - 1.5) * 2.2);   // fabric fades out past the weave
    return fabField(q) * FAB_HMAX * edge;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (2.0 * fragCoord - iResolution.xy) / iResolution.y;

    // Slow orbit at song pace: flow is tempo-integrated, so a fast song
    // circles the fabric faster, and a pace change bends the path.
    float orbit = flow * 0.085;
    float camH  = 1.45 + 0.35 * sin(flow * 0.031 + 1.3);
    vec3 ro = vec3(cos(orbit) * 2.9, camH, sin(orbit) * 2.9);
    vec3 ta = vec3(0.0, 0.08, 0.0);
    vec3 fw = normalize(ta - ro);
    vec3 rt = normalize(cross(fw, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(rt, fw);
    vec3 rd = normalize(fw * 1.5 + rt * uv.x + up * uv.y);

    // Background: audiofabric's dark gray, breathing faintly with the music.
    vec3 bgc = vec3(0.16) * (1.0 + 0.10 * swell + 0.18 * drop);
    bgc = mix(bgc, c1.rgb * 0.22, 0.12 * energy);
    float vig = 1.0 - 0.35 * dot(uv, uv);
    vec3 col = bgc * vig;

    // March the slab the fabric can occupy, then shade the hit.
    if (rd.y < -0.015) {
        float tTop = (FAB_HMAX + 0.02 - ro.y) / rd.y;
        float tBot = (0.0 - ro.y) / rd.y;
        float t0 = max(tTop, 0.0), t1 = tBot;
        float t = t0, tHit = -1.0;
        for (int i = 0; i < 52; i++) {
            vec3 p = ro + rd * t;
            float h = p.y - fabHeight(p.xz);
            if (h < 0.0) { tHit = t; break; }
            t += max(0.012, h * 0.65);
            if (t > t1) { tHit = t1; break; }
        }
        if (tHit < 0.0) tHit = t1;
        // one refinement step toward the surface
        for (int j = 0; j < 4; j++) {
            vec3 p = ro + rd * tHit;
            float h = p.y - fabHeight(p.xz);
            tHit += h * 0.5;
        }
        vec2 q = (ro + rd * tHit).xz;

        float f = fabField(q);
        // audiofabric's exact color ramp, pulled a little toward the theme
        vec3 ramp = clamp(sin((vec3(f) + vec3(0.10, 0.30, 0.50)) * 1.9), 0.0, 0.95);
        ramp = mix(ramp, pal(clamp(f, 0.0, 1.0)) * (0.3 + 0.9 * f), 0.45);

        // two line families, antialiased by distance so the weave stays fine
        float px = tHit * 2.6 / iResolution.y;
        vec2 g = abs(fract(q / FAB_SPACE) - 0.5) * FAB_SPACE;
        float lineW = 0.0060 + 0.0065 * f;
        float lx = 1.0 - smoothstep(lineW, lineW + px * 2.0, g.x);
        float ly = 1.0 - smoothstep(lineW, lineW + px * 2.0, g.y);
        float lines = max(lx, ly);

        // line opacity is the field squared, like the original, with a dim
        // base weave so the fabric never quite disappears; downbeats breathe
        // through it when the beat grid is confident.
        float op = clamp(pow(f * 1.7, 2.0), 0.0, 0.97);
        op = max(op, 0.045);
        op *= 1.0 + 0.10 * downbeat * beatConfidence + 0.12 * build;
        float dist = exp(-tHit * 0.16);
        col = mix(col, ramp, lines * op * dist);
        // soft underglow where the field is hot, so patches read as lit cloth
        col += ramp * f * f * 0.18 * dist * (1.0 + drop);
    }

    // Light themes: the dark weave becomes ink on paper.
    if (light > 0.5) col = vec3(0.96) - col * 0.88;
    fragColor = vec4(col, 1.0);
}
